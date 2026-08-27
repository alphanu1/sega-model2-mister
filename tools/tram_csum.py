#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# The expected value of overlay row 22: a fold of all 32,768 words of tile RAM,
# using the same add-and-rotate the core's region sweep uses, so the two numbers
# are directly comparable.
#
#   python3 tools/tram_csum.py <dir-with-tile.bin>
#
# WHAT A MISMATCH MEANS. The board's tile RAM is written by the live CPU and the
# reference is one captured frame, so they agree only when the screen is static
# and showing that same frame. A number that MOVES means the CPU is still
# redrawing; a number that is stable and wrong means writes are not arriving.
import sys, os

def fold(words):
    acc = 0
    for v in words:
        acc = (acc + v) & 0xffffff
        acc = ((acc << 1) | (acc >> 23)) & 0xffffff
    return acc

d = sys.argv[1] if len(sys.argv) > 1 else '.'
raw = open(os.path.join(d, 'tile.bin'), 'rb').read()
w = [raw[i] | (raw[i+1] << 8) for i in range(0, len(raw), 2)]
w += [0] * (32768 - len(w))
print(f"  tile.bin {len(raw)} bytes, {len(w)} words")
print(f"  row 22 should read {fold(w[:32768]):06X}")
