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
//
// VIRTUA COP 2 (V2 = 1; R870, MAME 0.289 vcop2, sim/io/mame_m2_vcop2_play.lua):
//   0x500034 word    the game's main mode, ONE-HOT, written whole (st) EVERY
//                    frame (pc 0x273c): 0x02 boot, 0x20 / 0x80 the two
//                    attract sequences, 0x100 A GAME (start, stage select,
//                    play, continue, game over), 0x2000 / 0x4000 / 0x8000 /
//                    0x04 / 0x10 the results and name entry on the way out.
//                    In a game = lane 1 (bits 15:8) == 0x01.
//   0x500038 byte    the game's step inside the mode, written as a byte: in a
//                    game 2 start, 3-7 stage select and the way in, 8 play,
//                    9 the continue when no player is left, 0x0a game over.
//                    TEST MODE writes 0 here on entry (pc 0x1ffc) and stops
//                    the mode writer, so "step != 0" is V2's test gate --
//                    Virtua Cop's latch would not hold: the mode word is
//                    written again one frame after the press, before the test
//                    program starts (175.006 press, 175.022 mode, 175.040 0).
//   0x502088 word    player 1: 0 out, 1 in play, 2 its continue countdown
//                    (written on a change in a game; toggled 1 / 0 every frame
//                    by the attract's own demo player -- the mode word rules
//                    that out)
//   0x50208c word    player 2: the same (1 at a start or join, pc 0x5fdc /
//                    0x305c; 2 at its countdown, 0x6280; 0 at game over)
// A player is in play when the mode is 0x100, the step is not 0 and its word
// is 1: from its start (stage select included -- a player who starts alone
// aims at the stage panels) to its countdown or game over.

`timescale 1ns/1ps

module m2_vcop_state #(
  parameter bit V2 = 1'b0           // R870: Virtua Cop 2's words
) (
  input  logic        clk,            // clk_i960
  input  logic        rst_n,          // the CPU's reset
  input  logic        en,             // Virtua Cop with the guns built (quasi-static)
  input  logic        test,           // the Test button (joystick 0 bit 8 for Virtua Cop; clk_sys; unused with V2)
  input  logic        bus_req, bus_we, bus_ack,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] bus_addr,       // [1:0] unused: word compares
  input  logic [31:0] bus_wdata,      // lane 0 (V2: and lane 1, its mode)
  input  logic  [3:0] bus_be,         // lane 0 (V2: and lane 1)
  /* verilator lint_on UNUSEDSIGNAL */
  output logic  [1:0] play            // {P2, P1} in play (registered)
);

  logic ingame, p1in, p2in, t_q;
  /* verilator lint_off UNUSEDSIGNAL */
  logic tl;                           // the test latch (unused with V2)
  /* verilator lint_on UNUSEDSIGNAL */
  wire wr = bus_req & bus_we & bus_ack & bus_be[0];
  wire hi = (bus_addr[31:16] == 16'h0050);
  // each game's words (word address bits 15:2; both games in 0x50xxxx)
  localparam logic [13:0] A_MODE = V2 ? 14'h000d : 14'h05b5;   // 0x500034 / 0x5016d4
  localparam logic [13:0] A_P1   = V2 ? 14'h0822 : 14'h3b8c;   // 0x502088 / 0x50ee30
  localparam logic [13:0] A_P2   = V2 ? 14'h0823 : 14'h3b8d;   // 0x50208c / 0x50ee34
  // V2's mode is lane 1 of its word
  wire wr_m = V2 ? (bus_req & bus_we & bus_ack & bus_be[1]) : wr;
  logic [2:0] hit_q;                  // {P2 word, P1 word, mode word} written
  logic       v7_q, v1_q;             // the mode's value / lane 0 was 1
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin hit_q <= 3'd0; v7_q <= 1'b0; v1_q <= 1'b0; end
    else begin
      hit_q <= {wr & hi & (bus_addr[15:2] == A_P2),
                wr & hi & (bus_addr[15:2] == A_P1),
                wr_m & hi & (bus_addr[15:2] == A_MODE)};
      v7_q  <= V2 ? (bus_wdata[15:8] == 8'h01) : (bus_wdata[7:0] == 8'h07);
      v1_q  <= (bus_wdata[7:0] == 8'h01);
    end
  end

  // V2: the step byte 0x500038 (word 0x000e, lane 0) is not 0 -- the test gate
  logic gate;
  generate if (V2) begin : g_step
    logic hs_q, nz_q, step_nz;
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin hs_q <= 1'b0; nz_q <= 1'b0; step_nz <= 1'b0; end
      else begin
        hs_q <= wr & hi & (bus_addr[15:2] == 14'h000e);
        nz_q <= (bus_wdata[7:0] != 8'h00);
        if (hs_q) step_nz <= nz_q;
      end
    end
    assign gate = step_nz;
  end else begin : g_latch
    assign gate = ~tl;
  end endgenerate

  // one bit per word, and the test latch (Virtua Cop; unused with V2)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ingame <= 1'b0; p1in <= 1'b0; p2in <= 1'b0; t_q <= 1'b0; tl <= 1'b0; play <= 2'b00;
    end else begin
      t_q <= test;
      if (t_q) tl <= 1'b1; else if (hit_q[0]) tl <= 1'b0;
      if (hit_q[0]) ingame <= v7_q;
      if (hit_q[1]) p1in   <= v1_q;
      if (hit_q[2]) p2in   <= v1_q;
      play <= {en & ingame & gate & p2in, en & ingame & gate & p1in};
    end
  end

endmodule
