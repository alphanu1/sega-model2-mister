// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// m2_texel_cdc with the two clocks independent (study R561).
//
//   M2_TXC_TF / M2_TXC_TS   fast / slow periods, ps (default 10000 / 16667)
//   M2_TXC_PH               slow clock's phase, ps (default: from the seed)
//   M2_TXC_JIT              +/- ps of jitter on each slow half-period
//   M2_TXC_SEED             randomness
//   M2_TXC_N                fetches in the main phase (default 20000)
//
// The requester is m2_span_tex's side of the protocol: it issues a fetch (a
// one-cycle pulse with its payload) whenever a credit is free and it feels
// like it, and takes answers, in order, whenever it feels like it. The far
// side is m2_texel's: it accepts when `f_req && f_rdy` on an edge, and answers
// IN ORDER, some cycles later, with a one-cycle `f_ack`.
//
// Checked: every answer arrives, in issue order, exactly once, with the value
// the cache computed for THAT request's payload; the cache never holds more
// than K unanswered; and the local 0xF answer appears only while the cache is
// refusing requests. The cache's texel is a hash of the payload that never
// equals 0xF, so a 0xF can only be the adapter's own.

#include "Vm2_texel_cdc.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <deque>

static Vm2_texel_cdc *d;
static long checks = 0, fails = 0;
static uint32_t seed = 1;
static uint32_t rnd() { seed = seed * 1103515245u + 12345u; return seed >> 8; }
static long envl(const char *n, long def) { const char *s = std::getenv(n); return s ? atol(s) : def; }
#define CHECK(c, ...) do { ++checks; if (!(c)) { if (fails < 12) { std::printf("  FAIL: " __VA_ARGS__); std::printf("  t=%lld ps\n", t_now); } ++fails; } } while (0)

static long long t_now = 0, TF, TS, JIT, nf, ns;
static bool f_lvl = false, s_lvl = false;
static bool running = false;           // both models idle until reset is released

static uint8_t texel_of(uint32_t tex, uint32_t u, uint32_t v) {
  uint32_t h = tex * 2654435761u ^ u * 40503u ^ v * 2246822519u;
  h ^= h >> 13;
  return uint8_t(h % 15);            // never 0xF
}

// ------------------------------------------------------------- the requester
struct Req { uint32_t tex, u, v; };
static std::deque<Req> in_flight;      // issued, not yet taken, in order
static long issued = 0, taken = 0, local_f = 0;
static int  issue_pct = 70, take_pct = 70;
static bool allow_f = false;           // a local 0xF is legal only while stalled

// ---------------------------------------------------------------- the cache
struct Ans { long long due; uint8_t texel; };
static std::deque<Ans> cache_q;           // accepted, answering in order
static long outstanding = 0, max_out = 0;
static bool stall = false;
static long fast_cyc = 0;

static void slow_edge() {
  // Inputs for the NEXT cycle, decided from this cycle's outputs.
  d->s_take = 0;
  if (d->s_ack && int(rnd() % 100) < take_pct) {
    CHECK(!in_flight.empty(), "an answer with nothing in flight");
    if (!in_flight.empty()) {
      const Req r = in_flight.front(); in_flight.pop_front();
      const uint8_t want = texel_of(r.tex, r.u, r.v), got = d->s_texel;
      if (got == 0xF) {
        ++local_f;
        CHECK(allow_f, "a local 0xF answer while the cache was taking requests");
      } else {
        CHECK(got == want, "answer %ld: got %x want %x (tex %08x u %05x v %05x)",
              taken, got, want, r.tex, r.u, r.v);
      }
      ++taken;
    }
    d->s_take = 1;
  }
  d->s_req = 0;
  if (issued < envl("M2_TXC_N", 20000) + (allow_f ? 400 : 0) && d->s_rdy && int(rnd() % 100) < issue_pct) {
    const Req r{ rnd(), rnd() & 0xfffff, rnd() & 0xfffff };
    d->s_tex = r.tex; d->s_u = r.u; d->s_v = r.v; d->s_req = 1;
    in_flight.push_back(r); ++issued;
  }
}

static void fast_edge(bool pre_req, bool pre_rdy, uint32_t ptex, uint32_t pu, uint32_t pv) {
  ++fast_cyc;
  d->f_ack = 0;
  if (pre_req && pre_rdy) {
    // In order: never due before the one ahead of it.
    long long due = fast_cyc + 1 + (rnd() % 12 == 0 ? 20 + rnd() % 40 : rnd() % 4);
    if (!cache_q.empty() && due <= cache_q.back().due) due = cache_q.back().due + 1;
    cache_q.push_back({ due, texel_of(ptex, pu, pv) });
    ++outstanding; if (outstanding > max_out) max_out = outstanding;
  }
  if (!cache_q.empty() && cache_q.front().due <= fast_cyc) {
    d->f_ack = 1; d->f_texel = cache_q.front().texel; cache_q.pop_front(); --outstanding;
  }
  d->f_rdy = stall ? 0 : (rnd() % 8 != 0);
}

static void step() {
  const bool fast = nf <= ns;
  t_now = fast ? nf : ns;
  if (fast) {
    const bool rising = !f_lvl;
    // What the DUT samples on this edge: the values from the cycle before.
    const bool pre_req = d->f_req, pre_rdy = d->f_rdy;
    const uint32_t pt = d->f_tex, pu = d->f_u, pv = d->f_v;
    f_lvl = !f_lvl; d->clk_fast = f_lvl; nf += TF / 2;
    d->eval();
    if (rising && running) { fast_edge(pre_req, pre_rdy, pt, pu, pv); d->eval(); }
  } else {
    const bool rising = !s_lvl;
    s_lvl = !s_lvl; d->clk_slow = s_lvl;
    long long h = TS / 2; if (JIT) h += (long long)(rnd() % (2 * JIT + 1)) - JIT;
    ns += h;
    d->eval();
    if (rising && running) { slow_edge(); d->eval(); }
  }
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  TF = envl("M2_TXC_TF", 10000); TS = envl("M2_TXC_TS", 16667); JIT = envl("M2_TXC_JIT", 0);
  seed = uint32_t(envl("M2_TXC_SEED", 1));
  const uint32_t seed0 = seed;
  const long long PH = envl("M2_TXC_PH", (long long)(rnd() % (uint32_t)TS));
  nf = TF / 2; ns = TS / 2 + PH;
  std::printf("  fast %lld ps, slow %lld ps (%.3f:1), phase %lld, jitter %lld, seed %u\n",
              TF, TS, double(TS) / double(TF), PH, JIT, seed0);
  d = new Vm2_texel_cdc;
  d->clk_fast = 0; d->clk_slow = 0; d->s_rst_n = 0; d->f_rst_n = 0;
  d->s_req = 0; d->s_take = 0; d->f_rdy = 1; d->f_ack = 0; d->f_texel = 0;
  d->eval();
  for (int i = 0; i < 100; ++i) step();
  d->s_rst_n = 1; d->f_rst_n = 1;
  running = true;

  const long N = envl("M2_TXC_N", 20000);
  // Phase 1: traffic at every pace -- bursts, trickles, a requester slow to take.
  for (int pace = 0; pace < 4 && fails == 0; ++pace) {
    issue_pct = (int[]){100, 70, 30, 100}[pace];
    take_pct  = (int[]){100, 60, 100, 15}[pace];
    const long until = N * (pace + 1) / 4;
    for (long g = 0; (issued < until || !in_flight.empty()) && g < 50000000; ++g) step();
  }
  CHECK(in_flight.empty() && taken == issued, "phase 1 lost answers: issued %ld taken %ld", issued, taken);
  std::printf("  phase 1: %ld fetches issued and taken in order, cache held at most %ld\n", issued, max_out);

  // Phase 2: the cache refuses for longer than the timeout, as a sweep does.
  allow_f = true; issue_pct = 100; take_pct = 100;
  // And it is sitting on a slow miss when it starts refusing: the answers it
  // owes are held past the timeout. A local answer must wait for them, or it
  // lands in front of an older request and every answer after is one off.
  for (long g = 0; g < 2000 && cache_q.size() < 2; ++g) step();
  stall = true;
  { long long k = 0; for (auto &a : cache_q) a.due = fast_cyc + 1500 + k++; }
  for (long g = 0; g < 200000; ++g) step();
  stall = false;
  for (long g = 0; (!in_flight.empty() || issued < N + 400) && g < 50000000; ++g) step();
  CHECK(in_flight.empty() && taken == issued, "phase 2 lost answers: issued %ld taken %ld", issued, taken);
  CHECK(local_f > 0, "the stall produced no local answers");
  std::printf("  phase 2: a stalled cache, %ld answered locally as 0xF\n", local_f);

  CHECK(max_out <= 4, "the cache held %ld unanswered, more than K", max_out);
  std::printf("  m2_texel_cdc: checks=%ld fails=%ld\n%s\n", checks, fails, fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
