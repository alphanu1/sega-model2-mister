# Milestones

Ordered to answer one question as early and as cheaply as possible:

> **Does a Model 2A core fit on a 5CSEBA6U23I7?**

Everything here is sequenced by how much that question is worth, not by what is
pleasant to build. `model2a-design-study.md` is the analysis; this is the order
of work.

---

## The question, reduced to one number

The device has **41,509 ALM**. From design study §5.5, the blocks that are *not*
the CPU or the renderer come to:

| | TGP | sound + 2D | `sys/` | total |
|---|---|---|---|---|
| optimistic | 3,000 | 7,530 | **6,630** | **17,160** |
| pessimistic | 5,000 | 9,830 | **6,630** | **21,460** |

Which leaves, for the i960KB and the 3D renderer together:

| Rest of core lands at | CPU + GPU may use (of 38,188 at 92%) |
|---|---|
| optimistic, 17,160 | **21,028 ALM** |
| pessimistic, 21,460 | **16,728 ALM** |

Against a current figure for those two of **17,000 to 28,000**, of which
**7,079 is measured** — the i960 as assembled and fitted.

So the optimistic case clears by ~4,000 ALM and the pessimistic case misses by
~11,300. **That is still the entire uncertainty of the project, but it is no
longer four numbers with no RTL behind them.** `sys/` (6,630) and the SCSP
(2,030, same chip) are measured, and the i960 row is now mostly built. The
renderer is the one row with nothing of ours in it, and it is bracketed rather
than anchored: the N64 RDP's 8,347 above, Saturn's VDP1 below.

> **R15/R16 note.** The throughput figures below were withdrawn by R15 and replaced
> by R16, measured from verified-uncollapsed traces: **71-73% of Daytona's
> instruction stream is two poll loops**, demand is **30,949 instructions of work per
> frame**, and the core runs that in **33.4% of a frame — about 3.0x headroom**. The
> pipeline remains unnecessary for Model 2, now on measured grounds rather than a
> claimed 0.1% spin fraction. The **area** case was never affected.

**Therefore: build the i960 and the renderer first.** They are 57% of the
optimistic budget, they are the only two blocks with no licence-compatible RTL
anywhere (§5.4.3, §2.1), and they carry the widest error bars. Nothing else
resolves the fit question, and anything else built first is work that a bad
answer here throws away.

The corollary is uncomfortable and worth stating plainly: **the cheapest
outcome of this plan is an early, well-evidenced no.** P0 and P1 are structured
so that a project that cannot fit says so before most of the effort is spent.

---

### The order changed once, deliberately: P1.5 was inserted

**Decision: a 2D proof-of-concept on real hardware runs before the renderer.**
This departs from everything above, so the reasoning is recorded rather than
implied.

*Why it is defensible now and would not have been before.* The paragraph above
exists to avoid spending effort on a core that cannot fit. Six blocks have since
been fitted on the target part (study §5.5): the budget moved from 34,160-49,460
to **24,454-40,293**, with **20,117 ALM measured**, and the optimistic case now
clears the 92% routing line by 14.1K. The risk that this ordering was built to
manage — pouring work into a project that says no at the end — has dropped a long
way. It has not vanished: the pessimistic case is still 1.7K over, and the
renderer is still the row with none of our RTL in it.

*What it buys.* Every trap in `mister-integration.md` is a **bring-up** trap, and
they are found by putting a build on a board, not by simulating. Finding them
with eight blocks in the design is far cheaper than finding them with thirty. It
also produces the debug overlay, without which nothing after it is debuggable on
hardware — and it produces something a person can look at, which no amount of
passing lockstep does.

*What it costs, stated plainly.* **P1.5 does not advance the fit question at
all.** Every block in it is either measured already or small. If the answer to
the fit question is eventually no, P1.5 is work thrown away — which is exactly
what the paragraph above warns against. That is accepted knowingly, on the
grounds that the odds of that no are materially lower than when this document
was written.

---

## P0 — Measure without building. **Do first.**

No FPGA design work. Days, not weeks, and it moves three estimates toward
measurements.

| | Task | Pass | Fail |
|---|---|---|---|
| **M2-E** | Compile `N64_MiSTer` (GPL-3.0, VHDL) for this exact part with Quartus 17.0. Extract per-module fitter figures for the RDP and the R4300i, **and achieved Fmax at the core's real utilization**. | RDP < 12K, R4300i < 12K | both at top of range |
| **M2-B** | Count i960 FP instructions per frame across the target set, by opcode class — basic arithmetic vs transcendental. Instrument MAME. | low enough that a microcoded FPU costs no frame time | FP-bound |
| **M2-A** | Instrument `model2_v.cpp` to log every texel address. Replay through a software cache model: 16/32/64 KB, 2/4/8-way, 32/64/128-byte lines, with and without Morton swizzling. Worst cases Daytona at speed, Sega Rally scenery. | > 85% at 32 KB | < 70% at 64 KB |
| **M2-G** | Email srg320 asking for an explicit licence grant on the Saturn SCSP RTL. | any GPL-3-compatible grant | no reply — write it from scratch |
| **M2-H** | **Build an M10K budget.** Design study §5.6 — there isn't one, and Model 1 reports M10K binding at 409/553 on this same part with a simpler renderer. Collect Model 1's per-consumer breakdown and isolate the MiSTer `sys/` framework's own usage. | a budget that closes under 553 with margin | it does not close — retune §6.2 tile size and §6.4 cache size before any RTL |

M2-H is new and it is not optional. This project has an ALM budget accurate to 1,000 ALM
and **no M10K budget at all**, while the only comparable project on the same device found
M10K to be the binding resource — and Model 2 adds ~78 blocks of tile buffer and texture
cache that Model 1 never needed. An ALM answer to the fit question is not an answer if the
design runs out of memory blocks first. It is a spreadsheet and a day, and it feeds
directly into M2-A: the cache-size sweep stops being confirmatory and starts being a
design decision.

M2-E is the highest-value hour in the whole plan. One compile produces
measured, same-part, same-toolchain proxies for **both** P1 and P2 before either
is started, and the only empirical figure anywhere for Fmax degradation at real
utilization on this device. Read the RDP source while the fitter runs — per
§5.4.2 it is GPL-3.0, so it is an architectural reference and not merely
readable.

M2-G is here purely because the answer takes as long as it takes. Send it on
day one; it is not on the critical path but a late "yes" is worth less than an
early one.

---

## P1 — i960KB

**Specification and running status: `p1-i960-spike.md`.** Scope, register model,
opcode space, timing, memory map, deliverables and exit criteria, taken from the
reference rather than from secondary sources.

**Status, 2026-08-17.** Steps 1-6 of 8 are done, with the FPU integrated and
whole-CPU lockstepped. All 15 suites pass at 147,060 checks and zero divergence.

| | |
|---|---|
| assembled CPU | **7,015 ALM, 7 DSP, 27.72 MHz** |
| throughput, Daytona mix with loops | **3.91 CPI = 6.86 M instr/s** |
| **Daytona's measured demand** | **0.93 M instr/s — met with 7.4x margin (R10)** |

**The bottleneck moved, and it is no longer the pipeline.** `T_DECODE` was
removed — the decoder reads the arriving word, so fetch goes straight to
execute — which put the front end at 2 CPI. Instruction fetch then became 80%
of a simple instruction at **4.28 cyc/instr**, against the **1.17** that a
12.5 M instr/s target allows.

So the remaining P1 work is **instruction fetch**, not sequencing:

- 60.8% prefetch hit rate; 6,948 fill-wait cycles. A 16-byte line is four
  instructions, so sequential code cannot miss less than 25%. Longer lines or a
  next-line prefetch attack this.
- 4,626 cycles waiting out a *discarded* prefetch's fill. Self-inflicted.
  A fill-abort was attempted and reverted — see `HANDOFF.md` for the failure
  signature and the three hypotheses already eliminated.

**The 90 MHz in step 7's exit criterion is a proxy and it is ~3.3x stricter than
the throughput requirement it stands for.** Judge on throughput. Area has never
been the constraint: 7,015 against a 12K pass band.

Still absent: faults entirely, the `rl` double-precision forms, `remr`, the six
glibc transcendentals, `synmov`/`synmovq`, `calls`, `modpc` and interrupts.

The main CPU. **No open-source i960 exists in any HDL** (§5.4.3) — this is
from scratch, and it is the larger of the two remaining unknowns to actually be
buildable.

Pipelined from the start. §4.3 is not negotiable: a multi-cycle FSM needs
123-164 MHz and does not close. Target 2 CPI, accept 4.

Order:

1. Integer core — pipeline, register windows, scoreboard, I-cache control,
   32-bit multiplexed burst bus.
2. **Lockstep against MAME `i960.cpp`** (BSD-3-Clause). Integer is bit-exact, so
   this is a real oracle, unlike anything in P2.
3. FPU, scoped by M2-B. Microcoded shared datapath with coefficient ROMs in M10K
   if FP is cold; a wider unit if it is hot. The full transcendental set is
   implemented in MAME and therefore used (§3) — it cannot be dropped.
4. **M2-D** — standalone Quartus spike, 5CSEBA6U23I7, pipelined.

**On what "pipelined" has to achieve here**, because §4.3's headline figure is
easy to misread. The 123-164 MHz there is what a *9.83-CPI FSM* would need. The
requirement is throughput, not clock: 12.5-16.7 M instr/s. At the measured
45 MHz a 3-CPI design delivers 15 M and a 2-CPI design 22.5 M. **The pipeline
needs low CPI more than it needs a high clock**, and it can afford to lose some
Fmax to hazard logic if it buys enough CPI.

**Exit:** *Pass* < 12K ALM and > 90 MHz. *Fail* > 18K ALM — and §9's close
condition applies.

**Known unverifiable:** MAME declares `double m_fp[4]`, modelling the four
80-bit extended-precision registers as host doubles (§2.2). FP results cannot be
lockstep-verified. Decide explicitly and record it: verify against a software
80-bit reference, or accept 64-bit and document the deviation. Do not let this
decision be made by default.

---

## P1.5 — 2D on hardware. The POC slice.

**Goal: an `.rbf` that boots on a DE10-Nano and puts a verified Model 2 tilemap
frame on a screen.** No CPU, no 3D, no sound.

This is a slice of P5 and P6 pulled forward, not new work — see the decision
above. P5 and P6 keep everything not listed here.

**It is cheap because the blocks exist.** `tools/model1-ref` has all of them, and
S24TILE is *the same chip* Model 2 uses. Everything lifted is copied into `rtl/`
with its source commit pinned in `THIRD_PARTY.md`; nothing is referenced in place
and nothing under `tools/` is edited.

**The video timing transfers unchanged, which was not expected.** P5 said
"retimed to 496x384". It needs no retiming: MAME declares Model 1 as
`set_raw(XTAL(16'000'000), 656, 0, 496, 424, 0, 384)` and Model 2 as
`set_raw(32_MHz_XTAL/2, 656, 0, 496, 424, 0, 384)` — the same pixel clock and the
same counts. `m1_video_timing.sv` is already correct for Model 2.

| | Step | Lift from | The trap, already paid for |
|---|---|---|---|
| 1 | Top level, PLL, video timing to a test pattern | `m1_video_timing` (unchanged) | **Name the PLL `pll` and generate it from the IP tool**, or `sys_top.sdc`'s clock groups match nothing and a passing build fails on hardware |

**Step 1 status: the RTL is done and verified; the framework is not.**

- `rtl/video/m2_video_timing.sv` — copied at `f48c842`, **51 ALM**, verified against
  MAME's `set_raw` by `sim/video/tb_m2_video_timing.cpp` (278,144 pixel clocks per
  frame, 424 lines, 496x384 visible, 57.52 Hz).
- `rtl/video/m2_testpattern.sv` — ours, **83 ALM**. Border, eight bars, corner
  markers, and a block that marches one bar per second for liveness.

**The PLL does NOT transfer, and this was checked rather than assumed.** Model 1's
has two outputs, 80 MHz and **19.2 MHz** — and 19.2 is its V60 core clock, which
Model 2 does not have. It must be regenerated.

**Model 2's frequencies are unusually clean, which helps.** MAME declares the
pixel clock as `32_MHz_XTAL/2`, so **16 MHz is exactly 32 MHz halved** — a 32 MHz
PLL output with a divide-by-two clock enable is exact, with no fractional
division and no drift. Proposed outputs:

| output | frequency | for |
|---|---|---|
| 0 | ~80 MHz | SDRAM |
| 1 | 32 MHz | video, `ce_pix` = /2 -> exactly 16 MHz |
| 2 | ~25 MHz | i960 (the real part's rate; ours fits at 26.84) |

`pll_0002.v` in the Model 1 tree is a direct parameterised instantiation of
`altera_pll`, not a Qsys black box, so the equivalent can be written by hand with
these frequencies rather than needing the GUI. **It must still be named `pll`.**

**Next actions, in order:** write the `pll` wrapper; copy MiSTer `sys/` from
`third_party/template`; write the core's `emu` module wiring timing + pattern to
`VGA_*`; add `.qsf`/`.qpf`/`files.qip`; build an `.rbf`. The first four are
desk work; only the last costs 25 minutes.
| 2 | ~~**Debug overlay**~~ **DONE** | `m1_diag` -> `rtl/video/m2_diag.sv` @ `b895e6c` | The screen is the only output channel. Hex digits, not blocks. This runs **before** the first board test, not after the fifth failure |
| 3 | ~~SDRAM and ROM loader~~ **DONE, PROVEN ON HARDWARE** | `m1_sdram`, `m1_rom_loader`, `m1_cdc_port`, `bw_monitor` | **One access is `req & ack`, not one cycle of `req`** — a side-effecting target must act on the handshake. The Model 1 TGP popped every FIFO word twice and deadlocked on hardware (`mister-integration.md`).<br> `ioctl_wait` stalls the HPS itself — always gate it on `ioctl_download`. Memory comes out of reset on PLL lock and stays out, separate from game reset. `mem_ready` and `rom_loaded` are different facts and must not share a signal |
| 4 | ~~S24TILE~~ **DONE, RENDERS CORRECTLY ON HARDWARE** | `m1_tile_fetch`, `m1_tile_decode`, `m1_tile_mixer`, `m1_palette` | Rebase char RAM to `0x01080000` |
| 5 | ~~**The oracle**~~ **DONE, MATCHED** | MAME | see below |

### Step 5 is what makes this a test rather than a hope

Model 2's tilemap contents are written **by the CPU**, and there is no CPU in this
slice. So there is nothing on screen unless it is supplied.

**Dump the tilemap RAM and the palette out of MAME at a known frame, load them
through the ROM loader as though they were ROM, render, and compare against
MAME's screenshot of that same frame.** That gives the 2D path a real oracle with
no CPU dependency — the same discipline the i960 got, applied to pixels instead of
registers. Without it this milestone proves only that the board draws *something*.

Pick the frame deliberately: one where the tilemap carries visible content.

**Exit criteria**

1. Builds under Quartus 17.0 and boots on a DE10-Nano; stable 496x384 video.
2. The overlay renders legible hex digits **on hardware**, photographed.
3. A canned state loads over `ioctl` without stalling the HPS.
4. The rendered frame matches MAME's screenshot for the same frame.

**Explicitly not in scope:** the i960 (it has no interrupts yet — study R14), the
renderer, sound, and any claim about the fit question.

---

## P2 — 3D renderer

The largest block, the widest error bar, and **the only block in the design with
no bit-exact oracle** (§2.1). Verified by framebuffer comparison, which localises
bugs poorly — plan the instrumentation accordingly.

Architecture is settled and is §6, which is the highest-confidence section of
the study: tile-based, not immediate-mode.

1. Morton swizzle at ROM load time — free at runtime, the MRA loader already
   touches every byte.
2. Binning to 128x64 screen tiles. **Ours, not Sega's** — no accuracy
   implication, a full frame of latency budget, and therefore the one block
   safely offloadable to the HPS if the fabric gets tight.
3. Per-tile rasterizer with on-chip colour and Z in M10K (64 KB
   double-buffered). Eliminates every Z read and write from external memory.
4. Texture cache, 32 KB M10K, 4-way, 64-byte lines — sized by M2-A.
5. Texture unit: bilinear, mipmapping. Push interpolators and the perspective
   divide into DSP blocks; 112 available.

**Exit:** area and Fmax spike on the real part, plus framebuffer comparison
against MAME on Daytona and Sega Rally.

**Note against the M2-E proxy:** the RDP does trilinear, a colour combiner and
coverage-based AA, all of which Model 2 needs less of. If P2 lands *above* the
RDP's measured figure, something is wrong with our design rather than with the
estimate.

---

## P3 — The fit verdict

With P1 and P2 measured, the number at the top of this document stops being an
estimate. Write the answer down either way, including a no.

A no is not a failed project — it is the design study's §9 close condition
reached honestly and early, at a fraction of the cost of discovering it during
integration. Publish the negative result with the measurements behind it.

---

## P4 — MB86234 TGP port

**Deliberately after the fit verdict.** Two reasons, and the second is the one
that sets the order:

- **The source is still moving.** The MB86233 is under active development in the
  Model 1 core. Its M0 spike is measured but not closed — there is no top level,
  so the program store and both RAM banks are absent from the 2,554 ALM figure;
  `fp_div` is verified but not yet instantiated in the ALU; and the assembled
  core reads 51.65 MHz against an 80 MHz gate. Forking a target that is changing
  under us buys a merge problem and an irreproducible measurement.
- **It is not the risk.** M2-C is closed (§5.4.1): `mb86234_device` is an empty
  subclass, so the port is free of design work and the estimate is anchored to a
  real measurement. At 3,000-5,000 ALM it cannot decide the fit question either
  way.

When Model 1's TGP settles: **pin a commit**, record it in `THIRD_PARTY.md`,
copy into `rtl/`, and never reference `tools/model1-ref` in place.

Then **M2-F**, which is the actual work: the measured FSM does 9.83 CPI at
72.17 MHz = 7.3 M instr/s against the ~16.7 M/s a 50 MHz MB86234 needs — a
**2.3x throughput gap**. Pipeline to <= 4 CPI. The per-opcode fuzz suites and the
whole-CPU lockstep harness port with the RTL and will catch a pipelining bug the
same day it is written.

---

## P5 — Sound and 2D

Cheap in risk except for one block.

| Block | Source | Note |
|---|---|---|
| 68000 | `ijor/fx68k`, GPL-3.0 | port; `enPhi1`/`enPhi2` clock enables, not a raw clock |
| S24TILE | Model 1 core, ours | same chip; rebase addresses (char RAM at `0x01080000`) |
| **SCSP** | **from scratch** | the only RTL is unlicensed (§5.3). Written against MAME's BSD-3 `scsp.cpp`, unless M2-G came back yes. |
| 315-5649, I8251, NVRAM, FIFOs | from scratch, small | MAME BSD-3 references |

Also ported from Model 1 here: SDRAM controller, ROM loader, CDC, bandwidth
monitor, video timing.

**Much of this row moved to P1.5** — S24TILE, the SDRAM controller, the ROM
loader, CDC and video timing are all pulled forward into the hardware POC. What
remains in P5 is the 68000, the SCSP, and the small I/O blocks. And the video
timing needs **no** retiming: Model 1 and Model 2 declare identical `set_raw`
parameters in MAME (see P1.5).

---

## P6 — Integration

Top level, MiSTer framework, MRA, hardware bring-up. Every trap in
`mister-integration.md` applies, and the debug overlay (`m1_diag`, 307 ALM,
measured) should be ported and running **before** the first board test, not
after the fifth failed one.

**The first bring-up moved to P1.5.** The framework, PLL, video timing, SDRAM,
ROM loader and overlay are brought up there against a 2D-only design. What
remains in P6 is integrating the CPU, TGP, renderer and sound into that shell,
plus the MRA — a much smaller and much better-understood job once a board has
already booted this framework.

---

## Standing rules for every milestone

**`docs/differential-testing.md` applies to every milestone from P1 onward.**
When behaviour diverges from MAME, diff against the oracle before theorising. The
Model 1 core reached a CPU bug it could not find by simulation and this is what
resolved it — three real defects in about two hours, two of them CPU bugs that had
survived its entire suite. Expect to need it here for the i960's interrupt bring-up
and for the TGP.


- **Fuzz and simulate before the fitter.** A Quartus build is the most expensive
  way to find an error.
- **Simulate what hardware does**, not what is convenient: stream ROMs through
  the real loader, make unwritten memory read `0xFFFF`, use the board's real
  clock frequencies, and make a stall detector `$fatal`.
- **Only a Quartus build can tell you where memory landed.** Simulation has no
  opinion about M10K inference.
- **Record what was wrong, not just what is right.** The design study has been
  wrong in both directions twice over and is more useful for it.
