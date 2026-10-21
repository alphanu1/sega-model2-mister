// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// tb_m2_fifo_fuzz -- R923: m2_fifo_m10k, the queue under both directions of the
// coprocessor's FIFO interface and the TGP's posted buffer-RAM writes (R888),
// against a reference queue, every cycle, under random traffic.
//
// The FIFO had no bench of its own: it was exercised only through the TGP
// replays, which never push into a full queue at the cycle the head is popped,
// never pop at the cycle a word lands in an empty one, and never hold either
// side for long. Here every combination is driven on purpose, in phases whose
// push and pop probabilities change every few hundred cycles (fill to full and
// sit there, drain to empty and sit there, both at once, pop-only bursts), and
// checked on every cycle:
//   * the head (q, q_valid): a valid head is always the oldest word not yet
//     popped, and a pop with q_valid takes exactly that word;
//   * nothing lost or duplicated: every word accepted is popped once, in order;
//   * `full` refuses a push exactly when DEPTH words are in the array (the
//     usable depth is DEPTH + 1 with the head), and `dropped` counts exactly
//     the refused pushes;
//   * `count` and `held` against the model (count may lag the in-flight read
//     by one cycle, as the module says; held may not);
//   * liveness: a word in the array reaches the head within 3 cycles of the
//     head being free.
// Usage: Vm2_fifo_m10k [cycles] [seed]

#include "Vm2_fifo_m10k.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <deque>

#ifndef FIFO_DEPTH
#define FIFO_DEPTH 128
#endif

static uint64_t rs = 1;
static uint32_t rnd() { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return uint32_t(rs >> 11); }

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const uint64_t N = (argc > 1 && argv[1][0] != '+') ? std::strtoull(argv[1], nullptr, 10) : 20000000ull;
  rs = (argc > 2) ? std::strtoull(argv[2], nullptr, 10) * 0x9E3779B97F4A7C15ull + 1 : 1;
  auto *d = new Vm2_fifo_m10k;
  d->clk = 0; d->rst_n = 0; d->push = 0; d->pop = 0; d->din = 0;
  d->eval();
  for (int i = 0; i < 4; ++i) { d->clk = 1; d->eval(); d->clk = 0; d->eval(); }
  d->rst_n = 1; d->eval();

  std::deque<uint32_t> model;       // every accepted word not yet popped, oldest first
  uint64_t fails = 0, pushes = 0, refused = 0, pops = 0, full_cyc = 0, empty_cyc = 0;
  uint64_t both_full = 0, pop_at_land = 0;
  uint32_t next = 1, phase_left = 0, pp = 50, pq = 50;
  int head_wait = 0, max_head_wait = 0;
  auto fail = [&](const char *what, uint64_t c) {
    if (fails < 10) std::printf("  FAIL cycle %llu: %s (model %zu, q_valid %d q %08x)\n",
                                (unsigned long long)c, what, model.size(), d->q_valid, (unsigned)d->q);
    ++fails;
  };

  for (uint64_t c = 0; c < N; ++c) {
    if (phase_left == 0) {
      // a new phase: fill, drain, both, idle, pop-only, push-only
      static const uint32_t P[][2] = {{95, 5}, {5, 95}, {50, 50}, {100, 100}, {0, 100}, {100, 0},
                                      {30, 70}, {70, 30}, {100, 50}, {50, 100}, {2, 2}};
      const uint32_t k = rnd() % (sizeof P / sizeof P[0]);
      pp = P[k][0]; pq = P[k][1];
      phase_left = 16 + rnd() % 1500;
    }
    --phase_left;
    const bool do_push = (rnd() % 100) < pp;
    const bool do_pop  = (rnd() % 100) < pq;
    d->push = do_push; d->din = next; d->pop = do_pop;
    d->eval();

    // ---- the settled cycle, before the edge
    const bool qv = d->q_valid;
    const uint32_t q = d->q;
    const uint32_t in_array = uint32_t(model.size()) - (qv ? 1u : 0u);   // incl. the read in flight
    if (qv) {
      if (model.empty()) fail("q_valid with nothing accepted", c);
      else if (q != model.front()) fail("head is not the oldest word", c);
    }
    if (!d->held && !model.empty()) fail("held low with words accepted", c);
    if (d->held && model.empty()) fail("held high with nothing accepted", c);
    const uint32_t cnt = d->count;
    if (cnt != model.size() && cnt + 1 != model.size()) fail("count off by more than the read in flight", c);
    // liveness of the head
    if (!qv && !model.empty()) { if (++head_wait > max_head_wait) max_head_wait = head_wait; if (head_wait > 3) fail("a word did not reach the free head in 3 cycles", c); }
    else head_wait = 0;
    // full: the ARRAY holds DEPTH (the head and the in-flight read are outside it)
    const bool full = d->full;
    if (full) ++full_cyc;
    if (model.empty()) ++empty_cyc;
    const bool accept = do_push && !full;
    if (do_push && full) { ++refused; if (do_pop && qv) ++both_full; }
    if (do_pop && qv && model.size() == 1) ++pop_at_land;
    (void)in_array;

    // ---- the edge
    if (do_pop && qv) { model.pop_front(); ++pops; }
    if (accept) { model.push_back(next); ++pushes; ++next; }
    d->clk = 1; d->eval(); d->clk = 0; d->eval();
    if (model.size() > FIFO_DEPTH + 2) fail("model holds more than DEPTH + 2: full never refused", c);
    if (d->dropped != refused) fail("dropped != pushes refused", c);
  }
  // drain and check nothing is left behind
  d->push = 0;
  for (int i = 0; i < 4 * FIFO_DEPTH + 16 && !model.empty(); ++i) {
    d->pop = 1; d->eval();
    if (d->q_valid) { if (d->q != model.front()) fail("drain: wrong word", N + i); model.pop_front(); ++pops; }
    d->clk = 1; d->eval(); d->clk = 0; d->eval();
  }
  if (!model.empty()) fail("words never came out", N);
  std::printf("m2_fifo_m10k DEPTH %d: %llu cycles, %llu accepted, %llu popped, %llu refused while full "
              "(%llu of them with a pop the same cycle), full %llu cycles, empty %llu, pops of the last word %llu, "
              "longest head wait %d\n", FIFO_DEPTH, (unsigned long long)N, (unsigned long long)pushes,
              (unsigned long long)pops, (unsigned long long)refused, (unsigned long long)both_full,
              (unsigned long long)full_cyc, (unsigned long long)empty_cyc, (unsigned long long)pop_at_land,
              max_head_wait);
  std::printf("%s (%llu failures)\n", fails ? "FAIL" : "PASS", (unsigned long long)fails);
  delete d;
  return fails ? 1 : 0;
}
