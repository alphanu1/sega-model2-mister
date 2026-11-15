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
// value. Narrowing rounds to nearest even and can overflow to infinity.
//
// This is what makes §8's claim work — that computing the `r` forms in double
// and narrowing once is equivalent to single-precision arithmetic. The single
// rounding happens here.
//
// R1013: SUBNORMALS, AS THE 80960KB HAS THEM IN NORMALIZING MODE WITH THE
// UNDERFLOW MASK SET (PRM §12 "Normalizing Mode", "Floating Underflow
// Exception"): a subnormal single operand is a value, and a result below
// 2^-126 is denormalised and rounded, not flushed. SUBNORM 0 is the flush this
// unit had before (both directions to a signed zero).
//   * Widening a subnormal single gives a NORMAL double (2^-149 is far inside
//     double's range): the significand's leading one moves to the hidden bit,
//     a 23-bit leading-zero count and shift. WREG 1 takes that from a register
//     of the PREVIOUS cycle's s_in, so the count and shift are not on the
//     operand path into the units -- i960_top holds rd1 / rd2 from T_EXEC
//     through T_FP, so the register is the same operand's. The other cases
//     stay combinational. WREG 0: combinational (the unit bench).
//   * Narrowing below 2^-126: the 53-bit significand is shifted right by
//     897 - exponent (capped at 31: beyond that only sticky remains) before
//     the same round to nearest even; a rounding carry out of a subnormal
//     lands in the exponent field, which is 2^-126 exactly, as it should.

module i960_fpcvt #(
  parameter bit SUBNORM = 1'b1,    // R1013: 0 flushes subnormals, as before
  parameter bit WREG    = 1'b0     // R1013: subnormal widening from a register
) (
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic        clk,         // used only when SUBNORM && WREG
  /* verilator lint_on UNUSEDSIGNAL */
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

  // R1013: a subnormal single, sm * 2^-149, as a normal double. With its
  // leading one at bit k (0..22) the value is 1.f * 2^(k - 149): biased
  // exponent k + 874, fraction the bits under the leading one.
  logic [4:0]  slz;                    // 22 - k
  logic [22:0] snorm;
  always_comb begin
    slz = 5'd0;
    for (int i = 0; i < 23; i++)
      if (sm[i]) slz = 5'(22 - i);
  end
  /* verilator lint_off UNUSEDSIGNAL */
  logic [23:0] sm_sh;                  // [23] is the leading one, dropped
  /* verilator lint_on UNUSEDSIGNAL */
  assign sm_sh = {1'b0, sm} << (slz + 5'd1);
  assign snorm = sm_sh[22:0];
  logic [62:0] sub_w, sub_q;           // the double's exponent and fraction
  assign sub_w = {11'd896 - {6'd0, slz}, snorm, 29'd0};   // 874 + k = 896 - slz
  generate
    if (SUBNORM && WREG) begin : g_wreg
      always_ff @(posedge clk) sub_q <= sub_w;
    end else begin : g_wcomb
      assign sub_q = sub_w;
    end
  endgenerate

  always_comb begin
    if (s_zero)     d_out = {ss, 63'd0};
    else if (s_inf) d_out = {ss, 11'h7ff, 52'd0};
    else if (s_nan) d_out = {ss, 11'h7ff, 1'b1, sm, 28'd0};   // quiet it
    else if (s_sub) d_out = SUBNORM ? {ss, sub_q} : {ss, 63'd0};
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

  // R1013: below 2^-126 (de <= 896) the significand X = {1, dm} is shifted
  // right by 897 - de first, the bits it loses joining the sticky. The single
  // fraction is then Xn[51:29] with Xn[52] clear, guard Xn[28], and the
  // exponent field 0 -- the same rounding as a normal result, whose carry
  // into bit 23 then sets the exponent field to 1 (2^-126). A double
  // subnormal (de 0) has no hidden bit and always rounds to a signed zero.
  // Only the 24 bits the rounding reads (fraction and guard, Xn[51:28]) are
  // shifted; everything under them is one sticky, X below bit 28 + shift.
  logic        to_sub;
  logic [10:0] dsh_w;
  logic [4:0]  dsh;
  logic [52:0] dx;
  logic [23:0] dxw;                    // Xn[51:28]
  logic [24:0] dlow;                   // X[52:28] taken into the sticky
  assign to_sub = SUBNORM && (de <= 11'd896);
  assign dsh_w  = 11'd897 - de;
  assign dsh    = !to_sub ? 5'd0 : (dsh_w > 11'd31) ? 5'd31 : dsh_w[4:0];
  assign dx     = {de != 11'd0, dm};
  /* verilator lint_off UNUSEDSIGNAL */
  logic [52:0] dx_sh;                  // [52] is the hidden bit, [27:0] the sticky's
  /* verilator lint_on UNUSEDSIGNAL */
  assign dx_sh  = dx >> dsh;
  assign dxw    = dx_sh[51:28];
  // X[28 + j] joins the sticky when j < shift (31 covers them all: X >> 31
  // keeps bits 52:31, and nothing reaches the guard at 28 after 25).
  /* verilator lint_off UNSIGNED */      // (SUBNORM 0: dsh is 0, the compare constant)
  always_comb
    for (int j = 0; j < 25; j++) dlow[j] = dx[28 + j] && (5'(j) < dsh);
  /* verilator lint_on UNSIGNED */

  logic [22:0] man_t;
  logic        guard, sticky, round_up;
  assign man_t    = dxw[23:1];
  assign guard    = dxw[0];
  assign sticky   = |dx[27:0] | |dlow;
  assign round_up = guard & (sticky | man_t[0]);

  logic [23:0]        man_r;
  logic signed [12:0] exp_r;
  assign man_r = {1'b0, man_t} + {23'd0, round_up};
  // A rounding carry into bit 23 means the significand became 2.0, so the
  // mantissa is zero and the exponent increments — the same rule the datapath
  // blocks needed and got wrong first time. For a subnormal the exponent field
  // is 0 and the carry makes it 1.
  assign exp_r = (to_sub ? 13'sd0 : ($signed({2'b0, de}) - 13'sd896))
               + (man_r[23] ? 13'sd1 : 13'sd0);

  always_comb begin
    if (d_nan)                    s_out = {ds, 8'hff, 1'b1, dm[51:30]};
    else if (d_inf)               s_out = {ds, 8'hff, 23'd0};
    else if (d_zero)              s_out = {ds, 31'd0};
    else if (exp_r >= 13'sd255)   s_out = {ds, 8'hff, 23'd0};   // overflow
    else if (exp_r <= 13'sd0 && !SUBNORM) s_out = {ds, 31'd0};  // flushed
    else                          s_out = {ds, exp_r[7:0], man_r[22:0]};
  end

endmodule
