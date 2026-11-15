// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Harness for i960_fpdiv against the host's own double divide, which
// is what the reference uses — MAME computes in host `double`, so the host IS
// the oracle here rather than a transcription of one.
//
// R1013: subnormal operands and results are compared too (SUBNORM 1); built
// with -DTB_FLUSH the bench checks a SUBNORM 0 unit and excludes them, as it
// did before, when the text below held. The cycles from req to done are
// checked as well: a normal operand pair with a normal result must take the
// same count as before (58), whatever the subnormal paths add or save.
// Subnormal operands and results are excluded. This unit flushes them and the
// host does not, so comparing there would test a documented deviation rather
// than the multiplier. Same discipline as the zero divisor and the overlapping
// mov: constrain the input, do not compare against a known difference.

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <random>
#include "Vi960_fpdiv.h"
#include "verilated.h"

namespace {
Vi960_fpdiv *dut = nullptr;
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
uint64_t n_sub_in = 0, n_sub_out = 0, cyc_bad = 0;
int cyc_norm = -1, cyc_min = 1 << 30, cyc_max = 0;
inline double mk(uint64_t sgn, uint64_t e, uint64_t m) {
  U x; x.u = (sgn << 63) | (e << 52) | (m & 0xfffffffffffffull); return x.d;
}

void check(double A, double B, bool unused_, const char *why) {
  (void)unused_;
  U ua{A}, ub{B};
  dut->a = ua.u; dut->b = ub.u; dut->req = 1;
  tick(); dut->req = 0;
  int cyc = 1;
  for (int i = 0; i < 200 && !dut->done; i++) { tick(); ++cyc; }   // 56 restoring steps

  const double want = A / B;
  if (FLUSH && (is_sub(want) || is_sub(A) || is_sub(B))) { tick(); return; }
  const bool sin_ = is_sub(A) || is_sub(B);
  if (sin_) ++n_sub_in;
  if (is_sub(want)) ++n_sub_out;
  // The subnormal paths: a subnormal operand, or a quotient under 2^-1022
  // before rounding (a subnormal, or 0 / 2^-1022 from non-zero finite
  // operands). Everything else -- specials included -- must take the 58.
  const bool sres = is_sub(want) || (want == 0.0 && A != 0.0 && std::isfinite(A) && !std::isinf(B))
                 || std::fabs(want) == 2.2250738585072014e-308;
  if (sin_ || sres) { if (cyc < cyc_min) cyc_min = cyc; if (cyc > cyc_max) cyc_max = cyc; }
  else {
    if (cyc_norm < 0) cyc_norm = cyc;
    else if (cyc != cyc_norm) {
      if (cyc_bad < 4) std::printf("  CYCLES %d (not %d) for %.17g / %.17g\n", cyc, cyc_norm, A, B);
      ++cyc_bad;
    }
  }

  U got; got.u = dut->y;
  ++checks;
  const bool both_nan = std::isnan(want) && std::isnan(got.d);
  if (!both_nan && got.u != U{want}.u) {
    if (fails < MAX_REPORT)
      std::printf("  MISMATCH [%s] %.17g %s %.17g  got=%.17g (%016llx) want=%.17g (%016llx)\n",
                  why, A, "/", B, got.d, (unsigned long long)got.u,
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
  dut = new Vi960_fpdiv;
  dut->rst_n = 0; dut->req = 0;
  for (int i = 0; i < 4; i++) tick();
  dut->rst_n = 1; tick();
  std::printf("i960_fpdiv vs the host double divide\n");

  const double sp[] = {0.0, -0.0, 1.0, -1.0, 2.0, 0.5, 3.0, -7.25,
                       1e308, -1e308, 1e-300, 123456789.0,
                       INFINITY, -INFINITY, NAN,
                       4.9406564584124654e-324, -4.9406564584124654e-324,
                       2.2250738585072009e-308, 2.2250738585072014e-308,
                       1.5e-308, -3e-320, 4.4501477170144028e-308,
                       1.4916681462400413e-154, 8.98846567431158e307};
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
    for (int k = 0; k < 6000; ++k) {
      U x; x.u = r2();
      if (k & 1) x.u = (x.u & 0x800fffffffffffffull) | (uint64_t(r2() % 3) << 52);   // R1013
      if (std::isnan(x.d) || std::isinf(x.d) || (FLUSH && is_sub(x.d))) continue;
      U z; z.u = x.u + (r2() % 8) - 4;
      if (std::isnan(z.d) || std::isinf(z.d) || (FLUSH && is_sub(z.d))) continue;
      check(x.d, z.d, 0, "near-equal"); ++nc;
      check(x.d, -z.d, 0, "near-equal"); ++nc;
    }
    std::printf("  near-equal operand pairs            : %llu\n",
                (unsigned long long)nc);
  }

  std::mt19937_64 rng(seed);
  for (uint64_t k = 0; k < n; ++k) {
    U x, z; x.u = rng(); z.u = rng();
    if (std::isnan(x.d) || std::isnan(z.d)) continue;
    if (FLUSH && (is_sub(x.d) || is_sub(z.d))) continue;
    check(x.d, z.d, rng() & 1, "random");
    if (k % 4) continue;                 // the divider is slow: a quarter as many each
    // R1013: quotients whose exponent lands from 2^-1090 to 2^-1010.
    {
      const uint64_t ea = 1 + rng() % 2046;
      int64_t eb = int64_t(ea) - 1023 + 1022 - 10 + int64_t(rng() % 80);
      if (eb < 1) eb = 1;
      if (eb > 2046) eb = 2046;
      check(mk(rng() & 1, ea, rng()), mk(rng() & 1, uint64_t(eb), rng()), 0, "near-underflow");
    }
    {
      const double sx = mk(rng() & 1, 0, rng() >> (rng() % 64));
      check(sx, mk(rng() & 1, 1 + rng() % 2046, rng()), 0, "subnormal/normal");
      check(mk(rng() & 1, 1 + rng() % 2046, rng()), sx, 0, "normal/subnormal");
      check(sx, mk(rng() & 1, 0, rng() >> (rng() % 64)), 0, "subnormal/subnormal");
      check(sx, mk(rng() & 1, 1023 - 4 + rng() % 8, rng()), 0, "subnormal/~1");
    }
  }
  // Ties in the subnormal range: m * 2^-1074 / 2, / (4/3), * 2^-k.
  {
    std::mt19937_64 r3(seed ^ 0x7135);
    const double fr[] = {2.0, 4.0 / 3.0, 4.0, 8.0 / 3.0, 1024.0 / 1.5, 3.0};
    uint64_t nt = 0;
    for (int k = 0; k < 6000; ++k) {
      const double sx = mk(r3() & 1, 0, r3() >> (r3() % 64));
      const double f = fr[k % 6];
      check(sx, f, 0, "tie"); ++nt;
      check(mk(r3() & 1, 1 + r3() % 3, r3()), f, 0, "edge"); ++nt;
    }
    std::printf("  subnormal ties and edges            : %llu\n", (unsigned long long)nt);
  }
  std::printf("  random bit patterns                 : %llu (seed %llu)\n",
              (unsigned long long)n, (unsigned long long)seed);

  dut->final(); delete dut;
  std::printf("  checks with a subnormal operand %llu, result %llu\n",
              (unsigned long long)n_sub_in, (unsigned long long)n_sub_out);
  std::printf("  cycles req -> done: normal %d (every one; %llu not), subnormal %d .. %d\n",
              cyc_norm, (unsigned long long)cyc_bad, cyc_min, cyc_max);
  if (cyc_bad) ++fails;
  std::printf("  %llu checks, %llu mismatches\n",
              (unsigned long long)checks, (unsigned long long)fails);
  if (fails) { std::printf("FAIL\n"); return 1; }
  std::printf("PASS\n"); return 0;
}
