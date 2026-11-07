#!/usr/bin/env bash
# m2_raster_fill old against new (sim/miter/miter.py, with m2_raster_div), every
# output every cycle, under the fill's own benches, one build at a time (-j 2,
# 8 GB cap), objects under the output directory.
#   fill_miter.sh <old tree> <new tree> <outdir> [config ...]
# configs: fill mip m2cov             the benches at their own parameters
#          m2 m2m                     tb_m2_raster_fill at the Model 2 build's (MIP: m2m)
#          m2r m2rm                   the same with a random in_frac on every quad
#                                     offered (the bench drives 0 otherwise)
set -u
O=$(cd "$1" && pwd); N=$(cd "$2" && pwd); M=$3; shift 3
CFGS=${*:-fill mip m2cov m2 m2m m2r m2rm}
mkdir -p $M
python3 $N/sim/miter/miter.py m2_raster_fill $O/rtl/video/m2_raster_fill.sv $N/rtl/video/m2_raster_fill.sv $M \
        m2_raster_div $O/rtl/video/m2_raster_div.sv $N/rtl/video/m2_raster_div.sv >/dev/null
for tb in tb_m2_raster_fill tb_m2_fill_m2cov; do
  sed -e 's/m2_raster_fill__DOT__/m2_raster_fill__DOT__u_new__DOT__/g' -e 's/delete d;/d->final(); delete d;/g' $N/sim/video/$tb.cpp > $M/$tb.cpp
done
sed -e 's/^  void tick() {$/  void tick() { if (d->in_valid) { d->in_frac = (uint16_t)rand(); }/' \
    $M/tb_m2_raster_fill.cpp > $M/tb_m2_raster_fill_rnd.cpp
grep -q "d->in_frac = (uint16_t)rand" $M/tb_m2_raster_fill_rnd.cpp || { echo "random variant not made"; exit 1; }
OTHER="$M/m2_raster_div_new.sv $M/m2_raster_div_old.sv $N/rtl/video/m2_recip_rom.sv $N/rtl/video/m2_persp_recip.sv"
W="-Wno-fatal -Wno-UNUSEDSIGNAL -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-MULTITOP -Wno-WIDTHEXPAND"
P2="-GPXC=1 -GFRB=2 -GM2COV=1 -GUZF=4 -GUVCL=1"   # m2_raster3d's u_fill as Model2.sv builds it (MIP: R3D_MIP)
b() { local n=$1 tb=$2 g=$3 c=$4; rm -rf $M/obj_$n
  systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=0 \
  verilator --cc --exe --build -j 2 $W --public-flat-rw --top-module m2_raster_fill $g --Mdir $M/obj_$n -o V -CFLAGS "-O2 $c" \
    $M/m2_raster_fill_miter.sv $M/m2_raster_fill_new.sv $M/m2_raster_fill_old.sv $OTHER $M/$tb.cpp > $M/build_$n.log 2>&1 || echo "$n: build failed ($M/build_$n.log)"; }
sum='/^MITER/{c+=$3; b+=$5} END{printf "MITER %d cycles, %d with an output differing\n", c, b}'
r() { local n=$1; shift; [ -x $M/obj_$n/V ] || return; env "$@" $M/obj_$n/V > $M/run_$n.log 2>&1
      echo "$n: exit $? | $(grep -hE 'checks=|PASS|FAIL' $M/run_$n.log | tail -1) | $(awk "$sum" $M/run_$n.log)"; }
for c in $CFGS; do
  case $c in
    fill)  b fill  tb_m2_raster_fill "" "";                          r fill X=1 ;;
    mip)   b mip   tb_m2_raster_fill "-GMIP=1" "-DTB_MIP";           r mip X=1 ;;
    m2cov) b m2cov tb_m2_fill_m2cov "-GFRB=2 -GM2COV=1" "";          r m2cov TIEW=0.01 ;;
    m2)    b m2    tb_m2_raster_fill "$P2" "";                       r m2 X=1 ;;
    m2m)   b m2m   tb_m2_raster_fill "$P2 -GMIP=1" "-DTB_MIP";       r m2m X=1 ;;
    m2r)   b m2r   tb_m2_raster_fill_rnd "$P2" "";                   r m2r X=1 ;;
    m2rm)  b m2rm  tb_m2_raster_fill_rnd "$P2 -GMIP=1" "-DTB_MIP";   r m2rm X=1 ;;
  esac
  rm -rf $M/obj_$c
done
