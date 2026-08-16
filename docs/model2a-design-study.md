# Sega Model 2A-CRX on Cyclone V — design study

**Status: open, contingent on measurement.** Optimistic budget fits with ~3K spare;
pessimistic budget is ~20K over. Every block is anchored to a named MAME device except the
renderer, and one gate (M2-C) is now closed. The problem is no longer only the renderer:
**three blocks have no licence-compatible RTL to start from — the renderer, the i960 and
the SCSP — and together they are 26,000 of the 38,500 optimistic total.**

Target: DE10-Nano, Cyclone V 5CSEBA6U23I7 — 41,509 ALM, 553 M10K (696 KB), 112 DSP,
one 16-bit SDRAM module, 1 GB DDR3 via HPS.

Approach is **LLE throughout**: every block implemented as the silicon behaved, verified
against a reference. Section 2 establishes which blocks have a reference and which do
not.

Revision history in section 10. This document has been wrong in both directions and the
failure modes are recorded.

**Order of work is `milestones.md`, not this document.** The fit question reduces to a
single number — whether the i960 and the renderer together land under ~25,000 ALM — and
the milestones are sequenced to answer it before anything else is built.

---

## 1. Machine — from source, not from secondary sources

`src/mame/sega/model2.cpp`, `model2a_state::model2a()` and the `model2_scsp()` /
`model2_screen()` fragments it calls:

| Function | MAME device | Clock |
|---|---|---|
| Main CPU | `I80960KB` | `50_MHz_XTAL / 2` = **25 MHz** |
| Geometry | `MB86234` — **one device** | `50_MHz_XTAL` = **50 MHz** |
| Sound CPU | `M68000` | `45.1584_MHz_XTAL / 4` = **11.2896 MHz** |
| Sound chip | `SCSP` | `45.1584_MHz_XTAL / 2` = **22.5792 MHz** |
| Tilemap | `S24TILE` | — |
| I/O | `SEGA_315_5649` | — |
| MIDI UART | `I8251` (uPD71051C) | 8 MHz nominal, clock unknown |
| Coprocessor link | 2x `GENERIC_FIFO_U32` | — |
| NVRAM / EEPROM | `NVRAM`, `EEPROM_93C46_16BIT` | — |
| Link comms | `M2COMM` | optional |
| **3D renderer** | **no device** | — |

Screen, from `model2_screen()`:

```
set_raw(32_MHz_XTAL/2, 656, 0, 496, 424, 0, 384)
```

16 MHz pixel clock, 656 x 424 total, 496 x 384 active. MAME annotates this
`// TODO: from System 24, might not be accurate for Model 2` — treat the blanking
figures as provisional and re-derive from hardware.

Two corrections to earlier versions of this study, both from this listing:

**No V60.** Model 1 and Model 2 share sound lineage, tilemap lineage and the TGP family.
They do not share a main CPU. Sega moved from NEC CISC to Intel RISC between them.
Nothing from the Model 1 CPU work transfers.

**One TGP, not five.** `required_device<mb86234_device> m_copro_tgp`, one 4 KB program
store at `0x000-0xfff`, and games run correctly on it. The "5x MB86234" figure came from
a board-level package count.

---

## 2. LLE reference availability

This table decides the risk profile of the whole project.

Two questions, and they are independent. *Is there a bit-exact oracle to verify against?*
is about correctness. *Is there licence-compatible RTL to start from?* is about effort.
Section 5.4 audits the second column; this table carries the result so the two are never
conflated again.

| Block | Reference | Bit-exact oracle? | Portable RTL? |
|---|---|---|---|
| i960KB | `src/devices/cpu/i960/i960.cpp` | **Integer yes except `addc`/`subc` carry (2.3), FP no** | **none exists (5.4.3)** |
| MB86234 | `src/devices/cpu/mb86233/` — **empty subclass of MB86233** | Yes | **ours, verified (5.4.1)** |
| 68000 | mature | Yes | `fx68k`, GPL-3.0 |
| SCSP | `src/devices/sound/scsp.cpp`, BSD-3 | Yes | **none usable — Saturn RTL is unlicensed (5.3)** |
| S24TILE | `src/mame/sega/segaic24.cpp` | Yes | **ours — same chip as Model 1** |
| 315-5649 I/O, I8251 | small, documented | Yes | write, small |
| **3D renderer** | **`model2_v.cpp` driver code — HLE** | **No** | N64 RDP as architecture only (5.4.2) |

The renderer is the only row with **No** in the oracle column, and that has not changed.
What changed is that it is no longer the only row with nothing in the RTL column — the
i960 and the SCSP joined it there.

### 2.1 The renderer has no device and no oracle

`model2_screen()` instantiates only `S24TILE`, `SCREEN` and `PALETTE`. There is no
`model2_gpu_device`. The 3D pipeline lives in `model2_v.cpp` as driver code — 69 KB of it
— built on MAME's generic `video/poly.h` framework with `raster_state` and `geo_state`
structs and `raster_init(memory_region *texture_rom)`.

That is high-level emulation of the rendering behaviour, not a model of the hardware.

Consequences:

- **No lockstep verification.** Every other block can be diffed instruction-by-instruction
  or sample-by-sample against MAME. The rasterizer can only be diffed at the framebuffer,
  which localises bugs poorly.
- **No area anchor.** The widest estimate in the budget is also the one with no reference
  implementation to reason from.
- **Reverse engineering required.** Same position as Model 1's rasterizer, but against a
  far more complex pipeline: texture mapping, bilinear filtering, mipmapping and a
  Z-buffer, versus Model 1's flat-shaded painter's-algorithm span filler.

**This is now the primary risk, ahead of the i960.** It is also what M2-E exists to
bound.

### 2.2 The i960 FPU has no bit-exact oracle either

MAME declares `double m_fp[4]` — the four 80-bit extended-precision registers are
modelled as host doubles. FP results are therefore approximate, not bit-exact.

An LLE i960 FPU cannot be lockstep-verified against MAME. Options: verify against a
software 80-bit reference implementation, or accept 64-bit and document the deviation.

### 2.3 The integer oracle has exactly one hole: `addc` and `subc` carry

Found while writing the ALU. MAME computes the carry flag as:

```cpp
uint32_t t1, t2;  uint64_t res;
res = t2+(t1+((m_AC>>1)&1));
m_AC |= ((res) & (((uint64_t)1) << 32)) ? 0x2 : 0;    // set carry
```

Every operand is `uint32_t`, so the arithmetic wraps modulo 2^32 **before** it is widened
to `uint64_t`. Bit 32 is therefore always zero and **MAME's `addc` and `subc` never set
carry at all.** Verified directly: `0xffffffff + 1` yields `res = 0` with bit 32 clear;
`0 - 1` yields `0xffffffff` with bit 32 clear.

The `// set carry` comment and the deliberate `(uint64_t)1 << 32` mask make the intent
unambiguous, so this is a C++ integer-promotion defect rather than a modelling decision.
`addc` and `subc` exist to chain multi-word arithmetic; carry propagation is their whole
purpose, and the silicon certainly produces it.

**The RTL implements the hardware behaviour.** `CLAUDE.md` rule 11 puts the reference above
this study, but its first clause reads "MAME, **or the silicon it models**", and
`THIRD_PARTY.md` records that the behaviour of Intel's silicon is fact rather than MAME's
expression of it. This is the case those clauses exist for.

Cost, stated plainly: **the integer core is no longer a completely bit-exact oracle.**
Whole-CPU lockstep (§7 criterion 2 of the spike) will diverge on any program using `addc`
or `subc`, and that divergence is expected rather than a bug. The reference model carries a
switch reproducing MAME's result so lockstep can still be run either way.

The divergence is bounded and measured, not assumed. Over 12.8 M vectors covering all 64
`op`/`op2` pairs in `0x58`-`0x5b`, the switch changes behaviour on exactly two operations —
`5b.0` and `5b.2` — the union of AC bits that ever differ is exactly `0x00000002`, and
`result`, `result_we` and `valid` never differ at all. `make test_i960_alu_carrybug` is a
standing test that this stays true: it **fails if the RTL stops diverging**, because that
would mean the defect had been reproduced.

**Unknown, and it matters:** whether Model 2 games use `addc`/`subc`. Nothing in this
project can answer that without program ROM. If they do not, the hole is theoretical. If
they do, MAME's own arithmetic is wrong there and matching it would be the error.

---

## 3. i960KB FPU — implemented, therefore used

The FPU cannot be omitted. MAME implements the full transcendental set, and MAME does not
implement instructions games do not execute:

```
cvtir  cvtri  scaler  scalerl  roundr  roundrl  cmpr  cmprl
atanr  atanrl  logr  logrl  expr  exprl  sqrtr  sqrtrl
sinr   sinrl   cosr  cosrl   tanr  tanrl
```

Both single (`r`) and extended (`rl`) forms.

This raises the FPU floor from earlier estimates. A microcoded FPU sharing one datapath
still works — CORDIC or polynomial approximation with coefficient ROMs in M10K — but it
must cover transcendentals at extended precision, which is not a 1-2K block.

**M2-B remains worth running, but for less than it was.** Implemented is not the same as
hot — and the hardware has now answered most of the question by itself.

`i960.cpp` carries differentiated per-opcode cycle counts, and the transcendentals are
enormous: `sinr` and `cosr` are **406** cycles, `sinrl`/`cosrl` **441**, `logr` **438**,
`tanr` 293, `atanr` 267, `sqrtr` 104. Basic arithmetic is cheap by comparison — `addr` and
`subr` 10, `mulr` 18, `divr` 35, `mulrl` 36, `divrl` 77.

At 25 MHz, 406 cycles caps `sinr` at ~61,600/second — **~1,000 per frame**, and that is
the ceiling with the CPU doing nothing else. Games cannot be issuing tens of thousands of
transcendentals per frame because the part cannot retire them.

**So the microcoded FPU is not a compromise.** A CORDIC at ~64 iterations would be roughly
six times faster than the silicon on exactly the operations that dominate FPU area, and 36
cycles for `mulrl` is ample budget for an iterative 27x27 DSP multiply rather than a wide
combinational one. This pushes the FPU toward the bottom of its 2,500-6,000 range.

Per section 4.1's standing rule these figures are not yet hardware facts and must be
checked against the i960KB timing manual. But `i960.cpp` is a different case from
`v60.cpp`: values differ per opcode, `remr` carries `// (67 to 75878 depending on
opcodes!!!)`, and exactly one op is hedged `// checkme`. A flat average cannot produce
that. **And the conclusion survives the figures being wrong by a factor of two.**

What M2-B is still needed for is the **mix** — basic arithmetic versus transcendental —
which sizes the adder and multiplier, the parts running at 10 and 18 cycles that cannot be
microcoded away. Run it for that, not for the verdict. Detail in `p1-i960-spike.md` §4.

---

## 4. Timing — the constraint that decides the architecture

**Read this before the area budget.** Two earlier versions of this study reached wrong
conclusions by treating MAME's cycle models as hardware facts and ignoring fabric clock
entirely.

### 4.1 The rule

```
fabric_clock_required = (part_clock / real_CPI) x your_CPI
```

MAME's cycle figures are frequently placeholders. `mb86233.cpp` returns `clocks/3` — the
real chip's part-clock-to-instruction-cycle ratio, not the FSM cost of an RTL
implementation. `v60.cpp` carries `// Actual cycles / instruction is unknown` with
`m_icount -= 8; /* fix me -- this is just an average */`. Neither is a target.

Measured, Model 1 MB86233 M0 spike: **9.83 CPI** for a multi-cycle FSM, **72.17 MHz**
Fmax after a three-stage retime on an otherwise empty device. Expect 15-25% degradation
at high utilization — **54-61 MHz in an assembled core**.

### 4.2 MB86234 must be pipelined

| | instr/s | x 9.83 CPI |
|---|---|---|
| Model 1 MB86233 @16 MHz, per instance | 5.33 M | 52.4 MHz — fits |
| Model 2 MB86234 @50 MHz, single instance | 16.67 M | **164 MHz — impossible** |

One TGP at 50 MHz does nearly the same aggregate work as Model 1's three at 16 MHz, but
through one instruction stream. One program counter, one 4 KB program store — additional
physical instances buy nothing.

| your CPI | required |
|---|---|
| 9.83 (FSM) | 164 MHz |
| 4 | 67 MHz |
| 2 | **33 MHz** |

The MB86233 ISA is fixed-width with a simple register file and pipelines well. A 4-5
stage design at 1.5-2 CPI is a **requirement**, not an optimisation. It costs area over
the measured 2,554 ALM FSM, but that is paid once rather than five times.

### 4.3 i960KB must be pipelined

RISC with a 512-byte direct-mapped I-cache, so real CPI is probably 1.5-2. At 25 MHz that
is 12.5-16.7 M instr/s.

| your CPI | required |
|---|---|
| 9.83 (FSM) | 123-164 MHz |
| 4 | 50-67 MHz |
| 2 | 25-33 MHz |

A multi-cycle FSM i960 does not close timing. Pipelining a 32-bit RISC is well-trodden,
but the register-window frame cache and the scoreboard interact badly with a pipeline,
and that is where i960 implementations get expensive. Section 5 carries that cost.

---

## 5. Area budget

### 5.1 Anchors and conversion

Strongest anchor is a measurement in the right currency, from this flow, on this part:
**MB86233 = 2,554 ALM, 1 DSP block, 3 M10K**, including a full IEEE-754 single multiplier
and adder, register file, AGU and sequencer.

**LE-to-ALM conversion.** 2:1 is the theoretical maximum, reached only when two
independent functions of <=4 inputs share <=8 distinct inputs. Real CPU logic is mux-heavy
and lands at **1.3-1.6 LE per ALM**. Register-heavy paths pack better since each Cyclone V
ALM carries four flip-flops. **Divide published LE figures by 1.5, not 2.**

Worked example: a T80 Z80 at ~1,200-1,500 LE is ~800-1,000 ALM, not 600-800.

### 5.2 i960KB

| Block | ALM |
|---|---|
| Core execution, register windows, scoreboard | 2,500-3,500 |
| **80-bit FPU incl. transcendentals** | **2,500-6,000** |
| I-cache control, 32-bit multiplexed burst bus | 500-1,000 |
| Pipelining overhead over an FSM design | 1,500-3,000 |
| **Subtotal** | **7,000-13,500** |

The FPU is most of the spread, and section 3 raises its floor from 1,500 to 2,500 —
transcendentals cannot be dropped.

### 5.3 Sound and 2D — the area holds, the risk moved

Earlier versions carried a flat 10K for "tilemap, sound, I/O", then claimed three of the
four blocks had existing RTL to adapt. **One of those three claims was false and one was
better than stated.** Section 5.4 is the audit; this is the result.

| Block | ALM | Source | Risk |
|---|---|---|---|
| 68000 @ 11.2896 MHz | 3,000-3,800 | `ijor/fx68k`, **GPL-3.0** — verified | low |
| SCSP @ 22.5792 MHz | 3,000-5,000 | **none — must be written** | **high** |
| S24TILE | 2,000-3,000 | **Model 1 core, ours** | very low |
| 315-5649 I/O, I8251, NVRAM, FIFOs | 500-1,000 | write, small | low |
| **Subtotal** | **8,500-12,800** | | |

The subtotal barely moves. What moved is where the risk sits.

**fx68k is confirmed GPL-3.0** and is cycle-exact SystemVerilog. GPL-3 combines with this
project's GPL-3-or-later without friction: the combined work is distributable under GPL-3
and our own files keep their or-later option.

Its figures are **as reported by the project, not measured here** — roughly 5,100 LE, about
5 KB of internal RAM, up to ~40 MHz on Cyclone families. Reconciled against the Model 1
project's own assessment (`4ff53be`), which reached it independently:

- **2,800-3,500 ALM**, not the ~2,550 a straight 2:1 division gives. 2:1 is the theoretical
  packing and real designs rarely reach it — which is section 5.1's point, and the reason
  this row is a range rather than a number. Measured only after `make quartus`.
- **4-5 M10K** for the microcode and nanocode ROMs. Small, and see 5.6 for why that is not
  the same as negligible.
- 40 MHz against an 11.2896 MHz target is nearly four times the headroom needed — one
  constraint this design does not have to think about. Note it is driven by
  `enPhi1`/`enPhi2` clock enables rather than a raw clock.

**One question is open and it is not the licence.** Does fx68k simulate under Verilator?
Rule 8 and every verification practice in this project assume a block can be exercised in
simulation before it reaches the fitter. This is the criterion that decided tv80 over T80
for the Model 1 I/O board — T80 is VHDL and cannot run inside the boot test. Fully
synchronous SystemVerilog is a good sign and not an answer. **Confirm before this counts as
a decision.**

**S24TILE is already written, and it is ours.** `model1.cpp:1830` instantiates
`S24TILE(config, m_tiles, 0, 0x3fff)` — Model 1 and Model 2 use *the same tilemap chip*.
The Model 1 core's `m1_tile_fetch`, `m1_tile_decode`, `m1_tile_mixer` and `m1_palette`
implement it against `segaic24.cpp`, with per-module fuzz harnesses. Model 2 remaps the
base address (char RAM at `0x01080000-0x010fffff` rather than `0x780000`); the chip
behind it is unchanged. The earlier note claimed "a MiSTer System 24 core exists" —
**no such core was found**, and it does not matter, because we wrote the block already.

**The SCSP claim was wrong, and this is the finding that hurts.** The previous revision
stated that srg320's Saturn core has an RTL SCSP under GPL, "licence-compatible with this
project's GPL-3 position". Checked directly:

| Repository | Licence | SCSP RTL present |
|---|---|---|
| `srg320/Saturn` | **none** | yes — `SCSP/SCSP.sv`, 77 KB, plus a 22 KB package |
| `srg320/Saturn_MiSTer` | **none** (archived) | no, it consumes the above |
| `MiSTer-devel/Saturn_MiSTer` | **none** | no |

`SCSP.sv` carries no SPDX header and no copyright notice, and GitHub's licence detection
reports `null` for all three repositories. **No licence means all rights reserved: no
permission to copy and none to adapt.** This is precisely the `frangarcj/geometrizer`
position the Model 1 project already ruled on — it may be read for understanding and run
as an external oracle, but translating or restructuring it is what "adapt" means, not a
way around it.

So the SCSP must be **written from scratch** against MAME's `scsp.cpp`, which is
BSD-3-Clause (ElSemi, R. Belmont) and therefore a clean reference. It is a 32-voice
sample playback engine with an FM mode, per-voice envelopes and LFO, and a DSP — the
largest single block in this row and now the only one in it with no starting point.
Two honest alternatives exist and both should be tried before committing:
**ask srg320 for an explicit licence grant**, or check whether a later Saturn core adds
one. A grant costs an email and would remove the whole item.

### 5.4 Portable RTL — audited, not assumed

This section exists because the previous revision asserted three RTL sources without
checking any of them, and got one badly wrong. Everything below was verified against the
repository or the measurement it came from.

**From the Model 1 core (`alphanu1/sega-model1-mister` @ `4ff53be`), GPL-3.0 — ours.**
Available as a read-only reference clone at `tools/model1-ref`.

| Block | Files | Lines | Measured | Transfers? |
|---|---|---|---|---|
| **MB86234 TGP** | `rtl/tgp/` — 12 modules | 3,179 | 2,554 ALM, 1 DSP, 3 M10K, 72.17 MHz | **yes, unchanged** — see 5.4.1 |
| S24TILE tilemap | `m1_tile_{fetch,decode,mixer}`, `m1_palette` | 734 | — | yes, rebase addresses |
| SDRAM controller | `rtl/mem/m1_sdram.sv` | 704 | — | yes |
| ROM loader | `rtl/io/m1_rom_loader.sv` | 284 | — | yes — carries the `ioctl_wait` fixes |
| Clock domain crossing | `m1_cdc_port`, `m1_cdc_pulse`, `m1_fetch_bridge` | 362 | — | yes |
| Debug overlay | `rtl/video/m1_diag.sv` | 207 | 307 ALM, 553 reg, 0 M10K | yes |
| Video timing | `m1_video_timing.sv` | 118 | — | yes, retimed to 496x384 |
| Bandwidth monitor | `rtl/mem/bw_monitor.sv` | 161 | — | yes |
| Build and verify harness | `Makefile`, `sim/` | — | 30+ per-module fuzz targets | yes |
| **V60 CPU** | `rtl/cpu/v60/` | 4,683 | — | **no** — Model 2 is i960 (R4) |

That is **~5,750 lines of RTL that is already written, already fuzz-verified, and already
measured on this exact part with this exact toolchain**, plus the entire lint, fuzz,
Quartus-report and Verilator harness around it. The V60 is the one large block that does
not transfer, and section 1 already knew that.

#### 5.4.1 The MB86234 is the MB86233 — M2-C is closed

Gate M2-C asked how much of the Model 1 TGP transfers. The answer is **all of it**, and it
took a single file to establish. In `src/devices/cpu/mb86233/mb86233.h`:

```cpp
class mb86234_device : public mb86233_device
{
public:
    mb86234_device(const machine_config &mconfig, const char *tag, device_t *owner, uint32_t clock);
};
```

An empty subclass. It overrides no method, adds no member, and its constructor forwards
straight to the parent with a different `DEVICE_TYPE` tag. The four address-space configs
are the parent's. **In MAME, the MB86234 and the MB86233 are behaviourally identical**, so
the 3,179 lines of verified TGP RTL — 1.9 M fuzz cases per opcode, 8,000 retires of
whole-CPU lockstep with zero divergence — port to Model 2 without modification.

Two honest caveats, and the first is the one that matters:

- **This is absence of evidence, not proof of equivalence.** MAME modelling them
  identically means no Model 2 game has yet required a difference, not that the silicon
  has none. The MB86234 is a later part. Any divergence found later has no oracle behind
  it, because the oracle is the thing asserting they are the same.
- **The port is free; the speed is not.** Section 4.2 is unaffected. The measured FSM does
  9.83 CPI at 72.17 MHz = 7.3 M instr/s, against the ~16.7 M instr/s a 50 MHz MB86234
  needs. That is **2.3x short**, and closing it is M2-F.

M2-F is nevertheless in a far better position than the gate assumed. It is now a
*modification of proven RTL*, re-verified with a lockstep harness and per-opcode fuzz
suites that already exist and already pass, rather than a new implementation checked by a
new test bench. Pipelining is the work; correctness has a net under it.

**External, licence-verified.**

| Source | Licence | Use |
|---|---|---|
| `ijor/fx68k` | GPL-3.0 | **port** — the sound 68000 |
| `MiSTer-devel/N64_MiSTer` | GPL-3.0, VHDL | **M2-E measurement, and a renderer reference — see below** |
| MAME `scsp.cpp` | BSD-3-Clause (ElSemi, R. Belmont) | reference for a from-scratch SCSP |
| MAME `i960.cpp` | BSD-3-Clause (Farfetch'd, R. Belmont) | reference for a from-scratch i960 |
| MAME `315_5649.cpp` | BSD-3-Clause (Dirk Best) | reference for the I/O chip |
| MiSTer `sys/` framework | GPL-2.0-or-later | framework, upgraded to GPL-3 under or-later |
| `srg320/Saturn` | **none — all rights reserved** | **read and oracle only. Do not port.** |

#### 5.4.2 The renderer is not quite as unreferenced as section 2.1 says

Section 2.1 stands on the point that matters: there is **no bit-exact oracle** for the
Model 2 rasterizer, and there will not be one. That does not change.

But "no reference implementation to reason from" is now too strong. `N64_MiSTer` is
**GPL-3.0** — licence-compatible, not merely readable — and it is a working textured,
Z-buffered, mipmapped, bilinear-filtered rasterizer that fits on *this exact part*
alongside two CPUs. It is not Model 2's renderer and cannot verify a single pixel of one.
It is an existence proof and an architectural reference for the block that had neither,
and section 8's M2-E already requires compiling it. Read it while the fitter report is
being generated.

#### 5.4.3 There is no i960, anywhere

Searched and not found: no open-source FPGA implementation of the i960 / i80960 exists in
Verilog or VHDL. Every other CPU-class block in this design has either RTL to port or a
BSD-3 behavioural model to work from; the i960 has only the latter. Combined with section
2.2 — MAME models the four 80-bit FP registers as host `double`, so the FPU has no
bit-exact oracle either — **the i960 is a from-scratch pipelined CPU with a partially
unverifiable FPU.** That is the second primary risk alongside the renderer, and unlike the
renderer it was not previously called out as a sourcing problem.

### 5.5 Total

| Block | Optimistic | Pessimistic | Anchor |
|---|---|---|---|
| i960KB, pipelined | 7,000 | 13,500 | estimate — no RTL exists anywhere (5.4.3) |
| 1x MB86234, pipelined | 3,000 | 5,000 | **measured 2,554 as an FSM** (5.4.1) |
| **3D renderer — no oracle** | **15,000** | **25,000** | estimate — N64 RDP is the only comparable |
| Sound, tilemap, I/O | 8,500 | 12,800 | fx68k measured; S24TILE written; SCSP estimate |
| `sys/` framework | 5,000 | 5,000 | framework |
| **Total** | **38,500** | **61,300** | |
| **Against 41,509** | **fits, 3K spare** | **20K over** | |

Barely different from the previous revision's 39,500 / 62,500, and that is the point worth
taking from section 5.4: **auditing the sources bought almost no area.** What it bought was
one line moving from estimate to measurement, one block moving from "adapt existing RTL" to
"write from scratch", and one block moving from "write from scratch" to "already done".

The optimistic case still closes, and still by less than the error bar on the renderer.
Two of the five rows — 22,000 of the 38,500 optimistic total, 57% of it — remain pure
estimate with no RTL behind them, and they are the two largest.

### 5.6 M10K is not budgeted here, and the sister project says it binds

**This section is a gap, not an analysis.** It exists because the Model 1 project reported,
at `4ff53be`, that on this device:

> M10K is the binding resource on this device now — 409 of 553 spent, with the
> rasterizer's band buffer wanting ~51 of what is left.

That is an empirical result from the same part, the same toolchain and a **simpler**
renderer: flat-shaded, painter's algorithm, no Z-buffer, no texture cache. This document
budgets ALM to 1,000-ALM precision across five rows and **does not budget M10K at all.**
Section 6.5's "~111 KB of 696 KB, room to push microcode ROMs and lookup tables off the
fabric" is the only figure, it counts three consumers, and it now looks optimistic.

A first pass at what Model 2 actually wants, at 1.25 KB usable per block:

| Consumer | Size | M10K | Source |
|---|---|---|---|
| Tile colour + Z, double-buffered | 64 KB | ~52 | §6.3 |
| Texture cache | 32 KB | ~26 | §6.4 |
| MB86234 program store + RAM banks | — | 3 | measured |
| fx68k microcode + nanocode ROMs | ~5 KB | 4-5 | reported |
| i960 I-cache + tags | 512 B | ~2 | §5.2 |
| S24TILE tile and char RAM | — | **unknown** | Model 1 has this figure |
| SCSP voice state and DSP | — | **unknown** | |
| MiSTer `sys/` scaler and framework | — | **unknown** | Model 1 has this figure |
| **Named so far** | | **~88** | |

The first five rows are the ones this document can already account for, and **78 of those
88 blocks are the tile buffers and texture cache — the two things Model 1 does not have at
all.** The three unknown rows are precisely where Model 1 spent most of its 409.

The arithmetic that follows is obvious and unwelcome. It does not close on its own, and it
cannot be settled by reasoning here, because the three unknown rows are the ones that
decide it.

Consequences, in order:

1. **Section 7's "push logic into M10K" lever may not exist.** It is listed under Tier 1,
   no accuracy loss, worth spending freely. If M10K binds, that lever is not free — it is
   the scarce resource, and moving the i960 FPU's coefficient ROMs there competes directly
   with the texture cache.
2. **Tier 2's "single texture unit rather than parallel" gets more attractive**, and a
   smaller texture cache becomes a real lever rather than a concession — which makes M2-A's
   hit-rate curve across 16/32/64 KB load-bearing rather than confirmatory.
3. **The tile size in §6.2 is now a two-sided trade.** 128x64 was chosen for bin traffic;
   it also sets the 52-block tile buffer directly. Halving tile height halves that.

**This needs a real budget before P1, not after P2.** Added to P0 in `milestones.md`. The
figures to collect are Model 1's actual per-consumer M10K breakdown — it has them — and
the MiSTer `sys/` framework's own usage, which both projects pay and neither has isolated.

---

## 6. Rendering architecture

Immediate-mode rendering does not fit. Tile-based rendering does. Highest-confidence
section of this document, and the right design on any hardware.

### 6.1 Why the naive bandwidth objection was wrong

An early version rejected Model 2 on texture bandwidth: ~180 MB/s of random reads against
30-40 MB/s of random-access capability. That assumed immediate-mode rendering with no
cache. Every GPU since 1996 solves this, and PowerVR shipped tile-based deferred rendering
on weaker silicon.

### 6.2 Binning

The geometry stage produces a Z-sorted polygon list. Bin to screen tiles before
rasterizing.

- 128 x 64 tiles: 24 across, 6 down, at 496 x 384.
- Bins hold polygon indices only. A few thousand polygons at ~4 bytes with modest overlap
  is under 100 KB of write traffic.
- Sequential write stream. No DDR3 latency cost.
- **Binning is our invention, not Sega's.** Full frame of latency budget, no accuracy
  implication, so it is the one block safely offloadable to the HPS if fabric gets tight.

### 6.3 Per-tile rasterization

Clear on-chip Z and colour, walk the bin into M10K, stream out as one sequential burst.

| Buffer | Size |
|---|---|
| Colour, 16bpp, 128 x 64 | 16 KB |
| Z, 16-bit | 16 KB |
| Double-buffered | **64 KB** |

Eliminates **every Z read and write from external memory** — ~90 MB/s on an
immediate-mode renderer at 2x overdraw, here zero.

### 6.4 Texture cache

The only random-access term left.

- **Swizzle at load time.** Morton order during ROM load, so a 4x4 texel neighbourhood is
  one contiguous burst. Free at runtime; the MRA loader already touches every byte.
- **32 KB M10K, 4-way, 64-byte lines.** A bilinear 2x2 fetch becomes one line hit rather
  than four scattered reads.
- **Locality is per-tile.** A 128 x 64 tile touches a bounded region of texture space.
  Working set is kilobytes, not 4 MB.
- **Mipmapping helps** — minified surfaces read smaller levels, improving hit rate.

At 90% hit rate, external texture traffic falls from ~180 MB/s random to ~18 MB/s burst.
**Measure this (M2-A).**

### 6.5 Memory assignment

| Content | Where | Pattern |
|---|---|---|
| Tile colour + Z | M10K, 64 KB | on-chip |
| Texture cache | M10K, 32 KB | on-chip |
| Texture data, 4 MB swizzled | DDR3 via f2sdram | cached bursts |
| Tile bins | SDRAM | sequential |
| Framebuffer | DDR3 | sequential |
| i960 program/data, geometry buffers | SDRAM | mixed |
| Tilemap, SCSP samples | SDRAM | mostly sequential |

DDR3's weakness is random-read latency. After tiling and caching, nothing in the DDR3
column is a random read. That is the whole argument.

M10K after tile buffers, texture cache and TGP state: ~111 KB of 696 KB. Room to push
microcode ROMs and lookup tables off the fabric.

---

## 7. Area reduction levers

### Tier 1 — no accuracy loss

- **Microcode the i960 FPU.** Shared datapath, CORDIC or polynomial with coefficient ROMs
  in M10K. Worth 2-3K. **No longer contingent on M2-B** — section 3 shows the silicon
  itself caps transcendentals at ~1,000 per frame, so a microcoded unit is faster than the
  part it replaces. Note the coefficient ROMs land in M10K, which section 5.6 says is the
  resource under pressure; count them there, not as free.
- **Push arithmetic into DSP blocks.** 112 available, Model 1 uses ~5. Edge and attribute
  interpolators, texture coordinate math, perspective divide all map to 27x27 MAC.
- **Push logic into M10K.** ~585 KB spare after section 6.5.
- **Offload our own scaffolding to the HPS.** Binning and swizzling are not Sega's
  hardware. Offloading our own inventions costs nothing; offloading the i960 costs
  everything.
- **Port rather than write, where licence permits.** `fx68k` for the 68000 (GPL-3), and
  the Model 1 core's own S24TILE, SDRAM, loader, CDC and overlay. **Not the SCSP** — the
  only RTL implementation is unlicensed (5.3). This lever is now fully spent except for
  whatever M2-G recovers.

### Tier 2 — bounded, measurable

- **Single texture unit rather than parallel.** Costs fill rate, not correctness. Tiling
  already decouples fill rate from external bandwidth. Measure against Daytona at speed.
- **Shrink the i960 register frame cache.** Costs cycles — but check section 4.3 first,
  cycles are not free here the way they were on Model 1.

### Tier 3 — these end the project's reason to exist

- **HLE the geometry.** Saves 4-6K. You then are not running the hardware's microcode and
  every game with custom geometry code becomes a compatibility problem.
- **Run the i960 on the HPS.** Saves 7-13.5K. Fails on latency: every coprocessor FIFO
  transaction crosses the h2f bridge at hundreds of nanoseconds, and the geometry upload
  path is chatty.
- **Point sampling instead of bilinear.** Visibly not Model 2.

All three fit comfortably and produce something with no accuracy claim, at which point
MAME's Model 2 driver on any modern SBC does the job better for zero effort.

---

## 8. Gates

Ordered by cost. The first three need no FPGA design work.

**M2-E — N64 core as measured comparable. Do first.**
`N64_MiSTer` is open, targets this exact part, builds with the same Quartus. One compile
gives a per-module fitter report.

| N64 block | Substitutes for | Estimate |
|---|---|---|
| RDP | textured tile-based rasterizer | 15-25K |
| R4300i | i960KB | 7-13.5K |

The RDP does bilinear, trilinear, mipmapping, Z-buffer with coverage, colour combiner and
blender — more capable than Model 2 needs — and fits alongside an R4300i *and* an RSP.
The R4300i is a fair i960KB proxy, arguably harder given the TLB and on-chip FPU.
Also extract **achieved Fmax at the N64 core's real utilization** — the only empirical
data point for degradation on this part.
*Pass:* RDP < 12K, R4300i < 12K. *Fail:* both at top of range.

**M2-B — i960 FPU usage.** Count FP instructions per frame across the target set,
broken down by opcode class (basic arithmetic vs transcendental). Section 3 shows the
full set is implemented; this establishes whether it is hot.
*Pass:* low enough that a microcoded unit costs no frame time. *Fail:* FP-bound.

**M2-A — texture cache hit rate.** Instrument `model2_v.cpp` to log every texel address.
Replay through a software cache model: 16/32/64 KB, 2/4/8-way, 32/64/128-byte lines, with
and without swizzling. Worst cases Daytona at speed, Sega Rally scenery.
*Pass:* >85% at 32 KB. *Fail:* <70% at 64 KB.

**M2-C — MB86234 delta from MB86233. CLOSED, PASS.** `mb86234_device` is an empty
subclass that overrides nothing (5.4.1). All 3,179 lines of Model 1 TGP RTL transfer
unmodified, along with their fuzz suites and lockstep harness. The residual risk is that
MAME's equivalence is an absence of evidence rather than a proof, and there is no oracle
that could tell us otherwise.

**M2-D — i960KB area and Fmax spike.** Standalone Quartus flow, same as Model 1 M0.
Pipelined, not FSM. *Pass:* <12K ALM and >90 MHz. *Fail:* >18K ALM.

**M2-F — pipelined MB86234 at <=4 CPI.** Section 4.2 is a hard requirement, and 5.4.1
quantifies it: the existing FSM delivers 7.3 M instr/s against ~16.7 M needed, so this is a
**2.3x throughput gap** on RTL that already exists and already passes. Still the cheapest
way to learn whether a pipelined TGP is tractable before committing to a pipelined i960 —
and now the cheapest by a wider margin, because the per-opcode fuzz suites and the
whole-CPU lockstep harness come with it and will catch a pipelining bug the same day it is
written.

**Deferred to P4.** M2-F was originally the cheap rehearsal for pipelining the i960. It no
longer is, because its input is still moving — the Model 1 MB86233 is under active
development and its measurement is not yet a closed number. Forking it now buys a merge
problem. The cost of deferring is stated in section 9: P1 pipelines the i960 with no
rehearsal behind it.

**M2-G — ask srg320 for an SCSP licence.** Costs one email and removes 3,000-5,000 ALM of
from-scratch work plus its verification (5.3). The RTL is written and works; only
permission is missing. Do it now, because the answer takes as long as it takes and a "yes"
changes the plan. *Pass:* any explicit licence grant compatible with GPL-3.
*Fail, or no reply:* write the SCSP against MAME's BSD-3 `scsp.cpp` and budget accordingly.
Until an answer arrives the budget assumes failure.

---

## 9. Verdict and preconditions

**Open, and decided by measurement rather than argument.** The optimistic budget closes
with ~3K spare. The margin is smaller than the error bar on the renderer, which remains the
one block with no oracle.

R6 changed the shape of the risk without changing its size. **~5,750 lines of measured,
fuzz-verified RTL transfer from Model 1 for free**, and the MB86234 turned out to be the
MB86233 exactly, which closes M2-C outright. Against that, the SCSP lost its assumed RTL
source and the i960 was confirmed to have none anywhere. Net area: 1,000 ALM. Net
information: substantial.

The honest summary is that **the blocks we can reuse are the ones that were never the
problem.** Everything portable is small — tilemap, loader, SDRAM, CDC, overlay, the TGP.
The three blocks that decide whether this fits — renderer, i960, SCSP — must all be written
from scratch, and two of them have no bit-exact oracle to write against.

**Preconditions before any RTL.** Revised — see `milestones.md` for the ordering and the
reasoning.

1. M2-E complete. The renderer and the i960 are 57% of the optimistic budget and neither
   has been checked against the one directly comparable core that exists.
2. M2-B complete. It scopes the FPU, which is most of the spread in section 5.2.
3. M2-G sent. Not a precondition on the answer, only on having asked.
4. ~~M2-C.~~ **Closed, pass** — section 5.4.1.

**No longer preconditions, and this is a deliberate reversal:**

- ~~*Model 1 M0 fully closed.*~~ It is not, and waiting on it would block the two blocks
  that decide the fit question on the one block that cannot. The Model 1 MB86233 is still
  under active development: its M0 measurement excludes the program store and both RAM
  banks, `fp_div` is not yet in the ALU, and the assembled core misses its own Fmax gate.
  Section 5's 2,554 ALM anchor is still the best figure available and section 4 still
  extrapolates from it — but **it is a moving number, and the TGP port is deferred to P4
  precisely so that it can stop moving before we fork it.**
- ~~*M2-F demonstrated before committing to a pipelined i960.*~~ M2-F was the cheap
  rehearsal — prove pipelining on the smaller CPU first. Deferring the TGP removes that
  rehearsal, so **P1 pipelines the i960 with nothing proven ahead of it.** That is a real
  increase in risk on the largest from-scratch block, accepted knowingly: the alternative
  is spending the schedule on a 3,000-5,000 ALM block that cannot change the answer.

**Close the study if:** M2-D puts the i960 above 18K ALM, or M2-E shows the RDP at the top
of its range, or P3 puts the i960 and renderer together above ~25,000 ALM with no
reduction lever left in section 7 tiers 1 and 2.

**Standing concern independent of area:** the renderer has no bit-exact oracle. Even a
Model 2 core that fits will be verified by framebuffer comparison rather than lockstep,
which is a materially weaker position than Model 1 enjoys on every block except its own
much simpler rasterizer.

---

## 10. Revision history

Wrong in both directions. Recorded so the reasoning can be audited and the failure modes
recognised.

**R1 — rejected on bandwidth.** Claimed texture fetch was unconditionally impossible.
Wrong: assumed immediate-mode rendering with no cache. Corrected by section 6.

**R2 — reopened on coprocessor multiplexing.** Argued five TGPs could share one datapath
with 3.5x headroom. Wrong: computed from MAME's `clocks/3`, treating a hardware ratio as
an RTL FSM cost. Measured cost is 9.83 CPI. Retracted.

**R3 — five TGPs.** Budgeted 12.8-25K for five instances. Wrong: MAME instantiates one
device with one program store and games run correctly. "5x" was a package count.
Corrected to one instance — but at 50 MHz, which forced the pipelining requirement.

**R4 — V60 carryover.** Assumed Model 1 CPU work would transfer. Wrong: `I80960KB` is the
main CPU. Nothing transfers.

**R5 — named-source audit.** Built section 1 from `model2a_state::model2a()` rather than
secondary sources. Findings: sound is 68000 + SCSP at derived clocks, not a guess; the
tilemap is `S24TILE`; **and there is no GPU device at all** — the renderer is HLE driver
code in `model2_v.cpp`. Also found `double m_fp[4]`: MAME models the 80-bit FP registers
as host doubles, so there is no bit-exact FP oracle. Also found the full transcendental
set implemented, raising the FPU area floor.

**R6 — RTL sourcing audit.** R5 audited the *device list* against MAME source but left the
*RTL availability* claims in section 5.3 unchecked, and they were written as though checked.
Every one has now been verified against the repository it names.

Three findings, in order of how much they change the plan:

- **The SCSP claim was false.** R5 stated srg320's Saturn SCSP was "GPL —
  licence-compatible". `srg320/Saturn`, `srg320/Saturn_MiSTer` and
  `MiSTer-devel/Saturn_MiSTer` all carry **no licence file**, and `SCSP.sv` has no SPDX
  header. All rights reserved. A block budgeted as "adapt existing RTL" became "write from
  scratch", and the project's own precedent on `geometrizer` had already settled that
  reading is permitted and adapting is not. Retracted, and M2-G added to try to recover it.
- **M2-C closed on inspection of one header.** `mb86234_device` is an empty subclass of
  `mb86233_device`. The entire Model 1 TGP — 3,179 lines, 2,554 ALM measured, 8,000 retires
  of lockstep — transfers unmodified. A gate that was scheduled as work turned out to be a
  five-minute read.
- **The S24TILE claim was wrong in our favour.** R5 justified it with "a MiSTer System 24
  core exists"; no such core was found. It did not matter: `model1.cpp:1830` instantiates
  the same `S24TILE` device, so the tilemap was already written here.

Also recorded: **no open-source i960 exists in any HDL** (5.4.3), which was never stated as
a risk before; and `N64_MiSTer` is GPL-3.0 rather than merely readable, which makes it an
architectural reference for the renderer and not only a fitter-report comparable (5.4.2).

Net effect on area: **1,000 ALM out of 39,500.** Effectively nothing. The value of R6 is
entirely in knowing which numbers are measurements and which are hopes — see 5.5.

**R7 — the integer oracle is not quite whole.** §2 carried "Integer yes" for the i960 from
R5 onward, and it is very nearly true. Writing the ALU found one exception: MAME's `addc`
and `subc` never set the carry flag, because their expression evaluates entirely in
`uint32_t` and wraps before being widened to `uint64_t`. §2.3 has the detail and the
decision — the RTL implements hardware carry and diverges deliberately.

Worth separating two things this revision could be mistaken for. It is **not** a case of
the study being wrong about MAME's quality; the file is otherwise an unusually careful
model, which is why §3's cycle table is trustworthy enough to size the FPU from. And it is
**not** licence to diverge whenever the reference looks inconvenient. The bar cleared here
was: the intent is documented in the source itself, the defect is mechanical and
demonstrable in three lines of C++, and the divergence is bounded by measurement rather
than argument.

**Third recurring failure mode, and this one is new:** a verification suite that passes
enormously proves the two things being compared agree, not that either is right. The
decoder cleared 6.0e9 field checks against a reference sharing its author and its source.
The ALU cleared 4.26e9. Both numbers are worth exactly as much as the independence of the
oracle behind them — which for the decoder was partial (`i960dis.cpp` could check the
opcode set and formats, not the field positions) and for `addc`/`subc` was zero, because
there the reference is the thing that is wrong. **State what an oracle cannot see, next to
the number that makes it look unnecessary.**

**Recurring failure mode:** treating MAME's cycle counts as hardware facts. Two wrong
conclusions in this document from that alone. Both `mb86233.cpp` and `v60.cpp` carry
timing models that are explicitly approximations, and `v60.cpp` says so in a comment.
Check the source before building an argument on a cycle count.

**Second recurring failure mode, from R6:** asserting that third-party RTL exists and is
licence-compatible without opening the repository. R5 did this three times in one table and
was wrong twice — once against the project and once in its favour. A licence claim is a
fact about a file, and checking it costs one API call. **Neither a search result nor a
recollection is a licence check.** `THIRD_PARTY.md` records the verification, not the
belief.
