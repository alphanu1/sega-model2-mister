// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// m2_vcop_state V2 (R870) against MAME's record of Virtua Cop 2's state.
//
// Input: MAME 0.289's log of every i960 write to the mode word 0x500034, the
// step word 0x500038 and the player words 0x502088 / 0x50208c (time, address,
// data, mask; V2_WLOG of sim/io/mame_m2_vcop2_play.lua) and the bytes 0x500034,
// 0x500038, 0x502088, 0x50208c every 0.5 s (V2_STATE, V2_WATCH in that order).
// The writes are replayed on the module's bus in order, as the i960 puts them
// there (a byte or half store replicated across the word, the enables picking
// the lane -- or junk in the other lanes), with random traffic between them
// that must be ignored (reads, the words +-8, other 64 KB banks, an address
// bit off, the write's own lane disabled, no ack). The words are also kept in a
// model RAM; the bytes the dump has must match it (the log is complete) and
// at every sample the module's {P2, P1} must equal MAME's RAM rule: mode word
// == 0x100, step byte != 0, the player's word == 1.
// Then directed cases, and en low: never in play.
//
// usage: Vtb_m2_vcop2_state <wlog.txt> <state.txt> [<wlog> <state>]...
#include "Vm2_vcop_state.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <map>
#include <vector>
#include <random>

static Vm2_vcop_state* d;
static long fails = 0, checks = 0;
#define CHECK(c, ...) do { checks++; if (!(c)) { if (fails++ < 20) { printf("FAIL: " __VA_ARGS__); printf("\n"); } } } while (0)
static void tick() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }
static std::mt19937 rng(870);

static uint32_t be_of(uint32_t mask) {
  uint32_t be = 0;
  for (int k = 0; k < 4; k++) if ((mask >> (8 * k)) & 0xff) be |= 1u << k;
  return be;
}
// what the i960 drives for a store MAME logged as (data, mask)
static uint32_t drive(uint32_t data, uint32_t mask) {
  uint32_t be = be_of(mask);
  if (rng() & 1) return (data & mask) | (rng() & ~mask);                     // junk elsewhere
  if (be == 1 || be == 2 || be == 4 || be == 8) {
    int k = __builtin_ctz(be); uint32_t b = (data >> (8 * k)) & 0xff; return b * 0x01010101u;
  }
  if (be == 3 || be == 12) { uint32_t h = (data >> (be == 3 ? 0 : 16)) & 0xffff; return h * 0x00010001u; }
  return data;
}
static void bus(bool we, uint32_t a, uint32_t w, uint32_t be, bool ack = true) {
  d->bus_req = 1; d->bus_we = we; d->bus_ack = ack; d->bus_addr = a; d->bus_wdata = w; d->bus_be = be;
  tick();
  d->bus_req = 0; d->bus_we = 0; d->bus_ack = 0;
  d->bus_addr = rng(); d->bus_wdata = rng(); d->bus_be = rng() & 15;   // idle bus: junk
  tick();
}
static const uint32_t TG[4] = {0x500034, 0x500038, 0x502088, 0x50208c};
static void noise() {
  for (int k = rng() % 4; k > 0; k--) {
    uint32_t a = TG[rng() % 4];
    uint32_t v = rng() & 1 ? 0x01010101u : (rng() & 1 ? 0x00000100u : 0x08080808u);
    switch (rng() % 7) {
      case 0: bus(false, a, v, 0xf); break;                                   // a read
      case 1: bus(true, a + 8, v, 0xf); break;                                // a word after
      case 2: bus(true, a - 8, v, 0xf); break;                                // a word before
      case 3: bus(true, a, v, (a == 0x500034) ? 0xd : 0xe); break;           // its lane off
      case 4: bus(true, a, v, 0xf, false); break;                             // not acknowledged
      case 5: bus(true, a ^ (1u << (16 + rng() % 16)), v, 0xf); break;        // another 64 KB
      case 6: bus(true, a ^ (1u << (3 + rng() % 13)), v, 0xf); break;         // one address bit off (bit 2 is the other player)
    }
  }
}
struct W { double t; uint32_t a, data, mask; };
struct S { double t; int b[4]; };

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_vcop_state;
  if (argc < 3) { printf("usage: %s <wlog.txt> <state.txt> [...]\n", argv[0]); return 2; }
  long samples = 0, in1 = 0, in2 = 0, changes = 0, nwrites = 0;
  for (int s = 1; s + 1 < argc; s += 2) {
    std::vector<W> ws; std::vector<S> ss;
    char line[256];
    FILE* f = fopen(argv[s], "r");
    if (!f) { printf("no %s\n", argv[s]); return 2; }
    while (fgets(line, sizeof line, f)) {
      W w;
      if (sscanf(line, "%lf %x data %x mask %x", &w.t, &w.a, &w.data, &w.mask) == 4) ws.push_back(w);
    }
    fclose(f);
    FILE* r = fopen(argv[s + 1], "r");
    if (!r) { printf("no %s\n", argv[s + 1]); return 2; }
    while (fgets(line, sizeof line, r)) {
      S x;
      if (sscanf(line, "%lf %x %x %x %x", &x.t, &x.b[0], &x.b[1], &x.b[2], &x.b[3]) == 5) ss.push_back(x);
    }
    fclose(r);
    d->rst_n = 0; d->en = 1; d->test = 0; d->bus_req = 0; d->bus_we = 0; d->bus_ack = 0; tick(); tick();
    d->rst_n = 1; tick();
    std::map<uint32_t, uint32_t> ram;   // the four words, as MAME's RAM holds them
    for (uint32_t a : TG) ram[a] = 0;
    size_t wi = 0;
    int last = -1;
    for (auto& x : ss) {
      while (wi < ws.size() && ws[wi].t <= x.t) {
        const W& w = ws[wi++];
        ram[w.a] = (ram[w.a] & ~w.mask) | (w.data & w.mask);
        // MAME's test presses ("press Service Mode") are not bus traffic; the
        // module's test input is unused with V2 -- pulse it to prove that
        d->test = (rng() % 50) == 0;
        bus(true, w.a, drive(w.data, w.mask), be_of(w.mask));
        nwrites++;
        if (rng() % 3 == 0) noise();
      }
      d->test = 0;
      for (int k = 0; k < 4; k++) tick();
      int rb[4] = {int(ram[0x500034] & 0xff), int(ram[0x500038] & 0xff), int(ram[0x502088] & 0xff), int(ram[0x50208c] & 0xff)};
      // (in the attract the demo player toggles P1's word 1 / 0 inside each
      // frame, 2 ms apart, so the dump may catch either; in a game the words
      // change only on an event)
      if (ram[0x500034] == 0x100)
      CHECK(rb[0] == x.b[0] && rb[1] == x.b[1] && rb[2] == x.b[2] && rb[3] == x.b[3],
            "%.3f: the log's RAM %02x %02x %02x %02x, the dump %02x %02x %02x %02x (log incomplete?)",
            x.t, rb[0], rb[1], rb[2], rb[3], x.b[0], x.b[1], x.b[2], x.b[3]);
      bool g = ram[0x500034] == 0x100 && (ram[0x500038] & 0xff) != 0;
      int want = (g && ram[0x502088] == 1) | ((g && ram[0x50208c] == 1) << 1);
      samples++;
      if (want & 1) in1++;
      if (want & 2) in2++;
      if (want != last) changes++;
      last = want;
      CHECK(d->play == unsigned(want), "%s %.3f: play %d want %d (mode %08x step %02x p1 %08x p2 %08x)",
            argv[s], x.t, d->play, want, ram[0x500034], ram[0x500038] & 0xff, ram[0x502088], ram[0x50208c]);
    }
  }
  printf("replayed %ld writes; %ld samples, P1 in play %ld, P2 in play %ld, %ld changes\n", nwrites, samples, in1, in2, changes);

  // ---------------------------------------------------------- directed
  d->rst_n = 0; tick(); d->rst_n = 1; tick();
  auto settle = [] { for (int k = 0; k < 4; k++) tick(); };
  bus(true, 0x500034, 0x00000100, 0xf); bus(true, 0x500038, 0x08080808, 0x1); bus(true, 0x50208c, 1, 0xf); settle();
  CHECK(d->play == 2, "directed: P2 in a game, step 8: play %d", d->play);
  bus(true, 0x500038, 0x00000000, 0x2); settle();          // lane 1 of the step word (0x500039) is not the step
  CHECK(d->play == 2, "directed: a write to 0x500039 changed the gate");
  bus(true, 0x500038, 0x00000000, 0x1); settle();          // test entry: step 0
  CHECK(d->play == 0, "directed: step 0 (test mode) must hide: play %d", d->play);
  bus(true, 0x500038, 0x09090909, 0x1); settle();
  CHECK(d->play == 2, "directed: step 9 again: play %d", d->play);
  bus(true, 0x500034, 0x01010101, 0x2); settle();          // a byte store of 1 to 0x500035 is still 0x100's lane
  CHECK(d->play == 2, "directed: stob 1 to 0x500035: play %d", d->play);
  bus(true, 0x500034, 0x00000300, 0xf); settle();          // two mode bits: not 0x100 (lane 1 compared whole)
  CHECK(d->play == 0, "directed: mode 0x300: play %d", d->play);
  bus(true, 0x500034, 0x00000100, 0xf); settle();
  CHECK(d->play == 2, "directed: mode 0x100 again: play %d", d->play);
  bus(true, 0x500034, 0x00000200, 0xf); settle();          // mode 0x200: not a game
  CHECK(d->play == 0, "directed: mode 0x200: play %d", d->play);
  bus(true, 0x500034, 0x00000100, 0xd); settle();          // lane 1 disabled: ignored
  CHECK(d->play == 0, "directed: mode write with lane 1 off: play %d", d->play);
  bus(true, 0x500034, 0x00000100, 0xf); settle();
  CHECK(d->play == 2, "directed: mode 0x100: play %d", d->play);
  bus(true, 0x500034, 0x00008000, 0xf); settle();          // results
  CHECK(d->play == 0, "directed: mode 0x8000: play %d", d->play);
  bus(true, 0x500034, 0x00000100, 0xf); bus(true, 0x50208c, 2, 0xf); settle();
  CHECK(d->play == 0, "directed: P2 at its countdown: play %d", d->play);
  bus(true, 0x50208c, 0x00000101, 0xf); settle();          // only lane 0's whole byte counts
  CHECK(d->play == 2, "directed: P2 word 0x101: lane 0 is 1: play %d", d->play);
  bus(true, 0x50208c, 0x00000011, 0xf); settle();
  CHECK(d->play == 0, "directed: P2 word 0x11 is not 1: play %d", d->play);
  bus(true, 0x502088, 1, 0xf); settle();
  CHECK(d->play == 1, "directed: P1 alone: play %d", d->play);
  d->test = 1; settle(); d->test = 0; settle();            // V2 ignores the Test button
  CHECK(d->play == 1, "directed: the Test button changed V2's state: play %d", d->play);
  d->en = 0; settle(); settle();
  CHECK(d->play == 0, "en low: play %d", d->play);

  printf("tb_m2_vcop2_state: %ld checks, %ld failures\n", checks, fails);
  printf(fails ? "FAIL\n" : "PASS\n");
  delete d;
  return fails ? 1 : 0;
}
