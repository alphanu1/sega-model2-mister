// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// The glyph cache, checked against a reference memory.
//
// What this has to prove, in order of how badly each would hurt:
//
//   1. EVERY read returns the right word. A cache that returns stale data is
//      worse than no cache -- it would put wrong pixels on screen while every
//      probe upstream reads clean, which is the exact fault this project has
//      spent a session chasing.
//   2. The handshake contract is honoured: v_ack is ONE cycle, v_data is valid
//      on it, and no acknowledge appears without a request.
//   3. Misses actually fall. A cache that never hits is dead weight in M10K.
//
// The access pattern matters: glyph reads are not random. A character is eight
// consecutive words and the same characters recur constantly, so the test
// replays that shape as well as a random sweep, and reports the hit rate for
// each.

#include "Vm2_char_cache.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>

static Vm2_char_cache *d;
static uint64_t cyc = 0;

// EVEN ADDRESSES ONLY, WHICH IS THE CACHE'S CONTRACT.
//
// A line is the PAIR (char_addr, char_addr+1) that holds one 8-pixel row, and
// m2_tile_decode never produces an odd char_addr:
//     char_addr = {tile_num, 4'b0000} + {map_y[2:0], 1'b0}
// Both terms have bit 0 clear. The cache therefore indexes from bit 1 -- using
// bit 0 would index on a value that never varies and waste half the M10K, which
// is what it did. Presenting an odd address is outside the contract, so this
// file stops doing it; the reference is defined per line for the same reason.
#define EVEN(a) ((a) & ~1u)
#define LINE(a) ((a) & ~3u)

// Reference memory: the value at an address is a hash of it, so a wrong word
// is caught wherever it comes from.
// `epoch` stands in for the game UPLOADING new glyphs: the same address starts
// returning something else. Nothing else in this file changes behaviour with
// it, so a stale read is unambiguous.
static uint32_t epoch = 0;
static uint32_t ref(uint32_t a) {
  a = EVEN(a);
  return ((a * 2654435761u) ^ 0xA5A5A5A5u) + epoch * 0x01010101u;
}

static int  fails = 0, checks = 0;
static uint64_t mem_reqs = 0;

// THE MEMORY IS A SERVER, NOT A SUBROUTINE OF THE READ.
//
// It used to be answered inside read_word, which could only ever see the ONE
// transaction that read was waiting for. The cache now fetches the sibling line
// behind the acknowledge, so a request can be outstanding when no read is in
// progress at all -- and a bench that only answers during a read would hang the
// fill, or worse, quietly never exercise it and report a pass.
static int mem_lat  = 3;
static int mem_wait = -1;

static void tick() {
  if (d->m_req && mem_wait < 0) { mem_wait = mem_lat; ++mem_reqs; }
  if (mem_wait == 0) {
    d->m_ack  = 1;
    // A line is four words: both 32-bit rows it holds.
    d->m_data = ((uint64_t)ref(d->m_addr + 2) << 32) | ref(d->m_addr);
  }
  d->eval();
  d->clk = 0; d->eval();
  d->clk = 1; d->eval();
  ++cyc;
  if (d->m_ack) { d->m_ack = 0; mem_wait = -1; }
  else if (mem_wait > 0) --mem_wait;
}

// Let any fill running behind the last acknowledge finish.
static void settle(int n = 200) { for (int i = 0; i < n; ++i) tick(); }

// One read through the cache. Returns the word; `cycles` gets how long the
// acknowledge took, which is how the overlap is measured.
static uint32_t read_word(uint32_t addr, int latency, int *cycles = nullptr) {
  addr = EVEN(addr);
  mem_lat = latency;
  d->v_req = 1; d->v_addr = addr;
  uint32_t got = 0;
  int n = 0;
  for (int i = 0; i < 2000; ++i) {
    tick(); ++n;
    if (d->v_ack) { got = d->v_data; break; }
  }
  d->v_req = 0;
  tick();                      // let the cache see the request drop
  if (cycles) *cycles = n;
  return got;
}

static void check(uint32_t addr, int lat) {
  const uint32_t got = read_word(addr, lat);
  ++checks;
  if (got != ref(addr)) {
    if (fails < 10)
      std::printf("  MISMATCH addr %05x got %08x want %08x\n",
                  addr, got, ref(addr));
    ++fails;
  }
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_char_cache;

  d->rst_n = 0; d->v_req = 0; d->v_addr = 0; d->m_ack = 0; d->m_data = 0;
  for (int i = 0; i < 4; ++i) tick();
  d->rst_n = 1;
  // The tag sweep must finish before anything is served.
  for (int i = 0; i < 20000; ++i) tick();

  // 1. Correctness on first touch, at several memory latencies.
  for (int lat : {0, 1, 3, 9}) {
    for (uint32_t a = 0; a < 64; ++a) check(a + lat * 1024, lat);
  }
  std::printf("  cold reads: %d checked, %d wrong\n", checks, fails);

  // 2. Re-reads must hit and must still be right.
  uint32_t h0 = d->dbg_hits, m0 = d->dbg_misses;
  for (int pass = 0; pass < 4; ++pass)
    for (uint32_t a = 0; a < 64; ++a) check(a, 3);
  const uint32_t hits = d->dbg_hits - h0, misses = d->dbg_misses - m0;
  std::printf("  warm re-reads: %u hits, %u misses\n", hits, misses);
  if (misses != 0) { std::printf("  FAIL: warm data should never miss\n"); ++fails; }

  // 3. The real access shape: characters of eight consecutive words, a small
  //    set of them, recurring -- which is what a text screen does.
  h0 = d->dbg_hits; m0 = d->dbg_misses;
  for (int rep = 0; rep < 30; ++rep)
    for (uint32_t g = 0; g < 40; ++g)
      for (uint32_t w = 0; w < 8; ++w)
        check(0x2000 + g * 8 + w, 3);
  {
    const uint32_t hh = d->dbg_hits - h0, mm = d->dbg_misses - m0;
    const double rate = 100.0 * hh / double(hh + mm);
    std::printf("  glyph pattern: %u hits, %u misses -- %.1f%% hit rate\n",
                hh, mm, rate);
    if (rate < 95.0) { std::printf("  FAIL: hit rate too low to be worth M10K\n"); ++fails; }
  }

  // 4. Conflict behaviour: addresses one index-span apart share a line, so
  //    alternating between them must still return correct data even though it
  //    thrashes. Correctness under thrash is the property that matters.
  const uint32_t span = 1u << 14;
  for (int rep = 0; rep < 8; ++rep) {
    check(0x40, 2);
    check(0x40 + span, 2);
  }
  std::printf("  conflict thrash: %d total checks, %d wrong\n", checks, fails);

  // 5. COHERENCY, which is the property whose absence blanked the screen.
  //
  // The char region is RAM and the game uploads glyphs into it. A cache with no
  // invalidation serves its filled lines forever, including lines filled BEFORE
  // the upload -- which read as zeros, and a glyph of zeros paints one flat
  // colour. The cache passed 10,128 correctness checks without ever being asked
  // whether it can FORGET, which is exactly why this was missed.
  {
    const uint32_t a = 0x1234;
    const uint32_t before = read_word(a, 3);          // fill the line
    if (before != ref(a)) { std::printf("  FAIL: cold read wrong\n"); ++fails; }

    ++epoch;                                          // the glyphs are rewritten
    const uint32_t stale = read_word(a, 3);
    if (stale != before) {
      std::printf("  FAIL: cache should still be holding its line here\n");
      ++fails;
    }

    d->inval_idx = (LINE(a) >> 2) & 0x1fff; d->inval = 1; tick(); d->inval = 0;
    for (int i = 0; i < 8; ++i) tick();               // one line, one cycle

    const uint32_t after = read_word(a, 3);
    ++checks;
    if (after != ref(a)) {
      std::printf("  FAIL: after inval got %08x, want %08x -- the cache did "
                  "NOT forget, and this is the blank-screen bug\n", after, ref(a));
      ++fails;
    } else {
      std::printf("  invalidate: line refetched after the data changed\n");
    }
  }

  // 6. THE SIBLING FILL, which is what halves the misses.
  //
  // A tile is 16 words -- four lines -- walked two glyph rows at a time by
  // consecutive scanlines. A miss on line I must leave line I^1 resident too,
  // fetched behind the acknowledge, so the scanline two below hits.
  {
    settle();
    const uint32_t base = 0x3000;                 // line index even
    const uint32_t h0 = d->dbg_hits, m0 = d->dbg_misses, f0 = d->dbg_fills;
    const uint64_t r0 = mem_reqs;

    if (read_word(base, 6) != ref(base)) { std::printf("  FAIL: sibling test cold read\n"); ++fails; }
    settle();                                      // the sibling fetch lands here
    ++checks;
    // R283: THREE siblings, not one -- the whole tile. A tile is four lines
    // sharing one tag, and the eight scanlines that cross it read all four.
    if (d->dbg_fills - f0 != 3) {
      std::printf("  FAIL: a miss must fetch the rest of its tile -- fills %u\n",
                  d->dbg_fills - f0);
      ++fails;
    }
    // The next TWO glyph rows are in the sibling line: both must hit, and no
    // new memory transaction may be issued for them.
    const uint64_t r1 = mem_reqs;
    // Every one of the tile's eight glyph rows must now be resident.
    for (uint32_t w = 2; w < 16; w += 2) {
      ++checks;
      if (read_word(base + w, 6) != ref(base + w)) {
        std::printf("  FAIL: word %u of the tile was not filled\n", w); ++fails;
      }
    }
    ++checks;
    if (mem_reqs != r1) {
      std::printf("  FAIL: the sibling line was refetched -- %llu extra transactions\n",
                  (unsigned long long)(mem_reqs - r1));
      ++fails;
    }
    std::printf("  sibling fill: %u hits, %u misses, %u fills, %llu transactions\n",
                d->dbg_hits - h0, d->dbg_misses - m0, d->dbg_fills - f0,
                (unsigned long long)(mem_reqs - r0));
  }

  // 7. THE OVERLAP. A HIT MUST NOT WAIT FOR AN OUTSTANDING FILL.
  //
  // This is the half that buys the scanline budget back: the fetch engine is
  // decoding its next tile word while the sibling is still in the SDRAM, and if
  // a hit had to queue behind that fill the prefetch would cost more than it
  // saves. Latency is measured against a deliberately slow memory so the two
  // cases cannot be confused.
  {
    settle();
    const uint32_t a = 0x5000;
    int c_miss = 0, c_hit = 0;
    read_word(a, 40, &c_miss);           // miss: pays the 40-cycle memory
    // No settle: the sibling fetch is now outstanding. Re-read the SAME line.
    read_word(a + 2, 40, &c_hit);
    ++checks;
    if (c_hit >= 20) {
      std::printf("  FAIL: a hit waited %d cycles for the sibling fill (miss was %d)\n",
                  c_hit, c_miss);
      ++fails;
    } else {
      std::printf("  overlap: miss %d cycles, hit during the fill %d cycles\n",
                  c_miss, c_hit);
    }
    settle();
  }

  // 8. MISSES ON THE REAL SHAPE. Eight scanlines walk a tile's four lines in
  //    order; with the sibling fill that must cost TWO transactions, not four.
  {
    settle();
    const uint32_t m0 = d->dbg_misses;
    const uint64_t r0 = mem_reqs;
    for (uint32_t g = 0; g < 32; ++g)
      for (uint32_t row = 0; row < 8; ++row) {
        const uint32_t a = 0x8000 + g * 16 + row * 2;
        ++checks;
        if (read_word(a, 4) != ref(a)) {
          if (fails < 10) std::printf("  MISMATCH walk addr %05x\n", a);
          ++fails;
        }
        settle(40);            // the scanline's other work, in which the fill lands
      }
    const uint32_t mm = d->dbg_misses - m0;
    std::printf("  tile walk: %u misses over 32 tiles x 8 rows (%.2f per tile), "
                "%llu transactions\n", mm, mm / 32.0,
                (unsigned long long)(mem_reqs - r0));
    ++checks;
    if (mm > 32 * 2) {
      std::printf("  FAIL: %u misses -- the sibling fill is not covering the walk\n", mm);
      ++fails;
    }
  }

  // 9. THE LOOKUP THAT GOT SOMEBODY ELSE'S LINE.
  //
  // `inval` diverts the array address, so a lookup issued in the same cycle
  // reads a DIFFERENT line -- and the tag is three bits here, so a wrong line
  // whose tag happens to match is a hit on another glyph's pixels. This is
  // arranged deterministically rather than hoped for: X and A carry the same
  // tag at different indices, X is resident, A is not, and the invalidate is
  // asserted on X's index in the exact cycle A is looked up.
  {
    settle();
    const uint32_t X = 0x0040;          // resident, tag 0
    const uint32_t A = 0x6000;          // same tag, different index, never touched
    if (read_word(X, 3) != ref(X)) { std::printf("  FAIL: priming read\n"); ++fails; }
    settle();

    d->v_req = 1; d->v_addr = A;
    d->inval_idx = (LINE(X) >> 2) & ((1u << 13) - 1);
    d->inval = 1;
    tick();                              // the lookup cycle, stolen
    d->inval = 0;
    uint32_t got = 0;
    for (int i = 0; i < 2000; ++i) { tick(); if (d->v_ack) { got = d->v_data; break; } }
    d->v_req = 0; tick();
    ++checks;
    if (got != ref(A)) {
      std::printf("  FAIL: a stolen lookup returned %08x, want %08x -- the cache "
                  "matched another line's tag\n", got, ref(A));
      ++fails;
    } else {
      std::printf("  stolen lookup: asked again and returned the right word\n");
    }
    settle();
  }

  std::printf("  memory transactions issued: %llu\n",
              (unsigned long long)mem_reqs);
  std::printf("m2_char_cache: checks=%d fails=%d\n", checks, fails);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
