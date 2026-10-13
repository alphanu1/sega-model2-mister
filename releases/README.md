# Sega Model 2 — releases

## What to copy

| file | where it goes on the SD card |
|---|---|
| `NEXT_RBF` | `/media/fat/_Arcade/cores/`, then **rename it to `Model2.rbf`** |
| `Daytona USA (Revision A).mra` | `/media/fat/_Arcade/` — the 1994 version |
| `Daytona USA (Deluxe 93).mra` | `/media/fat/_Arcade/` |
| `Daytona USA (Revision A) [15kHz CRT].mra` | `/media/fat/_Arcade/` — starts in 15 kHz, for a CRT |
| `Daytona USA (Deluxe 93) [15kHz CRT].mra` | `/media/fat/_Arcade/` — starts in 15 kHz, for a CRT |

There's only ever one core here. Older builds are in this repository's git
history if you need one.

You supply the ROMs. They go in `/media/fat/games/mame/`, named the way the
MRA expects. Nothing in this folder contains ROM data.

## ROMs

| zip | for |
|---|---|
| `daytona.zip` | Daytona USA (Revision A), MAME's `daytona` set |
| `daytona93.zip` | Daytona USA (Deluxe '93). With a split set you also need `daytona.zip` next to it, because the two share files. A merged `daytona.zip` on its own works too. |
| `model1io.zip`, or inside the game's zip | the I/O board's Z80 ROM, `epr-14869c.25` |

The I/O board ROM is looked for in `model1io.zip` and in the game's own zip,
so it will be found wherever your set keeps it. Without it you get no
controls at all: the game reads coins, start and steering through the I/O
board, so a missing `epr-14869c.25` looks like a machine that runs and
ignores you.

The TGP coprocessor's microcode is not a separate download. It sits inside
the game's data ROM and the core pulls it out.

**Check you're running the right file.** `NEXT_RBF` has the md5 `NEXT_MD5`.
If yours doesn't match, the usual reason is a second core file in `cores/`.
MiSTer picks the name that sorts last, and `_` sorts after `.`, so a spare
`Model2_old.rbf` quietly wins over `Model2.rbf`. Keep exactly one, and keep
any backups out of `cores/`.

**SDRAM:** the core needs a 64 MB or larger module. The 3D is drawn into the
DE10-Nano's own DDR3, so nothing else is needed for that.

## What works

Daytona USA runs at the arcade's speed, with textured, lit 3D over the 2D
layers and full sound. Both versions, Revision A and Deluxe '93, are
supported.

| | frames a second (the arcade runs at 57.5) |
|---|---|
| Attract mode | 57 |
| A race | 57 — 99% of frames on time, with no slowdown seen in testing |

The whole arcade board is in the FPGA: the i960 main CPU, the TGP geometry
coprocessor running the game's own microcode, the geometrizer, a hardware 3D
renderer drawing front to back like the real board, the 2D tile layers, the
I/O board, and the sound board with its own 68000, YM3438 and MultiPCM sample
chips. The 3D goes into a framebuffer and is only shown when a frame is
finished, so there's no tearing.

## New in this release

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
- **A shorter menu.** Texel step, 3D pacing, Texture brightness and Draw
  method's "every 3rd frame" are gone. They're fixed at the settings that work
  best now the core runs at full speed.
- **Room to grow.** Several parts were made smaller, including both sound
  chips now sharing one engine. That freed space on the FPGA for what comes
  next.

### Earlier releases

**20261013:** races at full speed, from a faster main CPU (8 KB instruction
cache and better instruction fetching). Steering wheel support. Split and
merged ROM sets for Deluxe '93. An 11-hour soak without a lock.

**20261011:** the random lock-up after 20 to 60 minutes was fixed, and races
went from mostly 30 to mostly 57 frames a second. Also: the 3D no longer goes
black; car windows stay; textures take the arcade's colours; the near road
stopped juddering; the car-select tyres came back; ROLLING START scrolls; the
mini-map and condition panel sit in the right place; no black band above the
sky; the "G" of GAME OVER is back; and 15 kHz CRT support with its own MRAs.

## OSD settings

| setting | what it does |
|---|---|
| `Aspect ratio` | as on other MiSTer cores |
| `Video` | `Native 24kHz`, or `15kHz interlaced` for a CRT. With a `[15kHz CRT]` MRA it reads `15kHz (CRT MRA)` and can't be changed. |
| `15kHz lines` | `262/263 (15.1kHz)` (default) or `273/274 (15.7kHz)` — see the CRT section |
| `Textures` | `On`, or `Off` to draw every polygon flat |
| `Texture filter` | `Bilinear` (default) or `Point` |
| `Draw method` | `Double Buffered` (default) draws every frame; `Single buffered` draws every other one |
| `Gamma` | `MAME` (default), `Off` or `Mild`. Affects 2D and 3D together. |
| `Volume` | 80% by default, in 10% steps; goes from 100% round to 0% |
| `Pedals` | swaps accelerator and brake if your controller has them the other way round |
| `Steering` | how much stick gives full lock: `3/4` (default), `Full`, `5/4` or `Half` |
| `Steering smoothing` | `Off` (default), `Light` or `Wheel` — see above |
| `Right stick` | `Pedals only` (default), or `Pedals+steer`: left/right steers as well, for a wheel |
| `Save settings (NVRAM)` | writes the game's own settings and records to the SD card |

## Controls

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

## On a 15 kHz CRT

The game's own picture is 24 kHz, which a 15 kHz TV can't show. The core has a
15 kHz interlaced mode that shows all 384 lines as two fields, at the game's
own speed.

The easy way is to **load the `[15kHz CRT]` version** of the game from the
MiSTer menu. It starts in 15 kHz straight away. With a normal MRA, set
`Video` to `15kHz interlaced`.

`15kHz lines` starts at `262/263`, NTSC's line count, which keeps most TVs
locked. If your set prefers it, `273/274` keeps the standard line rate
instead.

It's been tested on real CRTs, but more reports are very welcome: which TV,
how it's connected, and which settings work for you.

## MiSTer's audio filter is switched off

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

## Still to come

- **Mip-mapping.** Distant textures shimmer because they're always read at
  full size. A version that fixes it is being tuned so the near road stays
  sharp.
- **Reports from CRT and wheel owners** (see above), and from anyone running
  the Deluxe '93 set for long stretches.
- **Virtua Cop** needs a different I/O board (light guns and an LCD), so it
  will be its own core.

If you find something wrong, please report it.

## Credits

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
