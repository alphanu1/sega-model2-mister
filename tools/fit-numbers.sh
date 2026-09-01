#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# The resource numbers, archived before anything can delete or stale them.
#
# Two traps this exists for. The fitter can die without rewriting its reports,
# so a summary on disk may be an hour old and read as current -- always check
# the timestamp against the clock. And the M10K BLOCK COUNT lives only in
# Model2.fit.rpt: fit.summary carries "block memory bits", which is a different
# and much rosier number (61% of bits against 82% of blocks), because a block
# used at narrow width wastes most of its capacity.
set -euo pipefail
# DEFAULT INTO THE IGNORED BUILD TREE, NOT THE REPO ROOT. This defaulted to "."
# and dropped seven fit-*.blocks files into the working copy in one session.
OUT="${1:-build/fit}"
mkdir -p "$OUT"
S=output_files/Model2.fit.summary
R=output_files/Model2.fit.rpt
[ -f "$S" ] || { echo "no fit summary -- did the fitter finish?" >&2; exit 1; }
echo "fit.summary written: $(date -r "$S" +%H:%M:%S)   now: $(date +%H:%M:%S)"
grep -E "Logic utilization|Total registers|Total DSP|block memory bits" "$S" || true
[ -f "$R" ] && grep -iE "^; *M10K blocks" "$R" | head -1 || echo "  (no fit.rpt: M10K block count unavailable)"
ts=$(date +%Y%m%d-%H%M%S)
cp -f "$S" "$OUT/fit-$ts.summary" 2>/dev/null || true
[ -f "$R" ] && grep -iE "^; *(M10K blocks|Logic utilization|Total registers)" "$R" > "$OUT/fit-$ts.blocks" 2>/dev/null || true
echo "archived to $OUT/fit-$ts.*"
