// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// THE CHARACTER FETCH IS THE ONE REQUESTER THAT IS NOT ON clk_sys.
//
// m2_sdram_x2's header says every requester -- the i960's bridge, the copy
// engine, the character fetch, the sweep and the ROM loader -- is on clk_sys,
// and that this is therefore an ADAPTER and not a clock-domain crossing. That
// premise is true of every port but this one. m2_video runs on clk_vid, so
// char_req/char_ack cross 48 MHz <-> 32 MHz.
//
// WHY IT FAILED SILENTLY, AND ONLY ON HARDWARE (study R49):
//
//   * 48 and 32 are not integer multiples of one another. They share edges only
//     every 62.5 ns, so a signal from one is NOT stable across a whole cycle of
//     the other the way 96/48 is.
//   * m2_sdram holds p_ack for ACK_HOLD = 2 fast cycles, which is exactly one
//     48 MHz cycle -- 20.8 ns. clk_vid samples every 31.25 ns. A pulse shorter
//     than the sampling period is missed, deterministically, depending on which
//     clk_sys cycle it lands in.
//   * Model2.sdc CUTS clk_vid against the memory group, so the path was never
//     timed either. Nothing anywhere reported it.
//   * Every simulation answered char_ack in m2_video's OWN clock, so the frame
//     render reproduced MAME's picture exactly while the board showed a screen
//     of one flat colour -- red through a garbage palette, black once the
//     palette was correct. The renderer was never getting its characters.
//
// A FOUR-PHASE HANDSHAKE, because the ratio is not integral and no pulse-width
// argument survives a change of clock. This is correct at any pair of
// frequencies, which is the point: the previous arrangement was correct only
// for a ratio nobody had written down.
//
//   v_req  ---___------___     level, held by m2_tile_fetch until acknowledged
//   req_s  -----___------_     two clk_sys flops behind it
//   s_req  -----=--------      one SDRAM transaction, issued once
//   s_done ------=======__     raised when data is latched, cleared when v_req
//                              drops -- so it cannot be missed
//   v_ack  ---------=-----     ONE clk_vid cycle, on the rising edge of s_done
//
// v_ack is an EDGE, not a level. m2_tile_fetch re-raises char_req as soon as it
// has been acknowledged, and a level would still be high when it did -- the
// engine would read the previous character's data as the next one's. Gating a
// new transaction on `!s_done` closes the same hole from the other side: the
// crossing will not start another fetch until this one has been retired.

`timescale 1ns/1ps

module m2_char_cdc (
  // Video side: m2_video's clock.
  input  logic        clk_vid,
  input  logic        vid_rst_n,
  input  logic        v_req,      // level, held until v_ack
  input  logic [17:0] v_addr,     // held for as long as v_req
  output logic        v_ack,      // ONE clk_vid cycle
  output logic [63:0] v_data,     // valid at v_ack

  // Memory side: the m2_sdram_x2 slow domain.
  input  logic        clk_sys,
  input  logic        sys_rst_n,
  output logic        s_req,
  output logic [17:0] s_addr,
  input  logic        s_ack,
  input  logic [63:0] s_data
);

  // ---------------------------------------------------------------- clk_sys

  logic [1:0]  req_sync;
  logic        s_busy, s_done;
  logic [63:0] s_hold;
  logic [17:0] s_addr_r;

  wire req_s = req_sync[1];

  always_ff @(posedge clk_sys or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
      req_sync <= 2'b00;
      s_req    <= 1'b0;
      s_busy   <= 1'b0;
      s_done   <= 1'b0;
      s_hold   <= 64'd0;
      s_addr_r <= 18'd0;
    end else begin
      req_sync <= {req_sync[0], v_req};

      if (!s_busy && !s_done && req_s) begin
        // v_addr has been stable since before req_s could rise -- the video
        // side holds it for as long as it holds v_req, and req_s is two
        // clk_sys edges behind that. So it is sampled, not synchronised.
        s_addr_r <= v_addr;
        s_req    <= 1'b1;
        s_busy   <= 1'b1;
      end else if (s_busy && s_ack) begin
        s_hold <= s_data;
        s_req  <= 1'b0;
        s_busy <= 1'b0;
        s_done <= 1'b1;
      end else if (s_done && !req_s) begin
        // The requester has seen it and let go. Only now may another start.
        s_done <= 1'b0;
      end
    end
  end

  assign s_addr = s_addr_r;

  // ---------------------------------------------------------------- clk_vid

  logic [1:0] done_sync;
  logic       done_q;

  always_ff @(posedge clk_vid or negedge vid_rst_n) begin
    if (!vid_rst_n) begin
      done_sync <= 2'b00;
      done_q    <= 1'b0;
    end else begin
      done_sync <= {done_sync[0], s_done};
      done_q    <= done_sync[1];
    end
  end

  // The v_req term makes a stray acknowledge impossible if the video side ever
  // abandons a fetch: s_done still rises when the SDRAM answers, but with no
  // request outstanding it clears again without ever being reported.
  assign v_ack  = done_sync[1] & ~done_q & v_req;

  // s_hold does not change while s_done is high, and s_done is high for the
  // whole time v_ack can pulse, so this needs no synchroniser of its own.
  assign v_data = s_hold;

endmodule
