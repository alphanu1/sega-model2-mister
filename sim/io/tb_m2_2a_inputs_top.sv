// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R862: rtl/io/m2_2a_inputs.sv beside two references on the same inputs:
//   * VF2's map as Model2.sv had it at 9fb631d (the three expressions and
//     their register, copied here verbatim) -- r_in0..r_in2;
//   * Daytona's m2_cab_inputs, unchanged, for Sega Rally's analog channels
//     and shifter -- c_in1, c_steer, c_accel, c_brake.
// tb_m2_2a_inputs.cpp compares VF2 bit for bit and checks Sega Rally, Virtua
// Cop 2 and Zero Gunner against models written from MAME's INPUT_PORTS.
// R887: the module now takes the game ID and picks a profile (DIGITAL,
// ANALOG, GUN); the bench drives IDs, the new games' included.

`timescale 1ns/1ps

module tb_m2_2a_inputs_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic  [6:0] game,           // R887: the game ID
  input  logic [31:0] joystick_0,
  input  logic [31:0] joystick_1,
  input  logic [15:0] joy_analog,
  input  logic [15:0] joy_ranalog,
  input  logic [15:0] joy_analog_1,   // R879
  input  logic [31:0] jr0, jr1,       // R879: the reference's joysticks, the sticks folded in by the bench
  input  logic  [7:0] paddle,
  input  logic        st_pedswap,
  input  logic  [1:0] st_ssens,
  input  logic  [1:0] st_ssm,
  input  logic        st_rsteer,
  output logic  [7:0] in0, output logic [7:0] in1, output logic [7:0] in2,
  output logic  [7:0] an0, output logic [7:0] an1, output logic [7:0] an2,
  output logic  [7:0] r_in0, output logic [7:0] r_in1, output logic [7:0] r_in2,
  output logic  [7:0] c_in1, output logic [7:0] c_steer,
  output logic  [7:0] c_accel, output logic [7:0] c_brake
);
  m2_2a_inputs #(.SYS_MHZ(80), .ANALOG(1'b1)) dut (
    .clk, .rst_n, .game, .joystick_0, .joystick_1,
    .joy_analog, .joy_ranalog, .joy_analog_1, .paddle, .st_pedswap, .st_ssens, .st_ssm, .st_rsteer,
    .gun_in1(8'hFF), .in0, .in1, .in2, .an0, .an1, .an2);

  // Model2.sv at 9fb631d, g_5649 -- verbatim
  wire [7:0] a2_in0 = ~{2'b00, joystick_1[7], joystick_0[7], joystick_0[10],
                        joystick_0[9], joystick_1[8], joystick_0[8]};
  // (R879: the directions from jr0 / jr1 -- the joysticks with the bench's
  // model of the analogue sticks folded in; otherwise verbatim)
  wire [7:0] a2_in1 = ~{jr0[1], jr0[0], jr0[3], jr0[2],
                        1'b0, joystick_0[6], joystick_0[5], joystick_0[4]};
  wire [7:0] a2_in2 = ~{jr1[1], jr1[0], jr1[3], jr1[2],
                        1'b0, joystick_1[6], joystick_1[5], joystick_1[4]};
  always_ff @(posedge clk) begin
    r_in0 <= a2_in0; r_in1 <= a2_in1; r_in2 <= a2_in2;
  end

  wire [7:0] c_in0;
  m2_cab_inputs #(.SYS_MHZ(80)) cab (
    .clk, .rst_n, .is_desert(1'b0), .joystick_0, .joy_analog, .joy_ranalog, .paddle,
    .st_pedswap, .st_ssens, .st_ssm, .st_rsteer,
    .in0(c_in0), .in1(c_in1), .steer(c_steer), .accel(c_accel), .brake(c_brake));
endmodule
