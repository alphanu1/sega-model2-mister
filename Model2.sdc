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
set_clock_groups -asynchronous \
  -group [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|general[0].*|divclk \
                              *|pll|pll_inst|altera_pll_i|general[1].*|divclk \
                              *|pll|pll_inst|altera_pll_i|general[4].*|divclk}] \
  -group [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|general[2].*|divclk}] \
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

