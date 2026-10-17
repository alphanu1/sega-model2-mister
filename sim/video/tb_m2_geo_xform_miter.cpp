// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R866: m2_geo_xform (matrix in LUT RAM) against m2_geo_xform_ff, every
// output every cycle: random matrix writes (any index), points offered at
// random, the pool's grants and results at random -- including results the
// pool would never send -- and resets.   Vm2_geo_xform_miter [+cycles=N] [+seed=S]
#include "Vm2_geo_xform_miter.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  uint64_t cycles = 4000000;
  uint32_t seed = 1;
  for (int i = 1; i < argc; i++) {
    if (!strncmp(argv[i], "+cycles=", 8)) cycles = strtoull(argv[i] + 8, nullptr, 0);
    if (!strncmp(argv[i], "+seed=", 6)) seed = strtoul(argv[i] + 6, nullptr, 0);
  }
  std::mt19937 rng(seed);
  auto R = [&](uint32_t n) { return (uint32_t)(rng() % n); };
  auto P = [&](double p) { return (rng() / 4294967296.0) < p; };
  Vm2_geo_xform_miter *t = new Vm2_geo_xform_miter;
  uint64_t fails = 0, outs = 0, muls = 0;
  t->clk = 0; t->rst_n = 0; t->eval();
  for (int i = 0; i < 3; i++) { t->clk = 1; t->eval(); t->clk = 0; t->eval(); }
  t->rst_n = 1;
  int rst_left = 0;
  for (uint64_t c = 0; c < cycles; c++) {
    if (rst_left > 0) { rst_left--; t->rst_n = rst_left == 0; }
    else if (P(0.00005)) { rst_left = 1 + R(3); t->rst_n = 0; }
    t->mat_we = P(0.05); t->mat_idx = R(16); t->mat_data = rng();
    t->in_valid = P(0.3); t->in_x = rng(); t->in_y = rng(); t->in_z = rng(); t->in_translate = P(0.5);
    t->mul_gnt = P(0.7); t->mul_rsp = P(0.4); t->mul_res = rng();
    t->add_gnt = P(0.7); t->add_rsp = P(0.4); t->add_res = rng();
    t->eval();
    if (t->diff) { if (fails < 5) printf("  cycle %llu: outputs differ\n", (unsigned long long)c); fails++; }
    muls += t->mul_req_o;
    t->clk = 1; t->eval();
    t->clk = 0; t->eval();
    outs += t->out_valid_o;
    if (t->diff) { if (fails < 5) printf("  cycle %llu (after edge): outputs differ\n", (unsigned long long)c); fails++; }
  }
  printf("m2_geo_xform (matrix in LUT RAM) vs m2_geo_xform_ff, seed %u: %llu cycles, %llu points out, "
         "%llu multiply-request cycles\n%llu differences\n%s\n", seed, (unsigned long long)cycles,
         (unsigned long long)outs, (unsigned long long)muls, (unsigned long long)fails,
         fails ? "FAIL" : "PASS");
  delete t;
  return fails ? 1 : 0;
}
