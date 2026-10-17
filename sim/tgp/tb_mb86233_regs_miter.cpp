// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R866: mb86233_regs (rf in LUT RAM) against mb86233_regs_ff (flip-flops),
// every output every cycle, random inputs with reads and writes biased to
// rf 0x20-0x2f, resets at random.   Vmb86233_regs_miter [+cycles=N] [+seed=S]
#include "Vmb86233_regs_miter.h"
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
  Vmb86233_regs_miter *t = new Vmb86233_regs_miter;
  uint64_t fails = 0, rfreads = 0, rfzero = 0;
  t->clk = 0; t->rst_n = 0; t->eval();
  for (int i = 0; i < 3; i++) { t->clk = 1; t->eval(); t->clk = 0; t->eval(); }
  t->rst_n = 1;
  int rst_left = 0;
  for (uint64_t c = 0; c < cycles; c++) {
    if (rst_left > 0) { rst_left--; t->rst_n = rst_left == 0; }
    else if (P(0.0002)) { rst_left = 1 + R(3); t->rst_n = 0; }
    t->rd_addr = P(0.6) ? 0x20 + R(16) : R(64);
    t->wr_en = P(0.3);
    t->wr_addr = P(0.6) ? 0x20 + R(16) : R(64);
    t->wr_data = rng(); t->rf_fifo_rdata = rng();
    t->alu_d_we = P(0.1); t->alu_p_we = P(0.1); t->alu_d = rng(); t->alu_p = rng();
    t->clr_a = P(0.02); t->clr_b = P(0.02); t->clr_d = P(0.02);
    t->agu_x0_we = P(0.1); t->agu_x1_we = P(0.1); t->agu_x0 = rng(); t->agu_x1 = rng();
    t->c0 = rng(); t->c1 = rng();
    t->eval();
    if (t->rd_addr >= 0x20 && t->rd_addr < 0x30 && t->rd_addr != 0x21) { rfreads++; rfzero += t->rd_new == 0; }
    if (t->diff) { if (fails < 5) printf("  cycle %llu: outputs differ\n", (unsigned long long)c); fails++; }
    t->clk = 1; t->eval();
    t->clk = 0; t->eval();
    if (t->diff) { if (fails < 5) printf("  cycle %llu (after edge): outputs differ\n", (unsigned long long)c); fails++; }
  }
  printf("mb86233_regs (rf in LUT RAM) vs mb86233_regs_ff, seed %u: %llu cycles, %llu rf reads "
         "(%llu of them 0)\n%llu differences\n%s\n", seed, (unsigned long long)cycles,
         (unsigned long long)rfreads, (unsigned long long)rfzero, (unsigned long long)fails,
         fails ? "FAIL" : "PASS");
  delete t;
  return fails ? 1 : 0;
}
