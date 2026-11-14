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
// MICROCODED. A regular datapath -- seven 8-bit registers and their
// alternates, PC, SP, IY, a 16-bit TMP, one 16-bit address adder, one 8-bit
// ALU -- is driven by 153 40-bit micro-ops (173 with --union) in one M10K
// (tools/dsb/gen_z80_ucode.py writes them), dispatched by a 1024 x 8 table
// ({prefix, opcode}; prefix 0 none, 1 CB, 2 ED, 3 FD) in another M10K or, with
// DSB_UENT_LOGIC defined, as logic with the same one-cycle registered output.
// The alternate registers are SWAPPED by EXX / EX AF, not banked, so every
// register read port is as narrow as Model 1's.
//
// What the rest of the board can see is preserved exactly:
//   - every instruction takes the Z80's documented T-states (taken and
//     untaken branches, LDIR per iteration), carried on the micro-op that
//     ends it, so the firmware's loops, fades and delays run at real speed;
//   - every I/O access lands at the T-state at which tv80s commits it;
//   - an interrupt is taken at the instruction boundary at which tv80s takes
//     it: IFF1 set, not the instruction right after EI, INT high when real
//     time reaches the boundary. Accepting it is RST 38 with the Z80's 13 T-states.
// Only S, Z and C exist, the only flags either program reads (S and Z are
// always written together by the instructions both programs use). IFF2 is
// not kept: nothing either program executes reads it (no RETN, no LD A,I).
//
// TIMING. `ahead` is how far the core's T-time is ahead of real T-time: an
// instruction adds its T-states, each `tick` takes one away. Fetching waits
// while the core is ahead, and an I/O access waits until real time reaches
// it, so SDRAM latency never moves an I/O event; a stall only makes the core
// run back to back until it has caught up. With interrupts enabled the core
// may not pass an instruction boundary until real time reaches the point where
// INT is sampled; if it arrives there late (behind real time, after a stall)
// it decides from how long INT has been high (`irq_age`), so the answer is the
// one it would have had on time.

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
  logic [7:0]  R [8];                // B C D E H L - A, by Z80 register number
  logic [7:0]  Rx [8];               // their alternates (6 unused)
  logic        fS, fZ, fC, xS, xZ, xC;
  logic [15:0] PC, SP, IY, TMP;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [7:0]  IR;                   // bit 6 is never decoded
  /* verilator lint_on UNUSEDSIGNAL */
  logic [7:0]  dat;
  logic [1:0]  pfx;
  logic signed [11:0] ahead;
  logic        iff1, ei_blk;
  logic [11:0] irq_age;              // ticks INT has been high (saturating)

  typedef enum logic [2:0] {S_FETCH, S_FWAIT, S_DISP, S_RUN, S_IO} st_t;
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
  wire [2:0] f_wsrc = uw[28:26];
  wire [2:0] f_rmod = uw[25:23];
  wire [2:0] f_ridx = uw[22:20];
  wire [3:0] f_alu  = uw[19:16];
  wire [1:0] f_ysel = uw[15:14];
  wire       f_fz   = uw[13];
  wire       f_fc   = uw[12];
  wire [1:0] f_nxt  = uw[11:10];
  wire [1:0] f_csel = uw[9:8];
  wire [2:0] f_io   = uw[7:5];
  wire [4:0] f_tst  = uw[4:0];

  /* verilator lint_off UNUSEDPARAM */
  localparam logic [3:0] A_PASS = 4'd0, A_IRALU = 4'd1, A_IRROT = 4'd2, A_INC = 4'd3,
                         A_DEC = 4'd4, A_BIT = 4'd5, A_AGUC = 4'd6, A_CPL = 4'd7,
                         A_SBC16 = 4'd8, A_EXX = 4'd9, A_EXAF = 4'd10, A_EI = 4'd11,
                         A_DI = 4'd12;
  /* verilator lint_on UNUSEDPARAM */

  wire [15:0] BC = {R[0], R[1]}, DE = {R[2], R[3]}, HL = {R[4], R[5]};

  // ---------------------------------------------------------------- AGU
  // sbc hl,de is HL + ~DE + !C through the same adder
  wire        sbc16 = (f_alu == A_SBC16);
  logic [15:0] abase, aoffv;
  always_comb begin
    case (f_asrc)
      3'd0: abase = PC;  3'd1: abase = SP;  3'd2: abase = BC;
      3'd3: abase = DE;  3'd4: abase = HL;  3'd5: abase = TMP;
      3'd6: abase = IY;  default: abase = {10'd0, IR[5:3], 3'd0};   // RST / IM 1
    endcase
    case (f_aoff)
      3'd0: aoffv = 16'h0000; 3'd1: aoffv = 16'h0001; 3'd2: aoffv = 16'hffff;
      3'd3: aoffv = 16'hfffe; 3'd4: aoffv = sbc16 ? ~DE : DE; 3'd5: aoffv = {{8{dat[7]}}, dat};
      3'd6: aoffv = BC;       default: aoffv = HL;
    endcase
  end
  wire [16:0] asum = {1'b0, abase} + {1'b0, aoffv} + {16'd0, sbc16 & !fC};
  // post-increment (read at the base, write back base+1) vs offset address
  wire        a_post = (f_awb != 3'd0) && (f_aoff == 3'd1);
  wire [15:0] maddr  = a_post ? abase : asum[15:0];

  // ---------------------------------------------------------------- ALU
  wire        is_rd = (f_mem == 2'd1);
  wire [7:0]  din   = is_rd ? m_rdata : dat;        // a read's data, on its ack
  logic [7:0] Y;
  always_comb begin
    case (f_ysel)
      2'd0: Y = R[IR[2:0]];
      2'd1: Y = R[IR[5:3]];
      2'd2: Y = din;
      default: Y = R[0];
    endcase
  end
  // the 8-bit group by IR[5:3]: add adc sub sbc and xor or cp. One adder:
  // A + (Y or ~Y) + carry-in; a subtract's carry out is the inverse borrow.
  wire [2:0] grp   = IR[5:3];
  wire       g_ar  = !grp[2] || (grp == 3'd7);      // arithmetic (else logic)
  wire       g_sub = grp[1] && g_ar;                // sub, sbc, cp
  wire       g_cin = g_sub ? !(grp[0] && fC && !grp[2]) : (grp[0] && fC);
  wire [8:0] g_sum = {1'b0, R[7]} + {1'b0, g_sub ? ~Y : Y} + {8'd0, g_cin};
  logic [7:0] alu_r, fl_v;          // result; the value S and Z are taken from
  logic       alu_c;
  always_comb begin
    alu_r = Y; alu_c = fC; fl_v = Y;
    case (f_alu)
      A_IRALU: begin
        if (g_ar) begin
          alu_r = (grp == 3'd7) ? R[7] : g_sum[7:0];          // cp leaves A
          alu_c = g_sub ? !g_sum[8] : g_sum[8];
          fl_v  = g_sum[7:0];
        end else begin
          case (grp[1:0])
            2'd0: alu_r = R[7] & Y;
            2'd1: alu_r = R[7] ^ Y;
            default: alu_r = R[7] | Y;
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
      2'd1: cond = (R[0] != 8'd0);
      2'd2: cond = (BC != 16'd0);
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
  // A micro-op completes when its memory access (if any) is acknowledged; an
  // I/O micro-op completes in S_IO.
  wire u_done = (st == S_RUN) && (f_io == 3'd0) && ((f_mem == 2'd0) || m_ack);
  wire u_end  = (f_nxt == 2'd1) || (f_nxt == 2'd3) || (f_nxt == 2'd2 && !cond);
  wire pfx_byte = (pfx == 2'd0) && (m_rdata == 8'hcb || m_rdata == 8'hed || m_rdata == 8'hfd);

  always_comb begin
    upc_n = upc;
    if (st == S_FETCH && int_take)           upc_n = U_INT;
    else if (st == S_DISP)                   upc_n = ent_q;
    else if (u_done && !u_end)               upc_n = upc + 8'd1;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 8; i++) begin R[i] <= (i == 7) ? 8'hff : 8'h00; Rx[i] <= 8'h00; end
      fS <= 1'b1; fZ <= 1'b1; fC <= 1'b1; xS <= 1'b0; xZ <= 1'b0; xC <= 1'b0;
      PC <= '0; SP <= 16'hffff; IY <= '0; TMP <= '0; IR <= '0; dat <= '0; pfx <= '0;
      ahead <= '0; st <= S_FETCH; upc <= '0; iff1 <= 1'b0; ei_blk <= 1'b0; irq_age <= '0;
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
        S_FETCH: if (int_take) begin
          // IM 1: RST 38 with the interrupt's T-states (micro-op U_INT)
          iff1 <= 1'b0; IR <= 8'hff; st <= S_RUN;
        end else if (!int_wait && ahead <= 12'sd32) begin
          ei_blk <= 1'b0;
          m_req <= 1'b1; m_we <= 1'b0; m_addr <= PC; st <= S_FWAIT;
        end
        S_FWAIT: if (m_ack) begin
          PC <= PC + 16'd1;
          if (pfx_byte) begin
            pfx <= (m_rdata == 8'hcb) ? 2'd1 : (m_rdata == 8'hed) ? 2'd2 : 2'd3;
            m_req <= 1'b1; m_addr <= PC + 16'd1;           // the second opcode byte
          end else begin
            IR <= m_rdata; st <= S_DISP;
          end
        end

        S_DISP: st <= S_RUN;

        S_RUN: begin
          // issue this micro-op's memory access once
          if (f_mem != 2'd0 && !m_req && !m_ack) begin
            m_req <= 1'b1; m_we <= (f_mem == 2'd2); m_addr <= maddr;
            case (f_wsrc)
              3'd0: m_wdata <= R[f_ridx];
              3'd1: m_wdata <= PC[15:8];
              3'd2: m_wdata <= PC[7:0];
              3'd4: m_wdata <= TMP[15:8];
              3'd5: m_wdata <= TMP[7:0];
              default: m_wdata <= alu_r;
            endcase
          end
          if (f_io != 3'd0) begin
            // charge the instruction's T-states, then wait for real time
            addT = 12'(f_tst);
            case (f_io)
              3'd1: begin io_addr <= dat;  io_wdata <= R[7]; end
              3'd2: if (U_UNION) begin io_addr <= R[1]; io_wdata <= R[7]; end   // out (c),a: Star Wars only
              3'd3: begin io_addr <= R[1]; io_wdata <= dat;  end
              default: io_addr <= dat;
            endcase
            st <= S_IO;
          end
          if (u_done) begin
            if (is_rd) dat <= m_rdata;
            // 8-bit register write: always the ALU's result (a load passes data)
            case (f_rmod)
              3'd1: R[IR[5:3]] <= alu_r;
              3'd2: R[IR[2:0]] <= alu_r;
              3'd3: R[f_ridx]  <= alu_r;
              3'd4: TMP[7:0]   <= alu_r;
              3'd5: TMP[15:8]  <= alu_r;
              default: ;
            endcase
            // 16-bit write back from the address adder
            case (f_awb)
              3'd1: PC <= asum[15:0];
              3'd2: SP <= asum[15:0];
              3'd3: {R[0], R[1]} <= asum[15:0];
              3'd4: {R[2], R[3]} <= asum[15:0];
              3'd5: {R[4], R[5]} <= asum[15:0];
              3'd6: TMP <= asum[15:0];
              3'd7: IY <= asum[15:0];
              default: ;
            endcase
            if (f_fz) begin fZ <= alu_z; fS <= alu_sgn; end
            if (f_fc) fC <= alu_c;
            // the instructions that are only an action
            case (f_alu)
              A_EXX: for (int i = 0; i < 6; i++) begin R[i] <= Rx[i]; Rx[i] <= R[i]; end
              A_EXAF: begin
                R[7] <= Rx[7]; Rx[7] <= R[7];
                {fS, fZ, fC} <= {xS, xZ, xC}; {xS, xZ, xC} <= {fS, fZ, fC};
              end
              A_EI: begin iff1 <= 1'b1; ei_blk <= 1'b1; end
              A_DI: iff1 <= 1'b0;
              default: ;
            endcase
            if (u_end) begin
              addT = 12'(f_tst);
              pfx <= 2'd0; st <= S_FETCH;
              if (f_nxt == 2'd3) begin
                trap <= 1'b1; trap_pc <= PC;
                if (trap_cnt != 16'hffff) trap_cnt <= trap_cnt + 16'd1;
              end
            end
          end
        end

        // the strobe a real Z80 (and tv80s) ends one T before the instruction does
        S_IO: if (ahead <= 12'sd1) begin
          if (f_io == 3'd4) begin io_rd <= 1'b1; R[7] <= io_rdata; end
          else io_wr <= 1'b1;
          pfx <= 2'd0; st <= S_FETCH;
        end
        default: st <= S_FETCH;
      endcase
      // one T of real time per tick (floored, so a long stall cannot wrap)
      ahead <= ahead + addT - ((tick && ahead > -12'sd2000) ? 12'sd1 : 12'sd0);
    end
  end

  assign dbg_pc = PC;

endmodule
