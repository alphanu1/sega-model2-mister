// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
// (from the Sega Model 1 core, sega-model1-mister 2657c46, sim/sound/tb_dsb_z80.cpp)
//
// dsb_z80 (cut down) against tv80s (full Z80) on a DSB's real program, fed the
// UART bytes MAME's capture says the board received. Every port access of
// both cores is logged with the T-state it happened at; the two logs must be
// identical -- same order, same ports, same values, same T-states -- and both
// must take the same number of interrupts.
//
//   build (from the worktree root):
//     verilator --cc --exe --build -O2 -Wno-fatal -Irtl/sound --top-module dsb_z80_harness \
//       sim/sound/dsb_z80_harness.sv rtl/sound/dsb_z80.sv rtl/sound/m2_i8251.sv rtl/cpu/tv80/*.v \
//       sim/sound/tb_dsb_z80.cpp -o tb_dsb_z80 --Mdir obj_dsb_z80
//   (add -DDSB_UENT_LOGIC for the dispatch table as logic)
//
//   DSB_Z80ROM  the program, binary (default build/rom/dsb/epr-16471.2, Star Wars;
//               STCC is epr-19275.2s). Its first 32 KB are written as hex beside
//               the binary's name in DSB_HEXDIR (default obj_dsb_z80) for $readmemh.
//   DSB_CAP     MAME's capture (Star Wars: tools/mame_dsb_cap.lua "TX" lines;
//               STCC: the i960's UART data writes, "TX" too). Each byte reaches the
//               board one character time (320 us) after it was written, or one
//               after the previous byte, whichever is later.
//   DSB_SECS    emulated seconds (default 4)
//   DSB_LAT     dsb_z80's memory latency on chip, clk cycles (default 0)
//   DSB_LATFAR  ... and elsewhere (default = DSB_LAT); DSB_LATRND=1 makes it
//               uniform in [1, DSB_LATFAR] per access. Above what the T clock
//               can absorb, the core lags and I/O lands late; the bench then
//               checks order and values and reports the worst lag.
//   DSB_TPC     clk cycles per T-state (default 4; the board is 15; 2 is still
//               exact at latency 0 and the fastest way through 300 s)
//
// Ports other than the UART read 0 for both cores here, so once a song plays
// (STCC reads its position on e2-e4 and branches on it) the write stream
// departs from MAME's capture; tb_dsb_board, with the decoder, is the bench
// that compares against MAME.
#include "Vdsb_z80_harness.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <string>
#include <vector>
#include <random>
#include <cmath>
#include <algorithm>

struct Ev { char k; int port, data; uint64_t t; };

int main(int argc, char **argv) {
  const char *zp = getenv("DSB_Z80ROM") ? getenv("DSB_Z80ROM") : "build/rom/dsb/epr-16471.2";
  std::vector<uint8_t> rom(32768, 0xff);
  { FILE *f = fopen(zp, "rb");
    if (!f) { printf("dsb_z80: SKIPPED (%s absent)\n", zp); return 0; }
    size_t r = fread(rom.data(), 1, rom.size(), f); fclose(f); (void)r; }
  std::string hex = std::string(getenv("DSB_HEXDIR") ? getenv("DSB_HEXDIR") : "obj_dsb_z80") + "/" +
                    std::string(zp).substr(std::string(zp).find_last_of('/') + 1) + ".hex";
  { FILE *f = fopen(hex.c_str(), "w"); for (uint8_t b : rom) fprintf(f, "%02x\n", b); fclose(f); }
  std::vector<std::string> args(argv, argv + argc); args.push_back("+rom=" + hex);
  std::vector<const char *> av; for (auto &s : args) av.push_back(s.c_str());
  Verilated::commandArgs((int)av.size(), av.data());

  double secs = getenv("DSB_SECS") ? atof(getenv("DSB_SECS")) : 4.0;
  int lat = getenv("DSB_LAT") ? atoi(getenv("DSB_LAT")) : 0;
  int latfar = getenv("DSB_LATFAR") ? atoi(getenv("DSB_LATFAR")) : lat;
  bool latrnd = getenv("DSB_LATRND") != nullptr;
  int tpc = getenv("DSB_TPC") ? atoi(getenv("DSB_TPC")) : 4;
  const char *cap = getenv("DSB_CAP") ? getenv("DSB_CAP") : "build/rom/dsb/cap300.txt";

  // the bytes written to the far UART, arriving one character time later
  std::deque<std::pair<uint64_t, int>> rx;
  if (FILE *f = fopen(cap, "r")) {
    char line[256]; double prev = -1;
    while (fgets(line, sizeof line, f)) {
      double t; char k[8]; unsigned v;
      if (sscanf(line, "%lf %7s %x", &t, k, &v) == 3 && std::string(k) == "TX") {
        double a = std::max(t + 320e-6, prev + 320e-6); prev = a;
        rx.push_back({(uint64_t)(a * 4e6), (int)v});
      }
    }
    fclose(f);
  } else { printf("dsb_z80: SKIPPED (no capture %s)\n", cap); return 0; }

  long fails = 0;
  auto *h = new Vdsb_z80_harness;
  std::mt19937 rng(1234);
  h->lat = lat; h->lat_far = latfar; h->rst_n = 0; h->tick = 0; h->rx_stb = 0;
  for (int i = 0; i < 20; i++) { h->clk = 0; h->eval(); h->clk = 1; h->eval(); }
  h->rst_n = 1;

  std::deque<Ev> te, ce;
  size_t n = 0;
  long dt_max = 0, dt_neq = 0, wr_n = 0, tint = 0, cint = 0;
  auto drain = [&](void) {
    while (!te.empty() && !ce.empty()) {
      Ev a = te.front(), b = ce.front(); te.pop_front(); ce.pop_front();
      if (a.k != b.k || a.port != b.port || a.data != b.data) {
        if (fails < 10) printf("FAIL: access %zu: tv80 %c %02x=%02x @%llu  cut %c %02x=%02x @%llu\n", n,
            a.k, a.port, a.data, (unsigned long long)a.t, b.k, b.port, b.data, (unsigned long long)b.t);
        fails++;
      }
      long dt = (long)b.t - (long)a.t;
      if (dt) { dt_neq++; if (labs(dt) > dt_max) dt_max = labs(dt);
        if (dt_neq <= 5) printf("T differs: access %zu %c %02x=%02x tv80 @%llu cut @%llu\n", n, a.k, a.port, a.data,
            (unsigned long long)a.t, (unsigned long long)b.t); }
      if (getenv("DSB_SHOW") && n >= (size_t)atoi(getenv("DSB_SHOW")) && n < (size_t)atoi(getenv("DSB_SHOW")) + 12)
        printf("  %zu: tv80 %c %02x=%02x @%llu | cut %c %02x=%02x @%llu\n", n, a.k, a.port, a.data, (unsigned long long)a.t, b.k, b.port, b.data, (unsigned long long)b.t);
      if (a.k == 'W') wr_n++;
      n++;
    }
  };
  // what the cut core touched: per 256-byte page, reads (data), writes, fetches
  std::vector<long> pr(256, 0), pw(256, 0), pf(256, 0);
  int fmin = 0xffff, fmax = 0, spmin = 0xffff; long nfar = 0;
  uint64_t T = 0, Tend = (uint64_t)(secs * 4e6);
  long rxn = 0;
  uint64_t cyc = 0;
  // DSB_CTRACE=<file>: the cut core's port accesses and memory completions by
  // clk cycle, to show two builds of it are cycle-identical
  FILE *ct = getenv("DSB_CTRACE") ? fopen(getenv("DSB_CTRACE"), "w") : nullptr;
  while (T < Tend) {
    h->tick = ((cyc % tpc) == 0);
    h->rx_stb = 0;
    if (h->tick && !rx.empty() && rx.front().first <= T) { h->rx_stb = 1; h->rx_byte = rx.front().second; rx.pop_front(); rxn++;
      if (getenv("DSB_INTS") && rxn <= atoi(getenv("DSB_INTS")) + 1) printf("  rx %ld @%llu\n", rxn, (unsigned long long)T); }
    if (latrnd) h->lat_far = 1 + rng() % (latfar > 0 ? latfar : 1);
    h->clk = 0; h->eval(); h->clk = 1; h->eval();
    if (h->t_wr) te.push_back({'W', h->t_port, h->t_data, T});
    if (h->t_rd) te.push_back({'R', h->t_port, h->t_data, T});
    if (h->c_wr) ce.push_back({'W', h->c_port, h->c_data, T});
    if (h->c_rd) ce.push_back({'R', h->c_port, h->c_data, T});
    if (h->t_int) { tint++; if (getenv("DSB_INTS") && tint <= atoi(getenv("DSB_INTS"))) printf("  int %ld tv80 @%llu\n", tint, (unsigned long long)T); }
    if (h->c_int) { cint++; if (getenv("DSB_INTS") && cint <= atoi(getenv("DSB_INTS"))) printf("  int %ld cut  @%llu pc=%04x\n", cint, (unsigned long long)T, h->c_pc); }
    if (ct && (h->c_wr || h->c_rd || h->c_mstb))
      fprintf(ct, "%llu %d%d%d %02x %02x %04x\n", (unsigned long long)cyc, h->c_wr, h->c_rd, h->c_mstb, h->c_port, h->c_data, h->c_maddr);
    if (h->c_mstb) {
      int a = h->c_maddr;
      if (h->c_fetch) { pf[a >> 8]++; fmin = std::min(fmin, a); fmax = std::max(fmax, a); }
      else if (h->c_mwe) pw[a >> 8]++; else pr[a >> 8]++;
      if (!(a < 0x0800 || (a >> 8) == 0x90 || (a >> 8) == 0xff)) nfar++;
    }
    if (h->c_sp < spmin && T > 1000) spmin = h->c_sp;
    if ((cyc & 1023) == 0) drain();
    if (h->tick) T++;
    cyc++;
  }
  drain();
  if (ct) fclose(ct);
  if (te.size() != ce.size()) {
    printf("%s: tv80 made %zu accesses, cut made %zu\n", te.size() > ce.size() + 2 || ce.size() > te.size() + 2 ? "FAIL" : "note", te.size(), ce.size());
    if (te.size() > ce.size() + 2 || ce.size() > te.size() + 2) fails++;
  }
  if (h->trap) { printf("FAIL: unimplemented opcode trap, pc=%04x count=%u\n", h->trap_pc, h->trap_cnt); fails++; }
  if (tint != cint && labs(tint - cint) > 1) { printf("FAIL: interrupts tv80 %ld cut %ld\n", tint, cint); fails++; }
  if (lat == 0 && latfar == 0 && dt_neq) fails++;
  if (getenv("DSB_MAP")) {
    printf("pages touched by the cut core (page: fetch / read / write):\n");
    for (int p = 0; p < 256; p++) if (pf[p] || pr[p] || pw[p]) printf("  %02x00: %ld / %ld / %ld\n", p, pf[p], pr[p], pw[p]);
  }
  printf("dsb_z80[%s,lat=%d/%d%s,tpc=%d,%.1fs]: checks=%zu writes=%ld fails=%ld rx=%ld ovr=%u ints=%ld/%ld "
         "T_differ=%ld max_dT=%ld traps=%u fetch=%04x-%04x minSP=%04x far=%.0f/s\n",
         zp, lat, latfar, latrnd ? "rnd" : "", tpc, secs, n, wr_n, fails, rxn, h->ovr, tint, cint,
         dt_neq, dt_max, h->trap_cnt, fmin, fmax, spmin, nfar / secs);
  delete h;
  return fails ? 1 : 0;
}
