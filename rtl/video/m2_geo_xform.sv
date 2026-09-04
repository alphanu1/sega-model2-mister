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
// THE GEOMETRY TRANSFORM: one point through the current matrix, then focus.
//
// model2_v.cpp, transform_point() and apply_focus(), verbatim:
//
//   tx = (x * m[0]) + (y * m[3]) + (z * m[6]) + m[9]
//   ty = (x * m[1]) + (y * m[4]) + (z * m[7]) + m[10]
//   tz = (x * m[2]) + (y * m[5]) + (z * m[8]) + m[11]
//   x *= focus.x;  y *= focus.y
//
// transform_vector() is the same without the m[9..11] translate, which is what
// `vec_only` selects -- normals are directions and must not be translated.
//
// ONE MULTIPLIER AND ONE ADDER, SEQUENCED, AND THAT IS DELIBERATE. Eleven
// multiplies and nine adds per point could be a wide parallel datapath, but the
// area budget has the renderer and the i960 sharing what is left (milestones,
// "the fit question reduces to one number") and M10K is already at 92%. A
// sequencer costs two FP units and a handful of registers; the parallel version
// costs eleven and nine. Latency is hidden behind the walk, which is waiting on
// SDRAM for its vertex stream anyway.
//
// THE ORDER OF OPERATIONS IS NOT AN IMPLEMENTATION DETAIL. Float add is not
// associative, so `(a+b)+c` and `a+(b+c)` differ in the last bit, and the
// rasterizer's screen coordinates are these values shifted right by 8. The
// accumulation below is strictly left to right, matching the C, because the
// only oracle this block has is a framebuffer comparison and a one-bit
// difference in a vertex is a pixel in the wrong place with no error anywhere.
//
// fp_mul and fp_add are the TGP's own units, already verified in volume
// (test_fp_mul 1,885,699 vectors, test_fp_add 1,968,564, both fails=0).

`timescale 1ns/1ps

module m2_geo_xform (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        start,          // one cycle; ignored while busy
  input  logic [31:0] px, py, pz,     // the point, IEEE-754 single
  input  logic [31:0] m [12],         // the current matrix, column order as MAME
  input  logic [31:0] fx, fy,         // focus
  input  logic        vec_only,       // transform_vector: no translate, no focus

  output logic        busy,
  output logic        done,           // one cycle when ox/oy/oz are valid
  output logic [31:0] ox, oy, oz
);

  // ---- the two arithmetic units, shared by the sequencer
  logic        mul_in, add_in, mul_out, add_out;
  logic [31:0] mul_a, mul_b, mul_q;
  logic [31:0] add_a, add_b, add_q;

  fp_mul u_mul (.clk(clk), .rst_n(rst_n), .in_valid(mul_in),
                .a(mul_a), .b(mul_b),
                .out_valid(mul_out), .result(mul_q),
                .overflow(), .underflow(), .invalid());

  fp_add u_add (.clk(clk), .rst_n(rst_n), .in_valid(add_in),
                .a(add_a), .b(add_b), .sub(1'b0),
                .out_valid(add_out), .result(add_q),
                .overflow(), .underflow(), .invalid());

  // ---- sequencer
  //
  // row  = which output component (0..2)
  // term = which input component (0..2), then the translate
  typedef enum logic [2:0] {
    S_IDLE, S_MUL, S_MULW, S_ADDW, S_TRW, S_FOC, S_FOCW, S_DONE
  } state_e;
  state_e state;

  logic [1:0]  row, term, foc_i;
  logic [31:0] acc;
  logic [31:0] p   [3];
  logic [31:0] res [3];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE; busy <= 1'b0; done <= 1'b0;
      row <= 2'd0; term <= 2'd0; foc_i <= 2'd0; acc <= 32'd0;
      ox <= 32'd0; oy <= 32'd0; oz <= 32'd0;
      mul_in <= 1'b0; add_in <= 1'b0;
      mul_a <= 32'd0; mul_b <= 32'd0; add_a <= 32'd0; add_b <= 32'd0;
    end else begin
      mul_in <= 1'b0; add_in <= 1'b0; done <= 1'b0;

      case (state)
        S_IDLE: if (start) begin
          p[0] <= px; p[1] <= py; p[2] <= pz;
          row <= 2'd0; term <= 2'd0; acc <= 32'd0;
          busy <= 1'b1; state <= S_MUL;
        end

        // p[term] * m[term*3 + row]
        S_MUL: begin
          mul_a  <= p[term];
          mul_b  <= m[(term * 3) + row];
          mul_in <= 1'b1;
          state  <= S_MULW;
        end

        S_MULW: if (mul_out) begin
          if (term == 2'd0) begin
            // the first term seeds the accumulator; nothing to add to yet
            acc  <= mul_q;
            term <= 2'd1;
            state <= S_MUL;
          end else begin
            add_a  <= acc;
            add_b  <= mul_q;
            add_in <= 1'b1;
            state  <= S_ADDW;
          end
        end

        S_ADDW: if (add_out) begin
          acc <= add_q;
          if (term != 2'd2) begin
            term  <= term + 2'd1;
            state <= S_MUL;
          end else if (vec_only) begin
            begin
              res[row] <= add_q;
              if (row == 2'd2) begin
                foc_i <= 2'd0;
                state <= vec_only ? S_DONE : S_FOC;
              end else begin
                row   <= row + 2'd1;
                term  <= 2'd0;
                state <= S_MUL;
              end
            end   // a direction takes no translate
          end else begin
            add_a  <= add_q;
            add_b  <= m[9 + row];       // + m[9], m[10], m[11]
            add_in <= 1'b1;
            state  <= S_TRW;
          end
        end

        S_TRW: if (add_out) begin
          acc <= add_q;
          begin
              res[row] <= add_q;
              if (row == 2'd2) begin
                foc_i <= 2'd0;
                state <= vec_only ? S_DONE : S_FOC;
              end else begin
                row   <= row + 2'd1;
                term  <= 2'd0;
                state <= S_MUL;
              end
            end
        end

        // x *= focus.x, y *= focus.y. z is left alone.
        S_FOC: begin
          mul_a  <= res[foc_i];
          mul_b  <= (foc_i == 2'd0) ? fx : fy;
          mul_in <= 1'b1;
          state  <= S_FOCW;
        end

        S_FOCW: if (mul_out) begin
          res[foc_i] <= mul_q;
          if (foc_i == 2'd1) state <= S_DONE;
          else begin foc_i <= 2'd1; state <= S_FOC; end
        end

        S_DONE: begin
          ox <= res[0]; oy <= res[1]; oz <= res[2];
          done <= 1'b1; busy <= 1'b0; state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
