// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// m2_geo_engine: does an object_data command become the right stream of quads?
//
// The arithmetic is not the question here -- m2_geo_xform is already verified
// at 7,813 checks against host float. What this proves is the GRAMMAR, which is
// where a sequencer written from a misremembering fails silently:
//
//   * the vertex mapping   v0=P1(n-1) v1=P0(n-1) v2=P0(n) v3=P1(n), with v0 and
//                          v1 SWAPPED relative to command_buffer order
//   * the link             (attr>>8)&3 selects one of THREE carries, not a strip
//   * the triangle rope    P1(n) = P0(n)
//   * the consumed point   a triangle still reads the three words it discards
//   * termination          (attr & 3) == 0
//
// The matrix is the identity so a vertex arrives as the value that was fed in,
// which makes every check above readable as an exact word rather than as a
// float comparison. Study R171 has the grammar itself.

#include "Vm2_geo_engine_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>

static Vm2_geo_engine_top* d;
static std::vector<uint32_t> obj(4096, 0);
static long checks = 0, fails = 0;

static void tick() {
  // the vertex stream: one dword per acknowledge, no wait states
  d->mem_ack = d->mem_req;
  if (d->mem_req) d->mem_data = obj[d->mem_addr & 0xfff];
  d->clk = 0; d->eval();
  d->clk = 1; d->eval();
}

static uint32_t f2u(float f){ uint32_t u; std::memcpy(&u,&f,4); return u; }

static void ck(const char* w, uint32_t got, uint32_t want) {
  checks++;
  if (got != want) { std::printf("  FAIL %-30s got=%08x want=%08x\n", w, got, want); fails++; }
}

// A vertex is written as three consecutive words. Values are chosen so each
// vertex is identifiable on sight in a failure message.
static size_t put_xyz(size_t w, float base) {
  obj[w++] = f2u(base + 0.0f);
  obj[w++] = f2u(base + 1.0f);
  obj[w++] = f2u(base + 2.0f);
  return w;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_geo_engine_top;
  d->rst_n = 0; d->start = 0; d->poly_ready = 1; d->mem_ack = 0;
  for (int i = 0; i < 8; i++) tick();
  d->rst_n = 1; tick();

  // identity matrix: a transformed point comes out as it went in
  for (int i = 0; i < 12; i++) {
    static const float I[12] = {1,0,0, 0,1,0, 0,0,1, 0,0,0};
    d->mat_we = 1; d->mat_idx = i; d->mat_data = f2u(I[i]); tick();
  }
  d->mat_we = 0;
  // FOCUS OF 1.0 keeps every expected value an exact word, so the grammar
  // checks below stay readable. A second pass re-runs with a real focus.
  d->foc_x = f2u(1.0f); d->foc_y = f2u(1.0f);
  tick();

  // ---- build one object: three polygons exercising all three link types
  size_t w = 0;
  w = put_xyz(w, 100.0f);          // P0(n-1)
  w = put_xyz(w, 200.0f);          // P1(n-1)
  // polygon 1: QUAD, link type 0 -> reuse P0(n) and P1(n)
  obj[w++] = 0x00000001u;          // attr: bit0 quad, bits1:0 != 0, link 0
  w = put_xyz(w, 300.0f);          // normal, read and discarded
  w = put_xyz(w, 400.0f);          // P0(n)
  w = put_xyz(w, 500.0f);          // P1(n)
  // polygon 2: TRIANGLE, link type 1 -> reuse P0(n-1) and P0(n)
  obj[w++] = 0x00000102u;          // attr: bit0 clear = triangle, link 1
  w = put_xyz(w, 600.0f);          // normal
  w = put_xyz(w, 700.0f);          // P0(n)
  w = put_xyz(w, 800.0f);          // the point a triangle CONSUMES and discards
  // polygon 3: QUAD, link type 3 -> reuse P1(n-1) and P1(n)
  obj[w++] = 0x00000301u;
  w = put_xyz(w, 900.0f);
  w = put_xyz(w, 1000.0f);         // P0(n)
  w = put_xyz(w, 1100.0f);         // P1(n)
  obj[w++] = 0x00000000u;          // (attr & 3) == 0 terminates

  d->oba = 0; d->obc = 16;
  d->start = 1; tick(); d->start = 0;

  struct Poly { uint32_t v0,v1,v2,v3,attr; };
  std::vector<Poly> got;
  for (int budget = 0; budget < 60000 && (d->busy || got.empty()); budget++) {
    tick();
    if (d->poly_valid && d->poly_ready)
      got.push_back({d->v0x, d->v1x, d->v2x, d->v3x, d->poly_attr});
  }

  std::printf("test: an object_data becomes a stream of quads\n");
  std::printf("  %zu polygons emitted\n", got.size());
  ck("polygon count", uint32_t(got.size()), 3);

  if (got.size() >= 3) {
    // polygon 1: v0=P1(n-1)=200, v1=P0(n-1)=100, v2=P0(n)=400, v3=P1(n)=500
    ck("p1 v0 = P1(n-1)", got[0].v0, f2u(200.0f));
    ck("p1 v1 = P0(n-1)", got[0].v1, f2u(100.0f));
    ck("p1 v2 = P0(n)",   got[0].v2, f2u(400.0f));
    ck("p1 v3 = P1(n)",   got[0].v3, f2u(500.0f));

    // link 0 carried BOTH: P0(n-1)=400, P1(n-1)=500
    // polygon 2 is a TRIANGLE, so P1(n) is roped to P0(n)=700
    ck("p2 v0 = P1(n-1)<-500", got[1].v0, f2u(500.0f));
    ck("p2 v1 = P0(n-1)<-400", got[1].v1, f2u(400.0f));
    ck("p2 v2 = P0(n)",        got[1].v2, f2u(700.0f));
    ck("p2 v3 roped to P0(n)", got[1].v3, f2u(700.0f));

    // link 1 carried P0(n)->P1(n-1) only: P0(n-1) stays 400, P1(n-1) becomes 700
    ck("p3 v0 = P1(n-1)<-700", got[2].v0, f2u(700.0f));
    ck("p3 v1 = P0(n-1) kept", got[2].v1, f2u(400.0f));
    ck("p3 v2 = P0(n)",        got[2].v2, f2u(1000.0f));
    ck("p3 v3 = P1(n)",        got[2].v3, f2u(1100.0f));
  }

  // ---- second pass: focus is APPLIED, and to x and y only
  //
  // Model 2 has no perspective divide -- apply_focus IS the projection (study
  // R172) -- so this is the whole of it, and z must come through untouched.
  d->foc_x = f2u(2.0f); d->foc_y = f2u(4.0f);
  d->rst_n = 0; for (int i = 0; i < 4; i++) tick(); d->rst_n = 1; tick();
  for (int i = 0; i < 12; i++) {
    static const float I[12] = {1,0,0, 0,1,0, 0,0,1, 0,0,0};
    d->mat_we = 1; d->mat_idx = i; d->mat_data = f2u(I[i]); tick();
  }
  d->mat_we = 0; tick();
  d->start = 1; tick(); d->start = 0;
  std::vector<Poly> got2;
  std::vector<uint32_t> zs;
  for (int budget = 0; budget < 60000 && (d->busy || got2.empty()); budget++) {
    tick();
    if (d->poly_valid && d->poly_ready) { got2.push_back({d->v0x,d->v1x,d->v2x,d->v3x,d->poly_attr}); zs.push_back(d->v1z); }
  }
  std::printf("test: focus is the projection, applied to x and y only\n");
  if (got2.size() >= 1) {
    // P0(n-1) fed as x=100: focus.x = 2 -> 200
    ck("focus scales x", got2[0].v1, f2u(200.0f));
    // its z was fed as 102 and must be untouched
    ck("focus leaves z alone", zs[0], f2u(102.0f));
  } else { std::printf("  FAIL no polygons on the second pass\n"); fails++; }

  std::printf("m2_geo_engine: checks=%ld fails=%ld\n", checks, fails);
  delete d;
  return fails ? 1 : 0;
}
