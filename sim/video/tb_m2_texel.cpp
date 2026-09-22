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
#include "Vm2_texel___024root.h"
#include "verilated.h"
#include <cstdio>
#include <vector>
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
// R480: THE SECOND PORT, MODELLED SEPARATELY AND WITH ITS OWN LATENCY.
// m2_texel now issues fills on two SDRAM ports so two can be in flight. Giving
// them the same latency would hide the thing that matters -- the two ports
// complete INDEPENDENTLY and out of order, and the response FIFO is what puts
// the answers back in the order the walk asked in. A different latency here is
// what proves that rather than assumes it.
static int mem2_lat = 5, mem2_wait = -1;

static uint64_t line_at(uint32_t a) {
  uint64_t v = 0;
  const int sheet = (a >= BASE1) ? 1 : 0;
  const uint32_t off = a - (sheet ? BASE1 : BASE0);
  for (int i = 0; i < 4; i++)
    v |= (uint64_t)sheetmem(sheet, (off + i) & (SHEET_WORDS - 1)) << (16 * i);
  return v;
}

static void tick() {
  if (d->m_req  && mem_wait  < 0) mem_wait  = mem_lat;
  if (d->m2_req && mem2_wait < 0) mem2_wait = mem2_lat;
  if (mem_wait  == 0) { d->m_ack  = 1; d->m_data  = line_at(d->m_addr);  }
  if (mem2_wait == 0) { d->m2_ack = 1; d->m2_data = line_at(d->m2_addr); }
  d->eval();
  d->clk = 0; d->eval();
  d->clk = 1; d->eval();
  ++cyc;
  if (d->m_ack)  { d->m_ack  = 0; mem_wait  = -1; } else if (mem_wait  > 0) --mem_wait;
  if (d->m2_ack) { d->m2_ack = 0; mem2_wait = -1; } else if (mem2_wait > 0) --mem2_wait;
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
    // R474: DEASSERT ON ACCEPTANCE, which is what the module now requires. The
    // cache takes a request on the cycle req and rdy are both high; holding the
    // level past that is read as a SECOND request. This bench drives m2_texel
    // directly, so it has to model what m2_texel_x2 does for the real
    // requester -- without it the scanline walk reported 3,839 hits for 2,048
    // fetches, every texel still correct (R473).
    const bool accepted = d->req && d->rdy;
    if (d->m_req) last_addr = d->m_addr;
    tick();
    if (accepted) d->req = 0;
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
  d->rst_n = 0; d->req = 0; d->m_ack = 0; d->m2_ack = 0; d->inval = 0;
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
    // R480: DEASSERT ON ACCEPTANCE, as fetch() does. Holding req while the
    // cache is ready means offering it again -- the streaming cache took this
    // one twice, allocated BOTH miss slots, and the second port answered it in
    // nine ticks while the first was still staring at a dead memory. The
    // timeout never got a chance to fire and this test read as an RTL fault.
    bool acked = false;
    for (int i = 0; i < 4000; ++i) {
      const bool accepted = d->req && d->rdy;
      tick();
      if (accepted) d->req = 0;
      if (d->ack) { acked = true; break; }
    }
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

  // ---- R480: STREAMING, AND THE ORDER IT PROMISES.
  //
  // Everything above drives one request at a time, so it never allocates a
  // second MSHR and never proves the thing the redesign exists for: two fills
  // in flight on two ports, answered IN THE ORDER ASKED. The two ports have
  // different latencies in this bench precisely so an out-of-order completion
  // is possible -- if the response FIFO were not doing its job, the values
  // would come back swapped and every one of them would still be a real texel.
  {
    d->inval = 1; tick(); d->inval = 0;
    for (int i = 0; i < SWEEP_TICKS; ++i) tick();   // cold, so most of these miss
    mem_lat = 3; mem2_lat = 7;   // different, so out-of-order completion is possible

    const int N = 200;
    std::vector<int> want, got;
    TexState t{2, 2, 0, 0, 0, 4, 2};
    int issued = 0, seen_p2 = 0;
    d->tex = t.packed();
    for (int i = 0; i < 40000 && (int)got.size() < N; ++i) {
      // Offer the next request whenever the cache can take one.
      if (issued < N && !d->req) {
        // MASK TO 20 BITS, as fetch() does. The port is 20 bits wide, so the
        // DUT sees the masked value while ref_texel below was handed the raw
        // one -- the expectations were wrong, not the cache. 197 of 200 "wrong".
        d->u = ((33 + issued * 37) << 8) & 0xfffff;
        d->v = ((44 + issued * 11) << 8) & 0xfffff;
        d->req = 1;
      }
      const bool accepted = d->req && d->rdy;
      if (accepted) want.push_back(ref_texel(t, (int32_t)d->u, (int32_t)d->v));
      if (d->m2_req) ++seen_p2;
      tick();
      if (accepted) { d->req = 0; ++issued; }
      if (d->ack) got.push_back(d->texel);
    }
    d->req = 0; tick();

    ++checks;
    if ((int)got.size() != N) {
      std::printf("  FAIL streaming: %zu of %d answered\n", got.size(), N); ++fails;
    }
    ++checks;
    if (!seen_p2) {
      std::printf("  FAIL streaming: the second port was never used\n"); ++fails;
    }
    int wrong = 0;
    for (size_t k = 0; k < got.size() && k < want.size(); ++k) {
      ++checks;
      if (got[k] != want[k]) {
        ++wrong; ++fails;
      }
    }
    std::printf("  streaming: %zu answered in order, %d cycles on the second port, %d wrong\n",
                got.size(), seen_p2, wrong);
    // Where the wrong ones sit, and whether the value is a NEIGHBOUR of the
    // right one -- a shifted-by-one answer means the queue paired a group with
    // the wrong entry; an unrelated value means the line itself is wrong.
    std::printf("    [probe] issued=%d accepted=%zu answered=%zu wp=%u rp=%u\n",
                issued, want.size(), got.size(),
                (unsigned)d->rootp->m2_texel__DOT__rs_wp,
                (unsigned)d->rootp->m2_texel__DOT__rs_rp);
    std::printf("    [probe] first 24: ");
    for (size_t k = 0; k < 24 && k < got.size() && k < want.size(); ++k)
      std::printf("%s", got[k] == want[k] ? "." : "X");
    std::printf("\n    [probe] shifted-by-one matches: ");
    int off1 = 0;
    for (size_t k = 1; k < got.size() && k < want.size(); ++k)
      if (got[k] != want[k] && got[k] == want[k-1]) ++off1;
    std::printf("%d of %d wrong\n", off1, wrong);
    mem_lat = 3; mem2_lat = 5;
  }

  std::printf("m2_texel: checks=%ld fails=%ld\n", checks, fails);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
