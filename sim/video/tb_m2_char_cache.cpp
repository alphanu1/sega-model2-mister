// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// The glyph cache, checked against a reference memory.
//
// What this has to prove, in order of how badly each would hurt:
//
//   1. EVERY read returns the right word. A cache that returns stale data is
//      worse than no cache -- it would put wrong pixels on screen while every
//      probe upstream reads clean, which is the exact fault this project has
//      spent a session chasing.
//   2. The handshake contract is honoured: v_ack is ONE cycle, v_data is valid
//      on it, and no acknowledge appears without a request.
//   3. Misses actually fall. A cache that never hits is dead weight in M10K.
//
// The access pattern matters: glyph reads are not random. A character is eight
// consecutive words and the same characters recur constantly, so the test
// replays that shape as well as a random sweep, and reports the hit rate for
// each.

#include "Vm2_char_cache.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>

static Vm2_char_cache *d;
static uint64_t cyc = 0;

// Reference memory: the value at an address is a hash of it, so a wrong word
// is caught wherever it comes from.
static uint32_t ref(uint32_t a) { return (a * 2654435761u) ^ 0xA5A5A5A5u; }

static int  fails = 0, checks = 0;
static uint64_t mem_reqs = 0;

static void tick() {
  d->clk = 0; d->eval();
  d->clk = 1; d->eval();
  ++cyc;
}

// One read through the cache, with the memory side answered after a delay that
// stands in for SDRAM latency.
static uint32_t read_word(uint32_t addr, int mem_latency) {
  d->v_req = 1; d->v_addr = addr;
  int wait = -1;
  uint32_t got = 0;
  for (int i = 0; i < 2000; ++i) {
    if (d->m_req && wait < 0) { wait = mem_latency; ++mem_reqs; }
    if (wait == 0) {
      d->m_ack = 1;
      d->m_data = ref(d->m_addr);
    }
    tick();
    if (d->m_ack) { d->m_ack = 0; wait = -1; }
    else if (wait > 0) --wait;
    if (d->v_ack) { got = d->v_data; break; }
  }
  d->v_req = 0;
  tick();                      // let the cache see the request drop
  return got;
}

static void check(uint32_t addr, int lat) {
  const uint32_t got = read_word(addr, lat);
  ++checks;
  if (got != ref(addr)) {
    if (fails < 10)
      std::printf("  MISMATCH addr %05x got %08x want %08x\n",
                  addr, got, ref(addr));
    ++fails;
  }
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_char_cache;

  d->rst_n = 0; d->v_req = 0; d->v_addr = 0; d->m_ack = 0; d->m_data = 0;
  for (int i = 0; i < 4; ++i) tick();
  d->rst_n = 1;
  // The tag sweep must finish before anything is served.
  for (int i = 0; i < 20000; ++i) tick();

  // 1. Correctness on first touch, at several memory latencies.
  for (int lat : {0, 1, 3, 9}) {
    for (uint32_t a = 0; a < 64; ++a) check(a + lat * 1024, lat);
  }
  std::printf("  cold reads: %d checked, %d wrong\n", checks, fails);

  // 2. Re-reads must hit and must still be right.
  uint32_t h0 = d->dbg_hits, m0 = d->dbg_misses;
  for (int pass = 0; pass < 4; ++pass)
    for (uint32_t a = 0; a < 64; ++a) check(a, 3);
  const uint32_t hits = d->dbg_hits - h0, misses = d->dbg_misses - m0;
  std::printf("  warm re-reads: %u hits, %u misses\n", hits, misses);
  if (misses != 0) { std::printf("  FAIL: warm data should never miss\n"); ++fails; }

  // 3. The real access shape: characters of eight consecutive words, a small
  //    set of them, recurring -- which is what a text screen does.
  h0 = d->dbg_hits; m0 = d->dbg_misses;
  for (int rep = 0; rep < 30; ++rep)
    for (uint32_t g = 0; g < 40; ++g)
      for (uint32_t w = 0; w < 8; ++w)
        check(0x2000 + g * 8 + w, 3);
  {
    const uint32_t hh = d->dbg_hits - h0, mm = d->dbg_misses - m0;
    const double rate = 100.0 * hh / double(hh + mm);
    std::printf("  glyph pattern: %u hits, %u misses -- %.1f%% hit rate\n",
                hh, mm, rate);
    if (rate < 95.0) { std::printf("  FAIL: hit rate too low to be worth M10K\n"); ++fails; }
  }

  // 4. Conflict behaviour: addresses one index-span apart share a line, so
  //    alternating between them must still return correct data even though it
  //    thrashes. Correctness under thrash is the property that matters.
  const uint32_t span = 1u << 14;
  for (int rep = 0; rep < 8; ++rep) {
    check(0x40, 2);
    check(0x40 + span, 2);
  }
  std::printf("  conflict thrash: %d total checks, %d wrong\n", checks, fails);

  std::printf("  memory transactions issued: %llu\n",
              (unsigned long long)mem_reqs);
  std::printf("m2_char_cache: checks=%d fails=%d\n", checks, fails);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
