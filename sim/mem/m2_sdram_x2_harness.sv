// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// The controller at 96 MHz behind m2_sdram_x2, with requesters at 48.
//
// `clk` here is the FAST clock and `clk_slow` is driven out of it by a divide
// by two, so the testbench can act only on slow edges — which is the whole
// point. The adapter's two hazards are both about pulse widths measured in the
// other domain's cycles, and a testbench that drove the slow side on fast edges
// would be a requester the real core does not have.
//
// The read-data bypass is what this exists to catch. `dout_r` does not load
// until the fast edge AFTER the acknowledge, the acknowledge is two fast cycles
// wide, and the slow edge can land on either of them: in the Kaneko16 core the
// unbypassed version failed almost exactly half of all reads, because the two
// alignments are equally likely and one of them returns the previous
// transaction's data. Half-failing is not a subtle signature, but it only
// appears at 2:1 — the controller's own suite passes either way, because there
// is no slow domain in it to be misaligned with.

`timescale 1ns/1ps

module m2_sdram_x2_harness #(
  parameter int unsigned COL_BITS = 10
) (
  input  logic        clk,          // FAST, 96 MHz
  input  logic        rst_n,
  output logic        clk_slow,     // 48 MHz, exact /2
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

  logic div;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) div <= 1'b0;
    else        div <= ~div;
  end
  assign clk_slow = div;

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

  m2_sdram_x2 #(.NP(NP), .AW(AW)) u_x2 (
    .clk_fast(clk),
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
    .rd_lat_sel(2'd3),
    .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n),
    .sd_we_n(we_n), .sd_ba(ba), .sd_a(a), .sd_dqm(dqm),
    .sd_dq_o(dq_o), .sd_dq_oe(dq_oe), .sd_dq_i(dq_i),
    .wr_req(f_wr_req), .wr_addr(f_wr_addr), .wr_din(f_wr_din),
    .wr_be(f_wr_be), .wr_ack(f_wr_ack),
    .p_req(f_req), .p_we(f_we), .p_addr(f_addr), .p_din(f_din), .p_be(f_be),
    .p_dout(f_dout), .p_ack(f_ack),
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
