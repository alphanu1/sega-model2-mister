# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1 (R817)
import sys, array
import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rom import word, ilen
ips = array.array('I'); ips.frombytes(open(sys.argv[1], 'rb').read())
frames = []; cur = []
for a in ips:
    if a == 0xffffffff: frames.append(cur); cur = []
    else: cur.append(a)
frames.append(cur)
spin = lambda a: a in (0x1394, 0x139c)   # Rev A frame-sync spin: ldob 0x500000 / cmpibe
tot = dict(n=0, busy=0, two=0, taken=0, taken_x=0, xline_seq=0, ctrl=0, mem=0, ret=0, call=0, bwd=0)
for fr in frames[1:-1] or frames:
    for i in range(len(fr) - 1):
        a, b = fr[i], fr[i+1]
        w = word(a); L = ilen(w); op = w >> 24
        tot['n'] += 1
        if spin(a): continue
        tot['busy'] += 1
        if L == 8: tot['two'] += 1
        if op >= 0x80: tot['mem'] += 1
        if 0x08 <= op < 0x40: tot['ctrl'] += 1
        if b != a + L:
            tot['taken'] += 1
            if b < a: tot['bwd'] += 1
            if ((a + 4) >> 4) != (a >> 4): tot['taken_x'] += 1   # fall-through word is in the next line
        elif ((a + L) >> 4) != (a >> 4): tot['xline_seq'] += 1
        if op == 0x0a: tot['ret'] += 1
        if op == 0x09: tot['call'] += 1
nf = max(1, len(frames) - 2)
b = tot['busy']
print("%s: %d frames, %.0f insn/frame, busy (outside the 0x1394 spin) %.0f/frame" % (sys.argv[1], nf, tot['n']/nf, b/nf))
for k in ('two', 'mem', 'ctrl', 'taken', 'bwd', 'taken_x', 'xline_seq', 'call', 'ret'):
    print("   %-10s %6.1f%% of busy" % (k, 100.0 * tot[k] / b))
