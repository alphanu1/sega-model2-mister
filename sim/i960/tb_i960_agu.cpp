// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// Fuzz harness for i960_agu against the transcribed reference.
//
// Pass 1 is exhaustive over the axes that select behaviour: MEMA/MEMB, all 16
// MEMB modes and all 8 scales, crossed with operand patterns. Pass 2 targets
// the arithmetic that is easy to get wrong — the mode-5 post-increment IP, the
// MEMA offset being zero-extended rather than signed, and scaled indices that
// overflow 32 bits. Pass 3 is random.

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <random>
#include "Vi960_agu.h"
#include "verilated.h"
#include "i960_agu_ref.h"

namespace {
Vi960_agu *dut = nullptr;
uint64_t checks = 0, fails = 0;
const int MAX_REPORT = 20;

void check(uint32_t insn, uint32_t ab, uint32_t ix, uint32_t dp, uint32_t ip,
           const char *why) {
  // The AGU port is 14 bits — see the module header for why.
  dut->insn = insn & 0x3fffu;
  dut->abase_val = ab;
  dut->index_val = ix;
  dut->disp_word = dp; dut->ip_after_disp = ip;
  dut->eval();
  const i960ref::AguOut r = i960ref::agu(insn, ab, ix, dp, ip);
  struct { const char *n; uint32_t got, want; bool active; } f[] = {
    { "valid",      dut->valid,      r.valid,      true },
    { "needs_disp", dut->needs_disp, r.needs_disp, true },
    { "ea",         dut->ea,         r.ea,         r.valid },
  };
  for (const auto &x : f) {
    if (!x.active) continue;
    ++checks;
    if (x.got != x.want) {
      if (fails < MAX_REPORT)
        std::printf("  MISMATCH [%s] insn=%08x ab=%08x ix=%08x dp=%08x ip=%08x "
                    "%-10s got=%08x want=%08x\n", why, insn, ab, ix, dp, ip,
                    x.n, x.got, x.want);
      ++fails;
    }
  }
}

void pass_structural() {
  const uint32_t vals[] = {0u, 1u, 0xffffffffu, 0x80000000u, 0x00001234u};
  uint64_t n = 0;
  for (uint32_t memb = 0; memb < 2; ++memb)
    for (uint32_t mode = 0; mode < 16; ++mode)
      for (uint32_t scale = 0; scale < 8; ++scale)
        for (uint32_t v : vals) {
          uint32_t insn = (0x90u << 24) | (memb << 12) | (mode << 10) | (scale << 7) | 0x1fu;
          check(insn, v, v, v, v, "structural");
          ++n;
        }
  std::printf("  pass 1 structural : %llu vectors\n", (unsigned long long)n);
}

void pass_directed() {
  uint64_t n = 0;
  // Mode 5 adds the POST-increment IP. An off-by-four here is a silently wrong
  // target rather than a crash, so it gets its own sweep.
  for (uint32_t ip : {0u, 4u, 0x1000u, 0xfffffffcu, 0xffffffffu})
    for (uint32_t dp : {0u, 4u, 0x7fffffffu, 0x80000000u, 0xffffffffu}) {
      check((0x90u << 24) | (1u << 12) | (0x5u << 10), 0, 0, dp, ip, "mode5-ip");
      ++n;
    }
  // MEMA offset is zero-extended, not sign-extended. 0x1fff is the largest,
  // and its top bit set would flip the answer if it were signed.
  for (uint32_t off = 0x1ff0; off <= 0x1fff; ++off)
    for (uint32_t rel = 0; rel < 2; ++rel) {
      check((0x90u << 24) | (rel << 13) | off, 0xfffffff0u, 0, 0, 0, "mema-zext");
      ++n;
    }
  // Scaled index overflow: a shift of 7 on a large value discards the top bits.
  for (uint32_t sc = 0; sc < 8; ++sc)
    for (uint32_t ix : {0x01000000u, 0x80000000u, 0xffffffffu}) {
      check((0x90u << 24) | (1u << 12) | (0x7u << 10) | (sc << 7), 0x1000, ix, 0, 0, "scale-ovf");
      ++n;
    }
  std::printf("  pass 2 directed   : %llu vectors\n", (unsigned long long)n);
}

void pass_random(uint64_t n, uint64_t seed) {
  std::mt19937_64 rng(seed);
  for (uint64_t i = 0; i < n; ++i)
    check((uint32_t)rng(), (uint32_t)rng(), (uint32_t)rng(),
          (uint32_t)rng(), (uint32_t)rng(), "random");
  std::printf("  pass 3 random     : %llu vectors (seed %llu)\n",
              (unsigned long long)n, (unsigned long long)seed);
}
} // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  uint64_t n = 5000000, seed = 1;
  for (int i = 1; i < argc; ++i) {
    if (!std::strncmp(argv[i], "+random=", 8)) n = std::strtoull(argv[i] + 8, nullptr, 10);
    if (!std::strncmp(argv[i], "+seed=", 6))   seed = std::strtoull(argv[i] + 6, nullptr, 10);
  }
  dut = new Vi960_agu;
  std::printf("i960_agu vs reference\n");
  pass_structural(); pass_directed(); pass_random(n, seed);
  dut->final(); delete dut;
  std::printf("  %llu field checks, %llu mismatches\n",
              (unsigned long long)checks, (unsigned long long)fails);
  if (fails) { std::printf("FAIL\n"); return 1; }
  std::printf("PASS\n"); return 0;
}
