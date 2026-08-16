// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Harness for i960_muldiv.
//
// A zero divisor is never generated. The reference leaves it undefined for
// every opcode except divo, so comparing there would test the host's C++
// runtime rather than the design — the same reason Model 1 constrained shift
// counts to 0..31 instead of comparing against undefined behaviour. The RTL's
// defined answer for a zero divisor is documented in its header and exercised
// by a directed case against divo, which IS defined.
//
// INT_MIN / -1 is also excluded: it overflows a signed 32-bit quotient and is
// undefined in C++ too.

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <random>
#include "Vi960_muldiv.h"
#include "verilated.h"
#include "i960_muldiv_ref.h"

namespace {
Vi960_muldiv *dut = nullptr;
uint64_t checks = 0, fails = 0, ticks = 0;
const int MAX_REPORT = 16;

void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); ++ticks; }

bool run(uint8_t op, uint8_t op2, uint32_t t1, uint32_t t2, uint32_t t2hi,
         const char *why) {
  dut->op = op; dut->op2 = op2;
  dut->src1 = t1; dut->src2 = t2; dut->src2_hi = t2hi;
  dut->eval();

  const i960ref::MdOut r0 = i960ref::muldiv(op, op2, t1, t2, t2hi);

  // `valid` is combinational and is checked BEFORE issuing, which is how the
  // sequencer uses it. An unimplemented op never starts and therefore never
  // asserts done — waiting on it would hang rather than fail, which is exactly
  // what the first run of this harness did.
  ++checks;
  if (bool(dut->valid) != r0.valid) {
    if (fails < MAX_REPORT)
      std::printf("  MISMATCH [%s] %02x.%x valid got=%d want=%d\n",
                  why, op, op2, dut->valid, r0.valid);
    ++fails; return false;
  }
  if (!r0.valid) return true;

  dut->req = 1; tick(); dut->req = 0;

  int i = 0; const int LIMIT = 200;
  for (; i < LIMIT; i++) { if (dut->done) break; tick(); }
  if (i == LIMIT) {
    std::printf("STALL op=%02x.%x t1=%08x t2=%08x\n", op, op2, t1, t2);
    ++fails; return false;
  }
  const i960ref::MdOut r = r0;
  struct { const char *n; uint32_t got, want; bool on; } f[] = {
    { "lo",    dut->res_lo,   r.lo,    r.valid },
    { "hi",    dut->res_hi,   r.hi,    r.valid && r.pair },
    { "pair",  dut->res_pair, r.pair,  r.valid },
  };
  bool ok = true;
  for (auto &x : f) {
    if (!x.on) continue;
    ++checks;
    if (x.got != x.want) {
      ok = false;
      if (fails < MAX_REPORT)
        std::printf("  MISMATCH [%s] %02x.%x t1=%08x t2=%08x hi=%08x  %-5s "
                    "got=%08x want=%08x\n", why, op, op2, t1, t2, t2hi,
                    x.n, x.got, x.want);
      ++fails;
    }
  }
  tick();
  return ok;
}
} // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  uint64_t n = 200000, seed = 1;
  for (int i = 1; i < argc; ++i) {
    if (!std::strncmp(argv[i], "+random=", 8)) n = std::strtoull(argv[i]+8, nullptr, 10);
    if (!std::strncmp(argv[i], "+seed=", 6))   seed = std::strtoull(argv[i]+6, nullptr, 10);
  }
  dut = new Vi960_muldiv;
  dut->rst_n = 0; dut->req = 0;
  for (int i = 0; i < 4; i++) tick();
  dut->rst_n = 1; tick();
  std::printf("i960_muldiv vs reference\n");

  struct { uint8_t op, op2; const char *n; } OPS[] = {
    {0x70,0x1,"mulo"}, {0x70,0x8,"remo"}, {0x70,0xb,"divo"},
    {0x74,0x1,"muli"}, {0x74,0x8,"remi"}, {0x74,0x9,"modi"}, {0x74,0xb,"divi"},
    {0x67,0x0,"emul"}, {0x67,0x1,"ediv"},
  };

  // Exhaustive over op/op2 including unimplemented pairs, so `valid` is
  // checked across the whole space.
  uint64_t c = 0;
  for (uint32_t o : {0x67u, 0x70u, 0x74u})
    for (uint32_t o2 = 0; o2 < 16; ++o2) { run(o, o2, 7, 100, 0, "opspace"); ++c; }
  std::printf("  op space (incl. unimplemented) : %llu\n", (unsigned long long)c);

  // Directed: sign combinations, and the values where truncation and remainder
  // sign actually differ between languages and hardware.
  const int32_t vals[] = {1,-1,2,-2,7,-7,100,-100,0x7fffffff,-0x7fffffff,3,-3};
  c = 0;
  for (auto &O : OPS)
    for (int32_t a : vals)
      for (int32_t b : vals) {
        if (a == 0) continue;
        run(O.op, O.op2, uint32_t(a), uint32_t(b), 0, "signs"); ++c;
      }
  std::printf("  directed sign/truncation cases : %llu\n", (unsigned long long)c);

  // divo IS defined for a zero divisor — the reference guards it explicitly.
  run(0x70, 0xb, 0, 12345, 0, "divo-zero");
  std::printf("  divo with zero divisor         : defined, compared\n");

  std::mt19937_64 rng(seed);
  for (uint64_t k = 0; k < n && fails == 0; ++k) {
    const auto &O = OPS[rng() % (sizeof OPS / sizeof OPS[0])];
    uint32_t t1 = uint32_t(rng()), t2 = uint32_t(rng()), th = uint32_t(rng());
    if (t1 == 0) t1 = 1;                                   // never undefined
    if (t1 == 0xffffffffu && t2 == 0x80000000u) t2 = 1;    // INT_MIN / -1
    run(O.op, O.op2, t1, t2, th, "random");
  }
  std::printf("  random                         : %llu (seed %llu)\n",
              (unsigned long long)n, (unsigned long long)seed);

  dut->final(); delete dut;
  std::printf("  %llu checks over %llu cycles, %llu mismatches\n",
              (unsigned long long)checks, (unsigned long long)ticks,
              (unsigned long long)fails);
  if (fails) { std::printf("FAIL\n"); return 1; }
  std::printf("PASS\n"); return 0;
}
