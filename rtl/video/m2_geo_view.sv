// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// m2_geo_view -- THE PROJECTION, FROM THE GAME'S OWN WINDOW COMMAND (R642).
//
// R174 fixed the projection at "a 496x384 screen centred at (248,192)". The
// game says otherwise (R641): geo_window_data carries the viewport and the
// projection centre, Daytona's centre is (248,270) most of the time, and its
// attract cameras move it 270 -> 312 -> 270. MAME (model2_v.cpp):
//
//   model2_3d_project:  x = crtc_xoffset + center[0] + x/z
//                       y = (384 - center[1]) + crtc_yoffset - y/z
//   window command 3:   left   = center[0] - viewport[0]
//                       right  = viewport[2] - center[0]
//                       top    = viewport[3] - center[1]
//                       bottom = center[1] - viewport[1]
//
// and m2_geo_project / m2_geo_clip take s = (xc + x/z, yc - y/z) with the
// frustum as four slopes (R174: Model 1's a_bottom is MAME's TOP plane):
//
//   xc = crtc_xoffset + cx          yc = 384 - cy + crtc_yoffset
//   a_left = -left   a_right = right   a_bottom = top   a_top = -bottom
//
// The CRTC offsets are parameters: MAME logs 0 and 128 for Daytona on every
// frame (p13c), set from CRTC registers this core does not decode.
//
// The window changes at most once a list and the geometry is idle between
// objects, so the conversion takes two registered stages and no hurry.

`timescale 1ns/1ps

module m2_geo_view #(
  parameter int CRTC_X = 0,
  parameter int CRTC_Y = 128
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [31:0] win_vp_s,     // {x[27:16], y[11:0]}, 12-bit signed
  input  logic [31:0] win_vp_e,
  input  logic [31:0] win_c0,
  output logic [31:0] xc, yc,
  output logic [31:0] a_left, a_right, a_bottom, a_top
);

  function automatic logic signed [15:0] s12(input logic [11:0] v);
    s12 = 16'(signed'(v));
  endfunction

  // A small signed integer to IEEE-754 single, exactly (|v| < 2^15).
  function automatic logic [31:0] i2f(input logic signed [15:0] v);
    logic        sg;
    logic [15:0] m;
    int          e;
    logic [31:0] f;
    begin
      sg = v[15];
      m  = sg ? 16'(-v) : 16'(v);
      e  = 0;
      for (int i = 0; i < 16; i++) if (m[i]) e = i;
      if (m == 16'd0) f = 32'd0;
      else            f = {sg, 8'(127 + e), 23'({m, 23'd0} >> e)};
      i2f = f;
    end
  endfunction

  wire signed [15:0] vx0 = s12(win_vp_s[27:16]), vy0 = s12(win_vp_s[11:0]);
  wire signed [15:0] vx1 = s12(win_vp_e[27:16]), vy1 = s12(win_vp_e[11:0]);
  wire signed [15:0] cx  = s12(win_c0[27:16]),   cy  = s12(win_c0[11:0]);

  // Bits 31:28 and 15:12 are outside the two twelve-bit fields (MAME masks
  // them: x = (w & 0x0fff0000) >> 4, y = w & 0xfff).
  wire _unused = &{1'b0, win_vp_s[31:28], win_vp_s[15:12], win_vp_e[31:28],
                   win_vp_e[15:12], win_c0[31:28], win_c0[15:12]};

  // Stage 1: the six integers.
  logic signed [15:0] ixc, iyc, il, ir, it, ib;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ixc <= 16'sd248; iyc <= 16'sd192;
      il  <= 16'sd248; ir  <= 16'sd248; it <= 16'sd192; ib <= 16'sd192;
    end else begin
      ixc <= 16'(CRTC_X) + cx;
      iyc <= 16'sd384 - cy + 16'(CRTC_Y);
      il  <= cx - vx0;
      ir  <= vx1 - cx;
      it  <= vy1 - cy;
      ib  <= cy - vy0;
    end
  end

  // Stage 2: to float. Reset to R174's constants, which the power-up window
  // (m2_geo's reset words) also produces.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      xc <= 32'h4378_0000; yc <= 32'h4340_0000;             // 248, 192
      a_left <= 32'hC378_0000; a_right <= 32'h4378_0000;    // -248, +248
      a_bottom <= 32'h4340_0000; a_top <= 32'hC340_0000;    // +192, -192
    end else begin
      xc       <= i2f(ixc);
      yc       <= i2f(iyc);
      a_left   <= i2f(-il);
      a_right  <= i2f(ir);
      a_bottom <= i2f(it);
      a_top    <= i2f(-ib);
    end
  end

endmodule
