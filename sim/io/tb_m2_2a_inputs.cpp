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
//     R1010 (C2G, 2C builds; dut_or), MAME 0.289's ports:
//       0x1E Wave Runner INPUT_PORTS_START(waverunr) (J 4 Coin 5 Start
//                 6 Test 7 Service 8 View 10 Throttle): IN0 0x01 COIN1 0x04
//                 TEST 0x08 SERVICE 0x40 START1, the rest 1; IN1 0x01 View;
//                 IN2 0xF7; AN0 HANDLE = AN1 ROLL = Over Rev's steering line;
//                 AN2 THROTTLE = STCC's pedal line (released 0x00); AN3 PITCH
//                 = 0xFF - (0x80 + the left stick's Y) (AD_STICK_Y, REVERSE).
//       0x1F Sega Water Ski INPUT_PORTS_START(segawski) (J 4 Coin 5 Select
//                 Down 6 Test 7 Service 8 Set 9 Select Up 10 Pitch Left
//                 11 Pitch Right): IN0 as Wave Runner's; IN1 0x01 Set 0x02
//                 Select Up 0x04 Pitch Left 0x08 Pitch Right; IN2 0xFF; AN0
//                 SLIDE = the steering line; AN1-AN3 0xFF.
//       0x20 Behind Enemy Lines INPUT_PORTS_START(bel) (gunblade's; J 4
//                 Trigger 5 Missile 6 Start 7 Coin 8 Test 9 Service, P2 on
//                 joystick 1): IN0 0x01/0x02 coins 0x04 SERVICE 0x08 TEST
//                 0x10/0x20 starts; IN1 0x01/0x02 triggers 0x10/0x20
//                 missiles; IN2 0xFF; AN0 P1_X 0x69..0xFF, AN1 P2_X
//                 0x00..0x96, AN2 P1_Y 0x11..0xAE, AN3 P2_Y 0x11..0xAE.
//                 R1016: through m2_vcop_guns (V2, HD, as the 2C build): the
//                 reference pixel is the stick's, px = (a ^ 0x80) * 496 >> 8,
//                 py = (a ^ 0x80) * 384 >> 8 (R846), or the mouse's -- the
//                 bench's own accumulator of the packets it sends, 1:1,
//                 clamped 0..495 / 0..383, for the gun the OSD's Mouse line
//                 gives it (1: gun 1 aims, 3: gun 2). X = min + px * 78 >> 8,
//                 Y = 0xAE - py * 211 >> 9 (UP HIGH: the game's calibration
//                 takes the lower stop low), exact, of any of the last 12
//                 reference samples (the guns' two registers, four channels
//                 in turn through one multiply); AND, independently of those
//                 constants, within 1 unit of the straight line from pixel 0
//                 to pixel 494 (min .. max), never outside MAME's
//                 PORT_MINMAX, every end reached. IN1: the mouse's left /
//                 right buttons OR'd into the trigger / missile of gun 1 (or
//                 gun 2 when the Mouse line's bit 1 is set).
//       0x21 Sega Ski Super G INPUT_PORTS_START(skisuprg) (J 4 Coin 5 Select 1
//                 6 Test 7 Service 8 Select 2 9 Select 3 10 Zoom In 11 Zoom
//                 Out 12 Foot L 13 Foot R): IN0 0x01 COIN1 0x04 TEST 0x08
//                 SERVICE 0x10 Select 3 0x20 Zoom In 0x40 Select 1 0x80 Select
//                 2; IN1 0x01 Zoom Out; IN2 ACTIVE HIGH 0xF0 foot L 0x0F foot
//                 R; AN0 SWING = 0x80 + the left stick's Y; AN1 INCLINING =
//                 the steering line; AN2 0xFF.
//       0x22 Top Skater INPUT_PORTS_START(topskatr) (J 4 Coin 5 Start 6 Test
//                 7 Service 8 Jump Front 9 Jump Tail 10 Select Left 11 Select
//                 Right): IN0 0x10 Select Right 0x20 Jump Front 0x40 START1
//                 0x80 Select Left; IN1 0x01 Jump Tail; IN2 0xFF; AN0 CURVING =
//                 AN1 SLIDE = the steering line.
//       0x23 / 0x24 (Dynamite Cop 2C, Royal Ascot II): DIGITAL in every build.
//       The C2G 0 builds (dut, dut_nm) read all of them as digital IDs; an3 is
//       0xFF on every other ID and build.

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
enum { G_VF2, G_RALLY, G_VCOP2, G_ZG, G_DIG, G_SKY, G_BIKE, G_MANX, G_OREV, G_STCC, G_WAVE, G_WSKI, G_BEL, G_SKIS, G_TOPS, G_N };
static const char *GNAME[G_N] = {"VF2", "Sega Rally", "Virtua Cop 2", "Zero Gunner / Pilot Kids", "other digital",
                                 "Sky Target", "Motor Raid (0x1A-0x1B)", "Manx TT (0x19)", "Over Rev (0x1C)",
                                 "STCC (0x1D)", "Wave Runner (0x1E)", "Water Ski (0x1F)", "Behind Enemy Lines (0x20)", "Ski Super G (0x21)", "Top Skater (0x22)"};
static int game_id(int g) {
  static const int dig[] = {0x13, 0x14, 0x16, 0x17, 0x01, 0x0f, 0x1c, 0x1d, 0x1f, 0x20, 0x23, 0x24, 0x7f,
                            0x25, 0x26, 0x27, 0x28, 0x29, 0x29, 0x25, 0x26, 0x27,    // R1037: the 2B IDs, digital on every non-B2G copy
                            0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2d, 0x28, 0x2d, 0x28};   // R1046: and the rest of the 2B sets
  switch (g) {
    case G_VF2: return 0x00; case G_RALLY: return 0x10; case G_VCOP2: return 0x11;
    case G_ZG: return rnd(2) ? 0x12 : 0x15;               // R887: Pilot Kids takes Zero Gunner's order
    case G_SKY: return 0x18; case G_BIKE: return 0x1a + rnd(2); case G_MANX: return 0x19;
    case G_OREV: return 0x1c;
    case G_STCC: return 0x1d;   // R933
    case G_WAVE: return 0x1e; case G_WSKI: return 0x1f; case G_BEL: return 0x20;   // R1010
    case G_SKIS: return 0x21; case G_TOPS: return 0x22;
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
// R1010 / R1016: Behind Enemy Lines' axes from a reference pixel (ch 0 P1_X,
// 1 P2_X, 2 P1_Y, 3 P2_Y); Y up-high
static const int BEL_MIN[4] = {0x69, 0x00, 0x11, 0x11}, BEL_MAX[4] = {0xff, 0x96, 0xae, 0xae};
static int bel_axis(int ch, int p) {
  return ch < 2 ? BEL_MIN[ch] + (p * 78) / 256 : BEL_MAX[ch] - (p * 211) / 512;
}
// the straight line, from nothing the RTL shares: pixel 0 the X minimum / the
// Y maximum (top), a stick's +127 (px 494, py 382) and beyond the other end
static double bel_line(int ch, int p) {
  const int e = ch < 2 ? 494 : 382;
  double f = p >= e ? 1.0 : double(p) / e;
  return ch < 2 ? BEL_MIN[ch] + f * (BEL_MAX[ch] - BEL_MIN[ch]) : BEL_MAX[ch] - f * (BEL_MAX[ch] - BEL_MIN[ch]);
}
static int stick_px(int a) { return ((a ^ 0x80) & 0xff) * 496 / 256; }   // R846: u * 496 / 256
static int stick_py(int a) { return ((a ^ 0x80) & 0xff) * 384 / 256; }
static int ms_x = 248, ms_y = 192, ms_tgl = 0;   // R1016: the bench's mouse, m2_vcop_guns' rest
static uint32_t ms_prev = 0;                     // the word the driver has registered
static double bel_dev = 0.0;
static uint64_t bel_mouse_cyc = 0, bel_mouse_ends[4][2] = {}, bel_btn_cyc = 0, ms_packets = 0;
static uint64_t bel_ends[4][3] = {}, c2g_checks = 0, wave_pitch_ends[2] = {0, 0}, wave_thr_ends[2] = {0, 0}, wski_sl_ends[2] = {0, 0};
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
  if (game == G_OREV || game == G_STCC || game >= G_WAVE) game = G_DIG;   // R1010: and the C2G IDs   // R928 / R933: an OREV 0 build reads 0x1C / 0x1D as digital
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
    if (game == G_SKY) { w.an0 = sky_y(t->joy_analog); w.an1 = 0xff; w.an2 = 0xff - t->c0_steer; }   // R958: Standard always
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
// R1037: THE 2B GAMES (dut_b2), from MAME 0.289's INPUT_PORTS and machine
// configs: gunblade (rchase2's IN0 / IN1; AN0 P1_X AN1 P2_X AN2 P1_Y AN3
// P2_Y), rchase2 (AN0 P2_X AN1 P1_X AN2 P2_Y AN3 P1_Y, all PORT_REVERSE; PD
// rchase2_drive_board_r of the last PE write). A stick is 0x80 + s.
static const uint8_t RC2_CMD[8] = {0xe0, 0x0e, 0xd0, 0x0d, 0xb0, 0x0b, 0x70, 0x07};
static uint64_t b2_checks = 0, b2_pd_low[4] = {0, 0, 0, 0}, b2_seen[2] = {0, 0};
static int rc2_pd(int cmd) {   // MAME's rchase2_drive_board_r, verbatim
  int d = 0xff;
  if (cmd == 0xe0 || cmd == 0x0e) d &= ~1;
  if (cmd == 0xd0 || cmd == 0x0d) d &= ~2;
  if (cmd == 0xb0 || cmd == 0x0b) d &= ~4;
  if (cmd == 0x70 || cmd == 0x07) d &= ~8;
  return d;
}
struct W4 { int in0, in1, in2, an[4]; };
static W4 want_b2g(int id) {
  uint32_t j0 = t->joystick_0, j1 = t->joystick_1;
  W4 w;
  w.in0 = lo(b(j0, 7) << 0 | b(j1, 7) << 1 | b(j0, 8) << 2 | b(j0, 9) << 3 | b(j0, 6) << 4 | b(j1, 6) << 5);
  w.in1 = lo(b(j0, 4) << 0 | b(j1, 4) << 1);
  const int x1 = (0x80 + int8_t(t->joy_analog & 0xff)) & 0xff, y1 = (0x80 + int8_t(t->joy_analog >> 8)) & 0xff;
  const int x2 = (0x80 + int8_t(t->joy_analog_1 & 0xff)) & 0xff, y2 = (0x80 + int8_t(t->joy_analog_1 >> 8)) & 0xff;
  if (id == 0x25) { w.in2 = 0xff; w.an[0] = x1; w.an[1] = x2; w.an[2] = y1; w.an[3] = y2; }
  else { w.in2 = rc2_pd(t->pe); w.an[0] = 0xff - x2; w.an[1] = 0xff - x1; w.an[2] = 0xff - y2; w.an[3] = 0xff - y1; }
  return w;
}
// R1046: Dynamite Baseball (dynabb: model2's IN0, IN1 / IN2 with 0x0c unused,
// AN0 BAT1 / AN1 BAT2 -- 0xFF while J6 is held, else 0x00, player 1's
// trigger the partial swing) and Virtual-On (von: both levers and four
// buttons on player 1 -- IN2 from joystick 1, or player 1's right stick and
// J6 / J11), written from MAME 0.289's ports, not from the RTL
static uint64_t b2n_seen[3] = {0, 0, 0}, dybb_bat[2][2] = {{0, 0}, {0, 0}}, von_r[2] = {0, 0};
static W4 want_b2n(int id) {
  uint32_t j0 = t->joystick_0 | adir(t->joy_analog), j1 = t->joystick_1 | adir(t->joy_analog_1);
  W4 w;
  w.in0 = lo(b(j0, 8) << 0 | b(j1, 8) << 1 | b(j0, 9) << 2 | b(j0, 10) << 3 | b(j0, 7) << 4 | b(j1, 7) << 5);
  auto dirs = [&](uint32_t j) { return b(j, 2) << 4 | b(j, 3) << 5 | b(j, 0) << 6 | b(j, 1) << 7; };
  w.an[0] = w.an[1] = w.an[2] = w.an[3] = 0xff;
  if (id == 0x2d) {
    w.in1 = lo(b(j0, 4) << 0 | b(j0, 5) << 1 | dirs(j0));
    w.in2 = lo(b(j1, 4) << 0 | b(j1, 5) << 1 | dirs(j1));
    w.an[0] = b(j0, 6) ? 0xff : t->trig_rt;
    w.an[1] = b(j1, 6) ? 0xff : 0x00;
  } else {   // 0x28
    const uint32_t r = j1 | adir(t->joy_ranalog);
    w.in1 = lo(b(j0, 4) << 0 | b(j0, 5) << 1 | dirs(j0));
    w.in2 = lo((b(j1, 4) | b(t->joystick_0, 6)) << 0 | (b(j1, 5) | b(t->joystick_0, 11)) << 1 | dirs(r));
  }
  return w;
}
static uint64_t manx_ce = 0, manx_cd = 0;   // R892: Manx TT cycles answered 0xCE / 0xCD
static uint64_t per_game_wheel[G_N] = {}, sky_wdiff = 0, sky_skip = 0;   // R958

static void cmp(const char *n, int game, uint64_t cyc, int got, int want) {
  ++checks;
  if (got != want && mism++ < 25)
    std::printf("  MISMATCH game %d cyc %llu %s: dut %02x want %02x\n", game, (unsigned long long)cyc, n, got, want);
}

// R1016: Behind Enemy Lines exhaustively, before the random run: every stick
// byte on all four channels (P1 and P2, X and Y, each a different permutation
// so no two channels carry the same value), then the mouse for gun 1 and
// gun 2 over every pixel it can reach -- one-pixel steps right and down, one
// up and left, and throws of +-255 far past each edge -- each value held 16
// clocks and the last checked exactly; buttons each way round.
static uint64_t sw_checks = 0, sw_mism = 0, sw_seen[4][256];
static void tick() { t->clk = 1; t->eval(); t->clk = 0; t->eval(); }
static void sw_cmp(const char *n, int got, int want, int px) {
  ++sw_checks; ++checks;
  if (got != want && mism++ < 25) std::printf("  SWEEP MISMATCH %s: dut %02x want %02x (pixel %d)\n", n, got, want, px);
  if (got != want) ++sw_mism;
}
static void sw_check(int p1x, int p2x, int p1y, int p2y) {
  for (int k = 0; k < 16; ++k) tick();
  const int got[4] = {t->o_an0, t->o_an1, t->o_an2, t->o_an3}, px[4] = {p1x, p2x, p1y, p2y};
  static const char *nm[4] = {"P1_X", "P2_X", "P1_Y", "P2_Y"};
  for (int ch = 0; ch < 4; ++ch) { sw_cmp(nm[ch], got[ch], bel_axis(ch, px[ch]), px[ch]); ++sw_seen[ch][got[ch] & 0xff]; }
}
static void sw_packet(int dx, int dy, int btn) {
  uint32_t m = t->ps2_mouse ^ (1u << 24);
  t->ps2_mouse = (m & (1u << 24)) | (uint32_t(dy & 0xff) << 16) | (uint32_t(dx & 0xff) << 8)
               | (dy < 0 ? 0x20u : 0u) | (dx < 0 ? 0x10u : 0u) | 0x08u | uint32_t(btn);
  ms_x += dx; ms_y -= dy; ms_tgl ^= 1;
  ms_x = ms_x < 0 ? 0 : ms_x > 495 ? 495 : ms_x;
  ms_y = ms_y < 0 ? 0 : ms_y > 383 ? 383 : ms_y;
  tick(); tick();   // the guns' driver takes one packet per toggle it sees
}
static void bel_sweep() {
  t->game = 0x20; t->mouse_sel = 0; t->joystick_0 = 0; t->joystick_1 = 0;
  for (int i = 0; i < 64; ++i) tick();
  for (int a = 0; a < 256; ++a) {   // the sticks: a, and three permutations of it
    const int x1 = a, x2 = (a * 37 + 11) & 0xff, y1 = (a * 101 + 200) & 0xff, y2 = 255 - a;
    t->joy_analog = uint16_t(y1 << 8 | x1); t->joy_analog_1 = uint16_t(y2 << 8 | x2);
    sw_check(stick_px(x1), stick_px(x2), stick_py(y1), stick_py(y2));
  }
  t->joy_analog = 0; t->joy_analog_1 = 0;
  for (int g = 0; g < 2; ++g) {     // the mouse aiming gun 1, then gun 2 (the other gun on its centred stick)
    t->mouse_sel = g ? 3 : 1;
    for (int i = 0; i < 4; ++i) sw_packet(-255, 255, 0);   // to the top-left corner
    for (int i = 0; i < 16; ++i) tick();
    auto chk = [&]() {
      if (g) sw_check(248, ms_x, 192, ms_y); else sw_check(ms_x, 248, ms_y, 192);
    };
    chk();
    for (int x = 0; x < 500; ++x) { sw_packet(1, 0, 0); chk(); }     // right, one pixel at a time, past the edge
    for (int y = 0; y < 390; ++y) { sw_packet(0, -1, 0); chk(); }    // down
    for (int x = 0; x < 500; ++x) { sw_packet(-1, 0, 0); chk(); }    // left
    for (int y = 0; y < 390; ++y) { sw_packet(0, 1, 0); chk(); }     // up
    for (int i = 0; i < 64; ++i) { sw_packet(rnd(2) ? 255 : -255, rnd(2) ? 255 : -255, 0); chk(); }   // throws past the edges
    for (int btn = 0; btn < 4; ++btn) {   // the buttons: this gun's trigger / missile, the other gun's untouched
      sw_packet(0, 0, btn); for (int i = 0; i < 16; ++i) tick();
      const int l = btn & 1, r = btn >> 1;
      sw_cmp("in1 (mouse)", t->o_in1, lo((g ? l << 1 : l) | (g ? r << 5 : r << 4)), btn);
    }
    sw_packet(0, 0, 0);
  }
  t->mouse_sel = 0;
  for (int i = 0; i < 16; ++i) tick();
  ms_prev = t->ps2_mouse;
  int ends = 0, vals[4] = {0, 0, 0, 0};
  for (int ch = 0; ch < 4; ++ch) {
    for (int v = 0; v < 256; ++v) if (sw_seen[ch][v]) ++vals[ch];
    ends += sw_seen[ch][BEL_MIN[ch]] > 0 && sw_seen[ch][BEL_MAX[ch]] > 0;
  }
  std::printf("  R1016 sweep: %llu exact checks, %llu mismatches; distinct values P1_X %d P2_X %d P1_Y %d P2_Y %d (of 151 151 158 158); both ends on %d of 4 channels\n",
              (unsigned long long)sw_checks, (unsigned long long)sw_mism, vals[0], vals[1], vals[2], vals[3], ends);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  uint64_t N = 20000000;
  for (int i = 1; i < argc; ++i) if (!std::strncmp(argv[i], "+n=", 3)) N = std::strtoull(argv[i] + 3, nullptr, 10);
  t = new Vtb_m2_2a_inputs_top;
  t->clk = 0; t->rst_n = 0; t->game = 0;
  t->joystick_0 = 0; t->joystick_1 = 0; t->joy_analog = 0; t->joy_ranalog = 0; t->joy_analog_1 = 0; t->paddle = 0;
  t->st_pedswap = 0; t->st_ssens = 0; t->st_ssm = 0; t->st_rsteer = 0; t->st_wheel = 0; t->pe = 0xff;
  t->ps2_mouse = 0; t->mouse_sel = 0;   // R1016
  for (int i = 0; i < 4; ++i) { t->clk = 1; t->eval(); t->clk = 0; t->eval(); }
  t->rst_n = 1; gear = 0;
  bel_sweep();   // R1016
  t->game = 0;
  int game = 0;
  for (uint64_t c = 0; c < N; ++c) {
    static uint64_t since = 0;   // R933: clocks since the ID changed (the channels settle in three)
    ++since;
    static int sky_sw = 0;       // R958: clocks left in a switch to or from Sky Target
    if (sky_sw) --sky_sw;
    if (rnd(100000) == 0) {
      int g2 = rnd(G_N);
      // R958: Sky Target forces Standard inside the block, so a switch to or
      // from it changes the block's mode under it: the steering limiter's
      // history differs from the bench's reference block's. A real switch is
      // an MRA load, which holds the game in reset while the mode settles --
      // the bench holds it 8 clocks and skips the analog channels for them.
      if ((g2 == G_SKY) != (game == G_SKY)) sky_sw = 8;
      game = g2;
      if (t->game != game_id(game)) since = 0;
      t->game = game_id(game);   // the MRA changes the game (quasi-static)
    }
    if (rnd(24) == 0) t->joystick_0 ^= 1u << rnd(16);
    if (rnd(24) == 0) t->joystick_1 ^= 1u << rnd(16);
    if (rnd(2000) == 0) t->joy_analog = uint16_t(rng());
    if (rnd(2000) == 0) t->joy_ranalog = uint16_t(rng());
    if (rnd(2000) == 0) t->joy_analog_1 = uint16_t(rng());   // R879
    t->jr0 = t->joystick_0 | adir(t->joy_analog); t->jr1 = t->joystick_1 | adir(t->joy_analog_1);
    if (rnd(3000) == 0) t->paddle = (rnd(3) == 0) ? uint8_t(rng()) : 0;
    if (rnd(2500) == 0) { t->trig_rt = (rnd(3) == 0) ? 0 : uint8_t(rng()); t->trig_lt = (rnd(3) == 0) ? 0 : uint8_t(rng()); }   // R981
    if (rnd(20000) == 0) { t->st_pedswap = rnd(2); t->st_ssens = rnd(4); t->st_ssm = rnd(4); t->st_rsteer = rnd(2); t->st_wheel = rnd(4); }
    if (rnd(64) == 0)   // R892: PE, the game's motion command -- 0x3D a third of the time, its neighbours often
      t->pe = rnd(3) == 0 ? 0x3d : rnd(3) == 0 ? (0x3d ^ (1 << rnd(8)))
            : rnd(2) == 0 ? RC2_CMD[rnd(8)] ^ (rnd(4) == 0 ? (1 << rnd(8)) : 0) : uint8_t(rng());   // R1037: Rail Chase 2's commands
    // R1016: the mouse -- a packet now and then: moves of every size (beyond the
    // screen many times over), the buttons; the OSD's Mouse line now and then
    if (rnd(300) == 0) {
      int dx = rnd(4) == 0 ? rnd(511) - 255 : rnd(31) - 15, dy = rnd(4) == 0 ? rnd(511) - 255 : rnd(31) - 15;
      uint32_t m = t->ps2_mouse ^ (1u << 24);
      m = (m & (1u << 24)) | (uint32_t(dy & 0xff) << 16) | (uint32_t(dx & 0xff) << 8)
        | (dy < 0 ? 0x20u : 0u) | (dx < 0 ? 0x10u : 0u) | 0x08u | uint32_t(rnd(8));
      t->ps2_mouse = m; ++ms_packets;
    }
    if (rnd(150000) == 0) t->mouse_sel = rnd(4);
    if (rnd(500000) == 0) t->rst_n = 0; else if (!t->rst_n && rnd(8) == 0) t->rst_n = 1;
    if (sky_sw) t->rst_n = 0;   // R958
    if (!t->rst_n) { gear = 0; gup_d = 0; gdn_d = 0; }   // asynchronous in the RTL
    t->eval();
    Want w = want_now(game, true), wn = want_now(game, false);
    const int ms_btn_pre = int(t->ps2_mouse & 3), msel_pre = int(t->mouse_sel);   // R1016
    static uint64_t rst_ok = 0;   // R1016: clocks since a reset (the guns' pixels restart)
    rst_ok = t->rst_n ? rst_ok + 1 : 0;
    Want o = want_orev();   // R928: before the edge, as the others (the outputs are registered)
    const W4 wb = want_b2g(t->game);   // R1037
    const W4 wn2 = want_b2n(t->game);  // R1046
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
    if (t->st_wheel == 1 || t->st_wheel == 2) ++per_game_wheel[game];   // R958
    if (game == G_SKY && t->st_wheel && t->c_steer != t->c0_steer) ++sky_wdiff;
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
    if (sky_sw && (w.an0 != t->an0 || w.an1 != t->an1 || w.an2 != t->an2)) ++sky_skip;   // R958: the switch's reset
    if (sky_sw) { w.an0 = t->an0; w.an1 = t->an1; w.an2 = t->an2; wn.an0 = t->n_an0; wn.an1 = t->n_an1; wn.an2 = t->n_an2; }
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
    // R1010: the 2C-only C2G build's new IDs (dut_or); C2G 0 builds as digital above; an3 0xFF on those
    cmp("an3", game, c, t->an3, 0xff);
    cmp("nm an3", game, c, t->n_an3, 0xff);
    // R1016: the reference pixel per channel. The mouse as m2_vcop_guns'
    // spec says: a packet (a toggle of bit 24 since the last one taken) moves
    // it 1:1, Y up-positive, clamped to the screen; reset puts it at 248, 192
    // and forgets the toggle. Sampled after the edge (the RTL's registers
    // stand a clock or two behind; the history absorbs them).
    // The packet is taken a clock after it arrives (the driver registers the
    // word first): the model does the same, so a Mouse-line change in the
    // packet's clock sees the position before it, as the RTL does.
    if (!t->rst_n) { ms_x = 248; ms_y = 192; ms_tgl = 0; }
    else if (int((ms_prev >> 24) & 1) != ms_tgl) {
      ms_tgl ^= 1;
      int dx = int((ms_prev >> 8) & 0xff) - ((ms_prev & 0x10) ? 256 : 0);
      int dy = int((ms_prev >> 16) & 0xff) - ((ms_prev & 0x20) ? 256 : 0);
      ms_x += dx; ms_y -= dy;
      ms_x = ms_x < 0 ? 0 : ms_x > 495 ? 495 : ms_x;
      ms_y = ms_y < 0 ? 0 : ms_y > 383 ? 383 : ms_y;
    }
    ms_prev = t->ps2_mouse;
    const bool m1 = (t->mouse_sel == 1), m2 = (t->mouse_sel == 3);
    static int bh[4][12];   // R1010 / R1016: bel's reference pixel history per channel (newest [0])
    for (int ch = 0; ch < 4; ++ch) { for (int k = 11; k > 0; --k) bh[ch][k] = bh[ch][k - 1]; }
    bh[0][0] = m1 ? ms_x : stick_px(t->joy_analog & 0xff);
    bh[1][0] = m2 ? ms_x : stick_px(t->joy_analog_1 & 0xff);
    bh[2][0] = m1 ? ms_y : stick_py(t->joy_analog >> 8);
    bh[3][0] = m2 ? ms_y : stick_py(t->joy_analog_1 >> 8);
    if (t->game == 0x21 || t->game == 0x22) {   // R1010: Ski Super G, Top Skater
      uint32_t j0 = t->joystick_0;
      ++c2g_checks;
      if (t->game == 0x21) {
        cmp("skis in0", game, c, t->o_in0, lo(b(j0, 4) << 0 | b(j0, 6) << 2 | b(j0, 7) << 3 | b(j0, 9) << 4 | b(j0, 10) << 5 | b(j0, 5) << 6 | b(j0, 8) << 7));
        cmp("skis in1", game, c, t->o_in1, lo(b(j0, 11)));
        cmp("skis in2", game, c, t->o_in2, (b(j0, 12) ? 0xf0 : 0) | (b(j0, 13) ? 0x0f : 0));
        cmp("skis an0", game, c, t->o_an0, sky_y(t->joy_analog));
        if (since > 6) { double hm[6]; for (int k = 0; k < 6; ++k) hm[k] = 256.0 - hs[k];   // mirrored (board, s2702)
                         near("skis an1", c, t->o_an1, hm); }
        cmp("skis an2", game, c, t->o_an2, 0xff); cmp("skis an3", game, c, t->o_an3, 0xff);
      } else {
        cmp("tops in0", game, c, t->o_in0, lo(b(j0, 4) << 0 | b(j0, 6) << 2 | b(j0, 7) << 3 | b(j0, 11) << 4 | b(j0, 8) << 5 | b(j0, 5) << 6 | b(j0, 10) << 7));
        cmp("tops in1", game, c, t->o_in1, lo(b(j0, 9)));
        cmp("tops in2", game, c, t->o_in2, 0xff);
        if (since > 6) { near("tops an0", c, t->o_an0, hs); near("tops an1", c, t->o_an1, hs); }
        cmp("tops an2", game, c, t->o_an2, 0xff); cmp("tops an3", game, c, t->o_an3, 0xff);
      }
    } else if (t->game == 0x1e || t->game == 0x1f || t->game == 0x20) {
      uint32_t j0 = t->joystick_0, j1 = t->joystick_1;
      ++c2g_checks;
      if (t->game == 0x20) {
        cmp("bel in0", game, c, t->o_in0, lo(b(j0, 7) << 0 | b(j1, 7) << 1 | b(j0, 9) << 2 | b(j0, 8) << 3 | b(j0, 6) << 4 | b(j1, 6) << 5));
        // R1016: the mouse's buttons (sampled before the edge, as the joysticks)
        const int ml = ms_btn_pre & 1, mr = (ms_btn_pre >> 1) & 1, g2 = (msel_pre >> 1) & 1;
        if (ms_btn_pre & 3) ++bel_btn_cyc;
        cmp("bel in1", game, c, t->o_in1, lo((b(j0, 4) | (ml & !g2)) << 0 | (b(j1, 4) | (ml & g2)) << 1
                                           | (b(j0, 5) | (mr & !g2)) << 4 | (b(j1, 5) | (mr & g2)) << 5));
        cmp("bel in2", game, c, t->o_in2, 0xff);
        const int got[4] = {t->o_an0, t->o_an1, t->o_an2, t->o_an3};
        static const char *nm[4] = {"bel P1_X", "bel P2_X", "bel P1_Y", "bel P2_Y"};
        const bool mch[4] = {m1, m2, m1, m2};
        if (m1 || m2) ++bel_mouse_cyc;
        if (since > 12 && rst_ok > 12) for (int ch = 0; ch < 4; ++ch) {
          bool ok = false, near1 = false;
          for (int k = 0; k < 12; ++k) {
            if (got[ch] == bel_axis(ch, bh[ch][k])) ok = true;
            double d = got[ch] - bel_line(ch, bh[ch][k]);
            if (d <= 1.0 && d >= -1.0) near1 = true;
          }
          { double d = got[ch] - bel_line(ch, bh[ch][0]); if (d < 0) d = -d; if (got[ch] == bel_axis(ch, bh[ch][0]) && d > bel_dev) bel_dev = d; }
          checks += 2;
          if (got[ch] < BEL_MIN[ch] || got[ch] > BEL_MAX[ch]) ok = near1 = false;   // MAME's PORT_MINMAX
          if (!ok && mism++ < 25) std::printf("  MISMATCH %s cyc %llu: dut %02x want %02x (pixel %d%s)\n", nm[ch], (unsigned long long)c, got[ch], bel_axis(ch, bh[ch][0]), bh[ch][0], mch[ch] ? ", mouse" : "");
          if (!near1 && mism++ < 25) std::printf("  OFF THE LINE %s cyc %llu: dut %02x line %.2f (pixel %d)\n", nm[ch], (unsigned long long)c, got[ch], bel_line(ch, bh[ch][0]), bh[ch][0]);
          const int lo_end = ch < 2 ? BEL_MIN[ch] : BEL_MAX[ch], hi_end = ch < 2 ? BEL_MAX[ch] : BEL_MIN[ch];   // pixel 0 / the far edge
          if (got[ch] == lo_end) ++bel_ends[ch][0];
          if (got[ch] == hi_end) ++bel_ends[ch][2];
          if (!mch[ch] && bh[ch][0] == bh[ch][11] && bh[ch][0] == (ch < 2 ? 248 : 192) && got[ch] == bel_axis(ch, bh[ch][0])) ++bel_ends[ch][1];
          if (mch[ch] && got[ch] == lo_end) ++bel_mouse_ends[ch][0];
          if (mch[ch] && got[ch] == hi_end) ++bel_mouse_ends[ch][1];
        }
      } else {
        cmp("c2g in0", game, c, t->o_in0, lo(b(j0, 4) << 0 | b(j0, 6) << 2 | b(j0, 7) << 3 | b(j0, 5) << 6));
        if (t->game == 0x1e) {
          cmp("wave in1", game, c, t->o_in1, lo(b(j0, 8)));
          cmp("wave in2", game, c, t->o_in2, 0xf7);
          if (since > 6) { near("wave an0", c, t->o_an0, hs); near("wave an1", c, t->o_an1, hs); near("wave an2", c, t->o_an2, sa); }
          // the pitch is registered once from the stick: the sample before the edge
          static int py_d = 0x7f; int py = 0xff - ((0x80 + int8_t(t->joy_analog >> 8)) & 0xff);
          (void)py_d; cmp("wave an3", game, c, t->o_an3, py);
          if (t->o_an3 == 0x00) ++wave_pitch_ends[0];
          if (t->o_an3 == 0xff) ++wave_pitch_ends[1];
          if (t->o_an2 == 0x00) ++wave_thr_ends[0];
          if (t->o_an2 == 0xff) ++wave_thr_ends[1];
        } else {
          cmp("wski in1", game, c, t->o_in1, lo(b(j0, 8) << 0 | b(j0, 9) << 1 | b(j0, 10) << 2 | b(j0, 11) << 3));
          cmp("wski in2", game, c, t->o_in2, 0xff);
          if (since > 6) { double hm[6]; for (int k = 0; k < 6; ++k) hm[k] = 256.0 - hs[k];   // mirrored (board, s2702)
                           near("wski an0", c, t->o_an0, hm); }
          cmp("wski an1", game, c, t->o_an1, 0xff); cmp("wski an2", game, c, t->o_an2, 0xff); cmp("wski an3", game, c, t->o_an3, 0xff);
          if (t->o_an0 <= 0x01) ++wski_sl_ends[0];
          if (t->o_an0 == 0xff) ++wski_sl_ends[1];
        }
      }
    } else if (t->game == 0x1c || t->game == 0x1d) {   // G_OREV / G_STCC, or G_DIG's draw of 0x1C / 0x1D
      const bool st = (t->game == 0x1d);          // R933: STCC, the pedals not reversed
      cmp("or in0", game, c, t->o_in0, o.in0);
      cmp("or in1", game, c, t->o_in1, o.in1);
      cmp("or in2", game, c, t->o_in2, o.in2);
      // R1037: and not in the clocks after a reset (R958's Sky Target switch holds
      // one for 8 clocks; the channels restart behind it) -- a bench gap the
      // 2B IDs' extra random draws exposed (a switch 0x18 -> 0x1C, an1 0xFF)
      if (since > 6 && rst_ok > 6) {   // R933: a pedal registered under 0x1C's sense may stand for three clocks after 0x1D
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
    if (t->game != 0x1e && t->game != 0x20) cmp("or an3", game, c, t->o_an3, 0xff);   // R1010
    // R1037: the 2B build's copy. Its own IDs against MAME's ports; INDY 500 /
    // Super GT 24h on STCC's / Over Rev's lines; Over Rev and STCC as the OREV
    // copy; the C2G IDs digital (no C2G on 2B); everything else as the MOTION 0 copy.
    if (t->game == 0x25 || t->game == 0x29) {
      ++b2_checks; ++b2_seen[t->game == 0x29];
      cmp("b2 in0", game, c, t->b_in0, wb.in0); cmp("b2 in1", game, c, t->b_in1, wb.in1);
      cmp("b2 in2", game, c, t->b_in2, wb.in2);
      if (t->game == 0x29) for (int k = 0; k < 4; ++k) if (!((wb.in2 >> k) & 1)) ++b2_pd_low[k];
      cmp("b2 an0", game, c, t->b_an0, wb.an[0]); cmp("b2 an1", game, c, t->b_an1, wb.an[1]);
      cmp("b2 an2", game, c, t->b_an2, wb.an[2]); cmp("b2 an3", game, c, t->b_an3, wb.an[3]);
    } else if (t->game == 0x2d || t->game == 0x28) {   // R1046
      const int k = (t->game == 0x28);
      ++b2_checks; ++b2n_seen[k];
      cmp(k ? "von in0" : "dybb in0", game, c, t->b_in0, wn2.in0);
      cmp(k ? "von in1" : "dybb in1", game, c, t->b_in1, wn2.in1);
      cmp(k ? "von in2" : "dybb in2", game, c, t->b_in2, wn2.in2);
      cmp(k ? "von an0" : "dybb an0", game, c, t->b_an0, wn2.an[0]); cmp(k ? "von an1" : "dybb an1", game, c, t->b_an1, wn2.an[1]);
      cmp("b2n an2", game, c, t->b_an2, 0xff); cmp("b2n an3", game, c, t->b_an3, 0xff);
      if (!k) { ++dybb_bat[0][t->b_an0 == 0xff]; ++dybb_bat[1][t->b_an1 == 0xff]; }
      else if ((~t->b_in2 & 0xf3) && !(t->joystick_1 & 0x33)) ++von_r[(~t->b_in2 & 0xf0) ? 0 : 1];   // the right lever / buttons from player 1 alone
    } else if (t->game == 0x1c || t->game == 0x1d || t->game == 0x26 || t->game == 0x27) {
      const bool st = (t->game == 0x1d || t->game == 0x26);
      cmp("b2 or in0", game, c, t->b_in0, o.in0);
      cmp("b2 or in1", game, c, t->b_in1, o.in1 | (t->game == 0x27 ? 0x02 : 0));   // R1046: sgt24h's 0x02 unused
      cmp("b2 or in2", game, c, t->b_in2, o.in2);
      if (since > 6 && rst_ok > 6) {
        near("b2 or an0", c, t->b_an0, hs);
        near(st ? "b2 st an1" : "b2 or an1", c, t->b_an1, st ? sa : ha);
        near(st ? "b2 st an2" : "b2 or an2", c, t->b_an2, st ? sb : hb);
      }
      cmp("b2 an3", game, c, t->b_an3, 0xff);
      ++b2_checks;
    } else {
      cmp("b2 in0", game, c, t->b_in0, wn.in0); cmp("b2 in1", game, c, t->b_in1, wn.in1);
      cmp("b2 in2", game, c, t->b_in2, wn.in2);
      cmp("b2 an0", game, c, t->b_an0, wn.an0); cmp("b2 an1", game, c, t->b_an1, wn.an1);
      cmp("b2 an2", game, c, t->b_an2, wn.an2); cmp("b2 an3", game, c, t->b_an3, 0xff);
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
  std::printf("  R1010: %llu C2G cycles; Wave Runner throttle released 0x00 %llu / floored 0xFF %llu, pitch 0x00 %llu / 0xFF %llu; Water Ski slide <= 0x01 %llu / 0xFF %llu\n",
              (unsigned long long)c2g_checks, (unsigned long long)wave_thr_ends[0], (unsigned long long)wave_thr_ends[1],
              (unsigned long long)wave_pitch_ends[0], (unsigned long long)wave_pitch_ends[1],
              (unsigned long long)wski_sl_ends[0], (unsigned long long)wski_sl_ends[1]);
  std::printf("  R1016 Behind Enemy Lines cycles at pixel 0's end / stick centre / the far end:");
  for (int ch = 0; ch < 4; ++ch) std::printf(" ch%d %llu/%llu/%llu", ch, (unsigned long long)bel_ends[ch][0], (unsigned long long)bel_ends[ch][1], (unsigned long long)bel_ends[ch][2]);
  std::printf("\n  R1016 mouse: %llu packets, %llu Behind Enemy Lines cycles aimed by it, %llu with a button down; ends reached by the mouse:",
              (unsigned long long)ms_packets, (unsigned long long)bel_mouse_cyc, (unsigned long long)bel_btn_cyc);
  for (int ch = 0; ch < 4; ++ch) std::printf(" ch%d %llu/%llu", ch, (unsigned long long)bel_mouse_ends[ch][0], (unsigned long long)bel_mouse_ends[ch][1]);
  std::printf("\n  R1016 largest distance of an exact match from the straight line: %.3f units\n", bel_dev);
  std::printf("  R958 Analog control Wheel A / B cycles per game:");
  for (int g = 0; g < G_N; ++g) std::printf(" %s %llu%s", GNAME[g], (unsigned long long)per_game_wheel[g], g + 1 < G_N ? "," : "\n");
  std::printf("  Sky Target in a wheel mode: %llu cycles where the wheel-mode block's steering differs and Sky Target kept Standard's\n",
              (unsigned long long)sky_wdiff);
  std::printf("  (%llu clocks skipped in the sync after a switch to or from Sky Target)\n", (unsigned long long)sky_skip);
  std::printf("  R1037 2B copy: %llu own-ID / Over Rev line cycles (gunblade %llu, rchase2 %llu); rchase2 PD bits 0-3 low %llu %llu %llu %llu cycles\n",
              (unsigned long long)b2_checks, (unsigned long long)b2_seen[0], (unsigned long long)b2_seen[1],
              (unsigned long long)b2_pd_low[0], (unsigned long long)b2_pd_low[1], (unsigned long long)b2_pd_low[2], (unsigned long long)b2_pd_low[3]);
  std::printf("  R1046 2B copy: Dynamite Baseball %llu cycles (BAT1 0x00-or-trigger / 0xFF %llu / %llu, BAT2 0x00 / 0xFF %llu / %llu), Virtual-On %llu (right lever / buttons from player 1 alone %llu / %llu)\n",
              (unsigned long long)b2n_seen[0], (unsigned long long)dybb_bat[0][0], (unsigned long long)dybb_bat[0][1],
              (unsigned long long)dybb_bat[1][0], (unsigned long long)dybb_bat[1][1], (unsigned long long)b2n_seen[1],
              (unsigned long long)von_r[0], (unsigned long long)von_r[1]);
  std::printf("  %llu mismatches\n%s\n", (unsigned long long)mism, mism ? "FAIL" : "PASS");
  delete t;
  return mism ? 1 : 0;
}
