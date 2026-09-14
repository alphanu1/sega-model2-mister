// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// m2_tile_fetch: the 2D layer's tile-word and glyph fetch.
//
// WHY THIS EXISTS. This module fetches every glyph of every 2D layer -- all the
// text, the menus, the service screens -- and until now NOTHING in sim/
// instantiated it. Its only coverage was test_m2_video_frame, which needs MAME
// dumps that are not on this machine, so it silently SKIPs. An FSM change here
// went to a Quartus build with no local test at all, which is exactly what the
// project rule forbids.
//
// WHAT IT CHECKS, from m2_tile_decode's own arithmetic rather than from the
// fetcher's behaviour (a bench that mirrors the DUT proves nothing):
//     tile_addr = {1'b0, layer, map_y[8:3], map_x[8:3]}
//     char_addr = tile_num * 16 + (map_y & 7) * 2
// so the expected glyph address for every column is computed independently.
//
// The L1 glyph cache (CC_N = 16) is the point of most of it: a tile that
// repeats within a line must be fetched ONCE, and `fetches` must count the
// requests rather than the columns.

#include "Vm2_tile_fetch.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>
#include <set>

static Vm2_tile_fetch *d;
static long checks = 0, fails = 0;
static void ck(const char *what, long got, long want) {
  checks++;
  if (got != want) { fails++; std::printf("  FAIL %-46s got=%ld want=%ld\n", what, got, want); }
}

// The tile map the bench serves. Deliberately REPETITIVE -- tile = addr % 5 --
// so the 16-entry L1 is exercised: five distinct glyphs across 62 columns.
static uint16_t tram_model(uint16_t addr) { return (uint16_t)(addr % 5); }
// Glyph data, a function of the address so a wrong fetch shows as wrong pixels.
static uint32_t char_model(uint32_t a) { return (a * 0x01010101u) ^ 0xA5A5A5A5u; }

static std::vector<uint32_t> asked;     // char_addr values actually requested
static int ack_delay = 0, ack_ctr = 0;

static void tick() {
  // Tile RAM answers combinationally, as m2_tdp_ram does on this port.
  d->tram_data = tram_model(d->tram_addr);
  // Glyph fetch: answer after ack_delay cycles, as the char cache would.
  d->char_ack = 0;
  if (d->char_req) {
    if (ack_ctr >= ack_delay) {
      d->char_ack  = 1;
      d->char_data = char_model(d->char_addr);
      asked.push_back(d->char_addr);
      ack_ctr = 0;
    } else ack_ctr++;
  } else ack_ctr = 0;
  d->eval();
  d->clk = 0; d->eval();
  d->clk = 1; d->eval();
}

static void run_line(int line, int layer, int delay) {
  asked.clear(); ack_delay = delay; ack_ctr = 0;
  d->line = line; d->layer = layer;
  d->hscr = 0; d->vscr = 0; d->tile_mask = 0x3fff;
  d->row_mask = ~0ull; d->layer_off = 0;
  d->split_en = 0; d->split_x = 0; d->split_right = 0;
  d->start = 1; tick(); d->start = 0;
  for (int i = 0; i < 40000 && (d->busy || i < 4); i++) tick();
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_tile_fetch;
  d->clk = 0; d->rst_n = 0;
  for (int i = 0; i < 4; i++) tick();
  d->rst_n = 1; tick();

  const int COLUMNS = 62;

  // ---- 1. every distinct glyph of the line is fetched, exactly once
  {
    const int line = 9;                       // map_y = 9, so row 1 of the tile
    run_line(line, 0, 0);
    std::printf("test: one fetch per DISTINCT glyph, not per column\n");
    ck("the walk finished", d->busy, 0);

    std::set<uint32_t> want;
    for (int x = 0; x < COLUMNS; x++) {
      uint16_t taddr = (uint16_t)((0 << 12) | ((line >> 3) << 6) | (x & 0x3f));
      uint32_t tile  = tram_model(taddr) & 0x3fff;
      want.insert(tile * 16u + (uint32_t)((line & 7) * 2));
    }
    std::set<uint32_t> got(asked.begin(), asked.end());
    ck("distinct glyphs fetched", (long)got.size(), (long)want.size());
    ck("no glyph fetched twice", (long)asked.size(), (long)want.size());
    bool same = (got == want);
    ck("the addresses are the ones m2_tile_decode names", same ? 1 : 0, 1);
    if (!same) {
      std::printf("    want:"); for (auto v : want) std::printf(" %05x", v);
      std::printf("\n    got :"); for (auto v : got)  std::printf(" %05x", v);
      std::printf("\n");
    }
    ck("fetches counts the requests", d->fetches, (long)asked.size());
  }

  // ---- 2. the row within the tile selects the glyph words
  {
    run_line(9, 0, 0);  auto a = asked;
    run_line(12, 0, 0); auto b = asked;
    std::printf("test: a different scanline reads a different row of the glyph\n");
    // line 9 -> row 1 -> +2 ; line 12 -> row 4 -> +8. Same tiles, different rows.
    bool differ = (a != b);
    ck("a different row asks for different words", differ ? 1 : 0, 1);
    if (!a.empty() && !b.empty())
      ck("and the offset is (line & 7) * 2", (long)((b[0] & 15) - (a[0] & 15)), 6);
  }

  // ---- 3. A SLOW GLYPH FETCH MUST NOT LOSE PIXELS. The char cache can take
  //      tens of cycles on an SDRAM miss, and the fetcher has to hold rather
  //      than run on -- the R162 failure mode.
  {
    run_line(9, 0, 0);       auto fast = asked;
    run_line(9, 0, 17);      auto slow = asked;
    std::printf("test: a slow glyph fetch changes timing, not content\n");
    ck("the same glyphs are fetched", (slow == fast) ? 1 : 0, 1);
    ck("and the walk still finished", d->busy, 0);
  }

  // ---- 4. A LAYER THAT IS OFF STILL FETCHES, AND MASKS THE PIXELS.
  //
  // The bench first asserted that layer_off fetches nothing, and the RTL was
  // right: `layer_off` only ORs into lb_masked (m2_tile_fetch line 540), so the
  // glyphs are read and then thrown away at the line buffer. Written down
  // because the wrong expectation nearly became a "fix" to working code.
  //
  // It is also a real inefficiency -- a disabled layer costs full glyph
  // bandwidth on a memory that is the binding resource -- but that is a change
  // with a picture risk (a layer re-enabled mid-frame would have a cold L1),
  // so it is recorded here rather than made.
  {
    asked.clear(); ack_delay = 0;
    d->line = 9; d->layer = 0; d->hscr = 0; d->vscr = 0;
    d->tile_mask = 0x3fff; d->row_mask = ~0ull;
    d->layer_off = 1; d->split_en = 0; d->split_x = 0; d->split_right = 0;
    d->start = 1; tick(); d->start = 0;
    for (int i = 0; i < 40000 && (d->busy || i < 4); i++) tick();
    std::printf("test: a layer that is off masks its pixels, and still fetches\n");
    ck("it still fetches (masking is at the line buffer)", (long)asked.size() > 0, 1);
    ck("every pixel written is masked", d->lb_masked, 15);
    ck("and it still completes", d->busy, 0);
  }

  std::printf("m2_tile_fetch: checks=%ld fails=%ld\n", checks, fails);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
