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
#include <cmath>

static Vm2_geo_engine_top* d;
static std::vector<uint32_t> obj(4096, 0);
static long checks = 0, fails = 0;

// R222: the other three memory spaces the engine reads, as 16-bit words --
// the texture header (space 1), the palette mirror (2), the translation table
// mirror (3) -- served as the dword pair at the requested dword address.
static std::vector<uint16_t> thdr(0x1000, 0xffff), pal3d(1024, 0xffff), xlat(3 * 0x2000, 0xffff);
static uint32_t rd16pair(const std::vector<uint16_t>& m, uint32_t dw) {
  const uint32_t w = dw * 2;
  const uint16_t lo = w < m.size() ? m[w] : 0xffff, hi = (w + 1) < m.size() ? m[w + 1] : 0xffff;
  return uint32_t(lo) | (uint32_t(hi) << 16);
}
static void tick() {
  // the vertex stream: one dword per acknowledge, no wait states
  d->mem_ack = d->mem_req;
  if (d->mem_req) {
    switch (d->mem_space) {
      case 1:  d->mem_data = rd16pair(thdr,  d->mem_addr & 0x7fffff); break;
      case 2:  d->mem_data = rd16pair(pal3d, d->mem_addr); break;
      case 3:  d->mem_data = rd16pair(xlat,  d->mem_addr); break;
      default: d->mem_data = obj[d->mem_addr & 0xfff]; break;
    }
  }
  d->clk = 0; d->eval();
  d->clk = 1; d->eval();
}

static uint32_t f2u(float f){ uint32_t u; std::memcpy(&u,&f,4); return u; }

// R222: the reference's flat colour, transcribed (model2_v.cpp geo_parse_np_ns,
// model2rd.ipp flat case, m2_palette's gamma).
static uint8_t gam(uint8_t v) { double r = ((double)v - 64.0) * 255.0 / 191.0; return r < 0 ? 0 : (uint8_t)r; }
static int ref_luma(const float n[3], const float pt[3], const float lit[3], float diffuse, float ambient) {
  float dotl = n[0]*lit[0] + n[1]*lit[1] + n[2]*lit[2];
  float dotp = n[0]*pt[0] + n[1]*pt[1] + n[2]*pt[2];
  float lum = (dotl * dotp < 0) ? 0.0f : std::fabs(dotl);
  lum = lum * diffuse + ambient;
  if (lum < 0) lum = 0;
  if (lum > 255) lum = 255;
  return (int)lum;
}
static uint32_t ref_colour(uint16_t c555, int luma) {
  uint8_t c[3];
  for (int i = 0; i < 3; i++) {
    const uint32_t c5 = (c555 >> (5 * i)) & 0x1f;
    c[i] = gam(xlat[i * 0x2000 + ((c5 << 8) | (luma >> 2))] & 0xff);
  }
  return (uint32_t(c[0]) << 16) | (uint32_t(c[1]) << 8) | c[2];
}

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

  // R222: the light, texture parameter 0 (diffuse 200, ambient 20), a flat
  // texture header at ROM word 0x100 with colorbase 0x155, that palette entry,
  // and a translation table whose entries are a known function of their index.
  const float LIT[3] = {0.001f, 0.0005f, -0.0002f};
  d->lit_x = f2u(LIT[0]); d->lit_y = f2u(LIT[1]); d->lit_z = f2u(LIT[2]);
  d->tp_we = 1; d->tp_idx = 0; d->tp_diffuse = 200; d->tp_ambient = 20; tick(); d->tp_we = 0;
  d->tha = 0x100;
  thdr[0x100 + 0] = 0x0000; thdr[0x100 + 1] = 0; thdr[0x100 + 2] = 0; thdr[0x100 + 3] = uint16_t(0x155 << 6);
  const uint16_t C555 = 0x2AAC;
  pal3d[0x155] = C555;
  for (int c = 0; c < 3; c++) for (int i = 0; i < 0x2000; i++)
    xlat[c * 0x2000 + i] = uint16_t(0xA500 | ((((i >> 8) & 0x1f) * 7 + (i & 0x3f) * 3 + c * 11) & 0xff));
  d->col_inval = 0; d->tex_lum = 0;

  // ---- build one object: three polygons exercising all three link types
  size_t w = 0;
  w = put_xyz(w, 100.0f);          // P0(n-1)
  w = put_xyz(w, 200.0f);          // P1(n-1)
  // polygon 1: QUAD, link type 2 -> reuse P0(n) and P1(n), the same carry
  // as link 0. Link 0 itself is CULLED, as the reference culls it (R219),
  // so it cannot be the emitted case here; bit 17 makes each polygon
  // double-sided so the face test cannot cull the check either.
  obj[w++] = 0x00020201u;          // attr: bit0 quad, bits1:0 != 0, link 2, double-sided
  w = put_xyz(w, 300.0f);          // normal, read and discarded
  w = put_xyz(w, 400.0f);          // P0(n)
  w = put_xyz(w, 500.0f);          // P1(n)
  // polygon 2: TRIANGLE, link type 1 -> reuse P0(n-1) and P0(n)
  obj[w++] = 0x00020102u;          // attr: bit0 clear = triangle, link 1, double-sided
  w = put_xyz(w, 600.0f);          // normal
  w = put_xyz(w, 700.0f);          // P0(n)
  w = put_xyz(w, 800.0f);          // the point a triangle CONSUMES and discards
  // polygon 3: QUAD, link type 3 -> reuse P1(n-1) and P1(n)
  obj[w++] = 0x00020301u;          // link 3, double-sided
  w = put_xyz(w, 900.0f);
  w = put_xyz(w, 1000.0f);         // P0(n)
  w = put_xyz(w, 1100.0f);         // P1(n)
  obj[w++] = 0x00000000u;          // (attr & 3) == 0 terminates

  d->oba = 0; d->obc = 16;
  d->start = 1; tick(); d->start = 0;

  struct Poly { uint32_t v0,v1,v2,v3,attr,nx; uint32_t luma = 0, col = 0; };
  std::vector<Poly> got;
  for (int budget = 0; budget < 60000 && (d->busy || got.empty()); budget++) {
    tick();
    if (d->poly_valid && d->poly_ready)
      got.push_back({d->v0x, d->v1x, d->v2x, d->v3x, d->poly_attr, d->nrm_x, d->poly_luma, d->poly_col});
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

    // link 2 carried BOTH (as link 0 does): P0(n-1)=400, P1(n-1)=500
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

    // THE NORMAL IS KEPT, NOT DISCARDED. It used to be read and thrown away.
    // Model 2's luminance is dot(normal, light) against dot(normal, point), so
    // these three words are half of every lit pixel. The bench writes each
    // polygon's normal as a distinct base value, so a normal belonging to the
    // wrong polygon is visible on sight.
    ck("p1 normal x", got[0].nx, f2u(300.0f));
    ck("p2 normal x", got[1].nx, f2u(600.0f));
    ck("p3 normal x", got[2].nx, f2u(900.0f));

    // R222: THE LUMINANCE AND THE COLOUR, against the reference's arithmetic.
    // The normal is (b, b+1, b+2), the first new point P0(n) likewise; identity
    // matrix, so both are as fed. The luminance may land one either side of
    // the float model at an integer boundary; the colour must follow the luma.
    std::printf("test: luminance and colour (R222)\n");
    const float NB[3] = {300.0f, 600.0f, 900.0f}, PB[3] = {400.0f, 700.0f, 1000.0f};
    for (int i = 0; i < 3; i++) {
      const float n[3] = {NB[i], NB[i] + 1, NB[i] + 2}, pt[3] = {PB[i], PB[i] + 1, PB[i] + 2};
      const int want = ref_luma(n, pt, LIT, 200.0f, 20.0f);
      const int lu = int(got[i].luma);
      checks++;
      if (std::abs(lu - want) > 1) { std::printf("  FAIL p%d luma got=%d want=%d\n", i + 1, lu, want); fails++; }
      std::printf("  p%d luma %d (model %d) colour %06x\n", i + 1, lu, want, got[i].col);
      ck("colour follows the luma", got[i].col, ref_colour(C555, lu));
    }
    ck("three colour cache misses", d->dbg_col_miss, 3);
  }

  // ---- R222: a light from behind gives the ambient alone; the cache then hits
  {
    d->lit_x = f2u(-0.002f); d->lit_y = f2u(0.0005f); d->lit_z = f2u(0.0002f);
    d->rst_n = 0; for (int i = 0; i < 4; i++) tick(); d->rst_n = 1; tick();
    for (int i = 0; i < 12; i++) {
      static const float I[12] = {1,0,0, 0,1,0, 0,0,1, 0,0,0};
      d->mat_we = 1; d->mat_idx = i; d->mat_data = f2u(I[i]); tick();
    }
    d->mat_we = 0;
    d->tp_we = 1; d->tp_idx = 0; d->tp_diffuse = 200; d->tp_ambient = 20; tick(); d->tp_we = 0;
    d->start = 1; tick(); d->start = 0;
    std::vector<Poly> gd;
    for (int budget = 0; budget < 60000 && (d->busy || gd.empty()); budget++) {
      tick();
      if (d->poly_valid && d->poly_ready) gd.push_back({d->v0x, d->v1x, d->v2x, d->v3x, d->poly_attr, d->nrm_x, d->poly_luma, d->poly_col});
    }
    std::printf("test: dotl and dotp of opposite sign -> luminance is the ambient alone\n");
    ck("three polygons", uint32_t(gd.size()), 3);
    for (size_t i = 0; i < gd.size(); i++) ck("luma = ambient", gd[i].luma, 20);
    if (!gd.empty()) ck("colour at luma 20", gd[0].col, ref_colour(C555, 20));
    // Reset cleared the cache: one miss for the first polygon, hits for the rest.
    ck("one miss then hits", d->dbg_col_miss, 1);
    // The CPU rewriting the palette invalidates the cache.
    d->col_inval = 1; tick(); d->col_inval = 0;
    d->start = 1; tick(); d->start = 0;
    for (int budget = 0; budget < 60000 && (d->busy || budget < 10); budget++) tick();
    ck("invalidate forces one more miss", d->dbg_col_miss, 2);
  }

  // ---- R222: ANY translucent header (word 0 bit 13) draws nothing, textured
  //      or not -- the reference's two translucent callbacks both return.
  for (uint16_t h0 : {uint16_t(0x2000), uint16_t(0x6000)})
  {
    thdr[0x100 + 0] = h0;
    d->rst_n = 0; for (int i = 0; i < 4; i++) tick(); d->rst_n = 1; tick();
    for (int i = 0; i < 12; i++) {
      static const float I[12] = {1,0,0, 0,1,0, 0,0,1, 0,0,0};
      d->mat_we = 1; d->mat_idx = i; d->mat_data = f2u(I[i]); tick();
    }
    d->mat_we = 0;
    d->tp_we = 1; d->tp_idx = 0; d->tp_diffuse = 200; d->tp_ambient = 20; tick(); d->tp_we = 0;
    d->start = 1; tick(); d->start = 0;
    uint32_t n = 0;
    for (int budget = 0; budget < 60000 && (d->busy || budget < 10); budget++) { tick(); if (d->poly_valid && d->poly_ready) n++; }
    std::printf("test: translucent polygons are culled (header %04x)\n", h0);
    ck("no polygons emitted", n, 0);
    ck("three culled", d->dbg_culled, 3);
    thdr[0x100 + 0] = 0x0000;
  }
  // ---- and a TEXTURED OPAQUE header still draws, flat, in its palette colour
  {
    thdr[0x100 + 0] = 0x4000;
    d->rst_n = 0; for (int i = 0; i < 4; i++) tick(); d->rst_n = 1; tick();
    for (int i = 0; i < 12; i++) {
      static const float I[12] = {1,0,0, 0,1,0, 0,0,1, 0,0,0};
      d->mat_we = 1; d->mat_idx = i; d->mat_data = f2u(I[i]); tick();
    }
    d->mat_we = 0;
    d->tp_we = 1; d->tp_idx = 0; d->tp_diffuse = 200; d->tp_ambient = 20; tick(); d->tp_we = 0;
    d->start = 1; tick(); d->start = 0;
    uint32_t n = 0, col0 = 0, luma0 = 0;
    for (int budget = 0; budget < 60000 && (d->busy || budget < 10); budget++) { tick(); if (d->poly_valid && d->poly_ready) { if (!n) { col0 = d->poly_col; luma0 = d->poly_luma; } n++; } }
    std::printf("test: textured opaque polygons still draw, as lit grey (R231)\n");
    // grey 16/16/16 through the same table and gamma as a flat polygon would be
    // R234: its palette entry is not black, so it keeps it, at HALF the luma
    ck("textured polygon keeps its palette colour at full luma", col0, ref_colour(C555, (int)luma0));
    ck("three polygons emitted", n, 3);
    thdr[0x100 + 0] = 0x0000;
  }
  // ---- R234: a textured polygon whose palette entry is BLACK takes the grey
  {
    thdr[0x100 + 0] = 0x4000; pal3d[0x155] = 0x0000;
    d->rst_n = 0; for (int i = 0; i < 4; i++) tick(); d->rst_n = 1; tick();
    for (int i = 0; i < 12; i++) {
      static const float I[12] = {1,0,0, 0,1,0, 0,0,1, 0,0,0};
      d->mat_we = 1; d->mat_idx = i; d->mat_data = f2u(I[i]); tick();
    }
    d->mat_we = 0;
    d->tp_we = 1; d->tp_idx = 0; d->tp_diffuse = 200; d->tp_ambient = 20; tick(); d->tp_we = 0;
    d->start = 1; tick(); d->start = 0;
    uint32_t n = 0, col0 = 0, luma0 = 0;
    for (int budget = 0; budget < 60000 && (d->busy || budget < 10); budget++) { tick(); if (d->poly_valid && d->poly_ready) { if (!n) { col0 = d->poly_col; luma0 = d->poly_luma; } n++; } }
    std::printf("test: a textured polygon with a black palette entry takes the grey\n");
    ck("grey at half luma", col0, ref_colour(0x4210, (int)luma0 >> 1));
    thdr[0x100 + 0] = 0x0000; pal3d[0x155] = C555;
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

  // ---- transform_vector: the normal is ROTATED but NOT TRANSLATED
  //
  // MAME uses one matrix for both and distinguishes them by which function it
  // calls: transform_point adds matrix[9..11], transform_vector does not. If
  // the engine left in_translate at 1 for the normal, the normal would pick up
  // the object's position -- and a normal that moves with the object gives
  // luminance that changes as the object slides across the screen, which is
  // wrong in a way that looks like flickering rather than like a bug.
  //
  // The matrix below scales by 2 and translates by 1000, so a point comes out
  // as 2x+1000 and a normal as 2x exactly.
  {
    d->rst_n = 0; for (int i = 0; i < 4; i++) tick(); d->rst_n = 1; tick();
    static const float M[12] = {2,0,0, 0,2,0, 0,0,2, 1000,1000,1000};
    for (int i = 0; i < 12; i++) { d->mat_we = 1; d->mat_idx = i; d->mat_data = f2u(M[i]); tick(); }
    d->mat_we = 0;
    d->foc_x = f2u(1.0f); d->foc_y = f2u(1.0f);
    tick();
    d->start = 1; tick(); d->start = 0;
    uint32_t got_nx = 0, got_v1 = 0; bool any = false;
    for (int budget = 0; budget < 60000 && (d->busy || !any); budget++) {
      tick();
      if (d->poly_valid && d->poly_ready && !any) {
        got_nx = d->nrm_x; got_v1 = d->v1x; any = true;
      }
    }
    std::printf("test: the normal is rotated, not translated\n");
    // P0(n-1) was fed x=100: transform_point -> 100*2 + 1000 = 1200
    ck("point picks up the translation", got_v1, f2u(1200.0f));
    // polygon 1's normal was fed x=300: transform_vector -> 300*2 = 600
    ck("normal does NOT",                got_nx, f2u(600.0f));
  }

  std::printf("m2_geo_engine: checks=%ld fails=%ld\n", checks, fails);
  delete d;
  return fails ? 1 : 0;
}
