#!/usr/bin/env bash
# R1030: the 2C tilemap path (m2_video, m2_char_cache, the palette and tile
# RAMs as Model2.sv wires them) old against new, every output on every clock
# (m2_vid2c_miter.sv, tb_m2_vid2c_miter.cpp).
#
#   sim/miter/vid2c.sh <old tree> build [<SIBLING 0|1>]
#   sim/miter/vid2c.sh <old tree> run [<SIBLING 0|1>] <env>...     (VM_N, VM_SEED, VM_IN, VM_CE, VM_LAT, VM_HOLD, VM_IL, VM_WR, VM_INV)
set -u
O=$(cd "$1" && pwd); M=${MITER_DIR:-obj_miter_vid2c}; mkdir -p $M
case "$2" in
build)
  sed -e 's/\bmodule m2_video\b/module m2_video_old/' -e 's/\bmodule m2_lbuf_ram\b/module m2_lbuf_ram_old/' \
      -e 's/^\(\s*\)m2_lbuf_ram\b/\1m2_lbuf_ram_old/' $O/rtl/video/m2_video.sv > $M/m2_video_old.sv
  sed -e 's/\bmodule m2_char_cache\b/module m2_char_cache_old/' $O/rtl/video/m2_char_cache.sv > $M/m2_char_cache_old.sv
  [ $(grep -c 'm2_lbuf_ram_old' $M/m2_video_old.sv) -ge 3 ] || { echo "vid2c: the renames did not apply"; exit 1; }
  B=${3:-0}; rm -rf $M/obj$B
  verilator --cc --exe --build -j 2 -Wall -Wno-DECLFILENAME -Wno-fatal -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY \
    -Wno-UNUSEDPARAM -Wno-TIMESCALEMOD -GSIB=$B -CFLAGS "-O2" --top-module m2_vid2c_miter --Mdir $M/obj$B -o V \
    rtl/video/m2_video_timing.sv rtl/video/m2_tile_decode.sv rtl/video/m2_tile_fetch.sv rtl/video/m2_tile_mixer.sv \
    rtl/video/m2_palette.sv rtl/video/m2_video.sv rtl/video/m2_char_cache.sv rtl/mem/m2_tdp_ram2c.sv \
    $M/m2_video_old.sv $M/m2_char_cache_old.sv sim/miter/m2_vid2c_miter.sv sim/miter/tb_m2_vid2c_miter.cpp \
    > $M/build.log 2>&1 || { echo "vid2c: build failed ($M/build.log)"; exit 1; }
  echo "built $M/obj$B/V" ;;
run) B=0; case "${3:-}" in 0|1) B=$3; shift ;; esac; shift 2; env "$@" $M/obj$B/V ;;
esac
