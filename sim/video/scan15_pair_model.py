#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R939: a frame-level model of m2_scan15's pairing, for rates over long runs the RTL bench is too slow for. The image
# cadence is tb_m2_scan15's LCG (+rnd=1); on the same seed the re-pair counts match the bench run for run.
#   python3 sim/video/scan15_pair_model.py [minutes]
"""Frame-level model of m2_scan15's pairing (old: retrorepair's re-align; new: R939's field swap).
Image cadence from the tb's LCG. Counts per minute of native frames (57.524 Hz)."""
import sys
FPS = 57.524

def lcg_lens(seed, slip1, slip3, slip4):
    while True:
        seed = (seed * 1103515245 + 12345) & 0xFFFFFFFF
        r = ((seed >> 16) & 0x7FFF) % 1000
        yield 1 if r < slip1 else 3 if r < slip1 + slip3 else 4 if r < slip1 + slip3 + slip4 else 2

def changes(nframes, seed, slip1, slip3, slip4):
    """chg[f]: the image changed at native frame start f (tb: tag bumped at the vblank before it)."""
    g = lcg_lens(seed, slip1, slip3, slip4)
    chg = [False] * (nframes + 1); cdn = 2
    for f in range(nframes):          # vblank at the end of frame f
        if cdn <= 1:
            chg[f + 1] = True; cdn = next(g)
        else:
            cdn -= 1
    return chg

def old(chg, N=8):
    par = 0; bad = 0; moves = 0; f0 = None; pairs = 0; pbad = 0; lastE = None
    for f, c in enumerate(chg):
        if c and not par and bad == N - 1:
            moves += 1; par = 0; isE = True; bad = 0
        else:
            if c: bad = 0 if par else (bad + 1) % 8
            isE = bool(par); par ^= 1
        # output frame: field 0 shows the E frame, field 1 the next
        if isE: lastE = f
        elif lastE == f - 1:
            pairs += 1; pbad += c
    return moves, pairs, pbad

def new(chg, N=8, pe=True, holdoff=0):
    par = 0; bad = 0; s = 0; flip = 0; swaps = 0; pairs = 0; pbad = 0; f0 = None; last_swap = -10**9
    for f, c in enumerate(chg):
        isE = bool(par)
        good = par ^ s
        allowed = pe and (f - last_swap) >= holdoff
        trip = c and not good and bad == N - 1
        if c: bad = 0 if (good or trip) else bad + 1
        lab0 = (isE and s == 0) or (not isE and s == 1)   # this frame is field 0 (label before any swap now)
        if not par and (flip or (trip and allowed)):
            s ^= 1; flip = 0; swaps += 1; last_swap = f
        elif par and trip and allowed:
            flip = 1
        par ^= 1
        # pairs: a field-0 frame followed by a field-1 frame (labels: E is s, O is ~s, s as set at the E frame)
        if lab0: f0 = f
        elif f0 == f - 1:
            pairs += 1; pbad += c
    return swaps, pairs, pbad

def hold_late(chg, phase):
    """Ben's variant (not built): the pairing fixed, the renderer holds a LATE image (>= 3 frames since the last) one
    frame when it would start on field 1's frame. Returns holds, dropped images, combed output frames, output frames."""
    shown = []; holds = drops = 0; prev = None
    for g in (f for f, c in enumerate(chg) if c):
        t = g
        if prev is not None and g - prev >= 3 and (g + phase) % 2 == 1: t = g + 1; holds += 1
        if shown and t <= shown[-1]: drops += 1; shown[-1] = t
        else: shown.append(t)
        prev = g
    pairs = sum(1 for f in range(len(chg) - 1) if (f + phase) % 2 == 0)
    return holds, drops, sum(1 for f in set(shown) if (f + phase) % 2 == 1), pairs

if __name__ == '__main__':
    minutes = float(sys.argv[1]) if len(sys.argv) > 1 else 60
    nf = int(minutes * 60 * FPS)
    for name, (s1, s3, s4) in [('2:96% 3:2% 4:2% (slips persist)', (0, 20, 20)),
                               ('2:95% 3:2% 1:3% (catch-ups)', (30, 20, 0)),
                               ('2:98% 3:2%', (0, 20, 0)),
                               ('2:95% 3:5%', (0, 50, 0)),
                               ('steady 2', (0, 0, 0))]:
        chg = changes(nf, 1, s1, s3, s4)
        m, p, b = old(chg)
        print(f'{name}: {sum(chg)} images over {minutes:g} min')
        print(f'   old (re-align)   : {m/minutes:6.1f} half-line LINE jumps/min, combed output frames {100*b/p:5.1f}%')
        for N in (2, 4, 8, 16):
            sw, p2, b2 = new(chg, N)
            print(f'   new PAIR_N={N:<2}     : {sw/minutes:6.1f} repeated fields (1/2-line vsync steps)/min, combed {100*b2/p2:5.1f}%')
        for ho in (10, 30):
            sw, p2, b2 = new(chg, 8, True, int(ho * FPS))
            print(f'   new N=8, >= {ho:2d} s apart: {sw/minutes:6.1f} /min, combed {100*b2/p2:5.1f}%')
        sw, p2, b2 = new(chg, 8, False)
        print(f'   new pairing off  : {sw/minutes:6.1f} /min, combed {100*b2/p2:5.1f}%')
        for ph in (0, 1):
            h, d, b3, p3 = hold_late(chg, ph)
            print(f'   hold late image, phase {ph}: {h/minutes:5.1f} holds/min, {d/minutes:4.1f} dropped/min, combed {100*b3/p3:5.1f}%')
