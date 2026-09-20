// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The reciprocal the perspective divide needs: q ~= 2^30 / d, two cycles.
//
// WHY NOT m2_raster_div. That unit is a restoring divider with a table fast
// path for denominators under 256, and its denominators are edge heights in
// scanlines. Here d is a normalised 1/z running to 32767, which takes its slow
// path -- a divide per PIXSTEP group at that rate would cost more cycles than
// the span has pixels.
//
// WHY NOT A BIGGER TABLE. 2^30/d for every 15-bit d is 32K entries. Normalising
// d first means the table only ever sees the top eight bits of a value already
// in [2^15, 2^16), so 128 entries answer every input, and ONE Newton step takes
// the 0.4% table error down to about sixteen bits -- which is what R331
// measured 1/z needs. Two 16x16 multiplies against a 32K-entry ROM this part
// does not have.
//
//   r0 ~= 2^23 / dn[15:8]          table, 128 x 16
//   r1  = r0 + r0*(2^16 - dn*r0 >> 16) >> 16      one Newton step
//   q   = r1 << s                  undo the normalise
`timescale 1ns/1ps

module m2_persp_recip (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [15:0] in_d,        // 1..65535; zero returns the maximum
  output logic [31:0] out_q        // ~= 2^30 / in_d, valid two cycles later
);

  // ---- stage 0: normalise, and look the leading byte up
  function automatic logic [3:0] clz16(input logic [15:0] v);
    int i;
    begin
      // LOW TO HIGH, so the LAST assignment is the HIGHEST set bit. Written
      // the other way round the last assignment is the lowest set bit, which
      // is right only for powers of two -- and every power of two passed.
      clz16 = 4'd15;                       // v == 0 is trapped by the caller
      for (i = 0; i < 16; i = i + 1) if (v[i]) clz16 = 4'(15 - i);
    end
  endfunction

  // ceil(2^23 / idx) for idx in [128, 255].
  //
  // SEVENTEEN BITS, AND THE REASON IS NOT PRECISION IN GENERAL. idx == 128 is
  // exactly 65536, one past a 16-bit field. Clamping it to 65535 made the
  // Newton step converge on 65535 too, so out_q was ALWAYS at or below the true
  // reciprocal -- a signed bias, not noise. u = u/z * out_q then lands just
  // under every exact texel boundary and takes the texel BELOW: every fetch in
  // tb_m2_span_tex came back one short, uniformly. A rounding error that always
  // has the same sign is a different kind of bug from one that does not.
  // R444: WRITTEN IN m2_recip_rom's IDIOM, BECAUSE MINE DID NOT SURVIVE
  // SYNTHESIS. As a headless `initial for` doing 32-bit arithmetic, Quartus
  // dropped the contents entirely:
  //
  //   Info (276004): RAM logic "...|m2_persp_recip:u_denr|rtab" is uninferred
  //                  due to inappropriate RAM size
  //   Warning (10030): Net "rtab.data_a" has no driver or initial value,
  //                    using a default initial value '0'
  //
  // A table of zeros makes every reciprocal zero, every gradient zero, and the
  // board dead -- while Verilator, which executes initial blocks, passed
  // 152,369 checks. m2_recip_rom has been in this design for months doing the
  // same job, and the differences are explicit begin/end and longint' casts.
  // Copy what is known to synthesise rather than what is known to simulate.
  (* romstyle = "logic" *) logic [16:0] rtab [128];
  initial begin
    for (int i = 128; i < 256; i++) begin
      rtab[i-128] = 17'(((longint'(1) << 23) + longint'(i) - longint'(1)) / longint'(i));
    end
  end

  wire [3:0]  s0_s  = clz16(in_d);
  wire [15:0] s0_dn = in_d << s0_s;        // [2^15, 2^16), or 0 when in_d == 0

  logic [15:0] s1_dn;
  logic [16:0] s1_r0;
  logic [3:0]  s1_s;
  logic        s1_zero;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1_dn <= 16'd0; s1_r0 <= 17'd0; s1_s <= 4'd0; s1_zero <= 1'b0;
      out_q <= 32'd0;
    end else begin
      s1_dn   <= s0_dn;
      s1_s    <= s0_s;
      s1_zero <= (in_d == 16'd0);
      s1_r0   <= rtab[s0_dn[14:8]];        // top byte less its always-set bit

      // ---- stage 1: one Newton step, then undo the normalise.
      //
      // r1 = R0 * (2 - dn*R0) with R0 = r0 / 2^31. dn*r0 lands in Q15, not
      // Q16 -- getting that wrong makes `e` a number near 2^15 instead of a
      // correction near 2^16, and the answer is off by millions rather than
      // parts per million. Written out:
      //
      //   p  = dn * r0 >> 15      ~= 2^16, which is dn*R0 in Q16
      //   e  = 2^17 - p           ~= 2^16, which is (2 - dn*R0) in Q16
      //   r1 = r0 * e >> 16       ~= 2^31 / dn
      out_q <= s1_zero ? 32'hffff_ffff : persp_q(s1_dn, s1_r0, s1_s);
    end
  end

  function automatic logic [31:0] persp_q(input logic [15:0] dn,
                                          input logic [16:0] r0,
                                          input logic [3:0]  s);
    logic [17:0] p;
    logic [17:0] e;
    logic [35:0] c;
    logic [18:0] r1;
    logic [32:0] q;
    begin
      p  = 18'((33'(dn) * 33'(r0)) >> 15);
      e  = 18'h20000 - p;
      c  = 36'(r0) * 36'(e);
      r1 = 19'(c >> 16);
      // r1 ~= 2^31/dn and dn == d << s, so 2^30/d == r1 << s >> 1. The +1
      // rounds that last shift instead of always truncating downwards.
      q  = (33'(r1) << s) + 33'd1;
      persp_q = 32'(q >> 1);
    end
  endfunction
endmodule
