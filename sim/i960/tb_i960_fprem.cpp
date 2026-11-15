// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// R869: i960_fprem (remr) against the host's fmod -- what MAME computes,
// set_rif(opcode, fmod(t2f, t1f)) on doubles. fmod is exact, so the host is
// the oracle bit for bit. NaN results compare as "both NaN" (the units emit
// one quiet NaN).
//
// R1020: the unit takes subnormal operands and delivers subnormal remainders
// (SUBNORM 1, i960_top FP_SUBN 2), so the host's fmod is compared as it is.
// Built with -DTB_FLUSH the bench checks a SUBNORM 0 unit against the old
// flush model (§8.1: a subnormal operand is zero, a subnormal remainder a zero
// of x's sign), as it did before.
//
// The cycles from req to done are checked on EVERY vector against a model
// of the machine (cycles() below): a pair with no subnormal operand must take
// exactly what the old unit took, and the subnormal paths what R1020 says.
//
// Vectors, an order of magnitude and more past Sega Rally's (single operands,
// exponent differences up to ~30 in the game; see R869):
//   * doubles over the whole exponent range, exponent differences 0..2046
//   * singles widened (the r forms' own operands), every exponent pair
//   * exact multiples x = k * y and k * y +- one ulp, x = +-y, |x| just
//     under / over |y|, both signs of each
//   * zeros, infinities, NaNs, subnormals, the largest and smallest normals
//   * R1020: every leading-zero count of a subnormal x against every one of
//     a subnormal y; every subnormal y's leading-zero count against every x
//     exponent 0..2046 (x / y up to 2^2098); normal pairs whose remainder is
//     subnormal; exact multiples of a subnormal y; sparse significands
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
#ifdef TB_FLUSH
const bool FLUSH = true;
#else
const bool FLUSH = false;
#endif
uint64_t checks = 0, fails = 0, cyc_fails = 0, nan_cases = 0, flushed = 0, max_cyc = 0, cyc_total = 0;
uint64_t sub_in = 0, sub_out = 0, max_cyc_norm = 0, max_cyc_sub = 0;
uint64_t by_class[12] = {0};
bool band_x[53] = {false}, band_y[53] = {false};   // subnormal operands by leading-zero count
const int MAX_REPORT = 12;

double u2d(uint64_t u) { double d; std::memcpy(&d, &u, 8); return d; }
uint64_t d2u(double d) { uint64_t u; std::memcpy(&u, &d, 8); return u; }
void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }
bool is_sub(double v) { return std::fpclassify(v) == FP_SUBNORMAL; }

double flush(double v) {
  return (FLUSH && is_sub(v)) ? std::copysign(0.0, v) : v;
}
int lz52(uint64_t f) { int n = 0; for (int b = 51; b >= 0 && !((f >> b) & 1); --b) ++n; return n; }

// The machine's cycles, req's clock to done's, on the operands the unit sees
// (flushed with TB_FLUSH): 1 for a special or |x| < |y|; else
//   normal y:    1 + (ex' - ey + 1) + (r = 0 ? 1 : min(52 - p, ey - 1) + 1)
//                with r the remainder at y's scale and p its leading one
//   subnormal y: ex' + 2L + 2, L the shift that puts y's leading one at 52
// (ex' = max(ex, 1)). The first is the old unit's, unchanged by R1020.
uint64_t cycles(double X, double Y) {
  const uint64_t xb = d2u(X), yb = d2u(Y);
  const int ex = int((xb >> 52) & 0x7ff), ey = int((yb >> 52) & 0x7ff);
  const uint64_t fx = xb & 0xfffffffffffffull, fy = yb & 0xfffffffffffffull;
  if (std::isnan(X) || std::isnan(Y) || std::isinf(X) || Y == 0.0 || X == 0.0) return 1;
  const int ex1 = ex ? ex : 1, ey1 = ey ? ey : 1;
  if (ex1 < ey1) return 1;
  if (ey == 0) {
    const int L = lz52(fy) + 1;
    return uint64_t(ex1 + 2 * L + 2);
  }
  (void)fx;
  const double R = std::fmod(std::fabs(X), std::fabs(Y));
  const uint64_t r = uint64_t(std::ldexp(R, 1075 - ey));
  uint64_t norm = 1;
  if (r) {
    int p = 63; while (!((r >> p) & 1)) --p;
    norm = uint64_t(std::min(52 - p, ey - 1)) + 1;
  }
  return 1 + uint64_t(ex1 - ey1 + 1) + norm;
}

void check(double X, double Y, int cls) {
  dut->x = d2u(X); dut->y = d2u(Y); dut->req = 1;
  tick(); dut->req = 0;
  uint64_t c = 1;
  while (!dut->done && c < 5000) { tick(); ++c; }
  const double fx = flush(X), fy = flush(Y);
  const bool sop = is_sub(X) || is_sub(Y);
  if (fx != X || fy != Y) ++flushed;
  if (sop) {
    ++sub_in;
    if (is_sub(X)) band_x[lz52(d2u(X) & 0xfffffffffffffull)] = true;
    if (is_sub(Y)) band_y[lz52(d2u(Y) & 0xfffffffffffffull)] = true;
  }
  if (c > max_cyc) max_cyc = c;
  if (sop && c > max_cyc_sub) max_cyc_sub = c;
  if (!sop && c > max_cyc_norm) max_cyc_norm = c;
  cyc_total += c;
  double want = std::fmod(fx, fy);
  if (is_sub(want)) { ++sub_out; if (FLUSH) { want = std::copysign(0.0, want); ++flushed; } }
  const uint64_t got = dut->q;
  ++checks; ++by_class[cls];
  const bool both_nan = std::isnan(want) && std::isnan(u2d(got));
  if (std::isnan(want)) ++nan_cases;
  if (!dut->done || (!both_nan && got != d2u(want))) {
    if (fails < MAX_REPORT)
      std::printf("  MISMATCH [class %d] fmod(%.17g, %.17g) [%016llx, %016llx] got %016llx want %016llx (%.17g)%s\n",
                  cls, X, Y, (unsigned long long)d2u(X), (unsigned long long)d2u(Y),
                  (unsigned long long)got, (unsigned long long)d2u(want), want,
                  dut->done ? "" : " NO DONE");
    ++fails;
  } else {
    const uint64_t wc = cycles(fx, fy);
    if (c != wc) {
      if (cyc_fails < MAX_REPORT)
        std::printf("  CYCLES [class %d] fmod(%.17g, %.17g) [%016llx, %016llx] took %llu, model %llu\n",
                    cls, X, Y, (unsigned long long)d2u(X), (unsigned long long)d2u(Y),
                    (unsigned long long)c, (unsigned long long)wc);
      ++cyc_fails;
    }
  }
  tick();
}

// A subnormal with leading-zero count lz (0..51) and a random fraction below
// its leading one, or a sparse one (the leading one and at most one more bit).
double sub_lz(std::mt19937_64 &rng, int lz, bool neg) {
  const int top = 51 - lz;
  uint64_t f = 1ull << top;
  if (rng() % 4) f |= rng() & (f - 1);
  else if (top > 0 && (rng() & 1)) f |= 1ull << (rng() % top);
  return u2d(f | (neg ? 0x8000000000000000ull : 0));
}
double any_exp(std::mt19937_64 &rng, int e) {       // exponent field e, random fraction
  return u2d((rng() & 0x800fffffffffffffull) | (uint64_t(e) << 52));
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
                             1e-310, -1e-310, 4.9e-324, -4.9e-324, 2.2250738585072009e-308,
                             -2.2250738585072009e-308, 1.1125369292536007e-308,
                             2.2250738585072014e-308, -2.2250738585072014e-308,
                             1.7976931348623157e308, -1.7976931348623157e308, 1e300, 1e-300,
                             3.4028234663852886e38, 1.1754943508222875e-38, 1.401298464324817e-45,
                             6.283185307179586, 3.141592653589793, 360.0, -360.0, 65536.0 };
  for (double a : sp) for (double b : sp) check(a, b, 0);

  // 6: every subnormal x band against every subnormal y band, both signs
  for (int a = 0; a < 52; ++a) for (int b = 0; b < 52; ++b) for (int t = 0; t < 8; ++t)
    check(sub_lz(rng, a, t & 1), sub_lz(rng, b, t & 2), 6);
  // 7: every subnormal y band against every x exponent field 0..2046 -- the
  //    whole x / y range, up to 2^2046 / 2^-1074 = 2^2098 (x field 0 is a
  //    subnormal x, drawn from a random band)
  for (int b = 0; b < 52; ++b) for (int e = 0; e < 2047; ++e) {
    const double Y = sub_lz(rng, b, rng() & 1);
    const double X = e ? any_exp(rng, e) : sub_lz(rng, int(rng() % 52), rng() & 1);
    check(X, Y, 7);
  }
  // 8: every subnormal x band against normal y of every small exponent and a
  //    sample of the rest (x itself when |x| < |y|; ey = 1 runs the loop)
  for (int a = 0; a < 52; ++a) for (int e = 1; e < 2047; e += (e < 64 ? 1 : 37))
    for (int t = 0; t < 4; ++t) check(sub_lz(rng, a, t & 1), any_exp(rng, e), 8);
  // 9: normal pairs whose remainder is subnormal: x = k y + s, y near the
  //    bottom of the normals, s a subnormal multiple of y's ulp
  for (int e = 1; e < 64; ++e) for (int t = 0; t < 400; ++t) {
    const double Y = any_exp(rng, e);
    const double kk = std::ldexp(double(rng() % 100000 + 1), int(rng() % 40));
    double X = std::fabs(Y) * kk;                     // rounded: the remainder is what it is
    if (rng() & 1) X = std::nextafter(X, inf);
    if (rng() & 1) X = -X;
    check(X, Y, 9);
  }
  // 10: the ends of the long loop with a subnormal y: the largest x against
  //     the smallest y, x / y one band apart, exact multiples of a subnormal y
  {
    const double big[] = { 1.7976931348623157e308, -1.7976931348623157e308, 1e308, 8.98846567431158e307 };
    for (double X : big) for (int b = 0; b < 52; ++b) for (int t = 0; t < 4; ++t)
      check(X, sub_lz(rng, b, t & 1), 10);
    for (int b = 0; b < 52; ++b) for (int t = 0; t < 200; ++t) {
      const double Y = sub_lz(rng, b, rng() & 1);
      double X = Y * double(rng() % 1000000 + 1);       // exact while it fits 53 bits
      if (rng() & 1) X = std::nextafter(X, (rng() & 1) ? inf : -inf);
      check(X, Y, 10);
    }
  }

  for (uint64_t k = 0; k < n; ++k) {
    const int cls = 1 + int(rng() % 5);
    double X = 0, Y = 0;
    if (cls == 1) {                       // any doubles, the whole exponent range
      X = u2d(rng()); Y = u2d(rng());
      // R1020: an operand in eight a subnormal (exponent field 0)
      if ((rng() % 8) == 0) X = u2d(d2u(X) & 0x800fffffffffffffull);
      if ((rng() % 8) == 0) Y = u2d(d2u(Y) & 0x800fffffffffffffull);
    } else if (cls == 2) {                // widened singles (the r forms' operands)
      uint32_t a = uint32_t(rng()), b = uint32_t(rng());
      float fa, fb; std::memcpy(&fa, &a, 4); std::memcpy(&fb, &b, 4);
      X = fa; Y = fb;
    } else if (cls == 3) {                // exact multiples and their neighbours
      Y = u2d((rng() & 0x800fffffffffffffull) | (uint64_t(1 + rng() % 2046) << 52));
      if ((rng() % 8) == 0) Y = sub_lz(rng, int(rng() % 52), rng() & 1);   // R1020
      const double kk = std::ldexp(double(rng() % 100000 + 1), int(rng() % 64) - 16);
      X = Y * kk;
      if (rng() & 1) X = std::nextafter(X, (rng() & 1) ? inf : -inf);
      if (rng() & 1) X = -X;
      if (rng() & 1) Y = -Y;
    } else if (cls == 4) {                // |x| near |y|, the largest ratios
      Y = u2d((rng() & 0x800fffffffffffffull) | (uint64_t(1 + rng() % 2046) << 52));
      if ((rng() % 8) == 0) Y = sub_lz(rng, int(rng() % 52), rng() & 1);   // R1020
      switch (rng() % 5) {
        case 0: X = Y; break;
        case 1: X = std::nextafter(Y, inf); break;
        case 2: X = std::nextafter(Y, 0.0); break;
        case 3: X = 1.7976931348623157e308; Y = u2d((rng() & 0x000fffffffffffffull) | (uint64_t(rng() % 5) << 52)); break;
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
  int bx = 0, by = 0;
  for (int i = 0; i < 52; ++i) { bx += band_x[i]; by += band_y[i]; }
  std::printf("== i960_fprem (remr, R869; R1020 %s): %llu vectors (specials %llu, doubles %llu, singles %llu, multiples %llu, near / huge %llu, game-like %llu,\n"
              "   sub x sub %llu, sub y x every x exponent %llu, sub x / normal y %llu, subnormal remainders %llu, sub y ends / multiples %llu)\n",
              FLUSH ? "SUBNORM 0, the flush" : "SUBNORM 1",
              (unsigned long long)checks, (unsigned long long)by_class[0], (unsigned long long)by_class[1],
              (unsigned long long)by_class[2], (unsigned long long)by_class[3], (unsigned long long)by_class[4],
              (unsigned long long)by_class[5], (unsigned long long)by_class[6], (unsigned long long)by_class[7],
              (unsigned long long)by_class[8], (unsigned long long)by_class[9], (unsigned long long)by_class[10]);
  std::printf("   NaN results %llu, subnormal operands %llu (x bands %d / 52, y bands %d / 52), subnormal remainders %llu, flushed operands / results %llu\n",
              (unsigned long long)nan_cases, (unsigned long long)sub_in, bx, by,
              (unsigned long long)sub_out, (unsigned long long)flushed);
  std::printf("   cycles max %llu (no subnormal operand %llu, a subnormal operand %llu) mean %.1f; %llu off the model\n",
              (unsigned long long)max_cyc, (unsigned long long)max_cyc_norm, (unsigned long long)max_cyc_sub,
              double(cyc_total) / double(checks), (unsigned long long)cyc_fails);
  const bool bad = fails || cyc_fails;
  std::printf("   %s: %llu mismatches, %llu cycle mismatches\n", bad ? "FAIL" : "PASS",
              (unsigned long long)fails, (unsigned long long)cyc_fails);
  delete dut;
  return bad ? 1 : 0;
}
