#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# Every program in a Sega SCSP driver's tone bank (the format VCop2's
# driver reads at RAM 0x9000: word max index, word offsets; a program is
# 10-byte zones {max note, ?, level, transpose, voice word, EG words 4 / 5},
# or, when its first byte is 0x80, an FM program -- the driver then sets
# STWINH, MDL / MDXSL and the ring buffer from the record; study R856).
#   snd_bank_vcop2.py <zip> <prog rom> <bank address (68000 view)>
import sys
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from snd_rom_find import load

zp, prog, bank = sys.argv[1], sys.argv[2], int(sys.argv[3], 16)
p = load(zp, prog)
b = bank - 0x600000
w = lambda o: (p[o] << 8) | p[o + 1]
n = w(b) + 1
offs = [w(b + 2 + 2 * i) for i in range(n)]
fm = []
ends = sorted(set(offs)) + [None]
for i, o in enumerate(offs):
    rec = b + o
    nxt = [e for e in ends if e is not None and e > o]
    ln = (min(nxt) - o) if nxt else 64
    head = p[rec:rec + min(ln, 24)].hex()
    kind = 'FM' if p[rec] == 0x80 else ('drum?' if p[rec] == 0xff and p[rec + 1] == 0xff else 'zones')
    if kind == 'FM': fm.append(i)
    egs = []
    if kind == 'zones':
        z = rec
        while z + 10 <= rec + ln:
            egs.append((w(z + 6), w(z + 8)))
            if p[z] >= 0x7f: break
            z += 10
    flags = set()
    for w4, w5 in egs:
        if w4 & 0x20: flags.add('EGHOLD')
        if w5 & 0x4000: flags.add('LPSLNK')
        if ((w5 >> 10) & 15) != 0: flags.add('KRS%d' % ((w5 >> 10) & 15))
    print("prog %2d @%06x len %4d %-5s zones %2d %s  %s" % (i, bank + o, ln, kind, len(egs), ' '.join(sorted(flags)), head))
print("FM programs:", fm)
