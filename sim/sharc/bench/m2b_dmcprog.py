#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- R1031: a directed SHARC program for the DM cache (m2b_dmc),
# for tb_m2b_sharc +lock +noidle built with a small DM_AW (block-1 words from 0x30100 off chip).
# Neither Dead or Alive nor the random programs write a word of a line while that word's fill
# read is in flight (R1031: two planted faults on that path passed both); this does it on every
# block, at every word position of the line:
#   R3 = DM(c, I0)        a miss: the fill starts at word c and the read is answered when c lands;
#                         the fill's read of word c + 1 goes out at once
#   DM(c + 1, I0) = Rk    a write to that word while its read is in flight (a long +lat)
#   R4 = DM(c + 1, I0)    must read Rk, not the word the fill brings back
#   DM(c + 2, I0) = R4    and a write to a word whose read has not gone out yet
#   R5 = DM(c + 2, I0)
#   R6 = DM(c + 3, I0)    waits for the fill to reach c + 3 (the in-flight read of c + 1 has
#                         landed by then)
#   R7 = DM(c + 1, I0)    still Rk: the landing must not have overwritten it
#   I0 = I0 + 0x40        the next block, a line not cached
# The lockstep against v1 compares R3-R7 at every word. Generated, not ROM-derived.
#   m2b_dmcprog.py <out events.bin> [line words, 16] [blocks, 160]
import struct, sys


def main():
    out = sys.argv[1]
    W = int(sys.argv[2]) if len(sys.argv) > 2 else 16
    nb = int(sys.argv[3]) if len(sys.argv) > 3 else 160
    prog = []
    base = 0x20080

    def emit(w): prog.append(w)

    def imm(u, v): emit((0x0f << 40) | (u << 32) | (v & 0xffffffff))

    def dm(i, d, off, dr):      # type 4: DM(off, Ii) <-> dreg, no update (pre-modify by the 6-bit offset)
        emit((0b0110 << 44) | (i << 41) | (0 << 40) | (d << 39) | (0 << 38) | (0x1f << 33) |
             ((off & 0x3f) << 27) | (dr << 23))

    imm(0x7b, 0x18000)          # MODE1: TRUNC + RND32, as the games
    imm(0x7a, 0x60000)          # MODE2
    top = base + len(prog)
    imm(0x10, 0x30200)          # I0
    for k in range(8, 16):
        imm(k, 0x11111111 * (k - 7))
    for b in range(nb):
        c = b % W
        dm(0, 0, c, 3)
        dm(0, 1, (c + 1) % W, 8 + b % 8)
        dm(0, 0, (c + 1) % W, 4)
        dm(0, 1, (c + 2) % W, 4)
        dm(0, 0, (c + 2) % W, 5)
        dm(0, 0, (c + 3) % W, 6)
        dm(0, 0, (c + 1) % W, 7)
        imm(0x10, 0x30200 + 0x40 * (b + 1))
    emit((0x06 << 40) | (0x1f << 33) | top)    # JUMP back (I0 to 0x30200 again)
    pm = {base + k: w & 0xffffffffffff for k, w in enumerate(prog)}
    pm[0x20005] = (0x06 << 40) | (0x1f << 33) | base
    end = max(pm) + 1
    ev = bytearray()

    def rec(t, a, b): ev.extend(struct.pack('<BII', ord(t), a & 0xffffffff, b & 0xffffffff))
    for reg, val in [(0x1c, 0), (0x1c, 0), (0x40, 0), (0x40, 2), (0x41, 1), (0x41, 0),
                     (0x42, (end - 0x20000) & 0xffff), (0x42, 0), (0x1c, 0xa1), (0x1c, 0)]:
        rec('H', reg, val)
    n = 0
    for a in range(0x20000, end):
        w = pm.get(a, 0)
        for k in range(3):
            rec('U', n, (w >> (16 * k)) & 0xffff); n += 1
    rec('B', n, 0)
    open(out, 'wb').write(ev)
    print('%d program words, %d upload words' % (len(prog), n))


if __name__ == '__main__':
    main()
