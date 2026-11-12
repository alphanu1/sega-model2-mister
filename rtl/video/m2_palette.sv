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

// R995: THE CURVE IS APPLIED AS THE TABLE IS WRITTEN, NOT AS IT IS READ.
// The colour on screen is gam(xlat[entry channel], gsel): a function of a
// 5-bit index and of gsel. Each entry holds {mild curve, MAME's curve, the value written}, all
// three worked out from the written byte on the write side, and the read
// selects one by gsel. The same colour for every gsel at every moment (gsel
// is sampled where it was, the cycle after the table's registered read), and
// the read side is an MLAB's output register and a 3:1 select. s1773 at
// 100 MHz: the read side's subtract, multiply and saturate missed by 0.072 ns
// (xlat_r ... dataout_reg[2] -> m2_video|pr_q[3]).

`timescale 1ns/1ps

module m2_palette #(
  parameter bit GAMMA = 1
) (
  input  logic        clk,        // the read side: m2_video's clock

  // Bit 15 is deliberately unread -- see the note above. Silenced rather
  // than trimmed to 15 bits, because the palette entry IS 16 bits and a
  // narrowed port would hide that a bit is being ignored on purpose.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [15:0] entry,
  /* verilator lint_on UNUSEDSIGNAL */

  // The colour translation table's write port, on its writers' clock (R564).
  // Layout: {channel, value}, channel 0 = R, 1 = G, 2 = B; 3 writes nothing.
  input  logic        xlat_clk,
  input  logic        xlat_we,
  input  logic  [6:0] xlat_addr,
  input  logic  [7:0] xlat_din,

  output logic [7:0]  r,
  output logic [7:0]  g,
  output logic [7:0]  b,
  input  logic [1:0]  gsel       // R630: 0 MAME, 1 mild, 2/3 off (quasi-static)
);

  // gamma: max((i - bias) * 255 / (255 - bias), 0), truncated. R630: THE
  // CURVE IS AN OSD CHOICE (gsel) -- 0 MAME's (bias 64, 255/191 as 16.16 =
  // 87496), 1 milder (bias 32, 74941), 2/3 none. Both constants reproduce the
  // integer formula exactly at all 256 inputs (checked exhaustively), 255
  // included, where a coarser multiplier gives 254.
  function automatic logic [7:0] gam(input logic [7:0] v, input logic [1:0] sel);
    // Only [24:16] is read -- the fractional half of the 16.16 product is
    // the rounding that MAME's (u8) cast discards, so discarding it here is
    // the behaviour, not an oversight.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [24:0] p;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [7:0]  bias;
    begin
      bias = sel[0] ? 8'd32 : 8'd64;
      if (sel[1]) gam = v;
      else if (v <= bias) gam = 8'd0;
      else begin
        p = ({17'd0, (v - bias)} * (sel[0] ? 25'd74941 : 25'd87496));
        // The bits above 7 of the shifted product ARE meaningful: the curve
        // reaches exactly 255 at input 255, so a truncation to eight bits is a
        // wrap, not a rounding. Saturate.
        gam = (p[24:16] > 9'd255) ? 8'd255 : p[23:16];
      end
    end
  endfunction
  // R995: an entry as stored -- {mild, MAME's, the value}
  function automatic logic [23:0] ent(input logic [7:0] v);
    ent = {gam(v, 2'd1), gam(v, 2'd0), v};
  endfunction
  // ...and as read: the curve gsel names (GAMMA 0: the value)
  function automatic logic [7:0] pick(input logic [23:0] e, input logic [1:0] sel);
    pick = (!GAMMA || sel[1]) ? e[7:0] : sel[0] ? e[23:16] : e[15:8];
  endfunction

  // COLOUR TRANSLATION TABLE. It POWERS UP holding pal5bit, the expansion this
  // module used before the translation existed. That is deliberate: a core
  // that has not loaded the table renders exactly as it did, so adding this
  // cannot regress the picture on hardware, and loading it can only make the
  // colours more correct.
  //
  // R907: ONE 32-ENTRY ARRAY PER CHANNEL, TAGGED MLAB. As a single 96-entry
  // array read at three addresses at once it was never a RAM at all: the map
  // put it in 768 flip-flops with three 32:1 read muxes, while R564's notes
  // (and this comment's own history) took it for an MLAB. One array per read
  // port is the shape an MLAB can be: written on xlat_clk, read on clk into
  // the same registers as before. Addresses 96-127 (channel 3) were outside
  // the old array and wrote nothing; they write nothing here either.
  // R995: 24 bits an entry (two MLABs a channel, was one), so the curve is
  // looked up rather than computed. One entry is worked out a write, shared
  // by the three channels.
  (* ramstyle = "MLAB" *) logic [23:0] xlat_r [32];
  (* ramstyle = "MLAB" *) logic [23:0] xlat_g [32];
  (* ramstyle = "MLAB" *) logic [23:0] xlat_b [32];
  initial begin
    for (int i = 0; i < 32; i++) begin
      xlat_r[i] = ent({i[4:0], i[4:2]});      // pal5bit
      xlat_g[i] = ent({i[4:0], i[4:2]});
      xlat_b[i] = ent({i[4:0], i[4:2]});
    end
  end
  wire [23:0] xlat_e = ent(xlat_din);
  always_ff @(posedge xlat_clk) begin
    if (xlat_we && xlat_addr[6:5] == 2'd0) xlat_r[xlat_addr[4:0]] <= xlat_e;
    if (xlat_we && xlat_addr[6:5] == 2'd1) xlat_g[xlat_addr[4:0]] <= xlat_e;
    if (xlat_we && xlat_addr[6:5] == 2'd2) xlat_b[xlat_addr[4:0]] <= xlat_e;
  end

  // R582: the xlat lookup registered before the gamma curve (s312: pal_data_q
  // -> xlat -> gamma -> pb_q, -0.278 ns at 100 MHz). See m2_video's vid_r for
  // where the cycle comes from. R995: the same register, now 24 bits.
  logic [23:0] x_r, x_g, x_b;
  always_ff @(posedge clk) begin
    x_r <= xlat_r[entry[4:0]];
    x_g <= xlat_g[entry[9:5]];
    x_b <= xlat_b[entry[14:10]];
  end

  assign r = pick(x_r, gsel);
  assign g = pick(x_g, gsel);
  assign b = pick(x_b, gsel);

endmodule
