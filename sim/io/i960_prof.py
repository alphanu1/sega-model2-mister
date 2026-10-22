#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R927: THE i960'S CYCLES IN A WINDOW, BY CAUSE, from tb_m2_boot's
# M2_FRAMESTAT file with M2_WORK_IPS=<start>,<end> (Sega Rally: 5a0490,5bade8,
# the vblank interrupt to the timer read the game sets its detail budget
# from). Each window is a 'W' line (cycles, instructions, the sequencer's
# states) and a 'P' line (bus cycles and transactions by master and region,
# calls / returns / spills / fills, the frame cache modelled at other depths,
# the i-cache's requests and fills by region, instructions by region).
#
#   i960_prof.py <fs.txt> [from_vblank [to_vblank]]
import sys
from collections import Counter

TS = ['FETCH', 'FETCH_W', 'FETCH2', 'FETCH2_W', 'DECODE', 'EXEC', 'MEM', 'MEM_W',
      'MULDIV', 'MULTI', 'PAIR', 'FP', 'WB', 'FRAME', 'TRAP', 'BOOT', 'SYNMOV_RD',
      'SYNMOV_WR', 'INTR', 'RET7', 'MODPC', 'SYNQ', 'RLLO']
MASTER = {'b': 'aux', 'f': 'frame', 'l': 'ld/st', 'i': 'ifetch'}
REGION = {'r': 'prog ROM', 'B': 'board RAM', 'w': 'work RAM', 'u': 'buffer RAM',
          'o': 'I/O', 'd': 'data ROM', 'x': 'other'}


def main():
    path = sys.argv[1]
    lo = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    hi = int(sys.argv[3]) if len(sys.argv) > 3 else 1 << 60
    n = cyc = ins = 0
    ts = [0] * 23
    bus_n, bus_c = Counter(), Counter()
    cnt = Counter()
    depth = [0] * 34
    mame, ring = Counter(), Counter()
    icr, icf, insr = Counter(), Counter(), Counter()
    l1 = Counter(); l1h, l1c = Counter(), Counter(); l1wh, l1wc = Counter(), Counter()
    icm = [0] * 7; dcm = [0, 0]
    per = []
    want = False
    for line in open(path):
        p = line.split()
        if not p:
            continue
        if p[0] == 'W':
            v = int(p[2])
            want = lo <= v <= hi
            if not want:
                continue
            n += 1
            c, i = int(p[4]), int(p[6])
            cyc += c; ins += i
            per.append((v, c, i))
            t = [int(x) for x in p[p.index('ts') + 1:]]
            for k in range(min(23, len(t))):
                ts[k] += t[k]
        elif p[0] == 'P' and want:
            k = 3
            while k < len(p):
                tag = p[k]
                if tag == 'bus':
                    bus_n[p[k + 1]] += int(p[k + 2]); bus_c[p[k + 1]] += int(p[k + 3]); k += 4
                elif tag in ('calls', 'rets', 'flush', 'spill', 'fill'):
                    cnt[tag] += int(p[k + 1]); k += 2
                elif tag == 'depth':
                    for j in range(34):
                        depth[j] += int(p[k + 1 + j])
                    k += 35
                elif tag in ('mame', 'ring'):
                    j = k + 1
                    while j < len(p) and ':' in p[j]:
                        a, b = p[j].split(':')
                        (mame if tag == 'mame' else ring)[int(a)] += int(b)
                        j += 1
                    k = j
                elif tag == 'ic':
                    icr[p[k + 1]] += int(p[k + 2]); icf[p[k + 1]] += int(p[k + 3]); k += 4
                elif tag == 'ins':
                    insr[p[k + 1]] += int(p[k + 2]); k += 3
                elif tag == 'l1':
                    l1['rd'] += int(p[k + 1]); l1['rdcyc'] += int(p[k + 2]); l1['wr'] += int(p[k + 3])
                    j = k + 4
                    while j < len(p) and p[j].count(':') == 2:
                        a, b, c = p[j].split(':')
                        l1h[int(a)] += int(b); l1c[int(a)] += int(c)
                        j += 1
                    k = j
                elif tag == 'icm':
                    for j in range(7):
                        icm[j] += int(p[k + 1 + j])
                    k += 8
                elif tag == 'dcm':
                    dcm[0] += int(p[k + 1]); dcm[1] += int(p[k + 2]); k += 3
                elif tag == 'l1w':
                    j = k + 1
                    while j < len(p) and p[j].count(':') == 2:
                        a, b, c = p[j].split(':')
                        l1wh[int(a)] += int(b); l1wc[int(a)] += int(c)
                        j += 1
                    k = j
                else:
                    k += 1
    if not n:
        print('no windows'); return
    print('windows %d (vblanks %d-%d): %d cycles, %d instructions, CPI %.2f; a window %.0f cycles, %.0f instructions'
          % (n, per[0][0], per[-1][0], cyc, ins, cyc / ins, cyc / n, ins / n))
    pc = sorted(c for v, c, i in per)
    print('  window cycles: min %d p10 %d p50 %d p90 %d max %d' % (pc[0], pc[len(pc) // 10], pc[len(pc) // 2],
                                                                   pc[len(pc) * 9 // 10], pc[-1]))
    print('sequencer states (cycles an instruction, share):')
    for k in sorted(range(23), key=lambda k: -ts[k]):
        if ts[k]:
            print('  %-10s %10d  %5.2f  %5.1f%%' % (TS[k], ts[k], ts[k] / ins, 100.0 * ts[k] / cyc))
    print('bus, by master / region / direction: transactions, cycles, cycles each, share of window cycles:')
    for key in sorted(bus_c, key=lambda x: -bus_c[x]):
        m, r, d = key[0], key[1], key[2]
        nn, cc = bus_n[key], bus_c[key]
        print('  %-6s %-10s %s  %8d %9d  %6.2f  %5.1f%%' % (MASTER.get(m, m), REGION.get(r, r), 'write' if d == 'w' else 'read ',
                                                       nn, cc, cc / max(nn, 1), 100.0 * cc / cyc))
    tot = sum(bus_c.values())
    print('  bus busy %d cycles (%.1f%% of the window)' % (tot, 100.0 * tot / cyc))
    print('frames: calls %d rets %d flushreg %d; to memory (MAME rule, depth >= 4): %d spills, %d fills'
          % (cnt['calls'], cnt['rets'], cnt['flush'], cnt['spill'], cnt['fill']))
    print('  calls per window %.1f, frame transfers per window %.1f' % (cnt['calls'] / n, (cnt['spill'] + cnt['fill']) / n))
    tc = sum(depth)
    if tc:
        print('  depth at call: ' + ' '.join('%d:%.1f%%' % (j, 100.0 * depth[j] / tc) for j in range(34) if depth[j]))
    print('  frame transfers (spill + fill) by model and saved frames N:')
    print('    N      MAME rule   the chip\'s ring')
    for k in sorted(set(mame) | set(ring)):
        print('    %-4d %10d %12d' % (k, mame[k], ring[k]))
    print('i-cache: requests and line fills by region (fills / requests):')
    for r in sorted(icr, key=lambda x: -icr[x]):
        print('  %-10s %9d %7d  %.2f%%' % (REGION.get(r, r), icr[r], icf[r], 100.0 * icf[r] / max(icr[r], 1)))
    if l1['rd']:
        print('a CPU-side data cache over board / work RAM (model): %d reads (%.1f cycles each now), %d writes'
              % (l1['rd'], l1['rdcyc'] / l1['rd'], l1['wr']))
        for k in sorted(l1h):
            print('  %d KB: %5.1f%% hit; the hits take %.1f cycles each now -> %d cycles at 2 each, %.1f%% of the window'
                  % (k, 100.0 * l1h[k] / l1['rd'], l1c[k] / max(l1h[k], 1), l1c[k] - 2 * l1h[k],
                     100.0 * (l1c[k] - 2 * l1h[k]) / cyc))
        for k in sorted(l1wh):
            print('  %d KB, a word per miss: %5.1f%% hit -> %d cycles saved, %.1f%% of the window'
                  % (k, 100.0 * l1wh[k] / l1['rd'], l1wc[k] - 2 * l1wh[k], 100.0 * (l1wc[k] - 2 * l1wh[k]) / cyc))
    if icm[0]:
        print('i-cache models over the fetch requests (%d): misses' % icm[0])
        for j, nm in enumerate(['8 KB direct (as built)', '16 KB direct', '32 KB direct', '8 KB 2-way', '16 KB 2-way', '8 KB 4-way']):
            print('  %-24s %8d  %.2f%%' % (nm, icm[1 + j], 100.0 * icm[1 + j] / icm[0]))
    if l1['rd'] and (dcm[0] or dcm[1]):
        print('  data cache, line fills, 2-way: 4 KB %.1f%% hit, 8 KB %.1f%%' % (100.0 * dcm[0] / l1['rd'], 100.0 * dcm[1] / l1['rd']))
    print('instructions by region: ' + ', '.join('%s %d (%.1f%%)' % (REGION.get(r, r), insr[r], 100.0 * insr[r] / max(ins, 1))
                                                 for r in sorted(insr, key=lambda x: -insr[x])))


if __name__ == '__main__':
    main()
