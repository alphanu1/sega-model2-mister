#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# Every instruction of a sound driver's code that WRITES through the SCSP
# base register (or an absolute SCSP address), from snd_dasm.py's listing
# (study R856): the static half of "what can the driver set".
#   snd_scsp_writes.py <asm> <code end hex> <base reg, e.g. a5>
import sys, re
asm, end, base = sys.argv[1], int(sys.argv[2], 16), sys.argv[3]
WR = re.compile(r'^(move|clr|or|and|eor|bset|bclr|bchg|add|sub|not|neg|st|sf|lsl|lsr|asl|asr|rol|ror)')
for l in open(asm):
    m = re.match(r'^([0-9a-f]+): (\S+)\s+(\S+)\s*(.*)$', l.strip())
    if not m: continue
    a = int(m.group(1), 16)
    if a >= end: continue
    mn, ops = m.group(3), m.group(4)
    if not WR.match(mn): continue
    # destination: the last operand (split on commas outside parentheses)
    depth, parts, cur = 0, [], ''
    for ch in ops:
        if ch == '(': depth += 1
        if ch == ')': depth -= 1
        if ch == ',' and depth == 0: parts.append(cur.strip()); cur = ''
        else: cur += ch
    parts.append(cur.strip())
    dst = parts[-1]
    if ('(' + base) in dst or re.search(r'\$10[0-9a-f]{4}\.l', dst):
        print('%06x  %-8s %s' % (a, mn, ops))
