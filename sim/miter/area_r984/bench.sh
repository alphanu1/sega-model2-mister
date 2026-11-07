#!/usr/bin/env bash
# The tree's own benches, built like the Makefile but -j 2, 8 GB, objects in scratch.
#   bench.sh <tree> <outdir> <name>...   names: qs r3d
set -u
T=$(cd "$1" && pwd); M=$2; shift 2; mkdir -p $M
V="systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=0 verilator --cc --exe --build -j 2 -Wall -Wno-DECLFILENAME --timing -I$T/rtl/cpu/i960"
cd $T
for n in "$@"; do
  rm -rf $M/obj_$n
  case $n in
    qs) $V --top-module m2_quad_store --public-flat-rw -GTINY=4 -GTINY_FINE=2 -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-PINCONNECTEMPTY -Wno-VARHIDDEN \
          --Mdir $M/obj_$n -o V -CFLAGS "-O2" rtl/video/m2_quad_store.sv rtl/tgp/m2_fifo_m10k.sv sim/video/tb_m2_quad_store.cpp > $M/build_$n.log 2>&1 ;;
    r3d) $V --top-module m2_raster3d --public-flat-rw -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY -Wno-VARHIDDEN -Wno-WIDTHTRUNC \
          --Mdir $M/obj_$n -o V -CFLAGS "-O2" \
          rtl/video/m2_raster3d.sv rtl/video/m2_quad_store.sv rtl/video/m2_raster_fill.sv \
          rtl/video/m2_raster_div.sv rtl/video/m2_recip_rom.sv rtl/video/m2_persp_recip.sv rtl/video/m2_raster_band.sv rtl/video/m2_span_tex.sv rtl/video/m2_texel.sv rtl/video/m2_texel_bl.sv rtl/video/m2_texel_addr.sv rtl/video/m2_texel_x2.sv rtl/video/m2_texel_cdc.sv rtl/video/m2_char_x2.sv rtl/tgp/m2_fifo_m10k.sv rtl/video/m2_fb_wcomb.sv rtl/video/m2_fb_read.sv rtl/mem/m2_ddr3_arb.sv sim/video/tb_m2_raster3d.cpp > $M/build_$n.log 2>&1 ;;
    rl) $V --top-module m2_romload_harness -CFLAGS "-O2 -I$T/sim/mem" -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-SYNCASYNCNET -Wno-PINCONNECTEMPTY           --Mdir $M/obj_$n -o V rtl/mem/m2_sdram.sv rtl/io/m2_rom_loader.sv sim/mem/sdram_model.sv sim/mem/m2_romload_harness.sv sim/mem/tb_m2_romload.cpp > $M/build_$n.log 2>&1 ;;
    rx) $V -Wno-WIDTHTRUNC --top-module m2_rom_loader -GSDR_AW=25 -GXTRA_FROM=46006272 -GXTRA_TO=25690112 -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM           --Mdir $M/obj_$n -o V -CFLAGS "-O2" rtl/io/m2_rom_loader.sv sim/mem/tb_m2_rom_xtra.cpp > $M/build_$n.log 2>&1 ;;
    rx2) $V -Wno-WIDTHTRUNC --top-module m2_rom_loader -GSDR_AW=26 -GXTRA_FROM=39059456 -GXTRA_TO=27262976 -GXTRA2_FROM=47448064 -GXTRA2_TO=19922944 -GXTRA3_FROM=53215232 -GXTRA3_TO=33554432           -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM --Mdir $M/obj_$n -o V -CFLAGS "-O2 -DTB_X3" rtl/io/m2_rom_loader.sv sim/mem/tb_m2_rom_xtra2a.cpp > $M/build_$n.log 2>&1 ;;
  esac
  if [ -x $M/obj_$n/V ]; then $M/obj_$n/V > $M/run_$n.log 2>&1; echo "$n: exit $? | $(tail -2 $M/run_$n.log | tr '\n' ' ')"; else echo "$n: build failed $M/build_$n.log"; fi
  grep -c "%Warning" $M/build_$n.log | sed "s/^/$n warnings: /"
  rm -rf $M/obj_$n
done
