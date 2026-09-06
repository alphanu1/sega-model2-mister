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
  parameter int unsigned BAND_H = 16,
  parameter int unsigned NBUF   = 3
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
  output logic [31:0] dbg_pixels
);

  localparam int unsigned NBANDS = (SCR_H + BAND_H - 1) / BAND_H;
  localparam int unsigned BW     = $clog2(NBANDS);
  localparam int unsigned BUFW   = (NBUF > 1) ? $clog2(NBUF) : 1;

  // ------------------------------------------------------------ quad store
  logic        qs_clear, qs_sort_start, qs_sort_busy;
  logic        qs_replay_start, qs_replay_busy, qs_out_ready, qs_out_valid;
  logic [BW-1:0] qs_band;
  logic signed [15:0] qo_x0, qo_y0, qo_x1, qo_y1, qo_x2, qo_y2, qo_x3, qo_y3;
  logic [23:0] qo_col;
  logic        qo_moire;

  assign q_ready = 1'b1;      // the store absorbs or drops; it never backpressures

  m2_quad_store #(.BAND_H(BAND_H), .NBANDS(NBANDS), .BW(BW), .SCR_H(SCR_H)) u_store (
    .clk(clk), .rst_n(rst_n),
    .clear(qs_clear),
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
  wire [BW-1:0] scan_band = BW'(scan_y / 10'(BAND_H));

  // Scan-out picks whichever buffer currently holds the beam's band. Combinational
  // over NBUF, which is three: cheaper than a register that has to track the beam.
  always_comb begin
    scan_col = 16'd0;
    scan_hit = 1'b0;
    for (int i = 0; i < NBUF; i++)
      if (bd_ready[i] && (bd_band[i] == scan_band)) begin
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
  assign qs_clear        = frame_start;
  assign qs_sort_start   = (pst == P_SORT);
  assign qs_replay_start = (cst == C_REPLAY);
  assign qs_out_ready    = (cst == C_FILL) && fl_in_ready;
  assign fl_in_valid     = (cst == C_FILL) && qs_out_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pst <= P_COLLECT; cst <= C_IDLE;
      fill_band <= '0; fill_buf <= '0; bd_ready <= '0;
      bd_clear_req <= '0; dbg_bands <= 16'd0; dbg_pixels <= 32'd0;
      for (int i = 0; i < NBUF; i++) begin bd_y0[i] <= 16'sd0; bd_band[i] <= '0; end
    end else begin
      bd_clear_req <= '0;

      // ---- producer: collect quads for the frame, then sort once
      case (pst)
        P_COLLECT: if (q_end) pst <= P_SORT;
        P_SORT:    pst <= P_SORTW;
        P_SORTW:   if (!qs_sort_busy) pst <= P_READY;
        P_READY:   if (frame_start) begin pst <= P_COLLECT; end
      endcase

      // ---- consumer: one band at a time into the rotating buffers
      case (cst)
        C_IDLE: if (pst == P_READY && !bd_ready[fill_buf]) begin
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
          dbg_pixels <= dbg_pixels + bd_pixels[fill_buf];
          fill_buf   <= (BUFW'(fill_buf) == BUFW'(NBUF-1)) ? '0 : fill_buf + BUFW'(1);
          fill_band  <= (fill_band == BW'(NBANDS-1)) ? '0 : fill_band + BW'(1);
          cst <= C_IDLE;
        end
        default: cst <= C_IDLE;   // 3 bits, 7 states: the eighth must not latch
      endcase

      // A buffer is free again once the beam has passed its band.
      for (int i = 0; i < NBUF; i++)
        if (bd_ready[i] && (scan_band > bd_band[i])) bd_ready[i] <= 1'b0;

      if (frame_start) begin fill_band <= '0; bd_ready <= '0; end
    end
  end

  wire _unused = &{1'b0, fl_line_case, 1'b0};

endmodule
