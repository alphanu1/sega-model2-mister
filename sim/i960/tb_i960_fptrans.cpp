// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R845: the transcendental sequencer on the RTL units against the
// microcode's own interpreter (tools/i960_fptrans.py --vec FILE N writes
// "entry x y expected" in hex). Every result must be bit-identical; NaNs
// compare as NaNs (the units' canonical NaN is not the host's).
//
//   tools/i960_fptrans.py --vec vec.txt 20000
//   ./obj_i960_fptrans/Vi960_fptrans_harness +vec=vec.txt

#include "Vi960_fptrans_harness.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <string>

static bool isnan64(uint64_t u) { return ((u >> 52) & 0x7ff) == 0x7ff && (u & ((1ull << 52) - 1)); }

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  std::string vec = "fptrans_vec.txt";
  for (int i = 1; i < argc; i++)
    if (!std::strncmp(argv[i], "+vec=", 5)) vec = argv[i] + 5;
  FILE *f = std::fopen(vec.c_str(), "r");
  if (!f) { std::printf("no vectors (%s): run tools/i960_fptrans.py --vec\nFAIL\n", vec.c_str()); return 1; }
  auto *d = new Vi960_fptrans_harness;
  auto tick = [&]() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };
  d->rst_n = 0; d->start = 0; tick(); tick(); d->rst_n = 1; tick();
  unsigned e; unsigned long long x, y, want;
  long n = 0, bad = 0; unsigned long long cyc = 0, maxc[5] = {}, sumc[5] = {}, cnt[5] = {};   // R935: [4] logrl
  while (std::fscanf(f, "%u %llx %llx %llx", &e, &x, &y, &want) == 4) {
    d->entry = e; d->x = x; d->y = y; d->start = 1; tick(); d->start = 0;
    unsigned long long c = 1;
    while (!d->fin) { tick(); if (++c > 200000) { std::printf("HANG at vector %ld\nFAIL\n", n); return 1; } }
    const uint64_t got = d->res;
    tick();   // S_END
    const bool ok = (got == want) || (isnan64(got) && isnan64(want));
    if (!ok) {
      if (bad < 20) std::printf("  MISMATCH %ld entry %u x %016llx y %016llx: rtl %016llx want %016llx\n",
                                n, e, x, y, (unsigned long long)got, want);
      ++bad;
    }
    cyc += c; { const unsigned k = e > 4 ? 0 : e; if (c > maxc[k]) maxc[k] = c; sumc[k] += c; cnt[k]++; }
    ++n;
  }
  static const char *nm[5] = {"sin", "cos", "tan", "atan", "log"};
  for (int i = 0; i < 5; i++)
    if (cnt[i]) std::printf("  %-4s %llu vectors, cycles mean %llu max %llu\n", nm[i], cnt[i], sumc[i] / cnt[i], maxc[i]);
  std::printf("  %ld vectors, %ld mismatches\n", n, bad);
  std::printf(bad || !n ? "FAIL\n" : "PASS\n");
  return bad || !n;
}
