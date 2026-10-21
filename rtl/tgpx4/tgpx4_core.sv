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
//   S_WAIT   until the FP units are done (they started at the end of S_DEC);
//            a result counts in the clock it arrives
//   S_WA     ALU result and flags
//   S_FIN    multiplier result and flags
//
// The word ends in whichever of these is its last (eow), and the next word,
// already fetched, is accepted in the same clock.
//
// States a word does not need are skipped. An ALU + multiply + one transfer
// word takes 8 clocks (FP latency 4 under the transfer), a transfer alone 3,
// an integer op 3 (R920's measured table): 10-27 M words a second against
// the chip's 20.
//
// The register file is MAME's AA0-7 / AB0-7 / MA0-7 / MB0-7 as one 32 x 32
// array, written through one port and read through four MLAB copies (one
// per ALU / multiplier operand). Index {sel1, sel0, n}: 00 MA, 01 AA, 10 MB,
// 11 AB.
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
  parameter bit          SUBNORM = 1'b1
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
  // four read copies, one write port
  logic        rf_we;
  logic [4:0]  rf_wa;
  logic [31:0] rf_wd;
  logic [4:0]  rf_ra [0:3];
  logic [31:0] rf_rd [0:3];

  genvar gi;
  generate
    for (gi = 0; gi < 4; gi++) begin : g_rf
      tgpx4_rf u_rf (.clk(clk), .we(rf_we), .wa(rf_wa), .wd(rf_wd), .ra(rf_ra[gi]), .rd(rf_rd[gi]));
    end
  endgenerate

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

  // ======================================================== transfer decode
  // Each word moves at most two values, A and B, each from a source to a
  // destination. Kinds:
  localparam logic [2:0] K_NONE = 3'd0, K_REG = 3'd1, K_MEM = 3'd2,
                         K_EXT = 3'd3, K_IMM = 3'd4;

  logic [2:0]  sk [0:1], dk [0:1];          // source / destination kind
  logic [5:0]  sc [0:1], dc [0:1];          // register codes (transfer map)
  logic        sbus [0:1], dbus [0:1];      // 1 = B bus RAM
  logic        smask [0:1], dmask [0:1];    // address & 0x3ff (internal only)
  logic [3:0]  amode [0:1];                 // AGU fields, per move
  logic [2:0]  arx [0:1], ary [0:1];
  logic [13:0] adisp [0:1];
  logic [31:0] imm;
  logic        eo_upd;
  logic [5:0]  eo_disp;

  logic [4:0] cop;
  logic [5:0] ef1;
  logic [15:0] ef2;
  assign cop = ir[26:22];
  assign ef1 = ir[21:16];
  assign ef2 = ir[15:0];

  logic        t1_ext, t1_dir;
  logic [6:0]  t1_rr, t1_sr7;
  assign t1_ext = (top == 3'd1) ? ir[26] : ir[38];
  assign t1_dir = (top == 3'd1) ? ir[25] : ir[37];
  assign t1_rr  = (top == 3'd1) ? ir[18:12] : ir[30:24];
  assign t1_sr7 = (top == 3'd1) ? ir[25:19] : ir[37:31];

  always_comb begin
    for (int m = 0; m < 2; m++) begin
      sk[m] = K_NONE; dk[m] = K_NONE; sc[m] = 6'd0; dc[m] = 6'd0;
      sbus[m] = 1'b0; dbus[m] = 1'b0; smask[m] = 1'b0; dmask[m] = 1'b0;
      amode[m] = ir[3:0]; arx[m] = 3'd0; ary[m] = ir[6:4]; adisp[m] = 14'd0;
    end
    imm = 32'd0; eo_upd = 1'b0; eo_disp = 6'd0;
    case (top)
      3'd0: begin                                   // double transfer type 1
        // A
        sc[0] = {1'b0, ir[24:20]}; dc[0] = {1'b0, ir[24:20]};
        arx[0] = ir[19:17]; ary[0] = ir[16:14];
        // B
        sc[1] = {2'b10, ir[13:10]}; dc[1] = {2'b10, ir[13:10]};
        arx[1] = ir[9:7]; ary[1] = ir[6:4]; sbus[1] = 1'b1; dbus[1] = 1'b1;
        case (ir[26:25])
          2'd0: begin sk[0] = K_REG; dk[0] = K_REG; sk[1] = K_REG; dk[1] = K_REG; end
          2'd1: begin sk[0] = K_REG; dk[0] = K_MEM; sk[1] = K_REG; dk[1] = K_MEM; end
          2'd2: begin sk[0] = K_MEM; dk[0] = K_REG; sk[1] = K_MEM; dk[1] = K_REG; end
          default: ;
        endcase
      end
      3'd1, 3'd5: begin                             // single transfer types 1 / 2
        adisp[0] = (top == 3'd1) ? {9'd0, ir[11:7]} : ir[20:7];
        if (t1_ext) begin
          eo_upd  = 1'b1;
          eo_disp = (top == 3'd1) ? ir[24:19] : ir[36:31];
          arx[0]  = t1_rr[2:0];
          if (t1_dir) begin                            // external -> internal
            sk[0] = K_EXT;
            dk[0] = t1_rr[6] ? K_MEM : K_REG; dc[0] = t1_rr[5:0];
            dbus[0] = t1_rr[5]; dmask[0] = 1'b1;
          end else begin                            // internal -> external
            sk[0] = t1_rr[6] ? K_MEM : K_REG; sc[0] = t1_rr[5:0];
            sbus[0] = t1_rr[5]; smask[0] = 1'b1;
            dk[0] = K_EXT;
          end
        end else begin
          if (t1_sr7 == 7'h58) begin
            sk[0] = K_IMM;
            imm   = (top == 3'd1) ? {20'd0, ir[11:0]} : {8'd0, ir[23:0]};
          end else begin
            sk[0] = t1_sr7[6] ? K_MEM : K_REG; sc[0] = t1_sr7[5:0]; sbus[0] = t1_sr7[5];
          end
          dk[0] = t1_rr[6] ? K_MEM : K_REG; dc[0] = t1_rr[5:0]; dbus[0] = t1_rr[5];
          // source and destination each take an address from the same
          // fields with their own ARx: the AGU runs twice, source first
          arx[0] = t1_sr7[2:0]; arx[1] = t1_rr[2:0];
          amode[1] = ir[3:0]; ary[1] = ir[6:4]; adisp[1] = adisp[0];
        end
      end
      3'd4: begin                                   // double transfer type 2
        amode[0] = ir[23:20]; arx[0] = ir[32:30]; ary[0] = ir[29:27];
        adisp[0] = {11'd0, ir[26:24]};
        amode[1] = ir[3:0];   arx[1] = ir[12:10]; ary[1] = ir[9:7];
        adisp[1] = {11'd0, ir[6:4]};
        sbus[1] = 1'b1; dbus[1] = 1'b1;
        sc[0] = {1'b0, ir[37:33]}; dc[0] = {1'b0, ir[32:28]};
        sc[1] = {1'b1, ir[17:13]}; dc[1] = {1'b1, ir[12:8]};
        case (ir[39:38])
          2'd0: begin sk[0] = K_REG; dk[0] = K_REG; end
          2'd1: begin sk[0] = K_REG; dk[0] = K_MEM; end
          2'd2: begin sk[0] = K_MEM; dk[0] = K_REG; end
          default: ;
        endcase
        case (ir[19:18])
          2'd0: begin sk[1] = K_REG; dk[1] = K_REG; end
          2'd1: begin sk[1] = K_REG; dk[1] = K_MEM; end
          2'd2: begin sk[1] = K_MEM; dk[1] = K_REG; end
          default: ;
        endcase
      end
      3'd7: begin                                   // immediate
        sk[0] = K_IMM; imm = ir[58:27];
        dk[0] = ir[25] ? K_MEM : K_REG; dc[0] = ir[24:19]; dbus[0] = ir[24];
        arx[0] = ir[21:19]; adisp[0] = {2'd0, ir[18:7]};
      end
      3'd2, 3'd6: begin                             // control
        case (cop)
          5'h04: begin                              // PUSH: B[--SP] = reg
            sk[0] = K_REG; sc[0] = ef2[11:6];
          end
          5'h05: begin                              // POP: reg = B[SP++], after the ALU
            sk[0] = K_MEM; sbus[0] = 1'b1;
            dk[0] = K_REG; dc[0] = ef2[11:6];
          end
          default: ;
        endcase
        // control words take ARs through the AGU's ports: ARx = the target
        // register (ir[8:6]), ARy = the tested / counted one (ir[15:13])
        arx[0] = ir[8:6]; ary[0] = ir[15:13];
        case (cop)
          5'h10, 5'h11, 5'h12, 5'h18, 5'h19, 5'h1a: begin
            // the jump target, do_control_dst
            case (ir[15:13])
              3'd2: begin sk[0] = K_REG; sc[0] = {ir[11] ? 3'b101 : 3'b001, ir[8:6]}; end
              3'd3: begin sk[0] = K_REG; sc[0] = {ir[11] ? 3'b100 : 3'b000, ir[8:6]}; end
              3'd4, 3'd6: begin sk[0] = K_MEM; sbus[0] = 1'b0; end
              3'd5, 3'd7: begin sk[0] = K_MEM; sbus[0] = 1'b1; smask[0] = 1'b1; end
              default: ;                            // immediate / ARx: no fetch
            endcase
          end
          default: ;
        endcase
      end
      default: ;
    endcase
  end

  // ======================================================== AGU (one)
  logic        agu_m;         // which move's fields
  logic        agu_dst;       // destination pass (type 1 / 2 single transfers)
  logic [3:0]  g_mode;
  logic [13:0] g_arx, g_ary, g_disp, g_ea, g_arw;
  logic        g_isb, g_we, g_sely;
  logic [2:0]  g_rx, g_ry;
  logic        single_two;    // single transfer: destination uses fields [1]

  assign single_two = (top == 3'd1 || top == 3'd5) && !(top == 3'd1 ? ir[26] : ir[38]);

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
  logic        alu_go, mul_go;
  logic [4:0]  aop_q;
  logic [4:0]  imm5_q;

  // fp_add
  logic        add_go;
  logic [31:0] add_a, add_b;
  logic        add_sub;
  logic        add_v;
  logic [31:0] add_r;
  logic        add_ov, add_un, add_inv;
  fp_add #(.SUBNORM(SUBNORM)) u_add (
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
  assign add_a   = (aop_q[1] || aop_q == 5'h04) ? (aop_q == 5'h06 ? {1'b0, opb[30:0]} : opb) : opa;
  assign add_b   = (aop_q[1] || aop_q == 5'h04) ? (aop_q == 5'h06 ? {1'b0, opa[30:0]} : opa) : opb;
  assign add_sub = aop_q[1] || (aop_q == 5'h04);
  assign cv_go   = alu_go && a_cvt;
  assign sq_go   = alu_go && a_frsq;

  logic frsq_pend;
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

  // ======================================================== ALU / MUL results
  logic        alu_pend, alu_done, mul_pend, mul_done;
  logic [31:0] alu_r, mul_r;
  logic        alu_wr;               // the op has a register result
  // flags as computed, applied by opcode class at S_WA / S_FIN
  logic        fa_an, fa_az, fa_zc, fa_x, fa_au, fa_av;   // fa_x: ZD / NR
  logic        fa_upd, fa_zcu;
  logic        fm_n, fm_z, fm_d, fm_v, fm_u;

  assign fmul_go = mul_go && isfmul;

  function automatic logic f_neg(input logic [31:0] f);
    f_neg = f[31] && (f[30:0] != 31'd0) && !(f[30:23] == 8'hff && f[22:0] != 23'd0);
  endfunction
  function automatic logic f_zero(input logic [31:0] f);
    f_zero = (f[30:0] == 31'd0);
  endfunction

  logic        add_zc;
  logic [31:0] add_d;
  assign add_zc = aop_q[0] && !aop_q[2] && f_neg(add_r);     // FADDZ / FSUBZ clamp
  assign add_d  = add_zc ? 32'd0 : add_r;

  // ======================================================== moves in flight
  logic [31:0] mv_val [0:1];
  logic        xw_rf_v [0:1];
  logic [4:0]  xw_rf_i [0:1];
  logic        xw_st;
  logic        ctl_take;
  logic [11:0] ctl_tgt;

  // ======================================================== sequencer
  // combinational port use
  always_comb begin
    pm_req  = 1'b0;
    pm_addr = pc;
    rf_ra[0] = {ai1[3], 1'b1, ai1[2:0]};
    rf_ra[1] = {ai2[3], 1'b1, ai2[2:0]};
    rf_ra[2] = {m1s[3], 1'b0, m1s[2:0]};
    rf_ra[3] = {m2s[3], 1'b0, m2s[2:0]};
    if (s == S_XA) rf_ra[0] = rf_idx(sc[0]);
    if (s == S_XB) rf_ra[1] = rf_idx(sc[1]);
    agu_m   = (s == S_XA || s == S_WXB) ? 1'b1 : 1'b0;
    agu_dst = (s == S_WXA || s == S_WXB);
    ra_ra = is_ctl ? ctl_ea[9:0] : g_ea[9:0];
    rb_ra = (is_ctl && (cop == 5'h05)) ? sp : (is_ctl ? ctl_ea[9:0] : g_ea[9:0]);
    if ((s == S_DEC && !pf_sent) || (s == S_HALT && run)) pm_req = 1'b1;
  end

  // ONE special-register read, for source A in S_DEC and source B in S_XA.
  // PR is read at S_DEC's prp for both (MAME reads every transfer source
  // before the ALU's PR operand steps it).
  logic        spc_m;
  logic [5:0]  spc_c;
  logic [31:0] spc_now, pr_dec;
  assign spc_m   = (s == S_XA);
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

  // ---------------------------------------------------------------- word end
  logic dec_stall, wx_ext_start, eow, acc;
  logic [63:0] acc_word;
  logic alu_arr, mul_arr;
  assign dec_stall    = (needs_fi && !fi_valid) || (needs_fo && fo_full);
  assign wx_ext_start = (dk[wm] == K_MEM && !dbus[wm] && !dmask[wm] && g_ea[13:10] != 4'd0) ||
                        (dk[wm] == K_EXT);
  assign alu_arr = add_v | cv_v | div_v | (alu_go & (a_int | a_flog));
  assign mul_arr = fmul_v | imul_v;
  always_comb begin
    case (s)
      S_DEC:  eow = !dec_stall && !(alu_pr && mul_pr) && sk[0] == K_NONE && dk[0] == K_NONE &&
                    !is_ctl && !alu_en && !mul_en;
      S_XA:   eow = !ext_req && sk[1] == K_NONE && dk[0] == K_NONE && !is_ctl && !alu_pend && !mul_pend;
      S_WXA, S_WXB:
              // never a control word (it always has an ALU or multiply op,
              // so its delay slot / REP is in place before the next word is
              // taken), and never a write to ST (the take reads ST's RP)
              eow = (ext_req ? ext_ack : !wx_ext_start) && !(s == S_WXA && dk[1] != K_NONE) &&
                    !alu_pend && !mul_pend && !(dk[wm] == K_REG && wc == 6'h15);
      S_WA:   eow = !mul_pend;
      S_FIN:  eow = 1'b1;
      default: eow = 1'b0;
    endcase
  end
  assign acc      = run && ((s == S_FETCH && pm_valid) || (eow && (nx_v || pm_valid)));
  assign acc_word = nx_v ? nx_ir : pm_data;

  // THE INTERNAL WRITE PORTS ARE DRIVEN IN THE CLOCK THAT DECIDES THEM, so a
  // write lands at that clock's edge and the next word -- which may start in
  // the very next clock -- reads it. (Registered, they landed a clock late,
  // and the first prefetching version read stale registers: R920.) One data
  // path serves the RF, PR and both RAMs; only one of them writes a clock.
  logic [4:0] ao_idx, mo_idx;
  logic       alu_sup, mul_sup;
  assign ao_idx  = {ao[3], ao[4], ao[2:0]};
  assign mo_idx  = {mdst[3], mdst[4], mdst[2:0]};
  // a transfer to the same register came after the op in MAME
  assign alu_sup = (xw_rf_v[0] && xw_rf_i[0] == ao_idx) || (xw_rf_v[1] && xw_rf_i[1] == ao_idx);
  assign mul_sup = (xw_rf_v[0] && xw_rf_i[0] == mo_idx) || (xw_rf_v[1] && xw_rf_i[1] == mo_idx);

  logic [31:0] wd;
  always_comb begin
    rf_we = 1'b0; rf_wa = ao_idx;
    pr_we = 1'b0; pr_wa = pwp;
    ra_we = 1'b0; ra_wa = g_ea[9:0];
    rb_we = 1'b0; rb_wa = g_ea[9:0];
    wd    = wv;
    case (s)
      S_WXA, S_WXB: if (!ext_req) begin
        if (dk[wm] == K_REG && is_rf(wc)) begin rf_we = 1'b1; rf_wa = rf_idx(wc); end
        if (dk[wm] == K_REG && wc == 6'h30) pr_we = 1'b1;
        if (dk[wm] == K_MEM) begin
          if (dbus[wm])                               rb_we = 1'b1;
          else if (dmask[wm] || g_ea[13:10] == 4'd0)  ra_we = 1'b1;
        end
        if (s == S_WXA && is_ctl && cop == 5'h04) begin   // PUSH
          rb_we = 1'b1; rb_wa = sp - 10'd1;
        end
      end
      S_WA:  if (alu_wr && !alu_sup)  begin rf_we = 1'b1; rf_wa = ao_idx; wd = alu_r; end
      S_FIN: if (mul_pend && !mul_sup) begin rf_we = 1'b1; rf_wa = mo_idx; wd = mul_r; end
      default: ;
    endcase
  end
  assign rf_wd = wd;
  assign pr_wd = wd;
  assign ra_wd = wd;
  assign rb_wd = wd;

  integer k;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s <= S_HALT; ir <= 64'd0; ir_pc <= 12'd0; nx_ir <= 64'd0; nx_v <= 1'b0; pf_sent <= 1'b0; pc <= 12'd0; delay_pc <= 12'd0; delay_slot <= 1'b0;
      st <= 32'd0; rpc <= 16'd0; lpc <= 16'd0; eb <= 24'd0; eo <= 24'd0; sp <= 10'd0;
      modr <= 16'd0; pdr <= 32'd0; ddr <= 32'd0; prp <= 5'd0; pwp <= 5'd0; pcp <= 2'd0;
      for (k = 0; k < 4; k++) pcs[k] <= 12'd0;
      for (k = 0; k < 8; k++) ar[k] <= 14'd0;
      opa <= 32'd0; opb <= 32'd0; opm1 <= 32'd0; opm2 <= 32'd0;
      alu_go <= 1'b0; mul_go <= 1'b0; aop_q <= 5'd0; imm5_q <= 5'd0;
      alu_pend <= 1'b0; alu_done <= 1'b0; mul_pend <= 1'b0; mul_done <= 1'b0;
      alu_r <= 32'd0; mul_r <= 32'd0; alu_wr <= 1'b0;
      fa_an <= 1'b0; fa_az <= 1'b0; fa_zc <= 1'b0; fa_x <= 1'b0; fa_au <= 1'b0; fa_av <= 1'b0;
      fa_upd <= 1'b0; fa_zcu <= 1'b0;
      fm_n <= 1'b0; fm_z <= 1'b0; fm_d <= 1'b0; fm_v <= 1'b0; fm_u <= 1'b0;
      imul_p1 <= 32'd0; imul_r <= 32'd0; imul_v1 <= 1'b0; imul_v <= 1'b0;
      frsq_pend <= 1'b0;
      mv_val[0] <= 32'd0; mv_val[1] <= 32'd0; pr_dec <= 32'd0; ctl_ary <= 14'd0;
      xw_rf_v[0] <= 1'b0; xw_rf_v[1] <= 1'b0; xw_rf_i[0] <= 5'd0; xw_rf_i[1] <= 5'd0;
      xw_st <= 1'b0; ctl_take <= 1'b0; ctl_tgt <= 12'd0;
      fi_pop <= 1'b0; fi_clr <= 1'b0; fo_push <= 1'b0; fo_data <= 32'd0; fo_clr <= 1'b0;
      ext_req <= 1'b0; ext_we <= 1'b0; ext_addr <= 24'd0; ext_wdata <= 32'd0;
      dbg_retire <= 1'b0; dbg_bad <= 1'b0;
    end else begin
      alu_go <= 1'b0; mul_go <= 1'b0;
      fi_pop <= 1'b0; fi_clr <= 1'b0; fo_push <= 1'b0; fo_clr <= 1'b0;
      dbg_retire <= 1'b0;

      // ---------------------------------------------- unit completion
      imul_v1 <= mul_go && !isfmul;
      imul_p1 <= opm1 * opm2;
      imul_v  <= imul_v1;
      imul_r  <= imul_p1;

      if (alu_go && a_int) begin
        alu_done <= 1'b1; alu_r <= ires; alu_wr <= i_wr;
        fa_upd <= i_flags; fa_an <= i_an; fa_az <= i_az; fa_zcu <= i_zc_upd; fa_zc <= i_zc;
      end
      if (alu_go && a_flog) begin
        alu_done <= 1'b1; alu_r <= 32'd0; alu_wr <= 1'b1;
        fa_upd <= 1'b0; fa_zcu <= 1'b0; dbg_bad <= 1'b1;
      end
      if (add_v) begin
        alu_done <= 1'b1; alu_r <= add_d; alu_wr <= !aop_q[2];
        fa_upd <= 1'b1; fa_an <= f_neg(add_d); fa_az <= f_zero(add_d);
        fa_zcu <= aop_q[0] && !aop_q[2]; fa_zc <= add_zc;
      end
      if (cv_v) begin
        alu_done <= 1'b1; alu_r <= cv_r; alu_wr <= 1'b1;
        fa_upd <= 1'b1; fa_zcu <= 1'b0;
        fa_an <= cv_an; fa_az <= cv_az; fa_au <= cv_au; fa_av <= cv_av;
      end
      if (div_v) begin
        alu_done <= 1'b1; alu_r <= div_r; alu_wr <= 1'b1;
        fa_upd <= 1'b1; fa_zcu <= 1'b0; fa_an <= f_neg(div_r); fa_az <= f_zero(div_r);
        fa_x <= frsq_pend ? (f_zero(opa) || f_neg(opa)) : f_zero(opa);
        frsq_pend <= 1'b0;
      end
      if (sq_go) frsq_pend <= 1'b1;
      if (fmul_v) begin
        mul_done <= 1'b1; mul_r <= fmul_r;
        // MAME decode_mulop: MD = isnan, MV = isinf, MU = |res| < FLT_MIN --
        // so an exact zero sets MU too (R924), from the result, not the unit's flags
        fm_n <= f_neg(fmul_r); fm_z <= f_zero(fmul_r);
        fm_d <= (fmul_r[30:23] == 8'hff) && (fmul_r[22:0] != 23'd0);
        fm_v <= (fmul_r[30:23] == 8'hff) && (fmul_r[22:0] == 23'd0);
        fm_u <= (fmul_r[30:23] == 8'h00);
      end
      if (imul_v) begin
        mul_done <= 1'b1; mul_r <= imul_r;
        fm_n <= imul_r[31]; fm_z <= (imul_r == 32'd0); fm_d <= 1'b0; fm_v <= 1'b0; fm_u <= 1'b0;
      end

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
          if (dec_stall) begin
            s <= S_DEC;                               // stall: nothing done yet
          end else begin
            // ALU / multiplier operands
            opa  <= rf_rd[0];
            opb  <= !alu_src2 ? 32'd0 :
                    (ai2[4:3] == 2'd2) ? pr_rd :
                    (ai2[4:3] == 2'd3) ? cst(ai2[2:0], !aop[4]) : rf_rd[1];
            opm1 <= rf_rd[2];
            opm2 <= (m2s[4:3] == 2'd2) ? pr_rd :
                    (m2s[4:3] == 2'd3) ? cst(m2s[2:0], isfmul) : rf_rd[3];
            aop_q  <= aop;
            imm5_q <= ai2;
            if (alu_pr) prp <= prp_step(prp, ai2[2:0]);
            else if (mul_pr) prp <= prp_step(prp, m2s[2:0]);
            alu_pend <= alu_en;
            mul_pend <= mul_en;
            if (!(alu_pr && mul_pr)) begin
              alu_go <= alu_en;
              mul_go <= mul_en;
            end
            // source A: special registers now (MAME reads them before the ALU)
            pr_dec <= pr_rd;
            if (sk[0] == K_REG && !is_rf(sc[0])) begin
              mv_val[0] <= spc_now;
              if (sc[0] == 6'h31) fi_pop <= 1'b1;
            end
            if (sk[0] == K_IMM) mv_val[0] <= imm;
            // source A's address, and its AR update
            if (sk[0] == K_MEM && !is_ctl) begin
              if (g_we) ar[g_sely ? g_ry : g_rx] <= g_arw;
            end
            if (sk[0] == K_EXT) begin
              ext_req <= 1'b1; ext_we <= 1'b0; ext_addr <= eb + eo;
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
            if (alu_pr && mul_pr)                     s <= S_PR2;
            else if (sk[0] != K_NONE)                 s <= S_XA;
            else if (dk[0] != K_NONE || is_ctl)       s <= S_WXA;
            else                                      s <= S_WAIT;
          end
        end

        S_PR2: begin
          opm2 <= pr_rd;
          prp  <= prp_step(prp, m2s[2:0]);
          alu_go <= alu_en;
          mul_go <= mul_en;
          if (sk[0] != K_NONE)                        s <= S_XA;
          else if (dk[0] != K_NONE || is_ctl)         s <= S_WXA;
          else                                        s <= S_WAIT;
        end

        // ------------------------------------------------------------ sources
        S_XA: begin
          if (ext_req) begin
            if (ext_ack) begin ext_req <= 1'b0; mv_val[0] <= ext_rdata; end
          end else begin
            if (sk[0] == K_REG && is_rf(sc[0])) mv_val[0] <= rf_rd[0];
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
          if (sk[1] == K_REG && is_rf(sc[1])) mv_val[1] <= rf_rd[1];
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
          end else begin
            case (dk[wm])
              K_REG: begin
                if (is_rf(wc)) begin
                  xw_rf_v[wm] <= 1'b1; xw_rf_i[wm] <= rf_idx(wc);
                end else begin
                  case (wc)
                    6'h10: eb <= wv[23:0];
                    6'h11: eb <= {wv[9:0], eb[13:0]};
                    6'h12: eb <= {wv[9:0], 14'd0};   // MAME: (eb & 0xffc000) | (wv << 14)
                    6'h13: eo <= wv[23:0];
                    6'h14: sp <= wv[9:0];
                    6'h15: begin st <= wv; xw_st <= 1'b1; end
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

        // ------------------------------------------------------------ results
        S_WAIT: begin
          if ((!alu_pend || alu_done || alu_arr) && (!mul_pend || mul_done || mul_arr))
            s <= alu_pend ? S_WA : S_FIN;
        end

        S_WA: begin
          // the register write is in the write-port block; a transfer to ST
          // came after the op's flags in MAME
          if (!xw_st) begin
            if (fa_upd && aop_q != 5'h0f) begin st[F_AN] <= fa_an; st[F_AZ] <= fa_az; end
            if (aop_q == 5'h0f) begin                    // CFIB: AZ, and AU / AV only set
              st[F_AZ] <= fa_az; if (fa_au) st[F_AU] <= 1'b1; if (fa_av) st[F_AV] <= 1'b1;
            end
            if (fa_zcu) st[F_ZC] <= fa_zc;
            if (aop_q == 5'h0a) st[F_ZD] <= fa_x;
            if (aop_q == 5'h0b) st[F_NR] <= fa_x;
          end
          s <= S_FIN;
        end

        S_FIN: begin
          if (mul_pend) begin
            if (!xw_st) begin                            // FMUL: MV / MU only set
              st[F_MN] <= fm_n; st[F_MZ] <= fm_z; if (isfmul) st[F_MD] <= fm_d;
              if (fm_v) st[F_MV] <= 1'b1; if (fm_u) st[F_MU] <= 1'b1;
            end
          end
          s <= run ? S_FETCH : S_HALT;
        end

        default: s <= S_HALT;
      endcase

      // ------------------------------------------------ the next word
      if (pm_valid && s != S_HALT && !acc) begin nx_ir <= pm_data; nx_v <= 1'b1; end
      if (eow && !acc) s <= run ? S_FETCH : S_HALT;
      if (acc) begin
        // MAME execute_run: the PC steps (or the delay slot / repeat
        // applies) as the word is taken, before it executes
        ir <= acc_word; ir_pc <= pc;
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
        alu_pend <= 1'b0; alu_done <= 1'b0; mul_pend <= 1'b0; mul_done <= 1'b0;
        xw_rf_v[0] <= 1'b0; xw_rf_v[1] <= 1'b0; xw_st <= 1'b0; ctl_take <= 1'b0;
        s <= S_DEC;
      end
    end
  end

  assign dbg_pc  = pc;
  assign dbg_pdr = pdr;

endmodule
