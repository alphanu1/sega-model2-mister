#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# R721: what the i960 waits on, from a telemetry-lite capture
# (M2_DEBUG_LITE; tools/uart_capture.py on the board).
#
#   python3 tools/m2-decode-cpu.py <capture.txt> [first_vblank]
#
# The C record (~135 Hz, sampled) carries the i960's IP and
#   {copro_stall, ts[4:0], req_mem, tgt[2:0], r_we, st[3:0], r_addr[23:16], 9'b0}
# -- the CPU's sequencer state and the bridge's transaction in flight. Each
# sample is booked as the frame-sync wait (IP 0x12B0-0x12BF, R690), the core
# working, or a wait -- and a wait by what the bridge was doing.
import sys, collections

TS = ["T_FETCH", "T_FETCH_W", "T_FETCH2", "T_FETCH2_W", "T_DECODE", "T_EXEC", "T_MEM", "T_MEM_W",
      "T_MULDIV", "T_MULTI", "T_PAIR", "T_FP", "T_WB", "T_FRAME", "T_TRAP", "T_BOOT",
      "T_SYNMOV_RD", "T_SYNMOV_WR", "T_INTR", "T_RET7", "T_MODPC", "T_SYNQ"]
ST = ["S_IDLE", "S_LO", "S_LO_W", "S_HI", "S_HI_W", "S_RDB", "S_IOW", "S_DONE", "S_DCK", "S_RMW", "S_RMW_W"]
TGT = ["SDRAM", "TRAM", "PAL", "XLAT", "IO", "NONE", "?6", "?7"]
SYNC = range(0x12B0, 0x12C0)
WAITS = {"T_FETCH_W", "T_FETCH2_W", "T_MEM_W", "T_SYNMOV_RD", "T_SYNMOV_WR"}

def io_name(a):
    # r_addr[23:16] of an I/O access (Model2.sv's map, model2.cpp's)
    return {0x80: "geometrizer 0x80xxxx (push 0x804000, rp/wp)", 0x88: "TGP FIFO 0x884000",
            0x98: "TGP control / video 0x98xxxx", 0xe8: "interrupts 0xe8xxxx",
            0x90: "buffer RAM 0x90xxxx"}.get(a, "0x%02xxxxx" % a)

first = int(sys.argv[2]) if len(sys.argv) > 2 else 0
vbl = None; v0 = None; C = []
for l in open(sys.argv[1], errors='ignore'):
    f = l.split()
    if len(f) != 3 or len(f[1]) != 8 or len(f[2]) != 8: continue
    try: a = int(f[1], 16); d = int(f[2], 16)
    except ValueError: continue
    if f[0] == 'G':
        v = a & 0xffff
        if v0 is None: v0 = v
        vbl = (v - v0) & 0xffff
    elif f[0] == 'C' and vbl is not None and vbl >= first:
        C.append((a, d))
n = len(C)
if not n: print("no C samples"); sys.exit(0)

book = collections.Counter(); why = collections.Counter(); tsc = collections.Counter()
for ip, d in C:
    stall = (d >> 31) & 1; ts = (d >> 26) & 0x1f
    req = (d >> 25) & 1; tgt = (d >> 22) & 7; we = (d >> 21) & 1; st = (d >> 17) & 0xf; ad = (d >> 9) & 0xff
    tsn = TS[ts] if ts < len(TS) else "T_%d" % ts
    if ip in SYNC: book["frame-sync wait (idle)"] += 1; continue
    tsc[tsn] += 1
    if stall: book["TGP holding the i960 (copro_stall)"] += 1; why["copro_stall"] += 1; continue
    if tsn not in WAITS: book["working (" + ("fetch/decode/exec/other" ) + ")"] += 1; continue
    kind = "instruction fetch" if tsn in ("T_FETCH_W", "T_FETCH2_W") else "data access"
    book["waiting: " + kind] += 1
    stn = ST[st] if st < len(ST) else "S_%d" % st
    if not req and stn == "S_IDLE":
        why[kind + ": nothing in the bridge yet (crossing / icache)"] += 1
    elif TGT[tgt] == "IO":
        why[kind + ": I/O %s %s %s" % ("write" if we else "read", io_name(ad), stn)] += 1
    elif TGT[tgt] == "SDRAM":
        what = ("write" if we else ("cache check" if stn == "S_DCK" else
                ("read miss" if stn == "S_RDB" else "read")))
        why[kind + ": SDRAM %s (%s)" % (what, stn)] += 1
    else:
        why[kind + ": %s %s %s" % (TGT[tgt], "write" if we else "read", stn)] += 1

print("i960, %d samples:" % n)
for k, v in book.most_common(): print("  %5.1f%%  %s" % (100 * v / n, k))
print("\nWhat the waits were (share of ALL samples):")
for k, v in why.most_common(20): print("  %5.1f%%  %s" % (100 * v / n, k))
print("\nSequencer state, outside the frame-sync wait (share of all samples):")
for k, v in tsc.most_common(10): print("  %5.1f%%  %s" % (100 * v / n, k))
