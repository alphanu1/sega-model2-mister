// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// The framebuffer's write path as it is built: m2_fb_write -> m2_ddr3_arb
// (port b) -> m2_ddr3 -> DDRAM. Port a is a stand-in reader the bench drives.
//
// Every earlier bench stopped at the arbiter's m_* side with a C model that
// answers a beat in the cycle it takes it; m2_ddr3 answers a cycle later, and
// that cycle is where a request can be taken twice. Only the real chain shows it.

`timescale 1ns/1ps

module m2_fbw_chain (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        fb_sel,
  input  logic        clear_req,
  output logic        clear_busy,
  input  logic        in_valid,
  output logic        in_ready,
  input  logic signed [15:0] in_y, in_x0, in_x1,
  input  logic [23:0] in_col,
  input  logic        in_moire,
  output logic        w_empty,

  input  logic        b_hold,

  input  logic        rd_req,
  input  logic [24:0] rd_addr,
  input  logic [7:0]  rd_blen,
  output logic        rd_rvalid,
  output logic        rd_ack,

  output logic        w_req,
  output logic [31:0] dbg_pixels,

  input  logic        DDRAM_BUSY,
  output logic [7:0]  DDRAM_BURSTCNT,
  output logic [28:0] DDRAM_ADDR,
  output logic [63:0] DDRAM_DIN,
  output logic [7:0]  DDRAM_BE,
  output logic        DDRAM_WE,
  output logic        DDRAM_RD,
  input  logic [63:0] DDRAM_DOUT,
  input  logic        DDRAM_DOUT_READY
);

  logic        w_we, w_wnext, w_wacc, w_ack;
  logic [24:0] w_addr;
  logic [7:0]  w_blen, w_be;
  logic [63:0] w_din;

  m2_fb_write #(.SCR_W(496), .SCR_H(384), .STRIDE(512)) u_fbw (
    .clk(clk), .rst_n(rst_n), .fb_sel(fb_sel),
    .clear_req(clear_req), .clear_busy(clear_busy),
    .in_valid(in_valid), .in_ready(in_ready),
    .in_y(in_y), .in_x0(in_x0), .in_x1(in_x1), .in_col(in_col),
    .in_painted(1'b1), .in_moire(in_moire),
    .m_req(w_req), .m_we(w_we), .m_addr(w_addr), .m_blen(w_blen),
    .m_din(w_din), .m_be(w_be), .m_wnext(w_wnext), .m_wacc(w_wacc), .m_ack(w_ack),
    .empty(w_empty),
    .dbg_pixels(dbg_pixels), .dbg_clears(), .dbg_st()
  );

  logic        m_req, m_we, m_wnext, m_wacc, m_rvalid, m_ack;
  logic [24:0] m_addr;
  logic [7:0]  m_blen, m_be;
  logic [63:0] m_din, m_dout;

  m2_ddr3_arb u_arb (
    .clk(clk), .rst_n(rst_n),
    .a_req(rd_req), .a_we(1'b0), .a_addr(rd_addr), .a_blen(rd_blen),
    .a_din(64'd0), .a_be(8'hFF),
    .a_wnext(), .a_wacc(), .a_rvalid(rd_rvalid), .a_ack(rd_ack),
    .b_req(w_req), .b_hold(b_hold), .b_we(w_we), .b_addr(w_addr), .b_blen(w_blen),
    .b_din(w_din), .b_be(w_be),
    .b_wnext(w_wnext), .b_wacc(w_wacc), .b_rvalid(), .b_ack(w_ack),
    .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_blen(m_blen),
    .m_din(m_din), .m_be(m_be),
    .m_wnext(m_wnext), .m_wacc(m_wacc), .m_rvalid(m_rvalid), .m_ack(m_ack), .m_dout(m_dout),
    .dout(), .dbg_a_waits(), .dbg_b_waits(), .dbg_busy(), .dbg_owner()
  );

  m2_ddr3 u_ddr3 (
    .clk(clk), .rst_n(rst_n), .base(29'h0600_0000),
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
