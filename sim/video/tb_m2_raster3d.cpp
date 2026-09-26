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
#include "Vm2_raster3d___024root.h"
#include <cstdio>
#include <cstring>
#include <cmath>
#include <string>
#include <algorithm>
#include <cstdlib>
#include <cstdint>
#include <vector>

static int checks = 0, fails = 0;
#define CHECK(c, ...) do { ++checks; if (!(c)) { ++fails; std::printf("  FAIL: " __VA_ARGS__); std::printf("\n"); } } while (0)

static const int SCR_W = 496, SCR_H = 384;
// The real vertical timing, because the fault R225 fixed lives in the blanking
// lines: 424 total against 384 visible (m2_video_timing, MAME's set_raw).
// R538: BAND_H follows the build (-GBAND_H=...) through M2_R3D_BAND_H.
static const int V_TOTAL = 424;
static int BAND_H = 8;    // the shipped band height
static bool px_dump = false;   // R542: M2_R3D_PXDUMP, every painted pixel of the last frame
static uint64_t frame_hash = 1469598103934665603ull;   // R542: this frame only
static uint64_t pix_hash = 1469598103934665603ull;   // R539: every painted pixel, all frames
static long fill_hist[32], walk_busy = 0, cst_hist[8], why_hist[8], fw_hist[32], sw_hist[8];   // R539: fill state per cycle, per frame
static long top_hits = 0;
static unsigned vbl_bands = 0;
// CLOCKS PER SCANLINE, AND IT IS A TEST PARAMETER BECAUSE THE FAULT LIVES IN
// THE RATIO (R225). At 400 the fill is ten times faster than the beam and
// recovers from losing a band before the beam can notice; the board's fill is
// only about half again as fast as its beam, and there losing four bands in
// the blanking interval emptied the top eighth of the screen. M2_R3D_TPL sets
// it; the default is tight enough to reproduce that.
static int TPL = 400;

// R555: M2_R3D_TEXPAT -- a 4x4-texel checkerboard (3 / C) in place of noise,
// so a texel taken from the wrong place is visible in an image. A 16-bit word
// holds a 2x2 texel block (nib() in m2_texel: py0px0 [15:12], py0px1 [11:8],
// py1px0 [7:4], py1px1 [3:0]); a sheet row is 512 words; a line is 4 words.
// R615: M2_R3D_LIST mode serves texels from MAME's own texture RAM (two
// sheets, 16-bit words, word i = the i-th halfword of MAME's u32 array).
static std::vector<uint32_t> g_tex[2];
static uint32_t g_tbase1 = 0;
static uint64_t texpat_line(uint32_t addr, uint32_t base) {
  if (!g_tex[0].empty()) {
    const int sh = (addr >= g_tbase1) ? 1 : 0;
    const uint32_t w0 = addr - (sh ? g_tbase1 : base);
    uint64_t line = 0;
    for (int k = 0; k < 4; ++k) {
      const uint32_t w = w0 + k;
      const uint32_t dw = (w >> 1) < g_tex[sh].size() ? g_tex[sh][w >> 1] : 0xffffffffu;
      line |= uint64_t((w & 1) ? (dw >> 16) : (dw & 0xffff)) << (16 * k);
    }
    return line;
  }
  static const bool PAT = std::getenv("M2_R3D_TEXPAT") != nullptr;
  if (!PAT) return 0x0123456789abcdefULL ^ (uint64_t)addr;
  uint64_t line = 0;
  for (int k = 0; k < 4; ++k) {
    const uint32_t w = addr + k - base;
    const int tx0 = int(w % 512) * 2, ty0 = int(w / 512) * 2;
    uint32_t word = 0;
    for (int py = 0; py < 2; ++py) for (int px = 0; px < 2; ++px) {
      const int tx = tx0 + px, ty = ty0 + py;
      const uint32_t v = (((tx >> 2) ^ (ty >> 2)) & 1) ? 0xC : 0x3;
      const int sh = 12 - 4 * (py * 2 + px);
      word |= v << sh;
    }
    line |= uint64_t(word) << (16 * k);
  }
  return line;
}

struct Fetch { int y, x; uint32_t u, v, t, c; };
static std::vector<Fetch> g_fetch;
static bool g_rec = false;

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const bool g_textured = std::getenv("M2_R3D_TEX") != nullptr;
  if (const char *e = std::getenv("M2_R3D_TPL")) TPL = std::atoi(e);
  if (const char *e = std::getenv("M2_R3D_BAND_H")) BAND_H = std::atoi(e);
  if (g_textured) std::printf("  TEXTURED quads (M2_R3D_TEX)\n");
  std::printf("  %d core clocks per scanline\n", TPL);
  auto d = new Vm2_raster3d;
  d->clk = 0; d->clk_mem = 0; d->scan_clk = 0; d->rst_n = 0; d->frame_start = 0; d->q_valid = 0; d->q_end = 0;
  d->scan_x = 0; d->scan_y = 0;
  d->tex_m_ack = 0; d->tex_m_data = 0; d->tex_inval = 0;
  d->tex_m2_ack = 0; d->tex_m2_data = 0;
  // The board raises this once boot is done and never lowers it.
  d->tex_m2_en = 1;                                        // R517
  d->tex_base0 = 0x1760000; d->tex_base1 = 0x17E0000;
  // R555: 1/z FOR EVERY VERTEX, WHICH THIS BENCH NEVER DROVE. q_oz0..3 (R334,
  // a minifloat: 8-bit exponent, top 8 mantissa bits) were left at zero, so the
  // perspective divide gave every pixel the same texture coordinate -- every
  // textured scene here sampled ONE texel, always a cache hit. 0x7F00 is 1.0:
  // equal 1/z, plain affine texturing. M2_R3D_OZ overrides it.
  { const unsigned oz = std::getenv("M2_R3D_OZ") ? unsigned(std::strtoul(std::getenv("M2_R3D_OZ"), nullptr, 16)) : 0x7F00u;
    d->q_oz0 = oz; d->q_oz1 = oz; d->q_oz2 = oz; d->q_oz3 = oz; }
  // R291: A MEMORY FOR THE TEXEL FETCH. Without one the unit times out on
  // every fetch -- 1,023 cycles a texel -- and the fill grinds to a halt,
  // which is a bench artefact and not the fault being chased. With one, this
  // bench runs the whole texture path for the first time.
  // R517: AND THE SECOND PORT, WHICH THIS BENCH HAS NEVER DRIVEN.
  //
  // R482 gave the texel cache a second SDRAM port and two MSHRs, and the board
  // enables it (p2_tex) once the coprocessor and calibration are done. This
  // bench left tex_m2_en low and tex_m2_ack dead, so every run here has
  // exercised a SINGLE-PORT cache while the board runs a two-port one.
  //
  // That matters for R490: the span overlap changes WHEN fetches are issued
  // relative to spans, the cache's two MSHRs change how they are served, and
  // the interaction between them is the one thing no test has ever covered.
  // R490 has failed on hardware three times in three different ways and passes
  // every bench, including a 20,000-span soak (R513).
  //
  // THE TWO PORTS ANSWER AT DIFFERENT LATENCIES ON PURPOSE. Equal latencies
  // let a cache return responses in issue order by accident; different ones
  // prove it does so by construction. tb_m2_texel uses 7 against 3 for exactly
  // this reason.
  // R518: AND THE CACHE GETS SWEPT, because on the board it does.
  //
  // tex_inval has been tied to zero here for the life of this bench. The board
  // sweeps the texel cache whenever the texture base moves -- the capture of
  // s162 shows the count climbing about 1.7 times a second -- and a sweep
  // drops m2_texel's `rdy` for the duration while requests are outstanding.
  //
  // That is the window R490 widens: with the overlap there are two spans in
  // flight rather than one, so a sweep is far more likely to land while a
  // fetch is outstanding. R490 works on the board for THREE TO FIVE SECONDS
  // and then the 3D stops for good, which is the right order of magnitude for
  // an event arriving twice a second.
  //
  // M2_R3D_SWEEP is the period in ticks; 0 disables it.
  static const long SWEEP = std::getenv("M2_R3D_SWEEP")
                          ? atol(std::getenv("M2_R3D_SWEEP")) : 0;
  long sweep_ctr = 0;
  int tex_wait = -1, tex2_wait = -1;
  auto tick = [&]() {
    if (SWEEP) {
      if (++sweep_ctr >= SWEEP) { sweep_ctr = 0; d->tex_inval = 1; }
      else                        d->tex_inval = 0;
    }
    // R553: M2_R3D_TEXLAT sets the texel memory's latency in core cycles; the
    // default 8 is far quicker than the board's contended SDRAM.
    static const int TEXLAT = std::getenv("M2_R3D_TEXLAT") ? std::atoi(std::getenv("M2_R3D_TEXLAT")) : 8;
    if (d->tex_m_req && tex_wait < 0) tex_wait = TEXLAT;
    if (tex_wait == 0) {
      d->tex_m_ack = 1;
      d->tex_m_data = texpat_line(d->tex_m_addr, d->tex_base0);
    }
    if (d->tex_m2_req && tex2_wait < 0) tex2_wait = TEXLAT + 6;
    if (tex2_wait == 0) {
      d->tex_m2_ack = 1;
      d->tex_m2_data = texpat_line(d->tex_m2_addr, d->tex_base0);
    }
    d->eval();
    // R615: every real fetch, for the frame differential
    if (g_rec && d->rootp->m2_raster3d__DOT__u_spantex__DOT__dbg_fetch)
      g_fetch.push_back({(int)d->rootp->m2_raster3d__DOT__u_spantex__DOT__dbg_fetch_y,
                         (int)d->rootp->m2_raster3d__DOT__u_spantex__DOT__dbg_fetch_x,
                         (uint32_t)d->rootp->m2_raster3d__DOT__u_spantex__DOT__dbg_fetch_u,
                         (uint32_t)d->rootp->m2_raster3d__DOT__u_spantex__DOT__dbg_fetch_v,
                         (uint32_t)d->rootp->m2_raster3d__DOT__u_spantex__DOT__dbg_fetch_t,
                         (uint32_t)d->rootp->m2_raster3d__DOT__u_spantex__DOT__dbg_fetch_c});
    // R318: clk_mem runs at 2x clk, as it does on hardware -- m2_texel lives on
    // it now and m2_texel_x2 carries the request across the 2:1. Leaving it at
    // zero (as this bench did) means the texel unit never clocks, the crossing
    // is never exercised, and a PASS here says nothing about the change.
    // R564: M2_R3D_SCANMEM puts the scan side on clk_mem, as Model2.sv now
    // does (build the bench with -GTWO_CLOCKS=1 for it).
    static const bool SCANMEM = std::getenv("M2_R3D_SCANMEM") != nullptr;
    if (SCANMEM) {
      d->clk_mem = 1; d->scan_clk = 1; d->eval(); d->clk_mem = 0; d->scan_clk = 0; d->eval();
      d->clk = 1; d->eval(); d->clk = 0; d->eval();
      d->clk_mem = 1; d->scan_clk = 1; d->eval(); d->clk_mem = 0; d->scan_clk = 0; d->eval();
    } else {
    d->clk_mem = 1; d->eval(); d->clk_mem = 0; d->eval();
    d->clk = 1; d->scan_clk = 1; d->eval(); d->clk = 0; d->scan_clk = 0; d->eval();
    d->clk_mem = 1; d->eval(); d->clk_mem = 0; d->eval();
    }
    if (d->tex_m_ack) { d->tex_m_ack = 0; tex_wait = -1; }
    else if (tex_wait > 0) --tex_wait;
    if (d->tex_m2_ack) { d->tex_m2_ack = 0; tex2_wait = -1; }
    else if (tex2_wait > 0) --tex2_wait;    // R539: where the fill's time goes, a cycle at a time.
    ++fill_hist[d->dbg_fill_hot & 31];
    ++cst_hist[d->rootp->m2_raster3d__DOT__cst & 7];
    ++why_hist[d->rootp->m2_raster3d__DOT__fill_why & 7];
    if ((d->rootp->m2_raster3d__DOT__cst & 7) == 5) ++fw_hist[d->dbg_fill_hot & 31];   // R542: C_FILLW, by fill state
    ++sw_hist[d->rootp->m2_raster3d__DOT__u_spantex__DOT__wait_why & 7];   // R551
    if (d->dbg_walk_hot) ++walk_busy;
  };
  for (int i = 0; i < 4; i++) tick();
  d->rst_n = 1; tick();

  // One frame's list: a column of quads down the screen, one per band.
  //
  // R506: AND OPTIONALLY A ROAD. Every quad here is identical, so every band
  // costs the same and the fill is either comfortably ahead of the beam or
  // uniformly too slow for it. THE BOARD IS IN NEITHER STATE: it completes 51
  // band-fills a frame -- which a uniformly slow fill cannot do -- and still
  // shows two to five bands, because its cost is NOT uniform. The top of a
  // Daytona frame is sky and mountains and is cheap; the road across the lower
  // half is heavily textured and each of those bands overruns its band-time.
  // The fill loses its lead there and, at 8% average margin, never gets it
  // back inside the frame.
  //
  // M2_R3D_HEAVY puts that variance in: bands in the lower half get that many
  // quads instead of one. Without it this bench cannot reproduce the fault it
  // is meant to be testing, which is why every band-handshake change this
  // session passed it and failed on hardware.
  static const int HEAVY = std::getenv("M2_R3D_HEAVY")
                         ? std::atoi(std::getenv("M2_R3D_HEAVY")) : 1;
  auto push_list = [&](int frame_no) {
    d->frame_start = 0;
    // R555: M2_R3D_IMG -- ONE big textured quad, off both sides of the screen,
    // many bands tall, for looking at the picture rather than counting it.
    if (std::getenv("M2_R3D_IMG")) {
      { int g = 0; d->q_valid = 0; d->eval(); while (!d->q_ready && g++ < 100000) tick(); }
      d->q_valid = 1;
      d->q_x0 = -40; d->q_y0 = 20; d->q_x1 = 540; d->q_y1 = 20;
      d->q_x2 = 540; d->q_y2 = 360; d->q_x3 = -40; d->q_y3 = 360;
      d->q_col = 0xFFFFFF; d->q_z = 0x3F800000; d->q_moire = 0;
      d->q_tex = 0x000001 | (2u << 1) | (2u << 4);
      static const int IU = std::getenv("M2_R3D_IMGU") ? std::atoi(std::getenv("M2_R3D_IMGU")) : 4000;
      d->q_u0 = 0;   d->q_v0 = 0;   d->q_u1 = IU;  d->q_v1 = 0;
      d->q_u2 = IU;  d->q_v2 = IU;  d->q_u3 = 0;   d->q_v3 = IU;
      // R558: M2_R3D_PERSP gives the four vertices different 1/z (near on the
      // left, far on the right), so the perspective divide is exercised.
      if (std::getenv("M2_R3D_PERSP")) { d->q_oz0 = 0x7F00; d->q_oz1 = 0x7D80; d->q_oz2 = 0x7D80; d->q_oz3 = 0x7F00; }
      d->q_end = 1;
      tick();
      d->q_valid = 0; d->q_end = 0;
      return;
    }
    const int NB = SCR_H / 16;
    for (int b = 0; b < NB; b++) {
     // R509: THE MIDDLE, NOT THE LOWER HALF. The board draws bands at the top
     // AND at the bottom and misses the ones between, so the expensive bands
     // are the MIDDLE ones -- the horizon, where the road meets the sky. That
     // is where the geometry is most distant, so it is the most polygons and
     // each is small, which means MANY SHORT SPANS. R488 measured a span at
     // 8 + 2*groups cycles, so a short span is almost all fixed cost: the
     // bands that fail are the ones with the most spans and the shortest.
     // Modelling the load in the lower half instead put the cost where the
     // board does not have it.
     // R551: M2_R3D_BIG=n puts n layers of FULL-WIDTH textured quads in the
     // middle rows instead -- the close-up case (the car, the mountains),
     // where the texture is magnified (M2_R3D_MAGU: u span across the quad,
     // default 120 quarter-texels = 30 texels over 496 pixels).
     static const int BIG = std::getenv("M2_R3D_BIG") ? std::atoi(std::getenv("M2_R3D_BIG")) : 0;
     static const int MAGU = std::getenv("M2_R3D_MAGU") ? std::atoi(std::getenv("M2_R3D_MAGU")) : 120;
     const bool bigrow = BIG && (b >= NB/3 && b < 2*NB/3);
     const int reps = bigrow ? BIG : (b >= NB/3 && b < 2*NB/3) ? HEAVY : 1;
     for (int r = 0; r < reps; r++) {
      // R220: the store may be holding a finished list; wait for it.
      { int g = 0; d->q_valid = 0; d->eval(); while (!d->q_ready && g++ < 100000) tick(); }
      d->q_valid = 1;
      // R509: THE HEAVY BANDS GET NARROW QUADS, SPREAD ACROSS THE LINE.
      //
      // Replicating the same 40-pixel quad makes many LONG spans, and R488
      // says a long span amortises the fixed per-span cost almost away -- so
      // that model showed R490 worth 5% when the board's horizon is the case
      // it was built for. Distant geometry is many SMALL polygons: short
      // spans, where the 8-cycle pipeline refill is most of the cost.
      // R541: M2_R3D_OVERLAP packs the heavy quads two pixels apart, each its
      // own colour, so they overlap and the picture depends on paint ORDER.
      static const bool OVL = std::getenv("M2_R3D_OVERLAP") != nullptr;
      const int qx = bigrow ? 0 : (reps > 1) ? (OVL ? 8 + r * 2 : 8 + r * 12) : (100 + frame_no);
      const int qw = bigrow ? 495 : (reps > 1) ? 6 : 40;
      static const int QY = std::getenv("M2_R3D_QY") ? std::atoi(std::getenv("M2_R3D_QY")) : 2;
      const int qy = (reps > 1) ? QY : 2;   // R538: heavy quads' first line in the 16-line row
      d->q_x0 = qx;      d->q_y0 = b * 16 + qy;
      d->q_x1 = qx + qw; d->q_y1 = b * 16 + qy;
      // R538: M2_R3D_QH sets the heavy quads' height (default 10 lines), so
      // distant 2-3 line polygons can be modelled as well as 10-line ones.
      static const int QH = std::getenv("M2_R3D_QH") ? std::atoi(std::getenv("M2_R3D_QH")) : 10;
      const int qh = (reps > 1) ? QH : 10;
      d->q_x2 = qx + qw; d->q_y2 = b * 16 + qy + qh;
      d->q_x3 = qx;      d->q_y3 = b * 16 + qy + qh;
      d->q_col = (OVL && reps > 1) ? (0x100000u * (r & 15) + 0x001000u * (b & 15) + 0x10u * ((r >> 4) & 15)) : 0xFFFFFF;
      d->q_z = 0x3F800000; d->q_moire = 0;
      // R607: M2_R3D_ZRAND gives every quad its own depth (the store keys on
      // the low 16 bits, the reference's zval), so the picture depends on the
      // DEPTH order and not only on the tie rule -- the test that front to
      // back with a fill mask draws what the painter draws.
      static const bool ZRAND = std::getenv("M2_R3D_ZRAND") != nullptr;
      if (ZRAND) d->q_z = 0x3F800000u | ((uint32_t(r * 2654435761u + b * 40503u + frame_no * 977u) >> 7) & 0x0FFFu);
      // R291: THE TEXTURED BIT, which no test has ever set. Two builds with
      // the texture path live hung the board before the game started, and the
      // only thing they have that the working build does not is this bit.
      if (g_textured) {
        d->q_tex = 0x000001 | (2u << 1) | (2u << 4);   // 128x128, sheet 0
        // R553: M2_R3D_TEXSPREAD gives every close-up quad its own region of
        // the sheet (texx bits 18:13, texy 23:19), so the working set is many
        // textures -- far larger than the texel cache, as on the board. One
        // shared 128x128 texture fits the cache whole and never misses.
        static const bool SPREAD = std::getenv("M2_R3D_TEXSPREAD") != nullptr;
        if (SPREAD && bigrow)
          d->q_tex |= (uint32_t((r * 5 + b * 3 + frame_no * 11) & 63) << 13) | (uint32_t((r * 7 + b + frame_no * 3) & 31) << 19);   // moves every frame, as a scene does
        d->q_u0 = 0;   d->q_v0 = 0;
        d->q_u1 = bigrow ? MAGU : 400; d->q_v1 = 0;
        d->q_u2 = bigrow ? MAGU : 400; d->q_v2 = bigrow ? 40 : 200;
        d->q_u3 = 0;   d->q_v3 = bigrow ? 40 : 200;
      } else {
        d->q_tex = 0;
      }
      d->q_end = (b == NB - 1) && (r == reps - 1);
      tick();
     }
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
        if (count_pixels && t < SCR_W && d->scan_hit) {
          ++hits; if (y < BAND_H) ++top_hits;
          // R539: WHAT was painted, not only how much -- a change to WHEN
          // texels arrive must leave this identical.
          pix_hash = (pix_hash ^ (uint64_t(y) << 40 ^ uint64_t(t) << 20 ^ d->scan_col)) * 1099511628211ull;
          frame_hash = (frame_hash ^ (uint64_t(y) << 40 ^ uint64_t(t) << 20 ^ d->scan_col)) * 1099511628211ull;
          if (px_dump) std::printf("PX %d %d %04x\n", y, t, (unsigned)d->scan_col);   // R542
        }
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
    std::printf("      R536 missed scanlines last frame: %d\n", (int)d->dbg_miss_lines);
    { static uint32_t h0 = 0, m0 = 0; std::printf("      R553 texel hits %u misses %u this frame\n", d->dbg_texhit - h0, d->dbg_texmiss - m0); h0 = d->dbg_texhit; m0 = d->dbg_texmiss; }
    std::printf("      R539 pixel hash: %016llx  frame %016llx\n", (unsigned long long)pix_hash, (unsigned long long)frame_hash);
    frame_hash = 1469598103934665603ull;
    {
      long tot = 0; for (long v : fill_hist) tot += v;
      std::printf("      R539 fill states (%% of cycles):");
      for (int k = 0; k < 32; ++k) if (fill_hist[k] * 100 >= tot) std::printf(" %d:%ld%%", k, fill_hist[k] * 100 / (tot ? tot : 1));
      std::printf("  | walk busy %ld%%\n", walk_busy * 100 / (tot ? tot : 1));
      static const char *cn[8] = {"IDLE","CLR","CLRW","REPLAY","FILL","FILLW","DONE","?"};
      std::printf("      R539 band sequencer (%% of cycles):");
      for (int k = 0; k < 8; ++k) if (cst_hist[k]) std::printf(" %s:%ld%%", cn[k], cst_hist[k] * 100 / (tot ? tot : 1));
      std::printf("\n");
      std::printf("      R541 C_FILL split (%% of cycles): handoff %ld%%  fill-busy %ld%%  replaying %ld%%  band-end drain %ld%%\n",
                  why_hist[1]*100/(tot?tot:1), why_hist[2]*100/(tot?tot:1), why_hist[3]*100/(tot?tot:1), why_hist[4]*100/(tot?tot:1));
      for (long &v : why_hist) v = 0;
      std::printf("      R551 span walk busy (%% of cycles): painter-stall %ld%%  texel-wait %ld%%  no-credit %ld%%  refill %ld%%  moving %ld%%\n",
                  sw_hist[1]*100/(tot?tot:1), sw_hist[2]*100/(tot?tot:1), sw_hist[3]*100/(tot?tot:1), sw_hist[4]*100/(tot?tot:1), sw_hist[0]*0);
      for (long &v : sw_hist) v = 0;
      {
        static const char *fn[32] = {"IDLE","CLASSIFY","FLAT","START1","START2","LOADX","DIVA","DIVAW","DIVB","DIVBW",
          "DECIDE","FS_ENTER","FS_MULA","FS_MULB","FS_SWAP","FS_WALK","FS_END","FINAL","DONE","PF_D","PF_N","PF_Q1",
          "PF_Q1W","PF_Q2","PF_Q2W","PF_B","MINMAX","PF_NRM","OZ","PF_Q3","PF_Q3W","31"};
        long fwt = 0; for (long v : fw_hist) fwt += v;
        const long nq = d->dbg_fillpass ? d->dbg_fillpass : 1;
        std::printf("      R542 fill per quad handed (%ld handed last frame): %.1f cycles --", (long)d->dbg_fillpass, double(fwt) / nq);
        for (int k = 0; k < 32; ++k) if (fw_hist[k] * 50 >= fwt && fw_hist[k]) std::printf(" %s %.1f", fn[k], double(fw_hist[k]) / nq);
        std::printf("\n");
        for (long &v : fw_hist) v = 0;
      }
      for (long &v : cst_hist) v = 0;
      for (long &v : fill_hist) v = 0; walk_busy = 0;
    }
  };

  long px[8] = {0};
  // R225: the top band must be painted. The list below puts a quad in every
  // 16-row band, so band 0 has geometry and a frame that paints none of it is
  // the board's missing top bands reproduced at the desk.
  long top_px[8] = {0};
  // Frame 0: the walk delivers list A during the frame (as it does after the
  // flip); nothing is on display yet.
  // R615: M2_R3D_LIST=<dir> -- THE 3D FRAME DIFFERENTIAL. MAME's post-clip
  // polygons for one frame (polys.txt) and its texture RAM (tex0/1.bin) from
  // the instrumented MAME, turned into this rasteriser's quad interface exactly
  // as m2_geometry would present them, fed in submission order, and every
  // texel fetch of the frame that displays them written to fetch.txt.
  if (const char *lp = std::getenv("M2_R3D_LIST")) {
    const std::string dir(lp);
    for (int k = 0; k < 2; k++) {
      FILE *f = std::fopen((dir + (k ? "/tex1.bin" : "/tex0.bin")).c_str(), "rb");
      if (!f) { std::printf("  no %s\n", k ? "tex1" : "tex0"); return 1; }
      std::fseek(f, 0, SEEK_END); long n = std::ftell(f); std::fseek(f, 0, SEEK_SET);
      g_tex[k].resize(n / 4); if (std::fread(g_tex[k].data(), 4, n / 4, f) != size_t(n / 4)) return 1;
      std::fclose(f);
    }
    g_tbase1 = d->tex_base1;
    struct V { double x, y, z, pu, pv; };
    struct P { int idx; unsigned z, h0, h1, h2, h3; std::vector<V> v; };
    std::vector<P> polys;
    { FILE *f = std::fopen((dir + "/polys.txt").c_str(), "r"); char line[8192];
      while (f && std::fgets(line, sizeof line, f)) {
        P p; int win, n, vp[4]; unsigned luma; char *q = line;
        if (std::sscanf(q, "P %d z=%u win=%d h=%x,%x,%x,%x luma=%u vp=%d,%d,%d,%d n=%d",
                        &p.idx, &p.z, &win, &p.h0, &p.h1, &p.h2, &p.h3, &luma, &vp[0], &vp[1], &vp[2], &vp[3], &n) != 13) continue;
        q = std::strstr(q, " n="); q = std::strchr(q + 1, ' ');
        for (int i = 0; i < n && q; i++) { V v; if (std::sscanf(q, " %lf,%lf,%lf,%lf,%lf", &v.x, &v.y, &v.z, &v.pu, &v.pv) != 5) break; p.v.push_back(v); q = std::strchr(q + 1, ' '); }
        polys.push_back(p);
      }
      if (f) std::fclose(f); }
    std::sort(polys.begin(), polys.end(), [](const P &a, const P &b) { return a.idx < b.idx; });
    std::printf("  R615 list mode: %zu polygons from %s\n", polys.size(), lp);
    auto mf16 = [](double x) -> uint16_t { union { float f; uint32_t b; } u; u.f = (float)x; return (uint16_t)(((u.b >> 23) & 0xff) << 8 | ((u.b >> 15) & 0xff)); };
    auto wide = [](double pu) -> uint32_t { if (!(pu >= 2.0)) return 0; double w = std::floor(pu / 2.0); return w > 32767 ? 32767u : (uint32_t)w; };
    long nq = 0;
    auto push_quad = [&](const P &p, int a, int b, int c, int e, bool last) {
      const int ix[4] = {a, b, c, e};
      int32_t X[4], Y[4]; uint16_t OZ[4]; uint32_t U[4], Vv[4];
      for (int k = 0; k < 4; k++) {
        const V &v = p.v[ix[k]];
        X[k] = (int32_t)std::lround(v.x); Y[k] = (int32_t)std::lround(v.y);
        OZ[k] = mf16(1.0 / v.z); U[k] = wide(v.pu); Vv[k] = wide(v.pv);
      }
      // R609: move by a whole number of TWICE the texture's size
      const uint32_t uper = (256u << (p.h0 & 7)) - 1, vper = (256u << ((p.h0 >> 3) & 7)) - 1;
      uint32_t um = std::min(std::min(U[0], U[1]), std::min(U[2], U[3])) & ~uper & 0x7fff;
      uint32_t vm = std::min(std::min(Vv[0], Vv[1]), std::min(Vv[2], Vv[3])) & ~vper & 0x7fff;
      auto sat13 = [](uint32_t x) { return x > 8191 ? 8191u : x; };
      const uint32_t h0 = p.h0, h1 = p.h1, h2 = p.h2;
      const uint32_t tex = ((h0 >> 14) & 1) | ((h0 & 7) << 1) | (((h0 >> 3) & 7) << 4) | (((h0 >> 6) & 1) << 7)
                         | (((h0 >> 13) & 1) << 8) | (((h0 >> 8) & 1) << 9) | (((h0 >> 9) & 1) << 10) | (((h0 >> 15) & 1) << 11)
                         | (((h2 >> 12) & 1) << 12) | ((h2 & 0x3f) << 13) | (((h2 >> 6) & 0x1f) << 19);
      (void)h1;
      { int g = 0; d->q_valid = 0; d->eval(); while (!d->q_ready && g++ < 200000) tick(); }
      d->q_valid = 1;
      d->q_x0 = X[0]; d->q_y0 = Y[0]; d->q_x1 = X[1]; d->q_y1 = Y[1];
      d->q_x2 = X[2]; d->q_y2 = Y[2]; d->q_x3 = X[3]; d->q_y3 = Y[3];
      d->q_oz0 = OZ[0]; d->q_oz1 = OZ[1]; d->q_oz2 = OZ[2]; d->q_oz3 = OZ[3];
      d->q_u0 = sat13(U[0] - um); d->q_v0 = sat13(Vv[0] - vm); d->q_u1 = sat13(U[1] - um); d->q_v1 = sat13(Vv[1] - vm);
      d->q_u2 = sat13(U[2] - um); d->q_v2 = sat13(Vv[2] - vm); d->q_u3 = sat13(U[3] - um); d->q_v3 = sat13(Vv[3] - vm);
      // colour = MAME's index, in the bits that survive RGB565: idx[4:0] in R[7:3], idx[10:5] in G[7:2]
      d->q_tex = tex & 0xffffff; d->q_col = ((uint32_t(p.idx) & 31) << 19) | (((uint32_t(p.idx) >> 5) & 63) << 10); d->q_moire = 0;
      d->q_z = 0x3F800000u | (p.z & 0xffff);
      d->q_end = last;
      tick(); ++nq;
      d->q_valid = 0; d->q_end = 0;
    };
    d->frame_start = 0;
    for (size_t i = 0; i < polys.size(); i++) {
      const P &p = polys[i]; const int n = (int)p.v.size();
      if (n < 3) continue;
      const bool lastp = (i + 1 == polys.size());
      // a fan: (0,1,2,3), (0,3,4,5), ...; a triangle repeats its last vertex
      for (int k = 1; k < n - 1; k += 2) {
        const int c = k + 1, e = (k + 2 < n) ? k + 2 : k + 1;
        push_quad(p, 0, k, c, e, lastp && (k + 2 >= n - 1));
      }
    }
    std::printf("  R615: %ld quads pushed\n", nq);
    long hits = 0;
    video_frame(false, &hits);           // the list is collected, then swapped in
    g_rec = true;
    video_frame(true, &hits);            // the frame that displays it
    g_rec = false;
    FILE *fo = std::fopen((dir + "/fetch.txt").c_str(), "w");
    for (const Fetch &f : g_fetch) std::fprintf(fo, "%d %d %u %u %u %u\n", f.y, f.x, f.u, f.v, f.t, f.c);
    std::fclose(fo);
    std::printf("  R615: %zu fetches recorded, %ld pixels painted\n", g_fetch.size(), hits);
    delete d;
    return 0;
  }

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

  // R519: A LONG RUN, BECAUSE THE FAULT TAKES THREE HUNDRED FRAMES.
  //
  // Everything above is six frames. R490 draws correctly on the board for
  // three to five seconds -- two to three hundred frames -- and then the 3D
  // stops for good while the CPU, the tilemap and the video carry on. Six
  // frames cannot see that, and neither can any of the five regimes closed by
  // R513/R517/R518: stall, degenerate spans, flat/textured mixing, a
  // 20,000-span soak, both texel ports, cache sweeps. What is left is
  // DURATION, and a new list every frame rather than the same one replayed.
  //
  // M2_R3D_FRAMES sets how many; 0 skips it so the normal run stays quick.
  {
    const long NF = std::getenv("M2_R3D_FRAMES")
                  ? atol(std::getenv("M2_R3D_FRAMES")) : 0;
    if (NF > 0) {
      std::printf("  R519: soaking %ld frames\n", NF);
      long dead = 0, worst_dead = 0, last = -1;
      for (long f = 0; f < NF; f++) {
        push_list(int(2 + f));
        long hits = 0;
        px_dump = std::getenv("M2_R3D_PXDUMP") && (f == NF - 1);
        video_frame(true, &hits);
        px_dump = false;
        // THE FAULT IS A FRAME THAT PAINTS NOTHING AND NEVER RECOVERS. A frame
        // may legitimately paint little while a list is mid-flight; a RUN of
        // them is the 3D having stopped.
        if (hits == 0) { if (++dead > worst_dead) worst_dead = dead; }
        else dead = 0;
        last = hits;
      }
      CHECK(worst_dead < 8, "the 3D stopped for %ld frames and did not recover", worst_dead);
      std::printf("    last frame painted %ld, longest dead run %ld frames\n",
                  last, worst_dead);
    }
  }
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
