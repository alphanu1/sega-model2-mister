// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R823: TILE OVERRUNS -- the shipped tilemap path against a variant, side by
// side, through whole frames with the glyph cache and a port-3 latency model.
//
// Two questions, both answered every run:
//   1. EQUIVALENCE. In every frame where neither path overran, every visible
//      pixel's palette index must be the same. LB_RING changes WHEN lines are
//      rendered and SIBLING only when glyphs are fetched -- never what is drawn.
//   2. EFFECT. Overruns per frame for each path, at each port-3 latency.
//
// Scenes. No ROM is needed for the pass/fail part:
//   sky   tilemap 2 is a full-screen picture of 4,096 DISTINCT tiles (128 KB of
//         glyphs against a 64 KB cache), scrolling one line a frame; the other
//         three are text-like (a few repeated tiles). This is the shape that
//         overruns on the board: R823 found Daytona's sky / title layer doing
//         exactly this.
//   rand  every tile RAM word random, every frame (scroll, window and row-mask
//         words included), so the window and split paths are exercised.
//   +burst=<dir>  frames dumped from MAME by sim/video/mame_m2_ovrdump.lua
//         (dir/fNNNNN/tile.bin, char.bin in the first); optional, reported only.
//
// Latency is in clk_mem cycles from the cache raising m_req to the
// acknowledge, plus uniform jitter; one transaction at a time and the request
// must drop between them, as m2_sdram's port does.
//
// R824: every scene runs in all three video modes, with the pixel enable
// Model2.sv makes for each: native (16/100 of clk_mem, 4,100 cycles a line),
// 15 kHz interlaced with 273.5-line fields (547/5300, ~6,356 a line) and with
// 262.5-line fields (861/8692, ~6,622 a line). A "frame" in the counts is a
// FIELD when interlaced. Also reported:
//   vis        overrun-counter steps that landed on a visible line (the
//              two-bank counter also counts blanking lines; the ring's does not)
//   difflines  visible lines on which the two paths differ in any pixel. With
//              the shipped path at latency 0 as the reference (r@0), this is
//              the number of WRONG LINES ON THE SCREEN, whichever counter is
//              right -- the two-bank swap shows two wrong lines per overrun
//              (the repeat, then the late line one line low).
//   +sweep     with +burst: the dump matrix, machine-readable SWEEP lines.
//   +quick     skip the synthetic latency sweeps.
// And a mode change mid-frame (the OSD), in every direction: both paths must
// be back -- no overruns, every pixel equal -- from the second frame after.

#include "Vm2_video_ovr_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <algorithm>
#include <dirent.h>

static bool load_u16(const std::string &path, std::vector<uint16_t> &out) {
  FILE *f = std::fopen(path.c_str(), "rb");
  if (!f) return false;
  std::fseek(f, 0, SEEK_END); long n = std::ftell(f); std::fseek(f, 0, SEEK_SET);
  std::vector<uint8_t> b(size_t(n), 0);
  const size_t got = std::fread(b.data(), 1, size_t(n), f); std::fclose(f);
  if (got != size_t(n)) return false;
  out.resize(b.size() / 2);
  for (size_t i = 0; i < out.size(); ++i) out[i] = uint16_t(b[i*2] | (uint16_t(b[i*2+1]) << 8));
  return true;
}

struct Rng { uint64_t s; uint32_t next() { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return uint32_t(s >> 11); } };

// Port 3, one per path.
struct Port {
  int wait = -1; bool need_low = false; Rng rng{0};
  int lat = 0, jit = 0;
  void step(uint8_t req, uint32_t addr, uint8_t &ack, uint64_t &data, const std::vector<uint16_t> &chr) {
    ack = 0;
    if (!req) need_low = false;
    // jit < 0: R823's queue model -- 14 + U[0,6], plus U[0,80] with p = 0.6
    // (mean 41), a port that is usually quick and sometimes waits a long time
    if (wait < 0 && req && !need_low) {
      if (jit < 0) { wait = 14 + int(rng.next() % 7u); if (rng.next() % 10u < 6u) wait += int(rng.next() % 81u); }
      else wait = lat + (jit ? int(rng.next() % uint32_t(jit + 1)) : 0);
    }
    if (wait == 0) {
      const uint32_t a = addr & 0x3fffcu;
      uint64_t w = 0;
      for (int k = 0; k < 4; k++) w |= uint64_t((a + k) < chr.size() ? chr[a + k] : 0xffffu) << (16 * k);
      data = w; ack = 1; wait = -1; need_low = true;
    } else if (wait > 0) --wait;
  }
};

struct Result {
  long bad_glyph = 0; int frames = 0, cmp = 0, bad_frames = 0; long bad_px = 0;
  long r_ovr = 0, d_ovr = 0; int r_ovr_fr = 0, d_ovr_fr = 0, r_max = 0, d_max = 0;
  // R824: the counters' increments that land on a VISIBLE line (the line the
  // stale buffer is shown on), and visible lines on which any pixel of the two
  // paths differs -- with the shipped path at latency 0 as the reference, the
  // number of wrong lines on the screen, whatever either counter says.
  long r_vis = 0, d_vis = 0, diff_lines = 0; int d_vis_max = 0, d_vis_fr = 0;
  // per measured frame (field when interlaced): d visible overruns, mismatched
  // px in a compared frame, differing lines -- for the mode-switch test
  std::vector<int> f_dvis, f_rvis, f_bad, f_diff;
};

// R824: the pixel enable per video mode, as Model2.sv makes it on clk_mem:
// 0 native (16/100), 1 15 kHz interlaced 273.5-line fields (547/5300, R682),
// 2 15 kHz interlaced 262.5-line fields (861/8692, R783).
static const unsigned CE_NUM[3] = {16, 547, 861};
static const unsigned CE_DEN[3] = {100, 5300, 8692};

enum Scene { SKY, RAND, DUMP };

// mode: 0 native, 1 / 2 interlaced (CE_NUM). sw_frame >= 0: at line sw_line,
// pixel 300 of that measured frame the mode becomes sw_mode (an OSD change).
static Result run(Scene sc, int frames, int lat, int jit, int mode, uint64_t seed, int rlat,
                  const std::vector<std::vector<uint16_t>> *dump_tiles, const std::vector<uint16_t> *dump_chr,
                  int sw_frame = -1, int sw_mode = 0, int sw_line = 100) {
  Vm2_video_ovr_top *d = new Vm2_video_ovr_top;
  std::vector<uint16_t> tram(0x8000, 0), chr;
  Rng rng{seed * 0x9E3779B97F4A7C15ull + 1};
  if (sc == DUMP) chr = *dump_chr;
  else {
    chr.resize(0x40000);
    for (size_t i = 0; i < chr.size(); i++) chr[i] = uint16_t((i * 2654435761u) >> 13) ^ uint16_t(seed);
  }
  auto make_frame = [&](int f) {
    if (sc == DUMP) {
      const auto &t = (*dump_tiles)[size_t(std::min<int>(std::max(f, 0), int(dump_tiles->size()) - 1))];
      std::fill(tram.begin(), tram.end(), 0);
      std::copy(t.begin(), t.begin() + std::min(t.size(), tram.size()), tram.begin());
    } else if (sc == RAND) {
      for (auto &w : tram) w = uint16_t(rng.next());
      // The row-mask tables are random but FIXED for the run, and word 3 of
      // every line of the 0x6800 table is one value. m2_video's Q_HSCR_W reads
      // the word addressed in Q_HSCR, which is the sequencer's PREVIOUS address
      // -- the last row-mask word of the layer before (R823's side finding: the
      // tile RAM registers its address, so hscr has no wait state where every
      // other sequencer read has one). For tilemap 0 that is the previous
      // RENDERED line's 0x6800 + 4*line + 3, and the ring renders a different
      // previous line at a frame's start than the swap does. Holding that word
      // constant keeps the comparison about the ring; the fault itself is
      // reported, not fixed, here.
      { Rng mr{seed * 31 + 7}; const uint16_t w3 = uint16_t(mr.next());
        for (int i = 0x6000; i < 0x7000; i++) tram[size_t(i)] = uint16_t(mr.next());
        for (int i = 0x6800; i < 0x7000; i += 4) tram[size_t(i + 3)] = w3; }
    } else {
      // tilemaps 0, 1, 3: text-like, eight glyphs repeated; tilemap 2: a picture
      for (int L = 0; L < 4; L++)
        for (int i = 0; i < 0x1000; i++)
          tram[size_t(L) * 0x1000 + size_t(i)] = (L == 2) ? uint16_t(0x0000 | i)
                                                          : uint16_t(0x2000 + L * 8 + (i % 8));
      for (int i = 0x4000; i < 0x8000; i++) tram[size_t(i)] = 0;   // H tables, scroll, masks
      tram[0x5000] = 0; tram[0x5001] = 0; tram[0x5002] = uint16_t(f * 3); tram[0x5003] = 0;
      tram[0x5004] = 0; tram[0x5005] = 0; tram[0x5006] = uint16_t(f & 0x1ff); tram[0x5007] = 0;
    }
  };
  Port pr, pd; pr.lat = pd.lat = lat; pr.jit = pd.jit = jit;
  if (rlat >= 0) { pr.lat = rlat; pr.jit = 0; }   // the shipped path at its own latency
  pr.rng.s = seed * 7 + 3; pd.rng.s = seed * 7 + 3;     // same draws while both ask alike
  bool il = mode != 0;
  d->rst_n = 0; d->ce_pix = 0; d->interlace = il; d->ntsc_lines = mode == 2; d->r_m_ack = 0; d->d_m_ack = 0;
  uint16_t rq = 0, dq = 0;
  unsigned ce_acc = 0;
  int frame = -1;
  make_frame(0);
  Result res;
  long fbad = 0; uint16_t r0 = 0, d0 = 0;
  uint16_t rpo = 0, dpo = 0;                 // counters at the previous sample
  long fr_rvis = 0, fr_dvis = 0, fr_diff = 0; bool ldiff = false; int lvc = -1;
  // a runaway frame after a mode change can be ~1024 lines: allow for it
  const uint64_t LIMIT = uint64_t(frames + 3 + (sw_frame >= 0 ? 6 : 0)) * 4100ull * 424ull;
  for (uint64_t cyc = 0; cyc < LIMIT; ++cyc) {
    const unsigned cn = CE_NUM[mode], cdn = CE_DEN[mode];
    if (ce_acc >= cdn) { ce_acc = 0; d->ce_pix = 0; }   // a mode change: start clean (Model2.sv)
    else if (ce_acc + cn >= cdn) { ce_acc = ce_acc + cn - cdn; d->ce_pix = 1; } else { ce_acc += cn; d->ce_pix = 0; }
    d->r_tram_data = rq; d->d_tram_data = dq;
    uint8_t a; uint64_t w = 0;
    pr.step(d->r_m_req, d->r_m_addr, a, w, chr); d->r_m_ack = a; if (a) d->r_m_data = w;
    pd.step(d->d_m_req, d->d_m_addr, a, w, chr); d->d_m_ack = a; if (a) d->d_m_data = w;
    d->clk = 0; d->eval();
    // pre-edge observation: this cycle's registered state
    auto gl = [&](uint32_t a) { a &= 0x3ffffu; return uint32_t(a < chr.size() ? chr[a] : 0xffffu)
                                   | (uint32_t(a + 1 < chr.size() ? chr[a + 1] : 0xffffu) << 16); };
    if (d->r_vack && d->r_vdata != gl(d->r_vaddr)) {
      if (std::getenv("OVR_DEBUG") && res.bad_glyph < 8) std::printf("    r glyph wrong: frame %d addr %05x got %08x want %08x\n", frame, d->r_vaddr, d->r_vdata, gl(d->r_vaddr));
      res.bad_glyph++;
    }
    if (d->d_vack && d->d_vdata != gl(d->d_vaddr)) {
      if (std::getenv("OVR_DEBUG") && res.bad_glyph < 8) std::printf("    d glyph wrong: frame %d addr %05x got %08x want %08x\n", frame, d->d_vaddr, d->d_vdata, gl(d->d_vaddr));
      res.bad_glyph++;
    }
    const int vv = il ? 192 : 384;
    // an overrun counter that moved at the last edge: vcnt moved with it, so
    // it names the line now shown from the stale buffer
    if (d->r_ovr != rpo && d->vcnt < vv) fr_rvis += uint16_t(d->r_ovr - rpo);
    if (d->d_ovr != dpo && d->vcnt < vv) fr_dvis += uint16_t(d->d_ovr - dpo);
    rpo = d->r_ovr; dpo = d->d_ovr;
    if (int(d->vcnt) != lvc) { fr_diff += ldiff; ldiff = false; lvc = int(d->vcnt); }
    if (d->ce_pix && d->vcnt < vv && d->hcnt < 496 && frame >= 1)
      if (d->r_pal != d->d_pal) {
        if (std::getenv("OVR_DEBUG") && fbad < 8)
          std::printf("    differ: frame %d y %d x %d  r %03x d %03x\n", frame, int(d->vcnt), int(d->hcnt), d->r_pal, d->d_pal);
        ++fbad; ldiff = true;
      }
    if (sw_frame >= 0 && frame == sw_frame && d->vcnt == sw_line && d->hcnt == 300 && d->ce_pix) {
      mode = sw_mode; il = mode != 0;
      d->interlace = il; d->ntsc_lines = mode == 2;
    }
    if (d->vblank_start) {
      fr_diff += ldiff; ldiff = false;     // the last visible line
      if (frame >= 1) {
        const int ro = d->r_ovr - r0, dov = d->d_ovr - d0;
        res.frames++; res.r_ovr += ro; res.d_ovr += dov;
        res.r_ovr_fr += ro > 0; res.d_ovr_fr += dov > 0;
        res.r_max = std::max(res.r_max, ro); res.d_max = std::max(res.d_max, dov);
        if (ro == 0 && dov == 0) { res.cmp++; if (fbad) { res.bad_frames++; res.bad_px += fbad; } }
        res.r_vis += fr_rvis; res.d_vis += fr_dvis; res.diff_lines += fr_diff;
        res.d_vis_max = std::max<int>(res.d_vis_max, int(fr_dvis)); res.d_vis_fr += fr_dvis > 0;
        res.f_dvis.push_back(int(fr_dvis)); res.f_rvis.push_back(int(fr_rvis));
        res.f_bad.push_back((ro == 0 && dov == 0) ? int(fbad) : -1); res.f_diff.push_back(int(fr_diff));
      }
      r0 = d->r_ovr; d0 = d->d_ovr; fbad = 0; fr_rvis = fr_dvis = fr_diff = 0; ldiff = false;
      frame++;
      if (frame > frames) break;
      make_frame(frame);
    }
    const uint32_t ra = d->r_tram_addr, da = d->d_tram_addr;
    d->clk = 1; d->eval();
    if (cyc == 64) d->rst_n = 1;
    rq = tram[ra & 0x7fff]; dq = tram[da & 0x7fff];
  }
  delete d;
  return res;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  int frames = 6;
  std::string burst;
  bool sweep = false, sweep2 = false, quick = false;
  for (int i = 1; i < argc; i++) {
    if (!std::strncmp(argv[i], "+frames=", 8)) frames = std::atoi(argv[i] + 8);
    if (!std::strncmp(argv[i], "+burst=", 7))  burst = argv[i] + 7;
    if (!std::strcmp(argv[i], "+sweep"))       sweep = true;   // R824: the dump matrix only
    if (!std::strcmp(argv[i], "+sweep2"))      { sweep = true; sweep2 = true; }   // ... its heavier latency models
    if (!std::strcmp(argv[i], "+quick"))       quick = true;   // skip the synthetic sweeps
  }
  int fails = 0;
  auto show = [&fails](const char *name, const Result &r) -> bool {
    std::printf("  %-30s frames %2d  ovr/frame r %6.2f d %6.2f  frames with ovr r %2d d %2d  worst r %3d d %3d  vis r %5ld d %5ld  difflines %5ld  compared %2d mismatched %d (%ld px) bad glyphs %ld\n",
                name, r.frames, r.frames ? double(r.r_ovr) / r.frames : 0.0, r.frames ? double(r.d_ovr) / r.frames : 0.0,
                r.r_ovr_fr, r.d_ovr_fr, r.r_max, r.d_max, r.r_vis, r.d_vis, r.diff_lines, r.cmp, r.bad_frames, r.bad_px, r.bad_glyph);
    if (r.bad_glyph) { std::printf("  FAIL %s: a glyph cache answered with the wrong word\n", name); fails++; }
    return r.bad_glyph == 0;
  };
  static const char *MN[3] = {"", " i273", " i262"};

  if (!sweep) {
  std::printf("test: equivalence -- every visible pixel, frames where neither path overran\n");
  struct Eq { const char *name; Scene sc; int lat, jit; int mode; uint64_t seed; } eq[] = {
    {"sky lat 0",              SKY,  0,  0, 0, 1},
    {"rand lat 0 seed 1",      RAND, 0,  0, 0, 1},
    {"rand lat 0 seed 2",      RAND, 0,  0, 0, 2},
    {"rand lat 14+0..30",      RAND, 14, 30, 0, 3},
    {"sky interlaced lat 0",   SKY,  0,  0, 1,  4},
    {"rand interlaced lat 0",  RAND, 0,  0, 1,  5},
    // R824: both 15 kHz line counts, and with latency
    {"sky i262 lat 0",         SKY,  0,  0, 2,  6},
    {"rand i262 lat 0",        RAND, 0,  0, 2,  7},
    {"rand i273 lat 14+0..30", RAND, 14, 30, 1, 8},
    {"rand i262 lat 14+0..30", RAND, 14, 30, 2, 10},
  };
  const char *only = std::getenv("OVR_ONLY");
  for (const auto &e : eq) {
    if (only && std::strcmp(only, e.name)) continue;
    Result r = run(e.sc, frames, e.lat, e.jit, e.mode, e.seed, -1, nullptr, nullptr);
    show(e.name, r);
    if (r.bad_frames) { std::printf("  FAIL %s: %d frames differ\n", e.name, r.bad_frames); fails++; }
    if (e.lat == 0 && r.cmp == 0) { std::printf("  FAIL %s: nothing compared\n", e.name); fails++; }
  }

  // The variant at a latency where the shipped path overruns must draw the
  // picture the shipped path draws with no latency at all -- the whole claim.
  std::printf("test: the variant at 30 cycles against the shipped path at 0\n");
  for (int mode = 0; mode < 3; mode++) {
    char nm[64]; std::snprintf(nm, sizeof nm, "sky%s d@30 vs r@0", MN[mode]);
    Result r = run(SKY, frames, 30, 0, mode, 9, 0, nullptr, nullptr);
    show(nm, r);
    if (r.bad_frames) { std::printf("  FAIL: %d frames differ\n", r.bad_frames); fails++; }
    std::printf("  (compared %d of %d frames: those where the variant did not overrun)\n", r.cmp, r.frames);
  }

  // R824: an OSD change mid-frame -- native to each interlaced mode, back, and
  // between the two line counts -- at latency 0, where neither path overruns
  // in steady state. From the second whole frame after the change both paths
  // must be back: no overruns and every pixel equal. (The frame the change
  // lands in can run to ~1,024 lines: the timing generator's vcnt passes the
  // new, shorter total and wraps at 10 bits -- older than the ring, and the
  // monitor resyncs either way.)
  std::printf("test: a video mode change mid-frame recovers\n");
  {
    // line: where the change lands. Past the new mode's total (300 into a
    // 274-line field, 268 into a 263-line one) the timing generator runs vcnt
    // on to 1,023 and wraps WITHOUT toggling the field -- two fields of one
    // parity, which the ring must ride out.
    struct Sw { int from, to; Scene sc; int lat, jit, line; } sw[] = {
      {0, 1, SKY, 0, 0, 100}, {1, 0, SKY, 0, 0, 100}, {0, 2, SKY, 0, 0, 100}, {2, 0, SKY, 0, 0, 100},
      {1, 2, SKY, 0, 0, 100}, {2, 1, SKY, 0, 0, 100}, {1, 2, RAND, 0, 0, 100}, {0, 1, RAND, 0, 0, 100},
      {2, 0, SKY, 14, 30, 100}, {0, 2, SKY, 14, 30, 100},
      {0, 1, SKY, 0, 0, 300}, {0, 2, SKY, 0, 0, 380}, {1, 2, SKY, 0, 0, 268}, {1, 2, SKY, 14, 30, 268},
    };
    for (const auto &w : sw) {
      char nm[64]; std::snprintf(nm, sizeof nm, "%s %d->%d @%d lat %d+%d", w.sc == SKY ? "sky" : "rand", w.from, w.to, w.line, w.lat, w.jit);
      Result r = run(w.sc, 8, w.lat, w.jit, w.from, 21, w.lat ? 0 : -1, nullptr, nullptr, 3, w.to, w.line);
      show(nm, r);
      std::printf("    per frame d vis ovr:"); for (int v : r.f_dvis) std::printf(" %d", v);
      std::printf("  mismatched px (-1 not compared):"); for (int v : r.f_bad) std::printf(" %d", v);
      std::printf("  difflines:"); for (int v : r.f_diff) std::printf(" %d", v); std::printf("\n");
      // measured frame k is index k-1; the switch lands in frame 3 (index 2)
      for (size_t k = 4; k < r.f_dvis.size(); k++) {
        if (w.lat == 0 && (r.f_dvis[k] || r.f_rvis[k] || r.f_bad[k] != 0)) {
          std::printf("  FAIL %s: frame %zu after the change: d ovr %d r ovr %d mismatched %d\n", nm, k + 1, r.f_dvis[k], r.f_rvis[k], r.f_bad[k]);
          fails++;
        }
        if (w.lat != 0 && r.f_bad[k] > 0) {
          std::printf("  FAIL %s: frame %zu after the change: %d px differ from r@0\n", nm, k + 1, r.f_bad[k]); fails++;
        }
      }
      if (r.bad_frames && w.lat == 0) {
        // frames before the change must match too
        for (size_t k = 0; k < 2 && k < r.f_bad.size(); k++)
          if (r.f_bad[k] > 0) { std::printf("  FAIL %s: frame %zu before the change differs\n", nm, k + 1); fails++; }
      }
    }
  }

  if (!quick) {
  std::printf("test: effect -- the sky scene across port-3 latency (clk_mem cycles)\n");
  int r30 = 0, d30 = -1;
  for (int lat : {0, 12, 20, 30, 45, 60, 90}) {
    char nm[64]; std::snprintf(nm, sizeof nm, "sky lat %d", lat);
    Result r = run(SKY, frames, lat, 0, 0, 9, -1, nullptr, nullptr);
    show(nm, r);
    if (r.bad_frames) { std::printf("  FAIL %s: %d frames differ\n", nm, r.bad_frames); fails++; }
    if (lat == 30) { r30 = int(r.r_ovr); d30 = int(r.d_ovr); }
  }
  // The scene must actually overrun the shipped path, or it tests nothing.
  if (r30 == 0) { std::printf("  FAIL: the shipped path did not overrun the sky scene at 30 -- the scene is too light\n"); fails++; }
  std::printf("  at 30 cycles: shipped %d overruns, variant %d\n", r30, d30);
  // R824: the same in both 15 kHz modes, the variant against r@0 (difflines
  // is then the number of wrong lines on the screen)
  for (int mode = 1; mode < 3; mode++)
    for (int lat : {30, 45, 60, 90}) {
      char nm[64]; std::snprintf(nm, sizeof nm, "sky%s lat %d (r@%d)", MN[mode], lat, lat);
      Result r = run(SKY, frames, lat, 0, mode, 9, -1, nullptr, nullptr);
      show(nm, r);
      if (r.bad_frames) { std::printf("  FAIL %s: %d frames differ\n", nm, r.bad_frames); fails++; }
      std::snprintf(nm, sizeof nm, "sky%s d@%d vs r@0", MN[mode], lat);
      r = run(SKY, frames, lat, 0, mode, 9, 0, nullptr, nullptr);
      show(nm, r);
      if (r.bad_frames) { std::printf("  FAIL %s: %d frames differ\n", nm, r.bad_frames); fails++; }
    }
  }
  }

  if (!burst.empty()) {
    std::vector<std::string> fd;
    if (DIR *dp = opendir(burst.c_str())) {
      while (dirent *e = readdir(dp)) if (e->d_name[0] == 'f') fd.push_back(burst + "/" + e->d_name);
      closedir(dp);
    }
    std::sort(fd.begin(), fd.end());
    std::vector<std::vector<uint16_t>> tiles(fd.size());
    std::vector<uint16_t> chr;
    bool ok = !fd.empty() && load_u16(fd[0] + "/char.bin", chr);
    for (size_t i = 0; ok && i < fd.size(); i++) ok = load_u16(fd[i] + "/tile.bin", tiles[i]);
    if (!ok) std::printf("dumps: none usable under %s (SKIP)\n", burst.c_str());
    else if (sweep) {
      // R824: machine-readable. Every run is the variant at the latency
      // against the shipped path at 0, so difflines counts wrong lines; the
      // shipped path at the same latency is a separate run (r@L).
      std::printf("dumps: %s, %zu frames\n", burst.c_str(), fd.size());
      struct L { int lat, jit; };
      const std::vector<L> ls = sweep2 ? std::vector<L>{{14,50},{-1,-1},{30,30},{45,30}}
                                       : std::vector<L>{{0,0},{14,30},{20,0},{30,0},{45,0},{60,0},{90,0}};
      for (int mode = 0; mode < 3; mode++)
        for (const auto &l : ls) {
          Result r = run(DUMP, int(fd.size()), l.lat, l.jit, mode, 11, 0, &tiles, &chr);
          Result q = run(DUMP, int(fd.size()), l.lat, l.jit, mode, 11, -1, &tiles, &chr);
          std::printf("SWEEP mode %d lat %d jit %d frames %d d_vis %ld d_vis_fr %d d_vis_max %d d_cnt %ld difflines %ld r0_vis %ld cmp %d badfr %d badglyph %ld rL_vis %ld rL_cnt %ld rL_fr %d rL_max %d\n",
                      mode, l.lat, l.jit, r.frames, r.d_vis, r.d_vis_fr, r.d_vis_max, r.d_ovr, r.diff_lines, r.r_vis, r.cmp, r.bad_frames, r.bad_glyph + q.bad_glyph,
                      q.r_vis, q.r_ovr, q.r_ovr_fr, q.r_max);
          // r@0 is the reference. r@L is not: its counter misses a
          // line_start landing in a layer's setup states (R823), so a frame it
          // calls clean can still hold a late line -- reported, not failed.
          if (r.bad_frames || r.bad_glyph || q.bad_glyph) {
            std::printf("  FAIL mode %d lat %d: %d frames differ from r@0, glyphs %ld\n", mode, l.lat, r.bad_frames, r.bad_glyph + q.bad_glyph); fails++;
          }
          if (q.bad_frames)
            std::printf("  note mode %d lat %d: %d frames differ at r@L with no overrun counted (the swap counter's blind spot)\n", mode, l.lat, q.bad_frames);
        }
    } else {
      std::printf("dumps: %s, %zu frames\n", burst.c_str(), fd.size());
      for (int lat : {0, 20, 30, 45, 60}) {
        char nm[64]; std::snprintf(nm, sizeof nm, "dump lat %d", lat);
        Result r = run(DUMP, int(fd.size()), lat, 0, 0, 11, -1, &tiles, &chr);
        show(nm, r);
        if (r.bad_frames) { std::printf("  FAIL %s: %d frames differ\n", nm, r.bad_frames); fails++; }
      }
      for (int lat : {30, 45}) {
        char nm[64]; std::snprintf(nm, sizeof nm, "dump d@%d vs r@0", lat);
        Result r = run(DUMP, int(fd.size()), lat, 0, 0, 11, 0, &tiles, &chr);
        show(nm, r);
        if (r.bad_frames) { std::printf("  FAIL %s: %d frames differ\n", nm, r.bad_frames); fails++; }
      }
    }
  }
  std::printf("%s (%d failures)\n", fails ? "FAIL" : "PASS", fails);
  return fails ? 1 : 0;
}
