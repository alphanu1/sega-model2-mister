# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1 (R817)
# trconv.py <trace.tr> <out.ips> : MAME i960 trace -> u32 IP stream (consecutive repeats = MAME stall re-executions, dropped),
# frame markers as 0xFFFFFFFF.
import sys, struct, array
out = array.array('I'); last = None; rep = 0; n = 0
for l in open(sys.argv[1], errors='ignore'):
    if l.startswith('M2FRAME'):
        out.append(0xffffffff); last = None; continue
    if len(l) < 10 or l[8] != ':': continue
    try: a = int(l[:8], 16)
    except ValueError: continue
    if a == last: rep += 1; continue
    out.append(a); last = a; n += 1
open(sys.argv[2], 'wb').write(out.tobytes())
print("%s: %d instructions, %d stall repeats dropped" % (sys.argv[1], n, rep))
