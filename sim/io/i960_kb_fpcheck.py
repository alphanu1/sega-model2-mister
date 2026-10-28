#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R969 (GitHub #34): every i960 floating-point result of a MAME session window
# set against an exact model of the 80960KB as Intel's Programmer's Reference
# Manual (Mar 1988) states it, not MAME's host doubles: the infinitely precise
# result rounded ONCE to the destination format (ch. 12, "Rounding Control");
# AC[31:30] = 00 is round to nearest EVEN (Table 3-4); global / local register
# operands of addr / subr / scaler are reals (32-bit), of cvtir an integer.
#
#   i960_kb_fpcheck.py gen <dasm.txt> <t_on> <t_off> > cmds.txt
#       MAME debugger commands, one per line "<emulated s> <command>": a
#       breakpoint on every addr / subr / cmpr / scaler / cvtri / cvtir /
#       cvtzri in a sim/io/mame_m2_dasm.lua listing printing its sources
#       ("FS <pc> <op> <src...>") and one on the next instruction printing its
#       destination ("FD <pc> <op> <dst>"); issue them from a frame notifier in
#       a -debug session and copy the debugger console to a log
#   i960_kb_fpcheck.py check <log>
#       the model against every FS / FD pair in the log
# The log is ROM-derived run output and stays outside the repository.
import sys, re, struct, math
from fractions import Fraction as Fr


def isnum(u): return ((u >> 23) & 0xff) != 0xff


def exact(u):
    e = (u >> 23) & 0xff; m = u & 0x7fffff; s = -1 if u >> 31 else 1
    if e == 0: return s * Fr(m, 1 << 149)
    return s * Fr(m | 0x800000, 1) * (Fr(2) ** (e - 150))


def round_single(x):
    """Fraction -> real (u32), round to nearest even, with denormals."""
    if x == 0: return 0
    s = 0x80000000 if x < 0 else 0
    a = -x if x < 0 else x
    e = math.floor(math.log2(a.numerator) - math.log2(a.denominator))
    while Fr(2) ** e > a: e -= 1
    while Fr(2) ** (e + 1) <= a: e += 1
    sub = e < -126
    if sub: e = -126
    q = a / (Fr(2) ** (e - 23))
    n = q.numerator // q.denominator; r = q - n
    if r > Fr(1, 2) or (r == Fr(1, 2) and n & 1): n += 1
    if n >= (1 << 24): n >>= 1; e += 1
    if e > 127: return s | 0x7f800000
    if sub and n < (1 << 23): return s | n
    return s | ((e + 127) << 23) | (n & 0x7fffff)


def rne_int(x):
    n = math.floor(x); r = x - n
    if r > Fr(1, 2) or (r == Fr(1, 2) and n % 2 == 1): n += 1
    return n


def model(op, src):
    s32 = lambda v: v - (1 << 32) if v >> 31 else v
    if op in ('addr', 'subr') and all(isnum(v) for v in src):
        x = exact(src[1]) + exact(src[0]) if op == 'addr' else exact(src[1]) - exact(src[0])
        return round_single(x), x == 0
    if op == 'cvtri' and isnum(src[0]): return rne_int(exact(src[0])) & 0xffffffff, False
    if op == 'cvtzri' and isnum(src[0]): return int(exact(src[0])) & 0xffffffff, False
    if op == 'cvtir': return round_single(Fr(s32(src[0]))), False
    if op == 'scaler' and isnum(src[1]): return round_single(exact(src[1]) * Fr(2) ** s32(src[0])), False
    return None, False


def check(path):
    ev = [l.split() for l in open(path) if ' FS ' in l or ' FD ' in l]
    tot = diff = skipped = 0; byop = {}; ex = []
    i = 0
    while i < len(ev) - 1:
        a, b = ev[i], ev[i + 1]
        if a[1] == 'FS' and b[1] == 'FD' and a[2] == b[2]:
            op = a[3]; src = [int(v, 16) for v in a[4:]]; got = int(b[4], 16)
            sil, zero = model(op, src)
            if sil is not None and zero and got in (0, 0x80000000): sil = got   # sign of an exact zero
            if sil is None: skipped += 1
            else:
                tot += 1; byop.setdefault(op, [0, 0]); byop[op][0] += 1
                if sil != got:
                    diff += 1; byop[op][1] += 1
                    if len(ex) < 20: ex.append((a[0], a[2], op, [hex(v) for v in src], hex(got), hex(sil)))
            i += 2
        else:
            i += 1
    print("ops modelled", tot, "differ", diff, "not modelled (NaN/inf)", skipped)
    for k, v in byop.items(): print("  %-7s %6d checked, %d differ" % (k, v[0], v[1]))
    for e in ex: print("  ", e)


def gen(dasm, t_on, t_off):
    lines = open(dasm).read().splitlines()
    out = []
    for i, l in enumerate(lines):
        m = re.match(r'^([0-9A-F]{8}): (\S+)(?: \S+)?\s+(subr|addr|cmpr|scaler|cvtri|cvtir|cvtzri)\s+(\S+)', l)
        if not m: continue
        a = int(m.group(1), 16); op = m.group(3); ops = m.group(4).split(',')
        nxt = None
        for l2 in lines[i + 1:i + 3]:
            mm = re.match(r'^([0-9A-F]{8}):', l2)
            if mm: nxt = int(mm.group(1), 16); break
        srcs = ops if op == 'cmpr' else ops[:-1]
        out.append('%s bpset 0x%x,1,{printf "FS %x %s %s",%s; g}' % (t_on, a, a, op, ' '.join(['%08x'] * len(srcs)), ','.join(srcs)))
        if nxt and op != 'cmpr':
            out.append('%s bpset 0x%x,1,{printf "FD %x %s %%08x",%s; g}' % (t_on, nxt, a, op, ops[-1]))
    out.append('%s bpclear' % t_off)
    print('\n'.join(out))


if __name__ == '__main__':
    if sys.argv[1] == 'gen': gen(sys.argv[2], sys.argv[3], sys.argv[4])
    else: check(sys.argv[2])
