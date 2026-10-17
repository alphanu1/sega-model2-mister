#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# EVERY FP-CLASS WORD IN A MODEL 2 i960 PROGRAM, tagged by what a single-
# precision-only FPU (i960_top FP_EXT = 0, R866) would no longer run:
#   RL   a long-real or extended form (0x79, 0x69, 0x6d, cvtril / cvtzril,
#        cvtilr, scalerl, movre, cpysre) -- the double path itself;
#   FPR  a single form naming fp0-fp3 as a source (m1 / m2 set, index < 4)
#        or as the destination (m3 set) -- the 64-bit FP registers;
#   SGL  a single form on general registers and literals only.
# A linear scan reads data as code, so every word is a CANDIDATE: the PC list
# (-pcs) feeds sim/io/mame_m2_bphits.lua (BP_ONCE=1), whose breakpoints say
# which ones execute (R844: only that is evidence).
#
#   i960_fpext_scan.py <set zip> <lo> <hi> [<lo 2> <hi 2> ...] [-pcs out.txt]
#   (pairs are ROM_LOAD32_WORD low / high halves, consecutive in the map)
#   i960_fpext_scan.py --raw <image> <base hex> [-pcs out.txt]
#   (a memory image, e.g. work RAM from sim/io/mame_m2_ramdump.lua)
import struct, sys, zipfile
from collections import defaultdict

NAMES = {
    (0x67, 0x4): 'cvtir', (0x67, 0x5): 'cvtilr', (0x67, 0x6): 'scalerl', (0x67, 0x7): 'scaler',
    (0x68, 0x0): 'atanr', (0x68, 0x1): 'logepr', (0x68, 0x2): 'logr', (0x68, 0x3): 'remr',
    (0x68, 0x5): 'cmpr', (0x68, 0x8): 'sqrtr', (0x68, 0x9): 'expr', (0x68, 0xa): 'logbnr',
    (0x68, 0xb): 'roundr', (0x68, 0xc): 'sinr', (0x68, 0xd): 'cosr', (0x68, 0xe): 'tanr',
    (0x69, 0x0): 'atanrl', (0x69, 0x2): 'logrl', (0x69, 0x5): 'cmprl', (0x69, 0x8): 'sqrtrl',
    (0x69, 0x9): 'exprl', (0x69, 0xa): 'logbnrl', (0x69, 0xb): 'roundrl', (0x69, 0xc): 'sinrl',
    (0x69, 0xd): 'cosrl', (0x69, 0xe): 'tanrl',
    (0x6c, 0x0): 'cvtri', (0x6c, 0x1): 'cvtril', (0x6c, 0x2): 'cvtzri', (0x6c, 0x3): 'cvtzril',
    (0x6c, 0x9): 'movr', (0x6d, 0x9): 'movrl', (0x6e, 0x1): 'movre', (0x6e, 0x2): 'cpysre',
    (0x78, 0xb): 'divr', (0x78, 0xc): 'mulr', (0x78, 0xd): 'subr', (0x78, 0xf): 'addr',
    (0x79, 0xb): 'divrl', (0x79, 0xc): 'mulrl', (0x79, 0xd): 'subrl', (0x79, 0xf): 'addrl',
    (0x66, 0x0): 'calls', (0x66, 0xd): 'flushreg',
}
RL = {k for k in NAMES if k[0] in (0x69, 0x6d, 0x6e, 0x79)} | {(0x6c, 0x1), (0x6c, 0x3),
                                                                (0x67, 0x5), (0x67, 0x6)}
# which operand fields each single form reads as FP (get_1_rif / get_2_rif) and
# whether it writes an FP destination (set_rif); the rest are integers
SRC1_FP = {(0x68, x) for x in range(16)} | {(0x78, x) for x in range(16)} | \
          {(0x6c, 0x0), (0x6c, 0x2), (0x6c, 0x9)}
SRC2_FP = {(0x78, x) for x in range(16)} | {(0x68, 0x0), (0x68, 0x1), (0x68, 0x2), (0x68, 0x3), (0x68, 0x5),
                                           (0x67, 0x7)}
DST_FP = {(0x78, x) for x in range(16)} | {(0x68, x) for x in range(16) if x != 0x5} | \
         {(0x6c, 0x9), (0x67, 0x4), (0x67, 0x7)}


def tag(k, w):
    if k[0] == 0x66:
        return 'OTH'                              # not FP: listed so the run sees them too
    if k in RL:
        return 'RL'
    m1, m2, m3 = (w >> 11) & 1, (w >> 12) & 1, (w >> 13) & 1
    s1, s2, d = w & 0x1f, (w >> 14) & 0x1f, (w >> 19) & 0x1f
    if (k in SRC1_FP and m1 and s1 < 4) or (k in SRC2_FP and m2 and s2 < 4) or \
       (k in DST_FP and m3 and d < 4):
        return 'FPR'
    return 'SGL'


def main():
    a = sys.argv[1:]
    pcs_out = None
    if '-pcs' in a:
        i = a.index('-pcs'); pcs_out = a[i + 1]; del a[i:i + 2]
    base = 0
    if a[0] == '--raw':                           # a little-endian memory image at <base>
        base = int(a[2], 16)
        prog = bytearray(open(a[1], 'rb').read())
    else:
        z = zipfile.ZipFile(a[0])
        names = {n.split('/')[-1]: n for n in z.namelist()}
        prog = bytearray()
        for k in range(1, len(a), 2):
            lo, hi = z.read(names[a[k]]), z.read(names[a[k + 1]])
            for i in range(0, len(lo), 2):
                prog += lo[i:i + 2] + hi[i:i + 2]     # ROM_LOAD32_WORD: low half, high half
    hits = defaultdict(list)
    for pc in range(0, len(prog) - 3, 4):
        w = struct.unpack_from('<I', prog, pc)[0]
        k = (w >> 24, (w >> 7) & 0xf)
        if k in NAMES:
            hits[(tag(k, w), k)].append(base + pc)
    for t, k in sorted(hits):
        v = hits[(t, k)]
        print('%-3s %02x.%x %-8s %6d  first %s' % (t, k[0], k[1], NAMES[k], len(v),
                                                 ' '.join('%05x' % p for p in v[:5])))
    for t in ('RL', 'FPR', 'SGL', 'OTH'):
        print('%s: %d candidate addresses' % (t, sum(len(v) for (u, _), v in hits.items() if u == t)))
    if pcs_out:
        with open(pcs_out, 'w') as f:
            for (t, k), v in sorted(hits.items()):
                for p in v:
                    f.write('%05x %s.%s\n' % (p, NAMES[k], t))


if __name__ == '__main__':
    main()
