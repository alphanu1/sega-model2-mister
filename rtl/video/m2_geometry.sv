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
// THE GEOMETRY PIPELINE, ASSEMBLED. object_data in, screen quads out.
//
//     m2_geo_engine    the stream grammar: vertices, links, rope   (ours, R171)
//        |             transform_point + apply_focus -> VIEW space
//        v
//     the quad projector  four vertices through m2_geo_project, one at a time
//        |
//        v
//     m2_geo_clip      frustum clip in VIEW space; vertices it creates are
//        |  pj_*  ->   projected through the SAME m2_geo_project
//        v
//     q_*              to m2_quad_store / m2_raster3d
//
// R172 WAS WRONG AND THIS IS THE CORRECTION. It recorded that Model 2 has no
// perspective divide -- that apply_focus IS the projection and a vertex leaves
// the geometrizer already in pixels. It does not. MAME's model2_3d_project
// (model2_v.cpp:656) is:
//
//     v.x = crtc_xoffset + center[0] + (v.x / v.pz)
//     v.y = ((384 - center[1]) + crtc_yoffset) - (v.y / v.pz)
//
// The divide is there; it simply lives in the RASTERIZER rather than in the
// geometrizer, which is why reading geo_parse alone does not show it. The
// clipping is in the rasterizer too, and it is a frustum clip in view space
// against four planes built from the viewport and the centre
// (model2_v.cpp:882) -- not a box test on pixels.
//
// So the shape is Model 1's shape after all: transform, clip in view space,
// divide, screen. m2_geo_project's contract
//
//     s.x = xc + (x/z * zoomx + viewx)     s.y = yc - (y/z * zoomy + viewy)
//
// is Model 2's projection exactly, with zoom = 1 and view = 0, xc absorbing
// crtc_xoffset + center[0] and yc absorbing (384 - center[1]) + crtc_yoffset.
// apply_focus plays the part Model 1 gives to zoom, one stage earlier. Nothing
// needed writing: the cost of the wrong belief was a module (m2_geo_screen)
// that has been deleted, and a bench that caught it before a build.
//
// WHY THIS IS WRITTEN HERE RATHER THAN PORTED. Model 1's m1_geometry does the
// same job with these same stages, but its interface is bound to that board --
// zoomx/zoomy/viewx/viewy from its own commands, texture, palette, xlat, log
// RAM -- and it embeds Model 1's display-list walker. Study R170 draws that
// line: the arithmetic transfers, the grammar does not.
//
// FLAT, DELIBERATELY. q_col is a constant. Lighting needs the normal
// transformed and two dot products; texture needs the texture ROM and its own
// cache. Neither changes the dataflow here, and m2_raster3d takes one 24-bit
// colour with no texture input at all, so shape comes first and shading second.

`timescale 1ns/1ps

module m2_geometry (
  input  logic        clk,
  input  logic        rst_n,

  // ---- from the display-list walker
  input  logic        start,
  input  logic [31:0] oba, obc,
  // BUSY MEANS THE WHOLE PIPELINE, NOT THE ENGINE. The engine finishes reading
  // an object long before its last polygon has been through four 29-cycle
  // reciprocals and the clipper. Two things depend on this being the honest
  // answer: the walker's interlock, which hands the SDRAM port back on it, and
  // q_end, which releases the rasterizer's sort -- an early q_end throws away
  // whatever was still in flight at the end of a frame.
  output logic        busy,
  input  logic        mat_we,
  input  logic [3:0]  mat_idx,
  input  logic [31:0] mat_data,
  input  logic [31:0] foc_x, foc_y,

  // ---- the vertex stream, shared sequentially with the walk
  output logic        mem_req,
  output logic [23:0] mem_addr,
  input  logic [31:0] mem_data,
  input  logic        mem_ack,

  // ---- the viewport. xc/yc are the projection centre in pixels; a_* are the
  //      four frustum planes as SLOPES, per m2_geo_clip's header.
  input  logic [31:0] xc, yc,
  input  logic [31:0] a_left, a_right, a_bottom, a_top,
  // ---- R222: what the polygon's colour needs, and the memory space select
  //      the engine's reads carry (0 polygon memory, 1 texture, 2 palette
  //      mirror, 3 translation mirror). The colour travels with the polygon
  //      from the engine to the clipper's in_col, where a constant used to be.
  input  logic [31:0] tha,
  input  logic [31:0] tpa,        // R268: the texture-point address, for the UVs
  input  logic [31:0] lit_x, lit_y, lit_z,
  input  logic        tp_we,
  input  logic [4:0]  tp_idx,
  input  logic [7:0]  tp_diffuse, tp_ambient,
  input  logic        col_inval,
  input  logic [1:0]  tex_lum,           // R239
  input  logic [1:0]  gamma_sel,         // R630
  output logic [1:0]  mem_space,
  output logic [15:0] dbg_col_miss,

  // ---- screen quads out
  output logic        q_valid,
  input  logic        q_ready,
  output logic signed [15:0] q_x0, q_y0, q_x1, q_y1,
  output logic signed [15:0] q_x2, q_y2, q_x3, q_y3,
  // R270/R273: the quad's texture coordinates, clipped with it. FLOATS INSIDE
  // THE CLIPPER, TEXELS ON THE WAY OUT: the store keeps 11.2 texels a
  // component, so the conversion happens here, once, where the float still
  // exists.
  output logic [15:0] q_oz0, q_oz1, q_oz2, q_oz3,   // R334: 1/z, minifloat
  output logic [12:0] q_u0, q_v0, q_u1, q_v1,
  output logic [12:0] q_u2, q_v2, q_u3, q_v3,
  output logic [23:0] q_tex,           // R271: the polygon's texture state
  // R784: the polygon's luma table is row 1 (texture header word 1's low byte,
  // poly_tex[31:24], which q_tex does not carry). Daytona's row 1 is the
  // inverse ramp its decals use; m2_raster3d takes it in q_tex[11].
  output logic        q_tlinv,
  output logic  [7:0] q_lum,
  // R626: each vertex's quarter pixel below q_x/q_y, {fy3,fx3,...,fy0,fx0}.
  // For the texture plane fit only (m2_geo_project says why).
  output logic [15:0] q_frac,
  output logic [23:0] q_col,
  output logic [31:0] q_z,

  output logic [15:0] dbg_polys, dbg_objects, dbg_capped,
  output logic [15:0] dbg_culled,          // R219
  output logic [15:0] dbg_clip_in, dbg_clip_out, dbg_clip_dropped,
  output logic [15:0] dbg_nonfinite,   // polygons refused before the arithmetic
  output logic [15:0] dbg_behind,      // R246: polygons entirely behind the eye (max_z < 0)
  // R249: the frame's lighting, for the UART. The board is the only place the
  // "whole scene black" and "whole scene white" reports can be measured, and
  // neither has an instrument on it. `dbg_lum_go` is one pulse per polygon the
  // engine hands over, with its luminance.
  output logic        dbg_lum_go,
  output logic  [7:0] dbg_lum,
  input  logic  [7:0] zadj_e,          // R246: geo op 0x08's exponent byte, the z-sort bias
  output logic [15:0] dbg_pj_lost,     // projections abandoned on timeout
  // WHERE THE PIPELINE IS SITTING. The board wedges with the walk in W_OBJW,
  // which says only "the engine never finished". These say which stage.
  // Guessing at it has cost two wrong hypotheses already -- a NaN (refused
  // correctly, nonfinite counts it) and a z of zero (drains fine, tested).
  output logic  [4:0] dbg_eng_state,   // R719: 5 bits, from the engine's port
  output logic  [1:0] dbg_qst,
  output logic  [3:0] dbg_clip_state
);

  // ------------------------------------------------------------- the pool
  // Client 0 is the transform, 1 the focus multiplies, 2 the clipper, 3 the
  // projector. One multiplier, one adder and one divider between all four;
  // nothing here builds a private arbiter beside the pool, because that is how
  // a design ends up with two owners on one resource (study R167).
  localparam int NC = 4;
  logic [NC-1:0]  mul_req, mul_gnt, mul_rsp;
  logic [NC-1:0]  add_req, add_gnt, add_rsp, add_sub;
  logic [NC-1:0]  div_req, div_gnt, div_rsp;
  logic [31:0]    mul_a [NC], mul_b [NC], add_a [NC], add_b [NC], div_a [NC], div_b [NC];
  logic [31:0]    mul_res, add_res, div_res;

  m2_fp_pool #(.NC(NC)) u_pool (
    .clk(clk), .rst_n(rst_n),
    .mul_req(mul_req), .mul_a(mul_a), .mul_b(mul_b),
    .mul_gnt(mul_gnt), .mul_rsp(mul_rsp), .mul_res(mul_res),
    .add_req(add_req), .add_a(add_a), .add_b(add_b), .add_sub(add_sub),
    .add_gnt(add_gnt), .add_rsp(add_rsp), .add_res(add_res),
    .div_req(div_req), .div_a(div_a), .div_b(div_b),
    .div_gnt(div_gnt), .div_rsp(div_rsp), .div_res(div_res)
  );

  // ------------------------------------------------------------- the engine
  logic        eng_busy;
  logic        poly_valid, poly_ready;
  logic [31:0] v0x,v0y,v0z, v1x,v1y,v1z, v2x,v2y,v2z, v3x,v3y,v3z, poly_attr;
  logic [31:0] nrm_x, nrm_y, nrm_z;
  logic [23:0] poly_col, pcol;      // R222: the engine's colour, and the one in flight
  logic  [1:0] poly_zmode;          // R246: the engine's per-polygon z mode
  logic [31:0] poly_uv0, poly_uv1, poly_uv2, poly_uv3;   // R268
  logic [31:0] poly_tex;                                 // R271

  logic [4:0] eng_dbg_st;   // R719: telemetry
  m2_geo_engine u_engine (
    .tha(tha), .lit_x(lit_x), .lit_y(lit_y), .lit_z(lit_z),
    .tp_we(tp_we), .tp_idx(tp_idx), .tp_diffuse(tp_diffuse), .tp_ambient(tp_ambient),
    .col_inval(col_inval), .tex_lum(tex_lum), .gamma_sel(gamma_sel), .mem_space(mem_space),
    .poly_col(poly_col), .poly_zmode(poly_zmode), .poly_luma(dbg_lum), .dbg_col_miss(dbg_col_miss),
    // R268: the per-vertex texture coordinates, read beside the header
    .tpa(tpa), .poly_uv0(poly_uv0), .poly_uv1(poly_uv1),
    .poly_uv2(poly_uv2), .poly_uv3(poly_uv3),
    .poly_tex(poly_tex),
    .clk(clk), .rst_n(rst_n),
    .start(start), .oba(oba), .obc(obc), .busy(eng_busy),
    .mat_we(mat_we), .mat_idx(mat_idx), .mat_data(mat_data),
    .foc_x(foc_x), .foc_y(foc_y),
    .mem_req(mem_req), .mem_addr(mem_addr), .mem_data(mem_data), .mem_ack(mem_ack),
    .fmul_req(mul_req[1]), .fmul_a(mul_a[1]), .fmul_b(mul_b[1]),
    .fadd_req(add_req[1]), .fadd_a(add_a[1]), .fadd_b(add_b[1]),
    .fadd_gnt(add_gnt[1]), .fadd_rsp(add_rsp[1]), .fadd_res(add_res),
    .fmul_gnt(mul_gnt[1]), .fmul_rsp(mul_rsp[1]), .fmul_res(mul_res),
    .mul_req(mul_req[0]), .mul_a(mul_a[0]), .mul_b(mul_b[0]),
    .mul_gnt(mul_gnt[0]), .mul_rsp(mul_rsp[0]), .mul_res(mul_res),
    .add_req(add_req[0]), .add_a(add_a[0]), .add_b(add_b[0]), .add_sub(add_sub[0]),
    .add_gnt(add_gnt[0]), .add_rsp(add_rsp[0]), .add_res(add_res),
    .poly_valid(poly_valid), .poly_ready(poly_ready),
    .v0x(v0x), .v0y(v0y), .v0z(v0z), .v1x(v1x), .v1y(v1y), .v1z(v1z),
    .v2x(v2x), .v2y(v2y), .v2z(v2z), .v3x(v3x), .v3y(v3y), .v3z(v3z),
    .poly_attr(poly_attr), .nrm_x(nrm_x), .nrm_y(nrm_y), .nrm_z(nrm_z),
    .poly_prev_link(poly_prev_link), .poly_chain_ok(poly_chain_ok),
    .dbg_polys(dbg_polys), .dbg_objects(dbg_objects), .dbg_capped(dbg_capped),
    .dbg_culled(dbg_culled), .dbg_st(eng_dbg_st)
  );
  // add slot 1 is the engine's face test (R219), below.
  assign add_sub[1] = 1'b0;
  assign div_req[0] = 1'b0; assign div_a[0] = 32'd0; assign div_b[0] = 32'd0;
  assign div_req[1] = 1'b0; assign div_a[1] = 32'd0; assign div_b[1] = 32'd0;

  // ------------------------------------- the shared projector and its owner
  logic        pj_ready, pj_out_valid, pj_behind;
  logic [31:0] pj_out_z;
  logic signed [31:0] pj_out_sx, pj_out_sy;
  logic [1:0]         pj_out_fx, pj_out_fy;   // R626
  // R331: 1/z for this vertex, which the projector already computed.
  logic [31:0]        pj_out_invz;

  logic        w_pj_valid;                 // the quad projector below
  logic [31:0] w_pj_x, w_pj_y, w_pj_z;
  logic        k_pj_valid;                 // the clipper
  logic [31:0] k_pj_x, k_pj_y, k_pj_z;

  // THE CLIPPER HAS PRIORITY, and the grant is unambiguous rather than
  // hopeful. Both requesters can be up at once -- the clipper is working on
  // polygon n while the quad projector is already on n+1 -- so "pj_ready is
  // high, therefore I was served" is false for whichever one lost. Each side
  // is told separately whether IT was granted. Priority goes downstream
  // because draining the clipper is what frees the pipeline; the other way
  // round can wedge.
  wire pj_valid   = (w_pj_valid || k_pj_valid) && !pj_full;   // R758
  wire [31:0] pj_x = k_pj_valid ? k_pj_x : w_pj_x;
  wire [31:0] pj_y = k_pj_valid ? k_pj_y : w_pj_y;
  wire [31:0] pj_z = k_pj_valid ? k_pj_z : w_pj_z;
  wire w_granted  = pj_ready && w_pj_valid && !k_pj_valid && !pj_full;   // R758
  wire k_granted  = pj_ready && k_pj_valid && !pj_full;

  // ONE OPERATION IN FLIGHT AT A TIME, BECAUSE THERE IS ONLY ONE OWNER BIT.
  //
  // pj_owner is a single register latched at the grant. If a SECOND grant
  // happens before the first result emerges, it is overwritten and the first
  // requester's result is delivered to the wrong side -- so the first requester
  // waits forever for an out_valid that was routed elsewhere.
  //
  // That is what the board reported. With the engine idle and the clipper idle,
  // the quad projector sat in Q_WAIT and held m2_geometry.busy high, which held
  // the display-list walk in W_OBJW:
  //
  //     eng_state=E_IDLE  clip_state=K_IDLE  qst=Q_WAIT  walk=W_OBJW
  //     clip in=1 out=1 nonfinite=0
  //
  // The clipper had run, requested its own projections for the vertices it
  // creates, and taken ownership out from under a projection already in flight.
  //
  // pj_busy serialises the port: no new request is presented until the previous
  // result has been delivered. m2_geo_project's reciprocal is 29 cycles and does
  // not pipeline anyway, so this costs nothing that was not already being paid.
  // R758: AN OWNER PER PROJECTION IN FLIGHT, NOT ONE OWNER BIT. pj_busy
  // allowed one projection at a time, so the quad projector's four vertices
  // went through one after another at the projector's full latency (~65
  // cycles each) although m2_geo_project overlaps two -- the next point's
  // reciprocal during this one's scaling, 33 cycles a point streamed. The
  // quad projector held the engine in E_EMIT 10% and sat in Q_WAIT 64% of the
  // heaviest list. Results come back in grant order, so a queue of owners
  // routes each to its requester; R217's wrong-delivery fault cannot recur.
  logic [3:0] pj_own;                      // owners in flight, oldest in [0]
  logic [2:0] pj_n;                        // how many
  wire        pj_full = (pj_n == 3'd4);
  wire        pj_push = pj_valid && pj_ready;
  wire        pj_pop  = pj_out_valid && (pj_n != 3'd0);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pj_own <= 4'd0; pj_n <= 3'd0;
    end else begin
      case ({pj_push, pj_pop})
        2'b10: begin pj_own[pj_n[1:0]] <= k_pj_valid; pj_n <= pj_n + 3'd1; end
        2'b01: begin pj_own <= {1'b0, pj_own[3:1]}; pj_n <= pj_n - 3'd1; end
        2'b11: begin
          pj_own <= {1'b0, pj_own[3:1]};
          pj_own[pj_n[1:0] - 2'd1] <= k_pj_valid;
        end
        default: ;
      endcase
    end
  end
  wire w_pj_out_valid = pj_pop && !pj_own[0];
  wire k_pj_out_valid = pj_pop &&  pj_own[0];

  m2_geo_project u_project (
    .clk(clk), .rst_n(rst_n),
    .xc(xc), .yc(yc),
    .zoomx(32'h3F800000), .zoomy(32'h3F800000),   // 1.0: the focus was the zoom
    .viewx(32'd0), .viewy(32'd0),
    .in_valid(pj_valid), .in_ready(pj_ready),
    .in_x(pj_x), .in_y(pj_y), .in_z(pj_z),
    .mul_req(mul_req[3]), .mul_a(mul_a[3]), .mul_b(mul_b[3]),
    .mul_gnt(mul_gnt[3]), .mul_rsp(mul_rsp[3]), .mul_res(mul_res),
    .add_req(add_req[3]), .add_a(add_a[3]), .add_b(add_b[3]), .add_sub(add_sub[3]),
    .add_gnt(add_gnt[3]), .add_rsp(add_rsp[3]), .add_res(add_res),
    .div_req(div_req[3]), .div_a(div_a[3]), .div_b(div_b[3]),
    .div_gnt(div_gnt[3]), .div_rsp(div_rsp[3]), .div_res(div_res),
    .out_valid(pj_out_valid), .out_sx(pj_out_sx), .out_sy(pj_out_sy),
    .out_fx(pj_out_fx), .out_fy(pj_out_fy),   // R626
    .out_z(pj_out_z), .out_invz(pj_out_invz), .out_behind(pj_behind)
  );

  // --------------------------------------------------- the quad projector
  //
  // The engine emits four view-space vertices at once; the clipper wants them
  // as view-space floats AND as the pixels they project to, because a vertex it
  // does not cut can keep the pixel it already has. So each of the four goes
  // through the projector in turn and the results are held beside the floats.
  //
  // One at a time, and that is the reference's own rate: m2_geo_project's
  // reciprocal is 29 cycles and does not pipeline, so four vertices cost about
  // 120 cycles. At 50 MHz that is 2,700 polygons in a 60 Hz frame before this
  // stage is the limit, and the display lists measured here are far short of it.
  // R566: Q_CHK added -- the cull is decided a cycle after the polygon is taken.
  typedef enum logic [2:0] { Q_IDLE, Q_ISS, Q_WAIT, Q_OUT, Q_CHK, Q_MM, Q_MM2 } qst_t;   // R589: Q_MM; R740: Q_MM2
  qst_t qst;
  logic [1:0]  qi;
  logic [31:0] hx [4], hy [4], hz [4];
  logic signed [15:0] sx [4], sy [4];
  logic [3:0]  sf [4];                               // R626: {fy, fx} quarters
  logic [15:0] soz [4];                              // R334: 1/z per vertex
  logic        clip_in_valid;
  logic        clip_in_ready;
  logic [31:0] hzmin, hzmax;
  logic [31:0] zprev;               // R246: raster->polygon_z, carried between polygons
  logic [15:0] hzkey;               // the quantised key handed to the store
  logic [22:0] hzpre;                // R420: zval stage one, {neg, ex, ma}
  logic [9:0]  pj_wait;                    // cycles spent in Q_WAIT
  wire         pj_timeout = &pj_wait;
  // A VERTEX THE PREVIOUS POLYGON ALREADY PROJECTED IS NOT PROJECTED AGAIN
  // (R217). Model 2's polygon streams are strips: the engine carries two of
  // the last polygon's view-space points into the next (E_LINK, study R171),
  // so vertices 0 and 1 here are, bit for bit, two of the previous four. The
  // projector's reciprocal is 29 cycles and does not pipeline; projecting
  // four vertices a polygon was half of all the geometry's time on the
  // title (study R215). The last polygon's four vertices and their pixels
  // are kept, and a vertex equal to one of them takes its pixel instead of
  // a projection. Bit-exact equality on the floats is the right test: the
  // carried points are copies of registers, not recomputed. A miss costs
  // what it did before; the cache is cleared with the rest at reset only,
  // because a stale hit needs the same three floats to recur by chance.
  // SLIMMED: no comparators. The engine says which of the last polygon's
  // vertices this one carries (poly_prev_link) and whether that polygon was
  // emitted (poly_chain_ok); the eight 96-bit comparators were +465 ALUTs
  // on a device at 98% and hit two times in three, this hits every time.
  logic signed [15:0] csx [4], csy [4];
  logic [3:0]  csf [4];                  // R626
  logic        cvalid;                 // the last polygon's pixels are good
  logic [1:0]  poly_prev_link;
  logic        poly_chain_ok;
  logic [1:0]  hit_i [2];
  logic [1:0]  hit;
  always_comb begin
    case (poly_prev_link)
      2'd1:    begin hit_i[0] = 2'd2; hit_i[1] = 2'd1; end   // v0 = last v2, v1 = last v1
      2'd3:    begin hit_i[0] = 2'd0; hit_i[1] = 2'd3; end   // v0 = last v0, v1 = last v3
      default: begin hit_i[0] = 2'd3; hit_i[1] = 2'd2; end   // v0 = last v3, v1 = last v2
    endcase
    // THE STRIP CACHE IS OFF (R230), AND IT IS THE CHEAPER OF THE TWO TO LOSE.
    //
    // R217 lets a strip's carried vertices keep the pixel the previous polygon
    // projected, and R218 lets the clipper keep the pixel of a vertex no plane
    // cut. Together they put a vertex at exactly (0,0) -- the top-left corner
    // of the screen -- on 12 of the title's 4,096 sampled quads, always in slot
    // 1, and a quad with one corner pinned there is the white wedge across the
    // horizon the board has been drawing. Disabling EITHER removes all twelve,
    // so the fault is the pair: this cache supplies a pixel and the clipper
    // then trusts it instead of re-projecting.
    //
    // Measured, per object, over the title: both on 10,787 ticks; this cache
    // off 11,067; the clipper's reuse off 12,088. So the correct picture costs
    // 2.6% here and 12% there, and the choice makes itself.
    //
    // NOT the end of it. The remaining question is WHY the cached pixel is
    // wrong when the 3D coordinate beside it is right -- every one of the
    // twelve has all four z positive, so it is not a point behind the eye, and
    // the projector abandoned no projection on timeout in a whole run. The
    // answer is worth having: R217 is 2.6% and its mapping is sound against
    // the reference's carry rules, which were re-derived to check.
    hit[0] = 1'b0;
    hit[1] = 1'b0;
  end
  wire skip_here = (qi < 2'd2) && hit[qi[0]];

  // ---------------------------------------------------- THE GARBAGE GATE
  //
  // A POLYGON WITH A NaN OR AN INFINITY IN IT NEVER ENTERS THE ARITHMETIC, and
  // this is a hang fix, not tidiness.
  //
  // On hardware Daytona's one object_data points at SLOW POLYGON RAM, and
  // geo_polygon_data (opcode 0x05) is not implemented, so that RAM has never
  // been written. Unwritten memory reads 0xFFFF... -- a standing requirement in
  // docs/mister-integration.md that every bench here had ignored -- and
  // 0xFFFFFFFF read as an IEEE-754 float is a NaN. The clipper accepted such a
  // polygon and neither emitted nor dropped it:
  //
  //     H 00010000 04030000   objects rom=0 pram0=1, clip in=4 out=3 dropped=0
  //
  // frozen on every UART record. in_ready stayed low, so busy never fell, so
  // the walker sat in W_OBJW and THE WHOLE DISPLAY-LIST WALK DIED after one
  // object. Reproduced in tb_m2_geometry as in=1 out=0 dropped=0, busy stuck.
  //
  // MAME does not need this because it runs on host floats, where a NaN
  // propagates through the clip tests, every comparison answers false, and the
  // polygon simply fails to draw. Ours is a handshake pipeline: a stage that
  // never answers stops everything behind it.
  //
  // The test is the exponent field alone -- 8'hFF is NaN or Infinity, and
  // neither can be drawn -- so it is twelve 8-bit comparisons and no
  // arithmetic. It is deliberately at the pipeline's mouth rather than inside
  // the clipper: the property wanted is "garbage in the display list cannot
  // wedge the geometry", and that is stronger than fixing one stage's reaction
  // to one input.
  function automatic logic nonfinite(input logic [31:0] f);
    nonfinite = (f[30:23] == 8'hFF);
  endfunction

  wire poly_bad = nonfinite(v0x) | nonfinite(v0y) | nonfinite(v0z)
                | nonfinite(v1x) | nonfinite(v1y) | nonfinite(v1z)
                | nonfinite(v2x) | nonfinite(v2y) | nonfinite(v2z)
                | nonfinite(v3x) | nonfinite(v3y) | nonfinite(v3z);

  // R246: the four vertices' view depths, the mode's pick, and the reference's
  // "the whole polygon is behind the eye" cull (check_culling: max_z < 0).
  wire [31:0] zmin_c = fmin(fmin(v0z, v1z), fmin(v2z, v3z));
  wire [31:0] zmax_c = fmax(fmax(v0z, v1z), fmax(v2z, v3z));
  wire [31:0] zsel_c = (poly_zmode == 2'd0) ? zprev
                     : (poly_zmode == 2'd1) ? zmin_c
                     : (poly_zmode == 2'd2) ? zmax_c
                                            : 32'h5011B5EA;   // 1e10
  wire        zc_behind = zmax_c[31] && (zmax_c[30:0] != 31'd0);

  assign poly_ready = (qst == Q_IDLE);
  assign dbg_lum_go = poly_valid && poly_ready;   // R249
  assign w_pj_valid = (qst == Q_ISS) && !skip_here;   // R758: a cached vertex is not sent
  // R758: the vertices issued and not yet answered, in issue order, and the
  // answers to throw away after a timeout gave up on their polygon.
  logic [1:0] wq [4];
  logic [2:0] wq_n;
  logic [2:0] w_drop;
  wire        w_push = (qst == Q_ISS) && !skip_here && w_granted;
  wire        w_take = w_pj_out_valid && (w_drop == 3'd0) && (wq_n != 3'd0);
  assign w_pj_x = hx[qi]; assign w_pj_y = hy[qi]; assign w_pj_z = hz[qi];

  // THE SORT KEY IS THE SMALLEST z, as geo_parse computes min_z over the
  // vertices. These are view-space depths and are positive for anything in
  // front of the eye, and IEEE-754 orders positive floats exactly as the
  // unsigned integers of their bit patterns do -- so this is an integer
  // comparison, not a float unit.
  // R250: THESE ARE FLOATS, AND A NEGATIVE ONE IS NOT A SMALL UNSIGNED NUMBER.
  //
  // The comment these replace said the vertices "are positive for anything in
  // front of the eye, and IEEE-754 orders positive floats exactly as the
  // unsigned integers of their bit patterns do". Both halves are true and the
  // conclusion is not: a vertex BEHIND the eye is negative, its sign bit is
  // set, and as an unsigned integer it is therefore larger than every positive
  // float there is. So fmax returned the most-negative vertex the moment one
  // corner of a polygon crossed behind the camera, R246's max_z < 0 cull then
  // fired on the whole polygon, and the floor vanished while it was still on
  // screen -- reported from the board, which is where it was visible and where
  // the desk's own on-screen quad tests never put a vertex behind the eye.
  //
  // The monotone transform is the standard one: flip everything for a negative,
  // set the top bit for a positive, then compare as unsigned. +0.0 and -0.0 map
  // one apart, which cannot pick a different NUMBER, only which of the two zero
  // bit patterns is returned.
  function automatic logic [31:0] fkey(input logic [31:0] f);
    fkey = f[31] ? ~f : (f | 32'h8000_0000);
  endfunction
  function automatic logic [31:0] fmin(input logic [31:0] a, input logic [31:0] b);
    fmin = (fkey(a) < fkey(b)) ? a : b;
  endfunction
  function automatic logic [31:0] fmax(input logic [31:0] a, input logic [31:0] b);
    fmax = (fkey(a) > fkey(b)) ? a : b;
  endfunction

  // R597: ONE COMPARE DEEP, NOT TWO. The tree above is compare-mux-compare-
  // mux on 32 bits (s321: hz -> hzmax, -2.114 ns at 70 MHz). The six pairwise
  // compares run in parallel instead, ties broken by index so exactly one
  // vertex is the minimum and one the maximum, and the answer is an AND-OR of
  // the one-hot pick. fkey is a bijection, so a tie is two identical bit
  // patterns and the tie rule cannot change the value returned: checked
  // against the tree on 400,000 sets with forced ties, zeros, infinities and
  // negatives, 0 disagree. Six comparators, the same as the tree.
  logic [31:0] mm_k [4];
  logic        mm_le01, mm_le02, mm_le03, mm_le12, mm_le13, mm_le23;   // k_i <= k_j, i < j
  logic [3:0]  mm_lo, mm_hi;
  logic [31:0] mm_min, mm_max;
  // R740: THE SIX COMPARES REGISTERED, THE PICK A CYCLE LATER. fkey, six
  // 32-bit compares, the one-hot terms and the AND-OR were one cycle into
  // hzmin / hzmax (s789 at 80 MHz: hz -> hzmin -1.158). Q_MM now registers
  // the compares and Q_MM2 picks: one cycle more per polygon. hz does not
  // change between them (it is loaded only on taking a polygon).
  logic mm_r01, mm_r02, mm_r03, mm_r12, mm_r13, mm_r23;
  always_ff @(posedge clk) begin
    mm_r01 <= mm_k[0] <= mm_k[1];  mm_r02 <= mm_k[0] <= mm_k[2];
    mm_r03 <= mm_k[0] <= mm_k[3];  mm_r12 <= mm_k[1] <= mm_k[2];
    mm_r13 <= mm_k[1] <= mm_k[3];  mm_r23 <= mm_k[2] <= mm_k[3];
  end
  always_comb begin
    for (int i = 0; i < 4; i++) mm_k[i] = fkey(hz[i]);
    mm_le01 = mm_r01;  mm_le02 = mm_r02;
    mm_le03 = mm_r03;  mm_le12 = mm_r12;
    mm_le13 = mm_r13;  mm_le23 = mm_r23;
    // i comes before j: k_i <= k_j when i < j, k_i < k_j when i > j.
    mm_lo[0] =  mm_le01 &  mm_le02 &  mm_le03;
    mm_lo[1] = ~mm_le01 &  mm_le12 &  mm_le13;
    mm_lo[2] = ~mm_le02 & ~mm_le12 &  mm_le23;
    mm_lo[3] = ~mm_le03 & ~mm_le13 & ~mm_le23;
    mm_hi[0] = ~mm_le01 & ~mm_le02 & ~mm_le03;
    mm_hi[1] =  mm_le01 & ~mm_le12 & ~mm_le13;
    mm_hi[2] =  mm_le02 &  mm_le12 & ~mm_le23;
    mm_hi[3] =  mm_le03 &  mm_le13 &  mm_le23;
    mm_min = '0; mm_max = '0;
    for (int i = 0; i < 4; i++) begin
      mm_min = mm_min | ({32{mm_lo[i]}} & hz[i]);
      mm_max = mm_max | ({32{mm_hi[i]}} & hz[i]);
    end
  end

  // R246: THE SORT KEY IS THE REFERENCE'S 16-BIT z VALUE, NOT THE FLOAT.
  //
  // model2_v.cpp's float_to_zval rounds the mantissa to twelve bits and packs
  // it under a biased exponent, so the reference's sort is COARSE: polygons
  // within one part in 4,096 of each other land in the same bucket and are
  // then ordered by the list, which is the game's own choice. Sorting on the
  // full float instead -- what this core did -- reorders exactly those
  // polygons against each other, and that is a decal or a road marking
  // swapping with the surface it sits on.
  //
  //   exponent = ((f >> 23) & 0xff) - ((z_adjust >> 23) & 0xff)
  //   mantissa = (f & 0x7fffff) + 0x400, carrying into the exponent, >> 11
  //   f < 0            -> 0x0000        (behind the eye sorts furthest away)
  //   exponent < -12   -> 0x0000
  //   exponent < 0     -> (mantissa | 0x1000) >> -exponent
  //   exponent < 15    -> ((exponent + 1) << 12) | mantissa
  //   else             -> 0xffff
  // R420: zval SPLIT ACROSS A CYCLE. As one expression it is a 10-bit
  // subtract, a 24-bit add, a normalise compare-and-shift, a comparison chain
  // and a VARIABLE shift, hanging off p1prev through the zsel_c mux:
  //   m2_geo_engine|p1prev[2][31] -> m2_geometry|hzkey[6]   -0.584 on clk_sys
  //
  // That one is not survivable on the board. hzkey is the z-sort key for every
  // quad, so a wrong value makes the display list meaningless -- seed 11 came
  // up on a blue screen, where a raster_fill path missing by MORE only degraded
  // the texture. The path matters, not just the margin.
  //
  // Stage one does the arithmetic, stage two the selection. clip_in_valid does
  // not fire until all four vertices have issued, so the second cycle is free.
  function automatic logic [22:0] zval_pre(input logic [31:0] f, input logic [7:0] zbias);
    logic signed [9:0]  ex;
    logic        [23:0] ma;
    begin
      ex = $signed({2'b00, f[30:23]}) - $signed({2'b00, zbias});
      ma = {1'b0, f[22:0]} + 24'h400;
      if (ma > 24'h7fffff) begin ex = ex + 10'sd1; ma = {1'b0, ma[22:0]} >> 1; end
      ma = ma >> 11;
      zval_pre = {f[31], ex, ma[11:0]};   // only 12 mantissa bits survive
    end
  endfunction

  function automatic logic [15:0] zval_post(input logic [22:0] p);
    logic               neg;
    logic signed [9:0]  ex;
    logic        [11:0] ma;                  // only the low 12 survive the >>11
    begin
      neg = p[22];
      ex  = $signed(p[21:12]);
      ma  = p[11:0];
      if (neg)                  zval_post = 16'h0000;
      else if (ex < -10'sd12)   zval_post = 16'h0000;
      else if (ex < 10'sd0)     zval_post = 16'({4'd1, ma} >> (-ex));
      else if (ex < 10'sd15)    zval_post = {4'(ex + 10'sd1), ma};
      else                      zval_post = 16'hffff;
    end
  endfunction

  // R270: THE PAIRS ARE 16-BIT INTEGERS AND THE CLIPPER IS FLOAT. MAME reads
  // them straight into a float field -- `object.v[0].pu = *tp++` with tp a
  // u16* -- so the conversion is unsigned, and it is a normalise rather than
  // arithmetic: the top set bit gives the exponent and what follows it is the
  // mantissa.
  function automatic logic [31:0] u2f(input logic [15:0] n);
    logic [3:0] e;
    logic [15:0] m;
    begin
      if (n == 16'd0) u2f = 32'd0;
      else begin
        e = 4'd0;
        for (int b = 15; b >= 0; b--) if (n[b] && e == 4'd0) e = 4'(b);
        m = n << (4'd15 - e);                       // top bit at 15
        u2f = {1'b0, 8'(8'd127 + {4'd0, e}), m[14:0], 8'd0};
      end
    end
  endfunction

  logic [31:0] hu [4], hv [4];
  logic [31:0] ptex;  logic [7:0] plum;
  logic        c_bad;                      // R566: the non-finite test, registered
  logic [1:0]  c_zmode;                    // R578
  // R578: THE z PICK AND "BEHIND THE EYE" FROM THE REGISTERED MIN AND MAX. At 70
  // MHz the four-way float min/max trees still fed c_zsel in Q_IDLE's cycle
  // (s312: p0prev -> c_zsel, -1.73 ns at 70). hzmin/hzmax are already latched
  // with the polygon, so Q_CHK picks from them -- the same values, a cycle on.
  wire  [31:0] c_zsel   = (c_zmode == 2'd0) ? zprev
                        : (c_zmode == 2'd1) ? hzmin
                        : (c_zmode == 2'd2) ? hzmax
                                            : 32'h5011B5EA;   // 1e10
  wire         c_behind = hzmax[31] && (hzmax[30:0] != 31'd0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      qst <= Q_IDLE; qi <= 2'd0; clip_in_valid <= 1'b0; hzmin <= 32'd0; hzmax <= 32'd0;
      for (int k = 0; k < 4; k++) begin hu[k] <= 32'd0; hv[k] <= 32'd0; end
      ptex <= 32'd0; plum <= 8'd0;
      c_bad <= 1'b0; c_zmode <= 2'd0;
      zprev <= 32'h5011B5EA; hzkey <= 16'd0; hzpre <= '0;   // 1e10, as render_frame_start sets it
      dbg_nonfinite <= 16'd0; dbg_behind <= 16'd0; pj_wait <= 10'd0; dbg_pj_lost <= 16'd0;
      wq_n <= 3'd0; w_drop <= 3'd0;                                   // R758
      for (int k = 0; k < 4; k++) wq[k] <= 2'd0;
      cvalid <= 1'b0;
      for (int k = 0; k < 4; k++) begin csx[k] <= 16'sd0; csy[k] <= 16'sd0; csf[k] <= 4'd0; end
      for (int k = 0; k < 4; k++) begin
        hx[k] <= 32'd0; hy[k] <= 32'd0; hz[k] <= 32'd0;
        sx[k] <= 16'sd0; sy[k] <= 16'sd0; soz[k] <= 16'd0; sf[k] <= 4'd0;
      end
    end else begin
      pj_wait <= (qst == Q_WAIT) ? (pj_wait + 10'd1) : 10'd0;
      case (qst)
        // A refused polygon is still ACCEPTED from the engine -- poly_ready is
        // high here -- it simply goes no further. Refusing to accept it would
        // stall the engine instead of the clipper and fix nothing.
        // R566: TAKE THE POLYGON UNCONDITIONALLY, DECIDE THE CULL A CYCLE LATER.
        //
        // The cull -- eight non-finite tests and a four-way float max for
        // "wholly behind the eye" -- used to gate the load of every register
        // below in the same cycle, so the engine's vertex registers reached
        // ~150 load enables through a comparator tree (s297: p0prev -> hzpre
        // +1.842, -> hz/hu/hx/hy/pcol +2.65..+3.03 at 50 MHz; -1.5 at 60).
        // Now the polygon is always latched, the two cull flags and the
        // z-mode's pick are registered beside it, and Q_CHK acts on them. A
        // refused polygon's latched values are simply never used. One cycle a
        // polygon, against a 68-cycle budget.
        //
        // A refused polygon is still ACCEPTED from the engine -- poly_ready is
        // high in Q_IDLE -- it simply goes no further. Refusing to accept it
        // would stall the engine instead of the clipper and fix nothing.
        Q_IDLE: if (poly_valid) begin
          hx[0] <= v0x; hy[0] <= v0y; hz[0] <= v0z;
          hx[1] <= v1x; hy[1] <= v1y; hz[1] <= v1z;
          hx[2] <= v2x; hy[2] <= v2y; hz[2] <= v2z;
          hx[3] <= v3x; hy[3] <= v3y; hz[3] <= v3z;
          // R268 hands them over as {v, u}, v in the high half.
          hu[0] <= u2f(poly_uv0[15:0]); hv[0] <= u2f(poly_uv0[31:16]);
          hu[1] <= u2f(poly_uv1[15:0]); hv[1] <= u2f(poly_uv1[31:16]);
          hu[2] <= u2f(poly_uv2[15:0]); hv[2] <= u2f(poly_uv2[31:16]);
          hu[3] <= u2f(poly_uv3[15:0]); hv[3] <= u2f(poly_uv3[31:16]);
          pcol  <= poly_col;                       // R222
          ptex  <= poly_tex; plum <= dbg_lum;      // R271: the lighting luminance
          c_bad    <= poly_bad;
          c_zmode  <= poly_zmode;          // R578: picked in Q_CHK, from hzmin/hzmax
          qst      <= Q_MM;                // R589
        end

        // R589: the four-way float min and max, from the z values latched a
        // cycle ago rather than from the engine's registers in the latch cycle
        // (s317: p1cur -> hzmax, -0.322 ns at 70 MHz).
        Q_MM:  qst <= Q_MM2;   // R740: the compares are registered on this edge
        Q_MM2: begin
          hzmin <= mm_min;   // R597
          hzmax <= mm_max;
          qst   <= Q_CHK;
        end

        Q_CHK: begin
          // R246: the reference sets raster->polygon_z BEFORE it culls, so a
          // culled polygon still decides what a later "old value" reads.
          zprev <= c_zsel;
          if (c_bad || c_behind) begin      // R578: c_zsel / c_behind are wires on hzmin/hzmax
            if (c_bad) dbg_nonfinite <= dbg_nonfinite + 16'd1;
            else       dbg_behind    <= dbg_behind + 16'd1;
            cvalid <= 1'b0;                        // R217: a refused polygon breaks the chain
            qst    <= Q_IDLE;
          end else begin
            hzpre <= zval_pre(c_zsel, zadj_e);     // R420: arithmetic here
            qi    <= 2'd0;
            qst   <= Q_ISS;
          end
        end

        // ISSUE AND WAIT ARE SEPARATE STATES for the same reason the engine's
        // transform splits them: the projector's out_valid from the PREVIOUS
        // vertex is still standing when this one's in_valid goes up.
        // R420: selection here, a cycle after the arithmetic. hzpre is stable
        // throughout Q_ISS, so recomputing it each cycle is harmless and needs
        // no gating; hzkey is settled long before clip_in_valid.
        Q_ISS: begin
          hzkey <= zval_post(hzpre);
          if (skip_here) begin
          // R217: this vertex was projected by the previous polygon.
          sx[qi] <= csx[hit_i[qi[0]]];
          sy[qi] <= csy[hit_i[qi[0]]];
          sf[qi] <= csf[hit_i[qi[0]]];
          qi <= qi + 2'd1;                       // qi < 2 here, so never the last
          end else if (w_granted) begin
            // R758: on to the next vertex at once; the answers are taken below
            // the case as they come back.
            if (qi == 2'd3) qst <= Q_WAIT;
            else            qi  <= qi + 2'd1;
          end
        end

        // A PROJECTION THAT NEVER RETURNS MUST NOT STOP THE WORLD.
        //
        // The board wedged here once: engine idle, clipper idle, qst stuck in
        // Q_WAIT, m2_geometry.busy high forever, the walk held in W_OBJW. A
        // legitimate projection is tens of cycles; 1023 is far past any honest
        // latency and far short of a frame. On expiry the vertices still owed
        // keep whatever position they had, the pipeline moves on, and (R758)
        // their answers, if they ever come, are counted off and dropped rather
        // than given to the next polygon.
        Q_WAIT: if (pj_timeout) begin
          dbg_pj_lost   <= dbg_pj_lost + 16'd1;
          clip_in_valid <= 1'b1;
          qst           <= Q_OUT;
        end else if (w_take && (wq_n == 3'd1)) begin   // R758: the last answer
          clip_in_valid <= 1'b1;
          qst           <= Q_OUT;
        end

        Q_OUT: if (clip_in_ready) begin
          clip_in_valid <= 1'b0;
          qst <= Q_IDLE;
          // R217: remember this polygon's vertices and their pixels.
          for (int k = 0; k < 4; k++) begin csx[k] <= sx[k]; csy[k] <= sy[k]; csf[k] <= sf[k]; end
          cvalid <= 1'b1;
        end

        default: qst <= Q_IDLE;
      endcase

      // R758: THE ANSWERS, in issue order, whatever state the projector is in.
      if (w_take) begin
        sx[wq[0]]  <= pj_out_sx[15:0];
        sy[wq[0]]  <= pj_out_sy[15:0];
        sf[wq[0]]  <= {pj_out_fy, pj_out_fx};   // R626
        // R334: THE RECIPROCAL, KEPT, as a 16-bit minifloat -- the 8-bit IEEE
        // exponent and the top 8 mantissa bits, within 0.67 texels (R331).
        soz[wq[0]] <= mf16(pj_out_invz);
      end
      if (w_pj_out_valid && (w_drop != 3'd0)) w_drop <= w_drop - 3'd1;
      if ((qst == Q_WAIT) && pj_timeout) begin
        // an answer this cycle is either taken (w_drop 0) or dropped: one fewer owed
        w_drop <= w_drop + wq_n - (w_pj_out_valid ? 3'd1 : 3'd0);
        wq_n   <= 3'd0;
      end else begin
        case ({w_push, w_take})
          2'b10: begin wq[wq_n[1:0]] <= qi; wq_n <= wq_n + 3'd1; end
          2'b01: begin wq[0] <= wq[1]; wq[1] <= wq[2]; wq[2] <= wq[3]; wq_n <= wq_n - 3'd1; end
          2'b11: begin
            wq[0] <= wq[1]; wq[1] <= wq[2]; wq[2] <= wq[3];
            wq[wq_n[1:0] - 2'd1] <= qi;
          end
          default: ;
        endcase
      end
    end
  end

  // m2_geo_clip's in_ready IS its idle flag (assign in_ready = (kst == K_IDLE)),
  // so these three terms cover every stage between object_data and q_*.
  assign busy = eng_busy || (qst != Q_IDLE) || !clip_in_ready;

  assign dbg_eng_state  = eng_dbg_st;   // R719: a port, which Quartus synthesises (u_engine.st read 0)
  assign dbg_qst        = 2'(qst);
  assign dbg_clip_state = 4'(u_clip.kst);

  // R273: THE CLIPPER'S FLOAT, AS THE STORE'S 11.2 TEXELS.
  //
  // The reference's texel coordinate is `pu * (1/z) / 8`; without the
  // perspective divide that is pu/8, and eight times a quarter is a half -- so
  // the stored value is simply pu/2, which is a float-to-integer conversion
  // with the exponent biased by one. Thirteen bits holds 0..8191, and pu is a
  // 16-bit unsigned whose largest useful value is 16,383 (2,047.875 texels).
  logic [31:0] cu [4], cv [4];
  logic [15:0] coz [4];                               // R334, from the clipper
  // R334: an IEEE single to the stored 16-bit minifloat. No rounding: the
  // mantissa is truncated, which is what the error model measured.
  function automatic logic [15:0] mf16(input logic [31:0] f);
    mf16 = {f[30:23], f[22:15]};
  endfunction
  logic [31:0] ctex;
  function automatic logic [12:0] f2uv(input logic [31:0] f);
    logic [7:0]  e;
    logic [23:0] m;
    logic [4:0]  sh;
    begin
      e = f[30:23];
      m = {1'b1, f[22:0]};
      if (f[31] || e < 8'd127)      f2uv = 13'd0;       // negative or under 1.0
      else if (e >= 8'd127 + 8'd13) f2uv = 13'h1fff;    // 8,192 or more: clamp
      else begin
        sh   = 5'(8'd24 - (e - 8'd127));                // >> 23-e, then one more for /2
        f2uv = 13'(m >> sh);
      end
    end
  endfunction
  // R609: THE COORDINATE WRAPS, SO THE POLYGON IS MOVED, NOT CLAMPED.
  //
  // f2uv clamps at 8,191 quarter-texels (2,047.75 texels), and Daytona's
  // polygons go far past that: in MAME, 95% of frames with 3D (7,277 of
  // 7,644) have a polygon with a vertex beyond 2,048 texels, ~11 a frame, up
  // to the full 16 bits (8,191.9 texels). The long repeating surfaces -- the
  // road -- are the ones. Clamping a far vertex bends the u/z plane in
  // proportion to the distance along the polygon: right under the car, wrong
  // ahead, as Ben saw on the board.
  //
  // The reference only ever uses the coordinate modulo the texture:
  // `(u >> 8) & (tex_width - 1)`, and the mirror test reads the next bit up
  // (`u & (tex_width << 8)`). So subtracting the same multiple of TWICE the
  // texture's size from all four vertices changes no texel and no mirror
  // phase. Per axis: each vertex to a 15-bit quarter-texel (pu/2, up to
  // 32,767), the smallest of the four rounded down to 256 << code quarter-
  // texels (2 x (32 << code) texels), subtracted from all four. Only a polygon
  // that itself spans more than 2,048 texels still clamps.
  function automatic logic [14:0] f2uvw(input logic [31:0] f);
    logic [7:0]  e;
    logic [23:0] m;
    begin
      e = f[30:23];
      m = {1'b1, f[22:0]};
      // R643: THE CLAMP WAS ONE BINADE EARLY. The result is f/2 in 15 bits, so
      // every f below 65,536 fits (e <= 127+15 shifts right by 9 or more); the
      // clamp stood at e >= 127+15 and threw away 32,768..65,535 -- half the
      // range R609 made room for. The geometry differential found it: MAME
      // raw v 32,798..32,932 on a close-up textured surface came out 32,767
      // at every vertex, reduced to 511, the texture squashed flat.
      if (f[31] || e < 8'd127)      f2uvw = 15'd0;
      else if (e >= 8'd127 + 8'd16) f2uvw = 15'h7fff;
      else                          f2uvw = 15'(m >> (5'(8'd24 - (e - 8'd127))));
    end
  endfunction
  function automatic logic [14:0] min4w(input logic [14:0] a, b, c, d);
    logic [14:0] p, q;
    begin
      p = (a < b) ? a : b;
      q = (c < d) ? c : d;
      min4w = (p < q) ? p : q;
    end
  endfunction
  // R614: the conversion is its own stage -- s368 still had clipper -> ru/rv
  // at -0.796 with conversion, minimum, subtract and clamp in one cycle.
  logic [14:0] wu [4], wv [4];
  always_ff @(posedge clk) for (int k = 0; k < 4; k++) begin wu[k] <= f2uvw(cu[k]); wv[k] <= f2uvw(cv[k]); end
  wire  [15:0] uper = (16'd256 << ctex[3:1]) - 16'd1;   // 2 x width, quarter-texels, less one
  wire  [15:0] vper = (16'd256 << ctex[6:4]) - 16'd1;
  // R739: the minimum in two rounds a stage apart -- the pairs registered
  // (pu/qu, pv/qv), then the pair of pairs and the mask (s785 at 80 MHz:
  // wv -> voff_r -0.695, wu -> uoff_r -0.272).
  logic [14:0] pu_r, qu_r, pv_r, qv_r;
  always_ff @(posedge clk) begin
    pu_r <= (wu[0] < wu[1]) ? wu[0] : wu[1];  qu_r <= (wu[2] < wu[3]) ? wu[2] : wu[3];
    pv_r <= (wv[0] < wv[1]) ? wv[0] : wv[1];  qv_r <= (wv[2] < wv[3]) ? wv[2] : wv[3];
  end
  wire  [14:0] uoff = ((pu_r < qu_r) ? pu_r : qu_r) & ~uper[14:0];
  wire  [14:0] voff = ((pv_r < qv_r) ? pv_r : qv_r) & ~vper[14:0];
  function automatic logic [12:0] sat13(input logic [14:0] x);
    sat13 = (x > 15'd8191) ? 13'h1fff : x[12:0];
  endfunction
  // R613: REGISTERED. The conversion, the four-way minimum, the subtract and
  // the saturate were one cycle from the clipper into the store's M10K
  // (s358: qv -> uvt, -1.919 ns at 70 MHz). The clipper HOLDS a quad until it
  // is taken, so the reduced u/v are registered every cycle and the quad is
  // presented one cycle after it first appears -- c_seen says the registers
  // now hold THIS quad's values. Everything else the store takes (x, y, z,
  // 1/z, texture, colour) comes straight off the held clipper outputs.
  logic c_valid, c_ready, c_seen;
  logic [2:0] c_age;   // R614: cycles this quad has been held, to 2; R718: to 3; R739: to 4
  logic [12:0] ru [4], rv [4];
  // R718: AND THE MINIMUM IS ITS OWN STAGE TOO. At 75 and 80 MHz the four-way
  // minimum, the mask, the subtract and the saturate missed (s737: wu -> ru
  // -0.330 at 75; s735: wv -> rv -0.591 at 80). uoff/voff are registered
  // beside a one-cycle copy of wu/wv, and the subtract runs from both.
  logic [14:0] uoff_r, voff_r;
  logic [14:0] wu_d [4], wv_d [4];
  logic [14:0] wu_dd [4], wv_dd [4];   // R739: a stage more, beside the minimum's
  always_ff @(posedge clk) begin
    uoff_r <= uoff;
    voff_r <= voff;
    for (int k = 0; k < 4; k++) begin
      wu_d[k] <= wu[k];     wv_d[k] <= wv[k];
      wu_dd[k] <= wu_d[k];  wv_dd[k] <= wv_d[k];
    end
  end
  always_ff @(posedge clk) for (int k = 0; k < 4; k++) begin
    ru[k] <= sat13(wu_dd[k] - uoff_r);
    rv[k] <= sat13(wv_dd[k] - voff_r);
  end
  // R614: two register stages (wu/wv, then ru/rv); R718: three (the minimum),
  // so the quad is shown once it has been held three cycles. R739: four.
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n)                  c_age <= 3'd0;
    else if (!c_valid || c_ready) c_age <= 3'd0;   // gone, or taken this cycle
    else if (c_age != 3'd4)       c_age <= c_age + 3'd1;
  assign c_seen = (c_age == 3'd4);   // R739: four stages now
  assign q_valid = c_valid && c_seen;
  assign c_ready = q_ready && c_seen;
  assign q_u0 = ru[0]; assign q_v0 = rv[0];
  assign q_u1 = ru[1]; assign q_v1 = rv[1];
  assign q_u2 = ru[2]; assign q_v2 = rv[2];
  assign q_u3 = ru[3]; assign q_v3 = rv[3];
  assign q_tex = ctex[23:0];
  assign q_tlinv = (ctex[31:24] == 8'd1);   // R784
  assign q_oz0 = coz[0]; assign q_oz1 = coz[1];      // R334
  assign q_oz2 = coz[2]; assign q_oz3 = coz[3];

  // ------------------------------------------------------------- the clipper
  m2_geo_clip u_clip (
    .clk(clk), .rst_n(rst_n),
    .a_left(a_left), .a_right(a_right), .a_bottom(a_bottom), .a_top(a_top),
    .in_valid(clip_in_valid), .in_ready(clip_in_ready),
    .in_x0(hx[0]), .in_y0(hy[0]), .in_z0(hz[0]),
    .in_x1(hx[1]), .in_y1(hy[1]), .in_z1(hz[1]),
    .in_x2(hx[2]), .in_y2(hy[2]), .in_z2(hz[2]),
    .in_x3(hx[3]), .in_y3(hy[3]), .in_z3(hz[3]),
    .in_oz0(soz[0]), .in_oz1(soz[1]), .in_oz2(soz[2]), .in_oz3(soz[3]),
    .out_oz0(coz[0]), .out_oz1(coz[1]), .out_oz2(coz[2]), .out_oz3(coz[3]),
    .in_sx0(sx[0]), .in_sy0(sy[0]), .in_sx1(sx[1]), .in_sy1(sy[1]),
    .in_sx2(sx[2]), .in_sy2(sy[2]), .in_sx3(sx[3]), .in_sy3(sy[3]),
    .in_frac({sf[3], sf[2], sf[1], sf[0]}), .out_frac(q_frac),   // R626
    .pj_out_fx(pj_out_fx), .pj_out_fy(pj_out_fy),
    .in_u0(hu[0]), .in_v0(hv[0]), .in_u1(hu[1]), .in_v1(hv[1]),
    .in_u2(hu[2]), .in_v2(hv[2]), .in_u3(hu[3]), .in_v3(hv[3]),
    .in_col(pcol), .in_z({16'd0, hzkey}), .in_moire(1'b0),   // R246: the reference's 16-bit z value
    .in_tex(ptex), .in_lum(plum),                            // R271
    .mul_req(mul_req[2]), .mul_a(mul_a[2]), .mul_b(mul_b[2]),
    .mul_gnt(mul_gnt[2]), .mul_rsp(mul_rsp[2]), .mul_res(mul_res),
    .add_req(add_req[2]), .add_a(add_a[2]), .add_b(add_b[2]), .add_sub(add_sub[2]),
    .add_gnt(add_gnt[2]), .add_rsp(add_rsp[2]), .add_res(add_res),
    .div_req(div_req[2]), .div_a(div_a[2]), .div_b(div_b[2]),
    .div_gnt(div_gnt[2]), .div_rsp(div_rsp[2]), .div_res(div_res),
    .pj_valid(k_pj_valid), .pj_ready(k_granted),
    .pj_x(k_pj_x), .pj_y(k_pj_y), .pj_z(k_pj_z),
    .pj_out_valid(k_pj_out_valid), .pj_out_sx(pj_out_sx), .pj_out_sy(pj_out_sy),
    .pj_out_invz(pj_out_invz),                       // R334
    .out_valid(c_valid), .out_ready(c_ready),   // R613: presented a cycle late
    .out_sx0(q_x0), .out_sy0(q_y0), .out_sx1(q_x1), .out_sy1(q_y1),
    .out_sx2(q_x2), .out_sy2(q_y2), .out_sx3(q_x3), .out_sy3(q_y3),
    .out_u0(cu[0]), .out_v0(cv[0]), .out_u1(cu[1]), .out_v1(cv[1]),
    .out_u2(cu[2]), .out_v2(cv[2]), .out_u3(cu[3]), .out_v3(cv[3]),
    .out_tex(ctex), .out_lum(q_lum),
    .out_col(q_col), .out_z(q_z), .out_moire(),
    .dbg_in(dbg_clip_in), .dbg_out(dbg_clip_out), .dbg_dropped(dbg_clip_dropped)
  );

endmodule
