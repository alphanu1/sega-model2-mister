#!/usr/bin/env bash
# R1030: m2_raster3d and every module under it, old against new, every
# output on every cycle, under tb_m2_raster3d at Model2.sv's 2C parameters on
# MAME's display lists (M2_R3D_LIST). The miter presents the new copy's
# outputs, so the bench's own log is the new build's: compare it with an
# old-only run (r3d.sh with NOMITER=1 from the old tree) as well.
#
#   LISTS=<list dir> sim/miter/r3d.sh <old tree> <list> ...   (from the new tree's root)
#
# NOT2C=1 builds the shared files' other configuration (LSB 3, no DDRAM
# payload, MKV_LUT 0). Extra bench options pass through the environment
# (M2_R3D_DDRBUSY, M2_R3D_DDRHOLD, M2_R3D_DDRSEED, M2_R3D_TEXLAT, ...).
# Prints, per list: painted pixels, an md5 of the PX lines, an md5 of the
# whole log less the miter's lines, and the miter's count.
set -u
O=$(cd "$1" && pwd); shift; M=obj_miter_r3d${NOT2C:+_n2c}; mkdir -p $M
MODS="m2_quad_store m2_raster_fill m2_raster_div m2_recip_rom m2_persp_recip m2_raster_band m2_span_tex m2_texel m2_texel_bl m2_texel_addr m2_texel_x2 m2_texel_cdc m2_char_x2 m2_fb_wcomb m2_fb_read"
p() { case $1 in m2_fifo_m10k) echo rtl/tgp/$1.sv;; *) echo rtl/video/$1.sv;; esac; }
MEM="rtl/mem/m2_ddr3_arb.sv rtl/mem/m2_ddr3.sv rtl/mem/m2_ddram_mux.sv rtl/mem/m2_ddram_payload.sv"
if [ -n "${NOMITER:-}" ]; then
  RTL="rtl/video/m2_raster3d.sv rtl/tgp/m2_fifo_m10k.sv $MEM"; for m in $MODS; do RTL="$RTL $(p $m)"; done; TB=sim/video/tb_m2_raster3d.cpp
else
  A=""; for m in $MODS m2_fifo_m10k; do A="$A $m $O/$(p $m) $(p $m)"; done
  python3 sim/miter/miter.py m2_raster3d $O/rtl/video/m2_raster3d.sv rtl/video/m2_raster3d.sv $M $A >/dev/null || exit 1
  sed -e 's/m2_raster3d__DOT__/m2_raster3d__DOT__u_new__DOT__/g' -e 's/delete d;/d->final(); delete d;/g' sim/video/tb_m2_raster3d.cpp > $M/tb.cpp
  RTL="$M/m2_raster3d_miter.sv $M/m2_raster3d_new.sv $M/m2_raster3d_old.sv $MEM"
  for m in $MODS m2_fifo_m10k; do RTL="$RTL $M/${m}_new.sv $M/${m}_old.sv"; done; TB=$M/tb.cpp
fi
G="-GLSB=5 -GDDRAM_IN=1 -GPAY_DDR3=1 -GMKV_LUT=1"; D="-DR3D_DDRAM"
[ -n "${NOT2C:-}" ] && { G="-GLSB=3 -GDDRAM_IN=0 -GPAY_DDR3=0 -GMKV_LUT=0"; D=""; }
W="-Wno-fatal -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY -Wno-VARHIDDEN -Wno-WIDTHTRUNC -Wno-MULTITOP -Wno-DECLFILENAME -Wno-TIMESCALEMOD"
rm -rf $M/obj
verilator --cc --exe --build -j 2 $W --timing -Irtl/cpu/i960 --top-module m2_raster3d --public-flat-rw --Mdir $M/obj -o V \
  -GSCR_W=496 -GSCR_H=384 -GBAND_H=8 -GNBUF=6 -GFTB=1 -GFB_DDR3=1 -GFB_WCOMB=1 -GSPLIT_TRI=1 -GPXC=1 -GPIXSTEP=4 \
  -GFRB=2 -GM2COV=1 -GUVCL=1 -GTXLATE=3 -GTXNS=4 -GTXRSP=4 -GTXK=16 -GTXLW8=1 -GTXREUSE=0 -GMIP=1 -GTWO_CLOCKS=1 \
  -GTEX_AW=26 -GTEXLUT=1 -GKW=20 -GUVSH=1 -GRECIP_M10K=0 -GQNX=512 $G \
  -CFLAGS "-O2 -I$(pwd)/sim/video -DR3D_TEXLUT -DR3D_LW8 -DR3D_FB $D" $RTL $TB > $M/build.log 2>&1 || { echo "build failed ($M/build.log)"; exit 1; }
C2=1; [ -n "${NOT2C:-}" ] && C2=
for l in "$@"; do
  L=$M/run_$(basename $l).log
  env M2_R3D_LIST=${LISTS:-.}/$l M2_R3D_FB=1 M2_R3D_REALCOL=1 M2_R3D_WINKEY=1 M2_R3D_UVSH=1 M2_R3D_FRAC=1 M2_R3D_MIPZX=3 \
      M2_R3D_TPL=2870 M2_R3D_PXDUMP=1 ${C2:+M2_R3D_C2=1} $M/obj/V > $L 2>&1
  echo "$l: exit $? | $(grep -c '^PX' $L) px, PX md5 $(grep '^PX' $L | md5sum | cut -c1-12), log md5 $(grep -v -e 'list mode' -e '^MITER' -e '^  [a-z_0-9]*: new' $L | md5sum | cut -c1-12) | $(grep -h '^MITER' $L | tail -1)"
done
