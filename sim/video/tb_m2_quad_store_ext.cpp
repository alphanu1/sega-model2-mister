// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R1003: m2_quad_store's replay with the payload outside (EXT_PAY), against
// the same store with it on chip. ONE STIMULUS, TWO BUILDS: this file is
// built at the 2C store's parameters with EXT_PAY 0 and with EXT_PAY 1
// (-DQS_EXT), and each prints one STREAM line per band replayed -- the count
// and a hash of every field of every quad the store hands over, in order. The
// test target diffs the two outputs: the backing must change nothing a
// consumer can see.
//
// The EXT build's backing is a model of m2_ddram_payload's contract, made
// unkind: a read answered 1..LMAX cycles later (in order), a credit of DEPTH,
// UNWRITTEN SLOTS READ 0xFFFF..., the take a register. It counts a request
// arriving with the credit spent (the store's contract says never).
//
// What the stimulus covers:
//   - lists from 1 quad to past NQ + NX (2,560): the spill into the other
//     bank's top (R962), the refusal past it, and back-to-back collection
//   - a consumer that stalls 0%, 50% and 90% of the time (Model 1's 9c05b79
//     lesson: a store bench that takes every quad at once cannot see a quad
//     dropped while the output holds it)
//   - gaps of 0..400 cycles between bands, so the one-band lookahead finishes
//     its scan early, late, or not at all before the band starts
//   - a START FOR ANOTHER BAND while the lookahead holds quads (the R653
//     self-test can swap a list mid-draw): band 0 again after band k, which
//     the EXT store must answer by dropping the lookahead's quads unseen.
// Quads are made here from a seeded generator; nothing comes from a ROM.
#include "Vm2_quad_store.h"
#include "Vm2_quad_store___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <deque>
#include <map>
#include <array>
#include <cstdlib>
#include <vector>

static const int NQ = 2048, NX = 512, NBANDS = 48, BAND_H = 8, DEPTH = 16;
static const int PWW = 10;                     // 304 payload bits in 32-bit words
static Vm2_quad_store *d;
static uint64_t rng = 0x1003;
static uint32_t rnd() { rng = rng * 6364136223846793005ull + 1442695040888963407ull; return uint32_t(rng >> 33); }
// the quads' own generator: the two builds must see the same quads, and only
// the EXT build draws latencies from rnd()
static uint64_t qrng = 0x51ce;
static uint32_t qrnd() { qrng = qrng * 6364136223846793005ull + 1442695040888963407ull; return uint32_t(qrng >> 33); }
static long cyc = 0, refused = 0, unwritten = 0;

// ---- the EXT backing (unused, and tied off, in the on-chip build)
using Pay = std::array<uint32_t, PWW>;
static std::map<uint32_t, Pay> pmem;
struct Rep { long due; Pay p; };
static std::deque<Rep> pend;   // accepted, in order; valid once due
static int credit = 0, LMAX = 60;

static void drive_backing() {
#ifdef QS_EXT
  d->ext_ready = credit < DEPTH;
  bool v = !pend.empty() && pend.front().due <= cyc;
  d->ext_valid = v;
  for (int i = 0; i < PWW; i++) d->ext_rdata[i] = v ? pend.front().p[i] : 0;
#else
  d->ext_ready = 0; d->ext_valid = 0;
  for (int i = 0; i < PWW; i++) d->ext_rdata[i] = 0;
#endif
}
// What this cycle did, seen before the edge.
static void sample_backing() {
#ifdef QS_EXT
  if (d->ext_we) { Pay p; for (int i = 0; i < PWW; i++) p[i] = d->ext_wdata[i]; pmem[(uint32_t(d->ext_wbank) << 11) | d->ext_waddr] = p; }
  if (d->ext_take && d->ext_valid) { pend.pop_front(); credit--; }
  if (d->ext_req) {
    if (!d->ext_ready) refused++;
    else {
      auto it = pmem.find((uint32_t(d->ext_rbank) << 11) | d->ext_raddr);
      Pay p; if (it == pmem.end()) { p.fill(0xFFFFFFFFu); unwritten++; } else p = it->second;
      long due = cyc + 1 + long(rnd() % LMAX);
      if (!pend.empty() && pend.back().due >= due) due = pend.back().due + 1;
      pend.push_back({due, p}); credit++;
    }
  }
#endif
}
static long drops = 0, aheads = 0;
static void watch() {   // the lookahead's starts and drops, rising edges
#ifdef QS_EXT
  static bool pd = false, pa = false;
  bool dr = d->rootp->m2_quad_store__DOT__g_emit_ext__DOT__drop, la = d->rootp->m2_quad_store__DOT__g_emit_ext__DOT__la;
  if (dr && !pd) drops++;
  if (la && !pa) aheads++;
  pd = dr; pa = la;
#endif
}
static void tick() {
  drive_backing(); d->clk = 0; d->eval();
  sample_backing(); watch();
  d->clk = 1; d->eval(); cyc++;
}

// ---- the stream hash: every output field
static uint64_t h;
static void hadd(uint64_t v) { for (int i = 0; i < 8; i++) { h ^= (v >> (8 * i)) & 0xff; h *= 1099511628211ull; } }
static void hquad() {
  static const bool DUMP = std::getenv("QS_DUMP") != nullptr;
  if (DUMP) std::printf("Q x %d %d %d %d y %d %d %d %d col %06x m %d mz %d vx %d fr %04x uv %d %d %d %d %d %d %d %d oz %04x %04x %04x %04x tex %08x\n",
    (int)(int16_t)d->out_x0, (int)(int16_t)d->out_x1, (int)(int16_t)d->out_x2, (int)(int16_t)d->out_x3,
    (int)(int16_t)d->out_y0, (int)(int16_t)d->out_y1, (int)(int16_t)d->out_y2, (int)(int16_t)d->out_y3,
    (unsigned)d->out_col, (int)d->out_moire, (int)d->out_mipz, (int)d->out_vx, (unsigned)d->out_frac,
    (int)d->out_u0, (int)d->out_v0, (int)d->out_u1, (int)d->out_v1, (int)d->out_u2, (int)d->out_v2, (int)d->out_u3, (int)d->out_v3,
    (unsigned)d->out_oz0, (unsigned)d->out_oz1, (unsigned)d->out_oz2, (unsigned)d->out_oz3, (unsigned)d->out_tex);
  hadd(uint64_t(uint16_t(d->out_x0)) | uint64_t(uint16_t(d->out_y0)) << 16 | uint64_t(uint16_t(d->out_x1)) << 32 | uint64_t(uint16_t(d->out_y1)) << 48);
  hadd(uint64_t(uint16_t(d->out_x2)) | uint64_t(uint16_t(d->out_y2)) << 16 | uint64_t(uint16_t(d->out_x3)) << 32 | uint64_t(uint16_t(d->out_y3)) << 48);
  hadd(uint64_t(d->out_col) | uint64_t(d->out_moire) << 24 | uint64_t(d->out_mipz) << 25 | uint64_t(d->out_vx) << 26 | uint64_t(d->out_frac) << 32);
  hadd(uint64_t(d->out_u0) | uint64_t(d->out_v0) << 13 | uint64_t(d->out_u1) << 26 | uint64_t(d->out_v1) << 39);
  hadd(uint64_t(d->out_u2) | uint64_t(d->out_v2) << 13 | uint64_t(d->out_u3) << 26 | uint64_t(d->out_v3) << 39);
  hadd(uint64_t(d->out_oz0) | uint64_t(d->out_oz1) << 16 | uint64_t(d->out_oz2) << 32 | uint64_t(d->out_oz3) << 48);
  hadd(uint64_t(d->out_tex));
}

static void new_list() {
  d->in_valid = 0; tick();
  d->wbank = !d->wbank; d->rbank = !d->wbank;
  d->clear = 1; tick(); d->clear = 0; tick();
}
static void push_list(int n) {
  for (int i = 0; i < n; i++) {
    // a quad 1..60 px across somewhere on (and a little off) the screen
    int x = int(qrnd() % 560) - 32, y = int(qrnd() % 440) - 28, w = 1 + qrnd() % 60, hh = 1 + qrnd() % 60;
    d->in_x0 = x; d->in_y0 = y; d->in_x1 = x + w; d->in_y1 = y + (qrnd() % 3);
    d->in_x2 = x + w - (qrnd() % 4); d->in_y2 = y + hh; d->in_x3 = x + (qrnd() % 4); d->in_y3 = y + hh - (qrnd() % 3);
    // every input masked to its port's width: Verilator does not mask inputs,
    // and stray high bits are read differently by the two builds
    d->in_col = qrnd() & 0xFFFFFF; d->in_z = qrnd() & 0xFFFFF; d->in_moire = qrnd() & 1;
    d->in_u0 = qrnd() & 0x1FFF; d->in_v0 = qrnd() & 0x1FFF; d->in_u1 = qrnd() & 0x1FFF; d->in_v1 = qrnd() & 0x1FFF;
    d->in_u2 = qrnd() & 0x1FFF; d->in_v2 = qrnd() & 0x1FFF; d->in_u3 = qrnd() & 0x1FFF; d->in_v3 = qrnd() & 0x1FFF;
    d->in_oz0 = qrnd() & 0xFFFF; d->in_oz1 = qrnd() & 0xFFFF; d->in_oz2 = qrnd() & 0xFFFF; d->in_oz3 = qrnd() & 0xFFFF;
    d->in_frac = qrnd() & 0xFFFF; d->in_tex = qrnd() & 0xFFFFFFF; d->in_vx = qrnd() & 7; d->in_mipz = qrnd() & 1;
    d->in_valid = 1;
    long g = 0; do { tick(); } while (d->in_stall && g++ < 100000);   // a held quad is presented again
    d->in_valid = 0;
  }
  for (int k = 0; k < 4; k++) tick();
}
static void sort() {
  d->sort_start = 1; tick(); d->sort_start = 0;
  long g = 0; while (d->sort_busy && g++ < 2000000) tick();
}
// Replay one band; stall_pc per cent of cycles the consumer is not ready.
static int replay(int list, int b, int stall_pc, bool print) {
  d->replay_band = b; d->replay_ahead = (b != NBANDS - 1);
  d->replay_start = 1; d->out_ready = 0; tick(); d->replay_start = 0;
  h = 1469598103934665603ull; int n = 0; long g = 0;
  for (;;) {
    d->out_ready = int(rnd() % 100) >= stall_pc;
    drive_backing(); d->clk = 0; d->eval();
    if (d->out_valid && d->out_ready) { hquad(); n++; }
    bool busy = d->replay_busy || d->out_valid;
    sample_backing(); watch(); d->clk = 1; d->eval(); cyc++;
    if (!busy) break;
    if (++g > 2000000) { std::printf("STUCK list %d band %d\nFAIL\n", list, b); std::exit(1); }
  }
  d->out_ready = 0;
  if (print) std::printf("STREAM list %d band %2d: %4d quads %016llx\n", list, b, n, (unsigned long long)h);
  // the drain the raster3d waits for after the store goes idle
  int gap = (rnd() % 4 == 0) ? 0 : int(rnd() % 400);
  for (int k = 0; k < gap; k++) tick();
  return n;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_quad_store;
  d->clk = 0; d->rst_n = 0; d->clear = 0; d->wbank = 0; d->rbank = 1; d->ofree = 1;
  d->in_valid = 0; d->sort_start = 0; d->replay_start = 0; d->replay_band = 0; d->replay_ahead = 0; d->out_ready = 0;
  for (int k = 0; k < 4; k++) tick();
  d->rst_n = 1; tick();
#ifdef QS_EXT
  std::printf("  EXT_PAY: backing latency 1..%d, credit %d\n", LMAX, DEPTH);
#endif
  const int sizes[] = {1, 37, 700, 2047, 2048, 2049, 2300, 2560, 3100, 1500};
  const int stalls[] = {0, 50, 90};
  long total = 0;
  for (int li = 0; li < int(sizeof sizes / sizeof sizes[0]); li++) {
    new_list();
    push_list(sizes[li]);
    sort();
    new_list();   // the sorted list becomes the replay bank, as the swap does
    std::printf("LIST %d: %d pushed, %u stored, %u dropped\n", li, sizes[li], (unsigned)d->rootp->m2_quad_store__DOT__count[d->rbank], 0u);
    const int st = stalls[li % 3];
    if (li % 2 == 1) {
      // a start for another band while the lookahead holds quads: band 0
      // again after band 3 (its lookahead scanned band 4)
      for (int b = 0; b <= 3; b++) total += replay(li, b, st, true);
      std::printf("  restart at band 0 (the lookahead held band 4)\n");
#ifdef QS_EXT
      std::printf("  at the restart: la %d s_band %d cfill %d sc_run %d\n", (int)d->rootp->m2_quad_store__DOT__g_emit_ext__DOT__la,
                  (int)d->rootp->m2_quad_store__DOT__s_band, (int)d->rootp->m2_quad_store__DOT__g_emit_ext__DOT__cfill,
                  (int)d->rootp->m2_quad_store__DOT__sc_run);
#endif
    }
    for (int b = 0; b < NBANDS; b++) total += replay(li, b, st, true);
  }
  std::printf("TOTAL %ld quads handed\n", total);
#ifdef QS_EXT
  std::printf("  backing: %ld requests refused (must be 0), %ld unwritten slots read, %zu replies left (must be 0); lookaheads %ld, dropped %ld\n",
              refused, unwritten, pend.size(), aheads, drops);
  if (!drops || !aheads) { std::printf("FAIL: the lookahead or its drop was never exercised\n"); return 1; }
  if (refused || !pend.empty()) { std::printf("FAIL\n"); return 1; }
#endif
  std::printf("PASS\n");
  delete d;
  return 0;
}
