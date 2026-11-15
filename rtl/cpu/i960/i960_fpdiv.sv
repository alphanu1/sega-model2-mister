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
// IEEE-754 double-precision divider — the i960 FPU's divr and divrl.
//
// Restoring division, one quotient bit per cycle, 56 bits. That is slow and it
// does not matter: the reference charges 35 cycles for divr and 77 for divrl,
// so a 56-cycle divide is inside the budget the timing model already assumes.
// A faster radix-4 or Newton-Raphson unit would cost DSP blocks, and M2-E
// showed a comparable renderer already wanting 61 of the 112.
//
// Overflow goes to infinity; round-to-nearest-even only.
//
// R1013: SUBNORMALS, as the 80960KB has them in normalizing mode with the
// underflow mask set (PRM §12). SUBNORM 1:
//   * A subnormal operand (no hidden bit, effective exponent 1) is
//     normalised in S_NORM before the divide, one bit a cycle for each
//     operand at once, the exponent adjusted as it goes: max(lz) + 1 cycles,
//     only when an operand is subnormal. Normal operands go straight to S_DIV
//     as before, the same 58 cycles.
//   * A quotient below 2^-1022 is produced at its denormalised alignment:
//     with exp_q <= 0 the divide stops 1 - exp_q steps early, so the LSB that
//     comes out is the subnormal's, and the remainder is the sticky as usual
//     (fewer cycles, not more). exp_q = 1 with the first quotient bit clear is
//     subnormal at the full length. Either way the exponent field is 0, and a
//     rounding carry makes the result 2^-1022.
// SUBNORM 0 is the flush this unit had before.

module i960_fpdiv #(
  parameter bit SUBNORM = 1'b1
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        req,
  input  logic [63:0] a,             // dividend
  input  logic [63:0] b,             // divisor
  output logic [63:0] y,
  output logic        busy,
  output logic        done
);

  logic        sa, sb;
  logic [10:0] ea, eb;
  logic [51:0] ma, mb;
  assign sa = a[63];
  assign ea = a[62:52];
  assign ma = a[51:0];
  assign sb = b[63];
  assign eb = b[62:52];
  assign mb = b[51:0];

  logic a_zero, b_zero, a_inf, b_inf, a_nan, b_nan;
  assign a_zero = (ea == 11'd0)   && (ma == 52'd0);
  assign b_zero = (eb == 11'd0)   && (mb == 52'd0);
  assign a_inf  = (ea == 11'h7ff) && (ma == 52'd0);
  assign b_inf  = (eb == 11'h7ff) && (mb == 52'd0);
  assign a_nan  = (ea == 11'h7ff) && (ma != 52'd0);
  assign b_nan  = (eb == 11'h7ff) && (mb != 52'd0);

  logic a_sub, b_sub;
  assign a_sub = (ea == 11'd0) && (ma != 52'd0);
  assign b_sub = (eb == 11'd0) && (mb != 52'd0);

  logic [52:0] fa, fb;
  assign fa = (ea == 11'd0) ? (SUBNORM ? {1'b0, ma} : 53'd0) : {1'b1, ma};
  assign fb = (eb == 11'd0) ? (SUBNORM ? {1'b0, mb} : 53'd0) : {1'b1, mb};

  // A subnormal's effective exponent is 1 (SUBNORM 1).
  logic [10:0] ea_e, eb_e;
  assign ea_e = (SUBNORM && a_sub) ? 11'd1 : ea;
  assign eb_e = (SUBNORM && b_sub) ? 11'd1 : eb;

  // The result is a special (NaN, infinity, zero): the divide's value is not
  // used, so a subnormal operand is not normalised either.
  logic sp_any;
  assign sp_any = a_nan | b_nan | a_inf | b_inf | a_zero | b_zero;

  typedef enum logic [1:0] { S_IDLE, S_DIV, S_FIN, S_NORM } state_e;
  state_e state;
  assign busy = (state != S_IDLE);

  logic [53:0] rem;
  logic [55:0] quot;
  logic [52:0] dsr;
  logic [5:0]  cnt;
  logic        sgn, r_nan, r_inf, r_zero;
  logic signed [12:0] exp_q;

  // Compare BEFORE shifting. Shifting first computes 2*fa/fb and every result
  // comes out exactly one binade too large — which is what the first version
  // did, uniformly, on every input.
  // rem_sub[53] is zero whenever the subtraction is taken, because the branch
  // is guarded by rem >= dsr.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [53:0] rem_sub;
  /* verilator lint_on UNUSEDSIGNAL */
  // R952: the compare is the same subtract's borrow (one 55-bit carry chain,
  // where rem >= dsr built a second): rem_ge is rem >= {0, dsr} exactly.
  logic [54:0] rem_d;
  logic        rem_ge;
  assign rem_d   = {1'b0, rem} - {2'b0, dsr};
  assign rem_ge  = !rem_d[54];
  assign rem_sub = rem_d[53:0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE; done <= 1'b0; y <= 64'd0;
      rem <= 54'd0; quot <= 56'd0; dsr <= 53'd0; cnt <= 6'd0;
      sgn <= 1'b0; r_nan <= 1'b0; r_inf <= 1'b0; r_zero <= 1'b0;
      exp_q <= 13'sd0;
    end else begin
      done <= 1'b0;

      case (state)
        S_IDLE: if (req) begin
          sgn <= sa ^ sb;
          // 0/0 and inf/inf are NaN; x/0 is infinity; 0/x and x/inf are zero.
          r_nan  <= a_nan | b_nan | (a_zero & b_zero) | (a_inf & b_inf);
          r_inf  <= (a_inf & ~b_inf & ~b_nan) | (b_zero & ~a_zero & ~a_nan);
          r_zero <= (a_zero & ~b_zero & ~b_nan) | (b_inf & ~a_inf & ~a_nan);
          exp_q  <= $signed({2'b0, ea_e}) - $signed({2'b0, eb_e}) + 13'sd1023;
          rem    <= {1'b0, fa};
          dsr    <= fb;
          quot   <= 56'd0;
          cnt    <= 6'd0;
          state  <= (SUBNORM && (a_sub || b_sub) && !sp_any) ? S_NORM : S_DIV;
        end

        // R1013: normalise a subnormal dividend and / or divisor, one bit a
        // cycle each. A dividend shifted up is a smaller exponent, a divisor
        // shifted up a larger quotient exponent.
        S_NORM: begin
          if (!rem[52]) rem <= {rem[52:0], 1'b0};
          if (!dsr[52]) dsr <= {dsr[51:0], 1'b0};
          exp_q <= exp_q - (rem[52] ? 13'sd0 : 13'sd1) + (dsr[52] ? 13'sd0 : 13'sd1);
          if (rem[52] && dsr[52]) state <= S_DIV;
        end

        S_DIV: begin
          // One restoring step per cycle. 56 bits gives the 53-bit mantissa
          // plus guard and round, with the final remainder as sticky.
          if (rem_ge) begin                         // R952: rem >= {0, dsr}
            rem  <= {rem_sub[52:0], 1'b0};
            quot <= {quot[54:0], 1'b1};
          end else begin
            rem  <= {rem[52:0], 1'b0};
            quot <= {quot[54:0], 1'b0};
          end
          // R1013: a quotient below 2^-1022 (exp_q <= 0) needs 1 - exp_q
          // fewer steps: decided at the first, from the settled exp_q. With
          // d = 1 - exp_q, the steps are 56 - d: the first now, then cnt
          // from d + 1 to 55. d >= 55 leaves only this one, which lands in the
          // sticky (such a quotient is under half the smallest subnormal).
          // Not for a special result (0 / x, x / inf, ...): its steps are not
          // used, and it keeps the 58 cycles it always took.
          if (cnt == 6'd55) state <= S_FIN;
          else if (SUBNORM && (cnt == 6'd0) && (exp_q <= 13'sd0) && !(r_nan | r_inf | r_zero)) begin
            if (exp_q <= -13'sd54) state <= S_FIN;
            else                   cnt   <= 6'(13'sd2 - exp_q);
          end
          else              cnt   <= cnt + 6'd1;
        end

        S_FIN: begin
          if (r_nan)                      y <= {1'b0, 11'h7ff, 1'b1, 51'd0};
          else if (r_inf)                 y <= {sgn, 11'h7ff, 52'd0};
          else if (r_zero)                y <= {sgn, 63'd0};
          else if (res_exp >= 13'sd2047)  y <= {sgn, 11'h7ff, 52'd0};
          else if (res_exp <= 13'sd0 && !SUBNORM) y <= {sgn, 63'd0};   // flushed
          else                            y <= {sgn, res_exp[10:0], res_man};
          done  <= 1'b1;
          state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  // ------------------------------------------- normalise and round
  //
  // fa/fb lies in (0.5, 2), so the quotient's leading one is at bit 55 or 54
  // and at most one left shift is needed.

  // qn[55] is 1 by construction after the shift — the quotient's leading one is
  // placed there — so the mantissa comes from [54:3].
  /* verilator lint_off UNUSEDSIGNAL */
  logic [55:0]        qn;
  /* verilator lint_on UNUSEDSIGNAL */
  logic signed [12:0] en;
  assign qn = quot[55] ? quot : {quot[54:0], 1'b0};
  assign en = quot[55] ? exp_q : (exp_q - 13'sd1);

  // R1013: subnormal -- the quotient as it stands (already at its
  // denormalised alignment when exp_q <= 0; exp_q = 1 with quot[55] clear
  // needs no 1-bit normalise), exponent field 0.
  logic        is_sub;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [55:0] qf;                     // [55] is the hidden bit, not stored
  /* verilator lint_on UNUSEDSIGNAL */
  assign is_sub = SUBNORM && ((exp_q <= 13'sd0) || ((exp_q == 13'sd1) && !quot[55]));
  assign qf     = is_sub ? quot : qn;

  logic [51:0] man_t;
  logic        guard, sticky, round_up;
  assign man_t    = qf[54:3];
  assign guard    = qf[2];
  // Everything below the guard bit, plus a non-zero final remainder — the
  // division is not exact when rem != 0 and that must reach the round decision.
  assign sticky   = |qf[1:0] | (rem != 54'd0);
  assign round_up = guard & (sticky | man_t[0]);

  logic [52:0]        man_r;
  logic [51:0]        res_man;
  logic signed [12:0] res_exp, exp_f;
  assign exp_f   = is_sub ? 13'sd0 : en;
  assign man_r   = {1'b0, man_t} + {52'd0, round_up};
  assign res_man = man_r[51:0];
  assign res_exp = man_r[52] ? (exp_f + 13'sd1) : exp_f;

endmodule
