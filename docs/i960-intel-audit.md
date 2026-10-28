# The i960 core against Intel's own manuals

An audit, not a change. Until this document the core's i960 had been checked
only against MAME (`p1-i960-spike.md` §4: the Programmer's Reference Manual
"settles it ... until someone reads it"). Daytona #34 raised the question of MAME
being wrong where the arcade is right (it has since proved to be the arcade's
own behaviour, R969), and the silicon's documentation is the reference
here. **No RTL was changed.** Every difference is listed with its evidence,
the games that reach it, the fix that would move the core toward the manual,
what the fix costs, and how the fix would be proven.

Current game play is not taken as proof of correctness ("it may not be 100%
accurate", Ben): a difference is not dismissed because games appear to play
well. The rule for any later fix is the one in the study: a change that moves
the core toward documented silicon behaviour is wanted, even if it alters play
slightly; a change made only to make a symptom go away is not.

## Sources

| short name | document |
|---|---|
| PRM | Intel, *80960KB Programmer's Reference Manual*, March 1988 (270567-001). Page numbers are the manual's own footers, e.g. "PRM 11-50", "PRM C-14". |
| HRM | Intel, *80960KB Hardware Designer's Reference Manual*, March 1988. |
| MAME | `src/devices/cpu/i960/i960.cpp`, MAME 0.289 (`build/mame289`). |

The manuals are copyrighted and are not in the repository (they sit in the
git-ignored `sm2-builds/i960-docs/`); this document cites page and table
numbers and uses its own words.

The core was read on all three branches, because they differ:

| branch | games | i960 build |
|---|---|---|
| `main` (Model 2) | Daytona USA, Virtua Cop, Desert Tank | `VC=1`: MAME's register-cache rule (4 saved frames, spill every call past them), no data cache |
| `model2a` (2A-CRX) | VF2, Sega Rally, Zero Gunner, Virtua Cop 2, Manx TT, Motor Raid, Dynamite Cop, Sky Target, DOA, Pilot Kids, Hanguk Pro Yagu 98 | `FR`, `F2A`, R927's 8-frame register ring and 1 KB data cache |
| `model2c` | HOTD, Over Rev, STCC and the other 2B/2C sets | as model2a, plus the 2C forms (cvtilr, logrl, ...) |

File and line references are to `model2a` unless marked; `i960_alu.sv`,
`i960_muldiv.sv` and `i960_dec.sv` are identical on all three branches, and
`i960_top.sv` / `i960_regs.sv` differ only in the register ring, the data
cache, flushreg gating and the FP forms each board needs.

### Two measured facts that decide most severities

1. **Every game runs with AC = 0x3F00_1000** once past its first 0-5 frames
   (MAME 0.289, AC sampled every frame, 40-150 s each, all 16 sets: daytona,
   vcopa, desert, vf2, vcop2, srallyc, zeroguna, manxtt, motoraid, doaab,
   dynamcop, skytargt, pltkidsa, hpyagu98, hotd, overrev). That is rounding
   control 00 (nearest), all five FP exception masks set, normalising mode on,
   integer-overflow mask set (PRM 3-7..3-11). So any difference that appears
   only in another rounding mode, with an exception unmasked, or with
   normalising mode off is never reached by a Model 2 game. Each game executes
   `modac` at most once, at boot.
2. **The core's i960 clock is 40 MHz on all three branches**
   (`rtl/pll/pll.v` outclk_3; the "25 MHz" comments in `Model2.sv` are stale).
   The chip runs at 25 MHz on every Model 2 board (study §1). One core cycle is
   25 ns; one chip cycle is 40 ns.

---

## 0. Summary: every mismatch, ranked

Severity: **V** = affects a game visibly (shown), **C** = could (a game reaches
the case; effect on screen not shown), **N** = never exercised by any logged
game. "Play" says whether the fix would change current game play.

Integer findings are numbered I1-I13, floating-point F1-F9, timing T1-T8.

| # | difference from the manual | where | games reached | sev. | fix | cost | play |
|---|---|---|---|---|---|---|---|
| F1 | `cvtri` (and `roundr`) round exact halves away from zero; mode 00 is ties-to-even (PRM 3-11, 12-12); positive overflow gives 0x8000_0000, not 0x7FFF_FFFF (11-50) | `i960_fpmisc.sv:198`, `:269`, all branches | Daytona 89 results in 150 s, VF2 3,175 in 120 s, VC2 14 in 120 s, each off by one | **C** | ties-to-even increment; saturate | 30-50 ALM | yes, toward the cabinet |
| T6 | the CPU's pace is not the chip's (main ~1.2-2.8x slower on Daytona's busy code, MAME faster), and at least one game (Rally, R926) chooses its work from a timer | clock, register cache, memory path | Rally (proven); others unchecked | **C** | measure first (timer tap, clock sweep in MAME) | -- | -- |
| T2 | main spills by MAME's rule (every call past 4 saved frames); the chip has 4 sets in all and flushes the oldest only when all are in use (C-6, C-14) | `i960_regs` RING=0 on main | Daytona, Virtua Cop (#28), Desert Tank | **C** | R927's ring at the chip's depth, plus the data cache | ~20 ALM + 1 M10K, ~86 ALUT | speed only |
| T1 | transcendentals 3-9x slower than the chip | `i960_fptrans` sequencer | Manx TT (~9% of the core's time), Rally, VCop, Over Rev | **C** | overlap micro-op issue with the unit | 100-300 ALM | speed only |
| T4 | no load overlap, stores not posted at the CPU, quads not burst (C-15..C-17, HRM 3-x) | `i960_top`/`i960_lsu` | every game; Motor Raid #25 candidate | **C** | store buffer; ldq/stq bursts; (scoreboard) | moderate / large | speed only |
| I1 | `subc` treats C as a borrow; the manual (11-119, misprinted) and its sister `dsubc` (11-57) treat it as carry / not-borrow | `i960_alu.sv:189`, `:204` | VF2 6 in 90 s (a 64-bit counter difference, off by one) | **C**, unsettled | flip the sense -- **only after a board test**; the games' own code argues for the core | 0 ALM | yes (VF2) |
| F2 | subnormals flushed; the chip keeps them (3-10, 12-4) | `fpcvt.sv:56`, `fpmul.sv:60`, `fpadd.sv:61` | every 2A/2B/2C game: 126 bytes of a boot-time exponent table differ | C | normalise subnormal single inputs (full gradual underflow optional) | 120-200 ALM (+300-600) | only for values < 2^-126 |
| T3 | 2A/2C ring holds 8 saved frames, the chip 3; `flushreg` writes up to 8 | `i960_regs` RC_FRAMES=8 | DOA (flushreg 1.5 k/s), every 2A game | C | depth 3 -- only together with T4's burst spills, or the core gets slower than the chip | ~20 ALM | timing |
| F5 | NaN results always +QNaN, payload dropped (12-20/21) | `fpmul.sv:100` and the other units | not measured | C at most | propagate the operand's payload | 30-60 ALM | bits only |
| I2 | `addc`/`subc` keep cc bit 2; the manual writes 0CV (11-6, 11-119) | `i960_alu.sv:320`, `:325` | VF2, Rally, DOA, VCop run addc; never read after | N | write bit 2 = 0 | 0 ALM | no |
| I3 | `dmovt` clears AC[31:16] (MAME's 0xfff8 typo) | `i960_alu.sv:356` | none executed | N | mask ~7 | 0 ALM | no |
| I4 | `modi` tests the sign of the truncated product | `i960_muldiv.sv:195` | Daytona (operands never overflow) | N | src1[31] ^ src2[31] | 0 ALM | no |
| I5 | integer overflow never sets AC.of (3-9) | ALU, muldiv, LSU | addi/subi/muli/shli everywhere; flag never read | N | sticky flag | 40-60 ALM | no |
| I6 | no fault machinery (zero divide, constraint, invalid opcode) | `i960_muldiv.sv:250-254`, traps | none reached | N | implicit-call fault path | 300-500 ALM | no |
| I7 | `faultno` is a branch (MAME); it is a conditional fault (11-63) | `i960_top.sv:1669-1674` | never with cc = 000 | N | fall through (or fault with I6) | ~2 ALM | no |
| I8 | IACs 0x40, 0x89, 0x91, 0x92 ignored (13-6..13-12) | `i960_top.sv:2076-2079` | every game sends only 0x93 | N | 0x40 into the queue path; 0x89 drives the I-cache invalidate | 30 / ~350 ALM | no |
| I10 | taking an interrupt ORs the level into the priority and keeps trace-enable (8-5/8-6: set, and clear) | `i960_top.sv:2233` | unreachable with ICR 0x0f0e0d0c | N | set, clear | 0 ALM | no |
| I12 | daddc dsubc extract modify modtc mark fmark syncf atadd atmod synld synmovl calls cmpibo cmpibno, ret types 1/2/3/6, reserved scale: trap | decode | none executed | N | per instruction | 2-150 ALM each | no |
| I13 / F6 | `movre` into fp3 writes the SAT (MAME's storage aliasing) | `i960_top.sv:1941-1943` (2A) | DOA 40,944 in 90 s; SAT never read back | N | own 16-bit field | ~10 ALM | no |
| F3 | AC rounding mode ignored by add/sub/mul/div/sqrt/narrow | the FP units | every game runs mode 00 | N | honour it | 150-300 ALM | no |
| F4 | FP flags and faults never set | -- | all masked | N | sticky flags | 40-80 ALM | no |
| F7 | `cvtilr` (2C) converts the low word only | `i960_top.sv:828` (2C) | Over Rev (values fit) | N | 64-bit int path | ~80 ALM | no |
| F8 | `cvtzril` exact only below 2^31 | `i960_top.sv:1930` (2A) | largest seen 333,152 | N | 64-bit path | ~60 ALM | no |
| F9 | an r form reading a double from fp0-fp3 rounds twice | the FP units | Rally, DOA, Dyn, ZG, Sky, Over Rev; ~2^-29 an op, 0 in 900 k checks | N | round once, to single, from the unit's unrounded result when the destination is single | ~50-100 ALM | no |
| I9 | register-set depth and replacement | `i960_regs` | timing only (T2/T3) | -- | see T2/T3 | | |
| T5, T7, T8 | basic FP / multiply / conversions much faster than the chip; nothing known too fast; trapped forms | | | N | none | | |

Not differences of the core -- **the manual is wrong**, no change:
**I11** compare-and-branch targets are relative to the instruction itself (ROM
evidence in every game; the manual says the next instruction); and, probably,
**F6**'s opcode (the manual says 6E9; DOA runs 6E1 on the cabinet). And one long-open item **closed**:
the instruction field positions (REG, COBR, MEMA, MEMB, both displacement
widths) match App. B exactly.

---

## 1. Integer and control semantics

### Evidence used

* PRM chapters 3, 4, 5, 7, 8, 9, 11, 13 and Appendices B and E, read in full for the integer set.
* A scratch Verilator harness on the real i960_alu.sv + i960_muldiv.sv:
  every mismatch below is confirmed with concrete operands, results quoted.
* Static scan of the 17 program ROMs (a linear walk; data reads as code,
  so static counts are candidates only).
* MAME 0.289 with R869's form log (sm2-builds/mame-r869/m2lod, R869_OUT) -- what each game
  EXECUTES -- plus a pass of conditional debugger breakpoints  that print the
  operands of the value-dependent cases (zero divisors, modi operands, subc/addc chains, IAC
  messages, faultno with cc=000). Sessions: attract + two credits + scripted play, 90-150 s
  emulated each (the dynamic table below gives which games and how long).
* The games' own boot code, which fixes the AC state every game runs with.

### Facts that decide most of the impact column

1. **AC at run time.** Every game's boot runs the same `modac` (Daytona 0xa6c, VF2 0x528, ...):
   mask 0xff1f917f, value 0x3f001000 (MAME pass 2: executed once per boot). So AC.om (bit 12,
   integer-overflow MASK) = 1, all five FP fault masks (bits 24-28) = 1, normalizing mode
   (bit 29) = 1, rounding control (bits 31:30) = 00, no-imprecise-faults (bit 15) = 0.
   **Integer overflow therefore never faults on the board**; per PRM 3-9/3-10 it only sets the
   sticky AC.of (bit 8). Rounding 00 is "round to nearest (even)" per PRM Table 3-4 (p. 3-11)
   -- not C's round-half-away that MAME and i960_fpmisc use; that is section 2's F1, noted here because the AC value comes from this side.
2. **ICR.** All 17 games load ICR = 0x0f0e0d0c (lda 0xff000004 + synmov from a ROM word): INT0-3
   vectors 0x0c-0x0f, all priority 1 (PRM 8-2: priority = vector/8). Interrupts on pins can
   therefore never nest.
3. **IMI.** Every game's word 0 (SAT) is 0; PRCB is 0xb0/0xc0/0x3000.

### Instruction table

(Games = executed in a MAME form-log session unless marked "static" = present in ROM only.)

| Instruction | PRM | Core (file:line, model2a) | Match | Games executing |
|---|---|---|---|---|
| and andnot notand or ornot nor xor xnor not nand notor | 11-11, 11-91..96, 11-133 | i960_alu.sv:248-261 | yes | all |
| notbit setbit clrbit (bitpos mod 32) | 11-94, 11-109, 11-34 | alu:248,251,259 | yes | all |
| alterbit (cc bit 1 selects set/clear) | 11-10 | alu:262 | yes | VF2 168k, Daytona |
| chkbit (cc 010/000) | 11-31 | alu:309 | yes | all |
| scanbyte | 11-108 | alu:145,308 | yes | static only |
| scanbit / spanbit (highest bit; none -> 0xffffffff, cc 000) | 11-107, 11-114 | alu:221-228,340-347 | yes | VF2 828 |
| shlo / shro (len >= 32 -> 0, len NOT masked) | 11-110 | alu:277,289 | yes -- Intel's own action tests `len < 32` on the whole value, so MAME's unmasked count is right | all |
| shri (len >= 32 -> 0 or -1) | 11-110 | alu:285 | yes | all |
| shrdi (rounds toward 0; len >= 32 -> 0) | 11-110 | alu:278-284 | yes | all |
| shli | 11-110/111 | alu:289 | result yes; **no AC.of on overflow** (I5) | Daytona 450k, VF2 402k |
| rotate (len mod 32) | 11-103 | alu:126,290 | yes | Daytona, VF2 |
| addo / subo | 11-7, 11-120 | alu:275-276 | yes | all |
| addi / subi | 11-7, 11-120 | alu:275-276 | result yes; **no AC.of on overflow** (I5) | Daytona 7.7M/3.2M, VF2 3.6M/1.5M |
| addc | 11-6 | alu:317-321 | carry/V yes (MAME never sets carry, core does -- core right); **cc bit 2 kept instead of cleared** (I2) | VF2 279k (150 s) |
| subc | 11-119 | alu:187-189,204,322-326 | **carry sense: core = borrow (MAME), Intel = carry/not-borrow** (I1); cc bit 2 kept (I2) | VF2 4 / 150 s |
| cmpo / cmpi | 11-35 | alu:298-299 | yes | all |
| concmpo / concmpi | 11-45 | alu:302-303 | yes | VF2 15k/28k |
| cmpinco/i, cmpdeco/i (dst = src2 +/- 1, overflow suppressed) | 11-36/37 | alu:304-307 | yes | all |
| mov / movl / movt / movq | 11-85 | top T_MULTI; dst masks as MAME | yes (misaligned/overlap = Intel "unpredictable") | all |
| mulo / muli | 11-88 | muldiv:115,223 | low 32 bits yes; **muli: no AC.of** (I5) | Daytona 169k muli |
| divo / divi / remo / remi | 11-53, 11-97 | muldiv:186-270 | quotient/remainder signs yes; **zero divisor: no Arithmetic Zero-Divide fault** (I6); divi 0x80000000/-1: no AC.of | all |
| modi | 11-80 | muldiv:195,266-267 | **sign test on the TRUNCATED 32-bit product** (I4) | Daytona 2,491 / 120 s |
| emul / ediv | 11-58/59 | muldiv:217-257, top T_PAIR | yes (dst alignment unmasked = Intel "must be even"; ediv overflow undefined in Intel) | Daytona ediv 57k, VF2 45 |
| dmovt | 11-56 | alu:348-357 | cc yes; **clears AC[31:16] (rounding, FP masks, NM)** (I3) | static only (dynamic: see below) |
| modac | 11-79 | alu:358-363 | yes | every game, once at boot |
| modpc | 11-82/83 | top:1727-1745, 2119-2132 | yes except no type-mismatch check in user mode (games always supervisor) | every game at boot |
| daddc / dsubc / extract / modify / modtc / mark / fmark / syncf / atadd / atmod / synld / synmovl | 11-52, 57, 62, 81, 84, 78, 66, 123, 12, 15, 124, 126 | trap (halt) | **not implemented** (I12) | none (MAME has none of them either: it fatalerrors, and every game runs in MAME) |
| b / call / bal (CTRL, IP + disp) | 11-18, 11-25, 11-16 | top:909,1634-1652 | yes | all |
| b<cc> / bno | 11-22..24 | top:1653-1667 | yes (bno fixed by R242) | all |
| bx / balx / callx / lda | 11-18, 11-16, 11-29, 11-69 | top:1834-1845 | yes | all |
| bbc / bbs, cmpob<cc>, cmpib<cc> (COBR) | 11-20/21, 11-42..44, B-4 | top:1705-1722, dec:175 | **yes by ROM evidence, against the manual's text** (I11) | all |
| cmpibo / cmpibno (0x3f / 0x38) | 11-43 | trap | **not implemented** (I12) | none |
| test<cc> | 11-131/132 | top:1693-1704 | yes | all |
| faultno (0x18) | 11-63/64 | top:1669-1674: **a branch** (MAME) | **no: Intel raises Constraint-Range fault when cc = 000** (I7) | see dynamic section |
| fault<cc> taken | 11-63 | top:1675-1688: trap/halt | **no: Intel faults through the fault table** (I7) | none taken (MAME would fatalerror) |
| call / callx frame (FP=(SP+63)&~63, SP=FP+64, PFP = FP or type, RIP in caller r2) | 11-26, 4-4..4-8 | i960_regs.sv | yes | all |
| local register sets: 4 on the chip (current + 3), OLDEST flushed | 4-3, 4-7, C-6, C-14 | main: MAME rule, 4 saved + current, spill of every frame deeper than 4; model2a/2c: ring of 8 saved (R927) | **differs** (I9) -- visible only in the 64-byte save areas (undefined until flushreg) and in timing | all |
| new frame's locals | 4-8 ("unpredictable") | copies the caller's locals (MAME) | undefined either way | -- |
| flushreg | 11-65 | i960_regs; main live only for Virtua Cop, 2A for every game past VF2 | yes | Virtua Cop, Rally, Zero Gunner (boot) |
| ret type 0 / 7 | 11-101/102 | regs + top T_RET7 | yes | all (type 7 = interrupt return) |
| ret types 1, 2, 3, 6 | 11-101/102 | trap | no fault/user-mode machinery; unreachable without faults or user mode | none |
| calls | 11-27/28 | trap (MAME implements local entries) | **not implemented** (I12) | none in the sessions run (R866/R869: Rally/ZG candidates never hit) |
| synmov (+ ICR at 0xff000004) | 11-126 | top:1761-1790 | yes | all (once, boot) |
| synmovq IACs | 13-6..13-12 | top:2040-2110 | 0x93 / 0x80 / 0x41 yes; **0x40 interrupt, 0x89 purge I-cache, 0x91 freeze, 0x92 continue ignored** (I8) | see dynamic section |
| interrupts: edge on pin, vector from ICR, priority vector/8, higher-only immediate, 31 always, pending in table, highest vector first | 8-2..8-11, HRM 3-32 | top:205-327, 2150-2280 | yes | all |
| interrupt PC update | 8-5/8-6 | top:2233: OR's the new level into the old priority, keeps trace-enable (MAME, R21) | **no: Intel SETS priority to the interrupt's, clears trace-enable and trace-fault-pending** (I10) | unreachable with ICR 0x0f0e0d0c |
| interrupt record (PC at FP-16, AC at FP-12, vector at FP-8) | 8-6/8-7, 11-102 | top:2207-2219 | yes | all |
| MEMA / MEMB modes, scale, field positions | B-1..B-6, 5-6..5-8 | i960_dec.sv:145-218, i960_agu.sv | **yes -- now verified against Intel** (closes the spike's "field positions transcribed, not verified"); reserved mode 6 traps, Intel faults; reserved scale 5-7 not rejected (I12) | all |
| unaligned load/store | 7-7, E-1 | i960_lsu.sv splits into byte accesses (MAME) | values yes; bus pattern differs (Intel: wider accesses, "moderate cost") | rare |
| reset state (PC 0x001f2002, FP from PRCB+24, ICR) | 7-14, 8-11 | top:1324 | yes (AC and ICR at reset are Intel-undefined / 0xff000000; games set both) | all |

### Findings (every mismatch)

#### I1. subc: carry-in/carry-out sense (borrow in the core, carry in Intel's text) -- UNSETTLED, could affect a game
* **Intel (PRM 11-119):** "AC.cc <- 2#0CV#", carry bit 1 is "carry from ordinal subtraction". The
  action line prints as `dst <- src2 - (src1 - 1) + C`, which cannot be literal (it would give
  src2 - src1 + 1 with C = 0); the sister instruction dsubc on 11-57 prints `src2 - src1 - 1 + C`,
  and later i960 manuals (Jx/Hx, from memory, NOT re-checked here) define subc the same way:
  dst = src2 + NOT(src1) + C, carry out = the adder's carry (C = 1 means "no borrow"). We take
  that reading as Intel's intent.
* **Core:** i960_alu.sv:187-189 feeds `~carry_in` into the subtract and :204 inverts the carry
  out, i.e. C is a BORROW (MAME's `t2 - (t1 + C)`). Harness: subc 5-3 with C=1 -> 1 (Intel
  reading: 2); 0-1 with C=1 -> 0xfffffffe, C out 1 (Intel: 0xffffffff, C out 0).
* **The games' own code argues for the core's sense.** Every compiler-made 64-bit subtract in
  the 17 ROMs starts with `cmpo 1,0` or `cmpo 0,1` (both leave C = 0) -- the same carry-clear it
  uses before addc (9 static subc chains; VF2 runs three at 61 s: 0x50018c's 64-bit counter
  minus a stored copy, e.g. 0x2eb0 - 0x243f). Under the borrow sense that is the exact
  difference; under Intel's printed sense every one of them is one less (0xa70 instead of
  0xa71). A toolchain that clears C before every subc is evidence the silicon it was tested on
  treats C as borrow -- or a compiler bug that cost one tick. Not decidable from the documents.
* **Games:** VF2 executes subc (6 times in 90 s, 4 in 150 s); static chains also in Sega Rally,
  Zero Gunner, Motor Raid, DOA, Pilot Kids, Hanguk Pro Yagu 98 (dynamic: see the table at the end).
* **Fix if silicon is shown to follow the text:** alu:189 `add_cin = carry_in` for subc and :204
  `subc_res = add_res` (no inversion). ~0 ALM. Proof: directed vectors from the definition
  (all 4 combinations of C x borrow, 0/1/0x7fffffff/0x80000000/0xffffffff operand pool) and a
  `SUBC_INTEL` switch in i960_alu_ref.h so lockstep runs both ways. **Recommendation: do not
  change** without a silicon test (a 2-instruction program on a real board: cmpo 0,0; subc
  1,1,r -> 0 under Intel's sense, 0xffffffff under the core's).
* Note: MAME never sets carry at all (R7/§2.3), so in MAME the HIGH word of these chains ignores
  the low word's borrow; the core propagates it. That difference from MAME is a fix already in.

#### I2. addc / subc leave AC.cc bit 2 unchanged -- never visible in the games found
* Intel 11-6, 11-119: `AC.cc <- 2#0CV#` -- bit 2 is written 0. Core alu:320, :325 keep ac_in[2]
  (MAME: `m_AC &= ~0x3`). Harness: addc with cc=100 in -> cc=110 out (Intel: 010).
* Visible only if a branch/test reads bit 2 after addc/subc without a compare in between; the
  compiled chains are followed by ld/ldl/cmpo (VF2 0x6d914..), so not exercised there.
* Fix: `ac_out = {ac_in[31:3], 1'b0, C, V}` at both lines. 0 ALM. Proof: directed vectors with
  cc in = 1xx; alu_ref updated; lockstep.

#### I3. dmovt clears AC[31:16] -- would change FP rounding/masks if ever run
* Intel 11-56: only AC.cc changes (000 valid digit, 010 not). Core alu:356 masks AC with
  0x0000fff8 (MAME's typo, reproduced deliberately in the spike). Harness: AC 0xc0001000 in ->
  0x00001000 out: the rounding field, every FP mask and NM bit are lost.
* Games: static candidates in 10 ROMs; executed: see dynamic table (none found executing).
* Fix: `(ac_in & ~32'd7) | ...`. 0 ALM. Proof: directed (AC = random, check bits 31:3 kept).

#### I4. modi decides "add the divisor back" on the sign of the truncated 32-bit product
* Intel 11-80: result takes src1's sign when non-zero, i.e. add src1 when the TRUE signs of
  src1 and src2 differ and the remainder is non-zero. Core muldiv:195 uses prod_u[31] of the
  32-bit product (MAME's int32 overflow). Harness: modi 3, 0x40000000 -> 4 (true answer 1).
* Games: Daytona executes modi (2,491 in 120 s; 779 operand pairs logged in 90 s, every one with
  |operands| <= 1, never an overflowed product). Static elsewhere (Rally 3, VCop2 2, DOA 1, STCC 8).
* Fix: `mod_prod_neg <= src1[31] ^ src2[31]` (drops a dependency on the multiplier). ~0 ALM.
  Proof: 10^6 random + boundary pool against an exact int64 floor-modulo reference.

#### I5. Integer overflow never sets AC.of (addi, subi, muli, divi, shli, stib, stis; cvtri is FP)
* Intel 3-9/3-10, 11-7, 11-88, 11-110, 11-117, 11-120: with AC.om = 1 (every game, see above)
  overflow sets the sticky flag AC bit 8 instead of faulting. Core never sets bit 8 (harness:
  addi 0x7fffffff+1, subi 0x80000000-1, shli 0x40000000<<2 all leave AC = 0x1000).
* Visible only through modac reads of AC or the AC saved in an interrupt record; every game
  runs modac once (boot) and nothing reads AC.of afterwards that the sessions found. No visible
  effect expected; still a documented difference.
* Fix: overflow detect in i960_alu (signed add/sub overflow already computed for addc:
  reuse; shli: bits shifted out != sign), i960_muldiv (muli: prod_s[63:31] not all equal; divi
  0x80000000/-1), i960_lsu (stib/stis range), OR'd into ac[8] when ac[12]. ~40-60 ALM.
  With om = 0 Intel faults -- needs I6's fault path. Proof: directed vectors per form.

#### I6. No fault mechanism: zero-divide, constraint, invalid opcode / operand
* Intel ch. 9 (types 9-2), 11-53/58/80/97: divi/divo/remi/remo/modi/ediv with src1 = 0 raise
  Arithmetic Zero-Divide (NOT maskable) through the fault table (PRCB+40), with a fault record
  and an implicit call; fault<cc> (taken) raises Constraint-Range; reserved encodings raise
  invalid-opcode. Core: zero divisor -> quotient 0 / remainder = dividend (muldiv:250-254;
  harness confirms), fault<cc> taken -> trap/halt, reserved encodings -> trap/halt.
* Games: no zero divisor was ever seen (conditional breakpoints on every register-divisor
  divide site in the 7 games run in pass 2: 0 hits; Rally/ZG see the caveat below the dynamic table). MAME would crash the host on divi/remi/modi
  by zero (x86 SIGFPE), so those three can never have been hit in a working MAME session;
  only divo has MAME's "HACK!" guard. No fault<cc> is ever taken (MAME fatalerrors on it).
* Fix: an implicit-call microsequence beside M_TAKE (fault table read, fault record of 16+
  bytes, local or system-table entry, return type 001 handled in T_RET7's shape): ~300-500
  ALM, no DSP/M10K. Proof: directed programs from ch. 9's definitions, a reference model of
  the fault path, lockstep with faults enabled. Value: low (no game reaches it).

#### I7. faultno (0x18) is a branch, not a fault
* Intel 11-63/64: faultno raises Constraint-Range when cc = 000, else does nothing; it never
  branches. Core top:1669-1674 branches by the displacement field (MAME). An encoded faultno
  normally has displacement 0, so the core would branch to ITSELF and spin forever.
* Games: executed faultno with cc = 000: none (conditional breakpoints, the 7 games of pass 2). Static words
  in every ROM (13-353, mostly data).
* Fix: with I6, take the fault; without I6, at least make it a no-op (fall through) or a trap,
  which is what fault<cc> already does. ~2 ALM. Proof: directed cc = 000 / 0xx vectors.

#### I8. IACs 0x40 (interrupt), 0x89 (purge I-cache), 0x91 (freeze), 0x92 (continue init) ignored
* Intel 13-6..13-12: 0x40 raises an interrupt with the vector in field 1 (posted if not higher
  than the current priority); 0x89 invalidates the instruction cache; 0x91 stops the CPU.
  Core top:2076-2079 (MAME logs and ignores all four). 0x93 sets SAT/PRCB/IP only (Intel
  "reestablishes the processor state" -- whether priority/FP are reset as at power-on, 7-14, is
  not stated; unsettled, see below).
* Games: IAC messages captured (pass 2): Daytona and VF2 send exactly one IAC per boot, the
  0x93 reinitialise; others in the table at the end. No 0x40 / 0x89 / 0x91 / 0x92 seen.
* Fix (0x40): feed field 1 into the existing M_Q / immediate path (the pin path already does
  priority and posting) ~30 ALM. (0x89): drive i960_icache.inval from it -- the 32-entry
  invalidate loop the fitter currently removes (~350 ALM per the spike's 472 vs 106; R768/R786
  cache sizes scale it). Proof: directed IAC programs; for 0x89 a self-modifying sequence
  (copy code to RAM, run, overwrite, purge, run) checked against the new bytes.

#### I9. Local-register cache: depth and replacement differ from the chip
* Intel 4-3, 4-7, C-6, C-14: four register SETS (the current one + three saved); a call that
  finds all four allocated flushes the OLDEST set to its frame; ret reloads only a frame that
  is not cached. Save areas are undefined until flushreg (4-7).
* Core: main (Daytona, VCop, Desert) = MAME's rule: four saved frames by depth since the last
  flushreg, and EVERY call deeper than that spills the caller's frame and every matching return
  refills it (i960_regs RING=0); model2a / model2c = a ring of EIGHT saved frames, oldest out
  (R927).
* Visible: (a) the memory image of the 64-byte save areas (undefined architecturally; a game
  reading a caller's save area without flushreg sees different words on each); (b) timing
  (section 3). No game found doing (a) (R927 checked VF2's coroutine, Rally/ZG flushreg first).
* Fix toward silicon: RC_RING=1 with THREE saved frames (needs a non-power-of-two ring or a
  4-slot ring with one slot unused: ~20 ALM in i960_regs' pointer logic). Changes timing (more
  spills than 8, fewer than MAME's rule on main). Proof: the existing regs ring bench with a
  3-frame reference model; lockstep with RING on.
* Also undefined but different: a new frame's locals start as a copy of the caller's (MAME);
  on the chip they are whatever that physical set last held (4-8).

#### I10. Taking an interrupt ORs the level into the priority and keeps trace-enable (R21)
* Intel 8-5/8-6 (steps 4-5): the priority is SET to the interrupt's, trace-enable and
  trace-fault-pending are cleared. Core top:2233 keeps MAME's `& ~0x1f00` then `| lvl<<16`
  (R21's quirk) and leaves bit 0.
* Unreachable on Model 2 as programmed: every game's ICR is 0x0f0e0d0c (all four pins
  priority 1), interrupts only fire from priority 0, and 0 | 1 = 1. Would matter only for an
  IAC 0x40 interrupt at another priority (I8, none seen).
* Fix: `(pc_reg & ~32'h001f_0401) | (lvl << 16) | 32'h2002`. 0 ALM. Proof: the R21 mutation
  test inverted (lockstep reference switch), directed nested-interrupt programs. R21 asked for
  silicon evidence before changing it; the manual is that evidence.

#### I11. COBR branch target: the core is right and the manual's text is not
* PRM 11-20, 11-42..44 and B-4 say compare-and-branch / bbc / bbs add the displacement to the
  NEXT instruction's IP (IP + 4 + disp*4). The core (dec:175 `disp_cobr - 4` + ip_next = IP +
  disp*4, MAME's get_disp_s) adds it to the COBR instruction's own IP.
* ROM evidence: a target that lands on the displacement word of a two-word MEMB instruction is
  impossible. Over every COBR in the 17 programs, the core's reading lands on such a word
  15 / 1,937 times in Daytona (static noise), the manual's 437 / 1,937; VF2 300 vs 1,743, Rally
  1,103 vs 2,040, Sky Target 40 vs 1,338 -- the same in every game. CTRL (b/call/bal/b<cc>), which
  the manual says is IP-relative, gives 0 / 2,999 vs 888 / 2,999. So the silicon is IP-relative
  for COBR too; the KB manual's description is an error. **No change.**
* The same check verifies the spike's open item: field positions (REG src1/src2/srcdst, m1-m3,
  op2; COBR m1 at bit 13; MEMA/MEMB mode, scale, index; both displacement widths) match App B
  B-1..B-6 exactly.

#### I12. Instructions Intel defines that the core traps on (halts)
* daddc, dsubc (11-52/57), extract, modify (11-62/81), modtc (11-84), mark, fmark (11-78/66),
  syncf (11-123), atadd, atmod (11-12/15), synld, synmovl (11-124/126), calls (11-27),
  cmpibo / cmpibno (11-43), ret types 1/2/3/6 (11-101), reserved MEMB scale 5-7 (B-6, Intel:
  invalid-opcode fault; the core shifts by 5-7 instead).
* MAME implements none of these except calls (local entries), so no game executed them in any
  MAME session (all would fatalerror). Static candidates exist in many ROMs (fmark 1,496 in
  Rally, 3,328 in STCC -- data). Executed in this audit's sessions: none (form logs).
* Fix cost if wanted: extract/modify ~60 ALM (mask + shifter already in the ALU), cmpibo/no
  ~2 ALM, daddc/dsubc ~30 ALM, atadd/atmod ~80 ALM (LSU read-modify-write), synld/synmovl ~20,
  mark/fmark/syncf as no-ops ~5 (no trace), calls ~150 ALM (procedure-table read + frame type),
  scale check ~2. Proof: directed vectors from each 11-xx Action line.

#### I13. movre into fp3 overwrites the SAT's low half (section 2, I6) -- DOA
* PRM 12-9/12-10 and 11-86: movre moves a three-word extended real between registers;
  fp0-fp3 are 80-bit registers on the chip, entirely separate from the SAT pointer (an IMI
  pointer cached on chip, 7-10). Core top:1941-1943 (F2A, R897): movre's third word into fp3
  writes `sat_reg <= {16'd0, w2}` -- MAME stores m_fp[] as double and its fp3 + 1 slot aliases
  m_SAT.
* What reads sat_reg in the core: only IAC 0x80 (store system base, top:2087) and the debug
  port. calls is not implemented, faults are not implemented, interrupts use PRCB. So the
  clobber is visible only if a game sends IAC 0x80 after a movre to fp3 (it would store a
  wrong SAT).
* DOA: IMI word 0 (SAT) = 0, so before any reinit IAC the SAT is 0 and a movre that writes
  {16'd0, w2} with w2 = 0 changes nothing; the reinitialise IAC DOA sends (pass 2, table
  below) gives the SAT value it runs with -- see the dynamic section for whether its high 16
  bits are non-zero and whether any IAC 0x80 follows.
* Fix: give fp3 its own 16-bit sign/exponent extension register instead of sat_reg (16 flops,
  ~10 ALM), or true 80-bit registers. Proof: movre fp3 round trip + IAC 0x80 directed
  test.

### Dynamic results (MAME 0.289 + R869 form log + conditional breakpoints; 90 s each: boot,
### attract, coins at 10 s / 40 s, scripted play; VF2 also a 150 s form-log run)

| Game | IACs sent | zero divisor | faultno cc=000 | subc / addc executed | modi | dmovt | calls | flushreg | other |
|---|---|---|---|---|---|---|---|---|---|
| Daytona | 1 (0x93 reinit, PRCB 0x5ff400) | 0 | 0 | 0 / 0 | 779 (90 s); operands always (1, 0) -- no overflowed product | 0 | 0 | 0 | ediv 47k, divi 302k, muli 105k |
| Virtua Cop | 1 (0x93, PRCB 0x501000) | 0 | 0 | 0 / 420 | 0 | 0 | 0 | 1 (boot) | |
| VF2 | 1 (0x93, PRCB 0x5ff410) | 0 | 0 | 6 / 170,556 | 0 | 0 | 0 | 0 | the subc chains, I1 |
| Sega Rally | 1 (0x93, PRCB 0x201e40) | 0 * | 0 * | 0 / 384 | 0 | 0 | 0 | 1 (boot) | AC set by a hand-built type-7 frame + ret (0x5c0-0x5e4): AC 0x3f001000, PC 0 = USER mode |
| Zero Gunner | 1 (0x93) | 0 * | 0 * | 0 / 0 | 0 | 0 | 0 | 1 (boot) | |
| Virtua Cop 2 | 1 (0x93) | 0 | 0 | 0 / 0 | 0 | 0 | 0 | 0 | |
| DOA | 1 (0x93, SAT 0, PRCB 0x501810) | 0 | 0 | 0 / 4,134 | 0 | 0 | 0 | **130,038** (task switching) | movre 40,944 |
| Manx TT | 1 (0x93, PRCB 0x501e40) | 0 | 0 | 0 / 0 | 0 | 0 | 0 | 1 (boot) | |
| Desert Tank | not run (parent ROM set missing in /home/ben/roms/Model2) | | | | | | | | |

\* Sega Rally and Zero Gunner execute from a RAM copy; breakpoints were placed at ROM address +
0x500000, which proved NOT to be a faithful map (a "calls" breakpoint at 0x5a9f18 fired 5,095
times on what the form log shows is not a calls -- the copy's layout differs there). For those
two games only the form-log columns (subc / addc / modi / dmovt / calls / flushreg counts) are
evidence; the value columns are not.

The IAC column shows message words 0-2; the fourth word was mis-addressed by the debugger's
hex default (+0x12) and is not quoted. Not run in pass 2 (time): Motor Raid, Dynamite Cop, Sky Target, Pilot Kids, Hanguk Pro Yagu 98,
and the 2C set (HOTD, Over Rev, STCC). Their static scans are in the table above; their IAC
messages, zero-divisor and subc cases are unsettled.

### What could not be settled

1. **subc's carry sense on silicon** (I1). The KB manual's action line is misprinted; the
   games' compiler output assumes borrow semantics; later Intel manuals (memory, not checked)
   describe not-borrow. Needs a two-instruction test on a real i960KB / board.
2. **What reinitialise (IAC 0x93) does to PC priority, FP/SP and AC** (13-10 "reestablishes the
   processor state"; 7-14 gives power-on only). The core and MAME change SAT, PRCB and IP only.
   Every game issues it once at boot; Daytona/VF2 lower the priority with modpc afterwards and
   Rally rewrites PC/AC with its own type-7 return, so the likely effect is nil.
3. **Interrupt latency inside long instructions**: Intel suspends and resumes long FP
   instructions on an interrupt (C-19, 8-5); the core takes interrupts only at instruction
   boundaries. A timing question: section 3.
4. Value-dependent cases in the games not run dynamically (list above).
5. Sega Rally runs in USER mode after its boot (PC = 0 from its own type-7 return). Nothing in
   the core checks mode (modpc privilege, calls to supervisor entries, ret types 2/3); Rally
   executes none of those, so the result is the same, but the core does not know it is in user
   mode.

### Ranking (likely visible effect first)

1. I1 subc carry sense -- the only mismatch a game executes on a value that differs (VF2, a
   64-bit counter difference at 61 s, result differs by 1). Unsettled which side is silicon;
   do not change without a board test.
2. I8 IAC 0x89 purge / 0x40 interrupt -- would be visible the moment a game uses them; none of
   the 7 games run does.
3. I13 movre fp3 -> SAT -- invisible (no game reads SAT back); cheap to make right with section 2's I6.
4. I4 modi, I3 dmovt, I2 addc/subc bit 2, I10 interrupt priority, I7 faultno, I5 AC.of,
   I6/I12 faults and missing instructions -- documented, cheap (except I6), not reached by any
   game run.
5. I9 register-set depth -- architecturally invisible; a timing matter.
6. I11 COBR -- the manual is wrong, the core is right: no change.

---

## 2. Floating point

Sources: PRM ch. 3 (3-7..3-11), ch. 11 FP entries, ch. 12 (12-1..12-27),
App. A/B. Game usage from MAME form logs (R869/R921/R930/R935 archives and
fresh Daytona/VF2/Virtua Cop logs), MAME conditional breakpoints on every
`cvtri` and on the `logbnr` boot table, and numeric checks in Python.

### 2.1 Table

| instruction | PRM | core | match? | games |
|---|---|---|---|---|
| addr subr mulr divr | 11-8, 11-54, 11-89, 11-121 | double unit, round-to-nearest-even, narrowed RNE (`i960_fpadd/fpmul/fpdiv`, `i960_fpcvt.sv:34`) | yes in mode 00; AC rounding control ignored (N) | all |
| addrl subrl mulrl divrl | same | `RL=1`, double | yes in mode 00 | Rally, ZG, DOA, Dyn, Sky, PK, HPY, MR, Manx, HOTD, Over Rev, VCop, Desert |
| r form reading fp0-fp3, register destination | 12-13/12-14: one rounding, to the destination | double op, then narrow: two roundings | differs with probability ~2^-29 an op; 0 in 3 x 300,000 random checks | Rally (mulr 434 k a session), DOA, Dyn, ZG, Sky, Over Rev |
| cmpr cmprl | 11-40 | `i960_fpmisc` compare; cc 100/010/001/000 | yes (+0 = -0, NaN -> 000) | all FP games |
| cmpor cmporl, classr classrl, cpyrsre, cvtril, roundrl, expr/exprl, logepr/l, logr (main/2A) | 11-38, 11-32, 11-48, 11-50, 11-104, 11-60, 11-72, 11-75 | trap (MAME: fatalerror / absent) | absent | none logged |
| movr movrl | 11-86 | exact widen / RNE narrow | yes | all |
| movre | 11-86/87 and App. A give opcode **6E9** | decodes **6E1**, as MAME; the third word lands in the next fp register's low 16 bits and, after fp3, in the SAT (`i960_top.sv:1942` (2A)) | opcode: probable manual erratum (DOA executes 6E1 51,712 times a session); SAT side effect: no silicon basis (F6) | DOA |
| cpysre | 11-48 | sign from MAME's `src2 >= 0.0` test (`i960_top.sv:875` (2A)) | yes on the games' operands (src2 always literal +0.0) | Rally, ZG, PK, Over Rev, VCop |
| cvtir | 11-49 | exact int -> double, narrowed | yes | all |
| cvtilr (2C) | 11-49: 64-bit source pair | MAME's int32 of the LOW word | differs for magnitudes >= 2^31; Over Rev's values fit (N) | Over Rev |
| **cvtri** | 11-50, 3-11 Table 3-4, 12-12 | **mode 00 rounds ties AWAY from zero** (`i960_fpmisc.sv:198`, all branches, from MAME's C `round()`); overflow and NaN -> 0x8000_0000 (`:269`) | **NO**: mode 00 is ties-to-even; positive overflow must give 0x7FFF_FFFF | **Daytona, VF2, VCop2** (F1) |
| roundr | 11-104 | same mode-00 rounding as cvtri | NO on ties | none execute it |
| cvtzri cvtzril | 11-50 | truncate; cvtzril = cvtzri sign-extended | yes while magnitudes < 2^31 (largest logged 333,152) | all 2A/2B/2C, Daytona |
| sqrtr sqrtrl | 11-115 | correctly rounded; sqrt(-x) -> +QNaN | yes (NaN bits aside) | Rally, ZG, MR, PK, Over Rev, Dyn, HPY, VCop |
| **logbnr** | 11-70, 12-4 | widened operand; a **subnormal single is flushed to 0** -> -inf | **NO for subnormals** (F2) | all 11 2A/2B/2C games, at boot |
| scaler scalerl | 11-105 | multiply by a built 2^n (`i960_top.sv:729` (2A)) | yes in the normal range | Daytona (35,720 a session) |
| remr | 11-98 | exact fmod (`i960_fprem.sv`), truncated quotient, sign of src2 | yes; AC 3-6 quotient bits not set (N) | Rally (divisor always 2 pi) |
| atanr atanrl | 11-13 (quadrant table) | atan2(src2, src1), microcode | yes: operand order, quadrants and signed zeros | Rally, Manx, Over Rev, VCop |
| sin cos tan, r and rl | 11-112, 11-46, 11-129 | correctly rounded double microcode, r forms narrowed | yes to <= 1 ulp (chip reduces with a 66-bit pi, 12-18; arguments seen <= 12.6) | Rally, Manx, Over Rev, VCop |
| logrl (2C) | 11-75: src2 x log2(src1) | as defined | yes | HOTD (165 a session) |
| FP literals | B-2: 0x10 = +0.0, 0x16 = +1.0, the rest reserved | 0x16 = 1.0, any other >= 4 = 0.0 | yes for the legal encodings; games use only 0x10 / 0x16 | |
| fp0-fp3 | 12-8..12-10: 80-bit extended | 64-bit | NO: see 2.3 | |
| AC FP flags (16-20), integer-overflow flag (8), FP faults | 3-9/3-10, 12-21..12-26 | never set, never raised | NO (N: every game masks all five; flags are sticky and only `modac` reads them) | |
| denormals, normalising mode | 3-10, 12-4, 12-12 | subnormal inputs and results flushed (`fpmul.sv:60`, `fpcvt.sv:56`, `fpadd.sv:61`) | NO (games run normalising mode on) | F2 |
| NaN results | 12-20/12-21: a NaN operand's payload is kept; an invalid operation gives the standard QNaN | always +QNaN, payload dropped (`fpmul.sv:100`) | NO, bits only (MAME on x86 gives -QNaN and keeps payloads) | not measured |

### 2.2 Findings

**F1 -- cvtri rounds ties away from zero; the chip rounds them to even.**
PRM 3-11 (Table 3-4) and 12-12 define rounding control 00 as round to
nearest, ties to even. The core's mode-00 increment is "half up" in magnitude
(`i960_fpmisc.sv:198`, the comment says so), copied from MAME's `round()`.
PRM 11-50 also says an unrepresentable result stores the maximum positive or
maximum negative integer by sign; the core stores 0x8000_0000 for both (the
comment near `i960_fpmisc.sv:255` and study R12 say the manual gives "the
truncated low 32 bits": this manual does not). Measured in MAME with a
conditional breakpoint on every `cvtri` in each program, firing only on an
exact .5 or an overflow:

| game | session | exact ties | result differs by 1 | where |
|---|---|---|---|---|
| Daytona | 150 s attract + race | 159 | **89** | 0x68ac (50; -2.5, -4.5 ...), 0x172a4/0x172c0 (18; -221.5, -32.5), 0xc870 (8; 8466.5), 0x11be0/0x11c04 (7; 291.5), 0x109b0 (2; 7220.5), 0x6900, 0x964c |
| VF2 | 120 s attract + play | 8,337 | **3,175** | 0x28ad4 (2,905; values like 32767.5), 0x28820, 0x27cc8, 0x288f0 |
| Virtua Cop 2 | 120 s | 29 | **14** | 0x2eca8 |
| Desert Tank, Virtua Cop | 100 / 150 s | 0 | 0 | VCop runs no cvtri; Desert's never tie |

No other game runs `cvtri` or `roundr`. Positive overflow: 0 in every
session. Severity **C** (a deterministic one-unit integer difference against
the cabinet in three games; MAME has the same fault, so the core equals MAME
today). Daytona's 0x109b0 and 0x11be0-0x11c04 sit just after the
yaw/heading code the study traced at 0xffe8-0x10820.
*Fix:* in `i960_fpmisc`, mode 00 increments when the fraction is above half,
or exactly half and the integer part is odd (an exact-half test beside the
existing sticky, and the integer LSB); `roundr` shares it. Saturate positive
overflow to 0x7FFF_FFFF. ~30-50 ALM, 0 DSP. *Play:* yes, in Daytona, VF2 and
VCop2, toward the cabinet. *Proof:* `test_i960_fpmisc` gains a reference
switch (MAME vs PRM); directed vectors at every n + 0.5 for n in -2^24..2^24
(even and odd n, both signs), the 0.5 / 1.5 / 2.5 / -0.5 cases, +-2^31 +-
1 ulp and NaN, against `round-half-even` and the PRM's saturation; the
existing 3.3 M random checks re-run with the new reference; the
`tieana.py` census re-run on the three games' recorded tie values shows the
RTL now gives the even result at every logged PC.

**F2 -- subnormals are flushed; the chip keeps them.** PRM 3-10, 12-4 and
12-12: with normalising mode on (every game) denormalised operands are used as
they are and results underflow gradually. Every 2A/2B/2C game (Manx, Motor
Raid, Rally, DOA, Dynamite Cop, HPY, Sky Target, Pilot Kids, Zero Gunner,
HOTD, Over Rev) builds a 32,768-entry exponent byte table at boot from
`logbnr` of every single whose top bits step through the range (Manx at
0x3d88, HPY at 0x21f80; MAME disassembly); entries 1-258 are subnormal
singles. The silicon and MAME give logb = -149..-127 there; the core flushes
the operand to zero and returns -inf, which the game's clamp turns into 0.
**126 bytes of the table (entries 133-258) are 0 on the core and 1 on the
chip and in MAME** -- a core-vs-MAME difference nobody had measured. The
table is read only for inputs below 2^-126 (1.2e-38). Bulk-op subnormals in
play were not logged. Severity **C** (deterministic, almost certainly never
on screen). *Fix:* normalise a subnormal single on the widening path
(`i960_fpcvt` u_cvt_a / u_cvt_b: a 23-bit leading-zero count and shift),
~60-100 ALM each, 0 DSP; full gradual underflow on add/mul/div/narrow results
is ~300-600 ALM more. *Play:* only for values below 2^-126. *Proof:*
`test_i960_fpcvt` / `test_i960_fpmisc` with every subnormal single (2^23 x 2
signs, exhaustive) widened and `logbnr`'d against the host; the boot table
dumped from the whole-core bench equals MAME's table byte for byte.

**F3 -- the AC rounding mode is ignored by add, sub, mul, div, sqrt, the
narrowing and cvtir** (always nearest-even, `i960_fpmul.sv:18`). PRM 12-12:
every result rounds per AC. All games run mode 00. **N**. Honouring it:
~150-300 ALM across the units; proof would be the existing unit benches run in
all four modes against the host's `fesetround`. Not recommended while no game
reaches it.

**F4 -- FP exception flags, FP faults, and the integer-overflow flag are never
set**; remr's quotient bits (AC 3-6, PRM 11-99) neither. PRM 3-9/3-10,
12-21..12-26. Every game masks all five and none reads the flags after boot.
**N**. Setting the sticky flags is ~40-80 ALM; taking the faults needs the
fault mechanism the core does not have (section 1).

**F5 -- NaN encoding.** PRM 12-20/12-21: a NaN operand's payload propagates;
an invalid operation gives the standard QNaN. The core always returns
+0x7FF8_0000_0000_0000 / +0x7FC0_0000, dropping payloads. Bits only, and only
visible to code that reads a NaN as an integer or passes it to the TGP (R923
already noted TGP outputs differing "in NaN encoding only"). Not measured in
games. **C** at most. ~30-60 ALM. Proof: unit vectors with every NaN
class against a PRM-rules reference.

**F6 -- movre.** PRM 11-87 and App. A give movre as 0x6E9; MAME, the core and
DOA's code all use 0x6E1, which DOA runs 51,712 times a session and which
must therefore do what DOA needs on the cabinet: most likely a manual
erratum, not settled. Separately, the core copies a MAME storage artefact:
`movre` into fp3 writes the SAT's low 16 bits and clears its top 16
(`i960_top.sv:1942` (2A)). The silicon has no such coupling. DOA's
save/restore of fp0-fp3 round-trips identically either way. See section 1
for whether the SAT is read afterwards. *Fix:* hold the extended third word
in a 16-bit field per fp register, never in the SAT (~64 FF, ~20 ALM).

**F7 -- cvtilr (2C) converts the low word only**; PRM 11-49 converts the
64-bit pair. Over Rev's operands fit int32. **N**. Fix: a 64-bit
int->double path (~80 ALM).

**F8 -- cvtzril is cvtzri sign-extended**: right for |x| < 2^31 (largest
logged 333,152). **N**.

**F9 -- double rounding on mixed precision.** An r-form instruction that
reads a double from fp0-fp3 and writes a single register rounds twice in the
core and in MAME (to double inside the unit, then to single), once on the
chip (12-14). The rate is ~2^-29 an operation; 3 x 300,000 random mul/add/div
checks found none. **N in practice.** See section 4 item 2 for the
single-only case, which provably cannot differ.

Matches worth recording (no action): atanr's operand order and quadrant and
signed-zero table (11-13) are atan2(src2, src1); logr is src2 x log2(src1);
remr is the truncated-quotient remainder (fmod), not IEEE's; cmpr's condition
codes and +0 = -0; the literals; cvtzri ignores the mode; cvtri(NaN) =
0x8000_0000 (12-23, "maximum negative integer"); the rl transcendentals are
correctly rounded.

### 2.3 fp0-fp3: where the 80 bits live, game by game

PRM 12-8..12-14: only fp0-fp3 hold extended (80-bit) values. An operation with
an fp-register destination rounds to extended; with a general-register
destination it rounds once, to that register's width, even from extended
operands. movr/movrl widen exactly; movre moves 80 bits raw.

The core's fp0-fp3 are 64-bit (`p1-i960-spike.md` §8). From the form logs
(reads / writes of fp0-fp3 by instruction, one session each):

| game | writes fp0-fp3 with | reads fp0-fp3 in | consequence of 64-bit |
|---|---|---|---|
| Daytona, VF2, Virtua Cop 2 | nothing | nothing | none |
| Sega Rally | movr 8.5 M, movrl 6.2 M, cvtir 57 k, cpysre 37 k | cmprl 2.5 M, mulrl 1.8 M, addrl/subrl 1.4 M, mulr 434 k, ... | F9 only |
| Zero Gunner | movr 1.1 M, movrl 805 k, cvtir 60 k, cpysre 76 k | cmprl, movr, addrl, subrl, mulrl | F9 only |
| Motor Raid | movr 3.6 M, movrl 46 k | cvtzril 3.4 M, movr, mulr 17 k | F9 only |
| Manx TT | movr 6.7 k, movrl 440 | cvtzril, mulrl, divrl (110 each) | none practical |
| DOA | movr 7.5 M, movrl 2.3 M, movre 207 k | cmprl 2.8 M, subrl 1.5 M, subr/addr 685 k, movre | F9; F6 |
| Dynamite Cop | movr 316 k, movrl 165 k | addr 172 k, divrl 74 k | F9 only |
| Hanguk Pro Yagu 98 | movr 2.5 M, movrl 2.0 M | cmprl 1.2 M, mulrl 167 k | F9 only |
| Sky Target | movr 744 k, movrl 310 k | movr 645 k, mulrl 85 k | F9 only |
| Pilot Kids | movrl 1.4 M, movr 867 k, cvtir 236 k | addrl 375 k, cmprl 395 k | F9 only |
| HOTD (2C) | movr 130 k, movrl 38 k | cvtzril 71 k, addrl 15 k | F9 only |
| Over Rev (2C) | movrl 3.9 M, movr 3.7 M, cvtilr 3.4 k | mulrl 1.0 M, divrl 623 k, cmprl 585 k | F9 only |

**In no logged game does an arithmetic instruction write fp0-fp3.** They
receive only values that are exact in a double (moves and conversions), so
the 64-bit decision is invisible except through F9's double rounding. The
spike's §8 decision stands on this evidence; the reason it stands is now
measured rather than argued.

---

## 3. Timing

### 3.1 Appendix C, in our words (chip cycles at 25 MHz)

Execution time is from the start of one instruction's execute to the start of
the next's (PRM C-9, Fig. C-2); fetch and decode overlap.

Pipeline rules (PRM C-2..C-8, C-14..C-17):

- *Bypass:* a REG instruction takes a cycle less when a source is a literal
  or src2 is the previous result; otherwise one more (C-7/C-8).
- *Condition-code scoreboard:* reading the condition code in the instruction
  right after the one that set it costs a cycle (C-8, C-12).
- *Register scoreboard on loads:* execution continues past a load until an
  instruction reads its register; multi-register loads lock a block (Table
  C-1) (C-6/C-7).
- *Bus queue:* up to 3 outstanding requests; a fourth stalls. Stores post
  (C-2, C-16, C-17).
- *Effective address* 0-4 cycles, usually under 2 (C-5).
- *Register sets:* four in all, the current procedure holding one. A call
  with a free set is 9; with none free the **oldest** set is flushed as four
  quad stores, +24 at zero wait. A return is 7, +24 only if the frame it
  returns to was flushed; reload is on demand (C-6, C-14).
- *Integer multiply/divide* run on the FPU's 32-bit Booth multiplier with an
  early out on src1's significant bits (C-8, C-13).
- *Complex FP* instructions are interruptible and resume (C-19).

| class | chip cycles | table |
|---|---|---|
| and nand or nor xor xnor andnot notand notor ornot rotate shlo shro | 1 (bypass) / 2 | C-2 |
| not | 1 | C-2 |
| shli shri shrdi | 2 / 3 | C-2 |
| notbit setbit clrbit alterbit chkbit | 2 / 3 | C-3 |
| extract / modify | 7 / 8 | C-3 |
| scanbit spanbit | 8 best, 11 normal, 14 worst | C-4 |
| mov movl movt movq | 1 2 3 4 | C-5 |
| addo addi subo subi cmpo cmpi | 1 / 2 | C-6 |
| cmpinco cmpinci cmpdeco cmpdeci | 2 / 3 | C-6 |
| addc subc concmpi (the table also prints "subi": a misprint, probably concmpo) | 1 (cc ready) / 2 | C-7 |
| mulo muli | 18 typical, 9-21 by src1 bits (2 -> 9, 4 -> 10, 8 -> 11, 32 -> 21) | C-8, C-9 |
| divo divi remo remi modi | 37 | C-8 |
| emul / ediv | 24 / 40 | C-8 |
| b | 0-2 | C-10 |
| branch if (taken / not) | 0-2 / 0-1, cc ready; 0-3 / 0-2 otherwise | C-10 |
| bx | 0-6 | C-10 |
| bal balx | 2-8 | C-10 |
| compare and branch | 3-5 / 3-4 | C-10 |
| test if | 0-3 / 0-2; 0-4 / 0-3 | C-10 |
| fault if | 0-2 / 0-1; 0-3 / 0-2 | C-10 |
| call callx (a set free) / flush needed | 9 / 9 + 24 | C-14 |
| ret / frame flushed | 7 / 7 + 24 | C-14 |
| ld, next instruction uses it | 4 (zero wait), 5 (one wait) | C-15 |
| ld, next instruction unrelated | net 1-2 | C-16 |
| two loads back to back | 5-6 together | C-16 |
| extra words (ldl ldt ldq) | +1 + waits each: 5 6 7 | C-16 |
| st | 2-3; back-to-back stores 2 each; stall only on a full queue | C-17 |
| dmovt / daddc dsubc | 7 / 8 | C-11 |
| movr / movrl / movre | 5 / 5-7 / 7-8 | C-12 |
| cpysre cpyrsre | 8 | C-12 |
| addr subr / addrl subrl | 9-17 (typ 10) / 12-20 (typ 13) | C-12 |
| mulr / mulrl | 11-22 (typ 20) / 14-43 (typ 36) | C-12 |
| divr / divrl | 35 / 77 | C-12 |
| cmpr cmpor / cmprl cmporl | 10 / 12 | C-12 |
| cvtri / cvtril | 25-33 / 26-35 | C-12 |
| cvtir / cvtilr (the page prints "cvtilr" on both rows) | 41-45 / 42-46 | C-12 |
| cvtzri / cvtzril | 41-45 / 42-46 | C-12 |
| roundr / roundrl | 56-69 / 56-70 | C-12 |
| scaler / scalerl | 28 / 30 | C-12 |
| logbnr / logbnrl | 32-41 / 32-43 | C-12 |
| sqrtrl | 104 | C-13 |
| expr / exprl | 300 / 334 | C-13 |
| logepr / logeprl | 400 / 420 | C-13 |
| logr logrl | 438 | C-13 |
| remr remrl | 67-75,878 | C-13 |
| atanr / atanrl | 267 / 350 | C-13 |
| cosr / cosrl | 406 / 441 | C-13 |
| tanr / tanrl | 293 / 323 | C-13 |
| sinr, sinrl, sqrtr | not given (page image checked) | C-13 |

Table C-13's figures are typical and can vary 30-40% with the operands.

**MAME's counts are a transcription of Appendix C**, mostly the typical or
top-of-range value. Where they differ: mov 2 (Intel 1); shli/shri/shrdi 1
(2-3); b and branch-if 1 (0-3); bal 5 (2-8); bx 3 (0-6); mulr 18 (typ 20);
emul 37 (24); ediv 37 (40); cvtir/cvtilr 30 (41-46); scaler 30 (28); expr 334
(300 -- MAME took exprl's figure under its own "checkme"); sinr/sinrl/sqrtr
borrow cosr/cosrl/sqrtrl's numbers, which Intel does not give. What MAME
leaves out is where it departs from the silicon: wait states, the 512-byte
I-cache's misses, the +24 per register-set flush or reload, the bypass and
condition-code penalties, load/store overlap and the multiply early out. Its
register cache is 4 saved frames plus the current one -- one more set than the
chip's four -- and it spills on every call past that depth rather than on
demand. So the study's rule held: MAME's per-instruction numbers are Intel's,
but its machine is not.

### 3.2 The bus (HRM 3-1..3-14)

| | 80960KB on the board | the core |
|---|---|---|
| clock | 25 MHz | 40 MHz |
| single read | address + data + recovery = 3 cycles + 1 a wait state (120 ns + 40 ns a wait) | 2 cycles + the bridge: ~7.4-7.6 clk_i960 a board/work-RAM read (R927); 38.8 an I/O read held by the TGP FIFO; `ld` ~9.5 in all (237 ns); 2A data-cache hit: `ld` 4 (100 ns) |
| store | posted, 2-3 cycles, 3-deep queue | waits for its acknowledge: `st` 4 + latency |
| burst | one address cycle, then a word a clock (+ waits), up to 4 words, never across 16 bytes: a quad or a line fill is 6 cycles at zero wait | one bus transaction a word: `ldq` 6 + 4L, `stq` 10 + 4L |
| overlap | loads scoreboarded, 3 requests in flight, branches often free | none: every access holds the sequencer |
| I-cache | 512 B direct-mapped, 16-byte lines, look-ahead prefetch and bypass (PRM C-3) | 8 KB direct-mapped, next-instruction prefetch, hit under fill, early restart (R815, R817); a line fill ~25 cycles through the bridge |
| wait states | the game's table at 0x00E00000 (R904; format unresolved) | not modelled (R904's switch is for Sega Rally only and is off) |
| register sets | 4 including the current; the oldest flushed on demand | main: MAME's rule; 2A/2C: a ring of 8 saved frames, on demand (R927) |

Neither manual gives an interrupt latency (HRM 3-32 gives only pin set-up).

### 3.3 The core, measured

A directed harness (`sim/i960/audit/tb_timing.cpp`, `asm.py`, `run.py`,
`t1.py`-`t7.py`) runs `i960_top` from each branch's RTL in a flat memory that
answers every access after a fixed latency L (L = 0: one cycle; the board's
bridge behaves like ~6-8, R927). Cycles per instruction are the clk_i960
cycles between consecutive accepted instructions in a warm loop of 4-6
identical instructions, the median of thousands. Two builds: main
(`VC=1`) and 2A (`FR`, `F2A`, ring of 8, 64-line data cache). Results are the
same in both unless stated. Ratio = core time / chip time; below 1 the core
is faster than the silicon.

| class | core cyc | core ns | chip cyc | chip ns | ratio |
|---|---|---|---|---|---|
| ALU reg, reg | 2 | 50 | 1 / 2 | 40 / 80 | 1.25 / 0.63 |
| ALU with a literal | 2 | 50 | 1 | 40 | 1.25 |
| shli shri shrdi | 2 | 50 | 2 / 3 | 80 / 120 | 0.63 / 0.42 |
| bit ops, cmpinc/dec | 2 | 50 | 2 / 3 | 80 / 120 | 0.63 / 0.42 |
| mov movl movt movq | 2 3 4 5 | 50-125 | 1 2 3 4 | 40-160 | 1.25-0.78 |
| scanbit spanbit | 2 | 50 | 11 | 440 | 0.11 |
| extract, modify | trap | | 7 / 8 | | |
| mulo muli (no early out) | 6 | 150 | 9-21, typ 18 | 360-840 | 0.21 (0.18-0.42) |
| divo divi remo remi modi | 39 | 975 | 37 | 1,480 | 0.66 |
| emul / ediv | 7 / 72 | 175 / 1,800 | 24 / 40 | 960 / 1,600 | 0.18 / 1.13 |
| branch not taken | 2 | 50 | 0-1 | 0-40 | >= 1.25 |
| branch taken (b, bif, cmpob, bbs, bal) | 4 | 100 | 0-2 / 0-3 / 3-5 / 2-8 | 0-320 | 0.31-1.25+ |
| call, a set free | 11 | 275 | 9 | 360 | 0.76 |
| ret, frame resident | 15 | 375 | 7 | 280 | 1.34 |
| call that spills (main: every call past 4 saved frames) | 39 at L0, 135 at L6, ~166 on the board (R927) | 975-4,150 | 33 (only with all 4 sets in use) | 1,320 | 0.7-3.1 |
| ret that refills | main 135 at L6; 2A 55 (the spill's words hit the data cache) | 3,375 / 1,375 | 31 | 1,240 | 2.7 / 1.1 |
| flushreg (L6) | 136 + ~132 a resident frame: 2A with 8 frames 1,060 | 3.4-26.5 us | <= 3 frames x 24 | <= ~3 us | up to ~9 |
| ld (L0 / L6 / the bridge) | 3 / 9 / ~9.5 | 75-237 | 4-5; net 1-2 when overlapped | 160-200 | 0.4-1.5; up to ~6 against an overlapped load |
| ld, 2A data-cache hit | 4 | 100 | as above | | 0.5-2.5 |
| ldl ldt ldq | 4 / 5 / 6 + 2 a word a bus cycle (L6-8: 12-38) | | 5 / 6 / 7 + waits | 200-280 | ~1.1-3.4 |
| st (L6) | 10 | 250 | 2-3, posted | 80-120 | 1.3-3 |
| stl / stq (L6) | 18 / 34 | 450 / 850 | 3 / 5 | 120 / 200 | 3.7-4.3 |
| dependent vs unrelated op after a load | identical (no scoreboard) | | 4-5 vs net 1-2 | | |
| interrupt entry, edge -> handler's first instruction | ~27 at L0, ~63 at L6 | 0.7-1.6 us | not documented | | |
| movr movrl movre cpysre | 5 7 6 6 | 125-175 | 5 / 5-7 / 7-8 / 8 | 200-320 | 0.47-0.88 |
| addr subr / addrl subrl | 5 / 7 | 125 / 175 | 10 / 13 typ | 400 / 520 | 0.31 / 0.34 |
| mulr / mulrl | 5 / 7 | 125 / 175 | 20 / 36 typ | 800 / 1,440 | 0.16 / 0.12 |
| divr / divrl | 61 / 63 | 1,525 / 1,575 | 35 / 77 | 1,400 / 3,080 | 1.09 / 0.51 |
| cmpr / cmprl | 5 / 6 | 125 / 150 | 10 / 12 | 400 / 480 | 0.31 |
| cvtir cvtri cvtzri / cvtzril | 5 / 6 | 125 / 150 | 25-45 / 42-46 | 1,000-1,800 | 0.07-0.13 |
| roundr scaler logbnr | 5 | 125 | 56-69 / 28 / 32-41 | 1,120-2,760 | 0.05-0.11 |
| sqrtr / sqrtrl | 61 / 63 | 1,525 / 1,575 | - / 104 | 4,160 | 0.37 |
| remr (2A, data-dependent) | 4-104 | 0.1-2.6 us | 67-75,878 | >= 2.7 us | <= 1 |
| sinr / cosr (2A) | 2,138-2,380 / 1,935-2,377 | 48-60 us | - / 406 | 16.2 us | 3.0-3.7 |
| tanr (2A) | 4,155-4,373 | 104-109 us | 293 | 11.7 us | 8.9-9.3 |
| atanr (2A) | 3,209-4,095 | 80-102 us | 267 | 10.7 us | 7.5-9.6 |
| sinrl cosrl tanrl atanrl (main) | 2,174 / 1,937 / 4,157 / 4,097 | 48-104 us | - / 441 / 323 / 350 | 12.9-17.6 us | 2.7-8.0 |

The transcendentals are slow because R845's microcode is serial
double-double arithmetic: `tools/i960_fptrans.py` counts ~259 add/sub/mul
micro-operations for sin and ~486 for tan, at ~7 clk_i960 each (2-cycle units
plus the sequencer's issue, no overlap). The divider is not the cost.

### 3.4 Per game

FP share of the CPU's compute time (form-log counts; Intel zero-wait at
25 MHz against the core at 40 MHz; memory excluded):

| game | FP of note (a second) | chip % | core % | transcendentals chip % / core % |
|---|---|---|---|---|
| Manx TT | atanr 925, tanr 38, sqrtr 558, divr 2,007, mulr 13 k | 5.1 | 10.1 | 1.26 / **9.05** |
| Sega Rally | atanr 126, remr 52, divrl 587 | 3.7 | 2.5 | 0.26 / 1.21 |
| VF2 | mulr 32 k, addr 34 k, divr 1.8 k | 5.8 | 1.5 | 0 |
| Motor Raid | sqrtr 5.7 k, divr 7.1 k, mulr/addr/subr ~30 k each | 13.0 | 3.7 | 2.37 / 0.87 |
| Virtua Cop (main) | tanrl 26, cosrl 12, cvtir 4.2 k, divr 1.2 k | 1.6 | 0.75 | 0.06 / 0.35 |
| VC2, Zero Gunner, DOA, Sky Target, HPY, Dynamite Cop | basic forms only | 0.5-7.4 | 0.2-2.0 | ~0 |

Busy windows, from the study:

- **Sega Rally's frame start** (R926/R927): 21,969 instructions. MAME
  2.1 ms (CPI ~2.4 at 25 MHz). The game's own thresholds want it under
  4.3 ms for full opponent detail, so the chip manages it in <= ~4.3 ms (inferred,
  not measured on a cabinet). The 2A core before R927: 5.6-6.9 ms (#19);
  after: 3.9-4.5 ms -- now at the silicon's bound, and the board agrees.
- **Daytona, main** (R817): busy CPI 9.45-13.3 at 40 MHz = 236-334 ns an
  instruction. MAME: 92 ns. The chip, estimated from Appendix C, R817's
  512-byte miss rates and R904's waits: ~120-200 ns (+-50%: the wait-state
  format is unknown). **The main core is ~1.2-2.8x slower than the silicon on
  Daytona's busy code, and MAME is ~1.3-2.2x faster than it.**
- **Manx TT** (R896): atanr alone costs ~1.3 ms a frame more than on the chip
  (7.5% of a vblank).

### 3.5 Timing findings

**T1 -- transcendentals are 3-9x slower than the chip.** Severity **C**:
Manx TT is the one large case (~9% of the core's time against ~1% of the
chip's; "mostly full speed, a few slowdowns", R901). *Fix:* issue the next
micro-op while the current one runs (same microcode, same results), ~2x,
~100-300 ALM, no M10K; proof: `test_i960_fptrans` bit-identical on its whole
vector set, cycle counts from the audit harness. A single-precision algorithm
for the r forms would be faster again but changes results: reject unless the
overlap is not enough.

**T2 -- main keeps MAME's register-cache rule.** Every call past 4 saved
frames spills 16 words and every matching return refills them (~166 clk_i960
a call on the board, R927); the chip flushes only when all four sets are in
use, oldest first, and reloads on demand (PRM C-6, C-14). This was 25-30% of
Sega Rally's frame start before R927. Severity **C**: Virtua Cop (#28) and
Desert Tank run on main; call depth for them was not logged. *Fix:* port
R927's ring and data cache to main, holding 3 saved frames + the current one
to match the chip's four sets exactly (I9). `i960_regs` requires a
power-of-two ring, so this is a 4-slot ring capped at 3 (~20 ALM); 1 M10K +
~86 ALUT for the cache. *Play:* the CPU only gets faster;
the save areas it changes are undefined until `flushreg` on the chip.
*Proof:* `test_i960_regs_ring` / `test_i960_top_ring` at the chosen depth,
and a whole-core Daytona/VCop boot whose spill count per call matches a
4-set model of the same call stream.

**T3 -- the 2A ring is deeper than the chip.** 8 saved frames against the
chip's 4 sets including the current one: 2A spills less often than the
silicon, and `flushreg` writes up to 8 frames (DOA runs 1.5 k a second: up to
~4% of the core's time). Severity **C** (a speed difference, and a memory-stream
difference only inside save areas). *Fix:* the chip's depth (3 saved, as T2).
But the core's spill is ~4x the chip's (one bus transaction a word, no
bursts), so moving 2A from 8 to 3 saved frames alone would make Sega Rally's
frame start slower than the silicon again (R927's model: 4 frames, 9 frame
transfers a window, 8 frames 0.02). Do it only with T4's burst spills; proof
as T2 plus R927's Rally window.

**T4 -- no load overlap, no posted stores at the CPU, no bursts.** Every
access holds the sequencer; a dependent and an unrelated load cost the same;
a quad access is four bus transactions. The chip runs up to 3 requests in
flight and posts stores. The largest single term in busy windows
(memory wait 24-32% of cycles, R896/R927; Motor Raid runs 40 k stq and 25 k
ldq a second). Severity **C**. *Fix:* a CPU-side store buffer (est. -5%
cycles), bursts for ldq/stq through the bridge (moderate), a load scoreboard
(pipeline work, large). Speed only; proof by the lockstep (results
unchanged) and the harness's cycle table.

**T5 -- basic FP, integer multiply, conversions and scanbit are much faster
than the chip** (mulr 6.4x, addr 3.2x, cvt 8-14x, roundr 18x, mulo 4.8x,
emul 5.5x, scanbit 8.8x); simple ALU ops are 1.25x slower than a bypass hit,
a taken branch 100 ns against 0-80 ns, ret 1.34x slower. Severity **N** on
its own (game code is memory- and fetch-bound, R814/R817/R927). No fix.

**T6 -- CPU pace feeds game logic.** Sega Rally's timer-read opponent-detail budget (R926)
is the proven case. MAME's i960 is faster than the chip and main's is slower
(section 3.4); any game with a budget of the same kind takes paths on the
cabinet that neither takes. *Check, per game:* a MAME read tap on the timers
(0x00F00000-0x00F0000F) inside the frame, then R926's clock patch at
10 / 16 / 25 / 40 MHz. (Raised for Daytona #34, since found to be the
arcade's own behaviour, R969.) Severity **C**.

**T7 -- too fast?** The 8 KB I-cache, the 2A ring and the fast FP make cached
loops and FP-heavy code faster than the chip, and wait states are not
modelled. No game is known to misbehave from it; R904's wait-state switch is
the tool if one does.

**T8 -- forms that trap in every build** (extract, modify, cvtril, expr,
logr, logepr; cvtilr outside 2C): none of the logged games runs them.

---

## 4. The Daytona #34 cross-checks

Since this audit started, real-cabinet footage has shown the arcade doing the
same thing (R969, branch `daytona-wall`): #34 is the game's own behaviour, not
a fault. The three checks below were asked for while it was open; their
answers stand on their own, and nothing in them is a reason to change the
core for #34.

1. **cvtri / roundr ties** (`i960_fpmisc.sv:198`, half away from zero, as MAME's
   `round()`; the manual's mode 00 is ties-to-even). This is F1, measured
   game by game: Daytona 89 one-unit differences in 150 s, VF2 3,175 in
   120 s, VC2 14 in 120 s; every other game 0 (no `cvtri` or no ties).
   Daytona's sites 0x109b0 and 0x11be0-0x11c04 follow the yaw/heading code
   at 0xffe8-0x10820.
2. **addr / subr in double, then narrowed.** When both operands are singles
   the double result is exactly representable or rounds once to 53 bits, and
   because 53 >= 2 x 24 + 2 the second rounding to single always equals a
   single correct rounding (double rounding is innocuous for + - x / and
   sqrt under that condition). Checked: 20 M random pairs per operation with
   exponents up to 60 apart, the host's float32 result against the double-
   then-narrow result: **0 differences** for add, sub, mul and div. So the
   KB's single rounding and the core agree on every single-in, single-out
   operation, in every game. The two-roundings case that can differ is only
   F9: a single-precision instruction reading a **double** from fp0-fp3
   (Rally, DOA, Dyn, ZG, Sky, Over Rev; ~2^-29 an operation, 0 in 900 k
   random checks). Daytona never reads fp0-fp3, so for Daytona this item is
   provably not a source of difference.
3. **fp0-fp3 and long reals, game by game:** section 2.3. Daytona, VF2 and
   VC2 never touch fp0-fp3; every other game writes them only with exact
   values and never stores an arithmetic result there, so the 64-bit decision
   (spike §8) holds for every logged game, with F9 as its one, practically
   unreachable, exposure.

---

## 5. Recommended fix order

Each fix moves the core toward the manual; each is proven by a bench that
checks the PRM's own definition (directed vectors written from the
instruction's Action line, plus a reference switch in `sim/i960/*_ref.h` so the
whole-CPU lockstep runs both the MAME and the PRM behaviour), then the board.

1. **F1, cvtri ties-to-even and saturation** (30-50 ALM, all branches). The
   one semantic difference that is clearly documented, cheap, and reached in
   play: Daytona, VF2 and VC2 compute a different integer than the cabinet
   at measured sites. It changes play in those three games, toward the
   silicon.
2. **T6, the timer check** (MAME only, no RTL) for Daytona, Virtua Cop and
   Desert Tank: do they read the timers inside a frame and branch on them,
   as Rally does? It must come before any change to main's speed (step 3),
   because that change moves the pace those games see.
3. **T2, the chip's register-set rule on main** (4-slot ring capped at 3
   saved frames, plus R927's data cache). Speed only; brings main from MAME's
   spill rule to the chip's. Then measure Virtua Cop's truck scene (#28) on
   the whole-core bench before and after.
4. **The zero-cost conformance batch**: I2 (cc bit 2), I3 (dmovt), I4 (modi),
   I7 (faultno falls through), I10 (interrupt priority set, trace cleared),
   I13/F6 (movre's third word out of the SAT), and the cheap half of F2
   (normalise subnormal single inputs: the boot table then matches MAME and
   the chip). No logged game reaches any of them except F2's table, so they
   cannot change current play; they remove known departures before a game
   finds one.
5. **T1** (overlap the transcendental micro-ops; Manx TT) and **T4** (a store
   buffer, then ldq/stq bursts; measure Motor Raid's #25 window first).
   Speed only. T3 (2A's ring depth to the chip's) only after T4's bursts.
6. **I1, subc**, only after a board test settles which sense the silicon has
   (`cmpo 0,0` then `subc 1,1,r`: 0 under the manual's reading, 0xFFFFFFFF
   under the core's). The manual's line is misprinted and the games' own
   compiled code assumes the core's sense, so this is the one finding where
   the documentation is not enough to act on.
7. Larger and unreached: I5 (AC.of), F4 (FP flags), F5 (NaN payloads), F3
   (rounding modes), I8 (IACs), I6 (faults), I12 (the trapped instructions),
   F7, F8, F9. Worth doing only when a game is found that reaches one.

Fix first: **F1**. It is the only difference where the manual is unambiguous,
a game demonstrably computes a different value from the cabinet, and the fix
is small.

---

## 6. Not settled

- **subc's carry sense on the silicon (I1).** The manual's action line is
  misprinted; the games' compiled chains assume a borrow. A board test
  decides it.
- **The wait-state format (R904).** Every "chip ns" above that includes wait
  states is +-50% on it; an arcade bus capture or the Rally expert's answers
  settle it.
- **The chip's real busy CPI on game code** -- inferred from Appendix C,
  R817's 512-byte miss rates and Rally's 4.3 ms budget, never measured on a
  cabinet. Nor its interrupt latency (neither manual gives one), nor how much
  of a 512-byte cache miss its look-ahead hides.
- **Per-game call depth** on main (Virtua Cop, Desert Tank, Daytona): the
  form log does not record it; the whole-core bench's 'P' line (R927) does.
- **What IAC 0x93 (reinitialise) does to priority, FP state and AC** (13-10
  is silent; 7-14 covers power-on only). Every game sends it once at boot,
  then sets its own PC/AC, so the effect is probably nil.
- **What 6E1 does on the silicon** (F6), whether anything reads a NaN's sign
  or payload (F5), and subnormal operands outside the boot table (F2: the bulk
  FP ops were not operand-logged, to avoid rebuilding MAME).
- **Coverage.** Dynamic integer checks ran on Daytona, Virtua Cop, VF2, Rally,
  Zero Gunner, VC2, DOA and Manx TT (90 s each); Desert Tank could not run
  (its parent set is missing locally); Motor Raid, Dynamite Cop, Sky Target,
  Pilot Kids, HPY and the 2C sets have static scans and form logs only. For
  Rally and Zero Gunner (which run from a RAM copy) only the form-log counts
  are evidence, not the value breakpoints.
- **Sega Rally runs in user mode** after its boot (its own type-7 return sets
  PC = 0). The core does not model modes; Rally executes nothing
  mode-dependent, so the result is the same.

---

## 7. Reproducing

- `sim/i960/audit/tb_timing.cpp` with `asm.py` / `run.py` / `t1.py`-`t7.py`:
  the directed timing harness. From the branch's top directory:
  `verilator --cc --exe --build -Wno-fatal -Wno-lint -Wno-style --timing
  -Irtl/cpu/i960 --top-module i960_top -GVC=1 --Mdir obj_timing -o Vtiming
  rtl/cpu/i960/i960_{dec,alu,regs,agu,ldst,lsu,memmap,icache,muldiv,fpmul,fpadd,fpdiv,fpsqrt,fpmisc,fpcvt,fptrans,top}.sv
  sim/i960/audit/tb_timing.cpp` (2A: add `i960_fprem.sv` and `i960_dcache.sv`,
  and `-GFR=1 -GF2A=1 -GRC_RING=1 -GRC_FRAMES=8 -GDC_LINES=64 -GDC_LANES=0`
  in place of `-GVC=1`), then `python3 sim/i960/audit/t1.py obj_timing/Vtiming [L]`
  (t1 ALU, bit ops, moves and multiply/divide; `t2.py <bin> 0,6` loads and
  stores at each latency; t3 branches, call/ret and flushreg; `t4.py <bin>
  main|2a` the FP forms; `t5.py <bin> main|2a` data-dependent multiply,
  remr and transcendentals; t6 interrupt entry; t7 call depth and spills.
  Each writes `prog.hex` where it runs).
- `sim/i960/audit/rscan.py` (candidate `cvtri`/`roundr` sites in a program
  ROM, as breakpoint lines for `sim/io/mame_m2_bphits.lua` with `BP_VALS`),
  `tieana.py` (classifies the logged operands: exact ties, which differ
  between half-away and half-even), `dblround.py` (the mixed-precision
  double-rounding check).
- Everything ROM-derived (form logs, operand logs, disassembly) stays outside
  the repository.
