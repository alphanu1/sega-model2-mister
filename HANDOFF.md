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
## FP-register verification — closed

**All 15 suites pass.** The fp0-fp3 comparison is verified by mutation, not
assumed.

### The gap was real, and it was not what it looked like

The comparison had been in the harness for some time and had never failed. It
was **inert**: `i960_cpu_ref.h` dispatched on `(d.op << 8) | d.op2` against
`case 0x78f:` labels. Opcode and sub-opcode pack as `0xOOS` across *three* hex
digits, so the shift is 4. With 8, no label matched, `handled` stayed false, and
the reference **trapped on every FP instruction** — ending the lockstep loop
before it reached a single comparison. The DUT was executing FP the whole time
with nothing reading it.

Same defect class as the generator's `0x78f >> 8` found the same day, and the
fourth instance of a check that looked present and did nothing. **A check that
has never failed is not evidence; it is an untested branch.**

### The bug that mattered: a request strobe that was never lowered

`fadd_req`, `fmul_req`, `fdiv_req` and `fsqrt_req` were set in `T_EXEC` and
never cleared. They were missing from the per-cycle default block that already
clears `ic_req`, `lsu_req` and `md_req`, and absent from reset.

Left asserted, a unit **restarts the instant it returns to idle** and spins
permanently busy — so the next instruction of that type reads a `done` from the
spurious run rather than its own. It presented as `sqrtr` retiring without ever
writing its FP register.

It was throttling the entire run, not just breaking sqrt:

| | before | after |
|---|---|---|
| retires | 256 | **2,205** |
| FP ops executed | 53 | **514** |
| writes to fp0-fp3 | 4 | **58** |
| field checks | 9,728 | **83,790** |

**The lesson is the default block, not the strobe.** Three request signals were
in it and four were not, in the same module, with nothing to make the omission
visible. A one-cycle strobe that is never lowered does not fail loudly; it makes
a unit quietly always-busy, and the damage lands on the *next* instruction of
that type — which is why five rounds of reading the writeback path all came back
clean. It was found by probing every cycle of an FP op, after the reading
approach had been exhausted. **When successive hypotheses are each eliminated by
inspection, stop inspecting and instrument.**

### Two other real defects the working check then exposed

1. **`scaler` read the wrong operand.** Its FP source is src2; every other
   fpmisc op reads src1.
2. **`scaler` is a multiply, not an exponent add.** The reference computes
   `t2f * pow(2.0, n)`. When `pow` overflows, `0 * inf` is NaN — an exponent add
   returns zero. Now routed through `i960_fpmul` with 2^n materialised as a
   double, so the special cases are the multiplier's already-verified logic.

### Deviations reach architectural state, and skipping is not enough

Two recorded deviations (§8.1) write to registers, which changes what a harness
must do about them:

- **Subnormal flush.** The units flush, the host does not. Common at CPU level
  and rare at block level, because *any* small integer left in a register is a
  subnormal read as a single — `0x1b` is 3.8e-44, so `0 / 0x1b` is 0 on the host
  and 0/0 = NaN once the divisor flushes. It applies to results too: two normal
  singles can divide to a subnormal.
- **NaN payload.** The units emit one canonical quiet NaN; the host propagates
  the operand's sign and payload.

The first attempt **skipped the comparison** for that retire. That was wrong —
the diverged word stays in the register file and every later retire fails on
state already known to differ. The program must be **abandoned**, exactly like a
trap. *Skipping a comparison does not undo a write.*

**Then the subnormal flush was modelled instead of excluded**, and the
truncation went to zero. The flush is a two-line predicate written from §8.1 —
exponent 0, mantissa non-zero, return signed zero — not read off the RTL, so it
does not agree with the design by construction. If a unit flushed something it
should not, this would still diverge. It does not.

| | excluded | modelled |
|---|---|---|
| retires | 2,205 | **3,870** |
| FP ops | 514 | **828** |
| writes to fp0-fp3 | 58 | **115** |
| field checks | 83,790 | **147,060** |
| programs truncated | 111 + 18 | **0 + 33** |

**Modelling a known deviation beats excluding it, when the deviation has a
short specification.** Excluding threw away 111 of 200 programs and truncated
them at their *deepest* retires, which is where the interesting state is.
Modelling turned the same deviation into 147,060 assertions that the flush is
exactly right.

**33 programs still end on a NaN result, and that is left alone deliberately.**
The units do not share one NaN rule: `i960_fpdiv` emits a canonical
`0x7ff8_0000_0000_0000`, while `i960_fpcvt` propagates sign and payload through
narrowing. Modelling each unit's NaN would mean transcribing each unit's rule
into the reference — which is precisely the agree-by-construction failure the
reference exists to avoid. 16.5% truncation is the honest price of keeping the
oracle independent.

### Proof the check works

Three mutations, each **killed**:

| mutation | result |
|---|---|
| `fpr[d_srcdst[1:0] ^ 1]` — wrong register | killed |
| FP writeback stores `64'd0` — dropped result | killed |
| `fp_lit` 0x16 returns 0.0 instead of 1.0 | killed |

## CPI is mix-dependent, and the synthetic mix is not Model 2's

Worth stating plainly because a single CPI number has been quoted in two places
and they measure different things:

```
T_MULDIV   21699 cycles   9.84 cyc/instr   53.2%   <- dominant
T_FETCH     5343 cycles   2.42 cyc/instr   13.1%
T_FETCH_W   4648 cycles   2.11 cyc/instr   11.4%
T_FP        3350 cycles   1.52 cyc/instr    8.2%
CPI 18.50 (incl. reset and I-cache misses)
```

Fetch was 58% of cycles before the I-cache fill hold and sequential prefetch
went in; it is now 24.5% and **divide dominates**. But the fuzz generator emits
instruction classes roughly uniformly, so divides are enormously
over-represented against real code. 18.50 is the CPI of the generator's mix, and
the earlier 3.31 was a warm-cache figure on a different mix without FP.

**Neither is the throughput number the fit question needs.** That requires the
real instruction mix, which is exactly what **M2-B** measures — still open, and
its value just went up: it now sets the CPI weighting as well as scoping the
FPU. Do not quote a CPI figure without saying which mix produced it.

---

## Register file registered read — done, and it did not deliver

**Measured, not estimated:** Fmax 25.29 → **27.3 MHz**, +8%. The optimisation
backlog called this item "large". It was the best-evidenced item in that table —
1,547 ALM, 49% of the CPU, and the measured critical path ran straight through
it — and it bought 8%.

| | before | after |
|---|---|---|
| critical path | `ra1[2]` → `wd[28]` | `rd1[29]` → `wd[26]` |
| slack | 0.451 | **3.370** |
| Fmax | 25.29 MHz | **27.3 MHz** |
| lockstep cycles | 65,630 | **65,630** |

The change worked; the path just moved. The register read was the **first half**
of the path, and the second half is the execute datapath — operand through the
ALU and the result multiplexing into writeback. Slack went up sevenfold, so the
cut was real. It was not where the remaining time is.

**The latency cost zero cycles**, which was the part expected to be expensive.
Every read address was already presented in the state before its consumer, so
`ra1`/`ra2` became combinational drives in `i960_top` and the register file
supplies the cycle the sequencer used to. Identical cycle count, identical
retire count, identical checks. The item was recorded as "blocked on a step-6
pipeline decision" — the decision turned out to be free.

**The conclusion is the useful part: 90 MHz is not reachable by optimisation.**
From 27.3 that is a 3.3x reduction in path delay and there is no remaining
single structure worth 3.3x. Backlog items 2-5 should not be attempted as Fmax
work — at best they are area and clarity. The execute path has to be split
across stages, which is the pipeline.

### The write bypass: written, mutation-tested, then deliberately removed

A read-during-write forwarding path was written first, on the reasoning that
relying on the sequencer's spacing would be an unstated assumption. **Both
bypass forms were then mutation-tested and both SURVIVED** — across 3,870
retires and 147,060 checks, nothing distinguishes having it from not.

Chasing why that was so produced the real finding. The only reachable
read-during-write is an **overlapping `movl`/`movt`/`movq`** (`movl r4, r5`),
where `T_MULTI` writes word *i* while reading word *i+1*. And that case **has no
oracle**: MAME implements all three with `memcpy` on overlapping regions
(`i960.cpp`, cases 0x5d/0x5e/0x5f), which is undefined in C. The reference
transcribed it faithfully and the generator excludes it.

So the bypass was not insurance — it **silently changed behaviour in the one
case nothing can check**. With it an overlapping `movl` propagates; without it,
and in the original combinational design, it does not. It was removed.

**A refactor must not change semantics the oracle cannot check.** The instinct
that added the bypass was the right instinct applied to the wrong case: dead in
every checked case, and behaviour-changing in the only unchecked one. Mutation
testing is what turned "probably fine" into a decision — the surviving mutant
was the finding, not a failure of the suite.

**Open, and unresolvable from MAME:** what real i960 silicon does with an
overlapping `movl`. Only the i960KB manual or hardware answers it. Recorded here
so it is not rediscovered as a bug.

### Final measurement, and what it means for the gate

`i960_top`, Quartus 17.0.0, `5CSEBA6U23I7`:

```
ALM 6,986   reg 3,487   MLAB bits 2,048   DSP 7   Fmax 27.44 MHz
```

**Area is not the problem and never has been.** 6,986 against a 12K pass band,
inside the budget the fit question depends on. The clock is the problem.

**But "90 MHz" is the wrong number to be failing against**, and the milestones
document already says so at §P1: *"The requirement is throughput, not clock:
12.5-16.7 M instr/s."* The 90 MHz in exit criterion 4 is a proxy, and at the
measured Fmax the proxy and the requirement disagree sharply:

| CPI | at 27.44 MHz | verdict |
|---|---|---|
| 1.5 | 18.29 M instr/s | clears |
| **2.0** | **13.72 M instr/s** | **clears** |
| 2.5 | 10.98 M instr/s | short |
| 3.0 | 9.15 M instr/s | short |
| 4.0 | 6.86 M instr/s | short |

**A 2-CPI pipeline meets the requirement at today's clock, with no Fmax work at
all.** That is the single most useful number produced this session, and it
inverts the conclusion the 90 MHz gate was pushing toward.

It also kills the fallback. Milestones §P1 says *"Target 2 CPI, accept 4."*
**Accept-4 is dead** unless Fmax roughly doubles: 4 CPI needs 50 MHz and 3 CPI
needs 37.5 MHz, against 27.44 measured. The pipeline has to be the aggressive
version, and "we can always settle for 4 CPI" is no longer available as a
retreat.

Restating the target for whoever builds it:

- **Primary: 2 CPI.** Everything else is secondary, including Fmax.
- Fmax buys margin, not viability — every MHz above 27.44 widens the CPI budget
  (37.5 MHz would make 3 CPI viable, restoring the fallback).
- **Do not spend effort on 90 MHz.** It is a proxy that has now been measured
  against reality and found to be ~3.3x stricter than the requirement it stands
  for. Fix the criterion or it will drive the wrong work.

---

## T_DECODE removed — and the bottleneck is now instruction fetch

`i960_top`: **7,015 ALM, 3,504 reg, 2,048 MLAB bits, 7 DSP, Fmax 27.72 MHz.**
All 15 suites pass, 147,060 checks, zero divergence.

### What changed

Even at a 100% prefetch hit rate, `T_FETCH` → `T_DECODE` → `T_EXEC` could not
beat 3 CPI, and 3 CPI at 27.44 MHz is 9.15 M instr/s against a 12.5 M floor. The
decoder is combinational and ~103 ALM, so it now reads the word **arriving**
during a fetch state: the register numbers, the trap check and the prefetch
decision are all available in the cycle the instruction lands. `T_FETCH` and
`T_FETCH_W` merged into one body so the front end is written once.

Measured: **65,630 → 61,560 cycles**, 1.05 cyc/instr, matching `T_DECODE`'s old
1.14 exactly.

### The Fmax loss was a false path, not the decode

The first version cost 27.44 → 24.63 MHz, and the obvious explanation — decode
now sits in the fetch path — was wrong. Selecting one decoder's input with
`(ts == T_FETCH) ? fetch_word : insn` creates a **static** path
`ip → (pf_ip == ip) → dec_in → decode → ALU → wd`. No cycle ever uses it, since
during `T_EXEC` the decoder reads the latched word — but static timing cannot
know that, and it became the critical path at `ip[26] → wd[13]` with **negative
slack**.

Two decoders remove it structurally, for +109 ALM: the arriving-word decode
feeds only the register numbers and the front-end decisions and never reaches
writeback. Chosen over an SDC false-path exception because **a constraint that
stops being true fails silently, whereas a structural fix cannot rot.**
Fmax came back to 27.72, marginally past the original.

**Measure before redesigning, again.** The guessed cause was the decode path;
the measured cause was a multiplexer. Third time this session that reading the
source produced a plausible wrong answer and the timing report produced the
right one.

### Do not report 13.86 M instr/s. The average is 5.20.

A simple instruction on a prefetch hit is now 2 CPI, which at 27.72 MHz is
13.86 M instr/s and clears the floor. **That is the best case and it is not what
the design delivers.** The measured average:

| | cyc/instr | |
|---|---|---|
| `T_FETCH` | 2.39 | |
| `T_FETCH_W` | 1.89 | |
| **fetch subtotal** | **4.28** | **80% of a simple instruction** |
| `T_EXEC` | 1.05 | |
| **simple instruction** | **5.33 CPI** | **5.20 M instr/s — short** |

**The pipeline structure is no longer the bottleneck; instruction fetch is.**
For 12.5 M the budget is 2.22 CPI, so fetch must average **1.17 cycles against
4.28 now**. Where the 4.28 goes:

- **60.8% prefetch hit rate** — 4,101 fetches, 2,493 hits.
- **6,948 fill-wait cycles.** A 16-byte line is 4 instructions, so purely
  sequential code cannot miss less than 25% of the time. Larger lines or a
  deeper prefetch attack this directly.
- **4,626 cycles stuck in `T_FETCH`** waiting for a *discarded* prefetch's fill
  to drain, because the cache ignores requests while filling. This is the
  self-inflicted portion and the most promising: invalidating the line at fill
  start would make an abort safe, letting a redirect pre-empt a fill it no
  longer wants. Not attempted — it is the exact area that produced the stale-
  fill bug, and it wants its own session.

**Caveat, and it is R9 again:** this workload is 200 short programs that each
start cold, so the miss rate is pessimistic against real code with loops. The
hit rate is exactly the sort of number M2-B would replace with a measurement.
Do not tune the cache against this workload and believe the result.

### I-cache fill abort — attempted and reverted (RESOLVED later; see below)

The 4,626 self-inflicted stall cycles are still there. The attempt is recorded
because it eliminated three hypotheses, and the next attempt should not pay for
them again.

**The idea.** The requester waits for `!ic_busy` before issuing, so a
mispredicted prefetch leaves a fill in flight for a line nothing wants and the
next demand fetch waits it out. Let the cache **abandon** a fill when a
different line is requested, and drop the `!ic_busy` guard.

**The safety condition, which is correct and worth keeping.** `cvalid` is only
set on completion, but the *data* array is written word by word during the fill.
So a line that was valid under a different tag has its data destroyed while
still advertising a hit. Harmless while fills always completed; fatal once they
can be abandoned. `cvalid[idx] <= 1'b0` at fill **start** fixes it. Any future
attempt needs this.

**The failure, unchanged across three fixes:**

```
MISMATCH retire 13  g4  got=2094df56 want=00000016  (IP 00000044 insn 5fb80e16)
                    g5  got=68351c4c want=00000016
                    g6  got=99002e43 want=00000016
                    g7  got=6443cdb3 want=00000016
```

`5fb80e16` is `movq` with `src1_lit` set, so all four registers should take the
literal 22. They took what looks like memory contents, which means the **latched
instruction word was not this instruction** — the fetch delivered the wrong
word.

**Three hypotheses, each plausible, each eliminated by making the change and
re-running:**

1. *A speculative prefetch hijacks the demand fill.* The front end also issues
   `ic_req`, so a prefetch could abort the fill `T_FETCH_W` is waiting on.
   Gated the prefetch on `!ic_busy`. **No change.**
2. *`S_DONE` answers a request it did not service.* It asserts `valid`
   unconditionally and ignores `req`; `busy` used to cover `S_DONE` so the
   requester never issued there. Made `S_DONE` service a miss. **No change.**
3. *The abandoned line's partial data is readable.* Addressed by the invalidate
   above, which was in from the first version. **Not the cause.**

**Next attempt starts with instrumentation, not a fix.** Log every `(state, req,
addr, fill_base, valid, data)` tuple for the failing program and find which
cycle hands over the wrong word. Three eliminated guesses is the same signal
that the `sqrtr` bug gave earlier today, and the answer there came from a
per-cycle probe within minutes of giving up on reading the source.

**Standing suspicion for next time:** `req` is a one-cycle pulse and `addr` is
held, so any state that does not consume a `req` in the cycle it arrives loses
it entirely. A pending-request latch — capture `req`/`addr` when they cannot be
serviced, replay on return to `S_IDLE` — is probably the right shape, rather
than patching each state to handle arrivals.

**Also worth knowing: the block harness does not exercise this at all.**
`test_i960_icache` passes with 201,232 fetches because it never issues while
busy. Whatever lands next needs a directed abort test at block level, or the
whole-CPU harness stays the only thing that can see it.

---

## Pushed, 2026-08-17 — `aa8a6ba..78e2bfb`, 12 commits

Tree green: all 15 suites, 147,060 checks, zero divergence. `i960_top` at
**7,015 ALM, 7 DSP, 27.72 MHz** on Quartus 17.0.0 / `5CSEBA6U23I7`.

### One finding from the pre-push check, worth keeping

The rules file was cited **by filename** in three tracked files —
`docs/model2a-design-study.md`, `rtl/cpu/i960/i960_alu.sv` and
`sim/i960/tb_i960_dec.cpp`. That file is git-ignored, so the public tree
carried citations to something not in it, and the rules permit exactly one
reference to it: its line in `.gitignore`. Rewritten to cite the rule rather
than the file.

It predated this session and had already been pushed, which is the point worth
recording: **it survived because nothing checks for it.** The check that caught
it is one grep, and it belongs in the pre-push routine rather than in whoever
happens to look:

```
git grep -ilE 'claude|anthropic' -- .        # must return .gitignore and nothing else
git log --format='%an <%ae>' @{u}..HEAD | sort -u    # must be the one author
git log --format='%B' @{u}..HEAD | grep -icE 'co-authored|generated with'   # must be 0
```

The authorship and trailer checks were clean; only the filename citation was
not. A rule with no test is a rule that drifts.

### Where the next session starts

**Instruction fetch, not sequencing.** 4.28 of the 5.33 cycles a simple
instruction costs, against the 1.17 a 12.5 M instr/s target allows. The
fill-abort attempt and its three eliminated hypotheses are recorded above —
start with the per-cycle instrumentation, not another fix, and add a directed
abort test to `test_i960_icache`, which currently cannot see that class of bug
at all.

---

## I-cache fill abort — resolved, and the method is the point

`i960_top`: **7,079 ALM, 3,492 reg, 7 DSP, Fmax 26.78 MHz.** All 15 suites,
147,060 checks, zero divergence.

The previous attempt was reverted with three hypotheses eliminated by
inspection. It was solved by doing exactly what that note said to do, in that
order — **write the block-level test, then instrument.** Neither step was a
fix, and both were skipped the first time.

### Step 1: the test the harness could not previously express

A directed redirect pass in `test_i960_icache` issues a fetch, lets the fill
start, then asks for a different line — at every point in a 4-word fill, across
line and set boundaries. It **reproduced the failure at block level
immediately**, where it is minutes to debug rather than a whole-CPU lockstep
divergence 13 retires deep.

That blind spot was real and worth naming: `fetch()` waits for `valid` before
issuing again, so in 201,232 fetches the harness had **never once** asked the
cache for anything while it was busy. It was not that the test was weak; the
scenario was inexpressible.

With that test the cache abort passed in isolation — which is what located the
fault in `i960_top` rather than the cache, after two sessions of assuming the
cache was wrong.

### Step 2: the ring buffer found it in one run

64 cycles of front-end state, dumped on the first mismatch:

```
t=855  ts=T_FETCH  valid=1  addr=00000044  data=5fb80e16  insn=1900bcd4  ip=00000044
t=856  ts=T_EXEC   req=1    addr=00000048  data=5fb80e16  insn=1900bcd4  ip=00000044
```

The correct word is **right there** with `valid` asserted, and `insn` does not
update. One cycle earlier the front end had issued the prefetch and armed it in
the same cycle the *previous demand fetch's* `valid` was still asserted, so the
prefetch captured that stale valid and stored the previous instruction as the
prefetched word. `pf_ip` still matched, so `T_FETCH` accepted it and executed
the wrong instruction.

**Removing `T_DECODE` deleted the cycle that used to separate those two events.**
A latent ordering assumption that had been safe became live — the same shape as
the register-file write bypass, which was dead logic until the same change made
it load-bearing. Two ordering assumptions broken by one restructure.

Fix: arm one cycle after issuing (`pf_armed <= pf_issued`). Costs nothing — the
request is registered, so the earliest a genuine valid can arrive is the cycle
this makes `pf_armed` true.

### What it bought, and what it cost

| | before | after |
|---|---|---|
| waiting out a discarded fill | 4,626 | **601** |
| fill-wait cycles | 6,948 | 9,455 |
| total cycles | 61,560 | **60,037** |
| fetch cost | 4.28 cyc/instr | **3.66** |
| simple instruction | 5.33 CPI | **4.71** |
| Fmax | 27.72 | 26.78 |
| **throughput** | 5.20 M instr/s | **5.69 M instr/s** (+9.3%) |

Fills rise because an abandoned line is refetched if wanted later — the abort
trades stall cycles for refill cycles and wins, but by less than the stall
figure alone suggested.

**Sweeping the abort threshold over `fill_word <= 0, 1, 2` gives byte-identical
cycle counts.** Redirects always arrive at `fill_word 0`, so there is never
partial work to preserve and the policy question is moot. Worth having measured
rather than tuned: the obvious refinement — "don't abandon a nearly-complete
fill" — is dead code in this design.

### Next, and it is the same target

**Fill-wait is now the dominant fetch cost at 2.44 cyc/instr**, up from 1.89.
Throughput is 5.69 against a 12.5 floor, so this is still roughly half-way.

The abort attacked the *stall*; what remains is the **miss rate** itself, and
neither longer lines nor a next-line prefetch has been tried. A 16-byte line is
four instructions, so sequential code cannot miss less than 25% — that ceiling
is structural and only a bigger line or a genuine next-line prefetch moves it.
The 57.5% prefetch hit rate is a next-*word* prediction, which by construction
cannot help across a line boundary, which is exactly where the misses are.

Keep R9 in view: this workload is 200 short programs that each start cold, so
its miss rate is pessimistic against real code with loops. Do not tune line size
against it and believe the number.

---

## ST-V / Saturn as an M2-E proxy — SCSP measured, and it is cheaper than budgeted

Suggested by the user, and it is a better comparable than the N64 in one place
decisively and in another partially.

### The result

`srg320/Saturn` SCSP, Quartus 17.0.0, `5CSEBA6U23I7`:

```
SCSP   ALM 2,030   reg 2,379   MLAB bits 0   DSP 2   Fmax 76.73 MHz
```

**This is not a proxy. Model 2 uses the same SCSP.** It replaces a from-scratch
estimate of **3,000-5,000 ALM** with a measurement of **2,030** — between 1,000
and 3,000 ALM cheaper than budgeted, in the "sound + 2D" bucket that carries
8,500-12,800 of the non-CPU/GPU total. Fmax 76.73 is far above anything this
design needs.

Caveat on the figure: it is srg320's implementation, not ours, and we may not
copy it (see below), so ours could differ. But it bounds the block with a real
number on the real part, which is what M2-E is for.

### Where ST-V beats the N64, and where it does not

- **SCSP: decisively.** Same chip, so a direct measurement rather than a proxy.
- **Era and vendor:** Saturn 1994 vs N64 1996; Sega vs Nintendo.
- **VDP1 as a renderer proxy: partially, and as a FLOOR not an anchor.** It is a
  quad rasterizer and so is Model 2's renderer, where the RDP is triangle-based
  — a real architectural similarity. But §5.5 records Model 2 as having texture
  mapping, bilinear, mipmapping **and a Z-buffer**, and VDP1 has none of those.
  So VDP1 bounds the renderer from **below** where the RDP's 8,347 bounds it
  from **above**. Two measurements bracketing it beats either alone, which is
  better than the "replace N64 with ST-V" framing.

**Licence, re-verified rather than recalled:** `srg320/Saturn` and
`MiSTer-devel/Saturn_MiSTer` both still return `NO LICENSE`. Measurement and
reading only; copying a line is not permitted. Compiling locally to count ALMs
is not distribution.

**Worth knowing for M2-G:** srg320 licenses `SNES_MiSTer`, `FpgaSnes` and
`Main_MiSTer` as GPL-3.0 while `Saturn`, `Saturn_hw`, `SH`, `32X` and `S32X` all
carry none. The omission is a choice, not an oversight, which makes the M2-G
email a sharper question: *you GPL-3 your SNES core; would you grant the same
for the SCSP?*

**Still to measure:** VDP1 and VDP2. The Makefile wires them up
(`make quartus MOD=VDP1`). They instantiate Altera megafunctions, so verilator
cannot elaborate them and there is no pre-fitter check — recorded in the
Makefile rather than papered over with a command that always passes. Rule 8 is
unaffected; it governs `rtl/`.

## Critical-word-first — ATTEMPTED AND REVERTED

A miss currently waits the whole 4-word fill plus a done cycle before `valid`,
when the word actually wanted could be handed over on the first ack. Starting
the burst at the requested word and delivering it straight off the bus should
save ~3 cycles per miss, against 9,455 fill-wait cycles.

Four iterations at block level, reverted. **What it produced is still worth
having:**

1. **Abort and ack must be mutually exclusive.** Written as two separate `if`s,
   a cycle carrying both did both — the restart reset `fill_word`/`fill_cnt` and
   the ack then incremented them, so the abandoned burst continued into the new
   line's slots. Found and fixed; any future attempt needs this.
2. **The real blocker is that `req` is a one-cycle pulse.** Any cycle where the
   cache cannot service it loses it entirely. Critical-word-first adds cycles
   where that happens — a same-line request arriving on the critical-word ack
   assigns `fill_served` both 0 and 1 in the same cycle. Compensating with
   flags (`fill_served`, `early_valid`) is the wrong shape and produced stalls
   at redirect delays 4-5 that survived three different guards.
   **A pending-request latch — capture `req`/`addr` when unservable, replay on
   return to `S_IDLE` — is the prerequisite, not an optimisation.** This is the
   second time that conclusion has been reached from a different direction.
3. **The block harness cannot currently measure this.** Its miss counter is
   "did I see `bus_req` while waiting", which counts a background fill as a
   miss — the sequential walk read 0.500 against a true 0.25. **So the harness
   cannot evaluate critical-word-first even if the RTL were right.** Fix the
   hit/miss definition first.

Order for the next attempt, and it is not the order that was tried: pending-
request latch, then the harness's miss definition, then critical-word-first.

---

## M10K was being measured and thrown away — M2-H now has data

`make quartus_report` extracted the M10K figure into a shell variable and never
printed it. Every Quartus measurement this project has taken has silently
discarded the resource that **M2-H exists to budget**, and that Model 1 found
**binding at 409/553 on this same part** while ALM had headroom.

**Fourth instance of this pattern today**: the FP-register comparison that could
never run, the generator's `>> 8` opcode packing, the reference's dispatch
shift, and now this. Three of the four were a value computed correctly and then
not used. *Computing a thing is not checking it, and extracting a thing is not
reporting it.*

Fixed, and every build already on disk was re-reported without refitting.

### M10K, measured

| module | ALM | M10K of 553 | note |
|---|---|---|---|
| `i960_top` (ours) | 7,079 | **3** | the whole CPU |
| ├ `i960_icache` | 472 | 1 | 512 B instruction cache |
| └ `i960_regs` | 1,655 | 1 | plus 2,048 MLAB bits |
| `SCSP` (srg320) | 2,030 | **26** | same chip Model 2 uses |
| `VDP1` (srg320) | 2,537 | 0 | 512 MLAB bits instead |

**The i960 is not an M10K problem: 3 blocks of 553.** That is worth knowing
before the pipeline work, because a pipeline usually adds buffering and this
says there is room for it.

**The SCSP at 26 is the first real number for the sound block**, against a
budget that had none at all.

**Open, and it should be checked:** `i960_regs` reports **1 M10K plus 2,048 MLAB
bits**, when the design intent recorded in its header is MLAB *only* — chosen
deliberately because §5.6 puts the pressure on M10K blocks rather than bits. One
block is not a crisis, but it is one more than the header says should be there,
and the header explains at length why. Either the rationale or the RTL is wrong.

### VDP1 measured: 2,537 ALM, 3 DSP, 31.52 MHz, 0 M10K

The renderer floor, completing the bracket M2-E started:

| | ALM | what it is |
|---|---|---|
| N64 RDP | 8,347 | Z-buffered, mipmapped, bilinear **and trilinear**, colour combiner, coverage AA |
| **Model 2 renderer** | **8,000 - 14,000 (est.)** | Z-buffered, mipmapped, bilinear, **plus** tile binning and a texture cache |
| Saturn VDP1 | **2,537** | quad rasterizer, **no** Z-buffer, mipmapping or filtering |

**What this does and does not establish.** VDP1 is architecturally closer to us
than the RDP — both rasterize quads, the RDP does triangles — so 2,537 is a
meaningful floor for the *rasterizer core*. But it lacks every feature that
makes Model 2's renderer expensive, so the gap between 2,537 and 8,000 is
precisely the Z-buffer, filtering, mipmapping and tile machinery. It does not
narrow the estimate; it says where the money goes.

The 8,000 optimistic sits essentially *at* the RDP's 8,347, which the study
already justified as "roughly a wash" — cheaper without trilinear, the colour
combiner and coverage AA, more expensive with binning and a texture cache. Both
measurements are consistent with that judgement. **The pessimistic 14,000 is
1.7x the RDP and remains the least supported number in the budget.**

### Two arrays landed where the RTL says they should not, and only the fitter knew

Fixing the M10K report immediately paid for itself twice.

**1. `rcache_frame_addr` — 128 bits in a 10 Kbit block.** Four words, inferred
into an `altsyncram`. Pinned to logic: **−1 M10K, −16 ALM, Fmax unchanged.**
Pure waste, cleanly removed.

**2. `ctag` — the I-cache tag array, and this one is not about area.** Inferred
into an `altsyncram`, 736 bits in a block. The cache header states the tags stay
in flip-flops *"because it is read and compared combinationally on every fetch"*
— and `hit = cvalid[idx] && (ctag[idx] == tag)` depends on exactly that. **A
synchronous RAM read is not a combinational read, so the simulated circuit and
the synthesised circuit were not the same design.** Verilator models the array
combinationally and cannot see it; the standing rule that only a Quartus build
can tell you where memory landed is precisely this case.

Pinned to logic: **−1 M10K, +192 ALM, +665 registers, Fmax unchanged at 26.75.**

**Do not read that as a good resource trade — it is not.** One M10K of 553 is
noise; 192 ALM is real. The justification is correctness, not area: the design
should be the circuit the RTL describes, and relying on Quartus's
"Add Pass-Through Logic to Inferred RAMs" to rescue a combinational read from a
synchronous memory is both fragile and invisible to every test we have.

If ALM later becomes binding, this is a legitimate candidate to revisit — but
only with evidence that the inferred form is actually correct, which nothing in
the current suite can provide.

**Assembled now: 7,239 ALM, 4,209 reg, 1 M10K, 7 DSP, 26.75 MHz.**

**The general lesson, and it is the fourth today.** The M10K column had been
extracted and dropped since the first measurement. Two RTL defects had been
sitting in the design the whole time, both invisible to simulation, both
obvious the moment the number was printed. **An unreported measurement is not a
measurement**, and the cost of not printing it was two wrong circuits rather
than one wrong number.

---

## M2-B — CLOSED. The i960's FPU is cold, and the workload is load/store bound

Measured on real hardware behaviour: MAME 0.289, `daytona93`, traced with the
debugger across four sample points spanning 90 emulated seconds.

**The sample is a full 3D demo race**, confirmed by screenshot rather than
assumed — complete track, cliff geometry, scenery, six cars, textured
throughout. Visually this is the "Daytona at speed" the study names as a worst
case. It is attract mode, not interactive play: the scripted coin insert did not
register (`CREDIT 0/3`), and the difference between demo and interactive is
input handling, which is negligible against a render load.

Execution is genuine and distributed — **4,265 distinct PCs, hottest 0.3%, top
ten 2.8%** — so this is not a wait loop being sampled.

### The mix, over 150,501 instructions

| class | count | share |
|---|---|---|
| **load/store** | 79,575 | **52.9%** |
| integer ALU | 20,453 | 13.6% |
| move | 14,643 | 9.7% |
| compare/branch | 14,078 | 9.4% |
| address (`lda`) | 12,072 | 8.0% |
| call/return | 7,098 | 4.7% |
| **FP** | **1,238** | **0.8%** |
| other | 1,344 | 0.9% |

### M2-B verdict: PASS, decisively

The gate was *"low enough that a microcoded FPU costs no frame time"*.

**FP is 0.8% of instructions, and every one of them is basic arithmetic.
Zero transcendentals in 150,501 instructions.** Not one `sinr`, `cosr`, `tanr`,
`atanr`, `logr` or `expr`.

That makes architectural sense and is the first evidence for it: **the TGP does
the geometry**, so the i960 is the game CPU, not the maths engine. It moves data.

Two consequences for P1, and both reduce work:

- **The FPU can be microcoded and shared.** A wide FPU would be silicon spent on
  0.8% of instructions.
- **The six glibc transcendentals may not be needed at all.** They were carrying
  a large share of the i960's remaining 1,921-6,921 ALM. *Caveat: absence over
  8 frames is not proof of never* — a per-race-start call would not appear here.
  Before deleting them, sample across a race start and a menu.

### What this does NOT establish, and the trap is R8

The trace shows **18,813 instructions per frame**, which at 60 fps is ~1.13 M
instructions/second — against the 12.5-16.7 M/s the study requires. **Do not
conclude the i960 only needs 1.13 M/s.**

`model2.cpp` calls **`i960_stall()`**, and the driver's own notes say the timing
*"may need wait state emulation to fix"*. The instruction *rate* is a product of
MAME's stall model, which is exactly the class of figure R8 was written about
after it produced two wrong conclusions in this document.

**The mix is reliable; the rate is not.** Which opcodes a program executes is
determined by the program. How many it executes per frame is determined by
MAME's timing model, and that model is acknowledged imperfect by its own
authors.

### The immediately actionable result — this is R9's answer

The lockstep generator emits instruction classes roughly uniformly, which is why
`T_MULDIV` was 53% of measured cycles and CPI read 15.91. **Real code is 52.9%
load/store and 0.8% FP.** Divides are enormously over-represented and memory
enormously under-represented in every CPI figure this project has produced.

**Reweight the generator to the measured mix and re-measure CPI.** That converts
throughput from a number that cannot be interpreted into one that can, and it is
the first time that has been possible. Expect it to move a long way: our memory
path is multi-cycle (`T_MEM`/`T_MEM_W`) and is currently 1.5% of the synthetic
profile against 52.9% of reality.

---

## Reweighting the generator found something worse than a bad weighting

**`make test_i960_top` FAILS. Committed that way deliberately — the bug is real
and hiding it would undo the point of finding it.**

The plan was to reweight the lockstep generator to M2-B's measured mix. It could
not be done, because of what the generator turned out not to contain.

### The whole-CPU lockstep has never executed a load or a store

The class selector is `rng() % 10` over ten classes, and **none of them emit a
MEM-format instruction**. Confirmed against the profile: **zero `T_MEM` and zero
`T_MEM_W` cycles across the entire run.**

**52.9% of real instructions — the single largest class by a factor of four —
had never been executed at CPU level.** Every "3,870 retires, 147,060 checks,
zero divergence" result this project has reported was silent about more than
half of what a Model 2 program does.

A second, smaller instance of the same thing: `cls == 41` is dead code, because
`rng() % 10` cannot produce 41. **`test<cc>` has never been generated either.**

### Fixed, and it found a defect on the first run

Added `C_LDST` (the twelve MEMA load/store forms), `C_LDA`, and revived
`test<cc>` as `C_TEST`. Weighting is now table-driven with two modes, and the
default is deliberately **not** the realistic one:

- **coverage (default)** — near-uniform. Frequency is irrelevant to a verifier:
  a rare instruction that is wrong is still wrong, and weighting by frequency
  buries it.
- **`+mix=daytona`** — M2-B's measured shares, for CPI and throughput, where
  frequency is the only thing that matters.

First run, retire 4:

```
MISMATCH retire 4  r10  got=00000009 want=000000ff  (IP 0000001c insn 80500a70)
```

`ldob r10, 0xa70` — a byte load from unmapped memory, which reads `0xffffffff`,
so the byte is `0xff`.

**Narrowed by instrumentation rather than inspection**, and the elimination is
worth keeping:

- **Data memory agrees.** Both sides' data windows are identical, so this is not
  a store divergence surfacing later.
- **The bus transaction is correct**: `RD addr=00000a70 be=1 rdata=ffffffff`.
  Right address, right byte enable, right data returned.
- **Addressing and arbitration are therefore not at fault.** The MEMA effective
  address is right and the LSU won the bus.

**So the defect sits between the bus data arriving and the register writeback —
`i960_lsu`'s extension/lane extraction, or the writeback path in `i960_top`.**
That is a small, well-bounded area to search, and the harness now reproduces it
on the first program.

Note the arbiter was read carefully and looked correct, and it *is* correct.
Inspection has produced a confident wrong answer three times today; the bus
probe settled it in one run. **Instrument earlier than feels necessary.**

### Why this matters more than the CPI number that prompted it

The reweighting was supposed to make throughput interpretable. It has instead
shown that the verification behind every result so far excluded the dominant
instruction class. **The CPI figures were not merely weighted wrongly — the
memory path they should have been dominated by was never executed at all.**

Do not reweight to `+mix=daytona` and quote a number until this defect is fixed:
a mix that is 49% load/store, run against a broken load path, measures nothing.

### Load path defect one: FIXED. The load word was read a cycle after the bus

`ld_word` is extended in `S_NEXT`, one state **after** the ack — but `rd_byte`
and `rd_half` were combinational from **`bus_rdata`**, which by then belongs to
whatever the bus is doing next, usually an instruction fetch.

**The asymmetry is what hid it.** The split/unaligned path always captured at
ack time (`assemble[...] <= rd_byte_split`); the non-split path captured
nothing. And word-sized loads read a stale `0xffffffff` often enough to look
correct, so only byte and half loads showed it.

Fixed by capturing `bus_rdata` into `rd_q` at the ack and extending from that.
`ldob` now returns `0xff` from unmapped memory as it should.

**Why it survived until today: the whole-CPU generator emitted no loads or
stores at all**, and `test_i960_lsu` drives the LSU's bus directly, so its model
holds `bus_rdata` stable across the extension state. The block harness could not
express the failure and the CPU harness never tried. *A defect that needs two
levels to see is a defect that outlives both.*

### Load path defect two: OPEN, and located

```
MISMATCH retire 12  g8  got=873bdc44 want=ffffffff  (IP 00000044 insn a0c00a34)
```

`ldt` — a three-word load from `0xa34`, all three words unmapped, so all three
should be `0xffffffff`. The **first** word is wrong, and the value looks like
real data rather than a stale bus word.

So: single-word loads are now correct, multi-word are not. The loop is
`S_NEXT -> S_XFER` advancing `cur_addr` only in a burst region, and the
suspicion is the address rather than the data, since every word at that address
reads the same `0xffffffff`. **Do not read the loop and conclude — probe
`cur_addr`, `widx` and `bus_addr` per word.** Reading the LSU carefully is
exactly what produced the wrong answer on defect one; the `[lsu]` probe found
it in a single run.

`make test_i960_top` remains FAILING, deliberately.

### Load/store: three defects fixed, one open. `make test` is GREEN (15/15)

All three were the same shape — **a value read one state after the one that
produced it** — and none was reachable before the generator learned to emit
loads and stores.

| # | defect | symptom |
|---|---|---|
| 1 | `ld_word` extended from live `bus_rdata` in `S_NEXT`, one state after the ack | `ldob` returned a later bus word; captured into `rd_q` at the ack |
| 2 | `word_idx` was the live counter, which `S_NEXT` advances in the same cycle it asserts `ld_we` | `ldt` wrote registers 1,2,2 instead of 0,1,2 — first destination never written, last written twice |
| 3 | `ra1` held fixed across `T_MEM`/`T_MEM_W` | every word of an `stl`/`stt`/`stq` stored the SAME register to consecutive addresses |

Defect 3 needed a second index on the LSU: `word_idx` is deliberately one behind
so it matches `ld_word`, while a store needs the **live** index because the
caller must present `r[base + cur_idx]` while that word is being issued. Two
indices because they answer two different questions.

Default (coverage) mix: **4,577 retires, 173,926 checks, zero divergence.**

### Open: `+mix=daytona` still diverges on the store path

```
MISMATCH retire 29  g4  got=ffffff21 want=ffffffff  (IP 000000a4 insn 90a009a8)
MEMDIFF 000009a8   dut=ffffff21 ref=ffffffff
```

`ld r20, 0x9a8` reads what the DUT itself stored there earlier and the reference
did not — so an earlier **byte store went to an address the reference did not
write**. The load is innocent; it is reporting a store that already diverged.

The coverage mix passes and the daytona mix does not, which is exactly why the
weighting exists: at 49% load/store it reaches store cases the near-uniform mix
does not. **Keep both. The realistic mix is not a replacement for the coverage
mix — it is a second axis.**

### CPI: report the coverage figure, NOT the daytona one, until this closes

| mix | CPI | dominant state |
|---|---|---|
| coverage (passing) | **13.57** | `T_MULDIV` 54.1% |
| daytona (FAILING, truncated) | 9.28 | `T_MEM_W` 48.0% |

**The 9.28 is from a run that aborts at retire 29 and must not be quoted.** What
it does show, and this part is already informative, is the shape flipping
exactly as M2-B predicted: divide-dominated becomes memory-dominated,
`T_MEM_W` at **4.46 cyc/instr**. The memory path is where the CPI is, and it was
never measured before because it was never executed.

---

## The store stream was never compared. It is now, and the suite is not green

**Correction to the previous entry.** It reported the default coverage mix as
"4,577 retires, 173,926 checks, zero divergence". That was true and misleading:
**the harness never compared the data-memory write stream**, which the exit
criteria (§7 criterion 2) explicitly require. A store to the wrong address or
with the wrong value is invisible to a register comparison unless something
later loads it back — which is exactly how the daytona divergence was first
seen, 29 retires after the store that caused it.

Added: every store the reference performs is logged in order, the DUT's bus
writes are logged in order, and the two are compared **per retire**.

It found a real defect on the default mix immediately:

```
STORE #1 retire 27  dut=00000f70:309efaf2 ref=00000f70:3ec85418  (insn a2c00f6c)
```

`stt` — store triple. **Right address, wrong value, from word 1 onward.** The
defect was always present; the previous "zero divergence" simply did not look at
stores.

### Why it is not fixed yet, and what was eliminated

Reads are registered in the caller, so `rd1` lags `ra1` by a cycle. When the LSU
issues word *N* from `S_XFER` it sees word *N-1*'s register value.

Two attempts, both measured, both wrong in opposite directions:

| attempt | word 0 | words 1+ |
|---|---|---|
| `ra1 = base + cur_idx` (committed) | correct | **wrong** |
| `ra1 = base + cur_idx + 1` | **wrong** | correct |
| `cur_idx = (S_NEXT) ? widx+1 : widx` | broke `stob` at retire 15 | — |

**A constant offset cannot work**, and that is the finding: word 0's address is
presented from `T_EXEC` and reaches `S_XFER` after a *different* delay than
every later word, which is presented from `S_NEXT`. Any fixed offset fixes one
end and breaks the other. The third attempt tried to make the announced index
state-dependent and regressed single-word stores, so the timing is subtler than
"advance one state early" too.

**The likely correct shape is for the LSU to own the value rather than the
caller** — latch `st_word` into a register when each word's address is known,
instead of reading it combinationally at issue. That removes the caller's read
latency from the critical path entirely rather than trying to compensate for it,
and it is the same move that fixed the load side (`rd_q`).

`make test_i960_top` FAILS. Left that way: the check is correct and the defect
is real, and gating either would restore a green suite that proves less than it
claims — which is what the last four findings have all been.

### FIXED, and the first real throughput number

The LSU now **waits for its operand** instead of the caller compensating for the
read latency. A new `S_OPD` state announces the index it wants and spends one
cycle letting the registered read deliver it. **Stores only** — a load has no
operand to fetch and pays nothing.

That is the move that works precisely because it removes the caller's timing
from the problem rather than modelling it. Word 0's address comes from `T_EXEC`
and later words from `S_NEXT`, so no constant offset could ever suit both; the
LSU asking and waiting is indifferent to where the address came from. Same shape
as `rd_q` on the load side.

**All 15 suites pass, with the store stream compared:**

| mix | retires | checks | result |
|---|---|---|---|
| coverage | 4,577 | 173,926 | PASS |
| **daytona** | **9,769** | **371,222** | **PASS** |

## The first interpretable throughput figure this project has had

| mix | CPI | dominant state | at 26.75 MHz |
|---|---|---|---|
| coverage (uniform, divide-heavy) | 13.65 | `T_MULDIV` 53.7% | 1.96 M instr/s |
| **daytona (M2-B measured)** | **9.49** | **`T_MEM_W` 51.6%** | **2.82 M instr/s** |

Every previous figure was measured on a mix with **no loads or stores at all**.
This one is weighted by what Daytona actually executes.

**Against the study's 12.5-16.7 M instr/s, this is 4.4x short.** Reaching 12.5 M
at today's clock needs CPI 2.14 against 9.49.

### Where the time goes, and it is one place

`T_MEM_W` is **4.90 cyc/instr averaged over all instructions**, and at 49%
load/store that is **~10 cycles per memory access**. Nothing else is close:
fetch is 2.53 combined, execute 1.00, and divide — which dominated every
previous measurement — is 0.84.

**The bus model in the harness acks every cycle**, so those ten cycles are not
memory latency. They are the LSU's own state machine: `S_IDLE -> S_OPD ->
S_XFER -> S_NEXT -> S_DONE` per word, plus `T_MEM`/`T_MEM_W` around it in the
sequencer. One of those cycles is the `S_OPD` this fix just added.

**That is the next target and it is well posed:** cut the per-access cycle count,
not the clock and not the fetch path. A 4.4x throughput gap sitting behind a
single state machine that spends ten cycles doing a one-cycle bus transaction is
a better problem to have than a diffuse one.

Note the i960KB has no data cache and neither does this design, which is
architecturally correct — so this is sequencing overhead to remove, not a cache
to add.

### The three CPI figures now on record, and which to quote

| figure | mix | status |
|---|---|---|
| 3.31 | integer-only, pre-FPU, warm cache | historical, do not quote |
| 13.65 | uniform coverage | valid for coverage, meaningless for throughput |
| **9.49** | **Daytona-measured** | **the throughput figure** |

R9 said a CPI is a property of the mix. There are now three, all correct, and
only one answers the fit question.

## Retire aligned accesses at the ack — CPI 9.49 -> 8.07

`S_NEXT` existed because the load extension happened a state after the ack. That
was the original defect; capturing into `rd_q` fixed the correctness and left
the extra state behind. Doing the work **in the ack cycle** removes the state
entirely, which is where the throughput gap lives.

`rd_byte`/`rd_half` now read the LIVE bus again — correct **here** precisely
because it is the ack cycle, which is what the first version got wrong by doing
it one state later.

The byte-split path still uses `S_NEXT`: its last byte is merged into `assemble`
by that cycle's own non-blocking write, so the assembled word is not readable
until the next cycle. Aligned accesses are the common case and now pay nothing
for it.

| | before | after |
|---|---|---|
| CPI, daytona mix | 9.49 | **8.07** |
| `T_MEM_W` | 4.90 cyc/instr (51.6%) | **3.43 (42.4%)** |
| per memory access | ~10 cycles | **~7 cycles** |
| throughput at 26.75 MHz | 2.82 M instr/s | **3.31 M instr/s** |

All 15 suites pass; daytona mix 9,769 retires / 371,222 checks with the write
stream compared.

**Still 3.8x short of 12.5 M instr/s, and still in the same place.** `T_MEM_W`
remains the largest single cost at 42.4%.

### The next cycle to remove, identified but not taken

`bus_req` is set inside `S_XFER` as a registered assignment, so the request does
not appear until the cycle *after* the state is entered — every access spends a
cycle in `S_XFER` doing nothing but raising a request. Asserting it on the
transition into `S_XFER` would remove that, **but `bus_addr` and `bus_wdata` are
registered in the same place and would have to move with it**, which is a wider
change than it looks and was not attempted at the end of a long session.

That is worth roughly one cycle per word out of seven.

## Unaligned access was never generated either; the REFERENCE was wrong

Attempting the next LSU optimisation (combinational bus outputs, CPI 8.07 ->
7.22) broke the byte-split path outright — and **the whole-CPU harness passed
it.** The block harness caught it. That is the exact reverse of the load
defects, which the block harness could not express and the CPU harness found.
**Both levels are load-bearing and neither is redundant.**

Cause: the generator emitted **word-aligned offsets only**, so the LSU's split
path — reached exclusively by unaligned byte/half/word access — was unreachable
at CPU level. Now byte-granular for the single-word forms; multi-word forms stay
aligned, since `ldl`/`ldt`/`ldq` have alignment rules of their own.

Turning it on found **two reference defects**, both the same shape, and in both
cases the RTL was right:

- **Unaligned store.** The reference replaced the whole word at `t1 & ~3` for a
  word store and used `t1 & 2` for a half — both assume alignment. `st` to
  `0xd66` wrote all four bytes of `0xd64` instead of its upper half and the
  lower half of `0xd68`.
- **Unaligned load.** It read one word at `t1 & ~3` and extracted from it, so
  `ld` from `0xb17` returned the wrong bytes: it needs one byte of `0xb14` and
  three of `0xb18`.

Both now work byte-wise, which is what MAME's memory system does with an
unaligned access.

### The store-stream check was replaced by a memory-state check

The write-stream comparison added earlier was **wrong in a way worth recording**.
An unaligned access legitimately becomes several byte transactions in the DUT
and stays one logical store in the reference, so comparing transaction counts
fails a correct implementation — it reported `dut=4 ref=1` for a single `st`.

What must agree is the **result**, so the data window is now compared **after
every retire**. Per-retire is the load-bearing part: comparing only at the end
lets a store to the wrong address be overwritten before anyone looks, which is
how the `stt` defect survived "zero divergence".

**All 15 suites pass. Coverage mix 4,577 retires; daytona mix passes.
CPI 8.69** — up from 8.07 because unaligned accesses genuinely cost more and are
now being measured instead of skipped.

### The combinational-bus optimisation: reverted, and now testable

Worth ~1 cycle per access (CPI 8.07 -> 7.22, ~10%). It breaks splitting. It was
reverted, and **the coverage that would have caught it now exists** — so the
next attempt gets an immediate verdict rather than a silent regression.

## The I-cache lever cannot be measured, and the fetch cost is an artifact

Swept `LINES` over 32, 64, 128 and 256 — **512 B to 4 KB — and got byte-identical
CPI and hit rate every time.** 7.58 CPI, 67.7% hits, 15,392 fill-wait cycles,
unchanged.

The misses are **compulsory, not capacity**. The generator emits 200
straight-line programs of 60 instructions with the cache cold at each start, so
every line is fetched exactly once and no cache of any size can help. With a
16-byte line — four instructions — 67.7% is close to the structural ceiling for
code that is executed once.

**Real code is nothing like this.** M2-B's Daytona sample executed 38,987
instructions over 4,265 distinct PCs: **9.1x average PC reuse**. The generator's
reuse is 1.0x. Loops are where an instruction cache earns its keep and the
generator has none.

### What this invalidates, including advice given an hour ago

The three-lever plan estimated "I-cache 67.7% -> 90% saves ~1.0 CPI". **That
estimate is not supportable.** The 67.7% is a property of the test workload, not
of the cache, and cannot be improved by making the cache bigger. The real hit
rate under 9.1x reuse is unknown and probably far higher — which means:

- **The fetch component of CPI 7.58 (2.66 cyc/instr, 35% of the total) is
  inflated by an artifact.** Real fetch cost is likely much lower.
- **The measured 3.53 M instr/s is therefore pessimistic**, by an unknown margin.
- **Cache sizing must not be decided on this workload.** A sweep that returns
  identical numbers for an 8x size range is not evidence that size does not
  matter; it is evidence that the workload cannot see it.

Same failure mode as R9, and the fifth instance today of a measurement that
looked meaningful and was measuring the harness: the FP check that could not
run, the M10K column that was dropped, the generator with no loads, the LSU
harness that could not express its own bug, and now a cache benchmark with no
temporal locality.

### What has to happen before the pipeline

**The generator needs loops.** Backward branches with a bounded trip count,
so instructions are executed more than once and the fetch path is exercised the
way real code exercises it. Until then:

- the fetch share of CPI is not trustworthy,
- the I-cache cannot be sized,
- and the pipeline's benefit cannot be estimated either, since its dominant
  stall is exactly the one being mismeasured.

**Do the loops before the pipeline.** Building a pipeline against a workload
that cannot see its main benefit would produce a number as uninterpretable as
the CPI figures were before M2-B.

## Loops added: CPI 7.58 -> 5.98, and the cache question is still open

`+loops` closes an unconditional backward branch over part of the program and
extends the retire budget, so instructions execute more than once. Off by
default — a loop narrows what one program covers, and the default mix exists to
cover instruction forms.

| | straight-line | `+loops` |
|---|---|---|
| prefetch hit rate | 67.7% | **83.0%** |
| CPI (daytona mix) | 7.58 | **5.98** |
| retires | 9,769 | **51,885** |
| checks | 371,222 | **1,971,630** |
| throughput at 26.73 MHz | 3.53 M instr/s | **4.47 M instr/s** |

All 15 suites pass. **The fetch cost really was inflated by the absence of
loops, and 26% of the measured CPI was an artifact of straight-line code.**

### The cache-size question is NOT answered, and the estimate remains unsupported

Swept `LINES` again with loops: 512 B, 1 KB, 2 KB, 4 KB — **still byte-identical.**
The working set at the 60-instruction default is 240 bytes and fits in the
smallest cache, so size cannot matter.

Raised the program to 1,200 instructions (4.8 KB working set, 1.2 KB loop body)
to force capacity misses, and swept 512 B / 2 KB / 8 KB. **Still identical**, and
this time the reason is NOT understood. The build was verified clean and
`LINES=512` confirmed in the source, so it is not a stale binary.

The visible clue: only **3,001 fetches against ~48,000 expected retires**, so the
long programs are trapping early and barely entering the loop. 1,200 random
instructions make an early trap near-certain. That is a *plausible* explanation
and it has not been confirmed — **do not treat it as the answer.**

**What is established, and it points the other way from the earlier estimate:**
Daytona's sample touched **4,265 distinct PCs, about 17 KB** — 34x a 512 B
cache. Real code does not fit. So the earlier claim that real code would hit
*better* than the test is unsupported, and the opposite is at least as likely:
a 512 B cache against a 17 KB working set will thrash.

**Sizing the I-cache needs a workload whose working set is real and which runs
long enough to reach steady state.** Neither condition holds yet. The honest
position is that the cache is currently unsized and unsizable with this harness,
and that the "67.7% -> 90%" estimate should be treated as withdrawn rather than
merely revised.

## Fetch/execute overlap: built, correct, and it never fires. Prefetch depth is why

Built the first real pipelining step — hand the register ports to the successor
during execute so the fetch state disappears on a prefetch hit. It **passed all
15 suites and changed CPI by nothing**: 4.96 before and after, `T_FETCH` still
1.02 cyc/instr.

Instrumented rather than assumed: **`fetch_word_ok` was false in all 50,174
execute cycles.** The overlap was never once eligible.

### One good finding, which cost nothing to prove

**No extra register read ports are needed.** The design note assumed they were
the prerequisite, because instruction N+1's read must happen while N holds both
ports. They do not, because `rd1`/`rd2` are **registered**: this instruction's
result is computed from their current values during `T_EXEC` and latched on the
same edge that loads the successor's operands. Both are correct. That removes
the item the design called "the first work item".

### The actual blocker is prefetch DEPTH

The prefetch is issued when instruction N's word lands and takes about two
cycles to arrive. A simple instruction retires in two cycles — `T_FETCH` then
`T_EXEC`. **So the prefetch lands exactly at the retire boundary**, which is
precisely why `T_FETCH` costs one cycle on a hit rather than being free. During
`T_EXEC` it has not arrived.

Compounded by a correct fix from earlier today: `pf_armed <= pf_issued` arms the
prefetch one cycle after issue, which stopped it capturing the previous demand
fetch's stale `valid`. With a one-cycle `T_EXEC`, that arming has not happened
yet either.

**Overlap therefore needs the prefetch running TWO instructions ahead, not one**
— a small queue rather than a single `pf_insn`/`pf_ip` pair. That is the real
first work item, and it is a much smaller job than adding register ports.

Reverted; the machinery was correct but dead, and dead logic costs area and
reads as working.

### Revised plan, in dependency order

1. **Two-deep prefetch queue.** Prerequisite for everything below. Small,
   contained, and independently testable via the existing hit-rate counter.
2. **Fetch/execute overlap.** Already written once and known correct — the
   condition and the post-case override can be lifted from this session's
   history. Worth ~1.0 CPI.
3. **Memory as a stage.** `T_MEM_W` is 1.64 cyc/instr, ~3.3 per access. Worth
   ~1.15 CPI.
4. Then re-measure. 4.96 - 1.0 - 1.15 ~= 2.8 CPI ~= 9.5 M instr/s, with the
   remainder from Fmax once the execute path is split.

## Two-deep prefetch: worth ~0.6 CPI, and not correct yet

Built the queue the previous entry identified as the first work item — chain a
second request the moment the first lands, so a word is in flight for N+2 while
N executes.

**The mechanism works: CPI 4.96 -> 4.36 in the run that reached the failure.**
That is ~0.6 CPI, or 5.39 -> 6.13 M instr/s, and it confirms prefetch depth was
the right diagnosis. It is **not correct**, and was reverted.

```
MISMATCH retire 39  r14  got=0000001d want=0000001a  (IP 000000d4 insn 58761019)
```

### What was fixed along the way, and is worth keeping

The first version had the front end still issuing its own prefetch for `ip+4`
while the promotion had already supplied that word. The two fought over
`fetch_addr`/`pf_ip`, and `pf_ip` ended up naming an address the promoted word
did not match — so the queue handed over the wrong instruction. Fixed by
prefetching **beyond** whatever the queue holds: `ip+8` when the deeper slot has
just been promoted, `ip+4` otherwise.

That was a real bug and the fix is right. It was not the only one.

### What is still wrong, and how to approach it

The same mismatch survives, so at least one more coherence hole remains between
the two slots and the redirect path. Candidates, in the order worth checking:

1. **Branch redirect flushes only the shallow slot.** `pf_valid` is cleared on a
   redirect but `pf2_valid` may survive with a word for the untaken path, and
   the promotion guard (`pf2_ip == ip + 4`) can be satisfied coincidentally
   after a branch lands somewhere sequential.
2. **`T_FETCH`'s own issue path** clears `pf_valid`/`pf_armed` but knows nothing
   about slot 2.
3. **The len2 path** takes the cache port for its displacement word while a slot
   2 request may be outstanding.

**Do not patch this incrementally.** Two rounds of that produced a fix that was
individually correct and still left the same symptom. The queue wants designing
as a queue — one place that owns fill, promote and flush, with the invariant
stated (slot k holds the word at `ip + 4(k+1)`, or is invalid) — rather than two
sets of registers maintained by three separate code paths.

**Estimated value confirmed at ~0.6 CPI**, which makes it worth doing properly:
4.96 -> ~4.36, and it unblocks the fetch/execute overlap already known to be
correct and worth ~1.0 more.

### Prefetch queue, second attempt: redirect flush was NOT the cause either

Rebuilt the queue as one change rather than a patch, with the invariant stated
and slot 1 flushed on every path that invalidates slot 0 — the candidate the
previous entry ranked first. **Identical mismatch, same retire, same
instruction:**

```
MISMATCH retire 39  r14  got=0000001d want=0000001a  (IP 000000d4 insn 58761019)
```

Three hypotheses eliminated now: the front end's duplicate `ip+4` issue (a real
bug, fixed, not this one), slot ordering, and redirect flushing. Reverted.

**Next attempt starts with instrumentation, not a fourth hypothesis.** That rule
has been right every time today it was followed and wrong every time it was not
— the `sqrtr` bug, the FP-register gap and the store-index bug all fell to a
probe within one run after inspection had failed repeatedly.

Concretely: dump `(ip, pf_ip, pf_valid, pf2_ip, pf2_valid, fetch_word, insn)`
per cycle for the failing program and find the cycle where `insn` is latched
from a slot whose address does not match `ip`. The whole-CPU harness already has
the ring buffer for exactly this; it needs the two extra slots added to the
trace record.

**Worth ~0.6 CPI (4.96 -> 4.36), confirmed by measurement**, so it remains the
right next item — and it unblocks the fetch/execute overlap, which is already
written, known correct, and worth ~1.0 more.

### Prefetch queue, third attempt: one more real bug found, symptom unchanged

Followed the rule and instrumented instead of guessing a fourth time. The ring
buffer, extended with both slots, showed it immediately:

```
t=3838  ts=T_FETCH  ip=000000b4 | pf 000000b4 v0   pf2 000000ac v0
t=3839  ts=T_EXEC   ip=000000b4 | pf 000000b8 v0   pf2 000000b8 v0
```

**`pf2_valid` was 0 on every cycle of the entire run.** Slot 1 never once
became valid, so the queue was never two deep and the measured 0.6 CPI gain
came from something else entirely — worth knowing before anyone trusts that
figure.

Cause: the consume path cleared `pf2_armed` unconditionally, cancelling the
in-flight deeper request on every single instruction. Clearing belongs only on a
redirect. **That is a real bug and the fix is right** — and the mismatch is
still identical, at the same retire, on the same instruction.

**Four hypotheses eliminated, three of them real bugs that needed fixing
anyway.** The instrumentation was worth it — it disproved that the queue was
working at all, which every previous measurement had implicitly assumed.

Reverted. Tree green: 15/15, CPI 4.96, both mixes, nothing uncommitted.

**Next: the same trace, but keyed on the failure rather than read at the tail.**
Print the ring only for the program that fails and widen it to cover retire 39,
then find the cycle where `insn` is latched while `pf_ip != ip`. The dump
currently shows the last 64 interesting cycles of the whole run, which is not
necessarily the failing program at all — that is why the trace above shows
healthy sequential fetching and no fault.

### Prefetch queue: the blocker is the CACHE INTERFACE, not the sequencer

Fourth attempt, and the instrumentation finally named the fault instead of
another symptom. Added a **prefetch invariant** to the harness — whenever the
front end latches a word, it must equal memory at `ip` — and it fired
immediately:

```
[PREFETCH] latched 32c34008 at ip=000000d4, memory has 58761019
           pf_ip=000000c0 v0   pf2_ip=000000c0 v0
```

**Neither slot was valid.** The word came from `T_FETCH_W` accepting `ic_valid`
— a *prefetch's* completion mistaken for the demand fetch's. `i960_icache`
returns `valid` and `data` with **no indication of which request it is
answering**. With one outstanding request that is safe by construction. With a
queue it is not: a prefetch that hits completes while a demand fetch is being
waited for, and the wait state cannot tell the two apart.

**This is an interface problem, and the sequencer cannot fix it.** Three
sequencer-level fixes were tried and all failed for the same underlying reason:

1. flush slot 1 on redirect — clearing the flag does not un-issue the request;
2. count outstanding "stray" answers and discard them — **deadlocks**, because an
   *aborted* fill never answers, so the count never clears;
3. chain the deeper request only during `T_EXEC` — narrows the window, does not
   close it, since the front end also issues prefetches.

### What the next attempt needs, concretely

**`i960_icache` must name the address its `valid` answers.** Prototyped here as
an extra `vaddr` output latched when a request is accepted, with `T_FETCH_W`
matching `ic_vaddr == ip[31:2]`. That much is right and removed the wrong-word
latching outright.

It still stalled, because a second requirement was not met: **a speculative
prefetch must never abort a demand fill.** The cache aborts on any request for a
different line — correct and load-bearing for redirects — so a prefetch issued
while a demand fill is in flight kills it and the sequencer waits forever. The
cache needs to distinguish demand from speculative requests, e.g. a `req_prio`
input where only a demand request may abort.

**Both changes are in `i960_icache`, are small, and are testable at block level**
by the redirect pass that already exists. Do them there, with the block harness,
before touching the sequencer again — the last four attempts all failed in the
sequencer for reasons that live in the cache.

**Kept: the prefetch invariant check.** It catches a wrong instruction word at
the cycle it is latched rather than dozens of retires later as a wrong register,
and it costs nothing. It is the reason this attempt produced a diagnosis rather
than a fifth hypothesis.

## Prefetch queue: three cache-interface defects found, one still open

Fifth attempt, and it produced a **complete diagnosis** rather than another
symptom. Two of the three required changes are proven; the third is a genuine
redesign of the cache's read path and is why this is not landed.

### Added to the cache, and both are correct

1. **`vaddr` — the address each `valid` answers.** With one outstanding request
   a requester may assume every valid is its own. With a queue it may not: a
   prefetch that hits completes while a demand fetch is being waited for, and
   `T_FETCH_W` latched its word as the next instruction. `vaddr` removed the
   wrong-word latching outright.
2. **`req_demand` — only a demand request may abort a fill.** The abort is
   load-bearing for redirects, but a *speculative* request that aborts kills the
   fill the sequencer is waiting on, and it waits forever. Two earlier attempts
   deadlocked on precisely this.

Both pass the block harness's redirect pass. Both are worth keeping.

### Also required, and NOT solved: the data must match the answer

`cdata_q` is registered from `rd_raddr`, and `rd_raddr` is derived from the
**live** `addr`. So the data returned follows wherever the requester has since
moved, not the request being answered. Correct while the requester holds one
address until answered — which a queue does not.

`vaddr` and `data` therefore disagree. The invariant caught it exactly:

```
[PREFETCH] latched 22600000 at ip=000000d4, memory has 5cd89617   pf_ip=000000d4 v1
```

Slot 0 held the wrong word **for its own stated address**.

Reading the array at the latched request address instead broke the ordinary
case — `req_addr_q` is registered, so a hit reads with a stale address, and the
block harness reported 856 mismatches. **The read path needs the live address at
request time and the latched one afterwards**, which is a redesign rather than a
patch, and is where the next attempt starts.

### Sequencer findings, both confirmed

- **No extra register read ports are needed.** `rd1`/`rd2` are registered, so the
  retiring instruction's result is computed from their current values and
  latched on the same edge that loads the successor's operands.
- **The harness needed a retire-ordered view, and the fix is known.** With
  overlap, retires are back-to-back, and the extra tick that let the registered
  write land also retired the successor — comparing two instructions ahead of
  the reference. Applying the pending `we`/`wa`/`wd` inside `dreg()` instead
  gives exactly the retiring instruction's state with no extra tick and no
  assumption about retire length. **That change is required before any
  pipelining lands** and is recorded here rather than in the tree, since the
  multi-cycle design still needs the extra tick.

### Kept: the prefetch invariant

Whenever the front end latches a word, it must equal memory at `ip`. Four
attempts produced four symptoms and no cause; with this, the fifth named the
cause in one run. It is in the tree, costs nothing, and passes.

**Tree green: 15/15, CPI 4.96, both mixes.**

## Prefetch queue and overlap: both now WORK, and neither is landed

Two more attempts on the corrected cache interface. Both got materially
further, and the reason neither is committed is measurement, not correctness.

### The queue is correct and it is a REGRESSION on its own

With `vaddr`, `req_demand` and the fixed read path in place, the two-deep queue
passes everything — 15/15 suites, both mixes, zero divergence, and the prefetch
invariant silent.

**CPI 4.96 -> 5.07.** Slower. The queue does not reduce `T_FETCH` by itself; it
only makes the overlap possible, and meanwhile the extra speculative traffic
costs cycles. **Committing it alone would add logic and lose CPI**, so it is
not committed. It is only worth landing together with the overlap.

One fix inside it worth keeping for next time: the chain must not be gated on
`ts == T_EXEC`. The shallow prefetch actually lands during `T_FETCH`, where it
is consumed directly, so gating on execute meant the deeper request was never
issued and slot 1 never filled. The correct gate is "not while a demand fetch
is outstanding" — `ts != T_FETCH_W && ts != T_FETCH2_W`.

### The overlap FIRES and gives CPI 4.76, with one correctness failure left

With the queue filling properly, the fetch/execute overlap engages for the
first time: **`T_FETCH` 1.02 -> 0.90 cyc/instr, CPI 4.96 -> 4.76.**

```
MISMATCH retire 23  r11  got=00000001 want=bc7f8110  (IP 00000074 insn 5819d50c)
MISMATCH retire 23  IP   got=0000007c want=00000078
```

The IP runs one instruction ahead of the reference, with a register wrong
alongside it. **The harness change is in and correct** — `dreg()` applies the
pending `we`/`wa`/`wd` instead of ticking again, which is what a design with
back-to-back retires needs — so the remaining fault is more likely in the
overlap's own bookkeeping than in the comparison.

**Prime suspect, untested:** the post-case override sets `ip <= ip_next` and
promotes the queue, but the ALU path in the case has already set `ip <= ip_next`
and, on some paths, touched the prefetch registers. Two writers to the same
state in one cycle is the shape of every bug found today. The override should
be the ONLY writer of `ip`, `pf_*` and `ts` on the overlapped path.

### Where this leaves the target

The route is no longer speculative — every step has been executed at least once
and measured:

| step | status | CPI |
|---|---|---|
| baseline | committed, green | 4.96 |
| + queue | works, regression alone | 5.07 |
| + overlap | fires, one bug | **4.76** |
| + memory as a stage | not attempted | est. ~3.6 |

The cache interface that makes all of it possible **is committed and costs
nothing** — `vaddr`, `req_demand`, and a read path that answers the request it
names rather than whatever address the requester has moved to.

### Overlap: the harness is PROVEN correct; the fault is in the overlap

Isolated it rather than guessing. With `exec_can_overlap` forced to `1'b0` and
**every other change kept** — the queue, the addressed valid, and the harness's
retire-ordered comparison — the suite **passes**.

So:

- **The harness change is correct.** Removing the extra tick and applying the
  pending `we`/`wa`/`wd` inside `dreg()` gives exactly the retiring
  instruction's state, for both the two-cycle and the back-to-back case. This
  is the change that must land before any pipelining, and it is now verified
  independently of the thing it was written for.
- **The overlap causes an extra retire.** The DUT ends up one instruction ahead
  of the reference from retire 23, which means one harness iteration advanced
  the DUT twice.

The cycle trace shows the overlap itself behaving correctly — one instruction
per cycle, `ip` 0x74 -> 0x78 -> ... — so the extra advance is at a **boundary**:
most likely the transition from a multi-cycle instruction (`T_MULDIV` at 0x70 in
the failing case) back into an overlapped sequence, where the retire that ends
the multi-cycle instruction and the first overlapped retire land in the same
harness iteration.

**Next: instrument the boundary, not the steady state.** Count overlap firings
and compare against retires — if firings + normal retires exceeds retires
counted, the double advance is proven and localised. The steady state has
already been traced and is correct, so tracing more of it will not help.

Measured value stands at CPI 4.96 -> 4.76 for the overlap, and the queue is
required for it but is a regression alone (5.07).

### Overlap: two more mechanisms eliminated, and what is left

Instrumented the boundary as the previous entry prescribed. **Neither suspected
mechanism is the cause:**

- **No double advance.** Counting DUT IP changes against harness retires shows
  exactly one per retire, every retire, up to the failure.
- **No illegal IP jump.** Every advance of 8 in a single tick is a legitimate
  taken COBR branch (`ts = T_FETCH`, overlap not firing, opcodes 0x30/0x37/0x39
  with +8 displacements). The overlap never skips an instruction.

So the DUT advances correctly and lands on the right addresses, yet by retire 23
it is executing a different instruction from the reference. **The divergence is
in WHICH instruction is executed at a correct address**, not in the address
sequence — which points at the queue delivering a stale or wrong word on a path
the prefetch invariant does not cover, rather than at the overlap's sequencing.

Note the invariant only checks words latched in `T_FETCH`/`T_FETCH_W`. **The
overlap latches `insn <= pf_insn` in `T_EXEC`, which the invariant never sees.**
That is almost certainly the gap: extend the check to the overlap path first —
it is two lines, and every previous round of this bug was solved by an
invariant, not by reading the RTL.

Ruled out and worth not re-testing: the harness (passes with the overlap
disabled and everything else in), double advances, and IP skips.

### Overlap: the fault is localised to one boundary, with an exact symptom

Extended the prefetch invariant to the overlap's `T_EXEC` latch, as the previous
entry prescribed. **It does not fire** — the instruction words the overlap
latches are correct. Also added forwarding for the in-flight write (a genuine
RAW hazard: the successor's operands are read while the current instruction is
still executing, so `we`/`wa`/`wd` describe the *previous* write). **That did
not fix it either**, though the forwarding is correct and needed regardless.

A retire-by-retire IP log of both sides then gave the exact symptom:

```
r22   dut=00000074 ref=00000074  insn=6770c806        FP op at 0x70
r23   dut=0000007c ref=00000078  insn=5819d50c   <== DIVERGED
```

**The DUT advances 0x74 -> 0x7c: eight bytes for a four-byte REG instruction.**
Not a skipped instruction and not a wrong word — an `ip` that moves twice as far
as it should, once.

**The boundary is `T_FP` -> `T_FETCH` -> `T_EXEC(overlap)`.** The preceding
instruction is FP, which `exec_can_overlap` excludes, so the overlap fires on
the *first* instruction after a multi-cycle one. That is the untested
transition: every other path into the overlap comes from another overlapped
instruction or from a plain fetch.

**Prime suspect: `ip_next` is already advanced when the overlap reads it.** The
override does `ip <= ip_next; ip_next <= ip_next + 4`, which is correct only if
`ip_next` still describes *this* instruction's successor. Coming out of a
multi-cycle state, some path appears to have advanced `ip_next` already, so the
overlap lands one instruction too far. Check who writes `ip_next` on the
`T_FP`/`T_MULDIV` retire paths and on the fetch that follows.

**Ruled out and not worth re-testing:** the harness (passes with the overlap
disabled and everything else in), double advances in the steady state, wrong
instruction words on either latch path, and the RAW hazard.

### Prefetch queue: STOP. Read this before the next attempt.

Six attempts. The cache-interface work that came out of it is committed and
correct. **The queue itself is not landed, and the last two rounds produced
contradictory readings, which means the instrumentation was misleading rather
than converging.**

**A real harness bug wasted most of a round, and it is the important lesson.**
The retire loop still contained the extra `tick()` — the one that lets a
registered write land, correct for a two-cycle retire and *wrong* with
back-to-back retires, where it retires the successor too. It had been correctly
removed earlier, lost in a revert, and my re-removal targeted text
(`ip_at_retire`) that no longer existed, so it **silently did nothing**. Every
overlap measurement after that point was taken with the harness double-stepping.

That invalidated a conclusion recorded in this file: the "fault localised to the
`T_FP` -> overlap boundary, `ip` advancing 8 bytes" was **my harness stepping
twice**, not the design. Do not chase it.

**Where the contradiction stands.** With the tick removed and both the queue and
overlap in, the *latch* invariant fires (a wrong word handed over at `ip`) while
the *slot* invariant — same signals, same cycle, checked immediately before —
stays silent. Both cannot be true. One of the two checks is wrong, and finding
which is the first task, before any RTL is touched.

**Rules for the next attempt, earned expensively:**

1. **Verify every harness edit applied.** Three separate `replace` calls this
   session silently matched nothing after a revert changed the surrounding text.
   Assert on the pattern, or diff afterwards.
2. **Gate every invariant on "a program is running."** `mem` is rebuilt per
   program, so a check that runs during reset compares the new program's memory
   against the previous program's queue and reports a defect that is not one.
   Two invariants failed this way and cost a round each.
3. **Reconcile the two invariants before trusting either.** They disagree today.
4. Do not re-test: the RAW hazard (forwarding added, correct, not the cause),
   wrong words on the overlap's `T_EXEC` latch (checked, clean), and steady-state
   double advances (measured, one per retire).

**Value, still measured and still worth it:** overlap CPI 4.96 -> 4.76, queue
required for it but a regression alone at 5.07. That is ~1.0 CPI of the 2.8 CPI
needed to reach 12.5 M instr/s.

**Honest position:** this feature has consumed more of a session than it has
returned. The memory stage — `T_MEM_W` at 1.64 cyc/instr, ~33% of CPI, estimated
~1.15 CPI — is worth comparable throughput, is independent of all of this, and
has none of the accumulated confusion. **Consider doing that first.**

## Memory path: request issued during execute — CPI 4.96 -> 4.51

`lsu_req` was registered, so the LSU did not see the request until the first
`T_MEM_W` cycle. That cycle was spent **merely accepting** it — one of the three
a load costs, against a bus that acks immediately. Driving it combinationally
from `T_EXEC` puts the LSU in its transfer state by the time `T_MEM_W` begins.

Its inputs are ready throughout execute: `ea` is combinational from the AGU,
the `ls_*` controls from `i960_ldst`. Stores gain nothing — they still wait in
`S_OPD` for the register value — and lose nothing.

| | before | after |
|---|---|---|
| `T_MEM_W` | 1.64 cyc/instr (33%) | **1.19 (26.3%)** |
| CPI | 4.96 | **4.51** |
| Fmax | 26.73 | **27.78** |
| ALM | 7,227 | 7,238 (+11) |
| **throughput** | 5.39 M instr/s | **6.16 M instr/s** |

**Chosen over the LSU-side fast-issue path**, which was attempted twice and
failed both times — the second stalling the block harness with no clear cause.
This saves the same cycle without touching the state machine three defects were
recently fixed in. *When two routes reach the same cycle, prefer the one that
does not modify the component with recent history.*

Fmax rose rather than fell, so the added combinational path is not on the
critical one; the gain is most likely the cache-interface work landing.

### Standing position

**6.16 M instr/s against 12.5 M — a 2.03x gap**, from 4.4x at the start of the
session. Area 7,238 ALM against a 12K pass band, M10K 1 of 553.

Remaining measured levers, in order of confidence:

| lever | worth | state |
|---|---|---|
| fetch/execute overlap | ~1.0 CPI | works, blocked on prefetch queue — **see the STOP note** |
| memory as a full stage | ~0.6 CPI left | `T_MEM_W` still 1.19; the store path still pays `S_OPD` |
| I-cache miss cost | 0.49 cyc/instr | 82.5% hit rate; unsized, and unsizable on this workload |

## Memory retire and divide latency — CPI 4.51 -> 3.91

**Retire in the ack cycle.** `done` and `ld_we` were registered, so the
sequencer spent a whole cycle merely *noticing* an access had finished. The LSU
now also exposes `ld_we_now`/`ld_word_now`/`done_now` — the same retire known
combinationally in the ack cycle — and `T_MEM_W` acts on those. The registered
forms remain for the byte-split path, which retires a state later out of
`assemble` and cannot be known early.

**`T_MEM_W` 1.19 -> 0.74 cyc/instr.** Fmax 27.78 -> 26.67, and the net is still
positive: 6.16 -> 6.54 M instr/s.

**Divide ran at double length.** The restoring divider always took 64
iterations. `shifted` takes `quot[63]`, and a 32-bit dividend sat in the LOW
half of `dvd_mag` — so the first 32 iterations shifted out zeros and produced
zero quotient bits. Half the latency of every ordinary divide, wasted, on a
state that was **17.6% of all cycles for about 1% of instructions**.

A 32-bit dividend now goes in the high half and runs 32 steps; `ediv` keeps 64.
**`T_MULDIV` 0.72 -> 0.55 cyc/instr** — less than half, because multiplies share
the state.

### Position

```
i960_top   7,137 ALM   1 M10K   7 DSP   Fmax 26.76
CPI 3.91   ->  6.84 M instr/s   against 12.5 M   =  1.83x gap
session:   2.82 -> 6.84 M instr/s
```

Profile now, and the shape has changed completely from this morning:

```
T_FETCH    1.02   26%   <- the overlap's target
T_EXEC     1.00   26%   <- the overlap's target
T_MEM_W    0.74   19%   was 1.64
T_MULDIV   0.55   14%   was 0.84
T_FETCH_W  0.51   13%
```

**Fetch plus execute is now 52% of all cycles**, and collapsing them is exactly
what the fetch/execute overlap does — worth ~1.0 CPI, which alone would give
~9.1 M instr/s. It remains blocked on the prefetch queue; see the STOP note and
its four rules before attempting it again.

### A shorter route to the overlap, and where it still fails

The two-deep prefetch queue existed **only** to get a word into `T_EXEC`. There
is a cheaper way to the same place: **issue the prefetch combinationally, in the
cycle the current word lands, instead of registering it into the next.** That
buys one cycle of cache latency, so the answer arrives *during* `T_EXEC` rather
than at the retire boundary — no second slot, no promotion, no flush rules.

It works and is correct: `ic_req_eff = ic_req || pf_req_now`, address
`ip + 4`, `req_demand` low so a speculative request can never abort a demand
fill. **All 15 suites pass with it in.**

**On its own it is worth 0.02 CPI (3.91 -> 3.89)** — nothing, because it does
not remove a state. It is purely an enabler, so it was not kept: it adds
combinational paths to the cache request for no standalone gain.

**With the overlap on top, a wrong word still reaches the front end**, always at
the same address:

```
[PREFETCH] latched 22600000 at ip=000000d4, memory has 5cd89617   pf_ip=000000d4 v1
```

`pf_valid` is set and `pf_ip` matches `ip`, so `pf_insn` itself is wrong —
captured for the right address with the wrong data. Address-qualifying the
capture against `ic_vaddr` did **not** fix it, and the early prefetch alone does
not provoke it, so it is specific to the overlap's own re-arm path
(`pf_ip <= ip_next + 4`, `pf_issued`, `ic_req` in the post-case override).

**Next, and it is one experiment rather than a hypothesis:** the queue invariant
(every valid slot holds the word its address claims, checked every cycle,
gated on a running program) tells you the cycle `pf_insn` goes wrong. That check
exists in this file's history and was never run against *this* configuration —
only against the queue. Run it here first.

**Overlap value is unchanged and still the largest single lever: ~1.0 CPI**, with
`T_FETCH` + `T_EXEC` now 52% of all cycles.

### Overlap round 7: a DUPLICATED invariant was manufacturing the failures

The single most useful finding of this round is about the harness, not the RTL.

**`tb_i960_top.cpp` contained TWO copies of the prefetch invariant.** One gated
on a running program, one not. The ungated copy fired during reset — comparing
the new program's memory against a word left over from the previous program —
and every edit made to "the check" went to the *other* copy, so the probes never
changed what was printed.

**Several rounds of this bug were chasing a check that was reporting a defect
that did not exist.** The `[PREFETCH] latched ... at ip=000000d4` failure,
recorded twice in this file as a real symptom, was that duplicate.

With the duplicate removed, both invariants go silent and a **different, real**
failure appears at retire 1 on a `movl` — which the duplicate had been masking
by failing first every run.

**Rules, extending the four already recorded:**

5. **Grep for duplicates before trusting an invariant.** `grep -c` on the
   comment banner would have caught this in one command, and was not run for
   several rounds.
6. **A probe that does not change its output when edited is not being run.**
   That signal appeared twice and was read as "the bug is elsewhere" rather than
   "the edit did not take".

### The shorter route is real and is worth keeping in mind

Also established this round, and independent of the bug: the two-deep prefetch
queue is **not needed**. Issuing the prefetch combinationally in the cycle the
current word lands buys the same cycle of latency, so the successor's word
arrives during `T_EXEC` with no second slot, no promotion and no flush rules.
Six attempts at the queue; the goal was reachable without it.

That variant passes all 15 suites on its own and is worth 0.02 CPI without the
overlap, so it is only worth landing together with it.

**Overlap value unchanged: ~1.0 CPI, the largest single lever, with
`T_FETCH` + `T_EXEC` at 52% of cycles.** Next session starts from the retire-1
`movl` failure, which is the first *real* symptom this feature has produced.

### Correction: the duplicate did NOT manufacture the failure

The previous entry claimed a duplicated prefetch invariant was reporting a
defect that did not exist. **That was wrong and is retracted.**

The two copies were identical except that the second did not increment `fails`,
so it only ever **double-printed**. Neither fires spuriously during reset —
both require `fetch_word_ok`, which requires a valid prefetch, and there is none
during reset.

What actually suppressed the failure was a `checking` gate added in the same
round whose anchor line did not match, so `checking` never became true and the
invariant was silenced entirely. Removing a real check and calling the symptom
an artifact is the more embarrassing of the two mistakes, and it is exactly what
rule 1 (verify the edit applied) exists to prevent.

**The `[PREFETCH] latched ... at ip=000000d4` failure is REAL.** It is the
overlap's first genuine symptom and remains the place to start.

The duplicate is removed anyway — it is committed, it doubled every message, and
one invariant is easier to reason about than two.

### Where the overlap stands after round 7

Three distinct defects are now known on this path, in order of discovery:

1. **Demand must win the cache address mux.** `ic_addr_eff` was
   `pf_req_now ? pf_req_addr : fetch_addr`, which serviced a *demand* request at
   the prefetch's address whenever both fired. Fixed to `ic_req ? fetch_addr :
   pf_req_addr`.
2. **The prefetch capture must be address-qualified**, since the overlap issues
   its own requests and more than one answer is in flight. Applied.
3. **OPEN: `ic_data` and `ic_vaddr` disagree under the combinational request.**
   With (1) and (2) both in, the capture still stores a wrong word for an
   address that matches `ic_vaddr` — so the cache is naming one address and
   returning another's data. Prime suspect is the `S_FILL` "same line adopts the
   fill" rule, which sets `req_addr_q <= addr` for *any* same-line request
   including a speculative one, so a prefetch can rename the answer a demand
   fill is about to deliver. That rule was added for a redirect-within-a-line
   case and predates speculative requests existing.

**Fix (3) in the cache, at block level, before touching the sequencer again** —
the same lesson as rounds 1-4, where four sequencer fixes failed for a reason
that lived in the cache.

### Round 8: the cache is EXONERATED; the fault is the capture/pf_ip ordering

Two things established, both by measurement rather than reading.

**1. Same-line fill adoption is now demand-only.** The `S_FILL` rule that lets a
request for the line being filled become the request the `valid` answers applied
to *any* request, including a speculative one — so a prefetch could rename an
answer a demand fetch was waiting for. Restricted to `req_demand`. **Committed:
block harness clean, whole-CPU clean, no behaviour change to the current
design.** It was not the overlap's bug, but it is a latent one that only a
speculative requester can reach.

**2. The cache is consistent, and this is now checked.** A new invariant asserts
the cache's contract directly: **whenever `valid` is high, `data` must be the
word at `vaddr`.** It stays silent across the whole run with the overlap in.

That matters because two rounds could not tell "the cache answers
inconsistently" from "the front end captures the wrong answer" using only the
consuming end. Now they are separated, and **the cache is exonerated.**

### The remaining fault, stated precisely

`pf_insn` is captured from `ic_data` when `ic_vaddr == pf_ip`, **while the front
end updates `pf_ip` in the same cycle**:

```
capture (before the case):  if (pf_armed && ic_valid && ic_vaddr == pf_ip)
                                pf_insn <= ic_data;   // matches the OLD pf_ip
front end (in the case):        pf_ip   <= ip + 4;    // pf_ip becomes something else
```

Both are non-blocking, so `pf_insn` ends up describing the address `pf_ip` held
*before* the update, while `pf_ip` names a different one. The slot is then
internally inconsistent — exactly what the invariant reports.

In the current design this is harmless because every path that updates `pf_ip`
also clears `pf_valid`, so the inconsistent slot is never consumed. **The
overlap adds a path where it is not cleared**, and the stale word is handed over
as an instruction.

**The fix is to make one place own the slot**: `pf_ip`, `pf_insn` and `pf_valid`
should be written together or not at all. Do not add another guard to the
capture — that has been tried twice and treats the symptom.

**Value unchanged: ~1.0 CPI, the largest remaining lever, `T_FETCH` + `T_EXEC`
at 52% of cycles.**

### Round 9: the corruption is IN THE CACHE ARRAY, not the front end

Made the prefetch slot atomic — `pf_ip`, `pf_insn` and `pf_valid` written only
together, with `pf_req_ip` holding the address a prefetch was *issued* for. That
is the right structure and it passes the baseline unchanged (15/15, CPI 3.91),
but **it did not fix the overlap**, which finally localised the fault.

Printing the whole slot at the failure:

```
latched 22600000 at ip=000000d4, mem 5cd89617
  pf_insn=22600000 pf_ip=000000d4 v1 armed=0 req_ip=000000d4
  icv=0 icva=000000d4 icd=22600000
```

`ic_data` is **22600000 for `ic_vaddr` = 0xd4**, while memory holds `5cd89617`.
**The cache is returning the wrong word for that address** — the slot faithfully
captured what the cache gave it. The front end, the capture and the slot are all
correct.

**Why the cache check missed it:** it is gated on `ic_valid`, so it samples only
the cycles the cache is answering. A corrupted *line sitting in the array* is
invisible to it between answers. Extend it to check `data` against memory
whenever `vaddr` names a mapped address, not only when `valid` is high.

**Prime suspect: a line marked valid with partial data.** `cvalid[idx]` is
cleared at fill start and set at completion, which is correct for an abandoned
fill — but speculative requests now arrive during fills, and the `S_DONE` path
starts a new fill on `req && !hit` without re-checking who owns the line. A
speculative miss landing there can begin a fill that a later demand adopts.

**This is the first round that puts the defect inside `i960_icache` with
evidence rather than suspicion**, and it is the fourth time this feature's fault
has turned out to live one level below where it showed. Fix it at block level:
add a directed test that issues speculative requests during a fill and then
reads the filled line back.

Round 9 changes were reverted; the atomic slot is worth re-applying when the
cache is fixed, since it is correct and costs nothing.

### Round 10: correction — the cache is NOT proven corrupt, and speculation is safe

**Retraction.** Round 9 concluded "the cache returns the wrong word for 0xd4"
from this line:

```
icv=0  icva=000000d4  icd=22600000
```

**`icv` is 0.** The cache was not answering, so `ic_data` was merely the array's
last registered read and carries no claim about correctness. Concluding cache
corruption from a signal sampled while its qualifier is low is the same error as
reading a bus during a cycle nobody acked — and it is the third over-conclusion
on this feature.

**What is now genuinely established**, by a directed block-level test rather
than inference: `spec_during_fill()` issues a speculative request in the middle
of a demand fill, at every point in it, against lines that do and do not alias
the one being filled, then reads back every word of the filled line.
**All pass.** So speculative traffic during a fill does *not* corrupt the line,
does not abort the fill, and does not rename its answer.

That test is committed and is a permanent coverage addition — the harness had no
way to express speculative traffic before, which is precisely the traffic a
prefetching front end generates.

**So the overlap's fault is still not located.** What is known:

- the slot is atomic and still ends up holding a wrong word for its own address;
- the capture check (word vs memory at capture time) is silent;
- the cache contract check (valid implies data == memory[vaddr]) is silent;
- speculative-during-fill is now proven safe at block level.

**Next, and it must be a check that cannot be silent for the wrong reason:**
sample `pf_insn`/`pf_ip` on *every* cycle they change, log the writing path, and
diff against memory. Every check so far has sampled a condition; this needs to
sample a *transition*. Three of this feature's rounds have been lost to a check
that was silent because it was disabled, duplicated, or gated on a signal that
was low.

## Fetch/execute overlap: RESOLVED, and the answer is that it does not pay

After ten rounds, both questions are answered.

### It was never broken. The check was.

The failure that survived nine rounds was a **cross-program artifact**. `mem` is
rebuilt before the DUT is reset, so during those reset cycles the prefetch slot
still holds the *previous* program's word and the invariant compared it against
the *new* program's memory. Gated on a running program, **the overlap passes
everything**: 4,501 retires, 171,038 checks, zero divergence, all 15 suites.

The slot-transition log is what settled it — logging every change of
`pf_insn`/`pf_ip` with the memory truth showed the same address holding two
different values at two times, with **no bus write between them**. Memory had
not changed; it had been *replaced*.

**The gate is now committed, and it prints how many times it armed.** A gate
that silently never arms turned a real symptom into an apparent artifact once
already; a counter makes that impossible to miss.

### And measured, it is a regression

| | baseline | with overlap |
|---|---|---|
| `T_FETCH` | 1.02 | **0.84** |
| `T_FETCH_W` | 0.51 | **0.79** |
| CPI | **3.91** | 4.02 |

The overlap does exactly what it was designed to do — it removes 0.18 cyc/instr
of fetch state — and **costs 0.29 in fill waits.** The instructions it
short-circuits are the ones already in cache, so what still reaches `T_FETCH` is
disproportionately a miss. Making speculative misses drop instead of fill
changed nothing (0.80 vs 0.79), so it is selection, not wasted fills.

**~1.0 CPI was the estimate. Measured, it is −0.11.** The estimate assumed
removing a state removes its cycles; it moves them.

### What is kept

- **The invariant gate**, with its arm counter.
- **`spec_during_fill()`** in the cache harness — speculative traffic during a
  fill, proven safe.
- **Demand-only same-line fill adoption** in the cache.
- Recorded, not kept: the atomic prefetch slot and the combinational prefetch
  request are both correct and cost nothing; they are only worth applying if
  something later needs a word during execute.

**The remaining gap is not in fetch.** With the overlap eliminated as a lever,
CPI 3.91 = **6.84 M instr/s against 12.5 M**, and the next-largest items are
`T_EXEC` at 1.00 (irreducible without a real pipeline) and `T_FETCH_W` at 0.51
(I-cache misses, unsizable on this workload).

### Critical-word-first: third attempt, third failure, and a pattern worth naming

The miss penalty is the right target — a miss costs ~5 cycles (four words plus
a done cycle) before the requested word is available, and in a pipelined design
it stalls the whole pipe rather than one state.

Third attempt, reverted like the first two. The block harness caught every step
immediately, which is the system working:

1. Suppressing the completion `valid` once the critical word is delivered
   **stalls a same-line request** — that request was never answered, because the
   early delivery consumed the answer meant for the earlier one.
2. Clearing `fill_early` for such a request answers it but **breaks the
   redirect cases**, which then take the early path they should not.
3. The sequential miss rate reads 0.25 -> 0.33 -> 0.50 across the attempts, and
   part of that is a harness artifact: the counter treats "saw `bus_req` while
   waiting" as a miss, and with a line still filling behind an early delivery it
   sees one on hits too.

**The pattern across all three attempts is the same**: `valid` is a single
undifferentiated answer, and critical-word-first creates a state where *some*
requests have been answered and others have not. The cache cannot express that.
`vaddr` was added for exactly this class of problem and is not sufficient — it
says which address an answer is for, not whether a given requester is still
owed one.

**What a fourth attempt needs, and it is a design change rather than a patch:**
an outstanding-request record — who asked, for what, and whether they have been
answered — so early delivery can satisfy one requester without silently
consuming another's answer. That is the same conclusion the prefetch queue work
reached from the other direction, and it is now reached twice independently.

**Also required first: fix the harness's miss counter.** "Saw `bus_req` while
waiting" is not a miss once fills continue behind delivered words, and no
version of this change can be evaluated while the metric moves with the
mechanism.

## Fmax: the design is limited by a FAMILY of paths, not one

Throughput is Fmax / CPI, and a whole session went into CPI while Fmax sat at
26.76 MHz with the critical path unchanged since morning: `rd1 -> wd`, register
read through the ALU and result muxing into writeback.

**Tested the obvious cut.** A second execute stage latches the ALU result, so
`rd1 -> ALU -> mux -> wd` becomes two halves. All 15 suites pass.

| | CPI | Fmax | throughput |
|---|---|---|---|
| baseline | 3.91 | 26.76 | **6.84 M instr/s** |
| split execute | 4.12 | 27.20 | 6.60 M instr/s |

**It costs 0.21 CPI and buys 1.6% of Fmax.** Break-even needed 28.2 MHz. A
regression, and reverted.

### Why, and this is the useful part

With the ALU path cut, the critical path became **`insn[11] -> wd`** — a
*different* path of almost the same length, running from the instruction
register through decode and operand select into writeback. Slack 2.628 -> 3.232;
the limit moved rather than lifted.

**So the design is not limited by one long path. It is limited by a family of
comparable paths that all begin at a register feeding decode/execute and all end
at `wd`.** Cutting one promotes the next. That is why:

- registering the register-file read (this morning) bought 8%, not the "large"
  the backlog predicted;
- splitting the execute datapath buys 1.6%;
- and any further single-path surgery will buy about as little.

**Fmax needs a stage boundary that ALL of these paths cross, which is what a
pipeline is** — not a targeted cut. Piecemeal Fmax work is now measured, twice,
as not paying.

### What that means for the remaining 1.83x

Both halves of `throughput = Fmax / CPI` now have the same answer:

- **CPI**: `T_EXEC` at 1.00 is irreducible without overlapping stages; the fetch
  levers need the cache's outstanding-request record; everything cheap is done.
- **Fmax**: limited by a family of paths, liftable only by a real stage
  boundary.

**Both roads lead to the same place, and it is a genuine pipeline.** The
incremental route returned +143% this session (2.82 -> 6.84 M instr/s) and is
now exhausted -- every remaining lever has been measured and each is worth
under 2%, negative, or blocked on the same missing cache abstraction.

## Fmax: three stage boundaries measured, none pays. The delay is INSIDE the units

| configuration | CPI | Fmax | throughput |
|---|---|---|---|
| baseline | 3.91 | 26.76 | **6.84 M instr/s** |
| + X/W boundary (ALU result registered) | 4.12 | 27.20 | 6.60 |
| + D/X boundary (decode registered) | 3.91 | 26.54 | 6.79 |
| + both | 4.12 | 26.60 | 6.46 |

**Every cut moves the limit rather than lifting it**, and the path report says
why each time:

- baseline: `rd1 -> wd`
- with X/W cut: `insn[11] -> wd` — a different path, nearly as long
- with both: **back to `rd1 -> wd`**, slack 2.628 -> 2.409

`rd1` feeds the ALU *and* the AGU, and both end at `wd` — `lda` writes
`wd <= ea`. Registering the ALU's output simply promotes the AGU's path. There
is a **plateau** of comparable paths, all of the form
`register -> one functional unit -> wd`.

### The conclusion, and it is well evidenced now

**A stage boundary cannot lift Fmax here, because the delay is inside the
functional units rather than between them.** Cutting at a unit's output leaves
`rd1 -> unit`, which the X/W experiment showed is most of the delay: registering
the ALU output bought 1.6%.

So a universal writeback stage — every unit's result through one register —
would cost ~1.0 CPI (break-even needs Fmax > 33.6 MHz) and, by the same
measurement, would not get there.

**Fmax work means making the units shallower**, which is backlog item 2 (share
the ALU datapath: 973 ALM, six shift forms, four comparators and three adders
described separately) and its equivalent for the AGU. That reduces logic depth
without costing a cycle, and it is the only remaining lever that is not blocked.

**What is now measured rather than assumed:** the pipeline the spike document
has called for since the beginning would *not*, on its own, fix Fmax on this
design. It would fix CPI. Those are different problems here, and only one of
them has a structural answer.

## THE THROUGHPUT REQUIREMENT IS MET. It was met before this session started.

Measured, not inferred: **Daytona's i960 executes ~15,400 instructions of work
per frame = 0.93 M instr/s. The core delivers 6.86 M instr/s. 7.4x margin.**

| frame | instructions | in a spin loop | distinct PCs | hottest PC |
|---|---|---|---|---|
| 1 | 14,469 | 14 (0.1%) | 4,201 | 0.4% |
| 2 | 14,474 | 14 (0.1%) | 4,207 | 0.4% |
| 3 | 17,441 | 14 (0.1%) | 4,159 | 0.5% |

Three single-frame traces of `daytona93` under MAME 0.289. The work is genuine
and distributed — 4,200 distinct PCs per frame, hottest 0.4%, **0.1% spinning**
— so this is not a CPU idling against a slow emulator.

**The 12.5-16.7 M instr/s figure was the chip's capability, never the game's
demand.** A 25 MHz i960KB at 1.5-2 CPI delivers that. Nothing ever measured what
Model 2 software needs.

### Why this survives R8

R8 warns that MAME's cycle counts are estimates and `model2.cpp` calls
`i960_stall()`. **This measurement does not use MAME's cycle model.** It counts
instructions between *frame boundaries*, and the frame boundary comes from video
hardware. The remaining objection — MAME starving the CPU so it never finishes
its per-frame work — is answered three ways: the game renders correctly
(screenshot), the per-frame count is **stable across frames**, meaning a fixed
workload rather than work-until-vblank, and there is almost no spinning.

### What this changes

- **P1's throughput exit criterion is met**, with margin. The pipeline that §4.3
  has demanded since the beginning is **not required for Model 2**. It would be
  required to match the real chip, which nobody asked for.
- **The remaining i960 work is functional**: faults, `synmov`/`synmovq`,
  `calls`, `modpc`, interrupts, the `rl` forms. M2-B already suggested the six
  transcendentals may be unnecessary.
- **Area, not speed, is what the fit question needs from this core** — and at
  6,986 ALM against a 12K band it has been comfortable throughout.

### The lesson, and it is the third instance

A full session went into throughput. Every step was real — 2.82 -> 6.86 M
instr/s, six defects fixed, seven coverage holes closed — but **the target was
never verified**. R9 was a CPI quoted without its instruction mix; this is a
throughput target quoted without its workload. The measurement that settles it
took hours and could have been done first.

**Before optimising against a number, establish what measured it.**

## The i960's remaining work is ONE instruction, not thirty-four

Cross-referenced 196,885 instructions of Daytona traces against what the design
implements. **80 distinct mnemonics executed; exactly one is missing:**

```
callx    513    0.261%
```

Every other mnemonic the game uses is built. The coverage figure of "129 of 163"
counts the *architecture*; against the *workload* it is 79 of 80.

**That reframes the remaining i960 work completely.** The 34 unimplemented
mnemonics are not 34 tasks — they are one task plus a list of things Daytona
never executes. The six glibc transcendentals, the `rl` forms and `remr` do not
appear at all, consistent with M2-B finding zero transcendentals.

*Caveat, and it is real:* one game, in attract mode running a full demo race.
Interactive play adds input handling. Other Model 2 titles may use more. But as
a scoping measurement it is far better than building all 34 and discovering
which are dead.

### callx: implemented, and NOT yet correct

`callx` is MEM format — compute the effective address, then call it. Both halves
already existed: the AGU produces `ea`, `call_target` is already wired to
`alu_or_ea` which selects `ea` for MEM format, and the frame machinery is the
same one `call` uses. Joining them is a few lines in `i960_ldst`, the sequencer,
and both references.

Done, and it diverges:

```
MISMATCH retire 43  g15  got=00000009 want=9d3d02c0   (later instruction)
```

`g15` is FP, and `FP = (SP + 63) & ~63` is always 64-aligned — `9` is not a
frame pointer. **The reference performs the call and the DUT does not**, with
the divergence surfacing later on an unrelated instruction.

Verified present and therefore NOT the cause: `8'h86` decodes in `i960_ldst`
with `no_mem`, the sequencer's `d_op == 8'h86` branch exists, `0x86` is MEM
format, and `lsu_req` correctly stays low for it.

Worth checking next: whether the DUT reaches `T_FRAME` at all for `callx`
(count entries with and without it generated), and whether `agu_valid` holds for
its addressing mode. Reverted rather than committed -- an implementation the
harness has not verified is the same as no implementation.

One generator note worth keeping: `callx`'s address is a **call target**, so it
must point at code. Aimed into the data window it calls unwritten memory and
executes `0xffffffff`, which tests the trap path instead of the call.

### FIRST HARDWARE RUN: video path CONFIRMED, ROM readback does NOT match

Photographed on a DE10-Nano, loaded via the MRA (so a real ROM was streamed).

**Confirmed working on silicon:** magic `B0ADCAFE`, frame counter running,
`pll_locked` + `mem_ready` + `rom_loaded` all set, bar order R,G,B,C,M,Y,W,grey
correct, border present on all edges, corner marker, marching block visible. **The
framework, PLL, video timing, clock enables and the whole video path are proven on
hardware, not just in simulation.**

**Three defects, all found by the overlay, none in the design under test:**

1. `word2 = 1A7`, `word3 = 1EF` — off by one against MAME's `1A8`/`1F0`. **Both
   mine, both in the counters**, not the timing module (which sim asserts against
   MAME and passes). Same cause in each: reset and increment fired on the *same*
   edge — `hcnt==0` is a visible pixel, and the frame boundary lands on a line
   boundary — so the later non-blocking assignment won and the item being closed
   was never counted. **Third instrument bug this session.**
2. The status word was `{27'd0, ...}` = **31 bits, not 32**. A short field in a
   concatenation does not warn, it silently reindexes: every word above it shifted
   by one bit, which is why word4 read `80000007` with `rb_w0`'s LSB bleeding into
   its top bit. Decoding the photo required un-shifting by hand.
3. **Address 0 was a useless probe.** The i960 ROM legitimately begins
   `00000000`, so a correct read and a dead read are indistinguishable. Probes are
   now chosen for signature value.

**The open question, and it is a real one.** Un-shifting the photo gives
`rb_w0 = 000000FF`, `rb_w1 = 000000FF`. The ROM says they should have been
`00000000` and `000000C0`. **Neither matches, and both reads returned the same
value** — so the ROM path is not yet proven and may be broken.

Candidates, in the order worth testing:

- **SDRAM read capture phase.** The OSD option exists for exactly this; Model 1's
  board needed CL+2 because the real device answers half a period away from the
  simulation model. Cycle it and watch the two words.
- Loader address mapping — where `ioctl_addr` lands in SDRAM.
- Byte lane or interleave orientation.

**Next build is ready** (`build/release/Model2.rbf`, timing clean, 7,738 ALM) with
all three defects fixed and probes reading:

| word | address | **expected** |
|---|---|---|
| 5 | word 8 | **`FFFFF6E0`** |
| 6 | word 4, upper half | **`00000860`** |

Both signatures come from the interleaved stream the MRA builds. If they read
correctly, the ROM path is proven end to end. If they read shifted, the capture
phase is the cause and the OSD option is the fix.

### `make release` gathers the flashable files

```
build/release/Model2.rbf                          <- launch this directly today
build/release/_Arcade/Daytona USA (Deluxe 93).mra
build/release/_Arcade/cores/Model2.rbf
```

`output_files/` is git-ignored, as build folders are, and `mra/` is tracked — a
file describing a ROM layout is fine, the bytes are not. Nothing gathered the two
until now.

**For the board today: copy `Model2.rbf` to `/media/fat/_Other/` and run it.**
Steps 1-3 need no ROM. `_Arcade/cores` is not browsed directly; those launch via
their `.mra`, which is not usable yet — the loader has no consumer and the full
set is 43.62 MB against the 32 MB the controller addresses.

**What to read off the screen:** `word2 = 000001A8` and `word3 = 000001F0`. Those
are MAME's `set_raw` numbers, already asserted in simulation — silicon agreeing is
a separate claim.

### P1.5 step 3 WIRED: SDRAM + ROM loader in, with a readback that proves it

**Builds, 0 errors, timing clean. 7,707 ALM (18%), 58 M10K.** Not on hardware yet.

The whole memory path is instantiated in the 80 MHz domain and the overlay now
carries seven words, the last two of which are **the first two 32-bit words read
back out of SDRAM**:

| word | meaning |
|---|---|
| 0 | `B0ADCAFE` magic |
| 1 | frame counter (liveness) |
| 2 | lines/frame — must be `1A8` |
| 3 | visible pixels/line — must be `1F0` |
| 4 | status: `pll_locked`, `mem_ready`, `rom_loaded`, `overflow` |
| 5 | **ROM word 0, read back from SDRAM** |
| 6 | **ROM word 1, read back from SDRAM** |

Loading a ROM nothing reads proves nothing. Compare 5 and 6 against the ROM file
by eye; **if the read capture phase is wrong they come back shifted**, which is
the failure the new OSD option exists for — so this is also how that option gets
set, instead of guessing one 25-minute build at a time.

**Three things carried over from the Model 1 core that would each have cost a
build:**

- **`T_REFI(600)`, not the default 700.** T_REFI is in clock cycles and this
  domain is 80 MHz: 8192 rows in 64 ms is 625 cycles. 700 under-refreshes and
  presents as *random ROM corruption*, not as a timing setting.
- **`SDRAM_CLK = ~clk_sdram`.** The device is clocked on the falling edge, so no
  phase-shifted PLL output is needed.
- **Selectable read capture phase**, defaulting to CL+2. Model 1's board returned
  every burst shifted right by one 16-bit word because the real device answers
  half a period away from the simulation model.

**Two findings from the integration itself:**

1. **`NP=1` does not elaborate** — the arbiter indexes `grant[2]` unconditionally.
   Using `NP=5` with four ports tied off rather than editing lifted code; ports
   1-4 become the CPU, tilemap and renderer.
2. **This controller addresses 32 MB**, being `[24:1]` with 2 bank and 13 row
   bits. **Model 2's ROM set is 43.62 MB, so the full set does not fit it on any
   board.** Fine for P1.5 — the 2D milestone needs the tilemap dump, palette and
   character data, well under a megabyte — and it must not be forgotten for P6,
   where it needs widening for a 128 MB module or the DDR3 split.

**Next: step 4, S24TILE** (`m1_tile_fetch/decode/mixer`, `m1_palette`, char RAM
rebased to `0x01080000`), then step 5's MAME-dump oracle.

### P1.5 step 3 STARTED: modules lifted, NOT yet wired

**Deliberately bounded.** The four modules are in `rtl/` and lint clean; nothing is
instantiated, so the build and `make test` (16 suites) are untouched and green.
Integration is the next session's work, not a half-finished tree.

| file | lines | from `b895e6c` |
|---|---|---|
| `rtl/mem/m2_sdram.sv` | 741 | `m1_sdram.sv` |
| `rtl/io/m2_rom_loader.sv` | 316 | `m1_rom_loader.sv` |
| `rtl/mem/m2_cdc_port.sv` | 173 | `m1_cdc_port.sv` |
| `rtl/mem/m2_cdc_pulse.sv` | 59 | `m1_cdc_pulse.sv` |

Renamed only — logic untouched. `m2_sdram.sv` raises six lint warnings
(`UNUSEDSIGNAL`, `UNUSEDPARAM`, `WIDTHEXPAND`); **they are upstream's and the file
is deliberately unedited**, so it is linted with those three suppressed. Do not
"fix" them here; fix them upstream or leave them.

**What integration must get right, in order of how expensive it is to get wrong:**

1. **One access is `req & ack`, not one cycle of `req`.** `i960_lsu.sv` holds
   `bus_req` for the whole transfer state. Harmless for RAM, fatal for the FIFO
   and I/O behind it. `docs/mister-integration.md`.
2. **`ioctl_wait` gated on `ioctl_download`** — it stalls the HPS itself
   otherwise. The lifted loader already carries the fix and the FIFO that makes it
   work: `ioctl_wait` *asks* the host to stop and it does not stop instantly.
3. **Memory out of reset on PLL lock and stays out**, separate from game reset.
   `Model2.sv` already splits `mem_rst_n` from `game_rst_n` for exactly this.
4. **`mem_ready` and `rom_loaded` are different facts** and must not share a signal.
5. **Layout is `docs/rom-layout.md`** — 43.62 MB, fits a 128 MB board with 84 MB
   spare, no DDR3 split needed. `m2_fetch_bridge` not yet taken.

### P1.5 step 2 DONE: the overlay is in, and it prints the timing numbers

`rtl/video/m2_diag.sv`, lifted from Model 1 at `b895e6c`, wired over the test
pattern. Build: **7,256 ALM (+86), 0 errors, timing clean.**

It reports four words, and the point is that two of them are **assertions the
board can fail**:

| word | value | meaning |
|---|---|---|
| 0 | `B0ADCAFE` | magic — a garbled overlay is obvious rather than plausible |
| 1 | frame counter | liveness, numerically, wrapping |
| 2 | lines last frame | **must read `000001A8`** (424) |
| 3 | visible pixels per line | **must read `000001F0`** (496) |

Those are MAME's `set_raw` numbers. `sim/video/tb_m2_video_timing.cpp` already
asserts them in simulation — **simulation proving them and silicon proving them
are different claims**, and until now only the first had been made. If the board
shows anything other than 1A8 and 1F0, the timing is wrong on hardware regardless
of what the testbench says.

**Next: step 3, SDRAM + ROM loader.** The standing rule from `b895e6c` applies from
its first peripheral — **one access is `req & ack`, not one cycle of `req`**.

### One access is `req & ack`, not one cycle of `req` — pulled at `b895e6c`

Model 1 found a TGP FIFO bug that **transfers straight to our bus fabric**, and
P1.5 step 3 is where we build it.

Its coprocessor holds `mem_req` across two states (a registered RAM read needs the
address to stay put), and its FIFO logic popped/pushed on the *level*:

```systemverilog
assign fifo_in_pop   = fifo_rd && fifo_in_valid;    // fired EVERY cycle
assign fifo_out_push = fifo_wr && !fifo_out_full;   // likewise
```

Every `mov (x1), b` consumed **two** command words; every `mov p, (bx1)` pushed
**twice**. Symptom: a hardware deadlock, the copro waiting for a word the V60 had
already sent. **The double push was found one minute after the double pop was
fixed, because the first correct result printed twice** — left alone it would have
fed a duplicate and gone wrong one command later, much harder to see than the
deadlock hiding it.

**Our exposure is real but on the peripheral side.** `i960_lsu.sv` drives
`bus_req = (state == S_XFER)` and drops it on `bus_ack` — correct, and harmless
for RAM, because reading the same word twice returns the same word. It is *not*
harmless for a FIFO, a read-to-clear register, or an auto-incrementing port.
**Every peripheral step 3 attaches must count one access per handshake.** Recorded
as a standing rule in `docs/mister-integration.md`, with the fix shape worth
copying: a `popped`/`pushed` flag cleared when the request drops, the pop firing on
the first cycle data is actually present so an access to an empty FIFO still
completes, and the ack accepting "already done".

**`mb86233_core` re-measured: 2,355 ALM, unchanged** — the fix is in `m1_tgp.sv`,
outside the core. Budget row stands.

### R17: Model 1 has measured that MEMORY, not the CPU, is the throughput lever

Pulled `tools/model1-ref` to **`198e1d9`** (15 new commits) per rule 10. Two of
its findings land directly on ours.

**Its V60 runs at 30.49 CPI, and 65% of cycles are memory stalls** — 38% data,
27% fetch, barely overlapping, because a single arbitrated bus serialises them.
Its CPU in isolation is ~6 CPI against MAME's implied 8, so **the 3.18x gap to the
reference is almost entirely the memory subsystem**, and optimising the CPU would
not close it.

**That reframes R16 without contradicting it.** Our CPI 5.04 and ~3.0x headroom
were measured against an idealised bus — the lockstep harness answers memory on
demand, with no SDRAM latency, refresh or contention. On hardware the i960 shares
SDRAM with the renderer, TGP, sound and video: five masters, the configuration
Model 1 measured 65% stall under. **R16 stands as measured and must not be quoted
as a hardware margin.** A 3.18x memory-induced gap against a 3.0x margin leaves
nothing.

**Design consequence:** the i960's instruction cache stops being an optimisation
and becomes load-bearing. `i960_icache.sv` exists, but **its hit rate against real
Daytona code under realistic latency has never been measured** — and that can be
had from the R16 traces plus a latency model, with no hardware. That is the number
to get before any pipeline discussion resumes.

**Second finding, on M10K:** Model 1 now sits at **452/553 M10K (82%)** with 29,536
ALM. Our §5.5 conclusion that M10K is not binding came from **standalone blocks**
with no memory subsystem, caches or FIFOs — and our own step-1 build already uses
56 M10K for framework plus a test pattern. That conclusion is weaker than it reads
and should be re-taken once the memory subsystem exists.

**TGP re-measured after its fixes: 2,355 ALM** (was 2,344), Fmax 46.66. Budget row
unchanged.

Method note worth keeping: that project reached its cycle number on the **third**
attempt — the first was arithmetic dressed as a finding, the second used a sweep
that hardcoded `-GCEDIV=3` while the design shipped `ce_cpu(1'b1)`, so every number
it ever produced described a CPU getting one cycle in three. Same failure mode as
R15 here, same day, different project.

### P1.5 step 1 DONE: a timing-clean .rbf that draws a test pattern

**`output_files/Model2.rbf` builds, 0 errors, and meets timing with no negative
slack anywhere.** Not yet run on hardware.

| | |
|---|---|
| ALM | **7,170 / 41,910 (17%)** |
| M10K | 56 / 553 (10%) |
| DSP | 33 / 112 (29%) |
| PLLs | 3 / 6 |

Ours is 134 ALM of that (timing 51, pattern 83); the rest is `sys/`. **That
independently corroborates the 6,630 framework figure** the budget carries from
M2-E — this build measures ~7,036 for framework plus PLL plus `hps_io` wiring.

**The one real trap, and the doc had already warned about it.** The first
`rtl/pll/pll.v` put `altera_pll altera_pll_i` directly inside `pll` — correctly
named at both ends, but with no `pll_inst` level. `sys/sys_top.sdc` groups core
clocks by matching the whole instance path `*|pll|pll_inst|altera_pll_i|*`, an
empty `get_clocks` makes `set_clock_groups` a silent no-op, and so **the design
was not timed at all**: −36.5 ns setup on a 31.25 ns clock, −45.1 on the HDMI PLL,
−13.2 on audio — while reporting success and emitting an .rbf. Restoring the level
took every one of those to zero.

The framework PLLs failing made the symptom point away from the cause. And
`docs/mister-integration.md` has carried this warning, quoting −87 ns, since
before this core existed. **Second time in one session that a written-down lesson
did not prevent the thing it described** (see R15). Both fixes are now guards
rather than prose: `Model2.sdc` counts the matched clocks and raises a Quartus
error when the count is zero, so the build fails instead of passing vacuously.

**Files:** `Model2.sv` (emu top), `Model2.qsf/.qpf/.sdc`, `files.qip`,
`rtl/pll/pll.{v,qip}`, `sys/` copied from the MiSTer template. Build with
`quartus_sh --flow compile Model2`; note `quartus_map` alone does not run the
pre-flow script that generates `build_id.v`.

**Next: step 2, the debug overlay** (`m1_diag`, 307 ALM) — before any board test,
not after the fifth failure.

### P1.5 started: video timing and test pattern done, framework next

**Step 1 RTL is complete and verified. The MiSTer framework is not started.**

- `rtl/video/m2_video_timing.sv` — Model 1's module copied at `f48c842`, **51
  ALM**. **No retiming was needed** (MAME declares both machines identically), and
  `sim/video/tb_m2_video_timing.cpp` asserts it against MAME's `set_raw` rather
  than its own parameters: 278,144 pixel clocks/frame, 424 lines, 496x384 visible
  with every visible line exactly 496, and 57.52 Hz. `make test` is now 16 suites.
- `rtl/video/m2_testpattern.sv` — ours, **83 ALM**. Border proves nothing is
  cropped, eight bars prove channel order, corner markers prove orientation, and a
  block marching one bar per second proves liveness.

**The PLL does not transfer — checked, not assumed.** Model 1's outputs are 80 MHz
and 19.2 MHz; 19.2 is its V60 clock. Model 2 must regenerate it, and its
frequencies are clean: MAME's pixel clock is `32_MHz_XTAL/2`, so **16 MHz is
exactly 32 MHz halved** — no fractional division. Proposed: ~80 MHz SDRAM, 32 MHz
video with `ce_pix` = /2, ~25 MHz i960. `pll_0002.v` in the Model 1 tree is a
direct `altera_pll` instantiation rather than a Qsys black box, so the equivalent
can be hand-written. **It must be named `pll`** or `sys_top.sdc`'s clock groups
match nothing and a passing build fails on hardware.

**Next, in order:** the `pll` wrapper; copy MiSTer `sys/` from
`third_party/template`; the core `emu` module wiring timing + pattern to `VGA_*`;
`.qsf`/`.qpf`/`files.qip`; then an `.rbf`. Only the last costs a build.

One testbench trap recorded at the site: `vblank_start` is high ON cycle 0 of the
frame, so ticking past it before counting drops that cycle and every total comes
out one short — which reads exactly like an off-by-one in the RTL counters, and
was reported as one.

### SETTLED (R16): ~3.0x throughput headroom, measured properly

R15 withdrew R10 and R13. **R16 replaces them, and R10's conclusion survives with
its number out by 2x and its evidence replaced.**

Twelve consecutive attract-mode frames at frame 2300 of `daytona93`, traced with
the collapse flag **verified** (1,285,223 instructions, 0 collapse markers):

| | per frame |
|---|---|
| total | 106,754 - 107,883 (mean 107,101) |
| spin | 71.3 - 72.7% |
| **work** | 29,208 - **30,949** |

Two poll loops are all of it — `ldob 0x500000`/`cmpibe` at **69.2%** of the frame,
and `ld 0x91fff0`/`cmpibne` at 2.6%.

**The decisive observation, which R10 asserted and never showed: the total is
near-constant while the work varies.** Total moves 1.1% across 12 frames while
work moves 6%, and at a lighter point work drops to 6,464 while the total holds at
110,739. The CPU spins to fill the frame, so **the total is capacity, not demand**
— and a poll loop that runs fewer times still exits, because what it waits on is
driven by real time.

**Demand: 30,949 instructions of work per frame = 1.78 M instr/s. At 5.33 M
instr/s that is 5.81 ms of a 17.39 ms frame — 33.4%, about 3.0x headroom.** And
5.33 is conservative: R13's mix over-weighted the expensive frame ops.

**R13's census recounted clean** (work-only, 356,587 instructions): `call` 1.543%
(was 2.053%), `ret` 1.772% (was 2.395%), `callx` 0.225% (was 0.262%) — overstated
~30%, in the predicted direction. **The generator mix should be re-derived from
this trace**; until then CPI 5.04 is an upper bound.

| | work/frame | demand | margin |
|---|---|---|---|
| R10 | 15,400 | 0.93 M/s | 7.4x |
| R13 | same | same | 5.7x |
| R15 | withdrawn | withdrawn | unproven |
| **R16** | **30,949** | **1.78 M/s** | **~3.0x** |

Same caveat R10 had, now stated as a bounded gap: **attract mode only**, 14 frames
at three points. Gameplay is unsampled and could be heavier. The tooling to close
it exists and refuses to return a collapsed trace.

**Tooling:** `tools/i960-trace.sh` (verifies, refuses collapse markers) and
`tools/mame_i960_frame_trace.lua` (frame-notifier driven, `tracelog` boundary
markers, works around the unresolved long-`gtime` failure).

### RETRACTION (R15): the i960 throughput numbers came from loop-collapsed traces

**Read this before quoting any instructions/second figure.**

Every i960 trace taken before 2026-08-18 used `trace <file>,:maincpu` with **no
loop flag**, so MAME collapsed loops and printed `(loops for N instructions)`
instead of the bodies. Measured over the three traces R10 used:

| trace | printed | hidden | true total |
|---|---|---|---|
| f1 | 14,469 | 49,149 | 63,618 |
| f2 | 14,474 | 73,647 | 88,121 |
| f3 | 17,441 | 95,480 | 112,921 |

**77-85% of executed instructions were never in the file** — and they were exactly
the loop bodies, which is the population the "0.1% spin" claim was about. A
verified-uncollapsed 17 ms window shows 322,707 instructions across **148 distinct
PCs, with the top 20 accounting for 99.8%**, against R10's "4,200 distinct PCs,
hottest 0.4%".

**Withdrawn:** R10's 15,400 instr/frame, its 0.93 M instr/s, its 4,200 distinct
PCs, its 0.1% spin fraction; R13's mnemonic census and call-depth distribution,
and therefore the generator mix, CPI 5.04 and **5.33 M instr/s**.

**Not established:** the corrected requirement. The clean window above is a *boot*
frame; R10's were ~40 s in during a demo race. A settled uncollapsed trace has not
been produced — a long `gtime` in a debugscript yields no trace file here,
unresolved and recorded in the tool.

**So: the margin is unproven, not disproven.** If most recovered instructions are
spin, R10's conclusion survives with a smaller margin, because a poll loop that
runs fewer times still exits. If they are work, the core is at or below
requirement. Neither may be claimed yet.

**Area figures are unaffected** — they are fitter output, not traces.

`tools/i960-trace.sh` is the fix: it always passes `noloop`, and **refuses to
return any trace containing a collapse marker**. It also records two mechanics
that cost an hour — `gtime` is milliseconds, and long `gtime` values silently
produce no trace.

This is the fourth instance of the same error (R9, R10, R13, R15): a number used
without establishing what produced it. It is the worst of them, because
`docs/differential-testing.md` was written the same day and its first named
artifact, carried from the Model 1 core, is "**`noloop` is not optional**". The
warning was transcribed and not applied. **A lesson recorded is not a lesson
applied**, and the only durable form is a tool that refuses.

### callx lands, the frame path gets its first real test, and the throughput figure is corrected downward

`callx` is implemented and verified. Daytona now executes **no unimplemented
mnemonic**: all 80 distinct mnemonics in the 196,885-instruction sample are
covered. Study entries **R11**, **R12** and **R13**.

**Two latent frame defects, neither reachable before now.** `T_FRAME` exited on
`!rf_busy`, but `busy` is `state != S_IDLE` and the register file has not yet
*seen* the request in the first `T_FRAME` cycle -- so it left one cycle early
every time, refetched the same instruction and called again. Usually swallowed by
accident; when the refetch was slow (an I-cache fill) it was a **real** second
call, and one `callx` was seen building five frames and spilling to memory. And
the call target was presented live rather than latched, though `next_ip` is
sampled in `S_CALL_FIN` several cycles later -- `callx`'s target is `ea`, which
moves as soon as `ra1`/`ra2` revert on leaving `T_EXEC`. Both were latent in
`call` and `ret` too.

**Neither could have been caught: the whole-CPU generator emitted no `call` or
`ret` at all.** `i960_regs` has a thorough unit test, and a unit test that drives
`op_call` itself cannot see a *sequencer* that drives it twice. The generator now
emits `call`, `callx`, `ret` and `flushreg`, and seeds SP/FP plus a resident frame
at 0x2000 so a return below depth zero lands somewhere real -- that is the only
path outside the unit test that exercises the frame **reload**.

**`cvtri` overflow was wrong twice and the unit test skipped it.** `eu > 31`
misses the whole exponent-31 band (2^31..2^32 is out of range except -2^31), and
rounding can carry past 2^32, which was truncated to 32 bits *before* the range
check and read as `0`. `tb_i960_fpmisc.cpp` contained `if (r < -2147483648.0 || r
> 2147483647.0) return;` -- it skipped every out-of-range input, so 1.2M passing
checks never touched the path. Now checked, plus a directed walk of the int32
boundary both directions in all four rounding modes. MAME's answer here is x86's
indefinite value from a UB cast, not the manual's; the oracle wins and it is
recorded rather than buried.

**Throughput corrected: 6.86 -> 5.33 M instr/s.** R10's 6.86 came from a mix with
no calls in it. Counted from the same traces: `call` 2.053%, `ret` 2.395%, `callx`
0.262%, `calls` and `flushreg` 0.000%. **The margin over the 0.93 M instr/s demand
is 5.7x rather than 7.4x. R10's conclusion is unaffected -- the pipeline is still
not required.**

**The sharper half of that: the rate alone was not enough.** Emitting call and ret
at their measured rates gave CPI 6.71 and T_FRAME at 42% of cycles, because ret
slightly outnumbers call, depth sits at zero, and nearly every ret underflows into
a sixteen-word memory reload. What sets the cost is how often a call exceeds the
4-frame cache. Measured from the traces: **max depth 7, and only 8.5% of calls
spill**. The generator now models depth while emitting and **prints its own spill
rate beside the measured one every run** -- currently 9.5% vs 8.5%, conservative
in the right direction -- so the mix cannot drift silently again.

**Four harness deviations recorded, all abandoning the program like a subnormal
operand or a legitimate self-loop the retire detector cannot see:** self-modifying
code (a clobbered SP/FP sends a frame spill over the program; the I-cache has no
coherency with data writes), the IP leaving the program, a `callx` targeting its
own slot, and a `ret` immediately after a call -- the return address a call
records is `ip_next`, so a `ret` there returns to itself forever. That last one is
the general case and took three separate traces to see in full.

**State:** 15/15 suites pass; whole-CPU lockstep clean across **48 seeds** (it had
been run on one). `i960_top` measures **6,979 ALM** (6,986 before -- flat), Fmax
27.3 -> 26.84 MHz.

**Remaining i960 work.** Daytona's *instruction set* is complete; Daytona's
*machine* is not.

- **interrupts — a prerequisite, not a completeness item (R14).** Model 2 drives
  **four** i960 interrupt lines from a 12-bit request register (vblank, four
  timers, sound UART) via `model2.cpp::irq_update()`. **The core has no `irq`
  port at all.** Needs the PRCB interrupt table, vectoring, a type-7 call onto a
  separate interrupt stack, the IP/AC save, and `ret` dispatching on `PFP[2:0]`.
  This gates P1 exit criterion 3.
- **`ret` ignores `PFP[2:0]` in BOTH the module and the reference**, so they agree
  and lockstep is silent — R11's lesson repeating. MAME switches on the type and
  `fatalerror`s on 1-6. Fix with interrupts.
- faults — absent entirely, and they touch the sequencer
- `synmov`/`synmovq`, `calls`, `modpc` — bounded; `calls` measures 0.000% in the
  traces
- `rl` double-precision FP forms (four register reads against a two-port file);
  `remr`
- six glibc transcendentals — M2-B found zero in Daytona; confirm before building

### Every block measured, in every currency

Six blocks fitted this session on 5CSEBA6U23I7 with Quartus 17.0.0. The budget
now has **two estimate rows left**; everything else is a figure.

| Block | ALM | reg | M10K | MLAB bits | DSP | Fmax | whose RTL |
|---|---|---|---|---|---|---|---|
| `i960_top` | **6,979** | 4,212 | 1 | 2,048 | 7 | 26.84 | **ours** |
| `sys/` framework | **6,630** | — | — | — | — | — | upstream (M2-E) |
| VDP2 (tilemap ceiling) | **6,852** | 9,184 | 4 | 272 | 12 | 65.73 | srg320 |
| N64 RDP (renderer ceiling) | **8,347** | — | — | — | — | — | N64 (M2-E) |
| VDP1 (renderer floor) | **2,537** | 1,707 | 0 | 512 | 3 | 31.52 | srg320 |
| `mb86233_core` | **2,344** | 1,819 | 6 | 0 | 1 | 43.86 | Model 1 |
| fx68k | **2,134** | 1,412 | 6 | 0 | 0 | 68.45 | ijor, GPL-3 |
| SCSP | **2,030** | 2,379 | 26 | 0 | 2 | 76.73 | srg320 |

Device: **41,910 ALM, 553 M10K, 112 DSP**. Budget total **24,454 - 40,293 ALM**
(was 34,160 - 49,460). **The optimistic case fits with 14.1K spare against the
92% routing line; the pessimistic case fits the raw device.**

**M10K is not binding here, and that is now measured rather than assumed** — tens
of blocks against 553. One caveat stated plainly: **the renderer's framebuffer and
texture cache are in none of these numbers**, because no renderer RTL exists. A
496x384 16-bit framebuffer alone is 3.0 Mbit = 298 M10K. That is the number to
watch, and it is the only resource question still open.

`tools/model1-ref` pulled to **f48c842** per rule 10. Its new commit is docs-only
but carries a warning worth honouring: **its TGP trace figures recorded before
2026-08-18 are invalid** — the bench's microcode loader assigned `uc_data`/`uc_addr`
non-blockingly, so the coprocessor executed from the wrong addresses. Area
measurements are unaffected, which is why the MB86233 re-measure above stands.

**The standing lesson from this session, and it is the fourth instance.** Every
defect found here was in code that had a passing test. The frame path had a unit
test that could not observe the bug by construction; `cvtri` had a test that
skipped the failing inputs by construction; the CPI had a mix missing an entire
instruction class. **Ask what a passing test cannot see, not whether it passes.**
