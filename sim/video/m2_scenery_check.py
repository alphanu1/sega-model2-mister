#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R935: DO THE SCENERY'S PIECES STAY TOGETHER? Over a run of display-list
# dumps (MAME's M2GEO walks, or tb_m2_boot's M2_LISTDUMP -- both bufferram.bin
# and state.txt), every object from the scenery's polygon-ROM range is placed
# relative to the first one by its own matrix: R^T (t_i - t_ref). Static
# scenery gives the same vector in every walk whatever the camera does; a piece
# drawn with another frame's matrix moves off it (House of the Dead's courtyard
# shadow, "pieces sliding at different speeds and meeting up"). Also counts the
# distinct 3x3 parts in each walk. Moving objects (effects, 0x95e000 up in
# HOTD) are left out of the spread table.
#   m2_scenery_check.py [--lo 0x930000 --hi 0x95e000] <dump dir> ...
import sys, os, subprocess, struct, collections, math

def u2f(h):
    return struct.unpack('<f', struct.pack('<I', int(h, 16)))[0]

args = sys.argv[1:]
lo, hi = 0x930000, 0x95e000
if '--lo' in args: i = args.index('--lo'); lo = int(args[i + 1], 0); del args[i:i + 2]
if '--hi' in args: i = args.index('--hi'); hi = int(args[i + 1], 0); del args[i:i + 2]
dec = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'm2_listdec.py')
rel = collections.defaultdict(list)
for d in args:
    out = subprocess.run([sys.executable, dec, d, '-v'], capture_output=True, text=True).stdout.splitlines()
    mat = None; objs = {}; rots = collections.Counter()
    for l in out:
        p = l.split()
        if len(p) > 14 and p[2] == 'matrix':
            mat = [u2f(x) for x in p[3:15]]
        if len(p) >= 7 and p[2] == 'object':
            oba = int(p[5], 16)
            if lo <= oba < hi and mat:
                rots[tuple(round(v, 6) for v in mat[:9])] += 1
                objs.setdefault(oba, mat)
    print('%-12s scenery objects %3d, distinct 3x3 parts %d' % (os.path.basename(d.rstrip('/')), sum(rots.values()), len(rots)))
    if not objs:
        continue
    M = objs[min(objs)]
    R = [[M[c * 3 + r] for c in range(3)] for r in range(3)]   # x' = sum_c R[r][c] p[c] + t[r]
    for oba, m in objs.items():
        dt = [m[9] - M[9], m[10] - M[10], m[11] - M[11]]
        rel[oba].append([sum(R[r][c] * dt[r] for r in range(3)) for c in range(3)])
rows = []
for oba, xs in rel.items():
    if len(xs) < 2:
        continue
    rows.append((max(math.dist(a, b) for a in xs for b in xs), max(math.hypot(*a) for a in xs), oba, len(xs)))
rows.sort(reverse=True)
print('largest spread of a piece against the first, over the dumps (static scenery: ~0):')
for s, m, oba, n in rows[:12]:
    print('  oba %06x  spread %10.4f  |p| %8.1f  walks %d' % (oba, s, m, n))
