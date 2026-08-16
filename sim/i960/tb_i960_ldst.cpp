// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Harness for i960_ldst. The opcode and address-offset axes are small enough
// to cover exhaustively: all 256 opcode bytes x 4 offsets. Nothing is sampled.
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <random>
#include "Vi960_ldst.h"
#include "verilated.h"
#include "i960_ldst_ref.h"

namespace {
Vi960_ldst *dut = nullptr;
uint64_t checks = 0, fails = 0;
const int MAX_REPORT = 20;

void check(uint8_t op, uint8_t lo, uint32_t rd, uint32_t sv, const char *why) {
  dut->op = op; dut->addr_lo = lo; dut->rd_data = rd; dut->st_value = sv;
  dut->eval();
  const i960ref::LdSt r = i960ref::ldst(op, lo, rd, sv);
  const bool m = r.valid;
  struct { const char *n; uint32_t got, want; bool active; } f[] = {
    { "valid",     dut->valid,     r.valid,     true },
    { "is_load",   dut->is_load,   r.is_load,   true },
    { "is_store",  dut->is_store,  r.is_store,  true },
    { "no_mem",    dut->no_mem,    r.no_mem,    true },
    { "size",      dut->size,      r.size,      m },
    { "sign_ext",  dut->sign_ext,  r.sign_ext,  m },
    { "n_words",   dut->n_words,   r.n_words,   m },
    { "unaligned", dut->unaligned, r.unaligned, m },
    { "ld_result", dut->ld_result, r.ld_result, m && r.is_load },
    { "st_data",   dut->st_data,   r.st_data,   m && r.is_store },
    { "st_be",     dut->st_be,     r.st_be,     m && r.is_store },
  };
  for (const auto &x : f) {
    if (!x.active) continue;
    ++checks;
    if (x.got != x.want) {
      if (fails < MAX_REPORT)
        std::printf("  MISMATCH [%s] op=%02x lo=%d rd=%08x sv=%08x %-10s "
                    "got=%08x want=%08x\n", why, op, lo, rd, sv, x.n, x.got, x.want);
      ++fails;
    }
  }
}
} // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  uint64_t n = 2000000, seed = 1;
  for (int i = 1; i < argc; ++i) {
    if (!std::strncmp(argv[i], "+random=", 8)) n = std::strtoull(argv[i] + 8, nullptr, 10);
    if (!std::strncmp(argv[i], "+seed=", 6))   seed = std::strtoull(argv[i] + 6, nullptr, 10);
  }
  dut = new Vi960_ldst;
  std::printf("i960_ldst vs reference\n");

  // Exhaustive over opcode and offset, with patterns that make sign extension
  // and lane selection visible: 0x80 in each byte lane flips a sign bit.
  const uint32_t pats[] = {0x00000000u, 0xffffffffu, 0x80808080u, 0x7f7f7f7fu,
                           0x12345678u, 0x8000ffffu, 0x0000ff80u};
  uint64_t c = 0;
  for (uint32_t op = 0; op < 256; ++op)
    for (uint32_t lo = 0; lo < 4; ++lo)
      for (uint32_t p : pats)
        for (uint32_t s : pats) { check((uint8_t)op, (uint8_t)lo, p, s, "exhaustive"); ++c; }
  std::printf("  exhaustive opcode x offset : %llu vectors\n", (unsigned long long)c);

  std::mt19937_64 rng(seed);
  const uint8_t real_ops[] = {0x80,0x82,0x88,0x8a,0x8c,0x90,0x92,0x98,0x9a,
                              0xa0,0xa2,0xb0,0xb2,0xc0,0xc2,0xc8,0xca};
  for (uint64_t k = 0; k < n; ++k)
    check(real_ops[rng() % (sizeof real_ops)], (uint8_t)(rng() & 3),
          (uint32_t)rng(), (uint32_t)rng(), "random");
  std::printf("  random over implemented ops: %llu vectors (seed %llu)\n",
              (unsigned long long)n, (unsigned long long)seed);

  dut->final(); delete dut;
  std::printf("  %llu field checks, %llu mismatches\n",
              (unsigned long long)checks, (unsigned long long)fails);
  if (fails) { std::printf("FAIL\n"); return 1; }
  std::printf("PASS\n"); return 0;
}
