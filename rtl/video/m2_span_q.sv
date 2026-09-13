// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// A SHALLOW REGISTER QUEUE BETWEEN THE FILL AND THE SPAN WALK.
//
// WHY NOT m2_fifo_m10k, WHICH ALREADY EXISTS. Two reasons, and the second is
// the important one.
//
//   * IT COSTS 30 M10K HERE, not the seven a 242-bit payload should need.
//     Quartus maps it narrow-and-deep -- roughly 1024x10 -- so it holds about
//     2,065 bits per block against a possible 10,240. Measured in build/fifo1,
//     where it ate the exact 30 blocks the texel cache had just released and
//     left the device still at 553/553.
//
//   * IT ADDS LATENCY TO EVERY SPAN. Its own comment: "after a pop the next
//     word takes two cycles to reach the head, so q_valid falls between
//     back-to-back pops." That bubble is harmless for the coprocessor, which
//     pops slowly. Here it would be paid per span, on the path this queue
//     exists to shorten -- which defeats the purpose.
//
// This queue has NO BUBBLE: the head is a register read combinationally, so a
// pop and a push in the same cycle both land. It costs one cycle of pipeline
// DEPTH -- a one-time delay, not a per-span one -- and throughput is unchanged.
//
// It is deliberately SHALLOW. The point is to absorb a texel fetch, which is
// about fourteen cycles, while the fill emits a span every four to eight. Four
// to eight entries covers that; 256 was over-provisioning for "free" depth that
// was not free.
//
// FULL MEANS STALL, NEVER DROP. m2_fifo_m10k's `full` retires the TGP's pushes
// silently because the i960 must not be held. A silently dropped span is a hole
// in the picture, so `in_ready` falls instead and m2_raster_fill waits, which
// its span_valid/span_ready handshake already does.

`timescale 1ns/1ps

module m2_span_q #(
  parameter int unsigned DW    = 242,
  parameter int unsigned DEPTH = 8      // must be a power of two
) (
  input  logic          clk,
  input  logic          rst_n,

  input  logic          in_valid,
  output logic          in_ready,
  input  logic [DW-1:0] in_data,

  output logic          out_valid,
  input  logic          out_ready,
  output logic [DW-1:0] out_data,

  // High while anything is held. The band sequencer may not call a band
  // finished while a span it produced is still in here (R310).
  output logic          busy,
  output logic [7:0]    count
);

  localparam int unsigned AW = $clog2(DEPTH);

  // NEVER CLEARED IN RESET, which is what lets Quartus keep it as registers
  // without a reset fanout across DW*DEPTH bits. Nothing reads a slot that was
  // not written: `cnt` gates every read.
  logic [DW-1:0]   mem [DEPTH];
  logic [AW-1:0]   wptr, rptr;
  logic [AW:0]     cnt;

  wire empty = (cnt == '0);
  wire full  = (cnt == (AW+1)'(DEPTH));

  wire do_push = in_valid  && in_ready;
  wire do_pop  = out_valid && out_ready;

  assign in_ready  = !full;
  assign out_valid = !empty;
  assign out_data  = mem[rptr];
  assign busy      = !empty;
  assign count     = 8'(cnt);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wptr <= '0; rptr <= '0; cnt <= '0;
    end else begin
      if (do_push) begin
        mem[wptr] <= in_data;
        wptr      <= wptr + 1'b1;
      end
      if (do_pop) rptr <= rptr + 1'b1;
      // One counter, both directions: a simultaneous push and pop is a no-op
      // on the count and both pointers still move.
      case ({do_push, do_pop})
        2'b10:   cnt <= cnt + 1'b1;
        2'b01:   cnt <= cnt - 1'b1;
        default: ;
      endcase
    end
  end

endmodule
