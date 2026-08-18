# Third-party code and licences

This project is **GPL-3.0-or-later**, and that is forced rather than chosen: it
ports RTL from `alphanu1/sega-model1-mister`, which is GPL-3, and links the
MiSTer `sys/` framework, which is GPL-2-or-later and may therefore be upgraded
but never downgraded.

Every entry below was verified against the repository it names, on the date
given. **A search result is not a licence check and a recollection is not a
licence check.** The design study's R6 revision exists because that was assumed
three times and wrong twice.

Verification method: `gh api repos/<owner>/<repo> --jq '.license.spdx_id'`, plus
reading the file header for an SPDX line. Both, because they disagree — a repo
can carry a LICENSE file while an individual file is licensed differently, and
MAME does this deliberately.

---

## In use

### alphanu1/sega-model1-mister — GPL-3.0-or-later
*Verified 2026-08-18 · pinned at `f48c842`, cloned from the local repository rather than GitHub*

Our own Model 1 core, and the largest single source of RTL here. Available as a
read-only reference clone at `tools/model1-ref`, which is git-ignored and not
part of this repository. It has its own upstream and its own history; it is
never edited here, and modules are copied into `rtl/` with the source commit
recorded rather than referenced in place.

| Ported | From | Note |
|---|---|---|
| MB86234 TGP | `rtl/tgp/` — 12 modules, 3,179 lines | MAME's `mb86234_device` is an empty subclass of `mb86233_device`, so this transfers unmodified. Design study §5.4.1. |
| S24TILE tilemap | `rtl/video/m1_tile_*.sv`, `m1_palette.sv` | Model 1 and Model 2 instantiate the same chip. Base addresses differ. |
| SDRAM controller | `rtl/mem/m1_sdram.sv` | |
| ROM loader | `rtl/io/m1_rom_loader.sv` | Carries the `ioctl_wait` gating fixes |
| Clock domain crossing | `rtl/mem/m1_cdc_*.sv`, `m1_fetch_bridge.sv` | |
| Debug overlay | `rtl/video/m1_diag.sv` | 307 ALM measured |
| **Video timing — COPIED, in `rtl/video/m2_video_timing.sv`** | `rtl/video/m1_video_timing.sv` @ **`f48c842`** | **No retiming.** MAME declares both machines identically — Model 1 `set_raw(XTAL(16'000'000), 656, 0, 496, 424, 0, 384)`, Model 2 `set_raw(32_MHz_XTAL/2, 656, 0, 496, 424, 0, 384)`. Changed: module and file renamed `m1_`->`m2_`, header and one comment retargeted. Logic untouched. Verified against MAME's numbers by `sim/video/tb_m2_video_timing.cpp`. |
| Verification harness | `Makefile`, `sim/` | Per-module fuzz targets and the lockstep bridge |

**Not ported:** `rtl/cpu/v60/` — Model 2's main CPU is the i960KB. Nothing from
the V60 transfers (design study R4).

Note that some Model 1 files are themselves derivative of MAME and carry
Olivier Galibert's BSD-3-Clause attribution in their headers — `mb86233_pkg.sv`
for opcode numbering, status flag positions and the exponent/mantissa
accessors. **Those headers travel with the file.** Retain them.

### ijor/fx68k — GPL-3.0
*Verified 2026-08-16 · assessment reconciled with Model 1 `4ff53be`*

Cycle-exact 68000 in SystemVerilog, for the sound CPU at 11.2896 MHz. GPL-3 to
GPL-3, so reuse is direct; copyright remains Jorge Cwik's. The combined work is
distributable under GPL-3 and our own files keep their or-later option.

**Figures below are as reported by the project, not measured here.** ~5,100 LE,
~5 KB internal RAM, up to ~40 MHz on Cyclone families.

- **2,800-3,500 ALM**, not the ~2,550 a straight 2:1 division gives. 2:1 is the
  theoretical packing and real designs rarely reach it. Measured only after
  `make quartus`.
- **4-5 M10K** for the microcode and nanocode ROMs — and per design study §5.6,
  M10K is the resource this project has not budgeted and the one Model 1 found
  binding. Track it from the start.
- 40 MHz against 11.2896 MHz is ample. Driven by `enPhi1`/`enPhi2` clock
  enables, not a raw clock.

**Open, and it is not the licence: does it simulate under Verilator?** Rule 8
and every verification practice here assume a block can be exercised in
simulation before it reaches the fitter. This is the criterion that decided tv80
over T80 for the Model 1 I/O board. Fully synchronous SystemVerilog is a good
sign, not an answer. Confirm before this counts as a decision.

### MiSTer template / `sys/` — GPL-2.0-or-later
Framework, HPS I/O and scaler. The repository LICENSE carries GPLv2 text, but
every source file header reads "either version 2 of the License, or (at your
option) any later version". **That or-later clause is the only reason this
combination is lawful** — it permits upgrading `sys/` to GPL-3. Code flows in
from GPL-2-or-later cores and cannot flow back out to them.

### MAME — BSD-3-Clause *per file*
The behavioural oracle throughout. Files depended on, with headers checked
individually:

| File | SPDX | Copyright | Used for |
|---|---|---|---|
| `src/devices/cpu/mb86233/mb86233.{cpp,h,d.cpp}` | BSD-3-Clause | Olivier Galibert | TGP, and the M2-C finding |
| `src/devices/cpu/i960/i960.cpp` | BSD-3-Clause | Farfetch'd, R. Belmont | i960KB — the only reference that exists |
| `src/devices/sound/scsp.cpp` | BSD-3-Clause | ElSemi, R. Belmont | SCSP, written from scratch against it |
| `src/mame/sega/segaic24.cpp` | BSD-3-Clause | — | S24TILE tilemap |
| `src/mame/sega/315_5649.cpp` | BSD-3-Clause | Dirk Best | I/O chip |
| `src/mame/sega/model2.cpp`, `model2_v.cpp` | check before use | — | Board, memory map, renderer behaviour |

**MAME is GPL-2.0 as a whole and individual files carry their own SPDX
headers.** Check the header of every file you read. Do not rely on the
repository-level licence in either direction. `model2.cpp` and `model2_v.cpp`
are flagged above because they have not yet been checked and the renderer work
will lean on them heavily.

Reimplementing hardware behaviour is not derivative of the program that
documents it — the behaviour of Sega's and Intel's silicon is fact, not MAME's
expression. The distinction bites on *structure* rather than function: where
MAME made a decomposition choice that alternatives existed for, mirroring that
choice is a different question from reproducing what the chip does.

### MiSTer-devel/N64_MiSTer — GPL-3.0, VHDL
*Verified 2026-08-16*

Used two ways, neither of which is a port today:

1. **Gate M2-E** — compiled to obtain per-module fitter figures for the RDP and
   the R4300i on this exact part, as measured comparables for our renderer and
   i960 estimates.
2. **Architectural reference for the renderer.** It is a working textured,
   Z-buffered, mipmapped, bilinear-filtered rasterizer that fits on a
   5CSEBA6U23I7 alongside two CPUs. It cannot verify a single Model 2 pixel, but
   it is licence-compatible, so if anything from it is ever lifted, that is
   lawful. Record it here if that happens.

---

## Not usable

### srg320/Saturn — no licence, all rights reserved
*Verified 2026-08-16*

`SCSP/SCSP.sv` (77 KB) and `SCSP/SCSP_pkg.sv` (22 KB) are a complete RTL SCSP —
the exact chip Model 2 uses. **It cannot be used.**

- `srg320/Saturn` — GitHub reports `license: null`, no LICENSE or COPYING at
  root, and `SCSP.sv` opens with `// synopsys translate_off`, carrying no SPDX
  header and no copyright notice.
- `srg320/Saturn_MiSTer` — archived, `license: null`.
- `MiSTer-devel/Saturn_MiSTer` — `license: null`.

No licence means no permission to copy **and none to adapt**. Translating it to
another language or restructuring it is what "adapt" means, not a way around it.
It may be read for understanding and run as an external oracle — the same
position the Model 1 project took on `frangarcj/geometrizer`.

**Gate M2-G exists to fix this by asking.** An explicit grant from srg320 would
remove 3,000-5,000 ALM of from-scratch work and its verification. Until an
answer arrives, the budget assumes the answer is no. If a grant is given,
record it here with the date and the wording.

---

## Does not exist

### i960 / i80960
No open-source FPGA implementation in Verilog or VHDL was found. MAME's
`i960.cpp` is the only reference of any kind, and per design study §2.2 it
models the four 80-bit extended-precision FP registers as host `double`, so it
is not a bit-exact oracle for floating point. The i960KB is a from-scratch
pipelined CPU with a partially unverifiable FPU.

---

## ROM images

Never committed, nor anything derived from them, including microcode extracted
from a ROM and baked into source. `.mra` files describing a ROM layout are fine;
the bytes are not. Tooling reads from a path given on the command line and
writes only under `build/`, which is git-ignored.

## Release checklist

- [ ] `LICENSE` present and unmodified
- [ ] SPDX header on every source file
- [ ] This file lists every vendored component actually used
- [ ] Upstream revisions pinned, not just named
- [ ] Olivier Galibert's BSD-3-Clause notice retained wherever MAME-derived
- [ ] No `srg320/Saturn` code present anywhere in the tree
- [ ] `tools/` not present in the published tree
- [ ] ROM images are not distributed. Ever.
