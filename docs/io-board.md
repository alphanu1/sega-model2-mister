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

**THE BOARD SUPPLIES THIS BLOCK AND THE i960 COPIES IT INTO BACKUP SRAM.** It is
the same as Model 1 after all.

This file said the opposite for one build, and the correction is the useful
part. The window's contents are byte-for-byte what MAME's `backup1` NVRAM holds
at `0x1d00000`, and that was read as the i960 copying its backup SRAM *outward*.
**A correlation between two memories does not carry a direction.** The
disassembly does:

```
00228230: lda  0x1c00200,g6      ; g6 = DPRAM window   -- the SOURCE
00228238: lda  0x1d00000,g5      ; g5 = backup SRAM    -- the DESTINATION
00228240: ldob 0x1c00040,g4      ; wait flag == 0
0022824C: ldob 0x1c00042,g4      ; wait status == 0x40
0022825C: mov  3,g2
00228260: stob g2,0x1c00040      ; command 3
00228268: ldob 0x1c00040,g4      ; wait flag == 0
0022827C: ldob (g6),g4           ; then copy 128 bytes,
00228280: stob g4,(g5)           ; DPRAM at stride 2 -> SRAM at stride 1
002282CC: ble  0x0022827c
```

Model 1's `122988c` had already established exactly this on exactly this board —
*"the V60 block-reads all of it once, immediately after its first handshake is
answered, and will not go on to poll its controls until it has… ours read zeros
and looped at `fe1433` forever"* — and it was read, quoted into this file, and
then overridden by the misreading.

**What it cost:** one hardware build. The board answered the handshake perfectly
— overlay row 14 read `1A400000`: awake, status `0x40`, flag cleared — and the
i960 then copied 128 bytes of M10K power-up zeros into backup SRAM, rejected
them, and span in `0x2282xx` with **4,097 tile writes** against simulation's
12,292. The same 4,097 the old sound-constant stub produced, which is what a
boot that never gets past this block looks like.

So the board's part is: **push all 128 bytes** of the block, and **set status
`0x21` to `0x40`**. Then the CPU drives the flag `01 -> 03 -> 02 -> 01` and the
flag clears at frame 174 (R37).

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

## Two things the boot disproved, and they are the design

**The status byte is not a reply to the window write.** That was the first model
— frame 6 the i960 writes its block, frame 7 the status goes to `0x40`, so the
one causes the other. The boot disproved it in a single run by parking at

```
0022824C: ldob    0x1c00042,g4      ; status
00228254: setbit  6,0,g1            ; 0x40
00228258: cmpibne g4,g1,0x22824c    ; spin until status == 0x40
0022825C: mov     3,g2
00228260: stob    g2,0x1c00040      ; only THEN write the flag again
```

It waits for `0x40` **before** it writes the window at all. Two events in
consecutive frames are not a cause and an effect, and reading them as one
produced a board the boot could never get past. The status is on the board's
own schedule.

**The flag is not cleared once.** MAME clears it exactly once, at frame 174, so
the first model cleared it once. That is a description of the reference's
*timeline*, not of the board's behaviour, and it deadlocks: our i960 is about
three times slower per frame, so it had not yet written its command when the
single clear fired. The clear landed on nothing and the command that followed
was never answered — the boot parked at `00228268 / 00228270`, the next poll
along.

Modelled as Model 1 established it — **not listening until the self-test
finishes, answering after that** — it no longer depends on the two machines
running at the same speed.

**Known divergence, stated rather than hidden:** on the reference the flag
*stays* set after boot, re-raised once a frame as a doorbell and never cleared
again. Ours clears it every time. Right for the phase the boot is in, wrong
afterwards, and the differential will say when it starts to matter.

## Result

With the board modelled, the boot no longer traps:

| | distinct IPs | interrupts | outcome |
|---|---|---|---|
| sound-constant stub | 2,205 | 175 | **trapped** at IP 0, null pointer |
| I/O board | 1,355 | 74 | runs 25,000,000 instructions, no trap |

The differential agrees to **2,609,803** MAME instructions and then diverges
where MAME takes an interrupt mid-loop and we do not:

```
-1    mame=00000b20  ours=00000b20      stos r8,0x18000(r4)
>>>   mame=00000e00  ours=00000b28      stq  g0,(sp)   <- a handler prologue
```

That is the natural limit of a PC comparison between machines of different
speeds: an asynchronous interrupt lands at a different instruction, and no
resynchronisation can or should paper over it. Past this point the meaningful
comparison is of DATA, not of program counters.

## What is not established

Whether daytona93 polls the input region at `0x00-0x0e` the way Model 1 does,
and what it expects there. Model 1's layout — `0x00-0x07` scanned panel,
`0x08-0x0a` IN.0/1/2, `0x0b-0x0d` DIP banks, `0x0e` port 6 — is from the same
Z80 ROM and should carry over, but "should" is not a measurement and this
project has spent a session on the difference.
