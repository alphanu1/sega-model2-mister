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
| Virtua Cop (Revision A) | `Virtua Cop (Revision A).mra` | `vcopa.zip` (or `model1io2.zip` for its I/O ROM) | `vcopa` | Plays. The ammo display always shows full (known, to be fixed) |

Each of these also has a `[15kHz CRT]` MRA.

## Model 2A core — `Model2A.rbf` — BETA

**This core is a beta.** All four games below boot and play, but there are
known bugs, and Sega Rally slows down in places. Please report anything you
find, and say which game and where.

### What to copy

| file | where it goes on the SD card |
|---|---|
| `Model2A_20261020.rbf` | `/media/fat/_Arcade/cores/`, then **rename it to `Model2A.rbf`** |
| the four 2A MRAs below | `/media/fat/_Arcade/` |

**SDRAM:** the four games below run on a 64 MB or 128 MB module. Several of
the games still to come need more than 64 MB of ROM, so **they will need the
128 MB module**; the table further down says which.

`Model2A_20261020.rbf` has the md5 `e44e4a29bab56e0ad579d93f1b3904d6`. As with
the Model 2 core, keep exactly one `Model2A*.rbf` in `cores/`.

### Games

ROM sets: MAME 0.289.

| Game | MRA | ROM zips | MAME set | State |
|---|---|---|---|---|
| Virtua Fighter 2 (Version 2.1) | `Virtua Fighter 2 (Version 2.1).mra` | `vf2.zip` | `vf2` | Plays at full speed, with sound |
| Sega Rally Championship (Twin/DX, Revision C) | `Sega Rally Championship - Twin-DX (Revision C).mra` | `srallyc.zip` | `srallyc` | Plays, with wheel, pedals and gears. **Slows down** in busy scenes |
| Virtua Cop 2 | `Virtua Cop 2.mra` | `vcop2.zip` | `vcop2` | Plays, aiming with a mouse or stick. **No ammo display** |
| Zero Gunner (Export, Model 2A) | `Zero Gunner (Export, Model 2A).mra` | `zeroguna.zip` and its parent `zerogun.zip` | `zeroguna` | Plays, on the d-pad or either analogue stick |

### Known bugs

- **Sega Rally slows down** in some scenes. The 3D holds, but the frame rate
  drops where the geometry processor has the most work. Being looked at.
- **Virtua Cop 2 shows no ammo.** The bullets in the corner aren't drawn, so
  you can't see how many shots are left. Being fixed.
- **Sound is quiet** with the default settings: Sega Rally and Zero Gunner
  are quiet overall, and Virtua Fighter 2's hits sit well under its music.
  That is how MAME 0.289 mixes these games, sample for sample, and the core
  matches it. (MAME can sound louder because it also runs its own audio
  effects, a compressor among them, after the sound chip.) Whether the arcade
  is louder is still an open question. Until then, two OSD settings lift it
  — see *Sound settings* below.
- **Zero Gunner's protection chip isn't emulated.** Its MRA patches out the
  checks instead, so enemy patterns differ from MAME's (the game's random
  numbers read its own code), but the game plays through normally.
- **Virtua Fighter 2 froze in attract** once on an earlier build. It hasn't
  happened since the geometry processor fixes; if it does, please say where.
- **No link play** for Sega Rally yet, and no `[15kHz CRT]` MRAs. To make
  one, copy an MRA and set bit 7 of the game ID byte (index 4).

### Sound settings

| setting | what it does |
|---|---|
| `Volume` | 80% by default. After 70% the list goes on to **150%, 200%, 300% and 400%**. Above 100% the loudest moments are limited at full scale, never distorted by wrap-around. |
| `Sound boost` | `Off` (default: exactly MAME's mix), `+6 dB` or `+12 dB`. Raises every voice the sound chip plays directly, but not the effects processor's return. Virtua Fighter 2's music mostly comes back through that return, so its hits come up against the music (+12 dB: hits +12 dB, music about +5 dB). Sega Rally and Zero Gunner use the direct path for almost everything, so they come up nearly the full amount. |

**Quiet games: turn `Volume` up. Virtua Fighter 2's hits too quiet against
the music: use `Sound boost`.** For about the same loudness as Virtua
Fighter 2 at the default 80%:

| game | with `Sound boost` Off | with `Sound boost` +12 dB |
|---|---|---|
| Virtua Fighter 2 | `Volume` 80% (its loudest hits reach full scale at about 130%) | `Volume` 40–50% keeps the music where it was, with the hits up about 7 dB |
| Sega Rally | `Volume` 400% still leaves it a little quieter (its peaks reach only a third of full scale) | `Volume` 150% (no limiting below about 300%) |
| Zero Gunner | `Volume` 300–400% (no limiting up to 400%) | `Volume` 100% (no limiting below about 180%) |

### Model 2A games not supported yet

These run on the same board and are being brought up next. The zips are
what each will need, as MAME 0.289 names them. Those with an MRA in `mra/`
load on a core built from this branch after the 2026-10-20 release (not the
release above) and are **untested on a board**: they move to the table above
once they have been played.

| Game | ROM zips | MAME set | SDRAM | State |
|---|---|---|---|---|
| Hanguk Pro Yagu 98 | `hpyagu98.zip` | `hpyagu98` | 128 MB | MRA `Hanguk Pro Yagu 98.mra`, which loads the factory settings MAME ships in the zip (`hpyagu98_nvram`, `hpyagu98_backup`); untested on a board |
| Sky Target | `skytargt.zip` | `skytargt` | 128 MB | MRA `Sky Target.mra`; untested on a board |
| Dynamite Cop (Export) | `dynamcop.zip` | `dynamcop` | 128 MB | MRA `Dynamite Cop (Export, Model 2A).mra`, its 315-5881 checks patched out; untested on a board |
| Pilot Kids (Model 2A) | `pltkidsa.zip` and its parent `pltkids.zip` | `pltkidsa` | 128 MB | MRA `Pilot Kids (Model 2A).mra`, its 315-5881 check patched out; untested on a board |
| Manx TT Superbike (DX/Twin, Revision D) | `manxtt.zip` | `manxtt` | 64 MB | Being tested now |
| Motor Raid (Twin) | `motoraid.zip` | `motoraid` | 128 MB | MRA `Motor Raid - Twin.mra`; untested on a board. The Twin/DX set (`motoraiddx`) is not supported |
| Dead or Alive (Model 2A) | `doaab.zip` and its parent `doa.zip` | `doaab` | 128 MB | MRA `Dead or Alive (Model 2A).mra`, its protection check patched out; untested on a board |

## Model 2 core release notes

### What to copy

| file | where it goes on the SD card |
|---|---|
| `Model2_20261016.rbf` | `/media/fat/_Arcade/cores/`, then **rename it to `Model2.rbf`** |
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

**Check you're running the right file.** `Model2_20261016.rbf` has the md5 `644e28fa0dee02c90d4b2d93c2d99fbd`.
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

- **Desert Tank.** Its own MRA, on the same core. Left stick steers, the
  right stick aims the cannon, and the triggers drive forward and reverse.
  See Controls.
- **Virtua Cop.** Its own I/O board is now built into the core, and the main
  CPU gained the maths instructions the game needs. Aim with an analog stick
  or a mouse, so USB light guns that report as either (Sinden, GUN4IR and
  others) work too. Two players, a crosshair each, and reload by shooting
  off-screen. See Controls.
- **Mip-mapping.** Distant textures used to shimmer and crawl as you drove,
  because they were always read at full size, however far away they were.
  Now they're read from smaller, pre-filtered versions as they recede, as
  the arcade board does. `Mip-mapping` in the OSD picks how soon that
  happens: `Sharp` (default) keeps the most detail, `Smooth` the least
  shimmer, and `Off` turns it off. Your own car and anything else the
  game keeps sharp stay at full detail.
- **Sound now matches the arcade's balance.** Each voice's volume used to be
  set in coarse steps that left the music about 3.5 dB too loud, which made
  the speech sound quiet next to it. The GAME OVER speech now comes through
  as it should. The music also played about 4% too fast; it now runs at the
  arcade's tempo.
- **No more doubled scanlines in the 2D.** The tile layers sometimes didn't
  finish a line in time and repeated the one before. That's gone, at 24 kHz
  and at 15 kHz.
- **The background stays with the scene.** The sky and mountains are drawn
  as 2D, the road and cars as 3D, and the two could show different moments of
  the game, so in a slide the backdrop jumped against everything else. They're
  now kept in step.
- **Volume control** in the OSD, starting at 80%.
- **Steering smoothing** in the OSD. Daytona swings its camera as hard as you
  move the steering, so a pad flicked from lock to lock snaps the view in a
  way a real wheel never could. `Light` or `Wheel` limits how fast the
  steering can move, so a slide sweeps across instead. Off by default.
- **Right stick option.** By default the right stick only works the pedals
  (`Pedals only`). Set `Right stick` to `Pedals+steer` if you use a wheel that
  MiSTer maps onto the right stick: then left/right steers and up/down still
  works the pedals. See Controls.
- **More for CRTs.** 15 kHz now starts at the standard 15.7 kHz, which is
  what most TVs need, so the `[15kHz CRT]` MRAs should show a picture straight
  away. Your saved line setting is reset to it once. There's also a new
  15.4 kHz setting, and a `15kHz width` option for sets that show the picture
  squashed at 15.4 or 15.7 kHz.
- **A shorter menu.** Texel step, 3D pacing, Texture brightness and Draw
  method's "every 3rd frame" are gone. They're fixed at the settings that work
  best now the core runs at full speed.
- **Room to grow.** Several parts were made smaller, including both sound
  chips now sharing one engine. That freed space on the FPGA for what comes
  next.

#### Earlier releases

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
| `15kHz width` | `Full` (default) or `Narrow`, for a picture that looks squashed at 15.4 or 15.7 kHz — see the CRT section |
| `Textures` | `On`, or `Off` to draw every polygon flat |
| `Texture filter` | `Bilinear` (default) or `Point` |
| `Mip-mapping` | `Sharp` (default), `Medium`, `Smooth` or `Off` — how soon distant textures switch to their smaller versions |
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
15 kHz interlaced mode that shows all 384 lines as two fields, at the game's
own speed.

The easy way is to **load the `[15kHz CRT]` version** of the game from the
MiSTer menu. It starts in 15 kHz straight away. With a normal MRA, set
`Video` to `15kHz interlaced`.

`15kHz lines` starts at `273/274`, the standard 15.7 kHz line rate, which is
what most TVs want. A few sets prefer NTSC's line count instead: if yours
rolls or loses sync, try `262/263` (15.1 kHz), or `268/269` (15.4 kHz) in
between.

The game runs at 57.5 frames a second, not 60, so a faster line rate means
more lines in each field, and the picture uses fewer of them. On many sets
that makes it look shorter at 15.4 and 15.7 kHz than at 15.1. If yours does
that, set `15kHz width` to `Narrow`: the picture is pulled in from the sides
by the same amount, so it keeps its shape. If it looks too narrow, leave it
on `Full`. It has no effect at 15.1 kHz.

It's been tested on real CRTs, but more reports are very welcome: which TV,
how it's connected, and which settings work for you.

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
on the same hardware.

Hardware behaviour was checked throughout against MAME, whose Model 2 driver
is by R. Belmont, Olivier Galibert, ElSemi, Angelo Salese and Matthew
Daniels, and whose i960 is by Farfetch'd and R. Belmont.

GPL-3.0-or-later. Third-party details and licences are in `THIRD_PARTY.md` in
the source repository.
