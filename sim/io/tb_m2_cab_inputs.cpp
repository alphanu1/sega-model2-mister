// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R835 / R837: THE CABINET INPUTS, MOVED AND EXTENDED FOR DESERT TANK.
//
// Part A, is_desert = 0: rtl/io/m2_cab_inputs.sv against the block as it stood
// in Model2.sv at 0f3cbc4 (sim/io/m2_cab_inputs_ref.sv) -- in0, in1, steer,
// accel and brake compared after every clock edge and after every input
// change, under random buttons, sticks, paddle, OSD bits and resets. Any
// difference is a Daytona regression.
// Part B, is_desert = 1: in0 and steer still equal the reference (Desert
// Tank's HANDLE is Daytona's steering, unchanged); in1, accel and brake equal
// a model of R837's map, written from the study entry, not the RTL -- for the
// SYS_MHZ 80 copy and for a SYS_MHZ 1 copy whose timers step 80x as often:
//   in1   MAME's INPUT_PORTS_START(desert): 0x01 Shift (low = reverse),
//         0x10 Machine Gun (bit 12), 0x20 Cannon (bit 13), every other bit 1.
//         Shift is a latch: Reverse (bit 11) or a wheel's reverse half sets
//         it, Forward (bit 10) or a wheel's forward half clears it (Reverse
//         wins), and otherwise each press of VR4 (bit 9) flips it.
//   accel ACCEL, the one drive pedal: 0xe0 on either button, a wheel's pedal
//         (right stick Y in "Pedals+steer") past the dead zone, else 0x20.
//   brake TURRET: the target is 0x80 + 3/4 of the right stick's Y (flipped
//         by "Pedals") past the dead zone in pad mode, otherwise the d-pad's
//         held aim (0x80 out of reset, one count each 7812 us, 0x20..0xe0);
//         the output follows the target one count each 3906 us.
// Part C, directed on the SYS_MHZ 1 copy: rest values, the stick's rails,
// the slew, the d-pad aim saturating at both ends, the lever.

#include "Vtb_m2_cab_inputs_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <random>

static Vtb_m2_cab_inputs_top *t;
static std::mt19937_64 rng(0x835835);
static uint64_t mism = 0, checks = 0;

static int rnd(int n) { return int(rng() % uint64_t(n)); }

// ------------------------------------------------- Desert Tank's model (R837)
struct Model {
  int K, S;                       // d-pad step and slew step, in clocks
  int shift = 0, shf_d = 0, tur_dig = 0x80, tur_div = 0, tur_out = 0x80, tur_sdiv = 0;
  uint64_t n_tstep = 0, n_slew = 0;
  Model(int mhz) : K(mhz * 7812), S(mhz * 3906) {}
  void reset() { shift = 0; shf_d = 0; tur_dig = 0x80; tur_div = 0; tur_out = 0x80; tur_sdiv = 0; }
};
static Model m80(80), m1(1);
static int rs[3] = {0, 0, 0};    // the 3-flop OSD sync of "Right stick"
static uint64_t n_tuse = 0, n_wheel = 0, n_setrev = 0, n_vr4 = 0;

struct DtComb { int accel, raw, in1; bool go_rev, go_fwd; };
static DtComb dt_comb(const Model &m) {
  int j = t->joystick_0;
  int ax = int8_t(t->joy_ranalog >> 8);
  int mag = (ax == -128) ? 127 : (ax < 0 ? -ax : ax);
  int scl = mag + (mag >> 1);
  int pan = (scl >= 192) ? 0xe0 : 0x20 + scl;
  bool pup = t->st_pedswap ? !(ax < 0) : (ax < 0);
  bool wheel = rs[2];
  bool fwd = (j >> 10) & 1, rev = (j >> 11) & 1;
  bool ped_on = wheel && mag > 12;
  DtComb c;
  c.go_rev = rev || (!fwd && ped_on && !pup);
  c.go_fwd = !rev && (fwd || (ped_on && pup));
  c.accel = (fwd || rev) ? 0xe0 : ped_on ? pan : 0x20;
  int rx = t->st_pedswap ? -ax : ax;
  int fl4 = (rx >= 0) ? rx / 4 : -((-rx + 3) / 4);      // floor(rx / 4)
  bool use = !wheel && (ax > 12 || ax < -12);
  c.raw = use ? ((0x80 + rx - fl4) & 0xff) : m.tur_dig;
  c.in1 = 0xc0 | (((j >> 13) & 1) ? 0 : 0x20) | (((j >> 12) & 1) ? 0 : 0x10) | 0x0e | (m.shift ? 0 : 1);
  return c;
}
static void model_edge(Model &m, bool count) {
  int j = t->joystick_0, j9 = (j >> 9) & 1;
  DtComb c = dt_comb(m);
  if (!t->rst_n) { m.reset(); return; }
  if (c.go_rev) { if (!m.shift && count) ++n_setrev; m.shift = 1; }
  else if (c.go_fwd) m.shift = 0;
  else if (j9 && !m.shf_d) { m.shift ^= 1; if (count) ++n_vr4; }
  m.shf_d = j9;
  if (m.tur_div == 0) {
    m.tur_div = m.K - 1;
    bool up = (j >> 3) & 1, dn = (j >> 2) & 1;
    if (up && !dn && m.tur_dig > 0x20) { --m.tur_dig; ++m.n_tstep; }
    else if (dn && !up && m.tur_dig < 0xe0) { ++m.tur_dig; ++m.n_tstep; }
  } else --m.tur_div;
  if (m.tur_sdiv == 0) {
    m.tur_sdiv = m.S - 1;
    if (m.tur_out < c.raw) { ++m.tur_out; ++m.n_slew; }
    else if (m.tur_out > c.raw) { --m.tur_out; ++m.n_slew; }
  } else --m.tur_sdiv;
}

static void check(const char *ph, uint64_t cyc, bool desert) {
  auto cmp = [&](const char *n, int a, int b) {
    ++checks;
    if (a != b && mism++ < 20)
      printf("  MISMATCH %s cyc %llu %s: dut %02x want %02x\n", ph, (unsigned long long)cyc, n, a, b);
  };
  cmp("in0", t->in0, t->r_in0);
  cmp("steer", t->steer, t->r_steer);
  if (!desert) {
    cmp("accel", t->accel, t->r_accel);
    cmp("brake", t->brake, t->r_brake);
    cmp("in1", t->in1, t->r_in1);
  } else {
    DtComb c = dt_comb(m80), f = dt_comb(m1);
    cmp("accel", t->accel, c.accel);
    cmp("brake", t->brake, m80.tur_out);
    cmp("in1", t->in1, c.in1);
    cmp("f_accel", t->f_accel, f.accel);
    cmp("f_brake", t->f_brake, m1.tur_out);
    cmp("f_in1", t->f_in1, f.in1);
  }
}

static void edge(bool desert) {
  // the models' registers, updated at the rising edge from the pre-edge inputs
  if (desert) {
    int ax = int8_t(t->joy_ranalog >> 8);
    if (!rs[2] && (ax > 12 || ax < -12)) ++n_tuse;
    if (rs[2] && (ax > 12 || ax < -12)) ++n_wheel;
  }
  model_edge(m80, true);
  model_edge(m1, false);
  rs[2] = rs[1]; rs[1] = rs[0]; rs[0] = t->st_rsteer;
  t->clk = 1; t->eval();
  t->clk = 0; t->eval();
}

static void areset() { m80.reset(); m1.reset(); }   // the RTL's reset is asynchronous

static void run(const char *ph, bool desert, uint64_t ncyc, uint64_t &in1_diff) {
  t->is_desert = desert;
  for (uint64_t c = 0; c < ncyc; ++c) {
    // inputs change between edges
    if (rnd(48) == 0) t->joystick_0 ^= 1u << rnd(16);
    if (rnd(2000) == 0) t->joy_analog  = uint16_t(rng());
    if (rnd(2000) == 0) t->joy_ranalog = uint16_t(rng());
    if (rnd(3000) == 0) t->paddle = (rnd(3) == 0) ? uint8_t(rng()) : 0;
    if (rnd(20000) == 0) { t->st_pedswap = rnd(2); t->st_ssens = rnd(4); t->st_ssm = rnd(4); t->st_rsteer = rnd(2); }
    if (rnd(200000) == 0) t->rst_n = 0; else if (!t->rst_n && rnd(8) == 0) t->rst_n = 1;
    if (!t->rst_n) areset();
    t->eval();
    check(ph, c, desert);
    edge(desert);
    check(ph, c, desert);
    if (t->in1 != t->r_in1) ++in1_diff;
  }
}

// Part C helpers: hold the inputs, clock n cycles with checks
static void hold(uint64_t n) {
  for (uint64_t c = 0; c < n; ++c) { t->eval(); check("C", c, true); edge(true); }
  t->eval(); check("C", n, true);
}
static void expect(const char *what, int got, int want) {
  ++checks;
  bool ok = got == want;
  if (!ok) ++mism;
  printf("   %-46s %02x (want %02x) %s\n", what, got, want, ok ? "ok" : "FAIL");
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  t = new Vtb_m2_cab_inputs_top;
  t->clk = 0; t->rst_n = 0; t->is_desert = 0; t->joystick_0 = 0;
  t->joy_analog = 0; t->joy_ranalog = 0; t->paddle = 0;
  t->st_pedswap = 0; t->st_ssens = 0; t->st_ssm = 0; t->st_rsteer = 0;
  areset();
  for (int i = 0; i < 4; ++i) edge(false);
  t->rst_n = 1;
  uint64_t d = 0;
  printf("== part A: is_desert = 0 against the 0f3cbc4 block\n");
  run("A", false, 3000000, d);
  uint64_t ma = mism;
  printf("   %llu checks, %llu mismatches\n", (unsigned long long)checks, (unsigned long long)ma);

  printf("== part B: is_desert = 1, Desert Tank's map (R837)\n");
  t->rst_n = 0; t->eval(); areset(); edge(true); t->rst_n = 1;
  uint64_t c0 = checks; d = 0;
  run("B", true, 20000000, d);
  uint64_t mb = mism - ma;
  printf("   %llu checks, %llu mismatches; in1 differs from Daytona's on %llu cycles\n",
         (unsigned long long)(checks - c0), (unsigned long long)mb, (unsigned long long)d);
  printf("   coverage: d-pad aim steps %llu (80 MHz) / %llu (1 MHz); slew steps %llu / %llu;\n"
         "             %llu stick-aim cycles, %llu wheel-pedal cycles, %llu lever sets to\n"
         "             reverse, %llu VR4 flips\n",
         (unsigned long long)m80.n_tstep, (unsigned long long)m1.n_tstep,
         (unsigned long long)m80.n_slew, (unsigned long long)m1.n_slew,
         (unsigned long long)n_tuse, (unsigned long long)n_wheel,
         (unsigned long long)n_setrev, (unsigned long long)n_vr4);

  printf("== part C: directed (SYS_MHZ 1: d-pad step 7812, slew step 3906 clocks)\n");
  uint64_t c1 = mism;
  const uint64_t SL = 3906;
  t->joystick_0 = 0; t->joy_ranalog = 0; t->paddle = 0; t->st_pedswap = 0; t->st_rsteer = 0;
  t->rst_n = 0; t->eval(); areset(); edge(true); t->rst_n = 1;
  hold(8);
  expect("rest: TURRET (brake) centred", t->f_brake, 0x80);
  expect("rest: ACCEL idle", t->f_accel, 0x20);
  expect("rest: IN1, lever forward", t->f_in1, 0xff);
  t->joy_ranalog = 0x8000; hold(SL * 10);               // stick fully up (-128)
  expect("right stick full up, 10 slew steps", t->f_brake, 0x80 - 10);
  hold(SL * 100);
  expect("  ... settled: aim-up rail", t->f_brake, 0x20);
  t->joy_ranalog = 0x7f00; hold(SL * 0x60);             // fully down (+127)
  expect("full down, 0x60 steps: only to centre", t->f_brake, 0x80);
  hold(SL * 0x70);
  expect("  ... settled: aim-down rail", t->f_brake, 0xe0);
  t->st_pedswap = 1; hold(SL * 0xd0);
  expect("  ... Pedals: Swapped, settled", t->f_brake, 0x80 - 127 + 32);
  t->st_pedswap = 0; t->joy_ranalog = 0x0c00; hold(SL * 0x70);   // +12: dead zone
  expect("right stick +12 (dead zone): d-pad aim", t->f_brake, 0x80);
  t->joy_ranalog = 0;
  t->joystick_0 = 1u << 3; hold(7812ull * 100);          // d-pad up, 100 steps
  expect("d-pad up held 100 steps: aim-up rail", t->f_brake, 0x20);
  t->joystick_0 = 0; hold(7812ull * 3);
  expect("  ... released: the aim holds", t->f_brake, 0x20);
  t->joystick_0 = 1u << 2; hold(7812ull * 200);          // d-pad down, 200 steps
  expect("d-pad down held 200 steps: aim-down rail", t->f_brake, 0xe0);
  t->joystick_0 = 1u << 11; hold(4);
  expect("Reverse: ACCEL full", t->f_accel, 0xe0);
  expect("Reverse: IN1 lever reverse", t->f_in1, 0xfe);
  t->joystick_0 = 0; hold(4);
  expect("released: ACCEL idle", t->f_accel, 0x20);
  expect("released: lever stays reverse", t->f_in1, 0xfe);
  t->joystick_0 = 1u << 10; hold(4);
  expect("Forward: IN1 lever forward", t->f_in1, 0xff);
  t->joystick_0 = (1u << 10) | (1u << 11); hold(4);
  expect("both: Reverse wins", t->f_in1, 0xfe);
  t->joystick_0 = 0; hold(4);
  t->joystick_0 = 1u << 9; hold(4); t->joystick_0 = 0; hold(4);
  expect("VR4 press: lever flips to forward", t->f_in1, 0xff);
  t->st_rsteer = 1; t->joy_ranalog = 0x8000; hold(8);    // wheel, Y up = forward half
  expect("wheel mode, Y up: ACCEL 0x20 + 190", t->f_accel, 0xde);   // Daytona's scaling
  expect("wheel mode, Y up: lever forward", t->f_in1, 0xff);
  expect("wheel mode: TURRET is the d-pad's", t->f_brake, 0xe0);
  t->joy_ranalog = 0x4000; hold(8);                     // +64: the reverse half
  expect("wheel mode, Y +64: ACCEL 0x20 + 96", t->f_accel, 0x20 + 96);
  expect("wheel mode, Y +64: lever reverse", t->f_in1, 0xfe);
  printf("   %llu failures\n", (unsigned long long)(mism - c1));

  bool ok = (mism == 0) && d > 1000 && m80.n_tstep > 10 && m1.n_tstep > 1000 && m1.n_slew > 1000
            && n_tuse > 100000 && n_wheel > 100000 && n_setrev > 100 && n_vr4 > 10;
  printf("%s\n", ok ? "PASS" : "FAIL");
  delete t;
  return ok ? 0 : 1;
}
