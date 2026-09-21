// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// Carries the texel request from the span walk to m2_texel.
//
// R467: THIS IS A REAL CLOCK-DOMAIN CROSSING NOW, AND IT WAS NOT BEFORE.
//
// What this file used to say, correctly, at 50:100 --
//
//   "NO SYNCHRONISERS, DELIBERATELY, and for the same reason m2_sdram_x2 has
//    none: clk_sys is an exact /2 of clk_mem off the same PLL, so this is a
//    ratio, not a domain crossing."
//
// -- stopped being true the moment the renderer moved to clk_3d. The slow side
// is 60 MHz against clk_mem's 100: 3:5, edges realigning only every 50 ns, and
// Model2.sdc puts general[2] in its own clock group so these paths are CUT.
//
// An unsynchronised signal over a cut path is the worst shape of fault this
// project has: the timing violation that would have pointed at it is exactly
// what the cut removes, and Model 1 records the consequence at m1_raster3d --
// "a hardware-only fault by construction, which is why two throughput fixes
// measured well and changed nothing on the board".
//
// THE MISS THAT PRODUCED THIS FILE. R465 listed every signal crossing into
// clk_3d and concluded "tex_m_* does NOT cross: m2_texel is on clk_mem". That
// is true of the SDRAM master and false of the REQUEST: txf_req/txf_ack run
// between m2_span_tex on clk_3d and m2_texel on clk_mem, straight through here.
// The inventory was written and the one entry that mattered was left off it.
//
// WHAT CROSSES AND WHAT DOES NOT
//
//   s_req   -> two flops into clk_fast. A level, held until acknowledged.
//   done    -> two flops back into clk_slow, and that is what s_ack is.
//   tex/u/v -> NOT synchronised, on purpose. They are captured in registers
//              that cannot change while a request is outstanding, and the fast
//              side samples them two or more clocks after the request that
//              announced them. Synchronising a multi-bit bus would be actively
//              wrong: the bits settle independently and the reader can latch a
//              value that never existed. m1_cdc_port makes the same argument.
//   texel   -> likewise: written on the fast side while `done` is high and read
//              on the slow side only once the synchronised `done` has arrived,
//              by which point it has been stable for several fast cycles.
//
// WHAT IT COSTS, SAID PLAINLY. Four synchroniser trips per fetch -- request
// out, acknowledge back, request down, acknowledge down -- is roughly 50 ns,
// against 45,835 fetches a frame. That is ~2.3 ms of a 16.7 ms frame, and it
// lands on the texture path, which is already the renderer's bottleneck.
//
// THE FIX FOR THAT IS NOT HERE. It is to let the span walk keep several
// fetches in flight so the latency pipelines instead of serialising; today
// m2_span_tex blocks in T_FETCH until the acknowledge returns. This module's
// job is to be CORRECT across the cut. Being fast is m2_span_tex's job.

`timescale 1ns/1ps

module m2_texel_x2 (
  input  logic        clk_fast,       // clk_mem, 100 MHz
  input  logic        clk_slow,       // clk_3d, 60 MHz -- R467: unrelated now
  input  logic        rst_n,

  // ---------------------------------------------- requester, slow (clk_3d)
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

  // ------------------------------------------------------------- fast domain
  logic       req_s1, req_s2;   // s_req, synchronised in
  logic       done;
  logic [3:0] texel_r;

  always_ff @(posedge clk_fast or negedge rst_n) begin
    if (!rst_n) begin
      req_s1 <= 1'b0; req_s2 <= 1'b0; done <= 1'b0; texel_r <= 4'd0;
    end else begin
      req_s1 <= s_req;
      req_s2 <= req_s1;
      // Cleared by the slow side lowering its request, which is the only event
      // that means "this fetch is finished with" -- seen here two fast cycles
      // after it actually happens, which is the price of the crossing.
      if (!req_s2)    done <= 1'b0;
      else if (f_ack) done <= 1'b1;
      if (f_ack) texel_r <= f_texel;
    end
  end

  // Masked from the acknowledge itself rather than from the registered `done` a
  // cycle later: m2_texel takes a request while `req` is high, and one more
  // fast cycle of a held request is one more chance for it to start a second
  // fetch.
  assign f_req = req_s2 & ~done & ~f_ack;
  assign f_tex = s_tex;
  assign f_u   = s_u;
  assign f_v   = s_v;

  // ------------------------------------------------------------- slow domain
  //
  // `done` rather than `f_ack`: f_ack is a fast-domain pulse and could be gone
  // before a slow edge ever sees it, which at 3:5 it frequently would be. done
  // is a level that stands until the requester drops its request, so the slow
  // side cannot miss it however the edges fall. This is the R162 argument, and
  // it matters more here than it did at 2:1 -- a missed acknowledge wedges the
  // port permanently, and the coprocessor with it.
  logic ack_s1, ack_s2;
  always_ff @(posedge clk_slow or negedge rst_n) begin
    if (!rst_n) begin ack_s1 <= 1'b0; ack_s2 <= 1'b0; end
    else        begin ack_s1 <= done; ack_s2 <= ack_s1; end
  end

  assign s_ack   = ack_s2;
  // No bypass on the acknowledge cycle any more, and none is needed: texel_r is
  // written on the fast edge that raised `done`, and s_ack cannot assert until
  // that has been through two slow flops. The data has been stable for at
  // least two slow cycles by the time anything reads it.
  assign s_texel = texel_r;

endmodule
