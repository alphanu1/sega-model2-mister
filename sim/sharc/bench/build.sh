#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- R1027: build tb_m2b_sharc (Verilator, memory-capped).
#   build.sh <objdir> <MAME_RND 0|1> <LOCK 0|1> [rtl dir]   (core_faults.py builds a planted copy)
#   RF_ONES=1: the core's register / stack arrays start all ones (R1028: no word depends on them)
set -eu
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
OBJ=$1; MR=$2; LK=$3
RTL=${4:-$ROOT/rtl/sharc}
SRC=("$RTL/sharc_fp_pkg.sv" "$RTL/m2b_sharc_pkg.sv" "$RTL/m2b_lutram.sv" "$RTL/m2b_sharc_xu.sv" "$RTL/sharc_fadd.sv" "$RTL/sharc_fmul.sv" "$RTL/m2b_sharc.sv")
[ "$LK" = 1 ] && SRC+=("$ROOT/sim/sharc/ref/sharc_core.sv")
mkdir -p "$OBJ"
systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=0 \
  verilator --cc --exe --build -j 2 -O2 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
  -Wno-LATCH -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT --top-module tb_m2b_sharc -GMAME_RND=$MR -GLOCK=$LK -GRF_ONES=${RF_ONES:-0} \
  -I"$ROOT/sim/sharc/ref" -Mdir "$OBJ" -CFLAGS "-O2" \
  "${SRC[@]}" "$HERE/tb_m2b_sharc.sv" "$HERE/tb_m2b_sharc.cpp" \
  > "$OBJ/build.log" 2>&1 || { grep -E "%Error" "$OBJ/build.log" | head -30; tail -5 "$OBJ/build.log"; exit 1; }
echo "built $OBJ/Vtb_m2b_sharc"
