#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R1023: the speed model run inside MAME itself. The SHARC is clocked at clk_sys
# (80 MHz) and charged K clocks a word (M2B_CPI; 2.5 = MAME's own 32 MHz chip);
# the i960 is clocked at 25 MHz / S (S = the core's i960 time per MAME i960 time,
# R1005). MAME then couples the two exactly as it always does, and the game's
# own frame (vblank to flip, one flip a vblank in DOA) says whether a SHARC
# that slow costs a frame. A model of a core, not a core: MAME's i960 and SHARC
# timings are its own.
#
#   m2b_pace.sh <set> <outbase> <seconds> "<S>:<K> <S>:<K> ..." [jobs]
# K may be @<name>=<file>: per-address clocks (sim/sharc/m2b_costmodel.py --out)
# Then: m2b_census.py frames <outbase>/s<S>_k<K> <from> <to>
set -u
G=$1; B=$2; T=$3; PAIRS=$4; J=${5:-4}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for p in $PAIRS; do
  s=${p%%:*}; k=${p##*:}
  hz=$(python3 -c "print(int(25e6 / $s))")
  while [ "$(jobs -rp | wc -l)" -ge "$J" ]; do wait -n; done
  if [ "${k#@}" != "$k" ]; then
    nm=${k#@}; nm=${nm%%=*}; cf=${k#*=}
    ( M2B_PACE=1 M2B_SHARC_HZ=80000000 M2B_COSTF=$cf M2B_I960_HZ=$hz PL_COIN=${PL_COIN-30} \
        "$HERE/m2b_census.sh" "$G" "$B/s${s}_$nm" "$T" ) &
  else
    ( M2B_PACE=1 M2B_SHARC_HZ=80000000 M2B_CPI=$k M2B_I960_HZ=$hz PL_COIN=${PL_COIN-30} \
        "$HERE/m2b_census.sh" "$G" "$B/s${s}_k${k}" "$T" ) &
  fi
done
wait
