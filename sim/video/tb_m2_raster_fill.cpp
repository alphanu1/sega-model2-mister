// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE for the full text.
//
// Reference is a transcription of MAME's fill_quad / fill_slope / fill_line
// (BSD-3-Clause, Olivier Galibert) recording spans instead of writing pixels.
// See THIRD-PARTY.md and docs/m3-rasterizer-spec.md.
//
// What this is really aimed at:
//
//  * The slope division. C truncates toward zero; a floor-dividing RTL is one
//    LSB per scanline out on every left-leaning edge, which is a fraction of a
//    pixel on a small polygon and invisible unless the comparison is exact.
//    Every fuzz quad with a negative slope tests it.
//
//  * The half-open segment range. Emitting [y_top, y_bottom] instead of
//    [y_top, y_bottom) double-draws each internal vertex row — harmless-looking
//    on an opaque fill and visible through MOIRE stipple. Comparing the span
//    *sequence* rather than a painted bitmap is what catches it.
//
//  * The left/right decision being per segment rather than per scanline, which
//    only shows up on quads whose edges cross mid-segment. The fuzz generates
//    self-intersecting quads deliberately.
//
// Spans are compared in order, not as a painted image, so an extra or
// duplicated span fails even where it would paint the same pixels.

#include "Vm2_raster_fill.h"
#include "verilated.h"
#include <cstdio>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <random>
#include <vector>

// R424: THE FIT RUNS ON u/z, v/z AND 1/z NOW. Every quad below is given the
// SAME 1/z at all four vertices -- a flat-depth quad -- because these tests
// were written to check the plane fit and not the perspective divide, and a
// varying depth would make them measure the wrong thing.
//
// 1/z arrives as a minifloat {exponent, mantissa} and is normalised across the
// quad to ({1,mantissa} << 6) >> (emax - e). With all four equal the shift is
// zero, so mantissa 0 gives 1 << 14 = 16384, and u/z = u * 16384 >> 13 = 2u.
// Hence OZ_K: the gradients and plane values this fit produces are exactly
// twice what the affine one produced, and that factor is the test's business.
static const uint16_t OZ_FLAT = 0x7f00;   // exponent 127, mantissa 0
static const double   OZ_K    = 2.0;


// ------------------------------------------------------------------ reference

struct Span {
  int32_t y, x0, x1;
  bool operator!=(const Span& o) const { return y != o.y || x0 != o.x0 || x1 != o.x1; }
};

static int32_t VX1, VX2, VY1, VY2;
static std::vector<Span> ref_spans;

// int32 arithmetic that wraps rather than invoking UB, so the model and the RTL
// agree on the overflow cases the fuzz deliberately generates.
static inline int32_t addw(int32_t a, int32_t b) { return (int32_t)((uint32_t)a + (uint32_t)b); }
static inline int32_t subw(int32_t a, int32_t b) { return (int32_t)((uint32_t)a - (uint32_t)b); }
static inline int32_t mulw(int32_t a, int32_t b) { return (int32_t)((uint32_t)a * (uint32_t)b); }

// C division truncates toward zero. INT32_MIN / -1 overflows (and traps on
// x86), so it is folded to the wrapping answer the hardware produces.
static inline int32_t idiv(int32_t n, int32_t d) {
  if (d == 0) return 0;
  if (d == -1) return (int32_t)(0u - (uint32_t)n);
  return n / d;
}

static void ref_hline(int32_t x1, int32_t x2, int32_t y) {
  if (x1 <= x2) ref_spans.push_back({y, x1, x2});
}

static void ref_fill_line(int32_t y, int32_t x1, int32_t x2) {
  int32_t xx1 = x1 >> 16, xx2 = x2 >> 16;
  if (y > VY2 || y < VY1) return;
  if (xx1 <= VX2 || xx2 >= VX1) {
    if (xx1 < VX1) xx1 = VX1;
    if (xx2 > VX2) xx2 = VX2;
    ref_hline(xx1, xx2, y);
  }
}

static void ref_fill_slope(int32_t x1, int32_t x2, int32_t sl1, int32_t sl2,
                           int32_t y1, int32_t y2, int32_t* nx1, int32_t* nx2) {
  if (y1 > VY2) return;

  if (y2 <= VY1) {
    int32_t delta = subw(y2, y1);
    *nx1 = addw(x1, mulw(delta, sl1));
    *nx2 = addw(x2, mulw(delta, sl2));
    return;
  }

  if (y2 > VY2) y2 = VY2 + 1;

  if (y1 < VY1) {
    int32_t delta = subw(VY1, y1);
    x1 = addw(x1, mulw(delta, sl1));
    x2 = addw(x2, mulw(delta, sl2));
    y1 = VY1;
  }

  if (x1 > x2 || (x1 == x2 && sl1 > sl2)) {
    int32_t t = x1; x1 = x2; x2 = t;
    t = sl1; sl1 = sl2; sl2 = t;
    int32_t* tp = nx1; nx1 = nx2; nx2 = tp;
  }

  while (y1 < y2) {
    int32_t xx1 = x1 >> 16, xx2 = x2 >> 16;
    if (xx1 <= VX2 || xx2 >= VX1) {
      if (xx1 < VX1) xx1 = VX1;
      if (xx2 > VX2) xx2 = VX2;
      ref_hline(xx1, xx2, y1);
    }
    x1 = addw(x1, sl1);
    x2 = addw(x2, sl2);
    y1++;
  }

  *nx1 = x1;
  *nx2 = x2;
}

// Returns true for the wireframe case, which the filler flags and does not draw.
static bool ref_fill_quad(const int32_t* vx, const int32_t* vy) {
  ref_spans.clear();

  int32_t ax = vx[0], ay = vy[0], bx = ax, by = ay;
  int ndist = 1;
  for (int i = 1; i < 4; i++) {
    if (vx[i] == ax && vy[i] == ay) continue;
    if (ndist == 1) { bx = vx[i]; by = vy[i]; ndist = 2; }
    else if (vx[i] != bx || vy[i] != by) { ndist = 3; break; }
  }
  if (ndist == 2) return true;

  int32_t px[8], py[8];
  for (int i = 0; i < 4; i++) {
    px[i] = px[i + 4] = (int32_t)((uint32_t)vx[i] << 16);
    py[i] = py[i + 4] = vy[i];
  }

  int pmin = 0, pmax = 0;
  for (int i = 1; i < 4; i++) {
    if (py[i] < py[pmin]) pmin = i;
    if (py[i] > py[pmax]) pmax = i;
  }

  int32_t cury = py[pmin], limy = py[pmax];
  int32_t x1, x2;

  if (cury == limy) {
    x1 = px[0]; x2 = px[0];
    for (int i = 1; i < 4; i++) {
      if (px[i] < x1) x1 = px[i];
      if (px[i] > x2) x2 = px[i];
    }
    ref_fill_line(cury, x1, x2);
    return false;
  }

  if (cury > VY2) return false;
  if (limy <= VY1) return false;
  if (limy > VY2) limy = VY2;

  int ps1 = pmin + 4, ps2 = pmin;
  int32_t sl1 = 0, sl2 = 0;
  x1 = x2 = 0;

  // MAME jumps into the middle of the loop with `goto startup`; the flag says
  // the same thing without the goto.
  bool restart_both = true;
  for (;;) {
    if (restart_both) {
      while (py[ps1 - 1] == cury) ps1--;
      while (py[ps2 + 1] == cury) ps2++;
      x1  = px[ps1];
      x2  = px[ps2];
      sl1 = idiv(subw(x1, px[ps1 - 1]), subw(cury, py[ps1 - 1]));
      sl2 = idiv(subw(x2, px[ps2 + 1]), subw(cury, py[ps2 + 1]));
      restart_both = false;
    }

    if (py[ps1 - 1] == py[ps2 + 1]) {
      ref_fill_slope(x1, x2, sl1, sl2, cury, py[ps1 - 1], &x1, &x2);
      cury = py[ps1 - 1];
      if (cury >= limy) break;
      ps1--; ps2++;
      restart_both = true;
    } else if (py[ps1 - 1] < py[ps2 + 1]) {
      ref_fill_slope(x1, x2, sl1, sl2, cury, py[ps1 - 1], &x1, &x2);
      cury = py[ps1 - 1];
      if (cury >= limy) break;
      ps1--;
      while (py[ps1 - 1] == cury) ps1--;
      x1  = px[ps1];
      sl1 = idiv(subw(x1, px[ps1 - 1]), subw(cury, py[ps1 - 1]));
    } else {
      ref_fill_slope(x1, x2, sl1, sl2, cury, py[ps2 + 1], &x1, &x2);
      cury = py[ps2 + 1];
      if (cury >= limy) break;
      ps2++;
      while (py[ps2 + 1] == cury) ps2++;
      x2  = px[ps2];
      sl2 = idiv(subw(x2, px[ps2 + 1]), subw(cury, py[ps2 + 1]));
    }
  }

  if (cury == limy) ref_fill_line(cury, x1, x2);
  return false;
}

// ------------------------------------------------------------------- the DUT

static long checks = 0, fails = 0, printed = 0;
static long total_spans = 0, line_cases = 0, empty_quads = 0;

struct Dut {
  Vm2_raster_fill* d;
  std::mt19937* rng;
  std::vector<Span> spans;
  bool got_line = false;
  long cyc = 0;

  Dut(std::mt19937* r) : rng(r) {
    d = new Vm2_raster_fill;
    d->clk = 0; d->rst_n = 0; d->in_valid = 0; d->span_ready = 1;
    d->in_x0 = 0; d->in_y0 = 0; d->in_x1 = 0; d->in_y1 = 0;
    d->in_x2 = 0; d->in_y2 = 0; d->in_x3 = 0; d->in_y3 = 0;
    d->in_col = 0; d->in_moire = 0;
    d->eval();
    for (int i = 0; i < 4; i++) tick();
    d->rst_n = 1;
    tick();
  }
  ~Dut() { delete d; }

  void tick() {
    d->clk = 0; d->eval();
    d->clk = 1; d->eval();
    cyc++;
  }

  // Collect on the accepted beat, which is what the band buffer would see.
  void sample() {
    if (d->span_valid && d->span_ready)
      spans.push_back({(int32_t)d->span_y, (int32_t)d->span_x0, (int32_t)d->span_x1});
    if (d->line_case) got_line = true;
  }

  void set_viewport(int32_t x1, int32_t x2, int32_t y1, int32_t y2) {
    d->view_x1 = (uint32_t)x1; d->view_x2 = (uint32_t)x2;
    d->view_y1 = (uint32_t)y1; d->view_y2 = (uint32_t)y2;
  }

  // stall_pct exercises the span backpressure the band buffer will apply.
  bool run_quad(const int32_t* vx, const int32_t* vy, uint32_t col, bool moire,
                int stall_pct) {
    spans.clear();
    got_line = false;

    d->in_x0 = (uint32_t)vx[0]; d->in_y0 = (uint32_t)vy[0];
    d->in_x1 = (uint32_t)vx[1]; d->in_y1 = (uint32_t)vy[1];
    d->in_x2 = (uint32_t)vx[2]; d->in_y2 = (uint32_t)vy[2];
    d->in_x3 = (uint32_t)vx[3]; d->in_y3 = (uint32_t)vy[3];
    d->in_col = col;
    d->in_moire = moire ? 1 : 0;
    d->in_valid = 1;
    d->span_ready = 1;
    d->eval();

    // Handshake, then run to retire and *drain*. quad_done can be asserted in
    // the same cycle as the last span, so stopping at quad_done drops that span
    // whenever a stall lands on it — which then reappears at the head of the
    // next quad and reads as two unrelated failures. Backpressure is applied
    // only while the quad is still running.
    // THE STALL MODEL SHARES THE RNG WITH QUAD GENERATION, so anything that
    // changes how many cycles a quad takes reshuffles every later quad in the
    // corpus - and `spans`, `lines` and `empty` all move while `checks` and
    // `fails` stay put. Making the divider radix-4 did exactly that: 31,637,915
    // spans became 31,658,020 with nothing wrong. A moved total here is not a
    // regression on its own; a nonzero `fails` is.
    long guard = 0;
    bool accepted = false, retired = false;
    for (;;) {
      d->span_ready = (retired || !stall_pct)
                        ? 1
                        : (((int)((*rng)() % 100) >= stall_pct) ? 1 : 0);
      d->eval();

      sample();
      if (d->quad_done && accepted) retired = true;
      if (d->in_ready && d->in_valid) accepted = true;

      bool drained = retired && !d->span_valid;
      tick();
      if (accepted) { d->in_valid = 0; d->eval(); }
      if (drained) break;

      if (++guard > 20000) {
        printf("  FAIL timeout after %ld cycles\n", guard);
        return false;
      }
    }
    d->span_ready = 1;
    d->eval();
    return true;
  }
};

static void report(const char* what, const int32_t* vx, const int32_t* vy,
                   const std::vector<Span>& got, const std::vector<Span>& exp) {
  if (printed >= 20) return;
  printed++;
  printf("  FAIL %s\n", what);
  printf("    quad (%d,%d) (%d,%d) (%d,%d) (%d,%d)  view [%d..%d]x[%d..%d]\n",
         vx[0], vy[0], vx[1], vy[1], vx[2], vy[2], vx[3], vy[3], VX1, VX2, VY1, VY2);
  printf("    dut %zu spans, ref %zu spans\n", got.size(), exp.size());
  size_t n = got.size() < exp.size() ? got.size() : exp.size();
  size_t shown = 0;
  for (size_t i = 0; i < n && shown < 6; i++) {
    if (got[i] != exp[i]) {
      printf("    [%zu] dut y=%d x=%d..%d   ref y=%d x=%d..%d\n", i,
             got[i].y, got[i].x0, got[i].x1, exp[i].y, exp[i].x0, exp[i].x1);
      shown++;
    }
  }
  for (size_t i = n; i < got.size() && shown < 6; i++, shown++)
    printf("    [%zu] dut y=%d x=%d..%d   ref -\n", i, got[i].y, got[i].x0, got[i].x1);
  for (size_t i = n; i < exp.size() && shown < 6; i++, shown++)
    printf("    [%zu] dut -   ref y=%d x=%d..%d\n", i, exp[i].y, exp[i].x0, exp[i].x1);
}

static void one(Dut& dut, const int32_t* vx, const int32_t* vy, const char* what,
                int stall_pct = 0) {
  checks++;
  bool ref_line = ref_fill_quad(vx, vy);
  std::vector<Span> exp = ref_spans;

  if (!dut.run_quad(vx, vy, 0x00abcdef, false, stall_pct)) { fails++; return; }

  total_spans += (long)dut.spans.size();
  if (ref_line) line_cases++;
  if (!ref_line && exp.empty()) empty_quads++;

  if (dut.got_line != ref_line) {
    fails++;
    if (printed < 20) {
      printed++;
      printf("  FAIL %s: line_case dut=%d ref=%d\n", what, (int)dut.got_line, (int)ref_line);
      printf("    quad (%d,%d) (%d,%d) (%d,%d) (%d,%d)\n",
             vx[0], vy[0], vx[1], vy[1], vx[2], vy[2], vx[3], vy[3]);
    }
    return;
  }

  if (dut.spans.size() != exp.size()) { fails++; report(what, vx, vy, dut.spans, exp); return; }
  for (size_t i = 0; i < exp.size(); i++) {
    if (dut.spans[i] != exp[i]) { fails++; report(what, vx, vy, dut.spans, exp); return; }
  }
}


// ---------------------------------------------------------------- R274
// THE TEXTURE PLANE. A SKEWED quad with a different u and v at every corner:
// every span the filler emits must carry the value of the plane through
// vertices 0, 1 and 2 at its own (x0, y), and the per-pixel step must be that
// plane's x gradient.
//
// SKEWED ON PURPOSE. The first version of this test used an axis-aligned
// rectangle with u along x and v along y, which zeroes half of every cross
// product in the fit -- and then a sign flip in a numerator and a
// mis-scaled base BOTH passed it. A test whose inputs are symmetric cannot
// see an asymmetric fault.
static long tex_checks = 0, tex_fails = 0;

static void test_plane(Vm2_raster_fill* d) {
  auto tickf = [&]() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };
  const int32_t VX[4] = {10, 130, 118,   4};
  const int32_t VY[4] = { 5,  19,  71,  58};
  const int32_t U[4]  = {37, 501, 640, 122};     // quarter-texels, all different
  const int32_t V[4]  = {91, 160, 612, 540};

  // The same plane, in double precision, through vertices 0,1,2.
  const double ax = VX[1] - VX[0], ay = VY[1] - VY[0];
  const double bx = VX[2] - VX[0], by = VY[2] - VY[0];
  const double det = ax * by - bx * ay;
  const double u1 = U[1] - U[0], u2 = U[2] - U[0];
  const double v1 = V[1] - V[0], v2 = V[2] - V[0];
  const double dudx = (u1 * by - u2 * ay) / det, dudy = (ax * u2 - bx * u1) / det;
  const double dvdx = (v1 * by - v2 * ay) / det, dvdy = (ax * v2 - bx * v1) / det;

  d->view_x1 = 0; d->view_x2 = 495; d->view_y1 = 0; d->view_y2 = 383;
  d->in_x0 = VX[0]; d->in_y0 = VY[0];
  d->in_x1 = VX[1]; d->in_y1 = VY[1];
  d->in_x2 = VX[2]; d->in_y2 = VY[2];
  d->in_x3 = VX[3]; d->in_y3 = VY[3];
  d->in_u0 = U[0]; d->in_v0 = V[0];
  d->in_u1 = U[1]; d->in_v1 = V[1];
  d->in_u2 = U[2]; d->in_v2 = V[2];
  d->in_u3 = U[3]; d->in_v3 = V[3];
  d->in_oz0 = OZ_FLAT; d->in_oz1 = OZ_FLAT;   // R424
  d->in_oz2 = OZ_FLAT; d->in_oz3 = OZ_FLAT;
  d->in_col = 0xffffff; d->in_moire = 0;
  d->in_tex = 1;                                // bit 0: textured
  d->in_valid = 1; d->span_ready = 1;
  d->eval();

  bool accepted = false, retired = false;
  long guard = 0, spans_seen = 0;
  for (;;) {
    d->eval();
    if (d->span_valid && d->span_ready) {
      const int32_t y  = (int32_t)d->span_y;
      const int32_t x0 = (int32_t)d->span_x0;
      const double u  = (double)(int32_t)d->span_u / 65536.0;
      const double v  = (double)(int32_t)d->span_v / 65536.0;
      // R286: the gradient is 8.8, not 16.16 -- sixteen bits of it, signed.
      const double du = (double)(int16_t)d->span_dudx / 256.0;
      const double dv = (double)(int16_t)d->span_dvdx / 256.0;
      const double wu = OZ_K * (U[0] + dudx * (x0 - VX[0]) + dudy * (y - VY[0]));
      const double wv = OZ_K * (V[0] + dvdx * (x0 - VX[0]) + dvdy * (y - VY[0]));
      ++spans_seen; tex_checks += 4;
      // A quarter of a texel of slack: the gradients are a fixed-point divide
      // and the span is up to 130 pixels from the vertex the plane is anchored
      // at, so a bit of the quotient is a fraction of a texel by the far end.
      if (fabs(u - wu) > 1.0) {
        if (tex_fails < 6) printf("  FAIL plane u at (%d,%d): %.3f want %.3f\n", x0, y, u, wu);
        ++tex_fails;
      }
      if (fabs(v - wv) > 1.0) {
        if (tex_fails < 6) printf("  FAIL plane v at (%d,%d): %.3f want %.3f\n", x0, y, v, wv);
        ++tex_fails;
      }
      if (fabs(du - OZ_K * dudx) > 0.04) {
        if (tex_fails < 6) printf("  FAIL du/dx %.5f want %.5f\n", du, OZ_K * dudx);
        ++tex_fails;
      }
      if (fabs(dv - OZ_K * dvdx) > 0.04) {
        if (tex_fails < 6) printf("  FAIL dv/dx %.5f want %.5f\n", dv, OZ_K * dvdx);
        ++tex_fails;
      }
    }
    if (d->quad_done && accepted) retired = true;
    if (d->in_ready && d->in_valid) accepted = true;
    const bool drained = retired && !d->span_valid;
    tickf();
    if (accepted) { d->in_valid = 0; d->eval(); }
    if (drained) break;
    if (++guard > 40000) { printf("  FAIL plane test timeout\n"); ++tex_fails; break; }
  }
  ++tex_checks;
  if (!d->span_tex_en) { printf("  FAIL the fit did not take\n"); ++tex_fails; }
  printf("  texture plane: %ld spans, %ld checks, %ld wrong (du/dx %.4f du/dy %.4f)\n",
         spans_seen, tex_checks, tex_fails, dudx, dudy);

  // A TRIANGLE. It reaches here as a quad with a repeated vertex, so vertices
  // 0,1,2 can be collinear and the fit has to retry on 0,2,3 -- or the texture
  // is dropped on every triangle in the game.
  {
    const int32_t TX[4] = {20, 20, 90, 60};
    const int32_t TY[4] = {10, 10, 30, 80};
    d->in_x0 = TX[0]; d->in_y0 = TY[0]; d->in_x1 = TX[1]; d->in_y1 = TY[1];
    d->in_x2 = TX[2]; d->in_y2 = TY[2]; d->in_x3 = TX[3]; d->in_y3 = TY[3];
    d->in_u0 = 100; d->in_v0 = 200; d->in_u1 = 100; d->in_v1 = 200;
    d->in_u2 = 400; d->in_v2 = 220; d->in_u3 = 180; d->in_v3 = 700;
    d->in_oz0 = OZ_FLAT; d->in_oz1 = OZ_FLAT;   // R424
    d->in_oz2 = OZ_FLAT; d->in_oz3 = OZ_FLAT;
    d->in_valid = 1; d->eval();
    accepted = false; retired = false; guard = 0;
    long tri_spans = 0;
    for (;;) {
      d->eval();
      if (d->span_valid && d->span_ready) ++tri_spans;
      if (d->quad_done && accepted) retired = true;
      if (d->in_ready && d->in_valid) accepted = true;
      const bool drained = retired && !d->span_valid;
      tickf();
      if (accepted) { d->in_valid = 0; d->eval(); }
      if (drained) break;
      if (++guard > 40000) break;
    }
    ++tex_checks;
    if (!d->span_tex_en) {
      printf("  FAIL a triangle's first three vertices are collinear and the "
             "retry did not take -- every triangle would draw untextured\n");
      ++tex_fails;
    } else {
      printf("  triangle: the fit retried on 0,2,3 and took (%ld spans)\n", tri_spans);
    }
  }
  d->in_tex = 0;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  std::mt19937 rng(20260815u);

  // The real viewport: 496x384, inclusive.
  VX1 = 0; VX2 = 495; VY1 = 0; VY2 = 383;

  Dut dut(&rng);
  dut.set_viewport(VX1, VX2, VY1, VY2);

  // ------------------------------------------------------------- directed
  printf("test: directed shapes\n");
  {
    struct Case { int32_t vx[4], vy[4]; const char* name; };
    const Case cases[] = {
      // A plain convex quad, wholly on screen.
      {{100, 300, 320,  80}, {50,  60, 300, 280}, "convex"},
      // Triangle as the clipper emits one: last vertex repeated.
      {{100, 300, 200, 200}, {50,  60, 300, 300}, "triangle-as-quad"},
      // Flat: every vertex on one scanline. fill_line, min to max x.
      {{100, 300, 220,  50}, {200, 200, 200, 200}, "flat"},
      // All four coincident. NOT a wireframe — one pixel.
      {{123, 123, 123, 123}, {77,  77,  77,  77},  "single-point"},
      // Exactly two distinct vertices: wireframe, flagged not filled.
      {{ 10,  10, 400, 400}, {20,  20, 300, 300},  "wireframe"},
      // Self-intersecting, so the edges cross inside a segment.
      {{100, 300, 100, 300}, {50,  60, 300, 310},  "bowtie"},
      // Straddles every viewport edge.
      {{-200, 700, 640, -90}, {-120, -60, 500, 460}, "straddle-all"},
      // Entirely above, entirely below, entirely left, entirely right.
      {{100, 300, 320,  80}, {-400, -390, -200, -210}, "above"},
      {{100, 300, 320,  80}, {500,  510,  700,  690},  "below"},
      {{-900, -700, -720, -880}, {50, 60, 300, 280},   "left"},
      {{1400, 1600, 1620, 1380}, {50, 60, 300, 280},   "right"},
      // One scanline tall, and two scanlines tall.
      {{100, 300, 320,  80}, {100, 100, 101, 101}, "one-line"},
      {{100, 300, 320,  80}, {100, 101, 102, 101}, "two-line"},
      // Three vertices sharing the top y, so both startup loops iterate.
      {{100, 200, 300, 150}, {40,  40,  40,  300}, "flat-top-run"},
      // Three sharing the bottom y.
      {{150, 100, 200, 300}, {40,  300, 300, 300}, "flat-bottom-run"},
      // Vertical edges: slope zero on one side.
      {{100, 100, 300, 300}, {50,  300, 300, 50},  "axis-aligned"},
      // The <<16 overflow: |s.x| >= 32768 wraps rather than saturating.
      {{40000, 40100, 33000, 32800}, {50, 60, 300, 280}, "x-overflow"},
      {{-40000, -33000, -32800, -40100}, {50, 60, 300, 280}, "x-underflow"},
      // Huge y span, so the viewport skip path with the multiply runs.
      //
      // R327: WITHIN THE PORT'S RANGE, WHICH IS NOW SIXTEEN BITS. This case
      // used +/-100,000, which a 16-bit port cannot carry -- so it was testing
      // C-to-Verilog truncation, not the fill. m2_quad_store saturates every
      // screen coordinate to 13 bits (+/-4,095) before the fill can see it, so
      // 30,000 is already seven times anything the hardware can produce and
      // still runs the same skip-multiply path: the viewport is 0..383.
      {{100, 300, 320,  80}, {-30000, -29000, 30000, 29000}, "y-huge"},
      // Degenerate: two pairs, but three distinct points.
      {{100, 100, 300, 300}, {50,  50,  200, 201}, "two-pairs"},
    };
    for (const auto& c : cases) one(dut, c.vx, c.vy, c.name);
    printf("  %zu shapes\n", sizeof(cases) / sizeof(cases[0]));
  }

  // --------------------------------------------------------- backpressure
  printf("test: span backpressure\n");
  {
    const int32_t vx[4] = {40, 460, 430, 70}, vy[4] = {20, 30, 360, 350};
    for (int pct = 10; pct <= 90; pct += 20) one(dut, vx, vy, "stall", pct);
    printf("  five stall rates on a full-screen quad\n");
  }

  // ------------------------------------------------------------ viewports
  printf("test: viewport variations\n");
  {
    const int32_t views[][4] = {
      {0, 495, 0, 383},      // the real one
      {0, 0, 0, 0},          // one pixel
      {10, 20, 10, 12},      // tiny
      {100, 400, 100, 300},  // inset, so clamping bites on all four sides
      {0, 495, 200, 200},    // one scanline tall
    };
    for (const auto& v : views) {
      VX1 = v[0]; VX2 = v[1]; VY1 = v[2]; VY2 = v[3];
      dut.set_viewport(VX1, VX2, VY1, VY2);
      for (int i = 0; i < 400; i++) {
        int32_t vx[4], vy[4];
        for (int k = 0; k < 4; k++) {
          vx[k] = (int32_t)(rng() % 800) - 150;
          vy[k] = (int32_t)(rng() % 600) - 100;
        }
        one(dut, vx, vy, "viewport");
      }
    }
    VX1 = 0; VX2 = 495; VY1 = 0; VY2 = 383;
    dut.set_viewport(VX1, VX2, VY1, VY2);
    printf("  2000 quads across 5 viewports\n");
  }

  // ------------------------------------------- R430: TEXTURED, WITH REAL DEPTH
  //
  // THE GAP THIS CLOSES. The 150,000-quad fuzz above passes `false` for
  // textured, so NOT ONE of them enters the plane fit. The only textured quads
  // in this bench are test_plane's and the triangle's, and R424 gave both of
  // them the SAME 1/z on all four vertices -- deliberately, so the pre-existing
  // checks would keep passing. With 1/z flat, pf_o1 and pf_o2 are zero, so nxo
  // and nyo are zero, pf_clz(0) returns 32 and pf_scale returns 0 without
  // dividing. The THIRD DIVIDE ROUND HAS NEVER RUN WITH A REAL NUMERATOR.
  //
  // On the board that build freezes at the first frame with the TGP parked,
  // which is what a fill that never retires its first textured quad looks like
  // from four stages upstream. This drives varying depth and watches for a quad
  // that never retires.
  printf("test: R430, textured quads with a real depth gradient\n");
  {
    Vm2_raster_fill* d = dut.d;
    auto tickf = [&]() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };
    long hung = 0, ran = 0, worst = 0;
    // Exponent spreads from flat to 8:1 within one quad, plus the degenerate
    // cases: a vertex at z = infinity (1/z == 0) and all four there.
    const uint16_t OZ[][4] = {
      {0x7f00, 0x7f00, 0x7f00, 0x7f00},   // flat, the only case ever tested
      {0x7f00, 0x7e00, 0x7d00, 0x7c00},   // 8:1 across the quad
      {0x7f00, 0x7fff, 0x7e80, 0x7d40},   // mantissa spread too
      {0x7f00, 0x0000, 0x7e00, 0x7d00},   // one vertex at infinity
      {0x0000, 0x0000, 0x0000, 0x0000},   // all at infinity
      {0x7fff, 0x4000, 0x7fff, 0x4000},   // alternating extremes
      {0x8f00, 0x7f00, 0x6f00, 0x5f00},   // exponent far apart, saturating shift
    };
    const int32_t VX[4] = {10, 130, 118,   4};
    const int32_t VY[4] = { 5,  19,  71,  58};
    const int32_t U[4]  = {37, 501, 640, 122};
    const int32_t V[4]  = {91, 160, 612, 540};
    for (size_t c = 0; c < sizeof(OZ)/sizeof(OZ[0]); c++) {
      d->in_x0 = VX[0]; d->in_y0 = VY[0]; d->in_x1 = VX[1]; d->in_y1 = VY[1];
      d->in_x2 = VX[2]; d->in_y2 = VY[2]; d->in_x3 = VX[3]; d->in_y3 = VY[3];
      d->in_u0 = U[0]; d->in_v0 = V[0]; d->in_u1 = U[1]; d->in_v1 = V[1];
      d->in_u2 = U[2]; d->in_v2 = V[2]; d->in_u3 = U[3]; d->in_v3 = V[3];
      d->in_oz0 = OZ[c][0]; d->in_oz1 = OZ[c][1];
      d->in_oz2 = OZ[c][2]; d->in_oz3 = OZ[c][3];
      d->in_col = 0xffffff; d->in_moire = 0; d->in_tex = 1;
      d->in_valid = 1; d->span_ready = 1; d->eval();
      bool acc = false, ret = false;
      long g = 0;
      for (;;) {
        d->eval();
        if (d->quad_done && acc) ret = true;
        if (d->in_ready && d->in_valid) acc = true;
        const bool drained = ret && !d->span_valid;
        tickf();
        if (acc) { d->in_valid = 0; d->eval(); }
        if (drained) break;
        if (++g > 200000) {
          printf("  FAIL oz case %zu (%04x %04x %04x %04x) NEVER RETIRED -- "
                 "the fill is wedged, which upstream reads as a frozen game\n",
                 c, OZ[c][0], OZ[c][1], OZ[c][2], OZ[c][3]);
          ++hung; break;
        }
      }
      if (g > worst) worst = g;
      ++ran;
      d->in_valid = 0; d->eval();
      for (int k = 0; k < 40; k++) tickf();
    }
    printf("  %ld depth cases, %ld hung, worst %ld cycles to retire\n", ran, hung, worst);
    checks += ran; fails += hung;
  }

  // ----------------------------------------------------------------- fuzz
  // Three coordinate regimes, because they reach different code: on-screen
  // exercises the walk, near-edge exercises the clamps, and wild exercises the
  // <<16 overflow and the multiply skip.
  printf("test: fuzz\n");
  {
    const long N = 150000;
    for (long n = 0; n < N; n++) {
      int32_t vx[4], vy[4];
      int regime = (int)(n % 10);
      for (int k = 0; k < 4; k++) {
        if (regime < 5) {                       // on screen
          vx[k] = (int32_t)(rng() % 496);
          vy[k] = (int32_t)(rng() % 384);
        } else if (regime < 8) {                // straddling the edges
          vx[k] = (int32_t)(rng() % 1000) - 250;
          vy[k] = (int32_t)(rng() % 800) - 200;
        } else {                                // wild
          // x has always been effectively 16-bit -- px[i] is {sx[i], 16'h0} --
          // so this range tests the documented wrap and always has.
          vx[k] = (int32_t)(rng() % 200000) - 100000;
          // R327: y WIDENED FROM +/-2,000 TO +/-20,000, deliberately. Narrowing
          // the coordinate path is only safe if the fuzz actually visits the
          // top of the range, and +/-2,000 is INSIDE what the hardware can
          // produce (+/-4,095). This is five times past it and still inside the
          // 16-bit port, which is where a narrowing bug would show.
          vy[k] = (int32_t)(rng() % 40000) - 20000;
        }
      }
      // Every fifth quad gets a duplicated vertex, which is how the frustum
      // clipper delivers triangles — the common case, not an edge case.
      if ((n % 5) == 0) {
        int a = (int)(rng() & 3), b = (int)(rng() & 3);
        vx[a] = vx[b]; vy[a] = vy[b];
      }
      // And every seventeenth is squashed onto few scanlines, where the
      // startup loops and the fill_line tail do the work.
      if ((n % 17) == 0) {
        for (int k = 0; k < 4; k++) vy[k] = (int32_t)(rng() % 3) + 100;
      }
      one(dut, vx, vy, "fuzz", (n % 11) == 0 ? 25 : 0);
    }
    printf("  %ld quads\n", N);
  }

  test_plane(dut.d);
  checks += tex_checks; fails += tex_fails;

  printf("m2_raster_fill: checks=%ld fails=%ld spans=%ld lines=%ld empty=%ld\n",
         checks, fails, total_spans, line_cases, empty_quads);
  return fails ? 1 : 0;
}
