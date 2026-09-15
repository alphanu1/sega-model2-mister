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
  // R355: THE DDR3 FRAMEBUFFER, OFF BY DEFAULT.
  //
  // At 0 nothing below is instantiated and this file behaves exactly as it
  // always has -- band buffers, beam-paced fill, the lot. The DDR3 path is
  // committed dormant so the change that TURNS IT ON is a small diff against a
  // known-good tree, and so a bisect has somewhere to stand between "the
  // plumbing exists" and "the picture comes from it".
  //
  // What it buys when it is 1 (R340): the fill stops re-rendering a held list --
  // measured at 1.98 video frames per list, so very nearly half its work -- and
  // stops being beam-paced, because a framebuffer has somewhere to keep the
  // result. The band buffers' 24 M10K come back with it.
  parameter bit FB_DDR3 = 1'b0,
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
  output logic [31:0]     dbg_texpix, dbg_texhit, dbg_texmiss, dbg_texnz,
  output logic [15:0]     dbg_texlost,
  output logic [15:0] dbg_oz0, dbg_oz1, dbg_oz2, dbg_oz3,   // R334
  output logic [15:0] dbg_texsweep,

  output logic [15:0] dbg_quads,
  output logic [15:0] dbg_dropped,
  output logic [15:0] dbg_tiny,            // R216
  output logic [15:0] dbg_bands,
  output logic [31:0] dbg_pixels,       // R358: from the bands, or from the writer

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

  // ---- R355: the DDR3 side, arbitrated here and driven at the top level
  output logic        fb_req,
  output logic        fb_we,
  output logic [24:0] fb_addr,
  output logic [7:0]  fb_blen,
  output logic [63:0] fb_din,
  output logic [7:0]  fb_be,
  input  logic        fb_wnext,
  input  logic        fb_rvalid,
  input  logic        fb_ack,
  input  logic [63:0] fb_dout,
  output logic [31:0] dbg_fb_lines,
  output logic [31:0] dbg_fb_late,
  // R359: frames PUBLISHED, and lists that arrived before the last one drew.
  // If drop climbs with pub flat the fill is not keeping up and the picture is
  // frozen rather than torn -- a failure the band path could not even express.
  output logic [15:0] dbg_fb_pub,
  output logic [15:0] dbg_fb_drop
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

  // R327: 242 -> 194. y, x0 and x1 were 32 bits each for a 496x384 screen;
  // they are 16 now, which is 48 bits off every entry in this queue.
  localparam int unsigned SQ_DW = 194;
  logic [SQ_DW-1:0] sq_din, sq_q;
  logic             sq_in_rdy, sq_qv, sq_rdy, sq_busy, sq_full;
  logic [15:0]      sq_cnt16;
  logic [31:0]      sq_dropped;   // must stay zero: a dropped span is a hole

  // Backpressure, NOT a drop: m2_fifo_m10k's `full` retires the TGP's pushes
  // silently, and a silently dropped span is a hole in the picture.
  assign fl_span_ready = sq_in_rdy;

  assign sq_din = { fl_span_y, fl_span_x0, fl_span_x1,
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
  // Only the top three fields moved: everything from u down keeps its slice.
  wire signed [15:0] sq_y    = sq_q[193:178];
  wire signed [15:0] sq_x0   = sq_q[177:162];
  wire signed [15:0] sq_x1   = sq_q[161:146];
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
    .in_tex(qo_tex),
    .view_x1(16'sd0), .view_x2(16'(SCR_W) - 16'sd1),
    .view_y1(band_y1), .view_y2(band_y2),
    .span_valid(fl_span_valid), .span_ready(fl_span_ready),
    .span_y(fl_span_y), .span_x0(fl_span_x0), .span_x1(fl_span_x1),
    .span_col(fl_span_col), .span_moire(fl_span_moire),
    .span_u(fl_span_u), .span_v(fl_span_v),
    .span_dudx(fl_span_dudx), .span_dvdx(fl_span_dvdx),
    .span_tex(fl_span_tex), .span_tex_en(fl_span_tex_en),
    .quad_done(fl_quad_done), .line_case(fl_line_case)
  );

  // ------------------------------------------------- R275: the texture walk
  // R322/R324: EIGHT PIXELS PER TEXEL FETCH, up from two.
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
  m2_span_tex #(.PIXSTEP(8)) u_spantex (
    .clk(clk), .rst_n(rst_n),
    .in_valid(sq_qv), .in_ready(sq_rdy), .busy(spantex_busy),
    // m2_span_tex still carries these as 32; the fill and the queue are what
    // this change narrows.
    .in_y(32'(sq_y)), .in_x0(32'(sq_x0)), .in_x1(32'(sq_x1)),
    .in_col(sq_col), .in_moire(sq_moire),
    .in_u(sq_u), .in_v(sq_v),
    .in_dudx(sq_dudx), .in_dvdx(sq_dvdx),
    .in_tex(sq_tex), .in_tex_en(sq_tex_en),
    .out_valid(tx_span_valid), .out_ready(tx_span_ready),
    .out_y(tx_span_y), .out_x0(tx_span_x0), .out_x1(tx_span_x1),
    .out_col(tx_span_col), .out_moire(tx_span_moire),
    .tx_req(tex_req), .tx_ack(tex_ack), .tx_tex(tex_state),
    .tx_u(tex_u), .tx_v(tex_v), .tx_texel(tex_texel),
    .dbg_texpix(dbg_texpix), .dbg_texnz(dbg_texnz)
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
  logic        txf_req, txf_ack;
  logic [31:0] txf_tex;
  logic [19:0] txf_u, txf_v;
  logic [3:0]  txf_texel;

  m2_texel_x2 u_texel_x2 (
    .clk_fast(clk_mem), .rst_n(rst_n),
    .s_req(tex_req), .s_ack(tex_ack), .s_tex(tex_state),
    .s_u(tex_u), .s_v(tex_v), .s_texel(tex_texel),
    .f_req(txf_req), .f_ack(txf_ack), .f_tex(txf_tex),
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
  m2_texel #(.AW(TEX_AW), .IDX_BITS(11)) u_texel (
    .clk(clk_mem), .rst_n(rst_n),
    .base_s0(tex_base0), .base_s1(tex_base1),
    .req(txf_req), .ack(txf_ack), .tex(txf_tex),
    .u(txf_u), .v(txf_v), .texel(txf_texel),
    .m_req(tex_m_req), .m_addr(tex_m_addr), .m_ack(tex_m_ack), .m_data(tex_m_data),
    .inval(tex_sweep),
    .dbg_hits(dbg_texhit), .dbg_misses(dbg_texmiss), .dbg_lost(dbg_texlost),
    .dbg_sweeps(dbg_texsweep)
  );

  // RGB888 to RGB565 on the way in, as the reference does: the colour is
  // already quantised upstream, so this costs less than it looks.
  wire [15:0] span_565 = {tx_span_col[23:19], tx_span_col[15:10], tx_span_col[7:3]};

  // ------------------------------------------------ R355: the DDR3 path
  //
  // Dormant at FB_DDR3 = 0: the generate below instantiates nothing, so this
  // costs no ALM and no M10K until the change that turns it on.
  //
  // WHICH BUFFER IS WHICH. The fill writes the one the scanout is not showing,
  // swapped at frame_start -- the same discipline the quad store already uses
  // for its two banks (R213). `fb_draw` is the one being drawn into.
  // A new list is ready the moment a frame starts with the collect bank sorted.
  // Declared here because the framebuffer swap below is driven by it too.
  wire swap = frame_start && (pst == P_READY);

  // R359: THE SWAP IS A COMPLETION, NOT A CLOCK TICK.
  //
  // Flipping `fb_draw` every frame_start publishes whatever the fill happened
  // to have finished, which with a band-paced fill was all anyone could do --
  // the beam was going to show the bands regardless. A framebuffer removes that
  // constraint and the deadline with it: the display holds the last COMPLETE
  // frame, and a draw that runs long gets the next frame to finish rather than
  // being shown half done. This is the second half of what the framebuffer buys
  // and the reason R200's missing top of the frame stops being a deadline
  // problem at all.
  //
  // `fb_complete` is raised when the fill has walked every band. `fb_show`
  // takes `fb_draw` at the next frame_start -- a video-frame boundary, so the
  // reader never changes buffer part way down a line -- and `fb_draw` moves to
  // the other buffer only when a new list arrives AND the old one published.
  // If a new list arrives while the fill is still going, the partial frame is
  // abandoned in place: same buffer, cleared again, nothing shown from it.
  logic fb_draw, fb_show, fb_shown_ok, fb_complete, fb_busy;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fb_draw <= 1'b0; fb_show <= 1'b1; fb_shown_ok <= 1'b0; fb_busy <= 1'b0;
      dbg_fb_pub <= 16'd0; dbg_fb_drop <= 16'd0;
    end else begin
      if (frame_start && fb_complete) begin
        fb_show     <= fb_draw;
        fb_shown_ok <= 1'b1;       // until the first complete frame, show nothing
      end
      // R360: AND THE FIRST SWAP IS NEITHER. At reset nothing has been drawn
      // and nothing is in flight, so the first list to arrive is not a frame
      // published and not a list dropped. `fb_busy` is the difference: a list
      // is being drawn. Without it the very first swap counted as a drop, and
      // a counter that is wrong by one at startup is a counter nobody trusts.
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
  logic        fb_rd_hit, fbr_hit;
  // R356: THE WRITER'S OWN READY, not the shared span net. Connecting
  // m2_fb_write's in_ready straight to tx_span_ready gave that net two drivers
  // -- the band buffers and the writer -- which lint could not see while
  // FB_DDR3 was 0, because the generate built nothing. It would have appeared
  // only in the build that turned the framebuffer on.
  logic        fbw_ready;
  logic [31:0] fbw_pixels;   // R358: pixels the writer painted, to compare with the bands'
  logic        fb_clear_req, fb_clear_busy;

  // R359: raised when a NEW LIST arrives, not every frame_start. Clearing on
  // every frame would wipe a drawing that is still going, and there is no point
  // clearing a buffer that is about to be redrawn with the same list.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                 fb_clear_req <= 1'b0;
    else if (swap)              fb_clear_req <= 1'b1;
    else if (fb_clear_busy)     fb_clear_req <= 1'b0;
  end

  generate
    if (FB_DDR3) begin : g_fb
      logic        w_req, w_we, w_wnext, w_ack;
      logic [24:0] w_addr;
      logic [7:0]  w_blen, w_be;
      logic [63:0] w_din;
      logic        r_req, r_we, r_rvalid, r_ack;
      logic [24:0] r_addr;
      logic [7:0]  r_blen;

      // Spans in, pixels to DDR3. The span walk hands over exactly what it
      // handed the band buffers; only the destination changes.
      m2_fb_write #(.SCR_W(SCR_W), .SCR_H(SCR_H), .STRIDE(512)) u_fbw (
        .clk(clk), .rst_n(rst_n),
        .fb_sel(fb_draw),
        // R357: clear the buffer about to be drawn into, once a frame. The band
        // buffers cleared per band; a framebuffer that is never cleared keeps
        // the previous frame wherever this one paints nothing.
        .clear_req(fb_clear_req), .clear_busy(fb_clear_busy),
        .in_valid(tx_span_valid && FB_DDR3), .in_ready(fbw_ready),
        .in_y(tx_span_y[15:0]), .in_x0(tx_span_x0[15:0]), .in_x1(tx_span_x1[15:0]),
        .in_col(tx_span_col), .in_painted(1'b1),
        .m_req(w_req), .m_we(w_we), .m_addr(w_addr), .m_blen(w_blen),
        .m_din(w_din), .m_be(w_be), .m_wnext(w_wnext), .m_ack(w_ack),
        .dbg_spans(), .dbg_pixels(fbw_pixels)
      );

      // A line ahead of the beam, one burst. The line the mixer is about to
      // need is scan_y + 1; asking on the line BEFORE is the whole reason the
      // ~500 ns worst case (R351) never reaches the picture.
      //
      // **THIS SAMPLES scan_y ON clk AND IS ONLY SAFE WHILE TWO_CLOCKS = 0.**
      // Today they are the same net -- Model2.sv passes clk_sys to both -- so
      // there is no crossing and no synchroniser is wanted; adding one would be
      // the invented-hazard this module's header warns about at length. But the
      // header also says TWO_CLOCKS "must be 1 the moment the video moves to the
      // memory clock", and on that day this becomes a genuine unsynchronised
      // crossing of a free-running counter. It then needs what the band logic
      // already does below: gray-code scan_y in the video domain, two flops into
      // clk, and derive the pulse from the synchronised value.
      logic [9:0] scan_y_q;
      logic       line_pulse;
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin scan_y_q <= 10'd0; line_pulse <= 1'b0; end
        else begin
          scan_y_q   <= scan_y;
          line_pulse <= (scan_y != scan_y_q);
        end
      end

      m2_fb_read #(.WIDTH(SCR_W), .STRIDE(512)) u_fbr (
        .clk(clk), .rd_clk(scan_clk), .rst_n(rst_n),
        .fb_sel(fb_show),                        // R359: the last COMPLETE frame
        // R360: THE LINE AHEAD WRAPS. `scan_y + 1` runs on through the forty
        // blanking lines, so the reader fetched lines 385..424 -- outside the
        // picture, from DDR3 the clear never touches -- and NEVER FETCHED LINE
        // 0. Line 0 therefore showed whatever the last blanking fetch left in
        // the buffer: 496 painted pixels of uninitialised memory, every frame.
        // Clamping instead re-fetches line 0 through the blanking, so it is
        // fresh and paid for when the beam arrives.
        .line_req(line_pulse),
        .line_y((scan_y >= 10'(SCR_H - 1)) ? 9'd0 : 9'(scan_y + 10'd1)),
        .line_ready(),
        .m_req(r_req), .m_we(r_we), .m_addr(r_addr), .m_blen(r_blen),
        .m_rvalid(r_rvalid), .m_dout(fb_dout), .m_ack(r_ack),
        .rd_parity(scan_y[0]), .rd_x(scan_x[$clog2(SCR_W)-1:0]),
        .rd_col(fb_rd_col), .rd_hit(fbr_hit),
        .dbg_lines(dbg_fb_lines), .dbg_late(dbg_fb_late)
      );

      // R359: NOTHING IS SHOWN UNTIL A FRAME HAS BEEN DRAWN. Both buffers hold
      // whatever DDR3 powered up with, and bit 24 of that garbage is the
      // painted flag -- so without this the first frames scatter random 3D
      // pixels over the tilemap. Two flops because fb_shown_ok is in the fill
      // domain; it rises once and never falls.
      logic sok_s1, sok_s2;
      always_ff @(posedge scan_clk or negedge rst_n) begin
        if (!rst_n) begin sok_s1 <= 1'b0; sok_s2 <= 1'b0; end
        else begin sok_s1 <= fb_shown_ok; sok_s2 <= sok_s1; end
      end
      assign fb_rd_hit = fbr_hit && sok_s2;

      // The reader wins: it has the beam deadline and the writer has not.
      m2_ddr3_arb u_arb (
        .clk(clk), .rst_n(rst_n),
        .a_req(r_req), .a_we(r_we), .a_addr(r_addr), .a_blen(r_blen),
        .a_din(64'd0), .a_be(8'hFF),
        .a_wnext(), .a_rvalid(r_rvalid), .a_ack(r_ack),
        .b_req(w_req), .b_we(w_we), .b_addr(w_addr), .b_blen(w_blen),
        .b_din(w_din), .b_be(w_be),
        .b_wnext(w_wnext), .b_rvalid(), .b_ack(w_ack),
        .m_req(fb_req), .m_we(fb_we), .m_addr(fb_addr), .m_blen(fb_blen),
        .m_din(fb_din), .m_be(fb_be),
        .m_wnext(fb_wnext), .m_rvalid(fb_rvalid), .m_ack(fb_ack),
        .m_dout(fb_dout), .dout(),
        .dbg_a_waits(), .dbg_b_waits()
      );
    end else begin : g_nofb
      assign fb_req = 1'b0; assign fb_we = 1'b0; assign fb_addr = 25'd0;
      assign fb_blen = 8'd0; assign fb_din = 64'd0; assign fb_be = 8'd0;
      assign fb_rd_col = 24'd0; assign fb_rd_hit = 1'b0; assign fbr_hit = 1'b0;
      assign fbw_ready = 1'b0;   // the bands own the span handshake at FB_DDR3=0
      assign fb_clear_busy = 1'b0;
      assign dbg_fb_lines = 32'd0; assign dbg_fb_late = 32'd0;
      assign fbw_pixels = 32'd0;
    end
  endgenerate

  // --------------------------------------------------------- band buffers
  logic [NBUF-1:0]       bd_clear_req, bd_clear_busy;
  logic [NBUF-1:0]       bd_span_valid, bd_span_ready;
  logic [NBUF-1:0][15:0] bd_rd_col;
  logic [NBUF-1:0]       bd_rd_hit;
  logic [NBUF-1:0][31:0] bd_pixels;
  logic signed [15:0]    bd_y0 [NBUF];
  logic [BW-1:0]         bd_band [NBUF];
  logic [NBUF-1:0]       bd_ready;          // holds a finished band

  genvar b;
  generate
    // R358: not built when the framebuffer is on -- this is the 24 M10K and
    // 223 ALM the change hands back. Their outputs still need driving, because
    // the sequencer and the mixer reference them at either setting.
    if (FB_DDR3) begin : g_noband
      assign bd_rd_col    = '0;
      assign bd_rd_hit    = '0;
      assign bd_pixels    = '0;
      assign bd_span_ready = '0;
      assign bd_clear_busy = '0;
    end
    for (b = 0; b < (FB_DDR3 ? 0 : NBUF); b++) begin : g_band
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
        .dbg_spans(), .dbg_dropped(), .dbg_pixels(bd_pixels[b])
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
  generate
    if (TWO_CLOCKS) begin : g_rdy_sync
      logic [NBUF-1:0] rdy_s1;
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
    if (!rst_n) begin dbg_missed <= 16'd0; scan_x_d <= 10'd0; end
    else begin
      scan_x_d <= scan_x;
      if (scan_x == 10'd0 && scan_x_d != 10'd0 && scan_y < 10'(SCR_H)) begin
        automatic logic any_rdy = 1'b0;
        for (int i = 0; i < NBUF; i++)
          if (rdy_s2[i] && (band_s2[i] == scan_band)) any_rdy = 1'b1;
        if (!any_rdy && !(&dbg_missed)) dbg_missed <= dbg_missed + 16'd1;
      end
    end
  end

  // R356: WHERE THE MIXER'S PIXEL COMES FROM.
  //
  // With the framebuffer there is no band to choose and no readiness to test:
  // the line is already in the line buffer, fetched while the beam drew the
  // line before. All of `rdy_s2`, `band_s2` and `scan_band` exist to answer
  // "has the fill got here yet", which a framebuffer makes meaningless -- and
  // that question IS the beam deadline the whole change is removing.
  //
  // RGB888 to RGB565 on the way out, as the band buffers store it.
  wire [15:0] fb_565 = {fb_rd_col[23:19], fb_rd_col[15:10], fb_rd_col[7:3]};

  always_comb begin
    if (FB_DDR3) begin
      scan_col = fb_565;
      scan_hit = fb_rd_hit;
    end else begin
      scan_col = 16'd0;
      scan_hit = 1'b0;
      for (int i = 0; i < NBUF; i++)
        if (rdy_s2[i] && (band_s2[i] == scan_band)) begin
          scan_col = bd_rd_col[i];
          scan_hit = bd_rd_hit[i];
        end
    end
  end

  // R356: the span walk feeds the framebuffer or the bands, never both.
  assign tx_span_ready = FB_DDR3 ? fbw_ready : bd_span_ready[fill_buf];

  // R358: the pixel count has to keep meaning the same thing across the
  // change, or the before/after comparison says nothing. The bands add each
  // band's total at C_DONE; the writer counts as it paints.
  logic [31:0] bd_dbg_pixels;
  assign dbg_pixels = FB_DDR3 ? fbw_pixels : bd_dbg_pixels;
  always_comb begin
    bd_span_valid = '0;
    if (!FB_DDR3) bd_span_valid[fill_buf] = tx_span_valid;
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
  logic  [7:0] bands_this;

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
      fill_band <= '0; fill_buf <= '0; bd_ready <= '0; fb_complete <= 1'b0;
      bd_clear_req <= '0; dbg_bands <= 16'd0; bd_dbg_pixels <= 32'd0;
      dbg_ready_cyc <= 16'd0; dbg_bands_done <= 8'd0;
      dbg_late_frames <= 8'd0; dbg_qend_frames <= 8'd0;
      dbg_collect_cyc <= 16'd0; col_cyc <= 20'd0; col_run <= 1'b0;
      dbg_hold <= 8'd0; hold_cnt <= 8'd0;
      rdy_cyc <= 20'd0; rdy_run <= 1'b0; bands_this <= 8'd0;
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
        // R358: WITH A FRAMEBUFFER THERE IS NOTHING TO WAIT FOR.
        //
        // `!bd_ready[fill_buf] && bd_settled[fill_buf]` is the beam pacing: it
        // holds the fill until the beam has passed a band and released its
        // buffer, which is why the fill can run at most NBUF bands ahead and
        // why a slow frame loses the bottom of the screen. A framebuffer has
        // somewhere to put the result, so the only thing worth waiting for is
        // the once-a-frame clear finishing (R357) -- drawing into a buffer
        // being wiped would lose whatever landed first.
        // R359: AND STOP WHEN THE LIST IS DRAWN. The band path had to keep
        // going: fill_band restarted at every frame_start and the same list was
        // re-rendered, pixel for pixel, 1.98 times per list on the board --
        // because the beam needed the bands again. A framebuffer keeps the
        // result, so `fb_complete` holds the fill off until a new list arrives.
        C_IDLE: if (FB_DDR3 ? (dvalid && !fb_complete && !fb_clear_req && !fb_clear_busy)
                            : (dvalid && !bd_ready[fill_buf] && bd_settled[fill_buf])) begin
          bd_y0[fill_buf]   <= 16'sd0 + 16'(fill_band) * 16'(BAND_H);
          bd_band[fill_buf] <= fill_band;
          if (!FB_DDR3) bd_clear_req[fill_buf] <= 1'b1;
          cst <= FB_DDR3 ? C_REPLAY : C_CLR;
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
          // Marking a buffer ready is how the beam is told it may show this
          // band. There is no such handshake with a framebuffer.
          if (!FB_DDR3) bd_ready[fill_buf] <= 1'b1;
          dbg_bands  <= dbg_bands + 16'd1;
          if (!(&bands_this)) bands_this <= bands_this + 8'd1;
          bd_dbg_pixels <= bd_dbg_pixels + bd_pixels[fill_buf];
          fill_buf   <= (BUFW'(fill_buf) == BUFW'(NBUF-1)) ? '0 : fill_buf + BUFW'(1);
          fill_band  <= (fill_band == BW'(NBANDS-1)) ? '0 : fill_band + BW'(1);
          if (fill_band == BW'(NBANDS-1)) fb_complete <= 1'b1;   // R359: the frame is whole
          cst <= C_IDLE;
        end
        default: cst <= C_IDLE;   // 3 bits, 7 states: the eighth must not latch
      endcase

      // A buffer is free again once the beam has passed its band.
      for (int i = 0; i < NBUF; i++)
        if (bd_ready[i] && (scan_band_f > bd_band[i])) bd_ready[i] <= 1'b0;

      // Latched and restarted together, so the reported pair always describes
      // the SAME frame rather than one number from each side of a boundary.
      // R359: the band walk restarts when a new list arrives. Restarting it at
      // every frame_start is what made the fill redraw a held list.
      if (swap) fb_complete <= 1'b0;
      if (FB_DDR3 ? swap : frame_start) fill_band <= '0;
      if (frame_start) begin
        bd_ready <= '0;
        dbg_bands_done <= bands_this; bands_this <= 8'd0;
        rdy_cyc <= 20'd0; rdy_run <= 1'b1;
        col_cyc <= 20'd0; col_run <= 1'b1;
      end
    end
  end

  wire _unused = &{1'b0, fl_line_case, 1'b0};

  assign dbg_oz0 = qo_oz0; assign dbg_oz1 = qo_oz1;   // R334
  assign dbg_oz2 = qo_oz2; assign dbg_oz3 = qo_oz3;

endmodule
