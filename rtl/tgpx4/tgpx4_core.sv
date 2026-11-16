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
// Fujitsu MB86235 "TGPx4", Model 2C's coprocessor -- SIZING SKELETON (R920).
//
// NOT WIRED INTO Model2.sv AND NOT VERIFIED AGAINST MAME. It exists to be
// measured by quartus_map: every structure the finished core needs is here
// at its intended size and shape, decoded from MAME 0.289's interpreter
// (mb86235ops.cpp, which model2c runs -- ENABLE_DRC is 0), but no instruction
// stream has been run through it. See docs/model2-family-hardware.md,
// "Sizing the two new processors", for what it covers and what it leaves out.
//
// THE MICROARCHITECTURE: ONE INSTRUCTION AT A TIME, ITS PARTS IN SEQUENCE.
//
// The chip issues a 64-bit word a clock at 20 MHz: an ALU op, a multiply and
// up to two transfers together. clk_sys is 80 MHz, four clocks a word, and
// R888 / R896 measured the 2A games' TGP using at most ~30% of its frame
// budget on MAME's model of the part. So nothing here is duplicated for
// speed. The word's parts run one after another through one of each unit,
// in MAME's own order -- transfer sources, ALU and multiplier sources, the
// ALU, the multiplier, transfer destinations:
//
//   S_FETCH  only when the next word is not in yet: it is fetched in S_DEC
//            (its address is always known there -- a branch's target applies
//            one word later, after the delay slot) and held in nx_ir
//   S_DEC    the four ALU / multiplier operands from the register file (four
//            MLAB read ports), PR; source A's address (AGU) and RAM read;
//            FIFO stalls; branch condition
//   S_PR2    only when both ALU and multiplier take PR: the second PR read
//   S_XA     source A arrives (RAM / RF / external); source B's address
//   S_XB     source B arrives
//   S_WXA    destination A written (RF, RAM, special, FIFO out, external);
//            control flow resolved
//   S_WXB    destination B written
//   S_WAIT   one clock, for the words that may not end in S_WXA (control
//            words, a write to ST) and the words with operations alone
//
// The word ends in whichever of these is its last (eow), and the next word,
// already fetched, is accepted in the same clock.
//
// R1006: THE ALU AND MULTIPLIER RESULTS ARE WRITTEN BEHIND THE SEQUENCER. A
// word's operations start in the clock after S_DEC; the word ends when its
// transfers are done, whether or not its results have arrived, and the next
// word runs while they are in flight. A result is registered as it arrives
// (alu_r / mul_r, with its descriptor: where it goes, which flags) and written
// to the register file and ST in a later clock by the writer below, not by a
// state. MAME's order is kept by a scoreboard and three rules, checked in
// S_DEC (dec_hz): a word does not start while any register it reads or writes
// (operands, transfer sources and destinations, its own results' targets) has
// a result still to be written; a word that reads or writes ST does not start
// while any result is still to be written; and an operation is issued only
// when the operations of its class (ALU, multiplier) still in flight are on
// the same pipelined unit (so they arrive in issue order, two or more clocks
// apart), with FRCP / FRSQ alone. A word's own result is held until its
// transfer sources have been read (MAME reads every source before the ALU),
// and a transfer to the same register, or the multiply to the ALU's register,
// wins over it (MAME's order) -- decided from the decode. MAME's NaN bits ride
// with the operation (the operand registers are reloaded by later words).
// The ALU NOP is not an operation at all here (it was a full ALU pass).
//
// States a word does not need are skipped. Before R1006 an ALU + multiply +
// one transfer word took 8 clocks (FP latency under the transfer), a
// transfer alone 3, an integer op 3 (R920's measured table).
//
// The register file is MAME's AA0-7 / AB0-7 / MA0-7 / MB0-7, index {sel1,
// sel0, n}: 00 MA, 01 AA, 10 MB, 11 AB. R1006: two banks of 16, AA / AB (the
// ALU's operands) and MA / MB (the multiplier's), each with its own write port
// and two MLAB read copies -- the same four 2-MLAB copies as the single 32 x
// 32 file had, now with two writes a clock. A transfer source reads both banks
// and takes the one its code names.
//
// The shared units: fp_add and fp_mul (rtl/tgp, the 2A TGP's, SUBNORM as
// MAME's host floats), fp_div (FRCP = 1 / x, and FRSQ = 1 / sqrt), the new
// tgpx4_fsqrt and tgpx4_cvt, an integer ALU / shifter, and a 32 x 32 integer
// multiply (DSP).
//
// LEFT OUT (bounded in the document): FLOG (MAME computes ln(x) / 0.30103,
// not log2 -- the census decides whether any game runs it), the PDR / DDR
// LED outputs, PUSH / POP of a register code the stack cannot hold, and the
// illegal forms MAME stops on (here they do nothing and raise dbg_bad).

`timescale 1ns/1ps

module tgpx4_core #(
  // program memory: 4096 = all on chip; 1024 / 2048 = cache lines over SDRAM
  parameter int unsigned PLINES  = 1024,
  // subnormal results as MAME's host floats give them (fp_add / fp_mul)
  parameter bit          SUBNORM = 1'b1,
  // R1006: the copro data ROM's read cache, 2^XC_AW words direct-mapped in
  // M10K (12: 4 K words, 21 M10K); 0 = none
  parameter int unsigned XC_AW   = 12,
  // R1009: S_DEC's operands forwarded from the results written this clock
  // (0: a word on its predecessor's result waits a clock more)
  parameter bit          FWD     = 1'b1,
  // R1009: a register-file transfer source read in S_DEC when its bank's
  // first copy is free there (0: it is read in S_XA, as R924)
  parameter bit          XSRF    = 1'b1,
  // R1009 (measuring area): two ops of a class in flight (0: one), and a
  // control word's effect in S_DEC (0: in S_WXA, as R924)
  parameter bit          QD2     = 1'b1,
  parameter bit          CTLD    = 1'b1
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        run,          // copro_ctl1 bit 31 clear: booted

  // program upload, one 64-bit word (the wrapper packs the i960's pairs)
  input  logic        prog_we,
  input  logic [11:0] prog_addr,
  input  logic [63:0] prog_data,

  // cache refill from the SDRAM copy of the program
  output logic        pf_req,
  output logic [11:0] pf_addr,
  input  logic [63:0] pf_data,
  input  logic        pf_ack,

  // FIFOs (8 deep each, in the wrapper)
  input  logic [31:0] fi_data,
  input  logic        fi_valid,
  input  logic        fi_full,
  output logic        fi_pop,
  output logic        fi_clr,
  output logic [31:0] fo_data,
  output logic        fo_push,
  input  logic        fo_full,
  input  logic        fo_empty,
  output logic        fo_clr,

  // external bus: buffer RAM 0x400000, copro data ROM 0x800000 (24-bit words)
  output logic        ext_req,
  output logic        ext_we,
  output logic [23:0] ext_addr,
  output logic [31:0] ext_wdata,
  input  logic [31:0] ext_rdata,
  input  logic        ext_ack,
  input  logic        wq_busy,      // R1006: the wrapper's posted buffer RAM writes not all through

  output logic [11:0] dbg_pc,
  output logic        dbg_retire,
  output logic [31:0] dbg_pdr,
  output logic        dbg_bad
);

  // ======================================================== state
  typedef enum logic [3:0] {
    S_HALT, S_FETCH, S_DEC, S_PR2, S_XA, S_XB, S_WXA, S_WXB, S_WAIT, S_WA, S_FIN
  } st_e;
  st_e s;

  logic [63:0] ir;
  logic [63:0] nx_ir;          // the next word, fetched during this one
  logic        nx_v, pf_sent;
  logic [11:0] pc, delay_pc;
  logic [11:0] ir_pc;          // R924: the address of the word in ir (benches)
  logic        delay_slot;
  logic [31:0] st;
  logic [15:0] rpc, lpc;
  logic [23:0] eb, eo;
  logic [9:0]  sp;
  logic [15:0] modr;
  logic [31:0] pdr, ddr;
  logic [4:0]  prp, pwp;
  logic [11:0] pcs [0:3];
  logic [1:0]  pcp;
  logic [13:0] ar [0:7];

  localparam int F_AD = 0,  F_AU = 1,  F_AV = 2,  F_AZ = 3,  F_AN = 4;
  localparam int F_ZC = 8,  F_IL = 9,  F_NR = 10, F_ZD = 11;
  localparam int F_RP = 14, F_LP = 15;
  localparam int F_MD = 16, F_MU = 17, F_MV = 18, F_MZ = 19, F_MN = 20;
  localparam int F_F0 = 28, F_F1 = 29, F_F2 = 30;

  // ======================================================== program memory
  logic        pm_req;
  logic [11:0] pm_addr;
  logic        pm_valid;
  logic [63:0] pm_data;

  tgpx4_pmem #(.LINES(PLINES)) u_pmem (
    .clk(clk), .rst_n(rst_n),
    .rd_req(pm_req), .rd_addr(pm_addr), .rd_valid(pm_valid), .rd_data(pm_data),
    .prog_we(prog_we), .prog_addr(prog_addr), .prog_data(prog_data),
    .pf_req(pf_req), .pf_addr(pf_addr), .pf_data(pf_data), .pf_ack(pf_ack)
  );

  // ======================================================== decode
  logic [2:0] top;
  logic       is_ctl, is_imm, alu_one, alu_en, mul_en;
  assign top     = ir[63:61];
  assign is_ctl  = (top == 3'd2) || (top == 3'd6);
  assign is_imm  = (top == 3'd7);
  assign alu_one = ir[63];
  assign alu_en  = !is_imm && (!alu_one || ir[41]);
  assign mul_en  = !is_imm && (!alu_one || !ir[41]);
  // R1006: the operations that do something -- MAME's ALU NOP (0x07) changes
  // nothing (its operands are still read, so a PR operand still steps PR)
  logic alu_op, mul_op;
  assign alu_op = alu_en && (ir[60:56] != 5'h07);
  assign mul_op = mul_en;

  logic [4:0] aop, ai2, ao, mi2, mo, m2s, mdst;
  logic [3:0] ai1, mi1, m1s;
  logic       isfmul;
  assign aop  = ir[60:56];
  assign ai1  = ir[55:52];
  assign ai2  = ir[51:47];
  assign ao   = ir[46:42];
  assign mi1  = ir[40:37];
  assign mi2  = ir[36:32];
  assign mo   = ir[31:27];
  // alu1 forms reuse the ALU fields for a lone multiply
  assign m1s    = alu_one ? ai1 : mi1;
  assign m2s    = alu_one ? ai2 : mi2;
  assign mdst   = alu_one ? ao  : mo;
  assign isfmul = alu_one ? (aop != 5'd0) : ir[41];

  // MAME get_alu_second_src
  logic alu_src2;
  assign alu_src2 = !(((aop & 5'h1c) == 5'h1c) || ((aop & 5'h1e) == 5'h16) ||
                      ((aop & 5'h0f) == 5'h05) || ((aop & 5'h18) == 5'h08));

  logic alu_pr, mul_pr;
  assign alu_pr = alu_en && alu_src2 && (ai2[4:3] == 2'd2);
  assign mul_pr = mul_en && (m2s[4:3] == 2'd2);

  // ======================================================== register file
  // R1006: two banks of 16 -- A (AA / AB, index sel0 = 1) and M (MA / MB) --
  // each one write port and two read copies. In a bank, {sel1, n}.
  // rf_rd[0] / [1]: the ALU's operands (bank A); [2] / [3] the multiplier's
  // (bank M); in S_XA / S_XB copy 0 / 1 of both banks read transfer source A
  // / B, and the source's own bank is taken (xa_rd / xb_rd).
  logic        rfa_we, rfm_we;
  logic [3:0]  rfa_wa, rfm_wa;
  logic [31:0] rfa_wd, rfm_wd;
  logic [3:0]  rfa_ra [0:1], rfm_ra [0:1];
  logic [31:0] rfa_rd [0:1], rfm_rd [0:1];
  logic [31:0] rf_rd  [0:3];

  genvar gi;
  generate
    for (gi = 0; gi < 2; gi++) begin : g_rfa
      tgpx4_rf #(.AW(4)) u_rf (.clk(clk), .we(rfa_we), .wa(rfa_wa), .wd(rfa_wd), .ra(rfa_ra[gi]), .rd(rfa_rd[gi]));
    end
    for (gi = 0; gi < 2; gi++) begin : g_rfm
      tgpx4_rf #(.AW(4)) u_rf (.clk(clk), .we(rfm_we), .wa(rfm_wa), .wd(rfm_wd), .ra(rfm_ra[gi]), .rd(rfm_rd[gi]));
    end
  endgenerate
  assign rf_rd[0] = rfa_rd[0];
  assign rf_rd[1] = rfa_rd[1];
  assign rf_rd[2] = rfm_rd[0];
  assign rf_rd[3] = rfm_rd[1];

  // PR queue, 24 deep
  logic        pr_we;
  logic [31:0] pr_wd;
  logic [4:0]  pr_wa;          // pwp as it was: the write lands the clock after pwp steps
  logic [31:0] pr_rd;
  (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] prq [0:31];
  always_ff @(posedge clk) if (pr_we) prq[pr_wa] <= pr_wd;
  assign pr_rd = prq[prp];

  function automatic logic [4:0] prp_step(input logic [4:0] p, input logic [2:0] w);
    case (w[1:0])
      2'd1:    prp_step = (p == 5'd23) ? 5'd0  : p + 5'd1;
      2'd2:    prp_step = (p == 5'd0)  ? 5'd23 : p - 5'd1;
      2'd3:    prp_step = 5'd0;
      default: prp_step = p;
    endcase
  endfunction

  function automatic logic [31:0] cst(input logic [2:0] w, input logic fl);
    if (fl) begin
      case (w)
        3'd0: cst = 32'hbf800000;  3'd1: cst = 32'h00000000;
        3'd2: cst = 32'h3f000000;  3'd3: cst = 32'h3f800000;
        3'd4: cst = 32'h3fc00000;  3'd5: cst = 32'h40000000;
        3'd6: cst = 32'h40400000;  default: cst = 32'h40a00000;
      endcase
    end else begin
      case (w)
        3'd0: cst = 32'd0; 3'd1: cst = 32'd1; 3'd2: cst = 32'hffffffff;
        default: cst = 32'd0;
      endcase
    end
  endfunction

  // ======================================================== data RAMs A / B
  (* ramstyle = "M10K" *) logic [31:0] ram_a [0:1023];
  (* ramstyle = "M10K" *) logic [31:0] ram_b [0:1023];
  logic        ra_we, rb_we;
  logic [9:0]  ra_wa, rb_wa, ra_ra, rb_ra;
  logic [31:0] ra_wd, rb_wd, ra_q, rb_q;
  always_ff @(posedge clk) begin
    if (ra_we) ram_a[ra_wa] <= ra_wd;
    ra_q <= ram_a[ra_ra];
  end
  always_ff @(posedge clk) begin
    if (rb_we) ram_b[rb_wa] <= rb_wd;
    rb_q <= ram_b[rb_ra];
  end

  // ======================================================== R1006: the ROM read cache
  // The external reads of every 2C game so far are all copro data ROM
  // (0x800000-0x9fffff, R924 / R928 / R933), read-only, and the games read
  // the same tables over and over: STCC's race, 4 K words direct-mapped by
  // word, 84% hits (x4_deps on R1006's capture). A read's address (EB + EO)
  // is known in S_DEC: the cache is read there and answers in S_XA's first
  // clock; a miss goes to memory from there (one clock later than before) and
  // fills the line as it comes back. The ROM never changes under a running
  // game, so there is nothing to invalidate -- but a reset (a new game) sweeps
  // every line invalid, one a clock (4 K clocks; the TGPx4 boots milliseconds
  // later), through the write port: the array is never cleared in reset.
  localparam bit XC = (XC_AW != 0);
  localparam int XA_W = (XC_AW != 0) ? XC_AW : 1;
  localparam int XT_W = 20 - XA_W;               // tag: the rest of port 9's 20 address bits
  logic            xc_pend, xc_fill, xc_hit, xf_busy;
  logic            xc_spec, xc_hq;               // R1009: S_XA took the cache's word on trust; the tag compare, registered
  logic [XA_W-1:0] xf_cnt;
  logic [31:0]     xc_q;
  logic [XT_W:0]   xc_tq;                        // {valid, tag}
  logic [23:0]     x_dec_a;                      // the read's address, in S_DEC
  logic            x_dec_rom;
  assign x_dec_a   = eb + eo;
  assign x_dec_rom = XC && (x_dec_a[23:21] == 3'b100) && !xf_busy;
  logic            xc_we;
  logic [XA_W-1:0] xc_wa;
  generate if (XC) begin : g_xc
    (* ramstyle = "M10K, no_rw_check" *) logic [31:0]   xd_mem [0:(1<<XA_W)-1];
    (* ramstyle = "M10K, no_rw_check" *) logic [XT_W:0] xt_mem [0:(1<<XA_W)-1];
    always_ff @(posedge clk) begin
      if (xc_we) begin
        xd_mem[xc_wa] <= ext_rdata;
        xt_mem[xc_wa] <= xf_busy ? '0 : {1'b1, ext_addr[19:XA_W]};
      end
      xc_q  <= xd_mem[x_dec_a[XA_W-1:0]];
      xc_tq <= xt_mem[x_dec_a[XA_W-1:0]];
    end
  end else begin : g_noxc
    assign xc_q = 32'd0; assign xc_tq = '0;
  end endgenerate
  assign xc_hit = XC && xc_tq[XT_W] && (xc_tq[XT_W-1:0] == ext_addr[19:XA_W]);
  assign xc_we  = XC && (xf_busy || (s == S_XA && ext_req && ext_ack && xc_fill));
  assign xc_wa  = xf_busy ? xf_cnt : ext_addr[XA_W-1:0];
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin xf_busy <= XC; xf_cnt <= '0; end
    else if (xf_busy) begin xf_cnt <= xf_cnt + 1'b1; if (&xf_cnt) xf_busy <= 1'b0; end

  // ======================================================== transfer decode
  // Each word moves at most two values, A and B, each from a source to a
  // destination. Kinds:
  localparam logic [2:0] K_NONE = 3'd0, K_REG = 3'd1, K_MEM = 3'd2,
                         K_EXT = 3'd3, K_IMM = 3'd4;

  // R934: THE TRANSFER DECODE IS REGISTERED. It is a function of the word
  // alone, so it is computed from the word as it is taken (acc_word, at acc)
  // and held beside ir: xd == xdec(ir) at every clock (checked in Verilator,
  // below). Decoded from ir, it sat at the head of every worst TGPx4 path of
  // the 2C seeds -- ir -> the ARx select (4.3 ns) -> AR -> AGU -> the
  // internal / external test -> state, ext_addr, ar, rpc (to -0.87 ns).
  typedef struct packed {
    logic [1:0][2:0]  sk, dk;                 // source / destination kind
    logic [1:0][5:0]  sc, dc;                 // register codes (transfer map)
    logic [1:0]       sbus, dbus;             // 1 = B bus RAM
    logic [1:0]       smask, dmask;           // address & 0x3ff (internal only)
    logic [1:0][3:0]  amode;                  // AGU fields, per move
    logic [1:0][2:0]  arx, ary;
    logic [1:0][13:0] adisp;
    logic [31:0]      imm;
    logic             eo_upd;
    logic [5:0]       eo_disp;
    logic             single_two;             // single transfer: destination uses fields [1]
  } xdec_t;

  function automatic xdec_t xdec(input logic [63:0] w);
    logic [2:0]  t;
    logic [4:0]  c;
    logic [15:0] e2;
    logic        t1_ext, t1_dir;
    logic [6:0]  t1_rr, t1_sr7;
    xdec_t       d;
    t  = w[63:61];
    c  = w[26:22];
    e2 = w[15:0];
    t1_ext = (t == 3'd1) ? w[26] : w[38];
    t1_dir = (t == 3'd1) ? w[25] : w[37];
    t1_rr  = (t == 3'd1) ? w[18:12] : w[30:24];
    t1_sr7 = (t == 3'd1) ? w[25:19] : w[37:31];
    for (int m = 0; m < 2; m++) begin
      d.sk[m] = K_NONE; d.dk[m] = K_NONE; d.sc[m] = 6'd0; d.dc[m] = 6'd0;
      d.sbus[m] = 1'b0; d.dbus[m] = 1'b0; d.smask[m] = 1'b0; d.dmask[m] = 1'b0;
      d.amode[m] = w[3:0]; d.arx[m] = 3'd0; d.ary[m] = w[6:4]; d.adisp[m] = 14'd0;
    end
    d.imm = 32'd0; d.eo_upd = 1'b0; d.eo_disp = 6'd0;
    d.single_two = (t == 3'd1 || t == 3'd5) && !t1_ext;
    case (t)
      3'd0: begin                                   // double transfer type 1
        // A
        d.sc[0] = {1'b0, w[24:20]}; d.dc[0] = {1'b0, w[24:20]};
        d.arx[0] = w[19:17]; d.ary[0] = w[16:14];
        // B
        d.sc[1] = {2'b10, w[13:10]}; d.dc[1] = {2'b10, w[13:10]};
        d.arx[1] = w[9:7]; d.ary[1] = w[6:4]; d.sbus[1] = 1'b1; d.dbus[1] = 1'b1;
        case (w[26:25])
          2'd0: begin d.sk[0] = K_REG; d.dk[0] = K_REG; d.sk[1] = K_REG; d.dk[1] = K_REG; end
          2'd1: begin d.sk[0] = K_REG; d.dk[0] = K_MEM; d.sk[1] = K_REG; d.dk[1] = K_MEM; end
          2'd2: begin d.sk[0] = K_MEM; d.dk[0] = K_REG; d.sk[1] = K_MEM; d.dk[1] = K_REG; end
          default: ;
        endcase
      end
      3'd1, 3'd5: begin                             // single transfer types 1 / 2
        d.adisp[0] = (t == 3'd1) ? {9'd0, w[11:7]} : w[20:7];
        if (t1_ext) begin
          d.eo_upd  = 1'b1;
          d.eo_disp = (t == 3'd1) ? w[24:19] : w[36:31];
          d.arx[0]  = t1_rr[2:0];
          if (t1_dir) begin                            // external -> internal
            d.sk[0] = K_EXT;
            d.dk[0] = t1_rr[6] ? K_MEM : K_REG; d.dc[0] = t1_rr[5:0];
            d.dbus[0] = t1_rr[5]; d.dmask[0] = 1'b1;
          end else begin                            // internal -> external
            d.sk[0] = t1_rr[6] ? K_MEM : K_REG; d.sc[0] = t1_rr[5:0];
            d.sbus[0] = t1_rr[5]; d.smask[0] = 1'b1;
            d.dk[0] = K_EXT;
          end
        end else begin
          if (t1_sr7 == 7'h58) begin
            d.sk[0] = K_IMM;
            d.imm   = (t == 3'd1) ? {20'd0, w[11:0]} : {8'd0, w[23:0]};
          end else begin
            d.sk[0] = t1_sr7[6] ? K_MEM : K_REG; d.sc[0] = t1_sr7[5:0]; d.sbus[0] = t1_sr7[5];
          end
          d.dk[0] = t1_rr[6] ? K_MEM : K_REG; d.dc[0] = t1_rr[5:0]; d.dbus[0] = t1_rr[5];
          // source and destination each take an address from the same
          // fields with their own ARx: the AGU runs twice, source first
          d.arx[0] = t1_sr7[2:0]; d.arx[1] = t1_rr[2:0];
          d.amode[1] = w[3:0]; d.ary[1] = w[6:4]; d.adisp[1] = d.adisp[0];
        end
      end
      3'd4: begin                                   // double transfer type 2
        d.amode[0] = w[23:20]; d.arx[0] = w[32:30]; d.ary[0] = w[29:27];
        d.adisp[0] = {11'd0, w[26:24]};
        d.amode[1] = w[3:0];   d.arx[1] = w[12:10]; d.ary[1] = w[9:7];
        d.adisp[1] = {11'd0, w[6:4]};
        d.sbus[1] = 1'b1; d.dbus[1] = 1'b1;
        d.sc[0] = {1'b0, w[37:33]}; d.dc[0] = {1'b0, w[32:28]};
        d.sc[1] = {1'b1, w[17:13]}; d.dc[1] = {1'b1, w[12:8]};
        case (w[39:38])
          2'd0: begin d.sk[0] = K_REG; d.dk[0] = K_REG; end
          2'd1: begin d.sk[0] = K_REG; d.dk[0] = K_MEM; end
          2'd2: begin d.sk[0] = K_MEM; d.dk[0] = K_REG; end
          default: ;
        endcase
        case (w[19:18])
          2'd0: begin d.sk[1] = K_REG; d.dk[1] = K_REG; end
          2'd1: begin d.sk[1] = K_REG; d.dk[1] = K_MEM; end
          2'd2: begin d.sk[1] = K_MEM; d.dk[1] = K_REG; end
          default: ;
        endcase
      end
      3'd7: begin                                   // immediate
        d.sk[0] = K_IMM; d.imm = w[58:27];
        d.dk[0] = w[25] ? K_MEM : K_REG; d.dc[0] = w[24:19]; d.dbus[0] = w[24];
        d.arx[0] = w[21:19]; d.adisp[0] = {2'd0, w[18:7]};
      end
      3'd2, 3'd6: begin                             // control
        case (c)
          5'h04: begin                              // PUSH: B[--SP] = reg
            d.sk[0] = K_REG; d.sc[0] = e2[11:6];
          end
          5'h05: begin                              // POP: reg = B[SP++], after the ALU
            d.sk[0] = K_MEM; d.sbus[0] = 1'b1;
            d.dk[0] = K_REG; d.dc[0] = e2[11:6];
          end
          default: ;
        endcase
        // control words take ARs through the AGU's ports: ARx = the target
        // register (w[8:6]), ARy = the tested / counted one (w[15:13])
        d.arx[0] = w[8:6]; d.ary[0] = w[15:13];
        case (c)
          5'h10, 5'h11, 5'h12, 5'h18, 5'h19, 5'h1a: begin
            // the jump target, do_control_dst
            case (w[15:13])
              3'd2: begin d.sk[0] = K_REG; d.sc[0] = {w[11] ? 3'b101 : 3'b001, w[8:6]}; end
              3'd3: begin d.sk[0] = K_REG; d.sc[0] = {w[11] ? 3'b100 : 3'b000, w[8:6]}; end
              3'd4, 3'd6: begin d.sk[0] = K_MEM; d.sbus[0] = 1'b0; end
              3'd5, 3'd7: begin d.sk[0] = K_MEM; d.sbus[0] = 1'b1; d.smask[0] = 1'b1; end
              default: ;                            // immediate / ARx: no fetch
            endcase
          end
          default: ;
        endcase
      end
      default: ;
    endcase
    xdec = d;
  endfunction

  xdec_t xd;
  // R1009: a word that ends in S_DEC -- no transfer, no control, no op -- known
  // as it is taken (with xd), so the take's own decision does not wait on the
  // decode (ir -> dec_hz -> acc -> rpc was on the 2C seeds' lists)
  function automatic logic dec_end(input logic [63:0] w, input xdec_t d);
    logic is_ctl_w, is_imm_w, alu_en_w, mul_en_w;
    is_ctl_w = (w[63:61] == 3'd2) || (w[63:61] == 3'd6);
    is_imm_w = (w[63:61] == 3'd7);
    alu_en_w = !is_imm_w && (!w[63] || w[41]);
    mul_en_w = !is_imm_w && (!w[63] || !w[41]);
    dec_end = d.sk[0] == 3'd0 && d.dk[0] == 3'd0 && !is_ctl_w && !(alu_en_w && w[60:56] != 5'h07) && !mul_en_w;
  endfunction
  logic w_dec1;
  // R1009: and whether its register-file source A is read in S_DEC (xs_rf_dec)
  function automatic logic xs_dec(input logic [63:0] w, input xdec_t d);
    logic is_imm_w, alu_op_w, mul_op_w, rf_w;
    is_imm_w = (w[63:61] == 3'd7);
    alu_op_w = !is_imm_w && (!w[63] || w[41]) && w[60:56] != 5'h07;
    mul_op_w = !is_imm_w && (!w[63] || !w[41]);
    rf_w     = (d.sc[0][4] == 1'b0) && (d.sc[0][5:3] != 3'b010) && (d.sc[0][5:3] != 3'b110) && (d.sc[0][5:3] != 3'b111);
    xs_dec   = XSRF && d.sk[0] == 3'd1 && rf_w && (d.sc[0][3] ? !alu_op_w : !mul_op_w);
  endfunction
  logic xs_q;
  wire [1:0][2:0]  sk = xd.sk, dk = xd.dk;
  wire [1:0][5:0]  sc = xd.sc, dc = xd.dc;
  wire [1:0]       sbus = xd.sbus, dbus = xd.dbus, smask = xd.smask, dmask = xd.dmask;
  wire [1:0][3:0]  amode = xd.amode;
  wire [1:0][2:0]  arx = xd.arx, ary = xd.ary;
  wire [1:0][13:0] adisp = xd.adisp;
  wire [31:0]      imm = xd.imm;
  wire             eo_upd = xd.eo_upd;
  wire [5:0]       eo_disp = xd.eo_disp;

  logic [4:0] cop;
  logic [5:0] ef1;
  logic [15:0] ef2;
  assign cop = ir[26:22];
  assign ef1 = ir[21:16];
  assign ef2 = ir[15:0];

  // ======================================================== AGU (one)
  logic        agu_m;         // which move's fields
  logic        agu_dst;       // destination pass (type 1 / 2 single transfers)
  logic [3:0]  g_mode;
  logic [13:0] g_arx, g_ary, g_disp, g_ea, g_arw;
  logic        g_isb, g_we, g_sely;
  logic [2:0]  g_rx, g_ry;
  logic        single_two;    // single transfer: destination uses fields [1]

  assign single_two = xd.single_two;

  logic agu_mi;
  assign agu_mi = (agu_dst && single_two) ? 1'b1 : agu_m;
  assign g_mode = amode[agu_mi];
  assign g_rx   = arx[agu_mi];
  assign g_ry   = ary[agu_mi];
  assign g_disp = adisp[agu_mi];
  assign g_isb  = agu_dst ? dbus[agu_m] : sbus[agu_m];
  assign g_arx = ar[g_rx];
  assign g_ary = ar[g_ry];

  tgpx4_agu u_agu (
    .mode(g_mode), .arx(g_arx), .ary(g_ary), .disp(g_disp), .isb(g_isb),
    .modr(modr), .ea(g_ea), .ar_we(g_we), .ar_sel_y(g_sely), .ar_wval(g_arw)
  );

  // control-flow targets that need no fetch, and the stack / direct forms
  logic [13:0] ctl_ea;          // the RAM address of a memory jump target
  logic [13:0] ctl_ary;         // ARy latched for REP / SETL
  assign ctl_ea = (ir[15:13] == 3'd4 || ir[15:13] == 3'd5) ? {4'd0, ir[9:0]} : g_arx;

  // ======================================================== special registers
  function automatic logic [31:0] spc_rd(input logic [5:0] c,
      input logic [23:0] eb_i, input logic [23:0] eo_i, input logic [9:0] sp_i,
      input logic [31:0] st_i, input logic [15:0] mod_i, input logic [15:0] lpc_i,
      input logic [13:0] ar_i, input logic [31:0] pr_i, input logic [31:0] fi_i,
      input logic [31:0] pdr_i, input logic [31:0] ddr_i,
      input logic [4:0] prp_i, input logic [4:0] pwp_i);
    case (c)
      6'h10: spc_rd = {8'd0, eb_i};
      6'h11: spc_rd = {22'd0, eb_i[23:14]};
      6'h12: spc_rd = {18'd0, eb_i[13:0]};
      6'h13: spc_rd = {8'd0, eo_i};
      6'h14: spc_rd = {22'd0, sp_i};
      6'h15: spc_rd = st_i;
      6'h16: spc_rd = {16'd0, mod_i};
      6'h17: spc_rd = {16'd0, lpc_i};
      6'h30: spc_rd = pr_i;
      6'h31: spc_rd = fi_i;
      6'h34: spc_rd = pdr_i;
      6'h35: spc_rd = ddr_i;
      6'h36: spc_rd = {27'd0, prp_i};
      6'h37: spc_rd = {27'd0, pwp_i};
      default: spc_rd = {18'd0, ar_i};   // 0x18-0x1f
    endcase
  endfunction

  function automatic logic is_rf(input logic [5:0] c);
    is_rf = (c[4] == 1'b0) && (c[5:3] != 3'b010) && (c[5:3] != 3'b110) && (c[5:3] != 3'b111);
  endfunction

  function automatic logic [4:0] rf_idx(input logic [5:0] c);
    rf_idx = {c[5], c[3], c[2:0]};
  endfunction

  // ======================================================== flow helpers
  logic        cond;
  always_comb begin
    case (ef1[4:0])
      5'd0:  cond = st[F_MN];  5'd1:  cond = st[F_MZ];  5'd2:  cond = st[F_MV];
      5'd3:  cond = st[F_MU];  5'd4:  cond = st[F_ZD];  5'd5:  cond = st[F_NR];
      5'd6:  cond = st[F_IL];  5'd7:  cond = st[F_ZC];  5'd8:  cond = st[F_AN];
      5'd9:  cond = st[F_AZ];  5'd10: cond = st[F_AV];  5'd11: cond = st[F_AU];
      5'd12: cond = st[F_MD];  5'd13: cond = st[F_AD];
      5'd16: cond = st[F_F0];  5'd17: cond = st[F_F1];  5'd18: cond = st[F_F2];
      5'd20: cond = fi_full;   5'd21: cond = !fi_valid;
      5'd22: cond = fo_full;   5'd23: cond = fo_empty;
      default: cond = 1'b0;
    endcase
  end

  logic needs_fi, needs_fo;
  always_comb begin
    needs_fi = 1'b0; needs_fo = 1'b0;
    for (int m = 0; m < 2; m++) begin
      if (sk[m] == K_REG && sc[m] == 6'h31) needs_fi = 1'b1;
      if (dk[m] == K_REG && (dc[m] == 6'h32 || dc[m] == 6'h33)) needs_fo = 1'b1;
    end
  end

  // ======================================================== units
  logic [31:0] opa, opb, opm1, opm2;
  logic        alu_go, mul_go;        // R1009: the go pulses, combinational (ag_p / mg_p, below)
  logic        ag_p, mg_p;            // an op issued from S_DEC / S_PR2, not yet gone
  logic [4:0]  aop_q;
  logic [4:0]  imm5_q;

  // fp_add
  logic        add_go;
  logic [31:0] add_a, add_b;
  logic        add_sub;
  logic        add_v;
  logic [31:0] add_r;
  logic        add_ov, add_un, add_inv;
  // R1018: LEAN, one normalising shifter (the TGPx4 is the 2C build's alone)
  fp_add #(.SUBNORM(SUBNORM), .LEAN(1'b1)) u_add (
    .clk(clk), .rst_n(rst_n), .in_valid(add_go), .a(add_a), .b(add_b), .sub(add_sub),
    .out_valid(add_v), .result(add_r), .overflow(add_ov), .underflow(add_un), .invalid(add_inv)
  );

  // fp_mul
  logic        fmul_go;
  logic        fmul_v;
  logic [31:0] fmul_r;
  logic        fmul_ov, fmul_un, fmul_inv;
  fp_mul #(.SUBNORM(SUBNORM)) u_mul (
    .clk(clk), .rst_n(rst_n), .in_valid(fmul_go), .a(opm1), .b(opm2),
    .out_valid(fmul_v), .result(fmul_r), .overflow(fmul_ov), .underflow(fmul_un), .invalid(fmul_inv)
  );

  // fp_div: FRCP, and the second half of FRSQ
  logic        div_go;
  logic [31:0] div_b;
  logic        div_busy, div_v;
  logic [31:0] div_r;
  logic        div_ov, div_un, div_dz, div_inv;
  fp_div u_div (
    .clk(clk), .rst_n(rst_n), .in_valid(div_go), .a(32'h3f800000), .b(div_b),
    .busy(div_busy), .out_valid(div_v), .result(div_r),
    .overflow(div_ov), .underflow(div_un), .div_by_zero(div_dz), .invalid(div_inv)
  );

  logic        sq_go, sq_busy, sq_v;
  logic [31:0] sq_r;
  tgpx4_fsqrt u_sqrt (
    .clk(clk), .rst_n(rst_n), .in_valid(sq_go), .a(opa),
    .busy(sq_busy), .out_valid(sq_v), .result(sq_r)
  );

  logic        cv_go, cv_v;
  logic [31:0] cv_r;
  logic        cv_an, cv_az, cv_au, cv_av;
  tgpx4_cvt u_cvt (
    .clk(clk), .rst_n(rst_n), .in_valid(cv_go), .op(aop_q), .sh(imm5_q), .a(opa),
    .out_valid(cv_v), .result(cv_r), .f_an(cv_an), .f_az(cv_az), .f_au(cv_au), .f_av(cv_av)
  );

  // integer multiply, two stages (DSP)
  logic [31:0] imul_p1, imul_r;
  logic        imul_v1, imul_v;

  // dispatch of the ALU op
  logic a_fadd, a_frcp, a_frsq, a_cvt, a_int, a_flog;
  assign a_fadd = (aop_q[4:3] == 2'b00) && (aop_q[2:0] != 3'd5) && (aop_q[2:0] != 3'd7);
  assign a_frcp = (aop_q == 5'h0a);
  assign a_frsq = (aop_q == 5'h0b);
  assign a_flog = (aop_q == 5'h0c);
  assign a_cvt  = (aop_q == 5'h0d) || (aop_q == 5'h0e) || (aop_q == 5'h0f) ||
                  (aop_q[4:2] == 3'b111);                    // and the four shifts
  assign a_int  = !a_fadd && !a_frcp && !a_frsq && !a_flog && !a_cvt;

  assign add_go  = alu_go && a_fadd;
  // FSUB / FCMP: f2 - f1;  FABC: |f2| - |f1|
  // R924: the adder's operands REGISTERED in S_DEC (swapped for FSUB / FCMP,
  // made absolute for FABC there) -- the mux from aop_q into fp_add's first
  // stage was on s1312's clk_sys list (aop_q -> sA_small, -0.514 ns)
  logic [31:0] add_aq, add_bq;
  logic        add_subq;
  assign add_a   = add_aq;
  assign add_b   = add_bq;
  assign add_sub = add_subq;
  logic [31:0] opb_n;
  assign opb_n = !alu_src2 ? 32'd0 :
                 (ai2[4:3] == 2'd2) ? pr_rd :
                 (ai2[4:3] == 2'd3) ? cst(ai2[2:0], !aop[4]) : rfo[1];   // R1006: forwarded
  wire dec_swap = aop[1] || (aop == 5'h04);
  assign cv_go   = alu_go && a_cvt;
  assign sq_go   = alu_go && a_frsq;

  logic frsq_pend;
  // R924: x86's NaNs for FRCP (1 / f) and FRSQ (1 / sqrtf(f): sqrtf of a
  // negative is the default NaN, of a NaN that NaN quieted)
  logic [31:0] div_n;
  assign div_n = f_nan(opa) ? (opa | 32'h0040_0000)
               : (frsq_pend && opa[31] && opa[30:0] != 31'd0) ? 32'hffc0_0000
               : nanfix(div_r, 32'd0, 32'd0);
  assign div_go = (alu_go && a_frcp) || sq_v;
  assign div_b  = sq_v ? sq_r : opa;

  // the integer ALU, MAME's 0x05, 0x07-0x09 and 0x10-0x1f
  logic [31:0] ires;
  logic        i_an, i_az, i_zc, i_zc_upd, i_flags, i_wr;
  // ONE adder for ADD / SUB / CMP (and their Z forms): b - a = b + ~a + 1
  logic [31:0] ias;
  logic        isub;
  assign isub = aop_q[1] || (aop_q == 5'h14);
  assign ias  = opb + (isub ? ~opa : opa) + {31'd0, isub};
  always_comb begin
    ires = 32'd0; i_zc = 1'b0; i_zc_upd = 1'b0; i_flags = 1'b1; i_wr = 1'b1;
    case (aop_q)
      5'h05: ires = {1'b0, opa[30:0]};                        // FABS
      5'h07: begin i_flags = 1'b0; i_wr = 1'b0; end           // NOP
      5'h08: ires = (opa & 32'h7f800000) | {1'b0, opa[30:23] + {3'd0, imm5_q}, 23'd0};   // FEA
      5'h09: ires = (opa & 32'h7f800000) | {1'b0, opa[30:23] - {3'd0, imm5_q}, 23'd0};   // FES
      5'h10, 5'h11, 5'h12, 5'h13: begin
        ires = ias;
        if (aop_q[0]) begin i_zc_upd = 1'b1; i_zc = ias[31]; if (ias[31]) ires = 32'd0; end
      end
      5'h14: begin ires = ias; i_wr = 1'b0; end               // CMP
      5'h15: ires = {1'b0, opa[30:0]};                        // ABS
      5'h16: begin ires = opa; i_flags = 1'b0; end            // ATR
      5'h17: begin                                            // ATRZ
        i_flags = 1'b0; i_zc_upd = 1'b1; i_zc = opa[31];
        ires = opa[31] ? 32'd0 : opa;
      end
      5'h18: ires = opa & opb;
      5'h19: ires = opa | opb;
      5'h1a: ires = opa ^ opb;
      5'h1b: ires = ~opa;
      default: begin i_flags = 1'b0; i_wr = 1'b0; end
    endcase
    i_an = ires[31];
    i_az = (ires == 32'd0);
  end

  // ======================================================== ALU / MUL results (R1006)
  // THE DESCRIPTOR of an operation: where its result goes (we, idx), whether
  // it sets flags (fl: not when its word writes ST by a transfer -- the
  // transfer came after the op in MAME), its opcode (the flags it sets), cur
  // (issued by the word still in the sequencer), and MAME's NaN: nan set when
  // an operand is a NaN, ov that operand quieted ({sign, fraction[21:0]};
  // the first operand first, as MAME's host makes it -- R924).
  typedef struct packed {
    logic        we;
    logic [4:0]  idx;
    logic        fl;
    logic [4:0]  aop;      // ALU: the opcode; multiplier: bit 0 = FMUL
    logic        cur;
    logic        nan;
    logic [22:0] ov;
  } odesc_t;
  // (built by a function: Quartus 17.0 reads a named assignment pattern's
  // "aop:" as the signal aop)
  function automatic odesc_t mkd(input logic we_i, input logic [4:0] idx_i, input logic fl_i,
                                 input logic [4:0] op_i, input logic cur_i, input logic nan_i, input logic [22:0] ov_i);
    odesc_t d;
    d.we = we_i; d.idx = idx_i; d.fl = fl_i; d.aop = op_i; d.cur = cur_i; d.nan = nan_i; d.ov = ov_i;
    mkd = d;
  endfunction
  function automatic logic [31:0] ov32(input logic [22:0] o);
    ov32 = {o[22], 8'hff, 1'b1, o[21:0]};
  endfunction

  // the static parts, registered as the word leaves S_DEC; the go pulses
  // (alu_go / mul_go) follow in the next clock and the units take aop_q,
  // the operand registers and these
  logic        aq_we, aq_fl, mq_we, mq_fl, mq_isf;
  logic [4:0]  aq_idx, mq_idx;

  // in flight: issued, not arrived (two each, oldest first); a2u: their unit
  odesc_t      af [0:1], mf [0:1];
  logic [1:0]  af_n, mf_n;
  logic [1:0]  a_unit;                 // 0 fp_add, 1 tgpx4_cvt, 2 FRCP / FRSQ
  logic        m_unit;                 // 0 fp_mul, 1 the integer multiply
  // arrived, not written: the result, its descriptor, its flags
  logic        ar_v, mr_v;
  odesc_t      ard, mrd;
  logic [31:0] alu_r, mul_r;
  logic        fa_an, fa_az, fa_zc, fa_x, fa_au, fa_av;   // fa_x: ZD / NR
  logic        fa_upd, fa_zcu;
  logic        fm_n, fm_z, fm_d, fm_v, fm_u;
  // registers with a result still to be written
  logic [31:0] pend;

  assign fmul_go = mul_go && mq_isf;
  logic [31:0] fmul_n;
  logic        fm_opnan;
  assign fm_opnan = mf[0].nan;
  assign fmul_n = fm_opnan ? ov32(mf[0].ov) : f_nan(fmul_r) ? 32'hffc0_0000 : fmul_r;   // nanfix(fmul_r, opm1, opm2)

  function automatic logic f_neg(input logic [31:0] f);
    f_neg = f[31] && (f[30:0] != 31'd0) && !(f[30:23] == 8'hff && f[22:0] != 23'd0);
  endfunction
  function automatic logic f_zero(input logic [31:0] f);
    f_zero = (f[30:0] == 31'd0);
  endfunction
  // R924: NaNs AS MAME'S HOST (x86 SSE) MAKES THEM, so the bits match MAME's
  // run, not just the class: a NaN operand comes back quieted, the
  // expression's first operand first (f1 + f2, f2 - f1, f1 * f2, 1 / f); an
  // invalid operation with no NaN in gives the default NaN 0xffc00000. Found
  // by the HOTD replay at word 119,227,540 (pc 0x10a: rtl 7fc00000, MAME
  // ffffc000) -- the FP units give one canonical NaN.
  function automatic logic f_nan(input logic [31:0] f);
    f_nan = (f[30:23] == 8'hff) && (f[22:0] != 23'd0);
  endfunction
  function automatic logic [31:0] nanfix(input logic [31:0] r, input logic [31:0] x, input logic [31:0] y);
    if      (f_nan(x)) nanfix = x | 32'h0040_0000;
    else if (f_nan(y)) nanfix = y | 32'h0040_0000;
    else if (f_nan(r)) nanfix = 32'hffc0_0000;
    else               nanfix = r;
  endfunction

  // R934 / R1006: THE OPERANDS' NaN TESTS ARE MADE AT THE GO PULSE, from the
  // operand registers (loaded in S_DEC, opm2 also in S_PR2), and ride with
  // the operation in its descriptor -- the operand registers belong to the
  // next word by the time the result arrives. The flags of the result are
  // taken from the unit's result and that bit, not by testing nanfix()'s
  // output (add_bq -> nanfix -> f_neg -> the clamp -> f_zero -> fa_az was on
  // all four 2C seeds' lists). Exactly nanfix(): a NaN operand makes a NaN,
  // which is neither negative nor zero; a NaN result is neither either.
  logic        go_anan, go_bnan, go_m1nan, go_m2nan;
  assign go_anan  = f_nan(add_aq);  assign go_bnan  = f_nan(add_bq);
  assign go_m1nan = f_nan(opm1);    assign go_m2nan = f_nan(opm2);
  logic        add_zc, add_zop, add_rneg, add_rzero;
  logic [31:0] add_d;
  logic [31:0] add_n;
  assign add_n     = af[0].nan ? ov32(af[0].ov) : f_nan(add_r) ? 32'hffc0_0000 : add_r;   // nanfix(add_r, add_a, add_b), R924
  assign add_rneg  = !af[0].nan && f_neg(add_r);      // f_neg(add_n)
  assign add_rzero = !af[0].nan && f_zero(add_r);     // f_zero(add_n)
  assign add_zop   = af[0].aop[0] && !af[0].aop[2];
  assign add_zc    = add_zop && add_rneg;                    // FADDZ / FSUBZ clamp
  assign add_d     = add_zc ? 32'd0 : add_n;

  // ======================================================== moves in flight
  logic [31:0] mv_val [0:1];
  logic        ctl_take;
  logic [11:0] ctl_tgt;

  // ======================================================== sequencer
  // combinational port use
  always_comb begin
    pm_req  = 1'b0;
    pm_addr = pc;
    rfa_ra[0] = {ai1[3], ai1[2:0]};
    rfa_ra[1] = {ai2[3], ai2[2:0]};
    rfm_ra[0] = {m1s[3], m1s[2:0]};
    rfm_ra[1] = {m2s[3], m2s[2:0]};
    // R1006: a register-file source read in S_DEC through its free bank's copy 0
    // (only the source's own bank: the other's copy 0 may be its unit's operand)
    if (s == S_DEC && xs_q &&  sc[0][3]) rfa_ra[0] = {sc[0][5], sc[0][2:0]};
    if (s == S_DEC && xs_q && !sc[0][3]) rfm_ra[0] = {sc[0][5], sc[0][2:0]};
    if (s == S_XA) begin rfa_ra[0] = {sc[0][5], sc[0][2:0]}; rfm_ra[0] = {sc[0][5], sc[0][2:0]}; end
    if (s == S_XB) begin rfa_ra[1] = {sc[1][5], sc[1][2:0]}; rfm_ra[1] = {sc[1][5], sc[1][2:0]}; end
    agu_m   = (s == S_XA || s == S_WXB) ? 1'b1 : 1'b0;
    agu_dst = (s == S_WXA || s == S_WXB);
    ra_ra = is_ctl ? ctl_ea[9:0] : g_ea[9:0];
    rb_ra = (is_ctl && (cop == 5'h05)) ? sp : (is_ctl ? ctl_ea[9:0] : g_ea[9:0]);
    if ((s == S_DEC && !pf_sent) || (s == S_HALT && run)) pm_req = 1'b1;
  end
  // a transfer source from the register file, from its own bank (sel0 = code bit 3)
  logic [31:0] xa_rd, xb_rd;
  assign xa_rd = sc[0][3] ? rfa_rd[0] : rfm_rd[0];
  assign xb_rd = sc[1][3] ? rfa_rd[1] : rfm_rd[1];

  // ONE special-register read, for source A in S_DEC and source B in S_XA.
  // PR is read at S_DEC's prp for both (MAME reads every transfer source
  // before the ALU's PR operand steps it).
  logic        spc_m;
  logic [5:0]  spc_c;
  logic [31:0] spc_now, pr_dec;
  // R1009: "past S_DEC", a register of its own: S_XA's state bit, with all its
  // fanout, through the special-register read into mv_val was -0.59 ns on s2521
  logic        spc_mq;
  assign spc_m   = spc_mq;
  assign spc_c   = sc[spc_m];
  assign spc_now = spc_rd(spc_c, eb, eo, sp, st, modr, lpc, ar[spc_c[2:0]],
                          spc_m ? pr_dec : pr_rd, fi_data, pdr, ddr, prp, pwp);

  // the value a destination is written with, and where
  logic        wm;                                  // which move writes now
  logic [31:0] wv;
  logic [5:0]  wc;
  assign wm = (s == S_WXB);
  assign wv = mv_val[wm];
  assign wc = dc[wm];

  // the jump target
  logic [11:0] ctl_t, ctl_t0;
  assign ctl_t0 = (sk[0] == K_NONE) ? ctl_tgt : mv_val[0][11:0];
  always_comb begin
    case (cop)
      5'h13, 5'h14, 5'h15: ctl_t = pc + ir[11:0];
      5'h1b:               ctl_t = pcs[pcp - 2'd1];
      default:             ctl_t = ir[12] ? (pc + ctl_t0) : ctl_t0;
    endcase
  end

  // DBBC / DBBS test a bit of ARx; bits 14 and 15 read 0
  logic [15:0] ar_bt;
  assign ar_bt = {2'b00, g_ary};

  // R1006: A CONTROL WORD WITH NOTHING TO FETCH (no PUSH / POP, no jump
  // target in a register or RAM) TAKES ITS EFFECT IN S_DEC -- the condition,
  // the target and every register it changes are known there -- and ends a
  // clock later (S_WAIT), so its delay slot / REP is in place for the take.
  // The same decisions S_DEC registers (ctl_take, ctl_tgt) and S_WXA uses.
  logic        ctl_dec, take_d;
  logic [11:0] tgt_d, ctl_t_d;
  assign ctl_dec = CTLD && is_ctl && sk[0] == K_NONE;
  always_comb begin
    case (cop)
      5'h10: take_d = cond;
      5'h11: take_d = !cond;
      5'h12, 5'h1a, 5'h1b: take_d = 1'b1;
      5'h13: take_d = st[F_LP];
      5'h14: take_d = !ar_bt[ir[19:16]];
      5'h15: take_d =  ar_bt[ir[19:16]];
      5'h18: take_d = cond;
      5'h19: take_d = !cond;
      default: take_d = 1'b0;
    endcase
    case (ir[15:13])
      3'd0: tgt_d = ir[11:0];
      3'd1: tgt_d = g_arx[11:0];
      default: tgt_d = 12'd0;
    endcase
    case (cop)
      5'h13, 5'h14, 5'h15: ctl_t_d = pc + ir[11:0];
      5'h1b:               ctl_t_d = pcs[pcp - 2'd1];
      default:             ctl_t_d = ir[12] ? (pc + tgt_d) : tgt_d;
    endcase
  end
  // R1006: A SOURCE ALREADY IN HAND AT S_DEC NEEDS NO S_XA -- an immediate, a
  // special register (read there anyway), or a register-file source when its
  // bank's first read copy is free in S_DEC (the word has no operation on
  // that bank's unit); one source only
  logic xs_rf_dec, xa_skip;
  assign xs_rf_dec = xs_q;     // R1009: registered with the word (xs_dec)
  assign xa_skip   = sk[1] == K_NONE && (sk[0] == K_IMM || (sk[0] == K_REG && !is_rf(sc[0])) || xs_rf_dec);

  // ---------------------------------------------------------------- R1006 / R1009: the results' writer
  // R1009: EVERY RESULT IS REGISTERED AS IT ARRIVES (alu_r / mul_r, ar_v /
  // mr_v) AND WRITTEN FROM THERE, ON A SCHEDULE DECIDED A CLOCK AHEAD (a_wq /
  // m_wq, and wrm_q: the registers written this clock). R1006 wrote a result
  // in its arrival clock and chose, in that clock, between it, a held one and
  // the sequencer -- and the scoreboard's "written by the end of this clock"
  // and the forwarding hung on that choice: unit valid / aop_q -> candidate
  // -> bank conflict -> pend_l -> dec_hz -> every S_DEC enable, 14 ns, the
  // 2C seeds' -1.4 to -2.2 ns (s2520-s2522, s2540-s2561). Now all of S_DEC's
  // view of the writer is registers. A word's own result never arrives before
  // its transfer sources are read -- its ops start (go) only once S_XA has
  // nothing more to read -- so nothing is ever held for that. When the ALU's
  // and the multiplier's results want the same bank, the ALU's goes first,
  // unless the multiplier's has already waited a clock; neither waits more
  // than one, which the issue rules' two-clock spacing of arrivals relies on.
  // R1009: AN OP GOES THE CLOCK AFTER S_DEC / S_PR2. Its result is written
  // at the earliest the clock after it arrives, so a register-file source
  // read in S_XA (that clock) or S_XB (the next) still sees the value before
  // it, as MAME (every source before the ALU) -- unless an external read in
  // S_XA holds source B back: then the op waits for it. Only a source B can
  // be read that late, and no op writes a special register source B can name
  // (0x20-0x3f: the register file, PR, FI, PDR, DDR, PRP, PWP, AR).
  logic src_ok;
  assign src_ok = (s != S_DEC) && (s != S_PR2) && !(s == S_XA && ext_req && sk[1] != K_NONE);
  assign alu_go = ag_p && src_ok;
  assign mul_go = mg_p && src_ok;
  logic a_int_arr, a_arr, m_arr;
  assign a_int_arr = alu_go && (a_int || a_flog);
  assign a_arr     = add_v || cv_v || div_v || a_int_arr;
  assign m_arr     = fmul_v || imul_v;
  // arriving now
  odesc_t      a_cd_arr;
  logic [31:0] a_cv_arr, m_cv_arr;
  logic        a_aupd, a_aan, a_aaz, a_azcu, a_azc, a_aau, a_aav, a_ax;
  logic        m_an, m_az, m_ad, m_av, m_au;
  always_comb begin
    // the ALU's (MAME decode_aluop)
    a_cd_arr = a_int_arr ? mkd(aq_we, aq_idx, aq_fl, aop_q, 1'b0, 1'b0, 23'd0) : af[0];
    a_cv_arr = ires; a_aupd = i_flags; a_aan = i_an; a_aaz = i_az; a_azcu = i_zc_upd; a_azc = i_zc;
    a_aau = 1'b0; a_aav = 1'b0; a_ax = 1'b0;
    if (alu_go && a_flog) begin a_cv_arr = 32'd0; a_aupd = 1'b0; a_azcu = 1'b0; end
    if (add_v) begin
      a_cv_arr = add_d; a_aupd = 1'b1; a_aan = add_rneg && !add_zop; a_aaz = add_zc || add_rzero;   // R934: f_neg / f_zero(add_d)
      a_azcu = add_zop; a_azc = add_zc;
    end
    if (cv_v) begin
      a_cv_arr = cv_r; a_aupd = 1'b1; a_azcu = 1'b0; a_aan = cv_an; a_aaz = cv_az; a_aau = cv_au; a_aav = cv_av;
    end
    if (div_v) begin
      a_cv_arr = div_n; a_aupd = 1'b1; a_azcu = 1'b0; a_aan = f_neg(div_n); a_aaz = f_zero(div_n);
      a_ax = frsq_pend ? (f_zero(opa) || f_neg(opa)) : f_zero(opa);
    end
    // the multiplier's (MAME decode_mulop: MD = isnan, MV = isinf, MU = |res|
    // < FLT_MIN -- so an exact zero sets MU too, R924 -- from the result and
    // the operands' NaN bit, R934)
    m_cv_arr = imul_r; m_an = imul_r[31]; m_az = (imul_r == 32'd0); m_ad = 1'b0; m_av = 1'b0; m_au = 1'b0;
    if (fmul_v) begin
      m_cv_arr = fmul_n; m_an = !fm_opnan && f_neg(fmul_r); m_az = !fm_opnan && f_zero(fmul_r);
      m_ad = fm_opnan || f_nan(fmul_r);
      m_av = !fm_opnan && (fmul_r[30:23] == 8'hff) && (fmul_r[22:0] == 23'd0);
      m_au = !fm_opnan && (fmul_r[30:23] == 8'h00);
    end
  end
  // THE ARRIVALS, A CLOCK AHEAD: fp_add, tgpx4_cvt, fp_mul and the integer
  // multiply answer a fixed number of clocks after the go pulse (4, 6, 4, 2),
  // so each queued op counts down (acnt / mcnt) and the clock before it
  // arrives is known from registers (pa_n / pm_n; checked against the unit in
  // the bench). FRCP / FRSQ (apred 0) and the integer ALU are not predicted:
  // their results are registered and written from there.
  logic [2:0] acnt [0:1], mcnt [0:1];
  logic       apred [0:1];
  logic       pa_n, pm_n;              // an ALU / multiplier result arrives next clock
  odesc_t     pad_n, pmd_n;            // its descriptor
  always_comb begin
    if (a_pop) begin pa_n = (af_n == 2'd2) && apred[1] && acnt[1] == 3'd0; pad_n = af[1]; end
    else       begin pa_n = (af_n != 2'd0) && apred[0] && acnt[0] == 3'd0; pad_n = af[0]; end
    if (m_pop) begin pm_n = (mf_n == 2'd2) && mcnt[1] == 3'd0; pmd_n = mf[1]; end
    else       begin pm_n = (mf_n != 2'd0) && mcnt[0] == 3'd0; pmd_n = mf[0]; end
  end
  // THIS CLOCK'S WRITES, decided last clock: a_wq / m_wq, from the result
  // register or (a_ws / m_ws) straight from the arriving unit
  logic        a_wq, m_wq, a_ws, m_ws;
  logic [31:0] wrm_q;                    // the registers those two write
  odesc_t      a_wd, m_wd;               // what is written
  logic [31:0] a_wv, m_wv;
  logic        w_aupd, w_aan, w_aaz, w_azcu, w_azc, w_aau, w_aav, w_ax;
  logic        w_mn, w_mz, w_md, w_mv, w_mu;
  assign a_wd   = a_ws ? af[0]    : ard;
  assign a_wv   = a_ws ? a_cv_arr : alu_r;
  assign w_aupd = a_ws ? a_aupd   : fa_upd;
  assign w_aan  = a_ws ? a_aan    : fa_an;
  assign w_aaz  = a_ws ? a_aaz    : fa_az;
  assign w_azcu = a_ws ? a_azcu   : fa_zcu;
  assign w_azc  = a_ws ? a_azc    : fa_zc;
  assign w_aau  = a_ws ? a_aau    : fa_au;
  assign w_aav  = a_ws ? a_aav    : fa_av;
  assign w_ax   = a_ws ? a_ax     : fa_x;
  assign m_wd   = m_ws ? mf[0]    : mrd;
  assign m_wv   = m_ws ? m_cv_arr : mul_r;
  assign w_mn   = m_ws ? m_an     : fm_n;
  assign w_mz   = m_ws ? m_az     : fm_z;
  assign w_md   = m_ws ? m_ad     : fm_d;
  assign w_mv   = m_ws ? m_av     : fm_v;
  assign w_mu   = m_ws ? m_au     : fm_u;
  logic a_wr, m_wr, res_a_busy, res_m_busy;
  assign a_wr = a_wq;
  assign m_wr = m_wq;
  assign res_a_busy = (a_wq && a_wd.we && a_wd.idx[3]) || (m_wq && m_wd.we && m_wd.idx[3]);
  assign res_m_busy = (a_wq && a_wd.we && !a_wd.idx[3]) || (m_wq && m_wd.we && !m_wd.idx[3]);
  // an arrival not written as it arrives is registered
  logic a_keep, m_keep;
  assign a_keep = a_arr && !(a_wq && a_ws);
  assign m_keep = m_arr && !(m_wq && m_ws);
  // next clock's: the registered result (if any) first, else the arriving one;
  // on a bank conflict the multiplier's goes first only from its register
  // (it has waited a clock: the arriving one is written as it arrives
  // otherwise), so neither waits more than one
  // R1029-2C: THE SCHEDULE WORKED OUT FOR BOTH VALUES OF src_ok, THEN PICKED.
  // src_ok (the state, ext_req and the word's source B) is the last input to
  // arrive: it gated alu_go -> the integer ALU's arrival -> a_keep -> ar_vn ->
  // the bank-conflict test -> a_wqn / m_wqn -> the wrm_n decode, 10 levels
  // (xd.sk -> wrm_q -0.60 on s3066, -0.58 s3076; s.S_DEC -> wrm_q). Each half
  // below is that same logic with alu_go fixed (0, or ag_p), from registers
  // only; src_ok then picks between two finished answers. The same function
  // of the same inputs: no cycle and no value changes. m2_tgpx4 alone,
  // post-map: xd.sk -> wrm_q 11 -> 7 levels, s.S_DEC 10 -> 6, +4 ALM.
  function automatic logic [34:0] wsched(input logic keep, input odesc_t cd_arr,
      input logic arv, input logic awq, input logic aws, input odesc_t ard_i,
      input logic pan, input odesc_t pad, input logic mrvn, input logic cmn, input odesc_t cmd);
    logic   arvn, can, cf, awqn, mwqn;
    odesc_t ardn_l, cad;
    logic [31:0] w;
    begin
      arvn   = (arv && !(awq && !aws)) || keep;
      ardn_l = keep ? cd_arr : ard_i;
      can    = arvn || pan;  cad = arvn ? ardn_l : pad;
      cf     = can && cmn && cad.we && cmd.we && (cad.idx[3] == cmd.idx[3]);
      awqn   = can && !(cf && mrvn);
      mwqn   = cmn && !(cf && !mrvn);
      w = 32'd0;
      if (awqn && cad.we) w[cad.idx] = 1'b1;
      if (mwqn && cmd.we) w[cmd.idx] = 1'b1;
      wsched = {arvn, awqn, mwqn, w};
    end
  endfunction
  logic   ar_vn, mr_vn, a_wqn, m_wqn, cm_n;
  odesc_t mrdn, cmd_n;
  logic [31:0] wrm_n;
  logic        a_int_g, a_keep0, a_keep1;   // the ALU's arrival if no op goes / if ag_p's does
  odesc_t      a_cd_g;
  logic [34:0] ws0, ws1;
  assign a_int_g = ag_p && (a_int || a_flog);
  assign a_cd_g  = a_int_g ? mkd(aq_we, aq_idx, aq_fl, aop_q, 1'b0, 1'b0, 23'd0) : af[0];
  always_comb begin
    mr_vn = (mr_v && !(m_wq && !m_ws)) || m_keep;
    mrdn  = m_keep ? mf[0]    : mrd;
    cm_n  = mr_vn || pm_n;  cmd_n = mr_vn ? mrdn : pmd_n;
    a_keep0 = (add_v || cv_v || div_v) && !(a_wq && a_ws);
    a_keep1 = (add_v || cv_v || div_v || a_int_g) && !(a_wq && a_ws);
    ws0 = wsched(a_keep0, af[0],  ar_v, a_wq, a_ws, ard, pa_n, pad_n, mr_vn, cm_n, cmd_n);
    ws1 = wsched(a_keep1, a_cd_g, ar_v, a_wq, a_ws, ard, pa_n, pad_n, mr_vn, cm_n, cmd_n);
    {ar_vn, a_wqn, m_wqn, wrm_n} = src_ok ? ws1 : ws0;
  end
  // R1006: S_DEC's operands FORWARDED from the results written this clock --
  // the register file has them only after this clock's edge. R1009: from the
  // result registers, selected by the registered schedule.
  logic [4:0]  op_idx [0:3];
  logic [31:0] rfo [0:3], xa_rdo;
  assign op_idx[0] = {ai1[3], 1'b1, ai1[2:0]};
  assign op_idx[1] = {ai2[3], 1'b1, ai2[2:0]};
  assign op_idx[2] = {m1s[3], 1'b0, m1s[2:0]};
  assign op_idx[3] = {m2s[3], 1'b0, m2s[2:0]};
  always_comb begin
    for (int k = 0; k < 4; k++) begin
      rfo[k] = rf_rd[k];
      if (FWD && a_wq && a_wd.we && a_wd.idx == op_idx[k]) rfo[k] = a_wv;
      if (FWD && m_wq && m_wd.we && m_wd.idx == op_idx[k]) rfo[k] = m_wv;
    end
    xa_rdo = xa_rd;
    if (FWD && a_wq && a_wd.we && a_wd.idx == rf_idx(sc[0])) xa_rdo = a_wv;
    if (FWD && m_wq && m_wd.we && m_wd.idx == rf_idx(sc[0])) xa_rdo = m_wv;
  end
  // the in-flight queues: pushed at the go pulse, popped as the unit answers
  logic a_push, a_pop, m_pop, a_wi, m_wi;
  logic [1:0] a_wi2, m_wi2;
  assign a_push = alu_go && !(a_int || a_flog);
  assign a_pop  = add_v || cv_v || div_v;
  assign m_pop  = fmul_v || imul_v;
  assign a_wi2  = af_n - {1'b0, a_pop};
  assign m_wi2  = mf_n - {1'b0, m_pop};
  assign a_wi   = a_wi2[0];
  assign m_wi   = m_wi2[0];
  logic ops_idle;                      // nothing in flight and nothing to write (the bench's lockstep)
  assign ops_idle = (af_n == 2'd0) && !ar_v && (mf_n == 2'd0) && !mr_v && !ag_p && !mg_p;

  // ---------------------------------------------------------------- R1006: hazards at S_DEC
  logic [4:0] ao_idx, mo_idx;
  assign ao_idx  = {ao[3], ao[4], ao[2:0]};
  assign mo_idx  = {mdst[3], mdst[4], mdst[2:0]};
  // the word's transfers into the register file, and whether one writes ST
  logic       tx_rf0, tx_rf1, st_wr_s;
  assign tx_rf0  = dk[0] == K_REG && is_rf(dc[0]);
  assign tx_rf1  = dk[1] == K_REG && is_rf(dc[1]);
  assign st_wr_s = (dk[0] == K_REG && dc[0] == 6'h15) || (dk[1] == K_REG && dc[1] == 6'h15);
  // a transfer to the op's register came after the op in MAME, and the
  // multiply after the ALU: the op's result is dropped (decided here, so its
  // arrival time does not matter)
  logic       alu_sup_s, mul_sup_s, alu_wr_s;
  assign alu_sup_s = (tx_rf0 && rf_idx(dc[0]) == ao_idx) || (tx_rf1 && rf_idx(dc[1]) == ao_idx) ||
                     (mul_op && mo_idx == ao_idx);
  assign mul_sup_s = (tx_rf0 && rf_idx(dc[0]) == mo_idx) || (tx_rf1 && rf_idx(dc[1]) == mo_idx);
  // MAME's ALU ops with a register result: all but FCMP, FABC, NOP and CMP
  assign alu_wr_s  = !(aop == 5'h04 || aop == 5'h06 || aop == 5'h07 || aop == 5'h14);
  // the ALU op's unit (a_fadd / a_cvt / ... on aop, before it is registered)
  logic       d_fadd, d_div, d_cvt, d_imm;
  logic [1:0] d_unit;
  assign d_fadd = (aop[4:3] == 2'b00) && (aop[2:0] != 3'd5) && (aop[2:0] != 3'd7);
  assign d_div  = (aop == 5'h0a) || (aop == 5'h0b);
  assign d_cvt  = (aop == 5'h0d) || (aop == 5'h0e) || (aop == 5'h0f) || (aop[4:2] == 3'b111);
  assign d_imm  = !d_fadd && !d_div && !d_cvt;          // the integer ALU and FLOG: the result at the go pulse
  assign d_unit = d_div ? 2'd2 : d_cvt ? 2'd1 : 2'd0;
  // ISSUE: an op of a class may go while others of its class are in flight
  // only on the same pipelined unit (so they arrive in order, two or more
  // clocks apart) with room in the queue; FRCP / FRSQ and the integer ALU
  // only with nothing in flight -- and then the result register must be free
  // by the time it arrives
  logic a_issue_ok, m_issue_ok;
  assign a_issue_ok = (af_n == 2'd0) ? (!ar_v || a_wr) :
                      (QD2 && af_n == 2'd1) ? (!d_div && !d_imm && d_unit == a_unit && a_unit != 2'd2) : 1'b0;
  assign m_issue_ok = (mf_n == 2'd0) ? (!mr_v || m_wr) :
                      (QD2 && mf_n == 2'd1) ? (m_unit == !isfmul) : 1'b0;
  // RAW / WAW on the scoreboard: a register is free once its result is
  // written by the end of this clock (pend_l) -- S_DEC's own reads take the
  // value forwarded (rfo / xa_rdo), later states read the register file.
  logic [31:0] pend_l;
  assign pend_l = pend & ~wrm_q;                     // R1009: registers only
  logic [31:0] pend_o;                               // what S_DEC itself reads: forwarded, or it waits
  assign pend_o = FWD ? pend_l : pend;
  logic hz_reg, hz_st, rd_st;
  always_comb begin
    hz_reg = 1'b0;
    if (alu_op) begin
      if (pend_o[{ai1[3], 1'b1, ai1[2:0]}]) hz_reg = 1'b1;
      if (alu_src2 && !ai2[4] && pend_o[{ai2[3], 1'b1, ai2[2:0]}]) hz_reg = 1'b1;
      if (alu_wr_s && pend_l[ao_idx]) hz_reg = 1'b1;
    end
    if (mul_op) begin
      if (pend_o[{m1s[3], 1'b0, m1s[2:0]}]) hz_reg = 1'b1;
      if (!m2s[4] && pend_o[{m2s[3], 1'b0, m2s[2:0]}]) hz_reg = 1'b1;
      if (pend_l[mo_idx]) hz_reg = 1'b1;
    end
    if (sk[0] == K_REG && is_rf(sc[0]) && (xs_rf_dec ? pend_o[rf_idx(sc[0])] : pend_l[rf_idx(sc[0])])) hz_reg = 1'b1;
    if (sk[1] == K_REG && is_rf(sc[1]) && pend_l[rf_idx(sc[1])]) hz_reg = 1'b1;
    for (int m = 0; m < 2; m++)
      if (dk[m] == K_REG && is_rf(dc[m]) && pend_l[rf_idx(dc[m])]) hz_reg = 1'b1;
  end
  // ST read (a condition on the flags, a transfer from ST) or written
  assign rd_st = (is_ctl && (cop == 5'h10 || cop == 5'h11 || cop == 5'h18 || cop == 5'h19) && ef1[4:0] < 5'd20) ||
                 (sk[0] == K_REG && sc[0] == 6'h15) || (sk[1] == K_REG && sc[1] == 6'h15) || st_wr_s;
  assign hz_st = rd_st && !ops_idle;
  logic dec_hz;
  assign dec_hz = hz_reg || hz_st || (alu_op && !a_issue_ok) || (mul_op && !m_issue_ok) ||
                  (alu_pr && mul_pr && !ops_idle) ||     // S_PR2 issues a clock late: nothing in flight
                  (needs_fo && wq_busy);                 // an output after every posted write (m2_tgpx4)

  // ---------------------------------------------------------------- word end
  logic dec_stall, eow, acc;
  logic [63:0] acc_word;
  assign dec_stall    = (needs_fi && !fi_valid) || (needs_fo && fo_full);
  logic wx_maybe_ext, wx_hold, seq_rf;
  logic xc_bad;                                   // R1009: a cache word taken on trust that missed
  assign xc_bad = xc_spec && !xc_hq;
  assign wx_maybe_ext = (dk[wm] == K_MEM && !dbus[wm] && !dmask[wm]) || (dk[wm] == K_EXT);
  // R1006: a transfer into the register file waits a clock when a result
  // takes its bank's write port
  assign seq_rf  = (s == S_WXA || s == S_WXB) && !ext_req && !xc_bad && dk[wm] == K_REG && is_rf(wc);
  assign wx_hold = seq_rf && (wc[3] ? res_a_busy : res_m_busy);
  always_comb begin
    case (s)
      // (such a word has nothing to stall on: no FIFO, no register, no op)
      S_DEC:  eow = w_dec1;
      S_XA:   eow = !ext_req && sk[1] == K_NONE && dk[0] == K_NONE && !is_ctl;
      S_WXA, S_WXB:
              // never a control word (its delay slot / REP must be in place
              // before the next word is taken: it ends in S_WAIT), and never a
              // write to ST (the take reads ST's RP)
              // R924: !wx_ext_start (the AGU's sum) became a decode-only test: an A-bus memory
              // destination (internal or external by its address, the AGU's
              // sum) ends the word in a later state instead. That took the
              // AGU off s1312's worst path (ir -> AGU -> eow -> acc -> rpc,
              // -1.525 ns); HOTD writes the A bus ~600 times in 1 G words.
              eow = !xc_bad && !wx_hold && (ext_req ? ext_ack : !wx_maybe_ext) && !(s == S_WXA && dk[1] != K_NONE) &&
                    !is_ctl && !(dk[wm] == K_REG && wc == 6'h15);
      S_WAIT: eow = 1'b1;
      default: eow = 1'b0;
    endcase
  end
  assign acc      = run && ((s == S_FETCH && pm_valid) || (eow && (nx_v || pm_valid)));
  assign acc_word = nx_v ? nx_ir : pm_data;

  // THE INTERNAL WRITE PORTS ARE DRIVEN IN THE CLOCK THAT DECIDES THEM, so a
  // write lands at that clock's edge and the next word -- which may start in
  // the very next clock -- reads it. (Registered, they landed a clock late,
  // and the first prefetching version read stale registers: R920.) The
  // sequencer's data path serves PR, both RAMs and the register file's free
  // bank; the results' writer has the banks first.
  always_comb begin
    rfa_we = 1'b0; rfa_wa = {a_wd.idx[4], a_wd.idx[2:0]}; rfa_wd = a_wv;
    rfm_we = 1'b0; rfm_wa = {m_wd.idx[4], m_wd.idx[2:0]}; rfm_wd = m_wv;
    if (a_wq && a_wd.we) begin
      if (a_wd.idx[3]) begin rfa_we = 1'b1; rfa_wa = {a_wd.idx[4], a_wd.idx[2:0]}; rfa_wd = a_wv; end
      else             begin rfm_we = 1'b1; rfm_wa = {a_wd.idx[4], a_wd.idx[2:0]}; rfm_wd = a_wv; end
    end
    if (m_wq && m_wd.we) begin
      if (m_wd.idx[3]) begin rfa_we = 1'b1; rfa_wa = {m_wd.idx[4], m_wd.idx[2:0]}; rfa_wd = m_wv; end
      else             begin rfm_we = 1'b1; rfm_wa = {m_wd.idx[4], m_wd.idx[2:0]}; rfm_wd = m_wv; end
    end
    if (seq_rf && !wx_hold) begin
      if (wc[3]) begin rfa_we = 1'b1; rfa_wa = {wc[5], wc[2:0]}; rfa_wd = wv; end
      else       begin rfm_we = 1'b1; rfm_wa = {wc[5], wc[2:0]}; rfm_wd = wv; end
    end
  end
  always_comb begin
    pr_we = 1'b0; pr_wa = pwp;
    ra_we = 1'b0; ra_wa = g_ea[9:0];
    rb_we = 1'b0; rb_wa = g_ea[9:0];
    if ((s == S_WXA || s == S_WXB) && !ext_req && !wx_hold && !xc_bad) begin
      if (dk[wm] == K_REG && wc == 6'h30) pr_we = 1'b1;
      if (dk[wm] == K_MEM) begin
        if (dbus[wm])                               rb_we = 1'b1;
        else if (dmask[wm] || g_ea[13:10] == 4'd0)  ra_we = 1'b1;
      end
      if (s == S_WXA && is_ctl && cop == 5'h04) begin   // PUSH
        rb_we = 1'b1; rb_wa = sp - 10'd1;
      end
    end
  end
  assign pr_wd = wv;
  assign ra_wd = wv;
  assign rb_wd = wv;

`ifdef VERILATOR
  // R1006: the checkpoint start's controls, written by the bench only
  logic        dbg_restart    /*verilator public_flat_rw*/;
  logic [11:0] dbg_restart_pc /*verilator public_flat_rw*/;
  initial begin dbg_restart = 1'b0; dbg_restart_pc = 12'd0; end
  localparam logic [63:0] X4_NOP = 64'hC700_0200_0000_0000;   // control NOP, ALU NOP
`endif

  integer k;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s <= S_HALT; ir <= 64'd0; xd <= xdec(64'd0); w_dec1 <= 1'b0; spc_mq <= 1'b0; xs_q <= 1'b0; ir_pc <= 12'd0; nx_ir <= 64'd0; nx_v <= 1'b0; pf_sent <= 1'b0; pc <= 12'd0; delay_pc <= 12'd0; delay_slot <= 1'b0;
      st <= 32'd0; rpc <= 16'd0; lpc <= 16'd0; eb <= 24'd0; eo <= 24'd0; sp <= 10'd0;
      modr <= 16'd0; pdr <= 32'd0; ddr <= 32'd0; prp <= 5'd0; pwp <= 5'd0; pcp <= 2'd0;
      for (k = 0; k < 4; k++) pcs[k] <= 12'd0;
      for (k = 0; k < 8; k++) ar[k] <= 14'd0;
      opa <= 32'd0; opb <= 32'd0; opm1 <= 32'd0; opm2 <= 32'd0;
      add_aq <= 32'd0; add_bq <= 32'd0; add_subq <= 1'b0;
      ag_p <= 1'b0; mg_p <= 1'b0; aop_q <= 5'd0; imm5_q <= 5'd0;
      alu_r <= 32'd0; mul_r <= 32'd0;
      aq_we <= 1'b0; aq_fl <= 1'b0; aq_idx <= 5'd0; mq_we <= 1'b0; mq_fl <= 1'b0; mq_idx <= 5'd0; mq_isf <= 1'b0;
      af[0] <= '0; af[1] <= '0; mf[0] <= '0; mf[1] <= '0; af_n <= 2'd0; mf_n <= 2'd0;
      a_unit <= 2'd0; m_unit <= 1'b0; ar_v <= 1'b0; mr_v <= 1'b0; ard <= '0; mrd <= '0;
      pend <= 32'd0; a_wq <= 1'b0; m_wq <= 1'b0; wrm_q <= 32'd0; a_ws <= 1'b0; m_ws <= 1'b0;
      for (k = 0; k < 2; k++) begin acnt[k] <= 3'd0; mcnt[k] <= 3'd0; apred[k] <= 1'b0; end
      fa_an <= 1'b0; fa_az <= 1'b0; fa_zc <= 1'b0; fa_x <= 1'b0; fa_au <= 1'b0; fa_av <= 1'b0;
      fa_upd <= 1'b0; fa_zcu <= 1'b0;
      fm_n <= 1'b0; fm_z <= 1'b0; fm_d <= 1'b0; fm_v <= 1'b0; fm_u <= 1'b0;
      imul_p1 <= 32'd0; imul_r <= 32'd0; imul_v1 <= 1'b0; imul_v <= 1'b0;
      frsq_pend <= 1'b0;
      mv_val[0] <= 32'd0; mv_val[1] <= 32'd0; pr_dec <= 32'd0; ctl_ary <= 14'd0;
      ctl_take <= 1'b0; ctl_tgt <= 12'd0; xc_pend <= 1'b0; xc_fill <= 1'b0; xc_spec <= 1'b0; xc_hq <= 1'b0;
      fi_pop <= 1'b0; fi_clr <= 1'b0; fo_push <= 1'b0; fo_data <= 32'd0; fo_clr <= 1'b0;
      ext_req <= 1'b0; ext_we <= 1'b0; ext_addr <= 24'd0; ext_wdata <= 32'd0;
      dbg_retire <= 1'b0; dbg_bad <= 1'b0;
    end else begin
      if (alu_go) ag_p <= 1'b0;
      if (mul_go) mg_p <= 1'b0;
      fi_pop <= 1'b0; fi_clr <= 1'b0; fo_push <= 1'b0; fo_clr <= 1'b0;
      dbg_retire <= 1'b0;

      // ---------------------------------------------- R1006 / R1009: results written
      // (on the schedule decided last clock: a_wq / m_wq; the bank ports too)
      if (a_wq) begin
        if (a_wd.we) pend[a_wd.idx] <= 1'b0;
        if (a_wd.fl) begin
          if (w_aupd && a_wd.aop != 5'h0f) begin st[F_AN] <= w_aan; st[F_AZ] <= w_aaz; end
          if (a_wd.aop == 5'h0f) begin                 // CFIB: AZ, and AU / AV only set
            st[F_AZ] <= w_aaz; if (w_aau) st[F_AU] <= 1'b1; if (w_aav) st[F_AV] <= 1'b1;
          end
          if (w_azcu) st[F_ZC] <= w_azc;
          if (a_wd.aop == 5'h0a) st[F_ZD] <= w_ax;
          if (a_wd.aop == 5'h0b) st[F_NR] <= w_ax;
        end
      end
      if (m_wq) begin
        if (m_wd.we) pend[m_wd.idx] <= 1'b0;
        if (m_wd.fl) begin                             // FMUL: MV / MU only set
          st[F_MN] <= w_mn; st[F_MZ] <= w_mz; if (m_wd.aop[0]) st[F_MD] <= w_md;
          if (w_mv) st[F_MV] <= 1'b1; if (w_mu) st[F_MU] <= 1'b1;
        end
      end
      // an arriving result not written now is registered; next clock's schedule
      ar_v <= ar_vn; mr_v <= mr_vn;
      if (a_keep) begin
        alu_r <= a_cv_arr; ard <= a_cd_arr;
        fa_upd <= a_aupd; fa_an <= a_aan; fa_az <= a_aaz; fa_zcu <= a_azcu; fa_zc <= a_azc;
        fa_au <= a_aau; fa_av <= a_aav; fa_x <= a_ax;
      end
      if (m_keep) begin
        mul_r <= m_cv_arr; mrd <= mf[0];
        fm_n <= m_an; fm_z <= m_az; fm_d <= m_ad; fm_v <= m_av; fm_u <= m_au;
      end
      a_wq <= a_wqn; m_wq <= m_wqn; wrm_q <= wrm_n; a_ws <= !ar_vn; m_ws <= !mr_vn;
      // the countdowns
      for (k = 0; k < 2; k++) begin
        if (acnt[k] != 3'd0) acnt[k] <= acnt[k] - 3'd1;
        if (mcnt[k] != 3'd0) mcnt[k] <= mcnt[k] - 3'd1;
      end
      if (a_pop && af_n == 2'd2) begin acnt[0] <= (acnt[1] != 3'd0) ? acnt[1] - 3'd1 : 3'd0; apred[0] <= apred[1]; end
      if (m_pop && mf_n == 2'd2) mcnt[0] <= (mcnt[1] != 3'd0) ? mcnt[1] - 3'd1 : 3'd0;

      // ---------------------------------------------- issue (the go pulse)
      // the integer ALU's result is there at once; every other op's
      // descriptor queues until its unit answers
      if (a_push) begin
        af[a_wi] <= mkd(aq_we, aq_idx, aq_fl, aop_q, 1'b0,
            go_anan || go_bnan, go_anan ? {add_aq[31], add_aq[21:0]} : {add_bq[31], add_bq[21:0]});
        acnt[a_wi] <= a_cvt ? 3'd4 : 3'd2;           // latency - 2: cvt 6, fp_add 4
        apred[a_wi] <= !(a_frcp || a_frsq);
        a_unit <= a_cvt ? 2'd1 : (a_frcp || a_frsq) ? 2'd2 : 2'd0;
      end
      if (mul_go) begin
        mf[m_wi] <= mkd(mq_we, mq_idx, mq_fl, {4'd0, mq_isf}, 1'b0,
            go_m1nan || go_m2nan, go_m1nan ? {opm1[31], opm1[21:0]} : {opm2[31], opm2[21:0]});
        mcnt[m_wi] <= mq_isf ? 3'd2 : 3'd0;           // fp_mul 4, the integer multiply 2
        m_unit <= !mq_isf;
      end
      af_n <= af_n + {1'b0, a_push} - {1'b0, a_pop};
      mf_n <= mf_n + {1'b0, mul_go} - {1'b0, m_pop};
      if (a_pop && af_n == 2'd2) af[0] <= af[1];
      if (m_pop && mf_n == 2'd2) mf[0] <= mf[1];

      // ---------------------------------------------- the units
      imul_v1 <= mul_go && !mq_isf;
      imul_p1 <= opm1 * opm2;
      imul_v  <= imul_v1;
      imul_r  <= imul_p1;
      if (alu_go && a_flog) dbg_bad <= 1'b1;
      if (div_v) frsq_pend <= 1'b0;
      if (sq_go) frsq_pend <= 1'b1;

      case (s)
        // ------------------------------------------------------------ halted
        S_HALT: begin
          pc <= 12'd0; delay_slot <= 1'b0; nx_v <= 1'b0; pf_sent <= 1'b0;
          if (run) s <= S_FETCH;
        end

        // ------------------------------------------------------------ fetch
        S_FETCH: begin
          if (!run) s <= S_HALT;           // the word itself is taken at acc, below
        end

        // ------------------------------------------------------------ decode
        S_DEC: begin
          pf_sent <= 1'b1;
          if (dec_stall || dec_hz) begin
            s <= S_DEC;                               // stall: nothing done yet
          end else begin
            spc_mq <= 1'b1;                           // R1009: source B's special read, from here on
            // ALU / multiplier operands -- R1006: only for a word with the
            // operation (FRCP / FRSQ read opa until they answer)
            if (alu_op) begin
              opa  <= rfo[0];
              opb  <= opb_n;
              add_aq   <= dec_swap ? ((aop == 5'h06) ? {1'b0, opb_n[30:0]} : opb_n) : rfo[0];
              add_bq   <= dec_swap ? ((aop == 5'h06) ? {1'b0, rfo[0][30:0]} : rfo[0]) : opb_n;
              add_subq <= dec_swap;
              aop_q  <= aop;
              imm5_q <= ai2;
              aq_we  <= alu_wr_s && !alu_sup_s; aq_idx <= ao_idx; aq_fl <= !st_wr_s;
              if (alu_wr_s && !alu_sup_s) pend[ao_idx] <= 1'b1;
            end
            if (mul_op) begin
              opm1 <= rfo[2];
              opm2 <= (m2s[4:3] == 2'd2) ? pr_rd :
                      (m2s[4:3] == 2'd3) ? cst(m2s[2:0], isfmul) : rfo[3];
              mq_we  <= !mul_sup_s; mq_idx <= mo_idx; mq_fl <= !st_wr_s; mq_isf <= isfmul;
              if (!mul_sup_s) pend[mo_idx] <= 1'b1;
            end
            if (alu_pr) prp <= prp_step(prp, ai2[2:0]);
            else if (mul_pr) prp <= prp_step(prp, m2s[2:0]);
            if (!(alu_pr && mul_pr)) begin
              ag_p <= alu_op;
              mg_p <= mul_op;
            end
            // source A: special registers now (MAME reads them before the ALU)
            pr_dec <= pr_rd;
            if (sk[0] == K_REG && !is_rf(sc[0])) begin
              mv_val[0] <= spc_now;
              if (sc[0] == 6'h31) fi_pop <= 1'b1;
            end
            if (sk[0] == K_IMM) mv_val[0] <= imm;
            if (xs_rf_dec) mv_val[0] <= xa_rdo;        // R1006: no S_XA for it
            // source A's address, and its AR update
            if (sk[0] == K_MEM && !is_ctl) begin
              if (g_we) ar[g_sely ? g_ry : g_rx] <= g_arw;
            end
            if (sk[0] == K_EXT) begin
              ext_we <= 1'b0; ext_addr <= x_dec_a;
              if (x_dec_rom) xc_pend <= 1'b1;           // R1006: the cache answers in S_XA
              else ext_req <= 1'b1;
            end else if (sk[0] == K_MEM && !sbus[0] && !smask[0] && !is_ctl && (g_ea[13:10] != 4'd0)) begin
              ext_req <= 1'b1; ext_we <= 1'b0; ext_addr <= {eb[23:14], g_ea};
            end
            // control flow: condition now, target when it arrives
            if (is_ctl) begin
              ctl_ary <= g_ary;
              case (cop)
                5'h10: ctl_take <= cond;
                5'h11: ctl_take <= !cond;
                5'h12, 5'h1a, 5'h1b: ctl_take <= 1'b1;
                5'h13: ctl_take <= st[F_LP];
                5'h14: ctl_take <= !ar_bt[ir[19:16]];
                5'h15: ctl_take <=  ar_bt[ir[19:16]];
                5'h18: ctl_take <= cond;
                5'h19: ctl_take <= !cond;
                default: ctl_take <= 1'b0;
              endcase
              case (ir[15:13])
                3'd0: ctl_tgt <= ir[11:0];
                3'd1: ctl_tgt <= g_arx[11:0];
                default: ctl_tgt <= 12'd0;
              endcase
            end
            // R1006: a control word with nothing to fetch, now (as S_WXA does)
            if (ctl_dec) begin
              case (cop)
                5'h01: begin st[F_RP] <= 1'b1; rpc <= (ef1 == 6'h3f) ? {2'd0, g_ary} : ef2; end
                5'h02: begin st[F_LP] <= 1'b1; lpc <= (ef1 == 6'h3f) ? {2'd0, g_ary} : ef2; end
                5'h03: begin fi_clr <= ef1[0]; fo_clr <= ef1[1]; end
                5'h08: modr <= ef2;
                5'h09: modr <= (modr & ~16'h7000) | ef2;
                5'h0a: modr <= (modr & ~16'h0e00) | ef2;
                5'h0b: modr <= (modr & ~16'h0080) | ef2;
                5'h0c: modr <= (modr & ~16'h0010) | ef2;
                5'h0d: modr <= (modr & ~16'h0007) | ef2;
                5'h13: begin
                  lpc <= lpc - 16'd1;
                  if (lpc == 16'd2) st[F_LP] <= 1'b0;
                end
                default: ;
              endcase
              if (take_d) begin
                delay_slot <= 1'b1;
                delay_pc   <= ctl_t_d;
                if (cop == 5'h18 || cop == 5'h19 || cop == 5'h1a) begin
                  pcs[pcp] <= pc + 12'd1; pcp <= pcp + 2'd1;
                end
                if (cop == 5'h1b) pcp <= pcp - 2'd1;
              end
            end
            if (alu_pr && mul_pr)                     s <= S_PR2;
            else if (sk[0] != K_NONE && !xa_skip)     s <= S_XA;
            else if (dk[0] != K_NONE || (is_ctl && !ctl_dec)) s <= S_WXA;
            else                                      s <= S_WAIT;
          end
        end

        S_PR2: begin
          opm2 <= pr_rd;
          prp  <= prp_step(prp, m2s[2:0]);
          ag_p <= alu_op;
          mg_p <= mul_op;
          if (sk[0] != K_NONE && !xa_skip)            s <= S_XA;
          else if (dk[0] != K_NONE || (is_ctl && !ctl_dec)) s <= S_WXA;
          else                                        s <= S_WAIT;
        end

        // ------------------------------------------------------------ sources
        S_XA: begin
          if (ext_req) begin
            if (ext_ack) begin ext_req <= 1'b0; mv_val[0] <= ext_rdata; xc_fill <= 1'b0; end
          end else begin
            // R1009: THE CACHE'S WORD IS TAKEN ON TRUST and its tag compare
            // registered (xc_hq): its M10K outputs went through the compare
            // straight into the sequencer (lpc, nx_ir, modr, ar, rpc: -1.4 to
            // -2.0 ns on s2520-s2561). The next state (S_WXA: an external
            // source always has a destination) acts on it only if it hit;
            // on a miss it writes nothing and goes back to S_XA, to memory.
            if (xc_pend) begin xc_pend <= 1'b0; xc_spec <= 1'b1; xc_hq <= xc_hit; mv_val[0] <= xc_q; end
            if (sk[0] == K_REG && is_rf(sc[0])) mv_val[0] <= xa_rd;
            if (sk[0] == K_MEM) mv_val[0] <= sbus[0] ? rb_q : ra_q;
            // source B: a special register, or its address
            if (sk[1] == K_REG && !is_rf(sc[1])) begin
              mv_val[1] <= spc_now;
              if (sc[1] == 6'h31) fi_pop <= 1'b1;
            end
            if (sk[1] == K_MEM && g_we) ar[g_sely ? g_ry : g_rx] <= g_arw;
            if (sk[1] != K_NONE)                      s <= S_XB;
            else if (dk[0] != K_NONE || is_ctl)       s <= S_WXA;
            else                                      s <= S_WAIT;
          end
        end

        S_XB: begin
          if (sk[1] == K_REG && is_rf(sc[1])) mv_val[1] <= xb_rd;
          if (sk[1] == K_MEM) mv_val[1] <= rb_q;
          s <= S_WXA;
        end

        // ------------------------------------------------------------ destinations
        S_WXA, S_WXB: begin
          if (ext_req) begin
            if (ext_ack) begin
              ext_req <= 1'b0;
              if (eo_upd) eo <= eo + {{18{eo_disp[5]}}, eo_disp};
              s <= (s == S_WXA && dk[1] != K_NONE) ? S_WXB : S_WAIT;
            end
          end else if (xc_bad) begin                  // R1009: the cache missed -- back to S_XA, to memory
            xc_spec <= 1'b0; ext_req <= 1'b1; xc_fill <= 1'b1; s <= S_XA;
          end else if (!wx_hold) begin                // R1006: else its bank's port is a result's this clock
            xc_spec <= 1'b0;
            case (dk[wm])
              K_REG: begin
                if (!is_rf(wc)) begin                 // the register file: the write-port block
                  case (wc)
                    6'h10: eb <= wv[23:0];
                    6'h11: eb <= {wv[9:0], eb[13:0]};
                    6'h12: eb <= {wv[9:0], 14'd0};   // MAME: (eb & 0xffc000) | (wv << 14)
                    6'h13: eo <= wv[23:0];
                    6'h14: sp <= wv[9:0];
                    6'h15: st <= wv;                  // R1006: the word's own ops' flags are dropped (aq_fl / mq_fl)
                    6'h16: modr <= wv[15:0];
                    6'h17: lpc <= wv[15:0];
                    6'h30: begin pwp <= (pwp == 5'd23) ? 5'd0 : pwp + 5'd1; end
                    6'h32, 6'h33: begin fo_push <= 1'b1; fo_data <= wv; end
                    6'h34: pdr <= wv;
                    6'h35: ddr <= wv;
                    6'h36: prp <= wv[4:0];
                    6'h37: pwp <= wv[4:0];
                    default: if (wc[5:3] == 3'b011) ar[wc[2:0]] <= wv[13:0];
                    else dbg_bad <= 1'b1;
                  endcase
                end
              end
              K_MEM: begin
                if (g_we) ar[g_sely ? g_ry : g_rx] <= g_arw;
                if (dbus[wm]) begin
                end else if (dmask[wm] || g_ea[13:10] == 4'd0) begin
                end else begin
                  ext_req <= 1'b1; ext_we <= 1'b1; ext_addr <= {eb[23:14], g_ea}; ext_wdata <= wv;
                end
              end
              K_EXT: begin
                ext_req <= 1'b1; ext_we <= 1'b1; ext_addr <= eb + eo; ext_wdata <= wv;
              end
              default: ;
            endcase
            if (sk[wm] == K_EXT && eo_upd) eo <= eo + {{18{eo_disp[5]}}, eo_disp};
            // control flow, once, with destination A
            if (s == S_WXA && is_ctl) begin
              case (cop)
                5'h01: begin st[F_RP] <= 1'b1; rpc <= (ef1 == 6'h3f) ? {2'd0, ctl_ary} : ef2; end
                5'h02: begin st[F_LP] <= 1'b1; lpc <= (ef1 == 6'h3f) ? {2'd0, ctl_ary} : ef2; end
                5'h03: begin fi_clr <= ef1[0]; fo_clr <= ef1[1]; end
                5'h04: begin
                  sp <= sp - 10'd1;
                 
                end
                5'h05: sp <= sp + 10'd1;
                5'h08: modr <= ef2;
                5'h09: modr <= (modr & ~16'h7000) | ef2;
                5'h0a: modr <= (modr & ~16'h0e00) | ef2;
                5'h0b: modr <= (modr & ~16'h0080) | ef2;
                5'h0c: modr <= (modr & ~16'h0010) | ef2;
                5'h0d: modr <= (modr & ~16'h0007) | ef2;
                5'h13: begin
                  lpc <= lpc - 16'd1;
                  if (lpc == 16'd2) st[F_LP] <= 1'b0;
                end
                default: ;
              endcase
              if (ctl_take) begin
                delay_slot <= 1'b1;
                delay_pc   <= ctl_t;
                if (cop == 5'h18 || cop == 5'h19 || cop == 5'h1a) begin
                  pcs[pcp] <= pc + 12'd1; pcp <= pcp + 2'd1;
                end
                if (cop == 5'h1b) pcp <= pcp - 2'd1;
              end
            end
            if (!((dk[wm] == K_MEM && !dbus[wm] && !dmask[wm] && g_ea[13:10] != 4'd0) || dk[wm] == K_EXT))
              s <= (s == S_WXA && dk[1] != K_NONE) ? S_WXB : S_WAIT;
          end
        end

        // ------------------------------------------------------------ the end
        // S_WAIT ends the word (eow); R1006: the results are the writer's
        S_WAIT: ;

        default: s <= S_HALT;
      endcase

      // ------------------------------------------------ the next word
      if (pm_valid && s != S_HALT && !acc) begin nx_ir <= pm_data; nx_v <= 1'b1; end
      if (eow && !acc) s <= run ? S_FETCH : S_HALT;
      if (acc) begin
        // MAME execute_run: the PC steps (or the delay slot / repeat
        // applies) as the word is taken, before it executes
        ir <= acc_word; xd <= xdec(acc_word); ir_pc <= pc;   // R934: xd with ir
        w_dec1 <= dec_end(acc_word, xdec(acc_word));          // R1009
        xs_q   <= xs_dec(acc_word, xdec(acc_word));
        spc_mq <= 1'b0;
        nx_v <= 1'b0; pf_sent <= 1'b0;
        dbg_retire <= 1'b1;
        if (delay_slot) begin
          pc <= delay_pc; delay_slot <= 1'b0;
        end else if (st[F_RP]) begin
          rpc <= rpc - 16'd1;
          if (rpc == 16'd2) st[F_RP] <= 1'b0;
        end else begin
          pc <= pc + 12'd1;
        end
        ctl_take <= 1'b0;
        // R1006: the operations still in flight are no longer the word's in the sequencer
        s <= S_DEC;
      end
`ifdef VERILATOR
      // R1006: THE BENCH'S CHECKPOINT START (tb_tgpx4_replay --ck-frame): the
      // word in hand becomes a NOP (a control word, ALU NOP, no transfer) and
      // the next one is fetched from dbg_restart_pc; the FIFOs are emptied. The
      // bench then writes the reference's state into the registers and RAMs.
      if (dbg_restart) begin
        s <= S_DEC; ir <= X4_NOP; xd <= xdec(X4_NOP); ir_pc <= dbg_restart_pc; w_dec1 <= 1'b0; spc_mq <= 1'b0; xs_q <= 1'b0;
        pc <= dbg_restart_pc; nx_v <= 1'b0; pf_sent <= 1'b0; delay_slot <= 1'b0;
        ctl_take <= 1'b0; ext_req <= 1'b0; fi_clr <= 1'b1; fo_clr <= 1'b1; xc_pend <= 1'b0; xc_fill <= 1'b0; xc_spec <= 1'b0;
        af_n <= 2'd0; mf_n <= 2'd0; ar_v <= 1'b0; mr_v <= 1'b0; pend <= 32'd0;
        a_wq <= 1'b0; m_wq <= 1'b0; wrm_q <= 32'd0; ag_p <= 1'b0; mg_p <= 1'b0; a_ws <= 1'b0; m_ws <= 1'b0;
      end
`endif
    end
  end

`ifdef VERILATOR
  logic pa_q, pm_q;                    // R1009: the arrivals predicted last clock
  always_ff @(posedge clk) begin pa_q <= pa_n; pm_q <= pm_n; end
  // R1006: the queues never overflow, a unit never answers with nothing in
  // flight, and a result never lands on one not yet written
  /* verilator lint_off SYNCASYNCNET */
  always_ff @(posedge clk)
    if (rst_n && ((a_push && a_wi2 > 2'd1) || (mul_go && m_wi2 > 2'd1) || (a_pop && af_n == 2'd0) ||
                  (m_pop && mf_n == 2'd0) ||
                  (ar_v && !(a_wq && !a_ws) && a_keep) || (mr_v && !(m_wq && !m_ws) && m_keep) ||
                  ((a_pop && apred[0]) != pa_q) || (m_pop != pm_q) || (a_wq && a_ws && !a_pop) || (m_wq && m_ws && !m_pop) ||
                  (eow && (ag_p || mg_p) && !(alu_go || !ag_p) ) || (eow && mg_p && !mul_go))) begin
      $display("tgpx4_core: R1006 queue fault at pc %03x (af_n %0d mf_n %0d ar_v %0d mr_v %0d)", ir_pc, af_n, mf_n, ar_v, mr_v);
      $stop;
    end
  /* verilator lint_on SYNCASYNCNET */
  // R934: the registered decode is the decode of ir, every clock
  /* verilator lint_off SYNCASYNCNET */
  always_ff @(posedge clk)
    if (rst_n && (xd != xdec(ir) || w_dec1 != dec_end(ir, xd) || xs_q != xs_dec(ir, xd))) begin
      $display("tgpx4_core: xd != xdec(ir) at pc %03x", ir_pc);
      $stop;
    end
  /* verilator lint_on SYNCASYNCNET */
`endif

  assign dbg_pc  = pc;
  assign dbg_pdr = pdr;

endmodule
