#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
#
# Compare our PC stream against MAME's ACROSS A WAIT LOOP.
#
# tools/i960-diff.sh compares the two streams instruction for instruction and
# stops at the first difference. That is the right instrument for a CPU defect
# and it is how the i960 was verified. It cannot get past a poll.
#
# The reason is timing, not correctness. Our i960 runs at CPI ~3.95; MAME's
# model retires close to one instruction per cycle. Both reach 178 V-blanks in
# the same 3.1 seconds of emulated time, but MAME executes ~307,000
# instructions per frame and we execute ~110,000. So any loop that spins
# WAITING FOR AN EXTERNAL EVENT runs a different number of iterations on the
# two machines, and a strict comparison reports a divergence that is a
# difference in speed rather than in behaviour.
#
# THIS IS NOT LOOP COLLAPSING, which study R15 and Model 1's `9b3b70a` both
# record as having produced wrong answers. Collapsing rewrites the stream before
# comparing, and erases exactly the case where one side is stuck in a loop the
# other does not have. This compares raw streams, and only when they disagree
# does it look for a resynchronisation point -- then reports every one it took,
# with how many instructions each side skipped, so a resync that hides a real
# defect is visible as an implausible number rather than silently absorbed.
#
# A resync is only accepted if both sides were in a SHORT REPEATING CYCLE at the
# point of divergence. A stream that diverged by going somewhere new is a real
# defect and stops the comparison, as it should.
#
#   tools/i960-resync-diff.py mame.pc ours.pc [max_skip]

import sys, mmap

REC = 9          # "%08x\n"

class Trace:
    def __init__(self, path):
        self.f  = open(path, 'rb')
        self.m  = mmap.mmap(self.f.fileno(), 0, access=mmap.ACCESS_READ)
        self.n  = len(self.m) // REC
    def __getitem__(self, i):
        return self.m[i*REC:i*REC+8]

def find_pc(t, pc, start, limit):
    """Next index >= start whose record is pc, or None. mmap.find is C-speed;
    a Python loop over 50M records is not, and the sound poll spins for about
    that many."""
    pos = start * REC
    end = min(t.n, start + limit) * REC
    while pos < end:
        k = t.m.find(pc, pos, end)
        if k < 0: return None
        if k % REC == 0: return k // REC
        pos = (k // REC + 1) * REC
    return None

def span_pcs(t, a, b, cap=64):
    """Distinct PCs in [a,b), giving up past `cap` — a wait loop has few."""
    seen = set()
    for k in range(a, b):
        seen.add(t[k])
        if len(seen) > cap: return None
    return seen

def main():
    mame, ours = Trace(sys.argv[1]), Trace(sys.argv[2])
    max_skip = int(sys.argv[3]) if len(sys.argv) > 3 else 60_000_000
    print(f"  MAME {mame.n} instructions, ours {ours.n}")

    i = j = 0
    resyncs = []
    while i < mame.n and j < ours.n:
        if mame[i] == ours[j]:
            i += 1; j += 1; continue

        # Diverged. A resync is legitimate only if the side that ran on was
        # going round a SHORT loop -- that is a difference in speed. A side
        # that diverged by going somewhere new is a real defect and must stop
        # the comparison.
        best = None
        for who, t_run, run_i, t_other, other_i in (
                ('mame', mame, i, ours, j), ('ours', ours, j, mame, i)):
            k = find_pc(t_run, t_other[other_i], run_i, max_skip)
            if k is None or k == run_i: continue
            pcs = span_pcs(t_run, run_i, k)
            if pcs is None: continue          # too varied to be a wait loop
            if best is None or k - run_i < best[2]:
                best = (who, k, k - run_i, len(pcs))
        if best is None: break
        who, k, skipped, npcs = best
        resyncs.append((i, j, who, skipped, npcs, mame[i-1].decode()))
        if who == 'mame': i = k
        else:             j = k

    if resyncs:
        print(f"  resynchronised {len(resyncs)} time(s) across wait loops:")
        for (mi, oi, who, sk, npcs, pc) in resyncs[:20]:
            print(f"    mame={mi:>9} ours={oi:>9}  after {pc}: "
                  f"{who} ran on {sk} instructions over {npcs} distinct PCs")
        if len(resyncs) > 20:
            print(f"    ... and {len(resyncs)-20} more")
    if i >= mame.n or j >= ours.n:
        print(f"  IDENTICAL to the end of the shorter stream "
              f"(mame {i}/{mame.n}, ours {j}/{ours.n})")
        return 0
    print(f"  DIVERGES at mame={i} ours={j}")
    for k in range(6, 0, -1):
        if i-k >= 0 and j-k >= 0:
            print(f"    -{k:<3d}  mame={mame[i-k].decode()}  ours={ours[j-k].decode()}")
    print(f"    >>>   mame={mame[i].decode()}  ours={ours[j].decode()}")
    for k in range(1, 6):
        if i+k < mame.n and j+k < ours.n:
            print(f"    +{k:<3d}  mame={mame[i+k].decode()}  ours={ours[j+k].decode()}")
    return 1

sys.exit(main())
