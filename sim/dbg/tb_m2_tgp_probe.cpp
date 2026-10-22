// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// tb_m2_tgp_probe -- R923's TGP hang probe, end to end through its UART.
//
// The probe is built with a fast UART (DIVISOR 8) and FREEZE_BIT 12, and fed:
//   1. 700 i960 transfers of all four kinds with copro_stall raised in short
//      bursts under the freeze threshold (the ring must stay live, the longest
//      hold must be recorded);
//   2. copro_stall held: the ring must freeze once 2^12 cycles have passed;
//   3. 300 more transfers after the freeze, which must NOT enter the ring.
// The UART is decoded line by line and checked: every 'r' entry of a frozen
// pass against the 256 transfers before the freeze (index, order, kind, word,
// vblank count), the write index, and every state record against what was
// driven. The lines are written to argv[1] (default tgp_probe.uart) for
// tools/decode_tgp.py.
//
// Planted faults (each must FAIL): TB_FAULT=1 the ring keeps writing after
// the freeze (the bench model, not the RTL: the check must see it), set by
// the environment.

#include "Vm2_tgp_probe.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <map>

static Vm2_tgp_probe *d;
static const int DIV = 8;
static std::string line;
static std::vector<std::string> lines;
static uint64_t cyc = 0;

static void rx_sample() {
  static int state = 0, cnt = 0, biti = 0;
  static uint8_t sh = 0;
  if (state == 0) {
    if (!d->tx) { state = 1; cnt = DIV / 2; }
  } else if (--cnt <= 0) {
    if (state == 1) { state = 2; biti = 0; sh = 0; cnt = DIV; }
    else if (state == 2) {
      sh = uint8_t((sh >> 1) | (d->tx ? 0x80 : 0x00));
      if (++biti == 8) state = 3;
      cnt = DIV;
    } else {
      if (sh == '\n') { lines.push_back(line); line.clear(); }
      else if (sh != '\r') line.push_back(char(sh));
      state = 0;
    }
  }
}

static const int PT = 800;        // prof_tick period
static const int VBL = 40000;     // a "vblank" every VBL cycles
static int vbl_count = 0;

static void tick() {
  d->prof_tick = (cyc % PT) == 0;
  d->vbl_edge = (cyc % VBL) == VBL - 1;
  d->clk = 0; d->eval();
  d->clk = 1; d->eval();
  if (d->vbl_edge) ++vbl_count;
  rx_sample();
  ++cyc;
}

struct X { int kind; uint32_t w; int vbl; };

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const char *out = (argc > 1 && argv[1][0] != '+') ? argv[1] : "tgp_probe.uart";
  const bool fault = std::getenv("TB_FAULT") && std::atoi(std::getenv("TB_FAULT")) == 1;
  d = new Vm2_tgp_probe;
  // the state inputs: distinctive constants
  d->cpu_ip = 0x00007dc4; d->cpu_trap = 0; d->cpu_halted = 0;
  d->cpu_io_sel = 1; d->cpu_io_we = 0; d->cpu_io_addr = 0x884000;
  d->copro_stall = 0; d->tgp_unimpl = 0; d->tgp_pc = 0x0035;
  d->copro_fifo = 0x28800500u; d->tgp_hs = 0x98008400u;
  d->in_pushed = 0x1234; d->in_popped = 0x1230; d->out_pushed = 0x0aaa; d->out_popped = 0x0aaa;
  d->push_data = 0x11111111u; d->pop_data = 0x22222222u; d->out_data = 0x33333333u;
  d->out_refused = 0; d->in_dropped = 0; d->tgp_io_addr = 0x8010; d->tgp_retires = 0x4321;
  d->tgp_op = 0x1c1f2621u; d->tgp_bank = 0x40;
  d->xfer = 0; d->xfer_kind = 0; d->xfer_data = 0;
  d->rst_n = 0;
  for (int i = 0; i < 8; ++i) tick();
  d->rst_n = 1;

  std::vector<X> ring;              // what the RTL should hold, in order
  int fails = 0;
  uint32_t n = 0;
  int maxhold = 0;
  auto xfer = [&](bool counts) {
    const int kind = (n % 4 == 3) ? 2 : (n % 7 == 0) ? 1 : (n % 97 == 5) ? 3 : 0;
    const uint32_t w = 0xA5000000u ^ (n * 0x9E3779B1u);
    d->xfer = 1; d->xfer_kind = kind; d->xfer_data = w;
    const int v = vbl_count;
    tick();
    d->xfer = 0;
    if (counts || fault) ring.push_back({kind, w, v});
    ++n;
  };
  // 1. live, with short stalls
  for (int k = 0; k < 700; ++k) {
    xfer(true);
    for (int g = 0; g < 37 + (k * 13) % 200; ++g) tick();
    if (k % 50 == 25) {
      const int len = 300 + 31 * k;   // under 2^12
      const int l = len < 4000 ? len : 4000;
      d->copro_stall = 1;
      for (int g = 0; g < l; ++g) tick();
      d->copro_stall = 0;
      if (l > maxhold) maxhold = l;
      tick();
    }
  }
  if (d->frozen) { std::printf("  FAIL: frozen by stalls under the threshold\n"); ++fails; }
  // 2. the hang
  d->copro_stall = 1;
  for (int g = 0; g < 5000; ++g) tick();
  if (!d->frozen) { std::printf("  FAIL: not frozen after 5000 cycles held\n"); ++fails; }
  // 3. transfers after the freeze must not enter
  for (int k = 0; k < 300; ++k) { xfer(false); tick(); tick(); }
  // let the ring go round twice
  for (uint64_t g = 0; g < 2ull * 256 * 2 * 3 * PT + 20000; ++g) tick();

  FILE *f = std::fopen(out, "w");
  for (auto &l : lines) std::fprintf(f, "%s\n", l.c_str());
  std::fclose(f);

  // ---- check
  std::map<char, int> nrec;
  std::map<int, std::pair<uint32_t, uint32_t>> ent;   // frozen ring entries
  int frozen_wp = -1, bad = 0;
  for (auto &l : lines) {
    char t; unsigned a, b;
    if (l.size() != 19 || std::sscanf(l.c_str(), "%c %8x %8x", &t, &a, &b) != 3) { ++bad; continue; }
    ++nrec[t];
    switch (t) {
      case 'r':
        if (a >> 31) { ent[(a >> 8) & 0xff] = {a & 0xff, b}; frozen_wp = (a >> 16) & 0xff; }
        break;
      case 'C':
        if (a != 0x7dc4 || (b & 0xffff) != 0x35) { std::printf("  FAIL C %08x %08x\n", a, b); ++fails; }
        break;
      case 'h':
        if (a != 0x28800500u || b != 0x98008400u) { std::printf("  FAIL h %08x %08x\n", a, b); ++fails; }
        break;
      case 'j':
        if (a != 0x12341230u || b != 0x0aaa0aaau) { std::printf("  FAIL j %08x %08x\n", a, b); ++fails; }
        break;
      case 'p':
        if (a != 0x11111111u || b != 0x22222222u) { std::printf("  FAIL p %08x %08x\n", a, b); ++fails; }
        break;
      case 'x':
        if (a != 0x33333333u || b != 0) { std::printf("  FAIL x %08x %08x\n", a, b); ++fails; }
        break;
      case 'i':
        if (a != 0x80104321u || b != 0x1c1f2621u) { std::printf("  FAIL i %08x %08x\n", a, b); ++fails; }
        break;
      case 'a':
        if ((a & 0xffffff) != 0x884000 || (a >> 31) != 1 || (b >> 24) != 0x40) { std::printf("  FAIL a %08x %08x\n", a, b); ++fails; }
        break;
      default: break;
    }
  }
  if (bad) { std::printf("  FAIL: %d malformed lines\n", bad); ++fails; }
  for (char t : std::string("Chjpxiar"))
    if (!nrec[t]) { std::printf("  FAIL: no '%c' record\n", t); ++fails; }
  // the hold: the longest 'a' value seen must cover the 5000-cycle hang (saturating 24 bits)
  {
    uint32_t hmax = 0;
    for (auto &l : lines) { char t; unsigned a, b;
      if (std::sscanf(l.c_str(), "%c %8x %8x", &t, &a, &b) == 3 && t == 'a') hmax = b & 0xffffff; }
    if (hmax < 5000) { std::printf("  FAIL: longest hold %u < 5000\n", hmax); ++fails; }
  }
  // the ring
  const size_t want_n = ring.size() < 256 ? ring.size() : 256;
  const int want_wp = int(ring.size() & 0xff);
  if (frozen_wp != want_wp) { std::printf("  FAIL: frozen write index %02x, want %02x\n", frozen_wp, want_wp); ++fails; }
  if (ent.size() != 256) { std::printf("  FAIL: %zu frozen ring entries seen, want 256\n", ent.size()); ++fails; }
  int rbad = 0;
  for (size_t k = 0; k < want_n; ++k) {
    const X &x = ring[ring.size() - want_n + k];
    const int idx = (want_wp + int(256 - want_n + k)) & 0xff;
    auto it = ent.find(idx);
    if (it == ent.end()) { ++rbad; continue; }
    const uint32_t tag = it->second.first, w = it->second.second;
    if ((tag & 3) != uint32_t(x.kind) || w != x.w || (tag >> 2) != uint32_t(x.vbl & 63)) {
      if (rbad < 5) std::printf("  FAIL ring[%02x]: got kind %u vbl %u %08x, want kind %d vbl %d %08x\n",
                                idx, tag & 3, tag >> 2, w, x.kind, x.vbl & 63, x.w);
      ++rbad;
    }
  }
  if (rbad) { std::printf("  FAIL: %d ring entries wrong\n", rbad); ++fails; }
  std::printf("  %zu lines; records:", lines.size());
  for (auto &kv : nrec) std::printf(" %c %d", kv.first, kv.second);
  std::printf("\n  transfers %u (%zu before the freeze), frozen write index %02x, stream drops %u\n",
              n, ring.size(), frozen_wp, d->dbg_dropped);
  std::printf("m2_tgp_probe: fails=%d\n%s\n", fails, fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
