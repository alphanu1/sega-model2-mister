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
// MB86235 conversions AND shifts on ONE 32-bit right barrel shifter, MAME
// 0.289 decode_aluop 0x0d-0x0f and 0x1c-0x1f. Six clocks (R924, below). A left shift is the right shift of the bit-reversed
// value, reversed back -- two 32-bit 2:1 muxes instead of a second shifter.
// The core runs one ALU op at a time, so nothing else wants the shifter.
//
//   0x0d CIF   int32 -> float, round to nearest even (float(int))
//   0x0e CFI   float -> int32, toward zero (int(f)); out of range and NaN
//              give 0x80000000, as x86's cvttss2si does for MAME
//   0x0f CFIB  float -> 0..255: negative -> 0 and AU, above 255 -> 255 and
//              AV; AZ on a zero result
//   0x1c LSR, 0x1d LSL, 0x1e ASR, 0x1f ASL by a 5-bit immediate
//
// Flags out are AN / AZ / AU / AV for the caller to merge.

`timescale 1ns/1ps

module tgpx4_cvt (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        in_valid,
  input  logic [4:0]  op,         // the ALU opcode
  input  logic [4:0]  sh,         // shift count (the ALU's second-source field)
  input  logic [31:0] a,
  output logic        out_valid,
  output logic [31:0] result,
  output logic        f_an,
  output logic        f_az,
  output logic        f_au,
  output logic        f_av
);

  logic        v1;
  logic [4:0]  op1, sh1;
  logic [31:0] a1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v1 <= 1'b0; op1 <= 5'd0; sh1 <= 5'd0; a1 <= 32'd0;
    end else begin
      v1 <= in_valid;
      if (in_valid) begin op1 <= op; sh1 <= sh; a1 <= a; end
    end
  end

  function automatic logic [31:0] rev32(input logic [31:0] x);
    for (int i = 0; i < 32; i++) rev32[i] = x[31 - i];
  endfunction

  // R924: PIPELINED, SIX CLOCKS IN TO OUT (was two). The first fit of the 2C
  // build (s1303, 80 MHz) missed clk_sys by -3.9 to -4.2 ns, its worst 200
  // paths all a1 -> f_az through one clock of negate, leading-zero count,
  // shift, round and compare. Now one of those a clock:
  //   s1 operands   s2 |a|   s3 leading zeros, the shifter's inputs
  //   s4 the shift  s5 round / negate / clamp   s6 the flags, the result
  // A shift (LSR / LSL, ~5% of House of the Dead's words) costs four clocks
  // more; CFI / CIF are 0.03% of them.

  // ------------------------------------------------------------ s2: |a|
  logic        v2, neg2;
  logic [4:0]  op2, sh2;
  logic [31:0] a2, mag2;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v2 <= 1'b0; neg2 <= 1'b0; op2 <= 5'd0; sh2 <= 5'd0; a2 <= 32'd0; mag2 <= 32'd0;
    end else begin
      v2 <= v1; op2 <= op1; sh2 <= sh1; a2 <= a1;
      neg2 <= a1[31];
      mag2 <= a1[31] ? (~a1 + 32'd1) : a1;
    end
  end

  // ------------------------------------------------------------ s3: shifter inputs
  logic is_cif2, is_fcv2, is_left2;
  assign is_cif2  = (op2 == 5'h0d);
  assign is_fcv2  = (op2 == 5'h0e) || (op2 == 5'h0f);
  assign is_left2 = is_cif2 || (op2 == 5'h1d) || (op2 == 5'h1f);

  // CIF: |v|, normalised left by its leading zeros
  logic [4:0]  lz;
  always_comb begin
    lz = 5'd0;
    for (int i = 0; i < 32; i++) if (mag2[i]) lz = 5'd31 - i[4:0];
  end
  // CFI / CFIB: the significand at the top, right by 158 - exponent
  logic [7:0]  famt;
  assign famt = 8'd158 - a2[30:23];

  logic [31:0] sh_in;
  logic [4:0]  sh_amt;
  logic        sh_fill;
  always_comb begin
    if (is_cif2)      begin sh_in = rev32(mag2);              sh_amt = lz;         sh_fill = 1'b0;  end
    else if (is_fcv2) begin sh_in = {1'b1, a2[22:0], 8'd0};   sh_amt = famt[4:0];  sh_fill = 1'b0;  end
    else if (is_left2)begin sh_in = rev32(a2);                sh_amt = sh2;        sh_fill = 1'b0;  end
    else              begin sh_in = a2;                       sh_amt = sh2;        sh_fill = (op2 == 5'h1e) & a2[31]; end
  end

  logic        v3, neg3, big3, tiny3, left3, fill3;
  logic [4:0]  op3, lz3, amt3;
  logic [31:0] a3, in3;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v3 <= 1'b0; neg3 <= 1'b0; big3 <= 1'b0; tiny3 <= 1'b0; left3 <= 1'b0; fill3 <= 1'b0;
      op3 <= 5'd0; lz3 <= 5'd0; amt3 <= 5'd0; a3 <= 32'd0; in3 <= 32'd0;
    end else begin
      v3 <= v2; neg3 <= neg2; op3 <= op2; lz3 <= lz; a3 <= a2;
      big3 <= (a2[30:23] >= 8'd158); tiny3 <= (a2[30:23] < 8'd127);
      left3 <= is_left2; fill3 <= sh_fill; amt3 <= sh_amt; in3 <= sh_in;
    end
  end

  // ------------------------------------------------------------ s4: the one shifter
  logic [32:0] sh_wide;
  assign sh_wide = $signed({fill3, in3}) >>> amt3;   // 33 bits: the fill bit rides on top

  logic        v4, neg4, big4, tiny4, zero4, lowz4;
  logic [4:0]  op4, lz4;
  logic [31:0] res4;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v4 <= 1'b0; neg4 <= 1'b0; big4 <= 1'b0; tiny4 <= 1'b0; zero4 <= 1'b0; lowz4 <= 1'b0;
      op4 <= 5'd0; lz4 <= 5'd0; res4 <= 32'd0;
    end else begin
      v4 <= v3; neg4 <= neg3; big4 <= big3; tiny4 <= tiny3; op4 <= op3; lz4 <= lz3;
      zero4 <= (a3 == 32'd0);
      lowz4 <= (a3[30:0] == 31'd0);
      res4  <= left3 ? rev32(sh_wide[31:0]) : sh_wide[31:0];
    end
  end

  // ------------------------------------------------------------ s5: round, negate, clamp
  // CIF rounding
  logic        g, st, up;
  logic [24:0] m_r;
  logic [7:0]  e_cif;
  assign g     = res4[7];
  assign st    = |res4[6:0];
  assign up    = g & (st | res4[8]);
  assign m_r   = {1'b0, res4[31:8]} + {24'd0, up};
  assign e_cif = 8'd158 - {3'd0, lz4} + {7'd0, m_r[24]};

  logic [31:0] cif_res;
  assign cif_res = zero4 ? 32'd0
                 : {neg4, e_cif, (m_r[24] ? m_r[23:1] : m_r[22:0])};

  // CFI / CFIB (neg4 is the float's sign here)
  logic [31:0] tr;
  assign tr = tiny4 ? 32'd0 : res4;

  logic [31:0] cfi_res;
  assign cfi_res = big4 ? 32'h80000000 : (neg4 ? (~tr + 32'd1) : tr);

  logic        b_neg, b_ov;
  logic [31:0] cfib_res;
  assign b_neg    = neg4 && !lowz4;   // a negative, non-zero float
  assign b_ov     = !b_neg && (big4 || tr > 32'd255);
  assign cfib_res = b_neg ? 32'd0 : (b_ov ? 32'd255 : tr);

  logic [31:0] r;
  always_comb begin
    case (op4)
      5'h0d:   r = cif_res;
      5'h0e:   r = cfi_res;
      5'h0f:   r = cfib_res;
      default: r = res4;
    endcase
  end

  logic        v5, cifz5, cifn5, au5, av5;
  logic [4:0]  op5;
  logic [31:0] r5;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v5 <= 1'b0; cifz5 <= 1'b0; cifn5 <= 1'b0; au5 <= 1'b0; av5 <= 1'b0; op5 <= 5'd0; r5 <= 32'd0;
    end else begin
      v5 <= v4; op5 <= op4; r5 <= r;
      cifz5 <= zero4; cifn5 <= neg4;
      au5 <= (op4 == 5'h0f) && b_neg;
      av5 <= (op4 == 5'h0f) && b_ov;
    end
  end

  // ------------------------------------------------------------ s6: flags, out
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0; result <= 32'd0;
      f_an <= 1'b0; f_az <= 1'b0; f_au <= 1'b0; f_av <= 1'b0;
    end else begin
      out_valid <= v5;
      result    <= r5;
      f_an      <= (op5 == 5'h0d) ? cifn5 : (op5 == 5'h0f) ? 1'b0 : r5[31];
      f_az      <= (op5 == 5'h0d) ? cifz5 : (r5 == 32'd0);
      f_au      <= au5;
      f_av      <= av5;
    end
  end

endmodule
