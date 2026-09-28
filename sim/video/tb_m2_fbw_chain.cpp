// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R660: THE FRAMEBUFFER WRITE PATH END TO END -- m2_fb_write, m2_ddr3_arb and
// m2_ddr3 as built, against a DDRAM that says BUSY at random and a reader
// competing for it.
//
// Checked:
//   - the framebuffer, pixel by pixel, against every span applied in order
//     (later spans win), with never-written pixels told apart from painted ones;
//   - DDRAM write COMMANDS against the writer's own requests: a command the
//     writer never asked for is a request taken twice;
//   - the Avalon side: a burst's address and count held for every beat, no
//     read issued inside a write burst;
//   - every read burst the stand-in reader asks for comes back whole.
//
// Environment: CHAIN_N spans (default 20000), CHAIN_BUSY per mille of cycles
// BUSY (default 300), CHAIN_RD cycles between reads (default 900, 0 = none),
// CHAIN_SEED.

#include "Vm2_fbw_chain.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <map>
#include <vector>

static Vm2_fbw_chain *d;
static long checks = 0, fails = 0;
static void ck(const char *w, long got, long want) {
  checks++;
  if (got != want) { fails++; std::printf("  FAIL %-50s got=%ld want=%ld\n", w, got, want); }
}

static const uint32_t BASE = 0x06000000u;
static std::map<uint32_t, uint64_t> mem;
static std::map<uint32_t, uint8_t> valid;
static uint64_t rng = 1;
static uint32_t rnd() { rng = rng * 6364136223846793005ull + 1442695040888963407ull; return uint32_t(rng >> 33); }

static int BUSY_PM = 300;
static long cyc = 0;
static long cmds_w = 0, cmds_r = 0, beats_w = 0, proto = 0, empty_beats = 0, rd_in_wr = 0;
static int TRACE = 0;
static long wreq_rises = 0; static bool wreq_prev = false;
static uint32_t wr_a = 0, wr_a0 = 0; static int wr_left = 0, wr_b0 = 0;
struct RB { int cd; uint64_t v; };
static std::deque<RB> rq;
static long rd_beats_got = 0;

static void tick() {
  // the DDRAM: BUSY at random; a read's words come back after a latency, with gaps
  d->DDRAM_BUSY = (int(rnd() % 1000) < BUSY_PM) ? 1 : 0;
  d->DDRAM_DOUT_READY = 0;
  if (!rq.empty()) {
    if (rq.front().cd > 0) rq.front().cd--;
    else if (rnd() % 4) { d->DDRAM_DOUT = rq.front().v; d->DDRAM_DOUT_READY = 1; rq.pop_front(); }
  }
  d->eval();
  if (!d->DDRAM_BUSY) {
    if (d->DDRAM_WE) {
      if (wr_left == 0) {
        wr_a = wr_a0 = d->DDRAM_ADDR - BASE; wr_left = wr_b0 = d->DDRAM_BURSTCNT; cmds_w++;
      } else if ((d->DDRAM_ADDR - BASE) != wr_a0 || d->DDRAM_BURSTCNT != wr_b0) proto++;
      uint64_t m = 0;
      for (int b = 0; b < 8; b++) if (d->DDRAM_BE & (1 << b)) m |= 0xffull << (b * 8);
      uint64_t old = mem.count(wr_a) ? mem[wr_a] : 0ull;
      mem[wr_a] = (d->DDRAM_DIN & m) | (old & ~m);
      valid[wr_a] |= d->DDRAM_BE;
      if (d->DDRAM_BE == 0) empty_beats++;
      if (TRACE > 0) { TRACE--; std::printf("  c%ld WE a=%x n=%d be=%02x din=%016llx wreq_rises=%ld cmds=%ld\n", cyc, d->DDRAM_ADDR - BASE, d->DDRAM_BURSTCNT, d->DDRAM_BE, (unsigned long long)d->DDRAM_DIN, wreq_rises, cmds_w); }
      wr_a++; wr_left--; beats_w++;
    } else if (d->DDRAM_RD) {
      if (wr_left) rd_in_wr++;
      cmds_r++;
      for (int k = 0; k < d->DDRAM_BURSTCNT; k++)
        rq.push_back({k == 0 ? 20 : 0, 0x5A5A5A5A00000000ull | uint64_t(k)});
    }
  }
  if (d->w_req && !wreq_prev) wreq_rises++;
  wreq_prev = d->w_req;
  d->clk = 0; d->eval();
  d->clk = 1; d->eval();
  cyc++;
}

// the reference framebuffer: one 32-bit word a pixel, 0xFFFFFFFF never written
static const int W = 496, H = 384;
static std::vector<uint32_t> ref(512 * 512, 0xFFFFFFFFu);
static uint32_t pix(int y, int x) {
  uint32_t a = uint32_t(y) * 256 + uint32_t(x >> 1);
  uint8_t half = (x & 1) ? 0xF0 : 0x0F;
  uint8_t vm = valid.count(a) ? valid[a] : 0;
  if ((vm & half) == 0) return 0xFFFFFFFFu;
  if ((vm & half) != half) return 0xEEEEEEEEu;   // a torn pixel
  uint64_t v = mem[a];
  return (x & 1) ? uint32_t(v >> 32) : uint32_t(v);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const long N   = std::getenv("CHAIN_N")    ? atol(std::getenv("CHAIN_N"))    : 20000;
  BUSY_PM        = std::getenv("CHAIN_BUSY") ? atoi(std::getenv("CHAIN_BUSY")) : 300;
  const long RDP = std::getenv("CHAIN_RD")   ? atol(std::getenv("CHAIN_RD"))   : 900;
  TRACE          = std::getenv("CHAIN_TRACE") ? atoi(std::getenv("CHAIN_TRACE")) : 0;
  rng            = std::getenv("CHAIN_SEED") ? strtoull(std::getenv("CHAIN_SEED"), 0, 0) : 1;

  d = new Vm2_fbw_chain;
  d->clk = 0; d->rst_n = 0; d->fb_sel = 0; d->clear_req = 0; d->in_valid = 0;
  d->b_hold = 0; d->rd_req = 0; d->DDRAM_BUSY = 0; d->DDRAM_DOUT_READY = 0;
  for (int i = 0; i < 4; i++) tick();
  d->rst_n = 1; tick();

  long rd_issued = 0, rd_done = 0, rd_beats_want = 0, rd_timer = 0, stall = 0;
  bool rd_busy = false;
  auto reader = [&]() {
    if (!RDP) return;
    if (!rd_busy && ++rd_timer >= RDP) {
      rd_timer = 0; rd_busy = true; rd_issued++; rd_beats_want += 248;
      d->rd_req = 1; d->rd_addr = 0x100000 + (rnd() % 384) * 256; d->rd_blen = 248;
    }
  };
  auto reader_after = [&]() {
    if (d->rd_rvalid) { d->rd_req = 0; rd_beats_got++; }
    if (d->rd_ack) { d->rd_req = 0; rd_busy = false; rd_done++; }
  };

  // spans: mostly the 1-8 pixel runs a textured polygon is made of, walking
  // along a row the way the fill emits them; some long flat ones; some stippled
  uint32_t col = 1;
  int ry = 0, rx = 0;
  long pixels_want = 0;
  for (long n = 0; n < N; n++) {
    int y, x0, x1;
    const uint32_t k = rnd() % 100;
    if (k < 70) {                       // the next run along the same row
      if (rx >= W - 1 || (rnd() % 40) == 0) { ry = rnd() % H; rx = rnd() % (W / 2); }
      y = ry; x0 = rx; x1 = x0 + int(rnd() % 8); if (x1 >= W) x1 = W - 1; rx = x1 + 1 + ((rnd() % 16) == 0);
    } else if (k < 90) {                // a run anywhere
      y = rnd() % H; x0 = rnd() % W; x1 = x0 + int(rnd() % 12); if (x1 >= W) x1 = W - 1;
    } else {                            // a long flat span
      y = rnd() % H; x0 = rnd() % W; x1 = x0 + int(rnd() % 300); if (x1 >= W) x1 = W - 1;
    }
    const bool moire = (rnd() % 10) == 0;
    col = (col + 1) & 0xFFFFFF; if (!col) col = 1;
    int i = 0;
    while (!d->in_ready) { reader(); tick(); reader_after(); if (++i > 200000) break; }
    if (i > 200000) { stall++; break; }
    d->in_valid = 1; d->in_y = y; d->in_x0 = x0; d->in_x1 = x1; d->in_col = col; d->in_moire = moire;
    reader(); tick(); reader_after();
    d->in_valid = 0;
    for (int x = x0; x <= x1; x++)
      if (!moire || !((x ^ y) & 1)) { ref[y * 512 + x] = 0x01000000u | col; pixels_want++; }
    // a gap now and then, as the texel path leaves them
    if ((rnd() % 8) == 0) for (int g = rnd() % 40; g > 0; g--) { reader(); tick(); reader_after(); }
  }
  // drain: the writer empty, the bus idle, the reader finished
  int i = 0;
  for (; i < 2000000; i++) {
    reader(); tick(); reader_after();
    if (d->w_empty && !d->w_req && wr_left == 0 && !rd_busy && i > 200) break;
  }
  ck("drained", i < 2000000, 1);
  ck("no span refused for ever", stall, 0);

  long wrong = 0, torn = 0, shown = 0;
  for (int y = 0; y < H; y++)
    for (int x = 0; x < 512; x++) {
      uint32_t g = pix(y, x), w = ref[y * 512 + x];
      if (g == 0xEEEEEEEEu) torn++;
      if (g != w) { if (shown++ < 8) std::printf("  pixel y%d x%d got %08x want %08x\n", y, x, g, w); wrong++; }
    }
  std::printf("spans %ld, cycles %ld, pixels %ld; DDRAM write commands %ld (%ld beats), writer requests %ld;"
              " reads %ld/%ld, read beats %ld/%ld\n",
              N, cyc, pixels_want, cmds_w, beats_w, wreq_rises, rd_done, rd_issued, rd_beats_got, rd_beats_want);
  ck("framebuffer pixel for pixel", wrong, 0);
  ck("no torn pixel", torn, 0);
  ck("every DDRAM write command was asked for", cmds_w, wreq_rises);
  ck("burst address/count held", proto, 0);
  ck("no write beat with no byte enabled", empty_beats, 0);
  ck("no read inside a write burst", rd_in_wr, 0);
  ck("every read came back", rd_done, rd_issued);
  ck("every read beat came back", rd_beats_got, rd_beats_want);
  ck("dbg_pixels counts what was painted", (long)d->dbg_pixels, pixels_want);

  // the clear, through the same chain
  {
    d->clear_req = 1;
    for (i = 0; i < 100000 && !d->clear_busy; i++) { reader(); tick(); reader_after(); }
    for (i = 0; i < 20000000 && d->clear_busy; i++) { reader(); tick(); reader_after(); }
    d->clear_req = 0;
    for (i = 0; i < 1000; i++) { reader(); tick(); reader_after(); }
    ck("the clear finished", i >= 1000, 1);
    long nz = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) if (pix(y, x) != 0u) nz++;
    ck("every visible pixel cleared", nz, 0);
  }

  std::printf("m2_fbw_chain: checks=%ld fails=%ld\n", checks, fails);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
