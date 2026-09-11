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
// That is the failure mode the project rules and docs/mister-integration.md both warn
// about -- "a passing build fails on hardware" -- reached by a route neither
// anticipated. The rule is not only about the module NAME.
//
// SDRAM AT 40 MHz, DELIBERATELY AND TEMPORARILY.
//
// The board returns data that changes with the read capture phase but is never
// correct at any of the four settings. Wrong logic would fail in simulation too,
// and it does not: the controller passes 74,729 checks at 32 MB and 58,739 at
// 128 MB against the device model, and the loader-to-readback path passes as
// well. A capture window merely misplaced would be fixed by one of the phases.
//
// Neither fits, and both are consistent with MARGINAL TIMING: at 80 MHz the
// device is clocked on the inverse of the controller clock, which gives it only
// a half period of skew and no true phase shift. Halving the clock doubles every
// margin without changing a line of logic, so if the data comes back correct the
// cause is timing and the fix is a properly phase-shifted SDRAM_CLK. If it is
// still wrong, timing is exonerated and the fault is elsewhere.
//
// T_REFI follows the clock: 8192 rows in 64 ms is one refresh every 7.8125 us,
// which is 750 cycles at 96 MHz — it was 312 at 40.
//
// FREQUENCIES, AND WHY THESE
//
// MAME declares Model 2's pixel clock as `32_MHz_XTAL/2` -- so 16 MHz is
// EXACTLY 32 MHz halved. Taking 32 MHz from the PLL and dividing by two with a
// clock enable is exact: no fractional division, no accumulated phase error,
// and a frame rate of 16e6/(656*424) = 57.52 Hz that matches the reference
// rather than approximating it.
//
//   outclk_0  100 MHz   SDRAM controller, ALONE in this domain
//   outclk_1   50 MHz   clk_sys: everything else. Exact /2 of outclk_0.
//   outclk_2   32 MHz   video domain; ce_pix = /2 gives exactly 16 MHz
//   outclk_3   25 MHz   i960, an exact /2 of outclk_1
//   outclk_4  100 MHz   SDRAM_CLK pin, 180 degrees from outclk_0
//
// 96 MHz, AND WHAT IT COST. The 40 MHz above was a retreat from 80, and the
// note below diagnosed it: the device was clocked on the INVERSE of the
// controller clock, "only a half period of skew and no true phase shift", and
// said the fix was a properly phase-shifted SDRAM_CLK. outclk_4 is that fix —
// its own output counter at 180 degrees, not an inversion.
//
// THE i960 RUNS AT 25 MHz, WHICH IS THE REAL PART'S CLOCK.
//
// It was 24 for two revisions, and the reason recorded here was that "96, 32
// and 25 cannot share a PLL: they need a VCO that is a common multiple of all
// three, which is 2400 MHz, and Cyclone V tops out near 1600." That is true of
// a 96 MHz family and it is not a law. Off 96, all four fall out of a VCO of
// 800 MHz = 50 x 16:
//
//     SDRAM  800/8  = 100 MHz      core is an exact /2 of SDRAM
//     core   800/16 =  50 MHz      i960 is an exact /2 of core
//     video  800/25 =  32 MHz      unused for pixels now, see below
//     i960   800/32 =  25 MHz      the real part
//
// BOTH HALVING RELATIONSHIPS SURVIVE, and they are the two that matter.
// m2_sdram_x2 stays an ADAPTER rather than becoming a clock-domain crossing,
// and the CPU bridge keeps its SINGLE-FLOP crossing. That second one is not a
// nicety: the bridge records going from two flops to one taking S_DONE from
// 7.12 cycles per transaction to 1.14, so an i960 on its own PLL would have
// cost about six cycles a transaction to buy four per cent of clock.
//
// WHAT IT COSTS INSTEAD is the pixel enable. ce_pix was clk_sys/3, and 48/3 =
// 16 MHz exactly; 50/3 is not 16. It is a fractional 16-of-50 enable now --
// see Model2.sv. The video timing counts PIXELS, not nanoseconds, so every H
// and V position is unchanged and the frame rate is still exactly
// 16e6/(656*424) = 57.5242 Hz on average. What varies is the wall-clock
// spacing, alternating 60 and 80 ns about a uniform 62.5, into a scaler that
// latches into a line buffer and never sees the difference.
//
// Fmax headroom from the 96/48/24 build: SDRAM 116.7 against 100, core 58.5
// against 50, i960 29.1 against 25.
//
// Four per cent does not fix the speed problem -- the game runs at about a
// third of its logic rate and needs 3.4x, which is the core's cycles per
// instruction and not its clock (R100, R101). 25 MHz is here because it is what
// the hardware is.
//
// THE OUTPUTS MUST NOT ALL CARRY THE SAME SETTINGS. The Kaneko16 core had
// three at 48 MHz / 0 ps / 50% and the IP gave all three ONE output counter:
// the whole core became a single clock domain, one `pll` clock in the timing
// netlist, Fmax 54.74 MHz, with the memory controller held down to the slowest
// path among them. outclk_0 and outclk_4 are both 96 MHz here and differ only
// in phase, which is exactly the case that triggers it — check the fit report
// for five distinct clocks, not one.
//
// 48 MHz IS AN EXACT /2 OF 96 AND PHASE-ALIGNED, which is what makes
// m2_sdram_x2 an adapter rather than a clock-domain crossing: every slow edge
// coincides with a fast edge, every slow signal is stable across two fast
// cycles, and there is no metastability to synchronise away. The SDC must TIME
// the two against each other rather than cut them apart.
//                       (study §5.5), so this is the reference speed and not a
//                       limit we are pushing against.

`timescale 1 ps / 1 ps

module pll (
    input  wire  refclk,     // 50 MHz from the board
    input  wire  rst,
    output wire  outclk_0,   // 100 MHz  SDRAM controller
    output wire  outclk_1,   //  50 MHz  clk_sys, exact /2 of outclk_0
    output wire  outclk_2,   // 32 MHz  video  (ce_pix /2 -> 16 MHz)
    output wire  outclk_3,   //  25 MHz  i960
    output wire  outclk_4,   // 100 MHz  SDRAM_CLK pin, 180 deg from outclk_0
    output wire  locked
  );

  // Instance name `pll_inst`: see the note above. Not cosmetic.
  pll_core pll_inst (
    .refclk   (refclk),
    .rst      (rst),
    .outclk_0 (outclk_0),
    .outclk_1 (outclk_1),
    .outclk_2 (outclk_2),
    .outclk_3 (outclk_3),
    .outclk_4 (outclk_4),
    .locked   (locked)
  );

endmodule

module pll_core (
    input  wire  refclk,
    input  wire  rst,
    output wire  outclk_0,   // 100 MHz  SDRAM controller
    output wire  outclk_1,   //  50 MHz  clk_sys
    output wire  outclk_2,   // 32 MHz  video
    output wire  outclk_3,   //  25 MHz  i960
    output wire  outclk_4,   // 100 MHz  SDRAM_CLK pin, 180 deg
    output wire  locked
  );

  altera_pll #(
    .fractional_vco_multiplier("false"),
    .reference_clock_frequency("50.0 MHz"),
    .operation_mode("direct"),
    .number_of_clocks(5),
    .output_clock_frequency0("100.000000 MHz"),
    .phase_shift0("0 ps"),
    .duty_cycle0(50),
    .output_clock_frequency1("50.000000 MHz"),
    .phase_shift1("0 ps"),
    .duty_cycle1(50),
    .output_clock_frequency2("32.000000 MHz"),
    .phase_shift2("0 ps"),
    .duty_cycle2(50),
    .output_clock_frequency3("25.000000 MHz"),
    .phase_shift3("0 ps"),
    .duty_cycle3(50),
    // 180 degrees at 100 MHz is half a 10 ns period: 5000 ps exactly. It was
    // 5208 for 96 MHz. Stated in ps because that is the unit the IP takes.
    .output_clock_frequency4("100.000000 MHz"),
    .phase_shift4("5000 ps"),
    .duty_cycle4(50),
    .pll_type("General"),
    .pll_subtype("General")
  ) altera_pll_i (
    .rst        (rst),
    .outclk     ({outclk_4, outclk_3, outclk_2, outclk_1, outclk_0}),
    .locked     (locked),
    .fboutclk   ( ),
    .fbclk      (1'b0),
    .refclk     (refclk)
  );

endmodule
