#!/usr/bin/env bash
# R952: m2_raster_fill (with m2_raster_div) old against new, every output on
# every cycle, under the fill's own four benches (tb_m2_raster_fill plain and
# MIP, tb_m2_fill_m2cov plain and DIL where the tree has DIL).
#
#   sim/miter/fill.sh <old tree>        (run from the new tree's root)
#
# Prints each bench's own verdict and the miter's count of differing cycles.
set -u
O=$(cd "$1" && pwd); M=obj_miter_fill; mkdir -p $M
python3 sim/miter/miter.py m2_raster_fill $O/rtl/video/m2_raster_fill.sv rtl/video/m2_raster_fill.sv $M \
        m2_raster_div $O/rtl/video/m2_raster_div.sv rtl/video/m2_raster_div.sv >/dev/null
for tb in tb_m2_raster_fill tb_m2_fill_m2cov; do
  sed -e 's/m2_raster_fill__DOT__/m2_raster_fill__DOT__u_new__DOT__/g' -e 's/delete d;/d->final(); delete d;/g' sim/video/$tb.cpp > $M/$tb.cpp
done
OTHER="$M/m2_raster_div_new.sv $M/m2_raster_div_old.sv rtl/video/m2_recip_rom.sv rtl/video/m2_persp_recip.sv"
W="-Wno-fatal -Wno-UNUSEDSIGNAL -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-MULTITOP -Wno-WIDTHEXPAND"
b() { local n=$1 tb=$2 g=$3 c=$4; rm -rf $M/obj_$n
  verilator --cc --exe --build -j 0 $W --public-flat-rw --top-module m2_raster_fill $g --Mdir $M/obj_$n -o V -CFLAGS "-O2 $c" \
    $M/m2_raster_fill_miter.sv $M/m2_raster_fill_new.sv $M/m2_raster_fill_old.sv $OTHER $M/$tb.cpp > $M/build_$n.log 2>&1 || echo "$n: build failed ($M/build_$n.log)"; }
DIL=0; grep -q "parameter bit DIL" rtl/video/m2_raster_fill.sv && DIL=1
b fill tb_m2_raster_fill "" "" & b mip tb_m2_raster_fill "-GMIP=1" "-DTB_MIP" & b m2cov tb_m2_fill_m2cov "-GFRB=2 -GM2COV=1" "" &
[ $DIL = 1 ] && b dil tb_m2_fill_m2cov "-GFRB=2 -GM2COV=1 -GDIL=1" "-DTB_DIL" &
wait
sum='/^MITER/{c+=$3; b+=$5} END{printf "MITER %d cycles, %d with an output differing\n", c, b}'
r() { local n=$1; shift; [ -x $M/obj_$n/V ] || return; env "$@" $M/obj_$n/V > $M/run_$n.log 2>&1
      echo "$n: exit $? | $(grep -hE 'checks=|PASS|FAIL' $M/run_$n.log | tail -1) | $(awk "$sum" $M/run_$n.log)"; }
r fill X=1 & r mip X=1 & r m2cov TIEW=0.01 & r dil TIEW=0.01 & wait
