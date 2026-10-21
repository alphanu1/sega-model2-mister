# Sega Model 2 — releases

## What to copy

| file | where it goes on the SD card |
|---|---|
| `Model2_20261021.rbf` | `/media/fat/_Arcade/cores/`, then **rename it to `Model2.rbf`** |
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

## ROMs

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

**Check you're running the right file.** `Model2_20261021.rbf` has the md5 `44c8e69e194f1555ea73f1ef699bb553`.
If yours doesn't match, the usual reason is a second core file in `cores/`.
MiSTer picks the name that sorts last, and `_` sorts after `.`, so a spare
`Model2_old.rbf` quietly wins over `Model2.rbf`. Keep exactly one, and keep
any backups out of `cores/`.

**SDRAM:** the core needs a 64 MB or larger module. The 3D is drawn into the
DE10-Nano's own DDR3, so nothing else is needed for that.

## What works

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

## New in this release

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

### Earlier releases

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

## OSD settings

| setting | what it does |
|---|---|
| `Aspect ratio` | as on other MiSTer cores |
| `Video` | `Native 24kHz`, or `15kHz interlaced` for a CRT. With a `[15kHz CRT]` MRA it reads `15kHz (CRT MRA)` and can't be changed. |
| `15kHz lines` | `273/274 (15.7kHz)` (default), `268/269 (15.4kHz)` or `262/263 (15.1kHz)` — see the CRT section |
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

## Controls

### Daytona USA

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

### Desert Tank

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

### Virtua Cop

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

## Link play: Daytona USA, cabinet against cabinet

<!-- DRAFT for the release that carries link play (study R916). Not in the
20261021 core. -->

Daytona USA (Revision A, the 1994 set) can race other cabinets over your
network, wired or Wi-Fi, like linked arcade machines: two MiSTers, or a
MiSTer and a PC running the
[Daytona USA recompilation](https://github.com/alphanu1/daytona-arcade-recomp),
or more of either. They speak the same protocol, so any mix works.

The MiSTer's network is on its Linux side, so a small program, `m2link`,
carries the link; the core just needs its link board switched on.

**Once, on each MiSTer:**

1. Copy `m2link` to `/media/fat/linux/` and `m2link.sh` to `/media/fat/Scripts/`.
2. Copy `m2link.ini` to `/media/fat/linux/` and set the two lines in it (below).
3. Load Daytona USA (Revision A), open the OSD and set **Link board** to **On**.
4. Test mode (F2, or your mapped Test button) > **GAME SYSTEM**: set **LINK ID**
   to **MASTER** on one cabinet and **SLAVE** on all the others, and give each
   cabinet a different **CAR NUMBER**. Exit test mode (that's saved).
5. Run `m2link` from the MiSTer menu: **Scripts > m2link**. Run it again to stop it.

**`/media/fat/linux/m2link.ini`** holds only the network. The names and
defaults are the recomp's (its launcher's Game tab, saved in its `launcher.ini`):

    link_port = 15112
    link_next = 192.168.1.20:15112

* `link_port`: this cabinet listens here for the cabinet before it in the
  ring. 15112 is fine unless something else uses it.
* `link_next`: the IP address and `link_port` of the next cabinet. The
  cabinets form a ring; with two, each one's next is the other. Use an IP
  address, not a name.
* `link_framesync`: leave it out, or 0. (Advanced; a MiSTer can't hold its
  game to another cabinet's frame, so it changes nothing here.)

Master, slave and car number are never in this file: like the arcade and the
recomp, the game decides them from its own settings (step 4).

**Example: a MiSTer and a PC.** MiSTer at 192.168.1.62, PC at 192.168.1.20.

* MiSTer `m2link.ini`: `link_port = 15112`, `link_next = 192.168.1.20:15112`.
* PC (recomp launcher, Game tab): **Link to other cabinets** ticked, **This
  cabinet's port** 15112, **Next cabinet** `192.168.1.62:15112`.
* One of them MASTER in test mode, the other SLAVE, different car numbers.

Three or more: each cabinet's `link_next` is the next one round the circle,
and the last one's is the first.

**What you'll see.** The game says **NETWORK CHECKING** until every cabinet is
there, then the linked attract (通信システム). `m2link` reports what it is
doing in `/tmp/m2link.log`: `waiting: next cabinet ... not reached yet` (that
cabinet isn't listening, or a firewall is in the way), `linked: cabinet 1 of
2`, or `lost` (a cabinet went away: reset the game on every cabinet to link
again).

**Start it at boot instead:** add this line to `/media/fat/linux/user-startup.sh`:

    /media/fat/linux/m2link -c /media/fat/linux/m2link.ini > /tmp/m2link.log 2>&1 &

It does nothing until Daytona is loaded with Link board On, and stops touching
anything as soon as another core is.

**Not linking?** A cabinet set to TWIN in test mode with nobody to link to
waits at NETWORK CHECKING for ever — the factory setting does this, with or
without the link board. For one player, set LINK ID to SINGLE. Link board Off
in the OSD is exactly the core without link play.

## On a 15 kHz CRT

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

- **Reports from CRT, wheel and light-gun owners** (see above), and from
  anyone running the Deluxe '93 set for long stretches.
- **CRT light guns** (GunCon on MiSTer's SNAC port) are noted for later,
  not being worked on now.

If you find something wrong, please report it.

## Credits

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
