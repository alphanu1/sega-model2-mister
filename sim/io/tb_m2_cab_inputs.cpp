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
//   in1   MAME's INPUT_PORTS_START(desert): 0x01 Shift (high = reverse, R838 -- the board; R837 had low),
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
// R958, ANALOG CONTROL (st_wheel; GitHub #12). Parts A-C hold it at
// Standard (0), so Part A is the default against the 0f3cbc4 block, byte for
// byte. Part D: random inputs with st_wheel random; Standard (0 / 3) is
// still compared with the reference, Wheel A / B with a model written from
// the request:
//   steering  the left stick's X, no dead zone, scaled by "Steering"; the
//             right stick never; the paddle first; the d-pad while held
//   Wheel A   accelerator = left Y's up half, brake = right Y's up half
//             (0 released .. -127 fully pressed; the down half released)
//   Wheel B   accelerator = left Y, -127 released .. +127 pressed; brake =
//             right X the same; p = (v + 127) / 2, -128 released
//   a pedal p (0..127) reads 0x20 + p + p/2 (the right-stick pedals'
//   scaling: 0x20 released, 0xde fully pressed); "Pedals: Swapped" exchanges
//   them; the Accel / Brake buttons give 0xe0
//   Desert Tank: the further-pressed pedal drives (accelerator forward,
//   brake reverse) past the dead zone of 12, setting the lever; the cannon
//   is the d-pad's.
// Part E: directed sweeps of every axis through -128..+127 in each mode,
// Pedals Normal and Swapped, every Steering, checked against the request's
// endpoints and monotonicity as well as the model; Standard swept against
// the reference; Steering smoothing on the wheel's X; Desert Tank's pedals.

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
// R958: Analog control's sync, and the bits of the steering the wheel model needs
static int ws[3] = {0, 0, 0}, ssn[3] = {0, 0, 0}, smm[3] = {0, 0, 0};
static int w_acc_m = 0, w_brk_m = 0;                // registered pedal magnitudes
static int st_rq = 0x80; static bool st_known = false;   // steer_rq, when the model knows it
static uint64_t n_wa = 0, n_wb = 0, n_wcheck = 0;
static bool whl_a() { return ws[2] == 1; }
static bool whl_b() { return ws[2] == 2; }
static bool whl()   { return whl_a() || whl_b(); }
static bool whl_prev = false;   // the mode steer_rq was registered under (one clock behind)
static int p_up(int v)   { return v < 0 ? (v == -128 ? 127 : -v) : 0; }      // Wheel A
static int p_full(int v) { return v == -128 ? 0 : (v + 127) / 2; }          // Wheel B
static int p_an(int p)   { return 0x20 + p + p / 2; }
static int fl(int x, int d) { return (x >= 0) ? x / d : -((-x + d - 1) / d); }
static int st_an(int x, int ss) {
  int sc = ss == 0 ? x - fl(x, 4) : ss == 1 ? x : ss == 2 ? x + fl(x, 4) : fl(x, 2);
  int v = 0x80 + sc;
  return v > 0xe0 ? 0xe0 : v < 0x20 ? 0x20 : v;
}
static uint64_t n_tuse = 0, n_wheel = 0, n_setrev = 0, n_vr4 = 0;

struct DtComb { int accel, raw, in1; bool go_rev, go_fwd; };
static DtComb dt_comb(const Model &m) {
  int j = t->joystick_0;
  int ax = int8_t(t->joy_ranalog >> 8);
  int mag = (ax == -128) ? 127 : (ax < 0 ? -ax : ax);
  int scl = mag + (mag >> 1);
  int pan = (scl >= 192) ? 0xe0 : 0x20 + scl;
  bool pup = t->st_pedswap ? !(ax < 0) : (ax < 0);
  bool wheel = rs[2] || whl();                          // R958
  bool fwd = (j >> 10) & 1, rev = (j >> 11) & 1;
  bool wf = w_acc_m >= w_brk_m;
  if (whl()) { mag = wf ? w_acc_m : w_brk_m; pup = wf; pan = p_an(mag); }
  bool ped_on = wheel && mag > 12;
  DtComb c;
  c.go_rev = rev || (!fwd && ped_on && !pup);
  c.go_fwd = !rev && (fwd || (ped_on && pup));
  c.accel = (fwd || rev) ? 0xe0 : ped_on ? pan : 0x20;
  int rx = t->st_pedswap ? -ax : ax;
  int fl4 = (rx >= 0) ? rx / 4 : -((-rx + 3) / 4);      // floor(rx / 4)
  bool use = !wheel && (ax > 12 || ax < -12);
  c.raw = use ? ((0x80 + rx - fl4) & 0xff) : m.tur_dig;
  c.in1 = 0xc0 | (((j >> 13) & 1) ? 0 : 0x20) | (((j >> 12) & 1) ? 0 : 0x10) | 0x0e | (m.shift ? 1 : 0);   // R838: high = reverse
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
  if (!whl() && !whl_prev) cmp("steer", t->steer, t->r_steer);
  else if (st_known && smm[2] == 0) { cmp("w_steer", t->steer, st_rq); ++n_wcheck; }
  if (!desert && whl()) {                               // R958: the wheel model
    int j = t->joystick_0;
    cmp("w_accel", t->accel, ((j >> 10) & 1) ? 0xe0 : p_an(w_acc_m));
    cmp("w_brake", t->brake, ((j >> 11) & 1) ? 0xe0 : p_an(w_brk_m));
    cmp("in1", t->in1, t->r_in1);
    if (ws[2] == 1) ++n_wa; else ++n_wb;
  } else if (!desert) {
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
  // R958: the wheel's registers, from the pre-edge inputs and synced mode
  {
    int ly = int8_t(t->joy_analog >> 8), lx = int8_t(t->joy_analog & 0xff);
    int ry = int8_t(t->joy_ranalog >> 8), rx = int8_t(t->joy_ranalog & 0xff);
    int a = whl_b() ? p_full(ly) : p_up(ly);
    int b = whl_b() ? p_full(rx) : p_up(ry);
    w_acc_m = t->st_pedswap ? b : a;
    w_brk_m = t->st_pedswap ? a : b;
    int j = t->joystick_0;
    st_known = whl() && (t->paddle || !(j & 3));
    whl_prev = whl();
    st_rq = t->paddle ? t->paddle : st_an(lx, ssn[2]);
  }
  rs[2] = rs[1]; rs[1] = rs[0]; rs[0] = t->st_rsteer;
  ws[2] = ws[1]; ws[1] = ws[0]; ws[0] = t->st_wheel;
  ssn[2] = ssn[1]; ssn[1] = ssn[0]; ssn[0] = t->st_ssens;
  smm[2] = smm[1]; smm[1] = smm[0]; smm[0] = t->st_ssm;
  t->clk = 1; t->eval();
  t->clk = 0; t->eval();
}

static void areset() { m80.reset(); m1.reset(); }   // the RTL's reset is asynchronous

static bool wheel_rand = false;   // R958: Part D randomises Analog control (Smoothing Off)
static void run(const char *ph, bool desert, uint64_t ncyc, uint64_t &in1_diff) {
  t->is_desert = desert;
  for (uint64_t c = 0; c < ncyc; ++c) {
    // inputs change between edges
    if (rnd(48) == 0) t->joystick_0 ^= 1u << rnd(16);
    if (rnd(2000) == 0) t->joy_analog  = uint16_t(rng());
    if (rnd(2000) == 0) t->joy_ranalog = uint16_t(rng());
    if (rnd(3000) == 0) t->paddle = (rnd(3) == 0) ? uint8_t(rng()) : 0;
    if (rnd(20000) == 0) {
      t->st_pedswap = rnd(2); t->st_ssens = rnd(4); t->st_rsteer = rnd(2);
      if (wheel_rand) { t->st_wheel = (rnd(4) == 0) ? rnd(4) : 1 + rnd(2); t->st_ssm = 0; }
      else t->st_ssm = rnd(4);
    }
    if (wheel_rand && rnd(4000) == 0) {               // a wheel's axes: whole range, often
      int k = rnd(4); uint8_t v = uint8_t(rng());
      if (k < 2) t->joy_analog  = (t->joy_analog  & (k ? 0x00ff : 0xff00)) | (k ? v << 8 : v);
      else       t->joy_ranalog = (t->joy_ranalog & (k & 1 ? 0x00ff : 0xff00)) | (k & 1 ? v << 8 : v);
    }
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
  t->st_pedswap = 0; t->st_ssens = 0; t->st_ssm = 0; t->st_rsteer = 0; t->st_wheel = 0;
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
  expect("rest: IN1, lever forward", t->f_in1, 0xfe);
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
  expect("Reverse: IN1 lever reverse", t->f_in1, 0xff);
  t->joystick_0 = 0; hold(4);
  expect("released: ACCEL idle", t->f_accel, 0x20);
  expect("released: lever stays reverse", t->f_in1, 0xff);
  t->joystick_0 = 1u << 10; hold(4);
  expect("Forward: IN1 lever forward", t->f_in1, 0xfe);
  t->joystick_0 = (1u << 10) | (1u << 11); hold(4);
  expect("both: Reverse wins", t->f_in1, 0xff);
  t->joystick_0 = 0; hold(4);
  t->joystick_0 = 1u << 9; hold(4); t->joystick_0 = 0; hold(4);
  expect("VR4 press: lever flips to forward", t->f_in1, 0xfe);
  t->st_rsteer = 1; t->joy_ranalog = 0x8000; hold(8);    // wheel, Y up = forward half
  expect("wheel mode, Y up: ACCEL 0x20 + 190", t->f_accel, 0xde);   // Daytona's scaling
  expect("wheel mode, Y up: lever forward", t->f_in1, 0xfe);
  expect("wheel mode: TURRET is the d-pad's", t->f_brake, 0xe0);
  t->joy_ranalog = 0x4000; hold(8);                     // +64: the reverse half
  expect("wheel mode, Y +64: ACCEL 0x20 + 96", t->f_accel, 0x20 + 96);
  expect("wheel mode, Y +64: lever reverse", t->f_in1, 0xff);
  printf("   %llu failures\n", (unsigned long long)(mism - c1));

  // ------------------------------------------------ R958: Analog control
  printf("== part D: Analog control random (Wheel A / B against the request's model,\n"
         "            Standard against the 0f3cbc4 block), Daytona then Desert Tank\n");
  uint64_t c2 = mism, k0 = checks;
  wheel_rand = true;
  t->st_ssm = 0; t->st_wheel = 1;
  t->rst_n = 0; t->eval(); areset(); edge(false); t->rst_n = 1;
  run("D", false, 6000000, d);
  t->rst_n = 0; t->eval(); areset(); edge(true); t->rst_n = 1;
  uint64_t n_setrev0 = n_setrev, n_wheel0 = n_wheel;
  run("D", true, 6000000, d);
  wheel_rand = false;
  printf("   %llu checks, %llu mismatches; %llu Wheel A / %llu Wheel B cycles (Daytona),\n"
         "   %llu wheel-model steering checks, %llu lever sets to reverse (Desert Tank)\n",
         (unsigned long long)(checks - k0), (unsigned long long)(mism - c2),
         (unsigned long long)n_wa, (unsigned long long)n_wb, (unsigned long long)n_wcheck,
         (unsigned long long)(n_setrev - n_setrev0));
  (void)n_wheel0;

  printf("== part E: directed sweeps, every axis -128..+127\n");
  uint64_t c3 = mism, k1 = checks;
  auto settle = [&](bool desert) { for (int i = 0; i < 6; ++i) { t->eval(); edge(desert); } t->eval(); };
  auto ax16 = [](int x, int y) { return uint16_t((uint8_t(int8_t(y)) << 8) | uint8_t(int8_t(x))); };
  uint64_t sweep_fail = 0, sweep_n = 0;
  auto want = [&](const char *n, int got, int w, int mode, int sw, int ax, int v) {
    ++checks; ++sweep_n;
    if (got != w) { ++mism; if (sweep_fail++ < 20)
      printf("   FAIL %s mode %d swap %d axis %d v %d: %02x want %02x\n", n, mode, sw, ax, v, got, w); }
  };
  t->is_desert = 0; t->joystick_0 = 0; t->paddle = 0; t->st_ssm = 0; t->st_rsteer = 0;
  t->rst_n = 0; t->eval(); areset(); edge(false); t->rst_n = 1;
  for (int mode = 1; mode <= 2; ++mode)
    for (int sw = 0; sw < 2; ++sw)
      for (int ss = 0; ss < 4; ++ss) {
        t->st_wheel = mode; t->st_pedswap = sw; t->st_ssens = ss;
        int rest_ly = mode == 2 ? -127 : 0, rest_rx = mode == 2 ? -127 : 0;
        int acc_prev = -1, brk_prev = -1;
        for (int ax = 0; ax < 4; ++ax) {        // 0 left X, 1 left Y, 2 right X, 3 right Y
          acc_prev = brk_prev = -1;
          for (int v = -128; v <= 127; ++v) {
            int lx = ax == 0 ? v : 0, ly = ax == 1 ? v : rest_ly;
            int rx = ax == 2 ? v : rest_rx, ry = ax == 3 ? v : 0;
            t->joy_analog = ax16(lx, ly); t->joy_ranalog = ax16(rx, ry);
            settle(false);
            // the request, written out: which axis is which pedal, and its travel
            int pa = mode == 1 ? (ly < 0 ? (ly == -128 ? 127 : -ly) : 0) : (ly == -128 ? 0 : (ly + 127) / 2);
            int pb = mode == 1 ? (ry < 0 ? (ry == -128 ? 127 : -ry) : 0) : (rx == -128 ? 0 : (rx + 127) / 2);
            if (sw) std::swap(pa, pb);
            want("steer", t->steer, st_an(lx, ss), mode, sw, ax, v);
            want("accel", t->accel, 0x20 + pa + pa / 2, mode, sw, ax, v);
            want("brake", t->brake, 0x20 + pb + pb / 2, mode, sw, ax, v);
            // monotonic in the pressing direction, the request's endpoints
            int acc = t->accel, brk = t->brake;
            bool press_dir = (mode == 1) ? true : false;   // A: presses as v falls; B: as v rises
            if (ss == 0 && !sw && ((mode == 1 && ax == 1) || (mode == 2 && ax == 1))) {
              if (acc_prev >= 0) want("accel monotonic", (press_dir ? acc <= acc_prev : acc >= acc_prev), 1, mode, sw, ax, v);
              acc_prev = acc;
            }
            if (ss == 0 && !sw && ((mode == 1 && ax == 3) || (mode == 2 && ax == 2))) {
              if (brk_prev >= 0) want("brake monotonic", (press_dir ? brk <= brk_prev : brk >= brk_prev), 1, mode, sw, ax, v);
              brk_prev = brk;
            }
          }
        }
        // the request's endpoints, by name
        if (ss == 0 && !sw) {
          t->joy_analog = ax16(0, rest_ly); t->joy_ranalog = ax16(rest_rx, 0); settle(false);
          want("released: accel", t->accel, 0x20, mode, sw, 9, 0);
          want("released: brake", t->brake, 0x20, mode, sw, 9, 0);
          want("centred: steer", t->steer, 0x80, mode, sw, 9, 0);
          t->joy_analog = ax16(-127, mode == 1 ? -127 : 127); settle(false);
          want("full accel", t->accel, 0xde, mode, sw, 9, 1);
          want("full left (-127; 0x21 as Standard's)", t->steer, 0x21, mode, sw, 9, 1);
          t->joy_analog = ax16(127, rest_ly);
          t->joy_ranalog = mode == 1 ? ax16(0, -127) : ax16(127, 0); settle(false);
          want("full brake", t->brake, 0xde, mode, sw, 9, 2);
          want("accel released while braking", t->accel, 0x20, mode, sw, 9, 2);
          want("full right lock", t->steer, 0xe0, mode, sw, 9, 2);
          // the other stick's other axis does nothing
          t->joy_analog = ax16(40, rest_ly);
          t->joy_ranalog = mode == 1 ? ax16(-127, 0) : ax16(rest_rx, -127); settle(false);
          want("unused axis: steer", t->steer, st_an(40, 0), mode, sw, 9, 3);
          want("unused axis: accel", t->accel, 0x20, mode, sw, 9, 3);
          want("unused axis: brake", t->brake, 0x20, mode, sw, 9, 3);
          // the buttons and the d-pad
          t->joystick_0 = (1u << 10) | (1u << 11); settle(false);
          want("Accel / Brake buttons", (t->accel << 8) | t->brake, 0xe0e0, mode, sw, 9, 4);
          t->joystick_0 = 1u << 1; settle(false);
          want("d-pad left held: the ramp, not the wheel", t->steer != st_an(40, 0), 1, mode, sw, 9, 5);
          t->joystick_0 = 0; settle(false);
          want("d-pad released: the wheel", t->steer, st_an(40, 0), mode, sw, 9, 5);
          t->paddle = 0x33; settle(false);
          want("paddle first", t->steer, 0x33, mode, sw, 9, 6);
          t->paddle = 0;
        }
      }
  printf("   wheel modes: %llu sweep checks, %llu failures\n", (unsigned long long)sweep_n, (unsigned long long)sweep_fail);
  // Standard (0) and the unused 3: every axis against the reference, every option
  uint64_t std_n = 0, std_f = 0;
  for (int mode : {0, 3})
    for (int opt = 0; opt < 16; ++opt) {
      t->st_wheel = mode; t->st_pedswap = opt & 1; t->st_rsteer = (opt >> 1) & 1; t->st_ssens = opt >> 2;
      for (int ax = 0; ax < 4; ++ax)
        for (int v = -128; v <= 127; ++v) {
          for (int o = 0; o < 2; ++o) {        // the other axes at rest, then at a wheel's B rest
            int r = o ? -127 : 0;
            int lx = ax == 0 ? v : 0, ly = ax == 1 ? v : r, rx = ax == 2 ? v : r, ry = ax == 3 ? v : 0;
            t->joy_analog = ax16(lx, ly); t->joy_ranalog = ax16(rx, ry);
            settle(false);
            int g[5] = {t->in0, t->in1, t->steer, t->accel, t->brake};
            int r_[5] = {t->r_in0, t->r_in1, t->r_steer, t->r_accel, t->r_brake};
            for (int i = 0; i < 5; ++i) { ++checks; ++std_n; if (g[i] != r_[i]) { ++mism; ++std_f; } }
          }
        }
    }
  printf("   Standard / 3 vs the 0f3cbc4 block: %llu checks, %llu differences\n",
         (unsigned long long)std_n, (unsigned long long)std_f);

  // Steering smoothing on the wheel's X (SYS_MHZ 1 copy: Wheel = one count / 1581 clocks)
  t->st_wheel = 1; t->st_pedswap = 0; t->st_rsteer = 0; t->st_ssens = 0; t->st_ssm = 2;
  t->joy_analog = 0; t->joy_ranalog = 0; settle(false);
  for (int i = 0; i < 200000; ++i) { t->eval(); edge(false); }
  t->eval();
  expect("smoothing Wheel, Wheel A, centred", t->f_steer, 0x80);
  t->joy_analog = ax16(127, 0);
  for (int i = 0; i < 1581 * 10 + 8; ++i) { t->eval(); edge(false); }
  t->eval();
  { int s_ = t->f_steer; bool ok_ = s_ >= 0x80 + 9 && s_ <= 0x80 + 11;
    expect("  ... wheel to full right, 10 slew steps: 0x8a +-1", ok_ ? 0x8a : s_, 0x8a); }
  for (int i = 0; i < 1581 * 100; ++i) { t->eval(); edge(false); }
  t->eval();
  expect("  ... settled at full lock", t->f_steer, 0xe0);
  t->st_ssm = 0; settle(false);

  // Desert Tank in the wheel modes (the SYS_MHZ 1 copy and the model agree on both)
  t->is_desert = 1; t->joystick_0 = 0; t->paddle = 0;
  t->rst_n = 0; t->eval(); areset(); edge(true); t->rst_n = 1;
  for (int mode = 1; mode <= 2; ++mode) {
    t->st_wheel = mode;
    int rest_ly = mode == 2 ? -127 : 0, rest_rx = mode == 2 ? -127 : 0;
    t->joy_analog = ax16(0, rest_ly); t->joy_ranalog = ax16(rest_rx, 0); settle(true);
    expect(mode == 1 ? "DT Wheel A rest: ACCEL idle" : "DT Wheel B rest: ACCEL idle", t->f_accel, 0x20);
    t->joy_analog = ax16(0, mode == 1 ? -127 : 127); settle(true);
    expect("  accelerator full: ACCEL 0xde", t->f_accel, 0xde);
    expect("  accelerator full: lever forward", t->f_in1, 0xfe);
    t->joy_analog = ax16(0, rest_ly);
    t->joy_ranalog = mode == 1 ? ax16(0, -127) : ax16(127, 0); settle(true);
    expect("  brake full: ACCEL 0xde (reverse drive)", t->f_accel, 0xde);
    expect("  brake full: lever reverse", t->f_in1, 0xff);
    t->joy_ranalog = ax16(rest_rx, 0); settle(true);
    expect("  released: ACCEL idle, lever stays", (t->f_accel << 8) | t->f_in1, 0x20ff);
    t->joy_analog = ax16(0, mode == 1 ? -10 : -107); settle(true);   // 10 of 127: inside the dead zone
    expect("  accelerator inside the dead zone: idle", t->f_accel, 0x20);
    t->joy_analog = ax16(0, rest_ly); settle(true);
  }
  t->st_wheel = 0; settle(true);
  printf("   %llu checks, %llu failures\n", (unsigned long long)(checks - k1), (unsigned long long)(mism - c3));

  bool ok = (mism == 0) && n_wa > 100000 && n_wb > 100000 && n_wcheck > 100000 && d > 1000 && m80.n_tstep > 10 && m1.n_tstep > 1000 && m1.n_slew > 1000
            && n_tuse > 100000 && n_wheel > 100000 && n_setrev > 100 && n_vr4 > 10;
  printf("%s\n", ok ? "PASS" : "FAIL");
  delete t;
  return ok ? 0 : 1;
}
