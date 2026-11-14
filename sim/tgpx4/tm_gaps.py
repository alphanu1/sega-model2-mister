#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R1005: MAME's i960 time between its copro accesses, for tb_tgpx4_replay --tm.
#
#   tm_gaps.py <capdir> <tm.bin> <outdir>
#
# <capdir>/events.bin is an R924 capture; tm.bin the same MAME run's taps
# (tools/mame_stcc_timing.lua: 9-byte records <c1 type, double t>, t the
# i960's own local time inside the tap). The capture's i960-side events
# (C U I N X Y) and the taps (C W W N R R) are the same accesses in the same
# order -- checked, type for type, and the script stops on a mismatch.
#
# Writes <outdir>/tmg.bin, one 16-byte record per i960 event the bench
# presents (C U I N X, in capture order): <double gap, u32 frame, u32 flags>.
#   gap    seconds of MAME i960 time since the previous presented event; for
#          the first event of a frame, since that frame's vblank (the next F
#          tap less VB_OFS, below); for
#          an X read that MAME first found empty (Y), up to the first Y -- the
#          wait for the TGPx4 is the bench's to model, not MAME's
#   frame  GAME frame: flip taps (L) before the event
#   flags  1 first event of its frame; 2 the gap followed a push onto a FULL
#          input FIFO (MAME halts the i960 there until the TGPx4 pops), so it
#          holds MAME's TGPx4 time, not the i960's: set to 0
# and <outdir>/tml.bin, per game frame <double flip_gap, double mame_work>: the
# time from the frame's last copro access to its flip write (0x803008), and
# MAME's own vblank-to-flip time for the frame; <outdir>/flips.txt the session
# time of each flip. TM_KEEP_HALT=1 keeps the gaps after a full-FIFO halt (an
# upper bound on the i960's time; the default, 0, is the lower bound).
import sys, os
import numpy as np

cap, tmf, out = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out, exist_ok=True)
ev = np.fromfile(os.path.join(cap, "events.bin"), dtype=np.dtype([("t", "u1"), ("a", "<u4"), ("b", "<u4")]))
tm = np.fromfile(tmf, dtype=np.dtype([("t", "S1"), ("s", "<f8")]))
et = ev["t"]
C, U, I, N, X, Y, P = (ord(c) for c in "CUINXYP")
# the capture's i960-side stream and the taps' copro stream
cm = np.isin(et, [C, U, I, N, X, Y])
cidx = np.nonzero(cm)[0]
tt = tm["t"]
tmask = np.isin(tt, [b"C", b"W", b"N", b"R"])
tidx = np.nonzero(tmask)[0]
print(f"capture: {len(ev):,} events, {len(cidx):,} i960-side; taps: {len(tm):,}, {len(tidx):,} copro")
n = min(len(cidx), len(tidx))
ct = et[cidx[:n]]
want = np.where(ct == C, ord("C"), np.where((ct == U) | (ct == I), ord("W"), np.where(ct == N, ord("N"), ord("R"))))
got = np.frombuffer(tt[tidx[:n]].tobytes(), dtype=np.uint8)
bad = np.nonzero(want != got)[0]
if len(bad) or len(cidx) != len(tidx):
    print(f"MISMATCH: {len(bad)} type differences in the first {n:,} (first at {bad[:5]}), lengths {len(cidx):,} / {len(tidx):,}")
    if len(bad): sys.exit(1)
# times and frames of every tap
ts = tm["s"]
isF = tt == b"F"
fcount = np.cumsum(isF)                    # frames up to and including each tap
ftime = ts[isF]                            # tap time of each F
# per aligned copro event: its time
t_c = ts[tidx[:n]]
# halt after a push onto a full FIFO: occupancy in capture order (I +1, P -1)
occ_d = np.zeros(len(ev), dtype=np.int64)
occ_d[et == I] = 1
occ_d[et == P] = -1
occ = np.cumsum(occ_d)
iev = cidx[:n]
halted_after = (et[iev] == I) & (occ[iev] > 8)
# presented events: drop Y; an X takes the time of the first Y of its run
ty = ct
keep = ty != Y
# vectorised: positions of kept events; for each kept X, if the previous capture-cpu
# event is a Y, walk back to the first Y of the run
k = np.nonzero(keep)[0]
tk = t_c[k].copy()
yrun = (ty == Y)
# start index of each Y run
prev_is_y = np.zeros(n, dtype=bool); prev_is_y[1:] = yrun[:-1]
xs = k[(ty[k] == X) & prev_is_y[k]]
if len(xs):
    ystart = np.nonzero(yrun & ~prev_is_y)[0]           # first Y of each run
    j = np.searchsorted(ystart, xs, side="right") - 1
    pos = np.searchsorted(k, xs)
    tk[pos] = t_c[ystart[j]]
# GAME frames, not video frames: a game frame runs from the vblank that ends
# its spin to its flip (the 0x803008 write at the top of the wait routine), so
# frame g holds the copro accesses after the g-th flip tap. (MAME's frame
# notifier, tap F, fires ~0.75 ms after the vblank the spin sees: in every race
# frame the first access after a flip comes 0.723-0.756 ms before the next F,
# so the vblank is taken as that F less VB_OFS.)
VB_OFS = 0.756e-3
isL = tt == b"L"
lcount = np.cumsum(isL)
fk = lcount[tidx[:n]][k].astype(np.int64)          # flips before each presented event
prev_t = np.empty_like(tk); prev_t[0] = tk[0]; prev_t[1:] = t_c[k[:-1]]   # the previous presented event's tap time
first = np.ones(len(k), dtype=bool); first[1:] = fk[1:] != fk[:-1]
# the vblank that started each frame: the first F tap after the frame's first event, less VB_OFS
fpos = np.searchsorted(np.nonzero(isF)[0], tidx[:n][k])
fnext = np.where(fpos < len(ftime), ftime[np.clip(fpos, 0, len(ftime) - 1)], tk)
vstart = fnext - VB_OFS
gap = np.where(first, np.maximum(tk - vstart, 0.0), tk - prev_t)
# halts: the event after a halted push carries MAME's TGPx4 time too
h = np.zeros(len(k), dtype=bool)
ha = halted_after[k]
h[1:] = ha[:-1]
KEEP_HALT = os.environ.get("TM_KEEP_HALT") == "1"
if not KEEP_HALT:
    gap = np.where(h & ~first, 0.0, gap)
neg = np.count_nonzero(gap < 0)
gap = np.maximum(gap, 0.0)
flags = first.astype(np.uint32) | (h.astype(np.uint32) << 1)
rec = np.zeros(len(k), dtype=np.dtype([("g", "<f8"), ("f", "<u4"), ("fl", "<u4")]))
rec["g"] = gap; rec["f"] = fk; rec["fl"] = flags
rec.tofile(os.path.join(out, "tmg.bin"))
# per game frame: the gap from its last copro access to its flip, and MAME's
# own vblank-to-flip time
nf = int(lcount[-1]) + 1
lastc = np.full(nf, -1.0)
np.maximum.at(lastc, fk, t_c[k])
vs = np.full(nf, np.inf)
np.minimum.at(vs, fk, np.where(first, vstart, np.inf))
Lt = ts[isL]                                         # flip g ends frame g
flip = np.full(nf, -1.0); flip[:len(Lt)] = Lt
flip_gap = np.where((flip >= 0) & (lastc >= 0), np.maximum(flip - lastc, 0.0), 0.0)
mwork = np.where((flip >= 0) & np.isfinite(vs), flip - vs, 0.0)
tl = np.zeros(nf, dtype=np.dtype([("g", "<f8"), ("w", "<f8")]))
tl["g"] = flip_gap; tl["w"] = mwork
tl.tofile(os.path.join(out, "tml.bin"))
# the session time of each game frame's flip, for choosing --tm-from
np.savetxt(os.path.join(out, "flips.txt"), np.c_[np.arange(len(Lt)), Lt], fmt="%d %.6f")
print(f"presented {len(k):,} (Y dropped {np.count_nonzero(~keep):,}); frames {nf:,}; "
      f"gaps zeroed after a full-FIFO halt {np.count_nonzero(h & ~first):,}; negative gaps clamped {neg}")
print(f"input FIFO occupancy over 8 after a push: {np.count_nonzero(halted_after):,}")
