// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// m2_geometry: does an object_data command become SCREEN QUADS?
//
// Every stage below this is already verified on its own -- xform at 7,813
// checks, clip at 2,003, the engine's grammar at 15. What is new here is the
// JOIN, and the join is where this project's expensive bugs have lived:
//
//   * THREE CLIENTS ON ONE POOL. The transform, the focus multiplies and the
//     clipper all share one multiplier and one adder. If the round-robin or the
//     tag routing is wrong, a result lands in the wrong stage and the picture
//     is subtly incorrect rather than absent -- the hardest failure to see.
//
//   * ONE PROJECTOR, TWO REQUESTERS. The quad projector and the clipper both
//     drive m2_geo_project. If the grant is ambiguous, whichever side lost
//     still believes it was served and reads another vertex's pixels.
//
//   * VIEW SPACE IN, PIXELS OUT. The engine emits VIEW-space vertices; the
//     divide happens in the projector. z = 1.0 makes x/z = x, so a vertex fed
//     at x is expected at xc + x exactly -- no float comparison that "nearly"
//     passed.
//
// THE FIRST VERSION OF THIS BENCH HAD THE GEOMETRY WRONG, and that is worth
// recording. It was written believing study R172: that Model 2 has no
// perspective divide and that apply_focus leaves a vertex already in pixels.
// It fed pixel coordinates and clipped them against a pixel box, and the
// clipper -- which tests p.x < p.z * a_left, a FRUSTUM plane in view space --
// accepted the polygon and never emitted or dropped it. That hang is what sent
// this back to MAME, where model2_3d_project divides by pz plainly. The bench
// found a design error, not a wiring error, which is the whole reason for
// writing one before a build.

#include "Vm2_geometry.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>

static Vm2_geometry* d;
static std::vector<uint32_t> obj(4096, 0);
static long checks = 0, fails = 0;

static void tick() {
  d->mem_ack = d->mem_req;
  if (d->mem_req) d->mem_data = obj[d->mem_addr & 0xfff];
  d->clk = 0; d->eval();
  d->clk = 1; d->eval();
}

static uint32_t f2u(float f){ uint32_t u; std::memcpy(&u,&f,4); return u; }

static void ck(const char* w, int32_t got, int32_t want) {
  checks++;
  if (got != want) { std::printf("  FAIL %-32s got=%d want=%d\n", w, got, want); fails++; }
}

static size_t put_v(size_t w, float x, float y, float z) {
  obj[w++] = f2u(x); obj[w++] = f2u(y); obj[w++] = f2u(z);
  return w;
}

static void load_identity() {
  static const float I[12] = {1,0,0, 0,1,0, 0,0,1, 0,0,0};
  for (int i = 0; i < 12; i++) { d->mat_we = 1; d->mat_idx = i; d->mat_data = f2u(I[i]); tick(); }
  d->mat_we = 0; tick();
}

struct Quad { int32_t x0,y0,x1,y1,x2,y2,x3,y3; uint32_t col; };

static std::vector<Quad> run_object() {
  d->start = 1; tick(); d->start = 0;
  std::vector<Quad> got;
  // RUN THE WHOLE BUDGET. `busy` is the ENGINE's, and the engine finishes long
  // before the four vertices have been through a 29-cycle reciprocal each and
  // the clipper has run four planes over them. Breaking on it reported "no
  // quads" for a pipeline that had simply not got there yet -- the bench
  // measuring its own impatience.
  for (int budget = 0; budget < 40000; budget++) {
    tick();
    if (d->q_valid && d->q_ready)
      got.push_back({(int16_t)d->q_x0,(int16_t)d->q_y0,(int16_t)d->q_x1,(int16_t)d->q_y1,
                     (int16_t)d->q_x2,(int16_t)d->q_y2,(int16_t)d->q_x3,(int16_t)d->q_y3,
                     d->q_col});
  }
  std::printf("  [engine polys=%u objects=%u busy=%d]\n",
              d->dbg_polys, d->dbg_objects, (int)d->busy);
  return got;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_geometry;
  d->rst_n = 0; d->start = 0; d->q_ready = 1; d->mem_ack = 0; d->mat_we = 0;
  // The four frustum planes as slopes, for a 496x384 screen centred at
  // (248,192): a_left = (0-xc), a_right = (496-xc), a_bottom = (-0+yc),
  // a_top = (-384+yc). See m2_geo_clip's header for the tests they feed.
  d->xc = 0x43780000u; d->yc = 0x43400000u;               // 248.0, 192.0
  d->a_left = 0xC3780000u; d->a_right  = 0x43780000u;     // -248.0, 248.0
  d->a_bottom = 0x43400000u; d->a_top  = 0xC3400000u;     //  192.0, -192.0
  d->flat_col = 0xC0C0C0u;
  d->foc_x = f2u(1.0f); d->foc_y = f2u(1.0f);
  d->oba = 0; d->obc = 32;
  for (int i = 0; i < 8; i++) tick();
  d->rst_n = 1; tick();
  load_identity();

  // ---- test 1: one quad, wholly on screen, lands where the projection says
  //
  // The engine's mapping is v0=P1(n-1) v1=P0(n-1) v2=P0(n) v3=P1(n), so laying
  // the four corners down in stream order gives a square wound consistently.
  // z = 1.0 throughout, so x/z = x and the projection reduces to
  //     sx = xc + x = 248 + x        sy = yc - y = 192 - y
  {
    size_t w = 0;
    w = put_v(w, -50.0f,  50.0f, 1.0f);    // P0(n-1) -> (198, 142)
    w = put_v(w, -50.0f, -50.0f, 1.0f);    // P1(n-1) -> (198, 242)
    obj[w++] = 0x00000001u;                // quad, link 0, (attr&3) != 0
    w = put_v(w, 0.0f, 0.0f, 1.0f);        // normal, read and discarded
    w = put_v(w,  50.0f,  50.0f, 1.0f);    // P0(n)   -> (298, 142)
    w = put_v(w,  50.0f, -50.0f, 1.0f);    // P1(n)   -> (298, 242)
    obj[w++] = 0x00000000u;                // terminate

    auto got = run_object();
    std::printf("test: an on-screen quad projects to the pixels the reference gives\n");
    std::printf("  %zu quads out, clip in=%u out=%u dropped=%u\n",
                got.size(), d->dbg_clip_in, d->dbg_clip_out, d->dbg_clip_dropped);
    ck("quad count", (int32_t)got.size(), 1);
    if (got.size() >= 1) {
      ck("v0 = P1(n-1) x", got[0].x0, 198);  ck("v0 = P1(n-1) y", got[0].y0, 242);
      ck("v1 = P0(n-1) x", got[0].x1, 198);  ck("v1 = P0(n-1) y", got[0].y1, 142);
      ck("v2 = P0(n) x",   got[0].x2, 298);  ck("v2 = P0(n) y",   got[0].y2, 142);
      ck("v3 = P1(n) x",   got[0].x3, 298);  ck("v3 = P1(n) y",   got[0].y3, 242);
      ck("flat colour carried", (int32_t)got[0].col, 0xC0C0C0);
    }
    ck("clipper saw one polygon", (int32_t)d->dbg_clip_in, 1);
  }

  // ---- test 2: a quad wholly off the right edge is DROPPED, not drawn
  //
  // This is the check that the clipper is actually in the path. Without it, a
  // pipeline that ignored the window entirely would pass test 1 unchanged.
  {
    d->rst_n = 0; for (int i = 0; i < 4; i++) tick(); d->rst_n = 1; tick();
    load_identity();
    size_t w = 0;
    w = put_v(w, 2000.0f,  50.0f, 1.0f);   // x = 2000 > a_right(248)*z: outside
    w = put_v(w, 2000.0f, -50.0f, 1.0f);
    obj[w++] = 0x00000001u;
    w = put_v(w, 0.0f, 0.0f, 1.0f);
    w = put_v(w, 2100.0f,  50.0f, 1.0f);
    w = put_v(w, 2100.0f, -50.0f, 1.0f);
    obj[w++] = 0x00000000u;

    auto got = run_object();
    std::printf("test: an off-screen quad is dropped by the clipper\n");
    std::printf("  %zu quads out, clip in=%u out=%u dropped=%u\n",
                got.size(), d->dbg_clip_in, d->dbg_clip_out, d->dbg_clip_dropped);
    ck("nothing drawn", (int32_t)got.size(), 0);
    ck("counted as dropped", (int32_t)d->dbg_clip_dropped, 1);
  }

  // ---- test 3: THE POOL IS SHARED AND STILL CORRECT
  //
  // Focus of 2.0 in x and 4.0 in y makes the focus multiplies land on results
  // distinguishable from the transform's and from the projector's, so a tag
  // routed to the wrong client of the pool shows up as a coordinate scaled by
  // the wrong factor rather than as a hang. With z = 1:
  //     sx = 248 + 2*x        sy = 192 - 4*y
  {
    d->rst_n = 0; for (int i = 0; i < 4; i++) tick(); d->rst_n = 1; tick();
    load_identity();
    d->foc_x = f2u(2.0f); d->foc_y = f2u(4.0f);
    size_t w = 0;
    w = put_v(w, -50.0f,  10.0f, 1.0f);    // P0(n-1) -> (148, 152)
    w = put_v(w, -50.0f, -10.0f, 1.0f);    // P1(n-1) -> (148, 232)
    obj[w++] = 0x00000001u;
    w = put_v(w, 0.0f, 0.0f, 1.0f);
    w = put_v(w,  50.0f,  10.0f, 1.0f);    // P0(n)   -> (348, 152)
    w = put_v(w,  50.0f, -10.0f, 1.0f);    // P1(n)   -> (348, 232)
    obj[w++] = 0x00000000u;

    auto got = run_object();
    std::printf("test: focus and transform share one multiplier without crossing\n");
    ck("quad count", (int32_t)got.size(), 1);
    if (got.size() >= 1) {
      ck("focus.x scales v1 x", got[0].x1, 148);
      ck("focus.y scales v1 y", got[0].y1, 152);
      ck("focus.y scales v0 y", got[0].y0, 232);
      ck("focus.x scales v2 x", got[0].x2, 348);
    }
  }

  // ---- test 4: THE PIPELINE DRAINS AND RESTARTS
  //
  // busy must fall and a second object must run. A clipper stuck waiting on its
  // projector, or a pool grant never released, both show up here and nowhere
  // else -- one object in isolation can hang on the very last vertex and still
  // have produced the right quads.
  {
    auto got = run_object();
    std::printf("test: a second object runs after the first drained\n");
    ck("second object emitted", (int32_t)got.size(), 1);
    ck("engine idle at the end", (int32_t)d->busy, 0);
  }

  // ---- test 5: A POLYGON THAT STRADDLES A PLANE, which is the only case that
  //      exercises the shared projector's arbiter at all.
  //
  // Tests 1 to 4 feed quads that are wholly inside or wholly outside. The
  // clipper cuts nothing in either case, so it never creates a vertex, so it
  // never drives pj_* -- and k_pj_valid had never once been asserted. The
  // arbitration between the quad projector and the clipper, which is the piece
  // most likely to be wrong and the piece that hangs the frame when it is, was
  // untested by a bench that reported 20 passing checks.
  //
  // This quad crosses the right plane: x runs from -50 to +400 with z = 1, and
  // a_right is 248. The clipper must cut it, project the two vertices it
  // creates, and emit a quad clamped to the right edge.
  {
    d->rst_n = 0; for (int i = 0; i < 4; i++) tick(); d->rst_n = 1; tick();
    load_identity();
    d->foc_x = f2u(1.0f); d->foc_y = f2u(1.0f);
    size_t w = 0;
    w = put_v(w, -50.0f,  50.0f, 1.0f);   // P0(n-1) inside
    w = put_v(w, -50.0f, -50.0f, 1.0f);   // P1(n-1) inside
    obj[w++] = 0x00000001u;
    w = put_v(w, 0.0f, 0.0f, 1.0f);
    w = put_v(w, 400.0f,  50.0f, 1.0f);   // P0(n)   outside: 400 > 248
    w = put_v(w, 400.0f, -50.0f, 1.0f);   // P1(n)   outside
    obj[w++] = 0x00000000u;

    auto got = run_object();
    std::printf("test: a straddling quad is CUT, and the clipper's own vertices project\n");
    std::printf("  %zu quads out, clip in=%u out=%u dropped=%u\n",
                got.size(), d->dbg_clip_in, d->dbg_clip_out, d->dbg_clip_dropped);
    ck("the clipper saw it",   (int32_t)d->dbg_clip_in, 1);
    ck("not dropped whole",    (int32_t)d->dbg_clip_dropped, 0);
    ck("something was emitted", (int32_t)(got.size() > 0), 1);
    if (got.size() >= 1) {
      // Every vertex of every emitted quad must be inside the right edge. The
      // cut vertices come back through m2_geo_project via pj_*, so a broken
      // arbiter shows up here as a coordinate belonging to another vertex --
      // or, if it deadlocks instead, as nothing emitted at all above.
      int32_t worst = -32768;
      for (auto& q : got) {
        for (int32_t v : {q.x0, q.x1, q.x2, q.x3}) if (v > worst) worst = v;
      }
      // xc + a_right = 248 + 248 = 496, the right edge, with a pixel of slack
      // for the reciprocal's last place (see m2_geo_project's header).
      checks++;
      if (worst > 497) {
        std::printf("  FAIL clipped quad still crosses the right edge: x=%d\n", worst);
        fails++;
      } else {
        std::printf("  rightmost vertex after the cut: x=%d (edge is 496)\n", worst);
      }
    }
    ck("pipeline idle after the cut", (int32_t)d->busy, 0);
  }

  // ---- test 6: THE OBJECT THAT ISN'T THERE. Unwritten memory reads 0xFFFF...,
  //      and 0xFFFFFFFF read as an IEEE-754 float is a NaN.
  //
  // This is not hypothetical. On hardware Daytona's display list points its one
  // object_data at SLOW POLYGON RAM, and geo_polygon_data (opcode 0x05) is not
  // implemented, so that RAM has never been written. The engine transformed
  // NaN vertices, the projector divided by a NaN z, and the pipeline stopped:
  //
  //     H 00010000 04030000
  //       objects rom=0 pram0=1 pram1=0 capped=0
  //       clip in=4 out=3 dropped=0, quads=0
  //
  // -- frozen on every record. One polygon went into the clipper and never came
  // out, so in_ready stayed low, so busy never fell, so the walker sat in
  // W_OBJW and THE WHOLE DISPLAY LIST WALK DIED after one object.
  //
  // docs/mister-integration.md has required for a long time that tests use
  // 0xFFFF for unwritten memory rather than zero. Every bench in this file fed
  // clean floats. This one does not.
  {
    d->rst_n = 0; for (int i = 0; i < 4; i++) tick(); d->rst_n = 1; tick();
    load_identity();
    d->foc_x = f2u(1.0f); d->foc_y = f2u(1.0f);
    for (size_t i = 0; i < obj.size(); i++) obj[i] = 0xFFFFFFFFu;

    d->start = 1; tick(); d->start = 0;
    bool went_busy = false;
    int  idle_after_busy = 0;
    for (int budget = 0; budget < 400000; budget++) {
      tick();
      if (d->busy) { went_busy = true; idle_after_busy = 0; }
      else if (went_busy && ++idle_after_busy > 2000) break;
    }
    std::printf("test: an object of unwritten memory (0xFFFFFFFF = NaN) must not wedge\n");
    std::printf("  clip in=%u out=%u dropped=%u, capped=%u, busy=%d\n",
                d->dbg_clip_in, d->dbg_clip_out, d->dbg_clip_dropped,
                d->dbg_capped, (int)d->busy);
    checks++;
    if (d->busy) {
      std::printf("  FAIL pipeline still busy -- this is the hardware hang\n");
      fails++;
    } else {
      std::printf("  pipeline drained and released busy\n");
    }
    // Every polygon the clipper accepted must be accounted for: emitted or
    // dropped. One unaccounted polygon IS the hang.
    checks++;
    if (d->dbg_clip_in > d->dbg_clip_out + d->dbg_clip_dropped) {
      std::printf("  FAIL %u polygons accepted but only %u emitted + %u dropped\n",
                  d->dbg_clip_in, d->dbg_clip_out, d->dbg_clip_dropped);
      fails++;
    }
  }

  // ---- test 7: z = 0. FINITE, SO THE NaN GATE PASSES IT, AND 1/z IS NOT.
  //
  // The board is wedged in W_OBJW with nonfinite=0: 67 objects seen, the
  // geometry engine started and never finished, and nothing was refused. So
  // whatever hangs it is NOT a NaN -- the gate would have caught that. A vertex
  // at z = 0 is the obvious candidate: perfectly finite, passes every check the
  // pipeline makes, and the projector's reciprocal divides by it.
  //
  // MAME cannot show this either. model2_3d_project adds
  // std::numeric_limits<float>::min() to pz before dividing, precisely so the
  // divide cannot blow up -- a guard that costs nothing in C and does not exist
  // in our fp_div.
  {
    d->rst_n = 0; for (int i = 0; i < 4; i++) tick(); d->rst_n = 1; tick();
    load_identity();
    d->foc_x = f2u(1.0f); d->foc_y = f2u(1.0f);
    size_t w = 0;
    w = put_v(w, -50.0f,  50.0f, 0.0f);    // z = 0 on every vertex
    w = put_v(w, -50.0f, -50.0f, 0.0f);
    obj[w++] = 0x00000001u;
    w = put_v(w, 0.0f, 0.0f, 1.0f);
    w = put_v(w,  50.0f,  50.0f, 0.0f);
    w = put_v(w,  50.0f, -50.0f, 0.0f);
    obj[w++] = 0x00000000u;

    auto got = run_object();
    std::printf("test: a polygon at z=0 must not wedge the pipeline\n");
    std::printf("  clip in=%u out=%u dropped=%u nonfinite=%u busy=%d\n",
                d->dbg_clip_in, d->dbg_clip_out, d->dbg_clip_dropped,
                d->dbg_nonfinite, (int)d->busy);
    checks++;
    if (d->busy) {
      std::printf("  FAIL pipeline still busy -- this is the W_OBJW hang\n");
      fails++;
    } else {
      std::printf("  pipeline drained and released busy\n");
    }
  }

  std::printf("m2_geometry: checks=%ld fails=%ld\n", checks, fails);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
