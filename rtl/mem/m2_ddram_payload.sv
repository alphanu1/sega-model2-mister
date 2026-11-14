// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE for the full text.
//
// R1003: THE QUAD STORE'S PAYLOAD, IN DDR3. FROM THE MODEL 1 CORE,
// rtl/video/m1_ddram_payload.sv @ 311710f (sega-model1-mister; written in
// 48e67b5, rewritten in 9c05b79, the reply FIFO split per beat in 29a5fa0,
// `want` added in 311710f for m1_ddram_mux). What is changed, and why:
//
//   - THE PAYLOAD IS PW BITS IN NB BEATS, NOT 128 IN TWO. The 2C store's
//     payload is the vertex word (107 bits) and the texture word (197): 304
//     bits, five 64-bit beats, BURSTCNT 5. Model 1's two-beat write burst
//     (`din_hi`, `wr_open`) becomes a beat counter, and its reply FIFO's two
//     halves become NB lanes, each written as its beat arrives -- 29a5fa0's
//     reason for splitting them holds for five as for two.
//   - A QUAD'S SLOT IS 2^SW WORDS (8), so the address is {bank, index, 000}
//     with no multiply. 2 x 2,048 x 8 words is 256 KB of DDR3.
//   - wr_room: the write queue says when it is nearly full. Model 1's store
//     cannot stall the geometry and counts an overrun; the 2C store can --
//     m2_raster3d's q_ready already waits on the store's spill hold (R962) --
//     so the raster3d holds the next quad instead of losing a payload. On the
//     board the geometry hands a quad over every ~200-325 cycles (R994) and
//     the queue never fills; the bench hands them over back to back.
//
// Everything else is Model 1's, comments included: what its own header says
// about latency, prefetch, BUSY and resets is the reason this module exists
// and is true here as written.
//
// WHY DDR3 AND NOT THE SDRAM
//
// (Model 1's measurement, and the 2C core's SDRAM is the contended bus too:
// the CPU, the texel cache's four ports and the sound board share it.) The
// SDRAM is 16 bits wide, so a payload is several burst reads and many
// single-word writes. DDR3 is 64 bits wide, so the same payload is ONE
// transaction each way, and on 2C nothing else uses DDR3 but the 3D frame
// buffer, which m2_ddram_mux shares it with.
//
// LATENCY IS THE RISK, AND PREFETCH IS WHY IT IS SURVIVABLE
//
// The HPS arbitrates this bus against Linux and the scaler, so a read can be
// slow and the worst case is not ours to choose. What makes that affordable is
// that emissions are FILL-paced, not scan-paced. The store's scan runs ahead
// of that, so reads are issued from the SCAN and consumed by the OUTPUT with
// this module's reply FIFO between them. Latency is hidden entirely while it
// stays under about DEPTH x the fill's pace.
//
// WHAT THIS CORE PAID TO LEARN (docs/model2a-design-study.md), applied:
//
//   R345  RD/WE are HELD until BUSY is low, with ADDR and BURSTCNT latched for
//         the whole burst.
//   R346  DDRAM_ADDR counts 64-bit WORDS. BASE is a word address.
//   R377  The master runs on the clock of its consumers -- DDRAM_CLK is ours
//         to choose -- so no request or reply crosses a clock domain.
//   R654  0x30000000 is the cores' own region; the scaler sits at 0x20000000.
//   R649  A burst cut short by a reset wedges the HPS bridge until the FPGA is
//         reconfigured, and a core reset does not clear it. So this module is
//         reset ONLY with the memory, and a game reset would arrive as
//         `flush`: it discards what is queued, but a burst already started is
//         always finished and replies already owed are always drained. (On 2C
//         the 3D layer is not reset by the game at all -- m2_raster3d runs on
//         mem_rst_n -- so flush is tied low there; it is kept, and benched,
//         so the module stays Model 1's.)
//   R660  A command is never re-taken in the cycle it is accepted, and no beat
//         goes out with BE = 0.
//
// WRITES ARE POSTED. The store accepts a quad in one cycle, so the write side
// is a queue -- WDEP quads in M10K -- and an overrun, which would lose a
// payload, is COUNTED rather than silent (`dbg_wr_ovf`). `wr_idle` says every
// posted write has been accepted by the bus; m2_raster3d waits for it before
// a sorted list can be handed to the reader.
//
// RETURNS ARE IN ORDER. One master, one stream, so the reply FIFO needs no
// tags -- the Nth burst reply belongs to the Nth read.

`timescale 1ns/1ps

module m2_ddram_payload #(
  parameter int unsigned IW    = 11,          // quad index width
  parameter int unsigned PW    = 304,         // payload bits a quad
  parameter int unsigned NB    = (PW + 63) / 64,   // beats a quad -- derived, never overridden
  parameter int unsigned SW    = 3,           // log2 of the words a quad's slot spans (2^SW >= NB)
  parameter int unsigned DEPTH = 16,          // reads accepted and not yet taken
  parameter int unsigned WDEP  = 256,         // posted writes held
  parameter int unsigned WROOM = 8,           // wr_room falls with fewer than this many free
  // 64-bit word address of the payload region. Two banks of 2^IW slots.
  parameter logic [28:0] BASE  = 29'h0610_0000
) (
  input  logic          clk,                  // drives DDRAM_CLK
  input  logic          rst_n,                // MEMORY reset only - see R649
  input  logic          flush,                // game reset: drop what is queued

  // Posted writes: one quad's payload, accepted unconditionally.
  input  logic          wr_req,
  input  logic          wr_bank,
  input  logic [IW-1:0] wr_idx,
  input  logic [PW-1:0] wr_data,
  output logic          wr_idle,              // nothing queued, no burst open
  output logic          wr_room,              // R1003: at least WROOM free (registered)

  // Prefetched reads. `rd_ready` is a function of REGISTERED counts only, never
  // of DDRAM_BUSY, so the store's scan carries no path from the HPS.
  input  logic          rd_req,
  input  logic          rd_bank,
  input  logic [IW-1:0] rd_idx,
  output logic          rd_ready,
  output logic          rd_valid,             // a payload is presented
  input  logic          rd_take,              // consumer took it
  output logic [PW-1:0] rd_data,

  output logic [15:0]   dbg_wr_ovf,           // posted writes LOST, free-running
  output logic [15:0]   dbg_rd_refused,       // reads asked for with no credit: zero by contract
  // The longest the bus has kept us waiting for a reply with a read owed, in
  // clk cycles - an upper bound on the read round trip. Sticky.
  output logic [15:0]   dbg_rd_wait,
  // Something queued to put on the bus: a read or write waiting, a write
  // burst's later beats owed, or a command presented. For a shared port
  // (m2_ddram_mux): this client only raises a command after a cycle of !BUSY,
  // so an arbiter cannot wait to see one before granting it.
  output logic          want,

  // MiSTer DDR3, per sys/emu_ports.vh.
  output logic          DDRAM_CLK,
  input  logic          DDRAM_BUSY,
  output logic [7:0]    DDRAM_BURSTCNT,
  output logic [28:0]   DDRAM_ADDR,
  input  logic [63:0]   DDRAM_DOUT,
  input  logic          DDRAM_DOUT_READY,
  output logic          DDRAM_RD,
  output logic [63:0]   DDRAM_DIN,            // from the queue head, see the bus
  output logic [7:0]    DDRAM_BE,
  output logic          DDRAM_WE
);

  assign DDRAM_CLK = clk;
  assign DDRAM_BE  = 8'hff;

  localparam int unsigned BW_ = (NB > 1) ? $clog2(NB) : 1;   // beat counter width
  localparam int unsigned LW  = PW - 64 * (NB - 1);           // the last beat's live bits

  // 2^SW words a quad; the bank selects the half of the region.
  function automatic logic [28:0] pay_addr(input logic bank, input logic [IW-1:0] i);
    pay_addr = BASE + 29'({bank, i, SW'(0)});
  endfunction

  // ================================================================ writes
  // Block RAM with a registered read, presented show-ahead: the read address is
  // the pointer the head will have AFTER this edge, so `wq_q` always holds the
  // current head. An entry becomes visible a cycle after its write (wq_wp_d),
  // so a read never meets a write to the same word on the same edge.
  localparam int unsigned WW   = $clog2(WDEP);
  localparam int unsigned WE_W = 1 + IW + PW;
  (* ramstyle = "M10K" *) logic [WE_W-1:0] wq [WDEP];
  logic [WW:0]     wq_wp, wq_wp_d, wq_rp;
  logic [WE_W-1:0] wq_q;
  wire             wq_avail = (wq_wp_d != wq_rp);
  wire  [WW:0]     wq_fill  = wq_wp - wq_rp;
  wire             wq_full  = (wq_fill == (WW+1)'(WDEP));
  wire             wq_push  = wr_req && !wq_full && !flush;

  // ================================================================ read queue
  // Requests waiting for the bus, as deep as the credit: every read accepted
  // may be waiting here while the bus is busy. A shallower queue put a second
  // limit on rd_ready, and the store - which asks a cycle after it sampled
  // rd_ready, from a register - then presented a request the client refused.
  // The colour for it was already queued, so the output waited for a payload
  // that was never asked for and the 3D froze. (Model 1's render3d found it
  // under a busy bus; a bench that requests in the same cycle it samples ready
  // cannot.)
  //
  // So rd_ready depends on the credit alone, and the store's own limit - its
  // colour FIFO is DEPTH deep and counts the same reads a cycle EARLIER on
  // both ends - guarantees a request never arrives with the credit exhausted.
  // That guarantee is checked: dbg_rd_refused counts any that did.
  localparam int unsigned DW = $clog2(DEPTH);
  (* ramstyle = "M10K" *) logic [IW:0] rq [DEPTH];   // {bank, idx}
  logic [DW:0]   rq_wp, rq_wp_d, rq_rp;
  logic [IW:0]   rq_q;
  wire           rq_avail = (rq_wp_d != rq_rp);

  // Everything accepted and not yet taken: queued, owed by the bus, or sitting
  // in the reply FIFO. One registered counter, so the reply FIFO cannot
  // overflow and rd_ready is a compare.
  logic [DW:0]   credit;
  assign rd_ready = (credit < (DW+1)'(DEPTH)) && !flush;
  wire   rd_acc   = rd_req && rd_ready;

  // ================================================================ replies
  // NB lanes, one per reply beat, each written as its beat arrives: no beat
  // waits in a register for the last one (Model 1's 29a5fa0, for two).
  logic [DW:0]   fq_wp, fq_wp_d, fq_rp;
  logic [BW_-1:0] rbeat;                      // the beat of the burst arriving next
  logic [DW:0]   owed;                        // read bursts presented, not fully returned
  logic [DW:0]   drop;                        // of those, replies to discard (flush)
  wire           burst_done = DDRAM_DOUT_READY && (rbeat == BW_'(NB - 1));
  wire           fq_push = burst_done && (drop == '0) && !flush;
  wire           fq_pop  = rd_valid && rd_take;
  /* verilator lint_off UNUSEDSIGNAL */   // the pointer's wrap bit; the last lane's padding
  wire  [DW:0]   fq_rp_nx = fq_rp + (DW+1)'(fq_pop);
  /* verilator lint_on UNUSEDSIGNAL */
  assign rd_valid = (fq_wp_d != fq_rp);

  /* verilator lint_off UNUSEDSIGNAL */   // the pointer's wrap bit; the last lane's padding
  logic [64*NB-1:0] fq_q;
  /* verilator lint_on UNUSEDSIGNAL */
  genvar k;
  generate
    for (k = 0; k < int'(NB); k++) begin : g_lane
      localparam int unsigned LB = (k == int'(NB) - 1) ? LW : 64;   // the last lane holds what is left
      (* ramstyle = "M10K" *) logic [LB-1:0] fq [DEPTH];
      logic [LB-1:0] lq;
      always_ff @(posedge clk) begin
        if (DDRAM_DOUT_READY && rbeat == BW_'(k)) fq[fq_wp[DW-1:0]] <= DDRAM_DOUT[LB-1:0];
        lq <= fq[fq_rp_nx[DW-1:0]];
      end
      assign fq_q[64*k +: 64] = 64'(lq);
    end
  endgenerate
  assign rd_data = fq_q[PW-1:0];

  // ================================================================ the bus
  // A write burst's beats come straight from the queue's head, which is popped
  // only once the LAST beat has been taken - so DIN needs no register of its
  // own and the head is stable for as long as BUSY holds a beat.
  logic [BW_-1:0] wbeat;                      // the beat presented, while DDRAM_WE
  wire            w_last = (wbeat == BW_'(NB - 1));
  wire            wr_open = DDRAM_WE && !w_last;   // a later beat is still owed
  wire            wq_pop = !DDRAM_BUSY && DDRAM_WE && w_last;
  wire [64*NB-1:0] wq_pad = (64*NB)'(wq_q[PW-1:0]);
  assign DDRAM_DIN = wq_pad[64*wbeat +: 64];

  // What goes out at this edge, if the bus takes commands. Reads first: they
  // are what the fill is waiting for, and a write sits in a WDEP-deep queue.
  // A burst already open is finished before anything else (R649).
  wire bus_free  = !DDRAM_BUSY;
  wire can_issue = bus_free && !wr_open && !flush;
  wire do_rd     = can_issue && rq_avail;
  // Not in the cycle the head is popped: the next head is read at that edge
  // and is on wq_q only after it.
  wire do_wr     = can_issue && !do_rd && wq_avail && !wq_pop;
  /* verilator lint_off UNUSEDSIGNAL */   // the pointer's wrap bit; the last lane's padding
  wire [WW:0] wq_rp_nx = wq_rp + (WW+1)'(wq_pop);
  wire [DW:0] rq_rp_nx = rq_rp + (DW+1)'(do_rd);
  /* verilator lint_on UNUSEDSIGNAL */

  assign wr_idle = (wq_fill == '0) && !DDRAM_WE;
  assign want    = rq_avail || wq_avail || DDRAM_RD || DDRAM_WE;

  always_ff @(posedge clk) begin
    if (wq_push) wq[wq_wp[WW-1:0]] <= {wr_bank, wr_idx, wr_data};
    wq_q <= wq[wq_rp_nx[WW-1:0]];
    if (rd_acc) rq[rq_wp[DW-1:0]] <= {rd_bank, rd_idx};
    rq_q <= rq[rq_rp_nx[DW-1:0]];
  end

  logic [15:0] wait_t;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      DDRAM_RD <= 1'b0; DDRAM_WE <= 1'b0; DDRAM_ADDR <= '0;
      DDRAM_BURSTCNT <= 8'(NB); wbeat <= '0;
      wq_wp <= '0; wq_wp_d <= '0; wq_rp <= '0; wr_room <= 1'b1;
      rq_wp <= '0; rq_wp_d <= '0; rq_rp <= '0; credit <= '0; dbg_rd_refused <= '0;
      fq_wp <= '0; fq_wp_d <= '0; fq_rp <= '0;
      owed <= '0; drop <= '0; rbeat <= '0;
      dbg_wr_ovf <= '0; dbg_rd_wait <= '0; wait_t <= '0;
    end else begin
      // ---- posted-write queue. A flush drops everything not yet on the bus;
      // do_wr is low under flush, so nothing is being taken from it this edge.
      if (wr_req && wq_full && !flush) dbg_wr_ovf <= dbg_wr_ovf + 16'd1;
      if (flush)        wq_wp <= wq_rp;
      else if (wq_push) wq_wp <= wq_wp + 1'b1;
      wq_wp_d <= flush ? wq_rp : wq_wp;
      if (wq_pop) wq_rp <= wq_rp + 1'b1;
      // R1003: room for WROOM more, from this edge's fill (a push this edge
      // may make it one short; WROOM covers the quads in flight to the store)
      wr_room <= (wq_fill + (WW+1)'(wq_push)) <= (WW+1)'(WDEP - WROOM);

      // ---- read queue
      if (flush) begin
        rq_wp <= rq_rp; rq_wp_d <= rq_rp;
      end else begin
        if (rd_acc) rq_wp <= rq_wp + 1'b1;
        rq_wp_d <= rq_wp;
        if (do_rd) rq_rp <= rq_rp + 1'b1;
      end
      if (rd_req && !rd_ready && !flush) dbg_rd_refused <= dbg_rd_refused + 16'd1;

      // ---- credit: accepted minus taken. A flush forgets every one; the
      // replies still owed are discarded below and never reach the FIFO.
      if (flush) credit <= '0;
      else       credit <= credit + (DW+1)'(rd_acc) - (DW+1)'(fq_pop);

      // ---- the command register, held while BUSY: a command is taken at an
      // edge where it is presented and BUSY is low.
      if (bus_free) begin
        DDRAM_RD <= 1'b0;
        DDRAM_WE <= 1'b0;
        if (wr_open) begin
          wbeat     <= wbeat + 1'b1;          // the next beat of the open burst
          DDRAM_WE  <= 1'b1;
        end else if (do_rd) begin
          DDRAM_ADDR     <= pay_addr(rq_q[IW], rq_q[IW-1:0]);
          DDRAM_BURSTCNT <= 8'(NB);
          DDRAM_RD       <= 1'b1;
        end else if (do_wr) begin
          DDRAM_ADDR     <= pay_addr(wq_q[WE_W-1], wq_q[WE_W-2 -: IW]);
          DDRAM_BURSTCNT <= 8'(NB);
          wbeat          <= '0;
          DDRAM_WE       <= 1'b1;
        end
      end

      // ---- replies, NB beats each, in order
      if (DDRAM_DOUT_READY) rbeat <= (rbeat == BW_'(NB - 1)) ? '0 : rbeat + 1'b1;
      // owed counts read bursts from the edge they are presented until their
      // last beat returns; a flush turns every one still owed into a drop.
      owed <= owed + (DW+1)'(do_rd) - (DW+1)'(burst_done);
      if (flush)                          drop <= owed - (DW+1)'(burst_done);
      else if (burst_done && drop != '0)  drop <= drop - 1'b1;

      if (flush) begin
        fq_wp <= fq_rp; fq_wp_d <= fq_rp;
      end else begin
        if (fq_push) fq_wp <= fq_wp + 1'b1;
        fq_wp_d <= fq_wp;
        if (fq_pop) fq_rp <= fq_rp + 1'b1;
      end

      // ---- the longest wait for a reply with a read owed
      if (owed == '0 || DDRAM_DOUT_READY) wait_t <= '0;
      else if (wait_t != 16'hffff)        wait_t <= wait_t + 16'd1;
      if (wait_t > dbg_rd_wait) dbg_rd_wait <= wait_t;
    end
  end

endmodule
