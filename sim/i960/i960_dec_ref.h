// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// Reference decoder for i960_dec, transcribed from MAME's i960 device:
//   src/devices/cpu/i960/i960.cpp    execute_op dispatch, get_ea, get_*_ri/ci,
//                                    get_disp, get_disp_s
//   src/devices/cpu/i960/i960dis.cpp mnemonic table format column
// BSD-3-Clause, copyright Farfetch'd and R. Belmont. That licence permits this
// transcription; the attribution is the obligation and this discharges it.
//
// This is a SECOND EXPRESSION of the same encoding, written from the reference
// rather than from the RTL. If it were derived from i960_dec.sv it would agree
// with it by construction and prove nothing.

#pragma once
#include <cstdint>

namespace i960ref {

enum Fmt { FMT_CTRL = 0, FMT_COBR = 1, FMT_REG = 2, FMT_MEM = 3 };

struct Decoded {
  uint8_t  fmt;
  uint8_t  op;
  uint8_t  op2;
  bool     valid;
  bool     insn_len2;

  uint8_t  src1, src2, srcdst;
  bool     src1_lit, src2_lit, dst_lit;

  bool     memb;
  uint8_t  memb_mode;
  uint8_t  abase, index, scale;
  bool     mema_rel;
  uint16_t mema_offset;
  bool     memb_bad;

  uint32_t disp;
};

// The opcodes execute_op actually dispatches to. Deliberately not a range
// test: the COBR block is missing 0x38 and 0x3f, and the REG and MEM blocks
// are sparse. Enumerated so a divergence from the reference is a table edit
// with a reason, not a boundary that quietly moved.
inline bool op_implemented(uint8_t op) {
  switch (op) {
    // CTRL
    case 0x08: case 0x09: case 0x0a: case 0x0b:
    case 0x10: case 0x11: case 0x12: case 0x13:
    case 0x14: case 0x15: case 0x16: case 0x17:
    case 0x18: case 0x19: case 0x1a: case 0x1b:
    case 0x1c: case 0x1d: case 0x1e: case 0x1f:
    // COBR
    case 0x20: case 0x21: case 0x22: case 0x23:
    case 0x24: case 0x25: case 0x26: case 0x27:
    case 0x30: case 0x31: case 0x32: case 0x33:
    case 0x34: case 0x35: case 0x36: case 0x37:
    case 0x39: case 0x3a: case 0x3b: case 0x3c:
    case 0x3d: case 0x3e:
    // REG
    case 0x58: case 0x59: case 0x5a: case 0x5b:
    case 0x5c: case 0x5d: case 0x5e: case 0x5f:
    case 0x60: case 0x64: case 0x65: case 0x66:
    case 0x67: case 0x68: case 0x69: case 0x6c:
    case 0x6d: case 0x6e: case 0x70: case 0x74:
    case 0x78: case 0x79:
    // MEM
    case 0x80: case 0x82: case 0x84: case 0x85:
    case 0x86: case 0x88: case 0x8a: case 0x8c:
    case 0x90: case 0x92: case 0x98: case 0x9a:
    case 0xa0: case 0xa2: case 0xb0: case 0xb2:
    case 0xc0: case 0xc2: case 0xc8: case 0xca:
      return true;
    default:
      return false;
  }
}

// MEMB modes get_ea handles. Everything else is fatalerror there.
inline bool memb_mode_ok(uint8_t m) {
  return m == 0x4 || m == 0x5 || m == 0x7 ||
         m == 0xc || m == 0xd || m == 0xe || m == 0xf;
}

// Of those, the ones that read a displacement dword and advance IP by 4,
// making the instruction eight bytes.
inline bool memb_has_disp(uint8_t m) {
  return m == 0x5 || m == 0xc || m == 0xd || m == 0xe || m == 0xf;
}

inline Decoded decode(uint32_t insn) {
  Decoded d{};

  d.op  = static_cast<uint8_t>(insn >> 24);
  d.op2 = static_cast<uint8_t>((insn >> 7) & 0xf);

  if      (d.op < 0x20) d.fmt = FMT_CTRL;
  else if (d.op < 0x40) d.fmt = FMT_COBR;
  else if (d.op < 0x80) d.fmt = FMT_REG;
  else                  d.fmt = FMT_MEM;

  d.src1   = static_cast<uint8_t>(insn & 0x1f);
  d.src2   = static_cast<uint8_t>((insn >> 14) & 0x1f);
  d.srcdst = static_cast<uint8_t>((insn >> 19) & 0x1f);
  d.abase  = static_cast<uint8_t>((insn >> 14) & 0x1f);
  d.index  = static_cast<uint8_t>(insn & 0x1f);
  d.scale  = static_cast<uint8_t>((insn >> 7) & 0x7);

  // Three different bits for three operand positions. i960.cpp:
  //   get_1_ri 0x00000800, get_2_ri 0x00001000, set_ri 0x00002000
  d.src1_lit = (insn & 0x00000800) != 0;
  d.src2_lit = (insn & 0x00001000) != 0;
  d.dst_lit  = (insn & 0x00002000) != 0;

  d.memb        = (insn & 0x00001000) != 0;
  d.memb_mode   = static_cast<uint8_t>((insn >> 10) & 0xf);
  d.mema_rel    = (insn & 0x00002000) != 0;
  d.mema_offset = static_cast<uint16_t>(insn & 0x1fff);

  d.memb_bad  = (d.fmt == FMT_MEM) && d.memb && !memb_mode_ok(d.memb_mode);
  d.insn_len2 = (d.fmt == FMT_MEM) && d.memb && memb_has_disp(d.memb_mode);

  // get_disp   = sext(opcode, 24) - 4
  // get_disp_s = sext(opcode, 13) - 4
  // Sign-extends the whole low field, reserved low bits included.
  if (d.fmt == FMT_CTRL) {
    int32_t s = static_cast<int32_t>(insn << 8) >> 8;      // sext 24
    d.disp = static_cast<uint32_t>(s - 4);
  } else if (d.fmt == FMT_COBR) {
    int32_t s = static_cast<int32_t>(insn << 19) >> 19;    // sext 13
    d.disp = static_cast<uint32_t>(s - 4);
  } else {
    d.disp = 0;
  }

  d.valid = op_implemented(d.op) && !d.memb_bad;
  return d;
}

} // namespace i960ref
