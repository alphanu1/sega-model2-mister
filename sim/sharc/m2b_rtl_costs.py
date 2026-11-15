#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- R1027: the RTL's measured clocks a word, per address, for
# the speed model. tb_m2b_sharc +prof=<file> writes "pc words clocks" (clocks from one word's
# retirement to the next, the FIFOs never waiting); this writes MAME's M2B_COSTF ("pc cost",
# integer cycles) at SCALE cycles a clk_sys, so that M2B_SHARC_HZ = 80 MHz x SCALE keeps a tenth
# of a clock. Addresses the replay never ran keep MAME's default (1 cycle = 1 / SCALE clock).
#   m2b_rtl_costs.py <prof> <costf> [scale=10]
import sys


def main():
    prof, out = sys.argv[1], sys.argv[2]
    scale = int(sys.argv[3]) if len(sys.argv) > 3 else 10
    tw = tc = 0
    rows = []
    for line in open(prof):
        p = line.split()
        if len(p) != 3:
            continue
        pc, w, c = int(p[0], 16), int(p[1]), int(p[2])
        tw += w
        tc += c
        rows.append((pc, w, c))
    with open(out, 'w') as f:
        for pc, w, c in rows:
            f.write('%05x %d\n' % (pc, max(1, round(scale * c / w))))
    print('%d addresses, %d words, %d clocks: %.4f clk_sys a word; costs at %d cycles a clock in %s'
          % (len(rows), tw, tc, tc / tw, scale, out))
    # the dearest addresses
    rows.sort(key=lambda r: -r[2])
    for pc, w, c in rows[:12]:
        print('  %05x  %12d words  %.3f clk a word  %5.2f%% of the clocks' % (pc, w, c / w, 100.0 * c / tc))


if __name__ == '__main__':
    main()
