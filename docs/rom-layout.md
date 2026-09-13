# ROM download layout

**The contract between the `.mra` and the core's ROM loader.** The MRA
concatenates ROM files into one stream and the HPS sends it over `ioctl`; the
loader writes it to memory. If the two disagree the core sees garbage, and the
symptom is a black screen with nothing to point at — so the layout is written
down before either side is built.

Derived from MAME 0.289 `model2.cpp`, `ROM_START(daytona93)`.

## Size, and the SDRAM requirement it sets

| Region | Size | What |
|---|---|---|
| `maincpu` | 0.25 MB | i960 program |
| `main_data` | 10.00 MB | i960 data |
| `copro_data` | 4.00 MB | TGP collision / height maps |
| `polygons` | 13.00 MB | Models |
| `textures` | 8.00 MB | Textures |
| `cpu3` | 0.12 MB | Comms |
| 68000 audio | 0.25 MB | Sound program |
| MPCM samples | 8.00 MB | Samples |
| **total** | **43.62 MB** | |

**43.62 MB is a hard requirement on the SDRAM module, and it is the first storage
figure this project has recorded** — the design study tracks ALM and M10K and has
never tracked ROM.

| Board | Fits? |
|---|---|
| 32 MB | **No.** Short by 11.6 MB |
| 64 MB | Yes, 20 MB spare |
| **128 MB** | Yes, 84 MB spare — the development target |

**MEASURED (study R19): the controller addresses 64 MB on this board** — ten
column bits work, eleven alias, so the part presents 1024 columns. The 43.62 MB
set fits in 64 MB with 20 MB spare, the whole thing lives in SDRAM, and **no DDR3
split is needed.** That is worth stating as a decision rather than a convenience,
because it removes a real design problem: every consumer gets uniform,
predictable latency, and the renderer does not need a DDR3 path or the burst
scheduling that would go with one.

**It also sets the core's minimum.** A 32 MB board cannot run this at all, and
that is a fact about the ROM set rather than about our implementation — it would
be true of any Model 2 core. It should appear in the README before anyone spends
an evening on a black screen. 64 MB fits, but with 20 MB spare it leaves nothing
for a frame buffer in SDRAM should that ever be wanted; **128 MB is the
recommended target.**

DDR3 remains available (1 GB via `DDRAM_*`) and is not needed for ROM. The
framebuffer question is separate and still open — see the study's note that a
496x384 16-bit buffer is 3.0 Mbit, or 298 M10K, which is the one resource question
the area budget leaves unanswered.

## Interleaving

Almost every region is `ROM_LOAD32_WORD` pairs: two chips supplying alternating
16-bit halves of a 32-bit word. In the MRA that is

```xml
<interleave output="32">
  <part name="low"  map="0021"/>
  <part name="high" map="2100"/>
</interleave>
```

`map` names one input byte per output byte, MSB first, 1-based, `0` meaning zero.
So `0021` puts the part's two bytes in output bytes 1 and 0 (the low word) and
`2100` puts them in bytes 3 and 2 (the high word).

**The i960 is little-endian and fetches 32-bit words**, so getting this pair the
wrong way round produces code that disassembles as plausible nonsense rather than
failing loudly. It is worth checking against a known instruction at reset before
trusting anything downstream.

## `ROM_COPY` mirrors are the core's job, not the MRA's

`daytona93` mirrors `main_data` `0x900000` into `0xa00000` through `0xf00000` —
six copies. An MRA *could* repeat the part six times, but that ships 6 MB of
duplicate data over `ioctl` on every boot for no reason. **The core decodes the
mirror in its address map instead.** Recorded here because a loader written from
the MRA alone would not know the mirror exists.

## Status

**The MRA in `mra/` is written to this layout and neither side is verified.** The
loader does not exist yet (P1.5 step 3). Until it does, this file is a design
document, not a description of working behaviour.

**Packaging note:** MiSTer's MRA flow reads `.zip`. The set to hand here is
`daytona93.7z`, which must be repacked as `daytona93.zip` — the MRA names it that
way. The bytes never enter this repository either way.


---

## The 2D test blob (P1.5 step 5)

There is no CPU in the P1.5 slice, so nothing writes the tilemap and the screen is
black however good the fetcher is. The oracle is a **captured tilemap state**,
dumped out of MAME at a known frame:

```
M2_FRAME=2300 M2_OUT=<dir> mame daytona93 -rompath ... \
  -sound none -video none -nothrottle -skip_gameinfo \
  -autoboot_script tools/mame_m2_tiledump.lua
```

It reads three regions from `model2.cpp`'s map and writes them little-endian:

| i960 address | size | file | blob offset |
|---|---|---|---|
| `0x01000000` | 0x10000 | `tile.bin` | `0x000000` |
| `0x01800000` | 0x04000 | `palette.bin` | `0x010000` |
| `0x01080000` | 0x80000 | `char.bin` | `0x014000` |

Concatenated that is **0x94000, 592 KB** — comfortably inside the 32 MB this
controller addresses, unlike the full 43.62 MB game set. `mra/Model2 2D Tilemap
Test.mra` loads it.

**Verified to contain real content before being trusted**: 39.7% of the tile RAM,
55.9% of the char RAM and 38.6% of the palette are bytes other than `00` or `FF`.
A dump of an empty tilemap would have looked like a working pipeline producing a
black screen.

**`m2tiles.bin` is ROM-derived and never enters this repository.** The `.mra` and
the extractor do; the bytes do not.

---

# Adding the other Model 2 games

**Status: attempted once (R299), withdrawn (R306). Read this before trying
again — the work is done and the reason it failed is a tooling gap, not a
design problem.**

The layout, both new MRAs and the constant shift are preserved in commit
**`6aa5de8`**. Nothing below needs re-deriving.

## Fix this first, or do not start

`tools/rom_csum.py` **cannot see padding.** Its element walk is:

```python
elif ch.tag == 'part' and ch.get('name'):
```

so `<part repeat="N">FF</part>` is skipped silently. Every game but Daytona
needs padding, so the project's only MRA verifier — the one built *because* of
R203's 64 KB gap — is blind to the exact construct multi-game depends on. R299
went to the board verified by a throwaway script written in the same session,
which is not verification. Teach `rom_csum.py` to fold `repeat` first, then
re-land `6aa5de8` and let the tool check it.

## What Model 1 does, and it is less than you would expect

`tools/model1-ref/mra/` ships **ten MRAs for six games on one bitstream**. The
mechanism is only two things:

* **Fixed stream offsets for every game, gaps padded** — `<part
  repeat="262144">FF</part>`. `FF`, because unwritten memory reads `0xFFFF` on
  this board.
* **A game ID ahead of index 0** — `<rom index="4"><part>00 00</part></rom>`,
  and its comment says why: *"six titles share one bitstream and they do not
  agree about the input map, so the core has to be told."* **That is the only
  per-game datum.** Nothing else in that core is game-aware.

So multi-game here is an MRA-and-constants job, not a core redesign.

## Region sizes, measured from MAME 0.289 `model2.cpp`

| region | daytona93 | desert | vcopa | slot needed |
|---|---|---|---|---|
| **i960 program** | **0x040000** | **0x080000** | **0x080000** | **0x080000** |
| i960 data | 0xa00000 | 0x900000 | 0x900000 | 0xa00000 |
| copro data | 0x400000 | 0x100000 | none | 0x400000 |
| polygons | 0xd00000 | 0x800000 | 0x400000 | 0xd00000 |
| textures | 0x800000 | 0x400000 | 0x400000 | 0x800000 |
| 68000 sound | 0x040000 | 0x020000 | 0x040000 | 0x040000 |
| MPCM samples | 0x800000 | 0x600000 | 0x600000 | 0x800000 |

**Daytona is the largest in every region except the i960 program**, where it
loads two ROMs and the other two load four. So only the program slot grows,
0x40000 → 0x80000, Daytona pads the difference, and every later region shifts up
0x40000 bytes. Total 43.62 MB → 46.1 MB.

Five word constants move (`Model2.sv`), and nothing else:

```
GAME_DATA    0x0020000 -> 0x0040000     byte 0x40000   -> 0x80000
GAME_COPRO   0x0520000 -> 0x0540000     byte 0xa40000  -> 0xa80000
GAME_TEX     0x0720000 -> 0x0740000     byte 0xe40000  -> 0xe80000
GAME_POLY    0x0b20000 -> 0x0b40000     byte 0x1640000 -> 0x1680000
GAME_TGPTBL  0x15d0000 -> 0x15f0000     byte 0x2ba0000 -> 0x2be0000
```

`snd_base` needs **no** change and that is not luck: it is discovered by scanning
`SND_SCAN_LO..HI` for the sound ROM's signature, so it follows the layout by
itself. `GAME_WORK` and everything above it is RAM beyond the stream; the
shifted stream ends at word 0x1610000 against `GAME_WORK` at 0x1620000, leaving
128 KB. `sim/io/tb_m2_boot.cpp` hardcodes the texture and TGP-table bases and
must move with them.

## Two traps in the ROM sets

* **Desert Tank's socket suffixes are swapped against MAME.** The available set
  names `mpr-16964.21` / `mpr-16965.20` where MAME says `.20` / `.21`. Match by
  **CRC** — that is the ROM's identity; the suffix is only which socket it sat
  in. All 22 CRCs verify against MAME 0.289.
* **Pad `ROMREGION_ERASE00` regions with `00`, not `FF`.** Virtua Cop's copro
  data and both games' comms regions are declared `ERASE00` in MAME, so the
  hardware model says they read zero. `FF` is right for an unpopulated socket,
  wrong for these.

## Assets

ROMs are **never** committed. `vcopa.zip` and `desert.zip` live in
`~/roms/Model2/` and were copied to `/media/fat/games/mame/` on the board.
`model1io.zip` is absent but harmless — the MRAs declare
`zip="model1io.zip|daytona93.zip"` and fall back.

## What actually happened on the board

Deployed with its matched MRA (MD5-checked both sides), R299 gave garbage:

```
tgp  : 00A9:48671        parked at 0x00A9, not the 0x030B idle loop
SDRAM: bus busy 84.1%    geometry waiting 84.1% -- hammering, not starved
WALK: walks started 1    the display list ran once
LIGHT TABLE: 0 of 32     the CPU never got going
```

A TGP stuck at an abnormal microcode address while the geometry spins the bus is
what reading nonsense as a display list looks like. Every constant above was
re-checked against the MRA and agrees, and `m2_rom_loader` writes the stream
linearly ("deliberately no per-region base-address arithmetic here"), so the
mapping *should* hold. **It does not, and nobody knows why yet** — which is
exactly why `rom_csum.py` has to be able to check the image before this is tried
again.

## Do it on its own

R299 was not needed by anything — not the clock work, not the M10K work, not the
texel cache. It landed on a day with five other changes and cost a board cycle
the speed work needed. Multi-game is a clean, self-contained project for a day
when the renderer is not mid-surgery.
