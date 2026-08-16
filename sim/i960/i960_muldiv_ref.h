// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Reference for i960_muldiv, transcribed from MAME's REG blocks 0x67/0x70/0x74.
// BSD-3-Clause, Farfetch'd and R. Belmont.
//
// A zero divisor is UNDEFINED in the reference for every opcode except divo,
// which carries an explicit guard the author labelled HACK. This model returns
// the defined answer the RTL implements; the harness never generates a zero
// divisor, so the two are never compared on ground the reference does not
// define. Same resolution Model 1 used for shift counts above 31.
#pragma once
#include <cstdint>
namespace i960ref {

struct MdOut { uint32_t lo, hi; bool pair, valid; };

inline MdOut muldiv(uint8_t op, uint8_t op2, uint32_t t1, uint32_t t2, uint32_t t2hi) {
  MdOut o{0,0,false,true};
  const int32_t s1 = int32_t(t1), s2 = int32_t(t2);
  switch ((uint32_t(op) << 8) | op2) {
    case 0x7001: o.lo = uint32_t(t2 * t1); break;                       // mulo
    case 0x7401: o.lo = uint32_t(int32_t(s2 * s1)); break;              // muli
    case 0x7008: o.lo = t1 ? (t2 % t1) : t2; break;                     // remo
    case 0x700b: o.lo = t1 ? (t2 / t1) : 0u; break;                     // divo (guarded)
    case 0x7408: o.lo = t1 ? uint32_t(s2 % s1) : t2; break;             // remi
    case 0x740b: o.lo = t1 ? uint32_t(s2 / s1) : 0u; break;             // divi
    case 0x7409: {                                                      // modi
      if (!t1) { o.lo = t2; break; }
      int32_t d = s2 - (s2 / s1) * s1;
      // The reference tests `(src2*src1) < 0` on int32_t, so the condition is
      // bit 31 of the TRUNCATED 32-bit product — not the true sign of the
      // mathematical product. They differ whenever the multiply overflows, e.g.
      // 0x7fffffff * 3 is positive in 64 bits and negative in 32. Computing
      // this in int64_t looks tidier and is wrong.
      const uint32_t p32 = uint32_t(t2) * uint32_t(t1);
      if ((p32 & 0x80000000u) && d != 0) d += s1;
      o.lo = uint32_t(d);
      break;
    }
    case 0x6700: {                                                      // emul
      const uint64_t p = uint64_t(t1) * uint64_t(t2);
      o.lo = uint32_t(p); o.hi = uint32_t(p >> 32); o.pair = true; break;
    }
    case 0x6701: {                                                      // ediv
      const uint64_t d = (uint64_t(t2hi) << 32) | t2;
      if (!t1) { o.lo = uint32_t(d); o.hi = 0; }
      else     { o.lo = uint32_t(d % t1); o.hi = uint32_t(d / t1); }
      o.pair = true; break;
    }
    default: o.valid = false; break;
  }
  return o;
}
} // namespace i960ref
