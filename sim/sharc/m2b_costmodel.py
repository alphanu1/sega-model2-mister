#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
"""R1023: clocks a word for a proposed small SHARC, per program address, from the census.

  m2b_costmodel.py <census dir> [<dir>..] [--design A|B] [--out costs.txt]

Reads MAME's disassembly in pc.txt (sim/sharc/m2b_census.sh), charges each executed word the
clk_sys clocks the design would take, prints the work-weighted mean and the split by cause, and
writes "pc cost" lines for M2B_COSTF (sim/sharc/m2b_pace.sh's MAME run, PACE with a cost file).

A model of a design that does not exist yet, from the disassembly text -- it does not follow
data, so a RAW hazard is counted only between a word and the one at pc - 1 (straight-line code).

Design A (R1023's proposal): one word at a time on shared units, the next word fetched while
this one runs (TGPx4 R1006 / R1009's floor: 2 clocks a word); R0-R15 as four 4-register MLAB
banks (the multifunction groups R0-3 / R4-7 / R8-11 / R12-15, a read port each); float add and
multiply two stages (Hornet's sharc_fadd / sharc_fmul), written behind a scoreboard; DM in M10K
(a load's data the clock after its address); the FIFOs local.
Design B: the same without the prefetch and the scoreboard (fetch, decode, execute, write each a
clock, every float op waited for): the plain FSM, the floor of what could be built first.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import m2b_census as mc  # noqa: E402

REG = re.compile(r"\b([RF])(\d{1,2})\b")
FP_OPS = re.compile(r"\*|\bFLOAT\b|\bFIX\b|\bRECIPS\b|\bRSQRTS\b|\bLOGB\b|F\d+ [+-] F\d+|\bABS F|-F\d")


def parse(dis):
    """(dest regs, source regs, n data accesses, loads, fifo pops, fp ops, kind)"""
    parts = [p.strip() for p in dis.split(",")]
    # rejoin DM(a, b) split by the comma inside it
    j, cur = [], ""
    for p in parts:
        cur = p if not cur else cur + ", " + p
        if cur.count("(") == cur.count(")"):
            j.append(cur)
            cur = ""
    if cur:
        j.append(cur)
    dst, src = set(), set()
    nmem = loads = pops = fp = 0
    for p in j:
        if "=" in p and not p.startswith("IF ") and "UNTIL" not in p:
            lhs, rhs = p.split("=", 1)
            if "DM(" in lhs or "PM(" in lhs:
                nmem += 1
                src |= {int(m.group(2)) for m in REG.finditer(rhs)}
            else:
                dst |= {int(m.group(2)) for m in REG.finditer(lhs)}
                src |= {int(m.group(2)) for m in REG.finditer(rhs)}
                if "DM(" in rhs or "PM(" in rhs:
                    nmem += 1
                    loads += 1
                    if "DM(I0, M0)" in rhs:
                        pops += 1
                elif FP_OPS.search(rhs):
                    fp += 1
    kind = "other"
    if re.search(r"\bJUMP\b|\bCALL\b|\bRTS\b", dis):
        kind = "flow_db" if "(DB)" in dis else "flow"
    elif dis.startswith("DO ") or "DO (" in dis:
        kind = "loop"
    return dst, src, nmem, loads, pops, fp, kind


def cost(design, cur, prev):
    dst, src, nmem, loads, pops, fp, kind = cur
    if design == "A":
        c = 2
        c += max(0, nmem - 1)                 # a second data access (type 1 dual move)
        if fp and nmem:
            c += 0                            # the access goes under the float op's first stage
        if kind == "flow":
            c += 2                            # the prefetched word is dropped, the target fetched
        elif kind == "flow_db":
            c += 0                            # delayed: the two words after it are the delay slots
        if prev is not None:
            pdst, _, _, ploads, _, pfp, _ = prev
            if pfp and (src & pdst):
                c += 1                        # a float result read by the next word: one more clock
            elif ploads and (src & pdst):
                c += 0                        # a load is written in its own clock (forwarded)
        return c
    # design B: no overlap
    c = 4                                     # fetch, decode, execute, write
    c += nmem                                 # each access its own clock
    c += 2 * min(fp, 1)                       # wait for the two-stage unit
    if kind in ("flow", "flow_db"):
        c += 1
    return c


def main():
    a = sys.argv[1:]
    design, out = "A", None
    if "--design" in a:
        i = a.index("--design"); design = a[i + 1]; del a[i:i + 2]
    if "--out" in a:
        i = a.index("--out"); out = a[i + 1]; del a[i:i + 2]
    pcs = {}
    for d in a:
        for pc, v in mc.load_pc(d).items():
            o = pcs.get(pc)
            pcs[pc] = (v[0], (o[1] if o else 0) + v[1], v[2], v[3])
    sp = mc.spin_pcs(pcs)
    waits = mc.spin_waits(pcs, sp)
    parsed = {pc: parse(v[3]) for pc, v in pcs.items()}
    costs, tot_w, tot_c = {}, 0, 0
    by = {}
    for pc in sorted(pcs):
        c = cost(design, parsed[pc], parsed.get(pc - 1))
        costs[pc] = c
        w = pcs[pc][1] - waits.get(pc, 0)
        tot_w += w
        tot_c += w * c
        k = parsed[pc][6] + ("+fp" if parsed[pc][5] else "") + ("+mem%d" % parsed[pc][2] if parsed[pc][2] else "")
        by.setdefault(k, [0, 0])
        by[k][0] += w
        by[k][1] += w * c
    print(f"design {design}: {len(pcs)} words, work {tot_w:,} instructions, {tot_c / max(1, tot_w):.3f} clk_sys a word")
    for k, (w, c) in sorted(by.items(), key=lambda kv: -kv[1][1]):
        print(f"  {k:22s} {100 * w / tot_w:6.2f}% of words  {100 * c / tot_c:6.2f}% of clocks  {c / max(1, w):.2f} clk")
    if out:
        with open(out, "w") as f:
            for pc, c in sorted(costs.items()):
                f.write(f"{pc:05x} {c}\n")
        print(f"-> {out}")


if __name__ == "__main__":
    main()
