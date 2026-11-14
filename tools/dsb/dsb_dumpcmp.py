#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R1007: compare two tb_dsb_board dumps (DSB_DUMP=<file>) of the same run.
#
#   python3 tools/dsb/dsb_dumpcmp.py <a.txt> <b.txt>
#
# Reports, separately:
#   outputs  every 32 kHz tick (source, L, R) -- equal tick for tick means the
#            speaker hears the same thing at the same time;
#   samples  the decoded stream's VALUES in order -- equal means the same
#            samples, whatever the decode's timing;
#   clocks   whether each decoded sample also came on the same clock.
# Where outputs differ, it says whether b is a's output shifted by whole ticks
# at the points where play starts (a decode that starts later or earlier),
# with the shifts listed.
import sys

def load(p):
    o, s, c = [], [], []
    for l in open(p):
        f = l.split()
        if f[0] == 'O': o.append((int(f[2]), int(f[3], 16), int(f[4], 16)))
        elif f[0] == 'S': s.append(int(f[2], 16)); c.append(int(f[1]))
    return o, s, c

oa, sa, ca = load(sys.argv[1]); ob, sb, cb = load(sys.argv[2])
n = min(len(oa), len(ob))
od = [i for i in range(n) if oa[i] != ob[i]]
ns = min(len(sa), len(sb))
sd = [i for i in range(ns) if sa[i] != sb[i]]
cd = sum(1 for i in range(ns) if ca[i] != cb[i])
print(f'outputs: {len(oa)} / {len(ob)} ticks, {len(od)} differ' + (f' (first at tick {od[0]})' if od else ''))
print(f'samples: {len(sa)} / {len(sb)} decoded, values {len(sd)} differ' + (f' (first at {sd[0]})' if sd else '') +
      f'; on a different clock: {cd}')
if od:
    # the sounding samples (source 1) in order, and where each run of them starts
    va = [(x[1], x[2]) for x in oa if x[0]]; vb = [(x[1], x[2]) for x in ob if x[0]]
    m = min(len(va), len(vb))
    vd = sum(1 for i in range(m) if va[i] != vb[i])
    print(f'  sounding ticks: {len(va)} / {len(vb)}; in order, {vd} of {m} differ')
    def starts(o):
        r = []
        for i in range(1, len(o)):
            if o[i][0] and not o[i - 1][0]: r.append(i)
        return r
    a0, b0 = starts(oa), starts(ob)
    sh = [b - a for a, b in zip(a0, b0)]
    print(f'  play starts: {len(a0)} / {len(b0)}; shifts (ticks, b - a): ' + ' '.join(str(x) for x in sh if x) +
          f'  [{sum(1 for x in sh if x)} of {len(sh)} moved]')
sys.exit(1 if (od or sd) else 0)
