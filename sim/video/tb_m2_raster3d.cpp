// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// The 3D back end across video frames: a list delivered every SECOND frame
// must be drawn on EVERY frame (R211).
//
// Daytona hands over a display list at 30 Hz and the bands are drawn just
// ahead of the beam at 60 Hz. With one quad store the frames spent collecting
// drew nothing and the picture flashed. This drives the module the way the
// walker and the beam do: a frame of quads with q_end, then video frames with
// no quads at all, with scan_y sweeping the screen at a pace the fill can beat.
// Every video frame after the first must paint the same number of pixels as
// the first, including the frames during which the NEXT list is collected.
#include "Vm2_raster3d.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>

static int checks = 0, fails = 0;
#define CHECK(c, ...) do { ++checks; if (!(c)) { ++fails; std::printf("  FAIL: " __VA_ARGS__); std::printf("\n"); } } while (0)

static const int SCR_W = 496, SCR_H = 384;

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto d = new Vm2_raster3d;
  d->clk = 0; d->scan_clk = 0; d->rst_n = 0; d->frame_start = 0; d->q_valid = 0; d->q_end = 0;
  d->scan_x = 0; d->scan_y = 0;
  auto tick = [&]() { d->clk = 1; d->scan_clk = 1; d->eval(); d->clk = 0; d->scan_clk = 0; d->eval(); };
  for (int i = 0; i < 4; i++) tick();
  d->rst_n = 1; tick();

  // One frame's list: a column of quads down the screen, one per band.
  auto push_list = [&](int frame_no) {
    d->frame_start = 0;
    for (int b = 0; b < SCR_H / 16; b++) {
      d->q_valid = 1;
      d->q_x0 = 100 + frame_no; d->q_y0 = b * 16 + 2;
      d->q_x1 = 140 + frame_no; d->q_y1 = b * 16 + 2;
      d->q_x2 = 140 + frame_no; d->q_y2 = b * 16 + 12;
      d->q_x3 = 100 + frame_no; d->q_y3 = b * 16 + 12;
      d->q_col = 0xFFFFFF; d->q_z = 0x3F800000; d->q_moire = 0;
      d->q_end = (b == SCR_H / 16 - 1);
      tick();
    }
    d->q_valid = 0; d->q_end = 0;
  };

  // A video frame: frame_start, then the beam sweeps the screen. The fill
  // gets 400 core clocks per scanline -- generous, the point here is not
  // the race with the beam but whether anything is drawn at all.
  auto video_frame = [&](bool count_pixels, long *painted) {
    d->frame_start = 1; tick(); d->frame_start = 0;
    long hits = 0;
    for (int y = 0; y < SCR_H; y++) {
      for (int t = 0; t < 400; t++) {
        d->scan_y = y; d->scan_x = (t < SCR_W) ? t : SCR_W - 1;
        tick();
        if (count_pixels && t < SCR_W && d->scan_hit) ++hits;
      }
    }
    // vblank: a few hundred idle cycles
    for (int t = 0; t < 600; t++) tick();
    if (painted) *painted = hits;
    std::printf("    frame: hits %ld  quads %d dropped %d  bands_done %d ready_cyc %d late %d qend %d bands %d pixels %u\n",
                hits, (int)d->dbg_quads, (int)d->dbg_dropped, (int)d->dbg_bands_done, (int)d->dbg_ready_cyc,
                (int)d->dbg_late_frames, (int)d->dbg_qend_frames, (int)d->dbg_bands, (unsigned)d->dbg_pixels);
  };

  long px[8] = {0};
  // Frame 0: the walk delivers list A during the frame (as it does after the
  // flip); nothing is on display yet.
  push_list(0);
  video_frame(true, &px[0]);
  // Frames 1..3: no new list. All three must draw list A.
  video_frame(true, &px[1]);
  video_frame(true, &px[2]);
  // During frame 3 the walk delivers list B (the next flip).
  d->frame_start = 1; tick(); d->frame_start = 0;
  push_list(1);
  {
    long hits = 0;
    for (int y = 0; y < SCR_H; y++) for (int t = 0; t < 400; t++) {
      d->scan_y = y; d->scan_x = (t < SCR_W) ? t : SCR_W - 1; tick();
      if (t < SCR_W && d->scan_hit) ++hits;
    }
    for (int t = 0; t < 600; t++) tick();
    px[3] = hits;
  }
  // Frames 4, 5: list B on display.
  video_frame(true, &px[4]);
  video_frame(true, &px[5]);

  std::printf("  pixels painted per video frame: %ld %ld %ld %ld %ld %ld\n", px[0], px[1], px[2], px[3], px[4], px[5]);
  // Within 2%: the count includes bands the beam reaches while the fill is
  // still landing them, which moves a few pixels frame to frame in this
  // bench. The fault this guards against is a frame that paints NOTHING.
  auto near = [](long a, long b) { return a > 0 && b > 0 && (a > b ? a - b : b - a) * 50 < a; };
  CHECK(px[1] > 0, "the frame after the list arrived painted nothing");
  CHECK(near(px[2], px[1]), "a frame with no new list painted %ld, the previous %ld -- the picture flashes", px[2], px[1]);
  CHECK(near(px[3], px[1]), "the frame during which the next list was collected painted %ld, not %ld -- the picture flashes", px[3], px[1]);
  CHECK(near(px[4], px[1]) && near(px[5], px[4]), "list B not drawn steadily: %ld %ld", px[4], px[5]);
  CHECK(d->dbg_dropped == 0, "quads dropped: %d", (int)d->dbg_dropped);
  std::printf("m2_raster3d: checks=%d fails=%d\n", checks, fails);
  std::printf(fails ? "FAIL\n" : "PASS\n");
  delete d;
  return fails ? 1 : 0;
}
