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
  parameter int unsigned BAND_H = 8,
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
  parameter int unsigned NBUF   = 4,

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
  parameter bit TWO_CLOCKS = 1'b1,
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
  input  logic [12:0] q_u0, q_v0, q_u1, q_v1,
  input  logic [12:0] q_u2, q_v2, q_u3, q_v3,
  input  logic [23:0] q_tex,
  input  logic        q_end,                // last quad of the frame

  // ---- scan-out, on the video clock
  input  logic        scan_clk,
  input  logic [9:0]  scan_x,
  input  logic [9:0]  scan_y,
  output logic [15:0] scan_col,
  output logic        scan_hit,             // 0 = nothing painted, show the 2D

  // ---- R275: the texture sheets, in SDRAM
  input  logic [TEX_AW:1] tex_base0, tex_base1,
  input  logic            tex_inval,
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
  output logic [31:0]     dbg_texpix, dbg_texhit, dbg_texmiss, dbg_texnz,
  output logic [15:0]     dbg_texlost,
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
  output logic [15:0] dbg_missed
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
  logic [23:0] qo_tex;
  // R275: the texel fetch's wires, declared here because two modules share them.
  logic        tex_req, tex_ack;
  logic [31:0] tex_state;
  logic [19:0] tex_u, tex_v;
  logic [3:0]  tex_texel;
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
  m2_quad_store #(.BAND_H(BAND_H), .NBANDS(NBANDS), .BW(BW), .SCR_H(SCR_H), .TINY(4)) u_store (
    .clk(clk), .rst_n(rst_n),
    .clear(qs_clear), .wbank(bank), .rbank(~bank),
    .in_valid(q_take),
    .in_x0(q_x0), .in_y0(q_y0), .in_x1(q_x1), .in_y1(q_y1),
    .in_x2(q_x2), .in_y2(q_y2), .in_x3(q_x3), .in_y3(q_y3),
    .in_col(q_col), .in_z(q_z), .in_moire(q_moire),
    .in_oz0(q_oz0), .in_oz1(q_oz1), .in_oz2(q_oz2), .in_oz3(q_oz3),   // R334
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
  logic        fl_span_valid, fl_span_ready, fl_span_moire;
  logic signed [15:0] fl_span_y, fl_span_x0, fl_span_x1;
  logic signed [31:0] fl_span_ooz;                          // R337: 1/z at the span start
  logic signed [15:0] fl_span_doozdx;
  logic [23:0] fl_span_col;
  logic signed [31:0] fl_span_u, fl_span_v;
  logic signed [15:0] fl_span_dudx, fl_span_dvdx;   // R286: 8.8
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

  // R327: 242 -> 194 when y, x0 and x1 narrowed to 16 bits.
  // R337: 194 -> 242, carrying 1/z (32) and its gradient (16) for the
  // perspective divide. The queue is MLAB since R332, so this is ALM and not
  // M10K -- which is the only reason it is affordable at 553/553 blocks.
  localparam int unsigned SQ_DW = 242;
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
  m2_fifo_m10k #(.DW(SQ_DW), .DEPTH(32), .RAMSTYLE("MLAB")) u_span_q (
    .clk(clk), .rst_n(rst_n),
    .push(fl_span_valid && sq_in_rdy), .din(sq_din),
    .pop(sq_qv && sq_rdy), .q(sq_q), .q_valid(sq_qv),
    .full(sq_full), .count(sq_cnt16), .dropped(sq_dropped)
  );
  assign sq_in_rdy = !sq_full;
  assign sq_busy   = sq_qv || (sq_cnt16 != 16'd0);

  // Unpacked, in the same order.
  // R337: ooz and its gradient sit between the coordinates and u; everything
  // from dudx down keeps the slice it had.
  wire signed [15:0] sq_y    = sq_q[241:226];
  wire signed [15:0] sq_x0   = sq_q[225:210];
  wire signed [15:0] sq_x1   = sq_q[209:194];
  wire signed [31:0] sq_ooz  = sq_q[193:162];
  wire signed [15:0] sq_doozdx = sq_q[161:146];
  wire signed [31:0] sq_u    = sq_q[145:114];
  wire signed [31:0] sq_v    = sq_q[113:82];
  wire signed [15:0] sq_dudx = sq_q[81:66];
  wire signed [15:0] sq_dvdx = sq_q[65:50];
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

  m2_raster_fill u_fill (
    .clk(clk), .rst_n(rst_n),
    .in_valid(fl_in_valid), .in_ready(fl_in_ready),
    // R327: no sign extension. m2_quad_store already saturates these to 13
    // bits and hands them over as 16, and the fill now takes them as 16.
    .in_x0(qo_x0), .in_y0(qo_y0),
    .in_x1(qo_x1), .in_y1(qo_y1),
    .in_x2(qo_x2), .in_y2(qo_y2),
    .in_x3(qo_x3), .in_y3(qo_y3),
    .in_col(qo_col), .in_moire(qo_moire),
    .in_u0(qo_u0), .in_v0(qo_v0), .in_u1(qo_u1), .in_v1(qo_v1),
    .in_u2(qo_u2), .in_v2(qo_v2), .in_u3(qo_u3), .in_v3(qo_v3),
    .in_oz0(qo_oz0), .in_oz1(qo_oz1), .in_oz2(qo_oz2), .in_oz3(qo_oz3),  // R337
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
  m2_span_tex #(.PIXSTEP(4)) u_spantex (
    .clk(clk), .rst_n(rst_n),
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
    .tx_req(tex_req), .tx_ack(tex_ack), .tx_tex(tex_state),
    .tx_u(tex_u), .tx_v(tex_v), .tx_texel(tex_texel),
    .dbg_texpix(dbg_texpix), .dbg_texnz(dbg_texnz),
    .dbg_hot(dbg_walk_hot), .dbg_hotcyc(dbg_walk_hotcyc)   // R436
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

  // R318: the request crosses to clk_mem here. m2_texel's `ack` is one cycle,
  // which at 100 MHz is 10 ns and invisible to a 50 MHz sampler half the time --
  // and a missed acknowledge hangs the span walk in T_FETCH until its 511-cycle
  // timeout. m2_texel_x2 holds it up until the request drops, exactly as
  // m2_sdram_x2 does for the memory ports.
  logic        txf_req, txf_ack, txf_rdy;   // R474
  logic [31:0] txf_tex;
  logic [19:0] txf_u, txf_v;
  logic [3:0]  txf_texel;

  m2_texel_x2 u_texel_x2 (
    .clk_fast(clk_mem), .rst_n(rst_n),
    .s_req(tex_req), .s_ack(tex_ack), .s_tex(tex_state),
    .s_u(tex_u), .s_v(tex_v), .s_texel(tex_texel),
    .f_req(txf_req), .f_rdy(txf_rdy), .f_ack(txf_ack), .f_tex(txf_tex),
    .f_u(txf_u), .f_v(txf_v), .f_texel(txf_texel)
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
  m2_texel #(.AW(TEX_AW), .IDX_BITS(12)) u_texel (
    .clk(clk_mem), .rst_n(rst_n),
    .base_s0(tex_base0), .base_s1(tex_base1),
    .req(txf_req), .rdy(txf_rdy), .ack(txf_ack), .tex(txf_tex),
    .u(txf_u), .v(txf_v), .texel(txf_texel),
    .m_req(tex_m_req), .m_addr(tex_m_addr), .m_ack(tex_m_ack), .m_data(tex_m_data),
    // R480: the second SDRAM port, so two fills can be in flight.
    .m2_en(tex_m2_en), .m2_req(tex_m2_req), .m2_addr(tex_m2_addr),
    .m2_ack(tex_m2_ack), .m2_data(tex_m2_data),
    .inval(tex_sweep),
    .dbg_hits(dbg_texhit), .dbg_misses(dbg_texmiss), .dbg_lost(dbg_texlost),
    .dbg_sweeps(dbg_texsweep)
  );

  // RGB888 to RGB565 on the way in, as the reference does: the colour is
  // already quantised upstream, so this costs less than it looks.
  wire [15:0] span_565 = {tx_span_col[23:19], tx_span_col[15:10], tx_span_col[7:3]};

  // --------------------------------------------------------- band buffers
  logic [NBUF-1:0]       bd_clear_req, bd_clear_busy;
  logic [NBUF-1:0]       bd_span_valid, bd_span_ready;
  logic [NBUF-1:0][15:0] bd_rd_col;
  logic [NBUF-1:0]       bd_rd_hit;
  logic [NBUF-1:0]       bd_painted;   // R485: a flag per band, not a count
  logic signed [15:0]    bd_y0 [NBUF];
  logic [BW-1:0]         bd_band [NBUF];
  logic [NBUF-1:0]       bd_ready;          // holds a finished band
  // R502: WHICH FRAME EACH FINISHED BAND BELONGS TO.
  //
  // The fill wraps past band 47 and starts the NEXT frame's low bands while
  // the beam is still finishing this one -- that is what dbg_bands_done
  // reading 52 against NBANDS=48 has been reporting all along. Every one of
  // them was then thrown away, not by frame_start but by the release below:
  // `scan_band_f > bd_band[i]` frees a band the moment the beam is past it,
  // and the beam is past band 0 for the whole rest of the frame. So the four
  // bands of head start the fill builds each frame were discarded within a
  // cycle of being finished, and the head start was rebuilt from nothing in
  // the 40 lines of blanking -- five band-times for five buffers, no slack,
  // and any band that overran left the fill behind for the entire frame
  // because C_IDLE waits on buffer release and can never get more than NBUF
  // ahead again.
  //
  // One bit per buffer fixes it: a band built for the next frame is not the
  // current frame's to release or to display.
  // R503: A FLAG, NOT A FRAME NUMBER. R502 tagged each buffer with fill_frame
  // and freed those "not of the new frame" at frame_start. When the fill has
  // NOT wrapped past band 47 -- which is most of the time, because it runs
  // late, which is the whole problem -- fill_frame still equals disp_frame,
  // so that test frees NOTHING while every buffer holds the finished frame's
  // bands. Nothing is released during blanking either (scan_band_rel is
  // clamped to zero there), so the fill entered the frame with no free buffer
  // at all and starved. Four builds: two black, one stuck on the red bars,
  // one frozen on frame 1.
  //
  // `bd_ahead` is set only when the fill has already wrapped past the band
  // being displayed, so it means exactly "this band is for the NEXT frame"
  // and is unambiguous when there has been no wrap -- then no buffer is ahead
  // and frame_start frees them all, which is precisely the old behaviour.
  logic [NBUF-1:0]       bd_ahead;
  logic                  fill_frame, disp_frame;

  genvar b;
  generate
    for (b = 0; b < NBUF; b++) begin : g_band
      m2_raster_band #(.WIDTH(SCR_W), .HEIGHT(BAND_H)) u_band (
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
        .dbg_spans(), .dbg_dropped(), .dbg_painted(bd_painted[b])
      );
    end
  endgenerate

  // The buffer being filled, and the one the beam is reading.
  logic [BUFW-1:0] fill_buf;
  logic [NBUF-1:0] bd_settled;
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
  logic [NBUF-1:0] frm_s2;
  logic            dfr_s2;   // R502
  generate
    if (TWO_CLOCKS) begin : g_rdy_sync
      logic [NBUF-1:0] rdy_s1;
      logic [NBUF-1:0] frm_s1;
      logic            dfr_s1;
      logic [BW-1:0]   band_s1 [NBUF];
      always_ff @(posedge scan_clk or negedge rst_n) begin
        if (!rst_n) begin
          rdy_s1 <= '0; rdy_s2 <= '0;
          frm_s1 <= '0; frm_s2 <= '0; dfr_s1 <= 1'b0; dfr_s2 <= 1'b0;
          for (int i = 0; i < NBUF; i++) begin band_s1[i] <= '0; band_s2[i] <= '0; end
        end else begin
          rdy_s1 <= bd_ready; rdy_s2 <= rdy_s1;
          frm_s1 <= bd_ahead; frm_s2 <= frm_s1;
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
        frm_s2 = bd_ahead;                           // R503
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
          if (rdy_s2[i] && !frm_s2[i] && (band_s2[i] == scan_band)) any_rdy = 1'b1;
        if (!any_rdy) dbg_missed <= dbg_missed + 16'd1;
      end
    end
  end

  always_comb begin
    scan_col = 16'd0;
    scan_hit = 1'b0;
    for (int i = 0; i < NBUF; i++)
      if (rdy_s2[i] && !frm_s2[i] && (band_s2[i] == scan_band)) begin
        scan_col = bd_rd_col[i];
        scan_hit = bd_rd_hit[i];
      end
  end

  assign tx_span_ready = bd_span_ready[fill_buf];
  always_comb begin
    bd_span_valid = '0;
    bd_span_valid[fill_buf] = tx_span_valid;
  end

  // ------------------------------------------------------------ sequencing
  typedef enum logic [1:0] { P_COLLECT, P_SORT, P_SORTW, P_READY } pstate_t;
  typedef enum logic [2:0] { C_IDLE, C_CLR, C_CLRW, C_REPLAY, C_FILL, C_FILLW, C_DONE } cstate_t;
  pstate_t pst;
  cstate_t cst;

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
  wire swap = frame_start && (pst == P_READY);
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
  assign qs_out_ready    = (cst == C_FILL) && fl_in_ready;
  assign fl_in_valid     = (cst == C_FILL) && qs_out_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pst <= P_COLLECT; cst <= C_IDLE;
      bank <= 1'b0; dvalid <= 1'b0;
      fill_band <= '0; fill_buf <= '0; bd_ready <= '0;
      bd_ahead <= '0; fill_frame <= 1'b0; disp_frame <= 1'b0;   // R502
      bd_clear_req <= '0; dbg_bands <= 16'd0;
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
        P_READY:   if (frame_start) begin pst <= P_COLLECT; bank <= ~bank; dvalid <= 1'b1;
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
        C_IDLE: if (dvalid && !bd_ready[fill_buf] && bd_settled[fill_buf]) begin
          bd_y0[fill_buf]   <= 16'sd0 + 16'(fill_band) * 16'(BAND_H);
          bd_band[fill_buf] <= fill_band;
          bd_clear_req[fill_buf] <= 1'b1;
          cst <= C_CLR;
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
                   && tx_span_ready) cst <= C_DONE;   // and the band has painted the last one
        end
        C_FILLW: if (fl_quad_done) cst <= C_FILL;
        C_DONE: begin
          bd_ready[fill_buf] <= 1'b1;
          bd_ahead[fill_buf] <= (fill_frame != disp_frame);   // R502/R503
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
        if (bd_ready[i] && !bd_ahead[i]
                        && (scan_band_f > bd_band[i])) bd_ready[i] <= 1'b0;

      // Latched and restarted together, so the reported pair always describes
      // the SAME frame rather than one number from each side of a boundary.
      // R455: one count per quad HANDED TO THE FILL. A quad spanning six bands
      // is handed over six times, so this over dbg_quads is the replay factor.
      if (fl_in_valid && fl_in_ready && !(&fillpass_this))
        fillpass_this <= fillpass_this + 16'd1;

      if (frame_start) begin
        // R502: the frame being displayed advances, which makes the bands the
        // fill built ahead CURRENT rather than discarding them. Buffers still
        // holding the frame just finished are freed here -- that is what
        // `bd_ready <= '0` used to do for every buffer indiscriminately, head
        // start included.
        // R503: keep exactly the bands built AHEAD and free the rest -- with
        // no wrap nothing is ahead and every buffer is freed, which is what
        // the old unconditional clear did.
        disp_frame <= fill_frame;
        for (int i = 0; i < NBUF; i++) begin
          bd_ready[i] <= bd_ahead[i];
          bd_ahead[i] <= 1'b0;
        end
        fill_band <= '0;
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
