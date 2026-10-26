// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R835: rtl/io/m2_cab_inputs.sv beside sim/io/m2_cab_inputs_ref.sv (the block
// as Model2.sv had it at 0f3cbc4), on the same inputs. tb_m2_cab_inputs.cpp
// compares them with is_desert = 0 and checks Desert Tank's map with it set.
// R837: a second copy at SYS_MHZ 1 (`f_` outputs), so the turret's
// millisecond timers step thousands of times in a run, not dozens.
// R958: st_wheel (Analog control) on both copies; the reference has none, so
// with it at Standard the comparison is the default unchanged.

`timescale 1ns/1ps

module tb_m2_cab_inputs_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        is_desert,
  input  logic [31:0] joystick_0,
  input  logic [15:0] joy_analog,
  input  logic [15:0] joy_ranalog,
  input  logic  [7:0] paddle,
  input  logic        st_pedswap,
  input  logic  [1:0] st_ssens,
  input  logic  [1:0] st_ssm,
  input  logic        st_rsteer,
  input  logic  [1:0] st_wheel,
  output logic  [7:0] in0,  output logic [7:0] in1,
  output logic  [7:0] steer, output logic [7:0] accel, output logic [7:0] brake,
  output logic  [7:0] r_in0, output logic [7:0] r_in1,
  output logic  [7:0] r_steer, output logic [7:0] r_accel, output logic [7:0] r_brake,
  output logic  [7:0] f_in0, output logic [7:0] f_steer,
  output logic  [7:0] f_in1, output logic [7:0] f_accel, output logic [7:0] f_brake
);
  m2_cab_inputs #(.SYS_MHZ(80)) dut (
    .clk, .rst_n, .is_desert, .joystick_0, .joy_analog, .joy_ranalog, .paddle,
    .st_pedswap, .st_ssens, .st_ssm, .st_rsteer, .st_wheel,
    .in0, .in1, .steer, .accel, .brake);
  m2_cab_inputs_ref #(.SYS_MHZ(80)) ref_ (
    .clk, .rst_n, .joystick_0, .joy_analog, .joy_ranalog, .paddle,
    .st_pedswap, .st_ssens, .st_ssm, .st_rsteer,
    .in0(r_in0), .in1(r_in1), .steer(r_steer), .accel(r_accel), .brake(r_brake));
  m2_cab_inputs #(.SYS_MHZ(1)) fast (
    .clk, .rst_n, .is_desert, .joystick_0, .joy_analog, .joy_ranalog, .paddle,
    .st_pedswap, .st_ssens, .st_ssm, .st_rsteer, .st_wheel,
    .in0(f_in0), .in1(f_in1), .steer(f_steer), .accel(f_accel), .brake(f_brake));
endmodule
