#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# Study R976.
# Usage: snd_keyon_cmp.py <SND_DUMP file> [pairs out]; MAME_KEYON=<capture>/keyon.txt SHIFT= SHIFT_AFTER= as the run.
# key-on events from a tb_m2_2a_sound SND_DUMP (ours / mame streams):
# (time, slot, sa, pitch word, tl) per KYONEX write. Matches the two lists in
# order (LCS on (slot, sa, pitch)) and prints the time offsets per class.
import sys, collections
def parse(fn, who):
    regs = collections.defaultdict(lambda: [0]*16)
    ev = []
    for l in open(fn):
        p = l.split()
        if p[0] != who: continue
        t = float(p[1]); off = int(p[2], 16); d = int(p[3], 16); m = int(p[4], 16)
        if off >= 0x400: continue
        s, r = off >> 5, (off & 0x1f) >> 1
        regs[s][r] = (regs[s][r] & ~m) | (d & m)
        if r == 0 and (m & 0xff00) and (d & 0x1800) == 0x1800:
            # KYONEX: every slot with KYONB set keys on (the driver sets one at a time)
            w = regs[s]
            ev.append((t, s, ((w[0] & 0xf) << 16) | w[1], w[8], w[6] & 0xff, w[0]))
    return ev
fn = sys.argv[1]
a = parse(fn, 'ours')
import os
if os.environ.get('MAME_KEYON'):
    sh = float(os.environ.get('SHIFT', '0')); b = []
    for l in open(os.environ['MAME_KEYON']):
        p = l.split(); n = int(p[0]); w = [int(x, 16) for x in p[2:18]]
        t = n / 44100.0
        if t >= float(os.environ.get('SHIFT_AFTER', '0')): t -= sh
        b.append((t, int(p[1]), ((w[0] & 0xf) << 16) | w[1], w[8], w[6] & 0xff, w[0]))
    tend = max(e[0] for e in a) if a else 0
    b = [e for e in b if e[0] <= tend + 0.5]
else:
    b = parse(fn, 'mame')
print('key-ons ours %d mame %d' % (len(a), len(b)))
key = lambda e: (e[1], e[2], e[3])
# LCS (bounded)
na, nb = min(len(a), 3000), min(len(b), 3000)
L = [[0]*(nb+1) for _ in range(na+1)]
for i in range(1, na+1):
    for j in range(1, nb+1):
        L[i][j] = L[i-1][j-1]+1 if key(a[i-1]) == key(b[j-1]) else max(L[i-1][j], L[i][j-1])
pairs = []
i, j = na, nb
while i and j:
    if key(a[i-1]) == key(b[j-1]): pairs.append((a[i-1], b[j-1])); i -= 1; j -= 1
    elif L[i-1][j] >= L[i][j-1]: i -= 1
    else: j -= 1
pairs.reverse()
print('matched %d' % len(pairs))
def cls(e):
    if e[2] >= 0x50000: return 'resident sa=%05x' % e[2]
    return 'stream pitch=%04x' % e[3]
out = sys.argv[2] if len(sys.argv) > 2 else None
f = open(out, 'w') if out else None
by = collections.defaultdict(list)
for x, y in pairs:
    by[cls(y)].append((x[0] - y[0]) * 1e3)
    if f: f.write('%.6f %.6f %8.2f s%02d %s tl=%02x\n' % (y[0], x[0], (x[0]-y[0])*1e3, y[1], cls(y), y[4]))
for k, v in sorted(by.items(), key=lambda kv: -len(kv[1])):
    v.sort()
    print('%-26s n=%4d  ours-mame ms: min %7.2f med %7.2f max %7.2f' % (k, len(v), v[0], v[len(v)//2], v[-1]))
