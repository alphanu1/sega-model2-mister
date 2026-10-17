// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R866: the LUT-RAM register file against the flip-flop one, every output on
// every cycle, under random inputs -- legal sequences and illegal ones alike
// (an op while busy, a write while busy, ack at any time, resets mid-frame):
// two deterministic machines on the same inputs must agree whatever the
// inputs are. Phases bias toward deep call chains (spills to memory, the
// cache full), long return runs (fills from memory), flushreg at every depth.
//
//   Vi960_regs_miter [+cycles=N] [+seed=S]
#include "Vi960_regs_miter.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>

static const char *GROUP[13] = {"rd1", "rd2", "busy/nipv/ret_un", "next_ip(valid)", "next_ip",
                                "cur_fp", "cur_sp", "pfp_type", "dbg_rip/pfp", "rcache_pos/to_mem",
                                "mem_req/we", "mem_addr", "mem_wdata"};

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
  Vi960_regs_miter *t = new Vi960_regs_miter;
  uint64_t fails = 0, calls = 0, rets = 0, flushes = 0, spills = 0, maxpos = 0, ackcyc = 0;
  uint32_t gcount[13] = {0};
  t->clk = 0; t->rst_n = 0; t->eval();
  for (int i = 0; i < 4; i++) { t->clk = 1; t->eval(); t->clk = 0; t->eval(); }
  t->rst_n = 1;
  int phase = 0, phase_left = 0, rst_left = 0;
  for (uint64_t c = 0; c < cycles; c++) {
    if (phase_left-- <= 0) { phase = R(4); phase_left = 200 + R(3000); }
    // inputs for this cycle (applied on the low phase, sampled at the rise)
    if (rst_left > 0) { rst_left--; t->rst_n = rst_left == 0; }
    else if (P(0.00003)) { rst_left = 1 + R(3); t->rst_n = 0; }
    double pc = phase == 0 ? 0.25 : phase == 1 ? 0.03 : 0.10;
    double pr = phase == 0 ? 0.03 : phase == 1 ? 0.25 : 0.10;
    t->op_call = P(pc);
    t->op_ret = P(pr);
    t->op_flushreg = P(phase == 3 ? 0.05 : 0.005);
    t->we = P(0.5);
    t->wa = R(32);
    t->wd = rng();
    if (t->wa == 0) {                         // PFP: keep the return type legal most of the time
      if (P(0.97)) t->wd = (t->wd & ~7u) | (P(0.8) ? 0 : 7);
    }
    t->ra1 = R(32); t->ra2 = R(32);
    t->call_ip = rng(); t->call_target = rng(); t->call_stack = rng();
    t->call_type = P(0.8) ? 0 : (P(0.8) ? 7 : R(8));
    t->boot_fp_we = P(0.0005);
    t->boot_fp = rng();
    t->mem_rdata = rng();
    t->mem_ack = phase == 2 ? P(0.9) : P(0.4);
    t->eval();
    calls += t->op_call && !t->busy_o;
    rets += t->op_ret && !t->busy_o;
    flushes += t->op_flushreg && !t->busy_o;
    spills += t->mem_req_o;
    ackcyc += t->mem_req_o && t->mem_ack;
    t->clk = 1; t->eval();
    t->clk = 0; t->eval();
    if ((uint64_t)(int64_t)(int32_t)t->rcache_pos_o > maxpos && (int32_t)t->rcache_pos_o < 1000000)
      maxpos = (int32_t)t->rcache_pos_o;
    if (t->diff) {
      for (int g = 0; g < 13; g++)
        if (t->diff & (1u << (12 - g))) {
          if (gcount[g]++ < 5) printf("  cycle %llu: %s differs\n", (unsigned long long)c, GROUP[g]);
        }
      fails++;
    }
  }
  printf("i960_regs (LUT RAM) vs i960_regs_ff (flip-flops), seed %u: %llu cycles, %llu calls, "
         "%llu rets, %llu flushregs accepted, %llu memory-port cycles (%llu acked), depth max %llu\n",
         seed, (unsigned long long)cycles, (unsigned long long)calls, (unsigned long long)rets,
         (unsigned long long)flushes, (unsigned long long)spills, (unsigned long long)ackcyc,
         (unsigned long long)maxpos);
  printf("%llu cycles with a difference\n%s\n", (unsigned long long)fails, fails ? "FAIL" : "PASS");
  delete t;
  return fails ? 1 : 0;
}
