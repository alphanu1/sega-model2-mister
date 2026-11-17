#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- R1042: what a run executed of the PM-bus and type-1 forms.
# The program from an events.bin's upload ('U', 16/48 packing as DMAC6 0xa1), the executed words
# from tb_m2b_sharc +prof=<file> ("<pc> <words> <clocks>"); counts by form and, for type 1, by
# its read / write mix, its two moves' registers and the word before it (I(8+pmi) = I(dmi): the
# two moves at one word of block 1), with the clk_sys each took (the prof's clocks: D, its waits, X).
#   m2b_pmcov.py <events.bin> <prof> [...pairs]
import collections, struct, sys


def load_pm(path):
    pm = {}; n = 0
    d = open(path, 'rb').read()
    for k in range(0, len(d) - 8, 9):
        t, a, b = struct.unpack_from('<BII', d, k)
        if t == ord('U'):
            w = a % 3; idx = 0x20000 + a // 3
            pm[idx] = pm.get(idx, 0) | ((b & 0xffff) << (16 * w))
        elif t == ord('B'):
            break
    return pm


def classify(op, prev):
    b = lambda h, l: (op >> l) & ((1 << (h - l + 1)) - 1)
    t = []
    if b(47, 45) == 1:
        dmd, pmd, dr, pr = b(44, 44), b(37, 37), b(36, 33), b(26, 23)
        t.append('t1')
        t.append('t1 DM %s PM %s' % ('w' if dmd else 'r', 'w' if pmd else 'r'))
        if not dmd and not pmd and dr == pr: t.append('t1 both loads one register')
        if dmd != pmd and dr == pr: t.append('t1 a store of the register the other move loads')
        c = b(22, 0)
        if c:
            res = {(c >> 8) & 15} | ({(c >> 12) & 15} if c >> 22 else set())
            if (not dmd and dr in res) or (not pmd and pr in res): t.append('t1 a load to a compute result')
            t.append('t1 multifunction' if c >> 22 else 't1 single compute')
        t.append('t1 PM block %d' % (0 if b(32, 30) < 4 else 1))
        pb = lambda h, l: (prev >> l) & ((1 << (h - l + 1)) - 1)
        if prev is not None and pb(47, 44) == 7 and pb(43, 36) == 0x10 + b(43, 41) and pb(30, 23) == 0x18 + b(32, 30):
            t.append('t1 both moves at one word (DM %s, PM %s)' % ('w' if dmd else 'r', 'w' if pmd else 'r'))
    elif b(47, 45) == 2 and b(32, 32): t.append('PM ureg pre/post (010)'); t.append('PM d=%d' % b(31, 31))
    elif b(47, 44) == 6 and b(40, 40): t.append('PM dreg imm modify (0110)')
    elif b(47, 44) == 8 and b(32, 32): t.append('PM imm shift (1000)')
    elif b(47, 42) == 4 and b(41, 41): t.append('PM direct (000100)')
    elif b(47, 45) == 5 and b(44, 44): t.append('PM indirect (101)')
    elif b(47, 44) == 9 and b(37, 37): t.append('PM immediate (1001)')
    return t


def main():
    tot = collections.Counter(); clk = collections.Counter(); allw = allc = 0
    args = sys.argv[1:]
    for k in range(0, len(args), 2):
        pm = load_pm(args[k])
        for ln in open(args[k + 1]):
            p = ln.split()
            pc, n, kc = int(p[0], 16), int(p[1]), int(p[2])
            allw += n; allc += kc
            for c in classify(pm.get(pc, 0), pm.get(pc - 1)):
                tot[c] += n; clk[c] += kc
    print('%-55s %12d words %8.4f clk_sys a word' % ('all', allw, allc / max(allw, 1)))
    for c, n in sorted(tot.items()):
        print('%-55s %12d words %8.4f clk_sys a word' % (c, n, clk[c] / max(n, 1)))


if __name__ == '__main__':
    main()
