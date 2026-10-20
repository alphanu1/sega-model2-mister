// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R891: the board memory test (m2_memtest) where the answer is known.
//   MT_PASSES   read passes to run (default 4: the first, then three after waits)
//   MT_TICK     cycles per tick (default 65536, as the probe's prof_tick)
//   MT_EXPECT   clean | mask | alias | decay -- what the run must report:
//                 clean  every pass 0 errors
//                 mask   mask errors in every region, no data errors (R82)
//                 alias  data errors in the lower half's regions (0-7) only
//                 decay  pass 1 clean, a later pass with data errors in the
//                        upper half (8-15) only (the second chip not refreshed)
//   MT_OUT      write the records as the probe stream would ('B' / 'b' lines)
//               for tools/decode_why.py
// The 'b' summary and the sixteen 'B's are read after every pass.
#include "Vm2_memtest_harness.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static Vm2_memtest_harness *d;
static long cyc = 0, tick_n = 65536;
static void step() {
  d->tick = (cyc % tick_n) == (tick_n - 1);
  d->clk = 0; d->eval(); d->clk = 1; d->eval(); ++cyc;
}
struct Rec { char t; uint32_t a, dd; };
static std::vector<Rec> read_all() {
  std::vector<Rec> v;
  for (int s = 0; s <= 16; ++s) {
    d->sel = s; for (int i = 0; i < 4; ++i) step();
    v.push_back({ char(s == 16 ? 'b' : 'B'), d->r_a, d->r_d });
  }
  return v;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_memtest_harness;
  const int passes_want = getenv("MT_PASSES") ? atoi(getenv("MT_PASSES")) : 4;
  if (getenv("MT_TICK")) tick_n = atol(getenv("MT_TICK"));
  const std::string expect = getenv("MT_EXPECT") ? getenv("MT_EXPECT") : "clean";
  FILE *out = getenv("MT_OUT") ? fopen(getenv("MT_OUT"), "w") : nullptr;

  d->rst_n = 0; d->stop = 0; d->sel = 16; d->tick = 0;
  for (int i = 0; i < 8; ++i) step();
  d->rst_n = 1;
  long t_done0 = -1;
  int seen = 0, fails = 0;
  // per pass: data / mask errors per region
  std::vector<std::vector<std::pair<int,int>>> res;
  while (seen < passes_want && cyc < 400000000L) {
    step();
    if (t_done0 < 0 && d->done0) t_done0 = cyc;
    if (d->passes != seen) {
      seen = d->passes;
      auto v = read_all();
      std::vector<std::pair<int,int>> pr(16);
      int tde = 0, tme = 0;
      printf("pass %d complete @%ld:", seen, cyc);
      for (auto &r : v) {
        if (out) fprintf(out, "%c %08x %08x\n", r.t, r.a, r.dd);
        if (r.t == 'B') {
          int reg = (r.a >> 20) & 15, de = (r.a >> 8) & 0x1ff, me = (r.dd >> 16) & 0x1ff, ps = r.a >> 24;
          if (ps != seen) { printf(" [region %d carries pass %d]", reg, ps); ++fails; }
          pr[reg] = { de, me }; tde += de; tme += me;
          if (de || me) printf(" r%d:%d/%d", reg, de, me);
        } else if ((int)(r.a >> 24) != seen || ((r.a >> 16) & 0x1f) != 26) {
          printf(" [summary says pass %u, AW %u]", r.a >> 24, (r.a >> 16) & 0x1f); ++fails;
        }
      }
      printf("  total data %d mask %d\n", tde, tme);
      res.push_back(pr);
    }
  }
  printf("done0 at cycle %ld (the loader waits this long after ready); %d passes in %ld cycles; violations %u flags %04x, rows decayed %u\n",
         t_done0, seen, cyc, d->violations, d->v_flags, d->decayed_rows);
  if (seen < passes_want) { printf("FAIL: only %d passes\n", seen); ++fails; }

  auto tot = [&](int p, int lo, int hi, bool mask) { int n = 0;
    for (int r = lo; r <= hi; ++r) n += mask ? res[p][r].second : res[p][r].first; return n; };
  if (expect == "clean") {
    for (size_t p = 0; p < res.size(); ++p)
      if (tot(p, 0, 15, false) || tot(p, 0, 15, true)) { printf("FAIL: pass %zu has errors\n", p + 1); ++fails; }
    if (d->violations) { printf("FAIL: protocol violations\n"); ++fails; }
  } else if (expect == "mask") {
    for (int r = 0; r < 16; ++r)
      if (!res[0][r].second || res[0][r].first) { printf("FAIL: region %d not mask-only\n", r); ++fails; }
  } else if (expect == "alias") {
    if (!tot(0, 0, 7, false) || tot(0, 8, 15, false) || tot(0, 0, 15, true)) { printf("FAIL: not the lower-half alias\n"); ++fails; }
  } else if (expect == "decay") {
    if (tot(0, 0, 15, false) || tot(0, 0, 15, true)) { printf("FAIL: pass 1 not clean\n"); ++fails; }
    bool any = false;
    for (size_t p = 1; p < res.size(); ++p) {
      if (tot(p, 0, 7, false)) { printf("FAIL: pass %zu errors in chip 0\n", p + 1); ++fails; }
      if (tot(p, 8, 15, false)) any = true;
    }
    if (!any) { printf("FAIL: no decay seen in chip 1\n"); ++fails; }
  }
  if (out) fclose(out);
  printf("%s (%s)\n", fails ? "FAIL" : "PASS", expect.c_str());
  delete d;
  return fails ? 1 : 0;
}
