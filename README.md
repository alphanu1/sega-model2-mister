<!-- SPDX-License-Identifier: GPL-3.0-or-later
     Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1 -->

# Sega Model 2A-CRX for MiSTer

An FPGA implementation of Sega's Model 2A-CRX arcade board for the
[MiSTer](https://mister-devel.github.io/MkDocs_MiSTer/) platform, targeting the
DE10-Nano's Cyclone V `5CSEBA6U23I7`.

**This is a work in progress and does not play games yet.** What follows is what
is actually built and measured, not a plan.

## State

| | |
|---|---|
| **i960KB CPU** | Complete. Runs Daytona's real boot ROM with a program-counter stream identical to MAME's for 803,355 instructions. |
| **2D tilemap (S24TILE)** | Pixel-exact against MAME — ten frames, 190,464/190,464 pixels each. |
| **SDRAM controller** | Five ports, 64 MB geometry, verified against the packed ROM image on hardware region by region. |
| **I/O board** | Handshake answered on hardware. The boot does not yet clear the exchange that follows. |
| **Sound board** | Not started. The 68000 (fx68k) builds, simulates and executes; the audio devices are not written. |
| **3D renderer** | Not started. |
| **TGP / copro** | Stubbed, not implemented. `fifo_control` answers "finished" and the board identifies itself with the real `tgpid` string; the FIFO at `0x00884000`, `copro_ctl1` and `geo_ctl1` are not modelled. Measured as not gating the current boot — MAME's boot trace touches the region once. |

On hardware the i960 executes, services interrupts and does not trap. It stops
in the I/O board exchange; `docs/io-board.md` records exactly what has been
eliminated and what has not.

**Resources**, Quartus 17.0, `5CSEBA6U23I7`: 17,719 ALM (42%), 255 M10K (46%),
43 DSP (38%), timing closed with no negative slack. The design question this
project is organised around is whether the i960 and a 3D renderer together fit
under roughly 25,000 ALM — see `docs/model2a-design-study.md` §5.

## Building

Quartus Prime **Lite 17.0.0 Build 595** is the only supported toolchain. Later
versions infer memory differently and the MiSTer framework targets 17.0.x.

```
quartus_sh --flow compile Model2      # the bitstream, ~25 minutes
make release                          # package .rbf and .mra, refusing a stale build
```

`make release` checks source timestamps against the bitstream and the reported
flow status, because a stale `.rbf` has shipped twice.

## Testing

Everything is simulated before it reaches the fitter. Verilator 5.050 and
iverilog.

```
make lint      # every RTL module, -Wall
make test      # the whole suite
```

The suite covers each i960 unit, the FPU, whole-CPU lockstep against a
transcription of MAME, real ROM execution, the SDRAM controller across three
module geometries, the ROM loader, the CPU bridge, the video timing and a
whole-frame render, the 68000, and the I/O board.

**Differential testing against MAME** is the instrument this project leans on
hardest, and `docs/differential-testing.md` explains why and what it cannot do:

```
tools/i960-diff.sh [ms] [set]        # our PC stream against MAME's, instruction by instruction
tools/i960-resync-diff.py            # the same, across wait loops the two machines spin differently
tools/m2-framediff.sh                # a rendered frame against MAME's, demanding 100%
tools/rom_csum.py <mra> <dir> --scan # what each 2 MB of the ROM image should fold to
```

Simulation cannot see memory inference. Only a Quartus build can tell you
whether an array landed in M10K or in flip-flops, and it reports success either
way — check the register count, not the `ramstyle` tag.

## ROMs

**No ROM, ROM fragment, or ROM-derived binary is in this repository and none
ever will be.** `.mra` files describing a layout are fine; the bytes are not.
`docs/rom-layout.md` describes what a set must contain and how to build the
test images from MAME.

## Layout

```
Model2.sv               top level
rtl/cpu/i960/           the i960KB
rtl/video/              tilemap, palette, timing
rtl/mem/                SDRAM controller
rtl/io/                 ROM loader, CPU bridge, I/O board, backup SRAM
sim/                    testbenches, one directory per area
tools/                  differential scripts, MAME instrumentation, deployment
docs/                   the design study, and one file per subsystem
third_party/            vendored cores, each recorded in THIRD_PARTY.md
```

## Documents

- **`docs/model2a-design-study.md`** — the binding one. What fits, what has an
  oracle, what has a licence, and §10: every finding that turned out wrong, what
  was believed, and how it was corrected. Read the relevant section before
  making a design decision.
- `docs/milestones.md` — order of work.
- `docs/differential-testing.md` — the method, and its limits.
- `docs/io-board.md`, `docs/rom-layout.md`, `docs/mister-integration.md`.
- `HANDOFF.md` — current state and everything open.

The recorded failures in §10 are the most useful part of this repository. Six
separate defects here were a model gentler than the thing it modelled, and
several were found only because the wrong answer had been written down the first
time.

## Third party

Recorded in `THIRD_PARTY.md` with upstream, commit, licence, and what was
changed:

- **[fx68k](https://github.com/ijor/fx68k)** — cycle-exact 68000, GPL-3.0, for
  the sound CPU.
- **[MAME](https://www.mamedev.org/)** — the oracle. Not linked or distributed;
  used as a reference implementation to compare against.
- **[sega-model1-mister](https://github.com/alphanu1/sega-model1-mister)** —
  sibling project. The I/O board is the same physical device, and several
  measurements were taken from its findings rather than repeated.

## Licence

GPL-3.0-or-later. See `LICENSE`. Every source file carries an SPDX header.
