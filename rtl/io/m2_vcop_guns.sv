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
// VIRTUA COP'S TWO LIGHT GUNS, FROM MISTER'S INPUTS (R839).
//
// The cabinet's guns reach the game through the type-2 I/O board's "FPGA" at
// 0x8100 (m2_ioz80, TYPE2): four 10-bit coordinates in the game's own units
// and an off-screen bit per gun. MAME 0.289 INPUT_PORTS_START(vcop):
//
//   P1_X 0x083..0x276   P1_Y 0x024..0x1a9      (PORT_MINMAX, across the
//   P2_X 0x080..0x273   P2_Y 0x027..0x1a9       visible 496 x 384 screen)
//
// and model1io2.cpp fpga_r sets a gun's off-screen bit when any coordinate is
// within 5% of its range of either end (int(span * 0.05): X 24, Y 19).
//
// THE SOURCE IS MISTER'S STANDARD FOR A GUN: the player's left analog axes as
// an ABSOLUTE position (-128..127 across the screen). That is how MiSTer
// Main delivers a calibrated light gun (Sinden, GUN4IR and the like) to a
// core, and with an ordinary pad it is the stick held where you aim. Player 1
// can take a mouse instead (OSD), accumulated and clamped to the screen.
//
// Screen pixel first, game units second, so the crosshair the core draws is
// where the game thinks the gun points:
//   px = u * 496 / 256, py = v * 384 / 256       (u, v = axis + 128)
//   X  = min + px + px / 128                     (499/496: within one unit)
//   Y  = min + py + py / 64   (P1, 389/384)  or  min + py + py / 128 (P2, 386/384)
//
// Buttons, per player (J1 / J2 positions; the MRA names them):
//   bit 4 Coin, 5 Start, 6 Test, 7 Service (player 1 only), 8 Trigger,
//   9 Reload: holds the gun at the off-screen corner AND pulls the trigger,
//   which is how the cabinet reloads (shoot off the screen). The mouse's
//   left button is Trigger and its right button Reload.
//
// IN0 (active low): 0x01 Coin 1, 0x02 Coin 2, 0x04 Test, 0x08 Service,
// 0x10 1P Start, 0x20 2P Start. IN1: 0x01 P1 trigger, 0x02 P2 trigger.

`timescale 1ns/1ps

module m2_vcop_guns #(
  parameter bit MOUSE = 1'b1          // player 1 may use the mouse (OSD)
) (
  input  logic        clk,            // clk_sys
  input  logic        rst_n,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [15:0] joy0, joy1,     // joystick_0 / joystick_1 [15:0]
  input  logic [15:0] ana0, ana1,     // joystick_l_analog_0 / _1: {Y, X}, signed
  input  logic [24:0] ps2_mouse,
  input  logic        use_mouse,      // player 1 from the mouse
  /* verilator lint_on UNUSEDSIGNAL */
  output logic  [7:0] in0, in1,
  output logic  [9:0] p1x, p1y, p2x, p2y,   // game units
  output logic  [1:0] off,                  // {P2, P1} off-screen
  output logic  [8:0] c1x, c2x,             // crosshairs, screen pixels
  output logic  [8:0] c1y, c2y
);

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

  // ------------------------------------------------------ the mouse (P1)
  logic [8:0] mx, my;
  generate if (MOUSE) begin : g_mouse
    logic tgl_d;
    // dx / dy are 9-bit two's complement: {sign in [4] / [5], byte}
    wire signed [9:0] dx = {ps2_mouse[4], ps2_mouse[4], ps2_mouse[15:8]};
    wire signed [9:0] dy = {ps2_mouse[5], ps2_mouse[5], ps2_mouse[23:16]};
    wire signed [10:0] nx = $signed({2'b00, mx}) + 11'(dx);
    wire signed [10:0] ny = $signed({2'b00, my}) - 11'(dy);   // mouse up = screen up
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin mx <= 9'd247; my <= 9'd191; tgl_d <= 1'b0; end
      else begin
        tgl_d <= ps2_mouse[24];
        if (ps2_mouse[24] != tgl_d) begin
          mx <= (nx < 0) ? 9'd0 : (nx > 11'sd495) ? 9'd495 : nx[8:0];
          my <= (ny < 0) ? 9'd0 : (ny > 11'sd383) ? 9'd383 : ny[8:0];
        end
      end
    end
  end else begin : g_nomouse
    assign mx = 9'd247;
    assign my = 9'd191;
  end endgenerate
  wire m_on   = MOUSE && use_mouse;
  wire m_trig = m_on && ps2_mouse[0];
  wire m_rld  = m_on && ps2_mouse[1];

  // ------------------------------------------------------ positions
  wire rld1 = joy0[9] | m_rld;
  wire rld2 = joy1[9];
  wire [8:0] q1x = m_on ? mx : sx(ana0[7:0]);
  wire [8:0] q1y = m_on ? my : sy(ana0[15:8]);
  wire [8:0] q2x = sx(ana1[7:0]);
  wire [8:0] q2y = sy(ana1[15:8]);

  // registered: the I/O board reads these at 1 kHz, and the crosshair at
  // most once a pixel, so a cycle is free and keeps the arithmetic off both
  always_ff @(posedge clk) begin
    c1x <= q1x; c1y <= q1y; c2x <= q2x; c2y <= q2y;
    p1x <= rld1 ? 10'h083 : 10'h083 + {1'b0, q1x} + {8'd0, q1x[8:7]};
    p1y <= rld1 ? 10'h024 : 10'h024 + {1'b0, q1y} + {7'd0, q1y[8:6]};
    p2x <= rld2 ? 10'h080 : 10'h080 + {1'b0, q2x} + {8'd0, q2x[8:7]};
    p2y <= rld2 ? 10'h027 : 10'h027 + {1'b0, q2y} + {8'd0, q2y[8:7]};
  end
  // MAME's 5% border, from the coordinates as the board hands them over
  assign off[0] = (p1x <= 10'h09b) || (p1x >= 10'h25e) || (p1y <= 10'h037) || (p1y >= 10'h196);
  assign off[1] = (p2x <= 10'h098) || (p2x >= 10'h25b) || (p2y <= 10'h03a) || (p2y >= 10'h196);

  // ------------------------------------------------------ buttons
  wire t1 = joy0[8] | joy0[9] | m_trig | m_rld;
  wire t2 = joy1[8] | joy1[9];
  assign in0 = ~{2'b00, joy1[5], joy0[5], joy0[7], joy0[6], joy1[4], joy0[4]};
  assign in1 = ~{6'd0, t2, t1};

endmodule
