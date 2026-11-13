// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// m2_quad_store's tiny-quad test (R216, R233, R769), at the store itself.
//
// R769: the car-select tyres are rings of quads 2-3 px across, and TINY = 4
// refused 621 of the 1,340 quads on that screen -- the tyres went and the
// background showed through the wheel arches. The store now tests a list at
// TINY_FINE (2) when the list before it had fewer than 7/8 of NQ + NX quads passing
// that test, and at TINY (4) otherwise. This checks:
//   1. the size test at both thresholds, swept from 0 to 40 px of spread on
//      each axis and on the diagonal, at positive, negative and straddling
//      coordinates -- refused exactly when the spread is under the threshold
//      on BOTH axes, so a 1x1 quad is always refused;
//   2. a 32-quad tyre ring (every quad 2-3 px across): all stored at the fine
//      threshold, all refused at the coarse one;
//   3. the switch: power-up fine; a list with NQ - NQ/8 - 1 passing quads keeps
//      the next list fine, one more makes it coarse; heavy -> light is coarse
//      once and then fine; the heavy list at fine stores NQ and drops the rest;
//      the per-list count saturates instead of wrapping (lists of 5,000 and
//      50,000 quads).
// R1000: built with -GTINY_WHOLE=1 -DQS_WHOLE=1 (any NX), the WHOLE collection
// instead: after a list whose every offered quad fitted (NQ + NX), no size
// test until the count reaches 4/5 of the room, the fine test to 7/8, the
// coarse test past it; a list that did not fit falls back to R769 / R776.
// The quads are made here; nothing comes from a ROM.
#include "Vm2_quad_store.h"
#include "Vm2_quad_store___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cmath>
#include <vector>
#include <algorithm>
#include <utility>

static int checks = 0, fails = 0;
#define CHECK(c, ...) do { ++checks; if (!(c)) { ++fails; std::printf("  FAIL: " __VA_ARGS__); std::printf("\n"); } } while (0)

// R993: the switch is at 7/8 of the list's real room, NQ + NX (R962's spill).
// Build with -GNX=<n> -DQS_NX=<n> to test a spilling store; NX 0 is 1,792.
#ifndef QS_NX
#define QS_NX 0
#endif
static const int NQ = 2048, FINE_LIMIT = (NQ + QS_NX) - (NQ + QS_NX) / 8;   // 1,792 at NX 0
static const int T_COARSE = 4, T_FINE = 2;               // the instance's TINY / TINY_FINE

struct Q { int x[4], y[4]; };

static Vm2_quad_store *d;
static void tick() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }
static bool fine() { return d->rootp->m2_quad_store__DOT__fine; }

// A new list: the bank flips and `clear` pulses, as m2_raster3d's swap does.
static void new_list() {
  d->in_valid = 0; tick();
  d->wbank = !d->wbank; d->rbank = !d->wbank;
  d->clear = 1; tick(); d->clear = 0; tick();
}
static uint32_t g_zval = 1000;   // R1000: the quad's zval (R776's far test)
static void push(const Q &q) {
  d->in_valid = 1;
  d->in_x0 = q.x[0]; d->in_y0 = q.y[0]; d->in_x1 = q.x[1]; d->in_y1 = q.y[1];
  d->in_x2 = q.x[2]; d->in_y2 = q.y[2]; d->in_x3 = q.x[3]; d->in_y3 = q.y[3];
  d->in_z = 0x3F800000u | g_zval; d->in_col = 0xF80000;
  tick();
  d->in_valid = 0;
}
static void settle() { d->in_valid = 0; for (int k = 0; k < 4; k++) tick(); }

// the reference: refused when the integer spread is under t on both axes
static bool ref_tiny(const Q &q, int t) {
  int xl = q.x[0], xh = q.x[0], yl = q.y[0], yh = q.y[0];
  for (int k = 1; k < 4; k++) { xl = std::min(xl, q.x[k]); xh = std::max(xh, q.x[k]); yl = std::min(yl, q.y[k]); yh = std::max(yh, q.y[k]); }
  return (xh - xl) < t && (yh - yl) < t;
}

// one list of quads; returns {stored, tiny, dropped}
struct R { int stored, tiny, dropped; };
static R run_list(const std::vector<Q> &qs, bool open = true) {
  if (open) new_list();   // false: into the list next_fine_after() opened
  for (const Q &q : qs) push(q);
  settle();
  return R{(int)d->dbg_count, (int)d->dbg_tiny, (int)d->dbg_dropped};
}

// a quad of spread (sx, sy) at (x, y); shape 0 a box, 1 a diamond, 2 a sliver
static Q quad(int x, int y, int sx, int sy, int shape) {
  Q q;
  if (shape == 0) { int X[4] = {x, x + sx, x + sx, x}; int Y[4] = {y, y, y + sy, y + sy};
    for (int k = 0; k < 4; k++) { q.x[k] = X[k]; q.y[k] = Y[k]; } }
  else if (shape == 1) { int X[4] = {x + sx / 2, x + sx, x + sx - sx / 2, x}; int Y[4] = {y, y + sy / 2, y + sy, y + sy - sy / 2};
    for (int k = 0; k < 4; k++) { q.x[k] = X[k]; q.y[k] = Y[k]; } }
  else { int X[4] = {x, x + sx, x + sx, x + sx}; int Y[4] = {y, y + sy, y + sy, y + sy};
    for (int k = 0; k < 4; k++) { q.x[k] = X[k]; q.y[k] = Y[k]; } }
  return q;
}

// a tyre: 32 quads between radius 9 and 11 around (cx, cy), vertices rounded
static std::vector<Q> ring(int cx, int cy) {
  std::vector<Q> v;
  const int N = 32; const double ri = 9.0, ro = 11.0;
  for (int i = 0; i < N; i++) {
    const double a0 = 2 * M_PI * i / N, a1 = 2 * M_PI * (i + 1) / N;
    Q q;
    const double px[4] = {cx + ri * std::cos(a0), cx + ro * std::cos(a0), cx + ro * std::cos(a1), cx + ri * std::cos(a1)};
    const double py[4] = {cy + ri * std::sin(a0), cy + ro * std::sin(a0), cy + ro * std::sin(a1), cy + ri * std::sin(a1)};
    for (int k = 0; k < 4; k++) { q.x[k] = (int)std::lround(px[k]); q.y[k] = (int)std::lround(py[k]); }
    v.push_back(q);
  }
  return v;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_quad_store;
  d->clk = 0; d->rst_n = 0; d->clear = 0; d->wbank = 0; d->rbank = 1; d->in_valid = 0;
  d->sort_start = 0; d->replay_start = 0; d->replay_band = 0; d->out_ready = 0;
  d->in_moire = 0; d->in_tex = 0; d->in_frac = 0;
  d->in_u0 = d->in_v0 = d->in_u1 = d->in_v1 = d->in_u2 = d->in_v2 = d->in_u3 = d->in_v3 = 0;
  d->in_oz0 = d->in_oz1 = d->in_oz2 = d->in_oz3 = 0x7F00;
  d->ofree = (QS_NX > 0);   // R993: with a spill, the other bank is free here (nothing draws it)
  for (int k = 0; k < 4; k++) tick();
  d->rst_n = 1; tick();

  // ---- 3a. power-up: fine
  CHECK(fine(), "the store does not start at the fine threshold");
#ifdef QS_WHOLE
  {
    const int ROOM = NQ + QS_NX, ESC_F = ROOM - ROOM / 5, ESC_C = ROOM - ROOM / 8;
    auto whole = [&]() { return (bool)d->rootp->m2_quad_store__DOT__whole; };
    auto dots = [&](int n) { std::vector<Q> l; for (int i = 0; i < n; i++) l.push_back(quad(i % 400, 10 + (i / 400 % 100) * 3, (i % 3) == 0, (i % 5) == 0, 0)); return l; };
    auto twos = [&](int n, int y0) { std::vector<Q> l; for (int i = 0; i < n; i++) l.push_back(quad(i % 400, y0 + (i / 400 % 100) * 3, 2, 3, 0)); return l; };
    // 1. power-up is whole: a list of 1 px quads is stored, every one
    CHECK(whole(), "the store does not start whole");
    { const R r = run_list(dots(300)); CHECK(r.stored == 300 && r.tiny == 0, "dots after power-up: stored %d tiny %d, want 300 and 0", r.stored, r.tiny); }
    // 2. the tyre ring, whole
    { const R r = run_list(ring(200, 150)); CHECK(r.stored == 32 && r.tiny == 0, "tyre whole: stored %d tiny %d", r.stored, r.tiny); }
    // 3. a list of dots longer than the room: kept to ESC_F (one more at most, the
    // select is a register), refused from there for size, none for room
    for (int n : {ESC_F + 100, 3 * ROOM, 50000}) {
      run_list(ring(200, 150));
      CHECK(whole(), "not whole before %d dots", n);
      const R r = run_list(dots(n));
      std::printf("  R1000 %d dots after a light list: stored %d tiny %d dropped %d (ESC_F %d)\n", n, r.stored, r.tiny, r.dropped, ESC_F);
      CHECK(r.stored >= ESC_F && r.stored <= ESC_F + 1 && r.tiny == n - r.stored && r.dropped == 0,
            "%d dots whole: stored %d tiny %d dropped %d, want %d kept and the rest refused for size", n, r.stored, r.tiny, r.dropped, ESC_F);
      new_list();
      CHECK(whole() == (n < ROOM), "a list of %d quads offered (room %d) left the next list whole=%d", n, ROOM, (int)whole());
      CHECK(fine(), "a list of %d dots (none passing 2 px) left the next list coarse", n);
      d->in_valid = 0;
    }
    // 4. past ESC_C the coarse test: near 2-3 px quads are kept, far ones refused
    run_list(ring(200, 150)); run_list(ring(200, 150));
    {
      new_list();
      CHECK(whole(), "not whole before the escalation list");
      for (const Q &q : twos(ESC_C + 20, 500)) push(q);           // near (zval 1000): all kept
      g_zval = 0x3000;
      for (const Q &q : twos(100, 600)) push(q);                  // far: refused at coarse
      g_zval = 1000;
      settle();
      const R r{(int)d->dbg_count, (int)d->dbg_tiny, (int)d->dbg_dropped};
      std::printf("  R1000 %d near + 100 far 2-3 px quads: stored %d tiny %d dropped %d (ESC_C %d)\n", ESC_C + 20, r.stored, r.tiny, r.dropped, ESC_C);
      CHECK(r.stored == ESC_C + 20 && r.tiny == 100 && r.dropped == 0, "coarse past ESC_C: stored %d tiny %d dropped %d", r.stored, r.tiny, r.dropped);
    }
    // ...and the same far quads early in a whole list are kept
    run_list(ring(200, 150));
    { new_list(); g_zval = 0x3000; for (const Q &q : twos(100, 600)) push(q); g_zval = 1000; settle();
      CHECK((int)d->dbg_count == 100 && (int)d->dbg_tiny == 0, "far quads early in a whole list: stored %d tiny %d", (int)d->dbg_count, (int)d->dbg_tiny); }
    // 5. the boundary: ROOM - 1 offered keeps the next list whole, ROOM does not
    for (int n : {ROOM - 1, ROOM}) {
      run_list(ring(200, 150));
      run_list(twos(n, 300));
      new_list();
      CHECK(whole() == (n < ROOM), "after %d quads offered: whole %d", n, (int)whole());
      d->in_valid = 0;
    }
    // 6. not whole: R769 / R776 exactly -- after a heavy list of 2 px quads (it
    // passes the fine test) the next list is coarse and refuses far 2-3 px quads
    { run_list(twos(FINE_LIMIT + ROOM, 300));
      new_list(); CHECK(!whole() && !fine(), "after a heavy list: whole %d fine %d, want coarse", (int)whole(), (int)fine());
      g_zval = 0x3000; for (const Q &q : twos(50, 600)) push(q); g_zval = 1000; settle();
      CHECK((int)d->dbg_tiny == 50 && (int)d->dbg_count == 0, "far quads in a coarse list: stored %d tiny %d", (int)d->dbg_count, (int)d->dbg_tiny); }
    // a light list after it is not whole either (the heavy one did not fit) -- it
    // is the coarse one above; the list after THAT is whole again
    { const R r = run_list(dots(50)); CHECK(r.stored == 50 && r.tiny == 0, "dots, two lists after a heavy one: stored %d tiny %d", r.stored, r.tiny); }
    std::printf("m2_quad_store (R1000 WHOLE, NX %d): checks=%d fails=%d\n", QS_NX, checks, fails);
    std::printf(fails ? "FAIL\n" : "PASS\n");
    delete d;
    return fails ? 1 : 0;
  }
#endif

  // ---- 1. the size test at both thresholds
  auto sweep = [&](int t, const char *name) {
    int bad = 0, n = 0;
    const int org[4][2] = {{100, 100}, {-50, -60}, {-2, -1}, {490, 380}};
    for (int o = 0; o < 4; o++)
      for (int shape = 0; shape < 3; shape++)
        for (int sx = 0; sx <= 40; sx++)
          for (int sy = 0; sy <= 40; sy += (sy < 10 ? 1 : 5)) {
            std::vector<Q> one{quad(org[o][0], org[o][1], sx, sy, shape)};
            const R r = run_list(one);
            const bool want = ref_tiny(one[0], t);
            ++n;
            if ((r.tiny == 1) != want || (r.stored == 1) == want) {
              if (++bad <= 5) std::printf("  %s: spread %dx%d shape %d at (%d,%d): tiny %d stored %d, want %s\n",
                                          name, sx, sy, shape, org[o][0], org[o][1], r.tiny, r.stored, want ? "refused" : "stored");
            }
          }
    CHECK(bad == 0, "%s threshold: %d of %d single-quad lists decided wrongly", name, bad, n);
    std::printf("  %s threshold (%d px): %d quads, %d wrong\n", name, t, n, bad);
  };
  // every list above is a single quad, so the store stays fine throughout
  sweep(T_FINE, "fine");
  CHECK(fine(), "single-quad lists moved the store off the fine threshold");
  // 1x1 quads explicitly, at fine
  { const R r = run_list({quad(10, 10, 0, 0, 0), quad(10, 10, 1, 1, 0), quad(10, 10, 1, 0, 2)});
    CHECK(r.tiny == 3 && r.stored == 0, "1x1 quads at fine: tiny %d stored %d, want 3 and 0", r.tiny, r.stored); }

  // a heavy list (FINE_LIMIT quads of 2 px pass the fine test) makes the next coarse
  std::vector<Q> heavy;
  for (int i = 0; i < FINE_LIMIT; i++) heavy.push_back(quad(i % 400, 500 + (i / 400) * 3, 2, 2, 0));
  run_list(heavy);
  new_list();   // the heavy list's count decides here
  CHECK(!fine(), "a list of %d fine quads left the next list fine", FINE_LIMIT);
  // A list's threshold is fixed at its clear, and a one-quad list is light, so
  // the coarse sweep sends each quad in its own list straight after a heavy one.
  {
    int bad = 0, n = 0;
    for (int shape = 0; shape < 3; shape++)
      for (int s = 0; s <= 40; s += (s < 10 ? 1 : 10))
        for (int s2 = 0; s2 <= 8; s2++) {
          run_list(heavy);
          std::vector<Q> one{quad(-3, 7, s, s2, shape)};
          const R r = run_list(one);
          const bool want = ref_tiny(one[0], T_COARSE);
          ++n;
          if ((r.tiny == 1) != want) { if (++bad <= 5) std::printf("  coarse: spread %dx%d shape %d: tiny %d want %d\n", s, s2, shape, r.tiny, want); }
        }
    CHECK(bad == 0, "coarse threshold: %d of %d decided wrongly", bad, n);
    std::printf("  coarse threshold (%d px): %d quads, %d wrong\n", T_COARSE, n, bad);
  }

  // ---- 2. the tyre ring
  const std::vector<Q> tyre = ring(200, 150);
  { int lo = 99, hi = 0;
    for (const Q &q : tyre) { int xl = q.x[0], xh = q.x[0], yl = q.y[0], yh = q.y[0];
      for (int k = 1; k < 4; k++) { xl = std::min(xl, q.x[k]); xh = std::max(xh, q.x[k]); yl = std::min(yl, q.y[k]); yh = std::max(yh, q.y[k]); }
      const int s = std::max(xh - xl, yh - yl); lo = std::min(lo, s); hi = std::max(hi, s); }
    // the ring is the case only if every quad sits between the two thresholds
    CHECK(lo >= T_FINE && hi < T_COARSE, "the tyre's quads span %d..%d px, not inside [%d, %d)", lo, hi, T_FINE, T_COARSE);
    std::printf("  tyre: 32 quads spanning %d..%d px\n", lo, hi); }
  run_list(heavy);
  { const R r = run_list(tyre);   // coarse: the R233 behaviour, the fault
    CHECK(r.tiny == 32 && r.stored == 0, "tyre at coarse: tiny %d stored %d, want 32 and 0", r.tiny, r.stored); }
  { const R r = run_list(tyre);   // light after the coarse list: fine again
    CHECK(r.tiny == 0 && r.stored == 32, "tyre at fine: tiny %d stored %d, want 0 and 32", r.tiny, r.stored); }

  // ---- 3. the switch, at the boundary and past it
  // a list of n fine quads, then the NEXT list opened (its threshold decided
  // at that clear) and left open for run_list(.., false)
  auto next_fine_after = [&](int n) {
    std::vector<Q> l; for (int i = 0; i < n; i++) l.push_back(quad(i % 400, 500 + (i / 400 % 100) * 3, 2, 2, 0));
    const R r = run_list(l);
    new_list();
    return std::make_pair(fine(), r);
  };
  run_list(tyre);   // a light list: fine
  { auto p = next_fine_after(FINE_LIMIT - 1);
    CHECK(p.first, "%d fine quads made the next list coarse", FINE_LIMIT - 1);
    CHECK(p.second.stored == FINE_LIMIT - 1 && p.second.dropped == 0, "light list: stored %d dropped %d", p.second.stored, p.second.dropped); }
  { auto p = next_fine_after(FINE_LIMIT);
    CHECK(!p.first, "%d fine quads left the next list fine", FINE_LIMIT); }
  // light after heavy: that list is coarse, the one after it fine
  { const R r = run_list(tyre, false); CHECK(r.tiny == 32 && r.stored == 0, "light list after heavy not coarse: tiny %d", r.tiny); }
  { const R r = run_list(tyre); CHECK(r.tiny == 0 && r.stored == 32, "second light list after heavy not fine: tiny %d", r.tiny); }
  // heavy after light: collected fine, so it fills the store and drops the
  // tail; the next list is coarse
  for (int n : {2100 + QS_NX, 5000, 50000}) {
    run_list(tyre); run_list(tyre);   // fine for certain
    CHECK(fine(), "not fine before the heavy list of %d", n);
    auto p = next_fine_after(n);
    const int room = NQ + QS_NX;   // R993: the spill's room when the other bank is free
    CHECK(p.second.stored == room && p.second.dropped == n - room,
          "heavy list of %d at fine: stored %d dropped %d, want %d and %d", n, p.second.stored, p.second.dropped, room, n - room);
    CHECK(!p.first, "a list of %d quads (count saturating) left the next list fine", n);
    std::printf("  heavy list of %d after a light one: stored %d, dropped %d; next list fine=%d\n",
                n, p.second.stored, p.second.dropped, (int)p.first);
  }

  std::printf("m2_quad_store: checks=%d fails=%d\n", checks, fails);
  std::printf(fails ? "FAIL\n" : "PASS\n");
  delete d;
  return fails ? 1 : 0;
}
