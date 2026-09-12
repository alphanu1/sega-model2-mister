// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE for the full text.
//
// The quad store and the painter's sort.
//
// Model 1 has no Z-buffer: draw_quads paints z DESCENDING with ties broken by
// submission order (quad_t::compare, model1_v.cpp:535), so every quad of a
// viewport has to be collected before any of it can be drawn. This holds them,
// sorts them, and replays them in order - once per band, because the band buffer
// covers 64 of 384 rows and the same list is walked for each.
//
// WHY A RADIX SORT AND NOT A COMPARISON SORT
//
// A comparison sort needs the quads reachable in a random order while it works.
// An LSD radix sort touches them strictly in sequence and only ever moves an
// INDEX, so the quads themselves sit still in one wide memory and the sort works
// on 11-bit indices - two arrays of 2,048, which is a handful of M10K rather than
// a second copy of the store. Four passes of eight bits over a 32-bit key is
// 4 x 2,048 reads and writes, nothing against a frame.
//
// It is also STABLE, which is what makes the tie-break free: MAME resolves equal
// z by submission order, and a stable sort that starts in submission order keeps
// it without the key ever mentioning it.
//
// THE KEY IS THE FLOAT, MADE MONOTONIC. IEEE floats compare as sign-magnitude, so
// a raw integer compare is wrong across zero. The standard transform - invert a
// negative entirely, set the sign bit of a positive - makes the unsigned integer
// order match the float order. Then the key is COMPLEMENTED, because the sort is
// ascending and the painter wants descending.
//
// OVERFLOW IS COUNTED, NOT SILENT. A frame with more quads than the store holds
// drops the excess and says so. A real frame measured 2,001 quads and a peak frame
// 4,798 records of which not all emit, so 2,048 is the right order and the counter
// is how we find out if it is not.

`timescale 1ns/1ps

module m2_quad_store #(
  parameter int unsigned NQ     = 2048,      // quads held
  parameter int unsigned IW     = 11,        // ceil(log2(NQ))
  // THE BAND GEOMETRY IS A PARAMETER, not three hardcoded constants.
  //
  // It was written for six 64-row bands: a 6-bit mask, a 3-bit band select, and
  // a row-to-band index of `y[8:6]`. Halving the band height to 32 for the sound
  // M10K budget left all three untouched, so bands 6..11 had no mask bit, the
  // select could not address them, and a 3-bit counter compared against
  // 3'(12-1) = 3 stopped the frame dead after band 3. The picture was correct as
  // far as it went and simply ended a quarter of the way down.
  parameter int unsigned BAND_H = 32,
  parameter int unsigned NBANDS = 12,
  parameter int unsigned BW     = 4,         // ceil(log2(NBANDS))
  // FOUR BITS A PASS, NOT EIGHT, AND THE DEVICE DECIDED IT.
  //
  // A radix sort's histogram is read-modify-written at a dynamic address, which
  // no block RAM can do, so it is registers plus a multiplexer per entry. At
  // eight bits that is two 256-entry arrays of 12 bits - about 6,000 flops and
  // two 256:1 muxes - and the design missed fitting by 15 LABs of 4,191.
  //
  // At four bits the arrays are 16 entries: a sixteenth of the flops and muxes.
  // The cost is eight passes over the key instead of four, so the sort doubles
  // from 21% of a frame to about 42%. That is affordable and not fitting is not.
  parameter int unsigned RADIX  = 4,
  // NARROW ENTRIES (R211): the device ran out of M10K BLOCKS, not bits, when
  // the store was doubled. Screen coordinates are held in XW bits with
  // saturation on the way in (the clipper keeps them near the 496x384
  // screen; 13 bits is +-4095), the colour as 565 (which is all the band
  // buffer ever takes of it), and the sort key as its top KW bits. 2048 x
  // (4*26 + 24+1+16 + 24 + 2*11) = 191 bits against 231: 40 blocks a bank
  // against 47, and the radix sort runs KW/RADIX passes instead of 32/RADIX.
  // TWO BANKS IN ONE STORE (R213). The rasteriser collects into one bank
  // while replaying the other every video frame (R211). Only the collecting
  // bank is ever sorted, so the sort KEY and the SCRATCH index array are
  // shared; the quad data and the FINAL index order are per bank. Two
  // separate instances cost ~8 M10K blocks more than this.
  parameter int unsigned NBANK  = 2,
  parameter int unsigned XW     = 13,
  parameter int unsigned CW     = 16,
  parameter int unsigned KW     = 16,      // R246: the reference's 16-bit z value, not a float
  // R216: A QUAD UNDER TINY PIXELS IN BOTH DIMENSIONS IS NOT STORED. The
  // title's busiest frames carry ~4,200 quads against 2,048 held and the
  // bench's histogram says 46% of them are under 2x2 pixels (14% under
  // 1x1, none off-screen). The reference draws every one of them as a dot
  // or two; here they cost half the store and half of every band's replay.
  // Counted, so the deviation is measured, not assumed. 0 disables it.
  parameter int unsigned TINY   = 2,
  parameter int unsigned SCR_H  = 384
) (
  input  logic        clk,
  input  logic        rst_n,

  // ---- write side, from the geometry stage
  input  logic        clear,                 // start a new frame (in wbank)
  input  logic        wbank,                 // the bank collected into and sorted
  input  logic        rbank,                 // the bank replayed
  input  logic        in_valid,
  input  logic signed [15:0] in_x0, in_y0, in_x1, in_y1,
  input  logic signed [15:0] in_x2, in_y2, in_x3, in_y3,
  input  logic [23:0] in_col,
  input  logic [31:0] in_z,
  input  logic        in_moire,

  // ---- sort
  input  logic        sort_start,
  output logic        sort_busy,

  // ---- read side, replayed in painter's order. Restartable per band.
  //
  // BAND FILTERED. The band buffer covers 64 of 384 rows, so the sorted list is
  // walked six times a frame - and a quad that does not touch the band must not
  // cost anything to skip. Its row range is computed once on the way IN and
  // stored as a six-bit mask, so a replay pass tests one bit instead of four
  // vertices. Without it the six passes cost ~20 cycles of setup per quad per
  // band, which is 276,000 cycles of a 818,133-cycle frame spent on quads that
  // draw nothing.
  input  logic [BW-1:0] replay_band,
  input  logic        replay_start,
  output logic        replay_busy,
  input  logic        out_ready,
  output logic        out_valid,
  output logic signed [15:0] out_x0, out_y0, out_x1, out_y1,
  output logic signed [15:0] out_x2, out_y2, out_x3, out_y3,
  output logic [23:0] out_col,
  output logic        out_moire,

  output logic [15:0] dbg_count,
  output logic [15:0] dbg_dropped,
  output logic [15:0] dbg_tiny        // R216: quads refused for being under TINY px both ways
);


  // Four 32-bit words a quad: two vertices, then colour and key.
  //   w0 {y0,x0}   w1 {y1,x1}   w2 {y2,x2}   w3 {y3,x3}
  // and a separate narrow array for colour+moire, and one for the sort key, so
  // the sort never reads the wide one.
  // FOUR SEPARATE MEMORIES, ONE PER VERTEX, and this is not a style choice.
  //
  // As a single `vtx [NQ*4]` array this module wrote all four vertices of a quad
  // in one cycle and read all four in one cycle. An array with four simultaneous
  // accesses cannot be a RAM, and Quartus does not say so - it builds the whole
  // 8,192 x 32 bits out of flip-flops with 8192:1 multiplexers and carries on.
  //
  // Measured: 112,742 combinational nodes in this module alone, 93% of the 3D
  // layer and 68% of the entire design, against a device that holds 83,820. The
  // first real build failed to fit at 166,497. m2_geometry, doing all the actual
  // arithmetic, is 6,238.
  //
  // One vertex per memory gives each a single write port and a single read port,
  // which is a Simple Dual Port M10K and infers cleanly. the project rules' warning that
  // "block RAM inference is silent when it fails" cost 28,816 ALM once before.
  // PER-BANK ARRAYS, NOT ONE ARRAY OF DOUBLE DEPTH. An M10K holds 2048x5 or
  // 4096x2: a 4096-deep array of W bits costs ceil(W/2) blocks against
  // 2 x ceil(W/5) for two 2048-deep ones -- 13 against 12 for a vertex
  // word, 15 against 12 for the attribute word. build/dbuf8 ran out of
  // blocks with the merged arrays; the bank selects between two.
  (* ramstyle = "M10K" *) logic [2*XW-1:0] vtx0_0 [NQ], vtx0_1 [NQ];
  (* ramstyle = "M10K" *) logic [2*XW-1:0] vtx1_0 [NQ], vtx1_1 [NQ];
  (* ramstyle = "M10K" *) logic [2*XW-1:0] vtx2_0 [NQ], vtx2_1 [NQ];
  (* ramstyle = "M10K" *) logic [2*XW-1:0] vtx3_0 [NQ], vtx3_1 [NQ];
  // A BAND RANGE, NOT A MASK (R213): {hi, lo} in BW bits each. With 48 bands
  // a mask was 48 bits an entry; a range is 12, and the replay test is two
  // compares. A quad off the screen is stored as lo > hi and never hits.
  localparam int unsigned AT_W = 2*BW + 1 + CW;   // {hi, lo, moire, col565}
  (* ramstyle = "M10K" *) logic [AT_W-1:0] att_0 [NQ], att_1 [NQ];
  (* ramstyle = "M10K" *) logic [KW-1:0] key [NQ];

  // Saturate a screen coordinate to XW bits; sign-extend it back on the way out.
  function automatic [XW-1:0] sat(input logic signed [15:0] v);
    logic signed [15:0] hi, lo;
    begin
      hi = 16'sd1 <<< (XW - 1); hi = hi - 16'sd1;   // +4095
      lo = -hi - 16'sd1;                            // -4096
      sat = (v > hi) ? hi[XW-1:0] : (v < lo) ? lo[XW-1:0] : v[XW-1:0];
    end
  endfunction
  function automatic [15:0] sx(input logic [XW-1:0] v);
    sx = {{(16-XW){v[XW-1]}}, v};
  endfunction
  // 888 -> 565 and back: m2_raster3d takes [23:19], [15:10], [7:3] of out_col,
  // so an entry expanded this way yields the same 565 it was stored from.
  function automatic [CW-1:0] c565(input logic [23:0] c);
    c565 = {c[23:19], c[15:10], c[7:3]};
  endfunction
  function automatic [23:0] c888(input logic [CW-1:0] c);
    c888 = {c[15:11], 3'b000, c[10:5], 2'b00, c[4:0], 3'b000};
  endfunction

  // Two index arrays, ping-ponged by the radix passes.
  // THE FINAL ORDER, ONE ARRAY PER BANK. As a single {bank, index} array
  // Quartus inferred only the replay's read port and built the sort's read
  // (45,613 registers, build/dbuf7); two arrays with the bank selecting the
  // result infer as the single-bank store did, one write and two reads each.
  (* ramstyle = "M10K" *) logic [IW-1:0] idx_a0 [NQ];
  (* ramstyle = "M10K" *) logic [IW-1:0] idx_a1 [NQ];
  (* ramstyle = "M10K" *) logic [IW-1:0] idx_b [NQ];

  logic [IW:0]  count [NBANK];
  wire  [IW:0]  wcount = count[wbank];
  wire  [IW:0]  rcount = count[rbank];
  assign dbg_count = {{(16-IW-1){1'b0}}, wcount};

  // The capacity test, written once. count is one bit wider than an index so it
  // can hold NQ itself without wrapping.
  wire has_room = (wcount < {1'b0, IW'(NQ-1)} + 1'b1);

  // Which of the six 64-row bands this quad's rows touch. Computed from the
  // vertex extremes, clamped: a quad above the screen or below it lands in no
  // band and is never replayed.
  function automatic [2*BW-1:0] band_range(input logic signed [15:0] a, b, c, d);
    logic signed [15:0] lo, hi2;
    begin
      lo  = a;  if (b < lo)  lo  = b;  if (c < lo)  lo  = c;  if (d < lo)  lo  = d;
      hi2 = a;  if (b > hi2) hi2 = b;  if (c > hi2) hi2 = c;  if (d > hi2) hi2 = d;
      if (hi2 < 0 || lo > $signed(16'(SCR_H - 1))) band_range = {BW'(0), BW'(NBANDS-1)};   // lo > hi: never
      else begin
        if (lo  < 0)                        lo  = 16'sd0;
        if (hi2 > $signed(16'(SCR_H - 1)))  hi2 = $signed(16'(SCR_H - 1));
        band_range = {BW'(int'(hi2) / int'(BAND_H)), BW'(int'(lo) / int'(BAND_H))};
      end
    end
  endfunction

  // R246: THE KEY IS NO LONGER MADE HERE. It used to be a monotone transform
  // of the float z, complemented; m2_geometry now hands over the reference's
  // own 16-bit z value (model2_v.cpp's float_to_zval), which is coarse on
  // purpose -- polygons within one part in 4,096 tie and fall to the list's
  // order, which is the game's choice and not this core's.

  // ---------------------------------------------------------------- write
  function automatic logic tiny_quad(input logic signed [15:0] x0, y0, x1, y1, x2, y2, x3, y3);
    logic signed [15:0] xl, xh, yl, yh;
    begin
      xl = x0; if (x1 < xl) xl = x1; if (x2 < xl) xl = x2; if (x3 < xl) xl = x3;
      xh = x0; if (x1 > xh) xh = x1; if (x2 > xh) xh = x2; if (x3 > xh) xh = x3;
      yl = y0; if (y1 < yl) yl = y1; if (y2 < yl) yl = y2; if (y3 < yl) yl = y3;
      yh = y0; if (y1 > yh) yh = y1; if (y2 > yh) yh = y2; if (y3 > yh) yh = y3;
      tiny_quad = (TINY != 0) && ((xh - xl) < $signed(16'(TINY))) && ((yh - yl) < $signed(16'(TINY)));
    end
  endfunction
  wire is_tiny = tiny_quad(in_x0, in_y0, in_x1, in_y1, in_x2, in_y2, in_x3, in_y3);

  logic [IW-1:0] wi;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int b = 0; b < int'(NBANK); b++) count[b] <= '0;
      wi <= '0; dbg_dropped <= '0; dbg_tiny <= '0;
    end else if (clear) begin
      count[wbank] <= '0; wi <= '0; dbg_dropped <= '0; dbg_tiny <= '0;
    end else if (in_valid) begin
      // THE VERTEX RAMs' WRITE ENABLE DOES NOT WAIT FOR THE TINY TEST (R222).
      // It used to be `in_valid && !is_tiny && has_room`, and is_tiny is a
      // min/max tree over eight 16-bit coordinates -- so the clipper's output
      // y fed a comparator chain and then a block RAM's write-enable pin, and
      // that was the worst path in the design at 50 MHz once lighting made the
      // placement tighter (build/lit1 s13: -0.210 ns, qsy[0][7] -> the vertex
      // RAM's porta_we). Now every accepted quad is WRITTEN at slot wcount and
      // only the COUNT is withheld when it is tiny: the slot is simply reused
      // by the next quad, so the stored list is identical, and the comparator
      // tree ends at a small counter instead of a RAM control pin.
      if (has_room) begin
        if (wbank) begin
          vtx0_1[wcount[IW-1:0]] <= {sat(in_y0), sat(in_x0)};
          vtx1_1[wcount[IW-1:0]] <= {sat(in_y1), sat(in_x1)};
          vtx2_1[wcount[IW-1:0]] <= {sat(in_y2), sat(in_x2)};
          vtx3_1[wcount[IW-1:0]] <= {sat(in_y3), sat(in_x3)};
          att_1[wcount[IW-1:0]]  <= {band_range(in_y0, in_y1, in_y2, in_y3), in_moire, c565(in_col)};
        end else begin
          vtx0_0[wcount[IW-1:0]] <= {sat(in_y0), sat(in_x0)};
          vtx1_0[wcount[IW-1:0]] <= {sat(in_y1), sat(in_x1)};
          vtx2_0[wcount[IW-1:0]] <= {sat(in_y2), sat(in_x2)};
          vtx3_0[wcount[IW-1:0]] <= {sat(in_y3), sat(in_x3)};
          att_0[wcount[IW-1:0]]  <= {band_range(in_y0, in_y1, in_y2, in_y3), in_moire, c565(in_col)};
        end
        // R246: in_z CARRIES THE REFERENCE'S 16-BIT z VALUE in its low half
        // (m2_geometry's zval, model2_v.cpp's float_to_zval), not a float.
        // Complemented because the sort is ascending and the painter wants the
        // largest z -- the furthest -- first.
        key[wcount[IW-1:0]] <= ~in_z[KW-1:0];
      end
      if (is_tiny) begin
        if (dbg_tiny != 16'hffff) dbg_tiny <= dbg_tiny + 16'd1;
      end else if (has_room) begin
        count[wbank] <= wcount + 1'b1;
      end else if (dbg_dropped != 16'hffff) begin
        dbg_dropped <= dbg_dropped + 16'd1;
      end
    end
  end

  // ---------------------------------------------------------------- radix sort
  typedef enum logic [3:0] {
    R_IDLE, R_INIT, R_CNT,
    R_CNT_RUN, R_SUM, R_SCAT_RUN,
    R_NEXT, R_DONE
  } rstate_t;
  rstate_t rst_st;

  localparam int unsigned NPASS = KW / RADIX;
  localparam int unsigned NBUCK = 1 << RADIX;
  localparam int unsigned PW    = $clog2(NPASS);

  logic [PW-1:0] pass;                // which digit of the key
  logic [IW:0]  ri;
  logic [RADIX:0] hi;
  logic [IW:0]  hist [NBUCK];
  logic [IW:0]  base [NBUCK];
  logic [IW:0]  acc;
  logic         which;                // 0: a -> b, 1: b -> a
  logic [IW-1:0] cur_idx;
  // The index that goes with the digit now leaving the pipeline: cur_idx has
  // already moved on by the time its key comes back.
  logic [IW-1:0] cidx_d;
  // Three valid bits, one per stage of the two registered reads. Named for the
  // sort; the replay path below has its own.
  logic s0, s1, s2;

  assign sort_busy = (rst_st != R_IDLE);

  // EVERY READ OF A MEMORY IS REGISTERED, and that is not a style preference.
  //
  // An M10K has a registered read port. A continuous assignment out of an array -
  // `wire x = mem[addr];` - is an ASYNCHRONOUS read, which no block RAM can do,
  // so Quartus builds the whole array out of flip-flops and says nothing.
  //
  // Measured: key[2048] as an async read was 65,536 registers, and this module
  // carried 63,630 of the design's 93,971 while m2_geometry - doing all the
  // arithmetic - had 5,778. The fit failed needing 7,465 LABs of the device's
  // 4,191. Three arrays were being read asynchronously: the sort keys, the index
  // arrays, and the band mask out of att.
  //
  // The cost is a cycle per access, which this sequencer already had states for.
  logic [IW-1:0] idx_rd;
  logic [KW-1:0] key_rd;
  always_ff @(posedge clk) begin
    idx_rd <= which ? idx_b[ri[IW-1:0]] : (wbank ? idx_a1[ri[IW-1:0]] : idx_a0[ri[IW-1:0]]);
    key_rd <= key[cur_idx];
  end

  // ONE ELEMENT PER CYCLE, NOT FIVE.
  //
  // Both reads are registered - an asynchronous read of `key` cost 65,536
  // registers and is not coming back - so an element takes three cycles to walk
  // from `ri` to a digit. Doing that as five sequential states meant the two
  // block RAMs were idle four cycles in five, and it MEASURED as 812,776 cycles
  // of the render bench, 7.1% of everything, for a sort of at most 2,048 items:
  //
  //     5 cycles x 2 loops x 8 passes x count   =  80 cycles a quad
  //
  // Pipelined it is 16 plus a three-cycle drain per loop. The replay path in
  // this same module was already built this way; the sort was not, and the two
  // sat forty lines apart.
  wire pipe_busy = s0 || s1 || s2;
  wire more      = (ri < wcount);

  // The RADIX-bit field selected by `pass`, taken with a shift so the width is a
  // parameter rather than four hand-written slices that stop matching it.
  wire [KW-1:0] key_shifted = key_rd >> (RADIX * pass);
  wire [RADIX-1:0] digit = key_shifted[RADIX-1:0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rst_st <= R_IDLE; pass <= '0; ri <= '0; hi <= '0; acc <= '0;
      which <= 1'b0; cur_idx <= '0; cidx_d <= '0;
      s0 <= 1'b0; s1 <= 1'b0; s2 <= 1'b0;
      // NBUCK, not a hardcoded 256. Narrowing the radix left this loop walking
      // sixteen times past the end of both arrays - which Verilator tolerates
      // silently and Quartus rejects outright with "index 16 cannot fall outside
      // the declared range". A constant that has to track a parameter and does
      // not is the same class of bug as the band mask that was still six bits
      // after the band height halved.
      for (int i = 0; i < int'(NBUCK); i++) begin hist[i] <= '0; base[i] <= '0; end
    end else begin
      case (rst_st)
        R_IDLE: if (sort_start) begin
          pass <= '0; which <= 1'b0; ri <= '0;
          rst_st <= R_INIT;
        end

        // Submission order to start with: a stable sort then keeps it as the
        // tie-break, exactly as quad_t::compare does with the address.
        R_INIT: begin
          if (wbank) idx_a1[ri[IW-1:0]] <= ri[IW-1:0]; else idx_a0[ri[IW-1:0]] <= ri[IW-1:0];
          if (ri + 1 >= wcount) begin ri <= '0; hi <= '0; rst_st <= R_CNT; end
          else                       ri <= ri + 1'b1;
        end

        R_CNT: begin                       // clear the histogram
          hist[hi[RADIX-1:0]] <= '0;
          if (hi == (RADIX+1)'(NBUCK-1)) begin
            hi <= '0; ri <= '0;
            s0 <= 1'b0; s1 <= 1'b0; s2 <= 1'b0;
            rst_st <= R_CNT_RUN;
          end
          else                                 hi <= hi + (RADIX+1)'(1);
        end

        // Three stages, one element issued a cycle:
        //
        //   s0  idx_rd has landed for the element issued three cycles ago
        //   s1  cur_idx holds it, and addresses the key memory
        //   s2  key_rd has landed, so `digit` is that element's digit
        //
        // cur_idx has moved on by s2, so the index that belongs with the digit
        // is carried alongside in cidx_d rather than re-derived.
        R_CNT_RUN: begin
          if (more) ri <= ri + 1'b1;
          s0 <= more; s1 <= s0; s2 <= s1;
          cur_idx <= idx_rd;
          cidx_d  <= cur_idx;
          if (s2) hist[digit] <= hist[digit] + 1'b1;
          if (!more && !pipe_busy) begin
            hi <= '0; acc <= '0; rst_st <= R_SUM;
          end
        end

        R_SUM: begin                       // exclusive prefix sum
          base[hi[RADIX-1:0]] <= acc;
          acc <= acc + hist[hi[RADIX-1:0]];
          if (hi == (RADIX+1)'(NBUCK-1)) begin
            ri <= '0; s0 <= 1'b0; s1 <= 1'b0; s2 <= 1'b0;
            rst_st <= R_SCAT_RUN;
          end else hi <= hi + (RADIX+1)'(1);
        end

        // The same pipeline, with a write at the end. The write order IS the
        // walk order, which is what makes the sort stable and therefore what
        // makes submission order the tie-break, exactly as quad_t::compare has
        // it.
        R_SCAT_RUN: begin
          if (more) ri <= ri + 1'b1;
          s0 <= more; s1 <= s0; s2 <= s1;
          cur_idx <= idx_rd;
          cidx_d  <= cur_idx;
          if (s2) begin
            if (which) begin
              if (wbank) idx_a1[base[digit][IW-1:0]] <= cidx_d; else idx_a0[base[digit][IW-1:0]] <= cidx_d;
            end
            else       idx_b[base[digit][IW-1:0]] <= cidx_d;
            base[digit] <= base[digit] + 1'b1;
          end
          if (!more && !pipe_busy) rst_st <= R_NEXT;
        end

        R_NEXT: begin
          which <= ~which;
          if (pass == PW'(NPASS-1)) rst_st <= R_DONE;
          else begin
            pass   <= pass + PW'(1);
            hi     <= '0;
            rst_st <= R_CNT;
          end
        end

        R_DONE: rst_st <= R_IDLE;
        default: rst_st <= R_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------- replay
  //
  // A THREE-STAGE PIPELINE, so a quad that is not in this band costs ONE cycle.
  //
  // The sorted list is walked once per band - twelve times a frame - and almost
  // all of what it walks is skipped, because a quad touches two or three bands.
  // As a four-state sequence that cost 4 cycles a quad, so 2,001 quads cost 8,004
  // cycles of a band-time of 61,741 no matter what the band contained.
  //
  // THE ALIGNMENT IS THE WHOLE DIFFICULTY, and a first attempt at this reordered
  // the sort by getting it wrong. Both memory reads are registered, so:
  //
  //   cycle N    pi addresses idx_a          valid v0 = (pi < count)
  //   cycle N+1  ord_idx holds idx_a[pi@N]   valid v1, and it addresses att
  //   cycle N+2  att_rd holds att[ord@N+1]   valid v2, quad q2 = ord_idx@N+1
  //
  // So the decision stage must pair att_rd with a COPY of ord_idx taken at N+1,
  // not with ord_idx itself. Re-registering ord_idx into another stage instead
  // shifts the quad one place against its own attributes, which draws every quad
  // exactly once and in the wrong order.
  typedef enum logic [1:0] { P_IDLE, P_RUN, P_OUT } pstate_t;
  pstate_t p_st;

  logic [IW:0]   pi;
  logic [IW-1:0] q;
  logic          v1, v2;
  logic [IW-1:0] q2;

  logic [IW-1:0] ord_idx;
  logic [AT_W-1:0] att_rd;
  logic [2*XW-1:0] v0_r, v1_r, v2_r, v3_r;    // the four vertex words, one read each
  assign out_y0 = sx(v0_r[2*XW-1:XW]); assign out_x0 = sx(v0_r[XW-1:0]);
  assign out_y1 = sx(v1_r[2*XW-1:XW]); assign out_x1 = sx(v1_r[XW-1:0]);
  assign out_y2 = sx(v2_r[2*XW-1:XW]); assign out_x2 = sx(v2_r[XW-1:0]);
  assign out_y3 = sx(v3_r[2*XW-1:XW]); assign out_x3 = sx(v3_r[XW-1:0]);

  wire v0 = (pi < rcount);

  // Frozen while a quad is being emitted: the vertex reads and the output
  // register are shared, and those are the quads the band exists to draw.
  wire [BW-1:0] q_band_hi = att_rd[AT_W-1:AT_W-BW];
  wire [BW-1:0] q_band_lo = att_rd[AT_W-BW-1:CW+1];
  wire          hit = v2 && (replay_band >= q_band_lo) && (replay_band <= q_band_hi);
  wire              adv = (p_st == P_RUN) && !hit;

  assign replay_busy = (p_st != P_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p_st <= P_IDLE; pi <= '0; q <= '0;
      v1 <= 1'b0; v2 <= 1'b0; q2 <= '0;
      ord_idx <= '0; att_rd <= '0;
      out_valid <= 1'b0;
      v0_r <= '0; v1_r <= '0; v2_r <= '0; v3_r <= '0;
      out_col <= '0; out_moire <= 1'b0;
    end else begin
      if (adv) begin
        ord_idx <= rbank ? idx_a1[pi[IW-1:0]] : idx_a0[pi[IW-1:0]];
        att_rd  <= rbank ? att_1[ord_idx] : att_0[ord_idx];
        q2      <= ord_idx;
        v1      <= v0;
        v2      <= v1;
        if (v0) pi <= pi + 1'b1;
      end

      case (p_st)
        P_IDLE: begin
          out_valid <= 1'b0;
          if (replay_start && rcount != 0) begin
            pi <= '0; v1 <= 1'b0; v2 <= 1'b0;
            p_st <= P_RUN;
          end
        end

        P_RUN: begin
          if (hit) begin
            q         <= q2;
            out_col   <= c888(att_rd[CW-1:0]);
            out_moire <= att_rd[CW];
            p_st      <= P_OUT;
          end else if (!v0 && !v1 && !v2) begin
            p_st <= P_IDLE;              // drained
          end
        end

        // The vertex memories are registered, so the quad's data is ready the
        // cycle after q settles.
        //
        // ONE READ PER ARRAY, NOT TWO. `vtx0[q][15:0]` and `vtx0[q][31:16]` are
        // two separate reads of the same array at the same address as far as
        // synthesis is concerned, and Quartus answers a second read port by
        // DUPLICATING the memory. Measured in the fit report: vtx0 as
        // vtx0_rtl_0 and vtx0_rtl_1, 10 and 11 M10K for one 65,536-bit array,
        // and the same for the other three - 91 blocks for 411,648 bits of
        // unique data, 40% packing efficiency.
        //
        // A concatenation on the left is one read, split on the way out, and it
        // is bit-identical: the store writes {in_y, in_x}.
        P_OUT: begin
          // ONE READ PER ARRAY (see the note above): the slices are taken
          // from the registered word, not from two reads of the array.
          v0_r <= rbank ? vtx0_1[q] : vtx0_0[q];
          v1_r <= rbank ? vtx1_1[q] : vtx1_0[q];
          v2_r <= rbank ? vtx2_1[q] : vtx2_0[q];
          v3_r <= rbank ? vtx3_1[q] : vtx3_0[q];
          out_valid <= 1'b1;
          if (out_valid && out_ready) begin
            out_valid <= 1'b0;
            v2        <= 1'b0;           // this one is consumed
            p_st      <= P_RUN;
          end
        end

        default: p_st <= P_IDLE;
      endcase
    end
  end

endmodule
