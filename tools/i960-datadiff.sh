#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# The DATA half of the differential test.
#
#   tools/i960-datadiff.sh [breakpoint] [set]
#
# tools/i960-diff.sh compares program counters, and a PC comparison proves
# nothing about values: two runs can agree on every instruction and disagree on
# every store, because a wrong store only changes the PC stream if the program
# later reads it back and branches on it. It may never.
#
# This runs the real ROM through our i960 and through MAME to the SAME
# instruction address, dumps the three regions the 2D path reads, and compares
# them byte for byte:
#
#   0x01000000 +0x010000   tile RAM   -- the tilemap layout
#   0x01080000 +0x080000   char RAM   -- the glyph data
#   0x01800000 +0x004000   palette
#
# Matching here means the pixels the renderer will be handed are the right
# pixels, with no CPU-side doubt left in the 2D chain.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BP="${1:-228240}"
SET="${2:-daytona93}"
WORK="${M2_DIFF_OUT:-${TMPDIR:-/tmp}/m2-i960-diff}"

command -v mame >/dev/null || { echo "mame not on PATH — skipping"; exit 0; }
[ -x "$ROOT/obj_i960_rom/Vi960_rom" ] || { echo "build first: make obj_i960_rom/Vi960_rom"; exit 1; }

mkdir -p "$WORK/ours" "$WORK/mame"

# Ours runs well past the breakpoint and stops in the same poll loop: there is no
# sound board here, so nothing ever answers the DPRAM. That is fine for this
# comparison -- the boot's writes are all complete by then, and the regions do
# not change while it polls.
"$ROOT/obj_i960_rom/Vi960_rom" +insn=2000000 "+dump=$WORK/ours" >/dev/null

"$ROOT/tools/m2-memdump.sh" "$WORK/mame" "$BP" "$SET" >/dev/null

rc=0
for f in tile char palette; do
  printf '  %-9s ' "$f"
  if cmp -s "$WORK/ours/$f.bin" "$WORK/mame/$f.bin"; then
    echo "IDENTICAL ($(stat -c%s "$WORK/mame/$f.bin") bytes)"
  else
    n=$(cmp -l "$WORK/ours/$f.bin" "$WORK/mame/$f.bin" 2>/dev/null | wc -l)
    echo "DIFFERS in $n of $(stat -c%s "$WORK/mame/$f.bin") bytes"
    cmp -l "$WORK/ours/$f.bin" "$WORK/mame/$f.bin" 2>/dev/null | head -8 |
      awk '{printf "      offset %8d  ours=%s mame=%s\n", $1-1, $2, $3}'
    rc=1
  fi
done
exit $rc
