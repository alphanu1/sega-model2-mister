# Speed plan

Ranked list of what is left to do and what each is worth.
Full evidence for every line is in `docs/model2a-design-study.md` R426/R427.

**Measured** = a number from the board, a sim or a fit report.
**Estimate** = arithmetic from a measured number, not itself measured.

---

## The target

| | value | source |
|---|---|---|
| Real Model 2A | i960 25 MHz, MB86234 50 MHz | study S45-46 |
| We run | i960 25 MHz, renderer 50 MHz | **exactly 1x** |
| Model 1 needed for 60 fps | CPU 1.84x, 3D 2.36x | Model1.sv:675-682 |
| Model 1's 3D ceiling | 58.84 MHz -- "80 does not close" | Model1.sv:680 |

So the clock is necessary and nowhere near sufficient. Cycles per quad is the lever.

## Where the time goes

The whole deficit is the texture path. With textures OFF the bands complete and
no drops are visible (board, Ben). Three costs switch on together with `in_tex`
and nothing else does: the plane fit, the per-group walk expansion, the texel
fetches. **The split between those three is not yet measured.**

---

## TO DO, best first

| # | change | gain | cost | status |
|---|---|---|---|---|
| 1 | **Remove the readback probe on port 0** | +11-33% texel grants, +0.37 ns clk_mem | none | **done, R427, building** |
| 2 | **Stop the ROM sweeper looping on port 2** | same class as #1, likely larger | none | **not done** |
| 3 | **Plane-fit reciprocal** -- 6 divides share one denominator | ~2.4x on the fill, ~1.4x on the frame *(estimate)* | ALM | not done |
| 4 | **Register the fp_pool operand mux** | Model 1: 39.6 -> 54.57 MHz *(measured, theirs)* | ALM + a latency step | not done |
| 5 | **Re-test R387's prefetch** | unknown -- never fairly tested | none | not done |
| 6 | **Texel cache 2048 -> 4096 lines** | 70% -> ~80% hit *(estimate)* | +21 M10K | not done |
| 7 | **Clock boost to 60/120/30** | +20% | needs 2.6 ns clk_sys, 1.6 clk_mem, 3.5 clk_i960 | blocked on 3-6 |

### Notes on each

**1. Port 0 readback probe.** `rb_req` read two words onto the debug overlay.
R411 deleted the overlay; the loop kept running. `rb_w0`/`rb_w1` have had no
reader since. It was ALWAYS pending, so it took a full share of every rotation.
Not the ROM loader -- that is `ldr_wr_req` on the dedicated write port.

**2. ROM sweeper on port 2.** `sw_take <= uart_b2_valid && !wedge_have &&
sw_pend`, then `sw_state <= 3'd0; // and immediately go round again`. The debug
UART emits continuously, so the sweeper restarts forever -- a rolling
0x100000-word checksum of SDRAM during gameplay. Like #1 it is always pending, so
it takes a full share of every rotation. It is a diagnostic worth keeping; it
should run on demand, not on a loop.

**3. Plane-fit reciprocal.** m2_raster_fill lines 812/815/831/834/851/854 all
assign `den_n` -- six 16-cycle restoring divides by the SAME number. One
reciprocal plus six multiplies replaces them. m2_persp_recip (R424) proves the
technique at 0.018 texels. **The size is an estimate from a stale measurement**
("FILLW 436,000 a frame of 818,133", "the divider IS the fill") taken at radix-2,
before radix-4, before PIXSTEP 4, and before R424 took the fit from four divides
to six. Re-measure before sizing.

**4. fp_pool operand mux.** m2_fp_pool:138-146 feeds `mul_a[mul_win]` straight
into the units. Model 1 found the identical structure was its clk_3d critical
path; registering it took m1_geometry 39.6 -> 54.57 MHz. Their units standalone:
fp_add 138.48, fp_mul 145.62, fp_div 117.81 -- "the sharing wrapper was the
limit, not the arithmetic". Costs a latency step the static scheduler must know
about (theirs is FP_ADD_LAT in m1_geo_xform).

**5. R387 prefetch.** R415 records it was withdrawn on evidence taken while the
fitter flags, packing, capture depth and geometry dividers were all wrong
underneath, and that neither it nor R396 was ever shown faulty or sound.

**6. Texel cache.** Board hit rate 70% at PIXSTEP 4, texels wait 9.6%. The 9.6%
is a ceiling on the cycle gain -- but a texel miss stalls the walk MID-SPAN in
the one unit that cannot finish its bands, so the band cost may be far higher
than the cycle cost. Measure bands, not cycles.

---

## MEASURE FIRST (no build needed, except the last)

1. Cycles blocked in `T_FETCH` on `tx_ack` -- the real miss cost
2. Cycles in `S_PF_Q1W`/`Q2W`/`Q3W` -- the divide wait
3. Groups per frame -- the walk's expansion factor
4. Per-port `req`/`grant`/`wait` off the board with textures on -- how many ports
   are actually pending at once, which is what sets the texel port's real share

---

## DO NOT RE-PROPOSE (evidence in study R426 s4)

| rejected | why |
|---|---|
| Char cache back up | Ben measured 128 KB **still overran** (694 misses/12 overruns vs 2,146/51 at 64 KB). Latency tail, not capacity. |
| Grow the quad store | NQ=2048 is exactly the deepest M10K config, so 2049 costs what 4096 costs: +143 blocks against 48 free. |
| Slow the video (ce_pix) | It is the pixel clock, so hsync goes 24.39 -> 12.20 kHz. Survives ascal, not direct video. (R422 withdrawn by R423.) |
| DDR3 framebuffer | What Namco System 22 does (5.9 fps, complete picture). Framework supports it behind `MISTER_FB`. **Ben has ruled it out.** |
| More band buffers | ~7 M10K each; a whole frame is ~336 against 48 free. |
| Split the write port | It is not in the round-robin -- strict priority gated by `!pipe_busy` -- and is already starved (worst write wait 736 cyc). More ports deepen the arbiter, the current worst path. |

## BROKEN INSTRUMENTS

- **tb_m2_raster3d cannot measure the texel cache.** With `M2_R3D_TEX=1`:
  15,454 hits, 1 miss, **identical at 1024, 2048, 4096 and 8192 lines.** Its
  synthetic quads sample one texture line. The board's 70% is the only real datum.
- **No per-state cycle counters in the fill.** The 436,000 figure came from
  instrumentation that no longer exists.
- `IDX_BITS(11)` is a literal at m2_raster3d:464 -- R389's PIXSTEP lesson exactly.
