// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// A LINT-ONLY BLACK BOX FOR THE VENDOR PLL. It is never synthesised and never
// simulated -- Quartus builds the real IP from rtl/pll/pll.qip.
//
// It exists because `verilator --lint-only` STOPS at the first missing module,
// and stopping costs more than the missing module does. Verilator's whole-design
// checks -- UNDRIVEN chief among them -- run only after elaboration completes,
// so a design that cannot elaborate reports its parse-time warnings and silently
// skips everything else. `lint_top` looked clean for exactly that reason while
// three signals feeding the SDRAM arbiter had nothing driving them at all.
//
// The parameter list has to be complete: Verilog rejects a named parameter the
// module does not declare, so every one pll.v passes is named here even though
// none of them mean anything to a stub.
module altera_pll #(
  parameter fractional_vco_multiplier = "false",
  parameter reference_clock_frequency = "50.0 MHz",
  parameter operation_mode            = "direct",
  parameter number_of_clocks          = 5,
  parameter output_clock_frequency0   = "",
  parameter phase_shift0              = "0 ps",
  parameter duty_cycle0               = 50,
  parameter output_clock_frequency1   = "",
  parameter phase_shift1              = "0 ps",
  parameter duty_cycle1               = 50,
  parameter output_clock_frequency2   = "",
  parameter phase_shift2              = "0 ps",
  parameter duty_cycle2               = 50,
  parameter output_clock_frequency3   = "",
  parameter phase_shift3              = "0 ps",
  parameter duty_cycle3               = 50,
  parameter output_clock_frequency4   = "",
  parameter phase_shift4              = "0 ps",
  parameter duty_cycle4               = 50,
  parameter pll_type                  = "General",
  parameter pll_subtype               = "General"
) (
  input  wire       rst,
  input  wire       refclk,
  input  wire       fbclk,
  output wire [4:0] outclk,
  output wire       fboutclk,
  output wire       locked
);
  // Enough behaviour that nothing downstream reads as undriven. The frequencies
  // are a lie and that is fine -- no timing question is ever asked of this file.
  assign outclk   = {5{refclk}};
  assign fboutclk = refclk;
  assign locked   = ~rst;
endmodule
