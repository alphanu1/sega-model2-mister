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
| optimistic | 3,000 | 8,500 | 5,000 | **16,500** |
| pessimistic | 5,000 | 12,800 | 5,000 | **22,800** |

Which leaves, for the i960KB and the 3D renderer together:

| Rest of core lands at | CPU + GPU may use |
|---|---|
| optimistic, 16,500 | **25,009 ALM** |
| pessimistic, 22,800 | **18,709 ALM** |

Against a current estimate for those two of **22,000 to 38,500**.

So the optimistic case clears by ~3,000 ALM and the pessimistic case misses by
~13,500, and **every one of those four numbers is an estimate with no RTL behind
it.** That is the entire uncertainty of the project, concentrated in two blocks.

**Therefore: build the i960 and the renderer first.** They are 57% of the
optimistic budget, they are the only two blocks with no licence-compatible RTL
anywhere (§5.4.3, §2.1), and they carry the widest error bars. Nothing else
resolves the fit question, and anything else built first is work that a bad
answer here throws away.

The corollary is uncomfortable and worth stating plainly: **the cheapest
outcome of this plan is an early, well-evidenced no.** P0 and P1 are structured
so that a project that cannot fit says so before most of the effort is spent.

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

**Exit:** *Pass* < 12K ALM and > 90 MHz. *Fail* > 18K ALM — and §9's close
condition applies.

**Known unverifiable:** MAME declares `double m_fp[4]`, modelling the four
80-bit extended-precision registers as host doubles (§2.2). FP results cannot be
lockstep-verified. Decide explicitly and record it: verify against a software
80-bit reference, or accept 64-bit and document the deviation. Do not let this
decision be made by default.

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
monitor, video timing (retimed to 496x384).

---

## P6 — Integration

Top level, MiSTer framework, MRA, hardware bring-up. Every trap in
`mister-integration.md` applies, and the debug overlay (`m1_diag`, 307 ALM,
measured) should be ported and running **before** the first board test, not
after the fifth failed one.

---

## Standing rules for every milestone

- **Fuzz and simulate before the fitter.** A Quartus build is the most expensive
  way to find an error.
- **Simulate what hardware does**, not what is convenient: stream ROMs through
  the real loader, make unwritten memory read `0xFFFF`, use the board's real
  clock frequencies, and make a stall detector `$fatal`.
- **Only a Quartus build can tell you where memory landed.** Simulation has no
  opinion about M10K inference.
- **Record what was wrong, not just what is right.** The design study has been
  wrong in both directions twice over and is more useful for it.
