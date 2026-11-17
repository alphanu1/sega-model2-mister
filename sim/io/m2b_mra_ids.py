#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- R1039: the game IDs (index 4, bits 6:0) every
# <rbf>Model2B</rbf> MRA sends, as a 128-line $readmemh file (1 = a 2B set's ID), for
# sim/io/tb_m2b_gameid.sv.   m2b_mra_ids.py <mra dir> <out.hex>
# It also fails unless index 4 is each such MRA's FIRST <rom>: the ID is then written before any
# ROM byte, so the i960 (held in reset until rom_loaded) never runs with game ID 0 (Model2.sv's
# vc_en on a 2B build, R1039).
#   m2b_mra_ids.py --plant <mra dir>   the planted fault: the first 2B MRA with its index 4 moved
#   after the other parts must be refused (exit 0 when it is)
import sys, glob, re

def check(f, t):
    m = re.search(r'<rom index="4"[^>]*>\s*<part>\s*([0-9A-Fa-f]{2})', t)
    if not m: return 'no index 4 in ' + f, None
    first = re.search(r'<rom index="(\d+)"', t)
    if first.group(1) != '4': return 'index 4 is not the first <rom> in ' + f, None
    return None, int(m.group(1), 16) & 0x7f

def mras(d):
    for f in sorted(glob.glob(d + '/*.mra')):
        t = open(f, errors='replace').read()
        if '<rbf>Model2B</rbf>' in t: yield f, t

if sys.argv[1] == '--plant':
    f, t = next(mras(sys.argv[2]))
    m = re.search(r'\s*<rom index="4".*?</rom>', t, re.S)
    t = t[:m.start()] + t[m.end():]
    i = t.index('</misterromdescription>')
    err, _ = check(f, t[:i] + m.group(0) + '\n' + t[i:])
    print('planted (index 4 last in %s): %s' % (f.split('/')[-1], err or 'ACCEPTED'))
    sys.exit(0 if err else 1)

ids = {0}                        # 0x00: the value before any download
for f, t in mras(sys.argv[1]):
    err, g = check(f, t)
    if err: sys.exit(err)
    ids.add(g)
open(sys.argv[2], 'w').write(''.join('%x\n' % (1 if i in ids else 0) for i in range(128)))
print('2B MRA IDs:', ' '.join('%02x' % i for i in sorted(ids)))
