#!/usr/bin/env bash
# R959 / R968: m2_sdram old against new, FORMALLY: yosys equiv_make /
# equiv_simple / equiv_induct over the two netlists, every register and output
# matched by name. Proven means the two produce the same command stream, data
# and acks on every cycle from reset, for every input sequence, at the
# parameters given.
#
#   sim/miter/sdram_eq.sh <old tree> [main|np5 ...]   (from the new tree's root)
#
# THIS IS MAIN'S m2_sdram, NOT THE 2A ONE R959 WAS PROVEN ON (that file has
# DUAL, MASK_ON_A and AGE; this one ends its header at PRI_TOP). R968 re-ran
# the proof here, on this file, before taking R959's change into the Model 2
# core.
#
# yosys 0.66 reads m2_sdram with two edits, made to both copies alike: AW
# becomes a header parameter (the ports use it before the body's localparam),
# and tag_w[0][1:0] is read through a wire (a dynamic index yosys rejects).
set -u
O=$(cd "$1" && pwd); shift; M=obj_miter_sdram_eq; mkdir -p $M
prep() {
  sed -e "s/\bmodule m2_sdram\b/module m2_sdram_$2/" \
      -e "s/^\(\s*parameter logic \[NP-1:0\] PRI_TOP = '0\)$/\1,\n  parameter int unsigned AW = BA_BITS + ROW_BITS + COL_BITS/" \
      -e 's/^\(\s*localparam int unsigned AW = .*\)$/\/\/ \1/' \
      -e 's/^\(\s*logic \[RD_LAT-1:0\]\[2:0\]   tag_w;.*\)$/\1\n  wire [2:0] tag_w0 = tag_w[0];\n  wire [1:0] tag_w0l = tag_w0[1:0];/' \
      -e 's/cap\[tag_w\[0\]\[1:0\]\] <= dq_r;/cap[tag_w0l] <= dq_r;/' \
      -e 's/case (tag_w\[0\]\[1:0\])/case (tag_w0l)/' "$1" > $M/$2.sv
  [ $(grep -c 'tag_w0l\|parameter int unsigned AW' $M/$2.sv) = 4 ] || { echo "sdram_eq: the edits did not apply to $1"; exit 1; }
}
prep $O/rtl/mem/m2_sdram.sv old
prep rtl/mem/m2_sdram.sv new
[ $# = 0 ] && set -- main np5
for c in "$@"; do
  case $c in
  # Model2.sv's u_sdram: COL_BITS SDR_COL (10), NP NPORTS (13), T_REFI 781,
  # PRI / PRI_CAP / PRI_TOP as instantiated.
  main) P="-set NP 13 -set COL_BITS 10 -set T_REFI 781 -set PRI 13'b1110000011110 -set PRI_CAP 2 -set PRI_TOP 13'b0000000001000" ;;
  np5)  P="-set NP 5" ;;
  esac
  cat > $M/eq_$c.ys <<EOT
read_verilog -sv $M/old.sv $M/new.sv
chparam $P m2_sdram_old m2_sdram_new
proc
memory
flatten
opt_clean
async2sync
equiv_make m2_sdram_old m2_sdram_new equiv
hierarchy -top equiv
equiv_simple -undef
equiv_induct -undef
equiv_status -assert
EOT
  yosys -q -l $M/eq_$c.log $M/eq_$c.ys > /dev/null 2>&1; r=$?
  echo "$c: $( [ $r = 0 ] && echo PROVEN || echo NOT PROVEN ) | $(grep -E 'Of those cells' $M/eq_$c.log | tail -1 | sed 's/^ *//')"
done
