// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// m2_sdram_cdc with the two clocks independent (study R561).
//
// Both clocks are driven from absolute time in picoseconds, so the ratio and
// the phase are test parameters rather than properties of the harness:
//
//   M2_CDC_TF    fast period, ps (default 10000: 100 MHz)
//   M2_CDC_TS    slow period, ps (default 16667: 60 MHz)
//   M2_CDC_PH    slow clock's phase offset, ps (default: from the seed)
//   M2_CDC_JIT   +/- ps of random jitter on every slow half-period (default 0)
//   M2_CDC_SEED  requester randomness
//   M2_CDC_N     reads per port in the concurrent phase (default 2000)
//
// EVERY PORT RUNS AT ONCE, each with its own requester, because the adapter's
// hazards are about one port's handshake landing next to another port's and
// next to the other clock's edges. A requester here does what the core's do:
// raises `req` with its address, holds both until it sees `ack`, drops `req`
// the cycle AFTER, and waits a random 1-4 cycles before the next -- one cycle
// being the case a level-synchronised acknowledge gets wrong.
//
// What is checked:
//   * every read returns what was written (the region is filled first);
//   * EXACTLY ONCE: the device model counts words it served, and every burst
//     issued here is four words. A request taken twice returns the same data,
//     so no value check can see it; only the count can;
//   * nothing hangs: a port waiting 20,000 of its own cycles fails;
//   * no acknowledge is showing on any edge at which the request is low;
//   * a request raised after a one-cycle gap is not acknowledged by the last
//     transaction's toggle: that returns the PREVIOUS address's data, which the
//     value check sees because consecutive reads use different addresses.

#include "Vm2_sdram_cdc_harness.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <map>
#include <vector>

static Vm2_sdram_cdc_harness *d;
static long checks = 0, fails = 0;
static long bursts = 0, writes = 0;
static std::map<uint32_t, uint16_t> shadow;

static uint32_t seed = 0x1234567u;
static uint32_t rnd() { seed = seed * 1103515245u + 12345u; return seed >> 8; }
static long envl(const char *n, long def) { const char *s = std::getenv(n); return s ? atol(s) : def; }

static void set_req(int p, bool v) {
  switch (p) { case 0: d->p0_req = v; break; case 1: d->p1_req = v; break;
               case 2: d->p2_req = v; break; case 3: d->p3_req = v; break;
               default: d->p4_req = v; }
}
static void set_addr(int p, uint32_t a) {
  switch (p) { case 0: d->p0_addr = a; break; case 1: d->p1_addr = a; break;
               case 2: d->p2_addr = a; break; case 3: d->p3_addr = a; break;
               default: d->p4_addr = a; }
}
static bool get_ack(int p) {
  switch (p) { case 0: return d->p0_ack; case 1: return d->p1_ack;
               case 2: return d->p2_ack; case 3: return d->p3_ack;
               default: return d->p4_ack; }
}
static uint64_t get_dout(int p) {
  switch (p) { case 0: return d->p0_dout; case 1: return d->p1_dout;
               case 2: return d->p2_dout; case 3: return d->p3_dout;
               default: return d->p4_dout; }
}

// ------------------------------------------------------------------ clocks
static long long t_now = 0;
static long long TF, TS, JIT;
static long long nf_edge, ns_edge;      // next toggle of each clock
static bool f_lvl = false, s_lvl = false;

// Advance to the next clock toggle. Returns 1 for a fast rising edge, 2 for a
// slow rising edge, 0 for a falling edge. Simultaneous edges are taken one at
// a time, fast first -- the same order either way, since both are evaluated
// before any requester acts on them.
// What each port's acknowledge showed JUST BEFORE the latest rising edge of its
// own clock -- the value a registered requester captures on that edge. Reading
// it after the edge's evaluation instead sees a flag that the same edge has
// already cleared.
static bool ack_pre[5];

static int step() {
  const bool fast = nf_edge <= ns_edge;
  t_now = fast ? nf_edge : ns_edge;
  if (fast && !f_lvl) ack_pre[4] = get_ack(4);
  if (!fast && !s_lvl) for (int p = 0; p < 4; ++p) ack_pre[p] = get_ack(p);
  if (fast) {
    f_lvl = !f_lvl; d->clk = f_lvl; nf_edge += TF / 2;
  } else {
    s_lvl = !s_lvl; d->clk_slow = s_lvl;
    long long h = TS / 2;
    if (JIT) h += (long long)(rnd() % (2 * JIT + 1)) - JIT;
    ns_edge += h;
  }
  d->eval();
  if (fast && f_lvl) return 1;
  if (!fast && s_lvl) return 2;
  return 0;
}

// ------------------------------------------------------------- requesters
enum St { IDLE, REQ, HOLD };
struct Rq {
  int p; bool fast;
  St st = IDLE; int gap = 0; long wait = 0;
  uint32_t addr = 0; int left = 0;
  std::vector<uint32_t> *list = nullptr; size_t li = 0;
};

static void check_read(int p, uint32_t addr, uint64_t got) {
  for (int w = 0; w < 4; ++w) {
    const uint32_t a = addr + w;
    const uint16_t want = shadow.count(a) ? shadow[a] : 0;
    const uint16_t g = uint16_t((got >> (16 * w)) & 0xffff);
    ++checks;
    if (g != want) {
      if (fails < 12)
        std::printf("  FAIL p%d addr=%06x word=%d got=%04x want=%04x  t=%lld ps\n",
                    p, a, w, g, want, t_now);
      ++fails;
    }
  }
}

static std::vector<uint32_t> region_r;   // filled before the concurrent phase

// One edge of a reader's own clock.
static void reader_edge(Rq &r) {
  switch (r.st) {
    case IDLE:
      // m2_sdram_x2's acknowledge fell within half a slow cycle of the request
      // falling, so a requester that registers `ack` without gating it by its
      // own `req` never saw one too many. This adapter must not give it one.
      // NOT FOR THE FAST PORT: that is m2_sdram_x2's own logic in one domain,
      // where `done` clears the cycle after the request falls, and the texel
      // and character caches have run against exactly that since R318.
      if (!r.fast) ++checks;
      if (!r.fast && ack_pre[r.p]) {
        if (fails < 12) std::printf("  FAIL p%d acknowledge with no request  t=%lld ps\n", r.p, t_now);
        ++fails;
      }
      if (r.left == 0) return;
      if (r.gap > 0) { --r.gap; return; }
      r.addr = r.list ? (*r.list)[r.li++ % r.list->size()]
                      : region_r[rnd() % region_r.size()];
      set_addr(r.p, r.addr); set_req(r.p, 1);
      r.st = REQ; r.wait = 0;
      return;
    case REQ:
      if (get_ack(r.p)) {
        check_read(r.p, r.addr, get_dout(r.p));
        ++bursts; --r.left;
        r.st = HOLD;             // drop the cycle AFTER, as a registered requester does
      } else if (++r.wait > 20000) {
        std::printf("  FAIL p%d hung at %06x  t=%lld ps\n", r.p, r.addr, t_now);
        ++fails; r.left = 0; r.st = IDLE; set_req(r.p, 0);
      }
      return;
    case HOLD:
      set_req(r.p, 0);
      r.gap = int(rnd() % 4);    // 0 here is a one-cycle gap: IDLE raises next edge
      r.st = IDLE;
      return;
  }
}

struct Wr { St st = IDLE; int gap = 0; long wait = 0; uint32_t addr = 0; uint16_t v = 0;
            std::vector<std::pair<uint32_t,uint16_t>> q; size_t qi = 0; };

static void writer_edge(Wr &w) {
  switch (w.st) {
    case IDLE:
      if (w.qi >= w.q.size()) return;
      if (w.gap > 0) { --w.gap; return; }
      w.addr = w.q[w.qi].first; w.v = w.q[w.qi].second; ++w.qi;
      d->wr_addr = w.addr; d->wr_din = w.v; d->wr_be = 3; d->wr_req = 1;
      w.st = REQ; w.wait = 0;
      return;
    case REQ:
      if (d->wr_ack) { shadow[w.addr] = w.v; ++writes; w.st = HOLD; }
      else if (++w.wait > 20000) {
        std::printf("  FAIL write %06x hung  t=%lld ps\n", w.addr, t_now);
        ++fails; w.qi = w.q.size(); w.st = IDLE; d->wr_req = 0;
      }
      return;
    case HOLD:
      d->wr_req = 0; w.gap = int(rnd() % 4); w.st = IDLE;
      return;
  }
}

static uint32_t rand_base(uint32_t region) {
  // Rows and banks spread, as m2_sdram_x2's test does; `region` keeps the
  // concurrently written addresses apart from the ones being read.
  return (region << 22) | ((rnd() % 6) << 13) | ((rnd() % 4) << 20) | ((rnd() % 64) << 2);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  TF  = envl("M2_CDC_TF", 10000);
  TS  = envl("M2_CDC_TS", 16667);
  JIT = envl("M2_CDC_JIT", 0);
  seed = uint32_t(envl("M2_CDC_SEED", 1));
  const uint32_t seed0 = seed;
  const long N = envl("M2_CDC_N", 2000);
  const long long PH = envl("M2_CDC_PH", (long long)(rnd() % (uint32_t)TS));
  nf_edge = TF / 2; ns_edge = TS / 2 + PH;
  std::printf("  fast %lld ps, slow %lld ps (%.3f:1), slow phase %lld ps, jitter %lld, seed %u\n",
              TF, TS, double(TS) / double(TF), PH, JIT, seed0);

  d = new Vm2_sdram_cdc_harness;
  d->clk = 0; d->clk_slow = 0; d->rst_n = 0;
  d->wr_req = 0; d->p0_we = 0; d->p0_din = 0; d->p0_be = 3;
  for (int p = 0; p < 5; ++p) { set_req(p, 0); set_addr(p, 0); }
  d->eval();
  for (int i = 0; i < 200; ++i) step();
  d->rst_n = 1;
  for (long i = 0; i < 200000 && !d->ready; ++i) step();
  if (!d->ready) { std::printf("  FAIL controller never became ready\n"); return 1; }

  // Phase 1: fill region 0 through the write port alone.
  Wr w;
  for (int i = 0; i < 256; ++i) {
    const uint32_t b = rand_base(0);
    region_r.push_back(b);
    for (int k = 0; k < 4; ++k) w.q.push_back({b + k, uint16_t(rnd())});
  }
  while (w.qi < w.q.size() || w.st != IDLE) if (step() == 2) writer_edge(w);
  std::printf("  filled %zu words\n", shadow.size());

  // Phase 2: five readers on region 0, and the writer on region 1, all at once.
  std::vector<Rq> rq(5);
  for (int p = 0; p < 5; ++p) { rq[p].p = p; rq[p].fast = (p == 4); rq[p].left = int(N); }
  Wr w2;
  std::vector<uint32_t> region_w;
  for (int i = 0; i < 256; ++i) {
    const uint32_t b = rand_base(1);
    region_w.push_back(b);
    for (int k = 0; k < 4; ++k) w2.q.push_back({b + k, uint16_t(rnd())});
  }
  auto busy = [&]() {
    for (auto &r : rq) if (r.left || r.st != IDLE) return true;
    return w2.qi < w2.q.size() || w2.st != IDLE;
  };
  while (busy()) {
    const int e = step();
    if (e == 1) reader_edge(rq[4]);
    if (e == 2) { for (int p = 0; p < 4; ++p) reader_edge(rq[p]); writer_edge(w2); }
  }
  std::printf("  concurrent: %ld bursts read on five ports, %zu words written\n",
              bursts, w2.q.size());

  // Phase 3: region 1 read back, each burst on every port.
  for (int p = 0; p < 5; ++p) { rq[p].list = &region_w; rq[p].li = 0; rq[p].left = int(region_w.size()); }
  while (busy()) {
    const int e = step();
    if (e == 1) reader_edge(rq[4]);
    if (e == 2) for (int p = 0; p < 4; ++p) reader_edge(rq[p]);
  }

  const long want = bursts * 4;
  std::printf("  bursts %ld, device served %u read words (want %ld); writes %ld, served %u\n",
              bursts, d->reads_served, want, writes, d->writes_served);
  if (long(d->reads_served) != want) {
    std::printf("  FAIL a read was taken more or less than once\n"); ++fails;
  }
  if (long(d->writes_served) != writes) {
    std::printf("  FAIL a write was taken more or less than once\n"); ++fails;
  }
  std::printf("  m2_sdram_cdc: checks=%ld fails=%ld violations=%u  (%.1f us simulated)\n",
              checks, fails, d->violations, t_now / 1e6);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
