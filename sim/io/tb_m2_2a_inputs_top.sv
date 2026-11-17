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
// R892: MOTION (Manx TT's motion base on PD from PE) -- dut has it, dut_nm
// (MOTION 0) is the build without it; both are checked.
// R928: OREV (Over Rev, 0x1C, 2C builds) -- dut_or has it; dut / dut_nm
// (OREV 0) see 0x1C as a digital ID, as a 2A build does.
// R958: st_wheel (Analog control) on every copy; cab0 is the block at
// Standard, Sky Target's reference.
// R1010: C2G on dut_or (Wave Runner 0x1E, Water Ski 0x1F, Behind Enemy Lines
// 0x20); dut / dut_nm (C2G 0) must read those IDs as digital. an3 on each.
// R1016: Behind Enemy Lines' aim through the real chain -- m2_vcop_guns as
// the 2C build has it (V2, HD) turns the sticks or the mouse into pixels,
// dut_or maps them; its pixels are outputs (g_c1x ..) for the bench's
// diagnosis only, the reference is computed from the sticks and mouse
// packets. dut / dut_nm see the ports tied as a 2A build's harness would.
// R1037: dut_b2 is the 2B build's (B2G 1: Gunblade NY 0x25, INDY 500 0x26,
// Super GT 24h 0x27, Rail Chase 2 0x29; MOTION 0, C2G 0); every other copy
// must read 0x25-0x29 as digital IDs.

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
  input  logic  [1:0] st_wheel,       // R958: Analog control
  input  logic  [7:0] trig_rt,        // R981: the analogue triggers, on every copy
  input  logic  [7:0] trig_lt,
  input  logic  [7:0] pe,             // R892: the 315-5649's PE latch
  input  logic [24:0] ps2_mouse,      // R1016: hps_io's mouse word
  input  logic  [1:0] mouse_sel,      // R1016: the OSD's Mouse line (status[63:62])
  output logic  [8:0] g_c1x, output logic [8:0] g_c1y, output logic [8:0] g_c2x, output logic [8:0] g_c2y,
  output logic  [7:0] o_in0, output logic [7:0] o_in1, output logic [7:0] o_in2,   // R928: OREV 1
  output logic  [7:0] o_an0, output logic [7:0] o_an1, output logic [7:0] o_an2,
  output logic  [7:0] o_an3, output logic [7:0] n_an3, output logic [7:0] an3,   // R1010
  output logic  [7:0] n_in0, output logic [7:0] n_in1, output logic [7:0] n_in2,   // R892: MOTION 0
  output logic  [7:0] n_an0, output logic [7:0] n_an1, output logic [7:0] n_an2,
  output logic  [7:0] in0, output logic [7:0] in1, output logic [7:0] in2,
  output logic  [7:0] an0, output logic [7:0] an1, output logic [7:0] an2,
  output logic  [7:0] r_in0, output logic [7:0] r_in1, output logic [7:0] r_in2,
  output logic  [7:0] c_in1, output logic [7:0] c_steer,
  output logic  [7:0] c_accel, output logic [7:0] c_brake,
  output logic  [7:0] c0_steer,       // R958: the block at Standard (Sky Target's)
  output logic  [7:0] b_in0, output logic [7:0] b_in1, output logic [7:0] b_in2,   // R1037: the 2B build (B2G 1)
  output logic  [7:0] b_an0, output logic [7:0] b_an1, output logic [7:0] b_an2, output logic [7:0] b_an3
);
  // R1037: the 2B build's copy -- ANALOG, OREV, B2G; no MOTION (M2_NO_2A_MANX_MOTION),
  // no C2G (R1035), no guns (the pixels tied as a build without them)
  m2_2a_inputs #(.SYS_MHZ(80), .ANALOG(1'b1), .MOTION(1'b0), .OREV(1'b1), .C2G(1'b0), .B2G(1'b1)) dut_b2 (
    .clk, .rst_n, .game, .joystick_0, .joystick_1,
    .joy_analog, .joy_ranalog, .joy_analog_1, .paddle, .st_pedswap, .st_ssens, .st_ssm, .st_rsteer, .st_wheel, .trig_rt, .trig_lt,
    .gun_in1(8'hFF), .pe, .gun_c1x(9'd0), .gun_c1y(9'd0), .gun_c2x(9'd0), .gun_c2y(9'd0), .ms_btn(2'b00), .ms_gun2(1'b0),
    .in0(b_in0), .in1(b_in1), .in2(b_in2), .an0(b_an0), .an1(b_an1), .an2(b_an2), .an3(b_an3));
  m2_2a_inputs #(.SYS_MHZ(80), .ANALOG(1'b1), .MOTION(1'b1)) dut (
    .clk, .rst_n, .game, .joystick_0, .joystick_1,
    .joy_analog, .joy_ranalog, .joy_analog_1, .paddle, .st_pedswap, .st_ssens, .st_ssm, .st_rsteer, .st_wheel, .trig_rt, .trig_lt,
    .gun_in1(8'hFF), .pe, .gun_c1x(9'd0), .gun_c1y(9'd0), .gun_c2x(9'd0), .gun_c2y(9'd0), .ms_btn(2'b00), .ms_gun2(1'b0),
    .in0, .in1, .in2, .an0, .an1, .an2, .an3);
  m2_2a_inputs #(.SYS_MHZ(80), .ANALOG(1'b1), .MOTION(1'b0)) dut_nm (
    .clk, .rst_n, .game, .joystick_0, .joystick_1,
    .joy_analog, .joy_ranalog, .joy_analog_1, .paddle, .st_pedswap, .st_ssens, .st_ssm, .st_rsteer, .st_wheel, .trig_rt, .trig_lt,
    .gun_in1(8'hFF), .pe, .gun_c1x(9'd0), .gun_c1y(9'd0), .gun_c2x(9'd0), .gun_c2y(9'd0), .ms_btn(2'b00), .ms_gun2(1'b0),
    .in0(n_in0), .in1(n_in1), .in2(n_in2), .an0(n_an0), .an1(n_an1), .an2(n_an2), .an3(n_an3));

  m2_2a_inputs #(.SYS_MHZ(80), .ANALOG(1'b1), .MOTION(1'b1), .OREV(1'b1), .C2G(1'b1)) dut_or (   // R928; R1010 C2G
    .clk, .rst_n, .game, .joystick_0, .joystick_1,
    .joy_analog, .joy_ranalog, .joy_analog_1, .paddle, .st_pedswap, .st_ssens, .st_ssm, .st_rsteer, .st_wheel, .trig_rt, .trig_lt,
    .gun_in1(8'hFF), .pe, .gun_c1x(g_c1x), .gun_c1y(g_c1y), .gun_c2x(g_c2x), .gun_c2y(g_c2y),   // R1016
    .ms_btn(ps2_mouse[1:0]), .ms_gun2(mouse_sel[1]),
    .in0(o_in0), .in1(o_in1), .in2(o_in2), .an0(o_an0), .an1(o_an1), .an2(o_an2), .an3(o_an3));

  // R1016: the guns' driver as Model2.sv's u_vcop_guns on a 2C build (en is
  // Virtua Cop 2 / HOTD only, so 0 here: Behind Enemy Lines draws its own cross)
  wire [7:0] g_in0, g_in1;
  wire [9:0] g_p1x, g_p1y, g_p2x, g_p2y;
  wire [1:0] g_off, g_con;
  m2_vcop_guns #(.TICK_LOG2(6), .V2(1'b1), .HD(1'b1)) guns (
    .clk, .rst_n, .en(1'b0), .play(2'b00),
    .joy0(joystick_0[15:0]), .joy1(joystick_1[15:0]), .ana0(joy_analog), .ana1(joy_analog_1),
    .ps2_mouse, .mouse_sel, .edge_sel(2'd0),
    .in0(g_in0), .in1(g_in1), .p1x(g_p1x), .p1y(g_p1y), .p2x(g_p2x), .p2y(g_p2y), .off(g_off),
    .c1x(g_c1x), .c1y(g_c1y), .c2x(g_c2x), .c2y(g_c2y), .c_on(g_con));

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
    .st_pedswap, .st_ssens, .st_ssm, .st_rsteer, .st_wheel, .trig_rt, .trig_lt,
    .in0(c_in0), .in1(c_in1), .steer(c_steer), .accel(c_accel), .brake(c_brake));
  // R958: the same block at Analog control Standard -- what Sky Target must see
  wire [7:0] c0_in0, c0_in1, c0_accel, c0_brake;
  m2_cab_inputs #(.SYS_MHZ(80)) cab0 (
    .clk, .rst_n, .is_desert(1'b0), .joystick_0, .joy_analog, .joy_ranalog, .paddle,
    .st_pedswap, .st_ssens, .st_ssm, .st_rsteer, .st_wheel(2'd0), .trig_rt, .trig_lt,
    .in0(c0_in0), .in1(c0_in1), .steer(c0_steer), .accel(c0_accel), .brake(c0_brake));
endmodule
