// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// THE MULTIPCM's LEVELS, AGAINST MAME (R819).
//
// R703 reported the music and the game-over speech too quiet against the rest
// of the sound. R267 had matched the board's overall level to MAME's and its
// FM-to-sample balance, but nothing had ever compared a VOICE's level against
// the reference, and that is where the difference was: m2_multipcm applied
// the total level as `sample >>> (tl >> 4)` -- 6 dB steps, truncated -- where
// MAME's gew.cpp has 0.375 dB a step, and a pan law of 6 dB per two steps
// where MAME has 3 dB a step. Daytona's music sits at TL 30-60 and its speech
// at TL 0, so the music came out up to 3.5 dB hot and the speech did not.
//
// THREE PARTS.
//
//  A. ONE VOICE, EVERY TOTAL LEVEL AND EVERY PAN. A synthetic sample -- a
//     full-scale square wave this file writes itself, no ROM -- keyed at
//     TL 0..127 and pan 0..15, and its steady amplitude on each side held to
//     MAME's 10^(-(0.375 TL + 3 pan) / 20) within 0.3 dB or 2 LSB. MAME's
//     mutes too: pan 8 both sides, 7 the left, 9 the right.
//
//  B. THE CHIP AT ITS LOUDEST. 1 to 28 voices of that square wave at TL 0,
//     every voice the chip has: the peak must be min(n x one voice, 32767)
//     -- linear until it saturates, and SATURATE, never wrap -- and a wrap
//     anywhere shows up as extra sign changes within a half period.
//
//  C. MAME's OWN REGISTER STREAM (optional). sim/sound/
//     mame_m2_sound_levels.lua captures the sound 68000's MultiPCM writes and
//     each chip's own output from MAME; this replays the writes into the RTL
//     on MAME's sample clock and compares the two chips' levels in 2 s
//     windows, and the ratio between them -- music against effects and
//     speech, which is the thing R703 heard -- with ours clamped to one
//     full-scale voice as MAME's stream is: mean within 0.5 dB, no window
//     past 1.5 (the unclamped figures are printed beside them). Needs
//         M2_SND_REGS=<dir>/regs.log  M2_SND_MAME=<dir>  (pcm1.raw, pcm2.raw)
//     and the sample ROMs under $M2_ROMPATH/daytona93/. M2_SND_SECS limits
//     the replay. Without them part C is skipped, not failed.
//
// Our chip output is the sum of the voices shifted right by two; MAME's is the
// sum at unity and its route gain is 0.5 where the board mixes at 2 (R267). So
// our chip, x4 (+12.04 dB), is in MAME's units, and that is how C compares.

#include "Vm2_mpcm_level_harness.h"
#include "verilated.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <string>
#include <vector>
#include <algorithm>

static Vm2_mpcm_level_harness *d;
static std::vector<uint8_t> rom;
static int lat = 0;
static long nsamp = 0;
static std::vector<int16_t> got_l, got_r;
static bool keep = false;

static void tick() {
  if (d->rom_req && !d->rom_ack) {
    if (++lat >= 2) {
      uint32_t a = d->rom_addr;
      d->rom_data = a < rom.size() ? rom[a] : 0xff;
      d->rom_ack = 1;
      lat = 0;
    }
  } else {
    d->rom_ack = 0;
  }
  d->clk = 0; d->eval();
  d->clk = 1; d->eval();
  d->cs = 0;
  if (d->sample_stb) {
    ++nsamp;
    if (keep) { got_l.push_back(int16_t(d->out_l)); got_r.push_back(int16_t(d->out_r)); }
  }
}

static void wr(int off, int val) {
  d->cs = 1; d->addr = off; d->wdata = uint8_t(val);
  tick();
  tick();
}

static void reg(int slot, int r, int v) {
  wr(1, slot + slot / 7);          // VALUE_TO_CHANNEL: every eighth selector is a hole
  wr(2, r);
  wr(0, v);
}

static void reset_chip() {
  d->rst = 1; d->cs = 0; d->rom_ack = 0; d->bank_sel = 0;
  for (int i = 0; i < 8; ++i) tick();
  d->rst = 0;
  nsamp = 0;
}

static void run_samples(long n) {
  long end = nsamp + n;
  while (nsamp < end) tick();
}

// MAME's gew.cpp: level * -24/64 dB, pan * -12/4 dB, mutes at 8 and at 7/9.
static double mame_gain(int tl, int pan, bool left) {
  if (pan == 8) return 0;
  int p = 0;
  if (pan != 0) {
    if (pan & 8) { if (!left) { int ip = 16 - pan; if ((ip & 7) == 7) return 0; p = ip; } }
    else         { if (left)  { if ((pan & 7) == 7) return 0; p = pan; } }
  }
  return std::pow(10.0, -(0.375 * tl + 3.0 * p) / 20.0);
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

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_mpcm_level_harness;
  int fails = 0;

  // ---------------------------------------------------------------- A
  // Descriptor 0 at address 0: start 0x100, loop 0, end 64 samples; then 32
  // bytes of +127 and 32 of -127. Octave 1, pitch 0 is a step of exactly one
  // sample, so the square wave's period is 64 output samples.
  rom.assign(0x200, 0);
  rom[0] = 0x00; rom[1] = 0x01; rom[2] = 0x00;    // start
  rom[3] = 0x00; rom[4] = 0x00;                   // loop
  rom[5] = 0xff; rom[6] = 0xc0;                   // 0x10000 - 64
  for (int i = 0; i < 64; ++i) rom[0x100 + i] = i < 32 ? 0x7f : 0x81;
  const double ONE = 127.0 * 256.0 / 4.0;         // one voice at unity, at the chip output

  auto measure = [&](double &al, double &ar) {
    got_l.clear(); got_r.clear();
    keep = true; run_samples(256); keep = false;
    auto amp = [](const std::vector<int16_t> &v) {
      int mx = *std::max_element(v.begin(), v.end());
      int mn = *std::min_element(v.begin(), v.end());
      return (mx - mn) / 2.0;
    };
    al = amp(got_l); ar = amp(got_r);
  };

  reset_chip();
  int a_checks = 0, a_fail = 0;
  double worst_db = 0; int worst_tl = -1, worst_pan = -1;
  auto one = [&](int tl, int pan) {
    reg(0, 4, 0x00);
    reg(0, 0, pan << 4);
    reg(0, 5, (tl << 1) | 1);
    reg(0, 2, 0x00);
    reg(0, 3, 0x10);
    reg(0, 1, 0x00);
    reg(0, 4, 0x80);
    run_samples(200);
    double al, ar;
    measure(al, ar);
    for (int s = 0; s < 2; ++s) {
      double got = s ? ar : al;
      double want = ONE * mame_gain(tl, pan, s == 0);
      double tol = std::max(2.0, want * (std::pow(10.0, 0.3 / 20.0) - 1.0));
      ++a_checks;
      if (std::fabs(got - want) > tol) {
        if (a_fail < 8)
          std::printf("  A FAIL TL %3d pan %2d %s: amplitude %.1f, MAME %.1f\n",
                      tl, pan, s ? "R" : "L", got, want);
        ++a_fail;
      }
      if (want > 8.0) {
        double db = 20.0 * std::log10(std::max(got, 0.5) / want);
        if (std::fabs(db) > std::fabs(worst_db)) { worst_db = db; worst_tl = tl; worst_pan = pan; }
      }
    }
  };
  for (int tl = 0; tl < 128; ++tl) one(tl, 0);
  for (int tl : {0, 37, 100}) for (int pan = 0; pan < 16; ++pan) one(tl, pan);
  std::printf("  A: %d checks (TL 0..127 at pan 0; pan 0..15 at TL 0, 37, 100), %d off MAME; worst %+.2f dB at TL %d pan %d\n",
              a_checks, a_fail, worst_db, worst_tl, worst_pan);
  if (a_fail) ++fails;

  // ---------------------------------------------------------------- B
  int b_fail = 0;
  for (int n = 1; n <= 28; ++n) {
    reset_chip();
    for (int v = 0; v < 28; ++v) reg(v, 4, 0x00);
    for (int v = 0; v < n; ++v) {
      reg(v, 0, 0x00); reg(v, 5, 0x01); reg(v, 2, 0x00); reg(v, 3, 0x10); reg(v, 1, 0x00);
    }
    for (int v = 0; v < n; ++v) reg(v, 4, 0x80);
    run_samples(200);
    got_l.clear(); got_r.clear();
    keep = true; run_samples(640); keep = false;
    int mx = *std::max_element(got_l.begin(), got_l.end());
    int mn = *std::min_element(got_l.begin(), got_l.end());
    int flips = 0;
    for (size_t i = 1; i < got_l.size(); ++i)
      if ((got_l[i] < 0) != (got_l[i - 1] < 0)) ++flips;
    const double want = std::min(32767.0, n * ONE);
    // The voices start a few samples apart (each fetches its descriptor in
    // turn), so the plateau is the sum only once all have started; the peak is.
    bool bad = std::fabs(mx - want) > 2.0 * n || mn > -want + 2.0 * n || mn < -32768
               || flips < 18 || flips > 22;
    if (bad) {
      std::printf("  B FAIL %2d voices: peak %d / %d (want +-%.0f), %d sign changes in 640 samples (want 20)\n",
                  n, mx, mn, want, flips);
      ++b_fail;
    }
    if (n == 1 || n == 4 || n == 5 || n == 28)
      std::printf("  B: %2d voices at TL 0: peak %6d / %6d (want +-%5.0f), %d sign changes\n", n, mx, mn, want, flips);
  }
  if (b_fail) ++fails;

  // ---------------------------------------------------------------- C
  const char *rp = std::getenv("M2_SND_REGS");
  const char *mp = std::getenv("M2_SND_MAME");
  const char *romp = std::getenv("M2_ROMPATH");
  const std::string rdir = std::string(romp ? romp : (std::string(std::getenv("HOME") ? std::getenv("HOME") : ".") + "/roms/Model2")) + "/daytona93/";
  const double SECS = std::getenv("M2_SND_SECS") ? std::atof(std::getenv("M2_SND_SECS")) : 1e9;
  if (!rp || !mp) {
    std::printf("  C: SKIP (set M2_SND_REGS and M2_SND_MAME from sim/sound/mame_m2_sound_levels.lua)\n");
  } else {
    const double RATE = 10000000.0 / 224;
    const double WIN = 2.0;
    // Ours both ways: as the chip produces it, and clamped to one full-scale
    // voice as MAME's stream is (gew.cpp's put_int_clamp). The level law is
    // judged on the clamped one -- MAME's clamp is its own question (R819: the
    // firmware stacks twelve voices for the speech, and our chip and mix keep
    // the headroom) -- and the unclamped one is printed beside it.
    std::vector<double> ours_db[3], ourc_db[3], mame_db[3];
    bool ok = true;
    for (int chip = 1; chip <= 2 && ok; ++chip) {
      rom.clear();
      if (chip == 1) ok = load(rdir + "mpr-16491.32", rom) && load(rdir + "mpr-16492.33", rom);
      else           ok = load(rdir + "mpr-16493.4", rom)  && load(rdir + "mpr-16494.5", rom);
      std::vector<uint8_t> mraw;
      ok = ok && load(std::string(mp) + (chip == 1 ? "/pcm1.raw" : "/pcm2.raw"), mraw);
      if (!ok) { std::printf("  C: SKIP (sample ROMs or MAME capture missing)\n"); break; }
      FILE *f = std::fopen(rp, "r");
      if (!f) { std::printf("  C: SKIP (cannot open %s)\n", rp); ok = false; break; }
      reset_chip();
      got_l.clear(); got_r.clear(); keep = true;
      char line[256];
      double t; int ch, off, val;
      while (std::fgets(line, sizeof line, f)) {
        if (std::sscanf(line, "%lf %d %d %d", &t, &ch, &off, &val) != 4) continue;
        if (ch != chip && ch != chip + 2) continue;
        if (t > SECS) break;
        const long due = long(std::ceil(t * RATE));
        while (nsamp < due) tick();
        if (ch == chip + 2) d->bank_sel = val & 3;
        else { d->cs = 1; d->addr = off / 2; d->wdata = uint8_t(val); tick(); }
      }
      std::fclose(f);
      keep = false;
      const size_t mn = mraw.size() / 4;
      const int16_t *m = reinterpret_cast<const int16_t *>(mraw.data());
      const size_t n = std::min(got_l.size(), mn);
      const size_t w = size_t(WIN * RATE);
      for (size_t i = 0; i + w <= n; i += w) {
        double so = 0, sc = 0, sm = 0;
        for (size_t k = i; k < i + w; ++k) {
          double ol = got_l[k] * 4.0, orr = got_r[k] * 4.0;
          so += ol * ol + orr * orr;
          ol = std::min(32767.0, std::max(-32768.0, ol));
          orr = std::min(32767.0, std::max(-32768.0, orr));
          sc += ol * ol + orr * orr;
          sm += double(m[2 * k]) * m[2 * k] + double(m[2 * k + 1]) * m[2 * k + 1];
        }
        ours_db[chip].push_back(10.0 * std::log10(so / (2.0 * w) / (32768.0 * 32768.0) + 1e-30));
        ourc_db[chip].push_back(10.0 * std::log10(sc / (2.0 * w) / (32768.0 * 32768.0) + 1e-30));
        mame_db[chip].push_back(10.0 * std::log10(sm / (2.0 * w) / (32768.0 * 32768.0) + 1e-30));
      }
    }
    if (ok) {
      const size_t nw = std::min(ours_db[1].size(), ours_db[2].size());
      // [0] pcm1, [1] pcm2, [2] pcm2 - pcm1; c = clamped as MAME's stream is.
      double worst[3] = {0, 0, 0}, sum[3] = {0, 0, 0}, worstu[3] = {0, 0, 0}, sumu[3] = {0, 0, 0};
      int nchk[3] = {0, 0, 0};
      auto book = [&](int k, double e, double eu) {
        sum[k] += e; sumu[k] += eu; ++nchk[k];
        if (std::fabs(e) > std::fabs(worst[k])) worst[k] = e;
        if (std::fabs(eu) > std::fabs(worstu[k])) worstu[k] = eu;
      };
      std::printf("  C: window   pcm1 MAME / ours   pcm2 MAME / ours (unclamped)   pcm2-pcm1 MAME / ours   (dBFS, ours in MAME units)\n");
      for (size_t i = 0; i < nw; ++i) {
        const double m1 = mame_db[1][i], m2 = mame_db[2][i];
        const double o1 = ourc_db[1][i], o2 = ourc_db[2][i], u1 = ours_db[1][i], u2 = ours_db[2][i];
        const bool a1 = m1 > -45, a2 = m2 > -45;
        if (a1) book(0, o1 - m1, u1 - m1);
        if (a2) book(1, o2 - m2, u2 - m2);
        if (a1 && a2) book(2, (o2 - o1) - (m2 - m1), (u2 - u1) - (m2 - m1));
        if (a2)
          std::printf("     %4.0f-%-4.0f  %6.1f / %6.1f    %6.1f / %6.1f (%6.1f)    %6.1f / %6.1f\n",
                      i * WIN, (i + 1) * WIN, m1, o1, m2, o2, u2, m2 - m1, o2 - o1);
      }
      // Mean within 0.5 dB and no window past 1.5: what remains is the
      // envelope, the LFOs, TL interpolation and sample interpolation, none of
      // them built, each under 0.2 dB on the mean (R819).
      const char *nm[3] = {"pcm1 (music)", "pcm2 (effects, speech)", "pcm2 - pcm1"};
      for (int k = 0; k < 3; ++k) {
        const double mean = nchk[k] ? sum[k] / nchk[k] : 0.0;
        std::printf("  C: %-24s %3d windows, mean %+.2f dB, worst %+.2f dB against MAME (unclamped: mean %+.2f, worst %+.2f)\n",
                    nm[k], nchk[k], mean, worst[k], nchk[k] ? sumu[k] / nchk[k] : 0.0, worstu[k]);
        if (nchk[k] && (std::fabs(mean) > 0.5 || std::fabs(worst[k]) > 1.5)) {
          std::printf("  FAIL %s off MAME (mean past 0.5 dB or a window past 1.5)\n", nm[k]);
          ++fails;
        }
      }
    }
  }

  std::printf("m2_mpcm_level: fails=%d\n%s\n", fails, fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
