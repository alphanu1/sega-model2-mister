**R839 -- VIRTUA COP: THE TYPE-2 I/O BOARD (MODEL1IO2) AND FOUR i960 FORMS;
WHY THE BOARD SHOWED BLACK. FIRST STEP: A BOOT BUILD.**
(DRAFT for docs/model2a-design-study.md section 10. Board, s1104 / s1112
era, Virtua Cop MRA with the type-1 firmware epr-14869c: a black screen, the
framebuffer-clear counter at ~11 fps.)

*Believed:*
  * R726: the MRA's layout is right and the game "boots on Daytona's hardware
    model" if the type-1 firmware will do; "if the game refuses to start on
    the type-1 firmware, that is the type-2 board this core does not have".
  * R832 / Model 1 docs/io-board.md: the type-2 board is a TMPZ84C015 (Z80
    + CTC + dual SIO + PIO) and much of it "may be dead weight for a single
    cabinet"; the CTC's role was the open question. Its firmware is 64 KB
    with 32 KB mapped, so the ROM array was expected to double (+16 M10K).
  * R836: Desert Tank's long-real forms were the last i960 gap.

*Now known -- VERIFIED:*
  1. WHY BLACK -- TWO CAUSES, EITHER SUFFICIENT. (MAME 0.289,
     sim/io/mame_m2_snaps.lua, a snapshot every 0.5 s.)
     a. Without its own I/O board the game never leaves the boot: with the
        board's Z80 suspended from power-on (the debugger's "suspend") the
        screen is black for all 20 s and the i960 sits at 0x2384-0x2394.
        Normally: black 0-4 s ("memory destroyed" briefly at 2.5 s on a
        fresh NVRAM), the WARNING screen 4.5-14.5 s, the 3D attract from
        15 s.
     b. The i960 executes cvtzril first at 3.287 s (frame 188, before the
        WARNING screen), and the RTL trapped on it: the core halts there
        whatever the I/O board does.
     The ~11 fps clear count on the board is not examined (INFERRED: the
     renderer's own clears; the i960 cannot have flipped past 3.3 s).
  2. WHAT EPR-17181 USES (sim/io/mame_m2_vcop_io.lua; boot, attract, a coin,
     a game with a gun swept and fired, a continue; 300 s):
       - ROM 0x0000-0x31ff only; the file is 0xff from 0x3200 and nothing at
         0x3200-0x7fff is ever read. The type-1 board's 16 KB array holds it:
         NO NEW M10K (not +16).
       - RAM 0xf000-0xffff only (4 KB); 0xe000-0xefff never touched. The
         type-1 board's 8 KB array covers 0xe000-0xffff.
       - IM 2, I = 0, ONE interrupt source: CTC channel 1 (control 0xa5:
         timer, prescale 256, interrupt on; constant 0x26 = 38; vector base
         0xe8 from channel 0) -> vector 0xea -> handler 0x0a05, 1,010.5 / s
         measured (9.8304 MHz / 256 / 38). The handler does the board's work
         (inputs, guns, DPRAM); mean 519.6 us, max 643.7 us in MAME.
       - SIO A / B: initialised only (SIO A's receive interrupt is enabled,
         nothing is attached); PIO: data ports read 0xff (DSW2 / DSW3);
         TMPZ84C015 watchdog (0xf0 = 0xfb, 0xf1 = 0x4e once) and daisy
         register (0xf4 = 0): written once. None modelled.
       - 315-5338A: direction 0x07 -- PA / PB / PC are inputs IN0 / IN1 /
         IN2 (type 1: PB / PC / PD); PF drives the 93C46 (bit 6 DI, 5 CLK, 4
         CS), its DO read at 0x8040 bit 6; PG7 the MB3773 watchdog, PG6 the
         ADC bank; PD the lamps / recoil.
       - 0x8100 "FPGA": 5,120 bitstream writes; reads 0x80 until 0x1400 of
         them, then the four gun coordinates and the off-screen byte.
       - MSM6253 at 0x8200 (mirror 0x8204): every read 0x01 (no channel
         bound).
  3. TWO REFERENCE DETAILS THE TYPE-1 MODEL DOES NOT FOLLOW, found by the
     firmware bench, fixed for type 2 ONLY (Daytona must not move):
       - 315-5338A status (0x0d): the core returns {4'd0, 3'b001, busy} =
         0x02 / 0x03, bit 3 CLEAR, against its own comment ("bit 3 stays
         set"); MAME returns 0x08. EPR-17181 polls bit 3 up to 32 times on
         every DPRAM read (0x15bd): its boot ran 2.7x slow and the game's
         command 3 arrived before it listened. Type 2 returns 0x08 | busy.
         THE TYPE-1 BOARD HAS THE SAME FAULT: EPR-14869C on the core against
         a MAME Daytona '93 capture writes DPRAM 0x21 9,252 times in 30 s to
         MAME's 33,079 and starts 1.8% late. Not touched here; a question
         for a Daytona build, not this one.
       - 93C46 read timing: MAME's 93Cxx puts the dummy 0 out as the
         address's last bit is clocked and shifts on the FALLING clock,
         ones after D0; the core shifts on the rising clock (one bit late
         against MAME). EPR-17181 read 0x7fff for 0xffff. Type 2 follows
         MAME.
     And tv80's own timing: it latches an IN byte and the IM 2 vector at the
     end of T2, after IORQ has lifted, so the board holds both until the
     next memory cycle / M1's end.
  4. THE FIRMWARE BENCH (sim/io/tb_m2_ioz80_t2.cpp, make test_m2_ioz80_t2):
     m2_ioz80 TYPE2 on EPR-17181 with the game's DPRAM writes replayed from
     a MAME capture (VC_GUNFIX=1: guns held, nothing pressed), 30 s: CTC
     interrupts 1,010.53 / s (MAME 1,010.5); first DPRAM write 2.1623 s
     (MAME 2.1623 s); 59,084 DPRAM writes (MAME 59,105); all 157 DPRAM
     addresses with MAME's sequence of values; the first 844 writes in
     MAME's exact order; handler 50.5% of the time (MAME ~51%). Before the
     three fixes in (3) and the IN / vector holds it failed (1 interrupt; 0
     writes; 0x7f bytes; DPRAM 0x0c = 0x00).
     Type 1 unchanged: make test_m2_ioz80_t1same (EPR-14869C, a MAME Daytona
     '93 capture replayed, 30 s, 36,908 DPRAM writes): the trace hash of
     every DPRAM write and every opcode fetch with its cycle is equal on a
     TYPE2=0 and a TYPE2=1 build (de296b799108f18a).
  5. THE i960 (R836's method). Static scan (tools/i960_fpscan.py) of the
     512 KB program: trapping candidates cvtilr, logr, atanrl, sqrtrl,
     sinrl, cosrl, tanrl, cvtzril, cpysre. MAME breakpoints on all 99
     (sim/io/mame_m2_bphits.lua, coins at 40 s and 250 s, 480 s, a gun
     swept and fired): EXECUTED -- cvtzril (from 3.29 s), tanrl and cosrl
     (14.73 s), cpysre, sqrtrl, atanrl (18.3 s), sinrl (169.6 s); counts in
     480 s: cosrl 14,658, tanrl 13,395, cpysre 31,915, cvtzril ~150,000,
     sqrtrl 10,035, atanrl 78, sinrl 80. NEVER: cvtilr, logr. Non-FP forms
     outside Daytona's static set are all ones MAME and the RTL implement
     (nor, addc, spanbit, emul; MEMB modes 5/d/e/f). Timers: one write at
     2.5 s, no reads (Desert polled one); IRQs as Daytona (intena 0x001 /
     0x401).
     Operand values (MAME, 300 s): cosrl 0.3927 / 0.6283 / 3.14-3.99, tanrl
     0.056-0.275, sinrl 3.14-3.99, atanrl args 0-36, sqrtrl 0.007-0.197;
     cvtzril results -57,796..39,835 (inside int32).
  6. THE FORMS ADDED (i960_top VC = 1, live only while vc_en = game ID 1):
     sqrtrl (the existing double square root on the long-real path), cpysre
     (MAME: src2 >= 0.0 ? |src1| : -|src1|), cvtzril (cvtzri, its sign into
     the high word of the unmasked pair dst, dst + 1). Reference model
     extended; lockstep +vc, 60 seeds: 1,499 sqrtrl, 1,679 cpysre, 1,680
     cvtzril retired, 0 mismatches. Planted faults (sign inverted, high word
     zero, sqrt not started) all caught. Default build's test_i960_top output
     byte-identical to be50862's, and the VC=1 build with vc_en low too;
     test_i960_top_irq / _lat, test_i960_rom PASS.
  7. THE CORE: Model2.sv VCOP_IO (1), VCOP_GUN (0 in this build), VCOP_FPU
     (1). MRA index 3 is epr-17181.6 (crc 1add2b82; vcopa.zip, vcop.zip,
     model1io2.zip); tools/rom_csum.py + mra_vs_mame.py: all 11 slots PASS.
     lint_top clean, lint_idx the same 147 findings, quartus_map
     --analyze_file 0 errors (m2_ioz80, m2_vcop_guns, i960_top, Model2).
     AREA, quartus_map 17.0, whole design (Model2), the same tree three ways:

       build                          ALMs est.  ALUTs   registers  block bits  DSP
       be50862 (before)                 39,713   56,620    48,387   4,355,199   90
       this, M2_VCOP_IO=0 / FPU=0       39,731   56,633    48,387   4,355,199   90
       this, as committed (IO, FPU on)  39,864   56,940    48,532   4,355,199   90

     So VCOP_IO + VCOP_FPU cost ~+133 ALM estimated (+307 ALUT, +145
     registers) and NO block memory. Off is the old core in registers,
     memory and DSP exactly; its +13 ALUT (+0.02%) is spread as +-1..7 over
     modules the change does not touch (ascal, fpadd, m2_geometry, m2_geo),
     i.e. synthesis perturbation from the changed source, not logic -- the
     benches show the behaviour byte-identical (test_i960_top output,
     test_m2_ioz80_t1same hash). R836's +135 estimated was +91 placed.

*Not done -- the boot build stops at 14.7 s:* tanrl / cosrl (14.73 s, as
the attract's 3D starts), atanrl (18.3 s) and sinrl still trap. MAME
computes them with the host's libm (tan, cos, sin, atan2). Planned: a
microsequencer in i960_top that runs Horner polynomials on the existing
double add / mul / div units (range reduction by the 1.5 x 2^52 rounding
trick, constants and microcode in M10K); estimated ~150-250 ALM + 2-3
M10K, a few hundred cycles each (they run ~60 times a second).

*Also built, off (VCOP_GUN = 0):* rtl/io/m2_vcop_guns.sv -- two guns from
MiSTer's left analog axes (absolute; MiSTer's light-gun delivery) or a mouse
for P1, Trigger / Reload (Reload = off-screen + trigger), P2 buttons from
joystick 1, IN0 / IN1 to MAME's vcop map, MAME's 5% off-screen rule; a '+'
crosshair per gun drawn by inverting the picture; OSD lines (Crosshair, Gun
1 Stick / Mouse, Gun reload Shoot off-screen / Auto = DSW1 bit 0) shown only
for game ID 1. Not yet benched.

*INFERRED (each with what settles it):*
  a. The boot build shows the WARNING screen from ~4.5 s and halts at
     ~14.7 s (the first tanrl). The board.
  b. Nothing else Virtua Cop's first 15 s needs is missing: the I/O
     handshake is the bench's, the FP forms the breakpoints', the timers
     unused. The board.
  c. The handler's 3% longer run on tv80 (5,259 vs 5,108 Z80 cycles in the
     first 6 s) is tv80's instruction timing and harmless. The board.
  d. The watchdogs (TMPZ84C015 WDT, MB3773) do not matter: MAME does not
     reset the board on them and the game runs.
