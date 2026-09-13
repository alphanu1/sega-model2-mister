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
static long checks = 0, fails = 0;
static void ck(const char *what, long got, long want) {
  ++checks;
  if (got != want) { std::printf("  FAIL %-34s got=%ld want=%ld\n", what, got, want); ++fails; }
}

struct Out { int y, x0, x1; uint32_t col; };
static std::vector<Out> got;

// The texel the fetch returns: a function of the coordinate, so a wrong step
// shows up as a wrong colour.
static int texel_of(uint32_t u, uint32_t v) { return int(((u >> 8) + (v >> 8)) & 0xf); }

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
  // PIXSTEP is 2 (R279): a fetch and a handshake per pixel is four cycles a
  // pixel and the bands are beam-paced, so one texel covers a pair. The last
  // group of a span is clipped to its end.
  {
    got.clear();
    // AN ODD NUMBER OF PIXELS, so the last group is CLIPPED to one. With an
    // even span the clip never fires and a mutation that removed it passed.
    const int X0 = 10, X1 = 16;
    // ONE TEXEL IS 4 * 65536 IN THIS FORMAT -- quarter-texels with sixteen
    // fractional bits. The first version of this test stepped by 1<<10, which
    // is 1/256th of a texel a pixel: every pixel fetched the SAME texel, and a
    // mutation that stopped the walk entirely passed it.
    const int32_t TEXEL = 4 << 16;
    const int32_t U0 = 4 * TEXEL, V0 = 8 * TEXEL;
    const int32_t DU = TEXEL, DV = 2 * TEXEL;
    d->in_valid = 1; d->in_y = 5; d->in_x0 = X0; d->in_x1 = X1;
    d->in_col = 0xffffff; d->in_moire = 0;
    d->in_u = U0; d->in_v = V0; d->in_dudx = DU; d->in_dvdx = DV;
    d->in_tex = 0x000001; d->in_tex_en = 1;        // bit 0 = textured
    tick();                                        // accepted
    d->in_valid = 0;
    const int STEP = 2;
    const int groups = ((X1 - X0) / STEP) + 1;
    for (int i = 0; i < 400 && int(got.size()) < groups; ++i) tick();
    ck("one span per pixel group", long(got.size()), groups);
    for (size_t i = 0; i < got.size(); ++i) {
      const int x = X0 + int(i) * STEP;
      ck("group x0", got[i].x0, x);
      ck("group is PIXSTEP wide, clipped", got[i].x1, (x + STEP - 1 > X1) ? X1 : x + STEP - 1);
      // The texel unit sees the coordinate shifted from quarter-texels.16 to
      // texels.8, which is ten bits right.
      const uint32_t u = uint32_t((U0 + DU * int32_t(i) * STEP) >> 10);
      const uint32_t v = uint32_t((V0 + DV * int32_t(i) * STEP) >> 10);
      const int t = texel_of(u, v);
      const uint32_t want = uint32_t((0xff * ((t << 4) | t)) >> 8) * 0x010101u;
      ck("group colour is the texel at its first pixel", got[i].col, want);
    }
    ck("textured pixels counted", d->dbg_texpix, groups * STEP);
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
    const int X0 = 0, X1 = 5;
    d->in_valid = 1; d->in_y = 9; d->in_x0 = X0; d->in_x1 = X1;
    d->in_col = 0x808080;
    d->in_u = 0; d->in_v = 0; d->in_dudx = 4 << 16; d->in_dvdx = 0;
    d->in_tex = 0x000001; d->in_tex_en = 1;
    tick();
    d->in_valid = 0;
    const int STEP2 = 2;
    const int grp2 = ((X1 - X0) / STEP2) + 1;
    for (int i = 0; i < 800 && int(got.size()) < grp2; ++i)
      tick((i % 3) != 0);                          // ready only one cycle in three
    ck("stalled: one span per pixel group", long(got.size()), grp2);
    bool ordered = true;
    for (size_t i = 0; i < got.size(); ++i) if (got[i].x0 != X0 + int(i) * STEP2) ordered = false;
    ck("stalled: in order, none repeated", ordered, 1);
  }

  std::printf("m2_span_tex: checks=%ld fails=%ld\n", checks, fails);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
