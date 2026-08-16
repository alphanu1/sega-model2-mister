// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// Reference for i960_agu, transcribed from MAME's i960 device get_ea.
// BSD-3-Clause, copyright Farfetch'd and R. Belmont.
//
// Structured as the reference is, including the post-increment IP in mode 5,
// so the ordering can be audited line by line against the original.

#pragma once
#include <cstdint>

namespace i960ref {

struct AguOut { uint32_t ea; bool needs_disp; bool valid; };

inline AguOut agu(uint32_t insn, uint32_t abase, uint32_t index,
                  uint32_t disp, uint32_t ip_after_disp) {
  AguOut o{0, false, true};

  if (!(insn & 0x00001000u)) {                 // MEMA
    const uint32_t offset = insn & 0x1fffu;    // zero-extended, not signed
    o.ea = (insn & 0x2000u) ? (abase + offset) : offset;
    return o;
  }

  const uint32_t scale = (insn >> 7) & 7u;
  const uint32_t mode  = (insn >> 10) & 0xfu;
  const uint32_t si    = index << scale;

  switch (mode) {
    case 0x4: o.ea = abase; break;
    case 0x5: o.ea = disp + ip_after_disp; o.needs_disp = true; break;
    case 0x7: o.ea = abase + si; break;
    case 0xc: o.ea = disp;                 o.needs_disp = true; break;
    case 0xd: o.ea = disp + abase;         o.needs_disp = true; break;
    case 0xe: o.ea = disp + si;            o.needs_disp = true; break;
    case 0xf: o.ea = disp + abase + si;    o.needs_disp = true; break;
    default:  o.ea = 0; o.valid = false; break;
  }
  return o;
}

} // namespace i960ref
