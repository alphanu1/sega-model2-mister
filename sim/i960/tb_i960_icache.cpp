// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Harness for i960_icache.
//
// There is no reference model and there should not be one: MAME models no
// instruction cache, so there is nothing to lockstep against. The requirement
// is TRANSPARENCY — every fetch must return exactly the word external memory
// holds, whether it hit, missed, or came from a line filled ten fetches ago.
// That is checked on every fetch, not only on misses.
//
// The access patterns are chosen to attack the ways a direct-mapped cache goes
// wrong rather than to look busy: aliasing pairs that map to the same line from
// different tags, walks that wrap the whole cache, and repeated fetches inside
// one line to catch a word-select that ignores addr[3:2].
//
// TRANSPARENCY ALONE IS NOT ENOUGH, and this is the trap. A cache that never
// hits — one that fetches every word from memory and stores nothing — is
// perfectly transparent and completely useless, and a correctness-only harness
// passes it without complaint. So the miss rate is asserted too:
//
//   a sequential walk must miss about one fetch in four, because a 16-byte line
//   serves four dwords;
//   a second pass over data that fits in the cache must miss nothing at all.
//
// Those two bounds are what separate a working cache from an expensive wire.

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <map>
#include <random>
#include "Vi960_icache.h"
#include "verilated.h"

namespace {
Vi960_icache *dut = nullptr;
uint64_t fetches = 0, fails = 0, ticks = 0, misses = 0;
const int MAX_REPORT = 12;
std::map<uint32_t,uint32_t> mem;

uint32_t peek(uint32_t a) {
  auto it = mem.find(a & ~3u);
  return (it == mem.end()) ? 0xffffffffu : it->second;   // never zero
}

void tick() {
  if (dut->bus_req) { dut->bus_rdata = peek(dut->bus_addr); dut->bus_ack = 1; }
  else              { dut->bus_ack = 0; }
  dut->clk = 0; dut->eval();
  dut->clk = 1; dut->eval();
  ++ticks;
}

bool fetch(uint32_t a, const char *why) {
  dut->addr = a >> 2;          // port is [31:2]
  dut->req  = 1;
  const bool was_busy_before = false; (void)was_busy_before;
  tick();
  dut->req = 0;

  int i = 0;
  const int LIMIT = 100;
  bool saw_bus = false;
  for (; i < LIMIT; i++) {
    if (dut->bus_req) saw_bus = true;
    if (dut->valid) break;
    tick();
  }
  if (i == LIMIT) {
    std::printf("STALL fetch addr=%08x (%s) bus_req=%d\n", a, why, dut->bus_req);
    ++fails; return false;
  }
  if (saw_bus) ++misses;

  ++fetches;
  const uint32_t want = peek(a);
  if (dut->data != want) {
    if (fails < MAX_REPORT)
      std::printf("  MISMATCH [%s] addr=%08x got=%08x want=%08x\n",
                  why, a, dut->data, want);
    ++fails;
    return false;
  }
  return true;
}

void reset() {
  dut->rst_n = 0; dut->req = 0; dut->inval = 0; dut->bus_ack = 0;
  for (int i = 0; i < 4; i++) tick();
  dut->rst_n = 1; tick();
}
} // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  uint64_t rounds = 200000, seed = 1;
  for (int i = 1; i < argc; ++i) {
    if (!std::strncmp(argv[i], "+random=", 8)) rounds = std::strtoull(argv[i]+8, nullptr, 10);
    if (!std::strncmp(argv[i], "+seed=", 6))   seed   = std::strtoull(argv[i]+6, nullptr, 10);
  }
  dut = new Vi960_icache;

  // A 16 KB window of distinct words: 32 times the cache, so aliasing is
  // unavoidable rather than incidental.
  for (uint32_t a = 0; a < 0x4000; a += 4) mem[a] = 0xc0de0000u ^ (a * 2654435761u);

  reset();
  std::printf("i960_icache — transparency check (no oracle exists; none needed)\n");

  // Sequential walk across four times the cache size. One 16-byte line serves
  // four dwords, so a correct cache misses one fetch in four.
  {
    const uint64_t f0 = fetches, m0 = misses;
    for (uint32_t a = 0; a < 0x800; a += 4) fetch(a, "sequential");
    const double rate = double(misses - m0) / double(fetches - f0);
    const bool ok = rate > 0.20 && rate < 0.30;
    std::printf("  sequential walk 4x cache size      : miss rate %.3f %s\n",
                rate, ok ? "(expected ~0.25)" : "*** OUT OF BOUNDS ***");
    if (!ok) ++fails;
  }

  // Second pass over data that fits entirely in the cache must never miss.
  // This is the check a do-nothing cache fails.
  {
    reset();
    for (uint32_t a = 0; a < 0x200; a += 4) fetch(a, "warm");
    const uint64_t m0 = misses;
    for (uint32_t a = 0; a < 0x200; a += 4) fetch(a, "warm-2nd");
    const uint64_t missed = misses - m0;
    std::printf("  second pass over cache-sized data  : %llu misses %s\n",
                (unsigned long long)missed,
                missed == 0 ? "(expected 0)" : "*** CACHE NEVER HITS ***");
    if (missed != 0) ++fails;
  }

  // Same line, every word — catches a word select that ignores addr[3:2].
  for (int rep = 0; rep < 4; rep++)
    for (uint32_t w = 0; w < 16; w += 4) fetch(0x100 + w, "within-line");
  std::printf("  repeated fetches within one line\n");

  // Aliasing: addresses 512 bytes apart share a line and differ in tag.
  for (int rep = 0; rep < 64; rep++) {
    fetch(0x0040, "alias-A");
    fetch(0x0240, "alias-B");   // same index, different tag
    fetch(0x0440, "alias-C");
  }
  std::printf("  three-way line aliasing, 64 rounds\n");

  // Invalidate mid-stream and confirm the data is still right afterwards.
  for (uint32_t a = 0; a < 0x200; a += 4) fetch(a, "pre-inval");
  dut->inval = 1; tick(); dut->inval = 0; tick();
  for (uint32_t a = 0; a < 0x200; a += 4) fetch(a, "post-inval");
  std::printf("  invalidate mid-stream, refetch\n");

  std::mt19937_64 rng(seed);
  for (uint64_t k = 0; k < rounds && fails == 0; ++k)
    fetch(static_cast<uint32_t>(rng() % 0x4000) & ~3u, "random");
  std::printf("  random fetches over a 16 KB window : %llu\n",
              (unsigned long long)rounds);

  dut->final(); delete dut;
  std::printf("  %llu fetches (%llu missed) over %llu cycles, %llu mismatches\n",
              (unsigned long long)fetches, (unsigned long long)misses,
              (unsigned long long)ticks, (unsigned long long)fails);
  if (fails) { std::printf("FAIL\n"); return 1; }
  std::printf("PASS\n"); return 0;
}
