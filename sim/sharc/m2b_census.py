#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
"""R1023: a Model 2B game's SHARC program from sim/sharc/m2b_census.sh's output.

  m2b_census.py spins  <dir>            the M2B_SPIN list: every "IF FLAGn_IN, JUMP (self)"
                                        and the body of a one-word "DO .. UNTIL .. FLAG" loop
  m2b_census.py census <dir> [<dir>..]  program / data words used, the instruction forms
                                        executed (spins apart), external accesses, per frame
  m2b_census.py frames <dir> [from to]  per-vblank work, MAME's i960 waits, percentiles

The opcode classes and compute kinds are Hornet's (scripts/sharc_profile_report.py,
ppriest/Arcade-KonamiHornet_MiSTer 91edb27, GPL-3.0), restated here.
"""
import collections
import re
import sys
from pathlib import Path

# sharcops_table.cpp, in table order (first match wins), on the top 16 opcode bits
OPS = [
    (0xe000, 0x2000, "compute + dual DM/PM move"),
    (0xff00, 0x0100, "compute"),
    (0xf000, 0x4000, "compute + ureg DM/PM premod"),
    (0xf000, 0x5000, "compute + ureg DM/PM postmod"),
    (0xf180, 0x6000, "compute + DM->dreg immmod"),
    (0xf180, 0x6080, "compute + dreg->DM immmod"),
    (0xf180, 0x6100, "compute + PM->dreg immmod"),
    (0xf180, 0x6180, "compute + dreg->PM immmod"),
    (0xf000, 0x7000, "compute + ureg<->ureg"),
    (0xf000, 0x8000, "imm shift + DM/PM move"),
    (0xff00, 0x0200, "imm shift"),
    (0xff00, 0x0400, "compute + modify"),
    (0xff80, 0x0600, "jump direct"),
    (0xff80, 0x0680, "call direct"),
    (0xff80, 0x0700, "jump relative"),
    (0xff80, 0x0780, "call relative"),
    (0xff80, 0x0800, "jump indirect (+compute)"),
    (0xff80, 0x0880, "call indirect (+compute)"),
    (0xff80, 0x0900, "jump relative + compute"),
    (0xff80, 0x0980, "call relative + compute"),
    (0xe000, 0xc000, "jump indirect + compute + DM"),
    (0xe000, 0xe000, "jump relative + compute + DM"),
    (0xff00, 0x0a00, "RTS (+compute)"),
    (0xff00, 0x0b00, "RTI (+compute)"),
    (0xff00, 0x0c00, "DO UNTIL LCE (imm count)"),
    (0xff00, 0x0d00, "DO UNTIL LCE (ureg count)"),
    (0xff00, 0x0e00, "DO UNTIL condition"),
    (0xff00, 0x1000, "DM->ureg direct"),
    (0xff00, 0x1100, "ureg->DM direct"),
    (0xff00, 0x1200, "PM->ureg direct"),
    (0xff00, 0x1300, "ureg->PM direct"),
    (0xf100, 0xa000, "DM->ureg indirect"),
    (0xf100, 0xa100, "ureg->DM indirect"),
    (0xf100, 0xb000, "PM->ureg indirect"),
    (0xf100, 0xb100, "ureg->PM indirect"),
    (0xf000, 0x9000, "imm -> DM/PM"),
    (0xff00, 0x0f00, "imm -> ureg"),
    (0xff00, 0x1400, "sysreg bit op"),
    (0xff80, 0x1600, "modify I"),
    (0xff80, 0x1680, "bit reverse"),
    (0xff00, 0x1700, "push/pop stacks"),
    (0xff80, 0x0000, "NOP"),
    (0xff80, 0x0080, "IDLE"),
]
COMPUTE_CLASSES = {0x2000, 0x0100, 0x4000, 0x5000, 0x6000, 0x6080, 0x6100, 0x6180, 0x7000, 0x0400,
                   0x0800, 0x0880, 0x0900, 0x0980, 0xc000, 0xe000, 0x0a00, 0x0b00}
# the classes that make a data memory access (DM or PM bus) besides their compute
MEM_CLASSES = {0x2000: 2, 0x4000: 1, 0x5000: 1, 0x6000: 1, 0x6080: 1, 0x6100: 1, 0x6180: 1, 0x8000: 1,
               0xc000: 1, 0xe000: 1, 0x1000: 1, 0x1100: 1, 0x1200: 1, 0x1300: 1, 0xa000: 1, 0xa100: 1,
               0xb000: 1, 0xb100: 1, 0x9000: 1}
ALU = {0x01: "ADD", 0x02: "SUB", 0x05: "ADD+CI", 0x06: "SUB+CI", 0x0a: "COMP", 0x21: "PASS",
       0x22: "NEG", 0x25: "+CI", 0x26: "+CI-1", 0x29: "INC", 0x2a: "DEC", 0x30: "ABS", 0x40: "AND",
       0x41: "OR", 0x42: "XOR", 0x43: "NOT", 0x61: "MIN", 0x62: "MAX", 0x63: "CLIP",
       0x81: "FADD", 0x82: "FSUB", 0x89: "FAVG", 0x8a: "FCOMP", 0x91: "FADDABS", 0x92: "FSUBABS",
       0xa1: "FPASS", 0xa2: "FNEG", 0xb0: "FABS", 0xbd: "SCALB", 0xc1: "LOGB", 0xc4: "RECIPS",
       0xc5: "RSQRTS", 0xc9: "FIX", 0xca: "FLOAT", 0xd9: "FIX BY", 0xda: "FLOAT BY",
       0xe0: "COPYSIGN", 0xe1: "FMIN", 0xe2: "FMAX", 0xe3: "FCLIP"}
MUL = {0x14: "MRF=0", 0x16: "MRB=0", 0x30: "FMUL", 0x40: "MUL UUI", 0x70: "MUL SSI",
       0xb0: "MRF+=SSI", 0xb2: "MRB+=SSI"}
SHF = {0x00: "LSHIFT", 0x02: "ROT", 0x08: "OR LSHIFT", 0x10: "FEXT", 0x12: "FEXT (SE)",
       0x19: "OR FDEP", 0x30: "BSET", 0x31: "BCLR", 0x33: "BTST"}
MULTI = {0x00: "MR->reg", 0x01: "reg->MR", 0x04: "MUL SSFR || ADD", 0x05: "MUL SSFR || SUB",
         0x18: "FMUL || FADD", 0x19: "FMUL || FSUB", 0x1a: "FMUL || FLOAT BY",
         0x1b: "FMUL || FIX BY", 0x1c: "FMUL || FAVG", 0x1d: "FMUL || FABS", 0x1e: "FMUL || FMAX",
         0x1f: "FMUL || FMIN"}


def op_class(op48):
    top = (op48 >> 32) & 0xffff
    for mask, bits, name in OPS:
        if top & mask == bits:
            return bits, name
    return None, "unknown"


def compute_kind(c):
    """(unit, fixed/float, op name) of a 23-bit compute field, or None when it is 0."""
    if c == 0:
        return None
    if c & 0x400000:
        mo = (c >> 16) & 0x3f
        if mo >= 0x30:
            return ("multifunction", "float", "FMUL || FADD,FSUB (dual)")
        name = MULTI.get(mo, f"multi {mo:02x}")
        return ("multifunction", "float" if mo >= 0x18 else "fixed", name)
    cu, op = (c >> 20) & 3, (c >> 12) & 0xff
    if cu == 0:
        if 0x70 <= op <= 0x7f:
            return ("ALU", "fixed", "dual ADD/SUB")
        if op >= 0xf0:
            return ("ALU", "float", "dual FADD/FSUB")
        return ("ALU", "float" if op & 0x80 else "fixed", ALU.get(op, f"alu {op:02x}"))
    if cu == 1:
        return ("multiplier", "float" if op == 0x30 else "fixed", MUL.get(op, f"mul {op:02x}"))
    if cu == 2:
        return ("shifter", "fixed", SHF.get(op >> 2, f"shift {op >> 2:02x}"))
    return ("?", "?", f"cu3 {op:02x}")


def load_pc(d):
    """pc.txt: {pc: (op, count, versions, disassembly)}"""
    out = {}
    for line in open(Path(d) / "pc.txt"):
        if line.startswith("#"):
            continue
        f = line.split(None, 4)
        out[int(f[0], 16)] = (int(f[1], 16), int(f[2]), int(f[3]), f[4].strip() if len(f) > 4 else "")
    return out


def spin_pcs(pcs):
    """Waits: a flag test jumping to itself, and a one-word DO loop's body ended on a flag."""
    sp = []
    for pc, (op, n, v, dis) in pcs.items():
        m = re.match(r"IF (NOT )?FLAG[0-3]_IN, JUMP \(0x([0-9A-Fa-f]+)\)$", dis)
        if m and int(m.group(2), 16) == pc:
            sp.append(pc)
        m = re.match(r"DO \(0x([0-9A-Fa-f]+)\) UNTIL (NOT )?FLAG[0-3]_IN", dis)
        if m and int(m.group(1), 16) == pc + 1:
            sp.append(pc + 1)
    return sorted(set(sp))


def spin_waits(pcs, sp):
    """Executions of the spin PCs that were waits: all but the pass that falls through."""
    w = {}
    for pc in sp:
        n = pcs.get(pc, (0, 0))[1]
        nxt = pcs.get(pc + 1, (0, 0))[1]
        w[pc] = max(0, n - nxt)
    return w


def runs(words):
    out = []
    for w in sorted(words):
        if out and w == out[-1][1] + 1:
            out[-1][1] = w
        else:
            out.append([w, w])
    return out


def fmt_runs(rs, limit=16):
    s = ", ".join(f"{a:05x}-{b:05x}" if a != b else f"{a:05x}" for a, b in rs[:limit])
    return s + (f", ... ({len(rs)} runs)" if len(rs) > limit else "")


def totals(d):
    t = open(Path(d) / "totals.txt").read().split()
    return {t[i]: t[i + 1] for i in range(0, len(t) - 1, 2)}


def cmd_spins(d):
    print(",".join(f"{pc:05x}" for pc in spin_pcs(load_pc(d))))


def cmd_census(dirs):
    merged = {}
    for d in dirs:
        for pc, (op, n, v, dis) in load_pc(d).items():
            o = merged.get(pc)
            if o and o[0] != op:
                print(f"NOTE {pc:05x}: opcode differs between runs ({o[0]:012x} / {op:012x})")
            merged[pc] = (op, (o[1] if o else 0) + n, v, dis)
    pcs = merged
    sp = spin_pcs(pcs)
    waits = spin_waits(pcs, sp)
    tot = sum(n for _, n, _, _ in pcs.values())
    nwait = sum(waits.values())
    work = tot - nwait
    print(f"runs: {', '.join(str(d) for d in dirs)}")
    for d in dirs:
        t = totals(d)
        print(f"  {Path(d).name}: {t['frames']} vblanks, {int(t['ins']):,} instructions, upload {t['last_upload']} "
              f"16-bit words ({int(t['last_upload']) // 3} PM words) x {t['boots']} boot(s); IOP writes {int(t['iopw']):,}; "
              f"DMA starts {t['dma']}; FIFO in max {t['in_max']} out max {t['out_max']}")
    print(f"\nPROGRAM: {len(pcs)} PM words executed, {fmt_runs(runs(pcs))}")
    hi = max(pcs)
    print(f"  highest PC {hi:05x} = word {hi - 0x20000} of the 4,096 uploaded; versions > 1: "
          f"{sum(1 for v in pcs.values() if v[2] > 1)}")
    print(f"  instructions {tot:,}; waiting (spins) {nwait:,} = {100 * nwait / max(1, tot):.1f}%; work {work:,}")
    print("  spin PCs: " + ", ".join(f"{pc:05x} ({waits[pc]:,})" for pc in sp))

    cls, comp, units, mem = collections.Counter(), collections.Counter(), collections.Counter(), collections.Counter()
    cls_static = collections.Counter()
    nmem = 0
    for pc, (op, n, v, dis) in pcs.items():
        w = n - waits.get(pc, 0)
        bits, name = op_class(op)
        cls[name] += w
        cls_static[name] += 1
        if bits in MEM_CLASSES:
            nmem += w * MEM_CLASSES[bits]
            mem[name] += w
        if bits in COMPUTE_CLASSES:
            k = compute_kind(op & 0x7fffff)
            if k:
                comp[f"{k[0]:13s} {k[1]:5s} {k[2]}"] += w
                units[k[0]] += w
            else:
                comp["(no compute)"] += w
    print(f"\nINSTRUCTION FORMS (work only; % of {work:,}; static words):")
    for name, n in cls.most_common():
        print(f"  {100 * n / work:6.2f}%  {n:>12,}  {cls_static[name]:5d}  {name}")
    print(f"\nCOMPUTE OPERATIONS (work only):")
    for name, n in comp.most_common():
        print(f"  {100 * n / work:6.2f}%  {n:>12,}  {name}")
    print(f"\n  data memory accesses (DM / PM bus, internal and external): {nmem:,} = {nmem / work:.3f} a work instruction")

    # data memory
    for d in dirs[:1]:
        dm = Path(d, "dm.bin").read_bytes()
        pmd = Path(d, "pmdata.bin").read_bytes()
        rd = [a for a in range(len(dm)) if dm[a] & 1]
        wr = [a for a in range(len(dm)) if dm[a] & 2]
        dma = [a for a in range(len(dm)) if dm[a] & 0xc]
        print(f"\nDATA MEMORY ({Path(d).name}; DM word addresses; MAME's 21062: block 0 0x20000-0x27fff, "
              f"block 1 0x28000-0x2ffff mirrored at 0x30000 / 0x38000; short words 0x40000-0x7ffff):")
        allw = sorted(set(rd) | set(wr))
        for lo, hi, nm in ((0, 0x100, "IOP registers"), (0x20000, 0x28000, "block 0"), (0x28000, 0x40000, "block 1 (+mirrors)"),
                           (0x40000, 0x80000, "short-word space")):
            ws = [a for a in allw if lo <= a < hi]
            if ws:
                print(f"  {nm}: {len(ws)} words read or written; read {sum(1 for a in rd if lo <= a < hi)}, written "
                      f"{sum(1 for a in wr if lo <= a < hi)}: {fmt_runs(runs(ws))}")
        print(f"  outside instructions (DMA / host): {len(dma)} words")
        pr = [a + 0x20000 for a in range(len(pmd)) if pmd[a] & 0xf]
        print(f"  PM-bus data accesses: {len(pr)} addresses" + (f": {fmt_runs(runs(pr))}" if pr else ""))
        pru = [a + 0x20000 for a in range(len(pmd)) if pmd[a] & 0xf0]
        print(f"  PM written outside instructions (the upload): {len(pru)} words: {fmt_runs(runs(pru))}")


def load_frames(d):
    rows = []
    for line in open(Path(d) / "frames.txt"):
        if line.startswith("#"):
            continue
        f = line.split()
        rows.append(dict(frame=int(f[0]), t=float(f[1]), ins=int(f[2]), spin=int(f[3]), busy=int(f[4]), idle=int(f[5]),
                         fin=int(f[6]), fin_empty=int(f[7]), fout=int(f[8]), bufr=int(f[9]), bufw=int(f[10]), romr=int(f[11]),
                         iopr=int(f[12]), iopw=int(f[13]), dma=int(f[14]), fctl=int(f[15]), flips=int(f[16]),
                         h_in=float(f[17]), h_out=float(f[18]), in_max=int(f[19]), out_max=int(f[20]),
                         flip_ms=float(f[21]) if len(f) > 21 else -1.0))
    return rows


def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(round(p / 100 * (len(v) - 1))))] if v else 0


def cmd_frames(d, lo=None, hi=None):
    rows = load_frames(d)
    if lo is not None:
        rows = [r for r in rows if lo <= r["t"] < hi]
    print(f"{Path(d).name}: {len(rows)} vblanks" + (f" in {lo}-{hi} s" if lo is not None else ""))
    for k, nm in (("busy", "SHARC work (cycles charged)"), ("spin", "SHARC waiting"), ("fin", "FIFO in pops"),
                  ("fout", "FIFO out pushes"), ("iopw", "IOP writes (commands)"), ("h_out", "i960 halted on the out FIFO, ms"),
                  ("h_in", "i960 halted on a full in FIFO, ms"), ("out_max", "out FIFO max depth"), ("in_max", "in FIFO max depth")):
        v = [r[k] for r in rows]
        print(f"  {nm:38s} p50 {pct(v, 50):>10,.2f}  p90 {pct(v, 90):>10,.2f}  p99 {pct(v, 99):>10,.2f}  max {max(v):>10,.2f}  mean {sum(v) / max(1, len(v)):>10,.2f}")
    fl = [r["flips"] for r in rows]
    gaps = collections.Counter()
    last = None
    for i, r in enumerate(rows):
        for _ in range(r["flips"]):
            if last is not None:
                gaps[i - last] += 1
            last = i
    print(f"  flips {sum(fl)} in {len(rows)} vblanks; vblanks between flips: " +
          ", ".join(f"{g}: {n}" for g, n in sorted(gaps.items())))
    fm = [r["flip_ms"] for r in rows if r["flip_ms"] >= 0]
    if fm:
        print(f"  vblank to flip, ms (frames with a flip): p50 {pct(fm, 50):.2f}  p90 {pct(fm, 90):.2f}  "
              f"p99 {pct(fm, 99):.2f}  max {max(fm):.2f}")


if __name__ == "__main__":
    a = sys.argv[1:]
    if not a:
        sys.exit(__doc__)
    if a[0] == "spins":
        cmd_spins(a[1])
    elif a[0] == "census":
        cmd_census(a[1:])
    elif a[0] == "frames":
        cmd_frames(a[1], float(a[2]) if len(a) > 2 else None, float(a[3]) if len(a) > 3 else None)
    else:
        sys.exit(__doc__)
