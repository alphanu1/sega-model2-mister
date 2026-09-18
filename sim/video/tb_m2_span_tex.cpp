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
static std::vector<uint32_t> fetched_u;   // R424: tx_u at every fetch

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
  if (d->tx_req) { d->tx_ack = 1; d->tx_texel = texel_of(d->tx_u, d->tx_v);
                   fetched_u.push_back(d->tx_u); }
  else           { d->tx_ack = 0; }
  d->eval();
  if (d->out_valid && d->out_ready)
    got.push_back({int(d->out_y), int(d->out_x0), int(d->out_x1), d->out_col});
  d->clk = 0; d->eval();
  d->clk = 1; d->eval();
}

// R424: THE SPAN CARRIES u/z, v/z AND 1/z NOW, and the walk divides. Every test
// below predates that and asserts on u and v directly, so they drive 1/z at the
// value that makes the divide an IDENTITY: persp() is uoz * 2^29 / ozn and u_r
// is uoz * 2^16, so ozn == 2^13 returns u_r unchanged. 1/z in 16.16 is therefore
// 8192 << 16. Anything else and these tests would be measuring the divide
// instead of what they were written to measure.
static const int32_t OZ_ID   = 8192 << 16;
static const int16_t DOZ_FLAT = 0;

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
    const int32_t U0 = 4 * TEXEL, V0 = 8 * TEXEL;
    // R286: the fill hands over 8.8 texels a pixel; one texel is 0x100.
    const int32_t DU = 0x100, DV = 0x200;
    d->in_valid = 1; d->in_y = 5; d->in_x0 = X0; d->in_x1 = X1;
    d->in_col = 0xffffff; d->in_moire = 0;
    d->in_u = U0; d->in_v = V0; d->in_dudx = DU; d->in_dvdx = DV;
    d->in_o = OZ_ID; d->in_dodx = DOZ_FLAT;   // R424
    d->in_tex = 0x000001; d->in_tex_en = 1;        // bit 0 = textured
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
      const uint32_t u = uint32_t((U0 + (DU << 8) * int32_t(i) * STEP) >> 10);
      const uint32_t v = uint32_t((V0 + (DV << 8) * int32_t(i) * STEP) >> 10);
      const int t = texel_of(u, v);
      const uint32_t want = uint32_t((0xff * ((t << 4) | t) + 0xff) >> 8) * 0x010101u;
      ck("group colour is the texel at its first pixel", got[i].col, want);
    }
    ck("textured pixels counted", d->dbg_texpix, groups * STEP);
  }

  // 2b-R424. THE PERSPECTIVE DIVIDE ACTUALLY DIVIDES.
  //
  // Every other test here drives 1/z flat, which makes the divide an identity
  // and could not tell perspective-correct from affine if the whole feature
  // were deleted. This one holds u/z CONSTANT and sweeps 1/z over a 4:1 depth
  // ratio -- the road-to-the-horizon case R331 measured -- so the correct
  // answer sweeps 4:1 with it and the affine answer is a flat line.
  {
    got.clear(); fetched_u.clear();
    const int    PIX = 100;
    const int    X0  = 10, X1 = X0 + PIX - 1;
    const int32_t U0 = 3200 << 16;          // u/z, 16.16, CONSTANT across the span
    const int32_t O0 = 32704 << 16;         // 1/z at the near end, normalised
    const int16_t DO = -3925;               // 12.4 a pixel: 32704 -> ~8176 over 100
    d->in_valid = 1; d->in_y = 9; d->in_x0 = X0; d->in_x1 = X1;
    d->in_col = 0xffffff; d->in_moire = 0;
    d->in_u = U0; d->in_v = U0; d->in_dudx = 0; d->in_dvdx = 0;
    d->in_o = O0; d->in_dodx = DO;
    d->in_tex = 0x000001; d->in_tex_en = 1;
    tick();
    d->in_valid = 0;
    const int groups = ((X1 - X0) / STEP) + 1;
    for (int i = 0; i < 20000 && int(got.size()) < groups; ++i) tick();
    ck("perspective: one span per pixel group", long(got.size()), groups);

    long bad = 0; double worst = 0;
    for (size_t i = 0; i < fetched_u.size() && int(i) < groups; ++i) {
      const int64_t o   = int64_t(O0) + (int64_t(DO) << 12) * int64_t(i) * STEP;
      const int64_t ozn = o >> 16;
      // What the walk computes: u/z * 2^13 / (1/z), then shifted to texels.8.
      const int64_t want = ((int64_t(U0) * 8192) / ozn) >> 10;
      const int64_t err  = int64_t(fetched_u[i]) - want;
      if (llabs(err) > 4) { if (bad < 4) printf("  FAIL persp u[%zu] got=%u want=%lld\n",
                                                i, fetched_u[i], (long long)want); ++bad; }
      const double rel = double(llabs(err)) / double(want ? want : 1);
      if (rel > worst) worst = rel;
    }
    ck("perspective: u follows 1/z at every group", bad, 0L);

    // AND THE TEST CAN TELL THE TWO APART. Affine would hold u at its first
    // value for the whole span; the correct answer quadruples. Without this the
    // check above would pass on a build where the divide returned its input.
    if (fetched_u.size() >= 2) {
      const double ratio = double(fetched_u[fetched_u.size() - 1]) / double(fetched_u[0] ? fetched_u[0] : 1);
      printf("  perspective: u swept %.2fx across the span (affine would be 1.00x), worst error %.4f%%\n",
             ratio, worst * 100.0);
      ck("perspective: the sweep is hyperbolic, not flat", ratio > 3.0, true);
    }
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
      d->in_o = OZ_ID; d->in_dodx = DOZ_FLAT;   // R424
      d->in_tex = tex; d->in_tex_en = 1;
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
    d->in_o = OZ_ID; d->in_dodx = DOZ_FLAT;   // R424
    d->in_tex = 0x000001; d->in_tex_en = 1;
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
    d->in_o = OZ_ID; d->in_dodx = DOZ_FLAT;   // R424
    d->in_tex = 0x000001; d->in_tex_en = 1;
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
