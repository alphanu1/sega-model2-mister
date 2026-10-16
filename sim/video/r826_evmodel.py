#!/usr/bin/env python3
"""R826 residual: event model of the game, m2_geo (AFTER_STRICT), m2_raster3d
(swap / publish / list_hold) and m2_video SCR_SYNC, rule for rule from the RTL
at d7210b3 + r826-on.patch.  Time unit: one video frame (vblank period).
Vblank edge V_k at t = k; vblank lines 384-423 = [k, k+VB); the tilemap
sequencer reads the scroll words for lines -2..383 in [k+RD0, k+1).

THE GAME (Daytona Rev A, MAME debugger, R826 addendum + this session):
  0x138c: g0 = count; wait until count != g0; count = 0; step starts.
  So a step ALWAYS starts right after a delivered vblank IRQ, the first one
  whose count increment the wait loop sees.
  IRQ at a delivered vblank writes the scroll from 0x5fe11a, which the step
  start (0x4500) set to the yaw of the step before: words(V) belong to list
  N - 2, N = steps started before V.
  Step j flips list j at S_j + df, enters the wait loop at flip + tail.

TRUTH: list p on screen should be shown with words tagged p.
"""
import random, sys, math
from collections import Counter

LINES = 424
VB = 40 / LINES          # vblank length
RD0 = 38 / LINES         # first scroll read of a frame (2 lines ahead of line 0)

class P:  # parameters
    def __init__(self, **kw):
        self.df = lambda r: 0.8          # step start -> flip (frames)
        self.tail = lambda r: 0.01       # flip -> wait-loop entry
        self.lat = 0.0005                # vblank edge -> IRQ taken (mainline preempted)
        self.walk = lambda r: 0.25       # walk work while the store collects
        self.sort = lambda r: 0.03       # q_end -> P_READY
        self.draw = lambda r: 0.7        # swap -> fb_complete
        self.mode = 'sync'               # sync | none | depth3 | stepx | stepack | hold3
        self.strict = True
        self.frames = 2000
        self.seed = 1
        self.forced = {}                 # step index -> dict(df=..., tail=...)
        self.walk_forced = {}            # walk index -> work
        self.draw_forced = {}
        for k, v in kw.items(): setattr(self, k, v)

def _v(x, r): return x(r) if callable(x) else x

def run(p, trace=False, export=None, telem=None, mhz=75.0):
    r = random.Random(p.seed)
    INF = 1e18
    # ---------------- game
    N = 0                 # steps started
    step_j = -1
    flip_t = INF; wait_t = INF   # pending flip / wait entry of the running step
    game_waiting = True          # step 0 starts after the first IRQ
    tile_tag = -2; tile_prev = -2   # words in tile RAM / before the last IRQ write
    tile_written_t = -1.0
    # ---------------- RTL
    fc = 0; flip_seen = False; vaf = False; frame_pend = False
    walk_busy = False; walk_tag = None; walk_need = 0.0; walk_n = 0
    walk_start_t = None
    pst = 'C'; coll_since = 0.0  # store state; time collecting resumed
    tag_coll = None; ready_t = INF; sort_end = INF
    fb_busy = False; fb_complete = False; draw_end = INF; tag_draw = None
    show = None
    # SYNC
    ss_nf = 0; ss_c = [None, None]; ss_c3 = [None, None, None]
    # step-tagged copies (fix variants): list of (tag) of words per delivered vblank
    hist = []            # tags of the words shown in previous frames (newest last)
    n_ack = 0; flipped_since_ack = True; ack_tile = -2; ack_hist = []
    tile_at_fs = -2
    # stats
    frames = []
    cnt = Counter()
    k = 0
    pending_step_start = False
    t_last_read_tile = None

    tm = dict(wpend=False, ns=0, sph=None, glate=False, pend=None, fn=0)
    PH = mhz * 1e6 / 57.52 / 4096.0      # phase units a frame (clk_sys >> 12)

    def new_step(t):
        nonlocal N, step_j, flip_t, wait_t
        tm['ns'] += 1; tm['sph'] = t
        step_j = N; N += 1
        f = p.forced.get(step_j, {})
        df = f.get('df', _v(p.df, r)); tl = f.get('tail', _v(p.tail, r))
        flip_t = t + df; wait_t = flip_t + tl

    def start_walk(t):
        nonlocal walk_busy, walk_tag, walk_need, walk_n, flip_seen, vaf, frame_pend, coll_since, walk_start_t
        walk_busy = True; walk_tag = fc - 1
        walk_need = p.walk_forced.get(walk_n, _v(p.walk, r)); walk_n += 1
        flip_seen = False; vaf = False; frame_pend = False
        walk_start_t = t
        tm['wpend'] = True
        if pst == 'C': coll_since = max(coll_since, t)

    def walk_done_time():
        if not walk_busy or pst != 'C': return INF
        return coll_since + walk_need

    # the scroll the gate shows at time t (by tag)
    def shown(t):
        if p.mode == 'none':
            return tile_tag
        if p.mode == 'sync' or p.mode == 'depth3':
            if show is None: return tile_tag
            d = (ss_nf - (show + 2)) & 15
            if p.mode == 'sync':
                if d in (1, 2): return ss_c[(show + 2) & 1]
                return tile_tag
            else:
                if d in (1, 2, 3): return ss_c3[(show + 2) % 3]
                return tile_tag
        if p.mode in ('stepx', 'stepack', 'stepx3', 'stepack3'):
            if show is None: return tile_tag
            cur = tile_tag if p.mode.startswith('stepx') else ack_tile
            hh = hist if p.mode.startswith('stepx') else ack_hist
            depth = 3 if p.mode.endswith('3') else 2
            cand = [(cur, tile_tag)] + [(a, b) for a, b in reversed(hh[-depth:])]
            for tg, real in cand:
                if tg == show: return real
            # no match: older than every copy -> the oldest copy; newer -> tile RAM
            oldest = cand[-1]
            if len(cand) > depth and oldest[0] - show == 1: return oldest[1]
            return tile_tag
        raise ValueError(p.mode)

    # main loop over frames: process events in time order inside [k, k+1)
    for k in range(p.frames):
        t0 = float(k)
        # ---- vblank edge k
        held = (pst == 'R') and fb_busy
        tile_at_fs = tile_tag
        if telem is not None:
            rl = tm['wpend'] and pst != 'R'
            wl = flip_seen and walk_busy
            if tm['pend'] is not None:
                fr = tm['pend']
                fl_ = (int(held) << 7) | (int((not held) and (not game_waiting)) << 6) | (int(wl) << 5) | (int(rl) << 4)
                a = ((tm['fn'] & 0xff) << 24) | ((fr['ot'] & 15) << 20) | ((fr['ob'] & 15) << 16) | ((fr['dt'] & 15) << 12) | ((fr['db'] & 15) << 8) | fl_
                d = (fr['fph'] << 23) | (fr['sph'] << 14) | (min(3, fr['nf']) << 12) | (min(3, fr['ns']) << 10) | (fr['lat'] << 2) | ((0 if held else 1) << 1)
                telem.append('R %08x %08x' % (a, d))
                tm['fn'] += 1
            tm['pend'] = None
        # draw completion before the edge?
        # (handled in the inner loop of the previous frame)
        if not held:
            # raster3d frame_start: publish then swap
            if fb_complete and tag_draw is not None:
                if show != tag_draw:
                    show = tag_draw
                    if export is not None: export.append((t0, 'P', show))
            if pst == 'R' and not fb_busy:
                tm['wpend'] = False
                tag_draw = tag_coll; fb_busy = True; fb_complete = False
                dd = p.draw_forced.get(tag_coll, _v(p.draw, r))
                draw_end = t0 + dd
                pst = 'C'; coll_since = t0
            # m2_geo frame_start
            if flip_seen: vaf = True
            frame_pend = True
            trig = frame_pend and flip_seen and (vaf or not p.strict)
            if not walk_busy and trig: start_walk(t0)
        else:
            cnt['held'] += 1
        # ---- events inside this frame
        irq_t = t0 + p.lat if not held else INF
        seg = []           # (time, shown tag) for the visible part
        first_read_done = False
        t = t0
        nflip_frame = 0
        last_flip = None; tm['ns'] = 0; tm['sph'] = None; dtop = None
        while True:
            cands = []
            cands.append((irq_t, 'irq'))
            cands.append((flip_t, 'flip'))
            cands.append((wait_t, 'wait'))
            cands.append((walk_done_time(), 'walkdone'))
            cands.append((sort_end, 'sortdone'))
            cands.append((draw_end, 'drawdone'))
            cands.append((t0 + RD0 if not first_read_done else INF, 'read0'))
            tn, what = min(cands)
            if tn >= t0 + 1: break
            t = tn
            if what == 'irq':
                irq_t = INF
                # the handler's words: list N - 2
                tile_prev = tile_tag
                tile_tag = N - 2
                if export is not None:
                    export.append((t0, 'V', n_ack - 2))
                    export.append((t, 'W', tile_tag))
                # ack-rule tile tag (RTL can see flips and the ack)
                ack_hist.append((ack_tile, tile_prev))
                ack_tile = n_ack - 2
                if flipped_since_ack:
                    n_ack += 1; flipped_since_ack = False
                hist.append((tile_prev, tile_prev))
                # step start? the wait loop saw no change yet if it was entered before the IRQ was taken
                if game_waiting:
                    game_waiting = False
                    new_step(t)
            elif what == 'flip':
                flip_t = INF
                nflip_frame += 1; last_flip = t
                if export is not None: export.append((t, 'F', 0))
                tm.setdefault('ff', {})[fc] = k
                fc += 1; flip_seen = True
                # SYNC copy: the sequencer's last read
                in_reads = (t - t0) >= RD0
                dbg = tile_tag if in_reads else tile_at_fs
                ss_c[ss_nf & 1] = dbg
                ss_c3[ss_nf % 3] = dbg
                ss_nf += 1
                flipped_since_ack = True
                if (t - t0) < p.lat: cnt['flip_in_irq_window'] += 1
                if first_read_done: seg.append((t, shown(t)))
            elif what == 'wait':
                wait_t = INF
                # entered the wait loop: was this vblank's IRQ already taken?
                # (the step continues past the edge only if it is after irq_take)
                game_waiting = True   # the next IRQ taken starts the next step
            elif what == 'walkdone':
                walk_busy = False
                pst = 'S'; tag_coll = walk_tag; sort_end = t + _v(p.sort, r)
                trig = frame_pend and flip_seen and (vaf or not p.strict)
                if trig: start_walk(t)
            elif what == 'sortdone':
                sort_end = INF; pst = 'R'
            elif what == 'drawdone':
                draw_end = INF; fb_busy = False; fb_complete = True
            elif what == 'read0':
                first_read_done = True
                seg.append((t, shown(t)))
                dtop = ((ss_nf - (show + 2)) & 15) if show is not None else 0
        # ---- frame k's record
        tags = [s for _, s in seg]
        pshow = show
        if pshow is not None and k > 20:
            offs = [ (tg - pshow) for tg in tags ]
            top = offs[0]
            if all(o == 0 for o in offs): c = 'aligned'
            elif len(set(offs)) > 1: c = 'tear'
            elif top == 1: c = '+1'
            elif top == -1: c = '-1'
            else: c = 'other%+d' % top
            cnt[c] += 1
            cnt['frames'] += 1
            if nflip_frame == 0: cnt['noflip_frames'] += 1
            frames.append((k, pshow, tags, offs, nflip_frame, held))
            if telem is not None:
                ph = lambda tt: min(510, int((tt - t0) * PH)) if tt is not None else 511
                tm['pend'] = dict(ot=offs[0], ob=offs[-1], dt=dtop or 0, db=((ss_nf - (pshow + 2)) & 15),
                                  lat=(k - tm.get('ff', {}).get(pshow, k)) & 15,
                                  fph=ph(last_flip), sph=ph(tm['sph']), nf=nflip_frame, ns=tm['ns'])
            if export is not None: export.append((t0 + 1 - 1e-6, 'R', (pshow, tags[0], tags[-1])))
            if trace: print(k, 'show', pshow, 'tags', tags, 'offs', offs, 'flips', nflip_frame, 'held', held, 'nf', ss_nf, 'N', N)
    return cnt, frames

def summary(cnt, label=''):
    n = cnt['frames']
    def pc(x): return 100.0 * cnt[x] / n if n else 0
    others = sum(v for kk, v in cnt.items() if kk.startswith('other'))
    return "%-28s frames %6d  aligned %6.2f%%  +1 %5.2f%%  -1 %5.2f%%  tear %5.2f%%  other %5.2f%%  held %d noflip %.2f%%" % (
        label, n, pc('aligned'), pc('+1'), pc('-1'), pc('tear'), 100.0 * others / n if n else 0, cnt['held'], pc('noflip_frames'))

def changes(frames):
    # changes of the backdrop's offset against the scene, per 1000 frames
    ch = 0
    prev = None
    for f in frames:
        o = (f[3][0], f[3][-1])
        if prev is not None and o != prev: ch += 1
        prev = o
    return 1000.0 * ch / max(1, len(frames))


# ---------------------------------------------------------------- cases
CASES = {
    'steady':                     dict(),
    'B2 flip after mid vblank':   dict(forced={40: dict(df=1.10)}),
    'B2 flip in vblank':          dict(forced={40: dict(df=1.03)}),
    'B1 tail spans vblank':       dict(forced={40: dict(df=0.9995, tail=0.002)}),
    'E flip in IRQ window':       dict(forced={40: dict(df=0.9998, tail=0.0001)}),
    '3-vblank step':              dict(forced={40: dict(df=2.10)}),
    'walk late once':             dict(walk_forced={40: 1.0}),
    'walk late, B2 30 later':     dict(walk_forced={40: 1.0}, forced={70: dict(df=1.10)}),
    'walk late twice':            dict(walk_forced={40: 1.0, 60: 1.0}),
    'draw late once (hold)':      dict(draw_forced={40: 1.10}),
}
MODES = {'sync': 'R826 SCR_SYNC', 'depth3': 'flip copies x3', 'stepack': 'SCR_STEP depth 2',
         'stepack3': 'SCR_STEP depth 3', 'none': 'no gate'}

def df_tight(r): return max(0.3, r.gauss(0.80, 0.086))
def df_light(r): return r.uniform(1.0, 1.4) if r.random() < 0.01 else r.uniform(0.4, 0.95)
class walk_with:   # a class, not a closure, so the bench's worker processes can take it
    def __init__(self, pwl): self.pwl = pwl
    def __call__(self, r): return r.uniform(0.95, 1.3) if r.random() < self.pwl else r.uniform(0.05, 0.6)
def draw_ok(r): return r.uniform(0.4, 0.9)

def cmd_cases(modes):
    for m in modes:
        print('== %s (%s)' % (m, MODES[m]))
        for nm, kw in CASES.items():
            c, fr = run(P(frames=120, mode=m, tail=0.0005, **kw))
            bad = [(f[0], f[1], f[3]) for f in fr if any(o != 0 for o in f[3])]
            print(summary(c, nm), ' chg/1000 %.1f' % changes(fr))
            for b in bad[:4]: print('     frame %d 3D list %s 2D offsets top..bottom %s' % b)
            if len(bad) > 4: print('     ... %d frames misaligned' % len(bad))

def cmd_stoch(frames, modes):
    print("%d frames a row; tail 0.0005; IRQ window 0.0005; draw 0.4-0.9 frame" % frames)
    for shape, dfn in (('tight', df_tight), ('light+tail', df_light)):
        for pwl in (0.0, 0.002, 0.005, 0.01, 0.02):
            for m in modes:
                c, fr = run(P(frames=frames, mode=m, df=dfn, walk=walk_with(pwl), tail=0.0005,
                              draw=draw_ok, seed=7))
                print(summary(c, "%s wl=%.1f%% %s" % (shape, 100 * pwl, m)), " chg/1000 %.1f" % changes(fr))
            print()

BENCH_CASES = {   # the same cases, earlier and shorter for the RTL (~0.6 s a frame)
    'steady':                     dict(),
    'B2 flip after mid vblank':   dict(forced={30: dict(df=1.10)}),
    'B2 flip in vblank':          dict(forced={30: dict(df=1.03)}),
    'B1 tail spans vblank':       dict(forced={30: dict(df=0.9995, tail=0.002)}),
    'E flip in IRQ window':       dict(forced={30: dict(df=0.9998, tail=0.0001)}),
    '3-vblank step':              dict(forced={30: dict(df=2.10)}),
    'walk late once':             dict(walk_forced={30: 1.0}),
    'walk late, B2 15 later':     dict(walk_forced={30: 1.0}, forced={45: dict(df=1.10)}),
    'walk late twice':            dict(walk_forced={30: 1.0, 40: 1.0}),
    'draw late once (hold)':      dict(draw_forced={30: 1.10}),
}

def _bench_one(args):
    import subprocess, tempfile, os
    obj, m, nm, kw, nf = args
    ex = []
    run(P(frames=nf, mode=m, tail=0.0005, **kw), export=ex)
    with tempfile.NamedTemporaryFile('w', suffix='.sched', delete=False) as f:
        for t, ty, v in ex:
            if ty == 'R': f.write('%.6f R %d %d %d\n' % (t, v[0], v[1], v[2]))
            else: f.write('%.6f %s %d\n' % (t, ty, v))
        fn = f.name
    r = subprocess.run([obj, fn, nm], capture_output=True, text=True)
    os.unlink(fn)
    return r.returncode, r.stdout

def cmd_bench(objs, frames_case=64, frames_stoch=200, jobs=6):
    import os
    from concurrent.futures import ProcessPoolExecutor
    runs = [(nm, kw, frames_case) for nm, kw in BENCH_CASES.items()]
    runs.append(('stochastic light+tail wl 1%', dict(df=df_light, walk=walk_with(0.01),
                 draw=draw_ok, seed=3), frames_stoch))
    runs.append(('stochastic tight wl 2%', dict(df=df_tight, walk=walk_with(0.02),
                 draw=draw_ok, seed=5), frames_stoch))
    todo = [(obj, m, nm, kw, nf) for m, obj in objs for nm, kw, nf in runs]
    fails = 0
    with ProcessPoolExecutor(max_workers=jobs) as ex:
        res = list(ex.map(_bench_one, todo))
    last = None
    for (obj, m, nm, kw, nf), (rc, out) in zip(todo, res):
        if obj != last:
            print('-- RTL %s (%s), against model mode %s' % (os.path.dirname(obj), MODES[m], m)); last = obj
        sys.stdout.write(out)
        if rc != 0: fails += 1
    print('R826b bench: %s (the RTL against the model on every compared frame)' % ('FAIL' if fails else 'PASS'))
    return fails

if __name__ == '__main__':
    import argparse
    ap = argparse.ArgumentParser(description='R826 event model')
    ap.add_argument('what', choices=['cases', 'stoch', 'bench'])
    ap.add_argument('--modes', default='sync,depth3,stepack,stepack3')
    ap.add_argument('--frames', type=int, default=30000)
    ap.add_argument('--obj0'); ap.add_argument('--obj2'); ap.add_argument('--obj3')
    a = ap.parse_args()
    modes = a.modes.split(',')
    if a.what == 'cases': cmd_cases(modes)
    elif a.what == 'stoch': cmd_stoch(a.frames, modes)
    else:
        objs = [(m, o) for m, o in (('sync', a.obj0), ('stepack', a.obj2), ('stepack3', a.obj3)) if o]
        sys.exit(1 if cmd_bench(objs) else 0)
