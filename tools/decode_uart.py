#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# Decode a debug UART capture (tools/board-capture.sh) for the stream layout of
# 2026-09-11 (Model2.sv, m2_dbg_stream):
#   C records: a_data = {cpu_trap, cpu_halted, copro_stall, copro_dbg_ctl[31],
#              vid_vscr[0][5:0], vid_vscr[1][5:0], tgp_pc[15:0]}
#   H records: b_addr = {r3d_ready_cyc[15:0] (x16 clk), r3d_bands_done[7:0], r3d_hold[7:0]}
#              b_data = {r3d_dropped[15:0], r3d_tiny[11:4], r3d_quads[11:4]}
# Prints where the i960 spends its time (frame wait, mailbox poll, render), the
# TGP's commonest PCs, and per fifth of the capture the renderer's ready time,
# bands completed per video frame, frames a list was held, store drops, tiny
# quads refused and quads per list. Change the layout in Model2.sv and this
# file together.
#   python3 tools/decode_uart.py capture.txt
import sys,collections
C=[];H=[]
for line in open(sys.argv[1],errors='replace'):
    p=line.split()
    if len(p)!=3 or len(p[1])!=8 or len(p[2])!=8: continue
    try: a=int(p[1],16); d=int(p[2],16)
    except: continue
    (C if p[0]=='C' else H).append((a,d))
ip=collections.Counter(a for a,_ in C); pc=collections.Counter(d&0xffff for _,d in C)
live=sum(v for k,v in ip.items() if k!=0)
def rng(a,b): return sum(v for k,v in ip.items() if a<=k<b)
print('C',len(C),'H',len(H),' framewait %.1f%%'%(100*(ip[0x12b0]+ip[0x12b8])/max(1,live)),' mailbox %.1f%%'%(100*(ip[0x1166c]+ip[0x11674])/max(1,live)),' render %.1f%%'%(100*rng(0x16e58,0x17b00)/max(1,live)))
print('tgp  :',', '.join(f'{k:04X}:{v}' for k,v in pc.most_common(4)))
# b_addr = {ready_cyc16 (x16), bands_done8, hold8}; b_data = {qs_dropped16, geo_dropped8, quads[11:4]}
n=len(H); k=max(1,n//5)
print(' slice  ready ms(med,max)  bands_done         hold(frames-1 per list)      store dropped(max)  tiny refused x16(max)  quads x16 (med,max)')
for i in range(0,n,k):
    sl=H[i:i+k]
    if len(sl)<2: continue
    rc=sorted(((a>>16)&0xffff)*16/50000 for a,_ in sl); bd=collections.Counter((a>>8)&0xff for a,_ in sl); hd=collections.Counter(a&0xff for a,_ in sl)
    qd=max((d>>16)&0xffff for _,d in sl); gd=max(((d>>8)&0xff)*16 for _,d in sl)
    q=sorted((d&0xff)*16 for _,d in sl)
    print(f'{i:6d}  {rc[len(rc)//2]:6.2f} {rc[-1]:6.2f}   {bd.most_common(3)}   {hd.most_common(4)}   {qd:6d}   {gd:4d}   {q[len(q)//2]:5d} {q[-1]:5d}')
