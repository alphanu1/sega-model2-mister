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
// THE POLYGON SEQUENCER: an object_data command becomes a stream of quads.
//
// This is the block Model 1 could not supply. Its arithmetic transfers -- see
// study R170 and THIRD_PARTY.md, m2_geo_xform and the rest are its stages
// unmodified -- but the STREAM GRAMMAR is Model 2's own, so this is written
// here against model2_v.cpp's geo_parse_np_ns and model2_3d_push.
//
// The grammar is transcribed in study R171 and the two things that make it
// awkward are both here:
//
//   1. THE LINK IS NOT A STRIP. Which pair of vertices the next polygon
//      inherits is a field in the attribute word, (attr >> 8) & 3, with three
//      different carries. A sequencer written for a plain triangle strip is
//      correct for types 0 and 2 and silently wrong for 1 and 3, and the
//      failure is geometry that looks plausible everywhere and is right
//      nowhere.
//
//   2. A TRIANGLE STILL CONSUMES THE POINT IT DOES NOT USE. `input += 3` in
//      the reference. Skipping the read instead of consuming it desynchronises
//      the stream, which reads as a corrupt object rather than as a bug here --
//      the same failure mode the display-list walk had twice.
//
// FLAT FIRST, AND DELIBERATELY. The normal is read and stepped over but not
// transformed: it exists only to compute luminance and the texture LOD, and the
// ported rasterizer takes a single 24-bit colour with no texture input at all.
// So flat is the natural first target rather than a simplification that has to
// be undone -- lighting and texture add stages beside this one without changing
// the stream logic. Vertices leave here TRANSFORMED but still floating point;
// the screen conversion is fp_to_int's job downstream.
//
// THE MEMORY PORT IS SHARED WITH THE WALK, AND THAT IS SAFE HERE FOR A REASON
// WORTH STATING. m2_geo's walk stops while an object is fetched -- one state
// machine, strictly sequential, never two requests in flight. That is NOT the
// arrangement that cost this project four days (R167): there the coprocessor
// and the walker were INDEPENDENT owners of one port and their transactions
// overlapped. Sequential sharing by a single requester is fine; concurrent
// sharing by two is not. Do not "optimise" this into overlap.

`timescale 1ns/1ps

module m2_geo_engine (
  input  logic        clk,
  input  logic        rst_n,

  // ---- from the walker, when an object_data's four operands are in
  input  logic        start,
  input  logic [31:0] oba,            // object address, selects ROM or RAM
  input  logic [31:0] obc,            // object count; 0 means run to the end
  output logic        busy,

  // ---- the matrix, passed through to the transform stage
  input  logic        mat_we,
  input  logic [3:0]  mat_idx,
  input  logic [31:0] mat_data,

  // ---- the vertex stream. One dword per acknowledge, address in dwords.
  output logic        mem_req,
  output logic [23:0] mem_addr,
  input  logic [31:0] mem_data,
  input  logic        mem_ack,

  // ---- the projection. Model 2 has NO perspective divide: apply_focus is
  //      x *= focus.x, y *= focus.y and the result IS the screen coordinate,
  //      as a float. Study R172, and it is why m2_geo_project -- Model 1's
  //      divide-by-z -- is not in this pipeline.
  input  logic [31:0] foc_x, foc_y,

  // ---- a SECOND pool client, for those two multiplies. The pool exists to be
  //      shared (m2_fp_pool); muxing them onto the transform's port here would
  //      rebuild a private arbiter next to a general one.
  output logic        fmul_req,
  output logic [31:0] fmul_a, fmul_b,
  input  logic        fmul_gnt, fmul_rsp,
  input  logic [31:0] fmul_res,

  // ---- the shared arithmetic, forwarded to m2_geo_xform
  output logic        mul_req,
  output logic [31:0] mul_a, mul_b,
  input  logic        mul_gnt, mul_rsp,
  input  logic [31:0] mul_res,
  output logic        add_req,
  output logic [31:0] add_a, add_b,
  output logic        add_sub,
  input  logic        add_gnt, add_rsp,
  input  logic [31:0] add_res,

  // ---- one polygon out, four vertices, still floating point
  output logic        poly_valid,
  input  logic        poly_ready,
  output logic [31:0] v0x, v0y, v0z,
  output logic [31:0] v1x, v1y, v1z,
  output logic [31:0] v2x, v2y, v2z,
  output logic [31:0] v3x, v3y, v3z,
  output logic [31:0] poly_attr,

  output logic [15:0] dbg_polys,      // emitted this object
  output logic [15:0] dbg_objects     // objects completed
);

  // ---------------------------------------------------------------- transform
  logic        xf_in_valid, xf_in_ready, xf_out_valid;
  logic [31:0] xf_in_x, xf_in_y, xf_in_z;
  logic [31:0] xf_out_x, xf_out_y, xf_out_z;

  m2_geo_xform u_xform (
    .clk(clk), .rst_n(rst_n),
    .mat_we(mat_we), .mat_idx(mat_idx), .mat_data(mat_data),
    .in_valid(xf_in_valid), .in_ready(xf_in_ready),
    .in_x(xf_in_x), .in_y(xf_in_y), .in_z(xf_in_z),
    .in_translate(1'b1),                       // points; normals are not transformed here
    .mul_req(mul_req), .mul_a(mul_a), .mul_b(mul_b),
    .mul_gnt(mul_gnt), .mul_rsp(mul_rsp), .mul_res(mul_res),
    .add_req(add_req), .add_a(add_a), .add_b(add_b), .add_sub(add_sub),
    .add_gnt(add_gnt), .add_rsp(add_rsp), .add_res(add_res),
    .out_valid(xf_out_valid), .out_x(xf_out_x), .out_y(xf_out_y), .out_z(xf_out_z)
  );

  // ------------------------------------------------------------ the vertices
  //
  // Named for the reference's command_buffer slots so the mapping is checkable
  // against study R171 rather than remembered:
  //
  //   p0prev = buffer[2..4]   P0(n-1)      p1prev = buffer[5..7]   P1(n-1)
  //   p0cur  = buffer[11..13] P0(n)        p1cur  = buffer[14..16] P1(n)
  //
  // and process_polygon maps v[0]=P1(n-1), v[1]=P0(n-1), v[2]=P0(n), v[3]=P1(n)
  // -- v[0] and v[1] are SWAPPED relative to buffer order.
  logic [31:0] p0prev [3], p1prev [3], p0cur [3], p1cur [3];
  logic [31:0] attr;
  logic [23:0] ptr;
  logic [31:0] remain;

  typedef enum logic [3:0] {
    E_IDLE, E_RD, E_XF, E_XFW, E_FOC, E_FOCW, E_STORE, E_ATTR, E_NORM, E_SKIP,
    E_EMIT, E_LINK, E_DONE
  } estate_t;
  estate_t st, ret;

  logic [1:0] widx;                 // which of x,y,z is being read
  logic [31:0] xyz [3];
  logic [1:0] dst;                  // 0=p0prev 1=p1prev 2=p0cur 3=p1cur
  logic [1:0] skipn;
  logic [31:0] fx, fy, fz;   // the point, between transform and focus
  logic        fsel;         // 0 = scaling x, 1 = scaling y

  assign mem_addr = ptr;
  assign mem_req  = (st == E_RD) || (st == E_ATTR) || (st == E_NORM) || (st == E_SKIP);

  assign v0x = p1prev[0]; assign v0y = p1prev[1]; assign v0z = p1prev[2];
  assign v1x = p0prev[0]; assign v1y = p0prev[1]; assign v1z = p0prev[2];
  assign v2x = p0cur[0];  assign v2y = p0cur[1];  assign v2z = p0cur[2];
  assign v3x = p1cur[0];  assign v3y = p1cur[1];  assign v3z = p1cur[2];
  assign poly_attr = attr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= E_IDLE; ret <= E_IDLE; busy <= 1'b0; poly_valid <= 1'b0;
      ptr <= 24'd0; remain <= 32'd0; widx <= 2'd0; dst <= 2'd0; skipn <= 2'd0;
      attr <= 32'd0; xf_in_valid <= 1'b0;
      fmul_req <= 1'b0; fmul_a <= 32'd0; fmul_b <= 32'd0;
      fx <= 32'd0; fy <= 32'd0; fz <= 32'd0; fsel <= 1'b0;
      dbg_polys <= 16'd0; dbg_objects <= 16'd0;
      for (int k = 0; k < 3; k++) begin
        p0prev[k] <= 32'd0; p1prev[k] <= 32'd0;
        p0cur[k]  <= 32'd0; p1cur[k]  <= 32'd0; xyz[k] <= 32'd0;
      end
    end else begin
      xf_in_valid <= 1'b0;

      case (st)
        E_IDLE: if (start) begin
          // oba's low bits are the offset; which memory it selects is decoded
          // by the top level, which owns the bases.
          ptr    <= oba[23:0];
          // "if count == 0 then rolls over to max size" -- Virtual On and
          // Gunblade NY, per the reference. 0xfffff, not zero.
          remain <= (obc == 32'd0) ? 32'h000fffff : obc;
          dbg_polys <= 16'd0;
          busy   <= 1'b1;
          widx   <= 2'd0; dst <= 2'd0;
          st     <= E_RD; ret <= E_RD;
        end

        // ---- read three words into xyz, then hand them to the transform
        E_RD: if (mem_ack) begin
          xyz[widx] <= mem_data;
          ptr <= ptr + 24'd1;
          if (widx == 2'd2) begin widx <= 2'd0; st <= E_XF; end
          else widx <= widx + 2'd1;
        end

        // ISSUE AND WAIT ARE SEPARATE STATES, AND THAT IS NOT STYLE.
        //
        // Checking out_valid in the same state that raises in_valid latches the
        // result still standing from the PREVIOUS point -- the transform is a
        // pipelined stage and its output is valid before this one's input has
        // even been accepted. The bench caught it as every vertex being the
        // previous vertex's value, an exact one-place shift through all three
        // polygons: v2 read 200 where 400 was due, v3 read 400 where 500 was.
        E_XF: begin
          xf_in_x <= xyz[0]; xf_in_y <= xyz[1]; xf_in_z <= xyz[2];
          if (xf_in_ready) begin
            xf_in_valid <= 1'b1;
            st <= E_XFW;
          end
        end

        // The transform's result goes to the focus stage, not to a slot: a
        // vertex is not a screen coordinate until focus has been applied.
        E_XFW: if (xf_out_valid) begin
          fx <= xf_out_x; fy <= xf_out_y; fz <= xf_out_z;
          fsel <= 1'b0;
          st <= E_FOC;
        end

        // x *= focus.x, then y *= focus.y. z is untouched -- apply_focus does
        // not scale it, and the sort key downstream wants camera-space z.
        E_FOC: begin
          fmul_req <= 1'b1;
          fmul_a   <= fsel ? fy : fx;
          fmul_b   <= fsel ? foc_y : foc_x;
          if (fmul_gnt) begin fmul_req <= 1'b0; st <= E_FOCW; end
        end

        E_FOCW: if (fmul_rsp) begin
          if (!fsel) begin fx <= fmul_res; fsel <= 1'b1; st <= E_FOC; end
          else       begin fy <= fmul_res; st <= E_STORE; end
        end

        E_STORE: begin
          case (dst)
            2'd0: begin p0prev[0] <= fx; p0prev[1] <= fy; p0prev[2] <= fz;
                        dst <= 2'd1; widx <= 2'd0; st <= E_RD; end
            2'd1: begin p1prev[0] <= fx; p1prev[1] <= fy; p1prev[2] <= fz;
                        st <= E_ATTR; end
            2'd2: begin p0cur[0] <= fx; p0cur[1] <= fy; p0cur[2] <= fz;
                        if (attr[0]) begin dst <= 2'd3; widx <= 2'd0; st <= E_RD; end
                        else begin
                          // TRIANGLE: rope P1(n) = P0(n), and still CONSUME the
                          // three words of the point we do not use.
                          p1cur[0] <= fx; p1cur[1] <= fy; p1cur[2] <= fz;
                          skipn <= 2'd3; st <= E_SKIP;
                        end end
            default: begin p1cur[0] <= fx; p1cur[1] <= fy; p1cur[2] <= fz;
                           st <= E_EMIT; end
          endcase
        end

        // ---- the attribute word terminates the object when (attr & 3) == 0
        E_ATTR: if (mem_ack) begin
          attr <= mem_data;
          ptr  <= ptr + 24'd1;
          if ((mem_data[1:0] == 2'd0) || (remain == 32'd0)) st <= E_DONE;
          else begin skipn <= 2'd3; st <= E_NORM; end
        end

        // ---- the normal: read, not transformed. Flat shading needs no
        //      luminance, but the stream position depends on these words.
        E_NORM: if (mem_ack) begin
          ptr <= ptr + 24'd1;
          if (skipn == 2'd1) begin widx <= 2'd0; dst <= 2'd2; st <= E_RD; end
          else skipn <= skipn - 2'd1;
        end

        // ---- the unused triangle point, consumed
        E_SKIP: if (mem_ack) begin
          ptr <= ptr + 24'd1;
          if (skipn == 2'd1) st <= E_EMIT;
          else skipn <= skipn - 2'd1;
        end

        E_EMIT: begin
          poly_valid <= 1'b1;
          if (poly_valid && poly_ready) begin
            poly_valid <= 1'b0;
            dbg_polys  <= dbg_polys + 16'd1;
            remain     <= remain - 32'd1;
            st         <= E_LINK;
          end
        end

        // ---- the carry, chosen by (attr >> 8) & 3. Study R171.
        E_LINK: begin
          case (attr[9:8])
            2'd1: begin                     // reuse P0(n-1) and P0(n)
              p1prev[0] <= p0cur[0]; p1prev[1] <= p0cur[1]; p1prev[2] <= p0cur[2];
            end
            2'd3: begin                     // reuse P1(n-1) and P1(n)
              p0prev[0] <= p1cur[0]; p0prev[1] <= p1cur[1]; p0prev[2] <= p1cur[2];
            end
            default: begin                  // 0 and 2: reuse P0(n) and P1(n)
              p0prev[0] <= p0cur[0]; p0prev[1] <= p0cur[1]; p0prev[2] <= p0cur[2];
              p1prev[0] <= p1cur[0]; p1prev[1] <= p1cur[1]; p1prev[2] <= p1cur[2];
            end
          endcase
          st <= E_ATTR;
        end

        E_DONE: begin
          busy <= 1'b0;
          dbg_objects <= dbg_objects + 16'd1;
          st <= E_IDLE;
        end

        default: st <= E_IDLE;
      endcase
    end
  end

endmodule
