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
//   Zero Gunner   INPUT_PORTS_START(zerogun) (J 4 Button 1 5 Button 2
//                 6 Start 7 Coin 8 Test 9 Service): IN1 / IN2 model2's with
//                 0x04 / 0x08 unused (1); AN 0xFF. (R887: also ID 0x15,
//                 Pilot Kids, whose ports are zerogun's.)
//   R887, the other IDs:
//     DIGITAL (0x13, 0x14, 0x16 and any ID not listed): model2's ports in
//                 VF2's order (J 4 B1 5 B2 6 B3 7 Start 8 Coin 9 Test
//                 10 Service; MAME's Punch / Kick / Jump, Hold / Punch /
//                 Kick on B1-B3), P2 on joystick 1; AN 0xFF.
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
//     R892  0x19 Manx TT with MOTION: IN2 is the motion base's status --
//                 0xCE while PE holds 0x3D, else 0xCD (the game's boot check,
//                 program 0x5f530). 0x1A / 0x1B keep 0xFF. The MOTION 0 build
//                 (dut_nm) is checked against the same wants with IN2 0xFF.
//     R928  0x1C Over Rev (OREV, 2C builds; dut_or): INPUT_PORTS_START(overrev)
//                 with its MRA's buttons (J 4 Coin 5 Start 6 Test 7 Service
//                 8 View 1 9 View 2 10 Accel 11 Brake 12 Shift Up 13 Shift
//                 Down): IN0 0x01 COIN1 0x04 TEST 0x08 SERVICE 0x40 START1,
//                 the rest 1; IN1 0x01 View 1 0x02 View 2 0x10 Shift Up 0x20
//                 Shift Down, the rest 1; IN2 0xFF; AN0 STEER, AN1 ACCEL, AN2
//                 BRAKE: Daytona's block's 0x20..0xE0 on MAME's full 0x00..0xFF
//                 -- checked as within 1.5 of the exact line (of any of the
//                 last 6 samples: one multiply serves the three in turn) (pedals
//                 (v - 0x20) * 255 / 192, steering 0x80 + (v - 0x80) * 127 / 96),
//                 the pedals then reversed (0xFF - x, PORT_REVERSE). The OREV 0
//                 builds (dut, dut_nm) must still read 0x1C as a digital ID.
//     R933  0x1D Sega Touring Car Championship (OREV, 2C builds; dut_or):
//                 INPUT_PORTS_START(indy500) -- Over Rev's above with the
//                 pedals NOT reversed ((v - 0x20) * 255 / 192: released 0x00).
//                 The OREV 0 builds read 0x1D as a digital ID too.

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
enum { G_VF2, G_RALLY, G_VCOP2, G_ZG, G_DIG, G_SKY, G_BIKE, G_MANX, G_OREV, G_STCC, G_N };
static const char *GNAME[G_N] = {"VF2", "Sega Rally", "Virtua Cop 2", "Zero Gunner / Pilot Kids", "other digital",
                                 "Sky Target", "Motor Raid (0x1A-0x1B)", "Manx TT (0x19)", "Over Rev (0x1C)",
                                 "STCC (0x1D)"};
static int game_id(int g) {
  static const int dig[] = {0x13, 0x14, 0x16, 0x17, 0x01, 0x0f, 0x1c, 0x1d, 0x1f, 0x20, 0x7f};
  switch (g) {
    case G_VF2: return 0x00; case G_RALLY: return 0x10; case G_VCOP2: return 0x11;
    case G_ZG: return rnd(2) ? 0x12 : 0x15;               // R887: Pilot Kids takes Zero Gunner's order
    case G_SKY: return 0x18; case G_BIKE: return 0x1a + rnd(2); case G_MANX: return 0x19;
    case G_OREV: return 0x1c;
    case G_STCC: return 0x1d;   // R933
    default: return dig[rnd(int(sizeof dig / sizeof dig[0]))];
  }
}
// R928: Over Rev's channels, the exact lines the RTL approximates
static double orev_ped(int v) { v = v < 0x20 ? 0x20 : v > 0xe0 ? 0xe0 : v; return 255.0 - (v - 0x20) * 255.0 / 192.0; }
static double stcc_ped(int v) { return 255.0 - orev_ped(v); }   // R933: indy500's, not reversed
static double orev_str(int v) { v = v < 0x20 ? 0x20 : v > 0xe0 ? 0xe0 : v; return 0x80 + (v - 0x80) * 127.0 / 96.0; }
static Want want_orev() {
  uint32_t j0 = t->joystick_0;
  Want w;
  w.in0 = lo(b(j0, 4) << 0 | b(j0, 6) << 2 | b(j0, 7) << 3 | b(j0, 5) << 6);
  w.in1 = lo(b(j0, 8) << 0 | b(j0, 9) << 1 | b(j0, 12) << 4 | b(j0, 13) << 5);
  w.in2 = 0xff; w.an0 = w.an1 = w.an2 = -1;   // the channels: near() below
  return w;
}
static uint64_t orev_near = 0, orev_ends[4] = {0, 0, 0, 0}, stcc_ends[4] = {0, 0, 0, 0};
// R928: the RTL takes the three channels in turn through one multiply, so an
// output may lag its input by up to 5 clocks: accept the line of any of the
// last 6 input samples (h[0] the newest)
static void near(const char *n, uint64_t cyc, int got, const double *h) {
  ++checks; ++orev_near;
  bool ok = false; double want = h[0];
  for (int k = 0; k < 6; ++k) if (got - h[k] <= 1.5 && h[k] - got <= 1.5) ok = true;
  if (!ok && mism++ < 25)
    std::printf("  MISMATCH Over Rev cyc %llu %s: dut %02x want %.2f\n", (unsigned long long)cyc, n, got, want);
}
static int sky_y(uint16_t la) { return (0x80 + int8_t(la >> 8)) & 0xff; }   // 0x80 + y
static Want want_now(int game, bool motion) {
  uint32_t j0 = t->joystick_0, j1 = t->joystick_1;
  if (game == G_OREV || game == G_STCC) game = G_DIG;   // R928 / R933: an OREV 0 build reads 0x1C / 0x1D as digital
  if (game == G_ZG || game == G_DIG || game == G_VF2) { j0 |= adir(t->joy_analog); j1 |= adir(t->joy_analog_1); }
  Want w;
  if (game == G_RALLY) {   // Sega Rally
    w.in0 = lo(b(j0, 4) << 0 | b(j0, 6) << 2 | b(j0, 7) << 3 | b(j0, 8) << 5 | b(j0, 5) << 6);
    w.in1 = 0x8f | (gearvalue[gear] << 4);
    w.in2 = b(j0, 9) ? 0xff : 0x00;
    w.an0 = t->c_steer; w.an1 = t->c_accel; w.an2 = t->c_brake;
  } else if (game == G_SKY || game == G_BIKE || game == G_MANX) {   // R887: Sky Target, the bikes
    w.in0 = lo(b(j0, 4) << 0 | b(j0, 6) << 2 | b(j0, 7) << 3 | b(j0, 8) << 5 | b(j0, 5) << 6);
    w.in1 = lo(b(j0, 12) << 4 | b(j0, 13) << 5);
    w.in2 = (game == G_MANX && motion) ? (t->pe == 0x3d ? 0xce : 0xcd) : 0xff;   // R892
    w.an2 = 0xff - t->c_steer;
    if (game == G_SKY) { w.an0 = sky_y(t->joy_analog); w.an1 = 0xff; }
    else               { w.an0 = t->c_accel; w.an1 = t->c_brake; }
  } else if (game == G_ZG) {   // Zero Gunner (and R887: Pilot Kids, the same order) -- cdd58a7's model, verbatim
    w.in0 = lo(b(j0, 7) << 0 | b(j1, 7) << 1 | b(j0, 8) << 2 | b(j0, 9) << 3 | b(j0, 6) << 4 | b(j1, 6) << 5);
    auto pl = [&](uint32_t j) {   // model2: b1 b2 b3 b4 down up right left
      return lo(b(j, 4) << 0 | b(j, 5) << 1 | b(j, 2) << 4 | b(j, 3) << 5 | b(j, 0) << 6 | b(j, 1) << 7);
    };
    w.in1 = pl(j0); w.in2 = pl(j1); w.an0 = w.an1 = w.an2 = 0xff;
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
static uint64_t manx_ce = 0, manx_cd = 0;   // R892: Manx TT cycles answered 0xCE / 0xCD

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
  t->st_pedswap = 0; t->st_ssens = 0; t->st_ssm = 0; t->st_rsteer = 0; t->pe = 0xff;
  for (int i = 0; i < 4; ++i) { t->clk = 1; t->eval(); t->clk = 0; t->eval(); }
  t->rst_n = 1; gear = 0;
  int game = 0;
  for (uint64_t c = 0; c < N; ++c) {
    static uint64_t since = 0;   // R933: clocks since the ID changed (the channels settle in three)
    ++since;
    if (rnd(100000) == 0) { game = rnd(G_N); if (t->game != game_id(game)) since = 0; t->game = game_id(game); }   // the MRA changes the game (quasi-static)
    if (rnd(24) == 0) t->joystick_0 ^= 1u << rnd(16);
    if (rnd(24) == 0) t->joystick_1 ^= 1u << rnd(16);
    if (rnd(2000) == 0) t->joy_analog = uint16_t(rng());
    if (rnd(2000) == 0) t->joy_ranalog = uint16_t(rng());
    if (rnd(2000) == 0) t->joy_analog_1 = uint16_t(rng());   // R879
    t->jr0 = t->joystick_0 | adir(t->joy_analog); t->jr1 = t->joystick_1 | adir(t->joy_analog_1);
    if (rnd(3000) == 0) t->paddle = (rnd(3) == 0) ? uint8_t(rng()) : 0;
    if (rnd(20000) == 0) { t->st_pedswap = rnd(2); t->st_ssens = rnd(4); t->st_ssm = rnd(4); t->st_rsteer = rnd(2); }
    if (rnd(64) == 0)   // R892: PE, the game's motion command -- 0x3D a third of the time, its neighbours often
      t->pe = rnd(3) == 0 ? 0x3d : rnd(3) == 0 ? (0x3d ^ (1 << rnd(8))) : uint8_t(rng());
    if (rnd(500000) == 0) t->rst_n = 0; else if (!t->rst_n && rnd(8) == 0) t->rst_n = 1;
    if (!t->rst_n) { gear = 0; gup_d = 0; gdn_d = 0; }   // asynchronous in the RTL
    t->eval();
    Want w = want_now(game, true), wn = want_now(game, false);
    Want o = want_orev();   // R928: before the edge, as the others (the outputs are registered)
    static double hs[6], ha[6], hb[6], sa[6], sb[6];
    for (int k = 5; k > 0; --k) { hs[k] = hs[k - 1]; ha[k] = ha[k - 1]; hb[k] = hb[k - 1]; sa[k] = sa[k - 1]; sb[k] = sb[k - 1]; }
    hs[0] = orev_str(t->c_steer); ha[0] = orev_ped(t->c_accel); hb[0] = orev_ped(t->c_brake);
    sa[0] = stcc_ped(t->c_accel); sb[0] = stcc_ped(t->c_brake);   // R933
    if (game == G_MANX) { if (w.in2 == 0xce) ++manx_ce; else ++manx_cd; }
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
    // R892: the build without MOTION
    cmp("nm in0", game, c, t->n_in0, wn.in0);
    cmp("nm in1", game, c, t->n_in1, wn.in1);
    cmp("nm in2", game, c, t->n_in2, wn.in2);
    cmp("nm an0", game, c, t->n_an0, wn.an0);
    cmp("nm an1", game, c, t->n_an1, wn.an1);
    cmp("nm an2", game, c, t->n_an2, wn.an2);
    // R928: the OREV build -- Over Rev on 0x1C, every other ID as dut
    if (t->game == 0x1c || t->game == 0x1d) {   // G_OREV / G_STCC, or G_DIG's draw of 0x1C / 0x1D
      const bool st = (t->game == 0x1d);          // R933: STCC, the pedals not reversed
      cmp("or in0", game, c, t->o_in0, o.in0);
      cmp("or in1", game, c, t->o_in1, o.in1);
      cmp("or in2", game, c, t->o_in2, o.in2);
      if (since > 6) {   // R933: a pedal registered under 0x1C's sense may stand for three clocks after 0x1D
        near("or an0", c, t->o_an0, hs);
        near(st ? "st an1" : "or an1", c, t->o_an1, st ? sa : ha);
        near(st ? "st an2" : "or an2", c, t->o_an2, st ? sb : hb);
      }
      uint64_t *e = st ? stcc_ends : orev_ends;
      if (t->o_an1 == 0x00) ++e[0];
      if (t->o_an1 == 0xff) ++e[1];
      if (t->o_an0 <= 0x01) ++e[2];
      if (t->o_an0 == 0xff) ++e[3];
    } else {
      cmp("or in0", game, c, t->o_in0, w.in0);
      cmp("or in1", game, c, t->o_in1, w.in1);
      cmp("or in2", game, c, t->o_in2, w.in2);
      cmp("or an0", game, c, t->o_an0, w.an0);
      cmp("or an1", game, c, t->o_an1, w.an1);
      cmp("or an2", game, c, t->o_an2, w.an2);
    }
  }
  std::printf("  %llu cycles, %llu checks; per game:", (unsigned long long)N, (unsigned long long)checks);
  for (int g = 0; g < G_N; ++g) std::printf(" %s %llu%s", GNAME[g], (unsigned long long)per_game[g], g + 1 < G_N ? "," : "\n");
  std::printf("  shifter: %llu moves; Sega Rally cycles in N/1/2/3/4: %llu %llu %llu %llu %llu\n",
              (unsigned long long)gear_moves, (unsigned long long)gear_seen[0], (unsigned long long)gear_seen[1],
              (unsigned long long)gear_seen[2], (unsigned long long)gear_seen[3], (unsigned long long)gear_seen[4]);
  std::printf("  Manx TT's motion base (R892): %llu cycles answered 0xCE, %llu 0xCD\n",
              (unsigned long long)manx_ce, (unsigned long long)manx_cd);
  std::printf("  Over Rev (R928): %llu channel checks; accel 0x00 %llu / 0xFF %llu cycles, steering <= 0x01 %llu / 0xFF %llu\n",
              (unsigned long long)orev_near, (unsigned long long)orev_ends[0], (unsigned long long)orev_ends[1],
              (unsigned long long)orev_ends[2], (unsigned long long)orev_ends[3]);
  std::printf("  STCC (R933): accel 0x00 %llu / 0xFF %llu cycles, steering <= 0x01 %llu / 0xFF %llu\n",
              (unsigned long long)stcc_ends[0], (unsigned long long)stcc_ends[1],
              (unsigned long long)stcc_ends[2], (unsigned long long)stcc_ends[3]);
  std::printf("  %llu mismatches\n%s\n", (unsigned long long)mism, mism ? "FAIL" : "PASS");
  delete t;
  return mism ? 1 : 0;
}
