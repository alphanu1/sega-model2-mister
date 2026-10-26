# Sega Model 2 — releases

There are three cores: **Model 2** (`Model2.rbf`) for the original Model 2
board, **Model 2A** (`Model2A.rbf`) for the Model 2A-CRX board, and **Model
2C** (`Model2C.rbf`, beta) for the Model 2C-CRX board. Each game's MRA names
the core it runs on, so all three can sit in `cores/` side by side.

| in this folder | what it is |
|---|---|
| `Model2_*.rbf` | the Model 2 core |
| `Model2A_*.rbf` | the Model 2A core |
| `Model2C_*.rbf` | the Model 2C core (beta) |
| `mra/` | every MRA for all three cores, including the `[15kHz CRT]` versions |
| `helpers/m2link/` | only for Daytona link play (experimental) -- see the Model 2 notes |

Copy the MRAs you want from `mra/` to `/media/fat/_Arcade/` (or any folder
under it).

## Not just a MAME port

MAME has been the main reference for these cores: every part is checked
against it, often instruction for instruction and sample for sample. But the
cores are the arcade board rebuilt as hardware in the FPGA (the Intel i960
main CPU, the Fujitsu TGP geometry processor, the 3D renderer, the 2D video
chips, the sound boards and the I/O boards), and where the real board behaves
differently from MAME, fixes have been added to get as close to the real
hardware as possible:

- **Dead or Alive's bass drone is gone (Model 2A).** MAME runs the sound
  chip's effects processor with its delay taps at zero, which turns Dead or
  Alive's reverb into a constant low drone (MAME's own 20 Hz filter hides it).
  The core keeps the taps as the chip does: no drone, and Virtua Fighter 2's
  hits come through clearer against the music.
- **Virtua Cop 2's stage select shows SHOOT TO SELECT (Model 2A).** MAME
  draws the city map, a 2D layer set to go over the 3D, on top of the text in
  front of it. The board settles the 2D layers' own order first, so the text
  sits over the city, and so does the core.
- **Zero Gunner's SCORE RANKING shows the helicopter icons beside each name
  (Model 2A)**, from the same 2D layer fix. MAME never draws them.
- **Sky Target's sky has no lines between its panels (Model 2A).** MAME's
  bilinear filtering draws thin lines where the sky's panels meet; the board
  doesn't. With `Texture filter` on `Auto` (the default), the core draws Sky
  Target with point sampling, and the lines are gone.
- **Light guns fire right up to the screen edge (Virtua Cop, Virtua Cop
  2).** MAME treats the outer 5% of the gun's range as off-screen (about 24
  pixels at the sides), so shots near the edges turn into reloads. A real gun
  only reads off-screen when it can't see the screen; the cores now treat
  just the outermost 2 pixels as off-screen, so aiming off the screen still
  reloads.

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

## Model 2A core — `Model2A.rbf`

All eleven games below boot and play. A few known bugs remain (listed
below). Please report anything you find, and say which game and where.

### New in this build (`Model2A_20261026`)

- **Virtua Cop 2 runs at full speed on the expert stage's train** (GitHub
  #29). The 3D drawing ran out of time when the carriage filled with enemies
  and the game dropped to half speed; spans hidden behind what's already
  drawn are now skipped, and the train holds 57.5 frames a second.
- **Virtua Cop 2's RANKING screen shows every score.** The ranking's big
  letters and digits are 3D polygons, and the table needs more than the 2,048
  polygons a frame the core could hold, so the last score went missing. A
  heavy frame can now use up to 2,560.
- **Light guns fire right up to the screen edge** (see *Not just a MAME port*
  above): only the outermost 2 pixels count as off-screen.
- **Fewer stray pixels around trees** (Virtua Fighter 2's Lau stage, Sega
  Rally): a texture coordinate a hair below zero was read from the far side of
  the texture instead of its edge.
- **`Analog control` for wheels** (GitHub #12): `Wheel A` and `Wheel B`
  layouts beside today's (`Standard`, still the default). Sega Rally steers
  and pedals as Daytona does; in **Manx TT** and **Motor Raid** the wheel leans
  the bike, the accelerator pedal is the throttle and the brake pedal the
  brake. **Sky Target** ignores the setting. Not yet tried on a real wheel:
  please report how it goes. See *Analog control* under the Model 2 core's
  Controls below.
- **Builds close timing with more room to spare**: three paths that most
  often made builds fail are shorter, each proven to behave identically.

### Earlier in `Model2A_20261024b`

- **Sega Rally's cars no longer have white dots along their panels.** The
  shadow crack fix in `Model2A_20261024` widened plain-coloured polygons
  slightly to close hairline gaps. The cars' bodies are plain white panels
  with the livery drawn over them as decals, and the widened panels painted
  over the decals' edges. MAME draws no dots there.
- **New OSD setting `Seam fill`: `Off` / `Black only` / `On`.**
  - `Off` (default): polygons are drawn as before `Model2A_20261024`. The
    cars are clean; Sega Rally's car shadows can show thin cracks.
  - `Black only`: the crack fix only on black polygons, which is what the
    shadows are. Solid shadows, clean cars; black trim (window frames,
    sills) can be widened by a fraction of a pixel.
  - `On`: the crack fix on every plain polygon, as in `Model2A_20261024`,
    dots included.

  The setting applies to every 2A game: with `Black only` or `On`, any game
  that draws plain polygons next to textured ones can show stray edge
  pixels. **This is a temporary fix**: a proper one, which fills only the
  real gaps, is being worked on.

### Earlier in `Model2A_20261024`

**Download the new 2A MRAs too** (normal and `[15kHz CRT]`): the settings
fix below needs them, and the old MRAs don't work with this core's save file.

- **Settings are saved, Sega Rally's among them** (GitHub #15). The core
  saved the backup RAM but not the board's small EEPROM, where Sega Rally
  and other games keep their test-menu settings. Both now go in the save
  file.
- **Sega Rally: the white dots in the sky and the seams in the car shadows
  are gone** (GitHub #26). (The shadow fix is now the `Seam fill` setting,
  off by default: see `Model2A_20261024b` above.) The dots were the mountains' top edge picking up
  the row of texture just above it; the shadow seams were hairline cracks
  between polygons.
- **Text and 2D no longer flicker or pick up wrong values.** When a game
  read its 2D tile memory or palette back, the core returned the word next
  to the one asked for. Fixes the Manx TT leaderboard flicker (GitHub #21)
  and 2D read-backs in Virtua Fighter 2, Zero Gunner and Virtua Cop 2.
- **Dynamite Cop's sea** is drawn properly: very wide sea polygons were
  being clamped instead of scaled.
- **Cleaner sound.** The sound chip runs at 44.1 kHz and MiSTer's audio
  output at 48 kHz; the core now smooths between samples instead of
  repeating them, which removes the tinny, fizzy edge in every game.
- **`Texture filter` is now `Auto` / `Point`** (was `Bilinear` / `Point`).
  `Auto` is bilinear for every game except Sky Target, which the board draws
  without the lines between its sky panels (see *Not just a MAME port*
  above). A saved `Bilinear` opens as `Auto`, a saved `Point` stays `Point`.
- **15 kHz pairing** (`Auto` / `Off`), as in the Model 2 core: games that
  draw every other frame no longer jump their line timing when they slip a
  frame.
- **More room in the FPGA.** Parts of the chip that did the same job side
  by side now share one copy, checked clock for clock against the old
  design: about 1,500 logic blocks freed with nothing removed, which also
  makes clean builds easier.

### Earlier in `Model2A_20261022`

- **Sega Rally and Manx TT run at full speed, and Rally's opponents behave.**
  The main CPU was too slow in the races: every function call saved and
  restored its registers through memory, and Sega Rally reacts to running
  short of time by switching its nearest opponents to a simpler model. That
  made them blink, let you drive through them, and now and then launched one
  into the air (GitHub #19); it also caused both games' slowdowns. The CPU
  now keeps eight sets of registers on chip and has a small data cache, so
  races hold the full 57.5 frames a second and the opponents stay solid.
- **Virtua Fighter 2 no longer freezes.** The freeze (3D stopped, music
  still playing; GitHub #17) came from the geometry processor's result
  queue: some of VF2's commands return more words than the queue holds, and
  the extra words were dropped, leaving the main CPU waiting for them
  forever. Skipping a win pose with Start made it most likely. The geometry
  processor now waits for room instead of dropping a word.

### Earlier in `Model2A_20261021d`

- **Virtua Cop 2's stage select shows SHOOT TO SELECT properly.** The city
  map behind it is a 2D layer set to go over the 3D, and it was being drawn
  over the text in front of it (MAME does the same). The 2D layers now settle
  their own order first, so the text sits over the city. The same fix should
  bring back the helicopter icons beside each name on Zero Gunner's SCORE
  RANKING screen, which MAME never shows.

### Earlier in `Model2A_20261021c`

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
| `Model2A_20261026.rbf` | `/media/fat/_Arcade/cores/`, then **rename it to `Model2A.rbf`** |
| the 2A MRAs, from `mra/` | `/media/fat/_Arcade/` |

**SDRAM:** Virtua Fighter 2, Sega Rally, Virtua Cop 2, Zero Gunner and Manx
TT run on a 64 MB or 128 MB module. Pilot Kids, Hanguk Pro Yagu 98, Sky
Target, Dynamite Cop, Motor Raid and Dead or Alive have more than 64 MB of
ROM, so **they need the 128 MB module**.

`Model2A_20261026.rbf` has the md5 `ba126491849a02eab1f9e095be67b4c9`. As with
the Model 2 core, keep exactly one `Model2A*.rbf` in `cores/`.

### Games

ROM sets: MAME 0.289.

| Game | MRA | ROM zips | MAME set | State |
|---|---|---|---|---|
| Virtua Fighter 2 (Version 2.1) | `Virtua Fighter 2 (Version 2.1).mra` | `vf2.zip` | `vf2` | Plays at full speed, with sound |
| Sega Rally Championship (Twin/DX, Revision C) | `Sega Rally Championship - Twin-DX (Revision C).mra` | `srallyc.zip` | `srallyc` | Plays at full speed, with wheel, pedals and gears |
| Virtua Cop 2 | `Virtua Cop 2.mra` | `vcop2.zip` | `vcop2` | Plays, aiming with a mouse or stick; the ammo display counts down and reloads |
| Zero Gunner (Export, Model 2A) | `Zero Gunner (Export, Model 2A).mra` | `zeroguna.zip` and its parent `zerogun.zip` | `zeroguna` | Plays, on the d-pad or either analogue stick |
| Pilot Kids (Model 2A) | `Pilot Kids (Model 2A).mra` | `pltkidsa.zip` and its parent `pltkids.zip` | `pltkidsa` | Plays at full speed. **Needs the 128 MB SDRAM module.** Its protection check is patched out by the MRA |
| Manx TT Superbike (DX/Twin, Revision D) | `Manx TT Superbike - DX-Twin (Revision D).mra` | `manxtt.zip` | `manxtt` | Plays at full speed, with bike controls; boots straight past the motion-seat check |
| Hanguk Pro Yagu 98 | `Hanguk Pro Yagu 98.mra` | `hpyagu98.zip` | `hpyagu98` | Plays. **Needs the 128 MB SDRAM module.** The MRA loads the factory settings MAME ships in the zip; some surfaces' shading may differ slightly from MAME |
| Sky Target | `Sky Target.mra` | `skytargt.zip` | `skytargt` | Plays. **Needs the 128 MB SDRAM module.** |
| Dynamite Cop (Export, Model 2A) | `Dynamite Cop (Export, Model 2A).mra` | `dynamcop.zip` | `dynamcop` | Plays. **Needs the 128 MB SDRAM module.** Its 315-5881 protection checks are patched out by the MRA |
| Motor Raid (Twin) | `Motor Raid - Twin.mra` | `motoraid.zip` | `motoraid` | Plays. **Needs the 128 MB SDRAM module.** The Twin/DX set (`motoraiddx`) is not supported |
| Dead or Alive (Model 2A) | `Dead or Alive (Model 2A).mra` | `doaab.zip` and its parent `doa.zip` | `doaab` | Plays. **Needs the 128 MB SDRAM module.** Its protection check is patched out by the MRA |

### Known bugs

- **Virtua Cop 2: shots don't land on the crosshair?** Reset the game's
  settings to their defaults in its test menu, then save (OSD, Save
  settings). That fixes the gun calibration.
- **Manx TT**'s deluxe cabinet's extra sound board isn't emulated, so a few
  extra sounds are missing.
- **An occasional stray pixel near trees** (Sega Rally, Pilot Kids' window
  tree): far fewer than before and gone in a moment. MAME draws Pilot Kids'
  one too.
- **Sega Rally:** the AI cars can flash for about a second in the second
  race.
- **Virtua Fighter 2:** Jacky and Sarah's stage slows down in places.
- **Manx TT:** cresting a hill, the road beyond can show the sea through it
  for a moment, and road behind hills appears a little late.
- **Thin seams between some polygons show the background through them**
  (Virtua Fighter 2's Jacky and Sarah stages, Dead or Alive). Being worked on.
- **Sound balance:** in Dynamite Cop the environment sounds (breaking boxes)
  are too loud against the shots and music, and Virtua Fighter 2's effects
  are low. Being investigated against MAME and the board.
- **Slowdown:** Motor Raid slows a little in busy moments (GitHub #25).
  Being investigated.
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

## Model 2C core — `Model2C.rbf` (BETA)

The first Model 2C core: three games. The 2C board replaces the 2A's
geometry chip with Sega's TGPx4 (Fujitsu MB86235), rebuilt here from
scratch and checked against MAME output for output. It's a beta: please
report anything you find, with the game and where.

### What to copy

| file | where it goes on the SD card |
|---|---|
| `Model2C_20261024.rbf` | `/media/fat/_Arcade/cores/`, then **rename it to `Model2C.rbf`** |
| the 2C MRAs, from `mra/` | `/media/fat/_Arcade/` |

`Model2C_20261024.rbf` has the md5 `f6a672fde023a08c4f45c8b042756a3d`. Keep
exactly one `Model2C*.rbf` in `cores/`.

**The game's settings now save.** Change them in the test menu, then use the
OSD's "Save settings (NVRAM)". Use the MRAs from this folder: older 2C MRAs
don't save the settings.

### Games

ROM sets: MAME 0.289.

| Game | MRA | ROM zips | MAME set | State |
|---|---|---|---|---|
| The House of the Dead (Revision A) | `The House of the Dead (Revision A).mra` | `hotd.zip` | `hotd` | Plays at full speed, with guns from a mouse or stick. **Needs the 128 MB SDRAM module.** |
| Over Rev (Model 2C, Revision A) | `Over Rev (Model 2C, Revision A).mra` | `overrev.zip` | `overrev` | Plays, with wheel and pedals |
| Sega Touring Car Championship | `Sega Touring Car Championship (newer).mra` | `stcc.zip` | `stcc` | Boots and races. **Needs the 128 MB SDRAM module.** No music yet |

Each of these also has a `[15kHz CRT]` MRA.

### Fixed since the first test builds

- **House of the Dead's sound no longer wobbles, crackles or clips** on the
  attract's tutorial screen and similar busy moments (the sound chip was
  running out of time on each sample).
- **Cleaner sound.** The high, tinny layer (in House of the Dead's chapter
  2 most of all) is gone: the core now smooths between the sound chip's
  44.1 kHz samples for MiSTer's 48 kHz output instead of repeating them.
- **Test-menu settings are saved** for all three games.
- **Sega Touring Car Championship's title and rankings** no longer show
  garbage tiles (the 2D read-back fix, as in the Model 2A core).
- **`Texture filter`** is `Auto` / `Point`, as in the Model 2A core.
- **Clean timing, with room to spare**, from the same space saving as the
  Model 2A core.

### Known bugs

- **House of the Dead: shots don't land on the crosshair?** Run TEST MENU →
  GUN SETTING → PLAYER 1 / PLAYER 2 GUN DEFAULT ADJUSTMENT, then save (OSD,
  Save settings). A fix that lines them up without calibrating is coming.
- **House of the Dead**: the music is too loud against the gun shots, in
  chapter 2 most of all. `Raw Sound Boost` brings the shots back up (it
  lifts the music a little too). Being investigated.
- **Sega Touring Car Championship has no music.** Its music board plays
  MPEG audio, which the core doesn't have yet. Engine sounds and effects
  play. Races may slow down, and the pedals haven't been checked on a real
  wheel yet.
- **Over Rev** slows down a few times in a race, sometimes for a few
  seconds, and a row of dark blue dots can show in the sky along one line.
- **House of the Dead**'s courtyard shadows can look like they slide apart
  and meet again.
- No link play for Over Rev or Sega Touring Car Championship yet.

## Model 2 core release notes

### What to copy

| file | where it goes on the SD card |
|---|---|
| `Model2_20261026.rbf` | `/media/fat/_Arcade/cores/`, then **rename it to `Model2.rbf`** |
| `mra/Daytona USA (Revision A).mra` | `/media/fat/_Arcade/` — the 1994 version |
| `mra/Daytona USA (Deluxe 93).mra` | `/media/fat/_Arcade/` |
| `mra/Desert Tank.mra` | `/media/fat/_Arcade/` |
| `mra/Virtua Cop (Revision A).mra` | `/media/fat/_Arcade/` |
| the four `[15kHz CRT]` versions of those, also in `mra/` | `/media/fat/_Arcade/` — each starts in 15 kHz, for a CRT |
| `helpers/m2link/` | only for link play — see *Link play* below |

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

**Check you're running the right file.** `Model2_20261026.rbf` has the md5 `94173c3a71e2ee1eaf79e511cd319f7d`.
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

- **`Analog control` for wheels** (GitHub #12): `Wheel A` and `Wheel B`
  layouts beside today's (`Standard`, still the default), for wheels whose
  pedals MiSTer reports on their own axes. Not yet tried on a real wheel:
  please report how it goes. See *Analog control* under Controls below.
  (`Model2_20261026`.)
- **Virtua Cop: the gun fires right up to the screen edge.** Only the
  outermost 2 pixels count as off-screen now, instead of MAME's 5% border
  (see *Not just a MAME port* above). (`Model2_20261026`.)
- **Cleaner sound.** The sound board runs at about 44.6 kHz and MiSTer's
  audio output at 48 kHz; the core now smooths between samples instead of
  repeating them, which removes the tinny, fizzy edge. (`Model2_20261025`.)
- **Cleaner texture edges in Daytona.** A polygon's edge pixels could pick
  up a texel from just outside its own texture; they are now kept inside it.
  (`Model2_20261025`.)
- **More room in the FPGA.** Parts of the chip that did the same job side
  by side now share one copy, checked clock for clock against the old
  design: about 1,400 logic blocks freed, nothing removed or changed in how
  the games run. (`Model2_20261025`.)
- **15 kHz: Virtua Cop and Desert Tank no longer upset picky CRTs.** These
  two games draw a new picture every second frame, and when they slipped a
  frame the 15 kHz converter jumped its line timing to catch up, which some
  CRTs saw as a short loss of sync (GitHub #24). The line timing now never
  moves. New OSD option `15kHz pairing` (`Auto` / `Off`) for TVs that are
  still unhappy. Every other game's 15 kHz picture is exactly as before.
- **Virtua Cop's 2D reads are right.** When the game read its tilemaps or
  its 2D palette back, the core returned the word next to the one asked for
  (and a 32-bit read came back with its halves swapped). Writes were always
  right, so most of the picture was too, but anything the game worked out
  from a read-back was off. Daytona never reads them back, so it is
  unchanged. (`Model2_20261023`.)
- **Virtua Cop's colours are fixed: white clouds, grey concrete.** The clouds
  over the wharf came out black with white edges, the ground light blue, and
  the bars above and below the picture grey (GitHub #10). The core shaded
  Virtua Cop's and Desert Tank's textures with a brightness model built from
  Daytona's tables; it now uses each game's own tables, as the arcade board
  does. Desert Tank's sand and tanks take MAME's tones too. Daytona is
  unchanged. (`Model2_20261022`.)
- **Gun flash for CRT light guns (Virtua Cop).** On each shot the game flashes
  the screen white for a frame, so a CRT light gun such as the GunCon 2 can
  see where it's aimed (GitHub #13). The core didn't show it before. A new
  `Gun flash` setting: `Arcade` (default, the game's flash) or `Off` (no
  flash at all, for Sinden, mouse or stick players). Not yet tested with a
  GunCon 2: reports very welcome. (Virtua Cop 2, on the Model 2A core,
  already shows its flash: it needs no setting.)
- **Link play for Daytona USA (experimental).** Race other cabinets over your network:
  MiSTers, or PCs running the Daytona USA recompilation, in any mix. The
  link board is switched on in the OSD (`Link board`, Daytona only, Off by
  default), and a small helper program on the MiSTer's Linux carries the
  link. Master, slave and car number are the game's own test-menu settings.
  Optional frame sync keeps every cabinet on the master's frame. See *Link
  play* below for the setup. (`Model2_20261021c`.)
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
| `15kHz pairing` | `Auto` (default) or `Off`. Only Virtua Cop and Desert Tank (they draw a new picture every second frame) are affected. `Auto` keeps both fields of a frame from the same picture; if your CRT still loses sync briefly in those two games, choose `Off` — on a CRT it costs nothing |
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
| `Analog control` | `Standard` (default: the controls described here), `Wheel A` or `Wheel B`, for a wheel with its own pedal axes — see *Analog control* under Controls. |
| `Crosshair` | Virtua Cop only: `Small`, `Large` or `Off`. Player 1's shows all the time, player 2's only while player 2 is playing. Use `Off` with a real light gun. |
| `Mouse` | Virtua Cop only: which gun the mouse drives — `Gun 1 trigger` (default: its buttons only), `Gun 1 aim+trigger`, `Gun 2 trigger` or `Gun 2 aim+trigger` |
| `Gun reload` | Virtua Cop only: `Shoot off-screen` (default, as the cabinet) or `Auto` |
| `Gun flash` | Virtua Cop only: `Arcade` (default) or `Off` — the white flash on a shot, for CRT light guns |
| `Link board` | Daytona USA only, experimental: `Off` (default) or `On`, for link play with the `m2link` helper — see *Link play* |
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

**Analog control: Wheel A / Wheel B** (GitHub #12). Many wheels show up with the wheel on the *left* stick and each pedal
on its own axis, as Jotego's OutRun core expects. Pick the layout that
matches yours:

| | steering | accelerator | brake |
|---|---|---|---|
| `Wheel A` — most older wheels (the cathoderayblog setup guide) | left stick left/right | left stick **up**: centre is released, fully up is fully pressed | right stick **up**, the same way |
| `Wheel B` — newer pedal sets such as the Logitech RS50's | left stick left/right | left stick up/down over its **whole** travel: fully up is released, fully down is fully pressed | right stick left/right over its whole travel: fully left is released, fully right is fully pressed |

In both, the steering has no dead zone and the right stick never steers
(`Right stick` doesn't apply); `Steering` and `Steering smoothing` work as
before; `Pedals: Swapped` exchanges the two pedals; the `Accel` and `Brake`
buttons still press fully; the d-pad steers while you hold it. Don't use
`Wheel B` on a pad: with no pedals connected it reads half accelerator and
half brake. These follow how the wheel's owner says MiSTer reports these
wheels; they haven't been tried on one here yet, so please report how they
behave.

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
pedal axis drives forward or back, and the d-pad aims. With `Analog control:
Wheel A` or `Wheel B`, the accelerator pedal drives forward and the brake
pedal backwards (whichever is pressed further), and the d-pad aims.

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

### Link play: Daytona USA, cabinet against cabinet (EXPERIMENTAL)

> **Experimental.** Link play is new and has only been tested on a few
> setups so far (a MiSTer linked to the PC recompilation). Expect rough
> edges, and please report what works and what doesn't: your network, how
> many cabinets, MiSTer or PC, and whether frame sync was on.

Daytona USA (Revision A, the 1994 set) can race other cabinets over your
network, wired or Wi-Fi, like linked arcade machines: two MiSTers, or a
MiSTer and a PC running the
[Daytona USA recompilation](https://github.com/alphanu1/daytona-arcade-recomp),
or more of either. They speak the same protocol, so any mix works.

The MiSTer's network is on its Linux side, so a small program, `m2link`,
carries the link; the core just needs its link board switched on. Everything
is in `helpers/m2link/` here, ready to copy — nothing to build.
The same instructions are in `helpers/m2link/README.md`, next to the files.

| file in `helpers/m2link/` | where it goes on the SD card |
|---|---|
| `m2link` (the program) | `/media/fat/linux/m2link` |
| `m2link.ini` (its settings) | `/media/fat/linux/m2link.ini` |
| `m2link.sh` (start / stop) | `/media/fat/Scripts/m2link.sh` (only if you run it from the Scripts menu) |

`m2link` md5: `adccae3cf26e070dcd205f2045003d01`

**Setting up each MiSTer:**

1. Copy the files as in the table above.
2. Edit `/media/fat/linux/m2link.ini`. Two lines matter:

       link_port = 15112
       link_next = 192.168.1.XXX:15112

   * `link_port`: this cabinet listens here for the cabinet before it in the
     ring. Leave it at 15112 unless something else uses that port.
   * `link_next`: replace `192.168.1.XXX` with the IP address of the **next**
     cabinet, and give that cabinet's `link_port`. The cabinets form a ring:
     with two, each one's next is the other. Use an IP address, not a name.

   The names and defaults are the recomp's (its launcher's Game tab), so a
   MiSTer and a PC set up the same way.
3. Choose how `m2link` runs. Either:
   * **from the Scripts menu**: **Scripts > m2link** starts it; running it
     again stops it. Do this before a linked race; or
   * **at every boot**: add this line to `/media/fat/linux/user-startup.sh`
     and reboot once:

         /media/fat/linux/m2link -c /media/fat/linux/m2link.ini > /tmp/m2link.log 2>&1 &

     `m2link` then waits quietly. It links when Daytona is loaded with Link
     board On, drops the link when you switch it Off or load another core,
     and never touches anything while another core is running.
4. Load **Daytona USA (Revision A)**, open the OSD and set **Link board** to **On**.
5. Test mode (F2, or your mapped Test button) > **GAME SYSTEM**: set **LINK ID**
   to **MASTER** on one cabinet and **SLAVE** on all the others, and give each
   cabinet a different **CAR NUMBER**. Exit test mode (that's saved).

Master, slave and car number are never in the INI: like the arcade and the
recomp, the game decides them from its own settings (step 5).

**Starting a linked race:**

1. **Start the MASTER cabinet first**: load Daytona on it (and start `m2link`
   on it, if it is a MiSTer that doesn't start it at boot).
2. **Then start each SLAVE**, the same way.
3. Each says **NETWORK CHECKING** until every cabinet is there, then the
   linked attract (通信システム). Insert coins and race.

**If a cabinet drops out, or shows CANCELLED:** bring the **master** back up
first (reset Daytona on it, and restart `m2link` on it if you stopped it),
**then** reset each slave. A link that is lost does not come back by itself.

**Reading `/tmp/m2link.log`** (over ssh, or `cat` from a terminal) tells you
what `m2link` is doing:

* `waiting for the Model 2 core with Link board On in its OSD` — load
  Daytona, Link board On.
* `on (the game has not started the link: set LINK ID in test mode)` — LINK
  ID is SINGLE: set MASTER or SLAVE.
* `waiting: next cabinet ... not reached yet` — that cabinet isn't up, its
  `link_port` is different, or a firewall is in the way. `... no cabinet has
  connected to port ...` — the cabinet *before* this one hasn't reached it.
* `link_next is still the example's placeholder` — step 2.
* `linked: cabinet 1 of 2` — working.
* `lost (reset the game to try again)` — see above.

**Keeping the cabinets in step: `link_framesync`.** By default (0, as on the
recomp) each cabinet runs at its own pace and takes the others' cars as they
come; over a long race the cabinets slowly drift apart, exactly as the recomp
does. Set `link_framesync = 1` on **every** cabinet — in each MiSTer's
`m2link.ini`, and on each PC by ticking **Frame sync (every cabinet waits for
the master)** in the recomp's Game tab — and every cabinet waits each frame
for the master, so they stay together. A MiSTer then holds its game for the
moment it waits (picture and sound carry on).

**Example: a MiSTer and a PC.** MiSTer at 192.168.1.62, PC at 192.168.1.20.

* MiSTer `m2link.ini`: `link_port = 15112`, `link_next = 192.168.1.20:15112`.
* PC (recomp launcher, Game tab): **Link to other cabinets** ticked, **This
  cabinet's port** 15112, **Next cabinet** `192.168.1.62:15112`.
* One of them MASTER in test mode, the other SLAVE, different car numbers.
  Start the master first.

Three or more: each cabinet's `link_next` is the next one round the circle,
and the last one's is the first.

**Not linking at all?** A cabinet set to TWIN in test mode with nobody to link
to waits at NETWORK CHECKING for ever — the factory setting does this, with or
without the link board. For one player, set LINK ID to SINGLE. Link board Off
in the OSD is exactly the core without link play.

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
