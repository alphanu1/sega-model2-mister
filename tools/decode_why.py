#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# Decode the "why" telemetry (R814; R854 for the M2_WHY build of model2a):
#   decode_why.py <uart capture> [clk_sys MHz, default 80]
#
#   V {held, no flip + walk busy} | {no flip + walk idle, vblanks}  running totals
#   D {last draw} | {longest draw since the last D}                  clk_sys cycles
#   W {last walk} | {longest walk since the last W}                  clk_sys cycles
#   Y {last frame's work} | {longest since the last Y}               clk_sys cycles
#       (vblank edge to the game's frame-sync loop; > 1 vblank = the CPU overran)
#   I {i960 fetch-wait cycles} | {T_MEM_W cycles}                    clk_i960, running
#   K {TGP holding the CPU} | {geometry push queue holding it}       clk_sys, running
#   P {instructions retired} | {data-cache hits}                     running
#   G {flips, vblanks} | {TGP retires, tile overruns}                every vblank
import sys

mhz = float(sys.argv[2]) if len(sys.argv) > 2 else 80.0
VBL = mhz * 1e6 / 57.52                      # clk_sys cycles a vblank
recs = []
for l in open(sys.argv[1], errors='ignore'):
    p = l.split()
    if len(p) != 3 or len(p[0]) != 1 or len(p[1]) != 8 or len(p[2]) != 8: continue
    try: recs.append((p[0], int(p[1], 16), int(p[2], 16)))
    except ValueError: pass
med = lambda x: sorted(x)[len(x) // 2]
pct = lambda x, q: sorted(x)[min(len(x) - 1, int(len(x) * q))]

V = [(a >> 16, a & 0xffff, d >> 16, d & 0xffff) for t, a, d in recs if t == 'V']
if len(V) >= 2:
    f, l = V[0], V[-1]
    hold, walk, game, vbl = [(l[i] - f[i]) & 0xffff for i in range(4)]
    print("vblanks %d" % vbl)
    if vbl:
        moved = vbl - hold - walk - game
        print("  new picture possible (game flipped, not held): %6d  %5.1f%%" % (moved, 100 * moved / vbl))
        print("  DRAW behind (game held for the 3D):            %6d  %5.1f%%" % (hold, 100 * hold / vbl))
        print("  WALK behind (no flip, geometry walk busy):     %6d  %5.1f%%" % (walk, 100 * walk / vbl))
        print("  GAME behind (no flip, walk idle: CPU/TGP):     %6d  %5.1f%%" % (game, 100 * game / vbl))

for tag, name in (('D', 'draw'), ('W', 'walk'), ('Y', 'frame work (vblank to sync)')):
    R = [(a & 0xffffff, d & 0xffffff) for t, a, d in recs if t == tag]
    R = [r for r in R if r[0] or r[1]]
    if not R: continue
    la = [r[0] for r in R]; mx = [r[1] for r in R]
    ms = lambda c: c / (mhz * 1000)
    print("%-28s ms: last median %.1f p90 %.1f max %.1f | per-record max median %.1f p90 %.1f | over one vblank: %d of %d (%.1f%%)" % (
        name, ms(med(la)), ms(pct(la, .9)), ms(max(la)), ms(med(mx)), ms(pct(mx, .9)),
        sum(1 for x in mx if x > VBL), len(mx), 100 * sum(1 for x in mx if x > VBL) / len(mx)))

G = [(a >> 16, a & 0xffff, d >> 16) for t, a, d in recs if t == 'G']
if len(G) >= 2:
    fl = (G[-1][0] - G[0][0]) & 0xffff; vb = (G[-1][1] - G[0][1]) & 0xffff
    if vb: print("flips/vblank %.3f (%.1f game fps at 57.52)" % (fl / vb, 57.52 * fl / vb))
    tr = [g[2] for g in G[1:]]
    print("TGP instructions a vblank: median %d p90 %d max %d" % (med(tr), pct(tr, .9), max(tr)))

# rates over windows of >= 30 vblanks (R817: adjacent records undercount)
def series(tag):
    out = []; v0 = None
    for t, a, d in recs:
        if t == 'V':
            x = d & 0xffff; v0 = x if v0 is None else v0; vb = (x - v0) & 0xffff
            out.append(('V', vb, 0, 0))
        elif t == tag and v0 is not None: out.append((tag, out[-1][1] if out else 0, a, d))
    return [o for o in out if o[0] == tag]
def rates(s, f, win=30):
    r = []; j = 0
    for i in range(1, len(s)):
        dv = s[i][1] - s[j][1]
        if dv >= win: r.append(f(s[j], s[i]) / dv); j = i
    return r
d32 = lambda a, b: (b - a) & 0xffffffff
I = series('I'); K = series('K'); P = series('P')
if len(I) > 2 and len(K) > 2 and len(P) > 2:
    cpu_vbl = VBL / 2
    ifw = rates(I, lambda p, q: d32(p[2], q[2])); mw = rates(I, lambda p, q: d32(p[3], q[3]))
    cst = rates(K, lambda p, q: d32(p[2], q[2])); gst = rates(K, lambda p, q: d32(p[3], q[3]))
    ins = rates(P, lambda p, q: d32(p[2], q[2]))
    if ifw and ins:
        print("i960 cycles a vblank (median over 30-vblank windows), of %.0f:" % cpu_vbl)
        print("  instruction fetch wait  %7.0f  %4.1f%%" % (med(ifw), 100 * med(ifw) / cpu_vbl))
        print("  data access wait (all)  %7.0f  %4.1f%%" % (med(mw), 100 * med(mw) / cpu_vbl))
        print("    of which TGP holds    %7.0f  %4.1f%%" % (med(cst) / 2, 100 * med(cst) / VBL))
        print("    geometry push holds   %7.0f  %4.1f%%" % (med(gst) / 2, 100 * med(gst) / VBL))
        print("  instructions retired    %7.0f  (CPI over the vblank %.1f)" % (med(ins), cpu_vbl / max(med(ins), 1)))

# R862: the 2A sound board -- 'S' {68000 bus cycles} | {SCSP writes | bytes in}
#                             'T' {68000 last address(24) | bytes out(8)} | {peak |left| | underruns}
S = [(a, d >> 16, d & 0xffff) for t, a, d in recs if t == 'S']
T = [(a >> 8, a & 0xff, d >> 16, d & 0xffff) for t, a, d in recs if t == 'T']
if S:
    c0, c1 = S[0][0], S[-1][0]
    print("SOUND (%d S records, %d T records):" % (len(S), len(T)))
    print("  68000 bus cycles: first %d last %d (%s)" % (c0, c1, "RUNNING" if d32(c0, c1) else "NOT MOVING"))
    print("  SCSP writes by the 68000: %d -> %d   bytes i960 -> sound: %d -> %d" % (S[0][1], S[-1][1], S[0][2], S[-1][2]))
if T:
    addrs = [t[0] for t in T]
    from collections import Counter
    print("  68000 last bus address, commonest: %s" % ", ".join("%06x x%d" % (a, n) for a, n in Counter(addrs).most_common(6)))
    print("  bytes sound -> i960: %d -> %d   output FIFO underruns: %d -> %d" % (T[0][1], T[-1][1], T[0][3], T[-1][3]))
    pk = [t[2] for t in T]
    print("  output peak |left| per T record: median %d max %d (%d of %d records non-zero)" % (med(pk), max(pk), sum(1 for p in pk if p), len(pk)))
# R864: 'U' {68000 writes to 0x400-0x401 | to 0x418} | {pre-boot sound-RAM check: words wrong | MVOL}
U = [(a >> 16, a & 0xffff, d >> 16, d & 0xf) for t, a, d in recs if t == 'U']
if U:
    print("  68000 writes to 0x400-0x401 (MVOL): %d -> %d   to 0x418 (timer A): %d -> %d" % (U[0][0], U[-1][0], U[0][1], U[-1][1]))
    print("  MVOL as the SCSP holds it: first %d last %d   pre-boot sound-RAM check: %d of 4096 words wrong%s"
          % (U[0][3], U[-1][3], U[-1][2], "" if U[-1][2] == 0 else "  <-- THE SOUND RAM DOES NOT HOLD WHAT IS WRITTEN"))
# R868: the M2_PROBE build's 'C' {i960 IP} | {copro_stall, sequencer state, bridge, 9'd0}
C = [(a, d >> 31, (d >> 26) & 0x1f) for t, a, d in recs if t == 'C']
if C:
    from collections import Counter
    ips = Counter(c[0] for c in C)
    print("i960 (%d C records): distinct IPs %d; last %08x; TGP stalling in %d" % (len(C), len(ips), C[-1][0], sum(c[1] for c in C)))
    print("  commonest IPs: %s" % ", ".join("%08x x%d" % (a, n) for a, n in ips.most_common(8)))
    print("  last 8 IPs: %s" % " ".join("%08x" % c[0] for c in C[-8:]))
