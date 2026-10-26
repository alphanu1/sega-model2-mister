// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R965: GUN FLASH OFF ON THE 2A / 2C CORE, FRAME BY FRAME.
//
// tb_m2_gunflash2a_top (m2_video with the 2A core's parameters, tile RAM gated
// by the flash's kill, a stand-in 3D layer, m2_gun_flash as Model2.sv wires it
// for Virtua Cop 2 / The House of the Dead, the output register) renders a run
// of frames from a MAME dump (tile, char, palette, colour table:
// sim/io/mame_m2_gunflash_wt.lua WT_DUMP) while this bench plays the CPU's
// tile-RAM writes from a script, as the game makes them:
//
//   +wr=<file>   lines "F WORD VALUE [mid]" (hex word address and value): the
//                writes of frame F, in file order, one every 16 cycles, from
//                400 cycles into the vertical blank after frame F (where the
//                games' vblank handlers put them: MAME, before the next frame)
//                or, with "mid", from line 200 of the frame after (a handler
//                that ran late). Lines of one frame form one run.
//   +off=1       the OSD's Gun flash Off (O[66]); 0 Arcade
//   +en=0        the module held off (any game but the gun games)
//   +flash=0     is the harness built without it (FLASH = 0, the core before R965)
//
// The dump is taken on a frame without the flash: the window table (words
// 0x6000-0x67FF) is cleared first, as the game leaves it between shots.
// Every frame is summarised in <out>_sum.txt -- pure-white pixels, pixels the
// colour of the screen's centre, a hash, the cycles the kill was high; +raw
// also writes <out>_fNN.raw (496 x 384 RGB). run_gunflash2a.sh runs the cases
// and compares them (the checks are there).
#include "Vtb_m2_gunflash2a_top.h"
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

struct Run { int f; bool mid; std::vector<std::pair<uint16_t, uint16_t>> w; };

static const int W = 496, H = 384;

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  std::string in, out = "gf", wr;
  int frames = 10, off = 0, en = 1;
  bool raw = false;
  for (int i = 1; i < argc; i++) {
    const char *a = argv[i];
    if (!std::strncmp(a, "+in=", 4))     in = a + 4;
    if (!std::strncmp(a, "+out=", 5))    out = a + 5;
    if (!std::strncmp(a, "+wr=", 4))     wr = a + 4;
    if (!std::strncmp(a, "+frames=", 8)) frames = std::atoi(a + 8);
    if (!std::strncmp(a, "+off=", 5))    off = std::atoi(a + 5);
    if (!std::strncmp(a, "+en=", 4))     en = std::atoi(a + 4);
    if (!std::strncmp(a, "+raw", 4))     raw = true;
  }
  std::vector<uint16_t> tram, chr, pal, xlat;
  if (in.empty() || !load_u16(in + "/tile.bin", tram) || !load_u16(in + "/char.bin", chr) ||
      !load_u16(in + "/palette.bin", pal)) {
    std::printf("tb_m2_gunflash2a: no dumps (+in=<dir> from mame_m2_gunflash_wt.lua WT_DUMP)\nSKIP\n");
    return 0;
  }
  const bool have_xlat = load_u16(in + "/colorxlat.bin", xlat);
  for (int w = 0x6000; w < 0x6800; ++w) tram[w] = 0;

  std::vector<Run> runs;
  if (!wr.empty()) {
    FILE *f = std::fopen(wr.c_str(), "r");
    if (!f) { std::printf("tb_m2_gunflash2a: cannot read %s\n", wr.c_str()); return 1; }
    char line[256];
    while (std::fgets(line, sizeof line, f)) {
      int fr; unsigned wd, v; char m[16] = "";
      const int n = std::sscanf(line, "%d %x %x %15s", &fr, &wd, &v, m);
      if (n < 3) continue;
      const bool mid = (n == 4 && !std::strcmp(m, "mid"));
      if (runs.empty() || runs.back().f != fr || runs.back().mid != mid) runs.push_back({fr, mid, {}});
      runs.back().w.push_back({uint16_t(wd), uint16_t(v)});
    }
    std::fclose(f);
  }

  Vtb_m2_gunflash2a_top *d = new Vtb_m2_gunflash2a_top;
  d->rst_n = 0; d->ce_pix = 0; d->xlat_we = 0; d->char_ack = 0; d->char_data = 0;
  d->tram_q = 0; d->pal_data = 0; d->cpu_tram_we = 0; d->cpu_tram_addr = 0; d->cpu_tram_din = 0;
  d->off = off; d->en = en;

  std::vector<uint8_t> fb(size_t(W) * H * 3, 0);
  uint16_t tram_q = 0, pal_q = 0;
  int cl = 0; uint32_t char_pend = 0; bool char_busy = false;
  unsigned ce_acc = 0;
  int frame = -1, x = 0, y = -1, line = -1;
  bool hb_p = true, vb_p = true;
  uint64_t cyc = 0, kills = 0;
  long vbl_cyc = -1;                    // cycles since the last vblank began
  size_t ri = 0, wi = 0; bool busy = false; int gap = 0;
  const uint64_t LIMIT = uint64_t(frames + 3) * 656 * 424 * 7 + 100000;
  FILE *sum = std::fopen((out + "_sum.txt").c_str(), "w");
  if (!sum) { std::printf("tb_m2_gunflash2a: cannot write %s_sum.txt\n", out.c_str()); return 1; }

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
    // the CPU's write runs
    d->cpu_tram_we = 0;
    if (!busy && ri < runs.size()) {
      const Run &r = runs[ri];
      const bool go = (frame == r.f + 1) && (r.mid ? line >= 200 : vbl_cyc >= 400);
      if (go) {
        busy = true; wi = 0; gap = 0;
        std::fprintf(sum, "write run %zu (%zu words from %04x = %04x) at frame %d %s\n", ri, r.w.size(),
                     r.w[0].first, r.w[0].second, frame, r.mid ? "line 200" : "vblank+400");
      }
    }
    if (busy) {
      if (gap == 0) {
        const auto &p = runs[ri].w[wi];
        d->cpu_tram_we = 1; d->cpu_tram_addr = p.first & 0x7fff; d->cpu_tram_din = p.second;
        if (p.first < tram.size()) tram[p.first] = p.second;
        gap = 15;
        if (++wi == runs[ri].w.size()) { busy = false; ++ri; }
      } else --gap;
    }
    const uint32_t ta = d->tram_addr, pa = d->pal_addr;
    d->clk = 0; d->eval(); d->clk = 1; d->eval();
    ++cyc; if (vbl_cyc >= 0) ++vbl_cyc;
    if (cyc == 128) d->rst_n = 1;
    kills += d->o_kill;
    tram_q = (ta < tram.size()) ? tram[ta] : 0xffff;
    pal_q  = (pa < pal.size())  ? pal[pa]  : 0xffff;
    if (!d->ce_pix) continue;
    const bool hb = d->o_hb, vb = d->o_vb;
    if (vb && !vb_p) {
      if (frame >= 0) {
        size_t white = 0, flat = 0; uint64_t h = 1469598103934665603ull;
        const uint8_t *c = &fb[(size_t(H / 2) * W + W / 2) * 3];
        for (int r = 0; r < H; ++r)
          for (int k = 0; k < W; ++k) {
            const uint8_t *p = &fb[(size_t(r) * W + k) * 3];
            white += (p[0] == 255 && p[1] == 255 && p[2] == 255);
            flat += (p[0] == c[0] && p[1] == c[1] && p[2] == c[2]);
            for (int q = 0; q < 3; ++q) { h ^= p[q]; h *= 1099511628211ull; }
          }
        std::fprintf(sum, "frame %d white %zu flat %zu hash %016llx kill %llu\n", frame, white, flat,
                     (unsigned long long)h, (unsigned long long)kills);
        if (raw) {
          char path[512]; std::snprintf(path, sizeof path, "%s_f%02d.raw", out.c_str(), frame);
          if (FILE *g = std::fopen(path, "wb")) { std::fwrite(fb.data(), 1, fb.size(), g); std::fclose(g); }
        }
      }
      ++frame; y = -1; line = -1; vbl_cyc = 0; kills = 0;
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
  std::printf("tb_m2_gunflash2a: %d frames, %zu write runs, out %s\n", frame, ri, out.c_str());
  delete d;
  return 0;
}
