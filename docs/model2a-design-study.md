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

The strongest anchor is now our own: **`i960_top` = 6,979 ALM**, an entire CPU with FPU,
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
| i960KB + FPU | 6,979 | 9,500 | **6,979 measured** | assembled and fitted here. Optimistic = as built; pessimistic adds faults, interrupts, transcendentals and the `rl` forms |
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
| `i960_top` | **6,979** | 4,212 | 1 | 2,048 | 7 | 26.84 | **ours** |
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
figures** (i960 6,979 + `sys/` 6,630 + SCSP 2,030) plus bracketing proxies for
everything else.

| | ALM | whose RTL | what it proves |
|---|---|---|---|
| i960KB + FPU | **6,979** | **ours** | the CPU as built: integer, FPU, I-cache, register file, 7 DSP, 26.84 MHz |
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

7,079 of the 9,000-14,000 exists and is fitted. (`i960_top` alone measures **6,979
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
