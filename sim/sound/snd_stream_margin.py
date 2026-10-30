#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# Study R976.
# Usage: snd_stream_margin.py <p16 capture dir> <t0 s> <t1 s> [v]
# MAME: for each streamed key-on, how far ahead of the play position each 512-byte chunk of the
# first two laps was written (samples; negative = written after the slot played it)
import sys, numpy as np
d, t0, t1 = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
ko = []
for l in open(d + '/keyon.txt'):
    p = l.split(); w = [int(x, 16) for x in p[2:18]]; n = int(p[0])
    if t0 * 44100 <= n < t1 * 44100: ko.append((n, int(p[1]), ((w[0] & 0xf) << 16) | w[1], w[8]))
a = np.fromfile(d + '/ramw.bin', dtype=np.uint32).reshape(-1, 3); T = a[:, 0]
allm = []
for n, s, sa, pitch in ko:
    if sa >= 0x50000: continue
    oct_ = (pitch >> 11) & 0xf; oct_ = oct_ - 16 if oct_ & 8 else oct_
    rate = 2.0 ** oct_ * (1 + (pitch & 0x3ff) / 1024)
    b = a[np.searchsorted(T, n - 600):np.searchsorted(T, n + int(32 * 512 / rate) + 2000)]
    b = b[(b[:, 1] >= sa) & (b[:, 1] < sa + 0x2000)]
    marg = []
    for c in range(1, 32):     # chunk c of the stream (lap c // 16)
        need = n + c * 512 / rate
        lo = need - 16 * 512 / rate   # written after the previous lap's play of that spot
        off = sa + (c % 16) * 512
        m = b[(b[:, 1] >= off) & (b[:, 1] < off + 512) & (b[:, 0] > lo)]
        if len(m) == 0: break
        marg.append(int(need - m[:, 0].min()))
    if marg: allm.append(min(marg))
    if len(sys.argv) > 4: print('%.3f s%2d %04x min %d %s' % (n / 44100, s, pitch, min(marg) if marg else 0, marg[:10]))
allm = np.array(allm)
print('voices %d; min margin over the first two laps, samples: p0 %d p10 %d p50 %d; voices < 0: %d, < 256: %d' % (len(allm), allm.min(), np.percentile(allm, 10), np.median(allm), (allm < 0).sum(), (allm < 256).sum()))
