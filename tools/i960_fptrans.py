#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# THE i960's LONG-REAL TRANSCENDENTALS AS MICROCODE (R845): sinrl, cosrl,
# tanrl, atanrl, written as programs for i960_fptrans -- a sequencer that
# runs them on the i960's own double adder, multiplier and divider -- and
# assembled here into its two ROMs.
#
# THE TARGET IS THE CORRECTLY ROUNDED RESULT. MAME computes these with the
# host's libm on doubles (i960.cpp: set_rifl(sin(get_1_rifl()))); glibc 2.44
# on this machine is correctly rounded on all but ~0.1-0.2% of arguments
# (measured with mpmath: sin 32, cos 22, tan 37, atan2 17 in 20,000), and it
# uses FMA where the CPU has it, so MAME's bits are the host's, not a fixed
# function. The real 80960KB computes in 80-bit extended and rounds to
# double, which is correctly rounded but for double rounding. So the
# programs work in double-double (Dekker's products: the units have no FMA)
# to well past 2^-60 and round once.
#
# Every operation the program performs is an IEEE double add, subtract,
# multiply or divide, round to nearest even, subnormals flushed -- what the
# RTL units do -- so this file's interpreter IS the reference for the RTL
# sequencer: tb_i960_fptrans compares the two word for word.
#
#   tools/i960_fptrans.py --rom rtl/cpu/i960/i960_fptrans_rom.svh
#   tools/i960_fptrans.py --check N   (needs mpmath: the error against the
#       correctly rounded value and agreement with this host's libm)
#   tools/i960_fptrans.py --listing
import math, struct, sys, random

# --------------------------------------------------------------- the machine
OPS = {'ADD': 0, 'SUB': 1, 'MUL': 2, 'DIV': 3, 'BR': 4, 'JMP': 5, 'CALL': 6,
       'RET': 7, 'LDX': 8, 'LDY': 9, 'END': 10}
CONDS = {'NEG': 0, 'ZERO': 1, 'NAN': 2, 'INF': 3, 'BIT0': 4, 'BIT1': 5}
MOD = {'': 0, '-': 1, '|': 2, '-|': 3}       # none, negate, abs, -abs
NREG = 128
ROMW = 32


def d2u(x):
    return struct.unpack('<Q', struct.pack('<d', x))[0]


def u2d(u):
    return struct.unpack('<d', struct.pack('<Q', u & 0xffffffffffffffff))[0]


def flush(x):
    """The units flush subnormal operands and results to a signed zero."""
    u = d2u(x)
    if (u >> 52) & 0x7ff == 0 and (u & ((1 << 52) - 1)):
        return u2d(u & (1 << 63))
    return x


def fop(op, a, b):
    a, b = flush(a), flush(b)
    try:
        if op == 'ADD': r = a + b
        elif op in ('SUB', 'END', 'LDX', 'LDY'): r = a - b
        elif op == 'MUL': r = a * b
        else:
            if b == 0.0:
                r = math.nan if (a == 0.0 or a != a) else math.copysign(math.inf, a) * math.copysign(1.0, b)
            else:
                r = a / b
    except OverflowError:
        r = math.inf
    return flush(r)


class Prog:
    """A program: instructions with symbolic registers and labels."""

    def __init__(self):
        self.code = []          # (op, fields dict)
        self.labels = {}
        self.consts = {}        # name -> value
        self.temps = []         # names
        self.entries = {}

    def const(self, name, v):
        if name not in self.consts:
            self.consts[name] = float(v)
        return name

    def temp(self, *names):
        for n in names:
            if n not in self.temps:
                self.temps.append(n)

    def label(self, n):
        assert n not in self.labels, n
        self.labels[n] = len(self.code)

    def entry(self, n):
        self.entries[n] = len(self.code)

    def emit(self, op, **f):
        self.code.append((op, f))

    # three-address arithmetic; a / b may carry a modifier prefix '-', '|', '-|'
    def alu(self, op, d, a, b):
        self.temp(d)
        self.emit(op, d=d, a=a, b=b)

    def add(self, d, a, b): self.alu('ADD', d, a, b)
    def sub(self, d, a, b): self.alu('SUB', d, a, b)
    def mul(self, d, a, b): self.alu('MUL', d, a, b)
    def div(self, d, a, b): self.alu('DIV', d, a, b)
    def mov(self, d, a): self.alu('SUB', d, a, 'ZERO')
    def br(self, cond, a, target, inv=False): self.emit('BR', cond=cond, a=a, t=target, inv=inv)
    def jmp(self, t): self.emit('JMP', t=t)
    def call(self, t): self.emit('CALL', t=t)
    def ret(self): self.emit('RET')
    def ldx(self, d): self.temp(d); self.emit('LDX', d=d)
    def ldy(self, d): self.temp(d); self.emit('LDY', d=d)
    def end(self, a): self.emit('END', a=a)


def split_mod(s):
    for m in ('-|', '-', '|'):
        if s.startswith(m):
            return MOD[m], s[len(m):]
    return 0, s


# ------------------------------------------------------- double-double kit
# Subroutines take their operands in fixed registers and return in DH, DL.
#   DDMUL  (AH,AL) x (BH,BL)      DDADD  (AH,AL) + (BH,BL)
#   DDDIV  (AH,AL) / (BH,BL)
def build():
    p = Prog()
    p.const('ZERO', 0.0)
    p.const('ONE', 1.0)
    p.const('SPLIT', 134217729.0)            # 2^27 + 1, Dekker's splitter
    p.const('MAGIC', 6755399441055744.0)     # 1.5 * 2^52: x + MAGIC rounds x to an integer
    p.const('PIO4', 0.7853981633974483)      # just above pi/4 (0x3fe921fb54442d18)

    # ---- the dispatch: one entry per instruction (the sequencer jumps here)
    p.entry('sin'); p.jmp('SIN')
    p.entry('cos'); p.jmp('COS')
    p.entry('tan'); p.jmp('TAN')
    p.entry('atan'); p.jmp('ATAN')

    # ---- TWO_PROD: (P, E) = A * B exactly, A in AH, B in BH (Dekker)
    p.label('TWOPROD')
    p.mul('P', 'AH', 'BH')
    p.mul('T0', 'SPLIT', 'AH'); p.sub('T1', 'T0', 'AH'); p.sub('A1', 'T0', 'T1'); p.sub('A2', 'AH', 'A1')
    p.mul('T0', 'SPLIT', 'BH'); p.sub('T1', 'T0', 'BH'); p.sub('B1', 'T0', 'T1'); p.sub('B2', 'BH', 'B1')
    p.mul('T0', 'A1', 'B1'); p.sub('E', 'T0', 'P')
    p.mul('T0', 'A1', 'B2'); p.add('E', 'E', 'T0')
    p.mul('T0', 'A2', 'B1'); p.add('E', 'E', 'T0')
    p.mul('T0', 'A2', 'B2'); p.add('E', 'E', 'T0')
    p.ret()

    # ---- DDMUL: (DH, DL) = (AH, AL) * (BH, BL)
    p.label('DDMUL')
    p.call('TWOPROD')
    p.mul('T0', 'AH', 'BL'); p.add('E', 'E', 'T0')
    p.mul('T0', 'AL', 'BH'); p.add('E', 'E', 'T0')
    p.add('DH', 'P', 'E'); p.sub('T0', 'DH', 'P'); p.sub('DL', 'E', 'T0')
    p.ret()

    # ---- DDADD: (DH, DL) = (AH, AL) + (BH, BL)   (two_sum of the highs)
    p.label('DDADD')
    p.add('S', 'AH', 'BH'); p.sub('T0', 'S', 'AH'); p.sub('T1', 'S', 'T0')
    p.sub('T1', 'AH', 'T1'); p.sub('T0', 'BH', 'T0'); p.add('E', 'T1', 'T0')
    p.add('E', 'E', 'AL'); p.add('E', 'E', 'BL')
    p.add('DH', 'S', 'E'); p.sub('T0', 'DH', 'S'); p.sub('DL', 'E', 'T0')
    p.ret()

    # ---- DDDIV: (DH, DL) = (AH, AL) / (BH, BL)
    # q1 = AH / BH; r = A - q1 * B (exact product); q2 = r / BH
    p.label('DDDIV')
    p.div('Q1', 'AH', 'BH')
    p.mov('QS', 'AH'); p.mov('QSL', 'AL')    # keep A: TWOPROD's registers are AH / BH
    p.mov('AH', 'Q1')
    p.call('TWOPROD')
    # r = (QS - P) - E + QSL - Q1 * BL
    p.sub('T0', 'QS', 'P'); p.sub('T0', 'T0', 'E'); p.add('T0', 'T0', 'QSL')
    p.mul('T1', 'Q1', 'BL'); p.sub('T0', 'T0', 'T1')
    p.div('Q2', 'T0', 'BH')
    p.add('DH', 'Q1', 'Q2'); p.sub('T0', 'DH', 'Q1'); p.sub('DL', 'Q2', 'T0')
    p.ret()

    # ---- reduction: X -> (RH, RL), quadrant bits in QN's mantissa
    # |x| <= pi/4: none. Otherwise fdlibm's medium path, all three
    # Cody-Waite steps unconditionally (pi/2 to 33 + 33 + 33 + 53 bits):
    # exact while k < 2^20.
    p.const('INVPIO2', 6.36619772367581382433e-01)
    p.const('PIO2_1', 1.57079632673412561417e+00)
    p.const('PIO2_2', 6.07710050630396597660e-11)
    p.const('PIO2_3', 2.02226624871116645580e-21)
    p.const('PIO2_3T', 8.47842766036889956997e-32)
    p.label('REDUCE')
    p.mov('QN', 'ZERO'); p.mov('RH', 'X'); p.mov('RL', 'ZERO')
    p.sub('T0', 'PIO4', '|X')
    p.br('NEG', 'T0', 'RED1')                 # |x| > pi/4
    p.ret()
    p.label('RED1')
    p.mul('T0', 'X', 'INVPIO2'); p.add('QN', 'T0', 'MAGIC'); p.sub('FN', 'QN', 'MAGIC')
    # x - fn (P1 + P2 + P3 + P3T): P1..P3 33 bits each, so fn * Pi is exact
    # (fn < 2^20); the two subtractions after the first through two_sum
    p.mul('T0', 'FN', 'PIO2_1'); p.sub('R', 'X', 'T0')          # exact (Sterbenz)
    p.mul('W', 'FN', 'PIO2_2')
    p.sub('S', 'R', 'W'); p.sub('T0', 'S', 'R'); p.sub('T1', 'S', 'T0')
    p.sub('T1', 'R', 'T1'); p.add('T0', '-W', '-T0'); p.add('E1', 'T1', 'T0')   # R - W = S + E1
    p.mul('W', 'FN', 'PIO2_3')
    p.sub('R', 'S', 'W'); p.sub('T0', 'R', 'S'); p.sub('T1', 'R', 'T0')
    p.sub('T1', 'S', 'T1'); p.add('T0', '-W', '-T0'); p.add('E2', 'T1', 'T0')   # S - W = R + E2
    p.mul('W', 'FN', 'PIO2_3T')
    p.add('E1', 'E1', 'E2'); p.sub('E1', 'E1', 'W')
    p.add('RH', 'R', 'E1'); p.sub('T0', 'RH', 'R'); p.sub('RL', 'E1', 'T0')
    p.ret()

    # ---- the kernels: (SH, SL) = sin(r), (CH, CL) = cos(r), r = (RH, RL)
    # sin r = r (1 + z (S1 + z (S2 + z (S3 + z Q(z))))), cos r = 1 + z (C1 + z
    # (C2 + z (C3 + z P(z)))), z = r^2; the first three coefficients in
    # double-double (exact Taylor), the rest in double -- the doubles' error
    # is under 2^-64 of the result on |r| <= pi/4.
    S = [(-1, 6), (1, 120), (-1, 5040), (1, 362880), (-1, 39916800), (1, 6227020800),
         (-1, 1307674368000), (1, 355687428096000), (-1, 121645100408832000)]
    C = [(-1, 2), (1, 24), (-1, 720), (1, 40320), (-1, 3628800), (1, 479001600),
         (-1, 87178291200), (1, 20922789888000), (-1, 6402373705728000), (1, 2432902008176640000)]

    def ddconst(name, num, den, low=True):
        from fractions import Fraction
        f = Fraction(num, den)
        hi = float(f)
        lo = float(f - Fraction(hi))
        p.const(name + 'H', hi)
        if low:
            p.const(name + 'L', lo)

    for i, (n, d) in enumerate(S):
        ddconst('S%d' % i, n, d, i < 3)
    for i, (n, d) in enumerate(C):
        ddconst('C%d' % i, n, d, i < 3)

    def horner(prefix, coefs, ndd, out_h, out_l, zero_order_one):
        """(out_h, out_l) = 1 + z*(c0 + z*(c1 + ...)) with z in (ZH, ZL);
        the innermost len(coefs) - ndd terms in double on ZH."""
        nd = len(coefs)
        # double part
        p.mov('U', '%s%dH' % (prefix, nd - 1))
        for i in range(nd - 2, ndd - 1, -1):
            p.mul('U', 'U', 'ZH'); p.add('U', 'U', '%s%dH' % (prefix, i))
        p.mov('UL', 'ZERO')
        # double-double part
        for i in range(ndd - 1, -1, -1):
            p.mov('AH', 'ZH'); p.mov('AL', 'ZL'); p.mov('BH', 'U'); p.mov('BL', 'UL')
            p.call('DDMUL')
            p.mov('AH', 'DH'); p.mov('AL', 'DL')
            p.mov('BH', '%s%dH' % (prefix, i)); p.mov('BL', '%s%dL' % (prefix, i))
            p.call('DDADD')
            p.mov('U', 'DH'); p.mov('UL', 'DL')
        # 1 + z * U
        p.mov('AH', 'ZH'); p.mov('AL', 'ZL'); p.mov('BH', 'U'); p.mov('BL', 'UL')
        p.call('DDMUL')
        p.mov('AH', 'DH'); p.mov('AL', 'DL'); p.mov('BH', 'ONE'); p.mov('BL', 'ZERO')
        p.call('DDADD')
        p.mov(out_h, 'DH'); p.mov(out_l, 'DL')

    # the kernels are subroutines (the return stack is four deep)
    p.label('KZSQ')          # (ZH, ZL) = r^2
    p.mov('AH', 'RH'); p.mov('AL', 'RL'); p.mov('BH', 'RH'); p.mov('BL', 'RL')
    p.call('DDMUL')
    p.mov('ZH', 'DH'); p.mov('ZL', 'DL')
    p.ret()
    p.label('KSIN')          # (SH, SL) = sin(RH, RL), z in (ZH, ZL)
    horner('S', S, 3, 'KH', 'KL', True)
    p.mov('AH', 'KH'); p.mov('AL', 'KL'); p.mov('BH', 'RH'); p.mov('BL', 'RL')
    p.call('DDMUL')
    p.mov('SH', 'DH'); p.mov('SL', 'DL')
    p.ret()
    p.label('KCOS')          # (CH, CL) = cos(RH, RL)
    horner('C', C, 3, 'CH', 'CL', True)
    p.ret()

    def z_square(): p.call('KZSQ')
    def ksin(): p.call('KSIN')
    def kcos(): p.call('KCOS')

    # sin x: n 0 s, 1 c, 2 -s, 3 -c
    p.label('SIN')
    p.ldx('X')
    p.br('NAN', 'X', 'NANX'); p.br('INF', 'X', 'INFX'); p.br('ZERO', 'X', 'ZEROX')
    p.call('REDUCE'); z_square()
    p.br('BIT0', 'QN', 'SIN_C')
    ksin(); p.mov('Y', 'SH'); p.jmp('SIN_S')
    p.label('SIN_C')
    kcos(); p.mov('Y', 'CH')
    p.label('SIN_S')
    p.br('BIT1', 'QN', 'NEGOUT')
    p.end('Y')

    # cos x: n 0 c, 1 -s, 2 -c, 3 s
    p.label('COS')
    p.ldx('X')
    p.br('NAN', 'X', 'NANX'); p.br('INF', 'X', 'INFX')
    p.call('REDUCE'); z_square()
    p.br('BIT0', 'QN', 'COS_S')
    kcos(); p.mov('Y', 'CH')
    p.br('BIT1', 'QN', 'NEGOUT')
    p.end('Y')
    p.label('COS_S')
    ksin(); p.mov('Y', 'SH')
    p.br('BIT1', 'QN', 'COS_SP')
    p.jmp('NEGOUT')
    p.label('COS_SP')
    p.end('Y')

    # tan x: n even s / c, odd -c / s
    p.label('TAN')
    p.ldx('X')
    p.br('NAN', 'X', 'NANX'); p.br('INF', 'X', 'INFX'); p.br('ZERO', 'X', 'ZEROX')
    p.call('REDUCE'); z_square()
    ksin(); kcos()
    p.br('BIT0', 'QN', 'TAN_O')
    p.mov('AH', 'SH'); p.mov('AL', 'SL'); p.mov('BH', 'CH'); p.mov('BL', 'CL')
    p.call('DDDIV'); p.end('DH')
    p.label('TAN_O')
    p.mov('AH', 'CH'); p.mov('AL', 'CL'); p.mov('BH', 'SH'); p.mov('BL', 'SL')
    p.call('DDDIV'); p.mov('Y', 'DH'); p.jmp('NEGOUT')

    p.label('NEGOUT')
    p.mov('Y', '-Y')            # the sign flipped: exact, and -0 for +0
    p.end('Y')
    p.label('ZEROX')
    p.end('X')                  # sin / tan of +-0 is +-0
    p.label('NANX')
    p.add('Y', 'X', 'X'); p.end('Y')
    p.label('INFX')
    p.sub('Y', 'X', 'X'); p.end('Y')     # inf - inf: NaN

    # ---- atan2(y, x) = atanrl src2, src1: Y from src2, X from src1
    # t = min(|x|,|y|) / max(...) in double-double; atan(t) on [0, 1] by
    # fdlibm's breakpoints (7/16, 11/16) and constants atan(1/2), atan(1)
    # in double-double; then pi/2 - a if swapped, pi - a if x < 0, -a if y < 0.
    ddconst_val = {}
    from fractions import Fraction

    def ddconst_f(name, v_hi, v_lo):
        p.const(name + 'H', v_hi); p.const(name + 'L', v_lo)
    ddconst_f('ATQ', 0.24497866312686414, 1.0698755618734451e-17)              # atan(1/4)
    ddconst_f('ATH', 4.63647609000806093515e-01, 2.26987774529616870924e-17)   # atan(1/2)
    ddconst_f('AT1', 7.85398163397448278999e-01, 3.06161699786838301793e-17)   # atan(1)
    ddconst_f('PIO2', 1.57079632679489655800e+00, 6.12323399573676603587e-17)
    ddconst_f('PI', 3.14159265358979311600e+00, 1.22464679914735320717e-16)
    p.const('BIG', 2.0 ** 900); p.const('SMALL', 2.0 ** -900)
    p.const('DOWN', 2.0 ** -200); p.const('UP', 2.0 ** 200); p.const('MID', 2.0 ** 700)
    p.const('B1_5', 0.2); p.const('B7_16', 0.4375); p.const('B11_16', 0.6875)
    p.const('TWO', 2.0); p.const('FOUR', 4.0)
    # atan t = t (1 + z (A0 + z (A1 + ...))), A_i = (-1)^(i+1) / (2i + 3)
    # |t'| <= 0.2 in every branch: z <= 0.04, 14 terms reach 2^-66
    A = [(-1 if i % 2 == 0 else 1, 2 * i + 3) for i in range(14)]
    for i, (n, d) in enumerate(A):
        ddconst('A%d' % i, n, d, i < 4)

    p.label('ATAN')
    p.ldx('X'); p.ldy('YY')
    p.br('NAN', 'X', 'ATNAN'); p.br('NAN', 'YY', 'ATNAN')
    p.mov('AX', '|X'); p.mov('AY', '|YY')
    p.mov('SW', 'ZERO')
    p.sub('T0', 'AX', 'AY')
    p.br('NEG', 'T0', 'AT_SW')
    p.mov('NU', 'AY'); p.mov('DE', 'AX'); p.jmp('AT_Q')
    p.label('AT_SW')
    p.mov('NU', 'AX'); p.mov('DE', 'AY'); p.mov('SW', 'ONE')
    p.label('AT_Q')
    # t = NU / DE in double-double (0/0 cannot happen unless both zero:
    # then t = 0 and the signs alone decide, as atan2 does)
    p.br('INF', 'NU', 'AT_INF')               # both infinite
    p.br('INF', 'DE', 'AT_Z')                 # t = finite / inf = 0
    p.br('ZERO', 'DE', 'AT_Z')                # both zero: t = 0, the signs decide
    p.br('ZERO', 'NU', 'AT_Z')                # t = 0 exactly
    # Dekker's split overflows above ~2^996 and its error terms flush below
    # ~2^-969: bring the pair into range by a power of two (the ratio is
    # unchanged; a numerator that underflows has a flushed result anyway)
    p.sub('T0', 'DE', 'BIG')
    p.br('NEG', 'T0', 'AT_SM')
    p.mul('NU', 'NU', 'DOWN'); p.mul('DE', 'DE', 'DOWN')
    p.label('AT_SM')                          # NU <= DE: raise NU above 2^-900
    p.sub('T0', 'NU', 'SMALL')
    p.br('NEG', 'T0', 'AT_UP')
    p.jmp('AT_DV')
    p.label('AT_UP')
    p.sub('T0', 'DE', 'MID')
    p.br('NEG', 'T0', 'AT_UP2')
    p.jmp('AT_Z')                             # NU / DE < 2^-1600: the result flushes
    p.label('AT_UP2')
    p.mul('NU', 'NU', 'UP'); p.mul('DE', 'DE', 'UP')
    p.jmp('AT_SM')
    p.label('AT_DV')
    p.mov('AH', 'NU'); p.mov('AL', 'ZERO'); p.mov('BH', 'DE'); p.mov('BL', 'ZERO')
    p.call('DDDIV'); p.mov('TH', 'DH'); p.mov('TL', 'DL')
    p.jmp('AT_R')
    p.label('AT_Z')
    p.mov('TH', 'ZERO'); p.mov('TL', 'ZERO')
    p.label('AT_R')
    # breakpoints
    p.mov('OH', 'ZERO'); p.mov('OL', 'ZERO')
    p.sub('T0', 'TH', 'B1_5'); p.br('NEG', 'T0', 'AT_P')
    p.sub('T0', 'TH', 'B7_16'); p.br('NEG', 'T0', 'AT_4')
    p.sub('T0', 'TH', 'B11_16'); p.br('NEG', 'T0', 'AT_H')
    # t' = (c t - 1) / (c + t) with c = 1, 2, 4 for atan(1), atan(1/2), atan(1/4)
    p.mov('FAC', 'ONE'); p.call('ATRED')
    p.mov('OH', 'AT1H'); p.mov('OL', 'AT1L')
    p.jmp('AT_P')
    p.label('AT_H')
    p.mov('FAC', 'TWO'); p.call('ATRED')
    p.mov('OH', 'ATHH'); p.mov('OL', 'ATHL')
    p.jmp('AT_P')
    p.label('AT_4')
    p.mov('FAC', 'FOUR'); p.call('ATRED')
    p.mov('OH', 'ATQH'); p.mov('OL', 'ATQL')
    p.label('AT_P')
    # z = t'^2; poly; a = t' * (1 + z P) + offset
    p.mov('AH', 'TH'); p.mov('AL', 'TL'); p.mov('BH', 'TH'); p.mov('BL', 'TL')
    p.call('DDMUL'); p.mov('ZH', 'DH'); p.mov('ZL', 'DL')
    horner('A', A, 4, 'KH', 'KL', True)
    p.mov('AH', 'KH'); p.mov('AL', 'KL'); p.mov('BH', 'TH'); p.mov('BL', 'TL')
    p.call('DDMUL')
    p.mov('AH', 'DH'); p.mov('AL', 'DL'); p.mov('BH', 'OH'); p.mov('BL', 'OL')
    p.call('DDADD'); p.mov('RH', 'DH'); p.mov('RL', 'DL')
    p.label('AT_F')
    # swapped: pi/2 - a
    p.br('ZERO', 'SW', 'AT_X')
    p.mov('AH', 'PIO2H'); p.mov('AL', 'PIO2L'); p.mov('BH', '-RH'); p.mov('BL', '-RL')
    p.call('DDADD'); p.mov('RH', 'DH'); p.mov('RL', 'DL')
    p.label('AT_X')
    # x < 0 (sign bit, so -0 counts): pi - a
    p.br('NEG', 'X', 'AT_XN')
    p.jmp('AT_Y')
    p.label('AT_XN')
    p.mov('AH', 'PIH'); p.mov('AL', 'PIL'); p.mov('BH', '-RH'); p.mov('BL', '-RL')
    p.call('DDADD'); p.mov('RH', 'DH'); p.mov('RL', 'DL')
    p.label('AT_Y')
    p.br('NEG', 'YY', 'AT_YN')
    p.end('RH')
    p.label('AT_YN')
    p.mov('Y', '-RH'); p.end('Y')
    p.label('AT_INF')
    # both infinite: pi/4 (then pi - , -) per C99; the swap cannot change it
    p.mov('RH', 'AT1H'); p.mov('RL', 'AT1L')
    p.jmp('AT_F')
    p.label('ATRED')          # (TH, TL) = (FAC t - 1) / (FAC + t); FAC a power of two
    p.mul('T0', 'TH', 'FAC'); p.mul('T1', 'TL', 'FAC')
    p.mov('AH', 'T0'); p.mov('AL', 'T1'); p.mov('BH', '-ONE'); p.mov('BL', 'ZERO')
    p.call('DDADD'); p.mov('NH', 'DH'); p.mov('NL', 'DL')
    p.mov('AH', 'TH'); p.mov('AL', 'TL'); p.mov('BH', 'FAC'); p.mov('BL', 'ZERO')
    p.call('DDADD')
    p.mov('BH', 'DH'); p.mov('BL', 'DL'); p.mov('AH', 'NH'); p.mov('AL', 'NL')
    p.call('DDDIV'); p.mov('TH', 'DH'); p.mov('TL', 'DL')
    p.ret()
    p.label('ATNAN')
    p.add('Y', 'X', 'YY'); p.end('Y')
    return p


# --------------------------------------------------------------- assembler
def assemble(p):
    names = list(p.consts) + [t for t in p.temps if t not in p.consts]
    assert len(names) <= NREG, len(names)
    addr = {n: i for i, n in enumerate(names)}
    words = []
    for op, f in p.code:
        w = OPS[op] << 28
        if op in ('ADD', 'SUB', 'MUL', 'DIV', 'END', 'LDX', 'LDY'):
            d = f.get('d', 'SINK')
            if op == 'END':
                d = 'ZERO'      # never written: END only reads
            else:
                assert d not in p.consts, 'writes a constant: %s' % d
            ma, a = split_mod(f.get('a', 'ZERO'))
            mb, b = split_mod(f.get('b', 'ZERO'))
            w |= addr[d] << 21 | addr[a] << 14 | addr[b] << 7 | ma << 5 | mb << 3
        elif op == 'BR':
            ma, a = split_mod(f['a'])
            assert ma == 0
            w |= CONDS[f['cond']] << 25 | (1 if f['inv'] else 0) << 24 | addr[a] << 14 | p.labels[f['t']]
        elif op in ('JMP', 'CALL'):
            w |= p.labels[f['t']]
        words.append(w)
    return words, addr, names


# --------------------------------------------------------------- interpreter
maxdepth = [0]


def run(p, words, addr, names, entry, x, y=0.0, trace=None):
    R = [0.0] * NREG
    for n, v in p.consts.items():
        R[addr[n]] = v
    pc = p.entries[entry]
    ras = []
    steps = 0
    nops = 0
    while True:
        w = words[pc]
        steps += 1
        assert steps < 20000
        op = w >> 28
        pc1 = pc + 1
        if op in (0, 1, 2, 3, 8, 9, 10):
            d, a, b = (w >> 21) & 127, (w >> 14) & 127, (w >> 7) & 127
            ma, mb = (w >> 5) & 3, (w >> 3) & 3
            va = x if op == 8 else y if op == 9 else R[a]
            vb = 0.0 if op in (8, 9) else R[b]
            va = modv(va, ma) if op not in (8, 9) else va
            vb = modv(vb, mb) if op not in (8, 9) else vb
            nm = ['ADD', 'SUB', 'MUL', 'DIV'][op] if op < 4 else 'SUB'
            r = fop(nm, va, vb)
            nops += 1
            if op == 10:
                return r, nops
            R[d] = r
        elif op == 4:
            cond, inv, a, t = (w >> 25) & 7, (w >> 24) & 1, (w >> 14) & 127, w & 0x3ff
            u = d2u(R[a])
            c = [u >> 63, (u & ((1 << 63) - 1)) == 0,
                 ((u >> 52) & 0x7ff) == 0x7ff and (u & ((1 << 52) - 1)) != 0,
                 ((u >> 52) & 0x7ff) == 0x7ff and (u & ((1 << 52) - 1)) == 0,
                 u & 1, (u >> 1) & 1][cond]
            if bool(c) != bool(inv):
                pc1 = t
        elif op == 5:
            pc1 = w & 0x3ff
        elif op == 6:
            ras.append(pc + 1); pc1 = w & 0x3ff
            assert len(ras) <= 4, 'return stack overflow'
            maxdepth[0] = max(maxdepth[0], len(ras))
        elif op == 7:
            pc1 = ras.pop()
        pc = pc1


def modv(v, m):
    u = d2u(v)
    if m == 1: u ^= 1 << 63
    elif m == 2: u &= ~(1 << 63)
    elif m == 3: u |= 1 << 63
    return u2d(u)


ENTRY_ORDER = ['sin', 'cos', 'tan', 'atan']


def rom_svh(p, words, addr, names, path):
    with open(path, 'w') as f:
        f.write('// SPDX-License-Identifier: GPL-3.0-or-later\n')
        f.write('// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1\n')
        f.write('// GENERATED by tools/i960_fptrans.py -- do not edit. R845.\n')
        f.write('// %d microinstructions, %d registers (%d constants).\n' % (len(words), len(names), len(p.consts)))
        f.write('// Entries: %s\n' % ', '.join('%s %d' % (e, p.entries[e]) for e in ENTRY_ORDER))
        f.write('function automatic logic [31:0] ucode(input logic [8:0] a);\n  case (a)\n')
        for i, w in enumerate(words):
            f.write("    9'd%d: ucode = 32'h%08x;\n" % (i, w))
        f.write("    default: ucode = 32'h%08x;\n  endcase\nendfunction\n" % (OPS['END'] << 28))
        f.write('function automatic logic [63:0] uconst(input logic [6:0] a);\n  case (a)\n')
        for n, v in p.consts.items():
            f.write("    7'd%d: uconst = 64'h%016x;   // %s %r\n" % (addr[n], d2u(v), n, v))
        f.write("    default: uconst = 64'h0;\n  endcase\nendfunction\n")


def main():
    p = build()
    words, addr, names = assemble(p)
    assert len(words) <= 512, len(words)
    a = sys.argv[1:]
    if '--rom' in a:
        rom_svh(p, words, addr, names, a[a.index('--rom') + 1])
        print('%d words, %d registers (%d constants)' % (len(words), len(names), len(p.consts)))
    if '--listing' in a:
        inv = {v: k for k, v in p.labels.items()}
        for i, (op, f) in enumerate(p.code):
            print('%3d %-8s %-5s %s' % (i, inv.get(i, ''), op, f))
    if '--check' in a:
        check(p, words, addr, names, int(a[a.index('--check') + 1]))
    if '--vec' in a:
        vectors(p, words, addr, names, a[a.index('--vec') + 1], int(a[a.index('--vec') + 2]))


def vectors(p, words, addr, names, path, n):
    """Test vectors for the RTL bench: entry, x, y, expected (hex)."""
    random.seed(7)
    with open(path, 'w') as f:
        for i in range(n):
            e = ENTRY_ORDER[i % 4]
            k = random.random()
            if e == 'atan':
                x = random.uniform(-40, 40) if k < 0.7 else random.choice([0.0, -0.0, 1.0, -3.0, math.inf]) \
                    if k < 0.8 else random.uniform(-1, 1) * 2.0 ** random.randint(-1000, 1000)
                y = random.uniform(-40, 40) if k < 0.7 else random.choice([0.0, -0.0, 2.0]) \
                    if k < 0.75 else random.uniform(-1, 1) * 2.0 ** random.randint(-1000, 1000)
            else:
                x = random.uniform(-4, 4) if k < 0.7 else random.uniform(-1e4, 1e4) if k < 0.95 \
                    else random.choice([0.0, -0.0, 1e-300, math.pi, -math.pi / 2])
                y = 0.0
            r, _ = run(p, words, addr, names, e, x, y)
            f.write('%d %016x %016x %016x\n' % (ENTRY_ORDER.index(e), d2u(x), d2u(y), d2u(r)))


def check(p, words, addr, names, n):
    import mpmath
    mpmath.mp.prec = 200
    random.seed(3)
    for e, ref, mref, gen in [
            ('sin', math.sin, mpmath.sin, lambda: (random.uniform(-4, 4), 0.0)),
            ('cos', math.cos, mpmath.cos, lambda: (random.uniform(-4, 4), 0.0)),
            ('tan', math.tan, mpmath.tan, lambda: (random.uniform(-1.56, 1.56), 0.0)),
            ('sin', math.sin, mpmath.sin, lambda: (random.uniform(-3e4, 3e4), 0.0)),
            ('atan', math.atan2, mpmath.atan2, lambda: (random.uniform(-40, 40), random.uniform(-40, 40))),
            ('atan', math.atan2, mpmath.atan2, lambda: (random.uniform(-1, 1) * 2.0 ** random.randint(-1000, 1000),
                                                       random.uniform(-1, 1) * 2.0 ** random.randint(-1000, 1000)))]:
        notcr = nolibm = libmcr = 0
        maxops = 0
        for _ in range(n):
            x, y = gen()
            r, nops = run(p, words, addr, names, e, x, y)
            maxops = max(maxops, nops)
            if e == 'atan':
                h, c = math.atan2(y, x), float(mpmath.atan2(mpmath.mpf(y), mpmath.mpf(x)))
            else:
                h, c = ref(x), float(mref(mpmath.mpf(x)))
            notcr += r != c
            nolibm += r != h
            libmcr += h != c
        print('%-4s  not correctly rounded %d / %d   differs from host libm %d   (libm itself not CR %d)  max ops %d'
              % (e, notcr, n, nolibm, libmcr, maxops))


if __name__ == '__main__':
    main()
