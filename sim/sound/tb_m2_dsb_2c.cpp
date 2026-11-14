// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// tb_m2_dsb_2c (study R1004): the 2C build's Digital Sound Board as Model2.sv
// wires it (rtl/sound/m2_dsb_2c.sv) -- its reset gate and its mix -- at
// 80 MHz, behind an SDRAM that answers in [1, LAT] cycles and reads 0xFFFF
// where nothing was written.
//
//   1. NOT STCC (House of the Dead, Over Rev: run = 0). The i960's bytes go
//      out on the link as they do for any game and the SCSP's output is
//      random, every value of each channel swept: every cycle the speaker's
//      sample must be the SCSP's bit for bit, and the board must never raise
//      an SDRAM request.
//   2. STCC (run = 1), the board's ROM and MPEG data in the SDRAM model and
//      MAME's capture's bytes on the link: every cycle the speaker's sample
//      must be clamp16(SCSP + board), the board must play (decoded frames),
//      and it must never trap.
//   3. Back to another game (run = 0): two cycles later no request, and the
//      speaker is the SCSP's again.
//
//   DSB_SECS (phase 2, default 20), DSB_LAT (default 40), DSB_PH1 (phase 1
//   cycles, default 4,000,000); inputs from tools/dsb/prepare_stcc.sh.
#include "Vm2_dsb_2c.h"
#include "Vm2_dsb_2c___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <deque>
#include <random>
#include <string>
#include <vector>

static int16_t sat16(int v) { return v > 32767 ? 32767 : v < -32768 ? -32768 : (int16_t)v; }

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const double secs = getenv("DSB_SECS") ? atof(getenv("DSB_SECS")) : 20.0;
  const int LAT = getenv("DSB_LAT") ? atoi(getenv("DSB_LAT")) : 40;
  const long PH1 = getenv("DSB_PH1") ? atol(getenv("DSB_PH1")) : 4000000;
  const double CLK = 80e6;

  // SDRAM words: unwritten 0xFFFF; MPEG at word 0x3000000, ROM 0x3400000
  std::vector<uint16_t> mem((size_t)1 << 26, 0xffff);
  auto load = [&](const char *p, uint32_t wbase) {
    FILE *f = fopen(p, "rb"); if (!f) return false;
    std::vector<uint8_t> b(16 << 20); size_t n = fread(b.data(), 1, b.size(), f); fclose(f);
    for (size_t i = 0; i + 1 < n + 1; i += 2) mem[wbase + i / 2] = b[i] | ((i + 1 < n ? b[i + 1] : 0xff) << 8);
    return true;
  };
  if (!load("build/rom/dsb/mpeg.bin", 0x3000000) || !load("build/rom/dsb/epr-19275.2s", 0x3400000)) {
    printf("m2_dsb_2c: SKIPPED (build/rom/dsb absent)\n"); return 0;
  }
  // MAME's TX bytes, landing on the link's B side one character time later
  std::deque<std::pair<uint64_t, int>> rx;
  if (FILE *f = fopen("build/rom/dsb/cap300.txt", "r")) {
    char line[256]; double prev = -1;
    while (fgets(line, sizeof line, f)) {
      double t; char k[8]; unsigned v;
      if (sscanf(line, "%lf %7s %x", &t, k, &v) == 3 && std::string(k) == "TX") {
        double a = std::max(t + 320e-6, prev + 320e-6); prev = a;
        rx.push_back({(uint64_t)(a * CLK), (int)v});
      }
    }
    fclose(f);
  } else { printf("m2_dsb_2c: SKIPPED (no capture)\n"); return 0; }

  auto *d = new Vm2_dsb_2c;
  std::mt19937 rng(20261114);
  long fails = 0;
  int busy = 0; uint32_t sa = 0; int swe = 0, sbe = 0, sdin = 0;
  auto sdram = [&]() {   // one request at a time, the level held until the ack
    d->s_ack = 0;
    if (busy > 0) {
      if (--busy == 0) {
        d->s_ack = 1;
        if (swe) { uint16_t &w = mem[sa]; if (sbe & 1) w = (w & 0xff00) | (sdin & 0xff); if (sbe & 2) w = (w & 0x00ff) | (sdin & 0xff00); }
        else d->s_dout = mem[sa];
      }
    } else if (d->s_req) { busy = 1 + rng() % LAT; sa = d->s_addr & ((1u << 26) - 1); swe = d->s_we; sbe = d->s_be; sdin = d->s_din; }
  };
  auto tick = [&]() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };

  // ---- 1. not STCC
  d->mem_rst_n = 0; d->run = 0; d->b_rx_v = 0; d->b_rx_d = 0; d->in_l = 0; d->in_r = 0;
  for (int i = 0; i < 16; i++) tick();
  d->mem_rst_n = 1;
  long p1_req = 0, p1_chk = 0, p1_bytes = 0; int rxhold = 0;
  uint64_t next_byte = 25600;   // a character time at 80 MHz
  for (long c = 0; c < PH1; c++) {
    int16_t L = (c < 65536) ? (int16_t)c : (int16_t)rng(), R = (c < 65536) ? (int16_t)~c : (int16_t)rng();
    d->in_l = L; d->in_r = R;
    if (rxhold) { if (--rxhold == 0) d->b_rx_v = 0; }
    else if ((uint64_t)c >= next_byte) { d->b_rx_v = 1; d->b_rx_d = rng() & 0xff; rxhold = 1 + rng() % 200; next_byte = c + 25600 + rng() % 4096; p1_bytes++; }
    d->clk = 0; d->eval();
    if ((int16_t)d->out_l != L || (int16_t)d->out_r != R) { if (fails < 10) printf("FAIL: phase 1 cycle %ld: out %d %d, SCSP %d %d\n", c, (int16_t)d->out_l, (int16_t)d->out_r, L, R); fails++; }
    if (d->s_req) p1_req++;
    p1_chk++;
    sdram(); d->clk = 1; d->eval();
  }
  if (p1_req) { printf("FAIL: phase 1: %ld cycles with an SDRAM request\n", p1_req); fails++; }

  // ---- 2. STCC
  d->run = 1; d->b_rx_v = 0;
  const uint64_t N2 = (uint64_t)(secs * CLK);
  long p2_req = 0, p2_chk = 0, p2_nz = 0, p2_bytes = 0, p2_clamp = 0;
  rxhold = 0;
  for (uint64_t c = 0; c < N2; c++) {
    int16_t L = (int16_t)rng(), R = (int16_t)rng();
    if ((c & 0xffff) < 0x100) { L = (int16_t)(32767 - (rng() & 0x3ff)); R = (int16_t)(-32768 + (rng() & 0x3ff)); }   // near full scale: the clamp
    d->in_l = L; d->in_r = R;
    if (rxhold) { if (--rxhold == 0) d->b_rx_v = 0; }
    else if (!rx.empty() && rx.front().first <= c) { d->b_rx_v = 1; d->b_rx_d = rx.front().second; rx.pop_front(); rxhold = 1 + rng() % 200; p2_bytes++; }
    d->clk = 0; d->eval();
    int16_t bl = (int16_t)d->rootp->m2_dsb_2c__DOT__dsb_l, br = (int16_t)d->rootp->m2_dsb_2c__DOT__dsb_r;
    int16_t el = sat16(L + bl), er = sat16(R + br);
    if ((int16_t)d->out_l != el || (int16_t)d->out_r != er) { if (fails < 10) printf("FAIL: phase 2 cycle %llu: out %d %d, expected %d %d\n", (unsigned long long)c, (int16_t)d->out_l, (int16_t)d->out_r, el, er); fails++; }
    if (bl || br) p2_nz++;
    if (el != L + bl || er != R + br) p2_clamp++;
    if (d->s_req) p2_req++;
    p2_chk++;
    sdram(); d->clk = 1; d->eval();
  }
  if (!p2_req) { printf("FAIL: phase 2: the board never asked for SDRAM\n"); fails++; }
  if (d->dbg_trap) { printf("FAIL: phase 2: the Z80 trapped\n"); fails++; }
  unsigned frames = d->dbg_frames;
  if (secs >= 20 && !frames) { printf("FAIL: phase 2: no MPEG frame decoded\n"); fails++; }

  // ---- 3. another game again
  d->run = 0;
  long p3_req = 0, p3_chk = 0;
  for (long c = 0; c < 1000000; c++) {
    int16_t L = (int16_t)rng(), R = (int16_t)rng();
    d->in_l = L; d->in_r = R;
    d->clk = 0; d->eval();
    if (c >= 2) {
      if ((int16_t)d->out_l != L || (int16_t)d->out_r != R) { if (fails < 10) printf("FAIL: phase 3 cycle %ld: out %d %d, SCSP %d %d\n", c, (int16_t)d->out_l, (int16_t)d->out_r, L, R); fails++; }
      if (d->s_req) p3_req++;
      p3_chk++;
    }
    sdram(); d->clk = 1; d->eval();
  }
  if (p3_req) { printf("FAIL: phase 3: %ld cycles with an SDRAM request\n", p3_req); fails++; }

  printf("  not STCC : %ld cycles, out == SCSP on every one (all 65,536 values per channel swept), %ld link bytes, SDRAM requests %ld\n", p1_chk, p1_bytes, p1_req);
  printf("  STCC     : %ld cycles (%.0f s), out == clamp16(SCSP + board) on every one, board nonzero on %ld, clamped %ld, %ld link bytes, %u frames, SDRAM request cycles %ld\n",
         p2_chk, secs, p2_nz, p2_clamp, p2_bytes, frames, p2_req);
  printf("  after    : %ld cycles, out == SCSP, SDRAM requests %ld\n", p3_chk, p3_req);
  printf("m2_dsb_2c[lat=%d]: fails=%ld\n", LAT, fails);
  delete d;
  return fails ? 1 : 0;
}
