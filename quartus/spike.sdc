# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# P1 spike timing constraint.
#
# 25 MHz is the i960KB part clock. The gate in docs/p1-i960-spike.md §7 asks
# for >90 MHz, so this constraint is deliberately loose: it exists to make STA
# report a meaningful slack number against a real clock, not to be the target.
# Read the Fmax figure from the STA report, not the pass/fail on this period.

# Guarded. Four of the five P1 modules are purely combinational and have no clk
# port at all, and an unguarded create_clock on an empty collection aborts the
# whole SDC — taking the I/O cuts below with it and silently changing what is
# being measured.
if {[llength [get_ports -nowarn {clk}]] > 0} {
    create_clock -name clk -period 40.000 [get_ports {clk}]
    derive_clock_uncertainty
}

# Cut every I/O path. Everything is virtual-pinned, so input and output delays
# are meaningless here; leaving them in makes the worst path an I/O path and
# hides the register-to-register number this spike exists to measure.
set_false_path -from [all_inputs]  -to [all_registers]
set_false_path -from [all_registers] -to [all_outputs]
set_false_path -from [all_inputs]  -to [all_outputs]
