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
# R877: 'L' {2'd0, longest wait port 5 | port 6 | port 7 (10 bits each, clk_sys, saturating at 1023)}
#           | {clocks / 16 port 5 had a request outstanding | port 6 / 7 requests that waited >= 256}
# one L record every sixth probe record (~14.8 ms); maxima and counts are since the last L
L = [((a >> 20) & 0x3ff, (a >> 10) & 0x3ff, a & 0x3ff, d >> 16, d & 0xffff) for t, a, d in recs if t == 'L']
if L:
    us = lambda c: c / mhz
    print("SOUND SDRAM PORTS (%d L records, clk_sys at %.0f MHz; 1023 = saturated):" % (len(L), mhz))
    for i, nm in ((0, "5 (68000)     "), (1, "6 (slot fills)"), (2, "7 (DSP)       ")):
        v = [l[i] for l in L]
        print("  port %s longest wait per record: median %4d p90 %4d max %4d clk (%.2f / %.2f / %.2f us); saturated in %d records" % (
            nm, med(v), pct(v, .9), max(v), us(med(v)), us(pct(v, .9)), us(max(v)), sum(1 for x in v if x >= 1023)))
    win = mhz * 1e6 * 0.0148 / 16
    w5 = [l[3] for l in L]
    print("  port 5 request outstanding: median %.1f%% p90 %.1f%% max %.1f%% of the time" % (
        100 * med(w5) / win, 100 * pct(w5, .9) / win, 100 * max(w5) / win))
    sl = [l[4] for l in L]
    print("  port 6 / 7 requests that waited >= 256 clk: median %d p90 %d max %d a record (%d in all)" % (med(sl), pct(sl, .9), max(sl), sum(sl)))
    print("  (R877, tb_m2_sdram_load in clk_sys: a light video load ~20-75; a heavy one ~250-470 before the AGE fix, ~125-200 after)")
# R868: the M2_PROBE build's 'C' {i960 IP} | {copro_stall, TGP unimplemented, 14'd0, TGP pc} (R871)
C = [(a, d >> 31, (d >> 30) & 1, d & 0xffff) for t, a, d in recs if t == 'C']
if C:
    from collections import Counter
    ips = Counter(c[0] for c in C)
    print("i960 (%d C records): distinct IPs %d; last %08x; TGP stalling it in %d; TGP unimplemented op seen in %d" % (
        len(C), len(ips), C[-1][0], sum(c[1] for c in C), sum(c[2] for c in C)))
    print("  commonest IPs: %s" % ", ".join("%08x x%d" % (a, n) for a, n in ips.most_common(8)))
    print("  commonest TGP pcs: %s" % ", ".join("%04x x%d" % (a, n) for a, n in Counter(c[3] for c in C).most_common(8)))
    print("  last 8 (IP / TGP pc): %s" % " ".join("%08x/%04x" % (c[0], c[3]) for c in C[-8:]))
# R871: 'Q' {words pushed to the TGP | popped from it} | {words it pushed out | in dropped(8) | out dropped(8)}
Q = [(a >> 16, a & 0xffff, d >> 16, (d >> 8) & 0xff, d & 0xff) for t, a, d in recs if t == 'Q']
if Q:
    print("TGP queues (%d Q records), first -> last: pushed in %d -> %d, popped out %d -> %d, TGP pushed out %d -> %d, in dropped %d, out dropped %d" % (
        len(Q), Q[0][0], Q[-1][0], Q[0][1], Q[-1][1], Q[0][2], Q[-1][2], Q[-1][3], Q[-1][4]))
    print("  last: TGP has produced %d words the i960 has not taken (mod 64K)" % ((Q[-1][2] - Q[-1][1]) & 0xffff))
# R880: 'M' every MIDI byte the sound board took: {count so far(24) | n(8)} | {bytes, oldest in 31:24}
M = [(a >> 8, a & 0xff, d) for t, a, d in recs if t == 'M']
if M:
    stream, lost, prev = [], 0, None
    for cnt, n, d in M:
        b = [(d >> (24 - 8 * i)) & 0xff for i in range(n)]
        if prev is not None and cnt - n != prev: lost += (cnt - n - prev) & 0xffffff
        prev = cnt; stream += b
    print("MIDI to the sound board (%d M records): %d bytes, %d lost between records" % (len(M), len(stream), lost))
    if len(sys.argv) > 3:
        open(sys.argv[3], "w").write(" ".join("%02x" % x for x in stream) + "\n")
        print("  stream written to", sys.argv[3])
    print("  first 60:", " ".join("%02x" % x for x in stream[:60]))
# R882: 'R' {region} | {32-bit sum}: the sound ROMs in SDRAM, summed before boot
R = {}
for t, a, d in recs:
    if t == 'R': R[a & 7] = d
if R:
    names = ["program", "samples 0-2 MB", "samples 2-4 MB", "samples 4-6 MB", "samples 6-8 MB"]
    print("SOUND ROMS IN SDRAM (sums of 68000-order words): " + ", ".join("%s %08x" % (names[k], R[k]) for k in sorted(R)))
# R891: 'B' / 'b' -- the power-up memory test (M2_MEMTEST, rtl/mem/m2_memtest.sv)
#   'B' {its pass, region, 3'd0, data errors(9), first bad k} | {7'd0, mask errors(9), first bad word}
#   'b' {passes, parked, 2'd0, AW(5), sdram_sz(16)} | 0  (a pass's totals: the sum of its 'B's)
Bs = [(a >> 24, (a >> 20) & 15, (a >> 8) & 0x1ff, a & 0xff, (d >> 16) & 0x1ff, d & 0xffff) for t, a, d in recs if t == 'B']
bs = [(a >> 24, (a >> 23) & 1, (a >> 16) & 0x1f, a & 0xffff) for t, a, d in recs if t == 'b']
if Bs or bs:
    AWm = bs[-1][2] if bs else 26
    OB = AWm - 4
    def mt_offsets():
        # each region's 256 sample offsets in visiting order; the LFSR runs on across regions
        lf = 0x2468ACE1; out = []
        for r in range(16):
            row = []
            for k in range(256):
                if k == 0: o = 0
                elif k == 1: o = (1 << OB) - 1
                elif k < OB + 2: o = 1 << (k - 2)
                elif k < 2 * OB + 2: o = ((1 << OB) - 1) ^ (1 << (k - OB - 2))
                else:
                    o = lf & ((1 << OB) - 1)
                    lf = ((lf >> 1) ^ 0x80200003) if lf & 1 else (lf >> 1)
                row.append(o)
            out.append(row)
        return out
    OFF = mt_offsets()
    rbytes = 1 << (AWm + 1 - 4)                  # bytes a region
    mt_data = lambda s: ((~s & 0xf) << 12) | (s & 0xfff)
    last = {}
    for b in Bs: last[(b[0], b[1])] = b
    if bs:
        p, parked, aw, sz = bs[-1]
        szs = {0: "none", 1: "32 MB", 2: "64 MB", 3: "128 MB"}[sz & 3] if sz & 0x8000 else "not set"
        print("MEMORY TEST (R891): %d pass(es) complete%s; AW %d = %d MB tested as 16 regions of %d MB; hps_io sdram_sz %04x (%s)" % (
            p, ", parked (a download began)" if parked else "", aw, (1 << (aw + 1)) >> 20, rbytes >> 20, sz, szs))
        rows = [last[(p, r)] for r in range(16) if (p, r) in last]
        if len(rows) == 16:
            de, me = sum(x[2] for x in rows), sum(x[4] for x in rows)
            print("  last complete pass (%d): %d data errors, %d mask errors (of 4,096 words, 2,048 of them byte-masked)%s" % (
                p, de, me, "  -- CLEAN" if de == 0 and me == 0 else ""))
    for p in sorted(set(k[0] for k in last)):
        wait = ["none (written, then read)", "~0.84 s idle", "~3.4 s idle"][p - 1] if 1 <= p <= 3 else "~13.4 s idle"
        rows = [last[(p, r)] for r in range(16) if (p, r) in last]
        print("  pass %d (wait before it: %s): %d of 16 regions reported, %d data errors, %d mask errors" % (
            p, wait, len(rows), sum(x[2] for x in rows), sum(x[4] for x in rows)))
        for (ps, r, de, fk, me, got) in rows:
            if not de and not me: continue
            s = (r << 8) | fk
            word = (r << OB) | OFF[r][fk]
            want = mt_data(s); exp = want
            if fk & 3 == 1: exp = (want & 0xff00) | (~want & 0xff)
            if fk & 3 == 2: exp = (~want & 0xff00) | (want & 0xff)
            why = ""
            if (fk & 3) in (1, 2) and got == (~want & 0xffff):
                why = "  <- the masked byte was written too: BYTE MASK LOST"
            elif ((~got >> 12) & 0xf) == (got & 0xf) and (got & 0xfff) != s:
                gr, gk = (got >> 8) & 15, got & 0xff
                # the pattern's four check bits match one random word in 16, so
                # one region alone is a hint; the same partner across regions is not
                why = "  <- reads as sample %d/%d's data: aliased with byte %07x? (1 in 16 by chance)" % (
                    gr, gk, ((gr << OB) | OFF[gr][gk]) << 1)
            chip, bank = (r >> 3, (r >> 1) & 3) if AWm == 26 else (0, r >> 2)
            print("    region %2d (bytes %07x-%07x, chip %d, bank %d): %3d data, %3d mask errors; first k=%d at byte %07x read %04x want %04x%s" % (
                r, r * rbytes, (r + 1) * rbytes - 1, chip, bank, de, me, fk, word << 1, got, exp, why))

