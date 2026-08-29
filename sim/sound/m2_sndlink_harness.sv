// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// Both i8251s and the wire between them, which is the whole main-board-to-
// sound-board path. The testbench plays the i960's part on side A and the
// sound board's 68000 on side B.

`timescale 1ns/1ps

module m2_sndlink_harness #(
  // Short, so a test does not spend 15,360 cycles per byte proving a point
  // about ordering. The pacing test overrides nothing -- it measures whatever
  // this is set to, so the property holds at any rate.
  parameter int unsigned BYTE_CYCLES = 64
) (
  input  logic       clk,
  input  logic       rst_n,

  // Side A: the i960's register interface.
  input  logic       a_sel,
  input  logic       a_we,
  input  logic       a_addr,
  input  logic [7:0] a_din,
  output logic [7:0] a_dout,
  output logic       a_irq,

  // Side B: the sound 68000's.
  input  logic       b_sel,
  input  logic       b_we,
  input  logic       b_addr,
  input  logic [7:0] b_din,
  output logic [7:0] b_dout,
  output logic       b_irq,

  output logic [31:0] dbg_a_bytes,
  output logic  [7:0] dbg_a_last
);

  logic [7:0] a_tx_d, a_rx_d, b_tx_d, b_rx_d;
  logic       a_tx_v, a_tx_a, a_rx_v, a_rx_a;
  logic       b_tx_v, b_tx_a, b_rx_v, b_rx_a;

  m2_i8251 u_a (
    .clk(clk), .rst_n(rst_n),
    .sel(a_sel), .we(a_we), .addr(a_addr), .din(a_din), .dout(a_dout),
    .tx_data(a_tx_d), .tx_valid(a_tx_v), .tx_ack(a_tx_a),
    .rx_data(a_rx_d), .rx_valid(a_rx_v), .rx_ack(a_rx_a),
    .irq(a_irq)
  );

  m2_i8251 u_b (
    .clk(clk), .rst_n(rst_n),
    .sel(b_sel), .we(b_we), .addr(b_addr), .din(b_din), .dout(b_dout),
    .tx_data(b_tx_d), .tx_valid(b_tx_v), .tx_ack(b_tx_a),
    .rx_data(b_rx_d), .rx_valid(b_rx_v), .rx_ack(b_rx_a),
    .irq(b_irq)
  );

  m2_sound_link #(.BYTE_CYCLES(BYTE_CYCLES)) u_link (
    .clk(clk), .rst_n(rst_n),
    .a_tx_data(a_tx_d), .a_tx_valid(a_tx_v), .a_tx_ack(a_tx_a),
    .a_rx_data(a_rx_d), .a_rx_valid(a_rx_v), .a_rx_ack(a_rx_a),
    .b_tx_data(b_tx_d), .b_tx_valid(b_tx_v), .b_tx_ack(b_tx_a),
    .b_rx_data(b_rx_d), .b_rx_valid(b_rx_v), .b_rx_ack(b_rx_a),
    .dbg_a_bytes(dbg_a_bytes), .dbg_a_last(dbg_a_last)
  );

endmodule
