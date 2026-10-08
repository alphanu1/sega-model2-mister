#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R719: what a race spends its time on, from a telemetry-lite capture
# (M2_DEBUG_LITE; tools/uart_capture.py on the board).
#
#   python3 tools/m2-decode-race.py <capture.txt> [first_vblank]
#
# Reads the C record (~135 Hz, sampled): the i960's IP, and in its data word
#   {copro_stall, walk wst[3:0], engine st[4:0], fb_busy, fb_complete,
#    quad hand-off stalled, read-ahead busy, 0, 0, tgp_pc[15:0]}
# and the G record (every vblank): {game flips, vblanks}. Samples before
# first_vblank (default 600: the boot) are skipped.
#
# The game's frame-sync wait is the IP loop at 0x12B0-0x12BF (R690): the
# share of samples there is the share of the CPU's time with nothing to do.
import sys, collections

WALK = ["W_IDLE", "W_FETCH", "W_DECODE", "W_SKIP", "W_CNT", "W_TFIFO", "W_DDSKIP",
        "W_DDATTR", "W_OPRD", "W_OBJW", "W_PDA", "W_PDR", "W_PDW", "W_TPI", "W_TPP", "W_TPC"]
ENG = ["E_IDLE", "E_RD", "E_XF", "E_XFW", "E_FOC", "E_FOCW", "E_STORE", "E_ATTR", "E_NORM",
       "E_NXF", "E_NXFW", "E_SKIP", "E_EMIT", "E_LINK", "E_DONE", "E_DOT", "E_DOTA",
       "E_LUMM", "E_LUMMW", "E_LUMA", "E_LUMAW", "E_TH0", "E_TH1", "E_TH2", "E_TH3", "E_CC",
       "E_PAL", "E_XL", "E_XLG", "E_CW", "E_UV"]
SYNC = range(0x12B0, 0x12C0)

first = int(sys.argv[2]) if len(sys.argv) > 2 else 600
vbl = None; v0 = None
C = []; G = []
for l in open(sys.argv[1], errors='ignore'):
    f = l.split()
    if len(f) != 3 or len(f[1]) != 8 or len(f[2]) != 8: continue
    try: a = int(f[1], 16); d = int(f[2], 16)
    except ValueError: continue
    if f[0] == 'G':
        v = a & 0xffff
        if v0 is None: v0 = v
        vbl = (v - v0) & 0xffff
        G.append((vbl, a >> 16, v))
    elif f[0] == 'C' and vbl is not None and vbl >= first:
        C.append((a, d))

if len(G) > 2:
    g = [x for x in G if x[0] >= first]
    dv = (g[-1][2] - g[0][2]) & 0xffff; df = (g[-1][1] - g[0][1]) & 0xffff
    print("GAME: %d flips in %d vblanks -> %.1f fps of 57.5 (a frame every %.2f vblanks)"
          % (df, dv, 57.52 * df / max(dv, 1), dv / max(df, 1)))
    per = collections.Counter()
    for x, y in zip(g, g[1:]):
        per[(y[1] - x[1]) & 0xffff] += 1
    print("  flips per vblank:", ", ".join("%d: %.0f%%" % (k, 100 * v / max(sum(per.values()), 1))
                                         for k, v in sorted(per.items())))

n = len(C)
if not n:
    print("no C samples after vblank %d" % first); sys.exit(0)
spin = sum(1 for a, d in C if a in SYNC)
print("\nCPU: %d samples; in the frame-sync wait %.1f%% -> working %.1f%% of the time" % (n, 100 * spin / n, 100 - 100 * spin / n))
print("  copro_stall (TGP holding the i960) %.1f%%" % (100 * sum((d >> 31) & 1 for a, d in C) / n))
w = collections.Counter((d >> 27) & 0xf for a, d in C)
e = collections.Counter((d >> 22) & 0x1f for a, d in C)
fb_busy = sum((d >> 21) & 1 for a, d in C); fb_cmp = sum((d >> 20) & 1 for a, d in C)
qst = sum((d >> 19) & 1 for a, d in C); rab = sum((d >> 18) & 1 for a, d in C)
print("\nWALK state:")
for k, v in w.most_common(): print("  %-9s %5.1f%%" % (WALK[k] if k < len(WALK) else k, 100 * v / n))
print("ENGINE state:")
for k, v in e.most_common(12): print("  %-9s %5.1f%%" % (ENG[k] if k < len(ENG) else k, 100 * v / n))
print("RENDERER: fb_busy (drawing) %.1f%%, fb_complete %.1f%%; quad hand-off stalled %.1f%%; read-ahead busy %.1f%%"
      % (100 * fb_busy / n, 100 * fb_cmp / n, 100 * qst / n, 100 * rab / n))
