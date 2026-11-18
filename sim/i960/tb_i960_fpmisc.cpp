// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Harness for i960_fpmisc against the host's own operations. Every operation
// here is exactly specified, so these comparisons are bit-exact by right
// rather than by tolerance.
//
// R972: the reference is Intel's 80960KB manual, not MAME. Rounding mode 0 is
// round to nearest, ties to EVEN (PRM 3-11 Table 3-4, 12-12) -- the host's
// nearbyint() in its default FE_TONEAREST mode -- and an out-of-range
// cvtri / cvtzri saturates by sign (11-50). +ref=mame selects MAME's rule
// instead (C round(), half away from zero; 0x8000_0000 for any overflow) so a
// run can show the sweeps below DO see the difference: the fixed module must
// FAIL under it.
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <random>
#include "Vi960_fpmisc.h"
#include "verilated.h"

namespace {
Vi960_fpmisc *dut = nullptr;
uint64_t checks = 0, fails = 0;
const int MAX_REPORT = 14;
bool ref_mame = false;           // +ref=mame: MAME's rule, expected to FAIL now
bool ref_mame64 = false;         // R1045 +ref=mame64: MAME's 64-bit overflow alone, the same
union U { double d; uint64_t u; };
// Reinterpret raw bits as a double. `U{x}.d` initialises the FIRST member, so
// for an integer x it CONVERTS rather than reinterprets and every NaN check
// built on it silently fails.
inline double asd(uint64_t b) { U t; t.u = b; return t.d; }
bool is_sub(double x) { return x != 0.0 && std::fabs(x) < 2.2250738585072014e-308; }
// R1013: SUBNORM 1 takes a subnormal operand as a value in logb, round, cvtri
// and cvtzri (compare always did); -DTB_FLUSH checks a SUBNORM 0 unit and
// skips them, as before. Scale (op 6, not used by i960_top) still flushes, so
// its subnormals stay excluded either way.
#ifdef TB_FLUSH
const bool FLUSH = true;
#else
const bool FLUSH = false;
#endif
uint64_t n_sub = 0;
// R1045: -DTB_LONG checks a LONG 1 unit's 64-bit integer (cvtzril's; lng
// high) against the PRM at 64 bits, beside every 32-bit check.
#ifdef TB_LONG
const bool LONGI = true;
#else
const bool LONGI = false;
#endif
uint64_t n_long = 0;

enum { OP_CMP=0, OP_LOGB=1, OP_CVTIR=2, OP_CVTRI=3, OP_CVTZRI=4, OP_ROUND=5, OP_SCALE=6 };

void fail(const char *w, const char *f, uint64_t g, uint64_t want) {
  if (fails < MAX_REPORT)
    std::printf("  MISMATCH [%s] %-8s got=%016llx want=%016llx\n", w, f,
                (unsigned long long)g, (unsigned long long)want);
  ++fails;
}

void set(int op, double A, double B, int32_t I, int rm) {
  U ua{A}, ub{B};
  dut->op = op; dut->a = ua.u; dut->b = ub.u;
  dut->ai = (uint32_t)I; dut->rmode = rm; dut->lng = 0; dut->eval();
  // R575: one clock edge, so the STAGED build's register takes the operands.
  // The combinational build ignores clk and reads the same thing.
  dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval();
}

// round_to_int, exactly as the reference selects it from AC[31:30].
double rti(double v, int rm) {
  switch (rm) { case 0: return ref_mame ? std::round(v) : std::nearbyint(v);
                case 1: return std::floor(v);
                case 2: return std::ceil(v);  default: return std::trunc(v); }
}

void chk_cmp(double A, double B) {
  set(OP_CMP, A, B, 0, 0);
  uint32_t want = 0;
  if (!(std::isnan(A) || std::isnan(B))) want = (A < B) ? 4 : (A == B) ? 2 : 1;
  ++checks; if (dut->cc != want) fail("cmp", "cc", dut->cc, want);
}
void chk_logb(double A) {
  if (FLUSH && is_sub(A)) return;
  if (is_sub(A)) ++n_sub;
  set(OP_LOGB, A, 0, 0, 0);
  const double want = std::logb(A);
  ++checks; if (dut->y != U{want}.u && !(std::isnan(want) && std::isnan(asd(dut->y))))
    fail("logb", "y", dut->y, U{want}.u);
}
void chk_cvtir(int32_t I) {
  set(OP_CVTIR, 0, 0, I, 0);
  const double want = (double)I;
  ++checks; if (dut->y != U{want}.u) fail("cvtir", "y", dut->y, U{want}.u);
}
void chk_cvtri(double A, int rm, bool trunc_mode) {
  if (FLUSH && is_sub(A)) return;
  if (is_sub(A)) ++n_sub;
  if (std::isnan(A) || std::isinf(A)) {
    // NaN stores 0x8000_0000 (12-23); an infinity is the largest overflow
    // there is and saturates by sign (11-50).
    set(trunc_mode ? OP_CVTZRI : OP_CVTRI, A, 0, 0, rm);
    const uint32_t want = (std::isnan(A) || A < 0 || ref_mame) ? 0x80000000u : 0x7fffffffu;
    ++checks; if (dut->yi != want) fail(trunc_mode ? "cvtzri" : "cvtri", "yi(nan/inf)", dut->yi, want);
    return;
  }
  const double r = rti(A, trunc_mode ? 3 : rm);
  // Out of int32 range is CHECKED, not skipped. Skipping it is why the module
  // tested `eu > 31` for overflow -- which misses the entire exponent-31 band,
  // where every magnitude from 2^31 up to 2^32 is out of range except -2^31 --
  // and this test passed anyway. The C++ cast is undefined for those inputs, so
  // the expected value is written out rather than computed.
  const bool oor = (r < -2147483648.0 || r > 2147483647.0);
  set(trunc_mode ? OP_CVTZRI : OP_CVTRI, A, 0, 0, rm);
  const uint32_t want = !oor ? (uint32_t)(int32_t)r
                      : (ref_mame || r < 0) ? 0x80000000u : 0x7fffffffu;
  ++checks; if (dut->yi != want) {
    std::printf("    [cvtri in] A=%.10g rm=%d trunc=%d oor=%d\n", A, rm, trunc_mode, oor);
    fail(trunc_mode ? "cvtzri" : "cvtri", "yi", dut->yi, want);
  }
}
// R1045: the 64-bit integer (cvtzril; cvtri's mode-rounded form too, which
// is cvtril's arithmetic though i960_top does not decode cvtril). PRM 12-23:
// a NaN stores the maximum negative integer; 11-50: an unrepresentable value
// (an infinity included) the maximum positive or negative by sign. MAME's
// (int64_t) is x86's indefinite, 0x8000_0000_0000_0000, for all of them.
uint64_t want64(double A, int rm) {
  if (std::isnan(A)) return 0x8000000000000000ull;
  const double r = rti(A, rm);
  if (r >= 9223372036854775808.0) return (ref_mame || ref_mame64) ? 0x8000000000000000ull : 0x7fffffffffffffffull;
  if (r < -9223372036854775808.0) return 0x8000000000000000ull;
  return uint64_t(int64_t(r));
}
void chk_cvtl(double A, int rm, bool trunc_mode) {
  if (!LONGI || (FLUSH && is_sub(A))) return;
  U ua{A};
  dut->op = trunc_mode ? OP_CVTZRI : OP_CVTRI; dut->a = ua.u; dut->b = 0;
  dut->ai = 0; dut->rmode = rm; dut->lng = 1; dut->eval();
  dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval();
  const uint64_t got = (uint64_t(dut->yh) << 32) | dut->yi;
  const uint64_t want = want64(A, trunc_mode ? 3 : rm);
  ++checks; ++n_long;
  if (got != want) {
    if (fails < MAX_REPORT) std::printf("    [cvtl in] A=%.17g (%016llx) rm=%d trunc=%d\n", A,
                                        (unsigned long long)ua.u, rm, trunc_mode);
    fail(trunc_mode ? "cvtzril" : "cvtril", "yh:yi", got, want);
  }
  dut->lng = 0;
}
void chk_cvt_all(double A) {     // every conversion form, every mode
  for (int rm = 0; rm < 4; ++rm) {
    chk_cvtri(A, rm, false); chk_cvtri(A, rm, true);
    chk_cvtl(A, rm, false);  chk_cvtl(A, rm, true);
  }
}
void chk_round(double A, int rm) {
  if (FLUSH && is_sub(A)) return;
  if (is_sub(A)) ++n_sub;
  set(OP_ROUND, A, 0, 0, rm);
  const double want = (std::isnan(A) || std::isinf(A)) ? A : rti(A, rm);
  ++checks; if (dut->y != U{want}.u && !(std::isnan(want) && std::isnan(asd(dut->y))))
    fail("round", "y", dut->y, U{want}.u);
}
void chk_scale(double A, int32_t n) {
  if (is_sub(A)) return;
  const double want = A * std::pow(2.0, (double)n);
  if (is_sub(want)) return;
  set(OP_SCALE, A, 0, n, 0);
  ++checks; if (dut->y != U{want}.u && !(std::isnan(want) && std::isnan(asd(dut->y))))
    fail("scale", "y", dut->y, U{want}.u);
}
} // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  uint64_t n = 200000, seed = 1;
  int64_t tie_span = 1LL << 24;   // every n + 0.5 for |n| < tie_span
  for (int i = 1; i < argc; ++i) {
    if (!std::strncmp(argv[i], "+random=", 8)) n = std::strtoull(argv[i]+8, nullptr, 10);
    if (!std::strncmp(argv[i], "+seed=", 6))   seed = std::strtoull(argv[i]+6, nullptr, 10);
    if (!std::strcmp(argv[i], "+ref=mame"))    ref_mame = true;
    if (!std::strcmp(argv[i], "+ref=mame64"))  ref_mame64 = true;
    if (!std::strncmp(argv[i], "+ties=", 6))   tie_span = std::strtoll(argv[i]+6, nullptr, 10);
  }
  dut = new Vi960_fpmisc;
  std::printf("i960_fpmisc vs the host (all operations exactly specified), reference %s\n",
              ref_mame ? "MAME (half away from zero) -- expected to FAIL" : "80960KB PRM (ties to even)");

  const double sp[] = {0.0,-0.0,1.0,-1.0,0.5,-0.5,1.5,-1.5,2.5,-2.5,
                       3.0,-3.0,1e300,1e-300,4503599627370496.0,
                       INFINITY,-INFINITY,NAN};
  for (double A : sp) {
    chk_logb(A);
    for (double B : sp) chk_cmp(A, B);
    for (int rm = 0; rm < 4; ++rm) { chk_round(A, rm); chk_cvtri(A, rm, false); chk_cvtri(A, rm, true); }
    for (int32_t nn : {-40, -1, 0, 1, 40}) chk_scale(A, nn);
  }
  std::printf("  specials across every op and rounding mode\n");

  // Halfway cases: mode 0 is round to nearest, ties to EVEN (R972).
  for (double h : {0.5,1.5,2.5,3.5,-0.5,-1.5,-2.5,-3.5,4.5,-4.5})
    for (int rm = 0; rm < 4; ++rm) { chk_round(h, rm); chk_cvtri(h, rm, false); }
  std::printf("  halfway cases in all four rounding modes\n");

  // R972: EVERY tie n + 0.5 for |n| < tie_span (default 2^24: past single
  // precision's 2^23, where a single stops holding a .5, and VF2's 32767.5 by
  // three orders of magnitude), both signs, cvtri and roundr in mode 0, with
  // the neighbours one double ulp either side (near-ties, which round to
  // nearest whatever the tie rule). Then ties sampled by doubling out to
  // 2^52, where a double stops holding a .5 -- far past int32 -- in every
  // mode, so overflow-by-rounding (2147483647.5 -> 2^31, positive overflow)
  // is in the sweep too.
  const uint64_t c0 = checks, f0 = fails;
  for (int64_t k = -tie_span; k < tie_span; ++k) {
    const double h = double(k) + 0.5;
    chk_cvtri(h, 0, false); chk_round(h, 0);
    if ((k & 0xff) == 0 || (k > -4096 && k < 4096)) {
      chk_cvtri(std::nextafter(h, INFINITY), 0, false);
      chk_cvtri(std::nextafter(h, -INFINITY), 0, false);
      chk_round(std::nextafter(h, INFINITY), 0);
      chk_round(std::nextafter(h, -INFINITY), 0);
    }
  }
  for (int e = 0; e <= 52; ++e)
    for (double base : {std::ldexp(1.0, e), std::ldexp(1.0, e) - 1.0, std::ldexp(1.0, e) + 1.0,
                        std::ldexp(3.0, e) / 2.0})
      for (double sg : {1.0, -1.0}) {
        const double h = sg * (std::floor(base) + 0.5);
        if (h - sg * 0.5 != sg * std::floor(base)) continue;      // .5 not representable
        for (double hh : {h, std::nextafter(h, INFINITY), std::nextafter(h, -INFINITY)})
          for (int rm = 0; rm < 4; ++rm) { chk_cvtri(hh, rm, false); chk_cvtri(hh, rm, true); chk_round(hh, rm); }
      }
  // (Every game operand is a single widened to double; every tie a single
  // can hold has |n| < 2^23, so the exhaustive loop above covers them all.)
  std::printf("  ties: every n+0.5 for |n| < %lld, near-ties, ties to 2^52 : %llu checks, %llu mismatches\n",
              (long long)tie_span, (unsigned long long)(checks - c0), (unsigned long long)(fails - f0));

  // The int32 boundary, walked directly. Random 64-bit patterns reach the
  // exponent-31 band about one time in 2048 and each one has to survive the
  // subnormal and NaN filters, so the random sweep alone is not a boundary
  // test. -2^31 is representable and +2^31 is not, and that asymmetry is the
  // whole of the bug this was written for.
  for (double b : {2147483646.0, 2147483647.0, 2147483648.0, 2147483649.0,
                   4294967295.0, 4294967296.0, 8589934592.0,
                   -2147483647.0, -2147483648.0, -2147483649.0,
                   -4294967296.0, -8589934592.0})
    for (double d : {-1.5, -0.5, 0.0, 0.5, 1.5})
      for (int rm = 0; rm < 4; ++rm) {
        chk_cvtri(b + d, rm, false); chk_cvtri(b + d, rm, true);
        chk_cvtl(b + d, rm, false);  chk_cvtl(b + d, rm, true);
      }
  std::printf("  int32 boundary walked, both directions, all rounding modes\n");

  // R1045: THE CONVERSION TABLE (PRM 11-50, 12-23), directed: quiet and
  // signalling NaNs of both signs (doubles, and singles as i960_top widens
  // them), the infinities, the largest double and single, just past the
  // int32 and int64 ranges both ways, the zeros, subnormals and the
  // smallest normal -- each in every conversion form and rounding mode.
  {
    const uint64_t c0 = checks, f0 = fails;
    const uint64_t bits[] = {
      0x7ff8000000000000ull, 0xfff8000000000000ull,     // +-qNaN
      0x7ff0000000000001ull, 0xfff0000000000001ull,     // +-sNaN
      0x7ff7ffffffffffffull, 0xfff7ffffffffffffull,     // +-sNaN, every payload bit
      0x7fffffffffffffffull, 0xffffffffffffffffull,     // +-qNaN, every payload bit
      0x7ff0000020000000ull, 0xfff0000020000000ull,     // +-sNaN single 0x7f800001 widened
      0x7ffc000000000000ull,                            // a qNaN single 0x7fe00000 widened
      0x7ff0000000000000ull, 0xfff0000000000000ull,     // +-inf
      0x7fefffffffffffffull, 0xffefffffffffffffull,     // +-DBL_MAX
      0x47efffffe0000000ull, 0xc7efffffe0000000ull,     // +-FLT_MAX
      0x0000000000000000ull, 0x8000000000000000ull,     // +-0
      0x0000000000000001ull, 0x8000000000000001ull,     // +-smallest subnormal
      0x000fffffffffffffull, 0x800fffffffffffffull,     // +-largest subnormal
      0x0010000000000000ull, 0x8010000000000000ull,     // +-smallest normal
    };
    for (uint64_t b : bits) chk_cvt_all(asd(b));
    const double two31 = 2147483648.0, two63 = 9223372036854775808.0;
    for (double v : {two31, two31 - 1.0, two31 + 1.0, two31 - 0.5, two31 + 0.5,
                     4294967295.5, 4294967296.0, 4503599627370495.5, 4503599627370496.0,
                     9007199254740992.0, 9007199254740994.0, 1e18,
                     two63, std::nextafter(two63, 0.0), std::nextafter(two63, INFINITY),
                     2.0 * two63, two63 / 2.0, std::nextafter(two63 / 2.0, INFINITY),
                     9.3e18, 1e19, 1e300, 0.5, 1.5, 2.5, 0.49999999999999994})
      for (double sg : {1.0, -1.0}) chk_cvt_all(sg * v);
    // every exponent from below the subnormals to past int64, each power of
    // two and its neighbours one ulp either side, both signs
    for (int e = -1080; e <= 80; ++e)
      for (double sg : {1.0, -1.0}) {
        const double p = sg * std::ldexp(1.0, e);
        chk_cvt_all(p); chk_cvt_all(std::nextafter(p, INFINITY)); chk_cvt_all(std::nextafter(p, -INFINITY));
        chk_cvt_all(p * 1.5);
      }
    std::printf("  R1045 conversion table + every exponent      : %llu checks, %llu mismatches%s\n",
                (unsigned long long)(checks - c0), (unsigned long long)(fails - f0),
                LONGI ? "" : " (32-bit forms; built without TB_LONG)");
  }

  for (int64_t I : {0LL,1LL,-1LL,2147483647LL,-2147483648LL,12345678LL,-12345678LL}) chk_cvtir((int32_t)I);

  std::mt19937_64 rng(seed);
  for (uint64_t k = 0; k < n; ++k) {
    U x; x.u = rng(); U z; z.u = rng();
    const int rm = int(rng() & 3);
    chk_cmp(x.d, z.d); chk_logb(x.d);
    chk_round(x.d, rm);
    { const bool t = rng() & 1; chk_cvtri(x.d, rm, t); chk_cvtl(x.d, rm, t); }
    chk_cvtir((int32_t)rng());
    chk_scale(x.d, int32_t(rng() % 200) - 100);
  }
  std::printf("  random                              : %llu rounds (seed %llu)\n",
              (unsigned long long)n, (unsigned long long)seed);

  // R1013: subnormals of every leading-zero count, both signs: compare
  // (against each other, zeros, the smallest normals), logb, round and the
  // conversions in every mode.
  {
    std::mt19937_64 r4(seed ^ 0x5b);
    const double edge[] = {0.0, -0.0, 4.9406564584124654e-324, -4.9406564584124654e-324,
                           2.2250738585072009e-308, -2.2250738585072009e-308,
                           2.2250738585072014e-308, -2.2250738585072014e-308};
    for (double A : edge) {
      chk_logb(A);
      for (double B : edge) chk_cmp(A, B);
      for (int rm = 0; rm < 4; ++rm) { chk_round(A, rm); chk_cvtri(A, rm, false); chk_cvtri(A, rm, true); }
    }
    for (uint64_t k = 0; k < n; ++k) {
      U x; x.u = (r4() & 0xfffffffffffffull) >> (r4() % 53); x.u |= (r4() & 1ull) << 63;
      U z; z.u = (r4() & 0xfffffffffffffull) >> (r4() % 53); z.u |= (r4() & 1ull) << 63;
      if (k & 1) z.u = x.u + (r4() % 5) - 2;               // neighbours
      chk_cmp(x.d, z.d); chk_cmp(z.d, x.d); chk_logb(x.d);
      const int rm = int(r4() & 3);
      chk_round(x.d, rm); chk_cvtri(x.d, rm, false); chk_cvtri(x.d, rm, true);
      chk_cvtl(x.d, rm, false); chk_cvtl(x.d, rm, true);
    }
    std::printf("  subnormals (every leading-zero count): %llu checks with a subnormal operand\n",
                (unsigned long long)n_sub);
  }

  // R1045: random doubles across the whole int64 band (exponents 0..70), the
  // 64-bit forms' every shift
  if (LONGI) {
    std::mt19937_64 r5(seed ^ 0x1045);
    for (uint64_t k = 0; k < n; ++k) {
      U x; x.u = (r5() & 0x800fffffffffffffull) | (uint64_t(1023 + r5() % 71) << 52);
      const int rm = int(r5() & 3);
      chk_cvtl(x.d, rm, true); chk_cvtl(x.d, rm, false);
    }
    std::printf("  R1045 64-bit: %llu checks of the 64-bit integer in all\n", (unsigned long long)n_long);
  }

  dut->final(); delete dut;
  std::printf("  %llu checks, %llu mismatches\n",
              (unsigned long long)checks, (unsigned long long)fails);
  if (fails) { std::printf("FAIL\n"); return 1; }
  std::printf("PASS\n"); return 0;
}
