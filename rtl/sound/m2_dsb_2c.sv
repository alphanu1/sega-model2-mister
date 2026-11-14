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
// THE 2C BUILD'S DIGITAL SOUND BOARD AS THE CORE WIRES IT (study R979, R1004):
// dsb_board, its input, its reset gate and its mix into the SCSP's output.
// Moved out of Model2.sv unchanged (R1004) so that tb_m2_dsb_2c can drive the
// same RTL the core builds and show that for any game but STCC the board is
// held, never asks for SDRAM, and the sound out is the SCSP's bit for bit.
//
//   INPUT. MAME model2c stcc(): m_uart->txd_handler().append(m_dsbz80,
//   write_txd) -- the board hears exactly what the SCSP's MIDI in hears.
//   Here that is m2_sound_link's B side: b_rx_valid rises the moment a byte
//   lands, one character time after the i960 wrote it, and every byte is such
//   an edge (the link presents a byte only after the last was taken and a
//   character time has passed). Each rising edge toggles rx_tog. The board's
//   own transmit (its echo) goes nowhere, as in MAME.
//
//   RESET. run = the game's reset released, memory up, the image loaded and
//   the game STCC. Anything else holds the board in reset: its SDRAM request
//   is held low and its output is 0.
//
//   MIX. MAME routes the SCSP and the board to the speaker at 1.0 each. The
//   SCSP's out_l is MAME's SCSP stream x 32,768 (m2_scsp's dac()); the board's
//   is MAME's dsbz80 stream x 32,768 ((sample x vol) >> 7, MAME's
//   sample x vol / (32,768 x 128)). So the two add at unity; the sum is
//   clamped to 16 bits, never wrapped. The board's 32 kHz sample is held
//   between strobes.

`timescale 1ns/1ps

module m2_dsb_2c #(
  parameter int unsigned AW = 26,
  parameter logic [AW:1] ROM_BASE  = AW'(32'h3400000),   // SDRAM words
  parameter logic [AW:1] MPEG_BASE = AW'(32'h3000000),
  parameter logic [AW:1] RAM_BASE  = AW'(32'h3410000),
  parameter int unsigned SYS_MHZ   = 80,
  parameter bit WRAM_MLAB = 1'b0,
  parameter bit FIFO_MLAB = 1'b0,
  parameter bit TBL_PACK  = 1'b0
) (
  input  logic        clk,
  input  logic        mem_rst_n,
  input  logic        run,           // registered here into the board's reset

  input  logic        b_rx_v,        // m2_sound_link's B side, as the SCSP sees it
  input  logic  [7:0] b_rx_d,

  input  logic signed [15:0] in_l,   // the SCSP's output
  input  logic signed [15:0] in_r,
  output logic signed [15:0] out_l,  // the speaker's
  output logic signed [15:0] out_r,

  output logic        s_req,
  output logic        s_we,
  output logic [AW:1] s_addr,
  output logic [15:0] s_din,
  output logic  [1:0] s_be,
  input  logic        s_ack,
  input  logic [15:0] s_dout,

  output logic        dbg_trap,
  output logic [15:0] dbg_frames
);

  logic dsb_rst_n, rx_tog, b_rx_v_d;
  always_ff @(posedge clk) dsb_rst_n <= run;
  always_ff @(posedge clk or negedge mem_rst_n)
    if (!mem_rst_n) begin rx_tog <= 1'b0; b_rx_v_d <= 1'b0; end
    else begin b_rx_v_d <= b_rx_v; if (b_rx_v && !b_rx_v_d) rx_tog <= ~rx_tog; end

  logic signed [15:0] dsb_l, dsb_r;
  dsb_board #(.AW(AW), .ROM_BASE(ROM_BASE), .MPEG_BASE(MPEG_BASE), .RAM_BASE(RAM_BASE), .MAW(22),
              .T_NUM(1), .T_DEN(SYS_MHZ / 4), .TICK_NUM(4), .TICK_DEN(SYS_MHZ * 125),
              .WRAM_MLAB(WRAM_MLAB), .FIFO_MLAB(FIFO_MLAB), .TBL_PACK(TBL_PACK)) u_dsb (
    .clk(clk), .rst_n(dsb_rst_n),
    .rx_tog(rx_tog), .rx_byte(b_rx_d),
    .vol_mame(1'b1),   // MAME's reading of e8 (every write is the volume)
    .s_req(s_req), .s_we(s_we), .s_addr(s_addr), .s_din(s_din), .s_be(s_be),
    .s_ack(s_ack), .s_dout(s_dout),
    .out_l(dsb_l), .out_r(dsb_r), .out_stb(),
    .dbg_trap(dbg_trap), .dbg_frames(dbg_frames)
  );

  wire signed [16:0] mix_l = 17'(in_l) + 17'(dsb_l);
  wire signed [16:0] mix_r = 17'(in_r) + 17'(dsb_r);
  assign out_l = (mix_l[16] != mix_l[15]) ? (mix_l[16] ? 16'sh8000 : 16'sh7fff) : mix_l[15:0];
  assign out_r = (mix_r[16] != mix_r[15]) ? (mix_r[16] ? 16'sh8000 : 16'sh7fff) : mix_r[15:0];

endmodule
