# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
# i960 audit against Intel's manuals (docs/i960-intel-audit.md).
import sys, os, subprocess, statistics, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asm import Asm, boot
T = os.path.dirname(os.path.abspath(__file__))
def run(binary, build, rlat=0, wlat=None, ilat=None, maxt=30000, frm=8000):
    a = Asm(0x1000); build(a)
    boot(a.words)
    p = os.path.join(os.getcwd(), 'prog.hex'); a.done(p)   # written where it is run
    wl = rlat if wlat is None else wlat
    il = rlat if ilat is None else ilat
    out = subprocess.run([binary, '+prog='+p, '+rlat=%d'%rlat, '+wlat=%d'%wl, '+ilat=%d'%il, '+max=%d'%maxt, '+from=0'],
                         capture_output=True, text=True).stdout
    acc = []
    for ln in out.splitlines():
        if ln.startswith('A '): _, t, ip = ln.split(); acc.append((int(t), int(ip,16)))
        elif ln.startswith('TRAP'): print('   ', ln)
    d = collections.defaultdict(list)
    for (t0, ip0), (t1, ip1) in zip(acc, acc[1:]):
        if t0 >= frm: d[ip0].append(t1 - t0)
    res = collections.OrderedDict()
    for ip, tg in sorted(a.tags.items()):
        if d.get(ip): res.setdefault(tg, []).extend(d[ip])
    return {k: (statistics.median(v), min(v), max(v), len(v)) for k, v in res.items()}
def loop(setup, body):
    def b(a):
        setup(a); a.L('top'); body(a); a.ctrl('b', 'top', tag='loopb')
    return b
