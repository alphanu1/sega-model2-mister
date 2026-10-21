#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# link_framesync over a long run (study R916, addendum 3): every cabinet at
# the arcade's 57.5244 Hz (16 MHz / 656 / 424 -- the core's video timing and
# the recomp's kArcadeFrameHz), the recomp on its own pacer (recomp/app/
# pacing.cpp, Clock mode on a 60 Hz display), framesync 0 and 1, and one pair
# with the recomp 0.2% fast. Prints each cabinet's skew: its linked frame
# less the sender's linked frame in the block it took (how many frames apart
# they run, the frame the data takes to cross included). Not judged here --
# read it. Every pair also reports torn and late blocks.
#
#   test/run_framesync_long.sh [SECONDS]      (default 120)
set -u
cd "$(dirname "$0")/.."
B=build/x86
SECS=${1:-120}; SP="--spin-us 2000"
W=$(mktemp -d "${TMPDIR:-/tmp}/m2link-fs.XXXXXX")
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
mister() { # name listen next role car fs [extra core_model args]
  local n=$1 lp=$2 nx=$3 role=$4 car=$5 fs=$6; shift 6
  printf 'link_port = %s\nlink_next = 127.0.0.1:%s\nlink_framesync = %s\n' $lp $nx $fs > $W/$n.ini
  : > $W/$n.mem; truncate -s 45056 $W/$n.mem
  $B/core_model --mem $W/$n.mem --$role --car $car --seconds $SECS --hz 57.5244 $SP "$@" > $W/$n.core 2>&1 &
  $B/m2link -c $W/$n.ini --mem $W/$n.mem --seconds $((SECS+1)) > $W/$n.log 2>&1 &
}
recomp() { # name listen next role car fs [extra recomp_peer args]
  local n=$1 lp=$2 nx=$3 role=$4 car=$5 fs=$6; shift 6
  local f=""; [ $fs = 1 ] && f=--framesync
  $B/recomp_peer --listen $lp --next 127.0.0.1:$nx --$role --car $car --seconds $SECS $f $SP "$@" > $W/$n.core 2>&1 &
}
recomp A1 17001 17002 master 1 0; recomp A2 17002 17001 slave 2 0
recomp B1 17011 17012 master 1 1; recomp B2 17012 17011 slave 2 1
mister C1 17021 17022 master 1 0; recomp C2 17022 17021 slave 2 0
mister D1 17031 17032 master 1 1; recomp D2 17032 17031 slave 2 1
mister E1 17041 17042 master 1 1; mister E2 17042 17041 slave 2 1
mister F1 17051 17052 master 1 1; recomp F2 17052 17053 slave 2 1; mister F3 17053 17051 slave 3 1
recomp G1 17061 17062 master 1 1; mister G2 17062 17061 slave 2 1
mister H1 17071 17072 master 1 0; recomp H2 17072 17071 slave 2 0 --hz 57.6395
mister I1 17081 17082 master 1 1; recomp I2 17082 17081 slave 2 1 --hz 57.6395
wait
desc() { case $1 in
  A) echo "recomp + recomp, framesync 0";; B) echo "recomp + recomp, framesync 1 (the reference)";;
  C) echo "MiSTer master + recomp, framesync 0";; D) echo "MiSTer master + recomp, framesync 1";;
  E) echo "MiSTer + MiSTer, framesync 1";; F) echo "three: MiSTer, recomp, MiSTer, framesync 1";;
  G) echo "recomp master + MiSTer, framesync 1";; H) echo "MiSTer + recomp 0.2% fast, framesync 0";;
  I) echo "MiSTer + recomp 0.2% fast, framesync 1";; esac; }
for p in A B C D E F G H I; do
  echo "== $(desc $p)"
  for n in $W/$p?.core; do
    echo "    $(basename $n .core): $(grep -h 'frames ' $n | tail -1 | sed 's#^[^:]*:[^:]*: ##; s#core:[^:]*: ##') $(grep -h 'held ' $n | sed 's#^core:[^:]*: ##')"
  done
done
