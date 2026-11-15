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
// IEEE-754 double-precision multiplier — the i960 FPU's `mulr` and `mulrl`.
//
// Double, not extended, per docs/p1-i960-spike.md §8: 64 bits is the
// architectural interchange format and the only width the oracle can verify.
//
// Round-to-nearest-even only. The i960 has other rounding modes, but the
// reference computes in host `double` under the host's mode, which is
// round-to-nearest-even, so that is what lockstep compares against.
//
// Two cycles: partial products register, then normalise and round. The 53x53
// mantissa multiply is written as `*` so Quartus infers DSP blocks — measured
// at 3 for the integer unit, and this is the block that decides whether §7's
// "push arithmetic into DSP" lever survives contact with M2-E's finding that a
// comparable renderer already wants 61 of the 112.

// R1013: SUBNORMALS, as the 80960KB has them in normalizing mode with the
// underflow mask set (PRM §12). SUBNORM 1: a subnormal operand is the value
// 0.m * 2^-1022 and a result below 2^-1022 is denormalised, then rounded.
//   * Operands go to the DSP multiply as they are (no hidden bit for a
//     subnormal), so nothing new sits on the operand path into the DSPs. Two
//     subnormals multiply to under 2^-2044, which rounds to a signed zero
//     (e1 = -1021 shifts it all into the sticky). With one, its leading-zero
//     count lzs (computed beside the multiply)
//     says how far the product's leading one sits below where it belongs.
//   * Stage 2 shifts the product LEFT by min(lzs, max(e1, 0)) -- never
//     taking the exponent below 1 -- and, when e1 < 0 (a product below 2^-1022
//     from any operands), RIGHT by -e1 with the bits lost joining the sticky.
//     e1 = ea + eb - 1023 with a subnormal's exponent taken as 1. With
//     E = e1 - lzs: E > 0, or E = 0 with the shifted product's top bit set,
//     is a normal result as before; otherwise the result is subnormal,
//     exponent field 0, and a rounding carry makes it 2^-1022.
// SUBNORM 0 is the flush this unit had before: a subnormal operand is zeroed
// and a result below 2^-1022 is a signed zero.

module i960_fpmul #(
  parameter bit SUBNORM = 1'b1
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        req,
  input  logic [63:0] a,
  input  logic [63:0] b,
  output logic [63:0] y,
  output logic        done
);

  // ------------------------------------------------------------ unpack

  logic        sa, sb;
  logic [10:0] ea, eb;
  logic [51:0] ma, mb;
  assign sa = a[63];
  assign ea = a[62:52];
  assign ma = a[51:0];
  assign sb = b[63];
  assign eb = b[62:52];
  assign mb = b[51:0];

  logic a_zero, b_zero, a_inf, b_inf, a_nan, b_nan, a_sub, b_sub;
  assign a_zero = (ea == 11'd0)    && (ma == 52'd0);
  assign b_zero = (eb == 11'd0)    && (mb == 52'd0);
  assign a_inf  = (ea == 11'h7ff)  && (ma == 52'd0);
  assign b_inf  = (eb == 11'h7ff)  && (mb == 52'd0);
  assign a_nan  = (ea == 11'h7ff)  && (ma != 52'd0);
  assign b_nan  = (eb == 11'h7ff)  && (mb != 52'd0);
  assign a_sub  = (ea == 11'd0)    && (ma != 52'd0);
  assign b_sub  = (eb == 11'd0)    && (mb != 52'd0);

  // Hidden bit. A subnormal has none (SUBNORM 1) or is zeroed (SUBNORM 0).
  logic [52:0] fa, fb;
  assign fa = a_sub ? (SUBNORM ? {1'b0, ma} : 53'd0) : {1'b1, ma};
  assign fb = b_sub ? (SUBNORM ? {1'b0, mb} : 53'd0) : {1'b1, mb};

  // A subnormal's effective exponent is 1 (SUBNORM 1).
  logic [10:0] ea_e, eb_e;
  assign ea_e = (SUBNORM && a_sub) ? 11'd1 : ea;
  assign eb_e = (SUBNORM && b_sub) ? 11'd1 : eb;

  logic signed [12:0] exp_sum;
  assign exp_sum = $signed({2'b0, ea_e}) + $signed({2'b0, eb_e}) - 13'sd1023;

  // R1013: the leading-zero count of the (one) subnormal operand's
  // significand, 1..52; 0 when neither is subnormal. Beside the multiply,
  // not in front of it.
  logic [51:0] msub;
  logic [5:0]  lzs;
  assign msub = a_sub ? ma : mb;
  always_comb begin
    lzs = 6'd0;
    if (SUBNORM && (a_sub || b_sub))
      for (int i = 0; i < 52; i++)
        if (msub[i]) lzs = 6'(52 - i);
  end

  // ----------------------------------------------------------- stage 1

  logic               done_pipe;
  logic [51:0]        res_man;
  logic signed [12:0] res_exp;

  logic [105:0]       p1;
  logic signed [12:0] e1;
  logic [5:0]         lz1;
  logic               s1, sp_zero, sp_inf, sp_nan;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p1 <= 106'd0; e1 <= 13'sd0; s1 <= 1'b0; lz1 <= 6'd0;
      sp_zero <= 1'b0; sp_inf <= 1'b0; sp_nan <= 1'b0;
      done <= 1'b0; y <= 64'd0;
    end else begin
      done <= 1'b0;

      if (req) begin
        p1  <= fa * fb;                      // 53x53 -> DSP blocks
        e1  <= exp_sum;
        lz1 <= lzs;
        s1  <= sa ^ sb;
        // Special cases decided here so the rounding path never sees them.
        // (R1013: two subnormals need no case of their own -- e1 is -1021,
        // so the right shift below leaves only sticky: a signed zero.)
        sp_nan  <= a_nan | b_nan | (a_inf & b_zero) | (a_zero & b_inf);
        sp_inf  <= (a_inf | b_inf) & ~(a_zero | b_zero);
        sp_zero <= (a_zero | b_zero) & ~(a_inf | b_inf);
      end

      // ------------------------------------------------------- stage 2
      if (done_pipe) begin
        if (sp_nan)       y <= {1'b0, 11'h7ff, 1'b1, 51'd0};   // quiet NaN
        else if (sp_inf)  y <= {s1, 11'h7ff, 52'd0};
        else if (sp_zero) y <= {s1, 63'd0};
        // Exponent overflow becomes infinity. SUBNORM 0: underflow becomes
        // zero (flushed); SUBNORM 1 never gets res_exp below 0.
        else if (res_exp >= 13'sd2047) y <= {s1, 11'h7ff, 52'd0};
        else if (res_exp <= 13'sd0 && !SUBNORM) y <= {s1, 63'd0};
        else                           y <= {s1, res_exp[10:0], res_man};
        done <= 1'b1;
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) done_pipe <= 1'b0; else done_pipe <= req;

  // -------------------------------------------------- normalise and round
  //
  // The product of two normalised significands is in [1,4), so the result needs
  // at most a one-bit right shift. Round to nearest even on the bit below the
  // retained mantissa, with sticky from everything under it.
  //
  // R1013: with a subnormal operand the product is shifted left by lsh; below
  // 2^-1022 right by rsh instead (see the header) -- never both, so the two
  // are ONE funnel shift by 52 - lsh + rsh of {0, p1, 0} that delivers only
  // the 55 bits the rounding reads, pf[105:51]; everything under them is one
  // sticky (p1 below bit 51 - lsh + rsh). SUBNORM 0: lsh = rsh = 0, the
  // shift is a constant 52 and folds away, as the unit was.

  logic signed [12:0] e_big;            // E = e1 - lzs
  logic [5:0]         lsh, rsh;
  logic [6:0]         fsh;              // the funnel's right shift, 0..115
  assign e_big = e1 - $signed({7'd0, lz1});
  assign lsh   = !SUBNORM        ? 6'd0
               : (e1 < 13'sd0)   ? 6'd0
               : (e1 < $signed({7'd0, lz1})) ? 6'(e1) : lz1;
  assign rsh   = (!SUBNORM || (e1 >= 13'sd0)) ? 6'd0 : (e1 < -13'sd63) ? 6'd63 : 6'(-e1);
  assign fsh   = 7'd52 - {1'b0, lsh} + {1'b0, rsh};

  /* verilator lint_off UNUSEDSIGNAL */
  logic [221:0] fq;                     // only [105:51] are read
  /* verilator lint_on UNUSEDSIGNAL */
  logic [54:0]  w;                      // pf[105:51]
  assign fq = {64'd0, p1, 52'd0} >> fsh;
  assign w  = fq[105:51];

  // The sticky under the window: p1[j] for j < 51 - lsh + rsh. lsh and rsh
  // are never both non-zero, so it is p1[50:0] less its top lsh bits (a
  // left shift), or p1[50:0] and the low rsh bits of p1[105:51] (a right
  // shift) -- two masks of 51 and 55 bits on 6-bit counts, not one of 106.
  logic [50:0] lo_l;
  logic [54:0] lo_r;
  /* verilator lint_off UNSIGNED */      // (SUBNORM 0: lsh / rsh are 0, the compares constant)
  always_comb begin
    for (int k = 0; k < 51; k++) lo_l[k] = p1[k] && ((7'(k) + {1'b0, lsh}) < 7'd51);
    for (int k = 0; k < 55; k++) lo_r[k] = p1[51 + k] && (6'(k) < rsh);
  end
  /* verilator lint_on UNSIGNED */
  logic st_lo;
  assign st_lo = |lo_l | |lo_r;

  // Normal with the top bit clear: one more left (fraction w[52:1], guard
  // w[0]). Normal with it set, and every subnormal (E < 0, or E = 0 with the
  // top bit clear -- no 1-bit normalise, exponent field 0): fraction
  // w[53:2], guard w[1], w[0] into the sticky.
  logic               is_sub, sh1;
  logic signed [12:0] en;
  assign is_sub = SUBNORM && ((e_big < 13'sd0) || ((e_big == 13'sd0) && !w[54]));
  assign sh1    = !is_sub && !w[54];
  assign en     = w[54] ? (e_big + 13'sd1) : e_big;

  logic [51:0] man_trunc;
  logic        guard, sticky, round_up;
  assign man_trunc = sh1 ? w[52:1] : w[53:2];
  assign guard     = sh1 ? w[0]    : w[1];
  assign sticky    = st_lo | (!sh1 & w[0]);
  assign round_up  = guard & (sticky | man_trunc[0]);

  logic [52:0]        man_rnd;
  logic signed [12:0] exp_rnd, exp_f;
  assign exp_f   = is_sub ? 13'sd0 : en;
  assign man_rnd = {1'b0, man_trunc} + {52'd0, round_up};
  assign exp_rnd = man_rnd[52] ? (exp_f + 13'sd1) : exp_f;

  // Same rounding-carry rule as the adder: a carry into bit 52 means 2.0, so
  // the mantissa is zero and the exponent increments (for a subnormal, to 1).
  assign res_man = man_rnd[51:0];
  assign res_exp = exp_rnd;

endmodule
