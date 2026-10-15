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
// VIRTUA COP'S CROSSHAIRS (R839, R846), drawn into the picture in the game's
// own pixels, before the framework's scaler -- MiSTer's convention (System
// 32, PSX, MegaDrive, SNES all draw in the native pixel domain).
//
// A '+' per gun, arms of 5 (Small) or 9 (Large) pixels from the centre, one
// pixel wide, in the game's own colours for its two players (its GUN MARK
// CHECK marks: player 1 cyan 69FFFF, player 2 pink FF90A4), with a one-pixel
// black outline so it shows on any background. Hidden when its gun is off
// the screen (c_on), as the reference cores do; player 1 is drawn over
// player 2.
//
// THE CENTRE IS THE PIXEL THE GAME AIMS AT: (cx, cy) are m2_vcop_guns's
// screen pixels, whose game units it chose so the game's own aim mark lands
// on that pixel (R846). x is the column the picture is showing (vid_x_d,
// R779); y is the line: progressive, vcnt; 15 kHz interlaced, the field's row
// r is line 2r + field, and the crosshair is compared as line {r, cy[0]} --
// the horizontal arm then shows in BOTH fields (lines cy & ~1 and cy | 1)
// instead of flickering at 30 Hz in one, and the vertical arm keeps its
// length in each field.
//
// TIMING (clk_mem, 100 MHz): the positions are quasi-static and cross from
// clk_sys by two flops; the line's offsets (dy) are registered once a cycle
// (they change at the line's start, a whole blanked pixel before column 0);
// per pixel, one 11-bit subtract is registered (dx), then the range tests
// (|d| <= 10 needs only the low 4 bits and a sign check), then the colour.
// The colour leaves three clk_mem cycles after the column -- a pixel is
// 6.25 cycles at 24 kHz and 9-10 at 15 kHz, and the framework samples on the
// next ce_pix, so the cross is on its column (tb_m2_vcop_xhair checks it
// against the column/line the picture is showing, both modes).

`timescale 1ns/1ps

module m2_vcop_xhair (
  input  logic        clk,            // clk_mem
  input  logic  [1:0] on,             // {P2, P1} from m2_vcop_guns c_on (clk_sys)
  input  logic  [1:0] size,           // OSD: 0 Small, 1 Large, 2 Off (clk_sys)
  input  logic  [8:0] c1x, c1y, c2x, c2y,   // screen pixels (clk_sys)
  input  logic        il,             // 15 kHz interlaced (clk)
  input  logic  [9:0] vx,             // the column showing (vid_x_d)
  input  logic  [9:0] vy,             // vcnt: the line, or the field's row
  input  logic  [7:0] in_r, in_g, in_b,
  output logic  [7:0] out_r, out_g, out_b
);

  // ---------------------------------------------------- crossings (quasi-static)
  logic [8:0] x1a, y1a, x2a, y2a, x1b, y1b, x2b, y2b;
  logic [3:0] ea, eb;
  always_ff @(posedge clk) begin
    x1a <= c1x; y1a <= c1y; x2a <= c2x; y2a <= c2y;
    x1b <= x1a; y1b <= y1a; x2b <= x2a; y2b <= y2a;
    ea  <= {size, on}; eb <= ea;
  end
  wire       show = (eb[3:2] != 2'd2) && (eb[3:2] != 2'd3);
  wire [1:0] sh   = eb[1:0] & {2{show}};
  wire [4:0] la   = eb[2] ? 5'd9 : 5'd5;      // the arm
  wire [4:0] lo   = la + 5'd1;                // the arm's outline

  // |d| <= k for a signed 11-bit d and k <= 15
  function automatic logic inr(input logic [10:0] d, input logic [4:0] k);
    return ((d[10:4] == 7'h00) && ({1'b0, d[3:0]} <= k))
        || ((d[10:4] == 7'h7F) && ({1'b0, d[3:0]} >= 5'd16 - k));
  endfunction

  // ---------------------------------------------------- the line (once a cycle)
  logic [10:0] dy1, dy2;
  logic [3:0]  r1, r2;                // {col_o, col_c, row_o, row_c}
  always_ff @(posedge clk) begin
    dy1 <= {1'b0, (il ? {vy[8:0], y1b[0]} : vy)} - {2'b00, y1b};
    dy2 <= {1'b0, (il ? {vy[8:0], y2b[0]} : vy)} - {2'b00, y2b};
    r1  <= {inr(dy1, lo), inr(dy1, la), inr(dy1, 5'd1), (dy1 == 11'd0)};
    r2  <= {inr(dy2, lo), inr(dy2, la), inr(dy2, 5'd1), (dy2 == 11'd0)};
  end

  // ---------------------------------------------------- the pixel
  logic [10:0] dx1, dx2;
  logic [1:0]  hc, ho;                // {P2, P1}: colour, outline
  always_ff @(posedge clk) begin
    dx1 <= {1'b0, vx} - {2'b00, x1b};
    dx2 <= {1'b0, vx} - {2'b00, x2b};
    hc[0] <= sh[0] && ((r1[0] && inr(dx1, la)) || (r1[2] && (dx1 == 11'd0)));
    ho[0] <= sh[0] && ((r1[1] && inr(dx1, lo)) || (r1[3] && inr(dx1, 5'd1)));
    hc[1] <= sh[1] && ((r2[0] && inr(dx2, la)) || (r2[2] && (dx2 == 11'd0)));
    ho[1] <= sh[1] && ((r2[1] && inr(dx2, lo)) || (r2[3] && inr(dx2, 5'd1)));
  end

  always_ff @(posedge clk) begin
    if (hc[0])      begin out_r <= 8'h69; out_g <= 8'hFF; out_b <= 8'hFF; end
    else if (hc[1]) begin out_r <= 8'hFF; out_g <= 8'h90; out_b <= 8'hA4; end
    else if (|ho)   begin out_r <= 8'h00; out_g <= 8'h00; out_b <= 8'h00; end
    else            begin out_r <= in_r;  out_g <= in_g;  out_b <= in_b;  end
  end

endmodule
