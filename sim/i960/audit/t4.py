# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
# i960 audit against Intel's manuals (docs/i960-intel-audit.md).
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from run import run, loop
B = sys.argv[1]; LAT = 0; WHICH = sys.argv[2]
def setup(a):
    a.lf('g0', 1.5); a.lf('g1', 2.25); a.ld64('g2', 1.5); a.ld64('g4', 2.25); a.li('g6', 1234); a.li('g7', 3)
    a.lf('g8', 0.7); a.ld64('g10', 0.7); a.lf('g9', 6.2831855)
def rep(op, n=4, **kw):
    def body(a):
        for i in range(n): a.reg(op, tag=op, **kw)
    return body
S = [
 ('movr', dict(dst='g12', src1='g0')),
 ('addr', dict(dst='g12', src1='g0', src2='g1')), ('subr', dict(dst='g12', src1='g0', src2='g1')),
 ('mulr', dict(dst='g12', src1='g0', src2='g1')), ('divr', dict(dst='g12', src1='g0', src2='g1')),
 ('sqrtr', dict(dst='g12', src1='g1')), ('cmpr', dict(src1='g0', src2='g1')),
 ('cvtir', dict(dst='g12', src1='g6')), ('cvtri', dict(dst='g12', src1='g1')), ('cvtzri', dict(dst='g12', src1='g1')),
 ('roundr', dict(dst='g12', src1='g1')), ('scaler', dict(dst='g12', src1='g7', src2='g1')), ('logbnr', dict(dst='g12', src1='g1')),
 ('movrl', dict(dst='g12', src1='g2')),
 ('addrl', dict(dst='g12', src1='g2', src2='g4')), ('subrl', dict(dst='g12', src1='g2', src2='g4')),
 ('mulrl', dict(dst='g12', src1='g2', src2='g4')), ('divrl', dict(dst='g12', src1='g2', src2='g4')),
 ('cmprl', dict(src1='g2', src2='g4')), ('cvtzril', dict(dst='g12', src1='g4')), ('cvtril', dict(dst='g12', src1='g4')),
 ('cvtilr', dict(dst='g12', src1='g6')),
 ('cpysre', dict(dst=1, src1=0, src2=0x16, lit1=True, lit2=True, m3=True)),
 ('movre', dict(dst=1, src1='g2', m3=True)),
 ('sqrtrl', dict(dst='g12', src1='g4')),
 ('sinr', dict(dst='g12', src1='g8')), ('cosr', dict(dst='g12', src1='g8')), ('tanr', dict(dst='g12', src1='g8')),
 ('atanr', dict(dst='g12', src1='g0', src2='g1')), ('remr', dict(dst='g12', src1='g9', src2='g8')),
 ('sinrl', dict(dst='g12', src1='g10')), ('cosrl', dict(dst='g12', src1='g10')), ('tanrl', dict(dst='g12', src1='g10')),
 ('atanrl', dict(dst='g12', src1='g2', src2='g4')),
 ('expr', dict(dst='g12', src1='g8')), ('logr', dict(dst='g12', src1='g8')),
]
for op, kw in S:
    r = run(B, loop(setup, rep(op, **kw)), rlat=LAT, maxt=40000, frm=10000)
    print('%s %-8s' % (WHICH, op), {k: v[0] for k, v in r.items()} or 'TRAP/none')
