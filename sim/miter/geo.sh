#!/usr/bin/env bash
# R952: m2_geometry (with m2_geo_clip, m2_geo_project, m2_geo_engine) old
# against new, every output on every cycle, under tb_m2_geometry (plain and
# MIPZ) and the geometry differential's MAME walks (sim/video/geodiff_top:
# the walker, the projection and the geometry, the pool's every operand).
#
#   GD2A="<2A walk dumps>" GD="<main walk dumps>" sim/miter/geo.sh <old tree>
#
# GD2A walks run the 2A build's geometry (geodiff_2a: CRTC_Y 127, WINKEY,
# MZX, UVSH, M2GD_PRESET's coef table loaded into BOTH copies); GD walks the
# main build's. geodiff writes ours.txt into each dump directory.
set -u
O=$(cd "$1" && pwd); M=obj_miter_geo; mkdir -p $M
S=""; for m in m2_geo_clip m2_geo_project m2_geo_engine; do S="$S $m $O/rtl/video/$m.sv rtl/video/$m.sv"; done
python3 sim/miter/miter.py m2_geometry $O/rtl/video/m2_geometry.sv rtl/video/m2_geometry.sv $M $S >/dev/null
for tb in tb_m2_geometry tb_m2_geodiff; do
  sed -e 's/m2_geometry__DOT__/m2_geometry__DOT__u_new__DOT__/g' -e 's/u_geometry__DOT__/u_geometry__DOT__u_new__DOT__/g' \
      -e 's/delete d;/d->final(); delete d;/g' sim/video/$tb.cpp > $M/$tb.cpp
done
sed -i 's/{ d->rootp->geodiff_top__DOT__u_geometry__DOT__u_new__DOT__ct\[k++\] = (w >> 19) \& 0xfff;/{ d->rootp->geodiff_top__DOT__u_geometry__DOT__u_old__DOT__ct[k] = (w >> 19) \& 0xfff; d->rootp->geodiff_top__DOT__u_geometry__DOT__u_new__DOT__ct[k++] = (w >> 19) \& 0xfff;/' $M/tb_m2_geodiff.cpp
W="-Wno-fatal -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY -Wno-DECLFILENAME -Wno-UNOPTFLAT -Wno-TIMESCALEMOD -Wno-WIDTHTRUNC -Wno-MULTITOP"
GEO="$M/m2_geometry_miter.sv $M/m2_geometry_new.sv $M/m2_geometry_old.sv"
for m in m2_geo_clip m2_geo_project m2_geo_engine; do GEO="$GEO $M/${m}_new.sv $M/${m}_old.sv"; done
GEO="$GEO rtl/video/m2_geo_xform.sv rtl/video/m2_fp_pool.sv rtl/video/fp_to_int.sv rtl/tgp/fp_mul.sv rtl/tgp/fp_add.sv rtl/tgp/fp_div.sv"
WALK="sim/video/geodiff_top.sv rtl/video/m2_geo.sv rtl/video/m2_geo_view.sv rtl/tgp/m2_fifo_m10k.sv"
b() { local n=$1; shift; rm -rf $M/obj_$n
  verilator --cc --exe --build -j 0 $W --public-flat-rw --flatten -Irtl/tgp -Irtl/video --Mdir $M/obj_$n -o V "$@" > $M/build_$n.log 2>&1 || echo "$n: build failed ($M/build_$n.log)"; }
b geo --top-module m2_geometry -CFLAGS "-O2" $GEO $M/tb_m2_geometry.cpp &
b geomz --top-module m2_geometry -GMIPZ=1 -CFLAGS "-O2 -DTB_MIPZ" $GEO $M/tb_m2_geometry.cpp &
b gd2a --top-module geodiff_top -GCRTC_Y=127 -GWINKEY=1 -GMZX=1 -GUVSH=1 -CFLAGS "-O2" $WALK $GEO $M/tb_m2_geodiff.cpp &
b gd --top-module geodiff_top -CFLAGS "-O2" $WALK $GEO $M/tb_m2_geodiff.cpp &
wait
r() { local n=$1 lab=$2; shift 2; [ -x $M/obj_$n/V ] || return; env "$@" $M/obj_$n/V > $M/run_$lab.log 2>&1
      echo "$lab: exit $? | $(grep -hE 'PASS|FAIL|pool hash' $M/run_$lab.log | tail -1) | $(grep -h '^MITER' $M/run_$lab.log | tail -1)"; }
r geo geo X=1 & r geomz geomz X=1 &
for w in ${GD2A:-}; do r gd2a "$(basename $w)" M2GD_DIR=$w M2GD_STATE=1 M2GD_PRESET=1 M2GD_POOLHASH=1 & done
for w in ${GD:-}; do r gd "$(basename $w)" M2GD_DIR=$w M2GD_STATE=1 M2GD_POOLHASH=1 & done
wait
