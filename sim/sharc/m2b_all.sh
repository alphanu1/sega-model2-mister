#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R1024: the census over every Model 2B set, one session each: attract to the
# coin (PL_COIN, default 60 s), then play to <seconds>, a snapshot every 20 s.
#   m2b_all.sh <outbase> <seconds> [jobs] [set ...]
# The play mode per set is sim/io/mame_m2_2a_play.lua's (dig = stick and
# buttons; vcop2 = the gun / analog aim; orev = wheel and pedals, start on
# IN0 bit 6). ROM-derived output, outside the repository.
set -u
B=$1; T=$2; J=${3:-4}; shift 3 || shift $#
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
declare -A MODE=( [vstriker]=dig [fvipers]=dig [gunblade]=vcop2 [von]=dig [schamp]=dig
  [lastbrnx]=dig [sgt24h]=orev [indy500]=orev [powsled]=dig [powsledr]=dig [dynabb]=dig
  [dynabb97]=dig [rchase2]=vcop2 [pltkids]=dig [dynamcopb]=dig [doa]=dig [zerogun]=zg )
SETS=${*:-vstriker fvipers gunblade von schamp lastbrnx sgt24h indy500 powsled powsledr dynabb dynabb97 rchase2 pltkids dynamcopb}
export M2B_ROMPATH=${M2B_ROMPATH:-"/run/media/ssddata/roms/mame/MAME 0.232 ROMs (split);/home/ben/roms/Model2;/home/ben/roms"}
for g in $SETS; do
  while [ "$(jobs -rp | wc -l)" -ge "$J" ]; do wait -n; done
  ( PL_GAME=${MODE[$g]:-dig} PL_COIN=${PL_COIN:-60} PL_SNAP=20 "$HERE/m2b_census.sh" "$g" "$B/$g" "$T" ) &
done
wait
