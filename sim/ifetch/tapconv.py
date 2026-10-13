# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1 (R817)
# tapconv.py <window.da> <window.tr> <out.ipd>
# The MAME tap log (every read/write the i960 makes, tagged pip/ip) -> per-
# instruction records: u32 ip, u32 n, then n x (u32 addr|we, u32 byte enables).
# An instruction starts at a fetch record (pip == ip == offset, full dword);
# data records are pip != ip and offset != ip, outside program ROM (the tap
# also logs the accessor's own refills of code blocks, which are not
# accesses the CPU makes). Consecutive starts of one address (MAME's stall
# re-execution) are merged, as trconv.py drops them from the trace. The
# instruction sequence is checked against the trace's.
import sys, array
def is_rom(a): return a < 0x200000 or (0x220000 <= a < 0x240000)
out = array.array('I')
insts = []           # (ip, [(addr|we, be)])
cur = None
frames = 0
for l in open(sys.argv[1]):
    if l.startswith('M2FRAME'):
        if cur is not None: insts.append(cur); cur = None
        insts.append((0xffffffff, [])); frames += 1; continue
    p = l.split()
    if len(p) != 5: continue
    pip = int(p[0], 16); ip = int(p[1], 16); rw = p[2]; off = int(p[3], 16); mask = int(p[4], 16)
    if pip == ip and off == ip and mask == 0xffffffff and rw == 'r':
        if cur is not None and cur[0] == ip and not cur[1]:
            continue                       # stall re-execution of a start with no data yet
        if cur is not None and cur[0] == ip:
            continue                       # re-execution: keep the records gathered so far
        if cur is not None: insts.append(cur)
        cur = (ip, [])
        continue
    if pip == ip or off == ip or off == ip - 4: continue    # fetch, displacement, or their byte lanes
    if is_rom(off): continue
    if cur is None or cur[0] != pip: continue
    be = 0
    for b in range(4):
        if (mask >> (8 * b)) & 0xff: be |= 1 << b
    cur[1].append(((off & ~3) | (1 if rw == 'w' else 0), be))
if cur is not None: insts.append(cur)
# compare with the trace's deduplicated stream
tr = []
last = None
for l in open(sys.argv[2], errors='ignore'):
    if l.startswith('M2FRAME'): tr.append(0xffffffff); last = None; continue
    if len(l) < 10 or l[8] != ':': continue
    a = int(l[:8], 16)
    if a == last: continue
    tr.append(a); last = a
ti = [i[0] for i in insts]
same = sum(1 for a, b in zip(ti, tr) if a == b)
first_diff = next((k for k, (a, b) in enumerate(zip(ti, tr)) if a != b), None)
print("%s: %d instructions from taps, %d in the trace, %d agree in order; first difference at %s; data accesses %d" % (
      sys.argv[1], len(ti), len(tr), same, first_diff, sum(len(i[1]) for i in insts)))
for ip, recs in insts:
    out.append(ip); out.append(len(recs))
    for a, b in recs: out.append(a); out.append(b)
open(sys.argv[3], 'wb').write(out.tobytes())
