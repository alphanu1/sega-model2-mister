// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Harness for i960_fpadd against the host's own double add and subtract, which
// is what the reference uses — MAME computes in host `double`, so the host IS
// the oracle here rather than a transcription of one.
//
// Subnormal operands and results are excluded. This unit flushes them and the
// host does not, so comparing there would test a documented deviation rather
// than the multiplier. Same discipline as the zero divisor and the overlapping
// mov: constrain the input, do not compare against a known difference.

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <random>
#include "Vi960_fpadd.h"
#include "verilated.h"

namespace {
Vi960_fpadd *dut = nullptr;
uint64_t checks = 0, fails = 0;
const int MAX_REPORT = 12;

union U { double d; uint64_t u; };

void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }

bool is_sub(double x) { return x != 0.0 && std::fabs(x) < 2.2250738585072014e-308; }

void check(double A, double B, bool sub, const char *why) {
  U ua{A}, ub{B};
  dut->a = ua.u; dut->b = ub.u; dut->sub = sub; dut->req = 1;
  tick(); dut->req = 0;
  for (int i = 0; i < 8 && !dut->done; i++) tick();

  const double want = sub ? (A - B) : (A + B);
  if (is_sub(want)) return;                 // flushed here, not there

  U got; got.u = dut->y;
  ++checks;
  const bool both_nan = std::isnan(want) && std::isnan(got.d);
  if (!both_nan && got.u != U{want}.u) {
    if (fails < MAX_REPORT)
      std::printf("  MISMATCH [%s] %.17g %s %.17g  got=%.17g (%016llx) want=%.17g (%016llx)\n",
                  why, A, sub ? "-" : "+", B, got.d, (unsigned long long)got.u,
                  want, (unsigned long long)U{want}.u);
    ++fails;
  }
  tick();
}
} // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  uint64_t n = 200000, seed = 1;
  for (int i = 1; i < argc; ++i) {
    if (!std::strncmp(argv[i], "+random=", 8)) n = std::strtoull(argv[i]+8, nullptr, 10);
    if (!std::strncmp(argv[i], "+seed=", 6))   seed = std::strtoull(argv[i]+6, nullptr, 10);
  }
  dut = new Vi960_fpadd;
  dut->rst_n = 0; dut->req = 0;
  for (int i = 0; i < 4; i++) tick();
  dut->rst_n = 1; tick();
  std::printf("i960_fpadd vs the host double add/subtract\n");

  const double sp[] = {0.0, -0.0, 1.0, -1.0, 2.0, 0.5, 3.0, -7.25,
                       1e308, -1e308, 1e-300, 123456789.0,
                       INFINITY, -INFINITY, NAN};
  uint64_t c = 0;
  for (double A : sp) for (double B : sp) for (int sb = 0; sb < 2; ++sb)
    { check(A, B, sb, "special"); ++c; }
  std::printf("  specials (zero, inf, nan, extremes) : %llu\n", (unsigned long long)c);

  // Values that differ by a few ulps, where massive cancellation forces the
  // leading-zero path. Uniform random almost never produces this and it is
  // where an adder is most likely to be wrong.
  {
    std::mt19937_64 r2(seed ^ 0x5eed);
    uint64_t nc = 0;
    for (int k = 0; k < 40000; ++k) {
      U x; x.u = r2();
      if (std::isnan(x.d) || std::isinf(x.d) || is_sub(x.d)) continue;
      U z; z.u = x.u + (r2() % 8) - 4;
      if (std::isnan(z.d) || std::isinf(z.d) || is_sub(z.d)) continue;
      check(x.d, z.d, 1, "cancellation"); ++nc;
      check(x.d, -z.d, 0, "cancellation"); ++nc;
    }
    std::printf("  near-cancellation pairs             : %llu\n",
                (unsigned long long)nc);
  }

  std::mt19937_64 rng(seed);
  for (uint64_t k = 0; k < n; ++k) {
    U x, z; x.u = rng(); z.u = rng();
    if (std::isnan(x.d) || std::isnan(z.d)) continue;
    if (is_sub(x.d) || is_sub(z.d)) continue;
    check(x.d, z.d, rng() & 1, "random");
  }
  std::printf("  random bit patterns                 : %llu (seed %llu)\n",
              (unsigned long long)n, (unsigned long long)seed);

  dut->final(); delete dut;
  std::printf("  %llu checks, %llu mismatches\n",
              (unsigned long long)checks, (unsigned long long)fails);
  if (fails) { std::printf("FAIL\n"); return 1; }
  std::printf("PASS\n"); return 0;
}
