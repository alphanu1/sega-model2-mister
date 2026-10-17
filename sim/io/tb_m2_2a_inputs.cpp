// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R862: THE MODEL 2A CABINET PER GAME (rtl/io/m2_2a_inputs.sv).
//
// Random buttons, sticks, paddle, OSD bits, resets and game switches; after
// every clock edge each output is compared with what it must be for the
// game selected before the edge (the outputs are registered):
//   VF2 (game 0)  in0..in2 == Model2.sv's expressions at 9fb631d (the
//                 reference in tb_m2_2a_inputs_top.sv), an0..an2 == 0xFF.
//   Sega Rally    MAME 0.289 INPUT_PORTS_START(srallyc) + gears, with the
//                 MRA's buttons (J 4 Coin 5 Start 6 Test 7 Service 8 View
//                 9 Hand Brake 10 Accel 11 Brake 12 Gear Up 13 Gear Down):
//                   IN0 0x01 COIN1 0x04 TEST 0x08 SERVICE 0x20 VR 0x40 START1,
//                       active low, every other bit 1;
//                   IN1 bits 6:4 = daytona_gearbox_r's gearvalue[] = {0, 2,
//                       1, 6, 5} for N,1,2,3,4 (active high), the rest 1;
//                       the position steps on Gear Up / Gear Down presses
//                       (a model here, not the RTL), N out of reset;
//                   IN2 PEDAL3 (hand brake): 0x00 at rest, 0xFF held;
//                   AN0..2 == Daytona's block's steer / accel / brake.
//   Virtua Cop 2  INPUT_PORTS_START(vcop2) (J 4 Trigger 5 Start 6 Coin
//                 7 Test 8 Service, P2 on joystick 1): IN0 model2's (coins,
//                 test, service, starts), IN1 0x01 P1 trigger 0x02 P2
//                 trigger, the rest 1; IN2 0xFF; AN 0xFF.
//   Zero Gunner   INPUT_PORTS_START(zerogun) (J 4 Button 1 5 Button 2
//                 6 Start 7 Coin 8 Test 9 Service): IN1 / IN2 model2's with
//                 0x04 / 0x08 unused (1); AN 0xFF.

#include "Vtb_m2_2a_inputs_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <random>
#include <cstring>
#include <cstdlib>

static Vtb_m2_2a_inputs_top *t;
static std::mt19937_64 rng(0x862862);
static uint64_t mism = 0, checks = 0;
static int rnd(int n) { return int(rng() % uint64_t(n)); }
static inline int b(uint32_t j, int n) { return (j >> n) & 1; }

// Sega Rally's shifter, modelled from the MRA's buttons and MAME's table
static int gear = 0, gup_d = 0, gdn_d = 0;
static const int gearvalue[5] = {0, 2, 1, 6, 5};   // model2.cpp daytona_gearbox_r

struct Want { int in0, in1, in2, an0, an1, an2; };

static int lo(int bits) { return (~bits) & 0xff; }   // active low byte from "pressed" bits

static Want want_now(int game) {
  uint32_t j0 = t->joystick_0, j1 = t->joystick_1;
  Want w;
  if (game == 1) {   // Sega Rally
    w.in0 = lo(b(j0, 4) << 0 | b(j0, 6) << 2 | b(j0, 7) << 3 | b(j0, 8) << 5 | b(j0, 5) << 6);
    w.in1 = 0x8f | (gearvalue[gear] << 4);
    w.in2 = b(j0, 9) ? 0xff : 0x00;
    w.an0 = t->c_steer; w.an1 = t->c_accel; w.an2 = t->c_brake;
  } else if (game == 2) {   // Virtua Cop 2
    w.in0 = lo(b(j0, 6) << 0 | b(j1, 6) << 1 | b(j0, 7) << 2 | b(j0, 8) << 3 | b(j0, 5) << 4 | b(j1, 5) << 5);
    w.in1 = lo(b(j0, 4) << 0 | b(j1, 4) << 1);
    w.in2 = 0xff; w.an0 = w.an1 = w.an2 = 0xff;
  } else if (game == 3) {   // Zero Gunner
    w.in0 = lo(b(j0, 7) << 0 | b(j1, 7) << 1 | b(j0, 8) << 2 | b(j0, 9) << 3 | b(j0, 6) << 4 | b(j1, 6) << 5);
    auto pl = [&](uint32_t j) {   // model2: b1 b2 b3 b4 down up right left
      return lo(b(j, 4) << 0 | b(j, 5) << 1 | b(j, 2) << 4 | b(j, 3) << 5 | b(j, 0) << 6 | b(j, 1) << 7);
    };
    w.in1 = pl(j0); w.in2 = pl(j1); w.an0 = w.an1 = w.an2 = 0xff;
  } else {   // VF2: the reference registers (compared after the edge)
    w.in0 = w.in1 = w.in2 = -1; w.an0 = w.an1 = w.an2 = 0xff;
  }
  return w;
}

static void gear_edge() {
  if (!t->rst_n) { gear = 0; gup_d = 0; gdn_d = 0; return; }
  uint32_t j0 = t->joystick_0;
  int up = b(j0, 12), dn = b(j0, 13);
  int g = gear;
  if (up && !gup_d && gear != 4) g = gear + 1;
  if (dn && !gdn_d && gear != 0) g = gear - 1;   // the later assignment wins, as in the RTL
  gear = g; gup_d = up; gdn_d = dn;
}

static uint64_t per_game[4] = {0, 0, 0, 0}, gear_moves = 0, gear_seen[5] = {0, 0, 0, 0, 0};

static void cmp(const char *n, int game, uint64_t cyc, int got, int want) {
  ++checks;
  if (got != want && mism++ < 25)
    std::printf("  MISMATCH game %d cyc %llu %s: dut %02x want %02x\n", game, (unsigned long long)cyc, n, got, want);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  uint64_t N = 20000000;
  for (int i = 1; i < argc; ++i) if (!std::strncmp(argv[i], "+n=", 3)) N = std::strtoull(argv[i] + 3, nullptr, 10);
  t = new Vtb_m2_2a_inputs_top;
  t->clk = 0; t->rst_n = 0; t->is_srally = 0; t->is_vcop2 = 0; t->is_zerogun = 0;
  t->joystick_0 = 0; t->joystick_1 = 0; t->joy_analog = 0; t->joy_ranalog = 0; t->paddle = 0;
  t->st_pedswap = 0; t->st_ssens = 0; t->st_ssm = 0; t->st_rsteer = 0;
  for (int i = 0; i < 4; ++i) { t->clk = 1; t->eval(); t->clk = 0; t->eval(); }
  t->rst_n = 1; gear = 0;
  int game = 0;
  for (uint64_t c = 0; c < N; ++c) {
    if (rnd(100000) == 0) game = rnd(4);   // the MRA changes the game (quasi-static)
    t->is_srally = game == 1; t->is_vcop2 = game == 2; t->is_zerogun = game == 3;
    if (rnd(24) == 0) t->joystick_0 ^= 1u << rnd(16);
    if (rnd(24) == 0) t->joystick_1 ^= 1u << rnd(16);
    if (rnd(2000) == 0) t->joy_analog = uint16_t(rng());
    if (rnd(2000) == 0) t->joy_ranalog = uint16_t(rng());
    if (rnd(3000) == 0) t->paddle = (rnd(3) == 0) ? uint8_t(rng()) : 0;
    if (rnd(20000) == 0) { t->st_pedswap = rnd(2); t->st_ssens = rnd(4); t->st_ssm = rnd(4); t->st_rsteer = rnd(2); }
    if (rnd(500000) == 0) t->rst_n = 0; else if (!t->rst_n && rnd(8) == 0) t->rst_n = 1;
    if (!t->rst_n) { gear = 0; gup_d = 0; gdn_d = 0; }   // asynchronous in the RTL
    t->eval();
    Want w = want_now(game);
    int g0 = gear;
    gear_edge();
    if (gear != g0) ++gear_moves;
    t->clk = 1; t->eval(); t->clk = 0; t->eval();
    ++per_game[game];
    if (game == 1) ++gear_seen[g0];
    if (game == 0) {
      cmp("in0", game, c, t->in0, t->r_in0);
      cmp("in1", game, c, t->in1, t->r_in1);
      cmp("in2", game, c, t->in2, t->r_in2);
    } else {
      cmp("in0", game, c, t->in0, w.in0);
      cmp("in1", game, c, t->in1, w.in1);
      cmp("in2", game, c, t->in2, w.in2);
    }
    cmp("an0", game, c, t->an0, w.an0);
    cmp("an1", game, c, t->an1, w.an1);
    cmp("an2", game, c, t->an2, w.an2);
  }
  std::printf("  %llu cycles (VF2 %llu, Sega Rally %llu, Virtua Cop 2 %llu, Zero Gunner %llu), %llu checks\n",
              (unsigned long long)N, (unsigned long long)per_game[0], (unsigned long long)per_game[1],
              (unsigned long long)per_game[2], (unsigned long long)per_game[3], (unsigned long long)checks);
  std::printf("  shifter: %llu moves; Sega Rally cycles in N/1/2/3/4: %llu %llu %llu %llu %llu\n",
              (unsigned long long)gear_moves, (unsigned long long)gear_seen[0], (unsigned long long)gear_seen[1],
              (unsigned long long)gear_seen[2], (unsigned long long)gear_seen[3], (unsigned long long)gear_seen[4]);
  std::printf("  %llu mismatches\n%s\n", (unsigned long long)mism, mism ? "FAIL" : "PASS");
  delete t;
  return mism ? 1 : 0;
}
