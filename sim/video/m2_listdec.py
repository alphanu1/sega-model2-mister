#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# DECODE ONE DISPLAY-LIST WALK out of a MAME dump (patch p14: bufferram.bin and
# state.txt), as geo_parse walks it -- jumps followed, bounded by 0x8000
# opcodes and the end of buffer RAM -- and report what an RTL walk cares about:
# opcode histogram, geo_mode values, every object's oba / obc / tha / tpa, the
# memories they select, counts of count-driven commands, and anything outside
# what Daytona has been seen to send (R836).
#
#   m2_listdec.py <dump dir> [-v]      -v prints every command
import os, struct, sys
from collections import Counter

NAMES = {0x00: "nop", 0x01: "object", 0x02: "direct", 0x03: "window", 0x04: "texdata",
         0x05: "polydata", 0x06: "texparam", 0x07: "mode", 0x08: "zsort", 0x09: "focal",
         0x0a: "light", 0x0b: "matrix", 0x0c: "translate", 0x0d: "datapush", 0x0e: "test",
         0x0f: "end", 0x10: "dummy", 0x11: "object", 0x12: "direct", 0x13: "window",
         0x14: "logdata", 0x15: "polydata", 0x16: "lod", 0x17: "mode", 0x18: "zsort",
         0x19: "focal", 0x1a: "light", 0x1b: "matrix", 0x1c: "translate", 0x1d: "upload",
         0x1e: "codejump", 0x1f: "end"}
FIXED = {0x00: 0, 0x10: 1, 0x01: 4, 0x11: 4, 0x03: 6, 0x13: 6, 0x07: 1, 0x17: 1, 0x08: 1, 0x18: 1,
         0x09: 2, 0x19: 2, 0x0a: 3, 0x1a: 3, 0x0b: 12, 0x1b: 12, 0x0c: 3, 0x1c: 3, 0x16: 1, 0x1e: 1,
         0x0f: 0, 0x1f: 0}


def u2f(w):
    return struct.unpack("<f", struct.pack("<I", w))[0]


def decode(d, verbose=False):
    raw = open(os.path.join(d, "bufferram.bin"), "rb").read()
    buf = struct.unpack("<%dI" % (len(raw) // 4), raw)
    start = 0
    for ln in open(os.path.join(d, "state.txt")):
        if ln.startswith("walk"):
            start = int(ln.split()[3], 16)
    ip, ops, ended, jumps = start, 0, False, 0
    hist, notes, objs, modes = Counter(), [], [], []
    while not ended and ip < 0x8000 and ops < 0x8000:
        op = buf[ip]; ops += 1
        if op & 0x80000000:
            ip = (op & 0x1ffff) // 4; jumps += 1
            if verbose: print("  %05x jump -> %05x" % (ip, ip))
            continue
        c = (op >> 23) & 0x1f
        hist[NAMES[c] + "_%02x" % c] += 1
        at = ip; ip += 1
        a = lambda k: buf[ip + k] if ip + k < len(buf) else 0
        if c in FIXED:
            n = FIXED[c]
            if c in (0x01, 0x11):
                tpa, tha, oba, obc = a(0), a(1), a(2), a(3)
                objs.append((at, op, tpa, tha, oba, obc))
            if c in (0x07, 0x17):
                modes.append(a(0))
            if c in (0x0f, 0x1f):
                ended = True
            if c in (0x1e, 0x10, 0x0d, 0x0e, 0x1d):
                notes.append("%05x %s" % (at, NAMES[c]))
            if verbose:
                print("  %05x %08x %-9s %s" % (at, op, NAMES[c], " ".join("%08x" % a(k) for k in range(n))))
            ip += n
        elif c in (0x04, 0x05, 0x14, 0x15):
            n = a(1)
            if verbose: print("  %05x %08x %-9s addr %08x count %d" % (at, op, NAMES[c], a(0), n))
            notes.append("%05x %s addr %08x count %d" % (at, NAMES[c], a(0), n)) if n > 0x400 else None
            ip += 2 + n
        elif c == 0x06:
            n = a(1)
            if verbose: print("  %05x %08x texparam idx %d count %d" % (at, op, a(0) >> 2, n))
            ip += 2 + 2 * n
        elif c == 0x0d:
            notes.append("%05x datapush addr %08x count %d (MAME 2 words, RTL 2+count)" % (at, a(0), a(1)))
            ip += 2
        elif c == 0x1d:
            notes.append("%05x upload count %d (MAME 2+3n, RTL 1+3n)" % (at, a(1)))
            ip += 2 + 3 * a(1)
        elif c == 0x0e:
            blocks = a(32)
            notes.append("%05x test blocks %d" % (at, blocks))
            ip += 33 + 3 * blocks
        elif c in (0x02, 0x12):
            notes.append("%05x direct_data" % at)
            ip += 8
            while ip < 0x8000:
                attr = buf[ip]; ip += 1
                if attr & 3 == 0: break
                ip += 8 if attr & 1 else 5
    return dict(start=start, ops=ops, ended=ended, end_ip=ip, jumps=jumps, hist=hist,
                notes=notes, objs=objs, modes=modes)


def main():
    d = sys.argv[1]; v = "-v" in sys.argv
    r = decode(d, v)
    print("%s: start %05x ops %d ended %s at %05x jumps %d modes %s" % (
        d, r["start"], r["ops"], r["ended"], r["end_ip"], r["jumps"], ",".join("%x" % m for m in r["modes"])))
    print("  ops: " + " ".join("%s:%d" % kv for kv in sorted(r["hist"].items())))
    mem = Counter()
    for (at, op, tpa, tha, oba, obc) in r["objs"]:
        sel = "pram1" if oba & 0x1000000 else "rom" if oba & 0x800000 else "pram0"
        mem[sel] += 1
        flag = []
        if sel == "rom" and (oba & 0x3fffff) >= 0x200000: flag.append("ROM>=8MB")
        if obc == 0: flag.append("obc=0")
        if obc > 4096: flag.append("obc>4096")
        if not (tha & 0x800000) and (tha & 0x400000): flag.append("tha in tex pair 2")
        if not (tpa & 0x800000) and (tpa & 0x400000): flag.append("tpa in tex pair 2")
        if flag or v:
            print("  obj %05x op %08x tpa %08x tha %08x oba %08x obc %d %s" % (at, op, tpa, tha, oba, obc, " ".join(flag)))
    print("  objects by memory: " + " ".join("%s:%d" % kv for kv in sorted(mem.items())))
    for n in r["notes"]:
        print("  NOTE " + n)


if __name__ == "__main__":
    main()
