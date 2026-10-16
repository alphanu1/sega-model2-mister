#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# The sound RAM as the 68000 left it at sample N, rebuilt from a p16 capture's
# ramw.bin (study R856); written big-endian (the 68000's view) to <out>.
#   snd_ram_at.py <capture dir> <sample N> <out.bin>
import sys, numpy as np
d, n, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
r = np.fromfile(d + '/ramw.bin', dtype=[('n', '<u4'), ('a', '<u4'), ('dm', '<u4')])
r = r[r['n'] <= n]
ram = np.zeros(0x40000, dtype=np.uint16)
a = (r['a'] & 0x7fffe) >> 1
v = (r['dm'] & 0xffff).astype(np.uint16)
m = (r['dm'] >> 16).astype(np.uint16)
for i in range(len(r)):           # in order: later writes win, masks merge
    ram[a[i]] = (ram[a[i]] & ~m[i]) | (v[i] & m[i])
ram.byteswap().tofile(out)
print("writes applied:", len(r))
