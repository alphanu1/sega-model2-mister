#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R873: COMPARE TWO RUNS OF sim/prot/mame_m2_zg_patch.lua -- the per-second
# counter and RAM hashes, the snapshots (md5) and the RAM dumps word by word.
#
#   python3 -I sim/prot/zg_patch_cmp.py <run dir A> <run dir B>
#
# The run directories hold ROM-derived data and stay outside the repository.
import sys, os, hashlib, glob

a, b = sys.argv[1], sys.argv[2]

def hashes(d):
    r = {}
    for l in open(os.path.join(d, "hash.txt")):
        f = l.split()
        if len(f) < 6:
            continue
        r[int(f[0])] = dict(x.split("=") for x in f[1:])
    return r

ha, hb = hashes(a), hashes(b)
common = sorted(set(ha) & set(hb))
first, ndiff = {}, {}
for t in common:
    for k in ("cnt", "w0", "w1", "w2", "f"):
        va, vb = ha[t][k], hb[t][k]
        if k == "w1" and (va == "0" or vb == "0"):   # w1 is hashed every 30 s only
            continue
        if va != vb:
            ndiff[k] = ndiff.get(k, 0) + 1
            first.setdefault(k, t)
print(f"seconds compared: {common[0]}..{common[-1]} ({len(common)})")
for k in ("cnt", "w0", "w1", "w2", "f"):
    print(f"  {k}: {ndiff.get(k, 0)} seconds differ" + (f", first at {first[k]} s" if k in first else ""))
cb = [(t, hb[t]["cnt"]) for t in common if hb[t]["cnt"] != "0"]
if cb:
    print(f"  B counter nonzero from {cb[0][0]} s (value {cb[0][1]}), max {max(int(c) for _, c in cb)}")

def md5s(d):
    fs = sorted(glob.glob(os.path.join(d, "snap", "*", "*.png")))
    return [hashlib.md5(open(f, "rb").read()).hexdigest() for f in fs]

sa, sb = md5s(a), md5s(b)
n = min(len(sa), len(sb))
diffs = [i for i in range(n) if sa[i] != sb[i]]
print(f"snapshots: {len(sa)} / {len(sb)}, {len(diffs)} of {n} differ" + (f", first index {diffs[0]}" if diffs else ""))
for fa in sorted(glob.glob(os.path.join(a, "*_*.bin"))):
    fb = os.path.join(b, os.path.basename(fa))
    if not os.path.exists(fb):
        continue
    da, db = open(fa, "rb").read(), open(fb, "rb").read()
    base = 0x500000 if os.path.basename(fa).startswith("wr") else 0x200000
    d = [i for i in range(0, len(da), 4) if da[i:i + 4] != db[i:i + 4]]
    print(f"  {os.path.basename(fa)}: " + (f"{len(d)} words differ: " + " ".join(f"{base + i:06x}" for i in d[:16])
                                         if d else "identical"))
