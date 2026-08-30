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

---

**R61 — first light: EPR-14869C runs on tv80 and performs the exchange.** The
real I/O firmware, on a real Z80, standalone in `test_m2_ioz80`: given the
game's captured opening (replayed from a boot-harness DPRAM dialogue log), it
clears the flag, scans the inputs into `0x00-0x0f`, fills the whole window
`0x100-0x17f`, and writes **status `0x40` at `dp[0x21]`** — the R40 handshake,
produced by the program R40 could only imitate. 1,511 writes, 147 addresses.

*The wake-up protocol, which no HLE knew:* the game writes **"SEGA" into bytes
`0x1a-0x1d`** and raises the flag; the firmware polls `0x1a` through the
315-5338A's serial-read path and idles correctly forever on an empty DPRAM —
which is why the board first appeared dead standalone, and why R40's "status at
frame 7 unprompted" was really "status shortly after the game's opening move".

*R41 is confirmed by the silicon's own program:* zero firmware writes to the
identity block at `0x200-0x27f`. The game writes it; the board never does.

*What it took, all recorded in the module:* the 93C46 EEPROM behind PA7/PA6/PA5
and PG7, whose absence left the boot retrying a serial read forever; NEGEDGE
memory reads, because tv80 expects async-ROM shape and a posedge-registered
read serves fw[previous A] — observed as `ld (hl),n` storing the byte before
its operand; and trailing-edge write commit with latched A/dout, because tv80
settles dout after the strobe rises. The DPRAM sits BEHIND the 315-5338A
(commands 0x00/0x01 set an address from the serial register, 0x07 writes,
reg 0x0c reads, 0x70-0x77 write bytes 0-7 directly) — the byte-at-a-time shape
every DPRAM trace always showed.

Next: the credit computation. The game's settings round-trip happens later in
the dialogue (~1.7M instructions in); replaying the longer capture should show
the firmware computing the credit fields the menu digits are printed from —
the arithmetic whose absence was the whole R54-R56 hunt.

---

**R62 — the full-duplex composition draws the digit, and the real board ships.**
`m2_ioz80` joined the boot harness: real i960 and real Z80 firmware,
interlocking through the real flag/status protocol. The boot proceeds on the
firmware's own timing (first window read at 614,827 against the HLE's 521,763),
the exchange completes, and **`tram[1129] <= c033` at instruction 2,031,481** —
the credit digit, drawn through the genuine credit path, frame capture
confirming pixels on screen.

*Why full-duplex was necessary:* the half-duplex replay (R61's harness feeding a
captured game-side script on a fixed clock) broke the interlock — the game's
settings deposit landed before the firmware's input scan swept the window, which
looked like corruption and was only bad puppetry. A protocol has two live ends
or it is not being tested.

*Integration:* `Model2.sv` instantiates `m2_ioz80` with `USE_Z80=1` on the
DPRAM store; the behavioural exchange remains one parameter away as fallback.
The firmware arrives as MRA `<rom index="1">` (EPR-14869C, first 16 KB); the
Z80 is held in reset until the download completes, so a build without the
firmware behaves like a cabinet with the ROM pulled — loudly dead, not subtly
wrong. IN0 carries the OSD-mapped Coin/Start/Test/Service buttons in
model2.cpp's bit order; the ADC idles at centre/released. The board question —
do the digits appear on hardware — is now one flash away, and for the first
time the thing being flashed contains no imitated computers on the boot path.

---

**R63 — the digits are a protocol race, the reset was a misplaced menu line,
and the firmware's own code names the missing arbitration.** The day the real
I/O board went live on hardware (R61-62), three instruments converged:

*The digits.* The board's settings dword arrives in backup as **`7F FF 7F` —
the firmware's input-scan pattern**. The exchange is sequenced deposit ->
command -> firmware response -> copy-back, and the board's copy-back runs
before the response lands. The composition wins this race; the board loses it;
the difference is the game-side critical section stretched by real SDRAM
latency on top of our CPI 3.95 (R55's speed gap finally drawing blood against a
free-running peripheral). The formatter was exonerated by inspection -- pure
register arithmetic that cannot emit spaces -- and by a write-latch at the
SDRAM port.

*The firmware's testimony.* Its DPRAM primitives wait on status bits 0 and 3
with timeouts and a retry budget at work-RAM 0x5803 -- machinery for a real
MB8421's BUSY arbitration. Our 315-5338A model returns a constant 0x08, so
every wait passes instantly: the interlock the protocol was designed around
does not exist in our model. Window access costs the Z80 ~12us per byte through
the command interface, so refills take milliseconds and interleaving is normal;
the SEQUENCING, not byte atomicity, is what the status machinery protects.

*The reset.* Dead since the Z80 build -- and measured dead: a game-reset edge
counter ignored the OSD button entirely. The cause was the `J1` button line
placed between the two `R` items in CONF_STR, silently breaking parsing of
everything after it. Button definitions live at the END of the menu block; the
misplacement likely also meant Test/Coin/Start were never mapped at all.

*Next instrument, now unavoidable:* the composition with the real memory stack
-- m2_sdram, the x2 adapter, the behavioural SDRAM -- so the game side runs at
true latency and loses the race the way the board does. The fix (modelling the
BUSY/ready status honestly, or whatever the race demands once reproducible)
gets built against that.

**R64 — the contamination reproduces in simulation, and it is a phase, not a
latency.** The R63 instrument was built and run: the boot harness with
`REAL_MEM=1` swaps the C++ memory for the genuine stack — `m2_sdram_x2_harness`
whole (adapter + controller + behavioural device), the 43.62 MB image streamed
through the loader's write port with the i960 held, the CPU and char ports on
the stack's slow ports, the game side at true SDRAM latency. Two composition
traps cost a run each and are recorded because they will bite again:

1. **Nothing can be loaded on the divided clock while `rst_n` is low.** The
   stack's `clk_slow` divider is reset-gated; a firmware load issued during
   reset strobes a dead clock and writes nothing. The Z80 woke on an empty ROM
   and the game parked forever at the flag poll. Loads move after reset
   release, the Z80 held meanwhile by `fw_ready=0`.
2. **p0 is the only read/write slow port.** The CPU was first placed on
   read-only p1 — `p1_we` does not exist — so every RAM write vanished
   silently. The game ran 686K instructions on ROM and on-chip state alone,
   then trapped fetching an interrupt vector from RAM nothing had written:
   PRCB+20 read zero, handler address `ffffffff`. The tb's flight recorder
   (last 64 bus transactions, dumped at first trap) is what caught it, and it
   stays.

With the composition honest, the result overturned R63's mechanism: **the 7F FF
copy-back reproduces in BOTH memory models** — identical `SET WR` sequences at
fast and true latency — so the determinant is not the game-side critical
section stretched by SDRAM. It is the **Z80's start phase relative to the
game**. Firmware mid-initialization when command 03 arrives: the flag clears
after a ~93K-instruction wait and the window is served as the input-scan
pattern `7F FF 7F FF…` — byte-for-byte the board's backup capture. Firmware
long-idle (the warm-boot runs): the response is immediate and clean, and the
race never existed.

And the second overturn: **contamination alone does not blank the digits.**
The game validates the block, rejects the garbage, writes defaults
`01010100`/`00030300` at ip `0x227d60`, deposits them back to the firmware
(commands 01/02), re-reads them clean in a later exchange, and the attract
text renders — tram `8043` ('C') and `c033` ('3') at instruction ~2.03M, in
both memory models, 198 V-blanks at true pacing. The board blanks exactly
these characters. The board's own ordering was then replicated too
— firmware arriving last, the game already parked on the exchange
(`M2_FWLATE=1000000`) — and it ALSO recovers and renders. Every simulated
ordering recovers; the board does not. The live hypothesis follows from the
board's probes: row 23 read the settings dword as `02FF017F`, defaults and
scan bytes INTERLEAVED, which is the signature of ongoing re-contamination
rather than a single lost boot exchange. The game re-runs the exchange every
few frames forever; each one can race; one poisoned copy-back after attract
begins blanks the digits on the next redraw. The sims stopped one clean
exchange after recovery. Deep runs (6M instructions at true latency, 12M at
fast pacing) found no such thing: the repeating traffic is the input-scan
poll, not a settings re-read, and only two settings exchanges occur in a
12M-instruction run. The re-contamination theory is unsupported.

**The exchange is then exonerated outright.** The Z80's arrival phase was
swept across three orders of magnitude — `M2_FWLATE` at 0, 50K, 200K, 400K,
600K, 614K (mid-exchange), 620K, 700K, 1M and 2M instructions. **Every one
of the ten contaminates, and every one recovers and renders**: `tram[1129] =
c033`, `tram[1130] = 8043`, unchanged across the sweep. There is no phase in
which the game fails to repair the block. Whatever blanks the board's
characters, it is not this race, and R63's digit mechanism is now closed as
a cause even though the contamination it identified is real.

What the composition positively proves, from the same runs: the renderer
draws Daytona's GAME ASSIGNMENTS menu correctly at true latency — white
labels ("ADVERTISE SOUND", "COUNTRY") with green setting values, on a
496x384 frame captured while the CPU runs. Font, tilemap, palette, colour
translation, the char CDC and the settings path all work end to end in
simulation. The board's fault is therefore in something simulation does not
yet model, and the remaining asymmetries worth attacking are hardware-only:
the fitted timing of the char and backup paths, and the board's own probe
readings (`02FF017F`) which no simulated run reproduces.

Eliminated by inspection in the same pass, so they are not re-run: the char
CDC has no drop path at all (a four-phase handshake that stalls, never
discards); line overruns are counted and the board reports zero; the NVRAM
HPS write port is correctly gated (`ioctl_download && index==2 && ioctl_wr`)
so it cannot steal a CPU write; and `m2_backup` is wired identically in
Model2.sv and the boot harness, both clocked in the bridge's domain.

Bench honesty items from the same session: the DPRAM dialogue logger read the
even byte for both halves of a word (fixed — historical R-lines in dialogue
captures double the even byte); the harness verdict now tests the real
criterion (a copy-back carrying 7F/FF is the race reproduced); and the
behavioural SDRAM's unwritten cells return `DEFAULT_DATA = '0`, which violates
the unwritten-reads-`0xFFFF` rule — masked today because the streamed image
covers the space, open as a model gap.

**R65 — the Test button path is correct, the DIPs are a dead end, and the
analog readout is off by one bit.** Three results from putting MAME's own
input tables next to the Z80 board, taken because the TEST and SERVICE
buttons do nothing on the board and the request was for DIP switches instead.

*The DIPs would not have helped.* `mame daytona93 -listxml` defines three
banks — `ioboard:dsw1`, `dsw2`, `dsw3` — and **all twenty-four bits are
"Unused"**. There is no self-test DIP on this game; test mode is the TEST
switch. Wiring DIPs into the OSD would produce a menu that does nothing.

*The bit map was already right, and so is the whole path.* MAME's `IN0`:
0x01 Coin 1, 0x02 Coin 2, **0x04 Service Mode (the TEST switch)**, 0x08
Service 1, 0x10 1P Start, 0x20/0x40/0x80 VR1-3; `IN1` bit 0 is VR4. Our
`iob_in0` places Test at bit 2 and Service at bit 3, which matches. The
oracle for the rest: MAME's DPRAM byte 0x08 reads `FF` idle and `FB` with
Service Mode held, and byte 0x09 reads `8F`. Driving our own board with
`in0=FB` through the real firmware produces **`dp[0x08] = FB`, `dp[0x09] =
8F`** — identical. The game polls byte 0x08 (it appears as `R 008 ff` in
every dialogue capture). So controller bit -> port -> firmware -> DPRAM ->
game is proven end to end in simulation, and a non-working TEST button on
the board is not an RTL fault. The remaining candidate is the MiSTer side:
a core whose buttons have never been assigned in "Define buttons" has no
J1 mapping at all.

*The game receives it too, and still does nothing.* Driving the whole
composition with `in0=FB` from reset: the game reads DPRAM byte 0x08
**forty-four times and gets `FB` every time**, and its execution is
byte-for-byte identical to the released-switch run -- same instruction
count, same tram writes, same pixel total. So the switch reaches the game
and the game ignores it. The likely reason is that it is ALREADY in test
mode: the frame capture is the GAME ASSIGNMENTS screen, which the game
forces when its settings fail validation, so holding TEST inside the menu
changes nothing visible. Simulation therefore cannot discriminate further,
and the board needs an instrument instead -- overlay row 23, page 1, Probe
"bootIP" now shows {raw in0, the byte the firmware deposited, scan count},
which separates "the press never reaches the core" from "the firmware is
not scanning" from "the game is ignoring it".

*And the analog channels are shifted.* Same comparison, bytes 0x00-0x07:
MAME idle reads `80 20 20 ...` (steering centred, pedals released) where
ours reads `00 40 40 ...`. Every value is its MAME counterpart shifted LEFT
by one — 0x80 becomes 0x00, 0x20 becomes 0x40. The MSM6253 model in
`m2_ioz80.sv` returns `adc_shift[7]` and shifts once on `rd_end`, which on
inspection matches msm6253.cpp exactly -- so the extra shift comes from
somewhere else, most likely a dummy read the firmware issues while waiting
for the conversion, which our model consumes as a data bit and the real
chip does not. THE MECHANISM IS NOT PINNED, so nothing is changed here:
the reference source wins over a plausible edit, and an unverified "fix"
to a shift register is exactly how an off-by-one becomes an off-by-two.
Recorded with its evidence for whoever has the msm6253 datasheet open.
Nothing depends on it yet because steering has never been exercised, but
it would put the wheel hard over and both pedals off-centre the moment it
is.


**R66 — the blanking is measured on the board, the window contents are wrong
against MAME, and the late-firmware explanation is dead.** The board finally
answered the question simulation could not, through the tram cell probe of
R65's build.

*The measurement.* With the characters visibly gone, cell 1130 reads
`046A8020` -- the cell index 0x46A followed by **0x8020, a SPACE** -- and the
live settings dword reads contaminated at the same moment. So the digits are
written correctly, displayed, and then OVERWRITTEN. The board's own words:
"the text appears (CR, 3) for a microsecond, then the test menu arrives, then
disappears." This retires two theories at once: the font is not missing the
glyphs, and the render path is not dropping the cells. Something rewrites
them with spaces once the settings go bad.

*The window is wrong against the oracle.* MAME's DPRAM window 0x100-0x17f
holds the game's own deposited block -- `53 45 47 41` ("SEGA"), the identity
bytes, then the settings `00 01 01 01 00 03 03 00` -- and it is byte-for-byte
STABLE across hundreds of frames. Ours fills the same window with `7F FF`
repeating, which is the Z80's power-on RAM test pattern. So our I/O board
writes over the game's settings block where the real one leaves it alone.
That is a genuine divergence from the reference and it is the best lead the
project has on the digits.

*But the reset-ordering explanation for it is wrong, and it was tested rather
than assumed.* The theory was that our Z80 leaves reset only when `fw_ready`
latches at the end of the firmware download, which the MRA sends LAST, so the
board's Z80 wakes seconds after the i960 has drawn the menu and wipes the
window underneath it. Delaying the firmware to instruction 3,000,000 -- past
the point where the digits are drawn in a normal run -- does NOT blank them:
the game simply draws later (4.97M instead of 2.03M) and renders correctly.
**The game blocks at the I/O poll until the board answers**, so the ordering
is self-correcting and no firmware arrival time can produce the symptom.
`cpu_rst_n` is therefore NOT gated on `fw_ready`, and the one-line change that
looked obvious would have fixed nothing.

*Also corrected:* R64's claim that simulation never blanks the digits was an
artifact of stopping too early. A 40M-instruction run rewrites both cells with
`8020` at instruction 15,906,364 (ip 0x18dd0), both in the same instruction --
a bulk clear, consistent with the normal menu teardown on the way to attract
rather than with the board's selective fault, but the claim as stated in R64
was wrong and runs must now go past 16M to say anything about blanking.

*The window counter was read, and it cannot settle the question -- but it
corrects a misreading that R63 and R64 were partly built on.* Page 1 / Probe
"chr A" returned `05FF017F`: reset edges 5, window write count **0xFF
SATURATED**, last window address 0x17F. The counter is 8 bits and two
legitimate 128-byte exchanges reach 255 on their own, so saturation proves
nothing about whether the Z80 keeps rewriting the window during play.

More importantly: **the board's earlier `02FF017F` reading was THIS register,
not the settings dword.** It decodes as reset edges 2, the same saturated
window counter, the same last address 0x17F. The reading of it as "defaults
and scan bytes interleaved in the settings" -- the observation the
re-contamination theory in R63/R64 rested on -- was a misattribution of a
probe value, and no board measurement of interleaved settings bytes has ever
actually been taken. The lesson is the one R65 already paid for once: a probe
whose row is shared must carry its own identity, or its readings will be
attributed to whatever theory is current.

*The instrument that does settle it.* MAME holds `00 03 03 00` at window
offsets 0x114-0x117 and holds it stable; the question is what OUR firmware
deposits there. Row 23, page 1, Probe "chr 3" now latches those four bytes as
the Z80 writes them: `00030300` means the firmware writes real settings and
the window is exonerated, `7FFF7FFF` means the RAM-test pattern is landing on
the game's settings block. Unlike the counter it cannot saturate into
ambiguity, and unlike the previous rows it is a direct comparison against a
known oracle value.


**R67 — the window is CLEAN and the backup is not, so the corruption is in
the copy, and R63's original mechanism is back.** The instrument built at the
end of R66 was read on the board: window offsets 0x114-0x117, latched as our
Z80 writes them, return **`00030300`** -- byte-for-byte what MAME's real
machine holds. Our firmware deposits correct settings. The window is
exonerated, and with it the RAM-test-clobber theory that R66 called the
project's best lead.

What that leaves is sharper than anything before it, because two measurements
now bracket the fault from both sides:

  the firmware's side of the window   00030300   correct (this entry)
  the game's side, in backup SRAM     7F FF 7F   contaminated (R63)

The same block, correct where the firmware writes it and corrupt where the
game files it. **The corruption is therefore in the copy-back itself, and it
is a timing fault, not a data fault**: the game reads the window BEFORE the
firmware has refilled it, picking up whatever the previous occupant was -- the
`7F FF` RAM-test pattern -- and writes that to backup. The firmware then fills
the window correctly, which is why a later probe of the window shows clean
settings while the digits stay blank. That is exactly the sequencing race R63
described (deposit -> command -> firmware response -> copy-back, with the
copy-back beating the response), and it survived being written off in R64.

Why R64 was wrong to retire it: the phase sweep showed the composition
recovering in all ten orderings, and the conclusion drawn was "the exchange is
exonerated". But the sim WINS this race and the board LOSES it, so a sweep of
sim orderings could only ever show recoveries. Exonerating a race on evidence
that cannot exhibit it was a mistake in reasoning, not in measurement.

*Where the interlock actually lives, and the next measurement.* The game's
guard is the flag/status handshake at DPRAM 0x20/0x21: write command, wait for
the firmware to answer, then copy. With `USE_Z80=1` the HLE flag machine is
silenced and the real firmware drives it, so the question is whether the game
is seeing a flag that says "ready" too early -- a stale or wrongly-returned
status read letting it proceed before the refill. The live backup settings
dword (row 23, page 1, Probe "chr0" -- backup word 5, the dword the digits are
printed from) must be read and reported as an exact value to confirm the
bracket above from the board rather than from R63's older capture.


**R68 — everything upstream of the tilemap is CLEAN, and the fault is between
the formatted string and the tile cell.** Four board measurements in sequence
finally bracket it to one step:

  backup settings dword (page 1, "chr0")     00030300   correct
  firmware's window bytes (page 1, "chr 3")  00030300   correct, matches MAME
  formatter's own store (page 1, "row2")     cnt 0x3C, data 3131 -- ASCII "11"
  tile cell 1130 (page 0)                    8020       A SPACE

The settings are right, the I/O board is right, and the formatter is writing
genuine digit characters into the string buffer -- sixty times over. The value
becomes 0x20 only between that buffer and the tile cell.

**This retires every theory this project has held about the digits.** The
exchange race (R63), the window clobber (R66), the reset ordering (R66), the
copy-back corruption (R67) and the render path dropping cells (R64/R65) are
all upstream of the measured-clean boundary. R67 in particular is wrong on its
own evidence: it argued the copy-back stores garbage, which would mean the
digits never appeared at all -- but the board SHOWS them for a moment before
they vanish, which requires good settings at the first draw. That observation
came from watching the screen, not from any probe, and it falsified a
conclusion three instruments had failed to touch.

*What is left, and why it is a better question.* The remaining step is the
draw: the routine reads the formatted string back out of work RAM and writes
character codes into tile RAM. The question is no longer "which value is
corrupt" but "which instruction writes the space", which is directly
observable rather than inferred. Build 284074ce latches the CPU's IP at the
moment a space is written into the probed cell, with a count and the value:

  page 1, Probe "chr #"   {count, value} -- a count of ZERO is the decisive
                          case: nothing ever wrote a space, so tile RAM is
                          being corrupted without a write and the fault is in
                          the memory holding it, not in any code
  page 1, Probe "chr 1"   the IP that wrote it. 0001CDDC or 0001CE38 is the
                          same routine that drew the digit, and the bug is in
                          what it reads back; any other address names code
                          clobbering a cell it never drew

*Standing lesson, now paid for twice in one session.* Both of this session's
real breakthroughs came from the screen, not the probes -- "it shows for a
split second" and "CR, 3 appear then disappear". Probes answer the question
they were built for and are silent about the one that matters. R65's orphaned
probe and R66's misattributed register are the same failure from the other
direction: an instrument trusted past what it actually measures.


**R69 — the blanking is CORRECT BEHAVIOUR: MAME does it too, and R68 is
retracted.** The oracle was finally asked the right question -- not "what is
in the window" but "what does the real machine hold in these very cells, over
time". Reading MAME's tile RAM every 120 frames:

  frame 120   1129=c033  1130=8043  1131=8052  1108=8043   the glyphs
  frame 240   1129=8020  1130=8020  1131=8020  1108=8020   ALL SPACES
  frame 360   8020 throughout, and so on

**The real machine blanks the same four cells, to the same value, on its own.**
The clear at ip 0x18DD0 that the board reported and that our own 40M run
reproduced is the game tearing down the menu, and our core matches the
reference exactly. There is no fault at 0x18DD0, no fault between the
formatted string and the tile cell, and R68's conclusion is withdrawn in full.

*What went wrong in the reasoning, because it is the fourth time this session.*
Every tile-cell reading was taken AFTER the characters had vanished -- that is
when the board is easiest to read. But those cells are legitimately blank then,
in MAME and in our core alike, so the measurement could only ever return 8020
and could never distinguish healthy from broken. The probe was sound; the
sampling moment made it meaningless. R65's orphaned probe, R66's misattributed
register, R67's theory that contradicted the screen, and now this: four
distinct ways to be confidently wrong with a working instrument.

*What the digits question actually requires.* The characters must be compared
WHILE the menu is displayed -- MAME's frame 120, not its frame 240. Our own
composition already renders that screen correctly at true SDRAM latency
(R64's frame capture: white ADVERTISE SOUND / COUNTRY with green values), and
MAME holds the glyphs at the same point. So RTL and reference agree, and the
divergence is the BOARD's alone.

*The live hypothesis, and it is cheap to test.* Overlay row 20 read `00001204`
on the board. Per its own definition, bits 5:0 name which of CL+0..CL+5 read
the pattern back: `04` is a SINGLE working depth out of six. The SDRAM read
interface has no margin at all, and marginal reads corrupt some fetches and
not others -- which is exactly what "a few characters are missing while the
rest of the text is fine" looks like. The OSD already exposes `SDRAM phase`
(Auto, CL+1..CL+5) precisely so this can be walked by hand. Stepping it and
watching whether the missing characters change is a free experiment with a
real chance of ending this, and it should be done before any further
instrument is built.


**R70 — the RTL renders the screen CORRECTLY against the MAME reference image,
so the fault is the board's alone.** The claim in the previous session note
that simulation reproduced the missing characters was an artifact of the
capture moment and is withdrawn. Captured at frame 56 the menu is
part-drawn -- COUNTRY two scanlines tall, CABINET and DIFFICULTY absent, the
green '3' missing -- because the game draws it progressively. Captured at
frame 103, against MAME's reference at frame 130, our composition renders:

  ADVERTISE SOUND  ON / COUNTRY  JPN / CABINET  DELUXE / DIFFICULTY  NORMAL
  CREDIT TO START      3CREDIT(S) / COIN/CREDIT SETTING  # 1

-- complete, with the green '3' present, matching the reference. That is the
same sampling-moment error as R69, made twice in one session with two
different instruments.

*What this positively proves.* Settings, I/O firmware, the exchange, the
formatter, backup SRAM, tile RAM, the font, the palette, the colour
translation table and the renderer are correct TOGETHER, end to end, checked
against a reference image rather than against expectations. Line overruns
measure ZERO in the same run, so the fetch budget is not tight either. No
value anywhere in the chain is wrong.

*Which leaves board-only causes, and one is already indicated.* The same RTL
misbehaves on hardware, so the difference is something simulation cannot
model:

 1. **SDRAM read margin.** Row 20 reads `00001204`: one working capture depth
    out of six, and the board shows NO PICTURE AT ALL in any other phase. The
    tilemap lives in on-chip M10K and probes correct; the GLYPH data is
    fetched from SDRAM. A marginal fetch corrupts some characters and not
    others while leaving every probed value clean -- which is precisely the
    symptom and precisely why every probe came back healthy.
 2. **Memory inference.** Per the standing rules, simulation cannot see
    whether an array landed in M10K or in logic. Only a build can.

*The measurement that discriminates, already built.* Overlay row 22 latches
THE LAST CHARACTER FETCH verbatim. Read while characters are missing:
FFFFFFFF means the fetch is reading memory nobody wrote, varied data means
real glyphs are arriving and the fetch path is sound. That single reading
separates cause 1 from everything else, and it has never been taken while the
fault was visible.

**R71 — Quartus warns that the tilemap and palette RAMs have UNDEFINED
read-during-write on hardware, and the CPU writes them during active display
90% of the time.** Chasing why tile RAM fits as two 32768x16 arrays produced a
finding worth far more than the duplication itself.

*The duplication is not the debug probe.* That theory was tested and failed:
the probe's read was replaced with a write-observer (no port, no array read),
and tram still fits as `tram_rtl_0` and `tram_rtl_1`, 64 M10K each. The cause
is structural -- TWO reads of the same array in two clock domains, the
renderer's on `clk_vid` and the CPU's on `clk_sys` -- and Quartus builds one
simple-dual-port RAM per read port. The write-observer is kept anyway: it is
the right pattern for instruments and costs nothing.

*The finding that matters is the synthesis warning:*

    Warning (276027): Inferred dual-clock RAM node "emu:emu|tram_rtl_0" ...
    The read-during-write behavior of a dual-clock RAM is UNDEFINED and may
    not match the behavior of the original design.

The same warning is raised for `pal_rtl_0`. Set that beside a measurement this
project already had and never connected to it: **90-91% of all tilemap writes
happen during ACTIVE DISPLAY** (37,693 during display against 3,990 in
V-blank). The CPU is writing the tilemap while the renderer reads it, almost
all the time, through a RAM whose behaviour in exactly that circumstance
Quartus declares undefined on silicon and which Verilator models as
well-defined.

That is a genuine hardware/simulation divergence, flagged by the tool itself,
sitting on the path that produces the picture -- and it is invisible to every
simulation this project runs, which is precisely the class of fault the
standing rules warn about ("simulation cannot see memory inference").

*It is not yet proven to be the cause*, and the honest counter is that the
board's flat-colour attract screen points at the CHARACTER fetch rather than
the tilemap. But undefined read-during-write on the tilemap and palette would
corrupt tile indices and colours intermittently and positionally, which is the
shape of the fault, and it costs nothing to make defined: give the arrays
explicit read-during-write handling, or move the CPU's tilemap read off the
shared array (measure first whether the game reads tile RAM at all -- if it
only writes, the second read port and its 64 M10K disappear with it).


**R72 — the video moves onto clk_sys, which makes the tilemap's
read-during-write DEFINED, and a 64 KB glyph cache takes SDRAM out of the 2D
render path.** Four changes from one question: can the two clocks be related?

*They can be removed.* clk_vid ran at 32 MHz with ce_pix at half that -- 16 MHz
pixels. **48 / 3 = 16 MHz exactly**, so clk_sys reaches the same pixel rate with
a one-in-three enable and the second clock is unnecessary. The renderer, the
overlay and the timing generator now all run on clk_sys. Synthesis confirms the
consequence: `tram_rtl_0` and `pal_rtl_0` NO LONGER APPEAR among the
`Warning (276027)` dual-clock RAMs. Tilemap and palette read-during-write is
defined behaviour on silicon now instead of undefined, the clk_vid-to-memory
crossing no longer has to be cut in the SDC so those paths are timed, and the
fetch engine gets 1.5x more cycles per scanline.

*R71's supporting statistic was empty, and this retires it.* "90% of tilemap
writes land during active display" was read as evidence the CPU fights the
renderer. But V_VISIBLE=384 of V_TOTAL=424 makes blanking **9.4% of the
frame**, so a writer that ignores blanking measures 90.6% by arithmetic alone.
The timing matches MAME's set_raw exactly. The number says nothing about the
game and never did; the dual-clock hazard was real, the evidence offered for
its severity was not.

*The glyph cache.* Glyph pixels were the only part of the 2D path still read
from SDRAM, and the pattern is 9,084x redundant (71.6 M fetches, 7,883 distinct
words, 985 KB span). `m2_char_cache` holds 16,384 words -- 64 KB, sized with
headroom over the 30.8 KB measured rather than fitted to it. Direct-mapped, one
word per line, valid bits carried in the tag RAM and swept at reset. Its
testbench: 10,128 reads with ZERO wrong, 100% hit on warm data, **96.7% on the
real glyph access shape**, and correct data under deliberate conflict
thrashing. Live hit/miss counters ship with it so the size is revisited against
evidence.

*And the overlay is off by default* (`O[19]`), which it should always have
been: 24 rows of hex painted over the top-left of the picture, exactly where
the game puts its own text.

*What this does NOT yet claim.* None of it is proven to fix the board. The
flat-colour attract screen points at the character fetch, and the cache changes
that path radically -- 9,000x fewer SDRAM transactions, served from on-chip
memory in the renderer's own clock domain -- so if the fault is in the fetch or
its crossing, this is the change most likely to move it. If the board still
renders two flat colours afterwards, the fetch is returning bad data at the
source and row 22 is still the reading that says so.

*Self-inflicted, recorded so it is not repeated:* the first build of this failed
because the new module was created but never added to `Model2.qsf`. Quartus does
not glob; a new RTL file is invisible until the project lists it.

**R73 — the UART channel found it in two captures: the tilemap is the fault,
not the glyphs.** The core got a serial printf (R72's transmitter, wired to two
tagged channels) and it produced more usable evidence in five minutes than the
overlay produced in a day.

*Capture 1, 30 seconds at the flat-colour attract screen:* 7,172 character
fetches, **every one returning 00000000**, across **eight distinct addresses**.
No CPU writes to the character region in that window.

*Capture 2, across a full core reload:* **82 W lines** -- the CPU DOES upload
character data, and it is non-zero (`00001991`, `00006786`, `00003146`). The
"never written" reading from capture 1 was a window that began long after boot.
Across the whole boot the renderer requested **twelve** addresses: offsets
0x0-0xE and 0x30000-0x3000E from GAME_CHAR.

*The conclusion, and it retires the entire glyph investigation.* Simulation
fetches **7,883 distinct character words** rendering the same screen. The board
fetches twelve. The renderer is not reading the wrong data -- it is being told
to draw **tile 0 and one other tile, everywhere**, and tile 0's glyph is
legitimately blank, so it faithfully paints one flat colour per palette bank.
The character fetch, the CDC, the cache, the SDRAM path and the decode were all
working correctly the entire time, on a tilemap that contains almost nothing.

That is why every glyph-side change landed without effect (R72's cache, the
single-clock move), and it explains the one thing that never fitted: the tile
cells probed at the MENU held correct values (8020, c033, 8043) while attract
shows nothing. The menu's tilemap is written correctly. The attract screen's is
not.

*What the channel is worth, recorded because the lesson is bigger than the bug.*
The overlay shows eight hex digits, of one value, at the moment someone is
looking. It produced four wrong conclusions in a day: two values attributed to
the wrong probe, two read at a moment when the value was legitimately something
else. The serial channel showed 7,172 events with addresses AND data AND
ordering, and answered in one capture a question six builds had failed to
settle. `docs/mister-integration.md` had said it was available; CLAUDE.md's
summary said "No serial", and the summary is what governed.

*Next:* channel A repointed from character writes to TILEMAP writes
(`ocb_tram_we`, tagged 'T'), which shows directly what the CPU puts in the map
and whether the attract screen's tilemap is ever written at all.

**R74 — the CPU writes zeros into the tilemap because what it READS is zero.
The renderer was never at fault, and neither was the tilemap.** The serial
channel, once its two self-inflicted faults were fixed, gave the answer in one
capture.

*The measurement.* 4,185 sampled tilemap writes across a boot:

  00000000   4,175 times
  00003000       3      (tile 12288 -- simulation's top background tile)
  00000020       3      (tile 32    -- simulation's most common index)
  00008020       2
  00003D8D       2      (tile 15757 -- simulation's third)

The CPU writes the CORRECT values when it has them, and zeros the rest of the
time. Simulation fills 12,289 non-zero cells over 1,651 distinct indices; the
board writes ~99.8% zeros. Every subsystem downstream -- the renderer, the char
fetch, the glyph cache, the tilemap memory, the palette -- was working
faithfully on data that was zero before it ever arrived.

*Two instrument failures that each looked like a finding, recorded because they
cost more than the bug.* The channel first reported ZERO tilemap writes across
a full boot, which read as "the game never writes the map". It was a single
shared throttle: character fetches fire thousands of times a second, tilemap
writes rarely, so the fetches took every slot and the writes were counted as
drops. Then, tapped combinationally onto `ocb_tram_we`/`ocb_addr`/`ocb_din`,
the streamer loaded the tilemap WRITE path into the M10K and the board went
BLACK -- intermittently, rendering on the first boot after that build and not
on later ones. Restoring the previous core brought the picture back, which is
what identified it. The streamer already refused to STALL, on the principle
that an instrument must not change what it measures; the same principle applied
to fanout and had not been honoured. The tap is now registered.

*Where the fault must be.* One step further upstream: whatever the game reads
to build its tilemap returns zero on hardware and real data in simulation. That
is the same shape as the character region -- correct addresses, correct code,
empty source. Channel A now latches every CPU read and, on a tilemap write of
zero, emits the address and data of the read that preceded it. That converts
"the map is blank" into "the CPU read <address> and got <value>", which names
the region instead of the symptom.

**R75 — the CPU's read path is PROVEN GOOD, and the board is looping in the
I/O board command routine.** A night of serial-channel work, with the fault
narrowed from "a dozen subsystems" to one routine.

*The read path is not the fault, and this is measured, not argued.* Ten CPU
reads of the ROM mirror were captured on hardware and compared against the ROM
image byte for byte:

    sd word 17878 -> 58A3D090   ROM 58A3D090   MATCH
    sd word 14388 -> 8C803000   ROM 8C803000   MATCH
    sd word 14220 -> 80A03000   ROM 80A03000   MATCH
    ... 10 of 10 correct

So the bridge, the arbiter, port 1 and the ROM-mirror translation all work.
That kills the "32-bit reads lose their low halfword" hypothesis, which had
fitted the two numbers available at the time (0x80000000 survives, 0x00000300
becomes 0) and was wrong.

*Where the board actually is.* The hottest read by far -- 3,110 of 4,129 in a
90-second capture -- is i960 `0x0022F0F0`, a subroutine MAME's trace shows
being called from `0x00228700`, immediately after `setbit 7,0,g2`. That is the
**I/O board command path**, the same 0x2287xx/0x2288xx region as the settings
exchange. The board also reads `0x228430`-`0x22843C` repeatedly, whose operands
include `0x01C00040` -- the I/O board flag address.

*What that suggests, and it is not yet proven.* R63 found the settings exchange
returning the firmware's `7F FF` input-scan pattern instead of settings. The
composition recovers from that; the board may instead RETRY FOREVER. That would
produce exactly what is observed: the game never completes initialisation, the
allocator's later work never happens, block sizes stay zero, the loop at
0x1BA8 gets a bound of zero, and nothing is ever drawn. The exchange
contamination would then be the root cause after all -- not of missing
characters directly, but of the game never getting past setup.

*The chain, with every link now measured:*

    I/O board command loop (3,110 calls)   <- the board sits here
      -> allocator's descriptor work never completes
      -> block size field stays 0        (board 0, sim 0x80)
      -> pointer at 0x501224 wrong       (board 0x511000, sim 0x505100)
      -> loop bound at base+8 is 0       (board 0, sim 0x300)
      -> the 0x1BA8 loop never finishes
      -> no drawing routine ever runs
      -> two flat colour tiles

*Instrument failures, recorded because they cost more than the bug did.* Three
in one session. A shared throttle starved the channel that mattered and
reported ZERO tilemap writes across a boot, which read as a finding. Then a
comparator hung on the tilemap write bus blacked the screen. Then a comparator
hung on `cpu_sd_addr` blacked it again -- 0.358 ns of slack does not survive a
25-bit magnitude compare on a live bus. **STANDING RULE: never tap a live bus.
Register it, compare a cycle later.** Both black screens and one worthless
capture came from ignoring that.

**R76 — the I/O board firmware MULTIPLEXES its input ports between the cabinet
controls and the board's OWN DIP switches, and this core implemented only half
of it.** The board selects the DIP banks 24,948 times in 60 seconds on
hardware, and every one of those returned controller state instead.

*The mechanism, from four independent sources.* The 315-5338A's port A bit 0 is
a control switch, and every input the firmware reads is selected on it:

    // model1io.cpp, io_pa_w
    // -------0  control switch (0 = first, 1 = second)
    m_secondary_controls = bool(BIT(data, 0));

    uint8_t model1io_device::io_pb_r()
    { return m_secondary_controls ? m_dsw[0]->read() : m_in_cb[0](0); }
    // io_pc_r -> m_dsw[1], io_pd_r -> m_dsw[2], and analog0_r..analog3_r
    // likewise swap an_cb[0..3] for an_cb[4..7]

`model1io.h` carries `required_ioport_array<3> m_dsw`: **the I/O board has three
8-way DIP switches of its own, which are not the game's.** Daytona defines all
24 bits `PORT_DIPUNUSED_DIPLOC(mask, mask, ...)` -- the default equals the mask
-- so **each bank reads 0xFF**. `in_callback<2>` and `an_callback<3..7>` are
never bound for `model2o`, and an unbound `devcb_read8` also reads 0xFF.

*The firmware says so itself, independently of MAME.* EPR-14869C contains a
matched pair of routines, and `IY` points at the 315-5338A, so `(IY+0)` is
port A:

    07F9: PUSH AF          ; select PRIMARY controls
    07FA: LD  A,(IY+0)
    07FD: AND FEh          ; clears bit 0
    07FF: LD  (IY+0),A

    0807: PUSH AF          ; select SECONDARY controls
    0808: LD  A,(IY+0)
    080B: OR  01h          ; sets bit 0
    080D: LD  (IY+0),A

This matters because it is evidence from the silicon's own program rather than
from a model of it, and because simulation had said the opposite: the standalone
I/O harness ran 40 M cycles, wrote port A 5,890 times, and selected secondary
**zero** times -- the routine is only reached through the game-side dialogue the
standalone harness does not have.

*What the board was doing.* `m2_ioz80.sv` returned `in0`/`in1`/`in2`
unconditionally and its own header recorded the gap -- "DSW1-3 when the firmware
selects secondary controls -- **deferred until the game's own INPUT TEST screen
can serve as the oracle**". The oracle arrived from the UART instead. DPRAM
0x100, which holds `53 45` ("SE" of "SEGA"), was caught alternating with
`7F FF` -- an idle analog reading and an idle digital one, i.e. the SCAN pattern
written where the settings belong. That is R63's `7F FF`, now with a mechanism.

*What was ELIMINATED on the way, all by measurement:*

  - **The DPRAM wiring is correct.** `model2.cpp:1279` maps the i960 to the
    mb8421's RIGHT port at `0x01c00000` with `umask32(0x00ff00ff)`, and the
    ioboard's read/write callbacks to `left_r`/`left_w`. That is exactly this
    core's arrangement.
  - **The 315-5338A command set is correct.** Command `0x87` is a documented
    no-op in the reference ("sent after setting up the address and when wanting
    to receive serial data"), there is **no address auto-increment**, `0x0c`
    reads at the latched address, and `0x0d` returns a constant `0x08`. The
    suspicion that `0x87` armed something we ignored was wrong.
  - **There are no DPRAM collisions.** A hardware capture across a boot counted
    64 game-side window accesses, 64 Z80 writes and **zero** collisions. The
    "both sides colliding in silicon" theory is dead, and with it the reason to
    hang an MB8421 BUSY signal off a 5338A status bit that the reference
    documents as "command acknowledged".
  - **The CPU is not trapping.** `cpu_trap` reads 0 throughout. Note also that
    `T_TRAP` sets `halted` and self-loops, so `trap` LATCHES: it can fire at
    most once, and any count of its edges above one is an instrument artifact.

*Instrument failures, again worth more than the bug.* Three more, all of the
same family -- the instrument reporting something other than what it claimed:

  - The capture assigned its payload (`rd_ad`/`rd_dt`) **unconditionally** every
    cycle while strobing on `rd_v || trap_edge`. A trap therefore printed
    whichever address merely happened to be in flight. 128 lines of a flag poll
    wore a window read's clothes and were nearly read as a finding. **The
    payload must be gated by the same condition that raises the strobe.**
  - Channel A's "priority" in `m2_dbg_stream` only applies when the UART is
    IDLE. A channel firing thousands of times a second means it never is, so
    the prioritised channel was starved to **zero** lines -- which would have
    read as "the game never touches the window". Same failure as the earlier
    shared-budget starvation, in a new costume. Telemetry that fires constantly
    must be a HEARTBEAT carrying cumulative counts, not an event.
  - A stale bitstream was deployed and measured: `tools/deploy-mister.sh` copies
    `build/release/Model2.rbf`, and `make release` had not been re-run, so the
    board received a core 25 minutes older than the one just built. **Verify the
    deployed md5 against `output_files/` every time**; the deploy's own "OK"
    only proves the copy matched its source.

*Status: NOT YET PROVEN.* The multiplex is implemented, the DIP banks are wired
to 0xFF as ports (so a game that uses them can drive them), the full simulation
suite passes, and the change is provably inert wherever secondary is not
selected. Whether it restores the settings block, and with it the attract
screen, is the next measurement -- not a claim this entry is entitled to make.

**R77 — the MSM6253's shift was two events where the reference has one, and
every analog byte the I/O board produced was its input SHIFTED LEFT BY ONE.**
R65 recorded an "ADC off-by-one" and deliberately left it unfixed pending a
verified mechanism. This is that mechanism, and the fix is confirmed against
the reference byte for byte.

*How it was found: the same firmware, measured on both machines.* MAME's I/O
board deposits its input scan at DPRAM 0x00-0x0d, and those bytes are exactly
knowable. Ours were captured off the board over the serial channel. Eight
independent bytes, one relationship:

    DPRAM   board  MAME   fed in
    0x00     00     80    0x80    steering
    0x01     40     20    0x20    accelerator
    0x02     40     20    0x20    brake
    0x04-07  FE     FF    0xFF    the secondary analog bank

`0x80 << 1 = 0x00`, `0x20 << 1 = 0x40`, `0xFF << 1 = 0xFE`. The first read
returned bit 6 instead of bit 7, so one shift happened between the channel
latch and the first read.

*The cause is structural, not arithmetic.* The old code emitted
`adc_shift[7]` combinationally and shifted on the read's TRAILING edge --
**two events that have to agree exactly once per read, and did not.** The
reference makes them a single indivisible act:

    bool msm6253_device::shift_out() {
      bool msb = BIT(m_shift_register, 7);
      m_shift_register <<= 1;      // consumed by the act of taking it
      return msb;
    }

So capture and shift now happen on the SAME edge -- the read's leading edge --
and the bit is held for the rest of the strobe. Under CEN pacing the Z80
samples many cycles after the strobe rises, which is the assumption the
registered ROM and RAM reads in the same file already rest on.

*Also corrected:* `an_callback<3>` is never bound for this game, and an unbound
`devcb_read8` reads 0xFF, so `adc3` is 0xFF rather than 0x80. That is the byte
MAME's firmware deposits at DPRAM 0x03.

*Confirmed on hardware.* The I/O board's scan output is now byte-identical to
the reference across every address it writes:

    addr  000 001 002 003 004 005 006 007 009 00b 00c 00d
    board  80  20  20  FF  FF  FF  FF  FF  8F  FF  FF  FF
    MAME   80  20  20  FF  FF  FF  FF  FF  8F  FF  FF  FF

*The general lesson, which has now cost this project twice.* A read with a side
effect must be ONE event in the RTL, not a combinational output plus a
separate strobe that shifts. The two drift, simulation does not notice because
its strobes are ideal, and the error is a silent factor of two.

*Still open at the time of writing:* whether the settings block at DPRAM
0x100-0x17f stops being swept once the scan feeding it is correct. The
reference writes that block ONCE and never touches it again; this core was
sweeping it three times a minute with the shifted values.

**R78 — the instruction cache is NOT the bottleneck, CPI is ~21 rather than
3.95, and two thirds of the machine's time is spent waiting on memory.** Three
corrections, all measured, and the first cancels a piece of queued work.

*The instruction cache plan is dead.* Modelled against a 4,000,000-instruction
trace from the boot harness, direct-mapped with 16-byte lines exactly as
`i960_icache` indexes:

    LINES   size   hit%    tag FFs
       32   512B   99.97       768     <- what is built today
      128     2KB  99.98      2816
      512     8KB  100.00    10240

**512 bytes already hits 99.97%.** The queued "512 B -> 8 KB" would buy 0.03
percentage points for ~10,000 tag flip-flops -- and the tags CANNOT go in M10K,
because `hit` compares them combinationally on every fetch (see the header of
that file, which records Quartus inferring an altsyncram and silently changing
the circuit). It would cost thousands of ALM and gain nothing. **Do not do it.**

*R55's CPI of 3.95 is wrong by five times.* Measured two ways that agree:

    boot harness, real SDRAM controller   CPI 22.67
    the board itself, 1.16 M insn/s at 24 MHz   CPI 20.7

*Where the cycles actually go*, over 1.5 M instructions with the real
controller:

    WAITING on memory   65.6% of cycles   -> 14.87 of the CPI
    core sequencing     34.4% of cycles   ->  7.80 of the CPI
    bus transactions    0.805 per instruction, 18.5 cycles of wait EACH

**18.5 cycles of wait per access is the single biggest number in this core.**
At 24 MHz against SDRAM at 96 MHz that is ~74 SDRAM cycles for one access,
where a page-hit read should cost under ten. It is not the memory being slow,
it is the path around it, and `m2_cpu_bridge`'s own sequencer says why: every
32-bit access is TWO independent 16-bit transactions,
`S_LO -> S_LO_W -> S_HI -> S_HI_W`, and each `_W` state waits for the
controller's ack to FALL before the next request may go out. `m2_sdram` holds
ack for `ACK_HOLD` = 2 cycles, so each half costs a full round trip plus the
hold. Two of those per access, across the 24/48/96 MHz domains.

*The levers, in order of measured value:*

  1. **Serve a 32-bit access as one 2-word burst** instead of two independent
     transactions. Halves the round trips.
  2. **Drop the ack hold for this requester.** `ACK_HOLD` exists "so requesters
     on a slower synchronous clock see exactly one rising edge", and the bridge
     comment states this bridge runs on the SAME clock as the controller -- so
     for it the hold is pure overhead. Note `S_HI_W` and the `S_IDLE` guard are
     already labelled DEFENSIVE and not proven necessary; `S_LO_W` IS necessary
     and has a hardware failure behind it (boot IP read as 0x00600860 where the
     ROM holds 0x00000860). Do not remove that one without replacing what it
     guarantees.
  3. **A data cache.** 0.805 accesses per instruction, and the I-cache result
     above shows the working set is small; there is no D-cache at all today.

Eliminating the memory wait entirely would take CPI from 22.7 to 7.8, which is
2.9x. The core's own sequencing at 7.80 CPI is then the next target.

*Separately, the drawing fault is NOT the renderer and NOT the I/O board.* The
tilemap census on hardware, by writing instruction:

    IP 0001a15c   5167 writes  100% zero      <- dominates
    IP 0001ce38     10 writes   20% zero      <- the real fill, correct values
                                                 (0020, 3000, 3d8d -- exactly
                                                 simulation's three commonest)

and the routine disassembles as

    0001a0c4: ldos  0x501300,r3     ; reads WORK RAM
    0001a104: ldos  0x501320,r11    ; the bit source
    0001a10c: and / rotate / or     ; scatters r11's bits into r4,r6,r8,r10
    0001a15c: stos  0x100a000,r3    ; stores the result into tile RAM

It is a bit-plane expander writing faithfully what it reads, and it reads
**zero**, from the same `0x501xxx` work-RAM region where R75 already found the
board's pointer wrong (0x511000 against simulation's 0x505100). The drawing
code is correct and is being handed data nobody produced. **R76 and R77 did not
move this ratio (99.76% -> 99.81% zero), which is the evidence that the I/O
board faults and this one are separate.**

**R79 — the tilemap is written, read, and drawn; the screen is still flat. And
R78's "the CPU writes zeros" is WRONG — it was the instrument.** This entry
corrects R74, R75 and R78, all of which rest on a biased measurement.

*The bias, because it cost the most.* The per-write tilemap census sampled ONE
write per burst and always the same one. The routine at 0x1a120 issues eight
stores inside ~50 cycles while the serial streamer stays busy 1.74 ms after each
line, so the streamer caught the burst's FIRST store every time and nothing
else. That produced "one instruction is 5,167 of 5,245 writes, 99.81% of them
zero", which read as a finding and is an artefact. **Unbiased counters in RTL
said 35% of tilemap writes are NON-ZERO.** A counter cannot be biased; a sampled
stream can, and this one was, twice.

*What is actually true, all measured on hardware with counters:*

    CPU -> tilemap writes      35.0% non-zero
    renderer <- tilemap reads  38.7% non-zero
    glyph fetches              53.1% non-zero, 97,565/s
    palette reads              97.6% non-zero
    per-map non-zero writes    map0 8,315  map1 0  map2 12,672  map3 4,096
    MAME's maps                map0 full   map1 empty  map2 full  map3 full

Every stage carries data, and the map populations agree with the reference --
including map1 being empty in both.

*Where it stops:*

    layer 0 pixels contributed        0
    layer 1                           0
    layer 2                     190,464   = 496 x 384, THE ENTIRE SCREEN
    layer 3                           0
    non-blank tile words: layers 0,1 = 0; layers 2,3 = saturated

Layer 2 paints every pixel and the rest contribute nothing. That is the flat
screen: `hit_cat0[2]` carries `opaque_pass` -- MAME draws tilemap 2 with
TILEMAP_DRAW_OPAQUE -- so it paints even where transparent, and layer 3 sits
behind it. The mixer's ordering was checked against model1_v.cpp's eight draw
calls and is CORRECT.

*Ruled out, so nobody repeats them:*

  - **The layer disable.** `vscr[15]` switches a layer off for a frame. All four
    scroll words read ZERO on the board, so no layer is disabled.
  - **The glyph cache going stale.** It genuinely had NO invalidation and that
    was a real bug (fixed), but the fetch rate is 97,565/s with or without it,
    so it was never the throughput limiter.
  - **A low glyph fetch rate as a cause.** 97,565/s against ~4.1 M/s for a full
    screen looks damning until you notice `cc_hit`: the fetch engine keeps a
    per-line glyph cache, so a UNIFORM map needs almost no fetches. A low rate
    is a SYMPTOM of a flat picture, not its cause.
  - **`layer >> 1` scroll indexing.** m2_video's header comment says
    `0x5000 + (layer >> 1)`; the code at line 478 uses `0x5000 + cur_layer`. The
    comment is stale. Reasoning from it produced a wrong pair-split theory.
  - **Comparing "non-zero" against MAME's maps.** `tw_nonblank` excludes tile
    0x20, the SPACE character, which is the commonest index in the reference
    census. A lua script counting `!= 0` is therefore NOT measuring the same
    thing, and map0 being "full" in MAME may be full of spaces.

*The standing instrument rule this earns:* **prefer a counter in RTL to a
sampled stream.** Three wrong conclusions this session came from sampling --
the trap that was a flag poll, the starved channel that read as "never
written", and the burst-leader census above. Every one was corrected by a
counter, and a counter costs a few flip-flops.

**R80 — the maps and the glyphs are BOTH correct on hardware; the fault is
glyph fetch THROUGHPUT, which is the same memory path that limits the CPU.**

*Everything feeding the renderer is right, measured against the reference:*

    map2 real tiles   board 4,480 writes   MAME 4,096 content   agrees
    map3 real tiles   board 4,096          MAME 4,096           exact
    map1              board 0              MAME 0               exact
    map0 real tiles   board 96             MAME 459             short
    glyph upload      2,566,683 words written, 2,243,516 non-zero, THEN STOPS
    MAME's char RAM   62.8% non-zero; our fetches return 53.1% non-zero

*And the output is two flat bands, measured at the pin:* 524 colour changes per
frame over 16.00 Mpix/s, which is ~2.3 per scanline -- a horizon and nothing
else. A drawn screen is thousands.

*The one number that is wrong:*

    glyph fetches        97,565/s
    a full screen needs  ~4,100,000/s
    cache hit rate       51.8% on hardware, 96.7% in simulation

Every miss takes the slow path through the SAME asynchronous CDC that costs the
CPU 18.5 cycles per access (R78). Most tiles never receive their glyph in time,
render transparent, and tilemap 2's TILEMAP_DRAW_OPAQUE pass shows through as
flat colour. **So the memory path is not only the speed problem, it is also the
picture problem, and one fix addresses both.**

*Note on the hit rate.* The cache is 16,384 lines direct-mapped with a 4-bit
tag over an 18-bit space, so sixteen addresses alias to each line against a
measured working set spanning 985 KB. Simulation's 96.7% was measured on a
captured access pattern; hardware's 51.8% is the live one. That gap is worth its
own investigation once the memory path is fixed, because a cache that misses
half the time cannot hide a slow miss.

**R81 — the renderer is innocent: map 2 holds SIX distinct tile values where the
reference holds 1,274, because the game's artwork and text routines never
execute.** This is the flat screen, located at its source.

*Measured by snooping the renderer's own read port* -- no extra port, no
duplicated array, and it reports exactly what the picture is drawn from:

    board map2, as READ:  37,989 samples, 2,659 distinct cells, 6 distinct VALUES
        3d8d 21,414   3000 14,055   0020 1,980   0000 472   8020 67   0003 1
    MAME  map2:           1,274 distinct values, range 3000..3d8d

`0x3000` and `0x3d8d` are the flat backdrop pair. Everything else is missing.

*And it names the routines, against the simulation writer census:*

    0001ce38  18,816 writes, 4 distinct: 0020/3d8d/3000  the BACKGROUND  -- RUNS
    0001c904   7,840 writes, 1,175 distinct               artwork        -- NEVER
    0001c770   7,595 writes, 1,087 distinct               artwork        -- NEVER
    00018ea4  23,769 writes,   225 distinct (8bc9,8b90)   TEXT           -- NEVER

The background fill runs; the artwork and text routines do not. That is one
cause for BOTH symptoms -- the two flat bands in attract, and "3CR" missing from
the test screen, which is text from the same path.

*Why folding the WRITES was not decisive, recorded because it cost a build.* The
board's write range is 0x0020..0x8020, which CONTAINS MAME's 0x3000..0x3d8d, so
spaces written while clearing widen the range without saying what the final
content is. min/max over writes cannot distinguish "varied artwork" from "two
tiles plus clearing". The read snoop can, and did.

*What this closes.* The renderer, the tilemap array, its addressing, the mixer's
draw order, the glyph path and the palette are ALL exonerated -- they faithfully
draw the two tiles they are given. R79 and R80's stage-by-stage census was
measuring a pipeline that was working correctly the whole time. The fault is
upstream of the first tilemap write, in whatever gates the drawing routines,
which is where R75 left it.

**R82 — THE STUCK LOOP HAS A CAUSE: a byte store lands in all four lanes, so a
loop count of 0x27 becomes 0x27272727 and the loop runs for 85 minutes instead
of microseconds.** This is why the attract screen appeared overnight and never
within a person's patience.

*The loop, disassembled from the board's own instruction trace:*

    00001b98: ld   0x501084,r4     ; the loop COUNT
    00001ba0: ld   0x501224,r3     ; the base pointer
    00001ba8: ld   0x0(r3),r5      ; walk descriptors, advancing by the size
    00001bc0: ld   0x8(r3),r5      ;   at offset 8
    00001bc4: addi r5,r3,r3
    00001bc8: cmpdeco 1,r4,r4      ; count down
    00001bcc: bl   0x1ba8

*Measured, three ways:*

    MAME              count=00000013  base=00505100  size=00000300   19 passes
    simulation                                                       39 passes
    BOARD             count=27272727  base=00505100                 ~656,000,000

The base pointer is now CORRECT -- R75 measured 0x511000 and something fixed
since has repaired it. The COUNT is the fault, and its shape names the
mechanism: **0x27 replicated into all four byte lanes.** 0x27 is 39, which is
exactly the number of passes simulation makes.

At nine instructions a pass and 1.16 M instructions/s, 656 million passes is
about 85 minutes. The board was left overnight and drew the attract screen;
a restart lost it. That is not intermittency, it is arithmetic.

*What the CPU actually writes, captured off its own bus:*

    write data=27272727  be=0001     <- a BYTE store, byte replicated
    write data=2B2B2B2B  be=0001
    write data=00000000  be=1111     <- the word is zeroed first

The i960 replicates a stored byte across the word and relies on the ENABLES to
pick a lane -- that is correct i960 behaviour. With the word zeroed and only
lane 0 enabled, memory must hold 0x00000027. It holds 0x27272727, so **every
lane was written and the byte enables were lost.**

*Where it is NOT.* Read in source, the whole chain is correct:
m2_cpu_bridge computes `sd_be <= r_addr[1] ? r_be[3:2] : r_be[1:0]`,
m2_sdram_x2 passes it through as `f_be[g] = s_be[g]`, and m2_sdram drives
`sd_dqm <= ~be_r` from `be_p[rr_grant]`. Every hop reads right and the result is
wrong, which is the signature of source and silicon disagreeing.

*Instrument warning, because it cost a measurement.* A snoop filtered on the
bridge's `sd_addr` for that word ALSO catches the second half of an access to
the PRECEDING dword -- S_LO_W writes `sd_word+1` with `r_be[3:2]` -- and that
half legitimately carries be=00. Reading it as "the bridge sends be=0" is wrong.
Filter on the transaction, not the address.

*Why this matters far beyond one loop.* `stob` is common, and every byte store
to SDRAM is currently smearing its value across four bytes. Structures the game
initialises byte by byte are being corrupted wholesale, which is a far better
explanation of "the drawing routines never run" than anything in the renderer --
and R79/R80's stage-by-stage census was measuring a pipeline that was healthy
because the corruption is upstream of all of it.

**R83 — two attempted fixes for R82's byte smear, both reverted, and a gap in
the evidence that should have been closed first.**

*What still stands from R82.* The loop count at 0x501084 reads 0x27272727 where
MAME holds 0x00000027; the CPU issues a byte store (data 0x27272727, be=0001 --
correct i960 behaviour, since it replicates the byte and relies on the enables)
and every lane lands. 0x27 is 39, exactly simulation's pass count, and 656
million passes at 9 instructions each is ~85 minutes -- which is why the board
drew the attract screen overnight and never sooner.

*Attempt 1: a byte-enable self-test driving port 2. REVERTED, and it BROKE THE
BOARD.* Port 2 is shared with the tilemap copy engine and the self-test read
path; driving `p_we[2]`/`p_req[2]` from a new test hijacked it, the copy engine
stopped, and the tilemap went completely unwritten (map0 fold min=ffff max=0000
against a working board's min=0020 max=c058). **An instrument must not take a
port another master owns.** That is the fourth time this session an instrument
has damaged the thing it was measuring; the previous three were a live-bus tap,
a starved channel and a burst-biased census.

Its result was also unreadable twice over: the first version zeroed a word that
was probably already zero, so "the masked write did nothing" and "the fill did
nothing" gave the same answer. Fill with 0xFFFF, not 0x0000, so all three
outcomes are distinct.

*Attempt 2: read-modify-write for sub-word writes. REVERTED, UNTESTED.* Reading
the word, merging the enabled bytes in the FPGA and writing back full width
removes the dependency on byte enables entirely, and it is correct regardless of
which hop drops them. It passed all 26 tests, kept every byte lane correct in
the CPU+SDRAM integration test, cost 2.3% (CPI 17.56 against 17.16) and left the
instruction stream identical for 586,139 instructions. It was never evaluated on
hardware because the board was ALREADY broken by attempt 1, and the identical
bitstream md5 after reverting it proved that. The patch is kept at
/tmp/bridge_rmw_attempt.sv.

*THE GAP, and it is the important part of this entry.* **Every observation of
0x27272727 comes from a build that already had the data cache.** The cache was
added in the same session and has never been A/B'd against this symptom, so it
cannot yet be excluded as the CAUSE rather than an innocent bystander. Its line
is 8 bytes indexed by CPU byte address while the fill aligns the SDRAM WORD
address -- those agree only because every region base is 4-word aligned, which
was checked (GAME_WORK = 0x1600000) and holds. But "the arithmetic works out" is
not the same as "measured", and R78 through R82 are a record of what happens
when those are confused.

**The next measurement is therefore an A/B of the loop count with the data cache
bypassed, and it must come before any further fix.** Simulation cannot answer it:
it reads 0x27 correctly with the cache present, so whatever is happening is
hardware-only and only the board can say.

**R85 — the tearing is scanline overruns, the glyph cache line fixed most of it,
and the measurement says DEEPER BUFFERING IS NOT THE NEXT LEVER.**

*Two cache faults, both found by asking what the address bits actually do.*

  1. **The index used a bit that is always zero.** m2_tile_decode computes
     `char_addr = {tile_num, 4'b0000} + {map_y[2:0], 1'b0}` -- both terms have
     bit 0 clear -- and the cache indexed on v_addr[13:0]. Only even lines were
     reachable and HALF the M10K sat idle.
  2. **The line stored half of what the burst fetched.** A miss returns four
     16-bit words in a 64-bit p_dout and the line held two, discarding the next
     ROW of the same tile -- which the next scanline then fetched again. The
     locality is exact: rows sit at char_addr, +2, +4 ... +14 and consecutive
     scanlines read consecutive rows.

*Measured on hardware, in sequence:*

    glyph hit rate    61.4%  ->  82.6%  ->  93.56%
    overruns/frame     27.1  ->   27.1  ->   6.99   (of 384 lines)

Neither cost any M10K: 8,192 x 64 bits is the 64 KB that 16,384 x 32 was.

*Why a per-frame counter had to exist first.* dbg_overruns saturates at 65535
and reaches it during warm-up, so it can say "there were overruns" and never
"there are overruns NOW". Reading its stopped-incrementing state as "fixed" was
wrong and the screen said so. A frame has 384 lines; the per-frame count cannot
saturate.

*And why the next step is NOT four line buffers.* m2-framediff.sh measures the
demand directly:

    per-line fetch demand over 1470 non-empty lines:
        mean 61.5  median 66  p90 82  max 115
    burstiness max/mean = 1.87x
    engine waiting on memory: 8.3% of all time

The tool states the rule it was built with: above 2x, buffering ahead smooths
real variance; near 1x, only fewer fetches or more bandwidth help. **1.87x is
below that line**, and 8.3% memory wait is not a starved engine. Four banks were
written, cost ~6 M10K, and are PARKED rather than shipped -- the evidence does
not support them, and shipping on reasoning after this session's record would be
indefensible.

*An instrument note, because the parked version has one.* Decoupling the fetch
from the beam invalidates the overrun definition: "line_start arrived while the
sequencer was in Q_RUN" is normal operation for a FIFO that always runs, and it
reported 1195 against the two-bank 32 in the same simulation. The correct
definition for that design is "line_start arrived with nready == 0", and any
future attempt must change the counter in the same commit as the buffering.

*Separately, and worth its own investigation:* the pixel-exact frame test FAILS
by 173,299 of 190,464 pixels, and it fails identically with two banks and with
four, so it is pre-existing and not caused by either change. The data feeding it
is byte-perfect -- tools/i960-datadiff.sh reports tile RAM, char RAM and palette
all IDENTICAL to MAME -- so this is the renderer or the comparison's frame
alignment, not the game state. It is the obvious next thread.

**R86 — the four-word glyph line DOUBLED the cache and cost 64 M10K, and the
tilemap cannot stall a line.** Correcting c122bea, which claimed "same storage:
8,192 x 64 bits is the 64 KB that 16,384 x 32 was".

It is not 8,192 lines. `LINES` is `1 << IDX_BITS` and IDX_BITS stayed at 14
across that commit, so the array went from `[31:0] cdata[16384]` to
`[63:0] cdata[16384]` — 16,384 lines throughout, each line twice as wide.
512 Kbit became 1,024 Kbit. The cache DOUBLED, 64 KB to 128 KB, and the +64
M10K is simply twice the memory. Whole-design M10K moved 389 → 449 of 553.

    128  glyph cache cdata     <- largest single memory
    128  tilemap tram (2 x 64)
     31  palette
     16  Z80 firmware ROM
      8  Z80 RAM
      6  glyph cache tags
   ~145  framework (ascal)

*Which memory can actually stall a line, since the visible symptom points the
other way.* What tears on screen is the tile layer, and it is natural to read
that as the tilemap arriving late. It is not, and it cannot be: `m2_tile_fetch`
reads the tilemap over `tram_addr`/`tram_data` with NO handshake — a registered
M10K read that answers next cycle, every cycle. The only port in the line that
can wait is `char_req`/`char_ack`, the glyph pixels, and those come from SDRAM.

The two are the same layer. tram says WHICH tile; the glyph cache says WHAT IT
LOOKS LIKE — `char_data` is eight 4bpp pixels, the tile's own bitmap. So "only
the tiles tear" and "the glyph fetch stalls" are one observation and its cause,
not competing explanations. The decisive evidence is that the intervention was
made ENTIRELY on the glyph path and overruns fell 27.1 → 6.99 per frame. Had the
tilemap been the bottleneck, caching glyphs would have changed nothing.

*What the 64 blocks bought, measured:* hit rate 82.6% → 93.56%, overruns per
frame 27.1 → 6.99.

*The lever, if 3D needs the blocks back:* IDX_BITS 13 halves it to 64 KB at the
old block count while KEEPING the four-word line — and the four-word line is
where the gain came from, since a tile's rows sit at +0,+2,…,+14 and are read on
consecutive scanlines, so one miss now fills four rows instead of one. Measure
that from a glyph trace before building it, the way the data cache was sized.
Untested.

*Three reading errors in one investigation, all confident, all wrong.* The
fitter's memory table was first parsed with the wrong column and reported the
i960's register cache as the biggest consumer at 128 blocks — that array is
16 x 128 bits, in MLAB, and 128 was its port WIDTH. The M10K column is 20, not
21, and "Total Inapplicable" is a row, not a memory. Then the +64 was explained
as 64-bit words packing badly into narrow blocks, without checking whether the
line COUNT had also changed. It had not — which was the whole point, and made
the array twice the size. A number lifted from a table without checking its
column, and a ratio explained without checking both of its terms, are not
measurements.

*And the widening left a real defect behind, found while writing this up.*
IDX_BITS went 13 → 14 but `Model2.sv` still drove `inval_idx` with
`cpu_char_wr_addr[14:2]` — thirteen bits into a fourteen-bit port. Every CPU
write to glyph memory invalidated a line in the LOWER half of the cache
regardless of which half it belonged to: a write above 32 KB invalidated an
unrelated line and left its own stale. It survived because the game writes
glyphs mostly at init and the reset sweep clears everything. A parameter that
widens must be followed to every place it is indexed, and a port that silently
zero-extends will not tell you.

**R87 — the sound board is the MODEL 1 board, not SCSP, and its 68000 now runs
72,035 of MAME's own instructions.** §5.5 budgets "SCSP + 68000 = 4,164 ALM" for
sound. That is the wrong board for this game and the row should not be relied on.

`model2.cpp` gives model2o a `SEGAM1AUDIO` — the same device `model1.cpp` uses.
There is no SCSP anywhere near daytona93. The board is an M68000, a YM3438 and
**two** MULTIPCMs, and the main board reaches it over one serial pair and
nothing else.

*The map, read out of MAME's own `address_map` rather than transcribed:*

    000000-03FFFF  ROM 256 KB @ +0          C40000/C50000  MULTIPCM 1 + bank
    080000-09FFFF  ROM 128 KB @ +0x20000    C60000/C70000  MULTIPCM 2 + bank
    C20000-C20003  i8251                    D00000-D00007  YM3438
                                            F00000-F0FFFF  RAM 64 KB

The second ROM window is not more ROM. The `.mra` already carries both files —
68000 program at byte 0x2340000, 8 MB of PCM at 0x2380000 — so no ROM work was
needed, but the LAYOUT was got wrong twice and the ROM settles it without
guessing. `epr-16489.7` begins `f0 00 fe ff 00 00 00 03`; byte-swap each 16-bit
word and that is SP = 0x00F0FFFE, the top of the 64 KB RAM, and PC = 0x00000300,
exactly where MAME's trace starts. Unswapped it is 0xF000FEFF and 0x00000003,
neither of which is anything. And the two files are CONCATENATED, not
interleaved: the `.mra` has two single-part `<interleave>` blocks, and MAME's
second window reading region offset 0x20000 is where the second file begins.

*Three walls, each found by lockstep, each a different kind of thing.*

1. **The MULTIPCM must answer "not busy".** `00035A: move.b $c40001.l, D3 /
   btst #0 / bne $35a` is the first thing after the RAM clear. The standing rule
   that unwritten memory reads 0xFFFF is right for UNMAPPED space and wrong
   here: the device is mapped, 0xFF leaves bit 0 set, and the board hangs at
   instruction 65,561 having matched MAME exactly to that point.

2. **The two ends of the link do NOT take the same interrupt.** The main board
   ORs TXRDY and RXRDY — `sound_ready_w` is literally
   `if (m_uart->txrdy_r() || m_uart->rxrdy_r())`, and TXRDY is what paces the
   i960's transmit loop. The sound board's 68000 must take RX ONLY. TXRDY is
   high whenever the transmitter is free, which is nearly always, so an IPL
   driven from the OR is asserted permanently: the instant the firmware unmasks
   interrupts with `move #$2100, SR` at 0x51E it re-enters the handler forever.
   One `irq` output serving both ends looked economical and was wrong.

3. **The boundary, which is not a defect.** At 72,035:

       000542: move.b $d00001.l, D3
       000548: btst   #$1, D3
       00054C: beq    $554

   and MAME does not take that branch. Bit 1 of the YM3438's status is TIMER B
   OVERFLOW, and the firmware's main loop sequences music on it. A stub that
   reports zero says the timer never expires. The board genuinely does not have
   the hardware yet, so this is where it stops — asserted as a floor, and the
   real YM3438 is what raises it.

*What was verified before any of that.* The link itself is byte-exact on
hardware: 59 port writes, 48 data bytes, and an order-sensitive rotate-xor
signature of 0x6AE52ED8 identical to MAME's. The board also emits it in the
right ORDER, which a sum or an xor would not have caught.

*And the reason the stream was zero for a whole build cycle.* `uart_irq` was
driven and connected to nothing. The symptom points the wrong way: the eleven
CONTROL writes still happen, because those are mainline initialisation, and not
one of the forty-eight DATA bytes ever does — which reads as a broken data path
rather than a missing interrupt. Daytona never reads the i8251's status; a read
tap over 900 frames fires zero times. The line 10 handler IS the transmit loop.
Both of MAME's triggers are needed: the TXRDY edge alone never starts, because
after the command byte enables TxEN the transmitter is already free and there is
no edge left to catch. `irq_mask_delayed_update` re-testing the level on the
mask write is what fires the first one.

*A process failure worth more than the finding.* `third_party/fx68k/` was
already a working clone with a local patch, and it was overwritten from another
project's copy of the same commit without checking. `git status` on this repo
cannot see that — `third_party/` is git-ignored — so a passing test broke with
no diff to point at. Both copies are now one committed copy under
`rtl/sound/fx68k/`, unmodified, and the patch it needed is a Verilator flag
instead: `-Wno-BLKANDNBLK`. THIRD_PARTY.md's "needs a two-word change" is
withdrawn. It needs no change at all, which is the only version of this that
survives an upstream bump.

**R88 — the sound ROM is at MRA byte 0x2350000, not the 0x2340000 the MRA's own
comment says, and it needs a byte swap the i960 does not.** Both halves of that
were wrong in the first integration and the board reported it precisely.

*Where.* The comment is not the authority and neither is arithmetic over the
section list — the BUILT IMAGE is. Searching it for the opening bytes of
`epr-16489.7` finds them at **0x2350000**, with `epr-16490.8` at 0x2370000 (256 KB
contiguous) and the four 2 MB sample ROMs from **0x2390000**. The comment is 64 KB
low. R39 records the same class of error in the other direction, from
`rom_csum.py` expanding a byte-swap interleave as though it were 32-bit.

*Which way round.* The loader's mapping is the identity — stream byte N is SDRAM
byte N — so a 16-bit SDRAM word holds `{byte 2W+1, byte 2W}`, little end first.
That is right for the i960 and backwards for a 68000. The image at 0x2350000
begins `00 f0 ff fe`, which packs to 0xF000 and reads as a stack pointer of
0xF000FEFF instead of 0x00F0FFFE — and 0x00F0FFFE is the top of the sound board's
64 KB RAM, which is how you know which one is right.

The swap belongs at the READER, not in the loader. The loader serves six other
consumers correctly, and byte order is a property of the reader rather than of
the image: the same bytes are right for one CPU and wrong for the other.

*How the board said so, which is the part worth keeping.* Attaching the real
sound board changed what the link's byte counter MEANS, and the new meaning is
more useful than the old one. With the far end drained — `b_rx_ack` tied to
`b_rx_valid` — the count said "the i960 sent its stream", and it read 48 with a
signature matching MAME. With a real i8251 on the other end it says "the sound
board is READING its UART", because that i8251 refuses a second byte until the
68000 has consumed the first, and the link then blocks the i960 on TXRDY.

It read **2**. Two bytes is exactly a receiver that took one byte into its
holding register and never read it: the first is delivered, the second is
accepted by the wire and cannot be handed over. So the 68000 was not running,
and the same counter that had been proving the transmit path was now, unchanged,
reporting the state of the receiver. That is a signal meaning two things — which
this project has a rule against — and the honest fix was to add the 68000's own
bus address and cycle count rather than keep reading the link's count as though
it still answered the old question.

**R89 — the sound ROM is at byte 0x2340000, the MRA said so, and the board found
it by looking. R88's correction was itself wrong.** Three answers were asserted
for one address in one session, and the way out was to stop asserting.

R88 recorded the ROM at 0x2350000 on the strength of searching an image rebuilt
by `tools/rom_csum.py`. That is wrong. **A reconstruction is not the image**, and
R39 already recorded this same tool disagreeing with the board about these same
68000 sound ROMs, with the same verdict: "The BOARD had them in the right place
throughout; the reference did not." Reaching for it again, for the same region,
and believing it over the MRA was the mistake — not the arithmetic.

*What actually happened, which is only legible with both attempts side by side:*

| attempt | base | swap | result |
|---|---|---|---|
| 1 | 0x2340000 (right) | none (wrong) | garbage, PC 0xD684D0 |
| 2 | 0x2350000 (wrong) | swapped (right) | garbage, vector 84D6 84D3 |

Each attempt had exactly one of the two halves right, so each failed, and the
second failure looked like confirmation that the first fix had been necessary.
Two independent unknowns changed together is the whole error: had the swap gone
in on its own, attempt 1 would have booted.

The byte swap itself stands and R88's reasoning for it is sound. The loader's
mapping is the identity, so an SDRAM word holds `{byte 2W+1, byte 2W}` — right
for a little-endian i960, backwards for a 68000 — and it belongs at the reader,
because byte order is a property of the reader and not of the image.

*The fix is that the address is no longer written down.* `GAME_SND` is deleted.
At power-up the core sweeps 64 KB-aligned candidates over 8 MB of SDRAM looking
for the 68000's reset vector, which is a four-word signature that appears nowhere
else: SP = 0x00F0FFFE, the top of the sound board's own 64 KB RAM, then
PC = 0x00000300, where MAME's trace starts. 448 candidates, one four-word burst
each, microseconds once at 96 MHz. It reported word 0x11A0000 — byte 0x2340000.

Two properties beyond being right. The CPU is held in reset unless the scan
succeeds, so a future ROM reshuffle stops the sound board instead of running it
on whatever sits at a stale constant — which is precisely the failure this
replaces. And the answer survives any change to the MRA's layout without anyone
having to notice.

An address nobody can verify by reading is not a constant. It is a guess with a
name, and this project now has two entries about the same guess.

**R90 — VPA was tied high, so every interrupt vectored through garbage. The
sound board now takes all 48 bytes on hardware.** The user asked whether the new
SDRAM port had its read/write release; it did, and asking sent me to look at the
handshakes, which is where the real fault turned out not to be.

A 68000 whose VPAn never asserts runs a VECTORED interrupt acknowledge: it drives
FC = 7, reads the low byte of the data bus and uses it as a vector NUMBER.
Nothing on this board answers an acknowledge cycle, so it read the unmapped
default of 0xFF and jumped through vector 255 at 0x3FC into whatever was there.
It then executed 0xFFFF, took the line-1111 exception at 0x2C, and looped —
39,900,000 bus cycles of it on the board, never reading its UART.

`segam1audio` raises this with `set_input_line(M68K_IRQ_2)`, which is
AUTOVECTORED, so the firmware has filled in vector 26 at 0x68 → 0x000120. Assert
VPA when `as && fc == 3'b111` and the 68000 takes it.

*Why every test passed anyway, which is the part worth keeping.* The testbench
never sent the board a byte. With `rx_valid` held at zero the RX interrupt never
fired, so the acknowledge cycle was **unreachable**, and 98,025 instructions of
verified lockstep said nothing whatever about it. A suite that cannot reach a
path cannot defend it, and this one could not reach the single path the whole
sound board exists to service.

The A/B, once the link was driven, is unambiguous: **1 of 48 bytes with VPA tied
high, 48 of 48 with it asserted.** One byte is the exact signature of an
interrupt that never returns — the first arrives, RXRDY sets, the CPU vectors
away and never reads it, and the wire blocks holding the second. The board had
been reporting `linkbytes=2` throughout, which is that same fact seen from the
sending end.

*Three wrong theories were tested and killed first, cheaply, in simulation, and
each is worth recording as a thing that is NOT the problem here:* the held
acknowledge of R32 (swept ACK_HOLD 1→8, no effect), SDRAM latency under
contention (swept ROM_LAT 6→600, all 48 bytes at every value), and the arrival
time of the first byte (swept, no effect once the link was modelled at all). The
testbench also modelled a one-cycle acknowledge where `m2_sdram` holds two, which
could not have exposed R32's hazard even if it had been the fault; that is fixed
and swept regardless.

The default run is now 30,000,000 cycles rather than 2,000,000 and asserts that
all 48 bytes are taken. The old length stopped before the first byte, which is
precisely how this survived.

On hardware: 48 of 48 bytes, and the 68000 in Daytona's main loop at 0x1632 /
0x162E / 0x262E, all of which appear in MAME's own trace.

**R91 — the MULTIPCM's output rate followed SDRAM latency, and the average rate
is the wrong thing to measure.** Three builds were spent optimising a number
that could not distinguish the two failures it was being used to judge.

`m2_multipcm` advances its slot counter only while no fetch is outstanding:

    else if (!rom_req) begin
        tick <= tick + 1'b1;

so memory latency does not delay a sample, it stretches the sample PERIOD.
Measured against fetch latency in cycles, the period runs 1075..1805 at 100 and
1075..3015 at 300, against a nominal 1075. That is a sample rate moving by a
factor of nearly three from one sample to the next.

*Why a change that improved every average made the sound worse.* With no cache
EVERY fetch missed, so every period was equally long: uniformly flat, like a
tape running slow, and tolerable. Adding a per-voice cache raised the average
rate from 59% to 89% of nominal at high latency — and was reported from the
board as "really bad… all crackly". Both statements are true. Average rate
improved; STABILITY collapsed, because the miss count now varies per period.
Crackle is a rate that moves, not a rate that is low, and the standard deviation
of the period is the number that says so: 6.0% at latency 100, 15.8% at 300.

*Two earlier attempts at this, both measured, both worth recording as ineffective.*
A ONE-LINE buffer in front of the fetch made no difference whatever — identical
figures to four digits with it enabled and disabled — because the chip
round-robins 28 slots, so consecutive fetches come from 28 unrelated streams and
every access evicts the one before. Its hit rate was zero. And answering a cache
hit in one cycle instead of three also changed nothing, because the chip only
issues fetches inside `if (ce)`, every 4.8 cycles: any acknowledge under about
four cycles is free. Only MISSES cost anything.

*The fix is not a faster cache.* `m2_pcm_rate` gives each chip an enable well
above its nominal 10 MHz, buffers what it produces, and drains that buffer at
exactly 48 MHz × 44,643 / 48,000,000. The chip is throttled by the buffer being
full, so its average rate is the drain rate — pitch and envelopes advance per
sample period and stay correct — and stalls are absorbed instead of reaching the
speaker. The output rate is then a constant by construction rather than an
average that happens to land near the right value.

The headroom was sized by measurement, not taste. At a 600-cycle fetch latency
the buffer ran dry 2,436 times at 13 MHz, 391 times at 16, and not at all at 20.
The chip idles half the time at 20, which is the point: idle is what absorbs a
stall.

*And one thing that was checked only after the board reported a problem.* The
cache was added for speed and never tested for CORRECTNESS. A cache returning
the wrong byte does not sound slow, it sounds broken, and every measurement of
the RATE would have looked fine while it did. It is now checked against the ROM
on every read — 109,140 reads, 0 wrong — which should have been the first test
written, not the last.

*Where the sound actually is, for the record.* Counting the firmware's own
register traffic over a boot: 5,688 writes to the MULTIPCMs against 1,090 to the
YM3438. With the sample chips stubbed the core was correctly silent, and an
earlier claim here that "the sound board makes sound" rested on counting
non-zero samples across a whole run — which scores a burst of noise while the
YM's registers settle exactly the same as music. Over the last tenth alone the
FM was 0..0, 0 of 2,999,999 non-zero. Silent from the first second onward.

**R92 — the second MULTIPCM was reading four megabytes past the end of the
samples, and it is the one Daytona uses.** Two builds were spent on the sample
RATE while the dominant sample chip played whatever happened to sit above the
sound ROMs.

`p_addr` is a WORD address. The offset from the first sample chip to the second
was written as `0x400000`, which as a word offset is EIGHT megabytes; the second
chip's 4 MB region begins four megabytes on, `0x200000` words. So every sample it
fetched came from beyond the end of the image.

*Which chip matters, from the firmware's own traffic:*

    $c60001  4,128 writes     $c40001  560      (data)
    $c60005  1,060            $c40005  168      (register select)
    $c60003    948            $c40003   56      (slot select)

Seven writes to the second chip for every one to the first. Almost all of
Daytona's sound is on the chip that was reading nothing.

*Why it took two builds to look here.* The board reported a sample rate of
44,633 Hz against a nominal 44,643 — 100.0%, with zero buffer underruns, a
healthy buffer level and an 88% cache hit rate. Every number said the timing was
right, and the sound was still terrible. **A correct rate playing wrong bytes is
not distinguishable from a rate problem by listening**, and the instinct on
hearing bad audio was to keep measuring time.

R91's rate stage is not wasted and is not the fix — the jitter it removes was
real and measured, 1075..3015 cycles against a nominal 1075. Both faults were
present at once, which is why fixing one of them changed the symptom without
curing it.

*The gap that let it through.* `sim/sound/tb_m2_sndboard.cpp` serves each chip
its own correct 4 MB, so the fault lived entirely in `Model2.sv`'s SDRAM address
arithmetic, which no test touches. The sound board's simulation cannot see where
the top level points its memory ports. The program ROM does not have this
problem any more because the board FINDS it (R89) rather than being told; the
sample bases are still asserted, and the reason a signature scan does not
trivially extend to them is that mpr-16491 and mpr-16493 begin with the SAME
sixteen bytes — the two chips' regions are not distinguishable by their first
bytes. Deriving the second from the first, which is now done, at least makes one
constant instead of two.

**R93 — the first-boot slowdown is one-time state, not scene content, and it
clears at the first attract transition.** Measured and observed, not yet
explained; recorded so the next session does not re-derive it.

*Measured on the board, i960 retired instructions per second:*

    first load, 24-36 s : 1,887,560 /s     (boot code, cache-friendly loops)
    first load, 36-98 s : 1,000,000 /s     24.0 cycles per instruction
    after settling      : 3,182,410 /s      7.5 cycles per instruction

A 3.2x difference, and CPI collapsing from 24 to 7.5 means memory stalls
vanished rather than the machine finding less to do.

*Observed, which is the part that identifies it:*

    scene 1, first boot  SLOW
    scene 2              fast
    scene 3              fast
    scene 4 (high score) fast
    back to scene 1      FAST
    scene 2 onwards      fast

Scene 1 is slow ONLY the first time. Coming back to the same scene later it runs
at full speed, so it is not that scene's content — it is a one-time state that
is cleared by the first attract transition, and the CPU spends the intervening
minutes stalling on memory rather than executing more instructions.

*What it is not.* Not contention from the sound board: the 68000's own bus rate
went slightly UP over the same interval (1,474,545 -> 1,664,880 cycles/s) while
the i960 got three times faster, so nothing was yielding bandwidth to it.

*The instrument for this already exists and has never been read.* `ipring` in
`Model2.sv` records the last 512 retired instruction pointers into M10K and has
done since the design was built; `ipring_q` was written and nothing ever
consumed it. Reading it out during the slow phase names the code directly, and
consecutive passes show whether the CPU is in a repeating cycle and how long
that cycle is. That wiring is done and awaiting a build.

**R94 — `make lint` never linted the top level, and four builds of unusable
sound is what that cost.** The target ran the sixteen i960 modules and nothing
else. Every "lint clean" reported in this project was a statement about the CPU
and said nothing whatever about `Model2.sv` — which is where every integration
fault here has actually been.

*The fault it hid.* `m2_sound_board`'s sample ports changed from byte addresses
to four-word bursts when `m2_pcm_fetch` was added, and `Model2.sv` was not
updated with them. A 19-bit output drove a 22-bit wire, so the burst index
landed in the LOW bits; `p_addr` then took `[21:3]` of a value that was already
shifted and divided it by eight a second time, and the byte select indexed off a
burst index. Both sample chips read the wrong address and the wrong byte out of
it. The 64-bit `rom_data` port was likewise still being fed an 8-bit wire.

*How long it survived, and why.* Four builds. In that time three separate REAL
faults were found and fixed — the second chip reading four megabytes past the
samples (R92), a sample rate that followed memory latency (R91), and a one-line
cache with a hit rate of zero — and none of them changed the sound, because none
of them was this. The search was for something that sounded wrong instead of for
what CHANGED in the build that started sounding wrong, and the board had said
"it was much better four builds ago" early enough to have pointed straight at it.

*The guard, and it was tested rather than assumed.* Verilator names this
exactly: "Output port connection 'pcm1_rom_addr' expects 19 bits on the pin
connection, but pin connection's VARREF 'pcm1_addr' generates 22 bits." The new
`lint_top` target was written by REINTRODUCING the bug and checking that message
appears, then restoring — a guard that does not catch the bug it exists for is
worse than none, and that is only knowable by trying it.

It fails on PORT CONNECTION width mismatches only, and only in our own files.
The vendored cores carry internal width warnings by the dozen; holding them to
our standard would mean waiving the whole class, which is precisely how this got
through.

**R95 — the MULTIPCM's banking is the Model 1 board's, not System 32's, and that
is why the music was right and the voices were a foghorn.** One function in a
vendored core, and the only thing in it that does not transfer between two
boards carrying the same chip.

`segam1audio.cpp` gives each MULTIPCM a **two megabyte** space:

    map(0x000000, 0x0fffff).rom();                 // first 1 MB, direct
    map(0x100000, 0x1fffff).bankr(m_mpcmbank1);    // second 1 MB, banked
    m_mpcmbank1->configure_entries(0, 4, region->base(), 0x100000);

so the upper megabyte is a window onto one of FOUR one-megabyte pages of the
4 MB region, selected by two bits. `s32_multipcm` banks in 512 KB pages with a
three-bit selector split across two fields — a different scheme on the same
part — and with Daytona's bank value of 0x01 it sends 0x100000 to 0x080000 and
everything above 0x180000 into the first 512 KB.

*Which is exactly the symptom the board reported.* Daytona's music sits below
1 MB and was unbanked and correct throughout. The voice samples sit above it, so
the words came out as a foghorn and a whine while the music was already right.
A fault that is audible on half the content and silent on the other half is
worth listening to as a bisection: "music good, voices wrong" pointed at an
address transform that only applies above a boundary, and nothing else in the
signal path has a boundary.

*Two theories killed first, cheaply, and both worth recording as NOT the cause.*
The core's own header says 12-bit packed samples "are identified and retained in
state, but the bounded v1 datapath still fetches 8-bit", which is exactly the
shape of a fault that mangles some samples and not others. It is not this:
scanning the descriptor tables shows every entry 8-bit up to index ~215 in pcm1
and ~192 in pcm2, with everything beyond that being sample data misread as
descriptors. Daytona uses no 12-bit samples at all. And the bank VALUE was
checked rather than assumed — a write tap on 0xC50000/0xC70000 across 400 frames
shows 0x01 written to both chips, twice, and never changed.

*The vendored file is now modified and THIRD_PARTY.md records it.* One function
and one port: `banked()` and a two-bit `bank_sel` in place of the two three-bit
fields. Everything else is upstream's.

**R96 — 79 M10K blocks recovered by instantiating altsyncram explicitly, and
`Model2.fit.rpt` is not a current document.** Two findings, and the second one
invalidates several earlier readings.

*The saving.* `tram` and `pal` were inferred arrays with one write port and two
read ports, and Quartus 17.0 does not infer a true dual-port memory for that
shape — it silently REPLICATES the array once per read port. The fitter named it
plainly: `tram_rtl_0` at 64 blocks and `tram_rtl_1` at another 64 for a 512 Kbit
memory whose floor is 52, plus `pal_rtl_0`/`pal_rtl_1` at 15 and 16. The Model 1
project measured the same thing on the same idiom (`82fb928`) and found Quartus
refuses the true dual-port inference template outright with Error 276001, so the
saving needs an explicit instantiation.

`m2_tdp_ram.sv` wraps `altsyncram` in `BIDIR_DUAL_PORT`: port A the CPU's, read
and write; port B the renderer's, read only. **Both ports the same width is the
condition for a single copy** — mixed-width true dual-port is what forces
replication, and both of ours are 16 bits.

    533 / 553 (96%)  ->  454 / 553 (82%)      -79 blocks
    28,170 ALM (67%) ->  29,851 ALM (71%)     +1,681, and worth it
    timing met at 0.228 ns

*"OLD_DATA" IS NOT SUPPORTED and that is a real behaviour change.* The inferred
array was non-blocking, so a read on the same cycle as a write to the same
address returned the value from BEFORE the write. Cyclone V M10K cannot do
read-first in bidirectional dual-port mode: Quartus rejects it with Error 14000,
"uses an unsupported value for parameter port_a_read_during_write_mode". Only a
build says so. With `DONT_CARE`, a cell read on the edge it is written returns
either value — port A's own read is discarded (the CPU's reads and writes are
separate transactions), and port B is one renderer read of one cell taking the
old or new tile number for one cycle, which the real S24TILE arbitrates in
silicon in a way we do not know either.

*And the instrument was lying.* `quartus_fit` exits with status 2 — this project
has recorded that as "crash-on-exit, expected" — and when it does it does NOT
rewrite `output_files/Model2.fit.rpt`. The report was seven hours older than the
`.rbf` beside it, so the per-memory breakdown read out of it showed the arrays
that had just been REMOVED, still at 64 blocks each, and the totals showed 533
after a build that produced 454.

**`Model2.fit.summary` is written on every successful fit and is the file to
read.** Every M10K figure quoted in R86 and since came from the stale report and
should be re-checked against a summary before being relied on. A build's numbers
must come from a file whose timestamp has been looked at.

**R97 — 95 M10K blocks in total, and the one-write-two-read shape appears three
times in this design.** R96 covered `tram` and `pal`; the survey that should have
gone with it is here, because "are there others" is the question that turns one
fix into a policy.

*Every memory in the design, by shape:*

| memory | shape | replicated | blocks |
|---|---|---|---|
| `tram`, `pal` | 1W **2R** | yes | 79 saved (R96) |
| `m2_backup` b0-b3 | 1W **2R** — CPU and the HPS save path | yes | **16 saved** |
| `m2_ioboard` dp_hi/dp_lo | 1W **2R** — i960 and Z80 | yes | ~2, not taken |
| `m2_char_cache` cdata | 1W1R, same address | **no** | 128 is its real size |
| sound board RAM, Z80 ROM/RAM, dc_tag, ipring | 1W1R | no | — |

    533 / 553 (96%)  ->  438 / 553 (79%)      -95 blocks
    28,170 ALM (67%) ->  30,095 ALM (72%)     +1,925
    timing met at 0.471 ns

*The backup was already flagged and the flag understated it by four times.* Its
own comment reads "Costs a second read port on each lane, which Quartus serves
by duplication: ~4 M10K, debug-only." The real figure is 16 — each 4096x8 lane
needs FOUR blocks, not one, and all four lanes are duplicated. A cost estimated
once in a comment and never re-measured against a fitter report drifts.

*Port A carries the write and the CPU's read together*, which works because `ww`
IS `word` whenever `hps_we` is low — that covers every CPU read and every CPU
write — and when `hps_we` is high the read is discarded, because the CPU is held
in reset for the whole of that transfer.

*And the power-up value is part of the contract, not a detail.* Unwritten backup
RAM must read 0xFF: a battery-backed RAM that powers up as ZERO looks to the
game like a valid all-zero save. The inferred array got that from an `initial`
block, which an explicit `altsyncram` does not have, so it comes from
`rtl/mem/ff4096x8.mif` with `power_up_uninitialized` FALSE. Converting a memory
without carrying its initial contents across would have been a silent save-data
fault that no resource report could show.

*What is NOT available.* `m2_char_cache`'s 128 blocks are not replication — it
reads and writes one address and is genuinely 16,384 x 64 bits. The only way to
reduce it is to make it smaller, which costs hit rate and tearing (R86). The
I/O board's DPRAM has the same 1W2R shape but 1024x8 fits in a single block, so
converting it saves two and is not worth the risk to a working handshake.

**R98 — the coin reaches the i960 correctly; the game declines to credit it.**
The whole input chain is measured good, so this is a configuration question and
not a hardware one, and the measurement is worth keeping so nobody re-walks it.

    button -> IN0 bit 0          20 edges for 20 presses
    Z80 -> DPRAM word 4          lowest value ever written 0xFE
    i960 reads DPRAM word 4      yes -- see below

The last line needs no instrument. **Start, Test and Service are bits 4, 2 and 3
of the SAME BYTE the coin is bit 0 of**, and all three work. There is no
mechanism by which bit 0 of a byte arrives differently from bits 2, 3 and 4, so
the i960 is reading that byte, seeing the coin, and not awarding a credit.

Free play reaches game select, so the game itself runs.

*Two numbering conventions made this look harder than it was.* R65 recorded in0
landing in "DPRAM byte 0x08" and a MAME write tap showed a coin changing "byte
0x10", which read as a contradiction for most of a session. They are the same
place: MAME's DPRAM device is umasked to bytes 0 and 2 of each dword, so DPRAM
byte 0x08 is i960 address 0x01c00010 is dword 4 is `dp_lo[4]`. A byte index into
a umasked device is not a byte index into the device's own memory, and neither
figure was wrong.

*And an instrument that measured the wrong thing first.* The first version of
this tap latched the last non-idle DPRAM write ANYWHERE. The Z80 writes word 1
several times a frame, so it counted 255 writes and never held the coin at all.
An instrument has to be selective about the signal it is measuring or the
busiest one wins — the same lesson as the channel starvation in the debug
streamer, arrived at from the other direction.

*What remains, and it is not RTL.* MAME's i960 responds to a coin by starting a
repeated write to 0x1c0001c byte 2 that does not happen before it — the coin
counter output. Whether ours does the same would say if the coin routine runs at
all, but the likelier answer is Daytona's own coinage configuration, which lives
in backup RAM and is set from the service menu. That menu is reachable now: VR1
Red and VR4 Green are its down and up.

**R99 — the first attract scene is not a machine that is stalled, it is a
machine that is BUSY. The "speed-up" afterwards is the CPU going idle.**
The `ipring` buffer had recorded the last 512 retired instruction pointers since
the design was built and had never once been read out; reading it inverts the
question.

*Profiled on the board, same instrument, both phases:*

| | slow (CPI 23.9) | fast (CPI 7.2) |
|---|---|---|
| `0x0012B0` + `0x0012B8` | 4.5% | **70.4%** |
| `0x001000-0x001FFF` | 5.8% | 73.3% |
| `0x011000-0x011FFF` | **40.1%** | ~0% |
| `0x010000`,`0x013000`,`0x016000` | 36% combined | ~0% |

In the FAST phase the i960 spends seventy per cent of its time in a
TWO-INSTRUCTION wait loop at 0x12B0/0x12B8. That is what 7.2 CPI is measuring —
a machine with nothing to do, spinning in cache. It is not a faster machine.

In the SLOW phase it is running a large body of real code across
0x010000-0x016FFF that later scenes never touch, at 24 cycles per instruction.
The picture animates slowly because the CPU cannot finish its frame, and the
board's own observation confirms the shape: returning to scene 1 later runs at
full speed because that one-time work has already been done.

*Why this was mis-framed for two sessions.* An instruction RATE that triples
looks like a stall clearing, and 24 CPI dropping to 7.5 looks like memory
pressure being relieved. Both readings are consistent with the numbers and both
are wrong. A rate says how many instructions retire, never which ones, and
"faster" and "idle" are indistinguishable from the outside. Only knowing WHERE
the CPU is separates them, and the instrument for that had been sitting unread
in the design the whole time.

*What the real question now is.* Not "why does it stall" but "why is that code
24 cycles per instruction". The i960's data cache is 2 KB; whether that is the
binding constraint or the misses are compulsory is the next measurement, and the
hit rate in each phase answers it directly.
