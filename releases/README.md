# Sega Model 2 — releases

Copy to the SD card:

| from | to |
|---|---|
| `Model2_20261011.rbf` | `/media/fat/_Arcade/cores/` — **rename to `Model2.rbf` on the card** |
| `Daytona USA (Deluxe 93).mra` | `/media/fat/_Arcade/` |
| `Daytona USA (Revision A).mra` | `/media/fat/_Arcade/` — the 1994 revision |
| `Daytona USA (Deluxe 93) [15kHz CRT].mra` | `/media/fat/_Arcade/` — **new**: starts in 15 kHz, for a CRT |
| `Daytona USA (Revision A) [15kHz CRT].mra` | `/media/fat/_Arcade/` — **new**: starts in 15 kHz, for a CRT |

**One core, deliberately.** If you need an older build, it is in the git
history of this repository.

ROMs are supplied by you and must be in `/media/fat/games/mame/` as the MRA
names them. Nothing here contains ROM data.

## ROMs you need

| zip | what for |
|---|---|
| `daytona93.zip` | `Daytona USA (Deluxe 93)` — program, data, polygons, textures, tiles, samples |
| `daytona.zip` | `Daytona USA (Revision A)`, the 1994 set (MAME's `daytona`) — the whole set |
| `model1io.zip` **or** the game's zip | the I/O board's Z80 ROM, `epr-14869c.25` |

The I/O board ROM is searched for in `model1io.zip` **and** the game's own zip, so whichever of the two your
ROM set puts it in will be found. **Without it the core has no controls** — the
I/O board is what the game reads coins, start and steering through, so a missing
`epr-14869c.25` looks like a machine that runs and ignores you.

The TGP coprocessor's microcode needs no separate download. It lives inside the
game's own data ROM and the core extracts it.

**Check what you are running.** `Model2_20261011.rbf` is
`232ce65807684c4b676d584b133ea385`, 4,637,380 bytes. If the core on your card
does not have that md5, you are not running this build — and the usual reason is
a second file: MiSTer keeps the lexicographically greatest name beginning
`Model2` followed by `.` or `_`, and `_` sorts after `.`, so a spare
`Model2_old.rbf` in `cores/` silently wins over `Model2.rbf`. Keep exactly one,
and keep fallbacks out of `cores/` entirely.

**SDRAM:** the core addresses **64 MB**, so it needs a 64 MB or larger module.
The 3D is drawn into the DE10-Nano's own DDR3; nothing extra is needed for that.

## What this build does

**Daytona USA runs at close to arcade speed, with the 3D on screen** —
textured, lit polygons over the 2D layers, with sound.

**Speed, measured on a DE10-Nano with `Draw method` on `Double Buffered`
(the default) and `Texel step` on `1`:**

| | frames a second (the arcade runs at 57.5) |
|---|---|
| Attract mode | **57**, solid |
| In a race | **57 for 80-90% of the time**, dipping in the busiest moments |

The last release ran races at about 29.

- **The whole board is in the FPGA:** the i960 main CPU, the TGP geometry
  coprocessor and its microcode, the geometrizer, a hardware 3D renderer, the
  2D tilemap layers, the I/O board, and the sound board — its own 68000, the
  YM3438 and both MultiPCMs.
- **The 3D is drawn into a DDR3 framebuffer** and shown only when a frame is
  complete, so there is no tearing and no half-drawn picture.
- **Polygons are drawn front to back, as the real board draws them**, and
  texture reads are skipped for pixels something nearer already covers.

**New since `Model2_20261008b`:**

- **Much faster races.** The core runs at a higher clock. The geometry
  coprocessor does the same work in less than half the time. Texture reads
  miss less often and can wait on four misses at once. The step that writes
  the 3D into the framebuffer used to take only half a pixel a clock; it now
  takes a whole one. That last fix alone took races from mostly 30 to mostly
  full speed.
- **The random lock-up is fixed.** After 20-60 minutes, usually in attract,
  the 3D could freeze for good. The main CPU was sometimes handed the wrong
  instruction when a delayed memory answer arrived at the wrong moment.
  Revision A has since run 2.5 hours of attract without a lock.
- **The 3D no longer goes black** after a while in attract.
- **Car windows stay**: the glass and its sky reflection no longer drop out
  after a few minutes.
- **Textures look like the arcade's.** Textured surfaces take their colour
  the way the real board does, so decals, windows and signs are no longer
  washed out or too dark.
- **The road close to the camera no longer judders or shakes** in motion.
- **The car-select tyres are back**, no longer missing or see-through.
- **ROLLING START scrolls across the screen**, and the mini-map, the
  condition panel and the rev needle are in the right place.
- **No black band above the sky** when driving uphill.
- **The right edge of the 3D** lines up with the 2D.
- **The "G" of GAME OVER is back.** The first polygon of a frame could be
  lost when the 3D was running a frame late, and on the results screen that
  polygon is the G.
- **15 kHz for CRTs**, with two new `[15kHz CRT]` MRAs that start the core in
  15 kHz. See below.
- **Defaults changed:** `Draw method` is now `Double Buffered`, and `Gamma`
  is now `MAME`.

## OSD settings

| setting | what it does |
|---|---|
| `Video` | `Native 24kHz`, or `15kHz interlaced` for a CRT. With a `[15kHz CRT]` MRA it shows `15kHz (CRT MRA)` and is fixed — see below. |
| `15kHz lines` | `262/263 (15.1kHz)` (the default) or `273/274 (15.7kHz)` — see below. |
| `Aspect ratio` | as MiSTer's other cores. |
| `Textures` | `On`, or `Off` to draw every polygon flat. |
| `Texture filter` | `Bilinear` or `Point`. |
| `Texel step` | how many pixels share one texture read. `1` is the most detailed; `2`, `4` and `8` are faster and blurrier. |
| `Texture brightness` | brightness of textured polygons. |
| `Draw method` | **`Double Buffered` (the default)**: every frame is drawn, at the speeds above. `Single buffered` draws every second frame. `Every 3rd frame` draws one in three. |
| `3D pacing` | `Hold game` keeps the game in step with the 3D, as an overloaded arcade board slows down; `Free` lets the game run ahead of the picture. |
| `Gamma` | **`MAME` (the default)**, `Off` or `Mild`. Applies to 2D and 3D together. |
| `Pedals` | swaps throttle and brake on the right stick — axis direction differs between pads. |
| `Steering` | how much stick gives full lock: `3/4`, `Full`, `5/4` or `Half`. |
| `Save settings (NVRAM)` | writes the game's backup memory to the SD card. |

## MiSTer's audio filter is switched off

**This core turns off MiSTer's built-in audio filter.** The game's sound is unchanged: the same sound board, the same
mix and the same output on HDMI, the 3.5 mm jack and S/PDIF. What stops working
is MiSTer's own audio filter setting (the filter presets in the MiSTer menu and
`MiSTer.ini`). It has no effect on this core.

**Why.** The Model 2 board barely fits in the DE10-Nano's FPGA; it is about 99%
full. MiSTer's audio filter costs about 430 of the FPGA's logic blocks, and
that room now goes to the 3D renderer's texture fetching, which is what holds
races below full speed. Your MiSTer setup is not touched; this applies only
while the Model 2 core is running.

**It is not meant to be permanent.** If room in the FPGA can be freed up
elsewhere later, the audio filter will be switched back on.

**For anyone building the core:** this is one small, switchable change to the
MiSTer framework file `sys/audio_out.sv`. It is kept as a patch in
`docs/framework-patches/audio-filter-disable.patch`, explained in the README
beside it, and turned on by `MISTER_DISABLE_AUDIO_FILTER` in `Model2.qsf`. When
the framework is updated, re-apply the patch. If it no longer applies cleanly,
the README shows how to make the three-line change by hand.

## On a 15 kHz CRT

The game's own video is 24 kHz, which a 15 kHz TV cannot show. The core has
a 15 kHz interlaced mode for CRTs, at the game's own speed, with all 384
lines shown as two fields.

**Load the `[15kHz CRT]` version of the game** from the MiSTer menu, for
example `Daytona USA (Deluxe 93) [15kHz CRT].mra`. It starts the core in
15 kHz straight away, so you never need to see the 24 kHz picture. With the
normal MRA, set `Video` to `15kHz interlaced` in the OSD.

**`15kHz lines`** defaults to **262/263 (15.1kHz)**: fields of 262 and 263
lines, NTSC's count, at the game's own speed. That keeps most TVs locked and
the picture aligned. If yours prefers it, `273/274 (15.7kHz)` keeps the
standard line rate instead.

This has been tested and works on a real CRT. More reports are very welcome:
which TV, how it's connected, and which settings work.

## Controls

| | |
|---|---|
| Steer | left stick |
| Accelerate / brake | right stick up / down, or the `Accel` and `Brake` buttons |
| Gears | `Gear Up` / `Gear Down` |
| View buttons | `VR1 Red`, `VR2 Blue`, `VR3 Yellow`, `VR4 Green` |
| Start, Coin | `Start`, `Coin` |
| Test, Service | available to map in MiSTer's input settings |

## Not finished, as of `Model2_20261011.rbf`

This list describes the RBF named above. **The heading carries the RBF's name so
that if the two disagree, you trust neither and check.**

- **Races are not quite full speed all the time.** About 10-20% of the time,
  in the busiest moments, the frame rate dips. That is what is being worked
  on next.
- **Background music and the game-over speech are too quiet** against the
  rest of the sound.
- **No mip-mapping**, so distant textures shimmer.
- **Virtua Cop is not supported yet.** Its I/O board (light guns, an LCD) is
  a different one and is not in the core.
- **Play it and report what you find.**

## Credits

The framework is **MiSTer-devel**'s. The sound board's 68000 is **fx68k**, by
Jorge Cwik (ijor), and its YM3438 is **jt12**, by Jose Tejada (jotego). The
MultiPCM is from **[meathax](https://github.com/meathax)**'s
[s32](https://github.com/meathax/s32) System 32 project. The I/O board's Z80 is
**tv80**, by Guy Hutchison, after Daniel Wallner's T80. The TGP and the video
timing come from the Sega Model 1 core, which solved the same problems first on
the same part.

Hardware behaviour was verified throughout against **MAME**, whose Model 2
driver is by R. Belmont, Olivier Galibert, ElSemi, Angelo Salese and Matthew
Daniels, and whose i960 is by Farfetch'd and R. Belmont.

GPL-3.0-or-later. Full third-party detail and licences are in `THIRD_PARTY.md`
in the source repository.
