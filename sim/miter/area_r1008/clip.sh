#!/bin/bash
# R1008: tb_clip_top (sim/video/tb_m2_geo_clip.cpp, 2,003 quads against the
# C transcription of MAME's clipper) with m2_geo_clip replaced by an
# old-against-new miter. Run from the checkout:
#   python3 sim/miter/miter.py m2_geo_clip <old>/rtl/video/m2_geo_clip.sv rtl/video/m2_geo_clip.sv <dir>
#   sed -i '/m2_geo_clip_old #/s/#(.STK_M10K(STK_M10K)) //' <dir>/m2_geo_clip_miter.sv
#   sim/miter/area_r1008/clip.sh <dir>
M=$1
rm -rf $M/obj
systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=0 verilator --cc --exe --build -j 2 -Wall -Wno-DECLFILENAME --timing -Wno-fatal -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY -Wno-WIDTHTRUNC -Wno-UNOPTFLAT -Wno-MULTITOP --top-module tb_clip_top -CFLAGS "-O2" -Irtl/tgp -Irtl/video --Mdir $M/obj -o V sim/video/tb_clip_top.sv $M/m2_geo_clip_miter.sv $M/m2_geo_clip_new.sv $M/m2_geo_clip_old.sv rtl/video/m2_geo_project.sv rtl/video/m2_fp_pool.sv rtl/video/fp_to_int.sv rtl/tgp/fp_mul.sv rtl/tgp/fp_add.sv rtl/tgp/fp_div.sv sim/video/tb_m2_geo_clip.cpp > $M/build.log 2>&1 || { echo build failed; tail -5 $M/build.log; }
$M/obj/V 2>&1 | grep "checks=\|MITER\|wrong" | tail -4
