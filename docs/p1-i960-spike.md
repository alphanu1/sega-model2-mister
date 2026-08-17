# P1 — i960KB spike

The gate for the whole project, alongside P2. Design study §5.5: the i960 and the
renderer together must land under ~25,000 ALM or nothing else matters.

Ground truth is MAME `src/devices/cpu/i960/i960.cpp` (Farfetch'd, R. Belmont,
BSD-3-Clause) at the revision pinned in `deps.lock`, plus `model2.cpp` for the
board. **Where this document and that source disagree, the source wins** — with
one exception, recorded in §4, where the source is known not to model the
hardware.

**No open-source i960 exists in any HDL** (§5.4.3). Unlike every other CPU-class
block in this core, there is nothing to port and nothing to compare against but
a C++ behavioural model.

---

## 1. Scope

**In:**

- The full integer core: 164 implemented mnemonics across the four instruction
  formats.
- Register model — 16 local + 16 global, the register cache, and its spill path.
- Addressing: MEMA, and the MEMB modes MAME handles (§3.3).
- The 32-bit multiplexed burst bus, and the `BURST` regions of the Model 2 map.
- Interrupts as MAME implements them: IRQ0-3, the pending/vector path.
- FPU — but staged, and second. See §6.

**Out, deliberately:**

- **IACs beyond the seven MAME recognises.** `0x40`, `0x41`, `0x80`, `0x89`,
  `0x8f`, `0x91`, `0x92`, `0x93` are logged rather than executed; everything else
  reaches `fatalerror`. Model exactly that set and trap the rest — a game that
  needs more will announce itself loudly instead of drifting.
- **Fault-on-FAULT.** MAME: `"Taking the fault on a FAULT insn not yet
  supported"`. If Model 2 games needed it, MAME would not run them.
- **Unhandled MEMB modes and unhandled `0x58`-`0x5b` sub-opcodes.** Same
  reasoning: these are `fatalerror` in the reference, so they are unreachable in
  practice. Trap, do not implement.
- **Breakpoints, tracing, the halt/continue IACs** beyond logging.

There is no MMU. The i960KB has none — that is the CA and MC parts.

---

## 2. Register model

| Group | Count | Note |
|---|---|---|
| Local `r0`-`r15` | 16 | windowed; `r0`=PFP, `r1`=SP, `r2`=RIP |
| Global `g0`-`g15` | 16 | flat; `g15`=FP (frame pointer) |
| Floating point `fp0`-`fp3` | 4 | **80-bit extended**; MAME uses host `double` |
| Control | — | `SAT`, `PRCB`, `PC`, `AC`, `IP`, `PIP`, `ICR` |

MAME holds all 32 in `m_r[0x20]` with locals at 0-15 and globals at 16-31.

### 2.1 The register cache is where the area decision lives

```cpp
enum { I960_RCACHE_SIZE = 4 };
uint32_t m_rcache[I960_RCACHE_SIZE][0x10];
uint32_t m_rcache_frame_addr[I960_RCACHE_SIZE];
int32_t  m_rcache_pos;
```

Four frames of sixteen words. On `call`, the current locals are saved into the
cache and `rcache_pos` increments; past four frames the frame spills to memory
at `FP & ~0x3f`. On `ret` it reloads, from cache or from memory.

Design study §5.2 named this as where i960 implementations get expensive, and it
is right about the risk but wrong about the shape. **MAME copies sixteen words
because it is software. RTL should not.**

Make the local register file a banked memory four frames deep and `call` becomes
a frame-pointer increment — O(1), no copy, no pipeline bubble to drain sixteen
writes. Sizing:

| Structure | Bits | Cost |
|---|---|---|
| 4 frames x 16 locals x 32 | 2,048 | 1 M10K, or 2 for a 2R1W duplicate |
| 16 globals x 32 | 512 | flip-flops, ~128 ALM — always live |

So the register file is roughly **2 M10K and ~128 ALM**, not the ~512 ALM a
flat flip-flop implementation of the same storage would cost. Given §5.6, spending
2 M10K here needs justifying against the M10K budget rather than assumed free —
but the flip-flop alternative is worse on both axes.

### 2.2 Cache depth is architecturally invisible and memory-visible

The i960 architecture leaves register cache depth implementation-defined, and
correct software must not depend on it. **That does not make it free to change
here.** When a frame spills it *writes to memory*, so depth changes the memory
write stream — which is exactly what lockstep compares.

**Decision: implement four frames, matching MAME.** Not because four is right for
hardware, but because any other depth diverges from the only oracle available.
Deeper caching is a legitimate later optimisation and must be treated as a
behaviour change requiring its own verification, not a free win.

---

## 3. Instruction set

164 mnemonics reach an implemented case in `execute_op`. Dispatch is on
`opcode >> 24`.

### 3.1 Formats

| Format | Opcodes | Contents |
|---|---|---|
| CTRL | `0x08`-`0x0b` | `b`, `call`, `ret`, `bal` |
| COBR | `0x10`-`0x3e` | conditional branch, `fault*`, `test*`, `cmp*b*`, `bbc`/`bbs` |
| REG | `0x58`-`0x79` | arithmetic, logic, shift, bit, conversion, and all FP |
| MEM | `0x80`-`0xca` | load/store in byte, short, word, long, triple, quad widths |

### 3.2 The REG block is where the work is

`0x58`-`0x5f` are sub-dispatched on `(opcode >> 7) & 0xf` and hold the integer
ALU. `0x60`-`0x79` hold conversions, moves and the entire FPU. Four sub-dispatch
tables end in `fatalerror` on an unhandled index — replicate that as a trap.

### 3.3 MEMB modes

Handled: `0x4`, `0x5`, `0x7`, `0xc`, `0xd`, `0xe`, `0xf`. Everything else is
`fatalerror`. Mode `0x5` carries a comment worth transcribing exactly — it is
"address of this instruction + the offset dword + 8", which is really "address of
the next instruction + the offset dword". Off-by-one here is a silent wrong
branch target, not a crash.

---

## 4. Timing — and this is the finding that shapes the FPU

**Read §4.1 of the design study first.** Its standing rule is that MAME cycle
counts are not hardware facts, and that rule has already produced two wrong
conclusions in this project when ignored.

**Corrected.** An earlier version of this section argued that `i960.cpp` was a
different case from `v60.cpp` and could be relied on. That argument was wrong in
its structure, and the correction matters because the FPU sizing in §4.2 was
built on it.

The reasoning was: `v60.cpp` hedges pervasively, `i960.cpp` hedges once, so the
i960 figures must be transcribed from Intel's published table. **That is
inference from the absence of a disclaimer, and absence of a disclaimer is not
evidence of accuracy.** Re-checked: `i960.cpp` carries no header caveat of any
kind, and MAME's own device documentation makes no accuracy claim about
instruction cycle counts in either direction. Nothing in the file says the
numbers are measured, and nothing says they are not.

MAME's cycle counts are estimates unless proven otherwise. That is this
project's own standing rule — design study §4.1 lists "treating MAME's cycle
counts as hardware facts" as a recurring failure mode that has already produced
two wrong conclusions — and it applies here too. The table below is what the
file contains, not what the silicon does:

| | `v60.cpp` | `i960.cpp` |
|---|---|---|
| Comment | `// Actual cycles / instruction is unknown` | none of that kind |
| Model | `m_icount -= 8; /* fix me — just an average */` | differentiated per opcode |
| Detail | flat | `remr`: `// (67 to 75878 depending on opcodes!!!)` |
| Hedges | pervasive | one, `expr`: `// checkme` |

A flat average cannot produce a data-dependent range for one opcode and a
distinct value for every other, so *something* differentiated these numbers. But
"differentiated" is not "measured": a careful author working from a datasheet
and a careful author working from judgement both produce differentiated values.

**The only thing that settles it is the i960KB Programmer's Reference Manual,
270567-001**, which `i960dis.cpp`'s own header cites. Until someone reads it,
every conclusion drawn from the table below is a hypothesis.

### 4.1 Measured from the reference

| Class | Op | Cycles |
|---|---|---|
| Control | `call` | 9 base |
| | `ret` | 7 |
| FP basic, single | `addr`, `subr`, `cmpr` | 10 |
| | `mulr` | 18 |
| | `divr` | 35 |
| FP basic, extended | `addrl`, `subrl` | 13 |
| | `mulrl` | 36 |
| | `divrl` | 77 |
| Conversion | `cvtir` / `cvtri` / `scaler` | 30 / 33 / 30 |
| **Transcendental** | `sqrtr` / `sqrtrl` | 104 |
| | `tanr` / `tanrl` | 293 / 323 |
| | `expr` / `exprl` | 334 |
| | `atanr` / `atanrl` | 267 / 350 |
| | `logepr` | 400 |
| | `sinr` / `cosr` | 406 |
| | `logr` / `logrl` | 438 |
| | `sinrl` / `cosrl` | **441** |

### 4.2 What that means

At 25 MHz, the ceiling if the CPU did nothing else at all:

| Op | Cycles | Per second | Per frame @ 60 Hz |
|---|---|---|---|
| `addr` | 10 | 2,500,000 | 41,667 |
| `mulr` | 18 | 1,388,889 | 23,148 |
| `divrl` | 77 | 324,675 | 5,411 |
| `sinr` | 406 | 61,576 | **1,026** |
| `sinrl` | 441 | 56,689 | **945** |

**If these figures are real, the silicon is extremely slow at transcendentals.**
A CORDIC at ~64 iterations
costs ~64 cycles; the real part takes 406 for the same function. A fully
microcoded FPU sharing one datapath would be roughly **six times faster than the
chip it replaces**, on the operations that dominate its area.

Three consequences — **all conditional on the figures being approximately
right**, which is exactly what is not established:

1. **Microcode the transcendental set.** Design study §7 lists this under Tier 1
   as worth 2-3K ALM "contingent on M2-B showing FP is not hot". If the cycle
   counts hold, the hardware itself caps transcendental throughput at ~1,000 per
   frame and the contingency largely evaporates. **If they do not hold, the
   contingency stands and M2-B decides.** The earlier claim that this was
   settled was over-confident.
2. **Iterate the extended multiplier.** 36 cycles for `mulrl` is ample budget for
   a multi-pass 27x27 DSP approach rather than a wide combinational multiplier.
   112 DSP blocks exist and Model 1 uses 49.
3. **This would push the FPU toward the bottom of its 2,500-6,000 ALM range**,
   which is the widest line in the i960 estimate — and that is precisely why it
   must not be assumed. The projection in this document keeps the **full**
   2,500-6,000 range for exactly this reason.

### 4.3 M2-B is not optional after all

An earlier version of this section said M2-B's purpose had "changed from verdict
to mix", because the hardware's own slowness answered the question. That rested
on the cycle counts being real, which is not established.

**M2-B stands as originally written.** It counts FP instructions per frame by
opcode class from actual game execution, which depends on no cycle model at all
— it is a count of what the games issue. That makes it the one piece of evidence
here that survives the timing table being wrong, and it is measured by
instrumenting MAME rather than by trusting it.

Two independent things would settle the FPU:

- **270567-001** — does Intel's table match `i960.cpp`'s numbers?
- **M2-B** — how many transcendentals do the games actually issue per frame?

Either alone is useful. Both agreeing would make the microcoded FPU a
measurement rather than a hope.

### 4.4 Fabric clock

§4.3 of the design study applies unchanged. Real CPI is probably 1.5-2 with the
512-byte I-cache, so 12.5-16.7 M instr/s at 25 MHz:

| Your CPI | Fabric clock required |
|---|---|
| 9.83 (FSM, the Model 1 TGP figure) | 123-164 MHz — impossible |
| 4 | 50-67 MHz |
| 2 | 25-33 MHz |

**Pipelined from the start.** An FSM does not close, and with M2-F deferred there
is no cheaper rehearsal to learn on (§9).

---

## 5. Memory map

From `model2a_crx_mem` → `model2_tgp_mem` → `model2_base_mem`. `B` marks regions
MAME flags `i960_cpu_device::BURST`.

| Range | Contents | B |
|---|---|---|
| `0x00000000-0x001fffff` | program ROM | B |
| `0x00200000-0x0023ffff` | RAM (2A-CRX only) | B |
| `0x00500000-0x005fffff` | work RAM | B |
| `0x00800000-0x00803fff` | geometry processor | |
| `0x00804000-0x00807fff` | geo program RAM | B |
| `0x00880000-0x00883fff` | copro function port | B |
| `0x00884000-0x00887fff` | copro FIFO | |
| `0x00900000-0x0091ffff` | buffer RAM, mirror `0x60000` | B |
| `0x00980000-0x00980003` | copro control 1 | |
| `0x00980004-0x00980007` | FIFO control (r) | |
| `0x00980008-0x0098000b` | geo control 1 (w) | |
| `0x0098000c-0x0098000f` | video control | |
| `0x00980030-0x0098003f` | TGP ID (r) | |
| `0x00e00000-0x00e00037` | CPU control — wait states | |
| `0x00e80000-0x00e80007` | IRQ request / ack / enable | |
| `0x00f00000-0x00f0000f` | timers | |
| `0x01000000-0x0100ffff` | S24 tilemap, mirror `0x110000` | B |
| `0x01040000` / `0x01060000` | tilemap H / V sync registers | |
| `0x01080000-0x010fffff` | S24 char RAM, mirror `0x100000` | B |
| `0x01800000-0x01803fff` | palette | B |
| `0x01810000-0x0181bfff` | colour translate | B |
| `0x0181c000-0x0181c003` | 3D Z-clip (w) | |
| `0x01a00000-0x01a04002` | M2COMM link board | B |
| `0x01c00000-0x01c0001f` | 315-5649 I/O, `umask32 0x00ff00ff` | |
| `0x01c80000-0x01c80003` | i8251 MIDI UART, `umask16 0x00ff` | |
| `0x01d00000-0x01d03fff` | backup SRAM | B |
| `0x02000000-0x03ffffff` | main data ROM | B |
| `0x06000000-0x06ffffff` | "extra" data ROM | B |
| `0x10000000-0x101fffff` | render mode | |
| `0x10400000-0x105fffff` | polygon count (r) | |
| `0x11600000-0x116fffff` | framebuffer A / B, `xGGGGGRRRRRBBBBB` | B |
| `0x12000000-0x125fffff` | texture RAM 0 and 1, each mirrored | B |
| `0x12800000-0x1281ffff` | polygon luma RAM, `umask32 0x000000ff` | B |

Two notes for P1 specifically. The `umask` entries are **narrow ports on a 32-bit
bus** — the I/O chip is byte-lanes 0 and 2, the UART is byte lane 0. Getting
these wrong produces plausible-looking garbage rather than a failure. And most of
the map is `BURST`, so the burst bus is not an optimisation to add later; it is
how this CPU talks to almost everything.

---

## 6. Order of work

The FPU is deliberately last. It is the only part with no oracle, and the
integer core is what M2-D measures.

1. **Instruction decoder and the four formats.** Fuzz decode against
   `i960dis.cpp` — a disassembler is a free second opinion on field extraction.
2. **Integer ALU, shifts, bit ops, compare and the condition codes in `AC`.**
   Per-opcode fuzz, 10^6 random operand pairs each, every flag compared.
3. **Register file, register cache, `call`/`ret`/`callx`/`balx` and the spill
   path.** Compare the memory write stream, not only the registers — §2.2.
4. **Load/store across all six widths, MEMA and the seven MEMB modes.** Include
   the narrow-port regions from §5.
5. **Bus and I-cache, burst.** 512-byte direct-mapped.
6. **Whole-CPU lockstep** against a transcribed `execute_run`, the shape Model 1
   used for `mb86233_ref.cpp`.
7. **M2-D: Quartus spike**, pipelined, `5CSEBA6U23I7`, virtual pins.
8. **FPU**, scoped by M2-B, microcoded per §4.2.

Steps 1-7 are the gate. Step 8 changes the area number but not whether the
approach works.

---

## 7. Exit criteria

1. Per-opcode fuzz: 10^6 random operand pairs per integer op, bit-exact against
   the reference including every `AC` condition bit.
2. Whole-CPU lockstep over generated programs covering every decoded instruction
   form, comparing all 32 registers plus the control registers after each retire,
   **and the data-memory read and write streams**. Zero divergence.
3. Real Model 2A program ROM executes with zero unimplemented-path hits.
4. **M2-D**: standalone Quartus, 17.0.0, `5CSEBA6U23I7`.
   *Pass* < 12K ALM and > 90 MHz. *Fail* > 18K ALM — design study §9 close
   condition.

Criterion 3 has the same limitation Model 1 hit at M0: the i960 does not boot
anything alone. It will reach the point where it waits on the TGP or the
renderer, and that is correct behaviour, not a failure. Plan for a stimulus
harness rather than a boot.

---

## 8. FPU precision — decided, not defaulted

§2.2 of the design study records that MAME models the four 80-bit registers as
host `double`, and this document's §8 says the choice between matching that and
implementing true 80-bit must be made explicitly. **Decision: 64-bit double,
matching the reference.**

The operand model is what makes this smaller than it sounds. From
`get_1_rif` / `get_1_rifl`:

| form | operand source | width |
|---|---|---|
| `r` (single) | one general register, reinterpreted | **32-bit IEEE single** |
| `rl` (extended) | a general register **pair** | **64-bit IEEE double** |
| either, literal | `fp0`-`fp3`, or `0x16` = 1.0, else 0.0 | the FP registers |

**64-bit is already the architectural interchange format.** Everything that
crosses between the FPU and the register file or memory is 32 or 64 bits wide.
The 80-bit format exists only inside `fp0`-`fp3`, so the deviation is confined to
the precision of intermediates held in those four registers between instructions.

Three reasons for taking it:

- **It is the only verifiable option.** The oracle is `double`. An 80-bit unit
  could not be lockstep-verified against anything this project has, which §2.2
  already identifies as the FPU's central problem.
- **MAME runs the games correctly at 64-bit**, so the titles do not depend on
  extended-precision intermediates surviving between instructions.
- **80-bit costs materially more.** A 64-bit mantissa datapath against a 53-bit
  one is wider adders, more DSP blocks for the multiply, and more of both for
  the transcendental sequencer — spent on precision that cannot be checked.

**This is a real deviation from the silicon and is recorded as one.** It is not
"the FPU is 64-bit because that was easier"; it is that the extra 11 bits of
mantissa are unverifiable, unused by the software, and not free. If a game is
ever found that depends on them, this decision is where to look.

Note also `set_rif` rounds a double result back to single for `r` ops.
Computing in double and rounding once to single is equivalent to direct
single-precision arithmetic for add, subtract, multiply and divide, so the
`r` forms need no separate single-precision datapath.

### 8.1 The first FPU datapath block, measured

`rtl/cpu/i960/i960_fpmul.sv` — IEEE-754 double multiply, round-to-nearest-even,
two cycles.

| | ALM | DSP | Fmax |
|---|---|---|---|
| `i960_fpmul` (double, 53x53) | **326** | **4** | 64.02 MHz |
| Model 1 `fp_mul` (single, 24x24) | 144 | 1 | 116.85 MHz |

Verified against **the host's own `double` multiply**, which is the actual
oracle here rather than a transcription of one — MAME computes in host `double`,
so the two are the same thing. 1.97 M checks per seed across three seeds,
including every combination of zero, negative zero, both infinities, NaN and
the exponent extremes. Zero mismatches.

**The DSP cost is the finding.** Four blocks for one double multiply against one
for single. The FPU needs a multiplier, a divider and a transcendental
sequencer, and §7's Tier 1 lever assumes DSP is free capacity — M2-E already
showed a comparable renderer wanting 61 of 112. Four per FP multiply is a
number the DSP budget in §5.5 now has to carry.

`rtl/cpu/i960/i960_fpadd.sv` — IEEE-754 double add/subtract, two cycles.

| | ALM | DSP | Fmax |
|---|---|---|---|
| `i960_fpadd` (double) | **785** | 0 | 51.89 MHz |
| `i960_fpmul` (double) | 326 | 4 | 64.02 MHz |
| `i960_fpdiv` (double) | 319 | 0 | 66.15 MHz |
| `i960_fpsqrt` (double) | 249 | 0 | 89.90 MHz |
| `i960_fpmisc` (cmp/cvt/round/scale/logb) | 1,252 | 0 | comb |
| `i960_fpcvt` (single <-> double) | 175 | 0 | comb |
| **FPU total so far** | **3,106** | **4** | limited by `fpadd` at 51.89 |
| Model 1 `fp_add` (single) | 411 | 0 | 76.35 MHz |
| Model 1 `fp_mul` (single) | 144 | 1 | 116.85 MHz |

The divider is restoring, one quotient bit per cycle, 56 cycles. That is slow
and it does not matter: the reference charges 35 cycles for `divr` and 77 for
`divrl`, so it sits inside the budget the timing model already assumes. A
radix-4 or Newton-Raphson unit would be faster and would cost DSP blocks, which
M2-E's finding about the renderer makes the wrong currency to spend.

Its bug was uniform rather than rare: shifting the remainder **before** the
first compare computes `2*fa/fb`, so every result came out exactly one binade
too large. Restoring division compares first, then shifts. Caught by `1 / 1`.

2.07 M checks per seed across three seeds, plus 450 specials and **79,916
near-cancellation pairs** — operands within a few ulps of each other, generated
deliberately because uniform random almost never produces massive cancellation
and that is where an adder is most likely to be wrong.

Model 1's M0 recorded `fp_add` as the block holding its whole TGP's critical
path, and at 51.89 MHz this one is the slowest block in P1 so far. That is the
same pressure at double width, and the same fix — splitting it from two stages
to four — is available when a measurement asks for it.

#### Three rounding bugs, and where each hid

Worth recording individually because each was invisible to a different part of
the suite:

- **Leading-zero target off by one.** `lz = 56 - i` placed the leading one at
  bit 56 instead of 55, halving every result. Caught immediately by `0 + 1`.
- **Rounding carry mishandled.** When rounding carries into bit 52 the mantissa
  has become exactly 2.0, so the result is exponent+1 with a **zero** mantissa —
  the code shifted the mantissa right instead, giving 1.5 where 1.0 was wanted.
  **The multiplier had the same bug** and its six million checks had never hit
  the case; it was fixed in both.
- **Sticky lost on the carry shift.** When an addition carries out, the `>> 1`
  normalisation drops bit 0 — the sticky position. That turns "slightly more
  than half an ulp" into an exact tie, which rounds to even instead of up and
  lands one ulp low. **One failure in ~90,000 random pairs**, on the carry path
  only, and invisible to every directed case.

The last one is the useful lesson: the specials and the cancellation sweep both
passed clean while it was present. It took uniform random volume to surface a
one-in-90,000 path, and then a hand-worked numeric trace to locate it — reasoning
about the design had already produced two wrong diagnoses.

**Deviations recorded rather than discovered later.** Subnormal operands and
results are flushed, exponent overflow becomes infinity and underflow becomes
zero. The host implements subnormals properly, so a program that produces one
**will** diverge; the harness excludes them so the suite measures the
multiplier rather than a known difference. Rounding is round-to-nearest-even
only, which is what the reference's host mode does.

### 8.2 Transcendentals — the oracle runs out a third time

**The reference computes transcendentals with the host's `libm`**:

```cpp
case 0xc: // sinr
    set_rif(opcode, sin(t1f));
```

`libm` is not correctly rounded, differs between platforms and versions, and
cannot be reproduced in RTL without reimplementing its exact algorithms. So for
the transcendental group there is **no bit-exact oracle available at any
price** — a different position from §2.2's FPU precision problem, which at
least had a defined answer to aim at.

**Decision: bit-exact to the reference.** Taken deliberately, with the cost
understood: it ties this core's transcendental results to one `libm`'s
algorithms, and a different host would change what "correct" means.

**Not all of the group needs that.** Several operations are exactly specified by
IEEE-754, so a correct implementation is bit-exact *by definition* rather than
by imitation — and the host produces the same answer for the same reason:

| exactly specified | needs the reference's own algorithm |
|---|---|
| `sqrtr`, `sqrtrl` — IEEE requires correct rounding | `sinr`, `cosr`, `tanr` |
| `cmpr`, `cmprl` | `atanr`, `atanrl` |
| `roundr`, `roundrl` | `logr`, `logepr`, `logrl` |
| `remr` — IEEE remainder | `expr`, `exprl` |
| `logbnr`, `logbnrl` — exponent extract | |

The `r` forms help further: they round the double result back to **single**, and
a correctly-rounded single result matches a correctly-rounded double rounded to
single in all but vanishingly rare cases.

#### `sqrt`, and why its bugs were harder to read than the divider's

`rtl/cpu/i960/i960_fpsqrt.sv` — 249 ALM, no DSP, 89.90 MHz, 56 cycles against
the reference's 104. Digit-by-digit, no multiplier. 603,516 checks per seed
across three seeds plus every perfect square to 3999 and a sweep of both
exponent parities. Zero mismatches.

Two bugs, and the second is worth keeping:

- **Exponent parity inverted.** The bias is 1023, which is *odd*, so an odd
  biased exponent means an **even** unbiased one. Having that backwards swapped
  both branches and every result was wrong by a factor of sqrt(2).
- **One radicand bit per step instead of two.** Square root consumes two bits
  per step and shifts the remainder by two, with a trial subtrahend of
  `4*root + 1` — division consumes one and uses `2*root + 1`. Reusing the
  divider's shape looked right and produced roots wrong by a *non-obvious*
  factor rather than a clean binade, which made the failures much harder to read
  than the divider's uniform "everything is 2x too large".

#### The rest of the exactly-specified group

`rtl/cpu/i960/i960_fpmisc.sv` — `cmpr`/`cmprl`, `logbnr`, `cvtir`/`cvtilr`,
`cvtri`/`cvtzri`, `roundr`, `scaler`/`scalerl`. 1,252 ALM, combinational, no DSP.
3.3 M checks per seed across three seeds, every operation crossed with all four
rounding modes, zero mismatches.

**The rounding mode is AC[31:30] and it is not round-to-nearest-even:** 0 is
round half *away from zero* (C's `round()`), 1 floor, 2 ceil, 3 truncate. Model
1's M0 recorded the same trap on the TGP's `cfxd` — a mode field saying "round
to nearest" usually means half-to-even, and here it does not.

Three bugs, and the last is the one worth carrying forward:

- **`cvtzri` ignored the mode field.** The `z` means "toward zero" and it
  truncates regardless of AC[31:30], where `cvtri` honours it. Exposed by an
  *unused-parameter* warning, not by a test — the constant had no reader because
  the two conversions shared a path they should not have.
- **Sub-unity rounding was short-circuited to zero.** `0.5` rounds to `1`, and
  the fractional field needs more than 52 bits once |x| < 1. Capping it made
  `0.25` look like `0.5`.
- **A harness bug that disabled its own NaN check.** `U{dut->y}.d` initialises
  the *first* union member, so an integer argument is **converted** to double
  rather than reinterpreted. Every "both are NaN, skip" guard built on it was
  silently false. The other four FP harnesses use `U got; got.u = ...` and are
  unaffected — checked rather than assumed.

That last one is the same family as the stale-binary incident: a check that
looks present, reads plausibly, and does nothing. It only surfaced because the
arithmetic underneath it had become correct enough for NaN handling to be the
last thing left failing.

#### Single/double conversion — the operand plumbing

`rtl/cpu/i960/i960_fpcvt.sv`, 175 ALM. Every `r`-form instruction reads through
`u2f` and writes through `f2u`; the `rl` forms use register pairs and need no
conversion.

**This is what makes §8's argument hold.** Computing the `r` forms in double and
narrowing once is equivalent to single-precision arithmetic *because the single
rounding happens here*. Widening is exact — single's significand and exponent
both fit double with room — so nothing is lost on the way in.

2.98 M checks per seed across three seeds, with **every single exponent value**
crossed with four mantissas and both signs, plus narrowing tie cases where bit
28 decides round-to-even. Zero mismatches, and no bugs found — the first FP
block that worked first time, which is what an exact widening and one
well-understood rounding buys.

#### The FP blocks wired in

Single-precision `r` forms only: `addr`, `subr`, `mulr`, `divr`, `sqrtr`,
`logbnr`, `roundr`, `cmpr`, `cvtri`, `cvtzri`, `movr`, `cvtir`, `scaler` — 13
mnemonics, taking coverage to **129 of 163**.

The `rl` forms read and write register **pairs**, which needs four register
reads against the file's two ports and therefore its own fetch sequence. Left
unwired and trapping rather than half-built, the same call as `emul`/`ediv`
before the pair writes existed.

`fp0`-`fp3` exist as four 64-bit registers, with the literal forms selecting
them, `0x16` meaning 1.0 and anything else 0.0. A "literal" destination writes
an FP register rather than a general one.

| | ALM | DSP | Fmax |
|---|---|---|---|
| `i960_top` before FP | 3,812 | 3 | 42.94 MHz |
| **`i960_top` with FP** | **6,685** | **7** | **25.61 MHz** |

**Fmax fell to 25.61 MHz**, which matters: §4.3's table says a 2-CPI design
needs 25-33 MHz, so this is now at the very bottom of the acceptable band with
nothing spare. The FP adder was already the slowest block at 51.89 MHz
standalone, and assembling it behind the same shared operand muxes as everything
else has cost more. **This is the first measurement that makes the optimisation
backlog urgent rather than deferred** — item 1, moving the register file to a
registered read, targets exactly the path these operand muxes feed.

#### The FP-register gap — half closed, and the half that is not is recorded

Lockstep now reads `fp0`-`fp3` from the DUT and compares them against the
reference every retire, alongside the 32 general registers, AC and IP.

**It is not yet proven to have teeth, and until it is, treat it as absent.**
Three mutations that should have tripped it — writing to the wrong FP register,
dropping the write entirely, and finally storing a literal `0xDEADBEEFDEADBEEF`
— all passed. Something between the DUT's FP-register write and the harness's
read is not connected, and it has not been found yet.

Closing this uncovered a real bug elsewhere, which is why the mutation testing
was worth doing even without a result. The generator packed each FP opcode as
three hex digits and extracted the opcode with `sel >> 8`, so `0x78f` produced
opcode **`0x07`** — invalid, trapping immediately. **Every "FP op" the suite had
been running was actually an invalid-opcode trap**, and the 150 the first
counter saw were `emul`/`ediv` arriving from a different generator class. After
the fix, 312 FP operations execute per run and 43 of them target an FP register.

So the position is: the FP arithmetic is verified exhaustively block by block,
the FP instructions now genuinely execute under whole-CPU lockstep and agree on
every general register, AC and IP — and the FP register file itself is compared
by code that has not yet been shown to work. **That last clause is the honest
one and it should stay in this document until a mutation fails.**

## 9. Known unverifiable

**The FPU has no bit-exact oracle.** MAME declares `double m_fp[4]`, modelling
four 80-bit extended registers as host doubles (§2.2 of the design study). An LLE
80-bit FPU cannot be lockstep-verified against it.

Decide explicitly and record the decision — do not let it be made by default:

- verify against a software 80-bit reference (`long double` on x86 is 80-bit, and
  is the cheapest path to one), or
- implement 64-bit and document the deviation.

The first is preferred and probably not much harder. It is also the only option
that makes criterion 2 meaningful for FP.

---

## 10. Verification status

### Step 1 — decoder. Done.

`rtl/cpu/i960/i960_dec.sv` against `sim/i960/i960_dec_ref.h`, three passes:
exhaustive over opcode byte x MEMB mode x sub-format (32,768 vectors), directed
at the encoding's real boundaries (86), and random.

| Run | Vectors | Field checks | Mismatches |
|---|---|---|---|
| seed 1 | 10^7 | 200,657,080 | 0 |
| seeds 2, 7, 12345 | 10^8 each | 2,000,657,080 each | 0 |

Twenty fields compared on every vector, not just the field under test — a
decoder that answers correctly and corrupts a neighbour is still broken.

### Step 2 — integer ALU. Done.

`rtl/cpu/i960/i960_alu.sv` against `sim/i960/i960_alu_ref.h`. 37 operations across
REG opcodes `0x58`-`0x5b`: logic, bit, shift, arithmetic, compare and carry.

Three passes: exhaustive over all 64 `op`/`op2` pairs including unimplemented
ones so `valid` is checked across the whole space; directed at shift counts
either side of 32, carry and borrow pairs, every bit position, `scanbyte` lane
matching and the `concmp` skip condition; then per-opcode random with a biased
operand pool, because uniform 32-bit random almost never produces `0`, `1`, `-1`,
`0x80000000` or a shift count under 32 — which is where every one of these
operations changes behaviour.

| Run | Per op | Field checks | Mismatches |
|---|---|---|---|
| seed 1 | 10^6 | 142,007,232 | 0 |
| seeds 2, 7, 12345 | 10^7 each | 1,420,007,232 each | 0 |

Two behaviours that look like RTL bugs and are not, both replicated deliberately:

- **Shift counts are not masked to five bits.** The reference tests `t1 >= 32` on
  the full 32-bit value, so `shlo` by 100 gives zero rather than a shift by 4.
  Masking is the obvious implementation and would diverge on every out-of-range
  count. `rotate` and the bit operations *do* mask; the shifts do not.
- **`addi` and `subi` do not detect overflow.** The reference marks them
  `// #### overflow` and leaves them identical to `addo`/`subo`. Inventing
  overflow here would diverge from the only oracle there is.

**One deliberate divergence: `addc`/`subc` carry.** Design study §2.3. The RTL
implements hardware carry; MAME's never sets it. `make test_i960_alu_carrybug`
is a standing test that the divergence stays exactly where it is claimed — it
**fails if the RTL stops diverging**.

### Step 3 — register file and register cache. Done.

`rtl/cpu/i960/i960_regs.sv`. 16 locals and 16 globals in flip-flops, four saved
frames in MLAB, spill and fill to external memory beyond four frames, and the
`call`/`ret`/`flushreg` sequencing.

Compared against the reference on **all 32 architectural registers and the
external memory operation stream**, after every frame operation. The stream is
the point (§2.2): depth and the spill condition are invisible in the registers.

| Run | Ops | Checks | Cycles | Mismatches |
|---|---|---|---|---|
| directed | depth 0-8, flushreg at every depth, type-7 call | — | — | 0 |
| seed 1 | 20,000 | 733,523 | 335,644 | 0 |
| seeds 2, 7, 12345 | 200,000 each | ~7.4 M each | ~3.5 M each | 0 |

**Two design decisions worth keeping, both with the reasoning in the file:**

- **The frames are copied, not banked.** The obvious optimisation — five frames
  in one memory, `call` becomes a bank-pointer increment — is wrong here, and
  subtly. MAME copies the locals into the cache and *does not clear them*, so
  the callee inherits the caller's register values. A banked design would hand
  the callee whatever the last call at that depth left behind. Both are
  "undefined" to a compiler and different to a lockstep comparison. The copy is
  made cheap instead of skipped: the cache is four words wide, so a frame moves
  in 4 cycles rather than 16, inside the 9 the reference charges for `call`.
- **MLAB, not M10K.** 2,048 bits would fit one M10K, but §5.6 says M10K is the
  resource under pressure and ALM has headroom. `ramstyle = "MLAB"` spends LUTs
  deliberately. Explicit tag so a regression is a build error.

**The harness was mutation-tested**, because a stateful block passing first time
deserves suspicion. Five deliberate faults, all caught:

| Mutation | Caught by |
|---|---|
| spill one frame too early (depth 3) | memory op count, 16 vs 0 |
| spill base masked `~0x7f` not `~0x3f` | memory op 16 address |
| spill words written in reverse order | memory op 0 address |
| RIP saved off by one word | `r2/RIP` |
| `flushreg` leaves depth 1 not 0 | memory op count on the following `ret` |
| PFP keeps the low 3 bits of FP | `r0/PFP` |

Note two of six are visible **only** in the memory stream, which is the argument
for comparing it. A seventh mutation — dropping the `fp_masked` use entirely —
never reached the test: lint rejected it as an unused signal, which is why
UNUSEDSIGNAL is not suppressed.

### Step 4 — addressing and load/store. Done.

Two modules, both combinational.

`rtl/cpu/i960/i960_agu.sv` — MEMA and the seven MEMB modes. The port is 14 bits,
not 32: everything above bit 13 selects registers the *caller* fetches, and
passing the whole word would leave 18 bits unread.

`rtl/cpu/i960/i960_ldst.sv` — width, sign versus zero extension, byte-lane
placement and store byte enables. The signed/unsigned split is a table rather
than an arithmetic expression on opcode bit 6: `ldob`/`ldib` and `ldos`/`ldis`
differ only in that bit, which is exactly the kind of thing that folds into a
neat expression and is subtly wrong.

| Module | Coverage | Field checks | Mismatches |
|---|---|---|---|
| `i960_agu` | structural + directed + 5e6 random | 14,690,983 | 0 |
| `i960_agu` | 5e7 random x 3 seeds | ~1.47e8 each | 0 |
| `i960_ldst` | **exhaustive** 256 opcodes x 4 offsets x patterns, + 2e6 random | 19,041,842 | 0 |

Directed coverage targets the three things that read wrongly in the reference:
MEMB mode 5 adds the **post-increment** IP (an off-by-four is a silently wrong
target, not a crash); the MEMA offset is **zero-extended**, not signed; and a
scaled index discards bits shifted past 32.

**Unaligned access is deliberately not handled here.** The reference splits an
unaligned word or dword into byte accesses assembled little-endian, which needs
several bus cycles. `i960_ldst` raises `unaligned` and leaves the sequencing to
the bus unit in step 5.

**A harness bug masqueraded as an RTL bug**, and it is worth recording because
the symptom was convincing: 2,811,643 mismatches, all showing `ea` as zero. The
cause was an edit that inserted a `//` comment mid-line in the testbench,
swallowing the two operand assignments that followed it on the same line. The
RTL was correct throughout. **When a brand-new harness reports mass failure on
its first run, suspect the harness before the design** — the reverse is the
common case only once the harness has passed something.

### Measured on the real device — partial M2-D

Quartus Prime Lite 17.0.0 Build 595, `5CSEBA6U23I7`, virtual pins, I/O paths
cut. `make quartus_all`. **This is not M2-D**: the sequencer, I-cache, bus and
FPU do not exist yet, so this is the cost of steps 1-4 and not of the CPU.

| Module | ALM | Registers | MLAB bits | DSP | Fmax |
|---|---|---|---|---|---|
| `i960_dec` | 103 | 0 | 0 | 0 | comb |
| `i960_alu` | 852 | 0 | 0 | 0 | comb |
| `i960_regs` | 1,655 | 1,261 | 2,048 | 0 | **94.86 MHz** |
| `i960_agu` | 252 | 0 | 0 | 0 | comb |
| `i960_ldst` | 126 | 0 | 0 | 0 | comb |
| `i960_lsu` | 241 | 188 | 0 | 0 | **142.57 MHz** |
| `i960_memmap` | 35 | 0 | 0 | 0 | comb |
| `i960_icache` | 472 | 861 | 0 (4,096 M10K bits) | 0 | 84.97 MHz |
| **Total** | **3,736** | 2,310 | 2,048 MLAB + 4,096 M10K | 0 | |

Against the 7,000-13,500 estimate for the whole i960 including a 2,500-6,000
FPU, 2,988 for these five blocks tracks toward the lower half. **It is not
evidence of that yet** — the sequencer and pipeline control are missing and
assembly costs more than the sum of parts.

Note `i960_regs` clears the gate's >90 MHz on its own, which is worth exactly
what a standalone number is worth: Model 1's M0 recorded that isolated Fmax is
pessimistic because the critical path terminates at virtual pins with nothing to
retime against, and that the instance-level figure is what a gate should read.

#### The register cache did not infer, and only Quartus could say so

Written with the array read directly inside the control FSM, the build reported:

```
Info (276009): RAM logic "rcache" is uninferred due to unsupported
               read-during-write behavior
Total MLAB memory bits : 0
```

It became flip-flops. The cost, measured before and after the fix:

| | ALM | Registers | MLAB bits | Fmax |
|---|---|---|---|---|
| cache in flip-flops | 2,355 | 3,303 | 0 | 68.44 MHz |
| cache in MLAB | **1,655** | **1,261** | **2,048** | **94.86 MHz** |

**30% of the module's area and 26 MHz**, from a memory idiom that simulates
identically either way. Every test passed in both configurations. This is the
standing rule earning its place twice over: only a Quartus build can tell you
where storage landed, and the register count is what shows it first.

The fix is a dedicated write port and a dedicated *registered* read port, each
with its own address, rather than indexing the array inside the FSM. That costs
a cycle of read latency, so the fill and flush paths split into issue and
capture states.

Restructuring introduced a second bug the harness caught immediately: the flush
read address was held only for the cycle that issued it, and the array registers
its output every cycle, so the data moved under the flush while the addresses
stayed correct. It surfaced as **right address, wrong frame's word** — visible
only in the memory stream comparison, which is the argument for having it.

### Step 5 — bus, burst and I-cache. Done.

`rtl/cpu/i960/i960_lsu.sv`, `i960_memmap.sv` and `i960_icache.sv`.

The LSU turns one architectural load or store into the exact sequence of bus
transactions the reference performs, in the same order — which is
architecturally visible and therefore not free to optimise. Three behaviours
drive it, and two are invisible in the final register value:

- **Unaligned access splits into bytes.** The reference does not do a wide
  access and rotate; it issues individual byte reads at `addr`, `addr+1`, ...
  and assembles little-endian. An unaligned dword is four bus transactions, and
  a device with side effects sees four accesses.
- **Multi-word forms advance the address only in burst regions.**
  `if (pack.second & BURST) t1 += 4;` — in a non-burst region every word of
  `ldl`/`ldt`/`ldq` comes from the SAME address. That is how the coprocessor
  FIFO at `0x00884000` is drained, and the reference says so. Getting it wrong
  is silent: a burst-flagged FIFO returns four copies of the head word and the
  geometry stream quietly fills with repeats.
- **The destination register group aligns down** — `ldl` uses `srcdst & 0x1e`,
  `ldt` and `ldq` use `& 0x1c`. `ldt` moves three words but still aligns to
  four. Added to `i960_ldst` as `reg_mask`; it was missing.

`i960_memmap` decodes the §5 table into that burst flag. Regions not listed are
non-burst, which is the safe default: treating a burst region as non-burst costs
cycles, while treating a FIFO as burst corrupts data.

| Coverage | Requests | Checks | Mismatches |
|---|---|---|---|
| exhaustive offset x size x words x direction x burst | 384 | — | 0 |
| directed non-burst `ldq` FIFO drain | 1 | — | 0 |
| random, seed 1 | 200,000 | 1,265,853 | 0 |
| random, seeds 2/7/12345 | 1,000,000 each | ~6.3 M each | 0 |

Mutation-tested. Five faults, all caught: burst sense inverted, address always
advancing, address never advancing, an unaligned word split into 2 bytes instead
of 4, half-alignment tested on the wrong bit, and byte assembly big-endian.

#### The I-cache has no oracle and needs none

512 bytes, direct-mapped, 16-byte lines. **MAME models no instruction cache at
all** — its `m_cache` is an address-space accessor, and IAC `0x89`, "invalidate
internal instruction cache", is logged rather than executed. So this block is
architecturally invisible: it changes cycle counts and nothing else, and it
cannot diverge from a reference that has nothing to diverge from.

It is therefore verified by **transparency** — every fetch must return exactly
what external memory holds — checked on every fetch rather than only on misses.

**Transparency alone is not enough, and that is a trap worth naming.** A cache
that never hits is perfectly transparent and completely useless, and a
correctness-only harness passes it without complaint. So the miss rate is
asserted as well:

| Pattern | Requirement | Measured |
|---|---|---|
| sequential walk, 4x cache size | ~0.25 (a 16-byte line serves four dwords) | **0.250** |
| second pass over cache-sized data | zero misses | **0** |

Mutation-tested, and the two checks divide the work between them: a fill that
never marks its line valid is caught by the **miss rate** (1.000, out of
bounds), while an inverted tag comparison, a word select using `~addr[3:2]` and
a line index one bit too narrow are caught by **transparency**.

The standing assumption is that instruction memory does not change underneath
the cache. Model 2 executes from ROM, so there is no self-modifying code and no
DMA into the instruction stream. **If that ever stops being true this block
becomes wrong, and silently** — which is why `inval` exists although nothing
drives it yet.

Memory inference came out as intended, and the report says so explicitly:
`cdata` inferred to M10K (4,096 block memory bits) while `ctag` is "uninferred
due to asynchronous read logic", which is correct — tags are compared
combinationally on every fetch and must be flip-flops. M10K for the data is the
opposite call to the register cache's MLAB, for the opposite reason: 4,096 bits
is a third of one M10K but about seven MLABs, and §5.6's pressure is on blocks
rather than on bits.

**`i960_icache` reads 84.97 MHz, under the gate's 90.** The tag compare feeding
the hit decision is the obvious suspect. Not addressed yet, and recorded rather
than glossed.

#### A third Quartus-only syntax rejection

The LSU passed verilator and yosys and failed the build outright:

```
Error (10768): range must be the final index in the indexed name
```

`bus_rdata[{cur_addr[1:0], 3'd0} +: 8][7]` — indexing the result of a
part-select. Quartus 17.0 will not have it. Same family as Model 1's rule about
bit selects on a function call, same fix: name the intermediate.

That is now three constructs this project has found which one toolchain accepts
and another rejects — module-header package import, enum-typed port, and
indexing a part-select — which is the whole argument for `make synth` and for
running the fitter early rather than at the end.

### Integration — the assembled design, and the number that matters

`rtl/cpu/i960/i960_top.sv` wires all eight blocks together behind one arbitrated
bus port, driven by a multi-cycle sequencer. Every port is connected and nothing
dangles, so the fitter sees representative loading.

**It is not the design §4.4 requires.** That section is unambiguous that a
multi-cycle FSM does not close timing. This sequencer is multi-cycle; its job is
to connect the blocks, expose the assembled critical path, and be the skeleton
the pipeline replaces.

| | ALM | Registers | MLAB | Fmax |
|---|---|---|---|---|
| sum of the eight parts | 3,736 | 2,310 | 2,048 | 84.97 - 142.57 MHz |
| **assembled `i960_top`** | **3,155** | 1,915 | 2,048 | **43.91 MHz** |

Two results, and the second is the important one.

**Area went down by 581 ALM on assembly.** The fitter optimises across module
boundaries and removes what nothing consumes — including the duplicated data
path noted below. A sum of per-module figures is therefore an over-estimate
here, not the under-estimate one might assume.

**Fmax roughly halved against the slowest individual block.** This is Model 1's
M0 finding reproduced exactly: "no individual block is near this — the critical
path is created by assembly". Per-module Fmax cannot show it, because in
isolation the path terminates at virtual pins with nothing to retime against.

`make quartus_paths` names the endpoints rather than guessing:

```
SLACK 17.226   FROM i960_regs:u_regs|loc[10][3]   TO wd[9]
```

Register-file read → operand mux → ALU → writeback register, all combinational
inside one FSM state. **That is precisely where a pipeline stage boundary goes**,
which turns §4.4 from an argument into a measurement: the requirement to
pipeline is now empirical.

Sanity on throughput, and it agrees with §4.4's table. At 43.91 MHz with this
sequencer's ~6 cycles per instruction, the core retires ~7.3 M instr/s against
the 12.5-16.7 M/s a 25 MHz i960 needs — roughly half, from the direction §4.4
predicted.

#### A duplicated data path, found by integration

Lint at the top level showed `ls_ldres`, `ls_stdata` and `ls_stbe` with no
consumer. That is not dead-signal noise: `i960_lsu` performs its own sign
extension and lane placement, because the unaligned path has to assemble bytes
itself, which left `i960_ldst`'s data path with nothing to drive. **One of the
two should own it.** Recorded rather than suppressed; the fitter already deleted
it, which is part of why assembly came in smaller.

### What the assembled number does and does not bound

**3,174 ALM is 55% of an instruction set, not an i960.** Recounted after the
COBR fix:

| | mnemonics | |
|---|---|---|
| executed | **129** | 79% |
| traps correctly (`fault<cc>` taken, `modpc`, `calls`, `synmov`) | 12 | 7% |
| **absent** | **34** | **21%** |

Counted from the source rather than by hand — `execute_op` dispatches **163**
distinct mnemonics, not the 159 an earlier hand-tabulation in this document
claimed. The earlier figure undercounted the multiply and divide blocks.

Absent, by cost driver:

| mnemonics | block |
|---|---|
| **38** | **the entire FPU** — transcendental, conversion/move, arithmetic |
| 6 | `emul`, `ediv`, conversions, `scalerl` — pair writes, see below |
| 5 | `spanbit`, `scanbit`, `dmovt`, `modac`, `modpc` |
| 4 | `mov`, `movl`, `movt`, `movq` |
| 2 | `calls`, `flushreg` |
| 2 | `synmov`, `synmovq` |

Projecting from the study's own per-block figures:

| | ALM |
|---|---|
| assembled today | 6,685 |
| `mov` family, `spanbit`, `modac`, `calls`, `synmov` | +300 .. 600 |
| `fault<cc>`, fault handling, interrupts | +200 .. 500 |
| pipeline: hazards, forwarding, stalls | +1,500 .. 3,000 |
| **FPU, 38 mnemonics** | **+2,500 .. 6,000** |
| **projected complete i960KB** | **8,185 .. 11,185** |
| study §5.2 estimate | 7,000 .. 13,500 |

The projection straddles the study's range and overshoots its ceiling slightly.
Nothing here contradicts §5.2; it narrows nothing either.

#### What it does to the fit question

§5.5 allows the i960 and the renderer **25,009 ALM together** when the rest of
the core lands optimistically. So:

| i960 lands at | renderer may use | against its 15,000-25,000 estimate |
|---|---|---|
| 8,185 (best) | 16,824 | fits if the renderer is near its floor |
| 11,185 (worst) | 13,824 | fits if the renderer is near its floor |

**Both blocks have to land low.** An i960 at the top of its range leaves the
renderer less than its most optimistic estimate, and that is before the M10K
question in §5.6. This is the same conclusion §9 already reached, now with one
of the two numbers partially grounded instead of wholly estimated.

#### What 3,174 is actually good for

Three things, and none of them is an answer to the fit question:

- **A floor.** The integer datapath cannot cost less than this.
- **A proof the parts compose** — eight blocks, one arbitrated bus, lint-clean
  on three toolchains, building on the real device, lockstepped against a
  whole-CPU reference.
- **A located critical path**, so the pipeline work is targeted.

Two further reasons the number moves:
Two further reasons the number moves:

- **The 581 ALM assembly saved will not repeat.** It came from the fitter
  deleting logic nothing consumed — chiefly the duplicated `i960_ldst` data
  path. Once everything has a consumer there is nothing left to delete.
- **DSP usage is currently zero.** Integer multiply and the FPU's iterative
  27x27 multiply will both claim blocks. 112 exist and Model 1 uses 49, so this
  is headroom rather than risk — but it means ALM alone stops being the whole
  picture.

**On Fmax, two forces oppose each other and the product is what matters.**
Pipelining splits the measured critical path and should raise 43.91 MHz
substantially. Against that, §4.1 expects 15-25% degradation at high
utilization, and Model 1's M0 recorded the trap directly: retiming raised its
Fmax from 51.47 to 72.17 MHz, a 40% gain, while *also* raising cycles per
instruction from 7.71 to 9.83 — so the net throughput gain was far smaller than
the Fmax figure suggested. **Fmax alone is not the metric; Fmax divided by CPI
is.** Quote both or neither.

### Where the area actually is, and what is worth optimising

Per-entity, from the assembled fit report. Optimising by intuition would have
gone after the wrong block.

| Instance | ALM assembled | standalone | note |
|---|---|---|---|
| **`i960_regs`** | **1,547.6** | 1,655 | **49% of the CPU** |
| top-level glue | 656.1 | — | sequencer and arbiter |
| `i960_alu` | 473.6 | 852 | |
| `i960_agu` | 163.4 | 252 | |
| `i960_lsu` | 140.6 | 241 | |
| `i960_icache` | 106.0 | 472 | `inval` tied off — see below |
| `i960_memmap` | 37.4 | 35 | |
| `i960_dec` | 26.7 | 103 | |
| `i960_ldst` | **3.0** | 126 | duplicated data path deleted |

Two of these are not what they look like. `i960_ldst` collapsing to 3 ALM
confirms the duplication noted above — the fitter deleted a data path nothing
consumed. And `i960_icache` dropping from 472 to 106 is **deferred cost, not a
saving**: the top ties `inval` to zero, so the 32-entry invalidate loop was
optimised away. It returns the moment anything drives it.

**The register file is the target, and the reason is structural.** It holds 32
registers in flip-flops with two *combinational* read ports, which is two 32-bit
32:1 multiplexers — and the measured critical path runs straight through one of
them (`loc[10][3]` → `wd[9]`). Moving the file to a memory with a **registered**
read would delete both multiplexers and cut that path. It is also what a
pipelined front end wants anyway, which is why it belongs to step 6 rather than
being a standalone tidy-up: read latency is a pipeline-structure decision.

Second target is `i960_alu` at 473 ALM assembled, where six shift forms, four
comparators and three adders are described separately and could share a barrel
shifter and one adder/subtractor.

#### A measurement that was wrong, and the process fix

A frame-copy width sweep — `W` = 1, 2, 4 words per cycle — appeared to show
W=1 as both smaller and faster. **The numbers were invalid and are retracted.**
`W` is not genuinely parameterised: the index expressions hardcode four rows, so
W=1 and W=2 produce RTL that does not lint. Quartus accepted the width
mismatches verilator rejects and produced plausible figures for a design that
could never run.

That is rule 8 broken — nothing goes to the fitter until it is clean locally —
and the fix is systemic rather than a resolution to be more careful:
**`make quartus` now depends on `lint_$(MOD)`**, so an unlintable module cannot
reach the fitter at all. Verified by breaking the RTL deliberately and watching
the build refuse.

The lesson generalises past this project: **a tool being more permissive than
your linter is not a convenience, it is a way to be confidently wrong.** Quartus
will not tell you the RTL is nonsense; it will tell you how many ALMs the
nonsense costs.

### Optimisation backlog — deferred deliberately, with evidence

Nothing here is speculative; each item has a measurement behind it. Deferred to
after step 6 because every one is shaped by a decision the pipeline has to make
anyway, and doing them first means doing them twice and re-verifying twice.

**Revisit this section when step 6 lands.**

| # | Item | Evidence | Est. | Blocked on |
|---|---|---|---|---|
| 1 | ~~Register file to a memory with a **registered** read~~ **DONE, and the estimate was wrong** | measured critical path was `ra1[2]` → `wd[28]`, through a combinational 32:1 read mux, the ALU/FP result muxing and into writeback | predicted "large"; **delivered 25.29 → 27.3 MHz, +8%** | — |
| 2 | Share the ALU datapath | 473 ALM assembled; six shift forms, four comparators and three adders described separately | moderate | none, but cheap to fold into the pipeline pass |
| 3 | Delete `i960_ldst`'s dead data path | collapsed 126 → 3 ALM on assembly; `i960_lsu` re-implements extension and lane placement because the unaligned path must assemble bytes itself | ~0 area, real clarity | decide which module owns it |
| 4 | Genuinely parameterise the frame-copy width `W` | the sweep that motivated it was invalid — the index expressions hardcode four rows | unknown until it can be measured | must lint at every W before any figure is believable |
| 5 | Retime the I-cache tag compare | 84.97 MHz standalone, under the gate's 90 | unknown | may be moot once the pipeline sets the clock |

**Item 1 is done and it did not deliver.** It was the best-evidenced item in
this table — 49% of the CPU, and the measured critical path ran straight through
it — and cutting it moved Fmax by 8%. The path simply moved from `ra1[2]` →
`wd[28]` to `rd1[29]` → `wd[26]`: the register read was the *first* half, and
the second half is the execute datapath, operand through ALU and the result
multiplexing into writeback. Slack went 0.451 → 3.370, so the change was real;
it just was not where the remaining time is.

Two things follow, and the second is the one that matters:

- **The read latency cost zero cycles.** Every read address was already
  presented in the state before its consumer, so `i960_top` drives `ra1`/`ra2`
  combinationally and the file supplies the cycle the sequencer used to. The
  lockstep run takes the same 65,630 cycles either way. This was the item the
  table called "blocked on a step-6 decision"; the decision turned out to be
  free.
- **90 MHz is not reachable by optimisation.** From 27.3 that is a 3.3x
  reduction in path delay, and there is no single mux left that is worth 3.3x.
  It requires the execute path split across stages — the pipeline, not the
  backlog. **Items 2-5 should not be attempted as Fmax work**; at best they are
  area and clarity, and item 5 was already flagged as possibly moot.

Two items are **deferred cost rather than savings**, and must not be read as
headroom: `i960_icache` shows 106 ALM only because the top ties `inval` to zero
and the 32-entry invalidate loop was optimised away, and the 581 ALM that
assembly saved came from deleting logic nothing consumed, which cannot repeat
once everything has a consumer.

### Step 6 — whole-CPU lockstep. Started, and it earned its keep immediately.

`sim/i960/i960_cpu_ref.h` is a whole-CPU model assembled from the per-block
references already verified against their own DUTs — the method Model 1 used for
`mb86233_ref`. It adds only fetch, dispatch and the control-flow instructions,
which have no block of their own.

`sim/i960/tb_i960_top.cpp` runs generated programs on both and compares **all 32
registers, AC and IP after every retire**.

Instruction-fetch bus traffic is deliberately **not** compared. The DUT fetches
through a 16-byte-line cache while the reference reads single words, so the two
streams differ by design — that is the cache working, not a divergence. Data is
compared through memory contents instead.

| Run | Programs | Retires | Checks | Mismatches |
|---|---|---|---|---|
| seed 1 | 200 | 10,498 | 356,932 | 0 |
| seeds 2, 7, 12345 | 3,000 each | ~157,000 each | ~5.33 M each | 0 |

#### It found the COBR defect on the first retire

Predicted from reading the code, confirmed by measurement:

```
MISMATCH retire 0  AC  got=00000000 want=00000001
MISMATCH retire 0  IP  got=00000004 want=00000008
```

`cmpob<cc>` and `cmpib<cc>` **compare and then branch on the result of that
compare**. The sequencer branched on whatever `AC` already held and never
performed the compare. `test<cc>` was treated as a branch when it writes a
register and does not branch at all. Both are now correct, and `fault<cc>`
traps rather than silently falling through.

The compare is routed **through the existing ALU** — `0x5a.0` is `cmpo` and
`0x5a.1` is `cmpi`, which is exactly what COBR needs — costing two operand
muxes instead of a second 32-bit comparator. That is backlog item 2 done early
because the fix required touching the same logic.

Also reproduced rather than tidied: `bxx` and `bxx_s` mask the IP after a taken
branch (`IP &= ~3`) while plain `b`, `bbc` and `bbs` do not.

#### And one defect in the harness, not the design

The first fix left a failure at retire 1 that looked like a lost writeback. It
was the harness sampling one cycle early: **the IP moving is not the same as the
instruction having retired.** `we` is registered in the execute state, so the
write reaches the register file one edge *after* the IP updates. Comparing on
the IP change alone reads a stale register.

#### Coverage, stated plainly

The generator emits REG `0x58`-`0x5b`, `test<cc>`, `cmpob<cc>`, `cmpib<cc>`,
`bbc` and `bbs`. **It does not yet emit MEM, `call`/`ret`/`b`/`bal`, or the
multi-word load/store forms**, so the frame machinery and the LSU are verified
by their own harnesses but not yet in situ. That is the next extension, and it
matters: `call`/`ret` under a running program is where the register cache meets
instructions in flight.

### Integer multiply, divide, remainder and modulo

`rtl/cpu/i960/i960_muldiv.sv` — `mulo`, `muli`, `remo`, `remi`, `modi`, `divo`,
`divi`, plus `emul`/`ediv` in the module though not yet in the CPU.

**372 ALM, 3 DSP blocks, 105.63 MHz.** The first DSP usage in the project: 3 of
112, with Model 1 using 49, so this is the cheap direction. The multiplier is a
plain `*` so Quartus infers DSP; the divider is iterative restoring division at
a cycle per bit, which cannot use DSP but has budget — the reference charges 37
cycles for a divide.

Two simplifications that came out of writing it:

- **One multiplier, not two.** The low 32 bits of an NxN product are identical
  whether the operands are read as signed or unsigned, so `muli` and `mulo`
  differ only in the half they discard and both take the low half. The
  reference computes them with different casts, which is a C++ typing detail
  rather than two operations.
- **A 33-bit divider datapath, not 64.** The partial remainder is always less
  than the divisor, so it fits in 32 bits plus one for the bit shifted in. A
  64-bit comparator and subtractor would be three times the width for no reach.

**A zero divisor is undefined in the reference for every opcode except `divo`**,
which carries an explicit guard its author labelled `// HACK!`. `divi`, `remo`,
`remi` and `modi` have none, so C++ leaves the result undefined. Resolved the
way Model 1 resolved shift counts above 31: implement something deterministic —
quotient 0, remainder = dividend, matching `divo` — and **constrain the fuzz
rather than compare against undefined behaviour**. `divo` with a zero divisor
*is* defined and is compared directly.

**`modi` reads the sign of an overflowed product, and that is not a bug.** The
reference tests `(src2*src1) < 0` on `int32_t`, so the condition is bit 31 of
the *truncated* 32-bit product, not the true sign — the two differ whenever the
multiply overflows, as `0x7fffffff * 3` does. Computing it in `int64_t` looks
tidier and is wrong; the first version of the reference here did exactly that
and the harness caught it.

| Run | Checks | Mismatches |
|---|---|---|
| directed sign/truncation + op space + seed 1 | 648,648 | 0 |
| seeds 2, 7, 12345 at 10^6 | ~3.23 M each | 0 |

Integrated and lockstepped: the CPU is **3,521 ALM, 2 DSP, 44.66 MHz**, with
163,881 retires per seed and zero mismatches. `emul` and `ediv` write a register
pair, which needs the same sequencer support as `movl`/`movt`/`movq`, so `0x67`
still traps on both sides rather than being half-wired.

### `mov`, bit scan and the control registers

Added to `i960_alu`: `mov` (`0x5c.c`), `spanbit`, `scanbit`, `dmovt` and
`modac` (`0x64.0/1/4/5`). No sequencer change — they route through the existing
ALU path, so integration was free. The ALU is now 42 operations and 973 ALM
standalone.

`spanbit` and `scanbit` find the **highest** matching bit: the reference scans
from bit 31 down and breaks on the first hit. Written here as an unconditional
loop from bit 0 up so the last write wins, which gives the same answer without a
`break` — yosys rejects `break` inside a synthesis loop outright, and that is
Model 1's rule rather than a style preference.

**`dmovt` masks AC with `0xfff8`, not `~7`.** Every other site in the reference
uses `~7`; as a 32-bit value this one also clears `AC[31:16]`. Almost certainly
a typo, and it is **reproduced rather than corrected** — unlike the `addc`
carry it still computes the condition code correctly, so it is not demonstrably
non-functional and the oracle wins. The bar set in §2.3 of the design study is
deliberately high, and this does not clear it.

`modac` writes the **old** AC to its destination and then updates AC under a
mask, so it both reads and writes the same architectural state in one
instruction.

Lockstep after integration: 171,610 retires per seed, zero mismatches. The CPU
is **3,626 ALM, 2 DSP, 42.43 MHz** at 103 of 163 mnemonics.

### Multi-word and pair register writes

`movl`, `movt`, `movq`, `emul` and `ediv` — one piece of sequencer work for five
mnemonics. The register file has a single write port, so these take a cycle per
word, with the source read one cycle ahead so the copy runs at one word per
cycle after a one-cycle prologue.

**The destination masks are not uniform, and `emul`/`ediv` have none:**

| | destination |
|---|---|
| `movl` | `srcdst & 0x1e` |
| `movt`, `movq` | `srcdst & 0x1c` |
| `emul`, `ediv` | `srcdst & 0x1f` — **unmasked** |

Unmasked means `emul` with `srcdst = 31` writes `m_r[32]`, one past the end of
the reference's 32-entry array. That is a buffer overrun and therefore
undefined, so the harness never generates it.

The **source** of a `mov` is never masked either, so a misaligned source with an
aligned destination is legal and has to work.

#### A third undefined-behaviour case, and a bug in my own constraint

The reference copies with `memcpy(m_r+t2, m_r+(opcode & 0x1f), n*4)`. **`memcpy`
with overlapping regions is undefined in C** — `memmove` is the defined one. A
forward loop propagates (`r[28]=r[27]`, then `r[29]=r[28]` which is already
`r[27]`), a vectorised or backward copy does not. So overlapping source and
destination joins the zero divisor and the out-of-range shift count on the list
of things the fuzz must not generate.

Constraining it took two attempts, and the first failure is worth recording. A
linear test — `src + n <= base || base + n <= src` — misses **wraparound**:
register numbers are five bits and the copy wraps, so `src = 30, n = 4` covers
indices 30, 31, 0, 1 and collides with `base = 0` while passing the linear
check. The overlap has to be tested on the wrapped index sets.

Lockstep: 164,084 retires per seed, zero mismatches. The CPU is **3,754 ALM,
3 DSP, 45.16 MHz** at 108 of 163 mnemonics.

### CPI, measured — and it is worse than this document assumed

The lockstep harness now reports cycles per retired instruction. Measured on the
assembled design at 45.16 MHz:

| Instruction mix | CPI | M instr/s | vs the 12.5-16.7 needed |
|---|---|---|---|
| ALU only | 7.33 | 6.16 | 2.0x short |
| ALU + 10% multiply/divide | 11.89 | 3.80 | 3.3x short |
| the harness's full mix | 15.86 | 2.85 | **5.6x short** |

**This corrects an estimate made earlier in this document.** The assembled
design was described as doing "~6 cycles per instruction" and being "about half"
the required throughput. Neither was measured. The real base is 7.33 CPI for
pure ALU work, and the multi-cycle divider dominates any mix containing it — a
32-bit restoring division is ~68 cycles, so 10% divides adds ~4.5 CPI on its
own.

Two things follow, and they pull in opposite directions:

- **The synthetic mix is not real code.** No compiled program is 10% divides.
  The honest planning figure is the ALU-only 7.33, not the 15.86 headline.
- **Even 7.33 is 2x short**, and that is before faults, interrupts and the FPU
  add states. The FSM cannot get there by tuning.

#### What the pipeline actually has to achieve

§4.3's "123-164 MHz" is easy to misread: that is what a *9.83-CPI* design would
need. The requirement is **throughput**, and it can be met from either
direction:

| | CPI | Fmax needed |
|---|---|---|
| today | 7.33 | 92-122 MHz |
| 4 CPI | 4 | 50-67 MHz |
| 2 CPI | 2 | **25-33 MHz** |

At the **already-measured 45.16 MHz**, a 2-CPI design delivers 22.6 M instr/s
and a 3-CPI design 15.0 M — both inside the requirement. So the pipeline needs
**low CPI far more than it needs a high clock**, and it can afford to spend Fmax
on hazard logic if that is what buys the CPI. A four- or five-stage design at
1.5-2 CPI clears the requirement at a clock the design already reaches.

That reframing matters for the optimisation backlog too: item 1, moving the
register file to a registered read, costs a cycle of read latency in a
multi-cycle FSM but costs *nothing* in a pipeline, where it is simply a stage.

### Profiling first, then a prefetch — CPI 7.33 to 3.31

**The blocker was not what it was being called.** "The CPU needs a pipeline" was
an assumption; profiling cycles by sequencer state said otherwise:

| state | cyc/instr | share |
|---|---|---|
| `T_FETCH` | 1.07 | 14.5% |
| **`T_FETCH_W`** | **4.27** | **58.2%** |
| `T_DECODE` | 1.00 | 13.6% |
| `T_EXEC` | 1.00 | 13.6% |

**58% of all cycles were waiting for the instruction cache.** Execute was 14%. A
five-stage pipeline would have attacked the 14%.

Two contained changes followed, neither of them a pipeline:

**1. Hold the I-cache fill request.** `bus_req` was registered and dropped after
each word, costing ~3.7 cycles per word of a 4-word line. Holding it across the
line with a combinational address gives one word per ack. CPI 7.33 → 6.58.

**2. Prefetch, predicting sequential.** The request for the next instruction is
issued during *decode* of the current one, so on a hit the sequencer returns
straight to decode and skips both fetch states. A taken branch discards it and
refetches — the misprediction cost is exactly the fetch being avoided, so the
worst case is the old behaviour. Eight-byte forms need the cache port for their
own displacement word and do not prefetch.

| | before | after |
|---|---|---|
| straight-line, cold cache | 6.58 | **4.62** |
| **looping code, warm cache** | 5.26 | **3.31** |
| `T_FETCH_W`, warm | 2.25 | **0.30** |

At the measured 45.53 MHz:

| | CPI | M instr/s | vs 12.5-16.7 |
|---|---|---|---|
| looping code | 3.31 | **13.64** | **inside** |
| cold straight-line | 4.62 | 9.77 | short |

**The requirement is met for code that loops**, which is what game code does.
The cold figure is dominated by a 25% miss rate that is an artefact of the
harness — 60-instruction programs fetched once — and says more about the
generator than the design.

Cost: **45 ALM** (3,754 → 3,799) and Fmax unchanged at 45.53. Lockstep clean at
120,000 retires per seed across three seeds.

#### Two failures worth recording, both mine

The prefetch did nothing on its first two attempts and both diagnoses were wrong
before instrumentation settled it.

- **First attempt: checked only the latched prefetch.** `ic_req` is registered,
  so a request issued in decode has its `valid` arrive *during* `T_FETCH` — one
  cycle after the latch would have caught it. The fix is to check the in-flight
  case as well as the latched one.
- **Second attempt: the code was never inserted.** The edit targeted a comment
  that an earlier COBR fix had already rewritten, so the patch silently matched
  nothing. Two rounds of reasoning about timing were spent on RTL that did not
  contain the feature. **`pf_armed` counted zero the moment it was
  instrumented**, which is what should have been done first.

### Faults, and two bugs the fault work exposed

`faultno` and `fault<cc>` are implemented exactly as the reference has them,
which is not what the names suggest. `faultno` (`0x18`) is a **conditional
branch** — `if(!(m_AC & 7)) m_IP += get_disp(opcode);` — and does not mask the
IP the way `bxx` does. `fault<cc>` (`0x19`-`0x1f`) does nothing when the
condition is false and reaches `fatalerror` when it is true, so the taken case
traps here, which §1 already scoped out.

Adding them was eight mnemonics of easy work that exposed two harder problems.

#### The prefetch had a redirect hazard

Introducing frequent taken branches made the prefetch fail, and the failure was
subtle: a prediction that turns out wrong can leave the I-cache **mid-fill for a
line no longer wanted**. The cache ignores a request while filling, so the
redirect was dropped — and `T_FETCH_W` then accepted the *stale* fill's `valid`
and executed the wrong instruction.

Fixed by only issuing a redirect when the cache is idle. The cost is a few
cycles on a misprediction; the alternative is a CPU that silently executes the
wrong instruction after a branch. Retires per run went from ~24,000 to ~64,000
because the bug had been causing spurious traps.

#### And a bug lockstep could never have caught

`m_IP += 4` happens in the reference's fetch loop **before** `execute_op` runs,
so inside it `m_IP` is already `ip_next`. Every CTRL displacement is therefore
relative to `ip_next`:

```
case 0x08: m_IP += get_disp(opcode);   //  ip_next + (sext24 - 4)  ==  ip + sext24
```

The RTL computed `ip + d_disp`, four bytes short. **So did the reference model.**
They agreed with each other, so no amount of lockstep would ever have reported
it — `b`, `bal` and `call` were all wrong in both, in the same direction.

This is R7 made concrete: *a suite that passes enormously proves the two things
compared agree, not that either is right.* It was found by reading the fetch
loop while chasing something else, and the fix is verified by now generating
`b` and `bal` in the harness — which the previous test set never did, which is
why the bug survived.

#### A process failure, recorded

During the bisect above, `make ... >/dev/null 2>&1` hid a compile error, and
several runs afterwards reported PASS **from a stale binary**. It is the same
shape as running Quartus before lint: a silenced tool reporting success for
something that was never built. `make` output should not be discarded when its
result is being used as evidence.

### What that does not prove

**The reference and the RTL are two expressions by the same author from the same
source.** A misreading of `i960.cpp` appears in both and the fuzz agrees
enthusiastically. Six billion field checks measure internal consistency, not
correctness against Intel's encoding.

The partial mitigation is a genuinely independent cross-check: `i960dis.cpp`'s
`mnemonic[256]` table was written separately from `i960.cpp`'s `execute_op`
dispatch, and our opcode set was built from the dispatch. Comparing them:

- **84 opcodes claimed implemented; none unknown to the disassembler.** No
  opcode was invented.
- **Zero format disagreements** across all 84. The range boundaries at `0x20`,
  `0x40` and `0x80` agree with the table's per-entry format column.
- 11 opcodes the disassembler knows and we deliberately trap: `cmpibno` (0x38),
  `cmpibo` (0x3f), eight REG sub-blocks, and `dcinva` (0xad). This is the
  architectural set exceeding the implemented set, which is §1's stated position
  rather than a gap.

**Still unverified: the field positions.** Bit numbers for `src1`/`src2`/`dst`
literal selects, the MEMB mode and scale fields, and the two displacement widths
all come from `i960.cpp` alone. The disassembler cannot check them because it
was used as the source for none of them. Closing this needs either the i960KB
Programmer's Reference Manual (270567-001, cited in `i960dis.cpp`'s own header)
or real Model 2A program ROM decoding to sensible instruction sequences. **Until
one of those happens, treat field positions as transcribed rather than
verified.**

## 11. Risks specific to this milestone

**No pipelining rehearsal.** M2-F was the cheap way to learn whether a pipelined
CPU of this class closes timing on this part, on a 3,000 ALM block with an
existing test harness. It is deferred to P4 because its source is still moving
(design study §9), so P1 pipelines the largest from-scratch block in the design
with nothing proven ahead of it. Accepted knowingly. If step 7 misses badly, the
retiming lessons in Model 1's M0 document are the closest thing to prior art.

**The register cache interacts with the pipeline**, and §2.1's banked-memory
approach is the mitigation rather than the problem. `call` and `ret` change which
frame the register file addresses; that is a hazard for any instruction in flight
reading a local. Design it in from the start.

**Area is unknown to a factor of two** — 7,000 to 13,500. M2-E gives an R4300i
proxy on this part before any of this is written, which is why it comes first.
