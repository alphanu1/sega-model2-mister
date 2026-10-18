#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# scsp_cap2tr.py <out.tr> <seconds> <capture dir> (study R885): MAME's p16
# capture as a scsp_split trace -- every access before slot 0 of the sample
# MAME logged it against (MAME's semantics), MAME's own mix as the samples.
import sys, numpy as np
C=sys.argv[3] if len(sys.argv)>3 else '.'
N=int(float(sys.argv[2])*44100)
rec=np.dtype([('n','<u4'),('off','<u2'),('data','<u2'),('mask','<u2'),('pad','<u2')])
r=np.fromfile(C+'/regs.bin',dtype=rec); r=r[(r['n']<N)&(r['pad']==0)]
rw=np.fromfile(C+'/ramw.bin',dtype=np.dtype([('n','<u4'),('a','<u4'),('dm','<u4')]),count=int(N*12))
rw=rw[rw['n']<N]
o=np.fromfile(C+'/out.bin',dtype='<i4',count=N*2).reshape(-1,2)
# one stream ordered by n; within n: register writes, RAM writes (the capture keeps no finer order)
ev=[]
be=((r['mask']&0xff00)!=0)*2+((r['mask']&0xff)!=0)
for n,off,d,b in zip(r['n'],r['off'],r['data'],be): ev.append((int(n),0,'W 0 %03x %04x %d 0'%(off>>1,d,b)))
for n,a,dm in zip(rw['n'],rw['a'],rw['dm']): ev.append((int(n),1,'M 0 %05x %04x %04x'%((a&0x7fffe)>>1,dm&0xffff,dm>>16)))
ev.sort(key=lambda e:(e[0],e[1]))
with open(sys.argv[1],'w') as f:
    j=0
    for n in range(N):
        while j<len(ev) and ev[j][0]<=n:
            t=ev[j][2]; f.write('%s %d %s\n'%(t[0],n,t[2:])); j+=1
        f.write('O %d %d %d\n'%(n,o[n,0],o[n,1]))
print('written', len(ev), 'accesses,', N, 'samples')
