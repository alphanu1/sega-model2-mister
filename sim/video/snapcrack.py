# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
# R972: cracks that vertex snapping alone opens in a MAME polygon list (M2DIFF polys.txt).
# snapframe.py <polys.txt> ...: pixel centres covered with float vertices but by no polygon once the
# vertices are snapped to a 1/Q px grid -- the cracks snapping alone opens, whole frame and rows 262-282
import sys, numpy as np
H, W = 384, 496
def load(f):
    P = []
    for l in open(f):
        if l.startswith('P '):
            p = l.split(); P.append(np.array([tuple(map(float, x.split(',')[:2])) for x in p if x.count(',') == 4]))
    return P
def cover(P, q):
    C = np.zeros((H, W), bool)
    for v in P:
        if q: v = np.round(v * q) / q
        x0, y0 = np.floor(v.min(0)).astype(int); x1, y1 = np.ceil(v.max(0)).astype(int)
        x0 = max(x0, 0); y0 = max(y0, 0); x1 = min(x1, W - 1); y1 = min(y1, H - 1)
        if x1 < x0 or y1 < y0: continue
        ys, xs = np.mgrid[y0:y1 + 1, x0:x1 + 1]; cx = xs + 0.5; cy = ys + 0.5
        pos = np.zeros(cx.shape, bool); neg = np.zeros(cx.shape, bool)
        n = len(v)
        for i in range(n):
            a = v[i]; b = v[(i + 1) % n]
            e = (b[0] - a[0]) * (cy - a[1]) - (b[1] - a[1]) * (cx - a[0])
            pos |= e > 0; neg |= e < 0
        C[y0:y1 + 1, x0:x1 + 1] |= ~(pos & neg)
    return C
for f in sys.argv[1:]:
    P = load(f); F = cover(P, 0)
    res = []
    for q in (2, 4, 8, 16, 32):
        S = cover(P, q); crack = F & ~S
        res.append('1/%d: %d (%d in rows 262-282)' % (q, crack.sum(), crack[262:283].sum()))
    print(f, len(P), 'polys;', '; '.join(res))
