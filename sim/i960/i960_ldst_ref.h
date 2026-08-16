// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Reference for i960_ldst, transcribed from MAME's i960 MEM opcodes and the
// unaligned helpers. BSD-3-Clause, Farfetch'd and R. Belmont.
#pragma once
#include <cstdint>
namespace i960ref {

struct LdSt {
  bool is_load, is_store, no_mem, sign_ext, valid, unaligned;
  uint8_t size, n_words, reg_mask;
  uint32_t ld_result, st_data;
  uint8_t st_be;
};

inline LdSt ldst(uint8_t op, uint8_t addr_lo, uint32_t rd, uint32_t sv) {
  LdSt o{}; o.valid = true; o.size = 2; o.n_words = 1; o.reg_mask = 0x1f;
  switch (op) {
    case 0x80: o.is_load = true;  o.size = 0; break;                 // ldob u8
    case 0x82: o.is_store = true; o.size = 0; break;                 // stob
    case 0x88: o.is_load = true;  o.size = 1; break;                 // ldos u16
    case 0x8a: o.is_store = true; o.size = 1; break;                 // stos
    case 0x8c: o.no_mem = true; break;                               // lda
    case 0x90: o.is_load = true;  break;                             // ld
    case 0x92: o.is_store = true; break;                             // st
    case 0x98: o.is_load = true;  o.n_words = 2; o.reg_mask = 0x1e; break;              // ldl
    case 0x9a: o.is_store = true; o.n_words = 2; o.reg_mask = 0x1e; break;              // stl
    case 0xa0: o.is_load = true;  o.n_words = 3; o.reg_mask = 0x1c; break;              // ldt
    case 0xa2: o.is_store = true; o.n_words = 3; o.reg_mask = 0x1c; break;              // stt
    case 0xb0: o.is_load = true;  o.n_words = 4; o.reg_mask = 0x1c; break;              // ldq
    case 0xb2: o.is_store = true; o.n_words = 4; o.reg_mask = 0x1c; break;              // stq
    case 0xc0: o.is_load = true;  o.size = 0; o.sign_ext = true; break; // ldib s8
    case 0xc2: o.is_store = true; o.size = 0; break;                 // stib
    case 0xc8: o.is_load = true;  o.size = 1; o.sign_ext = true; break; // ldis s16
    case 0xca: o.is_store = true; o.size = 1; break;                 // stis
    default: o.valid = false; break;
  }

  o.unaligned = (o.size == 0) ? false
              : (o.size == 1) ? ((addr_lo & 1) != 0)
                              : (addr_lo != 0);

  const uint8_t  b = static_cast<uint8_t>(rd >> (addr_lo * 8));
  const uint16_t h = static_cast<uint16_t>((addr_lo & 2) ? (rd >> 16) : rd);

  if (o.size == 0)
    o.ld_result = o.sign_ext ? static_cast<uint32_t>(static_cast<int8_t>(b)) : b;
  else if (o.size == 1)
    o.ld_result = o.sign_ext ? static_cast<uint32_t>(static_cast<int16_t>(h)) : h;
  else
    o.ld_result = rd;

  if (o.size == 0) {
    const uint32_t v = sv & 0xffu;
    o.st_data = v | (v << 8) | (v << 16) | (v << 24);
    o.st_be   = static_cast<uint8_t>(1u << addr_lo);
  } else if (o.size == 1) {
    const uint32_t v = sv & 0xffffu;
    o.st_data = v | (v << 16);
    o.st_be   = (addr_lo & 2) ? 0xc : 0x3;
  } else {
    o.st_data = sv;
    o.st_be   = 0xf;
  }
  return o;
}
} // namespace i960ref
