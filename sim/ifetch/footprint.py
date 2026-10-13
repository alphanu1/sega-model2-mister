# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1 (R817)
# footprint.py <ips>... : per-frame code footprint, reuse distance, and miss
# rates of an LRU set-associative line cache (16-byte lines), counting line
# CHANGES in the busy (non-spin) stream as accesses -- the demand line stream,
# prefetch aside. Warm: the first frame warms, the rest are counted.
import sys, array, collections
SPIN = {0x1394, 0x139c}
def frames_of(path):
    ips = array.array('I'); ips.frombytes(open(path, 'rb').read())
    fr = []; cur = []
    for a in ips:
        if a == 0xffffffff: fr.append(cur); cur = []
        else: cur.append(a)
    fr.append(cur)
    return [f for f in fr if f]
def line_stream(fr):
    out = []; last = None
    for a in fr:
        if a in SPIN: continue
        l = a >> 4
        if l != last: out.append(l); last = l
    return out
def sim(stream_frames, lines, ways):
    sets = lines // ways
    cache = [collections.OrderedDict() for _ in range(sets)]
    miss = acc = 0; seqmiss = 0
    for fi, s in enumerate(stream_frames):
        prev = None
        for l in s:
            st = cache[l % sets]
            hit = l in st
            if hit: st.move_to_end(l)
            else:
                st[l] = 1
                if len(st) > ways: st.popitem(last=False)
            if fi > 0:
                acc += 1
                if not hit:
                    miss += 1
                    if prev is not None and l == prev + 1: seqmiss += 1
            prev = l
    return acc, miss, seqmiss
for path in sys.argv[1:]:
    frs = frames_of(path)
    ls = [line_stream(f) for f in frs]
    busy = [sum(1 for a in f if a not in SPIN) for f in frs]
    fp = [len(set(s)) for s in ls]
    print("%s: %d frames; busy insn/frame %s; distinct lines/frame %s (KB %s)" % (path, len(frs), busy, fp, [round(x*16/1024,1) for x in fp]))
    # reuse distance (distinct lines between uses), frames 1.. pooled
    last = {}; hist = collections.Counter(); seq = []
    for s in ls: seq += s
    # stack distance via simple LRU list (O(n*d) but fine for this size)
    stack = []
    import bisect
    pos = {}
    t = 0
    from collections import OrderedDict
    od = OrderedDict()
    for l in seq:
        if l in od:
            # distance = number of distinct lines used since
            d = 0
            for k in reversed(od):
                if k == l: break
                d += 1
            hist[min(d.bit_length(), 14)] += 1
            od.move_to_end(l)
        else:
            hist['cold'] += 1; od[l] = 1
    tot = sum(hist.values())
    cum = 0
    out = []
    for b in range(15):
        cum += hist.get(b, 0)
        out.append("<%d:%.1f%%" % ((1 << b), 100*cum/tot))
    print("   reuse distance (lines), cumulative: " + " ".join(out[3:]) + "  cold %.1f%%" % (100*hist['cold']/tot))
    for lines in (32, 128, 512, 2048):
        r = []
        for ways in (1, 2, 4):
            a, m, sq = sim(ls, lines, ways)
            r.append("%d-way %5.1f%% (%5.0f/frame, seq %2.0f%%)" % (ways, 100*m/max(a,1), m/max(1,len(ls)-1), 100*sq/max(m,1)))
        print("   %5d B: %s" % (lines*16, "  ".join(r)))
