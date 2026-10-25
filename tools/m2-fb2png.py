#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# Framebuffer grabs (tools/m2-fbgrab.py, on the board; tb_m2_raster3d
# M2_R3D_FBRAW, on the bench) to PNGs. Runs on the PC; standard library only.
#
#   m2-fb2png.py DIR                    every .raw in a grab directory (its index.txt)
#   m2-fb2png.py a.raw [b.raw ...]      files (lines from 0 unless --y0 says otherwise)
#     -o OUT         where the PNGs go (default: beside the files)
#     --scale N      each pixel N x N (nearest), for looking at single dots
#     --crop x,y,w,h only that part of the frame (frame coordinates)
#     --bg RRGGBB    what an unpainted pixel shows as (default ff00ff: the tilemap's place)
#     --full888      the stored 24-bit colour instead of what the scanout shows
#     --px x,y[,r]   print the words round a pixel (r = 2: a 5 x 5 block), every file
#     --y0 N         the first line a bare file holds (index.txt gives it otherwise)
#
# For each file: NAME.png, the colour exactly as the core shows it -- the word's
# R[23:19] G[15:10] B[7:3] (m2_raster3d scan_col), widened as Model2.sv does
# (r3d_r8 = {r[4:0], r[4:2]} and so on) -- with unpainted pixels in --bg; and
# NAME_mask.png, painted white, unpainted black, and red where the seven bits
# above the painted flag are not zero (nothing writes them: a red pixel is a
# word the core did not write, or not the framebuffer at all). A bench file's
# never-written words are 0xFFFFFFFF and show red.
# With more than one file, NAME_diff.png against the file before it (in a
# burst, the frame before -- the other buffer): unchanged pixels dimmed, changed
# ones at full colour, and the changed pixels listed when there are few. A dot
# that flickers is a few changed pixels between two complete frames.
#
# The colour tilemap (2D) is not in this memory: the core composites the 3D over
# it at the scanout. Where a tile has priority over the 3D (tile_cat1) the
# screen shows the tile even though the 3D painted the pixel.
import os, struct, sys, zlib

STRIDE, W = 512, 496


def png(path, w, h, rows):
    """rows: list of bytes, each w*3 RGB"""
    raw = b''.join(b'\x00' + r for r in rows)
    def chunk(t, d):
        c = struct.pack('>I', len(d)) + t + d
        return c + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(raw, 6)))
        f.write(chunk(b'IEND', b''))


def shown(v):
    """the 24-bit RGB the screen shows for a painted word (Model2.sv r3d_r8/g8/b8)"""
    r5, g6, b5 = (v >> 19) & 31, (v >> 10) & 63, (v >> 3) & 31
    return ((r5 << 3) | (r5 >> 2), (g6 << 2) | (g6 >> 4), (b5 << 3) | (b5 >> 2))


def load(path):
    d = open(path, 'rb').read()
    if len(d) % (STRIDE * 4): raise SystemExit('%s: %d bytes is not whole 2048-byte lines' % (path, len(d)))
    return struct.unpack('<%dI' % (len(d) // 4), d), len(d) // (STRIDE * 4)


def main():
    a = sys.argv[1:]
    if not a: print(open(__file__).read().split('import os')[0]); sys.exit(1)
    out, scale, crop, bg, full, pxs, y0a, files = None, 1, None, (255, 0, 255), False, [], None, []
    i = 0
    while i < len(a):
        k = a[i]
        if k == '-o': out = a[i + 1]; i += 2
        elif k == '--scale': scale = int(a[i + 1]); i += 2
        elif k == '--crop': crop = [int(v) for v in a[i + 1].split(',')]; i += 2
        elif k == '--bg': c = int(a[i + 1], 16); bg = (c >> 16, (c >> 8) & 255, c & 255); i += 2
        elif k == '--full888': full = True; i += 1
        elif k == '--px': pxs.append([int(v) for v in a[i + 1].split(',')]); i += 2
        elif k == '--y0': y0a = int(a[i + 1]); i += 2
        else: files.append(k); i += 1
    y0, meta = 0, {}
    if len(files) == 1 and os.path.isdir(files[0]):
        d = files[0]; ix = os.path.join(d, 'index.txt'); files = []
        if os.path.exists(ix):
            for ln in open(ix):
                p = ln.split()
                if ln.startswith('# rows'): y0 = int(p[2])
                elif p and not ln.startswith('#'):
                    files.append(os.path.join(d, p[0])); meta[files[-1]] = ' '.join(p[1:])
        else:
            files = sorted(os.path.join(d, f) for f in os.listdir(d) if f.endswith('.raw'))
    if y0a is not None: y0 = y0a
    last = {}   # buffer size -> (path, words)
    for path in files:
        wd, h = load(path)
        x0, ya, cw, ch = (crop if crop else (0, y0, W, h))
        ya = max(ya, y0); ch = min(ch, y0 + h - ya); cw = min(cw, W - x0)
        if cw <= 0 or ch <= 0: print('%s: the crop is outside lines %d-%d' % (path, y0, y0 + h - 1)); continue
        base = os.path.splitext(os.path.basename(path))[0]
        od = out or os.path.dirname(os.path.abspath(path)); os.makedirs(od, exist_ok=True)
        img, msk = [], []
        painted = pad = 0
        for y in range(ya, ya + ch):
            r1, r2 = bytearray(), bytearray()
            for x in range(x0, x0 + cw):
                v = wd[(y - y0) * STRIDE + x]
                if v >> 25: pad += 1
                if v & 0x1000000:
                    painted += 1
                    c = ((v >> 16) & 255, (v >> 8) & 255, v & 255) if full else shown(v)
                    m = (255, 255, 255)
                else:
                    c = bg; m = (0, 0, 0)
                if v >> 25: m = (255, 0, 0)
                r1 += bytes(c) * scale; r2 += bytes(m) * scale
            img += [bytes(r1)] * scale; msk += [bytes(r2)] * scale
        png(os.path.join(od, base + '.png'), cw * scale, ch * scale, img)
        png(os.path.join(od, base + '_mask.png'), cw * scale, ch * scale, msk)
        note = ('  [' + meta[path] + ']') if path in meta else ''
        print('%s: lines %d-%d, painted %d of %d, pad bits set %d%s'
              % (base, ya, ya + ch - 1, painted, cw * ch, pad, note))
        for p in pxs:
            px, py = p[0], p[1]; r = p[2] if len(p) > 2 else 2
            print('  words round (%d,%d):' % (px, py))
            for y in range(py - r, py + r + 1):
                s = []
                for x in range(px - r, px + r + 1):
                    if 0 <= x < STRIDE and y0 <= y < y0 + h: s.append('%08x' % wd[(y - y0) * STRIDE + x])
                    else: s.append('   --   ')
                print('   y%3d ' % y + ' '.join(s))
        key = len(wd)
        if key in last:
            pp, pw = last[key]; dif = []
            rows = []
            for y in range(ya, ya + ch):
                rr = bytearray()
                for x in range(x0, x0 + cw):
                    o = (y - y0) * STRIDE + x; v, u = wd[o], pw[o]
                    c = shown(v) if v & 0x1000000 else bg
                    if v != u:
                        dif.append((x, y, u, v))
                    else:
                        c = tuple(q // 4 for q in c)
                    rr += bytes(c) * scale
                rows += [bytes(rr)] * scale
            png(os.path.join(od, base + '_diff.png'), cw * scale, ch * scale, rows)
            print('  %d pixels changed from %s' % (len(dif), os.path.basename(pp)))
            if 0 < len(dif) <= 40:
                for x, y, u, v in dif: print('    (%d,%d) %08x -> %08x' % (x, y, u, v))
        last[key] = (path, wd)


if __name__ == '__main__':
    main()
