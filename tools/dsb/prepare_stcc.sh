#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# Inputs for STCC's Digital Sound Board benches (study R979), into
# build/rom/dsb/ (git-ignored -- ROM-derived, never committed):
#   epr-19275.2s  the DSB Z80 program        mpeg.bin  mpr-19262..19265, 8 MB
#   cap300.txt    MAME's 300 s of the board's traffic (MAME=1; ~6 minutes)
#   z80.asm       MAME's disassembly of the program (MAME=1)
#
#   tools/dsb/prepare_stcc.sh ~/roms/Model2/stcc.zip [MAME=1]
#   then: python3 tools/dsb/z80_census.py build/rom/dsb/z80.asm 02e0 02e6 032d 034f 0498 04a3 04ab 04c0
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
zip="${1:?usage: prepare_stcc.sh <stcc.zip>}"
out="$here/build/rom/dsb"; mkdir -p "$out" "$here/build/tmp"
tmp="$(mktemp -d "$here/build/tmp/dsb.XXXXXX")"
unzip -q -o "$zip" epr-19275.2s mpr-19262.57s mpr-19263.58s mpr-19264.59s mpr-19265.60s -d "$tmp"
cp "$tmp/epr-19275.2s" "$out/"
cat "$tmp/mpr-19262.57s" "$tmp/mpr-19263.58s" "$tmp/mpr-19264.59s" "$tmp/mpr-19265.60s" > "$out/mpeg.bin"
rm -rf "$tmp"
md5sum "$out/epr-19275.2s" "$out/mpeg.bin"   # f40ed524..., cc3e649a...
if [ "${MAME:-0}" = 1 ]; then
  ( cd "$here/build/tmp" && DSBCAP_SECS=300 DSBCAP_COIN=150 DSBCAP_OUT="$out/cap300.txt" \
    mame stcc -rompath "$(dirname "$zip")" -video none -sound none -nothrottle \
      -skip_gameinfo -autoboot_delay 0 -autoboot_script "$here/tools/dsb/stcc_dsb_cap.lua" >/dev/null )
  printf 'local d=false\nemu.register_frame_done(function() if d then return end d=true\n manager.machine.debugger:command("dasm %s,0,8000,1,:dsbz80:mpegcpu")\n manager.machine:exit() end)\n' \
    "$out/z80.asm" > "$here/build/tmp/dsb_dasm.lua"
  ( cd "$here/build/tmp" && mame stcc -rompath "$(dirname "$zip")" -video none -sound none -nothrottle \
      -skip_gameinfo -debug -debugger none -autoboot_delay 0 -seconds_to_run 2 \
      -autoboot_script "$here/build/tmp/dsb_dasm.lua" >/dev/null )
fi
