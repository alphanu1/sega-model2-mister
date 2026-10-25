#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# The core's 3D framebuffers, copied out of DDR3 as they are. READ-ONLY: runs
# ON THE MISTER and only ever reads /dev/mem (opened O_RDONLY, mapped PROT_READ).
#
#   python3 m2-fbgrab.py                  one grab: both buffers, and which is on show
#   python3 m2-fbgrab.py -n 20            a burst: the next 20 distinct complete frames
#   python3 m2-fbgrab.py -n 40 -s 10      ... stopping after 10 s whatever it has
#   python3 m2-fbgrab.py -n 40 -r 100:180 a burst of lines 100-179 only (much faster)
#   python3 m2-fbgrab.py -o DIR           where to write (default /media/fat/fbgrab/<time>)
#   --torn                                keep the torn copies as well, marked so
#   --mem FILE --base N                   read FILE at offset N instead (a test on the PC)
#
# Then on the PC: tools/m2-fb2png.py DIR   (PNGs of every file, the painted mask,
# and what changed from frame to frame).
#
# THE LAYOUT (m2_fb_write / m2_fb_wcomb / m2_fb_read, R640). Byte address
# 0x30000000 (Model2.sv fb_base: 0x06000000 64-bit words, R654); buffer 1 is
# 1 MB above buffer 0; a line is 512 32-bit words, 2048 bytes, of which 496
# are shown; 384 lines. A word is {7'd0, painted, colour[23:0]}: bit 24 says
# the 3D painted the pixel (0 shows the tilemap through it); the colour is
# R[23:16] G[15:8] B[7:0], of which the scanout keeps R[23:19] G[15:10] B[7:3]
# (m2_raster3d scan_col). The even pixel is the low half of each 64-bit word,
# so in little-endian bytes pixel x of line y is at y * 2048 + x * 4. At 15 kHz
# (R682) a field's line y is row 2y + field: the buffer is always the frame.
#
# WHICH BUFFER IS ON SHOW. Nothing the HPS can read says so, so it is
# inferred from what changes. The core draws into one buffer while the other
# is shown (m2_raster3d fb_draw / fb_show): a buffer that changed between two
# copies is being cleared or drawn, and the OTHER is on screen. When neither is
# changing, the one that changed last is the newest complete frame, which is
# the one on show (fb_show takes it at the next frame edge). "unknown": neither
# was seen to change during the grab.
#
# A COPY IS KEPT ONLY WHEN IT IS COMPLETE: identical to a second copy of the
# same buffer read straight after it, so nothing wrote it in between. Each
# buffer is read twice in a row, then the other twice. A copy of all 384 lines
# takes some milliseconds on the HPS (the index records how many), and a game
# drawing at 60 frames a second leaves a buffer still for little more than a
# video frame -- if a full-frame burst keeps nothing, narrow it with -r to the
# lines round the thing being chased. In a burst each distinct complete frame
# is saved once, so a dot that flickers shows as a frame that has it beside
# frames that do not.
#
# Files: buf<B>.raw (one grab) or f<NNN>_b<B>.raw (burst), each the lines asked
# for, 2048 bytes a line exactly as DDR3 holds them; index.txt says the lines
# and, one row a file:  file  t_ms  buffer  shown|other|unknown  complete|torn  painted
import mmap, os, sys, time

BASE, BUF, STRIDE, LINES = 0x30000000, 1 << 20, 2048, 384


def header():
    out = []
    for ln in open(__file__).read().splitlines()[4:]:
        if not ln.startswith('#'): break
        out.append(ln[2:])
    return '\n'.join(out)


def main():
    a = sys.argv[1:]
    n, secs, out, y0, y1, torn = 0, None, None, 0, LINES, False
    dev, base = '/dev/mem', BASE
    i = 0
    while i < len(a):
        if a[i] == '-n': n = int(a[i + 1]); i += 2
        elif a[i] == '-s': secs = float(a[i + 1]); i += 2
        elif a[i] == '-o': out = a[i + 1]; i += 2
        elif a[i] == '-r':
            y0, y1 = (int(v) for v in a[i + 1].split(':')); i += 2
        elif a[i] == '--torn': torn = True; i += 1
        elif a[i] == '--mem': dev = a[i + 1]; i += 2
        elif a[i] == '--base': base = int(a[i + 1], 0); i += 2
        else:
            print(header()); sys.exit(1)
    if not (0 <= y0 < y1 <= 512): print('-r wants y0:y1 within 0:512'); sys.exit(1)
    burst = n > 0
    if secs is None: secs = 30.0 if burst else 3.0
    if out is None: out = '/media/fat/fbgrab/' + time.strftime('%Y%m%d-%H%M%S')
    os.makedirs(out, exist_ok=True)
    lo, size = y0 * STRIDE, (y1 - y0) * STRIDE

    fd = os.open(dev, os.O_RDONLY | os.O_SYNC)
    mm = mmap.mmap(fd, 2 * BUF, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)

    prev = [None, None]         # the last copy of each buffer
    changing = [False, False]   # its last two copies differed
    last_change = [-1.0, -1.0]  # when it was last seen to change (ms)
    saved_last = [None, None]   # burst: the last frame of it saved, so each is saved once
    newest = [None, None]       # one grab: the newest complete copy of each
    kept = []                   # (name, t_ms, buffer, shown, complete, data)
    copies, busy = 0, 0.0
    t0 = time.monotonic()

    def shown_of(b):
        o = b ^ 1
        if changing[o]: return 'shown'
        if changing[b]: return 'other'
        if last_change[b] < 0 and last_change[o] < 0: return 'unknown'
        return 'shown' if last_change[b] > last_change[o] else 'other'

    seq = 0                     # buffer 0, 0, 1, 1, 0, 0, ...
    while True:
        now = time.monotonic()
        if now - t0 >= secs: break
        if burst and len(kept) >= n: break
        if not burst and newest[0] and newest[1] and (last_change[0] >= 0 or last_change[1] >= 0):
            break
        b = (seq >> 1) & 1; seq += 1
        c0 = time.monotonic()
        data = mm[BUF * b + lo: BUF * b + lo + size]
        c1 = time.monotonic()
        copies += 1; busy += c1 - c0
        t = (c1 - t0) * 1000.0
        same = prev[b] is not None and data == prev[b]
        # complete: equal to the copy read just before it, of the same buffer
        complete = same and (seq & 1) == 0
        if prev[b] is not None and not same:
            changing[b] = True; last_change[b] = t
        elif same:
            changing[b] = False
        prev[b] = data
        if burst:
            if complete and data != saved_last[b]:
                saved_last[b] = data
                kept.append(('f%03d_b%d.raw' % (len(kept), b), t, b, shown_of(b), 'complete', data))
            elif torn and not same and (seq & 1) == 0:
                kept.append(('f%03d_b%d.raw' % (len(kept), b), t, b, shown_of(b), 'torn', data))
        elif complete:
            newest[b] = (t, data)

    elapsed = time.monotonic() - t0
    if not burst:
        for b in (0, 1):
            if newest[b]:
                kept.append(('buf%d.raw' % b, newest[b][0], b, shown_of(b), 'complete', newest[b][1]))
            elif prev[b] is not None:   # never read the same twice: the last copy, marked torn
                kept.append(('buf%d.raw' % b, elapsed * 1000.0, b, shown_of(b), 'torn', prev[b]))
    ms = 1000.0 * busy / max(copies, 1)
    with open(os.path.join(out, 'index.txt'), 'w') as ix:
        ix.write('# m2-fbgrab %s base 0x%08x stride %d\n' % (dev, base, STRIDE))
        ix.write('# rows %d %d\n' % (y0, y1))
        ix.write('# %d copies in %.2f s, %.1f ms a copy (%.1f MB/s)\n'
                 % (copies, elapsed, ms, size / max(ms, 1e-3) / 1e3))
        ix.write('# file t_ms buffer shown complete painted\n')
        for name, t, b, sh, cp, data in kept:
            open(os.path.join(out, name), 'wb').write(data)
            painted = sum(v & 1 for v in data[3::4])
            row = '%s %.1f %d %s %s %d' % (name, t, b, sh, cp, painted)
            ix.write(row + '\n'); print(row)
    print('%d file(s) in %s -- lines %d-%d, %d copies in %.2f s, %.1f ms a copy'
          % (len(kept), out, y0, y1 - 1, copies, elapsed, ms))
    if burst and not any(k[4] == 'complete' for k in kept):
        print('no complete copy: the buffers changed faster than a copy -- narrow the lines with -r')


if __name__ == '__main__':
    main()
