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

  output logic  [7:0] a_stat, b_stat, a_data, b_data,
  output logic [31:0] dbg_a_bytes,
  output logic  [7:0] dbg_a_last,
  output logic [31:0] dbg_a_sig
);

  logic [7:0] a_tx_d, a_rx_d, b_tx_d, b_rx_d;
  // Brought out rather than left empty: the core reads both registers as one
  // dword, so the test should exercise the same ports the core uses.
  logic [7:0] a_data_o, a_stat_o, b_data_o, b_stat_o;
  logic       a_tx_v, a_tx_a, a_rx_v, a_rx_a;
  logic       a_irx, a_itx, b_irx, b_itx;   // the split flags; this test uses irq
  logic       b_tx_v, b_tx_a, b_rx_v, b_rx_a;

  m2_i8251 u_a (
    .clk(clk), .rst_n(rst_n),
    .sel(a_sel), .we(a_we), .addr(a_addr), .din(a_din), .dout(a_dout), .data_o(a_data_o), .stat_o(a_stat_o),
    .tx_data(a_tx_d), .tx_valid(a_tx_v), .tx_ack(a_tx_a),
    .rx_data(a_rx_d), .rx_valid(a_rx_v), .rx_ack(a_rx_a),
    .irq(a_irq), .irq_rx(a_irx), .irq_tx(a_itx)
  );

  m2_i8251 u_b (
    .clk(clk), .rst_n(rst_n),
    .sel(b_sel), .we(b_we), .addr(b_addr), .din(b_din), .dout(b_dout), .data_o(b_data_o), .stat_o(b_stat_o),
    .tx_data(b_tx_d), .tx_valid(b_tx_v), .tx_ack(b_tx_a),
    .rx_data(b_rx_d), .rx_valid(b_rx_v), .rx_ack(b_rx_a),
    .irq(b_irq), .irq_rx(b_irx), .irq_tx(b_itx)
  );

  m2_sound_link #(.BYTE_CYCLES(BYTE_CYCLES)) u_link (
    .clk(clk), .rst_n(rst_n),
    .a_tx_data(a_tx_d), .a_tx_valid(a_tx_v), .a_tx_ack(a_tx_a),
    .a_rx_data(a_rx_d), .a_rx_valid(a_rx_v), .a_rx_ack(a_rx_a),
    .b_tx_data(b_tx_d), .b_tx_valid(b_tx_v), .b_tx_ack(b_tx_a),
    .b_rx_data(b_rx_d), .b_rx_valid(b_rx_v), .b_rx_ack(b_rx_a),
    .dbg_a_bytes(dbg_a_bytes), .dbg_a_last(dbg_a_last), .dbg_a_sig(dbg_a_sig)
  );

  wire _unused = &{1'b0, a_irx, a_itx, b_irx, b_itx, 1'b0};

  assign a_stat = a_stat_o;
  assign b_stat = b_stat_o;
  assign a_data = a_data_o;
  assign b_data = b_data_o;

endmodule
