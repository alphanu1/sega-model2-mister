// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// m2_fb_write: spans into the DDR3 framebuffer.
//
// HOW THIS IS CHECKED. The DDRAM side is modelled as a memory, every write is
// applied to it with its byte enables, and the FRAMEBUFFER IS THEN RECONSTRUCTED
// AND COMPARED PIXEL BY PIXEL against what the span should have painted. That
// is stronger than watching the bus: it catches a wrong address, a wrong byte
// enable, a burst that runs one word long, and a pixel written twice, none of
// which a transaction count would show.
//
// The cases that matter are the ENDS. Two pixels share a 64-bit word, so a span
// starting or finishing on an odd x needs a byte-enabled single write while the
// middle bursts, and getting either end wrong corrupts the pixel BESIDE the
// span -- which belongs to something else.

#include "Vm2_fb_write.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <map>

static Vm2_fb_write *d;
static long checks = 0, fails = 0;
static void ck(const char *w, long got, long want) {
  checks++;
  if (got != want) { fails++; std::printf("  FAIL %-46s got=%ld want=%ld\n", w, got, want); }
}

static const int STRIDE = 512;
static std::map<uint32_t, uint64_t> mem;
// PER-BYTE validity, not per-word. A byte-enabled write creates the word, and a
// model that tracks only "does this word exist" then reports the untouched half
// as zero instead of as never-written -- which looks exactly like the module
// corrupting the neighbouring pixel. That artifact cost a debugging round.
static std::map<uint32_t, uint8_t> valid;
static int busy_for = 0, busy_ctr = 0;
static long beats = 0, commands = 0;
static uint32_t burst_addr = 0; static int burst_left = 0;

static void tick() {
  bool asking = d->m_req || burst_left > 0;
  bool busy = (asking && busy_ctr < busy_for);
  busy_ctr = asking ? busy_ctr + 1 : 0;

  d->m_wnext = 0; d->m_ack = 0;
  if (!busy) {
    if (burst_left == 0 && d->m_req) {
      burst_addr = d->m_addr; burst_left = d->m_blen ? d->m_blen : 1;
      commands++;
    }
    if (burst_left > 0) {
      uint64_t prev = mem.count(burst_addr) ? mem[burst_addr] : 0ull;
      uint64_t msk = 0;
      for (int b = 0; b < 8; b++) if (d->m_be & (1 << b)) msk |= 0xffull << (b * 8);
      mem[burst_addr] = (prev & ~msk) | (d->m_din & msk);
      valid[burst_addr] |= d->m_be;
      burst_addr++; burst_left--; beats++;
      d->m_wnext = 1;
      if (burst_left == 0) d->m_ack = 1;
      busy_ctr = 0;
    }
  }
  d->eval();
  d->clk = 0; d->eval();
  d->clk = 1; d->eval();
}

static uint32_t pix(int fb, int y, int x) {
  uint32_t w = (uint32_t)fb * (1u << 24) * 0 + (uint32_t)(fb ? (1u << 24) : 0);
  uint32_t a = ((uint32_t)((w ? (1u<<24) : 0) + y) * (STRIDE / 2)) + (uint32_t)(x >> 1);
  uint8_t vm = valid.count(a) ? valid[a] : 0;
  uint8_t half = (x & 1) ? 0xF0 : 0x0F;
  if ((vm & half) != half) return 0xFFFFFFFFu;        // this pixel never written
  uint64_t v = mem[a];
  return (x & 1) ? (uint32_t)(v >> 32) : (uint32_t)(v & 0xffffffffu);
}

// EVERY WAIT IS BOUNDED. An unbounded one turns a stuck FSM into a hung bench,
// which tells you nothing; bounded, it is a failure with a name attached.
static long stalls = 0;
static bool span(int y, int x0, int x1, uint32_t col, int painted) {
  int i = 0;
  for (; i < 5000 && !d->in_ready; i++) tick();
  if (i >= 5000) { stalls++; return false; }
  d->in_valid = 1; d->in_y = y; d->in_x0 = x0; d->in_x1 = x1;
  d->in_col = col; d->in_painted = painted;
  tick();
  d->in_valid = 0;
  for (i = 0; i < 20000 && !d->in_ready; i++) tick();
  if (i >= 20000) { stalls++; return false; }
  return true;
}

// every pixel the span should have painted, and nothing else
static long verify(int y, int x0, int x1, uint32_t col, int painted, int lo, int hi) {
  long wrong = 0;
  const uint32_t want = ((uint32_t)painted << 24) | (col & 0xffffff);
  for (int x = lo; x <= hi; x++) {
    uint32_t got = pix(0, y, x);
    if (x >= x0 && x <= x1) { if (got != want) wrong++; }
    else                    { if (got != 0xFFFFFFFFu) wrong++; }   // neighbour touched
  }
  return wrong;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_fb_write;
  d->clk = 0; d->rst_n = 0; d->in_valid = 0; d->fb_sel = 0; d->clear_req = 0;
  d->m_wnext = 0; d->m_ack = 0;
  for (int i = 0; i < 4; i++) tick();
  d->rst_n = 1; tick();

  // ---- the four alignments, which is where a two-pixels-per-word packing fails
  struct { int x0, x1; const char *name; } cases[] = {
    { 10, 21, "even..odd   (aligned both ends)" },
    { 11, 21, "odd..odd    (head write needed)" },
    { 10, 20, "even..even  (tail write needed)" },
    { 11, 20, "odd..even   (head AND tail)" },
    { 13, 13, "one pixel, odd" },
    { 14, 14, "one pixel, even" },
  };
  for (auto &c : cases) {
    mem.clear(); valid.clear();
    std::printf("test: %s\n", c.name);
    span(40, c.x0, c.x1, 0x3355AA, 1);
    ck("pixels exactly as the span says", verify(40, c.x0, c.x1, 0x3355AA, 1, c.x0 - 2, c.x1 + 2), 0);
  }

  // ---- the row address, which is a shift and easy to get wrong by a factor of two
  {
    mem.clear(); valid.clear();
    std::printf("test: rows do not overlap\n");
    span(0, 100, 109, 0x111111, 1);
    span(1, 100, 109, 0x222222, 1);
    long wrong = 0;
    for (int x = 100; x <= 109; x++) {
      if (pix(0, 0, x) != 0x01111111u) wrong++;
      if (pix(0, 1, x) != 0x01222222u) wrong++;
    }
    ck("row 0 and row 1 are distinct", wrong, 0);
  }

  // ---- a long span must BURST, not dribble out a word at a time (R347)
  {
    mem.clear(); valid.clear(); commands = 0; beats = 0; busy_for = 3;
    std::printf("test: a long span bursts\n");
    long px0 = d->dbg_pixels;
    span(7, 0, 399, 0x445566, 1);        // 400 px = 200 words
    ck("all 400 pixels correct", verify(7, 0, 399, 0x445566, 1, 0, 399), 0);
    ck("200 words written",      beats, 200);
    // one burst, not 200 commands. Allow a couple for any head/tail.
    ck("issued as a burst, not word by word", (long)(commands <= 3), 1);
    // R358: the counter reports PIXELS, and this is the case that tells the
    // two apart -- 400 pixels in 200 beats. A counter that counted beats, as
    // this one did, reads 200 and is not comparable with the band path's.
    ck("dbg_pixels counts pixels, not beats", (long)d->dbg_pixels - px0, 400);
  }

  // ---- the painted flag is what lets the mixer tell black from nothing
  {
    mem.clear(); valid.clear();
    std::printf("test: the painted flag is carried\n");
    span(9, 20, 23, 0x000000, 1);
    ck("black but PAINTED",   (long)pix(0, 9, 21), 0x01000000);
    span(9, 30, 33, 0x000000, 0);
    ck("black and NOT painted", (long)pix(0, 9, 31), 0x00000000);
  }

  ck("no span left the writer stalled", stalls, 0);
  // ---- R357: the clear. Without it the previous frame shows through wherever
  //      this one paints nothing, which the band buffers avoided by clearing
  //      per band and which the reference does with destmap().fill(0).
  {
    mem.clear(); valid.clear(); busy_for = 1; beats = 0;
    std::printf("test: the clear pass zeroes the buffer\n");
    span(5, 10, 20, 0x334455, 1);              // something to be cleared
    beats = 0;                                 // count the CLEAR's beats only
    long pxc = d->dbg_pixels;
    d->clear_req = 1;
    int i = 0; for (; i < 400000 && !d->clear_busy; i++) tick();
    ck("the clear started", (long)(i < 400000), 1);
    for (i = 0; i < 4000000 && d->clear_busy; i++) tick();
    d->clear_req = 0;
    ck("and finished",      (long)(i < 4000000), 1);
    long wrong = 0;
    for (int x = 8; x <= 22; x++) if (pix(0, 5, x) != 0u) wrong++;
    ck("the painted span is gone", wrong, 0);
    // a cleared pixel is NOT painted, so the mixer shows the tilemap through it
    ck("cleared means not painted", (long)(pix(0, 5, 15) >> 24), 0);
    ck("it wrote every visible line", beats, 384L * 248);
    // the clear paints nothing the mixer will show, so it must not be counted
    ck("the clear did not touch the pixel count", (long)d->dbg_pixels - pxc, 0);
    tick();
    ck("and takes spans again", (long)d->in_ready, 1);
  }

  std::printf("m2_fb_write: checks=%ld fails=%ld\n", checks, fails);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
