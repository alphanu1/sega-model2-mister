// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// Port adapter for running the SDRAM controller at twice the core clock.
//
// Ported from the Kaneko16 core's `kaneko_sdram_x2.sv` at `6f59d8a`, which
// solved this on the same controller; see THIRD_PARTY.md. Both projects are the
// same author's, and the two hazards below are that file's findings, kept
// because they were each found by a failure rather than by reasoning.
//
// WHY THE CONTROLLER IS NOT SIMPLY GIVEN A FASTER CLOCK
//
// Everything else in this core is in the core domain and cannot follow. The
// i960's bridge, the tilemap copy engine, the character fetch and the ROM
// loader all sit on what is today `clk_sdram`, and raising that clock raises
// all of them. The controller runs at 96 MHz and this sits between, which
// halves every round trip as counted in CORE clocks.
//
// THIS IS NOT A CLOCK-DOMAIN CROSSING, AND THE DISTINCTION MATTERS
//
// Both clocks come from one PLL at an exact 2:1 ratio — 960 MHz VCO, /10 and
// /20 — so their edges are aligned and every slow-domain signal is stable
// across two fast cycles. There is no metastability to synchronise away and no
// synchroniser here. What there IS, is a pulse-width problem in the other
// direction, and two hazards:
//
//   1. An acknowledge has to span exactly one slow cycle: any narrower and the
//      slow domain misses it, any wider and it counts it twice. m2_sdram holds
//      it for ACK_HOLD = 2 fast cycles, which is exactly one slow cycle, so it
//      is passed straight through. Widening it to three let the Kaneko core
//      acknowledge one transaction twice and read the second time into the
//      next one's data.
//
//   2. A requester drops `req` the slow cycle AFTER it sees the acknowledge,
//      so `req` is still high for up to two more fast cycles. A controller that
//      latches on the LEVEL takes that as a second request and reads the same
//      address again. `done` masks the request from the moment it is
//      acknowledged until the slow side actually lowers it.
//
//      NOT LOAD-BEARING AGAINST THIS CONTROLLER, and said plainly so a green
//      suite is not read as proof that it is. m2_sdram latches on the EDGE:
//
//        if (p_req[i] && !req_d[i]) begin
//
//      so a held request cannot re-request, and tb_m2_sdram_x2 passes with this
//      mask deleted -- 2,560 checks, exact transaction count. It edge-detects
//      because study R34 forced it to: the i960 holds its request across a run
//      of accesses and moves the address on the acknowledge. The mask stays
//      because it costs one gate and the property it depends on lives in
//      another file, but its absence would not be caught here.
//
// Addresses need nothing: a requester holds the address for as long as it holds
// `req`, so it is stable across the whole fast-domain transaction. That is a
// property of THIS core's requesters and study R34 is what established it — the
// i960 holds its request across a run of accesses and moves the address on the
// acknowledge, which is why the bridge latches rather than sampling live.

`timescale 1ns/1ps

module m2_sdram_x2 #(
  parameter int unsigned NP = 5,
  parameter int unsigned AW = 25
) (
  input  logic                clk_fast,       // 2x clk_slow, same PLL

  // ---- slow side: this core's requesters
  input  logic [NP-1:0]         s_req,
  input  logic [NP-1:0][AW:1]   s_addr,
  output logic [NP-1:0]         s_ack,
  output logic [NP-1:0][63:0]   s_dout,
  // PER-PORT WRITES, which the Kaneko core's adapter has no equivalent of:
  // this controller lets a port write as well as read, and port 0 does. They
  // are qualified by the same masked `req`, so they need no separate handling
  // — but they must be carried, and a port that could write and silently did
  // not would be a very quiet fault.
  input  logic [NP-1:0]         s_we,
  input  logic [NP-1:0][15:0]   s_din,
  input  logic [NP-1:0][1:0]    s_be,

  input  logic                  s_wr_req,
  input  logic [AW:1]           s_wr_addr,
  input  logic [15:0]           s_wr_din,
  input  logic [1:0]            s_wr_be,
  output logic                  s_wr_ack,

  // ---- fast side: the controller
  output logic [NP-1:0]         f_req,
  output logic [NP-1:0][AW:1]   f_addr,
  input  logic [NP-1:0]         f_ack,
  input  logic [NP-1:0][63:0]   f_dout,
  output logic [NP-1:0]         f_we,
  output logic [NP-1:0][15:0]   f_din,
  output logic [NP-1:0][1:0]    f_be,

  output logic                  f_wr_req,
  output logic [AW:1]           f_wr_addr,
  output logic [15:0]           f_wr_din,
  output logic [1:0]            f_wr_be,
  input  logic                  f_wr_ack
);

  genvar g;
  generate
    for (g = 0; g < NP; g = g + 1) begin : g_port
      logic        done;
      logic [63:0] dout_r;

      always_ff @(posedge clk_fast) begin
        // Cleared by the slow side lowering its request, which is the only
        // event that means "this transaction is finished with".
        if (!s_req[g])     done <= 1'b0;
        else if (f_ack[g]) done <= 1'b1;

        if (f_ack[g]) dout_r <= f_dout[g];
      end

      // Masked from the acknowledge itself, not from the registered `done` a
      // cycle later: the controller takes a request on its rising edge, and one
      // more cycle of a held request is one more chance for it to look like a
      // new one.
      assign f_req[g]  = s_req[g] & ~done & ~f_ack[g];
      assign f_addr[g] = s_addr[g];
      assign f_we[g]   = s_we[g];
      assign f_din[g]  = s_din[g];
      assign f_be[g]   = s_be[g];
      assign s_ack[g]  = f_ack[g];        // already two fast cycles wide

      // BYPASSED ON THE ACKNOWLEDGE CYCLE, not just registered.
      //
      // `dout_r` does not load until the fast edge AFTER f_ack, but f_ack is
      // two fast cycles wide and the slow edge can land on either of them. Land
      // on the first and the slow side latches the previous transaction's data
      // — or zero, on the first read of a port. In the Kaneko core that failed
      // almost exactly half the reads, which is what "half" means here: the two
      // alignments are equally likely and one of them is wrong.
      //
      // m2_sdram writes p_dout and raises p_ack on the SAME edge and holds both
      // until that port completes again, so f_dout is already valid throughout
      // the acknowledge. The register is kept for the cycles after it.
      assign s_dout[g] = f_ack[g] ? f_dout[g] : dout_r;
    end
  endgenerate

  // The loader's write port, same two hazards and the same two answers.
  logic w_done;
  always_ff @(posedge clk_fast) begin
    if (!s_wr_req)     w_done <= 1'b0;
    else if (f_wr_ack) w_done <= 1'b1;
  end

  assign f_wr_req  = s_wr_req & ~w_done & ~f_wr_ack;
  assign f_wr_addr = s_wr_addr;
  assign f_wr_din  = s_wr_din;
  assign f_wr_be   = s_wr_be;
  assign s_wr_ack  = f_wr_ack;

endmodule
