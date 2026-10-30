#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# Study R976.
# Usage: snd_hit_cmp.py <ours cls.bin> <MAME cls.bin> <ours events> <MAME events> <ours t0> <MAME t0> <seconds> [classes]
#   cls.bin: scsp_split SPLIT_BYSA=1 SPLIT_CLS output; events: snd_keyon_ev.py lines (MAME: from keyon.txt)
# per hat hit: ours against MAME, from the class-split audio (8 x int32 / sample) and key-on lists.
# Aligns the two timelines on the first key-on of the passage, then for each resident key-on:
# audible onset (first |x| > 10% of the hit's peak, within 0..150 ms) in each, and the lag that best
# correlates the 150 ms after MAME's key-on with ours.
import sys, numpy as np
oc, mc, oev, mev, t0o, t0m, dur = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], float(sys.argv[5]), float(sys.argv[6]), float(sys.argv[7])
k = 1
def load(f):
    c = np.fromfile(f, dtype=np.int32).reshape(-1, 8); return c[:, k].astype(float), c[:, 4 + k].astype(float)
ol, orr = load(oc); ml, mr = load(mc)
def ev(f, t0):
    return [(float(l.split()[0]), l.split()[1]) for l in open(f) if t0 <= float(l.split()[0]) < t0 + dur]
eo = ev(oev, t0o); em = ev(mev, t0m)
want = sys.argv[8].split(',') if len(sys.argv) > 8 else None
sel = lambda e: e[1] in want if want else e[1].startswith('res')
ho = [e for e in eo if sel(e)]; hm = [e for e in em if sel(e)]
base_o, base_m = eo[0][0], em[0][0]
print('first key-on: ours %.4f MAME %.4f; hits ours %d MAME %d' % (base_o, base_m, len(ho), len(hm)))
W = int(0.15 * 44100)
res = []
for (to, co), (tm, cm) in zip(ho, hm):
    no, nm = int(round(to * 44100)), int(round(tm * 44100))
    so = np.abs(ol[no:no + W]) + np.abs(orr[no:no + W]); sm = np.abs(ml[nm:nm + W]) + np.abs(mr[nm:nm + W])
    ono = np.argmax(so > 0.1 * so.max()) if so.max() > 0 else -1
    onm = np.argmax(sm > 0.1 * sm.max()) if sm.max() > 0 else -1
    # absolute audible onset times, each on its own timeline relative to the passage start
    ao = (no + ono) / 44100 - base_o; am = (nm + onm) / 44100 - base_m
    # waveform: best lag of ours against MAME around the key-on
    a = ml[nm:nm + W]; best = (None, 0)
    for lag in range(-441, 442):
        b = ol[no + lag:no + lag + W]
        if len(b) < W: continue
        e = np.sum((a - b) ** 2)
        if best[0] is None or e < best[0]: best = (e, lag)
    rel = np.sqrt(best[0] / max(1.0, np.sum(a ** 2)))
    res.append((ao - am) * 1e3)
    print('MAME %.4f %-9s ours %-9s  onset after key-on ms: ours %5.2f MAME %5.2f | audible onset ours-MAME %+6.2f ms | wave lag %+4d smp resid %.3f peak %d/%d'
          % (tm, cm, co, ono / 44.1, onm / 44.1, (ao - am) * 1e3, best[1], rel, so.max(), sm.max()))
r = np.array(res)
print('audible onset ours-MAME ms: median %.2f min %.2f max %.2f' % (np.median(r), r.min(), r.max()))
