#!/usr/bin/env bash
# R1059: i960mit.sh <name> <old tree> <-G params> <CFLAGS> <tb args>... -- run from the new tree.
# i960_top old against new through sim/miter/miter.py (i960_regs renamed in each copy), under
# tb_i960_top with its register pokes made to both copies (tbpatch.py); every i960_top output
# compared every clock, and rd1 / rd2 / the call saves / the flush words counted inside.
# STRIP: parameters the old tree lacks (default RF_SHARE); NEWREGS: an i960_regs.sv to use in
# place of the new tree's (a planted fault). -D MIT_SHARE / MIT_SHARE_O / MIT_GBR_O: where the
# new / old trees keep the third bank copy (see tbpatch.py).
set -u
S=$(cd "$(dirname "$0")" && pwd)
N=$(pwd)
name=$1; O=$2; G=$3; CF=$4; shift 4
M=$N/${OUT:-obj_mit_i960}/$name; rm -rf $M; mkdir -p $M; : > $M/empty.sv
python3 $N/sim/miter/miter.py i960_top $O/rtl/cpu/i960/i960_top.sv $N/rtl/cpu/i960/i960_top.sv $M \
   i960_regs $O/rtl/cpu/i960/i960_regs.sv ${NEWREGS:-$N/rtl/cpu/i960/i960_regs.sv} i960_rf_bank $M/empty.sv $M/empty.sv > $M/gen.log || exit 1
python3 - $M/i960_top_miter.sv <<'PY'
import sys
p=sys.argv[1]; t=open(p).read()
x='''  longint unsigned rd_diff, save_cyc, flush_w; initial begin rd_diff = 0; save_cyc = 0; flush_w = 0; end
  always @(posedge clk) begin
    if (u_new.u_regs.rd2 != u_old.u_regs.rd2 || u_new.u_regs.rd1 != u_old.u_regs.rd1) rd_diff <= rd_diff + 1;
    if (u_old.u_regs.state == 3'd1) save_cyc <= save_cyc + 1;
    if (u_old.u_regs.state == 3'd7 && u_old.u_regs.mem_ack) flush_w <= flush_w + 1;
  end
  final $display("INTERNAL rd1/rd2 differ on %0d cycles; S_CALL_SAVE %0d cycles; flush words %0d", rd_diff, save_cyc, flush_w);
'''
t=t.replace('endmodule', x+'endmodule')
open(p,'w').write(t)
PY
sed -i -E "/u_old \(/ s/\.(${STRIP:-RF_SHARE})\([A-Z_]+\),? ?//g" $M/i960_top_miter.sv
sed -e "s/i960_top__DOT__/i960_top__DOT__u_new__DOT__/g" -E -e "s/dut->rootp->i960_top__DOT__u_new__DOT__g_trans__DOT__u_trans__DOT__[A-Za-z_0-9]+/0/g" $N/sim/i960/tb_i960_top.cpp > $M/tb_i960_top.cpp
python3 $S/tbpatch.py $M/tb_i960_top.cpp
cp $N/sim/i960/*.h $M/
I=$N/rtl/cpu/i960
OTHER="$I/i960_dec.sv $I/i960_alu.sv $I/i960_agu.sv $I/i960_ldst.sv $I/i960_lsu.sv $I/i960_memmap.sv $I/i960_icache.sv $I/i960_muldiv.sv $I/i960_fpmul.sv $I/i960_fpadd.sv $I/i960_fpdiv.sv $I/i960_fpsqrt.sv $I/i960_fpmisc.sv $I/i960_fpcvt.sv $I/i960_fprem.sv $I/i960_fptrans.sv $I/i960_dcache.sv"
cd $N
systemd-run --user --scope -q -p MemoryMax=8G verilator --cc --exe --build -j 2 -Wno-fatal -Wno-lint -Wno-style --timing -Irtl/cpu/i960 \
  --top-module i960_top $G --public-flat-rw -CFLAGS "-O2 -I$M $CF" --Mdir $M/obj -o V \
  $M/i960_top_miter.sv $M/i960_top_new.sv $M/i960_top_old.sv $M/i960_regs_new.sv $M/i960_regs_old.sv $OTHER $M/tb_i960_top.cpp > $M/build.log 2>&1 || { echo "$name: build failed"; tail -20 $M/build.log; exit 1; }
for a in "$@"; do
  $M/obj/V $a > $M/run.log 2>&1; rc=$?
  echo "$name [$a] rc=$rc | $(grep -E 'PASS|FAIL|mismatch' $M/run.log | tail -1 | cut -c1-120) | $(grep '^MITER i960_top:.*cycles' $M/run.log) | $(grep '^INTERNAL' $M/run.log)"
done
