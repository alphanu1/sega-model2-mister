// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// m2_texview (R650): every visible pixel of the texture view against the sheet
// it claims to show, over every page of both sheets, with the port answering as
// m2_sdram does -- dispatched on the request's rising edge, the data valid
// while the acknowledge is held (ACK_HOLD 2) -- after a latency that is swept
// past the board's. The sheet is a real one: M2_TV_SHEET0/1 (u16 files, e.g.
// tb_m2_boot's M2_TEXDUMP output); without them, a hash of the address.
//
// A line the port was too slow to finish is not an error -- the view says so
// by showing the previous contents -- but it is counted, and at the board's
// latency there must be none.
#include "Vm2_texview.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>

static const uint32_t B0 = 0x1760000u, B1 = 0x17E0000u;
static std::vector<uint16_t> sh[2];
static uint16_t word(uint32_t a) {
  const int k = (a >= B1) ? 1 : 0; const uint32_t w = a - (k ? B1 : B0);
  if (!sh[k].empty()) return w < sh[k].size() ? sh[k][w] : 0xFFFF;
  return uint16_t((a * 2654435761u) >> 13);
}
static int texel_at(int k, int tx, int ty) {   // the sheet's own layout
  const uint32_t w = (k ? B1 : B0) + uint32_t(ty >> 1) * 512 + uint32_t(tx >> 1);
  const uint16_t v = word(w);
  const int sel = ((ty & 1) << 1) | (tx & 1);
  return (v >> (12 - 4 * sel)) & 0xF;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  for (int k = 0; k < 2; k++)
    if (const char *p = std::getenv(k ? "M2_TV_SHEET1" : "M2_TV_SHEET0")) {
      FILE *f = std::fopen(p, "rb"); if (!f) { std::printf("no %s\n", p); return 1; }
      sh[k].resize(0x80000); size_t n = std::fread(sh[k].data(), 2, 0x80000, f); std::fclose(f);
      if (n != 0x80000) { std::printf("short %s\n", p); return 1; }
    }
  const int LAT = std::getenv("M2_TV_LAT") ? std::atoi(std::getenv("M2_TV_LAT")) : 40;
  const int JIT = std::getenv("M2_TV_JIT") ? std::atoi(std::getenv("M2_TV_JIT")) : 20;
  Vm2_texview *d = new Vm2_texview;
  d->base0 = B0; d->base1 = B1; d->en = 0; d->rst_n = 0; d->clk = 0;
  const int HTOT = 656, VTOT = 424;            // 100 MHz, 16 ce per 100 cycles
  int hc = 0, vc = 0, ceacc = 0, cd = -1, ackh = 0, req_d = 0;
  uint32_t lat_addr = 0; uint64_t rng = 12345;
  long checks = 0, fails = 0;
  auto tick = [&]() {
    d->clk = 1; d->eval(); d->clk = 0; d->eval();
  };
  for (int i = 0; i < 20; i++) tick();
  d->rst_n = 1;
  for (int k = 0; k < 2; k++)
    for (int page = 0; page < 22; page++) {
      d->en = 1; d->sheet = k; d->page = page;
      for (int frame = 0; frame < 2; frame++) {
        for (;;) {
          // the port, as m2_sdram: a rising request is dispatched
          d->m_ack = 0;
          if (ackh > 0) { d->m_ack = 1; ackh--; }
          if (cd > 0 && --cd == 0) {
            uint64_t v = 0;
            for (int w = 0; w < 4; w++) v |= uint64_t(word(lat_addr + w)) << (16 * w);
            d->m_data = v; d->m_ack = 1; ackh = 1;
          }
          if (d->m_req && !req_d && cd <= 0 && ackh == 0) {
            lat_addr = d->m_addr;
            rng = rng * 6364136223846793005ull + 1442695040888963407ull;
            cd = LAT + int((rng >> 33) % uint64_t(JIT + 1));
          }
          req_d = d->m_req;
          // the beam: the texel for (x, y) appears a cycle after they are presented
          const int px = hc, py = vc;
          d->vid_x = hc < 512 ? hc : 511; d->vid_y = vc;
          tick();
          // texel, x_q and the line flag are registered from (vid_x, vid_y) on
          // this edge: after it, the output describes the pixel just presented
          if (frame == 1 && px < 496 && py < 384) {
            const int ty = (page >> 1) * 192 + (py >> 1), tx = (page & 1) * 528 + px;
            const int want = ty < 2048 ? texel_at(k, tx, ty) : 0;
            ++checks;
            if (int(d->texel) != want) {
              ++fails;
              if (fails < 10) std::printf("  FAIL sheet %d page %d (%d,%d): %x want %x\n", k, page, px, py, d->texel, want);
            }
          }
          if (++ceacc >= 100) ceacc -= 100;
          if ((ceacc * 16) % 100 < 16) { if (++hc == HTOT) { hc = 0; if (++vc == VTOT) { vc = 0; break; } } }
        }
      }
    }
  std::printf("m2_texview: latency %d+%d, %ld pixel checks, %ld wrong\n", LAT, JIT, checks, fails);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
