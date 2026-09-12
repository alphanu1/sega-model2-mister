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
settle. `docs/mister-integration.md` had said it was available; the project rules'
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

**R100 — the first phase is not slow because the CPU is behind; the CPU finishes
early and waits. Three framings were wrong before this one, and each was
consistent with the numbers available at the time.**

*What the board actually sees:* the picture is SMOOTH and running at a quarter
to an eighth speed. Smooth rules out dropped frames — the renderer draws every
frame completely. What is slow is the game advancing its own state.

*The measurements, in the order they were made and corrected:*

1. **"A stall that clears."** i960 at 1.0 M instructions/s for three minutes then
   3.2 M — 24 CPI down to 7.5. Read as memory pressure being relieved. Wrong: a
   rate says how many instructions retire, never which ones.
2. **"Scene 1 is expensive."** Reading `ipring` — recording the last 512 retired
   IPs since the design was built and never once read out — showed the FAST
   phase spending **70% of its time in a two-instruction wait loop** at
   0x12B0/0x12B8. 7.2 CPI is a machine with nothing to do. Not faster: idle.
3. **"One-time initialisation."** Wrong: MAME runs that same 0x010000-0x016FFF
   block steadily at ~10% of instructions from 3.5 s onward. It is periodic.
4. **"Grinding through work MAME finishes in seconds."** Wrong, and the board
   said so: growing the data cache 2 KB → 16 KB took the hit rate from 55% to
   88%, misses from 651 k/s to 215 k/s and the CPU from 1.00 M to 1.37 M
   instructions/s — **and the phase did not shorten at all**, 200 s to 210 s.
   The extra speed went entirely into idling more, 4% to 13%.

*The framing that fits every number.* If a logic frame's work takes about seven
display frames and then waits one for the next vblank, the CPU is 87% busy, 13%
idle, and the game runs at an eighth speed. Those three figures agree, which
none of the earlier readings managed, and it explains why a 37% faster CPU
changed nothing visible: it moved the work from seven frames to five, still more
than one, so the game still advances once per vblank-after-it-finishes.

*And it is a MODE CHANGE at 210 s, not a speed change.* Either side of it the
i960 runs entirely different code — 0x011xxx at 37% before and 0% after,
0x018xxx at 0% before and 55% after. A phase of the game's own startup ending,
not the machine catching up.

*What is worth measuring next, and it is not another rate.* The ratio of logic
frames to real vblanks. Occupancy of the wait loop says how long it waits;
ENTRIES say how often, and entries against `io_framenum` at 57.5 Hz is the speed
directly. One per vblank is full speed; one per eight is what the board sees.
Everything up to here has been inferred from rates, and rates cannot tell a busy
machine from an idle one.

*The standing lesson, restated.* This project has a rule that a MAME cycle count
is not a hardware fact. The companion is that an instruction rate is not a
progress measure. Four framings survived contact with the rate data; the first
one to survive contact with WHERE the CPU was, was the fourth.

**R101 — 25 MHz is unreachable without giving up something worth more than the
4% it buys, and the arithmetic says which.** Attempted, measured, reverted.

The i960's real clock is 25 MHz (MAME's `-listxml`: `Intel 80960KB
clock="25000000"`), and the timing report says the path can carry it — Fmax on
`general[3]` is 29.1 MHz against 24 in use. `rtl/pll/pll.v` records 25 as
impossible because "96, 32 and 25 cannot share a PLL: they need a VCO of 2400
MHz and Cyclone V tops out near 1600". That is true of a 96 MHz family and is
not a law: a VCO of **800 MHz = 50 x 16** gives 100 (/8), 50 (/16), 32 (/25) and
**25 (/32)**, all exact, with both halving relationships intact.

*So the PLL is not the obstacle. `ce_pix` is.* The renderer runs on `clk_sys`
with a one-in-three enable, and 48/3 = 16 MHz exactly, which is what makes the
frame rate 16e6/(656*424) = 57.5242 Hz. That divisor is also why the renderer
could move onto `clk_sys` at all — it removed a dual-clock tram and palette
whose read-during-write behaviour Quartus states outright is UNDEFINED.

Three conditions must hold at once:

    ce_pix = clk_sys / k = 16 MHz   ->  clk_sys in {16, 32, 48, 64, 80, 96, ...}
    i960   = clk_sys / 2            ->  i960   in {8, 16, 24, 32, 40, 48}

**25 is not in that set for any k.** Reaching it means breaking one of three
things, and each costs more than it returns:

* **the exact 2:1** — the CPU bridge's single-flop crossing becomes two-flop
  synchronisers, roughly two extra cycles per bridge transaction on a CPI of
  17.5. About -11% against the +4% gained. A net loss, and measurable as one.
* **the integer pixel divisor** — a fractional enable puts +-20 ns of jitter on
  a 62.5 ns pixel.
* **the renderer's clock** — back to the dual-clock arrays that were removed on
  purpose.

*And the 4% is not the problem anyway.* R100 measures the game running at about
a third of its logic rate and needing **3.4x**. 24 to 25 MHz is 4%. The gap is
the core's cycles per instruction — roughly 11 of the 17.5 CPI is the i960
itself, and a two-instruction compare-and-branch loop that hits in cache
measures 7.2 CPI. That is where 3.4x has to come from, and no clock available on
this part supplies it: even the full 29.1 MHz Fmax is only 1.2x.

Recorded rather than left as a loose end, because "match the real 25 MHz" is an
obvious and reasonable thing to want and the reason it is not free is four
levels down.

**R102 — the i960 runs at 25 MHz, the real part's clock, and R101's objection was
answered rather than overruled.** R101 concluded 25 MHz cost more than it bought.
It was right about the costs it listed and wrong that there were only three.

*The PLL was never the obstacle.* `pll.v` recorded 25 as impossible because "96,
32 and 25 cannot share a PLL: they need a VCO of 2400 MHz and Cyclone V tops out
near 1600." True of a 96 MHz family, not a law. A VCO of **800 MHz = 50 x 16**:

    SDRAM  800/8  = 100 MHz      core is an exact /2 of SDRAM
    core   800/16 =  50 MHz      i960 is an exact /2 of core
    video  800/25 =  32 MHz
    i960   800/32 =  25 MHz

*Both relationships worth keeping survived, and they were the expensive ones.*
`m2_sdram_x2` stays an ADAPTER rather than a clock-domain crossing, and the CPU
bridge keeps its SINGLE-FLOP crossing — the bridge records two flops costing
`S_DONE` **7.12 cycles per transaction against 1.14**, so an i960 on its own PLL
would have paid about six cycles a transaction for four per cent of clock.
`tram` and `pal` stay SINGLE-CLOCK, so read-during-write stays defined.

*What gave was the pixel enable, and it is the cheapest of the four.* `ce_pix`
was `clk_sys/3` and 48/3 = 16 MHz exactly; 50/3 is not. It is a 16-of-50 phase
accumulator now: the average is 16.000 MHz and the frame rate is still
16e6/(656*424) = 57.5242 Hz. The SPACING is not uniform — enables sit 3 or 4
cycles apart against a nominal 3.125, 60 or 80 ns against 62.5.

That does not reach the picture, and the board confirms it. The video timing
counts PIXELS: every H and V position, the line length and the frame length are
in units of `ce_pix` and are unchanged. The scaler latches one pixel per enable
into a line buffer and drives its output from its own clock, so what moves is
when a pixel is handed over, never which or how many.

*Timing closes with headroom:* SDRAM 123.2 MHz Fmax against 100, clk_sys 61.6
against 50, i960 31.2 against 25. Worst-case slack 0.442 ns.

*32 MHz was asked for and is not reachable.* The chain is
`SDRAM = 2 x clk_sys` and `i960 = clk_sys / 2`, so `SDRAM = 4 x i960`. An i960
at 32 forces a 128 MHz controller against a measured Fmax of 116.7 in the 96 MHz
build; 40 forces 160.

*And 4% does not fix anything.* The game runs at about a third of its logic rate
and needs 3.4x. With the 16 KB cache's 1.37x this is 1.43x of it. The remaining
2.4x is the core's cycles per instruction: ~11 of the 17.5 CPI, and a
two-instruction cache-resident compare-and-branch measures 7.2. 25 MHz is here
because it is what the hardware is, not because it was going to help.

**R103 — the i960's cost is instruction FETCH, not execution, and the direction
from here is pipelining. Recorded now because the next session should not
re-derive it.**

*Measured in the boot harness, per instruction, in CPU cycles:*

    T_FETCH      1.00      T_EXEC     1.00
    T_FETCH_W    2.64      T_MEM_W    2.72
    T_FETCH2_W   0.83      total      8.19

    fetch total  4.47      execute    1.00

**Fetch costs four and a half times what execution does.** That is the shape of
a non-pipelined multi-cycle machine: it walks T_FETCH -> T_FETCH_W -> T_EXEC in
strict sequence, so the fetch unit idles during execute and the execute unit
idles during fetch.

*A BIGGER INSTRUCTION CACHE IS NOT THE ANSWER, and this is worth recording
because it is the obvious guess.* Swept 512 B to 8 KB with forced rebuilds:
CPI identical to the digit at both. Those 2.64 cycles are the cache's LATENCY ON
A HIT, not misses. That is the opposite of the data cache, where 2 KB -> 16 KB
took the hit rate 55% -> 88% and was worth 1.37x on the board.

*Prefetch already exists and works.* Sequential prediction, issued during
execute. At instruction level in a hot four-instruction loop it hits three times
in four, missing only on the branch back — which is the honest cost of
predicting sequential. An aggregate counter reported 13% and disagrees with the
instruction-level dump; the counter is the more likely to be wrong and the
discrepancy is unresolved.

*THE DIRECTION: pipelining.* Not more cache, not a faster clock. The clock is
spent (R102: 25 MHz is the real part's, and Fmax is 31.2). The gap is 3.4x and
the memory work has already returned 1.37x. Overlapping fetch with execute is
worth up to the 4.47, and that is a rewrite of a ~3,000-line core with hazard
detection, forwarding and branch handling.

**Do not start that without first knowing exactly where the 4.47 goes.** The
breakdown above is by STATE, which is not the same as by cause: T_FETCH_W's 2.64
mixes icache hit latency, icache misses that reach SDRAM, and cycles lost to a
mispredicted prefetch, and those need different parts of a pipeline to fix. The
instrumentation to separate them is in `sim/io/tb_m2_boot.cpp` and works; what
it needs is a counter that is right.

*Five measurement errors in one session, all the same shape, all corrected --
counting the right thing against the wrong clock or edge.* `prof_cycles` counts
clk_mem and was read as CPU cycles, which made an 8.19 look like a 17.12 that
"matched" the board's 17.5. The state histogram sampled at clk_mem while the
sequencer runs at clk_cpu, counting every state twice -- which is why every
figure came out an exact multiple of two. The same sampling read `pf_ip` against
an `ip` that had not updated. The two-word counter watched a transition that
never happens. **A profile is a measurement and deserves the same scepticism as
any other; four of these looked entirely plausible until the next one exposed
them.**

*And the sim is NOT the board's slow phase.* 8.19 CPU cycles per instruction on
the boot path against 17.5 measured on hardware during the first three minutes.
Different workloads. Optimising against the boot path may not move the phase the
board actually complains about, and a representative trace is worth having
before the pipelining work starts.

**R104 — the TGP is ported and verified; the missing piece was in the MRA, not
the RTL.** 3D has a start, and the first real finding is an omission nobody could
have noticed earlier.

*What went in.* 4,400 lines from the Model 1 project at `4e7dee6`, unmodified,
with the whole verification package: **~18.5 million fuzz cases across ten
suites, zero failures, nothing uncovered.** `mb86233_xfer` is exhaustive at 256.
MAME's `mb86234_device` is an empty subclass of `mb86233`, so this transfers —
with 5.4.1's caveat that this is absence of evidence rather than proof.

*The interface, from `model2.cpp`'s address map rather than description:*

    0x00884000-0x00887fff  copro_fifo   read pops OUT, write pushes IN
    0x00980000             copro_ctl1   bit 31 selects which
    0x00980004             fifo_control read: 1 when OUT is empty

**One address does two things and `copro_ctl1` bit 31 is the selector.** While
that bit is set, a write to the FIFO port goes to the PROGRAM RAM at a counter
the hardware keeps; clear, it pushes the input FIFO. Setting the bit halts the
copro and zeroes the counter, clearing it boots — and it triggers on the bit
CHANGING, not on its value, so a write leaving bit 31 alone does neither. FIFO
depth is eight, from `setup(8, ...)`, not "deep enough": a FIFO that never fills
hides the flow control the game relies on, exactly as an infinitely fast serial
link did for the sound board.

*THE MATH TABLES WERE NOT IN THE MRA.* The TGP reads sincos, atan, inv and isqrt
through its IO space from `copro_tgp_tables` — `opr-14742a.45` and
`opr-14743a.46`, 128 KB each, interleaved to 32 bits. This file did not carry
them. **Nothing had asked for them**, because the coprocessor was stubbed as
permanently finished, so the omission was invisible until a real TGP's table port
had nowhere to read from. A stub does not merely defer work; it hides the
requirements of the thing it stands in for.

*And the offset is measured, not counted.* Adding 0x40000 to the previous
section gives 0x2BA0000; the tables are at **0x2BB0000**. A 64 KB gap, in the
same direction and of the same size as R88/R89 found for the 68000 sound ROM.
The comments in the MRA are a description of intent and the built image is the
authority.

*A consequence that had to be caught rather than discovered later.* R19 recorded
the gap between the last ROM word and `GAME_WORK` as deliberate margin — 0x30000
words, 384 KB. The 256 KB of tables took the image from 0x2BB0000 to 0x2BF0000
and that margin down to **64 KB**. Still positive, and 64 KB is not margin: the
next ROM anyone adds lands on work RAM, and the symptom would be the game
corrupting its own variables. `GAME_WORK`, `GAME_BOARD` and `GAME_CHAR` moved up
256 KB; margin is 320 KB again.

*What is not wired yet, stated rather than left to be found.* The TGP's RAM
window (Model 1 arbitrates a shared V60/TGP RAM; Model 2's equivalent is the
banked view in `copro_tgp_io_map` and has not been traced) is tied off, with the
request brought out on `dbg_ram_req` so a design that starts depending on it is
visible rather than silently wrong. The table and copro-data ports need SDRAM
channels. And the geometry engine at 0x00800000 is a SEPARATE processor that
shares only the naming.

*Speed remains the open problem and clocking cannot solve it.* 9.83 CPI at
72.17 MHz is 7.3 M instr/s against the 16.7 M a real 50 MHz part delivers — 44%.
164 MHz would be needed at this CPI against an Fmax of 72. But pipelining
shortens the critical path as well as the CPI, so the two compound rather than
competing: 4.3 CPI at 100 MHz is 138%. Partial progress on each multiplies.

**R105 — the tilemap scroll registers were never hardcoded and the path works;
what is missing is the camera, and the run that said otherwise was measuring a
CPU spinning on a handshake.** The question was why the sky and treeline sit
still. Three answers were possible: the registers are tied to zero somewhere,
the renderer reads the wrong words, or the game writes zero. It is the third,
and zero is the *right* value for a core in this state.

*The reference first, as the order of authority requires.* MAME writes tile RAM
words `0x5000..0x5007` — hscr for layers 0..3, then vscr for layers 0..3 — from
a routine at `0x1a164..0x1a19c`, eight writes every frame, 590 frames in 590
frames. Only **layer 2** ever carries a non-zero value; layers 0, 1 and 3 stay
at zero for the whole of attract mode. So three of the four layers not scrolling
is not a defect to be explained, it is what the game does.

*And layer 2's horizontal pan starts at frame 165, on the exact frame the 3D
driving demo replaces the settings text screen.* Snapshots either side settle
it: f120 is the ADVERTISE SOUND / COUNTRY / CABINET page with no polygons on it,
f200 is the treeline and the pack of cars. `hscr` is `0000` through f160, first
non-zero at f165, and then climbs `0008, 0009, 000a, 000c, 000d, 0010, 0013,
0018` — a camera turning, sampled once a frame. Layer 2 is the sky and treeline
band, and its scroll is derived from the heading. A core whose coprocessor is
stubbed has no heading, so it writes zero, and the horizon correctly does not
move. **This is not a video bug and no amount of work in `m2_video` will move
that layer.** It comes back with the geometry, not before.

*The mechanism is proven, not assumed.* `dbg_hscr[4]`/`dbg_vscr[4]` latch what
the renderer actually consumed, at the point of consumption. At 32 M retired
instructions this core reports `layer 2 : hscr=0000 vscr=2000`, and MAME reports
`L2 h=0183 v=2000` at the comparable point. The `vscr` matches **exactly**,
including bits 14:13 = 01 — window mode 1, not scroll — which means the fetch,
the address, the latch and the layer indexing are all right, and the only
disagreement left is the value the game computed. A tied-off register could not
have produced `0x2000`.

*Now the expensive part, and it is a measurement error of the same family as the
five in R100.* Before the firmware was connected, a 24-million-instruction run
reported all four layers at zero and `0x1a164` executed **zero times**. Read
naively that is damning evidence the scroll is never written. It is nothing of
the sort. The boot sim takes the I/O board firmware from `M2_IOFW`, and with the
variable unset the Z80 board is dead, never clears the DPRAM request flag, and
the i960 parks in the two-instruction spin at `0x228240`/`0x228248` polling
`0x01c00040` — the handshake documented in `docs/io-board.md` and diagnosed here
years of sessions ago. **97.8% of all 24 million retired instructions landed in
one 4 KB page of work RAM.** The run took four minutes, printed a complete and
plausible cycle profile, and had executed none of the game.

The instrument that caught it is worth more than the finding: a 4 KB-page
histogram of every retired PC, plus `M2_BOOT_PCHIT=<addr>` to count one address.
A boot that is stuck does not look stuck in a cycle profile — every rate, every
CPI, every state percentage is real and internally consistent — but it is
unmistakable the moment you ask *where the instructions were*. One page at 97.8%
is a spin; the healthy run spreads across `0x1000`, `0x1c000`, `0x17000`,
`0x13000`, `0x11000` and a dozen more. **Any future profile should be read
alongside that histogram, because a stalled boot is otherwise indistinguishable
from a fast one.**

*The fix is to remove the knob rather than remember it.* `M2_IOFW` now defaults
to `epr-14869c.25` beside the program ROMs, and an absent firmware prints a
warning naming the spin instead of quietly booting into it. `make test_m2_boot`
had been running without the firmware and reporting FAIL; it passes. A default
that matches the board is not a convenience — it is the difference between a
harness that models the machine and one that models a machine with its I/O board
unplugged.

**R106 — the tilemap scroll is TGP-derived, proven causally, and this core
already matches the reference under matched conditions.** R105 established that
layer 2's horizontal pan begins on the frame the 3D demo starts and inferred
that it was camera-derived. Inference is not proof, and the question deserved
an experiment: is the number computed from coprocessor output, or is it i960
game state this core should already be producing? Those have opposite
consequences -- the second would make our zero a real bug.

*The first experiment was confounded and is recorded because it was.* Holding
`copro_ctl1` bit 31 set to keep the TGP halted does not only halt it: bit 31 is
the selector, so every FIFO **write** is redirected into program RAM and the
upload path is destroyed along with the processor. Daytona then stops dead --
tile writes freeze at 41,451 around frame 70 and never resume. That is a real
finding about the game (it will not proceed at all without the coprocessor) but
it says nothing about the scroll, because nothing after frame 70 happens at all.
A test that breaks two things cannot attribute the result to either.

*The clean experiment leaves the copro running and zeroes only what the i960
pops out of it.* The FIFOs still fill and drain, flow control is untouched, so
the game cannot deadlock on it; everything the i960 computes for itself is
unaffected and everything it computes FROM copro results goes wrong. Over 400
frames:

    baseline            L2 hscr = 000c 0018 001b 0197 016e 007d   vscr = 2fe1 2fea 208a 2fef 2009
    copro results = 0   L2 hscr = 0000 0000 0000 0000 0000 0000   vscr = 2000 2000 2000 2000 2000
    THIS CORE           L2 hscr = 0000                            vscr = 2000

Tile writes keep climbing in the zeroed run -- 70,378 at f200 to 134,978 at f400
-- so the game is alive and drawing throughout. It simply has no heading.

**The reference with its coprocessor results zeroed produces this core's numbers
exactly, on both registers.** That is the strongest statement available about
the 2D path: it is not merely plausible, it agrees with MAME under matched
conditions. The split is clean and worth stating in one line, because it
predicts what will and will not change when the TGP lands:

  * `vscr = 0x2000` is i960-side static configuration -- bits 14:13 = 01,
    window mode 1, not a scroll value. We compute it correctly today.
  * `hscr` is derived from coprocessor output. Zero is the correct answer for a
    core without one.

*What this closes, and what it opens.* It closes the tilemap-scroll question:
there is no bug, and no work in `m2_video` or `m2_tile_decode` will move that
layer. It opens a cheap and unusually good acceptance test for the TGP -- layer
2's `hscr` is a single 16-bit number, written once a frame, that goes from
identically zero to a specific moving sequence the moment coprocessor output
becomes real. It needs no framebuffer comparison and no rasteriser. **When the
TGP is connected, `hscr` leaving zero is the first evidence it works, and the
sequence above is what it should look like.**

**R107 — `lint_top` was reporting on a fraction of the design and not saying
which fraction; four undriven signals feeding the SDRAM arbiter survived it.**
R94 built `lint_top` after a 19-bit port drove a 22-bit wire through four
builds, and it was written properly -- by reintroducing the bug and confirming
Verilator names it. It has been reporting "no port width mismatches" ever since.
It was telling the truth and it was still useless for a whole class of fault.

`verilator --lint-only` exits at the first missing module. `hps_io` lives in
`sys/` and the PLL is a `.qip`, so neither is matched by the grep that derives
the file list from the qsf, and the run ended with two MODMISSING errors. **The
checks that survive an early exit are the parse-time ones**; everything needing
a complete elaboration -- UNDRIVEN above all -- is silently skipped. So the
guard ran, passed, and had never examined the design as a whole.

What it was missing: `tgp_tbl_req`, `tgp_dat_req`, `tgp_tbl_addr` and
`tgp_dat_addr` are declared in `Model2.sv` and feed SDRAM ports 8 and 9, and
**nothing drives any of them** -- `m2_copro` is not instantiated. Quartus ties
them low without complaint, so the ports sit idle and the last build was
harmless, but the RTL is wrong and the guard existed precisely to say so.

The fix is to make elaboration complete: `sys/hps_io.sv` and `rtl/pll/pll.v` are
named explicitly, the vendor `altera_pll` gets a lint-only black box in
`sim/lint/`, and the filter gains UNDRIVEN. `sys/hps_io.sv` is not
Verilator-clean (PROCASSWIRE) and `-Wno-fatal` carries it far enough. With that,
the four signals are named immediately and `make lint` fails -- correctly, and
it will keep failing until the coprocessor is wired.

*The generalisation is the point, and it is the R94 lesson arriving a second
time in a different costume.* A lint that cannot elaborate is not a weaker lint,
it is a lint whose coverage is unknown, and unknown coverage reads exactly like
full coverage from the outside. **Any tool that can exit early must be checked
for whether it did**, because a clean report from a run that stopped is
indistinguishable from a clean report from a run that finished.

**R108 — wiring the coprocessor woke two latent SDRAM controller bugs, and the
undriven signals R107 complained about were the only thing that had been
suppressing them.** `Model2.sv` has declared NPORTS = 10 for a long time. Ports
8 and 9 were addressed, arbitrated and counted, and nothing drove them. That is
the state R107 caught. It is also the state that kept the core working.

Extending `tb_m2_sdram` from five ports to ten -- the number the core actually
instantiates -- failed immediately, on the i960's own port.

*Bug one: the read tag is three bits wide and there are ten ports.*

    logic [RD_LAT-1:0][2:0] tag_p;          // declaration
    tag_p[cap_depth-1] <= grant[2:0];       // and the assignment that truncates

`PW = $clog2(NP)` is 4. Ports 8 and 9 therefore aliased onto **0 and 1**: their
read data was written into `p_dout[0]`/`p_dout[1]` and `p_ack` was raised there.
Every TGP table lookup would have handed the i960 a float from the sincos table
in place of the instruction or datum it asked for, and acknowledged it as
correct. Widening the declaration alone does nothing -- the truncation is in the
assignment, and both had to be found.

*Bug two, and it is the more dangerous of the pair: `rd_total` is a single
global register, so ports may not have different burst lengths.* The burst
length is captured once per grant and `tag_last` is computed against it while
words are still being issued. A transaction granted while another is mid-issue
overwrites it, the earlier transaction is then declared complete at the wrong
word, and its result is composed from however much had arrived. Port 0 came back
with two of its four words and zeros above them.

Nothing detects this and nothing bounds which port is hit. It had never fired
because **every port that had ever been active bursts four**, which makes
`rd_total` invariant. Ports 8 and 9 were the first to want anything else.

*What was done, and what deliberately was not.* Bug one is fixed -- the tag is
`PW` bits at both the declaration and the assignment. Bug two is **not** fixed:
ports 8 and 9 burst four like everything else, which makes the defect
unreachable, and the constraint is written into `blen()` where the next person
choosing a burst length will read it. Fixing it properly means reworking the
read-issue sequencing, which is not a change to make on the way to first light
for a coprocessor. **Adding a port with a different burst length reintroduces
silent cross-port data corruption.**

The cost of uniformity is two wasted words per TGP lookup, on a port that blocks
on every lookup anyway. The pair never straddles a row: `tbl_addr`/`dat_addr`
are 32-bit word indices shifted left by one, so the address is always even, and
a row's last column is an odd index -- word 1 is always in the same row as word
0, whatever the burst does after it.

*The lesson is about the test, not the controller.* `tb_m2_sdram` instantiated
five ports because it always had. `blen()` had had ten entries for as long as
`Model2.sv` had had ten ports, and two of those entries described behaviour the
controller could not actually deliver. **A configuration that exists only in the
DUT is not covered by anything**, and the suite reported green throughout. This
is the same shape as R107 one layer down: the guard ran, passed, and was never
looking at the thing that was wrong.

**R109 — the coprocessor is wired in and it runs: 2,024 words uploaded, booted,
46,022 instructions retired. It produces no output yet, and that is now the one
open fault rather than a list of them.** Three things had to be true before this
could be measured at all, and none of them were: `m2_copro` was not instantiated
in `Model2.sv`, `rtl/tgp/*.sv` was not in `Model2.qsf` -- **no build ever
flashed contained a line of TGP** -- and `m2_copro` did not pass the TGP's
`tbl_*`/`dat_*` through, so `tbl_ack` was unconnected and the first math lookup
would have waited forever.

*The math tables were verified against the reference rather than reasoned
about.* MAME's `:copro_tgp_tables` region begins `00000000 38c90fdb 39490fdb` --
sin(0), sin(2*pi/65536), sin of twice that. Of the twenty-four ways to
interleave two 128 KB ROMs into 32-bit words exactly one reproduces it:
opr-14742a supplies bits 15:0 and opr-14743a bits 31:16, each little-endian
within itself. The `.mra` already did this. Checking cost one script, and the
last time a byte order was assumed instead it cost four builds (R94).

*What the boot harness now shows, with the coprocessor in the loop:*

    copro_ctl1        00000000     bit 31 cleared -- the copro was BOOTED
    program uploaded  2024 words   the upload-through-FIFO-write path works
    TGP retires       46022        pc=0046 -- it is EXECUTING
    FIFO in pushed    8            which is the whole depth
    FIFO out popped   0            and nothing has come back
    table reads       1

So the register interface, the bit-31 selector, the program upload, the boot
edge and the processor itself all work. **The input FIFO is at its full depth of
eight and the TGP has returned nothing**, which is precisely why layer 2's
`hscr` is still zero (R106) -- the acceptance test is working as designed, and
currently reporting failure honestly.

The next question is narrow and worth stating so it is not re-derived: 46,022
retires with one table read and no FIFO traffic is a **loop that touches neither
FIFO**. Either the TGP is not seeing `fifo_in_valid` where its microcode looks
for it, or it is waiting on something tied off -- the RAM window is acknowledged
immediately with zero (`dbg_ram_req` exposes it) and that is the obvious
suspect. A TGP program-counter trace is the instrument; the retire counter and
`dbg_pc` are already brought out for it.

*Fit, which rule 11 makes a study-level number rather than an implementation
detail.* With the whole coprocessor in:

    ALM          33,248 / 41,910   79%
    M10K            452 / 553      82%     (438 before, so the TGP cost 14)
    registers    44,817
    DSP              45 / 112      40%

**It fits, with 8,662 ALM and 101 M10K blocks in hand.** The ~25,000 ALM figure
the study has carried for i960-plus-renderer is not the ceiling it was treated
as; the ceiling is the part, and the part has room. Speed remains the open
problem (R104), and nothing here changes that.

*One incidental removal.* `m2_tgp` had an `initial` block zeroing
`sincos_base`, `inv_base`, `isqrt_base` and `atan_base`, every one of which is
already cleared in the reset branch of the always_ff above it. Pure redundancy,
and Verilator reports the pair as MULTIDRIVEN -- an error under -Wall, which
stopped the boot harness building the moment the coprocessor was added. The unit
flow never saw it because `TGPFLAGS` filters more widely than the harness does.
Removed rather than silenced; all ten TGP suites still pass unchanged.

**R110 — RETRACTED, SEE R116. The claim below is wrong and the fix it
describes was reverted.** It rested on a mis-addressed read of MAME's program
space and would have discarded three of every four program words.

~~The coprocessor FIFO port is NOT burst-capable, the i960 uploads with
quad-word stores, and taking all four dwords stretched the TGP program four to
one.~~ This was the whole of the "coprocessor runs but produces nothing" fault,
and it is one line.

`model2.cpp` says it in what it does not write:

    map(0x00804000, 0x00807fff)...flags(i960_cpu_device::BURST);   geometry program
    map(0x00880000, 0x00883fff)...flags(i960_cpu_device::BURST);   function port
    map(0x00884000, 0x00887fff).rw(copro_fifo_r, copro_fifo_w);    <- NOT flagged

The i960 stores quads. A burst-capable port takes all four dwords; this one
takes the FIRST and the bus drops the other three. Our bridge decomposes the
quad into four ordinary writes and `m2_copro` accepted every one.

*How it presented, because the symptom pointed everywhere except here.* The
upload looked perfect. `copro_ctl1` went `0 -> 80000000 -> 0` exactly once, with
2,024 words between, matching MAME's own control sequence edge for edge. The
2,024 words were verified **byte-identical to MAME's first 2,024 writes** on the
same port. The TGP then executed that program faithfully -- our `0x49` held
`fe000044`, literally "branch to 0x44", so the dead loop was correct behaviour
for the program it had. Every component was right and the composition was wrong.

*What settled it.* MAME's resident program satisfies

    program[i] == write[4i]     0 mismatches across all 506 words

and every one of those writes sits at a 16-byte-aligned offset. 2,024 / 4 = 506,
which is also exactly the count of non-zero words in MAME's program store -- a
number that had been sitting in the evidence for some time being read as a
coincidence.

*Two false trails, recorded because both cost time and both were reasonable.*
First, the tied-off TGP RAM window was the prime suspect for a processor that
retires without doing work; `dbg_ram_req` measured **zero** cycles and cleared
it outright. Second, 2,024 was read as four uploads of 506 and the bit-31 edge
detection was suspected; logging the control writes showed a single upload and
cleared that too. Both were answered by instruments rather than by argument,
and the instruments are worth more than the answers: a PC histogram and sequence
for the TGP, the io-address histogram, and `dbg_op` -- the word AT the fetched
PC, which is what finally separated "wrong program" from "wrong decode".

*The fix and its result.* `copro_fifo_sel` gains `cpu_io_addr[3:2] == 2'b00`.
The upload becomes 506 words, `program[0x4c]` and `program[0x57]` match MAME
exactly, and the TGP settles at **pc 0x4c-0x52 -- MAME's own wait loop**, where
MAME's TGP spends 63% of its time. It is running the reference's program from
the reference's addresses.

*Still open, and stated so it is not mistaken for done.* The TGP consumes
commands (37 pushed, and the pushes continue past the 8-deep FIFO, so they are
being drained) but has pushed nothing OUT. MAME issues roughly 65,000 command
words over 300 frames against our 37, so the i960 is barely feeding it -- which
is consistent with the game not yet being in the 3D path, and with layer 2's
`hscr` still reading zero (R106). Whether that is a second fault or simply the
game not having got there is the next question, and the acceptance test is
unchanged.

*The generalisation.* Bus ACCESS WIDTH is part of a port's contract, not a
detail of the master. Three ports in ten lines of `model2.cpp` differ only in a
flag, and the flag decides whether a device sees one word or four. Every port
this core implements should be checked against that map for the same thing.

**R111 — the coprocessor FIFOs BLOCK BOTH PROCESSORS IN BOTH DIRECTIONS, and
this core implements none of it; two of the four cases silently discard data.**
The specification is not inferred. It is `model2.cpp`'s `machine_start`, read
against the callback order in `devices/machine/gen_fifo.h`:

    m_copro_fifo_in->setup(8,
      [] { m_copro_tgp->stall(); },                 // pop on empty  -> STALL the TGP
      [] { m_copro_tgp->HALT   ASSERT; },           // still empty   -> HALT the TGP
      [] { m_copro_tgp->HALT   CLEAR;  },           // data arrives  -> resume
      [] { m_maincpu->HALT     ASSERT; },           // push on full  -> HALT THE i960
      [] { m_maincpu->HALT     CLEAR;  }, ...

    m_copro_fifo_out->setup(8,
      [] { m_maincpu->i960_stall(); },              // pop on empty  -> STALL the i960
      [] { m_maincpu->HALT     ASSERT; },
      [] { m_maincpu->HALT     CLEAR;  },
      [] { m_copro_tgp->HALT   ASSERT; },           // push on full  -> HALT the TGP
      [] { m_copro_tgp->HALT   CLEAR;  }, ...

`gen_fifo.h` states the contract in its own header: a pop on an empty FIFO
"must ask the destination to try again (e.g. ->stall() or equivalent)", and if
it is still empty after the sync "the destination device should be halted".

*What this core does instead, all four wrong and two of them destructive:*

| case                          | hardware        | `m2_copro` |
|-------------------------------|-----------------|------------|
| TGP pops empty input          | stall, then halt| runs on    |
| i960 pushes into full input   | halt the i960   | **word dropped** |
| i960 pops empty output        | stall, then halt| returns 0  |
| TGP pushes into full output   | halt the TGP    | **word dropped** |

The two drops are `else if (!fin_full)` and `if (tgp_out_push && !fout_full)`.
Both look like sensible overflow guards and both are data loss: on the real
board the FIFO going full is not an error, it is the flow control.

*This explains the measurement that started the hunt.* The TGP runs Daytona's
wait loop at 0x4c-0x57 **thirty million times without ever blocking** -- every
address in the loop carries an identical sample count, so it is not stalling
anywhere -- while MAME's TGP parks at 0x4c for 63% of its samples. A processor
that should be asleep is instead spinning, and a full input FIFO silently eats
the commands aimed at it. Only 37 pushes were ever recorded against MAME's tens
of thousands.

*It also retires a red herring.* `EMPTY_FIFO_READS_ZERO` in `m2_tgp` was the
prime suspect and it is the wrong layer: the question is not what an empty read
RETURNS, it is that the read must not complete at all. The fix is a handshake,
not a value.

*Scope, stated because it is larger than it looks.* Halting the i960 is not
something `m2_copro` can do by itself -- it needs the bus to hold, which means
`m2_cpu_bridge` must withhold its acknowledge for a copro access that cannot
complete. That is the same mechanism the SDRAM path already uses, so the
machinery exists, but it crosses a module boundary and the i960 has never been
made to wait on a peripheral before. **The FIFOs are flow control, not
buffers**, and a design that treats them as buffers loses commands rather than
slowing down.

**R112 — the ported TGP looks for its FIFOs at MODEL 1's addresses, which do
not exist on Model 2.** This is the root cause of "the coprocessor runs and
produces nothing", and it is the Model 1 inheritance the port never had checked.

`rtl/tgp/mb86233_mem.sv`:

    assign sel_fifo_in  = (addr == 17'h00100) && !we;
    assign sel_fifo_out = (addr == 17'h00400) &&  we;
    // comment cites copro_data_map -- which is MODEL 1's map

Model 2's own data map has neither address:

    void model2_tgp_state::copro_tgp_data_map(address_map &map)
    {
        map(0x0000, 0x00ff).ram();
        map(0x0200, 0x03ff).ram();
    }

0x100 and 0x400 are holes. Model 2 puts the FIFOs in the REGISTER FILE space,
which this port does not implement at all:

    void model2_tgp_state::copro_tgp_rf_map(address_map &map)
    {
        map(0x0, 0x0).nopw();                      // leds? busy flag?
        map(0x1, 0x1).r(m_copro_fifo_in,  read);   // commands IN
        map(0x2, 0x2).w(m_copro_fifo_out, write);  // results OUT
        map(0x3, 0x3).w(copro_tgp_bank_w);         // memory window bank
    }

*Measured on both sides, which is what makes it certain rather than plausible.*
MAME pops the input FIFO **484,947** times in 300 frames, and a tap carrying the
TGP's PC says **226,998 of those are at pc 0x004c** -- the instruction
`012f4614` at the head of Daytona's wait loop -- with the rest at the command
handlers (0x311, 0x316, 0x308, 0xbf, 0xc0, 0xba...) it only reaches once it has
data. This core executes 0x004c **49 million times** and asserts `fifo_rd`
**94** times. It runs the right instruction at the right address and does not
recognise it as a FIFO access.

*What this retires.* Three separate theories died on this measurement, all of
them reasonable and all of them wrong:
  * that the TGP was too SLOW -- the arithmetic says the stream needs 1.1 M
    instr/s and we have 5.1 M at 50 MHz, five times over. Clocking was never
    the blocker.
  * that `EMPTY_FIFO_READS_ZERO` was the fault. It WAS a real defect -- the
    parameter was declared, its reasoning documented at length, and the
    instantiation never passed it, so an empty read withheld its acknowledge and
    stalled the processor. Fixing it dropped `fifo_rd` from 154,767,628 stalled
    cycles to 94. It was necessary and it was not sufficient.
  * that the FIFO flow control was missing in all four directions (R111). Only
    the writer-on-full case was actually wrong; a pop on empty returns zero by
    design, and the microcode needs that zero.

*The shape of the fix.* The register-file space has to exist: rf 1 read is the
input FIFO, rf 2 write is the output FIFO, rf 3 write is the bank register that
drives the `copro_tgp_memory_r` window, rf 0 is ignored. That means the decoder
must route rf accesses distinctly from data accesses -- MAME's device declares
AS_RF as a fourth address space alongside program, data and io, and this port
folded it into data.

**The generalisation is the one the whole session keeps arriving at.** The TGP
core was lifted from the Model 1 project and every module was fuzz-verified
against a reference -- ten suites, all passing. What was never verified is the
part no unit test can see: WHICH MACHINE IT IS PLUGGED INTO. `copro_data_map`
is named in the comment. Nobody checked that Model 2 has a different one.

**R113 — the register-file routing works: the TGP now drains Daytona's command
stream at the reference rate and receives the correct words. What remains is the
DISPATCH, and it was validated against a Model 1 game.** R112 named the fault;
this records the fix and what it exposed underneath.

*The fix.* `mb86233_regs` routes rf index 1 to the input FIFO and index 2 to the
output FIFO, and `mb86233_core` ORs that path with the old data-space one so the
module stays usable on both machines -- on Model 2 the data addresses are holes
and never fire, on Model 1 the register indices are ordinary storage and never
fire. Measured before and after:

    TGP popped        31  ->  435,204      (MAME: 484,947)
    fifo_rd cycles    94  ->  2,935,127
    input FIFO        permanently full -> 3 outstanding

It is draining at essentially the reference rate.

*And the words are right.* The first popped values against MAME's own push
stream, same point in the boot:

    MAME  00000000 00000000 41000000 00000000 3b8e38e4 438e8000 3f9e5556 3fb98e39 42e00000 ...
    ours  00000000 00000000 41000000 00000000 3b8e38e4 438e8000 00000000 3fb98e39 42e00000 ...

Identical but for one word. The command path is correct end to end.

*What is still wrong, stated precisely so it is not re-derived.* The TGP visits
23 program addresses, all of them the 0x4c-0x57 wait loop, and NEVER reaches the
command handlers MAME reaches (0x311, 0x316, 0x308, 0xbf, 0xc0, 0xba, 0x30c,
0xb5). The dispatch at 0x52 is `brul alw d` with `d = get_exp(b) + 0x53`, so
b = 0 selects 0x53, the idle handler. Ours resolves to 0x53 every time while
holding correct, non-zero command words -- so either `d` is not being computed
from the popped value, or the computed branch is not taking the register value.

*The provenance is the point.* `mb86233_core.sv` records that the branch was
built and verified against "the **vr** microcode", which "has exactly one brul
(0x0052, register form, reg 0x19)". `vr` is Virtua Racing -- a MODEL 1 game.
The same file states outright that the MEMORY form "is not built yet". So the
computed branch has been exercised by exactly one instance of one form in one
Model 1 title, and Daytona's dispatch runs through it thousands of times a
frame.

**This is the third distinct Model 1 inheritance to surface in one session**,
after the FIFO addresses (R112) and `EMPTY_FIFO_READS_ZERO` never being passed.
The pattern is consistent and worth stating as a rule: **every module in
`rtl/tgp/` was fuzz-verified against a reference, and the reference was Model
1.** Passing unit tests say the module matches what it was compared against;
they say nothing about which machine it is plugged into. Anything in that
directory whose comments cite a Model 1 driver, a Model 1 game, or a Model 1
address map should be treated as unverified for this project until checked
against `model2.cpp`.


**R114 - the coprocessor now pops correctly and register B is NEVER WRITTEN;
the break is downstream of the FIFO, in the store-and-reload the microcode does
between them.** R113 left the TGP draining the command stream at the reference
rate while never dispatching. This narrows that to one register.

*Measured over a full boot, sampling EVERY CYCLE rather than at the pop -- the
write-back lands a cycle later, so a sample taken at the pop sees the old value
and proves nothing:*

    A  non-zero for  3,211,781 cycles      last 0000382d
    B  non-zero for          0 cycles      NEVER WRITTEN
    D  non-zero for 41,953,870 cycles      last 7fc00000  (a NaN)

The dispatch is `D = get_exp(B) + base`. With B permanently zero it can only
ever select the idle handler, which is exactly the observed behaviour: 23
program addresses visited, all of them the wait loop, none of MAME's handlers.
D holding a NaN says the arithmetic downstream is running on nothing.

*Our pop decode is CORRECT, and establishing that meant undoing a wrong
conclusion reached an hour earlier.* The instruction this core pops on,
`1c1f2021`, is class 0x07 sub-op 7 with `r2 >> 6 == 6` -- MAME's
`case 6: mov reg, reg`, which does `read_reg(r1)` then `write_reg(r2, v)`.
r1 = 0x021 is register 0x21, which `read_reg` maps to rf 1, the input FIFO.
r2 & 0x3f = 0x10, register A. So `1c1f2021` is `mov rf1, A` and popping there is
right. The earlier reading of this file allowed only `r2 >> 6` of 0 or 1 to
reach `read_reg` and therefore called our pop site wrong; case 6 reads r1 and
was missed.

*And MAME's CURPC is NOT usable for attributing memory accesses on this device.*
A tap on the rf space reported 147,299 FIFO reads at pc 0x004c, whose program
word is `012f4614` -- class 0x00, `lab`, which never calls `read_reg` at all.
Other rows named pcs 0x308/0x311/0x316, all beyond the 506-word program, whose
words read `00000000`. **PC-attributed measurements from a MAME memory tap must
be corroborated by decoding the opcode**, which is what finally identified the
real popping form.

*Where the fault now sits.* `lab` (class 0x00 op 3) loads A from `ea_pre_0(r1)`
and B from `ea_pre_1(r2) + 0x200`; at 0x4c that second address is `x1 + 0x200`,
which on Model 2 is ordinary data RAM (`copro_tgp_data_map` maps 0x200-0x3ff).
So B is loaded FROM RAM, and the RAM is empty. The microcode's flow is
pop -> A -> STORE to data RAM -> later `lab` reloads it into B. A is right and
the reload is empty, so the STORE is the next thing to verify: whether this core
issues that data write at all, and to the address the reload expects.

This core's `lab` is not the suspect: `S_LABB`/`S_LABB_W` capture both operands
and `S_LAB_WA`/`S_LAB_WB` write A then B, with a recorded fix for exactly the
bug of reading the second operand and discarding it.

*Verified, same run: the store never happens.* A counter on the exact condition
the RAM itself uses (`req && we && (sel_ram0 || sel_ram1)`, the same expression
as `ram0[a0] <= wdata`) reports **ZERO data-RAM writes** across a full boot,
against 58,645 successful FIFO pops. The TGP takes commands into A and never
stores anything, so `lab` reloads an untouched RAM into B, B stays zero, and the
dispatch can only ever select the idle handler.

That is the frontier: **this core issues no data-space write for any
instruction.** Whether that is a missing destination form in the decoder or a
`mem_we` that never asserts is the next thing to establish, and it is a
contained question -- one signal, one condition, and a working reference to diff
against.

**R115 - the FIFO register can now stall the pipeline, and the remaining
divergence is control flow: we enter a wait loop the reference never enters.**

*Fixed.* A register source completed in one cycle unconditionally, because
before Model 2 no register could ever be busy. On Model 2 the input FIFO IS
register 0x21, so `S_SRC` must be able to hold: MAME's pop on an empty FIFO
returns zero AND calls `stall()`, and `goto do_stall` re-executes the
instruction, so the read does not retire until a command arrives. The core now
holds in `S_SRC` while `rf_fifo_rd && !fifo_ack`. Measured: **196,842,195 hold
cycles** in one boot, with 58,633 commands still consumed. `EMPTY_FIFO_READS_ZERO`
goes back to 0 -- the stall is the behaviour, and the zero it returns matters
only for the value, not for whether the instruction completes.

*Verified against the reference, instruction for instruction.* The class 0x07
sub-op 7 table in `mb86233_xfer.sv` matches MAME's inner switch exactly -- case
0 `mov reg,mem`, 1 `mov reg,mem(e)`, 2 `mov mem+0x200,reg`, 3 `mov mem,reg`,
4 `mov mem(e),reg`, 5 `mov mem(o),reg`, 6 `mov reg,reg`. Two earlier suspicions
were wrong and are recorded as such: `0xb6` is `mov mem(e),reg`, an IO read and
not a store, and the `0x4c` handler entry really is only three instructions
(`b5, b6, b7`) because `0xb7` is `brif always -> 0x4c`.

*The divergence, located.* This core runs
`0000 -> 0010..0015 -> 0016 -> 00b5 00b6 00b7 -> 004c` and then the 0x4c-0x57
loop for ever. That loop has NO conditional exit -- 0x53/0x54/0x56 are `ldi` and
transfer forms, 0x57 is `brif always` back to 0x4c -- so it is a terminal state,
and its only pop (0x55) writes A, never B.

**The reference is not in that loop.** Its hottest TGP data reads are 000, 07f,
070, 073, 068 -- handler addresses -- and 0x14, which the loop's `lab` reads
every single iteration, does not appear in the top twelve at all. MAME's B also
takes popped command values (B = 12002424 immediately after data = 12002424),
which only 0x11/0x13 can do, so its dispatch loop is 0x10-0x15 plus the jump
table at 0x16-0x28, returning to 0x10 -- not 0x4c.

So we take jump-table **entry 0** because `D = get_exp(B)` with B = 0, and entry
0 leads to the terminal loop. The question for next session is narrow: what does
the reference compute for D at the first dispatch, and by what path does it
return to 0x10 rather than falling into 0x4c. Note the first two command words
in the stream ARE 00000000, so B = 0 at the first dispatch is not by itself
wrong -- the reference must leave the loop by a route this core does not take.

*A measurement caveat worth keeping.* MAME's `CURPC` cannot be trusted inside a
memory tap on this device: it attributed 147,299 rf reads to pc 0x004c, whose
word is class 0x00 `lab` and cannot call `read_reg` at all, and named pcs beyond
the 506-word program whose words read 00000000. Every PC-attributed measurement
here was re-derived by decoding the opcode instead.


**R116 - R110 WAS WRONG, and the error was a mis-addressed read of MAME's
program space that manufactured its own corroboration.**

The TGP's program space is WORD-addressed (`32, 16, -2`). It must be read as
`ps:read_u32(word)`. Every dump this project took read `ps:read_u32(word * 4)`.

*What that produced.* Sampling word*4 across a 2024-word program lands inside it
only while `a*4 < 2024`, i.e. for the first **506** samples. That is the entire
provenance of the "506-word program" -- a number that then appeared to confirm
`program[i] == write[4i]` with zero mismatches, because both sides of the
comparison were drawn from the same aliased sampling. 2024 / 4 = 506 was read as
a burst ratio when it was an artifact of the stride.

*Read correctly, in one run against a fetch tap that reports true word indices:*

    MAME program: 2024 non-zero words of 4096
    program[i] == write[i]   :  32 mismatches over 2064   <- 1:1
    program[i] == write[4i]  : 521 mismatches over 525    <- nonsense

`copro_fifo_w(u32 data)` pushes once per call and the map carries no burst flag
for a reason: **one write is one word.** The `cpu_io_addr[3:2] == 2'b00` filter
R110 added was discarding three of every four program words, and is reverted.

*Immediate effect of the revert, same harness, same run length:*

    program uploaded   506 -> 2024 words
    B non-zero           0 -> 12,062,975 cycles
    data-RAM writes      0 -> 50
    trace now executes the whole 0x10-0x3e init block

*What else this retracts.* Every static decode in R112-R115 that quoted program
words -- the "0x4c-0x57 wait loop", the "jump table at 0x16-0x28", the decode of
`012f4614`, the handler listing at 0xb5 -- was read from the wrong addresses and
must be redone. The MEASURED findings in those entries survive, because they
compared this core against the reference through counters rather than through
disassembly: the rf-space FIFO routing (R112), the FIFO stall in S_SRC (R115),
the unpassed `EMPTY_FIFO_READS_ZERO`, and the pop/push rates. It is the
instruction-level archaeology that has to start again.

*The lesson, and it is the third time this session in a different costume.*
R107 was a guard that could not see the fault. R114 was a PC attribution that
could not be trusted. This is a memory read whose ADDRESS UNIT was never
checked against the device's own space configuration -- and it did not fail
loudly, it returned plausible instruction words from the wrong places and
supported a theory for two days. **Before reading a device's memory from a
debugger or a script, verify the address unit against something the device
itself produces.** The fetch tap was that something, and it took ten minutes.

**R117 - PARTLY WRONG, SEE R119.** The measurement stands -- the i960 does push
zeros and the FIFO transmits them faithfully -- but the conclusion drawn from
it, that the fault is upstream of the TGP, does not. The zeros are the i960
READING this core's empty output FIFO.

~~The coprocessor is faithful; the i960 is pushing zeros. The fault is
upstream of the TGP entirely.~~

A lock-step diff of the command stream, ours against the reference's own writes
to the FIFO port, over the first 76 commands after the program upload:

    idx  ours      MAME
      4  3b8e38e4  3b8e38e4
      5  438e8000  438e8000
      6  00000000  3f9e5556   <<<
      7  3fb98e39  3fb98e39
     ...
     13  00000000  4260e0e2   <<<

**18 of 76 differ, and every one of them is ours reading 00000000.** The popped
stream shows the identical 18 mismatches at the identical indices, which is the
point: the FIFO delivers exactly what it was given, in order, and the TGP
consumes exactly what the FIFO delivers. Nothing between the i960 and the
coprocessor loses or reorders anything.

So the values are wrong before they are ever pushed. `3f9e5556` is about 1.238
and `4260e0e2` about 56.2 -- ordinary single-precision geometry values, and
roughly a quarter of them come out of this core as zero.

*What this closes.* The TGP investigation is finished for now. Its FIFO routing
(R112), its stall behaviour (R115), its decode table, its data-RAM
initialisation and its instruction trace all match the reference. It sits in the
drain loop because `get_exp(B)` of a zero command is zero, which is the correct
response to the input it is given.

*What it opens.* The i960's floating point. Every FP unit here passes a fuzz
suite against a reference model -- fpadd, fpmul, fpdiv, fpsqrt, fpmisc, fpcvt --
so the arithmetic is not obviously wrong in isolation. That leaves the
integration: which instruction form reaches which unit, operand selection,
result forwarding, or a path that silently returns zero. The project already has
the instrument for this in `tools/i960-diff.sh` and `i960-datadiff.sh`; the task
is to find the instruction that should produce 3f9e5556 and see what it does
instead.

*The generalisation, and it is the same shape as R116.* Two days were spent
inside the coprocessor because that is where the symptom appeared. The symptom
was downstream of the fault by an entire processor. **A component that faithfully
transmits bad input looks exactly like a broken component**, and the only thing
that separated them was comparing the DATA at the boundary rather than the
behaviour inside.

**R118 - the wrong value is register r3, computed in a nine-instruction window,
and r4 beside it is correct.** R117 established that the i960 pushes zeros where
the reference pushes floats. This narrows that to one register and a few
instructions.

The reference's i960 registers at the FIFO writes either side of the first
mismatch:

    push#6  pc=0000e2a8  data=438e8000   r3=438e8000  r4=3b8e38e4
    push#7  pc=0000e2cc  data=3f9e5556   r3=3f9e5556  r4=3fb98e39

Both pushes are `st` of a register to the FIFO port. Between 0xe2a8 and 0xe2cc
the program recomputes BOTH r3 and r4. **This core gets r4 right -- 3fb98e39
matches, and it is the next value we push -- and r3 comes out zero.** So the
divergence is a single value produced somewhere in

    e2ac  5cf01e00   REG
    e2b0  921f6038   st
    e2b4  921f6044   st
    e2b8  90203000   ld     (MEMB: 028b57a4 at e2bc is its displacement, not
    e2c0  8cf00303   lda     an opcode -- do not decode this window as one
    e2c4  92f6e030   st      instruction per word)
    e2c8  921edc1c   st

*Why r4 being right matters.* It rules out a wholesale failure of the FP path or
of this code being reached at all: the same window computes two values, one
correct and one zero. Whatever is wrong is specific to how r3 is produced, not
to the block.

*What is NOT yet established.* Whether this core executes the same instruction
sequence through that window. A branch taken differently would produce the same
symptom, and the PC stream through 0xe2a0-0xe2d4 has not been compared. That is
the next measurement, and `tools/i960-diff.sh` exists for it -- though it drives
the standalone ROM harness, which does not reach this depth of boot, so it needs
the boot harness's own PC trace (M2_BOOT_PCTRACE with M2_BOOT_PCFROM) against
MAME's.

*A decoding trap recorded because it cost time here.* i960 MEMB instructions
carry a 32-bit displacement in a second word. Walking this region four bytes at
a time produced `op=02` at 0xe2bc, which is not an i960 opcode at all -- it is
the displacement of the `ld` before it. Any hand decode of i960 code must track
instruction length, and the plausible-looking opcodes on either side are exactly
what makes the error easy to miss.

**R119 - the i960 is not computing those zeros, it is READING them out of the
coprocessor's empty output FIFO. The loop is a deadlock this core starts.**

A breakpoint-anchored disassembly of the window R118 narrowed, from the
reference itself:

    0000E2A8: ld      (g11)[g12],r3     <- READ the copro OUTPUT fifo into r3
    0000E2AC: mov     0,g14
    0000E2B0: st      r3,0x38(g13)
    0000E2B4: st      r3,0x44(g13)
    0000E2B8: ld      0x28b57a4,r4      <- r4 is a plain memory load
    0000E2C0: lda     0x303,g14
    0000E2C4: st      g14,0x30(g11)
    0000E2C8: st      r3,(g11)[g12]     <- push r3 BACK to the copro
    0000E2CC: st      r4,(g11)[g12]     <- push r4

g11 = 0x00880000 and g12 = 0x00004000, so `(g11)[g12]` is 0x00884000: the
coprocessor FIFO port. **r3 is a coprocessor RESULT, not an i960 computation.**
r4 is a constant fetched from memory, which is exactly why this core gets r4
right and r3 wrong -- the one value that depends on the TGP is the one that
comes out zero.

*So the causal chain runs the other way from R117.* The TGP produces no output;
the i960 reads its empty output FIFO and gets zero; the i960 pushes that zero
back as the next command; the TGP dispatches on `get_exp(0) = 0`, takes its idle
handler, and produces no output. **It is self-sustaining, and this core starts
it.** Every downstream observation -- 18 of 76 commands zero, B never carrying a
real command, the drain loop never exiting -- is that one fact echoing.

*What R117 got right and what it got wrong.* The measurement was sound: the i960
does push zeros, the FIFO does transmit them faithfully, and the pop stream does
carry the same mismatches at the same indices. The error was reading "the value
is wrong before it is pushed" as "the i960 computed it wrongly", when the i960
had loaded it from the coprocessor a few instructions earlier. **A value being
wrong at a boundary says nothing about which side produced it until you know
where it came from.**

*Where this puts the work.* Back inside the TGP, but with a far better question
than before: the first three commands (00000000, 00000000, 41000000, then
00000000, 3b8e38e4, 438e8000) are pushed at 0xe098-0xe0a0 and 0x3948-0xe2a8,
and the reference's TGP answers them before the i960 reads at 0xE2A8. This core
never answers. So the question is not "why does the TGP produce nothing over a
whole boot" but "what does the reference's TGP do with those first six words,
and where does this core's handling of them stop" -- a bounded window with a
known input and a known expected output.

*Tooling note.* `tools/i960-trace.sh` works and produces disassembled traces,
but its SETTLE_MS path fails for large settles and its `gtime` did not land the
window where expected. Anchoring with `bpset <addr>` and then tracing is exact
and cheap, and it is how this was finally read. The trace is UPPERCASE hex --
a case-sensitive grep for the address finds nothing and looks like absence.

**R120 - THE COPROCESSOR WORKS. The missing piece was a second write port whose
ADDRESS carries the command code.**

`model2.cpp` maps two write ports into the coprocessor, not one:

    map(0x00880000, 0x00883fff).w(copro_function_port_w).flags(BURST);
    map(0x00884000, 0x00887fff).rw(copro_fifo_r, copro_fifo_w);

and the first is where commands come from:

    void copro_function_port_w(offs_t offset, u32 data) {
        u32 d = data & 0x800fffff;
        u32 a = (offset >> 2) & 0xff;
        d |= a << 23;
        m_copro_fifo_in->push(u32(d));
    }

**The command code is the ADDRESS.** `(offset >> 2) & 0xff` -- bits 11:4 of the
byte address -- is folded into bits 30:23 of the pushed word, which is exactly
the field `get_exp()` reads. The microcode dispatches on it. The data half is
only the payload, masked to 0x800fffff.

This core decoded 0x884000 and 0x980000/4 and **not** 0x880000, so every command
the game issued went nowhere. The coprocessor received payloads and never a
command code.

*Everything else followed from that one omission.* `get_exp(B)` was never the
value the drain loop at 0x44-0x49 waits for, so it never exited; nothing was
ever produced; the i960 read the empty output FIFO at 0xE2A8, got zero, pushed
that zero back as the next command, and the pair sat in a self-sustaining
deadlock. R117's "the i960 is computing zeros", R118's "r3 is wrong in a
nine-instruction window" and R119's correction were all that single fact seen
from further and further downstream.

*Result, same harness, same run length:*

    FIFO out popped   0 -> 3          the coprocessor produces results
    B non-zero        0 -> 79,331,117 cycles, last 12802525
    data-RAM writes  50 -> 54

and the instruction trace now matches the reference exactly through the
divergence and beyond:

    0049 004a 004b 0055 0056 0057 0060 010a 010b 010c 010d 004c ... 0057 007d

which is the reference's own path into the steady-state loop, including the
0x7d -> 0x30a output push. `12802525` is precisely the command MAME pops at
0x4c in steady state.

*How it was found, because the method is the transferable part.* Not by reading
the coprocessor. By asking where a specific value came from: the reference's
TGP popped `04000001` at frame 13 with exponent 8, the drain loop's exit
condition; a tap on the FIFO port showed that word was NEVER written there; so
something else pushed it. Six lines of `grep -n "copro_fifo_in->push"` named
every writer, and one of them was a port this core had never decoded.

**The lesson is the one this project keeps paying for: a symptom seen from
downstream tells you where it surfaced, not where it started.** Two days were
spent inside the coprocessor, then a day inside the i960, for a missing address
decode at the top level.

**R121 - THE DEBUG UART IS READABLE OVER SSH. There is no cable, and there never
was one.**

`sys_top.v` drives `cyclonev_hps_interface_peripheral_uart`, which is the HPS's
own UART bonded into the fabric. `UART_TXD`/`UART_RXD` have **no pin assignment
anywhere in the QSF** -- they cannot be on a header, because nothing places them
there. On the board's Linux side the stream is `/dev/ttyS1`:

    stty -F /dev/ttyS1 115200 raw -echo
    timeout 8 cat /dev/ttyS1

Measured: 61,340 bytes in 8 s, 38,276 in 5 s, reproducible, nothing else holding
the port. `screen /dev/ttyS1 115200` works too and is the same channel; the
reason `cat` matters is that it is **scriptable**, so telemetry can be grepped,
counted and diffed against MAME automatically instead of read off a terminal.

*What this supersedes.* The standing rule "the screen is the only output
channel -- no serial, no printf, no debugger" was true when written and is no
longer. `m2_dbg_stream` made the board programmatically readable and the rule
has been shaping design decisions past its expiry. The overlay is still the
right tool for something to be watched while playing; the UART is the right tool
for anything to be counted or compared.

*The limit worth knowing.* Flow control is drop, not stall, and channel A
starves channel B: an 8-second capture gave 3,015 'S' records against 52 'H'.
Sufficient for a value sampled once a frame, not for anything bursty.

**R122 - THE i960's ATTRACT-MODE PROFILE MATCHES THE REFERENCE. The spin is
correct behaviour and was nearly read as a fault.**

Measured on the board over UART, build 18:

| | this core | MAME |
|---|---|---|
| in `0x12B0`/`0x12B8` | **66%** | **69.2%** |
| instruction rate | 4.148 M/s (CPI 5.79 at 24 MHz) | ~6.4 M/s |
| instructions/frame | ~69,000 | ~107,101 |
| non-spin work/frame | ~23,500 | 29,208 - 30,949 |

The loop is `ldob 0x500000,r3` / `cmpibe r3,g0,0x12b0`, and `0x00500000` is plain
work RAM -- so the byte is set by an interrupt handler, and the loop is the
game's frame sync. The study already established (S5793) that **the total is
capacity, not demand**: the CPU spins to fill whatever time is left. Our lower
instruction count is a higher CPI spending its shortfall on *spin* iterations,
not on work, which is why the work figures agree.

*The trap, recorded because it was walked into.* The same capture showed **148
distinct IPs against MAME's ~5,000**, which reads as a catastrophically narrow
working set. It is not evidence of anything: MAME's figure counts every PC in a
107,000-instruction frame, ours is 4,300 sparse samples read one ring entry per
profiler tick. **You cannot observe 5,000 distinct values in 4,300 samples.**
Any comparison between a full trace and a sampled one must reconcile the
sampling rate first, or it manufactures a fault.

**R123 - LAYER 2's `hscr` IS STILL ZERO, MEASURED, ON A BUILD WHERE EVERY
PREVIOUSLY SUSPECTED CAUSE IS EXCLUDED.**

52 samples over ~480 frames, build 18, all `0000`. The reading is sound: the
UART packs low bytes only, so layer 2's `vscr = 0x2000` correctly appears as
`00`, but MAME's `hscr` baseline of `000c 0018 001b 0197 016e 007d` has low
bytes `0c 18 1b 97 6e 7d` -- every one of them would be visible.

What is now excluded, each independently established:

  * the i960 runs the full attract sequence and profiles like the reference
    (R122), and the reference visibly scrolls the ground as the car rounds the
    track at this point
  * the tile fetcher honours the register -- `map_x = x - hscr`,
    `split_x = hscr & 0x1ff`, `e_off = sx[8:0] - hscr[8:0]`
  * the decode is complete and correct (R106)
  * the function port is decoded and the TGP executes the reference's program
    from the reference's addresses (R120)
  * timing passes on every clock (build 18: +0.203 worst setup)
  * the i960 is never held -- `stall` is tied to zero

So the fault is in the coprocessor's **return** path, and R106's acceptance test
remains the right instrument: `hscr` leaving zero is the first evidence the TGP
works, and it has not left zero.

*Why this took another build.* Every counter that could name the half at fault
-- `dbg_out_pushed`, `dbg_out_data`, `dbg_in_dropped`, `dbg_out_dropped` -- was
**tied off** in `Model2.sv`. They existed in `m2_copro` and were connected to
nothing. A debug output that is driven and unread is not instrumentation; grep
for a count of 2 (declaration plus instantiation) to find the rest.

**R124 - MODEL 2 HAS A SECOND PROCESSOR THIS CORE HAS NOT BUILT, AND THE
RASTERISER BRACKET WAS QUOTED AGAINST THE WRONG MODULE.**

The copro TGP at `0x880000`/`0x884000` is not the geometry engine. `model2.cpp`
maps a separate microcoded engine at `0x800000`/`0x804000` with its own program
upload (`geo_prg_w`), ~21 opcodes (`geo_object_data`, `geo_matrix_write`,
`geo_light_source`, `geo_texture_parameters`, `geo_zsort_mode`,
`geo_code_upload`, `geo_code_jump`) and four polygon-transform loops --
`geo_parse_np_ns`, `np_s`, `nn_ns`, `nn_s`, being normals present or absent
crossed with smooth or flat. None of it is implemented. `m2_copro.sv`'s own
header flagged it and it was read as a naming note rather than a work item.

Model 1 has the same split and confirms it: `m1_tgp.sv` **and** `m1_geometry`
both exist.

*The area consequence, which corrects a figure quoted earlier the same day.*
`m1_raster3d` at 6,977 ALM is not a rasteriser -- its own header lists
`m1_listwalk`, `m1_geometry`, `m1_quad_store`, `m1_raster_fill`,
`m1_raster_band`. The rasteriser proper is `m1_raster_fill` at **2,113 ALM,
1,110 bits, 2 DSP, 63.67 MHz** (m3-rasterizer-spec.md), which sits just under
VDP1's 2,537 and confirms the bracket's floor.

So both figures are right and they measure different things:

| | ALM | covers |
|---|---|---|
| VDP1 | 2,537 | quad rasteriser, no Z, no filtering |
| `m1_raster_fill` (+ divider) | 2,113 | quad to spans, flat |
| `m1_raster3d` | 6,977 | geometry + list walk + sort + fill + band buffer |
| N64 RDP | 8,347 | triangles, trilinear, combiner, coverage AA |

**The renderer budget is the 6,977 shape, not the 2,113 one**, because the four
lower rows are exactly what remains to be built, and `m1_raster3d` excludes
`m1_tgp` just as our 35,147 already includes `m2_copro`. Against build 18's
6,763 spare ALM that is short, not comfortable -- and ours is textured and
Z-buffered where Model 1's is flat.

*The fork that decides it, and it is study-level because it moves the ~25,000
ALM number.* `geo_code_upload`/`geo_code_jump` mean a game **can** upload its own
geometry microcode. If `daytona93` only ever runs the stock pipeline, the four
transform loops hardwire cheaply; if it uploads, the geometrizer must be a real
microcode engine and the cost roughly doubles. Answerable from MAME with a tap
on `geo_code_upload` over attract mode, and it should be answered before any of
the renderer is designed.

*Two memory findings that bear on the band buffer.* Sound-board work RAM is
524,288 bits of M10K and Model 1's band buffer needs ~522,240 -- moving sound to
SDRAM very nearly pays for it exactly. And a third read port on tile RAM made
Quartus build a second complete copy of the array, 128 of 312 M10K, for a debug
probe. A debug read port on a memory is never free; observe the write bus.

**R125 - THE COPROCESSOR'S HALT WAS AN UNACKNOWLEDGED READ OF IO 0x2e, AND THE
TELEMETRY THAT NAMED IT HAD BEEN DRIVEN AND UNREAD ALL ALONG.**

`m2_tgp.sv`'s io_ack mux read

    : sel_datb ? io_wr

`sel_datb` is `io_mid && (io_addr[4:0] == 5'h0e)` -- address 0x2e -- and the
selector exists only to catch the WRITE that sets `dat_base`. Nobody wrote the
read half, so a read of 0x2e acknowledged **never**, and the TGP held
mid-instruction forever.

Measured on the board, build 22:

    io_addr = 002e   io_rd = 1   io_ack = 0   unimpl = 0
    pc = 0x0481      retires = 21,325 (frozen)   fifo_hold = 0x0A34462B

*How it was cornered, because the route matters more than the answer.* Four
readings in sequence, each killing a hypothesis:

  1. `hscr` = 0 over 52 samples -> the coprocessor is not delivering.
  2. `out_popped` == `out_pushed` == 143, and the i960's IP moving across six
     addresses -> **NOT a FIFO deadlock.** The outbound queue was EMPTY, not
     full. This killed the theory this project had held for two days, and the
     8 -> 128 deepening that was built to fix it bought 22 more results and
     changed nothing structural.
  3. `retires` and `pc` byte-identical across two builds whose outbound FIFO
     differed **16x** -> one instruction failing deterministically, not a race.
  4. `dbg_op` = 1c1dc638, `top[31:26]` = 0x07 = `is_ldmov` -> an IMPLEMENTED
     opcode, so not `unimplemented`. A load that never gets its data.

*The reference has no special case at 0x2e at all.* `copro_tgp_io_map` maps the
math units at 0x20-0x2b and puts everything else in a banked view whose handler
ALWAYS answers:

    adr = (m_copro_tgp_bank_reg & 0xff0000) | offset;
    if (adr & 0x800000) return m_copro_data->as_u32(adr);
    if (adr & 0x400000) return m_bufferram[adr & 0x7fff];
    return 0;                                    // it cannot stall

So the fix is `sel_datb ? (io_rd || io_wr)`, and zero is the correct value for a
clear bank. **Verified on hardware:** `retires` climbs continuously and the PC
passes 0x0481, where it had been frozen across every previous build.

*The instrumentation lesson, and it cost a build.* `dbg_out_pushed`,
`dbg_out_data`, `dbg_in_dropped`, `dbg_out_dropped`, `dbg_op` and every
`dbg_io_*` existed in `m2_copro`/`m2_tgp` and were **tied off in `Model2.sv`**.
A debug output that is driven and unread is not instrumentation. Grep for a
count of TWO -- one declaration, one instantiation -- to find the rest.

*And one counter was unreachable by construction.* `dbg_out_dropped` sits behind
`else if (tgp_out_push && ...)`, but `m2_tgp` gates `fifo_out_push` on
`!fifo_out_full`, so a blocked push is never counted. The board read
`out_drop = 00` throughout the freeze and that number meant nothing. Quartus
later proved it independently: `u_fout|dropped[0..31] ; Stuck at GND`.

**R126 - THE MICROCODE UPLOAD IS BYTE-PERFECT, AND THE BENCH THAT SAID
OTHERWISE HAD BEEN WRONG SINCE R110 WAS RETRACTED.**

`tb_m2_boot.cpp` carried a hardcoded table of MAME's TGP program and printed
"*** the uploaded PROGRAM is wrong, not the decode ***" on every run. Re-dumped
from MAME with the correct address unit -- AS_PROGRAM is (32,16,-2), so
`read_u32(word)` and never `read_u32(word*4)` -- every entry in that table was
wrong and **this core was right at all ten addresses**:

    addr   MAME (truth)   old "want"     ours
    0044   1c1f2621       000f4610       1c1f2621
    0047   1c3da00b       1d3c4216       1c3da00b
    004b   bf600055       012f4611       bf600055
    0057   bf624019       bf60004c       bf624019

MAME holds **2,024 nonzero words** and this core uploads **2,024**. The table has
been replaced with ground truth and all fetched addresses now read `ok`.

*The general form, and it is the expensive part.* R110 was retracted by R116,
but the retraction chased the CONCLUSION and left the CONSTANTS. A hardcoded
expected-value table outlived the measurement that produced it and spent every
run since accusing a correct core. **A retraction has to chase its constants,
not just its prose.**

**R127 - PARTLY WRONG, AND CORRECTED BY R129. The measurements below stand;
the CONCLUSION -- that initialisation was the missing piece -- does not.
Initialising the RAM to 0x07800f0f changed nothing at all, byte-identical
telemetry, and R129 has the actual cause. Kept rather than deleted because
the numbers are the evidence R129 rests on, and because R126 is about
exactly this: a retraction must chase its constants, not just its prose.**

**R127 (as written) - IMPLEMENTING A MEMORY WITHOUT INITIALISING IT WAS
MEASURABLY WORSE THAN NOT IMPLEMENTING IT.**

`map(0x00900000, 0x0091ffff).mirror(0x60000).ram().share("bufferram")` is 128 KB
of plain RAM and this core routed it to `T_IO`, whose read mux ends in `32'd0`.
Measured in MAME over 900 attract frames: **33,554 writes and 12,269 reads**, all
going nowhere. It is not only the i960's -- the coprocessor reads the same array
through its bank at 0x400000 -- so it is **how the two share data**, and neither
end could see it.

Mapped to SDRAM at `GAME_BUFFER = 0x16f0000` (the gap between `GAME_CHAR` and
`ST_BASE`; 128 KB will not fit in M10K, ~103 blocks against 40 free after the
band buffers). And the machine got WORSE:

    unmapped, reads return 0      TGP retires 21,325, attract cycling
    mapped, SDRAM uninitialised   TGP retires  1,367, "insert coin" stopped

Because `model2.cpp` says so, in a comment that is load-bearing rather than
decorative:

    // initialize bufferram to a sane default
    m_bufferram[i] = 0x07800f0f;

**The game reads that memory before it writes it.** A deterministic 0 was
survivable; whatever SDRAM powered up holding was not.

*The ordering the code dictated.* The initialiser runs AFTER `cal_done` -- the
self-test is the SDRAM read-latency calibration and its own comment says
"RUNS FIRST, AND EVERYTHING THAT READS SDRAM WAITS FOR IT" -- and `cpu_rst_n`
now also waits on `bi_done`. 65,536 word writes, once, a few milliseconds.
Word order: the bridge selects the dword half with `r_addr[1]` while
`sd_word = base + r_addr[16:1]`, so an EVEN word index is the LOW half --
0x0f0f on even, 0x0780 on odd.

*The rule this generalises.* This project already knows that unwritten memory
must not read as zero. R127 is the other half: **when the reference initialises
a memory, that value is part of the hardware and must be reproduced.** A region
mapped over uninitialised storage is not "closer to correct" than an unmapped
one -- it can be strictly further away, and it will look like an unrelated
regression.

**R128 - PARTLY WRONG, CORRECTED BY R130. The access COUNTS below are right
and they matter. The inference drawn from them -- that 721,831 writes to
0x804000 mean the game uploads geometry microcode continuously, so the
geometrizer must be a microcoded processor -- is WRONG. Most of those writes
are DISPLAY-LIST DATA, and the reference discards the microcode entirely.
See R130.**

**R128 (as written) - THE GEOMETRIZER IS READ BACK, SO IT CANNOT BE DEFERRED
INDEFINITELY.**

Measured in MAME with taps on the i960's program space over 900 attract frames:

    READ   0x800000    2,263      geo_r
    READ   0x900000   12,269      bufferram
    WRITE  0x900000   33,554
    WRITE  0x800000   65,767      geo_w
    WRITE  0x804000  721,831      geometry microcode, ~800 words per frame

`geo_r` itself is small -- 0x2008 returns `m_geo_write_start_address`, 0x3008
returns `m_geo_read_start_address`, everything else returns 0 -- so the readable
state is two pointers the i960 set itself. But the 721,831 writes to 0x804000
settle the question R124 left open: **`daytona93` uploads geometry microcode
continuously**, so the geometrizer is a real microcoded engine here and not a
pipeline that can be hardwired. That is the design-study answer to the fork, and
it is measured rather than assumed.

*Corollary for the port.* `m1_geometry` and its nine `m1_geo_*` submodules
therefore do NOT transfer, and neither do `m1_listwalk` (Model 1's display-list
grammar) -- but `m1_quad_store` DOES: its two `m1_geometry` mentions are
comments and it instantiates nothing. The seam is a projected screen-space quad
with a colour and a z, which is exactly what a geometrizer emits.


**R129 - THE BUFFER RAM CANNOT LAND WITHOUT THE GEOMETRIZER. It is not a memory
the game merely stores things in; it is the geometrizer's WORKSPACE.**

R127 mapped 0x00900000 to SDRAM and the machine got worse, and R127 blamed the
uninitialised contents. It was wrong. Initialising all 65,536 words to the
reference's own 0x07800f0f produced **byte-identical telemetry** -- the same
retire count, the same PC, the same stuck flags, to the digit:

    build 27  mapped, SDRAM uninitialised        C 006D003E 055704C9
    build 29  mapped, initialised to 0x07800f0f  C 006D003E 055704C9

Identical output from different memory contents rules the contents out entirely.
What changed between working and broken is not what the reads RETURN, it is that
**the writes now LAND.**

*What the i960 actually does, measured with its own IP on the wire (build 30):*

    IP           0x0E00 / 0x0E08 / 0x0E10     a three-instruction loop
    last addr    0163FB80, 0163FB82, 0163FB8C  walking
                 0704, 0708, 070C
    528 unique samples -- it is LIVELOCKED, not stalled on a bus cycle

0x0163FBxx is unmapped: `model2.cpp` has nothing at 0x016xxxxx and this core's
bridge has no branch for it, so it falls to T_NONE. **The game is following a
pointer it wrote into the buffer and read back.**

*The mechanism.* Unmapped, writes to 0x900000 vanished and reads returned a
constant 0, so the game's own structure came back as zeros and it took a safe
path -- 21,325 TGP retires with attract mode cycling. Mapped, the structure
survives, the game follows it, and the path it leads to needs the geometrizer
this core does not have. It ends up dereferencing into nothing and spins.

*The general form, and it is the useful part.* **A memory that another engine
owns is not an independently landable increment.** Making it work in isolation
moves the machine from "wrong but safe" to "correct and then off a cliff",
because the software stops taking the degenerate path that the missing hardware
was accidentally forcing. The mapping is therefore correct, verified live -- the
boot profile shifts measurably with it on, 0x00001000 34.9% -> 29.8% and
0x00228000 19.4% -> 24.5% -- and it is DISABLED behind `BUFFERRAM` in
`m2_cpu_bridge` until the geometrizer lands in the same change.

*What survives from R127 regardless.* The initialiser itself is right and is
kept: `model2.cpp` initialises that array to 0x07800f0f because the game reads
before it writes, and when the reference initialises a memory that value is part
of the hardware. It costs 161 ALM and runs after `cal_done`, because the
self-test is the SDRAM read-latency calibration and everything touching SDRAM
waits for it.

*And a process note that cost real time.* A build that reads as broken must be
ROLLED BACK before anything else -- build 29 was left on the board while its
telemetry was analysed, and the first sign of that was the user reporting a dead
machine rather than the log saying so.


**R130 - THE GEOMETRIZER IS A DISPLAY-LIST INTERPRETER, NOT A PROCESSOR, AND THE
MICROCODE UPLOAD IS DISCARDED BY THE REFERENCE.**

R124 asked whether `geo_code_upload` meant the geometrizer had to be a real
microcode engine, and R128 answered "yes" from the write count. Both were wrong,
and the answer is four lines of `model2.cpp`:

    void model2_state::geo_prg_w(u32 data) {
        if (m_geoctl & 0x80000000) { m_geocnt++; }   // upload: COUNTS, DISCARDS
        else                       { push_geo_data(data); }
    }

**The upload is counted and thrown away.** MAME implements no geometrizer
microcode at all; `geo_process_command` hardcodes the standard pipeline. So the
721,831 writes to 0x804000 are overwhelmingly `push_geo_data` -- the game
streaming its DISPLAY LIST into buffer RAM through an auto-incrementing pointer,
not instructions.

*The machine, in full:*

    0x00800000-0x00800fff   function writes -> push_geo_data
    0x00801008 (w)          geo_write_start_address
    0x00803008 (w)          geo_read_start_address
    0x00802008 (r)          returns geo_write_start_address
    0x00803008 (r)          returns geo_read_start_address
    0x00804000-0x00807fff   geoctl[31] ? count+discard : push_geo_data
    0x00980008              geo_ctl1, bit 31 = upload mode
    0x00900000-0x0091ffff   bufferram: the display list itself

    push_geo_data(d) { m_bufferram[m_geo_write_start_address/4] = d;
                       m_geo_write_start_address += 4; }

and once per frame, at vblank, gated on `(videocontrol & 1) == 0 || !(frame & 1)`:

    geo_parse():  input = &bufferram[geo_read_start_address/4]
                  opcode = *input++
                  if (opcode & 0x80000000) -> jump to (opcode & 0x1ffff)/4
                  else input = geo_process_command(opcode, input, &end)
                  bounded by 0x8000 opcodes and the end of bufferram

That is `m1_listwalk`'s shape -- a bounded walk over a command list with a jump
opcode -- and NOT a processor. The renderer budget from R124 stands, but the
front end is far cheaper than "double the cost" and needs no program memory,
no instruction decode and no sequencer beyond a walk.

*And it probably explains yesterday's livelock.* `geo_r` returns
`geo_write_start_address` at 0x2008 and `geo_read_start_address` at 0x3008. This
core returns **0** for both, because that region falls into the bridge's T_IO
default. The game sets a pointer, reads it back as zero, and derives an address
from it -- which is exactly the shape of the failure R129 recorded: the i960
livelocked walking an unmapped 0x0163FBxx once buffer RAM writes started
landing. Two pointer registers are cheap and are the first thing to build.

*The lesson, and it is the same one twice in two days.* R128 inferred a design
from an ACCESS COUNT without reading the handler the accesses reach. A large
write count to a port named "program" is not evidence of a program: here it was
one branch of an if, and the other branch is the whole traffic. **Read the
handler, not the histogram.**

**R131 - THE TIMING COIN FLIP WAS `FITTER_AGGRESSIVE_ROUTABILITY_OPTIMIZATION
ALWAYS`, AND THE FAILING PATH NAMED IT.**

Builds had been missing timing about half the time, on a different clock each
seed -- `pll_hdmi` at -0.124, the SDRAM domain at -0.059 -- always by a hair,
always a single path. Two things cracked it, and neither was a synthesis option.

*First, the path was read instead of guessed.*

    quartus_sta:  SLACK -0.124   FROM vs   TO hdmi_out_vs

and in `sys/sys_top.v` those are two registers in the SAME always block on the
SAME clock:

    hdmi_out_vs <= vs;

**A bare flop-to-flop path with no logic between it can only fail on physical
distance.** That immediately explains why turning
`PHYSICAL_SYNTHESIS_COMBO_LOGIC_FOR_AREA` off produced a BYTE-IDENTICAL result
-- same slack, same TNS, same ALM count -- there is nothing there to restructure.
A null result worth having: it is not a hidden drag on this design.

*Second, occupancy was ruled out from outside.* Model 1 closes at 91% ALM on the
same part; we were failing at 78%. So the problem was not how full the chip is,
which is what sent the search to placement SETTINGS.

`FITTER_AGGRESSIVE_ROUTABILITY_OPTIMIZATION` deliberately SPREADS LOGIC to
relieve congestion, and spreading is exactly what pulls two adjacent flops apart.
The A/B, same seed, one option changed:

    seed 19, ALWAYS          -0.124  FAIL   32,970 ALM
    seed 19, AUTOMATICALLY   +0.428  PASS   33,323 ALM

**A 0.552 ns swing for 353 ALM**, and the worst path moved off HDMI entirely.

*It was added for a real failure and the reason still stands.* At 79% the fitter
could not route at all -- one contended resource at a time, a different one per
seed. `AUTOMATICALLY` lets it apply the same optimisation where it is needed
rather than everywhere. If routing ever fails again, `ALWAYS` is the line to put
back, and this entry is why it was changed.

*The rule.* When a path fails, READ IT before changing a setting. A failing path
with no combinational logic is a placement problem and no amount of synthesis
effort will touch it; a failing path inside the framework is not ours to fix at
all. Both were true here, and both were invisible from the slack number alone.

**R132 - THE BUFFER RAM MAPPING IS PROVEN CORRECT, AND ENABLING IT STILL BREAKS
THE MACHINE. R129's EXPLANATION IS WRONG.**

R129 said the game "writes a structure, reads it back and follows it", and that
the livelock was the game proceeding down a path needing the geometrizer. Two
measurements since say otherwise.

*The mapping is not at fault.* `tb_m2_cpu_bridge` now covers the region directly
-- 106 checks, 0 mismatches: a dword lands in two SDRAM words at
`base + (offset >> 1)`, reads back whole, the `.mirror(0x60000)` aliases rather
than addressing new storage, and the last dword of the 128 KB does not run past
the region. The decode, the halves and the mirror are all correct.

*The reference never goes where we go, AND THAT IS NOT THE FAULT.* Tapping the
i960's whole program space in MAME over 900 attract frames:

    REFERENCE NEVER TOUCHES 0x01600000-0x0170ffff

while our i960 walks 0x0163FB80, 84, 8E, 90 there. That is a real divergence and
it still wants explaining -- but it is NOT what breaks the machine. Build 36,
with BUFFERRAM off, shows the identical walk (0163FAFC, FB2A, FB46, FB66) while
attract mode runs and "insert coin" flashes. The walk is ordinary traffic that
sampling catches because a store queue to SDRAM is slow.

**Recorded because it nearly became the answer.** An address that looks wrong,
in a loop that looks stuck, on a build that IS broken, is not evidence until the
same reading is taken on a build that WORKS. The control was one flash away and
was not run first.

*And the loop is a memory clear.* The code at the livelock, read out of the ROM
through MAME:

    0e00  b2805000   stq    (0xb2 = store quad, 16 bytes)
    0e04  59084810   addo
    0e08  b2a05000   stq         four stq/addo pairs, 64 bytes an iteration
    0e0c  59084810   addo
    0e10  b2c05000   stq
    ...
    0e30  00500000   <- work RAM base, as data

which is why the profiler only ever catches 0x0E00/0x0E08/0x0E10: the stores are
where the time goes. The clear is running away.

*What is excluded, each checked rather than assumed:* the mapping (above), the
contents (initialising to the reference's own 0x07800f0f gave byte-identical
telemetry, R127/R129), the burst flag (0x0090_0000-0x0098_0000 was already in
`i960_memmap`'s table), cache aliasing (the tag is the full upper address), a
region collision (`cc_addr` is exactly 18 bits and the ROM image ends near word
0x15F8000), and the geometrizer's pointer registers (build 35 added them and
livelocked identically).

*And simulation does not reproduce it.* With `BUFFERRAM` on, the boot bench's CPU
profile SHIFTS -- 0x00001000 34.9% -> 29.8%, 0x00228000 19.4% -> 24.5%, so the
region is genuinely live -- but it never visits 0x0163Fxxx and never livelocks.
The fault is hardware-only, which is the least convenient shape it could take.

`BUFFERRAM` is therefore still off, and it is off with a proven-correct mapping
behind it rather than a suspect one. The next move is instrumentation, not
theory: the i960's IP RING rather than a sampled IP, which shows the loop body
and what it reads immediately before the address goes wrong.

**R133 - THE COPROCESSOR'S BANKED MEMORY WINDOW IS AN INVENTED SCHEME. The bank
register exists in the register file, is written by the microcode, and is read
by NOTHING.**

The TGP executes the reference's program from the reference's addresses (R120,
R126) and its opcodes are fuzzed against a transcription of MAME. None of that
touches the MEMORY MAP, and the memory map is wrong in four separate ways.

*The reference.* `copro_tgp_io_map` puts the math units at 0x20-0x2b and
everything else behind a VIEW whose handlers are:

    copro_tgp_memory_r(offset):
        adr = (m_copro_tgp_bank_reg & 0xff0000) | offset;
        if (adr & 0x800000) return m_copro_data->as_u32(adr & mask);  // data ROM
        if (adr & 0x400000) return m_bufferram[adr & 0x7fff];         // BUFFER RAM
        return 0;

    copro_tgp_memory_w(offset, data):
        adr = (m_copro_tgp_bank_reg & 0xff0000) | offset;
        if (adr & 0x400000) COMBINE_DATA(&m_bufferram[adr & 0x7fff]); // and WRITES it

    copro_tgp_bank_w(data):                     // this is AS_RF register 3
        m_copro_tgp_bank_reg = data;
        if (data & 0xc00000) bank.select(0);    // the view is ENABLED by the bank
        else                 bank.disable();    // otherwise it is not there at all

*What this core does instead:*

| | reference | this core |
|---|---|---|
| base of the window | `bank_reg`, written via **rf 3** | `dat_base`, written by **io 0x2e** |
| what selects the target | effective addr bit 23 / bit 22 | **offset bit 15** (`sel_datw`) |
| a write to io 0x2e | data into **bufferram** | sets a base register |
| is the view enabled? | only when bank & 0xc00000 | **always** |
| copro writes to bufferram | yes | **not implemented** |

`mb86233_regs.sv` line 239 stores rf 3 like any other register -- `if (wr_rf)
rf[wr_addr[3:0]] <= wr_data` -- and nothing ever reads `rf[3]`. So the register
the reference uses to form EVERY banked address is captured and discarded.

*It is not a corner case.* Tapping the copro's io space in MAME over 600 attract
frames: **257,550 reads of the math units and 7,537 through the banked window.**
The window is used about twelve times a frame.

*Why nothing caught it.* Both instruments this project trusts are blind to it.
The lockstep fuzz compares opcode SEMANTICS against a transcription; the i960
differential compares PROGRAM COUNTERS. A processor can execute the right
instructions in the right order out of the right program and still read the
wrong memory -- and it will not diverge in either instrument, it will only
produce wrong VALUES. Which is exactly the standing symptom: `dbg_out_data` =
0x42976767, a plausible float, and layer 2's `hscr` -- copro-derived, R106 --
stuck at zero.

*The order this wants fixing in.* rf 3 first, since everything else derives from
it: store it, use bits 23:16 as the window base, and gate the view on
`bank & 0xc00000`. Then route `adr & 0x800000` to the copro data ROM (the
existing `dat_req` path, whose address becomes `(bank & 0xff0000) | offset`
rather than `{dat_base[18:15], io_addr[14:0]}`), and `adr & 0x400000` to buffer
RAM in both directions. The copro writing bufferram is a new path this core has
never had, and it is how the coprocessor and the i960 share results.

*And it reframes R129/R132.* Buffer RAM has three consumers and this core serves
one. Enabling it for the i960 alone was never going to be sufficient, and may
never have been safe: the reference has the COPROCESSOR writing that memory too.

**R134 - R133 CONFIRMED ON HARDWARE. The bank register is live, it points at
buffer RAM, and the machine still does not boot with the region enabled.**

R133 was read out of `model2.cpp`. This is the board agreeing with it.

*The bank is written, and it selects the memory we never implemented.* With
`rf[3]` brought out to the UART:

    bank[23:16] = 0x40

0x40 in bits 23:16 is **bit 22 of the effective address** -- `adr & 0x400000` --
which is exactly the case `copro_tgp_memory_r` routes to `m_bufferram`. So the
microcode does write AS_RF 3, it points the window at BUFFER RAM, and every
banked access this core ever made went somewhere invented. The register was
being stored and discarded (R133); it was never idle.

*Three bugs of mine were found and fixed on the way, each named by the UART:*

  1. **A write to the ROM half hung the coprocessor.** `io_addr=7ffc, io_wr=1,
     io_ack=0`. The ack mux read `sel_rom ? dat_ack` for both directions, so a
     write issued no request and then waited for its acknowledgement. The
     reference drops ROM-bank writes silently -- `copro_tgp_memory_w` stores
     only when `adr & 0x400000`.

  2. **Making port 9 read-write cost the 96 MHz domain.** Four seeds at -0.253,
     -0.314, -0.381, worsening, with the worst paths INSIDE the controller:
     `xfer_addr[19] -> cmd[0]` and `be_r[1] -> cmd[0]`. Port 9 had been read-only
     since it was built; `p_we`/`p_din`/`p_be` widen the logic feeding `cmd`.
     Buffer-RAM writes now leave on the SHARED WRITE PORT instead -- the one the
     loader, the self-test and m2_geo take turns on -- which is idle during
     gameplay and outside the arbiter. Timing returned to +0.151 with the worst
     path back on pll_hdmi. Measured need: **250 window writes per 600 frames
     against 7,537 reads**, so the write is real but rare and the port suits it.

  3. **The write request must DROP between the two halves.** A dword is two
     16-bit transfers and the port acknowledges a request once; a level that
     never falls is one request, not two. Held high, it hung at
     `io_addr=7ffc, io_wr=1, io_ack=0` again. `bi_`, the buffer initialiser,
     already had the right shape -- assert, wait, drop, re-assert -- and this
     now matches it.

*The result of fixing all three.* The TGP's io flags went from `7FFC0008` --
stuck on a write -- to `00000000`, no access pending. **The coprocessor no
longer hangs.** And the machine still does not reach attract mode with
`BUFFERRAM` enabled.

*So the standing position, stated plainly.* The copro now reads and writes the
reference's memory map, which is a correctness fix that stands on its own and is
confirmed live. It is NOT sufficient to make buffer RAM safe to enable. Six
explanations for that livelock have now been proposed and killed by measurement
(R127, R129, R132, and three tonight); what is established is only this:

  * the mapping is correct -- 106 checks including the mirror and the region top
  * the i960 is byte-perfect against MAME for **521,752 instructions** with the
    real I/O board in the loop, and for 803,355 in the ROM harness
  * writes landing are harmless; READS are what break it (builds 39 vs 40)
  * cache retention is not the cause (build 43, fill suppression)
  * simulation does not reproduce it at 30 M instructions

The next instrument, and it is the one thing not yet tried: the i960's IP RING
rather than a sampled IP, which shows the loop body and its branch. It killed
two builds with `Internal Error: TDB, tdb_node.cpp:2080` when wired to the
streamer, and that attribution is itself uncertain -- the same crash recurred
with the ring disconnected. It wants a different route to the wire.

**R135 - THE COPROCESSOR PIPELINE IS ALIVE END TO END, AND THE DISPLAY LIST'S
WALKING RULE IS ESTABLISHED.**

*The coprocessor works.* With R133's memory map and BUFFERRAM enabled, measured
on the board over one 20-second capture:

    in_pushed   7292 -> 7368     the i960 is feeding it
    out_pushed  2149 -> 2173     the TGP is producing results
    out_popped  2036 -> 2057     the i960 is reading them back

All three climbing together. Two days earlier `out_pushed` was frozen at 121 and
nothing came back. Commands in, results out, results consumed.

*And the machine boots.* It renders the tilemap -- sky, grass, CREDIT 0/3, both
logos -- plays sound, and stops on the first attract frame. `hscr` is still zero,
which is now explained rather than mysterious: the game never reaches the code
that computes it, because it is waiting for geometry.

**BUFFERRAM IS NOT BROKEN. It never was after R133.** R129's original reading --
"the game proceeds down a path that needs the geometrizer" -- was right, and was
retracted here on bad grounds: MAME never touching 0x0163Fxxx is a separate and
benign fact, and it was allowed to discredit a correct conclusion. Six
explanations were chased afterwards. R127, R129, R132 are superseded by this.

*The method failure worth recording.* Every "livelock" call from build 27 onward
was made from telemetry alone. **Nobody asked what was on the screen.** The
machine was booting and rendering; one question would have established that on
day one, and it outranks any amount of counter-reading when a display and a
person are both present.

*The walking rule, which is what the interpreter gets written from.* geo_parse
reads dwords from bufferram at geo_read_start_address, and per opcode
`(op >> 23) & 0x1f`:

| op | handler | words consumed |
|---|---|---|
| 00 | nop | 0 |
| 01, 11 | object_data | 4 -- tpa, tha, oba, obc |
| 03, 13 | window_data | 6 |
| 04 | texture_data | 2 + count, count is the SECOND word |
| 05, 15 | polygon_data | 2 + count, count is the SECOND word |
| 07, 17 | mode | 1 |
| 08, 18 | zsort_mode | 1 |
| 09, 19 | focal_distance | 2 |
| 0a, 1a | light_source | 3 |
| 0b, 1b | matrix_write | 12 -- a 3x4 matrix |
| 0c, 1c | translate_write | 3 |
| 0f, 1f | end | 0, and ends the walk |
| 10 | dummy | 1 |
| 16 | lod | 1 |
| 1e | code_jump | 1 |
| 02, 12 | direct_data | 17 inline -- NOT yet confirmed |
| 06 | texture_parameters | count-driven -- NOT yet confirmed |
| 0d | data_mem_push | count-driven -- NOT yet confirmed |
| 0e | test | loops of 0x32/0xb/0xc -- NOT yet confirmed |
| 14 | log_data | count-driven -- NOT yet confirmed |
| 1d | code_upload | count-driven -- NOT yet confirmed |

**The count is read FROM THE STREAM, not from the opcode.** That was the open
question and it makes the walker far simpler: no opcode field decoding, just a
length word where the table says so.

A jump is the top bit: `if (opcode & 0x80000000) input = &bufferram[(opcode &
0x1ffff)/4]`, and the walk is bounded at 0x8000 opcodes and the end of bufferram.
Verified against the real list dumped from MAME: index 9 is matrix_write and
indices 10-21 are twelve IEEE floats, exactly as the table predicts.

*What the walker still needs that does not exist.* A READ path from bufferram.
`m2_geo` only writes it today. All ten SDRAM ports are in use, so this wants an
eleventh -- and `m2_sdram`'s `blen()` must list it explicitly, because the
default is 1 and R108 records that mixed burst lengths corrupt the controller.

---

**R136 - FOUR SIMULATION TARGETS HAD NOT REBUILT SINCE 26 AUGUST. `make` EXPANDS
A PREREQUISITE LIST WHEN IT READS THE RULE, AND THE LISTS WERE DEFINED 450 LINES
BELOW THE RULES THAT NAMED THEM.**

`SDR_RTL`, `RLD_RTL` and `VID_RTL` were defined near line 845 of the `Makefile`.
The rules naming them as prerequisites are at lines 393, 406, 416 and 469. GNU
make expands the prerequisite list at the moment it *reads* a rule, so all four
expanded to the empty string and the targets had no RTL dependency at all:

    $ make -q obj_m2_sdram/Vm2_sdram_harness    # with RTL 15 hours newer
    UP TO DATE

So `test_m2_sdram`, `test_m2_sdram128`, `test_m2_romload` and
`test_m2_video_timing` ran a **stale binary** and printed `PASS` whenever the
change under test was confined to RTL -- which is the normal case. A C++
testbench edit rebuilt them; an RTL edit did not.

*How it surfaced, and why nothing else would have caught it.* A state machine
was added to `m2_sdram` and the test returned **411373 cycles / 32782
transactions both before and after -- identical to the cycle.** A real FSM
change cannot leave a saturated arbiter's schedule bit-identical. The suspicion
came from the result being *too clean*, not from any failure.

*Corrected.* The three lists are hoisted above their first use, with a comment
saying why. A two-pass scan of the `Makefile` for prerequisites referencing a
variable defined later reports nothing further.

*What this costs retroactively.* Any conclusion drawn from those four targets
about RTL changed since 26 August is unproven, not wrong -- it was never run.
This is the second time this project has been misled by an instrument rather
than by the device: R129's `DCACHE_EN=0` passed both simulations and hung the
hardware. **The standing rule "fuzz and simulate before every build" silently
assumed the simulation was of the current source.** Where a result matters, the
build stamp of the binary that produced it is part of the result.

---

**R137 - THE SDRAM ROW COMPARATOR WAS ON THE COMMAND PATH, AND IT WAS THE
CRITICAL PATH OF THE WHOLE DESIGN. GETTING IT OFF COSTS 2.7% OF THROUGHPUT.**

`S_DISPATCH` exists, and its comment says it "keeps the port mux and the row
comparator out of the command-output timing cone." It got the port mux out. The
row comparator stayed in: `row_hit` was computed from the registered
`xfer_addr` and acted on in the same cycle, so the cone ran

    xfer_addr[25:24] -> tbank -> four 4:1 muxes (bank_open, bank_row,
    ras_cnt, rd_bank_cnt) -> 13-bit row compare -> if/else nest -> cmd

Post-fit, every failing path in the design was an instance of exactly this:

    xfer_addr[25]_OTERM1467  -> cmd[0]   -0.117
    xfer_addr[16]_...        -> cmd[0]   -0.097
    xfer_addr[15]_...        -> cmd[0]   -0.057

`[25:24]` are the bank bits and `[16:15]` are row bits into the comparator.

*The fix.* `S_DISPATCH` now writes **no `cmd` whatsoever**. A row hit and a
bank-closed miss both settle only `state`, which is a register boundary; only a
*conflict* miss -- bank open on the wrong row, the one case that must issue
PRECHARGE -- advances to a new `S_MISS`, which issues it from a registered
`dsp_bank`. The row comparator no longer reaches the command pins by any route.

*Measured, `tb_m2_sdram`, transactions per cycle:*

    0.079689   before
    0.077029   deferring every miss        -3.34%
    0.077531   deferring conflicts only    -2.66%

*The half-point that was not there.* Splitting the bank-closed leg back out was
expected to recover most of the loss and recovered about a fifth of it. With ten
ports over four banks, **most misses are conflict misses**, so the leg that pays
is the common one. The refinement is kept because it is free, but the honest
price of this fix is ~2.7% of SDRAM throughput, and it should be quoted that way
rather than as "noise" -- which is what it was called before it was measured.

*Standing note for the arbiter.* R108 and the port-count work already establish
this datapath as the binding timing constraint, and every added port widens it.
`cmd` is the endpoint that matters; anything combinational from `xfer_addr` to
it will be the critical path again.

---

**R138 - THE WALK STOPPED AT FRAME 141 ON OPCODE 0x0e, `test`. IT IS THE
SELF TEST, IT WRITES NOTHING, AND THE WALK OWES IT ONLY ITS LENGTH.**

Read off the board over UART, unchanged across 45 seconds:

    H 00050000 008D000E
      ops  objs  frames unknown

`dbg_walk_unknown` is **the opcode, not a count** -- `m2_geo.sv` assigns
`{3'd0, w_op}`. So: 141 walks completed, then a walk that retired 5 opcodes hit
**0x0e** and halted, and stayed halted. R130's note that the walk "halts on
test by design rather than desynchronising" did exactly what it said.

*What `geo_test` is.* From `model2_v.cpp`: a 1,2,4,8... ramp checked through the
FIFO, then a list of polygon-ROM blocks checksummed. **It returns no value,
writes no register and touches no geometrizer state.** A failure only
`logerror`s in MAME and lights an LED on the real board. So the walk's entire
obligation is to consume the right number of words:

    32 words    FIFO ramp
     + 1 word   block count
     + 3*blocks address, count, checksum

*Why it needed its own state.* The count sits at operand offset **32**, behind
the ramp. Every other count-driven command carries its count at offset 0 or 1,
which is what the `preop`/`mult` table expresses; `test` is the one length that
table cannot describe. `W_TFIFO` steps the ramp, then falls into the existing
`W_CNT` with a multiplier of 3.

*Verified.* `tb_m2_geo` walks a list carrying `test` with **0, 1 and 40 blocks**
and retires exactly the expected opcode total, `unknown` clear. The opcode total
is the sharp check, not a bonus one: a wrong skip length desynchronises the
remainder of the list, which is how the off-by-one in R130 read as 1093 opcodes
against an expected 101.

*The second fact in that telemetry, and it is the more important one.*
`dbg_walk_objs` is **cumulative and reads 0**. Across 141 frames the walker has
never seen a single `object_data`. Those frames were trivial lists. **No
geometry has been walked yet at all** -- so nothing downstream of the walker,
the transform stage included, has been exercised by the hardware even once. The
walk reaching `test` is the first frame that carries real content.

*Still not covered:* 0x02/0x12 `direct_data`, whose length is set by a while
loop terminating on an operand's low bits. It has not appeared. The walk still
halts on it by design, and `dbg_walk_unknown` will name it if it does.

---

**R139 - R135 WAS WRONG. ENABLING BUFFERRAM WAS A REGRESSION, AND A WORKING
BUILD FROM NINETY MINUTES EARLIER WOULD HAVE SHOWN IT.**

R135 concluded "BUFFERRAM IS NOT BROKEN. It never was after R133", and explained
the stop at attract frame 1 as the game waiting for geometry. **Both halves of
that are wrong.** Established by flashing the backups in order:

    Model2.rbf.good     a734d0d5  08-31 12:56   attract cycles, INSERT COIN
                                                flashes, coins accepted,
                                                selection screens reached
    Model2.rbf.attract  3307dcc5  09-02 22:09   cycles attract
    (a9ace86            09-02 23:53   BUFFERRAM 1'b0 -> 1'b1)
    build 53 onward               09-03         stuck at attract frame 1

`a9ace86`'s only functional change is that one parameter. `118cb77` -- R133's
copro memory map, which made the coprocessor write buffer RAM for real --
predates the WORKING `.attract` build, so the copro's writes are not the cause.

*Measured, not remembered.* The i960's instruction pointer, sampled over UART:

                        distinct IPs   top IP's share
    good  a734d0d5           823        367 / 12,935
    broken 4cdd444a          174     10,642 / 16,972 at 0x1166C alone

63% of samples at one address, 76% at two. The broken build spins; the good one
executes broadly. The spin's last address is 0x016FFFF8 -- inside buffer RAM.

*The mechanism, and why it only bites with BUFFERRAM on.* Unwritten SDRAM reads
0xFFFFFFFF. Bit 31 set means JUMP, so the walker jumps, lands on another
0xFFFFFFFF, and jumps again -- re-entering `W_FETCH` without ever passing
through `W_SKIP`, which was the only place the `w_ops` bound was checked. The
walk never terminated and held `rd_req` asserted permanently against SDRAM
port 9.

With **BUFFERRAM off** the i960's writes never reach SDRAM, so buffer RAM stays
uniformly 0x07800f0f -- an `end` -- and every walk stops on its first word. With
it **on**, the game's real display lists arrive and the walk runs for real. The
parameter did not break the mapping; it delivered the input that exposed an
unbounded loop.

*Corrected in `m2_geo`:* the bound is now tested in `W_FETCH`, where the jump
re-enters, not only in `W_SKIP`. `tb_m2_geo` feeds a walk nothing but
0xFFFFFFFF and requires it to stop requesting; **that test was confirmed to FAIL
with the bound removed and pass with it in**, so it tests the fix rather than
agreeing with it.

*The method failure, and it is the same one R135 itself named.* R135 was written
from telemetry -- `in_pushed`/`out_pushed`/`out_popped` all climbing -- and
concluded the pipeline was healthy. Three counters going up says traffic exists,
not that the machine is further along than it was. **The previous build was
sitting on the board's SD card the whole time and was never flashed back for
comparison.** A regression is established by running the older build, not by
reasoning about the newer one. R135's own closing lesson was "nobody asked what
was on the screen"; this is that lesson again, one build later.

---

**R140 - "THE SCREEN IS THE ONLY OUTPUT CHANNEL" HAD A PREMISE, AND THE PREMISE
IS NOW FALSE. THE DEBUG INSTRUMENTS COST 626 ALM AND ARE NOW COMPILE-TIME.**

The standing rule in `docs/` reads:

> The screen is the only output channel. No serial, no printf, no debugger.
> Build the debug overlay early and render hex digits, not blocks.

It is why `m2_diag` exists, and building it early was right. But it rests on a
premise -- that nothing except the screen can reach a running board -- and that
premise no longer holds. **UART reaches `/dev/ttyS1` at 115200 over ssh with no
cable attached**, because `UART_TXD` has no pin assignment and is
`cyclonev_hps_interface_peripheral_uart`. R136, R138 and R139 were every one of
them established from that serial link, not from the overlay:

    R138   the walk halting on opcode 0x0e, read straight off the H line
    R139   823 distinct i960 IPs on the good build against 174 on the broken
           one, 63% of them at a single address -- the regression, measured

*What they cost, measured rather than estimated:*

    m2_diag:u_diag             443.5 ALM
    m2_dbg_stream:u_dbg_stream 182.9 ALM
                               ------
                               626.4 ALM   of 41,910 on the part

The first estimate offered for this was "~100-300, probably", made by reading
the entity table for the wrong module name and guessing at the rest. The real
number is roughly double the top of that guess. **The overlay was a separate
entity all along and could have been measured in one command.**

*Amended, not dropped.* Both instruments stay in the source and ON BY DEFAULT.
A `M2_NO_DEBUG` Verilog macro compiles both out for an area-constrained build:
`m2_diag` is a pass-through filter, so its absence is three wires, and
`UART_TXD` ties idle-high. Both configurations lint clean.

*Why it is amended this way and not by deleting them.* Debug is scaffolding and
a build that only plays the game should not carry it -- but the rule exists
because instruments get cut first and regretted later, and this session is the
argument for keeping them: the machine has been diagnosed three times today by
exactly these two modules. The switch makes the cost optional. It does not make
the instruments optional while the transform stage is unbuilt.

*Standing note.* The fit question is whether the i960 and the renderer land
under ~25,000 ALM together. 626 ALM is real against that number, and so is
`MISTER_DISABLE_YC` (enabled) and `MISTER_DISABLE_ALSA` (251.5 ALM, HPS-sourced
audio only -- `core_l`/`core_r`, the analog jack, HDMI and S/PDIF are all
outside its guard and unaffected).

---

**R141 - IT IS THE CPU'S *READS* OF BUFFER RAM, NOT THE MAPPING AND NOT ANYTHING
WRITING TO IT. `BUFFERRAM_WRONLY` RESTORES THE MACHINE AND WAKES THE WALKER.**

Four builds of single-variable bisection, each measured on the board by the
i960's instruction-pointer spread over UART:

    build                          distinct IPs   top IP's share
    .attract   BUFFERRAM off             823       367 / 12,935
    a9ace86+   BUFFERRAM on              174    10,642 / 16,972  (63% at 0x1166C)
    35d991a9   on, copro writes OFF      --     unchanged, still spinning
    2ae6f8fc   on, WRONLY (reads -> 0)  1,174     1,058 / 15,084  (7%)

`BUFFERRAM_WRONLY` maps buffer RAM and lets the i960's WRITES land, while its
READS return 0 exactly as the unmapped path did. **The spin at 0x1166C
disappears and the attract sequence runs -- flashing text confirmed on the
screen.** The CPU executes over a wider address range than the known-good build.

*What this eliminates, all of it measured rather than argued:*

    buffer RAM uninitialised   NO -- bi_* fills 0x07800f0f, cpu_rst_n waits on bi_done
    region overlap             NO -- GAME_CHAR ends exactly at GAME_BUFFER
    base_buffer disagreement   NO -- one constant, bridge, geo and copro alike
    write/read reordering      NO -- one port, four-phase handshake
    the walker hogging SDRAM   NO -- it bounds out; masks fixed regardless
    the COPROCESSOR's writes   NO -- disabled on hardware, still spun (35d991a9)
    geo front door addressing  by INSPECTION only -- (ptr & 0x1ffff) >> 1 is
                               right, but no build has taken these writes away

What remains is what the i960 gets back when it READS buffer RAM -- and the
GEO FRONT DOOR IS STILL A CANDIDATE FOR PUTTING IT THERE. `BUFFERRAM_WRONLY`
does not clear it: the front door writes through the shared SDRAM write port,
not through the bridge, so those writes still happen in 2ae6f8fc. They simply
became invisible, because the CPU can no longer read them back. The copro test
(35d991a9) disabled the COPROCESSOR's writes only and left the front door
running.

ANSWERED, 23493a75: BUFFERRAM fully on with the front door's writes disabled,
and the board still stuck at frame 1 with no flashing text. **So both writers
are now cleared by experiment, and NOTHING that writes buffer RAM is at fault.
The i960's READ path is.**

Five builds of elimination could not say WHAT it reads, only that reading is
what breaks it. The bridge has captured the answer all along -- `dbg_last_dout`,
the data returned by the last SDRAM read -- and Model2.sv wires it to
`cpu_dbg_ldout` but streams `cpu_dbg_laddr` instead. The address has been a
constant 0x016FFFF8 in every capture, so it carries no information the data
would not. Swapped.

*And the walker came alive.* `dbg_walk_frames` had been frozen at 139/141 in
every build today; it now climbs -- 0x53, 0x59, 0x69, 0x6F across one capture.
`ops` is 1 and `objs` still 0, which is consistent: each walk reads one word,
finds the 0x07800f0f `end` the initialiser wrote, and stops. The game has not
pushed real geometry this early in attract.

*Why this is not the fix.* Real hardware lets the i960 read buffer RAM back --
MAME maps it `.ram()` at 0x00900000 with no such asymmetry. WRONLY is a
diagnostic that names the half at fault, and it may serve as a working
configuration for the transform-stage work in the meantime, because the CPU's
writes still reach SDRAM and the walker reads SDRAM directly rather than through
the bridge. It must not be mistaken for correct.

*Method note.* Simulation could not answer this. The boot harness had never run
with BUFFERRAM on at all -- the bridge defaults it off and no harness overrode
it -- so every green run tested the working configuration. Made switchable, and
with buffer RAM initialised to match hardware, it still could not: the first
divergence between the two configurations lands at instruction 697,522 inside
the DPRAM poll at 0x228xxx that `tools/i960-diff.sh` already documents as
unmodellable. **Four hardware builds settled what the simulator was structurally
unable to reach.**

---

**R142 - THE GAME POLLS A MAILBOX AT 0x91FFF0 FOR ZERO, AND THE COPROCESSOR IS
SUPPOSED TO CLEAR IT. `.attract` WAS NOT WORKING -- IT WAS SKIPPING THE
HANDSHAKE.**

Disassembled from the real program ROM through MAME's debugger, at the address
the board has been spinning on all day:

    0001166C: ld      0x91fff0,r3
    00011674: cmpibne 0,r3,0x1166c      loop back unless r3 == 0
    00011678: ld      0x91fff4,g0       then read the results
    00011680: ld      0x91fff8,g1

The i960 writes a command block, **waits for 0x91FFF0 to become ZERO**, and then
reads two result words above it. 0x91FFF0 is buffer RAM byte offset 0x1FFF0 --
dword 0x7FFC -- which is exactly the `0x016FFFF8` word address every UART
capture reported. The coprocessor's banked window reaches the same dword
(R133), and on real hardware the TGP is what clears it.

*Why every build since a9ace86 spun.* `bi_*` initialises buffer RAM to
0x07800F0F, which is not zero, and nothing in this core ever writes 0 to dword
0x7FFC. The compare never falls through.

**`.attract` WAS NEVER WORKING. It was skipping a synchronisation point.** With
BUFFERRAM off the read returned a deterministic 0, which the poll read as "the
coprocessor has finished" on every single pass. The game ran ahead of a
handshake it was supposed to wait at. That is why enabling the mapping looked
like a regression (R139): it was the first build in which the game actually
ENFORCED the handshake, and this core does not satisfy it. `BUFFERRAM_WRONLY`
(R141) restored the machine by the same accident, not by fixing anything.

*What this costs the earlier entries.* R139 called enabling BUFFERRAM "a
regression"; it is better described as the removal of an accident that was
masking a missing feature. R141's isolation was correct in every step -- writes
cleared by experiment, reads at fault -- and aimed at the wrong subsystem: the
read path is fine and returns exactly what is in memory. Five hardware builds of
elimination narrowed the question correctly and could not answer it, because the
answer was not in our RTL at all. **One disassembly of the reference did what
five builds could not, and it was available from the first hour.**

*Standing lesson, and it is the third time this project has paid it.* R128
inferred a design from a write histogram without reading the handler. R135
declared a pipeline healthy from three counters without asking what was on the
screen. This is the same failure once more: the board was telling us WHICH
address it was stuck on from the very first capture, and nobody disassembled it.
**When the machine names an address, disassemble it before theorising about the
subsystem that serves it.**

*What is actually needed.* The coprocessor must complete its mailbox: write 0 to
buffer-RAM dword 0x7FFC when a command finishes, and the two result words the
game reads at 0x91FFF4/0x91FFF8. The copro's write path into buffer RAM already
exists and is correctly addressed (R133); what is unestablished is whether our
TGP ever executes the microcode that performs the write. That is the next
question, and it is a TGP question, not a bridge one.

---

**R143 - THE COPROCESSOR *DOES* WRITE THE MAILBOX, AT THE RIGHT ADDRESS, BOTH
HALVES. R142's REMAINING QUESTION IS ANSWERED AND THE FAULT IS NARROWER AGAIN.**

Measured on the board with the write probe finally wired (a36cc9e0), one
40-second capture:

    C 000002B0 0000FFF9      count 688,  last write word 0xFFF9
    C 000002B2 0000FFFB
    C 00000436 0000FFF9      count 1078 -- climbing throughout

`bufw_addr` is `{win_adr[14:0], wr_hi}`, so word 0xFFF8/0xFFF9 is dword 0x7FFC
-- **exactly the mailbox the game polls at 0x91FFF0** (R142). The coprocessor
reaches it, repeatedly, at a rate of roughly ten writes a second.

*The odd addresses are a sampling artifact, not evidence.* Every captured
address is odd -- 0xFFF9, 0xFFFB, never 0xFFF8 -- which looks like the low half
never being written and the dword therefore keeping 0x0f0f from the initialiser.
It is not. `m2_tgp`'s handshake writes `wr_hi = 0` FIRST and flips to 1 after
the acknowledge, so the low half leads and the high half is simply the one still
latched when the slow profiler tick samples. **A probe that latches on every
event and is read at a fraction of the event rate reports the last event, not
the representative one.** Confirmed by reading the RTL, not by reasoning from
the capture.

*What this retires.* "Our coprocessor never writes buffer RAM" (stated from the
1a66f6ae capture) was wrong twice: the probe was not wired to the stream at all
in that build, and the count it appeared to show was `cpu_dbg_ip`, which read
zero because the CPU was not running. The copro writes, at the right address,
both halves.

*What is left.* The game waits for the dword to read ZERO. The copro writes it
and the game still spins, so the remaining possibilities are narrow:

    1. the VALUE written is not zero -- our TGP computes a different status
    2. the write does not reach SDRAM -- it is counted at the module boundary,
       and nothing yet confirms it survives the shared write port
    3. the game needs more than the flag -- the two result words at 0x91FFF4
       and 0x91FFF8 are read immediately after the poll falls through

The next probe is `bufw_data` for writes to 0xFFF8/0xFFF9 specifically, which
separates (1) from (2) in one build. Reading the SDRAM word back would separate
(2) as well.

*Method note, and it is the same one three entries running.* The count field and
the address field came from the same probe in the same build; one was
informative and the other was misleading, and only reading the RTL distinguished
them. A measurement is not evidence until the thing that produced it is
understood -- R128 (histogram without the handler), R135 (counters without the
screen), R142 (address without the disassembly), and now a sampling rate without
the handshake.

---

**R144 - THE MAILBOX PROTOCOL, FROM THE ROM AND FROM MAME. THE CPU SETS IT TO
0xFFFFFFFF AND THE TGP CLEARS IT TO EXACTLY ZERO, ~17 TIMES A SECOND.**

Disassembled just above the poll (R142):

    00011638: subo    1,0,r3          r3 = 0xFFFFFFFF
    0001163C: st      r3,0x91fff0     the CPU SETS the mailbox non-zero
    00011650: lda     0x17ffc,r3
    00011658: st      r3,(g11)[g12]   command words to the copro FIFO
    0001166C: ld      0x91fff0,r3
    00011674: cmpibne 0,r3,0x1166c    wait for the copro to clear it
    00011678: ld      0x91fff4,g0     then two result dwords
    00011680: ld      0x91fff8,g1

Confirmed live in MAME with i960-side watchpoints over 3 s of emulation:

    CPU W mbox=FFFFFFFF   x51
    CPU R mbox=FFFFFFFF   x12,112      the poll
    CPU R mbox=00000000   x50          the copro cleared it -- 50 handshakes

So the correct clearing value is **exactly 0**, the handshake completes about
17 times a second, and the TGP also produces two result dwords at 0x7FFD/0x7FFE.
R143's capture had our copro writing words 0xFFF9 AND 0xFFFB -- dwords 0x7FFC
and 0x7FFD -- at ~10/s, which is the same shape at a comparable rate.

*What is therefore left, and one build separates all three:* our TGP writes a
non-zero value; or its 0 lands BEFORE the CPU's 0xFFFFFFFF and is overwritten;
or the 0 never reaches SDRAM. The probe streams `tgp_mbox` (what the copro
wrote, both halves) beside `cpu_dbg_ldout` (what the CPU reads back).

*Ruled out by inspection while waiting.* `ACK_HOLD = 2` in m2_sdram: the write
acknowledge is two fast cycles wide, exactly like the reads, so a 2:1 slow
sampler sees it for one slow cycle and a stale ack cannot retire the high half
early.

*A real defect found on the way, NOT the cause of this bug, recorded so it is
not lost.* The shared SDRAM write port has five requesters -- loader, `bi_*`,
`st_*`, the geo front door, the copro -- and ONE acknowledge, `ldr_wr_ack`,
qualified only by the copro. The geo front door takes it raw. The mux
`tgp_bufw_req_r ? ... : geo_sd_busy ? ...` lets the copro preempt a geo write
in flight; whichever address was on the bus is written and BOTH requesters
retire. It cannot be today's cause -- with geo masked (23493a75) the copro had
the port alone and the game still spun -- but it will corrupt display lists
the moment real geometry and copro results flow together. Needs a lock or
per-requester acks. Left unfixed on purpose: one variable per build.

---

**R145 - THE FITTER "CRASHES" WERE EXIT-TIME TCL TEARDOWN FAULTS AFTER A
SUCCESSFUL FIT. EVERY ONE OF TODAY'S TWELVE WAS RECOVERABLE, AND THE SWEEP HAD
BEEN THROWING THEM AWAY.**

Twelve of ~26 fits today ended `*** Fatal Error: Segment Violation`. Every one
had the same signature: the last fitter message was `Generated suppressed
messages file` -- the end of the run -- and the top stack frame was
`ATCL_OBJ::tcl_freeInternalRepProc`, a Tcl object free during shutdown. And
every one had already written

    Fitter Status : Successful

to `Model2.fit.summary`. The placement and routing were done; the process died
freeing memory on the way out. `s101`, reported as a crash, ran `quartus_sta`
by hand and closed at **+0.479 -- the best slack of the day.**

*Why the sweep lost them.* The per-seed subshell inherits `set -e`, so the
fit's non-zero exit aborted it before `quartus_sta` ever ran, and the summary
line then said "Segment Violation" beside an empty result. **The exit code was
being read as the verdict; the verdict was in the summary file.** Fixed: the
sweep now ignores the fit's exit status, requires `Fitter Status : Successful`,
and runs STA on that. A seed is reported as a crash only when the fit is
genuinely incomplete.

*The suspected cause, and it is cheap to test.* Every Quartus run opens with

    qenv.sh: warning: setlocale: LC_CTYPE: cannot change locale (en_US.UTF-8)

because that locale is not installed on this machine -- `locale -a` has only
`C.utf8`, and the shell is `en_GB.UTF-8`. A failed locale is a classic source of
Tcl teardown faults. The sweep now exports `LC_ALL=C` for every Quartus
invocation; whether the crash rate drops is measured, not assumed. It was also
the "~1 in 3" instability this project had recorded as a fact of the tool.

*Standing note.* This project's recorded crash rate, and the seed-sweep tooling
built partly to absorb it, both rested on reading an exit code. Half of today's
compute was spent re-fitting designs that had already fitted.

---

**R146 - THE EMPTY COMMAND FIFO MUST READ ZERO. THE PARAMETER EXISTED, THE
REASON WAS WRITTEN DOWN, AND THE INSTANTIATION PASSED THE WRONG VALUE ANYWAY.**

`m2_copro.sv` carries a comment saying `EMPTY_FIFO_READS_ZERO` **must be set**,
that leaving it default "cost a whole session", and -- verbatim -- "the
parameter was written, the reason was written down, and the instantiation never
passed it." The line immediately beneath it read:

    m2_tgp #(.EMPTY_FIFO_READS_ZERO(1'b0)) u_tgp (

which is the default the comment names as the fault. **The note was written; the
value was never changed.** Reading a comment is not reading the value beside it.

*Why zero is right.* `gen_fifo.h`'s `pop()` returns `T()` on an empty FIFO and
never stalls. Daytona's microcode needs that zero: `0052 brul alw d` jumps to
`d = get_exp(b) + 0x53`, so an empty pop gives 0x53, the IDLE handler. A TGP
that stalls instead cannot reach its own idle path and parks at 004C -- which
is precisely where MAME's TGP sits between commands.

*A SECOND defect on the same path, found while fixing the first.* Even with the
parameter set, the combinational read was wrong:

    fifo_rdata = popped ? pop_data
               : (fifo_in_valid || EMPTY_FIFO_READS_ZERO) ? fifo_in_data : 32'd0;

The parameter only ever meant "do not stall", but it was wired into the DATA mux
as well, so an empty pop completed and handed back **stale `fifo_in_data`**. The
latched path had it right (`fifo_in_valid ? fifo_in_data : 0`) and the
combinational one did not -- and the acknowledge is combinational, so the core
can take the stale word in the same cycle. Now `fifo_in_valid ? fifo_in_data :
32'd0` unconditionally.

*THE MODEL 1 CROSS-CHECK, AND IT CARRIES A WARNING WE MUST HEED.* Model 1 runs
the same MB86233 and reached this conclusion first. Its `m1_tgp.sv` header says
the behaviour is CORRECT and keeps it OFF on purpose:

    BUT TURNING IT ON DEADLOCKS THE MACHINE, on the board and in simulation.
    Unparking the coprocessor means it starts PRODUCING results, and our V60
    never drains them: `fout` fills at ~400 M cycles, the TGP then stops taking
    commands, `fin` fills, and both halt permanently around frame 340.
    FLIP THIS TO 1 WHEN THAT IS FIXED.

Their `520cf6a` proved that state inescapable: fin full and fout full refuse
each other with no external event to break it.

*Why we may nonetheless be able to afford it.* The precondition Model 1 is
waiting on is a consumer that keeps up, and ours appears to. R135 measured the
i960 draining results as fast as the TGP produces them -- `out_pushed`
2149->2173 against `out_popped` 2036->2057 over the same capture. Model 1's V60
is 1.63x too slow; our i960 is not.

*THE OBJECTION HAS SINCE BEEN RETRACTED AND ITS PRECONDITION FIXED.* Two later
Model 1 findings settle it:

  * `520cf6a` re-examined the deadlock and concluded it is **"probably not the
    crash"** -- the hardware signature was the TGP stalled at 004C on an EMPTY
    command FIFO, "the opposite of the state proven here", and "the evidence
    still points at the V60 going wrong first."
  * The note's own escape clause is "FLIP THIS TO 1 WHEN THAT IS FIXED", the
    "that" being the V60's speed deficit. `docs/INCREMENTAL.md` rungs 3 and 5
    (FP pipelining, multiplexer reduction) both landed WORKING, and 2:1 took the
    board from ~46% to ~97% of hardware speed, swaps 13-14 -> 27-29. **The
    consumer now keeps up.** Model 1 has simply not gone back to flip it.

So the one recorded objection was a consumer that could not drain results, and
neither project has that consumer any more.

**It remains a calculated risk with a named failure mode.** The signature to
watch for is NOT the present stuck-at-frame-1: it is everything freezing
together -- TGP retires stopping first, then the CPU stalling. If that appears,
the fix is not wrong, the drain rate is, and the answer is the interlock work
Model 1 describes rather than reverting to a value the reference calls incorrect.

*Method note.* This is the second time today that reading the reference answered
in minutes what hardware bisection could not (R142 was the first). It is also
the second time a fix was found sitting UNAPPLIED beside its own explanation --
R136's Makefile lists were defined below the rules that used them, and this
parameter was documented and then passed wrong.

---

**R147 - LESSONS CARRIED OVER FROM THE MODEL 1 CORE, NOT CODE. SEVERAL OF THEM
NAME FAILURES THIS PROJECT COMMITTED TODAY.**

`tools/model1-ref` is a read-only mirror and nothing is lifted from it. What
transfers is what its commit messages measured on the same device. Read at
`incremental` (`aeb91d7`), `docs/INCREMENTAL.md` and the copro history.

**1. One change per build, from a confirmed base, with the hardware result in
the commit message.** Their rule, verbatim: *"Do not add the next change until
the current one is confirmed and committed... Two days were spent flashing
images containing eight changes at once and attributing each black screen to
whichever piece had been touched most recently. Five different 'found it'
moments all produced the same black screen, because the experiment could not
distinguish them."*

*We did this today.* `1a66f6ae` black-screened carrying walker fixes, YC, ALSA
and a debug refactor at once, and it is STILL unattributed. The seed sweep makes
four seeds cheap and made stacking changes feel cheap too; it is not.

**2. A change present in every failing image is not thereby the cause.** 2:1 sat
under suspicion for two days for exactly that reason; the bisect found the DATA
CACHE. Their file now says in capitals that 2:1 has never been shown to fail.
*We did this today too* -- the coprocessor's buffer writes were suspected on
commit order alone and cleared only when a build finally tested them.

**3. Staging must be cleared, and a stale file that still ELABORATES is worse
than one that fails.** `tools/mister_project.sh` left `dbg_dc_dropped` from
another branch in the staging copy; 102 errors was the lucky outcome. *Ours
stages fresh (`rm -rf "$d"`) but SYMLINKS `rtl/`, so an edit made mid-fit is
silently picked up by a later stage of the same build.* That cost a fit today
when a walker edit landed after map had run. Fresh staging is not the same as a
frozen source tree.

**4. Telemetry that has never been read is not telemetry.** Their data cache
carried `dbg_hits`, `dbg_misses` and `dbg_dropped` and *"NONE has ever been read
on hardware"*, which is why its fault stayed unexplained. Compare R143: our
copro write probe was not wired to the stream at all, and a value was reported
from it anyway.

**5. Standalone area estimates under-predict, and occupancy changes packing.**
Their V60 rung measured -530 ALM standalone and -1,947 integrated -- a factor of
three, in the unexpected direction -- because dropping from 98% to 93%
occupancy gave the fitter room. Any ALM number this study quotes from a
standalone `make quartus MOD=` is a lower bound on the integrated change, not an
estimate of it.

**6. A marginal slack figure may be placement, not design.** Four seeds on
identical RTL spread 0.11 ns (-0.077, -0.037, +0.014, +0.035). *And a low
positive number is not itself a fault*: Measured +0.012 running on the board.
The black screen blamed on +0.081 today was blamed wrongly.

**7. Two findings that are ours to use directly.** The empty-FIFO fix is correct
behaviour and its one recorded objection has been retracted (R146). And the
coprocessor ratio: the real board is a 50 MHz MB86234 against a 25 MHz i960, and
**this core already runs exactly that** -- `clk_sys` 50 MHz for the copro,
`clk_i960` 25 MHz -- where Model 1 had to retrofit 2:1 onto a 1:1 arrangement.
`Model2.sv` said 48/24 in four comments; stale, and corrected.

---

**R148 - THE COPROCESSOR IS HEALTHY. THE i960 NEVER ASKS IT ANYTHING. THE DAY'S
INSTRUMENTATION WAS AIMED ONE STAGE TOO FAR DOWNSTREAM.**

Measured in the boot harness with BUFFERRAM on, 12 M instructions:

    FIFO in pushed    4          MAME: 257,709
    TGP popped        4          MAME: 484,947
    TGP retires       7,159      idling correctly
    TGP data-RAM init matches MAME word for word

*The coprocessor is not broken.* Its init writes match the reference exactly --
`[000]=0 [001]=1 [002]=ffffffff [004]=3f800000 [005]=bf800000 [006]=f [007]=130`
-- and its steady loop is the genuine idle path:

    004c mov rf1,b -> ... -> 0057 brul alw d -> 0058 -> 00b5 mov rf1,d
    00b6 mov rf1,a -> 00b7 fadd -> 00b8 mov d,rf2 -> 00b9 brif alw #0x4c

With an empty FIFO B is 0, `0053 brif !zrd #0xa1` does not branch, and the
computed jump `d = get_exp(B) + 0x58` lands on 0x58 -- the idle handler, which
reads two empty operands, adds them and pushes zero. Ours pushes 132 zeros;
MAME idles pushing zeros from the same path. **This is correct behaviour.**

*What the i960 actually sends.* Four words in the whole run:

    04000001  12802525  12802525  12802525

These are FUNCTION-PORT words -- the command code lives in bits 30:23 -- with
**no float payload behind them.** MAME's first batch is
`3f9e5556 3f5a7171 4260e0e2 42e00000 4289898a 430a7e7e`, real geometry operands,
and it writes the FIFO port 173,552 times against 6,979 function-port writes.
Ours writes the FIFO port essentially never.

**So the coprocessor is not failing to answer. It is being asked the wrong
question.** Compared word for word against MAME, before the first mailbox poll:

    ours   04000001  12802525  12802525  12802525            (4 words)
    MAME   BF600010  00000000  00000000  41000000  00000000
           3B8E38E4  438E8000  3F9E5556  3FB98E39  42E00000  ... (32 words)

MAME sends 32 FLOAT operands; we send four words, three of them IDENTICAL, none
of them a float. 0x12802525 decodes as function code 0x25 with payload 0x2525 --
the same command three times, unchanged. The counter was checked before this was
believed: `dbg_in_pushed` increments for both the FIFO port and the function
port, so four is the true total.

*This is a DATA divergence, not a control-flow one, and that is why nothing
caught it.* `tools/i960-diff.sh` compares PROGRAM COUNTERS and was byte-perfect
for 521,752 instructions. R133 already recorded the shape: "a processor can
execute the right program and still read the wrong memory -- it produces wrong
VALUES, not divergence." The same blind spot, a second time.

The repeated identical word is the lead: it is what a loop looks like when the
value it reads never changes.

*The method failure, and it is the day's largest.* Every build from `35d991a9`
onward instrumented the COPROCESSOR -- its buffer writes, its mailbox value, its
all-ones reads by source, its retires and pc. The i960's push count was
measurable in the harness the entire time and was not looked at until As noted at the time,
repeatedly, that the CPU side was where the fault must be. **A stalled consumer
and an unfed producer look identical from the consumer's side; only the producer's
output rate distinguishes them, and it was never measured.**

*Where the question now goes.* Why does the i960 stop after four command words?
It is not held by the coprocessor -- measured, `i960 HELD by the copro for 0 of
110,254,956 cycles (0.0%)`. R142's mailbox wait explains why it stops
PROGRESSING, but not why it never fed the coprocessor before reaching that wait.
The next comparison is the i960's own instruction stream against MAME's around
the first function-port write, which `tools/i960-diff.sh` already does.

---

**R149 - THE COPROCESSOR RUNS AT FULL SPEED. FIVE CONCLUSIONS FROM 3 SEPTEMBER
RESTED ON MISREAD INSTRUMENTS AND ARE RETRACTED HERE.**

`dbg_retires` is a 16-bit counter that WRAPS, and says so two lines above its
own increment. Reading its first and last values as a total gave "10,815 retires
in 40 seconds -- 270 instructions per second, four orders of magnitude below
MAME". Measuring the DELTA between consecutive samples instead:

    delta per sample   12,963 (x6257)  12,964 (x2725)  12,962 (x1436)
    samples per second ~377
    => 12,963 x 377 = 4.9 M instructions/second

**MAME's TGP runs 4.6 M/s. Ours runs 4.9 M/s.** It is not slow, not stalled and
not deadlocked. It never was.

*What that retracts, in order:*

  1. "The coprocessor is frozen at 270 instructions/second" -- WRONG, wrapping
     counter read as a total.
  2. "A full output FIFO deadlocks the TGP (Model 1's 520cf6a shape)" -- WRONG,
     built on (1). Simulation had already shown `WORDS DROPPED out=0`, i.e. the
     output FIFO never fills, and that was noted and then reasoned past.
  3. "Our i960 sends 4 wrong words where MAME sends 32 floats" (R148) --
     UNSOUND. The capture is sampled a cycle off `obs_push_data`: the same run
     reported `04000001` at 12 M instructions and `00000000` at 60 M from the
     same PC, and a deterministic simulation cannot do that. The COUNT stands;
     the VALUES do not.
  4. "Commands are popped at instructions that never read the FIFO" -- WRONG,
     that trace samples at PUSH time, so its program counters are wherever the
     TGP happened to be, not pop sites.
  5. "The copro never writes buffer RAM" (from 1a66f6ae) -- already retracted in
     R143; the probe was not wired to the stream at all.

*What survives, measured and reliable:*

    the TGP runs at ~4.9 M instructions/second, in its idle loop
    109 commands arrive and are popped -- none is dispatched
    pc never reaches 00a1, the command path
    the coprocessor never writes the mailbox at dword 0x7FFC

*The live hypothesis, and it is arithmetic rather than a guess.* The idle loop
reads the command FIFO THREE times per iteration -- `004c mov rf1,b` (the
dispatch), then `00b5 mov rf1,d` and `00b6 mov rf1,a` (the idle handler's two
operands). Only the first is a dispatch. At ~272,000 loop iterations a second
against ~4 commands a second, a command is far likelier to be eaten as an
operand than to be seen by the dispatch. MAME survives the same race by pushing
144,000 words a second, so a large share land on `004c`. **If this is right, the
fault is not in the coprocessor at all -- it is that our i960 sends four
commands a second where the reference sends tens of thousands.**

*THE STANDING LESSON, PAID FIVE TIMES IN ONE DAY.* R128 read a histogram without
the handler. R135 read counters without the screen. R142 read an address without
the disassembly. R143 read a probe that was never wired. R149 read a wrapping
counter as a total. **Before any number is used as evidence, read the code that
produces it.** Every one of these cost a build, a wrong conclusion recorded in
this study, or both.

---

**R150 - THE i960'S COMMAND RATE IS THE REFERENCE'S, EXACTLY. R148 AND R149
COUNTED MAME'S MICROCODE UPLOAD AS COMMANDS, AND THE "FOUR ORDERS OF MAGNITUDE"
GAP WAS AN ARTEFACT OF THE PORT THE UPLOAD SHARES.**

R148: *"it writes the FIFO port 173,552 times against 6,979 function-port writes.
Ours writes the FIFO port essentially never."* R149 built its live hypothesis on
that: *"our i960 sends four commands a second where the reference sends tens of
thousands."* Both are wrong, and the measurement that settles it is one
watchpoint.

MAME, every write to 0x880000-0x887fff up to the first mailbox poll at 0x1166c,
split by port:

    0x884000  fifo + PROGRAM UPLOAD     2055
    0x880000  function port               78
                                        ----
                                        2133

Ours, same point in the boot, from the harness:

    program uploaded                    2024 words
    FIFO in pushed                       109
                                        ----
                                        2133

2024 + 109 = 2133. MAME's 2055 is the same 2024 microcode words plus 31 payload
pushes, and 31 + 78 = **109 -- the identical command count, word for word.**

*Why the port hides it.* `copro_fifo_w` (model2.cpp:624-631) is BOTH the command
FIFO and the microcode loader; which one a write means depends on
`m_coproctl & 0x80000000`, not on the address. A watchpoint on the port counts
2,024 program words as commands. Our harness separates them because our RTL
does, so the two counters were never measuring the same thing. Comparing them
produced a 20:1 gap where there is none.

*What this retracts:*

  1. R148's "the i960 is being asked the wrong question" -- it is not. It sends
     the same 109 words at the same point.
  2. R149's live hypothesis in full: the 004c-versus-00b5/00b6 race, the
     ~272,000 iterations against ~4 commands, and the conclusion that "the
     fault is not in the coprocessor at all". The premise was the rate gap.
  3. "pc never reaches 00a1, the command path" as evidence of a missed
     dispatch. 00a1 is the branch taken when `bl != bh`; for command 0x25,
     `bl == bh == 0x25`, so the reference does not take it either. The
     dispatch at 004c computes `d = bh + 0x58` and jumps -- MAME to 0x7d, then
     0x30a, 0x30b, back to 004c. **Our TGP was already doing exactly that**
     (`pc=030b B=12802525 D=0000007d` in the harness log, before any change).
     It was dispatching correctly the whole time.

*The method failure, and it is the same one three entries running.* R149 closed
with "before any number is used as evidence, read the code that produces it",
and then this entry's premise was a counter whose producing code
(`copro_fifo_w`) multiplexes two unrelated things onto one address. The rule
was written down and the next number was taken on trust anyway. **Reading the
code behind OUR instrument is not enough; the reference's instrument needs the
same treatment.**

---

**R151 - BOTH FIFO POPS STALL THEIR READER IN THE REFERENCE, AND OURS STALLED
NEITHER. R146 READ pop()'s RETURN VALUE WITHOUT THE CALLBACK FIRED SIX LINES
ABOVE IT.**

R146 concluded: *"gen_fifo.h's pop() returns T() on an empty FIFO and never
stalls."* The first half is true. The second is contradicted by the body of the
function:

    gen_fifo.cpp:109-115
        if(is_empty()) {
            m_sync_empty->adjust(attotime::zero);
            m_on_fifo_empty_pre_sync();     // <-- fired FIRST
            return T();                     // <-- to a cancelled instruction
        }

model2.cpp:193-209 binds both callbacks, and both replay the instruction that
read:

    copro_fifo_in  (i960 -> TGP)   on empty: m_copro_tgp->stall()
    copro_fifo_out (TGP -> i960)   on empty: m_maincpu->i960_stall()

    i960.h:71-75        m_stalled = true; m_IP = m_PIP;
    i960.cpp:2053       `if(!m_stalled)` -- the destination register is not written
    mb86233.cpp:1225-7  do_stall: m_pc = m_ppc; m_stall = false;

**In the reference neither processor ever observes the zero.** The T() is
returned into an access that has already been cancelled and will be re-executed.

*Why the i960 side is the one that mattered.* The ROM's coprocessor protocol is
synchronous. Ghidra (the i960 SLEIGH module, headless, `analyzeHeadless`) and
MAME's `dasm` agree on 0x11548-0x115e0, with g11 = 0x880000 and g12 = 0x004000:

    00011598  st  r5,(g11)[g12]     push
    0001159C  st  r6,(g11)[g12]     push
    000115A0  ld  (g11)[g12],g0     READ THE RESULT -- the next instruction
    000115A8  chkbit 31,g0          and branch on it

Push, push, read. **The FIFO read IS the wait**, and there are dozens of these:
0x115a0, 0x115d0, 0x11558, 0x67d4, 0xf110, 0xf1a4, 0xf3d4. Our
`rdata = fout_valid ? fout_q : 32'd0` answered every one of them with zero the
moment the coprocessor had not yet finished, and left the real results queued
in `fout` to be read as answers to questions asked later. A third DATA
divergence of the shape R133 named, invisible to `tools/i960-diff.sh` because
that compares program counters.

*What 41199bf got right, and where it overreached.* `push()` genuinely never
blocks -- a full FIFO queues to `m_extra_values` and halts the source at a
scheduler sync, outside the bus cycle. Removing the stall on a full WRITE was
correct. But the commit generalised "the reference never blocks the CPU inside
a bus cycle" from `push()` to `pop()`, and `pop()` does exactly that. The rule
is directional: **writes never stall, reads always do.**

*The change, two lines, both back to the reference:*

    m2_copro.sv   assign stall = fifo_rd && !fout_valid;    // was 1'b0
    m2_copro.sv   m2_tgp #(.EMPTY_FIFO_READS_ZERO(1'b0))     // was 1'b1

No new mechanism was needed. `m2_cpu_bridge.sv`'s S_IOW already holds an access
while `io_stall` and samples `io_rdata` only when it falls; `fout_pop` was
already gated on `fout_valid`, so a held read pops once, on the cycle the word
lands. R146's other finding on the same path -- the combinational read handing
back a stale head -- was a real defect and its fix stays.

*Measured, boot harness, BUFFERRAM=1, 20 M instructions, one variable changed:*

                              before        after
    TGP sits at               pc 0055       pc 048f
    distinct TGP pcs          150           456
    copro buffer-RAM writes   0             2
    dword 0x7FFC hits         0             2
    i960 held by the copro    0 cycles      7,960
    TGP retires               40,487        14,680

pc 0x480-0x4b0 is the display-list handler -- `rep #0xc` then
`mov (x0+1)(e),(bx1+1)`, the twelve-word vertex copy -- and 0x48f is MAME's
hottest TGP address after the first poll (5,580 of 112,853 traced
instructions). **The coprocessor writes buffer-RAM dword 0x7FFC, the mailbox
the game polls, for the first time in this project's history.**

*IT IS NOT FIXED. Both runs still end at IP 0001166c.* Two mailbox writes in
20 M instructions, and the game still spins, so either the value written is not
the zero the poll wants or it arrives after the poll begins. The harness counts
0x7FFC hits and does not record the VALUE; that probe is the next step and it
is a harness change, not a fit. Recorded here rather than left implicit,
because a partial result reported as a fix is how R141 and R143 went wrong.

*Regression state.* Every TGP target passes (`mb86233_mem/dec/xfer/seq/alu/agu`,
`fp_mul/add/div`, all fails=0). `mb86233_regs` fails 46,966 checks on register
0x21 -- byte-identical to the pre-existing count recorded before this change,
so it is untouched by it, and it remains owed.

*The deadlock this re-arms, named in advance.* Model 1's 520cf6a: `fout` full
holds the TGP, `fin` full holds the CPU, nothing releases either. It requires a
consumer that stops draining results, and a CPU that stalls on every result
read drains by construction. If it ever appears the signature is everything
stopping together -- TGP retires first, then the CPU -- not the frame-1 hang
this replaces.

*Method.* R146 quoted a line of `gen_fifo.h` that is true and drew from it a
conclusion the six lines above it forbid. Same family as R149's wrapping
counter and R150's shared port: the instrument was real, the reading was
partial. **Read the function, not its return statement.**

---

**R152 - THE 2:1 HANDSHAKE AUDIT MODEL 1 ASKED FOR. WE ARE SAFE, AND NOT BY
ACCIDENT -- THE EXACT 100/50/25 CHAIN IS WHAT MAKES BOTH HANDSHAKES CORRECT.
MODEL 1 ALSO CONFIRMS R151 INDEPENDENTLY.**

*The warning.* Model 1 found that bringing its coprocessor to 2:1 broke the
handshake, because the action fired on every cycle the request was held rather
than once. Its `incremental` branch states the rule in
`rtl/tgp/m1_copro_if.sv`:

    `req` is HELD until `ack` ... The action fires once, on the cycle the
    access completes, so a held request cannot double-pop a FIFO or
    triple-increment the address.

(Note for the reference clone: `main` and `wip-2to1` are both `57ce77e`, the 2:1
WIP that is black on hardware. **`incremental` is the live branch** and rung 7,
the 2:1 TGP itself, is still uncommitted there -- the standing blind spot.)

*Why it does not bite us, checked rather than assumed.* Our exposure looks
identical -- `fin_push` and `fout_pop` in `m2_copro.sv` carry NO edge
qualification:

    wire fin_push = (fifo_wr && !uploading) || fn_wr;
    wire fout_pop = fifo_rd && fout_valid;

They are safe because the SELECT is already one coprocessor cycle wide.
`m2_cpu_bridge` registers `io_sel` in its `always_ff @(posedge clk_mem)` block,
and the top level wires `.clk_cpu(clk_i960)` with `.clk_mem(clk_sys)`. The
coprocessor runs on `clk_sys` too, so a select is generated in the
coprocessor's OWN domain and lasts exactly one of its cycles. **The 2:1
crossing lives inside the bridge, between clk_cpu and clk_mem, which is where
Model 1 had to retrofit it.**

*The empirical proof, and it was already in hand.* `dbg_prog_words` and
`dbg_in_pushed` are both incremented per select-cycle, so a doubled select
doubles them:

    program uploaded  2024 words   MAME: 2024
    FIFO in pushed     109         MAME:  109

The boot harness DOES model the ratio (`clk_mem` 48 MHz, `clk_cpu` 24 MHz,
copro on `clk_m`), so this is a live test of the crossing and not a 1:1
simplification. Doubling would have read 4048 and 218.

*THE RATIO IS LOAD-BEARING, AND ONE STEP OF IT WOULD HAVE BEEN A REAL BUG AT
96 MHz.* `m2_sdram`'s parameter says so in its own words:

    // Ack hold. Requesters on a slower synchronous clock must see exactly one
    // rising edge with ack high, so this is 2 for a clk/2 requester.
    parameter int unsigned ACK_HOLD = 2

That invariant holds only if `clk_sys` is exactly half the memory clock. It is:
the PLL is configured `output_clock_frequency0("100.000000 MHz")` and
`output_clock_frequency1("50.000000 MHz")`. **Had the memory clock really been
the 96 MHz that nineteen comments across four files still claim, a 2-cycle ack
would be 20.83 ns against a 20 ns `clk_sys` period -- one rising edge or two
depending on phase, and a requester taking a stale ack for its NEXT access.**
That is Model 1's failure mode exactly, and the only thing standing between us
and it is a frequency that the prose gets wrong.

*So the finding is documentation, and it is not cosmetic.* Every NUMBER was
migrated to 100 MHz correctly and independently verified here:

    PLL          outclk_0/4 = 100.000000 MHz, outclk_1 = 50, outclk_3 = 25
    phase_shift4 5000 ps      -- 180 deg at 100 MHz; the comment even records
                                 that it "was 5208 for 96 MHz"
    T_REFI       781          -- 7.81 us at 100 MHz (750 would be the 96 figure)
    ACK_HOLD     2            -- correct for an exact clk/2 requester
    Model2.sdc   "general[0] is 100 MHz ... general[0] and general[4] here are
                 both 100 MHz and differ only in phase"

The prose did not follow. `Model2.sv`'s clock declarations said 96 and are
corrected here, with the ratio's consequences written beside them; the
remainder are historical measurements or references to the Kaneko16 core, which
genuinely ran at 96, and are left alone. **A stale frequency in a comment is
not a cosmetic defect when a handshake's correctness is derived from it -- this
audit spent its first pass concluding ACK_HOLD was broken, on the strength of a
comment.**

*AND MODEL 1 CONFIRMS R151 INDEPENDENTLY, FROM ITS OWN HARDWARE.* The header of
`m1_copro_if.sv` on `incremental`:

    AN EMPTY RESULT-FIFO READ STALLS. THIS WAS CHANGED TO RETURN ZERO ON
    2026-08-30 AND REVERTED THE SAME DAY ...

    gen_fifo.h says a pop on an empty fifo "returns zero" - and ALSO asks the
    destination to retry, and halts it after a sync if the fifo is still empty.
    The retry means the zero is never consumed ... Returning zero AND
    completing lets the V60 consume the zero, and this is what that did:

    the V60 reads twelve results into a matrix ... gets zeros, stores zeros,
    and at command 673 pushes 00000000 x4 where the reference pushes four
    floats. The real results then land in fout with nobody coming back for
    them: fout fills, the TGP halts, fin fills, the V60 halts.

    So both FIFO directions stall on empty, which is MAME's effective behaviour
    in both.

Two projects, two processors, the same source, the same conclusion, reached a
week apart and each without the other. **It also names the deadlock R151 listed
as its own named risk as a CONSEQUENCE of returning zero rather than of
stalling** -- fout fills precisely because a consumer that took a zero never
comes back for the real result. Stalling is what prevents it.

*Method.* This entry exists because A hardware finding from the
other project and the audit was run before a build rather than after a failure.
Every previous entry in this range was written the other way round.

---

**R153 - THE MAILBOX PROTOCOL, COMPLETE, FROM THE MICROCODE. THE HARNESS COULD
NOT HAVE SHOWN IT CLEARING: THREE STRUCTURAL GAPS ON THE COPRO/BUFFER-RAM PATH,
ALL FIXED. OUR TGP NOW FAILS FOR ONE MEASURED REASON.**

*First, a retraction from earlier the same day.* R151 reported "both runs still
end at IP 0001166c" and offered two explanations, one being that our
coprocessor writes a non-zero mailbox value. **That was measured against a
harness that could not have produced any other result, and the value we write
is CORRECT.** See below.

*THE HARNESS WAS NOT MODELLING THE MEMORY THE TWO SIDES SHARE.* Three separate
gaps, each of which alone is enough to make the handshake impossible:

  1. **Buffer-RAM writes were discarded.** `bufw_data` was wired to the
     observer and then used by nothing; `bufw_ack` was tied to 1'b1. The CPU
     meanwhile reaches buffer RAM through the bridge, which maps it into SDRAM
     at `base_buffer`. The two sides were not talking to the same memory, so
     the mailbox at dword 0x7FFC could not clear however the coprocessor
     behaved.
  2. **Buffer-RAM reads were served from the DATA ROM.** `tgp_tick()` did
     `rd32(COPRO_BASE + (dat_addr << 1))` unconditionally and `.dat_is_buf()`
     was left unconnected on the instantiation. Model2.sv picks the base with
     exactly that signal -- `p_addr[9] = (dat_is_buf ? GAME_BUFFER :
     GAME_COPRO) + {dat_addr, dat_half}` -- so every display-list read in
     simulation returned ROM bytes.
  3. **`dat_addr` was truncated from 20 bits to 19.** The port was widened in
     `m2_copro` when the data ROM went to its full 4 MB; the harness port was
     left at `[18:0]` and dropped the top bit silently.

All three are fixed, and the harness now shares one array between the CPU and
the coprocessor.

*THE PROTOCOL, END TO END, FROM MAME's OWN MICROCODE.* Read with `focus
copro_tgp` and breakpoints, against the microcode as uploaded (a `dasm` of the
TGP before the upload is 2,048 zeros):

    CPU   0001163C  st r3,0x91fff0        writes 0xFFFFFFFF   x50 in 6 s
    CPU   00011658  st ...,(g11)[g12]     pushes the batch
    TGP   0000046F  mov {0} $2, (x1)(e)   x1=0x7FFC, $2=0xFFFFFFFF   x50
    TGP   0000047C  mov (x0+1)(e), $0x4a  the display-list COUNT, from buffer
                                          RAM at x0 ~ 0x1088. MAME: 6,7,8,9,0x14
    TGP   00000481..04B5                  the loop, counting $0x4a down
    TGP   000004BC  mov {0} $0x4b, (x1)(e)  x1=0x7FFD, the result count   x50
    TGP   000004C4  mov {0} $0,    (x1)(e)  x1=0x7FFC, writes ZERO        x50
    CPU   0001166C  ld 0x91fff0,r3        the poll exits

Confirmed by watchpoint that **the i960 never writes zero there** -- 50 writes
of 0xFFFFFFFF and one of 0x07800000, nothing else -- so 0x4C4 is the only
clearing writer, and R144's "the TGP clears it to exactly zero" is now located
in the microcode rather than inferred from the CPU's reads.

*`{0}` IS NOT "WRITE ZERO".* It is the disassembler printing transfer-type
`(opcode >> 18) & 7`, and `mb86233.cpp` cases 0 and 1 are byte-identical. The
zero at 0x4C4 comes from the SOURCE, data-RAM `$0`, which the init sets to 0 --
just as 0x46F's 0xFFFFFFFF comes from `$2`. Reading `{0}` as an immediate would
have produced a wrong fix; the value was checked with `dd@0` and `dd@2` instead.

*SO OUR 0x46F WRITE IS RIGHT.* MAME writes 0xFFFFFFFF to dword 0x7FFC from the
same instruction with the same operand, 50 times. Our one such write is correct
behaviour and not the defect.

*THE DEFECT, MEASURED.* With all three harness gaps closed:

    DISPLAY-LIST COUNT at 0x47E:  ffffffff        MAME: 6, 7, 8, 9, 0x14

`$0x4a` is read from buffer RAM at 0x47C and counted down by the loop at
0x481-0x4B5; 0x4B4 falls through to the result store and the clear only when it
reaches zero. **0xFFFFFFFF is 4.3 billion iterations, so the loop never
terminates, 0x4BC and 0x4C4 are never reached, and the mailbox is never
cleared.** That is exactly what the pc histogram shows: 2,003,400 cycles at
0x48F and 569,792 at each of 0x49B/0x49D/0x49F/0x4A0, with 0x4C4 absent.

0xFFFFFFFF is this project's standing signature for **unwritten memory** -- the
rule from `docs/mister-integration.md` that a read of memory nobody has written
returns all-ones, never zero. So the count is not being corrupted; it is being
read from somewhere nothing has written.

*WHAT IS NOW OPEN, AND IT IS ONE QUESTION.* Either the coprocessor's read
ADDRESS is wrong, or the CPU's display-list writes are not landing where it
reads. MAME's `x0` at 0x47D is ~0x1088/0x11B1, small dword offsets into buffer
RAM, and the same figure from our core has not yet been captured. That is the
next probe and it needs no fit.

*Method.* Three of this session's conclusions have now been drawn from
instruments that could not have reported anything else -- R150's shared port,
R151's discarded writes, and this entry's ROM-sourced reads. The rule stated in
R149 and restated in R152 keeps being paid for: **before a number is used as
evidence, read the code that produces it -- including the harness's.**

---

**R154 - THE COPROCESSOR DATA ROM WAS NEVER LOADED INTO THE BOOT HARNESS, AND
THAT WAS THE DISPLAY-LIST COUNT. THE MAILBOX HANDSHAKE NOW COMPLETES, 37 TIMES
IN A 20 M-INSTRUCTION RUN.**

*The chain, followed to the bottom.* R153 left one question: is the count read
from the wrong address, or is the right address empty? Neither, quite. The
answer was a fourth harness gap behind both.

The TGP's init computes the base every display-list access is built from:

    07CC  lia #0x800000          a = 0x800000, the data-ROM bank
    07CD  mov a, rf3             select it
    07CE  ldi #0x10, b1
    07CF  mov (bx1) (e), d       READ THE COPRO DATA ROM
    07D0  addd                   d += 0x800000
    07D1  mov d, $0x69           $0x69 -- the base

and every command then does:

    0474  mov $0x69, d
    0475  addd : mov rf1, $0x53   d = $0x69 + the pushed pointer
    0478  mov d, rf3              the bank
    047B  mov d, x0               the offset
    047C  mov (x0+1) (e), $0x4a   THE COUNT

`tb_m2_boot.cpp` loads `main_data` at DATA_BASE and the TGP math tables at
TBL_BASE. **It never loaded `copro_data` at GAME_COPRO at all**, so every read
of that ROM returned the uninitialised 0xFFFFFFFF -- including the one at 0x7CF.
MAME has `$0x69 = 0xFF800030`; ours came out 0x30 short, the count at 0x47C was
fetched from dword 0x1057 instead of 0x1087, and read 0xFFFFFFFF. That is
4.3 billion loop iterations, which is why 0x4BC and 0x4C4 were never reached.

Loaded from `ROM_REGION32_LE("copro_data")` in model2.cpp -- `mpr-16537.ic28`
low, `mpr-16536.ic29` high, the same interleave as main_data.

*Measured, same command, 20 M instructions:*

                              before        after
    FIFO in pushed            109           1,571
    FIFO out popped           62            548
    TGP retires               1,381         61,627
    distinct TGP pcs          410           812
    copro buffer-RAM writes   2             178
    dword 0x7FFC hits         2             74
    display-list count        ffffffff      4, 12, 34, 70, ac, ...

**And the handshake completes.** The mailbox log shows the full protocol
cycling, exactly as the reference does it:

    cyc 196283999  0fff8 : ffff   tgp pc=046e     the CPU's batch, armed
    cyc 197513453  0fff8 : 0000   tgp pc=04c3     THE CLEAR
    cyc 202258059  0fff8 : ffff   tgp pc=046e
    cyc 202261913  0fff8 : 0000   tgp pc=04c3
    ...

37 complete handshakes in the run, against zero before. The CPU reaches code it
had never reached: pages 0x0000e000 (7,484 instructions) and 0x00013000 (2,879)
appear for the first time, and 0xE20C is the caller of the mailbox routine at
0x11620 that Ghidra had already identified.

*A discrepancy that does NOT matter, checked rather than assumed.* MAME's ROM
read at 0x7CF is 0xFF000030 and ours is 0x00000030 -- the top byte differs. The
ROM bytes were read directly and genuinely contain 0x00000030 at dword 0x10
(with dwords 0x00/0x05/0x0A/0x0F all 0x3F800000, an identity matrix, so the
interleave is right). The difference cannot reach the address: MAME computes
`adr = (bank & 0xff0000) | (d & 0xffff)` and both sides give bank bits 0x800000
and offset 0x1087. MAME's extra 0xFF000000 comes from `(bx1)` = b1 + x1 with a
non-zero x1 at that call, which the caller supplies; it is worth settling but it
is not this bug.

*STILL OPEN.* The counts differ from the reference -- ours run 4, 0x12, 0x34,
0x70, 0xAC, an arithmetic progression of 0x38, where MAME reads 6, 7, 8, 9,
0x14. So the handshake completes but the display lists being walked are not the
reference's. That is the next comparison, and like everything in R150-R154 it
needs no fit.

*Method, and this is the fourth time in one session.* R150's shared port,
R151's discarded writes, R153's ROM-sourced reads, and now a ROM that was never
loaded: **every one of them made the harness incapable of reporting the thing
being asked of it, and in each case the number it did report was taken at face
value first.** The rule from R149 has now been paid for four times in a day.
The harness is part of the instrument and gets read like one.

---

**R155 - THE COMMAND STREAM MATCHES MAME FOR 110 WORDS. THE DIVERGENCE TRACES TO
ONE INSTRUCTION: AN EXTERNAL READ INTO A REGISTER RETURNS ZERO, WHERE THE SAME
READ INTO DATA MEMORY WORKS.**

*The stream comparison.* With R154's ROM loaded, our i960's command stream was
dumped in order and diffed against MAME's (watchpoint on 0x880000-0x887fff,
first 2,024 fifo-port writes dropped as the microcode upload). **The first 110
words are identical, word for word**, including the batch R144 disassembled:

    idx 104..109   00017FFC 00000000 00001057 42E00000 430A7E7E 15002A2A
    idx 110        ours 00000000   MAME 00000146    <<<
    idx 114        ours 00000000   MAME 00000146    <<<
    idx 119        ours BDCCCCCD   MAME 80000000    <<<

`BDCCCCCD` names its own cause. `FUN_00011620` at 0x11688 is
`cmpobe 0,g0,0x116b4`, and 0x116B4 is `lda 0xbdcccccd,g0` -- **the constant the
CPU substitutes when the coprocessor's first result dword reads zero.** Our
harness confirms it: 0x91FFF4 held `bdcccccd`, not the 2 that MAME's 0x4BC
writes.

*Tracing it back, and it ends at one instruction.* The display-list pointer at
0x475 is right for the FIRST command and zero thereafter, and the pointers walk
two interleaved streams in MAME (1057, 1180, 1049, 1172, 103B, 1164, ...
stepping back by 0xE). Our count read lands on ROM dword 0x1057 where MAME's
lands on 0x1087 -- exactly 0x30 low. That 0x30 is built once, at boot:

    07CC  lia #0x800000        a = 0xFF800000  (sign-extended, ours and MAME's)
    07CD  mov a, rf3           the data-ROM bank
    07CE  ldi #0x10, b1
    07CF  mov (bx1) (e), d     READ THE DATA ROM -> d
    07D0  addd                 d = d + a
    07D1  mov d, $0x69         the base every command is computed from

Traced in the harness, one instruction per row:

    pc=07ce  d=bdcccccd        (unchanged, as expected)
    pc=07cf  d=00000000        <<< the read result -- should be 0x00000030
    pc=07d0  d=ff800000            0 + 0xFF800000
    pc=07d2  d=ff800000        MAME: d=FF800030

**The memory read itself is correct** -- the same run logs
`dat_addr=00010 is_buf=0 -> 00000030` for that access. The value is fetched and
then not written to `d`. `$0x69` therefore comes out 0xFF800000 instead of
0xFF800030, and every display-list access afterwards is 0x30 low.

*The contrast that localises it.* The count read at 0x47C,
`mov (x0+1) (e), $0x4a`, is the SAME external source with a DATA-MEMORY
destination, and it works -- 0x152 was fetched and landed. So the external read
path is sound; it is the register destination that loses the value.

*The instruction, decoded.* `1C1E3380` is group 0x07 with `op = (opcode>>18)&7
= 7`, `r2 = 0x119`, so `r2 >> 6 = 4` -- mb86233.cpp's **case 7 sub-case 4, "mov
mem (e), reg"**:

    u32 ea = ea_pre_1(r1);
    u32 v  = m_io.read_dword(ea);
    ...
    alu_post_1(alu);
    write_reg(r2, v);          // the transfer write is LAST, and wins

*What was inspected and found correct on paper, so the fault is subtler than
any of them.* Recorded so the next session does not re-read the same files:

  * `mb86233_dec.sv:115` -- `op7_sub = r2[8:6]`, which is 4. Correct.
  * `mb86233_xfer.sv` 3'd4 -- `src_space = EP_IO; src_bank = 1'b1;
    dst_is_reg = 1'b1; dst_use_r2 = 1'b1`. Correct, and `ea_pre_1` matches.
  * `mb86233_core.sv:553-585` -- S_SRC_W latches `src_val <= io_rdata` gated on
    `io_ack`. Shared with the working 0x47C case.
  * `mb86233_core.sv:708-710` -- S_DST asserts `rf_wr_en` with
    `rf_wr_addr = d_r2[5:0]` = 0x19 and `rf_wr_data = src_val`.
  * `mb86233_regs.sv:268` -- `6'h19: reg_d <= wr_data`. Present.
  * `mb86233_core.sv:729` -- S_ALU sets
    `xfer_d_valid = d_ldmov & x_dst_reg & (d_r2[5:0] == 6'h19)`.
  * `mb86233_alu.sv:483-485` -- `s2_xv` gives the transfer priority over an
    integer op, which is the reference's ordering.

Every stage claims to do the right thing and the value still arrives as zero.
Note `alu_active = d_lab | d_ldmov | d_repgrp` (`core.sv:405`), so the ALU
pipeline RUNS for this instruction even though its `alu` field is 0, and both
the S_DST register write and the ALU's `s2_xv` writeback target `reg_d` --
`regs.sv` lets `if (alu_d_we) reg_d <= alu_d;` override the write_reg path
unconditionally. That interaction is the first place to instrument.

*The instrument to build next, rather than more reading.* A directed case in
the `mb86233` differential suite: group 0x07, op 7, sub 4, external source,
register destination, against `mb86233_ref`. The suite is green today, so it
does not cover this shape -- which is why a defect this central survived.
`mb86233_regs` remains red on 0x21 (rf1) at its long-standing 46,966, unrelated
and still owed.

*Perspective.* This is the FIRST defect of this session located in our own RTL.
R150 through R154 were all instruments -- a shared MAME port, discarded writes,
ROM-sourced reads, an unloaded ROM. With those cleared, the core's own command
stream now matches the reference for 110 words and the mailbox handshake
completes 37 times in a run.

---

**R156 - FIXED. THE BANKED VIEW LOST THE IO DECODE TO A MODEL 1 REGISTER
WINDOW. THE COMMAND STREAM NOW MATCHES MAME FOR EVERY WORD CAPTURED, THE
MAILBOX READS ZERO, AND THE CPU HAS LEFT THE POLL.**

*R155's location was right and its attribution was wrong.* It put the fault in
the mb86233 core, on the strength of "an external read into a register returns
zero where the same read into data memory works". Building the test proved the
core innocent:

  * `sim/tgp/tb_mb86233_core.cpp` **had no run target at all.** The only rule
    naming it was `lint_mb86233_core`, which lints `$(M1R)` -- the read-only
    Model 1 clone -- not our `rtl/tgp`. The harness's own header says "what is
    unproven here is the glue", and the glue had never been executed.
  * Wired up as `test_mb86233_core` against our RTL and given directed cases
    for every `(e)` form into A/B/D/P, including the literal opcode
    `0x1C1E3380` with `(bx1)` addressing: **all pass.** The core does this
    correctly.
  * The lockstep section explains why nothing caught it earlier: its transfer
    forms are `FORMS[] = {0, 3, 6}`, all data-space. **Not one external `(e)`
    form -- 1, 2, 4 or 5 -- was ever generated.**

*The real fault, in `m2_tgp.sv`.* The IO decode computed the Model 1 register
window from the address alone and tested it FIRST in the read mux:

    wire io_lo    = (io_addr[15:5] == 11'd0);          // 0x00-0x1f
    wire sel_radr = io_lo && (io_addr[2:0] == 3'd0);
    ...
    if      (sel_radr) io_rdata = copro_adr[radr_i];
    else if (sel_rom || sel_buf) io_rdata = dat_rdata;

Daytona's TGP init reads the data ROM at offset 0x10 (`mov (bx1) (e), d` at
0x7CF, b1 = 0x10). That hit `sel_radr`, returned `copro_adr[2]` -- a register
nothing had written, so zero -- and **discarded the 0x30 the ROM had already
returned**. `dat_req = io_rd && (sel_rom || sel_buf)` fired regardless, which is
exactly why the read looked correct on the bus while the core got zero, and why
the count read at 0x1087 worked: `io_addr[15:5] != 0` there, so it fell through
to `dat_rdata`.

*The reference.* model2.cpp installs the math units and then the view, over the
whole space:

    map(0x00020, 0x00023) sincos ... map(0x0002a, 0x0002b) isqrt
    map(0x0000, 0xffff).view(m_copro_tgp_bank);
    m_copro_tgp_bank[0](0x0000, 0xffff).rw(copro_tgp_memory_r, ...);

**A selected view covers its whole range and hides what is under it.** With the
bank on, io 0x0000-0xffff IS the banked memory -- including 0x00-0x1f and the
math units. The microcode knows: `ldi #0x0, rf3` at 0x7C9 and 0x7D6 brackets the
two windowed reads at 0x7CF and 0x7D3. The fix is two words, `!win_en &&` on
`io_lo` and `io_mid`, so the window wins whenever it is selected.

`sel_radr`/`sel_rdat` are a Model 1 inheritance in any case -- model1_m.cpp's
copro RAM window. Model 2's io map has nothing at 0x00-0x1f but the view. They
are left reachable with the bank off rather than deleted: removing them is a
separate change with no consumer asking for it.

*Measured, 20 M instructions, BUFFERRAM=1:*

                                  before          after
    d after the 0x7CF read        00000000        00000030   (MAME: 00000030)
    d after 0x7D0 addd            ff800000        ff800030   (MAME: FF800030)
    dword 0x7FFC hits             74              340
    copro buffer-RAM writes       178             850
    MAILBOX dword 0x7FFC          ffffffff        00000000   <- what the game waits for
    CPU at the end                IP 00011674     IP 000012b0
    time in the 0x11000 page      5.0%            0.7%
    V-blanks                      271             286

**The display-list pointers are MAME's, all thirty in order:**

    1057 1180 1049 1172 103b 1164 102d 1156 101f 1148 1011 113a 1003 112c
    ff5 1110 fd9 10ee f98 e5a e5a c42 c42 a1d ac2 8f3 999 6ea 6fc 494

and the counts are 6,6,...,7,0x15,0xc,0xc,9,9 where they were 0xFFFFFFFF.
**The command stream matches MAME for all 200 words captured** -- no divergence
at any index, where before it broke at 110.

*Regression state.* Every TGP target passes, `test_mb86233_core` included and
now actually run. `mb86233_regs` is unchanged at its long-standing 46,966 on
register 0x21 (rf1) and remains owed.

*Method.* Five instruments in this session could not report what was asked of
them (R150, R151, R153, R154, and the core bench that was never wired up), and
R155 misattributed a fault because of the last one. **Writing the test that
should have existed is what located this: it exonerated the core in one run and
left only the wrapper.** The suite is stronger for it -- the assembled core is
executed now, and the untested `(e)` transfer forms have directed coverage.

---

**R158 - R157 IS RETRACTED. THE BOARD DID NOT FAIL ON THE WRITE PORT; R151's
STALL DEADLOCKED THE BOOT, AND THE UART SAID SO IN ONE LINE.**

*What R157 claimed.* That `Model2.rbf.r156` lost its tilemap because the shared
SDRAM write port's single unqualified acknowledge (R144) corrupted writes once
the coprocessor started using it in earnest. It named a real defect, and it was
the wrong answer to this question.

*What the board actually says.* Read over the UART, `/dev/ttyS1` at 115200, with
r156 loaded -- 3,769 consecutive records, every one identical:

    C 0000xxxx 00000000      tgp_pc = 0000, rd_total = 0, out_pushed = 0

**The coprocessor never left reset.** Not idling, not stalled mid-command --
never started. `m2_tgp` is instantiated `.rst_n(rst_n & ~halted)`, and `halted`
is 1 out of reset until the i960 writes `coproctl` with bit 31 falling. So the
CPU never reached that write.

*The loop, and it cannot break itself.*

    assign stall = fifo_rd && !fout_valid;     // R151, as built
    m2_tgp ... .rst_n(rst_n & ~halted)

A read of the FIFO port while the coprocessor is halted waits on `fout`. Only
the TGP can fill `fout`. Only the `coproctl` write can start the TGP. And the
stall is what stops the CPU reaching that write. **The one event that would
release the stall is the one event the stall prevents.**

It is not confined to cold boot: `if (wdata[31]) halted <= 1'b1` re-asserts on
every upload start, so any FIFO read during a microcode re-upload hangs the
machine the same way -- and leaves exactly the `tgp_pc = 0000` the capture
shows.

*Why the missing tilemap pointed the wrong way.* Losing the background looked
like corrupted memory, which is what R157 reasoned from. It was simpler than
that: the CPU hung before it drew anything. The absence of a tilemap was the
absence of a CPU, not the presence of a corrupt one.

*The fix.*

    assign stall = fifo_rd && !fout_valid && !halted && !uploading;

MAME has no equivalent state -- its TGP is a scheduled device that can always
run, so `on_fifo_unempty` can always arrive. Gating here restores that
PRECONDITION rather than departing from the behaviour: while the coprocessor is
halted or taking an upload it cannot answer, so the read completes instead of
hanging the machine. Once it is running, R151's synchronous protocol applies
unchanged.

*AND SIMULATION CANNOT CONFIRM IT, WHICH IS WORTH STATING PLAINLY.* The boot
harness produces byte-identical results with the gate and without it -- mailbox
clearing to zero, the 30 display-list pointers matching MAME, counts 6/7/0x15,
850 buffer writes, `IP 000012b0`. **The deadlock never occurs in simulation**,
so the harness reports success on a build that is dead on the board and cannot
tell the fix from the bug. That is a sixth instrument in this session unable to
report the thing asked of it, and the only reason the fault was found at all is
that the UART carries `tgp_pc`.

*What survives from R157.* R144 is still real and still unfixed: five requesters,
one broadcast `ldr_wr_ack`, and `m2_sdram_x2` passing `f_wr_addr`/`f_wr_din`
through combinationally so a higher-priority requester can move the address of a
write already in flight. Model 1's `b0c6785` is the worked precedent. It is a
genuine defect awaiting a consumer, not the cause of this failure, and it should
be fixed on its own evidence rather than on this.

*Method.* R157 was written from a board symptom plus a known-defect list, and
the known defect fit the symptom's shape. It took ten minutes of UART to falsify.
**A plausible mechanism that matches a symptom is a hypothesis, not a diagnosis;
the instrument that names the state is worth more than the one that fits the
story.**

---

**R159/R160/R161 - THE COPROCESSOR HANGS ON AN SDRAM READ THAT IS ISSUED AND
NEVER ANSWERED. R151 IS GOOD AND STAYS; R156 IS REVERTED. AND THE TILEMAP WAS
NEVER A RELIABLE SIGNAL.**

*Method note first, because it cost most of the day.* Four hardware builds were
judged from captures taken 15 s after `load_core`. The ROM set is 43.62 MB over
ioctl and had not finished; `rom_loaded` low holds `cpu_rst_n` low, so every one
of those captures read `cpu_ip = 0`, `tgp_pc = 0000`, nothing uploaded -- the
signature of a core held in reset, which was then reported three times as a
design failure. **R157 (write-port corruption) and R158's premise (a stall
deadlock at tgp_pc = 0000) both rest on those captures and are withdrawn.** The
conclusion "d27721c fails too" was the same artifact; re-measured after settling,
d27721c is identical to the known-good 108fed3d.

*AND THE SCREEN IS NOT THE INSTRUMENT IT LOOKS LIKE.* The tilemap lives in
on-chip RAM. When SDRAM stalls, the last frame stays on the display -- so
"tiles present, stuck at frame 1" and "no tiles" are not cleanly separable
states, and both were used as bisect evidence today. A frozen picture with tiles
is exactly what a stalled memory path looks like.

*What the bisect established, measured after proper settling:*

    d27721c (base)   TGP idles 004C-0057 / 00B5-00B9 forever, 3 reads,
                     191 idle zeros                      == 108fed3d
    R151 alone       TGP REACHES THE COMMAND HANDLER: 8 reads, 62 results,
                     then freezes at pc 047B             tiles intact
    R151 + R156      tilemap gone

So **R151 does what it was built to do** -- the coprocessor goes from never
starting to doing real work -- and **R156 is what costs the tilemap**, and is
reverted here. R156's target was real (the `sel_radr` theft of the io 0x10 read,
measured) but it gated `sel_math` in the same change, on an argument from MAME's
view semantics rather than a measurement. The two were never separated. It
should return narrowly, with a board result.

*THE ACTUAL FAULT, NAMED BY PORT-9 TELEMETRY.* The debug stream was repointed
from the walker to SDRAM port 9:

    C 0540047B 0008003E    retires 1344 frozen, pc 047B, 8 reads, 62 pushed
    H 000506BE 80105700    req_rises 5
                           tgp_dat_req_r = 1     <- request ASSERTED
                           tgp_dat_ack_r = 0     <- never acknowledged
                           is_buf = 0, we = 0    <- a READ of the copro data ROM
                           addr = 0x01057

pc 047B is `mov d, x0`, one instruction before `047C mov (x0+1)(e), $0x4a` --
the display-list count read. **The coprocessor issues that read to port 9 and
the controller never answers.** Not a request that was never made; one made and
abandoned.

*What is ruled out.*

  * **Reverting the SDRAM controller is not available.** `m2_sdram.sv` restored
    to its pre-d27721c form fails timing on all four seeds (-0.119 to -0.668),
    which independently confirms d27721c's own claim that the row-comparator
    rework exists to close timing. The rework is untested, not disproved.
  * **`S_MISS` is not a deadlock.** Its exit condition waits on
    `ras_cnt[dsp_bank]` and `rd_bank_cnt[dsp_bank]`, and both are decremented in
    the free-running block at lines 686/695, outside the state case. It always
    leaves.
  * **Every simulation path is blind to this.** The boot harness answers
    `tgp_dat_*` from C++, and `REAL_MEM` wires only ports 0 and 3. **Port 9 has
    never been exercised against the real controller anywhere except the
    board.** The three SDRAM benches pass and do not reach this pattern.

*THE INSTRUMENT THAT IS OWED, AND IT IS WORTH MORE THAN THE NEXT GUESS.* Wire
the TGP's ports 8 and 9 through `m2_sdram_x2` + `sdram_model` in the boot
harness, as `REAL_MEM` already does for the CPU and char ports. That reproduces
this at the desk with full visibility instead of at 25 minutes a hypothesis, and
it closes the gap that let a port-9 fault survive every test in the suite.

*Standing lesson, paid again and more expensively than before.* R149 said read
the code behind a number before using it. Today's version: **read the CONDITIONS
behind a measurement.** A capture during ROM download and a frozen frame buffer
are both instruments reporting faithfully about the wrong moment.

---

**R164 - THE BISECT MAP, RECORDED BEFORE IT IS NEEDED. WHERE ATTRACT STOPPED
CYCLING, WHAT MASKED EVERYTHING BEFORE IT, AND THE ONE BUILD THAT SETTLES
WHETHER ANYTHING ELSE BROKE.**

*Why this exists.* Observed: attract cycled before the coprocessor went
in, and **multiple additions landed between hardware tests**, so a regression in
that stretch would never have been attributed. That is the same failure that cost
this session a day with `d27721c`. The map is written down now, while it is
cheap, rather than reconstructed later under pressure.

*THE BOUNDARY, AND IT IS A ONE-LINE PARAMETER.* Traced through every commit that
touches the parameter:

    118cb77   .BUFFERRAM(1'b0), .BUFFERRAM_WRONLY(1'b0)    attract CYCLES
    a9ace86   .BUFFERRAM(1'b1), .BUFFERRAM_WRONLY(1'b0)    stuck at frame 1
    f716321   .BUFFERRAM(1'b1), .BUFFERRAM_WRONLY(1'b0)
    d27721c   .BUFFERRAM(1'b1), .BUFFERRAM_WRONLY(1'b0)

`m2_cpu_bridge.sv:67` -- `BUFFERRAM_WRONLY // writes land, reads still read 0`.
The mailbox is at 0x91FFF0, inside that region, and the poll is
`cmpibne 0,r3,0x1166c` -- **waiting for zero**. With BUFFERRAM off, or on with
WRONLY, the read returns zero unconditionally and the poll exits on its first
pass. The coprocessor is never waited for.

So attract cycling has always been the same shortcut, whether it came from the
region being unmapped (before `2ea8cc2`), mapped-but-disabled (`2ea8cc2` to
`118cb77`), or write-only. **`a9ace86` is where the machine first asked the real
question**, and it is a deliberate one-line change rather than a hidden fault.

*THE RISK THAT REMAINS, AND IT IS REAL.* The shortcut masks everything behind it.
Any of the twenty-two commits between the TGP being wired in and BUFFERRAM being
enabled could have broken something that only shows once the CPU actually waits.
None of them was tested on hardware alone.

    62402ce  Port the MB86234 TGP and its whole verification suite   <- BASE
      1 c3e146b Wire the TGP to the i960, and add the math tables
      2 64f35e6 Report the scroll registers the renderer actually used
      3 fcc59c5 SDRAM: the read tag was three bits wide and there are ten ports
      4 69cb105 Build: routability, and a lint that could not see the fault
      5 0e49c54 TGP: the FIFOs are in the register file on Model 2
      6 992eef2 Study: R105-R116, and R110 retracted
      7 110df30 TGP: instrument the drain loop, and correct the addressing
      8 26cbe69 The coprocessor is faithful; the i960 is pushing zeros
      9 97e3641 i960: the wrong value is r3, and r4 beside it is right
     10 3b4be66 The i960 reads those zeros out of the copro's empty output FIFO
     11 9e6d71c The coprocessor works: implement the function port at 0x00880000
     12 b57d5a5 MRA: a double hyphen inside an XML comment blocked the release
     13 41199bf Never stall the i960: the copro hold froze the machine
     14 93424f8 Size the copro queue to what fits: 128, not 512
     15 f94ca26 Register the TGP's SDRAM request path too
     16 7e71afb The coprocessor's halt was a read of 0x2e that never acknowledged
     17 f64fe2d Both coprocessor FIFOs into M10K
     18 a8d4969 Port the 3D back end from Model 1
     19 2ea8cc2 Map the shared buffer RAM, and leave it off
     20 57aacea The boot bench was accusing a correct core, and R121-R129
     21 3a211c1 Routability AUTOMATICALLY, not ALWAYS
     22 118cb77 The coprocessor was reading an invented memory map
     23 a9ace86 <- BUFFERRAM ENABLED. The real question begins here.
     24 f716321 The geometrizer walks its display list
     25 d27721c The command path is real, and R130-R149

Note 3, 13, 15 and 17 in particular: an SDRAM read-tag width fix, the i960 stall
removal, the TGP's SDRAM request path being registered, and both FIFOs moving to
M10K. Every one of them touches the path that R162 has just been found broken
on, and none was flashed alone.

*THE ONE BUILD THAT SETTLES IT.* Build the CURRENT tree with
`.BUFFERRAM_WRONLY(1'b1)` in `Model2.sv`'s bridge instantiation -- one
character -- which restores the shortcut on top of everything since.

  * **attract cycles** -> nothing in 1-22 is broken. The shortcut is the only
    difference, the mailbox path is the sole remaining work, and the bisect
    below is not needed.
  * **attract does not cycle** -> something in 1-22 regressed while the shortcut
    hid it. Bisect from `62402ce` with BUFFERRAM_WRONLY held at 1 throughout, so
    the mailbox is out of the picture and only the regression moves.

That is one build against roughly five for a blind binary search, and it
distinguishes two investigations that have nothing to do with each other.

*Method.* This is the third time in one session that a stack of untested commits
has had to be unpicked from the top. The rule already exists -- R147, one change
per build, flashed and confirmed before the next is added -- and the cost of
ignoring it is now measured in days rather than builds.

---

**R166 - PORT 9 HAS TWO OWNERS AND ONLY ONE OF THEM QUALIFIED ITS ACKNOWLEDGE.
THE COPROCESSOR WAS RETIRING ITS READS WITH THE GEOMETRIZER'S DATA.**

*The state on the board, with R151 + R162 + narrow R156 running.* The machine
gets further than it ever has -- sound plays, the attract sequence executes, the
coprocessor runs the whole command pipeline (`tgp_pc` 261 distinct across
0481-04B5, 0684-06E2, 06EA-0796; `cpu_ip` reaching 0x228940 and 0x22F100). Then
video falls to ~0.1 fps and it locks:

    cpu_ip   0001166C / 00011674   99% of samples   the mailbox poll
    tgp_pc   232 distinct, hottest 048F            the TGP is BUSY, not hung
    p9       req/ack both wrapping                 memory healthy
    flags    0, prog_words 07E8                    no stall, no trap

Not a deadlock. The coprocessor is grinding in the vertex/transform loop and
never reaches 0x4C4 to clear the mailbox, so the i960 waits for ever.

*The arithmetic that says it is not slowness.* MAME's TGP runs 4.6 M
instructions/second, so one Daytona frame is ~77,000 TGP instructions. Ours runs
4.9 M/s (R149) and was taking ~10 s a frame: **~640x the reference workload.**
Memory latency makes each instruction slower; it does not multiply the
instruction COUNT. Something was feeding the loops a count hundreds of times too
large -- the same failure as the 0xFFFFFFFF at 0x47C, one level on.

*THE FAULT.* `Model2.sv` muxes port 9 between two owners:

    p_req[9]  = tgp_dat_req_r | (geo_rd_req_r & ~tgp_dat_req_r);
    p_addr[9] = tgp_dat_req_r ? (copro address) : (geo address);

    geo_rd_ack_r    <= p_ack[9] & ~tgp_dat_req_r;   // QUALIFIED
    tgp_dat_ack_r   <= p_ack[9];                    // NOT QUALIFIED

**Every read the WALKER completed also acknowledged the COPROCESSOR**, which
retired its own pending read with the walker's data. Garbage into `$0x69` (the
display-list base) and `$0x4a` (its count), and a garbage count is billions of
iterations.

It can only bite while both owners are active. The walker has run since
`f716321`; the coprocessor only began issuing real reads with R151 and R162.
That is why this surfaced today and not in the three days before it.

*THE FIX, AND IT COMES FROM THE WORKING CORE.* The standing instruction --
check Model 1, it has the same coprocessor and it works -- is what found it.
`m1_integrated.sv` shares one memory port between the TGP's table and data
reads and qualifies BOTH:

    assign t_tbl_ack = t_mem_ack &&  t_tbl_req;
    assign t_dat_ack = t_mem_ack && !t_tbl_req && t_dat_req;

and adds a dead cycle so the address cannot move under a transaction already in
flight:

    wire t_owner_change = (t_tbl_req != t_prev_tbl);
    wire t_mem_req = (t_tbl_req || t_dat_req) && !t_owner_change;

Ours becomes `tgp_dat_ack_r <= p_ack[9] & tgp_dat_req_r;`. **The dead cycle is
still owed** -- `p_addr[9]` switches combinationally the moment
`tgp_dat_req_r` asserts, so a walker transaction in flight can still have its
address moved.

*THE PATTERN, NOW THREE TIMES IN ONE DAY.* R162: a shared port whose acknowledge
was a one-shot, so one missed pulse killed it for ever. R144: a shared WRITE
port with five requesters and one broadcast acknowledge. R166: a shared read
port with two owners and one unqualified acknowledge. **Every handshake in this
core that serves more than one master has been wrong in the same way**, and none
of them could be caught by a bench, because no bench drives two owners of the
same port at once.

*What is owed as a result.* A directed multi-owner test for every shared port --
two requesters, overlapping requests, checking that each retires on its own
acknowledge with its own data. That is the bench that would have caught all
three, and it does not exist.

---

**R170 - R124 IS TOO BROAD. MODEL 1'S GEOMETRY ARITHMETIC DOES TRANSFER; ITS
DISPLAY-LIST GRAMMAR DOES NOT. THE TGP AND THE GEOMETRIZER ARE TWO DIFFERENT
BLOCKS AND R124 TREATED THEM AS ONE.**

*What R124 said*, recorded in THIRD_PARTY.md: "Model 1's geometry does NOT
transfer: `m1_geometry` and its nine `m1_geo_*` submodules are fixed-function
RTL, while Model 2's geometry is a MICROCODED engine running a program the game
uploads."

*Why that is half right.* **Model 2 has both blocks, not one.**

  * The **TGP** (MB86234) is the microcoded processor -- it runs the 2,024-word
    program the i960 uploads, and it is what R151/R162/R167 got working on
    hardware. R124 is describing this correctly.
  * The **geometrizer** is separate: the display list at 0x00800000 that
    `geo_parse()` walks, with FIXED-FUNCTION opcodes -- `matrix_write` 0x0b,
    `focal_distance` 0x09, `object_data` 0x01, `light` 0x0a. `m2_geo.sv` has
    walked exactly that since `f716321`.

The geometrizer is fixed-function and its arithmetic is `transform_point`,
`transform_vector`, `apply_focus`, dot products and a projection -- the same
operations Model 1's stages implement, on the same 3x4 matrix, loaded by the
same opcode number (0x0b on both).

*What actually transfers, and what does not.*

    transfers      m1_fp_pool     the shared multiplier/adder/divider
                   m1_geo_xform   transform_point / transform_vector
                   m1_geo_project, m1_geo_clip, m1_geo_norm, m1_geo_det
                   -- generic 3D arithmetic, not board-specific

    does NOT       m1_geo_walk    Model 1's display-list grammar. Ours is
                                  m2_geo.sv and stays ours.

*The evidence.* `m1_geo_xform` ported unmodified but for the rename passes
7,813 checks against host float with zero failures, including its own directed
case proving the summation must be left to right. It streams at **19.0 cycles a
transform**, 57.1 per three-transform record.

*AND IT CORRECTED A DESIGN MISTAKE MADE HERE FIRST.* A hand-rolled
`m2_geo_xform` was written before the reference was consulted: private `fp_mul`
and `fp_add`, and a sequencer that waited for each result before issuing the
next -- one stage of a four-stage pipeline busy and three idle, about 100 cycles
for a single point. Model 1's own header records building exactly that and
replacing it:

    "The stages were first built with private units ... which is three of each.
     ... 44 mul 43 add against a budget of 68 cycles a record. fp_mul and fp_add
     are four-stage pipelines that retire one result per cycle, so ONE of each
     runs at 65% and 63%. Three of each buys nothing at all; it was convenience,
     not necessity, and it costs two multipliers and two adders."

*Method.* This is the fourth time in two days that the Model 1 core held the
answer and it was reached for late -- the per-owner acknowledge (R167), the
stall semantics (R151), the shared write port (R144), and now the arithmetic
pipeline. **The rule is not "check Model 1 when stuck"; it is check Model 1
FIRST, because it is the same author solving the same problem one board
earlier.** R124's blanket ruling is what allowed this one to be skipped, which
is the cost of a conclusion recorded more broadly than its evidence.

---

**R171 - THE POLYGON STREAM'S GRAMMAR, READ OUT OF THE REFERENCE BEFORE
BUILDING THE SEQUENCER. IT IS NOT A TRIANGLE STRIP; THE LINK IS A FIELD IN THE
ATTRIBUTE WORD.**

Written down because it is the part of the geometry engine that fails silently:
a wrong link produces geometry that is plausible everywhere and correct nowhere,
and the only oracle this block has is a framebuffer comparison (study 2.1).

*THE COMMAND BUFFER'S LAYOUT.* `model2_3d_push` treats the FIRST push as the
command and does not store it, so `geo_object_data`'s three pushes land as:

    push opcode>>23   -> cur_command = 1 (Polygon Data), NOT buffered
    push tpa          -> buffer[0]
    push tha          -> buffer[1]

then `geo_parse_np_ns` fills:

    p0.x,y,z          -> buffer[2..4]     P0(n-1)
    p1.x,y,z          -> buffer[5..7]     P1(n-1)
    attr              -> buffer[8]
    luma<<15          -> buffer[9]
    distance>>8       -> buffer[10]
    point.x,y,z       -> buffer[11..13]   P0(n)
    point.x,y,z       -> buffer[14..16]   P1(n), quads only

and `model2_3d_process_polygon` reads them as

    v[0] = [5..7]   v[1] = [2..4]   v[2] = [11..13]   v[3] = [14..16]

Note v[0] and v[1] are the PREVIOUS pair and are swapped relative to buffer
order. A triangle sets `[14..16] = [11..13]` -- "the rope of P1(n) is achieved
by P0(n-1)".

*AND THE CARRY IS A LINK TYPE, NOT A FIXED SLIDE.* After each polygon
`command_index` returns to 8, so the next attribute overwrites [8] and the next
points refill [11..16]. What [2..7] become is chosen by `(attr >> 8) & 3`:

    0, 2   buffer[2..7] = buffer[11..16]     reuse P0(n) and P1(n)
    1      buffer[5..7] = buffer[11..13]     reuse P0(n-1) and P0(n)
    3      buffer[2..4] = buffer[14..16]     reuse P1(n-1) and P1(n)

So the stream is a general strip/fan hybrid: type 0/2 advances both edges like a
quad strip, type 1 pins P0(n-1) and fans, type 3 pins P1(n-1) and fans the other
way. A sequencer that assumed a plain strip would be right only for type 0 and 2.

*WHAT ENDS AN OBJECT.* `(attr & 3) == 0` terminates -- `cur_command` is cleared
and the parser breaks out of its loop. `attr & 1` selects quad over triangle,
and a triangle still CONSUMES three words for the point it does not use
(`input += 3`), which is the kind of detail that desynchronises a reader that
skips them instead.

*WHAT THIS MEANS FOR A FLAT FIRST CUT.* Nothing above depends on lighting or
texture. The normal is read and transformed only to compute `dotl`/`dotp` for
luminance and the LOD, and `luma`/`distance` occupy buffer[9] and [10] which
`process_polygon` reads for shading alone. A flat build must still READ and STEP
OVER the normal's three words -- the stream position depends on it -- but need
not transform it. The ported rasterizer takes a single 24-bit colour and has no
texture input at all, so flat is the natural first target rather than a
simplification that has to be undone later.

*Provenance.* `model2_v.cpp`, `model2_3d_push` (the buffer discipline),
`model2_3d_process_polygon` (the vertex mapping and the link switch), and
`geo_parse_np_ns` (the read order). The other three parsers -- np_s, nn_ns,
nn_s -- differ in whether a normal is present and whether specular is computed,
selected by `geo->mode & 3`, and change the READ ORDER. Only np_ns is
transcribed here.

---

**R172 - WITHDRAWN. IT SAID MODEL 2 HAS NO PERSPECTIVE DIVIDE. IT HAS ONE, IN
THE RASTERIZER. SEE R174.**

The entry as written is preserved below because the reasoning in it is the
reasoning that produced a module which had to be deleted, and that is worth
more than a tidy record. What it got right: `geo_parse` really does end at
`apply_focus`, and a vertex really does leave the *geometrizer* as two
multiplies past the transform. What it got wrong: it concluded from that that a
vertex leaves the geometrizer **in pixels**. It does not -- it leaves in view
space, and `model2_3d_project` divides by `pz` one block downstream. R172 read
one function's end and called it the end of the pipeline.

--- the original entry follows ---

**R172 - MODEL 2 HAS NO PERSPECTIVE DIVIDE IN ITS GEOMETRY. `apply_focus` IS THE
PROJECTION, AND IT IS TWO MULTIPLIES. ONE OF THE PORTED STAGES THEREFORE DOES
NOT APPLY.**

Found while wiring the ported stages together, before anything was connected.

*The reference path, end to end.* `geo_parse_np_ns` does exactly this per point:

    transform_point(&point, geo->matrix);     9 mul, 9 add
    apply_focus(geo, &point);                 x *= focus.x;  y *= focus.y
    model2_3d_push(raster, f2u(point.x) >> 8);

and `model2_3d_process_polygon` restores them with `u2f(buffer[n] << 8)` and
clips. **There is no division by z at any point** -- checked across
`process_polygon` and the render path. The transformed, focused x and y ARE the
screen coordinates, as floats; the matrix carries whatever perspective the game
wants.

*What that means for the port.* `m2_geo_project` is Model 1's projection: a
perspective divide by z with `xc/yc/zoomx/zoomy/viewx/viewy`. It is correctly
ported and verified at 20,037 checks, and **it does not implement Model 2's
projection.** It is kept -- it costs nothing unbuilt, and the four other stages
around it do transfer -- but it must not be dropped into this pipeline on the
assumption that "project" means the same thing on both boards. That assumption
is exactly the shape of R124's error and of the sequencer's one-place shift: a
name that matches while the semantics do not.

`m2_geo_clip` takes both float and screen coordinates and drives a projector
through its `pj_*` port to re-project vertices it creates while clipping. On
Model 2 that re-projection is the focus multiply, not a divide, so the clipper
either gets a Model 2-shaped projector on that port or is adapted. Deciding
which is the next design question, and it is a real one rather than plumbing.

*What the sequencer still owes.* `m2_geo_engine` currently applies
`transform_point` only -- `m2_geo_xform` with `in_translate` set. **The focus
multiply is not applied anywhere yet**, so its vertices are camera space, not
screen space. Two multiplies per point, on the shared pool, between the
transform and the clipper.

*The simplification that follows.* Model 2's geometry is cheaper than Model 1's
by a divide per vertex. `fp_div` is 29 cycles and does not pipeline -- Model 1's
own pool header calls two reciprocals a record "58 of the 68" cycle budget. Not
needing it at all is the single largest arithmetic saving available here, and it
was found by reading the reference rather than by assuming the ported stage fit.

---

**R173 - THE WALK AND THE GEOMETRY ENGINE SHARE ONE SDRAM PORT BY TAKING TURNS,
NOT BY ARBITRATING. THE INTERLOCK IS IN THE WALKER.**

Established while wiring `m2_geometry` into the top level.

*The problem.* The display-list walk reads bufferram; the geometry engine reads
the polygon ROM. Both are dword reads, both want SDRAM, and the core has one
port free. R167 is exactly what happens when two independent owners are put on
one port -- it cost four days and it did not announce itself, it made the
coprocessor look broken.

*Why this case is different, and why that is not luck.* `geo_object_data` in the
reference does not return until `geo_parse` has walked every polygon of the
object. The walk is *already* serialised behind the geometry in MAME; making the
RTL do the same is reproducing the reference, not conceding to a resource
limit. `m2_geo` gained an `eng_busy` input and a `W_OBJW` state: when an
`object_data`'s four operands are in, the walk stops until the engine reports
that object drawn.

*The bug the interlock nearly had.* `busy` rises the cycle **after** `start`, so
"wait until `!eng_busy`" falls straight through on the cycle `obj_valid` was
raised, and the walk races back onto the port while the engine is still
starting. `W_OBJW` watches `eng_busy` go high first, then come back down.

*And `busy` must mean the whole pipeline.* The engine finishes reading an object
long before its last polygon has been through four 29-cycle reciprocals and the
clipper. `m2_geometry.busy` is therefore `eng_busy || quad projector not idle ||
clipper not idle` -- `m2_geo_clip`'s `in_ready` is literally `kst == K_IDLE`, so
that third term is exact. Two things ride on this being honest: the interlock
above, and `q_end`, which releases the rasterizer's sort and would otherwise
throw away whatever was still in flight at the end of a frame.

*What is still not proved.* Port 4 now has two drivers whose non-overlap rests
on this interlock rather than on structure. `dbg_p4_clash` counts cycles where
both request anyway. If the interlock is ever wrong, that counter is non-zero --
rather than the picture being subtly incorrect, which is the failure this
project has been worst at seeing.

*The bench had the same blind spot as every other one here.* `tb_m2_geo`
deadlocked at the first `object_data` the moment the interlock went in, because
it tied `eng_busy` low. That is the right failure -- it proves the wait actually
blocks -- but it is also the third time a bench has been written with one
requester where the design has two. Still outstanding: R144's shared write port,
five requesters and one broadcast acknowledge.

---

**R174 - MODEL 2 DOES HAVE A PERSPECTIVE DIVIDE. IT IS IN THE RASTERIZER, AND
THE CLIP IS A VIEW-SPACE FRUSTUM. THE GEOMETRY SHAPE IS MODEL 1'S SHAPE AFTER
ALL. THIS REPLACES R172.**

Established by `sim/video/tb_m2_geometry.cpp` hanging, then by reading
`model2_v.cpp` past the end of `geo_parse`.

*What the reference actually says.* `model2_3d_project` (model2_v.cpp:656):

    v.x = crtc_xoffset + center[0] + (v.x / v.pz)
    v.y = ((384 - center[1]) + crtc_yoffset) - (v.y / v.pz)

and before it, `model2_3d_process_polygon` clips against four planes built from
the viewport and the centre (model2_v.cpp:882), tested as
`dot(v, normal) >= 0` with the normals carrying a `pz` component -- a frustum
clip in **view** space, not a box test on pixels.

*So the pipeline is:* transform -> `apply_focus` -> frustum clip in view space
-> divide by z -> screen. Which is Model 1's pipeline exactly. `apply_focus`
plays the part Model 1 gives to zoom, one stage earlier; that is the whole
difference.

*And the ported projector fits without modification.* `m2_geo_project`'s
contract is

    s.x = xc + (x/z * zoomx + viewx)      s.y = yc - (y/z * zoomy + viewy)

which is Model 2's projection with `zoom = 1.0`, `view = 0`, `xc` absorbing
`crtc_xoffset + center[0]` and `yc` absorbing `(384 - center[1]) +
crtc_yoffset`. The four `a_*` clip slopes map onto MAME's four plane normals
one for one under different names -- Model 1's `a_bottom` is MAME's *top* plane
and vice versa, but the four half-spaces are identical. For a 496x384 screen
centred at (248,192): `a_left = -248`, `a_right = +248`, `a_bottom = +192`,
`a_top = -192`.

*What R172 cost.* One module, `m2_geo_screen`, which answered the clipper's
projector port with a float-to-int conversion on the belief that the vertices
were already pixels. Deleted. Nothing else: the wrong belief never reached
hardware, because the integration bench was written first.

*How it was caught, and this is the point.* Every stage passed its own bench --
xform 7,813, project 20,037, clip 2,003, the engine's grammar 15. The error was
in the **join**, and it appeared as the clipper accepting a polygon and then
neither emitting nor dropping it: `clip in=1 out=0 dropped=0`, a hang. Fed pixel
coordinates, a frustum test `p.x < p.z * a_left` compares a pixel column
against a slope times a depth and the polygon is neither in nor out of anything
meaningful. On hardware that is a black screen -- indistinguishable from the
geometry never running at all, which is the state this core spent four days in
for a different reason.

*A second, smaller lesson from the same bench.* Its first working version broke
its run loop on the engine's `busy` and reported "no quads" for a pipeline that
had simply not finished. A bench measuring its own impatience reads exactly like
a design that does not work. It now runs a fixed budget.

*The saving R172 claimed is gone.* There is no divide-free geometry here; the
reciprocal is 29 cycles and does not pipeline, four vertices per polygon is
about 120 cycles, and that puts roughly 2,700 polygons in a 60 Hz frame before
the projector is the limit. That is the number to watch when real display lists
arrive.

---

**R175 - THE DISPLAY-LIST WALK IS CORRECT AND MATCHES THE REFERENCE EXACTLY.
THE LIST IS NOT BEING PRODUCED. THAT IS THE BLOCKER, AND IT IS UPSTREAM OF
EVERYTHING BUILT SO FAR.**

Established in simulation, by putting `m2_geo` inside the boot bench so the real
i960 running the real ROMs drives the real walker.

*Why the bench was extended rather than the board questioned again.* On hardware
the walk reported `frames=1, objs=0, unknown=0` and then froze, and every guess
at why cost a 40-minute build. Three such guesses had already been spent. The
boot bench already ran the game; it simply had no geometrizer in it.

*What it reported on the first run:*

    frames=0  ops=32767  objs=0  unknown=00  state=W_FETCH
    geo rp=00000032  wp=0000403c
    polygon_data: 0 commands
    scanning buffer RAM for geo_end opcodes:  NONE FOUND

*And the list at the read pointer is not a list:*

    [  12] 00060006  op=00      [  15] 0000002d  op=00
    [  13] 00070007  op=00      [  16] 0000002d  op=00

Ascending small integers -- an index table -- every one of which decodes as
opcode 0x00, `geo_nop`. The walk retires nops until it hits its bound.

*THE BOUND IS MAME'S OWN, AND SO IS EVERYTHING ELSE.* `geo_parse`:

    u32 address = (m_geo_read_start_address & 0x1ffff)/4;
    while (end_code == false && (input - m_bufferram) < 0x20000/4
                             && op_count++ < 0x8000)

`op_count < 0x8000` is 32768, and the walk stopped at **32,767**. The register is
written at `0x3008` as `data & 0xfffff` (model2.cpp:891) and ours decodes
`0x803008`; MAME indexes `(addr & 0x1ffff)/4` = dword 12 and ours computes
`geo_rp[16:2]` = dword 12. Every number agrees. **Given this data, MAME does
exactly what our walk does.**

*So the conclusion inverts.* The walk, the operand capture, `geo_polygon_data`,
the engine's grammar, the transform, the projection and the clipper are all
verified -- 88,196 checks -- and none of them is the problem. **Nothing is
writing a display list.** There is no `geo_end` anywhere in the 128 KB of buffer
RAM, so there is no list to walk, and every downstream count is zero for the
only reason that can make them all zero at once.

*CORRECTION, WITHIN THE HOUR: THE COPROCESSOR DOES NOT WRITE THE LIST. THE i960
DOES.* The paragraph originally here said the TGP builds the display list and
named it as the next suspect. `push_geo_data` (model2.cpp:777) says otherwise:

    m_bufferram[m_geo_write_start_address/4] = data;
    m_geo_write_start_address += 4;

and its only caller is `geo_prg_w`, the i960's own function port at 0x800000 --
which is precisely the front door this core already implements. The i960 writes
buffer RAM directly; the coprocessor never touches it in the reference. Recorded
rather than deleted because it was committed before it was checked, which is the
habit this study exists to discourage.

*Where that actually leaves the question.* The i960 IS pushing -- 10,272 words
of it -- and what it pushes is a table, not a list. So the game has not yet
decided to build geometry. It is the i960's own code that makes that decision,
and on Model 2 that decision is downstream of the TGP: the game hands the
coprocessor work and pushes a display list built from what comes back. A
coprocessor that completes its mailbox handshake but returns wrong numbers gives
exactly this -- a game that runs, cycles attract, and never emits geometry.

So the coprocessor is still the thing to examine, but for a different and
weaker reason than first written: not because it writes the list, but because
the i960 will not write one until the TGP's answers are right. R167 established
that it runs. Nothing yet establishes that it is correct.

*What this cost, and the rule that came out of it.* Four builds were spent
looking for a fault in the consumer. **MAME is a reference; it is not the
oracle.** It is a C program with host floats, unbounded arrays and no
handshakes, and three separate hardware faults tonight -- the NaN that wedged
the walk, the pointer that would have run off polygon RAM, the stage that
stopped answering -- are all things MAME cannot exhibit because MAME is not a
pipeline. The Model 1 core in `tools/model1-ref/` is a working coprocessor,
geometry engine, walker, texture unit and rasterizer on this same device, and
it is the oracle. `CLAUDE.md` now says so.

---

**R176 - THE WORST SETUP PATH IN THE DESIGN WAS THE ARBITER'S ADDRESS MUX, AND
MODEL 1 HAD ALREADY WRITTEN DOWN THE FIX. SEED SWEEPING WAS THE WRONG LEVER AND
COST FIVE SWEEPS TO LEARN.**

All six worst setup paths reported by `report_timing` had both endpoints inside
`m2_sdram`:

    From  emu:emu|m2_sdram:u_sdram|Mux5~0_OTERM7279
    To    emu:emu|m2_sdram:u_sdram|Mux3~0_OTERM7275
    Slack -1.353 (VIOLATED)

*What they are.* The arbitration cycle computed the round-robin priority encoder
AND THEN read a ten-way 25-bit address mux with its result, into `xfer_addr`, in
one clock:

    grant <= rr_grant;
    sel    = addr_p[rr_grant];      // ten-way, 25-bit, combinational
    xfer_addr <= sel;

*The oracle had already met it.* `tools/model1-ref/docs/findings.md`, "Worst
setup slack is -0.019 ns, and it is the SDRAM address path": both endpoints
inside `m1_sdram`, nine combinational levels, 73% interconnect. Its conclusion,
which this project needed and did not read:

    "The deterministic fix is the 9 combinational levels feeding sd_a -- the
     state machine computing its address mux in the same cycle it drives the
     pins. Registering the address select one cycle earlier removes most of
     them."

and about the lever this project was pulling instead:

    "So the area lever is not the remedy it looks like ... It is a lottery
     ticket, not a fix."

*What that cost.* Five seed sweeps and roughly twenty-five fits, chasing a 0.84
ns seed-to-seed spread that was noise sitting on a structural path. Every one of
those builds was a lottery ticket.

*The fix.* `S_SEL` performs the mux in a cycle of its own; the arbitration cycle
settles only the grant INDEX, and `S_DISPATCH` still sees a settled `xfer_addr`
for its row comparator. Address, data and byte enables all move with the grant.

*Result, build 16, first fully setup-clean build since the geometry work began:*

    pll_hdmi   +0.217   was -0.928
    SDRAM      +0.276   was -0.928, and -1.353 on build 14
    worst hold -0.150   on clk_sys, still outstanding

**Both clocks closed, and the HDMI path came with it** -- That was predicted,
and it is the tell that these were one congestion problem rather than two.

*The price, measured rather than waved through:* one cycle per transaction,
0.079689 -> 0.070201 transactions per cycle, **-11.9%**. That figure is the
controller's CEILING under a saturated fuzz bench, not the demand: the core runs
attract at ~95% of hardware speed and what throttles it is the i960's poll loop.
Trading a few percent of an unapproached ceiling for a timing violation on the
clock every other block depends on is the right way round, and this study had it
backwards -- 2.7% was being quoted as a reason not to fix -1.353 ns.

*Standing note.* R108's warning still holds and now has a second instance:
anything combinational from the port array to `cmd` or to `xfer_addr` becomes
the critical path, and every added port widens it.

---

**R177 - THE GEOMETRIZER'S OPCODE IS IN THE WRITE ADDRESS, NOT IN THE DATA. THIS
IS WHY NO 3D HAS EVER DRAWN, AND IT WAS FOUND BY RUNNING MAME RATHER THAN
READING IT.**

*How it was found.* MAME 0.289 -- the same version as `third_party/mame` -- run
on the same ROMs with a Lua script dumping `bufferram` (mapped at 0x900000) at a
chosen frame, diffed word for word against ours at the same point:

    dword   MAME        ours
      0     04000000    00000000     op 08  zsort_mode
      1     40800000    40800000     ok
      2     01800000    00000000     op 03  window_data
     3-8    (six window operands)    all identical
      9     02000000    00000000     op 04  texture_data
     10     008050f8    008050f8     ok
     11     00000118    00000000

**Every operand matched. Every command word was zero.**

*The rule, from `geo_w` (model2.cpp):*

    if (data & 0x80000000) {
        r = (data & 0x800fffff) | (((address >> 4) & 0x3f) << 23);
        push_geo_data(r);
    } else if ((address & 0xf) == 0) {
        r = (data & 0x000fffff) | (((address >> 4) & 0x3f) << 23);
        if (((address >> 4) & 0xc0) && function == 1)
            r |= ((address >> 10) & 3) << 29;      // eye mode, Sega Rally
        push_geo_data(r);
    }
    // bit31 clear and the address not 16-byte aligned: NOTHING is pushed

The i960 selects a command by WHERE it writes -- `0x800000 + (function << 4)` --
and the geometrizer folds that function number into bits 28:23, which is exactly
the field the walk decodes as the opcode. This core pushed `cpu_io_wdata`
verbatim, so operands landed perfectly and every command word arrived as its
data half with no opcode: zero.

`0x804000-0x807fff` is `geo_prg_w` and IS a verbatim push. That half was always
correct, which is why the operands were flawless and made the fault look like
dropped writes rather than missing opcodes.

*What it explains, all of it at once.* Matrix writes read zero because no
`matrix_write` survived the front door; focal distance likewise. The "252
object_data commands" the board reported were opcode-0x01 bit patterns occurring
by chance in operand data and unwritten memory -- which is why their `oba` and
`obc` were both `0000ffff`, the same word. Every vertex collapsed to the
projection centre because the matrix was never written, and every quad was
degenerate in consequence.

*Result in simulation, at 30M instructions:*

    matrix writes=399   focal writes=32   objs=553
    last object: oba=008a6daf obc=00001388  -> polygon ROM
    ENGINE objects=552  polys=3038
    QUADS OUT=2   quad 0: (458,171) (454,173) (462,173) (462,173)

and the buffer-RAM opcode histogram now sits beside MAME's: 1,935 non-zero words
against 1,936, with 07:4, 08:1, 09:2, 0a:2 and 0f:5 matching to the count.

*THE METHOD IS THE FINDING.* Every previous attempt compared our CODE against
MAME's CODE and found them to agree -- because they DO agree about what `geo_w`
computes. What disagreed was what reached the front door. Reading the reference
cannot show that; only running it and diffing the data can. `CLAUDE.md` already
says Model 1 is the oracle and MAME a reference; the amendment this adds is that
a reference is worth far more RUN than READ.

---

**R178 - SIMULATION AND HARDWARE DISAGREE ON THE SAME CORE, AND THAT IS THE NEXT
THING TO RESOLVE.**

With R177 fixed and the identical bitstream md5-verified on the card:

    simulation, 30M insn:  mtx=399  foc=32  objs=553  polys=3038  quads out
    board, 60s, 382 UART records:  mtx=0  foc=2  objs=0  clip 0 in 0 out

The fix demonstrably reached the board -- focal writes went 0 to 2 and the 252
phantom object decodes vanished, both of which are R177's signature -- and then
nothing further. The board is not merely behind: it is static.

Three causes remain and nothing on the wire separated them, so the push port's
own counters go on the UART:

    pushes climbing, mtx zero -> the decode or the walk is wrong
    pushes flat               -> the i960 is not writing, and the fault is
                                 upstream in the game's own progress
    dropped climbing          -> the queue is too small and the list is being
                                 corrupted by loss

The third is not hypothetical. `m2_geo`'s header records "overrun: 3205 dropped,
counted, never stalled": the front door drops rather than backpressuring the
i960, and R177 has just multiplied the traffic it must carry -- 3,038 polygons
per frame in simulation against a queue sized when the list was nine dwords.

---

**R179 - THE WALK READ BUFFER RAM WHILE THE FRONT DOOR WAS STILL WRITING IT. THE
POINTERS WERE IDENTICAL TO SIMULATION AND THE CONTENT WAS NOT.**

*The measurement that isolated it.* With R177 fixed, the board and the boot bench
report the SAME pointers:

    board:  rp=0000  wp=0024  frames=2821  matrix pushes=110  decoded=0
    bench:  rp=0000  wp=0024                                  decoded=399

Same RTL, same addresses, opposite results. So this was never addressing -- it is
what occupies those dwords at the instant the walk reads them.

*The race.* `frame_start` launched the walk immediately. The push DMA writes
buffer RAM through the SHARED SDRAM WRITE PORT, which has real latency and a
queue in front of it, so at vblank there are words the i960 has written that have
not reached memory. The walk reads the previous frame's contents instead, and a
stale `geo_end` in dword 0 terminates it in one opcode. That is exactly the
signature: a frame counter climbing every vblank with nothing decoded, while 110
matrix writes and 3,000 `object_data` commands demonstrably pass the front door.

*The fix.* A vblank is REMEMBERED; the walk begins when the push queue is empty
and the write DMA idle. The timeout is not optional -- a game pushing
continuously would otherwise never walk at all, and dropping one frame is far
better than dropping every frame.

*THE PATTERN, WHICH IS NOW THE DOMINANT FAILURE MODE.* This is the third fault in
one day whose entire existence is the gap between a bench that answers instantly
and hardware that does not:

    - the edge-latched SDRAM port (m2_sdram.sv:377): benches acknowledge whenever
      req is high, so no bench can see a held request
    - the multi-cycle acknowledge: read as a level, one word is consumed twice
    - this: the queue drains in the same cycle it is filled in simulation, so the
      read-while-writing window does not exist there

88,000 checks pass against a memory model with no latency, no edge semantics and
no acknowledge width. `docs/mister-integration.md` already says a test proves
only what it is asked; the amendment is that **every bench here asks the same
wrong question about memory**, and that is a structural gap rather than three
separate oversights.

---

**R180 - TEXTURE IS FORCED INTO SDRAM BY SIZE AND FORCED TO HAVE A CACHE BY
BANDWIDTH. THE M10K TO PAY FOR THAT CACHE COMES FROM THE SOUND BOARD.**

*The sizes, from model2.cpp's memory map:*

    textureram0   0x12000000-0x121fffff    2 MB
    textureram1   0x12400000-0x125fffff    2 MB
    texture_ram   u16[0x10000]           128 KB   headers, read per POLYGON

4 MB is 3,200 M10K blocks and this device has 553, so the sheets follow the
polygon ROM and polygon RAM into SDRAM. That is arithmetic, not a design choice.
There is 15.6 MB free between GAME_PRAM1 and ST_BASE, so space is not the
constraint.

*The bandwidth, which is:*

    per-pixel texel demand, 496x384x60Hz      11.4 M fetches/s
    SDRAM ceiling, measured (0.0702 xact/cyc)  7.0 M/s

**SDRAM alone cannot serve texture.** A texel cache is not an optimisation, it is
what makes texture possible at all. Texture access has strong locality -- adjacent
pixels share texels -- so a cache should bring 11.4 M/s well under the ceiling,
but it has to exist and it has to live in M10K.

*Where the blocks come from.* M10K is 553/553. The Fitter RAM Summary, by module:

    m2_char_cache   134   proven needed: 64 KB caused tile and glyph overruns
    m2_raster3d     114   quad_store ~66 + band buffers 48
    m2_sound_board   78   of which ram_lo 32 + ram_hi 32 = 64 in the 68000's RAM
    m2_tdp_ram tram  64   tile RAM, read per pixel, must stay
    m2_video lanes   32   5.3x waste, MLAB declined by Quartus
    m2_backup        16   save RAM, rarely touched

*The plan, ranked by blocks per unit of risk:*

    68000 work RAM -> SDRAM      64 blocks   moderate: needs a stall path
    quad_store 2048 -> 1024      ~33         low: MAME's limit is 32,768 and the
                                             board emits ~216/frame; dbg_dropped
                                             catches an underrun
    band buffers NBUF 3 -> 2     ~16         low
    m2_backup -> SDRAM            16         low
                                 ----
                                 ~129 blocks, 23% of the device

129 blocks is 1.3 Mbit of cache, which is the right order for closing an 11.4
against 7.0 M/s gap.

*The dependency, and it is not optional.* **R144 is still live**: the loader's
write port has five requesters sharing one broadcast acknowledge. Every move
above adds another writer to that port. R144 is fixed first, or each move
inherits a known-broken arbiter -- and R167 is the record of what one shared port
with two owners costs when it is wrong.

*Why the sound board is the right first move.* The 68000 runs at ~11 MHz, so
SDRAM latency at 100 MHz costs it one or two of its own cycles and a stall
absorbs it. The band buffers and tile RAM are read every pixel during scanout and
cannot tolerate that at any price.

---

**R181 - R179'S RACE FIX DID NOT RESTORE DECODING, AND THE REASON IS THAT THE
GAME IS NOT SENDING GEOMETRY. THE PIPELINE IS WAITING FOR INPUT THAT NEVER
COMES.**

*The measurement, with the drain gate in place:*

    mtx_push = 110   STATIC, not climbing
    frames   = 2812  climbing normally
    wp       = 0024  every frame
    decoded  = 0

R179 is still correct engineering -- reading a buffer while a DMA writes it is a
race whatever else is true -- but it is **not** what was stopping the walk, and
that hypothesis is recorded as unconfirmed rather than quietly folded into the
fix that followed it.

*What the numbers actually say.* `mtx_push` is FROZEN at 110. Those matrix writes
happened once, during initialisation, and have never recurred. `wp` reaches 0x24
every frame and no further: the game emits a **nine-dword list per frame**,
forever, and the contents are known from the last-push capture -- `window_data`,
an operand or two, `geo_end`.

So the board is not failing to decode geometry. **The game is not producing
any.** Every stage measured is healthy: pushes arrive, the reconstructed words
are byte-correct against MAME, the pointers match simulation, the queue does not
overflow, and the walk completes 2,812 frames. The geometry pipeline is finished
and idle for want of input.

*Which returns this to R178 and narrows it.* The boot bench reaches a state where
the same game emits 399 matrix writes, 553 objects and 3,038 polygons. The board
does not. Same core, same ROMs, same MRA, md5-verified. The divergence is in the
i960's OWN EXECUTION -- what the game decides to do -- and not in anything
downstream of the front door.

*The next step, and it is a measurement rather than a hypothesis.* The boot bench
already traces the CPU. Run it to the instruction at which geometry first
appears, record the PC region doing the emitting, and compare that against the
board's `cpu_ip` histogram, which currently shows ~35% of samples in a two-
instruction poll at 0x12B0/0x12B8 and the remainder around 0x18E98/0x18EA4. If
the board never enters the emitting region, the question becomes what the poll
is waiting for; if it does, the question becomes why the writes do not follow.

*Three hypotheses were spent today reaching this point, and all three are
recorded as wrong rather than deleted:* the fitter's crash rate is not the
physical-synthesis settings (R176's neighbourhood), the glyph cache cannot be
halved despite its own rationale, and this. The pattern in all three is the same
-- a plausible mechanism adopted before it was measured -- and the counters that
eventually settled each of them cost one build apiece against the several spent
guessing.


---

**R182 - THE TEST QUAD RENDERED ONE EDGE, NOT A FILLED RECTANGLE. THE DRAWING
HALF IS PARTLY PROVEN, NOT PROVEN, AND THE PREVIOUS CLAIM IS CORRECTED HERE.**

*What was claimed and what was seen.* A commit message states "THE RASTERIZER
DRAWS" on the strength of a green rectangle appearing on the board. the
correction: **only one side of it was visible**. That is a materially different
result and the overstatement is corrected rather than left standing.

*What IS established.* Something reached the screen through the entire
downstream path -- quad store, sort, span generation, band buffer, video mixer --
from a quad injected at the `q_*` port. Before this, every quad that path had
ever seen had four vertices on one pixel and correctly drew nothing, so the half
was wholly unverified. Pixels arriving at all is real progress and is why the
test exists.

*What is NOT established.* That the fill path works. One visible edge is
consistent with several distinct faults and the evidence does not choose between
them:

  - **The store-clear race.** `qs_clear = (pst == P_COLLECT) && frame_start`,
    and the injector issued its quad on that same edge, so the clear sometimes
    won. Partial survival of one quad's spans would show as partial geometry.
    Fixed by delaying the injection eight cycles; that fix is untested at the
    time of writing.
  - **The wireframe path.** `m2_raster_fill` flags `line_case` for a quad with
    only two distinct screen vertices and retires it WITHOUT EMITTING -- the
    Bresenham line unit MAME uses is not implemented here. If the quad is
    reaching the filler degenerate, one edge is what a partly-working span
    generator would produce.
  - **Vertex order.** The filler expects the quad traversed around its
    perimeter. The injector uses (160,120) (160,260) (340,260) (340,120), which
    is a proper cycle and matches the engine's own v0..v3 convention, so this is
    the least likely of the three -- but it has not been ruled out.

*Why this matters beyond the test.* The test quad exists precisely so that a
black screen after the geometry is fixed can be attributed to one half or the
other. A test that itself renders incorrectly cannot do that job, so it has to
be made correct before it is trusted -- and the first thing it has told us is
that it was racing the store clear, which is a fault in the instrument.

*Standing correction.* "A green box appeared" was reported here as the drawing
half working. It is not. This project has now made the same class of error
twice in one day -- R181's race fix and this -- adopting a conclusion from a
signal that was weaker than the claim it was used to support.


---

**R183 - THE DRAWING HALF IS PROVEN ON HARDWARE. AND THE QUAD STORE WAS NEVER
BEING CLEARED, WHICH WOULD HAVE BROKEN THE REAL RENDERER TOO.**

*The result.* With four coloured test bars injected at `q_*` -- RED top, GREEN
right, BLUE bottom, YELLOW left, each a filled rectangle, offset so none touch --
all four appear on the board in the correct positions and the correct colours,
composited over the tilemap. Photographed.

That closes R182's doubt and proves, on hardware:

    m2_quad_store          accepts and replays quads
    the z-sort             does not lose them
    m2_raster_fill         FILLS -- both horizontal and vertical bars, not edges
    line_case              is NOT firing; these are true fills
    the band buffers       hold and present them
    the video mixer        composites over the tilemap correctly
    q_col                  reaches the band buffer intact, four distinct colours

Before this, every quad that path had ever seen had four vertices on one pixel,
because the matrix was zero, and those correctly draw nothing. The entire
downstream half was unverified and could not be distinguished from a geometry
fault. It can now.

*The fade, and it is not a test artefact.* The bars persisted for several
seconds and decayed. The cause:

    assign qs_clear = (pst == P_COLLECT) && frame_start;
    P_COLLECT: if (q_end) pst <= P_SORT;

The producer cycles P_COLLECT -> P_SORT -> P_SORTW -> P_READY -> P_COLLECT, the
last step on `frame_start`. So at the instant `frame_start` arrives, `pst` is
P_READY and the gate is FALSE. **The store is cleared only on frames that drew
nothing.**

Quads therefore accumulate without limit. Four bars per frame into a 2,048-entry
store fills it in 512 frames -- about 8.5 seconds at 60 Hz, which is the observed
decay -- after which every new quad is dropped.

**This would have broken the real renderer identically.** The geometry path
issues `q_end` every frame too, so a working geometry feed would have filled the
store just as surely and then stopped accepting anything. It was hidden only
because nothing had ever drawn.

MAME has no such condition: `render_frame_start()` resets `poly_list_index` at
the top of every `geo_parse`, unconditionally. Ours now clears on `frame_start`
outright.

*Method note.* The four-bar pattern was a deliberate change, and it is a better
instrument than the single rectangle it replaced for a reason worth keeping: each
bar is an independent test and the colour identifies which one drew, so a partial
result is diagnostic instead of ambiguous. The single rectangle produced "one
side visible", which was consistent with three unrelated faults and chose between
none of them.


---

**R184 - THE WHOLE PATH FROM DISPLAY LIST TO PIXELS RUNS ON HARDWARE. IT IS
DRAWING GARBAGE BECAUSE A ZERO MATRIX PROJECTS TO NaN, AND THE SCATTER PATTERN
IS THE PROOF.**

*What the board shows.* Small grey rectangles, 1-2 pixels tall and up to ~40
wide, scattered across sky and grass, appearing and accumulating. Photographed
in three views.

*They are ours.* Grey is `flat_col = 0xC0C0C0`; nothing else in this design
draws it. Through the fill path that is
`{col[23:19], col[15:10], col[7:3]}` = 0xC618 in RGB565 and 0xC6C6C6 back out at
the mixer -- lighter than the blue sky, darker than the bright yellow-green
grass, which is how it reads in both photographs.

*Why they are scattered and tiny, exactly.* The UART says `mtx_DECODED = 0`, so
m2_geo_xform's matrix is still all zeros. Then:

    transform_point   -> (0, 0, 0)
    apply_focus       -> (0, 0)
    m2_geo_project    -> x / z = 0 / 0 = NaN
    fp_to_int(NaN)    -> an arbitrary integer

So every vertex lands at an arbitrary screen position with near-zero extent
between the four of them. Small marks at random positions is not a symptom to be
explained away -- it is the precise signature of a zero matrix reaching a
projector that divides.

*WHAT THIS ESTABLISHES, AND IT IS THE LARGEST RESULT SO FAR.* The complete chain
runs on hardware: the walk, the engine, the transform, the focus, the
projection, the clipper, the quad store, the z-sort, m2_raster_fill, the band
buffers and the video mixer. Quads reach pixels, in the right colour,
composited over the tilemap, every frame. **Nothing between the front door and
the screen is unproven any more.** It is drawing garbage because its input is
garbage, which is a different and much smaller problem than a renderer that does
not run.

*The blocker, now located to one statement.* `mtx_push` is STATIC at 110: the
game issued 110 matrix writes during initialisation and none since. Per frame it
emits a TEN-DWORD list -- `wp` reaches 0x28 -- containing window_data, an operand
or two, and geo_end. MAME's buffer at the equivalent moment holds 1,936 non-zero
words including 29 matrix writes and 138 object_data.

That is R178 and R181 unchanged, and every measurement since has narrowed rather
than moved it: the i960 writes, the front door accepts, the words are
byte-correct against MAME, the pointers match simulation, the queue does not
overflow, the walk runs thousands of frames, and the renderer draws whatever it
is given. The one thing that differs between the bench and the board is what the
GAME chooses to emit.


---

**R185 - PARTLY RETRACTED. THE CLAIM "THE BOARD NEVER EXECUTES THE EMITTING
CODE" IS NOT SUPPORTED BY THE INSTRUMENT THAT PRODUCED IT. WHAT SURVIVES IS THE
DIRECT COUNT: 110 MATRIX PUSHES, STATIC. THE EMITTING PC IS 0x00017A04.**

*The retraction, first.* The zero-samples argument rests on the UART profiler,
and `prof_div` is 16 bits: one sample every 65,536 clk_sys cycles, which at
50 MHz is **12.7 samples per 60 Hz frame**. A routine that runs as a short burst
once a frame occupies a fraction of a percent of the cycles, so a histogram at
that resolution cannot distinguish "never runs" from "runs briefly". the
objection was that everything else is finished and working, which makes "the game
never calls its own 3D code" the least likely explanation on offer -- and the
instrument does not support it.

**Absence of samples is not evidence of absence here.** The sampling rate has to
be raised, or the question asked a different way, before anything is concluded
from that histogram.

*What DOES survive, because it is a direct count and not a sample:*

    board:  110 matrix pushes, STATIC over minutes
    bench:  15,993 matrix pushes at 30M instructions

`geo_mtx_push` increments on every push whose reconstructed opcode is 0x0b or
0x1b, on BOTH ports, exactly. It is not sampled. The board pushed 110 matrix
writes and has pushed none since, and that is a fact about the machine rather
than about a profiler.

*So the question is unchanged and the answer is not yet known:* why does the same
game, on the same ROMs, push 15,993 matrices in the bench and 110 on the board?
The candidates below still stand, and to them is added the one the objection
implies -- that the game IS running its 3D code and something about the push path
rejects or loses those particular writes, which the 110-then-nothing pattern
would also fit.

--- the original entry follows, with its overstated headline ---

**R185 - THE BOARD NEVER EXECUTES THE CODE THAT EMITS GEOMETRY. THE FAULT IS
UPSTREAM OF THE GEOMETRIZER ENTIRELY, AND THE PC THAT DOES THE EMITTING IS
0x00017A04.**

*The measurement.* The boot bench now captures `dbg_ip` at the instant a matrix
write is pushed through the front door. In simulation at 30M instructions:

    PUSHED: 15,993 matrix, 30,898 object
    last matrix pushed from PC 00017a04
    matrix writes decoded = 407, focal = 32
    polygon_data: 33 commands, 10,770 dwords written

*Against the board, over 88,598 captured cpu_ip samples:*

    samples at 0x17900-0x17b00 (the emitting PC):    0
    samples anywhere in 0x17000-0x18000:            65   (0.07%)
    pushed on the board:                           110 matrix, STATIC

**Zero.** The board does not reach the code at all. This is not "it executes and
the writes fail" -- every stage downstream of that had already been eliminated by
measurement (R177 the words, R178 the counters, R179 the pointers, R184 the
renderer). It is that the game never calls the routine.

*What the idle poll is, and what it is not.* The board's largest single PC is the
two-instruction loop this study documented long ago:

    000012B0: ldob    0x500000,r3
    000012B8: cmpibe  r3,g0,0x12b0

0x500000 is `map(0x00500000, 0x005fffff).ram().share("workram")` -- plain work
RAM, not a register. It is the game's own idle flag, set by an interrupt handler,
and the loop is the frame-wait. It was 69.2% of the frame when first measured and
is now **6.8%**, so the machine is doing more work than it was, not less. The
poll is not the blocker and should not be chased again.

*Where this leaves it.* Everything from the front door to the pixels is proven on
hardware (R184), and the game emits nothing to put through it. The two sides
differ in what the i960 CHOOSES to execute, so the candidates are the things that
differ between bench and board before that choice is made:

  - **Backup RAM.** The bench starts with a fresh array; the board has persistent
    saved settings from previous runs. Different settings, different attract
    path. This is the first thing to test because it is cheap: clear the board's
    backup RAM and see whether the PC distribution moves.
  - **The I/O board and DIP switches**, which the bench models and the board has
    for real.
  - **Self-test outcome.** A failed check taking a different branch would look
    exactly like this.

*Method note, and it is the lesson of the whole day.* Three hypotheses were spent
guessing at this before the PC was captured, and all three were wrong. The
capture cost one build and answered it outright. Every question today that was
settled by adding a counter was settled in one build; every question approached
by hypothesis cost several and was still wrong at the end.


---

**R186 - THE GAME EMITS GEOMETRY UNTIL FRAME 140 AND THEN STOPS. THE PUSH PATH IS
EXONERATED BY DIRECT COUNT, AND THE QUESTION IS NOW WHAT HAPPENS AT FRAME 140.**

*The measurement, all exact counts rather than samples:*

    mtx_push = 110      last matrix pushed at walk frame 140
    decoded  = 0
    REFUSED  = 1008     STATIC
    accepted = 2475     CLIMBING

*What each eliminates.*

**REFUSED is static.** The function port's gate -- `bit31 set, or a 16-byte
aligned address`, mirroring `geo_w` -- is the only place this design deliberately
discards a CPU write. 1,008 were refused early and none since. We are not eating
the game's matrix writes, and that hypothesis is closed. (1,008 refusals is not
itself a fault: MAME discards the same writes.)

**accepted is climbing.** The game is writing to the function port continuously,
right now, thousands of writes in. It is not stalled, not waiting, and not
finished with the geometrizer -- it is actively using it, for `window_data` and
`geo_end` and nothing else.

**last@frame = 140.** This is the finding. The game pushed matrix writes up to
walk frame 140 -- about 2.3 seconds -- and has pushed none in the thousands of
frames since. Combined with the two above, the game did not fail, block, or lose
its writes. **It stopped.**

*So the question narrows to one event.* Something at or before frame 140 changes
what the game decides to draw, and the same code in the boot bench goes on to
push 15,993 matrices. Frame 140 is roughly where a boot sequence hands over to
attract, which makes the candidates:

  - the attract path taken on hardware differs from the bench's, because of
    persistent backup RAM, DIP switches, or the I/O board's state
  - a check performed once around that point fails on hardware and disables 3D
  - the coprocessor: R167 established that it RUNS, and nothing since has
    established that its RESULTS are right. A game that asks the TGP to transform
    its first scene, gets wrong answers back, and stops drawing would look
    exactly like this -- and would explain why it emitted geometry at all before
    the first results came back.

*What is no longer a candidate.* The walk, the front door, the opcode
reconstruction, the queue, the pointers, the renderer, and the push gate. Each
was eliminated by a counter rather than an argument.

*Method, stated once more because it held all day.* Five hypotheses were spent
on this question and all five were wrong. Every counter added answered its
question in a single build. The counters that mattered here -- when the last
matrix landed, and how many writes the gate refuses -- cost one build together.

**R187 - THE COPROCESSOR'S MICROCODE IS IN THE GAME ROM, AT A KNOWN OFFSET, AND
OURS IS UPLOADED CORRECTLY. THE i960/COPRO CONVERSATION IS NOW DIFFABLE AGAINST
THE REFERENCE.**

Believed before: the TGP microcode existed only as something the i960 assembled
at boot, so the upload could be checked only by watching the words go past
(`m2_copro.sv`'s `dbg_uc_*`), and the bench's microcode test could not be run at
all -- it was skipped on every run for want of an image, and said so.

Known now, and how it was established:

1.  **The microcode is a verbatim block in the game's i960 DATA ROM**, at offset
    `0x60020` of the interleaved `epr-16534a.6` + `epr-16535a.7` image
    (`ROM_LOAD32_WORD`), 2024 words long. Not the i960 *program* ROM, which is
    `epr-16530a.12` + `epr-16531a.13` at `0x0000000` -- an error made once here
    and caught by disassembling `0x12b0` out of the wrong image and getting
    floating-point constants instead of instructions. Established by dumping `:copro_tgp`'s
    program space out of the reference after boot and searching the ROM image
    for it: the whole 8096-byte block matches. `tools/extract_tgp_microcode.py`
    pulls it out, and its output is byte-identical to the reference's program
    RAM. It is NOT a BIOS and NOT a separate ROM file, so nothing is needed on
    the SD card beyond the ROM the MRA already builds.

2.  **It is not in the "tgp" ROM region.** MAME labels `mpr-16536`/`mpr-16537`
    "TGP program? (COPRO socket)", which reads as the microcode and is not: that
    region is mapped at `0x00800000` in the copro's *data* space
    (`copro_tgp_map`), and the program space at `0x000-0x7ff` is RAM. Those two
    ROMs are the copro data the MRA already loads at `0x0a40000`.

3.  **The upload protocol is confirmed end to end.** `copro_ctl1` bit 31 set
    starts it and zeroes the counter; every write to the FIFO window
    `0x00884000` while it is set goes to program RAM instead of the FIFO;
    clearing bit 31 releases the copro from halt. Captured from the reference:
    one `C 00980000 80000000`, exactly 2024 pushes, one `C 00980000 00000000`.
    Ours does the same, in the same order, with the same words -- the first
    being `bf600010`, the reset vector.

4.  **Every instruction in the real microcode decodes.** Disassembled with the
    Model 1 project's `mb86233_disasm.py`: 2024 words, zero `unknown_group`,
    zero unnamed ALU operations. Run on our RTL core it retires 20,342
    instructions with `unimplemented` never asserted, reaching its input-wait
    loop (PCs `000`, `010-049`, `7cb-7d8`) -- 73 distinct PCs, because a
    standalone core is fed no FIFO input.

5.  **The bench's microcode loader truncated to 512 words.** It sized its buffer
    `0x2000` *bytes* while the program space is `0x2000` *words*. Daytona's
    program is 2024 words, so three quarters of it was being dropped -- and
    because the test had never been given an image, this had never shown.

*What this does not prove.* That the coprocessor's arithmetic is right. Decoding
every opcode is not computing every opcode correctly, and the microcode-driven
lockstep is still owed.

*The measurement this opens, which is the point of it.* The reference can be
tapped at the four coprocessor windows with a Lua memory tap, and the bench now
logs the same four windows in the same format (`M2_COPRO_TRACE`). The two traces
are directly diffable: same upload, same function-port commands, same FIFO
pushes -- and the first output word that differs is the coprocessor's
arithmetic, which nothing has ever checked against the reference. Through the
first command after boot -- `F 00880080 00000001` -- they already agree.

**R188 - THE COPROCESSOR IS CLEARED. SIMULATION REACHES THE 3D AND THE BOARD
DOES NOT, SO THE FAULT IS HARDWARE-ONLY AND THE BOARD IS WAITING ON A FRAME FLAG
THAT DOES NOT MOVE.**

Believed before: the coprocessor's arithmetic was the last untested stage and the
likeliest cause of the game emitting 110 matrix writes and stopping. R167 proved
it runs; nothing had ever proved what it computes.

*The coprocessor computes correctly.* Its outputs were captured from the
reference with a Lua tap on the four copro windows and from the boot bench with
`M2_COPRO_TRACE`, and compared. The command mix matches by rank -- `0x27`,
`0x28`/`0x02`, `0x25`, `0x24`, `0x01` lead both -- and the distinctive output
constants are the reference's own: `3ea8f5c3`, `43148d8e`, `430f4545`,
`43021a1a`, `41ae0e0f`, `3fac38e4` all appear in ours. Both coprocessors also
park in the same place when idle, the microcode's FIFO wait: the reference at pc
`004c` for 194 of 250 samples, ours at `030b`, which is `goto L_04c` -- our
debug PC reports the previously retired instruction, and `L_04c` is `b = rf1`.

*Simulation reaches the 3D.* Run to 40M instructions the boot bench emits **755
matrix writes and 1,084 objects** and produces 56.6M coprocessor events out to
frame 898. Nothing in the RTL prevents the 3D from running.

*The board does not, and it is not hung.* Its UART counters have read a static
`mtx_push=110, last frame=134, fn_reject=1008` across every sample, while the
profiler puts 90% of its samples in a two-instruction spin at `0x12b0`:

        0x12a8  ldob   r16, [0x00500000]     ; snapshot the frame flag
        0x12b0  ldob   r3,  [0x00500000]
        0x12b8  cmpibe r3, r16, 0x12b0       ; loop WHILE it is unchanged

That routine has exactly one caller, `0x128c`, and the caller is the main game
loop: `0x1240` .. `call 0x17c38, 0x1758, 0x1838, 0x17c50, 0x1abbc, 0x12a8` ..
`b 0x1240`. So the machine is alive and looping; it is waiting for the byte at
`0x00500000` to change. In the reference that byte counts `00,01,02,...,2b`.

*A difference in which wait, not merely how long.* The reference never sits at
`0x12b0` in either phase. Pre-3D (frames 1-159) it spends 65% at `0x12f0`, a
second frame-wait that tests a BIT of the same byte and has seven callers; in the
3D phase it spreads across `0x11450-0x11538` with no dominant spin. The 3D
itself starts at frame 162 -- before that the reference emits **two** matrix
writes in total, so no conclusion drawn from board behaviour before frame 162
means anything, and "matrix writes stop at frame 134" describes a window in
which the reference emits nothing either.

*What is measured next, and why it is one build.* Three causes remain and a
counter separates them, so none of them is worth arguing about:

  * nothing writes the flag -- the interrupt path is the fault
  * it is written and reads back different -- the memory path is the fault
  * it is written and reads back the same -- the flag moves and the main loop is
    waiting on something else

The build carries writes to `0x00500000`, the last value written, the last value
read, the write's byte enables, and the vblank interrupt count, in place of the
geometry counters that have had nothing to say since frame 134. `mtx_push` stays
in the record because it is the headline number.

*Recorded as wrong.* `epr-16534a.6`/`16535a.7` were called the i960 *program*
ROM in R187. They are the i960 *data* ROM; the program is
`epr-16530a.12`/`16531a.13`. Caught by disassembling `0x12b0` from the wrong
image and getting floating-point constants where instructions had to be.

**R189 - AUTO_RESOURCE_SHARING HAS BEEN OFF FOR EVERY BUILD THIS PROJECT HAS
EVER MADE, AND OPTIMIZATION_TECHNIQUE SPEED GUARANTEES NOTHING SHARES.**

Believed before: nothing, which is the point. The setting is absent from
`Model2.qsf` and was never considered, so no entry here records a decision about
it either way.

Known now: `AUTO_RESOURCE_SHARING` defaults to **Off** in Quartus, and this file
sets `OPTIMIZATION_TECHNIQUE SPEED`. Those compound. Sharing lets one adder or
comparator serve several operations the design can never run at the same time;
with it off, every such operator is built separately, and SPEED biases the
synthesiser away from making that trade on its own. So the design has been
paying full area for operators that are mutually exclusive by construction.

*Why it did not matter and now does.* The area was there. The comment beside
`PHYSICAL_SYNTHESIS_COMBO_LOGIC_FOR_AREA` still says the design has "8,940 ALM
spare" and is the reason that option was turned off; a later note beneath it
already records that both halves of that sentence are false. The fit is now
41,144 / 41,910 ALM (98%) with 553/553 M10K, and four consecutive seeds have
missed timing -- -0.311, -0.974, -0.423 and one Internal Error -- against
-0.021 on the build on the board. A fitter at 98% occupancy misses timing
because it has nowhere to place, not because a path is inherently slow, and the
seed sweeps that have been the standing remedy are treating the symptom.

*What is expected, and what would falsify it.* Sharing trades logic for muxes on
the shared operands, so it reduces ALM and can lengthen a path. The measurement
is ALM and worst-case slack together: fewer ALM with slack no worse is the win;
fewer ALM with slack materially worse means the muxes landed on a critical path
and the setting is wrong for this design. ALM alone is not the result.

*Recorded because this file has been burned by it.* Fitter settings changed in a
batch correlated with a run of crashes earlier in this project and had to be
reverted wholesale. This is ONE setting, changed alone, and `quartus_map` is
re-run rather than `quartus_fit` alone -- it is a synthesis assignment, so a
fit-only rerun would reuse the previous netlist and report a result for a
setting that never took effect.

**R190 - AGGRESSIVE AREA + AREA + RESOURCE SHARING FREES 3,590 ALM, AND THE ONLY
THING IT BREAKS IS THE FRAMEWORK'S SCALER.**

Measured, two seeds, against the build on the board:

| | SPEED + HIGH PERFORMANCE EFFORT | AREA + AGGRESSIVE AREA + sharing |
|---|---|---|
| ALM | 41,144 / 41,910 (98%) | **37,554 (89.6%)** |
| M10K, device | 553 / 553 | 553 / 553 |
| M10K, claimed by memories | 583 | 574 |
| worst-case slack | -0.202 | -3.344 |

*The area is real and it is large.* 3,590 ALM, and 8.4 points of occupancy. This
project has spent build after build seed-sweeping a fitter that had nowhere to
place; that is the actual remedy for it, and `AUTO_RESOURCE_SHARING` had been
OFF for every build ever made because it is absent from the qsf and defaults Off
(R189). SPEED refuses the logic-for-mux trade that sharing exists to make, so
the three settings only mean anything together.

*It also packed the quad store better with no RTL change.* 75 M10K to 66. The
four vertex arrays are identical 2048x32 simple-dual-port memories and were
costing 14/13/13/12 blocks against `key`'s 7 for the same shape -- 24 blocks of
pure packing waste, of which 9 came back. `m2_quad_store.sv` already records an
earlier round of this, where reading `vtx0[q][15:0]` and `vtx0[q][31:16]`
separately duplicated the array outright; that was fixed and the cost never
came back down, which is why the remaining waste was not a second read.

*The whole timing cost is in `ascal`, which is not ours.* Every failing path:

    SLACK -3.147  FROM ascal:ascal|o_hcpt[1]  TO ascal:ascal|o_vcpt_pre3[6]

Not one of our own paths appears, and `m2_sdram|dq_r -> p_dout` -- the worst
path at -0.202 under SPEED, and the subject of R176 -- drops off the list
entirely. The scaler was already second-worst at -0.106 before the change, so
area-restructuring its arithmetic is what blew it out.

*So the fix is an exemption, not a retreat.* `OPTIMIZATION_TECHNIQUE` and
`AUTO_RESOURCE_SHARING` are entity-level assignments; `ascal` keeps what it was
closing under and the core keeps AREA.

*Still to measure.* Whether the exemption recovers the slack without giving back
the ALM, and whether `PHYSICAL_SYNTHESIS_COMBO_LOGIC_FOR_AREA ON` and
`PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION OFF` -- Model 1 runs the latter off,
we run it on -- buy more. M10K is untouched by any of this: 553/553 before and
after, because these settings act on logic, not on memory inference.

**R191 - CORRECTS R189. THE AREA CAME FROM THE MODE AND THE TECHNIQUE.
`AUTO_RESOURCE_SHARING` CONTRIBUTED NOTHING AND MUST COME OUT.**

R189 framed `AUTO_RESOURCE_SHARING` as a lever that had been off for every build
this project ever made, and R190 credited 3,590 ALM to the three settings
together while noting the combination made the individual contributions
unattributable. Model 1 has since isolated it on the same part, and the answer is
that the sharing flag does nothing.

From `sega-model1-mister/docs/findings.md`, 2026-09-07:

  * Adding `AUTO_RESOURCE_SHARING`, `MUX_RESTRUCTURE`,
    `REMOVE_REDUNDANT_LOGIC_CELLS` and
    `AUTO_DELAY_CHAINS_FOR_HIGH_FANOUT_INPUT_PINS` on top of Aggressive Area +
    AREA produced a **byte-identical bitstream** -- same md5, same 41,124 ALM,
    same +0.896 ns. Two instruments agree: the V60 module is 16,007 ALM with and
    without it.
  * **"Aggressive Area + AREA already enable the sharing it asks for."**
  * It is NOT inert everywhere. Against `OPTIMIZATION_MODE "Aggressive
    Performance"` the flag alone makes the V60 **worse**, 17,759 to 18,125,
    because it fights the performance bias. Model 1 therefore guards it inside
    the same branch as the mode and technique so a speed-biased build never
    gets it.
  * Their verdict: **"Do not add it."**

*What this changes here.* The 41,144 -> 37,554 ALM measured in R190 is real, and
it is the work of `OPTIMIZATION_MODE "AGGRESSIVE AREA"` and
`OPTIMIZATION_TECHNIQUE AREA`. The sharing flag rides along contributing zero,
and in any configuration that keeps a performance-biased mode it is a
pessimisation. It is not to be restored when the area settings go back.

*What it does not change.* The `ascal` exemption stands on its own measurement:
every failing path under AREA was `ascal|o_hcpt -> ascal|o_vcpt_pre3`, and
exempting the scaler took worst-case slack from -3.147 to +0.220 while keeping
38,136 ALM of the 3,590 saved.

*And it weakens the black-screen hypothesis.* Model 1 ships Aggressive Area +
AREA and runs. That is not proof for this design -- the memories differ, and
inference is the one thing a fitter setting can genuinely change, which
`quad_store` 75 -> 66 M10K shows it did -- but it makes the loading method the
better suspect. `/dev/MiSTer_cmd` has twice left the core up with no ROMs, which
black-screens with the 3D test bars still rendering, exactly as observed.

*Method note.* Read from the live `sega-model1-mister` working copy rather than
`tools/model1-ref`, which tracks commits only; this finding was recorded today
and the mirror's known limitation is that uncommitted work there is invisible.

**R192 - 7ff4217 DOES NOT BOOT. DO NOT REINTRODUCE IT. THE MECHANISM IS NOT
KNOWN AND IS NOT WORTH CHASING.**

Commit `7ff4217` ("Trim the instrument to two latches") produces a bitstream in
which the i960 traps and halts at IP 0 and the screen stays black. Confirmed on
hardware, on two different fitter configurations and two different seeds.

Bisected against builds tested on the board:

| commit | RTL | flags | result |
|---|---|---|---|
| `6523ee3` | pre-instrument | original | **boots** |
| `87b11e2` (13) | instrument, four counters | original | **boots** |
| `7ff4217` (14) .. HEAD | instrument, trimmed | original | traps at IP 0 |
| `7ff4217` (14) .. HEAD | instrument, trimmed | AREA | traps at IP 0 |

The UART reports `C 00000000 C0000000` -- IP 0 with `cpu_trap` and `cpu_halted`
both set -- and `H EEEEEEEE EE000000`, the reset values, so nothing ever ran.
Commits 15-21 touch only `Model2.qsf`, and the control build that reverted every
flag to the known-good configuration still failed, which rules the flags out.

**Timing does not explain it.** The two failing bitstreams had BETTER worst-case
setup slack than the two that work: +0.199 and +0.220 against -0.209 and -0.062.

**The diff does not explain it either**, which is why this entry does not try.
It removes four `cpu_dbg_ip` comparators and a counter and adds one 32-bit latch
on writes to `0x005010a8`. All of it is debug that dead-ends in the UART record;
none of it touches the CPU, the bus, reset, or any memory.

*The rule, which is the only part that matters.* `Model2.sv` at `87b11e2` is a
known-good instrumented baseline. Build instruments forward from it. Do not
reapply `7ff4217`, and do not spend builds trying to find out why it fails --
that was offered and declined, deliberately.

*One habit that made it expensive to find.* Several of the `Model2.sv` edits in
commits 6-14 were made by splicing the file at string indices rather than by
matching exact text. One of them silently dropped a snoop and left a stale block
behind, which was only noticed later by reading the file. Lint does not catch
this: Verilator checks that signals are driven, not that the logic is what was
intended.

**R193 — the seed does not cause the black screen; it exposes a startup race.**
Two bitstreams, identical source and identical fitter flags, differing only in
`SEED`, were rebuilt from one tree on 2026-09-08 and reproduced **byte for byte**
against the originals built a day apart:

```
SEED   SETUP     HOLD      ALM       MD5
1604   -0.209    0.169     41,138    3cc7a41d…   boots
1953   -0.198    0.240     41,223    3c3d213f…   black screen
```

*What was believed.* That the two earlier bitstreams differed by more than the
seed, because `build_id.tcl` stamps a build date and they were built on
different days. **Wrong.** `build_id.tcl` is a `PRE_FLOW` script and this
project invokes `quartus_map`/`quartus_fit` directly, never `quartus_sh
--flow`, so it never runs. `build_id.v` read `260906` in the root and in both
staged builds. Quartus is bit-reproducible here, and the earlier comparison was
valid after all. Reproducing an md5 is how that was established -- not by
re-reading the assignment files.

*What is now known.* The failure is not video and not a marginal net. The
debug UART is alive on the black screen and emits the same line count as the
working build (9,587 against 9,588). What differs is the payload:

```
a_data = {cpu_trap, cpu_halted, copro_stall, uploading, copro_prog_words[11:0], tgp_pc[15:0]}
a_addr = cpu_dbg_ip

1604   07E8030B / IP 12F0, 12B0, 1166C, 1C488, 228434   trap=0 halted=0, 2024 words, TGP running
1953   C0000000 / IP 00000000 on all 9,426 samples      trap=1 halted=1,    0 words, TGP at 0
```

The i960 traps and halts having executed **nothing** -- IP never leaves zero and
the microcode upload never starts. Its first fetches return data it cannot
execute.

*Why this changes the conclusion.* A placement that merely lost margin on a
constrained path would degrade the picture, not stop the CPU before its first
instruction. A clean, repeatable trap at IP 0 that follows the seed is a race on
a path nothing constrains -- which is consistent with the standing
`Design is not fully constrained for hold requirements` warning, and with the
failing build scoring BETTER on both setup and hold than the working one. Static
timing analysis is not measuring the path that breaks.

*Consequence for the build.* Pinning `SEED 1604` is a lottery ticket, in the
exact sense Model 1's notes use the phrase: it buys a working bitstream without
removing the fault, and the fault travels with every future change. `SEED 1604`
stays only as a way to get a testable core while the race is found.

*Where to look first.* `cpu_rst_n = game_rst_n & rom_loaded & game_image &
cal_done & bi_done`, and the read-latency mux at `Model2.sv:807`, where
`rd_lat_sel` follows `cal_sel` while `!cal_done` and switches to the scan's
answer `cal_best` at `st_state == 4'd12`. A calibration that picks a marginal
latency, or a reset released before the memory path is genuinely settled, both
produce this signature. `O[7:5]` overrides the scan at runtime and is the
cheapest test available -- but it needs the OSD, and MiSTer exposes no way to
set a status bit remotely.

**R194 — the duplication settings cost this design nothing. Do not spend a build
on them again.** Model 1's `mister_project.sh` names
`PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION` and
`ROUTER_LCELL_INSERTION_AND_LOGIC_DUPLICATION` as the two template settings that
"spend ALM most directly", and defaults both OFF. Both were ON here. Measured
2026-09-08, identical RTL and identical flags otherwise, at two seeds:

```
                    SETUP     HOLD     ALM       MD5
1604  dup ON       -0.209    0.169   41,138     3cc7a41d
1604  dup OFF      -0.205    0.192   41,138     1b2ba6a6
1953  dup ON       -0.198    0.240   41,223     3c3d213f
1953  dup OFF      -0.614    0.013   41,223     98a43366
```

**Zero ALM, at both seeds, to the digit.** The bitstreams differ, so the
assignments reached the fitter and moved the placement; they simply do not cost
this netlist any logic. At 1953 the OFF build is 0.416 ns worse on setup. The
finding transfers in the direction of the measurement and no further: it is real
on Model 1's netlist and absent on ours.

The wider result is that the flag-level area reclaim is spent. The four framework
`MISTER_*` macros Model 1 defaults were already set here and their logic is
absent from the fit report (`alsa:alsa` and `yc_out:yc_out` appear zero times);
`MISTER_SMALL_VBUF` changes only ascal's DDR3 `RAMSIZE` and touches neither ALM
nor M10K (Model 1 corrected its own note on this, 2026-09-09); and the
mode/technique axis black-screened the board three times. Area now has to come
out of the design, not the fitter.

**R195 — the grey pixels were the display list being read mid-rewrite, and the
flip trigger removes them. It does not yet put geometry in their place.**
Built 2026-09-08 at seed 1604 (`46c0fef4`, 41,049 ALM, setup -0.303, hold
+0.119): commit 13 plus the `0x00803008` write trigger in `m2_geo.sv`. On
hardware the core boots normally --

```
C 000012F0 07E8030B    trap=0 halted=0, 2024/2024 microcode words, TGP running
```

-- and **the grey pixels are gone**. They had been read as "3D without its
vertices". That reading is now supported: walking on the game's flip instead of
on vblank stops the walk reading a list the i960 is still rewriting, and the
degenerate polygons disappear with it. This is the failure Model 1 documented as
"vertices collapsed toward the origin", and it is the same fix.

*What is NOT established.* Nothing replaced them. The screen has no 3D at all, so
the walk is now reading something empty rather than something wrong, and two
explanations remain open:

1. the walk runs far less often, because it now waits for a flip the game
   issues rarely; or
2. the walk runs at the same rate and finds an empty list at the pointer the
   flip handed it.

The instrument on this build carries the task-walker bytes
(`tw_1854`/`tw_1860`/`tw_1c14`) and cannot separate those -- they are CPU-side
counters. `tw_1c14` moved 0x26 -> 0x2A against the same core without the fix,
which says only that walker behaviour changed.

*The trigger itself checks out.* `geo_rp` is loaded on `wr_setrp`
(`m2_geo.sv:193`), `flip_pend` is set from the registered `setrp_q` the cycle
after (`:536-537`), and `W_IDLE` loads `w_ip <= geo_rp[16:2]` (`:572`). The walk
starts from the pointer the game just wrote, not a stale one.

*Next measurement, not next guess.* `b_addr` -> `{geo_walk_frames, geo_walk_ops}`
and `b_data` -> `{geo_polys, geo_clip_out}`. Frames says whether the walk runs,
ops whether it decodes anything, and the pair of polys against quads whether
anything survives to the rasterizer. All four are already ports on `m2_geo`; the
change is two expressions on the debug instance.

**R196 — the walk is aimed correctly and reads the wrong memory.** Built at seed
1604 with `dbg_rp`/`dbg_wp` exposed from `m2_geo` (`2baa36ef`, 41,116 ALM). The
core boots (2024/2024 microcode, TGP running). Measured on hardware:

```
H = rp | wp
 90x   rp 00000000   wp 00000024
 12x   rp 00000000   wp 00002010
  9x   rp 00000032   wp 0000403C
```

`rp` sits at zero while `wp` climbs to `0x403C` -- 16 kB of display list written
per frame. Read pointer at the buffer start with writes growing forward from it
is what correct double-buffering looks like, so **the walk is aimed at the right
address and the data is being written.** With the flip trigger it nonetheless
runs 901 times in twenty seconds, retires one to three opcodes each time, and
produces zero polys and zero quads (R195).

Aimed right, data present, nothing decoded: the walk is not reading the memory
the pushes land in. `w_ip <= 19'(geo_rp[16:2])` converts a byte address to a word
index correctly; what is unproven is the BASE that index is applied to.

*This exact fault was found in the bench first and should have been suspected
here sooner.* `sim/io/tb_m2_boot.cpp` read object data from a fixed
`0x0b20000` instead of selecting between `0x1710000`, `0x0b20000` and `0x1720000`
on the `oba` bits; correcting it took quads from 0 to 2,382. The bench and the
board disagree in the same place and in the same direction.

*And the bench is still wrong here, which is the standing warning made concrete.*
The same RTL that gives zero polys on hardware gives 478 in simulation. Where the
two disagree the board wins -- `docs/` has said so since the NaN that wedged the
display-list walk, and this is a second instance. Do not close this from a bench
run.

*Cost note.* Exposing the two pointers cost timing: setup -0.950 and hold -0.280
against -0.303/+0.119 for the same core without them. The instrumented build is
for measurement only and must not be a baseline.

**R196 is WRONG on its central claim, corrected the same day.** It concluded the
walk "is not reading the memory the pushes land in". It is. Read at
`Model2.sv:644` is `GAME_BUFFER + {geo_rd_addr_r, 1'b0}`; the push at
`m2_geo.sv:298` is `base_buffer + (ptr & 0x1ffff) >> 1`, and `base_buffer` is
wired to that same `GAME_BUFFER` (`0x16f0000`). The indexing agrees too:
`w_ip = geo_rp[16:2]` is a dword index, doubled to a 16-bit word index on the
read, against a byte pointer halved on the write. Same memory, same address.
The claim was made from `m2_geo.sv` alone without following `rd_data` to its
source, and the bench's old base-selection bug made a matching fault feel likely.
**Everything else in R196 stands** -- rp at zero, wp climbing to `0x403C`, 901
walks retiring one to three opcodes, zero polys and zero quads.

So the walk is aimed at the right address, in the right memory, with data
present, and stops anyway. What that leaves is the read PORT, and it is already
instrumented. `Model2.sv:642` shares port 4 between the walker and the engine:

```
p_req[4]  = geo_rd_req_r | eng_mem_req_r;
p_addr[4] = eng_mem_req_r ? (engine) : (GAME_BUFFER + ...);
geo_rd_ack_r <= p_ack[4] & geo_rd_req_r & ~eng_mem_req_r;
```

The comment defends this by an `eng_busy` interlock making the two mutually
exclusive, notes R167 made the same sharing fatal when they were independent, and
adds `dbg_p4_clash` to count the cycles where both request anyway -- "if the
interlock is ever wrong, that counter is non-zero rather than the picture being
subtly incorrect". The picture is currently absent and that counter has never
been read on hardware. Read it before theorising further.

**R197 — timing does not predict booting, and the best-timed builds are the ones
that fail.** One RTL (the selectable walk trigger), four seeds, built in one
session and each flashed and read over the UART:

```
SEED   SETUP     HOLD      RESULT
1604   -0.278   -0.269     broken video, horizontal blue/white stripes
1605   +0.159   +0.186     trap=1 halted=1, IP 0 on all 7,544 samples
1606   +0.178   +0.166     trap=1 halted=1, IP 0x00200020
1607   +0.052   -0.055     BOOTS -- 2024/2024 microcode, TGP running
```

Both fully-closed builds fail. The one that boots has NEGATIVE hold. This closes
the question R193 opened: the startup race is invisible to static timing
analysis, and closing timing neither avoids it nor predicts it. Seed sweeping for
slack is therefore not a route to a bootable core, and `SEED 1604` was never a
good seed -- it was the one that happened to boot.

*A wrong turn worth recording.* When 1604/1605/1606 all failed on this RTL while
three earlier builds booted at 1604, the conclusion drawn was "three for three is
not luck, the RTL change broke it". Seed 1607 then booted the same RTL. The
sample was three, the failure rate is around three in four, and three failures in
a row is unremarkable at that rate. **Do not infer a code fault from a run of
seed failures on this design.**

*What the working build measures.* `dbg_p4_clash` is ZERO on hardware, so the
walker/engine interlock on shared port 4 holds and R167's fault is not recurring
-- the first time that counter has been read on silicon. `walk_unknown` is 0 and
`walk_state` returns to `W_IDLE`, with `ops` at exactly 3 every walk. The walk is
not starved, crashing or misreading: it is handed a list containing three valid
opcodes and a proper terminator, while `wp` says 16 kB per frame is being
written somewhere.

*Also delivered.* `O[24:23]` selects the walk trigger at runtime -- Flip, Vblank,
After flip, Write ptr -- so the remaining candidates cost an OSD change rather
than a 25-minute build and a seed gamble.

**R198 — the I/O board's Z80 ran 4.2% fast, and the clock ratios were checked
because someone asked rather than because anything failed.** `clk_sys` moved
from 48 MHz to 50 MHz to make the i960's 25 MHz an exact halving. Two of the
three dependent dividers were corrected at the time -- the video CE became
"SIXTEEN OF FIFTY, NOT ONE OF THREE" and the sound board takes `TICK_DEN(50)`
at instantiation. The Z80's did not:

```
                real board            ours before        ours now
i960KB          25 MHz                clk_i960 25 MHz    unchanged
TGP             50 MHz                clk_sys 50 MHz     unchanged
sound 68000     10 MHz (20 xtal/2)    TICK 20/50 = 10    unchanged
I/O board Z80   4 MHz (32/8)          CEN_DIV 12 = 4.167 TICK 4/50 = 4.000
```

`CEN_DIV=12` was exact on 48 MHz and is 4.167 MHz on 50. It matters more than a
4% error usually would, because that module's own comment records the firmware's
power-on delays (~0.12 s and ~3.0 s, R40) as **Z80 delay loops** -- they come
from the program's own timing, so a fast enable makes every one of them 4%
short.

50/4 = 12.5 has no integer form, so the enable is now fractional, the way
`m2_sound_board` paces its 68000: add `TICK_NUM` each cycle, pulse when the
accumulator crosses `TICK_DEN`. Widths are explicit here because this module's
bench runs `-Wall` and the sound board's does not.

*What this says about the class of fault.* Nothing failed. The board boots, the
I/O exchange completes and the game runs, and it would have gone on doing so.
A derived constant stopped being derived when the thing it was derived from
moved, and only an explicit audit of all four ratios found it. **Whenever
`clk_sys` changes, every divider hanging off it is a change too.**

*Also found and corrected:* `sim/io/tb_m2_ioz80.cpp` documented a `+cendiv=12`
plusarg for real-rate pacing. No such plusarg exists or ever did -- it is an
elaboration parameter. And `test_m2_ioz80` is not in the default `test` target
and fails on its own today, before and after this change alike; it needs a
firmware image, which is a ROM and cannot live here.

**R199 — moving the video into the memory domain costs twelve crossings, and
four of them are real faults rather than timing numbers.** Recorded here because
they live on a branch that may not survive, and every one of them becomes
necessary again the moment `clk_mem` stops being an integer multiple of
`clk_sys`.

The move itself is one line -- `m2_video` and the character cache to `clk_mem`,
tile RAM and palette dual-clock. What follows is everything that was left behind:

```
control signals that stayed on clk_sys while their consumer moved
  character-cache invalidate      strobe AND payload
  colour translation table write  strobe AND payload
  cp_done, feeding the pixel mux
  rd_lat_sel, feeding cap_depth
  char_base, feeding port 3's address
  the character CDC, both its clocks
  ce_pix, which gates the framework's whole video chain
```

*Crossing a strobe does not cross what the strobe qualifies.* This cost two
rounds: `m2_cdc_pulse` on a write enable with the address still latched in the
source domain leaves the address crossing on its own, and it became the worst
path in the design both times.

**THE FOUR THAT ARE FAULTS, not slow paths.** Each would misbehave on silicon at
any clock speed once the domains differ:

1. `bd_ready` and `bd_band` read COMBINATIONALLY in the scan domain from
   registers in the fill domain (`m2_raster3d`). Two flops on the flag, and the
   index with it.
2. The video domain's reset RELEASED unsynchronised. Asserting late is harmless;
   releasing on an unsynchronised edge lets registers in one domain leave reset
   on different cycles. Async assert, sync release.
3. `scan_band` crossing back into the fill domain is a COUNTER, so a
   synchroniser is not enough -- sample a binary counter mid-transition and
   7 -> 8 reads as anything from 0 to 15, releasing a band the beam has not
   reached. Gray-coded.
4. The frame interrupt came from a SECOND `m2_video_timing` instance -- a
   duplicate generator whose only consumer was that interrupt, timing off
   something that draws nothing. It comes from `tile_vb` now, the blanking the
   picture is actually built from.

*Also learned, and cheap to lose.* The design's critical path was a
combinational divide by 62 in the boot-time test pattern -- about 22 ns from
`hcnt` through the colour mux to the pin, in an image the game never shows. That
fits a 20 ns period at 50 MHz by a whisker, which is the likeliest reason this
core has sat near -0.2 ns setup for weeks. Removing it is worth 4.8 ns.

*And the method, which is the transferable part.* Reading the RTL found none of
this. Every one came from `get_timing_paths` on a finished build, fixing the
named path, and rebuilding: -10.13 -> -5.32 -> -4.79 -> -3.88 -> -3.43 -> -2.80
-> -2.55 -> -2.47 -> -2.09 -> -1.57. Report DISTINCT endpoints -- ten copies of
one path reads like ten problems and is one.

**R200 -- the 3D test bars draw from band 13 down and not above it, and the
walk trigger has nothing to do with it.** Measured on hardware, seed 11 of
`build/area2`, with `3D test bars` on. Recorded so this test does not have to be
run again to remember what it said.

WHAT THE TEST IS. `status[21]` injects four known-good quads straight into
`m2_raster3d`, bypassing the geometry engine, the display-list walk and the
CPU entirely: `q_valid(tq_en ? tq_valid : q3d_valid)`. A bar that draws proves
the fill path, the band buffers, the scan-out and the whole video chain behind
them. `status[22]` picks between two layouts, and the layouts are the
measurement -- they put the same four quads at different heights.

```
                     size      y range   bands (/16)   drew?
  Wide    RED      240 x 20     80-100      5-6         NO
          GREEN     20 x 140   120-260      7-16        yes
          BLUE     240 x 20    280-300     17-18        yes
          YELLOW    20 x 140   120-260      7-16        yes
  Compact RED       80 x 20    140-160      8-10        NO
          GREEN     20 x 60    160-220     10-13        NO
          BLUE      80 x 20    220-240     13-15        yes
          YELLOW    20 x 60    160-220     10-13        NO
```

**EVERY QUAD THAT DREW REACHES BAND 13 OR LOWER. EVERY QUAD THAT DID NOT LIES
ENTIRELY ABOVE IT.** The cut falls in the same place in both layouts, at y=208
of 384. Size does not predict it -- Wide BLUE and Wide RED are the same 240x20
rectangle and only the lower one draws. Emission order does not predict it --
RED is first in both layouts, BLUE is third, YELLOW last, and in Compact only
the third survives. Shape does not predict it: horizontals and verticals both
appear in the drew and did-not columns.

*What that means, and it is not a display-list problem.* No CPU, no walk, no
SDRAM and no display list are involved in this path. The renderer is losing the
top half of the frame on its own. If that is the fill engine failing to stay
ahead of the beam over bands 0-12, then no amount of fixing the display list
would have produced a picture, because most of it would be dropped on the way
out. THE OPEN QUESTION that decides it: are Wide's GREEN and YELLOW bars full
height, or only their lower halves? They span bands 7-16, so a half-height bar
says the cut is real and positional; a full-height one says this reasoning is
wrong and the quad store is the place to look.

**THE WALK TRIGGER DOES NOT CHANGE THE BARS.** All four settings of `O[24:23]`
give the identical picture, and that is correct by construction rather than a
null result: the injector's state machine keys off `geo_walk_start`, which is
`vbl_d && !vbl_dd && !status[20]` -- the vblank edge -- and NOT off `trig_sel`,
which is the mux `O[24:23]` drives inside `m2_geo`. The two are different
signals. Do not re-run this combination expecting it to say something.

**THE BARS USED TO SHOW BEFORE THE FLIP FIX.** Recorded as reported rather than
as measured here, and it is a real regression clue, because `geo_walk_start`
shares its registers with the frame interrupt: R199 fault 4 moved `vbl_d` from
the duplicate `m2_video_timing`'s vblank to `tile_vb`, and `geo_walk_start` reads
`vbl_d`/`vbl_dd`. So the four-faults commit changed WHEN the injector fires as a
side effect of fixing what the CPU times off. That is the first thing to bisect
if the bars are worse now than they were: `build/four/s11` and `build/slack1/s5`
are on disk and one of them predates it.

*And a caution about this afternoon.* `m2_raster3d` was given `TWO_CLOCKS(0)` the
same day, which removes two cycles from band presentation and two from buffer
release. That is exactly the timing this test is sensitive to and there is no
before/after on it. Any conclusion drawn from a single build here is drawing on
two uncontrolled changes at once.

**R201 -- the HDMI slack cannot be reached by any setting available in Quartus
Lite, and two of them were spent finding that out.**

`MUX_RESTRUCTURE OFF` does not fit: **44,485 ALM, 106% of the device.** The flag
is worth ~6,800 ALM here. Model 1's `findings.md` (2026-09-07) measured the same
four flags as byte-identical no-ops on that core UNDER Aggressive Area, and that
finding does not transfer -- this design's mux structures are where its area is.
It stays on, and it is not available as a timing lever.

A LogicLock region on `osd:hdmi_osd` returned ALM, HDMI slack and clk_mem slack
IDENTICAL to the baseline to three decimals, because it was never applied:

```
Critical Warning (140003): Current license file does not support LogicLock
regions. The Quartus Prime software removes all the LogicLock regions in your
design automatically.
```

**LogicLock is a subscription feature and this project is licence-locked to
Quartus Prime Lite 17.0.** Check the feature against the edition before spending
a build on it. An experiment that silently degrades to the control looks exactly
like an experiment that ran and found nothing.

**R202 -- 0x030B IS THE MICROCODE'S FIFO WAIT, NOT A FLOW FAULT. THE 3D TASK IS
THE LAST OF 140 PER-FRAME TASKS AND THE BOARD'S WALKER NEVER DISPATCHES IT.**

*What the handoff of 2026-09-10 claimed, and why it was wrong.* "The
coprocessor is parked at PC 0x030B ... IT IS NOT STALLED ... if it were,
`copro_stall` would be high, and it is zero ... a microcode-flow fault."
`copro_stall` is `m2_copro.sv:303`:

    assign stall = fifo_rd && !fout_valid && !halted && !uploading;

That is the **i960** held on an empty *output* FIFO. It says nothing about the
TGP's *input* FIFO. The microcode, disassembled from the ROM
(`tools/extract_tgp_microcode.py`, then the Model 1 project's
`mb86233_disasm.py`):

    L_04c: b = rf1          ; the FIFO read -- replays until a word arrives
    ...
    L_055: a = 0x58 ; add_d ; goto_indirect   ; dispatch = 0x58 + command
    L_07d: goto L_30a       ; command 0x25
    L_30a: rf2 = load(0x68)
    L_30b: goto L_04c

`dbg_pc` reports the last *retired* instruction. A TGP stalled at `L_04c` on an
empty FIFO reports 0x30B, the `goto` that retired before it. R188 had already
recorded this ("ours at 030b, which is goto L_04c"); the handoff re-derived the
opposite from an instrument it had not read. **Read the code behind the number
-- R149's rule, broken again.** The four samples at 0x7D/0x52/0x4D are the
occasional command 0x25 the game still sends while idle.

*The reference's attract sequencer, measured with a Lua write tap on 0x5010a4.*
The dispatcher at 0x18a0 indexes the jump table at 0x18cc by the byte at
0x5010a4:

    frame 171  0x5010a4 <= 02   pc=00001978   (entries 0/1 -> 2, unconditional)
    frame 172  0x5010a4 <= 03   pc=00001CFC   (state 2's handler, one shot)
    then state 3 for 1600 frames (0x5010a8 = 25<<6), the 3D title

State 2's handler (0x197c-0x1d20) disables seven tasks, enables twelve with
their handler addresses, and among them registers the 3D task:

    0x1bf8  ld   r3, [0x501284]   ; -> 0x00510F80
    0x1c08  st   r5, 0(r3)        ; bit 31 set
    0x1c14  st   r5, 0xc(r3)      ; handler 0x5890

*The per-frame task list, dumped from the reference at frame 400.* The walker
at 0x1838 starts at 0x504000, takes its count from ROM 0x22f1f0 (= 140), and
for each entry calls +0xc if bit 31 of +0 is set, then advances by +8. **The 3D
task is entry 140 of 140, at 0x00510F80, the last one.** Entries 112-139 are 28
disabled 128-byte placeholders (handler 0x1894, a `ret`). Entry 111's handler
is 0x2200e4 (the model2o mirror of program ROM 0x200e4, which the bridge maps):

    0x2200e4  ld   r3, [0x501260]      ; -> 0x00510F00, entry 139
    0x2200ec  ld   r4, 8(g13)          ; this entry's size, 128
    0x2200f0  ld   r5, [0x5011fc]      ; the walker's remaining count
    0x2200f8  subo g13, r3, r3         ; bytes to skip
    0x2200fc  divo r4, r3, r3          ; entries to skip = 28
    0x220100  subo r3, r5, r3
    0x220104  st   r3, [0x5011fc]      ; count -= 28   (30 -> 2)
    0x22010c  ld   g13, [0x501260]     ; walk resumes at entry 139
    0x220114  ret

So the reference's walk is 112 iterations, 67 calls, the last call 0x5890, every
frame (three traced frames: 112/67, 111/66, 113/68). The render chain
0x16e58-0x17b00 is 2,948 instructions of ~108,000 per frame -- **2.7% of the
frame**, not a one-shot, and the mailbox routine 0x11620/0x1166c is not executed
at all in state 3 by the reference (0 of 108k in each traced frame).

*The board in the same phase.* The captures `c.txt`/`d.txt` of 2026-09-10 were
taken at walk frames 284-2012, i.e. inside state 3:

    tgp_pc     04C9/01D1/066A/048F ... -- the TGP is BUSY
    cpu ip     0x1166C 40%, 0x11674 9%     -- the i960 in the mailbox poll
    ip pages   0x11400-0x11600 executed (the reference's hot region)
               0x16E10-0x16E54 executed (a helper the car code calls)
               0x16E58-0x17B00: ZERO samples in 7,537 (590 frames)
    walk ops   3, every frame

A routine that is 2.7% of every frame gets ~200 samples in 590 frames at
1-in-65536. Zero is not a sampling artefact: **the board does not run the
render chain in state 3.** The TGP is busy because the car/track code
(0x116d0 -> 0x11620, called from 0xD2B8/0xD39C/0xD8E8/0xD9EC/0xDB30) queries it
through the buffer-RAM mailbox at 0x91fff0; that is game logic, not rendering,
and the reference does it without ever spinning at 0x1166c.

*And the direct count, decoded from the 2026-09-08 captures.* Build `2868625`
carried `b_addr = {state_last, n_state2, n_state_wr, tw_5890}` and
`b_data = {tw_1854, tw_1860, tw_1c14, 8'd0}`. `u1604.txt` and `uflip.txt`:

    03028000 FFFF2600     state 3, state 2 entered twice, 0x1c14 executed,
    03027600 FFFF2A00     walker head and callx saturated, tw_5890 = 0x00

**The task is registered, the walker runs, and the 3D handler is entered zero
times.** R195 attributed the 0x26/0x2A to `tw_1c14`; by the layout it is
`tw_1c14` in `b_data`'s third byte and `tw_5890` is `b_addr`'s low byte, which
is zero in both captures.

*What this leaves.* Everything between registration and dispatch is i960 plus
work RAM: the descriptor at 0x510F80 (bit 31, handler at +0xc), the pointer at
0x501260, the count at 0x5011fc, and the skip arithmetic. The plain boot bench
runs the identical RTL and reaches 0x5890 at frame 248, straight after the skip
handler (`M2_TRAP=0x5890`, IP ring: 0x2200fc 0x220100 0x220104 0x22010c
0x220114 0x1864 0x186c 0x1870 ... 0x5890). The i960 core is in-order and
blocks in `T_MULDIV` until `md_done`, so the `divo` feeding the next `subo` is
not a hazard. **The fault is in what the board's memory path returns or keeps
for those four words, and only there.** Instrumented in `build/walk`:
`wk_last_desc` (the address of the walker's `ld 0(g13)` at 0x1854 -- the last
descriptor walked), `sk_cnt` (the word stored at 0x220104) and `sk_ptr` (the
word read from 0x501260), with `tw_5890` and the attract state in the C record.
Reference values in state 3: last descriptor 0x00510F80, pointer 0x00510F00,
count 2.

*Three tools were broken on the way and are fixed in the same change.*
`tools/mame_i960_frame_trace.lua` never read `M2_FRAME` (compared `n == nil`
every frame, produced no trace); `tools/rom_csum.py`'s `build_image` walked
every `<rom>` in file order, and the I/O board's index-3 stream added on
2026-09-08 precedes index 0, so `M2_BOOT_IMAGE` put 64 KB of Z80 code where the
i960's boot record should be and the real-memory bench trapped on instruction
1; and the Makefile's `obj_boot_rm` source list predated the `fp_*` units the
video path now needs, so `make` reported a binary from August as up to date.

*Recorded because it cost the day before this one.* The "CPU at 100% speed is
the symptom" reading and the "microcode-flow fault" reading were both built on
0x030B; both are withdrawn. The observation that stands from 2026-09-10 is
R200's band-13 cut in the rasteriser, which is independent of all of this and
still open.

*MEASURED ON HARDWARE, `build/walk` seed 11 (setup -0.461, hold +0.214,
37,601 ALM), 2026-09-10 evening, 170 s from core load through the 3D title:*

    C samples 64,121   state 3 in 54,816 of them   tw_5890 = 0 in ALL
    H last descriptor the walker loaded:  0x00504E00 x920   0x00505D00 x3
    H skip count stored / pointer loaded: never written (0xEEEE) -- entry
                                          111's handler never ran

**The board's walk ends at entry 13 of 140.** Entry 13 is 0x504E00, whose
handler in state 3 is 0xD230 (the reference's list at frames 180-2400). The
same capture puts 45% of state-3 samples in the mailbox poll at 0x1166c, which
the reference never executes in state 3. Minutes later the board was frozen on
one frame: 98% at 0x1166c/0x11674, TGP at 0x04C9 in 100% of samples, state
still 3, walker still at entry 13. Microcode 0x4c2-0x4c9:

    L_4c3: x1 = load(0x6e)        ; the mailbox address
    L_4c4: move_mode0(0, (x1))    ; THE CLEAR -- data-RAM word 0 (= 0) to it
    L_4c9: goto L_04c             ; back to the FIFO wait

so a TGP reporting 0x4C9 has issued its clear and gone idle, and the i960 is
still reading the armed value at 0x91fff0. The clear never became visible to
the CPU. The same signature -- TGP 0x04C9 at 100%, IP 0x1166C -- is in eight
of the 2026-09-10 morning captures (g16, vb, ns, t1, t2, a, b, p) from other
builds of the day; `build/area2` s11 is the build where the poll eventually
completes, and even there it takes half of every frame. The walk never
reaching entries 14-140 -- the car handlers, the 0x22xxxx tasks and the 3D
task -- is the consequence: entry 13's handler chain is the one that queries
the TGP through the mailbox, and it does not return until the clear lands.

*What that excludes and what it leaves.* The bridge never retains a buffer-RAM
line (`BUFFER_NOCACHE`, fill suppression), so the poll is a real SDRAM read
each time. The TGP's write is two 16-bit halves through the shared write port
(`s_wr_*` in Model2.sv:813, one broadcast `ldr_wr_ack`, the request dropped
between halves as m2_tgp.sv:630 documents), the controller starts a write on
the request's rising edge, and `ACK_HOLD` is two fast cycles -- shorter than
the TGP's turnaround, so a held acknowledge retiring the second half early does
not fit the numbers on paper. What does fit is the path itself: "every failing
path in build 56 was exactly that" (Model2.sv:512, the write-port mux into
m2_sdram's wr_addr_p), the walk build missed setup by 0.461 ns, and the hang is
build-dependent. The instrument that settles it is `tgp_mbox` (what the TGP
wrote to 0xFFF8/0xFFF9) against the CPU's readback of 0x91fff0
(`cpu_dbg_ldout` at that address) and a count of completed port writes to word
0xFFF9, on a build that closes timing.

*The real-memory bench cannot see any of this yet.* `REAL_MEM` wires the CPU
and character ports only; the TGP's port 9 and the shared write port are still
served from C++ (study R163's standing debt). It did reproduce something of its
own: with the harness's read-capture selector pinned at 3 the CPU runs 17.5M
instructions and then fills a register frame from ROM 0x140 (frame pointer
0x100) two instructions into state 2's handler, deterministically, with every
work-RAM read shadow-checked correct (2.66M reads) and every full-word ROM read
matching the image; selectors 0, 1, 2 and 4 do not boot at all. Left open as a
harness question, not a board finding.

*`build/walk2` s11, same evening (setup -0.242, HDMI PLL path only; hold
+0.186).* Count from ROM 0x22f1f0 = 0x8C = 140 in every sample. The walker's
last stored count is 0 in 54 state-3 samples and 0x70, 0x6C, 0x24, 0x17, 0x10
in others: on this build the walk runs to the end of the list every frame,
and it is slow enough to be sampled mid-walk. The last handler it loaded is
0xC9C4 in 920 of 923 samples -- the car handlers' init state, which the
reference passes through in one frame (C940 -> C9C4 at frame 161, CF74 at
162, D230 at 164; the CF74 install is task 0x226360's placement routine at
0x2264E4). By handler range, state-3 IP samples on the board:

    entry 1 (17B94) 14   entry 6 (BA18) 3   entry 11 (4DF8) 15   entry 12 (120A4) 3
    entries 13-32 in C9C4: 4,854            entries 57/59/61/63/67: 0
    entries 75-111 (0x220010-0x2231C0): 0   entry 140 (5890): 0   render chain: 0

**Every task whose descriptor lies above 0x50D000 is never executed on the
board; every one below 0x508800 runs.** The same registration code enables
both groups (state 2's handler, 0x1a44-0x1c60, all `ld; setbit 31; st` through
pointers at 0x5012xx), and the disable loop it runs first covers entries
76-139 in the reference and is undone by the tasks that follow. This is not
the mailbox: the mailbox is why the walk is slow, not why those tasks are
dead. The candidates are the enable stores not landing, the walker's
descriptor reads being served stale (the bridge's write-through-invalidate
data cache, 2048 lines of 8 bytes indexed by address[13:3], sits between
them), or a later clear. `build/e140` measures entry 140's word 0 and handler
as the walker reads them.

*`build/e140` s13, later the same evening (setup -0.400, hold +0.242).* Entry
140's word 0, as the walker's `ld 0(g13)` returns it: 0x00000000 in all 923
state-3 samples; the walker loaded it TWICE in 9,000 frames; the handler word
was never loaded. The stored count still reaches 0 every frame. So the walk is
not advancing at all: a size field that reads 0 makes `addi r7,g13,g13` a
no-op and the walker spins on ONE entry for the rest of its count, calling its
handler each time. That is entry 13 -- the player car, 0x504E00, handler
0xC9C4 -- and it explains every number at once: 0xC9C4 dominating, the mailbox
queried ~127 times a frame (0xC9C4 calls 0x11620 at 0xCA50), entries 14-140
never called, the count reaching 0, entry 140 loaded twice (before the
corruption), and `build/walk`'s last descriptor 0x504E00 in 920 of 923.

*Why the size field is zero, and it is R82 again.* The reference writes entry
13's header every frame: `stos g2, 6(g9)` at 0x6FA0, a halfword into the UPPER
half of dword +4 (Lua tap: `write 00504E04 mask FFFF0000 pc=6FA4`, every
frame; +8 is written only at init and holds 768). In `m2_cpu_bridge` an
upper-half store is one real 16-bit write followed, in `S_LO_W`, by a SECOND
write to the next word -- `sd_din = 0, sd_be = 2'b00` -- that trusts DQM to
mask it. R82 measured that the byte enables do not survive to the silicon (a
byte store landed in all four lanes). So that dummy write lands 0x0000 on the
low half of the following dword, which for 0x504E06 is the size field at
0x504E08. 768 is 0x0300, all in the low half; the field becomes 0. Both
simulations honour the mask, which is why neither ever showed it, and why
the plain bench reaches the 3D task while the board does not.

*The fix, and it is one branch:* an upper-half write completes after its one
real word; no write is ever issued whose correctness depends on the mask
(`m2_cpu_bridge.sv`, `S_LO_W`). `build/fix` carries it together with the
entry-13 probes (size as read, last writer, handler loads per frame), so the
same capture that proves the mechanism proves the repair: size back to 768,
one handler load a frame, `tw_5890` climbing, the walk reaching entry 140.
`build/e13` (the probes without the fix) is the control.

*What is still owed after that.* The DQM path itself (R82's open item: the
mask is right in source and lost in silicon, so every remaining partial-word
write is suspect until the controller's DQM timing is measured); the shared
write port for the TGP's mailbox clear (the frozen `build/walk` symptom);
and the two throughput problems now visible -- the TGP blocking on SDRAM for
every data access, and the CPU's unposted write-through stores (race mode:
77% of the i960's time in a `stq` fill loop at 0xE414).

*`build/fix` s13 (setup -0.433, hold -0.197), on the board 22:09, 170 s:*

    entry 13 size as the walker reads it     0x00000300 in all 923 samples
    last writer of 0x504E08                  ip 0x1734 (init), data 0x0300
    handler loads of entry 13 per C sample   median 0, max 2  (was ~127/frame)
    render chain 0x16e58-0x17b00             5,048 samples   (was 0)
    0x5890                                   118             (was 0)
    0x22xxxx tasks                           3,720           (was 0)
    0xD290 (cars running)                    245   0xC9C4 (cars in init) 52
    mailbox poll 0x1166c/74                  239             (was ~10,000)
    frame wait 0x12b0/b8                     31% of samples  (CPU has slack)
    TGP                                      0x030B idle 38%, working the rest

**The mechanism is confirmed and the repair holds.** The board's attract now
runs at speed and the background moves for the first time (reported from the
screen: it jumps rather than scrolls, twice, on this build with hold -0.197).
No polygon is on screen yet: the game emits geometry every frame now, so the
question has moved downstream to the geometrizer and rasteriser, which had
never been fed real data on hardware, and to R200's band-13 cut. Next build:
the fix plus the geometry counters (matrix pushes, walk opcodes, polygons,
clipper output, quads to the rasteriser) on the wire, at four seeds.

*`build/geo` s11 (fix in; setup -0.399, hold +0.208), 22:40, the geometry
counters:* matrix pushes saturate their 12 bits within seconds; walk opcodes
per walk 286 typical, up to 2,050 (was 3 all day); **polygons 0, clipper in
0, clipper out 0, in every sample.** The front door and the walk are fed and
working; the geometry engine emits nothing from the objects it is handed.
Next: objects dispatched against objects finished, MAX_POLYS caps (an object
whose polygon data reads 0xFFFF), the walk state, and the last polygon-ROM
word the engine read -- which separates "the engine never starts", "it
starts and never finishes", and "it reads the wrong memory".

**R203 -- THE TGP'S MATH TABLES HAVE BEEN READ 64 KB LATE ON HARDWARE SINCE
THE DAY THEY WERE ADDED. THE "MEASURED GAP" WAS THE IMAGE BUILDER PREPENDING
THE I/O BOARD'S ROM.**

The index-0 image built tonight (`tools/rom_csum.py`, index 0 only) holds the
tables' first words -- `00000000 38c90fdb 39490fdb`, sin of 0, of 2pi/65536,
of twice that -- at byte **0x2BA0000**, directly after the comms program, where
the MRA's own arithmetic puts them. `GAME_TGPTBL` is word 0x15D8000 = byte
0x2BB0000. The entry of 2026-08-30 that set it ("the offset is measured, not
counted ... a 64 KB gap, in the same direction as R88/R89") measured an image
built by `build_image` walking every `<rom>` in file order, two days after
d339a3a put the 64 KB I/O firmware in `<rom index="3">` AHEAD of index 0 in
the file. The gap was that ROM. The board's loader sends each index as its own
stream; it never had the gap. R89 had already reversed R88's identical gap for
the sound ROM for the same reason, and the lesson was not carried across.

So on the board, every sincos, atan, inverse and inverse-square-root lookup the
coprocessor has made since 2026-08-30 returned a word 64 KB into the table. The
bench never saw it: it loads the table files at the RTL's base. That is the
strongest available explanation for tonight's `build/geo` numbers -- matrices
pushed, thousands of opcodes walked, zero polygons -- since garbage trig gives
garbage matrices and the geometry's nonfinite gate refuses what results; and
for the camera that jumps rather than scrolls once the cars are placed.

Fix: `GAME_TGPTBL = 0x15D0000`. `build/tbl` (four seeds) carries it with the
bridge fix and the object-stage probes. Polygon ROM (0x1640000), copro data
ROM (0xA40000) and the program were checked the same way and are where the
RTL reads them.

*Rule, and it is R149 again from the other side:* a base "measured" from an
image is only as good as the tool that built the image. When the MRA's
arithmetic and the built image disagree by exactly one ROM's size, suspect the
builder before recording a gap.

*`build/tbl` s13 (both fixes; setup -0.171, hold +0.240), 23:16 and 23:20, two
captures:* objects dispatched == objects finished, 147 then 264 a frame, none
capped, the engine's last polygon-ROM words real floats (BF22E53A, BE649C34,
BF63AC92 ...). The object stage consumes every object it is handed. On screen:
still no polygon; the background now pans slowly left and right (the title
camera's orbit, which needs correct trig -- the table fix is real) and jumps
vertically fast (the vertical scroll being taken at the wrong moment; R199
moved the vblank the tile layers latch from). `build/poly` carries polygons
produced : refused nonfinite | clipped out : quads to the rasteriser, and
clip drops; the scroll values the renderer used are the build after.

*`build/poly` s13 (both fixes; setup +0.275, hold +0.241 -- the first fully
closed build of the day), 23:50:* objects finished 264 a frame, and
**polygons 0, nonfinite 0, clipped out 0, quads to the rasteriser 0, clip
drops 0.** The engine walks every object to its end and emits nothing. Its
own rule for that: an attribute word with bits [1:0] clear ends the object
(`m2_geo_engine.sv`, E_ATTR).

*And the plain bench, with both fixes, does not do much better in the same
phase* (20M instructions, frames 246-293, the first 47 frames of the 3D task):

    matrix writes decoded 1,277   focal 51   objects 1,853
    polys 18   capped 36   nonfinite 16,384 (saturated)
    clipper in 65,535 (saturated)  out 1,410  dropped 65,535
    QUADS OUT 1,410, all degenerate at the right screen edge:
      (496,78) (493,80) (496,79) (496,79) ... (495,38) (495,38) (495,37) (496,37)

So the geometry below the walk is now the open question, and it is open AT
THE DESK: the bench produces quads and they are wrong -- vertices collapsed to
one edge, which is what a projection with z near zero or a matrix whose
translation row never applies looks like (Model 1's "vertices collapsed toward
the origin"). The "3,038 polygons per frame" this study quoted for the bench
came from a phase and a build that no longer exist, and was never a picture.
The board's zero, against the bench's 1,410 degenerate quads, is the same
pipeline one step further down: with the timing the board has, the objects
end at their attribute word. Next: the plain bench, `M2_TRAP` at the first
E_EMIT, and the matrix and focal values the walker captured against MAME's
for the same object -- no fitter needed for any of it.

*`build/scr` s13, 00:40: the vertical scroll of layers 0 and 1 as the
renderer reads them is 0 in all 56,579 samples.* The fast vertical jump is
not those registers changing. Left open (layers 2/3, horizontal, or the
band/frame presentation are the remaining candidates); the 3D comes first.

*The engine's inputs, from the bench with both fixes (first 3D frame):* raw
object point (0, 0.11, 2.47), matrix rows (-0.707,-0.5,-0.5) (0,0.707,-0.707)
(0.707,-0.5,-0.5) -- orthonormal, so the twelve words are captured in order
-- translation (-67.5, 48.5, 60.0), focus (280, 280). The transformed point is
the translation, 1.1 rad off-axis, outside a 280-focus view; every emitted
quad is a sliver clipped on the right plane at x 493-496. The reference's
first matrix of ITS first 3D frame (frame 173, front-door tap, opcode 0xB
followed by twelve data words) is a near-identity rotation with translation
(0.48, 0.47, 140.5): centred. The game computes these matrices through the
coprocessor, so the next comparison is the coprocessor's answer stream, word
by word, bench against reference, from the start of state 3.

**R204 -- THE PLAIN BOOT BENCH HAD BUFFER-RAM READS DISABLED, SO EVERY MAILBOX
ANSWER IT EVER GAVE THE GAME WAS ZERO. WITH READS ON, THE TGP'S ANSWERS ARE
REAL AND DIFFERENT FROM THE REFERENCE'S.**

`Makefile`'s `BOOT_BUFFERRAM ?= 0` ("the configuration that WORKS on
hardware") built the bridge with `BUFFERRAM=0`; the board's Model2.sv
instantiates it with `BUFFERRAM=1`. With 0 the CPU's reads of 0x900000-
0x97ffff return zero by construction: the mailbox poll at 0x1166c exits at
once and the placement answers at 0x91fff4/0x91fff8 read as zero, while the
TGP's writes of them land unread (logged tonight at words 0xFFFA-0xFFFD from
microcode 0x511/0x515, then the clear from 0x4c3). So the bench "reached the
3D task" with every car placed from zeros, the camera followed them off the
scene, and its 1,410 degenerate quads were the consequence of the bench, not
of the board. The default is now 1.

With `BOOT_BUFFERRAM=1`, same inputs as the reference (verified word for
word: 0x17ffc, 0, 0x1057, 112.0, 0x430A7E7E ...), the answers the CPU reads:

    bench      bdcccccd 000003df   bdcccccd 000003de   bdcccccd 000003e5 ...
    reference  80000000 00000146   80000000 0000014a   80000000 0000014a ...

The first word is the microcode's "not found" default (-0.1, the same
constant the i960 substitutes at 0x116b4 when it gets zero) and the segment
index is wrong. The track lookup (0x481-0x4b5, copying 12-word records from
the TGP's data space and comparing in float) is not finding what the
reference finds. Microcode, tables and inputs are identical; what remains is
the data it reads -- the copro data ROM through port 9 and buffer RAM -- or
the arithmetic of the loop. MAME exposes the TGP's data space to Lua, so the
reads themselves are comparable, and that is the next diff.

**R205 -- THE TGP WRAPPER ANSWERED A WINDOWED READ OF ROM WORD 0x20 WITH THE
SINCOS UNIT, SO THE TRACK-LOOKUP RECORD BASE WAS ZERO AND EVERY PLACEMENT
QUERY RETURNED "NOT FOUND".**

The mechanism, instruction by instruction from the boot bench with buffer-RAM
reads on (`obs_tgpx_*` taps on `core.u_regs` and `core.u_mem.ram0`):

    sub_7cb  a = 0x800000 (0xFF800000 sign-extended), rf3 = a   bank ON
    0x7cf    d = load_even((bx1)), b1 = 0x10   -> d = 0x00000030      right
    0x7d1    $0x69 = 0xFF800030                                       right
    0x7d3    d = load_even((bx1)), b1 = 0x20   -> d = 0x00000000      WRONG
             (the bus returned 0x00019C90 for ROM dword 0x20: logged)
    0x7d5    $0x6a = 0xFF800000                 should be 0xFF819C90
    lookup   0x486 d = idx<<4 = 0x1440, 0x488 d += $0x6a = 0xFF801440,
             0x48b d &= 0xffff, x0 = 0x1440: the record is fetched at ROM
             dword 0x1440 (zeros) instead of 0x1B0D0 (the records live at
             0x19C90 + idx<<4; the candidate list itself, at $0x69 + r5, was
             read correctly: count 6, indices 0x144 0x145 0x146 ...)

`m2_tgp.sv`: `io_mid = (io_addr[15:5] == 1)` and `sel_math = io_mid && ...`
were not gated by `win_en`, and the read mux ranks `sel_math` above
`sel_rom`. With the bank on, io 0x20 is the sincos unit's read port, not the
banked ROM. R156's full form gated `io_mid` too; the narrow form kept the
math units reachable through the window because "on the board it cost the
tilemap -- the TGP hung, the i960 stalled on its next FIFO read". Tonight's
R202 (the masked dummy write) and the shared write port are the likelier
owners of that hang; the gate was innocent and its removal was the fault.
MAME's model is the arbiter: the view is installed over the whole io space
after the math units and hides them while selected.

Fix: `sel_math = !win_en && io_mid && ...`. Unit tests: fp_mul, fp_add,
fp_div, mb86233_alu, mb86233_agu clean; mb86233_regs' 46,966 failures on
register 0x21 are the ones the handoff already records.

*How it was found, for the record.* Not by reading. By a chain of
measurements each of which named the next: polygons 0 on the board -> the
bench's quads all on one screen edge -> the transform's inputs (matrix
translation 1.1 rad off-axis) -> the reference's matrix for the same frame
(centred) -> the coprocessor answer streams -> the placement query answers
(bench zero, then bench -0.1/0x3DF against reference -0.0/0x146) -> the TGP's
external reads (candidates right, records fetched with no base) -> the
init routine's register trace (d = 0 after one specific windowed load) -> the
decode. Eleven bench runs of four minutes each, no fitter.

*With R205 in, the bench's scene is in view for the first time.* Placement
answers identical to the reference's sequence; 3,342 quads over frames
246-275 spanning x 0-496 and y 0-384, 2,303 of them wider or taller than ten
pixels, chains of adjacent quads tracing lines (curbs, road edges):

    x bins (62 px): 1131 246 210 119 119 266 389 862
    y bins (48 px):  763 460 525 1382  87  48  60  17

The harness has no rasteriser (`q_ready` tied high), so its captured frames
show the tilemap only; the quads' screen coordinates are the bench's whole
picture of the 3D. One coprocessor divergence remains under investigation:
for command 0x2A (six pushes, unconditional) the bench's trace shows three
reads where the reference shows six -- either the output FIFO drops words
under load, or the trace's completion sampling misses them.

*Closed the same hour:* `WORDS DROPPED in=0 out=0` over the whole run. The
three-of-six was the trace sampling io_sel on the 24 MHz CPU clock while the
bridge pulses it for one 50 MHz cycle; completed reads fall between samples.
Nothing is lost between the coprocessor and the CPU.

**R206 -- ON THE BOARD THE ENGINE'S FIRST READ OF EVERY OBJECT WAS RETIRED BY
THE WALKER'S HELD ACKNOWLEDGE, WITH THE WALKER'S DATA. R167 ONE LEVEL DOWN.**

`build/tgp` s11 (R202+R203+R205, setup -0.263, hold +0.175), 01:45: objects
dispatched == finished; polygons 0, nonfinite 0, clipped 0, quads 0. The
bench with the same RTL draws 3,342 quads. What the bench does not have is
port 4. `Model2.sv`: `eng_mem_ack_r <= p_ack[4] & eng_mem_req_r`, no
ownership; `m2_sdram` holds every acknowledge ACK_HOLD cycles; `m2_geo` lets
the engine start the cycle the walker's last read completes. So the walker's
held ack retires the engine's first read, and `eng_mem_data_r` -- latched
from p_dout[4] every cycle -- hands the engine the walker's display-list word
as the object's attribute word. Bits [1:0] clear is "object done"
(`m2_geo_engine.sv` E_ATTR). Every object, every frame. The "last
polygon-ROM word read" the `build/tbl` probe showed as floats were the
walker's matrix words for the same reason.

The interlock of R173 makes the two requests never overlap; it says nothing
about the acknowledge outliving the request that earned it, which is exactly
R167's mechanism. Fix: an acknowledge counts only on its rising edge for the
request that is up, and neither owner presents a request while an
acknowledge is still up (`p4_ack_d`). Not simulable here -- the boot harness
serves the engine from C++ with its own acknowledge -- so it goes straight to
the board with the polygon-path probes still on the wire.

*R206 did not change the board's numbers.* `build/p4b` s17 (all four fixes,
setup -0.176, hold -0.045), 02:03: objects finish, polygons 0, nonfinite 0,
clipped 0, quads 0 -- identical to `build/tgp` s11 before it. The fix stays
(the hazard it closes is real by construction) but it was not what stops the
engine, so the mechanism described above is not confirmed on the board and
is recorded as unconfirmed. What has still never been measured is the
engine's own read stream on the board. The bench shows an object's stream
begins with two points, six words, before its first attribute word
(`engrd 0..6`: 00000000 3de147ae 401e147b bf266666 3de147ae 4017ae14 then
attr 989c1501), so an object that ends at its first attribute check has
taken seven reads. `build/eo` (four seeds) latches the engine's first read
per object -- data and index, with the object's base select -- and the read
count of the previous object.

**R206 WITHDRAWN, 02:30.** `build/eo` s11 (R206 in, plus the engine-first-read
probe): first-read data 0x00000000, index 0, base select 0, reads per object
0, in all 1,078 samples, with the CPU's render chain running as before. The
engine never completed a read: the gating deadlocks the handover on the
board, where the ungated form lets the engine finish 264 objects a frame.
The mechanism R206 described remains a paper argument; the board contradicts
its fix. Reverted to the R173 form; the probe stays in for `build/eo2`.

**R207 -- ON THE BOARD THE WALKER HANDS THE ENGINE THE OBJECT'S COUNT AS ITS
ADDRESS: THE DISPLAY-LIST STREAM ARRIVES ONE DWORD AHEAD.** `build/eo2` s15
(R202+R203+R205, R206 withdrawn; setup +0.008, hold +0.239), 02:55:

    engine first-read index   0x001388 x766, 0x00002F x168, 0x000000 x126
    first-read data           0x07800000 x766, 0x00000000 x312
    base select [24:23]       0 (slow polygon RAM) x892, 3 x168, 2 (ROM) x18
    reads per object          12 x952

The bench, same RTL, same phase (`EOBJ`): first index = the object's own
address (0x95FF9D, 0x13B, 0x961BBF ...), base ROM, 137 to 3,597 reads per
object. 0x1388 is `obc`, the polygon count every Daytona object carries
("last object: oba=0095e0c6 obc=00001388"). So on the board `oba` receives
the word that follows it: the walker's reads of buffer RAM through port 4
return the NEXT dword. The engine then reads twelve words of slow polygon
RAM at 0x1388 (0x07800000 ...), hits an attribute word with clear low bits,
and ends. Twelve reads, every object, every frame; polygons 0.

A stream one word ahead also shifts every matrix, focal and light the walker
captures, which is what the "vertices collapsed toward the origin" grey
pixels of R195 were, and why nothing ever matched the bench. The bench's
`geo_tick` answers the walker in the same cycle from C++; the board's port 4
is an edge-triggered request with a held acknowledge and a registered
address. The next step is to give the bench the board's handshake latency
on port 4 and watch the stream shift at the desk.

**R208 -- R207 CLOSED: THE STREAM ARRIVED ONE WORD AHEAD BECAUSE THE WALKER
AND THE ENGINE TOOK THE ADAPTER'S HELD ACKNOWLEDGE AS A NEW ONE, EVERY CYCLE.
THE FIX IS IN THE REQUESTERS, NOT THE GLUE.** 2026-09-11, 03:40.

*The mechanism, from the RTL.* `m2_sdram_x2` (R162) answers a port with
`s_ack = f_ack | done`, and `done` clears only when the slow side lowers its
request. `m2_geo` asked for its display-list words as a LEVEL -- `rd_req` was
true for the whole of every reading state and `w_ip` advanced on each
`rd_ack` -- and `m2_geo_engine` did the same with `mem_req`/`ptr`. So one
acknowledge, held by `done` for as long as the request stood, was consumed
on every cycle it was up: the walker stepped its index once per cycle with
the SAME data word, the port never issued the next read (`f_req` is masked
by `done`), and the words the walker actually captured were whichever the
held data happened to be when a state changed. The engine's stream was
skewed the same way. R206 saw the acknowledge outlive its request and put
the fix in `Model2.sv`'s port-4 glue, where it deadlocked; the glue cannot
drop a request that the module behind it holds, and it cannot know which
cycle the module meant to take.

*Reproduced at the desk, then cured.* The boot bench served the walker and
the engine in the same tick from C++, which is why 3,132 quads were drawn
there while the board drew none: an instant answer never outlives its
request. `M2_GEO_LAT=N` now makes the bench serve both port-4 requesters as
the adapter and the glue do it -- the request registered (`geo_rd_req_r`),
a read issued when it stands with no `done`, `done` set on the fast
acknowledge and cleared only on a cycle the registered request is low, the
acknowledge `f_ack | done` reaching the requester a tick late, the data
held. The model must run on EVERY tick, not only on request ticks; the first
version ran only while the request was up, never saw the gap, and hung the
walker on its own stuck acknowledge (frames 0). Same RTL, same phase
(`+insn=19500000`, `M2_POLY_FROM=17000000`), instant service vs latency 6:

                                      instant   held ack, N=6   held ack, N=6
                                                 (RTL before)    (RTL fixed)
    walk frames / objects           80 / 1250      43 / 38        80 / 1240
    walk ops at the end                  404        32767 (bound)      404
    quads out of the clipper            3132            0            3132
    engine first read, object 1     0x95FF9D            -         0x95FF9D
    polygon_data dwords delivered      32768        49152           32768

The held-ack trace (`M2_GEOTRACE`) shows the old walker taking the
acknowledge on 30 consecutive ticks with `w_ip` already moved on, exactly
the board's "first read at 0x1388 = obc" of R207. The fixed walker takes
one word per acknowledge edge, drops its request for one cycle, `done`
clears, and the next read issues: ten ticks a word at N=6.

*The fix (`m2_geo.sv`, `m2_geo_engine.sv`).* Two rules, in the requester:
an acknowledge counts only on its rising edge (`rd_go = rd_ack & ~rd_ack_d`,
at all eleven consume sites including `mat_we`; `mem_go` at the engine's
five), and the request is lowered for the cycle after each accepted word
(`rd_req = ~rd_go_d & (reading states)`). Through the glue's register stage
that gap reaches the adapter two cycles later, `done` clears the cycle
after, and the acknowledge falls before the next word's rises. m2_sdram's
ACK_HOLD is 2 fast cycles = 1 slow, and the request returns five slow cycles
after the edge, so the held fast acknowledge cannot re-arm `done` for the
next word (the R167 shape) either. The per-object read count in the bench
triples under the model (3597 -> 10791) because it counts acknowledge
ticks, not words; the first-read index and data are identical.

*Why every port-4 requester has to obey both rules, and what else does not.*
The CPU bridge and the TGP data port drop their requests on the acknowledge
(state machines that leave the requesting state), so they were never
exposed. Anything added to a shared port that holds a level request across
consecutive words repeats R207; the bench's `M2_GEO_LAT` model is the test
for it and must be run on any new requester. Unconfirmed until the board
says so: `build/ack` (seeds 11, 13, 14, 15) is the first bitstream with the
requester-side fix and no glue gating, probe still on the wire.

*Confirmed on the board, 04:05.* `build/ack` s14 (R202+R203+R205+R208, setup
-0.149, hold +0.242; s11 died in the fitter's TDC module, s13 -0.783/-0.311,
s15 -0.282/+0.242), 170 s capture through the 3D title, same probe layout as
`build/eo2`:

                              build/eo2 s15 (before)    build/ack s14 (after)
    engine first-read index   0x001388 x766 (= obc)     0x15FF9D, 0x5AE5, 0xAA7C ...
    first-read data           0x07800000 x766           0x00000000, 0x3F800000, floats
    base select [24:23]       0 x892                    1 (ROM) x909, 0 x168
    reads per object          12 x952                   255 (saturated) x709, 51, 231 ...
    polys / clip out / quads  0 / 0 / 0                 50048 / 17001 / 22271 (16-bit, wrapping)
    render chain samples      running                   6459 of 64121; task 0x5890 93

0x15FF9D is the bench's first object (`oba=0095ff9d`, 22 index bits kept)
with the same base select; the board's stream now begins where the bench's
does. The engine reads whole objects, the clipper passes polygons and quads
are handed to the rasteriser -- the first 3D geometry to reach it on
hardware. Whether it draws correctly is the next question (R200's band-13
cut is still open); nonfinite stays high (37749 at mid-capture) as it does
in the bench (32768, capped), which is the unwritten-memory 0xFFFFFFFF
objects, 39 of them in the first-read data here.

**R209 -- THE SHARED WRITE PORT WAS A COMBINATIONAL MUX OF FIVE OWNERS, AND
TWO OF THEM ALTERNATING WEDGED IT: THE COPROCESSOR'S MAILBOX WRITE AND THE
PUSH DMA BOTH WAITED FOREVER. GRANTED PER TRANSACTION NOW, ROUND-ROBIN.**
2026-09-11, 06:40-08:00.

*What the board showed.* `build/ack` s14 after ~3 minutes in the 3D title:
every sample with the i960 in the mailbox poll (0x1166C/0x11674, 77%; the
rest in the car handlers), the TGP at 0x046E in all 15,087 samples, every
geometry counter frozen at one value (polys 50,060, quads 6,655), the
engine probe frozen on one object. A second boot ran seven minutes with no
hang -- a race, not a deterministic fault. 0x46E retires with 0x46F in
flight, and 0x46F is `mov {0} $2, (x1)(e)`: the TGP's write of 0xFFFFFFFF
into the mailbox dword 0x7FFC at the start of a job. A buffer-RAM write in
`m2_tgp` waits on `wr_done`, and that comes from the SHARED WRITE PORT, not
port 9. The earlier freeze "TGP at 0x4C9, the clear at 0x4C4 issued and
never seen" (09-10, `build/walk` s11) is the same family: a TGP buffer
write that never landed.

*The mechanism, from the RTL.* `m2_sdram_x2`'s write side: `f_wr_req =
s_wr_req & ~w_done & ~f_wr_ack`, `w_done` set on the fast acknowledge and
cleared ONLY on a cycle `s_wr_req` is low, `s_wr_ack = f_wr_ack` (one
pulse). `m2_sdram` takes a write on the RISING EDGE of `wr_req` and latches
address and data then. `Model2.sv` drove `s_wr_req` from a fixed-priority
mux: initialiser, store engine, `tgp_bufw_req_r`, push DMA (`geo_sd_busy ?
geo_sd_req`), loader; the TGP's acknowledge qualified by its own request,
the push DMA's NOT qualified at all (`.sd_wr_ack(ldr_wr_ack)`).

So: the push DMA's low half is in flight; the TGP raises `tgp_bufw_req_r`;
the mux switches address and data under the transaction and the composite
request stays high. The DMA's acknowledge arrives: the DMA retires (its
ack is unqualified) AND the TGP retires (`ldr_wr_ack & tgp_bufw_req_r`)
though nothing of its was written; `w_done` is now set with `s_wr_req`
still high. The TGP drops its request for one cycle, the mux falls through
to the DMA's high-half request, already up: `s_wr_req` never falls,
`w_done` never clears, `f_wr_req` never rises again. The DMA waits in
D_NEXT, the TGP waits at 0x46F for a `wr_done` that needs an acknowledge
the port will never make, the i960 waits for a clear the TGP will never
reach. It needs the two to collide within a few cycles, which the 3D title
makes likely: the walker and engine now run (R208) and the game pushes a
full display list while the TGP writes results.

*The fix: `rtl/mem/m2_wr_arb.sv`.* One owner at a time. The port is
GRANTED to a requester, held from its request to its acknowledge, released
with a dead cycle so `s_wr_req` is low for two fast cycles and `w_done`
clears, and each owner sees only the acknowledge of its own transaction.
Model 1's `t_owner_change` (m1_integrated.sv: suppress the request on the
cycle the owner changes, qualify acks by owner) is the same idea for two
owners that never preempt each other mid-transaction; here they can, so the
owner is held. Four owners hold their request until acknowledged (bi, st,
m2_tgp's `wr_pend`, m2_geo's D_LO/D_NEXT). *The ROM loader does not, and
the first arbiter broke the ROM load on the board (`build/wrarb` s11,
08:10): `m2_rom_loader` PULSES `sdr_wr_req` for one cycle ("req pulsed so
the controller sees a rising edge") and waits for the acknowledge with the
line low. The arbiter granted on the pulse, found the request gone the next
cycle, released without issuing the write, and the loader waited forever;
ioctl_wait then held the HPS. The claim above that all five hold was made
from the loader's HARNESS (`sim/mem/m2_romload_harness.sv`, which has a
`wr_pend`), not the loader. Fixed the same hour: the arbiter latches a
request per owner until that owner's acknowledge (`pend`), holds the port
from grant to acknowledge whatever the owner's line does, and the test's
loader slot now pulses. Board restored to `build/ack` s14 meanwhile.*

The unit test (`sim/mem/tb_m2_wr_arb.cpp`, `make test_m2_wr_arb`) models
the adapter's write side exactly -- edge-taken request, latched address and
data, one-pulse acknowledge, `w_done` cleared only on a low-request cycle
-- with the TGP's slot asking every cycle and the DMA's slot asking in
halves, and checks every write lands once, with its owner's address and
data, and that the port never idles with a requester waiting. It found
the second fault before the board could: under the mux's FIXED PRIORITY
with the TGP's slot busy, the push DMA and the loader were never served at
all (0 of 2,500 writes). The TGP's vertex loop writes buffer RAM
continuously, so the display-list DMA would have starved behind it. The
grant is round-robin from the owner last served. Latencies 1, 5, 12, 30:
all owners served, no write lost, longest idle 3 cycles. Cost: two dead
slow cycles per write on the shared port; the push DMA's queue (128) is
the buffer against it, and `geo_dropped` is the counter to watch.

*`build/wrarb2` s15 froze on the FIRST job (08:35): TGP at 0x4C9 in 96% of
samples, i960 in the mailbox poll 73%, render chain 0 -- the mailbox clear
at 0x4C4 acknowledged and never seen, deterministic this time.* The latch
was the cause. The TGP's request and acknowledge are each registered once
in Model2.sv and `wr_pend` falls a cycle after m2_tgp sees the acknowledge,
so its request line stays up for three cycles after it was served; the
latch took that stale level as a new request and kept it (`pend`) until
slot 2's next turn. By then the TGP had finished the instruction and
`bufw_addr`/`bufw_data` follow its bus (`win_adr`, `wr_hi`, `io_wdata`,
combinationally), so the grant wrote whatever was there -- over the
mailbox's low half. The unit test passed because its owners kept their
lines stable while idle and always had a fresh request by the time their
slot came round; with an idle owner driving garbage and the coprocessor's
slot going quiet for tens of cycles now and then, the latch-only arbiter
fails at once ("a write landed that nobody asked for", "owner 2
acknowledged while not asking") at every line lag from 1 to 3.

*The rule is four-phase:* request up, acknowledge, request DOWN, and only
then can that owner be granted again (`served`, cleared when the line
falls; `want = (req & ~served) | pend`). The pulse latch stays for the
loader. Test: latencies 1, 5, 12, 30, line lags 1-3, all pass; the
previous two arbiters fail it. Cost of the day's three arbiters: two
fitter runs and a stalled HPS. What was missing each time was the OWNER's
timing in the test -- the pulse, then the registered line, then the idle
bus -- not the port's.

Unconfirmed until the board says so: `build/wrarb3` (seeds 11, 13, 14, 15),
R202+R203+R205+R208+R209 four-phase, flashing probe on the H record.

*Confirmed on the board, 09:45.* `build/wrarb3` s15 (four-phase arbiter,
setup -0.255, hold +0.053; seeds 11, 13, 14 died in the fitter's
segmentation fault), 240 s capture from the core load: ROM loaded, the
first coprocessor job completed, the game ran the whole capture -- frame
wait 31%, render chain 10.6%, mailbox poll 3.7%, TGP mostly at its idle
0x30B, never parked at 0x46E or 0x4C9, quads dropped 0. Against `build/ack`
s14 (mailbox poll 77%, TGP parked, counters frozen). A ten-minute soak
follows; the race that hung s14 took three minutes once and did not show
in seven, so a clean soak is evidence, not proof. *Soak, 10:40: ten more
minutes from a fresh core load, 153k samples, no parking at any point,
mailbox poll 3.9%, render chain 12.5%, frame wait 32%, TGP at its idle loop
in every slice. Fourteen minutes clean in two loads against a hang inside
three. R209 is taken as confirmed.*

**R210 -- THE FLASHING IS THROUGHPUT: THE GEOMETRY STAGE TAKES ABOUT TWO
VIDEO FRAMES PER GAME FRAME, AND EVERY FRAME THAT STARTS BEFORE IT FINISHES
DRAWS NOTHING.** Same capture, the H record (`dbg_late_frames` = frame_start
while still collecting; `dbg_qend_frames` = geometry finished):

    per slice of ~152 samples (~24 s):  late 631-909   qend 455-758
    ready cycles (frame_start -> P_READY)  saturated at 65535 (> 1.3 ms) in
                                            every sample after the first slice
    bands completed last frame             1 (most common), 26, 0, 50
    quads held                             up to 1,532, dropped 0

Late and finished advance at the same rate: nearly every game frame's
geometry is still being collected when the next video frame starts, so
the store is cleared, that frame draws nothing (R200's clearing note), and
the frame after draws the list -- on and off at half rate, which is what
the screen shows. "Bands completed = 1" says that when P_READY does come
it is late in the frame and the beam has passed most bands: the parts
that do draw are the bottom of the screen, R200's cut from the other
side. (26 and 50 are more than NBANDS=24 and need explaining --
`bands_this` may count across the frame boundary.)

Where the time goes is not measured yet: the ready counter saturates at
16 bits. Known costs: the walker and the engine each pay ~10 clk_sys
cycles per dword on port 4 (R208's handshake through the registered glue
and the adapter; the port returns 64 bits and only 32 are used), the TGP
runs its job at one SDRAM access per external read, and the CPU pushes
the list through the front-door DMA at two writes per dword on the shared
write port now costing two dead cycles each (R209). Next probe: the ready
count in units of 16 cycles (1 M cycles = 21 ms full scale), and the cycles
from frame_start to q_end separately, to split walk+engine from sort.

**R211 -- THE FLASHING IS PRESENTATION, NOT THROUGHPUT: DAYTONA HANDS OVER A
LIST EVERY SECOND VIDEO FRAME, AND A SINGLE QUAD STORE CANNOT DRAW WHILE IT
COLLECTS. THE STORE IS DOUBLE-BUFFERED.** 2026-09-11, 10:30.

R210 read "late" and "finished" advancing at the same rate as the geometry
being slow. The user pointed out that Model 1 games refresh every second
frame, and the reference measurement already in `m2_geo.sv` says the same
of Daytona: the 0x803008 "list ready" write comes every SECOND frame,
right after the write pointer, single-buffered at address 0. So the walk
delivers a frame's quads at 30 Hz by the game's design, and `dbg_late_frames`
counts the frames in between as well as slow ones -- it cannot separate
the two, and R210's conclusion is withdrawn as unproven (the throughput
question stays open and the widened timers will answer it).

What flashes is this rasteriser's own structure. It has no frame buffer: it
draws bands just ahead of the beam every video frame out of ONE quad store,
and that store was cleared at every frame_start and refilled during the
collecting frame, so the collecting frames drew nothing -- on for one
frame, off for the next, at 30 Hz. Real hardware and MAME show the last
rendered frame until the next; the equivalent here is to keep the last
SORTED LIST and replay it every video frame until the next is ready.

*The fix (`m2_raster3d.sv`).* Two `m2_quad_store`s. `bank` is collected
into and sorted; `~bank` is replayed per band by the consumer on every
video frame once it holds a frame (`dvalid`), regardless of the producer's
state. They swap at the frame_start that finds the collected frame
P_READY; a frame_start that arrives mid-collection swaps nothing and
clears nothing. The clear goes to the bank coming OFF display at the swap
(the first version cleared the freshly sorted bank and drew nothing; the
test caught it at once). Cost: one more store, ~0.5 Mbit of the 1.37 Mbit
of block memory free at 76%, and a 200-bit output mux; ALM at 90% before.

*Test (`sim/video/tb_m2_raster3d.cpp`, `make test_m2_raster3d`).* A list
delivered during frame 0, nothing during frames 1-2, the next list during
frame 3, nothing during 4-5; the beam sweeps each frame. Committed RTL:
pixels 0, 0, 0, 9717, 0, 0 -- the flash. Double-buffered: 0, 9717, 9758,
9767, 9778, 9758 -- every frame after the first draws, including the one
in which the next list is collected. (The one-frame delay from list to
picture is inherent to collect-sort-then-draw and is what the old design
had too.)

Also seen in the test and unexplained: `dbg_bands_done` reads 26 for a
24-band frame; `fill_band` seems to run two past NBANDS. Cosmetic in the
counter, possibly two wasted band fills per frame -- to look at.
Unconfirmed until the board says so: `build/dbuf` (R202+R203+R205+R208+
R209+R211, R210's widened timers on the H record).

*R211, the fit.* `build/dbuf` (two 2,048-entry stores at the 231-bit entry)
failed all four seeds: "Selected device has 553 RAM location(s) of type
M10K block. However, the current design needs more than 553". Block memory
BITS were at 84%; BLOCKS ran out, because a 2048 x 32 array takes seven
2048x5 blocks with the odd bits wasted. Synthesis logic was unchanged
(52,564 -> 52,329 ALUTs); the 43,769 "ALM" the seed table printed is the
aborted fit's pre-packing estimate, not a result. The one store is ~47 of
the 553 blocks. Two answers, both taken: the entry is 191 bits (13-bit
saturated screen coordinates, 565 colour, top 24 bits of the sort key,
which also cuts the radix sort from eight passes to six -- `m2_quad_store`
XW/CW/KW, ports unchanged) for ~40 blocks a bank; and the framework
scaler's input line buffers, sized for 2,048-pixel lines against this
core's 496, are halved (`sys_top.v` IHRES 1024). `build/dbuf2` is a
1,024-a-bank stop-gap to prove the mechanism on the board while that
fits. Further levers if needed, in order of safety: share the key and one
scratch index array between banks (~8 blocks), loader FIFO 512 -> 256,
character cache, i960 data cache; and for logic, the coprocessor's
flip-flop input queue (~2,000 ALM as one M10K FIFO, recorded in the qsf).

**R212 -- THE BACKGROUND JUMPED BECAUSE THE COPROCESSOR'S ARCTANGENT UNIT
WAS MODEL 1's. THE HORIZON ROW IS A TGP ATAN RESULT.** 2026-09-11, 10:30.

*The chain, end to end.* The vertical jump the user saw on every build
since R202 (and read as a vertical-sync fault) is layer pair 2/3's vertical
scroll word. The reference (MAME, write taps on 0x0100A000-0F and
0x501300-1F) writes it once per frame from work RAM 0x50130A, creeping
0x2FDE -> 0x2FE1 over forty frames; mode bits 0x2000 = the vertical split
window at row (-vscr)&0x1ff ~ 34, the horizon. Our bench (`M2_SCRLOG`)
latched 0x2FFC, 0x20FA, 0x2ECF, 0x2F66, 0x20A7 ... a new value every few
frames. 0x50130A is written at 0x67F0 from g0 = cvtri(TGP result) & 0xFFF
| 0x2000, where the result is the 0x2525 job of the routine at 0x6738 that
feeds it sin/cos of an angle g0 = -(R + w28 - w52), and R is the result of
coprocessor function 0x0a with two float inputs. Function 0x0a IS atan2:
the reference returns 38 for (2048, 7.52) and -609 for (120.07, -7.02),
which are atan2(b, a) in 1/65536 turns. Ours returned 0 for (2048, 8.0)
and exactly -0x2000 for (97.3, -7.5).

*Why.* `m2_tgp.sv`'s four math units were transcribed from model1_m.cpp,
and Model 2's (model2.cpp copro_*_r/w) differ in the atan and inv units:
  - atan's table index is `(mant|0x800000) >> (0x88 - exp)` from the FLOAT
    in base 3 (Model 1: an integer index); the selector s2 is the
    comparison |base0| <= |base1| (Model 1: base2's sign bit); there is no
    table-word fixup (Model 1 corrects a bad ROM table); and s2 is also
    presented to the microcode as the gpio0 CONDITION -- copro_atan_w
    calls gpio0_w with it on every base write. sub_797 branches on gpio0
    to pick the octant. We tied all four gpio inputs to zero.
  - inv's sign is the operand's, on the odd word only (Model 1 flipped the
    table's sign for a negative operand on both words).
  - sincos and isqrt are identical in both.
The bench's copro trace hid the decisive read because it logged a FIFO read
only on the cycle it started and dropped it when the CPU stalled there;
fixed, the 0x0a result was visible (`R 00000000`).

*The fix and its proof.* The units rewritten from model2.cpp, gpio0 =
s2, and `tb_m2_boot.cpp` scores every completed function-0x0a exchange
against a C-model atan2 (`ATAN jobs checked`). First pass: 69 of 89, the
misses all with a negative operand returning exactly 0 or 0x4000 -- `ie`
is a u8 subtraction that wraps for a negative ratio, and a 9-bit version
sent the index to 0. Second pass: 89 of 89 within 2/65536 turn, and the
latched layer-2 scroll creeps 0x2FDE, 0x2FDD, 0x2FDC through the title like
the reference. Side effect worth noting: the same run passed 50,666
polygons out of the clipper against 49,655 before and 3,132 two days ago
-- a wrong camera pitch was also discarding geometry. Unconfirmed on the
board until `build/dbuf3`.

Also recorded: `make test_mb86233_regs` fails 46,966 of 3,000,000 checks
on the committed tree, in a module untouched today; not investigated.

*R211 confirmed on the board, 10:50.* `build/dbuf2` s13 (two 1,024-entry
banks at the old width, setup -0.693 on the system clock, hold +0.210; s15
had hold -0.309, s11 no bitstream; fits at 97% ALM because the second
bank's small arrays spilled into MLABs with the M10K blocks full), 120 s
capture with R210's timers on the H record:

    bands completed per frame     26 in 148-189 of 190 samples (was 1 on build/ack)
    frame_start -> q_end          4.3-7.4 ms median, 17.4 ms max
    frame_start -> P_READY        within 0.4 ms of q_end (the sort is nothing)
    quads held (x16)              at the 1,024 ceiling in most samples after slice 2

Every band is filled every video frame now: the list is drawn on the
frames it used to miss. Two things the same record says: the 1,024 banks
SATURATE in the title, so this stop-gap drops the last quads of most
frames and `build/dbuf3`'s 2,048 banks are needed, not optional; and the
collect occasionally takes a whole frame, so R210's throughput question
stands as a separate item (the walker and engine at ~10 cycles a word on
port 4, the TGP at one SDRAM access per read).

**R213 -- THE 3D DREW OVER THE UI TILES; 8-ROW BANDS, AS MODEL 1 SETTLED ON,
TO PAY FOR THE SECOND QUAD-STORE BANK; THE NARROWED 2,048 BANKS STILL DID
NOT FIT.** 2026-09-11, 11:20.

*Layer order.* On `build/dbuf2` the cars drew over the UI text. The
reference (model2_v.cpp screen_update) draws every layer's plain tiles
(`layer<<1`), then the polygons, then every layer's priority-bit tiles
(`(layer<<1)|1`): the 3D sits BETWEEN the two tile categories, not on top.
Our mixer already resolves category 1 over category 0 (m2_tile_mixer
hit_cat1/hit_cat0) and Model2.sv put a 3D pixel over everything. Now
`vid_cat1` leaves m2_video beside the RGB (registered on the same ce_pix,
the palette read landing within the period) and the top level keeps a
category-1 tile over a 3D pixel.

*The fit, second attempt.* `build/dbuf3` (191-bit entries, IHRES 1024)
failed all four seeds on M10K blocks as before. The stores went 226 -> 194
cells each; the scaler stayed at 600, so the IHRES override changed
nothing -- its big arrays are the two N_BURST burst buffers (128 cells
each), the polyphase tables and the palette, and `i_mem` (the only IHRES
array) is small. Left in the source as harmless. The tile renderer's 480
cells are its double-banked per-layer, per-lane line buffers.

*8-row bands.* The user's Model 1 experience: 48 bands, then clock the TGP
and CPU up. Here BAND_H 16 -> 8 halves the three band buffers (3 x 496 x 8
x 16 bits) -- the largest saving available without touching the scaler or
the tile buffers -- and the store's per-quad band MASK, which would have
doubled to 48 bits, became a band RANGE (hi, lo: 12 bits), so the entry
SHRANK to 2*6+1+16 = 29 bits of attribute against 41. Expected: band
buffers ~39 -> ~21 blocks, attribute arrays ~9 -> ~6 a bank. Finer beam
pacing comes free. `make test_m2_raster3d` at BAND_H 8: every frame
paints. `build/dbuf4` = R212 + R213 + narrowed 2,048 banks.

*The band ahead.* Model 1's 48-band change came with one more buffer of
lead over the beam. With 8-row bands a fourth buffer is ~7 blocks (four at
8 rows, ~28, still under three at 16, ~39), so NBUF is 4. The Model 1
reference (pulled to a7abcbf; ours was copied at 085a00e) has since fixed
three hardware-only band-presentation faults -- a multi-bit beam-band
crossing (a1d9192), presenting each band one line early (9ec7e9e), and
confining that lead to the horizontal blank (43118c5) -- on a
presentation design that differs from ours (one display pointer on a
toggle handshake, decided a band ahead). Ours crosses each buffer's ready
flag and band index separately, which is safe because the index is
written long before the flag rises, except at RELEASE: the beam clears
the flag and the fill could retarget the buffer while the scan side's
two-flop copy still reads ready, a mixed index sample then presenting a
buffer being cleared. A released buffer now settles eight cycles before
reuse. If `dbg_missed` says bands are still late, the next step is
Model 1's present-a-line-early logic, ported as a whole. `build/dbuf5` =
dbuf4 + four buffers + the settle.

*Probes for what the user reports on dbuf2* ("still flickering", "slower,
holding the frame for two frames"): `dbg_hold` latches at each swap how
many video frames the previous list stayed on display (2 is the game's
own rate; more means the collect spilled a frame), and `dbg_missed`
counts scanlines the beam started with no band buffer holding that band
(a band filled but not in time). The CPU's time budget on dbuf2 is within
a few percent of wrarb3 (frame wait 26% vs 33% on a shorter capture,
render chain 12.4% vs 12.9%), so the game itself did not slow down.

*dbuf4, 11:10.* The 2,048-entry banks FIT with 8-row bands: s14 and s15
placed at 96% ALM, block memory 77% by bits and within the 553 blocks.
Both failed HOLD by ~-0.3 ns on ONE path -- `m2_cpu_bridge` r_rdata[15]
(50 MHz) -> bus_rdata[15] (the CPU's 25 MHz), every other path on that
clock at +0.27 or better; a morning seed (wrarb2 s11) had the same clock
at -0.224. Quartus's default OPTIMIZE_HOLD_TIMING covers I/O paths only;
set to "All Paths" so the fitter pads internal hold misses. Not deployed:
a hold miss on the CPU's read data is a corrupted bit at some temperature,
not a margin. `build/dbuf5` carries the setting.

*dbuf5, 11:40.* Four 8-row buffers ran the device out of M10K blocks again
("needs more than 553", all seeds) where dbuf4's three had fit: the fourth
buffer's ~7 blocks were more than the margin dbuf4 left. Back to three
(the settle delay stays); `build/dbuf6` = dbuf4 + the settle + the
all-paths hold fix. The fourth buffer returns when the quad store shares
its sort key and one scratch index array between the two banks (~8
blocks), which only the collecting bank ever uses.

*dbuf6 s14 on the board, 12:00 (R211 + R212 + R213 together; three 8-row
buffers, hold fix, all clocks' hold positive, setup -0.202 on the HDMI PLL
only).* Photographed and captured for 240 s:
  - The tile background scrolls normally: R212 confirmed on hardware.
  - The 3D sits behind the UI text layer: R213's order confirmed.
  - `dbg_missed` (scanlines the beam started with no band ready) is 0
    through the whole title after boot: bands are never late. Late bands
    are NOT the flicker.
  - `dbg_hold` (video frames a list stayed on display, minus one): mostly 1
    (the game's two-frame cadence), but 2 for most of one 24-second slice
    and 3 at times -- the collect (frame_start -> q_end) ran 7-14 ms in
    those stretches and spilled a frame. That is the "slower" the user
    reports, and R210's throughput question measured: the walker and the
    engine at ~10 clk_sys cycles a dword on port 4.
  - Quads held reached the 2,048 ceiling in every slice, median 1,536 in
    the busiest: the banks OVERRUN in heavy frames and the last-submitted
    quads are dropped, which is the likely "3D mostly missing". The drop
    counters (store and push DMA) go on the record as R214.
  - CPU budget unchanged: frame wait 33.6%, mailbox 4.1%, render 12.2%.

**R214 -- THE WALKER AND THE ENGINE USED HALF OF EVERY PORT READ. A PAIR
CACHE IN FRONT OF EACH HALVES THEIR PORT TRIPS.** 2026-09-11, 12:30.

dbuf6 s14 measured the collect (frame_start -> q_end) at 7-14 ms in the
title with lists held three video frames for long stretches (R213). Both
port-4 readers pay the whole registered-glue-plus-adapter round trip,
~10 clk_sys cycles, per dword. `m2_sdram` answers every read with FOUR
consecutive 16-bit words -- it issues the four columns one by one at
burst length 1 (mode register A[2:0] = 000, `xfer_addr[COL_BITS:1] + 1`
per S_RD), so there is no SDRAM burst wrap and p_dout[63:32] is always
the dword after the one asked for. Both readers took p_dout[4][31:0] and
threw the rest away.

`rtl/mem/m2_pair_cache.sv` sits between each reader and the glue: a miss
goes to the port and its answer's upper half is kept as index+1; a request
for that index is answered in one cycle without the port; the copy is used
once and dropped on any other request, so a dword the CPU or TGP rewrites
is never served stale beyond the gap between two consecutive reads. The
index is the full dword address, so an object stream that begins one past
the last cannot hit a stale copy. The requester's handshake is R208's; two
faults the unit test caught before the fitter did: (1) the pass-through
acknowledge was combinational while the data was registered, so a miss
read the previous word -- both acknowledges are registered now; (2) a hit
one cycle after a miss raised its pulse while the adapter's held
acknowledge was still up and the requester never saw an edge -- a hit now
pends until the line has fallen. `make test_m2_pair_cache`: sequential
500 words = 250 trips, random 500 = 500, mixed correct, at latencies 1, 3,
6, 12. Not simulable in the boot bench (the glue is not in it); lint and
the unit test are the evidence until `build/dbuf8` (dbuf7 + R214).

Expected: the engine's stream (points, attribute, normals) and the walker's
(matrix, object, polygon-data words) both sequential, so roughly half the
port trips and the collect well under a frame. The TGP's own reads (one
SDRAM access per external read, port 9) are the next throughput item after
this, and the clock lever the user used on Model 1 after that.

*dbuf7, 12:40: no fit -- 74,800 ALUTs.* The two-bank store's final-order
array, as one {bank, index} array, inferred only the replay's read port;
the sort's read was built from 45,613 registers. Two arrays with the bank
selecting the result (`idx_a0`/`idx_a1`) infer as the single-bank store
did, one write and two reads each. Found beside it: since the narrowing
(dbuf3 on) each vertex word was read with TWO slices on one line, which
Quartus takes as two read ports and duplicates the array -- the file's
own "ONE READ PER ARRAY" rule, broken by me. One registered read each
now. That duplication was in dbuf4 and dbuf6 as well and is part of why
the fourth buffer did not fit in dbuf5; the true block count of the
narrowed store is lower than R213 measured. `build/dbuf8` = the corrected
two-bank store + four buffers + R214 pair caches + the drop counters.

*dbuf8, 12:55: no fit, M10K again -- and the reason is the block's shape.*
With the inference faults fixed the store synthesised at 1,052 ALUTs, 763
registers, 674 Kbit, ~200 memory cells against 388 for two instances,
and the device still needed more than 553 blocks. An M10K is 2048 x 5 or
4096 x 2: a 4096-deep array of W bits costs ceil(W/2) blocks against
2 x ceil(W/5) for two 2048-deep ones -- a 26-bit vertex word 13 against
12, the 29-bit attribute word 15 against 12, the 11-bit index 6 against
6. Merging the banks into double-depth arrays cost blocks; only the KEY
and the scratch index, which are single-bank by nature, save any. The
data arrays are per bank again with the bank selecting the result
(`vtx0_0/vtx0_1` ... `att_0/att_1`), key and `idx_b` shared. Rule for
this device, now written down: NEVER deepen an M10K array past 2048 to
merge two of them; the 4096 x 2 mode is the least dense. `build/dbuf9`.

**R215 -- THE BUSIEST TITLE FRAMES CARRY ~4,200 QUADS AND THE STORE HOLDS
2,048: HALF THE SCENE IS DROPPED, WHICH IS THE "3D MOSTLY MISSING". THE PAIR
CACHES DID NOT SHORTEN THE COLLECT: THE ENGINE'S ARITHMETIC IS THE LIMIT.**
2026-09-11, 13:20. `build/dbuf9` s14 (everything to R214; 91% ALM, 77%
block memory, hold positive on all clocks, setup -0.324 on the HDMI PLL
only), 240 s from the core load, the drop counters on the record:

    store dropped per frame (max per slice)   2036, 2148, 1321, 1992, 1252
    quads held (x16)                          at the 2,048 ceiling in every slice
    push DMA dropped                          0
    frame_start -> P_READY, ms (med / max)    5.3-13.6 / 17.4   (dbuf6: 4.3-14.4 / 17.4)
    hold (frames-1 per list)                  1 mostly, 2 for a whole slice, as dbuf6
    CPU: frame wait 33.8%, mailbox 4.1%, render 12.0%

So 2,048 + 2,148 = ~4,200 quads in the heaviest frames, against MAME's own
measurement of a 4,798-record peak frame (m2_quad_store's header). The
store keeps the first 2,048 in submission order and drops the rest, and
what the game submits last is what is missing on the screen. The user's
"still the same" on dbuf9 is this. And the collect did not move with the
walker's and engine's port trips halved, so R214's premise was wrong:
memory latency was not the collect's cost; the engine's per-polygon
transform/clip/project is.

Two roads, in order of cost:
  1. Reject at the store's door what cannot draw: a quad whose screen
     bounding box is under a pixel. The bench's quad dump counts how much
     of the title's 4,200 that is. Free if it is a lot; nothing if it is
     not.
  2. Vertex words to SDRAM. Per entry the store keeps the 24-bit key, the
     29-bit attribute and the index on chip and writes the 96-bit vertex
     word out through the arbiter (R209); the replay fetches vertices only
     on a band hit. Two 4,096-entry banks then cost about what two 2,048
     banks with vertices cost now (4096 x 2 blocks: key 12, att 15, index
     2 x 6 -- ~39 a bank), and the SDRAM traffic is ~4 MB/s of writes and
     ~5 MB/s of reads. The port is the question: the sweeper's port 0 is
     the free one.
The collect time is a third item: the engine's cycles per polygon, which
the bench can measure directly.

*The engine's cost, measured (13:40).* Boot bench from the title
(`M2_POLY_FROM=17000000`): engine-busy 30,376,300 ticks over 1,677 objects
and 50,666 emitted quads -- 600 busy ticks per quad, and the gap from one
emitted quad to the next is 467 ticks at the median AND at the 90th
percentile. A fixed per-polygon sequence, then, not memory waiting: 4,200
polygons x 467 = 39 ms of engine time at 50 MHz, more than two video
frames, which is why halving the port trips (R214) moved nothing. The
engine reads a polygon, transforms it, clips it and projects it strictly
one after the other. The next measurement is the split of those 467
across the stages; the fix is overlap -- fetching polygon N+1 while N is
in the arithmetic, and the projection's divides in parallel -- or the
clock, which is the lever the user pulled on Model 1 after its 48 bands.

**R216 -- 46% OF THE TITLE'S QUADS ARE UNDER 2x2 PIXELS. THE STORE REFUSES
THEM.** 2026-09-11, 13:50. The bench's dump of 4,096 projected quads from
the title (`M2_QUADS_OUT`, from instruction 17 M):

    bounding box under 1x1 px    13.6%
    under 2x2 px                 45.9%
    zero width or zero height    48.1%
    under 4x4 px                 59.5%
    entirely off-screen           0.0%

The reference draws each as a dot; here they cost half of a 2,048 store
and half of every band's replay, and the busiest frames were dropping
their LAST-SUBMITTED half (R215). `m2_quad_store` now refuses a quad whose
bounding box is under TINY (= 2) pixels in both dimensions, counted as
`dbg_tiny` and on the record beside the drop count. Expected on the
board: quads held ~2,300 in the heaviest frames against 2,048, so a small
residual drop, and the missing scene back. A deliberate deviation from
the reference, measured; 0 disables it. The rejection is at the store, so
it does not shorten the collect -- the engine still spends 467 cycles on
each of them before they are refused. Zero-extent quads (48%) are NOT
refused: the fill's line case draws them, and thin distant edges are
theirs. `build/dbuf10`.

*Where the 467 go (14:00).* The engine's state histogram over the title,
as a share of ALL ticks from instruction 17 M:

    E_IDLE   38.7%   no object in hand (the walker between objects)
    E_EMIT   34.2%   polygon ready, WAITING for the projection stage to take it
    E_XFW    12.9%   waiting on the vertex transform
    E_NXFW    5.6%   waiting on the normal transform
    E_FOCW    2.9%   waiting on the focus
    E_RD      1.8%   memory reads  (R214's target: never the cost)
    projection stage busy: 50.5% of all ticks

The projection (clip and perspective divide) is the bottleneck: half of
all time, and the engine idles in E_EMIT behind it for a third. At ~230
cycles a polygon that is eight sequential fp_div at ~29 cycles -- x/w and
y/w for four vertices -- with the clipper's planes on top. R217 is the
projection: one reciprocal per vertex and two multiplies instead of two
divides, or a pipelined divider; then overlap the engine's transform of
polygon N+1 with the projection of N.

**R217 -- THE QUAD PROJECTOR PROJECTED ALL FOUR VERTICES OF EVERY POLYGON;
TWO OF THEM ARE THE PREVIOUS POLYGON'S. A VERTEX ALREADY PROJECTED TAKES
ITS PIXEL.** 2026-09-11, 14:15. `m2_geometry`'s quad projector comment
budgets 120 cycles a polygon for four reciprocals at 29 and "2,700
polygons in a 60 Hz frame before this stage is the limit"; the title
carries ~4,200 (R215) and the measured cost was ~230 with the clipper's
reprojections and the pool's arbitration on top. Model 2's polygon
streams are strips: the engine carries two of each polygon's view-space
points into the next (E_LINK per attr[9:8], R171), so vertices 0 and 1 of
polygon n are, bit for bit, two of the four of polygon n-1. The projector
now keeps the last polygon's four vertices and their pixels and a vertex
bit-equal to one of them takes its pixel without a projection. Bit
equality is the right test because the carried points are register
copies, not recomputed; a miss costs what it did before. The clipper's
own reprojections of cut vertices are unchanged. Tests: m2_geometry 30
checks, m2_geo_engine 20, boot bench PASS; the engine's cost is being
remeasured. Expected: the projector's share roughly halved, so ~120 fewer
cycles a polygon of the 467.

*R217 measured (14:30):* quad-to-quad gap 467 -> 409 cycles (median and
p90 alike), projection busy 50.5% -> 47.8% of all ticks, E_EMIT 34.2% ->
30.7%. Real but a fraction of the halving expected, so the quad
projector's four projections were not the bulk of the projection stage:
what remains is the clipper's reprojection of cut vertices (it has
priority at the projector) and the engine's idle share, 39% of all ticks,
which is the walker between objects. Both are being split out by the
bench before the next step.

*The split (14:40).* Projection busy 47.8% of all ticks = quad projector
21.8% + clipper 26.0%; projections granted over the title: quad projector
283,080, clipper 219,860, against ~55,000 emitted quads. The clipper
reprojects about four vertices for every emitted polygon -- it is the
larger half -- and the quad projector still issues ~5 per emitted quad,
so R217's cache is missing far more than a strip should; its hit rate is
being counted. The walker: W_OBJW 62.4% (waiting for the engine), W_IDLE
37.2% (no walk in progress), the rest under 0.5% -- the walker is never
the cost, and the engine's 39% idle is the same 37%: the title's geometry
has that much slack between lists. The levers, in order: the clipper's
reprojection policy, the cache's misses, then the transform (E_XFW 14%).

**R218 -- THE CLIPPER REPROJECTED EVERY VERTEX OF EVERY EMITTED QUAD, CUT OR
NOT. ONLY THE VERTICES IT CREATES ARE PROJECTED NOW.** 2026-09-11, 15:00.
`m2_geo_clip`'s emit path ("Four vertices, one reciprocal each, at the
point of emission") sent all four vertices of every quad it emitted
through the 29-cycle projector, including quads no plane had touched --
219,860 projections against ~55,000 emitted quads over the title, 26% of
all the geometry's time (R217's split). The clipper already received the
quad projector's pixels (in_sx*) and did nothing with them. They now ride
through the stack beside the camera coordinates with a flag per vertex:
an input vertex has its pixel, a vertex made by a cut does not, and only
the latter is projected at emission. The pixel of an uncut vertex is
bit-identical to what a reprojection would give -- same projector, same
inputs -- so the reference's rate of one projection per emitted vertex is
matched in result, not in work. One fault on the way, caught by
`tb_m2_geo_clip`: the projection request was a level tied to the emit
state, so on the cycle a vertex was skipped the projector was still
granted a projection of it and the next vertex's result landed one slot
late; the request is gated on the vertex needing one. 2,003 checks pass.
The engine's cost is being remeasured; the expectation is the clipper's
26% falling to the share of cut vertices, a few percent.

*R218 measured (15:15), same bench, same window:*

                                 before (R215)   R217      R217+R218
    quad-to-quad gap, cycles         467          409          177
    busy ticks per emitted quad      600          546          308
    projection busy, % of all       50.5         47.8         23.5
      of which the clipper          26.0         26.0          0.6
    clipper projections granted   219,860      219,860        4,972
    engine waiting to emit (E_EMIT) 34.2         30.7          6.0
    engine idle, no object (E_IDLE) 38.7         39.4         63.8

The clipper now projects only what it cuts. The engine spends most of its
time with nothing to do, which is the title's geometry fitting in its
frame with room; the remaining cost is the quad projector's 22.9% (its
cache hits 191,042 of ~294,000 grants, so a strip's shared vertices are
found about two times in three -- the misses are the polygons after a
refused non-finite one or a skip, which break the chain) and the vertex
transform's 14.3%. `build/dbuf11` = dbuf10 + R217 + R218.

*dbuf10 s15 on the board (15:25), R216's rejection measured:* tiny quads
refused up to 1,440 a frame, and the store STILL drops 646-2,110 a frame
with quads held at the 2,048 ceiling in every slice. The heaviest frames
on the board carry ~5,000 quads before the rejection, more than the
bench's 4,200, and the reference's own 4,798 "records, of which not all
emit" says the same. R216 was worth what the histogram promised and it
is not enough: the store needs ~4,096 a bank, and on this device that is
the vertex words in SDRAM (R215's road 2) unless the reference emits
fewer polygons than we do -- which is the next thing to check before
building it. Hold: 1 mostly, 2 for a slice, as dbuf6/9 (no R217/R218 in
this build). CPU budget unchanged.

**R219 -- THE REFERENCE CULLS BACK FACES AND LINK-TYPE-0 POLYGONS; THIS
ENGINE EMITTED EVERY POLYGON IT READ.** 2026-09-11, 15:45. dbuf10's
capture: with 1,440 sub-2-pixel quads a frame refused, the store still
dropped up to 2,110 with 2,048 held -- ~5,000 quads a frame on the board.
model2_v.cpp `check_culling`: a polygon is not rendered when (a) attr bit
17 is clear (single-sided) and its face is the back -- `dotp = normal .
point < 0`, the normal after the matrix, the point the polygon's first new
vertex after the matrix and BEFORE the focus; (b) its link type, attr bits
9:8, is 0; (c) its z range is behind the camera or past the master clip
(the clipper covers the first here). `m2_geo_engine` had none of them, so
it emitted the back of every car and every building: that is why the
board's frames carry ~2x the reference's peak. The engine now computes
the dot product (three multiplies on the focus multiplier's port, two
adds on the pool's spare adder slot) between the second point and E_EMIT,
and skips the emit for a culled polygon while the strip carry still runs;
`dbg_culled` counts them. Unconfirmed until the bench and the board say
so: the bench's emitted-quad count against MAME's is the check.

*R219 measured (16:10), same bench window:* emitted quads 57,840 -> 31,648
(45% culled -- the backs of single-sided polygons and link type 0), clipper
input 65,535+ -> 55,209, clipper output 57,840 -> 31,648, projection busy
23.5% -> 14.4% of all ticks (this morning: 50.5%), quad-projector grants
293,987 -> 187,462. The engine's busy ticks are unchanged, as expected: a
culled polygon still costs its transform; what halves is everything
downstream -- the store, the sort, every band's replay. With R216's
rejection on top, the board's ~5,000-quad frames should land under the
2,048 the store holds. `build/dbuf12` = dbuf11 + R219.

*dbuf11 (16:20): the FITTER CRASHED on all four seeds* -- synthesis fine,
then "Fatal Error: Segment Violation at (nil)" (s13, s15) or a stack
trace ending "End-trace" (s11, s14) at the fitter's preparation step,
right after the I/O packing warnings. The same signature the project
file records for the area-mode experiment. dbuf10 fit; dbuf11 adds only
R217 (m2_geometry's projected-vertex cache: eight 96-bit comparators in
an always_comb with nested loops) and R218 (m2_geo_clip's pixel and flag
arrays through its stack, 2-D unpacked arrays of signed 16-bit). One of
those two netlist shapes trips Quartus 17.0's fitter. Bisected in
parallel from two worktrees, each with one commit reverted, two seeds
each: `build/bis_noR218` and `build/bis_noR217`. dbuf12 was stopped; it
shared the netlist.

*The bisect (16:50): it is not a shape, it is the density.* With R217
reverted, s14 crashed and s15 fit at 41,291 ALM (98.5%, setup -0.456,
hold -0.296); with R218 reverted, s15 crashed and s14 fit at 41,203 ALM
(98.3%). Each half alone puts the device at 98% and Quartus 17.0's fitter
falls over at that density on about half its seeds -- the same behaviour
the project file records from the area-mode experiment. Synthesis logic:
the geometry stage 5,096 -> 5,841 ALUTs from dbuf10 to dbuf11 (R217's
eight 96-bit comparators +465 in m2_geometry itself, R218's pixel stack
+274 and +664 registers in the clipper), the engine +190 for R219's dot
product. dbuf10 fit at 37.8k with these absent. So both changes stay and
both slim down: R217's comparators go -- the engine knows which two
vertices it carried (the link mode of the polygon before) and can say so,
which is also a 100% hit rate against the comparators' two in three; and
R218's stack carries a 2-bit vertex id and a flag instead of a 32-bit
pixel, the four input pixels held once. The coprocessor's flip-flop
input queue (~2,000 ALM as one M10K, per the qsf) remains the lever for
real room.

*Slimmed (17:15), 0f47d1b.* R217: `m2_geo_engine` exports the link mode of
the last emitted polygon and a chain flag (cleared at object start and by
a cull); the projector maps vertices 0 and 1 to the last polygon's pixels
by that mode -- default carry v0 = last v3, v1 = last v2; link 1 v0 =
last v2, v1 = last v1; link 3 v0 = last v0, v1 = last v3 -- and a refused
(non-finite) polygon clears the chain. No comparators. R218: the
clipper's stack carries a 2-bit input-vertex id and a flag; the four input
pixels are held once and looked up at emission. Engine 20, geometry 30,
clip 2,003 checks pass; boot bench passes. `build/dbuf13` = everything to
R219, slimmed. The bench is remeasuring the projector's hit rate.

*Slimmed, remeasured (17:40):* identical output -- 31,648 quads emitted,
projection busy 14.4% -- and the stated carry hits 88,123 vertices against
the comparators' 68,594 on the same window: four polygons in five take
both shared pixels, the fifth following a cull or an object start. dbuf13
synthesis: 52,288 ALUTs / 50,789 registers against dbuf10's 51,892 /
50,082 (dbuf11, which crashed: 52,728 / 51,373); the clipper 1,899 / 3,301
against the unslimmed 2,086 / 3,765. Predicted fit 91-93% ALM, block
memory unchanged at 77%.

*dbuf13 fit (18:00): 40,690 ALM (97%), block memory 77% -- the prediction of
91-93% was wrong by the same mechanism that crashed dbuf11.* +396 ALUTs
and +707 registers of synthesis over dbuf10 became +2,900 fitted ALMs:
at this density the fitter stops packing registers beside LUTs, so a
register costs an ALM of its own, and two of four seeds crashed as the
halves did. s11 fit with setup -0.525 on clk_mem, s15 with -0.543 on
clk_sys, hold positive on all clocks for both. s15 deployed as the
functional test. THE LESSON, FOR THE FIT MODEL: above ~92% fitted, add
registers at one ALM each, not four to the ALM, and expect the fitter to
crash on half the seeds. The relief is the coprocessor's 128 x 32
flip-flop input queue -- ~2,000 ALM as one M10K block, recorded in the
qsf since the area experiment -- and it is the next change, before
lighting or anything else that adds logic.

**R220 -- THE SORTED LIST WAS OVERWRITTEN BY THE NEXT WALK BEFORE THE SWAP.
THE STORE NOW TAKES QUADS ONLY WHILE COLLECTING.** 2026-09-11, 18:30.
dbuf13 s15 on the board: the store DROPS NOTHING in any slice (quads held
peak 2,000 of 2,048: R216 + R219 closed the capacity question), yet the
user sees the 3D on and off, not steady, with wrong wedge shapes (the
car-select car photographed: body right, a large wedge and pieces
missing). The title's quads that looked collapsed this afternoon were a
far camera -- the car-select car is full size, so the projection's scale
is right. The hazard is R211's: between a list's q_end and the frame_start
that swaps the banks, the SORTED list sits in the collect bank waiting.
The walker starts a walk on the game's flip (trig_flip), which can land
mid-frame, and its quads were written straight into that bank -- the
store never pushed back (`q_ready = 1`). Two lists mixed and the sorted
order part-overwritten: wedges, and a frame that draws a corrupt list
then a good one. `q_ready` is now `pst == P_COLLECT`; the geometry
pipeline already holds its output on it (the clipper's out_valid), so the
walk waits for the swap, which is the list's own two-frame cadence. The
hold on dbuf13 still reaches 3 frames in stretches, but its "ready" time
includes waiting for the game to deliver the list, which is the game's
timing, not the engine's -- to be separated later. `build/dbuf14`.

**R221 -- WHERE THE LOGIC IS, AND WHAT MOVES TO BLOCK RAM BEFORE LIGHTING.**
2026-09-11, 18:50. From dbuf13's synthesis, own logic by entity (ALUTs /
registers): i960 top 3,980 / 1,339; framework scaler 2,555 / 4,029;
MultiPCM x2 at 2,176 / 3,724 each; clipper 1,899 / 3,301; i960 regs 1,856
/ 1,368; quad store 1,480 / 1,628; PCM fetch x2 at 896 / 2,694 each. Above
~92% fitted the fitter charges an ALM per register (dbuf13: +707 registers
of synthesis became +2,900 ALMs), so REGISTERS are what to move, and the
sound board holds ~12,800 of them.
  1. `m2_pcm_fetch` x2: `buf_q [32]` of 64 bits, `tag_q`, `val_q` -- a
     per-voice prefetch line indexed by ONE slot -- ~2,700 registers each.
     As one M10K per unit (2 Kbit) with a registered read: the hit test
     `val_q[c_slot] && tag_q[c_slot] == addr` becomes a cycle later, so the
     fetch state machine takes one more cycle per lookup. Cheapest and
     largest single win; the sound bench is the oracle.
  2. `m2_multipcm` x2: sreg 28x8x8, s_pos 28x38, s_start/loop/end, ~4,500
     bits each in registers -- but indexed by five different slots in one
     cycle (play_slot, picked, slot, df_slot, cur_slot), so a RAM needs the
     per-tick schedule re-cut. Second.
  3. `m2_geo_clip`'s shift-register stack, NSTK=5 x 4 x 96 bits = 1,920
     registers moved on every push and pop: a pointer-based stack in an
     MLAB removes the registers and the shift muxes. Third.
  4. Debug probes in Model2.sv that have done their job (wk_*, e13_*,
     e140_*, mb_*, eo_*): a few hundred ALMs, at no risk.
Target: fitted ALM under ~85% before lighting, which is a few hundred
ALMs of arithmetic plus a table read port, and well under before
textures, which are the largest block left in the project.

*R220 at the desk (19:10):* boot bench through the title identical to before
the gate -- 82 walk frames, 1,916 objects, 31,648 quads, engine cost
unchanged, PASS. The walk waits at the gate and never wedges.
`build/dbuf14b` in the fitter.

*R221, step 1 done at the desk (19:40).* `m2_pcm_fetch`'s 32 x 64-bit line
data is an M10K with a registered read (F_LOOK, one cycle more per hit);
tags and valid bits stay in registers. `make test_m2_sndboard` passes as
before, the only log difference the sample-period jitter statistic (sd
11.6 -> 9.4 cycles, mean 1,120 unchanged), and the mixed output written
with M2_SND_WAV is BYTE-IDENTICAL to the flip-flop version's, 110,292
bytes, sample for sample. Two units: ~4,100 registers out of logic for
two blocks. Into the build after dbuf14b.

*R221, step 3 done at the desk (20:05).* `m2_geo_clip`'s stack is one
99-bit MLAB of NSTK x 4 entries indexed by {level, vertex}, with a
four-cycle push (K_CHILD writes one vertex a cycle) and a five-cycle pop
(K_POP issues vertex 0's read, K_POPR consumes vertex pcnt-1 while
issuing vertex pcnt). The shift-register version moved 1,920 registers on
every push and pop. Pushes and pops happen only for polygons a plane
cuts, so the cycles are nothing. `tb_m2_geo_clip` 2,003 checks,
`tb_m2_geometry` 30, boot bench pass. In the build after dbuf15.

*dbuf14b (20:20): fits at 40,555-40,758 ALM (97%), as dbuf13 -- R220 adds
no logic. s15 (setup -0.568 on the HDMI PLL only, hold +0.226) deployed
with a 240 s capture: the build with every change of the day including
the store's ready gate. `build/dbuf15` = dbuf14b + the block-RAM PCM
lines (R221 step 1) + the MLAB clipper stack (R221 step 3) is in the
fitter behind it: the first build that should come DOWN in ALM.

*R221, dbuf15 (21:05): THE M10K BLOCKS ARE THE WALL, NOT THE BITS.* All
four seeds refused at the fitter's RAM placement: 556 M10K blocks needed of
553, bits only 77%. dbuf14b sat at 553/553 exactly. The two 32 x 64-bit
PCM lines are 2 blocks each (a 64-bit word spans two 256 x 40 blocks, and
the depth is wasted), so the move that saved ~4,100 registers cost 4 blocks
the chip does not have. ALM before the refusal: 40,153 (96%), the first
build to come down. Corrected rule for the rest of the register moves: a
small, wide array goes to MLABs, not M10K -- an MLAB is 32 deep x 20 wide,
one LAB, and a 32 x 64 array is four of them for ~40 ALMs against 2,048
registers. M10K is for the deep arrays only, and there are none left to
give. PCM lines re-tagged MLAB; the write and the same-slot read coincide
on the miss (F_FETCH), whose output is not consumed -- F_ARM re-reads and
F_ACK uses that. WAV byte-identical again.

*R221, step 2 done at the desk (21:30): THE MULTIPCM STEPPING STATE IN
MLABs.* The plan above said the per-voice state needs the tick schedule
re-cut because five slot indices touch it in a cycle. Looking at who reads
what: the stepper alone reads and writes s_pos, and s_start/loop/end are
written only when a descriptor fetch completes and read only by the
stepper. Two single-writer, single-reader arrays, no schedule change:
`desc_ram` 32 x 55 {end, loop, start} and `pos_ram` 32 x 38, MLAB, read
registered at `slot`, and at the slot that comes next on the tick that
advances it (needed only if the sample CE were every clock; it is 1 in 5,
kept anyway). Two things the flip-flop version did in place are beside the
RAMs: key-on wrote position 0 -- now `pos_zero[slot]` reads as 0 until the
stepper's first write clears it; and a descriptor completing on the cycle
before the stepper takes that same slot would read the RAM stale -- the
completed word is forwarded for one cycle (`desc_fwd`). The stepper cannot
write while a fetch is in flight, so the two writers never meet; the
key-on write and same-address read can meet on an MLAB (read output
undefined) and that read is the one forwarded over. s_active, s_fmt12 and
s_release stay registers (reset values). sreg (the CPU's 28 x 8 bytes) is
read at play_slot, slot and picked in one cycle: still registers, next.
PROOF: `make test_m2_sndboard` PASS and the WAV byte-identical -- but that
run keys few voices; the real proof is a lockstep differential bench (the
flip-flop module renamed beside the new one, same register writes, each
with its own ROM model of identical per-request latency, every cycle
comparing rom_req/addr/slot, sample_stb, out_l/out_r): 3 seeds x 4 CE
patterns x 3-4 M cycles, 0 mismatches; and it CATCHES each mechanism
removed -- no forwarding: 1,528 mismatches (only with sparse writes: dense
writes never leave a voice stepping), no position-zero: 2.99 M, no
prefetch: 1.97 M with CE every clock and 0 with CE 1 in 5. Removes 2 x
2,604 registers and their 28:1 read muxes. `build/dbuf16` = dbuf14b + MLAB
PCM lines + MLAB clipper stack + this.

*R221, step 2b at the desk (22:00): THE READ REGISTER FIELDS TOO.* Of the
CPU's 28 x 8 bytes the chip reads five fields: pan (reg 0[7:4]) and level
(reg 5[7:1]) at play_slot in the mixer, pitch (reg 2[7:2]) and octave (reg
3) at `slot` in the stepper, and sample (reg 1, reg 2[0]) at `picked` --
an address that exists only in the cycle the pick uses it. The first four
are now four MLABs, written beside `sreg` by the CPU, read registered at
their consumer's slot, with the same one-cycle forward for a write to the
slot being read. Sample stays in `sreg`; the bytes nothing reads (reg 4,
the LFO defaults 6 and 7) synthesis already dropped. Same lockstep bench:
3 seeds x 5 CE patterns (1-in-5, random, 1-in-2, sparse writes, every
clock) x 2 M cycles, 0 mismatches; with each forward removed in turn the
bench fails (pan 4,390, level 10,455, octave 37,967 at 1-in-5; pitch 1,007
at CE every clock, where the stepper's slot is the one just written).
Another ~700 registers and 25 bits of 28:1 mux a chip. What is left in
registers per chip: s_active/s_fmt12/s_release/key_wait/desc_pending/
pos_zero (6 x 28), sample (9 x 28), and the descriptor buffer.

*R221, dbuf16 (16:25): 97% -> 83%.* dbuf14b + the three MLAB moves (PCM
lines, MultiPCM stepping state and register fields, clipper stack):
34,614-34,645 ALM (83%) against 40,555 (97%), M10K 553/553 as before,
three of four seeds fitted (s13 died in the fitter's own DYN sub-system,
the crash the density note predicted). s14: setup +0.556 ON EVERY CLOCK
INCLUDING THE HDMI PLL, hold +0.186 -- the first build of the project to
meet timing outright. Per module, dbuf14b -> dbuf16 (self ALM): clipper
2,310 -> 1,049; each MultiPCM 2,208 -> 826; each PCM fetch 1,368 -> under
280. Where the logic is now: i960 8,049 (2,819 own; regs 1,603; fpmisc
864; fpadd 664; alu 473), the framework's ascal 1,814, the quad store
1,338 (1,669 registers -- next), fx68k's excUnit 1,117, clipper 1,049,
MultiPCMs 1,640, raster fill 732, tilemap 662, sdram 652, fp_pool 651,
TGP alu 624. Deployed s14 for a 240 s capture.

*R221 on the board (16:20): dbuf16 s14, 240 s capture identical to dbuf14b
-- store dropped 0 in every slice, ready 3.7-10 ms median, hold 1-2 frames
in the same pattern, quads x16 median 0-752 -- and THE SOUND IS RIGHT BY
EAR with every MultiPCM voice stepping out of MLABs. R221 closed.*

**R222 -- LIGHTING AND THE POLYGON'S COLOUR: WHAT THE REFERENCE COMPUTES, WHERE THE DATA IS, AND THE DESIGN.**

*What MAME computes for a flat polygon* (`model2_v.cpp` `geo_parse_np_ns`, `model2_3d_render`, `model2rd.ipp` flat case):

    dotl  = normal . light            (light: cmd 0x0a, three floats; the walker
                                       already captures it as lit_x/y/z, R168)
    dotp  = normal . point            (the engine already has it: R219's cull)
    lum   = (dotl*dotp < 0) ? 0 : |dotl|
    lum   = lum * tp[attr>>18 & 31].diffuse + tp[..].ambient   (8-bit ints, cmd 0x06;
                                       the walker streams them as tp_we/tp_idx/
                                       tp_diffuse/tp_ambient, R168)
    luma  = clamp(int(lum), 0, 255)   (the face bit 0x100 is masked off again by
                                       `& 0xff` before any use: irrelevant)
    colorbase = texheader[3] >> 6 & 0x3ff
    c555      = palram[0x1000 + colorbase]
    r = gamma(colorxlat[0x0000/2 + (c555>>0 &31)<<8 | luma>>2])
    g = gamma(colorxlat[0x4000/2 + (c555>>5 &31)<<8 | luma>>2])
    b = gamma(colorxlat[0x8000/2 + (c555>>10&31)<<8 | luma>>2])
    texheader[0] bit 13 set and bit 14 clear: a translucent flat polygon, which
    the reference does not draw at all (`if (Translucent) return`).

The texture header is FOUR 16-BIT WORDS (texture_rom is u16*, texture_ram is
u16[0x10000]) at word address `tha & 0x3fffff` of the texture ROM (bit 23
clear) or `tha & 0xffff` of texture RAM (bit 23 set). Per polygon the header
address advances by `tho * 4` words AFTER the header is read, tho the signed
5-bit field attr[16:12]. gamma is `max((v-64)*255/191, 0)` -- the function
`m2_palette.sv` already implements for the tile layer.

*Where the data is in this core today:*
- Light and texture parameters: captured by the walker, consumed by nothing.
- Texture ROM: in SDRAM at byte 0x0e40000 (MRA), word 0x0720000, 8 MB; no
  reader.
- Texture RAM: the walker skips op 0x04 (texture/log data) by its count.
- Palette 0x1000-0x13ff: in `u_pal` (M10K, 8K x 16), port A the CPU, port B
  the tile pipeline EVERY PIXEL (`pal_addr = mixed`). No third port.
- colorxlat: the CPU's 48 KB at 0x01810000 are DROPPED except the 96 entries
  the tile layer reads (`r_addr[8:0] == 0x080`, the luma-64 row). There is no
  copy of the table anywhere.
- M10K: 553 of 553. Nothing more goes there (R221).

*Design.* Everything the polygon's colour needs that is not already in the
engine is put where the engine can read it through the port it already owns:
1. The bridge mirrors two CPU write regions into SDRAM: palette entries
   0x1000-0x13ff (byte offsets 0x2000-0x27ff of T_PAL) to PAL3D_BASE (word
   0x1730000, 1 K words) and the whole of T_XLAT to XLAT3D_BASE (word
   0x1731000, 24 K words), using the T_SDRAM write path (write-through,
   invalidate). The 96-entry tile tap stays. T_XLAT reads return the mirror.
   Both regions are free: PRAM1 ends at word 0x1730000, ST_BASE is 0x1F00000.
   A pulse from the bridge on either write invalidates the colour cache.
2. The engine's memory port grows a 2-bit space select beside the address:
   polygon memory (as now), texture ROM (word 0x0720000 + addr, 16-bit words
   read as the dword pair), the palette mirror, the xlat mirror. Model2.sv
   picks the base; the pair cache in front is unchanged (indexed by dword).
3. The engine, per polygon after R219's dotp: dotl (three multiplies, two
   adds, the same pool slots), the luminance (one multiply and one add
   against the texture parameters held as floats -- the walker's 8-bit
   values converted once at tp_we -- then a clamp and float-to-int), the
   header words 0 and 3 (two reads through the pair cache; translucent flat
   polygons culled like the reference), and the colour: a 256-entry direct-
   mapped cache keyed {colorbase, luma6} in MLABs (key 16 + rgb 24 bits) --
   a miss costs one palette and three xlat reads and the gamma function.
   Emits poly_col beside poly_attr; m2_geometry carries it to the clipper's
   in_col in place of the constant.
4. Texture RAM: the walker writes op 0x04's data (address bit 23 set;
   bit 23 clear is log RAM, for the texture LOD, skipped for now) into a
   128 KB region TEXRAM_BASE (word 0x1740000, 64 K x 16), the way it writes
   op 0x05 into polygon RAM; the engine's texture space selects RAM or ROM
   by tha bit 23.

*MEASURED on the boot bench through the title (16:30), the texture ROM now
loaded there (it never was: the first probe read 0xFFFF for every header
and said "every object translucent, textured, colorbase 0x3ff" -- an
unloaded region again, R154's lesson):* 1,917 objects; 58 (3%) have their
header in TEXTURE RAM (tha 0x018c000c -- the first six objects of every
list), 1,859 in ROM. Of those: 352 flat, 1,211 textured, 296 textured AND
translucent, 0 flat translucent, 21 checkered; 32 distinct colorbase
values (0x155 x241, 0x02c x208, 0x130 x180, 0x127 x108, 0x000 x94 ...).
So the title is mostly TEXTURED polygons, which this design still draws
flat in their palette colour, lit; that is the right intermediate picture
(shape, then shade, then texture), and the colour cache's 32 x 64 key
space says a 256-entry cache will hit almost always.

*Cost (with the texture RAM: +a walker write state and one SDRAM region).* ~+50 engine cycles per polygon on R217's 177 (header 2 reads, dotl
9, luminance ~15, colour 3 on a hit); ALM: the cache 16 MLABs (~160), the
float conversions and clamp ~150, the bridge mirror ~60, texparam floats 32
x 2 x 32 bits as MLABs. The M10K count does not move. Not done until the ALM
room from R221 is measured (dbuf16).

*Oracles.* (a) `tb_m2_geo_engine`: a float transcription of the reference's
luma against the engine's, over random normals, lights and texture
parameters, and the header address walk against the tho rule; (b) the
colour stage against a synthetic palette and xlat with the gamma function;
(c) the board: cars that are shaded, not white.

*R222, steps 1-3 at the desk (17:40).* Built as designed above:
1. `m2_cpu_bridge`: T_PAL bytes 0x2000-0x27ff and all of T_XLAT decode as
   T_SDRAM writes at base_pal3d (word 0x1730000) and base_xlat3d (word
   0x1731000) through the ordinary write-through path, the on-chip palette
   write and the tile layer's 96-entry tap taken beside them on the first
   pass; a `col_inval` pulse per mirrored write. Reads of both ranges come
   from the mirror. `make test_m2_cpu_bridge` 119 checks (the on-chip
   half-word data is the LOW half of the bus because the i960's LSU drives
   a halfword on both halves -- the test's first version drove only the
   upper half and "failed" the palette RAM that was right).
2. `m2_geo`: op 0x04 with address bit 23 goes down the polygon-data road
   into TEXRAM (word 0x1740000, 64 K x 16, wrapping), one 16-bit word per
   payload dword, low half only (`pd_tex` skips the DMA's high half); bit
   23 clear (log RAM) is stepped over by its count as before. `make
   test_m2_geo` 75 checks including the wrap at 0xffff.
3. `m2_geo_engine`: after R219's dotp, the same three multiplies and two
   adds against the light (dsel); |dotl| or 0 times the texture parameter's
   diffuse plus its ambient, both held as floats in a 32-entry MLAB filled
   at tp_we; f2i8 clamps and truncates as the reference's clamp-then-cast;
   header words 0 and 3 read through the port with `mem_space` = 1 (addr[23]
   = texture RAM), the address stepping by tho*4 after the read; a
   translucent flat header culls; the colour from a 256-entry direct-mapped
   MLAB cache on {colorbase, luma6} (valid bits cleared by col_inval), a miss
   costing one palette read (space 2) and three translation reads (space 3)
   with the gamma curve applied; `poly_col` beside the polygon, latched by
   m2_geometry with the vertices and handed to the clipper's in_col where
   the constant 0xC0C0C0 was. Model2.sv picks the base by space; the pair
   cache in front is indexed by the absolute dword so spaces cannot alias.
   `make test_m2_geo_engine` 36 checks: the three polygons' luma 98, 176,
   254 EXACTLY as the float transcription of geo_parse_np_ns gives, the
   colour equal to the transcription's palette -> table -> gamma for each,
   three misses; a light from behind gives the ambient alone (20) with one
   miss then hits, an invalidate one more miss; a translucent header culls
   all three. `test_m2_geometry` 30 (the lit colour reaches the clipper).

*R222 on the boot bench through the title (17:50):* PASS, and THE QUADS
CARRY 294 DISTINCT COLOURS over the 4,096 recorded (ffffff x385, 869a9a
x242, 000000 x220, 5c5c5c x200, 009475 x135, bd2100 x90 ...) where every
quad was 0xC0C0C0 before: real headers, real palette entries, real table
entries, on the game's own data. Cost: 9,436 -> 11,042 engine ticks per
object (+17%), 560 -> 647 per quad; 1,622 objects in the budget that held
1,880 -- the header reads, the second dot product and the colour misses are
all serial in the engine's one state machine. To be overlapped later (the
header read can be issued at E_ATTR, when attr is known, and consumed at the
colour step). One thing the bench also says: the walker wrote 0 texture RAM
words in the whole run while 55 objects (3%) point their header at texture
RAM -- so whatever fills texture RAM for those is not op 0x04 in the display
list within this window; those 55 read 0xFFFF headers (renderer 3, colorbase
0x3ff) and draw in whatever colour that maps to. Open: find the writer.
Building `build/lit1`.

**R223 -- THE REFERENCE DRAWS NO TRANSLUCENT POLYGON, AND WE WERE DRAWING
THEM OPAQUE. 16% OF THE TITLE'S OBJECTS.**

`model2_3d_render` picks `m_render_callbacks[(texheader[0] >> 13) & 3]` and
the table is {solid<false>, solid<true>, tex<false>, tex<true>} -- bit 13 is
the translucent flag, bit 14 textured. BOTH translucent entries return on
their first line (`if (Translucent) return;`, model2rd.ipp:63 and :184), so
the reference renders nothing at all for a polygon whose header has bit 13.
R222's first cut culled only the code-1 case (flat translucent) and drew
code 3 (textured translucent) as an opaque flat polygon in its palette
colour. The boot bench's header census says code 3 is 261 of the title's
1,659 objects -- SIXTEEN PER CENT -- and those are the shadows, glass and
smoke: solid grey wedges over the cars is exactly what drawing them opaque
looks like, and wedges over the cars is what the board has been showing.
Now any header with bit 13 culls. Blending is not built and is not the next
thing; not drawing them is what the reference does and is nearer right than
drawing them solid. `tb_m2_geo_engine`: headers 0x2000 and 0x6000 both emit
nothing and cull three, 0x4000 (textured opaque) still emits three.

*And what fills texture RAM, because nothing in the display list does.* The
walker decoded 47 `geo_texture_data` (0x04) commands in a whole run and
EVERY ONE had address bit 23 clear -- log RAM, the texture LOD table -- so
the 64 K-word texture RAM is never written, while 55 objects a list (3%)
point `tha` at it. MAME has no other writer either: `raster->texture_ram` is
touched only by raster command 0x04 (model2_v.cpp:921), which only
`geo_texture_data` pushes, and the i960's own texture RAM at 0x12000000 is a
DIFFERENT array (`m_textureram0/1`, the texel sheets). So in MAME those 55
objects read a texture_ram that `std::make_unique<raster_state>()` VALUE-
INITIALISED TO ZERO: header 0 means renderer 0, flat and opaque, colorbase
0, and they draw. Ours reads unwritten SDRAM -- 0xFFFF -- which means
renderer 3, and with R223 above they are now culled instead. Open: either
zero the TEXRAM region at boot to match the reference, or find the writer
the window we sample does not contain (the title may upload texture RAM
once, before M2_POLY_FROM). Not guessed at: measured next by running the
bench from instruction 0 with a texture-RAM write counter.

**R224 -- THE TINY-QUAD TEST WAS ON A BLOCK RAM'S WRITE-ENABLE PIN, AND
THAT BECAME THE WORST PATH IN THE DESIGN.**

`build/lit1` (R222's lighting) fitted at 83% but missed setup on clk_sys by
0.210 ns on s13 and 0.616 on s14, where `build/dbuf16` had made +0.556 on
every clock. The path was not the new arithmetic: it ran from
`m2_geo_clip.qsy[0][7]` to `m2_quad_store`'s vertex RAM `porta_we_reg`.
`is_tiny` is a min/max tree over eight 16-bit coordinates and it gated the
write enable, so a coordinate leaving the clipper had to cross that tree and
reach a block RAM's control pin inside one 20 ns cycle; lighting only made
the placement tight enough to expose it. Now the write enable is
`in_valid && has_room` alone -- every accepted quad is written at slot
`wcount` and only the COUNT is withheld when the quad is tiny, so a tiny
quad's slot is reused by the next one and the stored list is identical while
the comparator tree ends at a small counter. `make test_m2_raster3d`
unchanged (9,881 pixels a frame, six frames). Rule for the rest of the
renderer: a wide comparison may end at a register, never at a RAM's address
or enable.

*R223's second half, measured and then fixed (18:05).* The walker's opcode
histogram over a whole run: 0x00 nop 19,226, 0x01 object_data 1,627, 0x0b
matrix 1,342, 0x0a light 35, 0x09 focal 35, 0x08 zsort 24, 0x03 window 23,
**0x04 texture/log data 22 -- and every one of them addressed LOG RAM**, so
the 64 K-word texture RAM is written exactly never while 55 objects a list
read their header from it. Model2.sv now sweeps GAME_TEXRAM with zeros once,
in the boot writer's states 12-15 after the capture calibration (65,536
words through the arbitrated write port, ~3 ms, nothing waits on it), and
`cal_done` became `st_state >= 12` so the release it gates is not withdrawn
during the sweep. The boot bench's memory model zeroes the same region for
the same reason. Now those objects read header 0 -- renderer 0, flat,
opaque, colour base 0 -- and are drawn, as the reference draws them.

*R223/R224 on the bench (18:00):* the title's clipper input falls from
55,209 to 29,372 and its quads from 31,648 to 18,611 -- a third fewer
polygons reach the renderer, all of them ones the reference never draws --
and the 4,096 sampled quads still carry 280 distinct colours. PASS.

*R222/R223/R224 in the fitter (18:03): `build/lit2` fits all four seeds at
82% (34,482-34,548 ALM), M10K 553/553, and **s14 CLOSES TIMING OUTRIGHT --
every clock positive on both setup and hold** (clk_sys +0.611 setup where
lit1 was -0.210, HDMI PLL +0.094, hold +0.174 worst). Lighting, the colour
lookup and its cache cost about 50 ALM against dbuf16. Deployed s14.*

**R225 -- THE TOP OF THE SCREEN WAS BEING BUILT AND THROWN AWAY DURING
VERTICAL BLANK. A THIRD OF THE PICTURE.**

The board draws the 3D layer only from a band a little way down the screen --
a dead-straight full-width cut with the tile layer showing above it, at a
band index that does not depend on the scene. Photographs of the title put
it near line 92 of 384, band 12 with 8-row bands; R200 saw the same thing as
"the bars draw from band 13 down" and it was never explained.

`m2_raster3d` frees a band buffer when the beam has passed it:

    if (bd_ready[i] && (scan_band_f > bd_band[i])) bd_ready[i] <= 1'b0;

`scan_y` is the RAW line counter, 0..V_TOTAL-1 = 0..423 against 384 visible,
so through the 40 blanking lines its band index reads 48..52 -- past every
band in the picture. `frame_start` is the rising edge of vblank, so the fill
starts there, and every band it completed in those 40 lines was freed the
cycle after it was finished while `fill_band` advanced regardless. The frame
then opened with the first dozen bands already spent and nothing in any
buffer: the picture began wherever the fill had got to. The four band
buffers existed to give the fill a head start over the beam and it was
being destroyed every frame. `dbg_bands_done` reading 51 against NBANDS=48
had been saying so all along.

Fixed by clamping the crossed value to zero outside the visible area -- the
beam has passed nothing yet -- so the fill enters the frame with NBUF bands
standing and stalls, correctly, until the beam releases the first.

*And the bench could not see it, twice over.* `tb_m2_raster3d` pulsed
frame_start and swept the VISIBLE lines immediately, then idled 600 ticks
with `scan_y` parked on the last visible line: neither the head start nor
the out-of-range line numbers existed in it. It now sweeps blanking FIRST,
as the board does, at a clocks-per-scanline ratio that matches the board's
(the fill about as fast as the beam; `M2_R3D_TPL`, default 400), counts the
bands completed during blanking, and checks the top band paints. Reverted,
the RTL now FAILS it exactly as the board behaves: 15 bands built and
discarded in blanking, the top band empty, 6,724 pixels of 9,922 painted --
a third of the picture gone. Fixed: 4 bands held, top band painted, 9,922.
*And the first attempt at that control was itself wrong* -- the module has
two clock-crossing branches and the revert hit the unused one, so "fixed"
and "broken" measured identically and nearly had me record that the fix did
nothing. A control that shows no difference is a claim about the control.

**R227 -- 100/60/30 FROM A 1200 MHz VCO, AND EVERY RATE THAT HANGS OFF THE
CORE CLOCK.**

The geometry stage takes 13-16 ms of a 17 ms frame (R222's capture), so the
core clock is the throughput. Model 1 runs its 3D layer at 58.947 MHz and
its CPU at 29.47 and records the same fight -- "the shared FP pool measures
53.25 MHz" -- so 60/30 is a proven target on this part, not a hope.

A 1200 MHz VCO divides exactly into all four rates this core wants: 100
(/12), 60 (/20), 48 (/25) and 30 (/40). 800 could not: it gave 100, 50, 32
and 25, and 60 is not a divisor of it. The 32 MHz output existed for a 16
MHz dot clock at ce_pix = /2 and HAS NO USERS -- `ce_pix` is a 16/50
fractional accumulator on clk_sys, so the video already runs on the core
clock -- which is why moving that output to 48 costs nothing.

EVERY RATE DERIVED FROM clk_sys HAD TO MOVE WITH IT, and each one is a
chip that plays at the wrong speed if it does not:

    ce_pix            16/50  -> 16/60      the 16 MHz dot clock
    sound board       TICK_DEN 50 -> 60    the 68000's two 10 MHz phases
    YM3438            /6     -> 25/(3*TICK_DEN)   8.333 MHz at any core clock
    MultiPCM rate     CE_DEN 50 -> 60, OUT_DEN 50M -> 60M
    I/O board Z80     TICK_DEN 50 -> 60    4 MHz
    sound link        BYTE_CYCLES 16,000 -> 19,200   31,250 baud
    debug UART        DIVISOR 417 -> 521   115,200 baud
    I/O board         STATUS_CYCLES  5,072,464 -> 6,086,957     0.101 s
                      SELFTEST_CYCLES 126,086,957 -> 151,304,348  2.52 s
    debug heartbeat   HB_CYC 4,800,000 -> 6,000,000             100 ms

The YM3438 was the one that could not simply be rescaled: a divide-by-six
is 8.333 MHz only while the core clock is 50, and at 60 it is 10 MHz -- the
music a fifth sharp. It is now the same accumulator idiom as the 68000's
phases, 25/(3 x TICK_DEN), which is 1/6 at 50 and 25/180 at 60.

The last three are CYCLE COUNTS THAT ENCODE A DURATION rather than a ratio,
and they are the ones a clock change breaks silently: the I/O board's
self-test and status byte are a measured wall-clock delay the boot waits
on, not a number of operations. The projector's own timeout (1,023 cycles
in Q_WAIT) is left alone deliberately -- it is a runaway guard at 35 times
the expected latency, and it gets tighter in wall-clock terms, which is the
safe direction.

*Proof at the desk:* `make test_m2_sndboard` still matches MAME instruction
for instruction, and the measured sample period moves 1,120 -> 1,344 cycles
-- 60 MHz / 1,344 = 44,643 Hz, the same rate in absolute terms. The WAV is
NO LONGER byte-identical to the 50 MHz baseline and cannot be: the enables
land on different cycles. That oracle is for changes that must not move the
timing, and a clock change is not one.

*What this build is for.* The design's Fmax today is 51.9 MHz on the core
clock and 28.19 on the i960, so this WILL miss timing; the point is to
learn by how much and where. The two paths already known, from the 50 MHz
build ranked by slack: an OSD status bit (`status[21]`, the test-quad
enable) reaching the quad store's dropped counter, 0.733 ns of slack at 50
and -2.6 at 60; and the i960's float-convert unit reaching the writeback
mux, 4.53 ns at 25 and -2.14 at 30.

**R228 -- 100 AND 60 IS NOT A SLOW BUILD, IT IS A WRONG ONE. THE MEMORY
CLOCK MUST STAY AN EXACT 2:1 OVER THE CORE.**

`build/clk60` (100/60/30) fitted all four seeds at 84% and missed setup by
3.364 ns, and EVERY ONE of the thirty worst core-clock paths was
`m2_sdram -> emu` while every failing memory-clock path was the reverse.
That is not logic, it is arithmetic: 100 and 60 line up as five to three, so
the tightest launch-to-latch window between the domains is 3.33 ns where
100 and 50 give 10.00. The reported shortfall IS that window.

    memory / core     tightest window
    100 / 50   (2:1)      10.00 ns
    100 / 60   (5:3)       3.33 ns
    120 / 60   (2:1)       8.33 ns

And the ratio is not merely a timing convenience. `m2_sdram_x2`'s own header
says it: "THIS IS NOT A CLOCK-DOMAIN CROSSING, AND THE DISTINCTION MATTERS
-- both clocks come from one PLL at an exact 2:1 ratio, so their edges are
aligned and every slow-domain signal is stable across two fast cycles. There
is no metastability to synchronise away and no synchroniser here." Its
acknowledge is held for ACK_HOLD = 2 fast cycles BECAUSE that is exactly one
slow cycle. At 5:3 that is false, and the Kaneko core this was ported from
had already been bitten by an acknowledge one cycle too wide: it retired one
transaction twice and read the second time into the next one's data. So
100/60 would have been wrong on the board even had it closed timing.

120/60/30 comes from the same 1200 MHz VCO (/10, /20, /40) and restores
1:2:4 throughout. The cost is asking the SDRAM for 120 MHz where it measured
106.69 at a 100 MHz target, which is the open question this build answers.
Its device times are nanoseconds expressed in cycles, so they scale UP with
the clock: T_RCD and T_RP 2 -> 3, T_RAS 5 -> 6, T_WR 2 -> 3, T_RC 7 -> 9,
T_REFI 781 -> 937 (8,192 rows in 64 ms is one per 7.8125 us). The SDRAM_CLK
pin's phase moves with it too -- 180 degrees is 5,000 ps at 100 MHz and
4,167 at 120 -- and the read-capture depth is swept at boot against a known
pattern, so that part needs no hand-tuning.

*What clk60 also measured, and it is worth keeping.* With the fitter pushed,
the core logic reached 55.8 MHz (it was 51.9 at the 50 MHz target) and the
i960 reached 29.1 of the 30 asked, short by a single path from
`i960_fpcvt` into the writeback mux. So the logic is close; it was the
crossing that was hopeless.

*R228's build (20:50): `build/clk120` at 120/60/30 fits all four seeds at
84% and the crossing problem is GONE -- the failing paths are now honest
logic, each in one place:*

    memory 120 MHz   -2.112 ns   20 paths, ALL INSIDE m2_sdram      Fmax 95.74
    core    60 MHz   -1.735 ns   30 paths, hps_io -> m2_quad_store  Fmax 54.34
    i960    30 MHz   -1.010 ns   20 paths, i960_fpcvt -> writeback  Fmax 29.12

**R229 -- A USER SETTING WAS THE CORE CLOCK'S CRITICAL PATH.**

Every one of the core clock's thirty worst paths ran from `hps_io` into
`m2_quad_store`, and the signal was `status[21]`: the OSD's TEST-QUAD
ENABLE. Used raw off the framework's status word it fans out through the
quad source mux, the store's write path and its counters, and it held the
whole design to 54.3 MHz. `status[20]`, which gates the frame pulse that
starts the walk and the renderer's band schedule, is the same shape.

**The test-quad generator is deleted outright, not registered.** It drew one
known-good rectangle a frame and it had done its job -- it proved the store,
the sort, the band fill and the mixer before the geometry could feed them --
but once the geometry was real its only remaining effect was to cap the core
clock. A test injector that limits the product's clock has outlived itself,
and git holds it. `status[20]`, which is a real runtime control, is taken
through three flops on clk_sys instead. A setting a person
changes from a menu has no cycle-accurate relationship with anything, so
the registers cost nothing and give the fitter a local source to place
beside the logic it drives. The rule this is an instance of: **nothing off
`status` may be used combinationally in a datapath** -- it is a slow
control from another clock, and the fitter has no idea it is slow.

**R230 -- THE WEDGES: THE TWO VERTEX-REUSE OPTIMISATIONS ARE WRONG
TOGETHER, AND THE CACHE IS THE CHEAPER ONE TO DROP.**

The board draws long thin coloured wedges across the horizon. Reproduced at
the desk by rendering the boot bench's own emitted quads: the same wedges,
converging on the TOP-LEFT CORNER. Twelve of the 4,096 sampled quads have a
vertex at exactly (0,0), every one of them in slot 1 (v1, the carried
P0(n-1)), the other three vertices within a pixel or two of each other. A
tiny distant quad with one corner nailed to the corner of the screen.

*Two theories, both killed by measurement.* (a) A point behind the eye --
m2_geo_project answers a literal (0,0) for z <= 0, which is Model 1's rule
and not Model 2's (model2_v.cpp:661 divides unconditionally with FLT_MIN).
But every one of the twelve has a POSITIVE minimum z, 147 to 265, and not
one quad in 4,096 has z <= 0. (b) A projection abandoned on timeout, which
leaves the vertex at whatever position it already held: the counter reads
ZERO over a whole run. Both wrong, and both were plausible enough to have
been "fixed" without either being the cause.

*The control that worked.* Disable R218's clipper reuse: 12 -> 0 wedges.
Disable R217's strip cache: 12 -> 0 wedges. EITHER alone removes all of
them, so the fault is the pair -- the cache supplies a pixel and the clipper
then trusts it rather than re-projecting -- and neither is wrong by itself.

*Which to drop, measured rather than assumed:*

    both on            10,787 engine ticks/object, 12 wedges,  8.4% projecting
    strip cache off    11,067                       0 wedges
    clipper reuse off  12,088                       0 wedges, 17.2% projecting

The cache is worth 2.6% and the clipper's reuse 12%, so the cache goes.

*What is still not known, and it matters.* WHY the cached pixel is wrong
when the 3D coordinate beside it is right. The carry mapping was re-derived
from the reference's buffer rules for all three link types and matches the
engine's; `cvalid` is only set where all four pixels have just been written;
`poly_chain_ok` is cleared on a new object and on every cull including
R223's new one. 2.6% is worth recovering once that is understood.

**R231 -- THE BLACK SCENERY IS TEXTURED POLYGONS DRAWN IN THE COLOUR OF A
TEXTURE WE DO NOT HAVE. THE LUMINANCE SATURATES; IT DOES NOT COLLAPSE.**

The board draws most scenery black or wrong while the cars are nearly
right (a photograph of the V.R. screen: the tile layer visible at the top,
the rest of the picture a dark mass where the reference shows road, car
and trees). Black means a lookup returned zero, and the obvious suspect
was the luminance. Measured on the boot bench over 180,017 polygons: ZERO
at luma 0, and 155,972 (87%) in the top sixteenth -- the luminance
SATURATES at 255, because the game's texture parameters are mostly
255/255 (indices 3 and 8-21) and ambient 255 alone clamps the sum. (The
first attempt at this probe sampled only on cycles the engine was fetching
and reported zero polygons and zero texture parameters, which would have
read as "the game sets none" against a histogram counting 38 of them --
moved to run every tick.)

So the black is downstream. Read back out of the bridge's SDRAM mirrors
exactly as the game wrote them: the translation table is WRITTEN (1,739 of
the 2,048 words per channel the flat path can read) and ramps as it should
-- component 16 runs 00, 48, 4b ... ff over luma 0..63, component 31
reaches ff by index 32 -- and the 3D palette has 1,004 of 1,024 entries.
Colour bases 0x155, 0x02c, 0x130, 0x127 give white, white, ff4500 and
ffff45 at luma 255, which are the colours the quads carry. Colour bases 0
and 1 are palette entry 0x0000: BLACK. They are 182 of the title's 1,859
objects, and they are the TEXTURED ones -- a textured polygon's colour base
is not a colour, because the reference paints its texture sheet through
the luma RAM there and never reads the palette for it. We painted the
colour base. That is the black.

Until textures exist a textured polygon takes a mid grey, 16 of 31 on every
channel, through the same translation table and gamma as a flat one: lit,
with shape, and honestly a placeholder. One flag in the colour cache key
keeps it apart from real colour bases, and it skips the palette read.
`tb_m2_geo_engine` 40 checks: the textured-opaque header emits grey at its
luma through the reference's own table arithmetic.

**R232 -- THE CARS "CRASH" ALL THE TIME, AND THAT IS A COPROCESSOR
QUESTION, NOT A GEOMETRY ONE.**

The user's description: the cars jump and flip exactly like the crash
animation when they hit a wall, but continuously. The transform's matrix
order was checked against the reference and matches, and the walker loads
the twelve words in stream order, so the geometry is drawing what it is
told. What tells it is the game, and the game decides a crash from the
coprocessor's collision and height-map arithmetic on its own data ROM.
R212 found two of the four maths units (atan, reciprocal) were still Model
1's and that gave the jumping background; sine/cosine and inverse square
root have not been compared the same way. Next: `M2_COPRO_TRACE` against
MAME's mb86233 for those two ops, and a look at what the collision code
reads from the copro data ROM.

*R231 on the boot bench (22:50):* the title's sampled quads carry 130
distinct colours where they carried 320, and the commonest are now greys --
727272 x590, 323232 x380, 626262 x288, a6a6a6, e6e6e6 -- in place of the
black; 267 black remain, flat polygons whose colour base is genuinely entry
0. Textured scenery is lit grey with shape. PASS; `build/fix3d2`.

*R232, two suspects cleared by inspection and one left to measure:* the
sincos and isqrt units match model2.cpp's copro_sincos_r and copro_isqrt_r
line for line -- angle mirror and sign, index from the operand's mantissa,
exponent adjusted by 0x3f minus the operand's, the cosine read's sign
cleared -- and the table quadrants are the reference's (0x0000 sincos,
0x4000 atan, 0x8000 inv, 0xc000 isqrt). The data window matches
copro_tgp_memory_r: bank register bits 23:16 over the offset, bit 23 the
data ROM, else bit 22 the buffer RAM masked to 0x7fff. What does NOT match
is the ROM's address width: the reference masks to its region, 8 MB, and
returns ZERO above the 4 MB that is loaded; this core's `dat_addr` is 20
bits and a read above 0x100000 dwords aliases onto the loaded half -- the
same shape as the 19-bit fault the comment on that line records. The bench
now counts data-ROM reads by range over a whole run to say whether the game
ever goes there.

*R232, the third suspect cleared (23:20):* over a whole run the coprocessor
issued 11,813 data-ROM reads and NONE at or above dword 0x100000; the
highest was 0x01e23b, inside the loaded 4 MB by a wide margin. The 20-bit
address does not alias anything the game touches. So sincos, isqrt, the
banked data window and the ROM range all match the reference, and the
continuous crash animation is not explained by anything in the
coprocessor's memory path that the bench can see. What remains is what it
COMPUTES: the next measurement is the coprocessor's FIFO exchange
(`M2_COPRO_TRACE`) against MAME's over the same frames, looking for the
first result that differs -- the method that found R212.

*R230, not all of them (23:15):* the board still shows a few wedges coming
off the CARS with the strip cache off. The desk sample that read zero was
4,096 quads at one moment; a 65,536-quad capture over a later stretch is
running to find them at the desk before anything is changed.

**R233 -- THE STORE OVERFLOWS ON THE BUSIEST FRAMES, AND THE TINY THRESHOLD
IS THE LEVER THAT IS FREE TONIGHT.**

The board occasionally shows a car in silhouette over bare tiles with every
piece of scenery gone. The capture's first stretch has the store DROPPING
1,242 and 1,898 quads in single frames with the count pegged at 2,048: the
list runs over, the car at its head survives, the scenery behind it is
lost. Zeroing texture RAM (R223) brought back the objects at the head of
every list and tipped those frames over. The user had said "but we will
lose quads" when halving the banks was floated to fit; this is that.

Measured on 17,853 clipped quads from the boot bench: the 2 px test refuses
39%; 3 refuses 49% and 4 refuses 56%, the extra covering at most 0.13% and
0.24% of painted pixels. TINY = 4: a 3,900-quad frame stores ~1,700.

*The other two levers, for when this is not enough:* (1) the tile character
cache is 134 of the chip's 553 M10K blocks -- a quarter of all memory -- and
the quad store's two banks ~90; halving the cache doubles the store, after a
hit-rate measurement. (2) The HPS DDR3 is untouched (Model2.sv ties every
DDRAM_* pin to zero): the character data, or the sorted list itself, could
live there behind a small cache, which is how the memory would stop being
the binding resource at all. Both are proper jobs.

*And the coprocessor is not the speed lever.* R202 established that 0x030B
is the microcode's FIFO WAIT; this evening's capture has the coprocessor
there 37% of the time, the i960 waiting for the frame 34%, the walker
waiting for the engine 38% and the engine idle 62%. Nothing is saturated:
the geometry is a serial chain, one object at a time through walker, engine,
projector and clipper, and its own Fmax caps the core at 60.3 (R227). The
throughput is in overlapping that chain and in the fill's per-band cost,
not in the coprocessor's clock.

*R230, the remainder (23:50):* with the strip cache off, 17,853 clipped
quads from a later stretch and 14,477 more under the board's own port
timing (`M2_GEO_LAT=12`) carry NO vertex at the corner, nothing at the
saturation limit and no interior wedge. The 36 three-clustered-one-far
shapes the wider net caught are slivers ON the screen edge -- x = 0 or 496,
y = 384 -- which is a large road polygon fan-triangulated after the clip,
correct and the reference's own shape. The few wedges the board still shows
off the cars are therefore not reproducible at the desk with what the bench
models; the cars are in the crash animation continuously (R232), and a car
mid-roll is odd geometry in its own right. Left open, attached to R232.

*R231 in the fitter (23:55): `build/fix3d2` fits all four seeds at 83%
(34,645-34,684 ALM); s15 meets EVERY clock, setup +0.165, hold +0.212, the
third build of the day to close outright. Deployed. `build/fix3d3` = fix3d2
+ TINY = 4 (R233), in the fitter behind it.*

**R234 -- THE PLACEHOLDER TURNED BLUE CARS WHITE. THE CARS ARE TEXTURED, AND
THE REFERENCE READS THE PALETTE FOR THEM ALL THE SAME.**

`build/fix3d2` on the board: "too much light, the car colours are
saturated -- blue is now white". R231's placeholder gave EVERY textured
polygon a grey and sent it through the table at the polygon's luminance,
which is 255 for nearly all of them (the game's texture parameters are
255/255 on those indices, R231's measurement), and the game's own table
maps index 63 to full on every channel: grey at 255 is white. The cars'
liveries are texture sheets, so the panels that had been blue -- drawn
from their colour-base palette entry before R231 -- went white.

What the reference does for a textured polygon (model2rd.ipp, textured
case): reads `palram[colorbase + 0x1000]` exactly as for a flat one, and
per texel takes `lumaram[...] * object.luma / 256` as the luma index -- the
TEXEL's brightness scaled by the polygon's. So the polygon luma of 255 is a
multiplier, not a brightness, and texels sit mid-range.

The placeholder now: the palette entry when it is not black (the liveries),
grey only where it is black (most scenery, whose colour base is 0), and
HALF the polygon's luminance, which is what a 128-of-256 texel gives --
index ~31 rather than 63. The cache key carries the textured flag beside
the colour base and the halved luma, so a textured and a flat polygon on
the same entry never share a line. `tb_m2_geo_engine` 41 checks: a
textured header keeps its palette entry at half luma; a textured header on
a black entry takes the grey.

*The light vector itself is not the fault.* Read out of the reference's
own display list (Lua over bufferram): (0.437936, -0.914406, -0.411307),
length 1.094, the same every frame; and R222's engine test proved the
luminance arithmetic to the integer. The bench is measuring what the walker
holds and the rotated normals' lengths to close the last two inputs.

**R235 -- THE BOARD CATCHES ITS OWN WEDGES.** "That's why you check over
UART. Sim never matches." The remaining wedges off the cars do not
reproduce at the desk under any modelled condition, so the board now
latches the first quad per stretch that leaves the clipper with three
vertices within 8 px and the fourth more than 60 px away, all four strictly
inside the screen (an edge sliver is the clip's own correct shape), and
streams it as two records -- 'W' {x0,y0,x1,y1} then 'X' {x2,y2,x3,y3} --
in place of two 'H' records; a running count and the slot (1 = the carried
v1, 0 = the carried v0) ride in every 'H' where the tiny-refused count was.
`tools/decode_uart.py` prints them. In `build/fix3d4`.

*R234, corrected by the board (23:45):* "the build before had the right
lighting" -- fix3d, which drew a textured polygon in its palette entry at
the polygon's full luminance. So that is what it does again; halving was a
guess about texel brightness and the board says no. Only a textured polygon
whose palette entry is BLACK, which carries no colour information at all,
takes the grey, and only that one at half luminance, because grey at 255 is
white on this game's table. `tb_m2_geo_engine` 41 checks. `build/fix3d3`
(which had the halving) was stopped in the fitter; `build/fix3d4` = fix3d2
+ TINY 4 (R233) + this + the wedge catcher (R235).

*R234, the last two inputs measured (23:50):* the light vector the walker
holds is (0.438068, -0.912499, -0.415382), length 1.09412 -- the reference's
own display list gives (0.437936, -0.914406, -0.411307), length 1.09412,
the same to five figures (the components turn with the camera between the
two capture moments); and the rotated normals are unit, mean 0.998, 28,344
of 28,464 within 0.9-1.1. With R222's arithmetic proved to the integer,
every input to the luminance is now verified. The saturation was the
placeholder alone.

**R236 -- THE SEED RULE, WRITTEN DOWN BECAUSE A NUMBER CHOSE WRONG.**
`build/fix3d4` (fix3d2 + TINY 4 + R234 + the wedge catcher) fits three
seeds at 83% (34,891-34,940 ALM). Seed 11 has the best setup figure of the
batch, -0.022 ns -- and it is on the MEMORY clock. Seed 14's -0.172 is on
the framework's HDMI PLL alone, the miss every working build of this
project has carried. An automated "positive hold, best setup" picker chose
11 and was stopped before it copied. The rule is now `tools/pick-seed.py`:
eligible only with positive hold everywhere and NO setup miss on any emu
PLL clock; HDMI-only tolerated; then best worst-setup. Deploying s14. The
integration bench on this tree: PASS, 451 colours over 17,853 quads, the
luminance histogram unchanged.

*R234 confirmed on the board (00:05, 09-12): "colours look good" on
`build/fix3d4` s14 -- the palette colour at full luminance for textured
polygons, grey at half only on a black entry. What the board still shows:
stray quads off the cars (the catcher in this build is streaming them) and
the cars barrel-rolling in the crash animation continuously (R232, the
overnight trace).*

**R237 -- THE BOARD'S OWN WEDGES: A CARRIED VERTEX WITH THE RIGHT y AND THE
WRONG x.** `build/fix3d4` s14, 92 frames of the title: 165 quads caught by
R235's catcher, every one with the stray vertex in slot 0 or 1 -- the two
vertices a strip carries from the previous polygon -- its y within a pixel
or two of the other three and its x displaced 70-180 px; over consecutive
frames the stray x sits near 150-170 while the true cluster moves with the
car (297 -> 312 -> 335). So the vertex's y was projected correctly and its
x was not: the projector forms sx and sy as two separate multiplies through
the shared float pool, and an x product taken from the wrong transaction
gives precisely this shape. No desk run reproduces it -- 32,000 quads with
the strip cache off, with and without a FIXED port latency -- and the board
differs from every one of those in the TIMING of its memory acknowledges,
which sets the interleaving of the pool's clients. Next: a randomised port
latency in the bench to search the interleavings.

*And R233 on the board:* store drops 35 at worst in the boot stretch against
1,242 and 1,898 before; quads pegged at 2,048 only at the very start. The
silhouette frames should be gone.

*R237, the next measurement (00:06, 09-12):* the C record's twelve
scroll-probe bits (R212, closed) now carry `geo_pj_lost[11:0]`, the
projections the geometry abandoned on timeout. On expiry it moves on WITHOUT
resetting the projector, so the late result is taken by the next vertex --
the one path found by inspection that hands a vertex someone else's screen
position. Zero over every desk run; captures before `build/fix3d5` show
scroll values in those bits, not this. In the fitter.

*R237, the desk search (00:20):* with each port latency drawn at random
from 1..24 cycles -- the interleavings of the pool's clients as the board's
varying memory timing would produce them -- 14,240 clipped quads carry no
interior wedge. Fixed latency, random latency, instant: none. Whatever
makes the board's carried vertex take a wrong x is not the RTL's response
to memory TIMING. The next candidate is memory DATA: a vertex is three
floats read through port 4 and the pair cache, and one wrong 16-bit half of
the x float -- a bus or capture fault of the R82 kind -- gives exactly a
wrong x beside a right y, carried into the next polygon as v0/v1. The
core's port-4 sweep (tools/rom_csum.py's fold) was built to test that
path's data integrity on the board; putting its fold on the UART is the
test.

**R238 -- THE DATA-INTEGRITY SWEEP, REVIVED ON PORT 2 AND PUT ON THE UART.**
The port-4 sweep (tools/rom_csum.py's fold, an OSD-selected 2 MB region read
back through the SDRAM and folded to 24 bits) was dead: its request was
wired to no port, it waited on port 4's acknowledge -- the walker's and
engine's port since R167/R214, and a one-word port where the sweep expects
the four-word burst -- so it sat in its read state taking the engine's
acknowledges as its own. It now runs on port 2 behind the copy engine and
the calibration reads, both idle once the game runs, and each completed
fold goes out as an 'S' record {region, runs | fold}. Expected folds of the
image, from the MRA and the ROMs: region 11 = 82B1E2, 12 = A76A16, 13 =
1B298F (the polygon ROM spans regions 11-17). Region 0 is the control the
sweep was proved on. If a polygon-ROM region MISMATCHES, R237's wedges are
a data fault on the read path, not the geometry.

**R239 -- THE TEXTURE PLACEHOLDER'S BRIGHTNESS IS AN OSD OPTION, BECAUSE THE
BOARD IS THE ONLY JUDGE OF IT.** "Still too bright." The reference scales a
textured polygon's luminance by each texel's own, and texels average well
under full; with no texels, the palette colour at the polygon's full
luminance over-estimates. Full was judged right, then too bright; half was
built and never judged; a build per guess is the wrong instrument. So
"Texture brightness" -- 100%, 75%, 50%, 25% of the polygon's luminance for
textured polygons with a palette colour -- is OSD option O[22:21], in the
bits the deleted test-bar options held (R229), taken through three flops
on clk_sys as every status bit that reaches the datapath must be, and a
change empties the colour cache so nothing stale is served. The grey-for-
black case stays at half regardless. `tb_m2_geo_engine` 41 checks at mode
0 unchanged. In `build/fix3d6` with R238.

*R237's build (00:46, 09-12): `build/fix3d5` fits all four seeds at 84%
(34,970-35,036 ALM) and THREE meet every clock -- s14 setup +0.250, hold
+0.204, the cleanest of the day -- picked by the rule and deployed.
`build/fix3d6` (R238 sweep + R239 brightness option) confirmed to carry both
in its copied tree; in the fitter.*

*R238, what the desk lint missed (00:50):* `build/fix3d6` failed synthesis
in under a minute -- "Can't resolve multiple constant drivers for net
sw_pend": the fold-pending flag was set in the sweep's always block and
cleared in the stream's. `make lint_top` reports port, implicit, undriven
and missing-pin classes and was silent on MULTIDRIVEN, which Verilator does
flag under -Wall. The rule now reports it, and a sweep of the whole top
with the class enabled finds no other. The flag is one driver: the stream
block raises a one-cycle `sw_take`, the sweep block clears its own flag on
it. Build restarted 00:48.

*R237 on `build/fix3d5` (00:55, 09-12): projections abandoned on timeout =
ZERO over 240 s on the board -- the late-result path is excluded. 304
wedges streamed; the clean pairs repeat the signature: stray (167,188) or
(168,189) against a cluster at (297-299, 187-190).* And the cluster's y is
the point: 188 is four rows off the projection centre (192), so the
vertex's VIEW y is near zero. A wrong RECIPROCAL -- a wrong z, or the
quotient of someone else's divide -- moves sx by the whole error and sy by
almost nothing there. "Right y, wrong x" does not single out the x
multiply after all; it is exactly what a wrong 1/z looks like at the
horizon. The divider is one unit shared by the projector (client 3) and
the clipper (client 2); the clipper divides only when a plane cuts, so the
interleaving is rare and timing-dependent -- the board's, not the desk's.
Next at the desk: the pool's divide path under two clients issuing
back-to-back, checking each quotient reaches the client that asked.

*R237, the divider (01:10, 09-12): NO WINDOW. fp_div leaves S_DONE and
raises out_valid in the same cycle, so `busy` falls one cycle before the
result is seen -- but the pool's issue is also gated on `div_outstanding`,
which clears only on d_valid, so a second client cannot take the unit
until the first quotient has been routed by `dtag`. The shared divider is
not the mechanism. What is, is below.*

**R240 -- THE SDRAM BURST WRAPS INSIDE THE ROW, AND THE PAIR CACHE KEPT THE
WRAPPED WORD AS "THE NEXT DWORD".** m2_sdram issues its four columns by
incrementing the COLUMN FIELD alone (S_RD: "bursts wrap inside the open
row"), which is correct for the device -- the next row was never
activated -- and is why every burst port "must be burst-aligned". The two
pair caches on port 4 (R214) are not: a dword index N is word 2N, aligned
to two words, and the port's upper half is trusted as dword N+1. When N is
the LAST dword of a row (its nine column bits all ones with COL_BITS=10),
words 2N+2 and 2N+3 come from the row's FIRST columns, and the cache
serves the row's first dword as N+1. Whether a stream is hit depends on
its parity: a run that reaches the row edge with the odd index on the
port (miss at N, hit at N+1) takes the wrong dword; the other parity has
N+1 on the port and is right. One vertex coordinate wrong, its neighbours
right -- a wrong x with the right y is what the wedge catcher streamed
(R237), and a wrong matrix or normal word read the same way is a
candidate for the rest.

Why the desk never showed it: `tb_m2_boot` serves the walker and the
engine 32 bits at a time from a flat array, with no pair cache in the
path; the pair-cache bench's port model returned mem[N+1] with no row.
The other burst consumers are aligned and safe: the i960 bridge's line
is {sd_word[AW:3],2'b00}, the character cache's {tag,idx,2'b00}, the
68000's {addr[17:3],2'b00}, the sweep steps by four; ports 8/9 and 2 take
[31:0] or [15:0] only.

The fix is at the consumer: `m2_pair_cache` takes COL_BITS and keeps no
copy when the answered index's column bits are all ones (`have <=
~&idx[COL_BITS-2:0]`), so the dword after a row edge goes to the port.
One extra port trip per 512 dwords. The bench's port model now wraps as
the controller does; two streams across the edge, one of each parity,
1536 read as the row's first dword with the fix removed and right with
it (4,270 checks). Both instances in Model2.sv pass SDR_COL. To carry to
the board in `build/fix3d7` after `fix3d6`'s fitter finishes; the wedge
count over 240 s is the measure (304 on fix3d5).

**R241 -- THE BAND STRIPES ARE THE FILL'S PER-QUAD SETUP, AND MODEL 1 HAD
ALREADY HALVED IT.** The board's H records (fix3d5/6) say every list's 48
bands complete within the frame (bands_done 51) and nothing is dropped, so
the stripes the user sees through a car -- rows of 2D where the 3D should
be -- are not a frame-level shortfall but a BAND-level one: a band buffer
is released to the beam whether or not its fill has finished, and with
NBUF=4 the fill can lead the beam by at most four bands. The beam gives a
band 8 lines = 315 us = 15,700 core cycles. Measured at the desk
(`$S/fillcyc`, the filler alone with span_ready high, one band as the
replay presents it): a 2x2 quad cost 55 cycles, a 6x4 rectangle 57, a
small skewed quad 117, a quad reaching the band from above 92. The store's
replay scan (one quad a cycle, ~1,000-2,000 a band) runs in parallel and
is not the limit; the filler is, at 130-280 quads a band. A car is a few
hundred quads in two or three bands. The cost is setup, not pixels: the
band buffer already paints four pixels a cycle; the edge-slope divides --
sixteen cycles each, two or more a quad, serial -- are.

Model 1 measured the same ("the divider IS the fill", then "47% of the
worst band's fill") and fixed it twice since our copy at `085a00e`: a
reciprocal table (`m1_recip_rom`, recip[d] = ceil(2^32/d)) gives the
quotient as (n * recip) >> 32 with one multiply-compare correction, exact
for any 32-bit numerator, four cycles instead of nineteen; and the fill
issues both edge divides at once (`u_div`, `u_divb`). Both ported here as
`m2_raster_div`, `m2_raster_fill` and the new `m2_recip_rom` at Model 1
`a7abcbf`, renamed only, with ONE change: the table is 512 entries in
MLAB, not 1,024 in M10K -- this design's 553 M10K are all in use (R221),
and its vertices reach the store clipped to the viewport, so a scanline
difference is under 384; |den| >= 512 still takes the restoring path.

Measured after the port, same cases: 2x2 20 cycles (was 55), 6x4 23 (57),
skewed 53 (117), from-above 43 (92). Bit-identical: the filler's own
corpus, 152,025 quads and 31.68 M spans against the C reference, 0 fails
-- the bench had been carried since the copy but never wired into the
Makefile; `test_m2_raster_fill` and `test_m2_raster_band` now exist.
`test_m2_raster3d` 8/8, `lint_top` clean. The ALM cost is the table
(~260 in MLAB or logic) and a second divider. To carry to the board as
`build/fix3d8`; the measure is the user's stripes, and the H record's
bands_done stays as the frame-level check.

**R242 -- THE i960's `bno` WAS NEVER TAKEN, AND THAT IS WHERE THE GAME
LEAVES THE REFERENCE (R232).** Established from the reference outward, not
from a theory: the coprocessor's arithmetic is exonerated first (every
stateless command, and 0x1a keyed by its 0x12 and 0x41 by its 0x40, gives
the reference's output for the same inputs across ~50,000 transactions,
`$S/copro_stateless.py`), then a from-boot coprocessor trace aligned
against a MAME tap of frames 0-3800 -- clean NVRAM as well, to exclude the
settings -- agrees RECORD FOR RECORD through the first 0x11 matrix
readback (bench frame 248, MAME frame 162) and diverges on the very next
command: the reference issues 0x05/0x00/0x12 (the next object's set-up),
ours issues 0x1a (a point transform) 39 times. MAME's frame-162 instruction
trace (`tools/mame_i960_frame_trace.lua`) and its disassembly put both
sides in the same routine at 0x84e0: per object, `ldos 0x2e(r6)` (type),
`ld 0x501520[r3*4]`, `chkbit r4,r3`, `bno 0x85f8`. Our PC trace of the
same call (new: `M2_BOOT_PCFRAME=<video frame>` gates the bench's PC
trace by frame): 39 iterations both sides, bno TAKEN 39/39 in MAME, 0/39
here. Not the data -- the branch.

`i960_top.sv` executed every b<cc> (0x10-0x17) as "taken if `ac & cond`
is non-zero". For bno the condition field is 000, so it could never be
taken. The i960 defines bno as taken when NO condition bit is set --
MAME's `if(!(m_AC & 7))` for 0x10, the same special case this core already
made for faultno (0x18) and testno (0x20). The lockstep could not see it:
`sim/i960/i960_cpu_ref.h`, the transcription the RTL is checked against,
carried the identical `bxx(insn, d.op & 7)` for 0x10, and the generator
never emitted a conditional CTRL branch at all (class 1 was `b`/`bal`
only). Fixed in the RTL (0x10 branches on `~|ac[2:0]`, no IP mask, as
faultno), in the transcription, and in the generator (half of class 1 is
now 0x10-0x17); `test_i960_top` passes, 0 mismatches, with bno in the mix.
`lint_top` clean. Reaches the board with `build/fix3d8`.

What it explains: every `bno` in the game fell through. In this loop that
sends every object down the "transform and score" path; the same
`chkbit; bno` idiom is how the program tests flag bits, so the crash state
that plays continuously (R232) is the expected face of it. The desk check
is the same trace alignment past frame 248 (`$S/long/trace2.txt`, running);
the board check is the cars.

*R242, the test's own check (01:50): with the RTL's bno arm disabled in a
scratch copy of `rtl/cpu/i960` and the same corrected transcription and
generator, `test_i960_top` FAILS at retire 14 -- "IP got 00000144 want
00000150", a bno the reference took and the mutant fell through. So the
bench now sees the class of bug it had been standing in front of.*

*R242 at the desk (01:58, 09-12): with the fix, the from-boot coprocessor
trace agrees with the reference's tap for ALL 1,024,289 records through
bench frame 656 (MAME frame 417), well past the frame-248 divergence -- the
i960 now follows the game's path the reference follows. `build/fix3d8`
carries it to the board with R240 and R241.*

**R243 -- THE RECIPROCAL TABLE HAS TO BE MLAB, AND `ramstyle` ALONE DOES NOT
DO IT ON A DUAL-PORT ARRAY.** `build/fix3d8` (R240+R241+R242) failed the
fitter on all four seeds: "Can't place all RAM cells -- the design requires
556 memory locations of type M10K block", 553 on the device. Nothing but
R241 had touched memory. The map report names the cell:
`m2_raster_fill:u_fill|m2_recip_rom:u_recip|altsyncram:recip_rtl_0`, 16,384
bits. The array carried `(* ramstyle = "MLAB" *)` and Quartus inferred an
altsyncram in M10K anyway, because it has TWO READ PORTS and an MLAB has
one. Model 1 can afford that form; this design was at 553 of 553 before
R241 (R221).

Fixed by giving each divider its own copy -- two single-read-port arrays,
which the attribute is then honoured on -- and by dropping the table to 256
entries, so a copy is 8,192 bits, 13 MLABs. A denominator is an edge's
height in scanlines; |den| >= TN still takes the exact restoring path, so
the unit is correct for every input and only the fast-path hit rate moves.
The filler's corpus is unchanged and passes (152,025 checks, 0 fails).

Also at the desk, for R240: the boot harness can now instantiate the two
pair caches (`-GPAIR_EN=1`), with the bench serving their port the way
m2_sdram does -- the pair taken by incrementing the column INSIDE the row,
so a row's last dword pairs with the row's first. That is the configuration
no desk model had, and it is what the board runs.

**R244 -- THE PAIR CACHE BECOMES AN OSD SWITCH, AND THE BEAM'S MISSED BANDS
REACH THE UART.** `build/fix3d8` (R240+R241+R242) on the board: the cars
drive correctly for the first time -- the user's words, "cars are driving
like they are meant to, no more flipping" -- which confirms R242's `bno`
on hardware. What remains, reported by eye: scenery still wrong or
missing, cars flashing on and off between frames, and the lighting
swinging between blown-out and completely black from scene to scene.

The board's own numbers for that capture: every list completes its 48
bands (bands_done 51 in every steady slice), the store drops NOTHING,
quads per frame run 272-1,584 against the store's 2,048, and the collect
holds the list ONE extra frame almost always (hold 1 in 91-105 of every
112 frames). So the renderer is not losing quads and not running out of
bands; the list is simply taking two frames to build, and what is drawn
alternates.

Two instruments for the next board run:
1. `O[25],Pair cache,On,Off` -- `m2_pair_cache` gains a `bypass` input that
   keeps no copy at all, so every read is a port read. R214 put the cache
   there for throughput and R240 found it serving the wrong dword at a row
   edge; what remains is a copy that can go STALE when the CPU or the TGP
   rewrites a dword between two consecutive reads of a stream, which is
   exactly the shape of "an object is there one frame and gone the next".
   The switch answers in seconds what another build would answer in 25
   minutes. The bench checks the bypassed stream costs one trip per word
   and reads correctly (4,451 checks).
2. The H record's `dropped` field was 16 bits and always zero; its high
   half now carries `r3d_missed[7:0]`, the count of scanlines whose band
   had no ready buffer when the beam arrived. That is the direct measure
   of the stripes, and it has never been on the wire.

**R246 -- THE POLYGON'S SORT DEPTH IS CHOSEN PER POLYGON, QUANTISED, AND A
POLYGON WHOLLY BEHIND THE EYE IS CULLED. WE DID NONE OF THE THREE.** The
user, on `build/fix3d8`: "it almost seems like the track/scenery is being
drawn over the top of the car". That is painter's order, so the question
is what the reference sorts by. `src/mame/sega/model2_v.cpp`, read
directly (fetched to the scratchpad rather than recalled):

    switch ((attr >> 10) & 3) {
      case 0: zvalue = raster->polygon_z; break;   // the PREVIOUS polygon's
      case 1: zvalue = min_z;             break;
      case 2: zvalue = max_z;             break;
      case 3: zvalue = 1e10;              break;
    }
    raster->polygon_z = zvalue;                    // carried, culled or not
    ...
    object.z = float_to_zval(zvalue, raster->z_adjust);
    zpoly = raster->poly_sorted_list[object.z];    // a 16-bit bucket

This core took the MINIMUM for every polygon and sorted on the full 32-bit
float. Three separate departures:

1. **The mode.** `attr[11:10]` now reaches `m2_geometry` from the engine as
   `poly_zmode`, and the depth is the previous polygon's, the minimum, the
   maximum or 1e10 accordingly. `raster->polygon_z` is carried in `zprev`,
   updated for culled polygons too, and reset to 1e10 as `render_frame_start`
   does. A car drawn at its minimum z while the road it sits on is drawn at
   its maximum is exactly one object swapping in front of another.
2. **The quantisation.** `float_to_zval` rounds the mantissa to twelve bits
   under a biased exponent, so the reference's sort is COARSE and everything
   within one part in 4,096 ties and keeps the list's order -- the game's own
   choice for coplanar work like road markings. Sorting on the full float
   reorders exactly those against each other. `zval()` in `m2_geometry` is the
   transcription, `m2_quad_store`'s key is now that 16-bit value complemented,
   and KW drops from 24 to 16 (which also returns an M10K). The bias comes
   from geo op 0x08, whose operand the walker used to step over and now
   captures as `zadj_e` -- `(z_adjust >> 23) & 0xff`, Daytona writes
   0x40800000.
3. **The cull.** `check_culling` refuses a polygon whose `max_z < 0` -- every
   vertex behind the eye. The four clip planes all pass through the origin, so
   such a polygon survives them and projects to nonsense; this is a candidate
   for the wedges that remain after R240. Counted as `dbg_behind`.

The fourth test in `check_culling`, `master_z_clip`, is NOT implemented and
does not need to be: a Lua tap on 0x0181c000 over 900 frames of Daytona
shows one write, of 0xff, which is the value that disables it.

Direction is unchanged and worth recording, because MAME's loop runs
`for (z = min_z; z <= max_z; z++)` -- near to far. That is not a painter; the
Model 2 hardware has a Z-BUFFER (study §2.1) and MAME tests it per pixel, so
near-first is the early-out order and equal z means the first drawn wins.
Our painter draws far-first, and a stable sort leaves ties in list order, so
the last-submitted of a tie is drawn last and wins the pixel -- the same
outcome. `tb_m2_geometry` checks all of it against a C transcription of
`float_to_zval`: zmode 1 gives 0x0800, zmode 2 gives 0x1400 on the same quad,
zmode 3 gives 0xffff, and a polygon at z = -2..-5 is counted behind, never
reaches the clipper and emits nothing (39 checks). With the mode forced back
to "always minimum" the zmode-2 check fails, so the bench sees the bug it was
blind to. `test_m2_geo_engine` 41, `test_m2_geo` 75, `test_m2_raster3d` 8,
`lint_top` clean.

**R247 -- THE DISPLAY-LIST RAM HAS A RESET PATTERN, AND WE CAME UP WITH
UNWRITTEN MEMORY INSTEAD.** The user, on `build/fix3d10`: the cars are
right and no longer flash (R246 confirmed on hardware), but "the scenery
vanishes, not always there" and there are "scenes where all models are
black, as if there is no light". The lighting half is measured, not
guessed. `R245`'s probe, over 3,038,460 polygons of a 150 M-instruction
run:

    LIGHT PARAMETERS: polygons 3,038,460, of which 4,096 read an entry of
    {diffuse 0, ambient 0} -- black
    walker wrote / polygons asked, per entry: 0:30/302690 2:29/1139268
    3:29/362694 5:29/567596 7:28/548330 ...
    TEXTURE PARAMETERS (index: diffuse/ambient): 0:255/255 1:255/255
    2:255/255 3:255/255 4:255/255 5:255/255 6:52/0 7:54/0 8:57/0 9:59/0
    10:255/255 ... 15:255/255
    LUMINANCE over 3,038,460 polygons, zero on 155,431 (5.1%); the top bin
    holds 2,165,799 -- 71%

So the light table is not starved: every entry a polygon asks for was
written about thirty times. It is written with the WRONG THING. Entries
6-9 hold plausible values (52/0, 54/0, 57/0, 59/0); the rest hold exactly
255/255, which is `luminance = |dot| * 255 + 255` clamped to 255 -- white,
always, and 71% of all polygons land in the top luminance bin.

255 and 255 are the two bytes of 0xFFFF, which is what unwritten SDRAM
reads on this board. `model2.cpp`'s reset says where they should have come
from:

    // initialize bufferram to a sane default
    // TODO: HW can probably parse this at will somehow ...
    for (int i = 0; i < 0x20000/4; i++)
        m_bufferram[i] = 0x07800f0f;

All 128 KB of the display-list RAM. A texture-parameter command whose
count runs past what the game actually wrote therefore reads diffuse 0x0f
and ambient 0x0f in the reference -- dim, and the same every time -- and
255/255 here. The same pattern is also opcode 0x0f, END, so an unwalked
region stops the walk in the reference rather than being interpreted.

Model2.sv now sweeps word 0x16f0000 for 65,536 words at boot with
0x0F0F/0x0780 by word parity, in three new states beside R223's texture-RAM
sweep (`st_state` widened to five bits; `cal_done` is unchanged at >= 12,
so nothing waits longer). `tb_m2_boot` fills the same region the same way
before the run, because the bench had no boot sweep and would otherwise
keep measuring 0xFFFF. Verified by re-running the R245 probe.

Not established: whether this also explains the black scenes. It cannot be
the 4,096 polygons that read {0,0} -- that is 0.13% -- so the black scenes
are still open, and the scenery that vanishes is open too.

*R247 CORRECTED, SAME MORNING.* The display-list RAM was ALREADY filled with
0x07800F0F at boot: `bi_*` in Model2.sv writes all 65,536 words with
`bi_idx[0] ? 16'h0780 : 16'h0f0f` once `rom_loaded && cal_done`, and it holds
arbiter port 0. So the 255/255 light table R245 measured was a BENCH artefact
-- `tb_m2_boot` had no such fill and served 0xFFFF -- and the board never had
it. The bench fill stays (it makes the desk match the board); the duplicate
sweep added to Model2.sv is removed. One board capture of `build/fix3d11`
read the sweep's control region as 455519 against the expected 25E723, which
looked like memory corruption; a second capture of the same bitstream read
25E723 and so did `build/fix3d10`. Not reproducible, recorded, not explained.

**R248 -- THE TEXTURE-RAM CLEAR HAS NEVER RUN ON HARDWARE, AND THAT CULLS
EVERY OBJECT WHOSE TEXTURE HEADER LIVES IN TEXTURE RAM.** Found while
chasing the above. `st_run` gates the boot writer's request into the write
arbiter:

    assign st_run = rom_loaded && (st_state >= 4'd1) && (st_state <= 4'd8);

States 1 to 8 are the read-latency calibration's own writes. R223's
texture-RAM zero sweep runs in states 12 to 15. `m2_wr_arb` acknowledges
only a port it has picked and picks only a port that is requesting, so
`wr_ack_st` never arrived, state 13 waited for it forever, and not one of
the 65,536 words was written. Nothing noticed: `cal_done` is `st_state >=
4'd12`, which state 13 satisfies, so every consumer was released on time.
The study recorded the sweep as deployed. It was built, not run.

What it costs the picture. Daytona never writes texture RAM (R222), so the
reference reads ZEROS for a header held there; we read unwritten SDRAM,
which is 0xFFFF. Bit 13 of header word 0 is the translucent flag, and the
engine culls a translucent polygon because the reference draws nothing for
one (R231) -- so on the board EVERY polygon of EVERY object with a
RAM-resident header is discarded. The bench counts those objects:
`RAM-resident 7908` of `114986`, 6.9%. They are missing from the board's
picture and present in the reference's, which is what "the scenery
vanishes, and is not always there" looks like. The desk could not see it:
`tb_m2_boot` zeroes the texture-RAM region in its own memory image (R222),
so the bench has been rendering those objects all along.

Fixed by extending the gate to the sweep's states:

    assign st_run = rom_loaded && (st_state >= 4'd1)
                               && ((st_state <= 4'd8) || (st_state >= 4'd12));

`lint_top` clean; there is no desk test for this, because the boot machine
lives in Model2.sv and `tb_m2_boot` drives `m2_boot_harness` instead. The
measure is the board: objects that were absent should appear.

**R250 -- THE DEPTH MIN AND MAX COMPARED FLOATS AS UNSIGNED INTEGERS, SO ONE
CORNER BEHIND THE EYE CULLED THE WHOLE POLYGON.** From the board, by eye:
"it seems the behind-eye culling is happening too early on the scenery --
the floor disappears before it's off screen." Correct, and R246 introduced
it. `m2_geometry` reduced the four vertex depths with

    function automatic logic [31:0] fmin(a, b);  fmin = (a < b) ? a : b;
    function automatic logic [31:0] fmax(a, b);  fmax = (a > b) ? a : b;

and the comment beside them said the depths "are positive for anything in
front of the eye, and IEEE-754 orders positive floats exactly as the
unsigned integers of their bit patterns do". Both statements are true. The
conclusion does not follow: a vertex BEHIND the eye is negative, its sign
bit is set, and as an unsigned integer it is larger than every positive
float. So the moment one corner of a polygon crossed behind the camera it
became the MAXIMUM, `max_z` read negative, and R246's `max_z < 0` cull --
which is the reference's, and correct -- discarded a polygon that was still
mostly on screen. The floor is the worst case because it is the surface the
camera is closest to.

Both functions now compare through the standard monotone key, `f[31] ? ~f :
(f | 0x80000000)`, which is the same transform the quad store used to apply
to its sort key before R246 moved the key upstream. It also corrects the
sort depth itself for any polygon with a vertex behind the eye, which was
reading 0xffff -- the furthest bucket -- when it should read the negative
minimum.

`tb_m2_geometry` gains the case that was missing: a quad at z = {-2, 3, 4,
5}, whose maximum is 5, must NOT be culled, must reach the clipper, and must
sort on -2. With the unsigned comparison restored all three fail (42 checks,
3 fails), so the bench now sees it. The desk never had it because every
directed quad in that file sat wholly in front of the eye.

**R251/R252 -- THE LIGHT TABLE GOES ON THE WIRE, AND THE MEAN IS A ROLLING
AVERAGE BECAUSE A DIVIDE COSTS THIRTY-ONE NANOSECONDS.** R249 put the
frame's mean luminance and its black-polygon share on the UART, and
`build/fix3d13` answered the question the user had asked three times:
there are frames on the board where the black share reads 100 -- every
polygon at luminance zero. That is the "all models black, as if there is
no light" scene, measured at last. Luminance is |dot(normal,light)| *
diffuse + ambient, so all-zero means the entry those polygons ask for
holds diffuse 0 AND ambient 0, and an entry the display list never wrote
reads exactly that: the engine's 32-entry MLAB comes up zero and has no
reset. R251 streams the table itself as 'T' records -- a bit per entry the
walker has written, the raw diffuse and ambient of one entry per frame
rotating through all 32, and the walker's count of geo op 0x06 -- so the
board can say whether the entries in use were ever written.

R249's arithmetic was wrong in a way that cost a build. It summed the
luminance and divided by the polygon count at frame_start: two variable
divides, 22 bits by 14, combinational into a register. Quartus built them
faithfully -- +876 ALM, and EVERY seed of `build/fix3d13` missed setup on
the i960's clock by 31 to 33 ns against a 40 ns period. The comment beside
it read "this is one divider, off the critical path, and it only has to be
right once a frame"; a divide that feeds a flop IS the path, and "once a
frame" describes when the result is USED, not when the logic is evaluated.
Replaced by a single-pole IIR, `acc <= acc - (acc >> 6) + sample`, which
settles at 64 times the mean of the last ~64 polygons so the mean is
`acc[13:6]`: one subtract, one shift, one add. The black share is the same
filter fed 255 for a zero-luminance polygon.

And the deploy chain pushed that unusable bitstream to the board. Its
fallback -- "if the picked seed has no .rbf, take any other seed that has
one" -- ignored the seed rule that had just rejected all three. The board
came up not running, and the user said so before any capture could. The
fallback now only considers seeds the rule accepted.

**R254-R257 -- THREE BENCH FAULTS IN A ROW, AND THE ONE QUESTION THAT ONLY
THE BOARD CAN ANSWER.** The user's remaining faults were the scenery
vanishing and whole scenes rendering black. Both have the same shape: the
walker decoding commands the game never wrote. The desk said it decodes 417
nops a frame against the reference's NONE, and eighteen dumps of the
reference's own display list contain no texture_parameters command at all
while our walker executes 39 of them. Chasing that found the mechanism and
then found that the desk could not be trusted about any of it.

*The mechanism (R254), which is real and worth keeping.* Daytona does not
write a count into its list. It pushes a ZERO PLACEHOLDER, reads the push
port's write pointer at 0x802008 to remember where the placeholder went,
pushes the payload, reads the pointer again and patches the count in with a
STORE into buffer RAM:

    00019F04: ld   0x2008(g10),r10    ; where the placeholder will go
    00019F0C: st   r3,(g10)[g12]      ; push 0
      ...                              ; push the payload
    00019F8C: ld   0x2008(g10),r3     ; where we ended up
    00019F94: subo r10,r3,r3
    00019F98: shro 2,r3,r3
    00019F9C: subo 1,r3,r3
    00019FA0: st   r3,0x900000(r10)   ; patch the count

So the count arrives by a different road from every other word of the list,
and a walk that reads it as zero steps into the payload and decodes 280
words of vertex data as commands. That is where the light table's 0/0 and
255/255 entries come from -- the black scenes and the blown-out ones -- and
objects are skipped, which is the scenery that vanishes.

*Three bench faults, none of them in the core.* (1) `m2_boot_harness`'s
`cpu_io_rdata` had no case for 0x802008 or 0x803008 and returned zero, so
the game computed -1 and patched it to offset 0. Model2.sv answers both
correctly. (2) The harness gave the CPU bridge `base_buffer = 0x16d0000`
and the geometrizer `0x16f0000`, so every STORE the game made into its
display list -- the count among them -- landed 128 KB from where the walker
reads. Model2.sv passes GAME_BUFFER to both. (3) The walker trace was
capped at 6,000 lines from the first walk, which is entirely inside the
boot, so it reported that the walk ends immediately. Every desk conclusion
about the display list before this was measured on a list the bench had
malformed, which is the honest reason the desk and the board have disagreed
all day. The user said it plainly: check on the device.

*R256, the one candidate that is in the core.* `screen_vblank` in
model2.cpp walks the list only on even frames when the game is in 30 Hz
mode -- "if 60 Hz mode or frame number is even" -- and this core has always
walked every vblank. If Daytona sets that bit, every other walk reads a
half-built list. That is a one-line gate, but the desk cannot test it now,
so it goes to the board behind `O[26],Walk rate,Every frame,Reference` and
the board decides. Beside it, R255 streams what the walk actually did --
nops decoded, commands, objects, unknown opcode, push drops -- as 'U'
records, because the reference's list contains no nops at all and any run of
them is the walk reading data as commands.

**R258 -- THE BOARD ANSWERED: THE WALK IS SOUND AND THE PUSH QUEUE DROPS.**
R255's 'U' records, first capture (`build/fix3d15`):

    WALK: per frame -- nops decoded med 0 max 4 | commands med 67 |
          unknown op 00 | push drops 252

So the walk does NOT lose sync on hardware: no nop runs, no unknown opcode,
67 commands a frame against the reference's 57-91. Every desk symptom that
pointed that way was the bench's own malformed list (R254-R257). What the
board does report is 252 DROPS from the queue between the i960 and SDRAM,
and in the same capture a light table with NINETEEN of its thirty-two
entries reading 0/0 -- up from twelve. Every polygon indexing one of those
renders black, which is the user's "whole scenes where everything is black".

A drop is not a lost word, it is a HOLE. `m2_geo` deliberately does not
advance the write pointer on a drop -- "a drop must not advance it, or the
list gains a hole AND a wrong pointer" -- so the next dword takes the
missing one's slot and every word after it shifts by one. A shifted list
still walks (the opcodes are still opcodes) but its operands belong to the
command before, which is exactly how a texture_parameters command comes to
write real-looking values at scattered indices and zeros everywhere else.

The reference has no queue and cannot drop: `push_geo_data` writes bufferram
and returns. Real hardware holds the CPU off instead. The bridge already has
that path -- `io_stall` holds an I/O access with `io_sel` asserted, which is
how the coprocessor stalls the i960 -- so `m2_geo` now raises `push_stall`
while a push meets a full queue, and Model2.sv ORs it into `cpu_io_stall`.
No combinational loop: the bridge's `io_sel` is registered and the stall is
sampled in S_IOW. The measure is the board's own drop count, which must read
zero, and the light table, which must stop holding 0/0.

*R256 CONFIRMED ON THE BOARD, R258 WITHDRAWN, R259 (19:20).* The user set
`O[26]` to Reference and reported it at once: "I have changed it to
reference and it's great, only 1 or 2 scenery drop outs every 5 or so
seconds", and later "odd occasion missing floor, but not many". So walking
the display list on ALTERNATE frames in 30 Hz mode, as model2.cpp's
screen_vblank does, is what the scenery needed -- this core had walked every
vblank since the walker was written, and every other walk was reading a list
the game was still building. It is now the DEFAULT and the switch selects
the old behaviour.

R258's backpressure is WITHDRAWN. Holding the CPU when the push queue is
full is the right idea and the implementation was wrong: the bridge
re-asserts `io_sel` every cycle while `io_stall` is held, so `wr_push` is a
LEVEL for the whole stall and the same dword was pushed again on every cycle
after the queue made room. The board showed it -- drops unchanged and the
walk's nop count up from 4 to 280, a list with duplicated words in it -- and
`test_m2_geo` failed two checks at the desk. A correct version needs a
one-shot per access; it is not needed for the scenery any more, and the
drop counter stays on the wire as a measurement. What the episode is worth
recording for is the shape of the mistake: an output that is a pulse under
one handshake becomes a level under another, and `io_stall` changes the
handshake.

**R259 -- HALF BRIGHTNESS IS THE DEFAULT.** The textured placeholder's
brightness was an OSD option (R239) defaulting to full. The user, judging on
the board: make it 50%. An OSD bit reads zero until it is moved, so the menu
is reordered to 50/75/100/25 and `scale_lum`'s cases reordered to match --
selector 0 is now half. `tb_m2_geo_engine`'s expectation scales with the
selector instead of assuming full (41 checks).

**R260 -- THE REFERENCE'S LIGHT TABLE HAS NO ZERO IN IT, AND THE PUSH QUEUE
IS WHY OURS DOES.** The reference's texture_parameters command is rare --
about one frame in four hundred -- so twenty-two sampled dumps of its
display list contained none, and sampling was the wrong instrument. Walking
the list IN LUA on every frame catches it (`tools`-side script in the
scratchpad, frames 63 and 64 of the attract):

    TP index 0 count 32: 0:127/63 1:127/47 2:127/111 3:255/255 4:127/127
                         5:79/95 6:127/127 7:127/47 8..31: 255/255

One command writes the WHOLE table, 64 payload words, and not one entry is
zero -- 255/255 is simply what the unused upper half holds. The board's copy
of the same table had NINETEEN of thirty-two entries at 0/0, and a polygon
indexing one of those renders black however well lit the scene should be.
That is the user's "whole scenes where everything is black", and it is a
corrupted payload, not a lighting model.

The corruption is the push queue. It drops when full, and a drop is a HOLE:
`geo_wp` deliberately does not advance on a drop, so the next dword takes
the missing one's slot and every word after it shifts by one. In a 64-word
payload that turns real values into whatever the neighbouring words hold.
The board's drop counter climbs continuously.

So the queue now holds the CPU off instead, which is what the reference's
absence of a queue amounts to and what `io_stall` already does for the
coprocessor. The implementation detail that cost a board build: `wr_push` is
a one-cycle pulse under the bridge's ordinary handshake and a LEVEL while
`io_stall` is held, so a naive stall pushes the same dword every cycle after
the queue makes room -- the board reported that as the walk's nop count
going from 4 to 280. The push is now one-shot per access, with a new access
marked by the strobe rising OR the dword changing, because a pusher may hold
the strobe across two words and `tb_m2_geo` models one that does.

`tb_m2_geo` asserted the OLD contract -- "the i960 is never held: overrun
drops and counts" -- and now asserts the new one: 4,000 pushes into a
128-deep queue, none dropped, the pusher held, and the write pointer exactly
4,000 dwords on, so the list has no hole (76 checks).

**R261 -- THE BRIGHTNESS CONTROL DID NOT REACH THE PLACEHOLDER, WHICH IS
MOST OF WHAT IT WAS BEING JUDGED ON.** The user, on `build/fix3d18`: "menu
says 50% but it's still 100 as it was before, so you can only go much
brighter or down to 25% which looks like 50%". The menu and `scale_lum` are
consistent -- both were reordered by R259 and the reordering is in the build
-- so the control does what its label says. It simply did not apply to
enough of the picture. Three paths, and only one of them scaled:

  * flat (untextured) polygons: never scaled, and should not be -- that is
    the reference's own colour path, not a preference;
  * textured with a palette colour: scaled by the selector;
  * textured with a BLACK palette entry, drawn as the grey placeholder
    (R234): pinned at half, whatever the selector said.

The placeholders are most of what is on screen -- the board's own census
puts textured at 58,537 objects against 39,766 flat -- so moving the control
changed little and the default "50%" looked like the 100% before it. The
placeholder now takes `scale_lum` like any other textured polygon.
`tb_m2_geo_engine` gains the check that says so: the same polygon at
selector 2 must come back at FULL luminance, which fails with the old pinned
half (42 checks).

**R262 -- THE QUAD STORE'S VERTEX MEMORY WAS 43% FULL, AND TEXTURE NEEDS THE
BLOCKS.** M10K is 553 of 553 and texture mapping has not started. The
fitter's RAM summary prices every array, and the quad store is the worst
offender by efficiency: eight arrays of 2,048 x 26 bits holding 426 K bits
inside 900 K of block memory, 88 blocks. 26 is the reason -- an M10K's
native widths are 8, 16, 20 and 40, so a 26-bit word takes a 20-bit slice
plus an 8-bit slice and wastes the rest of both.

The four vertices of a quad were never independent memories: they are
written in the same cycle and read in the same cycle. One array per bank of
4 x 26 = 104 bits is the same storage under one address, and 104 fills three
40-bit slices. Eight blocks per slice at 2,048 deep gives 24 blocks a bank,
48 against 88 -- about 40 blocks back, with no quad lost and no change to
NQ. It also turns the replay's four reads into one.

For the record, since it was measured today and is not a one-line change:
`m2_video`'s 32 tilemap line stores are 128 x 15 and would be four MLABs
each, 1,280 ALM for 32 blocks -- but Quartus DECLINES `ramstyle = "MLAB"` on
them and leaves them AUTO, as an earlier session recorded in that file. The
cheap MLAB tier that Quartus does accept is about 46 blocks for ~2,000 ALM
(four 16 x 16 sound arrays, the 96 x 8 translation stage, 128 x 32 in the
i960 and coprocessor, 512 x 8 in the loader, 128 x 48 in the geometrizer).
The character cache is the biggest single consumer at 128 blocks and would
need 2,048 MLABs -- half the chip -- so it shrinks or it stays.

Texture data itself does NOT need blocks: it is already in SDRAM at word
0x720000 and the engine already reads texture headers from there, exactly as
the reference reads its texture ROM. What needs on-chip memory is a cache to
turn per-pixel reads into bursts, which is a handful of blocks.

**R263 -- WHICH TRIGGER STARTS EACH WALK, BECAUSE A MINORITY OF THEM STILL
READ A HALF-BUILT LIST.** `build/fix3d19` cleared the push-queue drops to
ZERO (R260 confirmed) and the light table improved -- most entries now read
255/255, which is what the reference holds in its unused slots -- but nine
still read 0/0 and the reference NEVER writes a zero. Measured against it:
over 3,200 frames the reference issues the texture_parameters command TWICE,
both at boot, writing 64 entries with no zero among them; this core issues
sixteen in four minutes and its table keeps changing. So a walk is still
decoding commands the game never wrote, and the board says how often: nops
per frame are median 0 and maximum 280, which is exactly the length of the
texture_data payload whose count the game patches in afterwards (R254).

One bad walk is permanent damage, because the reference's table is written
at boot and never again -- so a single phantom 0x06 corrupts the lighting
for the rest of the session. That is the black scenes.

Mode 0, the default, walks on the game's own "list is ready" write to
0x803008, with a FALLBACK that walks at vblank when no such write has been
seen for four frames. A fallback walk carries no promise that the list is
finished. `m2_geo` now counts both and Model2.sv streams them in the 'U'
record where the always-zero unknown-opcode byte and the walk-object count
were. If the bad walks are fallback walks the board will say so in one
capture; if they are not, the remaining suspect is ordering -- the CPU's
patch store and the walker's read reach memory through different ports with
nothing sequencing them.
