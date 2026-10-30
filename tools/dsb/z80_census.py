#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
# (from the Sega Model 1 core, sega-model1-mister 2657c46, tools/dsb/z80_census.py)
#
# Which Z80 opcodes can a DSB program execute? Traced statically from MAME's
# own disassembly of it: from the reset vector, the IM 1 vector (0x38) and any
# extra entry points given, following every branch, call, RST and
# fall-through. A JP (HL), JP (IX) or anything else whose target cannot be
# known statically ENDS that trace path; the program's jump tables must then be
# named as extra entry points, and an indirect jump that is not covered by them
# is the caller's job to rule out (it is printed as a note, not skipped
# silently).
#
# Then every reached opcode is checked against dsb_z80's dispatch table
# (tools/dsb/gen_z80_ucode.py): one missing is a FAIL, which is what lets
# dsb_z80 implement those and nothing else. Prefixes: CB, ED and FD (IY) are
# dispatched; DD (IX) and FD CB are not, and fail.
#
#   the disassembly, headless:
#     mame <set> -debug -debugger none -video none -sound none ... and the
#     debugger command  dasm <file>,0,8000,1,:dsbz80:mpegcpu
#   python3 tools/dsb/z80_census.py <z80.asm> [entry ...]
#
# The two programs this core runs (entry points in hex):
#   Star Wars (epr-16471.2):   z80_census.py z80.asm
#   STCC (epr-19275.2s):       z80_census.py z80.asm 02e0 02e6 032d 034f 0498 04a3 04ab 04c0
#     -- the two 4-entry jump tables at 02D8 (commands 60-63, entered by
#        push de / ret at 02C2-02D7) and 04D7 (song-script codes F0-F3,
#        entered by JP (HL) at 0497). Both are indexed by a value that is
#        range-checked first (cp 4 / jp nc at 02B2; sub F0 after cp F0 / jp nc
#        at 0437 on a byte < 0x100), so these eight are all their targets.
import os, re, sys, importlib.util

ins = {}
for l in open(sys.argv[1]):
    m = re.match(r'([0-9A-F]{4}): ((?:[0-9A-F]{2} )+)\s*(.*)', l.rstrip())
    if m:
        ins[int(m.group(1), 16)] = (m.group(2).split(), m.group(3).strip())

extra = [int(a, 16) for a in sys.argv[2:]]
seen, work, ops, bad, notes = set(), [0x0000, 0x0038] + extra, {}, 0, []
while work:
    a = work.pop()
    while a not in seen:
        if a not in ins:
            print(f'FAIL: no instruction at {a:04x} (misaligned trace)'); bad += 1; break
        seen.add(a)
        b, t = ins[a]
        if b[0] == 'DD' or (b[0] == 'FD' and b[1] == 'CB'):
            print(f'FAIL: IX / FD CB at {a:04x}: {t}'); bad += 1
        pf = {'CB': 1, 'ED': 2, 'FD': 3}.get(b[0], 0)
        key = (pf, int(b[1] if pf else b[0], 16))
        ops.setdefault(key, set()).add(re.sub(r'\$[0-9A-F]+', 'n', t))
        mn = t.split()[0]
        if '(' in t and mn == 'jp':
            notes.append(f'note: indirect jump at {a:04x}: {t} -- its targets must be entry points')
            break
        tgt = re.search(r'\$([0-9A-F]{4})$', t)
        if mn in ('jp', 'jr', 'call', 'djnz') and tgt:
            work.append(int(tgt.group(1), 16))
        if mn in ('jp', 'jr') and ',' not in t: break
        if mn in ('ret', 'reti', 'retn') and len(t.split()) == 1: break
        if mn == 'rst':
            work.append(int(t.split()[1].lstrip('$'), 16))
        a += len(b)

spec = importlib.util.spec_from_file_location('g', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'gen_z80_ucode.py'))
src = open(spec.origin).read().split('# ---- assemble')[0]   # the tables, not the output
g = {}
exec(compile(src, spec.origin, 'exec'), g)
entry = g['entry']
pfx = ['', 'CB ', 'ED ', 'FD ']
for n in notes: print(n)
for k in sorted(ops):
    have = k in entry
    if not have: bad += 1
    print(f"{'ok  ' if have else 'FAIL'} {pfx[k[0]]}{k[1]:02X}  {sorted(ops[k])[0]}")
print(f'{len(seen)} instructions reachable, {len(ops)} distinct opcodes, '
      f'{len(entry)} implemented, {bad} problems')
sys.exit(1 if bad else 0)
