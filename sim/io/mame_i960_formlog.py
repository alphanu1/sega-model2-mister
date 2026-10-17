#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R869: WHAT THE GAME'S OWN OPERANDS ASK OF THE FORMS THE 2A CORE LACKED.
# Reads the MAME form log (R869_OUT, sim/io/mame_i960_formlog.patch): a "PC"
# line for every (form, PC) first executed, and a "V" line for every distinct
# operand tuple of those forms -- key, PC, the m1 m2 m3 bits, operand 1 and 2
# as MAME read them (get_1_rif / get_2_rif widened to double, or the rl
# pairs), and the destination after (register pair or fp register). For each
# form: the operand classes, ranges and specials, and every instance checked
# against what i960_top computes:
#   remr     fmod(src2, src1), exact (math.fmod), narrowed like set_rif
#   atanr    R845's microcode run by its own interpreter (tools/i960_fptrans.py)
#   sinr     on the widened operands, then narrowed (struct '<f', RNE)
#   cvtzril  the module's cvtzri, sign-extended (exact while |x| < 2^31)
#   cpysre   |src1| with src2's sign as MAME tests it (src2 >= 0.0)
#
#   mame_i960_formlog.py <forms.txt> [...]
import math, os, struct, sys
from collections import defaultdict

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'tools'))
import i960_fptrans as T                                   # noqa: E402

NAMES = {0x680: 'atanr', 0x683: 'remr', 0x68c: 'sinr', 0x68d: 'cosr', 0x68e: 'tanr', 0x6c3: 'cvtzril',
         0x6e2: 'cpysre', 0x66d: 'flushreg', 0x660: 'calls', 0x698: 'sqrtrl', 0x690: 'atanrl',
         0x69c: 'sinrl', 0x69d: 'cosrl', 0x69e: 'tanrl', 0x6c1: 'cvtril', 0x6e1: 'movre', 0x675: 'cvtilr',
         0x676: 'scalerl', 0x681: 'logepr', 0x682: 'logr', 0x689: 'expr', 0x692: 'logrl', 0x699: 'exprl',
         0x69a: 'logbnrl', 0x69b: 'roundrl'}


def u2d(u): return struct.unpack('<d', struct.pack('<Q', u))[0]
def d2u(d): return struct.unpack('<Q', struct.pack('<d', d))[0]
def f2u(d):
    try:
        u = struct.unpack('<I', struct.pack('<f', d))[0]
    except OverflowError:
        u = 0x7f800000 | (0x80000000 if d < 0 else 0)
    if (u >> 23) & 0xff == 0 and u & 0x7fffff:          # the units flush a subnormal single
        u &= 0x80000000
    return u


def cls(d):
    if math.isnan(d): return 'nan'
    if math.isinf(d): return 'inf'
    if d == 0.0: return 'zero'
    if abs(d) < 2.2250738585072014e-308: return 'sub'
    return 'norm'


_P = None
def trans(entry, x, y=0.0):
    global _P
    if _P is None:
        p = T.build(); _P = (p,) + T.assemble(p)
    p, words, addr, names = _P
    return T.run(p, words, addr, names, entry, x, y)[0]


def main():
    pcs, insn_of = defaultdict(list), {}
    V = defaultdict(list)
    for fn in sys.argv[1:]:
        for ln in open(fn):
            f = ln.split()
            if f and f[0] == 'PC':
                k, pc, insn, t = int(f[1], 16), int(f[2], 16), int(f[4], 16), float(f[6])
                pcs[k].append((t, pc, insn)); insn_of[pc] = insn
            elif f and f[0] == 'V' and len(f) >= 7:
                V[int(f[1], 16)].append((int(f[2], 16), f[3], int(f[4], 16), int(f[5], 16), int(f[6], 16),
                                         float(f[8]) if len(f) > 8 else 0.0))
    for k in sorted(pcs):
        lst = sorted(pcs[k])
        print('%-8s %03x  first %.4f s at %08x; %d PCs: %s' % (NAMES.get(k, '?'), k, lst[0][0], lst[0][1], len(lst),
              ' '.join('%08x(%.2f)' % (pc, t) for t, pc, _ in lst)))
    for k in sorted(V):
        vs = V[k]; nm = NAMES.get(k, '?')
        bad = 0; srcs = defaultdict(int); classes = defaultdict(int)
        lo, hi = math.inf, -math.inf
        ediff = 0; ratio = 0.0; negs = [0, 0]
        for pc, m, a, b, res, t in vs:
            ins = insn_of.get(pc, 0)
            m1, m2, m3 = int(m[1]), int(m[2]), int(m[3])
            s1 = ('fp%d' % (ins & 3)) if (m1 and (ins & 0x1f) < 4) else ('lit' if m1 else 'reg')
            s2 = ('fp%d' % ((ins >> 14) & 3)) if (m2 and ((ins >> 14) & 0x1f) < 4) else ('lit' if m2 else 'reg')
            dd = ('fp%d' % ((ins >> 19) & 3)) if m3 else 'reg'
            srcs['src1 %s, src2 %s -> %s' % (s1, s2, dd)] += 1
            x1, x2 = u2d(a), u2d(b)
            classes['%s/%s' % (cls(x1), cls(x2))] += 1
            got = res if m3 else res & 0xffffffff
            if k == 0x683:                                 # remr: fmod(src2, src1)
                y, x = x1, x2
                negs[0] += x < 0; negs[1] += y < 0
                if cls(x) == 'norm' and cls(y) == 'norm':
                    ex, ey = math.frexp(x)[1], math.frexp(y)[1]
                    ediff = max(ediff, ex - ey); ratio = max(ratio, abs(x / y))
                    lo, hi = min(lo, x), max(hi, x)
                try:
                    r = math.fmod(x, y)
                except ValueError:
                    r = math.nan
                want = d2u(r) if m3 else f2u(r)
                ok = (got == want) or (math.isnan(r) and math.isnan(u2d(got) if m3 else struct.unpack('<f', struct.pack('<I', got))[0]))
            elif k in (0x680, 0x68c):                      # atanr / sinr on the sequencer
                r = trans('atan', x1, x2) if k == 0x680 else trans('sin', x1)
                lo, hi = min(lo, x1), max(hi, x1)
                want = d2u(r) if m3 else f2u(r)
                ok = got == want
            elif k == 0x6c3:                               # cvtzril
                lo, hi = min(lo, x1), max(hi, x1)
                v = int(x1) if not (math.isnan(x1) or math.isinf(x1)) else 0
                ok = abs(x1) < 2147483648.0 and (res == (v & 0xffffffffffffffff))
            elif k == 0x6e2:                               # cpysre
                r = abs(x1) if x2 >= 0.0 else -abs(x1)
                lo, hi = min(lo, x1), max(hi, x1)
                want = d2u(r) if m3 else d2u(r)
                ok = (res == want) if not m3 else (got == want)
            else:
                ok = True
            bad += not ok
        print('\n%s (%03x): %d distinct operand tuples' % (nm, k, len(vs)))
        for s, c in sorted(srcs.items(), key=lambda z: -z[1]): print('   %-40s %d' % (s, c))
        print('   operand classes (src1/src2): ' + ', '.join('%s %d' % kv for kv in sorted(classes.items())))
        if k == 0x683:
            print('   dividend range %.6g .. %.6g, negative dividends %d, negative divisors %d' % (lo, hi, negs[0], negs[1]))
            print('   largest exponent difference %d, largest |x / y| %.6g' % (ediff, ratio))
        elif lo <= hi:
            print('   src1 range %.9g .. %.9g' % (lo, hi))
        print('   module != MAME on %d of %d' % (bad, len(vs)))


if __name__ == '__main__':
    main()
