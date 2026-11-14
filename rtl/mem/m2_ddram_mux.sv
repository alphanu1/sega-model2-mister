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
// R1003: FROM THE MODEL 1 CORE, rtl/mem/m1_ddram_mux.sv @ 311710f
// (sega-model1-mister), renamed m1_ -> m2_. Model 1 wrote it for exactly this
// pairing -- this core's m2_ddr3 (the frame buffer) as master A and the quad
// payload client as master B -- and its rules, its read-owner queue and its
// bench are kept. ONE THING IS CHANGED, MEASURED: the grant (below, and the
// PRIORITY paragraph). The comments are otherwise Model 1's; their R-numbers
// are this project's study.
//
// TWO DDRAM MASTERS ON THE FRAMEWORK'S ONE DDRAM PORT.
//
// The 3D layer has two DDR3 users and the framework gives a core one port
// (the Model 2 study's R656: ram1 is the core's, ram2 the framework's own, and
// a third would need framework changes). They are different shapes, which is
// why this sits at the DDRAM level rather than in front of m2_ddr3:
//
//   A  the 3D frame buffer, through m2_ddr3: one transaction at a time, line
//      reads of 248 beats, write bursts of up to 16
//   B  the quad payload, m2_ddram_payload: PIPELINED reads (two beats on
//      Model 1, five on the 2C store), up to sixteen in flight, and posted
//      writes of the same length
//
// m2_ddr3's request/acknowledge port would serialise B to one read in flight,
// and B's prefetch exists to have several. So each master keeps its own Avalon
// port and this passes one through at a time.
//
// THE RULES, each one an Avalon obligation rather than a preference:
//
//   - A COMMAND ON THE BUS IS NOT TAKEN AWAY. While DDRAM_BUSY holds the
//     granted master's command, the grant stays; switching would change the
//     command under a BUSY, which the model counts as a protocol error and the
//     bridge is entitled to mis-take.
//   - A WRITE BURST IS NOT SPLIT. Its beats after the first carry no address;
//     another master's command between them would be taken as data.
//   - READ REPLIES COME BACK IN ORDER, so the owner of every read is queued as
//     it is accepted and each DDRAM_DOUT_READY beat goes to the queue's head.
//
// The master not granted sees BUSY, which is exactly what a busy bridge looks
// like to it - both masters already hold their commands through a BUSY.
//
// PRIORITY (R1003, not Model 1's): A FIRST, DECIDED IN THE CYCLE. Model 1
// alternated a registered grant, which costs A an edge whenever B holds the
// grant; here A's command goes straight to the bus unless B's is already on it
// (left under BUSY, or a write burst part done), so a frame-buffer command
// with the payload idle is taken exactly as on a port of its own. B takes
// every cycle A leaves. `hold_b` keeps B off while the scanout is fetching
// (the study's R655 - a line read must not queue behind other traffic).

`timescale 1ns/1ps

module m2_ddram_mux #(
  parameter int unsigned QD = 32          // read bursts in flight, both masters
) (
  input  logic        clk,
  input  logic        rst_n,              // the MEMORY reset: never mid-burst
  input  logic        hold_b,

  // ---- master A
  input  logic        a_rd, a_we,
  input  logic [28:0] a_addr,
  input  logic [7:0]  a_burstcnt,
  input  logic [63:0] a_din,
  input  logic [7:0]  a_be,
  output logic        a_busy,
  output logic        a_dout_ready,
  output logic [63:0] dout,               // both masters' read data

  // ---- master B
  input  logic        b_rd, b_we,
  // B has something to put on the bus. m2_ddram_payload raises a command only
  // after a cycle in which it saw !BUSY, so B is granted on `want` and keeps
  // the grant until it has presented one (or wants nothing): granting only on
  // a presented command deadlocks - it never presents one while refused.
  input  logic        b_want,
  input  logic [28:0] b_addr,
  input  logic [7:0]  b_burstcnt,
  input  logic [63:0] b_din,
  input  logic [7:0]  b_be,
  output logic        b_busy,
  output logic        b_dout_ready,

  // ---- the framework's port
  input  logic        DDRAM_BUSY,
  output logic [7:0]  DDRAM_BURSTCNT,
  output logic [28:0] DDRAM_ADDR,
  input  logic [63:0] DDRAM_DOUT,
  input  logic        DDRAM_DOUT_READY,
  output logic        DDRAM_RD,
  output logic [63:0] DDRAM_DIN,
  output logic [7:0]  DDRAM_BE,
  output logic        DDRAM_WE,

  output logic [15:0] dbg_q_max,          // most read bursts ever in flight
  output logic [15:0] dbg_q_ovf           // reads accepted with the queue full: zero
);

  // R1003: THE GRANT IS DECIDED IN THE CYCLE, NOT REGISTERED (not Model 1's).
  //
  // Model 1's mux registered the grant and handed it to B whenever B *wanted*
  // the port, so a command A raised while B held it waited an edge for the
  // grant to come back -- even with nothing of B's on the bus. On 2C, A is the
  // frame buffer's m2_ddr3 and B the payload, whose reads are prefetched and
  // queued most of the time: m2_ddr3 lost 1,621 cycles that way in STCC's
  // title list and that list drew 0.71% slower than the release store. A
  // registered "A first" grant changed nothing (the edge is lost either way).
  //
  // So the port goes, in the cycle, to:
  //   - whoever's command is ON THE BUS and still owed: a command presented
  //     under BUSY last cycle (it must not change -- Avalon) or a write
  //     burst with beats to come (its beats carry no address);
  //   - otherwise A, if A presents a command;
  //   - otherwise B, if B presents one (and the scanout is not fetching).
  // A command A raises with B not on the bus is taken in the same cycle it
  // would be on a port of its own: zero added cycles. B, refused, holds its
  // command as it would for a busy bridge; it raises one only after a cycle
  // it saw !BUSY, and b_busy is low whenever A is idle, so it needs no
  // `want` and no `fresh`. B cannot starve: m2_ddr3 is one transaction at a
  // time and idles between them, and after a read waits ~300 cycles for it.
  logic       g;                          // this cycle's owner of the port: 0 = A, 1 = B
  logic [7:0] wleft;                      // beats of the open write burst still to go
  logic       wown;                       // its owner
  logic       stk, stk_own;               // a command was left on the bus under BUSY, and whose

  assign DDRAM_RD       = g ? b_rd       : a_rd;
  assign DDRAM_WE       = g ? b_we       : a_we;
  assign DDRAM_ADDR     = g ? b_addr     : a_addr;
  assign DDRAM_BURSTCNT = g ? b_burstcnt : a_burstcnt;
  assign DDRAM_DIN      = g ? b_din      : a_din;
  assign DDRAM_BE       = g ? b_be       : a_be;
  assign dout   = DDRAM_DOUT;
  assign a_busy = DDRAM_BUSY ||  g;
  assign b_busy = DDRAM_BUSY || !b_ok;

  wire a_cmd = a_rd || a_we;
  wire b_cmd = b_rd || b_we;
  wire lock  = (wleft != 8'd0) || stk;
  wire lown  = (wleft != 8'd0) ? wown : stk_own;
  // B would have the port this cycle if it presented a command. b_busy is
  // this, not g: B raises a command only after a cycle it saw !BUSY, so a
  // b_busy that waited for B's command would never let it raise one.
  wire b_ok  = lock ? lown : (!a_cmd && !hold_b);
  assign g   = lock ? lown : (b_ok && b_cmd);
  wire cmd   = DDRAM_RD || DDRAM_WE;
  wire rd_take = DDRAM_RD && !DDRAM_BUSY;
  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_want = b_want;              // R1003: the in-cycle grant needs no `want`
  /* verilator lint_on UNUSEDSIGNAL */

  // ---- the owners of the reads in flight, in order
  localparam int unsigned QW = $clog2(QD);
  // Not a block RAM: the head is read in the cycle a push to an empty queue
  // lands, which an M10K's registered read would answer with the old word
  // (and Quartus inferred one, two M10K, when this was unmarked).
  // R1008: LUT RAM, NOT FLIP-FLOPS (Model 1 kept flops). An MLAB's read is
  // asynchronous -- the word written at an edge is read from the next cycle,
  // exactly as the flops were -- and {owner, length} is one 9-bit word, so
  // the 288 flops, their 32 write decodes and the two 32:1 head selects are
  // one LAB of RAM. The queue is never cleared: q_wp / q_rp are, and no slot
  // is read before it is written (q_fill gates every use of the head).
  (* ramstyle = "MLAB, no_rw_check" *) logic [8:0] q_ent [QD];
  logic [QW:0] q_wp, q_rp;
  logic [7:0]  beat;                      // beats of the head burst already returned
  wire  [QW:0] q_fill = q_wp - q_rp;
  wire  [8:0]  q_head = q_ent[q_rp[QW-1:0]];
  wire         head_own = q_head[8];
  wire  [7:0]  head_len = q_head[7:0];
  always_ff @(posedge clk) if (rd_take) q_ent[q_wp[QW-1:0]] <= {g, DDRAM_BURSTCNT};
  assign a_dout_ready = DDRAM_DOUT_READY && (q_fill != '0) && !head_own;
  assign b_dout_ready = DDRAM_DOUT_READY && (q_fill != '0) &&  head_own;
  wire         head_done = DDRAM_DOUT_READY && (q_fill != '0)
                        && ((beat + 8'd1 >= head_len) || (head_len == 8'd0));

  // After this cycle: a write burst still open, and a command left under BUSY.
  wire [7:0] wleft_nx = (DDRAM_WE && !DDRAM_BUSY)
                      ? ((wleft == 8'd0) ? ((DDRAM_BURSTCNT == 8'd0) ? 8'd0 : DDRAM_BURSTCNT - 8'd1)
                                         : wleft - 8'd1)
                      : wleft;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wleft <= 8'd0; wown <= 1'b0; stk <= 1'b0; stk_own <= 1'b0;
      q_wp <= '0; q_rp <= '0; beat <= 8'd0;
      dbg_q_max <= '0; dbg_q_ovf <= '0;
    end else begin
      wleft <= wleft_nx;
      if (DDRAM_WE && !DDRAM_BUSY && wleft == 8'd0) wown <= g;   // a burst's first beat names its owner
      stk     <= cmd && DDRAM_BUSY;
      stk_own <= g;

      if (rd_take) begin
        q_wp <= q_wp + 1'b1;
        if (q_fill == (QW+1)'(QD) && !(&dbg_q_ovf)) dbg_q_ovf <= dbg_q_ovf + 16'd1;
      end
      if (16'(q_fill) > dbg_q_max) dbg_q_max <= 16'(q_fill);
      if (head_done) begin
        q_rp <= q_rp + 1'b1;
        beat <= 8'd0;
      end else if (DDRAM_DOUT_READY && (q_fill != '0)) beat <= beat + 8'd1;
    end
  end

endmodule
