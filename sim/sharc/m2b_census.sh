#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R1023: a Model 2B game's SHARC program and its pacing, from MAME 0.289 with
# sim/sharc/mame_m2b_census.patch applied (headless, -nodrc: the recompiler
# bypasses the hooks). Everything written is ROM-derived and stays outside
# the repository.
#
#   m2b_census.sh <set> <outdir> <seconds> [extra MAME args]
#
# Environment (all optional; see the patch's header):
#   M2B_MAME     the patched binary (default sm2-builds/mame-m2b/m2lod)
#   M2B_SPIN     hex PCs counted as waiting (from a first run's pc.txt)
#   M2B_PACE=1 M2B_SHARC_HZ=80000000 M2B_CPI=<clk a word> | M2B_COSTF=<file>
#                the SHARC charged a small core's clocks, at clk_sys
#   M2B_I960_HZ  the i960's clock (25 MHz in MAME), for the core's slower i960
#   PL_GAME / PL_COIN / PL_TEND  sim/io/mame_m2_2a_play.lua's session (dig = DOA)
#   M2B_LUA      the autoboot script (default sim/sharc/mame_m2b_i960.lua, which
#                logs the i960's 2B-only accesses to <outdir>/i960.txt over it)
set -u
G=$1; O=$2; T=$3; shift 3
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MAME=${M2B_MAME:-/home/ben/source/sega-model2-mister/sm2-builds/mame-m2b/m2lod}
mkdir -p "$O"/{cfg,nv,sta,snap,inp,share,comment}
cd "$O"
export M2B_CENSUS=$O
export M2B_I960_LOG=${M2B_I960_LOG:-$O/i960.txt}
LUA=${M2B_LUA:-$HERE/mame_m2b_i960.lua}
export PL_GAME=${PL_GAME:-dig} PL_TEND=${PL_TEND:-$T} PL_COIN=${PL_COIN:-}
"$MAME" "$G" -rompath "/home/ben/roms/Model2;/home/ben/roms" -nodrc \
  -cfg_directory "$O/cfg" -nvram_directory "$O/nv" -state_directory "$O/sta" \
  -snapshot_directory "$O/snap" -input_directory "$O/inp" \
  -share_directory "$O/share" -comment_directory "$O/comment" \
  -sound none -video none -nothrottle -skip_gameinfo -seconds_to_run "$T" \
  -autoboot_script "$LUA" "$@" > "$O/run.log" 2>&1
echo "exit $?" >> "$O/run.log"
