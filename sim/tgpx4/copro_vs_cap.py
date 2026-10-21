#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R924: THE WHOLE-CORE BENCH'S COPROCESSOR OUTPUT AGAINST MAME'S. Compares the
# words the i960 read from the output FIFO in tb_m2_boot (M2_COPRO_TRACE, its
# 'R' lines) with the words MAME's i960 read (a R924_CAP capture's 'X' events),
# in order, and the words it pushed (the trace's 'W' / 'F' lines) with MAME's
# ('I' / 'N'). The two runs drift in time, not in order: the stream is causal.
#   copro_vs_cap.py <copro.txt> <capdir>
import sys, numpy as np

tr = open(sys.argv[1]).read().split('\n')
rd = []; wr = []; ctl = 0
for l in tr:
    f = l.split()
    if len(f) < 4: continue
    if f[0] == 'C': ctl = int(f[3], 16)
    elif f[0] == 'R': rd.append(int(f[3], 16))
    elif f[0] == 'W' and not (ctl & 0x80000000): wr.append(int(f[3], 16))   # not the upload
    elif f[0] == 'F':
        a = int(f[2], 16); d = int(f[3], 16)
        wr.append((d & 0x800fffff) | (((a >> 4) & 0xff) << 23))
d = np.fromfile(sys.argv[2] + '/events.bin', dtype=np.uint8)
n = len(d) // 9; r = d[:n * 9].reshape(n, 9); t = r[:, 0]
b = r[:, 5:9].copy().view('<u4').ravel()
mx = b[t == ord('X')].tolist()
mw = b[(t == ord('I')) | (t == ord('N'))].tolist()
def cmp(name, ours, mame):
    k = min(len(ours), len(mame)); bad = [i for i in range(k) if ours[i] != mame[i]]
    print(f"{name}: core {len(ours)}, MAME {len(mame)}; first {k} compared, {len(bad)} differ"
          + (f" ({100.0 * (k - len(bad)) / k:.4f}% match)" if k else ""))
    for i in bad[:10]: print(f"   #{i}: core {ours[i]:08x} MAME {mame[i]:08x}")
cmp("i960 pushes (FIFO + function port)", wr, mw)
cmp("i960 reads of the output FIFO", rd, mx)
