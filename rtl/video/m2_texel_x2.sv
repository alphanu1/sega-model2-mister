// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// Carries texel requests across the 2:1 between clk_sys and clk_mem.
//
// WHY m2_texel MOVES AND m2_span_tex DOES NOT. A texel miss is ~280 ns, of
// which roughly 160 ns is the SDRAM round trip and 120 ns is m2_texel's own
// state machine. Only the second half scales with the clock (R309).
//
// R539: UP TO K FETCHES IN FLIGHT, NOT ONE.
//
// The first version carried one request as a level: the requester held
// s_req until s_ack, and the next fetch could not start until this one had
// been answered and the handshake had come back down. That made every
// textured group of four pixels cost about two clk_sys cycles, which is now
// what limits the horizon bands (R537: the fill, when busy, is walking spans,
// and the texel bus waits are down to 4%). m2_texel itself has streamed since
// R474 -- it takes a request every cycle and answers in order through its
// response queue -- so the one-at-a-time limit was this adapter's.
//
// The slow side now ISSUES: s_req is a one-cycle pulse carrying its payload,
// accepted whenever s_rdy (a credit is free). Answers come back IN ORDER as
// s_ack/s_texel, and the requester takes each with s_take. K credits bound
// what is in flight, so neither queue can overflow.
//
// THE CACHE SEES A REGISTER. R496 measured a 2:1 mux in front of m2_texel's
// address adders at -1.271 ns and eight broken builds. The request queue is
// never read straight into the cache: the head is loaded into f_tex/f_u/f_v
// registers one cycle ahead, and those are what the cache's adders see -- the
// same shape as before this change.
//
// NO SYNCHRONISERS, for the reason m2_sdram_x2 has none: clk_sys is an exact
// /2 of clk_mem off one PLL, so this is a ratio, not a crossing. Slow
// registers are stable across two fast cycles, fast registers are read by the
// slow side through one slow-domain register (f_wp -> s_wp_q), and STA times
// every one of these paths at the fast period.
//
// LOSSLESS BY CONSTRUCTION, WITH ONE ESCAPE. m2_texel answers every request it
// accepts -- a miss that never returns is answered by its own timeout -- and
// (R539) its sweep now waits for its queue to drain. What it does NOT do is
// accept while it sweeps, which is 4,096 fast cycles. A request the cache has
// not accepted after TO_CYC cycles, with nothing older still unanswered, is
// answered HERE as 0xF, the value unwritten memory reads, so a sweep or a dead
// cache never stops the band. That is the job m2_span_tex's own 511-cycle
// timeout used to do, moved to where it can keep the answers in order.

`timescale 1ns/1ps

module m2_texel_x2 #(
  parameter int unsigned K      = 4,      // fetches in flight; a power of two
  parameter int unsigned TO_CYC = 1023    // fast cycles before a local answer
) (
  input  logic        clk_slow,       // clk_sys
  input  logic        clk_fast,       // clk_mem
  input  logic        rst_n,

  // ---------------------------------------------- requester, slow (clk_sys)
  input  logic        s_req,          // one-cycle issue, payload valid with it
  output logic        s_rdy,          // a credit is free: s_req may be raised
  input  logic [31:0] s_tex,
  input  logic [19:0] s_u, s_v,
  output logic        s_ack,          // an answer is standing, in issue order
  output logic [3:0]  s_texel,
  input  logic        s_take,         // the requester takes it this cycle

  // ------------------------------------------------- m2_texel, fast (clk_mem)
  output logic        f_req,
  input  logic        f_rdy,          // the cache accepts when f_req & f_rdy
  input  logic        f_ack,
  output logic [31:0] f_tex,
  output logic [19:0] f_u, f_v,
  input  logic [3:0]  f_texel
);

  localparam int unsigned PW = $clog2(K) + 1;   // one spare bit: full vs empty

  // ------------------------------------------------------------- slow side
  logic [PW-1:0] s_ip;                 // requests issued
  logic [PW-1:0] s_rp;                 // answers taken
  logic [PW-1:0] s_wp_q;               // answers written, seen a slow cycle late
  logic [31:0]   q_tex [K];
  logic [19:0]   q_u [K], q_v [K];

  always_ff @(posedge clk_slow or negedge rst_n) begin
    if (!rst_n) begin
      s_ip <= '0; s_rp <= '0; s_wp_q <= '0;
    end else begin
      s_wp_q <= f_wp;
      if (s_req && s_rdy) s_ip <= s_ip + 1'd1;
      if (s_ack && s_take) s_rp <= s_rp + 1'd1;
    end
  end
  // The payload queue is written only on issue and never reset (a memory).
  always_ff @(posedge clk_slow) begin
    if (s_req && s_rdy) begin
      q_tex[s_ip[PW-2:0]] <= s_tex;
      q_u  [s_ip[PW-2:0]] <= s_u;
      q_v  [s_ip[PW-2:0]] <= s_v;
    end
  end

  // Credits count from issue to TAKE, so an answer still waiting in the
  // response queue holds its slot and the queue cannot be overrun.
  assign s_rdy = ((s_ip - s_rp) != PW'(K));
  assign s_ack = (s_wp_q != s_rp);

  // ------------------------------------------------------------- fast side
  logic [PW-1:0] f_ld;                 // requests loaded into the f_* registers
  logic [PW-1:0] f_sent;               // requests the cache has accepted
  logic [PW-1:0] f_wp;                 // answers written
  logic          f_valid;              // f_tex/f_u/f_v hold an unsent request
  logic [3:0]    r_tex [K];
  logic [$clog2(TO_CYC+1)-1:0] f_wait;

  wire f_accept  = f_valid && f_rdy;
  wire f_pending = (s_ip != f_ld);
  // Answer locally only when every older request has been answered, so the
  // local answer lands in its own place in the order.
  wire f_timeout = f_valid && !f_rdy && (f_wp == f_sent)
                && (f_wait == ($clog2(TO_CYC+1))'(TO_CYC));

  always_ff @(posedge clk_fast or negedge rst_n) begin
    if (!rst_n) begin
      f_ld <= '0; f_sent <= '0; f_wp <= '0; f_valid <= 1'b0; f_wait <= '0;
      f_tex <= '0; f_u <= '0; f_v <= '0;
    end else begin
      // The presentation register: refilled from the queue the cycle its
      // request leaves, so the cache can take one every fast cycle.
      if ((!f_valid || f_accept || f_timeout) && f_pending) begin
        f_tex   <= q_tex[f_ld[PW-2:0]];
        f_u     <= q_u  [f_ld[PW-2:0]];
        f_v     <= q_v  [f_ld[PW-2:0]];
        f_ld    <= f_ld + 1'd1;
        f_valid <= 1'b1;
      end else if (f_accept || f_timeout) begin
        f_valid <= 1'b0;
      end

      if (f_accept || f_timeout) f_sent <= f_sent + 1'd1;

      if (!f_valid || f_rdy) f_wait <= '0;
      else if (f_wait != ($clog2(TO_CYC+1))'(TO_CYC)) f_wait <= f_wait + 1'd1;

      // Answers, in order. The cache's and the local one cannot coincide: the
      // local one needs every accepted request already answered.
      if (f_ack || f_timeout) f_wp <= f_wp + 1'd1;
    end
  end
  always_ff @(posedge clk_fast) begin
    if (f_ack)          r_tex[f_wp[PW-2:0]] <= f_texel;
    else if (f_timeout) r_tex[f_wp[PW-2:0]] <= 4'hf;
  end

  assign f_req   = f_valid;
  assign s_texel = r_tex[s_rp[PW-2:0]];

endmodule
