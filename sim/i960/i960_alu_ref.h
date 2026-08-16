// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// Reference for i960_alu, transcribed from MAME's i960 device, execute_op
// cases 0x58-0x5b. BSD-3-Clause, copyright Farfetch'd and R. Belmont.
//
// Written from the reference rather than from the RTL. If it were derived from
// i960_alu.sv it would agree by construction and prove nothing.
//
// ---------------------------------------------------------------------------
// MAME_CARRY_BUG selects which behaviour this models for addc and subc.
//
//   false (default) — hardware: carry computed at 33 bits and propagates.
//   true            — MAME: carry is always zero, because its expression is
//                     evaluated entirely in uint32_t and wraps before being
//                     widened to uint64_t.
//
// The switch exists so the divergence stays measurable rather than becoming an
// unexamined choice. Run the suite both ways: with the flag set, the RTL should
// differ from this model on exactly addc and subc carry and nothing else. If it
// differs anywhere else, that is a real bug wearing this one's clothes.
// See i960_alu.sv's header and design study R7.
// ---------------------------------------------------------------------------

#pragma once
#include <cstdint>

namespace i960ref {

struct AluOut {
  uint32_t result;
  bool     result_we;
  uint32_t ac;
  bool     valid;
};

inline void cmp_u(uint32_t &ac, uint32_t v1, uint32_t v2) {
  ac &= ~7u;
  if      (v1 <  v2) ac |= 4;
  else if (v1 == v2) ac |= 2;
  else               ac |= 1;
}

inline void cmp_s(uint32_t &ac, int32_t v1, int32_t v2) {
  ac &= ~7u;
  if      (v1 <  v2) ac |= 4;
  else if (v1 == v2) ac |= 2;
  else               ac |= 1;
}

inline void concmp_u(uint32_t &ac, uint32_t v1, uint32_t v2) {
  ac &= ~7u;
  ac |= (v1 <= v2) ? 2 : 1;
}

inline void concmp_s(uint32_t &ac, int32_t v1, int32_t v2) {
  ac &= ~7u;
  ac |= (v1 <= v2) ? 2 : 1;
}

inline uint32_t rotl32(uint32_t v, uint32_t n) {
  n &= 31u;
  return n ? ((v << n) | (v >> (32 - n))) : v;
}

inline AluOut alu(uint8_t op, uint8_t op2, uint32_t t1, uint32_t t2,
                  uint32_t ac_in, bool mame_carry_bug = false) {
  AluOut o{};
  o.result    = 0;
  o.result_we = false;
  o.ac        = ac_in;
  o.valid     = true;

  const int32_t t2s = static_cast<int32_t>(t2);

  auto wr = [&](uint32_t v) { o.result = v; o.result_we = true; };

  switch (op) {
    case 0x58:
      switch (op2) {
        case 0x0: wr(t2 ^  (1u << (t1 & 31))); break;   // notbit
        case 0x1: wr(t2 &  t1);                break;   // and
        case 0x2: wr(t2 & ~t1);                break;   // andnot
        case 0x3: wr(t2 |  (1u << (t1 & 31))); break;   // setbit
        case 0x4: wr(~t2 & t1);                break;   // notand
        case 0x6: wr(t2 ^  t1);                break;   // xor
        case 0x7: wr(t2 |  t1);                break;   // or
        case 0x8: wr(~t2 & ~t1);               break;   // nor
        case 0x9: wr(~(t2 ^ t1));              break;   // xnor
        case 0xa: wr(~t1);                     break;   // not
        case 0xb: wr(t2 | ~t1);                break;   // ornot
        case 0xc: wr(t2 & ~(1u << (t1 & 31))); break;   // clrbit
        case 0xd: wr(~t2 | t1);                break;   // notor
        case 0xe: wr(~t2 | ~t1);               break;   // nand
        case 0xf:                                        // alterbit
          wr((ac_in & 2) ? (t2 |  (1u << (t1 & 31)))
                         : (t2 & ~(1u << (t1 & 31))));
          break;
        default: o.valid = false; break;
      }
      break;

    case 0x59:
      switch (op2) {
        // addi/subi are marked "#### overflow" in the reference and do not
        // detect it, making them identical to addo/subo.
        case 0x0: case 0x1: wr(t2 + t1); break;         // addo, addi
        case 0x2: case 0x3: wr(t2 - t1); break;         // subo, subi
        case 0x8: wr(t1 >= 32 ? 0u : (t2 >> t1)); break; // shro
        case 0xa:                                        // shrdi
          if (t1 >= 32) wr(0u);
          else if (t2s < 0) {
            if (t2 & ((1u << t1) - 1)) wr(static_cast<uint32_t>((t2s >> t1) + 1));
            else                       wr(static_cast<uint32_t>(t2s >> t1));
          } else wr(t2 >> t1);
          break;
        case 0xb:                                        // shri
          if (t1 >= 32) wr(t2s < 0 ? 0xffffffffu : 0u);
          else          wr(static_cast<uint32_t>(t2s >> t1));
          break;
        case 0xc: case 0xe: wr(t1 >= 32 ? 0u : (t2 << t1)); break; // shlo, shli
        case 0xd: wr(rotl32(t2, t1 & 0x1f)); break;      // rotate
        default: o.valid = false; break;
      }
      break;

    case 0x5a:
      switch (op2) {
        case 0x0: cmp_u(o.ac, t1, t2); break;            // cmpo
        case 0x1: cmp_s(o.ac, static_cast<int32_t>(t1), t2s); break; // cmpi
        case 0x2: if (!(ac_in & 0x4)) concmp_u(o.ac, t1, t2); break; // concmpo
        case 0x3: if (!(ac_in & 0x4)) concmp_s(o.ac, static_cast<int32_t>(t1), t2s); break; // concmpi
        case 0x4: cmp_u(o.ac, t1, t2); wr(t2 + 1); break;            // cmpinco
        case 0x5: cmp_s(o.ac, static_cast<int32_t>(t1), t2s); wr(t2 + 1); break; // cmpinci
        case 0x6: cmp_u(o.ac, t1, t2); wr(t2 - 1); break;            // cmpdeco
        case 0x7: cmp_s(o.ac, static_cast<int32_t>(t1), t2s); wr(t2 - 1); break; // cmpdeci
        case 0xc:                                                     // scanbyte
          o.ac &= ~7u;
          if ((t1 & 0xff000000u) == (t2 & 0xff000000u) ||
              (t1 & 0x00ff0000u) == (t2 & 0x00ff0000u) ||
              (t1 & 0x0000ff00u) == (t2 & 0x0000ff00u) ||
              (t1 & 0x000000ffu) == (t2 & 0x000000ffu))
            o.ac |= 2;
          break;
        case 0xe: {                                                   // chkbit
          const uint32_t b = t1 & 0x1f;
          if (t2 & (1u << b)) o.ac = (o.ac & ~7u) | 2;
          else                o.ac &= ~7u;
          break;
        }
        default: o.valid = false; break;
      }
      break;

    case 0x5b:
      switch (op2) {
        case 0x0: {                                                   // addc
          const uint64_t res = static_cast<uint64_t>(t2) +
                               static_cast<uint64_t>(t1) +
                               ((ac_in >> 1) & 1u);
          const uint32_t r32 = static_cast<uint32_t>(res);
          wr(r32);
          o.ac &= ~0x3u;
          const bool carry = mame_carry_bug ? false : ((res >> 32) & 1u) != 0;
          const bool ovf   = ((r32 ^ t1) & (r32 ^ t2) & 0x80000000u) != 0;
          o.ac |= carry ? 0x2u : 0u;
          o.ac |= ovf   ? 0x1u : 0u;
          break;
        }
        case 0x2: {                                                   // subc
          const uint64_t sub = static_cast<uint64_t>(t1) + ((ac_in >> 1) & 1u);
          const uint64_t res = static_cast<uint64_t>(t2) - sub;
          const uint32_t r32 = static_cast<uint32_t>(res);
          wr(r32);
          o.ac &= ~0x3u;
          const bool carry = mame_carry_bug ? false : ((res >> 32) & 1u) != 0;
          const bool ovf   = ((t2 ^ t1) & (t2 ^ r32) & 0x80000000u) != 0;
          o.ac |= carry ? 0x2u : 0u;
          o.ac |= ovf   ? 0x1u : 0u;
          break;
        }
        default: o.valid = false; break;
      }
      break;

    case 0x5c:
      if (op2 == 0xc) wr(t1);                                       // mov
      else o.valid = false;
      break;

    case 0x64:
      switch (op2) {
        case 0x0: {                                                 // spanbit
          uint32_t res = 0xffffffffu; bool hit = false;
          for (int i = 31; i >= 0; i--) if (!(t1 & (1u << i))) { res = uint32_t(i); hit = true; break; }
          o.ac = (o.ac & ~7u) | (hit ? 2u : 0u); wr(res); break;
        }
        case 0x1: {                                                 // scanbit
          uint32_t res = 0xffffffffu; bool hit = false;
          for (int i = 31; i >= 0; i--) if (t1 & (1u << i)) { res = uint32_t(i); hit = true; break; }
          o.ac = (o.ac & ~7u) | (hit ? 2u : 0u); wr(res); break;
        }
        case 0x4:                                                   // dmovt
          wr(t1);
          // 0xfff8, not ~7 — see the RTL header. Reproduced, not corrected.
          o.ac = (ac_in & 0xfff8u) | (((t1 & 0xff) < 0x30 || (t1 & 0xff) > 0x39) ? 2u : 0u);
          break;
        case 0x5:                                                   // modac
          wr(ac_in);
          o.ac = (ac_in & ~t1) | (t2 & t1);
          break;
        default: o.valid = false; break;
      }
      break;

    default: o.valid = false; break;
  }

  if (!o.valid) { o.result = 0; o.result_we = false; o.ac = ac_in; }
  return o;
}

} // namespace i960ref
