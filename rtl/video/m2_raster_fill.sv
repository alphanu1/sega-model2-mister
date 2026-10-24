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
// Behavioural contract is MAME's model1_v.cpp (BSD-3-Clause, Olivier
// Galibert) — fill_quad, fill_slope, fill_line and draw_hline. Rules and line
// references are written up in docs/m3-rasterizer-spec.md.
//
// Quad filler: one quad in, a stream of horizontal spans out.
//
// The primitive is always a quad. The frustum clipper upstream emits a clipped
// triangle as a quad with a repeated vertex, so there is no triangle path and
// no primitive-type input — degeneracy is data. Two edges walk down from the
// topmost vertex in 16.16 fixed point, one span per scanline, and there is no
// per-pixel arithmetic at all: the cost of this block is the slope divider and
// the accumulators, which is why it is worth measuring before the band buffer
// is designed around it.
//
// Things here that look wrong and are not:
//
//  * x is 32-bit and carries s.x << 16, which **overflows for |s.x| >= 32768**.
//    MAME's spoint_t is int32_t and it does exactly this, so a vertex far off
//    screen wraps rather than saturating. Reproduced, not fixed.
//
//  * The left/right decision is made once per segment, not per scanline. If the
//    two edges cross inside a segment the span stays in the original order and
//    goes empty. That is fill_slope's behaviour.
//
//  * fill_slope covers [y_top, y_bottom) — the bottom scanline belongs to the
//    next segment, and the last scanline of the whole quad is emitted by the
//    fill_line tail. Making the range inclusive double-draws every internal
//    vertex row, which with MOIRE stipple is visible.
//
//  * MAME guards the span with `xx1 <= view->x2 || xx2 >= view->x1`, where && was
//    plainly meant. It is harmless — when the guard is the only thing that would
//    reject, the clamped span is already empty — so only the clamp is
//    implemented here. Behaviour identical, one comparison cheaper.
//
// Not handled here: a quad with exactly two distinct screen vertices is a
// wireframe, which MAME rasterizes with a clipped Bresenham line instead of
// filling. That is a separate unit; this block flags the case on `line_case`
// and retires the quad without emitting. See the spec for why that path is
// MAME improving on the filler rather than known silicon behaviour.
// SCREEN COORDINATES ARE SIXTEEN BITS, AND THAT IS A CONTRACT (R327).
//
// Every x and y in this module -- the vertices in, the viewport bounds, the
// scanline walk, the span out -- is a plain screen coordinate held in 16 bits.
// They were 32, for a 496x384 screen, and the top sixteen were sign extension
// that this module ALREADY refused to look at: `px[i]` seeds the 16.16
// accumulator from `{sx[i], 16'h0000}`, the plane fit's edge deltas took
// `sx[..][15:0]`, and `uv_at` sliced its own argument to sixteen. So the bits
// being dropped were carried by every register, mux and comparator here and
// then thrown away at every consumer.
//
// WHAT GUARANTEES IT: m2_quad_store saturates every screen coordinate to XW =
// 13 bits (+/-4,095) on the way in -- see its `sat()` -- so nothing that can
// reach this module comes near the 16-bit limit. **If XW ever grows past 16,
// or if a caller is added that does not go through the quad store, this module
// silently truncates.** The fill bench's directed `y-huge` case used to pass
// +/-100,000 and had to be brought inside the range; the fuzz now runs y to
// +/-20,000, five times what the hardware can produce, so the top of the range
// is actually visited.
//
// NOT narrowed, because they are 16.16 fixed point and not coordinates:
// `xa`, `xb`, `sla`, `slb`, `px[]`, `xlo*`, `xhi*`, `flat_lo/hi`, `emit_l/r`,
// and everything in the plane fit. Confusing the two is the mistake this note
// exists to stop: the first attempt narrowed `xlo01` and lost sixteen
// fractional bits of the edge accumulator.
//
// MULTIPLIES GO TO DSP BLOCKS. The plane fit is eight signed products and the
// per-span interpolation two more, and this part has 56 of its 112 DSP blocks
// free while it has 550 ALMs free. Left to itself the synthesiser built them
// out of logic.
(* multstyle = "dsp" *)
module m2_raster_fill #(
  // R616: THE PLANES ARE EVALUATED AT PIXEL CENTRES, as the reference samples
  // them. MAME's texel at (x, y) is the perspective plane at (x + 0.5,
  // y + 0.5): the 3D frame differential (R615) matched it to 0.66 texels
  // there and to 6.4 at the corner, on the mid-distance road (poly 521, where
  // v moves 12 texels a pixel vertically -- half a pixel is 6 texels, which
  // is the road's wrong orientation). 1 adds half of each gradient to every
  // plane's base. 0 keeps the corner, which tb_m2_raster_fill's reference
  // models.
  parameter bit PXC = 1'b0,
  // R626: QUARTER-PIXEL VERTICES FOR THE PLANE FIT. With FRB = 2, in_frac
  // carries each vertex's quarter pixel below its integer position, and the
  // fit runs on 4x + f: det grows by 16 and each numerator by 4, the divide's
  // normalisation keeps the same significant bits, and the undo shifts two
  // more. With every quarter zero the gradients and bases are bit-identical
  // to FRB = 0. The edges -- coverage -- still use the integers.
  parameter int unsigned FRB = 0,
  // R658: MODEL 2'S COVERAGE, NOT MODEL 1'S. Model 1 (fill_quad/fill_slope/
  // fill_line) walks integer vertices, covers [floor(xl), floor(xr)] and draws
  // the last row separately. Model 2 in MAME is poly.h: rows round(ymin) ..
  // round(ymax)-1, each sampled at its CENTRE, pixels [round(xl), round(xr)),
  // round(v) = floor(v) + (frac > 1/2), no special last row, nothing for a
  // polygon of no height. With whole-pixel vertices a near-horizontal edge
  // shared by two polygons lands a row off, and that whole row goes to the
  // wrong polygon -- a line of the neighbour's texture, moving every frame
  // (frame 1000: 59 pixels of row 212 to the wrong one; 1.3-3.1% of opaque
  // pixels across frames 1000/4000/9000). 1 walks the edges on the quarter-
  // pixel vertices (FRB 2, which it requires) by MAME's rule. 0 is Model 1.
  parameter bit M2COV = 1'b0,
  // R791: FRACTION BITS OF u/z AND v/z. qu/qv held u/z as a 13-bit INTEGER
  // of quarter-texels, (u * ooz) >> 15 truncated, and one unit of that is
  // 2^15 / ooz quarter-texels at a pixel -- at the far corner of a road
  // polygon 5.7x deeper than its near one (attract, MAME frame 8780), 1.4 to
  // 2.8 TEXELS a unit. The plane through the truncated corners tilts the near
  // end of the road by a fraction of a texel, which at ~2.6 pixels a texel is
  // several pixels -- and the residue is new every frame, so the road's
  // texture judders (measured on 24 consecutive MAME frames: 6.8 px mean
  // displacement, 2.6 px mean frame-to-frame jump; 1.7 px / 0.8 px at 4).
  // UZF carries u/z and v/z with this many more bits, in registers: qu/qv are
  // 13 + UZF wide. The gradients come out of the same divide in the scaled
  // units, so they gain UZF fraction bits too (8.8 was R286's choice, sized in
  // TEXELS -- the 2^15 / ooz factor and the magnification were not in it).
  // The u/v span values are (u/z) << 18 for every UZF: 18 - UZF fraction bits
  // over 13 + UZF integer ones, so a 32-bit signed value always holds them.
  // 0 is the old precision (the representation differs; the values do not).
  parameter int unsigned UZF = 4,
  // R828: THE QUAD'S MIP BIAS. For a projective map the texel footprint along
  // any screen direction is N * z^2 with N constant along that direction, and
  // along a quad's edge N is the edge's texels per pixel times the two ends'
  // 1/z: |duv| * oz_a * oz_b / |dxy|. The largest over the edges, as a log in
  // quarter levels, is span_mipk; m2_span_tex adds -2 log2(1/z) per group.
  // Worked out one edge a cycle beside S_OZ's normaliser, which already walks
  // the vertices with their raw u, v and 1/z. 0: span_mipk is 0 and unused.
  // R828a: THE OSD CHOOSES HOW MUCH OF THE SMALLEST EDGE K COUNTS. The
  // largest is the footprint's major axis, and on a road seen at a grazing
  // angle that is the compressed depth axis: the near road went 2-4 levels
  // blurry (s1052 on the board), while face-on surfaces (the mountains) looked
  // right. K = max - (max - min) * w, w = 0 (R828 exactly), 1/4 or 1/2: a
  // weighted mean of the logs, which leaves a face-on quad (max ~ min) where
  // R828 put it and pulls an oblique one towards its minor axis.
  parameter bit MIP = 1'b0,
  // R944: EVERY WALKED EDGE MOVED OUTWARD BY (1 + |dx/dy|) / 8 PIXEL, clamped
  // to the edge's own x extent +/- 1/8. The vertices are quarter pixels, so a
  // T-junction vertex -- one lying on its neighbour's long edge (Sega Rally's
  // car shadow: one quad's edge, three quads on the other side of it) -- is up
  // to 1/8 off that edge in x and in y, and the two sides of the edge part by
  // up to (1 + |dx/dy|) / 4 pixel in a row: on a shallow edge (40 px a row)
  // several pixels, once a row, the board's two dotted lines. Moving each
  // edge out by half that closes any such gap; the overlap it makes with a
  // true shared edge is at most 1/4 px across the edge, where the polygon
  // drawn later wins. Model 1's fill never leaves a gap either -- its spans
  // are [floor(xl), floor(xr)], a whole pixel of overlap. Needs M2COV. 0: the
  // edges exactly as R658 walks them.
  // FLAT QUADS ONLY. m2_span_tex walks a span's texel groups from its first
  // pixel, so a textured span start moved out by a pixel re-phases every
  // group of the span (measured: Rally attract 960, 38,863 pixels change for
  // ~2,000 that change polygon, and the frame's error vs MAME goes up). A
  // textured quad keeps R658's edges exactly.
  parameter bit DIL = 1'b0
) (
  input  logic               clk,
  input  logic               rst_n,

  // Quad in. Screen-space integer vertices, a finished RGB888 colour (lighting
  // and the palette lookup happen upstream in the geometry stage) and the
  // moire stipple flag.
  input  logic               in_valid,
  output logic               in_ready,
  input  logic signed [15:0] in_x0, in_y0,
  input  logic signed [15:0] in_x1, in_y1,
  input  logic signed [15:0] in_x2, in_y2,
  input  logic signed [15:0] in_x3, in_y3,
  input  logic [23:0]        in_col,
  input  logic               in_moire,
  // R274: THE TEXTURE. Four corners of {u, v} in 11.2 texels and the texel
  // fetch's state; bit 0 of in_tex says the polygon is textured at all.
  input  logic [12:0]        in_u0, in_v0, in_u1, in_v1,
  input  logic [12:0]        in_u2, in_v2, in_u3, in_v3,
  // R337: 1/z per vertex as a 16-bit minifloat (8-bit IEEE exponent, 8 mantissa
  // bits, sign dropped -- see m2_geometry's mf16). The fill normalises them.
  input  logic [15:0]        in_oz0, in_oz1, in_oz2, in_oz3,
  input  logic [15:0]        in_frac,          // R626: {fy3,fx3..fy0,fx0}
  input  logic [23:0]        in_tex,
  // R940: the quad's u and v are the true ones >> in_uvs (m2_geometry UVSH);
  // carried beside span_tex to m2_span_tex, and s levels added to the mip
  // bias below. 0 for every quad that fits 13 bits.
  input  logic [1:0]         in_uvs,
  // R828a: the mip rule, run time (OSD, quasi-static, on clk): 0 no level
  // (span_mipk -512, level 0 everywhere), 1 the largest edge K (R828), 2 max -
  // (max - min) / 4, 3 max - (max - min) / 2. Unused without MIP.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [1:0]         mip_mode,
  // R828c: the geometry's no-mip flag for this quad (m2_geometry q_mipz):
  // the game's own level is at most -MIPZ_B all over the polygon, so its
  // spans carry no level (K_NONE), as Off does. Unused without MIP.
  input  logic               in_mipz,
  /* verilator lint_on UNUSEDSIGNAL */

  // Viewport, inclusive on all four edges.
  input  logic signed [15:0] view_x1, view_x2, view_y1, view_y2,

  // Span out, inclusive and already clamped. Empty spans are never emitted.
  // Backpressure is real here and not decoration: the band buffer writer runs a
  // pixel loop, so it stalls the walk.
  output logic               span_valid,
  input  logic               span_ready,
  output logic signed [15:0] span_y,
  output logic signed [15:0] span_x0,
  output logic signed [15:0] span_x1,
  output logic [23:0]        span_col,
  output logic               span_moire,
  // R274: the span's texture, as a starting coordinate and a per-pixel step.
  // R791: u/z and v/z (quarter-texels, scaled as below) times 2^18: (13 +
  // UZF).(18 - UZF) in units of 2^-UZF. The consumer walks u += span_dudx.
  output logic signed [31:0] span_u, span_v,
  // 16.8 in units of 2^-UZF of u/z; the span walk shifts it up to its own
  // (18 - UZF) fraction bits.
  output logic signed [23:0] span_dudx, span_dvdx,     // R618: 16.8, was 8.8
  // R337: the perspective span. u and v above are u/z and v/z now; these carry
  // 1/z and its gradient, and `span_oshift` is the per-quad scale that
  // m2_span_tex must undo -- u = (uoz << oshift) / ooz.
  // THE SCALE IS A CONSTANT 15 AND IS NOT CARRIED. Normalisation puts the
  // largest 1/z of the quad in [2^14, 2^15), so (u * ooz) >> 15 lands in
  // [u/2, u) and fits the same 13 bits u did. m2_span_tex undoes it with a
  // fixed shift: u = (uoz << 15) / ooz.
  output logic signed [31:0] span_ooz,
  output logic signed [23:0] span_doozdx,
  output logic [23:0]        span_tex,
  output logic [1:0]         span_uvs,       // R940: in_uvs, latched with the quad
  output logic               span_tex_en,
  output logic signed [9:0]  span_mipk,      // R828: the quad's mip bias (MIP)

  // One cycle. Note quad_done can land in the same cycle as the quad's last
  // span, and in_ready can rise with that span still in flight — the next quad
  // is accepted and simply stalls at its first emit until the pending one is
  // taken. span_valid is the only authority on span delivery; a consumer that
  // stops listening at quad_done loses the last scanline.
  output logic               quad_done,
  // R436: WHERE IT STOPS, not where I think it stops. Four board builds of
  // perspective have wedged and every diagnosis so far has been inferred from
  // the TGP four stages upstream. dbg_hot is the state this unit spent longest
  // in since the last frame_start, and dbg_hotcyc is how long. If the fill is
  // the thing that stalls, this names the state outright.
  output logic [4:0]         dbg_hot,
  output logic [15:0]        dbg_hotcyc,
  output logic               line_case    // that quad was a wireframe, not filled
);

  localparam logic [4:0] S_IDLE     = 5'd0;
  localparam logic [4:0] S_CLASSIFY = 5'd1;
  localparam logic [4:0] S_FLAT     = 5'd2;
  localparam logic [4:0] S_START1   = 5'd3;
  localparam logic [4:0] S_START2   = 5'd4;
  localparam logic [4:0] S_LOADX    = 5'd5;
  localparam logic [4:0] S_DIVA     = 5'd6;
  localparam logic [4:0] S_DIVAW    = 5'd7;
  localparam logic [4:0] S_OFF      = 5'd8;    // R658: a reloaded edge to its first row's centre
  localparam logic [4:0] S_FS_DIL   = 5'd9;    // R944: the segment's edges moved out (DIL); was S_DIVBW, unused
  localparam logic [4:0] S_DECIDE   = 5'd10;
  localparam logic [4:0] S_FS_ENTER = 5'd11;
  localparam logic [4:0] S_FS_MULA  = 5'd12;
  localparam logic [4:0] S_FS_MULB  = 5'd13;
  localparam logic [4:0] S_FS_SWAP  = 5'd14;
  localparam logic [4:0] S_FS_WALK  = 5'd15;
  localparam logic [4:0] S_FS_END   = 5'd16;
  localparam logic [4:0] S_FINAL    = 5'd17;
  localparam logic [4:0] S_DONE     = 5'd18;
  // R274: the texture plane fit, ahead of the classification.
  localparam logic [4:0] S_PF_D     = 5'd19;   // the deltas and the determinant
  localparam logic [4:0] S_PF_N     = 5'd20;   // the four numerators
  localparam logic [4:0] S_PF_Q1    = 5'd21;   // du/dx and du/dy
  localparam logic [4:0] S_PF_Q1W   = 5'd22;
  localparam logic [4:0] S_PF_Q2    = 5'd23;   // dv/dx and dv/dy
  localparam logic [4:0] S_PF_Q2W   = 5'd24;
  localparam logic [4:0] S_PF_B     = 5'd25;   // the plane's value at (0,0)
  localparam logic [4:0] S_MINMAX   = 5'd26;   // R301: the vertex tournament, registered
  // R418: one cycle to count leading zeros, so the shift is not behind it.
  localparam logic [4:0] S_PF_NRM   = 5'd27;
  // R337: one vertex per cycle, reusing one shifter and one multiplier pair
  // rather than four of each -- 120 ALM and 6 DSP blocks, for four cycles in a
  // machine that already idles six waiting on m2_raster_div.
  // R432: 28/29/30, because R418 took 27 after this was written.
  localparam logic [4:0] S_OZ       = 5'd28;
  localparam logic [4:0] S_PF_Q3    = 5'd29;   // R337: the 1/z plane's divides
  localparam logic [4:0] S_PF_Q3W   = 5'd30;
  // R727: one cycle for pr_* to follow pf_second before S_PF_D reads them
  localparam logic [4:0] S_PF_DW    = 5'd31;

  localparam logic [1:0] EM_WALK = 2'd0;   // swapf-ordered edge pair
  localparam logic [1:0] EM_RAW  = 2'd1;   // xa, xb in chain order (fill_line tail)
  localparam logic [1:0] EM_FLAT = 2'd2;   // the flat-quad min/max pair

  logic [4:0] state /* verilator public_flat_rd */;
  // R544: THE PLANE FIT RUNS BESIDE THE EDGE SETUP, NOT BEFORE IT.
  //
  // A textured quad used to walk S_OZ .. S_PF_B (~18 cycles) and only then
  // S_MINMAX .. S_DECIDE (~12) -- and tb_m2_raster3d measured 44 cycles a
  // quad handed, of which 6 draw anything. The two chains share nothing: the
  // fit uses m2_persp_recip and mul_q, the edges m2_raster_div and mul_prod,
  // and the edges never read a gradient. Only a span does. So the fit has its
  // own state (pf_st, S_IDLE when done) and every state that EMITS a span
  // waits for it.
  logic [4:0] pf_st;

  // Latched quad. sx/sy are the raw screen coordinates: the wireframe test
  // compares them whole, so the pre-shift value has to survive.
  logic signed [15:0] sx [0:3];
  logic [3:0]         sf [0:3];      // R626: {fy, fx}
  // the plane fit's vertex positions, in quarters when FRB
  function automatic logic signed [15:0] p4(input logic signed [15:0] v, input logic [1:0] f);
    p4 = (FRB == 0) ? v : ((v <<< 2) + 16'(f));
  endfunction
  localparam logic signed [8:0] NET0 = (FRB == 0) ? 9'sd9 : 9'sd11;   // 8.8, and the 4 undone
  localparam int unsigned BPS = (FRB == 0) ? 8 : 6;
  // R791: the same products into the u/v planes' UVS fraction bits
  localparam int unsigned BPS_UV = BPS + (18 - UZF) - 16;
  logic signed [15:0] sy [0:3];
  logic [23:0]        col;
  logic               moire;

  // 16.16 x, exactly as fill_quad forms it: an int32 left shift that discards
  // everything above bit 15.
  logic signed [31:0] px [0:3];
  // R658: the EDGE y of each vertex -- in quarters with M2COV, else the integer
  logic signed [15:0] sye [0:3];
  always_comb begin
    for (int i = 0; i < 4; i++) begin
      // signed throughout: a clipped vertex sits at x = -1
      // R662: 16.16 of the quarter position is a CONCATENATION -- the integer,
      // the two quarter bits, zeros. It was 32'(signed'(4x + f)) <<< 14, and
      // Quartus 17.0 folds signed'() around a sum holding $signed({..}) to
      // nothing: every x came out 0 (or -1), every polygon zero wide, and s572
      // drew no 3D at all. Verilator computes it as written.
      px[i]  = M2COV ? $signed({sx[i], sf[i][1:0], 14'd0})
                     : $signed({sx[i], 16'h0000});
      sye[i] = M2COV ? ((sy[i] <<< 2) + $signed({14'd0, sf[i][3:2]})) : sy[i];
    end
  end
  // R658: a quarter-unit y to the first row whose centre is at or below it:
  // round(y) = floor(y) + (frac > 1/2), which in quarters is (y + 1) >> 2
  function automatic logic signed [15:0] rq(input logic signed [15:0] yq);
    rq = (yq + 16'sd1) >>> 2;
  endfunction

  // Chain state. Edge A walks ps1 downward, edge B walks ps2 upward, both from
  // the top vertex. The doubled 8-entry array in MAME exists to let them run in
  // opposite directions without wrapping logic; here the index is 3 bits and
  // the array read masks to 2.
  logic [2:0]         ps1, ps2;
  logic signed [31:0] xa, xb;     // 16.16 accumulators
  // R659: xa/xb + 0x7FFF, kept in step with them (every later write is +delta),
  // so M2COV's round-to-nearest is a bit slice and not an adder in front of
  // uv_at's multiply -- that adder cost s566-s568 4 ns on clk_sys.
  logic signed [31:0] xah, xbh;
  logic signed [31:0] sla, slb;   // 16.16 per scanline
  // R944 (DIL): which of an edge's two vertices has the lesser x (lo_*: the
  // one it starts from); fr_*: the edge was reloaded and has not been moved
  // out yet; and the segment's span clamps -- lbq bounds round(x) of the LEFT
  // edge by its vertices' least x - 1/8, ubq round(x) - 1 of the RIGHT edge
  // by their greatest + 1/8 -- applied as a span leaves stage 1 (off R739's
  // emit path). The move itself is no register: S_FS_DIL forms it from the
  // edge's own slope.
  logic               lo_a, lo_b;
  logic               fr_a, fr_b;
  logic signed [15:0] lbq, ubq;
  // R944: ONE ADDER PER EDGE for the row step and the move: xah + sla in
  // S_FS_WALK, xah + (t or ~t) + (C or 1 - C) in S_FS_DIL (a ternary add)
  wire                dil_st = DIL && (state == S_FS_DIL);
  wire  signed [31:0] dta = sla >>> 3, dtb = slb >>> 3;
  wire  signed [31:0] xah_nx = xah + (!dil_st ? sla : ((swapf == sla[31]) ? ~dta : dta))
                                   + (!dil_st ? 32'sd0 : (swapf ? 32'sh0000_2001 : 32'shFFFF_E000));
  wire  signed [31:0] xbh_nx = xbh + (!dil_st ? slb : ((!swapf == slb[31]) ? ~dtb : dtb))
                                   + (!dil_st ? 32'sd0 : (swapf ? 32'shFFFF_E000 : 32'sh0000_2001));
  logic signed [15:0] cury, limy;
  logic               need_a, need_b;

  // Segment state.
  logic signed [15:0] seg_y1;     // exclusive bottom of this segment
  logic signed [15:0] walk_y, walk_end;
  logic               swapf;
  logic               skip_only;  // segment is entirely above the viewport
  logic [1:0]         emit_mode;
  logic signed [31:0] flat_lo, flat_hi;   // 16.16: they feed emit_l/emit_r

  // ------------------------------------------------------- R274: the texture
  //
  // AFFINE, AND SAID SO PLAINLY. The reference divides u and v by z per PIXEL
  // and this does not: it fits ONE plane to the quad and steps along it. On a
  // polygon whose corners are at very different depths -- the road running to
  // the horizon is the case -- the texture will swim, exactly as it does on a
  // console of the same generation. The perspective divide needs 1/z per
  // vertex carried through the quad store, which is 26 more M10K blocks than
  // this part has, and getting the textures ON is worth more than getting them
  // flat-correct. The shape of this code does not change when they arrive: the
  // same plane fit runs on u/z, v/z and 1/z instead of on u and v.
  //
  // ONE PLANE PER QUAD, NOT A DIVIDE PER SPAN. Interpolating along the edges
  // the way the reference's scanline converter does needs two divides a SPAN;
  // a plane fit needs four a QUAD, and the fill already owns two dividers that
  // are idle until the first edge slope.
  // R337: AFTER NORMALISATION qu AND qv HOLD u/z AND v/z, not u and v. The raw
  // coordinate is never wanted again, so reusing these arrays costs nothing
  // where keeping both would be ~200 ALM of registers.
  // R791: 13 + UZF bits once rewritten as u/z (the raw u in the low 13 first).
  localparam int unsigned UW  = 13 + UZF;
  localparam int unsigned UW1 = UW + 1;            // a signed difference of two
  localparam int unsigned UVS = 18 - UZF;          // the u/v plane values' fraction bits
  logic [UW-1:0]      qu [0:3], qv [0:3];
  // 1/z on a scale common to the quad: the largest of the four fills bit 15.
  logic [15:0]        qoz [0:3];
  logic [1:0]         oz_i;              // which vertex the normaliser is on
  logic [7:0]         oz_emax;           // largest exponent of the four, latched
  // R731: S_OZ's first cycle only computes oz_emax, from the latched qoz --
  // off the INPUTS at acceptance it was m2_quad_store|vtx_r -> oz_emax, 0.735
  // ns at 75 MHz (s759), short of 80. Every 5-bit pf_st is taken, so a flag
  // rather than a state; one cycle per textured quad.
  logic               oz_pre;

  // R337: the four exponents and the largest, combinational off the INPUTS
  // because emax has to be known before the first vertex is rewritten.
  // R731: now off the latched copies, in S_OZ's first cycle (oz_pre). They
  // are qoz exactly as accepted: nothing rewrites qoz before stage two.
  wire [7:0] oze01_q = (qoz[1][15:8] > qoz[0][15:8]) ? qoz[1][15:8] : qoz[0][15:8];
  wire [7:0] oze23_q = (qoz[3][15:8] > qoz[2][15:8]) ? qoz[3][15:8] : qoz[2][15:8];
  wire [7:0] oz_emax_q = (oze23_q > oze01_q) ? oze23_q : oze01_q;

  // One minifloat to the quad's common fixed scale. The implicit 1 is restored,
  // the mantissa shifted up so the largest lands on bit 15, and the difference
  // in exponent shifts it down. A vertex more than 15 octaves behind the
  // nearest normalises to zero, which is "infinitely far" and is what the
  // error model measured as the depth-ratio limit.
  function automatic logic [15:0] oz_norm(input logic [15:0] mf, input logic [7:0] emax);
    logic [8:0] full;
    logic [7:0] d;
    begin
      full = {1'b1, mf[7:0]};
      d    = emax - mf[15:8];
      // BIT 14, NOT BIT 15. The plane fit forms 16-bit SIGNED differences of
      // these (pf_o1 = qoz[fb] - qoz[fa]), so the values must fit 15 bits or
      // every numerator, multiplier and barrel shifter in the fit widens.
      // Largest is 256<<6 = 2^14, up to 511<<6 = 32704 < 2^15.
      oz_norm = (mf[15:8] == 8'd0) ? 16'd0
              : (d >= 8'd16)       ? 16'd0
              : 16'((17'(full) << 6) >> d[3:0]);
    end
  endfunction
  // R618: TWENTY-FOUR BITS, 16.8. At 8.8 a gradient saturated at 128 a
  // pixel, and 1/z -- normalised per quad to ~2^15 at the nearest vertex --
  // moves faster than that on any steep, close polygon (the 3D differential's
  // poly 517: ~313 a pixel vertically, clamped to 128, so every u/z / 1/z
  // divide drifted, 37 texels by the far edge). The planes are modular:
  // base is the value extrapolated to (0,0) and wraps mod 2^32, every
  // product and accumulator wraps with it, and the value at a pixel inside
  // the polygon comes back in range -- so only these registers, their clamp
  // and the queue fields widen.
  logic signed [23:0] dodx, dody;        // the 1/z plane's gradients
  logic signed [31:0] base_o, nxo, nyo;
  logic               pf_c;              // the third fit's second divide is back
  logic [23:0]        tex_r;
  logic               mz_r;      // R828c: in_mipz, latched with the quad
  logic [1:0]         uvs_r;     // R940: in_uvs, latched with the quad
  logic               tex_ok;            // the fit succeeded and the poly is textured
  // SIXTEEN-BIT GRADIENTS, 8.8 TEXELS PER PIXEL (R286). Thirty-two bits of
  // gradient buys nothing a picture can show: the steepest useful slope is a
  // few texels a pixel and 1/256 of a texel of error accumulates to under half
  // a texel across the widest span this screen has. What it costs is every
  // multiplier and every barrel shifter in the fit at double width, on a part
  // with 550 ALMs free.
  logic signed [23:0] dudx, dudy, dvdx, dvdy;   // R618
  logic signed [31:0] det_r;
  // R674: THE FIT TAKES THE BETTER OF ITS TWO TRIANGLES. It fitted on vertices
  // 0,1,2 and fell back to 0,2,3 only when that determinant was exactly zero.
  // A flat quad's u/z, v/z and 1/z ARE planes in screen space, so any three
  // corners give the same plane -- but the corners are quantised (quarter
  // pixels, 13-bit u/v, the 1/z minifloat), and a small triangle magnifies
  // that into the gradients. A thin road strip or a quad with two near-
  // coincident corners (MAME frame 2000's poly 484: det 690 on 0,1,2 against
  // 1,802 on 0,2,3) came out with every pixel's texel wrong -- the "wrong
  // orientation" on the road. Both determinants are now taken, the larger
  // magnitude kept; a triangle (its last corner repeated) gives 0 for 0,2,3.
  logic [31:0]        det_first_abs;
  logic [1:0]         pf_ph;             // 0: 0,1,2 taken  1: 0,2,3 taken  2: chosen
  logic signed [31:0] nxu, nyu, nxv, nyv;
  // R418: THE NORMALISE, SPLIT IN TWO. pf_norm is a 32-bit negate, then clz32,
  // then a 32-bit variable shift -- all in one cycle, and it was the worst path
  // in the design once the physical-synthesis passes stopped hiding it:
  //   m2_raster_fill|nxu[19] -> div_num[28]   -0.762 ns on clk_sys
  //
  // The same cycle also computed pf_clz(nxu) for q_z_a, so the count was done
  // TWICE and the shift chained behind one of them. These hold the count from a
  // cycle earlier; the shift then stands alone. One extra cycle per quad, not
  // per pixel.
  logic [5:0] nxu_z, nyu_z, nxv_z, nyv_z;
  logic [5:0] nxo_z, nyo_z;   // R441: R418's treatment for the 1/z round
  logic               pf_second;         // the fit is retrying on vertices 0,2,3
  logic               pf_x;              // this divide round is the x gradient
  logic signed [31:0] q_num_a, q_num_b;
  // The numerator's leading-zero count, kept from the normalise. Recomputing it
  // when the quotient comes back is a second 32-bit priority encoder for a
  // number that has not changed.
  logic [5:0]         q_z_a, q_z_b;

  // The three vertices the plane is fitted through: 0,1,2 normally, 0,2,3 when
  // those three are collinear on screen -- which every triangle is, because a
  // triangle reaches here as a quad with a repeated vertex.
  wire [1:0] fa = 2'd0;
  wire [1:0] fb = pf_second ? 2'd2 : 2'd1;
  wire [1:0] fc = pf_second ? 2'd3 : 2'd2;

  wire signed [15:0] pf_ax = p4(sx[fb], sf[fb][1:0]) - p4(sx[fa], sf[fa][1:0]);   // R626
  wire signed [15:0] pf_ay = p4(sy[fb], sf[fb][3:2]) - p4(sy[fa], sf[fa][3:2]);
  wire signed [15:0] pf_bx = p4(sx[fc], sf[fc][1:0]) - p4(sx[fa], sf[fa][1:0]);
  wire signed [15:0] pf_by = p4(sy[fc], sf[fc][3:2]) - p4(sy[fa], sf[fa][3:2]);
  wire signed [UW:0] pf_u1 = UW1'({1'b0, qu[fb]}) - UW1'({1'b0, qu[fa]});
  wire signed [UW:0] pf_u2 = UW1'({1'b0, qu[fc]}) - UW1'({1'b0, qu[fa]});
  wire signed [UW:0] pf_v1 = UW1'({1'b0, qv[fb]}) - UW1'({1'b0, qv[fa]});
  // R337: 1/z's, which fit 16-bit signed because oz_norm caps them at bit 14.
  wire signed [15:0] pf_o1 = 16'(qoz[fb]) - 16'(qoz[fa]);
  wire signed [15:0] pf_o2 = 16'(qoz[fc]) - 16'(qoz[fa]);
  wire signed [UW:0] pf_v2 = UW1'({1'b0, qv[fc]}) - UW1'({1'b0, qv[fa]});

  // R638: THE SCREEN DIFFERENCES, REGISTERED FOR THE NUMERATORS. R626's
  // quarter-pixel positions put p4() and the fb/fc select in front of the
  // multiply, and s420-s422 failed clk_sys by 0.68-0.80 ns on exactly that:
  //   m2_raster_fill|sx -> m2_raster_fill|nxu
  // (s412 met it by luck). Loaded every cycle. The numerators are formed in
  // S_PF_N at the earliest; pf_second last changes in S_PF_N and S_PF_D
  // follows, and qu/qv/qoz last change in the final S_OZ cycle, so every
  // operand has been stable for a cycle by then and the registers hold the
  // same values the wires do.
  // R727: det_r reads them too. At 75 MHz the vertex select, p4() and the
  // subtract in front of the determinant's multiply failed clk_sys (s752,
  // qu -> det_r -0.523). S_PF_D is entered from S_OZ with pf_second unchanged
  // for many cycles, and through S_PF_DW whenever S_PF_N may have changed it,
  // so pr_* always hold what the wires would.
  logic signed [15:0] pr_ax, pr_ay, pr_bx, pr_by;
  // R727: and the texture differences, for the same reason (s752: qu -> nxu
  // -0.519 at 75 MHz). Same argument: qu/qv/qoz last change in the final
  // S_OZ cycle and pf_second two states before S_PF_N reads these.
  // R791: UW + 1 bits signed (18 at UZF 4) -- still an 18x19 DSP operand.
  logic signed [UW:0] pr_u1, pr_u2, pr_v1, pr_v2;
  logic signed [15:0] pr_o1, pr_o2;
  always_ff @(posedge clk) begin
    pr_ax <= pf_ax; pr_ay <= pf_ay; pr_bx <= pf_bx; pr_by <= pf_by;
    pr_u1 <= pf_u1; pr_u2 <= pf_u2; pr_v1 <= pf_v1; pr_v2 <= pf_v2;
    pr_o1 <= pf_o1; pr_o2 <= pf_o2;
  end
  // R847: THE DETERMINANT'S TWO PRODUCTS, REGISTERED EVERY CYCLE FROM pr_*.
  // det_r = ax*by - bx*ay was one cycle of multiply and subtract, and Quartus
  // SHARED its multipliers with nxo's (o1*by - o2*ay: the same by and ay, a
  // different state), so the path was pr_* -> the operand mux -> one DSP ->
  // a second DSP's adder -> det_r: s1129-s1131 -0.35 .. -0.55 ns, 160-422
  // paths a seed (pf_st.S_PF_N, the mux's select, and pr_o1 -> det_r / nxo).
  // Loaded every cycle, with no reset and no enable, these cannot be shared
  // and pack into their DSP's output registers; det_r subtracts them a cycle
  // later. They follow pr_* by a cycle, so S_PF_DW now waits two cycles
  // (dw_2) -- one more cycle per pass through it, two or three a quad.
  logic signed [31:0] dp_ab, dp_ba;
  always_ff @(posedge clk) begin
    dp_ab <= 32'(pr_ax) * 32'(pr_by);
    dp_ba <= 32'(pr_bx) * 32'(pr_ay);
  end
  logic dw_2;   // R847: S_PF_DW's second cycle

  // A DIVIDE THAT KEEPS ITS BITS. The gradient is a fraction -- texels per
  // pixel, usually between 1/16 and 16 -- and an integer divider returns zero
  // for all of it. So the numerator is normalised UP until its top bit is at
  // 30 and the denominator DOWN until it fits in sixteen bits, the quotient is
  // taken, and the shift is undone afterwards. That leaves at least fifteen
  // significant bits in every quotient, where scaling only the numerator by a
  // fixed amount would overflow on a large polygon and lose everything on a
  // small one.
  function automatic [5:0] clz32(input logic [31:0] x);
    logic [5:0] n;
    begin
      n = 6'd32;
      for (int i = 31; i >= 0; i--) if (x[i] && n == 6'd32) n = 6'(31 - i);
      clz32 = n;
    end
  endfunction

  wire [31:0] det_abs = det_r[31] ? (~det_r + 32'd1) : det_r;
  // R594: 70 MHz. The negate and the encode were still one cycle (s319:
  // det_r -> den_sh, -0.14 ns); the magnitude is registered first.
  logic [31:0] det_abs_r;
  // Bits the denominator must lose to fit in sixteen: 16 - clz32 when that is
  // positive. R727: computed from the top half alone -- a top bit at p >= 16
  // gives clz 31 - p, so the answer is p - 15, which is that bit's index in
  // det_abs_r[31:16] plus one, and 0 when the top half is clear. The same
  // number without the 32-bit encode and the subtract behind it (s755:
  // det_abs_r -> den_sh -0.181 at 75 MHz).
  function automatic logic [5:0] den_shift(input logic [15:0] h);
    logic [5:0] n;
    begin
      n = 6'd0;
      for (int i = 0; i < 16; i++) if (h[i]) n = 6'(i + 1);
      den_shift = n;
    end
  endfunction
  wire [5:0]  den_sh_c = den_shift(det_abs_r[31:16]);
  // REGISTERED, AND THAT IS THE WORST PATH IN THE DESIGN (R289). `den_sh` is a
  // 32-bit priority encode of the determinant, and `pf_scale` uses it to work
  // out how far to shift the quotient back. Left combinational, the path runs
  //   det_r -> abs -> clz32 -> den_sh -> net -> 40-bit barrel shift -> clamp
  //   -> dvdx
  // in ONE cycle, and report_timing named exactly that: `clz32~6 ->
  // dvdx[8]`, -0.365 ns. The determinant is known a full state before the
  // quotient comes back, so the encode costs nothing where it is done once.
  logic [5:0] den_sh;
  wire signed [31:0] den_n = det_r >>> den_sh;

  // R441: SIX DIVIDES BY THE SAME NUMBER BECOME ONE RECIPROCAL AND SIX
  // MULTIPLIES.
  //
  // Every plane-fit divide assigns `den_n` -- lines for dudx, dudy, dvdx, dvdy
  // and, since orientation, dodx and dody. m2_raster_div is radix-4 restoring,
  // 16 cycles, and its 256-entry table only helps for |den| < 256. den_sh
  // normalises the determinant to SIXTEEN significant bits, so |den_n| sits
  // around 2^15 and every one of the six takes the slow path: 96 cycles a
  // textured quad, of the 179 that R430 measured a quad to retire.
  //
  // den_n at 16 bits is exactly m2_persp_recip's input range, and that unit is
  // already exhaustively verified -- all 65,535 inputs, worst relative error
  // 0.0072%. One instance, two cycles, and each gradient is then a multiply.
  //
  // The dividers STAY: the edge-slope walk still uses them, and its denominator
  // is a scanline count, not this one.
  // FED FROM THE COMBINATIONAL den_sh_c, NOT THE REGISTERED den_sh. The unit
  // needs two cycles and `den_sh` only becomes valid entering S_PF_NRM, which
  // is one state before S_PF_Q1 -- so the first gradient read a STALE
  // reciprocal and saturated pf_scale at 127.996. det_r is settled a state
  // earlier, so this form is valid from S_PF_N and the answer is ready in time.
  // Identical in value: den_sh is den_sh_c registered.
  // R449: THE DENOMINATOR IS REGISTERED BEFORE THE RECIPROCAL SEES IT.
  //
  // R441 fed this from the COMBINATIONAL den_sh_c so the unit would have two
  // cycles. That put the determinant's priority encode, its variable shift and
  // an abs IN FRONT OF the reciprocal's own priority encode, shift and table
  // read -- two encoders and two shifters in one cycle:
  //
  //   m2_raster_fill|det_r[4] -> m2_persp_recip|u_denr|s1_r0[6]   -9.944 clk_sys
  //
  // That, not the ROM contents and not the area, is why every build of the
  // reciprocal plane fit died. Registered in S_PF_N instead, and S_PF_NRM takes
  // the extra cycle the unit needs -- one cycle a quad, against the 86 this
  // saves.
  logic [15:0] den_a;
  wire [31:0] den_rcp;
  m2_persp_recip u_denr (.clk(clk), .rst_n(rst_n), .in_d(den_a), .out_q(den_rcp));

  // R442: ONE MULTIPLIER, MUXED -- NOT SIX.
  //
  // R441 called rquo() from each of the six S_PF_Q* states and Quartus built a
  // multiplier for every one: +900 ALM and +11 DSP, and the fit failed at 101%.
  // AUTO_RESOURCE_SHARING did not fold them even though the states are mutually
  // exclusive.
  //
  // So the operands are registered and the product computed in ONE place. Each
  // state presents the next numerator and latches the previous gradient, which
  // costs one extra state at the end -- S_PF_B already exists and does it.
  // R450: THE PRODUCT IS REGISTERED BEFORE pf_scale SEES IT.
  //
  // R449 fixed the reciprocal's INPUT path and the output side then showed:
  //   m2_persp_recip|out_q[10] -> m2_raster_fill|dvdx[0]   -1.825 on clk_sys
  // a 64-bit multiply chained straight into pf_scale's 40-bit bidirectional
  // barrel shift and saturate. Same defect, other end of the same module.
  //
  // mul_q_r/mul_zr hold the product for a cycle, so each gradient is now
  // present-operands, multiply, scale: three stages rather than two. S_PF_B
  // takes two cycles because the bases need all six gradients and the last
  // one only lands on its first.
  logic signed [31:0] mul_q_r;
  logic        [5:0]  mul_zr;
  logic signed [8:0] net_r;   // R459: pf_scale's shift amount, a cycle early
  logic              zbig_r;  // R459: mul_zr >= 32, likewise
  // R594: 70 MHz. pf_scale_n's 40-bit bidirectional shift and its saturate
  // were still one cycle (s319: net_r -> dvdx, -0.17 ns). The shift is now
  // registered every cycle into sc_r and saturated the cycle after, so each
  // gradient lands one state later than it did; S_PF_B gains one cycle for
  // dody. Same values: sc_r is the shift of exactly the operands the old
  // single-cycle form read, taken one state earlier.
  logic signed [39:0] sc_r;
  // R727: and the saturate registered too, every cycle (s754: sc_r -> dudy
  // -0.539 at 75 MHz). Each gradient lands one more state later again, and
  // S_PF_B gains a third cycle for dody.
  logic signed [23:0] sc_s;
  logic               b_w2, b_w3;
  logic               b_wait;
  // R566: 60 MHz. The normaliser and the plane's base each did too much in one
  // cycle (s297: oz_i -> qv +2.601, sx -> base_u +2.700 at 50 MHz). Each now
  // takes one more: the normaliser is PIPELINED -- vertex k+1 is selected and
  // normalised while vertex k is multiplied, five cycles for four vertices
  // rather than eight (doubling it cost the heavy bench scene 16% of its
  // pixels: on small quads the fit is the fill's critical path) -- and
  // b_prod registers the six plane products, with no reset so they can pack
  // into the DSP blocks' own output registers, before the subtracts.
  logic               oz_w_v, oz_last, b_prod;
  logic [1:0]         oz_w;
  logic [15:0]        oz_n;
  logic [12:0]        oz_u, oz_v;   // the raw u, v: 13 bits
  logic signed [31:0] bp_ux, bp_uy, bp_vx, bp_vy, bp_ox, bp_oy;
  logic signed [31:0] bh_u, bh_v, bh_o;   // R616: half a pixel of each plane, both axes
  logic [UW-1:0]      bq_u, bq_v;   // R791
  logic [15:0]        bq_o;
  logic         [2:0] nrm_wait;   // R466/R599/R731: five cycles, the recip takes five
  logic [1:0] pfn_wait;   // R461/R594: S_PF_N takes three cycles: abs, encode, shift
  logic signed [31:0] mul_n;
  logic        [5:0]  mul_z;
  wire signed  [31:0] mul_q = rquo(mul_n, den_rcp, den_n[31]);

  // num / den_n, as num * (2^30/|den_n|) >> 30 with the sign put back. One
  // multiply, and ONE PER STATE -- the six below are sequenced, not parallel,
  // so this is a single multiplier reused six times rather than six of them.
  function automatic logic signed [31:0] rquo(input logic signed [31:0] num,
                                              input logic [31:0] rcp,
                                              input logic neg);
    logic signed [63:0] a64, b64, p;
    logic signed [31:0] q;
    begin
      // BOTH OPERANDS WIDENED FIRST. Verilog sizes a multiply by its OPERANDS,
      // not by what it is assigned to: written `$signed(num) * $signed({1'b0,
      // rcp})` the product is computed at 33 bits and truncated before it ever
      // reaches this 64-bit variable. The gradients then saturate pf_scale at
      // 127.996 -- and the fuzz corpus happened to miss it until the R430 test
      // was inserted ahead of it and reshuffled the RNG.
      a64 = 64'(num);
      b64 = {32'd0, rcp};
      p   = a64 * b64;
      q   = 32'(p >>> 30);
      rquo = neg ? -q : q;
    end
  endfunction

  // R584: pf_clz's first half, on its own.
  function automatic logic [31:0] pf_abs(input logic signed [31:0] n);
    pf_abs = n[31] ? (~n + 32'd1) : n;
  endfunction
  // R952: ONE NORMALISER FOR THE SIX NUMERATORS, A NUMERATOR A CYCLE (the
  // magnitude, the halves' counts and the join, R584 / R735's stages, in a
  // pipeline that S_PF_N's second cycle starts -- nxu..nyo landed the cycle
  // before and hold until the next fit). Each count is joined exactly when
  // the six-wide version joined it or earlier: nxu_z on NRM's wait 2 (as
  // before), nyu_z on 3, nxv_z on 4, nyv_z on Q1, nxo_z on Q1W, nyo_z on Q2
  // -- each the cycle before nz_c first takes it (R742's schedule: wait 3,
  // wait 4, Q1, Q1W, Q2, Q2W), and nz_c reads no count before that.
  logic [2:0]  nz_k;                       // the numerator entering, 0..5
  logic        nz_run, nz_vs, nz_va, nz_vc;
  logic [2:0]  nz_ks, nz_ka, nz_kc;
  logic [31:0] nz_sel, nz_abs;
  logic [4:0]  nz_h, nz_l;
  // R735: AND THE COUNT IN TWO HALVES. clz32 was one cycle (s784 at 80 MHz:
  // a_nyu -> nyu_z -0.737, a_nyo -> nyo_z). Each 16-bit half is counted on
  // nrm_wait 1 and the two combined on 2; the first reader is the state's
  // last cycle (4), so no cycle is added and the counts are the same numbers.
  function automatic logic [4:0] clz16(input logic [15:0] x);
    logic [4:0] n;
    begin
      n = 5'd16;
      for (int i = 15; i >= 0; i--) if (x[i] && n == 5'd16) n = 5'(15 - i);
      clz16 = n;
    end
  endfunction
  // {top half's count, bottom half's count}, each 0..16
  function automatic logic [5:0] clz_join(input logic [4:0] h, input logic [4:0] l);
    clz_join = (h == 5'd16) ? 6'(6'd16 + 6'(l)) : 6'(h);
  endfunction

  function automatic logic [5:0] pf_clz(input logic signed [31:0] n);
    logic [31:0] a;
    begin
      a = n[31] ? (~n + 32'd1) : n;
      pf_clz = clz32(a);
    end
  endfunction

  // Normalise the numerator so its top bit sits at 30, which is what leaves
  // the quotient its significant bits.
  // R418: the shift half of pf_norm, given a count worked out earlier.
  function automatic logic signed [31:0] pf_shift(input logic signed [31:0] n,
                                                  input logic [5:0] z);
    begin
      if (z >= 6'd32 || z == 6'd0) pf_shift = n;
      else                         pf_shift = n <<< (z - 6'd1);
    end
  endfunction

  function automatic logic signed [31:0] pf_norm(input logic signed [31:0] n);
    logic [31:0] a;
    logic [5:0]  z;
    begin
      a = n[31] ? (~n + 32'd1) : n;
      z = clz32(a);
      if (z >= 6'd32 || z == 6'd0) pf_norm = n;      // zero, or already at the top
      else                         pf_norm = n <<< (z - 6'd1);
    end
  endfunction

  // Undo both shifts: the quotient is (num << (z-1)) / (det >> den_sh), so the
  // 16.16 answer is that times 2^(16 - (z-1) - den_sh).
  // RETURNS SIXTEEN BITS, because the answer is an 8.8 gradient clamped to
  // +/-32767 and because Quartus 17.0 will not index a function call's result
  // -- `pf_scale(...)[15:0]` is a syntax error there where Verilator takes it.
  function automatic logic signed [15:0] pf_scale(input logic signed [31:0] q,
                                                  input logic [5:0] z);
    logic signed [8:0]  net;
    logic signed [39:0] r;
    begin
      if (z >= 6'd32) pf_scale = 16'sd0;
      else begin
        net = NET0 - 9'(z) - 9'(den_sh);   // 8.8, not 16.16 (R626: NET0)
        // FORTY BITS, NOT SIXTY-FOUR. The answer is clamped to +/-2^27 two
        // lines below, so everything above bit 39 is thrown away -- and a
        // 64-bit bidirectional barrel shifter is twice the logic of a 40-bit
        // one on a path that is already the widest thing in this module.
        r   = (net >= 9'sd0) ? (40'(q) <<< net[5:0]) : (40'(q) >>> (-net));
        // A gradient of 2,048 texels a pixel is already nonsense; clamping
        // keeps a degenerate quad from wrapping the accumulator instead.
        if      (r >  40'sd32767) pf_scale =  16'sd32767;
        else if (r < -40'sd32767) pf_scale = -16'sd32767;
        else                      pf_scale =  16'(r);
      end
    end
  endfunction

  // R459: THE SHIFT AMOUNT, PRECOMPUTED. Same arithmetic as pf_scale above,
  // split so the two 9-bit subtractions and the 6-bit compare do not sit in
  // series with the 40-bit bidirectional barrel shifter.
  //
  //   m2_raster_fill|mul_zr[1] -> m2_raster_fill|dvdy[*]   19.652 ns / 20.000
  //
  // was the worst clk_sys path on s117 after R457 moved the previous one, and
  // all 37 failing endpoints at 60 MHz were dudx/dudy/dvdx/dvdy -- every one
  // written by this single expression.
  //
  // `net` depends only on mul_z and den_sh. den_sh is registered entering
  // S_PF_NRM and does not move again for the quad, and mul_z is registered a
  // cycle before pf_scale reads it, so both are available in the cycle that
  // registers mul_zr. Computing it there is exact, not an approximation, and
  // costs no cycles: that cycle already only captures a result.
  function automatic logic signed [39:0] pf_gshift(input logic signed [31:0] q,
                                                  input logic signed [8:0]  net,
                                                  input logic               zbig);
    begin
      if (zbig) pf_gshift = 40'sd0;
      else      pf_gshift = (net >= 9'sd0) ? (40'(q) <<< net[5:0]) : (40'(q) >>> (-net));
    end
  endfunction

  function automatic logic signed [23:0] pf_sat(input logic signed [39:0] r);
    begin
      if      (r >  40'sd8388607) pf_sat =  24'sd8388607;   // R618
      else if (r < -40'sd8388607) pf_sat = -24'sd8388607;
      else                        pf_sat =  24'(r);
    end
  endfunction

  logic signed [31:0] base_u, base_v;   // u,v at screen (0,0) on the fitted plane
  // ONE EVALUATION OF THE PLANE, NOT THREE. The three emit sites -- the flat
  // quad, the segment walk and the fill_line tail -- all emit at `emit_cl` and
  // at a y that is either cury or walk_y, so one expression serves them all.
  // Written out at each site it was six multiply-add pairs instead of two, and
  // this module is what put the design over the device.
  // R715: AND ONE CYCLE LATER, FROM REGISTERS. At 80 MHz the emit cycle --
  // the edge x, the sort and viewport clamp into emit_cl, the plane's DSP
  // multiply and the add into span_v -- was 22.5 ns against 12.5 (s728,
  // -1.696). An emit now fills stage 1 (s1_*: the row, the clamped ends, the
  // colour); the next cycle moves it to the span output and evaluates the
  // plane at s1_cl / s1_y. A new quad is not accepted until stage 1 is empty,
  // so the gradients the plane uses are still this span's quad's.
  logic               s1_valid, s1_moire;
  logic signed [15:0] s1_y, s1_cl, s1_cr;
  // R944: a span leaving stage 1, cut to its edges' extents +/- 1/8 (DIL; the
  // whisker a shallow edge moved out would put past its end vertex). A flat
  // quad's span only -- the plane below is evaluated at s1_cl, which a
  // textured span (never clamped) keeps. lbq / ubq change only while stage 1
  // is empty (S_FS_DIL waits), so they are always the span's own segment's.
  wire                s1_dc = DIL && !tex_r[0];
  wire  signed [15:0] s1_x0 = (s1_dc && (s1_cl < lbq)) ? lbq : s1_cl;
  wire  signed [15:0] s1_x1 = (s1_dc && (s1_cr > ubq)) ? ubq : s1_cr;
  logic [23:0]        s1_col;
  wire                s1_adv  = s1_valid && (!span_valid || span_ready);
  wire                s1_free = !s1_valid || s1_adv;
  wire signed [31:0] emit_u  = uv_at_uv(base_u, dudx, dudy, s1_cl, s1_y);   // R791
  wire signed [31:0] emit_v  = uv_at_uv(base_v, dvdx, dvdy, s1_cl, s1_y);
  wire signed [31:0] emit_o  = uv_at(base_o, dodx, dody, s1_cl, s1_y);   // R337

  logic               pf_a, pf_b;        // the two plane-fit divides, back

  // u (or v) at a pixel, on the fitted plane. The units are the stored ones --
  // quarter-texels -- with sixteen fractional bits, and the texel fetch takes
  // its own eight by shifting this right by ten.
  // THIRTY-TWO BITS, NOT FORTY-EIGHT, AND THAT IS 1,600 ALUTs. The answer is
  // truncated to 32 either way -- it is a 16.16 coordinate -- but writing the
  // arithmetic in a 48-bit context makes the synthesiser build 48x48
  // multipliers to produce bits that are then thrown away. `m2_raster_fill`
  // went from 3,854 ALUTs to 5,460 on the build where the texture path first
  // survived constant-propagation, and this expression was most of it.
  // The gradient is 8.8 and the answer is 16.16, so each product -- 16 x 16,
  // one DSP -- is shifted up by eight on its way in.
  function automatic logic signed [31:0] uv_at(input logic signed [31:0] base,
                                               input logic signed [23:0] gx,   // R618
                                               input logic signed [23:0] gy,
                                               input logic signed [15:0] x,
                                               input logic signed [15:0] y);
    logic signed [31:0] gxp, gyp;
    begin
      gxp = gx * x;
      gyp = gy * y;
      uv_at = base + (gxp <<< 8) + (gyp <<< 8);
    end
  endfunction
  // R791: the same for u/z and v/z, whose values carry UVS fraction bits
  // rather than 16 -- the 8-fraction-bit products shift up by UVS - 8.
  function automatic logic signed [31:0] uv_at_uv(input logic signed [31:0] base,
                                                  input logic signed [23:0] gx,
                                                  input logic signed [23:0] gy,
                                                  input logic signed [15:0] x,
                                                  input logic signed [15:0] y);
    logic signed [31:0] gxp, gyp;
    begin
      gxp = gx * x;
      gyp = gy * y;
      uv_at_uv = base + (gxp <<< (UVS - 8)) + (gyp <<< (UVS - 8));
    end
  endfunction
  logic [2:0]         ps1m1, ps2p1;
  logic signed [15:0] ya_next, yb_next;
  always_comb begin
    ps1m1   = ps1 - 3'd1;
    ps2p1   = ps2 + 3'd1;
    ya_next = sye[ps1m1[1:0]];   // R658
    yb_next = sye[ps2p1[1:0]];
  end

  // ---------------------------------------------------------------- dividers
  // TWO, because the two edge slopes are independent and the fill needs both
  // before it can decide anything. Issued one after the other through a single
  // divider they were 49% of the fill unit's time on the reference's peak frame
  // (tb_m2_raster3d, frame 1020: DIVAW+DIVBW 49%, the span walk 31%), and on
  // the board the slowest band each second ran 1.3-1.7 beam slots and went up
  // late - a bar with no 3D across the screen. Issuing both at once halves
  // that wait for a divider's worth of ALM.
  logic               div_start, divb_start;
  logic signed [31:0] div_num, div_den, divb_num, divb_den;
  logic               div_ready, div_valid, div0_unused;
  logic               divb_ready, divb_valid, div0b_unused;
  logic signed [31:0] div_quo, divb_quo;
  logic               got_a, got_b;   // which slopes have come back this segment

  // ONE TABLE FOR BOTH. See m2_recip_rom.
  logic [7:0]  rom_a_addr, rom_b_addr;
  wire [31:0]  rom_a_data, rom_b_data;

  m2_recip_rom u_recip (
    .clk(clk),
    .a_addr(rom_a_addr), .a_data(rom_a_data),
    .b_addr(rom_b_addr), .b_data(rom_b_data)
  );

  m2_raster_div u_div (
    .clk       (clk),
    .rst_n     (rst_n),
    .rom_addr  (rom_a_addr),
    .rom_data  (rom_a_data),
    .in_valid  (div_start),
    .num       (div_num),
    .den       (div_den),
    .ready     (div_ready),
    .out_valid (div_valid),
    .quo       (div_quo),
    .div0      (div0_unused)
  );

  m2_raster_div u_divb (
    .clk       (clk),
    .rst_n     (rst_n),
    .rom_addr  (rom_b_addr),
    .rom_data  (rom_b_data),
    .in_valid  (divb_start),
    .num       (divb_num),
    .den       (divb_den),
    .ready     (divb_ready),
    .out_valid (divb_valid),
    .quo       (divb_quo),
    .div0      (div0b_unused)
  );

  // ------------------------------------------------------------- multiplier
  // Shared by the two viewport-skip paths in fill_slope, which advance an edge
  // by delta scanlines in one step. Only the low 32 bits are kept, which is
  // what the C does on int32 and is also what makes an iterative skip and this
  // multiply agree bit for bit.
  // R594: 70 MHz. mul_delta is a difference of two 16-bit rows, so seventeen
  // bits hold it exactly; at 32 the multiply was 32x32 and chained into the
  // accumulate (s319: -> xa, -0.04 ns). The low 32 bits are unchanged.
  logic signed [16:0] mul_delta;
  logic signed [31:0] mul_sl;
  // R631: THE PRODUCT IS REGISTERED BEFORE IT IS ADDED. 17 x 32 then a 32-bit
  // add in one 70 MHz cycle was s410's failing path (mul_sl -> xa/xb[28..31],
  // -0.230), and bit 31 is the sign of every edge that starts left of the
  // screen: on the board, streaks across the picture. S_FS_MULA and
  // S_FS_MULB each take two cycles now (mul_w), twice per clipped segment.
  logic signed [31:0] mul_pr;
  logic [1:0]         mul_w;   // R740: three cycles a multiply, not two
  // R740: AND THE MULTIPLY IN TWO HALVES. A 17 x 32 product is two DSPs and
  // an adder in one cycle (s788 at 80 MHz: mul_sl -> mul_pr -0.745). The
  // halves are 17 x 16 each -- one DSP apiece -- registered, then summed into
  // mul_pr: the low 32 bits of delta * sl are delta * sl[15:0] (unsigned) plus
  // (delta * sl[31:16] (signed)) << 16; checked on 1,000,000 pairs with every
  // extreme. One cycle more on each of S_FS_MULA / MULB.
  logic signed [33:0] mul_plo;
  logic signed [32:0] mul_phi;
  // declared operands, not $signed({..}) inline (R662's Quartus 17.0 fold)
  wire  signed [16:0] mul_sl_lo = {1'b0, mul_sl[15:0]};
  wire  signed [15:0] mul_sl_hi = mul_sl[31:16];

  // ------------------------------------------------------- vertex selection
  // Tournaments, arranged so the lowest index wins every tie. MAME scans
  // linearly with a strict comparison, which has the same effect, and the tie
  // rule decides which vertex a degenerate quad starts from.
  logic [1:0] pmin01, pmin23, pmin_c, pmax01, pmax23, pmax_c;
  // R735: THE FIRST ROUND AT ACCEPTANCE. At 80 MHz sy -> the two rounds ->
  // symin failed (s784: -0.647, 8 endpoints; sy -> pmin_r -0.189). The four
  // first-round comparisons are made from the INPUTS as the quad is latched
  // (they are the same y the registers then hold), so S_MINMAX does the final
  // round only. Nothing changes sy/sf between acceptance and S_MINMAX, which
  // is entered from acceptance alone. The extended y is a concatenation,
  // {y[13:0], fy}, which is what (y <<< 2) + fy is in sixteen bits -- no
  // signed'() around a sum (R662).
  logic m01_r, m23_r, x01_r, x23_r;
  // R740: and the pairs' winning VALUES with them, so the final round is one
  // compare and a 2:1 select (s788 at 80 MHz: m01_r -> symin -0.367, 11):
  // lo01_v == sye[pmin01] and so on, the same y as accepted.
  logic signed [15:0] lo01_v, lo23_v, hi01_v, hi23_v;
  // R743: and those values formed in S_MINMAX's first cycle (mm_pre) from the
  // latched sye and the acceptance's compare bits, not at acceptance -- there
  // they lengthened the store's output -> fill path (s799 at 80 MHz: vtx_r ->
  // hi01_v -0.489). One cycle more per quad.
  logic               mm_pre;
  wire  m_fin = lo23_v < lo01_v;   // pmin23 strictly lower: the tie goes to 0/1
  wire  x_fin = hi23_v > hi01_v;
  function automatic logic signed [15:0] ye_in(input logic signed [15:0] y, input logic [1:0] f);
    ye_in = M2COV ? $signed({y[13:0], f}) : y;
  endfunction
  always_comb begin
    pmin01 = m01_r ? 2'd1 : 2'd0;   // R658: on the edge y
    pmin23 = m23_r ? 2'd3 : 2'd2;
    pmin_c = m_fin ? pmin23 : pmin01;   // R740
    pmax01 = x01_r ? 2'd1 : 2'd0;
    pmax23 = x23_r ? 2'd3 : 2'd2;
    pmax_c = x_fin ? pmax23 : pmax01;   // R740
  end

  // R301: THE TOURNAMENT'S ANSWER, LATCHED. Measured on build/perf2/s12, the
  // fill's critical path was 18.019 ns of an 18.577 ns budget and every one of
  // the twenty worst clk_sys paths was in this module. The path is `sy` ->
  // LessThan3 (a ripple compare on THIRTY-TWO bits) -> Mux387 -> Equal227 ->
  // emit_mode: the two-level min/max tournament below, whose second level's
  // operands are muxed by the first level's comparators, then `sy[pmin_c] ==
  // sy[pmax_c]` on top of that, all feeding the FSM's next state in one cycle.
  //
  // It was recomputed EVERY cycle for values that are constant for the whole
  // quad -- sy[] is written once at S_IDLE and never again -- so S_MINMAX
  // spends one cycle latching the answer and S_CLASSIFY reads registers. The
  // fill spends hundreds of cycles per quad; one more is nothing.
  // R327: symin/symax are plain scanline coordinates; xlo_r/xhi_r are 16.16,
  // because they come from px[] which is `{sx[i], 16'h0000}`.
  logic signed [15:0] symin, symax;
  logic signed [31:0] xlo_r, xhi_r;
  logic [1:0]         pmin_r;
  logic               td_r;

  logic signed [31:0] xlo01, xlo23, xlo_c, xhi01, xhi23, xhi_c;   // 16.16, from px[]
  always_comb begin
    xlo01 = (px[1] < px[0]) ? px[1] : px[0];
    xlo23 = (px[3] < px[2]) ? px[3] : px[2];
    xlo_c = (xlo23 < xlo01) ? xlo23 : xlo01;
    xhi01 = (px[1] > px[0]) ? px[1] : px[0];
    xhi23 = (px[3] > px[2]) ? px[3] : px[2];
    xhi_c = (xhi23 > xhi01) ? xhi23 : xhi01;
  end

  // Wireframe test: exactly two distinct screen vertices. All four identical is
  // *not* a wireframe — it falls through to the flat path and paints one pixel.
  logic [3:1] eq_a;
  logic [1:0] b_idx;
  logic       all_eq, two_distinct;
  always_comb begin
    for (int i = 1; i < 4; i++)
      eq_a[i] = (sx[i] == sx[0]) && (sy[i] == sy[0]);

    // Lowest-index-wins priority encoder, written as an overwriting loop
    // because yosys rejects a loop with a break.
    b_idx = 2'd0;
    for (int i = 3; i >= 1; i--)
      if (!eq_a[i]) b_idx = 2'(i);

    all_eq = eq_a[1] && eq_a[2] && eq_a[3];

    two_distinct = !all_eq;
    for (int i = 1; i < 4; i++)
      if (!eq_a[i] && ((sx[i] != sx[b_idx]) || (sy[i] != sy[b_idx])))
        two_distinct = 1'b0;
  end

  // ------------------------------------------------------------- span clamp
  // emit_l/emit_r are 16.16 (xa, xb or flat_lo/hi); the `>>> 16` results and
  // everything clipped to the viewport are plain screen coordinates.
  logic signed [31:0] emit_l, emit_r;
  logic signed [15:0] emit_xl, emit_xr, emit_cl, emit_cr;
  logic               emit_ok;
  always_comb begin
    case (emit_mode)
      EM_FLAT: begin emit_l = flat_lo;              emit_r = flat_hi;              end
      EM_RAW:  begin emit_l = xa;                   emit_r = xb;                   end
      default: begin emit_l = swapf ? xb : xa;      emit_r = swapf ? xa : xb;      end
    endcase

    if (M2COV) begin
      // R658: sorted per row as MAME does, [round(lo), round(hi)) inclusive-ended
      // rounding is monotonic, so sorting the rounded values is the same thing
      // R739: AND THE CLAMPS BESIDE THE SORT, NOT AFTER IT. In series --
      // compare, select, -1, clamp, compare -- this was the 80 MHz path into
      // stage 1 and the DSP's enable (s785: xbh -> Mult1 ENA_DFF0 -0.782, ->
      // s1_col / s1_cr / s1_cl). Each clamp is monotonic, so clamping both
      // candidates and selecting with the sort is the same value, and so is
      // the emptiness test made on each pairing: two levels shorter.
      automatic logic signed [15:0] rxa = xah[31:16];
      automatic logic signed [15:0] rxb = xbh[31:16];
      automatic logic               sab = (rxa < rxb);
      automatic logic signed [15:0] ra1 = rxa - 16'sd1;
      automatic logic signed [15:0] rb1 = rxb - 16'sd1;
      automatic logic signed [15:0] cla = (rxa < view_x1) ? view_x1 : rxa;
      automatic logic signed [15:0] clb = (rxb < view_x1) ? view_x1 : rxb;
      automatic logic signed [15:0] cra = (ra1 > view_x2) ? view_x2 : ra1;
      automatic logic signed [15:0] crb = (rb1 > view_x2) ? view_x2 : rb1;
      emit_xl = sab ? rxa : rxb;
      emit_xr = sab ? rb1 : ra1;
      emit_cl = sab ? cla : clb;
      emit_cr = sab ? crb : cra;
      emit_ok = sab ? (cla <= crb) : (clb <= cra);
    end else begin
      emit_xl = 16'(emit_l >>> 16);
      emit_xr = 16'(emit_r >>> 16);
      emit_cl = (emit_xl < view_x1) ? view_x1 : emit_xl;
      emit_cr = (emit_xr > view_x2) ? view_x2 : emit_xr;
      emit_ok = (emit_cl <= emit_cr);
    end
  end

  // ------------------------------------------------------------------- FSM
  // R458: ONE BARREL SHIFTER, NOT SIX.
  //
  // The six gradient states each called pf_shift with DIFFERENT operands, so
  // sharing them needs an operand mux -- Quartus cannot fold them the way it
  // folds pf_scale, whose six calls take identical arguments and are plain
  // common-subexpression elimination. pf_shift is a 32-bit barrel shifter and
  // six of them is the shape that already put this module over the device
  // once ("six multiply-add pairs instead of two", base_u/base_v below).
  //
  // Exactly equivalent: in each state the mux selects that state's own
  // operands, so the shifter sees what it saw before. Only one state fires per
  // cycle, which is what makes one shifter sufficient.
  // R742: THE OPERAND ONE STATE AHEAD. The state's six-way numerator select,
  // the count's -1 and its range test were in front of the barrel shift
  // (s795 at 80 MHz: nyu -> mul_n -0.739). Each state's operand is known the
  // state before, so it is registered then (sn_r, sz_r) with z - 1 and the
  // pass-through test; the shift starts from flops. pf_shift's arithmetic,
  // the same values in the same states:
  //   NRM (wait 0-3) loads nxu for NRM's last cycle; NRM's last loads nyu for
  //   Q1; Q1 -> nxv; Q1W -> nyv; Q2 -> nxo; Q2W -> nyo (Q3 presents nothing).
  // The counts are joined on nrm_wait 2 (R735), so wait 3's load has them.
  // R952: the shared normaliser's datapath -- select, magnitude, halves
  always_ff @(posedge clk) begin
    nz_ks <= nz_k;
    case (nz_k)
      3'd0:    nz_sel <= nxu;
      3'd1:    nz_sel <= nyu;
      3'd2:    nz_sel <= nxv;
      3'd3:    nz_sel <= nyv;
      3'd4:    nz_sel <= nxo;
      default: nz_sel <= nyo;
    endcase
    nz_ka  <= nz_ks;  nz_abs <= pf_abs(nz_sel);
    nz_kc  <= nz_ka;  nz_h   <= clz16(nz_abs[31:16]);  nz_l <= clz16(nz_abs[15:0]);
  end
  logic signed [31:0] nn_c;
  logic [5:0]         nz_c;
  always_comb begin
    case (pf_st)   // R544: the fit's own state
      S_PF_NRM: if (nrm_wait == 3'd4) begin nn_c = nyu; nz_c = nyu_z; end
                else                  begin nn_c = nxu; nz_c = nxu_z; end
      S_PF_Q1:  begin nn_c = nxv; nz_c = nxv_z; end
      S_PF_Q1W: begin nn_c = nyv; nz_c = nyv_z; end
      S_PF_Q2:  begin nn_c = nxo; nz_c = nxo_z; end
      S_PF_Q2W: begin nn_c = nyo; nz_c = nyo_z; end
      default:  begin nn_c = nxu; nz_c = nxu_z; end
    endcase
  end
  logic signed [31:0] sn_r;
  logic [5:0]         sz_r;
  logic [4:0]         szm1_r;
  logic               spass_r;
  always_ff @(posedge clk) begin
    sn_r    <= nn_c;
    sz_r    <= nz_c;
    szm1_r  <= 5'(nz_c - 6'd1);
    spass_r <= (nz_c >= 6'd32) || (nz_c == 6'd0);
  end
  wire signed [31:0] mul_n_c = spass_r ? sn_r : (sn_r <<< szm1_r);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= S_IDLE;
      pf_st      <= S_IDLE;   // R544
      ps1        <= 3'd0;
      ps2        <= 3'd0;
      xa         <= 32'sd0;
      xb         <= 32'sd0;
      xah        <= 32'sh7FFF;
      xbh        <= 32'sh7FFF;
      lo_a       <= 1'b0;    lo_b  <= 1'b0;   // R944
      fr_a       <= 1'b0;    fr_b  <= 1'b0;
      lbq        <= 16'sd0;  ubq   <= 16'sd0;
      sla        <= 32'sd0;
      slb        <= 32'sd0;
      cury       <= 16'sd0;
      limy       <= 16'sd0;
      seg_y1     <= 16'sd0;
      walk_y     <= 16'sd0;
      walk_end   <= 16'sd0;
      swapf      <= 1'b0;
      skip_only  <= 1'b0;
      need_a     <= 1'b0;
      need_b     <= 1'b0;
      emit_mode  <= EM_WALK;
      flat_lo    <= 32'sd0;
      flat_hi    <= 32'sd0;
      col        <= 24'd0;
      moire      <= 1'b0;
      mul_delta  <= 17'sd0;
      mul_sl     <= 32'sd0;
      mul_pr     <= 32'sd0; mul_w <= 2'd0;   // R631
      mul_plo    <= '0; mul_phi <= '0;      // R740
      div_start  <= 1'b0;
      div_num    <= 32'sd0;
      div_den    <= 32'sd0;
      divb_start <= 1'b0;
      divb_num   <= 32'sd0;
      divb_den   <= 32'sd0;
      got_a      <= 1'b0;
      got_b      <= 1'b0;
      span_u <= '0; span_v <= '0; base_u <= '0; base_v <= '0; span_ooz <= '0;
      pf_a <= 1'b0; pf_b <= 1'b0;
      tex_ok <= 1'b0; pf_second <= 1'b0; tex_r <= '0; mz_r <= 1'b0; uvs_r <= 2'd0; pf_ph <= 2'd0; det_first_abs <= '0;
      dw_2 <= 1'b0;   // R847
      det_r <= '0; den_sh <= 6'd0; nxu <= '0; nyu <= '0; nxv <= '0; nyv <= '0;
      q_num_a <= '0; q_num_b <= '0; q_z_a <= '0; q_z_b <= '0;
      nxu_z <= '0; nyu_z <= '0; nxv_z <= '0; nyv_z <= '0;
      nxo_z <= '0; nyo_z <= '0; mul_n <= '0; mul_z <= 6'd0;   // R441/R442
      net_r <= 9'sd0; zbig_r <= 1'b0;   // R459
      den_a <= 16'd1; nrm_wait <= 3'd0; pfn_wait <= 2'd0; det_abs_r <= '0;    // R449/R461/R466/R594
      // R451: these were initialised in the prime step and NOT in reset. A
      // register that only gets a value once the state machine reaches a
      // particular state is undefined for every cycle before it, and b_wait
      // powering up set would make S_PF_B compute its bases from a gradient
      // that had not been latched yet.
      mul_q_r <= '0; mul_zr <= 6'd0; b_wait <= 1'b0; b_w2 <= 1'b0; b_w3 <= 1'b0; sc_r <= '0; sc_s <= '0; oz_w_v <= 1'b0; oz_last <= 1'b0; oz_w <= 2'd0; b_prod <= 1'b0;
      dudx <= '0; dudy <= '0; dvdx <= '0; dvdy <= '0;
      for (int k = 0; k < 4; k++) begin qu[k] <= '0; qv[k] <= '0; qoz[k] <= '0; end
      oz_i <= 2'd0; oz_emax <= 8'd0; oz_pre <= 1'b0; dodx <= '0; dody <= '0;
      base_o <= '0; nxo <= '0; nyo <= '0; pf_c <= 1'b0;
      span_valid <= 1'b0;
      s1_valid   <= 1'b0;   // R715
      span_y     <= 16'sd0;
      span_x0    <= 16'sd0;
      span_x1    <= 16'sd0;
      span_col   <= 24'd0;
      span_moire <= 1'b0;
      quad_done  <= 1'b0;
      line_case  <= 1'b0;
      symin <= 16'sd0; symax <= 16'sd0;
      xlo_r <= 32'sd0; xhi_r <= 32'sd0;
      pmin_r <= 2'd0;  td_r  <= 1'b0;
      m01_r <= 1'b0; m23_r <= 1'b0; x01_r <= 1'b0; x23_r <= 1'b0;   // R735
      lo01_v <= '0; lo23_v <= '0; hi01_v <= '0; hi23_v <= '0;          // R740
      mm_pre <= 1'b0;                                                  // R743
      for (int i = 0; i < 4; i++) begin
        sx[i] <= 16'sd0;
        sy[i] <= 16'sd0;
      end
      nz_k <= 3'd0; nz_run <= 1'b0; nz_vs <= 1'b0; nz_va <= 1'b0; nz_vc <= 1'b0;   // R952
    end else begin
      div_start  <= 1'b0;
      divb_start <= 1'b0;
      quad_done  <= 1'b0;
      // R952: the shared normaliser's walk and its joined counts
      if ((pf_st == S_PF_N) && (pfn_wait == 2'd1)) begin
        nz_k <= 3'd0; nz_run <= 1'b1;                     // nxu..nyo landed last cycle
      end else if (nz_run) begin
        nz_k <= nz_k + 3'd1;
        if (nz_k == 3'd5) nz_run <= 1'b0;
      end
      nz_vs <= nz_run; nz_va <= nz_vs; nz_vc <= nz_va;
      if (nz_vc) case (nz_kc)
        3'd0:    nxu_z <= clz_join(nz_h, nz_l);
        3'd1:    nyu_z <= clz_join(nz_h, nz_l);
        3'd2:    nxv_z <= clz_join(nz_h, nz_l);
        3'd3:    nyv_z <= clz_join(nz_h, nz_l);
        3'd4:    nxo_z <= clz_join(nz_h, nz_l);   // R441
        default: nyo_z <= clz_join(nz_h, nz_l);
      endcase
      sc_r      <= pf_gshift(mul_q_r, net_r, zbig_r);   // R594: every cycle
      sc_s      <= pf_sat(sc_r);                         // R727: every cycle
      line_case <= 1'b0;
      if (span_valid && span_ready) span_valid <= 1'b0;
      // R715: stage 1 to the output, the plane evaluated from registers
      if (s1_adv) begin
        span_valid <= !DIL || (s1_x0 <= s1_x1);   // R944: a span the clamps empty is dropped
        span_y     <= s1_y;
        span_x0    <= s1_x0;
        span_x1    <= s1_x1;
        span_col   <= s1_col;
        span_moire <= s1_moire;
        span_u     <= emit_u;
        span_v     <= emit_v;
        span_ooz   <= emit_o;        // R337
        s1_valid   <= 1'b0;
      end

      // ---- R544: the plane fit's own machine (states moved, bodies unchanged
      // except that the fit ends in S_IDLE rather than handing to S_MINMAX).
      case (pf_st)
        // ---- R274: the plane fit, four states and two divide rounds.
        //
        // det is the cross product of the two edges out of vertex 0 in SCREEN
        // space. Zero means the three vertices are collinear as drawn, which
        // every triangle-as-quad is on one of its two choices -- hence the
        // retry on 0,2,3 before giving up.
        // R337: ONE VERTEX A CYCLE. qoz goes from minifloat to the quad's
        // common fixed scale, and qu/qv are rewritten in place as u/z and v/z
        // -- the raw coordinate is not wanted again. The shift is a constant
        // 16 because normalisation puts the largest 1/z in [2^15, 2^16), so
        // the product lands back in the 13 bits u already occupied.
        S_OZ: if (oz_pre) begin
          oz_pre  <= 1'b0;   // R731
          oz_emax <= oz_emax_q;
        end else begin
          // R566: stage one -- select vertex oz_i and normalise its 1/z.
          if (!oz_last) begin
            oz_n   <= oz_norm(qoz[oz_i], oz_emax);
            oz_u   <= qu[oz_i][12:0];   // R791: the raw u, before the rewrite
            oz_v   <= qv[oz_i][12:0];
            oz_w   <= oz_i;
            oz_w_v <= 1'b1;
            if (oz_i == 2'd3) oz_last <= 1'b1;
            else              oz_i    <= oz_i + 2'd1;
          end else begin
            oz_w_v <= 1'b0;
          end
          // Stage two -- multiply and write back the vertex selected last
          // cycle. It is never the one stage one is reading this cycle.
          if (oz_w_v) begin
            qoz[oz_w] <= oz_n;
            // R791: UZF more bits of the same product (u < 2^13, oz_n < 2^15)
            qu[oz_w]  <= UW'((29'(oz_u) * 29'(oz_n)) >> (15 - UZF));
            qv[oz_w]  <= UW'((29'(oz_v) * 29'(oz_n)) >> (15 - UZF));
            if (oz_last) begin oz_last <= 1'b0; pf_st <= S_PF_D; end
          end
        end

        // R727: pr_* follow pf_second; R847: and dp_* follow pr_*, a cycle each
        S_PF_DW: if (!dw_2) dw_2 <= 1'b1;
                 else begin dw_2 <= 1'b0; pf_st <= S_PF_D; end

        S_PF_D: begin
          det_r <= dp_ab - dp_ba;   // R847: the products registered (R727: of pr_*)
          pf_st <= S_PF_N;
        end

        S_PF_N: begin
          if (pf_ph == 2'd0) begin            // R674: now the other triangle
            det_first_abs <= det_abs;
            pf_second     <= 1'b1;
            pf_ph         <= 2'd1;
            pf_st         <= S_PF_DW;
          end else if (pf_ph == 2'd1) begin   // R674: keep the larger
            // and back through S_PF_D: pr_* (R638) follow pf_second a cycle
            // late, and the numerators rely on S_PF_D coming between
            pf_ph <= 2'd2;
            if (det_first_abs >= det_abs) pf_second <= 1'b0;
            pf_st <= S_PF_DW;
          end else if (det_r == 32'sd0) begin
            if (!pf_second) begin
              pf_second <= 1'b1;
              pf_st     <= S_PF_DW;
            end else begin
              // No plane through these three points: draw it flat.
              tex_ok <= 1'b0;
              pf_st  <= S_IDLE;
            end
          // R461: THE ENCODE AND THE SHIFT IN SEPARATE CYCLES.
          //
          //   m2_raster_fill|det_r[3] -> m2_raster_fill|den_a[14]   19.446 ns
          //
          // was the worst clk_sys path on s122 once R459 moved pf_scale off it,
          // and 7,866 of the worst 8,000 paths at 60 MHz ended at den_a. One
          // cycle carried a 32-bit negate (det_abs), clz32's priority encoder,
          // the subtract that makes den_sh_c, a variable shift by it, and then
          // an abs -- the same encoder-feeding-a-shifter shape as R457 and
          // R459, for the third time in this module.
          //
          // Split across two cycles: the encode registers den_sh, the shift
          // reads it back. The second cycle reuses `den_n` -- which is already
          // `det_r >>> den_sh` for rquo's sign -- so no second shifter is
          // built, and the value is identical because den_sh is den_sh_c
          // registered.
          //
          // COSTS ONE CYCLE of the 129 to retire a quad. m2_persp_recip still
          // gets its two cycles: den_a lands one cycle later and S_PF_NRM's
          // pair is unchanged after it.
          end else if (pfn_wait == 2'd0) begin
            pfn_wait  <= 2'd1;
            det_abs_r <= det_abs;        // R594: magnitude, and only magnitude
            nxu <= 32'(pr_u1) * 32'(pr_by) - 32'(pr_u2) * 32'(pr_ay);   // R638, R727: pr_*
            nyu <= 32'(pr_ax) * 32'(pr_u2) - 32'(pr_bx) * 32'(pr_u1);
            nxv <= 32'(pr_v1) * 32'(pr_by) - 32'(pr_v2) * 32'(pr_ay);
            nyv <= 32'(pr_ax) * 32'(pr_v2) - 32'(pr_bx) * 32'(pr_v1);
            nxo <= 32'(pr_o1) * 32'(pr_by) - 32'(pr_o2) * 32'(pr_ay);   // R337
            nyo <= 32'(pr_ax) * 32'(pr_o2) - 32'(pr_bx) * 32'(pr_o1);
          end else if (pfn_wait == 2'd1) begin
            pfn_wait <= 2'd2;
            den_sh <= den_sh_c;          // R289/R461: encode, and only encode
          end else begin
            pfn_wait <= 2'd0;
            den_a  <= (den_n >= 0) ? 16'(den_n) : 16'(-den_n);   // R449/R461
            pf_st <= S_PF_NRM;   // R418 counts the zeros before R337 shifts
          end
        end

        // R418: count once, here, for all four numerators.
        // R441: the reciprocal needs two cycles and this state plus the one
        // after it give them, so it costs nothing extra.
        // R449: two cycles here, so m2_persp_recip has settled before the
        // first multiply reads it. The counts below are computed on the first.
        // R457: THE COUNTS MOVE TO THE FIRST CYCLE, THE SHIFT STAYS ON THE
        // SECOND, and that split is the worst clk_sys path in the design.
        //
        //   m2_raster_fill|nxu[9] -> m2_raster_fill|mul_n[28]   19.048 ns
        //
        // measured on s115 with report_timing, against a 20 ns period: clk_sys
        // Fmax 50.09 MHz, slack +0.037. Every other numerator state shifts by a
        // count registered a cycle earlier -- pf_shift(nyu, nyu_z) -- but the
        // priming line recomputed pf_clz(nxu) inline and fed the shifter from
        // it, so this one cycle carried a 32-bit two's-complement negate, then
        // clz32's priority encoder, then a 32-bit barrel shifter, in series.
        //
        // S_PF_NRM already spends two cycles here (R449, so m2_persp_recip has
        // settled before the first multiply reads it) and the first of them did
        // nothing but set nrm_wait. The counts go there. nxu is registered in
        // the state that branches here, so it is stable on entry and the first
        // cycle can read it.
        //
        // COSTS NOTHING: same six pf_clz instances, same 129 cycles to retire,
        // same registers -- nxu_z was previously WRITTEN AND NEVER READ, dead
        // because the priming line recomputed the count inline. This makes it
        // live and leaves the second cycle carrying only the shift.
        // R466: THREE CYCLES NOW, NOT TWO. m2_persp_recip splits its Newton
        // step across two cycles (both multiplies were in series and that was
        // the worst clk_3d path at 60 MHz), so it answers a cycle later and
        // this state waits one more before S_PF_Q1 reads den_rcp. One cycle of
        // about 130 to retire a quad.
        S_PF_NRM: if (nrm_wait != 3'd4) begin   // R599: was 2; R731: 4
          nrm_wait <= nrm_wait + 3'd1;
          // The counts still land on the FIRST cycle only -- repeating them on
          // the new third cycle would be harmless but would re-time six
          // priority encoders for nothing.
          // R584: THE NEGATE AND THE COUNT IN SEPARATE CYCLES. pf_clz was a
          // 32-bit two's-complement negate and clz32's encoder in series, six
          // times (s312: nyo -> nyo_z, -1.40 ns at 70 MHz). The magnitudes are
          // registered on the first cycle and counted on the second; the
          // first reader is the third cycle's mul_n, so no cycle is added and
          // the counts are the same numbers.
          // R952: the counts come from the shared normaliser (below the case).
        end else begin
          nrm_wait <= 3'd0;
          mul_n <= mul_n_c;   // R457/R458: registered count, one shared shifter
          mul_z <= sz_r;
          mul_q_r <= '0; mul_zr <= 6'd0; b_wait <= 1'b0; b_w2 <= 1'b0; b_w3 <= 1'b0;   // R450/R594/R727
          oz_w_v <= 1'b0; oz_last <= 1'b0; b_prod <= 1'b0; // R566
          pf_st <= S_PF_Q1;
        end

        // R441: one multiply a state. No handshake, no waiting: the quotient
        // is ready the cycle after the operands are.
        // R442: present the next numerator, latch the previous gradient.
        S_PF_Q1: begin
          mul_n <= mul_n_c; mul_z <= sz_r;
          mul_q_r <= mul_q; mul_zr <= mul_z;   // R450
          net_r <= NET0 - 9'(mul_z) - 9'(den_sh); zbig_r <= (mul_z >= 6'd32);   // R459, R626
          pf_st <= S_PF_Q1W;
        end

        S_PF_Q1W: begin
          mul_n <= mul_n_c; mul_z <= sz_r;
          mul_q_r <= mul_q; mul_zr <= mul_z;   // R450
          net_r <= NET0 - 9'(mul_z) - 9'(den_sh); zbig_r <= (mul_z >= 6'd32);   // R459, R626
          pf_st <= S_PF_Q2;
        end

        S_PF_Q2: begin
          mul_n <= mul_n_c; mul_z <= sz_r;
          mul_q_r <= mul_q; mul_zr <= mul_z;   // R450
          net_r <= NET0 - 9'(mul_z) - 9'(den_sh); zbig_r <= (mul_z >= 6'd32);   // R459, R626
          pf_st <= S_PF_Q2W;
        end

        S_PF_Q2W: begin
          mul_n <= mul_n_c; mul_z <= sz_r;
          mul_q_r <= mul_q; mul_zr <= mul_z;   // R450
          net_r <= NET0 - 9'(mul_z) - 9'(den_sh); zbig_r <= (mul_z >= 6'd32);   // R459, R626
          dudx  <= sc_s;   // R594, R727
          pf_st <= S_PF_Q3;
        end

        // R337: THE 1/z PLANE. Same shape as the two above and it reuses the
        // same pair of dividers -- m2_raster_div does not pipeline, so this is
        // two more divides of latency per quad, which is the real cost of
        // perspective correction and the thing to watch in `ready ms`.
        // R441: and the 1/z plane the same way. This also takes the clz out of
        // the same cycle as the shift, which is R418's fix applied to the round
        // R337 wrote before R418 existed.
        S_PF_Q3: begin
          mul_n <= mul_n_c; mul_z <= sz_r;
          mul_q_r <= mul_q; mul_zr <= mul_z;   // R450
          net_r <= NET0 - 9'(mul_z) - 9'(den_sh); zbig_r <= (mul_z >= 6'd32);   // R459, R626
          dudy  <= sc_s;
          pf_st <= S_PF_Q3W;
        end

        S_PF_Q3W: begin
          mul_q_r <= mul_q; mul_zr <= mul_z;   // R450
          net_r <= NET0 - 9'(mul_z) - 9'(den_sh); zbig_r <= (mul_z >= 6'd32);   // R459, R626
          dvdx  <= sc_s;
          pf_st <= S_PF_B;
        end

        // The plane is held as its value at screen (0,0) plus two gradients,
        // so a span costs two multiplies and no state.
        S_PF_B: if (!b_wait) begin
          dvdy   <= sc_s;   // R727
          b_wait <= 1'b1;
        end else if (!b_w2) begin
          dodx   <= sc_s;   // R594: one state later than R450 put it, R727 one more
          b_w2   <= 1'b1;
        end else if (!b_w3) begin
          dody   <= sc_s;   // the last gradient
          b_w3   <= 1'b1;
        end else if (!b_prod) begin
          // R566: the six products and the corner, registered.
          // R626: at the vertex's quarter-pixel position when FRB (the <<< 8
          // below becomes <<< 6 -- the product is four times as large)
          bp_ux <= 32'(dudx * p4(sx[fa], sf[fa][1:0]));  bp_uy <= 32'(dudy * p4(sy[fa], sf[fa][3:2]));
          bp_vx <= 32'(dvdx * p4(sx[fa], sf[fa][1:0]));  bp_vy <= 32'(dvdy * p4(sy[fa], sf[fa][3:2]));
          bp_ox <= 32'(dodx * p4(sx[fa], sf[fa][1:0]));  bp_oy <= 32'(dody * p4(sy[fa], sf[fa][3:2]));
          bq_u  <= qu[fa]; bq_v <= qv[fa]; bq_o <= qoz[fa];
          // R616: (gx + gy) / 2 in 16.16 -- the gradients are 8.8, so << 7.
          // R791: u/v at UVS fraction bits, so half a gradient is << UVS - 9
          bh_u  <= PXC ? ((32'(dudx) + 32'(dudy)) <<< (UVS - 9)) : 32'sd0;
          bh_v  <= PXC ? ((32'(dvdx) + 32'(dvdy)) <<< (UVS - 9)) : 32'sd0;
          bh_o  <= PXC ? ((32'(dodx) + 32'(dody)) <<< 7) : 32'sd0;
          b_prod <= 1'b1;
        end else begin
          b_wait <= 1'b0;
          b_w2   <= 1'b0;
          b_w3   <= 1'b0;
          b_prod <= 1'b0;
          // R791: at UVS fraction bits, not 16 -- the products' shift is two
          // (UZF - 2) less, and (13 + UZF) + UVS = 31 bits, always in range.
          base_u <= (32'(bq_u) <<< UVS) - (bp_ux <<< BPS_UV) - (bp_uy <<< BPS_UV) + bh_u;   // R616, R626
          base_v <= (32'(bq_v) <<< UVS) - (bp_vx <<< BPS_UV) - (bp_vy <<< BPS_UV) + bh_v;
          // R337: 1/z's own plane. qoz is 15 bits, so it shifts up by 16 the
          // same way, and the span walk divides by what this yields.
          base_o <= 32'({16'd0, bq_o} <<< 16) - (bp_ox <<< BPS) - (bp_oy <<< BPS) + bh_o;
          tex_ok <= 1'b1;
          pf_st  <= S_IDLE;
        end

        default: ;
      endcase

      case (state)
        S_IDLE: begin
          if (in_valid && pf_st == S_IDLE && !span_valid && !s1_valid) begin   // R544: see in_ready; R715
            sx[0] <= in_x0; sy[0] <= in_y0;
            sx[1] <= in_x1; sy[1] <= in_y1;
            sx[2] <= in_x2; sy[2] <= in_y2;
            sx[3] <= in_x3; sy[3] <= in_y3;
            sf[0] <= in_frac[3:0];  sf[1] <= in_frac[7:4];     // R626
            sf[2] <= in_frac[11:8]; sf[3] <= in_frac[15:12];
            // R735: the tournament's first round, from the same values
            m01_r <= ye_in(in_y1, in_frac[7:6])   < ye_in(in_y0, in_frac[3:2]);
            m23_r <= ye_in(in_y3, in_frac[15:14]) < ye_in(in_y2, in_frac[11:10]);
            x01_r <= ye_in(in_y1, in_frac[7:6])   > ye_in(in_y0, in_frac[3:2]);
            x23_r <= ye_in(in_y3, in_frac[15:14]) > ye_in(in_y2, in_frac[11:10]);
            mm_pre <= 1'b1;   // R743: the pairs' values in S_MINMAX's first cycle
            col   <= in_col;
            moire <= in_moire;
            // R791: the raw 13-bit u, v in the low bits until S_OZ rewrites them
            qu[0] <= UW'(in_u0); qv[0] <= UW'(in_v0); qu[1] <= UW'(in_u1); qv[1] <= UW'(in_v1);
            qu[2] <= UW'(in_u2); qv[2] <= UW'(in_v2); qu[3] <= UW'(in_u3); qv[3] <= UW'(in_v3);
            qoz[0] <= in_oz0; qoz[1] <= in_oz1;            // R337: still minifloats here
            qoz[2] <= in_oz2; qoz[3] <= in_oz3;
            oz_pre  <= 1'b1;                        // R731: emax in S_OZ's first cycle
            oz_i    <= 2'd0;
            tex_r     <= in_tex;
            mz_r      <= in_mipz;                // R828c
            uvs_r     <= in_uvs;                 // R940
            tex_ok    <= 1'b0;
            pf_second <= 1'b0;
            pf_ph     <= 2'd0;                // R674
            dw_2      <= 1'b0;                // R847: a fit abandoned in S_PF_DW
            dudx <= '0; dudy <= '0; dvdx <= '0; dvdy <= '0;
            // An untextured quad pays nothing for any of this.
            // R337: normalise 1/z before the plane fit, because the fit runs
            // on u/z and v/z and those do not exist until it has.
            state <= S_MINMAX;                       // R544: the edges start at once
            pf_st <= in_tex[0] ? S_OZ : S_IDLE;      // and the fit beside them
            // R675: AND THE NORMALISE PIPELINE STARTS EMPTY. A fit abandoned
            // below while S_OZ was part way left oz_w_v set, and the next
            // textured quad's first S_OZ cycle wrote the abandoned quad's
            // normalised 1/z and u/z, v/z into ITS corner oz_w -- a wrong
            // texture plane on the quad after any textured quad rejected before
            // its first span. Timing decided whether it struck.
            oz_w_v <= 1'b0; oz_last <= 1'b0;
          end else if (pf_st != S_IDLE) begin
            // R544: the quad ended before its first span (a line, or
            // rejected whole): its fit is not wanted.
            pf_st  <= S_IDLE;
            oz_w_v <= 1'b0; oz_last <= 1'b0;         // R675
          end
        end

        // One cycle of pure comparison: wireframe, top and bottom vertices, and
        // the three whole-quad rejects. Order matters — the flat case is taken
        // before the viewport rejects, because fill_line does its own y test.
        S_MINMAX: if (mm_pre) begin
          // R743: sye[] is the accepted y, the bits the acceptance's compares
          mm_pre <= 1'b0;
          lo01_v <= m01_r ? sye[1] : sye[0];  lo23_v <= m23_r ? sye[3] : sye[2];
          hi01_v <= x01_r ? sye[1] : sye[0];  hi23_v <= x23_r ? sye[3] : sye[2];
        end else begin
          // One cycle of pure comparison, and now the ONLY cycle that does it.
          td_r   <= two_distinct;
          pmin_r <= pmin_c;
          symin  <= m_fin ? lo23_v : lo01_v;   // R658: quarters with M2COV; R740: = sye[pmin_c]
          symax  <= x_fin ? hi23_v : hi01_v;
          xlo_r  <= xlo_c;
          xhi_r  <= xhi_c;
          state  <= S_CLASSIFY;
        end

        S_CLASSIFY: begin
          // R658: Model 1's wireframe case is judged on INTEGER vertices; with
          // quarter pixels a thin sliver has four distinct corners and Model 2
          // (poly.h) fills it. A polygon of truly no area covers no centre.
          if (td_r && !M2COV) begin
            line_case <= 1'b1;
            quad_done <= 1'b1;
            state     <= S_IDLE;
          end else if (M2COV && ((symin == symax) || (rq(symin) >= rq(symax))
                                 || (rq(symin) > view_y2) || (rq(symax) <= view_y1))) begin
            // R658: no row's centre inside it, or none on the screen
            quad_done <= 1'b1;
            state     <= S_IDLE;
          end else if (symin == symax) begin
            flat_lo   <= xlo_r;
            flat_hi   <= xhi_r;
            cury      <= symin;
            emit_mode <= EM_FLAT;
            state     <= S_FLAT;
          end else if (!M2COV && ((symin > view_y2) || (symax <= view_y1))) begin   // R658: M2COV tested above, in rows
            quad_done <= 1'b1;
            state     <= S_IDLE;
          end else begin
            cury   <= symin;
            limy   <= M2COV ? symax : ((symax > view_y2) ? view_y2 : symax);   // R658: quarters
            ps1    <= {1'b1, pmin_r};      // pmin + 4
            ps2    <= {1'b0, pmin_r};
            need_a <= 1'b1;
            need_b <= 1'b1;
            state  <= S_START1;
          end
        end

        S_FLAT: begin
          if (s1_free && pf_st == S_IDLE) begin   // R544; R715
            // R741: the data loads whenever stage 1 is free and only the
            // VALID depends on the emit test -- it was the enable of every
            // stage-1 flop (s792 at 80 MHz: xah -> s1_col -0.519, s1_moire).
            // Stage 1's data is read only while s1_valid.
            s1_valid   <= (cury <= view_y2) && (cury >= view_y1) && emit_ok;   // R715: stage 1; the plane next cycle
            s1_y       <= cury;
            s1_cl      <= emit_cl;
            s1_cr      <= emit_cr;
            s1_col     <= col;
            s1_moire   <= moire;
            quad_done <= 1'b1;
            state     <= S_IDLE;
          end
        end

        // The two startup loops: skip every vertex sharing the current y, so
        // the slope denominator below is strictly nonzero.
        S_START1: begin
          if (need_a && (ya_next == cury)) ps1 <= ps1 - 3'd1;
          else                             state <= S_START2;
        end

        S_START2: begin
          if (need_b && (yb_next == cury)) ps2 <= ps2 + 3'd1;
          else                             state <= S_LOADX;
        end

        // Reloading x from the vertex rather than keeping the walked value is
        // what snaps an edge back onto the polygon at each vertex event.
        S_LOADX: begin
          if (need_a) begin xa <= px[ps1[1:0]]; xah <= px[ps1[1:0]] + 32'sh7FFF; fr_a <= 1'b1; end   // R944: fr
          if (need_b) begin xb <= px[ps2[1:0]]; xbh <= px[ps2[1:0]] + 32'sh7FFF; fr_b <= 1'b1; end
          state <= S_DIVA;
        end

        // Both slopes at once. A side that does not need a new slope is
        // marked collected up front; both dividers are idle here because the
        // previous segment waited for both.
        S_DIVA: begin
          if (div_ready && !div_start && divb_ready && !divb_start) begin
            if (need_a) begin
              automatic logic signed [31:0] dxa = xa - px[ps1m1[1:0]];
              div_num   <= M2COV ? (dxa <<< 2) : dxa;   // R658: den in quarters
              div_den   <= 32'(cury - ya_next);
              div_start <= 1'b1;
              lo_a      <= dxa[31];   // R944: xa = px[ps1] now -- the start vertex is the lesser x
            end
            if (need_b) begin
              automatic logic signed [31:0] dxb = xb - px[ps2p1[1:0]];
              divb_num   <= M2COV ? (dxb <<< 2) : dxb;
              divb_den   <= 32'(cury - yb_next);
              divb_start <= 1'b1;
              lo_b       <= dxb[31];   // R944
            end
            got_a <= !need_a;
            got_b <= !need_b;
            state <= S_DIVAW;
          end
        end

        S_DIVAW: begin
          if (div_valid)  begin sla <= div_quo;  got_a <= 1'b1; end
          if (divb_valid) begin slb <= divb_quo; got_b <= 1'b1; end
          if ((got_a || div_valid) && (got_b || divb_valid)) state <= M2COV ? S_OFF : S_DECIDE;   // R658
        end

        // R658: A RELOADED EDGE STARTS AT ITS FIRST ROW'S CENTRE. It was loaded
        // at its vertex (x exact, y = cury in quarters); the first row it
        // covers is rq(cury), whose centre is d = 4*rq(cury) + 2 - cury
        // quarters below -- 0 to 3 -- so it moves by slope * d / 4. The other
        // edge is already at that row's centre: it was walked there.
        S_OFF: begin
          automatic logic [1:0] d = 2'((rq(cury) <<< 2) + 16'sd2 - cury);
          automatic logic signed [31:0] da = ((d[1] ? (sla <<< 1) : 32'sd0) + (d[0] ? sla : 32'sd0)) >>> 2;
          automatic logic signed [31:0] db = ((d[1] ? (slb <<< 1) : 32'sd0) + (d[0] ? slb : 32'sd0)) >>> 2;
          if (need_a) begin xa <= xa + da; xah <= xah + da; end
          if (need_b) begin xb <= xb + db; xbh <= xbh + db; end
          state <= S_DECIDE;
        end

        // Which chain reaches its next vertex first decides how far this
        // segment runs and which side gets reloaded afterwards.
        S_DECIDE: begin
          if (ya_next == yb_next) begin
            seg_y1 <= ya_next;
            need_a <= 1'b1;
            need_b <= 1'b1;
          end else if (ya_next < yb_next) begin
            seg_y1 <= ya_next;
            need_a <= 1'b1;
            need_b <= 1'b0;
          end else begin
            seg_y1 <= yb_next;
            need_a <= 1'b0;
            need_b <= 1'b1;
          end
          state <= S_FS_ENTER;
        end

        // fill_slope, pre-clip. Note the first case returns without touching
        // the accumulators at all, which is why the caller's edges survive a
        // segment that starts below the viewport.
        S_FS_ENTER: if (M2COV) begin
          // R658: the segment covers rows rq(cury) .. rq(seg_y1)-1
          if (rq(cury) > view_y2) begin
            state <= S_FS_END;
          end else if (rq(seg_y1) <= view_y1) begin
            mul_delta <= 17'(rq(seg_y1) - rq(cury));
            mul_sl    <= sla;
            skip_only <= 1'b1;
            state     <= S_FS_MULA;
          end else begin
            walk_end <= (rq(seg_y1) > view_y2) ? (view_y2 + 16'sd1) : rq(seg_y1);
            if (rq(cury) < view_y1) begin
              mul_delta <= 17'(view_y1 - rq(cury));
              mul_sl    <= sla;
              skip_only <= 1'b0;
              walk_y    <= view_y1;
              state     <= S_FS_MULA;
            end else begin
              walk_y <= rq(cury);
              state  <= S_FS_SWAP;
            end
          end
        end else begin
          if (cury > view_y2) begin
            state <= S_FS_END;
          end else if (seg_y1 <= view_y1) begin
            mul_delta <= 17'(seg_y1 - cury);
            mul_sl    <= sla;
            skip_only <= 1'b1;
            state     <= S_FS_MULA;
          end else begin
            walk_end <= (seg_y1 > view_y2) ? (view_y2 + 16'sd1) : seg_y1;
            if (cury < view_y1) begin
              mul_delta <= 17'(view_y1 - cury);
              mul_sl    <= sla;
              skip_only <= 1'b0;
              walk_y    <= view_y1;
              state     <= S_FS_MULA;
            end else begin
              walk_y <= cury;
              state  <= S_FS_SWAP;
            end
          end
        end

        S_FS_MULA: if (mul_w == 2'd0) begin
          mul_plo <= mul_delta * mul_sl_lo;   // R740
          mul_phi <= mul_delta * mul_sl_hi;
          mul_w   <= 2'd1;
        end else if (mul_w == 2'd1) begin
          mul_pr <= mul_plo[31:0] + {mul_phi[15:0], 16'd0};
          mul_w  <= 2'd2;
        end else begin
          xa     <= xa + mul_pr;
          xah    <= xah + mul_pr;
          mul_sl <= slb;
          mul_w  <= 2'd0;
          state  <= S_FS_MULB;
        end

        S_FS_MULB: if (mul_w == 2'd0) begin
          mul_plo <= mul_delta * mul_sl_lo;   // R740
          mul_phi <= mul_delta * mul_sl_hi;
          mul_w   <= 2'd1;
        end else if (mul_w == 2'd1) begin
          mul_pr <= mul_plo[31:0] + {mul_phi[15:0], 16'd0};
          mul_w  <= 2'd2;
        end else begin
          xb    <= xb + mul_pr;
          xbh   <= xbh + mul_pr;
          mul_w <= 2'd0;
          state <= skip_only ? S_FS_END : S_FS_SWAP;
        end

        // Left/right is decided here, once, and held for the whole segment.
        S_FS_SWAP: begin
          swapf     <= (xa > xb) || ((xa == xb) && (sla > slb));
          emit_mode <= EM_WALK;
          state     <= (DIL && M2COV && !tex_r[0]) ? S_FS_DIL : S_FS_WALK;   // R944: flat quads
        end

        // R944: A RELOADED EDGE MOVED OUT, once: the left one (a unless swapf)
        // by -dg, the right one by +dg, dg = (1 + |slope|) / 8, in the rounding
        // copies only -- xa / xb stay exact, and every later write to xah / xbh
        // is the same delta as xa / xb's, so the move holds until the edge is
        // reloaded. The side is this segment's; a convex quad's edges never
        // change sides. dg from the edge's own slope, on the walk's own adder
        // (xah_nx): with t = sl >>> 3 and C = 1/8 + 2^-16, |sl| >> 3 (ones'
        // complement for a negative slope) is t or ~t, and -(m + C) = ~m + 1 - C,
        // so the move is xah + (t or ~t) + (C or 1 - C). And the segment's clamps, from the
        // left and right edges' vertices (ps1 / ps2 still index them). Waits
        // for stage 1 to empty, so a span of the last segment keeps its clamps.
        S_FS_DIL: if (!s1_valid) begin
          automatic logic signed [17:0] qsa = px[ps1[1:0]][31:14];   // the edges' vertices, in quarters
          automatic logic signed [17:0] qea = px[ps1m1[1:0]][31:14];
          automatic logic signed [17:0] qsb = px[ps2[1:0]][31:14];
          automatic logic signed [17:0] qeb = px[ps2p1[1:0]][31:14];
          automatic logic signed [17:0] mna = lo_a ? qsa : qea, mxa = lo_a ? qea : qsa;
          automatic logic signed [17:0] mnb = lo_b ? qsb : qeb, mxb = lo_b ? qeb : qsb;
          // round(lo - 1/8) = (lo + 1) >> 2 in quarters; round(hi + 1/8) - 1 = (hi - 2) >> 2
          automatic logic signed [17:0] lo1 = (swapf ? mnb : mna) + 18'sd1;
          automatic logic signed [17:0] hi2 = (swapf ? mxa : mxb) - 18'sd2;
          if (fr_a) xah <= xah_nx;   // R944: the walk's adder, its move operands
          if (fr_b) xbh <= xbh_nx;
          lbq   <= lo1[17:2];   // R662: slices, no signed'() around a sum
          ubq   <= hi2[17:2];
          fr_a  <= 1'b0;
          fr_b  <= 1'b0;
          state <= S_FS_WALK;
        end

        S_FS_WALK: begin
          if (walk_y >= walk_end) begin
            state <= S_FS_END;
          end else if (s1_free && pf_st == S_IDLE) begin   // R544; R715
            // R741: the data loads whenever stage 1 is free and only the
            // VALID depends on the emit test -- it was the enable of every
            // stage-1 flop (s792 at 80 MHz: xah -> s1_col -0.519, s1_moire).
            // Stage 1's data is read only while s1_valid.
            s1_valid   <= emit_ok;   // R715: stage 1; the plane next cycle
            s1_y       <= walk_y;
            s1_cl      <= emit_cl;
            s1_cr      <= emit_cr;
            s1_col     <= col;
            s1_moire   <= moire;
            xa     <= xa + sla;
            xb     <= xb + slb;
            xah    <= xah_nx;   // R944: = xah + sla here (the adder S_FS_DIL shares)
            xbh    <= xbh_nx;
            walk_y <= walk_y + 16'sd1;
          end
        end

        S_FS_END: begin
          cury      <= seg_y1;
          skip_only <= 1'b0;
          if (seg_y1 >= limy) begin
            emit_mode <= EM_RAW;
            state     <= M2COV ? S_DONE : S_FINAL;   // R658: Model 2 has no separate last row
          end else begin
            if (need_a) ps1 <= ps1 - 3'd1;
            if (need_b) ps2 <= ps2 + 3'd1;
            state <= S_START1;
          end
        end

        // The last scanline of the quad, drawn unordered: fill_line does not
        // sort its two x values, so a crossed pair emits nothing.
        S_FINAL: begin
          if (s1_free && pf_st == S_IDLE) begin   // R544; R715
            // R741: the data loads whenever stage 1 is free and only the
            // VALID depends on the emit test -- it was the enable of every
            // stage-1 flop (s792 at 80 MHz: xah -> s1_col -0.519, s1_moire).
            // Stage 1's data is read only while s1_valid.
            s1_valid   <= (cury == limy) && (cury <= view_y2) && (cury >= view_y1) && emit_ok;   // R715: stage 1; the plane next cycle
            s1_y       <= cury;
            s1_cl      <= emit_cl;
            s1_cr      <= emit_cr;
            s1_col     <= col;
            s1_moire   <= moire;
            state <= S_DONE;
          end
        end

        default: begin // S_DONE
          quad_done <= 1'b1;
          emit_mode <= EM_WALK;
          state     <= S_IDLE;
        end
      endcase
    end
  end

  // The per-pixel step and the texture state do not change within a quad, so
  // they ride out continuously beside the span rather than being latched again
  // at every emit.
  assign span_dudx   = dudx;
  assign span_dvdx   = dvdx;
  assign span_doozdx = dodx;                               // R337
  assign span_tex    = tex_r;
  assign span_uvs    = uvs_r;                              // R940
  assign span_tex_en = tex_ok;

  // ------------------------------------------------------------ R828: the mip bias
  // Stage one of S_OZ selects vertex oz_i (oz_u, oz_v are its raw 11.2 u, v);
  // this takes its x, y and log2 of its 1/z on the quad's normalised scale
  // alongside. Stage two -- the vertex standing in oz_u -- makes the edge from
  // the vertex before it; after vertex 3 one more cycle closes 3 -> 0. A
  // triangle (a corner repeated) has an edge of length zero, which is skipped.
  //
  // In quarter levels: lq(v) = 4 * msb(v) + the two bits below it, and
  //   K_e = lq(max|du|,|dv|) - lq(max|dx|,|dy|) + lo_a + lo_b + 120
  // where lo = 4 * (14 - (emax - e)) + m[7:6] is log2 of oz_norm's value, and
  // 120 = 8 * 16 - 8 folds in span_ooz's 16 fraction bits and the quarter
  // texels (m2_span_tex: L = (K - 2 lq(ooz)) >> 2). The maxima are ORs and the
  // magnitudes one's complements -- a log only needs the leading bits.
  localparam logic signed [9:0] K_NONE = -10'sd512;
  localparam logic signed [9:0] K_TOP  =  10'sd511;   // R828a: the min's start
  // x and y in 13 bits: m2_quad_store saturates every screen coordinate to
  // XW = 13 (R327), so the differences fit 14. The first vertex's x, y are
  // read from sx[0], sy[0], which hold until the next quad.
  logic signed [12:0] kz_x, kz_y, kp_x, kp_y;
  logic [12:0]        kp_u, kp_v, kf_u, kf_v;
  logic signed [6:0]  kz_l, kp_l, kf_l;
  logic               kz_lv, kp_lv, kf_lv;
  logic               k_close;
  logic signed [9:0]  k_r;
  logic signed [9:0]  k_n;    // R828a: the smallest edge K
  logic signed [9:0]  k_o;    // R828a: the quad's K as it leaves
  // Every edge K lies in [49, 301] (lq's 0..63 each way, the two 1/z logs'
  // -8..118, + 120), so with an edge the spread is 0..252 and nothing wraps.
  wire  signed [9:0]  k_d = k_r - k_n;
  function automatic logic [5:0] lq(input logic [14:0] v);
    logic [3:0]  m;
    logic [16:0] w;
    begin
      m = 4'd0;
      for (int i = 0; i < 15; i++) if (v[i]) m = 4'(i);
      // the two bits below the leading one: w[m+1:m] of v with two zeros
      // under it -- in range for every m (R807: no select past the end)
      w  = {v, 2'b00};
      lq = {m, w[{1'b0, m} +: 2]};
    end
  endfunction
  wire        ks1   = MIP && (pf_st == S_OZ) && !oz_pre && !oz_last;   // stage one
  wire        ks2   = MIP && (pf_st == S_OZ) && !oz_pre && oz_w_v;     // stage two
  wire [7:0]  kd_e  = oz_emax - qoz[oz_i][15:8];
  // the edge: from kp to the vertex in stage two, or to the first on the close
  wire signed [12:0] kb_x = k_close ? sx[0][12:0] : kz_x;
  wire signed [12:0] kb_y = k_close ? sy[0][12:0] : kz_y;
  wire [12:0]        kb_u = k_close ? kf_u : oz_u;
  wire [12:0]        kb_v = k_close ? kf_v : oz_v;
  wire signed [6:0]  kb_l = k_close ? kf_l : kz_l;
  wire               kb_lv = k_close ? kf_lv : kz_lv;
  // THREE STAGES, NOT ONE (post-map timing: the whole edge in one cycle,
  // k_close -> subtract -> magnitude -> leading one -> sum -> max -> k_r,
  // was -8.1 ns at clk_sys). E1 the differences' magnitudes and the 1/z logs'
  // sum, E2 the two logs, E3 K_e, then the running max. K is final four
  // cycles after the close, and the first span waits for the plane fit
  // (~18 cycles after S_OZ), so nothing waits for it.
  wire               ke_go = (ks2 && (oz_w != 2'd0)) || k_close;   // an edge this cycle
  wire               k_new = ks2 && (oz_w == 2'd0);                // a new quad's first vertex
  wire signed [13:0] ke_du = 14'({1'b0, kb_u}) - 14'({1'b0, kp_u});
  wire signed [13:0] ke_dv = 14'({1'b0, kb_v}) - 14'({1'b0, kp_v});
  wire signed [13:0] ke_dx = 14'(kb_x) - 14'(kp_x);
  wire signed [13:0] ke_dy = 14'(kb_y) - 14'(kp_y);
  logic              e1_v, e2_v, e3_v;
  logic [12:0]       e1_t;
  logic [12:0]       e1_s;
  logic signed [7:0] e1_l, e2_l;
  logic [5:0]        e2_lt, e2_ls;
  logic signed [9:0] e3_k;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      e1_v <= 1'b0; e2_v <= 1'b0; e3_v <= 1'b0;
      e1_t <= '0; e1_s <= '0; e1_l <= '0; e2_l <= '0; e2_lt <= '0; e2_ls <= '0; e3_k <= '0;
    end else begin
      // E1
      e1_v <= ke_go && !k_new && kp_lv && kb_lv;
      e1_t <= 13'(ke_du ^ {14{ke_du[13]}}) | 13'(ke_dv ^ {14{ke_dv[13]}});
      e1_s <= 13'(ke_dx ^ {14{ke_dx[13]}}) | 13'(ke_dy ^ {14{ke_dy[13]}});
      e1_l <= {kp_l[6], kp_l} + {kb_l[6], kb_l};
      // E2 -- an edge of length zero (a triangle's repeated corner) is no edge
      e2_v  <= e1_v && !k_new && (e1_t != 13'd0) && (e1_s != 13'd0);
      e2_lt <= lq({2'd0, e1_t});
      e2_ls <= lq({2'd0, e1_s});
      e2_l  <= e1_l;
      // E3
      e3_v <= e2_v && !k_new;
      e3_k <= 10'({4'd0, e2_lt}) - 10'({4'd0, e2_ls}) + {{2{e2_l[7]}}, e2_l} + 10'sd120;
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      kz_x <= '0; kz_y <= '0; kz_l <= '0; kz_lv <= 1'b0;
      kp_x <= '0; kp_y <= '0; kp_u <= '0; kp_v <= '0; kp_l <= '0; kp_lv <= 1'b0;
      kf_u <= '0; kf_v <= '0; kf_l <= '0; kf_lv <= 1'b0;
      k_close <= 1'b0; k_r <= K_NONE; k_n <= K_TOP; k_o <= K_NONE;
    end else begin
      if (ks1) begin
        kz_x  <= sx[oz_i][12:0];
        kz_y  <= sy[oz_i][12:0];
        kz_lv <= (qoz[oz_i][15:8] != 8'd0) && (kd_e < 8'd16);
        kz_l  <= 7'sd56 - 7'({1'b0, kd_e[3:0], 2'b00}) + 7'({5'd0, qoz[oz_i][7:6]});
      end
      k_close <= ks2 && (oz_w == 2'd3);
      if (ks2) begin
        kp_x <= kz_x; kp_y <= kz_y; kp_u <= oz_u; kp_v <= oz_v; kp_l <= kz_l; kp_lv <= kz_lv;
        if (oz_w == 2'd0) begin
          kf_u <= oz_u; kf_v <= oz_v; kf_l <= kz_l; kf_lv <= kz_lv;
        end
      end
      // E4: the running max; a new quad starts it again (and the stages
      // above drop anything still in them from the last one)
      if (k_new)                          k_r <= K_NONE;
      else if (e3_v && (e3_k > k_r))      k_r <= e3_k;
      // R828a: and the running min beside it
      if (k_new)                          k_n <= K_TOP;
      else if (e3_v && (e3_k < k_n))      k_n <= e3_k;
      // E5 (R828a): the max less a quarter or a half of the spread, by the
      // OSD; no edge, or the OSD's Off, is no level. One cycle after the max:
      // final five cycles after the close, still ahead of the first span (the
      // bench checks every span of every quad, back to back, and still passes
      // with K held back 16 cycles more; 24 fails). A quad is not accepted while a
      // span is held (R544), so k_o cannot change under one.
      // R828c: and a quad the game keeps at level 0 (mz_r) is no level too.
      // R940: plus s levels (4s quarters) for a quad stored >> s: every
      // edge's |du|, |dv| is 2^s too small, and lq of a value 2^s times
      // larger is exactly 4s more (the spread k_d is unchanged).
      k_o <= ((mip_mode == 2'd0) || (k_r == K_NONE) || mz_r) ? K_NONE
           : ((mip_mode == 2'd3) ? k_r - (k_d >>> 1)
           :  (mip_mode == 2'd2) ? k_r - (k_d >>> 2)
           :                       k_r) + 10'({uvs_r, 2'b00});
    end
  end
  assign span_mipk = MIP ? k_o : 10'sd0;

  // R544: AND NOT WHILE THE LAST SPAN IS STILL WAITING. span_tex_en and the
  // three gradients below are NOT latched with a span -- they are this quad's
  // registers -- so accepting the next quad while a span is held resets them
  // under it, and that span goes out with the next quad's texture state (flat
  // white, in the bench). The slower fill never let the span queue back up;
  // the faster one does. Nothing can be emitted while a span is held anyway.
  always_comb in_ready = (state == S_IDLE) && (pf_st == S_IDLE) && !span_valid && !s1_valid;   // R715
  assign dbg_hot    = state;   // R449: free, no counter behind it
  assign dbg_hotcyc = 16'd0;

endmodule
