# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
# i960 audit against Intel's manuals (docs/i960-intel-audit.md).
import sys, os, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asm import Asm, boot
B = sys.argv[1]; LAT = int(sys.argv[2])
a = Asm(0x1000)
a.L('top')
for i in range(8): a.reg('addo', dst='g12', src1='g0', src2='g1', tag='alu')
a.ctrl('b', 'top', tag='loopb')
a.pc = 0x3000; a.L('h'); a.tag('h0'); a.reg('addo', dst='g13', src1='g0', src2='g1'); a.ctrl('ret', 'h', tag='ret7')
boot(a.words)
a.words[0x900 + 36 + (0xff - 8) * 4] = 0x3000
a.words[0x900] = 0   # pending priorities
a.done(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'irq.hex'))
out = subprocess.run([B, '+prog=irq.hex', '+rlat=%d' % LAT, '+max=4000', '+irqat=2000'], capture_output=True, text=True).stdout
lines = [l for l in out.splitlines() if l.startswith(('A ', 'IRQ', 'B ', 'TRAP'))]
i = [k for k, l in enumerate(lines) if l.startswith('IRQ')][0]
print('\n'.join(lines[i-3:i+40]))
