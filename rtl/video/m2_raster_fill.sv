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
module m2_raster_fill (
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
  input  logic [23:0]        in_tex,

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
  // R274: the span's texture, as a starting coordinate and a per-pixel step,
  // both 16.16 in texels. The consumer walks u += span_dudx a pixel.
  output logic signed [31:0] span_u, span_v,
  // 8.8 texels a pixel; the span walk shifts it up to its own 16.16.
  output logic signed [15:0] span_dudx, span_dvdx,
  // R337: the perspective span. u and v above are u/z and v/z now; these carry
  // 1/z and its gradient, and `span_oshift` is the per-quad scale that
  // m2_span_tex must undo -- u = (uoz << oshift) / ooz.
  // THE SCALE IS A CONSTANT 15 AND IS NOT CARRIED. Normalisation puts the
  // largest 1/z of the quad in [2^14, 2^15), so (u * ooz) >> 15 lands in
  // [u/2, u) and fits the same 13 bits u did. m2_span_tex undoes it with a
  // fixed shift: u = (uoz << 15) / ooz.
  output logic signed [31:0] span_ooz,
  output logic signed [15:0] span_doozdx,
  output logic [23:0]        span_tex,
  output logic               span_tex_en,

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
  localparam logic [4:0] S_DIVB     = 5'd8;
  localparam logic [4:0] S_DIVBW    = 5'd9;
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

  localparam logic [1:0] EM_WALK = 2'd0;   // swapf-ordered edge pair
  localparam logic [1:0] EM_RAW  = 2'd1;   // xa, xb in chain order (fill_line tail)
  localparam logic [1:0] EM_FLAT = 2'd2;   // the flat-quad min/max pair

  logic [4:0] state /* verilator public_flat_rd */;

  // Latched quad. sx/sy are the raw screen coordinates: the wireframe test
  // compares them whole, so the pre-shift value has to survive.
  logic signed [15:0] sx [0:3];
  logic signed [15:0] sy [0:3];
  logic [23:0]        col;
  logic               moire;

  // 16.16 x, exactly as fill_quad forms it: an int32 left shift that discards
  // everything above bit 15.
  logic signed [31:0] px [0:3];
  always_comb begin
    for (int i = 0; i < 4; i++) px[i] = $signed({sx[i], 16'h0000});
  end

  // Chain state. Edge A walks ps1 downward, edge B walks ps2 upward, both from
  // the top vertex. The doubled 8-entry array in MAME exists to let them run in
  // opposite directions without wrapping logic; here the index is 3 bits and
  // the array read masks to 2.
  logic [2:0]         ps1, ps2;
  logic signed [31:0] xa, xb;     // 16.16 accumulators
  logic signed [31:0] sla, slb;   // 16.16 per scanline
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
  logic [12:0]        qu [0:3], qv [0:3];
  // 1/z on a scale common to the quad: the largest of the four fills bit 15.
  logic [15:0]        qoz [0:3];
  logic [1:0]         oz_i;              // which vertex the normaliser is on
  logic [7:0]         oz_emax;           // largest exponent of the four, latched

  // R337: the four exponents and the largest, combinational off the INPUTS
  // because emax has to be known before the first vertex is rewritten.
  wire [7:0] oze01_c = (in_oz1[15:8] > in_oz0[15:8]) ? in_oz1[15:8] : in_oz0[15:8];
  wire [7:0] oze23_c = (in_oz3[15:8] > in_oz2[15:8]) ? in_oz3[15:8] : in_oz2[15:8];
  wire [7:0] oz_emax_c = (oze23_c > oze01_c) ? oze23_c : oze01_c;

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
  logic signed [15:0] dodx, dody;        // the 1/z plane's gradients
  logic signed [31:0] base_o, nxo, nyo;
  logic               pf_c;              // the third fit's second divide is back
  logic [23:0]        tex_r;
  logic               tex_ok;            // the fit succeeded and the poly is textured
  // SIXTEEN-BIT GRADIENTS, 8.8 TEXELS PER PIXEL (R286). Thirty-two bits of
  // gradient buys nothing a picture can show: the steepest useful slope is a
  // few texels a pixel and 1/256 of a texel of error accumulates to under half
  // a texel across the widest span this screen has. What it costs is every
  // multiplier and every barrel shifter in the fit at double width, on a part
  // with 550 ALMs free.
  logic signed [15:0] dudx, dudy, dvdx, dvdy;
  logic signed [31:0] det_r;
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

  wire signed [15:0] pf_ax = sx[fb] - sx[fa];
  wire signed [15:0] pf_ay = sy[fb] - sy[fa];
  wire signed [15:0] pf_bx = sx[fc] - sx[fa];
  wire signed [15:0] pf_by = sy[fc] - sy[fa];
  wire signed [15:0] pf_u1 = 16'({3'd0, qu[fb]}) - 16'({3'd0, qu[fa]});
  wire signed [15:0] pf_u2 = 16'({3'd0, qu[fc]}) - 16'({3'd0, qu[fa]});
  wire signed [15:0] pf_v1 = 16'({3'd0, qv[fb]}) - 16'({3'd0, qv[fa]});
  // R337: 1/z's, which fit 16-bit signed because oz_norm caps them at bit 14.
  wire signed [15:0] pf_o1 = 16'(qoz[fb]) - 16'(qoz[fa]);
  wire signed [15:0] pf_o2 = 16'(qoz[fc]) - 16'(qoz[fa]);
  wire signed [15:0] pf_v2 = 16'({3'd0, qv[fc]}) - 16'({3'd0, qv[fa]});

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
  wire [5:0]  det_clz = clz32(det_abs);
  // Bits the denominator must lose to fit in sixteen.
  wire [5:0]  den_sh_c = (det_clz >= 6'd16) ? 6'd0 : (6'd16 - det_clz);
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
  logic               b_wait;
  logic         [1:0] nrm_wait;   // R466: three cycles, the recip takes three
  logic pfn_wait;   // R461: S_PF_N takes two cycles, encode then shift
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
        net = 9'sd9 - 9'(z) - 9'(den_sh);   // 8.8, not 16.16
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
  function automatic logic signed [15:0] pf_scale_n(input logic signed [31:0] q,
                                                    input logic signed [8:0]  net,
                                                    input logic               zbig);
    logic signed [39:0] r;
    begin
      if (zbig) pf_scale_n = 16'sd0;
      else begin
        r = (net >= 9'sd0) ? (40'(q) <<< net[5:0]) : (40'(q) >>> (-net));
        if      (r >  40'sd32767) pf_scale_n =  16'sd32767;
        else if (r < -40'sd32767) pf_scale_n = -16'sd32767;
        else                      pf_scale_n =  16'(r);
      end
    end
  endfunction

  logic signed [31:0] base_u, base_v;   // u,v at screen (0,0) on the fitted plane
  // ONE EVALUATION OF THE PLANE, NOT THREE. The three emit sites -- the flat
  // quad, the segment walk and the fill_line tail -- all emit at `emit_cl` and
  // at a y that is either cury or walk_y, so one expression serves them all.
  // Written out at each site it was six multiply-add pairs instead of two, and
  // this module is what put the design over the device.
  wire signed [15:0] emit_y  = (state == S_FS_WALK) ? walk_y : cury;
  wire signed [31:0] emit_u  = uv_at(base_u, dudx, dudy, emit_cl, emit_y);
  wire signed [31:0] emit_v  = uv_at(base_v, dvdx, dvdy, emit_cl, emit_y);
  wire signed [31:0] emit_o  = uv_at(base_o, dodx, dody, emit_cl, emit_y);   // R337

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
                                               input logic signed [15:0] gx,
                                               input logic signed [15:0] gy,
                                               input logic signed [15:0] x,
                                               input logic signed [15:0] y);
    logic signed [31:0] gxp, gyp;
    begin
      gxp = gx * x;
      gyp = gy * y;
      uv_at = base + (gxp <<< 8) + (gyp <<< 8);
    end
  endfunction
  logic [2:0]         ps1m1, ps2p1;
  logic signed [15:0] ya_next, yb_next;
  always_comb begin
    ps1m1   = ps1 - 3'd1;
    ps2p1   = ps2 + 3'd1;
    ya_next = sy[ps1m1[1:0]];
    yb_next = sy[ps2p1[1:0]];
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
  logic signed [31:0] mul_delta, mul_sl;
  logic signed [63:0] mul_prod;
  always_comb mul_prod = mul_delta * mul_sl;

  // ------------------------------------------------------- vertex selection
  // Tournaments, arranged so the lowest index wins every tie. MAME scans
  // linearly with a strict comparison, which has the same effect, and the tie
  // rule decides which vertex a degenerate quad starts from.
  logic [1:0] pmin01, pmin23, pmin_c, pmax01, pmax23, pmax_c;
  always_comb begin
    pmin01 = (sy[1] < sy[0]) ? 2'd1 : 2'd0;
    pmin23 = (sy[3] < sy[2]) ? 2'd3 : 2'd2;
    pmin_c = (sy[pmin23] < sy[pmin01]) ? pmin23 : pmin01;
    pmax01 = (sy[1] > sy[0]) ? 2'd1 : 2'd0;
    pmax23 = (sy[3] > sy[2]) ? 2'd3 : 2'd2;
    pmax_c = (sy[pmax23] > sy[pmax01]) ? pmax23 : pmax01;
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

    emit_xl = 16'(emit_l >>> 16);
    emit_xr = 16'(emit_r >>> 16);
    emit_cl = (emit_xl < view_x1) ? view_x1 : emit_xl;
    emit_cr = (emit_xr > view_x2) ? view_x2 : emit_xr;
    emit_ok = (emit_cl <= emit_cr);
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
  logic signed [31:0] nsel_c;
  logic [5:0]         zsel_c;
  always_comb begin
    case (state)
      S_PF_Q1:  begin nsel_c = nyu; zsel_c = nyu_z; end
      S_PF_Q1W: begin nsel_c = nxv; zsel_c = nxv_z; end
      S_PF_Q2:  begin nsel_c = nyv; zsel_c = nyv_z; end
      S_PF_Q2W: begin nsel_c = nxo; zsel_c = nxo_z; end
      S_PF_Q3:  begin nsel_c = nyo; zsel_c = nyo_z; end
      default:  begin nsel_c = nxu; zsel_c = nxu_z; end   // S_PF_NRM, priming
    endcase
  end
  wire signed [31:0] mul_n_c = pf_shift(nsel_c, zsel_c);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= S_IDLE;
      ps1        <= 3'd0;
      ps2        <= 3'd0;
      xa         <= 32'sd0;
      xb         <= 32'sd0;
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
      mul_delta  <= 32'sd0;
      mul_sl     <= 32'sd0;
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
      tex_ok <= 1'b0; pf_second <= 1'b0; tex_r <= '0;
      det_r <= '0; den_sh <= 6'd0; nxu <= '0; nyu <= '0; nxv <= '0; nyv <= '0;
      q_num_a <= '0; q_num_b <= '0; q_z_a <= '0; q_z_b <= '0;
      nxu_z <= '0; nyu_z <= '0; nxv_z <= '0; nyv_z <= '0;
      nxo_z <= '0; nyo_z <= '0; mul_n <= '0; mul_z <= 6'd0;   // R441/R442
      net_r <= 9'sd0; zbig_r <= 1'b0;   // R459
      den_a <= 16'd1; nrm_wait <= 2'd0; pfn_wait <= 1'b0;    // R449/R461/R466
      // R451: these were initialised in the prime step and NOT in reset. A
      // register that only gets a value once the state machine reaches a
      // particular state is undefined for every cycle before it, and b_wait
      // powering up set would make S_PF_B compute its bases from a gradient
      // that had not been latched yet.
      mul_q_r <= '0; mul_zr <= 6'd0; b_wait <= 1'b0;
      dudx <= 16'sd0; dudy <= 16'sd0; dvdx <= 16'sd0; dvdy <= 16'sd0;
      for (int k = 0; k < 4; k++) begin qu[k] <= '0; qv[k] <= '0; qoz[k] <= '0; end
      oz_i <= 2'd0; oz_emax <= 8'd0; dodx <= 16'sd0; dody <= 16'sd0;
      base_o <= '0; nxo <= '0; nyo <= '0; pf_c <= 1'b0;
      span_valid <= 1'b0;
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
      for (int i = 0; i < 4; i++) begin
        sx[i] <= 16'sd0;
        sy[i] <= 16'sd0;
      end
    end else begin
      div_start  <= 1'b0;
      divb_start <= 1'b0;
      quad_done  <= 1'b0;
      line_case <= 1'b0;
      if (span_valid && span_ready) span_valid <= 1'b0;

      case (state)
        S_IDLE: begin
          if (in_valid) begin
            sx[0] <= in_x0; sy[0] <= in_y0;
            sx[1] <= in_x1; sy[1] <= in_y1;
            sx[2] <= in_x2; sy[2] <= in_y2;
            sx[3] <= in_x3; sy[3] <= in_y3;
            col   <= in_col;
            moire <= in_moire;
            qu[0] <= in_u0; qv[0] <= in_v0; qu[1] <= in_u1; qv[1] <= in_v1;
            qu[2] <= in_u2; qv[2] <= in_v2; qu[3] <= in_u3; qv[3] <= in_v3;
            qoz[0] <= in_oz0; qoz[1] <= in_oz1;            // R337: still minifloats here
            qoz[2] <= in_oz2; qoz[3] <= in_oz3;
            oz_emax <= oz_emax_c;
            oz_i    <= 2'd0;
            tex_r     <= in_tex;
            tex_ok    <= 1'b0;
            pf_second <= 1'b0;
            dudx <= 16'sd0; dudy <= 16'sd0; dvdx <= 16'sd0; dvdy <= 16'sd0;
            // An untextured quad pays nothing for any of this.
            // R337: normalise 1/z before the plane fit, because the fit runs
            // on u/z and v/z and those do not exist until it has.
            state <= in_tex[0] ? S_OZ : S_MINMAX;
          end
        end

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
        S_OZ: begin
          automatic logic [15:0] n = oz_norm(qoz[oz_i], oz_emax);
          qoz[oz_i] <= n;
          qu[oz_i]  <= 13'((29'(qu[oz_i]) * 29'(n)) >> 15);
          qv[oz_i]  <= 13'((29'(qv[oz_i]) * 29'(n)) >> 15);
          if (oz_i == 2'd3) state <= S_PF_D;
          else              oz_i  <= oz_i + 2'd1;
        end

        S_PF_D: begin
          det_r <= 32'(pf_ax) * 32'(pf_by) - 32'(pf_bx) * 32'(pf_ay);
          state <= S_PF_N;
        end

        S_PF_N: begin
          if (det_r == 32'sd0) begin
            if (!pf_second) begin
              pf_second <= 1'b1;
              state     <= S_PF_D;
            end else begin
              // No plane through these three points: draw it flat.
              tex_ok <= 1'b0;
              state  <= S_MINMAX;
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
          end else if (!pfn_wait) begin
            pfn_wait <= 1'b1;
            den_sh <= den_sh_c;          // R289/R461: encode, and only encode
            nxu <= 32'(pf_u1) * 32'(pf_by) - 32'(pf_u2) * 32'(pf_ay);
            nyu <= 32'(pf_ax) * 32'(pf_u2) - 32'(pf_bx) * 32'(pf_u1);
            nxv <= 32'(pf_v1) * 32'(pf_by) - 32'(pf_v2) * 32'(pf_ay);
            nyv <= 32'(pf_ax) * 32'(pf_v2) - 32'(pf_bx) * 32'(pf_v1);
            nxo <= 32'(pf_o1) * 32'(pf_by) - 32'(pf_o2) * 32'(pf_ay);   // R337
            nyo <= 32'(pf_ax) * 32'(pf_o2) - 32'(pf_bx) * 32'(pf_o1);
          end else begin
            pfn_wait <= 1'b0;
            den_a  <= (den_n >= 0) ? 16'(den_n) : 16'(-den_n);   // R449/R461
            state <= S_PF_NRM;   // R418 counts the zeros before R337 shifts
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
        S_PF_NRM: if (nrm_wait != 2'd2) begin
          nrm_wait <= nrm_wait + 2'd1;
          // The counts still land on the FIRST cycle only -- repeating them on
          // the new third cycle would be harmless but would re-time six
          // priority encoders for nothing.
          if (nrm_wait == 2'd0) begin
            nxu_z <= pf_clz(nxu); nyu_z <= pf_clz(nyu);
            nxv_z <= pf_clz(nxv); nyv_z <= pf_clz(nyv);
            nxo_z <= pf_clz(nxo); nyo_z <= pf_clz(nyo);   // R441
          end
        end else begin
          nrm_wait <= 2'd0;
          mul_n <= mul_n_c;   // R457/R458: registered count, one shared shifter
          mul_z <= zsel_c;
          mul_q_r <= '0; mul_zr <= 6'd0; b_wait <= 1'b0;   // R450
          state <= S_PF_Q1;
        end

        // R441: one multiply a state. No handshake, no waiting: the quotient
        // is ready the cycle after the operands are.
        // R442: present the next numerator, latch the previous gradient.
        S_PF_Q1: begin
          mul_n <= mul_n_c; mul_z <= zsel_c;
          mul_q_r <= mul_q; mul_zr <= mul_z;   // R450
          net_r <= 9'sd9 - 9'(mul_z) - 9'(den_sh); zbig_r <= (mul_z >= 6'd32);   // R459
          state <= S_PF_Q1W;
        end

        S_PF_Q1W: begin
          mul_n <= mul_n_c; mul_z <= zsel_c;
          mul_q_r <= mul_q; mul_zr <= mul_z;   // R450
          net_r <= 9'sd9 - 9'(mul_z) - 9'(den_sh); zbig_r <= (mul_z >= 6'd32);   // R459
          dudx  <= pf_scale_n(mul_q_r, net_r, zbig_r);
          state <= S_PF_Q2;
        end

        S_PF_Q2: begin
          mul_n <= mul_n_c; mul_z <= zsel_c;
          mul_q_r <= mul_q; mul_zr <= mul_z;   // R450
          net_r <= 9'sd9 - 9'(mul_z) - 9'(den_sh); zbig_r <= (mul_z >= 6'd32);   // R459
          dudy  <= pf_scale_n(mul_q_r, net_r, zbig_r);
          state <= S_PF_Q2W;
        end

        S_PF_Q2W: begin
          mul_n <= mul_n_c; mul_z <= zsel_c;
          mul_q_r <= mul_q; mul_zr <= mul_z;   // R450
          net_r <= 9'sd9 - 9'(mul_z) - 9'(den_sh); zbig_r <= (mul_z >= 6'd32);   // R459
          dvdx  <= pf_scale_n(mul_q_r, net_r, zbig_r);
          state <= S_PF_Q3;
        end

        // R337: THE 1/z PLANE. Same shape as the two above and it reuses the
        // same pair of dividers -- m2_raster_div does not pipeline, so this is
        // two more divides of latency per quad, which is the real cost of
        // perspective correction and the thing to watch in `ready ms`.
        // R441: and the 1/z plane the same way. This also takes the clz out of
        // the same cycle as the shift, which is R418's fix applied to the round
        // R337 wrote before R418 existed.
        S_PF_Q3: begin
          mul_n <= mul_n_c; mul_z <= zsel_c;
          mul_q_r <= mul_q; mul_zr <= mul_z;   // R450
          net_r <= 9'sd9 - 9'(mul_z) - 9'(den_sh); zbig_r <= (mul_z >= 6'd32);   // R459
          dvdy  <= pf_scale_n(mul_q_r, net_r, zbig_r);
          state <= S_PF_Q3W;
        end

        S_PF_Q3W: begin
          mul_q_r <= mul_q; mul_zr <= mul_z;   // R450
          net_r <= 9'sd9 - 9'(mul_z) - 9'(den_sh); zbig_r <= (mul_z >= 6'd32);   // R459
          dodx  <= pf_scale_n(mul_q_r, net_r, zbig_r);
          state <= S_PF_B;
        end

        // The plane is held as its value at screen (0,0) plus two gradients,
        // so a span costs two multiplies and no state.
        S_PF_B: if (!b_wait) begin
          dody   <= pf_scale_n(mul_q_r, net_r, zbig_r);   // R450: the last gradient
          b_wait <= 1'b1;
        end else begin
          b_wait <= 1'b0;
          base_u <= 32'({19'd0, qu[fa]} <<< 16)
                  - ((32'(dudx * sx[fa])) <<< 8)
                  - ((32'(dudy * sy[fa])) <<< 8);
          base_v <= 32'({19'd0, qv[fa]} <<< 16)
                  - ((32'(dvdx * sx[fa])) <<< 8)
                  - ((32'(dvdy * sy[fa])) <<< 8);
          // R337: 1/z's own plane. qoz is 15 bits, so it shifts up by 16 the
          // same way, and the span walk divides by what this yields.
          base_o <= 32'({16'd0, qoz[fa]} <<< 16)
                  - ((32'(dodx * sx[fa])) <<< 8)
                  - ((32'(dody * sy[fa])) <<< 8);
          tex_ok <= 1'b1;
          state  <= S_MINMAX;
        end

        // One cycle of pure comparison: wireframe, top and bottom vertices, and
        // the three whole-quad rejects. Order matters — the flat case is taken
        // before the viewport rejects, because fill_line does its own y test.
        S_MINMAX: begin
          // One cycle of pure comparison, and now the ONLY cycle that does it.
          td_r   <= two_distinct;
          pmin_r <= pmin_c;
          symin  <= sy[pmin_c];
          symax  <= sy[pmax_c];
          xlo_r  <= xlo_c;
          xhi_r  <= xhi_c;
          state  <= S_CLASSIFY;
        end

        S_CLASSIFY: begin
          if (td_r) begin
            line_case <= 1'b1;
            quad_done <= 1'b1;
            state     <= S_IDLE;
          end else if (symin == symax) begin
            flat_lo   <= xlo_r;
            flat_hi   <= xhi_r;
            cury      <= symin;
            emit_mode <= EM_FLAT;
            state     <= S_FLAT;
          end else if ((symin > view_y2) || (symax <= view_y1)) begin
            quad_done <= 1'b1;
            state     <= S_IDLE;
          end else begin
            cury   <= symin;
            limy   <= (symax > view_y2) ? view_y2 : symax;
            ps1    <= {1'b1, pmin_r};      // pmin + 4
            ps2    <= {1'b0, pmin_r};
            need_a <= 1'b1;
            need_b <= 1'b1;
            state  <= S_START1;
          end
        end

        S_FLAT: begin
          if (!span_valid || span_ready) begin
            if ((cury <= view_y2) && (cury >= view_y1) && emit_ok) begin
              span_valid <= 1'b1;
              span_y     <= cury;
              span_x0    <= emit_cl;
              span_x1    <= emit_cr;
              span_col   <= col;
              span_moire <= moire;
              span_u     <= emit_u;
              span_ooz    <= emit_o;        // R337
              span_v     <= emit_v;
            end
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
          if (need_a) xa <= px[ps1[1:0]];
          if (need_b) xb <= px[ps2[1:0]];
          state <= S_DIVA;
        end

        // Both slopes at once. A side that does not need a new slope is
        // marked collected up front; both dividers are idle here because the
        // previous segment waited for both.
        S_DIVA: begin
          if (div_ready && !div_start && divb_ready && !divb_start) begin
            if (need_a) begin
              div_num   <= xa - px[ps1m1[1:0]];
              div_den   <= 32'(cury - ya_next);
              div_start <= 1'b1;
            end
            if (need_b) begin
              divb_num   <= xb - px[ps2p1[1:0]];
              divb_den   <= 32'(cury - yb_next);
              divb_start <= 1'b1;
            end
            got_a <= !need_a;
            got_b <= !need_b;
            state <= S_DIVAW;
          end
        end

        S_DIVAW: begin
          if (div_valid)  begin sla <= div_quo;  got_a <= 1'b1; end
          if (divb_valid) begin slb <= divb_quo; got_b <= 1'b1; end
          if ((got_a || div_valid) && (got_b || divb_valid)) state <= S_DECIDE;
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
        S_FS_ENTER: begin
          if (cury > view_y2) begin
            state <= S_FS_END;
          end else if (seg_y1 <= view_y1) begin
            mul_delta <= 32'(seg_y1 - cury);
            mul_sl    <= sla;
            skip_only <= 1'b1;
            state     <= S_FS_MULA;
          end else begin
            walk_end <= (seg_y1 > view_y2) ? (view_y2 + 16'sd1) : seg_y1;
            if (cury < view_y1) begin
              mul_delta <= 32'(view_y1 - cury);
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

        S_FS_MULA: begin
          xa     <= xa + mul_prod[31:0];
          mul_sl <= slb;
          state  <= S_FS_MULB;
        end

        S_FS_MULB: begin
          xb    <= xb + mul_prod[31:0];
          state <= skip_only ? S_FS_END : S_FS_SWAP;
        end

        // Left/right is decided here, once, and held for the whole segment.
        S_FS_SWAP: begin
          swapf     <= (xa > xb) || ((xa == xb) && (sla > slb));
          emit_mode <= EM_WALK;
          state     <= S_FS_WALK;
        end

        S_FS_WALK: begin
          if (walk_y >= walk_end) begin
            state <= S_FS_END;
          end else if (!span_valid || span_ready) begin
            if (emit_ok) begin
              span_valid <= 1'b1;
              span_y     <= walk_y;
              span_x0    <= emit_cl;
              span_x1    <= emit_cr;
              span_col   <= col;
              span_moire <= moire;
              span_u     <= emit_u;
              span_ooz    <= emit_o;        // R337
              span_v     <= emit_v;
            end
            xa     <= xa + sla;
            xb     <= xb + slb;
            walk_y <= walk_y + 16'sd1;
          end
        end

        S_FS_END: begin
          cury      <= seg_y1;
          skip_only <= 1'b0;
          if (seg_y1 >= limy) begin
            emit_mode <= EM_RAW;
            state     <= S_FINAL;
          end else begin
            if (need_a) ps1 <= ps1 - 3'd1;
            if (need_b) ps2 <= ps2 + 3'd1;
            state <= S_START1;
          end
        end

        // The last scanline of the quad, drawn unordered: fill_line does not
        // sort its two x values, so a crossed pair emits nothing.
        S_FINAL: begin
          if (!span_valid || span_ready) begin
            if ((cury == limy) && (cury <= view_y2) && (cury >= view_y1) && emit_ok) begin
              span_valid <= 1'b1;
              span_y     <= cury;
              span_x0    <= emit_cl;
              span_x1    <= emit_cr;
              span_col   <= col;
              span_moire <= moire;
              span_u     <= emit_u;
              span_ooz    <= emit_o;        // R337
              span_v     <= emit_v;
            end
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
  assign span_tex_en = tex_ok;

  always_comb in_ready = (state == S_IDLE);
  assign dbg_hot    = state;   // R449: free, no counter behind it
  assign dbg_hotcyc = 16'd0;

endmodule
