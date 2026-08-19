// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// Harness for i960_regs against the transcribed reference.
//
// Compares all 32 architectural registers AND the external memory operation
// stream after every frame operation. The stream is the point: cache depth and
// the spill condition are invisible in the registers and obvious in memory
// traffic, so a register-only comparison would pass a design that spilled at
// the wrong depth, in the wrong order, or to the wrong address.
//
// Sequences are random but weighted to reach depth 4 and beyond, because
// everything interesting — the spill path, the fill path, and the post-flushreg
// negative-depth case — only happens there. Uniform choice between call and ret
// random-walks around depth 1 and would almost never spill.
//
// There is a stall detector. docs/mister-integration.md: a hang that never
// returns says only "something is wrong", while one that prints the state
// holding the handshake is a diagnosis. It is fatal, because a stalled run
// exiting zero is a test reporting success for a core that cannot function.

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>

#include "Vi960_regs.h"
#include "verilated.h"
#include "i960_regs_ref.h"

namespace {

Vi960_regs      *dut = nullptr;
i960ref::Regs    ref;
uint64_t         checks = 0, fails = 0;
const int        MAX_REPORT = 16;
uint64_t         tick_count = 0;

// Memory model. Unwritten reads return 0xFFFFFFFF, matching the reference and
// the standing requirement — zero is a legal value everywhere and flatters a
// broken core.
std::map<uint32_t, uint32_t> dut_mem;
std::vector<i960ref::MemOp>  dut_stream;

void tick() {
  // Serve the memory port. Ack is held while a request is asserted rather than
  // pulsed: a one-cycle ack to a requester that is not looking is missed, and
  // the requester waits forever. That fault bit Model 1 twice.
  if (dut->mem_req) {
    if (dut->mem_we) {
      dut_mem[dut->mem_addr] = dut->mem_wdata;
      dut_stream.push_back({dut->mem_addr, dut->mem_wdata, true});
    } else {
      auto it = dut_mem.find(dut->mem_addr);
      const uint32_t v = (it == dut_mem.end()) ? 0xffffffffu : it->second;
      dut->mem_rdata = v;
      dut_stream.push_back({dut->mem_addr, v, false});
    }
    dut->mem_ack = 1;
  } else {
    dut->mem_ack = 0;
  }

  dut->clk = 0; dut->eval();
  dut->clk = 1; dut->eval();
  ++tick_count;
}

// Run until the module is idle again, or fail loudly.
bool settle(const char *what) {
  const int LIMIT = 400;          // an order of magnitude past the worst case:
                                  // flushreg is 4 frames x 16 words = 64 acks
  for (int i = 0; i < LIMIT; i++) {
    tick();
    if (!dut->busy) return true;
  }
  std::printf("STALL after %d cycles during %s\n", LIMIT, what);
  std::printf("  busy=%d mem_req=%d mem_we=%d mem_addr=%08x\n",
              dut->busy, dut->mem_req, dut->mem_we, dut->mem_addr);
  return false;
}

uint32_t dut_reg(int i) {
  // The read port is registered now (see i960_regs.sv), so the address has to
  // be presented an edge before the data is valid. Reading it through the port
  // rather than reaching into the array keeps this a test OF the port.
  // Safe to clock here: `we` is cleared by wr_reg and the op_* strobes are
  // pulsed, so an idle file stays idle across this edge.
  dut->ra1 = i & 0x1f;
  tick();
  return dut->rd1;
}

void wr_reg(int i, uint32_t v) {
  dut->wa = i & 0x1f;
  dut->wd = v;
  dut->we = 1;
  tick();
  dut->we = 0;
  ref.r[i & 0x1f] = v;
}

const char *regname(int i) {
  static char b[8];
  if (i == 0) return "r0/PFP";
  if (i == 1) return "r1/SP";
  if (i == 2) return "r2/RIP";
  if (i == 31) return "g15/FP";
  std::snprintf(b, sizeof b, i < 16 ? "r%d" : "g%d", i < 16 ? i : i - 16);
  return b;
}

size_t g_cursor = 0;
void stream_cursor_reset() { g_cursor = 0; }

bool compare(const char *what) {
  bool ok = true;

  for (int i = 0; i < 32; i++) {
    ++checks;
    const uint32_t got = dut_reg(i), want = ref.r[i];
    if (got != want) {
      ok = false;
      if (fails < MAX_REPORT)
        std::printf("  MISMATCH [%s] %-7s got=%08x want=%08x  (depth %d)\n",
                    what, regname(i), got, want, ref.rcache_pos);
      ++fails;
    }
  }

  // The memory stream, in order, comparing only what is new since the last
  // call. Re-walking the whole stream every time is O(n^2) and inflates the
  // check count into a number that means nothing — see the standing note about
  // reporting verification figures honestly.
  size_t &cursor = g_cursor;
  ++checks;
  if (dut_stream.size() != ref.stream.size()) {
    ok = false;
    if (fails < MAX_REPORT)
      std::printf("  MISMATCH [%s] memory op count got=%zu want=%zu\n",
                  what, dut_stream.size(), ref.stream.size());
    ++fails;
  } else {
    for (size_t i = cursor; i < dut_stream.size(); i++) {
      ++checks;
      if (!(dut_stream[i] == ref.stream[i])) {
        ok = false;
        if (fails < MAX_REPORT)
          std::printf("  MISMATCH [%s] mem op %zu got %s %08x=%08x  "
                      "want %s %08x=%08x\n", what, i,
                      dut_stream[i].is_write ? "W" : "R",
                      dut_stream[i].addr, dut_stream[i].data,
                      ref.stream[i].is_write ? "W" : "R",
                      ref.stream[i].addr, ref.stream[i].data);
        ++fails;
      }
    }
    cursor = dut_stream.size();
  }
  return ok;
}

void do_call(uint32_t ret_ip, uint32_t target, int type, uint32_t stack) {
  dut->call_ip     = ret_ip;
  dut->call_target = target;
  dut->call_type   = type;
  dut->call_stack  = stack;
  dut->op_call     = 1;
  tick();
  dut->op_call = 0;
  settle("call");
  ref.call(ret_ip, target, type, stack);
}

void do_ret() {
  dut->op_ret = 1;
  tick();
  dut->op_ret = 0;
  settle("ret");
  ref.ret();
}

void do_flush() {
  dut->op_flushreg = 1;
  tick();
  dut->op_flushreg = 0;
  settle("flushreg");
  ref.flushreg();
}

void stream_cursor_reset();

void reset() {
  dut->rst_n = 0;
  dut->we = dut->op_call = dut->op_ret = dut->op_flushreg = 0;
  dut->ra1 = dut->ra2 = 0;
  for (int i = 0; i < 4; i++) tick();
  dut->rst_n = 1;
  tick();

  // Architectural registers are undefined at reset on the real part and the
  // arrays are deliberately not cleared (clearing an array in reset forces it
  // out of RAM into flip-flops). So seed both sides identically instead.
  for (int i = 0; i < 32; i++) wr_reg(i, 0x10000000u + i * 0x40u);
  ref.rcache_pos = 0;
  ref.mem.clear(); ref.stream.clear();
  dut_mem.clear(); dut_stream.clear();
  stream_cursor_reset();
}

} // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  uint64_t rounds = 20000;
  uint64_t seed   = 1;
  for (int i = 1; i < argc; ++i) {
    if (!std::strncmp(argv[i], "+random=", 8)) rounds = std::strtoull(argv[i] + 8, nullptr, 10);
    if (!std::strncmp(argv[i], "+seed=",   6)) seed   = std::strtoull(argv[i] + 6, nullptr, 10);
  }

  dut = new Vi960_regs;
  std::printf("i960_regs vs reference\n");

  // ---- directed: drive depth past the cache and back, which is where the
  // spill and fill paths live and where a depth-off-by-one hides.
  reset();
  for (int d = 0; d < 8; d++) {
    do_call(0x1000 + d * 0x10, 0x2000 + d * 0x10, 0, 0);
    if (!compare("deep call")) break;
  }
  for (int d = 0; d < 8; d++) {
    do_ret();
    if (!compare("deep ret")) break;
  }
  std::printf("  directed deep call/ret : depth 0..8 and back\n");

  // ---- directed: flushreg at every depth, then a ret, which is the
  // negative-rcache_pos case do_ret_0 has a special branch for.
  for (int d = 0; d <= 5; d++) {
    reset();
    for (int k = 0; k < d; k++) do_call(0x3000 + k, 0x4000 + k, 0, 0);
    do_flush();
    compare("flushreg");
    do_ret();
    compare("ret after flushreg");
  }
  std::printf("  directed flushreg      : depths 0..5, each followed by ret\n");

  // ---- directed: interrupt-type call, which overrides SP.
  reset();
  do_call(0x5000, 0x6000, 7, 0x00080000);
  compare("call type 7");
  do_ret();
  compare("ret from type 7");
  std::printf("  directed type-7 call   : SP override\n");

  // ---- random sequences, weighted toward depth.
  std::mt19937_64 rng(seed);
  reset();
  int depth = 0;
  for (uint64_t k = 0; k < rounds && fails == 0; k++) {
    const int roll = static_cast<int>(rng() % 100);
    if (roll < 8) {
      {
        // PFP[2:0] IS THE RETURN TYPE, and only 0 and 7 are architecturally
        // legal -- MAME fatalerrors on 1 to 6 and the module now raises
        // ret_unsupported for them. A random write to r0 could previously
        // manufacture an illegal type, which the old reference then returned
        // from as though it were type 0. Keep the other 29 bits random.
        const int      reg = static_cast<int>(rng() % 32);
        uint32_t       val = static_cast<uint32_t>(rng());
        if (reg == 0) val = (val & ~7u) | ((rng() & 1) ? 7u : 0u);
        wr_reg(reg, val);
      }
    } else if (roll < 12) {
      do_flush(); depth = 0;
      if (!compare("rand flushreg")) break;
    } else if (roll < 58 || depth == 0) {
      const int type = (rng() % 32 == 0) ? 7 : 0;
      do_call(static_cast<uint32_t>(rng()) & ~3u,
              static_cast<uint32_t>(rng()) & ~3u, type,
              (static_cast<uint32_t>(rng()) & 0x000ffff0u) + 0x00100000u);
      depth++;
      if (!compare("rand call")) break;
    } else {
      do_ret(); if (depth) depth--;
      if (!compare("rand ret")) break;
    }
  }
  std::printf("  random sequences       : %llu ops (seed %llu)\n",
              static_cast<unsigned long long>(rounds),
              static_cast<unsigned long long>(seed));

  dut->final();
  delete dut;

  std::printf("  %llu checks over %llu cycles, %llu mismatches\n",
              static_cast<unsigned long long>(checks),
              static_cast<unsigned long long>(tick_count),
              static_cast<unsigned long long>(fails));
  if (fails) { std::printf("FAIL\n"); return 1; }
  std::printf("PASS\n");
  return 0;
}
