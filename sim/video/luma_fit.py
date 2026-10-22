#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R933: FIT A GAME'S LUMA ROWS TO THE 2C BUILD'S 32 SLOTS (R932's method, as a
# script). Reads MAME walk dumps (M2GEO_OUT / M2GEO_TRIG: each t<walk>/ holds
# lumaram.bin, MAME's 32 KB luma RAM -- 256 rows of 128 entries -- and
# geopolys.txt, one line per polygon drawn with its texture header h= and its
# screen vertices). A textured polygon (h[0] bit 14) names its row in h[1]'s
# low byte (MAME model2_v.cpp: lumabase = (texheader[1] & 0xff) << 7).
#
# A slot is filled from ONE representative row; every row that maps to the
# slot is drawn with the representative's table. The cost of a map is the
# per-pixel mean |luma error| (0..63, MAME's 6-bit luma): each dump's drawn
# rows weighted by screen area (pixels), the error of a row the mean over its
# 128 entries of |its entry - the representative's entry|, both from that
# dump's own luma RAM.
#
# With no more distinct drawn rows than slots every drawn row is its own
# representative (error 0); otherwise k-medoids (PAM swap) over the drawn rows.
# Rows never drawn go to the representative nearest by content (unweighted,
# summed over the dumps). Prints statistics and the table as Verilog case
# items (the slot in 4:0, bit 5 set for a representative: m2_luma_map's
# format) and as a C byte array (m2_luma_map_ref.h's).
#
#   sim/video/luma_fit.py [--slots 32] [--sv NAME] [--c NAME] <walk dir> ...
#
# The dumps are ROM-derived and stay outside the repository.
import sys, os, re, glob, argparse

ap = argparse.ArgumentParser()
ap.add_argument("--slots", type=int, default=32)
ap.add_argument("--sv", default=None, help="write the SystemVerilog case items to this file")
ap.add_argument("--c", default=None, help="write the C byte array to this file")
ap.add_argument("dirs", nargs="+")
a = ap.parse_args()

def area(pts):
    s = 0.0
    for i in range(len(pts)):
        x0, y0 = pts[i]; x1, y1 = pts[(i + 1) % len(pts)]
        s += x0 * y1 - x1 * y0
    return abs(s) / 2.0

dumps = []   # (name, luma[256][128], {row: area})
for d in a.dirs:
    for w in sorted(glob.glob(os.path.join(d, "t*"))) + ([d] if os.path.exists(os.path.join(d, "geopolys.txt")) else []):
        lp, gp = os.path.join(w, "lumaram.bin"), os.path.join(w, "geopolys.txt")
        if not (os.path.exists(lp) and os.path.exists(gp)):
            continue
        raw = open(lp, "rb").read()
        if len(raw) != 0x8000:
            continue
        L = [raw[r * 128:(r + 1) * 128] for r in range(256)]
        rows = {}
        for line in open(gp):
            m = re.match(r"P \d+ .*?h=([0-9a-f]{4}),([0-9a-f]{4}),.*? n=(\d+) (.*?) L=", line)
            if not m:
                continue
            h0, h1 = int(m.group(1), 16), int(m.group(2), 16)
            if not (h0 >> 14) & 1:
                continue
            pts = []
            for v in m.group(4).split():
                f = v.split(",")
                pts.append((float(f[0]), float(f[1])))
            r = h1 & 0xff
            rows[r] = rows.get(r, 0.0) + area(pts)
        if rows:
            dumps.append((w, L, rows))
if not dumps:
    sys.exit("no walk dumps with drawn textured polygons")

drawn = sorted({r for _, _, rows in dumps for r in rows})
tot = sum(sum(rows.values()) for _, _, rows in dumps)
# entry values are MAME's 0..255 luma bytes? MAME scales by object.luma / 256 and
# clamps to 0x3f: the table byte is the 6-bit luma (0..63) in practice.
def rerr(L, r, m):
    if r == m:
        return 0.0
    a_, b_ = L[r], L[m]
    return sum(abs(a_[i] - b_[i]) for i in range(128)) / 128.0

# cost[r][m]: area-weighted error of drawing row r with row m's table, over all dumps
cost = {r: {} for r in drawn}
for r in drawn:
    for m in drawn:
        c = 0.0
        for _, L, rows in dumps:
            ar = rows.get(r)
            if ar:
                c += ar * rerr(L, r, m)
        cost[r][m] = c

def total(meds):
    return sum(min(cost[r][m] for m in meds) for r in drawn)

K = a.slots
if len(drawn) <= K:
    meds = list(drawn)
else:
    # greedy build, then PAM swaps
    meds = []
    while len(meds) < K:
        best = min((m for m in drawn if m not in meds), key=lambda m: total(meds + [m]) if meds else sum(cost[r][m] for r in drawn))
        meds.append(best)
    improved = True
    cur = total(meds)
    while improved:
        improved = False
        for i in range(K):
            for m in drawn:
                if m in meds:
                    continue
                trial = meds[:i] + [m] + meds[i + 1:]
                t = total(trial)
                if t < cur - 1e-9:
                    meds, cur, improved = trial, t, True
meds = sorted(meds)

# every row -> a slot
slot_of = {}
for r in drawn:
    slot_of[r] = meds.index(min(meds, key=lambda m: (cost[r][m], m)))
for r in range(256):
    if r in slot_of:
        continue
    def cdist(m):
        return sum(rerr(L, r, m) for _, L, _ in dumps)
    slot_of[r] = meds.index(min(meds, key=lambda m: (cdist(m), m)))

err = total(meds) / tot
big = 0.0
per = []
for name, L, rows in dumps:
    a_ = sum(rows.values()); e = 0.0
    for r, ar in rows.items():
        x = rerr(L, r, meds[slot_of[r]])
        e += ar * x
        if x > 4:
            big += ar
    per.append((e / a_, os.path.basename(name)))
print(f"{len(dumps)} dumps, {len(drawn)} rows drawn (textured): {drawn}")
print(f"{K} slots: per-pixel mean |luma error| {err:.3f} of 63; {100 * big / tot:.2f}% of drawn pixels on a row > 4 off")
per.sort(reverse=True)
print("worst dumps:", ", ".join(f"{n} {e:.2f}" for e, n in per[:5]))
print("representatives:", meds)

ent = []
for r in range(256):
    s = slot_of[r]
    ent.append(s | (0x20 if meds[s] == r else 0))
if a.sv:
    by = {}
    for r in range(256):
        if ent[r] != 0x1f or r in meds:
            by.setdefault(ent[r], []).append(r)
    with open(a.sv, "w") as f:
        for v in sorted(by, key=lambda v: (v & 0x20, v & 0x1f)):
            f.write("      " + ", ".join(f"8'd{r}" for r in by[v]) + f": tab = 6'h{v:02x};\n")
if a.c:
    with open(a.c, "w") as f:
        for i in range(0, 256, 16):
            f.write("  " + ", ".join(f"0x{v:02x}" for v in ent[i:i + 16]) + ",\n")
