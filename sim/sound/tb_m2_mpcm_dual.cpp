// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// ONE MULTIPCM ENGINE FOR BOTH CHIPS, AGAINST THE TWO IT REPLACES (R821).
//
// m2_multipcm_dual and two m2_multipcm run side by side on the same register
// writes, each behind the board's own m2_pcm_fetch, and every output sample
// of each chip is compared bit for bit.
//
// WHERE THE WRITES LAND. A chip's output depends on its register state at
// each slot's step, and on nothing else; but WHEN a write lands relative to
// the slots depends on the engine's timing -- which, for the single chip,
// already moves with memory latency (R91). So the writes due at a sample are
// applied with every engine stopped at the end of its own pass (enable held
// low after its strobe), and each engine is restarted on its own. The outputs
// are then a function of the register stream alone, and a difference is a
// difference in what is computed, not in when.
//
// The enables and the memory latency are the things that must NOT matter, so
// they are swept: the enable every cycle, every fourth cycle (the rate stage
// at 80 MHz), or at random; every fetch's latency drawn at random up to
// M2_DUAL_LMAX cycles (the board's SDRAM answers in tens of cycles), and the
// acknowledge held M2_DUAL_HOLD cycles as m2_sdram holds it. The reference's
// own outputs are hashed too: they must not move with any of it either.
//
//   (default)        random register streams on random sample ROMs:
//                    M2_DUAL_SEEDS seeds x M2_DUAL_N samples
//   M2_SND_REGS=...  MAME's own register stream (mame_m2_sound_levels.lua),
//                    on the real sample ROMs under $M2_ROMPATH/daytona93/;
//                    M2_SND_SECS limits it. With M2_SND_MAME=<dir> each chip's
//                    level is also put against MAME's, as tb_m2_mpcm_level C.
//
// Also: every byte each fetcher hands its chip is checked against the ROM,
// and the cycles each engine takes per sample are reported -- the shared
// engine's pass against the slower of the two chips', which is the fetch
// question (R821 Q2).

#include "Vm2_mpcm_dual_harness.h"
#include "verilated.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <string>
#include <vector>
#include <algorithm>
#include <random>

static Vm2_mpcm_dual_harness *d;
static std::vector<uint8_t> rom[2];
static std::mt19937_64 rng;
static int LMIN = 0, LMAX = 6, HOLD = 2, CE_MODE = 0;
static double CE_P = 0.5;
static long cyc = 0;
static long bad_bytes = 0;

struct Port { bool serving = false; int lat = 0; int hold = 0; };
static Port port[4];

static uint64_t line(int chip, uint32_t a8) {
  uint64_t v = 0, a = uint64_t(a8) * 8;
  for (int b = 0; b < 8; ++b)
    v |= uint64_t(a + b < rom[chip].size() ? rom[chip][a + b] : 0xff) << (b * 8);
  return v;
}

static uint32_t maddr(int p) {
  switch (p) { case 0: return d->m_addr0; case 1: return d->m_addr1; case 2: return d->m_addr2; default: return d->m_addr3; }
}
static void set_mdata(int p, uint64_t v) {
  switch (p) { case 0: d->m_data0 = v; break; case 1: d->m_data1 = v; break; case 2: d->m_data2 = v; break; default: d->m_data3 = v; }
}

// The enable each engine gets this cycle, when it is running.
static std::mt19937 cer[3];
static bool ce_pat(int e) {
  switch (CE_MODE) {
    case 0: return true;
    case 1: return (cyc & 3) == 0;                 // the rate stage at 80 MHz: 20/80
    case 2: return ((cyc * 20) % 50) >= 30;          // the rate stage at 50 MHz: 20/50
    default: return std::uniform_real_distribution<double>(0, 1)(cer[e]) < CE_P;
  }
}

static bool run_e[3];
static void tick() {
  for (int p = 0; p < 4; ++p) {
    const bool req = (d->m_req >> p) & 1, ack = (d->m_ack >> p) & 1;
    if (req && !port[p].serving && !ack) {
      port[p].serving = true;
      port[p].lat = LMIN + int(rng() % uint64_t(LMAX - LMIN + 1));
    }
    if (port[p].serving) {
      if (port[p].lat > 0) --port[p].lat;
      else {
        set_mdata(p, line(p & 1, maddr(p)));
        d->m_ack |= (1u << p);
        port[p].hold = HOLD;
        port[p].serving = false;
      }
    }
  }
  d->ce_r0 = run_e[0] && ce_pat(0);
  d->ce_r1 = run_e[1] && ce_pat(1);
  d->ce_d  = run_e[2] && ce_pat(2);
  d->clk = 0; d->eval();
  d->clk = 1; d->eval();
  ++cyc;
  // The byte each chip takes, on the edge it takes it, against the ROM.
  for (int f = 0; f < 4; ++f) {
    if (((d->c_req >> f) & 1) && ((d->c_ack >> f) & 1)) {
      uint32_t a = f == 0 ? d->c_addr0 : f == 1 ? d->c_addr1 : f == 2 ? d->c_addr2 : d->c_addr3;
      uint8_t got = f == 0 ? d->c_data0 : f == 1 ? d->c_data1 : f == 2 ? d->c_data2 : d->c_data3;
      uint8_t want = a < rom[f & 1].size() ? rom[f & 1][a] : 0xff;
      if (got != want && bad_bytes++ < 5)
        std::printf("  BYTE WRONG fetcher %d at %06X: %02X want %02X\n", f, a, got, want);
    }
  }
  for (int p = 0; p < 4; ++p)
    if (port[p].hold > 0 && --port[p].hold == 0) d->m_ack &= ~(1u << p);
}

struct Wr { int chip, off, val; };     // off: 0 data, 2 slot, 4 reg; chip 2/3 = bank of 0/1

static void apply(const Wr &w, int repeat, bool idle_after = true) {
  if (w.chip >= 2) {
    if (w.chip == 2) d->bank0 = w.val & 3; else d->bank1 = w.val & 3;
    return;
  }
  d->cs_r0 = w.chip == 0; d->cs_d0 = w.chip == 0;
  d->cs_r1 = w.chip == 1; d->cs_d1 = w.chip == 1;
  d->addr = w.off / 2; d->wdata = uint8_t(w.val);
  for (int i = 0; i < repeat; ++i) tick();     // a bus cycle holds the select
  d->cs_r0 = d->cs_r1 = d->cs_d0 = d->cs_d1 = 0;
  if (idle_after) tick();
}

static uint64_t hash_ref = 1469598103934665603ULL;
static void fold(uint64_t &h, uint32_t v) {
  for (int k = 0; k < 4; ++k) { h ^= (v >> (8 * k)) & 0xff; h *= 1099511628211ULL; }
}

struct Stat { long n = 0, sum = 0, mx = 0; void add(long c) { ++n; sum += c; if (c > mx) mx = c; } };

// One sample: start every engine, stop each on its own strobe. Returns false
// if an engine never finishes (a hang is a failure, not a long run).
static long smp_diff = 0, smp_n = 0;
static Stat st_r, st_d;
static std::vector<int16_t> keep_d[2], keep_r[2];
static bool keep = false;
static bool one_sample(long n) {
  run_e[0] = run_e[1] = run_e[2] = true;
  long t0 = cyc, done[3] = {0, 0, 0};
  const long LIMIT = 4000000;
  while (run_e[0] || run_e[1] || run_e[2]) {
    tick();
    if (run_e[0] && d->stb_r0) { run_e[0] = false; done[0] = cyc - t0; }
    if (run_e[1] && d->stb_r1) { run_e[1] = false; done[1] = cyc - t0; }
    if (run_e[2] && d->stb_d)  { run_e[2] = false; done[2] = cyc - t0; }
    if (cyc - t0 > LIMIT) {
      std::printf("  HANG at sample %ld: engines still running r0 %d r1 %d dual %d\n",
                  n, run_e[0], run_e[1], run_e[2]);
      return false;
    }
  }
  st_r.add(std::max(done[0], done[1]));
  st_d.add(done[2]);
  const int16_t r[4] = {int16_t(d->r0_l), int16_t(d->r0_r), int16_t(d->r1_l), int16_t(d->r1_r)};
  const int16_t g[4] = {int16_t(d->d0_l), int16_t(d->d0_r), int16_t(d->d1_l), int16_t(d->d1_r)};
  for (int k = 0; k < 4; ++k) fold(hash_ref, uint16_t(r[k]));
  bool same = true;
  for (int k = 0; k < 4; ++k) same = same && r[k] == g[k];
  ++smp_n;
  if (!same) {
    if (smp_diff < 8)
      std::printf("  DIFF sample %ld: ref %d %d | %d %d   shared %d %d | %d %d\n",
                  n, r[0], r[1], r[2], r[3], g[0], g[1], g[2], g[3]);
    ++smp_diff;
  }
  if (keep) {
    keep_r[0].push_back(r[0]); keep_r[0].push_back(r[1]);
    keep_r[1].push_back(r[2]); keep_r[1].push_back(r[3]);
    keep_d[0].push_back(g[0]); keep_d[0].push_back(g[1]);
    keep_d[1].push_back(g[2]); keep_d[1].push_back(g[3]);
  }
  return true;
}

// WRITES IN THE MIDDLE OF A PASS (M2_DUAL_MID=1). Stopping every engine at
// the end of its pass never exercises a write that lands while a pass is
// under way -- the forwarding of a write to the slot about to step, a key-on
// picked up mid-pass. So, per sample, one chip c and one slot s are drawn,
// and that chip's writes are applied with both engines stopped at the same
// place: just before slot s of chip c steps, with nothing of chip c's in
// flight. Both then compute the same thing by construction of the claim --
// slots before s with the old registers, s and after with the new -- and any
// difference is a fault in how a mid-pass write is taken.
static bool run_dual_to(int c, int s) {
  long t0 = cyc;
  run_e[0] = run_e[1] = false;
  if (!(d->d_v == ((s << 1) | c) && d->d_tick == 0)) {
    run_e[2] = true;
    while (!(d->d_v == ((s << 1) | c) && d->d_tick == 0)) {
      tick();
      if (d->stb_d || cyc - t0 > 4000000) { run_e[2] = false; return false; }
    }
    run_e[2] = false;
  }
  while ((d->d_busy >> c) & 1 || d->d_pm) { tick(); if (cyc - t0 > 4000000) return false; }
  return true;
}
static bool run_ref_to(int c, int s) {
  long t0 = cyc;
  auto at = [&]() { return c ? (d->r1_slot == s && d->r1_tick == 0) : (d->r0_slot == s && d->r0_tick == 0); };
  run_e[0] = run_e[1] = run_e[2] = false;
  if (at()) return true;
  run_e[c] = true;
  while (!at()) {
    tick();
    if ((c ? d->stb_r1 : d->stb_r0) || cyc - t0 > 4000000) { run_e[c] = false; return false; }
  }
  run_e[c] = false;
  for (int i = 0; i < 8; ++i) tick();     // let any acknowledge's add land
  return true;
}
static long mid_points = 0, mid_writes = 0;

static void reset_all() {
  d->rst = 1;
  d->cs_r0 = d->cs_r1 = d->cs_d0 = d->cs_d1 = 0;
  d->m_ack = 0; d->bank0 = 0; d->bank1 = 0;
  for (auto &p : port) p = Port();
  run_e[0] = run_e[1] = run_e[2] = false;
  for (int i = 0; i < 8; ++i) tick();
  d->rst = 0;
  tick();
}

static bool load(const std::string &p, std::vector<uint8_t> &v) {
  FILE *f = std::fopen(p.c_str(), "rb");
  if (!f) return false;
  std::fseek(f, 0, SEEK_END); long n = std::ftell(f); std::fseek(f, 0, SEEK_SET);
  size_t o = v.size(); v.resize(o + size_t(n));
  size_t g = std::fread(v.data() + o, 1, size_t(n), f);
  std::fclose(f);
  return g == size_t(n);
}

static int env_i(const char *n, int dflt) { const char *s = std::getenv(n); return s ? std::atoi(s) : dflt; }

// ---------------------------------------------------------------- synthetic
// 512 descriptors at 0 on a random 4 MB image, each a random start, length
// and loop (some with no loop: the position runs past the end, reading
// whatever is there, deterministically, in both).
static void make_rom(int chip, std::mt19937_64 &g) {
  rom[chip].resize(4u << 20);
  for (auto &b : rom[chip]) b = uint8_t(g());
  for (int s = 0; s < 512; ++s) {
    uint32_t start = 0x2000 + uint32_t(g() % ((4u << 20) - 0x12000));
    uint32_t len = 16 + uint32_t(g() % 65000);
    uint32_t loop = (g() % 8 == 0) ? len : uint32_t(g() % len);
    uint8_t *p = &rom[chip][s * 12];
    p[0] = uint8_t(((start >> 16) & 0x3f) | ((g() & 1) << 6));
    p[1] = uint8_t(start >> 8); p[2] = uint8_t(start);
    p[3] = uint8_t(loop >> 8);  p[4] = uint8_t(loop);
    uint32_t e = (0x10000 - len) & 0xffff;
    p[5] = uint8_t(e >> 8);     p[6] = uint8_t(e);
  }
}

static void random_writes(std::mt19937_64 &g, std::vector<Wr> &out, bool init) {
  auto slotsel = [&](int s) { return s + s / 7; };
  int n = init ? 200 : int(g() % 9);
  for (int i = 0; i < n; ++i) {
    int chip = int(g() & 1);
    if (g() % 64 == 0) { out.push_back({2 + chip, 0, int(g() & 3)}); continue; }
    int s = int(g() % 28);
    int sel = (g() % 50 == 0) ? int(8 * (g() % 4) + 7) : slotsel(s);   // sometimes a hole
    out.push_back({chip, 2, sel});
    int r = int(g() % 8);
    int val;
    switch (r) {
      case 1: val = int(g() & 0xff); break;
      case 3: val = int(((g() % 5) << 4) | (g() & 0xf)); if (g() % 8 == 0) val = int(g() & 0xff); break;
      case 4: val = (g() % 3) ? 0x80 : 0x00; break;
      default: val = int(g() & 0xff);
    }
    out.push_back({chip, 4, r});
    out.push_back({chip, 0, val});
  }
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_mpcm_dual_harness;
  LMIN = env_i("M2_DUAL_LMIN", 0);
  LMAX = env_i("M2_DUAL_LMAX", 6);
  HOLD = env_i("M2_DUAL_HOLD", 2);
  CE_MODE = env_i("M2_DUAL_CE", 0);
  CE_P = std::getenv("M2_DUAL_CEP") ? std::atof(std::getenv("M2_DUAL_CEP")) : 0.5;
  const int REP = env_i("M2_DUAL_REP", 3);         // cycles a write holds its select, max
  const bool MID = env_i("M2_DUAL_MID", 0) != 0;
  for (int e = 0; e < 3; ++e) cer[e].seed(1234 + 77 * e);
  int fails = 0;

  const char *rp = std::getenv("M2_SND_REGS");
  if (!rp) {
    const int SEEDS = env_i("M2_DUAL_SEEDS", 4);
    const long N = env_i("M2_DUAL_N", 6000);
    for (int seed = 1; seed <= SEEDS; ++seed) {
      std::mt19937_64 g(uint64_t(seed) * 0x9E3779B97F4A7C15ULL);
      rng.seed(uint64_t(seed) * 31 + 7);
      make_rom(0, g); make_rom(1, g);
      // A fresh model a seed: power-up, where both designs' sample numbers
      // read 0. A reset alone is NOT the same thing -- the reference clears
      // its sample-number flip-flops in reset and the shared engine's MLAB
      // keeps them (item 5 of its header) -- and seed 2 after seed 1 without
      // this differs in 1,981 of 2,000 samples for exactly that reason.
      delete d; d = new Vm2_mpcm_dual_harness; cyc = 0;
      reset_all();
      const long d0 = smp_diff;
      std::vector<Wr> w;
      random_writes(g, w, true);
      for (auto &x : w) apply(x, 1 + int(g() % REP));
      for (long n = 0; n < N; ++n) {
        if (g() % 4 == 0) {
          w.clear(); random_writes(g, w, false);
          for (auto &x : w) apply(x, 1 + int(g() % REP));
        }
        if (MID && g() % 2 == 0) {
          const int c = int(g() & 1), sl = int(g() % 28);
          w.clear(); random_writes(g, w, false);
          std::vector<Wr> wc;
          for (auto &x : w) if ((x.chip & 1) == c) wc.push_back(x);
          // Half the time the last write names slot s itself, in one of the
          // registers its step reads (pan, pitch, octave, level).
          if (g() & 1) {
            static const int rr[4] = {0, 2, 3, 5};
            wc.push_back({c, 2, sl + sl / 7});
            wc.push_back({c, 4, rr[g() % 4]});
            wc.push_back({c, 0, int(g() & 0xff)});
          }
          if (!run_dual_to(c, sl) || !run_ref_to(c, sl)) {
            std::printf("  MID: could not stop at chip %d slot %d (sample %ld)\n", c, sl, n);
            ++fails; break;
          }
          // The last write is followed straight away by the enable, so the
          // slot steps on the very next edge: that is the cycle in which its
          // registered RAM read is still the old word and the forward is the
          // only thing carrying the new one.
          for (size_t i = 0; i < wc.size(); ++i)
            apply(wc[i], 1 + int(g() % REP), i + 1 < wc.size());
          ++mid_points; mid_writes += long(wc.size());
        }
        if (!one_sample(n)) { ++fails; break; }
      }
      std::printf("  seed %d: %ld samples x 2 chips, %ld differ\n", seed, N, smp_diff - d0);
    }
  } else {
    // ------------------------------------------------------------ MAME
    const char *romp = std::getenv("M2_ROMPATH");
    const std::string rdir = std::string(romp ? romp : (std::string(std::getenv("HOME") ? std::getenv("HOME") : ".") + "/roms/Model2")) + "/daytona93/";
    if (!(load(rdir + "mpr-16491.32", rom[0]) && load(rdir + "mpr-16492.33", rom[0]) &&
          load(rdir + "mpr-16493.4", rom[1])  && load(rdir + "mpr-16494.5", rom[1]))) {
      std::printf("  SKIP (sample ROMs missing)\n");
      return 0;
    }
    FILE *f = std::fopen(rp, "r");
    if (!f) { std::printf("  SKIP (cannot open %s)\n", rp); return 0; }
    const double SECS = std::getenv("M2_SND_SECS") ? std::atof(std::getenv("M2_SND_SECS")) : 1e9;
    const double RATE = 10000000.0 / 224;
    rng.seed(99);
    reset_all();
    const char *mp = std::getenv("M2_SND_MAME");
    keep = mp != nullptr;
    char ln[256];
    double t; int ch, off, val;
    long n = 0, nw = 0;
    std::mt19937_64 g(5);
    bool ok = true;
    // The writes due before a sample are gathered first. With M2_DUAL_MID one
    // chip's share of them goes in at a random slot of the pass instead of at
    // its start (see run_dual_to); each chip's own writes keep their order.
    std::vector<Wr> pend;
    long pend_due = 0;
    auto flush = [&](long upto) {
      while (ok && n < upto) {
        if (n == pend_due && !pend.empty()) {
          if (MID && (g() & 1)) {
            const int c = int(g() & 1), sl = int(g() % 28);
            std::vector<Wr> wc;
            for (auto &x : pend) { if ((x.chip & 1) == c && x.chip < 2) wc.push_back(x); else apply(x, 1 + int(g() % REP)); }
            if (!run_dual_to(c, sl) || !run_ref_to(c, sl)) { std::printf("  MID: could not stop\n"); ok = false; break; }
            for (size_t i = 0; i < wc.size(); ++i) apply(wc[i], 1 + int(g() % REP), i + 1 < wc.size());
            ++mid_points; mid_writes += long(wc.size());
          } else for (auto &x : pend) apply(x, 1 + int(g() % REP));
          pend.clear();
        }
        if (!one_sample(n)) { ok = false; break; }
        ++n;
        if (n % 446430 == 0) std::printf("  ... %ld s, %ld samples differ\n", n / 44643, smp_diff);
      }
    };
    while (ok && std::fgets(ln, sizeof ln, f)) {
      if (std::sscanf(ln, "%lf %d %d %d", &t, &ch, &off, &val) != 4) continue;
      if (ch == 0) continue;                       // the YM3438
      if (t > SECS) break;
      const long due = long(std::ceil(t * RATE));
      if (due > n) {
        if (!pend.empty() && pend_due < n) pend_due = n;
        flush(due);
      }
      if (pend.empty()) pend_due = n;
      Wr x;
      if (ch == 3 || ch == 4) x = {ch - 1, 0, val};          // banks
      else x = {ch - 1, off, val};
      pend.push_back(x);
      ++nw;
    }
    if (!pend.empty()) flush(n + 1);
    std::fclose(f);
    if (!ok) ++fails;
    std::printf("  MAME stream: %ld writes to the MultiPCMs, %ld samples x 2 chips, %ld differ\n",
                nw, n, smp_diff);
    if (mp) {
      // Each chip against MAME in 2 s windows, as tb_m2_mpcm_level C (ours x4,
      // clamped to one full-scale voice as MAME's stream is).
      for (int c = 0; c < 2; ++c) {
        std::vector<uint8_t> mraw;
        if (!load(std::string(mp) + (c == 0 ? "/pcm1.raw" : "/pcm2.raw"), mraw)) continue;
        const int16_t *m = reinterpret_cast<const int16_t *>(mraw.data());
        const size_t w = size_t(2.0 * RATE);
        const size_t nn = std::min(mraw.size() / 4, keep_d[c].size() / 2);
        double sum = 0, worst = 0; int nwin = 0;
        for (size_t i = 0; i + w <= nn; i += w) {
          double sd = 0, sm = 0;
          for (size_t k = i; k < i + w; ++k)
            for (int s = 0; s < 2; ++s) {
              double o = std::min(32767.0, std::max(-32768.0, keep_d[c][2 * k + s] * 4.0));
              sd += o * o;
              sm += double(m[2 * k + s]) * m[2 * k + s];
            }
          const double md = 10 * std::log10(sm / (2.0 * w) / (32768.0 * 32768.0) + 1e-30);
          const double od = 10 * std::log10(sd / (2.0 * w) / (32768.0 * 32768.0) + 1e-30);
          if (md > -45) { sum += od - md; ++nwin; if (std::fabs(od - md) > std::fabs(worst)) worst = od - md; }
        }
        std::printf("  shared engine, pcm%d against MAME: %d windows, mean %+.2f dB, worst %+.2f dB\n",
                    c + 1, nwin, nwin ? sum / nwin : 0.0, worst);
      }
    }
  }

  std::printf("  cycles a sample (enable mode %d, latency %d..%d, hold %d): reference (slower chip) mean %.0f max %ld | shared mean %.0f max %ld\n",
              CE_MODE, LMIN, LMAX, HOLD, st_r.n ? double(st_r.sum) / st_r.n : 0.0, st_r.mx,
              st_d.n ? double(st_d.sum) / st_d.n : 0.0, st_d.mx);
  std::printf("  reference output hash %016llx (must not move with the enable or the latency)\n",
              (unsigned long long)hash_ref);
  if (MID) std::printf("  mid-pass stops: %ld, writes applied there: %ld\n", mid_points, mid_writes);
  std::printf("  fetched bytes wrong: %ld\n", bad_bytes);
  if (smp_diff) { std::printf("  FAIL %ld of %ld samples differ\n", smp_diff, smp_n); ++fails; }
  if (bad_bytes) ++fails;
  std::printf("m2_mpcm_dual: fails=%d\n%s\n", fails, fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
