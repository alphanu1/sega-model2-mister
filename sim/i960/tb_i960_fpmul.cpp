// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Harness for i960_fpmul against the host's own double multiply, which is what
// the reference uses — MAME computes in host `double`, so the host IS the
// oracle here rather than a transcription of one.
//
// R1013: subnormal operands and results are compared too (SUBNORM 1); built
// with -DTB_FLUSH the bench checks a SUBNORM 0 unit and excludes them, as it
// did before, when the text below held:
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
#ifdef TB_FLUSH
const bool FLUSH = true;
#else
const bool FLUSH = false;
#endif
uint64_t n_sub_in = 0, n_sub_out = 0;
inline double mk(uint64_t sgn, uint64_t e, uint64_t m) {
  U x; x.u = (sgn << 63) | (e << 52) | (m & 0xfffffffffffffull); return x.d;
}

void check(double A, double B, const char *why) {
  U ua{A}, ub{B};
  dut->a = ua.u; dut->b = ub.u; dut->req = 1;
  tick(); dut->req = 0;
  for (int i = 0; i < 8 && !dut->done; i++) tick();

  const double want = A * B;
  if (FLUSH && (is_sub(want) || is_sub(A) || is_sub(B))) { tick(); return; }
  if (is_sub(A) || is_sub(B)) ++n_sub_in;
  if (is_sub(want)) ++n_sub_out;

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
                       INFINITY, -INFINITY, NAN,
                       4.9406564584124654e-324, -4.9406564584124654e-324,
                       2.2250738585072009e-308, 2.2250738585072014e-308,
                       1.5e-308, -3e-320, 4.4501477170144028e-308,
                       1.4916681462400413e-154, 8.98846567431158e307};
  uint64_t c = 0;
  for (double A : sp) for (double B : sp) { check(A, B, "special"); ++c; }
  std::printf("  specials (zero, inf, nan, extremes) : %llu\n", (unsigned long long)c);

  std::mt19937_64 rng(seed);
  for (uint64_t k = 0; k < n && fails == 0; ++k) {
    U x, z; x.u = rng(); z.u = rng();
    if (std::isnan(x.d) || std::isnan(z.d)) continue;
    if (FLUSH && (is_sub(x.d) || is_sub(z.d))) continue;
    check(x.d, z.d, "random");
    // R1013: products whose exponent lands from 2^-1090 to 2^-1010 (across
    // and below the subnormal range), from normal operands of any size.
    {
      const uint64_t ea = 1 + rng() % 2046;
      int64_t eb = 1023 - int64_t(ea) - 68 + int64_t(rng() % 80);
      if (eb < 1) eb = 1;
      if (eb > 2046) eb = 2046;
      check(mk(rng() & 1, ea, rng()), mk(rng() & 1, uint64_t(eb), rng()), "near-underflow");
    }
    // A subnormal times anything finite, times a value that brings it back
    // to the normal range, and times another subnormal.
    {
      const double sx = mk(rng() & 1, 0, rng() >> (rng() % 64));
      check(sx, mk(rng() & 1, 1 + rng() % 2046, rng()), "subnormal*normal");
      check(mk(rng() & 1, 1023 + rng() % 60, rng()), sx, "normal*subnormal");
      check(sx, mk(rng() & 1, 0, rng()), "subnormal*subnormal");
    }
  }
  // Ties in the subnormal range: m * 2^-1074 times 1/2, 3/4, 1.5 / 2^k --
  // an odd m halves to an exact tie, which rounds to even.
  {
    std::mt19937_64 r3(seed ^ 0x7135);
    const double fr[] = {0.5, 0.75, 0.25, 0.375, 1.5 / 1024, 0.5 / 3.0};
    uint64_t nt = 0;
    for (int k = 0; k < 20000; ++k) {
      const double sx = mk(r3() & 1, 0, r3() >> (r3() % 64));
      const double f = fr[k % 6];
      check(sx, f, "tie"); check(f, -sx, "tie"); nt += 2;
      // just above / at the top of the subnormal range
      check(mk(r3() & 1, 1 + r3() % 3, r3()), f, "edge"); ++nt;
    }
    // Sparse significands (a few set bits, often at both ends), so the
    // product has bits far apart: a guard bit with nothing under it in the
    // kept window but something shifted out below -- the sticky the
    // denormalising shift must keep.
    for (int k = 0; k < 400000; ++k) {
      auto sparse = [&]() {
        uint64_t m = 0;
        const int nb = 1 + int(r3() % 3);
        for (int b = 0; b < nb; ++b) m |= 1ull << ((r3() & 1) ? (r3() % 4) : (48 + r3() % 4));
        return m;
      };
      const uint64_t ea = 1 + r3() % 2046;
      int64_t eb = 1023 - int64_t(ea) - 60 + int64_t(r3() % 64);
      if (eb < 0) eb = 0;
      if (eb > 2046) eb = 2046;
      check(mk(r3() & 1, ea, sparse()), mk(r3() & 1, uint64_t(eb), sparse()), "sparse"); ++nt;
    }
    std::printf("  subnormal ties, edges, sparse        : %llu\n", (unsigned long long)nt);
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
