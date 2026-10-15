<!-- SPDX-License-Identifier: GPL-3.0-or-later
     Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1 -->

# Sega Model 2 for MiSTer

An FPGA recreation of Sega's Model 2 arcade board, the original Model 2 that
Daytona USA runs on, for [MiSTer](https://mister-devel.github.io/MkDocs_MiSTer/)
on the DE10-Nano (Cyclone V `5CSEBA6U23I7`).

**Daytona USA runs at the arcade's speed**, both the Deluxe '93 set and the
1994 Revision A: textured, lit 3D over the 2D layers, full sound, 57 frames a
second in attract and in races. It's still a beta, and the list of what's left
is below.

**To play it, go to [`releases/`](releases/).** That has the core, the MRAs,
and a README covering the ROMs you need, the settings and the controls.

**Only the original Model 2 for now.** The later boards (Model 2A-CRX, 2B-CRX
and 2C-CRX) use different hardware, and each will need its own branch with
those parts swapped in. Virtua Cop needs a different I/O board (light guns),
so it will be a separate core for the same reason. Desert Tank uses Daytona's
I/O board and runs on this core with its own MRA (work in progress).
`mra/` also has a Virtua Cop MRA that loads its ROMs but doesn't run yet, and
a 2D tilemap test pattern.

## Where it stands

| | |
|---|---|
| **i960KB CPU** | Complete. Runs Daytona's real boot code instruction for instruction against MAME (803,355 instructions in lockstep), with an 8 KB instruction cache and a fetch path tuned on the game's own code. |
| **TGP coprocessor** | The MB86233 runs the game's own microcode, which the core extracts from the data ROM. On a recorded race its results match MAME's, apart from how a few NaNs are encoded. |
| **3D** | Display-list walker, geometry (transform, lighting, clipping, projection), and a textured, mip-mapped rasteriser drawing front to back into a DDR3 framebuffer. A frame is only shown once it's complete. |
| **2D tilemap** | Pixel-exact against MAME. A four-line buffer ring stops it dropping scanlines on busy screens. |
| **Sound board** | Its own 68000 (fx68k), the YM3438 (jt12), and both MultiPCM sample chips on one shared engine. Levels match MAME's to within about a dB. |
| **I/O board** | The real Z80 program running on the real board design, shared with the Model 1 core. |
| **SDRAM** | Thirteen ports, 64 MB, read timing fixed (not calibrated) since it was proven there's only one right setting. |
| **Speed** | 57 of 57.5 frames a second in attract and in a race, 99% of frames on time. The main CPU sets the pace now, not the 3D. |
| **Video** | Native 24 kHz, and 15 kHz interlaced for CRTs at 15.1, 15.4 or 15.7 kHz, with MRAs that start straight in 15 kHz. |

### What's left

- **Confirmation from CRT and wheel owners**, and long runs of the Deluxe '93
  set.
- **MiSTer's audio filter** is switched off to save space (see Building). It
  comes back once everything else is in, if there's room.

`HANDOFF.md` has the day-to-day state and the measurements behind it.

## Milestones

`docs/milestones.md` sets the order of work and the pass/fail criteria each
phase was held to.

| | Phase | State |
|---|---|---|
| **P0** | Measure before building | Done. The approach was costed from instrumented MAME and from other cores on this chip, not guessed. |
| **P1** | i960KB CPU | Done, including lockstep against MAME on the real boot ROM. |
| **P1.5** | 2D on hardware | Done, pixel-exact against MAME. |
| **P4** | TGP coprocessor | Done. |
| **P5** | Sound | Done. |
| **P2** | 3D renderer | Done. |
| **P3** | Does it fit? | Yes, but only just: 98 to 99% of the FPGA. Recent savings freed a little room for what's left. |
| **P6** | Integration | Released as a beta, running at the arcade's speed. |

They're listed in the order they were finished. The coprocessor and the sound
board came before the renderer because each had a working design to learn
from and the renderer didn't.

## Building

Quartus Prime **Lite 17.0.0 Build 595** is the only supported version. Newer
versions infer memory differently, and the MiSTer framework targets 17.0.x.

```
quartus_sh --flow compile Model2      # the bitstream, about 25 minutes
make release                          # packages the .rbf and .mra, and refuses a stale build
tools/seed-sweep.sh 3 1000            # fit three seeds at once and report which closed
```

The design fills 98 to 99% of the chip, so whether a build meets timing comes
down to the fitter seed, and it's normal for some seeds to miss. Every
release is a seed that meets every core clock, tested on the board. If you
build it yourself and get a black screen, try a different `SEED` in
`Model2.qsf` before suspecting anything else.

`make release` compares the source timestamps against the bitstream, because
a stale `.rbf` has been shipped by mistake before.

### The framework carries one patch

`sys/` is MiSTer-devel's framework, unchanged except for one small switchable
patch, `docs/framework-patches/audio-filter-disable.patch`. With
`MISTER_DISABLE_AUDIO_FILTER` set in `Model2.qsf` it leaves out MiSTer's audio
filter, which saves about 430 ALM. The game's sound is unaffected; only
MiSTer's filter presets stop doing anything on this core. It's meant to be
temporary: drop the macro and the file builds exactly as upstream.

If you update `sys/` from Template_MiSTer, re-apply it:

```
git apply docs/framework-patches/audio-filter-disable.patch
```

If it doesn't apply cleanly, `docs/framework-patches/README.md` describes the
three-line change. Without it the build still works, but the filter comes back
and takes that room.

## Testing

Everything is simulated before it goes near the fitter, with Verilator and
iverilog.

```
make lint      # every RTL module, -Wall
make test      # the whole suite
```

The suite covers every i960 unit and the FPU, whole-CPU lockstep against a
transcription of MAME, real ROM execution, the SDRAM controller, the ROM
loader, the CPU bridge, video timing and whole-frame renders, the TGP, the
geometry and 3D pipeline stage by stage, the texture cache, the 68000, the
sound board against MAME's own register streams, and the I/O board.

Comparing against MAME is the tool this project leans on most, and
`docs/differential-testing.md` explains why and where it falls short:

```
tools/i960-diff.sh [ms] [set]        # our CPU against MAME's, instruction by instruction
tools/i960-resync-diff.py            # the same, across wait loops the two spin differently
tools/m2-framediff.sh                # a rendered frame against MAME's
tools/rom_csum.py <mra> <dir> --scan # what each 2 MB of the ROM image should add up to
```

Simulation doesn't have the last word, though. The same code that drew 478
polygons in a testbench once drew none on the board, and simulation can't
tell you whether Quartus put a memory in block RAM or in flip-flops. When the
bench and the board disagree, the board wins. MAME isn't the last word either:
it's a reference for what the chips compute, and a few things it gets wrong
had to be worked out from the hardware.

## ROMs

No ROM, piece of a ROM, or anything built from ROM data is in this repository,
and none ever will be. MRA files describing the layout are fine; the bytes are
not. `docs/rom-layout.md` describes what a set must contain.

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
tools/                  comparison scripts, MAME instrumentation, deployment
docs/                   the design study, and one file per subsystem
third_party/            outside cores, each recorded in THIRD_PARTY.md
```

## Documents

- **`docs/model2a-design-study.md`** is the main one: what fits, what's been
  checked against what, what has a licence, and, in §10, every finding that
  turned out to be wrong, what was believed and how it was corrected.
- `docs/milestones.md`: the order of work.
- `docs/differential-testing.md`: the method and its limits.
- `docs/io-board.md`, `docs/rom-layout.md`, `docs/mister-integration.md`.
- `HANDOFF.md`: the current state and everything open.

The recorded mistakes in §10 are honestly the most useful part of the
repository. Several bugs here were a model that was gentler than the thing
it modelled, and more than one was only found because the wrong answer had
been written down the first time.

## Third party

Each is recorded in `THIRD_PARTY.md` with its source, commit, licence and what
was changed:

- **[sega-model1-mister](https://github.com/alphanu1/sega-model1-mister)**, the
  sister project and the reference for this one: a working Sega renderer on the
  same chip. The TGP came from it, and the I/O board is the same device.
- **[fx68k](https://github.com/ijor/fx68k)**, a cycle-exact 68000 (GPL-3.0),
  for the sound CPU.
- **[jt12](https://github.com/jotego/jt12)**, the FM chip (GPL-3.0), by Jose
  Tejada.
- **[meathax/s32](https://github.com/meathax/s32)**, the MultiPCM (GPL-3.0),
  with its volume and pan brought in line with MAME and both chips sharing one
  engine.
- **tv80**, by Guy Hutchison after Daniel Wallner's T80, for the I/O board's
  Z80.
- **[MAME](https://www.mamedev.org/)**, as a reference for what the hardware
  computes. Not linked or distributed.

## Licence

GPL-3.0-or-later. See `LICENSE`. Every source file carries an SPDX header.
