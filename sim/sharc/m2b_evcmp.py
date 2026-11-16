#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- R1031: the whole-core 2B bench's coprocessor traffic
# against MAME's. MAME's side is a 2B capture (sim/sharc/mame_m2b_capture.patch's events.bin:
# U upload words, I / N the i960's pushes, O the SHARC's pushes); the core's is tb_m2_boot's
# M2_COPRO_TRACE text (C copro_ctl1 writes, W FIFO-port writes -- the upload while bit 31 is
# set, else pushes -- F function-port writes, O the coprocessor's pushes). Each stream is
# compared in order: how many agree from the start, the first difference, how far each got.
#   m2b_evcmp.py <events.bin> <copro trace> [show]
import struct, sys


def mame(path, nmax):
    up, push, out = [], [], []
    with open(path, 'rb') as f:
        while True:
            r = f.read(9 << 16)
            if not r: break
            for k in range(0, len(r) - 8, 9):
                t = r[k]; a, b = struct.unpack_from('<II', r, k + 1)
                if t == ord('U'): up.append(b & 0xffff)
                elif t in (ord('I'), ord('N')): push.append(b)
                elif t == ord('O'): out.append(b)
            if len(push) > nmax and len(out) > nmax: break
    return up, push, out


def core(path):
    up, push, out = [], [], []
    ctl = 0; fr_out = []
    for ln in open(path):
        p = ln.split()
        if not p: continue
        if p[0] == 'C': ctl = int(p[3], 16)
        elif p[0] == 'W':
            v = int(p[3], 16)
            if ctl & 0x80000000: up.append(v & 0xffff)
            else: push.append(v)
        elif p[0] == 'F':
            a = int(p[2], 16); v = int(p[3], 16)
            push.append((v & 0x800fffff) | (((a >> 4) & 0xff) << 23))
        elif p[0] == 'O':
            if int(p[2]) != 1: print('  (a coprocessor push record of %s words)' % p[2])
            out.append(int(p[3], 16)); fr_out.append(int(p[1]))
    return up, push, out, fr_out


def cmp(name, a, b, show):
    n = min(len(a), len(b))
    k = next((i for i in range(n) if a[i] != b[i]), n)
    bad = sum(1 for i in range(n) if a[i] != b[i])
    print('%-28s core %9d  MAME %9d  equal from the start %9d  differ (of the common %d) %d'
          % (name, len(a), len(b), k, n, bad))
    for i in range(k, min(n, k + show)):
        print('    #%d core %08x MAME %08x%s' % (i, a[i], b[i], '' if a[i] != b[i] else ' (equal)'))
    return k, bad


def main():
    show = int(sys.argv[3]) if len(sys.argv) > 3 else 4
    cu, cp, co, cf = core(sys.argv[2])
    mu, mp, mo = mame(sys.argv[1], max(len(cp), len(co)) + 16)
    cmp('upload words (16-bit)', cu, mu, show)
    cmp('i960 pushes (in FIFO)', cp, mp, show)
    cmp('SHARC pushes (out FIFO)', co, mo, show)
    if cf: print('  the core\'s first SHARC push at frame %d, its last at frame %d' % (cf[0], cf[-1]))


if __name__ == '__main__':
    main()
