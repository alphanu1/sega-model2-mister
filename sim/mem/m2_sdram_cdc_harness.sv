// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// m2_sdram behind m2_sdram_cdc, with the two clocks INDEPENDENT (R561).
//
// m2_sdram_x2_harness derives the slow clock from the fast one by a divide by
// two, so it can only ever show the 2:1 case. Here the testbench drives both
// clocks from absolute time at whatever periods and phase it is given --
// 10 ns against 16.667 is the 100/60 the clock plan is for -- so every
// alignment the board can produce is reached. Port 4 is FAST: its requester
// runs on the controller's clock, as the texel and character caches do.

`timescale 1ns/1ps

module m2_sdram_cdc_harness #(
  parameter logic [2:0]  RD_LAT_SEL = 3'd3,   // read-capture selector, see m2_sdram; the board calibrates it
  parameter int unsigned COL_BITS = 10
) (
  input  logic        clk,          // FAST, the controller's
  input  logic        rst_n,
  input  logic        clk_slow,     // the requesters', any ratio
  output logic        ready,

  input  logic        wr_req,
  input  logic [COL_BITS+15:1] wr_addr,
  input  logic [15:0] wr_din,
  input  logic [1:0]  wr_be,
  output logic        wr_ack,

  input  logic        p0_req, p1_req, p2_req, p3_req, p4_req,
  input  logic        p0_we,
  input  logic [COL_BITS+15:1] p0_addr, p1_addr, p2_addr, p3_addr, p4_addr,
  input  logic [15:0] p0_din,
  input  logic [1:0]  p0_be,
  output logic [63:0] p0_dout, p1_dout, p2_dout, p3_dout, p4_dout,
  output logic        p0_ack, p1_ack, p2_ack, p3_ack, p4_ack,

  output int unsigned violations,
  output logic [15:0] v_flags,
  output int unsigned reads_served,
  output int unsigned writes_served
);

  // The same numbers the single-clock harness uses, and passed to BOTH sides
  // for the same reason: a controller built for one clock and checked against a
  // model built for another agrees with itself and with nothing real.
  localparam int unsigned T_RCD = 2;
  localparam int unsigned T_RP  = 2;
  localparam int unsigned T_RC  = 7;
  localparam int unsigned T_RAS = 5;
  localparam int unsigned T_WR  = 2;
  localparam int unsigned CL    = 2;
  localparam int unsigned T_REFI_C = 700;
  localparam int unsigned INIT_NOP = 600;

  localparam int unsigned AW = COL_BITS + 15;
  localparam int unsigned NP = 5;


  // ---- slow side, packed the way the top level packs it
  logic [NP-1:0]        s_req, s_ack, s_we;
  logic [NP-1:0][AW:1]  s_addr;
  logic [NP-1:0][15:0]  s_din;
  logic [NP-1:0][1:0]   s_be;
  logic [NP-1:0][63:0]  s_dout;

  always_comb begin
    s_req  = {p4_req, p3_req, p2_req, p1_req, p0_req};
    s_addr = {p4_addr, p3_addr, p2_addr, p1_addr, p0_addr};
    s_we   = {4'b0, p0_we};
    s_din  = {16'd0, 16'd0, 16'd0, 16'd0, p0_din};
    s_be   = {2'b11, 2'b11, 2'b11, 2'b11, p0_be};
  end
  assign {p4_ack, p3_ack, p2_ack, p1_ack, p0_ack} = s_ack;
  assign p0_dout = s_dout[0];  assign p1_dout = s_dout[1];
  assign p2_dout = s_dout[2];  assign p3_dout = s_dout[3];
  assign p4_dout = s_dout[4];

  // ---- fast side
  logic [NP-1:0]        f_req, f_ack, f_we;
  logic [NP-1:0][AW:1]  f_addr;
  logic [NP-1:0][15:0]  f_din;
  logic [NP-1:0][1:0]   f_be;
  logic [NP-1:0][63:0]  f_dout;
  logic                 f_wr_req, f_wr_ack;
  logic [AW:1]          f_wr_addr;
  logic [15:0]          f_wr_din;
  logic [1:0]           f_wr_be;

  m2_sdram_cdc #(.NP(NP), .AW(AW), .FAST(5'b10000)) u_cdc (
    .clk_slow(clk_slow), .s_rst_n(rst_n), .clk_fast(clk), .f_rst_n(rst_n),
    .s_req(s_req), .s_addr(s_addr), .s_ack(s_ack), .s_dout(s_dout),
    .s_we(s_we), .s_din(s_din), .s_be(s_be),
    .s_wr_req(wr_req), .s_wr_addr(wr_addr), .s_wr_din(wr_din),
    .s_wr_be(wr_be), .s_wr_ack(wr_ack),
    .f_req(f_req), .f_addr(f_addr), .f_ack(f_ack), .f_dout(f_dout),
    .f_we(f_we), .f_din(f_din), .f_be(f_be),
    .f_wr_req(f_wr_req), .f_wr_addr(f_wr_addr), .f_wr_din(f_wr_din),
    .f_wr_be(f_wr_be), .f_wr_ack(f_wr_ack)
  );

  logic cke, cs_n, ras_n, cas_n, we_n;
  logic [1:0]  ba;
  logic [12:0] a;
  logic [1:0]  dqm;
  logic [15:0] dq_o, dq_i;
  logic        dq_oe;

  m2_sdram #(
    .COL_BITS(COL_BITS), .NP(NP), .T_RCD(T_RCD), .T_RP(T_RP), .T_RC(T_RC),
    .T_RAS(T_RAS), .T_WR(T_WR), .CL(CL), .T_REFI(T_REFI_C),
    .INIT_NOP(INIT_NOP), .ACK_HOLD(2)
  ) u_sdram (
    .clk(clk), .rst_n(rst_n), .ready(ready),
    // CL+3, which is what the device MODEL needs -- selector 3 after the range
    // moved earlier for the board. Not the board's value.
    .rd_lat_sel(RD_LAT_SEL),
    .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n),
    .sd_we_n(we_n), .sd_ba(ba), .sd_a(a), .sd_dqm(dqm),
    .sd_dq_o(dq_o), .sd_dq_oe(dq_oe), .sd_dq_i(dq_i),
    .wr_req(f_wr_req), .wr_addr(f_wr_addr), .wr_din(f_wr_din),
    .wr_be(f_wr_be), .wr_ack(f_wr_ack),
    .p_req(f_req), .p_we(f_we), .p_addr(f_addr), .p_din(f_din), .p_be(f_be),
    .p_dout(f_dout), .p_ack(f_ack), .p_long('0), .p_lo(),   // R787
    .dbg_req(), .dbg_grant()
  );

  logic dq_oe_m;
  sdram_model #(
    .COL_BITS(COL_BITS), .T_RCD(T_RCD), .T_RP(T_RP), .T_RC(T_RC),
    .T_RAS(T_RAS), .T_WR(T_WR), .CL(CL), .T_REFI(781), .REFI_SLACK(9)
  ) u_dev (
    .clk(clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n),
    .we_n(we_n), .ba(ba), .a(a), .dqm(dqm),
    .dq_i(dq_o), .dq_oe_i(dq_oe),
    .dq_o(dq_i), .dq_oe_o(dq_oe_m),
    .violations(violations), .v_flags(v_flags),
    .reads_served(reads_served), .writes_served(writes_served)
  );

endmodule
