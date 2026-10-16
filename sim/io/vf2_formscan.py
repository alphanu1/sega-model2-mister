#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# STATIC SCAN OF A MODEL 2 i960 PROGRAM FOR EVERY REG-FORMAT (op, op2) THAT
# MAME 0.289 EXECUTES AND i960_top DOES NOT, all blocks (not only the FP ones
# tools/i960_fpscan.py covers): calls, flushreg, movre, cvtril and the rest.
# Each candidate is tagged VC when i960_top runs it with VC = 1 and vc_en high
# (R839 / R844 / R845), RTL-NONE when it traps whatever the build. A linear
# scan reads data as code, so a hit is a candidate address for a breakpoint
# (sim/io/mame_m2_bphits.lua), not a proof: R844 -- only a trace or a
# breakpoint on every occurrence says what executes.
#
#   vf2_formscan.py <set zip> <lo> <hi> [<lo 2> <hi 2>] [-pcs out.txt]
#   -pcs writes "<pc> <name>" for every candidate, VC and RTL-NONE alike
import struct, sys, zipfile
from collections import defaultdict

# MAME 0.289 i960.cpp execute_op, REG format: (op, op2) -> name
MAME = {
    **{(0x58, k): n for k, n in enumerate(['notbit', 'and', 'andnot', 'setbit', 'notand', None, 'xor',
                                           'or', 'nor', 'xnor', 'not', 'ornot', 'clrbit', 'notor',
                                           'nand', 'alterbit']) if n},
    (0x59, 0x0): 'addo', (0x59, 0x1): 'addi', (0x59, 0x2): 'subo', (0x59, 0x3): 'subi',
    (0x59, 0x8): 'shro', (0x59, 0xa): 'shrdi', (0x59, 0xb): 'shri', (0x59, 0xc): 'shlo',
    (0x59, 0xd): 'rotate', (0x59, 0xe): 'shli',
    (0x5a, 0x0): 'cmpo', (0x5a, 0x1): 'cmpi', (0x5a, 0x2): 'concmpo', (0x5a, 0x3): 'concmpi',
    (0x5a, 0x4): 'cmpinco', (0x5a, 0x5): 'cmpinci', (0x5a, 0x6): 'cmpdeco', (0x5a, 0x7): 'cmpdeci',
    (0x5a, 0xc): 'scanbyte', (0x5a, 0xe): 'chkbit',
    (0x5b, 0x0): 'addc', (0x5b, 0x2): 'subc',
    (0x5c, 0xc): 'mov', (0x5d, 0xc): 'movl', (0x5e, 0xc): 'movt', (0x5f, 0xc): 'movq',
    (0x60, 0x0): 'synmov', (0x60, 0x2): 'synmovq',
    (0x64, 0x0): 'spanbit', (0x64, 0x1): 'scanbit', (0x64, 0x4): 'dmovt', (0x64, 0x5): 'modac',
    (0x65, 0x5): 'modpc',
    (0x66, 0x0): 'calls', (0x66, 0xd): 'flushreg',
    (0x67, 0x0): 'emul', (0x67, 0x1): 'ediv', (0x67, 0x4): 'cvtir', (0x67, 0x5): 'cvtilr',
    (0x67, 0x6): 'scalerl', (0x67, 0x7): 'scaler',
    (0x68, 0x0): 'atanr', (0x68, 0x1): 'logepr', (0x68, 0x2): 'logr', (0x68, 0x3): 'remr',
    (0x68, 0x5): 'cmpr', (0x68, 0x8): 'sqrtr', (0x68, 0x9): 'expr', (0x68, 0xa): 'logbnr',
    (0x68, 0xb): 'roundr', (0x68, 0xc): 'sinr', (0x68, 0xd): 'cosr', (0x68, 0xe): 'tanr',
    (0x69, 0x0): 'atanrl', (0x69, 0x2): 'logrl', (0x69, 0x5): 'cmprl', (0x69, 0x8): 'sqrtrl',
    (0x69, 0x9): 'exprl', (0x69, 0xa): 'logbnrl', (0x69, 0xb): 'roundrl', (0x69, 0xc): 'sinrl',
    (0x69, 0xd): 'cosrl', (0x69, 0xe): 'tanrl',
    (0x6c, 0x0): 'cvtri', (0x6c, 0x1): 'cvtril', (0x6c, 0x2): 'cvtzri', (0x6c, 0x3): 'cvtzril',
    (0x6c, 0x9): 'movr', (0x6d, 0x9): 'movrl', (0x6e, 0x1): 'movre', (0x6e, 0x2): 'cpysre',
    (0x70, 0x1): 'mulo', (0x70, 0x8): 'remo', (0x70, 0xb): 'divo',
    (0x74, 0x1): 'muli', (0x74, 0x8): 'remi', (0x74, 0x9): 'modi', (0x74, 0xb): 'divi',
    (0x78, 0xb): 'divr', (0x78, 0xc): 'mulr', (0x78, 0xd): 'subr', (0x78, 0xf): 'addr',
    (0x79, 0xb): 'divrl', (0x79, 0xc): 'mulrl', (0x79, 0xd): 'subrl', (0x79, 0xf): 'addrl',
}
# What MAME runs and i960_top (RL = 1) traps on with VC = 0: i960_alu,
# i960_muldiv, the movx / synmov / modpc paths and the FP decode in i960_top.
RTL_LACKS = {(0x66, 0x0), (0x66, 0xd), (0x67, 0x5), (0x67, 0x6),
             (0x68, 0x0), (0x68, 0x1), (0x68, 0x2), (0x68, 0x3), (0x68, 0x9), (0x68, 0xc),
             (0x68, 0xd), (0x68, 0xe),
             (0x69, 0x0), (0x69, 0x2), (0x69, 0x8), (0x69, 0x9), (0x69, 0xa), (0x69, 0xb),
             (0x69, 0xc), (0x69, 0xd), (0x69, 0xe),
             (0x6c, 0x1), (0x6c, 0x3), (0x6e, 0x1), (0x6e, 0x2)}
# ...of which these run with VC = 1 and vc_en high
VC_FORMS = {(0x66, 0xd), (0x69, 0x8), (0x6e, 0x2), (0x6c, 0x3),
            (0x69, 0xc), (0x69, 0xd), (0x69, 0xe), (0x69, 0x0)}


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
        k = (w >> 24, (w >> 7) & 0xf)
        if k in RTL_LACKS:
            hits[k].append(pc)
    for k in sorted(hits):
        tag = 'VC      ' if k in VC_FORMS else 'RTL-NONE'
        print('%s %02x.%x %-8s %5d  first %s' % (tag, k[0], k[1], MAME[k], len(hits[k]),
                                                ' '.join('%05x' % p for p in hits[k][:6])))
    print('%d candidate addresses, %d forms' % (sum(len(v) for v in hits.values()), len(hits)))
    if pcs_out:
        with open(pcs_out, 'w') as f:
            for k in sorted(hits):
                for p in hits[k]:
                    f.write('%05x %s\n' % (p, MAME[k]))


if __name__ == '__main__':
    main()
