// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R870: VIRTUA COP 2'S GUNS, READ AS THE GAME READS THEM. tb_m2_vcop2_top is
// Model2.sv's 2A wiring (m2_vcop_guns V2 -> m2_315_5649 GUN, the triggers
// through m2_2a_inputs GUN); every value here is read on the i960's side of
// the 315-5649, the way vcop2 does in MAME 0.289 (sim/io/mame_m2_vcop2_play.lua):
// write the mux byte to offset 0x0a (CPU 0x01c00014, lane 0), read offset
// 0x0c (0x01c00018, lane 0); mux 0-8 every frame. The reference is MAME's
// model2.cpp: lightgun_mux_r / lightgun_data_r (mux 0-7 = P1_Y, P1_X, P2_Y,
// P2_X, low byte then high), lightgun_offscreen_r (mux >= 8: 0xfc | P2 << 1
// | P1, by int(span * 0.05f) on INPUT_PORTS_START(vcop2)'s ranges), and the
// crosshair MAME draws for a coordinate, floor((v - min) * dim / span).
//
//  1. THE STICK, every value of both axes of both guns (against the edges
//     and centre): units read back inside vcop2's ranges; each unit the
//     smallest whose MAME crosshair pixel is >= the core's crosshair pixel
//     (so it IS that pixel wherever one exists; X spans 493 units over 496
//     pixels, and 165 / 330 / 495 have none); the high bytes 0..3; the
//     off-screen byte by MAME's rule from the units read; c_on.
//  2. THE MOUSE: every pixel walked, both guns; 40,000 random packets per
//     aiming mode against accumulate-and-clamp; then ten screens' worth of
//     movement past each edge (an order of magnitude past it): clamped, the
//     edge unit, off-screen.
//  3. BUTTONS through ports B / C: IN0 (MAME's model2 IN0) and IN1 (the
//     triggers, joystick or mouse by the OSD mode) for random inputs.
//  4. RELOAD through the chip: the trigger is never read with the gun's
//     off-screen bit clear in the read just before it, and it does arrive.
//  5. THE MUX: every value 8..255 reads the off-screen byte; a machine reset
//     keeps the mux, power-on clears it to 0 (MAME: set at construction).
//  6. PLAYER 2's crosshair only in play; player 1's always (R850).
#include "Vtb_m2_vcop2_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <random>

static Vtb_m2_vcop2_top* d;
static long fails = 0, checks = 0;
static void tick(int n = 1) {
  while (n--) { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }
}
#define CHECK(c, ...) do { checks++; if (!(c)) { if (fails++ < 25) { printf("FAIL: " __VA_ARGS__); printf("\n"); } } } while (0)

struct Rng { int lo, hi; };
static const Rng P1X{137, 630}, P1Y{36, 425}, P2X{134, 627}, P2Y{36, 425};   // INPUT_PORTS_START(vcop2)
static int border(const Rng& r) { return int(float(r.hi - r.lo) * 0.05f); }  // lightgun_offscreen_r
static bool offr(int v, const Rng& r) { return v <= r.lo + border(r) || v >= r.hi - border(r); }
static int mame_px(int v, const Rng& r, int dim) { return (v - r.lo) * dim / (r.hi - r.lo); }
static int want_unit(int px, const Rng& r, int dim) {      // smallest unit on pixel px or the next
  for (int v = r.lo; v <= r.hi; v++) if (mame_px(v, r, dim) >= px) return v;
  return r.hi;
}

// ---- the i960's side
static void bus_write(int word, int be, uint32_t data) {
  d->sel = 1; d->we = 1; d->word = word; d->be = be; d->wdata = data; tick(); d->sel = 0; d->we = 0;
}
static uint32_t bus_read(int word, int be) {
  d->sel = 1; d->we = 0; d->word = word; d->be = be; d->eval();
  uint32_t v = d->rdata; tick(); d->sel = 0; return v;
}
static int gun_rd(int mux) { bus_write(5, 0x1, uint32_t(mux)); return bus_read(6, 0x1) & 0xff; }
struct Gun { int p1y, p1x, p2y, p2x, off; bool hi_ok; };
static Gun read_guns() {
  int b[9];
  for (int k = 0; k < 9; k++) b[k] = gun_rd(k);
  Gun g;
  g.p1y = b[0] | b[1] << 8; g.p1x = b[2] | b[3] << 8; g.p2y = b[4] | b[5] << 8; g.p2x = b[6] | b[7] << 8;
  g.off = b[8];
  g.hi_ok = b[1] < 4 && b[3] < 4 && b[5] < 4 && b[7] < 4;
  return g;
}
static int port_b() { return (bus_read(0, 0x4) >> 16) & 0xff; }   // offset 1: IN0
static int port_c() { return bus_read(1, 0x1) & 0xff; }           // offset 2: IN1

static void set_ana(int p, int x, int y) {
  uint16_t w = uint16_t(((y & 0xff) << 8) | (x & 0xff));
  if (p == 0) d->ana0 = w; else d->ana1 = w;
}

// the units, the off-screen byte and c_on for the pixels the core aims at
static void check_aim(const char* what, int a, int b) {
  Gun g = read_guns();
  int px[4] = {d->c1x, d->c1y, d->c2x, d->c2y};
  int q[4] = {g.p1x, g.p1y, g.p2x, g.p2y};
  const Rng* r[4] = {&P1X, &P1Y, &P2X, &P2Y};
  int dims[4] = {496, 384, 496, 384};
  CHECK(g.hi_ok, "%s %d %d: a high byte above 3", what, a, b);
  for (int k = 0; k < 4; k++) {
    CHECK(q[k] >= r[k]->lo && q[k] <= r[k]->hi, "%s %d %d axis %d: %d outside %d..%d", what, a, b, k, q[k], r[k]->lo, r[k]->hi);
    int w = want_unit(px[k], *r[k], dims[k]);
    CHECK(q[k] == w, "%s %d %d axis %d: pixel %d read %d want %d (MAME pixel %d)", what, a, b, k, px[k], q[k], w,
          mame_px(q[k], *r[k], dims[k]));
    int mp = mame_px(q[k], *r[k], dims[k]);
    CHECK(mp == px[k] || (k % 2 == 0 && mp == px[k] + 1 && (px[k] == 165 || px[k] == 330 || px[k] == 495)),
          "%s %d %d axis %d: MAME draws %d for the core's %d", what, a, b, k, mp, px[k]);
  }
  bool o1 = offr(g.p1x, P1X) || offr(g.p1y, P1Y), o2 = offr(g.p2x, P2X) || offr(g.p2y, P2Y);
  CHECK(g.off == (0xfc | o1 | (o2 << 1)), "%s %d %d: off byte %02x want %02x", what, a, b, g.off, 0xfc | o1 | (o2 << 1));
  CHECK(d->c_on == unsigned((!o1) | ((!o2) << 1)), "%s %d %d: c_on %d (o1 %d o2 %d)", what, a, b, d->c_on, o1, o2);
}

static int tg = 0;
static void mouse(int dx, int dy, int btn = 0) {
  tg ^= 1;
  d->ps2_mouse = (uint32_t(tg) << 24) | (uint32_t(dy & 0xff) << 16) | (uint32_t(dx & 0xff) << 8)
               | ((dy < 0) << 5) | ((dx < 0) << 4) | 0x08 | (btn & 7);
  tick(8);
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vtb_m2_vcop2_top;
  d->por_n = 0; d->rst_n = 0; d->play = 3; d->joy0 = 0; d->joy1 = 0; d->ana0 = 0; d->ana1 = 0;
  d->ps2_mouse = 0; d->mouse_sel = 0; d->sel = 0;
  tick(4); d->por_n = 1; d->rst_n = 1; tick(8);

  // ---------------------------------------------------------- 0. rest, centre
  {
    Gun g = read_guns();   // sticks at 0: the centre of the screen
    printf("centre stick: P1 (%d,%d) P2 (%d,%d) off %02x\n", g.p1x, g.p1y, g.p2x, g.p2y, g.off);
    CHECK(g.p1x == 384 && g.p1y == 231 && g.p2x == 381 && g.p2y == 231 && g.off == 0xfc,
          "centre: P1 (%d,%d) P2 (%d,%d) off %02x", g.p1x, g.p1y, g.p2x, g.p2y, g.off);
  }
  // ---------------------------------------------------------- 1. the stick
  for (int a = -128; a <= 127; a++) {
    for (int b = -128; b <= 127; b++) {
      if (b != a && b != -a && b != 0 && b != 127 && b != -128) continue;
      set_ana(0, a, b); set_ana(1, b, a); tick(8);
      int u = a + 128, v = b + 128;
      CHECK(d->c1x == unsigned(u * 496 / 256) && d->c1y == unsigned(v * 384 / 256) &&
            d->c2x == unsigned(v * 496 / 256) && d->c2y == unsigned(u * 384 / 256),
            "stick %d %d: crosshair (%d,%d)(%d,%d)", a, b, d->c1x, d->c1y, d->c2x, d->c2y);
      check_aim("stick", a, b);
    }
  }
  set_ana(0, -127, -127); set_ana(1, 127, 127); tick(8);
  CHECK((gun_rd(8) & 3) == 3, "a calibrated gun at +-127 must read off-screen");

  // ---------------------------------------------------------- 2. the mouse
  std::mt19937 rng(870);
  for (int sel : {1, 3}) {
    d->mouse_sel = sel; set_ana(0, 40, -30); set_ana(1, -70, 90); tick(8);
    for (int k = 0; k < 4; k++) mouse(-255, 255);          // to the top-left corner
    for (int x = 0; x <= 495; x++) {
      if (x) mouse(1, 0);
      int cx = sel == 1 ? d->c1x : d->c2x, cy = sel == 1 ? d->c1y : d->c2y;
      CHECK(cx == unsigned(x) && cy == 0, "walk x sel %d: (%d,%d) want (%d,0)", sel, cx, cy, x);
      check_aim("walk x", sel, x);
    }
    for (int y = 1; y <= 383; y++) {
      mouse(0, -1);
      int cy = sel == 1 ? d->c1y : d->c2y;
      CHECK(cy == unsigned(y), "walk y sel %d: %d want %d", sel, cy, y);
      check_aim("walk y", sel, y);
    }
    int mx = 495, my = 383;
    for (int i = 0; i < 40000; i++) {
      int dx = int(rng() % 511) - 255, dy = int(rng() % 511) - 255;
      if (rng() % 4 == 0) { dx = int(rng() % 9) - 4; dy = int(rng() % 9) - 4; }
      mouse(dx, dy);
      mx += dx; my -= dy;
      mx = mx < 0 ? 0 : mx > 495 ? 495 : mx;
      my = my < 0 ? 0 : my > 383 ? 383 : my;
      int cx = sel == 1 ? d->c1x : d->c2x, cy = sel == 1 ? d->c1y : d->c2y;
      CHECK(cx == unsigned(mx) && cy == unsigned(my), "mouse sel %d pkt %d: (%d,%d) want (%d,%d)", sel, i, cx, cy, mx, my);
      if (i % 16 == 0) check_aim("mouse", sel, i);
    }
    // ten screens past each edge, 255 a packet
    struct { int dx, dy; int ux1, uy1, ux2, uy2; const char* n; } edge[4] = {
      {255, 0, 630, -1, 627, -1, "right"}, {-255, 0, 137, -1, 134, -1, "left"},
      {0, 255, -1, 36, -1, 36, "top"}, {0, -255, -1, 424, -1, 424, "bottom"}};
    // (the bottom line, 383, is unit 424: 425 is MAME's pixel 384, below the
    // screen -- Virtua Cop's Y the same; the right column, 495, has no unit of
    // its own and takes 630 / 627, the next pixel's)
    for (auto& e : edge) {
      for (int k = 0; k < (e.dx ? 4960 : 3840) / 255 + 1; k++) mouse(e.dx, e.dy);
      Gun g = read_guns();
      int ux = sel == 1 ? g.p1x : g.p2x, uy = sel == 1 ? g.p1y : g.p2y;
      int wx = sel == 1 ? e.ux1 : e.ux2, wy = sel == 1 ? e.uy1 : e.uy2;
      if (wx >= 0) CHECK(ux == wx, "mouse sel %d ten screens %s: X %d want %d", sel, e.n, ux, wx);
      if (wy >= 0) CHECK(uy == wy, "mouse sel %d ten screens %s: Y %d want %d", sel, e.n, uy, wy);
      CHECK((g.off >> (sel == 1 ? 0 : 1)) & 1, "mouse sel %d ten screens %s: not off-screen (%02x)", sel, e.n, g.off);
      CHECK(!((d->c_on >> (sel == 1 ? 0 : 1)) & 1), "mouse sel %d %s: crosshair still drawn", sel, e.n);
      check_aim("edge", sel, e.dx * 1000 + e.dy);
      printf("mouse gun %d, ten screens %-6s: P%d (%d,%d) off %02x\n", sel == 1 ? 1 : 2, e.n, sel == 1 ? 1 : 2, ux, uy, g.off);
    }
  }

  // ---------------------------------------------------------- 3. buttons
  d->mouse_sel = 0; set_ana(0, 0, 0); set_ana(1, 0, 0);
  for (int i = 0; i < 20000; i++) {
    int sel = rng() & 3;
    uint16_t j0 = uint16_t(rng()) & 0x03d0, j1 = uint16_t(rng()) & 0x03d0;   // no reload here
    int mb = rng() & 1;
    d->mouse_sel = sel; d->joy0 = j0; d->joy1 = j1;
    tg ^= 0; d->ps2_mouse = (d->ps2_mouse & ~7u) | mb;
    tick(12);
    int t1 = ((j0 >> 4) & 1) | (!(sel & 2) && mb), t2 = ((j1 >> 4) & 1) | ((sel & 2) && mb);
    // model2 IN0: coin1 coin2 test service start1 start2 (Virtua Cop's MRA order)
    int in0 = ~(((j1 >> 6) & 1) << 5 | ((j0 >> 6) & 1) << 4 | ((j0 >> 9) & 1) << 3 | ((j0 >> 8) & 1) << 2
               | ((j1 >> 7) & 1) << 1 | ((j0 >> 7) & 1)) & 0xff;
    int in1 = ~(t2 << 1 | t1) & 0xff;
    int b = port_b(), c = port_c();
    CHECK(b == in0 && c == in1, "buttons j0 %03x j1 %03x mb %d sel %d: IN0 %02x IN1 %02x want %02x %02x", j0, j1, mb, sel, b, c, in0, in1);
  }
  d->joy0 = 0; d->joy1 = 0; d->ps2_mouse &= ~7u; tick(12);

  // ---------------------------------------------------------- 4. reload, through the chip
  set_ana(0, 10, 10); set_ana(1, -10, -10); d->mouse_sel = 0; tick(8);
  long trig_seen[2] = {0, 0}, bad[2] = {0, 0}, presses[2] = {0, 0};
  int held[2] = {0, 0};
  for (int i = 0; i < 300000; i++) {
    if (rng() % 1000 == 0) {
      int p = rng() & 1; held[p] ^= 1; if (held[p]) presses[p]++;
      if (p == 0) { if (rng() & 1) d->joy0 = held[0] ? 0x20 : 0; else d->ps2_mouse = (d->ps2_mouse & ~7u) | (held[0] ? 2 : 0); }
      else d->joy1 = held[1] ? 0x20 : 0;
      if (!held[0]) { d->joy0 = 0; d->ps2_mouse &= ~7u; }
    }
    int off = gun_rd(8);          // the off-screen byte, then IN1 the next cycle
    int c = port_c();
    for (int p = 0; p < 2; p++) {
      if (!((c >> p) & 1)) { trig_seen[p]++; if (!((off >> p) & 1)) bad[p]++; }
    }
  }
  CHECK(bad[0] == 0 && bad[1] == 0, "reload: trigger read with the gun on the screen %ld / %ld", bad[0], bad[1]);
  CHECK(trig_seen[0] > 0 && trig_seen[1] > 0, "reload: the trigger never arrived (%ld %ld)", trig_seen[0], trig_seen[1]);
  printf("reload through the 315-5649: %ld / %ld presses, trigger read %ld / %ld times, on the screen %ld / %ld\n",
         presses[0], presses[1], trig_seen[0], trig_seen[1], bad[0], bad[1]);
  d->joy0 = 0; d->joy1 = 0; d->ps2_mouse &= ~7u; tick(4000);
  CHECK(gun_rd(8) == 0xfc && port_c() == 0xff, "after reload: still off-screen or firing");

  // ---------------------------------------------------------- 5. the mux
  {
    int ref = gun_rd(8);
    for (int m = 8; m < 256; m++) { int v = gun_rd(m); CHECK(v == ref, "mux %02x read %02x want %02x", m, v, ref); }
    bus_write(5, 0x1, 2);         // P1_X low byte selected
    int lo = bus_read(6, 0x1) & 0xff;
    d->rst_n = 0; tick(4); d->rst_n = 1; tick(8);   // a machine reset keeps the mux
    int after = bus_read(6, 0x1) & 0xff;
    CHECK(after == lo, "machine reset: mux lost (read %02x, was %02x)", after, lo);
    bus_write(5, 0x4, 0x0800);    // lane 2 (offset 0x0b) is not the mux
    CHECK((bus_read(6, 0x1) & 0xff) == lo, "a lane-2 write moved the mux");
    Gun g = read_guns();          // leaves the mux at 8
    d->por_n = 0; tick(2); d->por_n = 1; tick(2);   // power-on: mux 0 = P1_Y's low byte
    CHECK((bus_read(6, 0x1) & 0xff) == (g.p1y & 0xff), "power-on: mux not 0");
  }

  // ---------------------------------------------------------- 6. in play
  set_ana(0, 0, 0); set_ana(1, 0, 0);
  for (int pl = 0; pl < 4; pl++) {
    d->play = pl; tick(8);
    CHECK(d->c_on == unsigned(1 | (pl & 2)), "play %d: c_on %d (R850: P1 always)", pl, d->c_on);
  }

  printf("tb_m2_vcop2_guns: %ld checks, %ld failures\n", checks, fails);
  printf(fails ? "FAIL\n" : "PASS\n");
  delete d;
  return fails ? 1 : 0;
}
