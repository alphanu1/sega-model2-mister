// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// jt12 AND ITS TIMER-ONLY STAND-IN ON ONE BUS, for tb_m2_ym_timers (R833).
// Both see the same reset, enable and write strobe on every clock; the
// testbench compares what the 68000 could read (dout) and the interrupt.

`timescale 1ns/1ps

module m2_ym_timers_harness (
  input  logic        clk,
  input  logic        rst,
  input  logic        cen,
  input  logic  [7:0] din,
  input  logic  [1:0] addr,
  input  logic        cs_n,
  input  logic        wr_n,

  output logic  [7:0] dout_j, dout_s,
  output logic        irq_n_j, irq_n_s,
  output logic signed [15:0] snd_l_s, snd_r_s,
  output logic        flag_a, flag_b, busy, zero
);

  jt12 u_jt12 (
    .rst(rst), .clk(clk), .cen(cen),
    .din(din), .addr(addr), .cs_n(cs_n), .wr_n(wr_n),
    .dout(dout_j), .irq_n(irq_n_j), .en_hifi_pcm(1'b0),
    .snd_right(), .snd_left(), .snd_sample()
  );

  m2_ym_timers u_stub (
    .rst(rst), .clk(clk), .cen(cen),
    .din(din), .addr(addr), .cs_n(cs_n), .wr_n(wr_n),
    .dout(dout_s), .irq_n(irq_n_s), .en_hifi_pcm(1'b0),
    .snd_right(snd_r_s), .snd_left(snd_l_s), .snd_sample()
  );

  // jt12's own internals, for coverage counts only
  assign flag_a = u_jt12.u_jt12.flag_A;
  assign flag_b = u_jt12.u_jt12.flag_B;
  assign busy   = u_jt12.u_jt12.busy;
  assign zero   = u_jt12.u_jt12.zero;

endmodule
