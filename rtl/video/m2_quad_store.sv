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
  // R626: FRACTION BITS IN THE STORED COORDINATE. 2 keeps each vertex as
  // 11.2 in the same XW = 13 bits -- the integer part saturates at +/-1023
  // (clipped vertices lie inside the viewport, -1..512) and the quarter pixel
  // below it rides free, for the texture plane fit (m2_geo_project, R626).
  // 0 is the old 13-bit integer, and no in_frac.
  parameter int unsigned FRB    = 0,
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
  parameter int unsigned UVW    = 13,      // R273: texture coordinate, 11.2
  parameter int unsigned TXW    = 24,      // R273: the texel fetch's state
  // R334: 1/z per vertex, as a 16-bit minifloat -- 8-bit IEEE exponent and the
  // top 8 mantissa bits, the sign dropped because 1/z of a vertex in front of
  // the eye is positive. The fill normalises the four to a common fixed point
  // when it fits the plane, which is why no scale has to be stored.
  //
  // SIXTEEN BITS IS MEASURED, NOT CHOSEN. A C model of MAME's uoz/voz/ooz
  // against ground quads gives 0.018 to 0.67 texels of error with an 8-bit
  // mantissa and 1.27 to 3.85 with a 7-bit one, so 8 is the knee. Twelve bits
  // total was proposed first, from a screen-size argument, and would have been
  // 16 texels out -- the error scales with the DEPTH RATIO ACROSS THE QUAD,
  // not with screen size.
  parameter int unsigned OZW    = 16,
  parameter int unsigned TINY   = 2,
  // R769: THE FINE THRESHOLD, USED WHILE THE PREVIOUS LIST FITTED UNDER IT.
  // Close-ups are built from small quads -- a car-select tyre is a ring of
  // 2-3 px quads -- so TINY = 4 is kept only for the lists that need it. The
  // store counts, per list, the quads that pass THIS test; when that count
  // left an eighth of the store free, the next list is tested at TINY_FINE,
  // else at TINY. 0 disables it (TINY always).
  parameter int unsigned TINY_FINE = 0,
  // R776: AND THE COARSE TEST ONLY FOR FAR QUADS. In a list tested coarse, a
  // quad between TINY_FINE and TINY pixels is refused only when its z value
  // (in_z[15:0], the reference's float_to_zval: 4-bit octave, 12-bit
  // mantissa, larger is farther) is at least TINY_FAR. 0x3000 is z = 16 at
  // Daytona's z_adjust of 4.0: car-select tyres sit at 6,510-8,442, the busy
  // scenes' small quads at p5 >= ~12,000. 0 makes every quad far (R769).
  parameter logic [15:0] TINY_FAR = 16'h0000,
  parameter int unsigned SCR_H  = 384,
  // R607: FRONT TO BACK, the reference's order (model2_v.cpp render_polygons:
  // z buckets from min_z up, each bucket a LIFO -- the last polygon submitted
  // at a z is drawn first). With the fill mask, first write wins, so the last
  // submitted wins a tie, exactly as it does under the painter's last-write-
  // wins. 0 keeps the painter's order (z descending, submission order).
  parameter bit          FTB    = 1'b0
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
  // R273: THE TEXTURE, PER QUAD. Four {u, v} in 11.2 texels -- eleven integer
  // bits because a sheet is 2,048 texels across and two fractional ones
  // because the span walk interpolates between these corners and a whole-texel
  // corner slides the picture by half a texel at the edges. `in_tex` is the
  // texel fetch's share of R271's state: sheet, origin, size, mirror.
  input  logic [UVW-1:0] in_u0, in_v0, in_u1, in_v1,
  input  logic [UVW-1:0] in_u2, in_v2, in_u3, in_v3,
  input  logic [OZW-1:0] in_oz0, in_oz1, in_oz2, in_oz3,   // R334
  input  logic [15:0]    in_frac,                           // R626: {fy3,fx3..fy0,fx0}
  input  logic [TXW-1:0] in_tex,

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
  output logic [UVW-1:0] out_u0, out_v0, out_u1, out_v1,
  output logic [UVW-1:0] out_u2, out_v2, out_u3, out_v3,
  output logic [OZW-1:0] out_oz0, out_oz1, out_oz2, out_oz3,   // R334
  output logic [15:0]    out_frac,                             // R626
  output logic [TXW-1:0] out_tex,

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
  // R262: ONE WIDE ARRAY PER BANK, NOT FOUR NARROW ONES.
  //
  // These were eight arrays of NQ x 26 bits, and 26 maps badly onto an M10K:
  // the block's native widths are 8, 16, 20 and 40, so a 26-bit word takes a
  // 20-bit slice plus an 8-bit slice and wastes the rest. The fitter's own
  // report priced it -- 88 blocks holding 426 K bits inside 900 K, 43% full --
  // and M10K is the binding resource at 553 of 553 with texture still to come.
  //
  // All four vertices are written in the same cycle and read in the same
  // cycle, so they were never independent memories: one array of 4 x 26 bits
  // per bank is the same storage with one address and one port, and its 104-bit
  // word fills three 40-bit slices instead of eight mismatched ones. It also
  // turns four reads into one in the replay path.
  localparam int unsigned VW = 4 * 2 * XW;      // four vertices, {y,x} each
  (* ramstyle = "M10K" *) logic [VW-1:0] vtx_0 [NQ], vtx_1 [NQ];
  // A BAND RANGE, NOT A MASK (R213): {hi, lo} in BW bits each. With 48 bands
  // a mask was 48 bits an entry; a range is 12, and the replay test is two
  // compares. A quad off the screen is stored as lo > hi and never hits.
  localparam int unsigned AT_W = 2*BW + 1 + CW;   // {hi, lo, moire, col565}
  (* ramstyle = "M10K" *) logic [AT_W-1:0] att_0 [NQ], att_1 [NQ];
  (* ramstyle = "M10K" *) logic [KW-1:0] key [NQ];
  // R273: the texture, in its own array for the same reason the vertices are in
  // theirs -- written once with the quad, read once on replay, never touched by
  // the sort. 8 x 13 + 21 = 125 bits, which fills three 40-bit M10K slices and
  // a 5-bit remainder rather than straddling the vertex word.
  // R334: + four 1/z. 104 + 24 + 64 = 192 bits, which is 39 M10K per bank in
  // the 2048x5 mode against 26 at 128 -- the +26 blocks R331 costs.
  localparam int unsigned UW  = 4 * 2 * UVW + TXW + 4 * OZW;
  localparam int unsigned OZ0 = 4 * 2 * UVW + TXW;   // where the 1/z block starts
  (* ramstyle = "M10K" *) logic [UW-1:0] uvt_0 [NQ], uvt_1 [NQ];

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
  // R626: with FRB, the integer saturated to XW-FRB bits and the quarters below
  localparam int unsigned XI = XW - FRB;
  function automatic [XW-1:0] satf(input logic signed [15:0] v, input logic [1:0] f);
    logic signed [15:0] hi, lo;
    logic [XW-1:0] r;
    begin
      if (FRB == 0) satf = sat(v);
      else begin
        hi = 16'sd1 <<< (XI - 1); hi = hi - 16'sd1;   // +1023 at FRB 2
        lo = -hi - 16'sd1;
        r  = XW'((v > hi) ? hi : (v < lo) ? lo : v) << FRB;
        r[1:0] = (v > hi || v < lo) ? 2'd0 : f;     // a saturated vertex has no quarter
        satf = r;
      end
    end
  endfunction
  function automatic [15:0] sxf(input logic [XW-1:0] v);
    sxf = (FRB == 0) ? sx(v) : 16'(signed'(v) >>> FRB);
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
  // R566: the count as it WILL be once a quad still in the one-cycle attribute
  // stage below has been counted -- so a quad arriving the very next cycle
  // takes the next slot rather than the pending one's. Every term is a
  // register, so this does not bring the comparator trees back into the path.
  logic          a_v, a_room, a_tiny, a_bank, a_need;
  wire           a_inc  = a_v && a_room && !a_tiny && (a_bank == wbank);
  wire  [IW:0]  wcount = count[wbank] + {{IW{1'b0}}, a_inc};
  wire  [IW:0]  rcount = count[rbank];
  assign dbg_count = {{(16-IW-1){1'b0}}, wcount};

  // The capacity test, written once. count is one bit wider than an index so it
  // can hold NQ itself without wrapping.
  wire has_room = (wcount < {1'b0, IW'(NQ-1)} + 1'b1);

  // Which of the six 64-row bands this quad's rows touch. Computed from the
  // vertex extremes, clamped: a quad above the screen or below it lands in no
  // band and is never replayed.
  function automatic logic signed [15:0] smin(input logic signed [15:0] p, q);
    smin = (q < p) ? q : p;
  endfunction
  function automatic logic signed [15:0] smax(input logic signed [15:0] p, q);
    smax = (q > p) ? q : p;
  endfunction
  // R731: IN TWO HALVES. The min/max tree is registered with the quad (a_lo,
  // a_hi) and the clamp and divide happen in the cycle that writes att_* --
  // as one cycle from the clipper's registers it was m2_geo_clip|qsy ->
  // a_band, 0.462 ns at 75 MHz (s759), short of 80. The same band.
  function automatic [2*BW-1:0] band_of(input logic signed [15:0] lo_in, hi_in);
    logic signed [15:0] lo, hi2;
    begin
      lo  = lo_in;
      hi2 = hi_in;
      if (hi2 < 0 || lo > $signed(16'(SCR_H - 1))) band_of = {BW'(0), BW'(NBANDS-1)};   // lo > hi: never
      else begin
        if (lo  < 0)                        lo  = 16'sd0;
        if (hi2 > $signed(16'(SCR_H - 1)))  hi2 = $signed(16'(SCR_H - 1));
        band_of = {BW'(int'(hi2) / int'(BAND_H)), BW'(int'(lo) / int'(BAND_H))};
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
      // R579: BALANCED TREES, two compare-and-select levels rather than three
      // in series -- the same answers (s312: qsy -> a_tiny, -1.56 ns at 70).
      xl = smin(smin(x0, x1), smin(x2, x3));
      xh = smax(smax(x0, x1), smax(x2, x3));
      yl = smin(smin(y0, y1), smin(y2, y3));
      yh = smax(smax(y0, y1), smax(y2, y3));
      tiny_quad = (TINY != 0) && ((xh - xl) < $signed(16'(TINY))) && ((yh - yl) < $signed(16'(TINY)));
    end
  endfunction
  // R592: FOR TINY = 2, PAIRWISE, NOT MIN AND MAX. max - min < 2 exactly when
  // every pair differs by -1, 0 or +1 -- the same 16-bit arithmetic as
  // tiny_quad, wraparound included -- and six subtracts per axis side by side
  // are one subtract deep where the trees were compare, select, compare,
  // select, subtract, compare (s317: qsy -> a_tiny, -0.389 ns at 70 MHz).
  // |d| <= 1 on a 16-bit difference is "bits 15:1 all zero" (0, +1) or "all
  // sixteen ones" (-1); -2 has bits 15:1 all ones and bit 0 clear, and fails.
  //
  // R598: AND FOR ANY TINY -- WHICH MATTERS, BECAUSE THE INSTANCE IS TINY = 4.
  // m2_raster3d builds this store with TINY(4) (R233), so R592's TINY == 2
  // branch was never taken on hardware and the trees stayed in the build
  // (s321: qsx -> smin -> a_tiny, -0.331 ns). max - min < T exactly when
  // every pair differs by at most T-1 either way; on the 16-bit difference
  // that is d <= T-1 or d >= 2^16 - (T-1), two constant compares. At T = 2 it
  // is R592's near1. Checked against the tree form for T = 2, 4 and 8, 300,000
  // quads each with spreads from 1 to 3,000: 0 disagree.
  function automatic logic near_t(input logic signed [15:0] a, input logic signed [15:0] b,
                                  input int unsigned t);
    logic [15:0] d;
    begin
      d = 16'(a - b);
      near_t = (d <= 16'(t - 1)) || (d >= 16'(32'h1_0000 - (t - 1)));
    end
  endfunction
  function automatic logic tiny_t(input int unsigned t);
    tiny_t = (t != 0)
          && near_t(in_x0, in_x1, t) && near_t(in_x0, in_x2, t) && near_t(in_x0, in_x3, t)
          && near_t(in_x1, in_x2, t) && near_t(in_x1, in_x3, t) && near_t(in_x2, in_x3, t)
          && near_t(in_y0, in_y1, t) && near_t(in_y0, in_y2, t) && near_t(in_y0, in_y3, t)
          && near_t(in_y1, in_y2, t) && near_t(in_y1, in_y3, t) && near_t(in_y2, in_y3, t);
  endfunction
  wire is_tiny   = tiny_t(TINY);
  wire is_tiny_f = tiny_t(TINY_FINE);
  // R769: `fine` is a register, so the select folds into the last LUT of
  // the two trees rather than lengthening either.
  logic          fine;
  logic [IW:0]   need;        // this list's quads that pass the fine test, saturating
  wire           far_q    = (TINY_FAR == 16'h0000) || (in_z[15:0] >= TINY_FAR);   // R776
  wire           tiny_sel = (TINY_FINE != 0 && fine) ? is_tiny_f
                          : (TINY_FINE != 0) ? (is_tiny_f | (is_tiny & far_q))
                          : is_tiny;

  // R566: THE COUNT AND THE ATTRIBUTE WORD LAND ONE CYCLE AFTER THE QUAD.
  //
  // At 50 MHz the clipper's output coordinate reached this store's quad COUNT
  // through tiny_quad()'s eight-way min/max tree in one cycle (s297: qsx[1][14]
  // -> count[0][*], +1.125 ns), and the attribute RAMs' data through
  // band_range() (+1.967 / +2.194). A 60 MHz core clock takes 3.33 ns off
  // both. So the two comparator trees, and the attribute word they feed, are
  // registered, and the count and att write happen the next cycle.
  //
  // WHY ONE CYCLE LATE IS SAFE. (1) A quad arriving the very next cycle takes
  // the slot after the pending one: wcount above includes a pending increment
  // (m2_geo_clip cannot emit back to back, but tb_m2_raster3d does, and the
  // store should not depend on its source's pacing). (2) The sort reads the
  // count no earlier than two cycles after the last quad: q_end -> P_SORT ->
  // sort_start -> R_IDLE -> R_INIT. (3) The vertex,
  // texture and key RAMs are still written on the quad's own cycle at wcount,
  // exactly as before; a tiny quad's slot is reused by the next quad as it
  // always was. `clear` wins over a pending increment, as it did over in_valid.
  logic                a_moire;
  logic [IW-1:0]       a_slot;
  logic signed [15:0] a_lo, a_hi;   // R731: band_of() at the write
  // R739: and only the first round of the min/max tree here -- the pairs --
  // the second at the write with the clamp (s786 at 80 MHz: qsy -> a_lo
  // -0.273, 7 endpoints). a_lo/a_hi above are now the write side's wires.
  logic signed [15:0] a_lo01, a_lo23, a_hi01, a_hi23;
  assign a_lo = smin(a_lo01, a_lo23);
  assign a_hi = smax(a_hi01, a_hi23);
  logic [CW-1:0]       a_col;
  // R740: THE ATTRIBUTE WORD A STAGE LATER STILL. R739's split left the band's
  // second round, clamp and divide in front of the att RAM's data port (s789
  // at 80 MHz: a_lo23 -> att_1 PORT_A_DATA_IN -0.498). The word is finished
  // into b_* and written the cycle after the count: nothing reads att_* for a
  // slot until the band pass, long after the sort (R566 (2)), and the count
  // itself does not move. `clear` still wins over a pending write.
  logic                b_v, b_bank, b_moire;
  logic [IW-1:0]       b_slot;
  logic [2*BW-1:0]     b_band;
  logic [CW-1:0]       b_col;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_v <= 1'b0; a_room <= 1'b0; a_tiny <= 1'b0; a_bank <= 1'b0; a_moire <= 1'b0; a_need <= 1'b0;
      a_slot <= '0; a_lo01 <= '0; a_lo23 <= '0; a_hi01 <= '0; a_hi23 <= '0; a_col <= '0;
      b_v <= 1'b0; b_bank <= 1'b0; b_moire <= 1'b0; b_slot <= '0; b_band <= '0; b_col <= '0;   // R740
    end else begin
      a_v     <= in_valid && !clear;
      a_room  <= has_room;
      a_tiny  <= tiny_sel;
      a_need  <= !is_tiny_f;
      a_bank  <= wbank;
      a_slot  <= wcount[IW-1:0];
      a_lo01  <= smin(in_y0, in_y1);  a_lo23 <= smin(in_y2, in_y3);   // R579 balanced; R739 split
      b_v     <= a_v && a_room;                                   // R740: the att word, finished
      b_bank  <= a_bank;  b_slot <= a_slot;  b_moire <= a_moire;  b_col <= a_col;
      b_band  <= band_of(a_lo, a_hi);
      a_hi01  <= smax(in_y0, in_y1);  a_hi23 <= smax(in_y2, in_y3);
      a_moire <= in_moire;
      a_col   <= c565(in_col);
    end
  end

  logic [IW-1:0] wi;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int b = 0; b < int'(NBANK); b++) count[b] <= '0;
      wi <= '0; dbg_dropped <= '0; dbg_tiny <= '0;
      fine <= 1'b1; need <= '0;
    end else if (clear) begin
      count[wbank] <= '0; wi <= '0; dbg_dropped <= '0; dbg_tiny <= '0;
      // R769: the list just ended decides the next one's threshold.
      fine <= (need < (IW+1)'(NQ - NQ/8));
      need <= '0;
    end else begin
      if (a_v && a_need && !(&need)) need <= need + 1'b1;
      // THE VERTEX RAMs' WRITE ENABLE DOES NOT WAIT FOR THE TINY TEST (R222).
      // Every accepted quad is WRITTEN at slot wcount and only the COUNT is
      // withheld when it is tiny: the slot is simply reused by the next quad.
      if (in_valid && has_room) begin
        if (wbank) begin
          vtx_1[wcount[IW-1:0]] <= {satf(in_y3, in_frac[15:14]), satf(in_x3, in_frac[13:12]),
                                    satf(in_y2, in_frac[11:10]), satf(in_x2, in_frac[9:8]),
                                    satf(in_y1, in_frac[7:6]),   satf(in_x1, in_frac[5:4]),
                                    satf(in_y0, in_frac[3:2]),   satf(in_x0, in_frac[1:0])};
          uvt_1[wcount[IW-1:0]]  <= {in_oz3, in_oz2, in_oz1, in_oz0,
                                     in_tex, in_v3, in_u3, in_v2, in_u2,
                                     in_v1, in_u1, in_v0, in_u0};
        end else begin
          vtx_0[wcount[IW-1:0]] <= {satf(in_y3, in_frac[15:14]), satf(in_x3, in_frac[13:12]),
                                    satf(in_y2, in_frac[11:10]), satf(in_x2, in_frac[9:8]),
                                    satf(in_y1, in_frac[7:6]),   satf(in_x1, in_frac[5:4]),
                                    satf(in_y0, in_frac[3:2]),   satf(in_x0, in_frac[1:0])};
          uvt_0[wcount[IW-1:0]]  <= {in_oz3, in_oz2, in_oz1, in_oz0,
                                     in_tex, in_v3, in_u3, in_v2, in_u2,
                                     in_v1, in_u1, in_v0, in_u0};
        end
        // R246: in_z CARRIES THE REFERENCE'S 16-BIT z VALUE in its low half
        // (m2_geometry's zval, model2_v.cpp's float_to_zval), not a float.
        // Complemented because the sort is ascending and the painter wants the
        // largest z -- the furthest -- first.
        // R607: uncomplemented when front to back -- nearest first.
        key[wcount[IW-1:0]] <= FTB ? in_z[KW-1:0] : ~in_z[KW-1:0];
      end
      // R566: a cycle later, from the registered comparators.
      if (b_v) begin   // R740: a cycle after the count
        if (b_bank) att_1[b_slot] <= {b_band, b_moire, b_col};
        else        att_0[b_slot] <= {b_band, b_moire, b_col};
      end
      if (a_v) begin
        if (a_tiny) begin
          if (dbg_tiny != 16'hffff) dbg_tiny <= dbg_tiny + 16'd1;
        end else if (a_room) begin
          count[a_bank] <= count[a_bank] + 1'b1;
        end else if (dbg_dropped != 16'hffff) begin
          dbg_dropped <= dbg_dropped + 16'd1;
        end
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
        // R607: FRONT TO BACK STARTS IN REVERSE SUBMISSION ORDER, so the stable
        // sort leaves ties last-submitted-first -- MAME's bucket LIFO.
        R_INIT: begin
          if (wbank) idx_a1[ri[IW-1:0]] <= FTB ? IW'(wcount - 1'b1 - ri) : ri[IW-1:0];
          else       idx_a0[ri[IW-1:0]] <= FTB ? IW'(wcount - 1'b1 - ri) : ri[IW-1:0];
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
  // R541: THE SCAN RUNS AHEAD OF THE FILL.
  //
  // The scan above froze on every hit until the fill had TAKEN that quad --
  // and the fill then spent tens of cycles on it (C_FILLW, 34% of a heavy
  // frame's cycles in tb_m2_raster3d) while the scan sat idle, after which the
  // fill waited again for the scan to find the next one ("replaying", 21%).
  // The two were serial. Now each hit goes into a small queue and the scan
  // carries on, stopping only when the queue is full; an emitter reads the
  // head's vertices and hands it over. First in, first out, so the painter's
  // order the sort established is exactly what the fill sees.
  localparam int unsigned HQ = 4;
  localparam int unsigned HW = $clog2(HQ) + 1;
  logic [IW-1:0] hq_q   [HQ];
  logic [CW:0]   hq_att [HQ];         // {moire, col565}, taken at the hit
  logic [HW-1:0] hq_wp, hq_rp;
  wire           hq_empty = (hq_wp == hq_rp);
  wire           hq_full  = ((hq_wp - hq_rp) == HW'(HQ));
  wire           hq_two   = ((hq_wp - hq_rp) >= HW'(2));
  wire [HW-2:0]  hq_nx    = hq_rp[HW-2:0] + 1'b1;   // the entry after the head

  logic          sc_run;              // the scan is walking the list
  logic [IW:0]   pi;
  logic [IW-1:0] q;
  logic          v1, v2;
  logic [IW-1:0] q2;

  logic [IW-1:0] ord_idx;
  logic [AT_W-1:0] att_rd;
  // R262: one 104-bit word holds all four, packed {v3,v2,v1,v0} with {y,x} in
  // each. The slices below are the same four words the four arrays used to be.
  logic [VW-1:0] vtx_r;
  logic [UW-1:0] uvt_r;
  wire [2*XW-1:0] v0_r = vtx_r[0*2*XW +: 2*XW];
  wire [2*XW-1:0] v1_r = vtx_r[1*2*XW +: 2*XW];
  wire [2*XW-1:0] v2_r = vtx_r[2*2*XW +: 2*XW];
  wire [2*XW-1:0] v3_r = vtx_r[3*2*XW +: 2*XW];
  assign out_y0 = sxf(v0_r[2*XW-1:XW]); assign out_x0 = sxf(v0_r[XW-1:0]);
  assign out_y1 = sxf(v1_r[2*XW-1:XW]); assign out_x1 = sxf(v1_r[XW-1:0]);
  assign out_y2 = sxf(v2_r[2*XW-1:XW]); assign out_x2 = sxf(v2_r[XW-1:0]);
  assign out_y3 = sxf(v3_r[2*XW-1:XW]); assign out_x3 = sxf(v3_r[XW-1:0]);
  // R626: the quarters, {fy3,fx3..fy0,fx0}; zero without FRB
  assign out_frac = (FRB == 0) ? 16'd0
                  : {v3_r[XW+1:XW], v3_r[1:0], v2_r[XW+1:XW], v2_r[1:0],
                     v1_r[XW+1:XW], v1_r[1:0], v0_r[XW+1:XW], v0_r[1:0]};
  assign out_u0 = uvt_r[0*UVW +: UVW]; assign out_v0 = uvt_r[1*UVW +: UVW];
  assign out_u1 = uvt_r[2*UVW +: UVW]; assign out_v1 = uvt_r[3*UVW +: UVW];
  assign out_u2 = uvt_r[4*UVW +: UVW]; assign out_v2 = uvt_r[5*UVW +: UVW];
  assign out_u3 = uvt_r[6*UVW +: UVW]; assign out_v3 = uvt_r[7*UVW +: UVW];
  assign out_tex = uvt_r[8*UVW +: TXW];
  assign out_oz0 = uvt_r[OZ0 + 0*OZW +: OZW];   // R334
  assign out_oz1 = uvt_r[OZ0 + 1*OZW +: OZW];
  assign out_oz2 = uvt_r[OZ0 + 2*OZW +: OZW];
  assign out_oz3 = uvt_r[OZ0 + 3*OZW +: OZW];

  wire v0 = sc_run && (pi < rcount);

  wire [BW-1:0] q_band_hi = att_rd[AT_W-1:AT_W-BW];
  wire [BW-1:0] q_band_lo = att_rd[AT_W-BW-1:CW+1];
  wire          hit = v2 && (replay_band >= q_band_lo) && (replay_band <= q_band_hi);
  // The pipeline moves unless a hit is standing with nowhere to go.
  // R741: unless ANY quad is standing in stage two with the queue full -- hit
  // or not. The hit test (replay_band against the att word just read) was in
  // the list RAMs' read enable (s791 at 80 MHz: raster3d fill_band -> the
  // RAM's PORT_B_ADDRESS_STALL -0.467). A miss now waits for a queue slot it
  // does not need, a cycle, only while the queue is full; nothing is reordered.
  wire          adv = sc_run && !(v2 && hq_full);

  typedef enum logic [1:0] { E_IDLE, E_READ, E_OUT } estate_t;
  estate_t e_st;

  assign replay_busy = sc_run || !hq_empty || (e_st != E_IDLE);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      sc_run <= 1'b0; pi <= '0; q <= '0;
      v1 <= 1'b0; v2 <= 1'b0; q2 <= '0;
      ord_idx <= '0; att_rd <= '0;
      hq_wp <= '0; hq_rp <= '0; e_st <= E_IDLE;
      out_valid <= 1'b0;
      vtx_r <= '0; uvt_r <= '0;
      out_col <= '0; out_moire <= 1'b0;
    end else if (replay_start) begin
      // A band starts only when the previous one has drained (the sequencer
      // waits on replay_busy), so nothing is lost here.
      sc_run <= (rcount != 0);
      pi <= '0; v1 <= 1'b0; v2 <= 1'b0;
      hq_wp <= '0; hq_rp <= '0; e_st <= E_IDLE; out_valid <= 1'b0;
    end else begin
      // ---- the scan: the same three-stage alignment as before (see above).
      if (adv) begin
        ord_idx <= rbank ? idx_a1[pi[IW-1:0]] : idx_a0[pi[IW-1:0]];
        att_rd  <= rbank ? att_1[ord_idx] : att_0[ord_idx];
        q2      <= ord_idx;
        v1      <= v0;
        v2      <= v1;
        if (v0) pi <= pi + 1'b1;
        // The hit in stage two leaves the pipeline on this same edge, into
        // the queue.
        if (hit) begin
          hq_q  [hq_wp[HW-2:0]] <= q2;
          hq_att[hq_wp[HW-2:0]] <= att_rd[CW:0];
          hq_wp <= hq_wp + 1'b1;
        end
      end
      if (sc_run && !v0 && !v1 && !v2) sc_run <= 1'b0;   // drained

      // ---- the emitter. The vertex memories are registered: the quad's data
      // is ready the cycle after q settles, which is when out_valid rises.
      // ONE READ PER ARRAY (R262): the slices are taken from the registered
      // word, not from two reads of the array.
      case (e_st)
        E_IDLE: if (!hq_empty) begin
          q         <= hq_q[hq_rp[HW-2:0]];
          out_col   <= c888(hq_att[hq_rp[HW-2:0]][CW-1:0]);
          out_moire <= hq_att[hq_rp[HW-2:0]][CW];
          e_st      <= E_READ;
        end
        E_READ: begin
          vtx_r     <= rbank ? vtx_1[q] : vtx_0[q];
          uvt_r     <= rbank ? uvt_1[q] : uvt_0[q];
          out_valid <= 1'b1;
          e_st      <= E_OUT;
        end
        E_OUT: if (out_ready) begin
          out_valid <= 1'b0;
          hq_rp     <= hq_rp + 1'b1;
          // Straight on to the next if one is already waiting.
          if (hq_two) begin
            q         <= hq_q[hq_nx];
            out_col   <= c888(hq_att[hq_nx][CW-1:0]);
            out_moire <= hq_att[hq_nx][CW];
            e_st      <= E_READ;
          end else e_st <= E_IDLE;
        end
        default: e_st <= E_IDLE;
      endcase
    end
  end

endmodule
