// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R658: m2_raster_fill with M2COV = 1 against MAME's own coverage rule
// (devices/video/poly.h, which model2_v.cpp renders every polygon with): rows
// round(ymin) .. round(ymax)-1, each sampled at its CENTRE y + 0.5; on a row,
// the pixels [round(xl), round(xr)) between the edges crossing that centre;
// round(v) = floor(v) + (frac > 1/2). Vertices carry quarter pixels (FRB 2),
// as the geometry hands them over. Every span of every quad is checked, the
// directed cases first -- the frame-1000 pair whose shared, nearly horizontal
// edge gave a whole row to the wrong polygon -- then random convex quads and
// triangles (a triangle is a quad with a repeated vertex, as the clipper emits).
//
// R944: built with -GDIL=1 -DTB_DIL, the rule with each edge moved outward by
// (1 + |dx/dy|) / 8 px, clamped to the edge's own x extent +/- 1/8, and a
// T-JUNCTION test: one quad above a long edge, two below it sharing a vertex
// that lies ON the edge in floats, every vertex rounded to quarters as the
// geometry rounds them; a pixel the exact-float picture covers that none of
// the three does, with both neighbours across it covered, is a crack. With
// DIL there must be none; without it (the default build) the count is
// printed, and is not zero -- the failure the test exists to catch.
#include "Vm2_raster_fill.h"
#include "verilated.h"
#include "Vm2_raster_fill___024root.h"
#include <cstdlib>
#include <string>
#include <cstdio>
#include <cstdint>
#include <cmath>
#include <vector>
#include <map>
#include <random>
#include <algorithm>

static Vm2_raster_fill *d;
static long checks = 0, fails = 0, g_ties = 0;
static void tick() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }

static int mround(double v) { double ip = std::floor(v); return int(ip) + ((v - ip) > 0.5 ? 1 : 0); }

// MAME's rule for a convex polygon given in quarter pixels
// rows whose left or right end falls exactly on a half pixel -- a rounding tie,
// where 16.16 slope steps and MAME's floats may land either side of 1/2
static std::map<int, int> g_tie;   // row -> bit0 left tie, bit1 right tie
static const double TIEW = std::getenv("TIEW") ? atof(std::getenv("TIEW")) : 1e-3;
static long g_cracks = 0, g_tj = 0;   // R944
static std::map<int, std::pair<int,int>> ref(const int xq[4], const int yq[4], int vx1, int vx2, int vy1, int vy2) {
  std::map<int, std::pair<int,int>> out; g_tie.clear();
  double x[4], y[4], ymin = 1e9, ymax = -1e9;
  for (int i = 0; i < 4; i++) { x[i] = xq[i] / 4.0; y[i] = yq[i] / 4.0; ymin = std::min(ymin, y[i]); ymax = std::max(ymax, y[i]); }
  for (int r = mround(ymin); r < mround(ymax); r++) {
    if (r < vy1 || r > vy2) continue;
    const double c = r + 0.5;
    double lo = 1e9, hi = -1e9; bool any = false;
    double lo0 = 1e9, hi0 = -1e9, slo = 0, shi = 0;   // R944: the undilated ends and slopes, which pick the edges
    (void)lo0; (void)hi0; (void)slo; (void)shi;
    for (int i = 0; i < 4; i++) {
      const int j = (i + 1) & 3;
      const double ya = y[i], yb = y[j];
      if (ya == yb) continue;
      const double t0 = std::min(ya, yb), t1 = std::max(ya, yb);
      if (!(c >= t0 && c < t1)) continue;
      const double xc = x[i] + (c - ya) * (x[j] - x[i]) / (yb - ya);
#ifdef TB_DIL
      // R944: the edge moved out, within its own extent +/- 1/8. Which edge is
      // the left one at a shared x (the top vertex's row) goes by the slope,
      // as the fill's swapf decides it: the smaller dx/dy is the left edge.
      const double sl = (x[j] - x[i]) / (yb - ya);
      const double dg = (1.0 + std::fabs(sl)) / 8.0;
      const double el = std::min(x[i], x[j]) - 0.125, eh = std::max(x[i], x[j]) + 0.125;
      if (!any || xc < lo0 || (xc == lo0 && sl < slo)) { lo0 = xc; slo = sl; lo = std::max(xc - dg, el); }
      if (!any || xc > hi0 || (xc == hi0 && sl > shi)) { hi0 = xc; shi = sl; hi = std::min(xc + dg, eh); }
      any = true;
#else
      lo = std::min(lo, xc); hi = std::max(hi, xc); any = true;
#endif
    }
    if (!any) continue;
    auto tie = [](double v) { const double f = v - std::floor(v); return std::fabs(f - 0.5) < TIEW; };
    g_tie[r] = (tie(lo) ? 1 : 0) | (tie(hi) ? 2 : 0);
    int a = mround(lo), b = mround(hi) - 1;   // inclusive
    a = std::max(a, vx1); b = std::min(b, vx2);
    if (a <= b) out[r] = {a, b};
  }
  return out;
}

static std::map<int, std::pair<int,int>> run(const int xq[4], const int yq[4]) {
  auto fl = [](int q) { return q >= 0 ? q / 4 : -((-q + 3) / 4); };   // floor(q/4)
  d->in_x0 = fl(xq[0]); d->in_y0 = fl(yq[0]); d->in_x1 = fl(xq[1]); d->in_y1 = fl(yq[1]);
  d->in_x2 = fl(xq[2]); d->in_y2 = fl(yq[2]); d->in_x3 = fl(xq[3]); d->in_y3 = fl(yq[3]);
  uint32_t fr = 0;
  for (int i = 0; i < 4; i++) fr |= uint32_t(((yq[i] & 3) << 2) | (xq[i] & 3)) << (4 * i);
  d->in_frac = fr; d->in_col = 0x123456; d->in_moire = 0; d->in_tex = 0;
  d->in_u0 = d->in_v0 = d->in_u1 = d->in_v1 = d->in_u2 = d->in_v2 = d->in_u3 = d->in_v3 = 0;
  d->in_oz0 = d->in_oz1 = d->in_oz2 = d->in_oz3 = 0x7f00;
  for (int i = 0; i < 2000 && !d->in_ready; i++) tick();
  d->in_valid = 1; tick(); d->in_valid = 0;
  std::map<int, std::pair<int,int>> got;
  for (int i = 0; i < 200000; i++) {
    if (d->span_valid && d->span_ready) {
      const int y = (int16_t)d->span_y;
      if (got.count(y)) { std::printf("  row %d emitted twice\n", y); ++fails; }
      got[y] = {(int16_t)d->span_x0, (int16_t)d->span_x1};
    }
    const bool done = d->quad_done;
    static const bool TR = std::getenv("TRACE") != nullptr;
    if (TR) { auto *r = d->rootp; static int ls = -1;
      if (r->m2_raster_fill__DOT__state != ls) { ls = r->m2_raster_fill__DOT__state;
        std::printf("    symin %d symax %d td %d line %d\n", (int16_t)r->m2_raster_fill__DOT__symin, (int16_t)r->m2_raster_fill__DOT__symax, (int)r->m2_raster_fill__DOT__td_r, (int)d->line_case);
        std::printf("    st %2d cury %d seg_y1 %d limy %d walk_y %d walk_end %d xa %.3f xb %.3f sla %.4f slb %.4f ps1 %d ps2 %d needa %d needb %d\n", ls,
          (int16_t)r->m2_raster_fill__DOT__cury, (int16_t)r->m2_raster_fill__DOT__seg_y1, (int16_t)r->m2_raster_fill__DOT__limy,
          (int16_t)r->m2_raster_fill__DOT__walk_y, (int16_t)r->m2_raster_fill__DOT__walk_end,
          (int32_t)r->m2_raster_fill__DOT__xa / 65536.0, (int32_t)r->m2_raster_fill__DOT__xb / 65536.0,
          (int32_t)r->m2_raster_fill__DOT__sla / 65536.0, (int32_t)r->m2_raster_fill__DOT__slb / 65536.0,
          (int)r->m2_raster_fill__DOT__ps1, (int)r->m2_raster_fill__DOT__ps2, (int)r->m2_raster_fill__DOT__need_a, (int)r->m2_raster_fill__DOT__need_b); } }
    tick();
    if (done) { for (int k = 0; k < 8; k++) { if (d->span_valid && d->span_ready) got[(int16_t)d->span_y] = {(int16_t)d->span_x0, (int16_t)d->span_x1}; tick(); } break; }
  }
  return got;
}

static void check(const char *name, const int xq[4], const int yq[4], bool verbose) {
  auto want = ref(xq, yq, 0, 495, 0, 383);
  auto got = run(xq, yq);
  ++checks;
  // a row that differs only by one pixel at a tie end is a tie, not a fault
  bool real = false; long ties = 0;
  {
    std::map<int,int> rows; for (auto &w : want) rows[w.first] = 1; for (auto &g : got) rows[g.first] = 1;
    for (auto &r : rows) {
      auto a = want.find(r.first), b = got.find(r.first);
      if (a != want.end() && b != got.end() && a->second == b->second) continue;
      const int t = g_tie.count(r.first) ? g_tie[r.first] : 0;
      if (a != want.end() && b != got.end()) {
        const int dl = b->second.first - a->second.first, dr = b->second.second - a->second.second;
        if ((dl == 0 || ((t & 1) && std::abs(dl) == 1)) && (dr == 0 || ((t & 2) && std::abs(dr) == 1))) { ++ties; continue; }
      } else if (t) {   // a row of one pixel that exists on one side only, at a tie
        auto &p = (a != want.end()) ? a->second : b->second;
        if (p.first == p.second) { ++ties; continue; }
      }
      real = true;
    }
  }
  g_ties += ties;
  if (real) {
    ++fails;
    if (verbose || fails < 8) {
      std::printf("  FAIL %s  quad q(%d,%d) (%d,%d) (%d,%d) (%d,%d)\n", name, xq[0], yq[0], xq[1], yq[1], xq[2], yq[2], xq[3], yq[3]);
      std::map<int,int> rows;
      for (auto &w : want) rows[w.first] = 1;
      for (auto &g : got) rows[g.first] = 1;
      int shown = 0;
      for (auto &r : rows) {
        auto a = want.find(r.first), b = got.find(r.first);
        if (a != want.end() && b != got.end() && a->second == b->second) continue;
        std::printf("     row %d: MAME %s  ours %s\n", r.first,
          a == want.end() ? "-" : (std::to_string(a->second.first) + ".." + std::to_string(a->second.second)).c_str(),
          b == got.end() ? "-" : (std::to_string(b->second.first) + ".." + std::to_string(b->second.second)).c_str());
        if (++shown > 6) break;
      }
    }
  }
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_raster_fill;
  d->rst_n = 0; d->in_valid = 0; d->span_ready = 1;
#ifdef TB_DIL
  d->dil_on = 2;   // R957: the OSD's Seam fill All (the R944 rule under test)
#endif
  d->view_x1 = 0; d->view_x2 = 495; d->view_y1 = 0; d->view_y2 = 383;
  for (int i = 0; i < 10; i++) tick();
  d->rst_n = 1; tick();

  if (std::getenv("ONE")) {   // one quad from the command line: 8 quarter values
    int x[4], y[4]; for (int i = 0; i < 4; i++) { x[i] = atoi(argv[1 + 2*i]); y[i] = atoi(argv[2 + 2*i]); }
    check("one", x, y, true); delete d; return 0;
  }
  std::printf("test: directed quads\n");
  { int x[4] = {0, 400, 400, 0}, y[4] = {0, 0, 400, 400}; check("square 100x100", x, y, true); }
  { int x[4] = {1, 401, 401, 1}, y[4] = {3, 3, 403, 403}; check("square, quarter offsets", x, y, true); }
  // frame 1000's pair: 752 above the edge (-1,212.8727)-(204.6349,211.5943), 749 below
  { int x[4] = {535, 818, -4, -4}, y[4] = {783, 846, 851, 747}; check("f1000 poly 752 (quarters)", x, y, true); }
  { int x[4] = {1231, -4, -4, 818}, y[4] = {923, 1442, 851, 846}; check("f1000 poly 749 (quarters)", x, y, true); }
  { int x[4] = {100, 140, 120, 120}, y[4] = {100, 100, 160, 160}; check("triangle (repeated vertex)", x, y, true); }
  { int x[4] = {100, 300, 300, 100}, y[4] = {202, 202, 202, 202}; check("no height", x, y, true); }
  { int x[4] = {-40, 600, 600, -40}, y[4] = {-40, -40, 2000, 2000}; check("larger than the screen", x, y, true); }

  std::printf("test: random convex quads and triangles\n");
  std::mt19937 rng(7);
  const int N = argc > 1 ? atoi(argv[1]) : 3000;
  for (int n = 0; n < N; n++) {
    // a random triangle or a random convex quad from a rotated rectangle
    int x[4], y[4];
    const double cx = 40 + rng() % 420, cy = 20 + rng() % 340;
    const double w = 1 + rng() % 120, h = 0.25 + (rng() % 400) / 4.0, a = (rng() % 3600) / 3600.0 * 6.2832;
    const double ca = std::cos(a), sa = std::sin(a);
    const double px[4] = {-w, w, w, -w}, py[4] = {-h, -h, h, h};
    for (int i = 0; i < 4; i++) {
      x[i] = int(std::floor((cx + px[i] * ca - py[i] * sa) * 4));
      y[i] = int(std::floor((cy + px[i] * sa + py[i] * ca) * 4));
    }
    if (rng() % 3 == 0) { x[3] = x[2]; y[3] = y[2]; }   // triangle
    char nm[32]; std::snprintf(nm, sizeof nm, "random %d", n);
    check(nm, x, y, false);
  }
  // R944: T-junctions. A long edge P0-P1, a point M on it (floats); quad A
  // above it (P0, P1 and two points above), quads B1 (P0, M, below) and B2
  // (M, P1, below) under it. Vertices rounded to the nearest quarter, half
  // away from zero, as m2_geometry rounds them. The exact-float picture
  // (MAME's rule) of the three has no crack along the edge (M is on it).
  {
    std::printf("test: T-junctions (one edge above, two below)\n");
    const int NT = std::getenv("M2_TJ_N") ? atoi(std::getenv("M2_TJ_N")) : 2000;
    std::mt19937 rt(11);
    auto q4 = [](double c) { const long a = long(std::trunc(8.0 * std::fabs(c))); const int m = int((a + 1) >> 1); return c < 0 ? -m : m; };
    const int H = 384, W = 496;
    std::vector<uint8_t> ex(H * W), core(H * W);
    auto exact = [&](const double *x, const double *y, int n) {
      double ymin = 1e9, ymax = -1e9; for (int i = 0; i < n; i++) { ymin = std::min(ymin, y[i]); ymax = std::max(ymax, y[i]); }
      for (int r = std::max(mround(ymin), 0); r < std::min(mround(ymax), H); r++) {
        const double c = r + 0.5; double lo = 1e9, hi = -1e9; bool any = false;
        for (int i = 0; i < n; i++) { const int j = (i + 1) % n; if (y[i] == y[j]) continue;
          if (!(c >= std::min(y[i], y[j]) && c < std::max(y[i], y[j]))) continue;
          const double xc = x[i] + (c - y[i]) * (x[j] - x[i]) / (y[j] - y[i]); lo = std::min(lo, xc); hi = std::max(hi, xc); any = true; }
        if (!any) continue;
        for (int px = std::max(mround(lo), 0); px < std::min(mround(hi), W); px++) ex[r * W + px] = 1;
      }
    };
    for (int t = 0; t < NT; t++) {
      std::fill(ex.begin(), ex.end(), 0); std::fill(core.begin(), core.end(), 0);
      // the edge: shallow (most of them, as the shadow's) or steep
      const double ang = (rt() % 2 == 0) ? ((int(rt() % 600) - 300) / 300.0 * 0.12) : ((int(rt() % 3000) - 1500) / 1500.0 * 1.4);
      const double L = 80 + rt() % 300, cx = 150 + rt() % 200, cy = 100 + rt() % 180;
      const double ux = std::cos(ang), uy = std::sin(ang), nx = -uy, ny = ux;   // n points "below"
      const double P0x = cx - ux * L / 2 + (rt() % 1000) / 1000.0, P0y = cy - uy * L / 2 + (rt() % 1000) / 1000.0;
      const double P1x = P0x + ux * L, P1y = P0y + uy * L;
      const double f = 0.2 + (rt() % 600) / 1000.0, Mx = P0x + (P1x - P0x) * f, My = P0y + (P1y - P0y) * f;
      const double ha = 6 + rt() % 40, hb = 6 + rt() % 40;
      const double A[8] = {P0x, P0y, P1x, P1y, P1x - nx * ha, P1y - ny * ha, P0x - nx * ha, P0y - ny * ha};
      const double B1[8] = {P0x, P0y, P0x + nx * hb, P0y + ny * hb, Mx + nx * hb, My + ny * hb, Mx, My};
      const double B2[8] = {Mx, My, Mx + nx * hb, My + ny * hb, P1x + nx * hb, P1y + ny * hb, P1x, P1y};
      for (const double *Q : {A, B1, B2}) {
        double ex4[4], ey4[4]; int xq[4], yq[4];
        for (int i = 0; i < 4; i++) { ex4[i] = Q[2 * i]; ey4[i] = Q[2 * i + 1]; xq[i] = q4(ex4[i]); yq[i] = q4(ey4[i]); }
        exact(ex4, ey4, 4);
        auto got = run(xq, yq);
        for (auto &g : got) if (g.first >= 0 && g.first < H) for (int px = std::max(g.second.first, 0); px <= std::min(g.second.second, W - 1); px++) core[g.first * W + px] = 1;
      }
      ++g_tj;
      for (int r = 1; r < H - 1; r++) for (int px = 1; px < W - 1; px++) {
        const int k = r * W + px;
        if (ex[k] && !core[k] && ((core[k - 1] && core[k + 1]) || (core[k - W] && core[k + W]))) {
          if (g_cracks < 6) std::printf("  crack (%d,%d), T-junction %d: edge (%.3f,%.3f)-(%.3f,%.3f) M (%.3f,%.3f)\n", px, r, t, P0x, P0y, P1x, P1y, Mx, My);
          ++g_cracks;
        }
      }
    }
#ifdef TB_DIL
    if (g_cracks) ++fails;
    std::printf("  %ld T-junctions, %ld crack pixels (DIL: must be 0)\n", g_tj, g_cracks);
#else
    std::printf("  %ld T-junctions, %ld crack pixels (no DIL: the cracks R944 closes; not a failure here)\n", g_tj, g_cracks);
#endif
  }
  std::printf("m2_raster_fill M2COV%s: checks=%ld fails=%ld (rows differing only at an exact half-pixel tie: %ld)\n%s\n",
#ifdef TB_DIL
              " DIL",
#else
              "",
#endif
              checks, fails, g_ties, fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
