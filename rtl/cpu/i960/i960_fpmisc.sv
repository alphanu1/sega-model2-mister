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
// i960 FPU compare, convert, scale and round — the exactly-specified group.
//
// Every operation here has one right answer defined by IEEE-754 or by plain
// integer arithmetic, so matching the reference is guaranteed rather than
// approximated. That is what separates this block from the transcendental
// group in §8.2, where the reference's answer comes from libm's particular
// approximation and there is nothing exact to aim at.
//
//   cmp      cmpr / cmprl    -> condition code, cmp_d
//   logb     logbnr          -> unbiased exponent as a double
//   cvtir    int32 -> double (exact: int32 fits a 53-bit mantissa)
//   cvtri    double -> int32, rounding mode from AC[31:30]
//   cvtzri   double -> int32, truncating
//   round    roundr          -> double rounded to an integral double
//   scale    scaler          -> multiply by 2^n, an exponent add
//
// The rounding mode is AC[31:30] and is NOT round-to-nearest-even:
//   0 = round half AWAY FROM ZERO (C's round()), 1 = floor, 2 = ceil,
//   3 = truncate toward zero.
// Model 1's M0 recorded the same trap on the TGP's cfxd — "round to nearest"
// in a mode field usually means half-to-even and here it does not.

module i960_fpmisc #(
  // R575: 1 puts a register after the round add, splitting the unit's ~25 ns
  // at about half: unpack, fraction mask, round decision and the add before
  // it; the shift, overflow, leading-zero count, renormalise and the result
  // select after. Results then appear one clk after the operands. 0 is the
  // combinational unit exactly as it was, and clk is unused.
  parameter bit STAGED = 1'b0
) (
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic        clk,          // R575: used only when STAGED
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [2:0]  op,
  input  logic [1:0]  rmode,        // AC[31:30]
  input  logic [63:0] a,            // FP operand
  input  logic [63:0] b,            // FP operand for compare
  input  logic [31:0] ai,           // integer operand for cvtir / scale
  output logic [63:0] y,            // FP result
  output logic [31:0] yi,           // integer result
  output logic [2:0]  cc            // condition code for compare
);

  localparam logic [2:0] OP_CMP    = 3'd0;
  localparam logic [2:0] OP_LOGB   = 3'd1;
  localparam logic [2:0] OP_CVTIR  = 3'd2;
  localparam logic [2:0] OP_CVTRI  = 3'd3;
  localparam logic [2:0] OP_CVTZRI = 3'd4;
  localparam logic [2:0] OP_ROUND  = 3'd5;
  localparam logic [2:0] OP_SCALE  = 3'd6;
  localparam logic [2:0] OP_MOV    = 3'd7;

  logic        sa;
  logic [10:0] ea;
  logic [51:0] ma;
  assign sa = a[63];
  assign ea = a[62:52];
  assign ma = a[51:0];

  logic a_zero, a_nan, a_inf;
  assign a_zero = (ea == 11'd0)   && (ma == 52'd0);
  assign a_nan  = (ea == 11'h7ff) && (ma != 52'd0);
  assign a_inf  = (ea == 11'h7ff) && (ma == 52'd0);

  logic signed [12:0] eu;                 // unbiased exponent
  assign eu = $signed({2'b0, ea}) - 13'sd1023;

  // ------------------------------------------------------------- compare
  //
  // cmp_d sets 4 for less, 2 for equal, 1 for greater and leaves all three
  // clear when either operand is NaN — every comparison against NaN is false.

  logic        sb;
  logic [10:0] eb;
  logic [51:0] mb;
  logic        b_nan, b_zero;
  assign sb     = b[63];
  assign eb     = b[62:52];
  assign mb     = b[51:0];
  assign b_nan  = (eb == 11'h7ff) && (mb != 52'd0);
  assign b_zero = (eb == 11'd0)   && (mb == 52'd0);

  // Ordered comparison on the raw bits: for equal signs the IEEE encoding is
  // monotonic, so the magnitude comparison is a plain unsigned compare.
  logic mag_lt, mag_eq;
  assign mag_lt = {ea, ma} <  {eb, mb};
  assign mag_eq = {ea, ma} == {eb, mb};

  logic both_zero, a_lt_b, a_eq_b;
  assign both_zero = a_zero && b_zero;          // +0 == -0
  assign a_lt_b = (sa != sb) ? (sa && !both_zero)
                             : (sa ? (!mag_lt && !mag_eq) : mag_lt);
  assign a_eq_b = both_zero || ((sa == sb) && mag_eq);

  logic [2:0] cc_c;
  always_comb begin
    if (a_nan || b_nan) cc_c = 3'b000;
    else if (a_lt_b)    cc_c = 3'b100;
    else if (a_eq_b)    cc_c = 3'b010;
    else                cc_c = 3'b001;
  end

  // ----------------------------------------------------- int32 -> double
  //
  // Exact: a 32-bit integer always fits a 53-bit significand.

  logic [31:0] imag;
  assign imag = ai[31] ? (~ai + 32'd1) : ai;

  logic [5:0] ilz;
  always_comb begin
    ilz = 6'd32;
    for (int i = 0; i < 32; i++)
      if (imag[i]) ilz = 6'(31 - i);
  end

  logic [51:0]        i2d_man;
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [12:0] i2d_exp;   // only [10:0] reaches the encoding
  /* verilator lint_on UNUSEDSIGNAL */
  assign i2d_man = 52'(({20'd0, imag} << ilz) << 21);   // drop the hidden bit
  assign i2d_exp = 13'sd1023 + 13'sd31 - $signed({7'd0, ilz});

  logic [63:0] i2d;
  assign i2d = (ai == 32'd0) ? 64'd0 : {ai[31], i2d_exp[10:0], i2d_man};

  // ------------------------------------------- double -> integral value
  //
  // The mantissa has (52 - eu) fractional bits. Below zero the whole value is
  // fractional; at 52 or above it is already integral.

  // The significand fa_full represents the value fa_full * 2^(eu-52), so the
  // number of fractional bits is (52 - eu). For |x| < 1 that exceeds 52, and
  // capping it at 53 was wrong: 0.25 then looked like 0.5 and rounded to 1.
  // Capping at 55 is safe because anything below 2^-3 rounds identically under
  // every mode — the fraction is non-zero and below a half either way.
  logic [5:0]  fbits;
  logic [52:0] fa_full;
  assign fa_full = (ea == 11'd0) ? 53'd0 : {1'b1, ma};
  always_comb begin
    if (eu >= 13'sd52)      fbits = 6'd0;
    else if (eu <= -13'sd3) fbits = 6'd55;
    else                    fbits = 6'(52 - eu);
  end

  logic [55:0] fa_w, frac_mask, frac_part, int_part;
  assign fa_w      = {3'd0, fa_full};
  assign frac_mask = (56'd1 << fbits) - 56'd1;
  assign frac_part = fa_w & frac_mask;
  assign int_part  = fa_w & ~frac_mask;

  // Half of the fractional field, for round-half-away-from-zero.
  logic [55:0] half;
  assign half = (fbits == 6'd0) ? 56'd0 : (56'd1 << (fbits - 6'd1));

  logic inc;
  // cvtzri truncates REGARDLESS of the mode field — the z is "toward zero" and
  // it ignores AC[31:30], where cvtri honours it.
  logic [1:0] eff_rmode;
  assign eff_rmode = (op == OP_CVTZRI) ? 2'd3 : rmode;

  always_comb begin
    case (eff_rmode)
      2'd0:    inc = (frac_part >= half) && (fbits != 6'd0);  // half away from 0
      2'd1:    inc = sa && (frac_part != 56'd0);              // floor
      2'd2:    inc = !sa && (frac_part != 56'd0);             // ceil
      default: inc = 1'b0;                                    // truncate
    endcase
  end

  logic [56:0] rounded;
  assign rounded = {1'b0, int_part} +
                   (inc ? ({1'b0, frac_mask} + 57'd1) : 57'd0);

  // --------------------------------------------------- R575: the stage
  //
  // Everything the second half needs, and every result the first half has
  // already finished (compare, int-to-double, scale, logb -- computed below
  // from the operands and registered with the rest).
  logic [56:0]        r2_rounded;
  logic [5:0]         r2_fbits;
  logic signed [12:0] r2_eu;
  logic               r2_sa, r2_a_nan, r2_a_inf, r2_inc;
  logic [63:0]        r2_a, r2_i2d, r2_scaled, r2_logb_d;
  logic [2:0]         r2_op;
  logic [63:0]        scaled, logb_d;       // declared here, computed below
  generate
    if (STAGED) begin : g_staged
      always_ff @(posedge clk) begin
        r2_rounded <= rounded; r2_fbits <= fbits; r2_eu <= eu;
        r2_sa <= sa; r2_a_nan <= a_nan; r2_a_inf <= a_inf; r2_inc <= inc;
        r2_a <= a; r2_i2d <= i2d; r2_scaled <= scaled; r2_logb_d <= logb_d;
        r2_op <= op; cc <= cc_c;
      end
    end else begin : g_comb
      always_comb begin
        r2_rounded = rounded; r2_fbits = fbits; r2_eu = eu;
        r2_sa = sa; r2_a_nan = a_nan; r2_a_inf = a_inf; r2_inc = inc;
        r2_a = a; r2_i2d = i2d; r2_scaled = scaled; r2_logb_d = logb_d;
        r2_op = op; cc = cc_c;
      end
    end
  endgenerate

  // Integer result: shift the significand down to the units position. No
  // short-circuit on r2_a negative exponent — 0.5 rounds to 1, not to 0.
  // Keep the shift at full width. Truncating it to 32 bits first destroys the
  // evidence: rounding can carry the magnitude up past 2^32 -- 4294967295.5
  // rounds to 2^32 -- and the truncated result is then 0, which looks like r2_a
  // small in-range value and passes any test that only inspects bit 31.
  logic [56:0] shifted;
  assign shifted = r2_rounded >> r2_fbits;

  logic [31:0] int_abs;
  always_comb begin
    if (r2_eu > 13'sd31) int_abs = 32'h8000_0000;
    else              int_abs = shifted[31:0];
  end

  // Overflow is NOT `r2_eu > 31`. An exponent of exactly 31 covers magnitudes in
  // [2^31, 2^32), all of which are out of int32 range -- except -2^31, which is
  // representable. Testing the exponent alone silently wrapped -3.18e9 to r2_a
  // positive value and agreed with nothing.
  //
  // The out-of-range value is 0x8000_0000, matching the oracle. MAME casts r2_a
  // double to int32_t, which is undefined in C++ and yields x86's indefinite
  // value; the i960 manual instead specifies the truncated low 32 bits when the
  // integer-overflow fault is masked. Those disagree, and the oracle wins --
  // see the design study for the record. Daytona converts no out-of-range
  // float, so nothing in the game depends on which was chosen.
  logic ovf;
  assign ovf = (r2_eu > 13'sd31) || (|shifted[56:32]) ||
               (shifted[31] && !(r2_sa && (shifted[30:0] == 31'd0)));

  assign yi = (r2_a_nan || ovf) ? 32'h8000_0000
                             : (r2_sa ? (~int_abs + 32'd1) : int_abs);

  // Integral double result. The integral value is r2_rounded * 2^(r2_eu-52), so it
  // is renormalised rather than pasted back under the original exponent —
  // which is what produced r2_a nonsense exponent for |x| < 1.
  logic [5:0] rlz;
  always_comb begin
    rlz = 6'd57;
    for (int i = 0; i < 57; i++)
      if (r2_rounded[i]) rlz = 6'(i);          // index of the highest set bit
  end

  // Rounding to an integral value cannot overflow or underflow the exponent
  // range, so rexp[12:11] carry no information.
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [12:0] rexp;
  /* verilator lint_on UNUSEDSIGNAL */
  assign rexp = $signed({7'd0, rlz}) + r2_eu - 13'sd52 + 13'sd1023;

  logic [51:0] rman;
  assign rman = (rlz >= 6'd52) ? 52'(r2_rounded >> (rlz - 6'd52))
                               : 52'(r2_rounded << (6'd52 - rlz));

  logic [63:0] round_d;
  always_comb begin
    if (r2_a_nan || r2_a_inf || (r2_eu >= 13'sd52)) round_d = r2_a;
    // |x| < 1 rounds to zero or to +/-1 and nothing else, so it needs no
    // renormalising. It also MUST bypass it: r2_fbits is capped at 55 below 2^-3,
    // which breaks the value = r2_rounded * 2^(r2_eu-52) relation the general path
    // depends on and produced r2_a nonsense exponent.
    else if (r2_eu < 13'sd0)                  round_d = r2_inc ? {r2_sa, 11'd1023, 52'd0}
                                                         : {r2_sa, 63'd0};
    else if (r2_rounded == 57'd0)             round_d = {r2_sa, 63'd0};
    else                                   round_d = {r2_sa, rexp[10:0], rman};
  end

  // ------------------------------------------------------------- scale
  //
  // Multiply by 2^n is an exponent add. Overflow becomes infinity, underflow
  // zero, matching the datapath blocks' flush behaviour.

  logic signed [12:0] sc_exp;
  assign sc_exp = $signed({2'b0, ea}) + $signed(ai[12:0]);

  always_comb begin
    if (a_nan || a_inf || a_zero)     scaled = a;
    else if (sc_exp >= 13'sd2047)     scaled = {sa, 11'h7ff, 52'd0};
    else if (sc_exp <= 13'sd0)        scaled = {sa, 63'd0};
    else                              scaled = {sa, sc_exp[10:0], ma};
  end

  // -------------------------------------------------------------- logb
  //
  // logb returns the unbiased exponent as a double: an int-to-double of eu.

  logic [31:0]        logb_i;
  logic signed [12:0] eu_l;
  assign eu_l   = eu;
  assign logb_i = 32'(eu_l);

  logic [31:0] lmag;
  logic [5:0]  llz;
  assign lmag = logb_i[31] ? (~logb_i + 32'd1) : logb_i;
  always_comb begin
    llz = 6'd32;
    for (int i = 0; i < 32; i++)
      if (lmag[i]) llz = 6'(31 - i);
  end

  assign logb_d = a_zero ? {1'b1, 11'h7ff, 52'd0}                 // logb(0) = -inf
                : a_inf  ? {1'b0, 11'h7ff, 52'd0}
                : a_nan  ? a
                : (logb_i == 32'd0) ? 64'd0
                : {logb_i[31],
                   11'(13'sd1023 + 13'sd31 - $signed({7'd0, llz})),
                   52'(({20'd0, lmag} << llz) << 21)};

  // ------------------------------------------------------------- select

  always_comb begin
    case (r2_op)
      OP_LOGB:            y = r2_logb_d;
      OP_CVTIR:           y = r2_i2d;
      OP_ROUND:           y = round_d;
      OP_SCALE:           y = r2_scaled;
      OP_CMP, OP_MOV,
      OP_CVTRI, OP_CVTZRI: y = r2_a;   // cmp and the int converts produce yi/cc
      default:            y = r2_a;
    endcase
  end

endmodule
