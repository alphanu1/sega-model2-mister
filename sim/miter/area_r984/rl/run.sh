#!/usr/bin/env bash
set -u
O=$1 N=$2 M=$3; shift 3; mkdir -p $M
python3 /home/ben/source/sega-model2-mister/sm2-builds/area-2c/sim/miter/miter.py m2_rom_loader $O $N $M >/dev/null
G="-GTGP_INDEX=1 -GTGP_PROG_END=8192 -GFIFO_DEPTH=512 -GWAIT_MARGIN=256 -GSDR_AW=26 -GROM_INDEX=0 -GXTRA_FROM=39059456 -GXTRA_TO=27262976 -GXTRA2_FROM=47448064 -GXTRA2_TO=19922944 -GXTRA3_FROM=53215232 -GXTRA3_TO=33554432"
W="-Wno-fatal -Wno-UNUSEDSIGNAL -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-MULTITOP"
rm -rf $M/obj
systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=0 verilator --cc --exe --build -j 2 $W --top-module m2_rom_loader $G --Mdir $M/obj -o V -CFLAGS "-O2"   $M/m2_rom_loader_miter.sv $M/m2_rom_loader_new.sv $M/m2_rom_loader_old.sv ${AREA_DIR:-/tmp/m2-area}/rl/tb_rl_miter.cpp > $M/build.log 2>&1 || { echo "build failed $M/build.log"; exit 1; }
for s in ${*:-1 2 3}; do SEED=$s $M/obj/V > $M/run_$s.log 2>&1; echo "seed $s: $(grep tb_rl $M/run_$s.log) | $(grep 'MITER.*cycles' $M/run_$s.log)"; done
rm -rf $M/obj
