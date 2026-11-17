#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- R1039: the game IDs (index 4, bits 6:0) every
# <rbf>Model2B</rbf> MRA sends, as a 128-line $readmemh file (1 = a 2B set's ID), for
# sim/io/tb_m2b_gameid.sv.   m2b_mra_ids.py <mra dir> <out.hex>
import sys, glob, re
ids = {0}                        # 0x00: the value before any download
for f in sorted(glob.glob(sys.argv[1] + '/*.mra')):
    t = open(f, errors='replace').read()
    if '<rbf>Model2B</rbf>' not in t: continue
    m = re.search(r'<rom index="4"[^>]*>\s*<part>\s*([0-9A-Fa-f]{2})', t)
    if not m: sys.exit('no index 4 in ' + f)
    ids.add(int(m.group(1), 16) & 0x7f)
open(sys.argv[2], 'w').write(''.join('%x\n' % (1 if i in ids else 0) for i in range(128)))
print('2B MRA IDs:', ' '.join('%02x' % i for i in sorted(ids)))
