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
      busy <= 1'b0; owner <= 1'b0; cool <= 1'b0;
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
      end

      // R372: THE R369 WATCHDOG IS REMOVED. IT RELEASED THE ARBITER WITHOUT
      // TELLING THE MASTER, AND THAT IS NOT A SAFE THING TO DO.
      //
      // It fired after 8,191 cycles with no beat and no acknowledge, on the
      // reasoning that the scanout must not be able to starve the fill -- which
      // is a real requirement and Ben's own point. But m2_ddr3 keeps driving
      // DDRAM_RD/WE from D_ISSUE until the bridge answers, and releasing the
      // grant does not reset it. At boot, before DDR3 calibration completes,
      // the first read can sit in D_ISSUE far longer than the timeout: the
      // watchdog then re-grants, beats and acknowledges route to whoever owns
      // the port now, and the bridge is left mid-transaction. A wedged bridge
      // at boot means the ROM download never finishes and the i960 never
      // starts -- black screen, which is what the board showed.
      //
      // s93, without it, ran 2D and completed lines. s113, with it, came up
      // black on the best timing of the day (every core clock POSITIVE). The
      // bracketing is not proof, but the mechanism is concrete and the guard
      // was never justified by a measurement in the first place.
      //
      // A SAFE VERSION WOULD HAVE TO RESET THE MASTER TOO, or only fire when
      // the master is known idle -- which means m2_ddr3 must report its state
      // to the arbiter. That is a design, not a timeout, and it belongs after
      // the handshake it is meant to backstop actually works.
      //
      // TWICE TODAY A GUARD ADDED ON REASONING RATHER THAN MEASUREMENT MADE
      // THINGS WORSE (R364 removed one that was load-bearing; R369 added one
      // that was harmful). The rule earned: while a system is under diagnosis,
      // change what the evidence names and nothing else.

      // What the priority actually costs the loser, and what it saves the
      // winner. If the reader ever waits at all, the burst-per-line argument
      // above is not holding and wants re-checking on the board.
      if (a_req && (busy && owner) && !(&dbg_a_waits)) dbg_a_waits <= dbg_a_waits + 32'd1;
      if (b_req && ((busy && !owner) || (!busy && a_req)) && !(&dbg_b_waits))
        dbg_b_waits <= dbg_b_waits + 32'd1;
    end
  end

endmodule
