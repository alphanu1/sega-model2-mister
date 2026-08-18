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

**Development is on a 128 MB board, so the whole set lives in SDRAM and no DDR3
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
