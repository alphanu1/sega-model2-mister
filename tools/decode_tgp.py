#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# Decode the TGP hang probe (R923; VERILOG_MACRO "M2_PROBE=1" + "M2_PROBE_TGP=1"):
#   decode_tgp.py <uart capture> [--all]
#
# Records (one every 2.46 ms, a state record and a ring record in turn):
#   C {i960 IP} | {copro_stall, TGP unimplemented, frozen, 13'd0, TGP pc}
#   h {m2_copro dbg_fifo} | {m2_tgp dbg_hs}                 (flags below)
#   j {i960 pushed : TGP popped} | {TGP pushed : i960 popped}  16-bit running
#   p {last word the i960 pushed} | {last word the TGP popped}
#   x {last word the TGP produced} | {output words dropped : input words dropped}
#   i {TGP io address : TGP retires} | {TGP program word}
#   a {io_sel, io_we, trap, halted, 0, i960 I/O address} | {TGP bank, longest stall}
#   r {frozen, 0, write index, this index, vblank[5:0], kind} | {word}
#       kind 0 FIFO-port push, 1 function-port push (command = bits 30:23),
#       2 the i960 popped a result, 3 a copro_ctl1 write
# The ring stops taking words once the i960 has been held by the coprocessor
# for 2^23 clk_sys cycles (105 ms), so a frozen ring is the 256 transfers
# before the hang.
import sys

STATES = ["S_FETCH", "S_FETCH_W", "S_DECODE", "S_SRC", "S_SRC_W", "S_LABB",
          "S_LABB_W", "S_DST", "S_DST_W", "S_ALU", "S_RETIRE", "S_BRUL_RD",
          "S_BRUL_W", "S_LAB_WA", "S_LAB_WB", "?15"]
KIND = ["push", "CMD ", "pop ", "ctl "]
FIFO_BITS = [(31, "halted"), (30, "uploading"), (29, "fin_valid"), (28, "fin_full"),
             (27, "fout_valid"), (26, "fout_full"), (25, "push_hold"), (24, "wq_busy"),
             (23, "i960_reads_fifo"), (22, "i960_writes_fifo"), (21, "i960_fn_write"),
             (20, "stall")]
HS_BITS = [(31, "core_run"), (26, "io_rd"), (25, "io_wr"), (24, "io_ack"),
           (23, "tbl_req"), (22, "tbl_ack"), (21, "dat_req"), (20, "dat_ack"),
           (19, "bufw_req"), (18, "bufw_ack"), (17, "wq_busy"), (16, "posted_ack"),
           (15, "fifo_rd"), (14, "fifo_wr"), (13, "fifo_ack"), (12, "popped"),
           (11, "pushed"), (10, "in_valid"), (9, "out_full"), (8, "sel_buf"),
           (7, "sel_rom"), (6, "sel_math"), (5, "buf_rd_ok"), (4, "wr_hi"), (0, "UNIMPL")]


def flags(v, bits):
    return " ".join(n for b, n in bits if (v >> b) & 1)


def main():
    if len(sys.argv) < 2:
        print(__doc__ if __doc__ else "usage: decode_tgp.py <capture> [--all]")
        sys.exit(2)
    show_all = "--all" in sys.argv
    recs = []
    for l in open(sys.argv[1], errors="ignore"):
        p = l.split()
        if len(p) != 3 or len(p[0]) != 1 or len(p[1]) != 8 or len(p[2]) != 8:
            continue
        try:
            recs.append((p[0], int(p[1], 16), int(p[2], 16)))
        except ValueError:
            pass
    if not recs:
        print("no records")
        return
    by = {}
    for t, a, d in recs:
        by.setdefault(t, []).append((a, d))
    print("records: " + ", ".join("%s %d" % (k, len(v)) for k, v in sorted(by.items())))

    C = by.get("C", [])
    if C:
        st = sum(1 for a, d in C if d >> 31)
        fz = [i for i, (a, d) in enumerate(C) if (d >> 29) & 1]
        print("C: %d records, copro_stall in %d (%.1f%%); ring frozen from record %s" % (
            len(C), st, 100.0 * st / len(C), fz[0] if fz else "never"))
        tail = C[-min(len(C), 200):]
        ips = {}
        pcs = {}
        for a, d in tail:
            ips[a] = ips.get(a, 0) + 1
            pcs[d & 0xffff] = pcs.get(d & 0xffff, 0) + 1
        print("  last %d C: i960 IP %s" % (len(tail), ", ".join(
            "%08x x%d" % kv for kv in sorted(ips.items(), key=lambda kv: -kv[1])[:6])))
        print("  last %d C: TGP pc  %s" % (len(tail), ", ".join(
            "%03x x%d" % kv for kv in sorted(pcs.items(), key=lambda kv: -kv[1])[:6])))
        if any((d >> 30) & 1 for a, d in tail):
            print("  TGP UNIMPLEMENTED OPCODE flag set")

    def last(t):
        v = by.get(t, [])
        return v[-1] if v else None

    def moving(t, f):
        v = by.get(t, [])[-20:]
        return len(set(f(a, d) for a, d in v)) > 1 if len(v) > 1 else None

    h = last("h")
    if h:
        fa, hs = h
        print("h: copro  %s | fin %d words, fout %d words" % (flags(fa, FIFO_BITS), (fa >> 8) & 0xff, fa & 0xff))
        print("   tgp    state %s | %s" % (STATES[(hs >> 27) & 15], flags(hs, HS_BITS)))
        if moving("h", lambda a, d: (a, d)):
            print("   (h still changing over the last 20 records)")
    j = last("j")
    if j:
        a, d = j
        ip, tp, to, io = a >> 16, a & 0xffff, d >> 16, d & 0xffff
        print("j: i960 pushed %d, TGP popped %d (fin %d); TGP pushed %d, i960 popped %d (fout %d)  [mod 65536]" % (
            ip, tp, (ip - tp) & 0xffff, to, io, (to - io) & 0xffff))
    p = last("p")
    if p:
        print("p: last i960 push %08x (cmd %02x if a function-port word) | last TGP pop %08x" % (
            p[0], (p[0] >> 23) & 0xff, p[1]))
    x = last("x")
    if x:
        print("x: last TGP output %08x | output words dropped %d, input words dropped %d" % (
            x[0], x[1] >> 16, x[1] & 0xffff))
    i = last("i")
    if i:
        print("i: TGP io address %04x, retires %d, program word %08x" % (i[0] >> 16, i[0] & 0xffff, i[1]))
        mv = moving("i", lambda a, d: a & 0xffff)
        if mv is not None:
            print("   TGP retire count %s over the last 20 i records" % ("MOVING" if mv else "STILL"))
    a_ = last("a")
    if a_:
        a, d = a_
        print("a: i960 io_sel %d io_we %d trap %d halted %d, I/O address %06x | TGP bank %02x, longest copro_stall %d cycles (%.1f ms)" % (
            a >> 31, (a >> 30) & 1, (a >> 29) & 1, (a >> 28) & 1, a & 0xffffff, d >> 24,
            d & 0xffffff, (d & 0xffffff) / 80000.0))

    # ---- the ring: the newest complete pass
    R = by.get("r", [])
    if R:
        ent = {}
        wp = None
        frozen = False
        for a, d in R:
            frozen = bool(a >> 31)
            wp = (a >> 16) & 0xff
            ent[(a >> 8) & 0xff] = (a & 0xff, d, frozen)
        print("ring: %d entries seen, %s, write index %02x" % (
            len(ent), "FROZEN at the hang" if frozen else "live (not frozen: entries may be of different ages)", wp))
        order = [(wp + k) & 0xff for k in range(256)]
        rows = [(k, ent[k]) for k in order if k in ent]
        if not show_all:
            rows = rows[-96:]
        for k, (tag, w, fz) in rows:
            kind = tag & 3
            vb = tag >> 2
            extra = ""
            if kind == 1:
                extra = "  command %02x" % ((w >> 23) & 0xff)
            elif kind == 3:
                extra = "  bit31 %d" % (w >> 31)
            print("  [%02x] vbl %2d %s %08x%s" % (k, vb, KIND[kind], w, extra))

    # ---- verdict
    if h and C:
        fa, hs = h
        stall = C[-1][1] >> 31
        st = STATES[(hs >> 27) & 15]
        print("VERDICT:", end=" ")
        if not stall:
            print("the i960 is not held by the coprocessor at the end of the capture.")
        elif (fa >> 31) & 1:
            print("the TGP is HALTED (copro_ctl1 bit 31) and the i960 waits on it.")
        elif not (hs >> 31) & 1:
            print("the TGP core is still in its release delay / reset.")
        elif (fa >> 25) & 1:
            print("the i960 is held pushing into a FULL input FIFO and the TGP is not draining it (state %s)." % st)
        elif (fa >> 23) & 1 and (fa >> 27) & 1 and (fa >> 24) & 1:
            print("a result word is waiting but the i960's read is held on POSTED BUFFER-RAM WRITES that do not drain "
                  "(bufw_req %d, bufw_ack %d)." % ((hs >> 19) & 1, (hs >> 18) & 1))
        elif (fa >> 23) & 1 and not (fa >> 27) & 1:
            if st == "S_SRC" and (hs >> 15) & 1 and not (hs >> 10) & 1:
                print("DEADLOCK BY COUNT: the i960 waits for a result and the TGP waits for an input word (state S_SRC, "
                      "input FIFO empty). The two disagree on how many words the command has: a word lost or "
                      "duplicated on one side, or the TGP took a different path. The ring has the command.")
            elif (hs >> 26) & 1 or (hs >> 25) & 1:
                which = "tables (port 8)" if (hs >> 23) & 1 else "data ROM / buffer RAM (port 9)" if (hs >> 21) & 1 \
                    else "posted buffer-RAM write queue" if (hs >> 25) & 1 else "io"
                print("the TGP waits on an io access that is never acknowledged: %s, io address in the i record "
                      "(state %s, io_ack %d)." % (which, st, (hs >> 24) & 1))
            else:
                print("the i960 waits for a result, the TGP is in %s and not waiting on a FIFO -- a long loop "
                      "or a livelock: see whether its retire count moves." % st)
        else:
            print("the i960 is held but not on a FIFO read (flags above).")


if __name__ == "__main__":
    main()
