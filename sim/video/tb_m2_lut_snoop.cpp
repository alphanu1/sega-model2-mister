// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R1046: tb_m2_lut_snoop_top -- MAME 0.289's stream of CPU writes to the luma RAM
// (0x11400000), the 3D palette (0x01802000) and the colour table (0x01810000),
// as a Lua tap logged them (writes.txt: region, offset, data, mask), mapped to
// SDRAM words as the 2B bridge maps them (a halfword a word, a dword two), with
// random gaps; then the shadows against the tables tb_m2_raster3d's REALCOL fill
// writes from the final contents (final.txt: luma rows by m2_luma_map_ref, the
// palette & 0x7fff, the colour table & 0xff at luma 0-63) -- for each ID given.
//   Vtb_m2_lut_snoop <dir> <id hex> [<id hex> ...]
#include "Vtb_m2_lut_snoop_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>
#include <random>
#include "m2_luma_map_ref.h"

int main(int argc, char **argv) {
  if (argc < 3) { std::printf("usage: %s <dir> <id> ...\n", argv[0]); return 2; }
  const std::string dir = argv[1];
  struct Wr { int reg; uint32_t off, d, mk; };
  std::vector<Wr> wr;
  FILE *f = std::fopen((dir + "/writes.txt").c_str(), "r");
  if (!f) { std::printf("no writes.txt\n"); return 2; }
  { Wr w; while (std::fscanf(f, "%d %x %x %x", &w.reg, &w.off, &w.d, &w.mk) == 4) wr.push_back(w); std::fclose(f); }
  std::vector<uint16_t> fin[3];
  fin[0].assign(0x8000, 0); fin[1].assign(0x400, 0); fin[2].assign(0x6000, 0);
  f = std::fopen((dir + "/final.txt").c_str(), "r");
  if (!f) { std::printf("no final.txt\n"); return 2; }
  { int r; uint32_t o, v; while (std::fscanf(f, "%d %x %x", &r, &o, &v) == 3) {
      const uint32_t w = o >> 1;
      if (w + 1 < fin[r].size() + 1) { if (w < fin[r].size()) fin[r][w] = v & 0xffff; if (w + 1 < fin[r].size()) fin[r][w + 1] = v >> 16; } }
    std::fclose(f); }
  const uint32_t base[3] = {0x1860000, 0x1730000, 0x1731000};
  long fails = 0, checks = 0;
  std::mt19937 rng(1046);
  for (int a = 2; a < argc; a++) {
    const int id = int(std::strtol(argv[a], nullptr, 16));
    Vtb_m2_lut_snoop_top *t = new Vtb_m2_lut_snoop_top;
    auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
    t->rst_n = 0; t->id_we = 0; t->cpu_sd_req = 0; t->cpu_sd_we = 0; t->ack = 0; tick(); tick(); t->rst_n = 1; tick();
    t->id_we = 1; t->id_din = id; tick(); t->id_we = 0; tick(); tick();
    long nw = 0;
    for (const Wr &w : wr) for (int h = 0; h < 2; h++) {
      if (!((w.mk >> (16 * h)) & 0xffff)) continue;
      t->cpu_sd_addr = base[w.reg] + (w.off >> 1) + h; t->cpu_sd_din = (w.d >> (16 * h)) & 0xffff;
      t->cpu_sd_req = 1; t->cpu_sd_we = 1; t->ack = 1; tick(); ++nw;
      t->ack = 0; for (int g = rng() % 4; g > 0; --g) tick();   // the request held, no ack: nothing is written
      t->cpu_sd_req = 0; tick();
    }
    tick(); tick();
    const int g = id & 0x7f;
    long lf = 0, pf = 0, xf = 0, lrows = 0;
    for (int r = 0; r < 256; r++) {
      const int ls = m2_luma_map_ref(g, r, true, true);
      if (!(ls & 32)) continue;
      ++lrows;
      for (int i = 0; i < 128; i++) {
        t->rd_lr = ((ls & 31) << 7) | i; t->eval(); ++checks;
        if (t->q_lr != (fin[0][r * 128 + i] & 0xff)) { if (++lf <= 4) std::printf("  id %02x luma row %d [%d]: shadow %02x, MAME %02x\n", id, r, i, t->q_lr, fin[0][r * 128 + i] & 0xff); }
      }
    }
    for (int i = 0; i < 1024; i++) { t->rd_pal = i; t->eval(); ++checks;
      if (t->q_pal != (fin[1][i] & 0x7fff)) { if (++pf <= 4) std::printf("  id %02x palette %d: shadow %04x, MAME %04x\n", id, i, t->q_pal, fin[1][i] & 0x7fff); } }
    for (int ch = 0; ch < 3; ch++) for (int c5 = 0; c5 < 32; c5++) for (int l = 0; l < 64; l++) {
      t->rd_x = (ch << 11) | (c5 << 6) | l; t->eval(); ++checks;
      const int want = fin[2][ch * 0x2000 + (c5 << 8) + l] & 0xff;
      if (t->q_x != want) { if (++xf <= 4) std::printf("  id %02x colour %d/%d/%d: shadow %02x, MAME %02x\n", id, ch, c5, l, t->q_x, want); }
    }
    std::printf("  ID %02x (register reads %02x): %ld word writes; luma rows captured %ld, %ld differ; palette %ld differ; colour table %ld differ\n",
                id, t->game_q, nw, lrows, lf, pf, xf);
    fails += lf + pf + xf;
    delete t;
  }
  std::printf("  %ld checks, %ld differ\n%s\n", checks, fails, fails ? "FAIL" : "PASS");
  return fails ? 1 : 0;
}
