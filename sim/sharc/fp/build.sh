#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- R1027: build tb_sharc_fp (Verilator, memory-capped).
#   build.sh <objdir> [rtl dir]     (the rtl dir lets fp_faults.sh build a planted copy)
set -eu
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
OBJ=$1; RTL=${2:-$ROOT/rtl/sharc}
mkdir -p "$OBJ"
systemd-run --user --scope -q -p MemoryMax=8G -p MemorySwapMax=0 \
  verilator --cc --exe --build -j 2 -O2 -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
  --top-module tb_sharc_fp -Mdir "$OBJ" -CFLAGS "-O2 -I$HERE -mfpmath=sse -msse2" \
  "$RTL/sharc_fp_pkg.sv" "$RTL/sharc_fadd.sv" "$RTL/sharc_fmul.sv" "$HERE/tb_sharc_fp.sv" "$HERE/tb_sharc_fp.cpp" \
  > "$OBJ/build.log" 2>&1 || { tail -30 "$OBJ/build.log"; exit 1; }
echo "built $OBJ/Vtb_sharc_fp"
