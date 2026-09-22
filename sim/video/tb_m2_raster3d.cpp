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
// The real vertical timing, because the fault R225 fixed lives in the blanking
// lines: 424 total against 384 visible (m2_video_timing, MAME's set_raw).
static const int V_TOTAL = 424, BAND_H = 8;
static long top_hits = 0;
static unsigned vbl_bands = 0;
// CLOCKS PER SCANLINE, AND IT IS A TEST PARAMETER BECAUSE THE FAULT LIVES IN
// THE RATIO (R225). At 400 the fill is ten times faster than the beam and
// recovers from losing a band before the beam can notice; the board's fill is
// only about half again as fast as its beam, and there losing four bands in
// the blanking interval emptied the top eighth of the screen. M2_R3D_TPL sets
// it; the default is tight enough to reproduce that.
static int TPL = 400;

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const bool g_textured = std::getenv("M2_R3D_TEX") != nullptr;
  if (const char *e = std::getenv("M2_R3D_TPL")) TPL = std::atoi(e);
  if (g_textured) std::printf("  TEXTURED quads (M2_R3D_TEX)\n");
  std::printf("  %d core clocks per scanline\n", TPL);
  auto d = new Vm2_raster3d;
  d->clk = 0; d->clk_mem = 0; d->scan_clk = 0; d->rst_n = 0; d->frame_start = 0; d->q_valid = 0; d->q_end = 0;
  d->scan_x = 0; d->scan_y = 0;
  d->tex_m_ack = 0; d->tex_m_data = 0; d->tex_inval = 0;
  d->tex_base0 = 0x1760000; d->tex_base1 = 0x17E0000;
  // R291: A MEMORY FOR THE TEXEL FETCH. Without one the unit times out on
  // every fetch -- 1,023 cycles a texel -- and the fill grinds to a halt,
  // which is a bench artefact and not the fault being chased. With one, this
  // bench runs the whole texture path for the first time.
  int tex_wait = -1;
  auto tick = [&]() {
    if (d->tex_m_req && tex_wait < 0) tex_wait = 8;
    if (tex_wait == 0) {
      d->tex_m_ack = 1;
      d->tex_m_data = 0x0123456789abcdefULL ^ (uint64_t)d->tex_m_addr;
    }
    d->eval();
    // R318: clk_mem runs at 2x clk, as it does on hardware -- m2_texel lives on
    // it now and m2_texel_x2 carries the request across the 2:1. Leaving it at
    // zero (as this bench did) means the texel unit never clocks, the crossing
    // is never exercised, and a PASS here says nothing about the change.
    d->clk_mem = 1; d->eval(); d->clk_mem = 0; d->eval();
    d->clk = 1; d->scan_clk = 1; d->eval(); d->clk = 0; d->scan_clk = 0; d->eval();
    d->clk_mem = 1; d->eval(); d->clk_mem = 0; d->eval();
    if (d->tex_m_ack) { d->tex_m_ack = 0; tex_wait = -1; }
    else if (tex_wait > 0) --tex_wait;
  };
  for (int i = 0; i < 4; i++) tick();
  d->rst_n = 1; tick();

  // One frame's list: a column of quads down the screen, one per band.
  auto push_list = [&](int frame_no) {
    d->frame_start = 0;
    for (int b = 0; b < SCR_H / 16; b++) {
      // R220: the store may be holding a finished list; wait for it.
      { int g = 0; d->q_valid = 0; d->eval(); while (!d->q_ready && g++ < 100000) tick(); }
      d->q_valid = 1;
      d->q_x0 = 100 + frame_no; d->q_y0 = b * 16 + 2;
      d->q_x1 = 140 + frame_no; d->q_y1 = b * 16 + 2;
      d->q_x2 = 140 + frame_no; d->q_y2 = b * 16 + 12;
      d->q_x3 = 100 + frame_no; d->q_y3 = b * 16 + 12;
      d->q_col = 0xFFFFFF; d->q_z = 0x3F800000; d->q_moire = 0;
      // R291: THE TEXTURED BIT, which no test has ever set. Two builds with
      // the texture path live hung the board before the game started, and the
      // only thing they have that the working build does not is this bit.
      if (g_textured) {
        d->q_tex = 0x000001 | (2u << 1) | (2u << 4);   // 128x128, sheet 0
        d->q_u0 = 0;   d->q_v0 = 0;
        d->q_u1 = 400; d->q_v1 = 0;
        d->q_u2 = 400; d->q_v2 = 200;
        d->q_u3 = 0;   d->q_v3 = 200;
      } else {
        d->q_tex = 0;
      }
      d->q_end = (b == SCR_H / 16 - 1);
      tick();
    }
    d->q_valid = 0; d->q_end = 0;
  };

  // A video frame: frame_start, then the beam sweeps the screen. The fill
  // gets 400 core clocks per scanline -- generous, the point here is not
  // the race with the beam but whether anything is drawn at all.
  auto video_frame = [&](bool count_pixels, long *painted) {
    // THE FRAME IS BLANK-FIRST, AS THE BOARD'S IS (R225). frame_start is the
    // rising edge of vblank, so the fill's head start is the 40 blanking lines
    // that follow it -- and those lines are where the fault lived. This bench
    // used to pulse frame_start and sweep the VISIBLE lines immediately, then
    // idle 600 ticks with scan_y parked on the last visible line, so it had
    // neither the head start nor the out-of-range line numbers and could not
    // see the top of the screen being thrown away.
    // R505: THE BEAM IS ALREADY IN BLANKING WHEN frame_start FIRES, as it is
    // on the board -- frame_start is the start of vblank, so scan_y is at or
    // past SCR_H and m2_raster3d clamps scan_band_rel to zero there. This line
    // used to pulse it with scan_y still on the LAST VISIBLE LINE, so the DUT
    // saw the beam at band 47 while the fill reset to band 0. Any logic that
    // compares the two -- which is the natural way to ask "is the fill behind
    // the beam" -- fired spuriously for that tick. R489 was reverted on exactly
    // that, reported as "the top band painted nothing".
    d->scan_y = SCR_H; d->scan_x = 0; tick();
    d->frame_start = 1; tick(); d->frame_start = 0;
    long hits = 0;
    top_hits = 0;
    const unsigned bands_at_fs = d->dbg_bands;
    for (int y = SCR_H; y < V_TOTAL; y++)
      for (int t = 0; t < TPL; t++) { d->scan_y = y; d->scan_x = 0; tick(); }
    // R225: how many bands the fill finished during blanking, and how many of
    // them it still holds. Held < finished means the release threw them away.
    vbl_bands = d->dbg_bands - bands_at_fs;
    for (int y = 0; y < SCR_H; y++) {
      for (int t = 0; t < TPL; t++) {
        d->scan_y = y; d->scan_x = (t < SCR_W) ? t : SCR_W - 1;
        tick();
        if (count_pixels && t < SCR_W && d->scan_hit) { ++hits; if (y < BAND_H) ++top_hits; }
      }
    }
    if (painted) *painted = hits;
    // R485: `pixels` is gone -- it was a 32-bit sum that reached nothing in the
    // real design and Quartus deleted it there. `painted` is the number the
    // five per-band flags now feed, and it is the one that was ever read.
    std::printf("    frame: hits %ld  quads %d dropped %d  bands_done %d ready_cyc %d late %d qend %d bands %d painted %d\n",
                hits, (int)d->dbg_quads, (int)d->dbg_dropped, (int)d->dbg_bands_done, (int)d->dbg_ready_cyc,
                (int)d->dbg_late_frames, (int)d->dbg_qend_frames, (int)d->dbg_bands, (int)d->dbg_bands_painted);
    std::printf("      bands filled during vblank: %u\n", vbl_bands);
  };

  long px[8] = {0};
  // R225: the top band must be painted. The list below puts a quad in every
  // 16-row band, so band 0 has geometry and a frame that paints none of it is
  // the board's missing top bands reproduced at the desk.
  long top_px[8] = {0};
  // Frame 0: the walk delivers list A during the frame (as it does after the
  // flip); nothing is on display yet.
  push_list(0);
  video_frame(true, &px[0]); top_px[0] = top_hits;
  // Frames 1..3: no new list. All three must draw list A.
  video_frame(true, &px[1]); top_px[1] = top_hits;
  video_frame(true, &px[2]); top_px[2] = top_hits;
  // During frame 3 the walk delivers list B (the next flip).
  d->frame_start = 1; tick(); d->frame_start = 0;
  push_list(1);
  {
    long hits = 0;
    for (int y = SCR_H; y < V_TOTAL; y++)
      for (int t = 0; t < TPL; t++) { d->scan_y = y; d->scan_x = 0; tick(); }
    for (int y = 0; y < SCR_H; y++) for (int t = 0; t < TPL; t++) {
      d->scan_y = y; d->scan_x = (t < SCR_W) ? t : SCR_W - 1; tick();
      if (t < SCR_W && d->scan_hit) { ++hits; if (y < BAND_H) ++top_hits; }
    }
    px[3] = hits;
  }
  // Frames 4, 5: list B on display.
  video_frame(true, &px[4]); top_px[4] = top_hits;
  video_frame(true, &px[5]); top_px[5] = top_hits;

  std::printf("  pixels painted per video frame: %ld %ld %ld %ld %ld %ld\n", px[0], px[1], px[2], px[3], px[4], px[5]);
  // Within 2%: the count includes bands the beam reaches while the fill is
  // still landing them, which moves a few pixels frame to frame in this
  // bench. The fault this guards against is a frame that paints NOTHING.
  auto near = [](long a, long b) { return a > 0 && b > 0 && (a > b ? a - b : b - a) * 50 < a; };
  std::printf("  pixels painted in the TOP band: %ld %ld %ld %ld %ld\n",
              top_px[0], top_px[1], top_px[2], top_px[4], top_px[5]);
  CHECK(px[1] > 0, "the frame after the list arrived painted nothing");
  CHECK(top_px[1] > 0, "the top band painted nothing -- the fill lost it during vblank (R225)");
  CHECK(top_px[2] > 0, "the top band painted nothing on a held frame (R225)");
  CHECK(top_px[5] > 0, "the top band painted nothing on a later frame (R225)");
  CHECK(near(px[2], px[1]), "a frame with no new list painted %ld, the previous %ld -- the picture flashes", px[2], px[1]);
  CHECK(near(px[3], px[1]), "the frame during which the next list was collected painted %ld, not %ld -- the picture flashes", px[3], px[1]);
  CHECK(near(px[4], px[1]) && near(px[5], px[4]), "list B not drawn steadily: %ld %ld", px[4], px[5]);
  CHECK(d->dbg_dropped == 0, "quads dropped: %d", (int)d->dbg_dropped);
  std::printf("m2_raster3d: checks=%d fails=%d\n", checks, fails);
  std::printf(fails ? "FAIL\n" : "PASS\n");
  delete d;
  return fails ? 1 : 0;
}
