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
U=[]     # R255: walk records
pend=None
for line in open(sys.argv[1],errors='replace'):
    p=line.split()
    if len(p)!=3 or len(p[1])!=8 or len(p[2])!=8: continue
    try: a=int(p[1],16); d=int(p[2],16)
    except: continue
    if p[0]=='C': C.append((a,d))
    elif p[0]=='H': H.append((a,d))
    elif p[0]=='T': T.append((a,d))     # R251: the light table
    elif p[0]=='U': U.append((a,d))     # R255: the walk's own numbers
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
    objs=[(d>>16)&0xffff for _,d in U]; unk=[(d>>8)&0xff for _,d in U]; drp=[d&0xff for _,d in U]
    nops.sort(); ops.sort(); objs.sort()
    print('WALK (R255): per frame -- nops decoded med %d max %d | commands med %d | objects med %d | unknown op %02X | push drops %d'
          % (nops[len(nops)//2], nops[-1], ops[len(ops)//2], objs[len(objs)//2], max(unk), max(drp)))
    print('    (nops should be ZERO: the reference list holds none, so any run of them is the walk reading data as commands)')
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
