// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE for the full text.
//
// THE DSB'S Z80, CUT DOWN TO ITS PROGRAMS.
//
// From the Sega Model 1 core (sega-model1-mister 2657c46, rtl/sound/dsb_z80.sv),
// where it ran Star Wars' Digital Sound Board program, epr-16471.2: 76 opcodes,
// no IX/IY, no EXX or EX AF, interrupts that can never be taken.
//
// SEGA TOURING CAR CHAMPIONSHIP'S PROGRAM IS A DIFFERENT ONE. epr-19275.2s is
// 1.5 KB of code, traced statically (tools/dsb/z80_census.py, from the reset
// and IM 1 vectors, RST 08 and its two 4-entry jump tables) to 783
// instructions of 128 distinct opcodes, 69 of which Star Wars never uses:
//   - it is INTERRUPT-DRIVEN. MAME wires the DSB UART's RxRDY to INT; the
//     program runs with EI in IM 1 and every received byte is taken by the
//     handler at 0x38 into a ring buffer at 8000-8FFF;
//   - the handler saves state with EX AF,AF' and EXX;
//   - IY (ld iy,nn; push / pop / inc iy; (iy+d) loads, stores, add / adc / cp);
//   - the S flag (jp m after or a), adc, sub, sbc hl,de, rr / rrca / rra, cpl,
//     JP (HL) into a jump table, RST 08, and more loads, incs, jrs and bits.
// R979's core executed the UNION of the two programs, 145 opcodes. R1004:
// Model 2C runs STCC's program only, so the generated microcode
// (gen_z80_ucode.py without --union, U_UNION 0) dispatches STCC's 128 and the
// datapath drops what only Star Wars used (out (c),a; sla; bit 7's S);
// anything else TRAPS -- counted, its PC kept, run as a no-op of 4 or 8 T.
// Generated with --union (U_UNION 1) it is R979's core, and Star Wars'
// program runs exactly as it did.
//
// MICROCODED. A regular datapath -- a two-port register file holding BC DE
// HL and their alternates, PC, SP, IY and a 16-bit TMP; A and the flags in
// flops; one 16-bit address adder, one 8-bit ALU -- is driven by 153 40-bit
// micro-ops (173 with --union) in one M10K (tools/dsb/gen_z80_ucode.py writes
// them), dispatched by a 1024 x 8 table ({prefix, opcode}; prefix 0 none,
// 1 CB, 2 ED, 3 FD) in another M10K or, with DSB_UENT_LOGIC defined, as logic
// with the same one-cycle registered output.
//
// R1007: THE REGISTERS ARE IN M10K. Until R1004 every register was a flop and
// every read a wide mux (the address base 8:1 x 16, three 8:1 byte reads, and
// a multi-source write mux on each of 20 bytes). Now they are rows of a
// 16 x 16 register file, one M10K per byte lane, each true dual-port: port A
// reads the micro-op's address base and writes its 16-bit result, port B reads
// its one other register (rb, chosen by the generator) and writes its one
// byte. A micro-op therefore takes two clocks, not one (the read, then the
// execute), and a fetch three (PC is a row too, incremented through the
// address adder) -- invisible outside, because the T-state accounting below
// (`ahead`) never depended on how many clocks a micro-op takes; at 20 clocks
// a T-state the core is still far ahead of real time. EXX is a bank bit on the
// BC / DE / HL rows, not a copy. The file is written with the reset values of
// the flops it replaces (all 0, SP ffff) by a 16-clock S_CLR after reset.
// The alternate A and flags are SWAPPED by EX AF, as before.
//
`timescale 1ns/1ps

module dsb_z80 (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        tick,          // one real T-state

  // memory, byte-wide, request held until ack
  output logic        m_req,
  output logic        m_we,
  output logic [15:0] m_addr,
  output logic  [7:0] m_wdata,
  input  logic        m_ack,
  input  logic  [7:0] m_rdata,

  // I/O, one-cycle strobes at the real T-time
  output logic        io_rd,
  output logic        io_wr,
  output logic  [7:0] io_addr,
  output logic  [7:0] io_wdata,
  input  logic  [7:0] io_rdata,

  // the maskable interrupt, level, active high (the UART's RxRDY & RxE)
  input  logic        irq,

  output logic        trap,          // an opcode outside the census was executed
  output logic [15:0] trap_pc,
  output logic [15:0] trap_cnt,
  output logic [15:0] dbg_pc
);

`include "dsb_z80_ucode.svh"

  // INT is sampled IRQ_S T-states before the boundary. 0: at it, which is
  // where tv80s decides (measured on the bench: 1 took 4 of the first 8 of
  // STCC's interrupts one instruction late).
  localparam int IRQ_S = 0;

  // ---------------------------------------------------------------- state
  logic [7:0]  A, Ax;                // A and its alternate
  logic        fS, fZ, fC, xS, xZ, xC;
  logic        xb;                   // EXX: which bank of BC / DE / HL
  /* verilator lint_off UNUSEDSIGNAL */
  logic [7:0]  IR;                   // bit 6 is never decoded
  /* verilator lint_on UNUSEDSIGNAL */
  logic [7:0]  dat;
  logic [1:0]  pfx;
  logic signed [11:0] ahead;
  logic        iff1, ei_blk;
  logic [11:0] irq_age;              // ticks INT has been high (saturating)
  logic [3:0]  clr;                  // S_CLR's row
  logic        intm;                 // in the IM 1 sequence: RST's vector is 38

  // S_FETCH 0 and S_FWAIT 1 are read by the bench (dsb_z80_harness)
  typedef enum logic [3:0] {S_FETCH = 4'd0, S_FWAIT = 4'd1, S_DISP = 4'd2, S_RA = 4'd3,
                            S_EX = 4'd4, S_IO = 4'd5, S_FADR = 4'd6, S_PFX = 4'd7,
                            S_CLR = 4'd8} st_t;
  st_t st;

  // ---------------------------------------------------------------- micro-op
  logic [7:0]    upc, upc_n;
  logic [UW-1:0] uw;
  always_ff @(posedge clk) uw <= urom[upc_n];
  logic [7:0] ent_q;
`ifdef DSB_UENT_LOGIC
  always_ff @(posedge clk) ent_q <= uent_f({pfx, m_rdata});    // valid in S_DISP
`else
  always_ff @(posedge clk) ent_q <= uent[{pfx, m_rdata}];      // valid in S_DISP
`endif

  wire [1:0] f_mem  = uw[39:38];
  wire [2:0] f_asrc = uw[37:35];
  wire [2:0] f_aoff = uw[34:32];
  wire [2:0] f_awb  = uw[31:29];
  wire [1:0] f_wsrc = uw[28:27];
  wire [3:0] f_wt   = uw[26:23];
  wire [3:0] f_alu  = uw[22:19];
  wire [1:0] f_ysel = uw[18:17];
  wire       f_fz   = uw[16];
  wire       f_fc   = uw[15];
  wire [1:0] f_nxt  = uw[14:13];
  wire [1:0] f_csel = uw[12:11];
  wire [2:0] f_io   = uw[10:8];
  wire [4:0] f_tst  = uw[7:3];
  wire [2:0] f_rb   = uw[2:0];

  /* verilator lint_off UNUSEDPARAM */
  localparam logic [3:0] A_PASS = 4'd0, A_IRALU = 4'd1, A_IRROT = 4'd2, A_INC = 4'd3,
                         A_DEC = 4'd4, A_BIT = 4'd5, A_AGUC = 4'd6, A_CPL = 4'd7,
                         A_SBC16 = 4'd8, A_EXX = 4'd9, A_EXAF = 4'd10, A_EI = 4'd11,
                         A_DI = 4'd12;
  /* verilator lint_on UNUSEDPARAM */
  localparam logic [3:0] RF_PC = 4'd3, RF_SP = 4'd4, RF_TMP = 4'd6;

  // ---------------------------------------------------------------- register file
  // Rows: 0 BC, 1 DE, 2 HL (8-10 their alternates, by xb), 3 PC, 4 SP, 5 IY,
  // 6 TMP. One M10K per byte lane, true dual-port. A port's address is its
  // write row in the cycle it writes, else its read row; nothing reads a port
  // in the cycle after it wrote (the next micro-op reads first).
  function automatic logic [3:0] row(input logic [2:0] r, input logic bank);
    row = {bank && (r < 3'd3), r};
  endfunction
  logic        we_a, we_bh, we_bl;
  logic  [3:0] pa, pb;
  logic [15:0] wd_a;
  logic  [7:0] wd_b;
  logic [15:0] qa, qb;
  (* ramstyle = "M10K, no_rw_check" *) logic [7:0] rf_h [16];
  (* ramstyle = "M10K, no_rw_check" *) logic [7:0] rf_l [16];
  // unwritten rows read 0xFF until S_CLR has written them
  initial for (int i = 0; i < 16; i++) begin rf_h[i] = 8'hff; rf_l[i] = 8'hff; end
  always_ff @(posedge clk) begin
    if (we_a) rf_h[pa] <= wd_a[15:8];
    qa[15:8] <= rf_h[pa];
  end
  always_ff @(posedge clk) begin
    if (we_a) rf_l[pa] <= wd_a[7:0];
    qa[7:0] <= rf_l[pa];
  end
  always_ff @(posedge clk) begin
    if (we_bh) rf_h[pb] <= wd_b;
    qb[15:8] <= rf_h[pb];
  end
  always_ff @(posedge clk) begin
    if (we_bl) rf_l[pb] <= wd_b;
    qb[7:0] <= rf_l[pb];
  end

  // ---------------------------------------------------------------- AGU
  // sbc hl,de is HL + ~DE + !C through the same adder. S_FADR is the fetch's
  // PC + 1 through it, and S_CLR's reset values are 0 + 0 and 0 + ffff (SP):
  // RST's base, {IR[5:3], 000}, is 0 there, IR being 0 from reset to the
  // first fetch.
  wire        fadr  = (st == S_FADR);
  wire        clr_s = (st == S_CLR);
  wire        sbc16 = !fadr && !clr_s && (f_alu == A_SBC16);
  wire  [2:0] aoff  = fadr ? 3'd1 : clr_s ? ((clr == RF_SP) ? 3'd2 : 3'd0) : f_aoff;
  // (the IM 1 interrupt's vector is RST 38's: IR[5:3] forced to 7 by intm,
  // where the core used to load IR with ff)
  wire [15:0] abase = ((!fadr && f_asrc == 3'd7) || clr_s) ? {10'd0, IR[5:3] | {3{intm}}, 3'd0} : qa;   // RST / IM 1
  logic [15:0] aoffv;
  always_comb begin
    case (aoff)
      3'd0: aoffv = 16'h0000; 3'd1: aoffv = 16'h0001; 3'd2: aoffv = 16'hffff;
      3'd3: aoffv = 16'hfffe; 3'd4: aoffv = sbc16 ? ~qb : qb; 3'd5: aoffv = {{8{dat[7]}}, dat};
      default: aoffv = qb;          // BC, HL
    endcase
  end
  wire [16:0] asum = {1'b0, abase} + {1'b0, aoffv} + {16'd0, sbc16 & !fC};
  // post-increment (read at the base, write back base+1) vs offset address
  wire        a_post = (f_awb != 3'd7) && (f_aoff == 3'd1);
  wire [15:0] maddr  = a_post ? abase : asum[15:0];

  // ---------------------------------------------------------------- ALU
  wire        is_rd = (f_mem == 2'd1);
  wire [7:0]  din   = is_rd ? m_rdata : dat;        // a read's data, on its ack
  // a register by number (7 A, else a byte of port B's row)
  wire [2:0]  yn = (f_ysel == 2'd0) ? IR[2:0] : (f_ysel == 2'd1) ? IR[5:3] : 3'd0;
  wire [7:0]  Y  = (f_ysel == 2'd2) ? din : (yn == 3'd7) ? A : yn[0] ? qb[7:0] : qb[15:8];
  // the 8-bit group by IR[5:3]: add adc sub sbc and xor or cp. One adder:
  // A + (Y or ~Y) + carry-in; a subtract's carry out is the inverse borrow.
  wire [2:0] grp   = IR[5:3];
  wire       g_ar  = !grp[2] || (grp == 3'd7);      // arithmetic (else logic)
  wire       g_sub = grp[1] && g_ar;                // sub, sbc, cp
  wire       g_cin = g_sub ? !(grp[0] && fC && !grp[2]) : (grp[0] && fC);
  wire [8:0] g_sum = {1'b0, A} + {1'b0, g_sub ? ~Y : Y} + {8'd0, g_cin};
  logic [7:0] alu_r, fl_v;          // result; the value S and Z are taken from
  logic       alu_c;
  always_comb begin
    alu_r = Y; alu_c = fC; fl_v = Y;
    case (f_alu)
      A_IRALU: begin
        if (g_ar) begin
          alu_r = (grp == 3'd7) ? A : g_sum[7:0];             // cp leaves A
          alu_c = g_sub ? !g_sum[8] : g_sum[8];
          fl_v  = g_sum[7:0];
        end else begin
          case (grp[1:0])
            2'd0: alu_r = A & Y;
            2'd1: alu_r = A ^ Y;
            default: alu_r = A | Y;
          endcase
          alu_c = 1'b0; fl_v = alu_r;
        end
      end
      A_IRROT: begin
        if (U_UNION) begin
          case (grp)
            3'd0: begin alu_r = {Y[6:0], Y[7]}; alu_c = Y[7]; end     // rlc
            3'd1: begin alu_r = {Y[0], Y[7:1]}; alu_c = Y[0]; end     // rrc
            3'd2: begin alu_r = {Y[6:0], fC};   alu_c = Y[7]; end     // rl
            3'd3: begin alu_r = {fC, Y[7:1]};   alu_c = Y[0]; end     // rr
            default: begin alu_r = {Y[6:0], 1'b0}; alu_c = Y[7]; end  // sla
          endcase
        end else begin
          // R1004: STCC rotates by rlc (rlca), rrc (rrca) and rr (rra) only
          if (!grp[0])      begin alu_r = {Y[6:0], Y[7]}; alu_c = Y[7]; end   // rlc
          else if (!grp[1]) begin alu_r = {Y[0], Y[7:1]}; alu_c = Y[0]; end   // rrc
          else              begin alu_r = {fC, Y[7:1]};   alu_c = Y[0]; end   // rr
        end
        fl_v = alu_r;
      end
      A_INC:   begin alu_r = Y + 8'd1; fl_v = alu_r; end
      A_DEC:   begin alu_r = Y - 8'd1; fl_v = alu_r; end
      A_CPL:   alu_r = ~Y;
      A_AGUC:  alu_c = asum[16];
      A_SBC16: alu_c = !asum[16];
      default: ;
    endcase
  end
  // S and Z: from fl_v, except bit (Z = the bit clear, S = bit 7 set) and
  // sbc hl,de (16-bit)
  logic alu_z, alu_sgn;
  always_comb begin
    case (f_alu)
      // R1004: neither program tests bit 7 (STCC bits 0-4), so on the STCC
      // build bit's S is 0 -- what the Z80 gives for every bit it tests
      A_BIT:   begin alu_z = !Y[IR[5:3]]; alu_sgn = U_UNION && (IR[5:3] == 3'd7) && Y[7]; end
      A_SBC16: begin alu_z = (asum[15:0] == 16'd0); alu_sgn = asum[15]; end
      default: begin alu_z = (fl_v == 8'd0); alu_sgn = fl_v[7]; end
    endcase
  end

  // ---------------------------------------------------------------- conditions
  wire [2:0] cc   = IR[7] ? IR[5:3] : {1'b0, IR[4:3]};
  logic      ccf;
  always_comb begin
    case (cc[2:1])
      2'd0: ccf = fZ;
      2'd1: ccf = fC;
      2'd3: ccf = fS;
      default: ccf = 1'b0;           // P/V: neither program tests it
    endcase
  end
  wire       ccv  = ccf ^ !cc[0];
  logic      cond;
  always_comb begin
    case (f_csel)
      2'd0: cond = ccv;
      2'd1: cond = (qb[15:8] != 8'd0);         // B (port B reads BC)
      2'd2: cond = (qb != 16'd0);              // BC
      default: cond = 1'b1;
    endcase
  end

  // ---------------------------------------------------------------- interrupt
  // At a boundary with interrupts enabled (and not the one right after EI),
  // wait for real time to reach the sampling point, then take INT if it was
  // high there: now, if on time; `irq_age` T ago or more, if behind.
  wire        int_arm  = iff1 && !ei_blk;
  wire        int_wait = int_arm && (ahead > 12'(IRQ_S));
  wire signed [12:0] int_need = 13'(IRQ_S) - 13'(ahead);    // >= 0 once not waiting
  wire        int_take = int_arm && !int_wait && irq && ($signed({1'b0, irq_age}) >= int_need);

  // ---------------------------------------------------------------- sequencing
  // A micro-op reads in S_RA and completes in S_EX when its memory access (if
  // any) is acknowledged; an I/O micro-op completes in S_IO.
  wire u_done = (st == S_EX) && (f_io == 3'd0) && ((f_mem == 2'd0) || m_ack);
  wire u_end  = (f_nxt == 2'd1) || (f_nxt == 2'd3) || (f_nxt == 2'd2 && !cond);
  wire pfx_byte = (pfx == 2'd0) && (m_rdata == 8'hcb || m_rdata == 8'hed || m_rdata == 8'hfd);

  always_comb begin
    upc_n = upc;
    if (st == S_FETCH && int_take)           upc_n = U_INT;
    else if (st == S_DISP)                   upc_n = ent_q;
    else if (u_done && !u_end)               upc_n = upc + 8'd1;
  end

  // the byte a micro-op writes: a register by number (7 is A), or TMP's
  wire [2:0] wn    = (f_wt == 4'd1) ? IR[5:3] : (f_wt == 4'd2) ? IR[2:0] : f_wt[2:0];
  wire       w_tmp = (f_wt == 4'd3) || (f_wt == 4'd4);
  wire       w_reg = (f_wt == 4'd1) || (f_wt == 4'd2) || f_wt[3];
  wire       w_a   = w_reg && (wn == 3'd7);
  // port B's read row: the pair of ysel's register, or a fixed one
  wire [2:0] rbr   = (f_rb == 3'd7) ? {1'b0, yn[2:1]} : (f_rb == 3'd4) ? 3'd6 : f_rb;

  always_comb begin
    // port A: the fetch's PC, S_FADR's PC + 1, a micro-op's base and its awb
    we_a = 1'b0; wd_a = asum[15:0];
    pa   = (st == S_FETCH || st == S_PFX) ? RF_PC : row(f_asrc, xb);
    if (clr_s) begin
      we_a = 1'b1; pa = clr;
    end else if (fadr) begin
      we_a = 1'b1; pa = RF_PC;
    end else if (u_done && f_awb != 3'd7) begin
      we_a = 1'b1; pa = row(f_awb, xb);
    end
    // port B: one other register, and the byte written
    wd_b  = alu_r;
    we_bh = 1'b0; we_bl = 1'b0;
    pb    = row(rbr, xb);
    if (u_done && (w_tmp || (w_reg && !w_a))) begin
      if (w_tmp) begin pb = RF_TMP; we_bh = (f_wt == 4'd4); we_bl = (f_wt == 4'd3); end
      else begin pb = row({1'b0, wn[2:1]}, xb); we_bh = !wn[0]; we_bl = wn[0]; end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      A <= 8'hff; Ax <= 8'h00; xb <= 1'b0; clr <= '0; intm <= 1'b0;
      fS <= 1'b1; fZ <= 1'b1; fC <= 1'b1; xS <= 1'b0; xZ <= 1'b0; xC <= 1'b0;
      IR <= '0; dat <= '0; pfx <= '0;
      ahead <= '0; st <= S_CLR; upc <= '0; iff1 <= 1'b0; ei_blk <= 1'b0; irq_age <= '0;
      m_req <= 1'b0; m_we <= 1'b0; m_addr <= '0; m_wdata <= '0;
      io_rd <= 1'b0; io_wr <= 1'b0; io_addr <= '0; io_wdata <= '0;
      trap <= 1'b0; trap_pc <= '0; trap_cnt <= '0;
    end else begin
      logic signed [11:0] addT;
      addT = 12'sd0;
      io_rd <= 1'b0; io_wr <= 1'b0;
      upc <= upc_n;
      if (m_ack) m_req <= 1'b0;
      if (!irq) irq_age <= '0;
      else if (tick && irq_age != 12'hfff) irq_age <= irq_age + 12'd1;

      case (st)
        // the register file's reset values, once
        S_CLR: begin clr <= clr + 4'd1; if (clr == 4'd15) st <= S_FETCH; end

        // PC is read here (port A), issued and incremented in S_FADR
        S_FETCH: if (int_take) begin
          // IM 1: RST 38 with the interrupt's T-states (micro-op U_INT)
          iff1 <= 1'b0; intm <= 1'b1; st <= S_RA;
        end else if (!int_wait && ahead <= 12'sd32) begin
          ei_blk <= 1'b0; intm <= 1'b0; st <= S_FADR;
        end
        S_FADR: begin m_req <= 1'b1; m_we <= 1'b0; m_addr <= qa; st <= S_FWAIT; end
        S_FWAIT: if (m_ack) begin
          if (pfx_byte) begin
            pfx <= (m_rdata == 8'hcb) ? 2'd1 : (m_rdata == 8'hed) ? 2'd2 : 2'd3;
            st <= S_PFX;                                     // the second opcode byte
          end else begin
            IR <= m_rdata; st <= S_DISP;
          end
        end
        S_PFX: st <= S_FADR;

        S_DISP: st <= S_RA;
        S_RA:   st <= S_EX;

        S_EX: begin
          // issue this micro-op's memory access once
          if (f_mem != 2'd0 && !m_req && !m_ack) begin
            m_req <= 1'b1; m_we <= (f_mem == 2'd2); m_addr <= maddr;
            case (f_wsrc)
              2'd0: m_wdata <= alu_r;
              2'd1: m_wdata <= A;
              2'd2: m_wdata <= qb[15:8];
              default: m_wdata <= qb[7:0];
            endcase
          end
          if (f_io != 3'd0) begin
            // charge the instruction's T-states, then wait for real time
            addT = 12'(f_tst);
            case (f_io)
              3'd1: begin io_addr <= dat;  io_wdata <= A; end
              3'd2: if (U_UNION) begin io_addr <= qb[7:0]; io_wdata <= A; end   // out (c),a: Star Wars only
              3'd3: begin io_addr <= qb[7:0]; io_wdata <= dat;  end
              default: io_addr <= dat;
            endcase
            st <= S_IO;
          end
          if (u_done) begin
            if (is_rd) dat <= m_rdata;
            if (w_a) A <= alu_r;      // the rest of the writes are the register file's
            if (f_fz) begin fZ <= alu_z; fS <= alu_sgn; end
            if (f_fc) fC <= alu_c;
            // the instructions that are only an action
            case (f_alu)
              A_EXX: xb <= !xb;
              A_EXAF: begin
                A <= Ax; Ax <= A;
                {fS, fZ, fC} <= {xS, xZ, xC}; {xS, xZ, xC} <= {fS, fZ, fC};
              end
              A_EI: begin iff1 <= 1'b1; ei_blk <= 1'b1; end
              A_DI: iff1 <= 1'b0;
              default: ;
            endcase
            st <= S_RA;
            if (u_end) begin
              addT = 12'(f_tst);
              pfx <= 2'd0; st <= S_FETCH;
              if (f_nxt == 2'd3) begin
                trap <= 1'b1; trap_pc <= qa;
                if (trap_cnt != 16'hffff) trap_cnt <= trap_cnt + 16'd1;
              end
            end
          end
        end

        // the strobe a real Z80 (and tv80s) ends one T before the instruction does
        S_IO: if (ahead <= 12'sd1) begin
          if (f_io == 3'd4) begin io_rd <= 1'b1; A <= io_rdata; end
          else io_wr <= 1'b1;
          pfx <= 2'd0; st <= S_FETCH;
        end
        default: st <= S_FETCH;
      endcase
      // one T of real time per tick (floored, so a long stall cannot wrap)
      ahead <= ahead + addT - ((tick && ahead > -12'sd2000) ? 12'sd1 : 12'sd0);
    end
  end

  // the bench's view of PC (not wired on the board)
`ifdef VERILATOR
  assign dbg_pc = {rf_h[RF_PC], rf_l[RF_PC]};
`else
  assign dbg_pc = 16'h0000;
`endif

endmodule
