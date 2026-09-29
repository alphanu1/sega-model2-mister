// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The video timing is checked against MAME's set_raw numbers, NOT against
// itself. `model2.cpp`:
//
//   m_screen->set_raw(32_MHz_XTAL/2, 656, 0, 496, 424, 0, 384);
//
// so 16 MHz, 656x424 total, 496x384 visible, 57.52 Hz. Those totals set the
// frame rate; a core that runs at the wrong rate drifts audio and tears
// scrolling in ways that look like unrelated bugs, which is why they are
// asserted here rather than trusted as parameters.

#include "Vm2_video_timing.h"
#include "verilated.h"
#include <cstdio>
#include <vector>
#include <cstdint>

static Vm2_video_timing *dut;
static uint64_t fails = 0, checks = 0;

static void ck(bool ok, const char *what, long got, long want) {
  ++checks;
  if (!ok) { std::printf("  MISMATCH %-28s got=%ld want=%ld\n", what, got, want); ++fails; }
}
static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vm2_video_timing;

  dut->rst_n = 0; dut->ce_pix = 1;
  for (int i = 0; i < 4; i++) tick();
  dut->rst_n = 1;

  // Settle to a known frame boundary before counting anything.
  for (int guard = 0; guard < 2000000 && !dut->vblank_start; ++guard) tick();
  ck(dut->vblank_start, "reached a frame boundary", dut->vblank_start, 1);
  // Do NOT tick here. `vblank_start` is high ON cycle 0 of the frame, so
  // advancing past it drops that cycle from the count and every total comes out
  // one short -- which reads exactly like an off-by-one in the RTL counters. It
  // was reported as one before this comment was written. The loop below counts
  // cycle 0 through cycle N-1 and breaks when the NEXT boundary appears.
  

  // One whole frame, counted edge by edge.
  long pix = 0, vis = 0, lines = 0, line_starts = 0, vbs = 0;
  long hs = 0, vs = 0, hb = 0, vb = 0;
  long vis_per_line = 0, max_vis_line = 0, min_vis_line = 1 << 30;
  int  prev_v = dut->vcnt;

  for (long guard = 0; guard < 2000000; ++guard) {
    ++pix;
    if (dut->visible) { ++vis; ++vis_per_line; }
    if (dut->hsync)   ++hs;
    if (dut->vsync)   ++vs;
    if (dut->hblank)  ++hb;
    if (dut->vblank)  ++vb;
    if (dut->line_start)   ++line_starts;
    if (dut->vblank_start) ++vbs;
    tick();
    if (dut->vcnt != prev_v) {                    // line rolled
      ++lines;
      if (vis_per_line) {
        if (vis_per_line > max_vis_line) max_vis_line = vis_per_line;
        if (vis_per_line < min_vis_line) min_vis_line = vis_per_line;
      }
      vis_per_line = 0;
      prev_v = dut->vcnt;
    }
    if (dut->vblank_start) break;                 // exactly one frame
  }

  // MAME's set_raw, asserted directly.
  ck(pix   == 656 * 424, "pixel clocks per frame",  pix,   656 * 424);
  ck(lines == 424,       "lines per frame",         lines, 424);
  ck(vis   == 496 * 384, "visible pixels per frame",vis,   496 * 384);
  ck(max_vis_line == 496, "visible pixels, longest line", max_vis_line, 496);
  ck(min_vis_line == 496, "visible pixels, shortest line", min_vis_line, 496);
  ck(line_starts == 424, "line_start per frame",    line_starts, 424);
  ck(vbs == 1,           "vblank_start per frame",  vbs, 1);

  // Sync widths follow from the parameters; assert them so a change to one
  // without the other is caught.
  ck(hs == (584 - 520) * 424, "hsync cycles per frame", hs, (584 - 520) * 424);
  ck(vs == (395 - 392) * 656, "vsync cycles per frame", vs, (395 - 392) * 656);
  ck(hb == (656 - 496) * 424, "hblank cycles per frame", hb, (656 - 496) * 424);
  ck(vb == (424 - 384) * 656, "vblank cycles per frame", vb, (424 - 384) * 656);

  const double hz = 16.0e6 / double(656 * 424);
  std::printf("  frame rate at 16 MHz: %.2f Hz  (MAME: 57.52)\n", hz);
  ck(hz > 57.4 && hz < 57.6, "frame rate in range", long(hz * 100), 5752);

  // ---- R682: 15 kHz INTERLACED. Two fields from a field-0 boundary.
  {
    dut->interlace = 1;
    // settle: run until a vblank_start in field 0 (so the next field is 1)
    int settle = 0;
    for (long g = 0; g < 4000000 && settle < 3; ++g) { tick(); if (dut->vblank_start) ++settle; }
    for (long g = 0; g < 4000000 && !(dut->vblank_start && dut->field == 0); ++g) tick();
    ck(dut->vblank_start && dut->field == 0, "interlaced: reached a field-0 boundary", dut->vblank_start, 1);
    // count from the line after field 0's last visible line through the end of field 0's
    // next occurrence: i.e. field 1 then field 0 (one interlaced frame of 547 lines)
    long lines[2] = {0,0}, visl[2] = {0,0}, vbs2 = 0, hs2 = 0, pix2 = 0;
    long vs_start_h[2] = {-1,-1};
    std::vector<int> seen(384, 0), order;
    std::vector<std::pair<long,int>> ln_at;           // (line index G, line_number) at each line_start
    std::vector<int> shownG;                          // G -> ypos shown on that line, -1 if blank
    long G = 0; shownG.push_back(-1);
    long dl = 0; int prev_v = dut->vcnt, prev_vs = dut->vsync, fld = dut->field;
    for (long g = 0; g < 4000000; ++g) {
      ++pix2;
      if (dut->hsync) ++hs2;
      if (dut->vsync && !prev_vs) vs_start_h[dut->field] = dut->hcnt;
      prev_vs = dut->vsync;
      if (dut->visible && dut->hcnt == 0) { seen[dut->ypos]++; order.push_back(dut->ypos); shownG[G] = dut->ypos; }
      if (dut->line_start) ln_at.push_back({G, (int)dut->line_number});
      fld = dut->field;
      tick();
      if (dut->vcnt != prev_v) { ++lines[fld]; if (prev_v < 192) ++visl[fld]; prev_v = dut->vcnt; ++G; shownG.push_back(-1); }
      if (dut->vblank_start) { ++vbs2; if (vbs2 == 2) break; }
    }
    ck(lines[1] == 273 || lines[1] == 274, "interlaced: field 1 lines", lines[1], 273);
    ck(lines[0] + lines[1] == 547, "interlaced: lines a frame (two fields)", lines[0] + lines[1], 547);
    ck(visl[0] == 192 && visl[1] == 192, "interlaced: 192 visible lines a field", visl[0] + visl[1], 384);
    ck(vbs2 == 2, "interlaced: one vblank_start a field", vbs2, 2);
    long dup = 0, miss = 0; for (int y = 0; y < 384; ++y) { if (seen[y] == 0) ++miss; if (seen[y] > 1) ++dup; }
    ck(miss == 0 && dup == 0, "interlaced: every line 0-383 shown exactly once a frame", miss + dup, 0);
    long parity_bad = 0; for (size_t i = 1; i < order.size(); ++i) if (i != 192 && order[i] != order[i-1] + 2) ++parity_bad;
    ck(parity_bad == 0, "interlaced: a field steps by two lines", parity_bad, 0);
    // line_number at the line_start ending line G names the line SHOWN on line G+2
    // (rendered during G+1, the progressive rule): checked wherever G+2 shows one
    long ahead_bad = 0, ahead_n = 0;
    for (auto &p : ln_at) { size_t k = p.first + 2; if (k < shownG.size() && shownG[k] >= 0) { ++ahead_n; if (shownG[k] != p.second) ++ahead_bad; } }
    ck(ahead_n > 300 && ahead_bad == 0, "interlaced: line_number is the line shown next", ahead_bad, 0);
    ck(vs_start_h[0] == 0 && vs_start_h[1] == 656 / 2, "interlaced: field 1's vsync starts half a line in", vs_start_h[1], 328);
    ck(hs2 == (584 - 520) * 547, "interlaced: hsync cycles a frame", hs2, (584 - 520) * 547);
    const double pixclk = 100.0e6 * 547.0 / 5300.0;
    std::printf("  interlaced at %.4f MHz: line %.1f Hz, field %.3f Hz\n", pixclk / 1e6, pixclk / 656.0, pixclk / (656.0 * 273.5));
    ck(pixclk / (656.0 * 273.5) > 57.50 && pixclk / (656.0 * 273.5) < 57.55, "interlaced: field rate is the game's", 0, 0);
  }

  std::printf("  %llu checks, %llu mismatches\n",
              (unsigned long long)checks, (unsigned long long)fails);
  std::printf(fails ? "FAIL\n" : "PASS\n");
  delete dut;
  return fails ? 1 : 0;
}
