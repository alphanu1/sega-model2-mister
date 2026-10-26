#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R965: Gun flash Off for Virtua Cop 2 and The House of the Dead through the
# 2A / 2C picture path (tb_m2_gunflash2a).
#
#   sim/video/run_gunflash2a.sh <vcop2 dump> <hotd dump> <hotd card dump> [work dir]
#
# Dumps (tile.bin / char.bin / palette.bin / colorxlat.bin) from
# sim/io/mame_m2_gunflash_wt.lua WT_DUMP, MAME 0.289; R965 used vcop2 frame
# 1726 (in play, the frame before a shot's flash), hotd frame 1716 (the
# same) and hotd frame 1470 (the white "The First Chapter" card, sim/io/
# mame_m2_hotd_play.lua seed 1). They are game memory and stay out of the
# repository.
#
# The writes are the games' own (MAME 0.289, every window-table write logged):
#   v2      Virtua Cop 2: 0xFFFF over words 0x6000-0x65FF from 0x6000 up in
#           the vblank after frame 4 (0x19f08), 0x0000 the same at the next
#           four (0x19f98)
#   hotd    House of the Dead: the same request (0x18620), cleared at the next
#           vblank only (0x18650)
#   *mid    the same runs at line 200 (a handler that ran late)
#   band    VCop's stage-start band: 0xFFFF over rows 172-199 only (words
#           0x62B0-0x631F) after frame 4, 0 after frame 6 -- the table used,
#           row 0 never written: not a request
#   hold    the card: a shot during HOTD's chapter card -- the request after
#           frame 2, then a band of mixed masks over rows 336-367 (words
#           0x6540-0x65BF, as 0x183f0 / 0x184f8 write it) after frames 3-7,
#           the whole table cleared after frame 8
#   cband   the same band on the card with no request
# Checked, for every case: Arcade (+off=0) gives every frame byte for byte the
# core before R965 (FLASH = 0); Off gives every frame of a request case the
# picture with no writes at all (MAME with the table writes forced to zero:
# the scene, not the flash), and every frame of a non-request case (band,
# cband, none) the Arcade picture; with the module held off (+en=0) Off is
# Arcade. And that the cases test something: Arcade's flash frames differ
# from the scene on > 95% of the pixels.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
D_V2="${1:?usage: run_gunflash2a.sh <vcop2 dump> <hotd dump> <hotd card dump> [work dir]}"
D_HD="${2:?}"; D_CD="${3:?}"
W="${4:-${TMPDIR:-/tmp}/m2-gunflash2a}"
mkdir -p "$W"
B1="${GF_B1:-$ROOT/obj_m2_gf2a1/Vtb_m2_gunflash2a_top}"   # GF_B1: another build (planted faults)
B0="$ROOT/obj_m2_gf2a0/Vtb_m2_gunflash2a_top"
python3 -I - "$W" <<'EOF'
import sys
w = sys.argv[1]
def run(f, v, mid=False, lo=0x6000, hi=0x6600):
    return [f"{f} {a:04x} {v:04x}{' mid' if mid else ''}" for a in range(lo, hi)]
def save(name, lines): open(f"{w}/{name}.wr", "w").write("\n".join(lines) + "\n")
save("none", [])
for mid in (False, True):
    sfx = "mid" if mid else ""
    save("v2" + sfx, run(4, 0xFFFF, mid) + sum((run(4 + k, 0, mid) for k in range(1, 5)), []))
    save("hotd" + sfx, run(4, 0xFFFF, mid) + run(5, 0, mid))
save("band", run(4, 0xFFFF, lo=0x62B0, hi=0x6320) + run(6, 0, lo=0x62B0, hi=0x6320))
pat = [0xFFFF, 0xFFFF, 0xFFC0, 0x01FF, 0xFFE0, 0x1FFF, 0xFFFF, 0xFFFF]
def band(f): return [f"{f} {a:04x} {pat[(a - 0x6540) % 8]:04x}" for a in range(0x6540, 0x65C0)]
save("hold", run(2, 0xFFFF) + sum((band(f) for f in range(3, 8)), []) + run(8, 0, hi=0x6800))
save("cband", sum((band(f) for f in range(3, 8)), []) + run(8, 0, hi=0x6800))
EOF
jobs=()
# build out dump case args -- never ending in a blank: xargs -L joins such a line to the next
add() { jobs+=("$1 $2 $3 $4 ${5:-+off=0} +en=1"); }
for c in none v2 v2mid band; do
  add "$B0" "f0_v2_$c" "$D_V2" "$c"
  add "$B1" "a_v2_$c"  "$D_V2" "$c" "+off=0"
  add "$B1" "o_v2_$c"  "$D_V2" "$c" "+off=1"
done
add "$B1" "e_v2_v2" "$D_V2" v2 "+off=1"; jobs[-1]="${jobs[-1]/+en=1/+en=0}"
for c in none hotd hotdmid; do
  add "$B0" "f0_hd_$c" "$D_HD" "$c"
  add "$B1" "a_hd_$c"  "$D_HD" "$c" "+off=0"
  add "$B1" "o_hd_$c"  "$D_HD" "$c" "+off=1"
done
for c in none hold cband; do
  add "$B0" "f0_cd_$c" "$D_CD" "$c"
  add "$B1" "a_cd_$c"  "$D_CD" "$c" "+off=0"
  add "$B1" "o_cd_$c"  "$D_CD" "$c" "+off=1"
done
printf '%s\n' "${jobs[@]}" | xargs -P "${GF_JOBS:-8}" -L 1 sh -c \
  '"$0" +in="$2" +out="'"$W"'/$1" +wr="'"$W"'/$3.wr" +frames=10 $4 $5 > /dev/null'
python3 -I - "$W" <<'EOF'
import sys
w = sys.argv[1]
N = 496 * 384
def fr(name):
    d = {}
    for l in open(f"{w}/{name}_sum.txt"):
        p = l.split()
        if p[0] == "frame": d[int(p[1])] = dict(white=int(p[3]), flat=int(p[5]), hash=p[7], kill=int(p[9]))
    return d
fails = 0
def check(what, ok):
    global fails
    print(("  ok    " if ok else "  FAIL  ") + what)
    if not ok: fails += 1
def same(a, b): return len(a) == 10 and len(b) == 10 and all(a[k]["hash"] == b[k]["hash"] for k in a)
def diffpx(a, b):   # frames whose hash differs
    return sorted(k for k in a if a[k]["hash"] != b[k]["hash"])
cases = [("v2", c) for c in ("none", "v2", "v2mid", "band")] + [("hd", c) for c in ("none", "hotd", "hotdmid")] \
      + [("cd", c) for c in ("none", "hold", "cband")]
for g, c in cases:
    check(f"{g} {c}: Arcade = the core before R965, every frame byte for byte", same(fr(f"a_{g}_{c}"), fr(f"f0_{g}_{c}")))
for g, c in cases:
    req = c in ("v2", "v2mid", "hotd", "hotdmid", "hold")
    ref = fr(f"f0_{g}_none") if req else fr(f"a_{g}_{c}")
    check(f"{g} {c}: Off = " + ("the picture with no writes (the flash removed)" if req else "Arcade (not a request: passes through)"),
          same(fr(f"o_{g}_{c}"), ref))
check("v2 v2, module held off (en 0): Off = Arcade", same(fr("e_v2_v2"), fr("a_v2_v2")))
# the cases test something: Arcade shows the game's own flash, whole or torn
n2, nh = fr("f0_v2_none"), fr("f0_hd_none")
a2, ah = fr("a_v2_v2"), fr("a_hd_hotd")
check("v2: Arcade's frame 5 is the game's flash (white over > 95%), the rest the scene",
      a2[5]["white"] > 0.95 * N and diffpx(a2, n2) == [5])
check("hotd: Arcade's frame 5 is the game's flash (one flat colour over > 95%), the rest the scene",
      ah[5]["flat"] > 0.95 * N and diffpx(ah, nh) == [5])
m2, mh = fr("a_v2_v2mid"), fr("a_hd_hotdmid")
check("v2 late: Arcade's frames 5 and 6 carry the torn flash, the rest the scene", diffpx(m2, n2) == [5, 6])
check("hotd late: Arcade's frames 5 and 6 carry the torn flash, the rest the scene", diffpx(mh, nh) == [5, 6])
check("v2 band: Arcade shows the band (frames 5, 6 differ from the scene)", diffpx(fr("a_v2_band"), n2) == [5, 6])
cn, ch, cb = fr("f0_cd_none"), fr("a_cd_hold"), fr("a_cd_cband")
check("card: the white card itself (no writes) is > 60% white in every mode, Off included",
      all(v["white"] > 0.6 * N for v in fr("o_cd_none").values()) and same(fr("o_cd_none"), cn))
check("card hold: Arcade differs from the card on frames 3-8 (the request standing)", diffpx(ch, cn) == [3, 4, 5, 6, 7, 8])
check("card cband: the band alone shows in Off as in Arcade (frames 4-8 differ from the card)",
      diffpx(fr("o_cd_cband"), cn) == [4, 5, 6, 7, 8])
check("kill never high with no request (none, band, cband, Off)",
      all(v["kill"] == 0 for n in ("o_v2_none", "o_v2_band", "o_hd_none", "o_cd_none", "o_cd_cband") for v in fr(n).values()))
print("PASS" if fails == 0 else f"FAIL ({fails})")
sys.exit(1 if fails else 0)
EOF
