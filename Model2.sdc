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
# general[0] is 100 MHz (m2_sdram), general[1] is 50 MHz (clk_sys, everything
# else) and general[4] is the 100 MHz SDRAM_CLK pin at 180 degrees. All three come
# from one 800 MHz VCO at exact integer divides, so their edges are aligned and
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
# general[3] -- the i960's 25 MHz -- IS NO LONGER ASYNCHRONOUS, and that is a
# deliberate change with a measurement behind it.
#
# It comes off the SAME PLL as general[1] at an exact 2:1 ratio, so its edges
# are aligned and there was never metastability to synchronise away. m2_sdram_x2
# already makes that argument for the 100/50 pair and carries no synchroniser;
# m2_cpu_bridge simply never had it applied, and paid two flops FOUR times over
# on a four-phase handshake -- measured at 7.12 cycles per transaction in S_DONE
# against 4.42 for the SDRAM access it wrapped.
#
# With the synchronisers gone the bridge samples across 50/25 directly, so those
# paths MUST be timed rather than ignored. Every clock here comes from one PLL
# with integer dividers, so they are all related and a single group is correct.
# If this ever fails timing, the answer is to fix the path -- not to put the
# group back, which would silence the check rather than the failure.
# R460: TWO GROUPS NOW, AND THE SPLIT IS THE WHOLE POINT OF THE CLOCK CHANGE.
#
# The single group above was correct while every core clock was an integer
# divide of one 800 MHz VCO -- 100, 50, 25 -- because then m2_sdram_x2 and
# m2_cpu_bridge are ADAPTERS and their paths must be timed. Adding a 60 MHz 3D
# clock moved the VCO to 1200 and broke that for two of the four:
#
#   clk_3d   60 vs clk_sys  50   3:5    edges realign every 50 ns
#   clk_3d   60 vs clk_mem 100   3:5    closest launch-to-capture 3.333 ns
#   clk_i960 30 vs clk_sys  50   3:5    likewise
#
# Timing ~400,000 paths at 3.333 ns is not a design. So the family splits by
# which relationships are still integer:
#
#   GROUP A  general[0] 100, general[1] 50, general[4] 100@180
#            Exact 2:1. m2_sdram_x2 stays an adapter, carries no synchroniser,
#            and its paths MUST stay timed -- that is what the note above says
#            and it is still true.
#
#   R470: THERE IS NO GROUP B ANY MORE. The renderer is back on clk_sys and
#   general[2] drives nothing, so naming it here would name a clock the fitter
#   has dropped -- which this file records as giving "Internal Error:
#   Sub-system: DTM ... three builds died on it". The PLL still generates 60 MHz
#   on outclk_2 and the VCO stays at 1200, so putting the renderer back on it is
#   a one-line change when the texel fetch can absorb the crossing.
#
# Between the groups the paths are CUT, so every signal crossing between them
# needs a real synchroniser. That is new for this core and it is not optional:
# m2_handshake_cdc carries the quad bus, and m2_cpu_bridge has to have back the
# two flops Model2.sdc's earlier note recorded removing (S_DONE 4.42 -> 7.12
# cycles). A cut path with no synchroniser is the failure Model 1 warns is
# "a hardware-only fault by construction" -- invisible in every bench.
#
# IF A CROSSING IS MISSED, THIS FILE WILL NOT SAY SO. Cutting the paths removes
# the timing error that would otherwise point at it. The only defence is that
# every signal between the groups goes through a synchroniser by construction.
# R568: TWO GROUPS -- THE MEMORY CLOCK IS ASYNCHRONOUS TO THE CORE NOW.
#
# Step 1 of the clock plan (R561-R564) made every clk_mem <-> clk_sys crossing a
# real one: the SDRAM ports (m2_sdram_cdc), the texel queue (m2_texel_cdc), the
# video on clk_mem with dual-clock tile and palette RAMs, the frame edge and
# the char-cache invalidate on synchronisers, debug values frame-latched. The
# inventory taken on the step-1(b) netlist BEFORE this cut (xings.tcl) is the
# check that nothing else crosses: this statement removes the timing error that
# would otherwise point at a missed crossing, so it goes in only after that.
#
#   GROUP A  general[0] clk_mem 100, general[4] SDRAM_CLK 100 @ 180
#   GROUP B  general[1] clk_sys, general[3] clk_i960 -- still an exact 2:1
#            (50/25 today, 60/30 in the plan), and m2_cpu_bridge's crossing
#            between them is TIMED, as R460 requires.
set_clock_groups -asynchronous \
  -group [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|general[0].*|divclk \
                              *|pll|pll_inst|altera_pll_i|general[4].*|divclk}] \
  -group [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|general[1].*|divclk \
                              *|pll|pll_inst|altera_pll_i|general[3].*|divclk}]

# FIVE OUTPUTS NOW, AND THE COUNT IS CHECKED. The Kaneko16 core gave three
# outputs identical settings -- same frequency, same phase, same duty -- and the
# IP responded by giving all three ONE output counter: the whole core collapsed
# into a single clock domain, one clock in the timing netlist, Fmax 54.74 MHz.
# general[0] and general[4] here are both 100 MHz and differ only in phase, which
# is precisely that case, so a build that quietly produced fewer than five
# distinct clocks would look like a timing regression with no cause.
# THE COUNT IS NOT CHECKED HERE. During the fitter's read_sdc the derived PLL
# clocks are not all present yet -- this counted 1 on a build whose PLL had been
# elaborated with all five, confirmed in the synthesis log -- so a count taken at
# this point reports a state that is not final. `make release` checks it against
# the finished STA report instead.


# ---- R563's texel-queue multicycle exceptions are GONE (R590). They relaxed
# q_* -> f_* and r_tex -> the span walk while clk_mem and clk_sys were one
# related group; since R568 those paths cross between asynchronous groups and
# are cut, so the exceptions had nothing left to act on -- and once R583 moved
# the address into the queue their target list stopped matching, which left a
# critical warning on every build. A warning that is always there is one that
# stops being read.


# ---- R586: THE CPU BRIDGE'S PAYLOAD IS TWO clk_sys CYCLES BY PROTOCOL.
#
# m2_cpu_bridge writes r_addr / r_we / r_wdata / r_be on a clk_i960 edge
# together with req_cpu. clk_sys samples req_cpu into req_mem on its next
# edge, and the memory-side FSM acts on req_mem -- so nothing on clk_sys reads
# the payload before the SECOND clk_sys edge after it was written, and it does
# not change until the four-phase handshake ends. The clocks are an exact 2:1
# (clk_i960 = clk_sys / 2), so STA would otherwise time these at one clk_sys
# period: 14.29 ns at 70 MHz, where r_addr -> sd_addr missed by 0.95 ns
# (sized on s312, R580).
set br_from [get_registers -nowarn {*u_cpu_bridge|r_addr[*] *u_cpu_bridge|r_we *u_cpu_bridge|r_wdata[*] *u_cpu_bridge|r_be[*]}]
if {[get_collection_size $br_from] == 0} {
    post_message -type critical_warning \
      "Model2.sdc: m2_cpu_bridge payload registers did not match -- R586's exception is not applied."
} else {
    set_multicycle_path -setup -end 2 -from $br_from -to [get_clocks {*|pll|pll_inst|altera_pll_i|general[1].*|divclk}]
    set_multicycle_path -hold  -end 1 -from $br_from -to [get_clocks {*|pll|pll_inst|altera_pll_i|general[1].*|divclk}]
}


# ---- R590: THE I/O BOARD Z80'S CORE, TWO CYCLES, INSIDE ITSELF ONLY.
#
# tv80_core loads every register it has -- the state, IR, PC, flags and the
# tv80_reg file -- only when ClkEn = cen && !BusAck, and cen is m2_ioz80's
# 4-in-SYS_MHZ accumulator: at 70 MHz one pulse in ~17 cycles, never two in a
# row. So a path that starts AND ends inside the core has at least two cycles
# (s317: IR -> RegsH, -0.434 ns at 70). tv80s, the wrapper, drives the bus
# strobes every cycle and is deliberately NOT covered: a transient strobe
# into the firmware RAM is a write.
set z80_core [get_registers -nowarn {*u_ioz80|u_z80|i_tv80_core|*}]
if {[get_collection_size $z80_core] == 0} {
    post_message -type critical_warning \
      "Model2.sdc: the Z80 core's registers did not match -- R590's exception is not applied."
} else {
    set_multicycle_path -setup -end 2 -from $z80_core -to $z80_core
    set_multicycle_path -hold  -end 1 -from $z80_core -to $z80_core
}


# ---- R738: THE YM3438's OPERATOR COUNTER INTO ITS PHASE INCREMENT, TWO CYCLES.
#
# s783/s785/s787 at 80 MHz: u_reg|cur_ch -> u_pg|phinc_II, -0.010 .. -0.309 ns
# (cur_ch -> the CH3 fnum mux -> jt12_pg_comb -> phinc_II). jt12 is jotego's
# and unmodified, so this is an exception rather than a register.
#
# Both ends load on jt12's internal clk_en and nothing else:
#   jt12_reg.v  up_counter  `if( clk_en ) { cur_op, cur_ch } <= ...`  (no reset)
#   jt12_pg.v   `always @(posedge clk) if(clk_en)` keycode_II, detune_mod_II,
#               phinc_II -- the only assignments to them.
# clk_en is jt12_div's `clk_en <= cen & cen_int`, a NEGEDGE register sampling
# jt12_top's cen_reg, which is m2_sound_board's ym_cen one posedge late. So
# clk_en is high across exactly the posedge after each cen_reg pulse, or not at
# all (cen_int is the 1/6 FM prescaler at reset, 1/3 or 1/2 if programmed;
# jt12_div's FASTDIV, which would hold clk_en high, is defined nowhere here).
# ym_cen is the 25-in-(3 x TICK_DEN) accumulator, TICK_DEN = SYS_MHZ: it pulses
# when ym_acc + 25 >= 3*SYS_MHZ and leaves ym_acc <= 24, so the next cycle's
# sum is <= 49 and cannot pulse. Never two in a row for any SYS_MHZ >= 17; at
# 80 MHz one in 9.6 cycles, at least 9 apart. Every value cur_ch/cur_op launch
# therefore has at least nine clk_sys cycles before these registers next load.
set ym_from [get_registers -nowarn {*u_ym|u_jt12|u_mmr|u_reg|cur_ch* *u_ym|u_jt12|u_mmr|u_reg|cur_op*}]
set ym_to   [get_registers -nowarn {*u_ym|u_jt12|u_pg|phinc_II* *u_ym|u_jt12|u_pg|keycode_II* *u_ym|u_jt12|u_pg|detune_mod_II*}]
if {[get_collection_size $ym_from] == 0 || [get_collection_size $ym_to] == 0} {
    post_message -type critical_warning \
      "Model2.sdc: the YM3438 operator counter or phase registers did not match -- R738's exception is not applied."
} else {
    set_multicycle_path -setup -end 2 -from $ym_from -to $ym_to
    set_multicycle_path -hold  -end 1 -from $ym_from -to $ym_to
}


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
    # set_net_delay IS DISABLED, AND IT IS NOT A STYLE CHOICE.
    #
    # With the coprocessor in the design, these three collection-to-collection
    # net-delay assignments make Quartus 17.0 abort with
    #
    #     Internal Error: Sub-system: STA, File: sta_assignment_db.h, Line: 468
    #
    # at "Fitter placement preparation operations beginning" -- three times out
    # of three, on a cleared database, deterministically. Removing this block
    # and nothing else builds cleanly and produces a changed .rbf, which is the
    # only trustworthy signal this project accepts. set_max_skew is kept: it is
    # two assignments against two named synchroniser buses rather than an N-by-N
    # product over a collection, and it is the part that actually keeps each
    # synchroniser's bits together.
    #
    # WHAT THIS COSTS is stated rather than left to be discovered. set_net_delay
    # was bounding the physical net delay across the clk_vid/clk_sys character
    # crossing (R49, reinstated under R58's proof protocol). Without it that
    # bound is gone; the synchronisers are still skew-bounded. If the character
    # path misbehaves on hardware this is the first thing to look at.
    set_max_skew -to [get_registers -nowarn {*u_char_cdc|req_sync[*]}]  2
    set_max_skew -to [get_registers -nowarn {*u_char_cdc|done_sync[*]}] 2
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


# ---- R731: THE GAMMA CHOICE IS AN OSD SETTING, NOT A DATA PATH.
#
# gam_s2 (and gam_m2 for the other clock) are the two-flop copies of the OSD's
# Gamma menu. They change when the menu does and at no other time, so the
# engine's gam() -- the bias and constant selected by them, a multiply, a
# compare -- is not a one-cycle path from them: s759 timed it at 0.677 ns at
# 75 MHz, short of 80. A menu change landing mid-colour gives one colour the
# old curve, once. The data path into gam() (xl_raw) stays timed.
set gam_from [get_registers -nowarn {*gam_s2[*] *gam_m2[*]}]
if {[get_collection_size $gam_from] == 0} {
    post_message -type critical_warning \
      "Model2.sdc: the gamma-select registers did not match -- R731's false path is not applied."
} else {
    set_false_path -from $gam_from
}


# ---- R742: THE YM3438 PHASE INCREMENT INTO ITS PHASE SHIFT REGISTER, TWO CYCLES.
#
# jt12_pg's phinc_II / keycode_II / detune_mod_II load only on clk_en
# (jt12_pg.v: `always @(posedge clk) if(clk_en)`), and what they feed here
# does too: u_phsh (jt12_sh_rst, `if(clk_en)`) and jt12_eg's eg_V
# (jt12_eg.v line 142, `if(clk_en)`) -- both of which Quartus maps to M10K
# shift-tap RAMs. It is the same jt12 clk_en R738 proves is never high on two
# consecutive clk_sys cycles, so the data has at least two cycles (s795 at 80
# MHz: u_pg|phinc_II -> u_eg eg_V_rtl_0's porta_datain_reg -0.307). Paths
# inside the shift registers (their own outputs fed back) are not covered.
set yp_from [get_registers -nowarn {*u_ym|u_jt12|u_pg|phinc_II* *u_ym|u_jt12|u_pg|keycode_II* *u_ym|u_jt12|u_pg|detune_mod_II*}]
set yp_to   [get_keepers   -nowarn {*u_ym|u_jt12|u_pg|u_phsh|* *u_ym|u_jt12|u_eg|eg_V*}]
if {[get_collection_size $yp_from] == 0 || [get_collection_size $yp_to] == 0} {
    post_message -type critical_warning \
      "Model2.sdc: the YM3438 phase registers or u_phsh did not match -- R742's exception is not applied."
} else {
    set_multicycle_path -setup -end 2 -from $yp_from -to $yp_to
    set_multicycle_path -hold  -end 1 -from $yp_from -to $yp_to
}


# ---- R743: THE SOUND 68000'S IR INTO ITS MICRO/NANO ADDRESS, TWO CYCLES.
#
# fx68k loads Ir (`if (enT1) ... Ir <= Irc`) and microAddr / nanoAddr
# (`else if (enT1) begin microAddr <= nma; nanoAddr <= orgAddr;`) only on
# enT1 = enPhi1 & (tState == T4) & ~wClk (fx68k.sv:178), once every four phase
# enables. m2_sound_board makes enPhi1/enPhi2 from an accumulator that adds
# TICK_NUM = 20 a cycle against TICK_DEN = SYS_MHZ (Model2.sv) and drops below
# 20 after each pulse, so two enables are never on consecutive cycles at any
# SYS_MHZ >= 40, and enT1s are far further apart. Ir -> the PLA -> nanoAddr
# (s798 at 80 MHz: -0.146) therefore has at least two cycles. nanoAddr's
# pwrUp load is a constant, not a path from Ir.
set sk_from [get_registers -nowarn {*u_sndboard|u_cpu|Ir[*]}]
set sk_to   [get_registers -nowarn {*u_sndboard|u_cpu|nanoAddr[*] *u_sndboard|u_cpu|microAddr[*]}]
if {[get_collection_size $sk_from] == 0 || [get_collection_size $sk_to] == 0} {
    post_message -type critical_warning \
      "Model2.sdc: the sound 68000's Ir / nanoAddr registers did not match -- R743's exception is not applied."
} else {
    set_multicycle_path -setup -end 2 -from $sk_from -to $sk_to
    set_multicycle_path -hold  -end 1 -from $sk_from -to $sk_to
}
