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
  parameter int unsigned COL_BITS = 10,    // m2_sdram's, in 16-bit words: a row is 2^(COL_BITS-1) dwords
  // R696: 1 keeps the whole last answer {N, N+1} until a miss replaces it
  // (the engine); 0 is R214's rule, N+1 for one request (the walker, whose
  // list the game patches behind it -- R266).
  parameter bit          KEEP_LAST = 1'b0
)(
  input  logic          clk,
  input  logic          rst_n,
  // the requester
  input  logic          bypass,   // R244: keep no copy at all, so every read is a port read
  // R266: THE COPY IS DROPPED WHEN ANOTHER MASTER WRITES THE MEMORY BEHIND IT.
  // The copy is only safe while nothing else changes the dword it holds, and
  // the display list is written by the CPU while the walker reads it: Daytona
  // patches a command's count in AFTER pushing the payload (R254), so a copy
  // taken before the patch serves the placeholder. On the board, turning the
  // cache off outright moved the luminance from pegged-at-255 to a healthy
  // median of 149 with no black polygons -- the user saw it before the capture
  // confirmed it. This keeps R214's halving of port trips and drops the copy
  // the moment the memory under it moves.
  input  logic          inval,
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

  // R696: THE WHOLE LAST ANSWER IS KEPT, BOTH DWORDS, until a miss replaces it.
  // It used to keep only N+1 and drop it after one use; but the engine reads
  // 16-bit halves one at a time -- a texture header's four words, a vertex's
  // eight coordinates -- so it asks for the SAME dword twice in a row, and
  // each second ask was a port trip. tb_m2_geodiff (w1000, 12-cycle port):
  // port trips 40,411 -> 28,800, the list 1.20 -> 1.09 vblanks. The copy is
  // still dropped on a write by another master (inval, R266) and never kept
  // in bypass; a stale word can now live until the next miss rather than
  // the next read -- a few reads in a stream that never pauses.
  logic          have_lo, have_hi;   // dword N, dword N+1 valid
  logic [AW-1:0] have_idx;           // N
  logic [31:0]   have_lo_d, have_hi_d;
  logic          hit_pend;  // a hit waiting for the acknowledge line to be clear
  logic          hit_ack;   // the one-cycle acknowledge of a hit
  logic          pass;      // this request is the port's
  logic          pass_ack;  // the port's acknowledge, registered beside its data
  logic          req_d, p_ack_d;
  logic          inval_pend;   // R698: an invalidate arrived while the port read was out

  wire new_req = req && !req_d;
  wire match_lo = have_lo && (idx == have_idx);
  wire match_hi = have_hi && (idx == have_idx + 1'b1);
  wire match    = match_lo || match_hi;
  // A HIT IS ACKNOWLEDGED ONLY ONCE THE PREVIOUS ACKNOWLEDGE HAS FALLEN. The
  // adapter holds its acknowledge until the request drops and the copy here
  // adds a register, so a hit that follows a miss by one cycle would raise
  // its pulse while the line is still up and the requester, which takes the
  // rising edge, would never see it. (Found by the bench: every odd word of
  // a sequential stream "never acknowledged".)
  wire fire    = hit_pend && !pass_ack && !p_ack;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      have_lo <= 1'b0; have_hi <= 1'b0; have_idx <= '0; have_lo_d <= '0; have_hi_d <= '0;
      hit_pend <= 1'b0; hit_ack <= 1'b0; pass <= 1'b0; pass_ack <= 1'b0;
      req_d <= 1'b0; p_ack_d <= 1'b0; data <= '0; inval_pend <= 1'b0;
    end else begin
      req_d    <= req;
      p_ack_d  <= p_ack;
      pass_ack <= pass & p_ack;      // one cycle behind p_ack, level with `data`
      hit_ack  <= fire;
      if (fire) hit_pend <= 1'b0;
      if (!req) pass <= 1'b0;
      if (inval) begin have_lo <= 1'b0; have_hi <= 1'b0; end   // R266: another master wrote the memory
      // R698: A READ IN FLIGHT ACROSS AN INVALIDATE may carry the old words, and a
      // kept copy (KEEP_LAST) would serve them long after; its answer is used
      // for the request that asked, and not kept.
      if (inval && pass) inval_pend <= 1'b1;
      if (new_req) begin
        if (!KEEP_LAST) have_hi <= 1'b0;       // R214: the copy serves one request, or none
        if (match) begin hit_pend <= 1'b1; data <= match_lo ? have_lo_d : have_hi_d; end
        else       pass <= 1'b1;
      end
      // The port's answer, on the rising edge of its acknowledge: the low
      // half for the requester, and both halves kept as N and N+1.
      if (p_ack && !p_ack_d) begin
        data      <= p_dout[31:0];
        have_lo   <= KEEP_LAST && !bypass && !inval && !inval_pend;
        have_hi   <= ~&idx[COL_BITS-2:0] && !bypass && !inval && !inval_pend;   // the last dword of a row: its pair wrapped
        inval_pend <= 1'b0;
        have_idx  <= idx;
        have_lo_d <= p_dout[31:0];
        have_hi_d <= p_dout[63:32];
      end
    end
  end

  assign p_req = pass & req;
  assign p_idx = idx;
  // Both acknowledges are registered so that `data` is valid on the cycle
  // the requester sees the rising edge, as the glue's registered pair was.
  assign ack   = hit_ack | pass_ack;

endmodule
