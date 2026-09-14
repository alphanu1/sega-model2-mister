# Area budget

**The core is full.** 41,132 of 41,910 ALM (98%), M10K reading 553/553, and the
FITTER is what keeps failing -- four builds in a row lost seeds to Quartus
internal errors rather than to anything in the RTL. Read this before adding
anything.

> **CORRECTION (R330): the fitter crashes are BATCH SIZE, not density.** A
> four-seed batch on this 31 GB machine is ~9 GB of fits plus whatever else is
> building, and one seed died with `Internal Error: dyn_enum.cpp, Line 186`
> while three finished -- at 40,861 ALM, LOWER than when this was written. Ben
> called it before the build finished: **three seeds at a time, maximum, and
> never two batches at once.** Attributing these crashes to density has been
> steering area decisions for nothing.

> **CORRECTION (R327/R328): two M10K figures below are wrong, both measured.**
> The span queue costs **5** blocks at `DEPTH(32)`, not the ~30 this document
> assumes -- which it flagged as unverified and which is now read from a fit
> report. R313 therefore halved the char cache (overruns 14 -> 53) to pay for
> something that costs five blocks. And the texel cache is **8** blocks at 1024
> lines, so doubling it costs 7, not the ~15 estimated.

Measured on `build/fifo2/s37` unless stated. Every figure here was READ from the
fit report, not derived -- three separate area decisions went wrong on the same
day from estimating instead.

---

## How to measure it, because guessing has cost us repeatedly

The fit report's hierarchy table lists parents AND children, so a naive
`grep | sum` triple-counts. This reads one named column per hierarchy path:

```sh
f=build/<name>/s<seed>/output_files/Model2.fit.rpt
awk -F';' '/Compilation Hierarchy Node/{
    for(i=1;i<=NF;i++){g=$i;gsub(/ /,"",g);
      if(g=="ALMsneeded[=A-B+C]")c=i;      # or "M10Ks", "DSPBlocks",
      if(g=="FullHierarchyName")h=i}       #    "ALMsusedformemory"
    next}
  NF>10&&c>0{v=$c;gsub(/ /,"",v);gsub(/\..*/,"",v);n=$h;gsub(/^ +| +$/,"",n);
    if(v ~ /^[0-9]+$/ && v+0>=40 && n!="") printf "%7s  %s\n", v, n}' $f \
 | sort -rn | head -20
```

A claim here that the char cache used 204 M10K and was "badly packed" came from
summing parent and child rows. It uses 68 against a ~55 theoretical minimum,
which is normal granularity, and there was never anything to reclaim.

---

## Where the ALM is

| block | ALM | note |
|---|---|---|
| `i960_top` | 7,717 | the CPU |
| `m2_geometry` | 6,388 | clipper 1,552, `geo_engine` 2,001 -- **no multiplies, all control logic** |
| `m2_raster3d` | 5,912 | `m2_raster_fill` 3,648, `m2_quad_store` 1,498 |
| `m2_sound_board` | 5,029 | `fx68k` 1,832 -- **stays in** |
| `m2_copro` | 2,612 | `m2_tgp` 2,538, `mb86233_core` 2,123 |
| framework (outside `emu`) | ~6,066 | `ascal` 1,942, `audio_out` 959, two `osd` 890, `pll_hdmi_adj` 418 |

## Where the M10K is

| block | M10K |
|---|---|
| `m2_quad_store` | 123 |
| `m2_sound_board` | 82 |
| `m2_char_cache` | 68 (at 8192 lines; 34 at 4096) |
| `m2_tdp_ram` | 64 |
| framework incl. `ascal` | ~50 |

**M10K only LOOKS exhausted.** It reads 553/553 in every build, including ones
where 30 blocks had just been released, because Quartus pushes logic into spare
block memory when ALM is tight. **ALM is the binding resource.** Reading 553/553
as "M10K is full" sent three sizing decisions the wrong way (R304, R307, and the
4096-line texel cache that would not fit at all).

## DSP: 63 used, 112 on the device, and nothing left to move

All multiplication is already in DSP:

* `m2_raster_fill` carries `(* multstyle = "dsp" *)` at MODULE level, covering
  all thirteen of its multiplies -- 28 blocks.
* The three `fp_mul` instances go through the shared `m2_fp_pool` -- 3 blocks.
* i960 7, tilemap 3, sound 1, copro 1.

`m2_geo_engine` and `m2_geo_clip` -- 3,553 ALM between them -- contain **no
multiplications at all**; every `*` in those files is in a comment. Their area
is state machines and control, which DSP cannot absorb. Adders do not benefit
(an ALM does two bits of add; a DSP block would be waste).

**So "push more to DSP" is exhausted.** The 49 free blocks have nothing to take.

---

## Things that do NOT work, so they are not retried

| idea | why not |
|---|---|
| char cache in MLAB | MLAB is built from ALM LUTs -- 640 bits each, ~10 ALM. 557,056 bits would be **~8,700 ALM**, the exact resource we lack. |
| more framework macros | Upstream `Template.qsf` and the MkDocs developer pages document **eight**, the same set as our `sys/`. Every applicable one is already set: `DOWNSCALE_NN`, `DISABLE_ADAPTIVE`, `DISABLE_YC`, `DISABLE_ALSA`, plus `M2_NO_OVERLAY`. |
| `MISTER_SMALL_VBUF` | Changes ascal's `RAMSIZE` only -- **DDR3, not FPGA**. No ALM or M10K saved. |
| `MISTER_DEBUG_NOHDMI` | Would free ~1,900 ALM and ~50 M10K, but removes the HDMI output the board is tested through. |
| removing unused framework modules | `arcade_video`, `video_mixer`, `hq2x`, `scandoubler` etc. are compiled but never instantiated, so Quartus prunes them. They cost nothing. |
| deleting disabled experiments | `WEDGE_EN`, `SWEEP_EN`, `WHOLE_TILE` are already pruned -- zero occurrences in the fit report. |

## Things that DO work

| lever | ALM | cost |
|---|---|---|
| char cache 8192 -> 4096 lines, span queue registers -> M10K (R313) | **~484** | glyph misses roughly double; the M10K queue's bubble returns |
| MLAB -> M10K via `ramstyle` on the small memories | **~650** | geometry 290, sound 280 currently in MLAB |
| debug stream out | ~360 + distributed counters | blinds the telemetry we navigate by |
| sound board out (development builds only) | 5,029 | no audio -- **rejected for normal use** |

---

## The rule that matters

**Pipelining is cheap. Sizing is expensive.**

* R301's `S_MINMAX` stage: **~50 ALM**. R305's char-cache split: the same order.
  The whole 100 MHz effort across five modules is ~250-500 ALM.
* What actually blew the budget in one day: a 4x texel cache (+30 M10K) and a
  256-entry span FIFO (+30 M10K). Both reverted.

So a change that adds a REGISTER STAGE is affordable and a change that adds a
BUFFER is not, and the two feel identical when proposed.

## The span queue is WIDTH-bound, not depth-bound

Already reduced: the texel cache is back to 512 lines and the span queue to
`DEPTH(32)` from 256. But **halving the depth may buy nothing**, because at 242
bits Quartus maps this queue narrow-and-deep -- roughly 1024x10 -- so each block
holds 1024 entries whether 32 or 256 are asked for. It cost 30 M10K at
DEPTH(256); the figure at DEPTH(32) needs reading from the next fit report
rather than assuming.

**The lever that does apply is the payload width**, because blocks here are
width-driven:

```
y, x0, x1   3 x 32 = 96 bits    screen coords fit in ~12: 3 x 13 = 39
u, v        2 x 32 = 64         quarter-texels, 16 fractional bits
dudx, dvdx  2 x 16 = 32
col, tex    2 x 24 = 48
moire, tex_en        2
                    242   ->   ~185 with narrowed coordinates
```

About a quarter off the width, which should come off the block count. The
coordinates are the obvious candidates -- `m2_raster_fill` carries them as
`logic signed [31:0]` throughout while the screen is 496x384 -- but narrowing
them is a change to the FILL's arithmetic, not just to the queue, so it is not
free of risk and wants its own bench run.

## R313 is reversible, and may need reversing

R313 traded area in the direction ALM needed at the time:

```
char cache 8192 -> 4096 lines     +34 M10K free, glyph misses roughly double
span queue registers -> M10K      +484 ALM free, -30 M10K, bubble returns
```

If a later build shows ALM headroom -- or if the doubled glyph misses hurt the
picture more than the ALM was worth -- **put the span queue back in registers
(`m2_span_q`, in commit 5cac8f9, bubble-free) and take the char cache back to
8192 lines.** Both halves are one parameter each. The trade was made to get a
build that fits at all, not because it is the right shape.

## A trap that made an area change a silent no-op

`Model2.sv` instantiates `m2_char_cache #(.IDX_BITS(13))`. Editing the module's
DEFAULT changed nothing; only a knock-on width mismatch on `inval_idx` exposed
it. **A default is not a setting when the instantiation overrides it** -- check
the instantiation, not the module.
