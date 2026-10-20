// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// R891: m2_memtest on port 1 of m2_sdram, against sdram_module -- the board
// memory test run where its answer is known. One clock (m2_sdram_cdc keeps the
// same port contract across clk_sys / clk_mem, R561). The controller's DUAL /
// MASK_ON_A and the module's CHIPS / DQM wiring are parameters, so a module the
// controller does not match can be put under the test and the test's report
// read for what the board would say (tb_m2_memtest.cpp).

`timescale 1ns/1ps

module m2_memtest_harness #(
  parameter bit          DUAL      = 1'b1,
  parameter bit          MASK_ON_A = 1'b1,
  parameter int unsigned CHIPS     = 2,
  parameter bit          DQM_A     = 1'b1,
  parameter int unsigned T_REFI    = 770,
  parameter int unsigned MT_AW     = 26,     // the test's address width (Model2.sv: SDR_AW)
  parameter int unsigned W1 = 3, W2 = 4, W3 = 5
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        tick,
  input  logic        stop,
  input  logic [4:0]  sel,
  output logic [31:0] r_a,
  output logic [31:0] r_d,
  output logic [7:0]  passes,
  output logic        done0,
  output logic        own,
  output int unsigned violations,
  output logic [15:0] v_flags,
  output int unsigned decayed_rows
);
  localparam int unsigned AW = (DUAL ? 1 : 0) + 2 + 13 + 10;

  logic        ready;
  logic        mt_req, mt_we;
  logic [MT_AW:1] mt_addr;
  logic [15:0] mt_din;
  logic [1:0]  mt_be;
  logic [1:0]  p_req, p_we, p_ack, p_lo;
  logic [1:0][AW:1]  p_addr;
  logic [1:0][15:0]  p_din;
  logic [1:0][1:0]   p_be;
  logic [1:0][63:0]  p_dout;
  logic [1:0]  dbg_req, dbg_grant;

  // a test wider than the controller is a controller that drops the top bit
  assign p_req  = {mt_req, 1'b0};
  assign p_we   = {mt_we, 1'b0};
  assign p_addr = {AW'(mt_addr), {AW{1'b0}}};
  assign p_din  = {mt_din, 16'd0};
  assign p_be   = {mt_be, 2'b11};

  logic        cke, cs_n, ras_n, cas_n, we_n, dq_oe_c, dq_oe_m, wr_ack;
  logic [1:0]  ba, dqm, dqm_c;
  logic [12:0] a;
  logic [15:0] dq_c2m, dq_m2c;
  assign dqm = MASK_ON_A ? a[12:11] : dqm_c;   // the DQM pins as Model2.sv drives them

  m2_sdram #(.COL_BITS(10), .NP(2), .T_REFI(T_REFI), .INIT_NOP(600), .ACK_HOLD(2),
             .DUAL(DUAL), .MASK_ON_A(MASK_ON_A)) dut (
    .clk(clk), .rst_n(rst_n), .ready(ready), .rd_lat_sel(3'd3),
    .sd_cke(cke), .sd_cs_n(cs_n), .sd_ras_n(ras_n), .sd_cas_n(cas_n), .sd_we_n(we_n),
    .sd_ba(ba), .sd_a(a), .sd_dqm(dqm_c), .sd_dq_o(dq_c2m), .sd_dq_oe(dq_oe_c), .sd_dq_i(dq_m2c),
    .wr_req(1'b0), .wr_addr('0), .wr_din('0), .wr_be(2'b11), .wr_ack(wr_ack),
    .p_req(p_req), .p_we(p_we), .p_addr(p_addr), .p_din(p_din), .p_be(p_be),
    .p_dout(p_dout), .p_ack(p_ack), .p_long(2'b00), .p_lo(p_lo),
    .dbg_req(dbg_req), .dbg_grant(dbg_grant)
  );

  int unsigned reads_served, writes_served;
  sdram_module #(.CHIPS(CHIPS), .COL_BITS(10), .DQM_FROM_A(DQM_A), .T_REFI(781), .REFI_SLACK(9),
                 .RD_DQM(1'b1), .CHECK_RET(1'b1), .CHECK_INIT(1'b1), .DEFAULT_HASH(1'b1)) device (
    .clk(clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
    .ba(ba), .a(a), .dqm(dqm), .dq_i(dq_c2m), .dq_oe_i(dq_oe_c), .dq_o(dq_m2c), .dq_oe_o(dq_oe_m),
    .violations(violations), .v_flags(v_flags), .reads_served(reads_served),
    .writes_served(writes_served), .decayed_rows(decayed_rows)
  );

  m2_memtest #(.AW(MT_AW), .W1(W1), .W2(W2), .W3(W3)) u_mt (
    .clk(clk), .rst_n(rst_n), .go(ready), .stop(stop), .tick(tick),
    .own(own), .req(mt_req), .we(mt_we), .addr(mt_addr), .din(mt_din), .be(mt_be),
    .ack(p_ack[1]), .dout(p_dout[1]),
    .done0(done0), .sel(sel), .sdram_sz(16'h8003),
    .r_a(r_a), .r_d(r_d), .passes(passes)
  );
endmodule
