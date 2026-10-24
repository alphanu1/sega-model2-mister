// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE for the full text.
//
// IEEE-754 single precision multiplier.
//
// 4-stage pipeline, LATENCY 4.
//
//   1  unpack and issue the 24x24 significand multiply (one Cyclone V
//      variable-precision DSP block in 27x27 mode)
//   2  normalise
//   3  round
//   4  pack
//
// fp_mul was never the timing bottleneck — it measures 114-117 MHz on its own.
// The extra stages exist so it matches fp_add's latency after fp_add was
// retimed to 4 for the Fmax gate. mb86233_alu pushes every non-FP result
// through a matching delay, and that only works if both FP units agree.
//
// Fully pipelined, one result per clock. The TGP retires roughly
// 5.3 M instructions/sec at a 16 MHz part clock so throughput is irrelevant;
// the pipeline exists to keep the DSP block registered and Fmax comfortable.
//
// OPEN QUESTION — denormal handling. MAME evaluates with host floats, which
// are fully IEEE and honour denormals. Real silicon of this era commonly
// flushes to zero. `FLUSH_DENORM_IN` and `FLUSH_DENORM_OUT` expose both
// behaviours. Resolve by fuzzing against the oracle with denormal operands
// before committing. Default matches MAME.

`timescale 1ns/1ps

module fp_mul #(
  parameter bit FLUSH_DENORM_IN  = 1'b0,
  parameter bit FLUSH_DENORM_OUT = 1'b0,
  // R852: SUBNORMAL PRODUCTS, as MAME's host floats give them. 0 is the unit
  // as it was (a product whose significand is below 1 -- a subnormal operand
  // -- is not renormalised, and a result below the normal range flushes).
  // 1 normalises the product by its leading zeros (stage 2) and shifts a
  // result below 2^-126 right into a subnormal before rounding (stage 3).
  // Virtua Fighter 2's TGP program multiplies subnormals on purpose (integers
  // carried as subnormal floats; 152 of 28,787 outputs in a 31-frame window).
  parameter bit SUBNORM          = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        in_valid,
  input  logic [31:0] a,
  input  logic [31:0] b,

  output logic        out_valid,
  output logic [31:0] result,
  output logic        overflow,
  output logic        underflow,
  output logic        invalid      // inf * 0, or NaN operand
);

  // ------------------------------------------------------------- unpack

  logic        a_sign, b_sign;
  logic [7:0]  a_exp,  b_exp;
  logic [22:0] a_frac, b_frac;

  assign a_sign = a[31];  assign a_exp = a[30:23];  assign a_frac = a[22:0];
  assign b_sign = b[31];  assign b_exp = b[30:23];  assign b_frac = b[22:0];

  logic a_is_zero, b_is_zero, a_is_inf, b_is_inf, a_is_nan, b_is_nan;
  logic a_is_den,  b_is_den;

  assign a_is_den  = (a_exp == 8'h00) && (a_frac != 23'd0);
  assign b_is_den  = (b_exp == 8'h00) && (b_frac != 23'd0);
  assign a_is_zero = (a_exp == 8'h00) && (FLUSH_DENORM_IN ? 1'b1 : (a_frac == 23'd0));
  assign b_is_zero = (b_exp == 8'h00) && (FLUSH_DENORM_IN ? 1'b1 : (b_frac == 23'd0));
  assign a_is_inf  = (a_exp == 8'hff) && (a_frac == 23'd0);
  assign b_is_inf  = (b_exp == 8'hff) && (b_frac == 23'd0);
  assign a_is_nan  = (a_exp == 8'hff) && (a_frac != 23'd0);
  assign b_is_nan  = (b_exp == 8'hff) && (b_frac != 23'd0);

  // Significand with implicit bit. Denormals carry a leading zero and an
  // exponent that behaves as 1, which the wide multiply handles directly.
  logic [23:0] a_sig, b_sig;
  assign a_sig = (a_is_den && !FLUSH_DENORM_IN) ? {1'b0, a_frac} : {1'b1, a_frac};
  assign b_sig = (b_is_den && !FLUSH_DENORM_IN) ? {1'b0, b_frac} : {1'b1, b_frac};

  logic signed [10:0] a_e_eff, b_e_eff;
  assign a_e_eff = (a_exp == 8'h00) ? 11'sd1 : $signed({3'b000, a_exp});
  assign b_e_eff = (b_exp == 8'h00) ? 11'sd1 : $signed({3'b000, b_exp});

  // SUBNORM: the operands' leading zeros, counted beside the multiply (not in
  // front of it) and registered with the product -- so stage 2 normalises by
  // a registered amount, and the subnormal decision is two registered flags
  // and one product bit (R852: a leading-zero count and a denormalising shift
  // in one stage were -7.8 ns post-map at 80 MHz).
  function automatic logic [4:0] lz24(input logic [23:0] v);
    lz24 = 5'd24;
    for (int i = 0; i < 24; i++) if (v[i]) lz24 = 5'(23 - i);
  endfunction
  wire [5:0] in_lz = SUBNORM ? ({1'b0, lz24(a_sig)} + {1'b0, lz24(b_sig)}) : 6'd0;
  wire signed [10:0] in_exp = a_e_eff + b_e_eff - 11'sd127;

  // ------------------------------------------------------------ stage 1

  logic               s1_valid;
  logic               s1_sign;
  logic signed [10:0] s1_exp;
  logic [47:0]        s1_prod;
  logic               s1_zero, s1_inf, s1_nan, s1_invalid;
  logic [5:0]         s1_lz;          // SUBNORM: the operands' leading zeros
  logic signed [10:0] s1_explz;       // s1_exp + 1 - s1_lz: the exponent if bit 47 ends up set
  logic               s1_xle0, s1_xeq1;   // s1_explz <= 0, == 1
  logic               s1_epos;        // s1_exp > 0
  logic [5:0]         s1_lsh;         // s1_exp, clamped to 0..47 (a subnormal result's left shift)
  logic [5:0]         s1_rsh;         // -s1_exp, clamped to 0..48 (... or its right shift)

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1_valid <= 1'b0;
    end else begin
      s1_valid   <= in_valid;
      s1_sign    <= a_sign ^ b_sign;
      s1_exp     <= in_exp;
      s1_lz      <= in_lz;
      s1_explz   <= in_exp + 11'sd1 - $signed({5'd0, in_lz});
      s1_xle0    <= (in_exp + 11'sd1 - $signed({5'd0, in_lz})) <= 11'sd0;
      s1_xeq1    <= (in_exp + 11'sd1 - $signed({5'd0, in_lz})) == 11'sd1;
      s1_epos    <= in_exp > 11'sd0;
      s1_lsh     <= (in_exp > 11'sd47) ? 6'd47 : (in_exp > 11'sd0) ? in_exp[5:0] : 6'd0;
      s1_rsh     <= (in_exp < -11'sd47) ? 6'd48 : (in_exp < 11'sd0) ? 6'(-in_exp) : 6'd0;
      s1_prod    <= a_sig * b_sig;
      s1_invalid <= (a_is_nan | b_is_nan)
                  | (a_is_inf & b_is_zero) | (b_is_inf & a_is_zero);
      s1_nan     <= (a_is_nan | b_is_nan)
                  | (a_is_inf & b_is_zero) | (b_is_inf & a_is_zero);
      s1_inf     <= (a_is_inf | b_is_inf) & ~(a_is_zero | b_is_zero);
      s1_zero    <= (a_is_zero | b_is_zero) & ~(a_is_inf | b_is_inf);
    end
  end

  // ------------------------------------------------------------ stage 2

  // Product of two [1,2) significands lands in [1,4). Bit 47 set means the
  // result needs one right shift and an exponent bump.
  logic               norm_shift;
  logic [47:0]        norm_prod;
  logic signed [10:0] norm_exp;

  // SUBNORM: shifted by the operands' leading zeros the product has bit 47
  // or 46 set; one more step normalises it (the original unit's step). A
  // result below 2^-126 is the product shifted by s1_exp itself -- left, or
  // right with the lost bits kept as a sticky bit 0 -- with exponent 0: the
  // normalised product shifted right by 1 - exponent comes to exactly that.
  //
  // R952: ONE LEFT SHIFTER, NOT TWO. The leading-zero shift (by s1_lz) and a
  // subnormal's left shift (by s1_lsh) were separate 48-bit shifters; they
  // share one, its amount picked by the registered s1_xle0. Below 2^-126 by
  // s1_xle0 it is s1_lsh, as before. Otherwise it is s1_lz -- the old p_lz,
  // and p_nsh with it -- and the other way into a subnormal, s1_xeq1 with
  // p_nsh, means s1_exp == s1_lz (explz = exp + 1 - lz = 1; lz <= 46, a
  // significand has at most 23 leading zeros), where the old p_left
  // (exp > 0, lsh = exp) and p_rgt (exp = lz = 0, a shift by nothing) were
  // both this same product. Every result identical (R952: the old unit
  // beside this one, 30 M random operand pairs per SUBNORM setting). p_nsh
  // stays the one bit of the s1_lz shift it always was (a 48:1 select, not
  // a shifter), so the path into s2_exp is the length it was.
  wire [47:0] p_sh   = s1_prod << (s1_xle0 ? s1_lsh : s1_lz);
  wire [47:0] p_lz   = s1_prod << s1_lz;   // bit 47 alone is used
  wire        p_nsh  = !p_lz[47];
  wire        p_den  = SUBNORM && (s1_xle0 || (s1_xeq1 && p_nsh));
  wire [47:0] p_rgt  = (s1_rsh >= 6'd48) ? {47'd0, |s1_prod}
                     : ((s1_prod >> s1_rsh[5:0])
                        | {47'd0, |(s1_prod & ~(48'hFFFF_FFFF_FFFF << s1_rsh[5:0]))});
  assign norm_shift = s1_prod[47];
  assign norm_prod  = !SUBNORM ? (norm_shift ? s1_prod : (s1_prod << 1))
                    : (s1_xle0 && !s1_epos) ? p_rgt
                    : (p_nsh && !p_den) ? (p_sh << 1) : p_sh;
  assign norm_exp   = !SUBNORM ? (s1_exp + (norm_shift ? 11'sd1 : 11'sd0))
                    : p_den    ? 11'sd0
                    : (s1_explz - (p_nsh ? 11'sd1 : 11'sd0));

  // norm_prod[47] is the implicit bit, [46:24] the fraction.
  // ------------------------------------------- stage 2: register normalised
  logic               s2_valid, s2_sign, s2_zero, s2_inf, s2_nan, s2_invalid;
  logic [47:0]        s2_prod;
  logic signed [10:0] s2_exp;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) s2_valid <= 1'b0;
    else begin
      s2_valid   <= s1_valid;
      s2_sign    <= s1_sign;
      s2_prod    <= norm_prod;
      s2_exp     <= norm_exp;
      s2_zero    <= s1_zero;
      s2_inf     <= s1_inf;
      s2_nan     <= s1_nan;
      s2_invalid <= s1_invalid;
    end
  end

  // ------------------------------------------------------ stage 3: round
  logic [22:0] frac_pre;
  logic        guard, round_bit, sticky;

  // SUBNORM: a subnormal arrives here already shifted, with exponent 0; a
  // round carry out of it gives exponent 1, the smallest normal, as IEEE.
  wire [47:0]        dn_prod = s2_prod;
  wire signed [10:0] dn_exp  = s2_exp;

  assign frac_pre  = dn_prod[46:24];
  assign guard     = dn_prod[23];
  assign round_bit = dn_prod[22];
  assign sticky    = |dn_prod[21:0];

  // Round to nearest, ties to even.
  logic round_up;
  assign round_up = guard & (round_bit | sticky | frac_pre[0]);

  logic [23:0]        frac_rnd;      // carry out of bit 22 on overflow
  logic signed [10:0] exp_rnd;
  logic [22:0]        frac_final;

  assign frac_rnd   = {1'b0, frac_pre} + {23'd0, round_up};
  assign exp_rnd    = dn_exp + (frac_rnd[23] ? 11'sd1 : 11'sd0);
  assign frac_final = frac_rnd[23] ? 23'd0 : frac_rnd[22:0];

  logic ovf, unf;
  assign ovf = (exp_rnd >= 11'sd255);
  assign unf = SUBNORM ? 1'b0 : (exp_rnd <= 11'sd0);   // SUBNORM: exponent 0 packs as subnormal

  // Registered between the round adder and the pack, so the carry chain and
  // the special-case mux are not on one path.
  logic               s3_valid, s3_sign, s3_zero, s3_inf, s3_nan, s3_invalid;
  logic               s3_ovf, s3_unf;
  logic [22:0]        s3_frac;
  logic signed [10:0] s3_exp;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) s3_valid <= 1'b0;
    else begin
      s3_valid   <= s2_valid;
      s3_sign    <= s2_sign;
      s3_frac    <= frac_final;
      s3_exp     <= exp_rnd;
      s3_zero    <= s2_zero;
      s3_inf     <= s2_inf;
      s3_nan     <= s2_nan;
      s3_invalid <= s2_invalid;
      s3_ovf     <= ovf;
      s3_unf     <= unf;
    end
  end

  // ------------------------------------------------------- stage 4: pack
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
      result    <= 32'd0;
      overflow  <= 1'b0;
      underflow <= 1'b0;
      invalid   <= 1'b0;
    end else begin
      out_valid <= s3_valid;
      invalid   <= s3_valid & s3_invalid;
      overflow  <= 1'b0;
      underflow <= 1'b0;

      if (s3_nan) begin
        result <= 32'h7fc00000;                    // quiet NaN
      end else if (s3_inf) begin
        result <= {s3_sign, 8'hff, 23'd0};
      end else if (s3_zero) begin
        result <= {s3_sign, 8'h00, 23'd0};
      end else if (s3_ovf) begin
        result   <= {s3_sign, 8'hff, 23'd0};
        overflow <= s3_valid;
      end else if (s3_unf) begin
        // Denormal output path not built: flush. See OPEN QUESTION above.
        result    <= {s3_sign, 8'h00, 23'd0};
        underflow <= s3_valid;
      end else begin
        result <= {s3_sign, s3_exp[7:0], s3_frac};
      end
    end
  end

endmodule
