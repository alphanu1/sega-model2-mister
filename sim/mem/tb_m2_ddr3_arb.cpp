// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// m2_ddr3_arb: two framebuffer masters onto one DDRAM port.
//
// THE THREE THINGS THAT MATTER, and each is a way this can be silently wrong:
//   1. a granted transaction is NOT interrupted -- DDR3 beats carry no address,
//      so interleaving two masters' beats corrupts both and neither knows;
//   2. the READER wins when both ask, because it has the beam deadline;
//   3. the loser's beats are NOT delivered to the winner -- an rvalid routed to
//      the wrong port writes one master's data into the other's buffer.
//
// (3) is the one that would be hardest to find on a board: the picture would be
// subtly wrong rather than absent.

#include "Vm2_ddr3_arb.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static Vm2_ddr3_arb *d;
static long checks = 0, fails = 0;
static void ck(const char *w, long got, long want) {
  checks++;
  if (got != want) { fails++; std::printf("  FAIL %-46s got=%ld want=%ld\n", w, got, want); }
}

static int left = 0, cd = 0; static uint32_t raddr = 0; static bool is_wr = false;
static long a_beats = 0, b_beats = 0, grants = 0;
static int zero_latency = 0;
static int dead_memory = 0;   // R369: accept the command, then never answer
static int a_ack_edge = 0, b_ack_edge = 0;

static void tick() {
  d->m_rvalid = 0; d->m_ack = 0; d->m_wnext = 0;
  if (left == 0 && d->m_req && !dead_memory) {
    left = d->m_blen ? d->m_blen : 1; is_wr = d->m_we; raddr = d->m_addr;
    cd = is_wr ? 0 : 6; grants++;
    if (zero_latency) {
      // served in the command cycle, acknowledge and all
      while (left > 0) {
        if (is_wr) d->m_wnext = 1; else { d->m_rvalid = 1; d->m_dout = 0xAA00u + raddr; }
        raddr++; left--;
      }
      d->m_ack = 1;
    }
  } else if (left > 0) {
    if (cd > 0) cd--;
    else {
      if (is_wr) d->m_wnext = 1; else { d->m_rvalid = 1; d->m_dout = 0xAA00u + raddr; }
      raddr++; left--;
      if (left == 0) d->m_ack = 1;
    }
  }
  d->eval();
  // SAMPLED AT THE EDGE, WHICH IS WHERE A FLIP-FLOP SAMPLES. Reading a_ack
  // after the clock has moved sees `busy` already updated and the routing
  // recomputed -- a glitch no real consumer can observe. Getting this wrong
  // made a correct arbiter look broken and cost an hour (R364).
  a_ack_edge = d->a_ack; b_ack_edge = d->b_ack;
  if (d->a_rvalid || d->a_wnext) a_beats++;
  if (d->b_rvalid || d->b_wnext) b_beats++;
  d->clk = 0; d->eval();
  d->clk = 1; d->eval();
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_ddr3_arb;
  d->clk = 0; d->rst_n = 0;
  d->a_req = d->b_req = 0; d->a_we = 0; d->b_we = 1;
  d->a_blen = 8; d->b_blen = 4; d->a_addr = 0x100; d->b_addr = 0x200;
  d->a_be = 0xFF; d->b_be = 0xFF; d->a_din = 0; d->b_din = 0x1234;
  d->m_wnext = d->m_rvalid = d->m_ack = 0; d->m_dout = 0;
  for (int i = 0; i < 4; i++) tick();
  d->rst_n = 1; tick();

  // ---- 1. both ask at once: the READER goes first, and completely
  {
    std::printf("test: both ask -- the reader wins and is not interrupted\n");
    a_beats = b_beats = grants = 0;
    d->a_req = 1; d->b_req = 1;
    // hold both until each is acknowledged
    int aq = 0, bq = 0;
    for (int i = 0; i < 2000 && (aq == 0 || bq == 0); i++) {
      if (d->a_ack) { aq = 1; d->a_req = 0; }
      if (d->b_ack) { bq = 1; d->b_req = 0; }
      tick();
    }
    ck("the reader completed",            aq, 1);
    ck("the writer completed",            bq, 1);
    ck("reader got all 8 of its beats",   a_beats, 8);
    ck("writer got all 4 of its beats",   b_beats, 4);
    ck("two grants, not interleaved",     grants, 2);
    ck("the writer waited for the reader", (long)(d->dbg_b_waits > 0), 1);
    ck("the reader never waited",          (long)d->dbg_a_waits, 0);
  }

  // ---- 2. the writer alone is served, so priority is not starvation
  {
    std::printf("test: the writer alone is served\n");
    a_beats = b_beats = 0;
    d->b_req = 1;
    int bq = 0;
    for (int i = 0; i < 2000 && !bq; i++) { if (d->b_ack) { bq = 1; d->b_req = 0; } tick(); }
    ck("the writer completed alone", bq, 1);
    ck("and got its beats",          b_beats, 4);
    ck("none leaked to the reader",  a_beats, 0);
  }

  // ---- 3. beats go to the OWNER, never the other port. This is the failure
  //         that would show as a subtly wrong picture rather than none.
  {
    std::printf("test: beats are never delivered to the wrong master\n");
    a_beats = b_beats = 0;
    d->a_req = 1;
    int aq = 0;
    for (int i = 0; i < 2000 && !aq; i++) { if (d->a_ack) { aq = 1; d->a_req = 0; } tick(); }
    ck("the reader's beats went to the reader", a_beats, 8);
    ck("and none to the writer",                b_beats, 0);
  }

  // ---- 4. R364: THE OWNER MUST NOT FOLLOW req ONCE GRANTED.
  //
  //         THIS IS THE ONE THAT MATTERED, and the test it replaces was worse
  //         than useless. R360 tested a memory that acknowledged in the cycle it
  //         was granted -- FASTER THAN m2_ddr3 CAN, since D_IDLE spends a cycle
  //         before D_ISSUE -- and to satisfy it the arbiter took `busy <= !m_ack`
  //         on a grant. That left a real hole: when m_ack is high in a grant
  //         cycle from the PREVIOUS transaction, the new grant runs with busy = 0,
  //         `sel_b` follows a_req live, and a master that drops req mid-burst (as
  //         both of ours do, on the first beat) has its acknowledge routed to the
  //         other port. It waits for ever.
  //
  //         So test the invariant instead of the timing: grant the reader, drop
  //         a_req the way m2_fb_read does, and require the acknowledge to still
  //         arrive at the reader.
  {
    std::printf("test: a master that drops req mid-burst still gets its ack\n");
    a_beats = b_beats = 0;
    d->a_blen = 8; d->a_req = 1; d->b_req = 1;   // both asking: reader wins
    d->eval();
    int aq = 0, dropped = 0; long stray_back = 0;
    for (int i = 0; i < 2000 && !aq; i++) {
      // m2_fb_read drops m_req on the FIRST returned beat
      if (!dropped && d->a_rvalid) { d->a_req = 0; dropped = 1; }
      if (b_ack_edge) stray_back++;
      if (a_ack_edge) aq = 1;
      if (getenv("ARB_DBG") && i < 40)
        std::printf("      t%-3d areq=%d breq=%d m_req=%d busy=%d own=%d arv=%d brv=%d aack=%d back=%d mack=%d\n",
                    i, d->a_req, d->b_req, d->m_req, d->dbg_busy, d->dbg_owner,
                    d->a_rvalid, d->b_rvalid, d->a_ack, d->b_ack, d->m_ack);
      tick();
    }
    ck("the reader's request was dropped mid-burst", dropped, 1);
    ck("and the reader still received its ack",      aq, 1);
    ck("all eight beats went to the reader",         a_beats, 8);
    ck("and none to the writer",                     b_beats, 0);
    ck("no ack was delivered to the wrong master",   stray_back, 0);
    d->a_req = 0; d->b_req = 0;
    for (int i = 0; i < 50; i++) tick();
  }

  // ---- 5. R369: NO MASTER HOLDS THE PORT FOR EVER.
  //
  //         Ben's point: the scanout must not be able to stop the fill. They
  //         share one DDRAM port, so a grant that is never released starves the
  //         other master completely -- which is exactly what the board did, with
  //         the reader stuck in R_FILL and the writer waiting in W_CLRW with its
  //         request high and unheard. R368 removes that cause; this is the floor
  //         under it, because the next stall anywhere would repeat it.
  {
    std::printf("test: a grant that goes dead is released, and the other master runs\n");
    // grant the reader, then have the memory go silent -- no beat, no ack
    left = 0; cd = 0; dead_memory = 1;
    d->a_req = 1; d->b_req = 0; d->eval();
    for (int i = 0; i < 20; i++) tick();
    ck("the reader was granted", (long)d->dbg_busy, 1);
    d->a_req = 0;                       // the reader is wedged and asks no more
    long before = d->dbg_stalls;
    int i = 0;
    for (; i < 20000 && d->dbg_busy; i++) tick();
    ck("the dead grant was released", (long)(d->dbg_busy == 0), 1);
    ck("and it was counted",          (long)(d->dbg_stalls > before), 1);
    // and now the writer, which had been locked out, must be served
    dead_memory = 0; b_beats = 0;
    d->b_req = 1; d->eval();
    int bq = 0;
    for (i = 0; i < 2000 && !bq; i++) { if (b_ack_edge) bq = 1; tick(); }
    ck("the starved master is served afterwards", bq, 1);
    ck("and got its beats",                       b_beats, 4);
    d->b_req = 0;
  }

  std::printf("m2_ddr3_arb: checks=%ld fails=%ld\n", checks, fails);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
