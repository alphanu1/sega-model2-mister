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

`i960.cpp` is a different case from `v60.cpp`, and the difference is checkable
rather than a matter of taste:

| | `v60.cpp` | `i960.cpp` |
|---|---|---|
| Comment | `// Actual cycles / instruction is unknown` | none of that kind |
| Model | `m_icount -= 8; /* fix me — just an average */` | differentiated per opcode |
| Detail | flat | `remr`: `// (67 to 75878 depending on opcodes!!!)` |
| Hedges | pervasive | one, `expr`: `// checkme` |

A flat average cannot produce a data-dependent range for one opcode and a
distinct value for every other. This reads as transcription from the i960KB
published timing table. **Verify it against that manual before anything
load-bearing rests on it** — but note the conclusion below survives the figures
being wrong by a factor of two.

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

**The silicon is extremely slow at transcendentals.** A CORDIC at ~64 iterations
costs ~64 cycles; the real part takes 406 for the same function. A fully
microcoded FPU sharing one datapath would be roughly **six times faster than the
chip it replaces**, on the operations that dominate its area.

Three consequences:

1. **Microcode the transcendental set.** Design study §7 lists this under Tier 1
   as worth 2-3K ALM "contingent on M2-B showing FP is not hot". The contingency
   is weaker than it looked: the hardware itself caps transcendental throughput
   at ~1,000 per frame. Games cannot be issuing tens of thousands.
2. **Iterate the extended multiplier.** 36 cycles for `mulrl` is ample budget for
   a multi-pass 27x27 DSP approach rather than a wide combinational multiplier.
   112 DSP blocks exist and Model 1 uses 49.
3. **This pushes the FPU toward the bottom of its 2,500-6,000 ALM range**, which
   is the widest line in the i960 estimate.

### 4.3 M2-B's purpose changes

M2-B asked whether FP is hot enough to need a fast unit. §4.2 answers most of
that from the hardware. What M2-B is still needed for is the **mix**: how much
basic arithmetic versus transcendental. That sizes the adder and multiplier — the
parts that run at 10 and 18 cycles and therefore cannot be microcoded away.

Run it, but for the mix, not the verdict.

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

## 8. Known unverifiable

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

## 9. Verification status

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

## 10. Risks specific to this milestone

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
