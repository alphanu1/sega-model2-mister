#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- R1028 / R1029: one-word programs the core must flag as unsupported
# (tb_m2b_sharc +lock +noidle prints "UNSUPPORTED word at <pc>: <op> (reason <n>)"). Each is a
# MODE1 set-up, the words given, then the unsupported word at 0x20084 and a jump back. Generated,
# not ROM-derived.
#   m2b_unsupprog.py <out dir> [--pxim0]   writes u<k>.bin and cases.txt (<file> <pc> <reason>);
#   --pxim0 adds the words only the 2B build's core (PXIM 0, R1038) flags
import os, struct, sys

CASES = [   # (name, words before, the word, reason)
    # R1042: type 1 and PM-bus data are done; what of the PM bus is not
    ('PM-bus data past the on-chip PM (R0 = PM(0x22000))', [], (0b000100 << 42) | (1 << 41) | 0x22000, 3),
    ('PM-bus data in external PM (PM(I8, M8) = R0, I8 = 0x400000)', [0x0f1800400000, 0x0f2800000000],
     (0b010 << 45) | (1 << 44) | (1 << 32) | (1 << 31) | (0x1f << 33), 3),
    ('type 1 with its PM move outside the PM (I8 = 0x22000)', [0x0f1800022000, 0x0f1000030100], 0x200000000000, 3),
    ('PX over the PM bus (48-bit in MAME: PX = PM(0x21000))', [], (0b000100 << 42) | (1 << 41) | (0xdb << 32) | 0x21000, 9),
    ('MODE1 swap bit by a ureg write', [], 0x0f7b00018400, 5),
    ('MODE1 swap bit by a bit operation', [], 0x140b00000400, 5),
    ('SHARC-side DMA (DMAC6 DEN)', [0x0f0000000001], 0x11000000001c, 7),
    ('an unknown IOP register written', [], 0x110000000055, 7),
    ('an unknown IOP register read', [], 0x101000000055, 7),
    ('a jump outside the PM (R1029: its flag from X\'s first clock)', [], (0x06 << 40) | (0x1f << 33) | 0x30000, 9),
]
# R1038: unsupported only in the 2B build's core (m2b_sharc PXIM 0: no PX, no IMASK); with
# --pxim0 these are written too, and with PXIM 1 the same programs run (supported)
PXIM0_CASES = [
    ('PX1 written (immediate)', [], 0x0fdc00001234, 8),
    ('PX read by a ureg move (R0 = PX, IF TRUE)', [], 0x7dbf80000000, 8),
    ('IMASK written (immediate)', [], 0x0f7d00000003, 8),
    ('IMASK bit set', [], 0x140d00000001, 8),
]


def prog_events(pre, word):
    base = 0x20080
    prog = [(0x0f << 40) | (0x7b << 32) | 0x18000] + pre
    while len(prog) < 4: prog.append(0)
    prog += [word, 0, 0, (0x06 << 40) | (0x1f << 33) | base]
    pm = {base + k: w for k, w in enumerate(prog)}
    pm[0x20005] = (0x06 << 40) | (0x1f << 33) | base
    top = max(pm) + 1
    ev = bytearray()
    def rec(t, a, b): ev.extend(struct.pack('<BII', ord(t), a & 0xffffffff, b & 0xffffffff))
    for reg, val in [(0x1c, 0), (0x1c, 0), (0x40, 0), (0x40, 2), (0x41, 1), (0x41, 0),
                     (0x42, (top - 0x20000) & 0xffff), (0x42, 0), (0x1c, 0xa1), (0x1c, 0)]:
        rec('H', reg, val)
    n = 0
    for a in range(0x20000, top):
        w = pm.get(a, 0)
        for k in range(3):
            rec('U', n, (w >> (16 * k)) & 0xffff); n += 1
    rec('B', n, 0)
    return ev


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    lines = []
    cases = CASES + (PXIM0_CASES if '--pxim0' in sys.argv[2:] else [])
    for k, (name, pre, word, why) in enumerate(c for c in cases if c[3]):
        p = os.path.join(out, 'u%d.bin' % k)
        open(p, 'wb').write(prog_events(pre, word))
        lines.append('%s 20084 %d %s' % (p, why, name))
    open(os.path.join(out, 'cases.txt'), 'w').write('\n'.join(lines) + '\n')
    print('%d programs' % len(lines))


if __name__ == '__main__':
    main()
