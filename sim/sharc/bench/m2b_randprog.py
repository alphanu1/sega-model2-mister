#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- R1027: random SHARC programs for the lockstep against
# Hornet's v1. Writes an events.bin in mame_m2b_capture.patch's format (the host's IOP set-up,
# the 16-bit upload, the boot) that tb_m2b_sharc +lock +noidle runs. Only the forms and compute
# operations the first cut does, in combinations Dead or Alive never makes: conditional loops
# longer than two words (MAME's ASTAT three words back), counted loops, a load to the register a
# float result goes to, a load or a move to the I register the same word post-modifies, ureg
# writes to ASTAT in a word with a float compute, MODE1 TRUNC / ALUSAT changes, delayed jumps,
# every condition. No FIFO traffic. Generated, not ROM-derived.
#   m2b_randprog.py <seed> <out events.bin> [words] [flat]   (flat: R1027's set, no nesting / calls)
# M2B_RP_SEQ=1 (R1029): also ureg writes to the sequencer -- LCNTR = any value, CURLCNTR = 1-3,
# PCSTK = PCSTK -- which the core applies the clock after X; without it the programs are R1028's.
import os, random, struct, sys

SEQ = os.environ.get('M2B_RP_SEQ') == '1'
# M2B_RP_SKLR0=1 (R1039): the ureg moves' CURLCNTR / LCNTR sources and STKY's bit operations go to
# ASTAT instead (the same random draws otherwise), for the 2B build's core (m2b_sharc SKLR 0, which flags those reads)
SKLR0 = os.environ.get('M2B_RP_SKLR0') == '1'
# M2B_RP_PM=1 (R1042): also PM-bus data (every form with a g bit, DAG2's I8-15 / M8-15, block 0's
# words at 0x21d00-0x21eff past the program and block 1's at the DM pointers' own addresses) and
# type-1 words (compute with a DM and a PM move): the two loads to one register, a load to a
# compute result's register, a store of a register the other move loads, and the two moves at one
# word of block 1 (I12-15 = I0-3 copied first) in all four read / write mixes. Without it the
# programs are R1029's, byte for byte.
PM = os.environ.get('M2B_RP_PM') == '1'
# M2B_RP_CURL=1 (R1044): a counted loop's body also writes CURLCNTR (1-3, an immediate -> ureg, so
# the core applies it the clock after X) and its words test condition 0x0f (CURLCNTR != 1), so a loop end and an IF
# LCE meet a CURLCNTR just written. Without it the programs are R1042's, byte for byte.
CURL = os.environ.get('M2B_RP_CURL') == '1'
PM0 = 0x21d00                                         # block 0's data words (past the program)

FIXED = [0x01, 0x05, 0x25, 0x29, 0x02, 0x06, 0x26, 0x2a, 0x0a, 0x21, 0x22, 0x30,
         0x40, 0x41, 0x42, 0x43, 0x61, 0x62, 0x63]
FLOAT = [0x81, 0x82, 0x91, 0x92, 0x89, 0x8a, 0xa1, 0xa2, 0xb0, 0xbd, 0xc1, 0xc4, 0xc5,
         0xc9, 0xca, 0xd9, 0xda, 0xe0, 0xe1, 0xe2, 0xe3]
SHIFT = [0x00, 0x08, 0x01, 0x02, 0x10, 0x11, 0x12, 0x13, 0x19, 0x30, 0x31, 0x32, 0x33]
CONDS_ASTAT = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x0d,
               0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x1d]


def main():
    seed = int(sys.argv[1]); out = sys.argv[2]
    nwords = int(sys.argv[3]) if len(sys.argv) > 3 else 6000
    g = random.Random(seed)
    pm = {}
    base = 0x20080
    prog = []

    def cond():
        r = g.random()
        if r < 0.6: return 0x1f
        if r < 0.9: return g.choice(CONDS_ASTAT)
        return g.choice([0x09, 0x0a, 0x19, 0x1a, 0x0e, 0x1e, 0x0f])

    def rreg(): return g.randrange(16)

    def comp(allow_none=True):
        r = g.random()
        if allow_none and r < 0.15: return 0
        if r < 0.35:
            op = g.choice(FIXED); return (0 << 20) | (op << 12) | (rreg() << 8) | (rreg() << 4) | rreg()
        if r < 0.6:
            op = g.choice(FLOAT); return (0 << 20) | (op << 12) | (rreg() << 8) | (rreg() << 4) | rreg()
        if r < 0.7:
            return (1 << 20) | (0x30 << 12) | (rreg() << 8) | (rreg() << 4) | rreg()          # FMUL
        if r < 0.8:
            sop = g.choice(SHIFT); return (2 << 20) | ((sop << 2) << 12) | (rreg() << 8) | (rreg() << 4) | rreg()
        mop = 0x18 + g.randrange(8)                                                       # multifunction
        return (1 << 22) | (mop << 16) | (rreg() << 12) | (rreg() << 8) | g.randrange(256)

    def fval():
        r = g.random()
        if r < 0.5:   # a float of moderate exponent, often with low mantissa bits clear (ties)
            e = g.randrange(100, 160); m = g.getrandbits(23)
            if g.random() < 0.3: m &= ~0xfff
            return (g.getrandbits(1) << 31) | (e << 23) | m
        if r < 0.6: return g.choice([0, 0x80000000, 0x7f800000, 0x00400000, 0x00800000, 0x7f7fffff, 0x3f800000])
        if r < 0.8: return g.randrange(-64, 64) & 0xffffffff
        return g.getrandbits(32)

    def emit(w): prog.append(w)

    def pm_anchor(k):                                  # R1042: I8-11 in block 0's data, I12-15 at I0-3's
        return (PM0 + 0x40 * k + g.randrange(16)) if k < 4 else (0x30100 + 0x100 * (k - 4) + g.randrange(64))

    # the set-up: MODE1 with RND32 (and TRUNC), MODE2 as the games, the I registers into block 1
    emit((0x0f << 40) | (0x7b << 32) | 0x18000)
    emit((0x0f << 40) | (0x7a << 32) | 0x60000)
    for k in range(8):
        emit((0x0f << 40) | ((0x10 + k) << 32) | (0x30100 + 0x100 * k))
        emit((0x0f << 40) | ((0x20 + k) << 32) | (g.randrange(-2, 3) & 0xffffffff))
    for k in range(8):
        emit((0x0f << 40) | ((0x28 + k) << 32) | (g.randrange(-3, 4) & 0xffffff))   # M8-15, 24 bits
    for k in range(16):
        emit((0x0f << 40) | (k << 32) | fval())
    if PM:                                             # I8-11 into block 0's data, I12-15 onto I0-3's
        for k in range(8):
            emit((0x0f << 40) | ((0x18 + k) << 32) | pm_anchor(k))

    def pm_word():
        # R1042: one PM-bus or type-1 word (and the I / M fix-ups after a load into them)
        r = g.random()
        if r < 0.55:                                   # type 1
            dmd = g.getrandbits(1); pmd = g.getrandbits(1)
            dmi = g.randrange(8); dmm = g.randrange(8); pmi = g.randrange(8); pmm = g.randrange(8)
            dr = rreg(); pr = dr if g.random() < 0.3 else rreg()
            c = comp()
            if c and g.random() < 0.4:                 # a load to the compute's result register
                tgt = pr if (not pmd and g.getrandbits(1)) else dr
                c = (c & ~(15 << 8)) | (tgt << 8) if g.getrandbits(1) or not (c >> 22) else (c & ~(15 << 12)) | (tgt << 12)
            if pmi >= 4 and g.random() < 0.5:          # both moves at one word: I(8+pmi) = I(pmi-4)... = I(dmi)
                dmi = pmi - 4
                emit((0b0111 << 44) | ((0x10 + dmi) << 36) | (0x1f << 31) | ((0x18 + pmi) << 23))
            emit((0b001 << 45) | (dmd << 44) | (dmi << 41) | (dmm << 38) | (pmd << 37) | (dr << 33) |
                 (pmi << 30) | (pmm << 27) | (pr << 23) | c)
            return
        i = g.randrange(8); m = g.randrange(8); d = g.getrandbits(1)
        f = g.randrange(6)
        if f == 0:                                     # compute, ureg <-> PM, pre / post modify
            post = g.getrandbits(1)
            if d: u = g.choice([g.randrange(16), 0x18 + g.randrange(8), 0x28 + g.randrange(8), 0x7c])
            else: u = g.choice([g.randrange(16), g.randrange(16), 0x18 + i, 0x18 + g.randrange(8), 0x28 + g.randrange(8)])
            emit((0b010 << 45) | (post << 44) | (i << 41) | (m << 38) | (cond() << 33) | (1 << 32) |
                 (d << 31) | (u << 23) | comp())
        elif f == 1:                                   # compute, dreg <-> PM, immediate modify
            u = rreg()
            emit((0b0110 << 44) | (i << 41) | (1 << 40) | (d << 39) | (g.getrandbits(1) << 38) | (cond() << 33) |
                 ((g.randrange(-3, 4) & 0x3f) << 27) | (u << 23) | comp())
        elif f == 2:                                   # immediate shift, dreg <-> PM
            sop = g.choice(SHIFT); data = g.randrange(-40, 40) & 0xfff if sop < 0x10 else g.getrandbits(12)
            u = rreg()
            emit((0b1000 << 44) | (i << 41) | (m << 38) | (cond() << 33) | (1 << 32) | (d << 31) | (u << 23) |
                 (((data >> 8) & 15) << 27) | (sop << 16) | ((data & 0xff) << 8) | (rreg() << 4) | rreg())
        elif f == 3:                                   # ureg <-> PM, direct
            a = g.choice([PM0 + g.randrange(0x200), 0x30100 + g.randrange(0x800)])
            u = g.choice([g.randrange(16), g.randrange(16), 0x18 + g.randrange(8), 0x7c]) if d else \
                g.choice([g.randrange(16), g.randrange(16), 0x28 + g.randrange(8)])
            emit((0b000100 << 42) | (1 << 41) | (d << 40) | (u << 32) | a)
        elif f == 4:                                   # ureg <-> PM, indirect (I + offset)
            u = g.choice([g.randrange(16), g.randrange(16), 0x7c]) if d else g.randrange(16)
            emit((0b101 << 45) | (1 << 44) | (i << 41) | (d << 40) | (u << 32) | (g.randrange(-8, 9) & 0xffffffff))
        else:                                          # immediate data -> PM(I, M)
            emit((0b1001 << 44) | (i << 41) | (m << 38) | (1 << 37) | fval())
            u = 0
        if f in (0, 3) and not d and 0x18 <= u < 0x20:  # a loaded I8-15 is data: back to its place
            emit((0x0f << 40) | (u << 32) | pm_anchor(u - 0x18))
        if f in (0, 3) and not d and 0x28 <= u < 0x30:
            emit((0x0f << 40) | (u << 32) | (g.randrange(-3, 4) & 0xffffff))

    nest = len(sys.argv) <= 4 or sys.argv[4] != 'flat'
    subs = []                                          # (index in prog of the CALL word, sub number)
    NSUB = 4

    def body(n):
        for _ in range(n):
            emit((0x02 << 39) | (0x1f << 33) | comp(False))

    def nested(kind):
        # R1028: nested counted loops, a loop abort (JUMP (LA)) out of a loop, a loop whose last
        # word aborts it (two pops in one word), CALLs into subroutines that call each other
        pc0 = base + len(prog)
        if kind == 0:                                  # two loops, one inside the other
            a = g.randrange(0, 3); li = g.randrange(1, 4); b = g.randrange(1, 3)
            emit((0x0c << 40) | (g.randrange(1, 4) << 24) | (a + 1 + li + b))
            body(a)
            emit((0x0c << 40) | (g.randrange(1, 4) << 24) | li)
            body(li); body(b)
        elif kind == 1:                                # a conditional JUMP (LA) out of a loop
            L = g.randrange(2, 6); at = g.randrange(1, L)    # not the last word (kind 2's)
            emit((0x0c << 40) | (g.randrange(1, 5) << 24) | L)
            for k in range(1, L + 1):
                if k == at:                            # to the word after the loop's last
                    emit((0x07 << 40) | (g.choice(CONDS_ASTAT + [0x1f]) << 33) | (1 << 38) | (L + 1 - k))
                else: body(1)
        elif kind == 2:                                # an outer loop round a loop whose last word aborts
            wrap = g.getrandbits(1)                    # (in a third loop: the second pop leaves one)
            li = g.randrange(1, 4)
            if wrap: emit((0x0c << 40) | (g.randrange(1, 3) << 24) | (li + 5))
            emit((0x0c << 40) | (g.randrange(1, 3) << 24) | (li + 2))
            emit((0x0c << 40) | (g.randrange(1, 3) << 24) | li)
            body(li - 1)
            emit((0x07 << 40) | (g.choice(CONDS_ASTAT + [0x1f]) << 33) | (1 << 38) | 1)
            body(1); body(1)
            if wrap: body(1)
        elif kind == 4:                                # a loop's last word a DO (a pop, then a push)
            lx = g.randrange(1, 3); ly = g.randrange(1, 3)
            emit((0x0c << 40) | (g.randrange(1, 3) << 24) | (1 + lx + ly + 1))
            emit((0x0c << 40) | (1 << 24) | lx)
            body(lx - 1)
            emit((0x0c << 40) | (g.randrange(1, 3) << 24) | ly)
            body(ly); body(1)
        elif kind == 5:                                # five loops deep (the stack's lower words)
            d = 5
            for k in range(d):
                emit((0x0c << 40) | (g.randrange(1, 4) << 24) | (2 * (d - k) - 1))
                if k == d - 1: body(1)
            for k in range(d):
                body(1)
        elif kind == 3:                                # a CALL (direct), delayed or not
            j = g.getrandbits(1)
            subs.append((len(prog), g.randrange(NSUB)))
            emit((0x06 << 40) | (1 << 39) | (g.choice(CONDS_ASTAT + [0x1f, 0x1f]) << 33) | (j << 26))
            if j: body(2)

    while len(prog) < nwords:
        if PM and g.random() < 0.15:
            pm_word(); continue
        r = g.random()
        pc = base + len(prog)
        if r < 0.30:                                       # compute
            emit((0x02 << 39) | (cond() << 33) | comp(False))
        elif r < 0.40:                                     # compute, dreg <-> DM, immediate modify
            i = g.randrange(8); d = g.getrandbits(1); u = g.getrandbits(1)
            mv = g.randrange(-3, 4) & 0x3f; dr = rreg()
            c = comp()
            if not d and g.random() < 0.4 and c and not (c >> 22) and ((c >> 20) & 3) == 1:
                dr = (c >> 8) & 15                         # the load wins over FMUL's result
            emit((0b0110 << 44) | (i << 41) | (0 << 40) | (d << 39) | (u << 38) | (cond() << 33) |
                 (mv << 27) | (dr << 23) | c)
        elif r < 0.48:                                     # compute, ureg <-> DM, pre / post modify
            post = g.getrandbits(1); i = g.randrange(8); m = g.randrange(8); d = g.getrandbits(1)
            if d: u = g.choice([g.randrange(16), 0x10 + g.randrange(8), 0x20 + g.randrange(8), 0x7c])
            else:
                # R, the I it modifies, another I (R1028: two I writes in one word), an M
                u = g.choice([g.randrange(16), g.randrange(16), 0x10 + i, 0x10 + g.randrange(8), 0x20 + g.randrange(8)])
            emit((0b010 << 45) | (post << 44) | (i << 41) | (m << 38) | (cond() << 33) | (0 << 32) |
                 (d << 31) | (u << 23) | comp())
            if not d and 0x10 <= u < 0x18:                 # the loaded I is data: back into block 1
                emit((0x0f << 40) | (u << 32) | (0x30100 + 0x100 * (u - 0x10)))
            if not d and 0x20 <= u < 0x28:                 # the loaded M is data: a small modifier again
                emit((0x0f << 40) | (u << 32) | (g.randrange(-2, 3) & 0xffffffff))
        elif r < 0.55:                                     # compute, ureg <-> ureg
            src = g.choice([g.randrange(16), 0x10 + g.randrange(8), 0x20 + g.randrange(8), 0x28 + g.randrange(8),
                            0x7c, 0x67, 0x64, 0x68])
            if SKLR0 and src in (0x67, 0x68): src = 0x7c
            dst = g.choice([g.randrange(16), g.randrange(16), g.randrange(16), 0x7c])
            if SEQ and g.random() < 0.3:
                src, dst = g.choice([(src, 0x68), (0x64, 0x64), (g.randrange(16), 0x68)])
            emit((0b0111 << 44) | (src << 36) | (cond() << 31) | (dst << 23) | comp())
        elif r < 0.63:                                     # immediate -> ureg
            u = g.choice([g.randrange(16)] * 4 + [0x20 + g.randrange(8), 0x7b])
            v = fval() if u < 16 else (g.randrange(-2, 3) & 0xffffffff) if u < 0x30 else \
                g.choice([0x18000, 0x10000, 0x12000, 0x1a000])
            if SEQ and g.random() < 0.3:
                u, v = g.choice([(0x68, g.getrandbits(32)), (0x67, g.randrange(1, 4))])
            emit((0x0f << 40) | (u << 32) | v)
        elif r < 0.68:                                     # immediate shift
            sop = g.choice(SHIFT); data = g.randrange(-40, 40) & 0xfff if sop < 0x10 else g.getrandbits(12)
            emit((0b000000100 << 39) | (cond() << 33) | (((data >> 8) & 15) << 27) | (sop << 16) |
                 ((data & 0xff) << 8) | (rreg() << 4) | rreg())
        elif r < 0.72:                                     # compute, modify
            emit((0b000001000 << 39) | (cond() << 33) | (0 << 38) | (g.randrange(8) << 30) |
                 (g.randrange(8) << 27) | comp())
        elif r < 0.77:                                     # a counted loop of 1-5 words
            n = g.randrange(1, 5); L = g.randrange(1, 6)
            if CURL and g.random() < 0.5:              # R1044: CURLCNTR written in the body
                ws = []
                for _ in range(L):
                    if g.random() < 0.35: ws.append((0x0f << 40) | (0x67 << 32) | g.randrange(1, 4))
                    else: ws.append((0x02 << 39) | (g.choice([0x0f, 0x0f, 0x1f]) << 33) | comp(False))   # 0x0f: IF NOT LCE (CURLCNTR != 1)
                emit((0x0c << 40) | (n << 24) | len(ws))
                for w in ws: emit(w)
                continue
            emit((0x0c << 40) | (n << 24) | L)
            for _ in range(L):
                emit((0x02 << 39) | (0x1f << 33) | comp(False))
        elif r < 0.82:                                     # a condition loop longer than two words
            L = g.randrange(3, 7)
            emit((0x0f << 40) | (15 << 32) | g.randrange(1, 4))          # R15 = 1..3
            emit((0x0e << 40) | (0x00 << 33) | L)                        # DO UNTIL EQ
            at = g.randrange(L)                                          # R15 = R15 - 1 somewhere in
            for k in range(L):                                           # the body, the rest moves
                if k == at: emit((0x02 << 39) | (0x1f << 33) | (0x2a << 12) | (15 << 8) | (15 << 4))
                else: emit((0x0f << 40) | (g.randrange(15) << 32) | fval())
        elif r < 0.87:                                     # a short forward jump, delayed or not
            k = g.randrange(3, 7); j = g.getrandbits(1)
            f = g.randrange(3)
            if f == 0: emit((0x07 << 40) | (cond() << 33) | (j << 26) | k)
            elif f == 1:                                   # R1028: the 6-bit relative form, with a compute
                emit((0x09 << 40) | (cond() << 33) | ((k & 0x3f) << 27) | (j << 26) | comp())
            else:                                          # R1028: IF cond JUMP (PC, k) ELSE compute, dreg <-> DM
                i = g.randrange(8); m = g.randrange(8); d = g.getrandbits(1)
                emit((0b11 << 46) | (1 << 45) | (d << 44) | (i << 41) | (m << 38) | (cond() << 33) |
                     ((k & 0x3f) << 27) | (rreg() << 23) | comp())
            for _ in range(k - 1):
                emit((0x02 << 39) | (0x1f << 33) | comp(False))
        elif r < 0.875:
            emit(0)                                        # NOP
        elif r < 0.88:                                     # R1028: a system register bit operation
            k = g.choice([0, 1, 2, 4, 5])
            reg, m = g.choice([(0x0, g.getrandbits(32)), (0x1, g.getrandbits(32)), (0xc, g.getrandbits(32) & 0xff87ffff),
                               (0xc, 1 << g.choice([0, 1, 2, 3, 18, 19])), (0xe, g.getrandbits(32)),
                               (0xb, g.choice([0x2000, 0x8000]))])
            if k == 5 and g.random() < 0.5: m = 0              # XOR against a register's value: equal sometimes
            if SKLR0 and reg == 0xe: reg = 0xc               # R1039: STKY's bit operations on ASTAT
            emit((0x14 << 40) | (k << 37) | (reg << 32) | m)
        elif r < 0.90 and nest:                            # R1028: the stacks (PC, loop) deeper
            nested(g.randrange(6))
        else:                                              # the I registers back into block 1
            k = g.randrange(8)
            emit((0x0f << 40) | ((0x10 + k) << 32) | (0x30100 + 0x100 * k + g.randrange(64)))
            if PM:
                k = g.randrange(8)
                emit((0x0f << 40) | ((0x18 + k) << 32) | pm_anchor(k))
    emit((0x06 << 40) | (0x1f << 33) | base)               # JUMP back to the start
    # the subroutines: a few words, a CALL to a later one (so they nest), RTS (delayed or not)
    sub_at = []
    calls = []
    for k in range(NSUB):
        sub_at.append(base + len(prog))
        body(g.randrange(1, 4))
        if k + 1 < NSUB and g.random() < 0.6:
            calls.append((len(prog), g.randrange(k + 1, NSUB)))
            emit((0x06 << 40) | (1 << 39) | (0x1f << 33))
        j = g.getrandbits(1)
        emit((0x0a << 40) | (g.choice([0x1f, 0x1f] + CONDS_ASTAT) << 33) | (j << 26) | comp())
        if j: body(2)
        emit((0x0a << 40) | (0x1f << 33))                  # an RTS that always returns
    for at, k in subs + calls:
        prog[at] |= sub_at[k]
    for k, w in enumerate(prog):
        pm[base + k] = w & 0xffffffffffff
    assert not PM or base + len(prog) < PM0 - 0x200, 'the program reaches the PM data words'
    pm[0x20005] = (0x06 << 40) | (0x1f << 33) | base       # the reset word: JUMP (base)
    top = max(pm) + 1
    ev = bytearray()

    def rec(t, a, b): ev.extend(struct.pack('<BII', ord(t), a & 0xffffffff, b & 0xffffffff))
    for reg, val in [(0x1c, 0), (0x1c, 0), (0x40, 0), (0x40, 2), (0x41, 1), (0x41, 0),
                     (0x42, (top - 0x20000) & 0xffff), (0x42, 0), (0x1c, 0xa1), (0x1c, 0)]:
        rec('H', reg, val)
    n = 0
    for a in range(0x20000, top):
        w = pm.get(a, 0)
        for k in range(3):
            rec('U', n, (w >> (16 * k)) & 0xffff); n += 1
    rec('B', n, 0)
    open(out, 'wb').write(ev)
    print('seed %d: %d program words, %d upload words' % (seed, len(prog), n))


if __name__ == '__main__':
    main()
