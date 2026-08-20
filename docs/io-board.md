<!-- SPDX-License-Identifier: GPL-3.0-or-later
     Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1 -->

# The I/O board, as measured on daytona93

The boot parks polling `0x01c00040` and does not proceed. That byte is **not the
sound board**. `model2.cpp`'s `model2o` map puts an MB8421 dual-port RAM at
`0x01c00000-0x01c00fff`, and the **left** side of it belongs to
`SEGA_MODEL1IO` — the I/O board. The sound board is a `SEGAM1AUDIO` behind an
i8251 UART at `0x01c80000`, which the boot never touches. Study R40.

It is **literally the same board as Model 1's**: `SEGA_MODEL1IO` with BIOS
`epr14869c`, a Z80 behind a 315-5338A running `EPR-14869`. Not an analogue. Later
Model 2 games differ — `vcop` replaces it with `SEGA_MODEL1IO2` / `epr17181` —
so this file is about `model2o`.

## Addressing

The DPRAM is 2K×8 behind `umask32(0x00ff00ff)`, so it occupies **bytes 0 and 2 of
each dword**:

```
DPRAM byte N  ->  0x01c00000 + (N >> 1) * 4 + (N & 1) * 2
```

| DPRAM | i960 address | what |
|---|---|---|
| `0x20` | `0x01c00040` | request flag — the byte the boot polls |
| `0x21` | `0x01c00042` | status |
| `0x100-0x17f` | `0x01c00200-0x01c002fe` | the 128-byte exchange window |

Those first two are exactly the pair R37 traced without knowing what they were.
Model 1's flag is at `0xc00040` and is DPRAM `0x20` as well, by the same ×2
mapping — the same offset on the same board.

## The exchange, measured

`tools/mame_m2_idblock.lua` samples the window **every frame** and records only
changes. Over 400 frames it has three distinct states:

| frame | flag `0x20` | status `0x21` | window `0x100-0x17f` |
|---|---|---|---|
| 1 | `01` | `00` | all zero |
| 6 | `01` | `00` | `0x00-0x42` written, rest still zero |
| 7 | `01` | `40` | `0x43-0x7b` = `ff`, `0x7c-0x7f` = `01 00 00 00` |

```
00: 53 45 47 41 40 82 01 00 bc eb 00 00 00 ff ff ff   "SEGA" + configuration
10: 00 01 01 01 00 03 03 00 00 00 00 01 ff ff ff ff
20: 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
30: 02 02 14 1c 00 01 00 01 04 01 ff ff ff ff ff ff
```

**THE CPU WRITES THIS BLOCK; THE BOARD DOES NOT SUPPLY IT.** That is the
opposite of Model 1, where the V60 block-*reads* an identity block the board
pushes, and where a core that left the window empty looped forever with every
input byte underneath it already correct (their `122988c`). Here the bytes are
byte-for-byte what MAME's `backup1` NVRAM holds at `0x1d00000` — the i960 copies
its backup SRAM outward.

So the board's part of this exchange is: **complete the window** (`0x43-0x7b` to
`ff`, `0x7c` to `01`) and **set status `0x21` to `0x40`**, at frame 7. Then the
CPU drives the flag `01 -> 03 -> 02 -> 01`, and the flag finally clears to `00`
at frame 174 (R37).

### Frame 6 is a partial write

At frame 6 the window holds the first `0x43` bytes and zeros after. **A snapshot
taken there would have produced a table that is two-thirds real and one-third
wrong**, which is precisely how Model 1 got six bytes wrong — one of them
gating the coprocessor path — from a single sample taken while the Z80 was
still filling the window (their `6e5aed4`). Their note is worth carrying:

> a table checked against itself proves only that it is self-consistent — and
> that safeguard did not work, because typing ONE READING out twice is still one
> reading.

Sampling every frame and recording changes is what makes the partial state
visible as a state rather than as the answer.

## Constraints on the implementation

- **One shared write port, not two.** The MB8421 is a true dual-port RAM. Model 1
  measured what asking Quartus 17.0 for two write ports costs: **192 ALM becoming
  16,059**. We have roughly 7,400 ALM of headroom under the ~25,000 budget, so a
  true dual-port DPRAM would end the fit on its own.
- **Sweep at the board's rate, not every free cycle.** Model 1's `6fd28aa`
  records that refreshing whenever the port is free is what turns a rare
  collision into a constant one; the real Z80 sweeps once per loop at 4 MHz.
- **The flag is a command code, not a doorbell** (their `779a0b4`): `1`
  acknowledges by writing `0` back, `2` copies the window into the board's own
  RAM, `3` clears and restarts. A responder that clears on any non-zero write is
  correct for `1` — which is why boot gets as far as it does — and silently
  wrong for `2` and `3`.
- **The turnaround is not a mailbox latency.** 740,684 cycles at 19.2 MHz on
  Model 1, because it is the board's Z80 running its own power-on self-test, and
  it happens once. Our flag clears at frame 174, which is the same shape.

## What is not established

Whether daytona93 polls the input region at `0x00-0x0e` the way Model 1 does,
and what it expects there. Model 1's layout — `0x00-0x07` scanned panel,
`0x08-0x0a` IN.0/1/2, `0x0b-0x0d` DIP banks, `0x0e` port 6 — is from the same
Z80 ROM and should carry over, but "should" is not a measurement and this
project has spent a session on the difference.
