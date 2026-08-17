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

module i960_fpmul (
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

  // Hidden bit. Subnormals are flushed rather than handled: the reference runs
  // on a host that does support them, so a program that produces one WILL
  // diverge. Recorded rather than hidden — see the spike document.
  logic [52:0] fa, fb;
  assign fa = a_sub ? 53'd0 : {1'b1, ma};
  assign fb = b_sub ? 53'd0 : {1'b1, mb};

  logic signed [12:0] exp_sum;
  assign exp_sum = $signed({2'b0, ea}) + $signed({2'b0, eb}) - 13'sd1023;

  // ----------------------------------------------------------- stage 1

  logic               done_pipe;
  logic [51:0]        res_man;
  logic signed [12:0] res_exp;

  logic [105:0]       p1;
  logic signed [12:0] e1;
  logic               s1, sp_zero, sp_inf, sp_nan;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p1 <= 106'd0; e1 <= 13'sd0; s1 <= 1'b0;
      sp_zero <= 1'b0; sp_inf <= 1'b0; sp_nan <= 1'b0;
      done <= 1'b0; y <= 64'd0;
    end else begin
      done <= 1'b0;

      if (req) begin
        p1 <= fa * fb;                       // 53x53 -> DSP blocks
        e1 <= exp_sum;
        s1 <= sa ^ sb;
        // Special cases decided here so the rounding path never sees them.
        sp_nan  <= a_nan | b_nan | (a_inf & b_zero) | (a_zero & b_inf);
        sp_inf  <= (a_inf | b_inf) & ~(a_zero | b_zero);
        sp_zero <= (a_zero | b_zero) & ~(a_inf | b_inf);
      end

      // ------------------------------------------------------- stage 2
      if (done_pipe) begin
        if (sp_nan)       y <= {1'b0, 11'h7ff, 1'b1, 51'd0};   // quiet NaN
        else if (sp_inf)  y <= {s1, 11'h7ff, 52'd0};
        else if (sp_zero) y <= {s1, 63'd0};
        // Exponent overflow becomes infinity; underflow becomes zero, because
        // subnormals are flushed. Both are visible to lockstep against a host
        // that implements them properly, so both are recorded as deviations
        // rather than treated as edge cases that will not come up.
        else if (res_exp >= 13'sd2047) y <= {s1, 11'h7ff, 52'd0};
        else if (res_exp <= 13'sd0)    y <= {s1, 63'd0};
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

  // After normalising, the top bit is 1 by construction — the product of two
  // values in [1,2) lies in [1,4), so one right shift at most.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [105:0]       pn;
  /* verilator lint_on UNUSEDSIGNAL */
  logic signed [12:0] en;
  assign pn = p1[105] ? p1 : {p1[104:0], 1'b0};
  assign en = p1[105] ? (e1 + 13'sd1) : e1;

  logic [51:0] man_trunc;
  logic        guard, sticky, round_up;
  assign man_trunc = pn[104:53];
  assign guard     = pn[52];
  assign sticky    = |pn[51:0];
  assign round_up  = guard & (sticky | man_trunc[0]);

  logic [52:0]        man_rnd;
  logic signed [12:0] exp_rnd;
  assign man_rnd = {1'b0, man_trunc} + {52'd0, round_up};
  assign exp_rnd = man_rnd[52] ? (en + 13'sd1) : en;

  assign res_man = man_rnd[52] ? man_rnd[52:1] : man_rnd[51:0];
  assign res_exp = exp_rnd;

endmodule
