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
#include <cstdlib>
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
static long ticks_done = 0;
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
  ++ticks_done;
  d->out_ready = stall ? 0 : 1;
  // The texel fetch answers in one cycle.
  // R479: A TEXEL THAT CAN MISS. Answering every fetch in one cycle is what
  // made this bench blind to the fault the board shows: with textures off every
  // band lands, with them on only two to five do, and m2_texel says why --
  // "one miss BLOCKS every span behind it". A perfect cache has no stall to
  // block with, so no amount of walk optimisation measured here would predict
  // anything about bands.
  //
  // M2_MISS_PCT (default 0) makes a fraction of fetches take M2_MISS_CYC cycles.
  // 26% at 14 cycles is the board's measured hit rate and a ~280 ns miss at
  // 50 MHz.
  static const int miss_pct = std::getenv("M2_MISS_PCT") ? atoi(std::getenv("M2_MISS_PCT")) : 0;
  static const int miss_cyc = std::getenv("M2_MISS_CYC") ? atoi(std::getenv("M2_MISS_CYC")) : 14;
  static uint32_t tex_rng = 99991;
  static int      tex_wait = -1;
  if (d->tx_req) {
    if (tex_wait < 0) {                       // a new fetch: decide hit or miss
      tex_rng = tex_rng * 1103515245u + 12345u;
      tex_wait = (int)((tex_rng >> 16) % 100) < miss_pct ? miss_cyc : 0;
    }
    if (tex_wait > 0) { --tex_wait; d->tx_ack = 0; }
    else              { d->tx_ack = 1; d->tx_texel = texel_of(d->tx_u, d->tx_v); tex_wait = -1; }
  } else { d->tx_ack = 0; tex_wait = -1; }
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
    // R475: CYCLES PER GROUP, which nothing has measured. The walk's floor
    // decides whether the texel fetch is the bottleneck or merely a term.
    long tick_total = 0, group_total = 0;

    for (int trial = 0; trial < 120; ++trial) {
      const int STEP = 2;
      // R488: the span LENGTH is settable, because the fixed cost of starting a
      // span and the per-group cost of walking it cannot be separated from one
      // corpus. Two runs at different lengths give two equations. The board's
      // own evidence demanded this: PIXSTEP 4 -> 8 halves the groups AND the
      // fetches per span and changed nothing on screen, which rules out both
      // per-group terms and leaves the per-span one.
      static const int SPAN_LEN = std::getenv("M2_SPAN_LEN")
                                ? atoi(std::getenv("M2_SPAN_LEN")) : 40;
      const int X0 = 4 + int(roll(60));
      const int X1 = X0 + STEP * int(1 + roll(SPAN_LEN));
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
      long t0 = ticks_done;
      for (int i = 0; i < 4000 && int(got.size()) < groups; ++i) tick();
      tick_total += ticks_done - t0; group_total += groups;

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
    std::printf("    walk rate: %ld cycles for %ld groups -- %.2f cycles per group\n",
                tick_total, group_total,
                group_total ? double(tick_total)/double(group_total) : 0.0);
    std::printf("    per span: %ld cycles for %ld spans -- %.2f cycles per span"
                " (%.2f groups per span)\n",
                tick_total, spans_run,
                spans_run ? double(tick_total)/double(spans_run) : 0.0,
                spans_run ? double(group_total)/double(spans_run) : 0.0);
    ck("spans actually ran", spans_run > 100, 1);
    ck("groups actually checked", groups_checked > 1000, 1);
  }

  // 2c. R490: SPANS BACK TO BACK, WHICH IS HOW THE FILL ACTUALLY DRIVES THIS.
  //
  // Every test above hands over ONE span, drops in_valid, and waits for all of
  // its groups before offering the next. That is not what m2_raster_fill does
  // and it is why R488's fixed cost was invisible here for so long: a unit that
  // is never offered a second span while the first drains cannot be measured
  // for, or caught overlapping, or caught overlapping WRONGLY.
  //
  // This holds a span on the input until in_ready takes it and immediately
  // presents the next, so the pipeline is offered work continuously. The
  // per-span figure from this loop is the one that decides whether the divide
  // pipeline is still refilling from empty -- R488 measured 8.0 + 2.0*groups
  // with the pipeline draining every time.
  {
    std::printf("test: R490, spans back to back -- the fill's own pattern\n");
    uint32_t rng = 0x5EEDu;
    auto roll = [&](uint32_t n) { rng = rng*1664525u + 1013904223u; return (rng >> 8) % n; };
    const int STEP = 2;
    const int NSPAN = 60;
    struct S { int y, x0, x1, u, v, du, dv, ooz, doz, groups; };
    std::vector<S> sp;
    for (int i = 0; i < NSPAN; ++i) {
      S q;
      q.x0 = 4 + int(roll(40));
      q.x1 = q.x0 + STEP * int(1 + roll(6));      // SHORT spans: 2-7 groups
      q.y  = 11 + int(roll(40));
      q.u  = int32_t(roll(8) << 18);  q.v = int32_t(roll(8) << 18);
      q.du = int32_t(roll(0x180)) + 0x20;
      q.dv = int32_t(roll(0x180)) + 0x20;
      q.groups = ((q.x1 - q.x0) / STEP) + 1;
      q.ooz = 0x2000000 + int32_t(roll(0x1000000));
      q.doz = -int32_t(roll(20000)) / (q.groups ? q.groups : 1);
      sp.push_back(q);
    }
    long want_groups = 0;
    for (auto &q : sp) want_groups += q.groups;

    got.clear(); force_texel = -1;
    static const int stall_pct = std::getenv("M2_STALL_PCT")
                               ? atoi(std::getenv("M2_STALL_PCT")) : 0;
    uint32_t stall_rng = 0xBEEF1234u;
    long t0 = ticks_done;
    size_t next = 0;
    d->in_tex = 0x000001; d->in_tex_en = 1; d->in_col = 0xffffff; d->in_moire = 0;
    for (long guard = 0; guard < 200000; ++guard) {
      if (next < sp.size()) {
        const S &q = sp[next];
        d->in_valid = 1;
        d->in_y = q.y; d->in_x0 = q.x0; d->in_x1 = q.x1;
        d->in_u = q.u; d->in_v = q.v; d->in_dudx = q.du; d->in_dvdx = q.dv;
        d->in_ooz = q.ooz; d->in_doozdx = q.doz;
      } else {
        d->in_valid = 0;
      }
      // in_ready is sampled BEFORE the edge, as the DUT sees it.
      // R494: SAMPLE in_ready AFTER SETTLING IT, not before. Until R490
      // in_ready did not depend on in_valid, so reading it at the top of the
      // loop was harmless. ld_over does depend on in_valid, so the stale read
      // made the bench miss an accept, re-present the same span, and the DUT
      // take it twice -- 2x the groups, which looked exactly like an RTL fault
      // and is not one. out_ready is driven here in the same order tick() does
      // it so the value sampled is the value the edge will use.
      stall_rng = stall_rng * 1103515245u + 12345u;
      bool stall = stall_pct && (int((stall_rng >> 16) % 100) < stall_pct);
      d->out_ready = stall ? 0 : 1;
      d->eval();
      bool taken = d->in_valid && d->in_ready;
      // THE CONSUMER STALLS, because the real one does. m2_raster_band
      // drops span_ready for the whole time it is painting a group, and the
      // R490 overlap was tested with out_ready tied high for every cycle --
      // which is the one thing the band NEVER does. A unit that only deadlocks
      // when the output backs up cannot be caught by a bench that never backs
      // it up.
      tick(stall);
      if (taken) ++next;
      if (next >= sp.size() && long(got.size()) >= want_groups) break;
    }
    d->in_valid = 0;
    long cyc = ticks_done - t0;

    // NOTHING LOST AND NOTHING INVENTED across the span boundaries, which is
    // the fault an overlap introduces: a group of span N coloured with span
    // N+1's parameters, or a span's tail dropped when the next one loads.
    ck("every group came out", long(got.size()), want_groups);
    if (std::getenv("M2_DBG")) {
      size_t kk = 0;
      for (size_t i = 0; i < sp.size() && kk < got.size(); ++i) {
        int n = 0;
        while (kk + n < got.size() && got[kk+n].y == sp[i].y) ++n;
        if (n != sp[i].groups)
          std::printf("      span %zu y=%d x[%d..%d] want %d groups, saw %d\n",
                      i, sp[i].y, sp[i].x0, sp[i].x1, sp[i].groups, n);
        kk += n;
        if (i > 8) break;
      }
    }
    size_t k = 0; long bad_y = 0, bad_x = 0;
    for (size_t i = 0; i < sp.size() && k + sp[i].groups <= got.size(); ++i) {
      int last_x0 = -1;
      for (int g = 0; g < sp[i].groups; ++g, ++k) {
        if (got[k].y != sp[i].y) ++bad_y;
        if (got[k].x0 <= last_x0 || got[k].x1 > sp[i].x1) ++bad_x;
        last_x0 = got[k].x0;
      }
    }
    ck("each group carries its own span's y", bad_y, 0);
    ck("x ascends within a span and stays inside it", bad_x, 0);
    std::printf("    back to back: %ld cycles for %zu spans, %ld groups"
                " -- %.2f cycles per span (%.2f groups per span)\n",
                cyc, sp.size(), want_groups,
                double(cyc)/double(sp.size()),
                double(want_groups)/double(sp.size()));
  }

  // 2d. R499: WHAT THE FILL ACTUALLY SENDS -- flat spans interleaved with
  //     textured ones, and degenerate widths among them.
  //
  // R497 named three gaps after the overlap froze the board with timing that
  // matched the builds that run. This closes two of them, and it is written
  // BEFORE the overlap goes back in so that "it passes" means something.
  //
  //   * A FLAT SPAN BETWEEN TEXTURED ONES. m2_span_tex passes flat spans
  //     through as WIRES while textured ones are walked from registers, and
  //     in_ready gates which path a span takes. A flat span arriving while
  //     textured pixels are still in the pipeline must WAIT -- passed through
  //     early it would overtake them. Every existing test sends one kind at a
  //     time.
  //   * DEGENERATE WIDTHS. x0 == x1 is one group and the fill emits them at
  //     polygon edges; x1 < x0 is an empty span. The corpus only ever
  //     generates x1 > x0.
  {
    std::printf("test: R499, flat and textured interleaved, degenerate widths\n");
    uint32_t rng = 0xA5A5u;
    auto roll = [&](uint32_t n) { rng = rng*1664525u + 1013904223u; return (rng >> 8) % n; };
    const int STEP = 2;
    struct S { int y, x0, x1, groups; bool tex; };
    std::vector<S> sp;
    for (int i = 0; i < 80; ++i) {
      S q; q.tex = (roll(3) != 0);          // a third of them flat
      q.x0 = 4 + int(roll(40));
      int w = int(roll(5));
      q.x1 = (w == 0) ? q.x0                       // one group
           : (w == 1) ? q.x0 - STEP                // EMPTY: x1 < x0
                      : q.x0 + STEP * int(roll(6) + 1);
      q.y  = 11 + i;                        // unique y per span, so the
      q.groups = (q.x1 < q.x0) ? 0          // outputs can be attributed
                               : ((q.x1 - q.x0) / STEP) + 1;
      sp.push_back(q);
    }
    got.clear(); force_texel = -1;
    long t0 = ticks_done; size_t next = 0; long sent = 0;
    long busy_gap = 0, accepted_groups = 0;
    for (long guard = 0; guard < 400000 && next < sp.size(); ++guard) {
      const S &q = sp[next];
      d->in_valid = 1;
      d->in_y = q.y; d->in_x0 = q.x0; d->in_x1 = q.x1;
      d->in_col = 0xffffff; d->in_moire = 0;
      d->in_u = 0x40000; d->in_v = 0x40000; d->in_dudx = 0x40; d->in_dvdx = 0x40;
      d->in_ooz = 0x4000000; d->in_doozdx = -100;
      d->in_tex = q.tex ? 0x000001 : 0x000000; d->in_tex_en = q.tex ? 1 : 0;
      d->out_ready = (roll(4) != 0) ? 1 : 0;
      d->eval();
      bool taken = d->in_valid && d->in_ready;
      size_t before = got.size();
      tick(!d->out_ready);
      // ONLY TEXTURED SPANS MAKE IT BUSY. A flat span is passed through as
      // wires in the cycle it is accepted, so counting its groups as work in
      // flight makes the check fail against known-good RTL -- which it did,
      // 476 times, before this line said `q.tex`.
      if (taken) { ++next; ++sent; if (q.tex) accepted_groups += q.groups; }
      if (q.tex || accepted_groups > 0) accepted_groups -= long(got.size() - before);
      // Work outstanding in the unit -> busy must be asserted.
      if (accepted_groups > 0 && !d->busy) ++busy_gap;
    }
    d->in_valid = 0;
    for (int i = 0; i < 400; ++i) {
      size_t before = got.size();
      tick();
      accepted_groups -= long(got.size() - before);
      if (accepted_groups > 0 && !d->busy) ++busy_gap;
    }
    long cyc = ticks_done - t0;

    // R501: `busy` MUST COVER EVERY SPAN IN FLIGHT.
    //
    // m2_raster3d leaves C_FILL for C_DONE on
    //   !qs_out_valid && !qs_replay_busy && !sq_busy && !spantex_busy && ...
    // so `busy` going low with work still inside this unit ends the band
    // early. R310 records what that costs: spans painted into the NEXT band,
    // "a frame with no new list painted 2214, the previous 2009". R490 changed
    // what `busy` means -- idle is now "no span in flight" rather than "not
    // walking a span" -- and NOTHING CHECKED IT. Counted here: busy must be
    // high on every cycle between a span being accepted and its last pixel
    // leaving.
    ck("busy covered every span in flight", busy_gap, 0);

    // EVERY SPAN WAS ACCEPTED -- a unit that wedges shows up here first, and a
    // wedge is exactly what the board did.
    ck("every span was accepted", sent, long(sp.size()));

    // AND THE ORDER IS THE ORDER SENT. y is unique per span, so a flat span
    // that overtook the textured pixels still in the pipeline is visible as an
    // out-of-order y -- which no check in this file could see before.
    long ooo = 0; int prev_y = -1;
    for (auto &o : got) { if (o.y < prev_y) ++ooo; prev_y = o.y; }
    ck("outputs never go backwards in y", ooo, 0);
    std::printf("    %ld spans accepted, %zu outputs, %ld cycles\n",
                sent, got.size(), cyc);
  }

  // 2e. R513: A SOAK, BECAUSE THE FAULT IS RARE AND PERMANENT.
  //
  // The board runs for three to five seconds -- two to three hundred frames --
  // drawing bands, and then the 3D stops for good while the CPU, the tilemap
  // and the video carry on. That is this unit wedging: if a span is accepted
  // and never completes, sp_n never returns, sp_room stays false, in_ready
  // never asserts again, the quad store's FIFO backs up and the fill can never
  // finish another band. Nothing else in the machine notices.
  //
  // A rare, absorbing state cannot be found by 60 spans or 120. This drives
  // tens of thousands with every knob moving -- length, flat/textured,
  // consumer stall, texel miss -- and watches for the only symptom that
  // matters: a stretch during which nothing is accepted and nothing comes out.
  {
    std::printf("test: R513, soak -- the unit must never stop accepting\n");
    uint32_t rng = 0x13577531u;
    auto roll = [&](uint32_t n) { rng = rng*1664525u + 1013904223u; return (rng >> 8) % n; };
    const int STEP = 2;
    const long NSPAN = std::getenv("M2_SOAK") ? atol(std::getenv("M2_SOAK")) : 20000;
    got.clear(); force_texel = -1;
    long sent = 0, stall_run = 0, worst_stall = 0;
    long guard = 0;
    while (sent < NSPAN && guard < 40000000) {
      ++guard;
      const int x0 = 4 + int(roll(60));
      const int w  = int(roll(6));
      const int x1 = (w == 0) ? x0 : (w == 1) ? x0 - STEP
                                              : x0 + STEP * int(roll(30) + 1);
      const bool tex = (roll(4) != 0);
      d->in_valid = 1;
      d->in_y = 11 + int(roll(60)); d->in_x0 = x0; d->in_x1 = x1;
      d->in_col = 0xffffff; d->in_moire = (roll(8) == 0);
      d->in_u = int32_t(roll(64) << 16); d->in_v = int32_t(roll(64) << 16);
      d->in_dudx = int32_t(roll(0x200)); d->in_dvdx = int32_t(roll(0x200));
      d->in_ooz = 0x1000000 + int32_t(roll(0x3000000));
      d->in_doozdx = -int32_t(roll(30000));
      d->in_tex = tex ? 0x000001 : 0; d->in_tex_en = tex;
      d->out_ready = (roll(5) != 0) ? 1 : 0;
      d->eval();
      const bool taken = d->in_valid && d->in_ready;
      const size_t before = got.size();
      tick(!d->out_ready);
      if (taken) { ++sent; stall_run = 0; }
      else if (got.size() == before) {
        if (++stall_run > worst_stall) worst_stall = stall_run;
      } else stall_run = 0;
    }
    d->in_valid = 0;
    for (int i = 0; i < 2000; ++i) tick();

    // THE WEDGE IS THE CHECK. A healthy unit is sometimes busy for a long time
    // -- a texel timeout is 511 cycles and a stalled consumer adds more -- but
    // it always comes back. Ten thousand cycles with neither an acceptance nor
    // an output is not busy, it is stuck.
    ck("never stopped accepting for 10k cycles", worst_stall < 10000, 1);
    ck("the soak actually ran", sent >= NSPAN, 1);
    std::printf("    %ld spans, %zu outputs, longest quiet stretch %ld cycles\n",
                sent, got.size(), worst_stall);
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
