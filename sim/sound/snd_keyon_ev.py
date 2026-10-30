#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# Study R976.
# Usage: snd_keyon_ev.py <SND_DUMP file> > ev.txt
# our key-ons from a SND_DUMP as "t class" lines (class as grid.py / MAME's: res<sa> or str<pitch>)
import sys, collections
regs = collections.defaultdict(lambda: [0]*16)
for l in open(sys.argv[1]):
    p = l.split()
    if p[0] != 'ours': continue
    t = float(p[1]); off = int(p[2], 16); d = int(p[3], 16); m = int(p[4], 16)
    if off >= 0x400: continue
    s, r = off >> 5, (off & 0x1f) >> 1
    regs[s][r] = (regs[s][r] & ~m) | (d & m)
    if r == 0 and (m & 0xff00) and (d & 0x1800) == 0x1800:
        w = regs[s]; sa = ((w[0] & 0xf) << 16) | w[1]
        print('%.6f %s' % (t, ('res%05x' % sa) if sa >= 0x50000 else ('str%04x' % w[8])))
