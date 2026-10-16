// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R826: THE 2D HELD TO ITS 3D, and hscr read from its own word -- through
// m2_video_ovr_top: `r` is the shipped m2_video, `d` the variant (HSF / SSY).
// Pixel-for-pixel, every visible pixel of every frame after the first.
//
// Built twice (make test_m2_video_r826):
//   HSF=1  d has HSCR_FIX.
//     hscr-eq    window mode on both pairs (Daytona's race): hscr_r is not
//                used there, so d must equal r exactly.
//     hscr-trap  plain mode, and the row-mask word r reads by mistake (the
//                last mask word of the layer before) set to the value each
//                0x5000 + L holds: r's wrong read and d's right read then give
//                the same scroll, so d must equal r -- d reads 0x5000 + L,
//                because r never does.
//     hscr-disc  the same with 0x5000 + L changed: d must DIFFER from r (the
//                trap can tell the two reads apart).
//   SSY=1  d has SCR_SYNC (and therefore HSCR_FIX; window mode only, so that
//          is invisible). The bench plays a game: iterations of 1-3 frames,
//          each writing its eight scroll words at line 386 of the vblank it
//          starts in and flipping its list at line 150 of its last frame; a
//          3D pipeline publishing list k at a vblank (scr_tag = k). d gets
//          tile RAM as the game writes it; r gets the words the gate SHOULD
//          show -- the game's iteration j only once list j - 2 is on screen
//          (and tile RAM as written when the 3D is three or more lists
//          behind). d must equal r.
//     sync-none  no flips, tag fixed: the gate never engages, d == r on the
//                same image.
//     sync-play  the game above: d == r(intended).
//     sync-60    a list every frame (the 3D one frame later than the game
//                assumes): every frame must come out aligned.
//     sync-disc  sync-60's game, r on tile RAM as written: d must differ
//                (the gate does something).
//     sync-stall the 3D stops publishing: from three lists behind, d shows
//                tile RAM as written (r on it, equal).
// Reported for sync-play: frames on which the 2D shown is the one the game
// wrote for the 3D shown (iteration = list + 2), gated and ungated.

#include "Vm2_video_ovr_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <algorithm>
#include <cmath>

#ifndef SSY_BUILD
#define SSY_BUILD 0
#endif

struct Rng { uint64_t s; uint32_t next() { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return uint32_t(s >> 11); } };

struct Port {
  int wait = -1; bool need_low = false;
  void step(uint8_t req, uint32_t addr, uint8_t &ack, uint64_t &data, const std::vector<uint16_t> &chr) {
    ack = 0;
    if (!req) need_low = false;
    if (wait < 0 && req && !need_low) wait = 0;
    if (wait == 0) {
      const uint32_t a = addr & 0x3fffcu;
      uint64_t w = 0;
      for (int k = 0; k < 4; k++) w |= uint64_t((a + k) < chr.size() ? chr[a + k] : 0xffffu) << (16 * k);
      data = w; ack = 1; wait = -1; need_low = true;
    } else if (wait > 0) --wait;
  }
};

// The eight words iteration j writes. Pair 0/1 in window mode 2 with a
// shake on hscr0 (+16, 0, -16, 0 -- the HUD shake measured in MAME), pair
// 2/3 in window mode 1 with the split and the backdrop scroll moving.
static void words(int j, uint16_t w[8]) {
  w[0] = (j % 4 == 0) ? 0x0010 : (j % 4 == 2) ? 0xfff0 : 0x0000;
  w[1] = 0;
  w[2] = uint16_t((7 * j) & 0x1ff);
  w[3] = 0;
  w[4] = 0x4000;
  w[5] = 0;
  w[6] = uint16_t(0x2000 | ((0x16a + 3 * j) & 0x1ff));
  w[7] = 0;
}

static void base_image(std::vector<uint16_t> &t, bool window) {
  for (int L = 0; L < 4; L++)
    for (int i = 0; i < 0x1000; i++)
      t[size_t(L) * 0x1000 + size_t(i)] = (L >= 2) ? uint16_t((L == 3 ? 0x1000 : 0) | i)
                                                   : uint16_t(0x2000 + L * 8 + (i % 8));
  for (int i = 0x4000; i < 0x8000; i++) t[size_t(i)] = 0;
  if (window) { uint16_t w[8]; words(0, w); for (int i = 0; i < 8; i++) t[size_t(0x5000 + i)] = w[i]; }
}

struct Sched {
  // per frame t: flip at line 150? new iteration's words at line 386 of the
  // vblank ending frame t? tag published at line 384 of that vblank?
  std::vector<int> flip_j, start_j, pub_k;
};

// Iterations of 1-3 frames. Iteration j's words are written at the vblank it
// starts in (iteration 0's are in the image) and it flips list j in its last
// frame; the RTL counts flips from list 0, as here. List k is walked at the
// vblank after its flip, drawn from the next vblank for 0.5-1.4 frames and
// published at the vblank after the draw ends (m2_raster3d's swap/publish).
static Sched make_sched(int frames, uint64_t seed, bool stall_after, bool sixty) {
  Sched s; s.flip_j.assign(size_t(frames + 8), -1); s.start_j.assign(size_t(frames + 8), -1);
  s.pub_k.assign(size_t(frames + 8), -1);
  Rng r{seed * 0x9E3779B97F4A7C15ull + 5};
  int t = 0, j = 0;         // iteration j runs from vblank t-1 (frame t on)
  std::vector<int> flipf;
  while (t < frames + 4) {
    const uint32_t x = r.next() % 100u;
    const int n = sixty ? 1 : x < 70 ? 2 : x < 92 ? 1 : 3;
    const int ff = t + n - 1;   // the frame it flips in
    if (ff < int(s.flip_j.size())) s.flip_j[size_t(ff)] = j;
    flipf.push_back(ff);
    if (ff < int(s.start_j.size())) s.start_j[size_t(ff)] = j + 1;   // at the vblank ending frame ff
    t = ff + 1;
    j++;
  }
  // In vblank indices: V_f ends visible frame f. The walk starts at V_ff, the
  // list is sorted during frame ff+1, swapped in at the next vblank once the
  // draw before it is done, and published at the first vblank after its draw.
  double busy = -1; int lastpub = -1;
  for (size_t k = 0; k < flipf.size(); k++) {
    const int walkv = flipf[k];
    const double rdy = walkv + 0.1 + (r.next() % 50u) / 100.0;
    double sw = std::floor(rdy) + 1;
    while (sw < busy) sw += 1;
    const double done = sw + 0.5 + (r.next() % (sixty ? 40u : 90u)) / 100.0;
    busy = done;
    int pub = int(std::ceil(done));
    pub = std::max(pub, lastpub + 1);
    lastpub = pub;
    if (stall_after && pub > frames / 2) continue;
    if (pub < int(s.pub_k.size())) s.pub_k[size_t(pub)] = int(k);
  }
  return s;
}

struct Res { int frames = 0, bad_frames = 0; long bad_px = 0; int al_n = 0, al_d = 0, al_live = 0, held = 0, skipped = 0, released = 0; };

static Res run(bool window, int frames, int scene, uint64_t seed) {
  // scene: 0 none / hscr-eq, 1 hscr-trap, 2 hscr-disc, 10 sync-none, 11 sync-play,
  //        12 sync-disc, 13 sync-stall
  Vm2_video_ovr_top *d = new Vm2_video_ovr_top;
  std::vector<uint16_t> tr(0x8000, 0), td(0x8000, 0), chr(0x40000);
  for (size_t i = 0; i < chr.size(); i++) chr[i] = uint16_t((i * 2654435761u) >> 13) ^ uint16_t(seed);
  base_image(tr, window); base_image(td, window);
  if (scene == 1 || scene == 2) {
    // plain mode, masks random except word 3 of every line: A in 0x6000's,
    // B in 0x6800's. r's hscr for layer L is word 3 of layer L-1's table
    // (layer 0: layer 3's, of the line before): L0 B, L1 A, L2 A, L3 B.
    Rng m{seed * 31 + 7};
    const uint16_t A = uint16_t((m.next() & 0x01ff) | 0x0003), B = uint16_t((m.next() & 0x01ff) | 0x0005);
    for (int i = 0x6000; i < 0x7000; i++) { const uint16_t v = uint16_t(m.next() | m.next()); tr[size_t(i)] = v; td[size_t(i)] = v; }
    for (int i = 0x6000; i < 0x6800; i += 4) { tr[size_t(i + 3)] = A; td[size_t(i + 3)] = A; }
    for (int i = 0x6800; i < 0x7000; i += 4) { tr[size_t(i + 3)] = B; td[size_t(i + 3)] = B; }
    const uint16_t h[4] = {B, A, A, B};
    for (int L = 0; L < 4; L++) {
      tr[size_t(0x5000 + L)] = h[L];
      td[size_t(0x5000 + L)] = uint16_t(scene == 2 ? (h[L] + 1 + L) & 0x1ff : h[L]);
      tr[size_t(0x5004 + L)] = td[size_t(0x5004 + L)] = uint16_t(5 * L);   // vscr, plain mode
    }
  }
  const int nfr = frames + 2;
  Sched sc = make_sched(nfr, seed, scene == 13, scene == 14 || scene == 12);
  int nf = 0;               // flips seen (the game's iteration now = nf)
  int jw = 0;               // iteration whose words tile RAM holds
  int P = 0;                // tag on screen
  bool flip_tgl = false;
  Port pr, pd;
  d->rst_n = 0; d->ce_pix = 0; d->interlace = 0; d->ntsc_lines = 0; d->r_m_ack = 0; d->d_m_ack = 0;
  d->d_flip = 0; d->d_tag = 0;
  uint16_t rq = 0, dq = 0;
  unsigned ce_acc = 0;
  int frame = -1, lvc = -1, vframe = -1;
  Res res; long fbad = 0;
  // which iteration r is to show, for the gated scenes
  // The rule m2_video implements: tile RAM holds iteration jw; the game is in
  // iteration nf (flips so far); list P is on screen. Iteration P + 2 is
  // shown while nf is one or two past it, tile RAM otherwise.
  auto intended = [&]() -> int {
    const int A = P + 2, df = nf - A;
    return (df >= 1 && df <= 2) ? A : jw;
  };
  bool trans = false;       // r's words changed mid-frame (a release at a flip)
  auto put = [&](std::vector<uint16_t> &t, int j) { uint16_t w[8]; words(j, w); for (int i = 0; i < 8; i++) t[size_t(0x5000 + i)] = w[i]; };
  const bool gated_ref = (scene == 11 || scene == 13 || scene == 14);
  int shown_r = 0;          // the iteration r shows (for the alignment count)
  const uint64_t LIMIT = uint64_t(nfr + 3) * 4100ull * 424ull;
  for (uint64_t cyc = 0; cyc < LIMIT; ++cyc) {
    if (ce_acc + 16 >= 100) { ce_acc = ce_acc + 16 - 100; d->ce_pix = 1; } else { ce_acc += 16; d->ce_pix = 0; }
    d->r_tram_data = rq; d->d_tram_data = dq;
    uint8_t a; uint64_t w = 0;
    pr.step(d->r_m_req, d->r_m_addr, a, w, chr); d->r_m_ack = a; if (a) d->r_m_data = w;
    pd.step(d->d_m_req, d->d_m_addr, a, w, chr); d->d_m_ack = a; if (a) d->d_m_data = w;
    d->clk = 0; d->eval();
    if (d->ce_pix && d->vcnt < 384 && d->hcnt < 496 && frame >= 1 && d->r_pal != d->d_pal) {
      if (std::getenv("R826_DEBUG") && fbad < 4)
        std::printf("    differ: frame %d y %d x %d r %03x d %03x\n", frame, int(d->vcnt), int(d->hcnt), d->r_pal, d->d_pal);
      ++fbad;
    }
    // the game and the 3D, on line boundaries (hcnt 0, first cycle of the line)
    if (int(d->vcnt) != lvc) {
      lvc = int(d->vcnt);
      // the schedule's frame: visible frame f and the vblank after it
      if (lvc == 0 && frame >= 0) vframe++;
      const int f = vframe;
      if (scene >= 11 && f >= 0) {
        if (lvc == 150 && sc.flip_j[size_t(f)] >= 0) {
          nf++; flip_tgl = !flip_tgl; d->d_flip = flip_tgl;
          if (gated_ref) { const int sh = intended(); if (sh != shown_r) { put(tr, sh); shown_r = sh; trans = true; } }
        }
        if (lvc == 384 && sc.pub_k[size_t(f)] >= 0) { P = sc.pub_k[size_t(f)]; d->d_tag = uint8_t(P & 0xf); }
        if (lvc == 386) {
          if (sc.start_j[size_t(f)] >= 0) { jw = sc.start_j[size_t(f)]; put(td, jw); }
          const int show = gated_ref ? intended() : jw;
          put(tr, show); shown_r = show;
        }
      }
    }
    if (d->vblank_start) {
      if (std::getenv("R826_TRACE"))
        std::printf("    frame %3d nf %2d jw %2d P %2d r-shows %2d trans %d bad %ld\n", frame, nf, jw, P, shown_r, int(trans), fbad);
      if (frame >= 1 && trans) res.skipped++;
      else if (frame >= 1) {
        res.frames++;
        if (fbad) { res.bad_frames++; res.bad_px += fbad; }
        if (nf - (P + 2) >= 3) res.released++;
        if ((scene == 11 || scene == 14) && frame >= 4) {   // past the first list's arrival
          res.al_n++;
          // the frame just shown: 3D list P (tag), 2D iteration shown_r (r) / jw (live)
          if (shown_r == P + 2) res.al_d++;
          if (jw == P + 2) res.al_live++;
          if (shown_r != jw) res.held++;
        }
      }
      fbad = 0; trans = false;
      frame++;
      if (frame > nfr) break;
    }
    const uint32_t ra = d->r_tram_addr, da = d->d_tram_addr;
    d->clk = 1; d->eval();
    if (cyc == 64) d->rst_n = 1;
    rq = tr[ra & 0x7fff]; dq = td[da & 0x7fff];
  }
  delete d;
  return res;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  int frames = 40;
  for (int i = 1; i < argc; i++)
    if (!std::strncmp(argv[i], "+frames=", 8)) frames = std::atoi(argv[i] + 8);
  int fails = 0;
  auto rep = [&](const char *nm, const Res &r, bool want_equal) {
    std::printf("  %-12s frames %3d  differing frames %3d (%ld px)%s   [mid-frame release, not compared %d; released %d]\n", nm, r.frames, r.bad_frames, r.bad_px,
                want_equal ? "  want 0" : "  want > 0", r.skipped, r.released);
    if (want_equal ? (r.bad_frames != 0) : (r.bad_frames == 0)) { std::printf("  FAIL %s\n", nm); fails++; }
    if (r.frames == 0) { std::printf("  FAIL %s: nothing compared\n", nm); fails++; }
  };
#if SSY_BUILD
  std::printf("== m2_video SCR_SYNC (R826) against the shipped path\n");
  rep("sync-none", run(true, 6, 10, 1), true);
  for (uint64_t seed = 1; seed <= 3; seed++) {
    Res r = run(true, frames, 11, seed);
    char nm[32]; std::snprintf(nm, sizeof nm, "sync-play/%d", int(seed));
    rep(nm, r, true);
    std::printf("      2D shown = the iteration written for the 3D shown (list + 2): gated %d of %d frames, ungated %d; frames held back %d\n",
                r.al_d, r.al_n, r.al_live, r.held);
    if (r.al_d < r.al_live) { std::printf("  FAIL: the gate aligned fewer frames than tile RAM as written\n"); fails++; }
  }
  {
    Res r = run(true, frames, 14, 1);
    rep("sync-60", r, true);
    std::printf("      (a list every frame, the 3D two vblanks behind its flip) aligned: gated %d of %d frames, ungated %d; held back %d\n",
                r.al_d, r.al_n, r.al_live, r.held);
    if (r.al_d != r.al_n) { std::printf("  FAIL: at 60 the gate should align every frame\n"); fails++; }
  }
  rep("sync-disc", run(true, frames, 12, 1), false);
  rep("sync-stall", run(true, frames, 13, 2), true);
#else
  std::printf("== m2_video HSCR_FIX (R826) against the shipped path\n");
  rep("hscr-eq", run(true, 6, 0, 1), true);
  for (uint64_t seed = 1; seed <= 3; seed++) {
    char nm[32]; std::snprintf(nm, sizeof nm, "hscr-trap/%d", int(seed));
    rep(nm, run(false, 4, 1, seed), true);
  }
  rep("hscr-disc", run(false, 4, 2, 1), false);
#endif
  std::printf("m2_video R826: %s\n", fails ? "FAIL" : "PASS");
  return fails ? 1 : 0;
}
