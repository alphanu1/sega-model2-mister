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
  parameter bit TWO_CLOCKS = 1'b1
) (
  input  logic        clk,
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
  input  logic        q_end,                // last quad of the frame

  // ---- scan-out, on the video clock
  input  logic        scan_clk,
  input  logic [9:0]  scan_x,
  input  logic [9:0]  scan_y,
  output logic [15:0] scan_col,
  output logic        scan_hit,             // 0 = nothing painted, show the 2D

  output logic [15:0] dbg_quads,
  output logic [15:0] dbg_dropped,
  output logic [15:0] dbg_bands,
  output logic [31:0] dbg_pixels,

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
  logic        qo_moire;

  assign q_ready = 1'b1;      // the store absorbs or drops; it never backpressures

  // One two-bank store: collect into `bank`, replay `~bank` (R213 shares the
  // key and scratch index between the banks, ~8 M10K blocks over two
  // instances).
  m2_quad_store #(.BAND_H(BAND_H), .NBANDS(NBANDS), .BW(BW), .SCR_H(SCR_H)) u_store (
    .clk(clk), .rst_n(rst_n),
    .clear(qs_clear), .wbank(bank), .rbank(~bank),
    .in_valid(q_valid),
    .in_x0(q_x0), .in_y0(q_y0), .in_x1(q_x1), .in_y1(q_y1),
    .in_x2(q_x2), .in_y2(q_y2), .in_x3(q_x3), .in_y3(q_y3),
    .in_col(q_col), .in_z(q_z), .in_moire(q_moire),
    .sort_start(qs_sort_start), .sort_busy(qs_sort_busy),
    .replay_band(qs_band),
    .replay_start(qs_replay_start), .replay_busy(qs_replay_busy),
    .out_ready(qs_out_ready), .out_valid(qs_out_valid),
    .out_x0(qo_x0), .out_y0(qo_y0), .out_x1(qo_x1), .out_y1(qo_y1),
    .out_x2(qo_x2), .out_y2(qo_y2), .out_x3(qo_x3), .out_y3(qo_y3),
    .out_col(qo_col), .out_moire(qo_moire),
    .dbg_count(dbg_quads), .dbg_dropped(dbg_dropped)
  );

  // ------------------------------------------------------------- the filler
  logic        fl_in_valid, fl_in_ready, fl_quad_done, fl_line_case;
  logic        fl_span_valid, fl_span_ready, fl_span_moire;
  logic signed [31:0] fl_span_y, fl_span_x0, fl_span_x1;
  logic [23:0] fl_span_col;

  // The band being filled IS the band the store replays. One register, two
  // consumers -- leaving qs_band undriven is a silent "always band 0".
  logic [BW-1:0] fill_band;
  assign qs_band = fill_band;
  wire signed [31:0] band_y1 = 32'(fill_band) * 32'(BAND_H);
  wire signed [31:0] band_y2 = band_y1 + 32'(BAND_H) - 32'sd1;

  m2_raster_fill u_fill (
    .clk(clk), .rst_n(rst_n),
    .in_valid(fl_in_valid), .in_ready(fl_in_ready),
    .in_x0({{16{qo_x0[15]}}, qo_x0}), .in_y0({{16{qo_y0[15]}}, qo_y0}),
    .in_x1({{16{qo_x1[15]}}, qo_x1}), .in_y1({{16{qo_y1[15]}}, qo_y1}),
    .in_x2({{16{qo_x2[15]}}, qo_x2}), .in_y2({{16{qo_y2[15]}}, qo_y2}),
    .in_x3({{16{qo_x3[15]}}, qo_x3}), .in_y3({{16{qo_y3[15]}}, qo_y3}),
    .in_col(qo_col), .in_moire(qo_moire),
    .view_x1(32'sd0), .view_x2(32'(SCR_W) - 32'sd1),
    .view_y1(band_y1), .view_y2(band_y2),
    .span_valid(fl_span_valid), .span_ready(fl_span_ready),
    .span_y(fl_span_y), .span_x0(fl_span_x0), .span_x1(fl_span_x1),
    .span_col(fl_span_col), .span_moire(fl_span_moire),
    .quad_done(fl_quad_done), .line_case(fl_line_case)
  );

  // RGB888 to RGB565 on the way in, as the reference does: the colour is
  // already quantised upstream, so this costs less than it looks.
  wire [15:0] span_565 = {fl_span_col[23:19], fl_span_col[15:10], fl_span_col[7:3]};

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
    for (b = 0; b < NBUF; b++) begin : g_band
      m2_raster_band #(.WIDTH(SCR_W), .HEIGHT(BAND_H)) u_band (
        .clk(clk), .rd_clk(scan_clk), .rst_n(rst_n),
        .band_y0(bd_y0[b]),
        .clear_req(bd_clear_req[b]), .clear_busy(bd_clear_busy[b]),
        .span_valid(bd_span_valid[b]), .span_ready(bd_span_ready[b]),
        .span_y(fl_span_y[15:0]),
        .span_x0(fl_span_x0[15:0]), .span_x1(fl_span_x1[15:0]),
        .span_col(span_565), .span_moire(fl_span_moire),
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
      wire  [BW-1:0] sb_gray = scan_band ^ (scan_band >> 1);
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
      always_comb scan_band_f = scan_band;
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

  always_comb begin
    scan_col = 16'd0;
    scan_hit = 1'b0;
    for (int i = 0; i < NBUF; i++)
      if (rdy_s2[i] && (band_s2[i] == scan_band)) begin
        scan_col = bd_rd_col[i];
        scan_hit = bd_rd_hit[i];
      end
  end

  assign fl_span_ready = bd_span_ready[fill_buf];
  always_comb begin
    bd_span_valid = '0;
    bd_span_valid[fill_buf] = fl_span_valid;
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
      bd_clear_req <= '0; dbg_bands <= 16'd0; dbg_pixels <= 32'd0;
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
          else if (!qs_out_valid && !qs_replay_busy) cst <= C_DONE;
        end
        C_FILLW: if (fl_quad_done) cst <= C_FILL;
        C_DONE: begin
          bd_ready[fill_buf] <= 1'b1;
          dbg_bands  <= dbg_bands + 16'd1;
          if (!(&bands_this)) bands_this <= bands_this + 8'd1;
          dbg_pixels <= dbg_pixels + bd_pixels[fill_buf];
          fill_buf   <= (BUFW'(fill_buf) == BUFW'(NBUF-1)) ? '0 : fill_buf + BUFW'(1);
          fill_band  <= (fill_band == BW'(NBANDS-1)) ? '0 : fill_band + BW'(1);
          cst <= C_IDLE;
        end
        default: cst <= C_IDLE;   // 3 bits, 7 states: the eighth must not latch
      endcase

      // A buffer is free again once the beam has passed its band.
      for (int i = 0; i < NBUF; i++)
        if (bd_ready[i] && (scan_band_f > bd_band[i])) bd_ready[i] <= 1'b0;

      // Latched and restarted together, so the reported pair always describes
      // the SAME frame rather than one number from each side of a boundary.
      if (frame_start) begin
        fill_band <= '0; bd_ready <= '0;
        dbg_bands_done <= bands_this; bands_this <= 8'd0;
        rdy_cyc <= 20'd0; rdy_run <= 1'b1;
        col_cyc <= 20'd0; col_run <= 1'b1;
      end
    end
  end

  wire _unused = &{1'b0, fl_line_case, 1'b0};

endmodule
