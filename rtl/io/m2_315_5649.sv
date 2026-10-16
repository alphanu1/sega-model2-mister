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
// THE MODEL 2A-CRX I/O: one Sega 315-5649 on the main board, read by the i960
// directly (no Z80, no dual-port RAM), with the 93C46 EEPROM on its port A.
// After MAME 0.289 sega/315_5649.cpp and model2.cpp (model2a_crx_mem,
// model2a(): eeprom_w, in0_r):
//
//   map(0x01c00000, 0x01c0001f).rw("io", ...).umask32(0x00ff00ff)
//
// so device offset n is byte lane 0 (n even) or lane 2 (n odd) of dword
// n >> 1: word = addr[4:2], and the access's byte enables say which offsets
// it names. Offsets:
//   0-6   ports A-G: read = the input if the port's direction bit is 1
//         (input), else the value last written; write = latch + output
//         callback. G in counter mode (mode bit 7) is not modelled (it reads
//         the input; MAME's counter callbacks are unset for model2a).
//   8     direction (1 = input), 0xFF at reset
//   9/10  RS-422 TX (dropped)        11/12 RS-422 RX: 0x00 (MAME's default)
//   13    RS-422 status: 0x0C (MAME's HACK: RX full, TX empty)
//   14    mode                       15 analog: read = channel, auto-
//         increments; write = select. No channel bound: 0xFF.
//   other reads 0xFF.
// model2a's callbacks: PA out -> eeprom_w (bit 0 ctrlmode, 5 DI, 6 CS, 7 CLK);
// PB in -> in0_r (ctrlmode: 0xC0 | DO << 5 | 0x10 | IN0[3:0], else IN0);
// PC in IN1, PD in IN2, PG in SW; PE out the billboard, PF out the lamps.
//
// rdata is combinational from registers: the bridge samples io_rdata in the
// cycle io_sel is high (Model2.sv's coprocessor note). Read side effects (the
// analog channel) count once per access whose enables name offset 15.

`timescale 1ns/1ps

module m2_315_5649 (
  input  logic        clk,
  // MAME's machine reset: direction, mode, the analog channel and ctrlmode.
  // The port latches and the EEPROM keep their state across it (MAME resets
  // neither -- a 93C46 has no reset pin); they start at power-on (por_n).
  input  logic        por_n,
  input  logic        rst_n,
  input  logic        sel,          // one cycle per i960 access to 0x01c00000-0x01c0001f
  input  logic        we,
  input  logic  [2:0] word,         // addr[4:2]
  input  logic  [3:0] be,
  input  logic [31:0] wdata,
  output logic [31:0] rdata,
  // the cabinet, active low as MAME's ports
  input  logic  [7:0] in0,          // coins, test, service, starts
  input  logic  [7:0] in1,          // player 1
  input  logic  [7:0] in2,          // player 2
  input  logic  [7:0] sw,           // SW3 DIP bank
  output logic  [7:0] lamps,        // PF
  output logic  [7:0] dbg_pa,
  output logic  [7:0] dbg_dir
);

  logic [7:0] pv [8];       // port latches A-G (8 entries: a 3-bit index never runs off the end, R807)
  logic [7:0] dir;          // 1 = input
  logic [7:0] mode;
  logic [2:0] an_ch;

  // ------------------------------------------------------------ the EEPROM
  logic ctrlmode;   // model2_state::m_ctrlmode: PA bit 0, cleared by machine_reset
  wire ee_do;
  m2_93c46 u_ee (
    .clk(clk), .rst_n(por_n),
    .cs(pv[0][6]), .sk(pv[0][7]), .di(pv[0][5]), .do_o(ee_do)
  );
  wire [7:0] pb_in = ctrlmode ? {2'b11, ee_do, 1'b1, in0[3:0]} : in0;

  function automatic logic [7:0] port_in(input logic [2:0] p);
    case (p)
      3'd1: port_in = pb_in;
      3'd2: port_in = in1;
      3'd3: port_in = in2;
      3'd6: port_in = sw;
      default: port_in = 8'hff;   // A, E, F: nothing bound (MAME's default 0xff)
    endcase
  endfunction

  function automatic logic [7:0] rd(input logic [3:0] off);
    if (off <= 4'd6)
      rd = dir[off[2:0]] ? port_in(off[2:0]) : pv[off[2:0]];
    else case (off)
      4'hb, 4'hc: rd = 8'h00;
      4'hd:       rd = 8'h0c;
      4'hf:       rd = 8'hff;          // analog: no channel bound
      default:    rd = 8'hff;
    endcase
  endfunction

  wire [3:0] off_lo = {word, 1'b0};
  wire [3:0] off_hi = {word, 1'b1};
  assign rdata = {8'h00, rd(off_hi), 8'h00, rd(off_lo)};

  always_ff @(posedge clk or negedge por_n) begin
    if (!por_n) begin
      for (int i = 0; i < 8; i++) pv[i] <= 8'hff;
    end else if (sel && we) begin
      if (be[0] && off_lo <= 4'd6) pv[off_lo[2:0]] <= wdata[7:0];
      if (be[2] && off_hi <= 4'd6) pv[off_hi[2:0]] <= wdata[23:16];
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dir <= 8'hff; mode <= 8'h00; an_ch <= 3'd0; ctrlmode <= 1'b0;
    end else if (sel) begin
      if (we) begin
        if (be[0]) begin
          if (off_lo == 4'h0) ctrlmode <= wdata[0];
          if (off_lo == 4'h8) dir  <= wdata[7:0];
          else if (off_lo == 4'he) mode <= wdata[7:0];
        end
        if (be[2] && off_hi == 4'hf) an_ch <= wdata[18:16];
      end else if (be[2] && off_hi == 4'hf)
        an_ch <= an_ch + 3'd1;
    end
  end

  assign lamps   = pv[5];
  assign dbg_pa  = pv[0];
  assign dbg_dir = dir;

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, be[1], be[3], wdata[31:24], wdata[15:8], wdata[23:19], mode, an_ch};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
