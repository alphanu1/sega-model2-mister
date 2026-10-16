// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// m2_vcop_xhair (R846) in the real video timing, sampled where the framework
// samples (ce_pix), at 24 kHz and at 15 kHz interlaced: every visible pixel
// of a whole frame (both fields) is classified -- picture, player 1, player
// 2, outline -- and compared with the cross the OSD asks for, centred on the
// pixel m2_vcop_guns names (the game's aim pixel). The picture is its own
// coordinates, so every pixel not under a cross must come out as exactly the
// pixel the sample belongs to: the picture is neither moved nor touched.
#include "Vtb_m2_vcop_xhair_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <random>

static Vtb_m2_vcop_xhair_top* d;
static long fails = 0, checks = 0;
#define CHECK(c, ...) do { checks++; if (!(c)) { if (fails++ < 30) { printf("FAIL: " __VA_ARGS__); printf("\n"); } } } while (0)

enum { PIC = 0, P1 = 1, P2 = 2, OUT = 3, BAD = 4 };
static const int W = 496, H = 384;
static std::vector<int> img;

// one clk_mem cycle; the framework's sample is the output before the edge on
// which ce_pix is high
static void cyc(bool rec) {
  d->clk = 0; d->eval();
  if (rec && d->ce) {
    int x = d->px, row = d->prow, f = d->pfield;
    int line = d->il ? 2 * row + f : row;
    bool vis = x < W && (d->il ? row < 192 : row < H);
    if (vis) {
      int r = d->r, g = d->g, b = d->b, k;
      int pr = x & 0xff, pg = ((x >> 8) << 6) | (row & 0x3f), pb = (f << 4) | (row >> 6);
      if (r == pr && g == pg && b == pb) k = PIC;
      else if (r == 0x69 && g == 0xff && b == 0xff) k = P1;
      else if (r == 0xff && g == 0x90 && b == 0xa4) k = P2;
      else if (r == 0 && g == 0 && b == 0) k = OUT;
      else k = BAD;
      img[line * W + x] = k;
    }
  }
  d->clk = 1; d->eval();
}

static int expect(int x, int line, bool il, const int on[2], int L, const int cx[2], const int cy[2]) {
  int col = PIC; bool out = false;
  for (int p = 1; p >= 0; p--) {
    if (!on[p]) continue;
    int ly = il ? ((line & ~1) | (cy[p] & 1)) : line;
    int dx = x - cx[p], dy = ly - cy[p];
    bool c = (dy == 0 && abs(dx) <= L) || (dx == 0 && abs(dy) <= L);
    bool o = (abs(dy) <= 1 && abs(dx) <= L + 1) || (abs(dx) <= 1 && abs(dy) <= L + 1);
    if (c) col = p + 1;
    if (o) out = true;
  }
  if (col == PIC && out) col = OUT;
  if (on[0]) {   // P1 over P2
    int ly = il ? ((line & ~1) | (cy[0] & 1)) : line;
    int dx = x - cx[0], dy = ly - cy[0];
    if ((dy == 0 && abs(dx) <= L) || (dx == 0 && abs(dy) <= L)) col = P1;
  }
  return col;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vtb_m2_vcop_xhair_top;
  std::mt19937 rng(846);
  struct Case { int il, size, on1, on2, x1, y1, x2, y2; };
  std::vector<Case> cs = {
    {0, 0, 1, 1, 248, 192, 100, 50}, {1, 0, 1, 1, 248, 192, 100, 50},
    {0, 1, 1, 1, 0, 0, 495, 383},    {1, 1, 1, 1, 0, 0, 495, 383},
    {0, 0, 1, 1, 300, 201, 305, 203}, {1, 0, 1, 1, 300, 201, 305, 203},   // overlapping, odd lines
    {0, 2, 1, 1, 248, 192, 100, 50}, {1, 2, 1, 1, 248, 192, 100, 50},     // Off
    {0, 0, 0, 1, 248, 192, 100, 51}, {1, 1, 1, 0, 17, 383, 100, 51},      // hidden (off-screen)
  };
  for (int i = 0; i < 8; i++)
    cs.push_back({int(i & 1), int(rng() % 2), 1, 1, int(rng() % W), int(rng() % H), int(rng() % W), int(rng() % H)});
  for (auto& c : cs) {
    d->il = c.il; d->size = c.size; d->on = c.on1 | (c.on2 << 1);
    d->c1x = c.x1; d->c1y = c.y1; d->c2x = c.x2; d->c2y = c.y2;
    d->rst_n = 0; for (int i = 0; i < 20; i++) cyc(false);
    d->rst_n = 1;
    for (int i = 0; i < 20; i++) cyc(false);
    img.assign(W * H, -1);
    // a frame: 24 kHz 656 x 424 at 6.25 cycles; interlaced two fields of
    // 684 x 273.5 at 100/10.32 cycles -- run 1.2 frames
    long n = c.il ? long(684 * 547 * 100.0 / 10.3208 * 1.2) : long(656 * 424 * 6.25 * 1.2);
    for (long i = 0; i < n; i++) cyc(true);
    int on[2] = {c.on1, c.on2}, cx[2] = {c.x1, c.x2}, cy[2] = {c.y1, c.y2};
    bool show = c.size < 2;
    if (!show) on[0] = on[1] = 0;
    int L = c.size == 1 ? 9 : 5;
    long miss = 0, wrong = 0, drawn = 0;
    for (int y = 0; y < H; y++)
      for (int x = 0; x < W; x++) {
        int got = img[y * W + x], want = expect(x, y, c.il, on, L, cx, cy);
        if (got < 0) { miss++; continue; }
        if (got != PIC) drawn++;
        if (got != want) { if (wrong++ < 5) printf("  il %d size %d (%d,%d)/(%d,%d): pixel (%d,%d) is %d, want %d\n",
                                                     c.il, c.size, c.x1, c.y1, c.x2, c.y2, x, y, got, want); }
      }
    // the aim pixel itself, in the field that shows it
    int ctr = img[c.y1 * W + c.x1];
    CHECK(miss == 0 && wrong == 0 && (!(show && c.on1) || ctr == P1),
          "il %d size %d P1 (%d,%d) P2 (%d,%d): %ld unseen, %ld wrong, centre %d",
          c.il, c.size, c.x1, c.y1, c.x2, c.y2, miss, wrong, ctr);
    printf("il %d size %d on %d%d P1 (%3d,%3d) P2 (%3d,%3d): %6d pixels sampled, %4ld drawn, %ld wrong, P1 centre %s\n",
           c.il, c.size, c.on2, c.on1, c.x1, c.y1, c.x2, c.y2, W * H, drawn, wrong,
           ctr == P1 ? "P1" : ctr == P2 ? "P2" : ctr == OUT ? "outline" : "picture");
  }
  printf("tb_m2_vcop_xhair: %ld checks, %ld failures\n", checks, fails);
  printf(fails ? "FAIL\n" : "PASS\n");
  delete d;
  return fails ? 1 : 0;
}
