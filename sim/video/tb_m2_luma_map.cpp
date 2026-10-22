// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R900: m2_luma_map against its reference (m2_luma_map_ref.h) -- every game ID
// (7 bits), every row on both lookups, and the game ID changed under it.
// R928: and as a 2C build drives it (c2: 0x17 and 0x1C take ranges).
#include "Vm2_luma_map.h"
#include "verilated.h"
#include <cstdio>
#include "m2_luma_map_ref.h"

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vm2_luma_map *d = new Vm2_luma_map;
  auto tick = [&]() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };
  long checks = 0, fails = 0;
  for (int pass = 0; pass < 4; pass++)
    for (int gi = 0; gi < 128; gi++) {
      const int g = (pass & 1) ? (gi * 53 + 7) & 127 : gi;   // the odd passes in another order
      const bool c2 = pass >= 2;                              // R928: passes 2-3 as a 2C build
      d->game_id = g & 15; d->big = m2_luma_big(g, c2); d->zg = (g == 0x12);
      tick(); tick();
      for (int r = 0; r < 256; r++) {
        const int w = (r * 37 + 11) & 255;
        d->q_row = r; d->w_row = w; d->eval();
        const int qe = m2_luma_map_ref(g, r, c2) & 7, we = m2_luma_map_ref(g, w, c2);
        const int qg = d->q_ls & 7, wg = d->w_ls;
        checks += 2;
        // a write's slot matters only when it is captured (no write otherwise)
        const bool wok = ((wg >> 3) == (we >> 3)) && (!(we & 8) || (wg & 7) == (we & 7));
        if (qg != qe || !wok) {
          if (++fails <= 10) std::printf("  FAIL game %02x row %3d q %x/%x  row %3d w %x/%x\n", g, r, qg, qe, w, wg, we);
        }
      }
    }
  std::printf("  m2_luma_map: %ld checks, %ld fails\n", checks, fails);
  std::printf(fails ? "FAIL\n" : "PASS\n");
  delete d;
  return fails ? 1 : 0;
}
