#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# Disassemble a Model 2A sound program (68000, mapped at 0x600000) around
# given addresses, for reading the SCSP driver (study R856). Needs capstone.
#
#   snd_dasm.py <zip> <rom file in zip> <addr> [<addr> ...]   (hex addresses)
#   snd_dasm.py <zip> <rom> --range <start> <end>
#   snd_dasm.py <zip> <rom> --dump <start> <len>               (hex words)
# The ROM is ROM_LOAD16_WORD_SWAP in MAME: the file's bytes are swapped per word.
import sys, zipfile, capstone

def load(zp, name):
    d = bytearray(zipfile.ZipFile(zp).read(name))
    for i in range(0, len(d) - 1, 2):
        d[i], d[i + 1] = d[i + 1], d[i]
    return bytes(d)

def dis(rom, start, end):
    md = capstone.Cs(capstone.CS_ARCH_M68K, capstone.CS_MODE_M68K_000)
    md.skipdata = True
    off = start - 0x600000
    for ins in md.disasm(rom[off:end - 0x600000], start):
        print("%06x: %-24s %s %s" % (ins.address, ins.bytes.hex(), ins.mnemonic, ins.op_str))

zp, name = sys.argv[1], sys.argv[2]
rom = load(zp, name)
if sys.argv[3] == '--range':
    dis(rom, int(sys.argv[4], 16), int(sys.argv[5], 16))
elif sys.argv[3] == '--dump':
    a, n = int(sys.argv[4], 16), int(sys.argv[5], 16)
    for i in range(a, a + n, 16):
        o = i - 0x600000
        print("%06x: %s" % (i, ' '.join(rom[o + j:o + j + 2].hex() for j in range(0, 16, 2))))
else:
    for a in sys.argv[3:]:
        x = int(a, 16)
        print("---- around %06x" % x)
        dis(rom, x - 0x60, x + 0x20)
