# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R826: horizontal motion per frame of screen regions in MAME snapshots
# (sim/video/mame_m2_scrlog.lua), and the lag between two of them.
#
#   python3 -I sim/video/r826_shift.py <snapdir> <first> <last> name:y0:y1:x0:x1 ... \
#       [--xc nameA nameB]
#
# For each consecutive pair: the integer shift dx in [-60, 60] minimising the
# mean absolute difference of the region (cur[x] ~ prev[x - dx]). --xc prints
# the correlation of B's per-frame motion at frame t with A's at t + lag.
import sys
import numpy as np
from PIL import Image

args = sys.argv[1:]
xc = None
if '--xc' in args:
    i = args.index('--xc'); xc = (args[i + 1], args[i + 2]); args = args[:i] + args[i + 3:]
d, a, b = args[0], int(args[1]), int(args[2])
rects = {}
for spec in args[3:]:
    name, y0, y1, x0, x1 = spec.split(':'); rects[name] = tuple(map(int, (y0, y1, x0, x1)))
load = lambda n: np.asarray(Image.open(f"{d}/f{n:05d}.png").convert('RGB')).astype(np.int32)
series = {k: [] for k in rects}
prev = load(a)
for n in range(a + 1, b):
    cur = load(n); out = []
    for name, (y0, y1, x0, x1) in rects.items():
        best = None
        for dx in range(-60, 61):
            xs0, xs1 = max(x0, x0 + dx, 0), min(x1, x1 + dx, cur.shape[1])
            if xs1 - xs0 < 40: continue
            s = np.abs(cur[y0:y1, xs0:xs1] - prev[y0:y1, xs0 - dx:xs1 - dx]).mean()
            if best is None or s < best[0]: best = (s, dx)
        series[name].append(best[1]); out.append(f"{name}={best[1]:+d}({best[0]:.0f})")
    print(n, ' '.join(out)); prev = cur
if xc:
    m = np.array(series[xc[0]], float); p = np.array(series[xc[1]], float)
    m -= m.mean(); p -= p.mean()
    for lag in range(-3, 4):
        u, v = (p[:len(p) - lag], m[lag:]) if lag >= 0 else (p[-lag:], m[:len(m) + lag])
        print(f"lag {lag:+d}: r = {np.corrcoef(u, v)[0, 1]:+.3f}")
