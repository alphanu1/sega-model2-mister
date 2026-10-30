#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# Study R976.
# Usage: snd_beat_rel.py <"t class" events> <t0> <t1>
# per beat cluster: drum key-on time minus the cluster's first melodic key-on (ms)
import sys, numpy as np
ev = [(float(l.split()[0]), l.split()[1]) for l in open(sys.argv[1])]
t0, t1 = float(sys.argv[2]), float(sys.argv[3])
ev = [e for e in ev if t0 <= e[0] < t1]
drum = lambda c: c.startswith('res') or c == 'str0000'
cl = []; cur = [ev[0]]
for e in ev[1:]:
    if e[0] - cur[0][0] < 0.05: cur.append(e)
    else: cl.append(cur); cur = [e]
cl.append(cur)
rel = []; spread = []; steps = []
for c in cl:
    mel = [e[0] for e in c if not drum(e[1])]; dr = [e[0] for e in c if drum(e[1])]
    spread.append((c[-1][0] - c[0][0]) * 1e3)
    if mel and dr: rel += [(d - mel[0]) * 1e3 for d in dr]
first = [c[0][0] for c in cl]
st = np.diff(first) * 1e3
rel = np.array(rel); spread = np.array(spread)
print('clusters %d; step ms median %.1f p10 %.1f p90 %.1f' % (len(cl), np.median(st), np.percentile(st, 10), np.percentile(st, 90)))
print('cluster spread ms: median %.1f p90 %.1f max %.1f' % (np.median(spread), np.percentile(spread, 90), spread.max()))
print('drum - first melodic ms (n=%d): median %.1f p10 %.1f p90 %.1f min %.1f max %.1f' % (len(rel), np.median(rel), np.percentile(rel, 10), np.percentile(rel, 90), rel.min(), rel.max()))
