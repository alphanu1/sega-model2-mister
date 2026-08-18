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
    post_message -type error \
      "Model2.sdc: no core PLL clocks matched *|pll|pll_inst|altera_pll_i|*. \
       The PLL hierarchy does not match sys_top.sdc, so its clock groups are a \
       silent no-op and this build is NOT timed. See rtl/pll/pll.v."
    post_message -type error "Model2.sdc: refusing to constrain a design that is not timed."
}

# The three outputs are unrelated by construction -- 80 MHz SDRAM, 32 MHz video,
# 25 MHz i960 -- and sys_top.sdc puts them in ONE group, which times them against
# each other. Cut them explicitly. Nothing crosses between them in this step;
# doing it now means the crossings that arrive later are explicit rather than
# accidentally timed.
set_clock_groups -asynchronous \
  -group [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|general[0].*|divclk}] \
  -group [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|general[1].*|divclk}] \
  -group [get_clocks -nowarn {*|pll|pll_inst|altera_pll_i|general[2].*|divclk}]
