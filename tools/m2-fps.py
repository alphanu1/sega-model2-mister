#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# 3D frames per second, measured on the board from Linux, no core changes.
# Runs ON THE MISTER (python3 is there): python3 m2-fps.py [seconds]
#
# The core clears a framebuffer (DDR3, 0x30000000, two buffers 1 MB apart,
# 512 words of 32 bits a line) each time it starts drawing a new display list.
# A marker word with the painted flag (bit 24) off is planted in the right-hand
# visible column of three lines of each buffer; when all three have been wiped,
# that buffer has been cleared for a new frame. Clears per second, both
# buffers together, is the 3D frame rate. The markers are unpainted pixels, so
# the tilemap shows through them, as it does through any pixel the 3D misses.
import mmap, os, struct, sys, time

BASE, SPAN = 0x30000000, 2 << 20
LINES, X = (1, 191, 383), 494
MARK = 0x00A5C35A                       # bit 24 clear: not painted

fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
mm = mmap.mmap(fd, SPAN, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=BASE)
def off(b, y): return (b << 20) + y * 2048 + X * 4
def rd(o): return struct.unpack_from('<I', mm, o)[0]
def plant(b):
    for y in LINES: struct.pack_into('<I', mm, off(b, y), MARK)

secs = float(sys.argv[1]) if len(sys.argv) > 1 else 20
plant(0); plant(1)
t0 = time.monotonic(); last = t0; n = 0; per = []; stamps = []
while True:
    now = time.monotonic()
    if now - t0 >= secs: break
    for b in (0, 1):
        if all(rd(off(b, y)) != MARK for y in LINES):
            n += 1; stamps.append(now); plant(b)
    if now - last >= 1.0:
        per.append(n); n = 0; last += 1.0
    time.sleep(0.0005)
gaps = [1000 * (b - a) for a, b in zip(stamps, stamps[1:])]
print('3D frames each second:', ' '.join(str(p) for p in per))
if per: print('mean %.1f fps over %d s' % (sum(per) / len(per), len(per)))
if gaps:
    gaps.sort()
    print('frame time ms: min %.1f  median %.1f  max %.1f  (video frame 17.4 ms at 57.5 Hz)'
          % (gaps[0], gaps[len(gaps) // 2], gaps[-1]))
    # in video frames: how many vblanks each 3D frame took (1 = the game's rate)
    hist = {}
    for g in gaps:
        k = max(1, round(g / 17.39)); hist[k] = hist.get(k, 0) + 1
    print('vblanks per 3D frame:', '  '.join('%d: %d%%' % (k, 100 * v // len(gaps)) for k, v in sorted(hist.items())))
