// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// First light for the real I/O firmware. Loads EPR-14869C into the Z80 board
// and WATCHES: every DPRAM write the firmware makes, timestamped; the status
// and flag bytes R40 measured from the outside; and whether the board writes
// the identity/settings region R41 concluded it must not.
//
// CEN_DIV=2 by default: a 24 MHz Z80 instead of 4 MHz. The firmware's delay
// loops compress 6x and its behaviour is unchanged -- the same program runs
// the same instructions in the same order. +cendiv=12 gives real pacing.
//
// PASS here is deliberately weak -- the firmware ran and wrote SOMETHING --
// because this harness is a discovery instrument first. The strong assertions
// come once its testimony has been read.

#include "Vm2_ioz80_harness.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include <string>
#include <map>

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
  std::printf("m2_ioz80: firmware %zu bytes from %s\n", n, fw_path);

  uint64_t cycles = 40'000'000;
  for (int i = 1; i < argc; i++)
    if (!std::strncmp(argv[i], "+cycles=", 8))
      cycles = std::strtoull(argv[i] + 8, nullptr, 10);

  // Idle inputs: everything released, active low; gearbox (in1[6:4]) neutral.
  // M2_IN0 overrides the idle cabinet inputs. MAME's oracle: DPRAM byte 0x08
  // reads FF idle and FB with Service Mode (the TEST switch) held, so driving
  // in0=0xfb here must produce the same byte if our port wiring is right.
  unsigned in0v = 0xff;
  if (const char *iv = std::getenv("M2_IN0")) in0v = std::strtoul(iv, nullptr, 16);
  d->in0 = in0v; d->in1 = 0x8f; d->in2 = 0xff;
  d->adc0 = 0x80; d->adc1 = 0x20; d->adc2 = 0x20; d->adc3 = 0x80;
  d->g_we = 0; d->g_addr = 0; d->g_wdata = 0;

  auto tick = [&]() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); };

  // Load the first 16 KB while in reset.
  d->rst_n = 0; d->fw_we = 0;
  for (int i = 0; i < 4; ++i) tick();
  for (int a = 0; a < 8192; ++a) {
    d->fw_we = 1; d->fw_addr = a;
    d->fw_data = fw[a*2] | (fw[a*2+1] << 8); tick();
  }
  d->fw_we = 0;
  for (int i = 0; i < 8; ++i) tick();
  d->rst_n = 1;

  // REPLAY THE GAME'S SIDE. M2_DPLOG names a dialogue captured from the boot
  // harness (W addr val insn); the writes are replayed through the game port
  // at a scaled time, and the firmware's responses are what this whole
  // harness exists to observe. The opening move, discovered by watching the
  // firmware poll: the game writes "SEGA" into bytes 0x1a-0x1d and raises the
  // flag at 0x20 -- the wake-up handshake no HLE ever knew about.
  struct DpEv { uint16_t a; uint8_t v; uint64_t at; };
  std::vector<DpEv> replay;
  if (const char *dl = std::getenv("M2_DPLOG")) {
    FILE *g = std::fopen(dl, "r");
    char op; unsigned a, v, insn;
    while (g && std::fscanf(g, " %c %x %x %u", &op, &a, &v, &insn) == 4)
      if (op == 'W') replay.push_back({uint16_t(a), uint8_t(v),
                                       uint64_t(insn) * 8});
    if (g) std::fclose(g);
    std::printf("  replaying %zu game-side writes\n", replay.size());
  }
  size_t rp = 0;

  // Watch.
  uint64_t writes = 0;
  std::map<uint16_t, uint8_t> last;         // final value per address
  std::map<uint16_t, uint64_t> first_at;    // first-write cycle per address
  int logged = 0;
  uint64_t status40_at = 0;

  int m1_prev = 1, pcs = 0;
  uint8_t ee_prev = 0; int ee_log = 0;
  for (uint64_t t = 0; t < cycles; ++t) {
    d->g_we = 0;
    if (rp < replay.size() && t >= replay[rp].at) {
      d->g_we = 1; d->g_addr = replay[rp].a; d->g_wdata = replay[rp].v;
      if (replay[rp].a >= 0x110 && replay[rp].a < 0x118) {
        static int glog = 0;
        if (glog < 30)
          { std::printf("  GAME dp[%03x] <= %02x  (cycle %llu)\n", replay[rp].a,
                        replay[rp].v, (unsigned long long)t); ++glog; }
      }
      ++rp;
    }
    tick();
    if (!d->spy_m1_n && m1_prev && t > 39800000 && pcs < 60) {
      std::printf("  fetch %04x  (cycle %llu)\n", d->spy_a, (unsigned long long)t);
      ++pcs;
    }
    m1_prev = d->spy_m1_n;
    static int wlog = 0;
    static uint16_t a_prev = 0xffff; static int alog = 0;
    if (d->spy_a != a_prev && alog < 50 && t > 400 && t < 900) {
      std::printf("  A=%04x di=%02x  (cycle %llu)\n", d->spy_a, d->spy_di,
                  (unsigned long long)t);
      a_prev = d->spy_a; ++alog;
    }
    if (d->spy_wr && (d->spy_a & 0xfff0) == 0x8000 && t > 39000000 && wlog < 40) {
      std::printf("  IOW [%04x] <= %02x  (cycle %llu)\n", d->spy_a, d->spy_dout,
                  (unsigned long long)t);
      ++wlog;
    }
    static int rlog = 0;
    if (d->spy_rd_end && (d->spy_ra & 0xfff0) == 0x8000 && t > 39000000 && rlog < 40) {
      std::printf("  IOR [%04x] -> %02x  (cycle %llu)\n", d->spy_ra, d->spy_rdat,
                  (unsigned long long)t);
      ++rlog;
    }
    if (d->spy_ee != ee_prev && ee_log < 4000) {
      std::printf("  EE cs=%d clk=%d di=%d do=%d st=%d ewen=%d  (cycle %llu)\n",
                  (d->spy_ee>>7)&1, (d->spy_ee>>6)&1, (d->spy_ee>>5)&1,
                  (d->spy_ee>>4)&1, (d->spy_ee>>1)&7, d->spy_ee&1,
                  (unsigned long long)t);
      ++ee_log; ee_prev = d->spy_ee;
    }
    if (d->spy_we) {
      ++writes;
      const uint16_t a = d->spy_addr;
      if (!first_at.count(a)) {
        first_at[a] = t;
        if (logged < 60) {
          std::printf("  first write dp[%03x] <= %02x  (cycle %llu)\n",
                      a, d->spy_data, (unsigned long long)t);
          ++logged;
        }
      }
      last[a] = d->spy_data;
      if (a >= 0x110 && a < 0x118) {
        static int slog = 0;
        if (slog < 30) {
          std::printf("  FW  dp[%03x] <= %02x  (cycle %llu)\n", a, d->spy_data,
                      (unsigned long long)t);
          ++slog;
        }
      }
      // THE ORDERING QUESTION (R64): flag/status writes and window fills,
      // every one, timestamped -- does the firmware clear the flag before
      // or after the window holds settings?
      if (a == 0x20 || a == 0x21) {
        static int flog = 0;
        if (flog < 200) {
          std::printf("  FLAG dp[%02x] <= %02x  (cycle %llu)\n", a,
                      d->spy_data, (unsigned long long)t);
          ++flog;
        }
      } else if (a >= 0x100 && a < 0x180) {
        static int wlog2 = 0; static uint64_t wlast = 0;
        // First write of each burst and every 32nd after, so a 128-byte
        // fill reads as a few lines, not 128.
        if (wlog2 < 400 && (t - wlast > 2000 || ((a & 0x1f) == 0))) {
          std::printf("  WIN  dp[%03x] <= %02x  (cycle %llu)\n", a,
                      d->spy_data, (unsigned long long)t);
          ++wlog2;
        }
        wlast = t;
      }
      if (a == 0x21 && d->spy_data == 0x40 && !status40_at) {
        status40_at = t;
        std::printf("  >>> status 0x40 at dp[0x21], cycle %llu -- the R40 "
                    "handshake, from the firmware itself\n",
                    (unsigned long long)t);
      }
    }
  }

  std::printf("  write strobes: io=%d any=%d\n", d->spy_wrcnt >> 8, d->spy_wrcnt & 0xff);
  std::printf("  total Z80->DPRAM writes: %llu, distinct addresses: %zu\n",
              (unsigned long long)writes, last.size());
  std::printf("  regions touched:\n");
  {
    const struct { uint16_t lo, hi; const char *name; } rgn[] = {
      {0x000, 0x00f, "input/panel 0x00-0x0f"},
      {0x010, 0x01f, "0x10-0x1f"},
      {0x020, 0x02f, "flag/status 0x20-0x2f"},
      {0x100, 0x17f, "window 0x100-0x17f"},
      {0x200, 0x27f, "identity/settings block 0x200-0x27f"},
    };
    for (auto &r : rgn) {
      int cnt = 0;
      for (auto &kv : last) if (kv.first >= r.lo && kv.first <= r.hi) ++cnt;
      std::printf("    %-36s %d addresses\n", r.name, cnt);
    }
  }
  // The block R41 ruled on, as the firmware left it.
  std::printf("  dp[0x200..0x21f] final: ");
  for (int a = 0x200; a < 0x220; ++a)
    std::printf("%02x ", last.count(a) ? last[a] : 0x00);
  std::printf("\n  dp[0x100..0x11f] final: ");
  for (int a = 0x100; a < 0x120; ++a)
    std::printf("%02x ", last.count(a) ? last[a] : 0xee);   // ee = firmware never wrote
  std::printf("\n  dp[0x00..0x0f] final:   ");
  for (int a = 0; a < 0x10; ++a)
    std::printf("%02x ", last.count(a) ? last[a] : 0xee);
  std::printf("\n  dp[0x20..0x2f] final:   ");
  for (int a = 0x20; a < 0x30; ++a)
    std::printf("%02x ", last.count(a) ? last[a] : 0x00);
  std::printf("\n");

  const bool ok = writes > 0;
  std::printf("m2_ioz80: %s\n", ok ? "PASS" : "FAIL");
  delete d;
  return ok ? 0 : 1;
}
