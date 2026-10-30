// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// R881: THE 2A BUILD'S SDRAM PATH WITH THE SOUND BOARD'S REAL REQUESTERS. The
// thirteen ports as Model2.sv wires them for Model 2A -- m2_sdram_cdc (FAST
// 2, 3, 10, 11, 12) in front of m2_sdram (the 2A priority class, PRI_TOP 3,
// optional AGE, eight-word reads on 2, 10, 11, 12, COL_BITS 10) and the device
// model -- with clk_sys and clk_mem driven independently by the C++, so their
// phase is whatever the bench makes it. Requesters:
//
//   5, 6, 7   the REAL m2_2a_sound (its bus FSM, posted writes, read-merge-
//             write, the boot check, the clear) with tb_snd_stubs.sv's 68000
//             and SCSP clients (the real m2_scsp_cache on 6 and 7)
//   1-4, 8-12 tb_cl_req: a single-outstanding requester per port, its choices
//             from the C++ (DPI tb_req_step), on its own side of the crossing
//   13        the loader / geometry write port (s_wr_*), the same way
//
// and a monitor on every port, on that port's clock, reporting each sample of
// the requester-side signals (DPI tb_mon) -- what the requester asked for and
// what it read on the clock it took the acknowledge -- plus each p_lo half of
// an eight-word read on the fast side (tb_mon_lo). The C++ checks every word.

`timescale 1ns/1ps

module tb_cl_req #(
  parameter int unsigned PORT = 0,
  parameter int unsigned AW   = 25
) (
  input  logic        clk,
  input  logic        rst_n,
  output logic        req,
  output logic [AW:1] addr,
  output logic        we,
  output logic [15:0] din,
  input  logic        ack
);
  import "DPI-C" function void tb_req_step(input int port, input bit ack, output bit req, output int addr,
                                           output bit we, output int din);
  always_ff @(posedge clk) begin
    if (!rst_n) begin req <= 1'b0; addr <= '0; we <= 1'b0; din <= '0; end
    else begin
      bit r, w; int a, d;
      tb_req_step(int'(PORT), ack, r, a, w, d);
      req <= r; addr <= AW'(a); we <= w; din <= d[15:0];
    end
  end
endmodule

module tb_cl_mon #(
  parameter int unsigned PORT = 0,
  parameter int unsigned AW   = 25
) (
  input  logic        clk,
  input  logic        req,
  input  logic        ack,
  input  logic        we,
  input  logic [AW:1] addr,
  input  logic [15:0] din,
  input  logic [63:0] dout
);
  import "DPI-C" function void tb_mon(input int port, input bit req, input bit ack, input bit we,
                                      input int addr, input int din, input longint dout);
  always_ff @(posedge clk) tb_mon(int'(PORT), req, ack, we, int'(addr), int'(din), longint'(dout));
endmodule

module m2_sdram_cdc_load_harness #(
  parameter int unsigned COL_BITS = 10,
  parameter logic [12:0] AGE      = '0,
  parameter bit          POST_WR  = 1'b1
) (
  input  logic        clk_sys,
  input  logic        clk_mem,
  input  logic        rst_n,
  input  logic        snd_rst_n,
  output logic        ready,
  output logic [15:0] selftest,
  output logic        snd_go,
  output int unsigned violations,
  output logic [15:0] v_flags,
  output int unsigned reads_served,
  output int unsigned writes_served
);
  localparam int unsigned AW = 2 + 13 + COL_BITS;
  localparam int unsigned NP = 13;
  localparam logic [NP-1:0] FAST = 13'b1_1100_0000_1100;   // Model2.sv u_sdram_x2
  localparam logic [NP-1:0] LONG = 13'b1_1100_0000_0100;   // 10, 11, 12; 2 (the texel cache owns it)
  // Model2.sv's 2A map (word addresses)
  localparam logic [AW:1] RAM_BASE = AW'(32'h12C0000);
  localparam logic [AW:1] ROM_BASE = AW'(32'h1260000);
  localparam logic [AW:1] SMP_BASE = AW'(32'h1A00000);

  logic [NP-1:0]          s_req, s_ack, s_we;
  logic [NP-1:0][AW:1]    s_addr;
  logic [NP-1:0][63:0]    s_dout;
  logic [NP-1:0][15:0]    s_din;
  logic [NP-1:0][1:0]     s_be;
  logic                   s_wr_req, s_wr_ack;
  logic [AW:1]            s_wr_addr;
  logic [15:0]            s_wr_din;
  logic [NP-1:0]          f_req, f_ack, f_we, f_lo;
  logic [NP-1:0][AW:1]    f_addr;
  logic [NP-1:0][63:0]    f_dout;
  logic [NP-1:0][15:0]    f_din;
  logic [NP-1:0][1:0]     f_be;
  logic                   f_wr_req, f_wr_ack;
  logic [AW:1]            f_wr_addr;
  logic [15:0]            f_wr_din;
  logic [1:0]             f_wr_be;

  m2_sdram_cdc #(.NP(NP), .AW(AW), .FAST(FAST)) u_cdc (
    .clk_slow(clk_sys), .s_rst_n(rst_n), .clk_fast(clk_mem), .f_rst_n(rst_n),
    .s_req(s_req), .s_addr(s_addr), .s_ack(s_ack), .s_dout(s_dout),
    .s_we(s_we), .s_din(s_din), .s_be(s_be),
    .s_wr_req(s_wr_req), .s_wr_addr(s_wr_addr), .s_wr_din(s_wr_din), .s_wr_be(2'b11), .s_wr_ack(s_wr_ack),
    .f_req(f_req), .f_addr(f_addr), .f_ack(f_ack), .f_dout(f_dout),
    .f_we(f_we), .f_din(f_din), .f_be(f_be),
    .f_wr_req(f_wr_req), .f_wr_addr(f_wr_addr), .f_wr_din(f_wr_din), .f_wr_be(f_wr_be), .f_wr_ack(f_wr_ack)
  );

  logic        cke, cs_n, ras_n, cas_n, we_n;
  logic [1:0]  ba, dqm;
  logic [12:0] a;
  logic [15:0] dq_c2m, dq_m2c;
  logic        dq_oe_c, dq_oe_m;
  logic [NP-1:0] dbg_req, dbg_grant;

  m2_sdram #(.COL_BITS(COL_BITS), .NP(NP), .T_REFI(781), .INIT_NOP(600),
             .PRI(13'b1_1111_0001_1110), .PRI_CAP(2), .PRI_TOP(13'b0_0000_0000_1000),
             .AGE(AGE), .AGE_T(48)) u_sdram (
    .clk(clk_mem), .rst_n(rst_n), .ready(ready),
    .rd_lat_sel(3'd3),                       // CL+3: the device model's phase (the board's is CL+2)
    .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n), .sd_we_n(we_n),
    .sd_ba(ba), .sd_a(a), .sd_dqm(dqm), .sd_dq_o(dq_c2m), .sd_dq_oe(dq_oe_c), .sd_dq_i(dq_m2c),
    .wr_req(f_wr_req), .wr_addr(f_wr_addr), .wr_din(f_wr_din), .wr_be(f_wr_be), .wr_ack(f_wr_ack),
    .p_req(f_req), .p_we(f_we), .p_addr(f_addr), .p_din(f_din), .p_be(f_be),
    .p_dout(f_dout), .p_ack(f_ack), .p_long(LONG), .p_lo(f_lo),
    .dbg_req(dbg_req), .dbg_grant(dbg_grant)
  );

  sdram_model #(.COL_BITS(COL_BITS), .T_REFI(781), .REFI_SLACK(9), .DEFAULT_HASH(1'b1)) device (
    .clk(clk_mem), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n),
    .we_n(we_n), .ba(ba), .a(a), .dqm(dqm),
    .dq_i(dq_c2m), .dq_oe_i(dq_oe_c), .dq_o(dq_m2c), .dq_oe_o(dq_oe_m),
    .violations(violations), .v_flags(v_flags),
    .reads_served(reads_served), .writes_served(writes_served)
  );

  // ---------------------------------------------------- the sound board (real)
  m2_2a_sound #(.AW(AW), .RAM_BASE(RAM_BASE), .ROM_BASE(ROM_BASE), .SMP_BASE(SMP_BASE), .ROM_SWAP(1'b1),
                .PHI_NUM(225792), .PHI_DEN(800000), .T44_NUM(441), .T44_DEN(800000),
                .POST_WR(POST_WR)) u_snd (
    .clk(clk_sys), .rst_n(snd_rst_n),
    .rx_data(8'd0), .rx_valid(1'b0), .rx_ack(), .tx_data(), .tx_valid(), .tx_ack(1'b1),
    .a_req(s_req[5]), .a_addr(s_addr[5]), .a_we(s_we[5]), .a_din(s_din[5]), .a_be(s_be[5]),
    .a_ack(s_ack[5]), .a_dout(s_dout[5]),
    .b_req(s_req[6]), .b_addr(s_addr[6]), .b_ack(s_ack[6]), .b_dout(s_dout[6]),
    .c_req(s_req[7]), .c_addr(s_addr[7]), .c_we(s_we[7]), .c_din(s_din[7]),
    .c_ack(s_ack[7]), .c_dout(s_dout[7]),
    .snd_boost(2'd0), .snd_tarc(1'b0), .snd_l(), .snd_r(),
    .dbg_addr(), .dbg_cycles(), .dbg_samples(), .dbg_under(), .dbg_selftest(selftest),
    .dbg_mvol(), .dbg_w400(), .dbg_w418(), .dbg_scsp_we(), .dbg_scsp_a(), .dbg_scsp_d(), .dbg_scsp_be(),
    .dbg_sums()                                       // (R882's port; this harness predates it)
  );
  assign s_we[6] = 1'b0; assign s_din[6] = '0;
  assign s_be[6] = 2'b11; assign s_be[7] = 2'b11;   // Model2.sv: p_be[7] = 2'b11
  assign snd_go = u_snd.cpu_go;

  // ------------------------------------------------------ the other requesters
  genvar g;
  generate
    for (g = 0; g < NP; g = g + 1) begin : g_port
      if (g < 5 || g > 7) begin : g_req
        tb_cl_req #(.PORT(g), .AW(AW)) u_req (
          .clk(FAST[g] ? clk_mem : clk_sys), .rst_n(rst_n),
          .req(s_req[g]), .addr(s_addr[g]), .we(s_we[g]), .din(s_din[g]), .ack(s_ack[g])
        );
        assign s_be[g] = 2'b11;
      end
      tb_cl_mon #(.PORT(g), .AW(AW)) u_mon (
        .clk(FAST[g] ? clk_mem : clk_sys),
        .req(s_req[g]), .ack(s_ack[g]), .we(s_we[g]), .addr(s_addr[g]), .din(s_din[g]), .dout(s_dout[g])
      );
    end
  endgenerate
  // the write port, a slow-side requester (Model2.sv: m2_wr_arb on clk_sys)
  logic w13_we;
  tb_cl_req #(.PORT(13), .AW(AW)) u_wreq (
    .clk(clk_sys), .rst_n(rst_n), .req(s_wr_req), .addr(s_wr_addr), .we(w13_we), .din(s_wr_din), .ack(s_wr_ack)
  );
  tb_cl_mon #(.PORT(13), .AW(AW)) u_wmon (
    .clk(clk_sys), .req(s_wr_req), .ack(s_wr_ack), .we(1'b1), .addr(s_wr_addr), .din(s_wr_din), .dout(64'd0)
  );
  // an eight-word read's first half, on the fast side as m2_sdram gives it
  import "DPI-C" function void tb_mon_lo(input int port, input longint dout);
  always_ff @(posedge clk_mem)
    for (int p = 0; p < NP; p++) if (f_lo[p]) tb_mon_lo(p, longint'(f_dout[p]));

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, dbg_req, dbg_grant, dq_oe_m, w13_we};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
