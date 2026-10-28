# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
# i960 audit against Intel's manuals (docs/i960-intel-audit.md).
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from run import run, loop
B = sys.argv[1]; WHICH = sys.argv[2]
def mk(setfn, op, **kw):
    def body(a):
        for i in range(4): a.reg(op, tag=op, **kw)
    return loop(setfn, body)
for (x, y) in [(3, 7), (3, 0x7fffffff), (0x7fff, 0x7fffffff), (1, 1), (0xffff, 5)]:
    def s(a, x=x, y=y): a.li('g0', x); a.li('g1', y)
    for op in ('divo', 'mulo'):
        r = run(B, mk(s, op, dst='g12', src1='g0', src2='g1'))
        print(WHICH, op, hex(x), hex(y), {k: v[0] for k, v in r.items()})
if WHICH == '2a':
    for (x, y) in [(0.7, 6.2831855), (100.0, 0.7), (1e6, 0.7), (1e30, 3.0)]:
        def s(a, x=x, y=y): a.lf('g8', x); a.lf('g9', y)
        r = run(B, mk(s, 'remr', dst='g12', src1='g9', src2='g8'), maxt=200000, frm=20000)
        print(WHICH, 'remr', x, y, {k: v[0] for k, v in r.items()})
    for x in (0.001, 0.25, 1.5, 3.0, 100.0, 3e4):
        def s(a, x=x): a.lf('g8', x); a.lf('g9', 1.0)
        for op in ('sinr', 'cosr', 'tanr'):
            r = run(B, mk(s, op, dst='g12', src1='g8'), maxt=100000, frm=20000)
            print(WHICH, op, x, {k: v[0] for k, v in r.items()})
        r = run(B, mk(s, 'atanr', dst='g12', src1='g9', src2='g8'), maxt=100000, frm=20000)
        print(WHICH, 'atanr', x, {k: v[0] for k, v in r.items()})
