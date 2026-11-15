#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- R1028: build tb_m2b_xu (Verilator, memory-capped).
#   build.sh <objdir> [rtl dir]
set -eu
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
OBJ=$1; RTL=${2:-$ROOT/rtl/sharc}
mkdir -p "$OBJ"
systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=0 \
  verilator --cc --exe --build -j 2 -O2 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
  -Wno-CASEINCOMPLETE --top-module tb_m2b_xu -Mdir "$OBJ" -CFLAGS "-O2" \
  "$RTL/sharc_fp_pkg.sv" "$RTL/m2b_sharc_pkg.sv" "$RTL/m2b_sharc_xu.sv" "$HERE/tb_m2b_xu.sv" "$HERE/tb_m2b_xu.cpp" \
  > "$OBJ/build.log" 2>&1 || { grep -E "%Error" "$OBJ/build.log" | head -30; tail -5 "$OBJ/build.log"; exit 1; }
echo "built $OBJ/Vtb_m2b_xu"
