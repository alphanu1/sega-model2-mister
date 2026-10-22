#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R926: SEGA RALLY'S AI CARS, FROM A CAR LOG (sim/io/mame_m2_rally_ap.lua's
# APLOG, or tb_m2_boot's M2_CARLOG -- the same format), AND THE GAME'S OWN
# DETAIL BUDGET, FROM ITS WRITES TO 0x0020aac0.
#
#   rally_ai_check.py glitch <log>          position steps the velocity does
#                                           not explain (TH=<units>, default 2)
#   rally_ai_check.py align <ref> <log>     each slot's states in <log> that are
#                                           in <ref>'s sequence, bit for bit
#   rally_ai_check.py modes <log>           each slot's flag changes (+0x10
#                                           bits 31:16: 0000 on the course line,
#                                           2222 / 3333 ... the full physics)
#   rally_ai_check.py budget <taplog> [from_frame]
#       the frame's measure (timer 2's count at 0x5bade8 + 90,000, less
#       400,000 if a vblank came first) and the budget row it picks,
#       (m // 10000 - 21) >> 1 clamped 0..8 -- row 8 allows 3 / 2 / 2 cars the
#       three nearest details, row 0 none. <taplog>: a MAME write-tap log
#       ("<frame> <t> W 0020aac0 <data> ip <ip>") or tb_m2_boot's M2_BUSLOG
#       with M2_BUSLOG_LO/HI=20aac0/20aac3 ("<insn> W 0020aac0 <data> be f ip
#       <ip> f<frame>").
import math, os, struct, sys
from collections import Counter


def f32(h):
    return struct.unpack('<f', struct.pack('<I', int(h, 16)))[0]


def records(path):
    fr = 0
    for line in open(path):
        p = line.split()
        if not p:
            continue
        if p[0] == 'T':
            fr = int(p[2])
        elif p[0] == 'A':
            yield fr, int(p[1]), p


def glitch(path):
    th = float(os.getenv('TH', '2.0'))
    prev = {}; n = bad = 0
    for fr, k, p in records(path):
        v = [f32(x) for x in p[3:12]]
        pos, vel = v[0:3], v[3:6]
        if k in prev and tuple(p[3:6]) == prev[k][3]:
            continue                                   # not updated this frame
        if k in prev and fr - prev[k][0] <= 4:
            pp, pv = prev[k][1], prev[k][2]
            d = [pos[i] - pp[i] for i in range(3)]
            e = min(math.sqrt(sum((d[i] - vel[i]) ** 2 for i in range(3))),
                    math.sqrt(sum((d[i] - pv[i]) ** 2 for i in range(3))))
            n += 1
            if not (e < th) or any(x != x for x in pos + vel):
                bad += 1
                if bad <= 40:
                    print('fr %d car %d seg %s pos %s prev %s err %.3f' % (fr, k, p[2],
                          ' '.join('%.2f' % x for x in pos), ' '.join('%.2f' % x for x in pp), e))
        prev[k] = (fr, pos, vel, tuple(p[3:6]))
    print('steps %d, over %.2f: %d' % (n, th, bad))


def seqs(path):
    out = {}
    for fr, k, p in records(path):
        st = tuple(p[3:6]); s = out.setdefault(k, [])
        if not s or s[-1][1] != st:
            s.append((fr, st))
    return out


def align(ref, path):
    A, B = seqs(ref), seqs(path)
    for k in sorted(set(A) & set(B)):
        ia = {st: i for i, (fr, st) in enumerate(A[k])}
        xz = {(st[0], st[2]) for fr, st in A[k]}
        ok = part = 0; bad = None; last = -1
        for fr, st in B[k]:
            if st in ia:
                ok += 1; last = ia[st]
            elif (st[0], st[2]) in xz:
                part += 1                               # sampled mid-update
            else:
                bad = (fr, st); break
        msg = 'slot %d: %d states, %d in the reference, %d part-updated' % (k, len(B[k]), ok, part)
        if bad:
            msg += '; first not in it at frame %d (%s), after reference state #%d (frame %d)' % (
                bad[0], ' '.join('%.4f' % f32(x) for x in bad[1]), last, A[k][last][0] if last >= 0 else -1)
        print(msg)


def modes(path):
    pm = {}; n = Counter()
    for fr, k, p in records(path):
        m = p[12][:4]
        if k in pm and pm[k] != m:
            n[k] += 1
            if n[k] <= 12:
                print('frame %d slot %d %s -> %s' % (fr, k, pm[k], m))
        pm[k] = m
    print('changes per slot:', dict(sorted(n.items())))


def budget(path, lo):
    last = {}; order = []
    for line in open(path):
        p = line.split()
        if len(p) < 7 or p[2] != '0020aac0' or p[1] != 'W':
            if len(p) >= 7 and p[2] == 'W' and p[3] == '0020aac0':   # MAME tap
                fr, v, ip = int(p[0]), int(p[4], 16), p[6]
            else:
                continue
        else:                                                       # tb BUSLOG
            fr, v, ip = int(p[8][1:]), int(p[3], 16), p[7]
        if v & 0x80000000:
            v -= 1 << 32
        if fr < lo:
            continue
        if ip in ('005bae00', '005bae08'):
            last[fr] = ('measured', v); order.append(fr)
        elif ip in ('005bae30', '005bae38'):
            last[fr] = ('late', v)
    rows = Counter(); kinds = Counter(); vals = []
    for fr in order:
        kind, v = last[fr]; kinds[kind] += 1
        q = v // 10000 - 21
        rows[0 if q < 0 else min(8, q >> 1)] += 1
        if kind == 'measured':
            vals.append(v)
    if not order:
        print('no budget writes'); return
    s = sorted(vals)
    print('frames %d (%s); measure min %d p10 %d p50 %d max %d' % (len(order), dict(kinds),
          s[0], s[len(s) // 10], s[len(s) // 2], s[-1]))
    print('budget row:', sorted(rows.items()))


if __name__ == '__main__':
    a = sys.argv[1:]
    if a and a[0] == 'glitch':
        glitch(a[1])
    elif a and a[0] == 'align':
        align(a[1], a[2])
    elif a and a[0] == 'modes':
        modes(a[1])
    elif a and a[0] == 'budget':
        budget(a[1], int(a[2]) if len(a) > 2 else 0)
    else:
        sys.exit(__doc__ if __doc__ else 'usage: see the header')
