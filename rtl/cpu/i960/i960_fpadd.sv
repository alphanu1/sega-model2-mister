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
// IEEE-754 double-precision adder/subtractor — the i960 FPU's addr/subr and
// addrl/subrl. Double per docs/p1-i960-spike.md §8.
//
// Two cycles: align and add, then normalise and round. Round-to-nearest-even,
// matching the host mode the reference computes under.
//
// Model 1's M0 recorded that its single-precision fp_add was the block holding
// the whole TGP's critical path, and that reaching the Fmax gate needed it
// split from two stages to four. Expect the same pressure here at double
// width; the split is deliberately left until there is a measurement asking
// for it, rather than paid for in advance.
//
// Deviations, the same set the multiplier carries: subnormals flushed,
// exponent overflow to infinity, underflow to zero.

module i960_fpadd (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        req,
  input  logic        sub,          // subtract: negate b before adding
  input  logic [63:0] a,
  input  logic [63:0] b,
  output logic [63:0] y,
  output logic        done
);

  // ------------------------------------------------------------- unpack

  logic        sa, sb_in, sb;
  logic [10:0] ea, eb;
  logic [51:0] ma, mb;

  assign sa     = a[63];
  assign ea     = a[62:52];
  assign ma     = a[51:0];
  assign sb_in  = b[63];
  assign sb     = sb_in ^ sub;
  assign eb     = b[62:52];
  assign mb     = b[51:0];

  logic a_zero, b_zero, a_inf, b_inf, a_nan, b_nan;
  assign a_zero = (ea == 11'd0)   && (ma == 52'd0);
  assign b_zero = (eb == 11'd0)   && (mb == 52'd0);
  assign a_inf  = (ea == 11'h7ff) && (ma == 52'd0);
  assign b_inf  = (eb == 11'h7ff) && (mb == 52'd0);
  assign a_nan  = (ea == 11'h7ff) && (ma != 52'd0);
  assign b_nan  = (eb == 11'h7ff) && (mb != 52'd0);

  // Subnormals are flushed to zero; see the header.
  logic [52:0] fa, fb;
  assign fa = (ea == 11'd0) ? 53'd0 : {1'b1, ma};
  assign fb = (eb == 11'd0) ? 53'd0 : {1'b1, mb};

  // --------------------------------------------- order by magnitude
  //
  // The larger operand keeps its exponent; the smaller is aligned down to it.

  logic a_bigger;
  assign a_bigger = (ea > eb) || ((ea == eb) && (fa >= fb));

  logic [10:0] e_big;
  logic [52:0] f_big, f_small;
  logic        s_big, s_small;
  assign e_big   = a_bigger ? ea : eb;
  assign f_big   = a_bigger ? fa : fb;
  assign f_small = a_bigger ? fb : fa;
  assign s_big   = a_bigger ? sa : sb;
  assign s_small = a_bigger ? sb : sa;

  // Shift is capped: past 56 bits the smaller operand contributes only sticky.
  logic [10:0] ediff_raw;
  logic [5:0]  sh;
  assign ediff_raw = (a_bigger ? ea : eb) - (a_bigger ? eb : ea);
  assign sh        = (ediff_raw > 11'd56) ? 6'd56 : ediff_raw[5:0];

  // Three guard bits below the mantissa carry guard, round and sticky.
  logic [55:0] big_w, small_w, small_al, lost;
  logic        sticky_al;
  assign big_w     = {f_big,   3'd0};
  assign small_w   = {f_small, 3'd0};
  assign small_al  = small_w >> sh;
  assign lost      = (sh == 6'd0) ? 56'd0 : (small_w << (7'd56 - {1'b0, sh}));
  assign sticky_al = |lost;

  logic [55:0] small_s;
  assign small_s = {small_al[55:1], small_al[0] | sticky_al};

  logic        eff_sub;
  logic [56:0] sum_raw;
  assign eff_sub = s_big ^ s_small;
  assign sum_raw = eff_sub ? ({1'b0, big_w} - {1'b0, small_s})
                           : ({1'b0, big_w} + {1'b0, small_s});

  // ------------------------------------------------------------ stage 1

  logic [56:0]        s1_sum;
  logic [10:0]        s1_exp;
  logic               s1_sign, s1_nan, s1_inf, s1_zero, done_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1_sum <= 57'd0; s1_exp <= 11'd0; s1_sign <= 1'b0;
      s1_nan <= 1'b0; s1_inf <= 1'b0; s1_zero <= 1'b0;
      done_q <= 1'b0; done <= 1'b0; y <= 64'd0;
    end else begin
      done_q <= req;
      done   <= 1'b0;

      if (req) begin
        s1_sum  <= sum_raw;
        s1_exp  <= e_big;
        s1_sign <= s_big;
        // inf - inf is NaN; inf + anything else is inf.
        s1_nan  <= a_nan | b_nan | (a_inf & b_inf & (sa ^ sb));
        s1_inf  <= (a_inf | b_inf) & ~(a_nan | b_nan) &
                   ~(a_inf & b_inf & (sa ^ sb));
        // Both zero: the sign of a zero result follows the addends, and
        // (-0) + (-0) is -0 while (+0) + (-0) is +0 under round-to-nearest.
        s1_zero <= a_zero & b_zero;
      end

      if (done_q) begin
        if (s1_nan)                        y <= {1'b0, 11'h7ff, 1'b1, 51'd0};
        else if (s1_inf)                   y <= {s1_sign, 11'h7ff, 52'd0};
        else if (s1_zero)                  y <= {s1_sign & s_small_q, 63'd0};
        else if (s1_sum == 57'd0)          y <= 64'd0;   // exact cancellation
        else if (res_exp_s >= 13'sd2047)   y <= {s1_sign, 11'h7ff, 52'd0};
        else if (res_exp_s <= 13'sd0)      y <= {s1_sign, 63'd0};
        else                               y <= {s1_sign, res_exp_s[10:0], res_man};
        done <= 1'b1;
      end
    end
  end

  // Sign of a both-zero result, latched with the rest of stage 1.
  logic s_small_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) s_small_q <= 1'b0; else if (req) s_small_q <= s_small;

  // ------------------------------------------- normalise and round

  // Leading-zero count as an unconditional overwrite loop: yosys rejects
  // `break` inside a synthesis loop, which is Model 1's rule.
  // The shift needed to place the leading one at bit 55, which is where the
  // hidden bit belongs given the mantissa is taken from [54:3]. Bit 56 is the
  // carry-out case and is handled separately, so the loop stops at 55.
  logic [5:0] lz;
  always_comb begin
    lz = 6'd55;
    for (int i = 0; i < 56; i++)
      if (s1_sum[i]) lz = 6'(55 - i);
  end

  // norm[56:55] are 1 and 0 by construction after normalising — the loop above
  // places the leading one at bit 55 — so the mantissa is taken from [54:3].
  /* verilator lint_off UNUSEDSIGNAL */
  logic [56:0]        norm;
  /* verilator lint_on UNUSEDSIGNAL */
  logic signed [12:0] exp_n;
  always_comb begin
    if (s1_sum[56]) begin                       // addition carried out
      // The right shift would drop bit 0, which is the sticky position — so
      // the sticky must be OR'd back in rather than shifted away. Losing it
      // turns "slightly more than half an ulp" into an exact tie, which rounds
      // to even instead of up and lands the result one ulp low. That was a
      // one-in-90,000 failure and it only showed up on the carry path.
      norm     = s1_sum >> 1;
      norm[0]  = s1_sum[1] | s1_sum[0];
      exp_n = $signed({2'b0, s1_exp}) + 13'sd1;
    end else begin
      norm  = s1_sum << lz;
      exp_n = $signed({2'b0, s1_exp}) - $signed({7'd0, lz});
    end
  end

  logic [51:0] man_t;
  logic        guard, sticky, round_up;
  assign man_t    = norm[54:3];
  assign guard    = norm[2];
  assign sticky   = |norm[1:0];
  assign round_up = guard & (sticky | man_t[0]);

  logic [52:0]        man_r;
  logic [51:0]        res_man;
  logic signed [12:0] res_exp_s;
  assign man_r     = {1'b0, man_t} + {52'd0, round_up};
  // A rounding carry into bit 52 means the mantissa became exactly 2.0, so the
  // result is exponent+1 with a ZERO mantissa — not the mantissa shifted right.
  // man_r is exactly 2^52 in that case, so the low 52 bits are already zero and
  // one expression covers both paths.
  assign res_man   = man_r[51:0];
  assign res_exp_s = man_r[52] ? (exp_n + 13'sd1) : exp_n;

endmodule
