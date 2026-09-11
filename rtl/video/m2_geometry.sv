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
  input  logic [23:0] flat_col,

  // ---- screen quads out
  output logic        q_valid,
  input  logic        q_ready,
  output logic signed [15:0] q_x0, q_y0, q_x1, q_y1,
  output logic signed [15:0] q_x2, q_y2, q_x3, q_y3,
  output logic [23:0] q_col,
  output logic [31:0] q_z,

  output logic [15:0] dbg_polys, dbg_objects, dbg_capped,
  output logic [15:0] dbg_culled,          // R219
  output logic [15:0] dbg_clip_in, dbg_clip_out, dbg_clip_dropped,
  output logic [15:0] dbg_nonfinite,   // polygons refused before the arithmetic
  output logic [15:0] dbg_pj_lost,     // projections abandoned on timeout
  // WHERE THE PIPELINE IS SITTING. The board wedges with the walk in W_OBJW,
  // which says only "the engine never finished". These say which stage.
  // Guessing at it has cost two wrong hypotheses already -- a NaN (refused
  // correctly, nonfinite counts it) and a z of zero (drains fine, tested).
  output logic  [3:0] dbg_eng_state,
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

  m2_geo_engine u_engine (
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
    .dbg_culled(dbg_culled)
  );
  // add slot 1 is the engine's face test (R219), below.
  assign add_sub[1] = 1'b0;
  assign div_req[0] = 1'b0; assign div_a[0] = 32'd0; assign div_b[0] = 32'd0;
  assign div_req[1] = 1'b0; assign div_a[1] = 32'd0; assign div_b[1] = 32'd0;

  // ------------------------------------- the shared projector and its owner
  logic        pj_ready, pj_out_valid, pj_behind;
  logic [31:0] pj_out_z;
  logic signed [31:0] pj_out_sx, pj_out_sy;

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
  wire pj_valid   = (w_pj_valid || k_pj_valid) && !pj_busy;
  wire [31:0] pj_x = k_pj_valid ? k_pj_x : w_pj_x;
  wire [31:0] pj_y = k_pj_valid ? k_pj_y : w_pj_y;
  wire [31:0] pj_z = k_pj_valid ? k_pj_z : w_pj_z;
  wire w_granted  = pj_ready && w_pj_valid && !k_pj_valid && !pj_busy;
  wire k_granted  = pj_ready && k_pj_valid && !pj_busy;

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
  logic pj_owner;                          // 0 = quad projector, 1 = clipper
  logic pj_busy;                           // a projection is in flight
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pj_owner <= 1'b0; pj_busy <= 1'b0;
    end else begin
      if (pj_valid && pj_ready && !pj_busy) begin
        pj_owner <= k_pj_valid;
        pj_busy  <= 1'b1;
      end
      if (pj_out_valid) pj_busy <= 1'b0;
    end
  end
  wire w_pj_out_valid = pj_out_valid && !pj_owner;
  wire k_pj_out_valid = pj_out_valid &&  pj_owner;

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
    .out_z(pj_out_z), .out_behind(pj_behind)
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
  typedef enum logic [1:0] { Q_IDLE, Q_ISS, Q_WAIT, Q_OUT } qst_t;
  qst_t qst;
  logic [1:0]  qi;
  logic [31:0] hx [4], hy [4], hz [4];
  logic signed [15:0] sx [4], sy [4];
  logic        clip_in_valid;
  logic        clip_in_ready;
  logic [31:0] hzmin;
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
    hit[0] = cvalid && poly_chain_ok;
    hit[1] = cvalid && poly_chain_ok;
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

  assign poly_ready = (qst == Q_IDLE);
  assign w_pj_valid = (qst == Q_ISS);
  assign w_pj_x = hx[qi]; assign w_pj_y = hy[qi]; assign w_pj_z = hz[qi];

  // THE SORT KEY IS THE SMALLEST z, as geo_parse computes min_z over the
  // vertices. These are view-space depths and are positive for anything in
  // front of the eye, and IEEE-754 orders positive floats exactly as the
  // unsigned integers of their bit patterns do -- so this is an integer
  // comparison, not a float unit.
  function automatic logic [31:0] fmin(input logic [31:0] a, input logic [31:0] b);
    fmin = (a < b) ? a : b;
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      qst <= Q_IDLE; qi <= 2'd0; clip_in_valid <= 1'b0; hzmin <= 32'd0;
      dbg_nonfinite <= 16'd0; pj_wait <= 10'd0; dbg_pj_lost <= 16'd0;
      cvalid <= 1'b0;
      for (int k = 0; k < 4; k++) begin csx[k] <= 16'sd0; csy[k] <= 16'sd0; end
      for (int k = 0; k < 4; k++) begin
        hx[k] <= 32'd0; hy[k] <= 32'd0; hz[k] <= 32'd0;
        sx[k] <= 16'sd0; sy[k] <= 16'sd0;
      end
    end else begin
      pj_wait <= (qst == Q_WAIT) ? (pj_wait + 10'd1) : 10'd0;
      case (qst)
        // A refused polygon is still ACCEPTED from the engine -- poly_ready is
        // high here -- it simply goes no further. Refusing to accept it would
        // stall the engine instead of the clipper and fix nothing.
        Q_IDLE: if (poly_valid && poly_bad) begin
          dbg_nonfinite <= dbg_nonfinite + 16'd1;
          cvalid <= 1'b0;                        // R217: a refused polygon breaks the chain
        end else if (poly_valid) begin
          hx[0] <= v0x; hy[0] <= v0y; hz[0] <= v0z;
          hx[1] <= v1x; hy[1] <= v1y; hz[1] <= v1z;
          hx[2] <= v2x; hy[2] <= v2y; hz[2] <= v2z;
          hx[3] <= v3x; hy[3] <= v3y; hz[3] <= v3z;
          hzmin <= fmin(fmin(v0z, v1z), fmin(v2z, v3z));
          qi    <= 2'd0;
          qst   <= Q_ISS;
        end

        // ISSUE AND WAIT ARE SEPARATE STATES for the same reason the engine's
        // transform splits them: the projector's out_valid from the PREVIOUS
        // vertex is still standing when this one's in_valid goes up.
        Q_ISS: if (skip_here) begin
          // R217: this vertex was projected by the previous polygon.
          sx[qi] <= csx[hit_i[qi[0]]];
          sy[qi] <= csy[hit_i[qi[0]]];
          qi <= qi + 2'd1;                       // qi < 2 here, so never the last
        end else if (w_granted) qst <= Q_WAIT;

        // A PROJECTION THAT NEVER RETURNS MUST NOT STOP THE WORLD.
        //
        // The board wedges exactly here: engine idle, clipper idle, qst stuck
        // in Q_WAIT, and m2_geometry.busy therefore high forever, which holds
        // the display-list walk in W_OBJW and stops all 3D for the rest of the
        // session. One vertex that the projector never answers costs every
        // frame after it.
        //
        // m2_geo_project's reciprocal is 29 cycles and the pool can make it
        // wait for a grant, so a legitimate projection is tens of cycles, not
        // hundreds. 1023 is far past any honest latency and far short of a
        // frame. On expiry the vertex keeps whatever screen position it already
        // had and the pipeline moves on, counted rather than silent -- the same
        // principle as the non-finite gate, which is that bad data degrades the
        // picture and never stalls the machine.
        Q_WAIT: if (pj_timeout) begin
          dbg_pj_lost <= dbg_pj_lost + 16'd1;
          if (qi == 2'd3) begin clip_in_valid <= 1'b1; qst <= Q_OUT; end
          else begin qi <= qi + 2'd1; qst <= Q_ISS; end
        end else if (w_pj_out_valid) begin
          sx[qi] <= pj_out_sx[15:0];
          sy[qi] <= pj_out_sy[15:0];
          if (qi == 2'd3) begin
            clip_in_valid <= 1'b1;
            qst <= Q_OUT;
          end else begin
            qi  <= qi + 2'd1;
            qst <= Q_ISS;
          end
        end

        Q_OUT: if (clip_in_ready) begin
          clip_in_valid <= 1'b0;
          qst <= Q_IDLE;
          // R217: remember this polygon's vertices and their pixels.
          for (int k = 0; k < 4; k++) begin csx[k] <= sx[k]; csy[k] <= sy[k]; end
          cvalid <= 1'b1;
        end

        default: qst <= Q_IDLE;
      endcase
    end
  end

  // m2_geo_clip's in_ready IS its idle flag (assign in_ready = (kst == K_IDLE)),
  // so these three terms cover every stage between object_data and q_*.
  assign busy = eng_busy || (qst != Q_IDLE) || !clip_in_ready;

  assign dbg_eng_state  = 4'(u_engine.st);
  assign dbg_qst        = 2'(qst);
  assign dbg_clip_state = 4'(u_clip.kst);

  // ------------------------------------------------------------- the clipper
  m2_geo_clip u_clip (
    .clk(clk), .rst_n(rst_n),
    .a_left(a_left), .a_right(a_right), .a_bottom(a_bottom), .a_top(a_top),
    .in_valid(clip_in_valid), .in_ready(clip_in_ready),
    .in_x0(hx[0]), .in_y0(hy[0]), .in_z0(hz[0]),
    .in_x1(hx[1]), .in_y1(hy[1]), .in_z1(hz[1]),
    .in_x2(hx[2]), .in_y2(hy[2]), .in_z2(hz[2]),
    .in_x3(hx[3]), .in_y3(hy[3]), .in_z3(hz[3]),
    .in_sx0(sx[0]), .in_sy0(sy[0]), .in_sx1(sx[1]), .in_sy1(sy[1]),
    .in_sx2(sx[2]), .in_sy2(sy[2]), .in_sx3(sx[3]), .in_sy3(sy[3]),
    .in_col(flat_col), .in_z(hzmin), .in_moire(1'b0),
    .mul_req(mul_req[2]), .mul_a(mul_a[2]), .mul_b(mul_b[2]),
    .mul_gnt(mul_gnt[2]), .mul_rsp(mul_rsp[2]), .mul_res(mul_res),
    .add_req(add_req[2]), .add_a(add_a[2]), .add_b(add_b[2]), .add_sub(add_sub[2]),
    .add_gnt(add_gnt[2]), .add_rsp(add_rsp[2]), .add_res(add_res),
    .div_req(div_req[2]), .div_a(div_a[2]), .div_b(div_b[2]),
    .div_gnt(div_gnt[2]), .div_rsp(div_rsp[2]), .div_res(div_res),
    .pj_valid(k_pj_valid), .pj_ready(k_granted),
    .pj_x(k_pj_x), .pj_y(k_pj_y), .pj_z(k_pj_z),
    .pj_out_valid(k_pj_out_valid), .pj_out_sx(pj_out_sx), .pj_out_sy(pj_out_sy),
    .out_valid(q_valid), .out_ready(q_ready),
    .out_sx0(q_x0), .out_sy0(q_y0), .out_sx1(q_x1), .out_sy1(q_y1),
    .out_sx2(q_x2), .out_sy2(q_y2), .out_sx3(q_x3), .out_sy3(q_y3),
    .out_col(q_col), .out_z(q_z), .out_moire(),
    .dbg_in(dbg_clip_in), .dbg_out(dbg_clip_out), .dbg_dropped(dbg_clip_dropped)
  );

endmodule
