// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// A valid/ready handshake across two genuinely unrelated clocks.
//
// THIS IS A REAL CLOCK-DOMAIN CROSSING, UNLIKE m2_sdram_x2 AND m2_texel_x2.
//
// Those two say plainly that they are NOT crossings: clk_sys is an exact /2 of
// clk_mem off one PLL, the edges are aligned, and every slow signal is stable
// across two fast cycles. That argument is what lets them carry no
// synchronisers at all, and Model2.sdc puts those clocks in ONE group so the
// paths through them are timed rather than ignored.
//
// clk_3d is 60 MHz against clk_sys's 50 and clk_mem's 100. 3:5 and 3:10 are not
// integer ratios: the edges realign only every 50 ns, and the closest a launch
// edge comes to a capture edge is 3.333 ns. Timing 400,000 paths at 3.333 ns is
// not a design, so clk_3d goes in its own clock group and the paths are cut --
// which means they need synchronising for real.
//
// MODEL 1 IS THE ORACLE HERE and it does exactly this. Its clk_3d (58.947) sits
// at 19:14 against clk_sys (80) -- worse than ours, a minimum edge separation of
// 0.893 ns -- and every cross-pair in its timing report reads `false path`. What
// makes that safe is that nothing time-critical crosses: a single toggle bit
// goes over, the data is held stable beside it, and the receiver captures the
// data when it sees the toggle change. m1_raster3d says so at its disp_tog:
//
//   "the data is held stable, a single toggle bit crosses, and the receiver
//    captures the data when it sees the toggle change. The toggle flips one
//    clk_3d cycle AFTER the data, so by the time it has been through two
//    synchroniser flops the data has been stable for longer than the crossing."
//
// and, in the same comment, the warning that matters most for this module:
//
//   "NONE OF THIS CAN APPEAR IN THE BENCHES. render3d ticks both clocks from one
//    edge and tb_m1_frame drives them from exact multiples, so neither has any
//    way to produce a settling failure. It is a hardware-only fault by
//    construction, which is why two throughput fixes measured well and changed
//    nothing on the board."
//
// So a green simulation of this module proves the PROTOCOL and says nothing
// about the crossing. The protocol is what is written here; the crossing is
// safe because of the structure, not because a bench agreed.
//
// TWO-PHASE, NOT FOUR. A four-phase handshake needs the request to return to
// zero and be seen doing it, which is four synchroniser trips a transfer. Two
// phases carry the request in the TOGGLE rather than the level, so one trip
// each way retires a transfer: about 2 clk_dst cycles out and 2 clk_src back.
//
// WHY ONE ENTRY IS ENOUGH HERE, stated because it would not be everywhere. At
// 60/50 a transfer costs roughly 2*16.7 + 2*20 = 73 ns. The geometry stage
// hands over about 2,000 quads a frame, so the crossing costs ~0.15 ms of a
// 16.7 ms frame -- under 1%. A path that moved 45,000 items a frame would need
// a FIFO instead, and the texel fetch is exactly that case; see m2_texel_x2.
//
// DATA IS NOT SYNCHRONISED AND MUST NOT BE. Only the toggle crosses. `data_r`
// is written on clk_src one cycle before the toggle flips and is not touched
// again until the destination has acknowledged, so by the time the toggle has
// cleared two flops the data has been stable for at least two source cycles.
// Putting synchronisers on a multi-bit bus is the fault m2_raster3d's own
// comment calls "a mistake this project has already made twice" -- each bit
// settles independently and the receiver can latch a value that never existed.

`timescale 1ns/1ps

module m2_handshake_cdc #(
  parameter int unsigned W = 32
) (
  // ---------------------------------------------------------- source domain
  input  logic         clk_src,
  input  logic         rst_n_src,
  input  logic         s_valid,
  output logic         s_ready,
  input  logic [W-1:0] s_data,

  // ----------------------------------------------------- destination domain
  input  logic         clk_dst,
  input  logic         rst_n_dst,
  output logic         d_valid,
  input  logic         d_ready,
  output logic [W-1:0] d_data
);

  // The toggle pair. `req_tog` flips when the source accepts an item, `ack_tog`
  // when the destination takes it. Equal means idle, different means in flight.
  logic         req_tog;
  logic         ack_tog;
  logic [W-1:0] data_r;

  // Synchronisers. Two flops each, and they carry ONE bit each by construction.
  logic [1:0] req_s;      // req_tog seen in the destination domain
  logic [1:0] ack_s;      // ack_tog seen in the source domain

  // ------------------------------------------------------------ source side
  //
  // Ready exactly when nothing is in flight. The destination's acknowledge has
  // to come all the way back before the next item is accepted, which is what
  // makes one data register sufficient: it cannot be overwritten while the
  // destination might still be reading it.
  assign s_ready = (req_tog == ack_s[1]);

  always_ff @(posedge clk_src or negedge rst_n_src) begin
    if (!rst_n_src) begin
      req_tog <= 1'b0;
      ack_s   <= 2'b00;
      data_r  <= '0;
    end else begin
      ack_s <= {ack_s[0], ack_tog};
      if (s_valid && s_ready) begin
        data_r  <= s_data;
        req_tog <= ~req_tog;
      end
    end
  end

  // ------------------------------------------------------- destination side
  //
  // Valid while the synchronised request disagrees with our acknowledge. d_data
  // is driven straight from data_r: it has been stable since before req_tog
  // flipped, and req_tog has since been through two flops here.
  assign d_valid = (req_s[1] != ack_tog);
  assign d_data  = data_r;

  always_ff @(posedge clk_dst or negedge rst_n_dst) begin
    if (!rst_n_dst) begin
      ack_tog <= 1'b0;
      req_s   <= 2'b00;
    end else begin
      req_s <= {req_s[0], req_tog};
      if (d_valid && d_ready) ack_tog <= ~ack_tog;
    end
  end

endmodule
