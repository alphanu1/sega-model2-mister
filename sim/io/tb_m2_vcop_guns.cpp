// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// m2_vcop_guns (R846): MiSTer's sticks and mouse to Virtua Cop's gun ports.
//
//  1. THE STICK, every value of both axes of both guns: the crosshair pixel
//     is (a + 128) * 496 / 256 (x) and * 384 / 256 (y); the game units land
//     inside MAME's range and on the SAME pixel by the game's own rule
//     (floor((v - min) * dim / span), measured from its GUN MARK CHECK
//     screen, R846) -- every pixel 0..495 / 0..383 checked, not sampled;
//     R961: the off-screen bit is the crosshair's pixel within 2 of an edge
//     (x 0-1 / 494-495, y 0-1 / 382-383), not MAME model1io2 fpga_r's 5%
//     border (X 24, Y 19 units), which put 19-24 px of every edge out of play.
//  2. THE MOUSE: 200,000 random packets (deltas to +-255, both signs) in
//     every OSD mode against a model that accumulates and clamps; the gun the
//     mouse does not aim stays on its stick.
//  3. BUTTONS: IN0 / IN1 against MAME's vcop map for random joystick and
//     mouse buttons in every mouse mode.
//  4. RELOAD: random presses; the trigger it pulls is never seen while the
//     gun is on the screen (the property the cabinet's "shoot off-screen"
//     needs), it does arrive, and the gun leaves the corner afterwards.
//     The mouse's every pixel: the off bit and c_on by the same rule.
//  5. player 2 not in play (R849): no P2 crosshair; P1's always (R850). 6. en low: none.
#include "Vm2_vcop_guns.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <random>

static Vm2_vcop_guns* d;
static uint64_t cyc = 0;
static long fails = 0, checks = 0;
static void tick(int n = 1) {
  while (n--) { d->clk = 0; d->eval(); d->clk = 1; d->eval(); cyc++; }
}
#define CHECK(c, ...) do { checks++; if (!(c)) { if (fails++ < 20) { printf("FAIL: " __VA_ARGS__); printf("\n"); } } } while (0)

struct Rng { int lo, hi; };
static const Rng P1X{0x083, 0x276}, P1Y{0x024, 0x1a9}, P2X{0x080, 0x273}, P2Y{0x027, 0x1a9};
// R961: off the screen = within 2 px of an edge
static bool offp(int x, int y) { return x <= 1 || x >= 494 || y <= 1 || y >= 382; }
static long n_off = 0, n_on = 0;
static void check_off(const char* what, int a, int b) {
  bool o1 = offp(d->c1x, d->c1y), o2 = offp(d->c2x, d->c2y);
  n_off += o1 + o2; n_on += !o1 + !o2;
  CHECK(d->off == unsigned(o1 | (o2 << 1)), "%s %d %d: off %d want %d (P1 px %d,%d P2 px %d,%d)", what, a, b, d->off, o1 | (o2 << 1),
        d->c1x, d->c1y, d->c2x, d->c2y);
  CHECK(d->c_on == unsigned((!o1) | ((!o2) << 1)), "%s %d %d: c_on %d", what, a, b, d->c_on);
}
// the game's aim pixel for a coordinate (its GUN MARK CHECK, = MAME's crosshair pixel)
static int game_px(int v, const Rng& r, int dim) { return (v - r.lo) * dim / (r.hi - r.lo); }

static void set_ana(int p, int x, int y) {   // signed -128..127
  uint16_t w = uint16_t(((y & 0xff) << 8) | (x & 0xff));
  if (p == 0) d->ana0 = w; else d->ana1 = w;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_vcop_guns;
  d->rst_n = 0; d->en = 1; d->play = 3; d->joy0 = 0; d->joy1 = 0; d->ana0 = 0; d->ana1 = 0;
  d->ps2_mouse = 0; d->mouse_sel = 0;
  tick(4); d->rst_n = 1; tick(4);

  // ---------------------------------------------------------- 1. the stick
  for (int a = -128; a <= 127; a++) {
    for (int b = -128; b <= 127; b += 1) {
      if (b != a && b != -a && b != 0 && b != 127 && b != -127) continue;   // a's sweep against edges and centre
      set_ana(0, a, b); set_ana(1, b, a);
      tick(8);
      int u = a + 128, v = b + 128;
      int px1 = u * 496 / 256, py1 = v * 384 / 256, px2 = v * 496 / 256, py2 = u * 384 / 256;
      CHECK(d->c1x == px1 && d->c1y == py1 && d->c2x == px2 && d->c2y == py2,
            "stick a=%d b=%d: crosshair (%d,%d)(%d,%d) want (%d,%d)(%d,%d)", a, b, d->c1x, d->c1y, d->c2x, d->c2y, px1, py1, px2, py2);
      int q[4] = {d->p1x, d->p1y, d->p2x, d->p2y};
      const Rng* r[4] = {&P1X, &P1Y, &P2X, &P2Y};
      int pxs[4] = {d->c1x, d->c1y, d->c2x, d->c2y};
      int dims[4] = {496, 384, 496, 384};
      for (int k = 0; k < 4; k++) {
        CHECK(q[k] >= r[k]->lo && q[k] <= r[k]->hi, "a=%d b=%d axis %d: %03x outside %03x..%03x", a, b, k, q[k], r[k]->lo, r[k]->hi);
        CHECK(game_px(q[k], *r[k], dims[k]) == pxs[k], "a=%d b=%d axis %d: unit %03x is game pixel %d, crosshair %d",
              a, b, k, q[k], game_px(q[k], *r[k], dims[k]), pxs[k]);
      }
      check_off("stick", a, b);
    }
  }
  // every pixel, not only those the stick reaches: the unit chosen for a pixel
  // is the smallest the game draws on that pixel (mouse positions reach all)
  // -- checked through the mouse below; here the stick's edges:
  set_ana(0, -127, -127); set_ana(1, 127, 127); tick(8);
  CHECK((d->off & 3) == 3, "a calibrated gun at the edge (+-127) must read off-screen (off=%d)", d->off);
  // every edge alone: +-127 (and -128) on one axis is off, +-126 is on
  for (int e : {-128, -127, 127}) for (int ax = 0; ax < 2; ax++) {
    set_ana(0, ax ? 0 : e, ax ? e : 0); set_ana(1, ax ? 0 : e, ax ? e : 0); tick(8);
    CHECK(d->off == 3, "stick %d on axis %d: off %d, want 3 (px %d,%d)", e, ax, d->off, d->c1x, d->c1y);
  }
  for (int e : {-126, 126}) for (int ax = 0; ax < 2; ax++) {
    set_ana(0, ax ? 0 : e, ax ? e : 0); set_ana(1, ax ? 0 : e, ax ? e : 0); tick(8);
    CHECK(d->off == 0, "stick %d on axis %d: off %d, want 0 (px %d,%d)", e, ax, d->off, d->c1x, d->c1y);
  }
  // the edge units the game sees on the screen (MAME: each one is a shot)
  set_ana(0, -126, -126); set_ana(1, -126, -126); tick(8);
  printf("stick -126: px (%d,%d) units P1 %03x,%03x P2 %03x,%03x off %d\n", d->c1x, d->c1y, d->p1x, d->p1y, d->p2x, d->p2y, d->off);
  set_ana(0, 126, 126); set_ana(1, 126, 126); tick(8);
  printf("stick +126: px (%d,%d) units P1 %03x,%03x P2 %03x,%03x off %d\n", d->c1x, d->c1y, d->p1x, d->p1y, d->p2x, d->p2y, d->off);
  set_ana(0, 0, 0); set_ana(1, 0, 0); tick(8);
  CHECK(d->off == 0 && d->p1x == 0x17d && d->p1y == 0x0e7, "centre: off=%d p1 %03x,%03x", d->off, d->p1x, d->p1y);

  // ---------------------------------------------------------- 2. the mouse
  std::mt19937 rng(846);
  int mx = 248, my = 192, tg = 0;
  for (int sel = 0; sel < 4; sel++) {
    d->mouse_sel = sel; set_ana(0, 40, -30); set_ana(1, -70, 90); tick(8);
    for (int i = 0; i < 50000; i++) {
      int dx = int(rng() % 511) - 255, dy = int(rng() % 511) - 255;
      if (rng() % 4 == 0) { dx = int(rng() % 9) - 4; dy = int(rng() % 9) - 4; }
      tg ^= 1;
      uint32_t pk = (uint32_t(tg) << 24) | (uint32_t(dy & 0xff) << 16) | (uint32_t(dx & 0xff) << 8)
                  | ((dy < 0) << 5) | ((dx < 0) << 4) | 0x08;
      d->ps2_mouse = pk; tick(1 + rng() % 3);
      mx += dx; my -= dy;
      mx = mx < 0 ? 0 : mx > 495 ? 495 : mx;
      my = my < 0 ? 0 : my > 383 ? 383 : my;
      tick(6);
      int s1x = 40 + 128, s1y = -30 + 128, s2x = -70 + 128, s2y = 90 + 128;
      int w1x = (sel == 1) ? mx : s1x * 496 / 256, w1y = (sel == 1) ? my : s1y * 384 / 256;
      int w2x = (sel == 3) ? mx : s2x * 496 / 256, w2y = (sel == 3) ? my : s2y * 384 / 256;
      CHECK(d->c1x == w1x && d->c1y == w1y && d->c2x == w2x && d->c2y == w2y,
            "mouse sel %d pkt %d: (%d,%d)(%d,%d) want (%d,%d)(%d,%d)", sel, i, d->c1x, d->c1y, d->c2x, d->c2y, w1x, w1y, w2x, w2y);
      if (sel == 1 || sel == 3) {
        int ux = (sel == 1) ? d->p1x : d->p2x, uy = (sel == 1) ? d->p1y : d->p2y;
        const Rng& rx = (sel == 1) ? P1X : P2X; const Rng& ry = (sel == 1) ? P1Y : P2Y;
        CHECK(game_px(ux, rx, 496) == mx && game_px(uy, ry, 384) == my && ux >= rx.lo && ux <= rx.hi && uy >= ry.lo && uy <= ry.hi,
              "mouse pixel (%d,%d) -> units %03x,%03x -> game pixel (%d,%d)", mx, my, ux, uy, game_px(ux, rx, 496), game_px(uy, ry, 384));
      }
      check_off("mouse", sel, i);
    }
  }
  // every pixel through the mouse: walk x 0..495 and y 0..383 one step at a time
  for (int sel : {1, 3}) {
    d->mouse_sel = sel;
    const Rng& rx = (sel == 1) ? P1X : P2X; const Rng& ry = (sel == 1) ? P1Y : P2Y;
    for (int step = 0; step < 2; step++) {
      // slam to the top-left corner first
      for (int k = 0; k < 4; k++) { tg ^= 1; d->ps2_mouse = (uint32_t(tg) << 24) | (0x00u << 16) | (0x01u << 8) | (1 << 4) | 0x08; tick(8); }
      for (int k = 0; k < 4; k++) { tg ^= 1; d->ps2_mouse = (uint32_t(tg) << 24) | (0xffu << 16) | 0x08; tick(8); }
      // (dy = +255 moves up: clamps y to 0; dx = -255 clamps x to 0)
      mx = 0; my = 0;
      for (int k = 0; k < (step == 0 ? 495 : 383); k++) {
        tg ^= 1;
        d->ps2_mouse = step == 0 ? ((uint32_t(tg) << 24) | (0x01u << 8) | 0x08)                    // dx +1
                                 : ((uint32_t(tg) << 24) | (0xffu << 16) | (1 << 5) | 0x08);     // dy -1 (down)
        tick(8);
        if (step == 0) mx++; else my++;
        int ux = (sel == 1) ? d->p1x : d->p2x, uy = (sel == 1) ? d->p1y : d->p2y;
        int cx = (sel == 1) ? d->c1x : d->c2x, cy = (sel == 1) ? d->c1y : d->c2y;
        CHECK(cx == mx && cy == my, "walk sel %d: at (%d,%d) want (%d,%d)", sel, cx, cy, mx, my);
        CHECK(game_px(ux, rx, 496) == mx && game_px(uy, ry, 384) == my,
              "walk sel %d pixel (%d,%d): units %03x,%03x are game pixel (%d,%d)", sel, mx, my, ux, uy, game_px(ux, rx, 496), game_px(uy, ry, 384));
        check_off("walk", mx, my);
      }
    }
  }
  // R961: the off-screen edge through the mouse, across the middle of the
  // screen both ways (every pixel), and ten screens past each edge
  for (int sel : {1, 3}) {
    d->mouse_sel = sel;
    auto send = [&](int dx, int dy) {        // dy > 0 moves up
      tg ^= 1;
      d->ps2_mouse = (uint32_t(tg) << 24) | (uint32_t(dy & 0xff) << 16) | (uint32_t(dx & 0xff) << 8)
                   | ((dy < 0) << 5) | ((dx < 0) << 4) | 0x08;
      tick(8);
    };
    for (int k = 0; k < 4; k++) send(-255, 0);
    for (int k = 0; k < 4; k++) send(0, 255);        // (0, 0)
    send(0, -192);                                    // (0, 192)
    for (int x = 0; x <= 495; x++) {
      if (x) send(1, 0);
      int cx = (sel == 1) ? d->c1x : d->c2x, cy = (sel == 1) ? d->c1y : d->c2y;
      CHECK(cx == x && cy == 192, "edge walk x: at (%d,%d) want (%d,192)", cx, cy, x);
      int o = (d->off >> (sel == 1 ? 0 : 1)) & 1;
      CHECK(o == (x <= 1 || x >= 494), "edge walk x sel %d px %d: off %d", sel, x, o);
      check_off("edge walk x", sel, x);
    }
    for (int k = 0; k < 2; k++) send(-124, 0);       // (247, 192)
    send(1, 0);                                       // (248, 192)
    send(0, 192);                                     // (248, 0)
    for (int y = 0; y <= 383; y++) {
      if (y) send(0, -1);
      int cx = (sel == 1) ? d->c1x : d->c2x, cy = (sel == 1) ? d->c1y : d->c2y;
      CHECK(cx == 248 && cy == y, "edge walk y: at (%d,%d) want (248,%d)", cx, cy, y);
      int o = (d->off >> (sel == 1 ? 0 : 1)) & 1;
      CHECK(o == (y <= 1 || y >= 382), "edge walk y sel %d px %d: off %d", sel, y, o);
      check_off("edge walk y", sel, y);
    }
    const int ed[4][2] = {{255, 0}, {-255, 0}, {0, 255}, {0, -255}};
    for (auto& e : ed) {
      for (int k = 0; k < 4; k++) send(-e[0], -e[1]);   // back across
      for (int k = 0; k < 2; k++) send(e[0] ? (e[0] > 0 ? -1 : 1) : 0, 0);
      send(0, 0);
      for (int k = 0; k < 20; k++) send(e[0], e[1]);   // ten screens past the edge
      int o = (d->off >> (sel == 1 ? 0 : 1)) & 1;
      CHECK(o == 1, "mouse past edge (%d,%d) sel %d: off %d (px %d,%d)", e[0], e[1], sel, o,
            sel == 1 ? d->c1x : d->c2x, sel == 1 ? d->c1y : d->c2y);
      check_off("mouse past edge", e[0], e[1]);
    }
  }

  // ---------------------------------------------------------- 3. buttons
  for (int i = 0; i < 100000; i++) {
    int sel = rng() & 3;
    uint16_t j0 = uint16_t(rng()) & 0x03f0 & ~0x0020, j1 = uint16_t(rng()) & 0x03f0 & ~0x0020;   // no reload here
    int mb = rng() & 1;                 // left button only
    d->mouse_sel = sel; d->joy0 = j0; d->joy1 = j1;
    d->ps2_mouse = (d->ps2_mouse & ~7u) | mb;
    tick(8);
    int t1 = ((j0 >> 4) & 1) | (!(sel & 2) && mb), t2 = ((j1 >> 4) & 1) | ((sel & 2) && mb);
    int in0 = ~(((j1 >> 6) & 1) << 5 | ((j0 >> 6) & 1) << 4 | ((j0 >> 9) & 1) << 3 | ((j0 >> 8) & 1) << 2
               | ((j1 >> 7) & 1) << 1 | ((j0 >> 7) & 1)) & 0xff;
    int in1 = ~(t2 << 1 | t1) & 0xff;
    CHECK(d->in0 == in0 && d->in1 == in1, "buttons j0 %03x j1 %03x mb %d sel %d: in0 %02x in1 %02x want %02x %02x",
          j0, j1, mb, sel, d->in0, d->in1, in0, in1);
  }
  d->joy0 = 0; d->joy1 = 0; d->ps2_mouse &= ~7u;

  // ---------------------------------------------------------- 4. reload
  // TICK_LOG2 is small in this build; random presses of Reload (joystick bit 5
  // or the mouse's right button), the guns on the screen.
  set_ana(0, 10, 10); set_ana(1, -10, -10); d->mouse_sel = 0; tick(8);
  long seen_trig[2] = {0, 0}, bad[2] = {0, 0}, presses[2] = {0, 0};
  int held[2] = {0, 0};
  long early[2] = {0, 0}, late[2] = {0, 0}, off_run[2] = {0, 0}, after[2] = {-1, -1};
  bool was_trig[2] = {false, false};
  for (int i = 0; i < 2000000; i++) {
    if (rng() % 3000 == 0) {
      int p = rng() & 1; held[p] ^= 1; if (held[p]) presses[p]++;
      if (p == 0) { if (rng() & 1) d->joy0 = held[0] ? 0x20 : 0; else d->ps2_mouse = (d->ps2_mouse & ~7u) | (held[0] ? 2 : 0); }
      else d->joy1 = held[1] ? 0x20 : 0;
      if (!held[0]) { d->joy0 = 0; d->ps2_mouse &= ~7u; }
    }
    tick();
    for (int p = 0; p < 2; p++) {
      bool trig = !((d->in1 >> p) & 1), off = (d->off >> p) & 1;
      if (trig) { seen_trig[p]++; if (!off) bad[p]++; }
      // the I/O board reads the trigger and the coordinates at different
      // moments of a 1 ms scan, so the corner must lead the trigger and
      // outlast it by a tick (64 cycles here, 1.64 ms in the core)
      if (trig && !was_trig[p] && off_run[p] < 64) { early[p]++; }
      if (!trig && was_trig[p]) after[p] = 0;
      if (after[p] >= 0) { if (!off) { if (after[p] < 64) late[p]++; after[p] = -1; } else after[p]++; }
      off_run[p] = off ? off_run[p] + 1 : 0;
      was_trig[p] = trig;
    }
  }
  CHECK(early[0] == 0 && early[1] == 0, "reload: trigger pulled less than a tick after the corner (%ld %ld)", early[0], early[1]);
  CHECK(late[0] == 0 && late[1] == 0, "reload: corner left less than a tick after the trigger (%ld %ld)", late[0], late[1]);
  CHECK(bad[0] == 0 && bad[1] == 0, "reload: trigger seen on screen %ld / %ld cycles", bad[0], bad[1]);
  CHECK(seen_trig[0] > 0 && seen_trig[1] > 0, "reload: the trigger never arrived (%ld %ld)", seen_trig[0], seen_trig[1]);
  d->joy0 = 0; d->joy1 = 0; d->ps2_mouse &= ~7u; tick(2000);
  CHECK(d->off == 0 && d->in1 == 0xff, "after reload: off %d in1 %02x", d->off, d->in1);
  printf("reload: %ld / %ld presses, trigger held %ld / %ld cycles, 0 / 0 on the screen expected (%ld / %ld)\n",
         presses[0], presses[1], seen_trig[0], seen_trig[1], bad[0], bad[1]);

  // ---------------------------------------------------------- 5. in play (R849)
  set_ana(0, 0, 0); set_ana(1, 0, 0);
  for (int pl = 0; pl < 4; pl++) {
    d->play = pl; tick(8);
    CHECK(d->c_on == unsigned(1 | (pl & 2)), "play %d: c_on %d (R850: P1 always)", pl, d->c_on);
  }
  d->play = 3;
  // ---------------------------------------------------------- 6. en low
  d->en = 0; tick(8);
  CHECK(d->c_on == 0, "en low: c_on %d", d->c_on);

  printf("off-screen rule (R961): %ld gun samples off, %ld on\n", n_off, n_on);
  printf("tb_m2_vcop_guns: %ld checks, %ld failures\n", checks, fails);
  printf(fails ? "FAIL\n" : "PASS\n");
  delete d;
  return fails ? 1 : 0;
}
