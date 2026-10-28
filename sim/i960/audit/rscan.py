# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
# i960 audit against Intel's manuals (docs/i960-intel-audit.md).
# scan program ROM for rounding-mode-sensitive FP ops; write bphits BP_FILE lines
import sys,zipfile,struct
RN=['pfp','sp','rip']+['r%d'%i for i in range(3,16)]+['g%d'%i for i in range(15)]+['fp']
WANT={(0x6c,0):'cvtri',(0x6c,1):'cvtril',(0x68,0xb):'roundr',(0x69,0xb):'roundrl'}
zipf=sys.argv[1]; out=sys.argv[2]; pairs=sys.argv[3:]
z=zipfile.ZipFile(zipf); names={n.split('/')[-1]:n for n in z.namelist()}
prog=bytearray()
for k in range(0,len(pairs),2):
    lo,hi=z.read(names[pairs[k]]),z.read(names[pairs[k+1]])
    for i in range(0,len(lo),2): prog+=lo[i:i+2]+hi[i:i+2]
cnt={}
with open(out,'w') as f:
    for pc in range(0,len(prog)-3,4):
        w=struct.unpack_from('<I',prog,pc)[0]
        k=(w>>24,(w>>7)&0xf)
        if k in WANT:
            m1=(w>>11)&1; s1=w&0x1f
            if m1: reg = 'fpsrc%d'%s1 if s1<4 else 'lit%d'%s1
            else: reg=RN[s1] if not k in((0x69,0xb),) else RN[s1&0x1e]+' '+RN[(s1&0x1e)+1]
            cnt[WANT[k]]=cnt.get(WANT[k],0)+1
            if m1: f.write('%x %s ac\n'%(pc,WANT[k]))     # fp-register source: log only AC
            else:  f.write('%x %s %s ac\n'%(pc,WANT[k],reg))
print(zipf, len(prog), cnt)
