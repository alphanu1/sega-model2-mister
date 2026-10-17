// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// R869: i960_fprem (remr) against the host's fmod -- what MAME computes,
// set_rif(opcode, fmod(t2f, t1f)) on doubles. fmod is exact, so the host is
// the oracle bit for bit; the only modelled difference is the units' flush
// (§8.1): a subnormal operand is zero, a subnormal remainder a zero of x's
// sign. NaN results compare as "both NaN" (the units emit one quiet NaN).
//
// Vectors, an order of magnitude and more past Sega Rally's (single operands,
// exponent differences up to ~30 in the game; see R869):
//   * doubles over the whole exponent range, exponent differences 0..2046
//   * singles widened (the r forms' own operands), every exponent pair
//   * exact multiples x = k * y and k * y +- one ulp, x = +-y, |x| just
//     under / over |y|, both signs of each
//   * zeros, infinities, NaNs, subnormals, the largest and smallest normals
//   +random=N (default 1,000,000), +seed=S

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <random>
#include <vector>
#include "Vi960_fprem.h"
#include "verilated.h"

namespace {
Vi960_fprem *dut = nullptr;
uint64_t checks = 0, fails = 0, nan_cases = 0, flushed = 0, max_cyc = 0, cyc_total = 0;
uint64_t by_class[6] = {0};
const int MAX_REPORT = 12;

double u2d(uint64_t u) { double d; std::memcpy(&d, &u, 8); return d; }
uint64_t d2u(double d) { uint64_t u; std::memcpy(&u, &d, 8); return u; }
void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }

double flush(double v) {
  return (std::fpclassify(v) == FP_SUBNORMAL) ? std::copysign(0.0, v) : v;
}

void check(double X, double Y, int cls) {
  dut->x = d2u(X); dut->y = d2u(Y); dut->req = 1;
  tick(); dut->req = 0;
  uint64_t c = 1;
  while (!dut->done && c < 5000) { tick(); ++c; }
  if (c > max_cyc) max_cyc = c;
  cyc_total += c;
  const double fx = flush(X), fy = flush(Y);
  if (fx != X || fy != Y) ++flushed;
  double want = std::fmod(fx, fy);
  if (std::fpclassify(want) == FP_SUBNORMAL) { want = std::copysign(0.0, want); ++flushed; }
  const uint64_t got = dut->q;
  ++checks; ++by_class[cls];
  const bool both_nan = std::isnan(want) && std::isnan(u2d(got));
  if (std::isnan(want)) ++nan_cases;
  if (!dut->done || (!both_nan && got != d2u(want))) {
    if (fails < MAX_REPORT)
      std::printf("  MISMATCH [class %d] fmod(%.17g, %.17g) got %016llx want %016llx (%.17g)%s\n",
                  cls, X, Y, (unsigned long long)got, (unsigned long long)d2u(want), want,
                  dut->done ? "" : " NO DONE");
    ++fails;
  }
  tick();
}
} // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  uint64_t n = 1000000, seed = 1;
  for (int i = 1; i < argc; ++i) {
    if (!std::strncmp(argv[i], "+random=", 8)) n = std::strtoull(argv[i] + 8, nullptr, 10);
    if (!std::strncmp(argv[i], "+seed=", 6))   seed = std::strtoull(argv[i] + 6, nullptr, 10);
  }
  dut = new Vi960_fprem;
  dut->rst_n = 0; dut->req = 0; tick(); tick(); dut->rst_n = 1; tick();
  std::mt19937_64 rng(seed);

  // 0: specials against everything
  const double inf = INFINITY, nan = NAN;
  std::vector<double> sp = { 0.0, -0.0, inf, -inf, nan, -nan, 1.0, -1.0, 3.0, -3.0, 0.5, 7.25,
                             1e-310, -1e-310, 4.9e-324, 2.2250738585072014e-308, -2.2250738585072014e-308,
                             1.7976931348623157e308, -1.7976931348623157e308, 1e300, 1e-300,
                             3.4028234663852886e38, 1.1754943508222875e-38, 1.401298464324817e-45,
                             6.283185307179586, 3.141592653589793, 360.0, -360.0, 65536.0 };
  for (double a : sp) for (double b : sp) check(a, b, 0);

  for (uint64_t k = 0; k < n; ++k) {
    const int cls = 1 + int(rng() % 5);
    double X = 0, Y = 0;
    if (cls == 1) {                       // any doubles, the whole exponent range
      X = u2d(rng()); Y = u2d(rng());
    } else if (cls == 2) {                // widened singles (the r forms' operands)
      uint32_t a = uint32_t(rng()), b = uint32_t(rng());
      float fa, fb; std::memcpy(&fa, &a, 4); std::memcpy(&fb, &b, 4);
      X = fa; Y = fb;
    } else if (cls == 3) {                // exact multiples and their neighbours
      Y = u2d((rng() & 0x800fffffffffffffull) | (uint64_t(1 + rng() % 2046) << 52));
      const double kk = std::ldexp(double(rng() % 100000 + 1), int(rng() % 64) - 16);
      X = Y * kk;
      if (rng() & 1) X = std::nextafter(X, (rng() & 1) ? inf : -inf);
      if (rng() & 1) X = -X;
      if (rng() & 1) Y = -Y;
    } else if (cls == 4) {                // |x| near |y|, the largest ratios
      Y = u2d((rng() & 0x800fffffffffffffull) | (uint64_t(1 + rng() % 2046) << 52));
      switch (rng() % 5) {
        case 0: X = Y; break;
        case 1: X = std::nextafter(Y, inf); break;
        case 2: X = std::nextafter(Y, 0.0); break;
        case 3: X = 1.7976931348623157e308; Y = u2d((rng() & 0x000fffffffffffffull) | (uint64_t(1 + rng() % 4) << 52)); break;
        default: X = -Y * 2.0; break;
      }
      if (rng() & 1) X = -X;
    } else {                              // games' kind: angles and modest ratios
      X = (double(int64_t(rng() % 2000001) - 1000000)) * std::ldexp(1.0, -int(rng() % 24));
      Y = double(1 + rng() % 4096) * std::ldexp(1.0, -int(rng() % 12));
      if (rng() & 1) Y = -Y;
      X = double(float(X)); Y = double(float(Y));
    }
    check(X, Y, cls);
  }
  std::printf("== i960_fprem (remr, R869): %llu vectors (specials %llu, doubles %llu, singles %llu, multiples %llu, near / huge %llu, game-like %llu)\n",
              (unsigned long long)checks, (unsigned long long)by_class[0], (unsigned long long)by_class[1],
              (unsigned long long)by_class[2], (unsigned long long)by_class[3], (unsigned long long)by_class[4],
              (unsigned long long)by_class[5]);
  std::printf("   NaN results %llu, flushed operands / results %llu, cycles max %llu mean %.1f\n",
              (unsigned long long)nan_cases, (unsigned long long)flushed, (unsigned long long)max_cyc,
              double(cyc_total) / double(checks));
  std::printf("   %s: %llu mismatches\n", fails ? "FAIL" : "PASS", (unsigned long long)fails);
  delete dut;
  return fails ? 1 : 0;
}
