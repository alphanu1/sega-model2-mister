#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- R1038: every word of a 2B SHARC program classified by what
# rtl/sharc/m2b_sharc.sv does not do (its unsupported tests restated). Input: R1024 census pc.txt
# files (executed words with counts), or mame_m2b_pmdump.lua dumps ("<addr> <word>" lines).
#   m2b_sclass.py <pc.txt> ...
import sys, collections
FIX_OK={0x01,0x05,0x25,0x29,0x02,0x06,0x26,0x2a,0x0a,0x21,0x22,0x30,0x40,0x41,0x42,0x43,0x61,0x62,0x63}
FLT_OK={0x81,0x82,0x91,0x92,0x89,0x8a,0xa1,0xa2,0xb0,0xbd,0xc1,0xc4,0xc5,0xc9,0xca,0xd9,0xda,0xe0,0xe1,0xe2,0xe3}
SH_OK={0x00,0x08,0x01,0x02,0x10,0x11,0x12,0x13,0x19,0x30,0x31,0x32,0x33}
def b(op,h,l): return (op>>l)&((1<<(h-l+1))-1)
def ureg_ok(u,wr):
    g,r=u>>4,u&15
    if g in (0,1,2): return True
    if g in (3,4): return wr
    if g==6: return r in (4,7,8) or (not wr and r==5)
    if g==7: return r in (0,1,9,10,11,12,13,14)
    if g==0xd: return r in (11,12,13)
    return False
def comp_class(c):
    if c==0: return None
    if b(c,22,22):
        mop=b(c,21,16)
        if b(mop,5,3)==3: return None
        return 'multi_mop%02x'%mop
    cu=b(c,21,20); cop=b(c,19,12)
    if cu==0:
        if not (cop&0x80):
            if (cop>>4)==7: return 'dual_addsub_fix'
            if cop not in FIX_OK: return 'fixalu_%02x'%cop
            return None
        if (cop>>4)==0xf: return 'dual_addsub_flt'
        if cop not in FLT_OK: return 'fltalu_%02x'%cop
        return None
    if cu==1: return None if cop==0x30 else 'mul_%02x'%cop
    if cu==2: return None if (cop>>2) in SH_OK else 'shift_%02x'%(cop>>2)
    return 'cu3'
def classify(op):
    r=[]; t=b(op,47,39); top3=b(op,47,45); top4=b(op,47,44)
    comp=None
    if top3==1: r.append('type1_dual_move'); comp=b(op,22,0)
    elif t>>1==0b00000001: comp=b(op,22,0)
    elif top4 in (4,5):
        comp=b(op,22,0)
        if b(op,32,32): r.append('pm_bus')
        else:
            u=b(op,30,23)
            if not ureg_ok(u, not b(op,31,31)): r.append('ureg_%02x'%u)
    elif top4==6:
        comp=b(op,22,0)
        if b(op,40,40): r.append('pm_bus')
    elif top4==7:
        comp=b(op,22,0); us=b(op,43,36); ud=b(op,30,23)
        if not ureg_ok(us,False): r.append('ureg_%02x'%us)
        if not ureg_ok(ud,True): r.append('ureg_%02x'%ud)
    elif top4==8:
        if b(op,32,32): r.append('pm_bus')
        so=b(op,21,16)
        if so not in SH_OK: r.append('shift_%02x'%so)
    elif t>>1==0b00000010:
        so=b(op,21,16)
        if so not in SH_OK: r.append('shift_%02x'%so)
    elif t==0b000001000 or t==0b000001001: comp=b(op,22,0)   # 0x04 compute modify
    elif t>>2==0b0000100: comp=b(op,22,0)
    elif top3==0b110 or top3==0b111: comp=b(op,22,0)
    elif t>>1 in (0b00001010,0b00001011):
        comp=b(op,22,0)
        if b(op,40,40): r.append('rti')
    elif t>>1==0b00010111: r.append('push_pop_stacks')
    elif t>>3==0b000100:
        if b(op,41,41): r.append('pm_bus')
        elif not ureg_ok(b(op,39,32), not b(op,40,40)): r.append('ureg_%02x'%b(op,39,32))
    elif top3==0b101:
        if b(op,44,44): r.append('pm_bus')
        elif not ureg_ok(b(op,39,32), not b(op,40,40)): r.append('ureg_%02x'%b(op,39,32))
    elif top4==9:
        if b(op,37,37): r.append('pm_bus')
    elif t>>1==0b00001111:
        if not ureg_ok(b(op,39,32),True): r.append('ureg_%02x'%b(op,39,32))
    elif t>>1==0b00010100:
        k=b(op,39,37); reg=b(op,35,32)
        if not ureg_ok(0x70|reg,True) or k==3 or k>5: r.append('bitop_%x_%x'%(k,reg))
    elif t==0b000101100: pass
    elif t in (0x00c,0x00d,0x00e,0x00f) or t>>1 in (0b00001100,0b00001101,0b00001110): pass  # jumps / calls / DO
    elif t==0: pass
    else: r.append('form_%03x'%t)
    if t>>1 in (0b00001100,0b00001101,0b00001110) and b(op,42,40)==5 and not ureg_ok(b(op,39,32),False): r.append('ureg_%02x'%b(op,39,32))
    cc=comp_class(comp) if comp is not None else None
    if cc: r.append(cc)
    return r
for path in sys.argv[1:]:
    tot=collections.Counter(); st=collections.Counter(); ex=collections.defaultdict(str); allw=0
    for ln in open(path):
        if ln.startswith('#'): continue
        p=ln.split(None,4)
        if len(p)==2: p=p+['1','1']          # a pmdump line: each nonzero word once
        if len(p)<4: continue
        pc=int(p[0],16); op=int(p[1],16); n=int(p[2])
        if op==0: continue
        allw+=n
        for k in classify(op):
            tot[k]+=n; st[k]+=1
            if not ex[k]: ex[k]='%x %s'%(pc,p[4].strip() if len(p)>4 else '')
    print('==',path.split('/')[-2],'words executed %d, distinct %d'%(allw,sum(1 for _ in open(path))))
    for k,v in sorted(tot.items(),key=lambda x:-x[1]):
        print('   %-22s %12d exec %5d pcs   e.g. %s'%(k,v,st[k],ex[k][:90]))
