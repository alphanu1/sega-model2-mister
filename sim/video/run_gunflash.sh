#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R929: Virtua Cop's gun flash through the picture path (tb_m2_gunflash).
#
#   sim/video/run_gunflash.sh <dump dir> [work dir]
#
# <dump dir> holds tile.bin / char.bin / palette.bin / colorxlat.bin of Virtua
# Cop in play, from sim/io/mame_m2_gunflash.lua (GF_DUMP=<frame>; R929 used
# frame 3337 of the scripted game: coin 40 s, start 41.5 s, shots 52 and 58 s).
# The dumps are game memory and stay out of the repository.
#
# The game's request lands 400 cycles into the vblank after frame 4 (where its
# vblank handler puts it), or at line 200 of frame 5 (a late handler, "mid");
# the countdown's four zero runs follow at the next four. Checked:
#   1. the core before R929 (FLASH = 0) draws the game's own flash: frame 5
#      entirely white, every other frame the picture with no request
#   2. built in, no request, any mode: every frame the picture before R929
#   3. Arcade: on time, exactly the core before R929; late, frame 5 as the core
#      before R929 (the game's own, torn at line ~200) and frame 6 entirely white
#   4. CRT gun, the bench answering as the game does (+game: the request in the
#      vblank after the frame after the press is seen): a pull at line 300 of
#      frame 2 -> the game gets it at frame 6 (held back three white frames),
#      pressed three frames; frames 3-8 entirely white (8 is the game's flash
#      frame, the aim taken at its end), the rest unchanged; a pull the game
#      does not answer -> frames 3-10 white (CMAX 8), the press as before.
#      Arcade and Off: the game gets the pull at once (frame 2, line 300)
#   5. Off: every frame the picture with no request, on time, late or pulled
#   6. the game's other use of the table (the stage-start band, rows 172-199,
#      never row 0) is not a request: every mode draws it as before R929
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DUMP="${1:?usage: run_gunflash.sh <dump dir> [work dir]}"
W="${2:-${TMPDIR:-/tmp}/m2-gunflash}"
mkdir -p "$W"
B1="${GF_B1:-$ROOT/obj_m2_gf1/Vtb_m2_gunflash_top}"   # GF_B1: another build (planted faults)
B0="$ROOT/obj_m2_gf0/Vtb_m2_gunflash_top"
run() { local b="$1" o="$2"; shift 2; "$b" +in="$DUMP" +out="$W/$o" "$@" > /dev/null; }
run "$B0" old_base +frames=10 +nreq=0
run "$B0" old_vbl  +frames=10 +req=4
run "$B0" old_mid  +frames=10 +req=4 +sc=mid
run "$B0" old_band +frames=10 +nreq=0 +band=4
for m in 0 1 2; do
  run "$B1" m${m}_base   +frames=10 +nreq=0 +mode=$m
  run "$B1" m${m}_vbl    +frames=10 +req=4 +mode=$m
  run "$B1" m${m}_mid    +frames=10 +req=4 +sc=mid +mode=$m
  run "$B1" m${m}_pull   +frames=12 +game +pull=2:300 +mode=$m
  run "$B1" m${m}_pullnr +frames=12 +nreq=0 +pull=2:300 +mode=$m
  run "$B1" m${m}_band   +frames=10 +nreq=0 +band=4 +mode=$m
done
python3 -I - "$W" <<'EOF'
import sys
w = sys.argv[1]
def frames(name):
    d = {}
    for l in open(f"{w}/{name}_sum.txt"):
        p = l.split()
        if p[0] == "frame": d[int(p[1])] = (int(p[3]), int(p[5]), p[7])
    return d
def trig(name):
    return [(l.split()[2], int(l.split()[5]), int(l.split()[7]))
            for l in open(f"{w}/{name}_sum.txt") if l.startswith("game trigger")]
fails = 0
def check(what, ok):
    global fails
    print(("  ok    " if ok else "  FAIL  ") + what)
    if not ok: fails += 1
base = frames("old_base")
H0 = base[0][2]
WHITE = 496 * 384
check("before R929, no request: all 10 frames the same picture, no white row",
      all(v[2] == H0 and v[1] == 0 for v in base.values()) and len(base) == 10)
def only(name, white, same_as=None, n=10):
    f = frames(name); ok = len(f) == n
    for k, v in f.items():
        if k in white: ok = ok and v[0] == WHITE
        elif same_as and k in same_as: ok = ok and v[2] == same_as[k][2]
        else: ok = ok and v[2] == H0
    return ok
old_mid = frames("old_mid")
check("before R929, the game's request in the vblank: frame 5 white, the rest unchanged", only("old_vbl", {5}))
check("before R929, late (line 200): frames 5 and 6 torn, the rest unchanged",
      old_mid[5][1] > 150 and old_mid[6][1] > 150 and old_mid[5][0] + old_mid[6][0] > WHITE * 0.95
      and all(old_mid[k][2] == H0 for k in old_mid if k not in (5, 6)))
for m in (0, 1, 2):
    check(f"mode {m}, no request: every frame as before R929", only(f"m{m}_base", set()))
check("Arcade, on time: the same frames as before R929", frames("m0_vbl") == frames("old_vbl"))
check("Arcade, late: frame 5 as before R929, frame 6 entirely white, the rest unchanged",
      only("m0_mid", {6}, same_as={5: old_mid[5]}))
check("Arcade, a pull the game answers: the game gets it at once, frame 4 white (its flash), the rest unchanged",
      only("m0_pull", {4}, n=12) and trig("m0_pull")[0] == ("pressed", 2, 300))
check("CRT gun, on time: frame 5 white (the game's), the rest unchanged", only("m1_vbl", {5}))
check("CRT gun, late: frame 5 as before R929, frame 6 white", only("m1_mid", {6}, same_as={5: old_mid[5]}))
t1 = trig("m1_pull")
check("CRT gun, a pull at frame 2 line 300: the game gets it at the start of frame 6, for three frames",
      len(t1) == 2 and t1[0][0] == "pressed" and t1[0][1] == 6 and t1[0][2] <= 0
      and t1[1][0] == "released" and t1[1][1] == 9 and t1[1][2] <= 0)
check("CRT gun, that pull answered: frames 3-8 white (8 the game's flash), the rest unchanged",
      only("m1_pull", {3, 4, 5, 6, 7, 8}, n=12))
t2 = trig("m1_pullnr")
check("CRT gun, a pull not answered: frames 3-10 white (CMAX), the press as before",
      only("m1_pullnr", set(range(3, 11)), n=12) and t2 == t1)
check("Off, a pull: the game gets it at once", trig("m2_pull")[0] == ("pressed", 2, 300))
ob = frames("old_band")
check("before R929, the stage band: frames 5 and 6 carry rows of white, the rest unchanged",
      ob[5][1] >= 20 and ob[6][1] >= 20 and ob[5][0] < WHITE // 4
      and all(ob[k][2] == H0 for k in ob if k not in (5, 6)))
for m in (0, 1, 2):
    check(f"mode {m}, the stage band: exactly as before R929 (not a flash request)", frames(f"m{m}_band") == ob)
for c in ("vbl", "mid", "pull", "pullnr"):
    check(f"Off ({c}): every frame the picture with no request",
          only(f"m2_{c}", set(), n=12 if c.startswith("pull") else 10))
print("PASS" if fails == 0 else f"FAIL ({fails})")
sys.exit(1 if fails else 0)
EOF
