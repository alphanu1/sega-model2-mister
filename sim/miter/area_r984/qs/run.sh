#!/usr/bin/env bash
# m2_quad_store miter at the 2C parameters.  run.sh <old.sv> <new.sv> <outdir> [seeds...]
set -u
A=${AREA_DIR:-/tmp/m2-area}
T=/home/ben/source/sega-model2-mister/sm2-builds/area-2c
O=$1 N=$2 M=$3; shift 3
mkdir -p $M
python3 $T/sim/miter/miter.py m2_quad_store $O $N $M >/dev/null
G="-GNQ=2048 -GFRB=2 -GIW=11 -GBAND_H=8 -GNBANDS=48 -GBW=6 -GRADIX=4 -GNBANK=2 -GXW=13 -GCW=17 -GRAWCOL=1 -GVX=1 -GVXN=3 -GKW=20 -GUVW=13 -GTXW=28 -GOZW=16 -GTINY=4 -GTINY_FINE=2 -GTINY_FAR=16\'h3000 -GSCR_H=384 -GFTB=1 -GMZ=1"
W="-Wno-fatal -Wno-UNUSEDSIGNAL -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-MULTITOP -Wno-PINCONNECTEMPTY -Wno-VARHIDDEN"
rm -rf $M/obj
systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=0 \
  verilator --cc --exe --build -j 2 $W --top-module m2_quad_store $G --Mdir $M/obj -o V -CFLAGS "-O2" \
  $M/m2_quad_store_miter.sv $M/m2_quad_store_new.sv $M/m2_quad_store_old.sv $T/rtl/tgp/m2_fifo_m10k.sv $A/qs/tb_qs_miter.cpp \
  > $M/build.log 2>&1 || { echo "build failed: $M/build.log"; exit 1; }
for s in ${*:-1 2 3}; do SEED=$s $M/obj/V > $M/run_$s.log 2>&1; echo "seed $s: $(grep tb_qs $M/run_$s.log) | $(grep 'MITER.*cycles' $M/run_$s.log)"; done
rm -rf $M/obj
