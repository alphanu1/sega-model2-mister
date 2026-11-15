// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Harness for i960_fpsqrt against the host's sqrt.
//
// This comparison is BIT-EXACT and legitimately so: IEEE-754 requires square
// root to be correctly rounded, so there is exactly one right answer per input
// and the host produces it too. Unlike sin or log, matching here is a property
// of the specification rather than of any particular libm.
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <random>
#include "Vi960_fpsqrt.h"
#include "verilated.h"

namespace {
Vi960_fpsqrt *dut = nullptr;
uint64_t checks = 0, fails = 0;
const int MAX_REPORT = 12;
union U { double d; uint64_t u; };
void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }
bool is_sub(double x) { return x != 0.0 && std::fabs(x) < 2.2250738585072014e-308; }
// R1013: subnormal operands are compared too (SUBNORM 1: the root of one is
// normal); -DTB_FLUSH checks a SUBNORM 0 unit and skips them. A normal
// operand must take the same cycles as before, whatever a subnormal costs.
#ifdef TB_FLUSH
const bool FLUSH = true;
#else
const bool FLUSH = false;
#endif
uint64_t n_sub_in = 0, cyc_bad = 0;
int cyc_norm = -1, cyc_min = 1 << 30, cyc_max = 0;

void check(double A, const char *why) {
  U ua{A};
  dut->a = ua.u; dut->req = 1; tick(); dut->req = 0;
  int cyc = 1;
  for (int i = 0; i < 200 && !dut->done; i++) { tick(); ++cyc; }
  const double want = std::sqrt(A);
  if (FLUSH && (is_sub(want) || is_sub(A))) { tick(); return; }
  if (is_sub(A)) {
    ++n_sub_in;
    if (A > 0) { if (cyc < cyc_min) cyc_min = cyc; if (cyc > cyc_max) cyc_max = cyc; }
  } else if (std::isfinite(A) && A > 0) {
    if (cyc_norm < 0) cyc_norm = cyc;
    else if (cyc != cyc_norm) { if (cyc_bad < 4) std::printf("  CYCLES %d for sqrt(%.17g)\n", cyc, A); ++cyc_bad; }
  }
  U got; got.u = dut->y;
  ++checks;
  const bool both_nan = std::isnan(want) && std::isnan(got.d);
  if (!both_nan && got.u != U{want}.u) {
    if (fails < MAX_REPORT)
      std::printf("  MISMATCH [%s] sqrt(%.17g)  got=%.17g (%016llx) want=%.17g (%016llx)\n",
                  why, A, got.d, (unsigned long long)got.u,
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
  dut = new Vi960_fpsqrt;
  dut->rst_n = 0; dut->req = 0;
  for (int i = 0; i < 4; i++) tick();
  dut->rst_n = 1; tick();
  std::printf("i960_fpsqrt vs the host sqrt (bit-exact by IEEE-754)\n");

  const double sp[] = {0.0, -0.0, 1.0, -1.0, 2.0, 4.0, 0.25, 0.5, 9.0, 1e308,
                       1e-300, 3.0, 1.0000000000000002, INFINITY, -INFINITY, NAN};
  for (double A : sp) check(A, "special");
  std::printf("  specials incl. -0, negatives, inf, nan : %zu\n", sizeof(sp)/sizeof(sp[0]));

  // Perfect squares must come back exactly; a rounding error shows instantly.
  for (int k = 1; k < 4000; ++k) check(double(k) * double(k), "perfect-square");
  std::printf("  perfect squares 1..3999                : exact roots\n");

  // Both exponent parities, since an odd exponent takes the extra-shift path.
  for (int e = -300; e <= 300; e += 7) { check(std::ldexp(1.3, e), "parity"); }
  std::printf("  both exponent parities                 : swept\n");

  std::mt19937_64 rng(seed);
  for (uint64_t k = 0; k < n; ++k) {
    U x; x.u = rng();
    if (std::isnan(x.d) || (FLUSH && is_sub(x.d))) continue;
    check(std::fabs(x.d), "random");
    // R1013: a subnormal of every leading-zero count, both signs.
    U z; z.u = (rng() & 0x800fffffffffffffull) >> (rng() % 53);
    z.u |= (rng() & 1ull) << 63;
    check(z.d, "subnormal");
  }
  // Perfect squares in the subnormal range: (k * 2^-537)^2 = k^2 * 2^-1074.
  for (uint64_t k = 1; k < (1ull << 26); k += 1 + (k >> 6)) check(double(k * k) * 4.9406564584124654e-324, "subnormal square");
  std::printf("  subnormals of every leading-zero count, subnormal perfect squares\n");
  std::printf("  random bit patterns                    : %llu (seed %llu)\n",
              (unsigned long long)n, (unsigned long long)seed);

  dut->final(); delete dut;
  std::printf("  checks with a subnormal operand %llu; cycles req -> done: normal %d (%llu not), subnormal %d .. %d\n",
              (unsigned long long)n_sub_in, cyc_norm, (unsigned long long)cyc_bad, cyc_min, cyc_max);
  if (cyc_bad) ++fails;
  std::printf("  %llu checks, %llu mismatches\n",
              (unsigned long long)checks, (unsigned long long)fails);
  if (fails) { std::printf("FAIL\n"); return 1; }
  std::printf("PASS\n"); return 0;
}
