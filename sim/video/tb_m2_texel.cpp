// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// The texel fetch, against a transcription of model2rd.ipp.
//
// What this has to prove:
//
//   1. EVERY texel is the one the reference reads. A texture fetch that is
//      right for most coordinates and wrong at a seam paints a picture that
//      looks nearly right, which is the worst kind of wrong to find on a board.
//   2. The 2x2 block unpacking, which is four cases and easy to get one of.
//   3. The 1024-column fold, which is the sheet being stored as 1024x2048 and
//      addressed as 2048x1024.
//   4. Mirroring, which is real at point sampling.
//   5. The cache returns what memory holds, including after an upload.

#include "Vm2_texel.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <random>

static Vm2_texel *d;
static uint64_t cyc = 0;
static long checks = 0, fails = 0;

// R304: THE SWEEP IS AS LONG AS THE CACHE HAS LINES, AND THE CACHE GREW.
// m2_texel clears one tag per cycle at S_INIT, so the warm-up is LINES cycles
// plus entry and exit. This was three bare `600`s, which was ample at 512 lines
// (IDX_BITS 9) and far short at 4096 (IDX_BITS 12): the fetch under test had not
// started yet, so "a dead memory hung the texel fetch" and "the abandoned fetch
// was not counted" both fired against a DUT that was still sweeping. A mirror of
// an RTL parameter has to track it.
static const int SWEEP_TICKS = (1 << 12) + 128;

// Two sheets of 512 K 16-bit words, as words -- the same shape the SDRAM holds.
static const uint32_t SHEET_WORDS = 1u << 19;
static uint32_t epoch = 0;
static uint16_t sheetmem(int sheet, uint32_t w) {
  // A hash, so a wrong word is caught wherever it comes from.
  uint32_t h = (w * 2654435761u) ^ (sheet ? 0x5a5a5a5au : 0xa5a5a5a5u);
  return uint16_t((h >> 7) + epoch * 0x1111u);
}

// ALREADY WORD ADDRESSES. Model2.sv's GAME_TEXS0/1 are SDR_AW'(...) values and
// SDR_AW counts 16-bit words, so shifting them again puts the two sheets a
// quarter of a sheet apart -- which reads as the other sheet's data on every
// fetch past the first 256 K words, and looked exactly like a fold bug.
static const uint32_t BASE0 = 0x1760000;
static const uint32_t BASE1 = 0x17E0000;

static int mem_lat = 3, mem_wait = -1;

static void tick() {
  if (d->m_req && mem_wait < 0) mem_wait = mem_lat;
  if (mem_wait == 0) {
    d->m_ack = 1;
    uint64_t v = 0;
    const uint32_t a = d->m_addr;
    const int sheet = (a >= BASE1) ? 1 : 0;
    const uint32_t off = a - (sheet ? BASE1 : BASE0);
    for (int i = 0; i < 4; i++)
      v |= (uint64_t)sheetmem(sheet, (off + i) & (SHEET_WORDS - 1)) << (16 * i);
    d->m_data = v;
  }
  d->eval();
  d->clk = 0; d->eval();
  d->clk = 1; d->eval();
  ++cyc;
  if (d->m_ack) { d->m_ack = 0; mem_wait = -1; }
  else if (mem_wait > 0) --mem_wait;
}

// ------------------------------------------------ the reference, transcribed
// model2rd.ipp get_texel, and the point-sampled half of fetch_bilinear_texel.
struct TexState {
  int wcode, hcode, mirx, miry, sheet, texx, texy;
  uint32_t packed() const {
    return (1u)                       // textured
         | (uint32_t(wcode) << 1)
         | (uint32_t(hcode) << 4)
         | (uint32_t(mirx)  << 9)
         | (uint32_t(miry)  << 10)
         | (uint32_t(sheet) << 12)
         | (uint32_t(texx)  << 13)
         | (uint32_t(texy)  << 19);
  }
};

static int ref_texel(const TexState& t, int32_t u, int32_t v) {
  const int tex_width  = 32 << t.wcode;
  const int tex_height = 32 << t.hcode;
  // ((texx * 32) - 2048) & 2047 -- a no-op at level 0, but written as the
  // reference writes it so the transcription is checkable line by line.
  const int tex_x = ((t.texx * 32) - 2048) & 2047;
  const int tex_y = ((t.texy * 32) - 1024) & 1023;

  if (t.mirx && (u & (tex_width << 8)))  u = ~u;
  if (t.miry && (v & (tex_height << 8))) v = ~v;

  const int u0 = (u >> 8) & (tex_width - 1);
  const int v0 = (v >> 8) & (tex_height - 1);

  int x2 = tex_x + u0;
  int y2 = tex_y + v0;
  if (x2 >= 1024) { x2 -= 1024; y2 ^= 1024; }
  const uint32_t offset = (((y2 / 2) * 512) + (x2 / 2)) & (SHEET_WORDS - 1);
  uint32_t texel = sheetmem(t.sheet, offset & (SHEET_WORDS - 1));
  if ((v0 & 1) == 0) texel >>= 8;
  if ((u0 & 1) == 0) texel >>= 4;
  return texel & 0x0f;
}

static uint32_t last_addr = 0;
static int fetch(const TexState& t, int32_t u, int32_t v) {
  d->tex = t.packed();
  d->u   = u & 0xfffff;
  d->v   = v & 0xfffff;
  d->req = 1;
  int got = -1;
  for (int i = 0; i < 4000; ++i) {
    if (d->m_req) last_addr = d->m_addr;
    tick();
    if (d->ack) { got = d->texel; break; }
  }
  d->req = 0;
  tick();
  return got;
}

static void check(const TexState& t, int32_t u, int32_t v, const char* what) {
  const int got = fetch(t, u, v);
  const int want = ref_texel(t, u, v);
  ++checks;
  if (got != want) {
    if (fails < 10)
      std::printf("  MISMATCH %s: u=%d v=%d w=%d h=%d texx=%d texy=%d mir=%d%d "
                  "sheet=%d got=%X want=%X\n", what, u, v, 32 << t.wcode,
                  32 << t.hcode, t.texx, t.texy, t.mirx, t.miry, t.sheet,
                  got, want);
    if (fails < 4) {
      const int tw = 32 << t.wcode, th2 = 32 << t.hcode;
      int uu = u, vv = v;
      if (t.mirx && (uu & (tw << 8))) uu = ~uu;
      if (t.miry && (vv & (th2 << 8))) vv = ~vv;
      const int u0 = (uu >> 8) & (tw - 1), v0 = (vv >> 8) & (th2 - 1);
      int x2 = (((t.texx * 32) - 2048) & 2047) + u0;
      int y2 = (((t.texy * 32) - 1024) & 1023) + v0;
      if (x2 >= 1024) { x2 -= 1024; y2 ^= 1024; }
      const uint32_t off = (((y2 / 2) * 512) + (x2 / 2)) & (SHEET_WORDS - 1);
      std::printf("      ref u0=%d v0=%d x2=%d y2=%d off=%u line=%u  dut line=%u (off-base %u)\n",
                  u0, v0, x2, y2, off, off & ~3u,
                  last_addr, last_addr - (t.sheet ? BASE1 : BASE0));
    }
    ++fails;
  }
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_texel;
  d->rst_n = 0; d->req = 0; d->m_ack = 0; d->inval = 0;
  d->base_s0 = BASE0; d->base_s1 = BASE1;
  for (int i = 0; i < 4; ++i) tick();
  d->rst_n = 1;
  for (int i = 0; i < SWEEP_TICKS; ++i) tick();      // the tag sweep

  // 1. THE FOUR NIBBLES OF A BLOCK. Walk a 2x2 with everything else fixed, so
  //    a swapped pair is unambiguous rather than lost in a fuzz total.
  {
    TexState t{2, 2, 0, 0, 0, 4, 2};        // 128x128 at (128, 64)
    for (int dv = 0; dv < 2; ++dv)
      for (int du = 0; du < 2; ++du)
        check(t, (10 + du) << 8, (6 + dv) << 8, "2x2 block");
    std::printf("  2x2 block: %ld checks, %ld wrong\n", checks, fails);
  }

  // 2. THE 1024-COLUMN FOLD. A texture whose origin plus u crosses 1024 is
  //    stored in the other half of the sheet with y flipped by 1024 -- the
  //    sheets are 2048x1024 addressed but 1024x2048 stored.
  {
    TexState t{5, 3, 0, 0, 0, 60, 4};       // 1024 wide at x = 1920
    const long before = fails;
    for (int u = 0; u < 400; ++u) check(t, u << 8, 9 << 8, "fold");
    std::printf("  1024-column fold: %ld wrong\n", fails - before);
  }

  // 3. MIRRORING, both axes, across the mirror boundary.
  {
    const long before = fails;
    for (int mx = 0; mx < 2; ++mx)
      for (int my = 0; my < 2; ++my) {
        TexState t{1, 1, mx, my, 1, 8, 8};  // 64x64, sheet 1
        for (int u = 0; u < 200; u += 3)
          for (int v = 0; v < 200; v += 37)
            check(t, u << 8, v << 8, "mirror");
      }
    std::printf("  mirroring: %ld wrong\n", fails - before);
  }

  // 4. FUZZ across the whole state space, including both sheets and every
  //    texture size.
  {
    std::mt19937 rng(0x7e8e1u);
    const long before = fails, bch = checks;
    for (int i = 0; i < 4000; ++i) {
      TexState t{int(rng() % 6), int(rng() % 6), int(rng() & 1), int(rng() & 1),
                 int(rng() & 1), int(rng() % 64), int(rng() % 32)};
      check(t, (rng() % 4096) << 8, (rng() % 4096) << 8, "fuzz");
    }
    std::printf("  fuzz: %ld checked, %ld wrong\n", checks - bch, fails - before);
  }

  // 5. THE WALK ALONG A SCANLINE, which is what the rasteriser actually does,
  //    and the hit rate on it -- the number that says whether the cache is
  //    worth its blocks.
  {
    const uint32_t h0 = d->dbg_hits, m0 = d->dbg_misses;
    const long before = fails;
    TexState t{3, 3, 0, 0, 0, 10, 6};        // 256x256
    for (int v = 0; v < 8; ++v)
      for (int u = 0; u < 256; ++u)
        check(t, (u << 8) + 0x40, (v << 8) + 0x80, "scanline walk");
    const uint32_t hh = d->dbg_hits - h0, mm = d->dbg_misses - m0;
    std::printf("  scanline walk: %u hits, %u misses -- %.1f%% hit rate, %ld wrong\n",
                hh, mm, 100.0 * hh / double(hh + mm), fails - before);
    ++checks;
    if (100.0 * hh / double(hh + mm) < 70.0) {
      std::printf("  FAIL: a texel cache that misses this often is not worth M10K\n");
      ++fails;
    }
  }

  // 6. THE SHEETS ARE WRITABLE. The game uploads textures by CPU stores, so a
  //    line filled before an upload is stale -- the glyph cache's blank screen,
  //    in a different memory.
  {
    TexState t{2, 2, 0, 0, 0, 4, 2};
    const int before = fetch(t, 20 << 8, 12 << 8);
    ++checks;
    if (before != ref_texel(t, 20 << 8, 12 << 8)) {
      std::printf("  FAIL: cold fetch wrong\n"); ++fails;
    }
    ++epoch;                                  // the texture is rewritten
    const int stale = fetch(t, 20 << 8, 12 << 8);
    ++checks;
    if (stale != before) {
      std::printf("  FAIL: the cache should still be holding this line\n"); ++fails;
    }
    d->inval = 1; tick(); d->inval = 0;
    for (int i = 0; i < SWEEP_TICKS; ++i) tick();     // the sweep
    ++checks;
    const int after = fetch(t, 20 << 8, 12 << 8);
    if (after != ref_texel(t, 20 << 8, 12 << 8)) {
      std::printf("  FAIL: after inval got %X want %X -- the cache did not forget\n",
                  after, ref_texel(t, 20 << 8, 12 << 8));
      ++fails;
    } else {
      std::printf("  invalidate: the sheet was refetched after the upload\n");
    }
  }

  // 7. A MEMORY THAT NEVER ANSWERS. The unit sits inside the band fill, so a
  //    request that is never acknowledged holds the span walk, the band, and
  //    every band after it -- R162's failure mode. It must give up and answer.
  {
    d->inval = 1; tick(); d->inval = 0;
    for (int i = 0; i < SWEEP_TICKS; ++i) tick();      // sweep, so the next fetch misses
    const uint32_t lost0 = d->dbg_lost;
    mem_lat = 1000000;                          // the memory is gone
    TexState t{2, 2, 0, 0, 0, 4, 2};
    d->tex = t.packed(); d->u = 33 << 8; d->v = 44 << 8; d->req = 1;
    bool acked = false;
    for (int i = 0; i < 4000; ++i) { tick(); if (d->ack) { acked = true; break; } }
    d->req = 0; tick();
    ++checks;
    if (!acked) { std::printf("  FAIL: a dead memory hung the texel fetch\n"); ++fails; }
    ++checks;
    if (d->dbg_lost == lost0) {
      std::printf("  FAIL: the abandoned fetch was not counted\n"); ++fails;
    } else {
      std::printf("  dead memory: answered anyway, %u abandoned\n", d->dbg_lost - lost0);
    }
    mem_lat = 3; mem_wait = -1;
  }

  std::printf("m2_texel: checks=%ld fails=%ld\n", checks, fails);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
