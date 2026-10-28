# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
# i960 audit against Intel's manuals (docs/i960-intel-audit.md).
import sys,struct,collections,math
def u2f(u): return struct.unpack('<f',struct.pack('<I',u))[0]
for f in sys.argv[1:]:
    pcs=collections.Counter(); kinds=collections.Counter(); ex={}
    for l in open(f):
        p=l.split()
        if p[0]!='V': continue
        pc=int(p[1],16); x=u2f(int(p[2],16)); ac=int(p[3],16)
        mode=(ac>>30)&3
        if math.isnan(x) or abs(x)>=2**31: k='posovf'
        else:
            away=math.copysign(math.floor(abs(x)+0.5),x); rne=round(x)
            k='tie(mode%d) away=%d rne=%d differ=%s'%(mode,away,rne,away!=rne)
            k='tie mode%d %s'%(mode,'odd-differs' if away!=rne else 'same')
        kinds[k]+=1; pcs[(pc,k)]+=1; ex.setdefault(pc,x)
    print('==',f,dict(kinds))
    for (pc,k),n in sorted(pcs.items()): print('   %06x %-24s %4d e.g. %g'%(pc,k,n,ex[pc]))
