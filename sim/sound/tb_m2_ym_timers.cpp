// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// m2_ym_timers AGAINST jt12, EVERY CLOCK (R833).
//
// The stand-in has to be indistinguishable from jt12 to the sound 68000,
// which polls the status byte (bit 1, timer B; bit 7, busy) and never takes
// the interrupt. So both are driven with the same reset, enable and write
// strobe, and dout and irq_n are compared after EVERY clock edge, together
// with the stand-in's audio (which must be zero). Three parts:
//
//   A  MAME's own YM write stream (mame_m2_ym_usage.lua's ymw.log), at MAME's
//      times, for M2_YMT_SECS seconds, written as m2_sound_board writes: the
//      strobe held from the bus cycle until the next 8 MHz enable.
//   B  the whole stream, with the gaps between writes clipped to
//      M2_YMT_GAP clocks -- every write the game makes, in its order.
//   C  random programming: every register, both parts, timer A and B values
//      biased to overflow often, 0x27 and 0x21 (fast timers) at random, reset
//      pulses; enables at random ratios 8/8 .. 8/400, always on, and random;
//      strobes board-style or held 1..40 clocks.
//
// No ROM is read; the log is ROM-derived and is not in git (it is optional:
// without it parts A and B are skipped and C still runs).
//
//   M2_YMT_LOG=<ymw.log> M2_YMT_SECS=2 M2_YMT_MHZ=80 M2_YMT_RAND=200000
//   (M2_YMT_GAP, the clipped gap, default 4000; M2_YMT_MAXW limits part B;
//   M2_YMT_SEED the random stream)

#include "Vm2_ym_timers_harness.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>
#include <random>

static Vm2_ym_timers_harness *d;
static long cyc = 0, mism = 0, nz_audio = 0;
static long fa_rise = 0, fb_rise = 0, busy_cyc = 0, irq_cyc = 0;
static int pfa = 0, pfb = 0;

static void check(const char *where) {
  bool bad = d->dout_j != d->dout_s || d->irq_n_j != d->irq_n_s;
  if (d->snd_l_s != 0 || d->snd_r_s != 0) ++nz_audio;
  if (bad) {
    if (mism < 10)
      std::printf("  MISMATCH %s at %ld: dout jt12 %02x stub %02x, irq_n %d/%d\n",
                  where, cyc, d->dout_j, d->dout_s, d->irq_n_j, d->irq_n_s);
    ++mism;
  }
}

// one clock with the given enable; inputs already set
static void clock(int cen) {
  d->cen = cen;
  d->clk = 0; d->eval(); check("negedge");
  d->clk = 1; d->eval(); check("posedge");
  ++cyc;
  if (d->flag_a && !pfa) ++fa_rise;
  if (d->flag_b && !pfb) ++fb_rise;
  pfa = d->flag_a; pfb = d->flag_b;
  busy_cyc += d->busy; irq_cyc += !d->irq_n_j;
}

// The enable: an accumulator NUM/DEN as the board's ym_cen (registered, so
// a pulse is one clock), or always on, or random.
struct Cen {
  int mode = 0, num = 8, den = 80; long acc = 0; double p = 0.5;
  std::mt19937 *rng = nullptr;
  int next() {
    if (mode == 1) return 1;
    if (mode == 2) return std::uniform_real_distribution<double>(0, 1)(*rng) < p;
    if (acc + num >= den) { acc = acc + num - den; return 1; }
    acc += num; return 0;
  }
};

// A write as m2_sound_board makes it: the strobe from the bus cycle until the
// first enable after it (inclusive), or held for a fixed number of clocks.
static void write(Cen &ce, int a, int v, int hold = 0) {
  d->addr = a & 3; d->din = v & 0xff; d->cs_n = 0; d->wr_n = 0;
  if (hold > 0) {
    for (int i = 0; i < hold; ++i) clock(ce.next());
  } else {
    for (;;) { int c = ce.next(); clock(c); if (c) break; }
  }
  d->cs_n = 1; d->wr_n = 1;
}

static void idle(Cen &ce, long n) { for (long i = 0; i < n; ++i) clock(ce.next()); }

static void reset(Cen &ce, int n) {
  d->rst = 1; idle(ce, n); d->rst = 0;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_ym_timers_harness;
  d->rst = 1; d->cs_n = 1; d->wr_n = 1; d->addr = 0; d->din = 0; d->cen = 0;

  const double MHZ = std::getenv("M2_YMT_MHZ") ? std::atof(std::getenv("M2_YMT_MHZ")) : 80.0;
  const double SECS = std::getenv("M2_YMT_SECS") ? std::atof(std::getenv("M2_YMT_SECS")) : 1.0;
  const long GAP = std::getenv("M2_YMT_GAP") ? std::atol(std::getenv("M2_YMT_GAP")) : 4000;
  const long MAXW = std::getenv("M2_YMT_MAXW") ? std::atol(std::getenv("M2_YMT_MAXW")) : -1;
  const long RAND = std::getenv("M2_YMT_RAND") ? std::atol(std::getenv("M2_YMT_RAND")) : 100000;
  const unsigned SEED = std::getenv("M2_YMT_SEED") ? unsigned(std::atol(std::getenv("M2_YMT_SEED"))) : 1u;
  std::mt19937 rng(SEED);

  Cen ce; ce.rng = &rng; ce.num = 8; ce.den = int(MHZ + 0.5);
  reset(ce, 200);

  // ---- MAME's stream
  struct W { double t; int off, v; };
  std::vector<W> ws;
  if (const char *lp = std::getenv("M2_YMT_LOG")) {
    if (FILE *f = std::fopen(lp, "r")) {
      char line[256]; W w; unsigned pc;
      while (std::fgets(line, sizeof line, f))
        if (std::sscanf(line, "%lf %d %d %x", &w.t, &w.off, &w.v, &pc) >= 3) ws.push_back(w);
      std::fclose(f);
    }
    std::printf("  MAME stream: %zu writes from %s\n", ws.size(), lp);
  }
  long a_writes = 0, b_writes = 0;
  if (!ws.empty()) {
    // A: real time
    const long t0 = cyc;
    for (const W &w : ws) {
      if (w.t > SECS) break;
      long at = t0 + long(w.t * MHZ * 1e6);
      if (at > cyc) idle(ce, at - cyc);
      write(ce, w.off >> 1, w.v);
      ++a_writes;
    }
    idle(ce, long(0.01 * MHZ * 1e6));
    std::printf("  A  real time, %.2f s at %.0f MHz: %ld writes, %ld cycles; timer A flags %ld, B flags %ld, mismatches %ld\n",
                SECS, MHZ, a_writes, cyc - t0, fa_rise, fb_rise, mism);
    // B: every write, gaps clipped
    reset(ce, 200);
    const long fa0 = fa_rise, fb0 = fb_rise, c0 = cyc;
    for (size_t i = 0; i < ws.size() && (MAXW < 0 || long(i) < MAXW); ++i) {
      if (i) {
        long g = long((ws[i].t - ws[i - 1].t) * MHZ * 1e6);
        if (g > GAP) g = GAP;
        idle(ce, g);
      }
      write(ce, ws[i].off >> 1, ws[i].v);
      ++b_writes;
    }
    std::printf("  B  the whole stream, gaps <= %ld clk: %ld writes, %ld cycles; timer A flags %ld, B flags %ld, mismatches %ld\n",
                GAP, b_writes, cyc - c0, fa_rise - fa0, fb_rise - fb0, mism);
  }

  // ---- C: random programming
  {
    const long fa0 = fa_rise, fb0 = fb_rise, c0 = cyc;
    long resets = 0, fast = 0;
    auto U = [&](int lo, int hi) { return std::uniform_int_distribution<int>(lo, hi)(rng); };
    for (long n = 0; n < RAND; ++n) {
      if ((n % 2000) == 0) {               // a new enable regime
        int m = U(0, 9);
        ce.mode = m < 6 ? 0 : (m < 8 ? 1 : 2);
        ce.den = U(8, 400); ce.acc = 0; ce.p = U(5, 95) / 100.0;
      }
      int r = U(0, 999);
      if (r < 2) { reset(ce, U(8, 80)); ++resets; continue; }
      int hold = U(0, 3) == 0 ? U(1, 40) : 0;
      int part = U(0, 3) == 0;
      int reg;
      int k = U(0, 99);
      if      (k < 15) reg = 0x27;
      else if (k < 25) reg = 0x26;
      else if (k < 33) reg = 0x24;
      else if (k < 41) reg = 0x25;
      else if (k < 45) reg = 0x21;
      else if (k < 50) reg = 0x28;
      else             reg = U(0, 255);
      int v;
      switch (reg) {
        case 0x24: case 0x26: v = U(0, 3) ? U(0xf0, 0xff) : U(0, 255); break;
        case 0x21: v = U(0, 255); if (v & 4) ++fast; break;
        case 0x27: v = U(0, 2) ? (U(0, 1) ? 0x2a : 0x15) | (U(0, 3) == 0 ? 0x3f : 0) : U(0, 255); break;
        default:   v = U(0, 255);
      }
      int how = U(0, 9);
      if (how < 7) { write(ce, part << 1, reg, hold); write(ce, (part << 1) | 1, v, hold); }
      else if (how < 9) write(ce, (part << 1) | 1, v, hold);       // data to the last register
      else write(ce, part << 1, reg, hold);                          // address only
      idle(ce, U(0, 9) == 0 ? U(0, 20000) : U(0, 400));
    }
    std::printf("  C  random, %ld operations, %ld resets, %ld fast-timer writes: %ld cycles; timer A flags %ld, B flags %ld, mismatches %ld\n",
                RAND, resets, fast, cyc - c0, fa_rise - fa0, fb_rise - fb0, mism);
  }

  std::printf("  coverage: %ld cycles, busy %ld, irq asserted %ld; stand-in audio non-zero on %ld\n",
              cyc, busy_cyc, irq_cyc, nz_audio);
  int fails = 0;
  if (mism) { std::printf("  FAIL %ld cycles where the stand-in's status or irq differs from jt12's\n", mism); ++fails; }
  if (nz_audio) { std::printf("  FAIL the stand-in made sound\n"); ++fails; }
  if (fb_rise == 0 || fa_rise == 0 || busy_cyc == 0) { std::printf("  FAIL the test never set a flag or busy -- it proves nothing\n"); ++fails; }
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
