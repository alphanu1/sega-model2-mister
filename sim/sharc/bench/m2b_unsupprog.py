#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- R1028 / R1029: one-word programs the core must flag as unsupported
# (tb_m2b_sharc +lock +noidle prints "UNSUPPORTED word at <pc>: <op> (reason <n>)"). Each is a
# MODE1 set-up, the words given, then the unsupported word at 0x20084 and a jump back. Generated,
# not ROM-derived.
#   m2b_unsupprog.py <out dir> [--pxim0]   writes u<k>.bin and cases.txt (<file> <pc> <reason>);
#   --pxim0 adds the words only the 2B build's core (PXIM 0, R1038) flags; --sklr0 those its
#   SKLR 0 flags (R1039: STKY, CURLCNTR and LCNTR read)
# R1062: a data address outside the map is flagged (reason 3) for the overlay but no longer run
# as a NOP: the access completes as nothing answering (a read loads 0, a write is lost) and the
# word runs. --oomloop writes o0.bin, a loop of such accesses of every kind; --oomcheck <tb out>
# checks a run of it (+noidle +show=<n>) word by word.
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


# R1061 / R1062: a data address outside the map whose region bits, read as if it were inside,
# name a region with an effect -- a read of the output FIFO's window (0x1000000, FOUT read):
# flagged, nothing pushed (out FIFO words 0), R0 loaded with 0
MAP_CASES = [
    ('a read of the output FIFO (R0 = DM(0x1000000))', [], (0b000100 << 42) | 0x01000000, 3),
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
    # R1060: a compute field of a form the core does not do (a fixed multiply), its condition
    # false: not flagged, and on the same clock as before (D's extra clock is only for such a
    # field that runs); alone, and with a load whose address is in the map
    ('IF FALSE (fixed multiply)', [], (0x01 << 40) | (0x0e << 33) | (1 << 20) | (0x40 << 12), 0),
    ('IF FALSE R1 = DM(I1, 2) (immediate modify, pre) with a fixed multiply, I1 = 0x30000',
     [0x0f1100030000], (0b0110 << 44) | (1 << 41) | (0x0e << 33) | (2 << 27) | (1 << 23) | (1 << 20) | (0x40 << 12), 0),
    # ... and straight before a word whose compute runs (R2 = R0 + R1): nothing of the one before
    # reaches it
    ('IF FALSE (fixed multiply), then R2 = R0 + R1', [0, 0, (0x01 << 40) | (0x0e << 33) | (1 << 20) | (0x40 << 12)],
     (0x01 << 40) | (0x1f << 33) | (0x01 << 12) | (2 << 8) | 1, 0),
    # R1061: a word whose address is outside the map under a false condition, straight before a
    # load that runs inside the map (I1 + 2 = 0x30002): nothing of the one before reaches it
    ('IF FALSE R0 = DM(I0, M0), I0 = 0x200000 outside the map, then R1 = DM(I1, 2), I1 = 0x30000',
     [0x0f1000200000, 0x0f2000000000, 0x0f1100030000, (0b010 << 45) | (0x0e << 33)],
     (0b0110 << 44) | (1 << 41) | (0x1f << 33) | (2 << 27) | (1 << 23), 0),
    # ... and a load through an I register written by the word before with a post-modify of another
    # (the write deferred a clock, ir_pw, into this word's first D clock): its old value outside the
    # map (I1 = 0x200000), the loaded one inside (0x30000, stored at 0x30010 first)
    ('R1 = DM(I1, 2) straight after I1 = DM(I2, M2) (post-modify, the I1 write deferred), I1 0x200000 -> 0x30000',
     [0x0f1200030010, 0x0f2200000000, 0x0f1100200000, 0x0f0000030000,
      (0b010 << 45) | (1 << 44) | (2 << 41) | (2 << 38) | (0x1f << 33) | (1 << 31),
      (0b010 << 45) | (1 << 44) | (2 << 41) | (2 << 38) | (0x1f << 33) | (0x11 << 23)],
     (0b0110 << 44) | (1 << 41) | (0x1f << 33) | (2 << 27) | (1 << 23), 0),
]


# R1062: the out-of-map loop. Every kind of access the core's map does not decode, read and
# written, in a loop; each read follows R0 = 0x0BADF00D so a load of 0 is told from no load. A
# word that must not land if dropped is aimed at the loop itself (a PM-bus store past the on-chip
# PM aliasing the loop's jump) or at a DM word read back (0x28010 = 0x12345678).
def _imm(ureg, v): return (0x0f << 40) | (ureg << 32) | (v & 0xffffffff)
def _dmd(addr, ureg, wr=0, pm=0): return (0b000100 << 42) | (pm << 41) | (wr << 40) | (ureg << 32) | (addr & 0xffffffff)
BAD = 0x0BADF00D
def oom_loop():
    top = 0x20088
    body = []                                   # (word, R0 / R1 / I0 expected after it, or None)
    def rd(addr, pm=0): body.append((_imm(0x00, BAD), None)); body.append((_dmd(addr, 0x00, 0, pm), ('R0', 0)))
    def wr(addr, pm=0): body.append((_dmd(addr, 0x05, 1, pm), None))
    rd(0x00020010); wr(0x00020010)              # block-0 data over the DM bus (the in-map kind: on-chip DM word 0x10)
    body.append((_dmd(0x00028010, 0x01), ('R1', 0x12345678)))
    rd(0x01000000)                              # the out FIFO's window, read (nothing pushed)
    wr(0x00400000)                              # the in FIFO's window, written (no pop, no wait for the empty FIFO)
    rd(0x02400000)                              # ... read with bit 25 set (no pop, no wait)
    wr(0x02C00000)                              # the out FIFO's window written with bit 25 set (nothing pushed)
    rd(0x00022000 | (top & 0x1fff), pm=1)       # PM past the on-chip words (aliasing the loop's first word)
    rd(0x00420000 | (top & 0x1fff), pm=1)       # ... with bit 22 set (the loop's first word's own low bits)
    jmp_k = None
    wr_j = len(body); body.append((None, None)) # PM-bus store aliasing the loop's jump (filled below)
    rd(0x00400000, pm=1)                        # external PM
    rd(0x0040A000, pm=1); wr(0x0040A000, pm=1)  # external PM whose low bits name block 1's page (m2b_xbus: nothing)
    rd(0x01E00000); wr(0x01E00000)              # DM-bus external, nothing decodes it (m2b_xbus's unmapped)
    rd(0x40028010); wr(0x40028010)              # an address bit above the map (as 0x28010 inside)
    wr(0x00010000)                              # 0x10000 (the IOP registers' kind: SYSCON not written)
    body.append((_imm(0x10, 0x00020010), None)) # I0 = 0x20010
    body.append((_imm(0x00, BAD), None))
    body.append(((0b010 << 45) | (1 << 44) | (1 << 38) | (0x1f << 33), ('R0', 0, 'I0', 0x00020011)))   # R0 = DM(I0, M1): the post-modify runs
    body.append((_imm(0x10, 0x00028010), None)) # I0 = 0x28010
    body.append((_imm(0x00, BAD), None)); body.append((_imm(0x01, 0), None))
    # type 1: R1 = DM(I0, M0) inside the map, R0 = PM(I8, M8) past the on-chip PM (I8 aliases the loop's first word)
    body.append(((0b001 << 45) | (1 << 33), ('R0', 0, 'R1', 0x12345678)))
    body.append(((0x06 << 40) | (0x1f << 33) | top, None))       # jump top
    jmp = top + len(body) - 1
    body[wr_j] = (_dmd(0x00022000 | (jmp & 0x1fff), 0x05, 1, 1), None)
    setup = [(0x0f << 40) | (0x7b << 32) | 0x18000, _imm(0x04, 0x12345678), _imm(0x05, 0xDEADBEEF),
             _dmd(0x00028010, 0x04, 1), _imm(0x20, 0), _imm(0x21, 1), _imm(0x18, 0x00022000 | (top & 0x1fff)), _imm(0x28, 0)]
    assert 0x20080 + len(setup) == top
    pm = {0x20080 + k: w for k, w in enumerate(setup)}
    exp = {}
    for k, (w, e) in enumerate(body):
        pm[top + k] = w
        if e: exp[top + k] = e
    pm[0x20005] = (0x06 << 40) | (0x1f << 33) | 0x20080
    return pm, exp, len(body)


def pm_events(pm):
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


def oom_check(path):
    # a run of o0.bin (+noidle +show=<n>): every word of the loop retires in order, each read
    # leaves the expected value, no word is flagged but for reason 3, nothing is pushed or written out
    import re
    pm, exp, n = oom_loop()
    top = 0x20088
    ret = [l for l in open(path) if l.startswith('ret ')]
    bad = 0; iters = 0; nxt = None
    for l in ret:
        m = re.search(r'pc (\w+) op \w+ next \w+  R0 (\w+) R1 (\w+) I0 (\w+)', l)
        pc, r0, r1, i0 = (int(x, 16) for x in m.groups())
        if nxt is not None and pc != nxt: bad += 1; print('ORDER', l.strip())
        if pc >= top: nxt = top if pc == top + n - 1 else pc + 1
        if pc == top + n - 1: iters += 1
        e = exp.get(pc)
        if e:
            v = {'R0': r0, 'R1': r1, 'I0': i0}
            for k in range(0, len(e), 2):
                if v[e[k]] != e[k + 1]:
                    bad += 1
                    if bad < 10: print('VALUE', e[k], '%08x' % v[e[k]], 'want %08x' % e[k + 1], l.strip())
    txt = open(path).read()
    outs = re.search(r'out FIFO words (\d+)', txt); bx = re.search(r'buffer / ROM: (\d+) reads, (\d+) writes', txt)
    un = re.search(r'UNSUPPORTED word at (\w+): \w+ \(reason (\d+)\)', txt)
    print('o0: %d words, %d loop passes (%d words each), %d differ; out FIFO words %s; buffer / ROM reads %s writes %s; flag %s' %
          (len(ret), iters, n, bad, outs.group(1) if outs else '?', bx.group(1) if bx else '?', bx.group(2) if bx else '?',
           ('pc %s reason %s' % un.groups()) if un else 'none'))
    ok = bad == 0 and iters > 0 and outs and outs.group(1) == '0' and bx and bx.groups() == ('0', '0') and un and un.group(2) == '3'
    print('OOM PASS' if ok else 'OOM FAIL')
    return ok


def prog_events(pre, word):
    base = 0x20080
    prog = [(0x0f << 40) | (0x7b << 32) | 0x18000] + pre
    while len(prog) < 4: prog.append(0)
    prog += [word, 0, 0, (0x06 << 40) | (0x1f << 33) | base]
    pm = {base + k: w for k, w in enumerate(prog)}
    pm[0x20005] = (0x06 << 40) | (0x1f << 33) | base
    return pm_events(pm)


def main():
    if sys.argv[1] == '--oomcheck':
        sys.exit(0 if oom_check(sys.argv[2]) else 1)
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    lines = []
    cases = CASES + (PXIM0_CASES if '--pxim0' in sys.argv[2:] else []) + (SKLR0_CASES if '--sklr0' in sys.argv[2:] else []) + MAP_CASES
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
    if '--oomloop' in sys.argv[2:]:
        pm, exp, n = oom_loop()
        open(os.path.join(out, 'o0.bin'), 'wb').write(pm_events(pm))
    print('%d programs' % len(lines))


if __name__ == '__main__':
    main()
