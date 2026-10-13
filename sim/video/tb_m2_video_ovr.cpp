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
    if (wait < 0 && req && !need_low) wait = lat + (jit ? int(rng.next() % uint32_t(jit + 1)) : 0);
    if (wait == 0) {
      const uint32_t a = addr & 0x3fffcu;
      uint64_t w = 0;
      for (int k = 0; k < 4; k++) w |= uint64_t((a + k) < chr.size() ? chr[a + k] : 0xffffu) << (16 * k);
      data = w; ack = 1; wait = -1; need_low = true;
    } else if (wait > 0) --wait;
  }
};

struct Result { long bad_glyph = 0; int frames = 0, cmp = 0, bad_frames = 0; long bad_px = 0; long r_ovr = 0, d_ovr = 0; int r_ovr_fr = 0, d_ovr_fr = 0, r_max = 0, d_max = 0; };

enum Scene { SKY, RAND, DUMP };

static Result run(Scene sc, int frames, int lat, int jit, bool il, uint64_t seed, int rlat,
                  const std::vector<std::vector<uint16_t>> *dump_tiles, const std::vector<uint16_t> *dump_chr) {
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
  d->rst_n = 0; d->ce_pix = 0; d->interlace = il; d->r_m_ack = 0; d->d_m_ack = 0;
  uint16_t rq = 0, dq = 0;
  unsigned ce_acc = 0;
  int frame = -1;
  make_frame(0);
  Result res;
  long fbad = 0; uint16_t r0 = 0, d0 = 0;
  const uint64_t LIMIT = uint64_t(frames + 3) * 4100ull * 424ull;
  for (uint64_t cyc = 0; cyc < LIMIT; ++cyc) {
    if (ce_acc + 16 >= 100) { ce_acc = ce_acc + 16 - 100; d->ce_pix = 1; } else { ce_acc += 16; d->ce_pix = 0; }
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
    if (d->ce_pix && d->vcnt < vv && d->hcnt < 496 && frame >= 1)
      if (d->r_pal != d->d_pal) {
        if (std::getenv("OVR_DEBUG") && fbad < 8)
          std::printf("    differ: frame %d y %d x %d  r %03x d %03x\n", frame, int(d->vcnt), int(d->hcnt), d->r_pal, d->d_pal);
        ++fbad;
      }
    if (d->vblank_start) {
      if (frame >= 1) {
        const int ro = d->r_ovr - r0, dov = d->d_ovr - d0;
        res.frames++; res.r_ovr += ro; res.d_ovr += dov;
        res.r_ovr_fr += ro > 0; res.d_ovr_fr += dov > 0;
        res.r_max = std::max(res.r_max, ro); res.d_max = std::max(res.d_max, dov);
        if (ro == 0 && dov == 0) { res.cmp++; if (fbad) { res.bad_frames++; res.bad_px += fbad; } }
      }
      r0 = d->r_ovr; d0 = d->d_ovr; fbad = 0;
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
  for (int i = 1; i < argc; i++) {
    if (!std::strncmp(argv[i], "+frames=", 8)) frames = std::atoi(argv[i] + 8);
    if (!std::strncmp(argv[i], "+burst=", 7))  burst = argv[i] + 7;
  }
  int fails = 0;
  auto show = [&fails](const char *name, const Result &r) -> bool {
    std::printf("  %-28s frames %2d  ovr/frame r %6.2f d %6.2f  frames with ovr r %2d d %2d  worst r %3d d %3d  compared %2d mismatched %d (%ld px) bad glyphs %ld\n",
                name, r.frames, r.frames ? double(r.r_ovr) / r.frames : 0.0, r.frames ? double(r.d_ovr) / r.frames : 0.0,
                r.r_ovr_fr, r.d_ovr_fr, r.r_max, r.d_max, r.cmp, r.bad_frames, r.bad_px, r.bad_glyph);
    if (r.bad_glyph) { std::printf("  FAIL %s: a glyph cache answered with the wrong word\n", name); fails++; }
    return r.bad_glyph == 0;
  };

  std::printf("test: equivalence -- every visible pixel, frames where neither path overran\n");
  struct Eq { const char *name; Scene sc; int lat, jit; bool il; uint64_t seed; } eq[] = {
    {"sky lat 0",              SKY,  0,  0, false, 1},
    {"rand lat 0 seed 1",      RAND, 0,  0, false, 1},
    {"rand lat 0 seed 2",      RAND, 0,  0, false, 2},
    {"rand lat 14+0..30",      RAND, 14, 30, false, 3},
    {"sky interlaced lat 0",   SKY,  0,  0, true,  4},
    {"rand interlaced lat 0",  RAND, 0,  0, true,  5},
  };
  const char *only = std::getenv("OVR_ONLY");
  for (const auto &e : eq) {
    if (only && std::strcmp(only, e.name)) continue;
    Result r = run(e.sc, frames, e.lat, e.jit, e.il, e.seed, -1, nullptr, nullptr);
    show(e.name, r);
    if (r.bad_frames) { std::printf("  FAIL %s: %d frames differ\n", e.name, r.bad_frames); fails++; }
    if (e.lat == 0 && r.cmp == 0) { std::printf("  FAIL %s: nothing compared\n", e.name); fails++; }
  }

  // The variant at a latency where the shipped path overruns must draw the
  // picture the shipped path draws with no latency at all -- the whole claim.
  std::printf("test: the variant at 30 cycles against the shipped path at 0\n");
  {
    Result r = run(SKY, frames, 30, 0, false, 9, 0, nullptr, nullptr);
    show("sky d@30 vs r@0", r);
    if (r.bad_frames) { std::printf("  FAIL: %d frames differ\n", r.bad_frames); fails++; }
    std::printf("  (compared %d of %d frames: those where the variant did not overrun)\n", r.cmp, r.frames);
  }

  std::printf("test: effect -- the sky scene across port-3 latency (clk_mem cycles)\n");
  int r30 = 0, d30 = -1;
  for (int lat : {0, 12, 20, 30, 45, 60, 90}) {
    char nm[64]; std::snprintf(nm, sizeof nm, "sky lat %d", lat);
    Result r = run(SKY, frames, lat, 0, false, 9, -1, nullptr, nullptr);
    show(nm, r);
    if (r.bad_frames) { std::printf("  FAIL %s: %d frames differ\n", nm, r.bad_frames); fails++; }
    if (lat == 30) { r30 = int(r.r_ovr); d30 = int(r.d_ovr); }
  }
  // The scene must actually overrun the shipped path, or it tests nothing.
  if (r30 == 0) { std::printf("  FAIL: the shipped path did not overrun the sky scene at 30 -- the scene is too light\n"); fails++; }
  std::printf("  at 30 cycles: shipped %d overruns, variant %d\n", r30, d30);

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
    else {
      std::printf("dumps: %s, %zu frames\n", burst.c_str(), fd.size());
      for (int lat : {0, 20, 30, 45, 60}) {
        char nm[64]; std::snprintf(nm, sizeof nm, "dump lat %d", lat);
        Result r = run(DUMP, int(fd.size()), lat, 0, false, 11, -1, &tiles, &chr);
        show(nm, r);
        if (r.bad_frames) { std::printf("  FAIL %s: %d frames differ\n", nm, r.bad_frames); fails++; }
      }
      for (int lat : {30, 45}) {
        char nm[64]; std::snprintf(nm, sizeof nm, "dump d@%d vs r@0", lat);
        Result r = run(DUMP, int(fd.size()), lat, 0, false, 11, 0, &tiles, &chr);
        show(nm, r);
        if (r.bad_frames) { std::printf("  FAIL %s: %d frames differ\n", nm, r.bad_frames); fails++; }
      }
    }
  }
  std::printf("%s (%d failures)\n", fails ? "FAIL" : "PASS", fails);
  return fails ? 1 : 0;
}
