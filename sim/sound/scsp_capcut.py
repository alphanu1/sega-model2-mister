#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# Study R976.
# Usage: scsp_capcut.py <capture> <out> <cut from s> <cut to s> <end s>
# a p16 capture with [A, B) seconds cut out and the rest moved up (for slow benches)
import sys, os, numpy as np
src, dst, A, B, END = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
a, b, e = int(A * 44100), int(B * 44100), int(END * 44100)
os.makedirs(dst, exist_ok=True)
def cut(arr):
    n = arr['n'] if arr.dtype.names else arr[:, 0]
    keep = (n < a) | ((n >= b) & (n < e))
    out = arr[keep].copy()
    if arr.dtype.names: out['n'][out['n'] >= b] -= (b - a)
    else: out[out[:, 0] >= b, 0] -= (b - a)
    return out
regs = np.fromfile(src + '/regs.bin', dtype=[('n', '<u4'), ('off', '<u2'), ('data', '<u2'), ('mask', '<u2'), ('pad', '<u2')])
cut(regs).tofile(dst + '/regs.bin')
ramw = np.fromfile(src + '/ramw.bin', dtype=np.uint32).reshape(-1, 3)
cut(ramw).tofile(dst + '/ramw.bin')
o = np.fromfile(src + '/out.bin', dtype=np.int32).reshape(-1, 2)
np.concatenate([o[:a], o[b:e]]).tofile(dst + '/out.bin')
with open(dst + '/midi.txt', 'w') as f:
    for l in open(src + '/midi.txt'):
        n = int(l.split()[0])
        if n < a: f.write(l)
        elif b <= n < e: f.write('%d %s' % (n - (b - a), l.split(None, 1)[1]))
with open(dst + '/keyon.txt', 'w') as f:
    for l in open(src + '/keyon.txt'):
        n = int(l.split()[0])
        if n < a: f.write(l)
        elif b <= n < e: f.write('%d %s' % (n - (b - a), l.split(None, 1)[1]))
print('cut', A, B, 'end', END)
