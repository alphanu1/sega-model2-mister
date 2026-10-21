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
// Region table from MAME's model2.cpp — model2_base_mem, model2_tgp_mem and
// model2a_crx_mem (BSD-3-Clause). See THIRD_PARTY.md and
// docs/p1-i960-spike.md §5, which carries the full map.
//
// ---------------------------------------------------------------------------
//
// Which Model 2A regions are burst-capable.
//
// This exists because of one line in the reference's multi-word load:
//
//   if (pack.second & BURST) t1 += 4;
//
// The address advances between words ONLY in a burst region. In a non-burst
// region every word of an `ldl`, `ldt` or `ldq` is fetched from the SAME
// address — which is exactly how the coprocessor FIFO at 0x00884000 is drained,
// and the reference says so: "Model 2 FIFO reads with ldl, ldt, ldq".
//
// Getting this wrong does not fail loudly. A burst-flagged FIFO returns four
// copies of the head word instead of four successive words, and the geometry
// stream quietly fills with repeats.
//
// Regions not listed are non-burst. That is the safe default here: treating a
// burst region as non-burst costs cycles, while treating a FIFO as burst
// corrupts data.

module i960_memmap #(
  // R924: the 2C-CRX map (Model2.sv M2_2C): texture RAM 0x11000000-0x113fffff
  // and luma RAM 0x11400000-0x1140ffff are BURST in MAME's model2c_crx_mem.
  // Left out, every stq / stl into 2C texture RAM wrote its words to one
  // address -- R905's fault again, on the board as banded textures (s1303).
  parameter bit C2 = 1'b0
) (
  input  logic [31:0] addr,
  output logic        is_burst
);

  logic [31:0] a;
  assign a = addr;

  always_comb begin
    is_burst = 1'b0;

    // Mirrors are folded in where the reference declares them, because the
    // burst property follows the region rather than the primary address.
    if      (a <  32'h0020_0000)                            is_burst = 1'b1; // program ROM
    else if (a >= 32'h0020_0000 && a <  32'h0024_0000)      is_burst = 1'b1; // 2A-CRX RAM
    else if (a >= 32'h0050_0000 && a <  32'h0060_0000)      is_burst = 1'b1; // work RAM
    else if (a >= 32'h0080_4000 && a <  32'h0080_8000)      is_burst = 1'b1; // geo program
    else if (a >= 32'h0088_0000 && a <  32'h0088_4000)      is_burst = 1'b1; // copro function port
    // 0x00884000-0x00887fff is the copro FIFO and is deliberately NOT burst.
    else if (a >= 32'h0090_0000 && a <  32'h0098_0000)      is_burst = 1'b1; // buffer RAM + mirror
    else if (a >= 32'h0100_0000 && a <  32'h0101_0000)      is_burst = 1'b1; // tilemap
    else if (a >= 32'h0111_0000 && a <  32'h0112_0000)      is_burst = 1'b1; // tilemap mirror
    else if (a >= 32'h0102_0000 && a <  32'h0102_0004)      is_burst = 1'b1; // ABSEL
    else if (a >= 32'h0108_0000 && a <  32'h0110_0000)      is_burst = 1'b1; // char RAM
    else if (a >= 32'h0118_0000 && a <  32'h0120_0000)      is_burst = 1'b1; // char RAM mirror
    else if (a >= 32'h0180_0000 && a <  32'h0180_4000)      is_burst = 1'b1; // palette
    else if (a >= 32'h0181_0000 && a <  32'h0181_c000)      is_burst = 1'b1; // colour translate
    else if (a >= 32'h01a0_0000 && a <  32'h01a0_4000)      is_burst = 1'b1; // m2comm share
    else if (a >= 32'h01a1_0000 && a <  32'h01a1_4000)      is_burst = 1'b1; // m2comm mirror
    else if (a >= 32'h01d0_0000 && a <  32'h01d0_4000)      is_burst = 1'b1; // backup SRAM
    else if (a >= 32'h0200_0000 && a <  32'h0400_0000)      is_burst = 1'b1; // main data ROM
    else if (a >= 32'h0600_0000 && a <  32'h0700_0000)      is_burst = 1'b1; // extra data ROM
    else if (a >= 32'h1160_0000 && a <  32'h1170_0000)      is_burst = 1'b1; // framebuffer A/B
    else if (C2 && a >= 32'h1100_0000 && a < 32'h1141_0000) is_burst = 1'b1; // R924: 2C texture + luma RAM
    // R905: TO 0x12800000. Both sheets carry .mirror(0x200000) with the BURST
    // flag (model2_tgp_mem: 0x12000000-0x121fffff and 0x12400000-0x125fffff),
    // so sheet 1's mirror 0x12600000-0x127fffff is a burst region too. It
    // ended at 0x12600000, and a multi-word store there put all its words on
    // its first address: Dynamite Cop, Dead or Alive, Sky Target and Motor
    // Raid upload sheet 1 with stq through that mirror -- three texel words
    // in four never written, the board's vertical stripes.
    else if (a >= 32'h1200_0000 && a <  32'h1280_0000)      is_burst = 1'b1; // texture RAM + mirrors
    else if (a >= 32'h1280_0000 && a <  32'h1282_0000)      is_burst = 1'b1; // luma RAM
  end

endmodule
