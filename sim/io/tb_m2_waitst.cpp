// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R904: m2_waitst against a model of the bridge's registered acknowledge.
//   * en low: every cycle b_req == c_req, c_ack == b_ack, c_rdata == b_rdata.
//   * the block: Sega Rally's table written by the CPU (byte lanes too), read
//     back; the bridge never sees an access to it.
//   * per region, swept over the bridge's latency 1..64 cycles and gaps of
//     0..3 idle cycles: MIN  total = max(2 + N, bridge), a burst's next word
//     max(1 + N, bridge); EXTRA total = N + bridge. Every answer's data is the
//     bridge's for that address, and the bridge starts exactly once per access.
// Built three ways (Makefile): ONEHOT=1 EXTRA=0 (the default), ONEHOT=1
// EXTRA=1, ONEHOT=0 EXTRA=0 -- the counts each expects follow the parameters.
#include "Vm2_waitst.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>
#include <algorithm>

#ifndef P_ONEHOT
#define P_ONEHOT 1
#endif
#ifndef P_EXTRA
#define P_EXTRA 0
#endif

static Vm2_waitst *t;
static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { if (fails < 20) { printf("FAIL: " __VA_ARGS__); printf("\n"); } fails++; } } while (0)

// the bridge model: registered ack, `lat` cycles from the cycle it takes the
// request to the cycle its ack is up (1 = the line buffer's answer); a write is
// acknowledged at once (posted) and keeps the bridge busy `lat` more cycles.
struct Dev {
  int busy = 0, ack = 0, starts = 0, post = 0;
  uint32_t rdata = 0, addr = 0;
  int lat = 1;
} dev;
static uint32_t dev_data(uint32_t a) { return a * 2654435761u ^ 0x5a5a1234u; }

struct Acc { uint32_t addr; int we; int be; uint32_t wdata; int gap; };
static int cyc_total = 0;
static bool en_check = false;   // en low: the pass-through checks

// run a list of accesses; returns the cycles each took (first shown .. ack)
static std::vector<int> run(const std::vector<Acc> &v, std::vector<uint32_t> *rd = nullptr) {
  std::vector<int> out;
  // the bridge finishes what it had (a posted write) before the list starts
  while (dev.ack || dev.busy || dev.post) {
    t->clk = 0; t->c_req = 0; t->b_ack = dev.ack; t->b_rdata = dev.rdata; t->eval();
    t->clk = 1; t->eval();
    if (dev.ack) dev.ack = 0; else if (dev.post) dev.post--; else if (dev.busy && --dev.busy == 0) { dev.ack = 1; dev.rdata = dev_data(dev.addr); }
  }
  size_t i = 0; int shown = 0, idle = v.empty() ? 0 : v[0].gap;
  int guard = 0;
  while (i < v.size()) {
    if (++guard > 1000000) { CHECK(false, "hang at access %zu addr %08x", i, v[i].addr); break; }
    bool req = (idle == 0);
    const Acc &a = v[i];
    t->clk = 0;
    t->c_req = req; t->c_we = a.we; t->c_addr = a.addr; t->c_be = a.be; t->c_wdata = a.wdata;
    t->b_ack = dev.ack; t->b_rdata = dev.rdata;
    t->eval();
    int c_ack = t->c_ack, b_req = t->b_req;
    uint32_t c_rd = t->c_rdata;
    if (en_check) {
      CHECK(b_req == (int)req, "pass-through b_req");
      CHECK(c_ack == dev.ack, "pass-through c_ack");
      CHECK(c_rd == dev.rdata, "pass-through c_rdata");
    }
    // the bridge's next state
    int nack = 0, nbusy = dev.busy, npost = dev.post; uint32_t nrd = dev.rdata;
    if (dev.ack) { /* the pulse ends; C_IDLE ignores a request while ack is up */ }
    else if (dev.post) { npost = dev.post - 1; }
    else if (dev.busy) { nbusy = dev.busy - 1; if (nbusy == 0) { nack = 1; nrd = dev_data(dev.addr); } }
    else if (b_req) {
      dev.starts++; dev.addr = a.addr;
      if (a.we) { nack = 1; npost = dev.lat; }
      else if (dev.lat == 1) { nack = 1; nrd = dev_data(a.addr); }
      else nbusy = dev.lat - 1;
    }
    t->clk = 1; t->eval();
    dev.ack = nack; dev.busy = nbusy; dev.post = npost; dev.rdata = nrd;
    cyc_total++;
    if (req) {
      if (c_ack) {
        out.push_back(shown + 1);
        if (rd) rd->push_back(c_rd);
        else if (!a.we && !(a.addr >= 0x00e00000 && a.addr < 0x00e00038))
          CHECK(c_rd == dev_data(a.addr), "data %08x at %08x (want %08x)", c_rd, a.addr, dev_data(a.addr));
        shown = 0; i++;
        idle = (i < v.size()) ? v[i].gap : 0;
      } else shown++;
    } else idle--;
  }
  return out;
}

static const uint32_t rally[14] = {0x10, 0x02, 0x42, 0x02, 0x10, 0x10, 0x10, 0x10, 0x08, 0x10, 0x10, 0x10, 0x10, 0x10};
static int count_of(uint32_t v) {
  if (!P_ONEHOT) return v & 0x3f;
  for (int b = 0; b < 6; b++) if (v & (1u << b)) return b;
  return 0;
}
struct Reg { uint32_t addr; int word; };
static const Reg regs[] = {
  {0x00001000, 0}, {0x00201000, 1}, {0x00501000, 2}, {0x00901000, 3}, {0x00800010, 4},
  {0x00884000, 5}, {0x00980004, 5}, {0x00e80000, 6}, {0x00f00004, 6}, {0x01000100, 7},
  {0x01080100, 7}, {0x02001000, 8}, {0x06001000, 8}, {0x01800100, 9}, {0x01810100, 9},
  {0x01a00100, 10}, {0x01c00000, 11}, {0x01d00010, 11}, {0x10000000, 12}, {0x12000100, 13},
  {0x12800100, 13}, {0x20000000, -1},
};

static void program(const uint32_t tab[14]) {
  std::vector<Acc> v;
  for (int k = 0; k < 14; k++) v.push_back({0x00e00000u + 4u * k, 1, 0xf, tab[k], 0});
  run(v);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  t = new Vm2_waitst;
  t->clk = 0; t->rst_n = 0; t->en = 0; t->eval();
  t->clk = 1; t->eval(); t->clk = 0; t->rst_n = 1; t->eval();

  // ---- 1. en low: a pure pass-through, whatever the traffic
  en_check = true;
  int starts0 = dev.starts;
  for (int lat = 1; lat <= 40; lat += 3) {
    dev.lat = lat;
    std::vector<Acc> v;
    for (auto &r : regs) for (int g = 0; g < 3; g++) v.push_back({r.addr + 4u * g, g == 1, 0xf, 0x11u * g, g});
    for (int k = 0; k < 14; k++) v.push_back({0x00e00000u + 4u * k, k & 1, 0xf, 0x77u, 0});
    run(v);
  }
  printf("en low: pass-through checked every cycle, %d bridge starts, %d fails\n", dev.starts - starts0, fails);
  en_check = false;

  // ---- 2. en high: the block
  t->en = 1;
  int st = dev.starts;
  dev.lat = 5;
  program(rally);
  // a byte-lane write: word 13 byte 2 only, then read every word back
  run({{0x00e00034, 1, 0x4, 0xaabbccdd, 0}});
  std::vector<Acc> rv;
  for (int k = 0; k < 14; k++) rv.push_back({0x00e00000u + 4u * k, 0, 0xf, 0, 1});
  std::vector<uint32_t> back;
  run(rv, &back);
  for (int k = 0; k < 14; k++) {
    uint32_t want = (k == 13) ? (0x00bb0000u | rally[13]) : rally[k];
    CHECK(back[k] == want, "read-back word %d %08x want %08x", k, back[k], want);
  }
  CHECK(dev.starts == st, "the bridge saw %d block accesses", dev.starts - st);
  printf("block: 14 words written, a byte lane, read back; bridge starts during it %d, fails %d\n", dev.starts - st, fails);
  run({{0x00e00034, 1, 0xf, rally[13], 0}});   // restore

  // ---- 3. the waits, per region, swept over latency and gap
  printf("region    addr      N   lat:1    2    4    8   16   32   64   (cycles an access, MIN %s)\n", P_EXTRA ? "off: EXTRA" : "on");
  for (auto &r : regs) {
    int n = (r.word < 0) ? 0 : count_of(rally[r.word]);
    printf("%-6d %08x  %2d  ", r.word, r.addr, n);
    for (int lat = 1; lat <= 64; lat++) {
      dev.lat = lat;
      for (int gap = 0; gap < 4; gap++) {
        for (int we = 0; we < 2; we++) {
          int s0 = dev.starts;
          // a single access, then a four-word burst (back to back in one line)
          std::vector<Acc> v = {{r.addr + 0x100, we, 0xf, 1, gap},
                                {(r.addr & ~0xfu) + 0x200, we, 0xf, 1, gap}, {(r.addr & ~0xfu) + 0x204, we, 0xf, 1, 0},
                                {(r.addr & ~0xfu) + 0x208, we, 0xf, 1, 0}, {(r.addr & ~0xfu) + 0x20c, we, 0xf, 1, 0}};
          auto c = run(v);
          CHECK(dev.starts - s0 == 5, "starts %d for 5 accesses", dev.starts - s0);
          // the bridge's own time: a read lat + 1 cycles; a posted write 2
          // (its busy time delays only the access after it)
          for (size_t k = 0; k < c.size(); k++) {
            int brg = we ? 2 : lat + 1;
            bool cont = (k >= 2);
            // a write after a write: the posted one keeps the bridge busy
            int gk = (k < 2) ? gap : 0;
            if (we && k >= 1 && gk < lat) brg = -1;   // not a fixed number; checked as >= below
            int want;
            if (P_EXTRA) want = (brg < 0) ? -1 : n + brg;
            else want = (brg < 0) ? -1 : std::max(cont ? 1 + n : 2 + n, brg);
            int floor_ = P_EXTRA ? n + 2 : (cont ? 1 + n : 2 + n);
            if (want >= 0) CHECK(c[k] == want, "region %d addr %08x lat %d gap %d we %d word %zu: %d cycles, want %d",
                                 r.word, r.addr, lat, gap, we, k, c[k], want);
            else CHECK(c[k] >= floor_, "region %d lat %d gap %d write %zu: %d cycles under %d", r.word, lat, gap, k, c[k], floor_);
          }
          if (gap == 0 && we == 0 && (lat == 1 || lat == 2 || lat == 4 || lat == 8 || lat == 16 || lat == 32 || lat == 64))
            printf("%4d/%-2d", c[0], c[3]);
        }
      }
    }
    printf("\n");
  }
  printf("(each cell: a single read / a burst's later word)\n");

  // ---- 4. large counts: binary 0x3f in every word (ONEHOT=0) or 0x20 (ONEHOT=1)
  uint32_t big[14];
  for (int k = 0; k < 14; k++) big[k] = P_ONEHOT ? 0x20 : 0x3f;
  program(big);
  dev.lat = 1;
  for (auto &r : regs) {
    int n = (r.word < 0) ? 0 : count_of(big[r.word]);
    auto c = run({{r.addr, 0, 0xf, 0, 0}});
    int want = P_EXTRA ? n + 2 : 2 + n;
    CHECK(c[0] == want, "big: region %d %d cycles want %d", r.word, c[0], want);
  }
  printf("large counts (%s): every region %d cycles at the bridge's fastest\n", P_ONEHOT ? "0x20" : "0x3f",
         P_EXTRA ? count_of(big[0]) + 2 : 2 + count_of(big[0]));

  printf("%s: %d fails, %d cycles\n", fails ? "FAIL" : "PASS", fails, cyc_total);
  delete t;
  return fails ? 1 : 0;
}
