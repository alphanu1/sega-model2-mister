#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- R1039: a random printable string as long as the 2B build's
# CONF_STR (and a copy with one byte changed) for sim/io/tb_hps_cfgstr.sv.
#   cfgstr_test.py <out.svh> [bytes] [seed]
import random, sys
n = int(sys.argv[2]) if len(sys.argv) > 2 else 962
g = random.Random(int(sys.argv[3]) if len(sys.argv) > 3 else 1)
s = ''.join(chr(g.randrange(0x20, 0x7f)) for _ in range(n)).replace('\\', '/').replace('"', "'")
k = g.randrange(n); p = s[:k] + ('A' if s[k] != 'A' else 'B') + s[k + 1:]
open(sys.argv[1], 'w').write('localparam int N = %d;\nlocalparam CS = "%s";\nlocalparam CS_P = "%s";\n' % (n, s, p))
