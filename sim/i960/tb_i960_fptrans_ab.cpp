// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R998: the pipelined transcendental sequencer against R845's, side by side
// on their own units. For every instruction both must give the same result,
// bit for bit (NaNs included), and the same register-file writes -- address
// and data, in the same order -- so the 55 working registers, which carry
// over from one instruction to the next, stay identical too. The arguments
// are drawn here: uniform ranges, the whole exponent range, raw 64-bit
// patterns (NaN payloads, subnormals), +-0 / subnormal / inf / NaN / huge
// specials, the reduction's edges (k pi/2 +- a few ulp, k to 2^30; pi/4),
// and for atan2 every pairing of those plus |y| = |x| and the breakpoints.
//
// On the 2C branch the reference is R935's sequencer (the 2C build's before
// R998; with LOG = 0 R845's exactly). Built with -DFPTRANS_LOG (the harness
// at LOG = 1, the 2C program) a fifth of the vectors are logrl (lg, with a
// random entry it must override): x over House of the Dead's range, +-0,
// negatives, +-inf, NaNs, subnormals, 1 and its neighbours, powers of 2 and
// their neighbours, the 1.5 x 2^k halving threshold +- a few ulp, the whole
// exponent range, huge and raw; y 1, +-0, +-inf, NaNs, subnormals, huge,
// tiny and raw.
//
//   ./obj_i960_fptrans_ab/Vi960_fptrans_ab_harness +n=200000 +seed=1
//   ./obj_i960_fptrans_ab_log/Vi960_fptrans_ab_harness +n=200000 +seed=1

#include "Vi960_fptrans_ab_harness.h"
#include "verilated.h"
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <random>
#include <vector>
#include <utility>

static uint64_t d2u(double d) { uint64_t u; std::memcpy(&u, &d, 8); return u; }
static double u2d(uint64_t u) { double d; std::memcpy(&d, &u, 8); return d; }

static std::mt19937_64 rng;
static double uni(double lo, double hi) { return std::uniform_real_distribution<double>(lo, hi)(rng); }
static uint64_t rbits() { return rng(); }
static int rint_(int lo, int hi) { return std::uniform_int_distribution<int>(lo, hi)(rng); }

static double nudge(double v, int ulps) {
  for (int i = 0; i < std::abs(ulps); i++) v = std::nextafter(v, ulps > 0 ? INFINITY : -INFINITY);
  return v;
}

static uint64_t special() {
  static const uint64_t tab[] = {
    0x0000000000000000ull, 0x8000000000000000ull,           // +-0
    0x0000000000000001ull, 0x8000000000000001ull,           // +-min subnormal
    0x000fffffffffffffull, 0x800fffffffffffffull,           // +-max subnormal
    0x0010000000000000ull, 0x8010000000000000ull,           // +-min normal
    0x7ff0000000000000ull, 0xfff0000000000000ull,           // +-inf
    0x7ff8000000000000ull, 0xfff8000000000000ull,           // +-quiet NaN
    0x7ff0000000000001ull, 0xfff4000000000000ull,           // signalling NaNs
    0x7fffffffffffffffull, 0xffffffffffffffffull,           // NaN, all payload
    0x7fefffffffffffffull, 0xffefffffffffffffull,           // +-max
    0x3ff0000000000000ull, 0xbff0000000000000ull,           // +-1
    0x3fe921fb54442d18ull, 0x3fe921fb54442d19ull,           // PIO4 and just above
    0x3fe921fb54442d17ull, 0xbfe921fb54442d18ull,           // just below, -PIO4
    0x3ff921fb54442d18ull, 0x400921fb54442d18ull,           // pi/2, pi
  };
  const int n = sizeof(tab) / sizeof(tab[0]);
  int k = rint_(0, n + 7);
  if (k < n) return tab[k];
  switch (k - n) {
    case 0:  return (rbits() & 0x800fffffffffffffull) | 1;                 // a subnormal
    case 1:  return 0x7ff0000000000000ull | (rbits() & 0x800fffffffffffffull) | 1;   // a NaN
    case 2:  return d2u(std::ldexp(uni(-1, 1), rint_(-1074, -1000)));    // tiny
    case 3:  return d2u(std::ldexp(uni(-1, 1), rint_(900, 1024)));       // huge
    case 4:  return d2u(uni(-1, 1) * 1e300);
    case 5:  return d2u(std::ldexp((double)rint_(1, 7), rint_(-30, 30)));  // exact small powers
    case 6:  return d2u(nudge(1.5707963267948966 * 524288.0, rint_(-8, 8)));    // 2^19 pi/2
    default: return d2u(std::ldexp(uni(0.5, 1.0), rint_(-60, -20)) * (rng() & 1 ? 1 : -1));
  }
}

static uint64_t near_halfpi() {
  long double hp = 1.5707963267948966192313216916397514L;
  long long k;
  int r = rint_(0, 3);
  if (r == 0)      k = rint_(-64, 64);
  else if (r == 1) k = (long long)rint_(-(1 << 20), 1 << 20);
  else if (r == 2) k = (long long)rint_(-(1 << 30), 1 << 30);
  else             k = (long long)rint_(-100000, 100000);
  double v = (double)(hp * (long double)k);
  return d2u(nudge(v, rint_(-16, 16)));
}

static uint64_t arg_trig() {
  int c = rint_(0, 99);
  if (c < 30) return d2u(uni(-4, 4));
  if (c < 45) return d2u(uni(-1e4, 1e4));
  if (c < 55) return d2u(std::ldexp(uni(-1, 1), rint_(-1080, 1030)));
  if (c < 70) return near_halfpi();
  if (c < 85) return special();
  if (c < 92) return d2u(uni(-1e6, 1e6));
  return rbits();
}

static uint64_t arg_atan1() {
  int c = rint_(0, 99);
  if (c < 40) return d2u(uni(-40, 40));
  if (c < 60) return d2u(std::ldexp(uni(-1, 1), rint_(-1080, 1030)));
  if (c < 80) return special();
  if (c < 90) return d2u(uni(-1, 1));
  return rbits();
}

static std::pair<uint64_t, uint64_t> arg_atan() {   // (x = src1, y = src2)
  int c = rint_(0, 99);
  uint64_t x = arg_atan1(), y = arg_atan1();
  if (c < 8) {                                   // |y| = |x| (+- an ulp): the swap
    double v = u2d(x);
    y = d2u(nudge(rng() & 1 ? v : -v, rint_(-1, 1)));
  } else if (c < 20) {                           // the breakpoints 0.2, 7/16, 11/16, 1
    static const double bp[] = {0.2, 0.4375, 0.6875, 1.0};
    double v = uni(-40, 40), t = bp[rint_(0, 3)];
    double w = nudge(v * t, rint_(-4, 4));
    if (rng() & 1) { x = d2u(v); y = d2u(w); } else { x = d2u(w); y = d2u(v); }
  }
  return {x, y};
}

static uint64_t arg_log_x() {          // logrl (FPTRANS_LOG builds only)
  int c = rint_(0, 99);
  if (c < 25) return d2u(uni(0.0, 4096.0));                                   // HOTD's range
  if (c < 33) return d2u(1.0 + uni(-1, 1) * std::ldexp(1.0, rint_(-60, -1)));  // near 1
  if (c < 40) return d2u(nudge(1.0, rint_(-8, 8)));                          // 1 +- a few ulp
  if (c < 48) return d2u(nudge(std::ldexp(1.0, rint_(-1022, 1023)), rint_(-3, 3)));   // 2^k +- ulp
  if (c < 56) return d2u(nudge(std::ldexp(1.5, rint_(-1022, 1023)), rint_(-4, 4)));   // the halving threshold
  if (c < 68) return d2u(std::ldexp(uni(1, 2), rint_(-1022, 1023)));         // every exponent
  if (c < 72) return d2u(nudge(1.7976931348623157e308, -rint_(0, 4)));       // huge
  if (c < 78) return d2u(-std::fabs(u2d(arg_trig())));                       // negative (and -0, -NaN)
  if (c < 92) return special();
  return rbits();
}
static uint64_t arg_log_y() {
  int c = rint_(0, 99);
  if (c < 25) return d2u(1.0);
  if (c < 50) return d2u(uni(-100, 100));
  if (c < 60) return d2u(std::ldexp(uni(-1, 1), rint_(-1074, 1023)));
  if (c < 85) return special();                  // +-0, +-inf, NaNs, subnormals, huge
  return rbits();
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  long n = 200000; unsigned long long seed = 1;
  for (int i = 1; i < argc; i++) {
    if (!std::strncmp(argv[i], "+n=", 3)) n = std::atol(argv[i] + 3);
    if (!std::strncmp(argv[i], "+seed=", 6)) seed = std::strtoull(argv[i] + 6, nullptr, 0);
  }
  rng.seed(seed);
  auto *d = new Vi960_fptrans_ab_harness;
  auto tick = [&]() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };
  d->rst_n = 0; d->start = 0; tick(); tick(); d->rst_n = 1; tick();

  static const char *nm[5] = {"sin", "cos", "tan", "atan", "log"};
  unsigned long long sumn[5] = {0}, sumo[5] = {0}, maxn[5] = {0}, maxo[5] = {0}, cnt[5] = {0};
  long bad = 0, badw = 0;
  std::vector<std::pair<unsigned, uint64_t>> wn, wo;
  for (long v = 0; v < n; v++) {
#ifdef FPTRANS_LOG
    unsigned e = rint_(0, 4);
#else
    unsigned e = rint_(0, 3);
#endif
    uint64_t x, y = 0;
    if (e == 4) { x = arg_log_x(); y = arg_log_y(); }
    else if (e == 3) { auto p = arg_atan(); x = p.first; y = p.second; }
    else { x = arg_trig(); y = (rng() & 3) ? 0 : rbits(); }   // y is ignored by sin/cos/tan
    d->entry = (e == 4) ? (unsigned)(rng() & 3) : e;           // logrl: lg overrides any entry
    d->lg = (e == 4); d->x = x; d->y = y; d->start = 1;
    wn.clear(); wo.clear();
    bool fn = false, fo = false;
    uint64_t rn = 0, ro = 0;
    unsigned long long cn = 0, co = 0, c = 0;
    // the write ports are sampled before each edge, as the register file does
    auto sample = [&]() {
      d->clk = 0; d->eval();
      if (d->n_we) wn.push_back({d->n_wa, d->n_res});
      if (d->o_we) wo.push_back({d->o_wa, d->o_res});
      if (d->n_fin && !fn) { fn = true; rn = d->n_res; cn = c; }
      if (d->o_fin && !fo) { fo = true; ro = d->o_res; co = c; }
    };
    sample(); tick(); d->start = 0; c = 1;
    while (!(fn && fo) || d->n_act || d->o_act) {
      sample();
      d->clk = 1; d->eval();
      if (++c > 400000) { std::printf("HANG at vector %ld (entry %u x %016llx y %016llx)\nFAIL\n",
                                      v, e, (unsigned long long)x, (unsigned long long)y); return 1; }
    }
    if (rn != ro) {
      if (bad < 20) std::printf("  RESULT %ld %s x %016llx y %016llx: new %016llx ref %016llx\n", v, nm[e],
                                (unsigned long long)x, (unsigned long long)y, (unsigned long long)rn, (unsigned long long)ro);
      ++bad;
    }
    if (wn != wo) {
      if (badw < 20) {
        size_t k = 0;
        while (k < wn.size() && k < wo.size() && wn[k] == wo[k]) k++;
        std::printf("  WRITES %ld %s x %016llx y %016llx: %zu vs %zu writes, first difference at %zu\n", v, nm[e],
                    (unsigned long long)x, (unsigned long long)y, wn.size(), wo.size(), k);
      }
      ++badw;
    }
    sumn[e] += cn; sumo[e] += co; cnt[e]++;
    if (cn > maxn[e]) maxn[e] = cn;
    if (co > maxo[e]) maxo[e] = co;
    for (int g = rint_(0, 2); g > 0; g--) tick();     // an idle gap, sometimes none
  }
  for (int i = 0; i < 5; i++)
    if (cnt[i]) std::printf("  %-4s %8llu  cycles  before mean %5llu max %5llu   R998 mean %4llu max %4llu   (x%.2f)\n", nm[i],
                            cnt[i], sumo[i] / cnt[i], maxo[i], sumn[i] / cnt[i], maxn[i],
                            (double)sumo[i] / (double)sumn[i]);
  std::printf("  %ld vectors (seed %llu): %ld result mismatches, %ld write-sequence mismatches\n", n, seed, bad, badw);
  std::printf(bad || badw || !n ? "FAIL\n" : "PASS\n");
  return bad || badw || !n;
}
