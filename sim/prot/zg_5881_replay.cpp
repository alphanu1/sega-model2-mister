// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R862: ZERO GUNNER'S 315-5881 TRAFFIC, REPLAYED THROUGH sim/prot/m2_5881_ref.h.
// Reads a MAME 0.289 capture (zg_5881_cap.lua: the i960's writes to the RAM at
// 0x01d80000 -- "M" lines --, its writes and reads of the chip at 0x01d90000 --
// "W" / "R"), rebuilds the RAM, drives the reference with the same writes and
// compares every decrypt read (0x01d9000c, the upper half) with MAME's. It also
// prints each session's header (FLAG_COMPRESSED, lengths) and the table of
// (address, subkey) -> words the game asked for.
//
//   zg_5881_replay <capture.txt> [key=042c0d13]
//
// The capture is ROM-derived and stays outside the repository.

#include "m2_5881_ref.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <vector>

int main(int argc, char **argv) {
  if (argc < 2) { std::fprintf(stderr, "usage: %s <capture.txt> [key]\n", argv[0]); return 2; }
  FILE *f = std::fopen(argv[1], "r");
  if (!f) { std::perror(argv[1]); return 2; }
  uint32_t key = argc > 2 ? uint32_t(std::strtoul(argv[2], nullptr, 16)) : 0x042c0d13u;
  static uint8_t ram[0x10000];
  std::memset(ram, 0, sizeof ram);
  M2_5881Ref ref;
  ref.key = key;
  ref.reset();
  uint64_t reads = 0, bad = 0, sessions = 0;
  uint32_t cur_addr = 0;
  uint16_t cur_key = 0;
  std::vector<uint16_t> cur_words;
  std::map<std::pair<uint32_t, uint16_t>, std::vector<uint16_t>> table;
  // model2.cpp crypt_read_callback: read_word(0x1d80000 + 2*addr), bytes swapped
  ref.m_read = [&](uint32_t a) -> uint16_t {
    uint32_t o = (2 * a) & 0xffff;   // past 64 KB it would be the chip itself; Zero Gunner never goes there
    uint16_t le = uint16_t(ram[o] | (ram[o + 1] << 8));
    return uint16_t((le >> 8) | (le << 8));
  };
  auto flush = [&]() {
    if (!cur_words.empty()) table[{cur_addr, cur_key}] = cur_words;
    cur_words.clear();
  };
  char line[256];
  while (std::fgets(line, sizeof line, f)) {
    double t; char k; unsigned o, d, mk;
    if (std::sscanf(line, "%lf %c %x %x %x", &t, &k, &o, &d, &mk) != 5) continue;
    if (k == 'M') {
      for (int b = 0; b < 4; ++b)
        if ((mk >> (8 * b)) & 0xff) ram[(o + b) & 0xffff] = uint8_t(d >> (8 * b));
    } else if (k == 'W') {
      if (o == 0x08 && (mk & 0xffff)) { flush(); ref.addrlo_w(uint16_t(d)); cur_addr = d & 0xffff; ++sessions; }
      if (o == 0x08 && (mk >> 16))    ref.addrhi_w(uint16_t(d >> 16));
      if (o == 0x0c && (mk & 0xffff)) { ref.subkey_le_w(uint16_t(d)); cur_key = uint16_t(d); }
    } else if (k == 'R') {
      if (o == 0x0c && (mk >> 16)) {
        bool first = ref.first_read;
        uint16_t want = uint16_t(d >> 16);
        uint16_t got = ref.decrypt_le_r();
        if (first)
          std::printf("  %.6f session addr %04x subkey %04x: header %05x (%s, %d x %d)\n", t, cur_addr, cur_key,
                      0u, "read at the first word", 0, 0);
        else cur_words.push_back(got);
        ++reads;
        if (got != want) { if (bad++ < 20) std::printf("  MISMATCH %.6f: ref %04x MAME %04x\n", t, got, want); }
        if (!first && cur_words.size() == 1)
          std::printf("            header %05x (%s, block %d x %d)\n", ref.dec_header,
                      (ref.dec_header & M2_5881Ref::FLAG_COMPRESSED) ? "COMPRESSED" : "plain",
                      int(((ref.dec_header >> 8) & 0x1ff) + 1), int((ref.dec_header & 0xff) + 1));
      }
    }
  }
  flush();
  std::printf("  the game's checks (address, subkey -> words):\n");
  for (auto &e : table) {
    std::printf("    %04x %04x ->", e.first.first, e.first.second);
    for (uint16_t w : e.second) std::printf(" %04x", w);
    std::printf("\n");
  }
  std::printf("  %llu sessions, %llu decrypt reads, %llu differ from MAME\n%s\n",
              (unsigned long long)sessions, (unsigned long long)reads, (unsigned long long)bad, bad ? "FAIL" : "PASS");
  return bad ? 1 : 0;
}
