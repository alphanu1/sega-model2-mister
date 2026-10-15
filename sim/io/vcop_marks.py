# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R846: Virtua Cop's own gun marks (sim/io/mame_m2_vcop_marks.lua snapshots)
# against MAME's crosshair for the same coordinate.
# usage: python3 vcop_marks.py <snapdir> <gunat-file>   (the TS_GUNAT string)
# R846's run: 24 points (5 fixed, 19 random, seed 1), each held 1 s from
#   31 s; TS_SEQ = "20::IN0/Service Mode,23::IN0/Service 1,23.5::IN0/Service 1,
#   24::IN0/Service 1,24.5::IN0/Service 1,25::IN0/Service 1,25.5::IN0/Service 1,
#   26.5::IN0/Service Mode,28::IN0/Service 1,29::IN0/Service Mode";
#   TS_FROM=31.7 TS_EVERY=1.0. Fresh NVRAM.
import sys, os
from PIL import Image
# centroids of the game's two gun marks (P1 cyan, P2 pink) in each snapshot,
# against MAME's crosshair for the same coordinate (PORT_CROSSHAIR scale 1.0:
# (v - min) / (max - min) of the 496 x 384 visible area) and the core's mapping.
snapdir, gunat = sys.argv[1], sys.argv[2]
pts = []
for item in open(gunat).read().strip().split(';'):
    t, vals = item.split('=')
    v = [int(x, 16) for x in vals.split(',')]
    pts.append((float(t), v))
W, H = 496, 384
RNG = {'p1x': (0x083, 0x276), 'p1y': (0x024, 0x1a9), 'p2x': (0x080, 0x273), 'p2y': (0x027, 0x1a9)}

def mame_px(v, k, dim):
    lo, hi = RNG[k]
    return (v - lo) / (hi - lo) * dim          # continuous; the pixel is floor()

def blobs(im):
    p1, p2 = [], []
    px = im.load()
    for y in range(H):
        for x in range(W):
            r, g, b = px[x, y][:3]
            if r < 160 and g > 200 and b > 200: p1.append((x, y))
            elif r > 200 and g < 190 and b < 200 and r - g > 50: p2.append((x, y))
    def c(l):
        if not l: return None
        xs = [a for a, _ in l]; ys = [b for _, b in l]
        return ((min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2, sum(xs) / len(xs), sum(ys) / len(ys), len(l))
    return c(p1), c(p2)

files = sorted(f for f in os.listdir(snapdir) if f.endswith('.png'))
rows = []
for f in files:
    t = float(f[1:-4])
    v = None
    for tt, vv in pts:
        if t >= tt: v = vv
    im = Image.open(os.path.join(snapdir, f)).convert('RGB')
    b1, b2 = blobs(im)
    for who, b, kx, ky, X, Y in (('P1', b1, 'p1x', 'p1y', v[0], v[1]), ('P2', b2, 'p2x', 'p2y', v[2], v[3])):
        if b is None: continue
        mx, my = mame_px(X, kx, W), mame_px(Y, ky, H)
        rows.append((f, who, X, Y, b, mx, my))
        print("%s %s X=%03x Y=%03x  mark box-centre (%.1f,%.1f) centroid (%.1f,%.1f) n=%d   MAME crosshair (%.2f,%.2f)  diff box-MAME (%+.2f,%+.2f)"
              % (f, who, X, Y, b[0], b[1], b[2], b[3], b[4], mx, my, b[0] - mx, b[1] - my))
