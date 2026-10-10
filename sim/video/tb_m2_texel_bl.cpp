// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// tb_m2_texel_bl -- R620's bilinear texel fetch against a model written from
// model2rd.ipp's fetch_bilinear_texel and get_texel (not from the RTL):
// random sheets, random texture headers (size, place, sheet, mirror, wrap,
// translucent), random u/v, both filter modes, random memory latency on both
// ports, the second port switched off at times, and cache sweeps. Every answer
// is checked, in order.
//
// The two documented departures are modelled as the RTL makes them: a texel
// widens by replication (x * 0x11), and LERP is taken per field.

#include "Vm2_texel_bl.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <vector>
#include <random>

static Vm2_texel_bl *d;
static std::mt19937 rng(20260926u);
static const uint32_t BASE0 = 0x1760000, BASE1 = 0x17E0000;
static std::vector<uint16_t> sheet[2];
static int checks = 0, fails = 0;

static uint16_t word_at(uint32_t a) {
  if (a >= BASE1 && a < BASE1 + 0x80000) return sheet[1][a - BASE1];
  if (a >= BASE0 && a < BASE0 + 0x80000) return sheet[0][a - BASE0];
  return 0xffff;   // unwritten memory reads 0xFFFF, never zero (docs/mister-integration.md)
}
static uint64_t line_at(uint32_t a) {
  uint64_t l = 0;
  for (int k = 0; k < 4; k++) l |= uint64_t(word_at(a + k)) << (16 * k);
  return l;
}
// R787: built with -DTB_LW8 (and -GLW8=1 -GIB=10) a line is EIGHT words, as
// m2_sdram delivers an eight-word read: words 0-3 with a one-cycle m*_lo four
// cycles before the acknowledge, words 4-7 with it.
#ifdef TB_LW8
static const bool LW8 = true;
#else
static const bool LW8 = false;
#endif
static void set_lo(int p, uint64_t l) {
  if (p == 0) { d->m_lo = 1; d->m_data = l; }
  if (p == 1) { d->m2_lo = 1; d->m2_data = l; }
  if (p == 2) { d->m3_lo = 1; d->m3_data = l; }
  if (p == 3) { d->m4_lo = 1; d->m4_data = l; }
}

struct Req { uint32_t tex, u, v; int bl; };

// model2rd.ipp get_texel
static int get_texel(int base_x, int base_y, int x, int y, int sh) {
  int x2 = base_x + x, y2 = base_y + y;
  if (x2 >= 1024) { x2 -= 1024; y2 ^= 1024; }
  uint32_t offset = ((y2 / 2) * 512) + (x2 / 2);
  uint16_t w = sheet[sh][offset & 0x7ffff];
  int t = w;
  if ((y & 1) == 0) t >>= 8;
  if ((x & 1) == 0) t >>= 4;
  return t & 0xf;
}
static int lerp(int x, int y, int a) { return x + (((y - x) * a) >> 8); }

// model2rd.ipp fetch_bilinear_texel, level 0; returns {discard, t}
static uint32_t model(const Req &r) {
  const uint32_t t = r.tex;
  const int wcode = (t >> 1) & 7, hcode = (t >> 4) & 7;
  const int W = 32 << wcode, H = 32 << hcode;
  const int mirx = (t >> 9) & 1, miry = (t >> 10) & 1;
  const int wrapx = ((t >> 7) & 1) & !mirx;
  const int wrapy = 1 & !miry;                 // poly_tex has no wrap-y bit (R620)
  const int tl = (t >> 8) & 1;
  const int tex_x = ((t >> 13) & 0x3f) * 32, tex_y = ((t >> 19) & 0x1f) * 32;
  const int sh = (t >> 12) & 1;
  int32_t u = (int32_t)r.u, v = (int32_t)r.v;   // 12.8, non-negative, 20 bits
  if (mirx && (u & (W << 8))) u = ~u & 0xfffff;
  if (miry && (v & (H << 8))) v = ~v & 0xfffff;
  u = (u - 0x80) & 0xfffff; v = (v - 0x80) & 0xfffff;
  int uf = u & 0xff, vf = v & 0xff;
  int u0 = (u >> 8) & (W - 1), u1 = (u0 + 1) & (W - 1);
  int v0 = (v >> 8) & (H - 1), v1 = (v0 + 1) & (H - 1);
  if (!wrapx && u1 == 0) { if (uf >= 0x80) { u0 = u1; u1++; uf = 0; } else { u1 = u0; u0--; uf = 0x100; } }
  if (!wrapy && v1 == 0) { if (vf >= 0x80) { v0 = 0; v1++; vf = 0; } else { v1 = v0; v0--; vf = 0x100; } }
  const int n00 = get_texel(tex_x, tex_y, u0, v0, sh), n01 = get_texel(tex_x, tex_y, u1, v0, sh);
  const int n10 = get_texel(tex_x, tex_y, u0, v1, sh), n11 = get_texel(tex_x, tex_y, u1, v1, sh);
  if (!r.bl) {
    // the nearest of the four, after the clamp: (frac >= 0x80 ? i1 : i0).
    // Unclamped that is the old (u >> 8) sample; clamped, the edge column.
    const int nu = (uf >= 0x80) ? u1 : u0, nv = (vf >= 0x80) ? v1 : v0;
    const int n = get_texel(tex_x, tex_y, nu, nv, sh);
    return (uint32_t(tl && n == 0xf) << 8) | uint32_t(n * 0x11);
  }
  int l00 = n00 * 0x11, l01 = n01 * 0x11, l10 = n10 * 0x11, l11 = n11 * 0x11;
  int a00 = 0x80, a01 = 0x80, a10 = 0x80, a11 = 0x80;
  if (tl) {
    if (n00 == 0xf) a00 = 0; if (n01 == 0xf) a01 = 0; if (n10 == 0xf) a10 = 0; if (n11 == 0xf) a11 = 0;
    if (n00 == 0xf) l00 = l01;
    if (n01 == 0xf) l01 = l00;
    if (n10 == 0xf) l10 = l11;
    if (n11 == 0xf) l11 = l10;
  }
  int l0x = lerp(l00, l01, uf), a0x = lerp(a00, a01, uf);
  int l1x = lerp(l10, l11, uf), a1x = lerp(a10, a11, uf);
  if (tl) {
    if (a0x == 0 && l0x == 0xff) l0x = l1x;
    if (a1x == 0 && l1x == 0xff) l1x = l0x;
  }
  const int lo = lerp(l0x, l1x, vf), ao = lerp(a0x, a1x, vf);
  return (uint32_t(tl && ao < 0x40) << 8) | uint32_t(lo & 0xff);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const long N = std::getenv("M2_TBL_N") ? atol(std::getenv("M2_TBL_N")) : 200000;
  for (int s = 0; s < 2; s++) { sheet[s].resize(0x80000); for (auto &w : sheet[s]) w = rng() & 0xffff; }
  d = new Vm2_texel_bl;
  d->clk = 0; d->rst_n = 0; d->base_s0 = BASE0; d->base_s1 = BASE1; d->bilinear = 1;
  d->req = 0; d->m_ack = 0; d->m2_ack = 0; d->m2_en = 1; d->inval = 0;
  d->m3_ack = 0; d->m4_ack = 0; d->m3_en = 1; d->m4_en = 1;   // R628: used when built NS=4
  d->m_lo = 0; d->m2_lo = 0; d->m3_lo = 0; d->m4_lo = 0;       // R787
  auto tick = [&]() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };
  for (int i = 0; i < 8; i++) tick();
  d->rst_n = 1;
  std::deque<Req> sent;
  long issued = 0, answered = 0, cyc = 0;
  int lat[4] = {-1, -1, -1, -1}; uint32_t ad[4] = {0, 0, 0, 0};
  // R650: M2_TBL_SDRAM=1 -- the port as m2_sdram really is: a request is
  // dispatched on its RISING edge only, one at a time, and the acknowledge and
  // data are HELD for ACK_HOLD (2) cycles; M2_TBL_LMAX the latency's range.
  static const bool SDR = std::getenv("M2_TBL_SDRAM") != nullptr;
  static const int LMAX = std::getenv("M2_TBL_LMAX") ? std::atoi(std::getenv("M2_TBL_LMAX")) : 30;
  bool rq_d[4] = {false, false, false, false}; int hold[4] = {0, 0, 0, 0}; uint64_t hd[4] = {0, 0, 0, 0};
  Req cur{}; bool have = false;
  const int pat = 0;
  while (answered < N && cyc < N * 60) {
    ++cyc;
    // memory: random latency on each port
    d->m_ack = 0; d->m2_ack = 0; d->m3_ack = 0; d->m4_ack = 0;
    d->m_lo = 0; d->m2_lo = 0; d->m3_lo = 0; d->m4_lo = 0;       // R787
    // R787: the line's second half rides the acknowledge
    const int HALF = LW8 ? 4 : 0;
    {
      const bool rq[4] = {(bool)d->m_req, (bool)d->m2_req, (bool)d->m3_req, (bool)d->m4_req};
      const uint32_t aa[4] = {d->m_addr, d->m2_addr, d->m3_addr, d->m4_addr};
      for (int p = 0; p < 4; p++) {
        if (SDR) {
          bool ack = false; uint64_t l = hd[p];
          if (hold[p] > 0) { ack = true; --hold[p]; }
          if (LW8 && lat[p] == 4) set_lo(p, line_at(ad[p]));            // R787
          if (lat[p] == 0) { l = hd[p] = line_at(ad[p] + HALF); ack = true; hold[p] = 1; }
          if (lat[p] >= 0) --lat[p];
          if (rq[p] && !rq_d[p] && lat[p] < 0) { lat[p] = (LW8 ? 5 : 2) + rng() % LMAX; ad[p] = aa[p]; }
          rq_d[p] = rq[p];
          if (ack) {
            if (p == 0) { d->m_ack = 1; d->m_data = l; }
            if (p == 1) { d->m2_ack = 1; d->m2_data = l; }
            if (p == 2) { d->m3_ack = 1; d->m3_data = l; }
            if (p == 3) { d->m4_ack = 1; d->m4_data = l; }
          }
          continue;
        }
        if (rq[p] && lat[p] < 0) { lat[p] = (LW8 ? 5 : 2) + rng() % 30; ad[p] = aa[p]; }
        if (LW8 && lat[p] == 4) set_lo(p, line_at(ad[p]));              // R787
        if (lat[p] == 0) {
          const uint64_t l = line_at(ad[p] + HALF);
          if (p == 0) { d->m_ack = 1; d->m_data = l; }
          if (p == 1) { d->m2_ack = 1; d->m2_data = l; }
          if (p == 2) { d->m3_ack = 1; d->m3_data = l; }
          if (p == 3) { d->m4_ack = 1; d->m4_data = l; }
        }
        if (lat[p] >= 0) --lat[p];
      }
    }
    // occasional port-off stretches (2, and 3/4 when built NS=4) and sweeps
    if ((cyc % 50000) == 20000) d->m2_en = 0;
    if ((cyc % 50000) == 30000) d->m2_en = 1;
    if ((cyc % 70000) == 10000) d->m3_en = 0;
    if ((cyc % 70000) == 35000) d->m3_en = 1;
    if ((cyc % 90000) == 40000) d->m4_en = 0;
    if ((cyc % 90000) == 41000) d->m4_en = 1;
    d->inval = ((cyc % 37000) == 100) ? 1 : 0;
    // requests: coherent runs (a span walking a texture) and random jumps
    if (!have && issued < N && (rng() % 4)) {
      static Req run{}; static int runlen = 0;
      if (runlen == 0) {
        uint32_t t = 1u | ((rng() % 6) << 1) | ((rng() % 6) << 4) | ((rng() & 1) << 7)
                   | ((rng() % 5 == 0) << 8) | ((rng() % 5 == 0) << 9) | ((rng() % 5 == 0) << 10)
                   | ((rng() & 1) << 12) | ((rng() % 64) << 13) | ((rng() % 32) << 19);
        run = {t, (uint32_t)(rng() & 0xfffff), (uint32_t)(rng() & 0xfffff), (int)(rng() % 4 != 0)};
        runlen = 1 + rng() % 40;
      }
      cur = run; have = true; --runlen;
      run.u = (run.u + (rng() % 300)) & 0xfffff;           // mostly small steps: magnified
      run.v = (run.v + (rng() % 7) - 3) & 0xfffff;
    }
    (void)pat;
    d->req = have ? 1 : 0;
    if (have) { d->tex = cur.tex; d->u = cur.u; d->v = cur.v; d->bilinear = cur.bl; }
    d->eval();
    const bool took = have && d->rdy;
    tick();
    if (took) { sent.push_back(cur); have = false; ++issued; }
    if (d->ack) {
      if (sent.empty()) { std::printf("  FAIL answer with nothing outstanding\n"); ++fails; break; }
      const Req r = sent.front(); sent.pop_front();
      const uint32_t want = model(r), got = d->texel;
      ++checks; ++answered;
      if (got != want) {
        if (fails < 12)
          std::printf("  FAIL #%ld tex=%06x u=%05x v=%05x bl=%d: got {%u,%02x} want {%u,%02x}\n",
                      answered, r.tex, r.u, r.v, r.bl, got >> 8, got & 0xff, want >> 8, want & 0xff);
        ++fails;
      }
    }
  }
  std::printf("m2_texel_bl: %ld answered of %ld issued in %ld cycles, hits %u misses %u lost %u sweeps %u\n",
              answered, issued, cyc, d->dbg_hits, d->dbg_misses, d->dbg_lost, d->dbg_sweeps);
  std::printf("m2_texel_bl: checks=%d fails=%d\n", checks, fails);
  std::printf(fails || answered < N ? "FAIL\n" : "PASS\n");
  delete d;
  return fails ? 1 : 0;
}
