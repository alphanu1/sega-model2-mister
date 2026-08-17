// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Harness for i960_fpcvt against the host's own float/double conversions,
// which is exactly what the reference's u2f and f2u do.
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <random>
#include "Vi960_fpcvt.h"
#include "verilated.h"

namespace {
Vi960_fpcvt *dut = nullptr;
uint64_t checks = 0, fails = 0;
const int MAX_REPORT = 14;
union Ud { double d; uint64_t u; };
union Uf { float f; uint32_t u; };
inline double asd(uint64_t b) { Ud t; t.u = b; return t.d; }
inline float  asf(uint32_t b) { Uf t; t.u = b; return t.f; }

bool sub_d(double x) { return x != 0.0 && std::fabs(x) < 2.2250738585072014e-308; }
bool sub_f(float x)  { return x != 0.0f && std::fabs(x) < 1.17549435e-38f; }

void chk_widen(uint32_t sbits) {
  const float f = asf(sbits);
  if (sub_f(f)) return;                       // flushed here, not by the host
  dut->s_in = sbits; dut->eval();
  Ud want; want.d = (double)f;
  ++checks;
  if (dut->d_out != want.u && !(std::isnan((double)f) && std::isnan(asd(dut->d_out)))) {
    if (fails < MAX_REPORT)
      std::printf("  MISMATCH widen  %08x -> got=%016llx want=%016llx\n",
                  sbits, (unsigned long long)dut->d_out, (unsigned long long)want.u);
    ++fails;
  }
}

void chk_narrow(uint64_t dbits) {
  const double d = asd(dbits);
  if (sub_d(d)) return;
  const float wf = (float)d;
  if (sub_f(wf)) return;                      // subnormal single result flushed
  dut->d_in = dbits; dut->eval();
  Uf want; want.f = wf;
  ++checks;
  if (dut->s_out != want.u && !(std::isnan(wf) && std::isnan(asf(dut->s_out)))) {
    if (fails < MAX_REPORT)
      std::printf("  MISMATCH narrow %016llx -> got=%08x want=%08x\n",
                  (unsigned long long)dbits, dut->s_out, want.u);
    ++fails;
  }
}
} // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  uint64_t n = 400000, seed = 1;
  for (int i = 1; i < argc; ++i) {
    if (!std::strncmp(argv[i], "+random=", 8)) n = std::strtoull(argv[i]+8, nullptr, 10);
    if (!std::strncmp(argv[i], "+seed=", 6))   seed = std::strtoull(argv[i]+6, nullptr, 10);
  }
  dut = new Vi960_fpcvt;
  std::printf("i960_fpcvt vs the host float/double conversions\n");

  const float fs[] = {0.0f,-0.0f,1.0f,-1.0f,2.0f,0.5f,3.14159265f,
                      3.4028235e38f,-3.4028235e38f,1.4e-45f,
                      INFINITY,-INFINITY,NAN};
  for (float f : fs) { Uf u; u.f = f; chk_widen(u.u); }
  const double ds[] = {0.0,-0.0,1.0,-1.0,0.5,1e300,-1e300,1e-300,
                       3.4028235677549e38, 3.4028234663852886e38,
                       1.0000000596046448, INFINITY,-INFINITY,NAN};
  for (double d : ds) { Ud u; u.d = d; chk_narrow(u.u); }
  std::printf("  specials both directions\n");

  // Exhaustive over the single exponent field, which is where narrowing
  // overflows and underflows.
  for (uint32_t e = 0; e < 256; ++e)
    for (uint32_t m : {0u, 1u, 0x400000u, 0x7fffffu}) {
      chk_widen((e << 23) | m);
      chk_widen(0x80000000u | (e << 23) | m);
    }
  std::printf("  every single exponent x 4 mantissas, both signs\n");

  // Halfway mantissas: bit 28 set with and without anything below it is the
  // tie case that decides round-to-even on narrowing.
  for (uint32_t k = 0; k < 64; ++k) {
    const uint64_t base = (uint64_t(1023 + (k % 8)) << 52) | (uint64_t(k) << 45);
    chk_narrow(base | (1ull << 28));
    chk_narrow(base | (1ull << 28) | 1ull);
    chk_narrow(base | (1ull << 29) | (1ull << 28));
  }
  std::printf("  narrowing tie cases (round to even)\n");

  std::mt19937_64 rng(seed);
  for (uint64_t k = 0; k < n; ++k) { chk_widen((uint32_t)rng()); chk_narrow(rng()); }
  std::printf("  random                   : %llu each way (seed %llu)\n",
              (unsigned long long)n, (unsigned long long)seed);

  dut->final(); delete dut;
  std::printf("  %llu checks, %llu mismatches\n",
              (unsigned long long)checks, (unsigned long long)fails);
  if (fails) { std::printf("FAIL\n"); return 1; }
  std::printf("PASS\n"); return 0;
}
