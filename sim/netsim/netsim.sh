#!/usr/bin/env bash
# R967: SIMULATE WHAT QUARTUS BUILT, NOT WHAT WE WROTE. A module is mapped alone
# by Quartus 17.0 (quartus_map, every pin virtual, the core's synthesis
# settings), written out as its post-synthesis functional netlist (quartus_eda
# --functional) and compiled by Verilator against sim/netsim/atoms_vl.sv (the
# Cyclone V atoms, two-state) with an unchanged bench -- the netlist's top has
# the RTL's ports. A difference from the RTL bench is a synthesis divergence.
# This is how R967's MPRO byte loss was found: the RTL passes, the netlist fails.
#
#   sim/netsim/netsim.sh <out dir> <top> <bench.cpp> <rtl files...>
#   e.g. sim/netsim/netsim.sh /tmp/x m2_scsp_dsp sim/sound/tb_m2_scsp_dsp.cpp \
#          rtl/sound/scsp/m2_scsp_dsp.sv rtl/sound/scsp/m2_scsp_cache.sv
#        then: cd /tmp/x/run && DSP_RANDOM=100 ./V<top>
#
# What it cannot see: the RAMs' and the MAC's silicon (atoms_vl.sv models them
# from their parameters; the vendor RAM models are plain SV in altera_lnsim.sv,
# the MAC's are encrypted), timing, and the fitter's physical synthesis.
# atoms_vl.sv counts every RAM read-during-write collision; a bench that calls
# t->final() prints the totals.
set -euo pipefail
QB=/home/ben/intelFPGA_lite/17.0/quartus/bin
out=$1; top=$2; tb=$3; shift 3
root=$(pwd)
mkdir -p "$out/q"
for f in "$@"; do cp "$root/$f" "$out/q/"; done
for f in "$root"/rtl/sound/scsp/*.hex "$root"/rtl/sound/scsp/*.svh; do cp "$f" "$out/q/"; done
{
  echo 'set_global_assignment -name FAMILY "Cyclone V"'
  echo 'set_global_assignment -name DEVICE 5CSEBA6U23I7'
  echo "set_global_assignment -name TOP_LEVEL_ENTITY $top"
  # Model2.qsf's synthesis settings
  echo 'set_global_assignment -name OPTIMIZATION_MODE "AGGRESSIVE AREA"'
  echo 'set_global_assignment -name OPTIMIZATION_TECHNIQUE AREA'
  echo 'set_global_assignment -name MUX_RESTRUCTURE ON'
  echo 'set_global_assignment -name REMOVE_REDUNDANT_LOGIC_CELLS ON'
  echo 'set_global_assignment -name AUTO_RESOURCE_SHARING ON'
  echo 'set_global_assignment -name QII_AUTO_PACKED_REGISTERS NORMAL'
  for f in "$@"; do echo "set_global_assignment -name SYSTEMVERILOG_FILE $(basename "$f")"; done
  echo 'set_instance_assignment -name VIRTUAL_PIN ON -to *'
} > "$out/q/n.qsf"
echo 'PROJECT_REVISION = "n"' > "$out/q/n.qpf"
(cd "$out/q" && "$QB/quartus_map" n -c n > map.log && \
  "$QB/quartus_eda" n -c n --simulation=on --functional=on --tool=modelsim_oem --format=verilog > eda.log)
# the defparams sit inside translate_off: keep them
grep -v "synopsys translate_o" "$out/q/simulation/modelsim/n.vo" > "$out/net.v"
verilator --cc --exe --build -j 8 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
  -CFLAGS "-O2 -std=c++17 -I$root/sim/sound" -I"$root/sim/sound" --top-module "$top" --Mdir "$out/obj" \
  "$root/sim/netsim/atoms_vl.sv" "$out/net.v" "$root/$tb" > "$out/build.log"
mkdir -p "$out/run"
cp "$out/obj/V$top" "$root"/rtl/sound/scsp/*.hex "$out/run/"
grep -i "simple dual\|true dual\|; rom " "$out/q/n.map.rpt" | sed 's/  */ /g' > "$out/rams.txt" || true
echo "netlist bench: $out/run/V$top  (RAM summary: $out/rams.txt)"
