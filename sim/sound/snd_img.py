#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# A Model 2A game's sound program and samples as the 68000 sees them (big-end
# first; MAME's ROM_LOAD16_WORD_SWAP undone), for tb_m2_2a_sound (study R859).
# Reads the ROM zip only; writes under the given directory (git-ignored).
#   snd_img.py <zip> <prog rom> <sample rom,sample rom,...> <out dir>
import sys, os, zipfile

def load(z, name):
    d = bytearray(z.read(name))
    for i in range(0, len(d) - 1, 2):
        d[i], d[i + 1] = d[i + 1], d[i]
    return bytes(d)

zp, prog, samples, out = sys.argv[1:5]
z = zipfile.ZipFile(zp)
os.makedirs(out, exist_ok=True)
open(os.path.join(out, 'prog.bin'), 'wb').write(load(z, prog))
open(os.path.join(out, 'samp.bin'), 'wb').write(b''.join(load(z, n) for n in samples.split(',')))
p = load(z, prog)
print('sound program: SP %08x PC %08x' % (int.from_bytes(p[0:4], 'big'), int.from_bytes(p[4:8], 'big')))
