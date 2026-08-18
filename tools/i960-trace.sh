#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Produce an i960 instruction trace from MAME that is safe to count.
#
#   tools/i960-trace.sh <out.tr> [ms] [set]
#
# WHY THIS EXISTS, AND WHY IT VERIFIES INSTEAD OF ASSUMING
#
# Every i960 trace taken before 2026-08-18 was made with `trace file,:maincpu`
# and NO loop flag, so MAME collapsed loops and printed "(loops for N
# instructions)" in place of the bodies. Those traces hid 77-85% of the
# instructions that executed, and three figures were derived from them and are
# wrong -- see study R15. Model 1's docs/differential-testing.md warned about
# exactly this, in its first bullet, and it was read after the fact rather than
# before.
#
# So this script does not trust the flag. It counts the collapse markers in the
# output and REFUSES to return a trace containing any.
#
# Two mechanics that cost an hour and are recorded so they cost nobody else one:
#   * `gtime` is MILLISECONDS. `gtime 17` is one frame at 57.5 Hz.
#   * A LONG `gtime` in a debugscript produces no trace file at all here --
#     20000, and 4x5000 chained, both yielded nothing while `gtime 1` worked.
#     Unresolved. Settle with SETTLE_MS and expect small values to work; if you
#     need a late window, take it with a Lua frame notifier instead.
#
# MAME writes cfg/, nvram/ and friends wherever it starts. Those go outside the
# tree: nvram/ is ROM-derived and must never enter this repository, and WARM
# nvram produced a false CPU-bug report on the Model 1 core. It is deleted every
# run for that reason.

set -euo pipefail

OUT_TR="${1:?usage: i960-trace.sh <out.tr> [ms] [set]}"
MS="${2:-17}"
SET="${3:-daytona93}"
SETTLE_MS="${SETTLE_MS:-0}"

ROMPATH="${M2_ROMPATH:-$HOME/roms/Model2}"
WORK="${M2_MAME_OUT:-${TMPDIR:-/tmp}/m2b-mame}"
SCRIPT="$(mktemp)"; trap 'rm -f "$SCRIPT"' EXIT

[ -d "$ROMPATH" ] || { echo "ROM path not found: $ROMPATH" >&2; exit 1; }
command -v mame >/dev/null || { echo "mame not on PATH" >&2; exit 1; }

mkdir -p "$WORK"/{cfg,nvram,sta,snap,diff,inp,comment,share}
rm -rf "$WORK/nvram"; mkdir -p "$WORK/nvram"      # never boot warm

{
  [ "$SETTLE_MS" -gt 0 ] && echo "gtime $SETTLE_MS"
  # THE THIRD ARGUMENT IS THE WHOLE POINT. Without it MAME collapses loops.
  echo "trace $OUT_TR,:maincpu,noloop"
  echo "gtime $MS"
  echo "trace off"
  echo "quit"
} > "$SCRIPT"

rm -f "$OUT_TR"
# Runtime bound generously above the requested window; MAME counts emulated
# seconds and the debugger adds its own overhead.
RUN_S=$(( (SETTLE_MS + MS) / 1000 + 5 ))

mame "$SET" -rompath "$ROMPATH" \
  -cfg_directory "$WORK/cfg" -nvram_directory "$WORK/nvram" \
  -state_directory "$WORK/sta" -snapshot_directory "$WORK/snap" \
  -diff_directory "$WORK/diff" -input_directory "$WORK/inp" \
  -share_directory "$WORK/share" -comment_directory "$WORK/comment" \
  -sound none -video none -nothrottle -skip_gameinfo \
  -debug -debugscript "$SCRIPT" -seconds_to_run "$RUN_S" \
  >/dev/null 2>&1 || true

[ -s "$OUT_TR" ] || {
  echo "FAIL: no trace produced. If SETTLE_MS is large, that is the known cause" >&2
  echo "      (see the header). Try SETTLE_MS=0." >&2
  exit 1; }

COLLAPSED=$(grep -c 'loops for' "$OUT_TR" || true)
if [ "$COLLAPSED" -ne 0 ]; then
  echo "FAIL: $COLLAPSED loop-collapse markers in $OUT_TR." >&2
  echo "      The noloop flag did not take. This trace CANNOT be counted --" >&2
  echo "      it is the defect that produced study R15." >&2
  exit 1
fi

N=$(grep -cE '^[0-9A-F]{8}:' "$OUT_TR")
echo "$OUT_TR: $N instructions over ${MS} ms  ($(( N / (MS>0?MS:1) )) per ms, \
$(awk -v n="$N" -v m="$MS" 'BEGIN{printf "%.2f", n/m/1000}') M instr/s)  \
[0 collapse markers, verified]"
