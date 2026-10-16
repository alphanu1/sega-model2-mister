#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# What a Model 2A game asks of the SCSP, its DSP and its 68000 (study R856),
# from one instrumented MAME run (build/mame_patches/p16, M2SCSP_OUT=<dir>,
# driven by sim/sound/mame_m2_2a_snd.lua).
#
#   scsp_usage.py <dir> [<dir> ...]
import os, struct, sys, collections
import numpy as np

REC = np.dtype([('n', '<u4'), ('off', '<u2'), ('data', '<u2'), ('mask', '<u2'), ('pad', '<u2')])
RAMW = np.dtype([('n', '<u4'), ('a', '<u4'), ('dm', '<u4')])

FS = 22579200 / 512

def rd(path, fmt):
    sz = struct.calcsize(fmt)
    data = open(path, 'rb').read()
    return [struct.unpack_from(fmt, data, i) for i in range(0, len(data) - sz + 1, sz)]

def slot_fields(r):
    d = r
    return dict(
        kx=(d[0] >> 12) & 1, kb=(d[0] >> 11) & 1, sbctl=(d[0] >> 9) & 3, ssctl=(d[0] >> 7) & 3,
        lpctl=(d[0] >> 5) & 3, pcm8=(d[0] >> 4) & 1, sa=((d[0] & 0xf) << 16) | d[1], lsa=d[2], lea=d[3],
        d2r=(d[4] >> 11) & 31, d1r=(d[4] >> 6) & 31, eghold=(d[4] >> 5) & 1, ar=d[4] & 31,
        lpslnk=(d[5] >> 14) & 1, krs=(d[5] >> 10) & 15, dl=(d[5] >> 5) & 31, rr=d[5] & 31,
        stwinh=(d[6] >> 9) & 1, sdir=(d[6] >> 8) & 1, tl=d[6] & 0xff,
        mdl=(d[7] >> 12) & 15, mdxsl=(d[7] >> 6) & 63, mdysl=d[7] & 63,
        oct=(d[8] >> 11) & 15, fns=d[8] & 0x3ff,
        lfore=(d[9] >> 15) & 1, lfof=(d[9] >> 10) & 31, plfows=(d[9] >> 8) & 3, plfos=(d[9] >> 5) & 7,
        alfows=(d[9] >> 3) & 3, alfos=d[9] & 7,
        isel=(d[10] >> 3) & 15, imxl=d[10] & 7,
        disdl=(d[11] >> 13) & 7, dipan=(d[11] >> 8) & 31, efsdl=(d[11] >> 5) & 7, efpan=d[11] & 31)

def rng(v):
    v = sorted(set(v))
    if not v: return '-'
    if len(v) <= 8: return ','.join(str(x) for x in v)
    return '%d..%d (%d values)' % (v[0], v[-1], len(v))

def hexrng(v):
    v = sorted(set(v))
    return '-' if not v else '%x..%x' % (v[0], v[-1])

def main(d):
    name = os.path.basename(os.path.normpath(d))
    print('=' * 72)
    print(name)
    st = open(os.path.join(d, 'stats.txt')).read().splitlines()
    print('  ' + st[0])
    nsamp = int(st[0].split()[1])
    secs = nsamp / FS
    acts = [(int(l.split()[1]), int(l.split()[2])) for l in st if l.strip().startswith('act ')]
    if acts:
        mx = max(a for a, _ in acts)
        busy = [(a, c) for a, c in acts if a > 0]
        mean = sum(a * c for a, c in busy) / max(1, sum(c for _, c in busy))
        print('  seconds %.1f, max active slots %d, mean active (when any) %.1f' % (secs, mx, mean))
    feat = {}
    i0 = st.index('slot-sample feature counts:')
    for l in st[i0 + 1:]:
        if not l.startswith('  ') or 'page' in l: break
        k, v = l.split(); feat[k] = int(v)
    used = [k for k, v in feat.items() if v]
    print('  slot features (slot-samples): ' + ' '.join('%s=%d' % (k, feat[k]) for k in used))

    # key-ons
    keys = []
    for l in open(os.path.join(d, 'keyon.txt')):
        p = l.split()
        keys.append((int(p[0]), int(p[1]), [int(x, 16) for x in p[2:18]]))
    print('  key-ons %d (%.1f/s), slots used %s' % (len(keys), len(keys) / secs, rng(k[1] for k in keys)))
    F = [slot_fields(k[2]) for k in keys]
    if F:
        for fld in ['pcm8', 'lpctl', 'ssctl', 'sbctl', 'sdir', 'stwinh', 'eghold', 'lpslnk', 'krs', 'ar', 'd1r', 'd2r', 'rr', 'dl', 'tl', 'oct',
                    'mdl', 'mdxsl', 'mdysl', 'lfore', 'lfof', 'plfows', 'plfos', 'alfows', 'alfos', 'isel', 'imxl', 'disdl', 'dipan', 'efsdl', 'efpan']:
            print('    %-7s %s' % (fld, rng(f[fld] for f in F)))
        print('    sa      %s   sample end (sa+lea<<pcm16) %s' % (hexrng(f['sa'] for f in F),
              hexrng(f['sa'] + (f['lea'] << (0 if f['pcm8'] else 1)) for f in F)))
    # register writes
    regs = np.fromfile(os.path.join(d, 'regs.bin'), dtype=REC)
    reads = np.fromfile(os.path.join(d, 'reads.bin'), dtype=REC)
    cw = collections.Counter(); cr = collections.Counter()
    dspw = collections.Counter(); vals = collections.defaultdict(set)
    off = regs['off'].astype(np.int64)
    slotw = int((off < 0x400).sum())
    com = regs[(off >= 0x400) & (off < 0x430)]
    for o in np.unique(com['off']):
        sel = com[com['off'] == o]
        cw[int(o)] = len(sel); vals[int(o)] = set(int(x) for x in np.unique(sel['data']))
    dspw['ring/other'] = int(((off >= 0x430) & (off < 0x700)).sum())
    dspw['COEF'] = int(((off >= 0x700) & (off < 0x780)).sum())
    dspw['MADRS'] = int(((off >= 0x780) & (off < 0x800)).sum())
    dspw['MPRO'] = int(((off >= 0x800) & (off < 0xc00)).sum())
    dspw['other'] = int((off >= 0xc00).sum())
    u, c = np.unique(reads['off'], return_counts=True)
    for a, b in zip(u, c): cr[int(a)] = int(b)
    print('  68000 register writes: slot %d (%.0f/s), common %d, dsp %s' % (slotw, slotw / secs, sum(cw.values()), dict(dspw)))
    names = {0x400: 'MEM4B/DAC18B/MVOL', 0x402: 'RBL/RBP', 0x404: 'MIBUF', 0x406: 'MOBUF', 0x408: 'MSLC/CA', 0x412: 'DMEA', 0x414: 'DRGA',
             0x416: 'DTLG/DEXE', 0x418: 'TIMA', 0x41a: 'TIMB', 0x41c: 'TIMC', 0x41e: 'SCIEB', 0x420: 'SCIPD', 0x422: 'SCIRE',
             0x424: 'SCILV0', 0x426: 'SCILV1', 0x428: 'SCILV2', 0x42a: 'MCIEB', 0x42c: 'MCIPD', 0x42e: 'MCIRE'}
    for off in sorted(set(cw) | set(k for k in cr if 0x400 <= k < 0x430)):
        v = sorted(vals[off])
        vs = ' '.join('%04x' % x for x in v[:10]) + (' ... (%d values)' % len(v) if len(v) > 10 else '')
        print('    %03x %-18s w %7d  r %7d  values %s' % (off, names.get(off, '?'), cw[off], cr[off], vs))
    other_r = {k: v for k, v in cr.items() if k < 0x400 or k >= 0x430}
    if other_r:
        print('    reads outside the common block: %s' % ' '.join('%03x:%d' % kv for kv in sorted(other_r.items())[:20]))
    # DSP
    dp = os.path.join(d, 'dsp.txt')
    if os.path.exists(dp):
        progs = []
        cur = None
        for l in open(dp):
            p = l.split()
            if p[0] == 'START':
                cur = dict(n=int(p[2]), last=int(p[4]), rbp=int(p[6], 16), rbl=int(p[8], 16), mpro=[], coef=[], madrs=[]); progs.append(cur)
            elif p[0] == 'MPRO': cur['mpro'].append([int(x, 16) for x in p[2:6]])
            elif p[0] == 'COEF': cur['coef'].append(int(p[2], 16))
            elif p[0] == 'MADRS': cur['madrs'].append(int(p[2], 16))
        print('  DSP starts %d' % len(progs))
        seen = set()
        for pr in progs:
            key = (tuple(map(tuple, pr['mpro'])), tuple(pr['coef']), tuple(pr['madrs']))
            tag = 'same as before' if key in seen else ''
            seen.add(key)
            u = collections.Counter(); masa = set(); coefs = set(); ira = set()
            for st_, w in enumerate(pr['mpro'][:pr['last']]):
                if not any(w): continue
                tra = (w[0] >> 8) & 0x7f; twt = (w[0] >> 7) & 1
                xsel = (w[1] >> 15) & 1; ysel = (w[1] >> 13) & 3; ira_ = (w[1] >> 6) & 0x3f; iwt = (w[1] >> 5) & 1
                table = (w[2] >> 15) & 1; mwt = (w[2] >> 14) & 1; mrd = (w[2] >> 13) & 1; ewt = (w[2] >> 12) & 1
                adrl = (w[2] >> 7) & 1; frcl = (w[2] >> 6) & 1; shift = (w[2] >> 4) & 3; yrl = (w[2] >> 3) & 1
                negb = (w[2] >> 2) & 1; zero = (w[2] >> 1) & 1; bsel = w[2] & 1
                nofl = (w[3] >> 15) & 1; coef = (w[3] >> 9) & 0x3f; masa_ = (w[3] >> 2) & 0x1f; adreb = (w[3] >> 1) & 1; nxadr = w[3] & 1
                for k, v in dict(twt=twt, iwt=iwt, table=table, mwt=mwt, mrd=mrd, ewt=ewt, adrl=adrl, frcl=frcl, yrl=yrl, negb=negb, zero=zero,
                                 bsel=bsel, nofl=nofl, adreb=adreb, nxadr=nxadr, xsel=xsel).items():
                    if v: u[k] += 1
                u['ysel%d' % ysel] += 1; u['shift%d' % shift] += 1
                if mrd or mwt:
                    masa.add(masa_)
                    if not (st_ & 1): u['mem_on_even_step(ignored)'] += 1
                if ysel == 1: coefs.add(coef)
                ira.add(ira_)
            print('    n %d (%.2f s) steps %d RBP %x RBL %x words %s' % (pr['n'], pr['n'] / FS, pr['last'], pr['rbp'], pr['rbl'], tag))
            if not tag:
                print('      fields used: ' + ' '.join('%s=%d' % kv for kv in sorted(u.items())))
                print('      MASA %s  COEFs %d  IRA %s  MADRS %s' % (rng(masa), len(coefs), rng(ira),
                      ' '.join('%04x' % pr['madrs'][m] for m in sorted(masa))))
    ds = os.path.join(d, 'dspstats.txt')
    if os.path.exists(ds):
        l = open(ds).read().splitlines()
        print('  ' + l[0])
        pages = [int(x.split()[1], 16) for x in l[1:]]
        print('    DSP pages: %s (%d x 4 KB)' % (hexrng(pages), len(pages)))
    # sound RAM footprint
    sl = [int(l.split()[1], 16) for l in st if l.strip().startswith('page ')]
    print('  slot read pages: %s (%d x 4 KB)' % (hexrng(sl), len(sl)))
    ramw = np.fromfile(os.path.join(d, 'ramw.bin'), dtype=RAMW)
    u, c = np.unique(ramw['a'] >> 12, return_counts=True)
    wp = collections.Counter({int(a): int(b) for a, b in zip(u, c)})
    print('  68000 RAM writes %d (%.0f/s), pages written %d: %s' % (len(ramw), len(ramw) / secs, len(wp),
          ' '.join('%05x' % (p << 12) for p in sorted(wp))[:400]))
    hi = max(wp) if wp else 0
    print('    highest page written by the 68000: %05x' % (hi << 12))
    print('  ' + ' | '.join(l.strip() for l in open(os.path.join(d, 'bus.txt')).read().splitlines()))
    # MIDI, IRQ
    midi = [l.split() for l in open(os.path.join(d, 'midi.txt'))]
    print('  MIDI in bytes %d (%.1f/s)' % (len(midi), len(midi) / secs))
    irq = collections.Counter()
    for l in open(os.path.join(d, 'irq.txt')):
        n, lvl, st_ = l.split(); irq[(int(lvl), int(st_))] += 1
    print('  IRQ line calls (level, state): %s' % dict(irq))
    if os.path.exists(os.path.join(d, 'ctl.txt')):
        print('  0x400000 writes: %s' % rng(int(l.split()[4], 16) for l in open(os.path.join(d, 'ctl.txt'))))
    misc = open(os.path.join(d, 'misc.txt')).read().splitlines()
    print('  DMA: %d' % sum(1 for l in misc if 'DMA' in l))
    pcs = [int(l.split()[1], 16) for l in open(os.path.join(d, 'pc.txt'))]
    print('  68000 PC samples: ROM %d RAM %d' % (sum(1 for p in pcs if p >= 0x600000), sum(1 for p in pcs if p < 0x80000)))

for d in sys.argv[1:]:
    main(d)
