// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// THE TYPE-2 I/O BOARD AGAINST MAME (R839). Runs a firmware on m2_ioz80 with
// the game's side of the DPRAM replayed from a MAME capture, and compares
// what the board writes into the DPRAM with what MAME's board wrote.
//
//   M2_IOFW=<epr-17181.6> M2_T2=1 M2_GW=<gw.log> M2_DPW=<dpw.log> \
//     obj_ioz80_t2/Vm2_ioz80_harness +secs=30
//
// gw.log and dpw.log come from sim/io/mame_m2_vcop_io.lua run with
// VC_GUNFIX=1 (both guns held at P1 0x100,0x0a0 / P2 0x200,0x150, nothing
// pressed). The harness runs the type-2 Z80 at clk / 2, so a MAME second is
// 2 x 9,830,400 clocks here, and the CTC counts Z80 clocks either way.
//
// THE COMPARISON. The two machines do not interleave identically to the
// clock -- the game's writes land at MAME's times, not at the same Z80
// instruction -- so the DPRAM is compared address by address: the sequence
// of distinct values each address took (runs collapsed), the number of
// writes, and when the first one landed. PASS needs every address's value
// sequence equal (the last value may be cut by the end of the window), the
// first DPRAM write within 1% of MAME's time, and the CTC's interrupt rate
// within 0.1% of 1,010.5 Hz.
//
// M2_T2=0 runs the type-1 path instead (any firmware, no comparison) and
// prints a hash of every DPRAM write and every opcode fetch address with its
// cycle: the same hash from a TYPE2=0 and a TYPE2=1 build is the type-1
// board unchanged, cycle for cycle.

#include "Vm2_ioz80_harness.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include <map>
#include <string>

static const double Z80HZ = 9830400.0;

struct Ev { uint64_t at; uint16_t a; uint8_t v; };

static std::vector<Ev> read_log(const char *path, bool game, double clk_per_s) {
  std::vector<Ev> v;
  FILE *f = path ? std::fopen(path, "r") : nullptr;
  if (!f) return v;
  char line[256];
  while (std::fgets(line, sizeof line, f)) {
    double t; unsigned a, x; char g;
    if (game) {
      if (std::sscanf(line, "%lf %c %x %x", &t, &g, &a, &x) == 4 && g == 'G')
        v.push_back({uint64_t(t * clk_per_s), uint16_t(a), uint8_t(x)});
    } else if (std::sscanf(line, "%lf %x %x", &t, &a, &x) == 3)
      v.push_back({uint64_t(t * clk_per_s), uint16_t(a), uint8_t(x)});
  }
  std::fclose(f);
  return v;
}

static std::map<uint16_t, std::vector<uint8_t>> runs(const std::vector<Ev> &v, uint64_t until) {
  std::map<uint16_t, std::vector<uint8_t>> m;
  for (auto &e : v) {
    if (e.at >= until) break;
    auto &s = m[e.a];
    if (s.empty() || s.back() != e.v) s.push_back(e.v);
  }
  return m;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *d = new Vm2_ioz80_harness;

  const char *fw_path = std::getenv("M2_IOFW");
  if (!fw_path) { std::printf("set M2_IOFW to the firmware image\nFAIL\n"); return 1; }
  FILE *f = std::fopen(fw_path, "rb");
  if (!f) { std::printf("cannot read %s\nFAIL\n", fw_path); return 1; }
  std::vector<uint8_t> fw(65536, 0xff);
  size_t n = std::fread(fw.data(), 1, fw.size(), f);
  std::fclose(f);
  const bool t2 = !std::getenv("M2_T2") || std::atoi(std::getenv("M2_T2")) != 0;
  double secs = 30.0;
  uint64_t cyc1 = 40'000'000;
  for (int i = 1; i < argc; i++) {
    if (!std::strncmp(argv[i], "+secs=", 6)) secs = std::atof(argv[i] + 6);
    if (!std::strncmp(argv[i], "+cycles=", 8)) cyc1 = std::strtoull(argv[i] + 8, nullptr, 10);
  }
  // both boards' Z80s run at clk / 2 here (type 1: TICK 25/50), so a MAME
  // second is twice the real CPU clock
  const double clk_per_s = 2.0 * (t2 ? Z80HZ : 4000000.0);
  const uint64_t cycles = (t2 || std::getenv("M2_DPW")) ? uint64_t(secs * clk_per_s) : cyc1;
  std::printf("m2_ioz80 %s: firmware %zu bytes from %s, %llu clocks\n",
              t2 ? "TYPE 2" : "type 1", n, fw_path, (unsigned long long)cycles);

  d->type2 = t2;
  d->in0 = 0xff; d->in1 = t2 ? 0xff : 0x8f; d->in2 = 0xff;
  d->dsw1 = 0xff; d->dsw2 = 0xff; d->dsw3 = 0xff;
  d->adc0 = 0x80; d->adc1 = 0x20; d->adc2 = 0x20; d->adc3 = 0x80;
  d->gun_p1x = 0x100; d->gun_p1y = 0x0a0; d->gun_p2x = 0x200; d->gun_p2y = 0x150;
  d->gun_off = 0;
  d->g_we = 0; d->g_addr = 0; d->g_wdata = 0;
  auto tick = [&]() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };

  d->rst_n = 0; d->fw_we = 0;
  for (int i = 0; i < 4; ++i) tick();
  for (int a = 0; a < 8192; ++a) {
    d->fw_we = 1; d->fw_addr = a;
    d->fw_data = fw[a * 2] | (fw[a * 2 + 1] << 8); tick();
  }
  d->fw_we = 0;
  for (int i = 0; i < 8; ++i) tick();
  d->rst_n = 1;

  std::vector<Ev> game = read_log(std::getenv("M2_GW"), true, clk_per_s);
  std::vector<Ev> ref  = read_log(std::getenv("M2_DPW"), false, clk_per_s);
  std::printf("  replaying %zu game writes; MAME board writes %zu\n", game.size(), ref.size());

  std::vector<Ev> mine;
  FILE *iolog = std::getenv("M2_IOLOG") ? std::fopen(std::getenv("M2_IOLOG"), "w") : nullptr;
  const uint64_t iolog_until = uint64_t(3.0 * clk_per_s);
  size_t gp = 0;
  uint64_t inta = 0, inta_first = 0, inta_last = 0, h = 1469598103934665603ULL;
  int inta_prev = 0, m1_prev = 1;
  uint64_t ius_cyc = 0;
  auto mix = [&](uint64_t x) { h ^= x; h *= 1099511628211ULL; };
  for (uint64_t t = 0; t < cycles; ++t) {
    d->g_we = 0;
    if (gp < game.size() && t >= game[gp].at) {
      d->g_we = 1; d->g_addr = game[gp].a; d->g_wdata = game[gp].v; ++gp;
    }
    tick();
    if (iolog && t < iolog_until) {   // io.log's format: the 315-5338A stream
      if (d->spy_wr && (d->spy_a & 0xfff0) == 0x8000)
        std::fprintf(iolog, "%.6f W %x %02x\n", t / clk_per_s, d->spy_a & 0xf, d->spy_dout);
      if (d->spy_rd_end && (d->spy_ra & 0xfff0) == 0x8000)
        std::fprintf(iolog, "%.6f R %x %02x\n", t / clk_per_s, d->spy_ra & 0xf, d->spy_rdat);
    }
    if (d->spy_we) { mine.push_back({t, d->spy_addr, d->spy_data}); mix((t << 20) ^ (uint64_t(d->spy_addr) << 8) ^ d->spy_data); }
    if (!d->spy_m1_n && m1_prev) mix((t << 16) ^ d->spy_a);
    m1_prev = d->spy_m1_n;
    const int ia = !d->spy_m1_n && !d->spy_iorq_n;
    if (ia && !inta_prev) { if (!inta) inta_first = t; inta_last = t; ++inta; }
    inta_prev = ia;
    if (d->spy_ius) ++ius_cyc;
  }
  if (const char *dump = std::getenv("M2_DUMP")) {   // the board's writes, dpw.log's format
    if (FILE *o = std::fopen(dump, "w")) {
      for (auto &e : mine) std::fprintf(o, "%.6f %03x %02x\n", e.at / clk_per_s, e.a, e.v);
      std::fclose(o);
    }
  }
  std::printf("  board DPRAM writes %zu, interrupts acknowledged %llu\n", mine.size(),
              (unsigned long long)inta);
  std::printf("  HASH %016llx\n", (unsigned long long)h);
  if (inta) std::printf("  in the CTC handler %.1f%% of the time, %.0f Z80 cycles per interrupt\n",
                        100.0 * ius_cyc / cycles, ius_cyc / 2.0 / inta);
  if (!t2 && !std::getenv("M2_DPW")) { std::printf("PASS (type-1 run; compare HASH between builds)\n"); return 0; }

  int fails = 0;
  if (t2) {
    double rate = inta > 1 ? (inta - 1) / ((inta_last - inta_first) / clk_per_s) : 0.0;
    std::printf("  CTC interrupt rate %.2f Hz (MAME 1010.5)\n", rate);
    if (rate < 1010.5 * 0.999 || rate > 1010.5 * 1.001) { std::printf("  FAIL rate\n"); ++fails; }
  } else if (inta) { std::printf("  FAIL type 1 took an interrupt\n"); ++fails; }

  // compare up to the end of the shorter record
  uint64_t until = cycles;
  if (!ref.empty() && ref.back().at < until) until = ref.back().at;
  auto A = runs(mine, until), B = runs(ref, until);
  if (!mine.empty() && !ref.empty()) {
    double dt = (double(mine[0].at) - double(ref[0].at)) / clk_per_s;
    std::printf("  first DPRAM write: board %.4f s, MAME %.4f s (%+.2f%%)\n",
                mine[0].at / clk_per_s, ref[0].at / clk_per_s, 100.0 * dt / (ref[0].at / clk_per_s));
    if (std::abs(dt) > 0.01 * (ref[0].at / clk_per_s)) { std::printf("  FAIL first write\n"); ++fails; }
  } else { std::printf("  FAIL no writes\n"); ++fails; }
  std::map<uint16_t, int> cntA, cntB;
  for (auto &e : mine) if (e.at < until) cntA[e.a]++;
  for (auto &e : ref) if (e.at < until) cntB[e.a]++;
  int addrs = 0, same = 0;
  std::map<uint16_t, bool> all;
  for (auto &k : A) all[k.first] = true;
  for (auto &k : B) all[k.first] = true;
  for (auto &k : all) {
    ++addrs;
    auto &x = A[k.first], &y = B[k.first];
    size_t m = std::min(x.size(), y.size());
    bool ok = std::equal(x.begin(), x.begin() + m, y.begin()) &&
              (x.size() > y.size() ? x.size() - y.size() : y.size() - x.size()) <= 1;
    if (ok) ++same;
    if (!ok || std::getenv("M2_VERBOSE"))
      std::printf("  %s dp[%03x] writes %d / MAME %d, values %zu / %zu\n", ok ? "  " : "MISMATCH",
                  k.first, cntA[k.first], cntB[k.first], x.size(), y.size());
    if (!ok) {
      for (size_t i = 0; i < std::max(x.size(), y.size()) && i < 12; ++i)
        std::printf("      [%zu] %s / %s\n", i,
                    i < x.size() ? (std::to_string(x[i])).c_str() : "-",
                    i < y.size() ? (std::to_string(y[i])).c_str() : "-");
      ++fails;
    }
  }
  std::printf("  %d DPRAM addresses, %d with MAME's value sequence\n", addrs, same);
  std::printf(fails ? "FAIL\n" : t2 ? "PASS (type-2 board against MAME)\n" : "PASS (type-1 board against MAME)\n");
  return fails ? 1 : 0;
}
