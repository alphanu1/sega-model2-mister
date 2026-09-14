// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// Carries the glyph lookup across the 2:1 between clk_sys and clk_mem.
//
// WHY THE CHAR CACHE MOVES. A glyph miss costs about 280 ns against a 480 ns
// per-column budget, so two misses in one column overrun and the line repeats.
// Of that 280 ns roughly 160 ns is the SDRAM round trip and 120 ns is the
// cache's own walk -- S_IDLE, S_LOOK, S_MISS, S_FILL, S_ACK is five cycles, and
// at 50 MHz that is 100 ns of it. Only that half scales:
//
//     at  50 MHz   ~120 + ~160 = 280 ns    two misses = 560 ns   OVERRUN
//     at 100 MHz    ~60 + ~160 = 220 ns    two misses = 440 ns   fits
//
// R313 halved the cache to 32 KB to buy ALM, which took the glyph hit rate from
// 90.1% to 83.0% and the overruns from 14 a frame to 53. This is what pays that
// back without giving the ALM up again.
//
// THE ACKNOWLEDGE IS THE DIFFICULTY, as it was for m2_texel (R318). `v_ack` is
// one cycle; at 100 MHz that is 10 ns and a 50 MHz sampler sees it half the
// time. A missed acknowledge leaves the fetch engine waiting forever on a glyph
// that has already been delivered. So `done` latches on the acknowledge and
// holds the slow side's ack up until the requester drops its request.
//
// AND THE DATA IS BYPASSED ON THE ACK CYCLE, not merely registered. R319 is the
// reason this matters: a slow-clock register sampling a fast-clock one on
// ALIGNED EDGES is a hold race, and the only thing that saved `p4_dout_r` for
// as long as it lasted was placement luck. `v_data` is presented combinationally
// while the ack is up and from a register afterwards, so the consumer has a
// whole slow cycle of stability either way.

`timescale 1ns/1ps

module m2_char_x2 #(
  parameter int unsigned ADDR_BITS = 18
) (
  input  logic                 clk_fast,      // clk_mem
  input  logic                 rst_n,

  // ---------------------------------------------- requester, slow (clk_sys)
  input  logic                 s_req,
  input  logic [ADDR_BITS-1:0] s_addr,
  output logic                 s_ack,
  output logic [31:0]          s_data,

  // -------------------------------------------- m2_char_cache, fast (clk_mem)
  output logic                 f_req,
  output logic [ADDR_BITS-1:0] f_addr,
  input  logic                 f_ack,
  input  logic [31:0]          f_data
);

  logic        done;
  logic [31:0] data_r;

  always_ff @(posedge clk_fast or negedge rst_n) begin
    if (!rst_n) begin
      done <= 1'b0; data_r <= 32'd0;
    end else begin
      if (!s_req)     done <= 1'b0;
      else if (f_ack) done <= 1'b1;
      if (f_ack) data_r <= f_data;
    end
  end

  assign f_req  = s_req & ~done & ~f_ack;
  assign f_addr = s_addr;

  assign s_ack  = f_ack | done;
  assign s_data = f_ack ? f_data : data_r;

endmodule
