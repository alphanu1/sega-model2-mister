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
// P1.5 step 1: a test pattern, so the first thing on a real screen answers
// questions instead of just proving the board is alive.
//
// It is designed to be read off a photograph, which is the same constraint the
// debug overlay is built under -- the screen is the only output channel.
//
// What each element is FOR:
//
//   1-pixel border      the visible window is 496x384 and nothing is cropped.
//                       If an edge is missing, the scaler or the sync
//                       parameters are wrong, not the timing counters.
//   8 colour bars       channel order and bit depth. Bars are R,G,B,C,M,Y,W,K
//                       so a swapped pair is obvious rather than plausible.
//   corner markers      orientation, so a vertically flipped or offset picture
//                       is not mistaken for a working one.
//   marching block      LIVENESS. It steps one bar-width per second. A frozen
//                       core and a working one look identical without it, and
//                       "is it still running" is the first question a bench
//                       asks. Wrapping, not saturating -- a saturating counter
//                       cannot show liveness (Model 1 differential-testing.md).

`timescale 1ns/1ps

module m2_testpattern #(
  parameter int unsigned H_VISIBLE = 496,
  parameter int unsigned V_VISIBLE = 384
) (
  input  logic       clk,
  input  logic       ce_pix,
  input  logic       rst_n,

  input  logic [9:0] hcnt,
  input  logic [9:0] vcnt,
  input  logic       visible,
  input  logic       vblank_start,

  output logic [7:0] r,
  output logic [7:0] g,
  output logic [7:0] b
);

  localparam int unsigned BAR_W = H_VISIBLE / 8;   // 62

  // Frame counter drives the marching block. Free-running and wrapping.
  logic [5:0] frame;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)           frame <= 6'd0;
    else if (vblank_start) frame <= frame + 6'd1;
  end

  // Which of the eight bars this pixel is in.
  logic [2:0] bar;
  always_comb bar = 3'(hcnt / 10'(BAR_W));

  logic at_border, at_corner, in_block;
  always_comb begin
    at_border = (hcnt == 10'd0) || (hcnt == 10'(H_VISIBLE - 1)) ||
                (vcnt == 10'd0) || (vcnt == 10'(V_VISIBLE - 1));
    // 16x16 blocks in the two top corners only, so top and bottom differ.
    at_corner = (vcnt < 10'd16) && ((hcnt < 10'd16) || (hcnt >= 10'(H_VISIBLE - 16)));
    // Marching block: one bar per ~57 frames, i.e. about a second.
    in_block  = (vcnt >= 10'(V_VISIBLE - 48)) && (vcnt < 10'(V_VISIBLE - 16)) &&
                (bar == frame[5:3]);
  end

  always_comb begin
    if (!visible)      {r, g, b} = 24'h00_00_00;
    else if (at_border){r, g, b} = 24'hff_ff_ff;
    else if (at_corner){r, g, b} = 24'hff_00_ff;
    else if (in_block) {r, g, b} = 24'hff_ff_ff;
    else begin
      unique case (bar)
        3'd0: {r, g, b} = 24'hff_00_00;   // red
        3'd1: {r, g, b} = 24'h00_ff_00;   // green
        3'd2: {r, g, b} = 24'h00_00_ff;   // blue
        3'd3: {r, g, b} = 24'h00_ff_ff;   // cyan
        3'd4: {r, g, b} = 24'hff_00_ff;   // magenta
        3'd5: {r, g, b} = 24'hff_ff_00;   // yellow
        3'd6: {r, g, b} = 24'hff_ff_ff;   // white
        3'd7: {r, g, b} = 24'h20_20_20;   // near-black, not black: a dead
                                          // output and this bar must differ
      endcase
    end
  end

  // ce_pix is unused by the combinational pattern; named so lint does not warn
  // and so the port stays for a future pipelined version.
  logic _unused;
  assign _unused = ce_pix;

endmodule
