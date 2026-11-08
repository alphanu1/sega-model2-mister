#!/usr/bin/env bash
# R989: Direct Video at 24 kHz -- what video_calc (and so MiSTer Main's DV1 info frame) measures, native CE_PIXEL
# against the 1-in-5 one, every phase. From anywhere: sim/video/run_dv24_vcalc.sh   (OBJ_DIR sets the build dir)
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
obj="${OBJ_DIR:-/tmp/dv24_vcalc_obj}"
cd "$root"
rm -rf "$obj"; mkdir -p "$obj"
verilator --binary --timing -j 2 -Wno-fatal -Wno-lint -Wno-style --top-module tb_dv24_vcalc --Mdir "$obj" \
  sim/video/tb_dv24_vcalc.sv rtl/video/m2_video_timing.sv sys/hps_io.sv -o tb > "$obj/build.log" 2>&1 \
  || { tail -30 "$obj/build.log"; exit 1; }
"$obj/tb" | grep -E "sel|FAIL|PASS|native|note"
