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
// Same deviations as the adder and multiplier: subnormals flushed, overflow to
// infinity, underflow to zero, round-to-nearest-even only.

module i960_fpdiv (
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

  logic [52:0] fa, fb;
  assign fa = (ea == 11'd0) ? 53'd0 : {1'b1, ma};
  assign fb = (eb == 11'd0) ? 53'd0 : {1'b1, mb};

  typedef enum logic [1:0] { S_IDLE, S_DIV, S_FIN } state_e;
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
  assign rem_sub = rem - {1'b0, dsr};

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
          exp_q  <= $signed({2'b0, ea}) - $signed({2'b0, eb}) + 13'sd1023;
          rem    <= {1'b0, fa};
          dsr    <= fb;
          quot   <= 56'd0;
          cnt    <= 6'd0;
          state  <= S_DIV;
        end

        S_DIV: begin
          // One restoring step per cycle. 56 bits gives the 53-bit mantissa
          // plus guard and round, with the final remainder as sticky.
          if (rem >= {1'b0, dsr}) begin
            rem  <= {rem_sub[52:0], 1'b0};
            quot <= {quot[54:0], 1'b1};
          end else begin
            rem  <= {rem[52:0], 1'b0};
            quot <= {quot[54:0], 1'b0};
          end
          if (cnt == 6'd55) state <= S_FIN;
          else              cnt   <= cnt + 6'd1;
        end

        S_FIN: begin
          if (r_nan)                      y <= {1'b0, 11'h7ff, 1'b1, 51'd0};
          else if (r_inf)                 y <= {sgn, 11'h7ff, 52'd0};
          else if (r_zero)                y <= {sgn, 63'd0};
          else if (res_exp >= 13'sd2047)  y <= {sgn, 11'h7ff, 52'd0};
          else if (res_exp <= 13'sd0)     y <= {sgn, 63'd0};
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

  logic [51:0] man_t;
  logic        guard, sticky, round_up;
  assign man_t    = qn[54:3];
  assign guard    = qn[2];
  // Everything below the guard bit, plus a non-zero final remainder — the
  // division is not exact when rem != 0 and that must reach the round decision.
  assign sticky   = |qn[1:0] | (rem != 54'd0);
  assign round_up = guard & (sticky | man_t[0]);

  logic [52:0]        man_r;
  logic [51:0]        res_man;
  logic signed [12:0] res_exp;
  assign man_r   = {1'b0, man_t} + {52'd0, round_up};
  assign res_man = man_r[51:0];
  assign res_exp = man_r[52] ? (en + 13'sd1) : en;

endmodule
