// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// THE OSD VOLUME OF THE 2A BUILD (study R829, R894): one gain on both
// channels, after the sound board. Codes 0-10 are R829's 80, 90, 100, 0,
// 10 .. 70 %; R894 adds 150, 200, 300 and 400 % in codes 11-14 (15 reads as
// the default, 80 %). The gain is the percentage of 256; the product's
// [23:8] is the output, CLAMPED to the 16-bit range above 100 %, never
// wrapped. At 100 % and below the clamp cannot act, so codes 0-10 give R829's
// 9-bit stage's output bit for bit (tb_m2_volume checks every input at every
// code). One register, as before.

`timescale 1ns/1ps

module m2_volume (
  input  logic               clk,
  input  logic        [3:0]  code,        // the OSD's status[49:46], already in clk's domain
  input  logic signed [15:0] in_l, in_r,
  output logic signed [15:0] out_l, out_r
);
  logic [10:0] gain;
  always_comb begin
    case (code)
      4'd0:    gain = 11'd205;    // 80%
      4'd1:    gain = 11'd230;    // 90%
      4'd2:    gain = 11'd256;    // 100%
      4'd3:    gain = 11'd0;      // 0%
      4'd4:    gain = 11'd26;     // 10%
      4'd5:    gain = 11'd51;     // 20%
      4'd6:    gain = 11'd77;     // 30%
      4'd7:    gain = 11'd102;    // 40%
      4'd8:    gain = 11'd128;    // 50%
      4'd9:    gain = 11'd154;    // 60%
      4'd10:   gain = 11'd179;    // 70%
      4'd11:   gain = 11'd384;    // 150%
      4'd12:   gain = 11'd512;    // 200%
      4'd13:   gain = 11'd768;    // 300%
      4'd14:   gain = 11'd1024;   // 400%
      default: gain = 11'd205;
    endcase
  end

  (* multstyle = "dsp" *) wire signed [27:0] pl = in_l * $signed({1'b0, gain});
  (* multstyle = "dsp" *) wire signed [27:0] pr = in_r * $signed({1'b0, gain});

  // p[27:8] is the gained sample (|p| <= 2^15 x 2^10): in range when p[27:23] is all sign
  function automatic logic signed [15:0] sat(input logic signed [27:0] p);
    if (p[27:23] != {5{p[27]}}) sat = p[27] ? 16'sh8000 : 16'sh7fff;
    else                        sat = p[23:8];
  endfunction

  always_ff @(posedge clk) begin
    out_l <= sat(pl);
    out_r <= sat(pr);
  end
endmodule
