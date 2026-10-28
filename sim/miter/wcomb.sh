#!/usr/bin/env bash
# R968: m2_fb_wcomb old against new under the write-path chain bench with the
# front-to-back mask (m2_fbw_chain, WCOMB=1 FTB=1, the build's configuration),
# every output on every cycle -- except pg_wd, the mask word, which is compared
# only while pg_we is 1: that is the only time anything reads it (m2_raster3d
# writes mk_a / the span_tex copy / its bypass under mk_we = fbw_we). The
# cycles where pg_wd differs with pg_we 0 are counted separately, so the run
# shows the change is exercised.
#
#   sim/miter/wcomb.sh <old tree>        (run from the new tree's root)
#
# A mutation (the written mask word one pixel off) must differ.
set -u
O=$(cd "$1" && pwd); M=obj_miter_wcomb; rm -rf $M; mkdir -p $M
mk() {   # outdir, old source, new source
  python3 sim/miter/miter.py m2_fb_wcomb "$2" "$3" "$1" >/dev/null
  python3 - "$1/m2_fb_wcomb_miter.sv" <<'PY'
import sys, re
p = sys.argv[1]; t = open(p).read()
t, n = re.subn(r'\(pg_wd != mo_pg_wd\)', '(pg_we && (pg_wd != mo_pg_wd))', t)
assert n >= 1, 'pg_wd compare not found'
t = t.replace('  longint unsigned mt_cyc, mt_bad;', '  longint unsigned mt_cyc, mt_bad, mt_masked;')
t = t.replace('initial begin mt_cyc = 0; mt_bad = 0; end', 'initial begin mt_cyc = 0; mt_bad = 0; mt_masked = 0; end')
t = t.replace('    mt_cyc <= mt_cyc + 1;', '    mt_cyc <= mt_cyc + 1;\n    if (!pg_we && (pg_wd != mo_pg_wd)) mt_masked <= mt_masked + 1;')
t = t.replace('final $display("MITER m2_fb_wcomb: %0d cycles, %0d with an output differing (%0d outputs compared)", mt_cyc, mt_bad,',
              'final $display("MITER m2_fb_wcomb: %0d cycles, %0d with an output differing; pg_wd differs unread on %0d (outputs compared: %0d)", mt_cyc, mt_bad, mt_masked,')
assert 'mt_masked,' in t
open(p, 'w').write(t)
PY
}
mk $M "$O/rtl/video/m2_fb_wcomb.sv" rtl/video/m2_fb_wcomb.sv
mkdir -p $M/mut
sed 's/32'"'"'({hi_on, lo_on}) << {b_off, 1'"'"'b0}/32'"'"'({hi_on, lo_on}) << {b_off, 1'"'"'b1}/' rtl/video/m2_fb_wcomb.sv > $M/mut/m2_fb_wcomb.sv
cmp -s $M/mut/m2_fb_wcomb.sv rtl/video/m2_fb_wcomb.sv && { echo "wcomb: the mutation did not apply"; exit 1; }
mk $M/mut "$O/rtl/video/m2_fb_wcomb.sv" $M/mut/m2_fb_wcomb.sv
sed -e 's/delete \([a-z_]*\);/\1->final(); delete \1;/g' sim/video/tb_m2_fbw_chain.cpp > $M/tb_m2_fbw_chain.cpp
grep -q -- '->final()' $M/tb_m2_fbw_chain.cpp || echo "note: the bench has no delete; final() comes from Verilator's exit"
W="-Wno-fatal -Wno-UNUSEDSIGNAL -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-MULTITOP -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY"
OTHER="sim/video/m2_fbw_chain.sv rtl/video/m2_fb_write.sv rtl/mem/m2_ddr3_arb.sv rtl/mem/m2_ddr3.sv"
b() { local n=$1 d=$2; rm -rf $M/obj_$n
  verilator --cc --exe --build -j 0 $W --timing --top-module m2_fbw_chain -GWCOMB=1 -GFTB=1 --Mdir $M/obj_$n -o V -CFLAGS "-O2 -DCHAIN_FTB" \
    $d/m2_fb_wcomb_miter.sv $d/m2_fb_wcomb_new.sv $d/m2_fb_wcomb_old.sv $OTHER $M/tb_m2_fbw_chain.cpp > $M/build_$n.log 2>&1 \
    || echo "$n: build failed ($M/build_$n.log)"; }
b eq $M & b mut $M/mut & wait
r() { local n=$1 tag=$2; shift 2; [ -x $M/obj_$n/V ] || return; env "$@" $M/obj_$n/V > $M/run_${n}_$tag.log 2>&1
      echo "$n $tag: exit $? | $(grep -hiE 'spans|PASS|FAIL' $M/run_${n}_$tag.log | tail -1 | cut -c1-110) | $(grep -h '^MITER' $M/run_${n}_$tag.log | tail -1)"; }
for busy in 0 300 900; do for seed in 1 7 12345; do
  r eq b${busy}_s$seed CHAIN_BUSY=$busy CHAIN_SEED=$seed CHAIN_N=${CHAIN_N:-200000} &
done; wait; done
echo "-- mutation (must differ):"
r mut b300_s1 CHAIN_BUSY=300 CHAIN_SEED=1 CHAIN_N=20000
