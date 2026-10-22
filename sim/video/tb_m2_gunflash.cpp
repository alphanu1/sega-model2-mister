// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R929: VIRTUA COP'S GUN FLASH THROUGH THE PICTURE PATH, FRAME BY FRAME.
//
// tb_m2_gunflash_top (m2_video with the core's parameters, tile RAM gated by
// the flash's kill, a stand-in 3D layer, m2_gun_flash, the output register)
// renders a run of frames from a MAME dump of Virtua Cop in play (tile, char,
// palette, colour table: sim/io/mame_m2_gunflash.lua GF_DUMP), while this
// bench plays the game's flash into tile RAM as the game does it:
//
//   the request   1,536 words 0xFFFF over the tilemap 0/1 window table
//                 (words 0x6000-0x65FF, from 0x6000 up), one every 16 cycles
//   the countdown the same words 0x0000 at each of the next four times
//
// at a chosen time: +sc=vbl puts each one 400 cycles into the vertical blank
// after frame +req=N (where the game's vblank handler puts it: MAME, IRQ bit
// 0, 0.04 ms in); +sc=mid puts each at line 200 of the frame after (a handler
// that ran late). +pull=F:L pulls player 1's trigger at line L of frame F.
// +band=N writes the game's OTHER use of the table instead -- the stage-start
// band, 0xFFFF over rows 172-199 only (words 0x62B0-0x631F, MAME 0x59D8C) --
// after frame N, and zero two frames later: not a flash, it must pass through.
// +game makes the bench answer like the game instead of on a schedule: it
// watches the trigger as the game gets it (trig_game_n -- held back in CRT
// gun mode) and puts the request in the vblank after the frame after the one
// the press is first seen in (MAME: pressed at 58.012, request 58.0452).
// +mode= is the OSD's Gun flash (0 Arcade, 1 CRT gun, 2 Off); +flash=0 is the
// harness built without the module (FLASH = 0, the core before R929).
//
// Every frame is summarised in <out>_sum.txt -- pixels that are pure white,
// rows that are entirely white, a hash -- with the request runs and the edges
// of the trigger as the game gets it; +raw also writes it to <out>_fNN.raw
// (496 x 384 RGB).
// run_gunflash.sh runs the cases and compares them (the checks are there).
#include "Vtb_m2_gunflash_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>

static bool load_u16(const std::string &path, std::vector<uint16_t> &out) {
  FILE *f = std::fopen(path.c_str(), "rb");
  if (!f) return false;
  std::fseek(f, 0, SEEK_END); long n = std::ftell(f); std::fseek(f, 0, SEEK_SET);
  std::vector<uint8_t> b(size_t(n), 0);
  const size_t got = std::fread(b.data(), 1, size_t(n), f);
  std::fclose(f);
  if (got != size_t(n)) return false;
  out.resize(b.size() / 2);
  for (size_t i = 0; i < out.size(); ++i) out[i] = uint16_t(b[i*2] | (uint16_t(b[i*2+1]) << 8));
  return true;
}

static const int W = 496, H = 384;

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  std::string in, out = "gf";
  int frames = 10, req = 4, mode = 0, pull_f = -1, pull_l = 0, nreq = 1;
  bool mid = false;
  int band = -1;
  bool game = false, raw = false;
  for (int i = 1; i < argc; i++) {
    const char *a = argv[i];
    if (!std::strncmp(a, "+in=", 4))     in = a + 4;
    if (!std::strncmp(a, "+out=", 5))    out = a + 5;
    if (!std::strncmp(a, "+frames=", 8)) frames = std::atoi(a + 8);
    if (!std::strncmp(a, "+req=", 5))    req = std::atoi(a + 5);
    if (!std::strncmp(a, "+nreq=", 6))   nreq = std::atoi(a + 6);   // 0: no request at all
    if (!std::strncmp(a, "+mode=", 6))   mode = std::atoi(a + 6);
    if (!std::strncmp(a, "+sc=mid", 7))  mid = true;
    if (!std::strncmp(a, "+band=", 6))   band = std::atoi(a + 6);
    if (!std::strncmp(a, "+game", 5))    game = true;
    if (!std::strncmp(a, "+raw", 4))     raw = true;
    if (!std::strncmp(a, "+pull=", 6))   std::sscanf(a + 6, "%d:%d", &pull_f, &pull_l);
  }
  std::vector<uint16_t> tram, chr, pal, xlat;
  if (in.empty() || !load_u16(in + "/tile.bin", tram) || !load_u16(in + "/char.bin", chr) ||
      !load_u16(in + "/palette.bin", pal)) {
    std::printf("tb_m2_gunflash: no dumps (+in=<dir> from mame_m2_gunflash.lua GF_DUMP)\nSKIP\n");
    return 0;
  }
  const bool have_xlat = load_u16(in + "/colorxlat.bin", xlat);
  // the dump is of a frame without the flash: the table must start at zero
  for (int w = 0x6000; w < 0x6600; ++w) tram[w] = 0;

  Vtb_m2_gunflash_top *d = new Vtb_m2_gunflash_top;
  d->rst_n = 0; d->ce_pix = 0; d->xlat_we = 0; d->char_ack = 0; d->char_data = 0;
  d->tram_q = 0; d->pal_data = 0; d->cpu_tram_we = 0; d->cpu_tram_addr = 0; d->cpu_tram_din = 0;
  d->trig_n = 3; d->mode = mode; d->en = 1;

  std::vector<uint8_t> fb(size_t(W) * H * 3, 0);
  uint16_t tram_q = 0, pal_q = 0;
  int cl = 0; uint32_t char_pend = 0; bool char_busy = false;
  unsigned ce_acc = 0;
  int frame = -1, x = 0, y = -1, line = -1;
  bool hb_p = true, vb_p = true;
  uint64_t cyc = 0;
  // the CPU's writes: a value over 0x6000..0x65FF, one word every 16 cycles
  int wr_left = 0, wr_word = 0, wr_gap = 0; uint16_t wr_val = 0;
  int band_n = 0;                       // band runs issued (the band, then its clear)
  int wr_n = 0;                         // requests issued (1 + 4 countdown each)
  long vbl_cyc = -1;                    // cycles since the last vblank began
  std::vector<int> sched;               // frame after whose vblank (or at whose line 200) a write run starts
  if (!game) for (int r = 0; r < nreq; ++r) for (int k = 0; k < 5; ++k) sched.push_back(req + 6 * r + k);
  int tg_prev = 3;                      // the game's trigger, last cycle
  size_t si = 0;
  const uint64_t LIMIT = uint64_t(frames + 3) * 656 * 424 * 7 + 100000;
  FILE *sum = std::fopen((out + "_sum.txt").c_str(), "w");
  if (!sum) { std::printf("tb_m2_gunflash: cannot write %s_sum.txt\n", out.c_str()); return 1; }

  while (cyc < LIMIT && frame < frames) {
    if (ce_acc + 16 >= 100) { ce_acc = ce_acc + 16 - 100; d->ce_pix = 1; } else { ce_acc += 16; d->ce_pix = 0; }
    d->tram_q = tram_q; d->pal_data = pal_q;
    d->char_ack = 0;
    if (char_busy) {
      if (--cl <= 0) { d->char_data = char_pend; d->char_ack = 1; char_busy = false; }
    } else if (d->char_req) {
      const uint32_t a = d->char_addr & 0x3ffffu;
      const uint16_t w0 = (a < chr.size()) ? chr[a] : 0xffff, w1 = (a + 1 < chr.size()) ? chr[a + 1] : 0xffff;
      char_pend = uint32_t(w0) | (uint32_t(w1) << 16);
      cl = 8; char_busy = true;
    }
    d->xlat_we = 0;
    if (have_xlat && cyc < 96) {
      static const uint32_t BASE[3] = { 0x0080u >> 1, 0x4080u >> 1, 0x8080u >> 1 };
      const uint32_t ch = uint32_t(cyc) / 32, iv = uint32_t(cyc) % 32, idx = BASE[ch] + (iv << 8);
      d->xlat_we = 1; d->xlat_addr = uint8_t(ch * 32 + iv);
      d->xlat_din = uint8_t(idx < xlat.size() ? (xlat[idx] & 0xff) : 0);
    }
    // the CPU's write run: the request (0xFFFF) first, then four of 0x0000
    d->cpu_tram_we = 0;
    if (si < sched.size() && wr_left == 0) {
      const int f = sched[si];
      const bool go = mid ? (frame == f + 1 && line == 200) : (frame == f + 1 && vbl_cyc == 400);
      // frame counts visible frames ended: "after frame f's vblank" is frame == f + 1 here
      if (go) {
        wr_left = 0x600; wr_word = 0x6000; wr_gap = 0;
        wr_val = (si % 5 == 0) ? 0xFFFF : 0x0000;
        std::fprintf(sum, "write run %zu (%04x) at frame %d %s\n", si, wr_val, frame, mid ? "line 200" : "vblank+400");
        ++si; ++wr_n;
      }
    }
    if (band >= 0 && wr_left == 0 && band_n < 2 && frame == band + 1 + 2 * band_n && vbl_cyc == 400) {
      wr_left = 0x70; wr_word = 0x62B0; wr_gap = 0; wr_val = band_n ? 0x0000 : 0xFFFF;
      std::fprintf(sum, "band run %d (%04x) at frame %d vblank+400\n", band_n, wr_val, frame);
      ++band_n;
    }
    if (wr_left > 0) {
      if (wr_gap == 0) {
        d->cpu_tram_we = 1; d->cpu_tram_addr = wr_word; d->cpu_tram_din = wr_val;
        tram[wr_word] = wr_val; ++wr_word; --wr_left; wr_gap = 15;
      } else --wr_gap;
    }
    // player 1's trigger: pressed for 4 ms at line L of frame F (frame index as below)
    static long pull_cyc = -1;
    if (pull_f >= 0 && frame == pull_f && line == pull_l && pull_cyc < 0) pull_cyc = 0;
    if (pull_cyc >= 0) { d->trig_n = (pull_cyc < 400000) ? 2 : 3; ++pull_cyc; } else d->trig_n = 3;

    // the trigger as the game gets it: log its edges, and with +game answer a press
    {
      const int tg = d->trig_game_n & 1;
      if (cyc > 256 && tg != (tg_prev & 1)) {   // not the reset's
        std::fprintf(sum, "game trigger %s at frame %d line %d\n", tg ? "released" : "pressed", frame, line);
        if (!tg && game) for (int k = 0; k < 5; ++k) sched.push_back(frame + 1 + k);
      }
      tg_prev = tg;
    }
    const uint32_t ta = d->tram_addr, pa = d->pal_addr;
    d->clk = 0; d->eval(); d->clk = 1; d->eval();
    ++cyc; if (vbl_cyc >= 0) ++vbl_cyc;
    if (cyc == 128) d->rst_n = 1;
    tram_q = (ta < tram.size()) ? tram[ta] : 0xffff;
    pal_q  = (pa < pal.size())  ? pal[pa]  : 0xffff;
    if (!d->ce_pix) continue;
    const bool hb = d->o_hb, vb = d->o_vb;
    if (vb && !vb_p) {
      // a frame has ended: summarise it
      if (frame >= 0) {
        size_t white = 0, wrows = 0; uint64_t h = 1469598103934665603ull;
        for (int r = 0; r < H; ++r) {
          bool all = true;
          for (int c = 0; c < W; ++c) {
            const uint8_t *p = &fb[(size_t(r) * W + c) * 3];
            const bool wpx = p[0] == 255 && p[1] == 255 && p[2] == 255;
            white += wpx; all = all && wpx;
            for (int k = 0; k < 3; ++k) { h ^= p[k]; h *= 1099511628211ull; }
          }
          wrows += all;
        }
        std::fprintf(sum, "frame %d white %zu rows_white %zu hash %016llx\n", frame, white, wrows, (unsigned long long)h);
        if (raw) {
          char path[512]; std::snprintf(path, sizeof path, "%s_f%02d.raw", out.c_str(), frame);
          if (FILE *g = std::fopen(path, "wb")) { std::fwrite(fb.data(), 1, fb.size(), g); std::fclose(g); }
        }
      }
      ++frame; y = -1; line = -1; vbl_cyc = 0;
      std::fill(fb.begin(), fb.end(), 0);
    }
    if (!hb && hb_p) { x = 0; if (!vb) { ++y; line = y; } }
    if (!hb && !vb && y >= 0 && y < H && x < W) {
      const size_t o = (size_t(y) * W + x) * 3;
      fb[o] = d->o_r; fb[o+1] = d->o_g; fb[o+2] = d->o_b;
    }
    if (!hb && !vb) ++x;
    hb_p = hb; vb_p = vb;
  }
  std::fclose(sum);
  std::printf("tb_m2_gunflash: %d frames, %d write runs, out %s\n", frame, wr_n, out.c_str());
  delete d;
  return 0;
}
