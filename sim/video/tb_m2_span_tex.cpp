// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// The span texturing walk.
//
// Three properties, and the first is the one that bit:
//
//   1. A FLAT SPAN COSTS NOTHING. It passes through in the same cycle it
//      arrives, because the bands are beam-paced and one extra cycle a span
//      took the reference's own frame from 5,945 painted pixels to 6,396 on
//      alternating frames -- a picture that flashes.
//   2. A textured span emits exactly one span per pixel, left to right, with
//      u and v stepping by the gradient and the colour scaled by the texel.
//   3. The handshake holds: nothing is emitted twice, nothing is lost when the
//      consumer stalls.

#include "Vm2_span_tex.h"
#include "verilated.h"
#include <cstdio>
#include <cmath>
#include <algorithm>
#include <cstdint>
#include <vector>

static Vm2_span_tex *d;
// THE BENCH MUST RUN THE PIXSTEP THE CORE SHIPS. This file hardcoded STEP = 2
// and m2_span_tex defaults to 2, while m2_raster3d instantiates PIXSTEP(8) --
// so every assertion here proved a configuration the core does not build. That
// is how R323's texture-step bug shipped: `<<< (PIXSTEP == 2 ? 1 : 0)` is
// correct at 2 and wrong at everything above it, and nothing here ever ran
// above it. Sweep the parameter or the test confirms a setting.
#ifndef TB_PIXSTEP
#define TB_PIXSTEP 2
#endif
static const int STEP = TB_PIXSTEP;

static long checks = 0, fails = 0;
static void ck(const char *what, long got, long want) {
  ++checks;
  if (got != want) { std::printf("  FAIL %-34s got=%ld want=%ld\n", what, got, want); ++fails; }
}

struct Out { int y, x0, x1; uint32_t col; };
static std::vector<Out> got;

// The texel the fetch returns: a function of the coordinate, so a wrong step
// shows up as a wrong colour.
static int force_texel = -1;   // R326: >= 0 pins what the fetch returns
static int texel_of(uint32_t u, uint32_t v) {
  if (force_texel >= 0) return force_texel;
  return int(((u >> 8) + (v >> 8)) & 0xf);
}

static void tick(bool stall = false) {
  d->out_ready = stall ? 0 : 1;
  // The texel fetch answers in one cycle.
  if (d->tx_req) { d->tx_ack = 1; d->tx_texel = texel_of(d->tx_u, d->tx_v); }
  else           { d->tx_ack = 0; }
  d->eval();
  if (d->out_valid && d->out_ready)
    got.push_back({int(d->out_y), int(d->out_x0), int(d->out_x1), d->out_col});
  d->clk = 0; d->eval();
  d->clk = 1; d->eval();
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_span_tex;
  d->rst_n = 0; d->in_valid = 0; d->out_ready = 1; d->tx_ack = 0;
  for (int i = 0; i < 4; ++i) tick();
  d->rst_n = 1; tick();

  // 1. A FLAT SPAN, IN ONE CYCLE.
  {
    got.clear();
    d->in_valid = 1; d->in_y = 17; d->in_x0 = 100; d->in_x1 = 140;
    d->in_col = 0x203040; d->in_moire = 0; d->in_tex = 0; d->in_tex_en = 0;
    d->eval();
    ck("a flat span is accepted at once", d->in_ready, 1);
    ck("and offered at once", d->out_valid, 1);
    tick();
    d->in_valid = 0;
    ck("one span out", long(got.size()), 1);
    if (!got.empty()) {
      ck("span x0", got[0].x0, 100);
      ck("span x1", got[0].x1, 140);
      ck("span colour untouched", got[0].col, 0x203040);
    }
  }

  // 2. A TEXTURED SPAN: one GROUP of PIXSTEP pixels per fetch, stepping.
  //
  // PIXSTEP comes from TB_PIXSTEP so this runs at the value the core builds.
  // A fetch and a handshake per pixel is four cycles a
  // pixel and the bands are beam-paced, so one texel covers a pair. The last
  // group of a span is clipped to its end.
  {
    got.clear();
    // THE SPAN SCALES WITH THE STEP: three full groups plus one pixel. At a
    // fixed 7-pixel span, PIXSTEP 8 produced a SINGLE group, u never stepped,
    // and R323's texture-step bug was invisible at exactly the value the core
    // ships. The trailing +1 keeps the last group CLIPPED to one pixel, which
    // an earlier mutation of the clip needed to be caught.
    const int X0 = 10, X1 = 10 + 3 * STEP;
    // ONE TEXEL IS 4 * 65536 IN THIS FORMAT -- quarter-texels with sixteen
    // fractional bits. The first version of this test stepped by 1<<10, which
    // is 1/256th of a texel a pixel: every pixel fetched the SAME texel, and a
    // mutation that stopped the walk entirely passed it.
    const int32_t TEXEL = 4 << 16;
    // R339: THE INPUTS ARE u/z AND v/z NOW, so they are halved and 1/z is held
    // at 2^14, which makes the divide multiply by exactly two and reconstructs
    // the coordinates this test always used. Holding 1/z CONSTANT is the
    // control: a constant depth is the one case where perspective and affine
    // agree, so these checks stay comparable to the affine ones they replace.
    // The varying case is tested separately below, where it belongs.
    const int32_t U0 = 2 * TEXEL, V0 = 4 * TEXEL;
    const int32_t DU = 0x80, DV = 0x100;
    const int32_t OOZ = 1 << 30;            // 1/z = 2^14 in 16.16
    d->in_valid = 1; d->in_y = 5; d->in_x0 = X0; d->in_x1 = X1;
    d->in_col = 0xffffff; d->in_moire = 0;
    d->in_u = U0; d->in_v = V0; d->in_dudx = DU; d->in_dvdx = DV;
    d->in_tex = 0x000001; d->in_tex_en = 1;        // bit 0 = textured
    d->in_ooz = OOZ; d->in_doozdx = 0;             // R339
    tick();                                        // accepted
    d->in_valid = 0;
    const int groups = ((X1 - X0) / STEP) + 1;
    for (int i = 0; i < 400 && int(got.size()) < groups; ++i) tick();
    ck("one span per pixel group", long(got.size()), groups);
    for (size_t i = 0; i < got.size(); ++i) {
      const int x = X0 + int(i) * STEP;
      ck("group x0", got[i].x0, x);
      ck("group is PIXSTEP wide, clipped", got[i].x1, (x + STEP - 1 > X1) ? X1 : x + STEP - 1);
      // The texel unit sees the coordinate shifted from quarter-texels.16 to
      // texels.8, which is ten bits right.
      // R339: the walk carries u/z, and the unit divides by 1/z before it
      // fetches. With 1/z pinned at 2^14 the divide is exactly x2, so the
      // expected texel coordinate is twice the interpolated u/z -- which is the
      // coordinate this test used before perspective existed.
      const uint32_t u = uint32_t((2 * (U0 + (DU << 8) * int32_t(i) * STEP)) >> 10);
      const uint32_t v = uint32_t((2 * (V0 + (DV << 8) * int32_t(i) * STEP)) >> 10);
      const int t = texel_of(u, v);
      const uint32_t want = uint32_t((0xff * ((t << 4) | t) + 0xff) >> 8) * 0x010101u;
      ck("group colour is the texel at its first pixel", got[i].col, want);
    }
    ck("textured pixels counted", d->dbg_texpix, groups * STEP);
  }

  // 2c. R326: ON A TRANSLUCENT POLYGON, TEXEL 0xF IS TRANSPARENT.
  //
  // model2rd.ipp's draw_scanline_tex<true> sets an alpha bit on every texel
  // except 0xF and skips the ones without it. Bit 8 of the texture word is the
  // translucent flag. The three cases below are the whole contract, and the
  // third is the one that matters most: on an OPAQUE polygon 0xF is a
  // legitimate full-brightness texel and must still paint.
  {
    const int X0 = 10, X1 = 10 + 3 * STEP;
    const int groups = ((X1 - X0) / STEP) + 1;
    const int32_t TEXEL = 4 << 16;
    const int32_t U0 = 4 * TEXEL, V0 = 8 * TEXEL;
    const int32_t DU = 0x100, DV = 0x200;

    // walk one span and return how many groups came out
    auto run = [&](uint32_t tex, int forced) {
      got.clear();
      force_texel = forced;
      d->in_valid = 1; d->in_y = 7; d->in_x0 = X0; d->in_x1 = X1;
      d->in_col = 0xffffff; d->in_moire = 0;
      d->in_u = U0; d->in_v = V0; d->in_dudx = DU; d->in_dvdx = DV;
      d->in_tex = tex; d->in_tex_en = 1;
      d->in_ooz = 1 << 30; d->in_doozdx = 0;   // R339
      tick();
      d->in_valid = 0;
      for (int i = 0; i < 400 && d->busy; ++i) tick();
      for (int i = 0; i < 8; ++i) tick();
      return long(got.size());
    };

    const uint32_t OPAQUE = 0x000001;   // bit 0 textured
    const uint32_t TRANS  = 0x000101;   // bit 0 textured + bit 8 translucent

    const uint32_t px_before = d->dbg_texpix;
    std::printf("test: R326, the translucent texel test\n");
    ck("a translucent span of 0xF paints nothing",      run(TRANS,  0xf), 0);
    ck("and counts no textured pixels",  long(d->dbg_texpix - px_before), 0);
    // The walk must still have FINISHED -- a transparent span that never
    // terminates holds the band, which is the R162 failure mode.
    ck("and the walk still finished",    d->busy, 0);
    ck("a translucent span of 0xE paints every group",  run(TRANS,  0xe), groups);
    ck("0xF on an OPAQUE polygon still paints",         run(OPAQUE, 0xf), groups);
    force_texel = -1;
  }

  // 2d. R339: 1/z VARYING -- THE TEST THAT PROVES PERSPECTIVE, not just that
  //     the divide runs. With depth changing across the span the texel
  //     coordinate must be NON-LINEAR in x; an affine walk cannot produce it,
  //     so this is the check that would fail if the divide were removed.
  //
  //     The model is the RTL's arithmetic reduced: uq = u_r * 2^31 / ooz_r.
  //     (uq = u_r * r1 >> (t-7) with r1 ~ 2^47/(ooz_r >> (t-23)) collapses to
  //     exactly that, independent of where the leading bit landed.)
  {
    const int X0 = 10, X1 = 40, STEP = 2;
    const int32_t U0 = 3 << 18, V0 = 5 << 18;
    const int32_t DU = 0x140, DV = 0x90;
    const int32_t OOZ = 1 << 30;
    // DEPTH FALLS ~20% ACROSS THE SPAN. The first version used -(1<<21), which
    // drove 1/z to zero on the SECOND group: the loop below broke at once, the
    // curvature check never got its three samples, and the test PASSED having
    // verified nothing. in_doozdx is 16-bit signed, so this is near its limit.
    const int32_t DOZ = -26000;
    got.clear(); force_texel = -1;
    d->in_valid = 1; d->in_y = 11; d->in_x0 = X0; d->in_x1 = X1;
    d->in_col = 0xffffff; d->in_moire = 0;
    d->in_u = U0; d->in_v = V0; d->in_dudx = DU; d->in_dvdx = DV;
    d->in_tex = 0x000001; d->in_tex_en = 1;
    d->in_ooz = OOZ; d->in_doozdx = DOZ;
    tick(); d->in_valid = 0;
    const int groups = ((X1 - X0) / STEP) + 1;
    for (int i = 0; i < 3000 && int(got.size()) < groups; ++i) tick();

    std::printf("test: R339, a span whose depth changes -- the perspective divide\n");
    ck("one span per pixel group", long(got.size()), groups);

    std::vector<double> ux;
    int ran = 0;
    for (size_t i = 0; i < got.size(); ++i) {
      const int64_t ur  = (int64_t)U0  + (int64_t)(DU  << 8) * (int64_t)i * STEP;
      const int64_t vr  = (int64_t)V0  + (int64_t)(DV  << 8) * (int64_t)i * STEP;
      const int64_t oz  = (int64_t)OOZ + (int64_t)(DOZ << 8) * (int64_t)i * STEP;
      if (oz <= 0) break;
      ran++;
      const int64_t uq = (ur << 31) / oz;
      const int64_t vq = (vr << 31) / oz;
      ux.push_back((double)uq);
      const int t = texel_of((uint32_t)(uq >> 10), (uint32_t)(vq >> 10));
      const uint32_t want = uint32_t((0xff * ((t << 4) | t) + 0xff) >> 8) * 0x010101u;
      // The reciprocal is a seed plus one Newton step (6.1e-5 relative), so a
      // texel index may land one either side at a boundary.
      const int tg = (int)((got[i].col & 0xff) >> 4);
      if (abs(tg - t) > 1 && abs(tg - t) < 15) {
        checks++; fails++;
        if (fails < 6) std::printf("  FAIL group %zu texel got=%x want=%x\n", i, tg, t);
      } else checks++;
    }
    // THE GUARD: a loop that breaks early tests nothing, and silently.
    ck("every group was actually checked", ran, (int)got.size());
    // ...and it must be CURVED. Affine would make the second difference zero.
    if (ux.size() >= 3) {
      double d2 = 0;
      for (size_t i = 2; i < ux.size(); ++i)
        d2 = std::max(d2, fabs((ux[i] - ux[i-1]) - (ux[i-1] - ux[i-2])));
      ck("the coordinate is non-linear, as only a divide makes it", d2 > 1000.0, 1);
    }
  }

  // 2e. R472: MANY SPANS, EVERY GROUP'S TEXEL CHECKED, AND THE ORDER TOO.
  //
  // WHY THIS EXISTS. 2d proves perspective on ONE span with one set of
  // gradients, which is 52 checks in total -- and m2_span_tex is about to be
  // rewritten from a state machine into a pipeline. A pipeline can get the
  // arithmetic right and the ORDER wrong, or drop a group, or emit one twice,
  // and none of those show up in a single hand-built span.
  //
  // m2_span_tex.sv still carries a note saying this bench "has no assertion on
  // u or v at all". That was true when R323 wrote it and R339 fixed it; the
  // note is stale. What was still true is that one span is not a corpus.
  //
  // THE CHECKS, and each is a different way a pipeline breaks:
  //   * every group's texel against the same reduced-arithmetic model 2d uses
  //   * one output per group, so nothing is dropped or duplicated
  //   * x0 strictly increasing, so nothing is reordered
  //   * x1 within the span, so the tail group is clamped and not wrapped
  {
    std::printf("test: R472, a corpus of spans -- texel, count and order\n");
    uint32_t rng = 0xC0FFEEu;
    auto roll = [&](uint32_t n) { rng = rng*1664525u + 1013904223u; return (rng >> 8) % n; };
    long spans_run = 0, groups_checked = 0;

    for (int trial = 0; trial < 120; ++trial) {
      const int STEP = 2;
      const int X0 = 4 + int(roll(60));
      const int X1 = X0 + STEP * int(1 + roll(40));
      const int32_t U0  = int32_t(roll(8) << 18);
      const int32_t V0  = int32_t(roll(8) << 18);
      // POSITIVE GRADIENTS ONLY, and that is a range limit rather than a
      // preference. A negative du/dx walks u below zero, sat32 clamps the
      // product to 0x7FFFFFFF, and every texel from there on is the same
      // value -- the first version of this fuzz read 0xe for group after group
      // and looked like an RTL fault. 2d uses positive gradients for the same
      // reason. Spans that walk a texture backwards are a separate question
      // and need their own test, not this one.
      const int32_t DU  = int32_t(roll(0x180)) + 0x20;
      const int32_t DV  = int32_t(roll(0x180)) + 0x20;
      const int32_t OOZ = int32_t(1u << 30);
      // Keep 1/z positive for the whole span: 2d records that letting it reach
      // zero makes the loop break on the second group and the test pass having
      // checked nothing.
      const int groups = ((X1 - X0) / STEP) + 1;
      const int32_t DOZ = -int32_t(roll(20000)) / (groups ? groups : 1);

      got.clear(); force_texel = -1;
      d->in_valid = 1; d->in_y = 11 + int(roll(40));
      d->in_x0 = X0; d->in_x1 = X1;
      d->in_col = 0xffffff; d->in_moire = 0;
      d->in_u = U0; d->in_v = V0; d->in_dudx = DU; d->in_dvdx = DV;
      d->in_tex = 0x000001; d->in_tex_en = 1;
      d->in_ooz = OOZ; d->in_doozdx = DOZ;
      tick(); d->in_valid = 0;
      for (int i = 0; i < 4000 && int(got.size()) < groups; ++i) tick();

      ck("one output per group", long(got.size()), groups);
      if (int(got.size()) != groups) continue;
      spans_run++;

      int last_x0 = -1;
      for (size_t i = 0; i < got.size(); ++i) {
        const int64_t ur = (int64_t)U0  + (int64_t)(DU  << 8) * (int64_t)i * STEP;
        const int64_t vr = (int64_t)V0  + (int64_t)(DV  << 8) * (int64_t)i * STEP;
        const int64_t oz = (int64_t)OOZ + (int64_t)(DOZ << 8) * (int64_t)i * STEP;
        if (oz <= 0) break;
        const int64_t uq = (ur << 31) / oz;
        const int64_t vq = (vr << 31) / oz;
        const int t  = texel_of((uint32_t)(uq >> 10), (uint32_t)(vq >> 10));
        const int tg = (int)((got[i].col & 0xff) >> 4);
        ++checks; ++groups_checked;
        // Same one-index tolerance 2d uses: the reciprocal is a seed plus one
        // Newton step, so a texel may land either side at a boundary.
        if (abs(tg - t) > 1 && abs(tg - t) < 15) {
          ++fails;
          if (fails < 8)
            std::printf("  FAIL trial %d group %zu texel got=%x want=%x\n", trial, i, tg, t);
        }
        // ORDER AND EXTENT. A pipeline that reorders or clamps wrongly passes
        // every arithmetic check above and still draws a broken span.
        ck("x0 strictly increasing", got[i].x0 > last_x0, 1);
        last_x0 = got[i].x0;
        ck("x1 inside the span", got[i].x1 <= X1, 1);
      }
    }
    // THE GUARD, as 2d has: a corpus that silently ran nothing proves nothing.
    ck("spans actually ran", spans_run > 100, 1);
    ck("groups actually checked", groups_checked > 1000, 1);
  }

  // 2b. A FLAT SPAN WHEN THE CONSUMER IS NOT READY. It must be HELD, not
  //     consumed: in_ready is the band's ready, exactly as it was before this
  //     unit existed, or the fill drops a span whenever a band is busy.
  {
    got.clear();
    d->in_valid = 1; d->in_y = 3; d->in_x0 = 7; d->in_x1 = 9;
    d->in_col = 0x112233; d->in_tex = 0; d->in_tex_en = 0;
    d->out_ready = 0; d->eval();
    ck("flat span not accepted while the band is busy", d->in_ready, 0);
    for (int i = 0; i < 4; ++i) tick(true);
    ck("and nothing came out", long(got.size()), 0);
    tick(false);
    d->in_valid = 0;
    ck("taken once the band is ready", long(got.size()), 1);
    if (!got.empty()) ck("the held span, unchanged", got[0].col, 0x112233);
  }

  // 3. THE CONSUMER STALLS. Nothing may be lost or repeated.
  {
    got.clear();
    const int X0 = 0, X1 = 3 * STEP;
    d->in_valid = 1; d->in_y = 9; d->in_x0 = X0; d->in_x1 = X1;
    d->in_col = 0x808080;
    d->in_u = 0; d->in_v = 0; d->in_dudx = 0x400; d->in_dvdx = 0;   // 4 texels a pixel, 8.8
    d->in_tex = 0x000001; d->in_tex_en = 1;
    d->in_ooz = 1 << 30; d->in_doozdx = 0;   // R339
    tick();
    d->in_valid = 0;
    const int grp2 = ((X1 - X0) / STEP) + 1;
    for (int i = 0; i < 800 && int(got.size()) < grp2; ++i)
      tick((i % 3) != 0);                          // ready only one cycle in three
    ck("stalled: one span per pixel group", long(got.size()), grp2);
    bool ordered = true;
    for (size_t i = 0; i < got.size(); ++i) if (got[i].x0 != X0 + int(i) * STEP) ordered = false;
    ck("stalled: in order, none repeated", ordered, 1);
  }

  // 4. A TEXEL FETCH THAT NEVER ANSWERS. m2_texel goes deaf while it sweeps
  //    its tags, and this walk is inside the band fill: a wait here is a band
  //    that never completes and a picture that stops.
  {
    got.clear();
    d->in_valid = 1; d->in_y = 40; d->in_x0 = 2; d->in_x1 = 3;
    d->in_col = 0xffffff; d->in_u = 0; d->in_v = 0;
    d->in_dudx = 0; d->in_dvdx = 0;
    d->in_tex = 0x000001; d->in_tex_en = 1;
    d->in_ooz = 1 << 30; d->in_doozdx = 0;   // R339
    tick();
    d->in_valid = 0;
    // The memory is gone: answer nothing at all.
    for (int i = 0; i < 4000 && got.empty(); ++i) {
      d->out_ready = 1;
      if (d->out_valid) got.push_back({int(d->out_y), int(d->out_x0), int(d->out_x1), d->out_col});
      d->eval();
      d->clk = 0; d->eval(); d->clk = 1; d->eval();
    }
    ck("a dead texel fetch does not stop the band", long(got.size()) > 0, 1);
    if (!got.empty()) ck("and the pixel takes 0xF", got[0].col, 0xffffffu);
  }

  std::printf("m2_span_tex: checks=%ld fails=%ld\n", checks, fails);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
