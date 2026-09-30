# Sega Model 2 — releases

Copy to the SD card:

| from | to |
|---|---|
| `Model2_20260930b.rbf` | `/media/fat/_Arcade/cores/` — **rename to `Model2.rbf` on the card** |
| `Daytona USA (Deluxe 93).mra` | `/media/fat/_Arcade/` |

**One core, deliberately.** If you need an older build, it is in the git
history of this repository.

ROMs are supplied by you and must be in `/media/fat/games/mame/` as the MRA
names them. Nothing here contains ROM data.

## ROMs you need

| zip | what for |
|---|---|
| `daytona93.zip` | the game itself — program, data, polygons, textures, tiles, samples |
| `model1io.zip` **or** `daytona93.zip` | the I/O board's Z80 ROM, `epr-14869c.25` |

The I/O board ROM is searched for in **both** zips, so whichever of the two your
ROM set puts it in will be found. **Without it the core has no controls** — the
I/O board is what the game reads coins, start and steering through, so a missing
`epr-14869c.25` looks like a machine that runs and ignores you.

The TGP coprocessor's microcode needs no separate download. It lives inside the
game's own data ROM and the core extracts it.

**Check what you are running.** `Model2_20260930b.rbf` is
`7c5daa8ad47e183ac7d2139c70695798`, 4,620,548 bytes. If the core on your card
does not have that md5, you are not running this build — and the usual reason is
a second file: MiSTer keeps the lexicographically greatest name beginning
`Model2` followed by `.` or `_`, and `_` sorts after `.`, so a spare
`Model2_old.rbf` in `cores/` silently wins over `Model2.rbf`. Keep exactly one,
and keep fallbacks out of `cores/` entirely.

**SDRAM:** the core addresses **64 MB**, so it needs a 64 MB or larger module.
The 3D is drawn into the DE10-Nano's own DDR3; nothing extra is needed for that.

## What this build does

**Daytona USA boots and runs its attract mode with the 3D on screen** —
textured, lit polygons over the 2D layers, with sound.

- **The whole board is in the FPGA:** the i960 main CPU, the TGP geometry
  coprocessor and its microcode, the geometrizer, a hardware 3D renderer, the
  2D tilemap layers, the I/O board, and the sound board — its own 68000, the
  YM3438 and both MultiPCMs.
- **The 3D is drawn into a DDR3 framebuffer** and shown only when a frame is
  complete, so there is no tearing and no half-drawn picture.
- **Polygons are drawn front to back, as the real board draws them.** Texture
  reads are skipped for pixels something nearer has already covered, which
  in simulation makes the 3D draw 15-36% faster than drawing back to front.
- **Road and scenery textures** land in the right place: the bridge, the road
  pieces, and the banked corners, which are now drawn as two triangles so they
  no longer twist.
- **Polygon edges use pixel-centre coverage**, which removed the streaks and
  overlaps along the seams.
- **Sound runs at the right speed.**

## OSD settings

| setting | what it does |
|---|---|
| `Video` | `Native 24kHz`, or `15kHz interlaced` for a CRT (57.5 Hz fields of 192 lines). The 15 kHz mode works on a real CRT; **this build fixes its field timing, not yet confirmed on a CRT** — see below. |
| `Aspect ratio` | as MiSTer's other cores. |
| `Textures` | `On`, or `Off` to draw every polygon flat. |
| `Texture filter` | `Bilinear` or `Point`. |
| `Texel step` | how many pixels share one texture read. `1` is the most detailed. |
| `Texture brightness` | brightness of textured polygons. |
| `Draw method` | **`Single buffered` (the default)**: the 3D is drawn every second frame and the game runs **at up to arcade speed** — full speed in most scenes, dipping in the heaviest. `Double Buffered` draws every frame the core can, and the whole game slows to about 30 frames a second. `Every 3rd frame` draws one in three. |
| `3D pacing` | `Hold game` keeps the game in step with the 3D, as an overloaded arcade board slows down; `Free` lets the game run ahead of the picture. |
| `Gamma` | `Off`, `MAME` or `Mild`. Applies to 2D and 3D together. |
| `Pedals` | swaps throttle and brake on the right stick — axis direction differs between pads. |
| `Steering` | how much stick gives full lock: `3/4`, `Full`, `5/4` or `Half`. |
| `Save settings (NVRAM)` | writes the game's backup memory to the SD card. |

## Controls

| | |
|---|---|
| Steer | left stick |
| Accelerate / brake | right stick up / down, or the `Accel` and `Brake` buttons |
| Gears | `Gear Up` / `Gear Down` |
| View buttons | `VR1 Red`, `VR2 Blue`, `VR3 Yellow`, `VR4 Green` |
| Start, Coin | `Start`, `Coin` |
| Test, Service | available to map in MiSTer's input settings |

## Not finished, as of `Model2_20260930b.rbf`

This list describes the RBF named above. **The heading carries the RBF's name so
that if the two disagree, you trust neither and check.**

- **Not quite full speed yet.** With `Draw method: Single buffered` (the
  default) the game averages about 50 frames a second of the arcade's 57.5,
  measured over two minutes of attract on hardware: full speed in three
  frames out of four, down to about 38 in the heaviest scenes. The limit is the geometry stage, which is being
  worked on. `Double Buffered` runs at about half speed.
- **15 kHz interlaced: fixed in this build, not yet confirmed on a CRT.** The
  previous build had four faults on a real set — a large border at the top,
  the picture dropping out every few seconds, the top 2D layer's scanlines
  misaligned, and no real interlacing (192 lines rather than 384 interleaved).
  They trace to the two fields being different lengths and the vertical sync
  sitting too early; this build makes the fields equal and centres the
  picture. Reports from CRT owners are welcome.
- **Car windows drop out.** After a few minutes of attract the glass or its sky
  reflection can disappear from some cars, so you see into the car.
- **Some textures flicker** on trees and hillsides.
- **No mip-mapping**, so distant textures shimmer.
- **Attract mode is what this build has been checked against.** Play it and
  report what you find.

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
