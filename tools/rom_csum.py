#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Fold a region of the packed ROM image to the same 24-bit value the core's
# port-4 sweep produces, so the two can be compared by eye on the overlay.
#
# WHY A FOLD OVER THE CHIP AND NOT A COUNT AT THE LOADER
#
# The loader already reports its high-water mark, and that number is taken at
# the WRITE REQUEST -- before the FIFO, before the controller, before the
# device. It says what the loader asked for. It says nothing about what is in
# the chip. Model 1's `72131a3` makes the same distinction and is where this
# instrument comes from: a fold at the ioctl input proves the bytes arrived AT
# THE LOADER, which is not the question.
#
# The core sweeps the region on SDRAM port 4 -- otherwise unused -- and folds
# every 16-bit word into a 24-bit accumulator. Same arithmetic here, over the
# image the MRA would build, so a mismatch means the region did not survive the
# trip.
#
#   tools/rom_csum.py <mra> <zipdir> [start_word] [n_words]

import sys, os, zipfile
import xml.etree.ElementTree as ET

def build_image(mra_path, zip_dir):
    root = ET.parse(mra_path).getroot()
    out = bytearray()
    for rom in root.iter('rom'):
        names = (rom.get('zip') or '').split('|')
        zips = []
        for n in names:
            p = os.path.join(zip_dir, n.strip())
            if os.path.exists(p):
                zips.append(zipfile.ZipFile(p))
        def read(nm):
            for z in zips:
                try: return z.read(nm)
                except KeyError: continue
            raise SystemExit(f"missing from zips: {nm}")
        for ch in rom:
            if ch.tag == 'interleave':
                parts = [read(p.get('name')) for p in ch]
                maps  = [p.get('map') for p in ch]
                n = max(len(p) for p in parts)
                # map digits run MOST significant output byte first; digit d
                # means "input byte d" (1-based), 0 means contribute nothing.
                for i in range(0, n, 2):
                    word = bytearray(4)
                    for part, mp in zip(parts, maps):
                        for oi, d in enumerate(reversed(mp)):
                            if d == '0': continue
                            src = i + int(d) - 1
                            if src < len(part): word[oi] = part[src]
                    out += word
            elif ch.tag == 'part' and ch.get('name'):
                out += read(ch.get('name'))
    return bytes(out)

def fold(img, start_word, n_words):
    acc = 0
    for w in range(start_word, start_word + n_words):
        o = w * 2
        v = (img[o] | (img[o+1] << 8)) if o + 1 < len(img) else 0xffff
        acc = (acc + v) & 0xffffff
        acc = ((acc << 1) | (acc >> 23)) & 0xffffff   # rotate, so order matters
    return acc

if __name__ == '__main__':
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    mra, zdir = sys.argv[1], sys.argv[2]
    start = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0
    count = int(sys.argv[4], 0) if len(sys.argv) > 4 else 0x8000
    img = build_image(mra, zdir)
    print(f"  image      : 0x{len(img):X} bytes ({len(img)/1048576:.2f} MB)")
    print(f"  last word  : 0x{len(img)//2 - 1:X}")
    print(f"  fold over  : word 0x{start:X} .. 0x{start+count-1:X}")
    print(f"  EXPECTED   : {fold(img, start, count):06X}")
