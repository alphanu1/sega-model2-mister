#!/usr/bin/env bash
# The area pass (R984-R988, ported from model2c) re-run from the history: every
# changed module's old copy against its new one, then the planted faults.
#   prove.sh <old rev> <new rev> [fill] [qs] [rl] [faults]     (default: all)
# e.g. prove.sh <the pass's parent> HEAD, or two adjacent commits for one step.
# Scratch under ${AREA_DIR:-/tmp/m2-area}; every build is capped at 8 GB, -j 2.
# Faults are planted in the new rev's files; one whose line is not there (a
# step that rev does not have) is reported and skipped.
set -u
H=$(cd "$(dirname "$0")" && pwd)
T=$(cd "$H/../../.." && pwd)
A=${AREA_DIR:-/tmp/m2-area}
O=$1 N=$2; shift 2
WHAT=${*:-fill qs rl faults}
mkdir -p $A/src
for r in old new; do
  rev=$O; [ $r = new ] && rev=$N
  rm -rf $A/tree_$r; mkdir -p $A/tree_$r
  git -C $T archive $rev rtl/video sim/video sim/miter/miter.py | tar -x -C $A/tree_$r
  cp $A/tree_$r/rtl/video/m2_quad_store.sv $A/src/qs_$r.sv
  git -C $T show $rev:rtl/io/m2_rom_loader.sv > $A/src/rl_$r.sv
done
export TREE=$T
has() { case " $WHAT " in *" $1 "*) return 0;; esac; return 1; }
has fill && { echo "## m2_raster_fill"; $H/fill_miter.sh $A/tree_old $A/tree_new $A/fill; }
has qs   && { echo "## m2_quad_store";  FRAMES=${FRAMES:-2000} $H/qs/run.sh $A/src/qs_old.sv $A/src/qs_new.sv $A/qs 1 2 3; }
has rl   && { echo "## m2_rom_loader";  $H/rl/run.sh $A/src/rl_old.sv $A/src/rl_new.sv $A/rl 1 2 3; }
has faults || exit 0
# plant <name> <file> <sed expression>: the fault in a copy, the old file against it
plant() { local n=$1 f=$2 e=$3 k=${2%%_*}
  sed "$e" $A/src/$f > $A/src/f_$n.sv
  if cmp -s $A/src/$f $A/src/f_$n.sv; then echo "fault $n: not in this rev, skipped"; return; fi
  echo "fault $n"
  case $k in
    qs) FRAMES=2000 $H/qs/run.sh $A/src/qs_old.sv $A/src/f_$n.sv $A/f_$n 1 ;;
    rl) CYC=2000000 $H/rl/run.sh $A/src/rl_old.sv $A/src/f_$n.sv $A/f_$n 1 ;;
  esac; }
echo "## planted faults (every one must differ, except where noted)"
plant r985_bank   qs_new.sv 's/rd_bank <= rbank ^ sb(q); rd_ld <= 1.b1;/rd_bank <= rbank; rd_ld <= 1'"'"'b1;/'
plant r985_start  qs_new.sv 's/wire e_rd = (e_st == E_READ) \&\& !replay_start;/wire e_rd = (e_st == E_READ);/'
plant r986_clear  qs_new.sv 's/h_we = (rst_st == R_CNT) ||/h_we = ((rst_st == R_CNT) \&\& !hi[3]) ||/'
plant r987_key    qs_new.sv 's/ksel   <= sb(cur_idx);/ksel   <= 1'"'"'b0;/'
plant r987_att    qs_new.sv 's/att_sel <= rbank ^ sb(ord_idx);/att_sel <= rbank;/'
plant r987_ord    qs_new.sv 's/      ord_sel <= rbank ^ sb(pi\[PIW-1:0\]);/      ord_sel <= rbank;/'
echo "(r987_start is NOT a fault: a read on replay_start's edge is never seen -- 0 expected)"
plant r987_start  qs_new.sv 's/wire o_rd = adv \&\& !replay_start;/wire o_rd = adv;/'
plant r988_flag   rl_new.sv 's/  assign sdr_wr_din  = fq_ld ? {fq_hi, fq_lo} : 16.d0;/  assign sdr_wr_din  = {fq_hi, fq_lo};/'
plant r988_empty  rl_new.sv 's/  wire                f_rd = !rst \&\& !busy \&\& !fifo_empty \&\& mem_ready \&\& !rd_armed;/  wire                f_rd = !rst \&\& !busy \&\& mem_ready \&\& !rd_armed;/'
# R984's two: s1_y from sx, and s1_y with the x fraction (seen only with random fractions: a2r)
if has fill; then
  for n in 1 2; do
    rm -rf $A/tree_f$n; cp -r $A/tree_new $A/tree_f$n
    F=$A/tree_f$n/rtl/video/m2_raster_fill.sv
    [ $n = 1 ] && sed -i 's/          s1_y   <= p4(sy\[fa\], sf\[fa\]\[3:2\]);/          s1_y   <= p4(sx[fa], sf[fa][3:2]);/' $F
    [ $n = 2 ] && sed -i 's/          s1_y   <= p4(sy\[fa\], sf\[fa\]\[3:2\]);/          s1_y   <= p4(sy[fa], sf[fa][1:0]);/' $F
    if cmp -s $F $A/tree_new/rtl/video/m2_raster_fill.sv; then echo "fault r984_$n: not in this rev, skipped"; continue; fi
    echo "fault r984_$n"; $H/fill_miter.sh $A/tree_old $A/tree_f$n $A/f_r984_$n a2 a2r
  done
fi
