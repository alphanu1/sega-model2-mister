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
// IEEE-754 double-precision square root — the i960 FPU's sqrtr and sqrtrl.
//
// BIT-EXACT BY SPECIFICATION, NOT BY IMITATION. IEEE-754 requires square root
// to be correctly rounded, so there is exactly one right answer for every
// input and any correct implementation produces it. That makes this one of the
// few FPU operations where matching the reference's libm is guaranteed rather
// than approximated — libm's sqrt is the correctly-rounded result too, usually
// the hardware instruction.
//
// Digit-by-digit (restoring) square root, one result bit per cycle. The
// reference charges 104 cycles for sqrtr, so 56 cycles is inside budget and no
// DSP is spent — which after M2-E's DSP finding is the currency worth saving.
//
// The recurrence: at each step the partial root q has been found and the
// partial remainder is rem. Trying the next bit means testing
//     rem >= (q << 1 | 1)
// and if so subtracting it, which is the standard shift-and-subtract form with
// no multiplier anywhere.

module i960_fpsqrt (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        req,
  input  logic [63:0] a,
  output logic [63:0] y,
  output logic        busy,
  output logic        done
);

  logic        sa;
  logic [10:0] ea;
  logic [51:0] ma;
  assign sa = a[63];
  assign ea = a[62:52];
  assign ma = a[51:0];

  logic a_zero, a_inf, a_nan, a_neg;
  assign a_zero = (ea == 11'd0)   && (ma == 52'd0);
  assign a_inf  = (ea == 11'h7ff) && (ma == 52'd0);
  assign a_nan  = (ea == 11'h7ff) && (ma != 52'd0);
  assign a_neg  = sa && !a_zero;          // sqrt(-0) is -0, not NaN

  logic [52:0] fa;
  assign fa = (ea == 11'd0) ? 53'd0 : {1'b1, ma};

  typedef enum logic [1:0] { S_IDLE, S_ITER, S_FIN } state_e;
  state_e state;
  assign busy = (state != S_IDLE);

  // The radicand is held in a wide register and consumed two bits per step,
  // which is what makes the root advance one bit per step.
  logic [111:0] radicand;
  logic [55:0]  root;
  logic [58:0]  rem;
  logic [5:0]   cnt;
  logic         r_nan, r_inf, r_zero, r_negzero;
  logic signed [12:0] exp_r;

  // Square root consumes TWO radicand bits per step and shifts the remainder by
  // two — unlike division, which takes one. The trial subtrahend is 4*root + 1,
  // not 2*root + 1. Getting that wrong produces roots wrong by a non-obvious
  // factor rather than a clean binade, which is what made the first version's
  // failures hard to read.
  logic [58:0] rem_sh;
  logic [58:0] trial;
  assign rem_sh = {rem[56:0], radicand[111:110]};
  assign trial  = {1'b0, root, 2'b01};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE; done <= 1'b0; y <= 64'd0;
      radicand <= 112'd0; root <= 56'd0; rem <= 59'd0; cnt <= 6'd0;
      r_nan <= 1'b0; r_inf <= 1'b0; r_zero <= 1'b0; r_negzero <= 1'b0;
      exp_r <= 13'sd0;
    end else begin
      done <= 1'b0;

      case (state)
        S_IDLE: if (req) begin
          r_nan     <= a_nan | a_neg;             // sqrt of a negative is NaN
          r_inf     <= a_inf & ~sa;
          r_zero    <= a_zero;
          r_negzero <= a_zero & sa;               // sqrt(-0) == -0

          // The bias is 1023, which is ODD — so an odd biased exponent means
          // an EVEN unbiased one. Getting that backwards inverts both branches
          // and every result comes out wrong by a factor of sqrt(2), which is
          // what the first version did.
          //
          // Alignment: the root must land with its leading one at bit 55, so
          // the radicand needs fa << 58 for an even exponent and fa << 59 for
          // an odd one, consumed two bits per step over 56 steps.
          if (ea[0]) begin                                   // unbiased EVEN
            radicand <= {1'b0, fa, 58'd0};
            exp_r    <= ($signed({2'b0, ea}) - 13'sd1023) >>> 1;
          end else begin                                     // unbiased ODD
            radicand <= {fa, 59'd0};
            exp_r    <= ($signed({2'b0, ea}) - 13'sd1023 - 13'sd1) >>> 1;
          end
          root  <= 56'd0;
          rem   <= 59'd0;
          cnt   <= 6'd0;
          state <= S_ITER;
        end

        S_ITER: begin
          if (rem_sh >= trial) begin
            rem  <= rem_sh - trial;
            root <= {root[54:0], 1'b1};
          end else begin
            rem  <= rem_sh;
            root <= {root[54:0], 1'b0};
          end
          radicand <= {radicand[109:0], 2'b00};
          if (cnt == 6'd55) state <= S_FIN;
          else              cnt   <= cnt + 6'd1;
        end

        S_FIN: begin
          if (r_nan)         y <= {1'b0, 11'h7ff, 1'b1, 51'd0};
          else if (r_inf)    y <= {1'b0, 11'h7ff, 52'd0};
          else if (r_zero)   y <= {r_negzero, 63'd0};
          else               y <= {1'b0, res_exp[10:0], res_man};
          done  <= 1'b1;
          state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  // ------------------------------------------- normalise and round
  //
  // The root of a value in [1,4) is in [1,2), so the leading one is already at
  // bit 55 and no normalising shift is needed.

  logic [51:0] man_t;
  logic        guard, sticky, round_up;
  assign man_t    = root[54:3];
  assign guard    = root[2];
  assign sticky   = |root[1:0] | (rem != 59'd0);
  assign round_up = guard & (sticky | man_t[0]);

  // sqrt halves the exponent range, so overflow and underflow are impossible
  // for any finite normal input and res_exp[12:11] carry no information.
  logic [52:0]        man_r;
  logic [51:0]        res_man;
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [12:0] res_exp;
  /* verilator lint_on UNUSEDSIGNAL */
  assign man_r   = {1'b0, man_t} + {52'd0, round_up};
  assign res_man = man_r[51:0];
  assign res_exp = (man_r[52] ? (exp_r + 13'sd1) : exp_r) + 13'sd1023;

endmodule
