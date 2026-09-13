// tb_m2_pair_cache -- a stream reader through the pair cache against a port
// that answers like m2_sdram_x2: a request taken on its rising edge, the
// dword at the index and the next one returned LAT cycles later, the
// acknowledge held while the request stands. The reader uses R208's
// handshake. Every word read must be the memory's word at that index, and a
// sequential run must cost about half the port trips.
#include "Vm2_pair_cache.h"
#include "Vm2_pair_cache___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>

static int checks = 0, fails = 0;
#define CHECK(c, ...) do { ++checks; if (!(c)) { ++fails; if (fails <= 12) { std::printf("  FAIL: " __VA_ARGS__); std::printf("\n"); } } } while (0)

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const int LAT = std::getenv("LAT") ? std::atoi(std::getenv("LAT")) : 6;
  auto d = new Vm2_pair_cache;
  std::vector<uint32_t> mem(1 << 16);
  for (size_t i = 0; i < mem.size(); i++) mem[i] = 0xA5000000u ^ (uint32_t(i) * 0x9E3779B1u);
  auto tick = [&]() { d->clk = 1; d->eval(); d->clk = 0; d->eval(); };
  d->clk = 0; d->rst_n = 0; d->req = 0; d->idx = 0; d->p_ack = 0; d->p_dout = 0; d->bypass = 0; d->inval = 0;
  tick(); tick(); d->rst_n = 1; tick();

  // The port model: rising-edge request, LAT cycles, then ack held while the
  // request stands; `done` clears when it falls (m2_sdram_x2).
  int p_req_d = 0, cnt = -1, done = 0; uint32_t p_idx_l = 0; long trips = 0;
  // The reader: R208. go = ack rising edge; drop req for a cycle after.
  int ack_d = 0, go_d = 0;

  long wait_cycles = 0;
  auto read_stream = [&](std::vector<uint32_t> idxs, const char *what) {
    long start_trips = trips, start_wait = wait_cycles;
    for (uint32_t ix : idxs) {
      d->idx = ix;
      bool got = false; int guard = 0;
      while (!got && guard++ < 200) {
        ++wait_cycles;   // R295: what the prefetch exists to reduce
        d->req = go_d ? 0 : 1;
        d->eval();
        // port model, on this cycle's outputs
        int pr = d->p_req;
        if (pr && !p_req_d && cnt < 0 && !done) { cnt = LAT; p_idx_l = d->p_idx; ++trips;
          if (getenv("M2_PC_TRACE") && trips < 12) printf("    port trip %ld: idx %u\n", trips, (unsigned)p_idx_l); }
        p_req_d = pr;
        if (getenv("M2_PC_CYC") && ix >= 101 && ix <= 102)
          printf("      ix=%u req=%d ack=%d data=%08x hit_pend=%d pf_own=%d p_ack=%d p_req=%d\n",
                 ix, d->req, d->ack, (unsigned)d->data,
                 d->rootp->m2_pair_cache__DOT__hit_pend, d->rootp->m2_pair_cache__DOT__pf_own,
                 d->p_ack, d->p_req);
        int go = d->ack && !ack_d;
        ack_d = d->ack;
        if (go && getenv("M2_PC_TRACE") && ix < 106)
          printf("    ack idx %u data %08x  have=%d have_idx=%u  pf_v=%d pf_idx=%u pf_req=%d\n",
                 ix, (unsigned)d->data, d->rootp->m2_pair_cache__DOT__have, (unsigned)d->rootp->m2_pair_cache__DOT__have_idx,
                 d->rootp->m2_pair_cache__DOT__pf_v, (unsigned)d->rootp->m2_pair_cache__DOT__pf_idx, d->rootp->m2_pair_cache__DOT__pf_req);
        if (go) {
          CHECK(d->data == mem[ix], "%s: idx %u read %08x, memory %08x", what, ix, (unsigned)d->data, mem[ix]);
          got = true;
        }
        go_d = go;
        tick();
        // registered port state
        if (cnt > 0) { if (--cnt == 0) { done = 1; d->p_dout = (uint64_t(mem[((p_idx_l & ~511u) | ((p_idx_l + 1) & 511u)) & 0xffff]) << 32) | mem[p_idx_l & 0xffff]; cnt = -1; } }  // the pair wraps inside the 512-dword row, as m2_sdram's burst does
        if (!d->p_req) done = 0;
        d->p_ack = done;
        d->eval();
      }
      CHECK(got, "%s: idx %u never acknowledged", what, ix);
      // the gap cycle
      d->req = 0; d->eval(); tick(); if (!d->p_req) done = 0; d->p_ack = done; d->eval(); go_d = 0;
      { int go = d->ack && !ack_d; ack_d = d->ack; CHECK(!go, "%s: a spurious acknowledge in the gap after idx %u", what, ix); }
    }
    std::printf("  %s: %zu words, %ld port trips, %ld cycles waiting (%.1f a word)\n",
                what, idxs.size(), trips - start_trips, wait_cycles - start_wait,
                double(wait_cycles - start_wait) / double(idxs.size()));
    return trips - start_trips;
  };

  std::vector<uint32_t> seq; for (uint32_t i = 100; i < 600; i++) seq.push_back(i);
  long w0 = wait_cycles;
  long t_seq = read_stream(seq, "sequential");
  CHECK(t_seq <= (long)seq.size() / 2 + 2, "sequential stream cost %ld trips for %zu words", t_seq, seq.size());
  // R295: THE PREFETCH IS FOR THE WAITING, NOT THE TRIPS. The pair alone gives
  // the trip count; what the board is short of is the CYCLES the engine stands
  // still. Without the prefetch a sequential word costs about 5.5 cycles here
  // -- a miss every other word at the port's latency -- and this reader has no
  // think time at all, so the real engine does better.
  const double seq_wait = double(wait_cycles - w0) / double(seq.size());
  CHECK(seq_wait < 5.0, "a sequential word waits %.1f cycles; the prefetch is not landing", seq_wait);

  std::vector<uint32_t> rnd; std::srand(7); for (int i = 0; i < 500; i++) rnd.push_back(std::rand() & 0xffff);
  long w1 = wait_cycles; long t1r = trips;
  read_stream(rnd, "random");
  // ... AND IT MUST NOT COST ANYTHING WHEN THE GUESS WOULD BE WRONG. Prefetching
  // on every miss put 750 trips on the port for 500 random words and took the
  // wait from 9.0 cycles a word to 13.0, because a demand queues behind a
  // useless transaction.
  const double rnd_wait = double(wait_cycles - w1) / double(rnd.size());
  CHECK(rnd_wait < 9.5, "a random word waits %.1f cycles; the prefetch is guessing", rnd_wait);
  CHECK(trips - t1r <= (long)rnd.size(), "random access cost %ld trips for %zu words",
        trips - t1r, rnd.size());

  // Sequential with rewrites between reads: the copy must not serve a stale
  // word. After reading idx N (which cached N+1), memory at N+1 changes and
  // is read next -- the cache will serve the OLD value: this is the one case
  // the single-use policy accepts, and the reader here reads in a fresh
  // stream after a random jump instead, which must miss.
  std::vector<uint32_t> mix; for (uint32_t i = 0; i < 300; i++) { mix.push_back(2000 + i); if (i % 7 == 6) mix.push_back(std::rand() & 0xffff); }
  read_stream(mix, "mixed");

  // R240: a sequential run that crosses a row edge with the odd index on the
  // port. 1535 is the row's last dword; its pair is the row's FIRST dword,
  // and 1536 must not be served from it.
  std::vector<uint32_t> edge; for (uint32_t i = 1529; i < 1580; i++) edge.push_back(i);
  read_stream(edge, "row edge, odd start");
  std::vector<uint32_t> edge2; for (uint32_t i = 3070; i < 3100; i++) edge2.push_back(i);
  read_stream(edge2, "row edge, even start");

  // R244: with `bypass` raised the cache keeps nothing, so a sequential run
  // costs one port trip per word and every word is still the memory's.
  d->bypass = 1;
  std::vector<uint32_t> byp; for (uint32_t i = 5000; i < 5060; i++) byp.push_back(i);
  long t_byp = read_stream(byp, "sequential, bypassed");
  CHECK(t_byp == (long)byp.size(), "bypassed stream cost %ld trips for %zu words", t_byp, byp.size());
  d->bypass = 0;

  // R266: AN INVALIDATE DROPS THE COPY, so the word after it comes from the
  // port and not from a copy taken before another master wrote the memory.
  // This is what the display list needs: the game patches a command's count in
  // after pushing its payload, and a copy taken in between holds the
  // placeholder.
  {
    // AN ODD NUMBER OF WORDS, so the run ENDS ON A MISS and the cache is
    // holding the copy of the next one. A hit clears the copy and does not take
    // a new one, so a run of even length leaves nothing to invalidate -- the
    // first version of this check ended that way and passed with the
    // invalidate removed.
    std::vector<uint32_t> pre; for (uint32_t i = 7000; i < 7009; i++) pre.push_back(i);
    read_stream(pre, "sequential, ending on a miss");
    long t1 = trips;
    std::vector<uint32_t> nxt; nxt.push_back(7009);
    read_stream(nxt, "the word after an invalidate");
    const long no_inval = trips - t1;
    // R295: THE PREFETCH IS A TRIP TOO. Reading the held word costs no DEMAND
    // trip, but the cache immediately asks for the pair after it -- so the
    // absolute count is 1, not 0, and what this test cares about is the
    // DIFFERENCE the invalidate makes, below.
    CHECK(no_inval <= 1, "the copy was not there to begin with, so this proves nothing");
    // now the same again WITH an invalidate between
    std::vector<uint32_t> pre2; for (uint32_t i = 7100; i < 7109; i++) pre2.push_back(i);
    read_stream(pre2, "sequential, ending on a miss");
    d->inval = 1; d->eval(); tick(); d->inval = 0; tick();
    long t2 = trips;
    std::vector<uint32_t> nxt2; nxt2.push_back(7109);
    read_stream(nxt2, "the word after an invalidate");
    CHECK(trips - t2 > no_inval,
          "the word after an invalidate was still served from the copy "
          "(%ld trips against %ld without)", trips - t2, no_inval);
  }

  std::printf("m2_pair_cache: checks=%d fails=%d\n", checks, fails);
  std::printf(fails ? "FAIL\n" : "PASS\n");
  delete d;
  return fails ? 1 : 0;
}
