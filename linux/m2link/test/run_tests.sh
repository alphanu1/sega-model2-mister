#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# m2link against the recomp's own link code, on this PC (study R916).
#
# Each MiSTer cabinet is m2link plus core_model (the core's side of the page,
# rtl/io/m2_comm.sv's contract, in a file standing for DDR3); each recomp
# cabinet is recomp_peer (the recomp's CommBoard and TcpLink, verbatim).
# Every cabinet runs the fake game (test/fake_game.h) on localhost ports.
#
# A cabinet passes when its game saw the link up with the right numbering,
# took a whole, NEW block on nearly every linked frame (0 torn; a "repeat" is
# a flip that brought no new frame -- late), and, where asked, stayed within
# a few frames of the cabinet before it (the skew: link_framesync).
#
#   test/run_tests.sh [SECONDS]        (from linux/m2link, after make)
#   ARM=1 test/run_tests.sh            the MiSTer build (build/arm/m2link,
#                                      after make arm) under qemu-arm, in
#                                      the m2link-armcc container
set -u
cd "$(dirname "$0")/.."
B=build/x86
SECS=${1:-12}
W=$(mktemp -d "${TMPDIR:-/tmp}/m2link-test.XXXXXX")
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
PASS=0; FAIL=0
port=15400

# mister NAME LISTEN NEXT ROLE CAR [extra core_model args]; FS=1 for
# link_framesync = 1 in its INI
mister() {
  local n=$1 lp=$2 nx=$3 role=$4 car=$5; shift 5
  printf 'link_port = %s\nlink_next = %s\nlink_framesync = %s\n' "$lp" "$nx" "${FS:-0}" > "$W/$n.ini"
  : > "$W/$n.mem"; truncate -s 45056 "$W/$n.mem"
  "$B/core_model" --mem "$W/$n.mem" --$role --car "$car" --seconds "$SECS" "$@" > "$W/$n.core" 2>&1 &
  if [[ "${ARM:-0}" == 1 ]]; then
    docker run --rm --network host -u "$(id -u):$(id -g)" -v "$W:$W" -v "$PWD:/src" -w /src m2link-armcc:bookworm \
      qemu-arm build/arm/m2link -c "$W/$n.ini" --mem "$W/$n.mem" --seconds "$((SECS + 2))" > "$W/$n.log" 2>&1 &
  else
    "$B/m2link" -c "$W/$n.ini" --mem "$W/$n.mem" --seconds "$((SECS + 1))" > "$W/$n.log" 2>&1 &
  fi
}
# recomp NAME LISTEN NEXT ROLE CAR [extra recomp_peer args, e.g. --framesync --hz 60]
recomp() {
  local n=$1 lp=$2 nx=$3 role=$4 car=$5; shift 5
  "$B/recomp_peer" --listen "$lp" --next "$nx" --$role --car "$car" --seconds "$SECS" "$@" > "$W/$n.core" 2>&1 &
}

field() { sed -n "s/.* $1 \\([0-9]*\\).*/\\1/p" <<<"$2"; }

# expect NAME ID COUNT [MAXSKEW]: numbering, >= 90% of linked frames a new
# whole block, none torn, at most 2% late; and the skew spread if given.
expect() {
  local n=$1 id=$2 cnt=$3 maxskew=${4:-} line
  line=$(grep -h "frames " "$W/$n.core" | tail -1)
  local got_id got_cnt linked ok torn rep smin smax
  got_id=$(sed -n 's/.* id \([0-9]*\) of \([0-9]*\).*/\1/p' <<<"$line")
  got_cnt=$(sed -n 's/.* id \([0-9]*\) of \([0-9]*\).*/\2/p' <<<"$line")
  linked=$(field linked "$line"); ok=$(field "rx ok" "$line"); torn=$(field torn "$line"); rep=$(field repeat "$line")
  smin=$(sed -n 's/.* skew \([0-9]*\)\.\.\([0-9]*\).*/\1/p' <<<"$line")
  smax=$(sed -n 's/.* skew \([0-9]*\)\.\.\([0-9]*\).*/\2/p' <<<"$line")
  local good=1
  [[ "$got_id" == "$id" && "$got_cnt" == "$cnt" && "${linked:-0}" -gt 100 && "${torn:-1}" == 0 ]] || good=0
  [[ $(( ${ok:-0} * 10 )) -ge $(( ${linked:-0} * 9 )) && $(( ${rep:-0} * 50 )) -le ${linked:-0} ]] || good=0
  if [[ -n "$maxskew" ]]; then [[ -n "$smax" && $(( smax - smin )) -le $maxskew ]] || good=0; fi
  local extra; extra=$(grep -h "held " "$W/$n.core" | tail -1 | sed 's#core:[^:]*: ##')
  if [[ $good == 1 ]]; then
    echo "    ok   $n: $(sed 's#core:[^:]*: ##' <<<"$line")${extra:+ | $extra}"
  else
    echo "    FAIL $n (want id $id of $cnt${maxskew:+, skew within $maxskew}): $(sed 's#core:[^:]*: ##' <<<"$line")${extra:+ | $extra}"
    [[ -f "$W/$n.log" ]] && sed 's/^/         | /' "$W/$n.log" | tail -8
    return 1
  fi
}

run() { # NAME then NAME ID COUNT MAXSKEW ... (MAXSKEW "-" for none)
  local name=$1; shift
  wait
  local bad=0
  echo "== $name"
  while [[ $# -gt 0 ]]; do
    local sk=$4; [[ "$sk" == "-" ]] && sk=""
    expect "$1" "$2" "$3" "$sk" || bad=1; shift 4
  done
  if [[ $bad == 0 ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
}
info() { # NAME...: print, do not judge
  wait
  for n in "$@"; do echo "    info $n: $(grep -h "frames " "$W/$n.core" | tail -1 | sed 's#core:[^:]*: ##')"; done
}

# ---------------------------------------------------------------- link_framesync 0
a=$((port++)); b=$((port++))
mister m1 $a 127.0.0.1:$b master 1
recomp r1 $b 127.0.0.1:$a slave 2
run "MiSTer master, recomp slave" m1 1 2 - r1 2 2 -

a=$((port++)); b=$((port++))
recomp r2 $a 127.0.0.1:$b master 1
mister m2 $b 127.0.0.1:$a slave 2
run "recomp master, MiSTer slave" r2 1 2 - m2 2 2 -

a=$((port++)); b=$((port++))
mister m3 $a 127.0.0.1:$b master 1
mister m4 $b 127.0.0.1:$a slave 2
run "MiSTer master, MiSTer slave" m3 1 2 - m4 2 2 -

# Numbering runs against the ring: the cabinet the master sends to is the
# last (id 3 of 3), the one after it 2 -- the 0xfe token counts down.
a=$((port++)); b=$((port++)); c=$((port++))
mister m5 $a 127.0.0.1:$b master 1
recomp r5 $b 127.0.0.1:$c slave 2
mister m6 $c 127.0.0.1:$a slave 3
run "three: MiSTer master, recomp slave, MiSTer slave" m5 1 3 - r5 3 3 - m6 2 3 -

a=$((port++)); b=$((port++)); c=$((port++))
recomp r7 $a 127.0.0.1:$b master 1
mister m7 $b 127.0.0.1:$c slave 2
recomp r8 $c 127.0.0.1:$a slave 3
run "three: recomp master, MiSTer slave, recomp slave" r7 1 3 - m7 3 3 - r8 2 3 -

a=$((port++)); b=$((port++)); c=$((port++))
recomp r11 $a 127.0.0.1:$b master 1
recomp r12 $b 127.0.0.1:$c slave 2
recomp r13 $c 127.0.0.1:$a slave 3
run "three recomp cabinets (the reference's own numbering)" r11 1 3 - r12 3 3 - r13 2 3 -

# THE HAND-OVER UNDER LOAD: every access to the core's page made to take
# 2 us (a DDR3 round trip is ~0.3-0.6 us on the board), so the game spends
# ~1 ms a frame in its slots and its block. 0.5 us: about the board's.
for ns in 500 2000; do
  a=$((port++)); b=$((port++))
  mister m14 $a 127.0.0.1:$b master 1 --access-ns $ns
  mister m15 $b 127.0.0.1:$a slave 2 --access-ns $ns
  run "MiSTer + MiSTer, every access $ns ns" m14 1 2 - m15 2 2 -
  a=$((port++)); b=$((port++))
  mister m16 $a 127.0.0.1:$b master 1 --access-ns $ns
  recomp r16 $b 127.0.0.1:$a slave 2
  run "MiSTer master ($ns ns accesses), recomp slave" m16 1 2 - r16 2 2 -
  a=$((port++)); b=$((port++))
  recomp r17 $a 127.0.0.1:$b master 1
  mister m17 $b 127.0.0.1:$a slave 2 --access-ns $ns
  run "recomp master, MiSTer slave ($ns ns accesses)" r17 1 2 - m17 2 2 -
done

# ---------------------------------------------------------------- link_framesync 1
# One cabinet at 60 frames/s against the others' 57.52 (a PC paced to a
# 60 Hz display). The fake game gives up its spin after 2 ms here (S): a game
# that waits for the flip as long as it takes is locked by its own spin, and
# this is about the link's lock. Free, the skew walks (~2.5 frames a second);
# with link_framesync 1 at both ends every cabinet waits each frame for the
# master's vsync token and the skew stays within a frame or two.
S="--spin-us 2000"
a=$((port++)); b=$((port++))
mister m20 $a 127.0.0.1:$b master 1 $S
recomp r20 $b 127.0.0.1:$a slave 2 --hz 60 $S
echo "== for comparison, link_framesync 0, the recomp slave at 60 Hz: the skew walks"
info m20 r20

a=$((port++)); b=$((port++))
FS=1 mister m21 $a 127.0.0.1:$b master 1 $S
recomp r21 $b 127.0.0.1:$a slave 2 --hz 60 --framesync $S
run "link_framesync 1 both ends: MiSTer master, recomp slave at 60 Hz -- held together" m21 1 2 3 r21 2 2 3

a=$((port++)); b=$((port++))
recomp r22 $a 127.0.0.1:$b master 1 --framesync --hz 60 $S
FS=1 mister m22 $b 127.0.0.1:$a slave 2 $S
run "link_framesync 1 both ends: recomp master at 60 Hz, MiSTer slave" r22 1 2 3 m22 2 2 3

a=$((port++)); b=$((port++))
FS=1 mister m23 $a 127.0.0.1:$b master 1 --hz 60 $S
FS=1 mister m24 $b 127.0.0.1:$a slave 2 $S
run "link_framesync 1: MiSTer master at 60 Hz, MiSTer slave" m23 1 2 3 m24 2 2 3

a=$((port++)); b=$((port++)); c=$((port++))
FS=1 mister m25 $a 127.0.0.1:$b master 1 $S
recomp r25 $b 127.0.0.1:$c slave 2 --framesync --hz 60 $S
FS=1 mister m26 $c 127.0.0.1:$a slave 3 --access-ns 500 $S
run "link_framesync 1, three: MiSTer master, recomp slave (60 Hz), MiSTer slave" m25 1 3 3 r25 3 3 3 m26 2 3 3

a=$((port++)); b=$((port++))
FS=1 mister m27 $a 127.0.0.1:$b master 1 --access-ns 2000 $S
recomp r27 $b 127.0.0.1:$a slave 2 --framesync $S
run "link_framesync 1, MiSTer master with 2 us accesses, recomp slave" m27 1 2 3 r27 2 2 3

# The core going away (another core loaded): m2link closes the link and
# the recomp cabinet sees it lost, as it would a cabinet switched off.
a=$((port++)); b=$((port++))
mister m10 $a 127.0.0.1:$b master 1 --stop-at $((SECS - 3))
recomp r10 $b 127.0.0.1:$a slave 2
wait
echo "== the MiSTer core stops: the link is lost at the far end"
if grep -q "the core has stopped answering" "$W/m10.log" && grep -q "recomp:$b: lost" "$W/r10.core"; then
  echo "    ok   m2link closed the link; recomp: $(grep "recomp:$b: lost" "$W/r10.core")"; PASS=$((PASS + 1))
else
  echo "    FAIL"; sed 's/^/         | /' "$W/m10.log" | tail -5; tail -3 "$W/r10.core"; FAIL=$((FAIL + 1))
fi

echo "== $PASS passed, $FAIL failed"
[[ $FAIL == 0 ]]
