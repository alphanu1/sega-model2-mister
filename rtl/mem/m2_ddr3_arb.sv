// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// TWO MASTERS, ONE DDRAM PORT. The framebuffer has a writer (spans, from the
// fill) and a reader (a line at a time, for the scanout) and the framework
// gives the core exactly one DDRAM interface.
//
// THE READER WINS, ALWAYS, AND IT IS NOT A CLOSE CALL. The scanout has a beam
// deadline: a line that is not in the buffer when the beam arrives is a torn
// line. The writer has none -- the fill runs ahead of the display by a whole
// frame, and a span that lands late simply lands late. Round-robin would be
// the wrong answer here, and this is the opposite of m2_sdram's arbiter, where
// every master is equally entitled.
//
// STARVATION IS BOUNDED BY ARITHMETIC, not by a fairness rule. The reader takes
// one 248-beat burst per scanline -- about 2.6 us of a 30 us line, under 9% --
// so the writer has the rest and cannot be locked out. That only holds while
// the reader is one burst a line; anything that makes it greedier has to
// revisit this.
//
// A TRANSACTION IS NOT INTERRUPTED once granted. DDR3 bursts carry their own
// address and the beats must not be interleaved with another master's, so the
// grant is held to the acknowledge.

`timescale 1ns/1ps

module m2_ddr3_arb (
  input  logic        clk,
  input  logic        rst_n,

  // ---- port 0: the scanout reader. PRIORITY.
  input  logic        a_req,
  input  logic        a_we,
  input  logic [24:0] a_addr,
  input  logic [7:0]  a_blen,
  input  logic [63:0] a_din,
  input  logic [7:0]  a_be,
  output logic        a_wnext,
  output logic        a_rvalid,
  output logic        a_ack,

  // ---- port 1: the span writer
  input  logic        b_req,
  input  logic        b_we,
  input  logic [24:0] b_addr,
  input  logic [7:0]  b_blen,
  input  logic [63:0] b_din,
  input  logic [7:0]  b_be,
  output logic        b_wnext,
  output logic        b_rvalid,
  output logic        b_ack,

  // ---- the single master
  output logic        m_req,
  output logic        m_we,
  output logic [24:0] m_addr,
  output logic [7:0]  m_blen,
  output logic [63:0] m_din,
  output logic [7:0]  m_be,
  input  logic        m_wnext,
  input  logic        m_rvalid,
  input  logic        m_ack,
  input  logic [63:0] m_dout,
  output logic [63:0] dout,

  output logic [31:0] dbg_a_waits,     // cycles the READER spent waiting
  output logic [31:0] dbg_b_waits,
  output logic [15:0] dbg_stalls,      // R369: grants released by the watchdog
  // R364: THE ARBITER'S STATE, OBSERVABLE. A block that can wedge the whole
  // core by holding a grant must not be a black box -- the board reported
  // "0 lines fetched" with nothing in flight, and busy/owner were the two bits
  // that would have named the fault immediately.
  output logic        dbg_busy,
  output logic        dbg_owner
);

  logic       busy, owner;             // 0 = a, 1 = b
  assign dbg_busy = busy;
  assign dbg_owner = owner;
  // ONE DEAD CYCLE AFTER AN ACKNOWLEDGE, and it is not politeness.
  // A master clears its request ON the acknowledge, which is a registered
  // assignment -- so for the cycle after m_ack its req is STILL HIGH. Granting
  // in that cycle starts the same transaction a second time, and the bench
  // caught it exactly: three grants for two requests, with the second master's
  // beats delivered against the first master's burst.
  //
  // It is enforced in ONE place -- the m_req gate below. An earlier version also
  // guarded the grant condition, and a mutation test then PASSED with that guard
  // removed, because the other mechanism was silently carrying it. Two guards
  // for one rule means a mutation test cannot tell you which one works.
  logic       cool;
  // R369: cycles this grant has seen no beat and no acknowledge.
  logic [12:0] stall;   // 8,192 -- trips at 4,096 by the &stall test on 12 bits

  assign m_req  = cool ? 1'b0
                : busy ? (owner ? b_req  : a_req)  : (a_req | b_req);
  assign m_we   = busy ? (owner ? b_we   : a_we)   : (a_req ? a_we   : b_we);
  assign m_addr = busy ? (owner ? b_addr : a_addr) : (a_req ? a_addr : b_addr);
  assign m_blen = busy ? (owner ? b_blen : a_blen) : (a_req ? a_blen : b_blen);
  assign m_din  = busy ? (owner ? b_din  : a_din)  : (a_req ? a_din  : b_din);
  assign m_be   = busy ? (owner ? b_be   : a_be)   : (a_req ? a_be   : b_be);

  assign dout   = m_dout;

  wire sel_b = busy ? owner : (a_req ? 1'b0 : 1'b1);

  assign a_wnext  = m_wnext  && !sel_b;
  assign a_rvalid = m_rvalid && !sel_b;
  assign a_ack    = m_ack    && !sel_b;
  assign b_wnext  = m_wnext  &&  sel_b;
  assign b_rvalid = m_rvalid &&  sel_b;
  assign b_ack    = m_ack    &&  sel_b;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 1'b0; owner <= 1'b0; cool <= 1'b0; stall <= '0; dbg_stalls <= 16'd0;
      dbg_a_waits <= '0; dbg_b_waits <= '0;
    end else begin
      cool <= 1'b0;
      // R367: `busy <= !m_ack` RESTORED, BECAUSE THE BOARD SAYS IT IS
      // LOAD-BEARING. R360 added it; R364 removed it on the argument that a
      // transaction acknowledged in its grant cycle "cannot happen with the
      // real master", since D_IDLE spends a cycle before D_ISSUE. That was a
      // reading of m2_ddr3, NOT a measurement, and three builds disagree:
      //
      //   busy <= !m_ack   s46 RAN    s49 RAN
      //   busy <= 1'b1     s51 BLACK  s52 BLACK  s61 BLACK
      //
      // s61 had the best timing of the day (clk_mem -0.237) and the lowest area,
      // so neither slack nor utilisation explains it. Three of three is not a
      // seed either. The guard stays until something measures why it is needed.
      //
      // WHAT THIS COSTS TO BE WRONG ABOUT: with `busy <= 1'b1` an acknowledge
      // that arrives in a grant cycle is lost, and the arbiter then holds the
      // grant for ever -- the phase-11 capture caught exactly that, busy=1 with
      // owner=reader and the master idle. Whatever produces such an acknowledge
      // on hardware, it happens.
      if (!busy) begin
        if (a_req)      begin owner <= 1'b0; busy <= !m_ack; cool <= m_ack; end
        else if (b_req) begin owner <= 1'b1; busy <= !m_ack; cool <= m_ack; end
      end else if (busy && m_ack) begin
        busy <= 1'b0;
        cool <= 1'b1;
        stall <= '0;
      end

      // R369: NO MASTER HOLDS THE PORT FOR EVER.
      //
      // Ben's point, and it is the right one: the scanout should not be able to
      // stop the fill. They share one DDRAM port, so a grant that is never
      // released starves the other master completely -- `m_req` only ever shows
      // the owner's request. That is exactly what the board did: the reader lost
      // an acknowledge (R368), sat in R_FILL, and the writer waited in W_CLRW
      // with its request high and unheard, so not one pixel reached DDR3.
      //
      // R368 removes THIS cause. The structure stays fragile without a floor:
      // any future stall in either master repeats it. So a grant is released if
      // nothing has happened on it for a long time -- no beat, no acknowledge.
      //
      // SAFE BECAUSE IT CANNOT INTERRUPT A LIVE TRANSFER. The counter is reset
      // by every beat, so a burst that is merely slow never trips it; only a
      // transfer with NO activity at all for 4,096 cycles does, which is
      // sixteen times the 262 a full line burst takes, and by then the master
      // has long since returned to idle. m2_ddr3 latches its address for the
      // whole burst (R362), so a later grant cannot disturb one in flight.
      //
      // It converts a permanent deadlock into a dropped line. That is a
      // recovery, not a fix, and dbg_stalls counts it so the board can say
      // whether it ever fires -- a guard that trips silently is a fault hiding.
      if (!busy) stall <= '0;
      else if (m_rvalid || m_wnext || m_ack) stall <= '0;
      else if (!(&stall)) stall <= stall + 13'd1;

      if (busy && (&stall)) begin
        busy  <= 1'b0;
        cool  <= 1'b1;
        stall <= '0;
        if (!(&dbg_stalls)) dbg_stalls <= dbg_stalls + 16'd1;
      end

      // What the priority actually costs the loser, and what it saves the
      // winner. If the reader ever waits at all, the burst-per-line argument
      // above is not holding and wants re-checking on the board.
      if (a_req && (busy && owner) && !(&dbg_a_waits)) dbg_a_waits <= dbg_a_waits + 32'd1;
      if (b_req && ((busy && !owner) || (!busy && a_req)) && !(&dbg_b_waits))
        dbg_b_waits <= dbg_b_waits + 32'd1;
    end
  end

endmodule
