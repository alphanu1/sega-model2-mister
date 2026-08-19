# Differential testing against MAME

**When behaviour diverges from the reference, diff against the oracle before
theorising. This is the first tool, not the last.**

This is not a proposal. It is already how the strongest findings in this project
were established, and it is how the remaining ones will be.

---

## The Model 1 core wrote this method down first, and it transfers

`tools/model1-ref/docs/differential-testing.md`, pinned at **f48c842**, is the
source document. **Read it before starting any divergence hunt here.** Its
lessons are about the *method*, not about the V60, so they transfer verbatim to
the i960 and the MB86234.

That project reached a CPU-level bug it could not find by simulation, built
instruction-stream and write-trace diffs against MAME's debugger, and **found
three real defects in about two hours — two of them CPU bugs that had survived
29/29 unit tests, every fuzz suite, boot traces, frame renders and months of
use.** The same afternoon it named and withdrew five causes reasoned from
plausible mechanisms.

The headline trap is the one that matters most here:

> **A reference model written from the same reading of the source as the
> implementation cannot catch a misreading of the source.** It only catches a
> slip between the two.

Its two habits follow directly and apply to every reference file in `sim/`:

1. **Derive reference models from the oracle's source, and cite file and function
   in a comment.** If the citation is wrong the model is wrong, and a future
   reader can check the citation.
2. **Break the RTL on purpose and confirm the count moves.** A test that does not
   fail when the logic is inverted is not testing that logic.

**Its list of five withdrawn artifacts is required reading.** Every one was the
instrument rather than the design: collapsed loops without `noloop`,
branch-to-self loops logged on change, warm `nvram/` from a reused directory, a
PC published but never executed, a poll loop alternating two addresses, and a
testbench whose loader wrote microcode one word high. Expect the same shape here.

---

## What has already been done here with it

| Finding | Method | Where |
|---|---|---|
| **M2-B**: FP instructions per frame by class | MAME `-debug -debugscript`, opcode census | study §, `p1-i960-spike.md` |
| **R10**: Daytona needs 0.93 M instr/s, not 12.5 | three single-frame traces, instructions between frame boundaries | study R10 |
| **R10**: 4,200 distinct PCs/frame, 0.1% spin | PC distribution over a traced frame | study R10 |
| **i960 scoping**: 80 mnemonics executed, one missing | mnemonic census over 196,885 instructions | study R11 |
| **R13**: `call` 2.053%, `ret` 2.395%, `callx` 0.262% | mnemonic census over 233,878 instructions | study R13 |
| **R13**: call depth max 7, only 8.5% spill | depth tracked through every call and ret in the trace | study R13 |
| **R14**: Model 2 drives four i960 IRQ lines | read `model2.cpp::irq_update()` | study R14 |

`tools/m2b-mame.sh` is the runner. It already implements Model 1's "run from a
scratch directory" lesson structurally: every writable MAME directory points
outside the tree, because `nvram/` is ROM-derived data that must never enter this
repository — and because **warm NVRAM produced a false CPU-bug report on Model
1**, chased at instruction 197,251 before the file was deleted and MAME agreed.

---

## What is different here

- **Two CPUs, not one.** The i960 main CPU and the MB86234 TGP. Model 1 needed
  both a `v60_trace` and a `tgp_trace`; expect the same split.
- **The i960 has a MAME disassembler and debugger**, so the instruction-stream
  method applies directly. `-debug -debugscript` with `trace <file>,0,noloop` is
  the starting point, and **`noloop` is not optional** — without it MAME collapses
  loops and the diff reports phantom extra instructions that read exactly like a
  branch bug.
- **The renderer has no bit-exact oracle at all** (study §2.1). Framebuffer
  comparison is the method there, not instruction diffing, and P1.5 already
  applies it to the 2D path: dump tilemap RAM and palette from MAME at a known
  frame, render, compare against MAME's screenshot.

---

## Where the instruction-trace method will stop here

**At the first timing-dependent wait loop**, exactly as on Model 1 — where the
boundary was the I/O board handshake, and where a *guessed constant in a
peripheral produced a false CPU-bug report*.

The analogue here is already visible in the R10 measurement: Daytona spends
**0.1% of its instructions in a spin loop**, and the i960 waits on the geometry
FIFO. Past that point, prefer **write traces** and targeted comparisons, which
tolerate timing differences that a PC stream does not.

**When the diff points at a wait loop, measure the thing being waited on before
suspecting the CPU.** Model 1 resolved its handshake by asking the reference
(`mame_iohandshake.lua` timed it at 38,577 us) rather than tuning a latency until
the traces agreed. Do that, not the other.

---

## The same trap, already sprung here

Model 1's headline trap is not hypothetical for this project. It has already cost
real time:

- **`ret` ignores `PFP[2:0]` in BOTH the module and the reference** (R14). They
  agree, so lockstep is silent. MAME switches on the type and `fatalerror`s on
  1-6. A shared omission cannot be fuzzed apart.
- **The FP reference dispatched on `(op << 8) | op2`** against `case 0x78f`, so it
  never matched and the reference trapped on every FP op — while reporting
  passing checks.
- **`tb_i960_fpmisc.cpp` skipped every out-of-range `cvtri` input** (R12), so 1.2
  M passing checks never touched the overflow path, which was wrong in two
  independent ways.
- **The whole-CPU generator emitted no `call` or `ret` at all** (R11), so two
  frame defects were unreachable — and `i960_regs`'s unit test, which drives
  `op_call` itself, could not observe a *sequencer* that drove it twice.

And the artifact class Model 1 warns about — **suspect the instrument first** —
has appeared here repeatedly and in the same shapes:

- a retire detector that reads a **correct** infinite self-call or self-return as
  a stall, because the IP legitimately does not move. Found three separate times
  before the general form was stated.
- self-modifying code, where the DUT's I-cache and the cacheless reference are
  **both correct** and cannot agree.
- an invariant whose arming anchor did not match, so it never armed — and a real
  symptom was wrongly declared an artifact on the strength of it.
- a build failure hidden by `>/dev/null 2>&1`.

**Suspect the instrument first when the reported fault is a difference in count,
in timing, or in one instruction.**

---

## What to build when the i960 needs this

Not yet built here, and the shape is known from Model 1:

1. **`make i960_trace`** — MAME instruction stream vs our `dbg_ip`, aligned and
   diffed, printing MAME's disassembly around the first divergence. Collapse the
   shortest repeating period on **both** sides, not just consecutive repeats: a
   poll loop that alternates two addresses defeats consecutive-repeat collapsing.
2. **Write traces** — `install_write_tap` over the address space on MAME's side,
   the same log from ours, then `cmp`. **Filter I/O-space writes from our side
   first** if I/O shares the memory bus here as it did on Model 1.
3. **Assign every Lua tap and notifier to a global**, or the subscription is
   collected and the callback silently stops.

`dbg_ip` must name **the last instruction that ran**, assigned on dispatch — not
published ahead of an interrupt check, which on Model 1 made the core appear to
execute one instruction it had not.

---

## A collapsed trace that says IDENTICAL can be hiding a loop only one side has

**From the Model 1 project, `9b3b70a`.** Worth having here before we build the
i960 trace, because it is a blind spot in the exact instrument this document
tells you to build.

That core's v60 trace ran to 1.5 billion cycles and reported **IDENTICAL for
25,685 instructions with zero resync sites** — while our side yielded the same
25,685 collapsed instructions at both 700 M and 1.5 B and the reference reached
5,193,988. "Identical" and "stuck" were both true at once.

The reason: **both streams are collapsed to one instance per repeating period.**
A loop present in one side and absent in the other leaves the PC *sequences*
identical — the collapse erases exactly the difference. Collapsing is what makes
a long trace comparable at all (see item 1 above), and it is also what hides
this.

**The counts file is what carries the difference.** Not the sequence — the
iteration count per collapsed body:

```
ours  ff8ac3,ff8ac6,ff8ac8,ff8aca,ff8acd   counts 6..14
MAME  same body                            count 20, consistently
```

which disassembles to a null-terminated string copy emitting 16-bit tile codes —
the text routine, running on both sides and copying different strings.

**So: emit a counts file alongside the collapsed trace, and diff it too.** A
collapsed-sequence comparison alone cannot report this class at all, and it will
tell you everything matches while the core is wedged. Note also that the counts
file only reports loops collapsed on **both** sides, so it is a partial
instrument as well — a loop only one side collapses needs the raw stream.

This is the same shape as R15 and R20 in the design study: the instrument was
believed and never checked, and it was capable of reporting agreement it had not
established.
