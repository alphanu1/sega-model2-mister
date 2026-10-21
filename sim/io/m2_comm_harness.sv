// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// THE COMM BLOCK AS Model2.sv WIRES IT (study R916): m2_comm on port b of an
// m2_ddr3_arb whose port a is a stand-in for m2_raster3d's framebuffer
// traffic (driven by the bench), into the real m2_ddr3 and out to the DDRAM
// pins, which the bench models -- BUSY, latency, bursts.

`timescale 1ns/1ps

module m2_comm_harness (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        game_rst_n,
  input  logic        fitted,

  input  logic        sel,
  input  logic        we,
  input  logic [15:0] addr,
  input  logic  [3:0] be,
  input  logic [31:0] wdata,
  output logic [31:0] rdata,
  output logic        stall,
  input  logic        tick,
  input  logic        frame,

  // port a: the framebuffer's stand-in
  input  logic        a_req,
  input  logic        a_we,
  input  logic [24:0] a_addr,
  input  logic  [7:0] a_blen,
  input  logic [63:0] a_din,
  output logic        a_wacc,
  output logic        a_rvalid,
  output logic        a_ack,

  output logic [63:0] dout,

  input  logic        DDRAM_BUSY,
  output logic  [7:0] DDRAM_BURSTCNT,
  output logic [28:0] DDRAM_ADDR,
  output logic [63:0] DDRAM_DIN,
  output logic  [7:0] DDRAM_BE,
  output logic        DDRAM_WE,
  output logic        DDRAM_RD,
  input  logic [63:0] DDRAM_DOUT,
  input  logic        DDRAM_DOUT_READY,

  output logic        dbg_cn,
  output logic        dbg_zfg
);

  wire        c_req, c_we, c_wacc, c_rvalid, c_ack, c_wnext, a_wnext;
  wire [24:0] c_addr;
  wire  [7:0] c_blen, c_be;
  wire [63:0] c_din;

  m2_comm u_comm (
    .clk(clk), .rst_n(rst_n), .game_rst_n(game_rst_n), .fitted(fitted),
    .sel(sel), .we(we), .addr(addr), .be(be), .wdata(wdata), .rdata(rdata), .stall(stall),
    .tick(tick), .frame(frame),
    .d_req(c_req), .d_we(c_we), .d_addr(c_addr), .d_blen(c_blen), .d_din(c_din), .d_be(c_be),
    .d_wacc(c_wacc), .d_rvalid(c_rvalid), .d_ack(c_ack), .d_dout(dout),
    .dbg_cn(dbg_cn), .dbg_zfg(dbg_zfg)
  );

  wire        m_req, m_we, m_wnext, m_wacc, m_rvalid, m_ack;
  wire [24:0] m_addr;
  wire  [7:0] m_blen, m_be;
  wire [63:0] m_din, m_dout;

  m2_ddr3_arb u_arb (
    .clk(clk), .rst_n(rst_n),
    .a_req(a_req), .a_we(a_we), .a_addr(a_addr), .a_blen(a_blen), .a_din(a_din), .a_be(8'hFF),
    .a_wnext(a_wnext), .a_wacc(a_wacc), .a_rvalid(a_rvalid), .a_ack(a_ack),
    .b_req(c_req), .b_hold(1'b0), .b_we(c_we), .b_addr(c_addr), .b_blen(c_blen), .b_din(c_din), .b_be(c_be),
    .b_wnext(c_wnext), .b_wacc(c_wacc), .b_rvalid(c_rvalid), .b_ack(c_ack),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_blen(m_blen), .m_din(m_din), .m_be(m_be),
    .m_wnext(m_wnext), .m_wacc(m_wacc), .m_rvalid(m_rvalid), .m_ack(m_ack), .m_dout(m_dout),
    .dout(dout),
    .dbg_a_waits(), .dbg_b_waits(), .dbg_busy(), .dbg_owner()
  );

  wire unused_ok = &{1'b0, a_wnext, c_wnext};

  m2_ddr3 u_ddr3 (
    .base(29'h0600_0000),
    .clk(clk), .rst_n(rst_n),
    .req(m_req), .we(m_we), .addr(m_addr), .blen(m_blen), .din(m_din), .be(m_be),
    .wnext(m_wnext), .wacc(m_wacc), .rvalid(m_rvalid), .ack(m_ack), .dout(m_dout),
    .DDRAM_CLK(), .DDRAM_BUSY(DDRAM_BUSY),
    .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
    .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE),
    .DDRAM_WE(DDRAM_WE), .DDRAM_RD(DDRAM_RD),
    .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
    .dbg_lat_last(), .dbg_lat_max(), .dbg_inflight_max(), .dbg_stuck_wr(), .dbg_acks()
  );

endmodule
