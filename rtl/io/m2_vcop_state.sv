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
// IS EACH VIRTUA COP PLAYER IN PLAY? (R849) -- the game's own answer, read
// off the i960's writes to work RAM, so a crosshair shows only while its
// player is playing: not in the attract (whose demo plays a 1P game with a
// gun of its own), the title, stage select, test mode, the continue
// countdown or game over.
//
// Found in MAME 0.289 vcopa (sim/io/mame_m2_vcop_play.lua; R849):
//   0x5016d4 byte 0  the game's mode: 0 boot, 1 attract, 2 credited start,
//                    3 / 4 / 6 stage select and its way in, 7 PLAYING,
//                    0x0c continue, 0x0d game over
//   0x50ee30 byte 0  player 1: 0 out, 1 in play, 2 continue countdown,
//                    3 its own game over (the other player playing on)
//   0x50ee34 byte 0  player 2: the same
// A player's crosshair shows when mode == 7 and its state == 1.
//
// TEST MODE entered during a game leaves all three words as they were (mode
// stays 7 for the ~3 s of the test screens, MAME) and the game reboots on
// leaving it, writing the mode word. So the Test button latches "not in
// play" until the next write to the mode word.
//
// THE WRITE PATH ONLY: a completed i960 write (req, we, ack on clk_i960) to
// one of those three words with byte lane 0 enabled -- the i960 replicates a
// stored byte across the word and the enables pick the lane, so stob and st
// both count (the game uses st). Nothing reads work RAM. The address and
// value compares are made on the bus and only their five answers are
// registered; the bus is clk_i960 (25 ns). en (game ID 1) gates the outputs;
// reset is the CPU's.

`timescale 1ns/1ps

module m2_vcop_state (
  input  logic        clk,            // clk_i960
  input  logic        rst_n,          // the CPU's reset
  input  logic        en,             // Virtua Cop with the guns built (quasi-static)
  input  logic        test,           // the Test button (joystick 0 bit 8 for Virtua Cop; clk_sys)
  input  logic        bus_req, bus_we, bus_ack,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] bus_addr,       // [1:0] unused: word compares
  input  logic [31:0] bus_wdata,      // lane 0 only
  input  logic  [3:0] bus_be,         // lane 0 only
  /* verilator lint_on UNUSEDSIGNAL */
  output logic  [1:0] play            // {P2, P1} in play (registered)
);

  wire wr = bus_req & bus_we & bus_ack & bus_be[0];
  wire hi = (bus_addr[31:16] == 16'h0050);
  logic [2:0] hit_q;                  // {P2 word, P1 word, mode word} written
  logic       v7_q, v1_q;             // lane 0 was 7 / was 1
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin hit_q <= 3'd0; v7_q <= 1'b0; v1_q <= 1'b0; end
    else begin
      hit_q <= {wr & hi & (bus_addr[15:2] == 14'h3b8d),     // 0x50ee34
                wr & hi & (bus_addr[15:2] == 14'h3b8c),     // 0x50ee30
                wr & hi & (bus_addr[15:2] == 14'h05b5)};    // 0x5016d4
      v7_q  <= (bus_wdata[7:0] == 8'h07);
      v1_q  <= (bus_wdata[7:0] == 8'h01);
    end
  end

  // one bit per word, and the test latch
  logic ingame, p1in, p2in, t_q, tl;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ingame <= 1'b0; p1in <= 1'b0; p2in <= 1'b0; t_q <= 1'b0; tl <= 1'b0; play <= 2'b00;
    end else begin
      t_q <= test;
      if (t_q) tl <= 1'b1; else if (hit_q[0]) tl <= 1'b0;
      if (hit_q[0]) ingame <= v7_q;
      if (hit_q[1]) p1in   <= v1_q;
      if (hit_q[2]) p2in   <= v1_q;
      play <= {en & ingame & ~tl & p2in, en & ingame & ~tl & p1in};
    end
  end

endmodule
