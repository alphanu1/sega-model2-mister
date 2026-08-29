# Core-specific timing constraints.
#
# THE GUARD BELOW IS THE POINT OF THIS FILE.
#
# sys/sys_top.sdc groups the core's PLL outputs by matching a hierarchy PATH:
#
#   -group [get_clocks { *|pll|pll_inst|altera_pll_i|*[*].*|divclk}]
#
# An empty `get_clocks` makes `set_clock_groups` a silent no-op. So a PLL whose
# instance path does not match that pattern is not constrained at all, the core
# clocks get timed against the HDMI and audio PLLs, and the build reports
# SUCCESS and emits an .rbf while missing setup by tens of nanoseconds.
#
# docs/mister-integration.md has warned about this since before this core
# existed, quoting -87 ns. It happened here anyway, at -36.5 ns, because the
# first `rtl/pll/pll.v` instantiated `altera_pll` directly inside `pll` and so
# had no `pll_inst` level -- functionally identical, constraint-wise fatal.
#
# A warning in a document did not prevent it. This does: the build now FAILS
# rather than passing vacuously.

set core_clks [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|*[*].*|divclk}]
if {[llength $core_clks] == 0} {
    # CRITICAL WARNING, NOT ERROR, AND THAT DISTINCTION COST A BUILD.
    #
    # `post_message -type error` inside an SDC makes read_sdc FAIL, and a failed
    # read_sdc means the design is fitted with NO CONSTRAINTS AT ALL. What
    # Quartus then reports is "Can't fit design in device" -- a resource message,
    # at 46% logic -- with the actual cause three lines earlier in another
    # report. The guard meant to prevent a vacuous pass produced a misleading
    # failure instead.
    #
    # `make release` enforces it against the finished STA report. Here it only
    # has to be VISIBLE.
    post_message -type critical_warning \
      "Model2.sdc: no core PLL clocks matched *|pll|pll_inst|altera_pll_i|*. \
       The PLL hierarchy does not match sys_top.sdc, so its clock groups are a \
       silent no-op and this build is NOT timed. See rtl/pll/pll.v."
}

# THE MEMORY CLOCK AND THE CORE CLOCK MUST BE TIMED AGAINST EACH OTHER.
#
# general[0] is 96 MHz (m2_sdram), general[1] is 48 MHz (clk_sys, everything
# else) and general[4] is the 96 MHz SDRAM_CLK pin at 180 degrees. All three come
# from one 960 MHz VCO at exact integer divides, so their edges are aligned and
# m2_sdram_x2 is an ADAPTER rather than a clock-domain crossing: it relies on
# every slow signal being stable across two fast cycles, which is a timed
# relationship and not an asynchronous one.
#
# THIS FILE USED TO CUT THEM APART. That was right when the three outputs were
# unrelated by construction and nothing crossed between them. Leaving it that
# way now would stop the fitter timing the one crossing in the design that
# actually has to be timed, and the paths through the adapter would simply not
# be analysed -- a build that reports success and is not constrained where it
# matters, which is the exact failure this file exists to prevent one level up.
#
# The video and i960 domains stay cut. Those crossings are genuine and handled:
# m2_cpu_bridge carries the i960 across with a request/acknowledge handshake
# (study R32, R34), and the tilemap is read through a dual-port memory.
# general[2] -- the old 32 MHz video clock -- IS GONE, and its group with it.
# The renderer, timing generator and overlay all moved onto clk_sys with a
# one-in-three enable (48/3 = 16 MHz, the exact old pixel rate), so that PLL
# output has no consumer and the fitter drops it. Leaving a clock group that
# names a clock which no longer exists is not a warning: it gave
#   Internal Error: Sub-system: DTM, File: dtm_node.cpp, Line: 772, node != 0
# in FITTER PLACEMENT PREPARATION -- three builds died on it, each looking like
# a different problem, because the crash moves as other settings change.
set_clock_groups -asynchronous \
  -group [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|general[0].*|divclk \
                              *|pll|pll_inst|altera_pll_i|general[1].*|divclk \
                              *|pll|pll_inst|altera_pll_i|general[4].*|divclk}] \
  -group [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|general[3].*|divclk}]

# FIVE OUTPUTS NOW, AND THE COUNT IS CHECKED. The Kaneko16 core gave three
# outputs identical settings -- same frequency, same phase, same duty -- and the
# IP responded by giving all three ONE output counter: the whole core collapsed
# into a single clock domain, one clock in the timing netlist, Fmax 54.74 MHz.
# general[0] and general[4] here are both 96 MHz and differ only in phase, which
# is precisely that case, so a build that quietly produced fewer than five
# distinct clocks would look like a timing regression with no cause.
# THE COUNT IS NOT CHECKED HERE. During the fitter's read_sdc the derived PLL
# clocks are not all present yet -- this counted 1 on a build whose PLL had been
# elaborated with all five, confirmed in the synthesis log -- so a count taken at
# this point reports a state that is not final. `make release` checks it against
# the finished STA report instead.


# ---- THE CHARACTER-FETCH CROSSING, CONSTRAINED (third time; the story is the
# point -- study R57/R58)
#
# First added because the clk_vid/clk_sys crossing in m2_char_cdc is physically
# unbounded: the clock groups above cut the domains, right for analysis, and
# the fitter is left free to route the crossing arbitrarily. The build carrying
# them failed to boot -- and that was NOT these constraints being wrong. The
# SDRAM interface was unconstrained, so ANY placement shift could silently
# destroy the memory, and this one did. With the interface now constrained and
# the other killer edit re-applied and absorbed (R58), these return under the
# same proof protocol: build, boot, row 20 unchanged.
#
# set_net_delay applies between asynchronous clock groups where set_max_delay
# does not; set_max_skew keeps each synchroniser's bits together. Collections
# guarded: an empty match is a silent no-op, the trap this file exists for.
set cdc_regs [get_registers -nowarn {*u_char_cdc|*}]
set vid_regs [get_registers -nowarn {*u_tilemap|*}]

if {[llength $cdc_regs] == 0} {
    post_message -type critical_warning \
      "Model2.sdc: no m2_char_cdc registers matched -- the character-fetch \
       crossing between clk_vid and clk_sys is UNCONSTRAINED. See study R49."
} else {
    set_net_delay -max 5 -from $cdc_regs -to $cdc_regs
    set_max_skew -to [get_registers -nowarn {*u_char_cdc|req_sync[*]}]  2
    set_max_skew -to [get_registers -nowarn {*u_char_cdc|done_sync[*]}] 2
    if {[llength $vid_regs] > 0} {
        set_net_delay -max 5 -from $cdc_regs -to $vid_regs
        set_net_delay -max 5 -from $vid_regs -to $cdc_regs
    }
}


# ============================================================================
# THE SDRAM INTERFACE, WHICH HAD NO TIMING CONSTRAINTS AT ALL (study R57)
# ============================================================================
#
# WHAT WAS MISSING, AND WHY IT MATTERED. The 96 MHz clock definition above
# constrains paths INSIDE the chip -- that is what "timing closed at +2.1 ns"
# has always meant. Nothing described the round trip to the memory: not when
# SDRAM_CLK arrives at the device, not when the device drives data back, not
# what setup and hold it needs. So the fitter placed the clock and data paths
# for that interface however suited whatever was nearby, TimeQuest reported
# success because it had nothing to check, and whether the core could read its
# memory was decided by where things landed.
#
# It is not a theoretical risk. TWO individually correct changes each stopped
# the machine booting -- no SEGA handshake, black screen, row 20 reading
# cal_mask = 000000, no capture depth passing at all. Reverting the first did
# not help; removing the second reproduced the known-good core BYTE-IDENTICALLY.
# The fit is deterministic and neither change was wrong. What they shared was
# moving placement.
#
# WHY THE FRAMEWORK DOES NOT SUPPLY THIS. sys/ ships no memory controller at
# all -- there is no sdram.v to inherit. Cores using the community's standard
# one get a clock and phase that thousands of installs have proven, so the
# interface works by convention and nobody writes it down. m2_sdram at 96 MHz
# with a 180-degree SDRAM_CLK is outside that, and must state its own.
#
# WHY IT WENT UNNOTICED. The boot self-test calibrates the capture depth at
# runtime (R47) and picks a depth that works. That is good engineering and it
# masked this for the life of the project: as long as ONE depth works the
# interface looks healthy. R46 recorded "the window is one depth wide" as a
# curiosity worth watching rather than as evidence nothing held it in place.
#
# THE NUMBERS. MiSTer's SDRAM modules are Winbond W9825G6KH-class parts rated
# well past this clock. Following the established MiSTer recipe
# (retroramblings.net/?p=515):
#   input  max = tAC 5.4 ns + ~1.0 ns PCB   = 6.4
#   input  min = conservative tOH + PCB     = 1.0
#   output max = device tSU                 = 1.5
#   output min = -(device tH)                = -0.8
#
# EXPECT THIS TO FAIL TIMING THE FIRST TIME. That is the point: a violation
# that exists right now and has never been visible.

# SYNTHESIS MUST NOT SEE THIS BLOCK. Quartus 17.0's quartus_map also reads the
# SDC (for timing-driven synthesis), and evaluating these port constraints there
# CRASHES it -- Internal Error, mast_mux_add.cpp:684, reproduced twice, once on
# a clean db, on RTL byte-identical to a build that synthesised fine. Only the
# fitter and TimeQuest need I/O constraints, so the block is fenced to them.
set sdc_exe ""
catch { set sdc_exe $::quartus(nameofexecutable) }
if {[string equal $sdc_exe "quartus_map"]} {
    # Deliberately constrained nowhere in synthesis; the fitter enforces it.
} else {

set sdram_clk_src [get_pins -nowarn {*|pll|pll_inst|altera_pll_i|general[4].*|divclk}]
set sdram_clk_prt [get_ports -nowarn {SDRAM_CLK}]

if {[llength $sdram_clk_src] == 0 || [llength $sdram_clk_prt] == 0} {
    # AN EMPTY COLLECTION IS A SILENT NO-OP, which is the failure this whole
    # file exists to prevent. Say so loudly rather than constraining nothing.
    post_message -type critical_warning \
      "Model2.sdc: SDRAM_CLK generated clock NOT created -- source pins \
       [llength $sdram_clk_src], ports [llength $sdram_clk_prt]. The SDRAM \
       interface is UNCONSTRAINED and this build's memory timing is luck. \
       See study R57."
} else {
    # general[4] is the 96 MHz output at 180 degrees that drives the pin.
    create_generated_clock -name SDRAM_CLK_pin -source $sdram_clk_src $sdram_clk_prt

    set_input_delay -clock SDRAM_CLK_pin -max 6.4 [get_ports {SDRAM_DQ[*]}]
    set_input_delay -clock SDRAM_CLK_pin -min 1.0 [get_ports {SDRAM_DQ[*]}]

    set sdram_out [get_ports -nowarn {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] \
                                      SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE \
                                      SDRAM_DQML SDRAM_DQMH SDRAM_CKE}]
    set_output_delay -clock SDRAM_CLK_pin -max  1.5 $sdram_out
    set_output_delay -clock SDRAM_CLK_pin -min -0.8 $sdram_out

    # THE READ PATH IS MULTI-CYCLE BY DESIGN. m2_sdram does not capture read
    # data on the edge after the SDRAM drives it -- it captures CL+N cycles
    # later, and the boot self-test MEASURES N (study R47; the board picks
    # CL+2). Without this exception TimeQuest assumes next-edge capture and
    # reported -13.77 ns on the 96 MHz domain, which describes a design this is
    # not. Setup moves to the second edge; hold checks stay on the default edge
    # (-end 1), matching the recipe this whole block follows.
    # -end 3 for setup is legitimate ONLY because of the calibration: dq_r
    # free-runs and the depth sweep picks which cycle's capture to trust, so
    # any consistent integer-cycle arrival works. What the constraint pair must
    # actually guarantee is that the arrival is CONSISTENT -- the data eye plus
    # routing variation fits inside one period -- and a setup/hold pair one
    # edge apart states exactly that. Without the calibration this would be
    # constraining the test to pass (R38); with it, it is the design's truth.
    set_multicycle_path -setup -end 3 \
      -from [get_clocks SDRAM_CLK_pin] \
      -to   [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}]
    set_multicycle_path -hold -end 2 \
      -from [get_clocks SDRAM_CLK_pin] \
      -to   [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}]

    # Outputs launch on general[0] at 0 degrees and the pin clock is the same
    # 96 MHz at 180; the intended sampling edge is the one AFTER the launch-
    # adjacent edge -- the controller has always worked that way on hardware
    # (the calibration's measured CL+2 bakes it in). Same setup/hold-pair
    # reasoning as the reads.
    set_multicycle_path -setup -end 2 \
      -from [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}] \
      -to   [get_clocks SDRAM_CLK_pin]
    set_multicycle_path -hold -end 1 \
      -from [get_clocks {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}] \
      -to   [get_clocks SDRAM_CLK_pin]
}

}
