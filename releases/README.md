# Sega Model 2 — releases

There are two cores: **Model 2** (`Model2.rbf`) for the original Model 2
board, and **Model 2A** (`Model2A.rbf`) for the Model 2A-CRX board. Each game's
MRA names the core it runs on, so both can sit in `cores/` side by side.

**The ROM sets are MAME 0.289's.** Every zip in the tables below is MAME
0.289's set of that name (split sets: a clone needs its parent zip too). Sets
from other MAME versions may have different file names or contents and may
not load. ROMs go in `/media/fat/games/mame/`. Nothing here contains ROM
data.

## Model 2 core — `Model2.rbf`

ROM sets: MAME 0.289.

| Game | MRA | ROM zips | MAME set | State |
|---|---|---|---|---|
| Daytona USA (Revision A) | `Daytona USA (Revision A).mra` | `daytona.zip`, plus the I/O board ROM `epr-14869c.25` (in `model1io.zip` or a Daytona zip) | `daytona` | Plays |
| Daytona USA (Deluxe '93) | `Daytona USA (Deluxe 93).mra` | `daytona93.zip`, plus `daytona.zip` with a split set | `daytona93` | Plays |
| Desert Tank | `Desert Tank.mra` | `desert.zip`, plus `epr-14869c.25` as for Daytona | `desert` | Plays |
| Virtua Cop (Revision A) | `Virtua Cop (Revision A).mra` | `vcopa.zip` (or `model1io2.zip` for its I/O ROM) | `vcopa` | Plays |

Each of these also has a `[15kHz CRT]` MRA.

## Model 2A core — `Model2A.rbf` — BETA

**This core is a beta.** All eleven games below boot and play, but there are
known bugs, and some games still slow down in places, mainly Sega Rally and
Manx TT. Please report anything you find, and say which game and where.

### New in this build (`Model2A_20261021c`)

- **Dead or Alive no longer freezes in a match.** The MRA's protection patch
  tripped the game's own boot checksum, and the game then stopped itself 5-20
  seconds into a match (3D gone, HUD and music still going). The new MRAs
  patch the protection chip's routines instead. **Download the new Dead or
  Alive MRAs** (normal and `[15kHz CRT]`): the fix is in them.
- **Dead or Alive's constant bass drone is gone.** The sound chip's effects
  processor was running with all its delay taps at zero, which turned DOA's
  reverb into a low drone. MAME does the same (its default 20 Hz filter hides
  it); the core now leaves the taps alone, as the chip does. Every game's
  reverb is affected: **Virtua Fighter 2 is about 9 dB quieter by default**,
  with its hits and effects clearer against the music (turn `Volume` up to
  taste), and Virtua Cop 2 loses a small constant offset.

### Earlier in `Model2A_20261021b`

- **15 kHz for every game.** The Model 2 core's new scan converter
  (retrorepair's design) is now in the 2A core too, with HDMI kept, and every
  2A game has a `[15kHz CRT]` MRA. Not yet tested on a CRT with the 2A games:
  reports very welcome. See *On a 15 kHz CRT* below.
- **Dead or Alive's floors and buildings are fixed.** The core was
  mip-mapping a game MAME never mip-maps, and read pictures from parts of
  texture memory the game never fills.
- **Mip-mapping matches MAME's choice in every 2A game.** The core used to
  decide when to mip-map with Daytona's settings; each game now uses its own,
  as MAME does. With `Mip-mapping` on `Sharp`, distant scenery in Virtua
  Fighter 2, Sega Rally, Virtua Cop 2, Manx TT and the rest is closer to MAME,
  and Hanguk Pro Yagu 98's is sharper.
- **Motor Raid's high-score screen** no longer has streaks in its 2D.
- **Sega Rally's mirror:** the black mirror some of you saw was the first
  beta (`Model2A_20261020`). It has worked since `Model2A_20261020b`.

### What to copy

| file | where it goes on the SD card |
|---|---|
| `Model2A_20261021c.rbf` | `/media/fat/_Arcade/cores/`, then **rename it to `Model2A.rbf`** |
| the 2A MRAs below | `/media/fat/_Arcade/` |

**SDRAM:** Virtua Fighter 2, Sega Rally, Virtua Cop 2, Zero Gunner and Manx
TT run on a 64 MB or 128 MB module. Pilot Kids, Hanguk Pro Yagu 98, Sky
Target, Dynamite Cop, Motor Raid and Dead or Alive have more than 64 MB of
ROM, so **they need the 128 MB module**.

`Model2A_20261021c.rbf` has the md5 `7f15c5329bb6616ee2f17b5ec5678792`. As with
the Model 2 core, keep exactly one `Model2A*.rbf` in `cores/`.

### Games

ROM sets: MAME 0.289.

| Game | MRA | ROM zips | MAME set | State |
|---|---|---|---|---|
| Virtua Fighter 2 (Version 2.1) | `Virtua Fighter 2 (Version 2.1).mra` | `vf2.zip` | `vf2` | Plays at full speed, with sound |
| Sega Rally Championship (Twin/DX, Revision C) | `Sega Rally Championship - Twin-DX (Revision C).mra` | `srallyc.zip` | `srallyc` | Plays, with wheel, pedals and gears. **Slows down** in busy scenes |
| Virtua Cop 2 | `Virtua Cop 2.mra` | `vcop2.zip` | `vcop2` | Plays, aiming with a mouse or stick; the ammo display counts down and reloads |
| Zero Gunner (Export, Model 2A) | `Zero Gunner (Export, Model 2A).mra` | `zeroguna.zip` and its parent `zerogun.zip` | `zeroguna` | Plays, on the d-pad or either analogue stick |
| Pilot Kids (Model 2A) | `Pilot Kids (Model 2A).mra` | `pltkidsa.zip` and its parent `pltkids.zip` | `pltkidsa` | Plays at full speed. **Needs the 128 MB SDRAM module.** Its protection check is patched out by the MRA |
| Manx TT Superbike (DX/Twin, Revision D) | `Manx TT Superbike - DX-Twin (Revision D).mra` | `manxtt.zip` | `manxtt` | Plays at full speed, with bike controls; boots straight past the motion-seat check. Occasional slowdowns |
| Hanguk Pro Yagu 98 | `Hanguk Pro Yagu 98.mra` | `hpyagu98.zip` | `hpyagu98` | Plays. **Needs the 128 MB SDRAM module.** The MRA loads the factory settings MAME ships in the zip; some surfaces' shading may differ slightly from MAME |
| Sky Target | `Sky Target.mra` | `skytargt.zip` | `skytargt` | Plays. **Needs the 128 MB SDRAM module.** |
| Dynamite Cop (Export, Model 2A) | `Dynamite Cop (Export, Model 2A).mra` | `dynamcop.zip` | `dynamcop` | Plays. **Needs the 128 MB SDRAM module.** Its 315-5881 protection checks are patched out by the MRA |
| Motor Raid (Twin) | `Motor Raid - Twin.mra` | `motoraid.zip` | `motoraid` | Plays. **Needs the 128 MB SDRAM module.** The Twin/DX set (`motoraiddx`) is not supported |
| Dead or Alive (Model 2A) | `Dead or Alive (Model 2A).mra` | `doaab.zip` and its parent `doa.zip` | `doaab` | Plays. **Needs the 128 MB SDRAM module.** Its protection check is patched out by the MRA |

### Known bugs

- **Sega Rally slows down** in some scenes. The 3D holds, but the frame rate
  drops where the geometry processor has the most work. Being looked at.
- **Manx TT** has an occasional slowdown in busy scenes. Its deluxe
  cabinet's extra sound board isn't emulated, so a few extra sounds are
  missing.
- **Sega Rally doesn't save its settings** (NVRAM). Reported by users; not
  looked at yet.
- **Virtua Cop 2's level-selection screen** has some of its text drawn in the
  wrong layer. Reported by users; not looked at yet.
- **Virtua Fighter 2 can crash** at random, in attract or in a fight.
  Being looked at; if it happens to you, please say where.
- **Sound is quiet** with the default settings: Sega Rally and Zero Gunner
  are quiet overall. That is how MAME 0.289 mixes these games, and apart from
  the effects processor fix above the core matches it sample for sample. (MAME can sound louder because it also runs its own audio
  effects, a compressor among them, after the sound chip.) Whether the arcade
  is louder is still an open question. Until then, two OSD settings lift it
  — see *Sound settings* below.
- **Zero Gunner's protection chip isn't emulated.** Its MRA patches out the
  checks instead, so enemy patterns differ from MAME's (the game's random
  numbers read its own code), but the game plays through normally.
- **No link play** for Sega Rally yet.
- **15 kHz on a CRT is not yet tested with the 2A games.** It's the same
  converter as the Model 2 core's, which testers have confirmed on their
  CRTs. Load a game's `[15kHz CRT]` MRA, or set `Video` to `15kHz
  interlaced`.

### Sound settings

| setting | what it does |
|---|---|
| `Volume` | 80% by default. The list runs upward from there: 80, 90, 100, **150, 200, 300, 400%**, then round to 0–70%. Above 100% the loudest moments are limited at full scale, never distorted by wrap-around. |
| `Raw Sound Boost` | `Off` (default), `+6 dB` or `+12 dB`. Raises every voice the sound chip plays directly, but not the effects processor's return. Sega Rally and Zero Gunner use the direct path for almost everything, so they come up nearly the full amount. (The level table below was measured before this build's effects processor fix, which made Virtua Fighter 2 about 9 dB quieter: give it more `Volume` than the table says.) |

**Quiet games: turn `Volume` up. Virtua Fighter 2's hits too quiet against
the music: use `Raw Sound Boost`.** For about the same loudness as Virtua
Fighter 2 at the default 80%:

| game | with `Raw Sound Boost` Off | with `Raw Sound Boost` +12 dB |
|---|---|---|
| Virtua Fighter 2 | `Volume` 80% (its loudest hits reach full scale at about 130%) | `Volume` 40–50% keeps the music where it was, with the hits up about 7 dB |
| Sega Rally | `Volume` 400% still leaves it a little quieter (its peaks reach only a third of full scale) | `Volume` 150% (no limiting below about 300%) |
| Zero Gunner | `Volume` 300–400% (no limiting up to 400%) | `Volume` 100% (no limiting below about 180%) |

## Model 2 core release notes

### What to copy

| file | where it goes on the SD card |
|---|---|
| `Model2_20261021b.rbf` | `/media/fat/_Arcade/cores/`, then **rename it to `Model2.rbf`** |
| `Daytona USA (Revision A).mra` | `/media/fat/_Arcade/` — the 1994 version |
| `Daytona USA (Deluxe 93).mra` | `/media/fat/_Arcade/` |
| `Desert Tank.mra` | `/media/fat/_Arcade/` |
| `Virtua Cop (Revision A).mra` | `/media/fat/_Arcade/` |
| the four `[15kHz CRT]` versions of those | `/media/fat/_Arcade/` — each starts in 15 kHz, for a CRT |

There's only ever one core here, and it runs all three games: the MRA you
pick tells it which. Older builds are in this repository's git history if
you need one.

You supply the ROMs. They go in `/media/fat/games/mame/`, named the way the
MRA expects. Nothing in this folder contains ROM data.

### ROMs

All sets are MAME 0.289's.

| zip | for |
|---|---|
| `daytona.zip` | Daytona USA (Revision A), MAME's `daytona` set |
| `daytona93.zip` | Daytona USA (Deluxe '93). With a split set you also need `daytona.zip` next to it, because the two share files. A merged `daytona.zip` on its own works too. |
| `desert.zip` | Desert Tank, MAME's `desert` set. Older sets name two of the polygon ROMs `.21` / `.20` instead of `.20` / `.21`; either works. |
| `vcopa.zip` | Virtua Cop (Revision A), MAME's `vcopa` set |
| `model1io.zip`, or a Daytona zip | Daytona's and Desert Tank's I/O board ROM, `epr-14869c.25` |

Daytona and Desert Tank use the same I/O board, and its ROM is looked for in
`model1io.zip` and in the Daytona zips, so it will be found wherever your set
keeps it (`desert.zip` doesn't carry it). Without it you get no controls at
all: the game reads coins, start and steering through the I/O board, so a
missing `epr-14869c.25` looks like a machine that runs and ignores you.

Virtua Cop has its own I/O board, and its ROM, `epr-17181.6`, is inside
`vcopa.zip` (or `model1io2.zip`).

The TGP coprocessor's microcode is not a separate download. It sits inside
the game's data ROM and the core pulls it out.

**Check you're running the right file.** `Model2_20261021b.rbf` has the md5 `672b7003d3264906e96f4ab0e925bab2`.
If yours doesn't match, the usual reason is a second core file in `cores/`.
MiSTer picks the name that sorts last, and `_` sorts after `.`, so a spare
`Model2_old.rbf` quietly wins over `Model2.rbf`. Keep exactly one, and keep
any backups out of `cores/`.

**SDRAM:** the core needs a 64 MB or larger module. The 3D is drawn into the
DE10-Nano's own DDR3, so nothing else is needed for that.

### What works

Three games run on one core: **Daytona USA** (Revision A and Deluxe '93),
**Desert Tank** and **Virtua Cop**.

| | frames a second |
|---|---|
| Daytona USA, attract and races | 57 of the arcade's 57.5, 99% of frames on time |
| Desert Tank | 29 — the game draws every other frame, as it does on the arcade board |
| Virtua Cop | 29 — the same |

The whole arcade board is in the FPGA: the i960 main CPU, the TGP geometry
coprocessor running the game's own microcode, the geometrizer, a hardware 3D
renderer drawing front to back like the real board, the 2D tile layers, the
I/O boards, and the sound board with its own 68000, YM3438 and MultiPCM
sample chips. The 3D goes into a framebuffer and is only shown when a frame
is finished, so there's no tearing.

Daytona has had the most play by far. Desert Tank has been played through
its missions with no lock in an 87-minute run. Virtua Cop is playable
through its stages with light-gun input. It's the newest, so please report
anything you find.

### New in this release

- **Daytona's road stays sharp in the distance.** With mip-mapping on, the
  road and its lane lines used to step and fade in bands as they went into
  the distance (GitHub issue #11). Mip-mapping is there for the mountains and
  distant scenery, so the road is now always drawn at full detail, at every
  `Mip-mapping` setting; the scenery is mip-mapped exactly as before.
  (`Model2_20261021b`; everything below came in `Model2_20261021`.)
- **A new 15 kHz picture.** The 15 kHz mode now runs the game's 384-line
  picture through a scan converter, so it fills a CRT top to bottom instead of
  sitting between black borders, with no added delay. HDMI keeps working
  alongside it. It's retrorepair's design, and it has been confirmed working
  on CRTs by three testers. The `15kHz width` setting is gone with the old
  picture. See the CRT section.
- **Virtua Cop's ammo display works.** The revolver on screen used to show
  six bullets whatever you did; it now empties as you fire and fills when you
  reload.
- **A texture-memory fix** carried over from the Model 2A work: one of the
  texture RAM's mirror addresses didn't take four-word writes, so three
  words in four of a write there were lost. None of the three games here is
  known to show it, but the core now matches the arcade board.

#### Earlier releases

**20261016:** Desert Tank and Virtua Cop on the same core as Daytona, with
light-gun and mouse aiming for Virtua Cop. Mip-mapping. Sound at the arcade's
balance and tempo. No more doubled scanlines in the 2D, and the 2D background
kept in step with the 3D. Volume control, steering smoothing, and a right-stick
option for wheels. 15 kHz starting at the standard 15.7 kHz. A shorter menu.

**20261013:** races at full speed, from a faster main CPU (8 KB instruction
cache and better instruction fetching). Steering wheel support. Split and
merged ROM sets for Deluxe '93. An 11-hour soak without a lock.

**20261011:** the random lock-up after 20 to 60 minutes was fixed, and races
went from mostly 30 to mostly 57 frames a second. Also: the 3D no longer goes
black; car windows stay; textures take the arcade's colours; the near road
stopped juddering; the car-select tyres came back; ROLLING START scrolls; the
mini-map and condition panel sit in the right place; no black band above the
sky; the "G" of GAME OVER is back; and 15 kHz CRT support with its own MRAs.

### OSD settings

| setting | what it does |
|---|---|
| `Aspect ratio` | as on other MiSTer cores |
| `Video` | `Native 24kHz`, or `15kHz interlaced` for a CRT. With a `[15kHz CRT]` MRA it reads `15kHz (CRT MRA)` and can't be changed. |
| `15kHz lines` | `273/274 (15.7kHz)` (default), `268/269 (15.4kHz)` or `262/263 (15.1kHz)` — see the CRT section |
| `Textures` | `On`, or `Off` to draw every polygon flat |
| `Texture filter` | `Bilinear` (default) or `Point` |
| `Mip-mapping` | `Sharp` (default), `Medium`, `Smooth` or `Off` — how soon distant textures switch to their smaller versions. Daytona's road is always drawn at full detail |
| `Draw method` | `Double Buffered` (default) draws every frame; `Single buffered` draws every other one |
| `Gamma` | `MAME` (default), `Off` or `Mild`. Affects 2D and 3D together. |
| `Volume` | 80% by default, in 10% steps; goes from 100% round to 0% |
| `Pedals` | swaps accelerator and brake if your controller has them the other way round |
| `Steering` | how much stick gives full lock: `3/4` (default), `Full`, `5/4` or `Half` |
| `Steering smoothing` | `Off` (default), `Light` or `Wheel` — see above |
| `Right stick` | `Pedals only` (default), or `Pedals+steer`: left/right steers as well, for a wheel |
| `Crosshair` | Virtua Cop only: `Small`, `Large` or `Off`. Player 1's shows all the time, player 2's only while player 2 is playing. Use `Off` with a real light gun. |
| `Mouse` | Virtua Cop only: which gun the mouse drives — `Gun 1 trigger` (default: its buttons only), `Gun 1 aim+trigger`, `Gun 2 trigger` or `Gun 2 aim+trigger` |
| `Gun reload` | Virtua Cop only: `Shoot off-screen` (default, as the cabinet) or `Auto` |
| `Save settings (NVRAM)` | writes the game's own settings and records to the SD card |

### Controls

#### Daytona USA

| | |
|---|---|
| Steer | left stick, the d-pad, or a wheel (see below) |
| Accelerate / brake | right stick up / down, or the `Accel` and `Brake` buttons |
| Gears | `Gear Up` / `Gear Down` |
| View buttons | `VR1 Red`, `VR2 Blue`, `VR3 Yellow`, `VR4 Green` |
| Start, Coin | `Start`, `Coin` |
| Test, Service | can be mapped in MiSTer's input settings |

Both pedals share one axis, the right stick's up and down: one way
accelerates, the other brakes, and how far you push sets how hard. If they
come out backwards, set `Pedals` to `Swapped`. The `Accel` and `Brake`
buttons always press fully.

Steering comes from a paddle if MiSTer provides one (some wheels show up that
way), otherwise from the left stick, otherwise from the d-pad, which ramps
and recentres. A small movement around the centre of a stick is ignored.

**With a wheel:** MiSTer usually maps a wheel onto the right stick, with
steering on left/right and the pedals on up/down. Set `Right stick` to
`Pedals+steer` and it will work. If the pedals are reversed, use `Pedals`. If the
steering feels too light or too heavy, try the `Steering` settings. I'd love
to hear from wheel owners: this has been built to how MiSTer maps wheels, but
not yet tried on one.

#### Desert Tank

| | |
|---|---|
| Steer the tank | left stick, the d-pad's left/right, or a wheel |
| Aim the cannon up / down | right stick up / down (level when you let go); the d-pad's up/down nudges it and it stays put |
| Drive forward / reverse | the `Forward` and `Reverse` buttons — put them on your triggers |
| Machine gun, cannon | `Machine Gun`, `Cannon` |
| Views | `VR1 Blue`, `VR2 Green`, `VR3 Red` |
| Shift | flips the forward/reverse lever by hand (Forward and Reverse set it for you) |

The MRA renames the buttons, so MiSTer's define-buttons screen asks for these
names. With `Right stick: Pedals+steer` (a wheel), the wheel steers, the
pedal axis drives forward or back, and the d-pad aims.

#### Virtua Cop

| | |
|---|---|
| Aim | player 1: the left stick of controller 1, or the mouse (see `Mouse`); player 2: the left stick of controller 2 |
| Fire | `Trigger`, or the mouse's left button |
| Reload | shoot off the screen, or `Reload`, or the mouse's right button |
| Start, Coin | `Start`, `Coin` on each player's controller |
| Test, Service | player 1's controller |

**With a USB light gun:** MiSTer sends a USB gun's position as the left
analog stick and its buttons as the mouse's, which is exactly what the core
takes. Calibrate the gun in MiSTer's own menu (F10), leave `Mouse` at its
default, and set `Crosshair` to `Off`. A second gun goes on controller 2.

The attract's tutorial text is in Japanese: Virtua Cop keeps its country in
its own backup RAM, and a fresh set starts as Japan, as it does in MAME. The
country is the game's own setting, so change it in its test menu, or use a
ROM set from another region.

### On a 15 kHz CRT

The game's own picture is 24 kHz, which a 15 kHz TV can't show. The core has a
15 kHz interlaced mode for it, at the game's own speed. The game keeps drawing
its native 384-line picture, and a scan converter turns that into 480 lines,
two fields of 240, so the picture fills the screen top to bottom instead of
sitting between black borders. It adds no delay, and for games that draw every
other frame (Virtua Cop, Desert Tank) it keeps each picture's two fields
together so moving things aren't combed. HDMI keeps working alongside it.

The converter is [retrorepair](https://github.com/retrorepair/sega-model2-mister)'s
design, from their CRT and light-gun work on this core.

The easy way is to **load the `[15kHz CRT]` version** of the game from the
MiSTer menu. It starts in 15 kHz straight away. With a normal MRA, set
`Video` to `15kHz interlaced`.

`15kHz lines` starts at `273/274`, the standard 15.7 kHz line rate, which is
what most TVs want. A few sets prefer NTSC's line count instead: if yours
rolls or loses sync, try `262/263` (15.1 kHz), or `268/269` (15.4 kHz) in
between.

The picture is the same 240 lines a field at every line rate. The game runs at
57.5 frames a second, not 60, so a faster line rate means more lines in each
field, and on some sets the picture looks a little shorter at 15.4 and 15.7 kHz
than at 15.1. The old `15kHz width` setting is gone with the old picture.

Three testers have confirmed the converter working on their CRTs. More
reports are very welcome: which TV, how it's connected, and which settings
work for you.

### MiSTer's audio filter is switched off

This core switches off MiSTer's own audio filter. The game sounds exactly the
same on HDMI, the 3.5 mm jack and S/PDIF; it's only MiSTer's filter presets
(in the menu and `MiSTer.ini`) that have no effect while this core is running.
Nothing in your MiSTer setup is changed.

The reason is space: the whole Model 2 board only just fits in the FPGA, and
the filter takes about 430 of its logic blocks. It's meant to come back once
the remaining features are in, if there's room left.

If you build the core yourself: it's one small, switchable change to the
framework file `sys/audio_out.sv`, kept as a patch in
`docs/framework-patches/` with a README explaining it.

### Still to come

- **Reports from CRT, wheel and light-gun owners** (see above), and from
  anyone running the Deluxe '93 set for long stretches.
- **CRT light guns** (GunCon on MiSTer's SNAC port) are noted for later,
  not being worked on now.

If you find something wrong, please report it.

### Credits

The framework is MiSTer-devel's. The sound board's 68000 is fx68k by Jorge
Cwik (ijor), and its YM3438 is jt12 by Jose Tejada (jotego). The MultiPCM
comes from [meathax](https://github.com/meathax)'s
[s32](https://github.com/meathax/s32) System 32 project. The I/O board's Z80
is tv80 by Guy Hutchison, after Daniel Wallner's T80. The TGP and the video
timing come from the Sega Model 1 core, which solved the same problems first
on the same hardware. The 15 kHz scan converter is retrorepair's.

Hardware behaviour was checked throughout against MAME, whose Model 2 driver
is by R. Belmont, Olivier Galibert, ElSemi, Angelo Salese and Matthew
Daniels, and whose i960 is by Farfetch'd and R. Belmont.

GPL-3.0-or-later. Third-party details and licences are in `THIRD_PARTY.md` in
the source repository.
