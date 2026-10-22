// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R927: i960_dcache against a flat memory, by TRANSPARENCY: every read the
// master is answered -- by the cache or by the bus behind it -- must return
// what memory holds, and every write must reach memory. Random reads and
// writes (every byte-enable pattern the load-store unit makes, and the odd
// one it does not) over a small set of lines so that hits, conflicts, partial
// writes into held words and refills all happen often; the bus answers after
// a random 0..LAT cycles; another master rewrites buffer RAM now and then,
// which the cache must never hold. Run with LANES 1 and 0 (Makefile).
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <map>
#include <random>
#include "Vi960_dcache.h"
#include "verilated.h"

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  uint64_t ops = 200000, seed = 1; int lat = 4;
  for (int i = 1; i < argc; ++i) {
    if (!std::strncmp(argv[i], "+ops=", 5)) ops = std::strtoull(argv[i] + 5, nullptr, 10);
    if (!std::strncmp(argv[i], "+seed=", 6)) seed = std::strtoull(argv[i] + 6, nullptr, 10);
    if (!std::strncmp(argv[i], "+lat=", 5)) lat = std::atoi(argv[i] + 5);
  }
  Vi960_dcache *d = new Vi960_dcache;
  std::mt19937_64 rng(seed);
  std::map<uint32_t, uint32_t> mem;   // unwritten memory reads 0xFFFFFFFF
  auto rdm = [&](uint32_t a) { auto it = mem.find(a & ~3u); return it == mem.end() ? 0xffffffffu : it->second; };
  auto tick = [&]() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };
  d->rst_n = 0; d->req = 0; d->ack_x = 0; tick(); tick(); d->rst_n = 1;
  for (int i = 0; i < 2000; ++i) tick();   // the reset sweep
  // addresses: a few lines in work RAM and board RAM that alias in the cache,
  // and one region it must never hold (buffer RAM)
  const uint32_t BASES[] = {0x500000u, 0x500000u + 0x400u, 0x500000u + 0x4000u, 0x20aa00u, 0x900000u, 0x5ff000u};
  uint64_t fails = 0, reads = 0, writes = 0, hits = 0;
  for (uint64_t k = 0; k < ops && fails < 10; ++k) {
    const uint32_t base = BASES[rng() % 6];
    const uint32_t a = base + uint32_t(rng() % 64) * 4u;
    const bool we = (rng() % 3) == 0;
    static const uint8_t BE[] = {0xf, 0xf, 0xf, 0x1, 0x2, 0x4, 0x8, 0x3, 0xc, 0x6};
    const uint8_t be = we ? BE[rng() % 10] : 0xf;
    const uint32_t wd = uint32_t(rng());
    d->req = 1; d->rd_ok = (rng() % 8) != 0; d->we = we; d->addr = a; d->be = be; d->wdata = wd;
    int wait = -1, cyc = 0; bool done = false;
    while (!done) {
      d->ack_x = 0; d->rdata_x = 0xdeadbeef;
      d->clk = 0; d->eval();
      const bool ext = d->req && !d->take && !d->ack;   // what the bridge sees
      if (ext) { if (wait < 0) wait = int(rng() % (lat + 1)); }
      if (ext && wait == 0) {
        d->ack_x = 1;
        if (we) { uint32_t v = rdm(a); for (int b = 0; b < 4; ++b) if (be & (1 << b)) v = (v & ~(0xffu << (8 * b))) | (wd & (0xffu << (8 * b))); mem[a & ~3u] = v; }
        else d->rdata_x = rdm(a);
        d->eval();
      }
      if (d->ack || d->ack_x) {
        if (!we) {
          const uint32_t got = d->ack ? d->rdata : d->rdata_x;
          if (d->ack) ++hits;
          if (got != rdm(a)) {
            ++fails;
            std::printf("  MISMATCH op %llu read %08x got %08x want %08x (%s)\n", (unsigned long long)k, a, got, rdm(a), d->ack ? "cache" : "bus");
          }
        }
        done = true;
      }
      d->clk = 1; d->eval();
      if (ext && wait > 0) --wait;
      if (++cyc > 1000) { std::printf("  STALL at op %llu\n", (unsigned long long)k); return 1; }
    }
    if (we) ++writes; else ++reads;
    d->req = 0;
    // another master writes buffer RAM behind the CPU (the TGP, the geometry
    // DMA): a cache that held it would answer the old word
    if ((rng() % 16) == 0) mem[0x900000u + uint32_t(rng() % 64) * 4u] = uint32_t(rng());
    const int gap = int(rng() % 3);
    for (int g = 0; g < gap; ++g) { d->ack_x = 0; tick(); }
  }
  std::printf("i960_dcache: %llu reads (%llu answered by the cache), %llu writes, lat 0..%d: %llu mismatches\n",
              (unsigned long long)reads, (unsigned long long)hits, (unsigned long long)writes, lat, (unsigned long long)fails);
  std::printf(fails ? "FAIL\n" : "PASS\n");
  delete d;
  return fails ? 1 : 0;
}
