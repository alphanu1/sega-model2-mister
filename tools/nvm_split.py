#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
#
# Split a MiSTer NVRAM save (16 KB, the MRA's <nvram index="2">) into the four
# byte-lane hex files m2_backup's arrays load from, so a board's REAL warm
# state can boot the simulation. The file lands on the SD card at
# /media/fat/config/nvram/<setname>.nvm once the framework saves it.
import sys
raw = open(sys.argv[1], 'rb').read()
raw = raw + b'\xff' * (16384 - len(raw))
out = sys.argv[2] if len(sys.argv) > 2 else 'bak'
for lane in range(4):
    with open(f"{out}{lane}.hex", 'w') as f:
        for w in range(4096):
            f.write(f"{raw[w*4+lane]:02x}\n")
print(f"wrote {out}0..3.hex (4096 bytes each)")
