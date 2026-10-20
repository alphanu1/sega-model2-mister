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
//   Virtua Cop 2  INPUT_PORTS_START(vcop2) (J 4 Trigger 5 Reload 6 Start
//                 7 Coin 8 Test 9 Service -- Virtua Cop's order, R870 --
//                 P2 on joystick 1; GUN 0 here: IN1 from the buttons): IN0 model2's (coins,
//                 test, service, starts), IN1 0x01 P1 trigger 0x02 P2
//                 trigger, the rest 1; IN2 0xFF; AN 0xFF.
//   Zero Gunner   INPUT_PORTS_START(zerogun). R887: the DIGITAL profile's
//                 fixed order (J 4 B1 5 B2 6 B3 7 Start 8 Coin 9 Test
//                 10 Service); its MRA names J 6 "-" (MiSTer never maps
//                 it), so IN1 / IN2 0x04 is MAME's unused 1 on the cabinet.
//                 Before R887 its own order was J 4 B1 5 B2 6 Start 7 Coin
//                 8 Test 9 Service: the same ports through the MRA's new
//                 <buttons>, the reference moved with it.
//   R887, the other IDs:
//     DIGITAL (0x13-0x16 and any ID not below): model2's ports in the fixed
//                 order above (VF2's map; MAME's Punch / Kick / Jump, Hold /
//                 Punch / Kick on B1-B3), P2 on joystick 1; AN 0xFF.
//     0x18 Sky Target  INPUT_PORTS_START(skytargt): IN0 Sega Rally's
//                 (coin, test, service, 0x20 View Change, 0x40 start); IN1
//                 0x10 Machine Gun = J 12, 0x20 Missile = J 13, the rest 1;
//                 IN2 0xFF; AN0 STICKY (0x80 + the left stick's Y), AN1
//                 0xFF, AN2 STICKX = 0xFF - Daytona's steering (PORT_REVERSE).
//     0x19-0x1B Manx TT / Motor Raid  INPUT_PORTS_START(manxtt): IN0 as
//                 Sky Target's (0x20 is unused there: its MRA names View
//                 "-"); IN1 0x10 Shift Up / Punch = J 12, 0x20 Shift Down /
//                 Kick = J 13; IN2 0xFF; AN0 THROTTLE = Daytona's
//                 accelerator, AN1 BRAKE = its brake, AN2 BANK = 0xFF -
//                 its steering.

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

// R879: a left analogue stick past 48 either way is a direction (VF2, Zero Gunner)
static uint32_t adir(uint16_t a) {
  int x = int8_t(a & 0xff), y = int8_t(a >> 8);
  return (x > 48 ? 1u : 0u) | (x < -48 ? 2u : 0u) | (y > 48 ? 4u : 0u) | (y < -48 ? 8u : 0u);
}
// the game index the bench switches between, and the ID it drives
enum { G_VF2, G_RALLY, G_VCOP2, G_ZG, G_DIG, G_SKY, G_BIKE, G_N };
static const char *GNAME[G_N] = {"VF2", "Sega Rally", "Virtua Cop 2", "Zero Gunner", "other digital",
                                 "Sky Target", "Manx TT / Motor Raid"};
static int game_id(int g) {
  static const int dig[] = {0x13, 0x14, 0x15, 0x16, 0x17, 0x01, 0x0f, 0x1c, 0x1f, 0x20, 0x7f};
  switch (g) {
    case G_VF2: return 0x00; case G_RALLY: return 0x10; case G_VCOP2: return 0x11; case G_ZG: return 0x12;
    case G_SKY: return 0x18; case G_BIKE: return 0x19 + rnd(3);
    default: return dig[rnd(int(sizeof dig / sizeof dig[0]))];
  }
}
static int sky_y(uint16_t la) { return (0x80 + int8_t(la >> 8)) & 0xff; }   // 0x80 + y
static Want want_now(int game) {
  uint32_t j0 = t->joystick_0, j1 = t->joystick_1;
  if (game == G_ZG || game == G_DIG || game == G_VF2) { j0 |= adir(t->joy_analog); j1 |= adir(t->joy_analog_1); }
  Want w;
  if (game == G_RALLY) {   // Sega Rally
    w.in0 = lo(b(j0, 4) << 0 | b(j0, 6) << 2 | b(j0, 7) << 3 | b(j0, 8) << 5 | b(j0, 5) << 6);
    w.in1 = 0x8f | (gearvalue[gear] << 4);
    w.in2 = b(j0, 9) ? 0xff : 0x00;
    w.an0 = t->c_steer; w.an1 = t->c_accel; w.an2 = t->c_brake;
  } else if (game == G_SKY || game == G_BIKE) {   // R887: Sky Target, the bikes
    w.in0 = lo(b(j0, 4) << 0 | b(j0, 6) << 2 | b(j0, 7) << 3 | b(j0, 8) << 5 | b(j0, 5) << 6);
    w.in1 = lo(b(j0, 12) << 4 | b(j0, 13) << 5);
    w.in2 = 0xff;
    w.an2 = 0xff - t->c_steer;
    if (game == G_SKY) { w.an0 = sky_y(t->joy_analog); w.an1 = 0xff; }
    else               { w.an0 = t->c_accel; w.an1 = t->c_brake; }
  } else if (game == G_VCOP2) {   // Virtua Cop 2
    w.in0 = lo(b(j0, 7) << 0 | b(j1, 7) << 1 | b(j0, 8) << 2 | b(j0, 9) << 3 | b(j0, 6) << 4 | b(j1, 6) << 5);
    w.in1 = lo(b(j0, 4) << 0 | b(j1, 4) << 1);
    w.in2 = 0xff; w.an0 = w.an1 = w.an2 = 0xff;
  } else {   // DIGITAL: model2's ports, the fixed order (VF2 also against the verbatim reference)
    w.in0 = lo(b(j0, 8) << 0 | b(j1, 8) << 1 | b(j0, 9) << 2 | b(j0, 10) << 3 | b(j0, 7) << 4 | b(j1, 7) << 5);
    auto pl = [&](uint32_t j) {   // model2: b1 b2 b3 b4 down up right left
      return lo(b(j, 4) << 0 | b(j, 5) << 1 | b(j, 6) << 2 | b(j, 2) << 4 | b(j, 3) << 5 | b(j, 0) << 6 | b(j, 1) << 7);
    };
    w.in1 = pl(j0); w.in2 = pl(j1); w.an0 = w.an1 = w.an2 = 0xff;
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

static uint64_t per_game[G_N] = {}, gear_moves = 0, gear_seen[5] = {0, 0, 0, 0, 0};

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
  t->clk = 0; t->rst_n = 0; t->game = 0;
  t->joystick_0 = 0; t->joystick_1 = 0; t->joy_analog = 0; t->joy_ranalog = 0; t->joy_analog_1 = 0; t->paddle = 0;
  t->st_pedswap = 0; t->st_ssens = 0; t->st_ssm = 0; t->st_rsteer = 0;
  for (int i = 0; i < 4; ++i) { t->clk = 1; t->eval(); t->clk = 0; t->eval(); }
  t->rst_n = 1; gear = 0;
  int game = 0;
  for (uint64_t c = 0; c < N; ++c) {
    if (rnd(100000) == 0) { game = rnd(G_N); t->game = game_id(game); }   // the MRA changes the game (quasi-static)
    if (rnd(24) == 0) t->joystick_0 ^= 1u << rnd(16);
    if (rnd(24) == 0) t->joystick_1 ^= 1u << rnd(16);
    if (rnd(2000) == 0) t->joy_analog = uint16_t(rng());
    if (rnd(2000) == 0) t->joy_ranalog = uint16_t(rng());
    if (rnd(2000) == 0) t->joy_analog_1 = uint16_t(rng());   // R879
    t->jr0 = t->joystick_0 | adir(t->joy_analog); t->jr1 = t->joystick_1 | adir(t->joy_analog_1);
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
    if (game == G_RALLY) ++gear_seen[g0];
    if (game == G_VF2) {
      cmp("in0", game, c, t->in0, t->r_in0);
      cmp("in1", game, c, t->in1, t->r_in1);
      cmp("in2", game, c, t->in2, t->r_in2);
    }
    {
      cmp("in0", game, c, t->in0, w.in0);
      cmp("in1", game, c, t->in1, w.in1);
      cmp("in2", game, c, t->in2, w.in2);
    }
    cmp("an0", game, c, t->an0, w.an0);
    cmp("an1", game, c, t->an1, w.an1);
    cmp("an2", game, c, t->an2, w.an2);
  }
  std::printf("  %llu cycles, %llu checks; per game:", (unsigned long long)N, (unsigned long long)checks);
  for (int g = 0; g < G_N; ++g) std::printf(" %s %llu%s", GNAME[g], (unsigned long long)per_game[g], g + 1 < G_N ? "," : "\n");
  std::printf("  shifter: %llu moves; Sega Rally cycles in N/1/2/3/4: %llu %llu %llu %llu %llu\n",
              (unsigned long long)gear_moves, (unsigned long long)gear_seen[0], (unsigned long long)gear_seen[1],
              (unsigned long long)gear_seen[2], (unsigned long long)gear_seen[3], (unsigned long long)gear_seen[4]);
  std::printf("  %llu mismatches\n%s\n", (unsigned long long)mism, mism ? "FAIL" : "PASS");
  delete t;
  return mism ? 1 : 0;
}
