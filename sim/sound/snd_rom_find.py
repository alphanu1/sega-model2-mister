#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# Find a byte string in a Model 2A game's sound program ROM (68000 view at
# 0x600000) and its sample ROM (0x800000, the four 2 MB parts in MAME's
# order), as the 68000 sees them (study R856).
#   snd_rom_find.py <zip> <prog rom> <sample rom,sample rom,...> <hex bytes>
import sys, zipfile

def load(zp, name):
    d = bytearray(zipfile.ZipFile(zp).read(name))
    for i in range(0, len(d) - 1, 2):
        d[i], d[i + 1] = d[i + 1], d[i]
    return bytes(d)

def image(zp, prog, samples):
    p = load(zp, prog)
    s = b''.join(load(zp, n) for n in samples.split(','))
    return p, s

if __name__ == '__main__':
    zp, prog, samples, pat = sys.argv[1], sys.argv[2], sys.argv[3], bytes.fromhex(sys.argv[4])
    p, s = image(zp, prog, samples)
    for base, img in ((0x600000, p), (0x800000, s)):
        i = img.find(pat)
        while i >= 0:
            print("%06x" % (base + i))
            i = img.find(pat, i + 1)
