# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
# i960 audit against Intel's manuals (docs/i960-intel-audit.md).
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from run import run, loop
B = sys.argv[1]; LATS = [int(x) for x in sys.argv[2].split(',')]
DATA = int(sys.argv[3], 16) if len(sys.argv) > 3 else 0x500000
def setup(a):
    a.li('g10', DATA); a.li('g8', 5); a.li('g9', 3); a.li('g0', 1); a.li('g1', 2)
def mem(op, n=6, mode=None, dst='g12'):
    def body(a):
        for i in range(n):
            if mode == 'mema':  a.mema(op, dst, (i*16) & 0xfff, abase='g10', tag=op)
            elif mode == 'disp': a.memb(op, dst, 0xd, abase='g10', disp=i*16, tag=op)
            else: a.memb(op, dst, 0x4, abase='g10', tag=op)
    return body
def dep_ld(a):   # load then immediate use
    for i in range(4):
        a.mema('ld', 'g12', i*16, abase='g10', tag='ld(use next)'); a.reg('addo', dst='g13', src1='g12', src2='g12', tag='use')
def indep_ld(a):
    for i in range(4):
        a.mema('ld', 'g12', i*16, abase='g10', tag='ld(no use)'); a.reg('addo', dst='g13', src1='g0', src2='g1', tag='alu')
def br(a):
    # conditional branch not taken / taken, cmp+b, compare-and-branch
    for i in range(3):
        a.reg('cmpo', src1='g0', src2='g1', tag='cmpo'); a.ctrl('be', 'n%d' % i, tag='be not taken'); a.L('n%d' % i)
    for i in range(3):
        a.reg('cmpo', src1='g0', src2='g0', tag='cmpo'); a.ctrl('be', 't%d' % i, tag='be taken'); a.L('t%d' % i)
    for i in range(3):
        a.cobr('cmpobe', 'g0', 'g1', 'c%d' % i, tag='cmpobe not taken'); a.L('c%d' % i)
    for i in range(3):
        a.cobr('cmpobe', 'g0', 'g0', 'd%d' % i, tag='cmpobe taken'); a.L('d%d' % i)
    for i in range(3):
        a.ctrl('b', 'e%d' % i, tag='b'); a.L('e%d' % i)
    for i in range(3):
        a.cobr('bbs', 0, 'g0', 'f%d' % i, lit1=True, tag='bbs taken'); a.L('f%d' % i)
    for i in range(3):
        a.cobr('teste', 'g12', 0, 'x', tag='teste')
    a.L('x')
for lat in LATS:
    print('== rlat=wlat=%d' % lat)
    for name, body in [('ld', mem('ld')), ('ld mema', mem('ld', mode='mema')), ('ld disp(2w)', mem('ld', mode='disp')),
                       ('ldob', mem('ldob')), ('ldl', mem('ldl')), ('ldt', mem('ldt')), ('ldq', mem('ldq')),
                       ('st', mem('st')), ('stob', mem('stob')), ('stl', mem('stl')), ('stq', mem('stq')),
                       ('lda', mem('lda', mode='mema')), ('lda disp', mem('lda', mode='disp')),
                       ('dep', dep_ld), ('indep', indep_ld), ('branch', br)]:
        r = run(B, loop(setup, body), rlat=lat)
        print('  %-12s' % name, {k: v[0] for k, v in r.items()})
