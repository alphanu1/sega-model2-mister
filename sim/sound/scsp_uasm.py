#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# The 2A SCSP's microcode (study R858): the field layout, the program, the
# assembler and a pipeline checker -- one source for the RTL (through the
# generated include) and the two ROMs.
#
#   scsp_uasm.py <out dir>   writes scsp_ucf.hex, scsp_uce.hex, scsp_uc.svh
#
# THE MACHINE (rtl/sound/scsp/m2_scsp.sv). A microinstruction is fetched
# into F, and executes in E the next clock. Its F half issues the reads --
# the register file's two ports (ra, rb), one row of the slot-state RAM, a
# word of the slot registers on each of two ports, one level word -- and
# chooses the next address. Its E half has those operands and computes one
# ALU result (always into Q; optionally into a register and / or a state
# row), may start a multiply, set a flag, latch register fields, and has up
# to two side effects. F and E come from two ROMs, E's read a clock later.
# A hold (DISPATCH, WAIT) keeps a microinstruction in F and feeds E bubbles;
# when it goes on, its E half runs once. Nothing stalls in E.
#
# Latencies, k = this microinstruction (the checker below enforces them on
# every execution path):
#   register or state row written by k : readable by k+2 (k+1 reads the old)
#   ALU result of k                    : Q in E(k+1) only
#   multiply started by k              : P from E(k+2) until E(j+1), j the next
#   table address loaded by k          : TBL / EGV from E(k+2)
#   flag or latch set by k             : E(k+1), F(k+2)
#   ring read issued by k              : RING in E(k+1)
#   STREG row read by k                : RATE in E(k+1)
# and, for timing (R859), the envelope takes two clocks: an EG at k adds in
# E(k) and clamps, writes its state row and loads EGV's table address in the
# clock after -- so k+1 may not write a state row or use Q, and EGV counts
# from k+1. The captures take the operand or the sum, not the result mux:
# FETCH1 / FETCH2 / TADRP are ADD / ADD / ADDSPLIT, TADRA and the outputs PASSA.
# The DAC takes register port A itself, not the A mux: a DAC is a = RA (R875;
# P's shift is registered a clock early in the RTL, which no latency here sees).
import sys, os

F_FIELDS = [('ra', 4), ('rb', 4), ('st', 1), ('strow', 3), ('streg', 1), ('idx', 2),
            ('swa', 4), ('swb', 4), ('lw', 3), ('flow', 3), ('bc', 4), ('tgt', 8)]
E_FIELDS = [('op', 4), ('a', 3), ('b', 3), ('psl', 2), ('imm', 16), ('immhi', 1),
            ('rdwe', 1), ('rd', 4), ('pred', 4), ('stwe', 1), ('stwrow', 3), ('widx', 2),
            ('mul', 1), ('ma', 2), ('mb', 3), ('fset', 3), ('lata', 3), ('latb', 2),
            ('s1', 4), ('s2', 4)]

IDX = dict(SLOT=0, SW=1, MSLC=2)
FLOW = dict(NEXT=0, BR=1, JMP=2, DISPATCH=3, WAIT=4, RET=5, SLOTEND=6)
COND = dict(ALWAYS=0, PLFO=1, ALFO=2, LOOP1=3, LOOP2=4, FMMOD=5, MVOL15=6, NMVOL15=7,
            START=8, NKB=9, MORESW=10, MOREI=11, SSCTL3=12, FETCHED=13, GO=14, DSPIDLE=15)
OP = dict(ADD=0, SUB=1, PASSA=2, PASSB=3, ANDN=4, ADDSGN=5, EG=6, RATEIDX=7, EGBASE=8, SBC=9,
          DAC=10, ADDSPLIT=12)
A = dict(RA=0, Q=1, ST=2, CSH=3, PSL=4, P2=5, RING=6, EFQ=7)
B = dict(RB=0, IMM=1, Q=2, SA=3, SQ12=4, LFOI=5, RATE=6, P1=7)
PSL = dict(S6=0, S12=1, S16=2, FM=3)
MA = dict(RA=0, Q=1, PSL=2, FNSX=3)
MB = dict(POW2P=0, POW2F=1, TBL4=2, EGV=3, LV=4, FRAC=5, MVG=6, BST=7)
FSET = dict(NONE=0, F1=1, F2=2, F3=3, F4=4, KBREL=5)
LATA = dict(NONE=0, W9=1, W4=2, W5=3, W6=4, W10=5)
LATB = dict(NONE=0, W0=1, W7=2)
S1 = dict(NONE=0, FETCH1=1, FETCH2=2, TADRP=3, TADRA=4, TADRE=5, DBG=8,
          RINGX=9, RINGY=10, LATEG=11, OUTLRAW=12, OUTRRAW=13, OUTL=14, OUTR=15)
S2 = dict(NONE=0, OUTV=1, DSPGO=2, ACTSET=3, SWINC=4, ICLR=5, IINC=6, MON1=7, MON2=8, MIXW=9, RINGW=10, MON3=11)
ST = dict(CUR=0, NXT=1, PH=2, VOL=3, RAR=4, RD1=5, RD2=6, RRR=7)
RI = dict(AR=0, D1R=1, D2R=2, RR=3)       # RATEIDX: imm[1:0] picks the rate field
R = dict(SMPL=0, SMPR=1, STEP=2, S=3, CURA=4, NA=5, CREM=6, NREM=7, SAFM=8, PH=9,
         T0=10, T1=11, T2=12)

def m(**kw):
    """one microinstruction; 'mul' is (ma, mb, name), 'P' / 'TBL' name what a P / table use expects"""
    return dict(kw)

# ===================================================================== a slot
# MAME's UpdateSlot, then this slot's part of DoMasterSamples' mix. The
# prefix is shared; the rest comes in four variants (FM or not, ALFO or not)
# of one schedule.
def slot_prefix():
    return [
        m(swa=9, lata='W9', swb=7, latb='W7'),                                       # 0
        m(swa=1, swb=0, latb='W0', op='PASSB', b='SA', rd='SAFM'),                   # 1
        m(swa=8, mul=('FNSX', 'POW2P', 'pitch'), st='PH', op='ADDSPLIT', a='ST', b='LFOI',
          rd='PH', s1='TADRP', flow='BR', bc='FMMOD', tgt='FSLOT'),                  # 2
    ]

def slot_mid(fm):
    if not fm:
        return [
            m(flow='BR', bc='SSCTL3', tgt='SKIP', st='CUR', op='ADD', a='CSH', b='RB', rb='SAFM',
              s1='FETCH1'),                                                           # 3
            m(st='NXT', op='ADD', a='CSH', b='RB', rb='SAFM', s1='FETCH2', swa=4, lata='W4',
              mul=('PSL', 'TBL4', 'plfo'), psl='S6', P='pitch', TBL='P'),             # 4
            m(op='PASSA', a='PSL', psl='S6', P='pitch', rd='STEP', swa=5, lata='W5',
              st='VOL', s1='LATEG'),                                                  # 5
            m(op='PASSA', a='PSL', psl='S12', P='plfo', rd='STEP', pred='PLFO', swa=6, lata='W6'),
            m(ra='PH', op='PASSA', a='RA', s1='TADRA', stw='PH', swa=10, lata='W10'),  # 7
            m(st='CUR', rb='STEP', swa=2, op='ADD', a='ST', b='RB', rd='CURA', fset='F3'),
            m(swa=2, op='ADD', a='Q', b='IMM', imm=4096, rd='NA', fset='F4'),         # 9
            m(flow='WAIT', bc='FETCHED', op='SUB', a='P2', b='P1', streg=1),          # 10
            m(mul=('Q', 'FRAC', 'frac'), st='VOL', swa=5, op='EG', a='ST', b='RATE', stw='VOL',
              s1='TADRE'),                                                            # 11
            m(ra='CURA', swa=3, op='SUB', a='RA', b='SQ12', rd='CREM', fset='F1'),    # 12
            m(op='SBC', a='PSL', psl='S12', P='frac', b='P1', rd='S',
              flow='BR', bc='ALFO', tgt='NALF'),                                      # 13
        ]
    return [
        m(flow='BR', bc='SSCTL3', tgt='SKIP', swa=7, s1='RINGX'),                     # 3
        m(swa=7, s1='RINGY', op='PASSA', a='RING'),                                   # 4: RING[x]
        m(op='ADD', a='RING', b='Q', st='VOL', s1='LATEG'),                           # 5: + RING[y]
        m(op='ADDSGN', a='Q', swa=4, lata='W4', mul=('PSL', 'TBL4', 'plfo'), psl='S6',
          P='pitch', TBL='P'),                                                        # 6
        m(op='PASSA', a='PSL', psl='S6', P='pitch', rd='STEP', mul=('Q', 'POW2F', 'fm'),
          swa=5, lata='W5'),                                                          # 7
        m(op='PASSA', a='PSL', psl='S12', P='plfo', rd='STEP', pred='PLFO', swa=6, lata='W6'),
        m(swa=1, swb=0, op='ADD', a='PSL', psl='FM', P='fm', b='SA', rd='SAFM'),      # 9
        m(ra='PH', op='PASSA', a='RA', s1='TADRA', stw='PH', swa=10, lata='W10'),      # 10
        m(st='CUR', op='ADD', a='CSH', b='RB', rb='SAFM', s1='FETCH1'),               # 11
        m(st='NXT', op='ADD', a='CSH', b='RB', rb='SAFM', s1='FETCH2'),               # 12
        m(st='CUR', rb='STEP', swa=2, op='ADD', a='ST', b='RB', rd='CURA', fset='F3'),
        m(swa=2, op='ADD', a='Q', b='IMM', imm=4096, rd='NA', fset='F4'),             # 14
        m(ra='CURA', swa=3, op='SUB', a='RA', b='SQ12', rd='CREM', fset='F1', streg=1),
        m(st='VOL', swa=5, op='EG', a='ST', b='RATE', stw='VOL', s1='TADRE'),         # 16
        m(flow='WAIT', bc='FETCHED', op='SUB', a='P2', b='P1'),                       # 17
        m(mul=('Q', 'FRAC', 'frac')),                                                 # 18
        m(),                                                                          # 19
        m(op='SBC', a='PSL', psl='S12', P='frac', b='P1', rd='S',
          flow='BR', bc='ALFO', tgt='FALF'),                                          # 20
    ]

def slot_alfo():
    return [
        m(mul=('Q', 'TBL4', 'alfo'), TBL='A'),
        m(),
        m(op='PASSA', a='PSL', psl='S12', P='alfo', rd='S'),
    ]

def slot_tail():
    # the loop's ends: cur / nxt written as stepped, then overwritten wrapped
    # (LSA + (stepped - LEA), LPCTL 1) where the address passed LEA
    return [
        m(mul=('Q', 'EGV', 'eg'), ra='NA', swa=3, op='SUB', a='RA', b='SQ12', rd='NREM', fset='F2'),
        m(ra='CURA', op='PASSA', a='RA', stw='CUR'),
        m(op='PASSA', a='PSL', psl='S12', P='eg', rd='S', s1='DBG'),
        m(mul=('Q', 'LV', 'l0'), lw=0, ra='NA', op='PASSA', a='RA', stw='NXT'),
        m(mul=('RA', 'LV', 'l1'), lw=1, ra='S'),
        m(mul=('RA', 'LV', 'l2'), lw=2, ra='S', rb='SMPL', op='ADD', a='PSL', psl='S12', P='l0',
          b='RB', rd='SMPL'),
        m(mul=('RA', 'LV', 'l5'), lw=5, ra='S', rb='SMPR', op='ADD', a='PSL', psl='S12', P='l1',
          b='RB', rd='SMPR'),
        m(s2='MIXW', P='l2', ra='CREM', swa=2, op='ADD', a='RA', b='SQ12', pred='LOOP1', stw='CUR'),
        m(s2='RINGW', P='l5', ra='NREM', swa=2, op='ADD', a='RA', b='SQ12', pred='LOOP2', stw='NXT',
          flow='SLOTEND'),
    ]

# ===================================================================== the rest
def sample_head():
    return [
        ('IDLE', m(flow='WAIT', bc='GO')),
        (None, m(op='PASSB', b='IMM', imm=0, rd='SMPL', s2='ICLR')),
        (None, m(op='PASSB', b='IMM', imm=0, rd='SMPR')),
        ('DISPATCH', m(flow='DISPATCH')),
        (None, m(flow='WAIT', bc='DSPIDLE')),
        (None, m(s2='DSPGO')),
        (None, m(s2='ICLR')),
        # R894: the direct sends' sum (the slots' DISDL / DIPAN, all of SMPL /
        # SMPR so far) x 1 / 2 / 4 -- the OSD's Direct boost -- before the
        # effect returns join it; while the DSP runs, so it costs no time.
        # BST is 64 << boost and PSL S6 takes P[37:6]: Off is SMPL exactly.
        ('BOOST', m(ra='SMPL', mul=('RA', 'BST', 'bl'))),
        (None, m(ra='SMPR', mul=('RA', 'BST', 'br'))),
        (None, m(op='PASSA', a='PSL', psl='S6', P='bl', rd='SMPL')),
        (None, m(op='PASSA', a='PSL', psl='S6', P='br', rd='SMPR')),
        (None, m(flow='WAIT', bc='DSPIDLE')),
        # the effect returns, i = 0..15 (ef_idx follows i; EFREG[i] two clocks after it moves)
        ('EFF', m(op='PASSA', a='EFQ')),
        (None, m(lw=3, mul=('Q', 'LV', 'e3'))),
        (None, m(lw=4, mul=('Q', 'LV', 'e4'), s2='IINC')),
        (None, m(rb='SMPL', op='ADD', a='PSL', psl='S12', P='e3', b='RB', rd='SMPL')),
        (None, m(rb='SMPR', op='ADD', a='PSL', psl='S12', P='e4', b='RB', rd='SMPR',
                 flow='BR', bc='MOREI', tgt='EFF')),
        # the output: the raw mix; the DAC and MVOL; the 0x408 monitor latched
        (None, m(ra='SMPL', op='PASSA', a='RA', s1='OUTLRAW')),
        (None, m(ra='SMPR', op='PASSA', a='RA', s1='OUTRRAW')),
        (None, m(ra='SMPL', op='DAC', a='RA', rd='T0')),
        (None, m(ra='SMPR', op='DAC', a='RA', rd='T1', mul=('Q', 'MVG', 'ol'))),
        (None, m(mul=('Q', 'MVG', 'or'), idx='MSLC', st='CUR', s2='MON1')),
        (None, m(op='PASSA', a='PSL', psl='S16', P='ol', pred='NMVOL15', s1='OUTL', idx='MSLC', st='VOL',
                 s2='MON2')),
        (None, m(op='PASSA', a='PSL', psl='S16', P='or', pred='NMVOL15', s1='OUTR')),
        (None, m(ra='T0', op='PASSA', a='RA', pred='MVOL15', s1='OUTL')),
        (None, m(ra='T1', op='PASSA', a='RA', pred='MVOL15', s1='OUTR')),
        (None, m(s2='OUTV', flow='JMP', tgt='IDLE')),
    ]

# KEYONEX: MAME's sweep -- every keyed slot in RELEASE starts, every unkeyed
# one is released (sw = 0..31; the call sets sw = 0)
def sweep():
    return [
        ('SWEEP', m(idx='SW', swb=0, st='VOL', fset='KBREL')),
        (None, m(idx='SW')),
        (None, m(idx='SW', flow='BR', bc='START', tgt='SWSTART')),
        ('SWNEXT', m(idx='SW', st='VOL', op='ANDN', a='ST', b='IMM', imm=0x0c00, immhi=1, pred='NKB',
                     stw='VOL', s2='SWINC')),
        (None, m(idx='SW', flow='BR', bc='MORESW', tgt='SWEEP')),
        (None, m(flow='RET')),
        # StartSlot: the four rates (Compute_EG's base), cur 0, nxt 4096, volume 0x17f << 16, ATTACK
        ('SWSTART', m(idx='SW', swa=8, swb=5, op='EGBASE', rd='T2')),
        (None, m(idx='SW', swa=4, op='RATEIDX', a='Q', imm=RI['AR'], stw='RAR')),
        (None, m(idx='SW', swa=4, ra='T2', op='RATEIDX', a='RA', imm=RI['D1R'], stw='RD1')),
        (None, m(idx='SW', swa=4, ra='T2', op='RATEIDX', a='RA', imm=RI['D2R'], stw='RD2')),
        (None, m(idx='SW', swb=5, ra='T2', op='RATEIDX', a='RA', imm=RI['RR'], stw='RRR')),
        (None, m(idx='SW', op='PASSB', b='IMM', imm=0, stw='CUR')),
        (None, m(idx='SW', op='PASSB', b='IMM', imm=4096, stw='NXT')),
        (None, m(idx='SW', op='PASSB', b='IMM', imm=0x0d7f, immhi=1, stw='VOL', s2='ACTSET',
                 flow='JMP', tgt='SWNEXT')),
    ]

# a write to word 5: RR = Get_RR(0, RR), MAME's base 0 (sw = the slot)
def word5():
    return [
        ('W5', m(idx='SW', op='PASSB', b='IMM', imm=0)),
        (None, m(idx='SW', swb=5, op='RATEIDX', a='Q', imm=RI['RR'], stw='RRR')),
        (None, m(flow='RET')),
    ]

# the 0x408 monitor latched for the 68000 (R885): called from an operation
# window at the 68000's own sample boundary, for the slot MSLC selected then
# (sw = that slot); MON3 is MON2 for the free-running engine
def moncall():
    return [
        ('MON', m(idx='SW', st='CUR', s2='MON1')),
        (None, m(idx='SW', st='VOL', s2='MON3')),
        (None, m(flow='RET')),
    ]

# ===================================================================== layout
rom, labels, fixups = [], {}, []
def place(label, mi):
    if label:
        if label in labels: raise SystemExit('label %s twice' % label)
        labels[label] = len(rom)
    rom.append(mi)

place('NOP', m())                      # address 0: E's bubble
for lab, mi in sample_head(): place(lab, mi)
for lab, mi in sweep(): place(lab, mi)
for lab, mi in word5(): place(lab, mi)
for lab, mi in moncall(): place(lab, mi)
place('SKIP', m(flow='SLOTEND'))       # SSCTL 3: MAME returns 0, touching nothing
pre, midn, midf, alf, tail = slot_prefix(), slot_mid(False), slot_mid(True), slot_alfo(), slot_tail()
for i, mi in enumerate(pre): place('SLOT' if i == 0 else None, mi)
for mi in midn: place(None, mi)
for mi in tail: place(None, mi)
for i, mi in enumerate(alf + tail): place('NALF' if i == 0 else None, mi)
for i, mi in enumerate(midf + tail): place('FSLOT' if i == 0 else None, mi)
for i, mi in enumerate(alf + tail): place('FALF' if i == 0 else None, mi)
paths = {
    'slot': pre + midn + tail, 'slot+alfo': pre + midn + alf + tail,
    'fm': pre + midf + tail, 'fm+alfo': pre + midf + alf + tail,
}
if len(rom) > 256: raise SystemExit('microcode too long: %d' % len(rom))

# ===================================================================== the checker
def check(name, seq):
    err = []
    regw, stw, mul, tadr = {}, {}, [], []     # last writer index; multiplies (k, name); table loads
    flag_set, lat_set = {}, {}
    for k, mi in enumerate(seq):
        for port in ('ra', 'rb'):
            if port in mi:
                r = mi[port]
                if r in regw and regw[r] == k - 1:
                    err.append('%d: %s=%s written by %d (needs Q)' % (k, port, r, k - 1))
        if 'st' in mi and mi['st'] in stw and stw[mi['st']] == k - 1:
            err.append('%d: state row %s written by %d' % (k, mi['st'], k - 1))
        if 'P' in mi:
            vis = [j for j, _ in mul if j <= k - 2]
            if not vis: err.append('%d: P %s: no multiply' % (k, mi['P']))
            else:
                j = max(vis)
                got = [n for jj, n in mul if jj == j][0]
                if got != mi['P']: err.append('%d: P is %s, wants %s' % (k, got, mi['P']))
        if 'TBL' in mi:
            vis = [(j, t) for j, t in tadr if j <= k - 2 and t != 'E']
            if not vis or vis[-1][1] != mi['TBL']:
                err.append('%d: table %s not there (%s)' % (k, mi['TBL'], vis[-1:]))
        if k > 0 and seq[k - 1].get('op') == 'EG':
            if 'stw' in mi: err.append('%d: state write the clock after an EG' % k)
            if mi.get('a') == 'Q' or mi.get('b') == 'Q' or ('mul' in mi and mi['mul'][0] == 'Q') \
               or 'op' not in mi:                       # (no op keeps Q: the EG's sum, not its result)
                err.append('%d: Q the clock after an EG' % k)
        if 'mul' in mi and mi['mul'][1] == 'EGV':
            if not [j for j, t in tadr if t == 'E' and j <= k - 2]: err.append('%d: EGV early' % k)
        # writes
        if 'rd' in mi: regw[mi['rd']] = k
        if 'stw' in mi: stw[mi['stw']] = k
        if 'mul' in mi: mul.append((k, mi['mul'][2]))
        s1 = mi.get('s1')
        if s1 in ('TADRP', 'TADRA'): tadr.append((k, s1[-1]))
        if s1 == 'TADRE': tadr.append((k + 1, 'E'))      # (the envelope's second clock)
    for e in err: print('%s: %s' % (name, e))
    return len(err)

# the captures' operations (the RTL takes the sum or the operand, not the result)
NEED = dict(FETCH1='ADD', FETCH2='ADD', TADRP='ADDSPLIT', TADRA='PASSA', TADRE='EG', DBG='PASSA',
            OUTLRAW='PASSA', OUTRRAW='PASSA', OUTL='PASSA', OUTR='PASSA')
for i, mi in enumerate(rom):
    s1 = mi.get('s1')
    if s1 in NEED and mi.get('op') != NEED[s1]:
        raise SystemExit('microinstruction %d: %s needs op %s' % (i, s1, NEED[s1]))
    # the DAC reads the register file's port A directly, not the A mux (R875)
    if mi.get('op') == 'DAC' and mi.get('a') != 'RA':
        raise SystemExit('microinstruction %d: DAC needs a = RA' % i)

nerr = sum(check(n, s) for n, s in paths.items())
nerr += check('head', [mi for _, mi in sample_head()][7:])     # from the boost (R894) on
nerr += check('sweep', [mi for _, mi in sweep()][6:])

# ===================================================================== encode
def enc(fields, vals):
    w, pos = 0, 0
    for name, bits in fields:
        v = vals.get(name, 0)
        if v < 0 or v >= (1 << bits): raise SystemExit('field %s = %d does not fit' % (name, v))
        w |= v << pos
        pos += bits
    return w

def fields_of(i, mi):
    f, e = {}, {}
    for k, v in mi.items():
        if k in ('P', 'TBL', 'note'): continue
        if k in ('ra', 'rb'): f[k] = R[v]
        elif k == 'rd': e['rdwe'] = 1; e['rd'] = R[v]
        elif k == 'st': f['st'] = 1; f['strow'] = ST[v]
        elif k == 'streg': f['st'] = 1; f['streg'] = 1
        elif k == 'idx': f['idx'] = IDX[v]; e['widx'] = IDX[v]
        elif k in ('swa', 'swb', 'lw'): f[k] = v
        elif k == 'flow': f['flow'] = FLOW[v]
        elif k == 'bc': f['bc'] = COND[v]
        elif k == 'tgt': f['tgt'] = labels[v]
        elif k == 'op': e['op'] = OP[v]
        elif k == 'a': e['a'] = A[v]
        elif k == 'b': e['b'] = B[v]
        elif k == 'psl': e['psl'] = PSL[v]
        elif k == 'imm': e['imm'] = v & 0xffff
        elif k == 'immhi': e['immhi'] = 1
        elif k == 'pred': e['pred'] = COND[v]
        elif k == 'stw': e['stwe'] = 1; e['stwrow'] = ST[v]
        elif k == 'mul': e['mul'] = 1; e['ma'] = MA[v[0]]; e['mb'] = MB[v[1]]
        elif k == 'fset': e['fset'] = FSET[v]
        elif k == 'lata': e['lata'] = LATA[v]
        elif k == 'latb': e['latb'] = LATB[v]
        elif k == 's1': e['s1'] = S1[v]
        elif k == 's2': e['s2'] = S2[v]
        else: raise SystemExit('microinstruction %d: unknown field %s' % (i, k))
    if 'op' not in mi: e['op'] = OP['PASSA']; e['a'] = A['Q']   # keep Q
    return f, e

def main():
    out = sys.argv[1] if len(sys.argv) > 1 else '.'
    if nerr: raise SystemExit('%d pipeline errors' % nerr)
    fw, ew = sum(b for _, b in F_FIELDS), sum(b for _, b in E_FIELDS)
    with open(os.path.join(out, 'scsp_ucf.hex'), 'w') as ff, open(os.path.join(out, 'scsp_uce.hex'), 'w') as fe:
        for i in range(256):
            f, e = fields_of(i, rom[i]) if i < len(rom) else fields_of(i, m())
            ff.write('%0*x\n' % ((fw + 3) // 4, enc(F_FIELDS, f)))
            fe.write('%0*x\n' % ((ew + 3) // 4, enc(E_FIELDS, e)))
    with open(os.path.join(out, 'scsp_uc.svh'), 'w') as h:
        h.write('// GENERATED by sim/sound/scsp_uasm.py -- the SCSP microcode\'s layout. Do not edit.\n')
        for nm, flds in (('F', F_FIELDS), ('E', E_FIELDS)):
            pos = 0
            for name, bits in flds:
                h.write('`define U%s_%s %d:%d\n' % (nm, name.upper(), pos + bits - 1, pos))
                pos += bits
            h.write('localparam int U%s_W = %d;\n' % (nm, pos))
        f0, e0 = fields_of(0, rom[0])                   # the bubble's E half, for the RTL's own
        h.write("localparam logic [%d:0] UE_NOPW = %d'h%x;\n" % (pos - 1, pos, enc(E_FIELDS, e0)) if nm == 'E' else '')
        for tname, tab in (('IDX', IDX), ('FLOW', FLOW), ('C', COND), ('OP', OP), ('A', A), ('B', B),
                           ('PSL', PSL), ('MA', MA), ('MB', MB), ('FSET', FSET), ('LATA', LATA),
                           ('LATB', LATB), ('S1', S1), ('S2', S2), ('ST', ST), ('RI', RI)):
            for k, v in tab.items():
                h.write('localparam int %s_%s = %d;\n' % (tname, k, v))
        for k, v in sorted(labels.items(), key=lambda x: x[1]):
            h.write('localparam logic [7:0] UA_%s = 8\'d%d;\n' % (k, v))
    print('microcode: %d of 256 words; F %d bits, E %d bits; slot %d / %d / %d / %d microinstructions'
          % (len(rom), fw, ew, len(paths['slot']), len(paths['slot+alfo']), len(paths['fm']),
             len(paths['fm+alfo'])))

if __name__ == '__main__':
    main()
