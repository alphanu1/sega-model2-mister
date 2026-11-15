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
#   m2b_randprog.py <seed> <out events.bin> [words]
import random, struct, sys

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

    while len(prog) < nwords:
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
                u = g.choice([g.randrange(16), g.randrange(16), 0x10 + i])    # R, or the I it modifies
            emit((0b010 << 45) | (post << 44) | (i << 41) | (m << 38) | (cond() << 33) | (0 << 32) |
                 (d << 31) | (u << 23) | comp())
            if not d and u == 0x10 + i:                    # the loaded I is data: back into block 1
                emit((0x0f << 40) | ((0x10 + i) << 32) | (0x30100 + 0x100 * i))
        elif r < 0.55:                                     # compute, ureg <-> ureg
            src = g.choice([g.randrange(16), 0x10 + g.randrange(8), 0x20 + g.randrange(8), 0x28 + g.randrange(8),
                            0x7c, 0x67, 0x64])
            dst = g.choice([g.randrange(16), g.randrange(16), g.randrange(16), 0x7c])
            emit((0b0111 << 44) | (src << 36) | (cond() << 31) | (dst << 23) | comp())
        elif r < 0.63:                                     # immediate -> ureg
            u = g.choice([g.randrange(16)] * 4 + [0x20 + g.randrange(8), 0x7b])
            v = fval() if u < 16 else (g.randrange(-2, 3) & 0xffffffff) if u < 0x30 else \
                g.choice([0x18000, 0x10000, 0x12000, 0x1a000])
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
            emit((0x07 << 40) | (cond() << 33) | (j << 26) | k)
            for _ in range(k - 1):
                emit((0x02 << 39) | (0x1f << 33) | comp(False))
        elif r < 0.90:
            emit(0)                                        # NOP
        else:                                              # the I registers back into block 1
            k = g.randrange(8)
            emit((0x0f << 40) | ((0x10 + k) << 32) | (0x30100 + 0x100 * k + g.randrange(64)))
    emit((0x06 << 40) | (0x1f << 33) | base)               # JUMP back to the start
    for k, w in enumerate(prog):
        pm[base + k] = w & 0xffffffffffff
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
