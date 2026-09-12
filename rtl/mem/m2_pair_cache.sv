// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// m2_pair_cache -- the second dword of a port's 64-bit return, kept for the
// next request (R214).
//
// m2_sdram answers a read with four consecutive 16-bit words: the dword at
// the requested index in [31:0] and the NEXT dword in [63:32] (it issues the
// four columns one by one at burst length 1, so there is no burst wrap). The
// display-list walker and the geometry engine read their streams one dword
// at a time and use only the low half, paying the whole port round trip --
// about ten clk_sys cycles through the registered glue and the adapter
// (R208) -- for every word. On the board that put the collect at 7-14 ms
// and held lists for three video frames (dbuf6 s14, R213).
//
// This sits between one requester and its port. A request for index N goes
// to the port; its answer's upper half is remembered as index N+1. A request
// for N+1 that follows is answered from that copy in one cycle, without the
// port. The copy is used ONCE and dropped on any other request, so a dword
// the CPU or the TGP rewrites is never served stale for longer than the gap
// between two consecutive reads of a stream.
//
// The requester's handshake is R208's: a level request, the acknowledge
// taken on its rising edge, the request lowered for a cycle after. A hit is
// a one-cycle acknowledge pulse; a miss passes the port's acknowledge
// through, held as the adapter holds it.
//
// THE COPY IS NOT KEPT ACROSS A ROW EDGE (R240). m2_sdram issues its four
// columns by incrementing the column field alone, so a burst that starts on
// the last dword of a row wraps to the row's FIRST words: the port's upper
// half is then dword N+1-ROW, not N+1. A dword index whose column bits are
// all ones therefore keeps nothing, and the next read goes to the port. The
// desk could not show this: the benches serve N+1 from a flat array.
`timescale 1ns/1ps
module m2_pair_cache #(
  parameter int unsigned AW       = 24,
  parameter int unsigned COL_BITS = 10     // m2_sdram's, in 16-bit words: a row is 2^(COL_BITS-1) dwords
)(
  input  logic          clk,
  input  logic          rst_n,
  // the requester
  input  logic          bypass,   // R244: keep no copy at all, so every read is a port read
  input  logic          req,
  input  logic [AW-1:0] idx,
  output logic          ack,
  output logic [31:0]   data,
  // the port
  output logic          p_req,
  output logic [AW-1:0] p_idx,
  input  logic          p_ack,
  input  logic [63:0]   p_dout
);

  logic          have;      // the copy is valid
  logic [AW-1:0] have_idx;
  logic [31:0]   have_data;
  logic          hit_pend;  // a hit waiting for the acknowledge line to be clear
  logic          hit_ack;   // the one-cycle acknowledge of a hit
  logic          pass;      // this request is the port's
  logic          pass_ack;  // the port's acknowledge, registered beside its data
  logic          req_d, p_ack_d;

  wire new_req = req && !req_d;
  wire match   = have && (idx == have_idx);
  // A HIT IS ACKNOWLEDGED ONLY ONCE THE PREVIOUS ACKNOWLEDGE HAS FALLEN. The
  // adapter holds its acknowledge until the request drops and the copy here
  // adds a register, so a hit that follows a miss by one cycle would raise
  // its pulse while the line is still up and the requester, which takes the
  // rising edge, would never see it. (Found by the bench: every odd word of
  // a sequential stream "never acknowledged".)
  wire fire    = hit_pend && !pass_ack && !p_ack;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      have <= 1'b0; have_idx <= '0; have_data <= '0;
      hit_pend <= 1'b0; hit_ack <= 1'b0; pass <= 1'b0; pass_ack <= 1'b0;
      req_d <= 1'b0; p_ack_d <= 1'b0; data <= '0;
    end else begin
      req_d    <= req;
      p_ack_d  <= p_ack;
      pass_ack <= pass & p_ack;      // one cycle behind p_ack, level with `data`
      hit_ack  <= fire;
      if (fire) hit_pend <= 1'b0;
      if (!req) pass <= 1'b0;
      if (new_req) begin
        have <= 1'b0;                          // the copy serves one request, or none
        if (match) begin hit_pend <= 1'b1; data <= have_data; end
        else       pass <= 1'b1;
      end
      // The port's answer, on the rising edge of its acknowledge: the low
      // half for the requester, the high half kept as the next index.
      if (p_ack && !p_ack_d) begin
        data      <= p_dout[31:0];
        have      <= ~&idx[COL_BITS-2:0] && !bypass;   // the last dword of a row: its pair wrapped

        have_idx  <= idx + 1'b1;
        have_data <= p_dout[63:32];
      end
    end
  end

  assign p_req = pass & req;
  assign p_idx = idx;
  // Both acknowledges are registered so that `data` is valid on the cycle
  // the requester sees the rising edge, as the glue's registered pair was.
  assign ack   = hit_ack | pass_ack;

endmodule
