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
# THE PERIOD IS A PARAMETER NOW, AND 40 ns MADE THE Fmax FIGURE MEANINGLESS.
#
# At 40 ns m2_raster_fill reports +18.4 ns of slack, so the fitter clears the
# constraint on the first try and stops. The Fmax that falls out is what
# effort-free placement achieves -- 46.36 MHz -- while the SAME RTL makes
# 19.4 ns inside the full design, where the fitter is working against 20 ns.
# Reading that number as capability is reading how hard the fitter tried.
#
# `make quartus MOD=x SPIKE_PERIOD=16.667` constrains at the real target so the
# slack means something. ALM was never affected by this -- area does not depend
# on timing pressure -- so the area numbers taken at 40 ns still stand.
if {[llength [get_ports -nowarn {clk}]] > 0} {
    set per 40.000
    if {[info exists ::env(SPIKE_PERIOD)]} { set per $::env(SPIKE_PERIOD) }
    create_clock -name clk -period $per [get_ports {clk}]
    derive_clock_uncertainty
    post_message -type info "spike.sdc: clk constrained at $per ns"
}

# Cut every I/O path. Everything is virtual-pinned, so input and output delays
# are meaningless here; leaving them in makes the worst path an I/O path and
# hides the register-to-register number this spike exists to measure.
set_false_path -from [all_inputs]  -to [all_registers]
set_false_path -from [all_registers] -to [all_outputs]
set_false_path -from [all_inputs]  -to [all_outputs]
