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
// ---------------------------------------------------------------------------
//
// R869: remr -- fmod(src2, src1), EXACT, on doubles.
//
// MAME's i960.cpp: set_rif(opcode, fmod(t2f, t1f)), the operands widened to
// double (get_1_rif / get_2_rif). fmod is exact: the remainder x - n*y with
// n = trunc(x / y) is always representable, so nothing rounds here; a single
// destination narrows it in i960_top as every other r form (and a remainder
// of two singles is itself a single, so that narrowing is exact too).
//
// The machine is restoring division of the significands, one quotient bit a
// cycle, keeping only the remainder:
//
//   r = mx;  repeat (ex - ey) { if (r >= my) r -= my; r <<= 1; }  if (r >= my) r -= my;
//
// then the remainder is r x 2^(ey - 1075): shifted left one bit a cycle until
// its leading one reaches bit 52, the exponent counting down from ey. Cycles:
// ex - ey + 1, plus up to 52 to normalise (at most ~2,100 for doubles; the
// 80960KB's own microcode quotes 67 to 75,878). Sega Rally's single operands
// take at most ~280.
//
// Special cases, C99 F.9.7.1 (glibc's fmod): a NaN operand, x infinite or y
// zero -> NaN (the units' one quiet NaN); y infinite -> x; x zero -> x;
// |x| < |y| -> x; a zero remainder keeps x's sign. The units' deviations hold
// (p1-i960-spike §8.1): a subnormal operand is zero, a subnormal remainder
// flushes to a zero of x's sign.
//
// x and y are read throughout and must be held from req to done: i960_top
// keeps the register file's read addresses on the instruction through T_FP,
// as it does for the transcendental sequencer (R845).

module i960_fprem (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        req,          // one cycle
  input  logic [63:0] x,            // dividend (src2)
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [63:0] y,            // divisor (src1); its sign does not matter
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [63:0] q,            // fmod(x, y), valid in done's cycle
  output logic        done
);

  wire        sx = x[63];
  wire [10:0] ex = x[62:52];
  wire [10:0] ey = y[62:52];
  wire x_nan  = (ex == 11'h7ff) && (x[51:0] != 52'd0);
  wire y_nan  = (ey == 11'h7ff) && (y[51:0] != 52'd0);
  wire x_inf  = (ex == 11'h7ff) && (x[51:0] == 52'd0);
  wire x_zero = (ex == 11'd0);                   // zero, or a subnormal flushed
  wire y_zero = (ey == 11'd0);
  wire [53:0] my = {2'b01, y[51:0]};

  typedef enum logic [1:0] {S_IDLE, S_DIV, S_NORM} st_t;
  st_t         st;
  logic [53:0] r;            // partial remainder (< 2 my); the result's significand
  logic [10:0] c;            // quotient bits still to take; then the result's exponent
  logic        f_nan, f_zero;

  wire  [54:0] d     = {1'b0, r} - {1'b0, my};
  wire  [53:0] r_sub = d[54] ? r : d[53:0];      // r >= my: take it

  // The result is read in done's cycle, while x is still held (its sign).
  assign q = f_nan  ? {1'b0, 11'h7ff, 1'b1, 51'd0}
           : f_zero ? {sx, 63'd0}
                    : {sx, c, r[51:0]};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st <= S_IDLE; r <= 54'd0; c <= 11'd0; f_nan <= 1'b0; f_zero <= 1'b0; done <= 1'b0;
    end else begin
      done <= 1'b0;
      case (st)
        S_IDLE: if (req) begin
          f_nan  <= x_nan || y_nan || x_inf || y_zero;
          f_zero <= x_zero;
          r      <= {2'b01, x[51:0]};
          if (x_nan || y_nan || x_inf || y_zero || x_zero || (ex < ey)) begin
            // NaN, a zero x, or |x| < |y| (y infinite among them): x itself
            c <= ex; done <= 1'b1;
          end else begin
            c <= ex - ey; st <= S_DIV;
          end
        end
        S_DIV: begin
          if (c == 11'd0) begin
            r <= r_sub; c <= ey; st <= S_NORM;
          end else begin
            r <= {r_sub[52:0], 1'b0}; c <= c - 11'd1;
          end
        end
        S_NORM: begin
          // r < my < 2^53 here. Done when the leading one is at bit 52 (a
          // normal result at exponent c), when r is zero, or when c can fall
          // no further (a subnormal: flushed to a zero of x's sign).
          if (r[52]) begin
            done <= 1'b1; st <= S_IDLE;
          end else if ((r[52:0] == 53'd0) || (c == 11'd1)) begin
            f_zero <= 1'b1; done <= 1'b1; st <= S_IDLE;
          end else begin
            r <= {r[52:0], 1'b0}; c <= c - 11'd1;
          end
        end
        default: st <= S_IDLE;
      endcase
    end
  end

endmodule
