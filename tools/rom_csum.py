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
#   tools/rom_csum.py <mra> <zipdir> --region N      one 2 MB region, as the OSD
#   tools/rom_csum.py <mra> <zipdir> --scan          every region, for bisecting
#
# --zip NAME.zip adds a zip to the search, repeatable. A MiSTer MRA names the
# MERGED set it expects on the target ("daytona93.zip"), but a local MAME romset
# is usually SPLIT, with the shared parts in the parent ("daytona.zip"). The MRA
# is what the board loads and must not be edited to suit this tool, so the extra
# zip is named here instead:
#
#   --zip daytona.zip
#
# --region N matches the core's "Sweep region (2MB)" OSD option exactly: word
# N*0x100000 for 0x100000 words. Walk N on the board and here together; the
# first N where they disagree is where the chip stops holding the image.
#
# PAST THE END OF THE IMAGE THIS MEANS NOTHING. Out there the fold below reads
# 0xFFFF because that is what an unwritten read returns by contract -- but
# nothing wrote those words in the chip either, and real SDRAM comes up holding
# whatever it holds. --scan marks those regions rather than printing a number
# that invites a comparison it cannot support.

import sys, os, zipfile
import xml.etree.ElementTree as ET

def build_image(mra_path, zip_dir, extra=()):
    root = ET.parse(mra_path).getroot()
    out = bytearray()
    for rom in root.iter('rom'):
        names = (rom.get('zip') or '').split('|') + list(extra)
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

RGN = 0x100000          # words per region -- 2 MB, and the core's OSD step

if __name__ == '__main__':
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    mra, zdir = sys.argv[1], sys.argv[2]
    argv, extra = sys.argv[3:], []
    rest = []
    i = 0
    while i < len(argv):
        if argv[i] == '--zip':
            extra.append(argv[i+1]); i += 2
        else:
            rest.append(argv[i]); i += 1
    img = build_image(mra, zdir, extra)
    nwords = len(img) // 2
    print(f"  image      : 0x{len(img):X} bytes ({len(img)/1048576:.2f} MB)")
    print(f"  last word  : 0x{nwords - 1:X}")

    if rest and rest[0] == '--scan':
        print(f"  {'rgn':>3}  {'first word':>10}  {'expected':>8}")
        for n in range((nwords + RGN - 1) // RGN):
            end = (n + 1) * RGN
            tail = '' if end <= nwords else '   <- runs past the image, not evidence'
            print(f"  {n:>3}  0x{n*RGN:08X}  {fold(img, n*RGN, RGN):06X}{tail}")
        raise SystemExit(0)

    if rest and rest[0] == '--region':
        n = int(rest[1], 0)
        start, count = n * RGN, RGN
        if start + count > nwords:
            print(f"  WARNING    : region {n} runs past the image; a mismatch here")
            print(f"               proves nothing -- see the note in this file.")
    else:
        start = int(rest[0], 0) if len(rest) > 0 else 0
        count = int(rest[1], 0) if len(rest) > 1 else 0x8000

    print(f"  fold over  : word 0x{start:X} .. 0x{start+count-1:X}")
    print(f"  EXPECTED   : {fold(img, start, count):06X}")
