// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// The SDRAM ports across an ASYNCHRONOUS boundary: requesters on the core
// clock, m2_sdram on clk_mem, at any ratio. Replaces m2_sdram_x2 (study R561).
//
// WHY m2_sdram_x2 CANNOT STAY. It is not a crossing: it relies on clk_sys
// being an exact /2 of clk_mem, so that every slow signal is stable across two
// fast cycles and every path is timed at 10 ns. At 100 and 60 the two line up
// as five to three and the tightest launch-to-latch window is 3.33 ns (R228);
// the build that tried it missed by exactly that.
//
// THE SLOW SIDE'S CONTRACT IS m2_sdram_x2's, UNCHANGED, so no requester moves:
//
//   * `s_req` is a level, raised with its address and write data and held --
//     with them -- until `s_ack`, then lowered for at least one slow cycle.
//     R34 is what established that every requester here holds its address.
//   * `s_ack` is sticky while the request stands (R162): a requester that was
//     not looking on the first cycle sees it on the next.
//   * `s_dout` is valid with `s_ack` and stays valid until the next request.
//
// HOW, Model 1's m1_cdc_port shape with two differences taken from this
// controller's own guarantees:
//
//   REQUEST: the level crosses through two flops. m2_sdram takes one
//   transaction per RISING EDGE of p_req and captures address and data on that
//   edge, so `f_req` is the synchronised level masked from the acknowledge
//   until the level falls. A one-slow-cycle gap is 16.7 ns at 60 MHz, longer
//   than a 10 ns fast cycle, so the fast side always sees it.
//
//   COMPLETION: a TOGGLE per acknowledge, edge-detected on the slow side. A
//   synchronised level would have to fall and be seen falling before the next
//   request's acknowledge could be told apart from the last one's -- a race
//   against the SDRAM's own latency. A toggle has no return-to-zero to race.
//
//   NO PAYLOAD REGISTERS, either way. m1_cdc_port captures address, data and
//   read data in registers of its own; here the requester already holds the
//   address and write data for the whole transaction, and m2_sdram holds
//   p_dout[port] from its acknowledge until that PORT completes again (R557's
//   delivery writes only the delivering port). The fast side samples the
//   address two fast cycles after the level that announced it; the slow side
//   reads the data two slow cycles after the toggle that announced it. Both
//   have been still for longer than any metastability window. Synchronising a
//   bus bit by bit would be actively wrong: the bits would arrive skewed.
//
// FAST-NATIVE PORTS. The texel cache and the character cache run on clk_mem
// and need no crossing; FAST[g] passes such a port through with
// m2_sdram_x2's logic exactly, in the fast domain.
//
// THE COST, stated so it is not rediscovered: two fast cycles on the way in
// and two slow cycles on the way back, per transaction, over m2_sdram_x2.
//
// WHAT tb_m2_sdram_cdc CAN AND CANNOT SEE (mutations, 100/60, 2:1 and 3.3:1):
//   * completion as a synchronised LEVEL instead of a toggle: 21,859 failures
//     -- a request re-raised after a one-cycle gap takes the previous
//     transaction's acknowledge and data, and writes are acknowledged that
//     never happened;
//   * `s_ack` not gated by `s_req`: 5,023 -- an acknowledge still showing the
//     cycle after the request fell, which m2_sdram_x2 never gave and which a
//     requester registering `ack` ungated would count twice;
//   * `f_req` not masked by `done`: NOTHING. m2_sdram latches on the request's
//     edge, so a held level cannot re-request. Kept for the reason
//     m2_sdram_x2 keeps it, and said here so a green suite is not read as
//     proof that it is load-bearing;
//   * single-flop synchronisers: nothing, and nothing in simulation can.

`timescale 1ns/1ps

module m2_sdram_cdc_port (
  input  logic        clk_slow,
  input  logic        s_rst_n,
  input  logic        clk_fast,
  input  logic        f_rst_n,

  input  logic        s_req,
  output logic        s_ack,

  output logic        f_req,
  input  logic        f_ack
);

  // ------------------------------------------------------------- fast side
  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
  logic rq1;
  logic rq2, done, ack_tog;
  always_ff @(posedge clk_fast or negedge f_rst_n) begin
    if (!f_rst_n) begin
      rq1 <= 1'b0; rq2 <= 1'b0; done <= 1'b0; ack_tog <= 1'b0;
    end else begin
      rq1 <= s_req;
      rq2 <= rq1;
      // Cleared only by the requester lowering its level: that is the one event
      // meaning "this transaction is finished with" (m2_sdram_x2 hazard 2).
      if (!rq2)                begin done <= 1'b0; end
      else if (f_ack && !done) begin done <= 1'b1; ack_tog <= ~ack_tog; end
    end
  end
  // Masked from the acknowledge itself as well as from `done` a cycle later.
  // Not load-bearing against this controller -- see the header.
  assign f_req = rq2 & ~done & ~f_ack;

  // ------------------------------------------------------------- slow side
  (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
  logic at1;
  logic at2, at3, acked;
  always_ff @(posedge clk_slow or negedge s_rst_n) begin
    if (!s_rst_n) begin
      at1 <= 1'b0; at2 <= 1'b0; at3 <= 1'b0; acked <= 1'b0;
    end else begin
      at1 <= ack_tog;
      at2 <= at1;
      at3 <= at2;
      if (!s_req)          acked <= 1'b0;
      else if (at2 ^ at3)  acked <= 1'b1;
    end
  end
  // The edge itself as well as the held flag, so the acknowledge is seen on
  // the cycle the toggle lands rather than one later. Sticky until the level
  // falls, and gone the cycle after: a request raised again after one idle
  // cycle cannot see the last transaction's acknowledge.
  assign s_ack = s_req & (acked | (at2 ^ at3));

endmodule

module m2_sdram_cdc #(
  parameter int unsigned  NP   = 5,
  parameter int unsigned  AW   = 25,
  parameter logic [NP-1:0] FAST = '0     // ports whose requester is on clk_fast
) (
  input  logic                clk_slow,
  input  logic                s_rst_n,
  input  logic                clk_fast,
  input  logic                f_rst_n,

  // ---- slow side (or fast, for a FAST port): the requesters
  input  logic [NP-1:0]         s_req,
  input  logic [NP-1:0][AW:1]   s_addr,
  output logic [NP-1:0]         s_ack,
  output logic [NP-1:0][63:0]   s_dout,
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
      if (FAST[g]) begin : g_fast
        // m2_sdram_x2's port, one domain: see that file for both hazards.
        logic done;
        always_ff @(posedge clk_fast) begin
          if (!s_req[g])     done <= 1'b0;
          else if (f_ack[g]) done <= 1'b1;
        end
        assign f_req[g] = s_req[g] & ~done & ~f_ack[g];
        assign s_ack[g] = f_ack[g] | done;
      end else begin : g_slow
        m2_sdram_cdc_port u_port (
          .clk_slow(clk_slow), .s_rst_n(s_rst_n),
          .clk_fast(clk_fast), .f_rst_n(f_rst_n),
          .s_req(s_req[g]), .s_ack(s_ack[g]),
          .f_req(f_req[g]), .f_ack(f_ack[g])
        );
      end
      assign f_addr[g] = s_addr[g];
      assign f_we[g]   = s_we[g];
      assign f_din[g]  = s_din[g];
      assign f_be[g]   = s_be[g];
      // Held by m2_sdram from this port's acknowledge until its next one.
      assign s_dout[g] = f_dout[g];
    end
  endgenerate

  // The loader's write port: always a slow-side requester.
  m2_sdram_cdc_port u_wr (
    .clk_slow(clk_slow), .s_rst_n(s_rst_n),
    .clk_fast(clk_fast), .f_rst_n(f_rst_n),
    .s_req(s_wr_req), .s_ack(s_wr_ack),
    .f_req(f_wr_req), .f_ack(f_wr_ack)
  );
  assign f_wr_addr = s_wr_addr;
  assign f_wr_din  = s_wr_din;
  assign f_wr_be   = s_wr_be;

endmodule
