// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Harness for i960_fpadd against the host's own double add and subtract, which
// is what the reference uses — MAME computes in host `double`, so the host IS
// the oracle here rather than a transcription of one.
//
// R1013: subnormal operands and results are compared too -- the unit takes
// and delivers them (SUBNORM 1), as the host does under its default mode
// (gradual underflow, no flush-to-zero). Built with -DTB_FLUSH the bench
// checks a SUBNORM 0 unit instead and excludes them, as it did before.

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
#ifdef TB_FLUSH
const bool FLUSH = true;
#else
const bool FLUSH = false;
#endif
uint64_t n_sub_in = 0, n_sub_out = 0;   // checks with a subnormal operand / result

// R1013: an exponent field in 0..span (sign and fraction random) -- the
// operands near and below 2^-1022 that uniform bit patterns almost never give.
double tiny(std::mt19937_64 &r, unsigned span) {
  U x; x.u = (r() & 0x800fffffffffffffull) | (uint64_t(r() % (span + 1)) << 52);
  return x.d;
}

void check(double A, double B, bool sub, const char *why) {
  U ua{A}, ub{B};
  dut->a = ua.u; dut->b = ub.u; dut->sub = sub; dut->req = 1;
  tick(); dut->req = 0;
  for (int i = 0; i < 8 && !dut->done; i++) tick();

  const double want = sub ? (A - B) : (A + B);
  if (FLUSH && (is_sub(want) || is_sub(A) || is_sub(B))) { tick(); return; }
  if (is_sub(A) || is_sub(B)) ++n_sub_in;
  if (is_sub(want)) ++n_sub_out;

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
                       INFINITY, -INFINITY, NAN,
                       // R1013: +-min / max subnormal, +-min normal, between
                       4.9406564584124654e-324, -4.9406564584124654e-324,
                       2.2250738585072009e-308, -2.2250738585072009e-308,
                       2.2250738585072014e-308, -2.2250738585072014e-308,
                       1.5e-308, -3e-320, 4.4501477170144028e-308};
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
      if (k & 1) x.d = tiny(r2, 4);              // R1013: cancelling to subnormals
      if (std::isnan(x.d) || std::isinf(x.d) || (FLUSH && is_sub(x.d))) continue;
      U z; z.u = x.u + (r2() % 8) - 4;
      if (std::isnan(z.d) || std::isinf(z.d) || (FLUSH && is_sub(z.d))) continue;
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
    if (FLUSH && (is_sub(x.d) || is_sub(z.d))) continue;
    check(x.d, z.d, rng() & 1, "random");
    // R1013: both near or below 2^-1022, one there and one anywhere up to
    // 2^-950, and a subnormal against random bits.
    check(tiny(rng, 3), tiny(rng, 3), rng() & 1, "tiny");
    check(tiny(rng, 70), tiny(rng, 2), rng() & 1, "tiny/near");
    check(tiny(rng, 0), x.d, rng() & 1, "subnormal/random");
  }
  std::printf("  random bit patterns                 : %llu (seed %llu)\n",
              (unsigned long long)n, (unsigned long long)seed);

  dut->final(); delete dut;
  std::printf("  checks with a subnormal operand %llu, result %llu\n",
              (unsigned long long)n_sub_in, (unsigned long long)n_sub_out);
  std::printf("  %llu checks, %llu mismatches\n",
              (unsigned long long)checks, (unsigned long long)fails);
  if (fails) { std::printf("FAIL\n"); return 1; }
  std::printf("PASS\n"); return 0;
}
