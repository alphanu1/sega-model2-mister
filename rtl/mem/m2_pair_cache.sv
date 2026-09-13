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

  // R295: THE NEXT PAIR, FETCHED WHILE THE ENGINE IS STILL USING THIS ONE.
  //
  // The board says the geometry port spends 43.5% of the frame WANTING the bus
  // while the bus is busy only 46.2% of it -- idle more than half the time.
  // The stream is read one dword at a time and every miss is a full port round
  // trip the engine stands still for (about ten clk_sys cycles, R208); the pair
  // above halves the number of trips but not the waiting, because the trip
  // still happens when the engine asks.
  //
  // So the trip is moved EARLIER. When the port answers a demand read at N it
  // has given us N and N+1; the stream's next want is N+2, and the engine is
  // about to spend cycles transforming N. The prefetch goes out then, on a bus
  // that is idle, and N+2 is in hand before it is asked for.
  //
  // ONE OWNER OF THE PORT AT A TIME, AND THE PREFETCH NEVER MOVES THE ADDRESS
  // UNDER A DEMAND READ: m2_sdram latches on the request's EDGE (R34), so a
  // transaction that is started must be finished. A demand that arrives while
  // a prefetch is in flight waits for it -- which is the trade, and the reason
  // the prefetch is only ever ONE pair deep.
  logic          pf_req;   // a prefetch is on the port
  // WHOSE ACKNOWLEDGE IS ON THE LINE. `pf_req` has to fall on the acknowledge's
  // RISING edge -- the port holds its acknowledge until the request drops, so a
  // request that waits for the acknowledge to fall waits forever, which is the
  // deadlock this flag exists to avoid. `pf_own` outlives it by the length of
  // the held acknowledge, which is what the hit gate needs to know.
  logic          pf_own    /* verilator public_flat_rd */;
  // ONLY A STREAM EARNS A PREFETCH. Started on every miss, the guesses are
  // wrong on random access and a demand then waits behind a useless
  // transaction: measured at 750 port trips for 500 random words against 500,
  // and 13.0 cycles a word against 9.0. A reader walking a stream asks for
  // consecutive dwords, so the previous demand's index is the test -- and the
  // geometry's reads ARE a walk, punctuated by jumps to headers and pointers
  // that this correctly declines to guess at.
  logic [AW-1:0] prev_idx;
  logic          prev_v;
  logic          pf_wait;  // the prefetch in flight is the one being asked for
  logic          pf_v      /* verilator public_flat_rd */;    // a prefetched pair is held
  logic          pf_kill;   // ... and the memory moved under it
  logic [AW-1:0] pf_idx    /* verilator public_flat_rd */;    // the low dword index of that pair
  logic [31:0]   pf_lo, pf_hi;
  logic [AW-1:0] pf_want;   // what to fetch when the port frees up
  logic          pf_arm;    // a prefetch is wanted

  logic          have      /* verilator public_flat_rd */;    // the copy is valid
  logic [AW-1:0] have_idx  /* verilator public_flat_rd */;
  logic [31:0]   have_data;
  logic          hit_pend  /* verilator public_flat_rd */;  // a hit waiting for the acknowledge line to be clear
  logic          hit_ack;   // the one-cycle acknowledge of a hit
  logic          pass;      // this request is the port's
  logic          pass_ack;  // the port's acknowledge, registered beside its data
  logic          req_d, p_ack_d;

  wire new_req = req && !req_d;
  wire match   = have && (idx == have_idx);
  // The prefetched pair answers either of its two dwords.
  wire pf_hit_lo = pf_v && (idx == pf_idx);
  wire pf_hit_hi = pf_v && (idx == pf_idx + 1'b1);
  wire pf_match  = pf_hit_lo || pf_hit_hi;
  // A HIT IS ACKNOWLEDGED ONLY ONCE THE PREVIOUS ACKNOWLEDGE HAS FALLEN. The
  // adapter holds its acknowledge until the request drops and the copy here
  // adds a register, so a hit that follows a miss by one cycle would raise
  // its pulse while the line is still up and the requester, which takes the
  // rising edge, would never see it. (Found by the bench: every odd word of
  // a sequential stream "never acknowledged".)
  // R295: A PREFETCH'S ACKNOWLEDGE IS NOT THE REQUESTER'S, and gating on the
  // raw one costs a whole read. The `!p_ack` above exists so a hit pulse is not
  // raised while the PORT's held acknowledge of a DEMAND read is still up --
  // the requester takes rising edges and would miss it. A prefetch's
  // acknowledge never reaches the requester at all, so blocking on it merely
  // delays the hit until the next request has arrived, and the requester then
  // takes that stale pulse as the answer to the NEW index. Measured: every
  // even word of a sequential stream read the word before it.
  //
  // `pf_req` is held for the whole prefetch transaction -- raised at the start,
  // dropped when the acknowledge FALLS, which is the same protocol the
  // requester uses (R208) -- so it is a reliable "this acknowledge is mine".
  wire fire    = hit_pend && !pass_ack && !(p_ack && !pf_own);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      have <= 1'b0; have_idx <= '0; have_data <= '0;
      hit_pend <= 1'b0; hit_ack <= 1'b0; pass <= 1'b0; pass_ack <= 1'b0;
      req_d <= 1'b0; p_ack_d <= 1'b0; data <= '0;
      pf_req <= 1'b0; pf_own <= 1'b0; pf_v <= 1'b0; pf_kill <= 1'b0; pf_wait <= 1'b0;
      prev_idx <= '0; prev_v <= 1'b0;
      pf_idx <= '0; pf_lo <= '0; pf_hi <= '0; pf_want <= '0; pf_arm <= 1'b0;
    end else begin
      req_d    <= req;
      p_ack_d  <= p_ack;
      // THE PREFETCH'S ACKNOWLEDGE IS NOT THE REQUESTER'S -- and `pf_req` is
      // not the test for that, because it falls on the acknowledge's rising
      // edge while the port holds the line up. A demand read that arrived
      // during a prefetch would take the held acknowledge as its own and
      // return whatever `data` last held.
      pass_ack <= pass & p_ack & ~pf_own;
      hit_ack  <= fire;
      if (fire) hit_pend <= 1'b0;
      if (!req) pass <= 1'b0;
      if (inval) begin
        have <= 1'b0;                          // R266: another master wrote the memory
        pf_v <= 1'b0;                          // and neither copy outlives it
        pf_arm <= 1'b0;
        if (pf_req) pf_kill <= 1'b1;           // the one in flight is already stale
      end
      if (new_req) begin
        have <= 1'b0;                          // the copy serves one request, or none
        if (match) begin
          hit_pend <= 1'b1; data <= have_data;
        end else if (pf_match) begin
          // Served from the prefetched pair. The OTHER dword of it becomes the
          // ordinary one-shot copy, and the pair after is asked for now.
          hit_pend <= 1'b1;
          data     <= pf_hit_lo ? pf_lo : pf_hi;
          pf_v     <= 1'b0;
          if (pf_hit_lo) begin
            have      <= 1'b1;
            have_idx  <= pf_idx + 1'b1;
            have_data <= pf_hi;
          end
          pf_want <= pf_idx + AW'(2);
          pf_arm  <= ~bypass;
        end else if (pf_own && !pf_v && (pf_want == idx)) begin
          // THE GUESS IS IN FLIGHT AND IT IS RIGHT. Throwing it away and
          // issuing a demand for the same index costs a second trip for a word
          // already on its way -- which is how a prefetch makes a stream
          // SLOWER: 375 port trips for 500 sequential words where the plain
          // pair cache took 250.
          pf_wait <= 1'b1;
        end else begin
          pass <= 1'b1;
          pf_v <= 1'b0;                        // the stream moved; the guess is worthless
        end
      end
      // The port's answer, on the rising edge of its acknowledge: the low
      // half for the requester, the high half kept as the next index.
      if (p_ack && !p_ack_d) begin
        if (pf_req) begin
          // The prefetch landed. Keep it unless the memory moved under it, or
          // the pair wrapped at the row edge (R240).
          pf_req  <= 1'b0;             // as the requester does: drop on the edge
          pf_own  <= 1'b1;             // ... but remember the line is still ours
          pf_kill <= 1'b0;
          if (pf_wait) begin
            // Somebody is waiting for exactly this: answer it from the landing
            // data, keep the pair's other dword, and guess again.
            pf_wait   <= 1'b0;
            hit_pend  <= 1'b1;
            data      <= p_dout[31:0];
            have      <= ~pf_kill && ~inval && ~&pf_want[COL_BITS-2:0];
            have_idx  <= pf_want + 1'b1;
            have_data <= p_dout[63:32];
            pf_want   <= pf_want + AW'(2);
            pf_arm    <= ~bypass;
          end
          pf_v   <= ~pf_wait && ~pf_kill && ~inval && ~&pf_want[COL_BITS-2:0];
          pf_idx <= pf_want;
          pf_lo  <= p_dout[31:0];
          pf_hi  <= p_dout[63:32];
        end else begin
          data      <= p_dout[31:0];
          have      <= ~&idx[COL_BITS-2:0] && !bypass && !inval;   // the last dword of a row: its pair wrapped

          have_idx  <= idx + 1'b1;
          have_data <= p_dout[63:32];
          // THE NEXT PAIR IS WANTED NOW, not when it is asked for -- but only
          // if this read continued a walk.
          prev_idx <= idx;
          prev_v   <= 1'b1;
          pf_want  <= idx + AW'(2);
          pf_arm   <= ~bypass && ~&idx[COL_BITS-2:0] && prev_v
                   && ((idx == prev_idx + AW'(1)) || (idx == prev_idx + AW'(2)));
        end
      end
      // Cleared only once the prefetch has been acknowledged AND the line has
      // fallen: set at the start and cleared on !p_ack alone, it cleared itself
      // one cycle later, before the transaction had even begun.
      if (pf_own && !pf_req && !p_ack) pf_own <= 1'b0;
      // Start the prefetch the moment the port is free of the demand read.
      // START IT WHENEVER THE PORT IS FREE, not only when the requester is
      // idle. `pass` is the only thing that needs the port -- a HIT does not --
      // and requiring `!req` meant the prefetch never went out at all while a
      // reader kept its request line up between words, which is exactly what a
      // streaming reader does. (Measured: 4.5 cycles a word with the wait, 2.6
      // without it.)
      if (pf_arm && !bypass && !pf_req && !pf_v && !pass && !p_ack) begin
        pf_arm  <= 1'b0;
        pf_kill <= 1'b0;
        pf_req  <= 1'b1;
        pf_own  <= 1'b1;
      end
    end
  end

  // The prefetch owns the port for the whole of its transaction; a demand read
  // that arrives meanwhile waits, which is why it is only one pair deep.
  // A DEMAND WAITS FOR THE PREFETCH TO FINISH. Without the mask, `p_req` never
  // falls between the two -- the prefetch drops its request as the demand
  // raises one -- so the port sees no new edge, never starts the demand's
  // transaction, and the demand takes the prefetch's answer.
  assign p_req = pf_req | (pass & req & ~pf_own);
  assign p_idx = pf_req ? pf_want : idx;
  // Both acknowledges are registered so that `data` is valid on the cycle
  // the requester sees the rising edge, as the glue's registered pair was.
  assign ack   = hit_ack | pass_ack;

endmodule
