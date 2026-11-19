#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- R1050: a directed 68000 program for the 2A sound bench
# (tb_m2_2a_sound, SND_IMG=<dir>): the forms that can write one register through both of fx68k's
# write ports (Rx and Ry) -- an address register loaded from its own post-increment / pre-decrement,
# ADDA / SUBA from (An)+ / -(An) into An, EXG of a register with itself and of two, CMPM / ADDX / SUBX
# / ABCD with both operands -(An) / (An)+ on one An, MOVEM of a list holding its base, LINK / UNLK on
# A6 and A7, MOVEA (A7)+,A7 -- each followed by a store of the registers it wrote, so a wrong winner
# shows on the bus. Hand-assembled (the encodings beside each word), looped with a counter mixed in.
# Generated, not ROM-derived. Writes <dir>/prog.bin (512 KB, the ROM at 0x600000) and samp.bin.
import os, struct, sys

ORG = 0x601000
code = []
labels = {}
def w(*ws): code.extend(ws)
def here(): return ORG + 2 * len(code)
def l32(v): return [(v >> 16) & 0xffff, v & 0xffff]
def movea_l(n, v): w(0x207C | (n << 9), *l32(v))          # MOVEA.L #v,An
def move_l_d(n, v): w(0x203C | (n << 9), *l32(v))         # MOVE.L #v,Dn
def st_a(n): w(0x2AC8 | n)                                # MOVE.L An,(A5)+
def st_d(n): w(0x2AC0 | n)                                # MOVE.L Dn,(A5)+

labels['loop'] = here()
movea_l(5, 0x3000)                                        # the log pointer
movea_l(0, 0x2000)
w(0x2C07)                                                 # MOVE.L D7,D6
w(0x7A3F)                                                 # MOVEQ #63,D5 (64 longs)
labels['fill'] = here()
w(0x20C6)                                                 # MOVE.L D6,(A0)+
w(0x0686, *l32(0x01020305))                               # ADDI.L #$01020305,D6
w(0x51CD, (labels['fill'] - (here() + 2)) & 0xffff)       # DBF D5,fill
tests = [
    (0, 0x2000, [0x2058], ['a0']),                        # MOVEA.L (A0)+,A0
    (1, 0x2010, [0x3259], ['a1']),                        # MOVEA.W (A1)+,A1
    (2, 0x2024, [0x2462], ['a2']),                        # MOVEA.L -(A2),A2
    (3, 0x2030, [0xD7DB], ['a3']),                        # ADDA.L (A3)+,A3
    (4, 0x2040, [0x99DC], ['a4']),                        # SUBA.L (A4)+,A4
    (0, 0x2050, [0xD0D8], ['a0']),                        # ADDA.W (A0)+,A0
    (1, 0x2062, [0x92E1], ['a1']),                        # SUBA.W -(A1),A1
    (6, 0x2068, [0x2C66], ['a6']),                        # MOVEA.L -(A6),A6
    (0, 0x2084, [0xB188], ['a0']),                        # CMPM.L (A0)+,(A0)+
    (0, 0x20A8, [0xD188], ['a0']),                        # ADDX.L -(A0),-(A0)
    (0, 0x20B8, [0x9188], ['a0']),                        # SUBX.L -(A0),-(A0)
    (0, 0x20C3, [0xC108], ['a0']),                        # ABCD -(A0),-(A0)
    (1, 0x20C8, [0xB349], ['a1']),                        # CMPM.W (A1)+,(A1)+
    (0, 0x20D0, [0x4CD8, 0x0103], ['a0', 'd0', 'd1']),    # MOVEM.L (A0)+,D0-D1/A0
    (2, 0x20E0, [0x4CDA, 0x0400], ['a2']),                # MOVEM.L (A2)+,A2
]
for n, a, ops, outs in tests:
    movea_l(n, a)
    w(*ops)
    for o in outs: (st_a if o[0] == 'a' else st_d)(int(o[1]))
# EXG: distinct values, the counter mixed in
for k, v in enumerate([0x11112222, 0x33334444, 0x55556666, 0x77778888]):
    move_l_d(k, v); w(0xD087 | (k << 9))                  # ADD.L D7,Dk
movea_l(0, 0x9999AAAA & 0x00FFFFFE); movea_l(3, 0x00BBCCDE)
w(0xC140)                                                 # EXG D0,D0
w(0xC342)                                                 # EXG D1,D2
w(0xC148)                                                 # EXG A0,A0
w(0xC78B)                                                 # EXG D3,A3
w(0xC388)                                                 # EXG D1,A0
for o in ['d0', 'd1', 'd2', 'd3', 'a0', 'a3']: (st_a if o[0] == 'a' else st_d)(int(o[1]))
# LINK / UNLK on A6 and on A7 (the stack pointer: both ports name SSP)
movea_l(6, 0x00002F00)
w(0x4E56, 0xFFF8)                                         # LINK A6,#-8
st_a(6); w(0x2ACF)                                        # MOVE.L A7,(A5)+
w(0x4E5E)                                                 # UNLK A6
st_a(6); w(0x2ACF)
w(0x4E57, 0xFFFC)                                         # LINK A7,#-4
w(0x2ACF)
w(0x4E5F)                                                 # UNLK A7
w(0x2ACF)
w(0x2F07)                                                 # MOVE.L D7,-(A7)
w(0x2E5F)                                                 # MOVEA.L (A7)+,A7
w(0x2ACF)
movea_l(7, 0x00005000)                                    # the stack back
w(0x5287)                                                 # ADDQ.L #1,D7
w(0x6000, (labels['loop'] - (here() + 2)) & 0xffff)      # BRA.W loop

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
rom = bytearray(b'\xff' * 0x80000)
vec = struct.pack('>IIII', 0x00005000, ORG, ORG + 2 * len(code) + 0x100, ORG + 2 * len(code) + 0x100)
rom[0:16] = vec
for i, x in enumerate(code):
    rom[ORG - 0x600000 + 2 * i: ORG - 0x600000 + 2 * i + 2] = struct.pack('>H', x)
# the bus / address error vectors land on a BRA.S to itself (a fault shows as a stall, and the
# lockstep still compares)
e = ORG - 0x600000 + 2 * len(code) + 0x100
rom[e:e + 2] = struct.pack('>H', 0x60FE)
open(os.path.join(out, 'prog.bin'), 'wb').write(rom)
open(os.path.join(out, 'samp.bin'), 'wb').write(b'\0' * 0x10000)
print('%d words at %06x, loop %06x' % (len(code), ORG, labels['loop']))
