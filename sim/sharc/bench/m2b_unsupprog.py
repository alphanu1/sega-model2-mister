#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- R1028 / R1029: one-word programs the core must flag as unsupported
# (tb_m2b_sharc +lock +noidle prints "UNSUPPORTED word at <pc>: <op> (reason <n>)"). Each is a
# MODE1 set-up, the words given, then the unsupported word at 0x20084 and a jump back. Generated,
# not ROM-derived.
#   m2b_unsupprog.py <out dir> [--pxim0]   writes u<k>.bin and cases.txt (<file> <pc> <reason>);
#   --pxim0 adds the words only the 2B build's core (PXIM 0, R1038) flags; --sklr0 those its
#   SKLR 0 flags (R1039: STKY, CURLCNTR and LCNTR read)
import os, struct, sys

CASES = [   # (name, words before, the word, reason)
    # R1042: type 1 and PM-bus data are done; what of the PM bus is not
    ('PM-bus data past the on-chip PM (R0 = PM(0x22000))', [], (0b000100 << 42) | (1 << 41) | 0x22000, 3),
    ('PM-bus data in external PM (PM(I8, M8) = R0, I8 = 0x400000)', [0x0f1800400000, 0x0f2800000000],
     (0b010 << 45) | (1 << 44) | (1 << 32) | (1 << 31) | (0x1f << 33), 3),
    ('type 1 with its PM move outside the PM (I8 = 0x22000)', [0x0f1800022000, 0x0f1000030100], 0x200000000000, 3),
    ('PX over the PM bus (48-bit in MAME: PX = PM(0x21000))', [], (0b000100 << 42) | (1 << 41) | (0xdb << 32) | 0x21000, 9),
    ('MODE1 swap bit by a ureg write', [], 0x0f7b00018400, 5),
    ('MODE1 swap bit by a bit operation', [], 0x140b00000400, 5),
    ('SHARC-side DMA (DMAC6 DEN)', [0x0f0000000001], 0x11000000001c, 7),
    ('an unknown IOP register written', [], 0x110000000055, 7),
    ('an unknown IOP register read', [], 0x101000000055, 7),
    ('a jump outside the PM (R1029: its flag from X\'s first clock)', [], (0x06 << 40) | (0x1f << 33) | 0x30000, 9),
    # R1048: a loop end's pop leaving a stack empty for the word's own pop (the reasons D decides
    # for both outcomes of the pop): RTS as a one-pass loop's last word, the loop's PC entry
    # popped first; a loop-abort JUMP there, the loop's entry popped first
    ('RTS at a one-pass loop\'s end (the loop end empties PCSTK)', [(0x0c << 40) | (1 << 24) | 3], (0x0a << 40) | (0x1f << 33), 6),
    ('JUMP (LA) at a one-pass loop\'s end (the loop end empties the loop stack)', [(0x0c << 40) | (1 << 24) | 3],
     (0x06 << 40) | (1 << 38) | (0x1f << 33) | 0x20080, 6),
    # R1048: a circular buffer (L != 0) under a post-modify, on DAG1 and on the PM bus's DAG2 (L's
    # nonzero flag read at the form's index)
    ('a DM post-modify with L0 = 4 (R0 = DM(I0, M0))', [0x0f3000000004, 0x0f1000030100],
     (0b010 << 45) | (1 << 44) | (0x1f << 33), 4),
    ('a PM-bus post-modify with L8 = 4 (R0 = PM(I8, M8))', [0x0f3800000004, 0x0f1800020100],
     (0b010 << 45) | (1 << 44) | (0x1f << 33) | (1 << 32), 4),
    # R1048: a data address outside the map under IF LCE at a one-pass loop's end, nested in an
    # outer loop: the condition after the pop reads the outer loop's counter (l1). In the first of
    # the outer loop's two passes it holds and the access is made (flagged); in its last pass it
    # fails (NEG_CASES). I1 = 0x200000, the address I1 + 2
    ('IF LCE R1 = DM(I1, 2) at a one-pass loop\'s end in the first of an outer loop\'s two passes',
     [0x0f1100200000, (0x0c << 40) | (2 << 24) | 3, (0x0c << 40) | (1 << 24) | 1],
     (0b0110 << 44) | (1 << 41) | (0x0f << 33) | (2 << 27) | (1 << 23), 3),
    # R1052: an unsupported compute (a fixed multiply) under an LCE condition as a counted loop's
    # last word, in a pass that does not pop: the flag reads the condition at LCE's input for no
    # pop (CURLCNTR != 2's), D's le-last outcome for le = 1 without the pop. LCE: flagged in the
    # second (popping) pass; NOT LCE: in the first. The miter sees the pass it is flagged in.
    ('IF LCE (fixed multiply) as a two-pass loop\'s last word (flagged in its second pass)',
     [(0x0c << 40) | (2 << 24) | 3], (0x01 << 40) | (0x0f << 33) | (1 << 20) | (0x40 << 12), 2),
    ('IF NOT LCE (fixed multiply) as a two-pass loop\'s last word (flagged in its first pass)',
     [(0x0c << 40) | (2 << 24) | 3], (0x01 << 40) | (0x1f << 33) | (1 << 20) | (0x40 << 12), 2),
]
# R1038: unsupported only in the 2B build's core (m2b_sharc PXIM 0: no PX, no IMASK); with
# --pxim0 these are written too, and with PXIM 1 the same programs run (supported)
PXIM0_CASES = [
    ('PX1 written (immediate)', [], 0x0fdc00001234, 8),
    ('PX read by a ureg move (R0 = PX, IF TRUE)', [], 0x7dbf80000000, 8),
    ('IMASK written (immediate)', [], 0x0f7d00000003, 8),
    ('IMASK bit set', [], 0x140d00000001, 8),
]

# R1039: unsupported only with m2b_sharc SKLR 0 (no STKY / CURLCNTR / LCNTR reads); with SKLR 1
# the same programs run in lockstep with v1. The writes stay supported at SKLR 0.
SKLR0_CASES = [
    ('STKY read by a ureg move (R0 = STKY)', [], 0x77ef80000000, 8),
    ('CURLCNTR read by a ureg move (R0 = CURLCNTR)', [], 0x767f80000000, 8),
    ('LCNTR read by a ureg move (R0 = LCNTR)', [], 0x768f80000000, 8),
    ('STKY bit test', [], 0x148e00000001, 8),
    ('STKY bit set (a read-modify-write)', [], 0x140e00000001, 8),
    # R1048: an unsupported ureg in a form with an access (D's ub): the access is not made -- the
    # address external, so a store made anyway shows on the bus (ub in the kind's last gate)
    ('DM(I0, M0) = STKY, I0 = 0x1400000 external (ureg <-> DM, post-modify)', [0x0f1001400000, 0x0f2000000000],
     (0b010 << 45) | (1 << 44) | (0x1f << 33) | (1 << 31) | (0x7e << 23), 8),
    ('DM(0x1400000) = STKY (ureg <-> DM direct, external)', [], (0b000100 << 42) | (1 << 40) | (0x7e << 32) | 0x1400000, 8),
]


# R1044: words that must NOT be flagged -- a data address outside the map under a FALSE condition
# (the access is not made, so neither is the address map's test). --negcond writes them as
# n<k>.bin, listed in negcases.txt; run them +lock and expect "unsupported: none".
NEG_CASES = [
    ('IF FALSE R0 = DM(I0, M0) (pre-modify), I0 = 0x200000 outside the map',
     [0x0f1000200000, 0x0f2000000000], (0b010 << 45) | (0x0e << 33), 0),
    ('IF FALSE R1 = DM(I1, 2) (immediate modify, pre), I1 = 0x200000',
     [0x0f1100200000], (0b0110 << 44) | (1 << 41) | (0x0e << 33) | (2 << 27) | (1 << 23), 0),
    ('IF FALSE DM(I2, M2) = R2 (post-modify), I2 = 0x01e00000 outside the map',
     [0x0f1201e00000, 0x0f2200000000], (0b010 << 45) | (1 << 44) | (2 << 41) | (2 << 38) | (0x0e << 33) | (1 << 31) | (2 << 23), 0),
    ('IF LCE R1 = DM(I1, 2) at a one-pass loop\'s end in an outer loop\'s last pass (R1048: the condition after the pop fails)',
     [0x0f1100200000, (0x0c << 40) | (1 << 24) | 3, (0x0c << 40) | (1 << 24) | 1],
     (0b0110 << 44) | (1 << 41) | (0x0f << 33) | (2 << 27) | (1 << 23), 0),
]


def prog_events(pre, word):
    base = 0x20080
    prog = [(0x0f << 40) | (0x7b << 32) | 0x18000] + pre
    while len(prog) < 4: prog.append(0)
    prog += [word, 0, 0, (0x06 << 40) | (0x1f << 33) | base]
    pm = {base + k: w for k, w in enumerate(prog)}
    pm[0x20005] = (0x06 << 40) | (0x1f << 33) | base
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
    return ev


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    lines = []
    cases = CASES + (PXIM0_CASES if '--pxim0' in sys.argv[2:] else []) + (SKLR0_CASES if '--sklr0' in sys.argv[2:] else [])
    for k, (name, pre, word, why) in enumerate(c for c in cases if c[3]):
        p = os.path.join(out, 'u%d.bin' % k)
        open(p, 'wb').write(prog_events(pre, word))
        lines.append('%s 20084 %d %s' % (p, why, name))
    open(os.path.join(out, 'cases.txt'), 'w').write('\n'.join(lines) + '\n')
    if '--negcond' in sys.argv[2:]:
        neg = []
        for k, (name, pre, word, why) in enumerate(NEG_CASES):
            p = os.path.join(out, 'n%d.bin' % k)
            open(p, 'wb').write(prog_events(pre, word))
            neg.append('%s %s' % (p, name))
        open(os.path.join(out, 'negcases.txt'), 'w').write('\n'.join(neg) + '\n')
    print('%d programs' % len(lines))


if __name__ == '__main__':
    main()
