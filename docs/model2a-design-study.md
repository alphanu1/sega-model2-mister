# Sega Model 2A-CRX on Cyclone V — design study

**Order note:** `docs/milestones.md` now runs a **P1.5 — 2D on hardware** slice before
the renderer, pulled forward from P5/P6. The decision and its cost are recorded there.
This study is unaffected: it still holds that the fit question governs, and P1.5
explicitly does not advance it.

**Throughput: settled by R16 at ~3.0x margin** (R10 and R13 were withdrawn by R15; R16
replaces them from verified-uncollapsed traces). Demand is 30,949 instructions of work per
frame; the core runs it in 33.4% of a frame. Area figures were never affected — they are
fitter output, not traces.

**Status: the fit question is answered in the affirmative, on measurements.** Optimistic
budget fits with **14.1K spare** against the 92% routing line; pessimistic is 1.7K over it
and still fits the raw device. The total is **24,454-40,293**, down from 34,160-49,460 and
originally 38,500-61,300 — and the movement came from *fitting six blocks*, not from a
better argument. Only two rows in the budget are still estimates (§5.5). Every block is anchored to a named MAME device except the
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

**The RTL implements the hardware behaviour.** The project rules put the reference above
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

**Corrected — and this weakens the conclusion above.** An earlier revision argued that
`i960.cpp` could be trusted where `v60.cpp` could not, because the i960 values differ per
opcode and are barely hedged while the V60's are flat and disclaimed. That is inference
from the *absence* of a disclaimer, which is not evidence of accuracy. Re-checked:
`i960.cpp` carries no header caveat at all, and MAME's own documentation makes no accuracy
claim about instruction cycle counts either way.

Section 4.1's rule therefore applies here exactly as it applies everywhere else: **MAME's
cycle counts are estimates unless proven otherwise.** Differentiated is not measured — a
careful author working from a datasheet and a careful author working from judgement both
produce differentiated numbers.

The hedge that the conclusion "survives the figures being wrong by a factor of two" only
helps if the figures are in the right region at all. If they were invented it does no work
whatsoever.

So this is a **hypothesis, not a finding**, and two things would settle it: the i960KB
Programmer's Reference Manual **270567-001** (cited in `i960dis.cpp`'s own header), and
**M2-B**, which counts what the games actually issue and depends on no cycle model at all.
The area budget in section 5.2 deliberately keeps the **full** 2,500-6,000 FPU range
rather than moving toward the bottom on the strength of this.

**M2-B therefore stands as originally written**, and is more important than the previous
revision implied. It counts FP instructions per frame by opcode class from real game
execution, which depends on no cycle model at all — making it the one piece of evidence
here that survives the timing table being wrong. Detail in `p1-i960-spike.md` §4.

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

Strongest anchor is a measurement in the right currency, from this flow, on this part.
**Re-measured at `tools/model1-ref` `198e1d9`: MB86233 = 2,355 ALM, 1 DSP, 6 M10K, 46.66
MHz**, including a full IEEE-754 single multiplier and adder, register file, AGU and
sequencer. The earlier figure here was 2,554 ALM / 3 M10K; the core has since moved work
into M10K, which is the direction that project's own resource finding predicts.

The strongest anchor is now our own: **`i960_top` = 7,807 ALM**, an entire CPU with FPU,
fitted here. See §5.5 for every block measured in every currency.

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

Every row that could be measured on this part, through this flow, now has been.
Six blocks were fitted for this revision; only two rows remain estimates.

| Block | Optimistic | Pessimistic | Status | Basis |
|---|---|---|---|---|
| i960KB + FPU | 7,807 | 9,500 | **7,807 measured** | assembled and fitted here, interrupts included. Optimistic = as built; pessimistic adds faults, transcendentals and the `rl` forms |
| 1x MB86234 | 2,355 | 4,000 | **2,355 measured (MB86233)** | Model 1's coprocessor, same family, fitted here. Pessimistic assumes pipelining |
| 3D renderer | 2,537 | 8,347 | **bracketed, both ends measured** | VDP1 2,537 (floor: no Z, no perspective); RDP 8,347 (ceiling: more capable than Model 2 needs) |
| Sound: SCSP + 68000 | 4,164 | 4,164 | **both measured** | SCSP 2,030 (same chip) + fx68k 2,134 (the core we intend to port) |
| Tilemap + I/O | 1,800 | 7,652 | **ceiling measured** | VDP2 6,852 is a *ceiling* — Saturn's tilemap is far richer than Model 2's System 24 layer. I/O 315-5649 small |
| `sys/` framework | 6,630 | 6,630 | **measured** | same framework, same device, from M2-E |
| **Total** | **24,454** | **40,293** | | |
| **Against 41,910 ALM (device)** | fits, 17,456 spare | fits, 1,617 spare | | |
| **Against 92% routing (38,557)** | **fits, 14,103 spare** | **1,736 over** | | |

Revised from **34,160 - 49,460**. Both ends moved a long way down, and none of it
came from a better argument — it came from fitting six blocks instead of guessing
at them. **The optimistic case now fits with room to spare, and even the
pessimistic case fits the raw device.**

#### Every measurement, in every currency

The device is **41,910 ALM, 553 M10K, 112 DSP**. ALM has been the only currency
this budget tracked; M10K is the one the Model 1 project found binding, so it is
tabulated here too. All figures are Quartus 17.0.0 Build 595, 5CSEBA6U23I7,
each block fitted standalone.

| Block | ALM | registers | M10K | MLAB bits | DSP | Fmax | whose RTL |
|---|---|---|---|---|---|---|---|
| `i960_top` | **7,807** | 4,872 | 1 | 2,048 | 7 | 26.4 | **ours** |
| P1.5 core as built (framework + PLL + video timing + overlay + SDRAM + loader + **S24TILE**) | **8,428** | — | **163** | — | — | — | **ours + upstream, MEASURED ON HARDWARE** |
| `sys/` framework | **6,630** | — | — | — | — | — | upstream (M2-E) |
| VDP2 (tilemap ceiling) | **6,852** | 9,184 | 4 | 272 | 12 | 65.73 | srg320 |
| N64 RDP (renderer ceiling) | **8,347** | — | — | — | — | — | N64_MiSTer (M2-E) |
| VDP1 (renderer floor) | **2,537** | 1,707 | 0 | 512 | 3 | 31.52 | srg320 |
| `mb86233_core` | **2,355** | 1,842 | 6 | 0 | 1 | 46.66 | Model 1 @ `198e1d9`, after its TGP fixes |
| fx68k | **2,134** | 1,412 | 6 | 0 | 0 | 68.45 | ijor, GPL-3 — to port |
| SCSP | **2,030** | 2,379 | 26 | 0 | 2 | 76.73 | srg320 |

**Totalling the blocks a Model 2A actually needs** — i960 + MB86234 + renderer +
SCSP + 68000 + tilemap + `sys/`:

| | ALM | M10K | DSP |
|---|---|---|---|
| optimistic (VDP1 floor, modest tilemap) | 24,454 | ~45 | ~14 |
| pessimistic (RDP ceiling, VDP2 tilemap) | 40,293 | ~55 | ~28 |
| **device** | **41,910** | **553** | **112** |

**M10K, now with a real integrated datapoint.** The P1.5 core — framework, PLL,
video timing, overlay, SDRAM controller, ROM loader and the S24TILE tilemap —
measures **163 M10K of 553 (29%)** on hardware, against 56 before the tilemap went
in. So the tilemap alone costs ~107 blocks, and that is the first figure here taken
from an assembled, *working* core rather than from blocks fitted standalone.

**M10K is not the binding resource for Model 2, and now that is measured rather
than assumed.** The blocks together use tens of M10K against 553. That answers
the concern the fx68k pull raised for the Model 1 project — it is real there and
does not transfer here — with one caveat stated plainly: **the renderer's
framebuffer and texture cache are not in these numbers**, because no renderer RTL
exists. A 496x384 16-bit framebuffer alone is 3.0 Mbit, or 298 M10K, and that is
the number to watch. DSP at ~28 of 112 is comfortable in every case.

#### What is actually PROVEN, on this part, with Quartus 17.0.0

**Six blocks totalling 31,506 ALM have been fitted on the target device.** Of the
blocks a Model 2A needs, the measured total is **15,743 ALM of directly-usable
figures** (i960 7,807 + `sys/` 6,630 + SCSP 2,030) plus bracketing proxies for
everything else.

| | ALM | whose RTL | what it proves |
|---|---|---|---|
| i960KB + FPU | **7,807** | **ours** | the CPU as built: integer, FPU, I-cache, register file, interrupts, 7 DSP, 26.4 MHz |
| `sys/` framework | **6,630** | upstream | the same framework on the same device, whichever core wraps it |
| SCSP | **2,030** | srg320 | the *same chip* Model 2 uses, fitted on the target part |
| fx68k | **2,134** | ijor | the *actual core we intend to port*, GPL-3 and licence-clear |
| MB86233 | **2,355** | Model 1 | the coprocessor's *sister part*, from a project measuring the same silicon |
| **total measured** | **20,117** | | |
| of which ours or portable | 11,457 | | |

The three have different standing and it matters:

- **7,079 is ours and is the strongest number in this document.** It is not a
  proxy or an analogy — it is the thing itself, fitted.
- **6,630 is upstream's, but it is the identical code**, so it transfers exactly.
- **2,030 is srg320's implementation of the SCSP, not ours.** Ours could differ.
  It bounds the block with a real figure on the real part, which is what M2-E is
  for, but it is not a measurement of code we will ship.

#### The i960 row: mostly measured, and what the remainder is

7,907 of the 9,000-14,000 exists and is fitted. (`i960_top` alone measures **7,807
ALM** as of R12, flat across the `callx` and `cvtri` work.) The remainder is not more of
the same — it is a specific, listable set:

| still to build | why it is not free |
|---|---|
| six glibc transcendentals | `sin cos tan atan log exp`, bit-exact; coefficient tables should land in M10K, not ALM |
| faults | absent entirely, and they touch the sequencer |
| interrupts | absent entirely; no `irq` port exists. Needs the PRCB interrupt table, vectoring, a type-7 call onto the interrupt stack, and the IP/AC save-restore |
| `synmov`/`synmovq`, `calls`, `modpc` | bounded opcode work. `calls` measures 0.000% in the Daytona traces (R13) |
| `rl` double-precision forms | needs four register reads against a two-port file |
| ~~the pipeline~~ | **struck again by R16, now on measured grounds.** It was struck on R10's grounds that the 12.5 M floor was the chip's capability rather than the game's demand — and R10's demand measurement is withdrawn, because every trace behind it was loop-collapsed. Fmax is **26.84 MHz against the real part's 25**, so the clock is met. Our ~5 CPI against the chip's 1.3-2 is real, but **71-73% of Daytona's instruction stream is two poll loops**, measured over 12 consecutive frames: demand is 30,949 instructions of work per frame, run in **33.4% of a frame**. The pipeline is not required for Model 2 |

The optimistic 9,000 assumes the transcendentals go mostly to M10K and the
pipeline costs little area; the pessimistic 14,000 assumes neither. **Neither
end is measured, but the base under them now is** — which is the difference
between this row and the renderer row.

#### The renderer row is now bracketed rather than anchored

M2-E gave a **ceiling**: the N64 RDP, a textured, Z-buffered, mipmapped,
bilinear *and trilinear* rasterizer with a colour combiner and coverage AA,
costs **8,347 ALM on this exact part**. Model 2 needs less than that.

ST-V gives the **floor**, once run: Saturn's VDP1 is a quad rasterizer like
Model 2's — where the RDP is triangle-based — but with no Z-buffer, no
mipmapping and no filtering, all of which Model 2 has. So it must come in under
our renderer.

**Two measurements bracketing an estimate is worth more than one anchoring it**,
and neither is our renderer. The 8,000-14,000 stands until VDP1 is measured.

#### Only two figures here are measurements of *this* design

An earlier version of this table put "M2-E: RDP = 8,347" in an "Anchor" column
against a renderer row reading 8,000-14,000, which implies the measurement
produced the range. **It did not, and the distinction matters.**

- **`sys/` framework, 6,630** — a measurement of the thing itself. The MiSTer
  framework is the same code on the same device whichever core wraps it.
- **i960, 3,754 of 8,254-13,354** — a measurement of the part that exists.
- **Everything else is an estimate**, including the renderer.

**What M2-E actually established about the renderer** is that a textured,
Z-buffered, mipmapped, bilinear *and trilinear* rasterizer with a colour
combiner and coverage-based anti-aliasing costs **8,347 ALM on this exact part
with this exact toolchain**. That is a real and useful fact. It is not our
renderer.

The 8,000-14,000 range is a judgement about how far our architecture differs,
and the differences run both ways:

| cheaper than the RDP | more expensive than the RDP |
|---|---|
| no trilinear filtering | tile binning — §6.2, which the RDP has no equivalent of |
| no colour combiner | on-chip tile buffer management and double-buffering |
| no coverage-based anti-aliasing | texture cache controller — the RDP streams from RDRAM |

Roughly a wash at the optimistic end, hence 8,000. The pessimistic 14,000 is
~1.7x the RDP and is a guess at how badly the binning and tile machinery could
go. **Neither bound is measured**, and the row should be read as "an informed
estimate that finally has something to be informed by", not as a result.

The honest summary of what M2-E changed: it removed the possibility that the
renderer is 25,000 ALM. It did not establish what the renderer is.

**The 92% line is not decoration.****The 92% line is not decoration.** M2-E's compile failed to fit at 92% ALM with
`Error (11802)`, and while that is a build-configuration difference rather than a
property of the N64 design, it is direct evidence of where this device stops
routing. Budget against 38,188, not 41,509.

#### The other two resources, which this study has never budgeted

ALM stopped being the only question the moment M2-E reported 111 DSP of 112.

| | quantified | of | note |
|---|---|---|---|
| ALM | 34,384 - 51,784 | 41,509 | budget above |
| **DSP** | **67 - 102** | **112** | never budgeted before; renderer alone wants 40-60 |
| M10K | ~125 quantified | 553 | 77% still unbudgeted (§5.6) |

The DSP row is assembled from: renderer 40-60 (RDP uses 61), i960 FPU 4-12,
SCSP 2-8, `sys/` framework 17 measured, TGP 1 measured, our `i960_muldiv` 3
measured. **The optimistic end leaves 45 blocks spare and the pessimistic end
leaves 10.** §7 Tier 1's "push arithmetic into DSP blocks — 112 available, Model
1 uses ~5" is therefore true only in the optimistic case, and must stop being
described as free capacity.

### 5.5.1 M2-E — measured, and the renderer estimate was far too high

`N64_MiSTer` compiled for `5CSEBA6U23I7` with Quartus 17.0.0. Per-entity, from
the fitter's own hierarchy table:

| Entity | ALM | block memory bits | DSP |
|---|---|---|---|
| `sys_top` (whole core) | 38,492 | 1,323,859 | **111 / 112** |
| `n64top` (the machine) | 30,486 | 939,029 | 84 |
| **`cpu` — R4300i** | **9,236** | 207,872 | 9 |
| — of which `cpu_FPU` | 2,297 | 0 | 0 |
| **`RDP` — the rasterizer** | **8,347** | 202,357 | 61 |
| `RSP` | 5,660 | 86,016 | 8 |
| `VI` video interface | 2,206 | 202,752 | 6 |
| `ascal` scaler (framework) | 2,012 | 315,488 | 17 |
| `hps_io` (framework) | 993 | — | — |

**Gate: RDP < 12K, R4300i < 12K. Both pass.**

#### This is the most consequential measurement in the project so far

**The renderer estimate was roughly 2-3x too high.** §5.5 carries 15,000-25,000
for our rasterizer. A *more* capable one — trilinear, a colour combiner,
coverage-based anti-aliasing, all things Model 2 does not need — costs **8,347
ALM**. §2.1's claim that the renderer is "the widest estimate in the budget with
no reference implementation to reason from" was true when written and is now
answerable: there is a measured comparable and it is less than half the
estimate's midpoint.

**The i960 projection is validated.** The R4300i is 9,236 ALM including a 2,297
ALM FPU, against our 8,254-13,354 projection for a broadly comparable 32-bit
RISC. The two agree, which is the first independent check either number has had.

#### And one finding that cuts the other way

**DSP is at 111 of 112 — 99%.** §7 lists "push arithmetic into DSP blocks" as a
Tier 1 area lever on the grounds that 112 exist and Model 1 uses ~5. That lever
is real but it is *not* free capacity: a comparable renderer consumes essentially
the entire DSP complement, 61 of them in the RDP alone. Model 2's renderer will
want them for edge and attribute interpolation, texture coordinates and the
perspective divide, and the i960's FPU will want more.

**The N64 core did not fit**, failing at 92% ALM with `Error (11802): Can't fit
design in device`. Since it ships on this hardware, that is a build-configuration
difference rather than a property of the design, and it does not affect the
per-entity figures above — those come from the fitter's placement before it gave
up. But it is a standing warning that **92% ALM is where this device stops
routing**, which makes the usable budget lower than 41,509 suggests.

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

The budget, with every row marked measured or estimated. One M10K is 10,240
bits; a 32-bit-wide array wastes none of that, a narrower one does.

| Consumer | bits | M10K | source |
|---|---|---|---|
| Tile colour + Z, 128x64 16bpp, double-buffered | 524,288 | **52** | §6.3, estimated |
| Texture cache, 32 KB | 262,144 | **26** | §6.4, estimated — M2-A sizes it |
| i960 I-cache, 512 B (tags are flip-flops) | 4,096 | **1** | **measured** |
| MB86234 program store + RAM banks | 30,720 | **3** | **measured**, Model 1 M0 |
| `fx68k` microcode + nanocode ROMs | ~40,960 | **4** | reported, not measured |
| **quantified** | | **86** | **16% of 553** |

And the rows nobody has a number for:

| Consumer | why it is unknown |
|---|---|
| S24TILE tile RAM + char RAM | Model 1 has this figure; not yet extracted |
| SCSP voice state, DSP, envelopes | unbuilt |
| MiSTer `sys/` scaler, HPS I/O, audio | **measured** — see below |
| i960 FPU coefficient ROMs | §7 Tier 1 explicitly puts them here |
| renderer bin and line buffers | unbuilt |

**The framework's own cost is now measured**, from M2-E's per-entity table:
`sys_top` minus `emu` is **6,630 ALM**, and its two largest memory consumers are
`ascal` at 315,488 block memory bits (~31 M10K) and `hps_io`. Call the framework
**~35-40 M10K**, which lifts the quantified total from 86 to roughly **125 of
553**.

**23% of the device is accounted for and 77% is not.** That is the finding, and
it is worse than "the budget is tight" — there is no budget.

For scale, M2-E also measured what a comparable machine spends: the N64 core
uses **236 of 553 M10K (43%)** in total, with the RDP alone at 202,357 block
memory bits (~20 M10K) and the R4300i at 207,872 (~21 M10K). That is a working
renderer and CPU inside 41 blocks — far less than the 78 our tile buffers and
texture cache are budgeted for, because the RDP streams from RDRAM rather than
holding a tile on chip. **Our tile-based architecture trades M10K for external
bandwidth, and M2-E is the first measurement of what that trade costs.**

Two things are already clear from the quantified rows alone:

- **The i960's own M10K appetite is negligible: one block.** The register cache
  went to MLAB deliberately (§5.4.1 of `p1-i960-spike.md`) and the I-cache is a
  single block. The CPU is not the problem here.
- **78 of the 86 quantified blocks are the tile buffers and texture cache** —
  the two structures Model 1 does not have at all. Model 1 reached 409 of 553
  *without* them.

If Model 2's non-renderer consumers resemble Model 1's, 409 + 78 = 487 of 553
before the SCSP, the FPU ROMs or anything the renderer needs beyond its tile
buffers. That does not obviously close, and it cannot be settled by argument
because the unknown rows are the deciding ones.

**This needs a real budget before P1, not after P2.****This needs a real budget before P1, not after P2.** Added to P0 in `milestones.md`. The
figures to collect are Model 1's actual per-consumer M10K breakdown and the MiSTer `sys/`
framework's own usage, which both projects pay and neither has isolated. The second of
those falls out of M2-E for free: compiling `N64_MiSTer` produces a per-entity fit report
in which `sys_top`'s framework blocks are itemised separately from the core's.

**Levers, if it does not close.** All three are in §6 already and all three are ours to
move, which is the one comfort here:

- **Halve the tile height.** 128x64 is a bin-traffic choice (§6.2); the buffer cost is
  linear in it. 128x32 halves 52 blocks to 26 at the price of more bin overhead.
- **Shrink the texture cache.** M2-A sweeps 16/32/64 KB precisely so this is a measured
  decision rather than a concession — 16 KB is 13 blocks instead of 26.
- **Single-buffer the tile.** Costs a stall between rasterize and stream-out, saves 26.

Together those three take the quantified 86 down to 34 without touching accuracy, which
is why §5.6 is a scheduling problem rather than a kill condition — provided it is
discovered before the RTL is written rather than after.

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
  in M10K. Worth 2-3K. **Contingent on M2-B**, as originally written — section 3's
  argument that the silicon caps transcendentals at ~1,000 per frame rests on MAME cycle
  counts that are not verified, so it does not remove the contingency. Note the
  coefficient ROMs land in M10K, which section 5.6 says is the resource under pressure;
  count them there, not as free.
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

**M2-E — N64 core as measured comparable. CLOSED, PASS. See 5.7.**
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

**R8 — the cycle-count rule applies to `i960.cpp` too.** R6 and the P1 work leaned on
`i960.cpp`'s per-opcode timings to argue the FPU could be microcoded, justifying it on the
grounds that this file is more careful than `v60.cpp`. The justification was structurally
unsound: it inferred accuracy from the absence of a disclaimer. The file has no header
caveat, and MAME claims nothing about cycle accuracy in either direction.

Nothing about the FPU plan is now known to be wrong — a microcoded shared datapath may
well be right. What changed is that it is a hypothesis again rather than a settled finding,
M2-B is back on the critical path for that decision, and the budget keeps the full
2,500-6,000 range. **This is the recurring failure mode below, caught for the third time,
and the first two were in this document's own history.** The rule is not "check v60.cpp";
it is "check any cycle count before building on it".

**Recurring failure mode:** treating MAME's cycle counts as hardware facts. Three wrong
conclusions in this document from that alone. Both `mb86233.cpp` and `v60.cpp` carry
timing models that are explicitly approximations, and `v60.cpp` says so in a comment.
Check the source before building an argument on a cycle count.

**R9 — a CPI figure is a property of the instruction mix, not of the CPU.** The P1
work has quoted two CPI numbers for the same RTL — 3.31 and 18.50 — and both are
correct. 3.31 was warm-cache on an integer mix before the FPU was integrated; 18.50 is
the current whole-CPU lockstep, where `T_MULDIV` alone is **53.2% of all cycles at 9.84
cyc/instr**. Nothing regressed between them: the fuzz generator emits instruction
classes roughly uniformly, so divides are represented far above their frequency in real
code, and the FPU added a second multi-cycle unit to the same synthetic stream.

*What was believed:* that measured CPI on the lockstep harness was a throughput figure
for §4.3's 12.5-16.7 M instr/s requirement.

*What is now known:* it is a throughput figure for the **generator's** mix, which was
built for coverage — every opcode exercised roughly equally — and coverage weighting is
close to the opposite of frequency weighting. Any CPI derived from it is an upper bound
on cycles, not an estimate.

*How established:* per-state cycle profiling in `tb_i960_top.cpp`, after the FP request
strobes were fixed. Fetch was 58% of cycles before the I-cache fill hold and sequential
prefetch; it is now 24.5% and divide dominates.

**This raises M2-B's value and changes what it is for.** It was scoped as "how hot is
FP, to decide whether the FPU can be microcoded". It is now also the **only** source of
the instruction-mix weighting that turns a cycle profile into a throughput number.
Without it, P1's exit criterion 4 can be measured (Fmax, ALM) but the §4.3 throughput
argument cannot be evaluated at all.

**Third recurring failure mode:** quoting a derived number without its basis. The 3.31
was not wrong when written and is not wrong now — it simply never carried the mix it was
measured on, so it read as a property of the design. Record the conditions with the
number or the number will be reused somewhere it does not apply.

**R10 — the i960 throughput requirement was the chip's capability, not the game's
demand, and the design already exceeds the demand by 7x.** P1 has been measured all
along against **12.5-16.7 M instr/s**. That figure is what a 25 MHz i960KB at 1.5-2 CPI
can *deliver*. It was never a measurement of what Model 2 software *needs*.

*What was believed:* that the core must reach 12.5 M instr/s to run Model 2, and that the
multi-cycle sequencer's shortfall against it was the project's second-largest risk.

*What is now known:* Daytona's i960 executes **~15,400 instructions of work per frame**,
which at 60 fps is **0.93 M instr/s**. The assembled core delivers **6.86 M instr/s**.
**The requirement is met with roughly 7.4x margin, and has been for some time.**

> **Corrected by R13, then WITHDRAWN by R15.** R13 corrected the figure to 5.33 M
> instr/s on a 5.7x margin. **R15 withdraws the demand side of this entry entirely:**
> every trace it rests on was loop-collapsed and omitted 77-85% of the instructions
> that executed — including, specifically, the spin-loop bodies this entry counted as
> 0.1%. The margin is **unproven, not disproven**, and no figure here may be quoted
> until a settled uncollapsed trace is counted.

*How established:* three single-frame traces (17 ms each) of `daytona93` under MAME
0.289, instrumented via the debugger. 14,469 / 14,474 / 17,441 instructions. The work is
genuine and distributed — **4,200 distinct PCs per frame, hottest 0.4%, and only 0.1% of
instructions in a spin loop** — so this is not a CPU idling against a slow emulation. The
sample is a full 3D demo race, confirmed by screenshot.

*Why the figure is trustworthy despite R8.* R8 warns that MAME's cycle counts are
estimates, and `model2.cpp` does call `i960_stall()`. But this measurement does not use
MAME's cycle model: it counts **instructions between frame boundaries**, and the frame
boundary is set by video hardware. The remaining objection — that MAME might be starving
the CPU so it never finishes its per-frame work — is answered by the game running
correctly, by the per-frame count being stable across frames (a fixed workload, not
work-until-vblank), and by the near-total absence of spinning.

*Consequences, and they are large:*

- **P1's throughput exit criterion is met.** The pipeline the spike document has demanded
  since §4.3 is **not required for Model 2**. It would still be required to match the real
  chip, which is a different and unasked question.
- **A session of optimisation was spent against an unverified number.** Throughput went
  2.82 -> 6.86 M instr/s and every step was real, but the target it was chasing was never
  the requirement. The measurement that would have shown this cost hours.
- **The i960's remaining work is functional, not performance**: faults, `synmov`/`calls`/
  `modpc`, interrupts, the `rl` forms. M2-B already indicated the transcendentals may be
  unnecessary.

**Third recurring failure mode, and it now has three instances:** optimising against a
figure whose basis was never checked. R9 was CPI quoted without its instruction mix; this
is a throughput target quoted without its workload. **Before optimising against a number,
establish what measured it.**

**Second recurring failure mode, from R6:** asserting that third-party RTL exists and is
licence-compatible without opening the repository. R5 did this three times in one table and
was wrong twice — once against the project and once in its favour. A licence claim is a
fact about a file, and checking it costs one API call. **Neither a search result nor a
recollection is a licence check.** `THIRD_PARTY.md` records the verification, not the
belief.

---

**R11 — the sequencer called twice for every `call`, and no test could see it because
the generator emitted no calls.** `callx` was the last mnemonic Daytona executes that P1
had not implemented. Adding it exposed a defect that had been latent in `call` and `ret`
since the frame machinery was written.

*What was believed:* that the register file's `busy` output was sufficient to hold the
sequencer in `T_FRAME` until a frame operation completed, and that the whole-CPU lockstep
covered the frame path because `i960_regs` has a passing unit test.

*What is now known:* two defects, both real.

1. **`T_FRAME` exited one cycle early, always.** `busy` is `state != S_IDLE` inside
   `i960_regs`, and in the first `T_FRAME` cycle the register file has not yet *seen* the
   request — `op_call` is only being presented on that edge, so `busy` is still low. The
   sequencer left immediately, and because `next_ip_valid` is a one-cycle strobe that had
   not pulsed, `ip` was unchanged: it refetched the same instruction and executed the call
   again. Usually this was harmless by accident, since the second strobe landed while the
   file was mid-save and `S_CALL_SAVE` ignores `op_call`. But when the refetch was slow —
   an I-cache fill — the file finished the whole frame and was back in `S_IDLE` before the
   sequencer returned, and the second strobe was a *real* second call. **One `callx` was
   observed building five frames and spilling to memory.** Fixed by making the strobes part
   of the wait condition: `!rf_busy && !rf_call && !rf_ret && !rf_flush`.
2. **The call target was presented live rather than latched.** `next_ip` is sampled in
   `S_CALL_FIN`, several cycles after `op_call`, so the target must hold for the whole
   frame sequence. For `callx` the target is `ea`, which depends on `rd1`/`rd2` — and those
   change the moment `ra1`/`ra2` revert to their defaults on leaving `T_EXEC`. CTRL `call`
   never exposed it because its target is `ip_next + disp`, with no register dependency.

*How established:* a counter on `rf_call` assertions per retire. The first hypothesis —
that the DUT was not reaching the frame machinery at all — was **wrong**, and the counter
disproved it in one run by reading 6. A directed program containing exactly one `callx` and
nothing else that can move the frame then isolated the target problem from the count
problem; the two had been producing a single confusing symptom.

*Why nothing caught it:* **the whole-CPU generator never emitted `call` or `ret`.** The
frame path had a thorough unit test that drives `op_call` directly — and a unit test that
drives the request itself cannot possibly observe a *sequencer* that drives it twice. This
is the recurring failure mode of §10 in its sharpest form: a check that looks present and
does nothing. The generator now emits `callx`, and the register seeding gives SP and FP a
real home, which was never needed while nothing called.

*Second-order finding.* A random program clobbers SP or FP, and the next call then spills
sixteen words wherever that garbage points — including over the program. The i960's
instruction cache has no coherency with data writes, so the DUT keeps executing the stale
line while the reference, which has no cache, reads the new bytes. Both are correct and
they cannot agree. Recorded as a deviation and the program is abandoned, exactly as for a
subnormal operand. Likewise a `callx` targeting its own address recurses forever with the
IP never changing, which the harness's "IP moved" retire detector reads as a stall.

---

**R12 — `cvtri` overflow was untested by construction, and wrong in two separate ways.**
The whole-CPU suite had been passing on one seed. Sweeping seeds after R11 failed two of
them on `cvtri`, and both were pre-existing.

*What was believed:* that `eu > 31` identified an out-of-range conversion, and that
`test_i960_fpmisc` covered the conversion path — it passes 1.2 M checks.

*What is now known:*

1. **The exponent test misses an entire band.** An exponent of exactly 31 covers magnitudes
   from 2^31 up to 2^32, every one of which is out of int32 range **except** -2^31, which is
   representable. `-3.18e9` wrapped silently to a positive value.
2. **Rounding can carry the magnitude past 2^32.** `4294967295.5` rounds to 2^32, and the
   shifted result was being truncated to 32 bits *before* the range check — so it read as
   `0`, an entirely plausible small in-range value. The check must inspect the full-width
   shift, not `int_abs[31]`.

*Why the unit test passed anyway:* it contained the line
`if (r < -2147483648.0 || r > 2147483647.0) return;` — **it skipped every out-of-range
input**. The overflow path was excluded from a test whose entire purpose included it. The
skip existed to avoid undefined behaviour in the C++ reference; the correct treatment is to
*state* the expected value, not to decline to check.

*A decision the oracle rule settles.* MAME casts a `double` to `int32_t`, which is
undefined in C++ and yields x86's indefinite value `0x8000_0000`. The i960 manual instead
specifies the truncated low 32 bits when the integer-overflow fault is masked. These
disagree. **The oracle wins** (rule 11, order of authority), so the RTL returns
`0x8000_0000`. This is recorded rather than buried because it is a case where MAME's
behaviour is an artifact of its host rather than a model of the silicon — the same species
of trap as R8, in a value rather than a cycle count. Nothing in Daytona converts an
out-of-range float, so no game behaviour depends on the choice.

*Cost:* the corrected range check and the latched call target together measure **6,979
ALM** for `i960_top`, against 6,986 before — flat. Fmax moves 27.3 -> 26.84 MHz, which is
immaterial against the 7.4x throughput margin established in R10.

---

**R13 — the measured throughput omitted 4.4% of the workload, and it was the expensive
4.4%.** R10 established the margin using a Daytona-mix CPI of 3.91, giving 6.86 M instr/s.
That mix contained **no `call` and no `ret`**, because the whole-CPU generator emitted
neither (R11). Adding them at their measured rates moves the figure.

*What was believed:* that `+mix=daytona` reproduced Daytona's instruction mix, having been
built from M2-B's measured class shares — 52.9% load/store, 13.6% ALU, 9.7% move, 9.4%
compare/branch, 8.0% lda, 0.8% FP.

*What is now known:* those shares sum to 94.4%, and a good part of the remainder is the
frame operations. Counted directly from the same traces, over 233,878 instructions:

| mnemonic   | count | share  |
|------------|-------|--------|
| `call`     | 4,802 | 2.053% |
| `ret`      | 5,602 | 2.395% |
| `callx`    |   612 | 0.262% |
| `bal`      |    37 | 0.016% |
| `calls`    |     0 | 0.000% |
| `flushreg` |     0 | 0.000% |

**Corrected figures: CPI 5.04, and 26.84 / 5.04 = 5.33 M instr/s against a demand of 0.93
M instr/s — a 5.7x margin.** R10's conclusion stands; its number does not.

*A second lesson, and it is the sharper one: the rate was not enough.* Emitting `call` and
`ret` independently at 2.053% and 2.395% produced **CPI 6.71 and T_FRAME at 42% of all
cycles** — because `ret` slightly outnumbers `call`, so the modelled depth sits at zero and
almost every `ret` underflows into a sixteen-word reload from memory. That is a property of
the generator, not of the design.

What actually determines the cost is **how often a call exceeds the 4-frame register cache
and spills**. Measured from the traces by tracking depth through every call and ret:

```
depth after call:  1:6.3%  2:22.3%  3:10.0%  4:6.4%  5:1.8%  6:2.1%  7:0.3%
max depth 7;  calls at depth >= 4, which spill to memory: 8.5%
```

**Daytona's register cache absorbs 91.5% of its calls.** The generator now models depth
while emitting and holds it in that band; it reports its own spill rate next to the
measured one every run, so the mix cannot silently drift again. It currently runs at
**9.5%** against the measured 8.5% — slightly conservative, which is the right direction
for a figure used as a margin.

*Why this is R9 a third time.* R9 said a CPI is a property of the instruction mix. R10 said
a throughput target is a property of the workload. This adds: **a mix is not specified by
its rates alone when an instruction's cost depends on machine state.** A call costs about
six cycles from the register cache and roughly sixty through memory, and nothing in a table
of mnemonic frequencies says which. The check that makes this durable is not a better
number, it is the generator printing its spill rate beside the measured one on every run.

---

**R14 — interrupts are required for Daytona, not optional, and "all 80 mnemonics
implemented" does not mean the CPU can run the game.** R11 closed the last mnemonic Daytona
executes. That is a real milestone and it is not the same claim as "the i960 is done".

*What was believed:* that with `callx` built, the executed-instruction coverage was
complete and the remaining i960 work — faults, interrupts, `synmov`, `modpc` — was a list of
things Daytona does not reach. The remaining-work table filed interrupts under "bounded
opcode work".

*What is now known:* **Model 2 drives four i960 interrupt lines.** From
`model2.cpp::irq_update()`:

```
m_maincpu->set_input_line(I960_IRQ0, m_intreq & 0b0000'0000'0001 ? ...);
m_maincpu->set_input_line(I960_IRQ1, m_intreq & 0b0000'0000'0010 ? ...);
m_maincpu->set_input_line(I960_IRQ2, m_intreq & 0b0011'1111'1100 ? ...);
m_maincpu->set_input_line(I960_IRQ3, m_intreq & 0b1100'0000'0000 ? ...);
```

Twelve request sources — vblank, four timers, the sound UART — folded onto four lines. The
core has **no `irq` port at all**, so none of this can be delivered.

*Corroboration from the traces, and it is independent of MAME's interrupt model.* Over
233,878 traced instructions there are 4,802 `call` and 612 `callx` but **5,602 `ret`** — 188
more returns than calls. Some of that is window-boundary effect, but an interrupt return is
a `ret` with no matching call in the trace, and 188 over three frames is the right order for
an interrupt-driven game.

*Consequence.* Interrupts are not a completeness item, they are a **prerequisite for
executing Model 2 code at all**, and they are the gate in front of P1 exit criterion 3.
They are also not merely an opcode: the mechanism needs the PRCB interrupt table, vectoring,
a type-7 call onto a separate interrupt stack, the IP/AC save into the new frame, and `ret`
dispatching on `PFP[2:0]` to undo it.

*And a shared blind spot to fix with it.* **Both the module and its reference ignore
`PFP[2:0]` entirely** — `ret` always performs a type-0 return. They therefore agree, and
lockstep is silent. This is R11's lesson exactly: the reference and the design shared an
omission, so no amount of fuzzing could see it. MAME switches on the type and
`fatalerror`s on 1-6.

*The honest scorecard.* Daytona's *instruction set* is complete. Daytona's *machine* is
not.

---

**R15 — every i960 trace before 2026-08-18 was loop-collapsed, and the throughput
argument rests on them.** R10 and R13 are both affected. This is a retraction, not
a refinement.

*What was believed:* that `trace <file>,:maincpu` produced a countable instruction
stream. Three figures were derived from it: Daytona executes ~15,400 instructions
per frame (0.93 M instr/s), across 4,200 distinct PCs, with **0.1% of instructions
in a spin loop**.

*What is now known:* MAME collapses loops by default and prints
`(loops for N instructions)` in place of the bodies. Measured over the three
single-frame traces R10 used:

| trace | printed | hidden in collapse | true total |
|---|---|---|---|
| f1 | 14,469 | 49,149 | 63,618 |
| f2 | 14,474 | 73,647 | 88,121 |
| f3 | 17,441 | 95,480 | 112,921 |

**77-85% of the instructions that executed were never in the file.** And they were
not a random 80%: they were precisely the loop bodies, which is exactly the
population the "0.1% spin" claim was about. The measurement excluded the thing it
was measuring.

An uncollapsed 17 ms window, taken with the flag verified rather than assumed,
shows the shape the collapsed trace could not:

```
total instructions: 322,707      distinct PCs: 148
top 20 PCs: 99.8% of all instructions
hottest: 0x16B0-0x16BC, a four-instruction loop, 47,543 iterations
```

Against R10's "4,200 distinct PCs, hottest 0.4%". The collapsed trace showed the
*variety* of the code and hid the *repetition*, so it inverted the picture.

*What this invalidates.*

- **R10's 15,400 instructions/frame and 0.93 M instr/s.** Withdrawn.
- **R10's "0.1% of instructions in a spin loop".** Withdrawn, and it was the load
  -bearing claim: the whole argument was that Daytona's *work* is small, and the
  evidence for "this is work, not waiting" came from a file with the waiting
  removed.
- **R13's mnemonic census** (`call` 2.053%, `ret` 2.395%, `callx` 0.262%) and its
  **call-depth distribution**, both counted over the same collapsed traces. The
  generator mix, and therefore CPI 5.04 and **5.33 M instr/s**, inherit the bias.

*What is NOT yet known, and must not be asserted.* The corrected requirement. The
uncollapsed window above is a **boot** frame, not attract mode — a boot frame is
legitimately dominated by clear-and-wait loops, and R10's traces were taken ~40 s
in, during a demo race. A settled uncollapsed trace has not yet been produced: a
long `gtime` in a debugscript yields no trace file here, unresolved, and recorded
in `tools/i960-trace.sh`.

**So the position is: the margin is unproven, not disproven.** If most of the
recovered instructions are spin, R10's conclusion survives with a much smaller
stated margin, because a poll loop that runs fewer times still exits. If they are
work, the core is at or below the requirement. **Neither may be claimed until a
settled attract-mode trace is counted.**

*The pattern, and this is the fourth instance.* R9: a CPI quoted without its mix.
R10: a throughput target quoted without its workload. R13: a mix specified by
rates when cost depended on machine state. R15: **a workload counted from a file
that omitted most of the workload.** Every one is the same error — a number used
without establishing what produced it.

It is worse than the others in one respect. `docs/differential-testing.md` was
written *the same day*, and its first named artifact, carried over from the Model 1
core, is:

> **`noloop` is not optional.** Without it MAME's tracer collapses loops and
> prints `(loops for 620 instructions)`.

The warning was transcribed into this repository and the traces were not re-run
against it. **A lesson recorded is not a lesson applied.** `tools/i960-trace.sh`
now refuses to return any trace containing a collapse marker, which is the only
form of this that survives being forgotten.

---

**R16 — the throughput question, measured properly at last: ~3x margin, and the
reason the earlier answers were wrong is now visible.** R15 withdrew R10 and R13.
This replaces them, from traces taken with the collapse flag *verified* rather
than assumed.

*Method.* `tools/mame_i960_frame_trace.lua` starts the trace on a frame notifier
at frame 2300 of `daytona93` attract mode (~40 s in, the same window R10 used),
runs 12 consecutive frames, marks each boundary with `tracelog`, and
`tools/i960-trace.sh` refuses any trace containing a collapse marker. 1,285,223
instructions, 0 markers.

*The measurement.*

| | per frame |
|---|---|
| total instructions | 106,754 - 107,883 (mean **107,101**) |
| spin-loop instructions | 76,758 - 77,746 (**71.3 - 72.7%**) |
| **work** | 29,208 - **30,949** |
| distinct PCs | ~5,000 |

Two poll loops account for all of the spin:

```
000012B0: ldob    0x500000,r3        69.2% of the frame, 37,000 iterations
000012B8: cmpibe  r3,g0,0x12b0
0001166C: ld      0x91fff0,r3         2.6%
00011674: cmpibne 0,r3,0x1166c
```

*The decisive observation, and it is the one R10 asserted without ever showing.*
**The total is near-constant while the work varies.** Across 12 frames the total
moves 1.1% (106,754-107,883) while the work moves 6% (29,208-30,949), and at a
lighter point in attract mode (frame 3200) the work drops to 6,464 while the total
*stays* at 110,739. The CPU executes a fixed number of instructions per frame
because **it spins to fill whatever time is left**. So the total is **capacity, not
demand** — and a poll loop that runs fewer times still exits, because what it waits
on is driven by real time, not by CPU speed.

*The answer.*

- **Demand is peak work per frame: 30,949 instructions**, or 1.78 M instr/s at
  57.5 fps.
- At the core's **5.33 M instr/s**, that is **5.81 ms of a 17.39 ms frame — 33.4%
  utilisation, about 3.0x headroom.**
- The 5.33 figure is **conservative**, because R13's mix over-weighted the
  expensive frame operations (below), so the true CPI is lower.

*R13's census, recounted on clean data* (work-only, 356,587 instructions):

| mnemonic | R13 (collapsed) | R16 (clean) |
|---|---|---|
| `call` | 2.053% | **1.543%** |
| `ret` | 2.395% | **1.772%** |
| `callx` | 0.262% | **0.225%** |
| `calls` | 0.000% | 0.000% |
| `flushreg` | 0.000% | 0.000% |

Overstated by ~30%, in the predicted direction: collapsing hides loop bodies, so
it under-represents the cheap loads and branches that fill loops and
over-represents everything else. **The generator mix should be re-derived from
this trace**; until it is, the CPI of 5.04 stands as an upper bound.

*So where R10, R13 and R15 each landed.*

| | work/frame | demand | margin |
|---|---|---|---|
| R10 | 15,400 | 0.93 M instr/s | 7.4x |
| R13 | (same) | (same) | 5.7x |
| R15 | withdrawn | withdrawn | unproven |
| **R16** | **30,949** | **1.78 M instr/s** | **~3.0x** |

**R10's conclusion survives; its number was out by 2x and its evidence was
invalid.** The pipeline is still not required for Model 2 — but that now rests on
a measured 72% spin fraction rather than a claimed 0.1%.

*The caveat that remains, and it is the same one R10 had.* This is **attract
mode**, sampled at three points across 14 frames. Gameplay is not sampled and
could be heavier. That is a bounded, known gap rather than an assumption — and
the tooling to close it now exists and refuses to lie.

---

**R17 — the Model 1 core has measured, on this silicon, that the CPU's throughput
lever is the memory subsystem and not the CPU. R16's margin is measured against a
bus that does not exist yet.** Pulled from `tools/model1-ref` at `198e1d9` per rule
10, and it changes what R16 means without changing what R16 measured.

*What that project found* (`e490688`). Its V60 runs at **30.49 CPI** over 819,812
instructions, and it counted where the cycles go directly rather than reasoning
about it:

```
data-stalled   9,625,651 (38%)
fetch-stalled  6,819,902 (27%)
either        16,435,859 (65%)
```

**Roughly 20 of the 30.5 CPI is waiting on memory and ~10 is execution**, and the
two buckets barely overlap — a single arbitrated bus serialising them rather than
hiding one behind the other. Its CPU in isolation is ~6 CPI against MAME's implied
8, so **the 3.18x gap to the reference is almost entirely the memory subsystem**,
and extracting or optimising the CPU would not close it.

*Why this lands on us.* **R16's CPI of 5.04, and the ~3.0x headroom derived from
it, were measured in simulation against an idealised bus.** The whole-CPU
lockstep's memory answers on demand; it models no SDRAM latency, no refresh, and
no contention. On hardware the i960 will share SDRAM with the renderer, the TGP,
sound and video — five masters, which is the configuration Model 1 measured 65%
stall under.

**So R16 stands as measured and must not be quoted as a hardware margin.** It
says: *given a bus that answers immediately, the core has 3.0x headroom against
Daytona's work.* It does not say the assembled core will. Model 1's numbers are
the closest available evidence for the gap between those two statements, and they
are not reassuring — a 3.18x memory-induced gap against a 3.0x margin leaves
nothing.

*What follows, and it is a design consequence rather than a caveat.* If memory is
the lever, the i960's instruction cache stops being an optimisation and becomes
load-bearing. It already exists (`i960_icache.sv`) and measures a hit rate against
a workload; **what has never been measured is its hit rate against real Daytona
code under realistic latency.** That is the number to get before any pipeline
discussion resumes, and it can be had from the R16 traces plus a latency model,
without hardware.

*A second finding from the same pull, on M10K* (`1df103e`). The Model 1 core now
sits at **452 of 553 M10K — 82%** — with 29,536 ALM. §5.5 concluded M10K is not
binding for us, from **standalone block measurements** that contain no memory
subsystem, no caches and no FIFOs. Our own step-1 build already uses 56 M10K for
framework plus a test pattern. **That conclusion is weaker than it reads and
should be re-taken once the memory subsystem exists**; a comparable machine on the
same part at 82% is the strongest evidence available, and it points the other way.

*Method note worth keeping.* That project reached its number on the third attempt.
The first was arithmetic dressed as a finding; the second used a sweep script that
hardcoded `-GCEDIV=3` while the design shipped `ce_cpu(1'b1)`, so **every number it
had ever produced described a CPU getting one cycle in three**. Its own commit
calls it "third misleading instrument today". The same failure mode as R15 here,
in a different project, on the same day.

---

**R18 — the SDRAM geometry was inferred, not measured, and it cost a day.** P1.5's
tilemap rendered garbage for twelve hardware builds. The cause was a change I had
made myself and never suspected.

*What was believed:* that a 128 MB module on the MiSTer connector must be 4 banks
x 8192 rows x 2048 columns, because 13 address pins and 2 bank pins admit exactly
that and nothing else reaches 64M words. `COL_BITS` was set to 11 on that basis.

*What is now known:* it aliases on this board. With `COL_BITS = 9` — the value the
Model 1 core runs on the same hardware — the tile copy checksums come back
**exactly right** (`A66F51B7`, `5BFDD5AF`) and Daytona's attract screen renders
correctly.

*Why it took so long, and the lesson is about the evidence rather than the bug.*
Column aliasing is **invisible to a test that reads one address repeatedly** and
**fatal to a walk across many**. The SDRAM self-test reads four words at a single
address and passed on every build; the copy engine walks 36,864 addresses and
failed on every build. That pattern was visible from the start and read as a port
problem, a burst-length problem, a clock-domain problem, a byte-lane problem and a
capture-phase problem in turn. **Every one of those was code I had not changed. The
one thing I had changed was never on the list.**

*The simulation could not have caught it, and that is structural.*
`m2_sdram_harness` configures `sdram_model` with the **same `COL_BITS`** as the
controller, so the model and the controller agree with each other while both are
wrong about the part. 74,729 checks passed at `COL_BITS = 11`. This is exactly the
trap `docs/differential-testing.md` names: a reference written from the same
reading as the implementation catches a slip between the two and never a shared
misreading. **Geometry can only be settled on hardware**, and the blind spot is now
recorded in the harness itself.

*Consequences for the budget.* 32 MB does not hold the 43.62 MB ROM set (R13's
figure). **The next step is `COL_BITS = 10` for 64 MB**, which covers it and needs
only A0-A9 with A10 left as the auto-precharge flag — no A11, and therefore no
dependence on the inference that failed here. If 10 also aliases, the module is
32 MB-organised whatever its capacity, and the DDR3 split returns as a real P6
requirement rather than a contingency.


---

**R19 — the module's real geometry, measured: 1024 columns, 64 MB addressable.**
R18 established that the geometry had been inferred rather than measured. It has
now been measured, on hardware, by the only instrument that can settle it.

| `COL_BITS` | addressable | result on this board |
|---|---|---|
| 9 | 32 MB | **works** — tile copy exact, attract screen renders |
| **10** | **64 MB** | **works** — same, and this is the configuration to ship |
| 11 | 128 MB | **aliases** — corrupt copy, garbled picture |

**So the part presents 1024 columns, not 2048.** Ten column bits use the
contiguous A0-A9 range and leave A10 as the auto-precharge flag; eleven is the
first value that must drive a column bit on A11, and that is where it breaks.
Whatever the module's stated capacity, **64 MB is what this controller can address
through the MiSTer connector's 13 address and 2 bank pins.**

*Consequences, and they are all good:*

- **The 43.62 MB ROM set fits in 64 MB with 20 MB spare** (R13's figure). The
  trimmed MRA is no longer needed and the full set is addressable.
- **No DDR3 split.** `docs/rom-layout.md` sketched one when the ceiling looked like
  32 MB; it is not required. Every consumer gets uniform SDRAM latency and the
  renderer needs no DDR3 path or burst scheduling.
- **The board minimum stands at 64 MB**, not 128, and that is now a measurement
  rather than an inference. A 32 MB board cannot hold the set.

*The method note worth keeping.* R18's fault was reasoning from pin counts to
internal organisation. The correction was not better reasoning — it was walking
the parameter down one step at a time against a checksum over 36,864 real words,
which is the only test that distinguishes a working geometry from an aliasing one.
**A single-address test passes at every setting**, including the broken one.

---

**R20 — a sentinel that collides with a legal value is not a sentinel, and it
cost four wrong diagnoses.** `synmov` is the only instruction that writes `ICR`,
and `ICR` supplies the vector byte for all four IRQ lines, so nothing about
interrupts is reachable without it. Its lockstep divergence was:

```
MEMSTATE retire 22  6bc4a65c dut=deadfbcb ref=ffffffff  (insn 6004c006)
```

*What was believed.* That the module was at fault — it was the new code, and
`ref=ffffffff` reads as "the reference never wrote here", since unwritten memory
returns `0xFFFFFFFF` by the standing rule in `docs/mister-integration.md`. Four
successive hypotheses were spent on the module's bus timing, including a
`callx`-shaped latching fix that produced a **bit-identical** failure and should
have ended that line of enquiry on the spot.

*What is now known.* The reference **did** write, and what it wrote was
`0xFFFFFFFF`. `synmov` was the only memory operation in the reference reaching
`Regs::read`/`Regs::write` instead of the CPU's own `rd()`/`wr()`, and the two
differ in a way nothing else exposed:

| | aligns address | records in `stores` |
|---|---|---|
| `CpuRef::rd`/`wr` | yes, `a & ~3` | yes |
| `Regs::read`/`write` | **no** | **no** |

With an unaligned source address every lookup missed the map and returned the
unwritten sentinel, which was then written to the destination as data. **The
harness cannot distinguish a written `0xFFFFFFFF` from unwritten memory**, so the
symptom presented as the reference not executing the instruction at all.

*How it was established.* One decode of `6004c006` — `src2 = r19`, no literal
bit — against the two accessors' definitions. This is the same shape as R15: the
instrument was the suspect and was never checked, and reasoning about the
reference substituted for reading it.

*Two further faults found while fixing it, neither of which was failing anything:*

- **`ICR` was never compared.** The suite reported zero mismatches on `synmov`
  while the one path that matters was unchecked. The memory-to-memory case is
  covered by the per-retire memory sweep, but the ICR case writes **no memory by
  definition** — a module that dropped the write entirely was indistinguishable
  from one that performed it. Now compared, and mutation-tested both ways
  (corrupt the write, and drop it): each is caught at retire 2.
- **`ts & 15` had silently stopped covering the state field.** `ts` is five bits
  with eighteen states; the mask wrapped `T_SYNMOV_RD` (16) onto `T_FETCH` (0)
  and `T_SYNMOV_WR` (17) onto `T_FETCH_W` (1). The enum comment in
  `i960_top.sv` asserts that *appending* new states protects the prefetch
  invariant — that was true up to sixteen states and stopped being true at the
  seventeenth. **Appending was necessary and never sufficient.** While it was
  wrong the prefetch invariant ran during both `synmov` states, and the
  histogram booked 334 `synmov` cycles as "extra `T_FETCH` cycles" — a
  measurement, quoted in fetch statistics, that was describing the wrong state.

*The rule.* Coverage counters are now printed for `synmov` (284 executed, 50 of
them the ICR path) and the run warns if the ICR path never fired, because a green
suite that never executed the instruction is the failure this entry is about.

*Alignment.* `synmov` is an atomic word operation and the i960 requires both
operands word-aligned. MAME splits an unaligned `read_dword` across two words,
but that is its memory system rather than the silicon it models, so both sides
state the alignment rule independently and **nothing is claimed about unaligned
`synmov`**.

---

**R21 — MAME's take_interrupt does not clear the priority field, and that is
reproduced deliberately.** `i960.cpp` take_interrupt ends:

```c
m_PC &= ~0x1f00;    // clear priority, state, trace-fault pending, and trace enable
m_PC |= (lvl<<16);  // set CPU level to current IRQ level
m_PC |= 0x2002;     // set supervisor mode & interrupt flag
```

The CPU priority is `(m_PC >> 16) & 0x1f` — bits 16 to 20. `0x1f00` is bits 8 to
12. **The mask does not touch the field the comment names**, so the new level is
OR-ed into a field that was never cleared and the priority accumulates bits
across nested interrupts.

*This is reproduced exactly, in both the module and the reference.* Rule 1 of the
project's order of authority is that the reference source wins, and the games
were validated against this behaviour — Daytona's handlers ran on a CPU that
accumulated priority bits, and any code that depends on the resulting eligibility
pattern depends on this. Substituting `0x1f0000` because it looks like what was
meant is a silent behavioural change to the one register that decides which
interrupts are allowed to fire.

**It is mutation-tested in that direction**: changing the mask to `0x1f0000`
fails lockstep. So the quirk is not merely reproduced, it is *observed* — if a
future change "corrects" it, the suite says so.

*What is not established.* Whether silicon behaves this way. Nothing here
distinguishes "the i960 does this" from "MAME has a typo that the games happen
not to expose". If a real board ever contradicts it, this entry is where to
start, and the change is one mask in two files.

---

**R22 — two whole classes of instrument fault, found by making interrupts work.**
Neither was a design error; both were checks that could not see what they claimed
to check, and both had already produced wrong diagnoses.

*Class 1: an accessor that does not align, and R20's fix that did not reach it.*
R20 traced a synmov divergence to `Regs::read`/`Regs::write` — which look up
`mem[a]` raw where the CPU reference's `rd()`/`wr()` mask with `~3`. R20 fixed
**the call site**: synmov was switched to `rd`/`wr`. The accessor was left as it
was, and the second instance surfaced immediately in the interrupt work:

```
MISMATCH retire 94  PC   got=00000100 want=ffffffff  (insn 0a000000)
```

A type-7 `ret` reads the saved PC from `FP-16`. The generator can write `r31`
as an ordinary register, so `FP` was `0x1f`; `FP-16` is `0x0f`; the module's bus
drops the low two bits and fetched `mem[0x0c]`, while `Regs::read` missed the map
and returned the unwritten sentinel. **The same fault, the same symptom, the same
misreading available.** The accessors now align, which is where R20 should have
fixed it. *Fix the accessor, not the caller.*

*Class 2: "the IP changed" is not a retire detector.* The lockstep harness closed
each comparison window on the IP moving. That is sound only while every
instruction moves the IP by a fixed amount and nothing else moves it. Interrupts
break it three separate ways, and each one presented as a different bug in
`take_interrupt`:

| what happened | how it looked |
|---|---|
| an interrupt moves IP without retiring anything | reference one instruction behind; RIP 4 too high |
| a handler address equals the IP the window opened at | window ran on into the handler — two instructions against one |
| a type-7 frame makes `ret` return to its own address | the `ret` executed twice, desynchronising the register-cache depth |

The third is the worst: it surfaced **fifteen retires later** as a frame reloaded
from memory while the reference reloaded from cache, with nothing pointing at the
`ret`. The module now exports an instruction-acceptance counter and the window
closes on that — one unambiguous event, one instruction, no inference.

*Also found while fixing these, none of which was failing anything:*

- **`ICR` was never compared** (R20), and **`PC` was never compared at all.** PC
  is the register that says whether an interrupt entry and a type-7 return
  actually happened; the entry rewrites its priority field and flags and the
  return restores the whole word. Both are compared now.
- **The interrupt lines were not cleared before reset.** `irq_prev` resets to 0
  while the pin still held the previous program's value, so releasing reset
  captured a rising edge the reference never saw and the module took an interrupt
  at retire 0 of a program the reference knew nothing about.
- **Edge ordering.** The module scans `irq_edge` from bit 0 up; the harness fed
  the reference in the order the generator drew the lines. Whenever the second
  line drawn was the lower one the two disagreed about which interrupt got the
  single immediate slot.
- **Edge timing.** The harness told the reference about an edge *before* the
  instruction; the module acts on it at the boundary *after*. Identical for every
  instruction except the one that matters — `synmov` to `0xff000004` IS the write
  to ICR, so a line whose vector was 0 (IAC mode, dropped) before it becomes a
  live priority-31 vector after it.

*Coverage, and a mutation that survived.* At the default program length a whole
run produced **four** dequeues, and a mutation reversing the priority scan in
`check_pending_irqs` **passed**. The path ran; it never ran with enough levels
pending for the direction to matter. `make test_i960_top_irq` is a separate
invocation at `+steps=400` with `+strictcov`, which turns zero coverage on any
interrupt path into a failure. It reaches 88 dequeues and kills that mutation.

It is a separate invocation on purpose: `steps` is the program length, so raising
it on the default run would change the working set, the I-cache hit rate and
therefore **the measured CPI that R16 rests on**.

---

**R23 — the interrupt controller costs 828 ALM, and it is measured, not
estimated.** Quartus 17.0, `5CSEBA6U23I7`, map + fit + sta:

| | before interrupts | with interrupts | delta |
|---|---|---|---|
| ALM | 6,979 | **7,807** | **+828** |
| registers | 4,212 | 4,872 | +660 |
| M10K | 1 | 1 | 0 |
| DSP | 7 | 7 | 0 |
| Fmax | 26.84 MHz | **26.4 MHz** | **-0.44** |

*What it bought:* the four external lines with edge detection, the ICR vector
lookup, the immediate slot, the queue into the interrupt table, the priority
scan that dequeues, `take_interrupt` with its nested-stack test and three process
saves, and the type-7 return that restores PC and AC. §5.2's pessimistic column
had budgeted interrupts inside its 9,500 estimate; **the measured total is still
below it.**

*Effect on the fit question.* The budget is i960 + renderer under ~25,000 ALM.
The i960 side is now **7,807 measured**, leaving **~17,200 for the renderer**.
§5.2's own pessimistic i960 figure was 13,500, so the CPU has come in materially
under its own worst case and the renderer's room is wider than the study
assumed, not narrower.

*Fmax is the number to watch, not ALM.* 26.4 MHz still clears the real part's
~25 MHz, but the margin has gone from 1.84 MHz to 1.4 MHz and this is the second
change in a row to take some. **The remaining i960 work — faults, `calls`,
transcendentals — has to be measured for Fmax as well as area**, and if the
margin reaches zero the answer is a pipeline stage in the aux-bus path, not a
retreat from correctness. Do not accept an Fmax figure from a fit-only rerun;
`quartus_map` must run too, per the build rules.

---

**R24 — `modpc`, and why the interrupt path was unreachable without it.** MAME
`i960.cpp` 0x65.5:

```c
t1 = m_PC;  t2 = get_2_ri(opcode);
m_PC = (m_PC & ~t2) | (m_r[(opcode>>19) & 0x1f] & t2);
set_ri(opcode, t1);
if ((t1 >> 16 & 0x1f) > (m_PC >> 16 & 0x1f)) check_pending_irqs();
```

**This is the only instruction that lowers the CPU priority.** PC resets to
`0x001f2002` — priority 31 — and the eligibility test
`((cpu_pri < priority) || (priority == 31))` then admits *only* priority-31
interrupts. Everything else queues and is never dequeued. So R22's controller,
complete and verified, would have been dead code on real hardware: a game opens
itself to its raster and TGP interrupts by calling `modpc`, and nothing else does.

The harness had been papering over this by **seeding PC with a random priority
per program**, which was the right call to get the controller tested but is not a
substitute for the instruction.

*Two implementation notes worth keeping.*

- **`srcdst` is read as a source and then written with the old PC**, which no
  other REG-format instruction does — the read port presents `src1` there. It
  costs one extra sequencer state (`T_MODPC`) to present `ra1 = srcdst` a cycle
  early. A mutation pointing that read at `src1` is caught.
- **The dequeue check is on a DECREASE, not a change.** Reproduced exactly, and
  the distinction is real rather than pedantic: level 31 is eligible regardless
  of CPU priority, so a `modpc` that RAISES the priority would still release a
  queued level-31 interrupt if the test were `!=`.

*That mutation initially SURVIVED*, and fixing the test rather than accepting it
is the point. Priority-31 vectors are 8 of 256 random ICR bytes — about 3% — and
a queued level 31 additionally needs the immediate slot already occupied. The
harness now biases ICR bytes toward 248-255 and drives paired edges in one
window. With that, the mutation dies.

*Effect on coverage, which is the other reason this matters:* enabling `modpc`
took the default run from **4 dequeues to 52**, and the soak to 106. It is the
realistic mechanism by which a queued interrupt is released, and until it existed
the dequeue path was being reached only by accident.

*One harness artifact found alongside.* The prefetch invariant fired on a
recorded deviation. A store into the program image makes the module's I-cache and
the cacheless reference disagree, and **both are correct** — the SMC check
abandons the program, but it runs at the end of the window and an interrupt can
redirect into the just-overwritten program *within the same window*. The
invariant is now gated on the program image being clean. Same class as the rest
of R22: the instrument, not the design.

---

**R25 — the i960 runs Daytona's real boot code, matching MAME instruction for
instruction.** P1's third exit criterion, and the first test here whose input
this project did not write.

`make test_i960_rom` loads the real `daytona93` program ROM and runs it through
`i960_top`; `tools/i960-diff.sh` compares the resulting program-counter stream
against MAME's, uncollapsed.

**803,355 instructions, identical, zero divergences.** The core boots from the
ROM's own boot record, clears RAM, programs its wait states, reinitialises
itself through the IAC port, writes 12,292 words of tilemap, 16 palette entries
and 64 texture/luma words, and ends in the same DPRAM poll loop MAME reaches.

**It programs `ICR` to `0x0f0e0d0c` and enables the V-blank interrupt.** The
interrupt controller of R22 and the `modpc` of R24 are not speculative
infrastructure — the game configures them directly, and the run confirms the
vector bytes land where the eligibility test reads them.

*Four defects this found that nothing else could have.* Every one was reached
only by real code, after tens of thousands of instructions, and every one had
passed a green lockstep suite:

| defect | where it surfaced |
|---|---|
| `bx` and `balx` not implemented at all | 32,878 instructions in, immediately after the RAM clear |
| `synmovq` and the whole IAC port missing | 33,197 in — Daytona reinitialises through IAC 0x93 |
| `main_data` ROM not modelled | boot copies code out of it into RAM and jumps there |
| the memory map taken from the wrong board variant | 521,748 in, trapping on opcode 0x00 |

The last is the one worth keeping. **daytona93 is `model2o`, the ORIGINAL Model 2
board, not the 2A-CRX this study targets**, and the two differ exactly here:

```
model2o:    map(0x00200000, 0x0021ffff).ram()                             // 128 KB
            map(0x00220000, 0x0023ffff).rom().region("maincpu", 0x20000)  // ROM MIRROR
model2a:    map(0x00200000, 0x0023ffff).ram()                             // 256 KB
```

Treating the upper half as RAM read zero where the boot code calls `0x00227cf0`.
The symptom — a trap on opcode `0x00` half a million instructions in — points at
the decoder and is a memory map copied from the wrong variant. **When the ROM set
and the board variant disagree, the ROM set wins**; the core must eventually
carry both maps, selected per game.

*What this does NOT establish.* Program counters only. Two runs can agree on
every PC and disagree on every value — a store to the wrong address surfaces only
when the PC stream finally reacts to it, which may be never. **Write-stream
comparison is the next instrument**, and `docs/differential-testing.md` describes
it. Do not read "803,355 identical" as "the data path is verified".

*And the generator caught up afterwards, which is the discipline that matters.*
`bx`, `balx` and `synmovq` are now generated in lockstep too, so they are held by
both instruments rather than only by the ROM run. Getting there needed two fixes
to the harness, both the R20 sentinel collision again:

- `synmovq` with random register pointers copies **unwritten memory to unwritten
  memory**, so every word moved is `0xFFFFFFFF` and a mutation copying three
  words instead of four is invisible. It now uses seeded pointers into a data
  window filled with per-address values.
- The IAC message had to be seeded into **both** memory maps; `ref.rf.mem = mem`
  is a copy taken earlier, and seeding only the harness's map diverged at the
  message address itself.


---

**R26 — the data matches too, byte for byte, and that closes the CPU side of the
2D path.** R25 compared program counters and said explicitly what it did not
establish: two runs can agree on every instruction and disagree on every store,
because a wrong store changes the PC stream only if the program reads it back
and branches on it, which it may never do.

`tools/i960-datadiff.sh` runs the real `daytona93` ROM through our i960 and
through MAME to the **same instruction address** — `0x228240`, the DPRAM poll
loop the boot enters once it has finished writing — and compares the three
regions the 2D path reads:

| region | size | result |
|---|---|---|
| tile RAM `0x01000000` | 65,536 bytes | **identical** |
| char RAM `0x01080000` | 524,288 bytes | **identical** |
| palette `0x01800000` | 16,384 bytes | **identical** |

**606,208 bytes, zero differing.**

*And that number is weaker than it looks — recorded here rather than left to be
quoted.* At the poll loop the boot has not drawn anything yet: tile RAM and char
RAM are **entirely zero on both sides**, and only 52 bytes of the palette are
non-zero. So this establishes that the two agree, and that we write zeros where
MAME writes zeros — it does **not** establish that a tilemap with content would
match.

**Both sides stall in the same place, which is why.** Daytona's boot polls
`0x01c00040` for the sound board; MAME loops there 140,803 times in 50 ms and
never leaves, and our harness has no sound board at all. Getting a content-rich
comparison out of this instrument needs the sound handshake modelled. **What
closed the gap instead was R27**, which compares rendered pixels from a
frame-2300 capture where the tilemap is full.

*Why an instruction address and not a frame number.* `mame_m2_tiledump.lua` syncs
on a frame, which is right when there is no CPU on our side and the state is
being supplied. Here both sides execute and they do **not** keep the same
wall-clock: our harness has no sound board, so it sits in the DPRAM poll loop
that MAME walks straight through. Comparing at "frame 2" compares two different
moments and reports a difference that is a scheduling artifact. An instruction
address means the same thing on both sides.

*What this closes, and what it does not.* The CPU-side content of the 2D path is
verified end to end: real ROM in, correct pixel-source data out. It says nothing
about the renderer that consumes it — `m2_video` is verified separately against
canned MAME state — and nothing about the 3D path, which has no oracle at all
(§2.1). **The remaining 2D risk is now in the wiring, not in either end.**


---

**R27 — the palette was Model 1's, and every fill colour in every game was
wrong.** Found by rendering a frame and comparing it against MAME pixel by pixel,
which is a thing this project had never done: P1.5's exit criterion 4 ("the
rendered frame matches MAME's screenshot") was judged on hardware, by eye.

`rtl/video/m2_palette.sv` was `m1_palette.sv` copied across. It did `pal5bit` —
`(x << 3) | (x >> 2)` — plus a bit-15 intensity/shade halving, and carried a
comment citing MAME as the source for the intensity bit. **That citation does not
describe Model 2.** `model2.cpp palette_w`:

```c
u8 r = m_colorxlat[(0x0080 >> 1) + (((palcolor >> 0) & 0x1f) << 8)];
u8 g = m_colorxlat[(0x4080 >> 1) + (((palcolor >> 5) & 0x1f) << 8)];
u8 b = m_colorxlat[(0x8080 >> 1) + (((palcolor >> 10) & 0x1f) << 8)];
r = m_gamma_table[r]; g = m_gamma_table[g]; b = m_gamma_table[b];
```

Each 5-bit channel indexes a **colour translation RAM the game programs** at
`0x01810000`, and the result goes through a gamma curve. **Bit 15 is not read at
all.**

*Measured against Daytona's real table, dumped from MAME:*

| 5-bit | colorxlat | gamma | `pal5bit` (what we had) |
|---|---|---|---|
| 2 | 81 | **22** | 16 |
| 9 | 123 | **78** | 74 |
| 23 | 207 | **190** | 189 |
| 31 | 255 | **255** | 255 |

**Only the endpoints agreed.** That is exactly why it survived being looked at on
hardware: the picture is right, every fill is a few units off, and nothing about
that is visible without a pixel comparison. In the diff mask it showed up as
glyph **outlines** matching and their **fills** not — a shape that says "colour",
not "layout", and is worth recognising on sight.

*The table costs 96 bytes, not 48 KB.* It is indexed at a stride of 256 words, so
only 32 entries per channel are ever read out of 24,576.

*The gamma is MAME's, not the hardware's,* and its own comment says so — "this
works OK for most games / real cabinets probably have their monitors calibrated
depending on the game". It is applied by default because matching the oracle is
what makes a pixel comparison mean anything, and it is a **parameter** so a
hardware A/B can turn it off without an edit. `255/191` in 16.16 is 87,496, which
reproduces MAME's table at every point including 255, where a coarser multiplier
gives 254.

*Result.* Matching pixels went from 15,795 to **34,664 of 190,464**, and the
residual is now exactly the 3D scene MAME composites and we do not render — the
2D glyphs are solid in the mask. A whole-frame match is not available until P2
exists, so `tools/m2-framediff.sh` holds a floor rather than demanding 100%.

*Deliberately NOT changed on hardware tonight.* The table **powers up holding
`pal5bit`**, so a core that has not loaded it renders exactly as the board does
today. Wiring the loader needs the copy engine extended and the MRA regenerated
to carry `colorxlat.bin`, and that could not be tested — the device is off. The
simulation is what makes that change safe to make later, which is the right order.

*The provenance lesson, and it is the same one as R22.* The module was lifted
from a core measuring the same family of hardware, and the ONE thing that
differed was the thing nobody re-checked. **A ported module's comments are
evidence about the core it came from, not about this one.**


---

**R28 — the 2D renderer is bit-exact against MAME over a whole frame.** P1.5's
exit criterion 4 is now met as an assertion rather than an impression.

`tools/m2-framediff.sh` renders a frame with `m2_video` from MAME's own tilemap
capture and compares every pixel with MAME's screen:

| frames | content | result |
|---|---|---|
| 30, 45, 60, 75, 90, 105, 120, 135, 150, 165 | settings screen, tilemap only | **190,464 / 190,464 identical — 100%, every one** |
| 180 and later | attract, with the 3D scene composited | 16-19%, residual is exactly the polygon scene |

**Ten consecutive tilemap-only frames, every pixel, no exceptions.**

**The default is frame 120 and it demands 100%, not a floor.** Daytona's settings
screen is tilemap only — no polygons anywhere on it — so an exact whole-frame
match is both possible and required, and anything less is a defect. Later frames
composite a 3D image we do not render at all, so they can only be held to a
floor; that mode still exists and is what `M2_MATCH_FLOOR` selects.

*It is sensitive to one bit.* Perturbing a single colour-translation entry by 1
fails the test with 2,054 differing pixels — every non-black pixel on the screen.
That is what makes it worth having: R27's fault was a few units per channel and
survived being looked at on hardware indefinitely.

*What is now established for the 2D path, end to end:*

1. The i960 executes Daytona's real boot code identically to MAME (R25).
2. The tile, char and palette data it produces are byte-identical (R26, with its
   stated limits).
3. The renderer turns that data into **pixels identical to MAME** (this entry).

**The remaining 2D risk is the wiring, not either end** — `i960_top` is still not
instantiated in `Model2.sv`, and the colour translation table is not yet loaded
on hardware. Both are integration, and both now have a verified specification to
be integrated against.


---

**R29 — the i960 is in the core, and it fits with room to spare.** Quartus 17.0,
full compile, 0 errors, timing closed.

| | without the CPU | with it | device |
|---|---|---|---|
| ALM | 9,004 | **17,162** | 41,910 (41%) |
| M10K | 164 | **237** | 553 (43%) |
| DSP | 36 | **43** | 112 (38%) |

*Slack, all positive:* `clk_i960` **+6.191 ns**, `clk_sdram` +10.627,
`clk_vid` +14.780. The CPU's 25 MHz has the least margin, as expected from R23's
26.4 MHz — but 6.19 ns of a 40 ns period is comfortable, not marginal.

**The fit question now has both halves of its numerator measured for the first
time.** 17,162 ALM is the whole core with CPU, tilemap, SDRAM and the MiSTer
framework, against a ~25,000 budget that was only ever about the CPU plus the
renderer. **24,748 ALM remain on the device.**

*Two faults found by building it, both structural:*

- **Three `always_ff` blocks touching one array kills RAM inference.** Adding the
  CPU's port to tile RAM made it a third accessor — renderer on `clk_vid`, copy
  engine and CPU on `clk_sdram` — and Quartus reported "cannot convert all sets
  of registers into RAM megafunctions". 512 Kbit of tile RAM became flip-flops,
  four times the whole device. The copy engine and the CPU are now muxed onto
  one port, so the array has exactly two. **M10K is dual-port; a third accessor
  is not a tight fit, it is a different thing entirely.**
- **The `.qsf` file list had no trailing newline**, so an append keyed on the
  last line silently did nothing and synthesis reported the CPU as an undefined
  entity. The count printed afterwards said 13 where 30 was expected, which is
  what an edit that did not apply looks like.

*Two modes, decided by the image rather than by the user.* The loader's highest
written address separates them: under 1 MB is the tilemap test — copy engine
runs, **CPU held in reset**, behaviour identical to what is on the board today —
and above it is the game, where the copy engine is skipped because its bases now
point at the program ROM.

*What this does NOT do.* **The game will not draw yet.** R25's boot stalls in the
sound-board handshake, and on hardware there is no sound board and no capture to
replay: it will clear RAM, reinitialise through IAC, and sit there. The
simulation path gets past it only because `+dpram` replays bytes recorded from
MAME. Baking that capture into the game image is the obvious next step and is not
done. **Nothing here has been tested on hardware.**


---

**R30 — `req && ack` is the rule for the numbered ports and NOT for the loader's
write port, and assuming otherwise put program ROM on the screen.** First
hardware run of the core with the i960 in it: Daytona rendered as scrolling
colour noise with the overlay intact.

The overlay said what it was, once read rather than glanced at:

```
word4 = 00000087   PLL locked, SDRAM ready, ROM loaded, no overflow, self-test OK
word5 = C3E101F3   tile RAM copy checksum
word6 = 0D3D0CAF   palette copy checksum
```

**Those checksums should have been zero.** The copy engine is meant to be
skipped for a game image; a non-zero checksum means it ran, and what it copied
was the i960's program ROM into tile RAM. The renderer then drew executable code
as tiles, which is exactly what colour noise is.

*The cause.* The mode is chosen by the highest address the loader wrote:

```systemverilog
else if (ldr_wr_req && ldr_wr_ack && (ldr_wr_addr > ldr_top)) ldr_top <= ldr_wr_addr;
```

`m2_rom_loader` **pulses** its request and drops it before the answer arrives —
its own comment says "req pulsed so the controller sees a rising edge" — and
then waits for the ACK EDGE. So `req && ack` is never simultaneously true,
`ldr_top` stayed at zero, `game_image` was permanently false, and the copy engine
ran on all 43.62 MB.

*Why this is worth an entry rather than a one-line fix.* `docs/mister-integration.md`
says **one access is `req & ack`, not one cycle of `req`**, and
`m2_cpu_bridge`'s own header repeats it — that rule was written down, quoted in
the module I had just built, and still applied to the wrong interface. **It is
the rule for the NUMBERED PORTS.** The dedicated write port is a different
protocol: pulse the request, watch for the acknowledge edge. Two handshakes on
one controller, and the difference is documented only inside the loader.

The address is presented with the request, so sampling on `req` alone is correct
and does not depend on when the controller answers.

*What it cost, and what it did not.* One build. It cost nothing else because the
overlay carried the copy checksums — a diagnostic added for a different fault
entirely, months of work earlier, that named this one on sight. **The screen is
the only output channel, and a number on it is worth more than a theory.**

*A note on what the fix does not fix.* With the mode detected correctly the game
still will not draw: it stalls in the sound-board handshake (R25), so the
expected result is a BLACK screen with a CPU that is executing. The overlay has
been repointed at the loader's highest address and at the CPU's instruction
count and IP, so "executing and stalled" can be told apart from "not running",
which the copy checksums could not.


---

**R31 — the SDRAM self-test was writing its patterns over the boot record, and
had been all along.** Second hardware run with the CPU in the core. The mode
detection from R30 now works — the overlay shows `game_image` set and the loader
reaching 22.8 M words — and the screen is black with the CPU **trapped after one
instruction** at `IP = AA55AA55`.

`AA55AA55` is not an address. It is `STP0`, the first pattern the SDRAM
self-test writes.

*The arithmetic.* `SDR_AW = 2 + 13 + COL_BITS`, which with the measured
`COL_BITS = 10` (R19) is **25 bits** — exactly 0x2000000 words, exactly 64 MB,
last valid word 0x1FFFFFF. The self-test's base was:

```systemverilog
localparam logic [SDR_AW:1] ST_BASE = SDR_AW'(32'h2000000);   // 64 MB mark
```

**One past the end.** `SDR_AW'()` truncated it to **zero**, so the four patterns
landed at word addresses 0 to 3 — byte addresses 0 to 7 — which is
`SAT` at 0 and `PRCB` at 4. The i960 read its startup state out of a memory test
pattern, jumped to it and trapped.

*Why it survived this long.* **Nothing had ever executed from SDRAM.** Every
earlier use read tile RAM, the palette and character data from addresses far
above zero, so a corrupted first eight bytes was invisible — and the self-test
reported `st_ok` because it verified its own patterns at the address it had
actually written. **A test that checks the place it wrote is not checking the
place it meant to write.**

*The class, and it is the third address-arithmetic fault in this project.* R18
inferred SDRAM geometry from pin counts; R25 took a memory map from the wrong
board variant; this one lets an out-of-range constant wrap silently. **An address
that does not fit is not an error in Verilog, it is a wrap** — and a wrap to zero
lands on the one structure the CPU cannot boot without.

There is now an elaboration-time `$error` on both `ST_BASE` and the top of the
game map against `1 << SDR_AW`, so the next one fails the build rather than the
board. The stale `// 26` comment on `SDR_AW` — left from when `COL_BITS` was 11 —
is corrected; it is what made the value look right on inspection.


---

**R32 — the bridge sampled an acknowledge that was still held from the previous
access, and the testbench could not see it because the model was easier than the
controller.** Third hardware run. R31's fix worked — the CPU now reads a real
boot record — and the overlay showed:

```
word5 = 00000002   two instructions accepted
word6 = 00600860   the IP
```

The ROM holds `0x00000860` at byte 12. **The low half is right and the high half
is not**, which is a much sharper statement than "it crashed".

*The cause.* `m2_sdram` holds `p_ack` for `ACK_HOLD` cycles — 2, by its own
parameter, "so requesters on a slower synchronous clock see exactly one rising
edge with ack high". `m2_cpu_bridge` runs on the **same** clock as the
controller, and it issued the second 16-bit half in the same cycle it captured
the first, while that ack was still asserted. It then sampled the still-held ack
and captured the **first word again**.

A 32-bit read therefore returned its low half in both halves.

*Why the testbench passed it.* The SDRAM model in `tb_m2_cpu_bridge.cpp` acked
for **one** cycle. **A model that is easier than the thing it models does not
test the thing it models** — and this one was written by the same person, on the
same day, as the bridge that assumed the same thing. Correcting the model to hold
ack for two cycles reproduces the fault immediately: `got=100d100d`,
`want=0000100d`.

*On mutation testing, and a correction worth keeping.* Three mutations removing
the new waits all **SURVIVED**, which briefly looked like the fix being
unnecessary. They were not faithful to the bug: each issued the second half one
cycle later than the original did, and a two-cycle hold tolerates that. The
faithful mutation — reinstate the issue in the same cycle as the capture — is
caught, `got=beefbeef want=deadbeef`.

**A mutation that is milder than the defect proves nothing about the defect.**
Only the `S_LO_W` wait is established as necessary; the `S_HI_W` wait and the
`S_IDLE` ack guard are defensive and are labelled as such in the source rather
than presented as verified.

*The pattern across R30, R31 and R32.* All three are the same shape: an
interface's actual behaviour differing from the behaviour assumed by the code
that drives it — a pulsed request read as a level, an address one past the end
read as in range, an acknowledge held for two cycles read as one. **None was
visible in simulation, and all three were named by the overlay on the first
frame.**


---

**R33 — a single-word read auto-precharges on its first command, and the CPU was
the only port doing single-word reads.** The overlay split the problem in one
reading:

```
row 2  = 00000860   the SAME words, read through PORT 1
row 10 = 00000004   the address port 0 last asked for
row 11 = 00000000   what port 0 got back
```

**The ROM is in SDRAM and port 1 reads it correctly.** Port 0 asks for plausible
addresses and receives zero. That eliminated the loader, the MRA layout, the
memory map and the decoder in a single frame.

*The mechanism.* `m2_sdram`'s `S_RD` asserts A10 — auto-precharge — on the
**last** word of a burst. For a single-word read the first word **is** the last,
so the row closes about `tRCD + 1` cycles after it was activated, inside `tRAS`.
A behavioural model tolerates that; a device need not. Ports 1 to 3 burst four
and issue the precharge on the fourth, clear of it.

That is exactly the asymmetry the board showed: **the copy engine on port 2 and
the character fetch on port 3 read correctly while the CPU on port 0 read zero
from the same SDRAM, at every capture depth the OSD offers.**

*The fix removes the case rather than tuning it.* `blen()` now gives port 0 four
words like the others, and since `p_dout` is 64 bits the CPU's 32-bit access
takes **one** transaction instead of two — which also deletes the held-ack
hazard of R32 rather than working around it.

*Three testbenches, three models of the same controller, three drifts.* This is
the through-line of R32 and R33 and it is worth stating once:

| model | said | controller says |
|---|---|---|
| `tb_m2_cpu_bridge.cpp` | ack lasts 1 cycle | `ACK_HOLD` = 2 |
| `tb_m2_cpu_bridge.cpp` | port 0 returns 1 word | now 4 |
| `tb_m2_sdram.cpp` | port 3 returns 1 word | `blen()` says 4 |
| `m2_sdram_harness.sv` | `rd_lat_sel` = 3 | the core ships 0 |

**Every one of these was written by the same hand as the code it tests, and each
agreed with that code rather than with the device.** A hand-written model of a
block is a second opinion from the same source. The composition test —
`make test_m2_cpu_sdram`, real bridge against real controller — exists because of
this and reproduced the hardware symptom on its first run.

*What is still open.* The model needs `rd_lat_sel = 3` where the board works at
0, and changing the OSD setting on hardware does not help. **That disagreement
is unexplained**, and it means the simulation cannot be trusted to choose the
capture depth. It is recorded rather than reasoned away.


---

**R34 — the i960 holds its request across a run of accesses and moves the address
ON THE ACKNOWLEDGE, and the bridge sampled the address in the cycle it was
answering.** Every read came out one behind.

The overlay isolated it to the byte:

```
row 2 = 00000860   the readback's word 6
row 8 = 00000860   the BRIDGE's word 6      -- its data path is fine
row 9 = EEEEEEEE   the BRIDGE's word 2      -- never requested at all
```

**Reading the right place correctly and never asking for the other place** is a
different fault from a bad read, and the two probes are what separated them.
Everything else had already been eliminated: rows 2, 9 and 10 cleared the loader,
the MRA layout, the memory map and the decoder, and swapping the CPU onto port 1
cleared the arbiter.

*The cause.* `i960_top`'s boot walk never drops `boot_req`:

```systemverilog
T_BOOT: if (boot_ack) begin
  case (boot_step)
    2'd0: begin sat_reg  <= bus_rdata; boot_addr <= 32'd4;  ... end
    2'd1: begin prcb_reg <= bus_rdata; boot_addr <= 32'd12; ... end
```

The request is held high for all three reads and the address moves **on the
acknowledge**, so in the cycle `bus_ack` is asserted `bus_addr` is still the
address just serviced. The bridge started the next access there, sampled the
stale address, and read `mem[0]` twice: `SAT` was right by luck, `PRCB` came back
zero, and the boot took a zero IP.

*The fix is an explicit four-phase handshake* — req-up, ack-up, req-down,
**ack-down** — because "a request is present" is true continuously and cannot
separate one access from the next. Only the acknowledge can. Condition-by-
condition patches to the old form kept racing; the state machine does not.

*Two testbench faults found on the way, and the second is the more embarrassing:*

- **The testbench never held the request.** `access()` drops `bus_req` after every
  acknowledge, so the pattern that shipped had no coverage. The i960's actual
  boot walk is now a test, and reinstating the old handshake fails it in exactly
  the hardware shape: read one fetches word 0 again, read two fetches word 2,
  and word 6 is never requested.
- **`bus_ack` was sampled per TICK rather than per edge.** It is asserted for a
  whole CPU clock, which is eight simulation ticks, so one acknowledge counted as
  eight and three reads appeared to complete on three consecutive ticks with no
  memory traffic at all. That looked exactly like the bridge answering from
  nowhere and sent this investigation after a deadlock that did not exist.
  `access()` hid it by breaking out on the first acknowledge.

**Five models of this system have now been gentler than the thing they model**
(R32, R33 and these two). Every one was written by the same hand as the code it
tests. That is the single most expensive pattern in this project's history and it
is worth more than any individual fix recorded here.


---

**R35 — the Jaguar core rejected DDR3 for latency, and our tile RAM is
duplicated in M10K.** Two findings, one from outside and one from our own fit
report.

*What the Jaguar core does (MiSTer-devel/Jaguar_MiSTer).* It is the closest
comparable: a machine whose object processor and blitter want more memory
bandwidth than one SDRAM gives.

- **"The core is now using SDRAM for cart loading and for main RAM as well as
  BIOSes and memtrack save data. So SDRAM is _required_."** DDR3 is not used.
- **DDR3 was tried and abandoned on LATENCY, not capacity.** The reported
  failure is that games "exhibit lines across the screen, probably because it's
  unable to fill the line buffers quickly enough from DDR". Its README still
  lists "Maybe caching with DDR" as an open idea rather than a solution.
- **Dual SDRAM is its bandwidth answer:** "All known games now appear to work
  correctly with dual ram builds. For single ram builds all boot, some with
  glitches or slow down".

*Why this matters here.* `docs/rom-layout.md` sketched a DDR3 split when the
SDRAM ceiling looked like 32 MB, and R19 removed the need by measuring 64 MB.
**This is independent evidence that the split would have been a mistake even if
it had been necessary**: our character fetch is a line-buffer fill, per line,
which is precisely the access pattern that broke the Jaguar core on DDR. If P2's
texture bandwidth ever exceeds one SDRAM, **dual SDRAM is the proven lever and
DDR3 is not.**

*And our own number, which is worse than it looks.* The fit reports **237 M10K
blocks (43%) for 1.65 Mbit (29%)** — block count is the constraint, not capacity.
The reason is in the report:

```
altsyncram:tram_rtl_0   bits=524288   M10K=64
altsyncram:tram_rtl_1   bits=524288   M10K=64
```

**Tile RAM is stored TWICE.** 512 Kbit needs 51 blocks ideally and takes 128,
because the array now has three accesses — the renderer reading on `clk_vid`, and
the CPU reading *and* writing on `clk_sdram` — and M10K is dual-port. Quartus
duplicated the whole array to provide the third port.

**Adding the CPU's read port to tile RAM cost 64 blocks, 12% of the device**, for
an access games make far less often than they write. Recovering it is a design
question for the renderer budget rather than a bug: P2 wants colour and Z
double-buffered on chip (§6) plus a 32 KB texture cache, which is roughly 160-200
blocks against the 316 now free.

*The general rule, which the M10K-versus-bits gap states plainly:* **on this part
an array's cost is set by its port count and shape, not by its size.** A third
accessor does not cost a little more, it costs another copy.


---

**R36 — the sound board is two bytes, not a 68000.** The i960 runs Daytona on
hardware and parks in the sound-board poll (R34 got it that far). The board is a
separate 68000 behind a dual-port RAM at `0x01c00000` and the boot will not go
past it.

*What was tried first, and why it was worse.* A 4 KB capture of MAME's DPRAM,
taken at the moment its own boot cleared the handshake, replayed into the read
path. It works — but the settings screen it produces shows **garbage values**
(`55CREDIT(S)`, `#56`), because **a recording answers questions from a moment
that is not this one.**

*What is actually needed:* two bytes.

```
byte 0 of 0x01c00040 = 0x00     no command outstanding
byte 2 of 0x01c00042 = 0x40     the status the boot waits for
```

Both live in the **same 32-bit word** — the DPRAM is eight bits wide at bytes 0
and 2, `.umask32(0x00ff00ff)` — so the answer is the constant `0x00400000`.

With that, the boot proceeds exactly as with the full capture: 62,392 words of
character data, its own colour translation table, 79 V-blank interrupts, a
tilemap with content — **and the settings screen renders with sensible values**,
`USA / DELUXE / EASY / 0 CREDIT(S) / #1`, where the recording gave nonsense.

**The smaller stub is the more correct one.** That is worth stating on its own:
replaying captured state looked like the higher-fidelity option and was not,
because the capture carries a moment's worth of context that no longer applies.

*Why it lives in the core and not in the ROM image.* These two bytes are a
handshake status, not game content, so nothing ROM-derived enters the build. The
alternative — appending the capture to the MRA — also ran into an unresolved
problem: **the loader's high-water mark on hardware is `0x015CFFFF`, 256 KB short
of the MRA's own end**, with no overflow reported. Anything appended to the tail
of that image might not arrive. That discrepancy is recorded and NOT explained;
it does not affect the boot, which lives in the first 64 KB, but it will matter
for texture data and should be settled before P2.

*What this is not.* It gets Daytona to its settings screen. It will not survive
attract mode or gameplay, and it is not a substitute for the sound board.


---

**R37 — the sound handshake is a protocol, not a value, and the stub matched
only half of it.** Two findings from finally tracing it instead of sweeping
constants at it.

*The stub was broken on hardware.* The core answered

```systemverilog
(cpu_io_addr[23:0] == 24'hc00040) ? 32'h0040_0000 :
```

but the boot reads **byte 0x01c00040 AND byte 0x01c00042**, and the DPRAM is
eight bits wide at bytes 0 and 2 of the same dword. Comparing the RAW BYTE
ADDRESS matches only the first, so the second read returned 0 where it needed
0x40 and the boot stayed in the poll. The board said so precisely: **4,097 tile
RAM writes against simulation's 12,292**, then stopped, with the IP back at
`0x2282xx`. Fixed by comparing `[23:2]` — the word.

**Simulation could not see it**: the harness masks the address to the word before
comparing, so both byte addresses landed on the same case. This is the same
byte-versus-word confusion that earlier made a sweep report identical cycle
counts for every value it was given — found once, written down, and then
repeated in RTL.

*And the protocol itself, traced at last.* Read taps do not fire on this region
— it is a device handler, not RAM — and debugger `printf` does not reach stdout,
so `tools/mame_m2_dpram_watch.lua` samples the region every frame and reports
only what changed:

| frame | `0x01C00040` | `0x01C00042` |
|---|---|---|
| 1 | `01` | `00` |
| 7 | | `00 -> 40` |
| 8 | `01 -> 03` | |
| 10 | `03 -> 02` | `40 -> 00` |
| 21 | `02 -> 01` | `00 -> 40` |
| **175** | **`01 -> 00`** | |

**It is a request/acknowledge cycle**, not a constant. The poll waits for
`0x...40` to reach `00`, which MAME does not reach until **frame 175** — about
three seconds, which is why a 50 ms trace only ever showed it looping.

So the core's constant is **"the board is already ready"** — the frame-175 state
presented immediately. That is a legitimate shortcut and it is why simulation
reaches the settings screen. **It is also a snapshot of one moment in a protocol
that genuinely transitions, and it will not survive attract mode or gameplay.**

*Method note.* Three instruments were tried before one worked: Lua read taps
(silent, wrong kind of region), debugger watchpoints (output never reaches
stdout), and frame sampling (works). Recorded so the next person tries the third
first.

**R38 — the sound stub is not what is failing now, and the fold instrument is
sound but was pointed at only two places.** Two results from the sweep build,
and one of them closes the sound question for the moment.

*The instrument is trustworthy.* The port-4 sweep was built with a control on
purpose: region 0 folded the first 64 KB of program ROM, where the image is
known to arrive, and region 1 folded the far end, where the loader's high-water
mark is short. The board returned **`00633A8F` for the control — exactly the
value `tools/rom_csum.py` computes** — and `00D16D4E` for the far end against an
expected `9F84E2`. A control that matches to the bit is what licenses the second
number: the fold, the port, the capture phase and the host tool all agree over
64 KB, so the far-end disagreement is **the chip not holding the image**, not
the instrument mis-measuring it.

*And the sound stub is not the current blocker — but the first version of this
entry proved it wrongly, and the wrong proof is the more useful record.*

The claim was that hardware and simulation diverge under the same stub: hardware
reaches `0x22E914` and traps, simulation "never enters `0x22Exxx`" and ends at
`0x12F0`. **The simulation had run 200,000 instructions.** That is
`tb_i960_rom.cpp`'s default `max_insn`, it is three orders of magnitude short of
where the boot gets to, and `0x12F0` was not a spin loop -- it was simply where
the cutoff fell. I read a step limit as a behaviour.

Run to 20,000,000 instructions instead, and simulation says something different
and much more useful:

```
  executed 19573571 instructions over 77368693 cycles, 2205 distinct IPs
  final IP 00000000  PC=00000000  ICR=0f0e0d0c  interrupts taken 175
  TRAPPED on op 00 at IP 00000000
  178 vblanks asserted, intena=401 intreq=000
  unmapped reads (top addresses):
    ffffffec  1
    fffffff0  1
    fffffffc  108
```

**Both sides trap.** Simulation takes 175 interrupts, services 178 V-blanks,
runs nineteen and a half million instructions -- and then branches to zero and
executes a zero word. It also reads `0xFFFFFFEC`, `0xFFFFFFF0` and `0xFFFFFFFC`,
which is a null base with a small negative offset: a null pointer, dereferenced
just before control reaches zero.

So the conclusion survives -- **the sound stub is not what breaks this boot**,
since a defect both sides share cannot explain a difference between them -- but
it survives for the opposite reason to the one first given. It is not that
hardware fails where simulation succeeds. **It is that simulation fails too**,
and simulation has MAME as an oracle, full visibility, and no 25-minute turn.

*That relocates the whole investigation.* The trap was being chased on the board
because the board was believed to be the only place it happened. It is
reproducible in a harness that can be single-stepped against a reference.
Nothing about the far-end SDRAM mismatch is explained away by this -- it is
still real, still unexplained, and still worth bisecting -- but it is no longer
the only lead, and it is the more expensive of the two to chase.

*Method note, and it is the point of this entry.* The defect was a **default
that looked like a result**. A run that stops early does not announce itself; it
produces a number, and the number invites interpretation. R37's method note said
to try frame sampling first because two instruments had failed silently before
it. This is the same failure one level up: the instrument ran, returned, and was
believed, and nobody asked what its limit was. **Ask what a test's budget is
before reading its endpoint as a behaviour.**

The `0x22E914` trap is separately not an unwritten-memory read, which was an
earlier theory and was also wrong: word `0x1748E` genuinely holds `FFFF` in the
ROM image, so the read was correct and the *branch* that led there was not.

*What the instrument could not do.* Two hardcoded regions say the far end is
wrong; they cannot say where it stops being right, and with hardcoded spans each
probe is a 25-minute build. The sweep base is now an OSD option — region N is
word `N*0x100000` for 2 MB, and `tools/rom_csum.py --region N` folds the same
span — so bisecting 43.62 MB costs menu clicks instead of builds. `--scan`
prints the whole table at once.

One caveat is built into both sides: **regions past the end of the image prove
nothing.** The host tool substitutes `0xFFFF` there because that is what an
unwritten read returns by contract, but nothing wrote those words in the chip
either and real SDRAM comes up holding whatever it holds. For daytona93 the
image ends at word `0x15EFFFF`, so regions 0-20 are evidence and region 21 is
not.

**R39 — the chip held the image the whole time. The reference did not.** The
sweep bisect ran, the board matched regions 0-16 and disagreed on 17-20, and
the disagreement was in `tools/rom_csum.py`.

*How it was found without another build.* Four wrong numbers are more
informative than one. Rather than ask for more regions, the readings were tested
against every single-address-bit fault the controller could have -- each bit of
the 25-bit word address forced, cleared and flipped, folding the host image at
the resulting source and comparing:

```
region 18: reads from word 0x1220000 (bit 17) -> MATCH
region 20: reads from word 0x1420000 (bit 17) -> MATCH
```

Not a stuck bit. Both regions read `base + 0x20000` -- **the same displacement,
0x20000 words, 256 KB** -- which is not an address fault at all. It is an
offset, and an offset means the two sides disagree about where a part begins.

*The defect.* Daytona's two 68000 sound ROMs are declared

```xml
<interleave output="16">
  <part name="epr-16489.7" crc="c20e543e" map="12"/>
</interleave>
```

`output="16"` with `map="12"` is a **byte swap**: two bytes in, two bytes out.
`build_image` ignored the `output` attribute and assumed 32 throughout, so it
emitted four bytes for every two and made each part `0x20000` too long. Two such
parts, `0x40000` = 256 KB, and every part after them sat 256 KB late in the
reconstruction while the board had them in the right place.

Corrected, the image is **0x2BA0000 = 43.62 MB**, and the whole table agrees:

| rgn | 17 | 18 | 19 | 20 |
|---|---|---|---|---|
| board | `7D7E94` | `DB4D7D` | `BCBA2C` | `19E937` |
| tool, fixed | `7D7E94` | `DB4D7D` | `BCBA2C` | `19E937` |

*What this exonerates.* All of it. The SDRAM controller, the capture phase, the
64 MB geometry of R19, the FIFO, the loader. **And the loader's high-water mark,
which read "256 KB short of the MRA's length" and was called a symptom for three
sessions.** It was short by exactly the amount the tool was long. It was right.
The one instrument reporting the truth was the one under suspicion.

*Why the control did not catch it.* The original sweep folded the first 64 KB of
program ROM and matched exactly, and that match was used to license the far-end
number. It was a real control and it was correctly reasoned about -- but it sat
at word 0, **before every part whose offset was wrong**. A control upstream of
the fault cannot see the fault. It proves the fold arithmetic, the port, the
capture phase and the host tool agree *on that region*, which is exactly what
was claimed for it, and no more.

The generalisation, which is the reusable part: **a control must be able to
fail.** Placing one where the suspected mechanism cannot reach it produces
confidence without evidence. Region 16 makes the same point from the other side
-- it is byte-identical to region 15 in the image, so it would have matched even
under an alias, and a "pass" there means nothing either.

*And what it does not exonerate.* The trap is still real. R38's finding stands
on its own evidence: simulation, run to a real instruction budget, traps too,
after 19.57M instructions and a null-pointer dereference. Memory was the leading
theory and it is now dead, which leaves the CPU or the memory map, and both are
reproducible in a harness with MAME as an oracle.

*Pattern.* R38 was a default read as a behaviour. R39 is a reference read as an
oracle. Both are the same shape as the six already recorded: **the model was
gentler than the thing it modelled**, and in both cases the hardware was
reporting correctly while the instrument was believed over it.

**R40 — the device blocking the boot is the I/O board, not the sound board, and
backup SRAM powers up all ones.** Two findings, and the first one reverses a
recommendation made in this session.

*The poll is the I/O board.* The plan was to build the sound board, on the
reasoning that the boot parks polling `0x01c00040` and that region is the sound
board's dual-port RAM. Reading `model2.cpp`'s **model2o** map rather than
assuming it:

```cpp
map(0x01c00000, 0x01c00fff).rw("dpram", mb8421_device::right_r, ...)   // 2k*8 DPRAM
map(0x01c80000, 0x01c80003).rw(m_uart, i8251_device::read, ...)        // to the sound board
...
model1io_device &ioboard(SEGA_MODEL1IO(config, "ioboard"));
ioboard.read_callback().set("dpram", mb8421_device::left_r);
ioboard.write_callback().set("dpram", mb8421_device::left_w);
```

**The left side of that dual-port RAM is the I/O board.** The sound board is a
`SEGAM1AUDIO` on an i8251 UART at `0x01c80000` — a different address, which the
boot is not polling. So `ldob 0x1c00040,g4` is an I/O-board handshake, and every
resync the differential reported as "a sound-handshake poll" was an I/O poll.

The evidence never distinguished them. It showed a poll on a region whose
*device* had not been checked, and the sound board was assumed because R36 and
R37 had been about sound. **Two findings about a neighbourhood do not identify
the next thing found in it.**

*And Model 1 has already built it.* `tools/model1-ref/rtl/io/m1_ioboard.sv` is
the same board, on the same protocol, at the same offset — Model 1's `0xc00040`
is word `0x20` of the DPRAM and so is ours. It carries measurements this project
would otherwise have to repeat:

- the flag is raised by the CPU and **cleared by the responder**, not echoed;
- the turnaround is **740,684 cycles**, because it is the I/O board's Z80
  running its own self-test, not a mailbox latency — and it happens once;
- after boot the flag is a fire-and-forget doorbell and is never cleared again;
- the CPU block-reads an **identity block** at DPRAM `0x100-0x17f` before it
  will poll anything, and nothing else writes it, so the board must supply it.

That last one is the kind of thing a from-scratch implementation discovers after
a week of a core sitting in a loop with every input byte underneath it correct.

*Backup SRAM powers up all ones.* `NVRAM(config, "backup1",
nvram_device::DEFAULT_ALL_1)`. Every other region MAME maps with `.ram()` is
zero-filled; this one is not, and it is the region the boot tests against a
signature before deciding whether to initialise it — so 0x00 versus 0xFF is a
branch, not a detail. `docs/mister-integration.md` has said "unwritten memory
reads 0xFFFF, never zero" since before the harness existed. **The rule was
written down and the harness broke it**, in the one region where MAME agrees
with it.

Fixed, the differential moves from **2,553,593 to 2,564,287** matching
instructions. Modest, real, and not the blocker — which is consistent with the
blocker being a device that is not modelled at all.

*A tool correction, recorded because it briefly produced a wrong number.*
`i960-resync-diff.py` accepted a resynchronisation whenever the skipped span had
few distinct PCs. A ONE-instruction skip over ONE distinct PC satisfies that,
and the first run after the 0xFF fix reported **134 resyncs** and a divergence at
3,505,968 — of which 129 were `ran on 1 instructions over 1 distinct PCs`,
repeating every twelve instructions. That is a real behavioural difference being
absorbed silently by the instrument built to find it. A span now qualifies only
if it is at least 8 instructions AND is L-periodic for at least 3 iterations:
5 resyncs, and the honest divergence point is 2,564,287.

**R41 — the I/O board must NOT supply the identity block, and only the
differential could say so.** Three readings of one protocol, the third measured.

*Reading 1: the i960 writes the block and the board completes the tail.* The
status reply was hung off the window write. The boot deadlocked: it waits for
status `0x40` **before** it writes the window, so it waited for a status it
would not get until it wrote a window it would not write until it had the
status. Disproved in one run.

*Reading 2: the board supplies the block and the i960 copies it in.* The
disassembly says DPRAM is the source, plainly:

```
00228230: lda  0x1c00200,g6      ; DPRAM window
00228238: lda  0x1d00000,g5      ; backup SRAM
0022827C: ldob (g6),g4 / stob g4,(g5)
```

and Model 1's `122988c` says exactly this about exactly this board. Both facts
are true. The conclusion drawn from them was still wrong.

*Reading 3, what the reference does.* The i960 copies whatever is in the window
— **zeros**, that early — into backup SRAM, and then validates it:

```
00227CF4: ldl    0x1d00000,g4    ; what was copied in
00227CFC: ldq    0x23c150,g0     ; "SEGA..." from ROM
00227D04: cmpibe g4,g0,0x227de4  ; already valid? skip
00227D08: stq    g0,0x1d00000    ; otherwise initialise it here
```

It finds it invalid and **initialises backup SRAM itself**. A board that
helpfully fills the window makes that compare succeed, so the i960 skips its own
initialisation and diverges from the reference immediately.

That also explains the observation reading 1 was built on. The window's contents
later match backup SRAM byte for byte because **the i960 put them there**, not
because the board did — the same correlation, read three different ways, and it
never carried a direction.

*The measurement:*

| window | differential diverges at |
|---|---|
| board pushes the 128-byte block | 1,300,259 |
| board pushes nothing | **2,609,803** |

*And the point of the entry.* **Hardware could not tell these apart.** Overlay
row 8 read `00001001` — 4,097 tile writes — with the block pushed and without
it, exactly as it had for the four builds before. A regression that doubles the
distance to the first divergence was invisible on the device and obvious against
the reference in one run.

The differential had not been run since the block was added. It was added on the
strength of a disassembly and a sibling project's commit, both of which were
accurate, and neither of which was the reference executing. **Reading the source
is not running the oracle**, and this project has now spent four hardware builds
on the difference.

`COMPLETE_WINDOW` stays as a parameter so the wrong reading is reproducible on
demand: built with it on, three checks in `test_m2_ioboard` fail.

**R42 — the SDRAM suite's two failures were the harness, and R33 is confirmed
from outside.** Both from the Kaneko core's independent port of this
controller, against pristine unmodified Model 2 sources — same addresses, same
values, so neither project's changes introduced them.

*The failures.* A read that overlaps a write to the same address may
legitimately return either value. The controller gives no ordering guarantee
between independent ports with concurrent outstanding transactions and never
claimed to; `tb_m2_sdram.cpp`'s shadow updates at write ISSUE time, so it
expected only the post-write value. `pick_addr` uses six rows and four banks on
purpose — "few rows, so conflicts happen" — which makes the collision common
rather than exotic. Bisecting the stimulus localised it immediately:

```
writes with byte-enables:  2 fails
writes, full words only:   1 fail
no writes at all:          0 fails
```

Fixed in the harness, and **the count is reported rather than absorbed**:

```
reads accepted as raced (returned the legal pre-write value): 2
m2_sdram: checks=123927 fails=0 violations=0
```

A run showing zero there would mean the test had quietly stopped covering the
case it exists for. This suite had been red for the whole session and carried as
a known debt against the controller. It was never the controller.

*And R33 is confirmed.* That entry recorded that port 0's single-word read
carries A10 — auto-precharge — on its first command, because the first word is
also the last, closing the row inside tRAS: tolerated by a behavioural model,
and on the board the CPU port reads zero while every other port reads fine from
the same SDRAM. It was written up as **a theory a hardware test appeared to
disprove**, with the burst-four change kept anyway on the strength of the
reasoning.

The same fault has now been found independently in another core, on the same
controller, and described as the one defect that could not have been caught in
simulation at all. **The theory was right and the test that seemed to refute it
was measuring something else.** Recorded because the wrong conclusion was
allowed to stand next to the right fix for several sessions, and a reader of R33
alone would have drawn the wrong lesson from it.

**R43 — the arbiter rotates the mask once, and what raising the SDRAM clock
will cost.** `pll.v` records the 40 MHz SDRAM as "DELIBERATELY AND TEMPORARILY".
The Kaneko16 core took the same controller to 96 MHz, and its findings say what
that will actually involve here.

*The arbiter was the whole of it, and not for the reason it looked.* The grant
loop indexed with `(rr_next + j) % NP`. That is free while `NP` is a power of
two — the synthesiser drops the high bits — and **a real divider once it is
not**. Their `NP` went from 8 to 9 when a Z80 fetch port was added; ours has
been **5 since it was written**, so it was never free.

```
                       before        after
clk_sdram 96 MHz   -3.023 ns   +0.502 ns
```

Their first reading was that the two-pass arbiter wanted pipelining — an
afternoon of surgery on the most delicate module in the design, to fix something
that was one operator.

Compare-and-subtract is not the answer either: it leaves `NP` adders in a
priority chain, which closed at +0.615 ns and went to **-0.009 ns** as soon as
four debug counters were added. Both forms are the same mistake — rotating once
per candidate when it only has to happen once. Rotate the pending mask right by
`rr_next`, take the lowest set bit, rotate the index back: one barrel shift, one
priority encode, one adder.

Applied here (`b5b2019`'s technique, our single-tier arithmetic). `m2_sdram`'s
123,927 checks pass **unchanged to the number**, with the same cycle count and
the same transaction count, because the behaviour is identical.

*What else raising the clock will break.* Their `f36feab`: the ROM loader was
left in the fast domain, the build **closed timing at +0.502 ns, and every game
was broken at once**. Its inputs all come from `hps_io` on the slow clock, so it
became an unsynchronised crossing; and it drove the slow side of the domain
adapter while clocked fast, so `ACK_HOLD`'s two-cycle acknowledge — exactly one
edge for a slow requester — was two edges for it, and every ROM write counted
twice.

**Checked here rather than assumed, and neither half is present.**

*The crossing does not exist.* `hps_io` (`.clk_sys(clk_sdram)`),
`m2_rom_loader` and `m2_sdram` are all on `outclk_0`. The PLL has three outputs
— 40 MHz SDRAM, 32 MHz video, 25 MHz i960 — and no spare. Their fault was a
loader on a *fast* clock fed by `hps_io` on a *slow* one; ours is one net for
all three, so moving the loader to a different clock would **create** the
crossing they removed, not fix it.

*The ACK_HOLD double-count cannot happen here either.* That was the half that
actually corrupted their image — a two-cycle acknowledge read as two writes.
`m2_rom_loader` edge-detects:

```systemverilog
if (sdr_wr_ack && !ack_d) begin        // rising edge, not level
```

A two-cycle acknowledge has exactly one rising edge however wide it is in the
requester's cycles, so this is robust to any clock ratio, including one that
does not exist yet.

*What is still true is the ordering.* When `clk_sdram` is raised, this becomes
live in one step, and the fix belongs with that change: a fourth PLL output for
`clk_sys`, `hps_io` and the loader moved onto it, and the loader's write path
crossing into the memory domain. Doing it beforehand means a PLL regeneration
and a build to prove nothing moved, for no behavioural gain today. A corrupt ROM
image presents as everything broken at once with nothing pointing at the memory
clock, so whoever raises the clock should read this first.

*And the guard.* `make release` now refuses a build with negative setup slack.
"Flow Status: Successful" does not mean timing closed — Quartus reports success
and lists the failing paths in the STA report. Their guard caught a 9 ps miss in
a build that looked identical to the one before it. Verified here by running the
extraction against the current report rather than assuming: no negative rows,
worst case **0.183 ns**.

That 0.183 ns is on `pll_hdmi` at 148.5 MHz — framework logic, not ours, and the
same path their `SEED 7` note is about. We are on `SEED 1`. A marginal path
there is placement luck rather than a design fault, and it is worth pinning to a
seed that closes it once there is a build to confirm one.

**R44 — the SDRAM runs at 96 MHz, and the i960 moves to 24.** The 40 MHz in
`pll.v` was a retreat from 80, and that file's own note diagnosed it: the device
was clocked on the **inverse** of the controller clock, *"only a half period of
skew and no true phase shift"*, and named the fix as a properly phase-shifted
`SDRAM_CLK`. The Kaneko16 core has that working at 96 MHz, so this takes it.

*What it cost, and it is not a rounding.* **96, 32 and 25 cannot share a PLL.**
They need a VCO that is a common multiple of all three — 2400 MHz — and Cyclone V
tops out near 1600. The VCO is 960 (50 × 96/5), and 96 (/10), 48 (/20), 32 (/30)
and 24 (/40) are all exact divides of it. 25 is not. So the i960 runs at 24 MHz,
4% below the real part, against a core already retiring at CPI ~3.95 where MAME's
model is ~1. The frame rate does not move: it comes from the 32 MHz video clock
and is still 16e6/(656×424) = 57.52 Hz exactly.

| output | | |
|---|---|---|
| `general[0]` | 96 MHz | `m2_sdram`, alone |
| `general[1]` | 48 MHz | `clk_sys` — everything else |
| `general[2]` | 32 MHz | video |
| `general[3]` | 24 MHz | i960 |
| `general[4]` | 96 MHz, 180° | `SDRAM_CLK` pin |

*The controller is alone in the fast domain.* Every requester — the i960's
bridge, the tilemap copy engine, the character fetch, the sweep, the ROM loader
— stays at 48 MHz behind `m2_sdram_x2`, which halves every round trip counted in
core clocks without any of them changing. It is **not a CDC**: 96 and 48 are
exact divides of one VCO, so the edges align and every slow signal is stable
across two fast cycles.

*And that answers the loader question from R43 properly.* The loader does not
move to a slower clock and does not need a synchroniser; it stays on `clk_sys`
with `hps_io`, where it already was, and the adapter carries its write port
across. What made the Kaneko version corrupt every ROM was a loader clocked
**fast** while driving the slow side of that adapter. Here it is on the slow side
of both.

*Three things that had to move with the clock, and one that would have been
silent:*

- `T_REFI` 300 → 750. 8192 rows in 64 ms is 7.8125 µs, which is 750 cycles at
  96 MHz.
- The I/O board's timers, again — they encode frames, not counts, so 40 → 48 MHz
  moves them a third time.
- **The self-test counter would have overflowed.** It was `logic [26:0]`, sized
  by hand for 40 MHz. Frame 174 is 121,044,000 cycles there and **145,252,176 at
  48**, which needs 28 bits — so it would have wrapped at 134,217,727 and the
  board would have answered the handshake about a second early. That is a
  protocol-shaped fault with a numeric cause. The counter is now sized from its
  own parameter and cannot do it again.
- The SDC **stopped cutting the memory and core clocks apart.** Cutting them was
  right when nothing crossed between them; it is wrong now, and would have left
  the one crossing that must be timed simply not analysed.

*What is not yet known.* None of this has been built. Timing at 96 MHz is the
open question — the arbiter rework in R43 removed what Kaneko measured as the
binding path, but ours is a different design and the CPU bridge, copy engine and
character fetch now all sit at 48 rather than 40. The suite is green, including a
new 2:1 test whose read-data bypass mutation fails 1,786 of 2,560 checks.

**R45 — the I-cache moves its fetch address under an outstanding transaction.**
Root cause of the boot failure, established with a cycle-level dump rather than
inferred. **The fix is not written yet** and two attempts at it made things
worse; this entry exists so the next attempt starts from the evidence rather
than from a summary.

*What happens.* `i960_icache`'s `S_FILL` holds `bus_req` high across a whole
line and drives `bus_addr` **combinationally** from `fill_base`:

```systemverilog
assign bus_addr = fill_base + {28'd0, fill_word, 2'b00};
...
// "A redirect ... can ask for a different line mid-fill. Restart on it"
if (req && req_demand && ((idx != fill_idx) || (tag != fill_tag))) begin
  fill_base <= {addr[31:4], 4'd0};      // moves bus_addr immediately
```

So a redirect moves the address under a transaction the memory has **already
taken**. Its data arrives and is written at `{fill_idx, fill_word}` — word 0 of
the *new* line. The line ends up tagged for the redirect target holding the
abandoned address's word.

*The cycle dump, against the real bridge:*

```
req=1 addr=00000920                       the fetch the bridge took
req=1 addr=00000920
req=1 addr=00000910                       redirect, one cycle later
req=1 addr=00000910  reqm=1
req=1 addr=00000910  st=RDB sdaddr=0000490    still fetching 0x920
...
req=1 addr=00000910  ack=1 rdata=84079000     0x920's contents
```

Byte `0x910` is answered with the contents of `0x920`, which is `bx (g14)` — a
**return**. The boot's 128 KB copy loop returns instead of iterating on its
second pass, board RAM is never filled, and the machine ends at `0022e914`, an
address MAME never reaches in 12,000,944 instructions.

*Why nothing caught it.* `tb_i960_rom` answers the bus from C++ with an
immediate acknowledge, so a fetch is almost never still in flight when a
redirect arrives. It takes a multi-cycle memory to hold the window open. 803,355
instructions verified against MAME went through that path and none went through
the bridge.

*Two failed fixes, and why they failed.*

1. **Defer every redirect to the next acknowledge.** Breaks
   `test_i960_icache`'s redirect pass — 2 mismatches. With an immediate-ack
   memory nothing is outstanding, and deferring consumes an acknowledge the
   completion path needed.
2. **Defer only when a fetch is outstanding.** 4 mismatches. The `outstanding`
   flag is set from `bus_req`, which is held across the line, so it reads true
   in cycles where nothing is actually in flight.

Both are reverted. The suite is green and the harness reproduces the fault in
five seconds, which is the right state to attempt a third fix from.

*The fix, third attempt, and what made it work.* **Resolve the redirect on the
acknowledge, with an immediate path when an acknowledge is already present.**

```systemverilog
if (bus_ack && (redir_now || redir_q)) begin   // safe: nothing outstanding
  ... restart the fill at the redirect target
end else if (redir_now) begin
  redir_q <= 1'b1;  ...                        // remember; hold the address
end else if (bus_ack) begin
  ... normal word advance / completion
end
```

The two earlier attempts each served one regime and broke the other. Against a
memory that acknowledges in the same cycle it is asked, nothing is ever
outstanding and the redirect must take effect **at once** — deferring it there
consumes an acknowledge the completion path needed. Against the bridge, acks are
many cycles apart and the redirect must **wait**. Keying on whether an
acknowledge is present this cycle is what serves both.

The abandoned word is not discarded — it is still written to the old line, which
is correct data for a line nothing is waiting on.

*Result:*

| | before | after |
|---|---|---|
| boot copy | 7,545 / 65,536 | **65,536 / 65,536** |
| trap | at `0022e914` | none, 3,000,000 instructions |
| tile RAM writes | 4,097 | **41,868** |
| differential against MAME | trapped at 474,490 | **2,602,357**, five clean resyncs |

`test_i960_icache` stays at zero on both its redirect and speculative passes.
The remaining divergence at `0x0b10-0x0b30` is interrupt timing and is the same
one the direct-CPU harness reaches — this is no longer the blocker.

**R46 — the boot runs on hardware at 96 MHz.** First build where the i960
executes past the I/O board exchange on the device rather than in simulation.

| overlay | reads | means |
|---|---|---|
| word 20 | `00001204` | capture sweep done, only CL+2 passes, CL+2 selected — **stable across four resets** |
| row 2 | `00000860` | SDRAM reads back the boot IP correctly at 96 MHz |
| row 16 | `41474553` | `"SEGA"` — the boot's 128 KB block copy landed in backup SRAM |
| row 8 | `0000A394` | **41,876 tile RAM writes**, against 41,868 in simulation |
| row 4 | `00003B03` | no trap, no halt, `st_ok` set, image loaded, PLL locked |

**4,097 is finally behind us.** That number stood on every build for five
sessions and was attributed in turn to the sound handshake (R37), a missing
identity block, absent backup SRAM, a clock-domain crossing, and the bus
arbiter. It was none of them: it was one combinational address in the I-cache
moving a cycle early (R45), and it could only be found by putting the real
bridge in the loop.

*What it took, in order:* the composition harness (`test_m2_boot`), which
reproduced every hardware symptom in five seconds; the bridge's `T_IO` sample,
one cycle early against a registered peripheral; backup SRAM, which did not
exist; the I-cache redirect; the SDRAM at 96 MHz behind a 2:1 adapter with a
phase-shifted `SDRAM_CLK`; and a capture-depth sweep that calibrates itself.

*The one number that is not comfortable.* The passing window is **one depth
wide** — CL+1 and CL+3 both fail. It is stable, and stability across resets is
what makes it trustworthy, but a single-cycle window has no margin against
temperature or voltage drift. The Kaneko16 core sits at CL+4 on this same board
at this same clock, so our data arrives about two cycles earlier than theirs;
the likely causes are pin routing and the two extra PLL outputs. If this core
ever becomes unreliable after warming up, that is the first thing to look at,
and the sweep now measures it in one boot rather than a build per guess.

---

**R47 — the capture calibration ran *after* the readers it exists to serve, so
everything that read SDRAM at boot read it at CL+0.** The 2D tilemap test came
back a flat red screen on the 96 MHz build. The reflex reading was a colour
fault — red means R survived and G/B did not — and that reading was wrong in an
instructive way.

*What was eliminated, and how.* The colour path is fine end to end. The copy
engine's source addressing matches `model2.cpp` exactly (`0x40`, `0x2040`,
`0x4040` in words, stride 256); the CPU path's `{r_addr[15:14], r_addr[13:9]}`
and the copy engine's `cp_idx[6:0]` produce the same `{channel, value}` index
that `m2_video` reads back; and `xlat_ok` gates all 96 entries as a unit, so a
half-loaded table cannot exist. The fixture was verified byte by byte — all
three channels carry identical valid ramps 0→255. Then the decisive test:
`test_m2_video_frame` was run against that exact dump and rendered **2,054
non-black pixels of 190,464 in a bounding box of x 161–405, y 41–174, in white
and green** — pixel-for-pixel MAME's frame. The 2D pipeline was never at fault.

*The actual mechanism.* `rd_lat_sel` follows `cal_sel` while `!cal_done`, and
`cal_sel` resets to `3'd0`. The self-test that performs the calibration waited
on `cp_done` — added deliberately, to stop three read ports issuing at once
while the copy was being diagnosed. That made the ordering:

```
rom_loaded → copy engine (CL+0) → cp_done → calibrate → cal_done
```

Every read before `cal_done` was captured at CL+0. The board's own sweep says
CL+0 does not work: word 20 reads `00001204`, i.e. `cal_mask = 0b000100` —
**only CL+2 passes**. So the copy engine read garbage, and because it copies
tile RAM, the palette and colorxlat into M10K exactly once, it did not merely
read garbage, it *kept* it. Calibrating afterwards cannot repair a copy already
made. Char RAM is 512 KB, too big to copy, so it is fetched live on port 3 —
after calibration, hence correctly. Correct character pixels indexed through a
garbage tilemap and a garbage palette is precisely a screen of real pixels in
one flat wrong colour.

*Why Daytona did not show it.* `game_image` short-circuits `cp_done` without
reading anything, so on a game image the copy engine is a no-op and the tilemap
test was the only thing exercising that path. The bug was invisible on the
target we were actually driving.

*But it was not harmless there.* Two other readers were also unguarded, and
both had already produced bench symptoms that were misread as marginal SDRAM:

- **The ROM readback** gated on `cp_done`, which `game_image` asserts early —
  so on Daytona it read at CL+0. That is the "row 2 reads `FFFFFFFF`, then
  `00000860` after three resets" seen repeatedly on the bench.
- **The i960 itself** came out of reset on `rom_loaded`. Its first act is four
  reads — SAT, PRCB, IP and the initial FP — issued before calibration. Boot
  vectors captured two words early are garbage, and the CPU then runs from them.
  The intermittent PRCB and IP on the overlay were this.

*The fix is an ordering one:* the self-test now waits only on `rom_loaded`, and
the copy engine, the ROM readback and `cpu_rst_n` all wait on `cal_done`. The
chain `rom_loaded → calibrate → copy → readback` has no cycle, and contention is
still avoided — the wait simply points the other way. `ST_BASE` is word
`0x1F00000`, ~62 MB up, clear of both images, so the self-test is safe to run
first.

*The generalisable rule, and it is the one this project keeps paying for:*
**a calibration must complete before anything it calibrates is trusted, and a
value that is latched once must never be captured on an uncalibrated path.**
The guard that caused this was itself a fix — added for a real contention bug —
and it was correct about the contention and wrong about the direction. When a
diagnostic and the thing it measures are ordered against each other, the
measurement goes first.

*A note on the reflex.* "Red screen → colour bug" cost the first hour. The
colour hypothesis was cheap to test and false; what actually localised the fault
was rendering the real fixture through the real pipeline in simulation and
getting MAME's frame back. Reproducing the good case is as diagnostic as
reproducing the bad one — it converts "something in this 2,000-line path" into
"nothing in this path", which is what left the ordering as the only candidate.

---

**R48 — `0053F400` in the PRCB is the boot succeeding, not failing.** The
overlay's row 7 was labelled *"PRCB read at boot, want `000000C0`"*. The board
read `0053F400` and it was briefly taken as a bad read on the CPU's port,
because row 2 — an independent readback of the same memory through port 1 — was
correct at the same moment, which looked like a port-0 fault.

It is not a fault. `i960_top` line 1641 assigns `prcb_reg <= iac2` on a
**reinitialize IAC**, and Daytona's boot issues one. Confirmed by tapping
`dbg_prcb` in `test_m2_boot`, whose instruction stream matches MAME for 803,355
instructions: the harness ends holding **`0053f400`**, the same value the board
shows.

So row 7 changing is evidence the CPU got *further*, not that a read went wrong.
The old legend asserted the opposite, and an instrument that states the wrong
expected value is worse than one with no legend at all — it converts a success
into a bug report. The label now gives both values and says which is which.

*The general form of this, and it is the third time it has been paid for:* a
debug tap needs to name the whole range of correct values, not the first one
anybody happened to observe. Compare R38, where regions past the end of the
image were being read as evidence, and the sweep had to be made say which those
were.

---

**R49 — the character fetch was the one requester not on `clk_sys`, and
`m2_sdram_x2`'s header said otherwise.** The 2D tilemap test has never rendered
on hardware. It showed red, then black once R47 fixed the palette copy, and both
were the same failure: every pixel was palette entry 0, garbage-red and then
correctly black. There was never any tile content in the picture at all.

*What the board proved, and it took two purpose-built overlay rows.* Row 2 read
`00200020` — tile RAM words 6/7, matching the fixture byte for byte — so the
data was in SDRAM and read back correctly. But row 2 only ever proved SDRAM, not
the destination. Row 22 was added to probe the M10K copy directly (`tram[1]`,
`pal[1]`) and read **`0020FFFF`**: the copy engine had done its job perfectly.
Row 21 tapped `dbg_layer_have`, which `m2_video` had been generating and
`Model2.sv` discarding all along, and read **`00000000`** against the `00000310`
the correct render produces. Copy good, renderer consuming nothing.

*The mechanism.* `m2_sdram_x2`'s header states:

> *Every requester here — the i960's bridge, the tilemap copy engine, the
> character fetch, the sweep and the ROM loader — is on clk_sys ... It is NOT a
> clock-domain crossing.*

That is true of every port but one. `m2_video` runs on **`clk_vid`, 32 MHz**, so
`char_req`/`char_ack` cross 48 ↔ 32. Three things then compound:

- 48 and 32 are **not integer multiples**. They share edges only every 62.5 ns,
  so nothing from one is stable across a full cycle of the other — which is
  exactly the property the 96/48 adapter relies on and this port does not have.
- `m2_sdram` holds `p_ack` for `ACK_HOLD` = 2 fast cycles = one 48 MHz cycle =
  20.8 ns. `clk_vid` samples every 31.25 ns. **`test_m2_char_cdc` measures it:
  4 of 12 starting phases lose the pulse entirely.**
- `Model2.sdc` cuts `clk_vid` against the memory group, so the path was never
  timed and nothing reported it.

`m2_tile_fetch` holds `char_req` until acknowledged, so the *first* missed ack
hangs the fetch engine permanently — which is why `dbg_layer_have` is exactly
zero rather than merely reduced. Modelling it as "the memory never answers"
(`+charlat=100000`) reproduces the board: **0 non-black pixels of 190,464.**

*Why every test passed.* Simulation answers `char_ack` in `m2_video`'s own clock
domain. `test_m2_video_frame` renders MAME's frame pixel-for-pixel — 2,054
non-black pixels in x 161–405, y 41–174 — and cannot see the crossing at all,
because the crossing does not exist in that harness. **A latency sweep does not
find this**: 1 → 80 cycles degrades the picture gracefully and never reaches
zero. Only "the acknowledge is never seen" reproduces it.

*The fix* is `rtl/mem/m2_char_cdc.sv`, a four-phase handshake: the request is
synchronised into `clk_sys`, one SDRAM transaction is issued, the data is
latched, and a `done` level is synchronised back and cleared only when the
requester lets go. `v_ack` is a one-cycle **edge**, not a level, because
`m2_tile_fetch` re-raises `char_req` immediately on acknowledgement and a level
would still be high — the engine would read the previous character as the next
one's. This is correct at any frequency pair, which is the point: the
arrangement it replaces was correct only for a ratio nobody had written down.

*`m2_cdc_port.sv` was considered and does not fit* — it is Model 1 heritage,
unused here, takes a one-cycle pulse on both sides where this needs a held
level, and is 16-bit where the character fetch needs 32.

*The rule, and it is the study's oldest one in a new costume:* **a comment
asserting "this is not a CDC" is a claim about every signal that crosses, and it
decays the moment one of them moves.** The premise was written when it was true.
What made it false was `m2_video` being on the video clock — which was not a
change to the memory system at all, and so was never checked against the memory
system's assumptions. Where a design depends on a frequency relationship, the
relationship belongs in a test that fails when it changes, not in prose.

---

**R50 — the character cache, and two measurements that contradicted what was
obvious.** With R49's crossing in place the tilemap rendered on hardware for the
first time, but `dbg_layer_have` read `00000224` against the correct `00000310`
and the longest text lines came out as wrong glyphs. The frame render at
`+charlat=10` reproduces that photograph **exactly** — same corrupted lines,
same clean ones, same `0x224` — so the board's character fetch costs ten
`clk_vid` cycles per glyph, and the whole remaining problem could be worked in
simulation against a pixel-exact oracle.

*The first thing that was obvious and wrong.* The four-phase handshake costs six
`clk_vid` cycles per fetch at minimum memory latency, and the reason looked
plainly like the return-to-zero: the engine cannot start the next fetch until
the request has dropped and propagated both ways. A two-phase toggle removes
that phase entirely. Implemented, it measured **7.0 cycles — worse.** Detecting
a toggle needs a third synchroniser stage on the request side, and that costs
more than the idle phase saved. Reverted. *The return-to-zero was never the
expensive part;* it overlaps with the next request's synchronisation.

*The second.* `test_m2_video_frame` reports the engine waits on memory for only
**4.5% of all cycles** at lat=10. That is not a memory-bound renderer by any
ordinary reading — and yet 36 lines overrun their budget, because the cost is
not spread evenly. A handful of dense text lines carry far more fetches than the
average, and they are the ones that fail. **An average hid the fault
completely**; only the per-line overrun count showed it.

*What actually worked.* `m2_tile_fetch` cached exactly one character, which
catches only CONSECUTIVE repeats, and a line of text is a small alphabet reused
constantly rather than runs of one glyph. Widening it:

| entries | perfect up to |
|---|---|
| 1 | (board: `0x224` at lat 10) |
| 12 | lat 12 fails, lat 10 ok |
| **16** | **lat 12** |
| 24, 32, 48 | lat 12 — no further gain |

16 is the ceiling and the cheapest way to reach it: beyond it what remains is
genuinely distinct glyphs, not repeats. Against the board's measured ten cycles
that is 20% margin. The cache is cleared per scanline with `tile_valid`, which
is not required for correctness — a character address encodes its row, so stale
entries simply miss — but it is kept, because the entries would be dead weight.

*What this does NOT fix.* The ceiling is lat=12 and Daytona is worse than the
tilemap test, because its i960 competes for the same SDRAM and lengthens the
round trip. If Daytona still corrupts, the next lever is not a bigger cache —
that is measured flat — but **halving the fetches**: the SDRAM already returns
four words and `char_data` takes two, so fetching rows N and N+1 together and
keeping the cache across scanlines would serve two lines per fetch. Beyond that,
the architectural answer is Model 1's, stated in `m2_cdc_port.sv`'s own header:
put *memory, ROM loading and video* in the fast domain and only the CPU in the
slow one. `m2_video` takes `ce_pix` precisely so its logic clock and its pixel
rate are separable, so moving it to `clk_sys` would delete the R49 crossing
rather than carry it.

*The rule:* **a percentage is an average, and an average is the wrong instrument
for a budget that is per-line.** 4.5% occupancy and 36 blown lines are the same
measurement described two ways, and only one of them names the bug.

---

**R51 — Daytona's characters were never late, they were being read from the
wrong address.** R49 gave the character fetch a working clock crossing and R50
cut its fetches to fit the line budget. Together they made the 2D tilemap test
**pixel-perfect on hardware** — the first time this core has rendered a
MAME-captured frame correctly on the device. Daytona was **unchanged**.

*That word is the whole finding.* R50 was a bandwidth fix, and bandwidth fixes
are graded: they move a picture partway. A game that does not move at all is not
short of bandwidth. It is doing something else entirely, and the two symptoms had
been assumed to share a cause because they shared a screen.

*What it was.* Character RAM lives in SDRAM because 512 KB will not fit in M10K.
Its base was written down **twice**:

| consumer | base | source |
|---|---|---|
| CPU bridge write path | `GAME_CHAR`, word `0x1690000` | `.base_char(GAME_CHAR)` |
| renderer fetch port | `CHAR_BASE`, word `0x0A000` | `p_addr[3] = CHAR_BASE + …` |

Both apply the same 18-bit word offset, so on the tilemap-test image they agree:
the fixture puts char RAM at byte `0x14000` = word `0x0A000`, and no CPU runs. On
a **game** image they do not. Daytona's i960 writes its characters to
`0x1690000` and the renderer reads `0x0A000`, which on a 43.5 MB game image is
program ROM. The board was drawing Daytona's text out of i960 instructions —
"program ROM rendered as tiles", which this project has recorded once before for
an unrelated reason, so the symptom was not even new.

*Why every instrument missed it.* `test_m2_boot` checks the CPU's char writes
against MAME and they are 100% correct — it has no renderer.
`test_m2_video_frame` renders correctly — it has no CPU and no SDRAM. Each half
was verified against a different oracle and each half was right. **The defect
lived only in the agreement between them**, and nothing tested that, because
nothing instantiated both.

*The fix* is not a second conditional. It is `wire char_base = game_image ?
GAME_CHAR : CHAR_BASE`, taken by the bridge and the fetch port alike, so the two
cannot drift. The old arrangement required two constants to be kept in step by
hand and offered nothing that would complain when they were not.

*The rule, which is this project's oldest one read backwards:* "**one signal must
not mean two things**" has a converse — **two things that must agree should not
be two signals.** Where a value is consumed in two places and must match, derive
it once. The alternative is a correctness property maintained by memory, and
this one survived a clock-domain rewrite, a cache rewrite and four builds
without anybody noticing it was there.

---

**R52 — R47 named four readers and there were five; the sweep was the fifth, and
it is the one the study tells you to trust.** With R51 in place Daytona renders
its horizon — sky and ground as two solid tile layers — and its overlay is
legible. The port-4 sweep, folded over region 0, read **`006393E3`** against
`tools/rom_csum.py`'s **`25E723`**, on a board whose i960 was at that moment
executing **106 million instructions out of that very region** and whose row 3
read `015CFFFF`, exactly the tool's `last word`. Both cannot be true of the
memory. The memory was right.

The sweep began at `3'd0: if (rom_loaded)`. R47 gated the copy engine, the ROM
readback and `cpu_rst_n` on `cal_done` and enumerated the readers as "ports 0
to 3" — the sweep sits on port 4 and was not in the list. A sweep runs ~66 ms
and the calibration completes part way through it, so the fold mixed words
captured at CL+0 with words captured at CL+2 and produced a total that matched
nothing and never could.

*A wrong instrument is worse than none*, and this is the second time in three
findings that the instrument rather than the machine was at fault — R48 was a
legend asserting the wrong expected value. Here the sweep is specifically what
R38 says to compare ROM contents against. Anyone following that advice on this
build would have concluded the image was corrupt and gone looking for a loader
bug that does not exist.

*Now gated, and the enumeration is written down so the next reader is checked
against a list rather than a memory:*

| port | requester | waits for |
|---|---|---|
| 0 | ROM readback | `cal_done` |
| 1 | i960 bridge | `cpu_rst_n`, which includes `cal_done` |
| 2 | copy engine / self-test | `cal_done` / **is** the calibration |
| 3 | character fetch | `m2_video` reset, now `cp_done & cal_done` |
| 4 | region sweep | `cal_done` |

Port 3 was self-correcting — live re-reads rather than a latched copy — and was
gated anyway, because "it fixes itself" is not a reason to leave a reader
running ahead of the thing that tells it where the data is.

*The rule:* **a fix that turns on an enumeration must write the enumeration
down.** R47 was correct about every reader it listed and the list was short by
one, which no test could catch because the missing item was a diagnostic and
diagnostics have no oracle of their own.

---

**R53 — the palette is 8,192 entries and half of every game's writes were
landing on top of the other half.** Daytona's test menu rendered its green
values and **no white labels**, and the ground alternated green and brown across
resets. Two hypotheses were tested and both were wrong before the right one:

*Wrong 1 — a dead colour channel.* White is (31,31,31): if the translation
table's R and B map to zero while G survives, white renders green and so does
green, and every colour collapses. It fits the symptom exactly. Row 22 was added
to count translation-table writes per channel and read **`00202020`** — 32 to
each, a complete table. Then `test_m2_boot` was tapped to dump the values the
CPU actually programs, and all three channels are identical, correct 0→255
ramps — the same table the fixture uses. Counting writes proved the addresses
landed; only dumping the values could prove the table was right.

*Wrong 2 — a dead layer.* Row 21 packed only `dbg_layer_have[1:0]` and read
`00000000` on a board visibly drawing sky and ground. That was the instrument,
not the machine: the fixture happens to use layer 0 and Daytona does not. Widened
to all four, it reads `FFFF0000` — layers 3 and 2 saturated. The fetch path was
never idle.

*What it actually was.* `tools/mame_m2_tiledump.lua`, which captures the
reference frame, gives the palette as `0x01800000 +0x004000` — **0x4000 bytes,
8,192 16-bit words**. `m2_cpu_bridge` forms `oc_addr = r_addr[15:1]`, so that
region yields indices 0..8191. `Model2.sv` held `pal[4096]` and indexed
`pal[ocb_addr[11:0]]`. **Every palette write above entry 4095 wrapped onto the
low half and overwrote the entries the tilemap draws with** — white among them.
The alternating ground colour was the same aliasing: which of two writes to one
physical entry landed last depended on timing, so it changed across resets.

*Why the fixture is immune, and why that mattered so much.* The copy engine
fills only the low 4,096 words and nothing ever writes above them, so the
tilemap test cannot express this defect at all — it renders **pixel-perfectly**
on the same hardware, in the same build, in the same frame, while a game does
not. A reference image that exercises one write path cannot validate another.
This is R51's shape repeated: the halves were each correct against their own
oracle and the defect lived in what neither covered.

*Checked at the same time and NOT a bug:* tile RAM is `0x010000` = 64 KB =
32,768 words, which `tram[32768]` matches. The bridge decodes twice that, and
`r_addr[15:1]` silently folds the upper half — which is correct, because the
hardware mirrors there.

*The rule:* **a region's size is a fact to be looked up, not inferred from the
array someone already wrote.** 4,096 was consistent with everything the fixture
could show, and it was wrong by a factor of two.

---

**R54 — the missing text is the CPU destroying its own palette at instruction
1,713,595, and it reproduces in simulation.** Daytona's test menu shows its green
values and no white labels. Five things were eliminated first, each by
measurement rather than argument: the colour translation table (all three
channels dump identical correct 0→255 ramps), the palette's colour channels
(per-channel write counts read `00202020`), a dead layer (row 21 widened to all
four reads `FFFF0000`, layers 2 and 3 saturated), line overruns (row 22 read
`00000000` — **the renderer keeps up, and the line buffer that was proposed
would not have helped**), and the palette's size (R53, real and fixed, but not
this).

*The reproduction, which is the whole finding.* `test_m2_boot` was made to dump
the tile RAM, palette and translation table **our own CPU builds**, and those
were rendered through `test_m2_video_frame` instead of MAME's capture. The
result is **468 non-black pixels against the reference's 2,054**, and the picture
is the photograph from the bench: `ON`, `JPN`, `DELUXE`, `NORMAL` in green, every
white label absent. The bug now lives in a five-second simulation.

*The diff then names it exactly.* Tile RAM differs in **13 words of 32,768** and
loses nothing. The palette differs in **64 entries, every one at `1 + 16k` for
k = 0..63**, each written `0000` where the reference holds a colour — and
**entry 1 is white**. Logging every write to that entry:

```
pal[1] <= ffff   (bus 01800000, instruction 1,478,810)   white written
pal[1] <= fd02   (bus 01800000, instruction 1,483,100)
pal[1] <= 0000   (bus 01800000, instruction 1,713,595)   white destroyed
```

*It is not the bridge.* `oc_addr = r_addr[15:1] + half` and `oc_din = half ?
r_wdata[31:16] : r_wdata[15:0]` are correct, and MAME maps the region at
`0x01800000-0x01803fff` with a **16-bit handler and no umask**
(`model2.cpp:1059`), so a 32-bit store there writes both entries in MAME exactly
as it does here. The stride-16 pattern is a zeroing loop walking 32 bytes at a
time; entries 0, 16, 32 are zero in the reference too, so only the odd ones show
as differences.

*So the CPU is executing something MAME does not, and it does so at instruction
1,713,595 — past the 803,355 the i960 has been differentially verified to.* That
is the target: `tools/i960-diff.sh` aimed at the window around 1.7M, not another
guess at the renderer.

*Two instruments were built and one was wasted.* The overrun counter earned its
build: `00000000` killed the bandwidth theory outright and stopped a line-buffer
rewrite that the burstiness figure (max/mean 3.18×) had made look attractive. The
tile-RAM fold probe did not: it cost **64 M10K** — Quartus duplicated the whole
array for a third read port — and could never be read, because the menu cannot be
held still and a fold of a moving screen compares against nothing. **Its
precondition was not checked before it was built.** Removed.

*The rule, and it is the one that has now paid three times in this session:*
**when each half is verified against its own oracle and the assembled machine
still fails, stop instrumenting the machine and render one half's real output
through the other.** R51 and R53 both hid in the gap between two passing tests;
this one was found by closing that gap in five seconds rather than by another
25-minute build.

---

**R55 — the PC-stream differential cannot reach this fault either, and the
reason is interrupt timing.** With R54's reproduction in hand, the obvious next
move was to find where our i960 stops agreeing with MAME. Two tools exist for
it and neither works here, for two different reasons, and both are worth writing
down because the next person will reach for them first.

*`i960-datadiff.sh` reports tile, char and palette IDENTICAL — and it is a true
result about the wrong moment.* Its breakpoint is passed to MAME's debugger as
`go $BP`, which is **hex**, so the default 228240 is `0x228240` — the sound poll
loop. Worse, its "ours" side is `obj_i960_rom`, which has no I/O board and
therefore stalls in that same loop forever while MAME walks past it and draws
the menu. Both sides are dumped pre-menu; both hold `entry1=9090`, the value
written at instruction 132,411. The comparison passes because nothing has
happened yet on either side.

*So the trace must come from `m2_boot_harness`*, which does get past the poll —
it has the I/O board and the backup SRAM. It now emits one PC per retired
instruction from `M2_BOOT_PCFROM` onward.

*Setting the comparison up took three attempts, and the two failures were mine,
not the tools':* MAME emits uppercase hex and we emit lowercase, and MAME's
trace carries 126 non-record lines — `(interrupted at 000013E0, IRQ 0)` and
blanks — which break `i960-resync-diff.py`'s fixed 9-byte record. Filter with
`grep -E '^[0-9A-Fa-f]{8}:' | cut -c1-8 | tr 'A-F' 'a-f'`.

*What it then found, and why it is not the answer.* Five resyncs across genuine
poll loops (2-3 distinct PCs each, one of them 1,201,884 MAME instructions
long — the CPI ratio, not a defect), then a divergence at `mame=2,602,332
ours=573,916` inside this loop:

```
00000B0C: shlo    6,3,r6          r6 = 192, a COUNTED loop, not a wait
00000B10: stos    r8,0x10000(r4)
00000B18: stos    r8,0x14000(r4)   +0x4000 apart: the three colour-
00000B20: stos    r8,0x18000(r4)   translation channels
00000B28: addo    2,r4,r4
00000B2C: cmpdeco 1,r6,r6
00000B30: bl      0x00000b10
```

We leave it after `00000B18` for `0x00000e00`. That looked like a `cmpdeco`
defect until the stream was checked: **`0x00000e00` appears 29 times in ours and
38 times in MAME's**, so it is a routine both machines run, and we reach it
*mid-loop, between two stores*. It is an interrupt.

*And an interrupt landing at a different instruction is expected here, not a
bug.* Our CPI is ~3.95 against MAME's ~1; V-blank arrives on wall-clock, so we
retire roughly a quarter of the instructions per frame that MAME does and every
interrupt lands at a different offset. `i960-resync-diff.py` was built to see
past **poll loops** and does; it cannot see past this, and nothing in it claims
to.

*The instrument this actually needs is the one `i960-diff.sh`'s own header
already names:* **write-stream comparison.** A PC stream cannot settle a
disagreement about values, and a timing-shifted interrupt makes PC comparison
useless long before the palette is written. Comparing the ordered sequence of
`(address, value)` stores into `0x01800000-0x01803fff` on both machines is
independent of when interrupts land and of how many instructions each side takes
to get there, and it names the differing store directly. `docs/differential-
testing.md` describes it; it does not exist yet.

*The rule:* **a differential tool is only as good as the thing it compares, and
PCs are the wrong thing once two machines run at different speeds.** Three
sessions of instruments have now converged on the same conclusion from different
directions — R54 found the fault by rendering one half's real output through the
other, and this entry finds that the PC stream cannot localise it further. Data,
not control flow, is what is left to compare.

---

**R56 — the bridge wrote both halves of every on-chip store, and a halfword
store destroyed the entry next door.** Daytona's test menu rendered its green
values with no white labels. `m2_cpu_bridge` asserted `oc_tram_we` / `oc_pal_we`
in **both** `S_IDLE` and `S_LO` without ever consulting the byte enables, so
every store to tile RAM or the palette wrote two 16-bit words. That is correct
for a 32-bit store and destructive for a 16-bit one.

The instruction is `stis g0,0x1800000(g4)` at `0x2784` — **store integer short**,
a halfword. The CPU decodes it correctly (`i960_ldst.sv`: `8'hca … size = 2'd1`);
only the bridge was wrong. The byte enables said so plainly once they were
logged:

```
pal[0] <= 0000  (bus 01800000 be=3)   16-bit: owns the low word only
pal[1] <= 0000  (bus 01800000 be=3)   written anyway -- the white destroyed
pal[1] <= ffff  (bus 01800000 be=f)   32-bit: both words, correctly
```

*How it was finally caught, after five wrong theories.* A snapshot comparison
could not distinguish "we execute a store MAME does not" from "we miss one MAME
makes". `tools/mame_m2_palwatch.lua` samples the entries per frame instead —
polling rather than tapping, because the palette is a device handler and study
R37 records that write taps do not fire on those. MAME's timeline is decisive:

```
frame 25:  e0=fd02  e1=ffff     white written
frame 26:  e0=0000  e1=ffff     entry 0 cleared, entry 1 SURVIVES
frame 400: e0=0000  e1=ffff
```

MAME clears one entry where we cleared two. That is a store-width fault stated
in one line, and nothing about the renderer, the palette's size, the layers or
the fetch bandwidth could ever have produced it.

*The result.* The palette our CPU builds now differs from MAME's capture in **0
of 8,192 entries**, holds **60 of 60** white entries against the reference's 60,
and our own output rendered through `m2_video` gives **2,054 of 190,464
non-black pixels — identical to the reference**, with `dbg_layer_have` matching
at `0x310`. The picture is the full menu: white labels, green values, and the
`3` and `1` the bench reported missing.

*This also affected TILE RAM*, on the same two lines, which is where the 13
differing words of R54 came from — small, because the tilemap is mostly written
32 bits at a time.

*The rule, and it is the sharpest statement of the one this session kept
re-learning:* **a write enable is not a width.** The bridge knew the address and
the data and applied both correctly; what it never asked was how much of the
dword the access owned. Five instruments were built chasing the symptom — layer
taps, per-channel counts, an overrun counter, a 64-M10K memory fold — and the
fault was named by logging four bits that were already on the wire.

---

**R57 — the SDRAM interface has never been timing-constrained, and that is why
builds are a lottery.** A build whose only source change was bounding the region
sweep at `ldr_top` failed to boot: no SEGA handshake, black screen, and **row 20
reading `00001400` — `cal_mask = 000000`, no capture depth passing at all**, with
`cal_best` falling back to its "nothing passed" default. A clean rebuild produced
a **byte-identical** core, so it was reproducible rather than fit luck.

*The cause is not that change.* It is that neither `Model2.sdc` nor
`sys/sys_top.sdc` contains a single `set_input_delay` or `set_output_delay` for
any SDRAM pin, and there is no `create_generated_clock` for `SDRAM_CLK` as it
arrives at the device. **The external timing relationship is invisible to the
fitter.** It places and routes those paths arbitrarily, STA reports success
because there is nothing to check, and whether the interface works is decided by
where the fit happens to put things. Adding a 25-bit comparator to an idle
port-4 state machine was enough to move it.

*What this reframes.* R46 recorded the passing window as ONE depth wide and read
it as a property of running at 96 MHz, worth watching. It is not that: it is an
unconstrained interface that landed near-usable. The same cause covers the
capture window moving between builds, `cal_mask` collapsing to zero, forcing
CL+2 by hand failing to rescue it (the window was gone, not misplaced), and
plausibly the shifting colours and flat sky/ground that were chased as logic
faults for most of a session.

*The fix, when it is done:* a `create_generated_clock` on the `SDRAM_CLK` output
pin, `set_input_delay` for `SDRAM_DQ` against the device's tAC/tOH, and
`set_output_delay` for address, control and write data against its tSU/tH. It
will probably fail timing at first, and that is the point -- it would be
reporting a violation that exists now and cannot currently be seen.

*Deferred deliberately, with a canary.* The decision from the bench is to wire up
more of the machine first and see whether the same trouble recurs. That is safe
only because the instrument already exists: **`cal_mask` on row 20 is a
per-build health check on the memory interface.** Several contiguous bits means
the fit is sound; a narrow or empty mask means the interface broke and the new
component is innocent. Read it before drawing any conclusion from a new build.

*The rule:* **an interface to a device outside the FPGA is not constrained by
constraining what is inside it.** Every clock in this design is timed, the PLL
hierarchy is checked, the CDC crossings are now bounded -- and the one path that
leaves the chip had nothing at all. A build can be green in every report this
project checks and still not talk to its memory.

---

**R58 — the SDRAM interface is constrained, and the former killer edit is the
proof it worked.** Following R57, `Model2.sdc` now carries the full interface
description: `create_generated_clock` on the `SDRAM_CLK` output pin,
`set_input_delay` on DQ (tAC 5.4 + 1 PCB), `set_output_delay` on
address/control/data (tSU 1.5, tH −0.8), both collections guarded so an empty
match posts a critical warning instead of silently constraining nothing.

*Getting it through Quartus 17.0 took three workarounds, all recorded because
each will bite again:*

1. **`quartus_map` evaluates the SDC too, and CRASHES on these port
   constraints** — Internal Error, `mast_mux_add.cpp:684`, reproduced on a
   clean db. The block is fenced by `$::quartus(nameofexecutable)` so only the
   fitter and TimeQuest see it. Synthesis has no use for I/O timing.
2. **The fitter then succeeds and crashes during its own exit cleanup**,
   aborting the flow after declaring success. `quartus_sta` and `quartus_asm`
   run standalone from the finished fit complete the build. This recurs on
   every build with these constraints; treat it as the normal flow.
3. **The first honest analysis reported −13.77 ns on reads and −1.92 on
   outputs** — numbers describing a design this is not. The capture depth is
   calibrated at boot (R47), so reads arrive a consistent integer number of
   cycles late, and outputs are sampled at the following 180° edge. Stated as
   setup/hold multicycle PAIRS one edge apart — which still enforces the one
   physical truth required, consistent arrival within one period — every clock
   closes: reads +2.22, outputs +8.50. Without the calibration these
   exceptions would be constraining the test to pass (R38); with it they are
   the design's description.

*The proof.* The `ldr_top` sweep bound — the edit that produced a non-booting
core twice, reproducibly, on the unconstrained interface — was re-applied on
the constrained one. The fitter absorbed it: reads +1.697, outputs +6.652, and
the board boots and behaves identically. **The comparator's placement cost is
now a measured slack consumption instead of an invisible coin toss.** The
constrained build's first fit also behaved identically to the known-good core
despite being a different placement — the first time a re-fit has been
survivable on this project.

*What did NOT change:* `cal_mask` still reads one depth (row 20 `00001204`,
CL+2). The constraints hold the window in place; they did not widen it. Margin
against temperature and voltage is still one depth, and widening it (SDRAM_CLK
phase tuning, now measurable per build in the STA numbers instead of by
rebuild-and-pray) is future work, not urgency.

*The rule, completing R57's:* **when a fix claims to make a class of failure
impossible, re-apply the failure and watch it be absorbed.** A fix verified
only by "the symptom went away" is indistinguishable from the symptom moving.

---

**R59 — the Model 1 project hit R57's wall independently, and the two projects
now cross-validate.** `tools/model1-ref` at `8788ede`: their fitter SEGFAULTS on
the read-path multicycle (they made the read side opt-in and ship output-only);
ours survived behind the `quartus_map` fence with registered NVRAM paths — same
17.0 fragility class, different crash sites, both recorded. They corrected their
generated clock's source the same way R57 did here (the dedicated phase-shifted
PLL output drives the pin; sourcing clk_sys with -invert would model a
relationship that does not exist) — independent convergence on the same fix.
And their finding that `Fast Output Register` is REFUSED on `sd_a` (it carries
both a clear and a load) reproduces here: 40 pack refusals on `sd_a[2,6,7,8]`
and `sd_dq_oe`. Those outputs launch from fabric; STA computes against the real
placement, so our +6.6 ns output slack already includes it and stays honest —
noted so nobody later "fixes" the refusals expecting margin that is already
counted.

---

**R60 — the SCSP is off Daytona's critical path, and the ecosystem covers more
than the audit credited.** `model2.cpp` line 2580: model2o games take
`SEGAM1AUDIO` — the Model 1 audio board, 68000 + YM3438 + 2× MultiPCM — with the
SCSP belonging to 2A-CRX. So §5.3's highest-risk block ("SCSP: none usable, must
be written, high") does not gate the bring-up target at all. Daytona's sound is
fx68k (vendored, suites green) + jt12 for the YM3438 (Jotego, GPL-3, proven in
the Genesis core) + MultiPCM, which must be written but is a 28-voice sample
player, far simpler than an SCSP, + the i8251 link.

The same audit pass, prompted from the bench ("is there not already a core for
this?"), reclassifies the I/O board: it is a COMPUTER (Z80 + EPR-14869, 64 KB,
in the daytona93 romset, CRC-verified) and will be run as one on a T80 rather
than imitated — R37-R41's HLE stalled exactly where the board computes rather
than responds (the credit digits). Remaining blocks needing original RTL are
now exactly two: MultiPCM and the 3D renderer. Everything else is
vendor-and-integrate with clean licences: T80, jt12, mb86233 (ours-adjacent),
fx68k. The Model 1 reference has no audio RTL yet, so MultiPCM work here flows
back to it — the reverse of the fx68k direction, closing the loop the study's
tooling section hoped for.
