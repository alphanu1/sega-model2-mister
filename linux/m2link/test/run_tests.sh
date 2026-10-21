#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# m2link against the recomp's own link code, on this PC (study R916).
#
# Each MiSTer cabinet is m2link plus core_model (the core's side of the page,
# in a file standing for DDR3); each recomp cabinet is recomp_peer (the
# recomp's CommBoard and TcpLink, verbatim). Every cabinet runs the fake game
# at 57.5 Hz on localhost ports. A test passes when every cabinet reports the
# link up with the right numbering and took whole blocks from the cabinet
# before it in nearly every linked frame, none of them torn.
#
#   test/run_tests.sh [SECONDS]        (from linux/m2link, after make)
#   ARM=1 test/run_tests.sh            the MiSTer build (build/arm/m2link,
#                                      after make arm) under qemu-arm, in
#                                      the m2link-armcc container
set -u
cd "$(dirname "$0")/.."
B=build/x86
SECS=${1:-10}
W=$(mktemp -d "${TMPDIR:-/tmp}/m2link-test.XXXXXX")
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
PASS=0; FAIL=0
port=15400

# mister NAME LISTEN NEXT ROLE CAR [extra core_model args]
mister() {
  local n=$1 lp=$2 nx=$3 role=$4 car=$5; shift 5
  printf 'link_port = %s\nlink_next = %s\n' "$lp" "$nx" > "$W/$n.ini"
  : > "$W/$n.mem"; truncate -s 20480 "$W/$n.mem"
  "$B/core_model" --mem "$W/$n.mem" --$role --car "$car" --seconds "$SECS" "$@" > "$W/$n.core" 2>&1 &
  if [[ "${ARM:-0}" == 1 ]]; then
    docker run --rm --network host -u "$(id -u):$(id -g)" -v "$W:$W" -v "$PWD:/src" -w /src m2link-armcc:bookworm \
      qemu-arm build/arm/m2link -c "$W/$n.ini" --mem "$W/$n.mem" --seconds "$((SECS + 2))" ${LINKARGS:-} > "$W/$n.log" 2>&1 &
  else
    "$B/m2link" -c "$W/$n.ini" --mem "$W/$n.mem" --seconds "$((SECS + 1))" ${LINKARGS:-} > "$W/$n.log" 2>&1 &
  fi
}
# recomp NAME LISTEN NEXT ROLE CAR [extra]
recomp() {
  local n=$1 lp=$2 nx=$3 role=$4 car=$5; shift 5
  "$B/recomp_peer" --listen "$lp" --next "$nx" --$role --car "$car" --seconds "$SECS" "$@" > "$W/$n.core" 2>&1 &
}

# expect NAME ID COUNT: the cabinet's fake game saw id/count, took >= 90% of
# its linked frames' slots whole, and none torn.
expect() {
  local n=$1 id=$2 cnt=$3 line
  line=$(grep -h "frames " "$W/$n.core" | tail -1)
  local got_id got_cnt linked ok torn
  got_id=$(sed -n 's/.* id \([0-9]*\) of \([0-9]*\).*/\1/p' <<<"$line")
  got_cnt=$(sed -n 's/.* id \([0-9]*\) of \([0-9]*\).*/\2/p' <<<"$line")
  linked=$(sed -n 's/.* linked \([0-9]*\) .*/\1/p' <<<"$line")
  ok=$(sed -n 's/.* rx ok \([0-9]*\) .*/\1/p' <<<"$line")
  torn=$(sed -n 's/.* torn \([0-9]*\) .*/\1/p' <<<"$line")
  if [[ "$got_id" == "$id" && "$got_cnt" == "$cnt" && "${linked:-0}" -gt 100 && "${torn:-1}" == 0 &&
        $(( ${ok:-0} * 10 )) -ge $(( linked * 9 )) ]]; then
    echo "    ok   $n: $line"
  else
    echo "    FAIL $n (want id $id of $cnt): $line"
    [[ -f "$W/$n.log" ]] && sed 's/^/         | /' "$W/$n.log" | tail -8
    return 1
  fi
}

run() { # NAME: the cabinets have been started; wait, then check
  local name=$1; shift
  wait
  local bad=0
  echo "== $name"
  while [[ $# -gt 0 ]]; do expect "$1" "$2" "$3" || bad=1; shift 3; done
  if [[ $bad == 0 ]]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
}

a=$((port++)); b=$((port++))
mister m1 $a 127.0.0.1:$b master 1
recomp r1 $b 127.0.0.1:$a slave 2
run "MiSTer master, recomp slave" m1 1 2 r1 2 2

a=$((port++)); b=$((port++))
recomp r2 $a 127.0.0.1:$b master 1
mister m2 $b 127.0.0.1:$a slave 2
run "recomp master, MiSTer slave" r2 1 2 m2 2 2

a=$((port++)); b=$((port++))
mister m3 $a 127.0.0.1:$b master 1
mister m4 $b 127.0.0.1:$a slave 2
run "MiSTer master, MiSTer slave" m3 1 2 m4 2 2

a=$((port++)); b=$((port++)); c=$((port++))
mister m5 $a 127.0.0.1:$b master 1
recomp r5 $b 127.0.0.1:$c slave 2
mister m6 $c 127.0.0.1:$a slave 3
# Numbering runs against the ring: the cabinet the master sends to is the
# last (id 3 of 3), the one after it 2 -- the 0xfe token counts down.
run "three: MiSTer master, recomp slave, MiSTer slave" m5 1 3 r5 3 3 m6 2 3

a=$((port++)); b=$((port++)); c=$((port++))
recomp r7 $a 127.0.0.1:$b master 1
mister m7 $b 127.0.0.1:$c slave 2
recomp r8 $c 127.0.0.1:$a slave 3
run "three: recomp master, MiSTer slave, recomp slave" r7 1 3 m7 3 3 r8 2 3

a=$((port++)); b=$((port++)); c=$((port++))
recomp r11 $a 127.0.0.1:$b master 1
recomp r12 $b 127.0.0.1:$c slave 2
recomp r13 $c 127.0.0.1:$a slave 3
run "three recomp cabinets (the reference's own numbering)" r11 1 3 r12 3 3 r13 2 3

a=$((port++)); b=$((port++))
mister m9 $a 127.0.0.1:$b master 1
recomp r9 $b 127.0.0.1:$a slave 2 --framesync
run "MiSTer master, recomp slave with link_framesync=1" m9 1 2 r9 2 2

# THE HAND-OVER UNDER LOAD: every access to the core's page made to take
# 2 us (a DDR3 round trip is ~0.3-0.6 us on the board; this is past it), so
# the game spends ~1 ms a frame in the slot and its block -- the window in
# which a board running beside it could write the one or copy the other.
a=$((port++)); b=$((port++))
mister m14 $a 127.0.0.1:$b master 1 --access-ns 2000
mister m15 $b 127.0.0.1:$a slave 2 --access-ns 2000
run "MiSTer + MiSTer, every access 2 us" m14 1 2 m15 2 2

a=$((port++)); b=$((port++))
mister m16 $a 127.0.0.1:$b master 1 --access-ns 2000
recomp r16 $b 127.0.0.1:$a slave 2
run "MiSTer master (2 us accesses), recomp slave" m16 1 2 r16 2 2

# And the same with the hand-over switched off (m2link --no-hold), to show
# what it is for: torn blocks are expected here, and reported, not failed.
a=$((port++)); b=$((port++))
LINKARGS=--no-hold mister m17 $a 127.0.0.1:$b master 1 --access-ns 2000
LINKARGS=--no-hold mister m18 $b 127.0.0.1:$a slave 2 --access-ns 2000
wait
echo "== for comparison, the hand-over off (--no-hold), every access 2 us: torn blocks expected"
for n in m17 m18; do echo "    info $n: $(grep -h "frames " "$W/$n.core" | tail -1 | sed 's#core:[^:]*: ##')"; done

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
