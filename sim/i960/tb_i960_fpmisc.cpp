// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Harness for i960_fpmisc against the host's own operations. Every operation
// here is exactly specified, so these comparisons are bit-exact by right
// rather than by tolerance.
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
union U { double d; uint64_t u; };
// Reinterpret raw bits as a double. `U{x}.d` initialises the FIRST member, so
// for an integer x it CONVERTS rather than reinterprets and every NaN check
// built on it silently fails.
inline double asd(uint64_t b) { U t; t.u = b; return t.d; }
bool is_sub(double x) { return x != 0.0 && std::fabs(x) < 2.2250738585072014e-308; }

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
  dut->ai = (uint32_t)I; dut->rmode = rm; dut->eval();
}

// round_to_int, exactly as the reference selects it from AC[31:30].
double rti(double v, int rm) {
  switch (rm) { case 0: return std::round(v); case 1: return std::floor(v);
                case 2: return std::ceil(v);  default: return std::trunc(v); }
}

void chk_cmp(double A, double B) {
  set(OP_CMP, A, B, 0, 0);
  uint32_t want = 0;
  if (!(std::isnan(A) || std::isnan(B))) want = (A < B) ? 4 : (A == B) ? 2 : 1;
  ++checks; if (dut->cc != want) fail("cmp", "cc", dut->cc, want);
}
void chk_logb(double A) {
  if (is_sub(A)) return;
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
  if (is_sub(A) || std::isnan(A) || std::isinf(A)) return;
  const double r = rti(A, trunc_mode ? 3 : rm);
  if (r < -2147483648.0 || r > 2147483647.0) return;      // out of int32 range
  set(trunc_mode ? OP_CVTZRI : OP_CVTRI, A, 0, 0, rm);
  const uint32_t want = (uint32_t)(int32_t)r;
  ++checks; if (dut->yi != want) fail(trunc_mode ? "cvtzri" : "cvtri", "yi", dut->yi, want);
}
void chk_round(double A, int rm) {
  if (is_sub(A)) return;
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
  for (int i = 1; i < argc; ++i) {
    if (!std::strncmp(argv[i], "+random=", 8)) n = std::strtoull(argv[i]+8, nullptr, 10);
    if (!std::strncmp(argv[i], "+seed=", 6))   seed = std::strtoull(argv[i]+6, nullptr, 10);
  }
  dut = new Vi960_fpmisc;
  std::printf("i960_fpmisc vs the host (all operations exactly specified)\n");

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

  // Halfway cases: mode 0 is round-half-AWAY-FROM-ZERO, not half-to-even.
  for (double h : {0.5,1.5,2.5,3.5,-0.5,-1.5,-2.5,-3.5,4.5,-4.5})
    for (int rm = 0; rm < 4; ++rm) { chk_round(h, rm); chk_cvtri(h, rm, false); }
  std::printf("  halfway cases in all four rounding modes\n");

  for (int64_t I : {0LL,1LL,-1LL,2147483647LL,-2147483648LL,12345678LL,-12345678LL}) chk_cvtir((int32_t)I);

  std::mt19937_64 rng(seed);
  for (uint64_t k = 0; k < n; ++k) {
    U x; x.u = rng(); U z; z.u = rng();
    const int rm = int(rng() & 3);
    chk_cmp(x.d, z.d); chk_logb(x.d);
    chk_round(x.d, rm); chk_cvtri(x.d, rm, rng() & 1);
    chk_cvtir((int32_t)rng());
    chk_scale(x.d, int32_t(rng() % 200) - 100);
  }
  std::printf("  random                              : %llu rounds (seed %llu)\n",
              (unsigned long long)n, (unsigned long long)seed);

  dut->final(); delete dut;
  std::printf("  %llu checks, %llu mismatches\n",
              (unsigned long long)checks, (unsigned long long)fails);
  if (fails) { std::printf("FAIL\n"); return 1; }
  std::printf("PASS\n"); return 0;
}
