# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R826 addendum: reads a log from sim/video/mame_m2_bgtime.lua and reports
#   * game steps per frame (the only timing input on the backdrop's path),
#   * the timing reads the game made outside its vblank wait,
#   * how smooth the camera yaw is (change of yaw rate per frame),
#   * the backdrop's own step changes (whole pixels),
#   * the backdrop's jump AGAINST the 3D per frame if the 2D shows game step
#     k-d under the 3D of step k (d = 0 aligned, 1 = MAME, -1 = this core at
#     one step a vblank, R826).
#
#   python3 -I sim/video/r826_bgtime.py <log> [first last]
import collections
import re
import sys


def wrap(a):
    return (a + 32768) % 65536 - 32768


def main():
    path = sys.argv[1]
    lo = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    hi = int(sys.argv[3]) if len(sys.argv) > 3 else 1 << 30
    rows = []
    with open(path) as f:
        for line in f:
            n = int(line.split()[0])
            if lo <= n <= hi:
                d = dict(re.findall(r'(\w+)=(\S*)', line))
                d['n'] = n
                rows.append(d)
    if len(rows) < 4:
        sys.exit("too few frames")
    its = collections.Counter(int(r['it']) for r in rows)
    tim = collections.Counter()
    for r in rows:
        for t in filter(None, r.get('tim', '').split(',')):
            k, _, c = t.rpartition('x')
            tim[k] += int(c)
    print(f"{len(rows)} frames {rows[0]['n']}-{rows[-1]['n']}")
    print("  game steps per frame:", dict(sorted(its.items())))
    print("  timing reads outside the vblank wait:", dict(tim) or "none")
    y = [int(r['Y']) for r in rows]
    u = [y[0]]
    for a, b in zip(y, y[1:]):
        u.append(u[-1] + wrap(b - a))
    dy = [u[i] - u[i - 1] for i in range(1, len(u))]
    ddy = [abs(dy[i] - dy[i - 1]) for i in range(1, len(dy))]
    print("  yaw rate change per frame (32 units = 1 px of backdrop):"
          f" <8 {sum(x < 8 for x in ddy)}, 8-31 {sum(8 <= x < 32 for x in ddy)},"
          f" 32-127 {sum(32 <= x < 128 for x in ddy)}, >=128 {sum(x >= 128 for x in ddy)}")
    h = [v >> 5 for v in u]
    d2 = [abs((h[i] - h[i - 1]) - (h[i - 1] - h[i - 2])) for i in range(2, len(h))]
    print(f"  backdrop step change (whole px): 0-1 {sum(x <= 1 for x in d2)},"
          f" 2-3 {sum(2 <= x < 4 for x in d2)}, 4-7 {sum(4 <= x < 8 for x in d2)}, >=8 {sum(x >= 8 for x in d2)}")
    p = [v / 32 for v in u]
    for d in (0, 1, -1, 2):
        rel = [p[k] - p[k - d] for k in range(2, len(p) - 2)]
        j = [abs(rel[i] - rel[i - 1]) for i in range(1, len(rel))]
        print(f"  d={d:+d} (2D shows step k-d under 3D step k): backdrop-vs-scene jump >=1 px {sum(x >= 1 for x in j)},"
              f" >=2 px {sum(x >= 2 for x in j)}, >=4 px {sum(x >= 4 for x in j)} frames")


if __name__ == "__main__":
    main()
