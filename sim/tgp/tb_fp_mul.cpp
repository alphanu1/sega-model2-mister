// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE for the full text.
//
// fp_mul fuzz harness — reference is the host C float, matching MAME's
// evaluation model (MAME uses host floats via u2f/f2u).
//
// Denormal results are excluded: the RTL flushes, MAME does not. That
// divergence is a deliberate open question to be resolved against the real
// TGP microcode traces, not against the host.

#include "Vfp_mul.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <random>

static uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static float    u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }

static bool is_denorm(uint32_t u) {
  return ((u >> 23) & 0xff) == 0 && (u & 0x7fffff) != 0;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* dut = new Vfp_mul;

  auto tick = [&]() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
  };

  dut->rst_n = 0; dut->in_valid = 0;
  for (int i = 0; i < 4; i++) tick();
  dut->rst_n = 1;

  std::mt19937 rng(20260814u);
  std::uniform_int_distribution<uint32_t> dist(0, 0xffffffffu);

#ifdef FPM_SUBNORM
  // R852: SUBNORM=1 -- subnormal operands and results are checked too, and
  // half the random operands are drawn near or below the normal range.
  const int N = 4000000;
#else
  const int N = 2000000;
#endif
  struct Pend { uint32_t a, b; bool live; };
  // Depth follows fp_mul's latency, now 4 to match fp_add after the retime.
  Pend pipe[6] = {};
  long checked = 0, skipped = 0, fails = 0, sub_n = 0;

  // Interesting operands seeded ahead of the random stream.
  const uint32_t seeds[] = {
    0x00000000, 0x80000000,             // +0 -0
    0x3f800000, 0xbf800000,             // +1 -1
    0x7f800000, 0xff800000,             // +inf -inf
    0x7fc00000, 0x7f800001,             // qNaN sNaN
    0x00800000, 0x007fffff,             // smallest normal, largest denorm
    0x7f7fffff, 0xff7fffff,             // largest finite
    0x40000000, 0x3eaaaaab,             // 2.0, 1/3
  };
  const int NS = sizeof(seeds) / sizeof(seeds[0]);

  for (int i = 0; i < N + 4; i++) {
    uint32_t a, b;
    if (i < NS * NS) { a = seeds[i / NS]; b = seeds[i % NS]; }
    else             { a = dist(rng);     b = dist(rng);     }
#ifdef FPM_SUBNORM
    // (2m+1)/2 ulps of 2^-149 plus (2m+1) * 2^-173 * 2^-23: a near-tie that only the
    // bits the denormalising shift drops decide (rounds up; even without them)
    if (i >= NS * NS && i < NS * NS + 4096) {
      const uint32_t m = uint32_t(i - NS * NS) & 2047;
      // a = (1 + 2^-23) * 2^-40, b = (2m+1) * 2^-110: both normal, so the
      // product's low bits lie ~46 bits below the subnormal ulp
      a = 0x2b800001u | ((i & 2048) ? 0x80000000u : 0u); b = f2u(std::ldexp(float(2 * m + 1), -110));
    }
#endif
#ifdef FPM_SUBNORM
    if (i >= NS * NS) {
      const uint32_t r = dist(rng);
      if (r & 1) a = (a & 0x807fffffu) | ((r >> 1) & 0x07) << 23;            // exponent 0-7
      if (r & 2) b = (b & 0x807fffffu) | ((((r >> 4) & 0x7f) + 0x40) << 23); // exponent 64-191
      if ((r & 0x30) == 0x10) a &= 0x80000fffu;                              // a tiny subnormal
      if ((r & 0xc0) == 0x40) std::swap(a, b);
      if ((r & 0x700) == 0x100) {
        // sparse significands whose product lands just below 2^-126: ties and
        // near-ties decided only by bits the denormalising shift drops
        const uint32_t ea = 1 + ((r >> 12) & 0x3f), eb = 126 - ea - ((r >> 18) & 0x1f) + 64;
        a = (r & 0x80000000u) | (ea << 23) | (((r >> 20) & 7) << 20) | 1;
        b = ((r << 1) & 0x80000000u) | ((eb & 0xff) << 23) | (((r >> 24) & 7) << 20);
      }
    }
#endif

    bool feed = (i < N);
    dut->in_valid = feed;
    dut->a = a;
    dut->b = b;

    for (int s = 5; s > 0; s--) pipe[s] = pipe[s - 1];
    pipe[0] = { a, b, feed };

    tick();

    if (dut->out_valid && pipe[3].live) {
      float ref_f = u2f(pipe[3].a) * u2f(pipe[3].b);
      uint32_t ref = f2u(ref_f);
      uint32_t got = dut->result;

      // Denormal INPUTS are out of scope: the RTL has no pre-normaliser.
      // Denormal RESULTS are out of scope: the RTL flushes, the host does not.
      // Both are tracked as open questions in docs/m0-mb86233-spike.md.
#ifdef FPM_SUBNORM
      if (std::isnan(ref_f)) { skipped++; continue; }
      if (is_denorm(pipe[3].a) || is_denorm(pipe[3].b) || is_denorm(ref)) ++sub_n;
#else
      if (is_denorm(pipe[3].a) || is_denorm(pipe[3].b) ||
          is_denorm(ref) || std::isnan(ref_f)) { skipped++; continue; }
#endif

      checked++;
      if (got != ref) {
        if (fails < 20) {
          printf("MISMATCH a=%08x b=%08x  ref=%08x got=%08x  (%g * %g = %g, got %g)\n",
                 pipe[3].a, pipe[3].b, ref, got,
                 u2f(pipe[3].a), u2f(pipe[3].b), ref_f, u2f(got));
        }
        fails++;
      }
    }
  }

  printf("fp_mul: checked=%ld (with a subnormal operand or result: %ld) skipped=%ld fails=%ld\n", checked, sub_n, skipped, fails);
  delete dut;
  return fails ? 1 : 0;
}
