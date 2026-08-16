// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Reference for i960_lsu, transcribed from MAME's MEM opcodes and the
// i960_read/write_{word,dword}_unaligned helpers. BSD-3-Clause, Farfetch'd and
// R. Belmont.
//
// Emits the ordered list of bus transactions a request produces, plus the
// loaded words. The ORDER is the product: it is what lockstep compares, and it
// is what the burst rule and the unaligned split both change.
#pragma once
#include <cstdint>
#include <map>
#include <vector>

namespace i960ref {

struct BusOp { uint32_t addr; uint8_t be; bool is_write; uint32_t data; };

struct LsuResult {
  std::vector<BusOp>    ops;
  std::vector<uint32_t> loaded;
};

// Unwritten memory reads 0xFFFFFFFF, never zero.
inline uint32_t peek(const std::map<uint32_t,uint32_t> &m, uint32_t a) {
  auto it = m.find(a & ~3u);
  return (it == m.end()) ? 0xffffffffu : it->second;
}

inline LsuResult lsu(uint32_t addr, uint8_t size, uint8_t n_words,
                     bool is_store, bool sign_ext, bool is_burst,
                     const uint32_t *st_words,
                     std::map<uint32_t,uint32_t> &mem) {
  LsuResult r;
  uint32_t t1 = addr;

  for (uint8_t w = 0; w < n_words; ++w) {
    const uint32_t sv = is_store ? st_words[w] : 0;

    const bool split = (size == 0) ? false
                     : (size == 1) ? ((t1 & 1) != 0)
                                   : ((t1 & 3) != 0);
    const uint8_t nbytes = (size == 1) ? 2 : 4;

    if (split) {
      // Byte at a time, little-endian, exactly as the reference assembles it.
      uint32_t acc = 0;
      for (uint8_t b = 0; b < nbytes; ++b) {
        const uint32_t ba = t1 + b;
        const uint8_t  be = static_cast<uint8_t>(1u << (ba & 3));
        if (is_store) {
          const uint8_t byte = static_cast<uint8_t>(sv >> (b * 8));
          uint32_t d = peek(mem, ba);
          d = (d & ~(0xffu << ((ba & 3) * 8))) | (static_cast<uint32_t>(byte) << ((ba & 3) * 8));
          mem[ba & ~3u] = d;
          r.ops.push_back({ba, be, true, static_cast<uint32_t>(byte) * 0x01010101u});
        } else {
          const uint32_t d = peek(mem, ba);
          acc |= static_cast<uint32_t>((d >> ((ba & 3) * 8)) & 0xffu) << (b * 8);
          r.ops.push_back({ba, be, false, d});
        }
      }
      if (!is_store) {
        uint32_t v = acc;
        if (size == 1) v = sign_ext ? static_cast<uint32_t>(static_cast<int16_t>(acc))
                                    : (acc & 0xffffu);
        r.loaded.push_back(v);
      }
    } else {
      const uint8_t be = (size == 0) ? static_cast<uint8_t>(1u << (t1 & 3))
                       : (size == 1) ? ((t1 & 2) ? 0xc : 0x3)
                                     : 0xf;
      if (is_store) {
        uint32_t d = peek(mem, t1);
        for (int lane = 0; lane < 4; ++lane)
          if (be & (1 << lane)) {
            const uint32_t src = (size == 0) ? (sv & 0xffu)
                               : (size == 1) ? ((sv >> ((lane & 2) ? 16 : 0)) & 0xffu)
                                             : ((sv >> (lane * 8)) & 0xffu);
            const uint32_t byte = (size == 0) ? src
                                : (size == 1) ? ((sv >> (((lane & 1) ? 8 : 0))) & 0xffu)
                                              : ((sv >> (lane * 8)) & 0xffu);
            d = (d & ~(0xffu << (lane * 8))) | (byte << (lane * 8));
          }
        mem[t1 & ~3u] = d;
        const uint32_t wd = (size == 0) ? (sv & 0xffu) * 0x01010101u
                          : (size == 1) ? ((sv & 0xffffu) | ((sv & 0xffffu) << 16))
                                        : sv;
        r.ops.push_back({t1, be, true, wd});
      } else {
        const uint32_t d = peek(mem, t1);
        r.ops.push_back({t1, be, false, d});
        uint32_t v;
        if (size == 0) {
          const uint8_t b = static_cast<uint8_t>(d >> ((t1 & 3) * 8));
          v = sign_ext ? static_cast<uint32_t>(static_cast<int8_t>(b)) : b;
        } else if (size == 1) {
          const uint16_t h = static_cast<uint16_t>((t1 & 2) ? (d >> 16) : d);
          v = sign_ext ? static_cast<uint32_t>(static_cast<int16_t>(h)) : h;
        } else v = d;
        r.loaded.push_back(v);
      }
    }

    // The whole point: the address advances only in a burst region.
    if (is_burst) t1 += 4;
  }
  return r;
}

} // namespace i960ref
