# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R892: two Manx TT runs of sim/io/mame_m2_manx_motion.lua compared from their
# Tg (the attract's first frame): the per-second hashes (work RAM with the
# motion bytes masked, RAM, buffer RAM, the EEPROM settings block, the main
# state), the snapshots (pixels that differ, each), and the RAM dumps (the
# bytes that differ, the first few listed).
# usage: python3 -I manx_motion_cmp.py <run dir A> <run dir B>
import sys, os, glob
from PIL import Image, ImageChops

a, b = sys.argv[1], sys.argv[2]


def rows(d):
    r = {}
    for ln in open(f"{d}/hash.txt"):
        f = ln.split()
        r[f[0]] = dict(zip(f[3::2], f[4::2]))
    return r


A, B = rows(a), rows(b)
keys = sorted(set(A) & set(B), key=float)
print(f"hash rows: {len(keys)} common")
for fld in ("w", "r", "b", "set", "st", "cmd", "ms"):
    eq = sum(A[k][fld] == B[k][fld] for k in keys)
    first = next((k for k in keys if A[k][fld] != B[k][fld]), None)
    print(f"  {fld:4s} equal {eq}/{len(keys)}  first diff {first}")
same, out = 0, []
for p in sorted(glob.glob(f"{a}/snap/g_*.png")):
    q = f"{b}/snap/" + os.path.basename(p)
    if not os.path.exists(q):
        continue
    x, y = Image.open(p).convert("RGB"), Image.open(q).convert("RGB")
    bb = ImageChops.difference(x, y).getbbox() if x.size == y.size else (0, 0, 1, 1)
    if bb is None:
        same += 1
    else:
        d = ImageChops.difference(x, y).convert("L").point(lambda v: 255 if v else 0)
        out.append(f"{os.path.basename(p)[2:7]}:{d.histogram()[255]}")
print(f"snapshots: {same} identical, {len(out)} differ" + (" -- " + " ".join(out) if out else ""))
for tag in sorted({os.path.basename(p)[2:6] for p in glob.glob(f"{a}/w_*.bin")}):
    for reg, base in (("w", 0x500000), ("r", 0x200000), ("b", 0x900000)):
        pa, pb = f"{a}/{reg}_{tag}.bin", f"{b}/{reg}_{tag}.bin"
        if not os.path.exists(pb):
            continue
        x, y = open(pa, "rb").read(), open(pb, "rb").read()
        d = [i for i in range(len(x)) if x[i] != y[i]]
        s = " ".join(f"{base + i:06x}:{x[i]:02x}/{y[i]:02x}" for i in d[:8])
        print(f"dump {tag} {reg}: {len(d)} bytes differ {s}")
