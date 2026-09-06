#!/usr/bin/env python3
"""Pull Daytona's TGP microcode out of the game program ROM.

The coprocessor has no program ROM of its own. Its 2024-word microcode is
carried inside the i960 program (epr-16534a.6 + epr-16535a.7, interleaved as
ROM_LOAD32_WORD) and pushed to the copro at boot through the FIFO port at
0x00884000 while copro_ctl1 bit 31 is set. So the core needs nothing on the SD
card beyond the ROM the MRA already builds -- this script exists only to give
the simulation bench a copy to run against.

No ROM bytes are committed; this reads the user's own zip and writes outside
the repository.

  usage: extract_tgp_microcode.py daytona93.zip out.bin
"""
import sys, zipfile

# Offset of the microcode inside the interleaved i960 image, and its length.
# Established by dumping :copro_tgp's program space out of MAME after boot and
# searching the ROM for it -- the whole 2024-word block matches verbatim.
MICROCODE_OFF   = 0x60020
MICROCODE_WORDS = 2024
PROGRAM_WORDS   = 2048          # the copro's program RAM, zero-filled above 2024

def main(zip_path, out_path):
    with zipfile.ZipFile(zip_path) as z:
        lo = z.read('epr-16534a.6')
        hi = z.read('epr-16535a.7')
    if len(lo) != len(hi):
        raise SystemExit('program ROM halves differ in size')
    img = bytearray()
    for i in range(0, len(lo), 2):
        img += lo[i:i+2] + hi[i:i+2]
    blob = bytes(img[MICROCODE_OFF:MICROCODE_OFF + MICROCODE_WORDS * 4])
    if len(blob) != MICROCODE_WORDS * 4:
        raise SystemExit('program image too short for the microcode')
    # The first word is the reset vector, an unconditional branch. If this
    # fails the offset is wrong for this ROM revision rather than silently
    # producing garbage.
    first = int.from_bytes(blob[0:4], 'little')
    if (first >> 26) & 63 not in (0x2f, 0x3f):
        raise SystemExit(f'word 0 is {first:08x}, not a branch -- wrong offset?')
    with open(out_path, 'wb') as f:
        f.write(blob)
        f.write(b'\0' * ((PROGRAM_WORDS - MICROCODE_WORDS) * 4))
    print(f'{out_path}: {MICROCODE_WORDS} words of microcode, '
          f'padded to {PROGRAM_WORDS} (reset vector {first:08x})')

if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2])
