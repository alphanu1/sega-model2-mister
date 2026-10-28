# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
# i960 audit against Intel's manuals (docs/i960-intel-audit.md).
import random,struct
from fractions import Fraction as F
def to_single_rne(fr):
    # correctly round a positive/negative Fraction to IEEE single (normal range assumed)
    import math
    if fr==0: return 0.0
    s=-1 if fr<0 else 1; a=abs(fr)
    e=math.floor(math.log2(a.numerator)-math.log2(a.denominator))
    while F(2)**e>a: e-=1
    while F(2)**(e+1)<=a: e+=1
    q=a/F(2)**(e-23); n=q.numerator//q.denominator; r=q-n
    if r>F(1,2) or (r==F(1,2) and n%2==1): n+=1
    return s*float(F(n)*F(2)**(e-23))
def f32(x): return struct.unpack('<f',struct.pack('<f',x))[0]
random.seed(1); N=300000; bad={'mul':0,'add':0,'div':0}
for i in range(N):
    x=random.uniform(-1000,1000)            # a double held in fp0-fp3 (53 bits)
    y=f32(random.uniform(-1000,1000))       # a single in a register
    for op in bad:
        if op=='mul': ex=F(x)*F(y); md=x*y
        elif op=='add': ex=F(x)+F(y); md=x+y
        else: ex=F(x)/F(y); md=x/y
        if f32(md)!=to_single_rne(ex): bad[op]+=1
print(N,bad)
