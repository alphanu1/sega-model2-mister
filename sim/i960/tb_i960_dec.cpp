// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// Fuzz harness for i960_dec against the transcribed reference.
//
// Three passes, in increasing cost:
//
//   1. Exhaustive over the structural axes. Every opcode byte crossed with
//      every MEMB mode and both MEM sub-formats. These are the fields that
//      decide format, length and validity, and there are few enough of them
//      that "sampled" is no excuse.
//   2. Directed at the boundaries the encoding actually has — format edges at
//      0x20/0x40/0x80, the two COBR holes at 0x38 and 0x3f, sign bits of both
//      displacement widths, and the -4 borrow.
//   3. Random words, defaulting to 10^7.
//
// CLAUDE.md rule 8 says to sweep an order of magnitude past what you believe.
// Pass 1 is not a sweep, it is the whole space of the axes that matter; pass 3
// exists because the axes that matter are only the ones already thought of.

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>

#include "Vi960_dec.h"
#include "verilated.h"
#include "i960_dec_ref.h"

namespace {

Vi960_dec *dut = nullptr;
uint64_t   checks = 0;
uint64_t   fails  = 0;
const int  MAX_REPORT = 20;

// Field-by-field comparison. Every field every time: a decoder that gets the
// right answer for the field under test and corrupts another is still broken,
// and checking only the interesting field is how that survives to synthesis.
bool check_one(uint32_t insn, const char *why) {
  dut->insn = insn;
  dut->eval();

  const i960ref::Decoded r = i960ref::decode(insn);

  struct { const char *name; uint32_t got, want; } f[] = {
    { "fmt",         dut->fmt,         r.fmt         },
    { "op",          dut->op,          r.op          },
    { "op2",         dut->op2,         r.op2         },
    { "valid",       dut->valid,       r.valid       },
    { "insn_len2",   dut->insn_len2,   r.insn_len2   },
    { "src1",        dut->src1,        r.src1        },
    { "src2",        dut->src2,        r.src2        },
    { "srcdst",      dut->srcdst,      r.srcdst      },
    { "src1_lit",    dut->src1_lit,    r.src1_lit    },
    { "src2_lit",    dut->src2_lit,    r.src2_lit    },
    { "dst_lit",     dut->dst_lit,     r.dst_lit     },
    { "memb",        dut->memb,        r.memb        },
    { "memb_mode",   dut->memb_mode,   r.memb_mode   },
    { "abase",       dut->abase,       r.abase       },
    { "index",       dut->index,       r.index       },
    { "scale",       dut->scale,       r.scale       },
    { "mema_rel",    dut->mema_rel,    r.mema_rel    },
    { "mema_offset", dut->mema_offset, r.mema_offset },
    { "memb_bad",    dut->memb_bad,    r.memb_bad    },
    { "disp",        dut->disp,        r.disp        },
  };

  bool ok = true;
  for (const auto &x : f) {
    ++checks;
    if (x.got != x.want) {
      ok = false;
      if (fails < MAX_REPORT) {
        std::printf("  MISMATCH insn=%08x [%s] %-12s got=%08x want=%08x\n",
                    insn, why, x.name, x.got, x.want);
      }
      ++fails;
    }
  }
  return ok;
}

// Pass 1 — every opcode byte against every MEMB mode and both sub-formats.
// 256 * 16 * 2 * a few operand patterns. Exhaustive on the axes that decide
// format, length and validity.
void pass_structural() {
  const uint32_t operand_patterns[] = {
    0x00000000u, 0xffffffffu, 0x00155540u, 0x002aaa80u,
  };

  uint64_t n = 0;
  for (uint32_t opb = 0; opb < 256; ++opb) {
    for (uint32_t mode = 0; mode < 16; ++mode) {
      for (uint32_t memb = 0; memb < 2; ++memb) {
        for (uint32_t pat : operand_patterns) {
          // Low 24 bits from the pattern, then the mode and MEMB bits forced
          // over the top so every combination is reached regardless of pattern.
          uint32_t insn = (opb << 24) | (pat & 0x00ffffffu);
          insn = (insn & ~(0xfu << 10)) | (mode << 10);
          insn = (insn & ~(1u << 12))   | (memb << 12);
          check_one(insn, "structural");
          ++n;
        }
      }
    }
  }
  std::printf("  pass 1 structural : %llu vectors\n",
              static_cast<unsigned long long>(n));
}

// Pass 2 — the boundaries this encoding actually has.
void pass_directed() {
  std::vector<uint32_t> v;

  // Format edges, and one either side of each.
  for (uint32_t o : {0x07u, 0x08u, 0x1fu, 0x20u, 0x27u, 0x3fu,
                     0x40u, 0x57u, 0x58u, 0x7fu, 0x80u, 0xffu}) {
    v.push_back(o << 24);
    v.push_back((o << 24) | 0x00ffffffu);
  }

  // The two holes in the COBR block. 0x38 and 0x3f are absent from
  // execute_op while their neighbours are present, so a range test would
  // wrongly accept them and nothing else in the suite would notice.
  for (uint32_t o : {0x37u, 0x38u, 0x39u, 0x3eu, 0x3fu}) {
    v.push_back(o << 24);
  }

  // Displacement sign bits and the -4 borrow, both widths. CTRL sign is
  // bit 23, COBR sign is bit 12, and disp = sext - 4 borrows through zero.
  for (uint32_t base : {0x08u << 24, 0x20u << 24}) {
    for (uint32_t d : {0x000000u, 0x000001u, 0x000003u, 0x000004u, 0x000005u,
                       0x000fffu, 0x001000u, 0x001fffu,
                       0x7fffffu, 0x800000u, 0xffffffu}) {
      v.push_back(base | d);
    }
  }

  // Every MEMB mode on a real load, with and without the operand bits set.
  for (uint32_t mode = 0; mode < 16; ++mode) {
    v.push_back((0x90u << 24) | (1u << 12) | (mode << 10));
    v.push_back((0x90u << 24) | (1u << 12) | (mode << 10) | 0x000003ffu);
  }

  // Operand-mode bits in isolation, so a swapped pair cannot hide behind a
  // pattern that happens to set both.
  for (uint32_t b : {11u, 12u, 13u}) {
    v.push_back((0x59u << 24) | (1u << b));
  }

  for (uint32_t insn : v) check_one(insn, "directed");
  std::printf("  pass 2 directed   : %zu vectors\n", v.size());
}

void pass_random(uint64_t n, uint64_t seed) {
  std::mt19937_64 rng(seed);
  for (uint64_t i = 0; i < n; ++i) {
    check_one(static_cast<uint32_t>(rng()), "random");
  }
  std::printf("  pass 3 random     : %llu vectors (seed %llu)\n",
              static_cast<unsigned long long>(n),
              static_cast<unsigned long long>(seed));
}

} // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  uint64_t n_random = 10000000;
  uint64_t seed     = 1;
  for (int i = 1; i < argc; ++i) {
    if (!std::strncmp(argv[i], "+random=", 8)) n_random = std::strtoull(argv[i] + 8, nullptr, 10);
    if (!std::strncmp(argv[i], "+seed=",   6)) seed     = std::strtoull(argv[i] + 6, nullptr, 10);
  }

  dut = new Vi960_dec;

  std::printf("i960_dec vs reference\n");
  pass_structural();
  pass_directed();
  pass_random(n_random, seed);

  dut->final();
  delete dut;

  std::printf("  %llu field checks, %llu mismatches\n",
              static_cast<unsigned long long>(checks),
              static_cast<unsigned long long>(fails));

  if (fails) { std::printf("FAIL\n"); return 1; }
  std::printf("PASS\n");
  return 0;
}
