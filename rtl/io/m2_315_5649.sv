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
//         R870, GUN (Virtua Cop 2, MAME model2a_state::vcop2): channel 2 is
//         the gun board -- a write of 10 is lightgun_mux_w (the mux byte), a
//         read of 12 is lightgun_mux_r: mux 0-7 the low / high byte (mux bit
//         0) of P1_Y, P1_X, P2_Y, P2_X (mux 2:1), mux >= 8 0xFC | P2 off << 1
//         | P1 off (lightgun_offscreen_r(0)). The mux is 0 from power-on and
//         survives a machine reset (MAME: a member set at construction).
//   13    RS-422 status: 0x0C (MAME's HACK: RX full, TX empty)
//   14    mode                       15 analog: read = channel, auto-
//         increments; write = select. R862: channels 0-2 are an0..an2
//         (Sega Rally's STEER / ACCEL / BRAKE; 0xFF for a game with none,
//         MAME's unbound default), 3-7 read 0xFF.
//   other reads 0xFF.
// model2a's callbacks: PA out -> eeprom_w (bit 0 ctrlmode, 5 DI, 6 CS, 7 CLK);
// PB in -> in0_r (ctrlmode: 0xC0 | DO << 5 | 0x10 | IN0[3:0], else IN0);
// PC in IN1, PD in IN2, PG in SW; PE out the billboard, PF out the lamps.
// R892: PE's latch is an output (pe): Manx TT's DX cabinet hangs its motion
// base on PE (command) and PD (status); m2_2a_inputs answers it.
//
// rdata is combinational from registers: the bridge samples io_rdata in the
// cycle io_sel is high (Model2.sv's coprocessor note). Read side effects (the
// analog channel) count once per access whose enables name offset 15.

`timescale 1ns/1ps

module m2_315_5649 #(
  parameter bit GUN = 1'b0,         // R870: Virtua Cop 2's guns on serial channel 2
  parameter bit EE_LOAD = 1'b0      // R897: the EEPROM's load port (m2_93c46 LOAD)
) (
  input  logic        clk,
  // MAME's machine reset: direction, mode and ctrlmode (R862: not the
  // analog channel, which starts at power-on).
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
  input  logic  [7:0] an0,          // R862: analog channels 0-2
  input  logic  [7:0] an1,
  input  logic  [7:0] an2,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic  [9:0] gun_p1x, gun_p1y, gun_p2x, gun_p2y,   // R870 (GUN): game units
  input  logic  [1:0] gun_off,      // {P2, P1} off-screen
  /* verilator lint_on UNUSEDSIGNAL */
  output logic  [7:0] lamps,        // PF
  output logic  [7:0] pe,           // R892: PE's latch (Manx TT's motion-base command)
  input  logic        ee_ld_we,     // R897 (EE_LOAD): an EEPROM word from the MRA
  input  logic  [5:0] ee_ld_a,
  input  logic [15:0] ee_ld_d,
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
  m2_93c46 #(.LOAD(EE_LOAD)) u_ee (
    .clk(clk), .rst_n(por_n),
    .cs(pv[0][6]), .sk(pv[0][7]), .di(pv[0][5]), .do_o(ee_do),
    .ld_we(ee_ld_we), .ld_a(ee_ld_a), .ld_d(ee_ld_d)   // R897
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

  // R870: the gun board on serial channel 2 (GUN; otherwise 12 reads 0x00)
  wire [7:0] gun_byte;
  generate if (GUN) begin : g_gun
    logic [7:0] gmux;
    always_ff @(posedge clk or negedge por_n) begin
      if (!por_n) gmux <= 8'h00;
      else if (sel && we && be[0] && word == 3'd5) gmux <= wdata[7:0];   // offset 10
    end
    wire [9:0] gv = (gmux[2:1] == 2'd0) ? gun_p1y : (gmux[2:1] == 2'd1) ? gun_p1x
                  : (gmux[2:1] == 2'd2) ? gun_p2y : gun_p2x;
    assign gun_byte = (gmux[7:3] != 5'd0) ? {6'h3f, gun_off}
                    : gmux[0] ? {6'd0, gv[9:8]} : gv[7:0];
  end else begin : g_nogun
    assign gun_byte = 8'h00;
  end endgenerate

  function automatic logic [7:0] rd(input logic [3:0] off);
    if (off <= 4'd6)
      rd = dir[off[2:0]] ? port_in(off[2:0]) : pv[off[2:0]];
    else case (off)
      4'hb:       rd = 8'h00;
      4'hc:       rd = gun_byte;          // R870
      4'hd:       rd = 8'h0c;
      4'hf:       rd = (an_ch == 3'd0) ? an0 : (an_ch == 3'd1) ? an1
                     : (an_ch == 3'd2) ? an2 : 8'hff;   // R862
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
      dir <= 8'hff; mode <= 8'h00; ctrlmode <= 1'b0;
    end else if (sel && we && be[0]) begin
      if (off_lo == 4'h0) ctrlmode <= wdata[0];
      if (off_lo == 4'h8) dir  <= wdata[7:0];
      else if (off_lo == 4'he) mode <= wdata[7:0];
    end
  end

  // R862: THE ANALOG CHANNEL SURVIVES A MACHINE RESET. MAME's device_reset
  // sets only the direction and the mode; m_analog_channel is 0 from
  // construction. Invisible while no channel was bound (every read 0xFF);
  // with Sega Rally's three it is not, so it now starts at power-on only.
  always_ff @(posedge clk or negedge por_n) begin
    if (!por_n) an_ch <= 3'd0;
    else if (sel && be[2] && off_hi == 4'hf)
      an_ch <= we ? wdata[18:16] : an_ch + 3'd1;
  end

  assign lamps   = pv[5];
  assign pe      = pv[4];
  assign dbg_pa  = pv[0];
  assign dbg_dir = dir;

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, be[1], be[3], wdata[31:24], wdata[15:8], wdata[23:19], mode};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule
