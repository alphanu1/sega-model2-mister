# Handoff

**Updated:** 2026-08-16, after `8400052`.

---

## State

**P1 steps 1-5 of 8 are done**, and there is a first real area measurement.
`make all` (lint + yosys portability + fuzz) passes from a clean checkout after
`tools/bootstrap.sh`; `make quartus_all` reproduces the numbers below.

| Step | State |
|---|---|
| 1. Decoder and the four formats | **done** — 6.0e9 field checks, 0 mismatches |
| 2. Integer ALU, shifts, bit ops, condition codes | **done** — 4.3e9 field checks, 0 mismatches |
| 3. Register file, register cache, call/ret and spill | **done** — registers + memory write stream, mutation-tested |
| 4. Load/store, MEMA and the seven MEMB modes | **done** — AGU + load/store data path |
| 5. Bus and I-cache, burst | **done** — LSU, burst decoder, I-cache |
| 6. Whole-CPU lockstep | **done** — found the COBR defect on retire 0 |
| 7. M2-D Quartus spike + **pipeline** | **next** — the pipeline is the real work |
| 8. FPU | after the gate |

| File | What it is |
|---|---|
| `docs/model2a-design-study.md` | The analysis. Whether it fits, and why that is still open. |
| `docs/milestones.md` | The order of work, and the one number it is all sequenced to answer. |
| `docs/p1-i960-spike.md` | **The current milestone.** i960KB scope, register model, opcode space, timing, memory map, exit criteria. |
| `docs/mister-integration.md` | Framework traps already paid for on hardware. Read before wiring anything. |
| `THIRD_PARTY.md` | Every licence, and how it was checked. |
| `tools/bootstrap.sh` | Fetches and pins the five upstream dependencies. |
| `deps.lock` | The pins. Enforced on fetch, not merely written afterwards. |
| `.vscode/settings.json` | Hides six nested repositories from Source Control, with the reasoning. |
| `LICENSE` | GPL-3, which porting from Model 1 forces rather than chooses. |

Environment verified on this machine: Quartus Prime Lite **17.0.0 Build 595** at
`/home/ben/intelFPGA_lite/17.0`, Verilator 5.050, iverilog. Quartus 24.1std is
also installed and must not be used for a core build.

`tools/model1-ref` is a read-only clone of the Model 1 core at `6fd28aa`,
**cloned from the local repository rather than GitHub** — that project's newest
commits are not always pushed, and cloning upstream silently pins us behind. It
tracks commits only: uncommitted work in that worktree is invisible here, which
is not fixable and is worth remembering before concluding anything from it.

Run `tools/bootstrap.sh` on a fresh checkout. `third_party/` and
`tools/model1-ref/` are git-ignored and are not part of this repository.

---

## The question everything is sequenced to answer

The device has 41,509 ALM. Everything that is not the CPU or the renderer comes
to 16,500 optimistic / 22,800 pessimistic, which leaves **25,009 ALM** for the
i960 and the renderer together in the good case and **18,709** in the bad one.

The current estimate for those two is **22,000 to 38,500**, and none of it has
RTL behind it.

That is the whole uncertainty of the project. It is why the milestones build the
CPU and the GPU first and defer everything that cannot change the answer.

---

## What remains

### Next, and none of it needs FPGA design work

- **M2-E** — compile `N64_MiSTer` for `5CSEBA6U23I7` with Quartus 17.0. Extract
  per-module ALM for the RDP and the R4300i, and achieved Fmax at real
  utilization. Highest-value hour in the plan: it produces measured, same-part
  proxies for *both* big blocks before either is started. Read the RDP source
  while the fitter runs.
- **M2-H** — build an M10K budget. There isn't one. See findings below.
- **M2-B** — count i960 FP instructions per frame by opcode class. Scopes the
  FPU, which is most of the spread in the i960 estimate.
- **M2-A** — texture cache hit rate. Instrument `model2_v.cpp`, replay through a
  software cache model across 16/32/64 KB and 2/4/8-way.
- **M2-G** — email srg320 about the SCSP licence. Send it now; a late yes is
  worth less than an early one.

### Measured CPI — the pipeline's actual target

| mix | CPI | M instr/s at 45.16 MHz |
|---|---|---|
| ALU only | 7.33 | 6.16 |
| + 10% multiply/divide | 11.89 | 3.80 |
| harness full mix | 15.86 | 2.85 |

Requirement is 12.5-16.7 M instr/s, so even the ALU-only figure is **2x short**.
An earlier note in this file said "~6 cycles per instruction, about half" — that
was an estimate and it was optimistic; 7.33 is measured.

**The pipeline needs low CPI more than a high clock.** At the already-measured
45.16 MHz, 2 CPI gives 22.6 M instr/s and 3 CPI gives 15.0 M — both clear the
requirement. It can afford to lose Fmax to hazard logic if that buys CPI.

### Deferred, not forgotten

`docs/p1-i960-spike.md` carries an **optimisation backlog** with five items,
each with a measurement behind it. The two that matter: the register file is 49%
of the CPU and the measured critical path runs through its combinational read
multiplexer, and the ALU describes six shifters, four comparators and three
adders separately. Both are deferred because the pipeline has to decide read
latency and datapath sharing anyway — doing them first means doing them twice.

**Revisit that section when step 6 lands.**

### Then — P1 step 6, and it is the big one

Every block P1 needs now exists except the sequencer. Step 6 is the top level
that wires them together plus a transcribed whole-CPU `execute_run` to lockstep
against, and it is larger than steps 1-5 combined. It is also where the pieces
stop being independently testable: the pipeline, its hazards, the interaction
between the register cache and instructions in flight (§10), and the branch and
interrupt paths all land here.

Only after that does step 7 (M2-D) mean anything — a half-CPU's area does not
answer the fit question.

The FPU is deliberately step 8 of 8: it is the only part with no oracle, and
M2-D measures the integer core.

Then P2 renderer, P3 the fit verdict, P4 TGP port, P5 sound and 2D, P6
integration. Detail in `docs/milestones.md`.

---

## Measured on the real device

Quartus 17.0.0, `5CSEBA6U23I7`, virtual pins, I/O cut. **Not M2-D** — the
sequencer, I-cache, bus and FPU do not exist yet.

| Module | ALM | Reg | MLAB bits | Fmax |
|---|---|---|---|---|
| `i960_dec` | 103 | 0 | 0 | comb |
| `i960_alu` | 852 | 0 | 0 | comb |
| `i960_regs` | 1,655 | 1,261 | 2,048 | 94.86 MHz |
| `i960_agu` | 252 | 0 | 0 | comb |
| `i960_ldst` | 126 | 0 | 0 | comb |
| `i960_lsu` | 241 | 188 | 0 | 142.57 MHz |
| `i960_memmap` | 35 | 0 | 0 | comb |
| `i960_icache` | 472 | 861 | 4,096 M10K bits | **84.97 MHz** |
| **total** | **3,736** | 2,310 | | |

`i960_icache` is **under the gate's 90 MHz** at 84.97. The tag compare feeding
the hit decision is the obvious suspect. Not addressed; recorded.

**Assembled `i960_top`: 3,155 ALM, 43.91 MHz.** Area fell 581 ALM on assembly
because the fitter deleted logic nothing consumed; Fmax roughly halved against
the slowest block, because the critical path is created by assembly —
`i960_regs|loc[10][3]` → `wd[9]`, register read through ALU to writeback in one
FSM state, which is exactly where a pipeline boundary goes.

**Do not read 3,155 as the i960's cost.** It executes 66 of 159 mnemonics, 14
more are semantically wrong (`cmpob`/`cmpib` do not compare; `test<cc>` is
treated as a branch), and 79 are absent including the entire FPU, integer
multiply/divide and all fault handling. Projected total with the missing blocks
and the pipeline: **8,155 - 14,255 ALM**, against the study's 7,000-13,500.

That **corrects an earlier note in this file** describing the per-module total as
tracking toward the lower half. It does not: the five blocks measured first were
the cheap ones. The 581 ALM assembly saved will also not repeat, and DSP usage
is currently zero — multiply and the FPU will both claim blocks.

## Findings

### Settled

**M2-C is closed, pass.** `mb86234_device` is an empty subclass of
`mb86233_device` — overrides nothing, adds nothing, same memory config, only the
device-type tag differs. The MB86234 and MB86233 are behaviourally identical in
MAME, so 3,179 lines of Model 1 TGP RTL transfer unmodified along with the fuzz
suites and lockstep harness. **Caveat: this is absence of evidence, not proof.**
MAME modelling them identically means no game has yet needed a difference. The
oracle is the thing asserting the equivalence, so a later divergence would have
nothing behind it.

**No open-source i960 exists in any HDL.** Searched and not found. Combined with
MAME modelling the four 80-bit FP registers as host `double`, the i960KB is a
from-scratch pipelined CPU with a partially unverifiable FPU. This was never
listed as a sourcing risk before.

**S24TILE is already written and it is ours.** `model1.cpp:1830` instantiates the
same `S24TILE` device Model 2 uses. Model 2 remaps the base address; the chip is
unchanged.

**`N64_MiSTer` is GPL-3.0**, not merely readable. It is an architectural
reference for the renderer, not only an M2-E comparable.

**The i960's transcendentals are enormously slow, so the FPU can be microcoded.**
`sinr`/`cosr` are 406 cycles, `sinrl`/`cosrl` 441, `logr` 438, against 10 for
`addr` and 18 for `mulr`. At 25 MHz that caps `sinr` at ~1,000 per frame with the
CPU doing nothing else. A CORDIC at ~64 iterations is ~6x faster than the
silicon on the operations that dominate FPU area, and 36 cycles for `mulrl`
affords an iterative 27x27 DSP multiply rather than a wide combinational one.
This pushes the widest line in the i960 estimate toward the bottom of its
2,500-6,000 range, and changes M2-B's purpose from verdict to mix.

**Downgraded to a hypothesis.** The argument that `i960.cpp` could be trusted
where `v60.cpp` could not inferred accuracy from the absence of a disclaimer,
which proves nothing — the file has no header caveat and MAME claims nothing
about cycle accuracy either way. The "survives being wrong by 2x" hedge only
helps if the figures are in the right region at all.

Two things would settle it: the i960KB Programmer's Reference Manual
**270567-001**, and **M2-B**, which counts what games actually issue and depends
on no cycle model. Until then the budget keeps the full 2,500-6,000 FPU range
and M2-B stays on the critical path. Design study R8.

**The register cache is cheaper than §5.2 assumed, and its depth is not free to
change.** MAME copies sixteen words per `call` because it is software; in RTL a
banked four-frame local file makes `call` a frame-pointer increment — ~2 M10K
and ~128 ALM, against ~512 ALM for a flat flip-flop file of the same storage.
But a spilled frame *writes to memory*, so cache depth is visible in the write
stream lockstep compares. Four frames, matching the reference. Deeper caching
later is a behaviour change needing its own verification, not a free win.

**MAME's `addc` and `subc` never set carry, so the integer oracle has one hole.**
Its expression evaluates entirely in `uint32_t` and wraps before being widened to
`uint64_t`, so the bit-32 carry test can never be true. Verified: `0xffffffff + 1`
gives `res = 0` with bit 32 clear. The `// set carry` comment and the deliberate
`(uint64_t)1 << 32` mask show the intent, so it is an integer-promotion defect
rather than a modelling choice — and these two instructions exist to chain
multi-word arithmetic.

**The RTL implements hardware carry and diverges on purpose** (design study §2.3,
R7). Whole-CPU lockstep will therefore diverge on any program using `addc` or
`subc`, and that is expected rather than a bug. The divergence is bounded by
measurement: over 12.8 M vectors across all 64 `op`/`op2` pairs in `0x58`-`0x5b`
it touches exactly two operations, the union of differing AC bits is exactly
`0x00000002`, and `result`, `result_we` and `valid` never differ.
`make test_i960_alu_carrybug` guards this and **fails if the RTL stops
diverging**.

**Unknown and unanswerable here:** whether Model 2 games actually use `addc` or
`subc`. It needs program ROM. If they do not, the hole is theoretical.

**A memory that simulates perfectly can still be flip-flops.** The register
cache was written with the array indexed inside the control FSM. Every test
passed. Quartus refused to infer it — `RAM logic "rcache" is uninferred due to
unsupported read-during-write behavior`, `Total MLAB memory bits : 0` — and it
became 2,048 flip-flops.

| | ALM | Reg | MLAB bits | Fmax |
|---|---|---|---|---|
| in flip-flops | 2,355 | 3,303 | 0 | 68.44 MHz |
| in MLAB | 1,655 | 1,261 | 2,048 | 94.86 MHz |

**30% of the module and 26 MHz.** The fix is a dedicated write port and a
dedicated *registered* read port with their own address signals, rather than
indexing the array inside the FSM. Watch the register count, not the memory
count — it moves first.

### Retracted

**The SCSP was recorded as having licence-compatible RTL. It does not.**
`srg320/Saturn`, `srg320/Saturn_MiSTer` and `MiSTer-devel/Saturn_MiSTer` all
report no licence, and `SCSP.sv` has no SPDX header and no copyright notice. No
licence is all rights reserved — no permission to copy and none to adapt, which
is the position this project family already took on `geometrizer`. It may be
read and used as an external oracle. It may not be ported. The SCSP is now a
from-scratch block against MAME's BSD-3 `scsp.cpp`.

### Open, and the one to worry about

**There is no M10K budget, and M10K may be the binding resource.** The Model 1
project reports 409 of 553 M10K spent on this same part, with a *simpler*
renderer — flat-shaded, no Z-buffer, no texture cache. This project budgets ALM
to 1,000-ALM precision across five rows and does not budget M10K at all.

Model 2's tile buffers and texture cache alone want ~78 blocks that Model 1
never needed. The three consumers not yet quantified here — S24TILE RAM, SCSP
state, and the MiSTer `sys/` framework itself — are precisely where Model 1
spent most of its 409.

The arithmetic does not obviously close, and it cannot be settled by reasoning
because the unquantified rows are the deciding ones. **An ALM answer to the fit
question is not an answer if the design runs out of memory blocks first.** M2-H
exists to fix this before P1, not after P2. Consequences if it binds: the "push
logic into M10K" area lever does not exist, the tile size in §6.2 becomes a
two-sided trade, and M2-A's cache-size sweep becomes a design decision rather
than a confirmation.

**Does fx68k simulate under Verilator?** Not confirmed. Rule 8 and every
verification practice here assume a block can be exercised in simulation before
it reaches the fitter, and this is the criterion that decided tv80 over T80 for
the Model 1 I/O board. Fully synchronous SystemVerilog is a good sign, not an
answer.

**The renderer still has no bit-exact oracle**, and never will. Verification is
by framebuffer comparison, which localises bugs poorly. Plan instrumentation
accordingly.

**The i960 FPU has no bit-exact oracle either, and the decision is unmade.**
MAME models the four 80-bit registers as host `double`. Either verify against a
software 80-bit reference — x86 `long double` is 80-bit and is the cheapest
route to one — or implement 64-bit and document the deviation. The first is
preferred and is the only option that makes lockstep meaningful for FP. Do not
let this be decided by default.

**P1 pipelines with no rehearsal.** M2-F was the cheap way to learn whether a
pipelined CPU of this class closes timing on this part, on a 3,000 ALM block
with an existing harness. Deferring the TGP removed it, so the largest
from-scratch block goes first with nothing proven ahead of it. Accepted
knowingly. If the Quartus spike misses, Model 1's M0 retiming notes are the
closest prior art.

---

**A fuzz suite this size measures internal consistency, not correctness.** The
decoder passed 6.0e9 field checks against its reference with zero mismatches,
and both were written by the same author from the same source — a misreading of
`i960.cpp` appears in both and the suite agrees enthusiastically.

The only independent check available was `i960dis.cpp`'s mnemonic table, written
separately from the `execute_op` dispatch our opcode set came from. It confirmed
no opcode was invented and no format boundary disagrees. It could not check
field positions, because it was the source for none of them.

**So the literal-select bit numbers, the MEMB mode and scale fields, and both
displacement widths are transcribed, not verified.** Closing that needs the
i960KB Programmer's Reference Manual (270567-001, cited in `i960dis.cpp`'s own
header) or real Model 2A program ROM decoding to sensible instruction sequences.
Worth doing before step 5, because a wrong field position will present as a bus
bug and be looked for in the wrong place.

## What was wrong, and the lesson

The design study asserted three third-party RTL sources without opening any of
the repositories. Two were wrong — one against the project and one in its
favour. The area consequence was 1,000 ALM out of 39,500, which is nothing; the
real cost was a plan built on a block believed to be free that is not.

**A licence claim is a fact about a file, and checking it costs one API call.
Neither a search result nor a recollection is a licence check.**

Recorded as the study's second recurring failure mode, alongside the first —
treating MAME's cycle counts as hardware facts, which produced two wrong
conclusions before this.

One more, from the fx68k reconciliation: the Model 1 project is measuring the
same device, and its commit messages carry findings that exist nowhere else.
M10K binding came from a commit message, not from any document. **Pull that
reference when it moves and read what changed, rather than only taking files
from it.**

---

## FP-register verification — closed as a check, open as a defect

**Suite state: `make test_i960_top` FAILS.** Committed failing deliberately, so
the defect is visible rather than carried as a note.

### The gap was real, and it was not what it looked like

The fp0-fp3 comparison had been in the harness for some time and had never
failed. It was **inert**: `i960_cpu_ref.h` dispatched on
`(d.op << 8) | d.op2` against `case 0x78f:` labels. Opcode and sub-opcode pack
as `0xOOS` across *three* hex digits, so the shift is 4. With 8, no label ever
matched, `handled` stayed false, and the reference **trapped on every FP
instruction** — which ended the lockstep loop before it reached a single
comparison. The DUT was executing FP the whole time and nothing was reading it.

This is the same defect class as the generator's `0x78f >> 8`, found earlier the
same day, and the fourth time a check that looked present did nothing. **A check
that has never failed is not evidence; it is an untested branch.**

### Real bugs this then exposed

1. **Stale `done` retiring the wrong result.** `T_FP` accepted *any* unit's
   `done`, so a strobe left by an earlier instruction could retire a result the
   current instruction never computed. Now qualified per-unit
   (`fp_is_sqrt && fsqrt_done`). The multi-cycle units — divide and sqrt — are
   exactly where that window is widest.
2. **`scaler` read the wrong operand.** Its FP source is src2; every other
   fpmisc op reads src1.
3. **`scaler` is a multiply, not an exponent add.** The reference computes
   `t2f * pow(2.0, n)`. When `pow` overflows, `0 * inf` is NaN — an exponent add
   returns zero. Now routed through `i960_fpmul` with 2^n materialised as a
   double, so every special case is the multiplier's already-verified logic.

### Deviations that had to be excluded, and why skipping was not enough

Two recorded deviations (§8.1) reach architectural state, and that changes how a
harness must handle them:

- **Subnormal flush.** The units flush, the host does not. At block level this
  is rare; at CPU level it is common, because *any* small integer left in a
  register is a subnormal when reinterpreted as a single — `0x1b` is 3.8e-44, so
  `0 / 0x1b` is 0 on the host and 0/0 = NaN once the divisor flushes. It applies
  to results as well as operands: two normal singles can divide to a subnormal.
- **NaN payload.** The units emit one canonical quiet NaN; the host propagates
  the operand's sign and payload.

First attempt skipped the comparison for that retire. **That was wrong** — the
diverged word stays in the register file and every later retire in the program
fails on state already known to differ. The program must be **abandoned** at
that point, exactly like a trap. Skipping a comparison does not undo a write.

Both are counted and printed, so an exclusion cannot quietly become most of the
run: currently **13 programs end on a subnormal, 1 on a NaN result, out of 200**.

### Where it stands

256 retires against 113 before, 53 FP ops executed, **4 of them writing fp0-fp3**
— so the comparison is now demonstrably reading real content.

**One unresolved defect, and the evidence is contradictory:**

```
MISMATCH retire 1  fp2  got=0000000000000000 want=43940b9ff8b76ef9
                        (insn 6815a407 = sqrtr, s1=07, dst_lit=1)
[dbg] r7=79c8e8c3  fsqrt_y=0  fpr = 0/0/0/0
```

`r7` is a valid large single and the expected root matches it exactly. The IP
advanced, so the instruction retired — but no FP register was written. Checked
and **eliminated**: `fp_valid` does dispatch `0x68.8`; `is_movx` does not
capture it (it requires op2 == 0xc); `d_dst_lit` is bit 13 in both the RTL and
the reference and is 1 here; `fp_writes_cc` and `fp_writes_int` are both false
for sqrt; the accessor is proven good by a write/read-back probe. `fsqrt_y = 0`
at compare time may be a red herring — the unit likely clears its output on
returning to idle, several cycles after the retire.

**The next move is a waveform, not another hypothesis.** Dump `T_FP`, `fsqrt_req`,
`fsqrt_done` and `fp_a` for that single program and find which branch of the
writeback actually fires. Five successive guesses were each eliminated by
inspection, which is the signal to stop guessing and look.

Do not extend the FPU — the `rl` forms, `remr`, the transcendentals — until this
closes. All of them write fp0-fp3, and until this is understood that path is
unproven in exactly the dimension they depend on.
