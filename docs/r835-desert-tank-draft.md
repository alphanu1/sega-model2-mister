**R835 -- DESERT TANK (MAME `desert`) ON THIS CORE: AN MRA, GAME ID 2, AND
ITS IN1. NOTHING ELSE IN THE CORE IS DAYTONA'S. NOT YET ON THE BOARD.**
(DRAFT for docs/model2a-design-study.md section 10; R832 asked "why MAME
flags it not working -- not yet checked", R833 asked for its gameplay before
YM_STUB is set for it.)

*Believed:*
  * R832: Desert Tank is the same original Model 2 board as Daytona (Model 1
    I/O board, epr-14869c), "a candidate for THIS core with its own MRA and
    input mapping".
  * R833: its FM was silent over 200 s of attract only; "gameplay must be
    measured before YM_STUB is set for them".
  * R725: "the TGP's microcode is transcribed into the RTL".
  * R306 / rom-layout.md: tools/rom_csum.py cannot see padding, so no
    padded MRA could be checked by the project's own tool.

*Now known -- VERIFIED:*
  1. MAME 0.289 (build/mame289-mip, sim/io/mame_m2_desert.lua; coin at 60 s
     and 260 s, start, accelerator held, wheel swept, machine gun and cannon
     fired; 420 s) BOOTS, ATTRACTS AND PLAYS: mission select, two games, the
     desert and canyon stages, score, the ranking screen.
  2. THE FM IS NEVER VOICED. 728,064 YM3438 writes (103,922 attract,
     624,142 play): the init block once per sound-program start and timer B
     reloads (0x27 <- 0x2A, 312,071 in play); no key-on with an operator bit,
     no TL below 127, no F-number. ymsnd: 23,333,101 samples, 0 non-zero.
     Daytona '93 on the same script: the same picture. YM_STUB 1 (the
     release) is right for Desert Tank.
  3. THE TGP RUNS THE SAME PROGRAM. MAME's TGP program RAM after the upload
     (copro_ctl1 bit 31, the FIFO port) is 2024 words, crc32 d6d611dd, in
     desert and daytona93 alike, and equal word for word to
     tools/extract_tgp_microcode.py's copy from Daytona's data ROM.
     CORRECTION to R725: the core does not carry a transcribed microcode --
     m2_copro writes the game's own upload into m2_tgp's program RAM
     (uc_we); the README is right.
  4. THE RTL TGP IS BIT-EXACT ON DESERT TANK. Two 30-frame gameplay windows
     captured with sim/tgp/tgp_capture.lua (frames 6000 and 9001; 35,124 /
     30,049 FIFO words in, 27,468 / 22,599 out) replayed through m2_copro
     (tb_tgp_replay, lat 6): every output, every i960 pop, every io read
     and write equal to MAME, 0 NaN-encoding differences, unimplemented-
     opcode flag 0 cycles -- "PASS (bit-exact against MAME)". Desert Tank
     calls TGP functions 07, 0e, 18, 1f, 2d and 2e, which the Daytona race
     capture (race5400) does not; they are covered. TGP load: 74.6 / 71.3
     ms per 30 frames at 80 MHz (the Daytona race: 121.6).
  5. RENDER MODE. Desert writes 0x10000000 once (0, the 30 Hz mode; IP
     0x3713c) and videocontrol once (1); its main loop waits for the vblank
     count to change and then to be even (0x2fc18-0x2fc3c) and flips
     0x803008 28-29 times a second (303 of 420 seconds at 29). The core's
     0x98000c already returns framenum[1] in bit 2 when render mode is 0
     (R765), and its walk runs after the game's flip (R764), so a 30 Hz
     game is what the Daytona race already is.
  6. WHAT IT TOUCHES THAT DAYTONA DOES NOT (the same script on daytona93,
     i960 accesses by address outside RAM and program ROM, diffed):
       - the TIMERS, 0x00f00000: timer 0 loaded with 0xfffff once a game
         frame and read 1.6 M times in 150 s. This core has no timers;
         those reads return 0. Disassembly (MAME's debugger): the main loop
         (0x2fb30) and the task scheduler (0x30910) compute elapsed
         microseconds per task and per frame from it, store them (task
         +0x14, max +0x18) and count overruns past 0x87d0 us at 0x5212e0 --
         a profiler. MEASURED HARMLESS: with every timer read forced to 0
         in MAME (DT_TIMER0=1; the tap takes -- the game's "remaining"
         word at 0x5212dc reads 0x87d0 against 0x5b58-0x7f27 with real
         timers), 241 snapshots, one a second over 240 s (attract, coin,
         mission select, a game), are byte-identical to the real-timer run,
         and so are the flips per second and the YM log. No timers needed.
       - comms RAM 0x01a00000: 2 writes, no reads (the core drops them, as
         an unpopulated comms board would);
       - geo_r 0x801xxx: 7 reads (MAME and the core both return 0);
       - backup RAM 0x01d01000-0x01d03fff: within the core's 16 KB;
       - main_data reads end below 9 MB (0x028fffff), as its ROMs do; nothing
         at 0x06000000.
     Daytona-only: geo_r 0x802008 polling, data 9-10 MB, DPRAM words 5/8.
     DSWs: MAME declares all three banks unused (0xFF, the core's value).
     Outputs (lamps, gun and cannon motors) go to lamp_output_w: not
     modelled, not needed.
  7. INPUTS. MAME's ports: IN0 is Daytona's bit for bit (VR1-3 at
     0x20/0x40/0x80); IN1 0x01 Shift (PORT_TOGGLE), 0x10 Machine Gun, 0x20
     Cannon. The analog ranges: MAME gives 0x00..0xff with no MINMAX, but
     the game clamps -- accelerator 0x20 == 0x00 ("GAS PEDAL", the tank
     stands) and 0xe0 == 0xff, wheel 0x20 == 0x00 and 0xe0 == 0xff: the same
     run, every snapshot identical for 61 s of play. So Daytona's
     0x20..0xe0 ADC values serve unchanged.
  8. THE MRA. mra/Desert Tank.mra (+ [15kHz CRT], 82 on index 4): the '93
     layout, zero-padded, program second half at 0x2BE0000, game ID 2.
     tools/rom_csum.py (now folding repeat, inline parts and offset /
     length, CRC-first like MiSTer's FileOpenZip) builds 0x2C20000 bytes;
     tools/mra_vs_mame.py (new; parses ROM_START and loads by CRC with
     MAME's semantics, sharing no code with rom_csum) passes all 11 slots
     against ROM_START(desert) and finds the 68000 vector at 0x2340000 where
     the core's scan will. Same tool: vcopa passes; daytona93 differs only
     where it should (textures above 4 MB, MAME's hole; no program second
     half). Planted faults caught: a swapped interleave, FF padding, a wrong
     CRC. The 43.62 MB Daytona images are unchanged (md5 dbd71f6d...).
  9. THE CORE. game_id 2 = is_desert; prog_ext = is_vcop | is_desert (R726's
     path, tb_m2_cpu_bridge 925 / 0). The cabinet-input block moved to
     rtl/io/m2_cab_inputs.sv; with is_desert its IN1 is {11, ~Gear Down,
     ~Gear Up, 111, ~shift} where shift toggles on each press of the VR4
     button (reset: released = forward, MAME's default). CONF_STR is
     unchanged: the MRA renames the buttons (<buttons names>, Model 1's
     scheme) -- VR4 -> Shift, Gear Up / Down -> Machine Gun / Cannon.
     tb_m2_cab_inputs (new, in `make test`): game ID 0 against the block as
     it was at 0f3cbc4, 30,000,000 output checks, 0 differences; game ID 2,
     30,000,000 checks against MAME's IN1, 0 differences, 1,978 shift
     toggles. Five planted faults all caught (a gear-table entry, shift on
     level, gun / cannon swapped, Desert pedal at rest 0x00, shift reset
     pressed). lint_top clean; lint_idx the same 147 lines; quartus_map
     17.0 --analyze_file on m2_cab_inputs.sv and Model2.sv: 0 errors (the
     -8'sd128 overflow warning is the old line, also in the reference).

*Why MAME flags it MACHINE_NOT_WORKING:* not recorded -- no comment in
model2.cpp, no per-game TODO, and the only commit naming it since 2018 is a
2024-10 ROM-name fix (mpr-16964/16965 .20/.21). In MAME 0.289 it plays (1);
one gameplay snapshot (frame 6031) shows a large stray flat polygon across
the left of the screen, the kind of 3D fault that earns the flag (INFERRED).

*INFERRED (each with what settles it):*
  a. It boots and plays on the core. The board.
  b. The zero timers change nothing past the 240 s measured (6) -- e.g. a
     long session whose overrun count is shown in a test screen. The
     board's service menu.
  c. Polygon ROM reads stay below 8 MB (MAME masks the 8 MB region; the
     core reads zeros at 8-13 MB and the program at 13-16 MB). A tap on
     geo_object_data's oba in MAME, or the board.
  d. Area: +10 ALM or less (a 7-bit compare, an OR, two flops, an 8-bit
     2:1 mux); the hierarchy move costs nothing. A fit.
  e. The texture-header reads land inside 0-4 MB, where the slot equals
     MAME's region (Daytona's second pair sits at MAME 8 MB, collapsed to
     4 MB in the slot). The board.
  f. The player needs model1io.zip or a Daytona zip for epr-14869c.

*Decision:* Desert Tank is this core plus an MRA, game ID 2 and an IN1 mux
behind it; YM_STUB 1 stays. Next: a fit, then Ben on the board.
