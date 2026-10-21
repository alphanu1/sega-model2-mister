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
// MB86235 (TGPx4) effective address, one bus, combinational.
//
// MAME 0.289 mb86235ops.cpp decode_ea(), mode by mode. The caller owns the
// AR file: this returns the address and the one AR write the mode makes
// (post-increment / decrement / displacement of ARx for modes 1-3, of ARy for
// 5-7 and d-f). ONE instance, used once per micro-step: MAME evaluates the
// A-bus address before the B-bus one and the source before the destination,
// and a later address sees the earlier one's AR update. A second instance
// would have to chain through the first to keep that order.
//
// Mode 0x0c is illegal in MAME (fatalerror); here it reads ARx.

`timescale 1ns/1ps

module tgpx4_agu (
  input  logic [3:0]  mode,
  input  logic [13:0] arx,
  input  logic [13:0] ary,
  input  logic [13:0] disp,
  input  logic        isb,       // B bus (selects the MOD field and the ARy half)
  input  logic [15:0] modr,      // the MOD register

  output logic [13:0] ea,
  output logic        ar_we,
  output logic        ar_sel_y,  // 0: the write goes to ARx, 1: to ARy
  output logic [13:0] ar_wval
);

  // modes d-f: ARy masked to 2..9 bits by MOD[14:12] (A) / MOD[10:8] (B)
  logic [2:0]  msel;
  logic [8:0]  ymask;
  assign msel  = isb ? modr[10:8] : modr[14:12];
  assign ymask = 9'h1ff >> (3'd7 - msel);

  // R924: THE EFFECTIVE ADDRESS AS ONE THREE-INPUT ADD, arx + y + d, its two
  // addends chosen by the mode (a shallow mux) -- not a case over separate
  // adders and a result mux. s1312's worst clk_sys paths ran ir -> ARx mux ->
  // two cascaded adders -> the mode mux -> the word-end decision.
  logic [13:0] ysel, dsel;
  always_comb begin
    ysel = 14'd0; dsel = 14'd0;
    case (mode)
      4'h4, 4'h5, 4'h6, 4'h7: ysel = ary;
      4'h8: ysel = isb ? {7'd0, ary[6:0]} : {7'd0, ary[13:7]};
      4'h9: ysel = isb ? {7'd0, ary[13:7]} : {7'd0, ary[6:0]};
      4'hb: ysel = ary;
      4'hd, 4'he, 4'hf: ysel = {5'd0, ary[8:0] & ymask};
      default: ysel = 14'd0;
    endcase
    if (mode == 4'ha || mode == 4'hb) dsel = disp;
  end
  assign ea = arx + ysel + dsel;

  always_comb begin
    ar_we    = 1'b0;
    ar_sel_y = 1'b0;
    ar_wval  = arx;
    case (mode)
      4'h1: begin ar_we = 1'b1; ar_wval = arx + 14'd1; end
      4'h2: begin ar_we = 1'b1; ar_wval = arx - 14'd1; end
      4'h3: begin ar_we = 1'b1; ar_wval = arx + disp;  end
      4'h5, 4'hd: begin ar_we = 1'b1; ar_sel_y = 1'b1; ar_wval = ary + 14'd1; end
      4'h6, 4'he: begin ar_we = 1'b1; ar_sel_y = 1'b1; ar_wval = ary - 14'd1; end
      4'h7, 4'hf: begin ar_we = 1'b1; ar_sel_y = 1'b1; ar_wval = ary + disp;  end
      default: ;
    endcase
  end

endmodule
