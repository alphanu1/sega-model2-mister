// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Harness for i960_fpmul against the host's own double multiply, which is what
// the reference uses — MAME computes in host `double`, so the host IS the
// oracle here rather than a transcription of one.
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
#include "Vi960_fpmul.h"
#include "verilated.h"

namespace {
Vi960_fpmul *dut = nullptr;
uint64_t checks = 0, fails = 0;
const int MAX_REPORT = 12;

union U { double d; uint64_t u; };

void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }

bool is_sub(double x) { return x != 0.0 && std::fabs(x) < 2.2250738585072014e-308; }

void check(double A, double B, const char *why) {
  U ua{A}, ub{B};
  dut->a = ua.u; dut->b = ub.u; dut->req = 1;
  tick(); dut->req = 0;
  for (int i = 0; i < 8 && !dut->done; i++) tick();

  const double want = A * B;
  if (is_sub(want)) return;                 // flushed here, not there

  U got; got.u = dut->y;
  ++checks;
  const bool both_nan = std::isnan(want) && std::isnan(got.d);
  if (!both_nan && got.u != U{want}.u) {
    if (fails < MAX_REPORT)
      std::printf("  MISMATCH [%s] %.17g * %.17g  got=%.17g (%016llx) want=%.17g (%016llx)\n",
                  why, A, B, got.d, (unsigned long long)got.u,
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
  dut = new Vi960_fpmul;
  dut->rst_n = 0; dut->req = 0;
  for (int i = 0; i < 4; i++) tick();
  dut->rst_n = 1; tick();
  std::printf("i960_fpmul vs the host double multiply\n");

  const double sp[] = {0.0, -0.0, 1.0, -1.0, 2.0, 0.5, 3.0, -7.25,
                       1e308, -1e308, 1e-300, 123456789.0,
                       INFINITY, -INFINITY, NAN};
  uint64_t c = 0;
  for (double A : sp) for (double B : sp) { check(A, B, "special"); ++c; }
  std::printf("  specials (zero, inf, nan, extremes) : %llu\n", (unsigned long long)c);

  std::mt19937_64 rng(seed);
  for (uint64_t k = 0; k < n && fails == 0; ++k) {
    U x, z; x.u = rng(); z.u = rng();
    if (std::isnan(x.d) || std::isnan(z.d)) continue;
    if (is_sub(x.d) || is_sub(z.d)) continue;
    check(x.d, z.d, "random");
  }
  std::printf("  random bit patterns                 : %llu (seed %llu)\n",
              (unsigned long long)n, (unsigned long long)seed);

  dut->final(); delete dut;
  std::printf("  %llu checks, %llu mismatches\n",
              (unsigned long long)checks, (unsigned long long)fails);
  if (fails) { std::printf("FAIL\n"); return 1; }
  std::printf("PASS\n"); return 0;
}
