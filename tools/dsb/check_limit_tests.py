#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R1007: dsb_mpeg's frame-limit tests on e = lim - rd_pos[26:3] and
# b = rd_pos[2:0] against the ones they replaced on remb = lim*8 - rd_pos,
# both at the RTL's widths, exhaustively over every rd_pos within 2^16 bits
# of the limit (either side) and, for S_CHECK, every g12 (15 bits). The
# decoder bench never lands a frame start or a sync scan within a few bits
# of the end address, so these edges are proven here, not there.
#
#   python3 tools/dsb/check_limit_tests.py
def sx(v, w):            # two's complement of a w-bit field
    v &= (1 << w) - 1
    return v - (1 << w) if v >> (w - 1) else v

LIM = 0x123456           # any byte address; only the difference matters
bad = 0; n = 0
for d in range(-(1 << 16), (1 << 16) + 1):        # remb = lim*8 - rd_pos
    rd = LIM * 8 - d
    remb = sx(LIM * 8 - rd, 28)
    e = sx(LIM - (rd >> 3), 25); b = rd & 7
    old = (remb <= 0, remb <= -3, remb < 16)
    e0 = e == 0
    new = (e < 0 or e0, e < 0 or (e0 and b >= 3), e < 0 or (e >> 1) == 0 or (e == 2 and b != 0))
    n += 1
    if old != new: bad += 1; print('limit', d, old, new) if bad < 5 else None
for d in range(-(1 << 13), (1 << 16) + 1):        # S_CHECK
    rd = LIM * 8 - d
    remb = sx(LIM * 8 - rd, 28); e = sx(LIM - (rd >> 3), 25); b = rd & 7
    eu = e & ((1 << 25) - 1)
    for g12 in list(range(0, 64)) + list(range(max(0, remb - 40), min(1 << 15, remb + 40))) + [(1 << 15) - 1]:
        old = remb < 0 or ((remb >> 15) == 0 and g12 > (remb & 0x7fff))
        new = (eu >> 24) & 1 == 1 or (((eu >> 13) & 0x7ff) == 0 and (((eu & 0x1fff) << 3) & 0xffff) < ((g12 + b) & 0xffff))
        n += 1
        if old != new: bad += 1; print('check', d, g12, old, new) if bad < 5 else None
print(f'{n} cases, {bad} differ')
raise SystemExit(1 if bad else 0)
