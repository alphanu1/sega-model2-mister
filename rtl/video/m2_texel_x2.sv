// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// Carries the texel request across the 2:1 between clk_sys and clk_mem.
//
// WHY m2_texel MOVES AND m2_span_tex DOES NOT. A texel miss is ~280 ns, of
// which roughly 160 ns is the SDRAM round trip and 120 ns is m2_texel's own
// state machine. Only the second half scales with the clock, and halving it
// makes each fetch ~27% faster -- which is what the span walk's throughput on
// TEXTURED spans is limited by (R309). The span queue (R310) was meant to
// absorb that and could not: a queue absorbs BURSTS, and this is a sustained
// rate mismatch, so 32 entries drained in well under a millisecond and the
// fill stalled again exactly as before.
//
// THE ACK IS THE WHOLE PROBLEM. m2_texel raises `ack` for ONE cycle. At 100 MHz
// that is 10 ns, and a consumer on the 50 MHz clock samples every 20 ns -- so it
// would miss half of them, and a missed acknowledge hangs the span walk in
// T_FETCH until its 511-cycle timeout. This is the same fault m2_sdram_x2 was
// built for and it takes the same answer: latch `done` on the acknowledge and
// hold the slow side's ack up until the requester drops its request.
//
// NO SYNCHRONISERS, DELIBERATELY, and for the same reason m2_sdram_x2 has none:
// clk_sys is an exact /2 of clk_mem off the same PLL, so this is a ratio, not a
// domain crossing. The request, tex, u and v are captured in registers that
// cannot change while a request is outstanding, and the fast side samples them
// a whole fast cycle after the request went up.

`timescale 1ns/1ps

module m2_texel_x2 (
  input  logic        clk_fast,       // clk_mem
  input  logic        rst_n,

  // ---------------------------------------------- requester, slow (clk_sys)
  input  logic        s_req,
  output logic        s_ack,
  input  logic [31:0] s_tex,
  input  logic [19:0] s_u, s_v,
  output logic [3:0]  s_texel,

  // ------------------------------------------------- m2_texel, fast (clk_mem)
  output logic        f_req,
  input  logic        f_ack,
  output logic [31:0] f_tex,
  output logic [19:0] f_u, f_v,
  input  logic [3:0]  f_texel
);

  logic       done;
  logic [3:0] texel_r;

  always_ff @(posedge clk_fast or negedge rst_n) begin
    if (!rst_n) begin
      done <= 1'b0; texel_r <= 4'd0;
    end else begin
      // Cleared by the slow side lowering its request, which is the only event
      // that means "this fetch is finished with".
      if (!s_req)     done <= 1'b0;
      else if (f_ack) done <= 1'b1;
      if (f_ack) texel_r <= f_texel;
    end
  end

  // Masked from the acknowledge itself, not from the registered `done` a cycle
  // later: m2_texel takes a request while `req` is high, and one more fast cycle
  // of a held request is one more chance for it to start a second fetch.
  assign f_req   = s_req & ~done & ~f_ack;
  assign f_tex   = s_tex;
  assign f_u     = s_u;
  assign f_v     = s_v;

  assign s_ack   = f_ack | done;
  // Bypassed on the acknowledge cycle: texel_r does not load until the fast
  // edge AFTER f_ack, and the slow edge can land on either.
  assign s_texel = f_ack ? f_texel : texel_r;

endmodule
