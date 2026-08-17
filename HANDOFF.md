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
