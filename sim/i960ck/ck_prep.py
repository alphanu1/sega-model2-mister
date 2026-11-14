#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R1011: MAME's access log after a checkpoint (tools/mame_i960_ck.lua) ->
# what tb_i960_ck replays and compares.
#
#   ck_prep.py <ckdir> [--c2 0|1] [--icr HEX]
#
# From acc.bin: the instruction stream (a read at the ip with ip == pip is an
# instruction's first word; one at the ip with ip != pip its displacement), the
# load / store traffic of each MEM-format instruction (its n words, in order),
# and the interrupt entries. MAME specifics undone here:
#   * a copro FIFO read MAME found empty stalls the i960 (i960_stall: ip back
#     to pip) and the instruction runs again from its first word later, its
#     remaining words only (execute_burst_stall_op). The stalled read is the
#     last FIFO read of the attempt; it is dropped and the attempts merged.
#   * every interrupt line change reads PRCB+20 between instructions, and a
#     take reads PRCB+20 / +24, the vector, and writes the record; MAME's
#     register-cache rule spills frames in call / ret. None of that is the
#     instruction's own traffic: each MEM instruction keeps its first n words,
#     the rest is not compared (the RTL does it through other masters).
#   * an interrupt is found by where it lands: an instruction start at a
#     handler (the interrupt table's entry for a vector the ICR names) that
#     the previous instruction did not branch to.
# Writes insn.bin (<I ip, I flags, d t> per instruction: flags bit 0 the
# handler was entered before it, bits 15:8 the vector) and ops.bin (<I idx,
# I addr, I data, I mask, B we, B io, H 0> per access), and prints a summary.
import struct, sys, os, array

d = sys.argv[1]
c2 = 1
if '--c2' in sys.argv: c2 = int(sys.argv[sys.argv.index('--c2') + 1])
icr = 0x0f0e0d0c   # STCC's (synmov from ROM 0xde0 at boot); --icr for another game
if '--icr' in sys.argv: icr = int(sys.argv[sys.argv.index('--icr') + 1], 16)

st = {}
for ln in open(os.path.join(d, 'state.txt')):
    k, v = ln.split()
    st[k] = float(v) if k == 't' else (int(v) if k == 'frame' else int(v, 16))

def region_io(a):
    # m2_cpu_bridge's decode, in its order: 0 SDRAM / on chip, 1 T_IO, 2 T_NONE
    # (the bridge answers T_NONE itself, 0, with nothing on its I/O port)
    if a < 0x00200000: return 0
    if 0x00200000 <= a < 0x00240000: return 0                    # board RAM (2A / 2C)
    if 0x00500000 <= a < 0x00600000: return 0
    if 0x01080000 <= a < 0x01100000: return 0
    if 0x00900000 <= a < 0x00980000: return 0                    # buffer RAM
    if 0x02000000 <= a < 0x04000000: return 0
    if 0x06000000 <= a < 0x07000000: return 0
    if 0x01000000 <= a < 0x01020000: return 0                    # tile RAM
    if 0x01800000 <= a < 0x01804000: return 0                    # palette (and its 3D mirror)
    if c2 and 0x11000000 <= a < 0x11400000: return 2 if (a >> 20) & 1 else 0
    if c2 and 0x11400000 <= a < 0x11410000: return 0
    if c2 and 0x12000000 <= a < 0x12820000: return 2
    if not c2 and 0x12000000 <= a < 0x12820000: return 0
    if 0x01810000 <= a < 0x0181c000: return 0
    if 0x00800000 <= a < 0x01000000: return 1
    if 0x01020000 <= a < 0x01080000: return 1
    if 0x01a00000 <= a < 0x02000000: return 1
    if a >= 0x10000000: return 1
    return 2

NW = {0x80: 1, 0x82: 1, 0x88: 1, 0x8a: 1, 0x90: 1, 0x92: 1, 0x98: 2, 0x9a: 2, 0xa0: 3, 0xa2: 3,
      0xb0: 4, 0xb2: 4, 0xc0: 1, 0xc2: 1, 0xc8: 1, 0xca: 1}
LOADS = {0x80, 0x88, 0x90, 0x98, 0xa0, 0xb0, 0xc0, 0xc8}

def is_fifo(a): return 0x00884000 <= a < 0x00888000

# handler addresses: the interrupt table in the board RAM dump
mem = {}
for fn in os.listdir(d):
    if fn.startswith('mem_') and fn.endswith('.bin'):
        mem[int(fn[4:12], 16)] = open(os.path.join(d, fn), 'rb').read()
def rd32(a):
    for b, m in mem.items():
        if b <= a and a + 4 <= b + len(m): return struct.unpack_from('<I', m, a - b)[0]
    return None
prcb = st['prcb']
itab = rd32(prcb + 20)
handlers = {}
if itab is not None:
    for v in range(8, 256):
        h = rd32(itab + 36 + (v - 8) * 4)
        if h is not None: handlers.setdefault(h, v)
icr_vecs = [((icr or 0) >> (8 * i)) & 0xff for i in range(4)]
hv = {}
for v in icr_vecs:
    if v >= 8:
        h = rd32(itab + 36 + (v - 8) * 4)
        if h is not None: hv[h] = v
print(f'prcb {prcb:08x} itab {itab or 0:08x} icr {icr or 0:08x} handlers ' +
      ' '.join(f'v{v:02x}@{h:08x}' for h, v in hv.items()))

R = struct.Struct('<cIIIIId')
raw = open(os.path.join(d, 'acc.bin'), 'rb').read()
n = len(raw) // R.size

ins_ip = array.array('I'); ins_fl = array.array('I'); ins_t = array.array('d')
ops = bytearray()
OP = struct.Struct('<IIIIBBH')
cur = None          # [ip, word, attempt accesses (list), merged good accesses]
stalls = extra_n = unstalled = 0
over = 0
frames = []

def finalize(c):
    global extra_n, over
    ip, w, att, good = c
    op = w >> 24
    good = good + att
    if op in NW:
        # n words; an unaligned word is four byte accesses, an unaligned half
        # two (MAME's i960_*_unaligned, and the RTL's i960_lsu byte split)
        sz = 1 if op in (0x80, 0x82, 0xc0, 0xc2) else 2 if op in (0x88, 0x8a, 0xc8, 0xca) else 4
        k = 0; p_ = 0
        for _w in range(NW[op]):
            if p_ >= len(good): break
            m_ = good[p_][3]
            byte = m_ in (0xff, 0xff00, 0xff0000, 0xff000000)
            n_ = (4 if sz == 4 else 2 if sz == 2 else 1) if (byte and sz > 1) else 1
            p_ += n_; k += n_
        own = good[:k]
        if len(good) > k: extra_n += len(good) - k
        if len(own) < k: over += 1
        idx = len(ins_ip) - 1
        for (kind, a, v, mk, _ip) in own:
            ops.extend(OP.pack(idx, a, v, mk, 1 if kind == b'W' else 0, region_io(a), 0))

prev_ip = None
for i in range(n):
    k, a, v, mk, ip, pip, t = R.unpack_from(raw, i * R.size)
    if k == b'F':
        frames.append((a, t, len(ins_ip)))
        continue
    if k == b'R' and a == ip:
        if ip != pip: continue                      # a displacement word
        if cur is not None and cur[0] == a and (cur[1] >> 24) in LOADS:
            # the same load from its first word again: MAME's burst-stall resume
            att = cur[2]
            for j in range(len(att) - 1, -1, -1):
                if att[j][0] == b'R' and is_fifo(att[j][1]):
                    del att[j]; break
            cur[3] = cur[3] + att; cur[2] = []
            stalls += 1
            continue
        if cur is not None and a in hv and (cur[1] >> 24) in LOADS and itab is not None:
            # An interrupt taken while a load sat stalled: MAME's take reads the
            # vector with m_IP still rewound to the load (i960_stall), so the
            # load had not executed -- it runs again after the handler's ret.
            # The resume ip is in the tap's ip field of the vector read.
            res = [x for x in cur[2] if x[0] == b'R' and itab + 36 <= x[1] < itab + 36 + 4 * 248]
            if res and res[-1][4] == cur[0] and not cur[3]:
                ins_ip.pop(); ins_fl.pop(); ins_t.pop()
                cur = None; unstalled += 1
        if cur is not None: finalize(cur)
        fl = 0
        if a in hv and prev_ip is not None:
            # entered by the interrupt, unless the instruction before branched there
            fl = 1 | (hv[a] << 8)
        ins_ip.append(a); ins_fl.append(fl); ins_t.append(t)
        cur = [a, v, [], []]
        prev_ip = a
        continue
    if cur is not None: cur[2].append((k, a, v, mk, ip))
if cur is not None: finalize(cur)

# (an entry the previous instruction branched to would be miscounted as an
# interrupt; the bench's PC compare would show it at once)
with open(os.path.join(d, 'insn.bin'), 'wb') as f:
    for j in range(len(ins_ip)):
        f.write(struct.pack('<IId', ins_ip[j], ins_fl[j], ins_t[j]))
open(os.path.join(d, 'ops.bin'), 'wb').write(ops)
nops = len(ops) // OP.size
nirq = sum(1 for x in ins_fl if x & 1)
print(f'records {n}  instructions {len(ins_ip)}  mem ops {nops}  stall resumes {stalls}  '
      f'interrupt entries {nirq} (over a stalled load {unstalled})  extra accesses dropped {extra_n}  short {over}  frames {len(frames)}')
