#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R920: THE MODEL 2C TGPx4 CENSUS, one MAME session per 2C set.
#
# Needs a MAME 0.289 built with sim/tgp/mame_mb86235_census.patch (the scratch
# tree sm2-builds/mame-r869 has it: its m2lod binary), and the 2C ROM sets
# (none are on this machine as of R920). Each set is played by
# sim/io/mame_m2_2a_play.lua -- attract, two coins, start, then a scripted
# player -- and the census is written to $OUT/<set>.census at exit. What the
# census decides is in docs/model2-family-hardware.md, "Sizing the two new
# processors": which instruction forms the skeleton must keep (the rest are
# dropped), the program size (on-chip store or cache), the cache's miss rate,
# and the per-frame busy fraction against the skeleton's measured throughput.
#
# The play mode per set is a first guess, NOT CHECKED on any 2C set:
#   rally  STCC and Over Rev (indy500-style STEER / ACCEL / BRAKE ports)
#   vcop2  The House of the Dead (its ports include Virtua Cop 2's)
#   dig    everything else -- coin / start / buttons only, so the analog
#          games (Wave Runner, Ski Super G, Water Ski, Top Skater, Behind
#          Enemy Lines) reach the attract and the start of play, not a race
#
#   M2C_MAME=<m2lod>  M2C_ROMPATH=<dir>  M2C_OUT=<dir>  M2C_SECS=<s>
#   sim/tgp/mame_m2c_census.sh [set ...]     (default: every 2C parent)
#
# Everything written is ROM-derived and stays outside the repository.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAME="${M2C_MAME:-$ROOT/../mame-r869/m2lod}"
ROMPATH="${M2C_ROMPATH:-$HOME/roms/Model2}"
OUT="${M2C_OUT:-${TMPDIR:-/tmp}/m2c-census}"
SECS="${M2C_SECS:-600}"

# MAME 0.289's 2C sets (model2.cpp GAME lines): parents first, then clones
SETS_ALL="stcc hotd bel waverunr skisuprg segawski topskatr overrev rascot2 dynamcopc
          stccb stcca stcco hotdo hotdp topskatru topskatruo topskatrj"

mode_of() {
  case "$1" in
    stcc*|overrev) echo rally ;;
    hotd*)         echo vcop2 ;;
    *)             echo dig ;;
  esac
}

[ -x "$MAME" ] || { echo "no census MAME at $MAME (build it with the patch)" >&2; exit 1; }
mkdir -p "$OUT"
sets="${*:-stcc hotd bel waverunr skisuprg segawski topskatr overrev rascot2 dynamcopc}"
for s in $sets; do
  d="$OUT/$s"; mkdir -p "$d/cfg" "$d/nvram"
  echo "== $s ($(mode_of "$s"), ${SECS} s)"
  ( cd "$d" && R920_OUT="$OUT/$s.census" PL_GAME="$(mode_of "$s")" PL_COIN="30,200,400" PL_TEND="$SECS" \
      "$MAME" "$s" -rompath "$ROMPATH" -cfg_directory cfg -nvram_directory nvram \
      -video none -sound none -nothrottle -skip_gameinfo -seconds_to_run "$SECS" \
      -autoboot_script "$ROOT/sim/io/mame_m2_2a_play.lua" > "$d/mame.log" 2>&1 ) \
    || echo "   MAME exited non-zero -- see $d/mame.log"
  if [ -f "$OUT/$s.census" ]; then
    grep -E "^(TOTAL|UPLOAD|PC distinct|PCACHE|BUSY|FORMS)" "$OUT/$s.census" | sed 's/^/   /'
    grep -E "^ALU .*(FLOG|FRCP|FRSQ|CIF|CFI|CFIB)|^PR_BOTH|^ABUS_EXT|^XEXT" "$OUT/$s.census" | sed 's/^/   /'
  else
    echo "   no census written (the TGPx4 never ran?)"
  fi
done
: "${SETS_ALL}"
