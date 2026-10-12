# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1 (R817)
import os
def load_rom():
    d = os.path.expanduser(os.environ.get('M2_ROMPATH', '~/roms/Model2')) + '/daytona/'
    lo = open(d + 'epr-16722a.12', 'rb').read(); hi = open(d + 'epr-16723a.13', 'rb').read()
    n = len(lo) // 2
    w = [ (lo[2*i] | lo[2*i+1] << 8) | ((hi[2*i] | hi[2*i+1] << 8) << 16) for i in range(n)]
    return w
ROM = load_rom()
def word(a):
    if a >= 0x220000 and a < 0x240000: a -= 0x200000
    i = a >> 2
    return ROM[i] if 0 <= i < len(ROM) else 0
def ilen(w):
    op = w >> 24
    if op >= 0x80 and (w >> 12) & 1:
        mode = (w >> 10) & 0xF
        if mode in (5, 12, 13, 14, 15): return 8
    return 4
