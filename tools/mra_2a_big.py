#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# WRITE THE <rom index="0"> BODY OF A LARGE-LAYOUT 2A MRA FROM MAME'S ROM_START
# (R897). The layout is Model2.sv's a2_big (study R897):
#
#   0x0000000  i960 program 0-512 KB          maincpu 0x000000
#   0x0080000  main_data, 32 MB               main_data 0x0000000 (ROM_COPY
#                                             mirrors written out)
#   0x2080000  4 MB of zeros
#   0x2480000  TGP math tables, 256 KB        copro_tgp_tables
#   0x24C0000  68000 sound program, 512 KB    audiocpu
#   0x2540000  SCSP samples, 8 MB             samples
#   0x2D40000  i960 program 512 KB-2 MB       maincpu 0x080000
#   0x2EC0000  TGP copro data, 4 MB           copro_data
#   0x32C0000  texture-coordinate ROM, 16 MB  textures (a smaller region
#                                             repeated, as MAME's mask mirrors it)
#   0x42C0000  polygons, to the last chip     polygons
#
# Each stretch MAME's region does not load is written as its fill (0, or 0xFF
# in a ROMREGION_ERASEFF region). Text only: names, CRCs and offsets from
# model2.cpp -- no ROM bytes. tools/mra_vs_mame.py --layout=2a checks the
# image the result describes against MAME's regions.
#
#   tools/mra_2a_big.py <model2.cpp> <set>      (prints the parts, indented)

import re, sys

def rom_start(src, name):
    m = re.search(r"ROM_START\(\s*%s\s*\)(.*?)ROM_END" % re.escape(name), src, re.S)
    if not m:
        raise SystemExit(f"no ROM_START({name})")
    body = m.group(1)
    if "MODEL2_CPU_BOARD" in body:
        mb = re.search(r"#define MODEL2_CPU_BOARD(.*?)\n/\*", src, re.S)
        body = body.replace("MODEL2_CPU_BOARD", mb.group(1).replace("\\\n", "\n"))
    return body

def parse(body):
    """regions: tag -> dict(size, fill, segs=[(start, end, kind, chips)], copies)"""
    regs, cur = {}, None
    for line in body.splitlines():
        line = line.split("//")[0]
        m = re.search(r"ROM_REGION(?:\d\d_[LB]E)?\(\s*(0x[0-9a-fA-F]+)\s*,\s*\"([^\"]+)\"\s*,\s*([^)]*)\)", line)
        if m:
            cur = m.group(2)
            regs[cur] = dict(size=int(m.group(1), 16), fill=0xFF if "ERASEFF" in m.group(3) else 0x00,
                             w32={}, w16=[], copies=[])
            continue
        m = re.search(r"(ROM_LOAD32_WORD|ROM_LOAD16_WORD_SWAP)\(\s*\"([^\"]+)\"\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*CRC\(([0-9a-fA-F]+)\)", line)
        if m:
            kind, nm, off, ln, crc = m.group(1), m.group(2), int(m.group(3), 16), int(m.group(4), 16), m.group(5).lower()
            r = regs[cur]
            if kind == "ROM_LOAD32_WORD":
                base = off & ~3
                r["w32"].setdefault(base, [None, None, ln])[(off >> 1) & 1] = (nm, crc)
            else:
                r["w16"].append((off, nm, crc, ln))
            continue
        m = re.search(r"ROM_COPY\(\s*\"([^\"]+)\"\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*\)", line)
        if m:
            regs[m.group(1)]["copies"].append(tuple(int(m.group(i), 16) for i in (2, 3, 4)))
    return regs

def segments(r):
    """[(start, end, emit(a, b) -> lines)] for region r's loaded spans, copies resolved"""
    segs = []
    for base, (lo, hi, ln) in r["w32"].items():
        def em(a, b, base=base, lo=lo, hi=hi, ln=ln):
            o, n = (a - base) // 2, (b - a) // 2
            att = "" if (o == 0 and n == ln) else f' offset="0x{o:06X}" length="0x{n:06X}"'
            out = ['<interleave output="32">']
            for chip, mp in ((lo, "0021"), (hi, "2100")):
                out.append(f'    <part name="{chip[0]}" crc="{chip[1]}" map="{mp}"{att}/>')
            return out + ["</interleave>"]
        segs.append((base, base + 2 * ln, em))
    for off, nm, crc, ln in r["w16"]:
        def em(a, b, off=off, nm=nm, crc=crc, ln=ln):
            o, n = a - off, b - a
            att = "" if (o == 0 and n == ln) else f' offset="0x{o:06X}" length="0x{n:06X}"'
            return ['<interleave output="16">', f'    <part name="{nm}" crc="{crc}" map="12"{att}/>', "</interleave>"]
        segs.append((off, off + ln, em))
    for src, dst, ln in r["copies"]:
        def em(a, b, src=src, dst=dst, ln=ln, base_segs=list(segs)):
            return emit_range(base_segs, a - dst + src, b - dst + src, None)
        segs.append((dst, dst + ln, em))
    # a later segment (a copy) wins over an earlier one at the same place
    return segs

def emit_range(segs, a, b, fill):
    out = []
    p = a
    while p < b:
        cover = [s for s in segs if s[0] <= p < s[1]]
        if cover:
            s = cover[-1]
            e = min(b, s[1])
            nxt = [t[0] for t in segs if p < t[0] < e and t is not s]
            e = min([e] + nxt)
            out += s[2](p, e)
            p = e
        else:
            nxt = [t[0] for t in segs if t[0] > p]
            e = min([b] + nxt)
            if fill is None:
                raise SystemExit("a copy reads unloaded space")
            out.append(f'<part repeat="{e - p}">{fill:02X}</part>')
            p = e
    return out

def block(title, lines, ind="        "):
    return [ind + "<!-- " + title.replace("\n", "\n" + ind) + " -->"] + [ind + l for l in lines] + [""]

def main():
    src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    regs = parse(rom_start(src, sys.argv[2]))
    def rng(tag, a, b):
        r = regs.get(tag)
        if not r:
            return [f'<part repeat="{b - a}">00</part>']
        return emit_range(segments(r), a, b, r["fill"])
    out = []
    out += block("0x0000000  i960 program 0-512 KB", rng("maincpu", 0, 0x80000))
    out += block("0x0080000  i960 data, 32 MB (MAME's 0x02000000 window, mirrors written out)",
                 rng("main_data", 0, 0x2000000))
    out += block("0x2080000  4 MB of zeros, to the fixed slots", ['<part repeat="4194304">00</part>'])
    out += block("0x2480000  TGP math tables, 256 KB", rng("copro_tgp_tables", 0, 0x40000))
    out += block("0x24C0000  68000 sound program, 512 KB (16-bit, byte-swapped)", rng("audiocpu", 0, 0x80000))
    out += block("0x2540000  SCSP samples, 8 MB (16-bit, byte-swapped); moved by the\n"
                 "             loader to SDRAM byte 0x3400000", rng("samples", 0, 0x800000))
    out += block("0x2D40000  i960 program 512 KB-2 MB (R862)", rng("maincpu", 0x80000, 0x200000))
    out += block("0x2EC0000  TGP copro data, 4 MB (R862)", rng("copro_data", 0, 0x400000))
    t = regs["textures"]
    tex = []
    for k in range(0x1000000 // t["size"]):
        tex += rng("textures", 0, t["size"])
    out += block("0x32C0000  texture-coordinate ROM, 16 MB (R897; the loader's third\n"
                 "             remap puts it at SDRAM byte 0x4000000)", tex)
    p = regs["polygons"]
    last = max(e for s, e, _ in segments(p))
    out += block(f"0x42C0000  polygons, {last >> 20} MB (R897; SDRAM byte 0x5000000)", rng("polygons", 0, last))
    print("\n".join(out).rstrip())
    print(f"<!-- image 0x{0x42C0000 + last:07X} bytes -->", file=sys.stderr)

if __name__ == "__main__":
    main()
