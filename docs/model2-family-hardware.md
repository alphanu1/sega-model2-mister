<!-- SPDX-License-Identifier: GPL-3.0-or-later
     Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1 -->

# The Model 2 family, board by board: the hardware, and what is done

This document lists every part of the four Model 2 boards, with a status for
each. It started as a review of study entry R832, and the review's findings
are study entry R919 (`docs/model2a-design-study.md`). The hardware facts come
from MAME 0.289's source: `src/mame/sega/model2.cpp` (machine configs, memory
maps, `GAME()` lines), `model2_v.cpp`, `m2comm.cpp`, `model1io.cpp`,
`model1io2.cpp`, `315_5649.cpp`, `315-5881_crypt.cpp`,
`315-5838_317-0229_comp.cpp`, `segabill.cpp`, `dsbz80.cpp`, `dsb2.cpp`,
`shared/segam1audio.cpp`, and the CPU cores in `src/devices/cpu/{mb86233,
mb86235,sharc}`. The implementation facts come from branches `main` (the
original Model 2 core) and `model2a` (the Model 2A core), at `b0c1790` and
`8e40e35`.

Two cautions carry over from R832. MAME's `MACHINE_NOT_WORKING` flag
describes MAME's emulation, not the hardware: five 2A sets that MAME flags
as not working play on the 2A core. And a board is what MAME models, which
may differ from a real PCB in details MAME leaves out.

**Ben's decision (2026-10-13, R832) still stands: Model 2B-CRX and 2C-CRX
are documented only, not implemented.** Their tables below say what the
existing work already covers, what would change, and what would be new, so
that the decision rests on a stated gap and not on a guess. The MB86235
(2C) is sized by a measured skeleton (R920). The SHARC (2B) is still R919's
scaled estimate, and says so.

## Legend

| Status | Meaning |
|---|---|
| ✅ | Implemented, and working on the board in one of the cores. Names the core (`main` = Model 2, `2A` = Model 2A) and the module. In the 2B and 2C tables it means "covered as is by that module". |
| ⚠️ | Implemented, with a known open issue. The issue is named (a GitHub issue number or a study entry). |
| **Changed:** | Exists in a core, but the board needs it altered. Says what changes. |
| **From …:** | Not in this core, but another core or Model 1 has it. Says what to take. |
| **New:** | Nothing to take. Says what would have to be built, with a size where the study has one. |
| — | The board doesn't have it. |

Sizes in ALMs and M10K are taken from s1248's fitter report (a 2A build,
2026-10-20, 41,434 ALM, 553/553 M10K) unless another build is named. The
device has 41,910 ALMs, 553 M10K and 112 DSP blocks. The 2A beta's current
build, s1278, is 41,389 ALMs and 547/553 M10K. The Model 2 release, s1287,
is 41,063 ALMs and 553/553 M10K.

## Summary: what each board shares with the one before it

- **Common to all four boards:** an i960KB at 25 MHz, the System 24 tilemap
  chip, the palette and colour tables, the 3D renderer and the geometrizer
  (which MAME models as one piece of high-level code for every board), the
  main-board RAMs (1 MB of work RAM, 128 KB of geometry buffer RAM, 16 KB of
  battery-backed backup SRAM), the four timers, the interrupt controller,
  the comm board interface at 0x01a00000, and the video timing (as MAME
  models it). Both cores carry all of these except the timers (the 2A core
  only) and the comm board (built only on branch `link-play`).
- **Model 2A-CRX vs the original Model 2:** the main CPU, the TGP and the
  video are the same. The sound board changes completely (an SCSP and a
  68000 replace the Model 1 sound board). The I/O changes completely (a
  315-5649 on the main board, read directly by the i960, replaces the Model 1
  I/O board's Z80 and dual-port RAM). It adds a 93C46 EEPROM and optional
  protection chips. The board RAM grows from 128 KB to 256 KB, and the
  program-ROM mirror is gone. **This is the 2A core, and it is done:**
  eleven games play.
- **Model 2B-CRX vs 2A:** the same sound, I/O, EEPROM, protection chips,
  tilemap and renderer. The TGP is replaced by an ADSP-21062 SHARC running
  code the game uploads. The texture and luma RAMs move to new addresses
  with a plain 32-bit layout. The sound UART moves. **Everything except the
  SHARC is already built.**
- **Model 2C-CRX vs 2B:** the same again, with a Fujitsu MB86235 "TGPx4"
  instead of the SHARC, the UART back where 2A has it, and no billboard. Two
  games add an MPEG digital sound board. **Everything except the TGPx4 (and
  the MPEG boards) is already built.**
- **The geometrizer needs no new processor on any board.** The headers say
  "(5x TGP) or (2x SHARC) or (2x TGPx4)": one processor runs the game's own
  code, and the other(s) run the geometrizer. MAME 0.289 discards the
  geometrizer program that 2B and 2C upload (`geo_prg_w` counts the words
  and drops them) and runs the same high-level geometrizer for every board.
  This core's `m2_geometry` is that geometrizer in RTL. So 2B and 2C each
  need **one** new processor, not two. Top Skater is the known exception
  (below).

## Model 2 (original), `model2o_state`, the `main` core

Games: Daytona USA (`daytona` Rev A, `daytona93`, `daytonase`, `daytonas`,
plus the hacks `daytonam`, `daytonagtx`, `daytonat`, `daytonata`), Desert
Tank (`desert`), Virtua Cop (`vcop`, `vcopa`). The released core plays
Daytona Rev A, Deluxe '93, Desert Tank and Virtua Cop (Rev A).

| Component | What it is (chip, clocks, sizes) | Games / notes | Status |
|---|---|---|---|
| Main CPU | Intel i960KB at 25 MHz (50 MHz XTAL / 2), with on-chip FPU. Program ROM 2 MB at 0x000000 (Daytona uses 512 KB + mirror). | All. The core runs it from `clk_i960` at 40 MHz (R713). | ✅ main: `rtl/cpu/i960/` (803,355 instructions of Daytona's boot in lockstep with MAME, milestone P1; Virtua Cop's FPU forms R839, R844, R845) |
| Work RAM | 1 MB at 0x00500000 (`workram`, every board). Board RAM 128 KB at 0x00200000 plus a mirror of program ROM 0x20000-0x3ffff at 0x00220000. | | ✅ main: `rtl/io/m2_cpu_bridge.sv` (SDRAM) |
| Geometry buffer RAM | 128 KB at 0x00900000 (mirrored over 0x900000-0x97ffff). The i960 builds display lists here, and the TGP writes to it through its bank window. | | ✅ main: `m2_cpu_bridge` (R266), the TGP's buffer writes `m2_copro` (`M2_NO_COPRO_BUFW` switches them off) |
| Backup SRAM | 16 KB at 0x01d00000, battery backed. MAME's NVRAM powers it up all 0xFF. | Settings, records. | ✅ main: `rtl/io/m2_backup.sv`, saved with the OSD's "Save settings (NVRAM)" |
| Timers | Four 25 MHz down-counters at 0x00f00000, raising IRQ bits 2-5. | Not needed by the three original games (R835 measured Desert Tank's profiler harmless). | — on main (left out by design). **From 2A:** `rtl/io/m2_timers.sv` as is (~210 ALM) if a later original game needs them. |
| Interrupt controller, CPU control | IRQ request/enable at 0x00e80000. CPU control (wait states) block at 0x00e00000, which MAME treats as plain RAM. | | ✅ main: `Model2.sv` interrupt block. Wait states not modelled (MAME doesn't time them either). |
| Coprocessor | Fujitsu MB86234 "TGP" (MAME: an MB86233 with no differences) at 50 MHz. Program RAM 4 K x 32 (0x000-0xfff) uploaded by the i960. Data RAM 0x000-0x0ff and 0x200-0x3ff. 8-word FIFOs in and out. Function port 0x00880000. ROM tables for sin/cos, atan, 1/x and 1/sqrt in its I/O space. | Daytona's and Desert Tank's upload is 2,024 words (R852). | ✅ main: `rtl/tgp/` from Model 1 @ `4e7dee6` (THIRD_PARTY.md): `mb86233_*`, `m2_tgp`, `m2_copro`. 2,048-word program store; 2.3x faster since R771-R774. |
| Copro data ROM | Up to 8 MB "COPRO socket" (collision and height data), read through the TGP's bank window. | Daytona, Desert Tank. Virtua Cop has none. | ✅ main: `m2_copro` (SDRAM port 9) |
| Geometrizer | Fixed-function in the hardware (its code is in the DSPs' internal ROM, never dumped). MAME runs a high-level version written from a 2B game's code. It reads polygon (model) ROM, up to 32 MB. | | ✅ main: `rtl/video/m2_geometry.sv`, `m2_geo*.sv` (arithmetic from Model 1 @ `78481c4` / `0b5d04f`), against MAME by the geometry differential (R643) |
| 3D renderer: Z-sort, clip, raster | Front to back with a fill buffer, 60 or 30 Hz (render_mode 0x10000000), double or single buffered. Texture-parameter ROM ("textures" region) 16 MB. Texture RAM: two sheets, each a 2 MB window at 0x12000000 / 0x12400000 (mirrored), 16 bits stored per 32-bit address. Luma RAM 32 KB at 0x12800000 (one byte per dword). Raster-side texture RAM 64 K x 16 and log RAM 32 KB (filled by command). Framebuffers 2 x 512 KB at 0x11600000 (direct CPU access only in test mode). | Mip-mapping and microtexture (128 x 128) are in MAME's renderer. | ✅ main: `rtl/video/m2_raster3d.sv`, `m2_raster_*`, `m2_span_tex`, `m2_texel*`, the framebuffer in DDR3 (R640), mip-mapping (R828, R828c, R915) |
| Textured colour (luma) | The luma RAM rows and the colour translation table are the game's data. | Right for Daytona; Virtua Cop and Desert Tank are wrong (R872). | ⚠️ main: Daytona's fixed luma model (R784), R872 open (GitHub #10, "inaccurate colors"). **From 2A:** `rtl/video/m2_luma_map.sv` + `m2_span_tex` TEXLUT (R867, R900), ~9 M10K, and main is at 553/553 M10K. |
| Microtexture | 128 x 128 detail textures blended in close up. | Desert Tank draws ~25% of its 3D pixels with it in MAME (R912). | **New:** not in either core. No size in the study. |
| 2D tilemap | Sega System 24 tile chip (315-5292 family, MAME `S24TILE`): four layers, tile RAM 64 KB at 0x01000000, character RAM 512 KB at 0x01080000, horizontal/vertical sync registers at 0x01040000 / 0x01060000. | | ✅ main: `rtl/video/m2_video.sv`, `m2_tile_{fetch,decode,mixer}`, `m2_char_cache` (pixel-exact against MAME; line-buffer ring R823-R825) |
| Palette, colour, gamma | Palette RAM 16 KB at 0x01800000, colour translation 48 KB at 0x01810000 (R, G, B tables), z-clip register 0x0181c000. 8,192 MAME pens. MAME adds a gamma (bias 64, gain 255/191). | | ✅ main: `rtl/video/m2_palette.sv` and the colour tables (R222), gamma OSD with MAME's as the default (R624, R630, R790) |
| Video timing | 16 MHz pixel clock (32 MHz / 2), 656 x 424 total, 496 x 384 visible, ~57.5 Hz. MAME notes it is taken from System 24 and may not be exact. | | ✅ main: `rtl/video/m2_video_timing.sv`; 15 kHz through retrorepair's scan converter `m2_scan15` (R898) |
| Sound UART | uPD71051 (i8251) at 0x01c80000 to the sound board, 31.25 kbaud, interrupt 10. | | ✅ main: `rtl/sound/m2_i8251.sv`, `m2_sound_link.sv` |
| Sound board | The Model 1 sound board: 68000 at 10 MHz, YM3438 at 8 MHz, two Sega MultiPCM at 10 MHz, 64 KB RAM (16 KB on the PCB), 768 KB program ROM, 2 x 4 MB sample ROM. | Same board as Model 1. | ✅ main: `rtl/sound/m2_sound_board.sv` (fx68k, jt12, `m2_multipcm_dual`; R819-R821, R833) |
| I/O board, type 1 | Model 1 I/O board 837-8950-01: Z80 at 4 MHz, 315-5338A I/O chip, MSM6253 ADC, 93C45 EEPROM, 8 KB RAM, ROM EPR-14869C; MB8421 2 KB dual-port RAM at 0x01c00000 on the main board side. | Daytona and Desert Tank (steer, accel, brake; Desert Tank's third channel is the cannon, R837). | ✅ main: `rtl/io/m2_ioz80.sv` (tv80, real firmware, R60; EEPROM in MLAB R716), `m2_ioboard.sv`, `m2_cab_inputs.sv` (wheel, pedals, smoothing R830, right stick R816). GitHub #12 (wheel mapping) open. |
| I/O board, type 2 | Model 1 I/O board "advanced" 837-11130 + 837-11131: Z80, 315-5338A, an FPGA for the guns, MSM6253, 93C46, 4 KB backup RAM, diagnostic LCD. ROM EPR-17181. | Virtua Cop: two light guns. | ⚠️ main: `m2_ioz80` type 2 (R839), guns `m2_vcop_guns`, `m2_vcop_state`, crosshairs `m2_vcop_xhair` (R846, R849, R850), behind `M2_VCOP_*`. GitHub #13 open (the I/O board's flash output). CRT light guns documented, not built (R841). |
| Drive / force-feedback board | SJ25-0207-01 (838-10646 for Daytona): Z80 at 4 MHz, two 315-5296, MSM6253, 8 KB RAM, EPR-16488A. Driven from the I/O board. | Daytona only. MAME runs its Z80 but leaves its motor output unconnected, so MAME has no reference for the force feedback. | **New:** neither core has it (the I/O board's PE reads 0xFF, "absent"). Games run without it. A path to a MiSTer wheel's force feedback has not been looked at. |
| Lamps, coin counters | Output latch on the I/O board: start, view (VR1-4), leader lamps, coin counters. Desert Tank: cannon and machine-gun motors. | | — not routed anywhere (MiSTer has no lamp output). Optional. |
| Comm (link) board | 837-10537: Z80, NEC uPD72103 HDLC controller, 5 x 8 KB SRAM, EPR-16726, 16 KB shared with the i960 at 0x01a00000 plus CN/FG registers. | Daytona's link play. | **From branch `link-play`:** `rtl/io/m2_comm.sv` (the shared RAM in DDR3) + the `linux/m2link` helper, compatible with the Daytona recomp (R863, R916). Built and checked on the desk, not yet on a board, not merged. |
| Protection | None on Sega's sets. `daytonam` has a PIC simulated at 0x00240000; `daytonagtx` banks a protection ROM over 0x02c00000. | Both are fan hacks, `MACHINE_NOT_WORKING` in MAME. | **New:** two small read decoders plus MRAs (no size measured). Not planned. |
| ROM and SDRAM | Raw ROM: Daytona 45.8 MB, Desert Tank 28.6 MB, Virtua Cop 23.8 MB. | | ✅ main: 64 MB module, `m2_rom_loader` and the MRAs |

## Model 2A-CRX, `model2a_state`, the `model2a` core (beta)

Games (MAME 0.289 machine config in brackets): Virtua Fighter 2 (`model2a`:
vf2, vf2a, vf2b, vf2o), Hanguk Pro Yagu 98 (`model2a`), Sega Rally
Championship (`srallyc`: srallyc, srallycb, srallycc, srallycdx,
srallycdxa), Manx TT Superbike (`manxttdx`: manxtt Rev D, manxttdx;
`manxtt`: manxttc), Motor Raid (`manxtt`: motoraid, motoraiddx), Sky Target
(`skytargt`), Virtua Cop 2 (`vcop2`), Air Walkers (`airwlkrs`, Data East),
Dead or Alive (`model2a_0229`: doaa, doaab, doaae), Dynamite Cop / Dynamite
Deka 2 (`model2a_5881`), Pilot Kids 2A (`model2a_5881`), Zero Gunner 2A
(`zeroguna`: zeroguna, zerogunaj). The beta plays eleven: vf2, srallyc,
vcop2, zeroguna, pltkidsa, manxtt, hpyagu98, skytargt, dynamcop, motoraid,
doaab.

| Component | What it is (chip, clocks, sizes) | Games / notes | Status |
|---|---|---|---|
| Main CPU | i960KB at 25 MHz, as the original. | Sega Rally, Zero Gunner, Virtua Cop 2 and Manx TT run FPU forms the original games never did. | ✅ 2A: `rtl/cpu/i960/` with the 2A FPU forms (`i960_top` F2A, `i960_fprem`: R865, R869, R903 `cosr`) |
| Work RAM | 1 MB at 0x00500000 as the original. Board RAM 256 KB at 0x00200000-0x0023ffff, no program mirror. | | ✅ 2A: `m2_cpu_bridge` `BOARD_2A` (R852, R862) |
| Geometry buffer RAM, backup SRAM | As the original (128 KB at 0x900000, 16 KB at 0x01d00000). | | ✅ 2A: as main |
| Timers | Four 25 MHz timers at 0x00f00000. | VF2 uses timer 3 for its sound byte chain and spins on timer 2 (R852). | ✅ 2A: `rtl/io/m2_timers.sv` (~210 ALM) |
| CPU control / wait states | 0x00e00000, RAM in MAME. | Sega Rally's enemy-car placement depends on i960 timing, per MAME's TODO. | ⚠️ 2A: `rtl/io/m2_waitst.sv` built, off by default (R904; the format is inferred, Ben parked it) |
| Coprocessor | MB86234 TGP as the original. | VF2's upload is 3,802 words and needs a 4 K program store; VF2 carries subnormal floats (R852). | ⚠️ 2A: `rtl/tgp/` with `PROG_WORDS` 4096 and `SUBNORM` (R852); R888 brought Rally's TGP work from 1.54x to 0.97x MAME's time in the bench. Slowdowns in Sega Rally and Manx TT remain (release notes). |
| Copro data ROM | Up to 8 MB. | Sega Rally 4 MB, Manx TT, Sky Target, Motor Raid. | ✅ 2A: `GAME_COPRO_2A` slot, second loader remap (R862) |
| Geometrizer | As the original. | | ✅ 2A: `m2_geometry` and friends, with the 3D CRTC offsets taken from the game (R852), MAME's mip level per game (R911, R912) |
| 3D renderer | As the original. The 2A video board also carries mpr-16310..16312, which MAME doesn't use (R852). | | ✅ 2A: as main, with the texture burst region (R905), window key (R889) |
| Textured colour (luma) | As the original. | | ✅ 2A: `rtl/video/m2_luma_map.sv` + TEXLUT (R867, R900); Hanguk Pro Yagu 98's shading may differ slightly (release notes) |
| 2D tilemap | System 24 tile chip as the original. Character RAM is zeroed at boot on this board (R852). | MAME's own TODO lists a tilemap priority fault on Virtua Cop 2's stage select. | ⚠️ 2A: `m2_video` and friends; GitHub #16 (Virtua Cop 2's level-select text in the wrong layer): fixed on branch `vc2-layer` (R922, a front category-0 tile hides a back category-1 tile; also shows Zero Gunner's ranking icons), not yet on the board |
| Palette, colour, gamma, video timing | As the original. | | ✅ 2A: as main; 15 kHz converter merged (R908, 27 M10K found for it in R909). 15 kHz not yet tested on a CRT with 2A games. |
| Sound UART | uPD71051 at 0x01c80000, but now a MIDI link to the SCSP (31.25 kbaud). | | ✅ 2A: `m2_i8251` |
| Sound board | Yamaha SCSP (YMF292) at 22.58 MHz (45.1584 MHz XTAL / 2) on the video board: 32 slots, effects DSP, timers. 68000 at 11.29 MHz. 512 KB sound RAM (shared by the 68000 and the SCSP), 512 KB program ROM at 0x600000, 8 MB samples at 0x800000 (banking only above 8 MB, which no 2A set has). | VF2, Rally, ZG and the rest. Sound is quiet in some games; the core matches MAME's mix (release notes). | ⚠️ 2A: `rtl/sound/m2_2a_sound.sv` (fx68k, RAM in SDRAM, R859) + `rtl/sound/scsp/` (our own SCSP from MAME's BSD-3 code, R856-R858; levels R874-R886, R894). Open: Dead or Alive's low bass rumble (R914 reserved, branch `doa-rumble`). |
| Second sound board (Manx TT) | A Model 1 sound board on the same MIDI line. | MAME's `manxttdx` config, which also holds `manxtt` Rev D, the set the beta plays. | **From main:** `rtl/sound/m2_sound_board.sv` as is, about 4,650 ALM (s999) and ~17 M10K, which the 2A core doesn't have (521 ALM and 6 M10K free on s1278). Release notes: "a few extra sounds are missing". |
| I/O controller | Sega 315-5649 on the main board at 0x01c00000-0x01c0001f (umask 0x00ff00ff): ports A-G, eight analog channels, two serial channels. No Z80, no dual-port RAM. | Port A: EEPROM. B, C, D: inputs. E: billboard (Rally: drive board). F: lamps. G: switches. | ✅ 2A: `rtl/io/m2_315_5649.sv` (2 M random operations against MAME's device, R852), inputs `rtl/io/m2_2a_inputs.sv` (R862, R879) |
| Analog controls | On the 315-5649's ADC. | Sega Rally (steer, accel, brake, shifter, hand brake), Manx TT and Motor Raid (throttle, brake, bank), Sky Target (stick X/Y). | ✅ 2A: `m2_2a_inputs` with main's `m2_cab_inputs` for Rally (`M2_2A_RALLY`, R862) |
| Light guns | Interface board 837-12079 (Altera FLEX + 315-5338A), read through the 315-5649's serial channel 2 (a mux register). | Virtua Cop 2. | ✅ 2A: main's `m2_vcop_guns` / `m2_vcop_state` (V2) and `m2_vcop_xhair`, on serial channel 2 (`M2_2A_VCOP2_GUN`, R870); ammo display R889 |
| Four-player inputs | Port F bit 7 selects which pair of players ports C and D read. | Air Walkers only. | **New:** an MRA, a layout and a two-way mux in `m2_2a_inputs` (small). 26.5 MB, fits 64 MB. MAME: not working, imperfect sound. Not started. |
| EEPROM | 93C46, 64 x 16, on port A. | Settings. Hanguk Pro Yagu 98 needs its factory image (R897). | ⚠️ 2A: `rtl/io/m2_93c46.sv`, loaded from the MRA (`M2_2A_EE_LOAD`, R897), **never saved back**: the module's header says persistence "is not here yet", and the OSD save writes only the backup SRAM. GitHub #15 (Sega Rally doesn't save its settings) is open; that this is its cause is inferred here, not checked. **New:** an EEPROM save path (the 128 bytes beside the backup SRAM's 16 KB). |
| Protection, 315-5881 | Sega's decryption chip, 0x01d80000 RAM buffer + 0x01d90000 registers. | Zero Gunner 2A, Dynamite Cop, Pilot Kids 2A. On all three it's only a check (R873, R887). | ⚠️ 2A: not emulated; one-byte MRA patches skip the checks (R873, R887). Zero Gunner's enemy patterns differ from MAME's (release notes). **New** if wanted: the chip, ~300-400 ALM and 1 M10K (R862), MAME's BSD-3 `315-5881_crypt.cpp` as the reference. |
| Protection, 315-5838 / 317-0229 | Compression and encryption chip. | Dead or Alive 2A: decrypts one string checked at boot (MAME's device notes). | ⚠️ 2A: not emulated; patched by the MRA (R887) |
| Drive / force-feedback board | SJ25-0207-01 (838-11661 for Rally, EPR-17891), on the 315-5649's port E. | Sega Rally. | **New:** as the original (not in either core, no MAME output to check against). |
| Motion base | Manx TT DX's "Active Motion Slider" drive board on ports E/D. | Manx TT (DX mode boots without it via R892's answer). `motoraiddx` has its own check with a different protocol. | ✅ 2A for `manxtt`: `m2_2a_inputs` MOTION (`M2_2A_MANX_MOTION`, R892). **New** for `motoraiddx` (protocol not analysed, 68.6 MB, R892). |
| Lamp billboard | Sega Versus City billboard 837-11854: Z80 at 8 MHz, 315-5338A, 8 KB RAM, EPR-18022, four 7-segment digits and LEDs, fed from port E. | Display only. | **From main:** tv80 and `m2_ioz80`'s 315-5338A as a pattern, if anyone wants it shown on the OSD. Not needed to play. |
| Comm (link) board | 837-11525 "MODEL2 A-CRX COMMUNICATION": the same parts and EPR-16726 as Daytona's 837-10537. | Sega Rally (twin cabinets). | **From branch `link-play`:** `m2_comm` + `m2link` (R916), with Rally's frame size and offset checked first. Release notes: "No link play for Sega Rally yet". |
| ROM and SDRAM | Raw ROM 26.5 MB (Air Walkers) to 90.5 MB (Dynamite Cop). | Six of the eleven need more than 64 MB (R887). | ✅ 2A: the 128 MB module (R891, R897), large layout. |
| Board-level faults | | GitHub #17 (VF2 crashes at random), #18 (DOA crashes going into the first match). Cause unknown. | ⚠️ 2A: open, not looked at yet |

## Model 2B-CRX, `model2b_state`: documented only (Ben, R832)

Games (machine config in brackets; MAME 0.289's flag after the name, NW =
not working): Virtua Striker (`model2b`, works), Fighting Vipers (NW),
Cyber Troopers Virtual-On (NW), Sonic Championship / Sonic the Fighters
(NW), Last Bronx (NW) (all `model2b`); Gunblade NY (`gunblade`, works);
Rail Chase 2 (`rchase2`, works, imperfect sound); INDY 500 (`indy500`, NW),
Super GT 24h (`indy500`, NW), Over Rev Model 2B (`indy500`, NW); Power Sled
(`powsled`, NW); Dynamite Baseball and '97 (`dynabb`, NW); Dead or Alive 2B
(`model2b_0229`, works); Zero Gunner 2B (`zerogun` = `model2b_5881`,
works); Pilot Kids 2B (`model2b_5881`, works); Dynamite Cop / Deka 2 Model
2B (`model2b_5881`, NW). DOA, Zero Gunner, Pilot Kids and Dynamite Cop
already play from their 2A sets.

| Component | What it is (chip, clocks, sizes) | Games / notes | Status |
|---|---|---|---|
| Main CPU | i960KB at 25 MHz. | The FPU forms 2B games run have not been logged (R869's method needs the ROMs, which aren't on this machine). | ✅ 2A: `rtl/cpu/i960/` as is. Risk: forms 2A never ran would trap until added. |
| Work RAM, board RAM, buffer RAM, backup SRAM | As 2A (256 KB board RAM at 0x200000). | | ✅ 2A: `m2_cpu_bridge` `BOARD_2A`, `m2_backup` |
| Timers, interrupts | As 2A. | | ✅ 2A: `m2_timers`, `Model2.sv` |
| Coprocessor | **Analog Devices ADSP-21062 SHARC at 32 MHz** (32-bit IEEE float plus 40-bit extended, 48-bit instructions, one per cycle with up to two data accesses). 2 Mbit (256 KB) of dual-ported on-chip SRAM. Booted by the host: the i960 uploads the game's program in 16-bit words through the SHARC's external DMA port (`copro_fifo_w` while `copro_ctl1` bit 31 is set); IOP registers at 0x008c0000 (Last Bronx uploads through DMA port 0). Its own map: input FIFO 0x0400000, output FIFO 0x0c00000, the geometry buffer RAM 0x1400000, the copro data ROM 0x1c00000. FIFOs 16 deep, their empty/full as the SHARC's FLAG0/FLAG1. Copro status at 0x00980014 (Sonic the Fighters), bank register 0x00980020. | Every 2B game. MAME's header says "2x SHARC"; MAME instantiates one (the second, the geometrizer, is commented out). | **New:** a SHARC core. Sizing below. **Changed (from 2A's `m2_copro`):** the i960-side interface carries over (control register, function port 0x00880000, FIFOs, buffer-RAM write port, copro-data ROM port), with the upload path changed to 16-bit DMA words, the FIFOs 16 deep, and the flags wired to the SHARC. |
| Copro data ROM | 8 MB region. | | ✅ 2A: SDRAM port 9 slot as is (address decode changes with the SHARC's map) |
| Geometrizer | The second SHARC on the board, running uploaded code. MAME 0.289 discards the upload (`geo_prg_w`) and runs its high-level geometrizer, which was written from a 2B game's disassembly. | | ✅ 2A: `m2_geometry` as is, to the same degree as MAME. The upload at 0x00804000 has to be accepted and dropped (a few ALM). |
| 3D renderer | As 2A, but the texture RAM is plain 32-bit RAM at 0x11000000 (sheet 0) and 0x11200000 (sheet 1), mapped as 1 MB mirrored twice in MAME, instead of 2A's 16-bits-per-dword windows at 0x12000000 / 0x12400000. Luma RAM 32 KB at 0x11400000, one byte per 16-bit word (umask16 0x00ff). | | **Changed:** `m2_cpu_bridge`'s texture and luma decode (new addresses, full 32-bit stores into the sheets). The renderer behind it is ✅ 2A as is. |
| Framebuffer access | Framebuffers at 0x11600000 / 0x11680000 (xGGGGGRRRRRBBBBB, 512 x 400), drawn directly by the CPU in the renderer's test mode. | Last Bronx's title screen. | **New:** a CPU window onto the DDR3 framebuffer (the core keeps it in DDR3, R640). The test-mode bit is already stored for read-back (R896). |
| 2D tilemap, palette, colour, video timing | As 2A. | | ✅ 2A: `m2_video` and friends, `m2_palette`, `m2_video_timing`, `m2_scan15` |
| Sound UART | uPD71051, moved to 0x009c0000 (one byte per dword). | | **Changed:** `m2_i8251` as is, decoded at the new address |
| Sound board | SCSP + 68000 as 2A. | Virtua Striker's samples are 6 MB. | ✅ 2A: `m2_2a_sound` + `rtl/sound/scsp/` as is |
| I/O controller, EEPROM | 315-5649 and 93C46 as 2A. | | ✅ 2A: `m2_315_5649`, `m2_93c46` (with 2A's EEPROM-save gap, #15) |
| Analog controls | INDY 500, Super GT 24h, Over Rev: wheel and pedals. Power Sled: two players' left/right on channels 1, 3, 5, 7, plus IN3 on port E and a motion ADC. Dynamite Baseball: two bats. Gunblade NY: two guns as analog X/Y. Rail Chase 2: two guns as analog X/Y. | | **Changed:** `m2_2a_inputs` profiles per game. The wheel is main's `m2_cab_inputs` as Rally uses it; the gun aim can come from `m2_vcop_guns`' stick and mouse code, fed to the ADC channels instead of the serial mux. Small. |
| Protection | 315-5838 / 317-0229 (DOA 2B), 315-5881 (Zero Gunner, Pilot Kids, Dynamite Cop 2B). | | ⚠️ 2A approach as is: MRA patches, to be redone per set (the patch addresses differ between 2A and 2B programs). |
| Drive and motion boards | INDY 500, Super GT 24h, Over Rev: a drive board on port E. Rail Chase 2: "Drive I/O BD" 837-11694, a Z80 at 4 MHz with a CXD1095 and EPR-17895, driving the seat's air cylinders; MAME only answers its status checks. Power Sled: motion ADC. | | **New** if wanted; MAME's level (answer the checks) is a few ALM in `m2_2a_inputs`, as R892 did for Manx TT. |
| Lamp billboard | As 2A. | | As 2A (not needed). |
| Comm (link) board | As 2A. Power Sled reaches it at 0x01a1xxxx and uses frame offset 0x180. | Power Sled is sold as Slave / Relay / Main sets. | **From branch `link-play`:** `m2_comm` + `m2link`, with Power Sled's offsets. |
| ROM and SDRAM | Raw ROM 27.6 MB (Virtua Striker) to 90.5 MB (Dynamite Cop 2B). DOA 2B 69.5, Dynamite Baseball '97 66.5, Pilot Kids 65.5, Sonic 62.5 MB. | | ✅ 2A: the 128 MB module and the large layout cover them; each set needs its own layout check (`tools/mra_vs_mame.py`). |

## Model 2C-CRX, `model2c_state`: documented only (Ben, R832)

Games (all `MACHINE_NOT_WORKING` in MAME 0.289): Sega Ski Super G
(`skisuprg`, also unemulated protection), Sega Touring Car Championship
(`stcc`: stcc, stcca, stccb, stcco), Wave Runner (`waverunr`), Behind
Enemy Lines (`bel`), The House of the Dead (`hotd`: hotd, hotdo, hotdp),
Over Rev (`overrev2c`), Royal Ascot II (`model2c`), Sega Water Ski
(`segawski`), Top Skater (`topskatr`: four sets), Dynamite Cop USA Model 2C
(`model2c_5881`).

| Component | What it is (chip, clocks, sizes) | Games / notes | Status |
|---|---|---|---|
| Main CPU, RAMs, timers, interrupts | As 2A (256 KB board RAM at 0x200000). | 2C's i960 forms not logged (no ROMs here). | ✅ 2A: as is (same risk as 2B) |
| Coprocessor | **Fujitsu MB86235 "TGPx4" at 20 MHz.** 64-bit instructions: an ALU operation, a multiply and up to two transfers in one instruction, with delay slots. Program RAM 4 K x 64 (32 KB), uploaded by the i960 as pairs of 32-bit words. Internal data RAMs A and B, 1 K x 32 each. Registers: AA0-7, AB0-7, MA0-7, MB0-7, AR0-7, a 24-entry PR queue, a 4-deep PC stack, repeat and loop counters. ALU ops include FRCP, FRSQ and FLOG. External data: the geometry buffer RAM at 0x400000, the copro data ROM ("TGPx4 program", 8 MB) at 0x800000. FIFOs 8 deep. | Every 2C game. MAME's header says "2x TGPx4"; MAME instantiates one. | **New:** an MB86235 core. Sizing below. **Changed (from 2A's `m2_copro`):** the i960 side carries over with the upload packing two words per instruction and no TGP tables. |
| Copro data ROM | 8 MB region. | | ✅ 2A: SDRAM port 9 slot as is |
| Geometrizer | As 2B (a second TGPx4; MAME discards the upload and runs the high-level geometrizer). | **Top Skater** uses different geometry code with a second transformation matrix, which MAME's high-level geometrizer doesn't have (model2_v.cpp notes). | ✅ 2A: `m2_geometry` as is, except **New** for Top Skater: the second matrix (size unknown; MAME has no reference for it either). |
| 3D renderer | As 2B: texture RAM at 0x11000000 / 0x11200000 as plain RAM (2 MB windows), luma RAM at 0x11400000. | | **Changed:** the same bridge decode as 2B; the renderer ✅ 2A as is. |
| 2D tilemap, palette, colour, video timing | As 2A. | | ✅ 2A: as is |
| Sound UART | Back at 0x01c80000, as 2A. | | ✅ 2A: `m2_i8251` as is |
| Sound board | SCSP + 68000 as 2A. | | ✅ 2A: `m2_2a_sound` + SCSP as is |
| Digital Sound Board (DSB) | Sega's Z80 DSB: Z80 at 4 MHz, 32 KB RAM, 128 KB program, 8 MB of MPEG-1 Layer II audio, fed from the same MIDI line. | Sega Touring Car Championship (music). | **New:** tv80 from main is the CPU; an MPEG-1 Layer II decoder has no RTL in this project and would be the large part. |
| Digital Sound Board 2 | Sega's DSB2: 68000 at 8 MHz with 16 MB of MPEG-1 Layer II audio. | Top Skater. | **New:** fx68k from 2A is the CPU; the same MPEG decoder. |
| I/O controller, EEPROM | 315-5649 and 93C46 as 2A. | | ✅ 2A: as is |
| Analog controls | Ski Super G: swing and incline. STCC and Over Rev: wheel and pedals. Wave Runner: handle, roll, throttle, pitch. Behind Enemy Lines: two guns as analog X/Y. Water Ski: slide. Top Skater: curving and slide. | | **Changed:** `m2_2a_inputs` profiles; the wheel from `m2_cab_inputs`; the gun aim as for 2B. Small. |
| Light guns | Serial channel 2 mux, as Virtua Cop 2. | The House of the Dead. | ✅ 2A: R870's guns as is (`M2_2A_VCOP2_GUN`) |
| Protection | 315-5881 (Dynamite Cop 2C). Ski Super G: unemulated protection in MAME. | | ⚠️ 2A approach (MRA patches) for Dynamite Cop; Ski Super G's is unknown. |
| Drive board | STCC's set carries a drive-board ROM; MAME's `stcc` config doesn't add the board. | | **New** if wanted (as the original). |
| Lamp billboard | Not on 2C (MAME's `model2c` has none). | | — |
| Comm (link) board | As 2A. | STCC has a link ROM. | **From branch `link-play`:** `m2_comm` + `m2link`. |
| ROM and SDRAM | Raw ROM 33.6 MB (Over Rev) to 90.5 MB (Water Ski, Dynamite Cop 2C). House of the Dead 84.5, Royal Ascot II 66.6 MB. | | ✅ 2A: the 128 MB module and large layout, set by set. |

## Sizing the two new processors

### What exists to start from

- **No open-source FPGA SHARC or MB86235 core was found** (a web search on
  2026-10-21 for ADSP-21062 and MB86235/TGPx4 HDL found nothing). That is
  absence of evidence, as section 5.4.1 says of its own finding.
- **Model 1's reference (`tools/model1-ref` @ `0b5d04f`) has neither.** Its
  TGP is the MB86233 this core already uses.
- **The MB86233/MB86234 we have, and how much of it an MB86235 could use.**
  Section 5.4.1 closed M2-C because the MB86234 *is* the MB86233 in MAME. It
  says nothing about the MB86235, and the MB86235 is a different machine:
  a 64-bit VLIW word (ALU, multiplier and transfers issued together),
  different addressing modes, register files and sequencer. What carries
  over: the float add and multiply units with their subnormal handling
  (`rtl/tgp/fp_add.sv`, `fp_mul.sv`), the divider (`fp_div.sv`), the FIFO
  (`m2_fifo_m10k.sv`), the i960-side board interface (`m2_copro.sv`), the
  reciprocal and inverse-square-root units from the geometry
  (`m2_geo_rsqrt.sv`, `m2_recip_rom.sv`) for FRCP / FRSQ, and the TGP's
  replay and lockstep harness pattern (`tgp_replay`). (R920's skeleton
  takes FRCP / FRSQ through `fp_div` and a new square root instead, which
  give MAME's bits; the geometry's approximations would not.) The decoder, the
  sequencer (delay slots, PC stack, repeat), the address units and the
  register files are new. For the SHARC only the float units and the board
  interface carry over.
- **Oracles.** Both exist in MAME 0.289 under BSD-3: `cpu/sharc/` (Ville
  Linde) and `cpu/mb86235/` (Angelo Salese, ElSemi, Matthew Daniels).
  MAME's SHARC is mature (it also serves Konami's Hornet and NWK-TR boards),
  and an interpreter path exists for lockstep. MAME's MB86235 is weaker: its
  TODO says illegal delay slots are unsupported and the FIFO hookups are
  inside the opcodes, FRCP / FRSQ / FLOG use host maths (`1.0F / sqrtf(f)`),
  and every 2C game is `MACHINE_NOT_WORKING` in 0.289 (why was not checked).
  So a bit-exact oracle exists for the SHARC's arithmetic as MAME models it,
  and only an approximate one for the TGPx4.

### The numbers

**The MB86235 (2C) was re-sized in R920 by a measured skeleton. The SHARC
(2B) was not re-sized: its row below is still R919's scaled estimate.**

#### The budget: what a 2C core gets by giving up the TGP

The 2A core (s1278, the 2A beta's fit): 41,389 / 41,910 ALM (521 free),
547 / 553 M10K (6 free), 96 / 112 DSP (16 free). A 2C core keeps the i960
side of the coprocessor board (`m2_copro`: its 36 ALM, the two FIFOs at
1 M10K each) and replaces the processor behind it. On s1278 that processor,
`m2_tgp` (the MB86233 core plus its board logic and R888's posted-write
queue), is **2,802 ALM, 19 M10K (16 program, 3 data RAM), 1 DSP**. (R919's
2,867 ALM and 24 M10K were `m2_copro` as a whole on s1248, before R909 took
the TGP's shift-register RAMs out.)

| | ALM | M10K | DSP |
|---|---|---|---|
| Freed by the TGP | 2,802 | 19 | 1 |
| Free on s1278 | 521 | 6 | 16 |
| **Budget for the TGPx4 and its board logic** | **2,802 at today's fill; 3,323 with the device full** | **25** | **17** |
| More if needed: the copro FIFOs (8 deep) to MLAB | ~ -20 | +2 | |
| More if needed: R909's reserve (char cache at `max_depth` 2048, `span_q` to MLAB) | | +19 | |

The like-for-like figure (2,802) is the one to design to: s1278 is 99% full
and closed timing with a seed sweep, so a replacement no larger than the TGP
leaves the fill unchanged. Nothing else large on the 2A core is unused by
2C. The light-gun logic (`m2_vcop_guns` / `_state` / `_xhair`, 233 ALM) is
needed by The House of the Dead, but as a per-game parameter it can be off
in a build for the other games. 2C has no billboard, and the 2A core has
none either.

#### The design: one instruction at a time, its parts in sequence

The chip issues a 64-bit word per 20 MHz clock: an ALU op, a multiply and
up to two transfers. `clk_sys` is 80 MHz, and the 2A games' TGP used at most
~30% of its frame on MAME's model of the part (R888: Sega Rally max 5.05 of
17.39 ms; R896: Manx TT max 5.11 ms). So nothing is duplicated for speed.
`rtl/tgpx4/tgpx4_core.sv` runs each word's parts one after another, in
MAME's order (transfer sources, ALU and multiplier operands, ALU, multiplier,
transfer destinations), through one of each unit:

- **One FP adder and one FP multiplier**: the 2A TGP's own `fp_add` / `fp_mul`
  (`rtl/tgp`, with R852's SUBNORM, which matches MAME's host floats). The
  MB86235 is IEEE single precision in MAME (`u2f` / `f2u`), with no extended
  format, so they fit as they are. FRCP is `fp_div`'s 1 / x. FRSQ is MAME's
  `1.0F / sqrtf(f)`: a new single-precision square root (`tgpx4_fsqrt`,
  one bit a clock) followed by the same divide. Two correctly rounded
  operations, so for normal inputs the result is MAME's bits.
- **One shifter** (`tgpx4_cvt`, 33 bits) for CIF / CFI / CFIB and the four
  integer shifts; a left shift is the bit-reversed right shift. One adder
  for integer ADD / SUB / CMP. A 32 x 32 integer multiply in two DSPs.
- **Register files in MLAB**: AA / AB / MA / MB as one 32 x 32 array with four
  read copies (one per ALU / multiplier operand) and one write port; the
  24-deep PR queue in one more. AR0-7 and the special registers are in
  flip-flops, read through one shared AGU (`tgpx4_agu`, MAME's 15 modes),
  one special-register multiplexer and three AR ports.
- **Data RAMs A and B**, 1 K x 32 each, in M10K, one read and one write port
  each. The write ports are driven in the clock that decides them, so the
  next word reads what the last one wrote.
- **Program memory** (`tgpx4_pmem`), in one of three sizes: all 4 K x 64 on
  chip, or a direct-mapped cache of 1 K or 2 K lines over a copy of the
  program in SDRAM. The upload writes both the line and the copy, so the
  cache never needs a flush. Tag and valid bit ride in the spare bits of the
  line.
- **Prefetch**: the next word is fetched in S_DEC. Its address is always known
  there, because a branch takes effect one word later, after its delay slot.

**Measured, quartus_map 17.0 on the skeleton alone** (`make tgpx4_map
TGPX4_PLINES=<n>`, the spike template, 5CSEBA6; map only, no fit):

| Program memory | ALM (map estimate) | registers | block bits | M10K (Cyclone V shapes) | DSP |
|---|---|---|---|---|---|
| 1 K-line cache | 3,062 | 1,899 | 134,144 | 15 (A 4, B 4, cache 1 K x 67 = 7) | 3 |
| 2 K-line cache | 3,063 | 1,899 | 200,704 | 22 (cache 2 K x 66 = 14) | 3 |
| all on chip | 3,004 | 1,871 | 327,680 | 40 (program 4 K x 64 = 32) | 3 |

By entity (1 K cache, map ALUTs): `fp_add` 599, `fp_mul` 689, `fp_div` 148,
`tgpx4_fsqrt` 190, `tgpx4_cvt` 586, `tgpx4_agu` 133, the cache control 98,
and the core's own sequencer, decode, transfer engine and registers 1,706
(1,056 registers). MLAB: 160 memory ALUTs (five 32 x 32 arrays).

**From map estimate to fitted ALM.** The 2A's `m2_tgp`, mapped the same way
with its 2A parameters, reads 3,598 ALM against 2,802 fitted on s1278: a
factor of 0.78. Applied here, the skeleton is **~2,390 ALM fitted** (1 K
cache), ±10% for the factor's uncertainty.

**M10K counts are by shape, not fitted.** 1 K x 32 fits 4 blocks at 1 K x 10
and 4 K x 64 fits 32 at 4 K x 2. The fitter has taken worse shapes before
(R909: 8192 x 1 slices), and `max_depth` pins the shape if it does.

**What the skeleton covers.** It covers every instruction type (0, 1, 4, 5,
7 and the control types 2 / 6), MAME's field decode for each, every ALU op
except FLOG, both multiplies, the PR queue with its step modes, all 15 AGU
modes, every transfer code (registers, special registers, AR, PR, FIFO in /
out, PDR / DDR, PRP / PWP), external transfers with EB / EO and the A-bus
window over 0x400, REP / SETL / DBLP, the conditional / relative /
register / memory branch targets with their delay slot, the 4-deep PC
stack, PUSH / POP, CLRF and the SETM forms, and MAME's FIFO stall (a word
waits before doing anything if it reads an empty FI or writes a full FO).

**How it was checked.** The skeleton lints clean (Verilator 5.052,
`make lint_tgpx4`, the unused-signal class waived). The new arithmetic is
fuzzed against host floats: `tgpx4_fsqrt` 0 / 59,532 wrong against
`sqrtf`, and `tgpx4_cvt` 0 / 239,939 against `(float)int`, `int(f)`, the
CFIB rule and the shifts. A planted fault (dropping the sticky bit) is
caught 18,399 times. A second planted fault (rounding ties to nearest even)
is not caught, and cannot be: a square root never falls exactly on a
rounding tie. A hand-assembled program runs end to end in both
program-memory forms, with every output right (FADD, FRSQ through
sqrt + divide, a RAM A round trip with post-increment, FMUL, CIF, REP of an
integer add, PR queue write / step / read). **It has not been run against
MAME on a real 2C program.** No 2C ROM is on this machine.

**Throughput, measured** (Verilator, REP loops of one form, `clk_sys`
80 MHz). On MAME's model, the chip does 20 M words a second:

| Form | clocks per word | M words / s |
|---|---|---|
| transfer only | 3 | 26.7 |
| integer op + register transfer | 5 | 16.0 |
| FADD + register transfer | 7 | 11.4 |
| FADD + FMUL + one or two transfers (the geometry word) | 8 | 10.0 |
| FRCP / FRSQ + register transfer (iterative divide; square root then divide) | 32 / 59 | 2.5 / 1.4 |

An external access (data ROM, buffer RAM) or a cache miss adds an SDRAM
round trip: ~19 clocks idle, 25-40 typical (R888). On the FP-heavy word the
skeleton runs at half the chip's rate. That covers a 2C game that uses its
TGPx4 the way the 2A games use their TGP (at most ~30% of a frame on MAME's
model) by about 1.7x. Whether 2C games do is what the census's BUSY line
measures.

#### What the rest adds (bounded)

| Item | Bound | Source of the bound |
|---|---|---|
| The board logic: SDRAM port 9 for the data ROM and the program copy's refill, buffer-RAM writes in 16-bit halves through R888's posted queue, the program copy's writes | ≤ 378 ALM | `m2_tgp`'s own logic (324) + its queue (54) on s1278, which does the same jobs plus the MB86233's table port |
| `m2_copro`: pack the i960's word pairs into 64-bit program words | ~20-40 ALM | one 32-bit holding register and a counter bit |
| FLOG, only if the census finds it | ~100-200 ALM, 0-1 M10K | a sequence on the shared fp_mul / fp_add with a mantissa table |
| Overlap, only if the census's BUSY line says 8 clocks a word is too slow: the next word's operand reads under this word's FP latency | ~100-250 ALM | a second operand set and a check of 2 destinations against 4-6 sources; 8 clocks a word goes to ~5 |

#### The result

| Chip | Microarchitecture | Skeleton, measured (map) | Expected total, fitted | Budget after removing the TGP | Fits? |
|---|---|---|---|---|---|
| MB86235 TGPx4 (2C), 1 K-line program cache | One word at a time on shared units; MLAB register files; one AGU, one shifter, one adder; prefetch | 3,062 ALM, 15 M10K, 3 DSP | **~2,800 ALM** (2,390 + ≤378 + ~30), **15 M10K**, 3 DSP; ~2,900-3,250 with FLOG and overlap | 2,802 ALM at today's fill (3,323 full), 25 M10K, 17 DSP | **Yes.** About equal to the TGP in ALM, so the fill stays at s1278's 99%. 10 M10K spare. FLOG plus overlap would go over the like-for-like figure by up to ~450 ALM, still inside the device. |
| same, 2 K-line cache | as above | 3,063 ALM, 22 M10K | ~2,800 ALM, 22 M10K | as above | Yes, 3 M10K spare |
| same, whole program on chip | as above, no cache | 3,004 ALM, 40 M10K | ~2,750 ALM, 40 M10K | as above | ALM yes. M10K only with R909's 19-block reserve (4 spare) |
| ADSP-21062 SHARC (2B) | **not re-sized in R920** | — | R919's scaled estimate: ~6,000-12,000 ALM, its 2 Mbit RAM off chip | 2,802 / 3,323 ALM | No, on R919's estimate |

R919 believed the MB86235 would take ~4,000-5,500 ALM and ~34-40 M10K, and
leave a 2C core ~600-2,100 ALM over. Measured, it takes about what the TGP
it replaces takes, and 15 M10K with a 1 K-line cache. **Ben's decision
(R832) is unchanged by this. 2C remains documented only, and nothing here is
wired into `Model2.sv`.** But the size of the processor is no longer the
reason.

#### Open risks

- **No 2C program has been run.** The skeleton follows MAME's interpreter,
  and every 2C set is `MACHINE_NOT_WORKING` in MAME 0.289, so the oracle may
  itself be wrong for these games. Model 1 has no MB86235 to check it
  against.
- **Throughput.** The skeleton runs at half the chip's rate on the geometry
  word. Nothing has measured a 2C game's load: the census's BUSY line will.
  The overlap lever is bounded above.
- **The program cache.** A 1 K-line cache over a program of up to 4 K words
  (VF2 uploads 3,802 words to its TGP, R852) misses when the working set
  spills. Each miss costs an SDRAM round trip. The census models 1 K and 2 K
  direct-mapped caches on the real fetch stream (PCACHE line). If they
  thrash, the 2 K cache (22 M10K) or the whole program on chip (40, with
  R909's reserve) are the fall-backs, and they are measured above.
- **FP edges.** `fp_div` flushes subnormal results, so FRCP of |x| > 2^126
  differs from MAME's host float. FRSQ of a subnormal or negative input
  follows x86, unchecked. **FLOG**: MAME computes `log(f) / 0.301030F`,
  which is ln x / log10 2, not log2 x. Either MAME or the chip is odd; the
  census says whether any game runs it. **FEA / FES**: MAME keeps only the
  exponent field and drops the mantissa (`src1 &= 0x7f800000`). The skeleton
  copies it, and the census says whether it matters.
- **MAME has no pipeline model for this chip.** A result is visible to the
  next word. The real part may have data hazards that its programs avoid or
  rely on. The skeleton follows MAME.
- **The 2C i960 forms** (R869's method) and **Top Skater's second geometry
  matrix** are unchanged open items.

#### The census (ready, needs the ROMs)

`sim/tgp/mame_mb86235_census.patch` (applied and built in the scratch MAME
0.289 tree `sm2-builds/mame-r869`, binary `m2lod`) logs, per game:

- every distinct instruction form with its first PC and count;
- the ALU / multiply ops, second-source kinds and PR modes, AGU modes,
  transfer codes, external and A-bus-over-0x400 transfers, and control ops
  and conditions;
- the uploaded program size;
- a direct-mapped 1 K / 2 K program cache's misses on the real fetch stream;
- the busy fraction per 1/57.5 s on MAME's model.

`sim/tgp/mame_m2c_census.sh` runs it set by set with
`sim/io/mame_m2_2a_play.lua`. The play mode per set is a first guess:
rally for STCC and Over Rev, vcop2 for House of the Dead, and coin / start /
buttons only for the rest. The census code was checked in a harness on
known words, and the script on a 2A set (no census, correctly) and on a
missing 2C set (fails cleanly).

**The ROM sets it needs** (MAME 0.289 names, all `model2c_state`):

- **Parents:** `stcc`, `hotd`, `bel`, `waverunr`, `skisuprg`, `segawski`,
  `topskatr`, `overrev`, `rascot2`.
- **`dynamcopc`**, whose parent `dynamcop` is already here.
- **Clones:** `stccb`, `stcca`, `stcco`, `hotdo`, `hotdp`, `topskatru`,
  `topskatruo`, `topskatrj`.

The parents are the minimum, plus the BIOS / device zips MAME asks for.

## Remaining work

### For 2B (if the decision is ever reopened), in order

1. **Get the ROMs and measure.** Log the SHARC upload size and the i960's FPU
   forms (R869's method) for each 2B set, and why MAME flags most 2B games
   not working. No RTL. This decides item 3's memory plan.
2. **The bridge and board changes:** texture and luma RAM at 0x11000000 /
   0x11400000 as plain RAM, the UART at 0x009c0000, copro status 0x00980014,
   the geometrizer upload accepted and dropped, the 16-deep FIFOs and the
   DMA upload in `m2_copro`. Small (tens to low hundreds of ALM).
3. **The SHARC**, against MAME's interpreter in lockstep: ~6,000-12,000 ALM,
   its 2 Mbit RAM in SDRAM/DDR3 behind caches, pipelined to 2.5 clocks per
   instruction. The large item, and it doesn't fit beside the rest today.
4. **Inputs and per-game boards:** wheel (INDY 500, Super GT 24h, Over Rev),
   analog guns (Gunblade NY, Rail Chase 2), bats (Dynamite Baseball), Power
   Sled's controls and link offsets, Rail Chase 2's drive I/O checks.
   Small each.
5. **The framebuffer window** for Last Bronx's title screen. Small to medium.
6. **MRAs, layouts and protection patches** set by set.

Games that would come with it: Virtua Striker, Fighting Vipers,
Virtual-On, Sonic Championship, Last Bronx, Gunblade NY, Rail Chase 2,
INDY 500, Super GT 24h, Over Rev (2B), Power Sled, Dynamite Baseball and
'97, plus the 2B sets of Dead or Alive, Zero Gunner, Pilot Kids and
Dynamite Cop (already playable from their 2A sets).

### For 2C (if the decision is ever reopened), in order

1. **Get the ROMs and measure**, as for 2B, including whether the high-level
   geometrizer is enough for each game (Top Skater is known not to be).
2. **The bridge and board changes:** as 2B's item 2, without the UART move
   and with the 64-bit upload packing. Small.
3. **The MB86235**, from R920's skeleton (`rtl/tgpx4`, branch `model2c`),
   against MAME's interpreter (a weaker oracle): ~2,800 ALM fitted with its
   board logic and 15 M10K with a 1 K-line program cache, within the TGP's
   own 2,802 ALM / 19 M10K. Run the census first (`sim/tgp/mame_m2c_census.sh`)
   to fix the forms, the cache size, FLOG and the throughput lever.
4. **Inputs:** House of the Dead's guns as is (R870); wheels; Ski Super G,
   Wave Runner, Water Ski and Top Skater profiles; Behind Enemy Lines'
   analog guns. Small each.
5. **Top Skater's second geometry matrix.** Unknown size, no reference.
6. **The MPEG sound boards** (STCC's DSB, Top Skater's DSB2): an MPEG-1
   Layer II decoder in RTL. Large; the games run without their music.
7. **MRAs, layouts, protection patches.** Ski Super G's protection is
   unknown.

Games that would come with it: The House of the Dead, Sega Touring Car
Championship, Sega Ski Super G, Wave Runner, Behind Enemy Lines, Over Rev
(2C), Royal Ascot II, Sega Water Ski, Top Skater, and Dynamite Cop's 2C set.

### Still open on the original Model 2 core (`main`)

- **Textured colour for Virtua Cop and Desert Tank** (R872, GitHub #10):
  port 2A's `m2_luma_map` + TEXLUT, ~9 M10K, and main is at 553/553.
- **Virtua Cop's I/O board flash** (GitHub #13), and CRT light guns (R841,
  documented only).
- **Desert Tank's microtexture** (R912: ~25% of its 3D pixels): new
  renderer work, unsized.
- **Link play** for Daytona: built on branch `link-play` (R916), to be
  tested on a board and merged.
- **Wheel mapping** (GitHub #12).
- Not planned: the drive board and force feedback, the lamps, the
  `daytonam` / `daytonagtx` / turbo hack sets.

### Still open on the 2A core (`model2a`)

- **The four user reports**, GitHub #15-#18. For #15 (Sega Rally's settings),
  the EEPROM is loaded from the MRA but never saved; check that first.
- **Dead or Alive's bass rumble** (R914 reserved, branch `doa-rumble`).
- **Slowdowns** in Sega Rally and Manx TT; the i960 wait states (R904) are
  parked.
- **Manx TT's second sound board:** main's `m2_sound_board`, ~4,650 ALM,
  doesn't fit beside the 2A board.
- **Air Walkers:** an MRA and a four-player mux. **Motor Raid DX:** its
  drive-board protocol (R892). **The other 2A clones** (vf2a/b/o, Rally's
  other revisions, manxttc, doaa/doaae, dyndeka2, zerogunaj): MRAs with a
  layout check each, not done.
- **Link play for Sega Rally:** from `link-play` (R916).
- **The protection chips themselves** (315-5881: ~300-400 ALM, 1 M10K,
  R862), only if the patches prove insufficient. Zero Gunner's enemy
  patterns are the one visible difference.
- Not planned: the billboard, the drive boards.
