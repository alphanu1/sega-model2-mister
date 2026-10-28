# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
# i960 audit against Intel's manuals (docs/i960-intel-audit.md).
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from run import run, loop
B = sys.argv[1]; LAT = int(sys.argv[2]) if len(sys.argv) > 2 else 0
def setup(a):
    for i, r in enumerate(['g0','g1','g2','g3','g4','g5','g6','g7']): a.li(r, 0x1234567 * (i+1) & 0x7fffffff)
    a.li('g8', 5); a.li('g9', 3); a.li('g10', 0x500000); a.li('g11', 7)
def rep(op, n=6, **kw):
    def body(a):
        for i in range(n): a.reg(op, tag=op, **kw)
    return body
tests = [
 ('addo reg,reg', rep('addo', dst='g12', src1='g0', src2='g1')),
 ('addo lit,reg', rep('addo', dst='g12', src1=3, src2='g1', lit1=True)),
 ('and', rep('and', dst='g12', src1='g0', src2='g1')),
 ('shlo', rep('shlo', dst='g12', src1='g8', src2='g1')),
 ('shri', rep('shri', dst='g12', src1='g8', src2='g1')),
 ('rotate', rep('rotate', dst='g12', src1='g8', src2='g1')),
 ('setbit', rep('setbit', dst='g12', src1='g8', src2='g1')),
 ('chkbit', rep('chkbit', src1='g8', src2='g1')),
 ('cmpo', rep('cmpo', src1='g0', src2='g1')),
 ('cmpinco', rep('cmpinco', dst='g12', src1='g0', src2='g1')),
 ('addc', rep('addc', dst='g12', src1='g0', src2='g1')),
 ('mov', rep('mov', dst='g12', src1='g0')),
 ('movl', rep('movl', dst='g12', src1='g0')),
 ('movt', rep('movt', dst='g12', src1='g0')),
 ('movq', rep('movq', dst='g12', src1='g0')),
 ('scanbit', rep('scanbit', dst='g12', src1='g1')),
 ('spanbit', rep('spanbit', dst='g12', src1='g1')),
 ('scanbyte', rep('scanbyte', src1='g0', src2='g1')),
 ('modac', rep('modac', dst='g12', src1='g13', src2='g13')),
 ('extract', rep('extract', dst='g12', src1='g8', src2='g9')),
 ('modify', rep('modify', dst='g12', src1='g8', src2='g9')),
 ('mulo 3-bit src1', rep('mulo', dst='g12', src1='g9', src2='g1')),
 ('mulo 31-bit src1', rep('mulo', dst='g12', src1='g1', src2='g9')),
 ('muli', rep('muli', dst='g12', src1='g1', src2='g9')),
 ('divo', rep('divo', dst='g12', src1='g9', src2='g1')),
 ('divi', rep('divi', dst='g12', src1='g9', src2='g1')),
 ('remo', rep('remo', dst='g12', src1='g9', src2='g1')),
 ('remi', rep('remi', dst='g12', src1='g9', src2='g1')),
 ('modi', rep('modi', dst='g12', src1='g9', src2='g1')),
 ('emul', rep('emul', dst='g12', src1='g1', src2='g9')),
 ('ediv', rep('ediv', dst='g12', src1='g9', src2='g0')),
]
for name, body in tests:
    r = run(B, loop(setup, body), rlat=LAT)
    print('%-18s' % name, {k: v for k, v in r.items()})
