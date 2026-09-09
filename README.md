<!-- SPDX-License-Identifier: GPL-3.0-or-later
     Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1 -->

# Sega Model 2A-CRX for MiSTer

An FPGA implementation of Sega's Model 2A-CRX arcade board for the
[MiSTer](https://mister-devel.github.io/MkDocs_MiSTer/) platform, targeting the
DE10-Nano's Cyclone V `5CSEBA6U23I7`.

**This is a work in progress and does not play games yet.** **Daytona USA
(Deluxe '93)** boots, runs its attract mode and makes sound. What it does not do
is draw 3D. It is the only game here — `mra/` holds its MRA and a 2D tilemap
test pattern, nothing else. What follows is what is built and measured, not a
plan.

## State

| | |
|---|---|
| **i960KB CPU** | Complete. Runs Daytona's real boot ROM with a program-counter stream identical to MAME's for 803,355 instructions. On hardware it executes, services interrupts and does not trap. |
| **2D tilemap (S24TILE)** | Pixel-exact against MAME — ten frames, 190,464/190,464 pixels each. |
| **SDRAM controller** | Ten ports (`NPORTS = 10`; the module's own default is 5, which the top level overrides), 64 MB geometry, verified against the packed ROM image on hardware region by region. Read capture depth is calibrated on boot and overridable from the OSD. |
| **I/O board** | Working. The board answers, the exchange completes and the game runs. It needs the I/O board's Z80 ROM, taken from either `model1io.zip` or `daytona93.zip` — both sets carry all three revisions (`epr-14869.25`, `epr-14869b.25`, `epr-14869c.25`) and this core uses **revision C**. The Model 1 core is the same physical board and selects the base revision; both work, and the difference is a revision, not a disagreement. |
| **Sound board** | Working on hardware — the board's own 68000 (fx68k), its FM (jt12) and its MultiPCM samples. |
| **TGP coprocessor** | Implemented. The MB86233 runs, and Daytona's 2,024-word microcode uploads and executes — verified on hardware, not only in simulation. The microcode is **not a separate download**: it lives inside the game's own data ROM and `tools/extract_tgp_microcode.py` locates it. |
| **3D renderer** | Every stage is written and simulated — display-list walker, matrix transform, projection, clipping, quad store and rasteriser. **Nothing reaches the screen yet.** |

### The open problem

The display-list walker runs at frame rate and retires **three opcodes** per
walk, while the game writes **16 kB of list per frame**. The walk is aimed at
the right address in the right memory, the read port is not contended
(`dbg_p4_clash` reads zero on hardware) and it stops on a valid terminator
rather than an unknown opcode. Either the pushes are not landing where the walk
reads, or the game is not emitting geometry. That is the whole remaining
question, and `HANDOFF.md` carries the measurements.

## Milestones

`docs/milestones.md` sets the order of work and holds the detail — the pass and
fail criteria each phase was accepted against. Status as of this commit:

| | Phase | State |
|---|---|---|
| **P0** | Measure before building | **Done.** The costing that decided the approach, taken from instrumented MAME and from other cores on this part rather than estimated. |
| **P1** | i960KB CPU | **Done.** Exit criteria met, including the third — lockstep against MAME on the real boot ROM. |
| **P1.5** | 2D on hardware | **Done.** Renders correctly on hardware, pixel-exact against MAME. |
| **P4** | TGP coprocessor | **Done.** The MB86233 runs on hardware and the game's own microcode uploads and executes. |
| **P5** | Sound | **Done.** Audible on hardware — the sound board's 68000, FM and MultiPCM. |
| **P2** | 3D renderer | **Written, not visible.** Every stage simulates; nothing reaches the screen. |
| **P3** | The fit verdict | **Answered, and it is tight.** Everything fits the device together, with essentially no headroom — which is why debug instruments now have to replace each other rather than accumulate. |
| **P6** | Integration | **In progress.** The game boots, runs attract and plays sound. 3D is the gap. |

The phases are listed here in the order they were completed, not numerically:
P4 and P5 were finished before P2, because the coprocessor and the sound board
each had a working reference to follow and the renderer did not.

### Building this core is not deterministic

On identical source, **three of four fitter seeds produce a bitstream that does
not boot** — the i960 traps at reset and the screen stays black — and static
timing analysis does not predict which. The two best-timed builds of a recent
four-seed set both failed; the one that boots has negative hold slack. This is a
startup race on a path nothing constrains, not lost margin, and it is unsolved.

If you build this yourself and the screen stays black, the build is the first
suspect, not your setup — try another `SEED` in `Model2.qsf`, and see
`tools/seed-pair.sh` below.

**There is no release yet.** No bitstream is published, because a core that
boots, plays sound and draws no 3D is not something to hand anybody as a
release. When there is one it will be a dated `.rbf` and the MRAs, in the layout
MiSTer expects.

## Building

Quartus Prime **Lite 17.0.0 Build 595** is the only supported toolchain. Later
versions infer memory differently and the MiSTer framework targets 17.0.x.

```
quartus_sh --flow compile Model2      # the bitstream, ~25 minutes
make release                          # package .rbf and .mra, refusing a stale build
tools/seed-pair.sh 1604 1607          # one tree at several seeds, in parallel
```

`make release` checks source timestamps against the bitstream and the reported
flow status, because a stale `.rbf` has shipped twice.

`tools/seed-pair.sh` exists because seeds must be compared **within one
session**: `build_id.v` is stamped per build, so two bitstreams built on
different days differ by more than the seed, and that mistake invalidated a
whole measurement once.

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
whole-frame render, the MB86233 and its arithmetic, the geometry pipeline stage
by stage, the 68000, the sound board and the I/O board.

**Differential testing against MAME** is the instrument this project leans on
hardest, and `docs/differential-testing.md` explains why and what it cannot do:

```
tools/i960-diff.sh [ms] [set]        # our PC stream against MAME's, instruction by instruction
tools/i960-resync-diff.py            # the same, across wait loops the two machines spin differently
tools/m2-framediff.sh                # a rendered frame against MAME's, demanding 100%
tools/rom_csum.py <mra> <dir> --scan # what each 2 MB of the ROM image should fold to
```

**Simulation is not the last word, and has been wrong about hardware.** The
same RTL that renders 478 polygons in the bench renders none on the board. Where
the bench and the board disagree, the board wins. Simulation also cannot see
memory inference: only a Quartus build can tell you whether an array landed in
M10K or in flip-flops, and it reports success either way.

## ROMs

**No ROM, ROM fragment, or ROM-derived binary is in this repository and none
ever will be.** `.mra` files describing a layout are fine; the bytes are not.
`docs/rom-layout.md` describes what a set must contain and how to build the
test images from MAME.

## Layout

```
Model2.sv               top level
rtl/cpu/i960/           the i960KB
rtl/tgp/                the MB86233 coprocessor
rtl/video/              tilemap, palette, timing, geometry, rasteriser
rtl/sound/              sound board, 68000, FM, MultiPCM
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

- **[sega-model1-mister](https://github.com/alphanu1/sega-model1-mister)** —
  sibling project, and **the oracle for this one**: a working Sega renderer on
  the same part. The MB86233 came from it with its verification, and the I/O
  board is the same physical device.
- **[fx68k](https://github.com/ijor/fx68k)** — cycle-exact 68000, GPL-3.0, for
  the sound CPU.
- **[jt12](https://github.com/jotego/jt12)** — the FM chip, GPL-3.0, by Jose
  Tejada.
- **[meathax/s32](https://github.com/meathax/s32)** — the MultiPCM, GPL-3.0.
- **[MAME](https://www.mamedev.org/)** — a reference for what the silicon
  computes. Not linked or distributed.

## Licence

GPL-3.0-or-later. See `LICENSE`. Every source file carries an SPDX header.
