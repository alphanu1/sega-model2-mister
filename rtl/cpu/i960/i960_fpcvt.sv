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
// Single <-> double conversion — the i960 FPU's operand plumbing.
//
// Every `r`-form instruction reads its operands through u2f (a 32-bit register
// reinterpreted as IEEE single, widened to double) and writes its result
// through f2u (double narrowed back to single). The `rl` forms use register
// pairs and need no conversion at all.
//
// Widening is EXACT: single's 24-bit significand and 8-bit exponent both fit
// double with room to spare, so there is nothing to round and no way to lose a
// value. Narrowing rounds to nearest even and can overflow to infinity or
// underflow to zero.
//
// This is what makes §8's claim work — that computing the `r` forms in double
// and narrowing once is equivalent to single-precision arithmetic. The single
// rounding happens here.

module i960_fpcvt (
  input  logic [31:0] s_in,        // IEEE single, as held in a register
  output logic [63:0] d_out,       // widened, exact

  input  logic [63:0] d_in,        // IEEE double
  output logic [31:0] s_out        // narrowed, round-to-nearest-even
);

  // ------------------------------------------------------ single -> double

  logic        ss;
  logic [7:0]  se;
  logic [22:0] sm;
  assign ss = s_in[31];
  assign se = s_in[30:23];
  assign sm = s_in[22:0];

  logic s_zero, s_inf, s_nan, s_sub;
  assign s_zero = (se == 8'd0)   && (sm == 23'd0);
  assign s_inf  = (se == 8'hff)  && (sm == 23'd0);
  assign s_nan  = (se == 8'hff)  && (sm != 23'd0);
  assign s_sub  = (se == 8'd0)   && (sm != 23'd0);

  always_comb begin
    if (s_zero)     d_out = {ss, 63'd0};
    else if (s_inf) d_out = {ss, 11'h7ff, 52'd0};
    else if (s_nan) d_out = {ss, 11'h7ff, 1'b1, sm, 28'd0};   // quiet it
    // Subnormal singles are flushed, consistent with the datapath blocks.
    else if (s_sub) d_out = {ss, 63'd0};
    else            d_out = {ss, 11'({8'd0, se} + 11'd896), sm, 29'd0};
  end

  // ------------------------------------------------------ double -> single
  //
  // Bias adjust is 1023 -> 127, i.e. subtract 896. The significand drops from
  // 52 bits to 23, so 29 bits are rounded away.

  logic        ds;
  logic [10:0] de;
  logic [51:0] dm;
  assign ds = d_in[63];
  assign de = d_in[62:52];
  assign dm = d_in[51:0];

  logic d_zero, d_inf, d_nan;
  assign d_zero = (de == 11'd0)   && (dm == 52'd0);
  assign d_inf  = (de == 11'h7ff) && (dm == 52'd0);
  assign d_nan  = (de == 11'h7ff) && (dm != 52'd0);

  logic [22:0] man_t;
  logic        guard, sticky, round_up;
  assign man_t    = dm[51:29];
  assign guard    = dm[28];
  assign sticky   = |dm[27:0];
  assign round_up = guard & (sticky | man_t[0]);

  logic [23:0]        man_r;
  logic signed [12:0] exp_r;
  assign man_r = {1'b0, man_t} + {23'd0, round_up};
  // A rounding carry into bit 23 means the significand became 2.0, so the
  // mantissa is zero and the exponent increments — the same rule the datapath
  // blocks needed and got wrong first time.
  assign exp_r = $signed({2'b0, de}) - 13'sd896 + (man_r[23] ? 13'sd1 : 13'sd0);

  always_comb begin
    if (d_nan)                    s_out = {ds, 8'hff, 1'b1, dm[51:30]};
    else if (d_inf)               s_out = {ds, 8'hff, 23'd0};
    else if (d_zero)              s_out = {ds, 31'd0};
    else if (exp_r >= 13'sd255)   s_out = {ds, 8'hff, 23'd0};   // overflow
    else if (exp_r <= 13'sd0)     s_out = {ds, 31'd0};          // underflow
    else                          s_out = {ds, exp_r[7:0], man_r[22:0]};
  end

endmodule
