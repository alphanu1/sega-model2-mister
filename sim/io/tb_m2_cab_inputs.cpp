// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R835: THE CABINET INPUTS, MOVED AND EXTENDED FOR DESERT TANK.
//
// Part A, is_desert = 0: rtl/io/m2_cab_inputs.sv against the block as it stood
// in Model2.sv at 0f3cbc4 (sim/io/m2_cab_inputs_ref.sv) -- in0, in1, steer,
// accel and brake compared after every clock edge and after every input
// change, under random buttons, sticks, paddle, OSD bits and resets. Any
// difference is a Daytona regression.
// Part B, is_desert = 1: in0 / steer / accel / brake still equal the
// reference (Desert Tank uses them unchanged), and in1 equals MAME's
// INPUT_PORTS_START(desert): 0x01 Shift (a toggle: each press of joystick
// bit 9 flips it, reset to released), 0x10 Machine Gun (bit 12), 0x20 Cannon
// (bit 13), every other bit 1.

#include "Vtb_m2_cab_inputs_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <random>

static Vtb_m2_cab_inputs_top *t;
static std::mt19937_64 rng(0x835835);
static uint64_t mism = 0, checks = 0;

static int rnd(int n) { return int(rng() % uint64_t(n)); }

// Desert Tank's IN1 model
static int shift = 0, shf_d = 0;

static void check(const char *ph, uint64_t cyc, bool desert) {
  auto cmp = [&](const char *n, int a, int b) {
    ++checks;
    if (a != b && mism++ < 20)
      printf("  MISMATCH %s cyc %llu %s: dut %02x want %02x\n", ph, (unsigned long long)cyc, n, a, b);
  };
  cmp("in0", t->in0, t->r_in0);
  cmp("steer", t->steer, t->r_steer);
  cmp("accel", t->accel, t->r_accel);
  cmp("brake", t->brake, t->r_brake);
  if (!desert) {
    cmp("in1", t->in1, t->r_in1);
  } else {
    int j = t->joystick_0;
    int want = 0xc0 | (((j >> 13) & 1) ? 0 : 0x20) | (((j >> 12) & 1) ? 0 : 0x10) | 0x0e | (shift ? 0 : 1);
    cmp("in1", t->in1, want);
  }
}

static void edge(bool desert) {
  // the model's register, sampled at the rising edge on the pre-edge inputs
  int j9 = (t->joystick_0 >> 9) & 1;
  if (!t->rst_n) { shift = 0; shf_d = 0; }
  else { if (j9 && !shf_d) shift ^= 1; shf_d = j9; }
  t->clk = 1; t->eval();
  t->clk = 0; t->eval();
  (void)desert;
}

static uint64_t run(const char *ph, bool desert, uint64_t ncyc, uint64_t &toggles, uint64_t &in1_diff) {
  t->is_desert = desert;
  int prev_shift = shift;
  for (uint64_t c = 0; c < ncyc; ++c) {
    // inputs change between edges
    if (rnd(48) == 0) t->joystick_0 ^= 1u << rnd(16);
    if (rnd(2000) == 0) t->joy_analog  = uint16_t(rng());
    if (rnd(2000) == 0) t->joy_ranalog = uint16_t(rng());
    if (rnd(3000) == 0) t->paddle = (rnd(3) == 0) ? uint8_t(rng()) : 0;
    if (rnd(20000) == 0) { t->st_pedswap = rnd(2); t->st_ssens = rnd(4); t->st_ssm = rnd(4); t->st_rsteer = rnd(2); }
    if (rnd(200000) == 0) t->rst_n = 0; else if (!t->rst_n && rnd(8) == 0) t->rst_n = 1;
    if (!t->rst_n) { shift = 0; shf_d = 0; }   // the RTL's reset is asynchronous
    t->eval();
    check(ph, c, desert);
    edge(desert);
    check(ph, c, desert);
    if (shift != prev_shift) { ++toggles; prev_shift = shift; }
    if (t->in1 != t->r_in1) ++in1_diff;
  }
  return ncyc;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  t = new Vtb_m2_cab_inputs_top;
  t->clk = 0; t->rst_n = 0; t->is_desert = 0; t->joystick_0 = 0;
  t->joy_analog = 0; t->joy_ranalog = 0; t->paddle = 0;
  t->st_pedswap = 0; t->st_ssens = 0; t->st_ssm = 0; t->st_rsteer = 0;
  for (int i = 0; i < 4; ++i) edge(false);
  t->rst_n = 1;
  uint64_t tg = 0, d = 0;
  printf("== part A: is_desert = 0 against the 0f3cbc4 block\n");
  run("A", false, 3000000, tg, d);
  uint64_t ma = mism;
  printf("   %llu checks, %llu mismatches\n", (unsigned long long)checks, (unsigned long long)ma);
  printf("== part B: is_desert = 1, Desert Tank's IN1\n");
  t->rst_n = 0; edge(true); t->rst_n = 1;
  uint64_t c0 = checks; tg = 0; d = 0;
  run("B", true, 3000000, tg, d);
  printf("   %llu checks, %llu mismatches; shift toggled %llu times; in1 differs from Daytona's on %llu cycles\n",
         (unsigned long long)(checks - c0), (unsigned long long)(mism - ma),
         (unsigned long long)tg, (unsigned long long)d);
  bool ok = (mism == 0) && tg > 100 && d > 1000;
  printf("%s\n", ok ? "PASS" : "FAIL");
  delete t;
  return ok ? 0 : 1;
}
