// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// Fuzz harness for i960_alu against the transcribed reference.
//
// Per-opcode fuzzing, per docs/p1-i960-spike.md §7 criterion 1: every op gets
// its own budget rather than sharing one random stream, so a rare op cannot
// hide behind a common one. 10^6 operand pairs each by default across 37
// implemented ops, plus an exhaustive sweep of the op/op2 space and directed
// vectors at the boundaries this ALU actually has.
//
// Operands are drawn from a biased pool, not uniformly. Uniform 32-bit random
// almost never produces 0, 1, -1, 0x80000000 or a shift count under 32, and
// those are where every one of these operations changes behaviour.

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>

#include "Vi960_alu.h"
#include "verilated.h"
#include "i960_alu_ref.h"

namespace {

Vi960_alu *dut = nullptr;
uint64_t   checks = 0;
uint64_t   fails  = 0;
bool       carry_bug_mode = false;
const int  MAX_REPORT = 24;

struct OpInfo { uint8_t op, op2; const char *name; };

const OpInfo OPS[] = {
  {0x58,0x0,"notbit"},  {0x58,0x1,"and"},     {0x58,0x2,"andnot"},
  {0x58,0x3,"setbit"},  {0x58,0x4,"notand"},  {0x58,0x6,"xor"},
  {0x58,0x7,"or"},      {0x58,0x8,"nor"},     {0x58,0x9,"xnor"},
  {0x58,0xa,"not"},     {0x58,0xb,"ornot"},   {0x58,0xc,"clrbit"},
  {0x58,0xd,"notor"},   {0x58,0xe,"nand"},    {0x58,0xf,"alterbit"},
  {0x59,0x0,"addo"},    {0x59,0x1,"addi"},    {0x59,0x2,"subo"},
  {0x59,0x3,"subi"},    {0x59,0x8,"shro"},    {0x59,0xa,"shrdi"},
  {0x59,0xb,"shri"},    {0x59,0xc,"shlo"},    {0x59,0xd,"rotate"},
  {0x59,0xe,"shli"},
  {0x5a,0x0,"cmpo"},    {0x5a,0x1,"cmpi"},    {0x5a,0x2,"concmpo"},
  {0x5a,0x3,"concmpi"}, {0x5a,0x4,"cmpinco"}, {0x5a,0x5,"cmpinci"},
  {0x5a,0x6,"cmpdeco"}, {0x5a,0x7,"cmpdeci"}, {0x5a,0xc,"scanbyte"},
  {0x5a,0xe,"chkbit"},
  {0x5b,0x0,"addc"},    {0x5b,0x2,"subc"},
};
const int N_OPS = sizeof(OPS) / sizeof(OPS[0]);

bool check_one(uint8_t op, uint8_t op2, uint32_t s1, uint32_t s2, uint32_t ac,
               const char *why, const char *name) {
  dut->op    = op;
  dut->op2   = op2;
  dut->src1  = s1;
  dut->src2  = s2;
  dut->ac_in = ac;
  dut->eval();

  const i960ref::AluOut r = i960ref::alu(op, op2, s1, s2, ac, carry_bug_mode);

  // result is only meaningful when the instruction writes a destination, so
  // comparing it unconditionally would fail on compares for no reason.
  struct { const char *n; uint32_t got, want; bool active; } f[] = {
    { "valid",     dut->valid,     r.valid,     true },
    { "result_we", dut->result_we, r.result_we, true },
    { "result",    dut->result,    r.result,    r.valid && r.result_we },
    { "ac",        dut->ac_out,    r.ac,        r.valid },
  };

  bool ok = true;
  for (const auto &x : f) {
    if (!x.active) continue;
    ++checks;
    if (x.got != x.want) {
      ok = false;
      if (fails < MAX_REPORT)
        std::printf("  MISMATCH %-9s [%s] op=%02x.%x s1=%08x s2=%08x ac=%08x  "
                    "%-9s got=%08x want=%08x\n",
                    name, why, op, op2, s1, s2, ac, x.n, x.got, x.want);
      ++fails;
    }
  }
  return ok;
}

// Values where these operations change behaviour. Uniform random would reach
// almost none of them.
uint32_t biased(std::mt19937_64 &rng) {
  static const uint32_t pool[] = {
    0x00000000u, 0x00000001u, 0x00000002u, 0x0000001fu, 0x00000020u,
    0x00000021u, 0x0000003fu, 0x7ffffffeu, 0x7fffffffu, 0x80000000u,
    0x80000001u, 0xfffffffeu, 0xffffffffu, 0x0000ffffu, 0xffff0000u,
    0xaaaaaaaau, 0x55555555u, 0x000000ffu, 0xff000000u, 0x00ff00ffu,
  };
  const uint64_t r = rng();
  switch (r & 3) {
    case 0:  return pool[(r >> 8) % (sizeof(pool) / sizeof(pool[0]))];
    case 1:  return static_cast<uint32_t>(r >> 16) & 0x3f;   // small: shift counts
    default: return static_cast<uint32_t>(r >> 32);
  }
}

// AC matters as an input to alterbit (bit 1), concmp (bit 2) and addc/subc
// (bit 1 as carry in). Bias toward the low bits and keep the high bits busy so
// a module that fails to preserve them is caught.
uint32_t biased_ac(std::mt19937_64 &rng) {
  const uint64_t r = rng();
  return (static_cast<uint32_t>(r) & 0xfffffff8u) | static_cast<uint32_t>((r >> 40) & 7u);
}

void pass_exhaustive_opspace() {
  // Every op/op2 pair in 0x58-0x5b, implemented or not, so `valid` is checked
  // over the whole space rather than only where it should be true.
  uint64_t n = 0;
  for (uint32_t op = 0x58; op <= 0x5b; ++op)
    for (uint32_t op2 = 0; op2 < 16; ++op2)
      for (uint32_t s1 : {0x00000000u, 0xffffffffu, 0x12345678u})
        for (uint32_t s2 : {0x00000000u, 0xffffffffu, 0x9abcdef0u})
          for (uint32_t ac : {0x00000000u, 0x00000007u}) {
            check_one(static_cast<uint8_t>(op), static_cast<uint8_t>(op2),
                      s1, s2, ac, "opspace", "-");
            ++n;
          }
  std::printf("  pass 1 op space   : %llu vectors\n",
              static_cast<unsigned long long>(n));
}

void pass_directed() {
  // Shift counts either side of 32: the reference does NOT mask to five bits,
  // so a count of 32 or 100 gives zero rather than a wrapped shift. Masking in
  // RTL is the obvious mistake and this is what catches it.
  const uint32_t counts[] = {0, 1, 15, 16, 30, 31, 32, 33, 63, 64, 100, 0xffffffffu};
  const uint32_t vals[]   = {0x00000000u, 0x00000001u, 0x7fffffffu, 0x80000000u,
                             0xffffffffu, 0x80000001u, 0xfffffffeu, 0x0000ff00u};
  uint64_t n = 0;
  for (uint32_t c : counts)
    for (uint32_t v : vals)
      for (uint8_t op2 : {0x8, 0xa, 0xb, 0xc, 0xd, 0xe}) {
        check_one(0x59, op2, c, v, 0, "shift-boundary", "shift");
        ++n;
      }

  // addc/subc carry chains: the pairs that must carry or borrow.
  const struct { uint32_t a, b; } pairs[] = {
    {0xffffffffu, 0x00000001u}, {0x00000001u, 0xffffffffu},
    {0x00000000u, 0x00000001u}, {0x80000000u, 0x80000000u},
    {0x7fffffffu, 0x00000001u}, {0xffffffffu, 0xffffffffu},
    {0x00000000u, 0x00000000u},
  };
  for (const auto &p : pairs)
    for (uint32_t ac : {0x00000000u, 0x00000002u})
      for (uint8_t op2 : {0x0, 0x2}) {
        check_one(0x5b, op2, p.a, p.b, ac, "carry", "addc/subc");
        ++n;
      }

  // scanbyte: one lane matching, all matching, none.
  for (uint32_t s1 : {0x11223344u, 0x11000000u, 0x00000044u, 0xaabbccddu})
    for (uint32_t s2 : {0x11223344u, 0x11ffffffu, 0xffffff44u, 0x00000000u}) {
      check_one(0x5a, 0xc, s1, s2, 0, "scanbyte", "scanbyte");
      ++n;
    }

  // chkbit and the bit ops over every bit position.
  for (uint32_t b = 0; b < 64; ++b)
    for (uint8_t op2 : {0x0, 0x3, 0xc, 0xf}) {
      check_one(0x58, op2, b, 0xa5a5a5a5u, 0x00000002u, "bitpos", "bitop");
      ++n;
    }
  for (uint32_t b = 0; b < 64; ++b) {
    check_one(0x5a, 0xe, b, 0xa5a5a5a5u, 0, "bitpos", "chkbit");
    ++n;
  }

  // concmp is skipped entirely when AC bit 2 is set — not merely unwritten.
  for (uint32_t ac : {0x00000000u, 0x00000004u, 0x00000005u, 0xfffffffbu})
    for (uint8_t op2 : {0x2, 0x3}) {
      check_one(0x5a, op2, 5, 7, ac, "concmp-skip", "concmp");
      ++n;
    }

  std::printf("  pass 2 directed   : %llu vectors\n",
              static_cast<unsigned long long>(n));
}

void pass_per_op(uint64_t per_op, uint64_t seed) {
  for (int i = 0; i < N_OPS; ++i) {
    std::mt19937_64 rng(seed + 0x9e3779b97f4a7c15ull * static_cast<uint64_t>(i));
    for (uint64_t k = 0; k < per_op; ++k)
      check_one(OPS[i].op, OPS[i].op2, biased(rng), biased(rng), biased_ac(rng),
                "random", OPS[i].name);
  }
  std::printf("  pass 3 per-op     : %d ops x %llu vectors (seed %llu)\n",
              N_OPS, static_cast<unsigned long long>(per_op),
              static_cast<unsigned long long>(seed));
}

} // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  uint64_t per_op = 1000000;
  uint64_t seed   = 1;
  for (int i = 1; i < argc; ++i) {
    if (!std::strncmp(argv[i], "+random=", 8)) per_op = std::strtoull(argv[i] + 8, nullptr, 10);
    if (!std::strncmp(argv[i], "+seed=",   6)) seed   = std::strtoull(argv[i] + 6, nullptr, 10);
    if (!std::strcmp (argv[i], "+mame_carry_bug"))    carry_bug_mode = true;
  }

  dut = new Vi960_alu;

  std::printf("i960_alu vs reference%s\n",
              carry_bug_mode ? "  [modelling MAME's carry defect]" : "");
  pass_exhaustive_opspace();
  pass_directed();
  pass_per_op(per_op, seed);

  dut->final();
  delete dut;

  std::printf("  %llu field checks, %llu mismatches\n",
              static_cast<unsigned long long>(checks),
              static_cast<unsigned long long>(fails));

  if (carry_bug_mode) {
    // Expected to fail: the RTL implements hardware carry and this mode models
    // MAME's. A PASS here would mean the RTL had the defect too.
    if (fails) { std::printf("EXPECTED DIVERGENCE (%llu) — RTL implements hardware carry\n",
                             static_cast<unsigned long long>(fails)); return 0; }
    std::printf("FAIL: no divergence, so the RTL reproduces MAME's carry defect\n");
    return 1;
  }

  if (fails) { std::printf("FAIL\n"); return 1; }
  std::printf("PASS\n");
  return 0;
}
