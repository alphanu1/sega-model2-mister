# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
# i960 audit against Intel's manuals (docs/i960-intel-audit.md).
# Minimal i960 assembler for timing loops. Registers: r0-r15 = 0-15, g0-g15 = 16-31.
import struct
def R(n):
    if isinstance(n, int): return n
    return int(n[1:]) + (16 if n[0] == 'g' else 0)
REGOPS = {
 'notbit':0x580,'and':0x581,'andnot':0x582,'setbit':0x583,'notand':0x584,'xor':0x586,'or':0x587,'nor':0x588,
 'xnor':0x589,'not':0x58a,'ornot':0x58b,'clrbit':0x58c,'notor':0x58d,'nand':0x58e,'alterbit':0x58f,
 'addo':0x590,'addi':0x591,'subo':0x592,'subi':0x593,'shro':0x598,'shrdi':0x59a,'shri':0x59b,'shlo':0x59c,
 'rotate':0x59d,'shli':0x59e,'cmpo':0x5a0,'cmpi':0x5a1,'concmpo':0x5a2,'concmpi':0x5a3,'cmpinco':0x5a4,
 'cmpinci':0x5a5,'cmpdeco':0x5a6,'cmpdeci':0x5a7,'scanbyte':0x5ac,'chkbit':0x5ae,'addc':0x5b0,'subc':0x5b2,
 'mov':0x5cc,'movl':0x5dc,'movt':0x5ec,'movq':0x5fc,'synmov':0x600,'synmovq':0x602,
 'spanbit':0x640,'scanbit':0x641,'dmovt':0x644,'modac':0x645,'modify':0x650,'extract':0x651,'modpc':0x655,
 'calls':0x660,'flushreg':0x66d,'emul':0x670,'ediv':0x671,'cvtir':0x674,'cvtilr':0x675,'scalerl':0x676,'scaler':0x677,
 'atanr':0x680,'logepr':0x681,'logr':0x682,'remr':0x683,'cmpr':0x685,'sqrtr':0x688,'expr':0x689,'logbnr':0x68a,
 'roundr':0x68b,'sinr':0x68c,'cosr':0x68d,'tanr':0x68e,'atanrl':0x690,'cmprl':0x695,'sqrtrl':0x698,'sinrl':0x69c,
 'cosrl':0x69d,'tanrl':0x69e,'cvtri':0x6c0,'cvtril':0x6c1,'cvtzri':0x6c2,'cvtzril':0x6c3,'movr':0x6c9,'movrl':0x6d9,
 'movre':0x6e1,'cpysre':0x6e2,'mulo':0x701,'remo':0x708,'divo':0x70b,'muli':0x741,'remi':0x748,'modi':0x749,'divi':0x74b,
 'divr':0x78b,'mulr':0x78c,'subr':0x78d,'addr':0x78f,'divrl':0x79b,'mulrl':0x79c,'subrl':0x79d,'addrl':0x79f,
}
CTRL = {'b':0x08,'call':0x09,'ret':0x0a,'bal':0x0b,'bno':0x10,'bg':0x11,'be':0x12,'bge':0x13,'bl':0x14,'bne':0x15,'ble':0x16,'bo':0x17}
COBR = {'testno':0x20,'teste':0x22,'testne':0x25,'bbc':0x30,'cmpobg':0x31,'cmpobe':0x32,'cmpobge':0x33,'cmpobl':0x34,
        'cmpobne':0x35,'cmpoble':0x36,'bbs':0x37,'cmpibg':0x39,'cmpibe':0x3a,'cmpibne':0x3d,'cmpibl':0x3c}
MEM = {'ldob':0x80,'stob':0x82,'bx':0x84,'balx':0x85,'callx':0x86,'ldos':0x88,'stos':0x8a,'lda':0x8c,'ld':0x90,'st':0x92,
       'ldl':0x98,'stl':0x9a,'ldt':0xa0,'stt':0xa2,'ldq':0xb0,'stq':0xb2,'ldib':0xc0,'stib':0xc2,'ldis':0xc8,'stis':0xca}
class Asm:
    def __init__(s, base): s.base=base; s.pc=base; s.words={}; s.labels={}; s.fix=[]; s.tags={}
    def tag(s, t): s.tags[s.pc]=t
    def L(s, name): s.labels[name]=s.pc
    def w(s, x): s.words[s.pc]=x & 0xffffffff; s.pc+=4
    def reg(s, op, dst=0, src1=0, src2=0, lit1=False, lit2=False, m3=False, tag=None):
        if tag: s.tags[s.pc]=tag
        o=REGOPS[op]; s.w(((o>>4)<<24)|(R(dst)<<19)|(R(src2)<<14)|(int(m3)<<13)|(int(lit2)<<12)|(int(lit1)<<11)|((o&15)<<7)|R(src1))
    def ctrl(s, op, label, tag=None):
        if tag: s.tags[s.pc]=tag
        s.fix.append((s.pc,'ctrl',label)); s.w(CTRL[op]<<24)
    def cobr(s, op, src1, src2, label, lit1=False, tag=None):
        if tag: s.tags[s.pc]=tag
        s.fix.append((s.pc,'cobr',label)); s.w((COBR[op]<<24)|(R(src1)<<19)|(R(src2)<<14)|(int(lit1)<<13))
    def mema(s, op, reg, off, abase=None, tag=None):   # off <= 4095
        if tag: s.tags[s.pc]=tag
        s.w((MEM[op]<<24)|(R(reg)<<19)|((R(abase) if abase is not None else 0)<<14)|((1 if abase is not None else 0)<<13)|(off&0xfff))
    def memb(s, op, reg, mode, abase=0, index=0, scale=0, disp=None, tag=None):
        if tag: s.tags[s.pc]=tag
        s.w((MEM[op]<<24)|(R(reg)<<19)|(R(abase)<<14)|(1<<12)|(mode<<10)|(scale<<7)|R(index))
        if disp is not None: s.w(disp)
    def li(s, reg, val):  # load 32-bit constant via lda (MEMB mode 0xc, absolute disp)
        if 0 <= val < 4096: s.mema('lda', reg, val)
        else: s.memb('lda', reg, 0xc, disp=val)
    def lf(s, reg, f): s.li(reg, struct.unpack('<I', struct.pack('<f', f))[0])
    def ld64(s, reg, d):
        u = struct.unpack('<Q', struct.pack('<d', d))[0]; s.li(reg, u & 0xffffffff); s.li(R(reg)+1, u >> 32)
    def done(s, path):
        for pc,kind,l in s.fix:
            disp = s.labels[l] - pc
            if kind=='ctrl': s.words[pc] |= disp & 0xfffffc
            else:
                assert -4096 <= disp < 4096, disp
                s.words[pc] |= disp & 0x1ffc
        with open(path,'w') as f:
            for a,w in sorted(s.words.items()): f.write('%x %x\n'%(a,w))
def boot(memwords, prcb=0x800, stack=0x500000, prog=0x1000):
    # SAT at 0, PRCB at 4, IP at 12; PRCB+20 interrupt table, PRCB+24 interrupt stack (= initial FP)
    memwords.update({0:0x100, 4:prcb, 8:0, 12:prog, prcb+20:0x900, prcb+24:stack})
