#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Render a frame with m2_video and compare it against MAME's screen, PIXEL BY
# PIXEL, from the same tilemap inputs.
#
#   tools/m2-framediff.sh [frame] [set]
#
# WHY THIS EXISTS
#
# P1.5's exit criterion 4 — "the rendered frame matches MAME's screenshot" — was
# judged on hardware by looking at it. That catches a wrong tilemap. It does not
# catch a wrong colour, and there was one: this core inherited Model 1's palette
# module, and Model 2's palette is a different mechanism entirely (study R27).
# Every fill colour in every game was a few units out and the picture looked
# perfect.
#
# WHAT A PASS MEANS, AND WHAT IT CANNOT MEAN YET
#
# There is no 3D renderer, so a whole-frame match is impossible: MAME composites
# polygons into the middle of this screen and we composite nothing. The number
# to watch is the MATCHING pixel count, and the artifact to look at is the mask
# — every 2D glyph should be solid, and the residual should have the shape of
# the 3D scene. A colour error shows up as glyph OUTLINES matching and their
# fills not, which is exactly how R27 was found.
#
# It writes ours.ppm, mame.png and diffmask.png so the three can be looked at.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAME="${1:-120}"
SET="${2:-daytona93}"
WORK="${M2_FRAME_OUT:-${TMPDIR:-/tmp}/m2-framediff}"
# Frame 120 is Daytona's settings screen: TILEMAP ONLY, no polygons anywhere on
# it, so an exact whole-frame match is both possible and required. Frames 60, 90
# and 150 are the same and also match exactly.
#
# Later frames composite the 3D scene, which we do not render at all, so they
# can only be held to a floor. Pass a frame and set M2_MATCH_FLOOR to use one.
EXACT="${M2_EXACT:-1}"
FLOOR="${M2_MATCH_FLOOR:-0}"

command -v mame >/dev/null || { echo "mame not on PATH — skipping"; exit 0; }
[ -x "$ROOT/obj_m2_vf/Vm2_video" ] || { echo "build first: make obj_m2_vf/Vm2_video"; exit 1; }

mkdir -p "$WORK"
W=/tmp/m2b-mame; mkdir -p $W/{cfg,nvram,sta,snap,diff,inp,comment,share}

# Inputs and screen from the SAME frame of the SAME run configuration. MAME is
# deterministic here because nvram is deleted first — a warm nvram produced a
# false CPU-bug report on the Model 1 core.
for script in mame_m2_tiledump mame_m2_screendump; do
  rm -rf $W/nvram; mkdir -p $W/nvram
  M2_FRAME="$FRAME" M2_OUT="$WORK" mame "$SET" -rompath "${M2_ROMPATH:-$HOME/roms/Model2}" \
    -cfg_directory $W/cfg -nvram_directory $W/nvram -state_directory $W/sta \
    -snapshot_directory $W/snap -diff_directory $W/diff -input_directory $W/inp \
    -share_directory $W/share -comment_directory $W/comment \
    -sound none -video none -nothrottle -skip_gameinfo \
    -autoboot_script "$ROOT/tools/$script.lua" >/dev/null 2>&1 || true
done

"$ROOT/obj_m2_vf/Vm2_video" "+in=$WORK" "+out=$WORK/ours" | sed 's/^/  /'

python3 - "$WORK" "$FLOOR" "$EXACT" <<'PY'
import struct, zlib, sys, collections
work, floor, exact = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "1"
W, H = 496, 384
px   = struct.unpack("<%dI" % (W*H), open(f"{work}/screen.raw", "rb").read())
ours = open(f"{work}/ours.raw", "rb").read()

def png(path, rows):
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t+d) & 0xffffffff)
    hdr = struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', hdr)
                           + chunk(b'IDAT', zlib.compress(b''.join(rows))) + chunk(b'IEND', b''))

same = 0
mask, mrows = bytearray(), []
for i in range(W*H):
    v = px[i]; m = ((v >> 16) & 255, (v >> 8) & 255, v & 255)
    o = (ours[i*3], ours[i*3+1], ours[i*3+2])
    if m == o: same += 1; mask += bytes((0, 255, 0))
    else:      mask += bytes((255, 0, 0))
    mrows.append(bytes(m))
png(f"{work}/diffmask.png", [b'\x00' + bytes(mask[y*W*3:(y+1)*W*3]) for y in range(H)])
png(f"{work}/mame.png",     [b'\x00' + b''.join(mrows[y*W:(y+1)*W]) for y in range(H)])

pct = 100.0 * same / (W*H)
print(f"  {same} of {W*H} pixels identical ({pct:.1f}%)")
print(f"  wrote {work}/diffmask.png (green = identical) and {work}/mame.png")
if exact:
    if same != W*H:
        print(f"  FAIL — a tilemap-only frame must match EXACTLY; {W*H - same} pixels differ")
        sys.exit(1)
    print("  EXACT — whole frame identical to MAME")
else:
    if same < floor:
        print(f"  REGRESSED below the floor {floor}")
        sys.exit(1)
    print("  OK — residual should be the 3D scene; check the mask if it moved")
PY
