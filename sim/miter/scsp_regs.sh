#!/usr/bin/env bash
# R1021: m2_scsp_regs old against new, every output on every clock (miter.py),
# under random stimulus (tb_scsp_regs_rand.cpp, which also compares the two
# copies' timer and interrupt state) at TIMER 0, 1 and 2, and under the whole
# SCSP's capture replay (tb_m2_scsp) with the miter in u_regs's place.
#
#   sim/miter/scsp_regs.sh <old tree> build
#   sim/miter/scsp_regs.sh <old tree> rand <TIMER> <env>...   (RR_N, RR_SEED)
#   sim/miter/scsp_regs.sh <old tree> scsp <env>...           (SCSP_CAP, SCSP_N)
set -u
O=$(cd "$1" && pwd); M=${MITER_DIR:-obj_miter_scsp_regs}; mkdir -p $M
D=rtl/sound/scsp
python3 sim/miter/miter.py m2_scsp_regs $O/$D/m2_scsp_regs.sv $D/m2_scsp_regs.sv $M >/dev/null
sed -e 's/\treturn (bad || slot_bad) ? 1 : 0;/\tt->final(); return (bad || slot_bad) ? 1 : 0;/' sim/sound/tb_m2_scsp.cpp > $M/tb_m2_scsp.cpp
grep -q 't->final(); return' $M/tb_m2_scsp.cpp || { echo "bench end not found"; exit 1; }
VFL="-Wall -Wno-DECLFILENAME -I$D -Isim/sound -Wno-fatal -Wno-UNUSEDSIGNAL -Wno-PINCONNECTEMPTY -Wno-MULTITOP -Wno-UNUSEDPARAM ${MITER_VFL:-}"
MR="$M/m2_scsp_regs_miter.sv $M/m2_scsp_regs_new.sv $M/m2_scsp_regs_old.sv"
case "$2" in
build)
  for tm in 0 1 2; do
    rm -rf $M/obj_rand$tm
    verilator --cc --exe --build -j 2 $VFL --public-flat-rw -GTIMER=$tm -CFLAGS "-O2" --top-module m2_scsp_regs --Mdir $M/obj_rand$tm -o V \
      $MR sim/miter/tb_scsp_regs_rand.cpp > $M/build_rand$tm.log 2>&1 || { echo "rand$tm: build failed ($M/build_rand$tm.log)"; exit 1; }
  done
  rm -rf $M/obj_scsp
  verilator --cc --exe --build -j 2 $VFL -CFLAGS "-O2 -std=c++17 -I$PWD/sim/sound" --top-module m2_scsp --Mdir $M/obj_scsp -o V \
    $D/m2_scsp.sv $MR $D/m2_scsp_level.sv $D/m2_scsp_cache.sv $D/m2_scsp_dsp.sv $M/tb_m2_scsp.cpp > $M/build_scsp.log 2>&1 || { echo "scsp: build failed ($M/build_scsp.log)"; exit 1; }
  cp -f $D/*.hex $M/obj_scsp/
  echo "built $M/obj_rand{0,1,2}/V $M/obj_scsp/V" ;;
rand) tm=$3; shift 3; env "$@" $M/obj_rand$tm/V ;;
scsp) shift 2; (cd $M/obj_scsp && env "$@" ./V) ;;
esac
