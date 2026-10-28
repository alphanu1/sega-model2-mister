# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
# i960 audit against Intel's manuals (docs/i960-intel-audit.md).
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from run import run
B = sys.argv[1]; LAT = int(sys.argv[2])
for depth in (1, 3, 5, 8):
    def b(a, depth=depth):
        a.L('top'); a.ctrl('call', 'f1', tag='call'); a.ctrl('b', 'top', tag='loopb')
        for d in range(1, depth + 1):
            a.L('f%d' % d)
            if d < depth: a.ctrl('call', 'f%d' % (d + 1), tag='call')
            else: a.reg('flushreg', tag='flushreg')
            a.ctrl('ret', 'top', tag='ret')
    r = run(B, b, rlat=LAT, maxt=80000, frm=30000)
    print('depth', depth, {k: v for k, v in r.items()})
