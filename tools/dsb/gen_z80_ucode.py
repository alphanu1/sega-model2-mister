#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
# (from the Sega Model 1 core, sega-model1-mister 2657c46, tools/dsb/gen_z80_ucode.py)
#
# Generates rtl/sound/dsb_z80_ucode.svh: the microcode of dsb_z80, the DSB's
# cut-down Z80, and its dispatch table. One micro-op per line below; the
# instructions are the UNION of what two programs reach (tools/dsb/z80_census.py):
#
#   Star Wars Arcade, epr-16471.2 (Model 1)      76 opcodes
#   Sega Touring Car Championship, epr-19275.2s  128 opcodes, 69 of them new:
#     IY (FD 21 23 70 71 77 7E 86 8E BE E1 E5), EX AF,AF' and EXX, JP (HL),
#     RST 08, adc / sub / sbc hl,de, the S flag (jp m), rr / rrca / rra,
#     cpl, more loads, incs, jrs and bits, and IM 1 interrupts.
#
# with the Z80's T-states on the micro-op that ends each instruction. Changed
# from Model 1: wsrc grew to 3 bits (TMPh / TMPl, for PUSH IY) and paid for it
# with rsrc, which is gone -- every register write takes the ALU's result, and
# a load is the ALU passing the read data (ysel dat). The ALU field also
# carries the instructions that are only an action (EXX, EX AF, EI, DI).
#
#   python3 tools/dsb/gen_z80_ucode.py [--uent-logic] > rtl/sound/dsb_z80_ucode.svh
#
# --uent-logic also emits the dispatch table as a function, uent_f(), which
# dsb_z80 uses instead of the 1024 x 8 ROM when DSB_UENT_LOGIC is defined. The
# ROM is always emitted; the unused one is left out by synthesis.
import sys

# ---- field encodings (must match dsb_z80.sv)
MEM = dict(none=0, rd=1, wr=2)
ASRC = dict(PC=0, SP=1, BC=2, DE=3, HL=4, TMP=5, IY=6, RSTV=7)
AOFF = {'0': 0, '+1': 1, '-1': 2, '-2': 3, 'DE': 4, 'e': 5, 'BC': 6, 'HL': 7}
AWB = dict(none=0, PC=1, SP=2, BC=3, DE=4, HL=5, TMP=6, IY=7)
WSRC = dict(reg=0, PCh=1, PCl=2, alu=3, TMPh=4, TMPl=5)
RMODE = dict(none=0, IR53=1, IR20=2, idx=3, TMPlo=4, TMPhi=5)
REG = dict(B=0, C=1, D=2, E=3, H=4, L=5, A=7)
ALU = dict(PASS=0, IRALU=1, IRROT=2, INC=3, DEC=4, BIT=5, AGUC=6, CPL=7,
           SBC16=8, EXX=9, EXAF=10, EI=11, DI=12)
YSEL = dict(IR20=0, IR53=1, dat=2, B=3)
NXT = dict(next=0, end=1, cend=2, trap=3)
CSEL = dict(IRcc=0, Bnz=1, BCnz=2, always=3)
IO = dict(none=0, out_n_a=1, out_c_a=2, out_c_dat=3, in_a_n=4)

LAYOUT = [  # (name, bits) MSB first
    ('mem', 2), ('asrc', 3), ('aoff', 3), ('awb', 3), ('wsrc', 3),
    ('rmode', 3), ('ridx', 3), ('alu', 4), ('ysel', 2),
    ('fz', 1), ('fc', 1), ('nxt', 2), ('csel', 2), ('io', 3), ('tst', 5),
]
WIDTH = sum(b for _, b in LAYOUT)
assert WIDTH <= 40, WIDTH   # one M10K at 256 x 40

def u(mem='none', asrc='PC', aoff='0', awb='none', wsrc='reg', rmode='none',
      ridx='B', rsrc='data', alu='PASS', ysel='IR20', fz=0, fc=0, nxt='next',
      csel='always', io='none', t=0):
    # fz writes S and Z together: every instruction either program runs that
    # sets one sets the other.
    if rmode != 'none' and rsrc == 'data':   # a load: the ALU passes the read data
        assert alu == 'PASS', (alu, rmode)
        ysel = 'dat'
    v = dict(mem=MEM[mem], asrc=ASRC[asrc], aoff=AOFF[aoff], awb=AWB[awb],
             wsrc=WSRC[wsrc], rmode=RMODE[rmode], ridx=REG[ridx],
             alu=ALU[alu], ysel=YSEL[ysel],
             fz=fz, fc=fc, nxt=NXT[nxt], csel=CSEL[csel], io=IO[io], tst=t)
    w = 0
    for name, bits in LAYOUT:
        assert 0 <= v[name] < (1 << bits), (name, v[name])
        w = (w << bits) | v[name]
    return w

# reads at PC, post-increment: an immediate byte
def imm(**k):  return u(mem='rd', asrc='PC', aoff='+1', awb='PC', **k)
def imm16():   return [imm(rmode='TMPlo'), imm(rmode='TMPhi')]

prog = {}      # label -> [uops]
entry = {}     # (pfx, op) -> label

def ins(label, ops, codes):
    prog[label] = ops
    for c in codes:
        assert c not in entry, c
        entry[c] = label

M, CB, ED, FD = 0, 1, 2, 3

ins('ld_r_n',   [imm(rmode='IR53', nxt='end', t=7)], [(M, o) for o in (0x06, 0x0e, 0x16, 0x26, 0x3e)])
for o, p in ((0x01, 'BC'), (0x11, 'DE'), (0x21, 'HL'), (0x31, 'SP')):
    ins(f'ld_{p}_nn', imm16() + [u(asrc='TMP', awb=p, nxt='end', t=10)], [(M, o)])
ins('ld_r_r',   [u(alu='PASS', ysel='IR20', rmode='IR53', rsrc='alu', nxt='end', t=4)],
    [(M, o) for o in (0x44, 0x47, 0x4d, 0x4f, 0x54, 0x57, 0x5d, 0x5f, 0x67, 0x69, 0x6a, 0x6f,
                      0x78, 0x79, 0x7a, 0x7b, 0x7c, 0x7d)])
ins('ld_r_hl',  [u(mem='rd', asrc='HL', rmode='IR53', nxt='end', t=7)],
    [(M, o) for o in (0x4e, 0x56, 0x5e, 0x66, 0x7e)])
ins('ld_hl_r',  [u(mem='wr', asrc='HL', wsrc='alu', alu='PASS', ysel='IR20', nxt='end', t=7)],
    [(M, o) for o in (0x70, 0x71, 0x72, 0x73, 0x77)])
ins('ld_a_de',  [u(mem='rd', asrc='DE', rmode='idx', ridx='A', nxt='end', t=7)], [(M, 0x1a)])
ins('alu_r',    [u(alu='IRALU', ysel='IR20', rmode='idx', ridx='A', rsrc='alu', fz=1, fc=1, nxt='end', t=4)],
    [(M, o) for o in (0x80, 0x87, 0xaf, 0xb1, 0xb3, 0xb4, 0xb5, 0xb7, 0xba, 0xbb)])
ins('alu_n',    [imm(alu='IRALU', ysel='dat', rmode='idx', ridx='A', rsrc='alu', fz=1, fc=1, nxt='end', t=7)],
    [(M, o) for o in (0xc6, 0xd6, 0xe6, 0xfe)])
ins('alu_hl',   [u(mem='rd', asrc='HL', alu='IRALU', ysel='dat', rmode='idx', ridx='A', rsrc='alu', fz=1, fc=1, nxt='end', t=7)],
    [(M, 0xbe)])
ins('inc_r',    [u(alu='INC', ysel='IR53', rmode='IR53', rsrc='alu', fz=1, nxt='end', t=4)],
    [(M, o) for o in (0x04, 0x0c, 0x14, 0x1c, 0x3c)])
ins('dec_r',    [u(alu='DEC', ysel='IR53', rmode='IR53', rsrc='alu', fz=1, nxt='end', t=4)],
    [(M, o) for o in (0x0d, 0x3d)])
ins('inc_mhl',  [u(mem='rd', asrc='HL'),
                 u(mem='wr', asrc='HL', wsrc='alu', alu='INC', ysel='dat', fz=1, nxt='end', t=11)], [(M, 0x34)])
ins('dec_mhl',  [u(mem='rd', asrc='HL'),
                 u(mem='wr', asrc='HL', wsrc='alu', alu='DEC', ysel='dat', fz=1, nxt='end', t=11)], [(M, 0x35)])
ins('ld_mhl_n', [imm(), u(mem='wr', asrc='HL', wsrc='alu', alu='PASS', ysel='dat', nxt='end', t=10)], [(M, 0x36)])
for o, p, d in ((0x0b, 'BC', '-1'), (0x13, 'DE', '+1'), (0x1b, 'DE', '-1'), (0x23, 'HL', '+1'), (0x2b, 'HL', '-1')):
    ins(f'incdec16_{o:02x}', [u(asrc=p, aoff=d, awb=p, nxt='end', t=6)], [(M, o)])
for o, p in ((0x09, 'BC'), (0x19, 'DE'), (0x29, 'HL')):
    ins(f'add_hl_{p}', [u(asrc='HL', aoff=p, awb='HL', alu='AGUC', fc=1, nxt='end', t=11)], [(M, o)])
ins('sbc_hl_de', [u(asrc='HL', aoff='DE', awb='HL', alu='SBC16', fz=1, fc=1, nxt='end', t=15)], [(ED, 0x52)])
ins('ld_nn_hl', imm16() + [u(mem='wr', asrc='TMP', wsrc='reg', ridx='L'),
                           u(mem='wr', asrc='TMP', aoff='+1', wsrc='reg', ridx='H', nxt='end', t=16)], [(M, 0x22)])
ins('ld_hl_nn', imm16() + [u(mem='rd', asrc='TMP', rmode='idx', ridx='L'),
                           u(mem='rd', asrc='TMP', aoff='+1', rmode='idx', ridx='H', nxt='end', t=16)], [(M, 0x2a)])
ins('ld_nn_a',  imm16() + [u(mem='wr', asrc='TMP', wsrc='reg', ridx='A', nxt='end', t=13)], [(M, 0x32)])
ins('ld_a_nn',  imm16() + [u(mem='rd', asrc='TMP', rmode='idx', ridx='A', nxt='end', t=13)], [(M, 0x3a)])
ins('ld_nn_de', imm16() + [u(mem='wr', asrc='TMP', wsrc='reg', ridx='E'),
                           u(mem='wr', asrc='TMP', aoff='+1', wsrc='reg', ridx='D', nxt='end', t=20)], [(ED, 0x53)])
ins('ld_de_nn', imm16() + [u(mem='rd', asrc='TMP', rmode='idx', ridx='E'),
                           u(mem='rd', asrc='TMP', aoff='+1', rmode='idx', ridx='D', nxt='end', t=20)], [(ED, 0x5b)])
ins('ld_bc_nn', imm16() + [u(mem='rd', asrc='TMP', rmode='idx', ridx='C'),
                           u(mem='rd', asrc='TMP', aoff='+1', rmode='idx', ridx='B', nxt='end', t=20)], [(ED, 0x4b)])
ins('jp',       imm16() + [u(asrc='TMP', awb='PC', nxt='end', t=10)], [(M, 0xc3)])
ins('jp_cc',    imm16() + [u(nxt='cend', csel='IRcc', t=10), u(asrc='TMP', awb='PC', nxt='end', t=10)],
    [(M, o) for o in (0xc2, 0xca, 0xd2, 0xda, 0xfa)])
ins('jp_hl',    [u(asrc='HL', awb='PC', nxt='end', t=4)], [(M, 0xe9)])
ins('jr',       [imm(), u(asrc='PC', aoff='e', awb='PC', nxt='end', t=12)], [(M, 0x18)])
ins('jr_cc',    [imm(), u(nxt='cend', csel='IRcc', t=7),
                 u(asrc='PC', aoff='e', awb='PC', nxt='end', t=12)], [(M, o) for o in (0x20, 0x28, 0x30, 0x38)])
ins('djnz',     [imm(), u(alu='DEC', ysel='B', rmode='idx', ridx='B', rsrc='alu'),
                 u(nxt='cend', csel='Bnz', t=8),
                 u(asrc='PC', aoff='e', awb='PC', nxt='end', t=13)], [(M, 0x10)])
for o, c in ((0xcd, 'always'), (0xc4, 'IRcc')):
    ins(f'call_{o:02x}', imm16() + [u(nxt='cend', csel=c, t=10),
                                    u(mem='wr', asrc='SP', aoff='-1', wsrc='PCh'),
                                    u(mem='wr', asrc='SP', aoff='-2', awb='SP', wsrc='PCl'),
                                    u(asrc='TMP', awb='PC', nxt='end', t=17)], [(M, o)])
for (p, o), c, t0, t1 in (((M, 0xc9), 'always', 10, 10), ((M, 0xc8), 'IRcc', 5, 11),
                          ((M, 0xd0), 'IRcc', 5, 11), ((ED, 0x4d), 'always', 14, 14)):
    ins(f'ret_{p}_{o:02x}', [u(nxt='cend', csel=c, t=t0),
                             u(mem='rd', asrc='SP', aoff='+1', awb='SP', rmode='TMPlo'),
                             u(mem='rd', asrc='SP', aoff='+1', awb='SP', rmode='TMPhi'),
                             u(asrc='TMP', awb='PC', nxt='end', t=t1)], [(p, o)])
# RST p and the IM 1 interrupt are the same three micro-ops: push PC, then PC
# from IR[5:3] (RSTV). The interrupt enters at 'int_im1' with IR forced to FF
# (rst 38) and takes the Z80's 13 T-states against RST's 11.
for lab, t, codes in (('rst', 11, [(M, 0xcf)]), ('int_im1', 13, [])):
    ins(lab, [u(mem='wr', asrc='SP', aoff='-1', wsrc='PCh'),
              u(mem='wr', asrc='SP', aoff='-2', awb='SP', wsrc='PCl'),
              u(asrc='RSTV', awb='PC', nxt='end', t=t)], codes)
for o, hi, lo in ((0xe5, 'H', 'L'), (0xd5, 'D', 'E')):
    ins(f'push_{o:02x}', [u(mem='wr', asrc='SP', aoff='-1', wsrc='reg', ridx=hi),
                          u(mem='wr', asrc='SP', aoff='-2', awb='SP', wsrc='reg', ridx=lo, nxt='end', t=11)], [(M, o)])
for o, hi, lo in ((0xe1, 'H', 'L'), (0xd1, 'D', 'E')):
    ins(f'pop_{o:02x}', [u(mem='rd', asrc='SP', aoff='+1', awb='SP', rmode='idx', ridx=lo),
                         u(mem='rd', asrc='SP', aoff='+1', awb='SP', rmode='idx', ridx=hi, nxt='end', t=10)], [(M, o)])
ins('ex_sp_hl', [u(mem='rd', asrc='SP', rmode='TMPlo'),
                 u(mem='rd', asrc='SP', aoff='+1', rmode='TMPhi'),
                 u(mem='wr', asrc='SP', wsrc='reg', ridx='L'),
                 u(mem='wr', asrc='SP', aoff='+1', wsrc='reg', ridx='H'),
                 u(asrc='TMP', awb='HL', nxt='end', t=19)], [(M, 0xe3)])
ins('ex_de_hl', [u(asrc='HL', awb='TMP'), u(asrc='DE', awb='HL'),
                 u(asrc='TMP', awb='DE', nxt='end', t=4)], [(M, 0xeb)])
ins('exx',      [u(alu='EXX', nxt='end', t=4)], [(M, 0xd9)])
ins('ex_af',    [u(alu='EXAF', nxt='end', t=4)], [(M, 0x08)])
# rlca / rrca / rra: C only. CB rotates and shifts: S, Z and C. Both by IR[5:3].
ins('rot_a',    [u(alu='IRROT', ysel='IR20', rmode='idx', ridx='A', rsrc='alu', fc=1, nxt='end', t=4)],
    [(M, o) for o in (0x07, 0x0f, 0x1f)])
ins('cpl',      [u(alu='CPL', ysel='IR20', rmode='idx', ridx='A', rsrc='alu', nxt='end', t=4)], [(M, 0x2f)])
ins('rot_r',    [u(alu='IRROT', ysel='IR20', rmode='IR20', rsrc='alu', fz=1, fc=1, nxt='end', t=8)],
    [(CB, o) for o in (0x00, 0x01, 0x07, 0x18, 0x19, 0x1a, 0x1b, 0x27)])
ins('bit_r',    [u(alu='BIT', ysel='IR20', fz=1, nxt='end', t=8)],
    [(CB, o) for o in (0x47, 0x4a, 0x4f, 0x57, 0x5f, 0x64, 0x67)])
ins('out_n_a',  [imm(), u(io='out_n_a', nxt='end', t=11)], [(M, 0xd3)])
ins('in_a_n',   [imm(), u(io='in_a_n', nxt='end', t=11)], [(M, 0xdb)])
ins('out_c_a',  [u(io='out_c_a', nxt='end', t=12)], [(ED, 0x79)])
ins('outi',     [u(mem='rd', asrc='HL'),
                 u(alu='DEC', ysel='B', rmode='idx', ridx='B', rsrc='alu', fz=1),
                 u(asrc='HL', aoff='+1', awb='HL'),
                 u(io='out_c_dat', nxt='end', t=16)], [(ED, 0xa3)])
ins('ldir',     [u(mem='rd', asrc='HL'),
                 u(mem='wr', asrc='DE', wsrc='alu', alu='PASS', ysel='dat'),
                 u(asrc='HL', aoff='+1', awb='HL'),
                 u(asrc='DE', aoff='+1', awb='DE'),
                 u(asrc='BC', aoff='-1', awb='BC'),
                 u(nxt='cend', csel='BCnz', t=16),
                 u(asrc='PC', aoff='-2', awb='PC', nxt='end', t=21)], [(ED, 0xb0)])
ins('im1',      [u(nxt='end', t=8)], [(ED, 0x56)])
ins('di',       [u(alu='DI', nxt='end', t=4)], [(M, 0xf3)])
ins('ei',       [u(alu='EI', nxt='end', t=4)], [(M, 0xfb)])
# ---- IY (FD prefix; IR is the second byte). T-states include the prefix.
ins('ld_iy_nn', imm16() + [u(asrc='TMP', awb='IY', nxt='end', t=14)], [(FD, 0x21)])
ins('inc_iy',   [u(asrc='IY', aoff='+1', awb='IY', nxt='end', t=10)], [(FD, 0x23)])
ins('ld_iyd_r', [imm(), u(mem='wr', asrc='IY', aoff='e', wsrc='alu', alu='PASS', ysel='IR20', nxt='end', t=19)],
    [(FD, o) for o in (0x70, 0x71, 0x77)])
ins('ld_r_iyd', [imm(), u(mem='rd', asrc='IY', aoff='e', rmode='IR53', nxt='end', t=19)], [(FD, 0x7e)])
ins('alu_iyd',  [imm(), u(mem='rd', asrc='IY', aoff='e', alu='IRALU', ysel='dat', rmode='idx', ridx='A', rsrc='alu',
                          fz=1, fc=1, nxt='end', t=19)], [(FD, o) for o in (0x86, 0x8e, 0xbe)])
ins('pop_iy',   [u(mem='rd', asrc='SP', aoff='+1', awb='SP', rmode='TMPlo'),
                 u(mem='rd', asrc='SP', aoff='+1', awb='SP', rmode='TMPhi'),
                 u(asrc='TMP', awb='IY', nxt='end', t=14)], [(FD, 0xe1)])
ins('push_iy',  [u(asrc='IY', awb='TMP'),
                 u(mem='wr', asrc='SP', aoff='-1', wsrc='TMPh'),
                 u(mem='wr', asrc='SP', aoff='-2', awb='SP', wsrc='TMPl', nxt='end', t=15)], [(FD, 0xe5)])
ins('trap_m',   [u(nxt='trap', t=4)], [])
ins('trap_x',   [u(nxt='trap', t=8)], [])

# ---- assemble
rom, addr = [], {}
for label, ops in prog.items():
    addr[label] = len(rom)
    rom.extend(ops)
assert len(rom) <= 256, len(rom)

if __name__ == '__main__':
    logic = '--uent-logic' in sys.argv
    out = []
    out.append('// Generated by tools/dsb/gen_z80_ucode.py -- do not edit.')
    out.append(f'// {len(rom)} micro-ops, {WIDTH} bits; fields MSB first: ' +
               ', '.join(f'{n}[{b}]' for n, b in LAYOUT))
    out.append(f'localparam int UW = {WIDTH};')
    out.append(f"localparam logic [7:0] U_INT = 8'd{addr['int_im1']};   // the IM 1 interrupt's first micro-op")
    # an initialised array, which is what Quartus turns into an M10K ROM --
    # or, with DSB_UROM_LOGIC (Model 2, R979: an M10K back), into LUTs; the
    # read stays registered (uw), so the two are cycle-identical
    out.append('`ifdef DSB_UROM_LOGIC')
    out.append('(* romstyle = "logic" *) logic [UW-1:0] urom [256];')
    out.append('`else')
    out.append('(* romstyle = "M10K" *) logic [UW-1:0] urom [256];')
    out.append('`endif')
    out.append('initial begin')
    for i in range(256):
        w = rom[i] if i < len(rom) else u(nxt='trap', t=4)
        out.append(f"  urom[{i}] = {WIDTH}'h{w:0{(WIDTH+3)//4}x};")
    out.append('end')
    out.append('// dispatch: {pfx, opcode} -> first micro-op, a 1024 x 8 ROM (pfx 0 none, 1 CB,')
    out.append('// 2 ED, 3 FD). Anything absent traps.')
    out.append('`ifndef DSB_UENT_LOGIC')
    out.append('(* romstyle = "M10K" *) logic [7:0] uent [1024];')
    out.append('initial begin')
    for p in range(4):
        for o in range(256):
            lab = entry.get((p, o), 'trap_m' if p == 0 else 'trap_x')
            out.append(f"  uent[{p*256+o}] = 8'd{addr[lab]};")
    out.append('end')
    out.append('`else')
    out.append('// the same table as logic: the opcodes both programs reach, and the two traps')
    out.append('function automatic logic [7:0] uent_f(input logic [9:0] a);')
    out.append('  case (a)')
    for (p, o) in sorted(entry):
        out.append(f"    10'h{p*256+o:03x}: uent_f = 8'd{addr[entry[(p, o)]]};")
    out.append(f"    default: uent_f = (a[9:8] == 2'd0) ? 8'd{addr['trap_m']} : 8'd{addr['trap_x']};")
    out.append('  endcase')
    out.append('endfunction')
    out.append('`endif')
    print('\n'.join(out))
    print(f'{len(rom)} uops, {len(entry)} opcodes', file=sys.stderr)
