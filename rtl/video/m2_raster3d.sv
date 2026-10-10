// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// The 3D back end: projected quads in, a lit pixel out.
//
//     m2_quad_store   collect, sort z-descending, replay per band
//     m2_raster_fill  quad to spans          (includes m2_raster_div)
//     m2_raster_band  NBUF band buffers, filled and displayed in rotation
//
// THE FRONT END IS NOT HERE, AND THAT IS THE POINT. Model 1 puts its display-
// list walk and a fixed-function geometry pipeline in the equivalent file.
// Model 2 cannot: its geometry is a MICROCODED engine that runs a program the
// game uploads -- 721,831 writes to 0x804000 over 900 attract frames, measured
// in MAME -- so the transform stage is a processor, not a pipeline, and it
// belongs on the other side of this port list. Everything above the `q_*` input
// is therefore Model 2's own work; everything below it is Model 1's, verified
// over 152,025 quads and 31.6 M spans. See THIRD_PARTY.md and study R124.
//
// `q_*` is the seam: a projected screen-space quad, a colour and a z. That is
// exactly what a geometrizer emits, so the interface does not change when the
// real one arrives.

`timescale 1ns/1ps

module m2_raster3d #(
  parameter int unsigned SCR_W  = 496,
  parameter int unsigned SCR_H  = 384,
  parameter int unsigned BAND_H = 8,    // tracks Model2.sv (R508's lesson)
  // R454: 4 -> 6 BAND BUFFERS. The renderer's problem is VARIANCE, not
  // throughput: `ready ms` measures 6.08 median against 17.3 max, and the
  // frame is 16.7. Most frames finish in a third of the time and the
  // occasional one runs over -- and with only four buffers there is no cushion
  // to absorb that, so one slow band throws away everything behind it.
  //
  // R452's counter is what showed this. Bands PAINTED is 23 median and 50 in
  // 27% of frames, against two or three visible: the work is being done and
  // then discarded, because a buffer is freed the moment the beam passes its
  // band. Deeper buffering lets the fast bands bank ahead for the slow ones.
  //
  // Two more, not three: a buffer is 8 M10K and 25 are free, so 6 leaves 9 in
  // hand where 7 would leave 1 and not fit.
  // R508: THE MODULE DEFAULT IS THE BENCH'S VALUE. tb_m2_raster3d instantiates
  // this module directly, so it has been testing FOUR buffers while Model2.sv
  // overrides to five (R456 records the same trap the other way round: R454
  // changed this default and the instantiation ignored it). Tracking the
  // override so the bench measures what the design builds.
  parameter int unsigned NBUF   = 6,
  // R607: FRONT TO BACK WITH A FILL MASK, the reference's order (see the
  // study). 0 is Model 1's painter: back to front, last write wins.
  parameter bit          FTB    = 1'b0,
  // R616: pixel-centre planes and group-centre samples; texels per fetch.
  parameter bit          PXC    = 1'b0,
  parameter int unsigned PIXSTEP = 4,
  // R626: quarter-pixel vertices for the texture plane fit (m2_quad_store,
  // m2_raster_fill); 0 is the integer-only fit
  parameter int unsigned FRB = 0,
  // R658: Model 2's pixel-centre coverage in the fill (requires FRB 2)
  parameter bit          M2COV = 1'b0,
  // R627: BILINEAR UNLESS LATE. A texel request issued while the fill is
  // within TXLATE bands of the beam (the frame on screen, the beam in the
  // picture) is point-sampled -- one cache line, not up to four -- so a heavy
  // band catches up instead of going out missing. 0: never.
  parameter int unsigned TXLATE = 0,
  // R628: texel miss slots -- 2 (tex_m, tex_m2) or 4 (+ tex_m3, tex_m4)
  parameter int unsigned TXNS = 2,
  // R789: texel fetches in flight across the crossing (m2_span_tex TXK =
  // m2_texel_cdc K; R539 4, R553 8 -- R558's scramble was the old 2:1
  // adapter's timing, R561 replaced it) and the cache's response queue
  // (m2_texel_bl RSP_D; R622 4). R628: four miss slots only pay with a deeper
  // queue to discover the misses and more credits to issue them.
  parameter int unsigned TXK = 8,
  parameter int unsigned TXRSP = 4,
  // R633: while tex_late, every other group reuses its neighbour's texel
  parameter bit          TXREUSE = 1'b0,

  // ARE clk AND scan_clk ACTUALLY DIFFERENT CLOCKS?
  //
  // 0 means they are the same net, and then every synchroniser below is a
  // crossing this module invents against itself: two flops each on the band
  // flag, the band index and the scan counter, for a hazard that cannot occur
  // when there is one clock edge. That is not free -- it is two cycles of
  // band-presentation latency and two of buffer release, in the renderer whose
  // whole problem is finishing a band before the beam arrives.
  //
  // 1 restores all of it, and it must be 1 the moment the video moves to the
  // memory clock. The logic is kept rather than deleted precisely because that
  // move is planned and R199 records what it costs to rediscover.
  parameter bit TWO_CLOCKS = 1'b0,   // R545: what Model2.sv builds (R508's lesson)
  // R640: THE DDR3 FRAMEBUFFER (ported from branch ddr3, R355-R380). At 1 the
  // band buffers are not built, the fill is not beam-paced, a list is drawn
  // ONCE into DDR3 and shown only when complete, and the scanout reads it a
  // line ahead. With FTB the front-to-back mask is fed by the combining
  // writer, the one place a pixel is committed (R683), so FTB needs FB_WCOMB.
  parameter bit FB_DDR3 = 1'b0,
  // R661: the framebuffer writer that combines spans into 64-pixel windows
  // (m2_fb_wcomb) instead of a DDR3 command per span (m2_fb_write). ~+330 ALM
  // in place: it does not fit beside everything else yet (s575-s577).
  parameter bit FB_WCOMB = 1'b0,
  // R677: a textured quad goes to the fill as two triangles, (0,1,2) and
  // (0,2,3), each fitted through its own corners. A banked road on a corner
  // is TWISTED -- its four corners' u/z, v/z, 1/z lie on no one plane (MAME
  // frame 9000: the plane through three misses the fourth by up to 333
  // texels) -- and the fill's single plane cannot follow it; MAME interpolates
  // along the edges. Needs M2COV, whose pixel-centre rule shares the diagonal
  // without a gap or a pixel drawn twice.
  parameter bit SPLIT_TRI = 1'b0,
  // R275: the SDRAM address width the texel fetch drives.
  parameter int unsigned TEX_AW = 25
) (
  input  logic        clk,
  // R318: m2_texel runs on this, not on `clk`. A texel miss is ~280 ns of which
  // ~120 ns is that unit's own state machine, and only that half scales. See
  // m2_texel_x2 for why the acknowledge has to be held across the 2:1.
  input  logic        clk_mem,
  input  logic        rst_n,
  input  logic        frame_start,          // one pulse at the start of vblank

  // ---- quads in, from the geometry stage. Screen space, already projected.
  input  logic        q_valid,
  output logic        q_ready,
  input  logic signed [15:0] q_x0, q_y0, q_x1, q_y1,
  input  logic signed [15:0] q_x2, q_y2, q_x3, q_y3,
  input  logic [23:0] q_col,
  input  logic [31:0] q_z,
  input  logic        q_moire,
  // R273: the quad's texture -- four {u, v} in 11.2 texels and the texel
  // fetch's share of the header. Arrives already converted from the floats the
  // clipper interpolates; see m2_geometry's f2uv.
  input  logic [15:0] q_oz0, q_oz1, q_oz2, q_oz3,   // R334: 1/z, minifloat
  input  logic [15:0] q_frac,                       // R626: {fy3,fx3..fy0,fx0}
  input  logic [12:0] q_u0, q_v0, q_u1, q_v1,
  input  logic [12:0] q_u2, q_v2, q_u3, q_v3,
  input  logic [23:0] q_tex,
  input  logic        q_end,                // last quad of the frame

  // ---- scan-out, on the video clock
  input  logic        scan_clk,
  input  logic [9:0]  scan_x,
  input  logic [9:0]  scan_y,
  // R682: 15 kHz interlaced (scan_clk): scan_y is then the displayed line of
  // the field scan_field, 192 a field
  input  logic        scan_il,
  input  logic        scan_field,
  output logic [15:0] scan_col,
  output logic        scan_hit,             // 0 = nothing painted, show the 2D

  // ---- R275: the texture sheets, in SDRAM
  input  logic [TEX_AW:1] tex_base0, tex_base1,
  input  logic            tex_inval,
  input  logic            tex_bilinear,   // R620: on clk_mem, quasi-static (OSD)
  input  logic [1:0]      tex_pxk,        // R650: texel step 1/2/4/8 as log2, on clk (OSD)
  // R784: the OSD's output curve on clk (m2_geo_engine's encoding), for the
  // pedestal m2_span_tex adds to a textured pixel. q_tex[11] carries "luma
  // table row 1" from here on: the checker bit that sat there is taken from
  // q_moire, and nothing in this module read tex[11].
  input  logic [1:0]      tex_gamma,
  // R652: a finished list is waiting for the draw in progress (FB_DDR3). The
  // top level holds the GAME on it -- no vblank interrupt, no frame count, no
  // walk -- so the 2D the game writes keeps the 3D's pace.
  output logic            list_hold,
  // R653: THE FRAMEBUFFER SELF-TEST (FB_DDR3). fb_test (clk, quasi-static)
  // replaces the fill with a generator that writes a pattern each pixel of
  // which names its own place -- {row, 8-pixel cell, check} -- and a checker
  // on the scanout verifies every pixel it reads against the place it is
  // shown. Per video frame (scan_clk, latched at the end of the visible
  // lines, carried to clk on a toggle): bad pixels, bad rows, and the first
  // bad one's {row, column, the row its data named}.
  input  logic            fb_test,
  // R656: THE WRITER'S PACE (clk, quasi-static): 0 off, else a write beat's
  // credit refills every 2^(fb_pace-1) cycles (1, 1/2, 1/4, 1/8, 1/16 beats a
  // cycle), up to 64 in hand. A write burst is not granted without credit for
  // its beats, so the HPS port's queue -- which our scanout reads wait behind
  // (R655) -- is filled no faster than that.
  input  logic [2:0]      fb_pace,
  output logic [15:0]     dbg_tp_bad,
  output logic [15:0]     dbg_tp_rows,
  output logic [26:0]     dbg_tp_first,
  output logic            tex_m_req,
  output logic [TEX_AW:1] tex_m_addr,
  input  logic            tex_m_ack,
  input  logic [63:0]     tex_m_data,
  // R480: a second texel port -- one transaction per SDRAM port at a time,
  // so a single port serialises every miss.
  input  logic            tex_m2_en,
  output logic            tex_m2_req,
  output logic [TEX_AW:1] tex_m2_addr,
  input  logic            tex_m2_ack,
  input  logic [63:0]     tex_m2_data,
  // R628: slots 2 and 3's ports (TXNS = 4); tie en low otherwise
  input  logic            tex_m3_en, tex_m4_en,
  output logic            tex_m3_req, tex_m4_req,
  output logic [TEX_AW:1] tex_m3_addr, tex_m4_addr,
  input  logic            tex_m3_ack, tex_m4_ack,
  input  logic [63:0]     tex_m3_data, tex_m4_data,
  output logic [31:0]     dbg_texpix, dbg_texhit, dbg_texmiss, dbg_texnz,
  output logic [15:0]     dbg_texlost,
  output logic [15:0]     dbg_texto,      // R650: m2_texel_cdc's local answers (clk_mem)
  output logic [15:0] dbg_oz0, dbg_oz1, dbg_oz2, dbg_oz3,   // R334
  output logic [15:0] dbg_texsweep,
  // R436: the fill's and the walk's longest-dwelt states
  output logic [4:0]  dbg_fill_hot,
  output logic [15:0] dbg_fill_hotcyc,
  output logic [2:0]  dbg_walk_hot,
  output logic [15:0] dbg_walk_hotcyc,

  output logic [15:0] dbg_quads,
  output logic [15:0] dbg_dropped,
  output logic [15:0] dbg_tiny,            // R216
  output logic [15:0] dbg_bands,

  // WHY THE TOP OF THE FRAME IS MISSING, INSTRUMENTED. R200 measured that
  // bands 0-11 never render and 12+ render perfectly, on a fill that is
  // BEAM-PACED -- C_IDLE only fills a buffer the beam has already released, so
  // it can run at most NBUF bands ahead and cannot simply "fall behind". A slow
  // fill loses the BOTTOM of the screen; this loses the TOP, which means the
  // fill starts late rather than running slow.
  //
  // These two say which. dbg_ready_cyc is clk cycles from frame_start to
  // pst==P_READY -- the collect-plus-sort cost, which is the only thing that
  // can delay the first fill. dbg_bands_done is how many bands completed in the
  // last frame, against NBANDS=24: if it reads 12 the fill never starts on the
  // first twelve, and if it reads 24 they are being filled and lost elsewhere.
  output logic [15:0] dbg_ready_cyc,
  output logic [7:0]  dbg_bands_done,
  // R452: BANDS THAT PAINTED SOMETHING, not bands that finished. A band with
  // no quads in it completes instantly, so dbg_bands_done counts those too --
  // which is why it reads 17 while the screen shows about two. One comparator
  // R485: one AND on bd_painted, the flag the band already maintains.
  output logic [7:0]  dbg_bands_painted,
  // R455: THE REPLAY FACTOR. The quad store re-issues every quad to every band
  // it touches, so a tall quad is fitted and walked once PER BAND. dbg_quads
  // counts quads; this counts fill PASSES. The ratio is how much of the fill's
  // work is repetition, and it decides whether BAND_H should go up or down --
  // taller bands halve the replay and cost buffer memory, shorter ones do the
  // reverse. Nobody has measured it.
  output logic [15:0] dbg_fillpass,
  // THE FLASHING, INSTRUMENTED. The store is cleared on every frame_start.
  // A frame whose q_end has not arrived by then is still in P_COLLECT: what
  // it collected is wiped, nothing is P_READY for the beam, and the frame
  // draws nothing. dbg_late_frames counts those; dbg_qend_frames counts
  // the frames the geometry stage finished. Equal rates mean every frame
  // is late and the picture is whatever the previous frame's list left.
  output logic [7:0]  dbg_late_frames,
  output logic [7:0]  dbg_qend_frames,
  // R210: the ready count saturated at 16 bits on the board. Both timers are
  // 20 bits now and reported in units of 16 cycles (1 M cycles full scale,
  // 21 ms at 50 MHz); dbg_collect_cyc is frame_start to q_end, so the sort
  // is the difference between the two.
  output logic [15:0] dbg_collect_cyc,
  // R213: how many video frames the last list stayed on display (latched at
  // the swap), and scanlines the beam drew with no band buffer ready.
  output logic [7:0]  dbg_hold,
  output logic [15:0] dbg_missed,
  // R536: WHICH bands the beam found with no buffer ready, last frame -- bit b
  // is band b, bands past NBANDS read 0 -- and how many scanlines that was.
  output logic [63:0] dbg_miss_map,
  output logic [15:0] dbg_miss_lines,
  // R547: WHAT THE SEQUENCER WAITS ON WHEN IT MATTERS, per frame, in units of 1,024 (R553; was
  // 256 cycles (saturating): counted only while the fill is on the displayed
  // frame and at most one band ahead of the beam -- the moments a band can be
  // late. a = {critical total, span walk waiting on a texel, span walk out of
  // fetch credits, span walk stalled by the painter} (R554).
  // b is zero (R547's first form had eight counters and did not fit).
  output logic [31:0] dbg_seq_a,
  output logic [31:0] dbg_seq_b,

  // ---- R640: the DDR3 side (m2_ddr3's consumer port, on `clk`)
  output logic        fb_req,
  output logic        fb_we,
  output logic [24:0] fb_addr,
  output logic [7:0]  fb_blen,
  output logic [63:0] fb_din,
  output logic [7:0]  fb_be,
  input  logic        fb_wnext,
  input  logic        fb_wacc,     // R660: m2_ddr3's same-cycle beat accept
  input  logic        fb_rvalid,
  input  logic        fb_ack,
  input  logic [63:0] fb_dout,
  output logic [15:0] dbg_fb_lines,
  output logic [15:0] dbg_fb_late,
  output logic [15:0] dbg_fb_pub,    // frames published
  output logic [15:0] dbg_fb_drop,   // lists replaced before they were drawn
  output logic [31:0] dbg_fb_pixels,
  output logic  [7:0] dbg_pipe       // measurement build: {pst, cst, fb_busy, fb_complete, 0}
);

  localparam int unsigned NBANDS = (SCR_H + BAND_H - 1) / BAND_H;
  localparam int unsigned BW     = $clog2(NBANDS);
  localparam int unsigned BUFW   = (NBUF > 1) ? $clog2(NBUF) : 1;

  // ------------------------------------------------------------ quad store
  //
  // TWO STORES, ONE COLLECTING AND ONE ON DISPLAY (R211). Daytona hands over
  // a display list every SECOND video frame (the 0x803008 flip, measured in
  // the reference), so the walk delivers a frame's quads at 30 Hz while the
  // bands are drawn just ahead of the beam at 60 Hz. With one store the
  // frames spent collecting could not draw, and the picture was on for one
  // frame and off for the next -- the white cars flashing on build/ack s14.
  // Real hardware and MAME keep the last rendered frame until the next one;
  // there is no frame buffer here, so the equivalent is to keep the last
  // SORTED LIST and replay it every video frame until the next one is ready.
  //
  // `bank` is the store being collected into and sorted; ~bank is replayed.
  // They swap at the frame_start that finds the collected frame P_READY. A
  // frame_start that arrives while the collection is still running does not
  // swap and does not clear anything: the display bank keeps drawing and
  // the collection completes. `dvalid` says the display bank holds a frame.
  logic        bank, dvalid;
  logic        qs_clear, qs_sort_start, qs_sort_busy;
  logic        qs_replay_start, qs_replay_busy, qs_out_ready, qs_out_valid;
  logic [BW-1:0] qs_band;
  logic signed [15:0] qo_x0, qo_y0, qo_x1, qo_y1, qo_x2, qo_y2, qo_x3, qo_y3;
  logic [23:0] qo_col;
  logic [12:0] qo_u0, qo_v0, qo_u1, qo_v1, qo_u2, qo_v2, qo_u3, qo_v3;   // R273
  // R334: 1/z off the store. STREAMED, and that is not only telemetry -- with
  // nothing reading these the fitter would drop the top 64 bits of uvt_* and
  // the build would prove nothing about the 26 M10K the perspective divide
  // costs. It also lets the values be checked on the board before the fill is
  // made to depend on them.
  logic [15:0] qo_oz0, qo_oz1, qo_oz2, qo_oz3;
  logic [15:0] qo_frac;                              // R626
  logic [23:0] qo_tex;
  // R275: the texel fetch's wires, declared here because two modules share them.
  logic        tex_req, tex_ack;
  logic        tex_rdy, tex_take;   // R539: a credit is free / the walk takes an answer
  logic [31:0] tex_state;
  logic        tex_late;    // R627: declared here, set by the band sequencer's test
  logic [19:0] tex_u, tex_v;
  logic [8:0]  tex_texel;   // R620: {discard, t}
  logic        qo_moire;

  // THE STORE TAKES QUADS ONLY WHILE COLLECTING (R220). Between a list's
  // q_end and the frame_start that swaps the banks, the sorted list sits in
  // the collect bank; a walk the game's mid-frame flip starts in that gap
  // wrote its quads straight over it -- lists mixed and part-overwritten,
  // seen as wrong wedges and an on-off flicker (dbuf13 s15). The geometry
  // pipeline honours this line (the clipper holds out_valid), so the walk
  // waits for the swap, which is the frame's own cadence.
  assign q_ready = (pst == P_COLLECT);
  wire   q_take  = q_valid && q_ready;

  // One two-bank store: collect into `bank`, replay `~bank` (R213 shares the
  // key and scratch index between the banks, ~8 M10K blocks over two
  // instances).
  // THE TINY THRESHOLD IS 4, MEASURED (R233). The store holds 2,048 quads a
  // bank and the busiest title frames produce ~3,900 after clipping: the
  // capture dropped 1,242 and 1,898 in single frames, and a frame that loses
  // its tail loses its scenery -- a car in silhouette against bare tiles. Of
  // 17,853 clipped quads sampled, the 2-pixel test refused 39%; 4 refuses
  // 56% and the extra 17% together cover at most 0.24% of the painted pixels,
  // every one of them distant detail under four pixels across. Small is far,
  // so this drops the right things first, and it is a parameter so the number
  // can move when the store can grow.
  // R769: NOT ALWAYS. Small is not far on car select: each tyre is a ring of
  // ~32 quads 2-3 px across, and TINY = 4 refused 621 of 1,340 quads there
  // (4.15% of the picture, every pixel at the wheels). The store now tests
  // at 2 while the previous list fitted under it with an eighth to spare,
  // and at 4 only for the lists that would not.
  // R776: and at 4 only for quads at z >= 16 (zval 0x3000): close-up detail
  // keeps every quad of 2 px or more whatever the list's size.
  m2_quad_store #(.BAND_H(BAND_H), .NBANDS(NBANDS), .BW(BW), .SCR_H(SCR_H), .TINY(4), .TINY_FINE(2), .TINY_FAR(16'h3000),   // R769, R776
                  .FTB(FTB), .FRB(FRB)) u_store (   // R607, R626
    .clk(clk), .rst_n(rst_n),
    .clear(qs_clear), .wbank(bank), .rbank(~bank),
    .in_valid(q_take),
    .in_x0(q_x0), .in_y0(q_y0), .in_x1(q_x1), .in_y1(q_y1),
    .in_x2(q_x2), .in_y2(q_y2), .in_x3(q_x3), .in_y3(q_y3),
    .in_col(q_col), .in_z(q_z), .in_moire(q_moire),
    .in_oz0(q_oz0), .in_oz1(q_oz1), .in_oz2(q_oz2), .in_oz3(q_oz3),   // R334
    .in_frac(q_frac), .out_frac(qo_frac),                             // R626
    .in_u0(q_u0), .in_v0(q_v0), .in_u1(q_u1), .in_v1(q_v1),
    .in_u2(q_u2), .in_v2(q_v2), .in_u3(q_u3), .in_v3(q_v3),
    .in_tex(q_tex),
    .sort_start(qs_sort_start), .sort_busy(qs_sort_busy),
    .replay_band(qs_band),
    .replay_start(qs_replay_start), .replay_busy(qs_replay_busy),
    .out_ready(qs_out_ready), .out_valid(qs_out_valid),
    .out_x0(qo_x0), .out_y0(qo_y0), .out_x1(qo_x1), .out_y1(qo_y1),
    .out_x2(qo_x2), .out_y2(qo_y2), .out_x3(qo_x3), .out_y3(qo_y3),
    .out_col(qo_col), .out_moire(qo_moire),
    .out_oz0(qo_oz0), .out_oz1(qo_oz1), .out_oz2(qo_oz2), .out_oz3(qo_oz3),   // R334
    .out_u0(qo_u0), .out_v0(qo_v0), .out_u1(qo_u1), .out_v1(qo_v1),
    .out_u2(qo_u2), .out_v2(qo_v2), .out_u3(qo_u3), .out_v3(qo_v3),
    .out_tex(qo_tex),
    .dbg_count(dbg_quads), .dbg_dropped(dbg_dropped), .dbg_tiny(dbg_tiny)
  );

  // ------------------------------------------------------------- the filler
  logic        fl_in_valid, fl_in_ready, fl_quad_done, fl_line_case;
  // R677: the triangle splitter. sp_b: 0 = the first triangle (0,1,2) is next,
  // 1 = the second (0,2,3). The store's entry is held until the second is
  // taken. A quad already a triangle (corner 3 on corner 2) goes whole.
  logic        sp_b;
  wire         sp_tri = (qo_x3 == qo_x2) && (qo_y3 == qo_y2) && (qo_frac[15:12] == qo_frac[11:8]);
  wire         sp_on  = SPLIT_TRI && qo_tex[0] && !sp_tri;
  wire         sp_2nd = sp_on && sp_b;
  wire         sp_1st = sp_on && !sp_b;
  wire signed [15:0] sp_x1 = sp_2nd ? qo_x2 : qo_x1,  sp_y1 = sp_2nd ? qo_y2 : qo_y1;
  wire signed [15:0] sp_x2 = sp_2nd ? qo_x3 : qo_x2,  sp_y2 = sp_2nd ? qo_y3 : qo_y2;
  wire signed [15:0] sp_x3 = sp_1st ? qo_x2 : qo_x3,  sp_y3 = sp_1st ? qo_y2 : qo_y3;
  wire [12:0]  sp_u1 = sp_2nd ? qo_u2 : qo_u1,  sp_v1 = sp_2nd ? qo_v2 : qo_v1;
  wire [12:0]  sp_u2 = sp_2nd ? qo_u3 : qo_u2,  sp_v2 = sp_2nd ? qo_v3 : qo_v2;
  wire [12:0]  sp_u3 = sp_1st ? qo_u2 : qo_u3,  sp_v3 = sp_1st ? qo_v2 : qo_v3;
  wire [15:0]  sp_oz1 = sp_2nd ? qo_oz2 : qo_oz1;
  wire [15:0]  sp_oz2 = sp_2nd ? qo_oz3 : qo_oz2;
  wire [15:0]  sp_oz3 = sp_1st ? qo_oz2 : qo_oz3;
  wire [15:0]  sp_frac = sp_2nd ? {qo_frac[15:12], qo_frac[15:12], qo_frac[11:8], qo_frac[3:0]}
                       : sp_1st ? {qo_frac[11:8],  qo_frac[11:8],  qo_frac[7:4],  qo_frac[3:0]}
                       : qo_frac;
  logic        fl_span_valid, fl_span_ready, fl_span_moire;
  logic signed [15:0] fl_span_y, fl_span_x0, fl_span_x1;
  logic signed [31:0] fl_span_ooz;                          // R337: 1/z at the span start
  logic signed [23:0] fl_span_doozdx;   // R618
  logic [23:0] fl_span_col;
  logic signed [31:0] fl_span_u, fl_span_v;
  logic signed [23:0] fl_span_dudx, fl_span_dvdx;   // R286: 8.8; R618: 16.8
  logic [23:0] fl_span_tex;
  logic        fl_span_tex_en;

  // R310: A SPAN FIFO, BECAUSE THE TEXEL FETCH BLOCKS EVERY SPAN BEHIND IT.
  //
  // m2_span_tex asserts `in_ready` only in T_IDLE, so while a TEXTURED span
  // waits in T_FETCH the fill cannot hand over ANY span -- and a flat span,
  // which needs nothing from the texel cache and passes through
  // combinationally once it gets in, queues behind a texture fetch it has no
  // relationship with. That is why enabling textures takes the 3D away rather
  // than merely making the textures flicker: the fetch is serialised into the
  // one path all geometry crosses (R309). About 14,600 misses a frame at
  // ~280 ns each is ~4.1 ms of a 17.38 ms frame spent blocked.
  //
  // The FIFO lets the fill keep walking while a fetch is outstanding. Storage
  // is M10K via m2_fifo_m10k, which the coprocessor's input queue already
  // uses: 242 bits of payload needs seven blocks and 256 entries of depth come
  // free with them, where a register FIFO of any useful depth costs ALM this
  // design does not have (40,971 of 41,910 used).
  //
  // TWO THINGS m2_fifo_m10k DOES THAT HAVE TO BE HANDLED HERE, not discovered.
  // Its `full` is a DROP signal for the TGP, because the i960 must never be
  // held; spans must never be dropped, so it becomes backpressure --
  // `fl_span_ready = !sq_full` -- which m2_raster_fill already honours. And it
  // has a deliberate two-cycle bubble after a pop, harmless only because the
  // fill walks edges over several cycles per scanline and cannot produce one
  // span per cycle anyway.
  logic spantex_busy;
  logic [2:0] walk_wait;   // R554: m2_span_tex's wait_why

  // R327: 242 -> 194 when y, x0 and x1 narrowed to 16 bits.
  // R337: 194 -> 242, carrying 1/z (32) and its gradient (16) for the
  // perspective divide. The queue is MLAB since R332, so this is ALM and not
  // M10K -- which is the only reason it is affordable at 553/553 blocks.
  localparam int unsigned SQ_DW = 266;   // R618: three gradients 16 -> 24 bits
  logic [SQ_DW-1:0] sq_din, sq_q;
  logic             sq_in_rdy, sq_qv, sq_rdy, sq_busy, sq_full;
  logic [15:0]      sq_cnt16;
  logic [31:0]      sq_dropped;   // must stay zero: a dropped span is a hole

  // Backpressure, NOT a drop: m2_fifo_m10k's `full` retires the TGP's pushes
  // silently, and a silently dropped span is a hole in the picture.
  assign fl_span_ready = sq_in_rdy;

  assign sq_din = { fl_span_y, fl_span_x0, fl_span_x1,
                    fl_span_ooz, fl_span_doozdx,                   // R337
                    fl_span_u, fl_span_v,
                    fl_span_dudx, fl_span_dvdx,
                    fl_span_col, fl_span_tex,
                    fl_span_moire, fl_span_tex_en };

  // R313: BACK TO BLOCK MEMORY, to trade ALM for M10K. The register queue
  // (R312) is the better part -- no bubble -- but it costs ~484 ALM, and ALM is
  // what the fitter is running out of. m2_fifo_m10k costs ~30 M10K instead,
  // which the halved char cache has just released.
  //
  // ITS BUBBLE IS ACCEPTED, NOT OVERLOOKED: "after a pop the next word takes two
  // cycles to reach the head". The fill emits a span every four to eight cycles,
  // so back-to-back pops only occur while the queue DRAINS -- which is when it
  // is doing its job, and where a flat span's throughput halves. Watch it; do
  // not assume it is free.
  // R332: MLAB, not M10K. DEPTH 32 is exactly an MLAB's native depth, and the
  // 5 block-RAM tiles this releases are what R331's quad store is short by.
  // Verify it took: the fit report's RAM Summary must say MLAB for this array.
  // R684: BACK TO M10K (7 blocks). R332's reason -- the quad store short of
  // block RAM -- is gone (538 of 553 used at s637), and these 13 MLAB LABs are
  // what R683's fill mask needs: s638-s640 were 23-28 LABs short.
  m2_fifo_m10k #(.DW(SQ_DW), .DEPTH(32), .RAMSTYLE("M10K")) u_span_q (
    .clk(clk), .rst_n(rst_n),
    .push(fl_span_valid && sq_in_rdy), .din(sq_din),
    .pop(sq_qv && sq_rdy), .q(sq_q), .q_valid(sq_qv),
    .full(sq_full), .count(sq_cnt16), .dropped(sq_dropped), .held()
  );
  assign sq_in_rdy = !sq_full;
  assign sq_busy   = sq_qv || (sq_cnt16 != 16'd0);

  // Unpacked, in the same order.
  // R337: ooz and its gradient sit between the coordinates and u; everything
  // from dudx down keeps the slice it had.
  // R618: 266 = 3x16 (y, x0, x1) + 32 (ooz) + 24 (doozdx) + 2x32 (u, v)
  //       + 2x24 (dudx, dvdx) + 24 (col) + 24 (tex) + 2 (moire, tex_en)
  wire signed [15:0] sq_y    = sq_q[265:250];
  wire signed [15:0] sq_x0   = sq_q[249:234];
  wire signed [15:0] sq_x1   = sq_q[233:218];
  wire signed [31:0] sq_ooz  = sq_q[217:186];
  wire signed [23:0] sq_doozdx = sq_q[185:162];
  wire signed [31:0] sq_u    = sq_q[161:130];
  wire signed [31:0] sq_v    = sq_q[129:98];
  wire signed [23:0] sq_dudx = sq_q[97:74];
  wire signed [23:0] sq_dvdx = sq_q[73:50];
  wire        [23:0] sq_col  = sq_q[49:26];
  wire        [23:0] sq_tex  = sq_q[25:2];
  wire               sq_moire  = sq_q[1];
  wire               sq_tex_en = sq_q[0];
  // R275: the textured span, expanded a pixel at a time. tx_* is the span as
  // the band buffers see it -- identical in shape, one pixel wide when the
  // polygon wears a texture.
  logic        tx_span_valid, tx_span_ready, tx_span_moire;
  logic signed [31:0] tx_span_y, tx_span_x0, tx_span_x1;
  logic [23:0] tx_span_col;

  // The band being filled IS the band the store replays. One register, two
  // consumers -- leaving qs_band undriven is a silent "always band 0".
  logic [BW-1:0] fill_band;
  assign qs_band = fill_band;
  wire signed [15:0] band_y1 = 16'(fill_band) * 16'(BAND_H);
  wire signed [15:0] band_y2 = band_y1 + 16'(BAND_H) - 16'sd1;

  m2_raster_fill #(.PXC(PXC), .FRB(FRB), .M2COV(M2COV)) u_fill (   // R616, R626, R658
    .clk(clk), .rst_n(rst_n),
    .in_valid(fl_in_valid), .in_ready(fl_in_ready),
    // R327: no sign extension. m2_quad_store already saturates these to 13
    // bits and hands them over as 16, and the fill now takes them as 16.
    .in_x0(qo_x0), .in_y0(qo_y0),
    .in_x1(sp_x1), .in_y1(sp_y1),                                        // R677
    .in_x2(sp_x2), .in_y2(sp_y2),
    .in_x3(sp_x3), .in_y3(sp_y3),
    .in_col(qo_col), .in_moire(qo_moire),
    .in_u0(qo_u0), .in_v0(qo_v0), .in_u1(sp_u1), .in_v1(sp_v1),
    .in_u2(sp_u2), .in_v2(sp_v2), .in_u3(sp_u3), .in_v3(sp_v3),
    .in_oz0(qo_oz0), .in_oz1(sp_oz1), .in_oz2(sp_oz2), .in_oz3(sp_oz3),  // R337
    .in_frac(sp_frac),                                                    // R626
    .in_tex(qo_tex),
    .view_x1(16'sd0), .view_x2(16'(SCR_W) - 16'sd1),
    .view_y1(band_y1), .view_y2(band_y2),
    .span_valid(fl_span_valid), .span_ready(fl_span_ready),
    .span_y(fl_span_y), .span_x0(fl_span_x0), .span_x1(fl_span_x1),
    .span_col(fl_span_col), .span_moire(fl_span_moire),
    .span_u(fl_span_u), .span_v(fl_span_v),
    .span_dudx(fl_span_dudx), .span_dvdx(fl_span_dvdx),
    .span_ooz(fl_span_ooz), .span_doozdx(fl_span_doozdx),     // R337
    .span_tex(fl_span_tex), .span_tex_en(fl_span_tex_en),
    .quad_done(fl_quad_done), .line_case(fl_line_case),
    .dbg_hot(dbg_fill_hot), .dbg_hotcyc(dbg_fill_hotcyc)   // R436
  );

  // ------------------------------------------------- R275: the texture walk
  // R322/R324/R389: FOUR PIXELS PER TEXEL FETCH (was eight, was two).
  //
  // A cache line is EIGHT texels across, so at PIXSTEP=8 one line covers 64
  // pixels of span and a 100-pixel span costs ~13 fetches where PIXSTEP=2 cost
  // 50. Four times fewer than the original. The blockiness compounds with it --
  // one texel across eight pixels is a real approximation, not a subtle one --
  // so this is a judgement to make on the screen, and it is one parameter back.
  //
  // This is the largest single lever on texture throughput and it is one
  // parameter. A textured span costs a fetch per group, and at 42.4% hit a
  // 100-pixel span is ~29 misses and ~6.4 us against a 362 us band budget --
  // which is why a handful of textured spans consume a whole band and the rest
  // of the frame's bands never appear. Halving the group count halves that.
  //
  // R279 chose two and its reasoning extends, with less force, to four:
  // "Daytona's textures are magnified far more often than minified, so adjacent
  // pixels usually share a texel anyway." At four the approximation is real and
  // visible on minified surfaces. Set back to 2 if it looks wrong -- this is a
  // quality judgement to make by eye, not by counter.
  //
  // SET HERE, NOT ON THE MODULE'S DEFAULT. R313 changed m2_char_cache's default
  // while the instantiation overrode it, and the change did nothing at all.
  // R389: EIGHT -> FOUR. Eight was chosen when the texture walk was starving
  // whole bands, and this file said so at the time: "one texel across eight
  // pixels is a real approximation, not a subtle one... a quality judgement to
  // make by eye, not by counter." R387 bought the bandwidth to pay for four --
  // a cache line is eight texels, so one line covers 64 pixels of span at eight
  // and 32 at four, roughly doubling fetches from the census 35,355/frame and
  // misses from 11,038. Set back to 8 if bands stop finishing; 2 if four still
  // looks coarse and the budget allows it.
  //
  // tb_m2_span_tex now runs the SAME value as this instantiation (R389). It
  // used to prove PIXSTEP 2 while this said 8, which is how R323's
  // texture-step bug shipped.
  // R607: THE FILL MASK'S WIRES, declared ahead of both users. One bit a
  // pixel for the ONE band being filled -- the fill does a band start to
  // finish (C_REPLAY .. C_DONE) -- 32 pixels a word, MROW words a row. Its
  // logic is below fill_buf.
  localparam int unsigned MROW = (SCR_W + 31) / 32;
  localparam int unsigned MDEP = BAND_H * MROW;
  localparam int unsigned MAW  = $clog2(MDEP);
  logic [MDEP-1:0]       mk_valid;
  logic                  mk_we;
  logic [MAW-1:0]        mk_pwi;
  logic [31:0]           mk_wd;
  logic signed [15:0]    mk_y0;

  m2_span_tex #(.PIXSTEP(PIXSTEP), .TXK(TXK), .FTB(FTB), .GC(PXC), .SCR_W(SCR_W), .BAND_H(BAND_H),
                .REUSE(TXREUSE)) u_spantex (   // R633
    .clk(clk), .rst_n(rst_n),
    .pxk(tex_pxk),   // R650
    .gamma_sel(tex_gamma),   // R784
    .mk_valid(mk_valid), .mk_we(mk_we), .mk_waddr(mk_pwi), .mk_wdata(mk_wd),   // R607
    .mk_band_y0(mk_y0),
    .in_valid(sq_qv), .in_ready(sq_rdy), .busy(spantex_busy),
    // m2_span_tex still carries these as 32; the fill and the queue are what
    // this change narrows.
    .in_y(32'(sq_y)), .in_x0(32'(sq_x0)), .in_x1(32'(sq_x1)),
    .in_col(sq_col), .in_moire(sq_moire),
    .in_u(sq_u), .in_v(sq_v),
    .in_dudx(sq_dudx), .in_dvdx(sq_dvdx),
    .in_ooz(sq_ooz), .in_doozdx(sq_doozdx),                   // R337
    .in_tex(sq_tex), .in_tex_en(sq_tex_en),
    .out_valid(tx_span_valid), .out_ready(tx_span_ready),
    .out_y(tx_span_y), .out_x0(tx_span_x0), .out_x1(tx_span_x1),
    .out_col(tx_span_col), .out_moire(tx_span_moire),
    .tx_req(tex_req), .tx_rdy(tex_rdy), .tx_ack(tex_ack), .tx_tex(tex_state),
    .tx_u(tex_u), .tx_v(tex_v), .tx_texel(tex_texel), .tx_take(tex_take),   // R539
    .late(tex_late),                                                          // R633
    .dbg_texpix(dbg_texpix), .dbg_texnz(dbg_texnz),
    .dbg_hot(dbg_walk_hot), .dbg_hotcyc(dbg_walk_hotcyc),   // R436
    .dbg_wait(walk_wait)                                    // R554
  );

  // R280: THE SWEEP HAPPENS ONCE A FRAME, NOT ONCE A WRITE.
  //
  // m2_texel answers no request while it is clearing its tags, and the game
  // uploads its textures in bursts of tens of thousands of words -- every one
  // of them raising `inval`. Re-entering the sweep per write means the cache
  // never serves, the span walk waits in T_FETCH, the band never finishes, and
  // the picture stops for the length of the upload. That is R266's mistake
  // exactly: invalidate-everything is the correct answer to the wrong
  // question.
  //
  // So a write marks the cache DIRTY and the sweep runs at the next frame
  // start. The cost is at most one frame of stale texels; the alternative is a
  // frozen picture whenever a texture is loaded.
  logic tex_dirty;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)          tex_dirty <= 1'b0;
    else if (frame_start) tex_dirty <= 1'b0;
    else if (tex_inval)   tex_dirty <= 1'b1;
  end
  wire tex_sweep = tex_dirty && frame_start;

  // R561: AND IT CROSSES TO clk_mem AS A TOGGLE. tex_sweep is one core-clock
  // pulse and the cache lives on clk_mem; at any ratio but an exact 2:1 a
  // pulse cannot simply be wired across. m2_texel edge-detects `inval`, so a
  // one-cycle pulse on its own clock is what it wants.
  logic       sweep_tog;
  logic [2:0] sweep_s;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)         sweep_tog <= 1'b0;
    else if (tex_sweep) sweep_tog <= ~sweep_tog;
  end
  always_ff @(posedge clk_mem or negedge rst_n) begin
    if (!rst_n) sweep_s <= 3'd0;
    else        sweep_s <= {sweep_s[1:0], sweep_tog};
  end
  wire tex_sweep_f = sweep_s[2] ^ sweep_s[1];

  // R318: the request crosses to clk_mem here. m2_texel's `ack` is one cycle,
  // which at 100 MHz is 10 ns and invisible to a 50 MHz sampler half the time --
  // and a missed acknowledge hangs the span walk in T_FETCH until its 511-cycle
  // timeout. m2_texel_x2 holds it up until the request drops, exactly as
  // m2_sdram_x2 does for the memory ports.
  logic        txf_req, txf_ack, txf_rdy;   // R474
  logic [31:0] txf_tex;
  logic [19:0] txf_u, txf_v;
  logic [8:0]  txf_texel;                  // R620: {discard, t}

  // R539: fetches in flight; K must equal m2_span_tex's TXK (R553: 8).
  // R558: FOUR, NOT EIGHT. R553's eight scrambled textures on the board
  // (s285, Ben: "that's the broken one"; s281 at four is clean) while being
  // pixel-exact in simulation -- the wider queues across the 2:1 had failing
  // paths into m2_texel on s285. Back to the configuration the board trusts.
  // R561: AN ASYNCHRONOUS QUEUE, NOT A 2:1 RATIO -- m2_texel_cdc. Same ports
  // and protocol; the pointers cross in Gray code.
  // R620: nine bits back; a timed-out fetch answers opaque and full (0x0FF).
  // f_waddr and friends (R583) are m2_texel's precomputed address and are
  // left open: m2_texel_bl places four texels of its own.
  m2_texel_cdc #(.K(TXK), .TW(9), .TO_VAL(255)) u_texel_x2 (
    .clk_slow(clk), .s_rst_n(rst_n), .clk_fast(clk_mem), .f_rst_n(rst_n),
    .s_req(tex_req), .s_rdy(tex_rdy), .s_ack(tex_ack), .s_tex({tex_late, tex_state[30:0]}),   // R627
    .s_u(tex_u), .s_v(tex_v), .s_texel(tex_texel), .s_take(tex_take),
    .f_req(txf_req), .f_rdy(txf_rdy), .f_ack(txf_ack), .f_tex(txf_tex),
    .f_u(txf_u), .f_v(txf_v), .f_texel(txf_texel),
    .f_waddr(), .f_sheet(), .f_x2p(), .f_y2p(), .dbg_to(dbg_texto)   // R650
  );

  // R328: IDX_BITS 11 -- 2048 lines / 16 KB, SET HERE AND NOT IN THE MODULE.
  // m2_char_cache's size lives at its instantiation for the reason the area
  // budget records: editing a module DEFAULT that an instantiation overrides is
  // a silent no-op, and this one was not overridden at all, which is just as
  // easy to miss from the other direction.
  //
  // WHY NOW: R326 put the textured translucent polygons back and the texel
  // cache took the weight -- misses 8,556 -> 16,772 a frame and the hit rate
  // 60.3% -> 54.3%, measured on the board. This is 8 M10K of the 28 free.
  // 4096 lines would be 24 and was NOT taken: R322's doubling is a measurement
  // as much as a change, and spending the whole headroom before reading the
  // curve is how R304 and R307 both went wrong.
  // R453: 2048 -> 4096 LINES, 16 KB -> 32 KB, +21 M10K of the 48 free.
  //
  // With textures OFF all fifty bands land; with them on, two. Same geometry,
  // same quad store, same display list -- so the supply is fine and the entire
  // cost is the texture path. Untextured a span is ONE handshake; textured it
  // expands into width/PIXSTEP groups each with a texel fetch, so a 400-pixel
  // span is a hundred fetches. Measured: 45,835 fetches a frame at 56.3% hit,
  // about 20,000 misses, each an SDRAM round trip.
  //
  // The one lever that costs M10K rather than ALM, which is the resource this
  // design still has. R328 measured 1024 -> 2048 taking the hit rate
  // 54.3% -> 64.9%.
  //
  // R620: m2_texel_bl, the bilinear fetch -- the same 4,096 lines as two
  // 2,048-line banks by row-pair parity (IB 11), so a 2x2 block comes back in
  // one access 87.5% of the time. Point mode is the old picture.
  m2_texel_bl #(.AW(TEX_AW), .IB(11), .RSP_D(TXRSP), .NS(TXNS)) u_texel (   // R622: 4 entries, measured equal; R789: TXRSP
    .clk(clk_mem), .rst_n(rst_n),
    .base_s0(tex_base0), .base_s1(tex_base1), .bilinear(tex_bilinear),
    .req(txf_req), .rdy(txf_rdy), .ack(txf_ack), .tex(txf_tex),
    .u(txf_u), .v(txf_v), .texel(txf_texel),
    .m_req(tex_m_req), .m_addr(tex_m_addr), .m_ack(tex_m_ack), .m_data(tex_m_data),
    // R480: the second SDRAM port, so two fills can be in flight.
    .m2_en(tex_m2_en), .m2_req(tex_m2_req), .m2_addr(tex_m2_addr),
    .m2_ack(tex_m2_ack), .m2_data(tex_m2_data),
    .m3_en(tex_m3_en), .m3_req(tex_m3_req), .m3_addr(tex_m3_addr),     // R628
    .m3_ack(tex_m3_ack), .m3_data(tex_m3_data),
    .m4_en(tex_m4_en), .m4_req(tex_m4_req), .m4_addr(tex_m4_addr),
    .m4_ack(tex_m4_ack), .m4_data(tex_m4_data),
    .inval(tex_sweep_f),                          // R561: crossed
    .dbg_hits(dbg_texhit), .dbg_misses(dbg_texmiss), .dbg_lost(dbg_texlost),
    .dbg_sweeps(dbg_texsweep)
  );

  // RGB888 to RGB565 on the way in, as the reference does: the colour is
  // already quantised upstream, so this costs less than it looks.
  wire [15:0] span_565 = {tx_span_col[23:19], tx_span_col[15:10], tx_span_col[7:3]};

  // ------------------------------------------------ R640: the DDR3 framebuffer
  //
  // From branch ddr3 (R355-R360), with two changes for today's clocks. The
  // branch ran the scanout on `clk`; since R564 it is on clk_mem (TWO_CLOCKS),
  // so the line-ahead request crosses by a toggle and two flops, and the line
  // number is read only after the toggle has arrived (it changes once a line).
  //
  // WHICH BUFFER IS WHICH (R359). `fb_draw` is drawn into; `fb_show` is the
  // last COMPLETE frame, taken at a frame_start so the reader never changes
  // buffer part way down the screen. A list that arrives while the previous is
  // still being drawn replaces it in place (counted as a drop) -- the display
  // keeps the last complete frame, which is what the hardware does.
  // R650: AND NOT WHILE A DRAW IS IN FLIGHT. A list swapped in over a draw
  // restarted it in place (R359's "replaces it in place"), and that restart
  // was wrong three ways: the band being filled finished with the NEW list's
  // quads at the old band's place, C_DONE then advanced the just-reset
  // fill_band to 1 so band 0 was never drawn, and the list-clear ran under the
  // band still writing. The frame still reached fb_complete and was shown.
  // s540 counted 7 such drops in 150 s at PIXSTEP 4; at PIXSTEP 1 (a draw of
  // 3.5-5 video frames against a list every 2.09) nearly every draw was one --
  // tb_m2_raster3d M2_R3D_LIST2 reproduced it, rows 0-7 wrong across the whole
  // width. Now the new list waits, sorted, until the draw is whole; the store
  // stops collecting meanwhile and the geometry waits on q_ready. Every frame
  // published is one list drawn start to finish.
  logic fb_draw, fb_show, fb_shown_ok, fb_complete, fb_busy;
  wire swap = frame_start && (pst == P_READY) && !(FB_DDR3 && fb_busy);
  assign list_hold = FB_DDR3 && (pst == P_READY) && fb_busy && !fb_test;   // R652; R653
  logic tp_done;   // R653: the self-test generator's frame is whole
  logic [2:0] tp_show_fid;   // R656: the frame number of the frame on show
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fb_draw <= 1'b0; fb_show <= 1'b1; fb_shown_ok <= 1'b0; fb_busy <= 1'b0; tp_show_fid <= '0;
      dbg_fb_pub <= 16'd0; dbg_fb_drop <= 16'd0;
    end else if (FB_DDR3 && fb_test) begin
      // R653: the generator's frames, published whole at the frame edge; the
      // lists go on swapping (the walk must not stall) and draw nothing.
      fb_busy <= 1'b0;
      if (frame_start && tp_done && fbw_empty) begin   // R660
        tp_show_fid <= tp_fid;   // R656: the frame published is the one just finished
        fb_show <= fb_draw; fb_shown_ok <= 1'b1; fb_draw <= ~fb_draw;
      end
    end else if (FB_DDR3) begin
      if (frame_start && fb_complete) begin
        fb_show     <= fb_draw;
        fb_shown_ok <= 1'b1;
      end
      if (swap) begin
        fb_busy <= 1'b1;
        if (fb_busy) begin
          if (!(&dbg_fb_drop)) dbg_fb_drop <= dbg_fb_drop + 16'd1;
        end else if (fb_complete) begin
          fb_draw <= ~fb_draw;
          if (!(&dbg_fb_pub)) dbg_fb_pub <= dbg_fb_pub + 16'd1;
        end
      end else if (fb_complete) fb_busy <= 1'b0;
    end
  end

  logic [23:0] fb_rd_col;
  logic        fb_rd_hit;
  logic        fbw_ready;
  logic        fbw_in_ready;   // R653: the writer's own ready; the fill sees it only outside the self-test
  logic        fbw_empty;      // R660: nothing held in the writer, nothing in flight
  // R683: the writer as the fill mask's painting group (see mk_a); R685: it
  // reads one word and writes another a stage later
  logic [8:0]  fbw_ry, fbw_rx0, fbw_wy, fbw_wx0;
  logic [31:0] fbw_rword, fbw_wd;
  logic        fbw_we;
  assign fbw_ready = fbw_in_ready && !fb_test;

  // ---------------------------------------------------------------- R653
  // THE SELF-TEST'S GENERATOR (clk). Every visible row, in bit-reversed order
  // (so consecutive writes are not consecutive rows), every 8-pixel cell, in
  // two spans split at w = (cell + row) & 7 -- odd starts, single-pixel heads
  // and tails and whole-word bodies all get written, with their byte enables.
  // A pixel's colour is {row[8:0], cell[5:0], frame[2:0], row[5:0] ^ cell}:
  // it names its own place, so the checker needs nothing but the colour it
  // reads, and the frame number catches a row that was never rewritten (the
  // pattern is otherwise the same every frame, and a stale row would pass).
  logic        tp_valid, tp_active, tp_half;
  logic [8:0]  tp_r;             // row counter; the row is its bit reversal
  logic [5:0]  tp_i;             // cell
  logic [15:0] tp_y, tp_x0, tp_x1;
  logic [23:0] tp_col;
  function automatic logic [8:0] rev9(input logic [8:0] v);
    for (int b = 0; b < 9; b++) rev9[b] = v[8 - b];
  endfunction
  wire  [8:0]  tp_row = rev9(tp_r);
  wire  [2:0]  tp_w   = 3'(tp_i) + tp_row[2:0];
  wire  [5:0]  tp_chk = tp_row[5:0] ^ tp_i;
  logic [2:0]  tp_fid;           // the generated frame's number
  always_comb begin
    tp_y   = 16'(tp_row);
    tp_col = {tp_row, tp_i, tp_fid, tp_chk};
    tp_x0  = 16'({tp_i, 3'b000}) + ((tp_half) ? 16'(tp_w) : 16'd0);
    tp_x1  = (!tp_half && tp_w != 3'd0) ? 16'({tp_i, 3'b000}) + 16'(tp_w) - 16'd1
                                        : 16'({tp_i, 3'b111});
  end
  assign tp_valid = FB_DDR3 && fb_test && tp_active && (tp_row < 9'(SCR_H));
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tp_active <= 1'b0; tp_done <= 1'b0; tp_half <= 1'b0; tp_r <= '0; tp_i <= '0; tp_fid <= '0;
    end else if (!fb_test) begin
      tp_active <= 1'b0; tp_done <= 1'b0; tp_half <= 1'b0; tp_r <= '0; tp_i <= '0;
    end else begin
      if (!tp_active && !tp_done) tp_active <= 1'b1;
      // a restart when the finished frame is published
      if (tp_done && frame_start) begin tp_done <= 1'b0; tp_active <= 1'b1; tp_fid <= tp_fid + 3'd1; end
      // a row off the screen is skipped; a span taken advances
      if (tp_active && ((tp_row >= 9'(SCR_H)) || fbw_in_ready)) begin
        // the second span of a cell exists only when the split is inside it
        if (tp_row >= 9'(SCR_H) || tp_half || tp_w == 3'd0) begin
          tp_half <= 1'b0;
          if (tp_row >= 9'(SCR_H) || tp_i == 6'(SCR_W / 8 - 1)) begin
            tp_i <= '0;
            if (&tp_r) begin tp_r <= '0; tp_active <= 1'b0; tp_done <= 1'b1; end
            else tp_r <= tp_r + 9'd1;
          end else tp_i <= tp_i + 6'd1;
        end else tp_half <= 1'b1;
      end
    end
  end
  logic        fb_clear_req, fb_clear_busy;
  // Cleared when a NEW LIST arrives, not every frame (R359).
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                 fb_clear_req <= 1'b0;
    else if (FB_DDR3 && swap && !fb_test) fb_clear_req <= 1'b1;   // R653: not under the self-test
    else if (fb_clear_busy)     fb_clear_req <= 1'b0;
  end

  generate
    if (FB_DDR3 && FTB && !FB_WCOMB) begin : g_fb_ftb_needs_wcomb
      FB_DDR3_FTB_requires_FB_WCOMB u_error ();   // no such module: elaboration stops here (R683)
    end
    if (FB_DDR3) begin : g_fb
      logic        w_req, w_we, w_wnext, w_wacc, w_ack;
      logic [24:0] w_addr;
      logic [7:0]  w_blen, w_be;
      logic [63:0] w_din;
      logic        r_req, r_we, r_rvalid, r_ack;
      logic [24:0] r_addr;
      logic [7:0]  r_blen;
      logic        fbr_hit;
      logic        fbr_hungry;   // R655: the scanout has a line to fetch; the writer waits
      // R656: the writer's credit, in beats; refilled at the OSD's pace,
      // spent a beat per write beat taken (w_wnext)
      logic signed [8:0] wcred;
      logic [3:0]        pace_ctr;
      wire  [3:0]        pace_div = (fb_pace == 3'd0) ? 4'd0 : (4'd1 << (fb_pace - 3'd1)) - 4'd1;
      wire               pace_hold = (fb_pace != 3'd0) && (wcred < $signed({1'b0, w_blen}));
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin wcred <= 9'sd64; pace_ctr <= '0; end
        else begin
          automatic logic signed [8:0] c = wcred;
          if (fb_pace == 3'd0) c = 9'sd64;
          else if (pace_ctr >= pace_div) begin if (c < 9'sd64) c = c + 9'sd1; end
          if (w_wnext) c = c - 9'sd1;
          wcred    <= c;
          pace_ctr <= (fb_pace == 3'd0 || pace_ctr >= pace_div) ? 4'd0 : pace_ctr + 4'd1;
        end
      end

      if (FB_WCOMB) begin : g_wcomb
        m2_fb_wcomb #(.SCR_W(SCR_W), .SCR_H(SCR_H), .STRIDE(512), .FTB(FTB)) u_fbw (
          .clk(clk), .rst_n(rst_n),
          .fb_sel(fb_draw),
          .clear_req(fb_clear_req), .clear_busy(fb_clear_busy),
          .in_valid(fb_test ? tp_valid : tx_span_valid), .in_ready(fbw_in_ready),   // R653
          .in_y(fb_test ? tp_y : tx_span_y[15:0]), .in_x0(fb_test ? tp_x0 : tx_span_x0[15:0]),
          .in_x1(fb_test ? tp_x1 : tx_span_x1[15:0]),
          .in_col(fb_test ? tp_col : tx_span_col), .in_painted(1'b1),
          .in_moire(fb_test ? 1'b0 : tx_span_moire),   // R640
          .m_req(w_req), .m_we(w_we), .m_addr(w_addr), .m_blen(w_blen),
          .m_din(w_din), .m_be(w_be), .m_wnext(w_wnext), .m_wacc(w_wacc), .m_ack(w_ack),
          .empty(fbw_empty),
          .pg_ry(fbw_ry), .pg_rx0(fbw_rx0), .pg_rword(fbw_rword),   // R683, R685
          .pg_we(fbw_we), .pg_wy(fbw_wy), .pg_wx0(fbw_wx0), .pg_wd(fbw_wd),
          .dbg_pixels(dbg_fb_pixels), .dbg_clears(), .dbg_st()
        );
      end else begin : g_wone
        assign fbw_ry = '0; assign fbw_rx0 = '0; assign fbw_we = 1'b0;
        assign fbw_wy = '0; assign fbw_wx0 = '0; assign fbw_wd = '0;
        m2_fb_write #(.SCR_W(SCR_W), .SCR_H(SCR_H), .STRIDE(512)) u_fbw (
          .clk(clk), .rst_n(rst_n),
          .fb_sel(fb_draw),
          .clear_req(fb_clear_req), .clear_busy(fb_clear_busy),
          .in_valid(fb_test ? tp_valid : tx_span_valid), .in_ready(fbw_in_ready),   // R653
          .in_y(fb_test ? tp_y : tx_span_y[15:0]), .in_x0(fb_test ? tp_x0 : tx_span_x0[15:0]),
          .in_x1(fb_test ? tp_x1 : tx_span_x1[15:0]),
          .in_col(fb_test ? tp_col : tx_span_col), .in_painted(1'b1),
          .in_moire(fb_test ? 1'b0 : tx_span_moire),   // R640
          .m_req(w_req), .m_we(w_we), .m_addr(w_addr), .m_blen(w_blen),
          .m_din(w_din), .m_be(w_be), .m_wnext(w_wnext), .m_wacc(w_wacc), .m_ack(w_ack),
          .empty(fbw_empty),
          .dbg_pixels(dbg_fb_pixels), .dbg_clears(), .dbg_st()
        );
      end

      // The line ahead of the beam, requested when the beam starts a line.
      // scan_clk side: which line to fetch (R360: wraps to 0 through blanking,
      // so line 0 is fetched fresh before the beam reaches it), and a toggle.
      logic [9:0] fl_sy_q;
      logic [8:0] fl_line;
      localparam int unsigned FB_LA = 3, V_TOT = 424;   // R655
      // R657: THE TOP OF THE FRAME IS FETCHED EARLY. Lines 0-3 go into the
      // buffers lines 380-383 used, free once those are shown, so they are
      // fetched on scan lines 385-388 -- after the flip at the start of the
      // blanking (frame_start is the vblank edge), with ~36 lines to land --
      // not on 421-423, after the writer has had the whole blanking to fill the
      // HPS queue (R656: row 0 held row 380 in every frame of the self-test).
      // A second request for line 3 at scan line 0 finds it fetched already.
      // R682: interlaced, the same rules on a field's 192 displayed lines; the
      // early top fetch is the NEXT field's (field flips at the wrap)
      wire  [9:0] scrh_e = scan_il ? 10'(SCR_H / 2) : 10'(SCR_H);
      wire  [9:0] top0_e = scrh_e + 10'd1;                 // 385, or 193
      wire        fl_top = (scan_y >= top0_e) && (scan_y < top0_e + 10'(FB_LA + 1));
      wire  [9:0] fl_tgt = fl_top                                ? scan_y - top0_e
                         : (scan_y + 10'(FB_LA) < scrh_e)        ? scan_y + 10'(FB_LA)
                         : scrh_e;   // nothing
      logic       fl_tog, fl_fld;
      always_ff @(posedge scan_clk or negedge rst_n) begin
        if (!rst_n) begin fl_sy_q <= 10'd0; fl_line <= 9'd0; fl_tog <= 1'b0; fl_fld <= 1'b0; end
        else begin
          fl_sy_q <= scan_y;
          // R655: THREE LINES AHEAD. The target is (scan_y + 3) mod V_TOTAL;
          // a target in the blanking is not fetched, so the first lines of a
          // frame are fetched during the last blanking lines before it.
          if (scan_y != fl_sy_q && fl_tgt < scrh_e) begin
            fl_line <= 9'(fl_tgt);
            fl_fld  <= scan_il && (scan_field ^ fl_top);   // R682
            fl_tog  <= ~fl_tog;
          end
        end
      end
      // clk side: two flops on the toggle; the line number, stable for a whole
      // line, is sampled only once the toggle has arrived.
      logic [2:0] fl_tog_s;
      logic [8:0] fl_line_c;
      logic       fl_fld_c;
      logic       line_pulse;
      logic [2:0] il_s;                                  // R682: the OSD bit, into clk
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin fl_tog_s <= 3'd0; fl_line_c <= 9'd0; fl_fld_c <= 1'b0; line_pulse <= 1'b0; il_s <= 3'd0; end
        else begin
          il_s       <= {il_s[1:0], scan_il};
          fl_tog_s   <= {fl_tog_s[1:0], fl_tog};
          line_pulse <= fl_tog_s[2] ^ fl_tog_s[1];
          if (fl_tog_s[2] ^ fl_tog_s[1]) begin fl_line_c <= fl_line; fl_fld_c <= fl_fld; end
        end
      end

      m2_fb_read #(.WIDTH(SCR_W), .STRIDE(512), .LA(FB_LA), .V_TOTAL(V_TOT)) u_fbr (
        .clk(clk), .rd_clk(scan_clk), .rst_n(rst_n),
        .fb_sel(fb_show),
        .line_req(line_pulse), .line_y(fl_line_c), .line_ready(), .hungry(fbr_hungry),   // R655
        .il(il_s[2]), .line_f(fl_fld_c),                                                  // R682
        .m_req(r_req), .m_we(r_we), .m_addr(r_addr), .m_blen(r_blen),
        .m_rvalid(r_rvalid), .m_dout(fb_dout), .m_ack(r_ack),
        .rd_buf(scan_y[1:0]), .rd_x(scan_x[$clog2(SCR_W)-1:0]),   // R655
        .rd_col(fb_rd_col), .rd_hit(fbr_hit),
        .dbg_lines(dbg_fb_lines), .dbg_late(dbg_fb_late),
        .dbg_st(), .dbg_busy(), .dbg_acks_seen()
      );

      // Nothing is shown until a frame has been drawn (R359): DDR3 powers up
      // with garbage, and bit 24 of it is the painted flag.
      logic sok_s1, sok_s2;
      always_ff @(posedge scan_clk or negedge rst_n) begin
        if (!rst_n) begin sok_s1 <= 1'b0; sok_s2 <= 1'b0; end
        else begin sok_s1 <= fb_shown_ok; sok_s2 <= sok_s1; end
      end
      assign fb_rd_hit = fbr_hit && sok_s2;

      // R653: THE SELF-TEST'S CHECKER (scan_clk). u_fbr registers its read
      // address on this clock, so the colour standing after an edge is the
      // pixel whose x was presented at it -- ck_x1. Each pixel is checked once,
      // on the cycle its x first stands.
      logic [2:0]  tst_s;
      logic [9:0]  ck_x1, ck_x2, ck_y1;
      logic [15:0] ck_bad, ck_rows;
      logic        ck_rowbad, ck_rowwf, ck_have;   // R657: this row has a wrong-line / wrong-frame pixel
      logic [26:0] ck_first;
      logic [15:0] ck_bad_f, ck_rows_f;
      logic [26:0] ck_first_f;
      logic        ck_tog;
      wire  [8:0]  ck_ey   = ck_y1[8:0];
      wire  [5:0]  ck_ei   = ck_x1[8:3];
      // R656: the frame number expected is the frame PUBLISHED (tp_show_fid,
      // stable for a frame, carried on two flops), not the frame's first pixel:
      // a stale first row made every row of the frame count as bad.
      logic [2:0]  ck_sfid1, ck_sfid2;
      wire  [23:0] ck_exp  = {ck_ey, ck_ei, ck_sfid2, ck_ey[5:0] ^ ck_ei};
      logic [8:0]  ck_last;
      wire         ck_look = tst_s[2] && sok_s2 && (ck_x1 != ck_x2)
                          && (ck_x1 < 10'(SCR_W)) && (ck_y1 < 10'(SCR_H));
      wire         ck_isbad = !fbr_hit || (fb_rd_col != ck_exp);
      always_ff @(posedge scan_clk or negedge rst_n) begin
        if (!rst_n) begin
          tst_s <= '0; ck_x1 <= '0; ck_x2 <= '0; ck_y1 <= '0;
          ck_bad <= '0; ck_rows <= '0; ck_rowbad <= 1'b0; ck_have <= 1'b0; ck_first <= '0;
          ck_bad_f <= '0; ck_rows_f <= '0; ck_first_f <= '0; ck_tog <= 1'b0;
          ck_sfid1 <= '0; ck_sfid2 <= '0; ck_last <= '0; ck_rowwf <= 1'b0;
        end else begin
          tst_s <= {tst_s[1:0], fb_test};
          ck_x1 <= scan_x; ck_x2 <= ck_x1; ck_y1 <= scan_y;
          if (scan_y != ck_y1) begin ck_rowbad <= 1'b0; ck_rowwf <= 1'b0; end
          ck_sfid1 <= tp_show_fid; ck_sfid2 <= ck_sfid1;
          // R657: WHICH KIND OF WRONG. A bad pixel holding ANOTHER line's data
          // (or none) is a line-buffer fault; one holding its OWN line with the
          // wrong frame number is a frame fault -- the scanout reading a buffer
          // other than the one published. Rows of each kind are counted, and the
          // first bad pixel below row 4 (row 0's known staleness aside) is kept:
          // {row, the row it held, its frame number right, x/2}.
          if (ck_look && ck_isbad) begin
            automatic logic [8:0] held = fbr_hit ? fb_rd_col[23:15] : 9'h1FF;
            automatic logic       wl   = (held != ck_ey);
            if (wl  && !ck_rowbad && !(&ck_bad))  ck_bad  <= ck_bad + 16'd1;    // rows: wrong line
            if (!wl && !ck_rowwf && !(&ck_rows)) ck_rows <= ck_rows + 16'd1;   // rows: wrong frame
            if (wl)  ck_rowbad <= 1'b1;
            if (!wl) ck_rowwf  <= 1'b1;
            if (!ck_have && ck_ey >= 9'd4) begin
              ck_have  <= 1'b1;
              ck_first <= {ck_ey, held, (fb_rd_col[8:6] == ck_sfid2), ck_x1[8:1]};
            end
          end
          // the frame's totals, at the first line past the picture
          if (scan_y == 10'(SCR_H) && ck_y1 != 10'(SCR_H)) begin
            ck_bad_f <= ck_bad; ck_rows_f <= ck_rows;
            ck_first_f <= ck_first;   // R657
            ck_bad <= '0; ck_rows <= '0; ck_have <= 1'b0; ck_first <= '0;
            ck_tog <= ~ck_tog;
          end
        end
      end
      // to clk: the totals hold for a frame; taken once the toggle has crossed
      logic [2:0] ck_tog_s;
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin ck_tog_s <= '0; dbg_tp_bad <= '0; dbg_tp_rows <= '0; dbg_tp_first <= '0; end
        else begin
          ck_tog_s <= {ck_tog_s[1:0], ck_tog};
          if (ck_tog_s[2] ^ ck_tog_s[1]) begin
            dbg_tp_bad <= ck_bad_f; dbg_tp_rows <= ck_rows_f; dbg_tp_first <= ck_first_f;
          end
        end
      end

      // The reader wins: it has the beam deadline and the writer has not.
      m2_ddr3_arb u_arb (
        .clk(clk), .rst_n(rst_n),
        .a_req(r_req), .a_we(r_we), .a_addr(r_addr), .a_blen(r_blen),
        .a_din(64'd0), .a_be(8'hFF),
        .a_wnext(), .a_wacc(), .a_rvalid(r_rvalid), .a_ack(r_ack),
        .b_req(w_req), .b_hold(fbr_hungry || pace_hold), .b_we(w_we), .b_addr(w_addr), .b_blen(w_blen),   // R655, R656
        .b_din(w_din), .b_be(w_be),
        .b_wnext(w_wnext), .b_wacc(w_wacc), .b_rvalid(), .b_ack(w_ack),
        .m_req(fb_req), .m_we(fb_we), .m_addr(fb_addr), .m_blen(fb_blen),
        .m_din(fb_din), .m_be(fb_be),
        .m_wnext(fb_wnext), .m_wacc(fb_wacc), .m_rvalid(fb_rvalid), .m_ack(fb_ack),
        .m_dout(fb_dout), .dout(),
        .dbg_a_waits(), .dbg_b_waits(),
        .dbg_busy(), .dbg_owner()
      );
    end else begin : g_nofb
      assign fb_req = 1'b0; assign fb_we = 1'b0; assign fb_addr = 25'd0;
      assign fb_blen = 8'd0; assign fb_din = 64'd0; assign fb_be = 8'd0;
      assign fb_rd_col = 24'd0; assign fb_rd_hit = 1'b0;
      assign fbw_in_ready = 1'b0;
      assign fbw_empty    = 1'b1;
      assign fbw_ry = '0; assign fbw_rx0 = '0; assign fbw_we = 1'b0;
      assign fbw_wy = '0; assign fbw_wx0 = '0; assign fbw_wd = '0;
      assign dbg_tp_bad = '0; assign dbg_tp_rows = '0; assign dbg_tp_first = '0;   // R653
      assign fb_clear_busy = 1'b0;
      assign dbg_fb_lines = 16'd0; assign dbg_fb_late = 16'd0;
      assign dbg_fb_pixels = 32'd0;
    end
  endgenerate

  // --------------------------------------------------------- band buffers
  logic [NBUF-1:0]       bd_clear_req, bd_clear_busy;
  logic [NBUF-1:0]       bd_span_valid, bd_span_ready;
  logic [NBUF-1:0][15:0] bd_rd_col;
  logic [NBUF-1:0]       bd_rd_hit;
  logic [NBUF-1:0]       bd_painted;   // R485: a flag per band, not a count
  logic signed [15:0]    bd_y0 [NBUF];
  logic [BW-1:0]         bd_band [NBUF];
  logic [NBUF-1:0]       bd_ready;          // holds a finished band
  // R516: bd_ahead is gone -- see the study. fill_frame/disp_frame stay:
  // R506's re-phase needs to know whether the fill is still on the frame
  // being displayed.
  logic                  fill_frame, disp_frame;
  // R607: each band's painting group, and the mask's answer for it.
  logic [NBUF-1:0]                    bd_pg_active;
  logic [$clog2(BAND_H)-1:0]          bd_pg_row    [NBUF];
  logic [$clog2(SCR_W)-1:0]           bd_pg_x0     [NBUF];
  logic [3:0]                         bd_pg_wr     [NBUF];
  logic [3:0]                         bd_pg_filled [NBUF];

  genvar b, nb;
  generate
    // R640: no band buffers with the framebuffer -- their outputs still need
    // driving, because the sequencer and the mixer reference them.
    if (FB_DDR3) begin : g_noband
      assign bd_rd_col = '0; assign bd_rd_hit = '0; assign bd_painted = '0;
      assign bd_span_ready = '0; assign bd_clear_busy = '0; assign bd_pg_active = '0;
      for (nb = 0; nb < NBUF; nb++) begin : g_nopg   // Quartus 17: genvar declared outside
        assign bd_pg_row[nb] = '0; assign bd_pg_x0[nb] = '0; assign bd_pg_wr[nb] = '0;
      end
    end
    for (b = 0; b < (FB_DDR3 ? 0 : NBUF); b++) begin : g_band
      m2_raster_band #(.WIDTH(SCR_W), .HEIGHT(BAND_H), .FTB(FTB)) u_band (
        .clk(clk), .rd_clk(scan_clk), .rst_n(rst_n),
        .band_y0(bd_y0[b]),
        .clear_req(bd_clear_req[b]), .clear_busy(bd_clear_busy[b]),
        .span_valid(bd_span_valid[b]), .span_ready(bd_span_ready[b]),
        .span_y(tx_span_y[15:0]),
        .span_x0(tx_span_x0[15:0]), .span_x1(tx_span_x1[15:0]),
        .span_col(span_565), .span_moire(tx_span_moire),
        .rd_x(scan_x[$clog2(SCR_W)-1:0]),
        .rd_row(scan_y[$clog2(BAND_H)-1:0]),
        .rd_col(bd_rd_col[b]), .rd_hit(bd_rd_hit[b]),
        .dbg_spans(), .dbg_dropped(), .dbg_painted(bd_painted[b]),
        .pg_active(bd_pg_active[b]), .pg_row(bd_pg_row[b]), .pg_x0(bd_pg_x0[b]),   // R607
        .pg_wr(bd_pg_wr[b]), .pg_filled(bd_pg_filled[b])
      );
    end
  endgenerate

  // The buffer being filled, and the one the beam is reading.
  logic [BUFW-1:0] fill_buf;

  // R607: THE FILL MASK. Only fill_buf paints, so one mask serves every
  // buffer. The band asks about the four-pixel group it is painting and
  // writes only the lanes not yet filled (first write wins); what it writes
  // is ORed into the word. A word is read asynchronously out of an MLAB; the
  // last two writes are bypassed so a read of a word written a cycle or two
  // earlier -- consecutive groups of one span share a word -- never sees it
  // stale, whatever the MLAB's read-during-write timing. mk_valid says a
  // word has been written since the band started: clearing 128 flops at
  // C_REPLAY is instant where clearing the MLAB would take 128 cycles.
  // no_rw_check: without it Quartus 17.0 will not infer an async-read MLAB
  // ("uninferred due to unsupported read-during-write behavior") and builds
  // the mask from 4,096 flip-flops. The bypass above makes the answer exact.
  (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] mk_a [MDEP];
  logic [MAW-1:0] mk_b1_a, mk_b2_a;
  logic [31:0]    mk_b1_d, mk_b2_d;
  logic           mk_b1_v, mk_b2_v;
  // R611: OR of the six, not a select by fill_buf -- only the painting band
  // drives anything but zero (m2_raster_band gates pg_* on S_PAINT).
  logic [$clog2(BAND_H)-1:0] mk_prow;
  logic [$clog2(SCR_W)-1:0]  mk_px0;
  logic [3:0]                mk_pwr;
  logic                      mk_pact;
  always_comb begin
    mk_prow = '0; mk_px0 = '0; mk_pwr = '0; mk_pact = 1'b0;
    if (FB_DDR3) begin
      // R683: the framebuffer writer; the write side here, its read below.
      // The self-test (fb_test) draws its own pattern and never marks.
      mk_prow = ($clog2(BAND_H))'(fbw_wy - 9'(mk_y0));
      mk_px0  = ($clog2(SCR_W))'(fbw_wx0);
      mk_pact = fbw_we && !fb_test;
    end else
      for (int k = 0; k < NBUF; k++) begin
        mk_prow = mk_prow | bd_pg_row[k];
        mk_px0  = mk_px0  | bd_pg_x0[k];
        mk_pwr  = mk_pwr  | bd_pg_wr[k];
        mk_pact = mk_pact | bd_pg_active[k];
      end
  end
  wire  [4:0]                mk_poff = mk_px0[4:0];            // a multiple of 4
  assign mk_pwi = MAW'(mk_prow) * MAW'(MROW) + MAW'(mk_px0 >> 5);
  // R685: the word READ is the band's own (read-modify-write in one cycle),
  // or on the framebuffer the word the writer is walking, a stage ahead of
  // the one it writes.
  wire [$clog2(BAND_H)-1:0] mk_rrow = ($clog2(BAND_H))'(fbw_ry - 9'(mk_y0));
  wire [MAW-1:0] mk_rdi = FB_DDR3 ? (MAW'(mk_rrow) * MAW'(MROW) + MAW'(fbw_rx0 >> 5)) : mk_pwi;
  logic [31:0] mk_pword;
  always_comb begin
    if      (mk_b1_v && (mk_b1_a == mk_rdi)) mk_pword = mk_b1_d;
    else if (mk_b2_v && (mk_b2_a == mk_rdi)) mk_pword = mk_b2_d;
    else if (mk_valid[mk_rdi])               mk_pword = mk_a[mk_rdi];
    else                                     mk_pword = 32'd0;
  end
  assign fbw_rword = mk_pword;
  wire [3:0] mk_pfill = 4'(mk_pword >> mk_poff);
  // R611: the answer goes to every band; only the painting one uses it.
  always_comb
    for (int k = 0; k < NBUF; k++)
      bd_pg_filled[k] = FTB ? mk_pfill : 4'd0;
  assign mk_we = FTB && mk_pact && (FB_DDR3 || (mk_pwr != 4'd0));
  assign mk_wd = FB_DDR3 ? fbw_wd : (mk_pword | (32'(mk_pwr) << mk_poff));
  // R611: registered. bd_y0[fill_buf] is set in C_IDLE and fill_buf moves at
  // C_DONE; the span walk first queries at least two cycles after either.
  always_ff @(posedge clk) mk_y0 <= bd_y0[fill_buf];
  always_ff @(posedge clk) if (mk_we) mk_a[mk_pwi] <= mk_wd;
  logic [NBUF-1:0] bd_settled;
  // R540: BUFFERS ARE CLEARED IN THE BACKGROUND. bd_clean: cleared since the
  // beam last released it, and not yet claimed. bd_clr_pend/bd_clr_run: a
  // background clear has been asked for / has been seen running.
  logic [NBUF-1:0] bd_clean, bd_clr_pend, bd_clr_run;
  logic [3:0]      bd_settle_cnt [NBUF];
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < NBUF; i++) begin bd_settle_cnt[i] <= 4'd0; bd_settled[i] <= 1'b1; end
    end else begin
      for (int i = 0; i < NBUF; i++) begin
        if (bd_ready[i]) begin bd_settle_cnt[i] <= 4'd0; bd_settled[i] <= 1'b0; end
        else if (bd_settle_cnt[i] != 4'd8) bd_settle_cnt[i] <= bd_settle_cnt[i] + 4'd1;
        else bd_settled[i] <= 1'b1;
      end
    end
  end
  wire [BW-1:0] scan_band = BW'(scan_y / 10'(BAND_H));

  // THE BAND THE BEAM HAS PASSED -- AND DURING VERTICAL BLANK IT HAS PASSED
  // NOTHING (R225).
  //
  // `scan_y` is the raw line counter, 0..V_TOTAL-1, so through the 40 blanking
  // lines of a 424-line frame it reads 384..423 and its band index is 48..52 --
  // past EVERY band in the picture. The release below then freed each band the
  // fill finished during blanking the instant it was finished, and the fill
  // advanced regardless. The frame therefore opened with the first several
  // bands already spent: the beam reached line 0 with nothing in any buffer and
  // the picture began only where the fill had got to, as a dead-straight
  // full-width cut at a band index that does not depend on the scene at all.
  // That is what the board showed -- the tile layer visible above line ~92 with
  // the 3D starting abruptly beneath it -- and it is what `dbg_bands_done`
  // reading 51 against NBANDS=48 was saying all along: three to eight bands a
  // frame were being built and thrown away.
  //
  // Clamped to zero outside the visible area, the fill instead enters the frame
  // with NBUF bands already standing, which is the head start the design wanted
  // from having four buffers in the first place.
  wire [BW-1:0] scan_band_rel = (scan_y >= 10'(SCR_H)) ? '0 : scan_band;

  // SCAN_BAND BACK IN THE FILL DOMAIN, GRAY-CODED.
  //
  // The buffer release below reads a value derived from scan_y, which is the
  // scan domain's, in a block that runs on clk. That is a COUNTER crossing, and
  // a plain synchroniser is not enough for one: sample a binary counter
  // mid-transition and 7 -> 8 reads as anything from 0 to 15, which would
  // release a band the beam has not reached and drop its geometry. That is a
  // fault that looks like missing scenery, not like a clock-domain bug.
  //
  // Gray coding makes every increment a single-bit change, so a mid-transition
  // sample yields the old value or the new one and never a third. The band
  // counter only increments and resets between frames, which is the condition
  // Gray coding needs.
  //
  // Dormant at one clock, like the pair above, and correct at two.
  logic [BW-1:0] scan_band_f;
  generate
    if (TWO_CLOCKS) begin : g_sb_sync
      logic [BW-1:0] sb_gray_s1, sb_gray_s2;
      wire  [BW-1:0] sb_gray = scan_band_rel ^ (scan_band_rel >> 1);
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin sb_gray_s1 <= '0; sb_gray_s2 <= '0; end
        else        begin sb_gray_s1 <= sb_gray; sb_gray_s2 <= sb_gray_s1; end
      end
      always_comb begin
        scan_band_f = '0;
        for (int b = BW-1; b >= 0; b--)
          scan_band_f[b] = (b == BW-1) ? sb_gray_s2[b]
                                       : (scan_band_f[b+1] ^ sb_gray_s2[b]);
      end
    end else begin : g_sb_direct
      // One clock: the counter is read on the edge that changes it, which is
      // what every other read of scan_y in this module already does.
      always_comb scan_band_f = scan_band_rel;
    end
  endgenerate

  // SYNCHRONISED INTO THE SCAN DOMAIN.
  //
  // bd_ready and bd_band are registered in the `clk` domain and this block runs
  // in scan_clk's. Reading them combinationally is safe only while the two are
  // the same clock -- which they are today, so this is not fixing a live fault.
  // It is here so the module is correct by construction when they diverge, and
  // because that divergence is planned: the fetch budget wants the video on the
  // memory clock.
  //
  // THE FLAG AND THE INDEX CROSS TOGETHER. Synchronising the flag alone makes
  // the SAMPLING safe and leaves the index a cross-domain path in its own right,
  // which is a mistake this project has already made twice.
  //
  // Two flops on both, and safe for the same reason: an index is written before
  // its flag is raised and does not change until the buffer is released, so it
  // is static for the whole window it is read in.
  //
  // COSTS TWO CYCLES of band-presentation latency at one clock, where it removes
  // a metastability hazard at two.
  logic [NBUF-1:0] rdy_s2;
  logic [BW-1:0]   band_s2 [NBUF];
  generate
    if (TWO_CLOCKS) begin : g_rdy_sync
      logic [NBUF-1:0] rdy_s1;
      logic            dfr_s1;
      logic [BW-1:0]   band_s1 [NBUF];
      always_ff @(posedge scan_clk or negedge rst_n) begin
        if (!rst_n) begin
          rdy_s1 <= '0; rdy_s2 <= '0;
          for (int i = 0; i < NBUF; i++) begin band_s1[i] <= '0; band_s2[i] <= '0; end
        end else begin
          rdy_s1 <= bd_ready; rdy_s2 <= rdy_s1;
          for (int i = 0; i < NBUF; i++) begin
            band_s1[i] <= bd_band[i]; band_s2[i] <= band_s1[i];
          end
        end
      end
    end else begin : g_rdy_direct
      // One clock: read them where they are written. A band is presented on the
      // cycle it becomes ready rather than two cycles later.
      always_comb begin
        rdy_s2 = bd_ready;
        for (int i = 0; i < NBUF; i++) band_s2[i] = bd_band[i];
      end
    end
  endgenerate

  // Scan-out picks whichever buffer currently holds the beam's band. Combinational
  // over NBUF, which is three: cheaper than a register that has to track the beam.
  // A scanline the beam starts with no buffer holding its band draws nothing
  // there this frame. Counted in the scan domain, free-running; the debug
  // stream takes deltas.
  logic [9:0] scan_x_d;
  always_ff @(posedge scan_clk or negedge rst_n) begin
    // R487: WRAPS. The comment above says the stream takes deltas, and a delta
    // is right across a wrap -- but the guard below stuck it at 0xFFFF. At up
    // to 384 a frame that arrives in about three seconds, after which every
    // delta is zero. Identical to R484's two texture counters. NOTHING HAS EVER
    // READ THIS NUMBER: r3d_missed is declared at the top level, connected, and
    // consumed by nobody, so the fitter deletes it. It is the direct measure of
    // "the beam reached this band and no buffer was holding it" -- the one
    // question the band investigation has been trying to answer by inference.
    if (!rst_n) begin dbg_missed <= 16'd0; scan_x_d <= 10'd0; end
    else begin
      scan_x_d <= scan_x;
      if (scan_x == 10'd0 && scan_x_d != 10'd0 && scan_y < 10'(SCR_H)) begin
        automatic logic any_rdy = 1'b0;
        for (int i = 0; i < NBUF; i++)
          if (rdy_s2[i] && (band_s2[i] == scan_band)) any_rdy = 1'b1;
        if (!any_rdy) dbg_missed <= dbg_missed + 16'd1;
      end
    end
  end

  // R536: THE MISSED BANDS BY NAME, ONE FRAME AT A TIME.
  //
  // "5-10 bands always missing in the middle", and the fill's own counters say
  // it completes 48 bands in 80-100% of frames. Both can be true only if the
  // bands complete AFTER the beam has passed them -- or on time and empty.
  // This says which: a band set here was not standing in any buffer when the
  // beam started one of its lines. Latched at the first line past the picture.
  logic [63:0] miss_cur;
  logic [15:0] miss_lines_cur;
  always_ff @(posedge scan_clk or negedge rst_n) begin
    if (!rst_n) begin
      miss_cur <= '0; miss_lines_cur <= '0; dbg_miss_map <= '0; dbg_miss_lines <= '0;
    end else if (scan_x == 10'd0 && scan_x_d != 10'd0) begin
      if (scan_y < 10'(SCR_H)) begin
        automatic logic any_rdy = 1'b0;
        for (int i = 0; i < NBUF; i++)
          if (rdy_s2[i] && (band_s2[i] == scan_band)) any_rdy = 1'b1;
        if (!any_rdy) begin
          miss_cur[6'(scan_band)] <= 1'b1;
          miss_lines_cur          <= miss_lines_cur + 16'd1;
        end
      end else if (scan_y == 10'(SCR_H)) begin
        dbg_miss_map   <= miss_cur;
        dbg_miss_lines <= miss_lines_cur;
        miss_cur       <= '0;
        miss_lines_cur <= '0;
      end
    end
  end

  // R604: THE SELECT READS scan_band REGISTERED. scan_y moves only at the
  // start of a line, deep in horizontal blanking, so a copy one scan_clk
  // later picks the same buffer for every visible pixel -- and takes the
  // video timing counter's decode out of the mixer's path (s339: vcnt ->
  // mix_r_q, +0.105 ns, the second-thinnest path on clk_mem).
  logic [BW-1:0] scan_band_q;
  always_ff @(posedge scan_clk) scan_band_q <= scan_band;
  always_comb begin
    scan_col = 16'd0;
    scan_hit = 1'b0;
    if (FB_DDR3) begin   // R640: the line is already fetched; nothing to choose
      scan_col = {fb_rd_col[23:19], fb_rd_col[15:10], fb_rd_col[7:3]};
      scan_hit = fb_rd_hit;
    end else
      for (int i = 0; i < NBUF; i++)
        if (rdy_s2[i] && (band_s2[i] == scan_band_q)) begin
          scan_col = bd_rd_col[i];
          scan_hit = bd_rd_hit[i];
        end
  end

  // R640: the span walk feeds the framebuffer or the bands, never both.
  assign tx_span_ready = FB_DDR3 ? fbw_ready : bd_span_ready[fill_buf];
  always_comb begin
    bd_span_valid = '0;
    if (!FB_DDR3) bd_span_valid[fill_buf] = tx_span_valid;
  end

  // ------------------------------------------------------------ sequencing
  typedef enum logic [1:0] { P_COLLECT, P_SORT, P_SORTW, P_READY } pstate_t;
  typedef enum logic [2:0] { C_IDLE, C_CLR, C_CLRW, C_REPLAY, C_FILL, C_FILLW, C_DONE } cstate_t;
  pstate_t pst;
  cstate_t cst /*verilator public_flat_rd*/;   // R539: the bench histograms it
  assign dbg_pipe = {pst, cst, fb_busy, fb_complete, 1'b0};   // measurement build
  // R607: the fill mask's valid bits and bypass (declared with it, above).
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mk_valid <= '0; mk_b1_v <= 1'b0; mk_b2_v <= 1'b0;
      mk_b1_a <= '0; mk_b2_a <= '0; mk_b1_d <= '0; mk_b2_d <= '0;
    end else if (cst == C_REPLAY) begin   // a band's fill starts: nothing painted
      mk_valid <= '0; mk_b1_v <= 1'b0; mk_b2_v <= 1'b0;
    end else if (mk_we) begin
      mk_valid[mk_pwi] <= 1'b1;
      mk_b2_v <= mk_b1_v; mk_b2_a <= mk_b1_a; mk_b2_d <= mk_b1_d;
      mk_b1_v <= 1'b1;    mk_b1_a <= mk_pwi;  mk_b1_d <= mk_wd;
    end
  end
  // R541: WHY C_FILL IS WAITING, for the bench only (nothing reads it, so the
  // fitter drops it). 1 quad handed over, 2 quad offered and the fill busy,
  // 3 the store still replaying, 4 the band's last spans still painting.
  logic [2:0] fill_why /*verilator public_flat_rd*/;

  // R200 instrumentation: see the port comments.
  logic [19:0] rdy_cyc;
  logic        rdy_run;
  logic [19:0] col_cyc;
  logic        col_run;
  logic [7:0]  hold_cnt;
  logic  [7:0] bands_this, painted_this;   // R452
  logic [15:0] fillpass_this;              // R455

  // CLEAR UNCONDITIONALLY AT FRAME START, as the reference does.
  //
  // This was `(pst == P_COLLECT) && frame_start`, and in steady state that
  // never fires. The producer cycles
  //
  //     P_COLLECT -(q_end)-> P_SORT -> P_SORTW -> P_READY -(frame_start)-> P_COLLECT
  //
  // so at the moment frame_start arrives pst is P_READY, not P_COLLECT, and the
  // gate is false. The store is only ever cleared on frames where NO q_end
  // came -- that is, frames that drew nothing.
  //
  // The consequence is that quads accumulate forever. With the four test bars
  // that is 4 per frame into a 2,048-entry store: full after 512 frames, about
  // 8.5 seconds, after which everything new is dropped and the picture decays.
  // which matches the observed behaviour -- four correct bars that fade away.
  //
  // It is not a test-only fault. The geometry path issues q_end every frame
  // too, so the real renderer would have filled the store just as surely and
  // then stopped accepting geometry.
  //
  // MAME has no such condition: render_frame_start() resets poly_list_index at
  // the top of every geo_parse, unconditionally.
  // R211: cleared only when the banks swap -- the new collect bank is the
  // one that was on display, and it is emptied before the walk's first quad.
  // (`swap` is declared with the framebuffer above, R640.)
  // The store clears count[wbank]. On the swap cycle `bank` has not flipped
  // yet, so the clear is delayed one cycle to land on the new collect bank
  // (the one coming off display). The walk's first quad is many cycles away.
  logic swap_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) swap_d <= 1'b0; else swap_d <= swap;
  end
  assign qs_clear        = swap_d;
  assign qs_sort_start   = (pst == P_SORT);
  assign qs_replay_start = (cst == C_REPLAY);
  always_comb begin
    fill_why = 3'd0;
    if (cst == C_FILL) begin
      if (qs_out_valid)        fill_why = fl_in_ready ? 3'd1 : 3'd2;
      else if (qs_replay_busy) fill_why = 3'd3;
      else                     fill_why = 3'd4;
    end

  end

  // R547: the critical-period histogram. See dbg_seq_a. FOUR counters, not
  // eight: the eight-counter version took the design to 4,200 LABs of 4,191.
  // C_CLRW, the handoff and the band-end drain read ~0 in every bench regime,
  // and C_IDLE cannot occur while the fill is behind the beam.
  logic [17:0] sq_c [4];   // R553: 18 bits, reported in 1,024-cycle units (16 saturated)
  // R571: "the beam is in the picture" comes from scan_clk's domain, and with
  // the video on clk_mem (R564) it is synchronised like scan_band_f beside it.
  // The crossing inventory found this read raw: 216 endpoints.
  logic [1:0] sq_vis_s;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) sq_vis_s <= 2'b00;
    else        sq_vis_s <= {sq_vis_s[0], (scan_y < 10'(SCR_H))};
  end
  wire sq_crit = dvalid && (fill_frame == disp_frame) && sq_vis_s[1]
              && ((BW+1)'(fill_band) <= (BW+1)'(scan_band_f) + (BW+1)'(1));
  // R627: the same test at TXLATE bands, registered; it rides bit 31 of each
  // texel request (always 0 from m2_span_tex, unread by the cache before)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) tex_late <= 1'b0;
    else        tex_late <= !FB_DDR3 && (TXLATE != 0) && dvalid && (fill_frame == disp_frame) && sq_vis_s[1]
                            && ((BW+1)'(fill_band) <= (BW+1)'(scan_band_f) + (BW+1)'(TXLATE));
  end
  function automatic logic [7:0] sq8(input logic [17:0] c);
    sq8 = c[17:10];
  endfunction
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int k = 0; k < 4; k++) sq_c[k] <= '0;
      dbg_seq_a <= '0;
    end else if (frame_start) begin
      dbg_seq_a <= {sq8(sq_c[0]), sq8(sq_c[1]), sq8(sq_c[2]), sq8(sq_c[3])};
      for (int k = 0; k < 4; k++) sq_c[k] <= '0;
    end else if (sq_crit) begin
      if (!(&sq_c[0])) sq_c[0] <= sq_c[0] + 1'b1;
      // R554: the span walk's reasons, now that R547 has shown C_FILLW and
      // span-walk-busy each ~100% of the critical time on the board.
      if (walk_wait == 3'd2 && !(&sq_c[1])) sq_c[1] <= sq_c[1] + 1'b1;   // texel
      if (walk_wait == 3'd3 && !(&sq_c[2])) sq_c[2] <= sq_c[2] + 1'b1;   // no credit
      if (walk_wait == 3'd1 && !(&sq_c[3])) sq_c[3] <= sq_c[3] + 1'b1;   // painter
    end
  end
  assign dbg_seq_b = '0;
  assign qs_out_ready    = (cst == C_FILL) && fl_in_ready && !sp_1st;   // R677: held for the second triangle
  always_ff @(posedge clk or negedge rst_n) begin   // R677: which triangle is next
    if (!rst_n)                                 sp_b <= 1'b0;
    else if (fl_in_valid && fl_in_ready && sp_on) sp_b <= ~sp_b;
  end
  assign fl_in_valid     = (cst == C_FILL) && qs_out_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pst <= P_COLLECT; cst <= C_IDLE;
      bank <= 1'b0; dvalid <= 1'b0;
      fill_band <= '0; fill_buf <= '0; bd_ready <= '0; fb_complete <= 1'b0;
      fill_frame <= 1'b0; disp_frame <= 1'b0;   // R506: the re-phase guard
      bd_clear_req <= '0; dbg_bands <= 16'd0;
      bd_clean <= '0; bd_clr_pend <= '0; bd_clr_run <= '0;   // R540
      dbg_ready_cyc <= 16'd0; dbg_bands_done <= 8'd0;
      dbg_bands_painted <= 8'd0; painted_this <= 8'd0;   // R452
      dbg_fillpass <= 16'd0; fillpass_this <= 16'd0;     // R455
      dbg_late_frames <= 8'd0; dbg_qend_frames <= 8'd0;
      dbg_collect_cyc <= 16'd0; col_cyc <= 20'd0; col_run <= 1'b0;
      dbg_hold <= 8'd0; hold_cnt <= 8'd0;
      rdy_cyc <= 20'd0; rdy_run <= 1'b0; bands_this <= 8'd0; painted_this <= 8'd0;
      for (int i = 0; i < NBUF; i++) begin bd_y0[i] <= 16'sd0; bd_band[i] <= '0; end
    end else begin
      bd_clear_req <= '0;

      // R540: THE CLEAR MOVES OFF THE FILL'S PATH.
      //
      // The sequencer used to claim a buffer, clear it -- one word a cycle,
      // ~960 cycles -- and only then fill it. tb_m2_raster3d put that wait,
      // C_CLRW, at 27% of ALL cycles in a frame whose middle bands miss the
      // beam, with the fill idle 71% of the time: the fill was not slow, it
      // was waiting for clean buffers. A clear does not depend on which band
      // the buffer will hold, and every buffer has its own clear engine, so
      // any buffer the beam has released is cleared at once, in the
      // background, while the fill works on another. By the time the
      // sequencer reaches it, it is clean.
      //
      // Never the buffer the sequencer is on or about to claim (fill_buf):
      // that one keeps the original path, so the two can never both drive it.
      for (int i = 0; i < NBUF; i++) begin
        if (bd_clr_pend[i]) begin
          if (bd_clear_busy[i]) bd_clr_run[i] <= 1'b1;
          else if (bd_clr_run[i]) begin
            bd_clr_pend[i] <= 1'b0; bd_clr_run[i] <= 1'b0; bd_clean[i] <= 1'b1;
          end
        end else if (BUFW'(i) != fill_buf && !bd_ready[i] && bd_settled[i]
                     && !bd_clean[i] && !bd_clear_busy[i]) begin
          bd_clear_req[i] <= 1'b1;
          bd_clr_pend[i]  <= 1'b1;
        end
      end

      // ---- R200's two numbers.
      //
      // rdy_run is high from frame_start until pst reaches P_READY, and rdy_cyc
      // counts while it is. That interval is collect-plus-sort, and it is the
      // ONLY thing that can stop the first band being filled during vblank --
      // the fill itself is beam-paced and cannot start early. Saturating rather
      // than wrapping: a wrapped count of a long stall reads like a short one.
      if (rdy_run && !(&rdy_cyc)) rdy_cyc <= rdy_cyc + 20'd1;
      if (rdy_run && (pst == P_READY)) begin
        rdy_run       <= 1'b0;
        dbg_ready_cyc <= rdy_cyc[19:4];
      end
      if (col_run && !(&col_cyc)) col_cyc <= col_cyc + 20'd1;
      if (col_run && q_end) begin
        col_run         <= 1'b0;
        dbg_collect_cyc <= col_cyc[19:4];
      end

      if (frame_start && (pst == P_COLLECT)) dbg_late_frames <= dbg_late_frames + 8'd1;
      if (frame_start && !(&hold_cnt)) hold_cnt <= hold_cnt + 8'd1;
      if (q_end) dbg_qend_frames <= dbg_qend_frames + 8'd1;

      // ---- producer: collect quads for the frame, then sort once
      case (pst)
        P_COLLECT: if (q_end) pst <= P_SORT;
        P_SORT:    pst <= P_SORTW;
        P_SORTW:   if (!qs_sort_busy) pst <= P_READY;
        P_READY:   if (swap) begin pst <= P_COLLECT; bank <= ~bank; dvalid <= 1'b1;   // R650: swap, not frame_start
                                          dbg_hold <= hold_cnt; hold_cnt <= 8'd0; end
      endcase

      // ---- consumer: one band at a time into the rotating buffers
      case (cst)
        // A RELEASED BUFFER SETTLES BEFORE IT IS REUSED (R213). bd_band[i]
        // crosses to the scan domain on plain flops; it is safe because it is
        // written long before bd_ready[i] rises -- EXCEPT at release, when the
        // beam clears bd_ready and the fill could retarget the buffer within a
        // cycle while rdy_s2 still reads 1 for two scan clocks: a mixed band
        // sample equal to the beam's own band would present a buffer being
        // cleared. Model 1 found the same class on its beam-band index
        // (a1d9192). Eight cycles of settle covers the two-flop crossing.
        // R505: DO NOT BUILD A BAND THE BEAM HAS ALREADY PASSED. RE-PHASE.
        //
        // The fill completes 51 band-fills a frame and two to five reach the
        // screen: it is at the right RATE and the wrong PHASE, finishing band
        // N just after the beam has gone by, so the release clears bd_ready
        // within a cycle of C_DONE setting it and the band is never shown
        // (R504). Grinding on in band order keeps it exactly that far behind
        // for the whole frame, because the average margin is only 8% -- 0.92
        // band-times a band -- which needs 62 bands to recover five and the
        // frame is 48.
        //
        // Skipped, the fill re-synchronises within a few bands and every band
        // after that lands. The skipped ones are not a loss: they could not
        // have been displayed, which is the whole point.
        //
        // R489 TRIED THIS AND WAS REVERTED, on tb_m2_raster3d reporting "the
        // top band painted nothing". That was the BENCH: it pulsed frame_start
        // with scan_y still on the last visible line, so the DUT saw the beam
        // at band 47 while the fill reset to band 0, and the comparison fired
        // for that tick and threw band 0 away. On the board frame_start is the
        // start of vblank, scan_y is past SCR_H and scan_band_rel is clamped to
        // zero, so it reads 0 > 0 and does not fire. R505 fixes the bench to be
        // blank-first as the board is, which is what its own comment always
        // claimed it was.
        // AT OR BEHIND, NOT JUST BEHIND. `>` skips until the fill lands ON the
        // beam's own band -- it then spends a band-time building the band the
        // beam is already crossing, the beam moves past while it works, and it
        // skips again. It chases the beam and finishes nothing: 861 pixels
        // against the 8,912 of not skipping at all, at TPL=150. `>=` leaves it
        // one band AHEAD, which is the least that can actually be displayed.
        // STRICTLY BEHIND, AND JUMP STRAIGHT TO ONE AHEAD.
        //
        // `>=` also fired when the fill was on the beam's OWN band, which can
        // still be displayed -- the beam is only entering it and has eight
        // lines to go -- so it threw away bands that would have landed and the
        // output went erratic in the healthy case. `>` alone crawls forward one
        // band a cycle and stops ON the beam, which is the same trap one band
        // later: 861 pixels against 8,912.
        //
        // Strictly behind, jumped in one step to the band after the beam's.
        // AND NOT ONCE THE FILL HAS WRAPPED. After band 47 the fill is
        // building the NEXT frame's head start while the beam is still at 47,
        // so `47 > 0` fires, the jump lands back on 0, and it fires again --
        // the fill does nothing at all for the rest of the frame, which is the
        // erratic healthy case (10824, 902, 902, 10824, 902). fill_frame says
        // which frame the fill is working on, so the skip applies only while
        // it is still on the one being displayed.
        // R640: WITH A FRAMEBUFFER THERE IS NO BEAM TO CATCH OR WAIT FOR --
        // only the once-a-list clear, and a list already drawn (fb_complete)
        // is not drawn again (R358/R359).
        C_IDLE: if (FB_DDR3) begin
          if (dvalid && !fb_complete && !fb_clear_req && !fb_clear_busy && !fb_test) begin   // R653
            bd_y0[fill_buf]   <= 16'sd0 + 16'(fill_band) * 16'(BAND_H);
            bd_band[fill_buf] <= fill_band;
            cst <= C_REPLAY;
          end
        end else if (dvalid && (fill_frame == disp_frame)
                           && (scan_band_f > fill_band)) begin
          fill_band <= (scan_band_f == BW'(NBANDS-1)) ? '0 : scan_band_f + BW'(1);
        end else if (dvalid && !bd_ready[fill_buf] && bd_settled[fill_buf]
                     && !bd_clr_pend[fill_buf]) begin   // R540: a clear in flight finishes first
          bd_y0[fill_buf]   <= 16'sd0 + 16'(fill_band) * 16'(BAND_H);
          bd_band[fill_buf] <= fill_band;
          if (bd_clean[fill_buf]) begin
            // R540: cleared in the background -- straight to the fill.
            bd_clean[fill_buf] <= 1'b0;
            cst <= C_REPLAY;
          end else begin
            bd_clear_req[fill_buf] <= 1'b1;
            cst <= C_CLR;
          end
        end
        C_CLR:  cst <= C_CLRW;
        C_CLRW: if (!bd_clear_busy[fill_buf]) cst <= C_REPLAY;
        C_REPLAY: cst <= C_FILL;
        C_FILL: begin
          if (fl_in_valid && fl_in_ready) cst <= C_FILLW;
          // R310: AND THE SPAN PATH MUST BE EMPTY. The FIFO decouples the fill
          // from the texel fetch, so the quad store running dry says nothing
          // about whether the spans it produced have been painted. Leaving
          // early paints them into the next band, which tb_m2_raster3d caught
          // as "a frame with no new list painted 2214, the previous 2009".
          else if (!qs_out_valid && !qs_replay_busy
                   && !sq_busy && !spantex_busy
                   && tx_span_ready && fbw_empty) cst <= C_DONE;   // and the band has painted the last one (R660: and written it)
        end
        C_FILLW: if (fl_quad_done) cst <= C_FILL;
        C_DONE: begin
          if (!FB_DDR3) bd_ready[fill_buf] <= 1'b1;
          if (FB_DDR3 && fill_band == BW'(NBANDS-1)) fb_complete <= 1'b1;   // R640: the frame is whole
          dbg_bands  <= dbg_bands + 16'd1;
          if (!(&bands_this)) bands_this <= bands_this + 8'd1;
          // R485: dbg_pixels is gone. It summed the five bands' 32-bit pixel
          // totals into a counter that reaches nothing -- Quartus deletes it,
          // and querying the fitted netlist for it returns zero registers --
          // while the five counters feeding it survived only because of the
          // `!= 0` test below. That test is a boolean, so the bands now keep a
          // flag and the 160 registers of adder go.
          if (bd_painted[fill_buf] && !(&painted_this))
            painted_this <= painted_this + 8'd1;                 // R452, R485
          fill_buf   <= (BUFW'(fill_buf) == BUFW'(NBUF-1)) ? '0 : fill_buf + BUFW'(1);
          fill_band  <= (fill_band == BW'(NBANDS-1)) ? '0 : fill_band + BW'(1);
          // R502: past the last band is the next frame's work.
          if (fill_band == BW'(NBANDS-1)) fill_frame <= ~fill_frame;
          cst <= C_IDLE;
        end
        default: cst <= C_IDLE;   // 3 bits, 7 states: the eighth must not latch
      endcase

      // A buffer is free again once the beam has passed its band.
      for (int i = 0; i < NBUF; i++)
        // R502: a band built for the NEXT frame is not this one's to free.
        if (bd_ready[i] && (scan_band_f > bd_band[i])) bd_ready[i] <= 1'b0;

      // Latched and restarted together, so the reported pair always describes
      // the SAME frame rather than one number from each side of a boundary.
      // R455: one count per quad HANDED TO THE FILL. A quad spanning six bands
      // is handed over six times, so this over dbg_quads is the replay factor.
      if (fl_in_valid && fl_in_ready && !(&fillpass_this))
        fillpass_this <= fillpass_this + 16'd1;

      // R640: with the framebuffer the band walk restarts when a NEW LIST
      // arrives; restarting it every frame_start is what redrew a held list.
      if (FB_DDR3 && swap) begin fb_complete <= 1'b0; fill_band <= '0; fill_buf <= '0; end

      if (frame_start) begin
        // R502: the frame being displayed advances, which makes the bands the
        // fill built ahead CURRENT rather than discarding them. Buffers still
        // holding the frame just finished are freed here -- that is what
        // `bd_ready <= '0` used to do for every buffer indiscriminately, head
        // start included.
        // R506: the frame being displayed advances with the fill, which is
        // what the re-phase guard tests against.
        disp_frame <= fill_frame;
        if (!FB_DDR3) fill_band <= '0;
        bd_ready <= '0;
        dbg_bands_done <= bands_this; bands_this <= 8'd0;
        dbg_bands_painted <= painted_this; painted_this <= 8'd0;   // R452
        dbg_fillpass <= fillpass_this; fillpass_this <= 16'd0;      // R455
        rdy_cyc <= 20'd0; rdy_run <= 1'b1;
        col_cyc <= 20'd0; col_run <= 1'b1;
      end
    end
  end

  wire _unused = &{1'b0, fl_line_case, 1'b0};

  assign dbg_oz0 = qo_oz0; assign dbg_oz1 = qo_oz1;   // R334
  assign dbg_oz2 = qo_oz2; assign dbg_oz3 = qo_oz3;

endmodule
