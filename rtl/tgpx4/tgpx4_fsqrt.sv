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
// IEEE single square root, round to nearest even, one result bit a clock
// (25 iterations + 2). For the TGPx4's FRSQ, which MAME computes as
// 1.0F / sqrtf(f): sqrtf is correctly rounded, so this followed by fp_div's
// correctly rounded 1/x gives MAME's bits for normal inputs.
//
// NOT HERE: subnormal inputs (taken as zero, as fp_div takes them), and the
// sign of the NaN for a negative input (x86 SSE returns 0xffc00000; this
// returns that too, but nothing has compared it).

`timescale 1ns/1ps

module tgpx4_fsqrt (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        in_valid,     // accepted when !busy
  input  logic [31:0] a,
  output logic        busy,
  output logic        out_valid,
  output logic [31:0] result
);

  logic        sa;
  logic [7:0]  ea;
  logic [22:0] ma;
  assign sa = a[31];
  assign ea = a[30:23];
  assign ma = a[22:0];

  logic        run;
  logic [4:0]  cnt;
  logic [49:0] x;
  logic [27:0] rem;
  logic [24:0] root;
  logic [7:0]  re;
  logic        special;
  logic [31:0] spec_val;

  logic [27:0] rem_sh, trial;
  assign rem_sh = {rem[25:0], x[49:48]};
  assign trial  = {1'b0, root, 2'b01};

  assign busy = run;

  // round: root[24] is the integer bit, root[23:1] the mantissa, root[0] guard
  logic        sticky, rnd_up;
  logic [23:0] rmant;
  assign sticky = (rem != 28'd0);
  assign rnd_up = root[0] & (sticky | root[1]);
  assign rmant  = {1'b0, root[23:1]} + {23'd0, rnd_up};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      run       <= 1'b0;
      out_valid <= 1'b0;
      result    <= 32'd0;
      cnt       <= 5'd0;
      x         <= 50'd0;
      rem       <= 28'd0;
      root      <= 25'd0;
      re        <= 8'd0;
      special   <= 1'b0;
      spec_val  <= 32'd0;
    end else begin
      out_valid <= 1'b0;
      if (!run) begin
        if (in_valid) begin
          run     <= 1'b1;
          cnt     <= 5'd25;
          rem     <= 28'd0;
          root    <= 25'd0;
          special <= 1'b1;
          if (ea == 8'd0)                       spec_val <= {sa, 31'd0};        // +-0 (and subnormals)
          else if (ea == 8'hff && ma != 23'd0)  spec_val <= a | 32'h00400000;   // NaN, quieted
          else if (sa)                          spec_val <= 32'hffc00000;       // negative
          else if (ea == 8'hff)                 spec_val <= a;                  // +inf
          else                                  special  <= 1'b0;
          // exponent parity: odd unbiased exponent (even biased) doubles the radicand
          if (ea[0]) begin
            x  <= {1'b0, 1'b1, ma, 25'd0};        // sig << 25: radicand in [1,2)
            re <= {1'b0, ea[7:1]} + 8'd64;        // (e - 127) / 2 + 127
          end else begin
            x  <= {1'b1, ma, 26'd0};              // sig << 26: radicand in [2,4)
            re <= {1'b0, ea[7:1]} + 8'd63;
          end
        end
      end else if (cnt != 5'd0) begin
        cnt <= cnt - 5'd1;
        x   <= {x[47:0], 2'b00};
        if (rem_sh >= trial) begin
          rem  <= rem_sh - trial;
          root <= {root[23:0], 1'b1};
        end else begin
          rem  <= rem_sh;
          root <= {root[23:0], 1'b0};
        end
      end else begin
        run       <= 1'b0;
        out_valid <= 1'b1;
        if (special) result <= spec_val;
        else         result <= {1'b0, re + {7'd0, rmant[23]}, rmant[22:0]};
      end
    end
  end

endmodule
