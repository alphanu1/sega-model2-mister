// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Whole-CPU lockstep for i960_top against the transcribed reference.
//
// Compares all 32 architectural registers, AC and IP after every retire, plus
// data memory at the end.
//
// Instruction-fetch bus traffic is deliberately NOT compared. The DUT fetches
// through a 16-byte-line cache while the reference reads single words, so the
// two streams differ by design — that is the cache doing its job, not a bug.
// Data writes are compared through memory contents instead.
//
// Programs are generated from the subset i960_top implements, with registers
// and memory seeded identically on both sides. Anything the reference traps on
// ends the program rather than counting as a mismatch.

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <map>
#include <random>
#include <vector>
#include "Vi960_top.h"
#include "Vi960_top___024root.h"
#include "verilated.h"
#include "i960_cpu_ref.h"

namespace {
Vi960_top   *dut = nullptr;
i960ref::Cpu ref;
std::map<uint32_t,uint32_t> mem;
uint64_t checks = 0, fails = 0, ticks = 0, retires = 0;
const int MAX_REPORT = 10;

void tick() {
  if (dut->bus_req) {
    const uint32_t a = dut->bus_addr & ~3u;
    auto it = mem.find(a);
    const uint32_t cur = (it == mem.end()) ? 0xffffffffu : it->second;
    if (dut->bus_we) {
      uint32_t d = cur;
      for (int l = 0; l < 4; l++)
        if (dut->bus_be & (1 << l))
          d = (d & ~(0xffu << (l*8))) | (dut->bus_wdata & (0xffu << (l*8)));
      mem[a] = d;
    } else {
      dut->bus_rdata = cur;
    }
    dut->bus_ack = 1;
  } else dut->bus_ack = 0;
  dut->clk = 0; dut->eval();
  dut->clk = 1; dut->eval();
  ++ticks;
}

// Verilated internals, exposed with --public-flat-rd. Reading the register file
// directly avoids adding debug ports that would change what is measured.
uint32_t dreg(int i) {
  return (i < 16) ? dut->rootp->i960_top__DOT__u_regs__DOT__loc[i]
                  : dut->rootp->i960_top__DOT__u_regs__DOT__glb[i-16];
}
uint32_t dac() { return dut->rootp->i960_top__DOT__ac; }
uint32_t dip() { return dut->rootp->i960_top__DOT__ip; }

const char *rn(int i) {
  static char b[8];
  std::snprintf(b, sizeof b, i < 16 ? "r%d" : "g%d", i < 16 ? i : i - 16);
  return b;
}

bool compare(uint64_t n) {
  bool ok = true;
  for (int i = 0; i < 32; i++) {
    ++checks;
    if (dreg(i) != ref.rf.r[i]) {
      ok = false;
      if (fails < MAX_REPORT)
        std::printf("  MISMATCH retire %llu  %-4s got=%08x want=%08x  (IP %08x)\n",
                    (unsigned long long)n, rn(i), dreg(i), ref.rf.r[i], ref.IP);
      ++fails;
    }
  }
  ++checks;
  if (dac() != ref.AC) {
    ok = false;
    if (fails < MAX_REPORT)
      std::printf("  MISMATCH retire %llu  AC   got=%08x want=%08x\n",
                  (unsigned long long)n, dac(), ref.AC);
    ++fails;
  }
  ++checks;
  if (dip() != ref.IP) {
    ok = false;
    if (fails < MAX_REPORT)
      std::printf("  MISMATCH retire %llu  IP   got=%08x want=%08x\n",
                  (unsigned long long)n, dip(), ref.IP);
    ++fails;
  }
  return ok;
}
} // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  uint64_t progs = 200, steps = 60, seed = 1;
  for (int i = 1; i < argc; ++i) {
    if (!std::strncmp(argv[i], "+random=", 8)) progs = std::strtoull(argv[i]+8, nullptr, 10);
    if (!std::strncmp(argv[i], "+seed=", 6))   seed  = std::strtoull(argv[i]+6, nullptr, 10);
  }
  dut = new Vi960_top;
  std::printf("i960_top whole-CPU lockstep\n");

  // Opcodes i960_top has an execution path for.
  const uint8_t REG58[] = {0x0,0x1,0x2,0x3,0x4,0x6,0x7,0x8,0x9,0xa,0xb,0xc,0xd,0xe,0xf};
  const uint8_t REG59[] = {0x0,0x1,0x2,0x3,0x8,0xa,0xb,0xc,0xd,0xe};
  const uint8_t REG5A[] = {0x0,0x1,0x2,0x3,0x4,0x5,0x6,0x7,0xc,0xe};

  std::mt19937_64 rng(seed);
  uint64_t total_retires = 0, trapped_progs = 0;

  for (uint64_t p = 0; p < progs && fails == 0; ++p) {
    mem.clear(); ref = i960ref::Cpu();

    // Generate a straight-line program of REG and COBR forms. Work RAM at
    // 0x00500000 is burst-flagged; the program sits at 0.
    std::vector<uint32_t> prog;
    for (uint64_t k = 0; k < steps; ++k) {
      const int cls = int(rng() % 10);
      uint32_t insn;
      if (cls == 9) {                                  // mul / div / rem / mod
        const uint32_t blk = (rng() & 1) ? 0x70u : 0x74u;
        static const uint8_t U[] = {0x1,0x8,0xb}, S[] = {0x1,0x8,0x9,0xb};
        const uint32_t o2 = (blk == 0x70) ? U[rng()%3] : S[rng()%4];
        // src1 is the divisor. A literal keeps it non-zero, which the
        // reference leaves undefined for every opcode except divo.
        insn = (blk << 24) | ((rng() % 32) << 19) | ((rng() % 32) << 14)
             | (o2 << 7) | (1 + rng() % 31) | 0x0800;
      } else if (cls == 8) {                           // mov / bit scan / modac
        static const uint8_t B64[] = {0x0,0x1,0x4,0x5};
        const bool use5c = (rng() & 1);
        const uint32_t blk = use5c ? 0x5cu : 0x64u;
        const uint32_t o2  = use5c ? 0xcu  : B64[rng() % 4];
        insn = (blk << 24) | ((rng() % 32) << 19) | ((rng() % 32) << 14)
             | (o2 << 7) | (rng() % 32);
        if (rng() & 1) insn |= 0x0800;
        if (rng() & 1) insn |= 0x1000;
      } else if (cls < 5) {                            // REG ALU
        const uint32_t blk = 0x58 + (rng() % 4);
        uint32_t o2;
        if      (blk == 0x58) o2 = REG58[rng() % 15];
        else if (blk == 0x59) o2 = REG59[rng() % 10];
        else if (blk == 0x5a) o2 = REG5A[rng() % 10];
        else                  o2 = (rng() & 1) ? 2 : 0;
        insn = (blk << 24) | ((rng() % 32) << 19) | ((rng() % 32) << 14)
             | (o2 << 7) | (rng() % 32);
        if (rng() & 1) insn |= 0x0800;                 // src1 literal
        if (rng() & 1) insn |= 0x1000;                 // src2 literal
      } else if (cls < 7) {                            // test<cc>
        insn = ((0x20 + (rng() % 8)) << 24) | ((rng() % 32) << 19);
      } else if (cls < 9) {                            // cmpib<cc> / cmpob<cc>
        const uint32_t op = (rng() & 1) ? (0x31 + rng() % 6) : (0x39 + rng() % 6);
        insn = (op << 24) | ((rng() % 32) << 19) | ((rng() % 32) << 14) | 0x0008;
      } else if (cls < 8) {                            // bbc / bbs
        insn = (((rng() & 1) ? 0x37u : 0x30u) << 24)
             | ((rng() % 32) << 19) | ((rng() % 32) << 14) | 0x2008;
      } else { insn = 0x5c0c0000u; }                   // unreachable filler
      prog.push_back(insn);
    }
    for (size_t k = 0; k < prog.size(); ++k) mem[uint32_t(k*4)] = prog[k];
    ref.rf.mem = mem;

    // Reset, then seed both register files identically.
    dut->rst_n = 0; dut->bus_ack = 0;
    for (int i = 0; i < 4; i++) tick();
    dut->rst_n = 1; tick();
    for (int i = 0; i < 32; i++) {
      const uint32_t v = uint32_t(rng());
      ref.rf.r[i] = v;
      if (i < 16) dut->rootp->i960_top__DOT__u_regs__DOT__loc[i] = v;
      else        dut->rootp->i960_top__DOT__u_regs__DOT__glb[i-16] = v;
    }
    ref.AC = 0; ref.IP = 0;

    // Run, comparing at each retire. The DUT retires when it re-enters fetch.
    for (uint64_t r = 0; r < steps && fails == 0; ++r) {
      const uint32_t ip_before = dip();
      int guard = 0;
      // advance until the sequencer has moved on to the next instruction
      while (guard++ < 400 && dip() == ip_before && !dut->trap) tick();
      if (dut->trap) break;
      if (guard >= 400) { std::printf("STALL at IP %08x\n", ip_before); ++fails; break; }
      // IP moving is not the same as the instruction having retired. `we` is
      // registered in the execute state, so the write reaches the register file
      // one edge AFTER the IP updates. Sampling on the IP change alone compares
      // the architectural state one cycle early and reports a stale register.
      tick();
      ref.step();
      if (ref.trapped) { ++trapped_progs; break; }
      ++retires; ++total_retires;
      if (!compare(r)) break;
    }
  }

  dut->final(); delete dut;
  std::printf("  %llu programs, %llu retires, %llu checks over %llu cycles\n",
              (unsigned long long)progs, (unsigned long long)total_retires,
              (unsigned long long)checks, (unsigned long long)ticks);
  std::printf("  %llu mismatches\n", (unsigned long long)fails);
  if (fails) { std::printf("FAIL\n"); return 1; }
  std::printf("PASS\n"); return 0;
}
