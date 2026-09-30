#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# Is the 3D lit? Runs ON THE MISTER: python3 m2-fbcheck.py [seconds] [interval]
#
# Samples both DDR3 framebuffers (0x30000000, 1 MB apart, 512 words of 32 bits
# a line, bit 24 = painted) every `interval` seconds and prints, per sample and
# buffer, how many pixels the 3D painted and their mean brightness (R+G+B,
# 0..765). A lit attract frame reads ~300-400; the "everything black" fault
# (R254/R697: the light table read as 0/0) reads near zero with the 3D still
# painted. Each sample is also written to /tmp/fbcheck_NN.bin for a closer look.
import mmap, os, struct, sys, time

secs = float(sys.argv[1]) if len(sys.argv) > 1 else 180
step = float(sys.argv[2]) if len(sys.argv) > 2 else 8
fd = os.open('/dev/mem', os.O_RDONLY | os.O_SYNC)
mm = mmap.mmap(fd, 2 << 20, mmap.MAP_SHARED, mmap.PROT_READ, offset=0x30000000)

def stats(buf, b):
    painted = lum = dark = 0
    for y in range(0, 384, 2):                     # every other line is plenty
        base = (b << 20) + y * 2048
        for x in range(0, 496, 2):
            v = struct.unpack_from('<I', buf, base + x * 4)[0]
            if v & 0x1000000:
                s = ((v >> 16) & 255) + ((v >> 8) & 255) + (v & 255)
                painted += 1; lum += s
                if s < 40: dark += 1
    return painted, lum // max(painted, 1), 100 * dark // max(painted, 1)

t0 = time.monotonic(); n = 0; worst = 999
while time.monotonic() - t0 < secs:
    snap = mm[:2 << 20]
    open('/tmp/fbcheck_%02d.bin' % n, 'wb').write(snap)
    line = []
    for b in (0, 1):
        p, m, dk = stats(snap, b)
        line.append('buf%d painted %5d mean %3d dark %2d%%' % (b, p, m, dk))
        if p > 2000: worst = min(worst, m)
    print('%3d  %5.0fs  %s' % (n, time.monotonic() - t0, '   '.join(line)), flush=True)
    n += 1
    time.sleep(step)
print('lowest mean brightness of a painted frame: %d  (lit attract ~300-400; black fault near 0)' % worst)
