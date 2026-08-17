// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Harness for i960_lsu. Compares the ordered bus transaction stream and the
// loaded words against the reference.
//
// The stream is the product. Two of the three behaviours this module exists to
// reproduce are invisible in the final register value and visible only here:
// an unaligned access issuing four byte transactions instead of one wide one,
// and a multi-word form NOT advancing its address in a non-burst region.
//
// Fatal stall detector, per docs/mister-integration.md: a hang that never
// returns says only "something is wrong".

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <map>
#include <random>
#include <vector>
#include "Vi960_lsu.h"
#include "verilated.h"
#include "i960_lsu_ref.h"

namespace {
Vi960_lsu *dut = nullptr;
uint64_t checks = 0, fails = 0, ticks = 0;
const int MAX_REPORT = 16;

std::map<uint32_t,uint32_t>  mem;      // shared: both sides see one memory
std::vector<i960ref::BusOp>  stream;
uint32_t st_words[4];
std::vector<uint32_t>        loaded;

void tick() {
  // Present the store word BEFORE sampling the bus. bus_wdata is combinational
  // from st_word now, so sampling first captures the previous word's value --
  // which was invisible while the LSU registered its bus outputs, and showed up
  // as 480 mismatches the moment it stopped. The caller in i960_top holds
  // st_word from a registered read, so this ordering is what the real design
  // does; the harness was relying on a delay that no longer exists.
  dut->st_word = st_words[dut->cur_idx & 3];
  dut->eval();

  // Serve the bus. Ack held while req is asserted, never pulsed.
  if (dut->bus_req) {
    const uint32_t da = dut->bus_addr & ~3u;
    auto it = mem.find(da);
    const uint32_t cur = (it == mem.end()) ? 0xffffffffu : it->second;
    if (dut->bus_we) {
      uint32_t d = cur;
      for (int lane = 0; lane < 4; ++lane)
        if (dut->bus_be & (1 << lane))
          d = (d & ~(0xffu << (lane*8))) | (dut->bus_wdata & (0xffu << (lane*8)));
      mem[da] = d;
      // Poison the read bus on a write cycle too: nothing may rely on rdata
      // surviving from an earlier read.
      dut->bus_rdata = 0xbaadf00du ^ uint32_t(ticks * 2654435761u);
      stream.push_back({dut->bus_addr, (uint8_t)dut->bus_be, true, dut->bus_wdata});
    } else {
      dut->bus_rdata = cur;
      stream.push_back({dut->bus_addr, (uint8_t)dut->bus_be, false, cur});
    }
    dut->bus_ack = 1;
  } else {
    dut->bus_ack = 0;
    // POISON THE BUS WHENEVER IT IS NOT ACKING A READ.
    //
    // This harness previously left bus_rdata holding its last value, which made
    // it stable across the extension state -- and i960_lsu extends `ld_word` in
    // S_NEXT, one state AFTER the ack. A DUT reading the live bus there looked
    // correct here and returned a later bus word in the real design, where the
    // instruction cache owns the bus by then. 1,265,853 passing checks could
    // not see it; the whole-CPU harness found it only once its generator
    // learned to emit loads.
    //
    // Real hardware makes no such promise, so neither does this. A value that
    // must be captured at the ack is now the only value that survives.
    dut->bus_rdata = 0xdeadbeefu ^ uint32_t(ticks * 2654435761u);
  }

  dut->clk = 0; dut->eval();
  dut->clk = 1; dut->eval();
  if (dut->ld_we) loaded.push_back(dut->ld_word);
  ++ticks;
}

bool run(uint32_t addr, uint8_t size, uint8_t nw, bool store, bool sext, bool burst) {
  stream.clear(); loaded.clear();
  std::map<uint32_t,uint32_t> ref_mem = mem;
  const i960ref::LsuResult r =
      i960ref::lsu(addr, size, nw, store, sext, burst, st_words, ref_mem);

  dut->req = 1; dut->addr = addr; dut->size = size; dut->n_words = nw;
  dut->is_store = store; dut->sign_ext = sext; dut->is_burst = burst;
  tick();
  dut->req = 0;

  const int LIMIT = 200;   // worst case is 4 words x 4 bytes x a few cycles
  int i = 0;
  for (; i < LIMIT; i++) { tick(); if (dut->done) break; }
  if (i == LIMIT) {
    std::printf("STALL addr=%08x size=%d nw=%d store=%d burst=%d "
                "bus_req=%d bus_addr=%08x\n",
                addr, size, nw, store, burst, dut->bus_req, dut->bus_addr);
    ++fails; return false;
  }
  tick();   // let the final ld_we land

  bool ok = true;
  ++checks;
  if (stream.size() != r.ops.size()) {
    ok = false;
    if (fails < MAX_REPORT)
      std::printf("  MISMATCH addr=%08x sz=%d nw=%d st=%d burst=%d : op count "
                  "got=%zu want=%zu\n", addr, size, nw, store, burst,
                  stream.size(), r.ops.size());
    ++fails;
  } else {
    for (size_t k = 0; k < stream.size(); k++) {
      ++checks;
      if (stream[k].addr != r.ops[k].addr || stream[k].be != r.ops[k].be ||
          stream[k].is_write != r.ops[k].is_write) {
        ok = false;
        if (fails < MAX_REPORT)
          std::printf("  MISMATCH addr=%08x sz=%d nw=%d burst=%d : op %zu got "
                      "%s %08x be=%x  want %s %08x be=%x\n", addr, size, nw, burst, k,
                      stream[k].is_write?"W":"R", stream[k].addr, stream[k].be,
                      r.ops[k].is_write?"W":"R", r.ops[k].addr, r.ops[k].be);
        ++fails;
      }
    }
  }
  ++checks;
  if (loaded.size() != r.loaded.size()) {
    ok = false;
    if (fails < MAX_REPORT)
      std::printf("  MISMATCH addr=%08x sz=%d nw=%d : loaded count got=%zu want=%zu\n",
                  addr, size, nw, loaded.size(), r.loaded.size());
    ++fails;
  } else {
    for (size_t k = 0; k < loaded.size(); k++) {
      ++checks;
      if (loaded[k] != r.loaded[k]) {
        ok = false;
        if (fails < MAX_REPORT)
          std::printf("  MISMATCH addr=%08x sz=%d sext=%d : word %zu got=%08x want=%08x\n",
                      addr, size, sext, k, loaded[k], r.loaded[k]);
        ++fails;
      }
    }
  }
  mem = ref_mem;   // keep both sides in step for the next request
  return ok;
}

void reset() {
  dut->rst_n = 0; dut->req = 0; dut->bus_ack = 0;
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
  dut = new Vi960_lsu;
  reset();
  std::printf("i960_lsu vs reference\n");

  for (int i = 0; i < 4; i++) st_words[i] = 0xa0b0c0d0u + i * 0x11111111u;
  for (uint32_t a = 0x1000; a < 0x1100; a += 4) mem[a] = 0xdeadbe00u + a;

  // Exhaustive over the axes that change the transaction sequence: every
  // address offset, every size, every word count, load and store, burst and
  // not. This is the whole behavioural space of the module.
  uint64_t n = 0;
  for (uint32_t off = 0; off < 8; ++off)
    for (uint8_t sz = 0; sz < 3; ++sz)
      for (uint8_t nw = 1; nw <= 4; ++nw)
        for (int st = 0; st < 2; ++st)
          for (int sx = 0; sx < 2; ++sx)
            for (int bu = 0; bu < 2; ++bu) {
              if (nw > 1 && sz != 2) continue;   // multi-word is dword-only
              run(0x1000 + off, sz, nw, st, sx, bu);
              ++n;
            }
  std::printf("  exhaustive offset x size x words x dir x burst : %llu requests\n",
              (unsigned long long)n);

  // Directed: the non-burst FIFO drain. Four words from one address.
  {
    mem[0x00884000] = 0x11111111u;
    const bool ok = run(0x00884000, 2, 4, false, false, /*burst=*/false);
    std::printf("  directed non-burst ldq (FIFO drain)           : %s\n",
                ok ? "4 reads, address held" : "MISMATCH");
  }

  std::mt19937_64 rng(seed);
  for (uint64_t k = 0; k < rounds && fails == 0; ++k) {
    const uint8_t sz = (uint8_t)(rng() % 3);
    const uint8_t nw = (sz == 2) ? (uint8_t)(1 + rng() % 4) : 1;
    for (int i = 0; i < 4; i++) st_words[i] = (uint32_t)rng();
    run(0x1000 + (uint32_t)(rng() & 0x3f), sz, nw, rng() & 1, rng() & 1, rng() & 1);
  }
  std::printf("  random requests                                : %llu (seed %llu)\n",
              (unsigned long long)rounds, (unsigned long long)seed);

  dut->final(); delete dut;
  std::printf("  %llu checks over %llu cycles, %llu mismatches\n",
              (unsigned long long)checks, (unsigned long long)ticks,
              (unsigned long long)fails);
  if (fails) { std::printf("FAIL\n"); return 1; }
  std::printf("PASS\n"); return 0;
}
