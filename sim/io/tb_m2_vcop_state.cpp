// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// m2_vcop_state (R849) against MAME's own record of Virtua Cop's state.
//
// Input, per scenario: MAME 0.289's log of every i960 write to the mode word
// (0x5016d4) and the two player words (0x50ee30 / 0x50ee34) -- time, address,
// data, mask -- and the state as MAME's work RAM holds it every 0.5 s (time,
// mode byte, P1 byte, P2 byte), both written by sim/io/mame_m2_vcop_play.lua. The writes are replayed on the module's
// bus, in order, between them random traffic the module must ignore (reads
// of the same words, writes to the neighbouring words, writes to the same
// words with lane 0 disabled); at each dump's time the module's {P2, P1}
// must equal what the dump says: mode byte == 7 and the player byte == 1 --
// except from a Test press to the next write of the mode word, the test
// screens, where MAME's RAM still says 7 (the snapshots show the test menu).
// Then en low: never in play.
//
// usage: Vm2_vcop_state <wlog.txt> <state.txt> [<wlog> <state>]...
#include "Vm2_vcop_state.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <random>

static Vm2_vcop_state* d;
static long fails = 0, checks = 0;
#define CHECK(c, ...) do { checks++; if (!(c)) { if (fails++ < 20) { printf("FAIL: " __VA_ARGS__); printf("\n"); } } } while (0)
static void tick() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }
static std::mt19937 rng(849);

static void bus(bool we, uint32_t a, uint32_t w, uint32_t be, bool ack = true) {
  d->bus_req = 1; d->bus_we = we; d->bus_ack = ack; d->bus_addr = a; d->bus_wdata = w; d->bus_be = be;
  tick();
  d->bus_req = 0; d->bus_we = 0; d->bus_ack = 0;
  d->bus_addr = rng(); d->bus_wdata = rng(); d->bus_be = rng() & 15;   // idle bus: junk
  tick();
}
static void noise() {
  static const uint32_t tg[3] = {0x5016d4, 0x50ee30, 0x50ee34};
  for (int k = rng() % 4; k > 0; k--) {
    uint32_t a = tg[rng() % 3];
    // (the targets are 4 apart, so "neighbours" are +-8 and other banks)
    uint32_t v = 0x01010101u * (rng() & 1 ? 7 : 1);
    switch (rng() % 7) {
      case 0: bus(false, a, v, 0xf); break;                                   // a read of it
      case 1: bus(true, a + 8, v, 0xf); break;                                // a word after
      case 2: bus(true, a - 8, v, 0xf); break;                                // a word before
      case 3: bus(true, a, v ^ (rng() << 8), 0xe); break;                     // lane 0 off
      case 4: bus(true, a, v, 0xf, false); break;                             // not acknowledged
      case 5: bus(true, a ^ (1u << (16 + rng() % 16)), v, 0xf); break;        // another 64 KB
      case 6: bus(true, a ^ (1u << (3 + rng() % 13)), v, 0xf); break;         // one address bit off (bit 2 is the other player)
    }
  }
}
struct W { double t; uint32_t a, data, mask; bool test; };

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_vcop_state;
  if (argc < 3) { printf("usage: %s <wlog.txt> <state.txt> [...]\n", argv[0]); return 2; }
  for (int s = 1; s + 1 < argc; s += 2) {
    const char* wl = argv[s]; const char* rb = argv[s + 1];
    std::vector<W> ws;
    FILE* f = fopen(wl, "r");
    if (!f) { printf("no %s\n", wl); return 2; }
    char line[256];
    while (fgets(line, sizeof line, f)) {
      W w; char nm[16];
      if (sscanf(line, "%lf %15s %x data %x mask %x", &w.t, nm, &w.a, &w.data, &w.mask) == 5) {
        w.test = !strcmp(nm, "test");
        ws.push_back(w);
      }
    }
    fclose(f);
    FILE* r = fopen(rb, "r");
    if (!r) { printf("no %s\n", rb); return 2; }
    d->rst_n = 0; d->en = 1; d->test = 0; d->bus_req = 0; d->bus_we = 0; d->bus_ack = 0; tick(); tick();
    d->rst_n = 1; tick();
    size_t wi = 0; long samples = 0, inplay[2] = {0, 0}, mism = 0;
    int last_exp = -1, changes = 0;
    bool texp = false, tin = false; long tgated = 0;   // the test latch, modelled from the log
    double ts; int mode, p1, p2;
    while (fgets(line, sizeof line, r)) {
      if (sscanf(line, "%lf %x %x %x", &ts, &mode, &p1, &p2) != 4) continue;
      while (wi < ws.size() && ws[wi].t <= ts) {
        uint32_t be = 0;
        for (int b = 0; b < 4; b++) if ((ws[wi].mask >> (8 * b)) & 0xff) be |= 1u << b;
        if (ws[wi].test) {                       // the Test button, from the scenario
          tin = ws[wi].data & 1; d->test = tin; if (tin) texp = true;
          tick(); tick();
        } else {
          noise();
          bus(true, ws[wi].a, ws[wi].data, be);
          if (ws[wi].a == 0x5016d4 && (be & 1) && !tin) texp = false;
        }
        wi++;
      }
      for (int k = 0; k < 4; k++) tick();
      int exp = ((mode == 7 && p2 == 1) << 1) | (mode == 7 && p1 == 1);
      if (texp && exp) { tgated++; exp = 0; }    // test screens: mode still 7 in RAM
      samples++;
      if (exp & 1) inplay[0]++;
      if (exp & 2) inplay[1]++;
      if (exp != last_exp) { changes++; last_exp = exp; }
      if (int(d->play) != exp) mism++;
      CHECK(int(d->play) == exp, "%s t=%.3f: play %d, MAME mode %02x P1 %02x P2 %02x -> %d",
            wl, ts, d->play, mode, p1, p2, exp);
    }
    fclose(r);
    printf("%s: %zu writes replayed, %ld samples, P1 in play %ld, P2 in play %ld, %ld hidden by test mode, %d changes, %ld mismatches\n",
           wl, ws.size(), samples, inplay[0], inplay[1], tgated, changes, mism);
    // directed: only lane 0's whole byte counts, of a write with lane 0 on
    {
      struct { uint32_t a, v, be; int want; } dv[] = {
        {0x5016d4, 0x07, 1, -1}, {0x50ee30, 0x01, 1, -1}, {0x50ee34, 0x01, 1, 3},
        {0x5016d4, 0x0f, 1, 0}, {0x5016d4, 0x87, 1, 0}, {0x5016d4, 0x17, 1, 0},
        {0x5016d4, 0x0707, 1, 3}, {0x5016d4, 0x0000, 0xe, 3},                // lane 0 off: kept
        {0x50ee30, 0x81, 1, 2}, {0x50ee30, 0x11, 1, 2}, {0x50ee30, 0x0101, 1, 3},
        {0x50ee34, 0x02, 1, 1}, {0x50ee34, 0x03, 1, 1}, {0x50ee34, 0x01, 0xf, 3},
        {0x5016d4, 0x0c, 0xf, 0}, {0x5016d4, 0x07, 0xf, 3},
      };
      bool tsav = d->test; d->test = 0; tick(); tick();
      d->rst_n = 0; tick(); d->rst_n = 1; tick();
      for (auto& x : dv) {
        bus(true, x.a, x.v | (x.v << 16), x.be);
        for (int k = 0; k < 3; k++) tick();
        if (x.want >= 0) CHECK(int(d->play) == x.want, "directed write %06x=%x be %x: play %d want %d", x.a, x.v, x.be, d->play, x.want);
      }
      // the test latch: Test, then in play only after a mode write with Test up
      d->test = 1; tick(); tick(); tick();
      CHECK(d->play == 0, "test held: play %d", d->play);
      bus(true, 0x5016d4, 0x07, 1); tick(); tick();
      CHECK(d->play == 0, "mode written while Test held: play %d", d->play);
      d->test = 0; tick(); tick(); tick();
      CHECK(d->play == 0, "Test released, no mode write yet: play %d", d->play);
      bus(true, 0x5016d4, 0x07, 1); tick(); tick(); tick();
      CHECK(d->play == 3, "mode written after Test: play %d", d->play);
      d->test = tsav;
    }
    // en low: the same traffic leaves it out of play
    d->en = 0;
    for (int k = 0; k < 4; k++) tick();
    CHECK(d->play == 0, "en low: play %d", d->play);
    for (size_t i = 0; i < ws.size() && i < 20000; i++) { bus(true, ws[i].a, ws[i].data, 0xf); CHECK(d->play == 0, "en low: play %d", d->play); }
  }
  printf("tb_m2_vcop_state: %ld checks, %ld failures\n", checks, fails);
  printf(fails ? "FAIL\n" : "PASS\n");
  delete d;
  return fails ? 1 : 0;
}
