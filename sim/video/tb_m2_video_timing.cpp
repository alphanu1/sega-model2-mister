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

  std::printf("  %llu checks, %llu mismatches\n",
              (unsigned long long)checks, (unsigned long long)fails);
  std::printf(fails ? "FAIL\n" : "PASS\n");
  delete dut;
  return fails ? 1 : 0;
}
