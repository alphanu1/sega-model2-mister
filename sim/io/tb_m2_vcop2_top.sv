// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R870: Virtua Cop 2's guns as the 2A build wires them (Model2.sv g_vcgun /
// g_5649 with VCOP2GUN): m2_vcop_guns (V2) -> m2_315_5649 (GUN) serial
// channel 2, and its triggers through m2_2a_inputs (GUN) to port C. The bench
// drives MiSTer's inputs and reads the chip on the i960's side.

`timescale 1ns/1ps

module tb_m2_vcop2_top (
  input  logic        clk,
  input  logic        por_n,
  input  logic        rst_n,
  input  logic  [1:0] play,
  input  logic [15:0] joy0, joy1,
  input  logic [15:0] ana0, ana1,
  input  logic [24:0] ps2_mouse,
  input  logic  [1:0] mouse_sel,
  // the i960's access to 0x01c00000-0x01c0001f
  input  logic        sel,
  input  logic        we,
  input  logic  [2:0] word,
  input  logic  [3:0] be,
  input  logic [31:0] wdata,
  output logic [31:0] rdata,
  // the driver's own outputs, for the crosshair checks
  output logic  [8:0] c1x, c1y, c2x, c2y,
  output logic  [1:0] c_on,
  output logic  [9:0] p1x, p1y, p2x, p2y,
  output logic  [1:0] goff
);
  logic [7:0] g_in0, g_in1;
  m2_vcop_guns #(.TICK_LOG2(6), .V2(1'b1)) guns (
    .clk, .rst_n, .en(1'b1), .play,
    .joy0, .joy1, .ana0, .ana1, .ps2_mouse, .mouse_sel,
    .in0(g_in0), .in1(g_in1),
    .p1x, .p1y, .p2x, .p2y, .off(goff),
    .c1x, .c2x, .c1y, .c2y, .c_on
  );

  logic [7:0] in0, in1, in2, an0, an1, an2, lamps, dbg_pa, dbg_dir, pe_q;
  m2_2a_inputs #(.SYS_MHZ(80), .ANALOG(1'b0), .GUN(1'b1)) inputs (
    .clk, .rst_n, .game(7'h11),   // R887: Virtua Cop 2's ID, the GUN profile
    .joystick_0({16'd0, joy0}), .joystick_1({16'd0, joy1}),
    .joy_analog(16'd0), .joy_ranalog(16'd0), .joy_analog_1(16'd0), .paddle(8'd0),
    .st_pedswap(1'b0), .st_ssens(2'd0), .st_ssm(2'd0), .st_rsteer(1'b0),
    .gun_in1(g_in1), .pe(8'hFF),
    .in0, .in1, .in2, .an0, .an1, .an2
  );

  m2_315_5649 #(.GUN(1'b1)) io (
    .clk, .por_n, .rst_n, .sel, .we, .word, .be, .wdata, .rdata,
    .in0, .in1, .in2, .sw(8'hFF), .an0, .an1, .an2,
    .gun_p1x(p1x), .gun_p1y(p1y), .gun_p2x(p2x), .gun_p2y(p2y), .gun_off(goff),
    .lamps(lamps), .pe(pe_q), .dbg_pa(dbg_pa), .dbg_dir(dbg_dir)
  );

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, g_in0, lamps, dbg_pa, dbg_dir, pe_q};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule
