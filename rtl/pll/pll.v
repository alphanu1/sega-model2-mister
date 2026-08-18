// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// THE MODULE MUST BE NAMED `pll`. MiSTer's `sys/sys_top.sdc` writes its
// clock-group constraints against that name. Rename it and the constraints match
// nothing, timing analysis passes vacuously, and the build fails on hardware
// with no failing report to point at. This is a standing rule in
// docs/mister-integration.md, paid for once already.
//
// Written by hand rather than generated, because Model 1's `pll_0002.v` shows
// the IP tool emits a plain parameterised instantiation of `altera_pll` rather
// than a Qsys black box. The parameter set below is that instantiation's, with
// this core's frequencies. `rtl/pll/pll.qip` carries the instance assignments
// the generator would have written.
//
// THE TWO-LEVEL HIERARCHY IS LOAD-BEARING AND MUST NOT BE FLATTENED.
// `sys/sys_top.sdc` line 14 reads:
//
//     -group [get_clocks { *|pll|pll_inst|altera_pll_i|*[*].*|divclk}]
//
// It matches on the INSTANCE PATH, so the inner instance must be named
// `pll_inst` and the `altera_pll` inside it `altera_pll_i`. The first version of
// this file put `altera_pll` directly inside `pll`, which is functionally
// identical and constraint-wise fatal: the group matched nothing, the core
// clocks were left related to the HDMI and audio PLLs, and the build reported
// **-36.5 ns** of setup slack on a 31.25 ns clock while still emitting an .rbf.
//
// That is the failure mode CLAUDE.md and docs/mister-integration.md both warn
// about -- "a passing build fails on hardware" -- reached by a route neither
// anticipated. The rule is not only about the module NAME.
//
// FREQUENCIES, AND WHY THESE
//
// MAME declares Model 2's pixel clock as `32_MHz_XTAL/2` -- so 16 MHz is
// EXACTLY 32 MHz halved. Taking 32 MHz from the PLL and dividing by two with a
// clock enable is exact: no fractional division, no accumulated phase error,
// and a frame rate of 16e6/(656*424) = 57.52 Hz that matches the reference
// rather than approximating it.
//
//   outclk_0   80 MHz   SDRAM
//   outclk_1   32 MHz   video domain; ce_pix = /2 gives exactly 16 MHz
//   outclk_2   25 MHz   i960. The real part's rate; ours fits at 26.84 MHz
//                       (study §5.5), so this is the reference speed and not a
//                       limit we are pushing against.

`timescale 1 ps / 1 ps

module pll (
    input  wire  refclk,     // 50 MHz from the board
    input  wire  rst,
    output wire  outclk_0,   // 80 MHz  SDRAM
    output wire  outclk_1,   // 32 MHz  video  (ce_pix /2 -> 16 MHz)
    output wire  outclk_2,   // 25 MHz  i960
    output wire  locked
  );

  // Instance name `pll_inst`: see the note above. Not cosmetic.
  pll_core pll_inst (
    .refclk   (refclk),
    .rst      (rst),
    .outclk_0 (outclk_0),
    .outclk_1 (outclk_1),
    .outclk_2 (outclk_2),
    .locked   (locked)
  );

endmodule

module pll_core (
    input  wire  refclk,
    input  wire  rst,
    output wire  outclk_0,
    output wire  outclk_1,
    output wire  outclk_2,
    output wire  locked
  );

  altera_pll #(
    .fractional_vco_multiplier("false"),
    .reference_clock_frequency("50.0 MHz"),
    .operation_mode("direct"),
    .number_of_clocks(3),
    .output_clock_frequency0("80.000000 MHz"),
    .phase_shift0("0 ps"),
    .duty_cycle0(50),
    .output_clock_frequency1("32.000000 MHz"),
    .phase_shift1("0 ps"),
    .duty_cycle1(50),
    .output_clock_frequency2("25.000000 MHz"),
    .phase_shift2("0 ps"),
    .duty_cycle2(50),
    .pll_type("General"),
    .pll_subtype("General")
  ) altera_pll_i (
    .rst        (rst),
    .outclk     ({outclk_2, outclk_1, outclk_0}),
    .locked     (locked),
    .fboutclk   ( ),
    .fbclk      (1'b0),
    .refclk     (refclk)
  );

endmodule
