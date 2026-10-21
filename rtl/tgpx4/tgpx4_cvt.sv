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
// 0.289 decode_aluop 0x0d-0x0f and 0x1c-0x1f. Two clocks (operand register,
// result register). A left shift is the right shift of the bit-reversed
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

  // ------------------------------------------------------------ operands
  logic is_cif, is_fcv, is_left;
  assign is_cif  = (op1 == 5'h0d);
  assign is_fcv  = (op1 == 5'h0e) || (op1 == 5'h0f);
  assign is_left = is_cif || (op1 == 5'h1d) || (op1 == 5'h1f);

  // CIF: |v|, normalised left by its leading zeros
  logic        is_neg;
  logic [31:0] mag;
  logic [4:0]  lz;
  assign is_neg = a1[31];
  assign mag    = is_neg ? (~a1 + 32'd1) : a1;
  always_comb begin
    lz = 5'd0;
    for (int i = 0; i < 32; i++) if (mag[i]) lz = 5'd31 - i[4:0];
  end

  // CFI / CFIB: the significand at the top, right by 158 - exponent
  logic [7:0]  fe;
  logic        big, tiny;
  logic [7:0]  famt;
  assign fe   = a1[30:23];
  assign big  = (fe >= 8'd158);
  assign tiny = (fe <  8'd127);
  assign famt = 8'd158 - fe;

  logic [31:0] sh_in, sh_out, sh_res;
  logic [32:0] sh_wide;
  logic [4:0]  sh_amt;
  logic        sh_fill;
  always_comb begin
    if (is_cif)      begin sh_in = rev32(mag);               sh_amt = lz;         sh_fill = 1'b0;  end
    else if (is_fcv) begin sh_in = {1'b1, a1[22:0], 8'd0};   sh_amt = famt[4:0];  sh_fill = 1'b0;  end
    else if (is_left)begin sh_in = rev32(a1);                sh_amt = sh1;        sh_fill = 1'b0;  end
    else             begin sh_in = a1;                       sh_amt = sh1;        sh_fill = (op1 == 5'h1e) & a1[31]; end
  end
  // the one shifter
  assign sh_wide = $signed({sh_fill, sh_in}) >>> sh_amt;   // 33 bits: the fill bit rides on top
  assign sh_out  = sh_wide[31:0];
  assign sh_res = is_left ? rev32(sh_out) : sh_out;

  // ------------------------------------------------------------ CIF rounding
  logic        g, st, up;
  logic [24:0] m_r;
  logic [7:0]  e_cif;
  assign g     = sh_res[7];
  assign st    = |sh_res[6:0];
  assign up    = g & (st | sh_res[8]);
  assign m_r   = {1'b0, sh_res[31:8]} + {24'd0, up};
  assign e_cif = 8'd158 - {3'd0, lz} + {7'd0, m_r[24]};

  logic [31:0] cif_res;
  assign cif_res = (a1 == 32'd0) ? 32'd0
                 : {is_neg, e_cif, (m_r[24] ? m_r[23:1] : m_r[22:0])};

  // ------------------------------------------------------------ CFI / CFIB
  logic [31:0] tr;
  assign tr = tiny ? 32'd0 : sh_res;

  logic [31:0] cfi_res;
  assign cfi_res = big ? 32'h80000000 : (a1[31] ? (~tr + 32'd1) : tr);

  logic        b_neg, b_ov;
  logic [31:0] cfib_res;
  assign b_neg    = a1[31] && (a1[30:0] != 31'd0);
  assign b_ov     = !b_neg && (big || tr > 32'd255);
  assign cfib_res = b_neg ? 32'd0 : (b_ov ? 32'd255 : tr);

  logic [31:0] r;
  always_comb begin
    case (op1)
      5'h0d:   r = cif_res;
      5'h0e:   r = cfi_res;
      5'h0f:   r = cfib_res;
      default: r = sh_res;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0; result <= 32'd0;
      f_an <= 1'b0; f_az <= 1'b0; f_au <= 1'b0; f_av <= 1'b0;
    end else begin
      out_valid <= v1;
      result    <= r;
      f_an      <= (op1 == 5'h0d) ? is_neg : (op1 == 5'h0f) ? 1'b0 : r[31];
      f_az      <= (op1 == 5'h0d) ? (a1 == 32'd0) : (r == 32'd0);
      f_au      <= (op1 == 5'h0f) && b_neg;
      f_av      <= (op1 == 5'h0f) && b_ov;
    end
  end

endmodule
