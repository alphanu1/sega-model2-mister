#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# THE INSTRUCTIONS A GAME EXECUTES, from a MAME i960 trace (loops not
# collapsed: sim/io/mame_m2_trace_window.lua or tools/i960-trace.sh), as a set:
# mnemonic, operand form (register / literal / memory addressing mode), count,
# first and last PC, and the window's distinct PCs. Two sets diffed say which
# instructions one game runs that the other never does (R836).
#
#   i960_opset.py <trace> [<trace> ...] > set.txt
#   i960_opset.py --diff <set A> <set B>   lines in A whose key is absent from B
import re, sys
from collections import defaultdict

LINE = re.compile(r'^([0-9A-Fa-f]{8}): (\S+)\s*(.*)$')


def form(ops):
    """Operand form: registers -> R, literals -> L, memory operands by mode."""
    out = []
    for o in [x.strip() for x in re.split(r',(?![^(\[]*[)\]])', ops) if x.strip()]:
        if re.fullmatch(r'(g|r)\d+|fp|sp|pfp|rip', o):
            out.append('R')
        elif re.fullmatch(r'fp\d', o):
            out.append('FPR')
        elif re.fullmatch(r'-?(0x)?[0-9a-fA-F]+', o) and '(' not in o:
            out.append('L')
        else:
            m = re.sub(r'0x[0-9a-fA-F]+|\b\d+\b', 'd', o)
            m = re.sub(r'\b(g|r)\d+\b|\bfp\b|\bsp\b|\bpfp\b', 'r', m)
            out.append('M[' + m + ']')
    return ','.join(out)


def collect(paths):
    st = defaultdict(lambda: [0, None, None])
    pcs = set()
    for p in paths:
        with open(p, errors='replace') as f:
            for ln in f:
                mm = LINE.match(ln.rstrip('\n'))
                if not mm:
                    continue
                pc, mn, ops = mm.group(1).lower(), mm.group(2), mm.group(3)
                pcs.add(pc)
                k = mn + ' ' + form(ops)
                e = st[k]
                e[0] += 1
                if e[1] is None:
                    e[1] = pc
                    e[2] = ops
    return st, pcs


def main():
    if sys.argv[1] == '--diff':
        a = [l.rstrip('\n') for l in open(sys.argv[2]) if not l.startswith('#')]
        b = {l.split('\t')[0] for l in open(sys.argv[3]) if not l.startswith('#')}
        for l in a:
            if l.split('\t')[0] not in b:
                print(l)
        return
    st, pcs = collect(sys.argv[1:])
    print('# %d distinct pcs, %d instruction forms, %d instructions' % (len(pcs), len(st), sum(e[0] for e in st.values())))
    for k in sorted(st):
        n, pc, ex = st[k]
        print('%s\t%d\t%s\t%s' % (k, n, pc, ex))


if __name__ == '__main__':
    main()
