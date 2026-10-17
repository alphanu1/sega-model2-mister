#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# CHECK AN MRA'S IMAGE AGAINST MAME'S OWN ROM_START, REGION BY REGION (R835).
#
# tools/rom_csum.py builds the image the MRA describes. This builds what MAME
# loads -- from model2.cpp's ROM_START(<set>) text and the zip, by CRC, with
# MAME's load semantics (ROM_LOAD32_WORD, ROM_LOAD16_WORD_SWAP, ROM_LOAD,
# unloaded space 0) -- and compares each of the core's fixed '93 slots with
# the region MAME would show there. The two share no code, so an MRA mistake
# has to be made twice, in two different languages, to pass.
#
#   tools/mra_vs_mame.py <image.bin> <model2.cpp> <set> <zip>[,<zip>...] [--layout=2a]
#
# <image.bin> is `tools/rom_csum.py <mra> <romdir> --out image.bin`. Every
# file is ROM-derived; keep them outside the repository.

import re, sys, zipfile, zlib

# The core's slots: the Daytona '93 MRA's offsets (docs/rom-layout.md), and
# the program's second half after the '93 image (R726). (name, image offset,
# size, MAME region, offset in the region)
SLOTS = [
    ("program 0-256K",   0x0000000, 0x040000, "maincpu",          0x000000),
    ("main_data",        0x0040000, 0xa00000, "main_data",        0x000000),
    ("copro_data",       0x0a40000, 0x400000, "copro_data",       0x000000),
    ("textures",         0x0e40000, 0x800000, "textures",         0x000000),
    ("polygons",         0x1640000, 0xd00000, "polygons",         0x000000),
    ("68000 program",    0x2340000, 0x040000, "m1audio:sndcpu",   0x000000),
    ("MPCM1",            0x2380000, 0x400000, "m1audio:pcm1",     0x000000),
    ("MPCM2",            0x2780000, 0x400000, "m1audio:pcm2",     0x000000),
    ("comms",            0x2b80000, 0x020000, "comms",            0x000000),
    ("TGP tables",       0x2ba0000, 0x040000, "copro_tgp_tables", 0x000000),
    ("program 256-512K", 0x2be0000, 0x040000, "maincpu",          0x040000),
]
# R852: the Model 2A core's layout (branch model2a; Model2.sv M2_2A): the
# program whole, 16 MB of data, no copro data, the samples last (the loader
# moves them above the RAMs). `--layout 2a` checks an MRA against these.
SLOTS_2A = [
    ("program",          0x0000000, 0x080000, "maincpu",          0x000000),
    ("main_data",        0x0080000, 0x1000000, "main_data",       0x000000),
    ("textures 0-4M",    0x1080000, 0x400000, "textures",         0x000000),
    ("textures 8-12M",   0x1480000, 0x400000, "textures",         0x800000),
    ("polygons",         0x1880000, 0xc00000, "polygons",         0x000000),
    ("TGP tables",       0x2480000, 0x040000, "copro_tgp_tables", 0x000000),
    ("68000 program",    0x24c0000, 0x080000, "audiocpu",         0x000000),
    ("samples",          0x2540000, 0x800000, "samples",          0x000000),
]
IMG_END_2A = 0x2d40000
# R862: the 2A layout's extension, appended after VF2's image (whose slots do
# not move) and put by the loader's second remap (XTRA2) in the 2A SDRAM hole:
# the program above 512 KB (Sega Rally and Zero Gunner 1 MB, Virtua Cop 2
# 2 MB), then the TGP's copro data (Sega Rally only). A set whose MAME region
# has data there must carry the slot; one that does not may end before it.
SLOTS_2A_EXT = [
    ("program 512K-2M",  0x2d40000, 0x180000, "maincpu",          0x080000),
    ("copro_data",       0x2ec0000, 0x400000, "copro_data",       0x000000),
]
IMG_ENDS_2A = (0x2d40000, 0x2ec0000, 0x32c0000)
ALIAS = {"M1AUDIO_CPU_REGION": "m1audio:sndcpu", "M1AUDIO_MPCM1_REGION": "m1audio:pcm1",
         "M1AUDIO_MPCM2_REGION": "m1audio:pcm2",
         "cpu3": "comms", "cpu4": "comms"}   # daytona names it cpu3, desert / vcopa cpu4

def rom_start(src, name):
    m = re.search(r"ROM_START\(\s*%s\s*\)(.*?)ROM_END" % re.escape(name), src, re.S)
    if not m:
        raise SystemExit(f"no ROM_START({name})")
    body = m.group(1)
    if "MODEL2_CPU_BOARD" in body:
        mb = re.search(r"#define MODEL2_CPU_BOARD(.*?)\n/\*", src, re.S)
        body = body.replace("MODEL2_CPU_BOARD", mb.group(1).replace("\\\n", "\n"))
    return body

def build(body, zips):
    by_crc = {}
    for z in zips:
        for zi in z.infolist():
            by_crc.setdefault(zi.CRC, (z, zi))
    regions, cur = {}, None
    for line in body.splitlines():
        line = line.split("//")[0]
        m = re.search(r"ROM_REGION(?:\d\d_[LB]E)?\(\s*(0x[0-9a-fA-F]+)\s*,\s*([\w\"]+)", line)
        if m:
            size = int(m.group(1), 16)
            tag = m.group(2).strip('"')
            tag = ALIAS.get(tag, tag)
            regions[tag] = bytearray(size)          # unloaded space reads 0
            cur = tag
            continue
        m = re.search(r"(ROM_LOAD32_WORD|ROM_LOAD16_WORD_SWAP|ROM_LOAD)\(\s*\"([^\"]+)\"\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*CRC\(([0-9a-fA-F]+)\)", line)
        if not m:
            continue
        kind, fname, off, ln, crc = m.group(1), m.group(2), int(m.group(3), 16), int(m.group(4), 16), int(m.group(5), 16)
        if crc not in by_crc:
            raise SystemExit(f"{fname} crc {crc:08x}: not in the zips")
        z, zi = by_crc[crc]
        d = z.read(zi)
        if len(d) != ln or (zlib.crc32(d) & 0xffffffff) != crc:
            raise SystemExit(f"{fname}: size/crc mismatch")
        r = regions[cur]
        if kind == "ROM_LOAD32_WORD":
            # 16 bits of every 32: the file's word i lands at off + 4*i.
            for i in range(0, ln, 2):
                r[off + 2 * i: off + 2 * i + 2] = d[i:i + 2]
        elif kind == "ROM_LOAD16_WORD_SWAP":
            # Stored here as the bytes a big-endian bus presents in address
            # order: the file's pairs swapped.
            for i in range(0, ln, 2):
                r[off + i] = d[i + 1]; r[off + i + 1] = d[i]
        else:
            r[off:off + ln] = d
    # ROM_COPY( "region", src, dst, len ) -- Virtua Cop 2's main_data mirrors
    for m in re.finditer(r"ROM_COPY\(\s*\"([^\"]+)\"\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*\)", body):
        r = regions[m.group(1)]
        src, dst, ln = (int(m.group(i), 16) for i in (2, 3, 4))
        r[dst:dst + ln] = r[src:src + ln]
    return regions

def init_patches(src, setname, regions):
    """R862: the GAME line's init function, if it writes maincpu words
    (init_zerogun: ROM[0x700/4] = 0x08000004), applied as MAME applies it."""
    g = re.search(r"GAME\(\s*\d+\??\s*,\s*%s\s*,[^,]*,[^,]*,[^,]*,[^,]*,\s*(\w+)" % re.escape(setname), src)
    if not g or g.group(1) == "empty_init":
        return []
    f = re.search(r"::%s\(\)\s*\{(.*?)\n\}" % re.escape(g.group(1)), src, re.S)
    out = []
    for m in re.finditer(r"^\s*ROM\[(0x[0-9a-fA-F]+)\s*/\s*4\]\s*=\s*(0x[0-9a-fA-F]+)\s*;", f.group(1) if f else "", re.M):
        off, val = int(m.group(1), 16), int(m.group(2), 16)
        regions["maincpu"][off:off + 4] = val.to_bytes(4, "little")
        out.append((g.group(1), off, val))
    return out

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--layout")]
    m2a = "--layout=2a" in sys.argv[1:] or "--layout2a" in sys.argv[1:]
    img_path, src_path, setname, zipnames = args[0], args[1], args[2], args[3]
    img = open(img_path, "rb").read()
    src = open(src_path, encoding="utf-8", errors="replace").read()
    zips = [zipfile.ZipFile(z) for z in zipnames.split(",")]
    regions = build(rom_start(src, setname), zips)
    for fn, off, val in init_patches(src, setname, regions):
        print(f"  {fn}: maincpu 0x{off:X} = 0x{val:08X} (applied to MAME's side)")
    bad = 0
    slots = SLOTS
    if m2a:
        slots = list(SLOTS_2A)
        for s_ in SLOTS_2A_EXT:
            name, io, size, tag, roff = s_
            need = any(regions.get(tag, b"")[roff:roff + size])
            if len(img) > io or need:
                slots.append(s_)
                if need and len(img) < io + size:
                    print(f"  {name:18s} MAME has data here and the image does not carry the slot")
    for name, io, size, tag, roff in slots:
        want = bytes(regions.get(tag, b"")[roff:roff + size])
        want += bytes(size - len(want))              # past the region: 0 (the MRA's pad)
        got = img[io:io + size]
        if len(got) < size:
            print(f"  {name:18s} image ends inside the slot"); bad += 1; continue
        if got == want:
            nz = sum(1 for i in range(0, size, 4096) if any(got[i:i + 4096]))
            print(f"  {name:18s} 0x{io:07X} +0x{size:06X}  == MAME {tag}[0x{roff:X}..]   ({nz} of {size // 4096} 4K pages non-zero)")
        else:
            first = next(i for i in range(size) if got[i] != want[i])
            print(f"  {name:18s} 0x{io:07X}  DIFFERS from MAME {tag} at +0x{first:X}"); bad += 1
    if m2a:
        # the 2A core has no sound scan: the 68000 program's base is fixed
        if len(img) not in IMG_ENDS_2A:
            print(f"  image size 0x{len(img):X}, expected one of "
                  + ", ".join(f"0x{e:X}" for e in IMG_ENDS_2A)); bad += 1
        print("PASS" if bad == 0 else f"FAIL ({bad})")
        sys.exit(1 if bad else 0)
    if len(img) != 0x2be0000 + 0x40000:
        print(f"  image size 0x{len(img):X}, expected 0x2C20000"); bad += 1
    # The sound scan (Model2.sv SC_*): 64 KB steps from byte 0x1000000, the
    # first 00F0FFFE 00000300 as the 68000 reads it is the sound base.
    hit = next((a for a in range(0x1000000, 0x2c00000 + 1, 0x10000)
                if img[a:a + 8] == bytes.fromhex("00f0fffe00000300")), None)
    print(f"  sound scan finds  : {hex(hit) if hit is not None else 'NOTHING'} (want 0x2340000)")
    if hit != 0x2340000: bad += 1
    print("PASS" if bad == 0 else f"FAIL ({bad})")
    sys.exit(1 if bad else 0)

if __name__ == "__main__":
    main()
