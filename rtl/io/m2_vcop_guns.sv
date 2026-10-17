// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE for the full text.
//
// VIRTUA COP'S TWO LIGHT GUNS, FROM MISTER'S STICKS AND MOUSE (R839, R846).
//
// The cabinet's guns reach the game through the type-2 I/O board's "FPGA" at
// 0x8100 (m2_ioz80, TYPE2): four 10-bit coordinates in the game's own units
// and an off-screen bit per gun. MAME 0.289 INPUT_PORTS_START(vcop), which are
// also the game's own default calibration (its GUN MARK CHECK screen shows
// these four ranges as AD1 / AD2 XMIN..YMAX):
//
//   P1_X 0x083..0x276   P1_Y 0x024..0x1a9
//   P2_X 0x080..0x273   P2_Y 0x027..0x1a9
//
// and model1io2.cpp fpga_r sets a gun's off-screen bit when any coordinate is
// within 5% of its range of either end (int(span * 0.05): X 24, Y 19).
//
// WHERE THE AIM COMES FROM -- MiSTer's convention (R846: System 32, PSX,
// MegaDrive, SNES, NES cores and Main_MiSTer read):
//   * the stick: joystick_l_analog_N as an ABSOLUTE screen position. A USB
//     light gun (Sinden, GUN4IR, ...) arrives exactly so, calibrated by MiSTer
//     (F10) to -127..+127 edge to edge and saturating there when aimed off the
//     screen. Player 1 is analog_0, player 2 analog_1. u = a + 128, then
//     px = u * 496 / 256, py = u * 384 / 256 (System 32's and PSX's form).
//   * the mouse: ps2_mouse is RELATIVE only (Main merges every mouse into one
//     stream and has no absolute channel; a gun's ABS axes never reach it),
//     so it is accumulated per packet, 1:1 in pixels, clamped to the screen,
//     for ONE gun ("aim+trig" in the OSD).
//   * the trigger: Main sends a QUIRK_LIGHTGUN gun's buttons to the MOUSE
//     buttons, not the joystick's, so the mouse's left / right buttons are
//     ALWAYS a trigger / reload for the gun the OSD gives the mouse (default
//     gun 1), whether or not the mouse also aims it. Joystick buttons work too.
//
// SCREEN PIXEL FIRST, GAME UNITS SECOND, so the crosshair is drawn on the
// pixel the game aims at. The game's own aim mark (GUN MARK CHECK) sits on
// pixel floor((v - min) * 496 / span) -- MAME's crosshair pixel -- within
// 0.7 px over 43 marks (R846), so each pixel maps to the smallest unit that
// lands on it, v - min = ceil(px * span / 496):
//   X  (span 499):          px + (px>0) + (px>=166) + (px>=331)
//   Y1 (span 389): py + (py>0) + (py>=77) + (py>=154) + (py>=231) + (py>=308)
//   Y2 (span 386): py + (py>0) + (py>=193)
// (tb_m2_vcop_guns checks every pixel against the floor rule.)
//
// Buttons, per player (joystick bits; the Virtua Cop MRA names them):
//   4 Trigger, 5 Reload, 6 Start, 7 Coin, 8 Test, 9 Service (player 1 only).
// RELOAD is "shoot off the screen", as on the cabinet: the gun is held at the
// off-screen corner at once and the trigger follows two ticks (~1.6-3.3 ms)
// later, so the I/O board's 1 kHz scan can never see the trigger with the gun
// still on the screen; the corner is held ~3 ticks after release likewise.
//
// IN0 (active low): 0x01 Coin 1, 0x02 Coin 2, 0x04 Test, 0x08 Service,
// 0x10 1P Start, 0x20 2P Start. IN1: 0x01 P1 trigger, 0x02 P2 trigger.
//
// R849: a crosshair shows only while its player is in play (play, the game's
// own state from m2_vcop_state) and on the screen.
// R850 (Ben): player 1's crosshair is shown ALL the time (attract, menus,
// test included) while on the screen -- it is the aim for the menus too;
// only player 2's waits for player 2 to be in play.
// en low (any game but Virtua Cop) shows no crosshair; Model2.sv takes in0 /
// in1 from here only for game ID 1 (vc_gun), as it did before this module was
// built, so Daytona and Desert Tank see the inputs they always did.
//
// VIRTUA COP 2 (V2 = 1, the 2A build's M2_2A_VCOP2_GUN; R870): the same
// sticks, mouse, buttons, reload and crosshairs, scaled to MAME 0.289
// INPUT_PORTS_START(vcop2):
//
//   P1_X 137..630 (0x089..0x276)   P1_Y 36..425 (0x024..0x1a9)
//   P2_X 134..627 (0x086..0x273)   P2_Y 36..425 (0x024..0x1a9)
//
// rest 0x17f / 0x0e6 / 0x17c / 0x0e6; off-screen by the same int(span * 0.05f)
// rule (lightgun_offscreen_r: X 24, Y 19). Y is Virtua Cop's P1_Y for both
// guns. X spans 493 units over 496 pixels, so v - min = ceil(px * 493 / 496)
// = px - (px>=166) - (px>=331): the SAME two thresholds as Virtua Cop's X,
// subtracted. Pixels 165, 330 and 495 have no unit of their own (MAME's
// crosshair skips them); they take the next pixel's. The game reads the four
// coordinates and the off-screen bits through the 315-5649's serial channel 2
// (m2_315_5649 GUN), not an I/O board; in0 is unused there (m2_2a_inputs has
// the same map) and the game's in-play state is its own (m2_vcop_state V2).
// V2 = 0 is Virtua Cop exactly: every V2 term is a parameter constant.
//
// TIMING: every stage is registered -- the hps_io inputs once, the pixel,
// then the game units, then the off-screen test -- so no path is longer than
// one small adder and a compare (R843's lesson: a stick into a long chain
// failed clk_sys). The I/O board reads at 1 kHz; four cycles are free.

`timescale 1ns/1ps

module m2_vcop_guns #(
  parameter int unsigned TICK_LOG2 = 17,    // reload tick: 2^17 clk_sys = 1.64 ms at 80 MHz
  parameter bit          V2        = 1'b0   // R870: Virtua Cop 2's ranges
) (
  input  logic        clk,            // clk_sys
  input  logic        rst_n,
  input  logic        en,             // Virtua Cop with the guns built (vc_gun)
  input  logic  [1:0] play,           // {P2, P1} in play (m2_vcop_state, clk_i960 = clk / 2; R849)
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [15:0] joy0, joy1,     // joystick_0 / joystick_1 [15:0]
  input  logic [15:0] ana0, ana1,     // joystick_l_analog_0 / _1: {Y, X}, signed
  input  logic [24:0] ps2_mouse,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic  [1:0] mouse_sel,      // OSD: 0 gun 1 trigger, 1 gun 1 aim+trig, 2 gun 2 trigger, 3 gun 2 aim+trig
  output logic  [7:0] in0, in1,
  output logic  [9:0] p1x, p1y, p2x, p2y,   // game units
  output logic  [1:0] off,                  // {P2, P1} off-screen
  output logic  [8:0] c1x, c2x,             // crosshairs, screen pixels
  output logic  [8:0] c1y, c2y,
  output logic  [1:0] c_on                  // {P2, P1}: draw it (en, in play, on the screen)
);

  // ------------------------------------------------------ inputs, registered
  logic [15:0] a0_q, a1_q;
  /* verilator lint_off UNUSEDSIGNAL */
  logic  [5:0] b0_q, b1_q;            // joystick bits 9:4 (player 2 has no Test / Service)
  logic [24:0] ms_q;                  // (the overflow bits and middle button unused)
  /* verilator lint_on UNUSEDSIGNAL */
  logic  [1:0] sel_q;
  logic        en_q;
  /* verilator lint_off UNUSEDSIGNAL */
  logic  [1:0] play_q;                // R850: bit 0 (P1) no longer gates its cross
  /* verilator lint_on UNUSEDSIGNAL */
  always_ff @(posedge clk) begin
    a0_q <= ana0;  a1_q <= ana1;
    b0_q <= joy0[9:4]; b1_q <= joy1[9:4];
    ms_q <= ps2_mouse;
    sel_q <= mouse_sel;
    en_q <= en;
    play_q <= play;
  end

  // ------------------------------------------------------ stick to pixel
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [8:0] sx(input logic [7:0] a);   // 0..494
    logic [7:0]  u;
    logic [16:0] m;
    u = a ^ 8'h80;
    m = {u, 9'd0} - {5'd0, u, 4'd0};                        // u * 496
    return m[16:8];
  endfunction
  function automatic logic [8:0] sy(input logic [7:0] a);   // 0..382
    logic [7:0]  v;
    logic [16:0] m;
    v = a ^ 8'h80;
    m = {1'b0, v, 8'd0} + {2'b0, v, 7'd0};                  // v * 384
    return m[16:8];
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // ------------------------------------------------------ the mouse
  // dx / dy are 9-bit two's complement: {sign in [4] / [5], byte}; Main
  // already sends Y up-positive, so screen y moves by -dy.
  logic [8:0] mx, my;
  logic       tgl_d;
  // Plain concatenations and unsigned compares, no signed casts (R662: Quartus
  // 17.0 folds some signed casts Verilator computes). nx / ny are -255..750
  // in 11-bit two's complement; bit 10 is the sign.
  wire [10:0] dx = {{3{ms_q[4]}}, ms_q[15:8]};
  wire [10:0] dy = {{3{ms_q[5]}}, ms_q[23:16]};
  wire [10:0] nx = {2'b00, mx} + dx;
  wire [10:0] ny = {2'b00, my} - dy;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin mx <= 9'd248; my <= 9'd192; tgl_d <= 1'b0; end
    else begin
      tgl_d <= ms_q[24];
      if (ms_q[24] != tgl_d) begin
        mx <= nx[10] ? 9'd0 : (nx > 11'd495) ? 9'd495 : nx[8:0];
        my <= ny[10] ? 9'd0 : (ny > 11'd383) ? 9'd383 : ny[8:0];
      end
    end
  end
  wire aim1_m = (sel_q == 2'd1);
  wire aim2_m = (sel_q == 2'd3);
  wire mb1    = !sel_q[1];             // the mouse's buttons belong to gun 1
  wire mb2    =  sel_q[1];

  // ------------------------------------------------------ the reload tick
  logic [TICK_LOG2-1:0] tdiv;
  logic tick;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin tdiv <= '0; tick <= 1'b0; end
    else begin tdiv <= tdiv + 1'd1; tick <= &tdiv; end
  end

  // ------------------------------------------------------ stage B: pixels, buttons
  logic [8:0] s1x, s1y, s2x, s2y;
  logic       t1, t2, r1, r2;         // trigger, reload held
  logic [2:0] rs1, rs2;               // reload, delayed by ticks
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1x <= 9'd248; s1y <= 9'd192; s2x <= 9'd248; s2y <= 9'd192;
      t1 <= 1'b0; t2 <= 1'b0; r1 <= 1'b0; r2 <= 1'b0;
      rs1 <= 3'd0; rs2 <= 3'd0;
    end else begin
      s1x <= aim1_m ? mx : sx(a0_q[7:0]);
      s1y <= aim1_m ? my : sy(a0_q[15:8]);
      s2x <= aim2_m ? mx : sx(a1_q[7:0]);
      s2y <= aim2_m ? my : sy(a1_q[15:8]);
      t1  <= b0_q[0] | (mb1 & ms_q[0]);
      t2  <= b1_q[0] | (mb2 & ms_q[0]);
      r1  <= b0_q[1] | (mb1 & ms_q[1]);
      r2  <= b1_q[1] | (mb2 & ms_q[1]);
      if (tick) begin rs1 <= {rs1[1:0], r1}; rs2 <= {rs2[1:0], r2}; end
    end
  end
  wire hold1 = r1 | (|rs1);           // at the corner: from the press until ~3 ticks after
  wire hold2 = r2 | (|rs2);
  wire fire1 = t1 | (r1 & rs1[1]);    // the trigger: the button, or a reload two ticks in
  wire fire2 = t2 | (r2 & rs2[1]);

  // ------------------------------------------------------ stage C: game units
  // each game's ranges (R870: V2 is Virtua Cop 2's; constants either way)
  localparam logic [9:0] X1LO = V2 ? 10'h089 : 10'h083;   // P1_X min
  localparam logic [9:0] X2LO = V2 ? 10'h086 : 10'h080;   // P2_X min
  localparam logic [9:0] Y2LO = V2 ? 10'h024 : 10'h027;   // P2_Y min
  localparam logic [9:0] P1X0 = V2 ? 10'h17f : 10'h17c;   // MAME's rest positions
  localparam logic [9:0] P2X0 = V2 ? 10'h17c : 10'h179;
  localparam logic [9:0] P2Y0 = V2 ? 10'h0e6 : 10'h0e8;
  localparam logic [9:0] O1XL = V2 ? 10'h0a1 : 10'h09b;   // min + int(span * 0.05f)
  localparam logic [9:0] O2XL = V2 ? 10'h09e : 10'h098;
  localparam logic [9:0] O2YL = V2 ? 10'h037 : 10'h03a;
  // the corrections are 0..5: a 3-bit count of the thresholds passed
  function automatic logic [9:0] ux(input logic [8:0] p, input logic [9:0] lo);
    logic [2:0] k;
    if (V2) begin                     // span 493: ceil(px * 493 / 496)
      k = {2'b00, p >= 9'd166} + {2'b00, p >= 9'd331};
      return lo + {1'b0, p} - {7'd0, k};
    end
    k = {2'b00, p != 9'd0} + {2'b00, p >= 9'd166} + {2'b00, p >= 9'd331};
    return lo + {1'b0, p} + {7'd0, k};
  endfunction
  function automatic logic [9:0] uy1(input logic [8:0] p);
    logic [2:0] k;
    k = {2'b00, p != 9'd0} + {2'b00, p >= 9'd77} + {2'b00, p >= 9'd154}
      + {2'b00, p >= 9'd231} + {2'b00, p >= 9'd308};
    return 10'h024 + {1'b0, p} + {7'd0, k};
  endfunction
  function automatic logic [9:0] uy2(input logic [8:0] p);
    logic [2:0] k;
    k = {2'b00, p != 9'd0} + {2'b00, p >= 9'd193};
    return 10'h027 + {1'b0, p} + {7'd0, k};
  endfunction
  logic [1:0] fire_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p1x <= P1X0; p1y <= 10'h0e6; p2x <= P2X0; p2y <= P2Y0;   // MAME's rest positions
      fire_q <= 2'b00;
    end else begin
      p1x <= hold1 ? X1LO : ux(s1x, X1LO);
      p1y <= hold1 ? 10'h024 : uy1(s1y);
      p2x <= hold2 ? X2LO : ux(s2x, X2LO);
      p2y <= hold2 ? Y2LO : (V2 ? uy1(s2y) : uy2(s2y));
      fire_q <= {fire2, fire1};
    end
  end
  // the crosshairs read the pixel registers themselves (a stage ahead of
  // the units; they cross to clk_mem by two flops anyway)
  assign c1x = s1x; assign c1y = s1y; assign c2x = s2x; assign c2y = s2y;

  // ------------------------------------------------------ stage D: off-screen, the ports
  // MAME's 5% border, from the coordinates as the board hands them over
  // (V2: lightgun_offscreen_r's, the same rule on Virtua Cop 2's ranges)
  wire o1 = (p1x <= O1XL) || (p1x >= 10'h25e) || (p1y <= 10'h037) || (p1y >= 10'h196);
  wire o2 = (p2x <= O2XL) || (p2x >= 10'h25b) || (p2y <= O2YL) || (p2y >= 10'h196);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      off <= 2'b00; c_on <= 2'b00; in0 <= 8'hFF; in1 <= 8'hFF;
    end else begin
      off  <= {o2, o1};
      c_on <= {en_q & play_q[1] & ~o2, en_q & ~o1};   // R850: P1 always
      in0  <= ~{2'b00, b1_q[2], b0_q[2], b0_q[5], b0_q[4], b1_q[3], b0_q[3]};
      in1  <= ~{6'd0, fire_q};
    end
  end

endmodule
