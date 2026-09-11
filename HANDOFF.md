# Handoff

**Updated:** 2026-09-11 16:30 (machine clock). Study entries R176-R221.

## WHERE 2026-09-11 LEFT IT

**The whole 3D path runs on hardware for the first time.** Board: `build/dbuf14b`
s15 (97% ALM, hold positive on all clocks, setup miss on the HDMI PLL only).
White, flat-shaded cars (the colour is a constant by design: lighting is not
built), behind the UI text, over a steadily scrolling background, at the
game's own 30 Hz list rate, with the store dropping nothing. `build/dbuf15`
(PCM lines to M10K + MLAB clipper stack) REFUSED TO FIT: 556 M10K blocks of
553 -- the chip has no blocks left, only bits (77%). Small wide arrays go
to MLABs. **`build/dbuf16` (PCM lines, MultiPCM state and register fields,
clipper stack all in MLABs) FITS AT 83% -- 34,614 ALM against 40,555 -- and
s14 MEETS TIMING ON EVERY CLOCK (setup +0.556, hold +0.186).** Deployed s14:
capture identical to dbuf14b (drops 0), SOUND CONFIRMED BY EAR on the board
with the MultiPCM state in MLABs. R221 closed. The user reports the 3D still
has issues on this build (details being gathered). R222 (lighting design,
measured inputs) is written; implementation next.

**Fixed today, each with a study entry and a board or bench proof:**
- R208 walker/engine took one held acknowledge many times (stream one word ahead)
- R209 shared write port wedged when the TGP and the push DMA collided (arbiter, four-phase)
- R211 flashing: a list every second frame drawn from a single quad store (double-buffered, 191-bit entries)
- R212 background jumping: the TGP's atan/inv units were Model 1's; gpio0 was tied low
- R213 3D drew over the UI (reference order); 8-row bands; buffer-release settle
- R214 pair caches on port 4 (halve trips; not the collect's cost -- kept)
- R215/R216 frames of ~5,000 quads vs 2,048 held; sub-2-px quads refused (46%)
- R217/R218 projector: strip-shared vertices and uncut clipper vertices keep their pixels (467 -> 177 cycles/polygon)
- R219 the reference's culling: back faces of single-sided polygons and link type 0 (45% of the title's polygons)
- R220 the sorted list was overwritten by the next walk before the swap (store takes quads only while collecting)
- R221 PCM fetch lines to MLAB (WAV-identical), clipper stack to MLAB (2,003 checks), MultiPCM per-voice position, descriptor and read register fields to MLABs (lockstep differential bench vs the flip-flop module, 0 mismatches, catches each mechanism removed) -- in dbuf16

**Open, in order:**
1. ALM: 83% fitted (dbuf16). The probes that reach no output cost nothing (synthesis sweeps them). Next by dbuf16's own table: the quad store's 1,669 registers, then the i960 (8,049 total). M10K: 553/553, nothing more goes there. Lighting (R222 design in the study) can start.
2. Lighting: R222 in the study is the design, with the reference's arithmetic and the measured inputs (title: 1,917 objects, 3% headers in texture RAM, 352 flat / 1,507 textured, 32 colour bases). Steps: bridge mirrors (palette 0x1000-0x13ff and the whole colorxlat into free SDRAM at words 0x1730000/0x1731000), engine memory-space select, walker op 0x04 into TEXRAM (word 0x1740000), engine dotl + luminance + header read + colour cache, poly_col through m2_geometry to the clipper. Oracles listed there.
3. Throughput: quad projector still ~14% of geometry time; the transform ~14%; `dbg_hold` reaches 3 frames in stretches, partly the game's own list timing (separate the two).
4. Vertical scroll: fixed by R212. R200's band-13 cut: superseded by 8-row bands? -- re-test the 3D test bars.
5. Textures: the largest block left; see R215 road 2 for vertex words in SDRAM if capacity returns as an issue.
6. `make test_mb86233_regs` fails on the committed tree (pre-existing, not investigated).

**Rules learned today, written into the study:** an M10K deeper than 2048 is the least dense shape (R211 fit); model the OWNER's timing in a port test, not the port's (R209); above 92% fitted, registers cost an ALM each (R221).

---

## R209: THE BOARD HANGS IN THE 3D TITLE -- THE SHARED WRITE PORT WEDGES WHEN THE TGP AND THE PUSH DMA COLLIDE. ARBITER IN, BUILDING

`build/ack` s14 froze after ~3 minutes of 3D title: i960 in the mailbox poll,
TGP parked at 0x46E (0x46F = its mailbox write, waiting on `wr_done` from the
SHARED WRITE PORT), every counter frozen. A second boot ran 7 minutes clean:
a race. The port was a fixed-priority combinational mux of five owners with
the push DMA's ack unqualified; two owners alternating keep `s_wr_req` high
across the change, the adapter's `w_done` never clears, no write is ever
issued again, and both wait forever. Same family as the 09-10 "clear at
0x4C4 issued and never seen" freeze. `rtl/mem/m2_wr_arb.sv` now grants the
port per transaction, round-robin, dead cycle on release, per-owner acks;
`make test_m2_wr_arb` models the adapter's write side and also caught the
fixed-priority starvation of the DMA. **`build/wrarb` s11 BROKE THE ROM LOAD:**
the loader pulses its request for one cycle, the arbiter released on the
gone request without writing, the loader waited forever and ioctl_wait held
the HPS. Fixed: the arbiter latches a request per owner until its
acknowledge; the test's loader slot pulses. **`build/wrarb2` s15 FROZE ON THE
FIRST JOB** (TGP at 0x4C9, mailbox clear never seen): the latch kept the
TGP's stale request line (registered twice, three cycles up after its ack)
and the next grant to that slot wrote the TGP's idle bus over the mailbox.
Now four-phase: a served owner is not granted again until its line has
fallen. The test drives garbage from idle owners and idles the coprocessor
slot for tens of cycles at a time; the two earlier arbiters fail it, this
one passes. `build/wrarb3` (11, 13, 14, 15) carries it plus the flashing
probe. **`build/wrarb3` s15 WORKS (09:45): ROM loads, first TGP job
completes, 4 minutes clean -- render chain 10.6%, mailbox poll 3.7%, no
parking, no drops. Ten-minute soak from a fresh load also clean: mailbox
poll 3.9%, render chain 12.5%, never parked. R209 CONFIRMED.** The board is
on it. Study R209.

**dbuf14b s15 ON THE BOARD (20:20): everything to R220; 97% ALM. Capture
running. `build/dbuf15` (+ block-RAM PCM lines + MLAB clipper stack) in the
fitter -- the first build expected to come down in ALM.**

**R221 step 1 (19:40): the PCM fetch units' line data is block RAM, sound
output byte-identical (WAV compared). ~4,100 registers freed; in the build
after dbuf14b.**

**NEXT (R221): free ALMs before lighting/textures -- the fitter charges an
ALM per register above ~92% (dbuf13 at 97%). In order: the two PCM fetch
units' 64-bit x 32 prefetch buffers to M10K (~2,700 registers each), the
MultiPCMs' per-voice state (needs the tick schedule re-cut), the clipper's
shift-register stack to an MLAB, and the spent debug probes. Target under
85% fitted. Study R221.**

**R220 (18:30): dbuf13 on the board drops NOTHING (capacity closed) but the
3D is still on-off with wrong wedges: the next walk, started by a mid-frame
flip, overwrote the sorted list waiting for the swap because the store never
pushed back. `q_ready = (pst == P_COLLECT)` now; the geometry waits.
`build/dbuf14`. Study R220.**

**dbuf13 (18:00): fits at 97% ALM (40,690), block memory 77%; two seeds
crashed, s11/s15 fit with setup misses of -0.5 ns (clk_mem / clk_sys), hold
positive. s15 deployed as the functional test of everything to R219. The
fitter packs registers one per ALM at this density: the coprocessor's
flip-flop input queue -> M10K (~2,000 ALM) is the next change, before any
more logic.**

**dbuf11 CRASHED THE FITTER on all four seeds (density: each of R217/R218
alone puts the device at 98% ALM, and Quartus 17 falls over there on half
its seeds -- bisected from two worktrees). Both slimmed (0f47d1b): the
engine states the strip's carry instead of the projector comparing floats,
and the clipper's stack carries vertex ids instead of pixels. `build/dbuf13`
= everything to R219, slimmed, in the fitter. Board still on dbuf10 s15.**

**R219 (16:10): the reference culls back faces of single-sided polygons and
link-type-0 polygons; the engine emitted everything. Now it culls as the
reference does: emitted quads over the title 57,840 -> 31,648, projection
share 14% (from 50% this morning). `build/dbuf12` = dbuf11 + R219 queued
behind dbuf11. Study R219.**

**R218 (15:15): the clipper reprojected every vertex of every quad it emitted;
now only the ones it cuts. Engine cost per polygon 467 -> 409 (R217) -> 177
(R218), clipper projections 219,860 -> 4,972, engine idle 39% -> 64%.
`build/dbuf11` = dbuf10 + R217 + R218, building. Study R218.**

**R217 (14:15): the projector projected all four vertices of every polygon;
strips share two with the previous one, which now keep their pixels
(ea4289b). The engine's split: projection busy 50% of all ticks, the engine
waiting behind it 34%, memory under 2%. Remeasuring; then a build.**

**R216 (13:50): 46% of the title's quads are under 2x2 px (bench histogram);
the store now refuses them, counted on the record. Expected to bring the
heaviest frames from ~4,200 to ~2,300 against 2,048 held. `build/dbuf10`
building. The engine's cost is 467 cycles a polygon, fixed (study R215);
its per-stage split is being measured -- that is the "slower".**

**dbuf9 s14 ON THE BOARD (13:20), everything to R214, fits at 91%:** the
store DROPS up to 2,148 quads a frame on top of 2,048 held -- the busiest
frames carry ~4,200 (MAME's peak is 4,798) and the last-submitted half is
what is missing on screen. Push DMA drops 0. The pair caches did not shorten
the collect (5-14 ms as before): the engine's arithmetic is the limit, not
memory. Next: count sub-pixel quads in the bench (free rejection if many);
else vertex words to SDRAM with 4,096-entry banks. Study R215.**

**dbuf7 did not fit (74,800 ALUTs): the two-bank store's final-order array
lost a read port to registers, and every vertex array had been duplicated
since the narrowing by a two-slice read. Both fixed (ad02e34). `build/dbuf8`
= corrected store + four buffers + pair caches + drop counters, building.**

**R214 (12:30): a pair cache in front of the walker and the engine -- the
controller returns four words per read and both used two. Halves their port
trips; unit-tested at four latencies. `build/dbuf8` = dbuf7 + R214, queued.
Study R214.**

**dbuf6 s14 ON THE BOARD (12:00): background scrolls normally (R212 confirmed),
3D behind the UI (R213 confirmed), bands never late (dbg_missed 0), lists
held 2 frames mostly but 3 for long stretches (collect 7-14 ms -- the
"slower"; R210's throughput is real), quads held at the 2,048 ceiling in
heavy frames (overrun -- the "3D mostly missing"; drop counters go on the
record next, R214). Board is on dbuf6 s14. `build/dbuf7` (four buffers,
shared-key store) in the fitter.**

**R213 (11:20): the 3D drew OVER the UI -- the reference puts it between the
two tile categories; fixed via `vid_cat1`. `build/dbuf3` (191-bit entries)
still ran out of M10K: the IHRES override did nothing (the scaler's cells are
its burst buffers). Now 8-row bands as Model 1 settled on (band buffers
halved) with a band RANGE in the store instead of a 48-bit mask, plus
`dbg_hold` (frames per list on display) and `dbg_missed` (scanlines with no
band ready) for the user's "still flickering / slower" on dbuf2.
`build/dbuf4` = R212 + R213 + narrowed 2,048 banks: FITS (2,048 banks, 8-row
bands, 77% block memory) but both bitstreams miss hold by -0.3 ns on one path,
bridge r_rdata[15] -> bus_rdata[15] into the CPU clock; not deployed. Quartus
pads internal hold only with OPTIMIZE_HOLD_TIMING "ALL PATHS", now set.
`build/dbuf5` (a fourth band buffer) ran out of M10K blocks; back to three.
`build/dbuf6` = dbuf4 + buffer-release settle + hold fix, building. Study R213.**

**R212: THE JUMPING BACKGROUND IS THE TGP's ARCTANGENT -- MODEL 1's UNIT ON A
MODEL 2 BOARD. FIXED AT THE DESK, BUILDING.** The horizon row of the title's
tile background is a coprocessor atan2 result (function 0x0a) that the game
converts to the layer-2/3 vertical scroll word (0x50130A -> tile RAM
0x5006). `m2_tgp.sv`'s atan and inv units were transcribed from Model 1;
Model 2's differ (float-exponent table index, |a|<=|b| selector, no table
fixup, inv sign on the odd word only) and Model 2 also feeds that
comparison to the microcode as the gpio0 condition, which we tied low.
Rewritten from model2.cpp; `tb_m2_boot` now scores every atan job against
C atan2 (`ATAN jobs checked`): 89 of 89, and the latched scroll creeps
0x2FDE, 0x2FDD, 0x2FDC like the reference. Study R212.

**R211's fit:** two 2,048-entry stores at the old 231-bit entry need more
M10K BLOCKS than the device has (553; bits were only at 84%). Entries are
now 191 bits (13-bit saturated coordinates, 565 colour, 24-bit key; six
sort passes instead of eight) and the framework scaler's input line
buffers are halved (`sys_top.v` IHRES 1024). `build/dbuf2` is a
1,024-a-bank stop-gap to prove the flashing fix on the board; `build/dbuf3`
= R212 + narrowed 2,048 banks + IHRES is queued behind it. If dbuf3 still
misses: share key + one scratch index between banks (~8 blocks), loader
FIFO 512->256, character cache, i960 data cache; the coprocessor's
flip-flop input queue (~2,000 ALM) is the logic lever.

`make test_mb86233_regs` fails on the committed tree (46,966 of 3 M
checks), in a module untouched today. Not investigated.

**R211 CONFIRMED on the board (build/dbuf2 s13, 10:50):** bands completed per
frame 26 on nearly every sample where build/ack read 1 -- every band drawn
every video frame. Collect 4-7 ms median, 17 ms max; the 1,024 banks sit at
their ceiling in the title, so dbuf3's 2,048 banks are needed.

**R211: THE FLASHING IS PRESENTATION -- Daytona flips every second frame
(the reference measurement in m2_geo.sv), and the single quad store could not
draw while collecting. `m2_raster3d` now has two stores: collect into one,
replay the other every video frame until the next is ready. `make
test_m2_raster3d` shows the committed RTL painting 0,0,0,9717,0,0 pixels
over six frames and the fix painting every frame. Building as `build/dbuf`.
R210's throughput reading is withdrawn as unproven; its timers stay on the
wire to answer it.**

**R210 (superseded by R211): THE FLASHING IS THROUGHPUT.** `dbg_late_frames` and `dbg_qend_frames`
advance at the same rate: the geometry stage takes ~2 video frames per game
frame, every frame that starts mid-collect clears the store and draws
nothing, and when a frame is ready it is late enough that mostly one band
completes. Ready-cycle counter saturates at 65535; next probe widens it
(units of 16) and splits walk+engine from sort. Candidate levers, in order
of size: use both dwords of port 4's 64-bit return (halves walker and
engine reads), prefetch the object stream, cut the per-word handshake cost.

**SEEN ON THE SCREEN (build/ack s14, 08:05): white, transparent car models,
flashing on and off.** The first 3D drawn on hardware. White is by design
(`m2_geometry.sv`: q_col is a constant; lighting and texture not built).
The flashing is the next fault: candidate is frames whose geometry is not
finished at frame_start, which clears the quad store and draws nothing --
`dbg_late_frames`/`dbg_qend_frames` in `m2_raster3d` now measure it.

Also seen: the background jumps up and down on `build/ack` as before
(vertical scroll fault, still open, not this).

## R208: THE 3D STREAM WAS ONE WORD AHEAD BECAUSE THE WALKER AND THE ENGINE TOOK ONE HELD ACKNOWLEDGE EVERY CYCLE. FIXED IN THE REQUESTERS, BENCH-PROVEN, ON THE BOARD NEXT

`m2_sdram_x2` holds a port's acknowledge for as long as the request stands
(R162). `m2_geo` held `rd_req` as a level through every reading state and
stepped `w_ip` on every `rd_ack` cycle; `m2_geo_engine` did the same with
`mem_req`. One acknowledge, many words: the index moved on with stale data
and the port never issued the next read. That is R207's "engine's first read
at 0x1388 = obc" and every shifted matrix and focal before it. The boot
bench never showed it because C++ answered in the same tick.

**Fix, in `rtl/video/m2_geo.sv` and `rtl/video/m2_geo_engine.sv`:** take the
acknowledge on its rising edge only (`rd_go`/`mem_go`, at every consume
site) and lower the request for one cycle after each accepted word. The
port-4 glue in `Model2.sv` stays as R173 left it (R206's glue-side gating
deadlocked, and could not have worked: the glue cannot drop a request the
module holds).

**Bench proof:** `M2_GEO_LAT=6` now serves both port-4 requesters exactly as
the adapter and glue do (registered request, `done` set on the fast ack and
cleared only on a low-request cycle, ack `f_ack | done` a tick late, data
held; the model runs every tick or it hangs on its own stuck ack). Old RTL
under it: 43 walk frames, 38 objects, 0 quads, walk at its 32767-op bound,
trace shows 30 consecutive ack ticks consumed. Fixed RTL: 80 frames, 1240
objects, 3,132 quads, first read per object at the object's own address --
identical to instant service. `M2_GEOTRACE=<file>` dumps the handshake.

    M2_GEO_LAT=6 M2_POLY_FROM=17000000 ./obj_boot/Vm2_boot_harness +insn=19500000

**On the board, 04:05 -- CONFIRMED.** `build/ack` s14 (setup -0.149, hold
+0.242; deployed, capture `ack_s14.txt`): the engine's first read per object
is now the object's own address (0x15FF9D = the bench's first object, same
ROM base select), reads per object saturate at 255 instead of 12, the polygon
counter runs to 50,048, the clipper passes 17,001 and 22,271 quads reach the
rasteriser (16-bit counters, wrapping). Before, on `build/eo2`: 0x1388 (obc),
12 reads, all three counters 0. The board's stream now starts where the
bench's does. This is the first 3D geometry to reach the rasteriser on
hardware. NOT yet seen on a screen -- the capture cannot say what was drawn;
look. If the picture is wrong or empty the fault is now downstream of the
engine's fetch: the rasteriser (R200's band-13 cut is open) or presentation.
The board is running `build/ack` s14; the previous core is `Model2.rbf.prev`.

**Rule for any new requester on a shared port:** both rules above, and run
it under `M2_GEO_LAT` before a build.

---

## 0x030B IS THE TGP'S IDLE LOOP. THE 3D TASK IS THE LAST OF 140 AND THE BOARD'S WALKER NEVER CALLS IT (R202)

**The 2026-09-10 headline is withdrawn.** `copro_stall` (`m2_copro.sv:303`) is
the i960 held on an empty OUTPUT FIFO; it cannot say whether the TGP waits on its
INPUT FIFO. The microcode says it does: `L_04c` is `b = rf1`, the FIFO read
that replays until a word arrives, and 0x30B is the `goto L_04c` that retired
before it. R188 had this right. The TGP is idle because the game sends nothing,
and "CPU at 100% is the symptom" fell with it. **Read the code behind the number
before using it (R149).** It cost the whole of 2026-09-10.

**Where the game's 3D lives, from the reference (MAME 0.289, Lua taps):**

    attract state 0x5010a4:  0 -> 2 at frame 171 -> 3 at frame 172
    state 3 = the 3D title, 1600 frames; the 3D task 0x5890 is registered
    by state 2's handler as ENTRY 140 OF 140 in the per-frame task list
    (0x504000.., count from ROM 0x22f1f0, walker at 0x1838)
    entry 111 (0x510100, handler 0x2200e4) skips 28 disabled entries:
    jumps the walk to *0x501260 = 0x510F00 and stores count-28 (= 2)
    reference walk: 112 iterations, 67 calls, last call 0x5890, every frame
    render chain 0x16e58-0x17b00 = 2.7% of every frame

**The board in state 3 (captures c/d of 09-10, walk frames 284-2012):** TGP
busy, i960 40% in the mailbox poll 0x1166c (the car/track code's TGP query --
game logic, which the reference does without spinning), 0x11450-0x11538
executed, and **zero of 7,537 samples in the render chain** across 590 frames.
Not a sampling artefact at 2.7% of a frame. And the direct count from the 09-08
captures, decoded with build 2868625's layout: state 3, state 2 entered twice,
0x1c14 executed, walker head and callx saturated, **tw_5890 = 0**. Registered,
walked, never dispatched.

The plain boot bench (same RTL, instant memory) reaches 0x5890 at frame 248
straight after the skip handler. The i960 is in-order and blocks on `divo`. So
the divergence is in the four work-RAM words the walk depends on -- the
descriptor at 0x510F80, the pointer at 0x501260, the count at 0x5011fc -- as the
board's memory path serves them. `build/walk` (seeds 11, 12) instruments exactly
that: H = last descriptor the walker loaded | {count stored at 0x220104, pointer
read from 0x501260}; C carries tw_5890 and the attract state in place of the
retired-instruction rate. Decode with the layout in `Model2.sv` (search
`wk_last_desc`). Reference values in state 3: 0x00510F80 / 0x0002 / 0x0F00.

**RESULTS, two instrumented builds later (2026-09-10 evening):**

`build/walk` s11 (setup -0.461): attract state 3, `tw_5890` = 0, skip handler
never ran, **the walker's last descriptor load is entry 13 (0x504E00)**; the
board then froze on one frame with the i960 in the mailbox poll (98% at
0x1166c) and the TGP at 0x4C9, which is the `goto L_04c` after the clear at
L_4c4. The clear was issued and never seen.

`build/walk2` s11 (setup -0.242 on the HDMI PLL only, hold +0.186): the count
from ROM is 140; the walker's last stored count reaches 0, so **on this build
the walk runs the whole list**, slowly -- most of every frame inside 0xC9C4,
the car handlers' INIT state, which the reference leaves after one frame. IP
samples in state 3, by handler: entries 1, 6, 11, 12 execute; 13-32 sit in
0xC9C4 (4,854 samples, the mailbox query inside it); **entries 57, 59, 61, 63,
67, 75-111 (the 0x22xxxx tasks) and 140 execute ZERO instructions.** Every
task state 2 registers at a descriptor above 0x50D000 is dead on the board;
every one below 0x508800 works. The cars stay in init because the task that
places them (entry 63, 0x226360 -> 0x2264E4 installs 0xCF74) is one of the
dead ones.

So the fault is one of: the enable stores to those descriptors (state 2's
`setbit 31; st` at 0x1c08 and its siblings) not landing, or the walker's
`ld 0(g13)` for those addresses reading stale/wrong data (the bridge's
write-through-invalidate data cache is the one thing between them), or
something clearing them afterwards. `build/e140` (seeds 11, 13, fitting)
captures entry 140's word 0 and handler exactly as the walker reads them,
and how often it is loaded. `build/mbox` (fitting) captures the TGP's mailbox
writes against the CPU's readback, for the hang.


**THE MECHANISM, FOUND 2026-09-10 LATE EVENING (R202, last two parts).**
`build/e140`: entry 140's word 0 reads 0x00000000 in every state-3 sample and
the walker loaded it twice in 9,000 frames, while the count still reaches 0
each frame. The walk is not advancing: entry 13's SIZE field reads 0, so
`addi r7,g13,g13` adds nothing and the walker spins on entry 13 for the rest
of its count, calling 0xC9C4 each time (the ~127 mailbox queries a frame).

Why the size is 0: the game does `stos g2, 6(g9)` at 0x6FA0 into the player
car's descriptor every frame, an UPPER-HALF halfword store. The bridge follows
that with a dummy write to the next word -- `sd_be = 00`, data 0 -- trusting
DQM to mask it. R82 measured that byte enables are lost in silicon. The dummy
lands 0x0000 on 0x504E08, the size field. Simulations honour the mask, so the
bench always reached the 3D task and the board never did.

Fix (in the tree, `m2_cpu_bridge.sv` S_LO_W): an upper-half write completes
after its one real word; nothing relies on the mask. `build/fix` (seeds 11,
13) carries it plus entry-13 probes; `build/e13` is the same probes without
the fix, the control. Expected on the fix: size 0x300, one handler load per
frame, `tw_5890` climbing, tiles scrolling, cars placed. If the walk reaches
entry 140 and the 3D still does not draw, the next things in line are R200's
band-13 cut and the TGP's mailbox clear on the shared write port
(`build/mbox2`, seeds 14/15, the probe pair for it).

Then the throughput work, both measured today: the TGP blocks on SDRAM for
every data access (a query costs half a frame), and the CPU's write-through
stores are unposted (race mode: 77% of the i960 in a `stq` fill loop).

**CONFIRMED ON THE BOARD, `build/fix` s13, 22:09:** size field 0x300 in every
sample, written only by init; render chain 5,048 samples (was 0); 0x5890 every
frame; the 0x22xxxx tasks run; cars leave init; mailbox samples 239 (was
~10,000); the CPU idles 31% in the frame wait. The attract runs at speed and
the background moves for the first time. **Still no polygon on screen.** The
game emits geometry every frame now; the fault has moved downstream to the
geometrizer/rasteriser path (never fed real data on hardware before tonight)
and R200's band-13 cut. Next build: fix + geometry counters, four seeds.

**`build/geo` s11 (fix in), 22:40:** matrix pushes saturate, walk opcodes
286-2,050 a frame, **polygons 0, clipper in 0, clipper out 0.** The list is
decoded; the geometry engine produces nothing. `build/obj` (four seeds)
carries objects dispatched : finished, MAX_POLYS caps, walk state, and the
last polygon-ROM word the engine read.

**R203, found 22:50: the TGP's math tables are read 64 KB late on hardware,
and have been since 2026-08-30.** `GAME_TGPTBL` was set from an image that
`build_image` had prepended the 64 KB index-3 I/O ROM to. The board never had
that gap. Every trig lookup the coprocessor has made on silicon returned a
word 64 KB into the table; the bench loads the tables at the RTL's base and
never saw it. Fixed (`0x15D0000`); `build/tbl` (four seeds) carries it with
the bridge fix and the object-stage probes. Expect this to be why the geometry
engine emits zero polygons from thousands of walked opcodes, and why the
camera jumps.

**`build/tbl` s13 (both fixes) on the board, 23:16:** objects dispatched ==
finished, 264 a frame, none capped, real floats read from the polygon ROM.
Background pans slowly (camera orbit: trig now right) and jumps vertically
fast (scroll latch timing, R199). No polygon yet. `build/poly` (four seeds)
carries polys : nonfinite | clip out : quads, and clip drops. Then the scroll
values the renderer used, to settle the jump.

**`build/poly` s13 (both fixes, TIMING CLOSED +0.275/+0.241) is ON THE BOARD,
23:50:** polygons 0, nonfinite 0, clipped 0, quads 0 -- the engine walks
every object to its end and emits nothing. The plain bench with both fixes
in the same phase: 1,853 objects, 18 polys, nonfinite saturated, 1,410 quads
ALL degenerate at the right screen edge (x 493-496). **The rest of the 3D
fault is now reproducible at the desk.** Start there: `M2_TRAP` at the first
E_EMIT, the walker's captured matrix/focal against MAME's for the same
object, and why the objects end at their attribute word on the board.
`build/scr` (four seeds) adds the vertical-scroll probe for the fast jump.

**R204/R205, 2026-09-11 00:00-01:30, found and fixed at the desk.** The boot
bench had buffer-RAM reads OFF (`BOOT_BUFFERRAM ?= 0`; the board is 1), so
every mailbox answer it ever handed the game was zero; with reads on, the
TGP's placement answers were real and wrong (-0.1 / 0x3DF where the
reference gives -0.0 / 0x146). Traced through the TGP's external reads and a
register trace of its init routine: `m2_tgp.sv` answered a windowed read of
copro ROM dword 0x20 with the sincos unit (`sel_math` not gated by the bank
window), so the track-lookup record base $0x6a was 0x800000 with no offset
and every record fetch hit zeros. Fix: `sel_math = !win_en && ...`. With it
the bench's answers match the reference's exactly, word for word. `build/tgp`
(seeds 11, 13, 14, 15) carries all three fixes: the bridge's masked dummy
write (R202), the table base (R203), the math-unit gate (R205).

**Bench with all three fixes, 01:40:** placement answers identical to the
reference; 3,342 quads spread across the whole screen, most larger than ten
pixels, chains tracing curbs and edges. The scene is in view. The bench
harness has no rasteriser, so this is the quads' coordinates, not pixels.
`build/tgp` (four seeds, all three fixes, polygon-path probes on the wire)
is the build to look at. Open in the bench: command 0x2A's six output words
read back as three in the trace (FIFO drop or trace sampling; the
`WORDS DROPPED` counters now print).

**R206, 01:50:** `build/tgp` s11 on the board: objects finish, polys 0,
quads 0 -- the engine's first read of every object was retired by the
WALKER's held port-4 acknowledge with the walker's data (no ownership on
`eng_mem_ack_r`; ACK_HOLD; the engine starts the cycle the walker's read
completes). Fixed: edge-qualified acks, no request presented while an ack is
up. `build/p4` (four seeds) is the build with all four fixes.

**02:05: R206's fix did not move the board** -- `build/p4b` s17 with all
four fixes: polys 0, quads 0, same as before. The fix stays (the hazard is
real) but is unconfirmed as the cause. `build/eo` (four seeds) probes the
engine's first read per object (data, index, base select) and reads per
object; seven reads means it ends at its first attribute word.

**02:30: R206 WITHDRAWN.** Its gating deadlocked the engine on the board
(`build/eo` s11: zero engine reads, busy never toggling). Reverted to the R173
handover; the engine-first-read probe stays in for `build/eo2`.

**R207, 02:55, the board-side fault located (closed by R208 above):** on the board the engine's
first read per object is at index 0x1388 = the object's polygon COUNT, base
select 0, twelve reads per object; in the bench it is the object's address,
base ROM, hundreds of reads. The walker's buffer-RAM stream through port 4
arrives one dword AHEAD on the board (oba gets obc's word). Every matrix
and focal the walker captured on hardware was shifted the same way. Next:
give the bench's walker service the board's port-4 latency and reproduce.

**Tools fixed on the way:** `mame_i960_frame_trace.lua` never read `M2_FRAME`;
`rom_csum.py`'s `build_image` prepended the index-3 I/O ROM (64 KB) to the
image, so `M2_BOOT_IMAGE` trapped the real-memory bench on instruction 1; the
`obj_boot_rm` Makefile rule's source list predated the `fp_*` units and `make`
reported an August binary as current.

**Still open and independent:** R200's band-13 cut in the rasteriser.

---

## WHERE 2026-09-08 LEFT IT

Three things moved, and one claim made during the day had to be taken back.

**1. The black screen is a startup race, not seed luck (R193).** Seeds 1604 and
1953 were rebuilt from one tree and reproduced BYTE FOR BYTE against bitstreams
built a day apart, so the seed really is the only variable. On 1953 the i960
traps and halts having executed nothing -- IP 0 on all 9,426 samples, 0 of 2024
microcode words -- while 1604 runs normally. A placement that merely lost margin
would spoil the picture, not stop the CPU before its first instruction, and the
FAILING build scores better on both setup and hold. Static timing analysis is
not measuring the path that breaks. `SEED 1604` is a lottery ticket and the
fault travels with every future change.

Pinning the SDRAM capture depth moved the failure from IP 0 to IP 0x40910 --
further, not fixed. CL+2 is the right depth (confirmed at the OSD on hardware);
the tree's comments disagree with each other about this and `Model2.sv:795-798`
still documents a retired selector encoding. `st_got` is latched at
`Model2.sv:1189` and never read: the calibration compares live `p_dout[2]` a
cycle later instead.

**2. The grey pixels were a display list read mid-rewrite (R195), and removing
them is NOT yet a gain.** The flip trigger boots clean at 1604 and the grey
pixels go away, which confirms what they were -- Model 1's "vertices collapsed
toward the origin". But nothing replaced them: the walk runs 901 times in twenty
seconds, retires ONE TO THREE opcodes each time, and produces zero polys and
zero quads. Before the fix it produced polygons, wrong ones. By the only output
that matters this is a step backwards, and it was briefly written up here as a
fix, which it is not.

`rp` sits at 0 while `wp` climbs to 0x403C, so 16 kB of list is written per
frame and the walk starts at the buffer start. The likely reading is that the
game publishes `0x00803008` BEFORE filling, so the flip trigger walks an empty
buffer -- the vblank trigger was wrong, and this is wrong in the other
direction. Untested alternatives: walk on the next vblank AFTER a flip, or walk
the other buffer.

**3. R196 claimed the walk reads the wrong memory. It does not.** Read is
`GAME_BUFFER + {geo_rd_addr_r,1'b0}` (`Model2.sv:644`), write is
`base_buffer + (ptr & 0x1ffff)>>1` (`m2_geo.sv:298`), and `base_buffer` IS
`GAME_BUFFER`. Made from one file without following `rd_data` to its source.

**4. Timing does not predict booting, and the best-timed builds fail (R197).**
One RTL, four seeds, each flashed and read over the UART:

    1604   -0.278  -0.269   broken video, blue/white stripes
    1605   +0.159  +0.186   trap=1 halted=1, IP 0
    1606   +0.178  +0.166   trap=1 halted=1, IP 0x00200020
    1607   +0.052  -0.055   BOOTS, 2024/2024 microcode, TGP running

Both fully-closed builds fail; the one that boots has negative hold. Seed
sweeping for slack is not a route to a bootable core. `SEED 1604` was never a
good seed, only a lucky one.

**Do not infer a code fault from a run of seed failures.** When three seeds
failed on new RTL while three earlier builds had booted at 1604, this was
written up as "three for three is not luck, the change broke it". The fourth
seed then booted the same RTL. The failure rate is around three in four and
three in a row is unremarkable at that rate.

**5. Port sharing is exonerated, measured on a build that renders.**
`dbg_p4_clash` reads ZERO on hardware -- the first reading of that counter on
silicon -- so the `eng_busy` interlock on shared port 4 (`Model2.sv:642`) holds
and R167's fault is not recurring. `geo_walk_unknown` is 0, `geo_walk_state`
returns to `W_IDLE`, and `ops` is exactly 3 on every walk. The walk is not
starved, crashing or misreading: it is handed a list of three valid opcodes and
a proper terminator.

**THE OPEN QUESTION, and it is better shaped than this morning's:** `wp` says
16 kB of list is written per frame and the walk finds three opcodes. Either the
pushes are not landing where the walk reads despite both naming `GAME_BUFFER`,
or the game is not emitting 3D geometry and three opcodes is all it sends.

**Next measurement:** the first word the walk fetches. It separates those two
outright. Instrument cost is real -- every debug addition today cost timing --
so add it and remove something else.

**Delivered for that work:** `O[24:23]` selects the walk trigger at runtime --
Flip, Vblank, After flip, Write ptr -- so the remaining candidates cost an OSD
change rather than a build and a seed gamble. Selecting Vblank brings the grey
pixels back, which is a useful diagnostic signal rather than a regression.

**Area is finished at the flag level (R194).** The two duplication settings cost
ZERO ALM at both seeds. The four framework `MISTER_*` macros were already set and
their logic is absent from the fit report. `MISTER_SMALL_VBUF` is DDR3 only.
Aggressive Area black-screened the board three times. Area now has to come out of
the design.

**Housekeeping.** Three Quartus STA internal errors in one day
(`sta_assignment_db.h:468` twice, `sta_scc.cpp:1041`), on a design that reports
`Design is not fully constrained for hold requirements` -- possibly the same root
as the seed race. `tools/seed-pair.sh` builds one tree at two arbitrary seeds in
parallel; the pair MUST be built in one session because comparing across days
was what invalidated the first attempt at the seed measurement.

---


## THE 3D PATH IS FINISHED. THE GAME NEVER ASKS FOR IT (R188)

The renderer, the display-list walker, the geometry engine and the coprocessor
are all correct and all idle. The fault is above them, in the game's own attract
sequencer, and it is one value.

**The chain, every link measured rather than argued:**

    attract dispatcher 0x18a0 -> jump table at 0x18cc
        {0x1948, 0x1948, 0x197c, 0x1d24, 0x1dfc, 0x2028, 0x2338, ...}
                         ^^^^^^ entry 2 enables the 3D task, unconditionally
    board dispatches entries 3, 5, 7, 9 and NEVER 2
        -> the 3D task is never registered in the per-frame task list
        -> the walker at 0x1854-0x1860 never calls handler 0x5890
        -> 0x179b8 never runs, no matrices are pushed from 0x17a04

45,260 profiler samples over two minutes: zero in 0x197c, zero in 0x5890,
0x16e58, 0x1780c, 0x179b8 and 0x1786c. The same capture puts 256 samples in the
walker's loop head and 32 in its callx, so the list works and dispatches OTHER
tasks every frame.

**The boot bench does reach the 3D** -- 31,667 matrices pushed from 0x17a04 --
through the same RTL, which is what proves the path rather than the theory.

**What is NOT wrong, each having been believed and disproved today:**

| believed | actually |
|---|---|
| 110 matrix writes is a board fault | the bench pushes exactly 110 at the same point from the same PC (0x1678) before going on to 31,667 |
| the board is stuck spinning at 0x12b0 | that is the main loop's ordinary frame wait; the bench sits there 14.3% while reaching the 3D |
| the board is trapped in the wrong loop | the reference never executes 0x228f00, that loop's exit; being there is correct |
| the copro's arithmetic is suspect | it returns the reference's own constants -- 3ea8f5c3, 43148d8e, 430f4545, 43021a1a, 41ae0e0f, 3fac38e4 |
| 0x44a8 gates the geometry | the bench reaching the 3D executes it ZERO times |
| 0x0053f688 holds a dispatch pointer | it is an interrupt epilogue restoring saved registers |

**A ONE-SHOT CANNOT BE SAMPLED.** This was got wrong twice, on 0x172c (runs 140
times at init) and again on 0x1c0c (runs once). "Absent from the board's
samples" is not evidence for anything that runs a bounded number of times; those
must be COUNTED in RTL.

## READING THE BOARD

    ssh root@<board>   # then, on the board:
    python3 /tmp/uartcap.py <seconds> /tmp/uart.txt

`stty` BLOCKS opening /dev/ttyS1 on this board -- it opens read-write and stalls
with no carrier, which wedges processes in uninterruptible sleep that even
kill -9 will not clear. Open with O_NONBLOCK and set termios from python; the
script is in the scratchpad and on the board. A core reload resets the port's
baud, so re-set it after one.

## THE FITTER SETTINGS WERE THE TIMING PROBLEM (R189, R190)

`AUTO_RESOURCE_SHARING` had been **OFF for every build this project ever made**
-- it is absent from the qsf and its Quartus default is Off -- and
`OPTIMIZATION_TECHNIQUE SPEED` refuses the logic-for-mux trade that sharing
exists to make, while `OPTIMIZATION_MODE` asked for performance on top. The
three only mean anything together. Set together, against the build on the board:

| | SPEED + HIGH PERFORMANCE EFFORT | AREA + AGGRESSIVE AREA + sharing |
|---|---|---|
| ALM | 41,144 / 41,910 (98%) | **37,554 (89.6%)** |
| M10K, device | 553 / 553 | 553 / 553 |
| quad_store M10K | 75 | 66 |
| worst slack | -0.202 | -3.344 |

Two seeds agree, so it is the settings and not seed luck. **3,590 ALM and 8.4
points of occupancy.** Build after build has been spent seed-sweeping a fitter
that had nowhere to place; this is the remedy for that, not another seed.

**The whole timing cost is in `ascal`, the framework scaler, and none of it is
ours.** Every failing path is `ascal|o_hcpt -> ascal|o_vcpt_pre3`, and
`m2_sdram|dq_r -> p_dout` -- the worst path at -0.202 and the subject of R176 --
drops off the list entirely. The scaler was already second-worst at -0.106
before the change. `OPTIMIZATION_TECHNIQUE` and `AUTO_RESOURCE_SHARING` are
entity-level, so ascal is exempted and keeps what it was closing under.

Remaining area levers, both pulling the right way and neither tried:
`PHYSICAL_SYNTHESIS_COMBO_LOGIC_FOR_AREA ON` (its OFF justification cited SPEED
and "8,940 ALM spare" and is dead) and `PHYSICAL_SYNTHESIS_REGISTER_DUPLICATION
OFF` (Model 1 runs it off, we run it on).

**None of this touches M10K.** 553/553 before and after: these settings act on
logic, not memory inference. 92 of the 583 claimed blocks are packing waste --
char_cache +26, quad_store +24, tdp_ram +15, sound_board +13. The four
quad_store vertex arrays are identical 2048x32 simple-dual-port memories costing
14/13/13/12 blocks against `key`'s 7 for the same shape; 9 came back from the
settings alone. The sound board's 78 blocks of 68000 work RAM are the biggest
movable single item.

## TIMING HAS NO HEADROOM (R189)

41,144 / 41,910 ALM (98%) with 553/553 M10K. Four seeds in a row missed --
-0.311, -0.974, -0.423 and an Internal Error -- against -0.021 on the build on
the board. Instruments were cut to two latches for this reason.

`AUTO_RESOURCE_SHARING` was OFF for every build this project has ever made (it
is absent from the qsf and defaults Off), and `OPTIMIZATION_TECHNIQUE SPEED`
biases the synthesiser against sharing anyway. It is now ON, changed ALONE.
`OPTIMIZATION_TECHNIQUE AREA` is the next arm -- Model 1 closes at 97-99% with
AREA plus "Aggressive Area" and nothing else. Note the qsf records an earlier
experiment stripping the nine physical-synthesis passes: it tested the CRASH
rate, which did not improve. It never tested area, so AREA is untested here, not
disproven.

Model 1 core builds share this machine and run concurrent fits; seed-sweep.sh
subtracts foreign load, and a foreign fit is what seed 1783's Internal Error was.

## WHERE THE MACHINE IS

The core runs Daytona attract at ~95% of hardware speed with sound and tilemap.
The 3D geometry pipeline is **complete, wired, verified, and idle** -- every
stage measured healthy on hardware, waiting for input the game is not sending.

**THE CURRENT POSITION IN ONE LINE:** the board's geometry path works and the
game does not use it. `mtx_push` is frozen at 110 -- matrices sent once during
initialisation and never again -- and `wp` reaches 0x24 every frame, meaning a
nine-dword list of `window_data` and `geo_end`. The same game in the boot bench
emits 399 matrix writes, 553 objects and 3,038 polygons. Same core, same ROMs,
same MRA, md5-verified. The divergence is in the i960's own execution (R178,
R181), not in anything downstream of the front door.

**The single most important thing on this page:** the reason nothing ever drew
was that **the geometrizer's opcode is encoded in the WRITE ADDRESS, not in the
data** (R177). Everything else chased for a day and a half -- zero matrices,
degenerate quads, phantom object_data commands -- was downstream of that.

### WHAT WAS FIXED, AND WHERE IT IS WRITTEN DOWN

| finding | entry |
|---|---|
| Opcode is in the write address; found by RUNNING MAME and diffing bufferram | **R177** |
| SDRAM arbiter's address mux was the worst path; both clocks closed | **R176** |
| Walk read buffer RAM while the front door was still writing it | **R179** |
| Texture must go to SDRAM; its cache must come out of the sound board | **R180** |
| Sim and hardware diverged on identical bitstreams | **R178** |
| Model 2 DOES have a perspective divide (R172 withdrawn) | **R174** |
| Walk and engine share port 4 by taking turns | **R173** |

### THE PIPELINE, STAGE BY STAGE

    m2_geo           display-list walk, operand capture, geo_polygon_data (0x05),
                     geo_translate_write (0x0c), light source (0x0a),
                     texture parameters (0x06)
    m2_geo_engine    stream grammar, vertex links, triangle rope, normal kept
                     and ROTATED (transform_vector, not transform_point)
    m2_geo_xform     3x4 transform            } all byte-identical to Model 1's
    m2_geo_project   perspective divide       } and verified at 88,218 checks
    m2_geo_clip      view-space frustum clip  }
    m2_raster3d      quad store, sort, span fill, three band buffers

Proven in simulation at 30M instructions: **399 matrix writes, 553 objects
addressing the polygon ROM, 3,038 polygons, quads with four distinct vertices**,
and a buffer-RAM opcode histogram matching MAME to within one word of 1,936.

### WHAT IS STILL OPEN

1. **Why does the game emit geometry in simulation and not on hardware?** This
   is THE question (R178, R181). Everything else is downstream of it. The next
   step is a measurement, not a hypothesis: the boot bench already traces the
   CPU, so run it to the instruction where geometry first appears, record the PC
   region doing the emitting, and compare against the board's `cpu_ip`
   histogram -- currently ~35% of samples in a two-instruction poll at
   0x12B0/0x12B8, the rest around 0x18E98/0x18EA4.
2. **The fitter segfaults**, roughly every other run. Occupancy is NOT the cause
   -- Model 1 fits at 97% and passes nearly every build. Matching their minimal
   fitter configuration did NOT fix it either; that hypothesis is disproved and
   the cause is unknown.
3. **Lighting is half built.** The light vector and the rotated normal are
   captured; the two dot products, the diffuse/ambient scale and the clamp are
   not written. MAME's maths is in R174's neighbourhood and is small.
4. **Texture is not started** and M10K is 553/553. R180 is the plan.
5. **R144 is still live** and blocks R180: five requesters, one broadcast
   acknowledge, on the loader's write port.
6. **A -0.150 ns hold violation** on clk_sys, and HDMI setup varies by seed.
7. The sound board does not reset on OSD reset.

### THREE HYPOTHESES SPENT TODAY, ALL WRONG, ALL RECORDED

Each looked sound, each was adopted before it was measured, and each cost builds:

* **The fitter's crash rate is the physical-synthesis settings.** Matched Model
  1's minimal configuration; builds 24 and 26 crashed anyway with the same
  `Segment Violation at (nil)`. Settings restored. Cause still unknown -- and
  The point that Model 1 fits at 97% while this core crashed at 89% still stands and
  still says it is not occupancy. (Build 25 was separately an OOM kill of my own
  making, from running a 30M simulation beside the fitter; `Killed` and
  `Segment Violation` are different failures and I had been conflating them.)
* **The glyph cache can be halved to match its own rationale.** It cannot: 64 KB
  produces tile and glyph overruns on the board. The 30.8 KB "actually touched"
  figure was measured through the menu, and real scenes need more. Reverted.
* **R179's read-while-writing race is what stops the walk.** It is a real race
  and the fix is kept, but decoding did not return, so it was not the cause.

The pattern is the same in all three, and worth more than the findings: a
plausible mechanism believed before it was measured. The counter that settled
each one cost a single build; the guessing cost several.

### THE LESSON THAT COST THE MOST TIME

Three separate faults in one day existed ONLY in the gap between a bench that
answers instantly and hardware that does not: the edge-latched SDRAM port, the
multi-cycle acknowledge, and R179's read-while-writing race. **Every bench in
this tree acknowledges whenever a request is high, with no latency, no edge
semantics and no acknowledge width.** 88,218 checks pass against a memory model
this design does not have. That is one structural gap, not three oversights, and
it is the highest-value thing to fix in the test infrastructure.

The second lesson, from R177: **a reference is worth far more RUN than READ.**
Every earlier attempt compared our code with MAME's code and found agreement --
because they do agree. What disagreed was what reached the front door, and only
running MAME on the same ROMs and diffing the data could show it.

## THE 3D PIPELINE IS CONNECTED

`Model2.sv`'s `.q_valid(1'b0)` is gone. The rasterizer has been wired and inert
since R124 and now has a producer:

    m2_geo          the display-list walk, ours
      | object_data
    m2_geo_engine   the stream grammar: vertices, links, triangle rope (R171)
      | transform_point + apply_focus -> VIEW space
    the quad projector   four vertices through m2_geo_project, one at a time
      |
    m2_geo_clip     frustum clip in VIEW space; vertices it creates go back
      |             through the SAME projector
    q_*             m2_quad_store / m2_raster3d

Flat colour, no texture, no lighting -- shape first. `m2_raster3d` takes one
24-bit colour and has no texture input at all, so this is the natural first
target rather than a simplification to undo later.

**Verified in simulation, NOT YET SEEN ON HARDWARE.** A build with all of it is
running as this is written. The geometry suite is 88,181 checks / 0 fails:
xform 7,813, project 20,037, det 12,007, rsqrt 30,186, norm 16,100, clip 2,003,
walker 32, engine 15, integration 20. Boot bench PASS, `lint_top` clean.
Pre-geometry fit for reference: **33,195 ALM of 41,910 (79%)**, block memory
68% -- the geometry's own cost is not yet known.

### R172 WAS WRONG, AND THE BENCH CAUGHT IT BEFORE THE BUILD

R172 read `geo_parse` to its end, saw it finish at `apply_focus`, and concluded
Model 2 has no perspective divide -- that a vertex leaves the geometrizer
already in pixels. It does not. `model2_3d_project` (model2_v.cpp:656) divides
x and y by `pz`, and the clip before it is a **view-space frustum**, not a box
test on pixels. The divide simply lives in the rasterizer rather than in the
geometrizer, which is why reading `geo_parse` alone does not show it.

So the shape is Model 1's shape after all: transform, focus, frustum clip,
divide, screen. `apply_focus` plays the part Model 1 gives to zoom, one stage
earlier -- that is the entire difference. `m2_geo_project` fits unmodified with
`zoom = 1.0`, `view = 0`, `xc` absorbing `crtc_xoffset + center[0]` and `yc`
absorbing `(384 - center[1]) + crtc_yoffset`.

**How it showed up.** Every stage passed its own bench. The error was in the
JOIN, and it appeared as the clipper accepting a polygon and then neither
emitting nor dropping it: `clip in=1 out=0 dropped=0`. Fed pixel coordinates, a
frustum test `p.x < p.z * a_left` compares a column against a slope times a
depth and the polygon is neither in nor out of anything meaningful. **On
hardware that is a black screen -- indistinguishable from the geometry never
running at all**, which is the state this core spent four days in for an
entirely different reason.

Cost: one module, `m2_geo_screen`, deleted. Nothing reached hardware.

A second, smaller lesson from the same bench: its first working version broke
its run loop on the engine's `busy` and reported "no quads" for a pipeline that
had simply not finished four 29-cycle reciprocals yet. **A bench measuring its
own impatience reads exactly like a design that does not work.**

### PORT 4 HAS TWO READERS AND THEY TAKE TURNS (R173)

The walk reads bufferram; the engine reads the polygon ROM. That is the R167
shape that cost four days. They do not arbitrate -- `m2_geo` stops at every
`object_data` until the engine reports it drawn, which is what
`geo_object_data` does in the reference anyway (it does not return until
`geo_parse` has walked every polygon).

Two things about it worth keeping:

* `busy` rises the cycle AFTER `start`, so "wait until `!eng_busy`" falls
  straight through and the walk races back onto the port. `W_OBJW` watches busy
  go high FIRST, then come down.
* `m2_geometry.busy` means the WHOLE pipeline, not the engine. The engine
  finishes long before four reciprocals and the clipper do. `q_end` rides on it,
  and an early `q_end` throws away whatever was still in flight at frame end.

`dbg_p4_clash` counts cycles where both request anyway. If the interlock is ever
wrong that is a number, not a subtly wrong picture.

**`tb_m2_geo` deadlocked at the first `object_data` the moment the interlock
went in**, because it drove one requester where the design has two. That is the
right failure -- it proves the wait blocks -- and it is the THIRD bench here
with that blind spot. **R144's shared write port is the one still live: five
requesters, one broadcast `ldr_wr_ack`.**

### WHAT TO READ OFF THE UART FIRST

The 'H' record now carries the geometry instead of the TGP's loop counts:

    b_addr   objects to ROM : PRAM0 : PRAM1 : objects hitting MAX_POLYS
    b_data   clipper in : out : dropped : quads reaching the rasterizer

The first three separate **"the geometry is broken"** from **"every object this
game draws lives in a polygon RAM that opcode 0x05 has never filled"**. Those
are the same black screen and need completely different work. Read them before
changing anything.

`geo_polygon_data` (opcode 0x05) is NOT implemented, so a PRAM object reads
unwritten SDRAM -- `0xFFFF...`, whose low two bits are 3 and never terminate.
`MAX_POLYS = 4096` stops that becoming a 2.5-second frozen picture per object;
`dbg_capped` counts objects that reach the ceiling.

### WHAT IS STILL CONSTANT AND SHOULD NOT BE

* **The viewport.** `xc/yc = (248,192)` and the four clip slopes are hardcoded
  for a 496x384 screen. Model 2 sets the centre and viewport with rasterizer
  commands the core does not capture, and the CRTC sync registers offset them.
  A game that moves its viewport draws to the wrong place -- visibly.
* **The colour.** `flat_col = 0xC0C0C0`.
* **The sort key** is min-z over the four vertices; `zsort_mode` is ignored.

### THE NEXT PIECES, IN ORDER

1. Read the UART counters on the running board. Everything below depends on
   which of them are non-zero.
2. `geo_polygon_data` (0x05) if PRAM objects are what Daytona uses. Route it
   through the walker's EXISTING `sd_wr_*` output -- do not add a sixth
   requester to R144's broken write port.
3. `geo_window_data` (0x03) -> real viewport and clip planes.
4. Lighting, then texture. `m2_geo_color` is NOT ported; Model 2's differs.
5. The other three parsers: `np_s`, `nn_ns`, `nn_s`.

## WHERE THE MACHINE IS

**IT RUNS.** The coprocessor completes commands, the mailbox handshake cycles,
and the game executes on hardware for the first time.

On the card: seed 1304, +0.376, kept as `Model2.rbf.r167`.

    $0x4a             00000000    was FFE5CB2F garbage
    tgp_pc            372 distinct, reaching 004C, 046E/F, 04C3/04C4
                      -- dispatch, mailbox arm, mailbox CLEAR
    cpu_ip            655 then 717 distinct addresses
    in the mailbox poll  ~2% of samples, was 99%
    mailbox clears    8 then 5 per window, cycling continuously, no lock

## THE FOUR-DAY FAULT: TWO OWNERS ON ONE SDRAM PORT (R167)

    p_req[9]  = tgp_dat_req_r | (geo_rd_req_r & ~tgp_dat_req_r);
    p_addr[9] = tgp_dat_req_r ? (copro address) : (geo address);

The coprocessor's data reads and the geometrizer walker shared port 9. This
controller's interface is **one req/ack pair and one address per port**, so the
address moved under whichever transaction was in flight and the single
acknowledge could not say whose it was. The coprocessor retired its reads with
the walker's data -- garbage into `$0x69` (the display-list base) and `$0x4a`
(its count) -- and a garbage count is billions of iterations. Hence ~640x the
reference workload, 0.1 fps, and a lock with the i960 at 0x1166C.

**It could only bite while both owners were active.** The walker has run since
`f716321`; the coprocessor only began issuing real reads with R151 and R162.
The bug did not exist until the coprocessor started working, which is why four
days of hunting never found it.

An OSD toggle settled it without a build: geometrizer walk OFF cured it
outright. The fix is **separate ports, not arbitration** -- the controller
already arbitrates between ports correctly.

    p_req[4]  = geo_rd_req_r;    the walker, alone
    p_req[9]  = tgp_dat_req_r;   the coprocessor, alone

Port 4 was the SDRAM checksum sweeper, whose question is long since answered.

## THE THREE FIXES THAT GOT HERE, IN ORDER

  1. **R151** -- both FIFO pops stall their reader, as the reference does. Takes
     the coprocessor from idling forever to dispatching commands.
  2. **R162** -- `s_ack[g] = f_ack[g] | done`. The per-port acknowledge was a
     one-shot masked by `done`, so ONE missed pulse killed the port for ever.
  3. **R167** -- separate ports for the walker and the coprocessor.

Plus the **narrow half of R156**: gate only the Model 1 register window on the
bank, never the math units. The full R156 cost the tilemap.

## THE PATTERN, AND THE BENCH THAT IS OWED

Three shared-port handshakes wrong the same way in one day:

    R162   an acknowledge that was a one-shot
    R144   five requesters on one broadcast acknowledge   (STILL LIVE)
    R167   two owners on one port

**Not one was catchable by the suite, because nothing in it drives two owners of
a port at once.** A directed test -- two requesters, overlapping requests,
checking each retires on its own acknowledge with its own data -- would have
caught all three in a single run. That is the highest-value thing left.

## STILL OWED

* **R144** -- the shared WRITE port: five requesters, one broadcast
  `ldr_wr_ack`, and `m2_sdram_x2` passing address and data through
  combinationally. Same class as R167 and still live. It will bite when the
  walker starts writing display lists. Model 1's `b0c6785` is the precedent.
* **The multi-owner bench**, above.
* **`sw_*` behind `M2_SDRAM_SWEEP`** -- staged, not deleted. Its header must say
  that re-enabling needs a port assigned, since port 4 is the walker's now.
* **An OSD reset does not reset the sound board** -- it keeps playing. Same
  family as `bi_*` being tied to `mem_rst_n` rather than the game reset.
* **Model 1's dead cycle on owner change** for any port that ever gets two
  owners again.
* `mb86233_regs` still 46,966 fails on register 0x21.

## METHOD, PAID FOR EXPENSIVELY

* **Wait for the ROM.** 43.62 MB over ioctl takes ~90 s. Four builds were judged
  from captures taken at 15 s, read a core held in reset, and were reported as
  design failures. R157 and R158's premise were withdrawn for this.
* **The screen is not a clean instrument.** The tilemap is on-chip, so a stalled
  SDRAM leaves the last frame up. "Tiles present" and "no tiles" are not
  separable states.
* **One seed is not a result.** Seeds 803 and 804, identical RTL: 804 dead, 803
  running the game. Slack did not explain it -- 804 had the better margin.
* **Check Model 1 first.** It has the same coprocessor and it works. Its
  per-owner acknowledge qualification is the thing this whole session was
  missing.

## THE i960 IS NOT SLOW. IT NEVER WAS (R150)

The whole "our i960 pushes four commands a second where MAME pushes 144,000"
story was an artefact of MAME's port multiplexing. `copro_fifo_w` is both the
command FIFO and the microcode loader, chosen by `coproctl` bit 31 rather than
by address, so a watchpoint counts 2,024 program words as commands.

    MAME, up to the first mailbox poll   0x884000: 2055   0x880000:   78  = 2133
    ours, same point                     program:  2024   pushed:    109  = 2133

31 payload pushes + 78 function-port writes = **109, our exact number.** The
command stream is identical to the reference.

Also retracted with it: "pc never reaches 00a1" as evidence of a missed
dispatch. 00a1 is the `bl != bh` branch; for command 0x25 the reference does not
take it either. Our TGP was dispatching correctly all along -- `pc=030b
B=12802525 D=0000007d` was the CORRECT handler for command 0x25 (0x7d -> 0x30a
-> 0x30b -> 004c), visible in the logs before any change was made.

## THE ACTUAL FAULT, AND IT IS FIXED IN THE TREE (R151)

**Both FIFO pops stall their reader in the reference. Ours stalled neither.**

`gen_fifo.cpp:109-115` fires the on-empty callback BEFORE `return T()`;
`model2.cpp:193-209` binds those to `m_copro_tgp->stall()` and
`m_maincpu->i960_stall()`; and both replay the instruction (`m_IP = m_PIP`,
`m_pc = m_ppc`). Neither processor ever sees the zero. R146 read pop()'s last
line and missed the six above it.

The i960 side is what mattered. The ROM's protocol is synchronous -- push, push,
`ld (g11)[g12]` in the very next instruction, at 0x115a0, 0x115d0, 0x11558,
0x67d4, 0xf110, 0xf1a4, 0xf3d4 -- so **the FIFO read IS the wait**, and we were
answering it with 0.

    m2_copro.sv   assign stall = fifo_rd && !fout_valid;    // was 1'b0
    m2_copro.sv   m2_tgp #(.EMPTY_FIFO_READS_ZERO(1'b0))     // was 1'b1

The rule is directional and was over-generalised by 41199bf:
**writes never stall, reads always do.**

Measured, boot harness, BUFFERRAM=1, 20 M instructions, one variable:

                              before        after
    TGP sits at               pc 0055       pc 048f    <- the display-list handler
    distinct TGP pcs          150           456
    copro buffer-RAM writes   0             2
    dword 0x7FFC hits         0             2          <- THE MAILBOX, first time
    i960 held by the copro    0 cycles      7,960

0x480-0x4b0 is the vertex-copy handler (`rep #0xc`), and 0x48f is MAME's hottest
TGP address after the poll.

## THE MAILBOX HANDSHAKE COMPLETES (R153, R154)

**37 complete handshakes in a 20 M-instruction run, against zero before.** The
mailbox log shows the reference's own protocol cycling:

    cyc 196283999  0fff8 : ffff   tgp pc=046e    armed by the CPU's batch
    cyc 197513453  0fff8 : 0000   tgp pc=04c3    THE CLEAR
    cyc 202258059  0fff8 : ffff   tgp pc=046e
    cyc 202261913  0fff8 : 0000   tgp pc=04c3

**FOUR harness gaps, all on the copro/buffer-RAM path, all fixed.** None of them
was in the core; every one made the harness incapable of answering the question
put to it:

  1. buffer-RAM writes DISCARDED -- `bufw_data` used by nothing, `bufw_ack` tied
     high, while the CPU reached buffer RAM through the bridge into SDRAM
  2. buffer-RAM reads served from the DATA ROM -- `.dat_is_buf()` unconnected
  3. `dat_addr` truncated 20 bits -> 19
  4. **the copro data ROM was never loaded at all** -- `tb_m2_boot.cpp` loads
     main_data and the math tables and nothing at GAME_COPRO, so every read
     returned 0xFFFFFFFF

(4) was the display-list count. The TGP's init at 0x7CF reads that ROM to build
`$0x69`, the base every command is computed from (0x474/0x475/0x478). MAME has
`$0x69 = 0xFF800030`; ours came out 0x30 short, so the count at 0x47C came from
dword 0x1057 instead of 0x1087 and read 0xFFFFFFFF -- 4.3 billion iterations,
and 0x4BC/0x4C4 were never reached. ROMs are `mpr-16537.ic28` (low) and
`mpr-16536.ic29` (high), same interleave as main_data.

                              before        after
    FIFO in pushed            109           1,571
    FIFO out popped           62            548
    TGP retires               1,381         61,627
    distinct TGP pcs          410           812
    dword 0x7FFC hits         2             74
    display-list count        ffffffff      4, 12, 34, 70, ac, ...

The CPU reaches code it never reached: pages 0x0000e000 and 0x00013000 appear
for the first time, and 0xE20C is the caller of the mailbox routine at 0x11620.

**Correction to R151.** It guessed our coprocessor writes a non-zero mailbox
value. It does not: MAME writes the same 0xFFFFFFFF from the same instruction
(0x46F, source `$2`). `{0}` in that disassembly is the transfer type, not "write
zero" -- the zero at 0x4C4 is data-RAM `$0`.

## FIXED: THE MAILBOX CLEARS, AND THE COMMAND STREAM MATCHES MAME (R156)

    MAILBOX dword 0x7FFC:  00000000   -- what the game waits for
    command stream:        matches MAME for ALL 200 words captured
    display-list pointers: MAME's exact sequence, all 30 in order
    CPU:                   IP 000012b0, out of the poll entirely

**The fault was in `m2_tgp.sv`'s IO decode, not the mb86233 core.** The Model 1
register window was computed from the address alone and tested FIRST in the read
mux, so it beat the banked view:

    wire io_lo    = (io_addr[15:5] == 11'd0);      // 0x00-0x1f
    wire sel_radr = io_lo && (io_addr[2:0] == 3'd0);
    if      (sel_radr) io_rdata = copro_adr[radr_i];
    else if (sel_rom || sel_buf) io_rdata = dat_rdata;

The TGP init reads the data ROM at offset 0x10 (`mov (bx1)(e), d` at 0x7CF,
b1=0x10). That hit `sel_radr`, returned `copro_adr[2]` -- never written, so zero
-- and threw away the 0x30 the ROM had returned. `dat_req` fired anyway, which
is why the read looked right on the bus while the core got zero, and why the
count read at 0x1087 worked (`io_addr[15:5] != 0` there).

MAME installs the view over the whole 0x0000-0xffff AFTER the math units, and a
selected view hides what is under it. The microcode brackets its windowed reads
with `ldi #0x0, rf3` at 0x7C9/0x7D6. **Fix: `!win_en &&` on `io_lo` and
`io_mid`.**

                                  before          after
    d after the 0x7CF read        00000000        00000030
    dword 0x7FFC hits             74              340
    copro buffer-RAM writes       178             850
    MAILBOX dword 0x7FFC          ffffffff        00000000
    CPU at the end                IP 00011674     IP 000012b0
    time in the 0x11000 page      5.0%            0.7%

## R155 WAS WRONG ABOUT WHERE, AND THE TEST IS WHAT SETTLED IT

R155 blamed the mb86233 core. **`sim/tgp/tb_mb86233_core.cpp` had no run target
at all** -- the only rule naming it was `lint_mb86233_core`, which lints
`$(M1R)`, the read-only Model 1 clone, not our rtl/tgp. Wired up as
`test_mb86233_core` with directed cases for every `(e)` form into A/B/D/P,
including the literal opcode 0x1C1E3380 with `(bx1)` addressing: all pass. The
core was innocent, and that left only the wrapper.

The lockstep's transfer forms are `FORMS[] = {0, 3, 6}` -- all data-space.
**No external `(e)` form was ever generated**, which is why this survived.

## TEST STATE

Every TGP target passes, `test_mb86233_core` now included and actually run.
`mb86233_regs` unchanged at its long-standing 46,966 on register 0x21 (rf1),
still owed.

## THE 2:1 HANDSHAKE AUDIT: SAFE, AND THE RATIO IS WHY (R152)

A finding from Model 1: bringing its coprocessor to 2:1 broke the handshake
because the action fired on every cycle the request was held. Its `incremental`
branch states the rule -- **the action fires once, on the cycle the access
completes, so a held request cannot double-pop a FIFO.**

Reference-clone note: `main` and `wip-2to1` are BOTH `57ce77e`, the 2:1 WIP that
is black on hardware. **`incremental` is the live branch.** Rung 7, the 2:1 TGP
itself, is still uncommitted there.

Our `fin_push` and `fout_pop` carry no edge qualification and look exposed. They
are safe because `m2_cpu_bridge` registers `io_sel` on **clk_mem, which the top
level wires to clk_sys -- the coprocessor's own clock.** A select is one copro
cycle. The 2:1 crossing is inside the bridge, between clk_cpu and clk_mem.

Proof already in hand: `dbg_prog_words` and `dbg_in_pushed` both count per
select-cycle, and read 2024 / 109 against MAME's 2024 / 109. The harness models
the ratio (clk_mem 48, clk_cpu 24), so that is a live test. Doubling would read
4048 / 218.

**But one step of the chain would be a genuine bug at 96 MHz.** m2_sdram's
`ACK_HOLD = 2` says in its own comment that it exists so "requesters on a slower
synchronous clock see exactly one rising edge" and is "2 for a clk/2 requester".
At 100/50 that is exact. At 96/50 a 2-cycle ack is 20.83 ns against a 20 ns
period -- one edge or two depending on phase, a requester taking a stale ack for
its next access, which is Model 1's failure mode precisely.

The PLL is 100 MHz (`output_clock_frequency0("100.000000 MHz")`) and every
NUMBER is right for it: `phase_shift4` 5000 ps, `T_REFI(781)`, `ACK_HOLD 2`,
and Model2.sdc's own text. **Nineteen comments across four files still say 96.**
Model2.sv's clock declarations are corrected here with the consequences written
beside them; the rest are historical measurements or Kaneko16 references, which
genuinely were 96, and are left. This audit spent its first pass concluding
ACK_HOLD was broken, on the strength of a comment.

## MODEL 1 CONFIRMS R151 INDEPENDENTLY

`m1_copro_if.sv` on `incremental`: *"AN EMPTY RESULT-FIFO READ STALLS. THIS WAS
CHANGED TO RETURN ZERO ON 2026-08-30 AND REVERTED THE SAME DAY."* Their measured
failure: the V60 reads twelve results, gets zeros, stores them, and pushes
`00000000 x4` where the reference pushes four floats -- then *"fout fills, the
TGP halts, fin fills, the V60 halts."*

*"So both FIFO directions stall on empty, which is MAME's effective behaviour in
both."* Two projects, two processors, the same source, the same conclusion, a
week apart, neither aware of the other.

**It also reframes R151's named risk.** The fout/fin deadlock is a CONSEQUENCE
of returning zero, not of stalling: fout fills because a consumer that took a
zero never comes back for the real result. Stalling prevents it.

## NEXT STEPS, IN ORDER

1. **FIT AND FLASH.** There are now three unflashed RTL changes -- R151's two
   stall lines and R156's two decode words -- and the board has not seen any of
   them. One change per build still stands (R147), so decide the order
   deliberately; R156 is the one with the measured behavioural result.
2. **Run the boot sim longer than 20 M instructions.** The CPU is out of the
   poll at IP 000012b0 and tilemap scroll is still zero; the next question is
   what attract does with a working coprocessor.
3. **Generate the `(e)` transfer forms in the lockstep**, not just directed
   cases -- FORMS[] should be {0,1,2,3,4,5,6}.

## HOW TO REPRODUCE WITHOUT A FIT

    rm -rf obj_boot
    make test_m2_boot BOOT_BUFFERRAM=1 TEST_ARGS="+insn=20000000"

About 3.5 minutes. 20 M instructions is enough -- the i960 reaches the mailbox
poll well before it.

## TOOLING THAT NOW EXISTS

* **Ghidra decompiles the i960 ROM, headless.** The `ghidra_i960-master` SLEIGH
  module installed into the flatpak's user Extensions dir
  (`~/.var/app/org.ghidra_sre.Ghidra/config/ghidra/ghidra_12.1.3_FLATPAK/Extensions/i960`),
  with `Module.manifest` rewritten to `name=i960` -- the upstream file ships
  `name=@riscv@`, a build-time token that Ghidra rejects. Two gotchas: the
  project path **must not contain a dot-prefixed element** (headless refuses
  `~/.var/...`; use `~/ghidra-m2work`), and the ROM must be interleaved first --
  `epr-16530a.12` is the low word, `epr-16531a.13` the high, two bytes at a
  time.
* **MAME's `dasm` command** dumps either CPU's disassembly without a trace:
  `dasm out.txt,0x11000,0x1000,1` for the i960, `,copro_tgp` for the TGP. The
  TGP must be dumped AFTER the microcode upload or it is 2,048 zeros.
* Both agree instruction for instruction, which is the check worth doing before
  trusting either.

## STILL UNPROVEN OR OWED

* **`mb86233_regs` fails 46,966 checks** on register 0x21 (rf1, the FIFO read) --
  byte-identical before and after this change, so pre-existing and untouched.
  Part of the TGP suite is RED and will mask a real regression until settled.
  Every other TGP target passes: `mb86233_mem/dec/xfer/seq/alu/agu`,
  `fp_mul/add/div`, all fails=0.
* **The black screen of 1a66f6ae is unexplained.**
* **The shared SDRAM write port has five requesters and one unqualified ack**
  (R144). It will corrupt display lists once geometry and copro results flow
  together.
* **The 20-bit copro data-ROM address and the FIFO write-ack change are built
  (seed 172, +0.394) but NOT flashed.**
* **Nothing downstream of the walker exists.** ~9,000 ALM free.

## STANDING LESSONS, PAID AGAIN

* **Read the function, not its return statement.** R146 quoted a true line of
  `gen_fifo.h` and drew a conclusion the six lines above it forbid.
* **Read the code behind the REFERENCE's instrument too.** R149 wrote "before
  any number is used as evidence, read the code that produces it" -- and R150's
  premise was then taken on trust from a MAME watchpoint whose port
  multiplexes two unrelated things. The rule was written down and skipped on
  the very next number.
* **A grep for `FAIL` matches `fails=0`.** Nine passing TGP targets were read as
  nine failures for a minute on exactly that.
* **One change per build** (R147). Still binding.

---

---

# EVERYTHING BELOW IS THE RECORD OF EARLIER SESSIONS

Kept because the reasoning and the measurements are worth having, but read it
against the sections above, which supersede it where they disagree. In
particular R149 retracts five conclusions drawn on 3 September from misread
instruments -- the coprocessor is NOT frozen, NOT deadlocked and NOT slow.

## THE COPROCESSOR WAS READING AN INVENTED MEMORY MAP (R133, R134)

`copro_tgp_io_map` puts the math units at 0x20-0x2b and everything else behind a
VIEW whose base -- and whose very existence -- come from AS_RF register 3:

    adr = (bank_reg & 0xff0000) | offset;
    if (adr & 0x800000) -> copro data ROM
    if (adr & 0x400000) -> bufferram, READ AND WRITTEN
    else                -> 0
    bank_w(d): bank_reg = d; if (d & 0xc00000) view.select else view.disable

This core stored rf 3 and **read it from nowhere**. The base came from writes to
io 0x2e, the target was chosen by OFFSET bit 15, the view was always on, and the
coprocessor could not write bufferram at all. Four inventions.

**Confirmed on the board:** `bank[23:16] = 0x40` -- bit 22 of the effective
address, which is exactly the bufferram case. The register is live and points at
the memory we never implemented. Every banked access ever made went elsewhere.

Neither instrument could see it. The opcode fuzz compares SEMANTICS; the i960
differential compares PROGRAM COUNTERS. **A processor can execute the right
program and still read the wrong memory** -- it produces wrong VALUES, not
divergence, which is the standing symptom: out_data = 0x42976767, a plausible
float, and hscr stuck at zero.

Fixed: rf 3 is the bank, the window derives from it, reads route by effective
address bits 23/22, and buffer-RAM writes leave on the shared write port.

## AND IT IS NOT ENOUGH TO ENABLE BUFFERRAM

The copro no longer hangs -- io flags went from 7FFC0008, stuck on a write, to
00000000 -- and the machine still does not reach attract mode with BUFFERRAM on.
BUFFERRAM therefore stays 1'b0.

Six explanations for that livelock have been proposed and killed by measurement.
What is actually established:

  * the mapping is correct: 106 checks, including the .mirror(0x60000) aliasing
  * the i960 is byte-perfect against MAME for **521,752 instructions** with the
    real I/O board in the loop (803,355 in the ROM harness)
  * writes landing are harmless; READS break it (builds 39 vs 40)
  * cache retention is not the cause (build 43)
  * simulation will not reproduce it, even at 30 M instructions

Next instrument: the i960's IP ring rather than a sampled IP. Sampling cannot
show a branch, and the branch is the question.

## THINGS THAT COST TIME TONIGHT, SO THEY DO NOT AGAIN

- **Port 9 was read-only. Making it read-write cost four seeds** (-0.253 ..
  -0.381, worsening) on the 96 MHz domain, worst paths `xfer_addr[19] -> cmd[0]`
  and `be_r[1] -> cmd[0]` INSIDE m2_sdram. Writes belong on the shared write
  port, which is idle during gameplay and outside the arbiter.
- **A write request must DROP between the halves.** A dword is two transfers and
  the port acks once; a held level is one request. `bi_` had it right already.
- **Land the part of a finding that has a CONSUMER first.** R133's read half is
  the correctness fix; the write half had no consumer (no geometrizer) and cost
  ~100 minutes of builds to discover.
- **READ THE FAILING PATH before changing a setting.** Twice tonight the path
  named a cause that contradicted the obvious theory.
- **Take the same reading on a WORKING build before treating it as evidence.**
  0x0163Fxxx looked like a smoking gun and appears identically on builds that
  boot fine.
- **Quartus fails about one build in three** here: STA
  `sta_assignment_db.h:468`, TDB `tdb_node.cpp:2080`, silent map exits, and OOM
  against a concurrent Model 1 build. A seed change has cleared every one.
- **`pgrep -f` matches other waiters' command lines.** Two build queues deadlocked
  on each other's pattern text. Use `pgrep -x` on the binary.

## THE COPROCESSOR RUNS. The halt was an unacknowledged read of IO 0x2e.

`m2_tgp`'s io_ack mux had `sel_datb ? io_wr`. That selector exists only to catch
the WRITE that sets `dat_base`; the read half was never written, so a read of
0x2e acknowledged never and the TGP held mid-instruction forever. Measured:
`io_addr=002e io_rd=1 io_ack=0`, frozen at `pc 0x0481` after exactly 21,325
retires. The fix is `sel_datb ? (io_rd || io_wr)` and it is **verified on
hardware** -- retires now climb continuously and the PC passes 0x0481.

The reference has no special case at 0x2e at all: it falls into
`copro_tgp_io_map`'s banked view, whose handler always answers and returns 0 for
a clear bank. Study R125.

**The FIFO-deadlock theory was wrong and is dead.** `out_popped == out_pushed`
with the i960's IP moving proved the outbound queue was EMPTY, not full. The
8 -> 128 deepening built to fix it bought 22 results and changed nothing --
though the M10K conversion it rode in on was worth 2,491 ALM.

## AREA: 2,491 ALM BACK, ZERO M10K BLOCKS

Both copro FIFOs are now `m2_fifo_m10k`, a show-ahead FIFO whose storage is a
block and whose head register keeps the combinational read the TGP needs.

    u_fin    ~1,500 ALM of flip-flops  ->  71 ALM + 4,096 bits
    u_fout   8 deep                    ->  128 deep, 28 ALM
    ALM      35,348 -> 32,757 (78%)        9,153 spare
    M10K     464 -> 465 of 553             both FIFOs packed into existing blocks

## THE 3D BACK END IS PORTED, NOT YET WIRED

    m2_raster3d     240   the band sequencer (ours)
    m2_quad_store   490   z-sort + per-band replay      Model 1 @ 085a00e
    m2_raster_fill  531   quad to spans                 152,025 quads verified
    m2_raster_div   157   signed restoring divide
    m2_raster_band  307   x3, 496x16, ~48 M10K

`q_*` -- a projected screen-space quad with colour and z -- is the seam, and it
is exactly what a geometrizer emits. **Model 1's geometry does NOT transfer**:
`m1_geometry`, its nine `m1_geo_*` submodules and `m1_listwalk` are fixed-function
RTL, and R128 settles by measurement that Model 2's is a real microcoded engine
(721,831 writes to 0x804000 per 900 attract frames). `m1_quad_store` DOES
transfer -- its `m1_geometry` mentions are comments.

Sizing: three band buffers are ~48 M10K against 88 spare, and Model 2 is 496x384
like Model 1, so the geometry transfers unchanged.

## BUFFER RAM IS MAPPED AND DELIBERATELY OFF (R129)

`0x00900000`, 128 KB, was routed to `T_IO` whose read mux ends in `32'd0` -- so
33,554 writes and 12,269 reads per 900 frames went nowhere. It is now mapped to
SDRAM at `GAME_BUFFER = 0x16f0000` and **disabled behind `BUFFERRAM` in
`m2_cpu_bridge`.**

It is off because it cannot land alone. That memory is the GEOMETRIZER'S
WORKSPACE: the game writes a structure, reads it back and follows it. Unmapped,
it read zeros and took a safe path (21,325 retires, attract cycling). Mapped, the
writes land, the game follows its own pointer, and with no geometrizer the i960
livelocks at IP 0x0E00-0x0E10 walking an unmapped 0x0163FBxx (1,367 retires).

Initialising to the reference's 0x07800f0f changed **nothing** -- byte-identical
telemetry -- which is what rules out the contents. Turn `BUFFERRAM` on in the
same change that brings up the geometrizer. The initialiser is kept and is
correct: 161 ALM, runs after `cal_done` because the self-test is the SDRAM
read-latency calibration.

## THE DEBUG UART WORKS OVER SSH -- NO CABLE (R121)

`/dev/ttyS1`, 115200. `UART_TXD` has no pin assignment; it is the HPS's own UART
bonded into the fabric. `stty -F /dev/ttyS1 115200 raw -echo && cat /dev/ttyS1`.
The standing rule "the screen is the only output channel" is superseded.

`/dev/MiSTer_cmd` reloads a core remotely:
`echo "load_core /media/fat/_Arcade/<x>.mra" > /dev/MiSTer_cmd`.

**A build that reads as broken gets rolled back BEFORE it is analysed.** Build 29
was left on the board while its telemetry was studied and the first report of it
came from the user, not the log.

## THINGS THAT COST TIME AND WILL AGAIN

- **The fitter crashes on exit and hits `Internal Error: STA,
  sta_assignment_db.h:468` at random.** Both are placement-dependent; a seed
  change has cleared it every time (builds 24 and 28). Run `quartus_map`,
  `quartus_fit`, `quartus_sta`, `quartus_asm` as separate steps.
- **Timing needs a re-seed roughly half the time** at this occupancy, on
  `pll_hdmi` or the SDRAM domain. Budget for it.
- **Concurrent Quartus builds OOM this machine.** 31 GB total and the Model 1
  project's memories take 15 GB; build 21 was SIGKILLed mid-fit and looked like
  a design failure until the exit reason was read.
- **A debug output that is driven and unread is not instrumentation.** Every
  copro `dbg_*` was tied off in `Model2.sv`; grep for a count of TWO to find the
  rest.

## BUILD 18 PASSES TIMING, AND IT IS ON THE BOARD

First clean build this project has had. `+0.203` worst setup, `+0.182` hold,
`TNS 0.000` on every clock. The SDRAM's 96 MHz domain went `-0.784 -> +0.396`;
what fixed it was registering the TGP's SDRAM request path, so `mb86233_agu`'s
adder no longer reaches `m2_sdram`'s arbiter mux combinationally.

    35,147 / 41,910 ALM   (84%, 6,763 spare)
    3,434,570 / 5,662,720 memory bits (61%)
    45 / 112 DSP

Deployed and md5-verified. `Model2.rbf.good` is untouched; `Model2.rbf.prev`
holds the rollback. It also carries the fix for the hardware freeze -- `stall`
tied to zero in `m2_copro`, because holding the i960 on the copro froze the
machine outright (black tilemap, no "insert coin", stuck on screen 1).

**The M10K block count is still unknown.** `fit.rpt` is not written, because the
fitter crashes on exit (already documented below) -- `fit.summary` survives and
gives bits, not blocks. Blocks are the binding resource, so this number is still
owed. `tools/fit-numbers.sh` archives whatever a build does produce.

## THE DEBUG UART WORKS OVER SSH -- NO CABLE (R121)

`/dev/ttyS1` on the board, 115200. `UART_TXD` has no pin assignment anywhere;
it is the HPS's own UART bonded into the fabric. Time was spent believing this
needed hardware attached.

    stty -F /dev/ttyS1 115200 raw -echo && timeout 8 cat /dev/ttyS1

**The standing rule "the screen is the only output channel" is superseded.** The
board is programmatically readable now, so telemetry can be counted and diffed
against MAME instead of photographed.

## THE SCROLL FAULT IS IN THE COPRO's RETURN PATH (R122, R123)

Layer 2's `hscr` measured `0000` across 52 samples / ~480 frames on build 18.
Everything else is excluded: the i960 profiles like MAME (66% in the frame-sync
spin against MAME's 69.2% -- that spin is *correct*, see R122), the tile fetcher
honours the register, the decode is right (R106), the function port is decoded
and the TGP runs the reference's program (R120), timing passes, the CPU is never
held. The reference visibly scrolls the ground here, so the expectation is firm.

Every counter that could name the failing half was **tied off** in `Model2.sv`.
Build 19 (in flight) wires them to the UART:

    C <in_pushed:out_pushed>  <retires:pc>
    H <out_data>  <hscr2:in_drop:out_drop>

in climbing / out flat = a TGP that consumes and never answers. Both flat = an
i960 that never issues. Drops moving = the 128-deep queue losing commands.

## THE RENDERER BUDGET, AND A SECOND PROCESSOR WE HAVE NOT BUILT (R124)

`model2.cpp` maps a **geometrizer** at `0x800000`/`0x804000` -- separate from the
copro TGP, its own microcode upload, ~21 opcodes, four polygon-transform loops.
None of it exists here. Model 1 has the same split (`m1_tgp` *and* `m1_geometry`).

So the renderer comparator is `m1_raster3d`'s **6,977 ALM** (geometry + list walk
+ sort + fill + band buffer), not `m1_raster_fill`'s 2,113 -- against 6,763 spare.
Tight, not comfortable. Before designing any of it, settle whether `daytona93`
ever calls `geo_code_upload`: hardwired transform loops if not, a real microcode
engine if so, and that roughly doubles the cost.

Two ways to buy room: the copro input queue is async-read (flip-flops, ~2,000 ALM
for 128 entries) and belongs in M10K; and sound-board work RAM is 524,288 bits of
M10K against a band buffer needing ~522,240.

## SOUND WORKS. Music and voices both.

Four faults, found in this order, and only the last one was audible as itself:

1. **`uart_irq` was connected to nothing** (R87). The line 10 interrupt handler
   IS the transmit loop -- Daytona never reads the i8251's status, so nothing in
   the mainline waits for the transmitter. Symptom: the eleven CONTROL writes
   happen and none of the forty-eight DATA bytes do, which reads as a broken
   data path rather than a missing interrupt.
2. **VPA tied high** (R90). A 68000 whose VPA never asserts runs a VECTORED
   acknowledge, reads 0xFF off an unmapped bus and jumps through vector 255.
   39.9 million bus cycles of line-1111 exception, never reading its UART.
3. **A 19-bit port driving a 22-bit wire** (R94). The sample ports became bursts
   and `Model2.sv` was not updated with them, so both chips read the wrong
   address AND the wrong byte. This is the one that made it unlistenable for
   four builds, and `make lint` never linted the top level at all.
4. **System 32's banking on a Model 1 board** (R95). `segam1audio` gives each
   MULTIPCM a 2 MB space whose upper half is one of four 1 MB pages; the
   vendored core banks 512 KB pages with a three-bit selector. Music sits below
   1 MB and was right all along; the voices sit above it and came out as a
   foghorn.

**`lint_top` now exists and was written by reintroducing bug 3 and checking
Verilator names it.** A guard that does not catch the bug it exists for is worse
than none, and that is only knowable by trying it.

## M10K: 95 BLOCKS BACK, 96% -> 79%

One write port and two read ports is not a shape Quartus 17.0 infers a true
dual-port memory for -- it silently replicates the array once per read port.
`m2_tdp_ram.sv` wraps `altsyncram` in `BIDIR_DUAL_PORT`; both ports must be the
same width or replication returns. R96 and R97.

    tram + palette   -79      m2_backup   -16      total 438/553
    m2_ioboard dp_*  ~2 available, not taken
    m2_char_cache    128 is its REAL size, not duplication

**`OLD_DATA` read-during-write is not supported on Cyclone V M10K in that mode**
and Quartus says so with Error 14000. `DONT_CARE` is a real behaviour change and
R96 states where it can be observed.

## FOUR INSTRUMENTS WERE LYING, AND ALL FOUR COST TIME

- **`Model2.fit.rpt` is not rewritten when the fitter crashes on exit.** It was
  SEVEN HOURS older than the `.rbf` beside it and still listed arrays that had
  been removed. `Model2.fit.summary` is the file to read.
- **Even `fit.summary` can be pre-crash.** The fitter can report Successful and
  still not commit its database; the assembler then refuses with "Run Fitter
  before Assembler" and `output_files/Model2.rbf` is left as the PREVIOUS build
  with a fresh timestamp. **The only trustworthy signal is a changed `.rbf`
  md5**, which the build script now checks and reports.
- **The boot sim ran with its I/O board unplugged and looked completely
  healthy.** `M2_IOFW` was unset, so the Z80 never cleared the DPRAM request
  flag and the i960 sat in the two-instruction spin at `0x228240` polling
  `0x01c00040`. A 24-million-instruction run printed a full, internally
  consistent cycle profile having executed **none of the game** -- 97.8% of
  every retired instruction in one 4 KB page of work RAM. It was nearly read as
  proof that the tilemap scroll is never written. R105.

  Two things came out of it. The firmware now **defaults** to `epr-14869c.25`
  beside the program ROMs, and a missing one warns by naming the spin rather
  than booting into it -- `make test_m2_boot` had been running without it and
  reporting FAIL, and now passes. And the boot sim prints a **4 KB-page
  histogram of every retired PC**, with `M2_BOOT_PCHIT=<addr>` to count a single
  address. A stalled boot is invisible in a cycle profile and obvious in the
  histogram: one page at 97.8% is a spin, a healthy boot spreads over a dozen.
  **Read the two together or the profile can be entirely real and mean nothing.**
- **`lint_top` was reporting on a fraction of the design and not saying which
  fraction.** Verilator exits at the first missing module, and `hps_io` (in
  `sys/`) and the PLL (a `.qip`) were never passed in -- so it ended on
  MODMISSING and every check needing full elaboration was skipped. Parse-time
  warnings survived, which is why it kept saying "no port width mismatches"
  truthfully while never having examined the design as a whole. It was missing
  four undriven signals feeding SDRAM ports 8 and 9. Fixed by naming
  `sys/hps_io.sv` and `rtl/pll/pll.v`, black-boxing the vendor `altera_pll` in
  `sim/lint/`, and adding UNDRIVEN to the filter. R107. **`make lint` now fails,
  correctly, until the coprocessor is wired.**

## INPUTS: THE WHOLE CABINET IS WIRED

`model2.cpp`'s `daytona` map is `model2` plus `gears`. Coin/Start/Test/Service
were wired; the four VR buttons, the gearbox and every analog axis were not.

Buttons are ordered by what is needed FIRST, not by the cabinet's numbering --
VR1 Red and VR4 Green are the service menu's down and up and the board cannot be
navigated without them, so they sit at 5 and 6.

The gearbox is a STATE, not a button: `daytona_gearbox_r` returns
`{0,2,1,6,5}` for N,1,2,3,4, deliberately not a binary count, because the real
shifter is microswitches whose pattern the game reads. Gear Up/Down step the
positions and that table converts.

### OPEN: the coin does not credit

Free play reaches game select, so the game is fine. Measured: the button reaches
IN0 bit 0 (the core counts the edge), IN0/IN1 idle correctly at FF/8F, and NVRAM
is live. MAME says a coin changes exactly ONE DPRAM byte, FF -> FE -- the Z80
publishes the raw input scan and the **i960** does the crediting.

A tap on every non-idle Z80 publication is built and NOT YET FLASHED. It
deliberately does not assume the address: R65 records `in0` at DPRAM byte 0x08
and a MAME write tap shows the coin at byte 0x10, and those cannot both be right
under one arithmetic -- MAME's device is umasked to bytes 0 and 2 of each dword,
so a linear byte index is not a word index.

## THE TILEMAP SCROLL IS CORRECT, AND IT IS WAITING FOR THE CAMERA

The sky and treeline sit still. They are supposed to, for now. R105.

- **Nothing is hardcoded.** `m2_video` fetches hscr/vscr per layer per line from
  tile RAM `0x5000`/`0x5004`, exactly as `segaic24` does, and
  `m2_tile_decode` implements the arithmetic correctly.
- **Only ONE layer ever scrolls.** MAME writes all eight words every frame from
  a routine at `0x1a164`, and layers 0, 1 and 3 hold zero for the whole of
  attract mode. Three still layers is the game, not a fault.
- **The path is proven by a match, not by inspection.** `dbg_hscr[4]`/
  `dbg_vscr[4]` latch what the renderer actually consumed. This core reports
  layer 2 `vscr=2000`; MAME reports `v=2000` at the comparable point --
  including bits 14:13 = 01, which is window mode, not scroll. A tied-off
  register cannot produce `0x2000`.
- **What is missing is the heading.** Layer 2's horizontal pan is zero until
  MAME frame 165 and first moves on the exact frame the 3D driving demo replaces
  the settings text page, then climbs `0008 0009 000a 000c 000d 0010 0013 0018`
  -- a camera turning, once per frame. With the coprocessor stubbed there is no
  camera, so the game computes zero and the horizon correctly does not move.

**No work in `m2_video` will move that layer.** It comes back with the geometry.

### PROVEN, not inferred -- and this core already matches the reference

R106. Leave the copro booted and running, zero only the values the i960 pops out
of its FIFO, and the game keeps drawing (70,378 tile writes at f200 rising to
134,978 at f400 -- no deadlock, flow control untouched). What changes is only
what was computed from copro results:

    baseline            L2 hscr = 000c 0018 001b 0197 016e 007d   vscr = 2fe1 ... 2009
    copro results = 0   L2 hscr = 0000 0000 0000 0000 0000 0000   vscr = 2000 ... 2000
    THIS CORE           L2 hscr = 0000                            vscr = 2000

**MAME with its coprocessor results zeroed produces our numbers exactly, on both
registers.** The 2D path is not merely plausible, it agrees with the reference
under matched conditions.

A first attempt was confounded and is kept as a warning: holding `copro_ctl1`
bit 31 set does not just halt the TGP, it is the SELECTOR, so every FIFO write
goes into program RAM instead. Daytona freezes at 41,451 tile writes around
frame 70. True, useful (the game will not proceed at all without the copro), and
worthless for attributing the scroll.

**This gives the TGP a free acceptance test.** Layer 2's `hscr` is one 16-bit
number written once a frame that is identically zero without coprocessor output
and moves the moment it becomes real. No framebuffer diff, no rasteriser needed
-- `hscr` leaving zero is the first evidence the TGP works, and the baseline row
above is the shape it should take.

## THE COPROCESSOR IS WIRED IN (not yet run on hardware)

`m2_copro` existed, was committed, and was connected to nothing: not
instantiated in `Model2.sv`, not in `Model2.qsf` -- **no build ever flashed has
contained a line of TGP** -- and it did not pass the TGP's `tbl_*`/`dat_*`
through, so `tbl_ack` was unconnected and the first sincos lookup would have
hung. All three are done, plus the math-table byte order verified against
MAME's own `copro_tgp_tables` region (opr-14742a is bits 15:0, opr-14743a is
31:16 -- the `.mra` interleave was already right).

**Wiring it woke two latent SDRAM bugs, and the undriven signals were the only
thing that had been suppressing them.** R108.

1. **The read tag is 3 bits and there are 10 ports.** Ports 8/9 aliased onto
   0/1 -- TGP table reads delivered into the i960's port and acknowledged there.
   Fixed at both the declaration and the assignment that truncated (`grant[2:0]`);
   widening one without the other does nothing.
2. **`rd_total` is a single global register, so ports may not have different
   burst lengths.** A grant mid-issue overwrites it and the earlier transaction
   completes at the wrong word. Port 0 came back with two of four words and
   zeros above. NOT fixed -- ports 8/9 burst four like everything else, which
   makes it unreachable, and the constraint is written into `blen()`. **A port
   with a different burst length reintroduces silent cross-port corruption.**

`tb_m2_sdram` now drives all ten ports; it drove five while `blen()` had had ten
entries for as long as the core had had ten ports. A configuration that exists
only in the DUT is covered by nothing.

### What is NOT yet verified

- The copro is **not in the boot harness**, so the integration is unsimulated:
  program upload, FIFO handshake and the TGP actually retiring have not been
  seen end to end. The 10 TGP unit suites and the SDRAM suite pass; the join
  between them has not been exercised.
- **Fit is unknown.** The TGP is a whole processor and no `quartus_map` has been
  run with it in. Per rule 11 that is a study-level number, not a detail.

### The two acceptance tests, in order

1. **Layer 2's `hscr` leaving zero.** One 16-bit number, written once a frame,
   identically zero without coprocessor output (R106). First sign of life, and
   it needs no rasteriser.
2. **The service menu's own TGP test.** The real verdict.

## STILL OPEN, in the user's priority order

1. ~~Sound~~ and ~~M10K~~ done.
2. **The coin credit** -- diagnostic built, awaiting a flash.
3. **The three-minute CPU slowdown.** R93. 24.0 CPI slow against 7.5 settled,
   and scene 1 is slow ONLY on first boot -- returning to it later it runs full
   speed, so it is one-time state cleared by the first attract transition, not
   that scene's content. The `ipring` wiring is written: 512 retired IPs have
   been recorded into M10K since the design was built and `ipring_q` was never
   consumed by anything.
4. **3D.**
5. Boosted CPU clock if still slow.

## SOUND: THE LINK IS BYTE-EXACT ON HARDWARE, THE 68000 RUNS THE REAL ROM

Two independent results, both measured, neither an impression.

**The serial link is proven on the board.** 59 port writes, 48 data bytes, and an
order-sensitive rotate-xor signature of **0x6AE52ED8 — identical to MAME's**. A
count would not have been enough and neither would a sum or an xor: this is a
command protocol, so order is all of it.

It sent ZERO bytes for a whole build cycle, and the cause is worth keeping.
`uart_irq` was driven and connected to nothing. The symptom points the wrong
way — the eleven CONTROL writes still happen, because those are mainline
initialisation, and not one of the forty-eight DATA bytes ever does, which reads
as a broken data path. Daytona NEVER reads the i8251's status; a read tap over
900 frames of attract mode fires zero times. **The line 10 interrupt handler IS
the transmit loop.** Both of MAME's triggers are needed — the TXRDY edge alone
never starts, because after the command byte enables TxEN the transmitter is
already free and there is no edge left to catch.

Three counters found it in one measurement where reasoning had failed twice: is
the address selected, does a data write reach the device, does the link take the
byte. 11 / 0 / 0, and 11 is exactly MAME's control-write count.

**The sound 68000 runs 72,035 of MAME's own instructions**, fx68k on the real
256 KB ROM, locked step against a debugger trace of `:m1audio:sndcpu` from reset.
It stops on the YM3438's timer B flag, which the firmware's main loop sequences
music on — the hardware not existing yet, not a defect, asserted as a floor for
the real chip to raise. Study **R87** has the map, the ROM layout, and the three
walls found along the way.

### What is next, in order

1. **YM3438 (jt12)** — the timer B flag at `0xD00001` bit 1 is the exact thing
   blocking instruction 72,036. This is the highest-value next piece.
2. **Two MULTIPCMs** — currently stubbed to "not busy", which is the minimum
   that lets the board boot.
3. **A sixth SDRAM port** for the sound ROM. All five are in use. Simulation
   serves the ROM port directly, so the CPU was provable without it.

### Sound M10K, and ~80 blocks that are recoverable

Currently 449/553 (81%). The largest memories are the glyph cache at 128 and
the tilemap at 128, and **the Model 1 project measured that half of a tilemap
like ours is CPU/video duplication** (`82fb928`): Quartus 17.0 silently
replicates a one-write-two-reads array rather than inferring a shared true
dual-port, and refuses the TDP template outright with Error 276001. Ours has
exactly that shape — video reads `tram_data`, the CPU reads and writes
`cpu_tram_q`. **~64 blocks from tram and ~15 from the palette, for an explicit
altsyncram.** That is a better lever than shrinking the glyph cache because it
costs no hit rate. Not yet attempted here.

## ATTRACT MODE RENDERS, AND ANIMATES

Daytona USA's attract screen draws on the DE10-Nano from the real i960 running
the real game code, with the real Z80 I/O board firmware, and the INSERT COIN
prompt blinks. map 2 holds 1,356 distinct artwork tiles against MAME's 1,274.

### The blocker was a byte store landing in all four lanes

The i960 replicates a stored byte across the word and relies on the byte
ENABLES to pick a lane -- correct i960 behaviour -- and every lane was written.
So the loop count at work RAM 0x501084 read 0x27272727 instead of 0x27.

0x27 is 39, exactly MAME's value and exactly the passes simulation makes. At
nine instructions a pass and 1.16 M instructions/s, 656 million passes is about
85 MINUTES. That is why the screen appeared after a night and never sooner, and
why a restart always lost it. Never intermittent -- arithmetic.

Every hop that carries the enables verifies: the CPU asserts be=0001, the bridge
forwards be=01 (measured on the board), the x2 adapter passes them through, the
controller drives sd_dqm = ~be, the pins are assigned and constrained, and
simulation gets all four lanes right against the device model. Bypassing the
data cache changes nothing. That leaves the SDRAM module -- DQM tied low is
common on these boards and would look exactly like this, invisible to every test
we own because they all test the FPGA.

**The Model 1 project reached the same conclusion independently**, on the same
hardware: its newest commit is "Read-modify-write partial SDRAM writes: no byte
mask reaches the device".

So partial writes now read, merge in the fabric, and write back full width. No
mask reaches the device. Costs 2.3%. Study R82/R84.

### Also fixed this session

| what | measured |
|---|---|
| I/O board DIP multiplex (R76) | the firmware throws that switch 24,948 times a minute; we answered with controller state |
| MSM6253 shifted a bit early (R77) | every analog byte was doubled; scan output now byte-identical to MAME |
| glyph cache had NO invalidation | added, per-line -- it served pre-upload zeros |
| glyph cache indexed an always-zero bit | half the M10K was unreachable; 61.4% -> 82.6% |
| glyph cache line was half a burst | 82.6% -> 93.56%; overruns 27.1 -> 6.99 per frame |
| CPU had no data cache | 2 KB at 99.57%, sized from an 813,751-address trace |
| bridge crossed 48/24 with synchronisers | same PLL, exact 2:1 -- halved. CPI 22.67 -> 17.16, 1.32x |

`tools/i960-datadiff.sh` now reports tile RAM, char RAM and palette all
**IDENTICAL to MAME**, byte for byte.

### Sound: started

The serial link between the main board and the sound board is built and
verified against MAME's own byte stream (it emits exactly 59 bytes over attract
mode). daytona93's sound board is the MODEL 1 board -- 68000 + YM3438 + TWO
MultiPCMs -- not the SCSP the study budgets. Sized by synthesising each
candidate standalone on this part:

    fx68k                2,100 ALM   6 M10K   already in tree
    jt12 (YM3438)          777 ALM   8 M10K   meathax/s32, GPL-3
    s32_multipcm x2      4,484 ALM   0 M10K   meathax/s32, GPL-3
    68K work RAM 16 KB       ~0     13 M10K
    total               ~7,660 ALM  ~27 M10K

Study §5.5 budgets 4,164 for "SCSP + 68000", which is the wrong board and 3,496
ALM light. The risk moves the other way: §5.3 calls sound "high risk -- must be
written", and for this board the cores exist and are licence-compatible.

### Open

- **The pixel-exact frame test fails by 173,299 of 190,464 pixels**, identically
  with two line-buffer banks and four, so it is pre-existing. The data feeding
  it is byte-perfect, so this is the renderer or the comparison's frame
  alignment. Best-posed open question.
- ~7 overruns per frame remain (1.8% of lines). Four line buffers were written
  and PARKED: m2-framediff.sh measures burstiness at 1.87x against its own 2x
  threshold for "buffering helps", and 8.3% memory wait is not a starved engine.
  Parked copy in the scratchpad; R85 records the counter bug it must fix first.
- Core sequencing is now 8.23 of the 17.16 CPI -- memory is no longer the
  majority cost.

### Instrument failures this session, because they cost more than the bugs

Five, all the same shape -- the instrument answered a different question than
the one asked:

- a capture whose payload was not gated by its own strobe: 128 lines of a flag
  poll wore a window read's clothes
- a channel firing thousands of times a second starved the prioritised one to
  zero, which read as "the game never touches the window"
- a per-write census sampled one write per burst, always the first: 99.81% zero
  where a counter said 35% non-zero
- a self-test that hijacked port 2, which the copy engine owns, and BROKE THE
  BOARD
- a saturating counter read as a rate: "overruns have stopped" when they had not

**Standing rule: prefer a counter in RTL to a sampled stream, and never take a
port another master owns.**


## THE ATTRACT-SCREEN HUNT: two real faults found and fixed on hardware

Both were found by measuring the SAME FIRMWARE on both machines and diffing
the bytes, not by reasoning about either. Simulation was not the oracle here
and could not have been -- it renders the attract screen with the same RTL
that fails on the board.

**1. The I/O board's ports are multiplexed, and we implemented one side.**
Port A bit 0 of the 315-5338A is a control switch: clear, PB/PC/PD carry the
cabinet controls; set, they carry the board's OWN three DIP banks, and the
analog channels swap banks with it. We always returned the controls. The
firmware itself proves the mechanism -- EPR-14869C has a matched pair of
routines at 0x07F9 (`AND FEh`) and 0x0807 (`OR 01h`) writing `(IY+0)` -- and on
hardware it throws that switch **24,948 times in 60 seconds**. Study R76.

**2. The MSM6253 shifted a bit early, so every analog byte was doubled.**
R65's "ADC off-by-one", with a mechanism at last. The old code emitted
`adc_shift[7]` combinationally and shifted on the read's TRAILING edge -- two
events that must agree exactly once per read, and did not. Eight independent
bytes showed one relationship, `value << 1`:

    DPRAM   board  MAME   fed in
    0x00     00     80    0x80    steering
    0x01     40     20    0x20    accelerator
    0x04-07  FE     FF    0xFF    the secondary bank

Bound capture and shift to the SAME edge, as the reference does. Study R77.

### What that bought, measured on the board

| before | after |
|---|---|
| scan area disagreed with MAME on every analog byte | **byte-identical** at every address the firmware writes |
| settings block written with only `7F`/`FF` | **all 29 sampled offsets match MAME's block exactly** |

### What is still open

The firmware pre-fills the settings block with **`0x7F` where MAME fills it
with `0xFF`** -- one bit, PG bit 7, which is the EEPROM data line. MAME does
the same two-pass fill (frame 7 all-`FF`, frame 10 the real block), so the
sequence is right and only that bit differs. Whether the attract screen now
renders was NOT established before this was written; the correct block content
reaching the game is necessary, not proven sufficient.

Standing instrument rules earned this session, all three the hard way:
- **Gate a capture's payload by the same condition that raises its strobe.**
  Assigning it unconditionally made a trap print an unrelated address, and 128
  lines of a flag poll nearly became a finding.
- **Telemetry that fires constantly must be a HEARTBEAT carrying cumulative
  counts.** A channel firing thousands of times a second starved the
  prioritised channel to zero -- priority only applies when the UART is idle.
- **Verify the deployed md5 against `output_files/` every time.** The deploy
  copies `build/release/`, and `make release` had not been re-run, so a core 25
  minutes stale was measured and briefly believed.

---


---

## STATUS: what is PROVEN, and by which test

Every claim below names its evidence. A claim without a test is not in this
table.

### i960 CPU — working, verified against MAME
| claim | evidence |
|---|---|
| every unit correct | 25-suite `make test` green: decoder, ALU, regs/callret, AGU, ld/st, LSU, I-cache, muldiv, 7 FPU suites, whole-CPU lockstep, IRQ soak |
| runs the real game | PC stream identical to MAME for **803,355 instructions** from the boot vector (`i960-diff.sh`) |
| beyond that | resync differential clean to **2.6 M instructions** across 5 poll loops; sole divergence is interrupt arrival timing, expected at CPI 3.95 vs 1 (R55) |
| on hardware | boots Daytona; PRCB after reinitialize IAC = `0053F400`, matching sim (R48); 106 M+ instructions, no trap, no halt; 128 KB boot copy 65,536/65,536 words, `"SEGA"` in backup SRAM |

### SDRAM — working, verified end to end and now constrained
| claim | evidence |
|---|---|
| controller correct | `test_m2_sdram`/`128`: **123,927 checks, 0 fails**; x2 adapter 2,560 checks |
| the full 43.62 MB image is in the chip, byte-correct | **all 22 regions** fold to `rom_csum.py`'s values on the board, incl. bounded region 21 = `00DDC2C0` — the bench's "that's only 42 MB" catch closed |
| arbitrary words readable | 8 sim-verified words (glyph data, boot IP) read back exactly via the OSD probe |
| interface constrained | generated clock on the `SDRAM_CLK` pin + I/O delays + multicycle pairs; closes at reads +1.9 ns, outputs +6.6 ns (R57) |
| constraints proven | BOTH former killer edits (sweep bound, CDC constraints) re-applied and absorbed; board boots identically (R58). `cal_mask` on row 20 is the per-build health check |

### 2D renderer — working, pixel-exact against MAME
| claim | evidence |
|---|---|
| renders MAME's frame | `test_m2_video_frame`: 2,054/190,464 non-black, bbox x 161-405 y 41-174 — pixel-identical to the capture |
| on hardware | the 2D tilemap test is **pixel-perfect on the board** |
| from our own CPU's data | boot-harness dumps (tile, palette, xlat, char) render identically — incl. the full attract title screen: logos, clouds, textured grass (R54/R56) |
| concurrently with the CPU | composition harness (CPU + renderer + real char CDC, three true-ratio clocks) = same 2,054 pixels, at real I/O-board timing too |
| the crossing | `m2_char_cdc` 64/64 fetches at every latency; the old direct path measured losing 4/12 phases (R49) |

### I/O board & backup SRAM — working
Handshake sequence verified in `test_m2_ioboard` (status, flag, self-test at
real 121 M-cycle constants); backup SRAM byte-lane correct, holds the game's
own "S-RAM CHECK OK" status string, survives resets by design.

### The digit race, and the instrument being built for it (R63)

The exchange is deposit -> command -> firmware response -> copy-back. The
board's copy-back beats the response: backup receives `7F FF 7F` (the Z80's
input-scan pattern) instead of the settings. The composition wins this race
because its C++ memory shortens the game's critical section; the board loses it
under real SDRAM latency on top of CPI 3.95. The firmware's own primitives
(disassembled: `0x7A4-0x8D0`) wait on 315-5338A status bits 0/3 with timeouts
and a retry budget at Z80 RAM `0x5803` -- MB8421 BUSY arbitration our model
replaces with a constant `0x08`.

**Next build: `m2_boot_harness` with `REAL_MEM=1`** -- replace the C++ memory
with `sim/mem/m2_sdram_x2_harness.sv` instantiated whole (it is a complete
subsystem: x2 adapter + m2_sdram + sdram_model, fast clock in, slow ports out,
and it generates its own clk_slow). Wiring: bridge `sd_*` -> p1, char fetch ->
p3 (+`GAME_CHAR` base), ROM image streamed through the wr port before reset
release, p0/p2/p4 idle, harness `clk_mem` replaced by the subsystem's
`clk_slow` under the parameter, tb drives a 96 MHz clock at base half-period 1.
Its header's warning is on-theme: the 2:1 read-data bypass "failed almost
exactly half of all reads" and is invisible in single-domain tests. When the
game side runs at true latency the sim should LOSE the race like the board --
then the fix (honest BUSY/status modelling, or whatever the reproduced race
demands) gets built against seconds-long runs.

### ON THE BOARD NOW: build 6a8bbc08 (R72)

Deployed 2026-08-28. 20,100 ALM (48%), 386 M10K (70%), worst-case setup
slack 0.606 ns, 5 distinct PLL clocks. The fitter did NOT crash on exit
this build -- first time with the SDRAM constraints in place.

WHAT CHANGED, and why it may matter to the missing glyphs:

1. ONE CLOCK FOR THE PICTURE. clk_vid is gone; the renderer, overlay and
   timing generator run on clk_sys with ce_pix one-in-three (48/3 = 16 MHz,
   the exact old pixel rate). Synthesis confirms tram_rtl_0 and pal_rtl_0
   have LEFT the Warning(276027) dual-clock list, so tilemap and palette
   read-during-write is defined on silicon now, and the clk_vid crossing
   the SDC had to cut is a timed path.

2. 64 KB GLYPH CACHE (m2_char_cache) in front of the character fetch.
   Glyph pixels were the last part of the 2D path read from SDRAM, at
   9,084x redundancy. Own testbench: 10,128 reads zero wrong, 96.7% hit
   on the real access shape.

3. DEBUG OVERLAY OFF BY DEFAULT -- OSD "Debug overlay", O[19].

LOOK AT THE ATTRACT SCREEN FIRST. The board rendered it as two flat
colours (blue sky, green ground), which is the signature of the character
fetch returning uniform data. Both changes above land on exactly that
path. If it is still two flat colours, the fetch is bad at the SOURCE and
overlay row 22 (last character fetch, verbatim) is the reading that says
so -- turn the overlay on to read it.

MEASURED CLEAN, do not re-investigate: backup settings 00030300, firmware
window 00030300 (matches MAME), formatter store 3131, tile cells blank
NORMALLY (MAME does the same), zero line overruns, V-blank timing matches
MAME set_raw exactly. The cabinet TEST button never reaches the core
(joystick_0 reads zero) -- separate open bug.

### The tram cell probe, finally connected

Build f1faaf86, deployed 2026-08-28. 19,984 ALM / 312 M10K, all slack
positive. One RTL change: overlay row 23 page 0 now shows the TRAM CELL
probe, `{1'b0, tp_cell, tp_q}`.

WHY IT MATTERED. tp_q was declared, clocked off tram[tp_cell], and wired
to NOTHING -- orphaned when row 23 was repurposed to walk the settings
dword. The OSD kept the probe names (chr 3, chr 1, chr #, chr A), so the
row read like character cells while reporting the backup SRAM's
first-read value. THE EARLIER "chr# - 20202020" READING WAS NOT A TILE
CELL, and the conclusion drawn from it -- that the board writes spaces
into the tilemap -- is withdrawn. Page 1 is untouched: all backup,
settings and collision telemetry read exactly as before.

WHAT TO READ. Boot to the screen with the missing characters, set Probe
page = 0, step Probe 0..7 and read row 23 each time. The cell index rides
in the top half, so 0469C033 is cell 1129 holding C033 and a value can
never be attributed to the wrong cell. Expected: 0:1129 C033, 1:1130
8043, 2:1131 8052, 3:1132 8045, 4:1368 802F, 5:1385 8023, 6:1387 C031,
7:1108 8043.

  right value + glyph missing on screen -> the render path drops the CELL
  wrong value                           -> the CPU's write never landed

Those have opposite fixes and simulation cannot choose between them: the
composition renders this menu correctly.

### The race is reproduced, the crash was ours, the blanking is open (R64)

Study R64 has the full account. Short form: the REAL_MEM composition works
end to end after two fixes (firmware loads must follow reset release,
because the stack's clk_slow divider is reset-gated; the CPU must sit on
p0, the one read/write slow port -- on p1 every RAM write silently
vanished and the game died at its first interrupt-vector fetch, caught by
the tb's new flight recorder). With the composition honest:

- The 7F FF copy-back reproduces IN BOTH MEMORY MODELS. The determinant is
  the Z80's start phase (mid-init when the command arrives), not SDRAM
  latency. R63's mechanism is overturned on that point.
- Contamination alone does not blank the digits: the game validates,
  writes defaults 01010100/00030300, re-reads them clean, and renders
  '3'/'C' (tram c033/8043) in every ordering tried -- including the
  board's firmware-last ordering (M2_FWLATE).
- THE EXCHANGE IS EXONERATED. The Z80 arrival phase was swept over three
  orders of magnitude (FWLATE 0 .. 2M, ten points): all ten contaminate,
  all ten recover, tram1129=c033 tram1130=8043 every time. Deep runs found
  no late re-contamination either -- the repeating traffic is the input
  poll, not a settings re-read. R63's digit mechanism is closed as a cause.
- The composition RENDERS THE MENU CORRECTLY at true latency: white
  "ADVERTISE SOUND"/"COUNTRY" with green values, frame captured while the
  CPU runs. Font, tilemap, palette, colour translation, char CDC and the
  settings path are all proven together in simulation.
- So the board's fault is outside what the sim models. Also eliminated this
  pass: the char CDC has no drop path (four-phase, stalls not drops); line
  overruns are counted and the board reads zero; the NVRAM HPS port is
  correctly gated; m2_backup is wired identically in both. The next lever
  is hardware-only -- fitted timing on the char/backup paths, and a fresh
  board probe of the settings dword and the tile cells that blank.

Bench notes: the DPRAM dialogue logger's R-lines used to double the even
byte of each word (fixed; treat old captures accordingly). The harness
verdict now keys on the copy-back carrying 7F/FF. sdram_model unwritten
cells return 0, violating the FFFF rule -- masked while the streamed
image covers the space; open gap.

### Open items
1. **Two menu digits print as green spaces** — localised to the settings dword
   at backup byte `0x14` (sim: `00030300` → prints '3'); the probe reading it
   off the board is deployed (Probe=chr0, row 23, during the menu).
2. **Sound** — fx68k vendored and executing; no audio devices wired.
3. **3D** — renderer and TGP/copro not started. Sky/ground planes are the
   correct 2D-only picture.

---

## RESOLVED: the SDRAM interface is now constrained (R57/R58)

The section below is kept as history. As of `e3b29916`: the interface is fully
described in `Model2.sdc` (generated clock on the SDRAM_CLK pin, input/output
delays, multicycle pairs matching the calibrated capture), closes with margin
(reads +1.9, outputs +6.7), and BOTH former killer edits -- the ldr_top sweep
bound and the CDC net-delay/skew constraints -- now coexist on it, verified
booting on the board with row 20 unchanged at 00001204. Region 21 reads
00DDC2C0, matching tools/rom_csum.py exactly: **the full 43.62 MB image is
verified end to end.** Three Quartus 17.0 quirks are the price, documented in
the SDC and R58: the quartus_map fence, the fitter's crash-on-exit (run
quartus_sta and quartus_asm standalone, every build), and grep-able honesty
about what the multicycle exceptions mean.

## HISTORY: the SDRAM interface was unconstrained, and it was blocking

**The board is on `d3335ae0`, which works. Do not assume a new build will.**

Two individually CORRECT changes each stopped the machine booting — no SEGA
handshake, black screen, and **row 20 reading `00001400`: `cal_mask = 000000`,
no SDRAM capture depth passing at all**:

1. bounding the region sweep at `ldr_top` (arithmetically right, study R52/R57)
2. adding `set_net_delay`/`set_max_skew` to the character-fetch CDC (a real
   unconstrained crossing, and the constraints are correct)

Reverting (1) did NOT fix it; removing (2) reproduced `d3335ae0`
**byte-identically**. So the fit is deterministic, neither change was wrong, and
what they share is that both **move placement**.

**The cause:** neither `Model2.sdc` nor `sys/sys_top.sdc` contains a single
`set_input_delay`, `set_output_delay`, or `create_generated_clock` for
`SDRAM_CLK` at the device. The 96 MHz clock definition constrains paths INSIDE
the chip; nothing describes the round trip to the memory. So the fitter places
the clock and data paths for that interface however it likes, STA reports
success, and whether the core can read its memory is decided by luck.

**The fix, and it is established MiSTer practice** (retroramblings.net/?p=515):

```tcl
create_generated_clock -name SDRAM_CLK_pin \
  -source [get_pins {...general[4]...divclk}] [get_ports {SDRAM_CLK}]
set_input_delay  -clock SDRAM_CLK_pin -max 6.4 [get_ports SDRAM_DQ[*]]
set_input_delay  -clock SDRAM_CLK_pin -min 1.0 [get_ports SDRAM_DQ[*]]
set_output_delay -clock SDRAM_CLK_pin -max 1.5 [get_ports SDRAM_*]
set_output_delay -clock SDRAM_CLK_pin -min -0.8 [get_ports SDRAM_*]
```

Check the numbers against the DE10-Nano SDRAM module's own datasheet rather than
borrowing another board's. **Expect it to fail timing at first** — that is the
point; it would be reporting a violation that exists now and cannot be seen.

**Why MiSTer does not supply this:** the framework ships no memory controller at
all. Cores using the community `sdram.v` inherit a clock and phase thousands of
installs have proven, so it works by convention. A custom controller at a custom
clock — which `m2_sdram` at 96 MHz is — is outside that and must state its own.

**Why it went unnoticed for the life of the project:** the boot self-test
calibrates the capture depth at runtime (R47). That is good engineering and it
MASKED the missing constraints, because as long as one depth works the interface
looks fine. R46 recorded "the window is one depth wide" as a curiosity to watch
rather than as evidence nothing was holding it.

**Until this is done, `cal_mask` on row 20 is a per-build health check.** Several
contiguous bits means the fit is sound; `000000` means the memory interface broke
and whatever else changed is innocent. Read it before believing anything else on
a new build.

---
 `make test` is green at
25 PASS.

---

## Where Daytona actually is

**The 2D path renders on hardware.** Daytona boots, runs continuously, and draws
its test menu with white labels and green values, plus a sky/ground horizon in
attract mode. The **2D tilemap test is pixel-perfect on the device** against a
MAME-captured frame. Both were black screens at the start of this session.

**Verified from the board, by the bench:**

| row | reads | means |
|---|---|---|
| 12 | `0025E723` | matches `tools/rom_csum.py` exactly — the 43.62 MB ROM image in SDRAM is byte-correct |
| 3 | `015CFFFF` | the tool's `last word` exactly |
| 20 | `00001204` | capture calibrated, CL+2, stable |
| 16 | `41474553` | `"SEGA"` — the boot's 128 KB copy landed |
| 4 | `00003B03` | no trap, no halt |
| 7 | `0053F400` | PRCB after the reinitialize IAC, matching simulation |

**What is left, and it is narrow:**

1. **Two glyphs missing** — the `3` of `3CREDIT(S)` and the `1` of `# 1`.
2. **Sky/ground banding** — green, then blue, then green, where it should be
   sky over ground.
3. **No 3D.** The road, cars and scenery need the renderer and TGP/copro, which
   are not started. Flat colour planes are the correct picture for now.

## The two glyphs: what has been ELIMINATED

This matters more than the remaining candidates, because each was measured and
several looked compelling:

- **Fetch bandwidth — ruled out TWICE.** Row 22's overrun counter reads
  `00000000` both before and after the white labels returned. With zero
  overruns the renderer fetches everything it is asked for.
- **Line buffering** — would not have helped. Demand is bursty (max/mean 3.18×)
  so it looked attractive, but there is nothing to smooth when nothing is late.
- **Latency jitter** — modelled in `test_m2_video_frame` with `+charjit=`. It
  costs pixels only once it costs overruns, and the board has none.
- **The colour translation table** — `test_m2_boot` dumps all three channels as
  identical correct 0→255 ramps.
- **The palette** — differs from MAME's capture in **0 of 8,192 entries** and
  holds 60 of 60 whites.
- **Character data** — rendering with OUR CPU's own `char.bin` still gives
  2,054 pixels, identical to the reference.

**The whole 2D chain, driven entirely by data our own CPU produced, is
pixel-perfect in simulation — and the board is not.** So the difference is
something the harness does not model: real SDRAM behaviour, the live
`m2_char_cdc` crossing, or the CPU taking a different path on hardware because
of the I/O board, inputs or NVRAM. Note that both missing glyphs are *dynamic
values* (credit count, coin setting), which are read from backup SRAM — and a
bus trace showed an unaligned read of `01d00216` returning `FFFFFF00` where the
all-`0xFF` contract says `FFFFFFFF`. That is wrong on its own terms and is the
first thing to chase.

## How to reproduce the 2D state in five seconds

Do not debug this on the board. The loop that found R56 is:

```
M2_BOOT_DUMP=<dir> M2_DUMP_OUT=<dir> ./obj_boot/Vm2_boot_harness +insn=4000000
./obj_m2_vf/Vm2_video +in=<dir> +out=<dir>/r +frames=2 +charlat=10
```

That dumps the tile RAM, palette, colorxlat and char RAM **our CPU builds** and
renders them through the real renderer. 2,054 non-black pixels means correct.
`tools/mame_m2_palwatch.lua` gives MAME's side frame by frame for comparison.

---

---

## The red screen was an ordering bug, not a colour bug (study R47)

The 2D tilemap test rendered **flat red** on the 96 MHz build. Daytona was
unaffected, which is itself the clue.

**Do not read "red screen" as "colour bug".** That reflex cost the first hour.
What localised it was rendering the *good* case: `test_m2_video_frame` against
the real `m2tiles` dump returns **2,054 non-black pixels of 190,464 in x
161–405, y 41–174, white and green** — MAME's frame, pixel for pixel. That
turned "something in this 2,000-line path" into "nothing in this path".

**The mechanism.** `rd_lat_sel` follows `cal_sel` while `!cal_done`, and
`cal_sel` resets to `3'd0`. The self-test that performs the calibration waited
on `cp_done` — added for a real contention bug, and correct about the contention
but backwards about the direction. So:

```
rom_loaded -> copy engine (CL+0) -> cp_done -> calibrate -> cal_done
```

The board's own sweep says CL+0 does not work: **word 20 reads `00001204`**,
`cal_mask = 0b000100` — only CL+2 passes. The copy engine latches tile RAM, the
palette and colorxlat into M10K **once**, so it did not merely read garbage, it
*kept* it; calibrating afterwards cannot repair a copy already made. Char RAM is
512 KB, too big to copy, so it is fetched live — after calibration, hence
correctly. Real character pixels through a garbage tilemap and palette is
exactly a screen of one flat wrong colour.

**Why Daytona hid it.** `game_image` short-circuits `cp_done` without reading
anything, so on a game image the copy engine is a no-op. The tilemap test was
the only thing exercising that path.

**It was not harmless on Daytona.** Two other readers were unguarded, and both
had already produced bench symptoms misread as marginal SDRAM:

- The **ROM readback** gated on `cp_done`, which `game_image` asserts early — so
  it read at CL+0. That is the *"row 2 reads `FFFFFFFF`, then `00000860` after
  three resets"* seen repeatedly.
- The **i960** came out of reset on `rom_loaded`. Its first act is four reads —
  SAT, PRCB, IP, initial FP — issued before calibration. The intermittent PRCB
  and IP on the overlay were this.

**The fix.** The self-test waits only on `rom_loaded`; the copy engine, the ROM
readback and `cpu_rst_n` all wait on `cal_done`. `rom_loaded -> calibrate ->
copy -> readback` has no cycle. `ST_BASE` is word `0x1F00000` (~62 MB), clear of
both images, so the self-test is safe to run first.

**The rule to carry:** *a calibration must complete before anything it
calibrates is trusted, and a value latched once must never be captured on an
uncalibrated path.* When a diagnostic and the thing it measures are ordered
against each other, the measurement goes first.

**Not a bug:** Quartus warns `10027 index expression is not wide enough` at
`m2_video.sv:717–718`. It constant-folds the leading `2'd0`/`2'd1` and notes
those indices cannot span all 96 entries. Line 719 (`{2'd2, x_b5}`, reaching
element 95) does not warn. Intentional partitioning, not truncation.

**The fixture.** `m2tiles.zip` md5 `aa8f3175bc61c2fd65017417d4bca26f`, 655,360
bytes, goes in `/media/fat/games/mame/`. Layout is in the MRA and verified:
tile `0x10000`, palette `0x4000`, char `0x80000`, colorxlat `0xC000`. All three
colorxlat channels carry identical valid ramps 0→255, so `xlat_ok` passes.

---

## State

**The i960 is done as a CPU.** It runs Daytona's real boot code and its program
counter stream is identical to MAME's for 803,355 instructions. `make lint` is
clean and `tools/i960-diff.sh` reproduces the differential result whenever MAME
is on PATH.

**`make test` IS green**, for the first time in several sessions. `test_m2_sdram`
had been red throughout and was carried as a debt against the controller; it was
the harness. A read overlapping a write to the same address may legitimately
return either value, and the shadow model updated at write issue time so it
expected only the later one. Diagnosed in the Kaneko core against pristine Model
2 sources — same addresses, same values. Study R42.

The raced-read count is REPORTED, not absorbed: a run showing zero would mean
the test had stopped covering the case it exists for.

```
reads accepted as raced (returned the legal pre-write value): 2
m2_sdram: checks=123927 fails=0 violations=0
``` Stated here rather than left to be
rediscovered — a red suite that is *known* red still hides the next regression,
so this is a debt, not a footnote.

| Step | State |
|---|---|
| 1. Decoder and the four formats | **done** |
| 2. Integer ALU, shifts, bit ops, condition codes | **done** |
| 3. Register file, register cache, call/ret and spill | **done** |
| 4. Load/store, MEMA and the seven MEMB modes | **done** |
| 5. Bus and I-cache, burst | **done** |
| 6. Whole-CPU lockstep | **done** |
| 7. FPU | **done** |
| 8. **Interrupts, `modpc`, `synmov`/`synmovq`, IAC, `bx`/`balx`** | **done** |
| 9. **Real ROM execution vs MAME** | **done — 803,355 instructions identical** |

**P1.5 is done and proven on hardware**: 496x384 video, the overlay, SDRAM at the
measured 64 MB geometry, the S24TILE tilemap rendering Daytona's attract screen
correctly from canned MAME state.

**Measured, Quartus 17.0, `5CSEBA6U23I7`:** `i960_top` = **7,807 ALM**, 4,872
registers, 1 M10K, 7 DSP, **Fmax 26.4 MHz**. The interrupt controller cost 828
ALM and 0.44 MHz of headroom (R23). The budget is i960 + renderer under ~25,000
ALM, so **~17,200 ALM remain for the renderer** — wider than §5.2 assumed.

**Whole core with the CPU in it: 17,339 ALM, and timing closes.** M10K is the
binding resource, not ALM — ~107 blocks are recoverable (64 from the duplicated
tile RAM, ~43 from ascal) and that recovery is a P2 prerequisite.

## Where it actually is

The boot runs on hardware at 96 MHz and gets **15,880,053 instructions** into
simulation before trapping. Tilemap, palette and character data all match MAME.

| | |
|---|---|
| char RAM write stream vs MAME | **identical** — all 143,072 writes |
| words the game wrote, matching MAME | **100.00%** (124,784 of 124,784) |
| tilemap / palette | 98.7% / 98.5% at the same frame |
| `make test` | green, 24 PASS |

### What was fixed today

1. **Unaligned 32-bit accesses lost a half, in both directions.** `S_LO` always
   sent `r_wdata[15:0]`; `S_RDB` always took `sd_dout[31:0]`. When `r_addr[1]`
   is set the enabled bytes are the HIGH half, so writes were dropped and reads
   returned the **neighbouring halfword**. The boot's character copy is a
   halfword loop, so every second access was wrong — 52,375 of 140,864 source
   loads. **All SDRAM reads come through `S_RDB`;** `S_LO`/`S_HI` is the write
   path, and a first attempt at the read fix went into `S_LO`, where it compiled
   and did nothing.

2. **The initial frame pointer was never read from the PRCB.** `i960.cpp`'s
   `device_reset` does `FP = rd(PRCB+24)` and `SP = FP + 64`; the boot walk
   stopped at the IP. FP stayed zero and frames allocated from `0x40, 0x80,
   0xc0, 0x100` — the boot record and program ROM. **It survived 803,355
   verified instructions because nothing touches memory until a frame spills,
   and a spill needs depth > 4.**

### The open fault

A second `ret`, at `0x0001C690`, still branches to zero. The frame taps say why
it *looks* wrong and not yet why it *is*:

```
i15424572  ip=0001c6a0  rip=0001c670 pfp=0053f6c0 pos=5 spill=1
i15424576  ip=0001c670  rip=0001c670 pfp=ffffffff pos=4 spill=1
```

`pfp=ffffffff` is our unwritten-memory value, so the restore read memory nothing
wrote.

**The spill machinery itself works, and an earlier note here saying otherwise
was wrong** — it came from a trace filtered to a single address. Taps on
`rf_mem_req`/`rf_mem_ack`/`rf_mem_addr` show:

```
register-frame memory: req asserted 30412 cycles, 2048 acks, last addr fffffffc
FIRST frame access outside work RAM: addr ffffffc0 at instruction 15880052,
                                     ip 0001c690, pfp ffffffff
```

2,048 acks is exactly 128 frames x 16 words, and **every** frame access is
inside work RAM until the very last one. So spills and fills are happening, to
sane addresses, and being answered.

What fails is that at the final `ret` the frame restored from work RAM brings
back `PFP = 0xFFFFFFFF` — so the matching spill did not write what that fill
reads. Spill and fill are both `spill_base + idx*4`, `spill_base` being
`fp_masked` at the call and `PFP & ~0x3f` at the return, which should be the
same address.

**The next step is to log spill and fill address/data pairs for one frame and
compare them** — which of the sixteen words differ, and whether the two agree on
where the frame lives. `dbg_rf_addr` is already exposed; the data is not.

A caution: `pfp = 0xFFFFFFFF` appears legitimately at the outermost frame, so it
is not by itself evidence of corruption. An earlier reading here treated it as
such, and the first genuinely out-of-range access is at instruction 15,880,052,
not at 15,424,576.

### Instruments that now exist

- `test_m2_boot` — the real boot through the real bridge, five seconds a run
- `tools/mame_m2_charwrites.lua` — MAME's char-RAM write stream, diffable
  line-for-line against ours (`M2_BOOT_CHARSTREAM`)
- frame taps: `dbg_rip`, `dbg_pfp`, `dbg_rcache_pos`, `dbg_to_memory`
- `M2_BOOT_FRAME`, `M2_BOOT_STACK`, `M2_BOOT_BUS`, `M2_BOOT_CHAR`, `M2_BOOT_SDR`
- MAME disassembly and breakpoint-started traces via `-debugscript`, which is
  how code outside the 12M-instruction trace window gets read

### A caution about the overlay

Two rows have now reported healthy while being meaningless: row 14 during the
bridge bug (it showed the board's shadow registers, not what the CPU received)
and row 12 after the sweep's fold was pipelined into a state that collided with
"done" — `DD` latched while the value churned. **Check that a diagnostic can
fail before believing it.**

## The SDRAM is verified end to end — and the fault was in the reference

**All 21 regions of the Daytona set now fold identically on the board and on the
host.** The chip holds the image. This closes a line of investigation that ran
for three sessions and was aimed at the wrong component throughout.

The board matched regions 0–16 and disagreed on 17–20. Rather than ask for more
readings, the four wrong values were tested against every single-address-bit
fault the controller could produce — each bit of the 25-bit word address forced,
cleared and flipped, folding the host image at the resulting source:

```
region 18: reads from word 0x1220000 (bit 17) -> MATCH
region 20: reads from word 0x1420000 (bit 17) -> MATCH
```

Both read `base + 0x20000` — the *same* displacement, 256 KB. That is not an
address fault, it is an offset, and an offset means the two sides disagree about
where a part begins.

`tools/rom_csum.py` ignored the `output` attribute on `<interleave>`. Daytona's
two 68000 sound ROMs are `output="16" map="12"` — a byte swap, two bytes in and
two bytes out — and the tool emitted four for every two, making each part
`0x20000` too long. **The image is 43.62 MB, not 43.88.**

**And the loader's high-water mark was right all along.** It read "256 KB short
of the MRA's length" and was treated as a symptom; it was short by exactly the
amount the tool was long. The one instrument reporting the truth was the one
under suspicion. Study R39.

**What that exonerates:** the SDRAM controller, the capture phase, R19's 64 MB
geometry, the FIFO, and the loader. Memory was the leading theory for the trap.
It is now dead, which leaves the CPU or the memory map — and both are
reproducible in simulation.

**What it costs to have learned:** the original control folded the first 64 KB
of program ROM, matched exactly, and was used to license the far-end number. It
was a real control, correctly reasoned about — and it sat at word 0, *before
every part whose offset was wrong*. **A control must be able to fail.** Region
16 makes the point from the other side: it is byte-identical to region 15, so it
would have matched even under an alias.

## Using the sweep

Region N is word `N*0x100000` — 2 MB — selectable from the OSD, restarting on
change. On the host:

```
python3 tools/rom_csum.py "mra/Daytona USA (Deluxe 93).mra" /home/ben/roms/Model2 --scan
```

On the board, read two overlay rows together:

- **row 13** — `DD00000N`. `DD` means the sweep FINISHED; `00` means it is still
  running and row 12 is a partial total, not a result. `N` is the region.
- **row 12** — the fold.

Regions past the image end are marked by `--scan` and are not evidence: the host
tool substitutes `0xFFFF` there because that is what an unwritten read returns by
contract, but nothing wrote those words in the chip either.

### Flashing

```
make release
```

`make release` refuses a stale bitstream — it checks source mtimes against the
`.rbf` and the Flow Status — because it shipped one twice.

- `build/release/Model2.rbf` → the MiSTer
- `build/release/_Arcade/Daytona USA (Deluxe 93).mra` → `_Arcade/`
- `daytona93.zip` is already on the device

`tools/deploy-mister.sh` does the copy and holds no credentials; it takes them
from the environment (`SSH_ASKPASS`).

## The 2D path is verified end to end

Three links, each against MAME, each an assertion rather than an impression:

| link | instrument | result |
|---|---|---|
| CPU executes the real ROM | `tools/i960-diff.sh` | **803,355 instructions identical** |
| the data it builds | `tools/i960-datadiff.sh` | tile/char/palette byte-identical (see R26's stated limits) |
| the renderer turns it into pixels | `tools/m2-framediff.sh` | **10 tilemap-only frames, 190,464/190,464 pixels each** |

`tools/m2-framediff.sh` defaults to frame 120 and **demands 100%**, not a floor.
It is sensitive to one bit: perturbing a single colour-translation entry by 1
fails it with 2,054 differing pixels.

**It found a real defect immediately** — `m2_palette.sv` was Model 1's module
copied across, and Model 2's palette is a different mechanism (R27). Every fill
colour in every game was a few units out, and it had survived being looked at on
hardware because the picture is otherwise right.

## The video and interrupt session (history)

- **The whole interrupt controller** — `execute_set_input`, the immediate slot,
  the queue into the interrupt table, `check_pending_irqs`, `take_interrupt` and
  the type-7 return that restores PC and AC. Study R21, R22, R23.
- **`modpc`**, without which none of it is reachable by real code (R24).
- **`synmov` fixed** — the fault was in the reference, not the module (R20).
- **`synmovq`, the IAC port, `bx`, `balx`** — all found missing by the ROM run.
- **`make test_i960_rom`** and **`tools/i960-diff.sh`** (R25).
- **`make test_i960_top_irq`** — a strict-coverage soak, separate from the
  default run because `steps` is the program length and changing it would move
  the CPI that R16 rests on.
- **The palette rewritten to Model 2's actual path** — colour translation table
  plus gamma, replacing Model 1's `pal5bit` and its inapplicable intensity bit
  (R27), and a whole-frame pixel comparison to hold it (R28).

## The 2D path, and what it needs to be flashed against

The tilemap test image is ROM-derived and lives outside this repository. To
regenerate it:

```
M2_FRAME=2300 M2_OUT=<dir> mame daytona93 -autoboot_script tools/mame_m2_tiledump.lua
cat <dir>/tile.bin <dir>/palette.bin <dir>/char.bin <dir>/colorxlat.bin > m2tiles.bin
zip m2tiles.zip m2tiles.bin
```

The colour translation table at `0x094000` is the fourth section and an image
built before R27 will not have it. The core sanity checks it — entry 0 must map
to 0 and entry 31 to 255 on all three channels — and falls back to the old
`pal5bit` expansion if it is absent or wrong, so an old image still renders
exactly as it did. The table is staged and committed only if the whole section
passes, so a corrupt one cannot half-replace it.

## Findings worth carrying, all of them about instruments

Every real defect this session was in a check, not in the design. The pattern is
consistent enough to state as a rule: **when a lockstep divergence is reported,
the instrument is a suspect of equal standing to the module.**

- **A sentinel that collides with a legal value is not a sentinel.** Unwritten
  memory reads `0xFFFFFFFF`; a reference that *writes* `0xFFFFFFFF` is
  indistinguishable from one that wrote nothing. This produced four wrong
  diagnoses on `synmov` (R20) and later hid a `synmovq` mutation entirely (R25).
- **Fix the accessor, not the caller.** R20 fixed `synmov`'s call site and left
  `Regs::read`/`write` unaligned; the second instance surfaced immediately in
  `ret_typed` (R22).
- **"The IP changed" is not a retire detector.** Interrupts break it three ways.
  The module now exports an instruction-acceptance counter (R22).
- **Appending enum states was necessary and never sufficient** — `ts & 15`
  silently stopped covering a five-bit field at the seventeenth state (R20).
- **A green suite that never executed the instruction proves nothing.** Coverage
  counters are printed, and `+strictcov` makes zero coverage a failure.
- **From the Model 1 project, `9b3b70a`:** a COLLAPSED trace can report
  IDENTICAL for tens of thousands of instructions while one side is wedged in a
  loop the other does not have. The counts file carries the difference. Written
  into `docs/differential-testing.md` before we build the trace that would have
  the same blind spot.

## Known gaps, stated plainly

- ~~The differential test compares program counters only.~~ **Closed.**
  `tools/i960-datadiff.sh` compares the data too: tile RAM, char RAM and palette,
  **606,208 bytes, identical** (R26). The CPU side of the 2D path is verified end
  to end. The 3D path still has no oracle at all (§2.1).
- Still unimplemented in the i960: faults, `calls`, `remr`, the `rl` FP forms and
  transcendentals. None is reached by Daytona's boot in 803,355 instructions.
  They must be measured for **Fmax** as well as area — the margin is now 1.4 MHz.
- The renderer (P2) has not been started.

## The question everything is sequenced to answer

The device has 41,509 ALM. Everything that is not the CPU or the renderer comes
to 16,500 optimistic / 22,800 pessimistic, which leaves **25,009 ALM** for the
i960 and the renderer together in the good case and **18,709** in the bad one.

The current estimate for those two is **22,000 to 38,500**, and none of it has
RTL behind it.

That is the whole uncertainty of the project. It is why the milestones build the
CPU and the GPU first and defer everything that cannot change the answer.

---

## What remains

### Next, and none of it needs FPGA design work

- **M2-E** — compile `N64_MiSTer` for `5CSEBA6U23I7` with Quartus 17.0. Extract
  per-module ALM for the RDP and the R4300i, and achieved Fmax at real
  utilization. Highest-value hour in the plan: it produces measured, same-part
  proxies for *both* big blocks before either is started. Read the RDP source
  while the fitter runs.
- **M2-H** — build an M10K budget. There isn't one. See findings below.
- **M2-B** — count i960 FP instructions per frame by opcode class. Scopes the
  FPU, which is most of the spread in the i960 estimate.
- **M2-A** — texture cache hit rate. Instrument `model2_v.cpp`, replay through a
  software cache model across 16/32/64 KB and 2/4/8-way.
- **M2-G** — email srg320 about the SCSP licence. Send it now; a late yes is
  worth less than an early one.

### Measured CPI — the pipeline's actual target

| mix | CPI | M instr/s at 45.16 MHz |
|---|---|---|
| ALU only | 7.33 | 6.16 |
| + 10% multiply/divide | 11.89 | 3.80 |
| harness full mix | 15.86 | 2.85 |

Requirement is 12.5-16.7 M instr/s, so even the ALU-only figure is **2x short**.
An earlier note in this file said "~6 cycles per instruction, about half" — that
was an estimate and it was optimistic; 7.33 is measured.

**The pipeline needs low CPI more than a high clock.** At the already-measured
45.16 MHz, 2 CPI gives 22.6 M instr/s and 3 CPI gives 15.0 M — both clear the
requirement. It can afford to lose Fmax to hazard logic if that buys CPI.

### Deferred, not forgotten

`docs/p1-i960-spike.md` carries an **optimisation backlog** with five items,
each with a measurement behind it. The two that matter: the register file is 49%
of the CPU and the measured critical path runs through its combinational read
multiplexer, and the ALU describes six shifters, four comparators and three
adders separately. Both are deferred because the pipeline has to decide read
latency and datapath sharing anyway — doing them first means doing them twice.

**Revisit that section when step 6 lands.**

### Then — P1 step 6, and it is the big one

Every block P1 needs now exists except the sequencer. Step 6 is the top level
that wires them together plus a transcribed whole-CPU `execute_run` to lockstep
against, and it is larger than steps 1-5 combined. It is also where the pieces
stop being independently testable: the pipeline, its hazards, the interaction
between the register cache and instructions in flight (§10), and the branch and
interrupt paths all land here.

Only after that does step 7 (M2-D) mean anything — a half-CPU's area does not
answer the fit question.

The FPU is deliberately step 8 of 8: it is the only part with no oracle, and
M2-D measures the integer core.

Then P2 renderer, P3 the fit verdict, P4 TGP port, P5 sound and 2D, P6
integration. Detail in `docs/milestones.md`.

---

## Measured on the real device

Quartus 17.0.0, `5CSEBA6U23I7`, virtual pins, I/O cut. **Not M2-D** — the
sequencer, I-cache, bus and FPU do not exist yet.

| Module | ALM | Reg | MLAB bits | Fmax |
|---|---|---|---|---|
| `i960_dec` | 103 | 0 | 0 | comb |
| `i960_alu` | 852 | 0 | 0 | comb |
| `i960_regs` | 1,655 | 1,261 | 2,048 | 94.86 MHz |
| `i960_agu` | 252 | 0 | 0 | comb |
| `i960_ldst` | 126 | 0 | 0 | comb |
| `i960_lsu` | 241 | 188 | 0 | 142.57 MHz |
| `i960_memmap` | 35 | 0 | 0 | comb |
| `i960_icache` | 472 | 861 | 4,096 M10K bits | **84.97 MHz** |
| **total** | **3,736** | 2,310 | | |

`i960_icache` is **under the gate's 90 MHz** at 84.97. The tag compare feeding
the hit decision is the obvious suspect. Not addressed; recorded.

**Assembled `i960_top`: 3,155 ALM, 43.91 MHz.** Area fell 581 ALM on assembly
because the fitter deleted logic nothing consumed; Fmax roughly halved against
the slowest block, because the critical path is created by assembly —
`i960_regs|loc[10][3]` → `wd[9]`, register read through ALU to writeback in one
FSM state, which is exactly where a pipeline boundary goes.

**Do not read 3,155 as the i960's cost.** It executes 66 of 159 mnemonics, 14
more are semantically wrong (`cmpob`/`cmpib` do not compare; `test<cc>` is
treated as a branch), and 79 are absent including the entire FPU, integer
multiply/divide and all fault handling. Projected total with the missing blocks
and the pipeline: **8,155 - 14,255 ALM**, against the study's 7,000-13,500.

That **corrects an earlier note in this file** describing the per-module total as
tracking toward the lower half. It does not: the five blocks measured first were
the cheap ones. The 581 ALM assembly saved will also not repeat, and DSP usage
is currently zero — multiply and the FPU will both claim blocks.

## Findings

### Settled

**M2-C is closed, pass.** `mb86234_device` is an empty subclass of
`mb86233_device` — overrides nothing, adds nothing, same memory config, only the
device-type tag differs. The MB86234 and MB86233 are behaviourally identical in
MAME, so 3,179 lines of Model 1 TGP RTL transfer unmodified along with the fuzz
suites and lockstep harness. **Caveat: this is absence of evidence, not proof.**
MAME modelling them identically means no game has yet needed a difference. The
oracle is the thing asserting the equivalence, so a later divergence would have
nothing behind it.

**No open-source i960 exists in any HDL.** Searched and not found. Combined with
MAME modelling the four 80-bit FP registers as host `double`, the i960KB is a
from-scratch pipelined CPU with a partially unverifiable FPU. This was never
listed as a sourcing risk before.

**S24TILE is already written and it is ours.** `model1.cpp:1830` instantiates the
same `S24TILE` device Model 2 uses. Model 2 remaps the base address; the chip is
unchanged.

**`N64_MiSTer` is GPL-3.0**, not merely readable. It is an architectural
reference for the renderer, not only an M2-E comparable.

**The i960's transcendentals are enormously slow, so the FPU can be microcoded.**
`sinr`/`cosr` are 406 cycles, `sinrl`/`cosrl` 441, `logr` 438, against 10 for
`addr` and 18 for `mulr`. At 25 MHz that caps `sinr` at ~1,000 per frame with the
CPU doing nothing else. A CORDIC at ~64 iterations is ~6x faster than the
silicon on the operations that dominate FPU area, and 36 cycles for `mulrl`
affords an iterative 27x27 DSP multiply rather than a wide combinational one.
This pushes the widest line in the i960 estimate toward the bottom of its
2,500-6,000 range, and changes M2-B's purpose from verdict to mix.

**Downgraded to a hypothesis.** The argument that `i960.cpp` could be trusted
where `v60.cpp` could not inferred accuracy from the absence of a disclaimer,
which proves nothing — the file has no header caveat and MAME claims nothing
about cycle accuracy either way. The "survives being wrong by 2x" hedge only
helps if the figures are in the right region at all.

Two things would settle it: the i960KB Programmer's Reference Manual
**270567-001**, and **M2-B**, which counts what games actually issue and depends
on no cycle model. Until then the budget keeps the full 2,500-6,000 FPU range
and M2-B stays on the critical path. Design study R8.

**The register cache is cheaper than §5.2 assumed, and its depth is not free to
change.** MAME copies sixteen words per `call` because it is software; in RTL a
banked four-frame local file makes `call` a frame-pointer increment — ~2 M10K
and ~128 ALM, against ~512 ALM for a flat flip-flop file of the same storage.
But a spilled frame *writes to memory*, so cache depth is visible in the write
stream lockstep compares. Four frames, matching the reference. Deeper caching
later is a behaviour change needing its own verification, not a free win.

**MAME's `addc` and `subc` never set carry, so the integer oracle has one hole.**
Its expression evaluates entirely in `uint32_t` and wraps before being widened to
`uint64_t`, so the bit-32 carry test can never be true. Verified: `0xffffffff + 1`
gives `res = 0` with bit 32 clear. The `// set carry` comment and the deliberate
`(uint64_t)1 << 32` mask show the intent, so it is an integer-promotion defect
rather than a modelling choice — and these two instructions exist to chain
multi-word arithmetic.

**The RTL implements hardware carry and diverges on purpose** (design study §2.3,
R7). Whole-CPU lockstep will therefore diverge on any program using `addc` or
`subc`, and that is expected rather than a bug. The divergence is bounded by
measurement: over 12.8 M vectors across all 64 `op`/`op2` pairs in `0x58`-`0x5b`
it touches exactly two operations, the union of differing AC bits is exactly
`0x00000002`, and `result`, `result_we` and `valid` never differ.
`make test_i960_alu_carrybug` guards this and **fails if the RTL stops
diverging**.

**Unknown and unanswerable here:** whether Model 2 games actually use `addc` or
`subc`. It needs program ROM. If they do not, the hole is theoretical.

**A memory that simulates perfectly can still be flip-flops.** The register
cache was written with the array indexed inside the control FSM. Every test
passed. Quartus refused to infer it — `RAM logic "rcache" is uninferred due to
unsupported read-during-write behavior`, `Total MLAB memory bits : 0` — and it
became 2,048 flip-flops.

| | ALM | Reg | MLAB bits | Fmax |
|---|---|---|---|---|
| in flip-flops | 2,355 | 3,303 | 0 | 68.44 MHz |
| in MLAB | 1,655 | 1,261 | 2,048 | 94.86 MHz |

**30% of the module and 26 MHz.** The fix is a dedicated write port and a
dedicated *registered* read port with their own address signals, rather than
indexing the array inside the FSM. Watch the register count, not the memory
count — it moves first.

### Retracted

**The SCSP was recorded as having licence-compatible RTL. It does not.**
`srg320/Saturn`, `srg320/Saturn_MiSTer` and `MiSTer-devel/Saturn_MiSTer` all
report no licence, and `SCSP.sv` has no SPDX header and no copyright notice. No
licence is all rights reserved — no permission to copy and none to adapt, which
is the position this project family already took on `geometrizer`. It may be
read and used as an external oracle. It may not be ported. The SCSP is now a
from-scratch block against MAME's BSD-3 `scsp.cpp`.

### Open, and the one to worry about

**There is no M10K budget, and M10K may be the binding resource.** The Model 1
project reports 409 of 553 M10K spent on this same part, with a *simpler*
renderer — flat-shaded, no Z-buffer, no texture cache. This project budgets ALM
to 1,000-ALM precision across five rows and does not budget M10K at all.

Model 2's tile buffers and texture cache alone want ~78 blocks that Model 1
never needed. The three consumers not yet quantified here — S24TILE RAM, SCSP
state, and the MiSTer `sys/` framework itself — are precisely where Model 1
spent most of its 409.

The arithmetic does not obviously close, and it cannot be settled by reasoning
because the unquantified rows are the deciding ones. **An ALM answer to the fit
question is not an answer if the design runs out of memory blocks first.** M2-H
exists to fix this before P1, not after P2. Consequences if it binds: the "push
logic into M10K" area lever does not exist, the tile size in §6.2 becomes a
two-sided trade, and M2-A's cache-size sweep becomes a design decision rather
than a confirmation.

**Does fx68k simulate under Verilator?** Not confirmed. Rule 8 and every
verification practice here assume a block can be exercised in simulation before
it reaches the fitter, and this is the criterion that decided tv80 over T80 for
the Model 1 I/O board. Fully synchronous SystemVerilog is a good sign, not an
answer.

**The renderer still has no bit-exact oracle**, and never will. Verification is
by framebuffer comparison, which localises bugs poorly. Plan instrumentation
accordingly.

**The i960 FPU has no bit-exact oracle either, and the decision is unmade.**
MAME models the four 80-bit registers as host `double`. Either verify against a
software 80-bit reference — x86 `long double` is 80-bit and is the cheapest
route to one — or implement 64-bit and document the deviation. The first is
preferred and is the only option that makes lockstep meaningful for FP. Do not
let this be decided by default.

**P1 pipelines with no rehearsal.** M2-F was the cheap way to learn whether a
pipelined CPU of this class closes timing on this part, on a 3,000 ALM block
with an existing harness. Deferring the TGP removed it, so the largest
from-scratch block goes first with nothing proven ahead of it. Accepted
knowingly. If the Quartus spike misses, Model 1's M0 retiming notes are the
closest prior art.

---

**A fuzz suite this size measures internal consistency, not correctness.** The
decoder passed 6.0e9 field checks against its reference with zero mismatches,
and both were written by the same author from the same source — a misreading of
`i960.cpp` appears in both and the suite agrees enthusiastically.

The only independent check available was `i960dis.cpp`'s mnemonic table, written
separately from the `execute_op` dispatch our opcode set came from. It confirmed
no opcode was invented and no format boundary disagrees. It could not check
field positions, because it was the source for none of them.

**So the literal-select bit numbers, the MEMB mode and scale fields, and both
displacement widths are transcribed, not verified.** Closing that needs the
i960KB Programmer's Reference Manual (270567-001, cited in `i960dis.cpp`'s own
header) or real Model 2A program ROM decoding to sensible instruction sequences.
Worth doing before step 5, because a wrong field position will present as a bus
bug and be looked for in the wrong place.

## What was wrong, and the lesson

The design study asserted three third-party RTL sources without opening any of
the repositories. Two were wrong — one against the project and one in its
favour. The area consequence was 1,000 ALM out of 39,500, which is nothing; the
real cost was a plan built on a block believed to be free that is not.

**A licence claim is a fact about a file, and checking it costs one API call.
Neither a search result nor a recollection is a licence check.**

Recorded as the study's second recurring failure mode, alongside the first —
treating MAME's cycle counts as hardware facts, which produced two wrong
conclusions before this.

One more, from the fx68k reconciliation: the Model 1 project is measuring the
same device, and its commit messages carry findings that exist nowhere else.
M10K binding came from a commit message, not from any document. **Pull that
reference when it moves and read what changed, rather than only taking files
from it.**

---
## FP-register verification — closed

**All 15 suites pass.** The fp0-fp3 comparison is verified by mutation, not
assumed.

### The gap was real, and it was not what it looked like

The comparison had been in the harness for some time and had never failed. It
was **inert**: `i960_cpu_ref.h` dispatched on `(d.op << 8) | d.op2` against
`case 0x78f:` labels. Opcode and sub-opcode pack as `0xOOS` across *three* hex
digits, so the shift is 4. With 8, no label matched, `handled` stayed false, and
the reference **trapped on every FP instruction** — ending the lockstep loop
before it reached a single comparison. The DUT was executing FP the whole time
with nothing reading it.

Same defect class as the generator's `0x78f >> 8` found the same day, and the
fourth instance of a check that looked present and did nothing. **A check that
has never failed is not evidence; it is an untested branch.**

### The bug that mattered: a request strobe that was never lowered

`fadd_req`, `fmul_req`, `fdiv_req` and `fsqrt_req` were set in `T_EXEC` and
never cleared. They were missing from the per-cycle default block that already
clears `ic_req`, `lsu_req` and `md_req`, and absent from reset.

Left asserted, a unit **restarts the instant it returns to idle** and spins
permanently busy — so the next instruction of that type reads a `done` from the
spurious run rather than its own. It presented as `sqrtr` retiring without ever
writing its FP register.

It was throttling the entire run, not just breaking sqrt:

| | before | after |
|---|---|---|
| retires | 256 | **2,205** |
| FP ops executed | 53 | **514** |
| writes to fp0-fp3 | 4 | **58** |
| field checks | 9,728 | **83,790** |

**The lesson is the default block, not the strobe.** Three request signals were
in it and four were not, in the same module, with nothing to make the omission
visible. A one-cycle strobe that is never lowered does not fail loudly; it makes
a unit quietly always-busy, and the damage lands on the *next* instruction of
that type — which is why five rounds of reading the writeback path all came back
clean. It was found by probing every cycle of an FP op, after the reading
approach had been exhausted. **When successive hypotheses are each eliminated by
inspection, stop inspecting and instrument.**

### Two other real defects the working check then exposed

1. **`scaler` read the wrong operand.** Its FP source is src2; every other
   fpmisc op reads src1.
2. **`scaler` is a multiply, not an exponent add.** The reference computes
   `t2f * pow(2.0, n)`. When `pow` overflows, `0 * inf` is NaN — an exponent add
   returns zero. Now routed through `i960_fpmul` with 2^n materialised as a
   double, so the special cases are the multiplier's already-verified logic.

### Deviations reach architectural state, and skipping is not enough

Two recorded deviations (§8.1) write to registers, which changes what a harness
must do about them:

- **Subnormal flush.** The units flush, the host does not. Common at CPU level
  and rare at block level, because *any* small integer left in a register is a
  subnormal read as a single — `0x1b` is 3.8e-44, so `0 / 0x1b` is 0 on the host
  and 0/0 = NaN once the divisor flushes. It applies to results too: two normal
  singles can divide to a subnormal.
- **NaN payload.** The units emit one canonical quiet NaN; the host propagates
  the operand's sign and payload.

The first attempt **skipped the comparison** for that retire. That was wrong —
the diverged word stays in the register file and every later retire fails on
state already known to differ. The program must be **abandoned**, exactly like a
trap. *Skipping a comparison does not undo a write.*

**Then the subnormal flush was modelled instead of excluded**, and the
truncation went to zero. The flush is a two-line predicate written from §8.1 —
exponent 0, mantissa non-zero, return signed zero — not read off the RTL, so it
does not agree with the design by construction. If a unit flushed something it
should not, this would still diverge. It does not.

| | excluded | modelled |
|---|---|---|
| retires | 2,205 | **3,870** |
| FP ops | 514 | **828** |
| writes to fp0-fp3 | 58 | **115** |
| field checks | 83,790 | **147,060** |
| programs truncated | 111 + 18 | **0 + 33** |

**Modelling a known deviation beats excluding it, when the deviation has a
short specification.** Excluding threw away 111 of 200 programs and truncated
them at their *deepest* retires, which is where the interesting state is.
Modelling turned the same deviation into 147,060 assertions that the flush is
exactly right.

**33 programs still end on a NaN result, and that is left alone deliberately.**
The units do not share one NaN rule: `i960_fpdiv` emits a canonical
`0x7ff8_0000_0000_0000`, while `i960_fpcvt` propagates sign and payload through
narrowing. Modelling each unit's NaN would mean transcribing each unit's rule
into the reference — which is precisely the agree-by-construction failure the
reference exists to avoid. 16.5% truncation is the honest price of keeping the
oracle independent.

### Proof the check works

Three mutations, each **killed**:

| mutation | result |
|---|---|
| `fpr[d_srcdst[1:0] ^ 1]` — wrong register | killed |
| FP writeback stores `64'd0` — dropped result | killed |
| `fp_lit` 0x16 returns 0.0 instead of 1.0 | killed |

## CPI is mix-dependent, and the synthetic mix is not Model 2's

Worth stating plainly because a single CPI number has been quoted in two places
and they measure different things:

```
T_MULDIV   21699 cycles   9.84 cyc/instr   53.2%   <- dominant
T_FETCH     5343 cycles   2.42 cyc/instr   13.1%
T_FETCH_W   4648 cycles   2.11 cyc/instr   11.4%
T_FP        3350 cycles   1.52 cyc/instr    8.2%
CPI 18.50 (incl. reset and I-cache misses)
```

Fetch was 58% of cycles before the I-cache fill hold and sequential prefetch
went in; it is now 24.5% and **divide dominates**. But the fuzz generator emits
instruction classes roughly uniformly, so divides are enormously
over-represented against real code. 18.50 is the CPI of the generator's mix, and
the earlier 3.31 was a warm-cache figure on a different mix without FP.

**Neither is the throughput number the fit question needs.** That requires the
real instruction mix, which is exactly what **M2-B** measures — still open, and
its value just went up: it now sets the CPI weighting as well as scoping the
FPU. Do not quote a CPI figure without saying which mix produced it.

---

## Register file registered read — done, and it did not deliver

**Measured, not estimated:** Fmax 25.29 → **27.3 MHz**, +8%. The optimisation
backlog called this item "large". It was the best-evidenced item in that table —
1,547 ALM, 49% of the CPU, and the measured critical path ran straight through
it — and it bought 8%.

| | before | after |
|---|---|---|
| critical path | `ra1[2]` → `wd[28]` | `rd1[29]` → `wd[26]` |
| slack | 0.451 | **3.370** |
| Fmax | 25.29 MHz | **27.3 MHz** |
| lockstep cycles | 65,630 | **65,630** |

The change worked; the path just moved. The register read was the **first half**
of the path, and the second half is the execute datapath — operand through the
ALU and the result multiplexing into writeback. Slack went up sevenfold, so the
cut was real. It was not where the remaining time is.

**The latency cost zero cycles**, which was the part expected to be expensive.
Every read address was already presented in the state before its consumer, so
`ra1`/`ra2` became combinational drives in `i960_top` and the register file
supplies the cycle the sequencer used to. Identical cycle count, identical
retire count, identical checks. The item was recorded as "blocked on a step-6
pipeline decision" — the decision turned out to be free.

**The conclusion is the useful part: 90 MHz is not reachable by optimisation.**
From 27.3 that is a 3.3x reduction in path delay and there is no remaining
single structure worth 3.3x. Backlog items 2-5 should not be attempted as Fmax
work — at best they are area and clarity. The execute path has to be split
across stages, which is the pipeline.

### The write bypass: written, mutation-tested, then deliberately removed

A read-during-write forwarding path was written first, on the reasoning that
relying on the sequencer's spacing would be an unstated assumption. **Both
bypass forms were then mutation-tested and both SURVIVED** — across 3,870
retires and 147,060 checks, nothing distinguishes having it from not.

Chasing why that was so produced the real finding. The only reachable
read-during-write is an **overlapping `movl`/`movt`/`movq`** (`movl r4, r5`),
where `T_MULTI` writes word *i* while reading word *i+1*. And that case **has no
oracle**: MAME implements all three with `memcpy` on overlapping regions
(`i960.cpp`, cases 0x5d/0x5e/0x5f), which is undefined in C. The reference
transcribed it faithfully and the generator excludes it.

So the bypass was not insurance — it **silently changed behaviour in the one
case nothing can check**. With it an overlapping `movl` propagates; without it,
and in the original combinational design, it does not. It was removed.

**A refactor must not change semantics the oracle cannot check.** The instinct
that added the bypass was the right instinct applied to the wrong case: dead in
every checked case, and behaviour-changing in the only unchecked one. Mutation
testing is what turned "probably fine" into a decision — the surviving mutant
was the finding, not a failure of the suite.

**Open, and unresolvable from MAME:** what real i960 silicon does with an
overlapping `movl`. Only the i960KB manual or hardware answers it. Recorded here
so it is not rediscovered as a bug.

### Final measurement, and what it means for the gate

`i960_top`, Quartus 17.0.0, `5CSEBA6U23I7`:

```
ALM 6,986   reg 3,487   MLAB bits 2,048   DSP 7   Fmax 27.44 MHz
```

**Area is not the problem and never has been.** 6,986 against a 12K pass band,
inside the budget the fit question depends on. The clock is the problem.

**But "90 MHz" is the wrong number to be failing against**, and the milestones
document already says so at §P1: *"The requirement is throughput, not clock:
12.5-16.7 M instr/s."* The 90 MHz in exit criterion 4 is a proxy, and at the
measured Fmax the proxy and the requirement disagree sharply:

| CPI | at 27.44 MHz | verdict |
|---|---|---|
| 1.5 | 18.29 M instr/s | clears |
| **2.0** | **13.72 M instr/s** | **clears** |
| 2.5 | 10.98 M instr/s | short |
| 3.0 | 9.15 M instr/s | short |
| 4.0 | 6.86 M instr/s | short |

**A 2-CPI pipeline meets the requirement at today's clock, with no Fmax work at
all.** That is the single most useful number produced this session, and it
inverts the conclusion the 90 MHz gate was pushing toward.

It also kills the fallback. Milestones §P1 says *"Target 2 CPI, accept 4."*
**Accept-4 is dead** unless Fmax roughly doubles: 4 CPI needs 50 MHz and 3 CPI
needs 37.5 MHz, against 27.44 measured. The pipeline has to be the aggressive
version, and "we can always settle for 4 CPI" is no longer available as a
retreat.

Restating the target for whoever builds it:

- **Primary: 2 CPI.** Everything else is secondary, including Fmax.
- Fmax buys margin, not viability — every MHz above 27.44 widens the CPI budget
  (37.5 MHz would make 3 CPI viable, restoring the fallback).
- **Do not spend effort on 90 MHz.** It is a proxy that has now been measured
  against reality and found to be ~3.3x stricter than the requirement it stands
  for. Fix the criterion or it will drive the wrong work.

---

## T_DECODE removed — and the bottleneck is now instruction fetch

`i960_top`: **7,015 ALM, 3,504 reg, 2,048 MLAB bits, 7 DSP, Fmax 27.72 MHz.**
All 15 suites pass, 147,060 checks, zero divergence.

### What changed

Even at a 100% prefetch hit rate, `T_FETCH` → `T_DECODE` → `T_EXEC` could not
beat 3 CPI, and 3 CPI at 27.44 MHz is 9.15 M instr/s against a 12.5 M floor. The
decoder is combinational and ~103 ALM, so it now reads the word **arriving**
during a fetch state: the register numbers, the trap check and the prefetch
decision are all available in the cycle the instruction lands. `T_FETCH` and
`T_FETCH_W` merged into one body so the front end is written once.

Measured: **65,630 → 61,560 cycles**, 1.05 cyc/instr, matching `T_DECODE`'s old
1.14 exactly.

### The Fmax loss was a false path, not the decode

The first version cost 27.44 → 24.63 MHz, and the obvious explanation — decode
now sits in the fetch path — was wrong. Selecting one decoder's input with
`(ts == T_FETCH) ? fetch_word : insn` creates a **static** path
`ip → (pf_ip == ip) → dec_in → decode → ALU → wd`. No cycle ever uses it, since
during `T_EXEC` the decoder reads the latched word — but static timing cannot
know that, and it became the critical path at `ip[26] → wd[13]` with **negative
slack**.

Two decoders remove it structurally, for +109 ALM: the arriving-word decode
feeds only the register numbers and the front-end decisions and never reaches
writeback. Chosen over an SDC false-path exception because **a constraint that
stops being true fails silently, whereas a structural fix cannot rot.**
Fmax came back to 27.72, marginally past the original.

**Measure before redesigning, again.** The guessed cause was the decode path;
the measured cause was a multiplexer. Third time this session that reading the
source produced a plausible wrong answer and the timing report produced the
right one.

### Do not report 13.86 M instr/s. The average is 5.20.

A simple instruction on a prefetch hit is now 2 CPI, which at 27.72 MHz is
13.86 M instr/s and clears the floor. **That is the best case and it is not what
the design delivers.** The measured average:

| | cyc/instr | |
|---|---|---|
| `T_FETCH` | 2.39 | |
| `T_FETCH_W` | 1.89 | |
| **fetch subtotal** | **4.28** | **80% of a simple instruction** |
| `T_EXEC` | 1.05 | |
| **simple instruction** | **5.33 CPI** | **5.20 M instr/s — short** |

**The pipeline structure is no longer the bottleneck; instruction fetch is.**
For 12.5 M the budget is 2.22 CPI, so fetch must average **1.17 cycles against
4.28 now**. Where the 4.28 goes:

- **60.8% prefetch hit rate** — 4,101 fetches, 2,493 hits.
- **6,948 fill-wait cycles.** A 16-byte line is 4 instructions, so purely
  sequential code cannot miss less than 25% of the time. Larger lines or a
  deeper prefetch attack this directly.
- **4,626 cycles stuck in `T_FETCH`** waiting for a *discarded* prefetch's fill
  to drain, because the cache ignores requests while filling. This is the
  self-inflicted portion and the most promising: invalidating the line at fill
  start would make an abort safe, letting a redirect pre-empt a fill it no
  longer wants. Not attempted — it is the exact area that produced the stale-
  fill bug, and it wants its own session.

**Caveat, and it is R9 again:** this workload is 200 short programs that each
start cold, so the miss rate is pessimistic against real code with loops. The
hit rate is exactly the sort of number M2-B would replace with a measurement.
Do not tune the cache against this workload and believe the result.

### I-cache fill abort — attempted and reverted (RESOLVED later; see below)

The 4,626 self-inflicted stall cycles are still there. The attempt is recorded
because it eliminated three hypotheses, and the next attempt should not pay for
them again.

**The idea.** The requester waits for `!ic_busy` before issuing, so a
mispredicted prefetch leaves a fill in flight for a line nothing wants and the
next demand fetch waits it out. Let the cache **abandon** a fill when a
different line is requested, and drop the `!ic_busy` guard.

**The safety condition, which is correct and worth keeping.** `cvalid` is only
set on completion, but the *data* array is written word by word during the fill.
So a line that was valid under a different tag has its data destroyed while
still advertising a hit. Harmless while fills always completed; fatal once they
can be abandoned. `cvalid[idx] <= 1'b0` at fill **start** fixes it. Any future
attempt needs this.

**The failure, unchanged across three fixes:**

```
MISMATCH retire 13  g4  got=2094df56 want=00000016  (IP 00000044 insn 5fb80e16)
                    g5  got=68351c4c want=00000016
                    g6  got=99002e43 want=00000016
                    g7  got=6443cdb3 want=00000016
```

`5fb80e16` is `movq` with `src1_lit` set, so all four registers should take the
literal 22. They took what looks like memory contents, which means the **latched
instruction word was not this instruction** — the fetch delivered the wrong
word.

**Three hypotheses, each plausible, each eliminated by making the change and
re-running:**

1. *A speculative prefetch hijacks the demand fill.* The front end also issues
   `ic_req`, so a prefetch could abort the fill `T_FETCH_W` is waiting on.
   Gated the prefetch on `!ic_busy`. **No change.**
2. *`S_DONE` answers a request it did not service.* It asserts `valid`
   unconditionally and ignores `req`; `busy` used to cover `S_DONE` so the
   requester never issued there. Made `S_DONE` service a miss. **No change.**
3. *The abandoned line's partial data is readable.* Addressed by the invalidate
   above, which was in from the first version. **Not the cause.**

**Next attempt starts with instrumentation, not a fix.** Log every `(state, req,
addr, fill_base, valid, data)` tuple for the failing program and find which
cycle hands over the wrong word. Three eliminated guesses is the same signal
that the `sqrtr` bug gave earlier today, and the answer there came from a
per-cycle probe within minutes of giving up on reading the source.

**Standing suspicion for next time:** `req` is a one-cycle pulse and `addr` is
held, so any state that does not consume a `req` in the cycle it arrives loses
it entirely. A pending-request latch — capture `req`/`addr` when they cannot be
serviced, replay on return to `S_IDLE` — is probably the right shape, rather
than patching each state to handle arrivals.

**Also worth knowing: the block harness does not exercise this at all.**
`test_i960_icache` passes with 201,232 fetches because it never issues while
busy. Whatever lands next needs a directed abort test at block level, or the
whole-CPU harness stays the only thing that can see it.

---

## Pushed, 2026-08-17 — `aa8a6ba..78e2bfb`, 12 commits

Tree green: all 15 suites, 147,060 checks, zero divergence. `i960_top` at
**7,015 ALM, 7 DSP, 27.72 MHz** on Quartus 17.0.0 / `5CSEBA6U23I7`.

### One finding from the pre-push check, worth keeping

The rules file was cited **by filename** in three tracked files —
`docs/model2a-design-study.md`, `rtl/cpu/i960/i960_alu.sv` and
`sim/i960/tb_i960_dec.cpp`. That file is git-ignored, so the public tree
carried citations to something not in it, and the rules permit exactly one
reference to it: its line in `.gitignore`. Rewritten to cite the rule rather
than the file.

It predated this session and had already been pushed, which is the point worth
recording: **it survived because nothing checks for it.** The check that caught
it is one grep, and it belongs in the pre-push routine rather than in whoever
happens to look:

```
git grep -ilE "$(printf 'cl%s|anthr%s' aude opic)" -- .   # .gitignore and nothing else
# (the pattern is assembled so that this line does not match its own check)
git log --format='%an <%ae>' @{u}..HEAD | sort -u    # must be the one author
git log --format='%B' @{u}..HEAD | grep -icE 'co-authored|generated with'   # must be 0
```

The authorship and trailer checks were clean; only the filename citation was
not. A rule with no test is a rule that drifts.

### Where the next session starts

**Instruction fetch, not sequencing.** 4.28 of the 5.33 cycles a simple
instruction costs, against the 1.17 a 12.5 M instr/s target allows. The
fill-abort attempt and its three eliminated hypotheses are recorded above —
start with the per-cycle instrumentation, not another fix, and add a directed
abort test to `test_i960_icache`, which currently cannot see that class of bug
at all.

---

## I-cache fill abort — resolved, and the method is the point

`i960_top`: **7,079 ALM, 3,492 reg, 7 DSP, Fmax 26.78 MHz.** All 15 suites,
147,060 checks, zero divergence.

The previous attempt was reverted with three hypotheses eliminated by
inspection. It was solved by doing exactly what that note said to do, in that
order — **write the block-level test, then instrument.** Neither step was a
fix, and both were skipped the first time.

### Step 1: the test the harness could not previously express

A directed redirect pass in `test_i960_icache` issues a fetch, lets the fill
start, then asks for a different line — at every point in a 4-word fill, across
line and set boundaries. It **reproduced the failure at block level
immediately**, where it is minutes to debug rather than a whole-CPU lockstep
divergence 13 retires deep.

That blind spot was real and worth naming: `fetch()` waits for `valid` before
issuing again, so in 201,232 fetches the harness had **never once** asked the
cache for anything while it was busy. It was not that the test was weak; the
scenario was inexpressible.

With that test the cache abort passed in isolation — which is what located the
fault in `i960_top` rather than the cache, after two sessions of assuming the
cache was wrong.

### Step 2: the ring buffer found it in one run

64 cycles of front-end state, dumped on the first mismatch:

```
t=855  ts=T_FETCH  valid=1  addr=00000044  data=5fb80e16  insn=1900bcd4  ip=00000044
t=856  ts=T_EXEC   req=1    addr=00000048  data=5fb80e16  insn=1900bcd4  ip=00000044
```

The correct word is **right there** with `valid` asserted, and `insn` does not
update. One cycle earlier the front end had issued the prefetch and armed it in
the same cycle the *previous demand fetch's* `valid` was still asserted, so the
prefetch captured that stale valid and stored the previous instruction as the
prefetched word. `pf_ip` still matched, so `T_FETCH` accepted it and executed
the wrong instruction.

**Removing `T_DECODE` deleted the cycle that used to separate those two events.**
A latent ordering assumption that had been safe became live — the same shape as
the register-file write bypass, which was dead logic until the same change made
it load-bearing. Two ordering assumptions broken by one restructure.

Fix: arm one cycle after issuing (`pf_armed <= pf_issued`). Costs nothing — the
request is registered, so the earliest a genuine valid can arrive is the cycle
this makes `pf_armed` true.

### What it bought, and what it cost

| | before | after |
|---|---|---|
| waiting out a discarded fill | 4,626 | **601** |
| fill-wait cycles | 6,948 | 9,455 |
| total cycles | 61,560 | **60,037** |
| fetch cost | 4.28 cyc/instr | **3.66** |
| simple instruction | 5.33 CPI | **4.71** |
| Fmax | 27.72 | 26.78 |
| **throughput** | 5.20 M instr/s | **5.69 M instr/s** (+9.3%) |

Fills rise because an abandoned line is refetched if wanted later — the abort
trades stall cycles for refill cycles and wins, but by less than the stall
figure alone suggested.

**Sweeping the abort threshold over `fill_word <= 0, 1, 2` gives byte-identical
cycle counts.** Redirects always arrive at `fill_word 0`, so there is never
partial work to preserve and the policy question is moot. Worth having measured
rather than tuned: the obvious refinement — "don't abandon a nearly-complete
fill" — is dead code in this design.

### Next, and it is the same target

**Fill-wait is now the dominant fetch cost at 2.44 cyc/instr**, up from 1.89.
Throughput is 5.69 against a 12.5 floor, so this is still roughly half-way.

The abort attacked the *stall*; what remains is the **miss rate** itself, and
neither longer lines nor a next-line prefetch has been tried. A 16-byte line is
four instructions, so sequential code cannot miss less than 25% — that ceiling
is structural and only a bigger line or a genuine next-line prefetch moves it.
The 57.5% prefetch hit rate is a next-*word* prediction, which by construction
cannot help across a line boundary, which is exactly where the misses are.

Keep R9 in view: this workload is 200 short programs that each start cold, so
its miss rate is pessimistic against real code with loops. Do not tune line size
against it and believe the number.

---

## ST-V / Saturn as an M2-E proxy — SCSP measured, and it is cheaper than budgeted

Suggested by the user, and it is a better comparable than the N64 in one place
decisively and in another partially.

### The result

`srg320/Saturn` SCSP, Quartus 17.0.0, `5CSEBA6U23I7`:

```
SCSP   ALM 2,030   reg 2,379   MLAB bits 0   DSP 2   Fmax 76.73 MHz
```

**This is not a proxy. Model 2 uses the same SCSP.** It replaces a from-scratch
estimate of **3,000-5,000 ALM** with a measurement of **2,030** — between 1,000
and 3,000 ALM cheaper than budgeted, in the "sound + 2D" bucket that carries
8,500-12,800 of the non-CPU/GPU total. Fmax 76.73 is far above anything this
design needs.

Caveat on the figure: it is srg320's implementation, not ours, and we may not
copy it (see below), so ours could differ. But it bounds the block with a real
number on the real part, which is what M2-E is for.

### Where ST-V beats the N64, and where it does not

- **SCSP: decisively.** Same chip, so a direct measurement rather than a proxy.
- **Era and vendor:** Saturn 1994 vs N64 1996; Sega vs Nintendo.
- **VDP1 as a renderer proxy: partially, and as a FLOOR not an anchor.** It is a
  quad rasterizer and so is Model 2's renderer, where the RDP is triangle-based
  — a real architectural similarity. But §5.5 records Model 2 as having texture
  mapping, bilinear, mipmapping **and a Z-buffer**, and VDP1 has none of those.
  So VDP1 bounds the renderer from **below** where the RDP's 8,347 bounds it
  from **above**. Two measurements bracketing it beats either alone, which is
  better than the "replace N64 with ST-V" framing.

**Licence, re-verified rather than recalled:** `srg320/Saturn` and
`MiSTer-devel/Saturn_MiSTer` both still return `NO LICENSE`. Measurement and
reading only; copying a line is not permitted. Compiling locally to count ALMs
is not distribution.

**Worth knowing for M2-G:** srg320 licenses `SNES_MiSTer`, `FpgaSnes` and
`Main_MiSTer` as GPL-3.0 while `Saturn`, `Saturn_hw`, `SH`, `32X` and `S32X` all
carry none. The omission is a choice, not an oversight, which makes the M2-G
email a sharper question: *you GPL-3 your SNES core; would you grant the same
for the SCSP?*

**Still to measure:** VDP1 and VDP2. The Makefile wires them up
(`make quartus MOD=VDP1`). They instantiate Altera megafunctions, so verilator
cannot elaborate them and there is no pre-fitter check — recorded in the
Makefile rather than papered over with a command that always passes. Rule 8 is
unaffected; it governs `rtl/`.

## Critical-word-first — ATTEMPTED AND REVERTED

A miss currently waits the whole 4-word fill plus a done cycle before `valid`,
when the word actually wanted could be handed over on the first ack. Starting
the burst at the requested word and delivering it straight off the bus should
save ~3 cycles per miss, against 9,455 fill-wait cycles.

Four iterations at block level, reverted. **What it produced is still worth
having:**

1. **Abort and ack must be mutually exclusive.** Written as two separate `if`s,
   a cycle carrying both did both — the restart reset `fill_word`/`fill_cnt` and
   the ack then incremented them, so the abandoned burst continued into the new
   line's slots. Found and fixed; any future attempt needs this.
2. **The real blocker is that `req` is a one-cycle pulse.** Any cycle where the
   cache cannot service it loses it entirely. Critical-word-first adds cycles
   where that happens — a same-line request arriving on the critical-word ack
   assigns `fill_served` both 0 and 1 in the same cycle. Compensating with
   flags (`fill_served`, `early_valid`) is the wrong shape and produced stalls
   at redirect delays 4-5 that survived three different guards.
   **A pending-request latch — capture `req`/`addr` when unservable, replay on
   return to `S_IDLE` — is the prerequisite, not an optimisation.** This is the
   second time that conclusion has been reached from a different direction.
3. **The block harness cannot currently measure this.** Its miss counter is
   "did I see `bus_req` while waiting", which counts a background fill as a
   miss — the sequential walk read 0.500 against a true 0.25. **So the harness
   cannot evaluate critical-word-first even if the RTL were right.** Fix the
   hit/miss definition first.

Order for the next attempt, and it is not the order that was tried: pending-
request latch, then the harness's miss definition, then critical-word-first.

---

## M10K was being measured and thrown away — M2-H now has data

`make quartus_report` extracted the M10K figure into a shell variable and never
printed it. Every Quartus measurement this project has taken has silently
discarded the resource that **M2-H exists to budget**, and that Model 1 found
**binding at 409/553 on this same part** while ALM had headroom.

**Fourth instance of this pattern today**: the FP-register comparison that could
never run, the generator's `>> 8` opcode packing, the reference's dispatch
shift, and now this. Three of the four were a value computed correctly and then
not used. *Computing a thing is not checking it, and extracting a thing is not
reporting it.*

Fixed, and every build already on disk was re-reported without refitting.

### M10K, measured

| module | ALM | M10K of 553 | note |
|---|---|---|---|
| `i960_top` (ours) | 7,079 | **3** | the whole CPU |
| ├ `i960_icache` | 472 | 1 | 512 B instruction cache |
| └ `i960_regs` | 1,655 | 1 | plus 2,048 MLAB bits |
| `SCSP` (srg320) | 2,030 | **26** | same chip Model 2 uses |
| `VDP1` (srg320) | 2,537 | 0 | 512 MLAB bits instead |

**The i960 is not an M10K problem: 3 blocks of 553.** That is worth knowing
before the pipeline work, because a pipeline usually adds buffering and this
says there is room for it.

**The SCSP at 26 is the first real number for the sound block**, against a
budget that had none at all.

**Open, and it should be checked:** `i960_regs` reports **1 M10K plus 2,048 MLAB
bits**, when the design intent recorded in its header is MLAB *only* — chosen
deliberately because §5.6 puts the pressure on M10K blocks rather than bits. One
block is not a crisis, but it is one more than the header says should be there,
and the header explains at length why. Either the rationale or the RTL is wrong.

### VDP1 measured: 2,537 ALM, 3 DSP, 31.52 MHz, 0 M10K

The renderer floor, completing the bracket M2-E started:

| | ALM | what it is |
|---|---|---|
| N64 RDP | 8,347 | Z-buffered, mipmapped, bilinear **and trilinear**, colour combiner, coverage AA |
| **Model 2 renderer** | **8,000 - 14,000 (est.)** | Z-buffered, mipmapped, bilinear, **plus** tile binning and a texture cache |
| Saturn VDP1 | **2,537** | quad rasterizer, **no** Z-buffer, mipmapping or filtering |

**What this does and does not establish.** VDP1 is architecturally closer to us
than the RDP — both rasterize quads, the RDP does triangles — so 2,537 is a
meaningful floor for the *rasterizer core*. But it lacks every feature that
makes Model 2's renderer expensive, so the gap between 2,537 and 8,000 is
precisely the Z-buffer, filtering, mipmapping and tile machinery. It does not
narrow the estimate; it says where the money goes.

The 8,000 optimistic sits essentially *at* the RDP's 8,347, which the study
already justified as "roughly a wash" — cheaper without trilinear, the colour
combiner and coverage AA, more expensive with binning and a texture cache. Both
measurements are consistent with that judgement. **The pessimistic 14,000 is
1.7x the RDP and remains the least supported number in the budget.**

### Two arrays landed where the RTL says they should not, and only the fitter knew

Fixing the M10K report immediately paid for itself twice.

**1. `rcache_frame_addr` — 128 bits in a 10 Kbit block.** Four words, inferred
into an `altsyncram`. Pinned to logic: **−1 M10K, −16 ALM, Fmax unchanged.**
Pure waste, cleanly removed.

**2. `ctag` — the I-cache tag array, and this one is not about area.** Inferred
into an `altsyncram`, 736 bits in a block. The cache header states the tags stay
in flip-flops *"because it is read and compared combinationally on every fetch"*
— and `hit = cvalid[idx] && (ctag[idx] == tag)` depends on exactly that. **A
synchronous RAM read is not a combinational read, so the simulated circuit and
the synthesised circuit were not the same design.** Verilator models the array
combinationally and cannot see it; the standing rule that only a Quartus build
can tell you where memory landed is precisely this case.

Pinned to logic: **−1 M10K, +192 ALM, +665 registers, Fmax unchanged at 26.75.**

**Do not read that as a good resource trade — it is not.** One M10K of 553 is
noise; 192 ALM is real. The justification is correctness, not area: the design
should be the circuit the RTL describes, and relying on Quartus's
"Add Pass-Through Logic to Inferred RAMs" to rescue a combinational read from a
synchronous memory is both fragile and invisible to every test we have.

If ALM later becomes binding, this is a legitimate candidate to revisit — but
only with evidence that the inferred form is actually correct, which nothing in
the current suite can provide.

**Assembled now: 7,239 ALM, 4,209 reg, 1 M10K, 7 DSP, 26.75 MHz.**

**The general lesson, and it is the fourth today.** The M10K column had been
extracted and dropped since the first measurement. Two RTL defects had been
sitting in the design the whole time, both invisible to simulation, both
obvious the moment the number was printed. **An unreported measurement is not a
measurement**, and the cost of not printing it was two wrong circuits rather
than one wrong number.

---

## M2-B — CLOSED. The i960's FPU is cold, and the workload is load/store bound

Measured on real hardware behaviour: MAME 0.289, `daytona93`, traced with the
debugger across four sample points spanning 90 emulated seconds.

**The sample is a full 3D demo race**, confirmed by screenshot rather than
assumed — complete track, cliff geometry, scenery, six cars, textured
throughout. Visually this is the "Daytona at speed" the study names as a worst
case. It is attract mode, not interactive play: the scripted coin insert did not
register (`CREDIT 0/3`), and the difference between demo and interactive is
input handling, which is negligible against a render load.

Execution is genuine and distributed — **4,265 distinct PCs, hottest 0.3%, top
ten 2.8%** — so this is not a wait loop being sampled.

### The mix, over 150,501 instructions

| class | count | share |
|---|---|---|
| **load/store** | 79,575 | **52.9%** |
| integer ALU | 20,453 | 13.6% |
| move | 14,643 | 9.7% |
| compare/branch | 14,078 | 9.4% |
| address (`lda`) | 12,072 | 8.0% |
| call/return | 7,098 | 4.7% |
| **FP** | **1,238** | **0.8%** |
| other | 1,344 | 0.9% |

### M2-B verdict: PASS, decisively

The gate was *"low enough that a microcoded FPU costs no frame time"*.

**FP is 0.8% of instructions, and every one of them is basic arithmetic.
Zero transcendentals in 150,501 instructions.** Not one `sinr`, `cosr`, `tanr`,
`atanr`, `logr` or `expr`.

That makes architectural sense and is the first evidence for it: **the TGP does
the geometry**, so the i960 is the game CPU, not the maths engine. It moves data.

Two consequences for P1, and both reduce work:

- **The FPU can be microcoded and shared.** A wide FPU would be silicon spent on
  0.8% of instructions.
- **The six glibc transcendentals may not be needed at all.** They were carrying
  a large share of the i960's remaining 1,921-6,921 ALM. *Caveat: absence over
  8 frames is not proof of never* — a per-race-start call would not appear here.
  Before deleting them, sample across a race start and a menu.

### What this does NOT establish, and the trap is R8

The trace shows **18,813 instructions per frame**, which at 60 fps is ~1.13 M
instructions/second — against the 12.5-16.7 M/s the study requires. **Do not
conclude the i960 only needs 1.13 M/s.**

`model2.cpp` calls **`i960_stall()`**, and the driver's own notes say the timing
*"may need wait state emulation to fix"*. The instruction *rate* is a product of
MAME's stall model, which is exactly the class of figure R8 was written about
after it produced two wrong conclusions in this document.

**The mix is reliable; the rate is not.** Which opcodes a program executes is
determined by the program. How many it executes per frame is determined by
MAME's timing model, and that model is acknowledged imperfect by its own
authors.

### The immediately actionable result — this is R9's answer

The lockstep generator emits instruction classes roughly uniformly, which is why
`T_MULDIV` was 53% of measured cycles and CPI read 15.91. **Real code is 52.9%
load/store and 0.8% FP.** Divides are enormously over-represented and memory
enormously under-represented in every CPI figure this project has produced.

**Reweight the generator to the measured mix and re-measure CPI.** That converts
throughput from a number that cannot be interpreted into one that can, and it is
the first time that has been possible. Expect it to move a long way: our memory
path is multi-cycle (`T_MEM`/`T_MEM_W`) and is currently 1.5% of the synthetic
profile against 52.9% of reality.

---

## Reweighting the generator found something worse than a bad weighting

**`make test_i960_top` FAILS. Committed that way deliberately — the bug is real
and hiding it would undo the point of finding it.**

The plan was to reweight the lockstep generator to M2-B's measured mix. It could
not be done, because of what the generator turned out not to contain.

### The whole-CPU lockstep has never executed a load or a store

The class selector is `rng() % 10` over ten classes, and **none of them emit a
MEM-format instruction**. Confirmed against the profile: **zero `T_MEM` and zero
`T_MEM_W` cycles across the entire run.**

**52.9% of real instructions — the single largest class by a factor of four —
had never been executed at CPU level.** Every "3,870 retires, 147,060 checks,
zero divergence" result this project has reported was silent about more than
half of what a Model 2 program does.

A second, smaller instance of the same thing: `cls == 41` is dead code, because
`rng() % 10` cannot produce 41. **`test<cc>` has never been generated either.**

### Fixed, and it found a defect on the first run

Added `C_LDST` (the twelve MEMA load/store forms), `C_LDA`, and revived
`test<cc>` as `C_TEST`. Weighting is now table-driven with two modes, and the
default is deliberately **not** the realistic one:

- **coverage (default)** — near-uniform. Frequency is irrelevant to a verifier:
  a rare instruction that is wrong is still wrong, and weighting by frequency
  buries it.
- **`+mix=daytona`** — M2-B's measured shares, for CPI and throughput, where
  frequency is the only thing that matters.

First run, retire 4:

```
MISMATCH retire 4  r10  got=00000009 want=000000ff  (IP 0000001c insn 80500a70)
```

`ldob r10, 0xa70` — a byte load from unmapped memory, which reads `0xffffffff`,
so the byte is `0xff`.

**Narrowed by instrumentation rather than inspection**, and the elimination is
worth keeping:

- **Data memory agrees.** Both sides' data windows are identical, so this is not
  a store divergence surfacing later.
- **The bus transaction is correct**: `RD addr=00000a70 be=1 rdata=ffffffff`.
  Right address, right byte enable, right data returned.
- **Addressing and arbitration are therefore not at fault.** The MEMA effective
  address is right and the LSU won the bus.

**So the defect sits between the bus data arriving and the register writeback —
`i960_lsu`'s extension/lane extraction, or the writeback path in `i960_top`.**
That is a small, well-bounded area to search, and the harness now reproduces it
on the first program.

Note the arbiter was read carefully and looked correct, and it *is* correct.
Inspection has produced a confident wrong answer three times today; the bus
probe settled it in one run. **Instrument earlier than feels necessary.**

### Why this matters more than the CPI number that prompted it

The reweighting was supposed to make throughput interpretable. It has instead
shown that the verification behind every result so far excluded the dominant
instruction class. **The CPI figures were not merely weighted wrongly — the
memory path they should have been dominated by was never executed at all.**

Do not reweight to `+mix=daytona` and quote a number until this defect is fixed:
a mix that is 49% load/store, run against a broken load path, measures nothing.

### Load path defect one: FIXED. The load word was read a cycle after the bus

`ld_word` is extended in `S_NEXT`, one state **after** the ack — but `rd_byte`
and `rd_half` were combinational from **`bus_rdata`**, which by then belongs to
whatever the bus is doing next, usually an instruction fetch.

**The asymmetry is what hid it.** The split/unaligned path always captured at
ack time (`assemble[...] <= rd_byte_split`); the non-split path captured
nothing. And word-sized loads read a stale `0xffffffff` often enough to look
correct, so only byte and half loads showed it.

Fixed by capturing `bus_rdata` into `rd_q` at the ack and extending from that.
`ldob` now returns `0xff` from unmapped memory as it should.

**Why it survived until today: the whole-CPU generator emitted no loads or
stores at all**, and `test_i960_lsu` drives the LSU's bus directly, so its model
holds `bus_rdata` stable across the extension state. The block harness could not
express the failure and the CPU harness never tried. *A defect that needs two
levels to see is a defect that outlives both.*

### Load path defect two: OPEN, and located

```
MISMATCH retire 12  g8  got=873bdc44 want=ffffffff  (IP 00000044 insn a0c00a34)
```

`ldt` — a three-word load from `0xa34`, all three words unmapped, so all three
should be `0xffffffff`. The **first** word is wrong, and the value looks like
real data rather than a stale bus word.

So: single-word loads are now correct, multi-word are not. The loop is
`S_NEXT -> S_XFER` advancing `cur_addr` only in a burst region, and the
suspicion is the address rather than the data, since every word at that address
reads the same `0xffffffff`. **Do not read the loop and conclude — probe
`cur_addr`, `widx` and `bus_addr` per word.** Reading the LSU carefully is
exactly what produced the wrong answer on defect one; the `[lsu]` probe found
it in a single run.

`make test_i960_top` remains FAILING, deliberately.

### Load/store: three defects fixed, one open. `make test` is GREEN (15/15)

All three were the same shape — **a value read one state after the one that
produced it** — and none was reachable before the generator learned to emit
loads and stores.

| # | defect | symptom |
|---|---|---|
| 1 | `ld_word` extended from live `bus_rdata` in `S_NEXT`, one state after the ack | `ldob` returned a later bus word; captured into `rd_q` at the ack |
| 2 | `word_idx` was the live counter, which `S_NEXT` advances in the same cycle it asserts `ld_we` | `ldt` wrote registers 1,2,2 instead of 0,1,2 — first destination never written, last written twice |
| 3 | `ra1` held fixed across `T_MEM`/`T_MEM_W` | every word of an `stl`/`stt`/`stq` stored the SAME register to consecutive addresses |

Defect 3 needed a second index on the LSU: `word_idx` is deliberately one behind
so it matches `ld_word`, while a store needs the **live** index because the
caller must present `r[base + cur_idx]` while that word is being issued. Two
indices because they answer two different questions.

Default (coverage) mix: **4,577 retires, 173,926 checks, zero divergence.**

### Open: `+mix=daytona` still diverges on the store path

```
MISMATCH retire 29  g4  got=ffffff21 want=ffffffff  (IP 000000a4 insn 90a009a8)
MEMDIFF 000009a8   dut=ffffff21 ref=ffffffff
```

`ld r20, 0x9a8` reads what the DUT itself stored there earlier and the reference
did not — so an earlier **byte store went to an address the reference did not
write**. The load is innocent; it is reporting a store that already diverged.

The coverage mix passes and the daytona mix does not, which is exactly why the
weighting exists: at 49% load/store it reaches store cases the near-uniform mix
does not. **Keep both. The realistic mix is not a replacement for the coverage
mix — it is a second axis.**

### CPI: report the coverage figure, NOT the daytona one, until this closes

| mix | CPI | dominant state |
|---|---|---|
| coverage (passing) | **13.57** | `T_MULDIV` 54.1% |
| daytona (FAILING, truncated) | 9.28 | `T_MEM_W` 48.0% |

**The 9.28 is from a run that aborts at retire 29 and must not be quoted.** What
it does show, and this part is already informative, is the shape flipping
exactly as M2-B predicted: divide-dominated becomes memory-dominated,
`T_MEM_W` at **4.46 cyc/instr**. The memory path is where the CPI is, and it was
never measured before because it was never executed.

---

## The store stream was never compared. It is now, and the suite is not green

**Correction to the previous entry.** It reported the default coverage mix as
"4,577 retires, 173,926 checks, zero divergence". That was true and misleading:
**the harness never compared the data-memory write stream**, which the exit
criteria (§7 criterion 2) explicitly require. A store to the wrong address or
with the wrong value is invisible to a register comparison unless something
later loads it back — which is exactly how the daytona divergence was first
seen, 29 retires after the store that caused it.

Added: every store the reference performs is logged in order, the DUT's bus
writes are logged in order, and the two are compared **per retire**.

It found a real defect on the default mix immediately:

```
STORE #1 retire 27  dut=00000f70:309efaf2 ref=00000f70:3ec85418  (insn a2c00f6c)
```

`stt` — store triple. **Right address, wrong value, from word 1 onward.** The
defect was always present; the previous "zero divergence" simply did not look at
stores.

### Why it is not fixed yet, and what was eliminated

Reads are registered in the caller, so `rd1` lags `ra1` by a cycle. When the LSU
issues word *N* from `S_XFER` it sees word *N-1*'s register value.

Two attempts, both measured, both wrong in opposite directions:

| attempt | word 0 | words 1+ |
|---|---|---|
| `ra1 = base + cur_idx` (committed) | correct | **wrong** |
| `ra1 = base + cur_idx + 1` | **wrong** | correct |
| `cur_idx = (S_NEXT) ? widx+1 : widx` | broke `stob` at retire 15 | — |

**A constant offset cannot work**, and that is the finding: word 0's address is
presented from `T_EXEC` and reaches `S_XFER` after a *different* delay than
every later word, which is presented from `S_NEXT`. Any fixed offset fixes one
end and breaks the other. The third attempt tried to make the announced index
state-dependent and regressed single-word stores, so the timing is subtler than
"advance one state early" too.

**The likely correct shape is for the LSU to own the value rather than the
caller** — latch `st_word` into a register when each word's address is known,
instead of reading it combinationally at issue. That removes the caller's read
latency from the critical path entirely rather than trying to compensate for it,
and it is the same move that fixed the load side (`rd_q`).

`make test_i960_top` FAILS. Left that way: the check is correct and the defect
is real, and gating either would restore a green suite that proves less than it
claims — which is what the last four findings have all been.

### FIXED, and the first real throughput number

The LSU now **waits for its operand** instead of the caller compensating for the
read latency. A new `S_OPD` state announces the index it wants and spends one
cycle letting the registered read deliver it. **Stores only** — a load has no
operand to fetch and pays nothing.

That is the move that works precisely because it removes the caller's timing
from the problem rather than modelling it. Word 0's address comes from `T_EXEC`
and later words from `S_NEXT`, so no constant offset could ever suit both; the
LSU asking and waiting is indifferent to where the address came from. Same shape
as `rd_q` on the load side.

**All 15 suites pass, with the store stream compared:**

| mix | retires | checks | result |
|---|---|---|---|
| coverage | 4,577 | 173,926 | PASS |
| **daytona** | **9,769** | **371,222** | **PASS** |

## The first interpretable throughput figure this project has had

| mix | CPI | dominant state | at 26.75 MHz |
|---|---|---|---|
| coverage (uniform, divide-heavy) | 13.65 | `T_MULDIV` 53.7% | 1.96 M instr/s |
| **daytona (M2-B measured)** | **9.49** | **`T_MEM_W` 51.6%** | **2.82 M instr/s** |

Every previous figure was measured on a mix with **no loads or stores at all**.
This one is weighted by what Daytona actually executes.

**Against the study's 12.5-16.7 M instr/s, this is 4.4x short.** Reaching 12.5 M
at today's clock needs CPI 2.14 against 9.49.

### Where the time goes, and it is one place

`T_MEM_W` is **4.90 cyc/instr averaged over all instructions**, and at 49%
load/store that is **~10 cycles per memory access**. Nothing else is close:
fetch is 2.53 combined, execute 1.00, and divide — which dominated every
previous measurement — is 0.84.

**The bus model in the harness acks every cycle**, so those ten cycles are not
memory latency. They are the LSU's own state machine: `S_IDLE -> S_OPD ->
S_XFER -> S_NEXT -> S_DONE` per word, plus `T_MEM`/`T_MEM_W` around it in the
sequencer. One of those cycles is the `S_OPD` this fix just added.

**That is the next target and it is well posed:** cut the per-access cycle count,
not the clock and not the fetch path. A 4.4x throughput gap sitting behind a
single state machine that spends ten cycles doing a one-cycle bus transaction is
a better problem to have than a diffuse one.

Note the i960KB has no data cache and neither does this design, which is
architecturally correct — so this is sequencing overhead to remove, not a cache
to add.

### The three CPI figures now on record, and which to quote

| figure | mix | status |
|---|---|---|
| 3.31 | integer-only, pre-FPU, warm cache | historical, do not quote |
| 13.65 | uniform coverage | valid for coverage, meaningless for throughput |
| **9.49** | **Daytona-measured** | **the throughput figure** |

R9 said a CPI is a property of the mix. There are now three, all correct, and
only one answers the fit question.

## Retire aligned accesses at the ack — CPI 9.49 -> 8.07

`S_NEXT` existed because the load extension happened a state after the ack. That
was the original defect; capturing into `rd_q` fixed the correctness and left
the extra state behind. Doing the work **in the ack cycle** removes the state
entirely, which is where the throughput gap lives.

`rd_byte`/`rd_half` now read the LIVE bus again — correct **here** precisely
because it is the ack cycle, which is what the first version got wrong by doing
it one state later.

The byte-split path still uses `S_NEXT`: its last byte is merged into `assemble`
by that cycle's own non-blocking write, so the assembled word is not readable
until the next cycle. Aligned accesses are the common case and now pay nothing
for it.

| | before | after |
|---|---|---|
| CPI, daytona mix | 9.49 | **8.07** |
| `T_MEM_W` | 4.90 cyc/instr (51.6%) | **3.43 (42.4%)** |
| per memory access | ~10 cycles | **~7 cycles** |
| throughput at 26.75 MHz | 2.82 M instr/s | **3.31 M instr/s** |

All 15 suites pass; daytona mix 9,769 retires / 371,222 checks with the write
stream compared.

**Still 3.8x short of 12.5 M instr/s, and still in the same place.** `T_MEM_W`
remains the largest single cost at 42.4%.

### The next cycle to remove, identified but not taken

`bus_req` is set inside `S_XFER` as a registered assignment, so the request does
not appear until the cycle *after* the state is entered — every access spends a
cycle in `S_XFER` doing nothing but raising a request. Asserting it on the
transition into `S_XFER` would remove that, **but `bus_addr` and `bus_wdata` are
registered in the same place and would have to move with it**, which is a wider
change than it looks and was not attempted at the end of a long session.

That is worth roughly one cycle per word out of seven.

## Unaligned access was never generated either; the REFERENCE was wrong

Attempting the next LSU optimisation (combinational bus outputs, CPI 8.07 ->
7.22) broke the byte-split path outright — and **the whole-CPU harness passed
it.** The block harness caught it. That is the exact reverse of the load
defects, which the block harness could not express and the CPU harness found.
**Both levels are load-bearing and neither is redundant.**

Cause: the generator emitted **word-aligned offsets only**, so the LSU's split
path — reached exclusively by unaligned byte/half/word access — was unreachable
at CPU level. Now byte-granular for the single-word forms; multi-word forms stay
aligned, since `ldl`/`ldt`/`ldq` have alignment rules of their own.

Turning it on found **two reference defects**, both the same shape, and in both
cases the RTL was right:

- **Unaligned store.** The reference replaced the whole word at `t1 & ~3` for a
  word store and used `t1 & 2` for a half — both assume alignment. `st` to
  `0xd66` wrote all four bytes of `0xd64` instead of its upper half and the
  lower half of `0xd68`.
- **Unaligned load.** It read one word at `t1 & ~3` and extracted from it, so
  `ld` from `0xb17` returned the wrong bytes: it needs one byte of `0xb14` and
  three of `0xb18`.

Both now work byte-wise, which is what MAME's memory system does with an
unaligned access.

### The store-stream check was replaced by a memory-state check

The write-stream comparison added earlier was **wrong in a way worth recording**.
An unaligned access legitimately becomes several byte transactions in the DUT
and stays one logical store in the reference, so comparing transaction counts
fails a correct implementation — it reported `dut=4 ref=1` for a single `st`.

What must agree is the **result**, so the data window is now compared **after
every retire**. Per-retire is the load-bearing part: comparing only at the end
lets a store to the wrong address be overwritten before anyone looks, which is
how the `stt` defect survived "zero divergence".

**All 15 suites pass. Coverage mix 4,577 retires; daytona mix passes.
CPI 8.69** — up from 8.07 because unaligned accesses genuinely cost more and are
now being measured instead of skipped.

### The combinational-bus optimisation: reverted, and now testable

Worth ~1 cycle per access (CPI 8.07 -> 7.22, ~10%). It breaks splitting. It was
reverted, and **the coverage that would have caught it now exists** — so the
next attempt gets an immediate verdict rather than a silent regression.

## The I-cache lever cannot be measured, and the fetch cost is an artifact

Swept `LINES` over 32, 64, 128 and 256 — **512 B to 4 KB — and got byte-identical
CPI and hit rate every time.** 7.58 CPI, 67.7% hits, 15,392 fill-wait cycles,
unchanged.

The misses are **compulsory, not capacity**. The generator emits 200
straight-line programs of 60 instructions with the cache cold at each start, so
every line is fetched exactly once and no cache of any size can help. With a
16-byte line — four instructions — 67.7% is close to the structural ceiling for
code that is executed once.

**Real code is nothing like this.** M2-B's Daytona sample executed 38,987
instructions over 4,265 distinct PCs: **9.1x average PC reuse**. The generator's
reuse is 1.0x. Loops are where an instruction cache earns its keep and the
generator has none.

### What this invalidates, including advice given an hour ago

The three-lever plan estimated "I-cache 67.7% -> 90% saves ~1.0 CPI". **That
estimate is not supportable.** The 67.7% is a property of the test workload, not
of the cache, and cannot be improved by making the cache bigger. The real hit
rate under 9.1x reuse is unknown and probably far higher — which means:

- **The fetch component of CPI 7.58 (2.66 cyc/instr, 35% of the total) is
  inflated by an artifact.** Real fetch cost is likely much lower.
- **The measured 3.53 M instr/s is therefore pessimistic**, by an unknown margin.
- **Cache sizing must not be decided on this workload.** A sweep that returns
  identical numbers for an 8x size range is not evidence that size does not
  matter; it is evidence that the workload cannot see it.

Same failure mode as R9, and the fifth instance today of a measurement that
looked meaningful and was measuring the harness: the FP check that could not
run, the M10K column that was dropped, the generator with no loads, the LSU
harness that could not express its own bug, and now a cache benchmark with no
temporal locality.

### What has to happen before the pipeline

**The generator needs loops.** Backward branches with a bounded trip count,
so instructions are executed more than once and the fetch path is exercised the
way real code exercises it. Until then:

- the fetch share of CPI is not trustworthy,
- the I-cache cannot be sized,
- and the pipeline's benefit cannot be estimated either, since its dominant
  stall is exactly the one being mismeasured.

**Do the loops before the pipeline.** Building a pipeline against a workload
that cannot see its main benefit would produce a number as uninterpretable as
the CPI figures were before M2-B.

## Loops added: CPI 7.58 -> 5.98, and the cache question is still open

`+loops` closes an unconditional backward branch over part of the program and
extends the retire budget, so instructions execute more than once. Off by
default — a loop narrows what one program covers, and the default mix exists to
cover instruction forms.

| | straight-line | `+loops` |
|---|---|---|
| prefetch hit rate | 67.7% | **83.0%** |
| CPI (daytona mix) | 7.58 | **5.98** |
| retires | 9,769 | **51,885** |
| checks | 371,222 | **1,971,630** |
| throughput at 26.73 MHz | 3.53 M instr/s | **4.47 M instr/s** |

All 15 suites pass. **The fetch cost really was inflated by the absence of
loops, and 26% of the measured CPI was an artifact of straight-line code.**

### The cache-size question is NOT answered, and the estimate remains unsupported

Swept `LINES` again with loops: 512 B, 1 KB, 2 KB, 4 KB — **still byte-identical.**
The working set at the 60-instruction default is 240 bytes and fits in the
smallest cache, so size cannot matter.

Raised the program to 1,200 instructions (4.8 KB working set, 1.2 KB loop body)
to force capacity misses, and swept 512 B / 2 KB / 8 KB. **Still identical**, and
this time the reason is NOT understood. The build was verified clean and
`LINES=512` confirmed in the source, so it is not a stale binary.

The visible clue: only **3,001 fetches against ~48,000 expected retires**, so the
long programs are trapping early and barely entering the loop. 1,200 random
instructions make an early trap near-certain. That is a *plausible* explanation
and it has not been confirmed — **do not treat it as the answer.**

**What is established, and it points the other way from the earlier estimate:**
Daytona's sample touched **4,265 distinct PCs, about 17 KB** — 34x a 512 B
cache. Real code does not fit. So the earlier claim that real code would hit
*better* than the test is unsupported, and the opposite is at least as likely:
a 512 B cache against a 17 KB working set will thrash.

**Sizing the I-cache needs a workload whose working set is real and which runs
long enough to reach steady state.** Neither condition holds yet. The honest
position is that the cache is currently unsized and unsizable with this harness,
and that the "67.7% -> 90%" estimate should be treated as withdrawn rather than
merely revised.

## Fetch/execute overlap: built, correct, and it never fires. Prefetch depth is why

Built the first real pipelining step — hand the register ports to the successor
during execute so the fetch state disappears on a prefetch hit. It **passed all
15 suites and changed CPI by nothing**: 4.96 before and after, `T_FETCH` still
1.02 cyc/instr.

Instrumented rather than assumed: **`fetch_word_ok` was false in all 50,174
execute cycles.** The overlap was never once eligible.

### One good finding, which cost nothing to prove

**No extra register read ports are needed.** The design note assumed they were
the prerequisite, because instruction N+1's read must happen while N holds both
ports. They do not, because `rd1`/`rd2` are **registered**: this instruction's
result is computed from their current values during `T_EXEC` and latched on the
same edge that loads the successor's operands. Both are correct. That removes
the item the design called "the first work item".

### The actual blocker is prefetch DEPTH

The prefetch is issued when instruction N's word lands and takes about two
cycles to arrive. A simple instruction retires in two cycles — `T_FETCH` then
`T_EXEC`. **So the prefetch lands exactly at the retire boundary**, which is
precisely why `T_FETCH` costs one cycle on a hit rather than being free. During
`T_EXEC` it has not arrived.

Compounded by a correct fix from earlier today: `pf_armed <= pf_issued` arms the
prefetch one cycle after issue, which stopped it capturing the previous demand
fetch's stale `valid`. With a one-cycle `T_EXEC`, that arming has not happened
yet either.

**Overlap therefore needs the prefetch running TWO instructions ahead, not one**
— a small queue rather than a single `pf_insn`/`pf_ip` pair. That is the real
first work item, and it is a much smaller job than adding register ports.

Reverted; the machinery was correct but dead, and dead logic costs area and
reads as working.

### Revised plan, in dependency order

1. **Two-deep prefetch queue.** Prerequisite for everything below. Small,
   contained, and independently testable via the existing hit-rate counter.
2. **Fetch/execute overlap.** Already written once and known correct — the
   condition and the post-case override can be lifted from this session's
   history. Worth ~1.0 CPI.
3. **Memory as a stage.** `T_MEM_W` is 1.64 cyc/instr, ~3.3 per access. Worth
   ~1.15 CPI.
4. Then re-measure. 4.96 - 1.0 - 1.15 ~= 2.8 CPI ~= 9.5 M instr/s, with the
   remainder from Fmax once the execute path is split.

## Two-deep prefetch: worth ~0.6 CPI, and not correct yet

Built the queue the previous entry identified as the first work item — chain a
second request the moment the first lands, so a word is in flight for N+2 while
N executes.

**The mechanism works: CPI 4.96 -> 4.36 in the run that reached the failure.**
That is ~0.6 CPI, or 5.39 -> 6.13 M instr/s, and it confirms prefetch depth was
the right diagnosis. It is **not correct**, and was reverted.

```
MISMATCH retire 39  r14  got=0000001d want=0000001a  (IP 000000d4 insn 58761019)
```

### What was fixed along the way, and is worth keeping

The first version had the front end still issuing its own prefetch for `ip+4`
while the promotion had already supplied that word. The two fought over
`fetch_addr`/`pf_ip`, and `pf_ip` ended up naming an address the promoted word
did not match — so the queue handed over the wrong instruction. Fixed by
prefetching **beyond** whatever the queue holds: `ip+8` when the deeper slot has
just been promoted, `ip+4` otherwise.

That was a real bug and the fix is right. It was not the only one.

### What is still wrong, and how to approach it

The same mismatch survives, so at least one more coherence hole remains between
the two slots and the redirect path. Candidates, in the order worth checking:

1. **Branch redirect flushes only the shallow slot.** `pf_valid` is cleared on a
   redirect but `pf2_valid` may survive with a word for the untaken path, and
   the promotion guard (`pf2_ip == ip + 4`) can be satisfied coincidentally
   after a branch lands somewhere sequential.
2. **`T_FETCH`'s own issue path** clears `pf_valid`/`pf_armed` but knows nothing
   about slot 2.
3. **The len2 path** takes the cache port for its displacement word while a slot
   2 request may be outstanding.

**Do not patch this incrementally.** Two rounds of that produced a fix that was
individually correct and still left the same symptom. The queue wants designing
as a queue — one place that owns fill, promote and flush, with the invariant
stated (slot k holds the word at `ip + 4(k+1)`, or is invalid) — rather than two
sets of registers maintained by three separate code paths.

**Estimated value confirmed at ~0.6 CPI**, which makes it worth doing properly:
4.96 -> ~4.36, and it unblocks the fetch/execute overlap already known to be
correct and worth ~1.0 more.

### Prefetch queue, second attempt: redirect flush was NOT the cause either

Rebuilt the queue as one change rather than a patch, with the invariant stated
and slot 1 flushed on every path that invalidates slot 0 — the candidate the
previous entry ranked first. **Identical mismatch, same retire, same
instruction:**

```
MISMATCH retire 39  r14  got=0000001d want=0000001a  (IP 000000d4 insn 58761019)
```

Three hypotheses eliminated now: the front end's duplicate `ip+4` issue (a real
bug, fixed, not this one), slot ordering, and redirect flushing. Reverted.

**Next attempt starts with instrumentation, not a fourth hypothesis.** That rule
has been right every time today it was followed and wrong every time it was not
— the `sqrtr` bug, the FP-register gap and the store-index bug all fell to a
probe within one run after inspection had failed repeatedly.

Concretely: dump `(ip, pf_ip, pf_valid, pf2_ip, pf2_valid, fetch_word, insn)`
per cycle for the failing program and find the cycle where `insn` is latched
from a slot whose address does not match `ip`. The whole-CPU harness already has
the ring buffer for exactly this; it needs the two extra slots added to the
trace record.

**Worth ~0.6 CPI (4.96 -> 4.36), confirmed by measurement**, so it remains the
right next item — and it unblocks the fetch/execute overlap, which is already
written, known correct, and worth ~1.0 more.

### Prefetch queue, third attempt: one more real bug found, symptom unchanged

Followed the rule and instrumented instead of guessing a fourth time. The ring
buffer, extended with both slots, showed it immediately:

```
t=3838  ts=T_FETCH  ip=000000b4 | pf 000000b4 v0   pf2 000000ac v0
t=3839  ts=T_EXEC   ip=000000b4 | pf 000000b8 v0   pf2 000000b8 v0
```

**`pf2_valid` was 0 on every cycle of the entire run.** Slot 1 never once
became valid, so the queue was never two deep and the measured 0.6 CPI gain
came from something else entirely — worth knowing before anyone trusts that
figure.

Cause: the consume path cleared `pf2_armed` unconditionally, cancelling the
in-flight deeper request on every single instruction. Clearing belongs only on a
redirect. **That is a real bug and the fix is right** — and the mismatch is
still identical, at the same retire, on the same instruction.

**Four hypotheses eliminated, three of them real bugs that needed fixing
anyway.** The instrumentation was worth it — it disproved that the queue was
working at all, which every previous measurement had implicitly assumed.

Reverted. Tree green: 15/15, CPI 4.96, both mixes, nothing uncommitted.

**Next: the same trace, but keyed on the failure rather than read at the tail.**
Print the ring only for the program that fails and widen it to cover retire 39,
then find the cycle where `insn` is latched while `pf_ip != ip`. The dump
currently shows the last 64 interesting cycles of the whole run, which is not
necessarily the failing program at all — that is why the trace above shows
healthy sequential fetching and no fault.

### Prefetch queue: the blocker is the CACHE INTERFACE, not the sequencer

Fourth attempt, and the instrumentation finally named the fault instead of
another symptom. Added a **prefetch invariant** to the harness — whenever the
front end latches a word, it must equal memory at `ip` — and it fired
immediately:

```
[PREFETCH] latched 32c34008 at ip=000000d4, memory has 58761019
           pf_ip=000000c0 v0   pf2_ip=000000c0 v0
```

**Neither slot was valid.** The word came from `T_FETCH_W` accepting `ic_valid`
— a *prefetch's* completion mistaken for the demand fetch's. `i960_icache`
returns `valid` and `data` with **no indication of which request it is
answering**. With one outstanding request that is safe by construction. With a
queue it is not: a prefetch that hits completes while a demand fetch is being
waited for, and the wait state cannot tell the two apart.

**This is an interface problem, and the sequencer cannot fix it.** Three
sequencer-level fixes were tried and all failed for the same underlying reason:

1. flush slot 1 on redirect — clearing the flag does not un-issue the request;
2. count outstanding "stray" answers and discard them — **deadlocks**, because an
   *aborted* fill never answers, so the count never clears;
3. chain the deeper request only during `T_EXEC` — narrows the window, does not
   close it, since the front end also issues prefetches.

### What the next attempt needs, concretely

**`i960_icache` must name the address its `valid` answers.** Prototyped here as
an extra `vaddr` output latched when a request is accepted, with `T_FETCH_W`
matching `ic_vaddr == ip[31:2]`. That much is right and removed the wrong-word
latching outright.

It still stalled, because a second requirement was not met: **a speculative
prefetch must never abort a demand fill.** The cache aborts on any request for a
different line — correct and load-bearing for redirects — so a prefetch issued
while a demand fill is in flight kills it and the sequencer waits forever. The
cache needs to distinguish demand from speculative requests, e.g. a `req_prio`
input where only a demand request may abort.

**Both changes are in `i960_icache`, are small, and are testable at block level**
by the redirect pass that already exists. Do them there, with the block harness,
before touching the sequencer again — the last four attempts all failed in the
sequencer for reasons that live in the cache.

**Kept: the prefetch invariant check.** It catches a wrong instruction word at
the cycle it is latched rather than dozens of retires later as a wrong register,
and it costs nothing. It is the reason this attempt produced a diagnosis rather
than a fifth hypothesis.

## Prefetch queue: three cache-interface defects found, one still open

Fifth attempt, and it produced a **complete diagnosis** rather than another
symptom. Two of the three required changes are proven; the third is a genuine
redesign of the cache's read path and is why this is not landed.

### Added to the cache, and both are correct

1. **`vaddr` — the address each `valid` answers.** With one outstanding request
   a requester may assume every valid is its own. With a queue it may not: a
   prefetch that hits completes while a demand fetch is being waited for, and
   `T_FETCH_W` latched its word as the next instruction. `vaddr` removed the
   wrong-word latching outright.
2. **`req_demand` — only a demand request may abort a fill.** The abort is
   load-bearing for redirects, but a *speculative* request that aborts kills the
   fill the sequencer is waiting on, and it waits forever. Two earlier attempts
   deadlocked on precisely this.

Both pass the block harness's redirect pass. Both are worth keeping.

### Also required, and NOT solved: the data must match the answer

`cdata_q` is registered from `rd_raddr`, and `rd_raddr` is derived from the
**live** `addr`. So the data returned follows wherever the requester has since
moved, not the request being answered. Correct while the requester holds one
address until answered — which a queue does not.

`vaddr` and `data` therefore disagree. The invariant caught it exactly:

```
[PREFETCH] latched 22600000 at ip=000000d4, memory has 5cd89617   pf_ip=000000d4 v1
```

Slot 0 held the wrong word **for its own stated address**.

Reading the array at the latched request address instead broke the ordinary
case — `req_addr_q` is registered, so a hit reads with a stale address, and the
block harness reported 856 mismatches. **The read path needs the live address at
request time and the latched one afterwards**, which is a redesign rather than a
patch, and is where the next attempt starts.

### Sequencer findings, both confirmed

- **No extra register read ports are needed.** `rd1`/`rd2` are registered, so the
  retiring instruction's result is computed from their current values and
  latched on the same edge that loads the successor's operands.
- **The harness needed a retire-ordered view, and the fix is known.** With
  overlap, retires are back-to-back, and the extra tick that let the registered
  write land also retired the successor — comparing two instructions ahead of
  the reference. Applying the pending `we`/`wa`/`wd` inside `dreg()` instead
  gives exactly the retiring instruction's state with no extra tick and no
  assumption about retire length. **That change is required before any
  pipelining lands** and is recorded here rather than in the tree, since the
  multi-cycle design still needs the extra tick.

### Kept: the prefetch invariant

Whenever the front end latches a word, it must equal memory at `ip`. Four
attempts produced four symptoms and no cause; with this, the fifth named the
cause in one run. It is in the tree, costs nothing, and passes.

**Tree green: 15/15, CPI 4.96, both mixes.**

## Prefetch queue and overlap: both now WORK, and neither is landed

Two more attempts on the corrected cache interface. Both got materially
further, and the reason neither is committed is measurement, not correctness.

### The queue is correct and it is a REGRESSION on its own

With `vaddr`, `req_demand` and the fixed read path in place, the two-deep queue
passes everything — 15/15 suites, both mixes, zero divergence, and the prefetch
invariant silent.

**CPI 4.96 -> 5.07.** Slower. The queue does not reduce `T_FETCH` by itself; it
only makes the overlap possible, and meanwhile the extra speculative traffic
costs cycles. **Committing it alone would add logic and lose CPI**, so it is
not committed. It is only worth landing together with the overlap.

One fix inside it worth keeping for next time: the chain must not be gated on
`ts == T_EXEC`. The shallow prefetch actually lands during `T_FETCH`, where it
is consumed directly, so gating on execute meant the deeper request was never
issued and slot 1 never filled. The correct gate is "not while a demand fetch
is outstanding" — `ts != T_FETCH_W && ts != T_FETCH2_W`.

### The overlap FIRES and gives CPI 4.76, with one correctness failure left

With the queue filling properly, the fetch/execute overlap engages for the
first time: **`T_FETCH` 1.02 -> 0.90 cyc/instr, CPI 4.96 -> 4.76.**

```
MISMATCH retire 23  r11  got=00000001 want=bc7f8110  (IP 00000074 insn 5819d50c)
MISMATCH retire 23  IP   got=0000007c want=00000078
```

The IP runs one instruction ahead of the reference, with a register wrong
alongside it. **The harness change is in and correct** — `dreg()` applies the
pending `we`/`wa`/`wd` instead of ticking again, which is what a design with
back-to-back retires needs — so the remaining fault is more likely in the
overlap's own bookkeeping than in the comparison.

**Prime suspect, untested:** the post-case override sets `ip <= ip_next` and
promotes the queue, but the ALU path in the case has already set `ip <= ip_next`
and, on some paths, touched the prefetch registers. Two writers to the same
state in one cycle is the shape of every bug found today. The override should
be the ONLY writer of `ip`, `pf_*` and `ts` on the overlapped path.

### Where this leaves the target

The route is no longer speculative — every step has been executed at least once
and measured:

| step | status | CPI |
|---|---|---|
| baseline | committed, green | 4.96 |
| + queue | works, regression alone | 5.07 |
| + overlap | fires, one bug | **4.76** |
| + memory as a stage | not attempted | est. ~3.6 |

The cache interface that makes all of it possible **is committed and costs
nothing** — `vaddr`, `req_demand`, and a read path that answers the request it
names rather than whatever address the requester has moved to.

### Overlap: the harness is PROVEN correct; the fault is in the overlap

Isolated it rather than guessing. With `exec_can_overlap` forced to `1'b0` and
**every other change kept** — the queue, the addressed valid, and the harness's
retire-ordered comparison — the suite **passes**.

So:

- **The harness change is correct.** Removing the extra tick and applying the
  pending `we`/`wa`/`wd` inside `dreg()` gives exactly the retiring
  instruction's state, for both the two-cycle and the back-to-back case. This
  is the change that must land before any pipelining, and it is now verified
  independently of the thing it was written for.
- **The overlap causes an extra retire.** The DUT ends up one instruction ahead
  of the reference from retire 23, which means one harness iteration advanced
  the DUT twice.

The cycle trace shows the overlap itself behaving correctly — one instruction
per cycle, `ip` 0x74 -> 0x78 -> ... — so the extra advance is at a **boundary**:
most likely the transition from a multi-cycle instruction (`T_MULDIV` at 0x70 in
the failing case) back into an overlapped sequence, where the retire that ends
the multi-cycle instruction and the first overlapped retire land in the same
harness iteration.

**Next: instrument the boundary, not the steady state.** Count overlap firings
and compare against retires — if firings + normal retires exceeds retires
counted, the double advance is proven and localised. The steady state has
already been traced and is correct, so tracing more of it will not help.

Measured value stands at CPI 4.96 -> 4.76 for the overlap, and the queue is
required for it but is a regression alone (5.07).

### Overlap: two more mechanisms eliminated, and what is left

Instrumented the boundary as the previous entry prescribed. **Neither suspected
mechanism is the cause:**

- **No double advance.** Counting DUT IP changes against harness retires shows
  exactly one per retire, every retire, up to the failure.
- **No illegal IP jump.** Every advance of 8 in a single tick is a legitimate
  taken COBR branch (`ts = T_FETCH`, overlap not firing, opcodes 0x30/0x37/0x39
  with +8 displacements). The overlap never skips an instruction.

So the DUT advances correctly and lands on the right addresses, yet by retire 23
it is executing a different instruction from the reference. **The divergence is
in WHICH instruction is executed at a correct address**, not in the address
sequence — which points at the queue delivering a stale or wrong word on a path
the prefetch invariant does not cover, rather than at the overlap's sequencing.

Note the invariant only checks words latched in `T_FETCH`/`T_FETCH_W`. **The
overlap latches `insn <= pf_insn` in `T_EXEC`, which the invariant never sees.**
That is almost certainly the gap: extend the check to the overlap path first —
it is two lines, and every previous round of this bug was solved by an
invariant, not by reading the RTL.

Ruled out and worth not re-testing: the harness (passes with the overlap
disabled and everything else in), double advances, and IP skips.

### Overlap: the fault is localised to one boundary, with an exact symptom

Extended the prefetch invariant to the overlap's `T_EXEC` latch, as the previous
entry prescribed. **It does not fire** — the instruction words the overlap
latches are correct. Also added forwarding for the in-flight write (a genuine
RAW hazard: the successor's operands are read while the current instruction is
still executing, so `we`/`wa`/`wd` describe the *previous* write). **That did
not fix it either**, though the forwarding is correct and needed regardless.

A retire-by-retire IP log of both sides then gave the exact symptom:

```
r22   dut=00000074 ref=00000074  insn=6770c806        FP op at 0x70
r23   dut=0000007c ref=00000078  insn=5819d50c   <== DIVERGED
```

**The DUT advances 0x74 -> 0x7c: eight bytes for a four-byte REG instruction.**
Not a skipped instruction and not a wrong word — an `ip` that moves twice as far
as it should, once.

**The boundary is `T_FP` -> `T_FETCH` -> `T_EXEC(overlap)`.** The preceding
instruction is FP, which `exec_can_overlap` excludes, so the overlap fires on
the *first* instruction after a multi-cycle one. That is the untested
transition: every other path into the overlap comes from another overlapped
instruction or from a plain fetch.

**Prime suspect: `ip_next` is already advanced when the overlap reads it.** The
override does `ip <= ip_next; ip_next <= ip_next + 4`, which is correct only if
`ip_next` still describes *this* instruction's successor. Coming out of a
multi-cycle state, some path appears to have advanced `ip_next` already, so the
overlap lands one instruction too far. Check who writes `ip_next` on the
`T_FP`/`T_MULDIV` retire paths and on the fetch that follows.

**Ruled out and not worth re-testing:** the harness (passes with the overlap
disabled and everything else in), double advances in the steady state, wrong
instruction words on either latch path, and the RAW hazard.

### Prefetch queue: STOP. Read this before the next attempt.

Six attempts. The cache-interface work that came out of it is committed and
correct. **The queue itself is not landed, and the last two rounds produced
contradictory readings, which means the instrumentation was misleading rather
than converging.**

**A real harness bug wasted most of a round, and it is the important lesson.**
The retire loop still contained the extra `tick()` — the one that lets a
registered write land, correct for a two-cycle retire and *wrong* with
back-to-back retires, where it retires the successor too. It had been correctly
removed earlier, lost in a revert, and my re-removal targeted text
(`ip_at_retire`) that no longer existed, so it **silently did nothing**. Every
overlap measurement after that point was taken with the harness double-stepping.

That invalidated a conclusion recorded in this file: the "fault localised to the
`T_FP` -> overlap boundary, `ip` advancing 8 bytes" was **my harness stepping
twice**, not the design. Do not chase it.

**Where the contradiction stands.** With the tick removed and both the queue and
overlap in, the *latch* invariant fires (a wrong word handed over at `ip`) while
the *slot* invariant — same signals, same cycle, checked immediately before —
stays silent. Both cannot be true. One of the two checks is wrong, and finding
which is the first task, before any RTL is touched.

**Rules for the next attempt, earned expensively:**

1. **Verify every harness edit applied.** Three separate `replace` calls this
   session silently matched nothing after a revert changed the surrounding text.
   Assert on the pattern, or diff afterwards.
2. **Gate every invariant on "a program is running."** `mem` is rebuilt per
   program, so a check that runs during reset compares the new program's memory
   against the previous program's queue and reports a defect that is not one.
   Two invariants failed this way and cost a round each.
3. **Reconcile the two invariants before trusting either.** They disagree today.
4. Do not re-test: the RAW hazard (forwarding added, correct, not the cause),
   wrong words on the overlap's `T_EXEC` latch (checked, clean), and steady-state
   double advances (measured, one per retire).

**Value, still measured and still worth it:** overlap CPI 4.96 -> 4.76, queue
required for it but a regression alone at 5.07. That is ~1.0 CPI of the 2.8 CPI
needed to reach 12.5 M instr/s.

**Honest position:** this feature has consumed more of a session than it has
returned. The memory stage — `T_MEM_W` at 1.64 cyc/instr, ~33% of CPI, estimated
~1.15 CPI — is worth comparable throughput, is independent of all of this, and
has none of the accumulated confusion. **Consider doing that first.**

## Memory path: request issued during execute — CPI 4.96 -> 4.51

`lsu_req` was registered, so the LSU did not see the request until the first
`T_MEM_W` cycle. That cycle was spent **merely accepting** it — one of the three
a load costs, against a bus that acks immediately. Driving it combinationally
from `T_EXEC` puts the LSU in its transfer state by the time `T_MEM_W` begins.

Its inputs are ready throughout execute: `ea` is combinational from the AGU,
the `ls_*` controls from `i960_ldst`. Stores gain nothing — they still wait in
`S_OPD` for the register value — and lose nothing.

| | before | after |
|---|---|---|
| `T_MEM_W` | 1.64 cyc/instr (33%) | **1.19 (26.3%)** |
| CPI | 4.96 | **4.51** |
| Fmax | 26.73 | **27.78** |
| ALM | 7,227 | 7,238 (+11) |
| **throughput** | 5.39 M instr/s | **6.16 M instr/s** |

**Chosen over the LSU-side fast-issue path**, which was attempted twice and
failed both times — the second stalling the block harness with no clear cause.
This saves the same cycle without touching the state machine three defects were
recently fixed in. *When two routes reach the same cycle, prefer the one that
does not modify the component with recent history.*

Fmax rose rather than fell, so the added combinational path is not on the
critical one; the gain is most likely the cache-interface work landing.

### Standing position

**6.16 M instr/s against 12.5 M — a 2.03x gap**, from 4.4x at the start of the
session. Area 7,238 ALM against a 12K pass band, M10K 1 of 553.

Remaining measured levers, in order of confidence:

| lever | worth | state |
|---|---|---|
| fetch/execute overlap | ~1.0 CPI | works, blocked on prefetch queue — **see the STOP note** |
| memory as a full stage | ~0.6 CPI left | `T_MEM_W` still 1.19; the store path still pays `S_OPD` |
| I-cache miss cost | 0.49 cyc/instr | 82.5% hit rate; unsized, and unsizable on this workload |

## Memory retire and divide latency — CPI 4.51 -> 3.91

**Retire in the ack cycle.** `done` and `ld_we` were registered, so the
sequencer spent a whole cycle merely *noticing* an access had finished. The LSU
now also exposes `ld_we_now`/`ld_word_now`/`done_now` — the same retire known
combinationally in the ack cycle — and `T_MEM_W` acts on those. The registered
forms remain for the byte-split path, which retires a state later out of
`assemble` and cannot be known early.

**`T_MEM_W` 1.19 -> 0.74 cyc/instr.** Fmax 27.78 -> 26.67, and the net is still
positive: 6.16 -> 6.54 M instr/s.

**Divide ran at double length.** The restoring divider always took 64
iterations. `shifted` takes `quot[63]`, and a 32-bit dividend sat in the LOW
half of `dvd_mag` — so the first 32 iterations shifted out zeros and produced
zero quotient bits. Half the latency of every ordinary divide, wasted, on a
state that was **17.6% of all cycles for about 1% of instructions**.

A 32-bit dividend now goes in the high half and runs 32 steps; `ediv` keeps 64.
**`T_MULDIV` 0.72 -> 0.55 cyc/instr** — less than half, because multiplies share
the state.

### Position

```
i960_top   7,137 ALM   1 M10K   7 DSP   Fmax 26.76
CPI 3.91   ->  6.84 M instr/s   against 12.5 M   =  1.83x gap
session:   2.82 -> 6.84 M instr/s
```

Profile now, and the shape has changed completely from this morning:

```
T_FETCH    1.02   26%   <- the overlap's target
T_EXEC     1.00   26%   <- the overlap's target
T_MEM_W    0.74   19%   was 1.64
T_MULDIV   0.55   14%   was 0.84
T_FETCH_W  0.51   13%
```

**Fetch plus execute is now 52% of all cycles**, and collapsing them is exactly
what the fetch/execute overlap does — worth ~1.0 CPI, which alone would give
~9.1 M instr/s. It remains blocked on the prefetch queue; see the STOP note and
its four rules before attempting it again.

### A shorter route to the overlap, and where it still fails

The two-deep prefetch queue existed **only** to get a word into `T_EXEC`. There
is a cheaper way to the same place: **issue the prefetch combinationally, in the
cycle the current word lands, instead of registering it into the next.** That
buys one cycle of cache latency, so the answer arrives *during* `T_EXEC` rather
than at the retire boundary — no second slot, no promotion, no flush rules.

It works and is correct: `ic_req_eff = ic_req || pf_req_now`, address
`ip + 4`, `req_demand` low so a speculative request can never abort a demand
fill. **All 15 suites pass with it in.**

**On its own it is worth 0.02 CPI (3.91 -> 3.89)** — nothing, because it does
not remove a state. It is purely an enabler, so it was not kept: it adds
combinational paths to the cache request for no standalone gain.

**With the overlap on top, a wrong word still reaches the front end**, always at
the same address:

```
[PREFETCH] latched 22600000 at ip=000000d4, memory has 5cd89617   pf_ip=000000d4 v1
```

`pf_valid` is set and `pf_ip` matches `ip`, so `pf_insn` itself is wrong —
captured for the right address with the wrong data. Address-qualifying the
capture against `ic_vaddr` did **not** fix it, and the early prefetch alone does
not provoke it, so it is specific to the overlap's own re-arm path
(`pf_ip <= ip_next + 4`, `pf_issued`, `ic_req` in the post-case override).

**Next, and it is one experiment rather than a hypothesis:** the queue invariant
(every valid slot holds the word its address claims, checked every cycle,
gated on a running program) tells you the cycle `pf_insn` goes wrong. That check
exists in this file's history and was never run against *this* configuration —
only against the queue. Run it here first.

**Overlap value is unchanged and still the largest single lever: ~1.0 CPI**, with
`T_FETCH` + `T_EXEC` now 52% of all cycles.

### Overlap round 7: a DUPLICATED invariant was manufacturing the failures

The single most useful finding of this round is about the harness, not the RTL.

**`tb_i960_top.cpp` contained TWO copies of the prefetch invariant.** One gated
on a running program, one not. The ungated copy fired during reset — comparing
the new program's memory against a word left over from the previous program —
and every edit made to "the check" went to the *other* copy, so the probes never
changed what was printed.

**Several rounds of this bug were chasing a check that was reporting a defect
that did not exist.** The `[PREFETCH] latched ... at ip=000000d4` failure,
recorded twice in this file as a real symptom, was that duplicate.

With the duplicate removed, both invariants go silent and a **different, real**
failure appears at retire 1 on a `movl` — which the duplicate had been masking
by failing first every run.

**Rules, extending the four already recorded:**

5. **Grep for duplicates before trusting an invariant.** `grep -c` on the
   comment banner would have caught this in one command, and was not run for
   several rounds.
6. **A probe that does not change its output when edited is not being run.**
   That signal appeared twice and was read as "the bug is elsewhere" rather than
   "the edit did not take".

### The shorter route is real and is worth keeping in mind

Also established this round, and independent of the bug: the two-deep prefetch
queue is **not needed**. Issuing the prefetch combinationally in the cycle the
current word lands buys the same cycle of latency, so the successor's word
arrives during `T_EXEC` with no second slot, no promotion and no flush rules.
Six attempts at the queue; the goal was reachable without it.

That variant passes all 15 suites on its own and is worth 0.02 CPI without the
overlap, so it is only worth landing together with it.

**Overlap value unchanged: ~1.0 CPI, the largest single lever, with
`T_FETCH` + `T_EXEC` at 52% of cycles.** Next session starts from the retire-1
`movl` failure, which is the first *real* symptom this feature has produced.

### Correction: the duplicate did NOT manufacture the failure

The previous entry claimed a duplicated prefetch invariant was reporting a
defect that did not exist. **That was wrong and is retracted.**

The two copies were identical except that the second did not increment `fails`,
so it only ever **double-printed**. Neither fires spuriously during reset —
both require `fetch_word_ok`, which requires a valid prefetch, and there is none
during reset.

What actually suppressed the failure was a `checking` gate added in the same
round whose anchor line did not match, so `checking` never became true and the
invariant was silenced entirely. Removing a real check and calling the symptom
an artifact is the more embarrassing of the two mistakes, and it is exactly what
rule 1 (verify the edit applied) exists to prevent.

**The `[PREFETCH] latched ... at ip=000000d4` failure is REAL.** It is the
overlap's first genuine symptom and remains the place to start.

The duplicate is removed anyway — it is committed, it doubled every message, and
one invariant is easier to reason about than two.

### Where the overlap stands after round 7

Three distinct defects are now known on this path, in order of discovery:

1. **Demand must win the cache address mux.** `ic_addr_eff` was
   `pf_req_now ? pf_req_addr : fetch_addr`, which serviced a *demand* request at
   the prefetch's address whenever both fired. Fixed to `ic_req ? fetch_addr :
   pf_req_addr`.
2. **The prefetch capture must be address-qualified**, since the overlap issues
   its own requests and more than one answer is in flight. Applied.
3. **OPEN: `ic_data` and `ic_vaddr` disagree under the combinational request.**
   With (1) and (2) both in, the capture still stores a wrong word for an
   address that matches `ic_vaddr` — so the cache is naming one address and
   returning another's data. Prime suspect is the `S_FILL` "same line adopts the
   fill" rule, which sets `req_addr_q <= addr` for *any* same-line request
   including a speculative one, so a prefetch can rename the answer a demand
   fill is about to deliver. That rule was added for a redirect-within-a-line
   case and predates speculative requests existing.

**Fix (3) in the cache, at block level, before touching the sequencer again** —
the same lesson as rounds 1-4, where four sequencer fixes failed for a reason
that lived in the cache.

### Round 8: the cache is EXONERATED; the fault is the capture/pf_ip ordering

Two things established, both by measurement rather than reading.

**1. Same-line fill adoption is now demand-only.** The `S_FILL` rule that lets a
request for the line being filled become the request the `valid` answers applied
to *any* request, including a speculative one — so a prefetch could rename an
answer a demand fetch was waiting for. Restricted to `req_demand`. **Committed:
block harness clean, whole-CPU clean, no behaviour change to the current
design.** It was not the overlap's bug, but it is a latent one that only a
speculative requester can reach.

**2. The cache is consistent, and this is now checked.** A new invariant asserts
the cache's contract directly: **whenever `valid` is high, `data` must be the
word at `vaddr`.** It stays silent across the whole run with the overlap in.

That matters because two rounds could not tell "the cache answers
inconsistently" from "the front end captures the wrong answer" using only the
consuming end. Now they are separated, and **the cache is exonerated.**

### The remaining fault, stated precisely

`pf_insn` is captured from `ic_data` when `ic_vaddr == pf_ip`, **while the front
end updates `pf_ip` in the same cycle**:

```
capture (before the case):  if (pf_armed && ic_valid && ic_vaddr == pf_ip)
                                pf_insn <= ic_data;   // matches the OLD pf_ip
front end (in the case):        pf_ip   <= ip + 4;    // pf_ip becomes something else
```

Both are non-blocking, so `pf_insn` ends up describing the address `pf_ip` held
*before* the update, while `pf_ip` names a different one. The slot is then
internally inconsistent — exactly what the invariant reports.

In the current design this is harmless because every path that updates `pf_ip`
also clears `pf_valid`, so the inconsistent slot is never consumed. **The
overlap adds a path where it is not cleared**, and the stale word is handed over
as an instruction.

**The fix is to make one place own the slot**: `pf_ip`, `pf_insn` and `pf_valid`
should be written together or not at all. Do not add another guard to the
capture — that has been tried twice and treats the symptom.

**Value unchanged: ~1.0 CPI, the largest remaining lever, `T_FETCH` + `T_EXEC`
at 52% of cycles.**

### Round 9: the corruption is IN THE CACHE ARRAY, not the front end

Made the prefetch slot atomic — `pf_ip`, `pf_insn` and `pf_valid` written only
together, with `pf_req_ip` holding the address a prefetch was *issued* for. That
is the right structure and it passes the baseline unchanged (15/15, CPI 3.91),
but **it did not fix the overlap**, which finally localised the fault.

Printing the whole slot at the failure:

```
latched 22600000 at ip=000000d4, mem 5cd89617
  pf_insn=22600000 pf_ip=000000d4 v1 armed=0 req_ip=000000d4
  icv=0 icva=000000d4 icd=22600000
```

`ic_data` is **22600000 for `ic_vaddr` = 0xd4**, while memory holds `5cd89617`.
**The cache is returning the wrong word for that address** — the slot faithfully
captured what the cache gave it. The front end, the capture and the slot are all
correct.

**Why the cache check missed it:** it is gated on `ic_valid`, so it samples only
the cycles the cache is answering. A corrupted *line sitting in the array* is
invisible to it between answers. Extend it to check `data` against memory
whenever `vaddr` names a mapped address, not only when `valid` is high.

**Prime suspect: a line marked valid with partial data.** `cvalid[idx]` is
cleared at fill start and set at completion, which is correct for an abandoned
fill — but speculative requests now arrive during fills, and the `S_DONE` path
starts a new fill on `req && !hit` without re-checking who owns the line. A
speculative miss landing there can begin a fill that a later demand adopts.

**This is the first round that puts the defect inside `i960_icache` with
evidence rather than suspicion**, and it is the fourth time this feature's fault
has turned out to live one level below where it showed. Fix it at block level:
add a directed test that issues speculative requests during a fill and then
reads the filled line back.

Round 9 changes were reverted; the atomic slot is worth re-applying when the
cache is fixed, since it is correct and costs nothing.

### Round 10: correction — the cache is NOT proven corrupt, and speculation is safe

**Retraction.** Round 9 concluded "the cache returns the wrong word for 0xd4"
from this line:

```
icv=0  icva=000000d4  icd=22600000
```

**`icv` is 0.** The cache was not answering, so `ic_data` was merely the array's
last registered read and carries no claim about correctness. Concluding cache
corruption from a signal sampled while its qualifier is low is the same error as
reading a bus during a cycle nobody acked — and it is the third over-conclusion
on this feature.

**What is now genuinely established**, by a directed block-level test rather
than inference: `spec_during_fill()` issues a speculative request in the middle
of a demand fill, at every point in it, against lines that do and do not alias
the one being filled, then reads back every word of the filled line.
**All pass.** So speculative traffic during a fill does *not* corrupt the line,
does not abort the fill, and does not rename its answer.

That test is committed and is a permanent coverage addition — the harness had no
way to express speculative traffic before, which is precisely the traffic a
prefetching front end generates.

**So the overlap's fault is still not located.** What is known:

- the slot is atomic and still ends up holding a wrong word for its own address;
- the capture check (word vs memory at capture time) is silent;
- the cache contract check (valid implies data == memory[vaddr]) is silent;
- speculative-during-fill is now proven safe at block level.

**Next, and it must be a check that cannot be silent for the wrong reason:**
sample `pf_insn`/`pf_ip` on *every* cycle they change, log the writing path, and
diff against memory. Every check so far has sampled a condition; this needs to
sample a *transition*. Three of this feature's rounds have been lost to a check
that was silent because it was disabled, duplicated, or gated on a signal that
was low.

## Fetch/execute overlap: RESOLVED, and the answer is that it does not pay

After ten rounds, both questions are answered.

### It was never broken. The check was.

The failure that survived nine rounds was a **cross-program artifact**. `mem` is
rebuilt before the DUT is reset, so during those reset cycles the prefetch slot
still holds the *previous* program's word and the invariant compared it against
the *new* program's memory. Gated on a running program, **the overlap passes
everything**: 4,501 retires, 171,038 checks, zero divergence, all 15 suites.

The slot-transition log is what settled it — logging every change of
`pf_insn`/`pf_ip` with the memory truth showed the same address holding two
different values at two times, with **no bus write between them**. Memory had
not changed; it had been *replaced*.

**The gate is now committed, and it prints how many times it armed.** A gate
that silently never arms turned a real symptom into an apparent artifact once
already; a counter makes that impossible to miss.

### And measured, it is a regression

| | baseline | with overlap |
|---|---|---|
| `T_FETCH` | 1.02 | **0.84** |
| `T_FETCH_W` | 0.51 | **0.79** |
| CPI | **3.91** | 4.02 |

The overlap does exactly what it was designed to do — it removes 0.18 cyc/instr
of fetch state — and **costs 0.29 in fill waits.** The instructions it
short-circuits are the ones already in cache, so what still reaches `T_FETCH` is
disproportionately a miss. Making speculative misses drop instead of fill
changed nothing (0.80 vs 0.79), so it is selection, not wasted fills.

**~1.0 CPI was the estimate. Measured, it is −0.11.** The estimate assumed
removing a state removes its cycles; it moves them.

### What is kept

- **The invariant gate**, with its arm counter.
- **`spec_during_fill()`** in the cache harness — speculative traffic during a
  fill, proven safe.
- **Demand-only same-line fill adoption** in the cache.
- Recorded, not kept: the atomic prefetch slot and the combinational prefetch
  request are both correct and cost nothing; they are only worth applying if
  something later needs a word during execute.

**The remaining gap is not in fetch.** With the overlap eliminated as a lever,
CPI 3.91 = **6.84 M instr/s against 12.5 M**, and the next-largest items are
`T_EXEC` at 1.00 (irreducible without a real pipeline) and `T_FETCH_W` at 0.51
(I-cache misses, unsizable on this workload).

### Critical-word-first: third attempt, third failure, and a pattern worth naming

The miss penalty is the right target — a miss costs ~5 cycles (four words plus
a done cycle) before the requested word is available, and in a pipelined design
it stalls the whole pipe rather than one state.

Third attempt, reverted like the first two. The block harness caught every step
immediately, which is the system working:

1. Suppressing the completion `valid` once the critical word is delivered
   **stalls a same-line request** — that request was never answered, because the
   early delivery consumed the answer meant for the earlier one.
2. Clearing `fill_early` for such a request answers it but **breaks the
   redirect cases**, which then take the early path they should not.
3. The sequential miss rate reads 0.25 -> 0.33 -> 0.50 across the attempts, and
   part of that is a harness artifact: the counter treats "saw `bus_req` while
   waiting" as a miss, and with a line still filling behind an early delivery it
   sees one on hits too.

**The pattern across all three attempts is the same**: `valid` is a single
undifferentiated answer, and critical-word-first creates a state where *some*
requests have been answered and others have not. The cache cannot express that.
`vaddr` was added for exactly this class of problem and is not sufficient — it
says which address an answer is for, not whether a given requester is still
owed one.

**What a fourth attempt needs, and it is a design change rather than a patch:**
an outstanding-request record — who asked, for what, and whether they have been
answered — so early delivery can satisfy one requester without silently
consuming another's answer. That is the same conclusion the prefetch queue work
reached from the other direction, and it is now reached twice independently.

**Also required first: fix the harness's miss counter.** "Saw `bus_req` while
waiting" is not a miss once fills continue behind delivered words, and no
version of this change can be evaluated while the metric moves with the
mechanism.

## Fmax: the design is limited by a FAMILY of paths, not one

Throughput is Fmax / CPI, and a whole session went into CPI while Fmax sat at
26.76 MHz with the critical path unchanged since morning: `rd1 -> wd`, register
read through the ALU and result muxing into writeback.

**Tested the obvious cut.** A second execute stage latches the ALU result, so
`rd1 -> ALU -> mux -> wd` becomes two halves. All 15 suites pass.

| | CPI | Fmax | throughput |
|---|---|---|---|
| baseline | 3.91 | 26.76 | **6.84 M instr/s** |
| split execute | 4.12 | 27.20 | 6.60 M instr/s |

**It costs 0.21 CPI and buys 1.6% of Fmax.** Break-even needed 28.2 MHz. A
regression, and reverted.

### Why, and this is the useful part

With the ALU path cut, the critical path became **`insn[11] -> wd`** — a
*different* path of almost the same length, running from the instruction
register through decode and operand select into writeback. Slack 2.628 -> 3.232;
the limit moved rather than lifted.

**So the design is not limited by one long path. It is limited by a family of
comparable paths that all begin at a register feeding decode/execute and all end
at `wd`.** Cutting one promotes the next. That is why:

- registering the register-file read (this morning) bought 8%, not the "large"
  the backlog predicted;
- splitting the execute datapath buys 1.6%;
- and any further single-path surgery will buy about as little.

**Fmax needs a stage boundary that ALL of these paths cross, which is what a
pipeline is** — not a targeted cut. Piecemeal Fmax work is now measured, twice,
as not paying.

### What that means for the remaining 1.83x

Both halves of `throughput = Fmax / CPI` now have the same answer:

- **CPI**: `T_EXEC` at 1.00 is irreducible without overlapping stages; the fetch
  levers need the cache's outstanding-request record; everything cheap is done.
- **Fmax**: limited by a family of paths, liftable only by a real stage
  boundary.

**Both roads lead to the same place, and it is a genuine pipeline.** The
incremental route returned +143% this session (2.82 -> 6.84 M instr/s) and is
now exhausted -- every remaining lever has been measured and each is worth
under 2%, negative, or blocked on the same missing cache abstraction.

## Fmax: three stage boundaries measured, none pays. The delay is INSIDE the units

| configuration | CPI | Fmax | throughput |
|---|---|---|---|
| baseline | 3.91 | 26.76 | **6.84 M instr/s** |
| + X/W boundary (ALU result registered) | 4.12 | 27.20 | 6.60 |
| + D/X boundary (decode registered) | 3.91 | 26.54 | 6.79 |
| + both | 4.12 | 26.60 | 6.46 |

**Every cut moves the limit rather than lifting it**, and the path report says
why each time:

- baseline: `rd1 -> wd`
- with X/W cut: `insn[11] -> wd` — a different path, nearly as long
- with both: **back to `rd1 -> wd`**, slack 2.628 -> 2.409

`rd1` feeds the ALU *and* the AGU, and both end at `wd` — `lda` writes
`wd <= ea`. Registering the ALU's output simply promotes the AGU's path. There
is a **plateau** of comparable paths, all of the form
`register -> one functional unit -> wd`.

### The conclusion, and it is well evidenced now

**A stage boundary cannot lift Fmax here, because the delay is inside the
functional units rather than between them.** Cutting at a unit's output leaves
`rd1 -> unit`, which the X/W experiment showed is most of the delay: registering
the ALU output bought 1.6%.

So a universal writeback stage — every unit's result through one register —
would cost ~1.0 CPI (break-even needs Fmax > 33.6 MHz) and, by the same
measurement, would not get there.

**Fmax work means making the units shallower**, which is backlog item 2 (share
the ALU datapath: 973 ALM, six shift forms, four comparators and three adders
described separately) and its equivalent for the AGU. That reduces logic depth
without costing a cycle, and it is the only remaining lever that is not blocked.

**What is now measured rather than assumed:** the pipeline the spike document
has called for since the beginning would *not*, on its own, fix Fmax on this
design. It would fix CPI. Those are different problems here, and only one of
them has a structural answer.

## THE THROUGHPUT REQUIREMENT IS MET. It was met before this session started.

Measured, not inferred: **Daytona's i960 executes ~15,400 instructions of work
per frame = 0.93 M instr/s. The core delivers 6.86 M instr/s. 7.4x margin.**

| frame | instructions | in a spin loop | distinct PCs | hottest PC |
|---|---|---|---|---|
| 1 | 14,469 | 14 (0.1%) | 4,201 | 0.4% |
| 2 | 14,474 | 14 (0.1%) | 4,207 | 0.4% |
| 3 | 17,441 | 14 (0.1%) | 4,159 | 0.5% |

Three single-frame traces of `daytona93` under MAME 0.289. The work is genuine
and distributed — 4,200 distinct PCs per frame, hottest 0.4%, **0.1% spinning**
— so this is not a CPU idling against a slow emulator.

**The 12.5-16.7 M instr/s figure was the chip's capability, never the game's
demand.** A 25 MHz i960KB at 1.5-2 CPI delivers that. Nothing ever measured what
Model 2 software needs.

### Why this survives R8

R8 warns that MAME's cycle counts are estimates and `model2.cpp` calls
`i960_stall()`. **This measurement does not use MAME's cycle model.** It counts
instructions between *frame boundaries*, and the frame boundary comes from video
hardware. The remaining objection — MAME starving the CPU so it never finishes
its per-frame work — is answered three ways: the game renders correctly
(screenshot), the per-frame count is **stable across frames**, meaning a fixed
workload rather than work-until-vblank, and there is almost no spinning.

### What this changes

- **P1's throughput exit criterion is met**, with margin. The pipeline that §4.3
  has demanded since the beginning is **not required for Model 2**. It would be
  required to match the real chip, which nobody asked for.
- **The remaining i960 work is functional**: faults, `synmov`/`synmovq`,
  `calls`, `modpc`, interrupts, the `rl` forms. M2-B already suggested the six
  transcendentals may be unnecessary.
- **Area, not speed, is what the fit question needs from this core** — and at
  6,986 ALM against a 12K band it has been comfortable throughout.

### The lesson, and it is the third instance

A full session went into throughput. Every step was real — 2.82 -> 6.86 M
instr/s, six defects fixed, seven coverage holes closed — but **the target was
never verified**. R9 was a CPI quoted without its instruction mix; this is a
throughput target quoted without its workload. The measurement that settles it
took hours and could have been done first.

**Before optimising against a number, establish what measured it.**

## The i960's remaining work is ONE instruction, not thirty-four

Cross-referenced 196,885 instructions of Daytona traces against what the design
implements. **80 distinct mnemonics executed; exactly one is missing:**

```
callx    513    0.261%
```

Every other mnemonic the game uses is built. The coverage figure of "129 of 163"
counts the *architecture*; against the *workload* it is 79 of 80.

**That reframes the remaining i960 work completely.** The 34 unimplemented
mnemonics are not 34 tasks — they are one task plus a list of things Daytona
never executes. The six glibc transcendentals, the `rl` forms and `remr` do not
appear at all, consistent with M2-B finding zero transcendentals.

*Caveat, and it is real:* one game, in attract mode running a full demo race.
Interactive play adds input handling. Other Model 2 titles may use more. But as
a scoping measurement it is far better than building all 34 and discovering
which are dead.

### callx: implemented, and NOT yet correct

`callx` is MEM format — compute the effective address, then call it. Both halves
already existed: the AGU produces `ea`, `call_target` is already wired to
`alu_or_ea` which selects `ea` for MEM format, and the frame machinery is the
same one `call` uses. Joining them is a few lines in `i960_ldst`, the sequencer,
and both references.

Done, and it diverges:

```
MISMATCH retire 43  g15  got=00000009 want=9d3d02c0   (later instruction)
```

`g15` is FP, and `FP = (SP + 63) & ~63` is always 64-aligned — `9` is not a
frame pointer. **The reference performs the call and the DUT does not**, with
the divergence surfacing later on an unrelated instruction.

Verified present and therefore NOT the cause: `8'h86` decodes in `i960_ldst`
with `no_mem`, the sequencer's `d_op == 8'h86` branch exists, `0x86` is MEM
format, and `lsu_req` correctly stays low for it.

Worth checking next: whether the DUT reaches `T_FRAME` at all for `callx`
(count entries with and without it generated), and whether `agu_valid` holds for
its addressing mode. Reverted rather than committed -- an implementation the
harness has not verified is the same as no implementation.

One generator note worth keeping: `callx`'s address is a **call target**, so it
must point at code. Aimed into the data window it calls unwritten memory and
executes `0xffffffff`, which tests the trap path instead of the call.

### SDRAM widened to 128 MB, and the full Daytona set restored

**Sorted rather than left hanging.** `m2_sdram` now addresses **128 MB** and the
Daytona MRA carries all **29 parts / 43.62 MB** again. Build clean at **7,796
ALM**, timing clean, 17 suites green. Deployed.

**The geometry was forced, not guessed.** The MiSTer connector gives 13 address
pins and 2 bank pins, so with 13 row bits the module size is decided entirely by
the column count, and only one value reaches 64M words:

| `COL_BITS` | geometry | size |
|---|---|---|
| 9 | 8192 x 512 x 4 | 32 MB |
| 10 | 8192 x 1024 x 4 | 64 MB |
| **11** | **8192 x 2048 x 4** | **128 MB** |

**Column bits map to A0-A9 then A11, A12, skipping A10** — the auto-precharge
flag. That is why the Model 1 comment records ten column bits taken as `[10:1]`
aliasing: it puts a column bit where the precharge flag lives.

**Both geometries are proven against the device model**, and the 32 MB case is
kept as a regression net:

```
make test_m2_sdram      9 column bits ->  32 MB   74,729 checks, 0 fails
make test_m2_sdram128  11 column bits -> 128 MB   58,739 checks, 0 fails
```

**A real bug in the lifted device model, found by doing this.** At 11 column bits
it reported **3,965 data mismatches with ZERO protocol violations** — timing
perfect, addressing wrong. The model took `col = a[COL_BITS-1:0]`, a straight
slice that is correct up to ten bits and at eleven **consumes A10, the
auto-precharge flag it tests elsewhere in the same file**. A correct controller
looked broken. Corrected to `{a[12], a[11], a[9:0]}`; **worth reporting upstream,
since Model 1 will hit it the moment it goes past 32 MB.**

Changes to lifted code are recorded in `THIRD_PARTY.md` rather than made quietly:
the controller's geometry is parameterised and its ports widened, the loader takes
`SDR_AW`, and the harness and testbench take the geometry as a parameter.

**`check_mra` earned its place immediately** — it caught me putting `--` back into
an XML comment while restoring the MRA, which is the exact fault it was added for.

### i960 interrupts, increment 4: synmov built, and a divergence LEFT OPEN

**`synmov` is the only way `ICR` is ever written** (MAME `i960.cpp` 0x60.0), and
`ICR` supplies the vector byte for each external IRQ line — so interrupts are
unreachable without it. It is a memory-to-memory dword move with one magic
destination:

```
t1 = src1 (destination address)      t2 = src2 (source address)
if (t1 == 0xff000004) ICR = mem[t2]; else mem[t1] = mem[t2];
AC[2:0] = 2
```

**Implemented in both the reference and the module.** The module uses the boot
walk's bus master, generalised to an "aux master" with a write phase, because
synmov's two addresses are *register values* rather than a decoded effective
address — the LSU cannot supply that. Two states, `T_SYNMOV_RD` and
`T_SYNMOV_WR`.

**IT IS NOT VERIFIED, AND THE GENERATOR WEIGHT IS ZERO.** Turning it on is one
number in `W_COVER`. With it enabled the lockstep fails:

```
MEMSTATE retire 22  6bc4a65c dut=deadfbcb ref=ffffffff  (insn 6004c006)
```

`insn 6004c006` decodes src1=6 (destination), src2=19 (source), op2=0. **The DUT
read address 4** — it wrote `deadfbcb`, which is the PRCB word at `mem[4]` — where
the reference read `r19`. So the module's source address is wrong, and 4 is one of
the boot walk's own addresses, which points at `boot_addr` not being updated when
the synmov dispatch believed it was. The reference wrote to its own `t1`
elsewhere, which is why the check reports the DUT's address as absent rather than
differing.

**The latching fix was TRIED AND DID NOT WORK** — both addresses are now latched
at dispatch and the request raised from the latched value in the next state, and
the failure is bit-identical: `MEMSTATE retire 22 6bc4a65c dut=deadfbcb
ref=ffffffff`, same address, same value. So the callx-shaped hypothesis is wrong
and is recorded as such.

**What the evidence actually says, re-read:** the DUT wrote to `0x6bc4a65c`, and
that address matches the REFERENCE's own `t1 = r[6]`. Had the reference executed
`synmov` it would have written *something* to that same address. It wrote nothing.
**So the reference's branch is not firing, and the module may be correct.**

Checked and eliminated: `0x60 < 0x80` so the format is `FMT_REG`; the branch sits
at the top of that case, before anything that could intercept; `op2` really is
`(insn >> 7) & 0xf` and is 0 for `6004c006`; and bit 11 is clear so `src1_lit` is
false on both sides.

**Next step: instrument the reference, do not reason about it.** Print whether the
branch is entered and what `t1`/`t2` it computes for `insn 6004c006`. One printf
settles what four inferences have not. The module is not the suspect. `ra1`/`ra2` are
driven a state ahead and revert on leaving `T_EXEC` — that is exactly what bit
`callx`, where the call target had to be latched rather than presented live. This
smells like the same fault in a new place. **Latching both addresses at dispatch,
as `call_tgt` does, is the likely fix.**

**Also still open for interrupts:** `take_interrupt` itself, the `irq[3:0]` input
and immediate path, and type-7 `ret` restoring PC and AC.

### i960 interrupts, increment 3: the core boots itself from low memory

**`T_BOOT` reads the startup record before the first instruction fetch**, the way
the real part does (MAME `device_reset`):

```
SAT = mem[0]     PRCB = mem[4]     IP = mem[12]
```

Verified, not assumed — the harness checks the loaded values against the record it
laid down:

```
[boot] SAT=dead5a70 PRCB=deadfbcb IP=00000100  loaded from mem[0]/mem[4]/mem[12]
```

**That check exists because arriving at `PROG_BASE` proves only that the IP is
right, and it would have been right by accident if the walk had never run.** SAT
and PRCB carry distinctive values in the record for exactly that reason. The
harness no longer pokes the IP at all.

A boot master sits above the register-file spill in the bus arbiter, which is safe
because it only runs in `T_BOOT`, before any other master can have work. On the
last read it sets `ip`, mirrors it into `pf_ip` and invalidates the prefetch slot,
so the first fetch goes to the loaded address rather than to whatever the front end
speculated from the reset value of 0.

**7,055 -> 7,082 ALM**, lint clean, 17 suites green, 12 seeds clean.

**`PRCB` is now real, so `take_interrupt` is buildable.** What remains for
interrupts:

1. **`ICR` needs a write path.** MAME's `m_ICR` is set by the game; find how (it is
   not a plain memory write — check `sysctl`) before guessing.
2. **`take_interrupt`** — the sequence is written out in the increment-1 notes:
   PRCB+20/+24, the vector fetch at `int_tab + 36 + (vector-8)*4`, the stack
   computation, `do_call(IRQV, 7, SP)`, three frame writes, then the PC update.
3. **The `irq[3:0]` input and the immediate path** — vector from the `ICR` byte,
   priority = vector/8, taken when `cpu_pri < priority`.
4. **Type-7 `ret` restoring PC and AC**, which is deliberately absent on both
   sides today so they stay identical.

### i960 interrupts, increment 2: the architectural state exists

`PC`, `SAT`, `PRCB` and `ICR` are registers in both the module and the reference,
with MAME's reset values from `device_reset`:

| register | reset | why it matters |
|---|---|---|
| `PC` | `0x001f2002` | bit 13 is the interrupt flag, `[20:16]` the priority — `take_interrupt` reads both |
| `SAT` | 0 | should be `mem[0]` |
| `PRCB` | 0 | should be `mem[4]`; the interrupt table is at `PRCB+20` |
| `ICR` | `0xff000000` | one vector byte per IRQ line |

**6,979 -> 7,055 ALM** (+76), Fmax 26.84 -> 26.34, lint clean, 17 suites green.

They are exposed as `dbg_pc/sat/prcb/icr` rather than lint-waived: they are written
and not yet read, and on hardware the screen is the only output channel, so making
them observable is what one would want regardless.

**WHAT IS DELIBERATELY NOT DONE, and it blocks enabling interrupts:** loading
`SAT = mem[0]`, `PRCB = mem[4]` and **`IP = mem[12]`** at reset. That needs a boot
state machine issuing three reads before the first fetch, which means either a new
bus master or a way for the sequencer to drive the LSU with no decoded instruction
behind it. **Until it lands `PRCB` reads 0 and the interrupt table would be looked
up at the wrong address**, so interrupts must not be enabled on top of this.

It also matters independently of interrupts: **our core starts at IP 0 and the
real part starts at `mem[12]`**, which is a difference any real ROM will notice.

**The harness angle to think about first.** The lockstep generator writes its
program at address 0, so `mem[0]`, `mem[4]` and `mem[12]` are program words. Once
reset reads them, either the harness must lay down a real boot record and move the
program (the generator uses absolute `callx` targets, so they shift too), or both
sides agree on nonsense and most programs get abandoned by the out-of-range guard.
**The first is the faithful option and is the work.**

### i960 interrupts, increment 1: `ret` now dispatches on the frame type

**The shared blind spot R14 recorded is closed.** `ret` ignored `PFP[2:0]` in BOTH
the module and its reference, so the two agreed and lockstep could never see it.
MAME dispatches:

| type | meaning | us |
|---|---|---|
| 0 | ordinary return | as before |
| **1-6** | MAME `fatalerror` | **`ret_unsupported` -> trap**, both sides |
| 7 | interrupt return | legal: `do_ret_0`, **PC/AC restore still missing** |

**Type 7 is deliberately not trapped.** It is a *legal* return type, and trapping a
legal one would be a different wrong answer. The module performs the `do_ret_0`
half, which is all of it that is reachable — nothing in this core can create a
type-7 frame until interrupts exist. **The reference deliberately does NOT restore
PC/AC either**, so both sides are incomplete in the same way on purpose; a
reference that restored AC while the module did not would diverge on the one
register lockstep actually checks.

**Two tests were asserting the old assumption and had to be corrected, not
worked around:**

- `tb_i960_regs`'s random *register write* could set PFP to an illegal type 1-6,
  which its reference then returned from as though it were type 0. The type field
  is now constrained to 0 or 7 — the other 29 bits stay random. Testing an
  architecturally impossible input against a reference that pretends it is legal
  proves nothing.
- The "ret from type 7" case expected a plain return, which is correct, and is
  why type 7 must not trap.

17 suites green.

### What the ORACLE says the rest of interrupts needs

Read from `i960.cpp` before writing any more RTL:

- **Reset:** `SAT = mem[0]`, `PRCB = mem[4]`, **`IP = mem[12]`**, `PC = 0x001f2002`,
  `ICR = 0xff000000`. **Our core starts at IP 0 and reads none of this** — that
  alone matters for running real ROM.
- **The common path is register-only.** `execute_set_input` takes the *immediate*
  path when `cpu_pri < priority`: three registers, no memory access. The
  pending-table-in-memory path is only for interrupts that cannot be taken yet.
  Model 2 uses "the cheapest solution" — four external lines, vectors straight
  from `ICR` bytes, priority = vector/8.
- **`take_interrupt`:** read `PRCB+20` (int table) and `PRCB+24` (int stack), then
  `IRQV = mem[int_tab + 36 + (vector-8)*4]`; SP is the int stack unless already
  interrupted (`PC & 0x2000`), then `(SP+63) & ~63`, `+64`; `do_call(IRQV, 7, SP)`;
  write PC, AC and `vector-8` to `FP-16`, `FP-12`, `FP-8`; then
  `PC &= ~0x1f00; PC |= lvl<<16; PC |= 0x2002`.

### SDRAM GEOMETRY MEASURED: 64 MB, and the full ROM set fits

| `COL_BITS` | size | result |
|---|---|---|
| 9 | 32 MB | works |
| **10** | **64 MB** | **works — ship this** |
| 11 | 128 MB | aliases |

**The part presents 1024 columns, not 2048.** Ten uses the contiguous A0-A9 range
with A10 left as auto-precharge; eleven is the first value needing a column bit on
A11, and that is where it breaks. Study **R19**.

**The 43.62 MB ROM set fits in 64 MB with 20 MB spare.** No DDR3 split, no trimmed
MRA, uniform SDRAM latency for every consumer, and the renderer needs no DDR3 path.
The board minimum is 64 MB and that is now measured rather than inferred.

**How it was settled:** walking the parameter down one step at a time against a
checksum over 36,864 real words. **A single-address test passes at every setting,
including the broken one** — which is precisely why the SDRAM self-test stayed
green through twelve builds while the copy was corrupt.

### P1.5 COMPLETE: Model 2 2D RENDERS CORRECTLY ON HARDWARE

**Daytona's attract screen, drawn by our tilemap, on a DE10-Nano.** Mountains,
grass, the VR button graphic, INSERT COIN(S), CREDIT 0/3, the SEGA logo. Both copy
checksums exact: **`A66F51B7`** and **`5BFDD5AF`**.

The whole chain is proven on silicon: MRA -> `ioctl` -> loader -> SDRAM -> copy
engine -> on-chip tile RAM and palette -> S24TILE fetch, decode, mix, palettise ->
video timing -> overlay -> screen.

**The cause was `COL_BITS`, which I had changed myself and never suspected.** The
geometry for a 128 MB module was **inferred** from the connector's pin count, not
measured. At 11 it aliases on this board. At **9** — the value the Model 1 core
runs on the same hardware — everything is correct. Study **R18**.

**Why it took twelve builds, and the lesson is about evidence:** column aliasing is
invisible to a test that reads one address repeatedly and fatal to a walk across
many. The self-test (four words, one address) passed every time; the copy engine
(36,864 addresses) failed every time. That split was visible from the first result
and I read it as a port problem, a burst-length problem, a clock-domain problem, a
byte-lane problem and a capture-phase problem in turn — **all code I had not
touched. The one thing I had changed was never on the list.**

The question that broke it was not mine: *"how comes my Model1 is fine with the
SDRAM?"* The answer was that it does not run the same configuration.

**NEXT: `COL_BITS = 10` for 64 MB.** 32 MB does not hold the 43.62 MB ROM set. Ten
covers it and needs only A0-A9, leaving A10 as auto-precharge — no A11, so no
dependence on the inference that just failed. If 10 also aliases, the module is
32 MB-organised whatever its capacity and the DDR3 split becomes a real P6
requirement.

### CAUTION on my own evidence, from the Model 1 core at `d53a149`

That project found **six TGP defects in a day** and wrote down two lessons that
apply directly here, so they are recorded before the next session repeats them.

**1. A suite can pass because it does not model the conditions the fault lives
in.** Their `mb86233_agu` ran 3,000,000 cases and missed a defect "because it
tests the AGU as a combinational function while the fault is in *when* the core
applies it — nothing in that suite has a stalling memory."

**2. "diverged=0 has now been cited as evidence three times and found not to
be."**

**Both land on me.** I have cited `test_m2_sdram`'s **74,729 checks, 0 fails** as
proof the SDRAM controller is sound at least four times today. That suite is
better than the AGU case — it has a device model with protocol checking — but it
runs under Verilator against a *model*, not the board, and the fault in play is
one the model does not reproduce. **It is evidence the controller is logically
consistent with the model. It is not evidence the controller works.**

**3. Their fault class is worth checking for directly:** the AGU post-increment
"fired once per CYCLE, not once per access", because the state is held while the
access completes — the same shape as the FIFO pop/push that preceded it. Our copy
engine clears `cp_req` on ack, so it is one action per handshake; but `p_ack` is
held for `ACK_HOLD` cycles, and **anything that samples an ack as a level rather
than an edge in this design is suspect.**

### And a hypothesis I got wrong, recorded before the board disproves it

I argued the fault was the single-word read path because the copy engine was "the
only consumer of a `blen=1` port". **That is false.** `Model1.sv` line 429 reads
`.sdr_dout(p_dout[0][15:0])` — its V60 uses port 0, single-word, and that core
works on hardware. So `blen=1` is exercised and sound in the sister project.

The deployed build still discriminates, because our port-0 usage differs from
theirs in one respect that remains untested: **theirs is sporadic CPU traffic,
ours is 36,864 back-to-back reads at maximum rate.** If moving to port 1 fixes it,
the difference is the access *pattern*, not the port width.

### The tilemap renderer is VERIFIED against MAME, point by point

Checked after the first garbled render, because porting Model 1's renderer without
reading the oracle for Model 2 was the wrong way round. **Every decode rule
matches `segaic24.cpp` exactly**, so the RTL is not where the fault is:

| | MAME | our RTL |
|---|---|---|
| tile mask | `S24TILE(config, m_tiles, 0, 0x3fff)` in `model2.cpp` | `14'h3FFF` |
| tile number | `val & tile_mask` | `tile_word[13:0] & tile_mask` |
| colour | `(val >> 7) & 0xff` | `tile_word[14:7]` |
| palette index | colour x 16 + pixel | `{colour, pixel}`, 12 bits |
| char address | 16 words per tile | `{tile_num,4'b0}+{map_y[2:0],1'b0}` |
| map bases | `0x0000/0x1000/0x2000/0x3000` | `{1'b0, layer, ...}` |
| map scan | `TILEMAP_SCAN_ROWS`, 64x64 of 8x8 | `{map_y[8:3], map_x[8:3]}` |
| control regs | `tile_ram[0x5000]`, `[0x5004]` | `15'h5000`, `15'h5004` |
| `char_r` | linear `uint16_t[]`, no transform | linear dump |

**`tile_mask` was the one value I had guessed** when wiring, and it happens to be
right — Model 2 configures `0x3fff`. It is now verified rather than assumed.

**So the renderer is exonerated on every statically checkable point**, which makes
the copy checksums the discriminator. If tile RAM reads `A66F51B7` and the palette
`5BFDD5AF`, the data is intact and a renderer that matches MAME is drawing it
wrongly — which points at the char fetch path or the line buffer, neither of which
can be checked by reading. If either checksum is wrong, the data never arrived and
the renderer was never implicated.

### P1.5 STEP 4: the tilemap RENDERS. Structured, not correct.

**First tiles on screen.** The pipeline runs end to end: copy engine completes (the
test pattern is gone, which is the designed signal that it finished), tiles are
fetched from SDRAM per line, decoded, mixed and palettised, and the overlay sits
on top. `word4 = 00000087`, `word5/6 = 00200020` — the correct readback for the
tilemap blob.

**And it incidentally cleared the parked ROM fault's leading hypothesis.** Char
data is fetched on a **burst port**, the same class the failing ROM readback used
and the self-test did not. It fetches successfully and produces structured output,
so that port class works. **The port-1-vs-port-2 hypothesis is weakened; the
interleave-expectation theory is now the stronger of the two.**

**The picture is wrong in a specific way:** regular fine vertical striping, and
large flat blocks of magenta and orange. That is misaddressed or mis-ordered
*data*, not a broken pipeline — a broken pipeline gives black or noise.

**Checked and NOT the cause:**

- **Palette width.** `pal_addr` is 12 bits from the mixer, which is the S24TILE
  colour index. Model 2's 16 KB palette RAM is larger than the tilemap indexes,
  so copying 4,096 entries is right and the other half belongs to the renderer.
- **Char addressing.** `char_addr = {tile_num, 4'b0000} + {map_y[2:0], 1'b0}` —
  16 words per tile, 16-bit word addressing — and `CHAR_BASE + char_addr` matches
  what the Model 1 core does.
- **COLUMNS.** Already 62 for both machines (496/8).

**The leading candidate, untested: the byte and word order of the MAME dump.**
`tools/mame_m2_tiledump.lua` reads with `read_u32` and packs little-endian, which
is the i960's view of memory. But `segas24_tile_device::char_r` is a device
accessor, and if it transforms the data — bit or byte reordering — the linear dump
is not what the fetcher expects. **Check `segaic24.cpp`'s `char_r`/`char_w`
against a straight linear read before changing any RTL.** The dump is cheap to
regenerate; the RTL is not.

**Second candidate:** Model 2's tile RAM layout versus Model 1's. Control
registers are read from tile RAM at word `0x5000`/`0x5004`; if Model 2 places
them elsewhere, scroll and layer control would be garbage while the glyph data
was fine, which fits large flat blocks.

**Resources with the tilemap in:** 8,428 ALM (20%), **163 M10K (29%)** — up from
56, being on-chip tile RAM and palette. That is the first real M10K datapoint for
the budget and it is worth carrying into §5.5: the tilemap alone costs ~107
blocks.

### OPEN AND PARKED: the ROM high byte reads as 0x00. Possibly a ghost.

**Parked deliberately after eight hardware builds.** Everything below is
eliminated by measurement, not by argument, so a future session does not repeat
it. **Read this before touching the ROM path again.**

**The symptom, stable across every build:**

```
word5  FFFFF6E0   what ARRIVED over ioctl        correct
word6  00FF00E0   what came back from SDRAM      high byte of each word is 0x00
word4  00000087   PLL locked, mem ready, ROM loaded, no overflow, SELF-TEST PASSING
```

**What is PROVEN GOOD, each by a measurement:**

| | evidence |
|---|---|
| SDRAM device, both byte lanes | self-test writes `AA55 5AA5 FF00 00FF` at the 64 MB mark and reads all four back exactly, looping |
| the SDRAM write port | the self-test uses the *same* port |
| the data arriving | a probe latches `ioctl_dout` itself: `FFFFF6E0`, correct |
| the controller and loader in simulation | `test_m2_romload` drives the real ROM words through loader -> SDRAM -> readback, 0 mismatches |
| the controller at both geometries | 74,729 checks at 32 MB, 58,739 at 128 MB, 0 fails, 0 protocol violations |

**What has been ELIMINATED, each by a build:**

- **Capture phase** — the range was CL+2..CL+5 and the board needs earlier; moved
  to CL+1..CL+3 and the symptom is unchanged. (The range *was* wrong; fixing it
  did not fix this.)
- **Clock speed** — 80 MHz -> 40 MHz, unchanged.
- **Clock domain crossing** — `hps_io` moved from `clk_vid` to `clk_sdram`, the
  loader's domain, unchanged. Kept because it is correct regardless.
- **M10K read latency** — the drain now waits a cycle between launching the read
  and asserting the request, unchanged.
- **Byte-lane splitting** — `fifo_data` split into two 8-bit M10K arrays as
  `docs/` requires, confirmed in the fitter report, unchanged.
- **Inferred memory itself** — `ramstyle = "logic"`, no memory anywhere in the
  loader path, **10,118 ALM (19% -> 43%)**, unchanged. **The FIFO is exonerated.**
- **Bus widths** — 16 bits end to end at every point, checked not assumed.
- **MRA size wrap** — real, fixed, and not this.

**THE LEADING HYPOTHESIS, and it is untested:**

**The data in SDRAM may be correct and the READBACK may be wrong.** The self-test
reads through **port 2**; the ROM readback reads through **port 1**. That is now
the only structural difference left between a path that works and a path that does
not. Point the ROM readback at port 2, or the self-test at port 1, and the answer
falls out in one build. **Do this first.**

**Why it may be a ghost:** every "expected" value is computed from *my* reading of
the MRA's interleave (`map="0021"`/`map="2100"`). If MiSTer assembles the stream
differently, the ROM in SDRAM could be correct-but-different and the readback
correct, with only the expectation wrong. The arrived-probe showing `FFFFF6E0`
argues against this, but it does not settle it — that probe reads the stream, not
the ROM file. **Dumping what MiSTer actually delivers and diffing it against the
ROM would settle it without hardware.**

### i960: what is NOT implemented, for when the CPU comes back

Daytona executes 80 distinct mnemonics and **all 80 are built**. What remains is
machine, not instruction set:

- **Interrupts — a prerequisite, not a completeness item (study R14).** Model 2
  drives **four** i960 interrupt lines from a twelve-source register (vblank, four
  timers, sound UART) via `model2.cpp::irq_update()`. **The core has no `irq` port
  at all.** Needs the PRCB interrupt table, vectoring, a type-7 call onto a
  separate interrupt stack, the IP/AC save, and `ret` dispatching on `PFP[2:0]`.
  **This gates P1 exit criterion 3.**
- **`ret` ignores `PFP[2:0]` in BOTH the module and its reference**, so they agree
  and lockstep is silent. MAME switches on the type and `fatalerror`s on 1-6.
- **Faults** — absent entirely; they touch the sequencer.
- `synmov`/`synmovq`, `calls`, `modpc` — bounded; `calls` measures 0.000% in the
  traces.
- `rl` double-precision FP forms (four register reads against a two-port file);
  `remr`.
- Six glibc transcendentals — M2-B found zero in Daytona; confirm before building.
- **Throughput (R16):** ~3.0x headroom on measured demand, but that is against an
  *idealised* bus. R17 records Model 1 measuring 65% of its CPU's cycles as memory
  stalls, so the i960's I-cache hit rate under realistic latency is the number to
  get before any pipeline discussion resumes.

### P1.5 STEP 3 CLOSED: ROM path proven end to end on hardware

Board reads, running `Model2 2D Tilemap Test`:

```
B0ADCAFE   0000034E   000001A8   000001F0   00000007   00200020   00200020
magic      frames     lines      pixels     status     ROM w8/9   ROM w6/7
```

**Both ROM signatures exact.** MRA -> `ioctl` -> `m2_rom_loader` -> `m2_sdram` ->
readback is proven on silicon, together with the video path. Step 3 is closed.

**And it identified why Daytona failed.** The full set is **43.62 MB** and
`m2_sdram` addresses **32 MB** (`[24:1]`, 2 bank + 13 row bits). Loading all of it
**wraps by 11.62 MB and overwrites its own start**, which is where the i960
program lives — so the board read `FFFFFFFF` (padding from the tail of the
stream) at exactly the addresses the program should occupy. The same build with a
592 KB payload read the expected signature at both probes, which is what made it
a measurement rather than a theory.

**`mra/Daytona USA (Deluxe 93).mra` is trimmed to 22.25 MB** — i960 program, main
data, copro data, textures — and the polygons, samples and comms program are
omitted with the reason written into the file. Restoring them needs the controller
widened for a 128 MB module, or the DDR3 split. **P6 work, now with a hardware
measurement behind it rather than an estimate.**

**My error, and worth naming.** I measured 43.62 MB and 32 MB, wrote both into
`docs/rom-layout.md` and into `Model2.sv`'s comments, concluded "fine for P1.5" —
and left the MRA loading the full set anyway. The two numbers were a page apart.
It cost a board test.

### ROM READBACK SOLVED IN SIMULATION: two bugs, both mine, found in one morning

Built `sim/mem/m2_romload_harness.sv` + `tb_m2_romload.cpp` — the hardware path on
a desk: **ioctl -> m2_rom_loader -> m2_sdram -> readback**, with the readback FSM
copied verbatim from `Model2.sv`. `make test` is now **17 suites**.

**Bug 1: `hps_io` was instantiated without `WIDE(1)`.** The loader's own header
says it expects 16-bit `ioctl_dout` with `ioctl_addr` advancing by two. Left at the
default, `WIDE=0` makes the port **8 bits**, our 16-bit wire silently zero-extends
a byte, and the ROM lands as garbage. **That is the `000000FF` the board reported**
— a byte, zero-extended. Model 1 has `.WIDE(1)`; I had copied the template's
instantiation instead.

**Bug 2: the readback was on port 0, which does not burst.** `m2_sdram`'s `blen()`
is hardcoded per port: **ports 1-3 burst four 16-bit words and fill the whole
64-bit `p_dout`; ports 0 and 4 return ONE.** On port 0 the readback got a correct
low half and a permanently zero upper half — which reads like a broken controller
and is a port-selection mistake. The CPU takes port 0 *because* it wants single
words; 1-3 are the streaming ports. **Relevant to the tilemap wiring next.**

**The harness now passes with both signatures exact** — `rb_w0 = FFFFF6E0`,
`rb_w1 = 00000860` — and it corroborates Model 1's hardware claim as a bonus:

| `rd_lat_sel` | result |
|---|---|
| 0 (CL+3) | **exact** — what the device *model* wants |
| 1 (CL+2) | `f6e00000` / `08600000` — **shifted by exactly one 16-bit word** |

That is the symptom the Model 1 core documented seeing on its board, reproduced
in simulation. The board default stays CL+2 because the real device is clocked on
the inverse of the controller clock and answers half a period away; the model is
not, and wants CL+3. **Two different numbers for a physical reason, now
demonstrated rather than asserted.**

**Method note.** Two hardware builds were spent on this before the harness
existed, and the first hypothesis — the capture phase — was wrong. The project's
own rule says fuzz and simulate before building. The harness took under an hour
and found both bugs; the builds found neither.

Two instrument errors along the way, both logged and both worth remembering: the
write log sampled *before* the clock edge and printed nothing while the device
model was serving 16 writes; and it gated on `req && ack`, which never coincide on
this interface because the loader pulses the request for one cycle and the
controller acks two cycles later.

### SECOND HARDWARE RUN: video path fully confirmed; ROM readback narrowed

**Everything in the video path is now proven on silicon.** `word2 = 000001A8`,
`word3 = 000001F0`, `word4 = 00000007` (clean top bit, `pll_locked` + `mem_ready`
+ `rom_loaded`, no overflow) — all three defects from the first run are fixed and
verified on the board. **MiSTer's own info panel independently reports
`496x384  24.40KHz  57.5Hz`**, which is MAME's `set_raw` agreed by the framework
rather than by us.

**The ROM readback is still wrong, and it is now NARROWED.**

| | probe | expected | read |
|---|---|---|---|
| word5 | word addr 8 | `FFFFF6E0` | `000000FF` |
| word6 | word addr 4, upper half | `00000860` | `00000000` |

**It is address-independent.** `word5` read `000000FF` from address 0 in the first
build and `000000FF` from address 8 in the second. **That rules out the SDRAM
capture phase** — a wrong phase shifts data, it does not return a constant. Do not
spend builds cycling the OSD option; that is not the fault.

**And it is not the controller.** `make test_m2_sdram` now runs the Model 1
controller testbench against its device model, lifted with it: **74,729 checks, 0
fails, 0 protocol violations, 95,607 reads, 6,625 writes**, with five contending
ports. The controller works.

**So the fault is in the integration**, and the candidates are:

1. **The readback FSM** (`Model2.sv`). Its state 2 asserts `rb_req` and moves to
   state 3 unconditionally — if the controller can ack in that same cycle, the ack
   is missed and `rb_w1` never latches. `word6 = 00000000` is consistent with
   exactly that.
2. **Loader address mapping** — where `ioctl_addr` lands in SDRAM. Nothing has ever
   checked that the loader's writes go where the readback looks.
3. Byte lane / interleave orientation.

**Next step is simulation, not another board build.** `sim/mem/` now has the
device model, the harness and the testbench. Extending the harness to drive
`m2_rom_loader` into `m2_sdram` and read back reproduces the whole path on a
desk — which is what the last two builds should have been.

### FIRST HARDWARE RUN: video path CONFIRMED, ROM readback does NOT match

Photographed on a DE10-Nano, loaded via the MRA (so a real ROM was streamed).

**Confirmed working on silicon:** magic `B0ADCAFE`, frame counter running,
`pll_locked` + `mem_ready` + `rom_loaded` all set, bar order R,G,B,C,M,Y,W,grey
correct, border present on all edges, corner marker, marching block visible. **The
framework, PLL, video timing, clock enables and the whole video path are proven on
hardware, not just in simulation.**

**Three defects, all found by the overlay, none in the design under test:**

1. `word2 = 1A7`, `word3 = 1EF` — off by one against MAME's `1A8`/`1F0`. **Both
   mine, both in the counters**, not the timing module (which sim asserts against
   MAME and passes). Same cause in each: reset and increment fired on the *same*
   edge — `hcnt==0` is a visible pixel, and the frame boundary lands on a line
   boundary — so the later non-blocking assignment won and the item being closed
   was never counted. **Third instrument bug this session.**
2. The status word was `{27'd0, ...}` = **31 bits, not 32**. A short field in a
   concatenation does not warn, it silently reindexes: every word above it shifted
   by one bit, which is why word4 read `80000007` with `rb_w0`'s LSB bleeding into
   its top bit. Decoding the photo required un-shifting by hand.
3. **Address 0 was a useless probe.** The i960 ROM legitimately begins
   `00000000`, so a correct read and a dead read are indistinguishable. Probes are
   now chosen for signature value.

**The open question, and it is a real one.** Un-shifting the photo gives
`rb_w0 = 000000FF`, `rb_w1 = 000000FF`. The ROM says they should have been
`00000000` and `000000C0`. **Neither matches, and both reads returned the same
value** — so the ROM path is not yet proven and may be broken.

Candidates, in the order worth testing:

- **SDRAM read capture phase.** The OSD option exists for exactly this; Model 1's
  board needed CL+2 because the real device answers half a period away from the
  simulation model. Cycle it and watch the two words.
- Loader address mapping — where `ioctl_addr` lands in SDRAM.
- Byte lane or interleave orientation.

**Next build is ready** (`build/release/Model2.rbf`, timing clean, 7,738 ALM) with
all three defects fixed and probes reading:

| word | address | **expected** |
|---|---|---|
| 5 | word 8 | **`FFFFF6E0`** |
| 6 | word 4, upper half | **`00000860`** |

Both signatures come from the interleaved stream the MRA builds. If they read
correctly, the ROM path is proven end to end. If they read shifted, the capture
phase is the cause and the OSD option is the fix.

### `make release` gathers the flashable files

```
build/release/Model2.rbf                          <- launch this directly today
build/release/_Arcade/Daytona USA (Deluxe 93).mra
build/release/_Arcade/cores/Model2.rbf
```

`output_files/` is git-ignored, as build folders are, and `mra/` is tracked — a
file describing a ROM layout is fine, the bytes are not. Nothing gathered the two
until now.

**For the board today: copy `Model2.rbf` to `/media/fat/_Other/` and run it.**
Steps 1-3 need no ROM. `_Arcade/cores` is not browsed directly; those launch via
their `.mra`, which is not usable yet — the loader has no consumer and the full
set is 43.62 MB against the 32 MB the controller addresses.

**What to read off the screen:** `word2 = 000001A8` and `word3 = 000001F0`. Those
are MAME's `set_raw` numbers, already asserted in simulation — silicon agreeing is
a separate claim.

### P1.5 step 3 WIRED: SDRAM + ROM loader in, with a readback that proves it

**Builds, 0 errors, timing clean. 7,707 ALM (18%), 58 M10K.** Not on hardware yet.

The whole memory path is instantiated in the 80 MHz domain and the overlay now
carries seven words, the last two of which are **the first two 32-bit words read
back out of SDRAM**:

| word | meaning |
|---|---|
| 0 | `B0ADCAFE` magic |
| 1 | frame counter (liveness) |
| 2 | lines/frame — must be `1A8` |
| 3 | visible pixels/line — must be `1F0` |
| 4 | status: `pll_locked`, `mem_ready`, `rom_loaded`, `overflow` |
| 5 | **ROM word 0, read back from SDRAM** |
| 6 | **ROM word 1, read back from SDRAM** |

Loading a ROM nothing reads proves nothing. Compare 5 and 6 against the ROM file
by eye; **if the read capture phase is wrong they come back shifted**, which is
the failure the new OSD option exists for — so this is also how that option gets
set, instead of guessing one 25-minute build at a time.

**Three things carried over from the Model 1 core that would each have cost a
build:**

- **`T_REFI(600)`, not the default 700.** T_REFI is in clock cycles and this
  domain is 80 MHz: 8192 rows in 64 ms is 625 cycles. 700 under-refreshes and
  presents as *random ROM corruption*, not as a timing setting.
- **`SDRAM_CLK = ~clk_sdram`.** The device is clocked on the falling edge, so no
  phase-shifted PLL output is needed.
- **Selectable read capture phase**, defaulting to CL+2. Model 1's board returned
  every burst shifted right by one 16-bit word because the real device answers
  half a period away from the simulation model.

**Two findings from the integration itself:**

1. **`NP=1` does not elaborate** — the arbiter indexes `grant[2]` unconditionally.
   Using `NP=5` with four ports tied off rather than editing lifted code; ports
   1-4 become the CPU, tilemap and renderer.
2. **This controller addresses 32 MB**, being `[24:1]` with 2 bank and 13 row
   bits. **Model 2's ROM set is 43.62 MB, so the full set does not fit it on any
   board.** Fine for P1.5 — the 2D milestone needs the tilemap dump, palette and
   character data, well under a megabyte — and it must not be forgotten for P6,
   where it needs widening for a 128 MB module or the DDR3 split.

**Next: step 4, S24TILE** (`m1_tile_fetch/decode/mixer`, `m1_palette`, char RAM
rebased to `0x01080000`), then step 5's MAME-dump oracle.

### P1.5 step 3 STARTED: modules lifted, NOT yet wired

**Deliberately bounded.** The four modules are in `rtl/` and lint clean; nothing is
instantiated, so the build and `make test` (16 suites) are untouched and green.
Integration is the next session's work, not a half-finished tree.

| file | lines | from `b895e6c` |
|---|---|---|
| `rtl/mem/m2_sdram.sv` | 741 | `m1_sdram.sv` |
| `rtl/io/m2_rom_loader.sv` | 316 | `m1_rom_loader.sv` |
| `rtl/mem/m2_cdc_port.sv` | 173 | `m1_cdc_port.sv` |
| `rtl/mem/m2_cdc_pulse.sv` | 59 | `m1_cdc_pulse.sv` |

Renamed only — logic untouched. `m2_sdram.sv` raises six lint warnings
(`UNUSEDSIGNAL`, `UNUSEDPARAM`, `WIDTHEXPAND`); **they are upstream's and the file
is deliberately unedited**, so it is linted with those three suppressed. Do not
"fix" them here; fix them upstream or leave them.

**What integration must get right, in order of how expensive it is to get wrong:**

1. **One access is `req & ack`, not one cycle of `req`.** `i960_lsu.sv` holds
   `bus_req` for the whole transfer state. Harmless for RAM, fatal for the FIFO
   and I/O behind it. `docs/mister-integration.md`.
2. **`ioctl_wait` gated on `ioctl_download`** — it stalls the HPS itself
   otherwise. The lifted loader already carries the fix and the FIFO that makes it
   work: `ioctl_wait` *asks* the host to stop and it does not stop instantly.
3. **Memory out of reset on PLL lock and stays out**, separate from game reset.
   `Model2.sv` already splits `mem_rst_n` from `game_rst_n` for exactly this.
4. **`mem_ready` and `rom_loaded` are different facts** and must not share a signal.
5. **Layout is `docs/rom-layout.md`** — 43.62 MB, fits a 128 MB board with 84 MB
   spare, no DDR3 split needed. `m2_fetch_bridge` not yet taken.

### P1.5 step 2 DONE: the overlay is in, and it prints the timing numbers

`rtl/video/m2_diag.sv`, lifted from Model 1 at `b895e6c`, wired over the test
pattern. Build: **7,256 ALM (+86), 0 errors, timing clean.**

It reports four words, and the point is that two of them are **assertions the
board can fail**:

| word | value | meaning |
|---|---|---|
| 0 | `B0ADCAFE` | magic — a garbled overlay is obvious rather than plausible |
| 1 | frame counter | liveness, numerically, wrapping |
| 2 | lines last frame | **must read `000001A8`** (424) |
| 3 | visible pixels per line | **must read `000001F0`** (496) |

Those are MAME's `set_raw` numbers. `sim/video/tb_m2_video_timing.cpp` already
asserts them in simulation — **simulation proving them and silicon proving them
are different claims**, and until now only the first had been made. If the board
shows anything other than 1A8 and 1F0, the timing is wrong on hardware regardless
of what the testbench says.

**Next: step 3, SDRAM + ROM loader.** The standing rule from `b895e6c` applies from
its first peripheral — **one access is `req & ack`, not one cycle of `req`**.

### One access is `req & ack`, not one cycle of `req` — pulled at `b895e6c`

Model 1 found a TGP FIFO bug that **transfers straight to our bus fabric**, and
P1.5 step 3 is where we build it.

Its coprocessor holds `mem_req` across two states (a registered RAM read needs the
address to stay put), and its FIFO logic popped/pushed on the *level*:

```systemverilog
assign fifo_in_pop   = fifo_rd && fifo_in_valid;    // fired EVERY cycle
assign fifo_out_push = fifo_wr && !fifo_out_full;   // likewise
```

Every `mov (x1), b` consumed **two** command words; every `mov p, (bx1)` pushed
**twice**. Symptom: a hardware deadlock, the copro waiting for a word the V60 had
already sent. **The double push was found one minute after the double pop was
fixed, because the first correct result printed twice** — left alone it would have
fed a duplicate and gone wrong one command later, much harder to see than the
deadlock hiding it.

**Our exposure is real but on the peripheral side.** `i960_lsu.sv` drives
`bus_req = (state == S_XFER)` and drops it on `bus_ack` — correct, and harmless
for RAM, because reading the same word twice returns the same word. It is *not*
harmless for a FIFO, a read-to-clear register, or an auto-incrementing port.
**Every peripheral step 3 attaches must count one access per handshake.** Recorded
as a standing rule in `docs/mister-integration.md`, with the fix shape worth
copying: a `popped`/`pushed` flag cleared when the request drops, the pop firing on
the first cycle data is actually present so an access to an empty FIFO still
completes, and the ack accepting "already done".

**`mb86233_core` re-measured: 2,355 ALM, unchanged** — the fix is in `m1_tgp.sv`,
outside the core. Budget row stands.

### R17: Model 1 has measured that MEMORY, not the CPU, is the throughput lever

Pulled `tools/model1-ref` to **`198e1d9`** (15 new commits) per rule 10. Two of
its findings land directly on ours.

**Its V60 runs at 30.49 CPI, and 65% of cycles are memory stalls** — 38% data,
27% fetch, barely overlapping, because a single arbitrated bus serialises them.
Its CPU in isolation is ~6 CPI against MAME's implied 8, so **the 3.18x gap to the
reference is almost entirely the memory subsystem**, and optimising the CPU would
not close it.

**That reframes R16 without contradicting it.** Our CPI 5.04 and ~3.0x headroom
were measured against an idealised bus — the lockstep harness answers memory on
demand, with no SDRAM latency, refresh or contention. On hardware the i960 shares
SDRAM with the renderer, TGP, sound and video: five masters, the configuration
Model 1 measured 65% stall under. **R16 stands as measured and must not be quoted
as a hardware margin.** A 3.18x memory-induced gap against a 3.0x margin leaves
nothing.

**Design consequence:** the i960's instruction cache stops being an optimisation
and becomes load-bearing. `i960_icache.sv` exists, but **its hit rate against real
Daytona code under realistic latency has never been measured** — and that can be
had from the R16 traces plus a latency model, with no hardware. That is the number
to get before any pipeline discussion resumes.

**Second finding, on M10K:** Model 1 now sits at **452/553 M10K (82%)** with 29,536
ALM. Our §5.5 conclusion that M10K is not binding came from **standalone blocks**
with no memory subsystem, caches or FIFOs — and our own step-1 build already uses
56 M10K for framework plus a test pattern. That conclusion is weaker than it reads
and should be re-taken once the memory subsystem exists.

**TGP re-measured after its fixes: 2,355 ALM** (was 2,344), Fmax 46.66. Budget row
unchanged.

Method note worth keeping: that project reached its cycle number on the **third**
attempt — the first was arithmetic dressed as a finding, the second used a sweep
that hardcoded `-GCEDIV=3` while the design shipped `ce_cpu(1'b1)`, so every number
it ever produced described a CPU getting one cycle in three. Same failure mode as
R15 here, same day, different project.

### P1.5 step 1 DONE: a timing-clean .rbf that draws a test pattern

**`output_files/Model2.rbf` builds, 0 errors, and meets timing with no negative
slack anywhere.** Not yet run on hardware.

| | |
|---|---|
| ALM | **7,170 / 41,910 (17%)** |
| M10K | 56 / 553 (10%) |
| DSP | 33 / 112 (29%) |
| PLLs | 3 / 6 |

Ours is 134 ALM of that (timing 51, pattern 83); the rest is `sys/`. **That
independently corroborates the 6,630 framework figure** the budget carries from
M2-E — this build measures ~7,036 for framework plus PLL plus `hps_io` wiring.

**The one real trap, and the doc had already warned about it.** The first
`rtl/pll/pll.v` put `altera_pll altera_pll_i` directly inside `pll` — correctly
named at both ends, but with no `pll_inst` level. `sys/sys_top.sdc` groups core
clocks by matching the whole instance path `*|pll|pll_inst|altera_pll_i|*`, an
empty `get_clocks` makes `set_clock_groups` a silent no-op, and so **the design
was not timed at all**: −36.5 ns setup on a 31.25 ns clock, −45.1 on the HDMI PLL,
−13.2 on audio — while reporting success and emitting an .rbf. Restoring the level
took every one of those to zero.

The framework PLLs failing made the symptom point away from the cause. And
`docs/mister-integration.md` has carried this warning, quoting −87 ns, since
before this core existed. **Second time in one session that a written-down lesson
did not prevent the thing it described** (see R15). Both fixes are now guards
rather than prose: `Model2.sdc` counts the matched clocks and raises a Quartus
error when the count is zero, so the build fails instead of passing vacuously.

**Files:** `Model2.sv` (emu top), `Model2.qsf/.qpf/.sdc`, `files.qip`,
`rtl/pll/pll.{v,qip}`, `sys/` copied from the MiSTer template. Build with
`quartus_sh --flow compile Model2`; note `quartus_map` alone does not run the
pre-flow script that generates `build_id.v`.

**Next: step 2, the debug overlay** (`m1_diag`, 307 ALM) — before any board test,
not after the fifth failure.

### P1.5 started: video timing and test pattern done, framework next

**Step 1 RTL is complete and verified. The MiSTer framework is not started.**

- `rtl/video/m2_video_timing.sv` — Model 1's module copied at `f48c842`, **51
  ALM**. **No retiming was needed** (MAME declares both machines identically), and
  `sim/video/tb_m2_video_timing.cpp` asserts it against MAME's `set_raw` rather
  than its own parameters: 278,144 pixel clocks/frame, 424 lines, 496x384 visible
  with every visible line exactly 496, and 57.52 Hz. `make test` is now 16 suites.
- `rtl/video/m2_testpattern.sv` — ours, **83 ALM**. Border proves nothing is
  cropped, eight bars prove channel order, corner markers prove orientation, and a
  block marching one bar per second proves liveness.

**The PLL does not transfer — checked, not assumed.** Model 1's outputs are 80 MHz
and 19.2 MHz; 19.2 is its V60 clock. Model 2 must regenerate it, and its
frequencies are clean: MAME's pixel clock is `32_MHz_XTAL/2`, so **16 MHz is
exactly 32 MHz halved** — no fractional division. Proposed: ~80 MHz SDRAM, 32 MHz
video with `ce_pix` = /2, ~25 MHz i960. `pll_0002.v` in the Model 1 tree is a
direct `altera_pll` instantiation rather than a Qsys black box, so the equivalent
can be hand-written. **It must be named `pll`** or `sys_top.sdc`'s clock groups
match nothing and a passing build fails on hardware.

**Next, in order:** the `pll` wrapper; copy MiSTer `sys/` from
`third_party/template`; the core `emu` module wiring timing + pattern to `VGA_*`;
`.qsf`/`.qpf`/`files.qip`; then an `.rbf`. Only the last costs a build.

One testbench trap recorded at the site: `vblank_start` is high ON cycle 0 of the
frame, so ticking past it before counting drops that cycle and every total comes
out one short — which reads exactly like an off-by-one in the RTL counters, and
was reported as one.

### SETTLED (R16): ~3.0x throughput headroom, measured properly

R15 withdrew R10 and R13. **R16 replaces them, and R10's conclusion survives with
its number out by 2x and its evidence replaced.**

Twelve consecutive attract-mode frames at frame 2300 of `daytona93`, traced with
the collapse flag **verified** (1,285,223 instructions, 0 collapse markers):

| | per frame |
|---|---|
| total | 106,754 - 107,883 (mean 107,101) |
| spin | 71.3 - 72.7% |
| **work** | 29,208 - **30,949** |

Two poll loops are all of it — `ldob 0x500000`/`cmpibe` at **69.2%** of the frame,
and `ld 0x91fff0`/`cmpibne` at 2.6%.

**The decisive observation, which R10 asserted and never showed: the total is
near-constant while the work varies.** Total moves 1.1% across 12 frames while
work moves 6%, and at a lighter point work drops to 6,464 while the total holds at
110,739. The CPU spins to fill the frame, so **the total is capacity, not demand**
— and a poll loop that runs fewer times still exits, because what it waits on is
driven by real time.

**Demand: 30,949 instructions of work per frame = 1.78 M instr/s. At 5.33 M
instr/s that is 5.81 ms of a 17.39 ms frame — 33.4%, about 3.0x headroom.** And
5.33 is conservative: R13's mix over-weighted the expensive frame ops.

**R13's census recounted clean** (work-only, 356,587 instructions): `call` 1.543%
(was 2.053%), `ret` 1.772% (was 2.395%), `callx` 0.225% (was 0.262%) — overstated
~30%, in the predicted direction. **The generator mix should be re-derived from
this trace**; until then CPI 5.04 is an upper bound.

| | work/frame | demand | margin |
|---|---|---|---|
| R10 | 15,400 | 0.93 M/s | 7.4x |
| R13 | same | same | 5.7x |
| R15 | withdrawn | withdrawn | unproven |
| **R16** | **30,949** | **1.78 M/s** | **~3.0x** |

Same caveat R10 had, now stated as a bounded gap: **attract mode only**, 14 frames
at three points. Gameplay is unsampled and could be heavier. The tooling to close
it exists and refuses to return a collapsed trace.

**Tooling:** `tools/i960-trace.sh` (verifies, refuses collapse markers) and
`tools/mame_i960_frame_trace.lua` (frame-notifier driven, `tracelog` boundary
markers, works around the unresolved long-`gtime` failure).

### RETRACTION (R15): the i960 throughput numbers came from loop-collapsed traces

**Read this before quoting any instructions/second figure.**

Every i960 trace taken before 2026-08-18 used `trace <file>,:maincpu` with **no
loop flag**, so MAME collapsed loops and printed `(loops for N instructions)`
instead of the bodies. Measured over the three traces R10 used:

| trace | printed | hidden | true total |
|---|---|---|---|
| f1 | 14,469 | 49,149 | 63,618 |
| f2 | 14,474 | 73,647 | 88,121 |
| f3 | 17,441 | 95,480 | 112,921 |

**77-85% of executed instructions were never in the file** — and they were exactly
the loop bodies, which is the population the "0.1% spin" claim was about. A
verified-uncollapsed 17 ms window shows 322,707 instructions across **148 distinct
PCs, with the top 20 accounting for 99.8%**, against R10's "4,200 distinct PCs,
hottest 0.4%".

**Withdrawn:** R10's 15,400 instr/frame, its 0.93 M instr/s, its 4,200 distinct
PCs, its 0.1% spin fraction; R13's mnemonic census and call-depth distribution,
and therefore the generator mix, CPI 5.04 and **5.33 M instr/s**.

**Not established:** the corrected requirement. The clean window above is a *boot*
frame; R10's were ~40 s in during a demo race. A settled uncollapsed trace has not
been produced — a long `gtime` in a debugscript yields no trace file here,
unresolved and recorded in the tool.

**So: the margin is unproven, not disproven.** If most recovered instructions are
spin, R10's conclusion survives with a smaller margin, because a poll loop that
runs fewer times still exits. If they are work, the core is at or below
requirement. Neither may be claimed yet.

**Area figures are unaffected** — they are fitter output, not traces.

`tools/i960-trace.sh` is the fix: it always passes `noloop`, and **refuses to
return any trace containing a collapse marker**. It also records two mechanics
that cost an hour — `gtime` is milliseconds, and long `gtime` values silently
produce no trace.

This is the fourth instance of the same error (R9, R10, R13, R15): a number used
without establishing what produced it. It is the worst of them, because
`docs/differential-testing.md` was written the same day and its first named
artifact, carried from the Model 1 core, is "**`noloop` is not optional**". The
warning was transcribed and not applied. **A lesson recorded is not a lesson
applied**, and the only durable form is a tool that refuses.

### callx lands, the frame path gets its first real test, and the throughput figure is corrected downward

`callx` is implemented and verified. Daytona now executes **no unimplemented
mnemonic**: all 80 distinct mnemonics in the 196,885-instruction sample are
covered. Study entries **R11**, **R12** and **R13**.

**Two latent frame defects, neither reachable before now.** `T_FRAME` exited on
`!rf_busy`, but `busy` is `state != S_IDLE` and the register file has not yet
*seen* the request in the first `T_FRAME` cycle -- so it left one cycle early
every time, refetched the same instruction and called again. Usually swallowed by
accident; when the refetch was slow (an I-cache fill) it was a **real** second
call, and one `callx` was seen building five frames and spilling to memory. And
the call target was presented live rather than latched, though `next_ip` is
sampled in `S_CALL_FIN` several cycles later -- `callx`'s target is `ea`, which
moves as soon as `ra1`/`ra2` revert on leaving `T_EXEC`. Both were latent in
`call` and `ret` too.

**Neither could have been caught: the whole-CPU generator emitted no `call` or
`ret` at all.** `i960_regs` has a thorough unit test, and a unit test that drives
`op_call` itself cannot see a *sequencer* that drives it twice. The generator now
emits `call`, `callx`, `ret` and `flushreg`, and seeds SP/FP plus a resident frame
at 0x2000 so a return below depth zero lands somewhere real -- that is the only
path outside the unit test that exercises the frame **reload**.

**`cvtri` overflow was wrong twice and the unit test skipped it.** `eu > 31`
misses the whole exponent-31 band (2^31..2^32 is out of range except -2^31), and
rounding can carry past 2^32, which was truncated to 32 bits *before* the range
check and read as `0`. `tb_i960_fpmisc.cpp` contained `if (r < -2147483648.0 || r
> 2147483647.0) return;` -- it skipped every out-of-range input, so 1.2M passing
checks never touched the path. Now checked, plus a directed walk of the int32
boundary both directions in all four rounding modes. MAME's answer here is x86's
indefinite value from a UB cast, not the manual's; the oracle wins and it is
recorded rather than buried.

**Throughput corrected: 6.86 -> 5.33 M instr/s.** R10's 6.86 came from a mix with
no calls in it. Counted from the same traces: `call` 2.053%, `ret` 2.395%, `callx`
0.262%, `calls` and `flushreg` 0.000%. **The margin over the 0.93 M instr/s demand
is 5.7x rather than 7.4x. R10's conclusion is unaffected -- the pipeline is still
not required.**

**The sharper half of that: the rate alone was not enough.** Emitting call and ret
at their measured rates gave CPI 6.71 and T_FRAME at 42% of cycles, because ret
slightly outnumbers call, depth sits at zero, and nearly every ret underflows into
a sixteen-word memory reload. What sets the cost is how often a call exceeds the
4-frame cache. Measured from the traces: **max depth 7, and only 8.5% of calls
spill**. The generator now models depth while emitting and **prints its own spill
rate beside the measured one every run** -- currently 9.5% vs 8.5%, conservative
in the right direction -- so the mix cannot drift silently again.

**Four harness deviations recorded, all abandoning the program like a subnormal
operand or a legitimate self-loop the retire detector cannot see:** self-modifying
code (a clobbered SP/FP sends a frame spill over the program; the I-cache has no
coherency with data writes), the IP leaving the program, a `callx` targeting its
own slot, and a `ret` immediately after a call -- the return address a call
records is `ip_next`, so a `ret` there returns to itself forever. That last one is
the general case and took three separate traces to see in full.

**State:** 15/15 suites pass; whole-CPU lockstep clean across **48 seeds** (it had
been run on one). `i960_top` measures **6,979 ALM** (6,986 before -- flat), Fmax
27.3 -> 26.84 MHz.

**Remaining i960 work.** Daytona's *instruction set* is complete; Daytona's
*machine* is not.

- **interrupts — a prerequisite, not a completeness item (R14).** Model 2 drives
  **four** i960 interrupt lines from a 12-bit request register (vblank, four
  timers, sound UART) via `model2.cpp::irq_update()`. **The core has no `irq`
  port at all.** Needs the PRCB interrupt table, vectoring, a type-7 call onto a
  separate interrupt stack, the IP/AC save, and `ret` dispatching on `PFP[2:0]`.
  This gates P1 exit criterion 3.
- **`ret` ignores `PFP[2:0]` in BOTH the module and the reference**, so they agree
  and lockstep is silent — R11's lesson repeating. MAME switches on the type and
  `fatalerror`s on 1-6. Fix with interrupts.
- faults — absent entirely, and they touch the sequencer
- `synmov`/`synmovq`, `calls`, `modpc` — bounded; `calls` measures 0.000% in the
  traces
- `rl` double-precision FP forms (four register reads against a two-port file);
  `remr`
- six glibc transcendentals — M2-B found zero in Daytona; confirm before building

### Every block measured, in every currency

Six blocks fitted this session on 5CSEBA6U23I7 with Quartus 17.0.0. The budget
now has **two estimate rows left**; everything else is a figure.

| Block | ALM | reg | M10K | MLAB bits | DSP | Fmax | whose RTL |
|---|---|---|---|---|---|---|---|
| `i960_top` | **6,979** | 4,212 | 1 | 2,048 | 7 | 26.84 | **ours** |
| `sys/` framework | **6,630** | — | — | — | — | — | upstream (M2-E) |
| VDP2 (tilemap ceiling) | **6,852** | 9,184 | 4 | 272 | 12 | 65.73 | srg320 |
| N64 RDP (renderer ceiling) | **8,347** | — | — | — | — | — | N64 (M2-E) |
| VDP1 (renderer floor) | **2,537** | 1,707 | 0 | 512 | 3 | 31.52 | srg320 |
| `mb86233_core` | **2,344** | 1,819 | 6 | 0 | 1 | 43.86 | Model 1 |
| fx68k | **2,134** | 1,412 | 6 | 0 | 0 | 68.45 | ijor, GPL-3 |
| SCSP | **2,030** | 2,379 | 26 | 0 | 2 | 76.73 | srg320 |

Device: **41,910 ALM, 553 M10K, 112 DSP**. Budget total **24,454 - 40,293 ALM**
(was 34,160 - 49,460). **The optimistic case fits with 14.1K spare against the
92% routing line; the pessimistic case fits the raw device.**

**M10K is not binding here, and that is now measured rather than assumed** — tens
of blocks against 553. One caveat stated plainly: **the renderer's framebuffer and
texture cache are in none of these numbers**, because no renderer RTL exists. A
496x384 16-bit framebuffer alone is 3.0 Mbit = 298 M10K. That is the number to
watch, and it is the only resource question still open.

`tools/model1-ref` pulled to **f48c842** per rule 10. Its new commit is docs-only
but carries a warning worth honouring: **its TGP trace figures recorded before
2026-08-18 are invalid** — the bench's microcode loader assigned `uc_data`/`uc_addr`
non-blockingly, so the coprocessor executed from the wrong addresses. Area
measurements are unaffected, which is why the MB86233 re-measure above stands.

**The standing lesson from this session, and it is the fourth instance.** Every
defect found here was in code that had a passing test. The frame path had a unit
test that could not observe the bug by construction; `cvtri` had a test that
skipped the failing inputs by construction; the CPI had a mix missing an entire
instruction class. **Ask what a passing test cannot see, not whether it passes.**

### Queued: the i960 clock, and the throughput deficit behind it

Two speed deficits stack, measured 2026-08-28:

  real i960   25 MHz, CPI ~1     25.0 M insn/s
  our core    24 MHz, CPI 3.95    6.1 M insn/s   4.1x slower  (R55)
  MEASURED on the board           1.2 M insn/s   5.2x slower again
  total                                          21x slower than hardware

24 MHz is not a rounding of 25: 96, 32 and 25 cannot share a VCO, and 960
gives exact divisors for 96 (/10), 48 (/20), 32 (/30), 24 (/40). See
rtl/pll/pll.v.

BUMP THE i960 TO clk_sys (48 MHz). Because our CPI is 4x wrong, matching
the CLOCK guarantees the THROUGHPUT is wrong -- and a game's real-time
behaviour depends on instructions retired per second, not the clock
label. R63's digit race was lost precisely because our CPU was too slow
against a free-running peripheral. 48 MHz halves the deficit and costs
nothing new: clk_sys already exists, from the same VCO, and closes timing
for everything else. The open question is whether the i960 itself closes
at 48 -- it has only ever been constrained to 24.

The other 5x is memory stalls: 91% of profile samples in the stuck loop
land on loads and stores. Candidates are the bridge turning every 32-bit
access into two 16-bit SDRAM transactions plus a multi-state walk, the
five-port arbiter, and an interface with one working capture depth.

NEITHER FIXES THE CURRENT BUG. The board executed 117.6 M instructions
against the 15.9 M simulation needs to draw attract, and drew nothing.
