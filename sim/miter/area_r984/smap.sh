#!/usr/bin/env bash
# Standalone quartus_map of one module, the project's synthesis settings.
#   smap.sh <name> <top> "<params: N=V ...>" "<macros: M ...>" <file>...
# Waits for its turn: no other quartus_map of mine, fewer than 3 quartus_fit.
set -u
Q=/home/ben/intelFPGA_lite/17.0/quartus/bin
A=${AREA_DIR:-/tmp/m2-area}
name=$1 top=$2 params=$3 macros=$4; shift 4
D=$A/map_$name; rm -rf $D; mkdir -p $D
{
echo "set_global_assignment -name FAMILY \"Cyclone V\""
echo "set_global_assignment -name DEVICE 5CSEBA6U23I7"
echo "set_global_assignment -name TOP_LEVEL_ENTITY $top"
echo "set_global_assignment -name OPTIMIZATION_MODE \"AGGRESSIVE AREA\""
echo "set_global_assignment -name OPTIMIZATION_TECHNIQUE AREA"
echo "set_global_assignment -name MUX_RESTRUCTURE ON"
echo "set_global_assignment -name REMOVE_REDUNDANT_LOGIC_CELLS ON"
echo "set_global_assignment -name AUTO_RESOURCE_SHARING ON"
echo "set_global_assignment -name QII_AUTO_PACKED_REGISTERS NORMAL"
echo "set_global_assignment -name NUM_PARALLEL_PROCESSORS 2"
echo "set_instance_assignment -name VIRTUAL_PIN ON -to *"
for p in $params; do echo "set_parameter -name ${p%%=*} ${p#*=}"; done
for m in $macros; do echo "set_global_assignment -name VERILOG_MACRO \"$m\""; done
for f in "$@"; do echo "set_global_assignment -name SYSTEMVERILOG_FILE $f"; done
} > $D/s.qsf
echo "PROJECT_REVISION = \"s\"" > $D/s.qpf
exec 9>$A/map.lock; flock 9
while [ "$(pgrep -x quartus_fit | wc -l)" -ge 3 ]; do sleep 5; done
( cd $D && $Q/quartus_map s > map.log 2>&1 ); rc=$?
flock -u 9
R=$D/output_files/s.map.rpt; [ -f $R ] || R=$D/s.map.rpt
echo "== $name rc=$rc"
grep -E "Estimate of Logic utilization|Combinational ALUT usage for logic|Dedicated logic registers|Total block memory bits|Total DSP Blocks" $R | sed 's/  */ /g' | head -8
grep -A40 "Analysis & Synthesis RAM Summary" $R | grep "^;" | cut -c1-200 | head -20
grep -E "^Error|Error \(" $D/map.log | head -5
rm -rf $D/db $D/incremental_db
