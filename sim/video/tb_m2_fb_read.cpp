// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// m2_fb_read: the DDR3 framebuffer, read back a line at a time.
//
// WHAT MATTERS HERE. The mixer sees rd_x -> rd_col/rd_hit and must not know the
// pixels came from DDR3. So the test fills DDR3 with a pattern that is a
// function of (y, x), asks for a line, and reads EVERY pixel of it back --
// which catches a dropped first beat, a half-beat written to the wrong index,
// a line address off by a factor of two, and the two buffers being confused.
//
// It also checks the thing the design rests on: ONE COMMAND A LINE. If the
// reader dribbles out per-pixel requests, the ~200 ns latency lands in the
// beam's path and the whole argument for a framebuffer collapses.

#include "Vm2_fb_read.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <map>

static Vm2_fb_read *d;
static long checks = 0, fails = 0;
static void ck(const char *w, long got, long want) {
  checks++;
  if (got != want) { fails++; std::printf("  FAIL %-46s got=%ld want=%ld\n", w, got, want); }
}

static const int STRIDE = 512, BEATS = (496 + 1) / 2;   // 248: the visible line
static std::map<uint32_t, uint64_t> mem;
static long commands = 0, beats_served = 0;
static int lat = 20;                  // ~200 ns at 100 MHz (R347)
static int cd = 0, left = 0; static uint32_t raddr = 0;
// R368: collapse the whole burst into one beat, so rvalid and ack share a cycle
static int one_beat = 0;

// the pixel DDR3 should hold, as a function of where it is
static uint32_t want_px(int y, int x) { return 0x01000000u | ((uint32_t)(y * 7 + x * 3) & 0xffffff); }

static void tick() {
  d->m_rvalid = 0; d->m_ack = 0;
  if (left == 0 && d->m_req) {
    raddr = d->m_addr; left = one_beat ? 1 : d->m_blen; cd = lat; commands++;
  }
  else if (left > 0) {
    if (cd > 0) cd--;
    else {
      d->m_dout = mem.count(raddr) ? mem[raddr] : 0ull;
      d->m_rvalid = 1; raddr++; left--; beats_served++;
      if (left == 0) d->m_ack = 1;
    }
  }
  d->eval();
  d->clk = 0; d->rd_clk = 0; d->eval();
  d->clk = 1; d->rd_clk = 1; d->eval();
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_fb_read;
  d->clk = 0; d->rd_clk = 0; d->rst_n = 0; d->line_req = 0; d->fb_sel = 0;
  d->rd_x = 0; d->rd_parity = 0;
  d->m_rvalid = 0; d->m_ack = 0; d->m_dout = 0;
  for (int i = 0; i < 4; i++) tick();
  d->rst_n = 1; tick();

  // fill DDR3 for buffer 0, lines 0..3
  for (int y = 0; y < 4; y++)
    for (int x = 0; x < STRIDE; x += 2) {
      uint32_t a = (uint32_t)y * (STRIDE / 2) + (uint32_t)(x >> 1);
      mem[a] = ((uint64_t)want_px(y, x + 1) << 32) | want_px(y, x);
    }

  for (int y = 0; y < 4; y++) {
    commands = 0; beats_served = 0;
    d->line_y = y; d->line_req = 1; tick(); d->line_req = 0;
    int i = 0;
    for (; i < 40000 && !d->line_ready; i++) tick();
    if (y == 0) std::printf("test: a line comes back, every pixel of it\n");
    ck("the line arrived", (long)(i < 40000), 1);
    ck("ONE command for the whole line", commands, 1);
    ck("248 beats served (the visible line)", beats_served, BEATS);

    long wrong = 0;
    d->rd_parity = y & 1;              // R354: buffer chosen by line parity
    for (int x = 0; x < 496; x++) {
      d->rd_x = x; tick(); tick();
      uint32_t got = ((uint32_t)d->rd_hit << 24) | (d->rd_col & 0xffffff);
      if (got != want_px(y, x)) wrong++;
    }
    if (wrong) std::printf("  (line %d: %ld pixels wrong)\n", y, wrong);
    ck("every pixel matches what DDR3 holds", wrong, 0);
  }

  // the two buffers must not be confused: line 3 must still read line 3
  {
    std::printf("test: the ping-pong does not hand back the wrong buffer\n");
    long wrong = 0;
    d->rd_parity = 3 & 1;
    for (int x = 0; x < 496; x++) {
      d->rd_x = x; tick(); tick();
      uint32_t got = ((uint32_t)d->rd_hit << 24) | (d->rd_col & 0xffffff);
      if (got != want_px(3, x)) wrong++;
    }
    ck("still the last line fetched", wrong, 0);
  }

  // a line asked for before the previous landed is COUNTED, not silently late
  {
    std::printf("test: asking early is counted, not silent\n");
    uint32_t before = d->dbg_late;
    d->line_y = 1; d->line_req = 1; tick(); d->line_req = 0;
    d->line_y = 2; d->line_req = 1; tick(); d->line_req = 0;   // too soon
    for (int i = 0; i < 40000 && !d->line_ready; i++) tick();
    ck("the early request was counted", (long)(d->dbg_late > before), 1);
  }

  // ---- R368: AN ACKNOWLEDGE THAT ARRIVES IN R_REQ MUST NOT BE LOST.
  //
  // When a burst's first beat is also its last, rvalid and ack share a cycle
  // and the reader is still in R_REQ. That state watched only rvalid, so the
  // acknowledge went on the floor: the reader sat in R_FILL for ever, busy
  // never cleared, and the arbiter held a grant nobody would release. The board
  // showed exactly that -- and dbg_lat_last proved a transfer HAD completed and
  // acknowledged, so the pulse was issued and lost rather than never sent.
  //
  // Modelled by serving the whole line in one beat, which collapses rvalid and
  // ack into the same cycle. The reader must still retire the line.
  {
    std::printf("test: an ack arriving in R_REQ still retires the line\n");
    mem.clear();
    one_beat = 1;
    uint32_t before = d->dbg_lines;
    d->line_y = 3; d->line_req = 1; tick(); d->line_req = 0;
    int i = 0;
    for (; i < 40000 && !d->line_ready; i++) tick();
    ck("the line completed", (long)(i < 40000), 1);
    ck("and was counted",    (long)(d->dbg_lines > before), 1);
    ck("the reader is free again", (long)d->dbg_busy, 0);
    one_beat = 0;
  }

  ck("lines fetched", (long)(d->dbg_lines >= 4), 1);
  std::printf("m2_fb_read: checks=%ld fails=%ld\n", checks, fails);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
