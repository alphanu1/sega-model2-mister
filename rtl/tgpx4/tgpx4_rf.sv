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
// One read copy of a TGPx4 register-file bank: 2^AW x 32, one write port, one
// asynchronous read port, in MLAB. Its own module because the same array
// written inside a generate loop in tgpx4_core was NOT inferred as RAM by
// quartus_map 17.0 -- it built flip-flops and read multiplexers instead
// (R920's first map). R1006: AW 4, a bank of 16 (AA / AB, or MA / MB).

`timescale 1ns/1ps

module tgpx4_rf #(
  parameter int unsigned AW = 5
) (
  input  logic          clk,
  input  logic          we,
  input  logic [AW-1:0] wa,
  input  logic [31:0]   wd,
  input  logic [AW-1:0] ra,
  output logic [31:0]   rd
);
  (* ramstyle = "MLAB, no_rw_check" *) logic [31:0] mem [0:(1<<AW)-1];
  always_ff @(posedge clk) if (we) mem[wa] <= wd;
  assign rd = mem[ra];
endmodule
