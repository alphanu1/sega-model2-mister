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
*Verified 2026-08-18 · pinned at `d53a149`, cloned from the local repository rather than GitHub*

Our own Model 1 core, and the largest single source of RTL here. Available as a
read-only reference clone at `tools/model1-ref`, which is git-ignored and not
part of this repository. It has its own upstream and its own history; it is
never edited here, and modules are copied into `rtl/` with the source commit
recorded rather than referenced in place.

| Ported | From | Note |
|---|---|---|
| MB86234 TGP | `rtl/tgp/` — 12 modules, 3,179 lines | MAME's `mb86234_device` is an empty subclass of `mb86233_device`, so this transfers unmodified. Design study §5.4.1. |
| **S24TILE — COPIED, `rtl/video/m2_tile_{fetch,decode,mixer}.sv`, `m2_palette.sv`** | `rtl/video/m1_tile_*.sv`, `m1_palette.sv` @ **`0676857`** | Renamed only, 835 lines. Model 1 and Model 2 instantiate the **same chip**, and `COLUMNS=62` (496/8) already matches. Not yet wired. Model 2's char RAM is at `0x01080000` and tile RAM at `0x01000000`. |
| **SDRAM controller — COPIED AND MODIFIED, `rtl/mem/m2_sdram.sv`** | `rtl/mem/m1_sdram.sv` @ **`b895e6c`** | **Changed: geometry parameterised (`COL_BITS`/`ROW_BITS`/`BA_BITS`), address ports widened from `[24:1]` to `[AW:1]`, and column bits placed on A0-A9,A11,A12 via `col_a()` instead of a fixed 9-bit slice.** That takes it from a 32 MB module to 128 MB. Upstream is 32 MB only. Both geometries pass the device-model suite. NOT yet instantiated. Lints clean with `-Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHEXPAND`; those six warnings are upstream's and the file is deliberately unedited. |
| **ROM loader — COPIED, `rtl/io/m2_rom_loader.sv`** | `rtl/io/m1_rom_loader.sv` @ **`b895e6c`** | Renamed only. NOT yet instantiated. Carries the `ioctl_wait` gating fixes: `ioctl_wait` asks the HPS to stop rather than stopping it, so writes go to a short FIFO and the wait asserts while it still has room. |
| **CDC — COPIED, `rtl/mem/m2_cdc_port.sv`, `m2_cdc_pulse.sv`** | `rtl/mem/m1_cdc_*.sv` @ **`b895e6c`** | Renamed only. NOT yet instantiated. `m1_fetch_bridge.sv` not taken yet. |
| **Debug overlay — COPIED, in `rtl/video/m2_diag.sv`** | `rtl/video/m1_diag.sv` @ **`b895e6c`** | Changed: module and file renamed `m1_`->`m2_`, header retargeted. Logic untouched. Instantiated with NWORDS=4. |
| **3D BACK END — COPIED, `rtl/video/m2_raster_{div,fill,band}.sv`** | `rtl/video/m1_raster_{div,fill,band}.sv` @ **`085a00e`** | Renamed only, 995 lines, logic untouched. Benches taken too as `sim/video/tb_m2_raster_{fill,band}.cpp` — upstream verifies the filler over **152,025 quads and 31.6 M spans** against a C reference. NOT yet wired. `m2_raster_band` has no dependency (its `m2_palette` mention is a comment); `m2_raster_fill` needs `m2_raster_div`. Lint clean except one upstream `WIDTHTRUNC` at `m2_raster_div.sv:101` (`6'h0` into 5 bits — benign, left unedited per the rule above). **Model 1's geometry does NOT transfer**: `m1_geometry` and its nine `m1_geo_*` submodules are fixed-function RTL, while Model 2's geometry is a MICROCODED engine running a program the game uploads (721,831 writes to `0x804000` per 900 attract frames, measured in MAME). `m1_listwalk` and `m1_quad_store` are likewise bound to Model 1's display-list grammar and geometry types. Design study R124. |
| **Video timing — COPIED, in `rtl/video/m2_video_timing.sv`** | `rtl/video/m1_video_timing.sv` @ **`f48c842`** | **No retiming.** MAME declares both machines identically — Model 1 `set_raw(XTAL(16'000'000), 656, 0, 496, 424, 0, 384)`, Model 2 `set_raw(32_MHz_XTAL/2, 656, 0, 496, 424, 0, 384)`. Changed: module and file renamed `m1_`->`m2_`, header and one comment retargeted. Logic untouched. Verified against MAME's numbers by `sim/video/tb_m2_video_timing.cpp`. |
| **GEOMETRY ARITHMETIC — COPIED, `rtl/video/m2_fp_pool.sv`, `m2_geo_{xform,project,det,norm,rsqrt,clip,planes}.sv`, `fp_to_int.sv`, `sim/video/geo_wrappers.sv`, `tb_clip_top.sv`** | `rtl/video/m1_fp_pool.sv`, `m1_geo_*.sv`, `fp_to_int.sv`, `sim/video/geo_wrappers.sv`, `tb_clip_top.sv` @ **`78481c4`**, **incremental branch** | Renamed only; benches taken too. **This REFINES the "geometry does not transfer" line below — see study R170.** The arithmetic stages transfer because a 3x4 matrix transform of a 3D point is the same operation on both boards; what does not transfer is the display-list GRAMMAR, which stays ours in `m2_geo.sv`. Ported with their benches: **88,146 checks, 0 fails** across xform 7,813, project 20,037, det 12,007, rsqrt 30,186, norm 16,100 and clip 2,003. **19.0 cycles per transform** streamed. `fp_to_int.sv` is the float-to-screen-coordinate conversion the quad store needs — MAME keeps vertices as floats through its rasterizer and converts late, so this had no equivalent here. `m2_geometry` (the sequencer) and `m1_geo_walk` are NOT taken: both are bound to Model 1's display-list grammar, and ours is `m2_geo.sv`. Replaces a hand-rolled version written here first, which gave the stage private FP units and idled three stages of a four-stage pipeline. |
| Verification harness | `Makefile`, `sim/` | Per-module fuzz targets and the lockstep bridge |
| **SDRAM sim — COPIED AND MODIFIED, `sim/mem/`** | `sim/mem/tb_m1_sdram.cpp`, `m1_sdram_harness.sv`, `sdram_model.sv`, `rtl/mem/bw_monitor.sv` @ **`b895e6c`** | **Changed: harness and testbench take the geometry as a parameter, and the device model's column decode corrected to skip A10.** The model took `col = a[COL_BITS-1:0]`, which is right up to ten column bits and wrong at eleven, where it consumes the auto-precharge flag as a column bit. **Worth reporting upstream.** Controller vs device model, five contending ports: 74,729 checks, 0 fails, 0 protocol violations. |
| **PLL — NOT ported** | `rtl/pll/` | Checked, does not transfer: Model 1's outputs are 80 MHz and **19.2 MHz**, and 19.2 is its V60 core clock. Ours is written by hand in `rtl/pll/pll.v` — the generator emits a plain parameterised `altera_pll` instantiation, not a Qsys black box, so the structure is followed rather than the file copied. |

### MiSTer-devel/Template_MiSTer — GPL-2.0-or-later
*Copied 2026-08-18 from `third_party/template`*

| Copied | To | Note |
|---|---|---|
| `sys/` framework | `sys/` | Unmodified. GPL-2.0-**or-later**, so it is used here under GPL-3. This is the 6,630 ALM row in the budget (§5.5), measured via M2-E. |
| `Template.qsf`, `Template.qpf` | `Model2.qsf`, `Model2.qpf` | Renamed only. `sys/sys.tcl` supplies FAMILY and DEVICE (5CSEBA6U23I7), and `PRE_FLOW_SCRIPT_FILE` generates `build_id.v` — which `quartus_map` alone does not run, so a direct map invocation needs it generated first. |
| `Template.sv` structure | `Model2.sv` | Port list via `sys/emu_ports.vh`; the unused-output assignments and `hps_io` instantiation follow the template. The core logic is ours. |

**Not ported:** `rtl/cpu/v60/` — Model 2's main CPU is the i960KB. Nothing from
the V60 transfers (design study R4).

Note that some Model 1 files are themselves derivative of MAME and carry
Olivier Galibert's BSD-3-Clause attribution in their headers — `mb86233_pkg.sv`
for opcode numbering, status flag positions and the exponent/mantissa
accessors. **Those headers travel with the file.** Retain them.

### alphanu1/sega-model1-mister — GPL-3.0-or-later (the TGP)
*COPIED 2026-08-30 · `rtl/tgp/` and `sim/tgp/` @ **`4e7dee6`***

The MB86234 geometry processor, 4,400 lines, unmodified. MAME's `mb86234_device`
is an EMPTY SUBCLASS of `mb86233` — it overrides no method, adds no member, and
forwards its constructor to the parent with a different DEVICE_TYPE tag — so the
two are behaviourally identical there and this transfers without change. Study
5.4.1, including the caveat: that is **absence of evidence, not proof of
equivalence**. MAME modelling them identically means no Model 2 game has yet
required a difference, and any divergence found later has no oracle behind it,
because the oracle IS the thing asserting they are the same.

**The verification came with it, which is why the whole thing was taken rather
than the RTL alone.** All ten suites pass unchanged on this tree: ~18.5 million
cases, zero failures, zero uncovered opcodes, addressing modes, registers or
decode paths. `mb86233_xfer` is exhaustive at 256.

`m1_copro_if.sv` and `m1_tgp.sv` are Model 1's wrappers and will need Model 2
equivalents; the `mb86233_*` core and the `fp_*` units are the portable part.

**Speed is the open problem, not correctness.** 9.83 CPI at 72.17 MHz is
7.3 M instr/s against the ~16.7 M a 50 MHz MB86234 delivers — 44%. Clocking
alone cannot close it: 164 MHz would be needed at this CPI, and Fmax is 72.
Pipelining shortens the critical path as well as the CPI, so the two compound.
Study M2-F.

### meathax/s32 — GPL-3.0
*IN USE 2026-08-30 · `rtl/sound/m2_multipcm.sv` from `rtl/audio/s32_multipcm.sv` @ **`7905361`***

The Sega 315-5560 MultiPCM (Yamaha YMW-258-F GEW8), two of them, at MAME's
figure of 10,000,000 Hz. **Changed: module renamed `s32_multipcm` → `m2_multipcm`.
Nothing else.** System 32 and the Model 1 sound board carry the same part, and the
register, descriptor and pitch semantics follow MAME's `multipcm.cpp`.

**It is an HLE and says so in its own header**: "Envelope curves, interpolation
and LFO modulation remain bounded approximations; the sample-selection/playback
path is cycle deterministic." That is the right trade here — this is where
Daytona's sound actually lives, and the alternative was silence.

**CHANGED: `banked()` and the bank port — the two boards bank differently.**
`segam1audio.cpp` gives each MULTIPCM a TWO megabyte space, the first megabyte
direct and the second a window onto one of FOUR one-megabyte pages selected by
two bits:

    map(0x000000, 0x0fffff).rom();
    map(0x100000, 0x1fffff).bankr(m_mpcmbank1);
    m_mpcmbank1->configure_entries(0, 4, region->base(), 0x100000);

System 32 banks the same part in 512 KB pages with a three-bit selector split
across `bank_lo`/`bank_hi`. With Daytona's bank value of 0x01 that scheme sends
0x100000 to 0x080000 and everything above 0x180000 into the first 512 KB — which
was audible as correct music (below 1 MB, unbanked) and voice samples that came
out as a foghorn (above it). Study R95.

`banked()` is replaced and the two three-bit fields become one two-bit
`bank_sel`. Nothing else in the file is touched. **Also added: `rom_slot` and
`sample_stb` outputs**, both wires off existing state, changing no timing —
`rom_slot` so the sample cache can index by voice, `sample_stb` so the output
rate can be measured.

`rdata` is tied to 0, which is what the firmware needs: it polls bit 0 of
0xC40001 as a busy flag and spins until it clears.

Banking follows the reference's own field split — high bank in bits 5:3, low in
2:0 — written to 0xC50000 for the first chip and 0xC70000 for the second.

### jotego/jt12 — GPL-3.0
*IN USE 2026-08-29 · `rtl/sound/jt12/` @ **`4cf1c5b`** · UNMODIFIED*

The YM3438 (OPN2C) on the sound board, at MAME's own figure of 8,000,000 Hz —
which divides 48 MHz by exactly six, so it takes a counter rather than the phase
accumulator the 10 MHz 68000 needs. Copyright Jose Tejada Gomez; GPL-3 to GPL-3,
so reuse is direct.

`cfg/jt12.yaml` declares `hdl/*.v` plus `hdl/adpcm/*.v` — 57 files. The ADPCM
helpers are not optional even for plain OPN2: `jt12_pcm_interpol.v` instantiates
`jt10_adpcm_div`.

**One write per bus cycle, and it takes a pulse.** `jt12_top` forms its strobe as
`write = !cs_n && !wr_n`, a LEVEL, and acts on it in a clocked block. A 68000
write cycle at 10 MHz is about 400 ns and spans three 8 MHz enables, so passing
the bus signals straight through applies every register write three times. Most
registers do not care; the key-on register at 0x28 and the timer controls do, and
the symptom would be notes that retrigger rather than anything obviously broken.
`m2_sound_board.sv` latches address and data on the cycle's leading edge and
holds the strobe for exactly one enable.

Verilator waivers are upstream's own: EOFNEWLINE, PROCASSINIT, GENUNNAMED, and
the width family. Held in the target's flags, not in VFLAGS, so our RTL stays at
-Wall.

### ijor/fx68k — GPL-3.0
*IN USE 2026-08-29 · `rtl/sound/fx68k/` @ **`0602ee4`** · UNMODIFIED*

**Copied byte for byte, and it stays that way.** The earlier assessment below
said this needs "a two-word change" — packing `s_irdecod` and `s_nanod` so
Verilator accepts their mixed blocking/non-blocking writes. **That is withdrawn.**
`-Wno-BLKANDNBLK` accepts the construct as it stands, and an unmodified file has
nothing to re-apply on an upstream bump. `--no-assert-case` is the second flag:
`fx68kAlu.sv:313` is a `unique case` on the microword, which is all zeroes before
reset is released and matches no arm, so the runtime check fires at time 0 in the
ALU and reads as a decode fault in a CPU that has not started.

`fx68k.sv` uses CRLF line endings. Keep them; a whitespace-only reformat would
make every future upstream diff unreadable.

`microrom.mem` and `nanorom.mem` are `$readmemb`'d by BARE FILENAME, so they are
found relative to the WORKING DIRECTORY or not at all — and when they are not,
the CPU comes up with an all-zero microword and dies on that same unrelated
looking ALU assertion. Simulation runs from the directory holding them.

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

**Does it simulate under Verilator? YES, with a two-word change.** This was the
open question here and it is now answered.

Verilator 5.050 rejects it as shipped:

```
%Error-BLKANDNBLK: fx68k.sv:293: Unsupported: Blocking and non-blocking
assignments to same non-packed variable: 'fx68k.Nanod'
```

`s_nanod` and `s_irdecod` are unpacked structs written from both an
`always_comb` and an `always_ff`. **Changed here:** both are declared
`typedef struct packed`. Every member is already `logic`, so the layout is
defined and the semantics are unchanged — Verilator supports mixed assignment
to a packed variable, and Quartus accepts either form.

It then elaborates, compiles and runs. Required flags:

```
-Wno-UNOPTFLAT -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC --no-assert +define+FX68K_TEST
```

- `UNOPTFLAT` — `Nanod`/`Irdecod` are genuinely circular combinationally.
  Verilator iterates them, which costs simulation speed and is not a defect.
- `--no-assert` — `fx68kAlu.sv:313` is a `unique case` that legitimately
  matches nothing while the ALU is idle. Left on, it `$stop`s during reset.
- `FX68K_TEST` — guards `fx68kTop`, the clock-divider wrapper. Only needed to
  drive the core standalone; the real integration will supply `enPhi1`/`enPhi2`
  itself.

**And it EXECUTES.** `make test_fx68k` loads a four-instruction program over a
modelled bus and checks that a value the program computed arrives at an address
the program chose:

```
ticks 289, bus cycles 11, writes 1, last address 000100
mem[0x100] = 1234 (want 1234)
fx68k EXECUTES: reset vector read, immediate decoded,
absolute-long write completed (first write at tick 285).
```

Reset vector read from memory, fetch from the address in it, immediate decoded,
absolute-long write completed. A core that merely elaborates does none of that.

**The earlier failure was the harness, not the core.** A C++ testbench drove
`enPhi1`/`enPhi2` and the data bus by hand and never saw a vector fetch, and
there was no way to tell which side was wrong. The bus is RTL now
(`sim/sound/fx68k_harness.sv`), where the timing relationships are the ones the
68000 specifies.

Two things in that harness are deliberate and worth keeping when it grows into
the real sound board:

- **DTACK is registered off AS, not tied low.** Tying it acknowledges before the
  address is valid, which a synchronous model tolerates and real memory does
  not. Mutating it to a constant makes the test fail correctly -- one bus cycle,
  no write -- so the acknowledge path is actually being exercised.
- **The test asserts a computed value at a chosen address**, not "it did not
  crash". The old harness never crashed either, and taught us nothing.

**Superseded note.** Rule 8
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


### Model 1 core — `sega-model1-mister`, GPL-3.0

*Pinned at `72131a3`, read 2026-08-20.*

`rtl/io/m2_ioboard.sv` is derived in SHAPE from that project's
`rtl/io/m1_ioboard.sv` — the same device, since `model2o` instantiates
`SEGA_MODEL1IO` with bios `epr14869c` and Model 1 runs `EPR-14869` behind the
same 315-5338A. **The protocol is not copied**, because on this machine it runs
the other way round: there the board pushes a 128-byte identity block the V60
reads, here the i960 writes the block and the board completes it. Measured, not
assumed — see `docs/io-board.md`.

What IS taken is the engineering, and it is the expensive half:

- **One shared write port.** The MB8421 is a true dual-port RAM; that project
  measured what asking Quartus 17.0 for a second write port costs — **192 ALM
  becoming 16,059**. Against ~7,400 ALM of headroom here, that single number
  decided the design.
- **The turnaround is not a mailbox latency** but the board's Z80 running its
  power-on self-test before it ever looks at the flag, which is why it is
  enormous and happens once (their `292e628`).
- **The flag is a command code, not a doorbell** — 1 acknowledges, 2 copies the
  window, 3 restarts. Clearing on any non-zero write is right for 1, which is
  why boot gets as far as it does, and silently wrong for 2 and 3 (`779a0b4`).
- **Sweep at the board's rate, not every free cycle**, which is what turns a
  rare collision into a constant one (`6fd28aa`).
- **Sample a window another processor is filling more than once.** They took the
  identity block from one snapshot mid-push, got six bytes wrong — one gating
  the coprocessor path — and propagated it into the RTL, the testbench and the
  docs, which looks like three artefacts and is one reading (`6e5aed4`).

`rtl/mem/m2_sdram_x2.sv` is ported from the sibling **Kaneko16** core's
`kaneko_sdram_x2.sv` at `6f59d8a`, which solved running this same controller at
twice the core clock. Same author, GPL-3, so reuse is direct. What was changed:
`NP` 7 to 5, `AW` to our 25, per-port write signals added (this controller lets
a port write and port 0 does; theirs has no equivalent), and the header rewritten
for our clocks and requesters. **The two hazards and their answers are theirs**,
and both were found by a failure rather than by reasoning — the read-data bypass
failed almost exactly half their reads without it.

One of the two does not apply here and the file says so rather than implying
otherwise: their request mask guards a controller that latches on the LEVEL, and
`m2_sdram` latches on the edge (`p_req[i] && !req_d[i]`, forced by study R34
because the i960 holds its request across a run of accesses). `test_m2_sdram_x2`
passes with the mask deleted. It is kept as defence against a controller change,
not against this controller.

Their `m1_uart_tx` is a debug printf channel and NOT a sound UART; three things
in that repo get called a UART and conflating them has cost time there already.
Our sound path is the i8251 at `0x01c80000`.

## hutch31/tv80 — MIT

- **Upstream:** https://github.com/hutch31/tv80
- **Commit:** 66a131c38d05
- **Files:** `rtl/cpu/tv80/tv80_core.v`, `tv80_alu.v`, `tv80_mcode.v`,
  `tv80_reg.v`, `tv80s.v`, `LICENSE`
- **Licence:** MIT (Guy Hutchison, 2004) — compatible with this project's
  GPL-3-or-later; the MIT text is retained in every file header and in
  `rtl/cpu/tv80/LICENSE`.
- **What it is:** a Verilog Z80, the port of Wallner's T80. Chosen over the
  VHDL T80 because this project's whole verification method runs through
  Verilator, which does not read VHDL — one source must serve simulation and
  synthesis both.
- **Why it is here:** the Model 1 I/O board (Sega 837-8950, shared by Model 1
  and model2o cabinets) is a Z80 running `EPR-14869`, and study R60 replaces
  the behavioural board with the real firmware on this core.
- **Changes:** `tv80s.v` — the `cen` clock-enable is exposed as a module port
  (upstream hardwires it to 1 in this wrapper; `tv80_core` has always taken
  it). Two lines, marked in-file.
# Copied from the Model 1 project (local clone 8788ede) -- same author, same licence.
