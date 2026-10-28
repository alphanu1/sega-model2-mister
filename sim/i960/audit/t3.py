# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
# i960 audit against Intel's manuals (docs/i960-intel-audit.md).
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from run import run, loop
B = sys.argv[1]; LAT = int(sys.argv[2]); DATA = int(sys.argv[3], 16) if len(sys.argv) > 3 else 0x500000
def setup(a):
    a.li('g10', DATA); a.li('g0', 1); a.li('g1', 2)
def skip(a, lbl):  # one dead word then the label
    a.reg('addo', dst='g14', src1='g0', src2='g0', tag='dead'); a.L(lbl)
def br(a):
    for i in range(3):
        a.reg('cmpo', src1='g0', src2='g0', tag='cmpo'); a.ctrl('be', 't%d' % i, tag='be taken'); skip(a, 't%d' % i)
    for i in range(3):
        a.reg('cmpo', src1='g0', src2='g1', tag='cmpo'); a.ctrl('be', 'n%d' % i, tag='be not taken'); a.reg('addo', dst='g14', src1='g0', src2='g0', tag='ft'); a.L('n%d'%i)
    for i in range(3):
        a.cobr('cmpobe', 'g0', 'g0', 'd%d' % i, tag='cmpobe taken'); skip(a, 'd%d' % i)
    for i in range(3):
        a.cobr('cmpobne', 'g0', 'g0', 'c%d' % i, tag='cmpobne not taken'); a.reg('addo', dst='g14', src1='g0', src2='g0', tag='ft'); a.L('c%d'%i)
    for i in range(3):
        a.ctrl('b', 'e%d' % i, tag='b'); skip(a, 'e%d' % i)
    for i in range(3):
        a.cobr('bbs', 0, 'g0', 'f%d' % i, lit1=True, tag='bbs taken'); skip(a, 'f%d' % i)
    for i in range(3):
        a.ctrl('bal', 'h%d' % i, tag='bal'); skip(a, 'h%d' % i)
def bx(a):
    for i in range(3):
        a.memb('lda', 'g5', 0xc, disp=0, tag='lda tgt'); fix = a.pc - 4
        a.memb('bx', 0, 0x4, abase='g5', tag='bx (g5)'); skip(a, 'x%d' % i); a.words[fix] = a.labels['x%d' % i]
def calls(depth):
    def build(a):
        a.li('g10', DATA); a.L('top')
        a.ctrl('call', 'f1', tag='call d1'); a.ctrl('b', 'top', tag='loopb')
        for d in range(1, depth + 1):
            a.L('f%d' % d)
            if d < depth: a.ctrl('call', 'f%d' % (d + 1), tag='call d%d' % (d + 1))
            a.ctrl('ret', None or 'top', tag='ret d%d' % d)   # ret ignores disp
    return build
def flush(a):
    a.reg('flushreg', tag='flushreg')
print('== rlat=wlat=%d' % LAT)
for name, b in [('branch', loop(setup, br)), ('bx', loop(setup, bx))]:
    r = run(B, b, rlat=LAT); print('  %-8s' % name, {k: v[0] for k, v in r.items() if k not in ('dead','ft')})
for depth in (1, 2, 3, 4, 5, 6, 8, 9, 10):
    r = run(B, calls(depth), rlat=LAT, maxt=60000, frm=20000)
    print('  depth %-2d' % depth, {k: v[0] for k, v in r.items()})
def fl(a):
    a.li('g10', DATA); a.L('top'); a.ctrl('call', 'f1', tag='call'); a.ctrl('b', 'top', tag='loopb')
    a.L('f1'); a.reg('flushreg', tag='flushreg d1'); a.ctrl('ret', 'top', tag='ret after flush')
r = run(B, fl, rlat=LAT); print('  flushreg', {k: v[0] for k, v in r.items()})
