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
// Palette entry to RGB888, from model1_paletteram_w in model1_v.cpp.
//
//   r = pal5bit((v >> 0)  & 0x1f)
//   g = pal5bit((v >> 5)  & 0x1f)
//   b = pal5bit((v >> 10) & 0x1f)
//   if (!BIT(v, 15)) { r >>= 1; g >>= 1; b >>= 1; }
//
// BIT 15 IS INTENSITY, NOT PADDING
//
// MODEL 2'S PALETTE IS NOT A 5-TO-8 BIT EXPANSION, and this module used to
// assume it was. It was Model 1's `m1_palette.sv` copied across unchanged, and
// Model 1's palette path is genuinely different from Model 2's.
//
// model2.cpp palette_w:
//
//   u8 r = m_colorxlat[(0x0080 >> 1) + (((palcolor >> 0) & 0x1f) << 8)];
//   u8 g = m_colorxlat[(0x4080 >> 1) + (((palcolor >> 5) & 0x1f) << 8)];
//   u8 b = m_colorxlat[(0x8080 >> 1) + (((palcolor >> 10) & 0x1f) << 8)];
//   r = m_gamma_table[r]; g = ...; b = ...;
//
// Each 5-bit channel indexes a COLOUR TRANSLATION RAM the game writes at
// 0x01810000, and the result then goes through a gamma curve. The table is
// indexed at a stride of 256 words, so only 96 of its 24,576 entries are ever
// read -- 32 per channel -- which is why this costs a 96-byte table and not
// 48 KB.
//
// Measured against Daytona's attract screen, the difference is real and it is
// not rounding:
//
//   5-bit   colorxlat   gamma   pal5bit (what this did)
//     2   ->    81   ->   22        16
//     9   ->   123   ->   78        74
//    23   ->   207   ->  190       189
//    31   ->   255   ->  255       255
//
// Only the endpoints agreed, which is exactly why it survived being looked at
// on hardware: the picture is right, every fill colour is slightly wrong, and
// nothing about that is visible without a pixel comparison.
//
// BIT 15 IS NOT AN INTENSITY BIT HERE. That behaviour came over with the Model 1
// module and its comment. model2.cpp reads bits 0-14 and ignores bit 15, so the
// halving is removed. If a Model 2 game is ever found that needs it, the
// evidence for it must come from model2.cpp or from silicon, not from Model 1.
//
// THE GAMMA IS MAME'S, NOT THE HARDWARE'S. Its own comment says so:
//
//   // convert color space; this works OK for most games
//   // real cabinets probably have their monitors calibrated depending on the game
//   raw_value = max((i - 64) * 255 / 191, 0)
//
// So it is display compensation, not silicon. It is applied by default because
// MAME is the oracle we compare against and matching it is what makes a pixel
// comparison meaningful, and it is a parameter so a hardware A/B can turn it
// off without editing anything.

`timescale 1ns/1ps

module m2_palette #(
  parameter bit GAMMA = 1
) (
  // Bit 15 is deliberately unread -- see the note above. Silenced rather
  // than trimmed to 15 bits, because the palette entry IS 16 bits and a
  // narrowed port would hide that a bit is being ignored on purpose.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [15:0] entry,
  /* verilator lint_on UNUSEDSIGNAL */

  // The three 5-bit channel indices, out to the translation table...
  output logic [4:0]  x_r5,
  output logic [4:0]  x_g5,
  output logic [4:0]  x_b5,
  // ...and the translated values back.
  input  logic [7:0]  x_r,
  input  logic [7:0]  x_g,
  input  logic [7:0]  x_b,

  output logic [7:0]  r,
  output logic [7:0]  g,
  output logic [7:0]  b
);

  assign x_r5 = entry[4:0];
  assign x_g5 = entry[9:5];
  assign x_b5 = entry[14:10];

  // gamma: max((i - 64) * 255 / 191, 0), truncated. 255/191 in 16.16 is 87496,
  // which reproduces MAME's table exactly at every point that matters -- 255
  // included, where a coarser multiplier gives 254.
  function automatic logic [7:0] gam(input logic [7:0] v);
    // Only [24:16] is read -- the fractional half of the 16.16 product is
    // the rounding that MAME's (u8) cast discards, so discarding it here is
    // the behaviour, not an oversight.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [24:0] p;
    /* verilator lint_on UNUSEDSIGNAL */
    begin
      if (v <= 8'd64) gam = 8'd0;
      else begin
        p = ({17'd0, (v - 8'd64)} * 25'd87496);
        // The bits above 7 of the shifted product ARE meaningful: the curve
        // reaches exactly 255 at input 255, so a truncation to eight bits is a
        // wrap, not a rounding. Saturate.
        gam = (p[24:16] > 9'd255) ? 8'd255 : p[23:16];
      end
    end
  endfunction

  assign r = GAMMA ? gam(x_r) : x_r;
  assign g = GAMMA ? gam(x_g) : x_g;
  assign b = GAMMA ? gam(x_b) : x_b;

endmodule
