#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# STATIC SCAN OF A MODEL 2 i960 PROGRAM for REG-format words in the FP and
# extended-op blocks (0x64-0x7f), counted by (opcode, sub-opcode) with their
# addresses (R836). A linear scan also reads data as code, so a hit is a
# candidate, not a proof: confirm it with a MAME breakpoint or a trace.
#
#   i960_fpscan.py <set zip> <lo rom> <hi rom> [<lo rom 2> <hi rom 2>] [-pcs out.txt]
# e.g. i960_fpscan.py ~/roms/Model2/desert.zip epr-16976.12 epr-16977.13 epr-16970.14 epr-16971.15
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
}
# what i960_top executes after R836 (everything else in these blocks traps)
RTL = {(0x78, 0xf), (0x78, 0xd), (0x78, 0xc), (0x78, 0xb), (0x68, 0x5), (0x68, 0x8), (0x68, 0xa),
       (0x68, 0xb), (0x6c, 0x0), (0x6c, 0x2), (0x6c, 0x9), (0x67, 0x4), (0x67, 0x7),
       (0x79, 0xf), (0x79, 0xd), (0x79, 0xc), (0x79, 0xb), (0x69, 0x5), (0x6d, 0x9)}


def main():
    a = sys.argv[1:]
    pcs_out = None
    if '-pcs' in a:
        i = a.index('-pcs'); pcs_out = a[i + 1]; del a[i:i + 2]
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
        op, op2 = w >> 24, (w >> 7) & 0xf
        if 0x67 <= op <= 0x79 and (op, op2) in NAMES:
            hits[(op, op2)].append(pc)
    for k in sorted(hits):
        tag = 'ok  ' if k in RTL else 'TRAP'
        print('%s %02x.%x %-8s %5d  first %s' % (tag, k[0], k[1], NAMES[k], len(hits[k]),
                                                ' '.join('%05x' % p for p in hits[k][:6])))
    if pcs_out:
        with open(pcs_out, 'w') as f:
            for k in sorted(hits):
                if k not in RTL:
                    for p in hits[k]:
                        f.write('%05x %s\n' % (p, NAMES[k]))


if __name__ == '__main__':
    main()
