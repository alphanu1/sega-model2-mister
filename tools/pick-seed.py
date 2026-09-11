#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# Pick the seed to put on the board from a tools/seed-pair.sh build directory.
#
# THE RULE, WRITTEN DOWN BECAUSE "BEST SETUP NUMBER" GOT IT WRONG (R236): a seed
# is eligible only if hold is positive on every clock AND no core clock (the
# emu PLL: memory, core, i960, video) misses setup. A miss on the framework's
# HDMI PLL alone is tolerated -- every working build of this project has had
# one. Among the eligible, the best worst-setup wins. Seed 11 of build/fix3d4
# had the best setup figure of the batch, -0.022, and it was on the MEMORY
# clock; seed 14's -0.172 was the HDMI PLL's. The number alone chose wrong.
#
#   tools/pick-seed.py build/fix3d4          -> prints the seed, or nothing
import sys, re, glob, os
d = sys.argv[1]
best = None
for sta in sorted(glob.glob(os.path.join(d, 's*', 'output_files', 'Model2.sta.rpt'))):
    seed = re.search(r'/s(\d+)/', sta).group(1)
    txt = open(sta, errors='replace').read()
    def table(name):
        i = txt.find('; ' + name)
        rows = []
        if i < 0: return rows
        # The table is: header row, a '+---' rule, the column names, another
        # rule, then the rows, then a rule. Skip the rules; stop at the first
        # line that is neither a rule nor a row.
        for line in txt[i:].splitlines()[1:60]:
            if line.startswith('+'): continue
            if not line.startswith(';'): break
            f = [x.strip() for x in line.split(';')]
            if len(f) > 3 and re.match(r'^-?\d+\.\d+$', f[2]): rows.append((f[1], float(f[2])))
        return rows
    setup, hold = table('Setup Summary'), table('Hold Summary')
    if not setup: continue
    core_miss = [c for c, s in setup if s < 0 and 'emu|pll' in c]
    hold_neg  = [c for c, s in hold  if s < 0]
    worst     = min(s for _, s in setup)
    ok = not core_miss and not hold_neg
    print(f"  s{seed}: worst setup {worst:+.3f}  {'OK' if ok else 'REJECT'}"
          + (f"  core-clock miss: {core_miss[0][:40]}" if core_miss else '')
          + (f"  hold miss: {hold_neg[0][:40]}" if hold_neg else ''), file=sys.stderr)
    if ok and (best is None or worst > best[1]): best = (seed, worst)
print(best[0] if best else '')
