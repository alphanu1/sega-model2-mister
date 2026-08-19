#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Dump the 2D regions out of MAME AT A MATCHED POINT, so they can be compared
# against what our i960 built from the same ROM.
#
#   tools/m2-memdump.sh <outdir> [breakpoint] [set]
#
# WHY A BREAKPOINT AND NOT A FRAME NUMBER
#
# tools/mame_m2_tiledump.lua dumps at a frame, which is the right sync point when
# there is no CPU on our side and the state is being supplied. Here both sides
# execute, and they do NOT keep the same wall-clock: our harness has no sound
# board, so it sits in the DPRAM poll loop that MAME walks straight through.
# Comparing at "frame 2" would compare two different moments and report a
# difference that is a scheduling artifact.
#
# Breaking at an INSTRUCTION ADDRESS both sides reach gives a point that means
# the same thing on each. 0x228240 is the DPRAM poll loop Daytona's boot enters
# once it has finished writing the tilemap.
#
# MAME writes cfg/ and nvram/ outside the tree: nvram/ is ROM-derived and must
# never enter this repository, and a WARM nvram produced a false CPU-bug report
# on the Model 1 core, so it is deleted every run.

set -euo pipefail

OUT="${1:?usage: m2-memdump.sh <outdir> [breakpoint] [set]}"
BP="${2:-228240}"
SET="${3:-daytona93}"

ROMPATH="${M2_ROMPATH:-$HOME/roms/Model2}"
WORK="${M2_MAME_OUT:-${TMPDIR:-/tmp}/m2b-mame}"
SCRIPT="$(mktemp)"; trap 'rm -f "$SCRIPT"' EXIT

command -v mame >/dev/null || { echo "mame not on PATH — skipping"; exit 0; }
[ -d "$ROMPATH" ] || { echo "ROM path not found: $ROMPATH" >&2; exit 1; }

mkdir -p "$OUT" "$WORK"/{cfg,nvram,sta,snap,diff,inp,comment,share}
rm -rf "$WORK/nvram"; mkdir -p "$WORK/nvram"

{
  :
  echo "go $BP"
  echo "save $OUT/tile.bin,0x01000000,0x10000"
  echo "save $OUT/char.bin,0x01080000,0x80000"
  echo "save $OUT/palette.bin,0x01800000,0x4000"
  echo "quit"
} > "$SCRIPT"

mame "$SET" -rompath "$ROMPATH" \
  -cfg_directory "$WORK/cfg" -nvram_directory "$WORK/nvram" \
  -state_directory "$WORK/sta" -snapshot_directory "$WORK/snap" \
  -diff_directory "$WORK/diff" -input_directory "$WORK/inp" \
  -share_directory "$WORK/share" -comment_directory "$WORK/comment" \
  -sound none -video none -nothrottle -skip_gameinfo \
  -debug -debugscript "$SCRIPT" -seconds_to_run 10 >/dev/null 2>&1 || true

for f in tile char palette; do
  [ -s "$OUT/$f.bin" ] || { echo "MAME produced no $f.bin — breakpoint 0x$BP not reached?" >&2; exit 1; }
done
ls -l "$OUT"/*.bin | awk '{print "  " $9 "  " $5 " bytes"}'
