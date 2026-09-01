#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Differential trace: our i960 against MAME, on the real Daytona program ROM.
#
#   tools/i960-diff.sh [ms] [set]
#
# This is the test that no reference this project wrote can substitute for. The
# lockstep harness proves the module agrees with a transcription of MAME on an
# instruction mix this project chose; this proves it agrees with MAME on the mix
# the GAME chose, from the boot vector onward.
#
# WHAT IT COMPARES, AND WHAT IT DOES NOT
#
# Program counters, in order, with loops NOT collapsed — tools/i960-trace.sh
# refuses a trace containing collapse markers, and study R15 records the three
# wrong figures that came from traces that did. Model 1's `9b3b70a` records the
# other half of that trap: a COLLAPSED trace can report IDENTICAL for tens of
# thousands of instructions while one side is wedged in a loop the other does
# not have, because collapsing erases exactly that difference. Raw streams here,
# for that reason.
#
# It does NOT compare data. Two runs can agree on every PC and disagree on every
# value; a store to the wrong address shows up only when the PC stream finally
# reacts to it. Write-stream comparison is the next instrument, and
# docs/differential-testing.md describes it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MS="${1:-50}"
SET="${2:-daytona93}"
WORK="${M2_DIFF_OUT:-${TMPDIR:-/tmp}/m2-i960-diff}"
mkdir -p "$WORK"

command -v mame >/dev/null || { echo "mame not on PATH — skipping"; exit 0; }
[ -x "$ROOT/obj_i960_rom/Vi960_rom" ] || { echo "build first: make obj_i960_rom/Vi960_rom"; exit 1; }

"$ROOT/tools/i960-trace.sh" "$WORK/mame.tr" "$MS" "$SET"
grep -oE '^[0-9A-Fa-f]{8}' "$WORK/mame.tr" | tr 'A-F' 'a-f' > "$WORK/mame.pc"
N=$(wc -l < "$WORK/mame.pc")

# One extra instruction: MAME's tracer prints from the SECOND instruction it
# executes, ours from the boot IP. Dropping our first line aligns them, and this
# is an alignment, not a fudge — the streams match exactly afterwards.
# EXTRA ARGS, because the trace is blind past the first thing the harness
# cannot model. The DPRAM poll at 0x228240 stalls it at ~1.1M instructions --
# real hardware walks through it, the C++ dpram model does not -- so every
# divergence after that point is invisible. M2_DIFF_ARGS="+dpram=<image>"
# feeds it MAME's own dpram and lets the comparison reach further.
"$ROOT/obj_i960_rom/Vi960_rom" "+insn=$((N + 8))" "+out=$WORK/ours.raw" ${M2_DIFF_ARGS:-} >/dev/null
tail -n +2 "$WORK/ours.raw" > "$WORK/ours.pc"

python3 - "$WORK/mame.pc" "$WORK/ours.pc" <<'PY'
import sys
m = open(sys.argv[1]).read().split()
o = open(sys.argv[2]).read().split()
n = min(len(m), len(o))
i = 0
while i < n and m[i] == o[i]: i += 1
print(f"  MAME {len(m)} instructions, ours {len(o)}; compared {n}")
if i == n:
    print(f"  IDENTICAL for all {n} instructions")
    sys.exit(0)
print(f"  DIVERGES at instruction {i}")
for k in range(max(0, i - 6), min(n, i + 6)):
    mark = "  <<<" if k == i else ""
    print(f"    {k:8d}  mame={m[k]}  ours={o[k]}{mark}")
sys.exit(1)
PY
