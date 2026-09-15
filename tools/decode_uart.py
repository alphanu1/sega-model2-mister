#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# Decode a debug UART capture (tools/board-capture.sh) for the stream layout of
# 2026-09-11 (Model2.sv, m2_dbg_stream):
#   C records: a_data = {cpu_trap, cpu_halted, copro_stall, copro_dbg_ctl[31],
#              geo_pj_lost[11:0] (R237), tgp_pc[15:0]}
#   H records: b_addr = {r3d_ready_cyc[15:0] (x16 clk), r3d_bands_done[7:0], r3d_hold[7:0]}
#              b_data = {luma_mean[7:0], black_pct[7:0], wedge_slot, wedge_n[6:0], quads[11:4]}  (R249)
#              b_data = {r3d_dropped[15:0], wedge_slot, wedge_n[6:0], r3d_quads[11:4]}   (R235)
#   W records: {x0,y0} {x1,y1} and X records: {x2,y2} {x3,y3} of a quad the board's
#              wedge catcher latched (R235): three vertices within 8 px, the fourth
#              more than 60 px away, all four inside the screen.
# Prints where the i960 spends its time (frame wait, mailbox poll, render), the
# TGP's commonest PCs, and per fifth of the capture the renderer's ready time,
# bands completed per video frame, frames a list was held, store drops, tiny
# quads refused and quads per list. Change the layout in Model2.sv and this
# file together.
#   python3 tools/decode_uart.py capture.txt
import sys,collections
C=[];H=[];W=[];SW=[]
T=[]     # R251: light-table records
Z=[]     # R334: 1/z per vertex, as 16-bit minifloats (phase 6)
D=[]     # R346: DDR3 self-test -- latency and mismatches
U=[]     # R255: walk records
V=[]     # R269: glyph cache records
Y=[]     # R275: texture records
Z=[]     # R294: SDRAM occupancy, phase 5
Z2=[]    # R294: SDRAM occupancy, phase 6
F=[]     # R359: framebuffer frames published / dropped, phase 9
P=[]     # R363: i960 rate, phase 10
N=[]     # R364: where the framebuffer is stuck, phase 11
pend=None
for line in open(sys.argv[1],errors='replace'):
    p=line.split()
    if len(p)!=3 or len(p[1])!=8 or len(p[2])!=8: continue
    try: a=int(p[1],16); d=int(p[2],16)
    except: continue
    if p[0]=='C': C.append((a,d))
    elif p[0]=='H': H.append((a,d))
    elif p[0]=='T': T.append((a,d))     # R251: the light table
    elif p[0]=='Q': Z.append((a,d))     # R334: {oz0,oz1} and {oz2,oz3}, phase 7
    elif p[0]=='D': D.append((a,d))     # R346: DDR3, phase 8
    elif p[0]=='F': F.append((a,d))     # R359: framebuffer frames, phase 9
    elif p[0]=='P': P.append((a,d))     # R363: the CPU's pace, phase 10
    elif p[0]=='N': N.append((a,d))     # R364: framebuffer state, phase 11
    elif p[0]=='U': U.append((a,d))     # R255: the walk's own numbers
    elif p[0]=='V': V.append((a,d))     # R269: the glyph cache, per frame
    elif p[0]=='Y': Y.append((a,d))     # R275: the texture path, per frame
    elif p[0]=='Z': Z.append((a,d))     # R294: bus busy / CPU wait
    elif p[0]=='z': Z2.append((a,d))    # R294: geometry / glyph / texel wait
    elif p[0]=='S': SW.append(((a>>8)&0x1f, a&0xff, d&0xffffff))   # R238: region, runs, fold
    elif p[0]=='W': pend=(a,d)
    elif p[0]=='X' and pend is not None:
        s16=lambda v: v-65536 if v>=32768 else v
        a0,d0=pend; pend=None
        W.append(tuple(s16(v) for v in ((a0>>16)&0xffff,a0&0xffff,(d0>>16)&0xffff,d0&0xffff,(a>>16)&0xffff,a&0xffff,(d>>16)&0xffff,d&0xffff)))
ip=collections.Counter(a for a,_ in C); pc=collections.Counter(d&0xffff for _,d in C)
live=sum(v for k,v in ip.items() if k!=0)
def rng(a,b): return sum(v for k,v in ip.items() if a<=k<b)
print('C',len(C),'H',len(H),' framewait %.1f%%'%(100*(ip[0x12b0]+ip[0x12b8])/max(1,live)),' mailbox %.1f%%'%(100*(ip[0x1166c]+ip[0x11674])/max(1,live)),' render %.1f%%'%(100*rng(0x16e58,0x17b00)/max(1,live)))
print('tgp  :',', '.join(f'{k:04X}:{v}' for k,v in pc.most_common(4)))
pj=[(d>>16)&0xfff for _,d in C]
print('projections abandoned on timeout (R237): first %d, last %d, max %d' % (pj[0] if pj else 0, pj[-1] if pj else 0, max(pj) if pj else 0))
# b_addr = {ready_cyc16 (x16), bands_done8, hold8}; b_data = {qs_dropped16, geo_dropped8, quads[11:4]}
n=len(H); k=max(1,n//5)
if SW:
    # tools/rom_csum.py <mra> <zipdir> --region N gives the expected fold of the image
    EXPECT={0:0x25E723,11:0x82B1E2,12:0xA76A16,13:0x1B298F,14:0xFD6ADB,15:0x06D6CC,16:0x06D6CC,17:0x7D7E94}   # tools/rom_csum.py, 2026-09-12
    r,sn,v=SW[-1]     # NOT `n`: that is the H row count the table below slices with, and shadowing it printed one slice instead of five
    e=EXPECT.get(r)
    print(f'SWEEP (R238): region {r} folded {sn} times, last fold {v:06X}' + (f'  expected {e:06X}  {"MATCH" if e==v else "MISMATCH"}' if e else '  (no expectation on file; run tools/rom_csum.py --region %d)' % r))
if W:
    print(f'WEDGES caught on the board: {len(W)} streamed; last count {(H[-1][1]>>4)&0x7f if H else 0} (slot {"1" if H and (H[-1][1]>>11)&1 else "0"})')
    for q in W[:12]: print('   (%d,%d) (%d,%d) (%d,%d) (%d,%d)' % q)
if U:
    # R255: a well-formed list decodes no nops. A walk that has lost sync reads
    # a count-driven command's payload as commands, and a run of zero words
    # comes out as a run of nops.
    nops=[(a>>16)&0xffff for a,_ in U]; ops=[a&0xffff for a,_ in U]
    fl=[(d>>24)&0xff for _,d in U]; fb=[(d>>16)&0xff for _,d in U]
    unk=[(d>>8)&0xff for _,d in U]; drp=[d&0xff for _,d in U]
    nops.sort(); ops.sort()
    print('WALK (R255): per frame -- nops decoded med %d max %d | commands med %d | unknown op %02X | push drops %d'
          % (nops[len(nops)//2], nops[-1], ops[len(ops)//2], max(unk), max(drp)))
    # R263: the counters are free-running bytes, so what matters is how fast each
    # moves. A fallback walk has no promise the list is finished.
    def rate(v):
        d=0
        for i in range(1,len(v)): d+=(v[i]-v[i-1]) & 0xff
        return d
    print('    walks started by the game\'s list-ready write: %d, by the vblank fallback: %d'
          % (rate(fl), rate(fb)))
    print('    (nops should be ZERO: the reference list holds none, so any run of them is the walk reading data as commands)')
if V:
    # R269: b_addr = {hits16, misses16}, b_data = {sibling fills16, overruns16},
    # all PER FRAME. An overrun is a scanline whose fetches did not finish before
    # the next one started: the bank does not flip and the previous line is drawn
    # again, which is visible flicker. The fills say the sibling prefetch is
    # running -- one per miss when it is.
    hit=[(a>>16)&0xffff for a,_ in V]; mis=[a&0xffff for a,_ in V]
    fil=[(d>>16)&0xffff for _,d in V]; ovr=[d&0xffff for _,d in V]
    def med(v): w=sorted(v); return w[len(w)//2]
    tot=[h+m for h,m in zip(hit,mis)]
    rate=100.0*sum(hit)/max(1,sum(tot))
    print('GLYPH CACHE (R269): per frame -- hits med %d, misses med %d max %d, hit rate %.1f%%'
          % (med(hit), med(mis), max(mis), rate))
    print('    sibling fills med %d (expect ~1 per miss), scanline overruns med %d max %d'
          % (med(fil), med(ovr), max(ovr)))
if Y:
    # R275: b_addr = {textured pixels16, texel misses16}, b_data = {texel hits16,
    # fetches abandoned16}, all PER FRAME. Pixels at zero means no polygon
    # reached the span walk with its textured bit set -- the path is not running
    # at all, which is a different fault from a texture that looks wrong.
    px=[(a>>16)&0xffff for a,_ in Y]; tm=[a&0xffff for a,_ in Y]
    th=[(d>>16)&0xffff for _,d in Y]; nz=[d&0xffff for _,d in Y]
    def med2(v): w=sorted(v); return w[len(w)//2]
    tot=[h+m for h,m in zip(th,tm)]
    rate=100.0*sum(th)/max(1,sum(tot))
    # R324: the textured-pixel field counts in FOURS. It saturated at 65535 in
    # build/char100b, which reads "at least this many" and cannot show whether a
    # change helped; Model2.sv now shifts it by two before the 16-bit delta.
    px = [v*4 for v in px]
    print('TEXTURES (R275): per frame -- textured pixels med %d max %d; texel cache %.1f%% of %d fetches'
          % (med2(px), max(px), rate, med2(tot)))
    print('    texels that were NOT 0xF: med %d of %d fetches -- zero means the sheets are EMPTY'
          % (med2(nz), med2(tot)))
    print('    (pixels 0 = nothing textured reached the span walk at all, which is a different fault)')

if Z or Z2:
    # R294: IS THE MEMORY FULL OR IS IT BLOCKED? All figures are per frame in
    # units of 32 memory-clock cycles; a frame is 1.67 M of them, so 52,000
    # units is 100% of the frame.
    FR = 1670000.0/32.0
    def med3(v): w=sorted(v); return w[len(w)//2] if w else 0
    if Z:
        busy=[(a>>16)&0xffff for a,_ in Z]; cpu=[a&0xffff for a,_ in Z]
        txm=[(d>>16)&0xffff for _,d in Z]
        # R310: the low half was 16'd0 and now carries m2_texel's whole-cache
        # sweep count. A cache cleared every frame and a cache that thrashes
        # give the SAME hit rate, and nothing separated them until this.
        tsw=[d&0xffff for _,d in Z]
        print('SDRAM (R294): bus busy %.1f%% of the frame; the CPU port waits %.1f%%'
              % (100*med3(busy)/FR, 100*med3(cpu)/FR))
        print('    texel misses med %d a frame' % med3(txm))
        if len(tsw) > 1:
            d_sw = [b-a for a, b in zip(tsw, tsw[1:]) if b >= a]
            print('    TEXEL CACHE SWEEPS (R310): %d total, med %d per sample'
                  % (max(tsw)-min(tsw) if tsw else 0, med3(d_sw)))
            print('    (a sweep clears every line, one per cycle, and answers nothing while it runs.')
            print('     Frequent sweeps mean the cache is COLD, not thrashing, and size will not help.)')
    if Z2:
        geo=[(a>>16)&0xffff for a,_ in Z2]; chr_=[a&0xffff for a,_ in Z2]
        tex=[(d>>16)&0xffff for _,d in Z2]
        print('    waiting for the bus: geometry %.1f%%  glyph fetch %.1f%%  texels %.1f%%'
              % (100*med3(geo)/FR, 100*med3(chr_)/FR, 100*med3(tex)/FR))
    print('    (bus busy near 100%% with everyone waiting = BANDWIDTH; idle bus with a'
          ' queue = BLOCKED, and the fixes are opposites)')

def mf16(v):
    # R334: 8-bit IEEE exponent + top 8 mantissa bits, sign dropped.
    e = (v >> 8) & 0xff
    if e == 0: return 0.0
    m = 1.0 + ((v & 0xff) / 256.0)
    return m * (2.0 ** (e - 127))

if D:
    # R346: the question every DDR3 decision rests on -- what does a round trip
    # actually cost here, with the HPS competing? SDRAM's is 13 cycles.
    a, d = D[-1]
    last  = (a >> 16) & 0xffff
    stuck_wr = (a >> 15) & 1
    mx    = a & 0x7fff
    late, lines = (d >> 16) & 0xffff, d & 0xffff
    print('DDR3 (R358): framebuffer -- %d lines fetched, %d asked for early' % (lines, late))
    print('    round trip: last COMPLETED %d cycles   (SDRAM is 13 at 100 MHz)' % last)
    print('    longest IN FLIGHT: %d cycles, on a %s' % (mx, 'WRITE' if stuck_wr else 'read'))
    if mx == 0:
        print('    (zero = no transfer ever started: the master is not talking to DDR3)')
    elif mx >= 0x7fff:
        print('    *** SATURATED: a transfer has been in flight for 32,767+ cycles.')
        print('        The bridge has taken a request and never finished it, which')
        print('        wedges the arbiter and starves every other master. The %s'
              % ('WRITE' if stuck_wr else 'read'))
        print('        path is the one that hung.')
    elif mx > 4 * 262:
        print('    (a burst is ~262 cycles; anything far above that is the bridge stalling)')
    if late:
        print('    (asked-early means a line was requested before the last one landed:')
        print('     a line of warning is not enough, and the picture will tear)')

if F:
    # R359: the framebuffer publishes on COMPLETION. pub counts whole frames
    # handed to the display; drop counts lists that arrived while the last one
    # was still drawing and were abandoned in place. A frozen picture is drop
    # climbing with pub flat -- which is the failure the band path could not
    # express, because it showed partial frames instead of holding complete ones.
    a, d = F[-1]
    pub, drop = a & 0xffff, (a >> 16) & 0xffff
    print('framebuffer (R359): %d frames published, %d lists dropped  (16-bit, wraps)'
          % (pub, drop))
    if len(F) > 1:
        a0, d0 = F[0]
        dp = (pub - (a0 & 0xffff)) & 0xffff
        dd = (drop - ((a0 >> 16) & 0xffff)) & 0xffff
        print('    over the capture: +%d published, +%d dropped' % (dp, dd))
        if dp == 0 and dd:
            print('    (nothing published: the fill never finishes a whole list --')
            print('     the picture is frozen on the last complete frame)')
    print('    pixels painted, last sample: %d' % d)

if N:
    # R364: WHERE IS IT STUCK? "0 lines, 0 pixels, nothing in flight" fits
    # several faults that need opposite fixes, so this names the state directly.
    WST = {0:'IDLE', 1:'HEAD', 2:'BODY', 3:'TAIL', 4:'WAIT', 5:'DONE',
           6:'CLR', 7:'CLRW'}
    RST = {0:'IDLE', 1:'REQ (asked, no beat came back)',
           2:'FILL (beats came, no ack)', 3:'?'}
    import collections
    cw = collections.Counter(); cr = collections.Counter(); ca = collections.Counter()
    clears = 0
    for a, d in N:
        cw[a & 0xf] += 1
        cr[(a >> 4) & 3] += 1
        ca[((a >> 8) & 1, (a >> 7) & 1)] += 1
        clears = (a >> 16) & 0xffff
    spans = N[-1][1] & 0xffff
    acks  = (N[-1][1] >> 16) & 0xffff
    print('FRAMEBUFFER STATE (R364): %d clear passes COMPLETED' % clears)
    print('    writer state:  ' + ', '.join('%s x%d' % (WST.get(k, k), v)
                                            for k, v in cw.most_common(3)))
    print('    reader state:  ' + ', '.join('%s x%d' % (RST.get(k, k), v)
                                            for k, v in cr.most_common(3)))
    for (own, bsy), v in ca.most_common(3):
        print('    arbiter: busy=%d owner=%s  x%d' % (bsy, 'writer' if own else 'reader', v))
    print('    spans accepted by the writer: %d' % spans)
    # R366: the two ends of the same handshake. m2_ddr3 counts every ack it
    # issues; m2_fb_read counts every line it completes, which needs one.
    lines_seen = (D[-1][1] & 0xffff) if D else 0
    print('    acknowledges ISSUED by m2_ddr3: %d   lines COMPLETED by the reader: %d'
          % (acks, lines_seen))
    if acks and not lines_seen:
        print('    *** ACKNOWLEDGES ARE BEING LOST BETWEEN THE MASTER AND THE READER.')
        print('        m2_ddr3 finished transfers that m2_fb_read never saw finish,')
        print('        so the fault is in the arbiter routing or the reader FSM,')
        print('        NOT in DDR3 and not in the burst.')
    elif not acks:
        print('    (no acknowledge was ever issued: the master never completed a')
        print('     transfer, so look at the request path, not the routing)')
    if clears == 0:
        print('    *** NO CLEAR EVER COMPLETED. in_ready stays low and clear_busy')
        print('        stays high, so the span path is jammed AND the fill is held')
        print('        in C_IDLE. Everything else follows from this one fact.')
    if spans == 0 and clears:
        print('    (clears finish but no span was ever offered: the fault is UPSTREAM')
        print('     of the writer, in the fill or the span walk, not in DDR3)')

if P:
    # R363: IS THE GAME AT FULL SPEED? The i960 is 25 MHz and the frame is
    # 1/60 s, so a frame is 416,667 CPU cycles. Instructions retired against
    # that is the machine's pace, and the CPU port's wait is why it is not
    # higher. R362 measured 24.5% waiting with the renderer alive and 0.0% with
    # it dead -- so this is the renderer's cost to the CPU, read directly.
    CPU_HZ, FPS = 25.0e6, 60.0
    cyc = CPU_HZ / FPS
    ipf = [a & 0xffffff for a, d in P]
    wt  = [d & 0x1fffff for a, d in P]
    ipf.sort(); wt.sort()
    med_i, med_w = ipf[len(ipf)//2], wt[len(wt)//2]
    print('CPU PACE (R363): %d instructions retired per frame (med of %d samples)'
          % (med_i, len(P)))
    print('    %.3f per CPU cycle, against a %d-cycle frame at 25 MHz / 60 Hz'
          % (med_i / cyc, int(cyc)))
    # bwl_cpu counts clk_mem cycles (100 MHz), so the frame there is 1.667 M
    print('    the CPU port waited %d cycles a frame -- %.1f%% of it'
          % (med_w, 100.0 * med_w / (100.0e6 / FPS)))
    if med_i == 0:
        print('    (zero retired = the CPU is halted or trapped, not merely slow)')
    print('    min %d  max %d  (a steady figure is a steady frame rate)'
          % (ipf[0], ipf[-1]))

if Z:
    # R334: 1/z per vertex. Sanity, not accuracy -- these should be small
    # positive numbers (z is a view-space depth), and a run of zeros means the
    # reciprocal is not reaching the store.
    vals = []
    for a, d in Z:
        for v in ((a >> 16) & 0xffff, a & 0xffff, (d >> 16) & 0xffff, d & 0xffff):
            vals.append(mf16(v))
    nz = [v for v in vals if v > 0]
    print('1/z (R334): %d samples, %d nonzero (%.1f%%)' % (len(vals), len(nz), 100.0*len(nz)/max(1,len(vals))))
    if nz:
        nz.sort()
        print('    min %.6g  median %.6g  max %.6g   -> z from %.4g to %.4g'
              % (nz[0], nz[len(nz)//2], nz[-1], 1.0/nz[-1], 1.0/nz[0]))
    print('    (all zero = the reciprocal is not arriving; a huge spread inside one')
    print('     quad is what the perspective divide exists to correct)')

if T:
    # The walker's 32-entry light table, as the board holds it. Luminance is
    # |dot| * diffuse + ambient, so an entry of 0/0 renders every polygon that
    # asks for it black.
    seen = T[-1][0]
    ent = {}
    for a, d in T:
        ent[(d >> 24) & 0x1f] = ((d >> 16) & 0xff, (d >> 8) & 0xff)
    cmds = T[-1][1] & 0xff
    print('LIGHT TABLE (R251): geo op 0x06 seen %d times; entries written mask %08X (%d of 32)'
          % (cmds, seen, bin(seen).count('1')))
    print('   ', ' '.join('%d:%d/%d%s' % (k, v[0], v[1], '' if (seen >> k) & 1 else '!')
                          for k, v in sorted(ent.items())))
    print('    (! = the list never wrote it, so it reads 0/0 and every polygon using it is black)')
print(' slice  ready ms(med,max)  bands_done         hold(frames-1 per list)      luma med/min/max  black%  wedges(max)  quads x16 (med,max)')
for i in range(0,n,k):
    sl=H[i:i+k]
    if len(sl)<2: continue
    rc=sorted(((a>>16)&0xffff)*16/50000 for a,_ in sl); bd=collections.Counter((a>>8)&0xff for a,_ in sl); hd=collections.Counter(a&0xff for a,_ in sl)
    lm=sorted((d>>24)&0xff for _,d in sl); lz=max((d>>16)&0xff for _,d in sl); gd=max((d>>4)&0x7f for _,d in sl)   # R249: mean luminance, black-polygon %, wedge count
    q=sorted((d&0xff)*16 for _,d in sl)
    print(f'{i:6d}  {rc[len(rc)//2]:6.2f} {rc[-1]:6.2f}   {bd.most_common(3)}   {hd.most_common(4)}   {lm[len(lm)//2]:3d} {lm[0]:3d} {lm[-1]:3d} {lz:3d}   {gd:4d}   {q[len(q)//2]:5d} {q[-1]:5d}')
