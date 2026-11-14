// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R1006: tgpx4_core's transfer decode (xdec) in C++, for the benches: which
// sources and destinations a 64-bit TGPx4 word moves, and their kinds.
#pragma once
#include <cstdint>

enum { K_NONE, K_REG, K_MEM, K_EXT, K_IMM };
struct Xd { int sk[2], dk[2]; int sc[2], dc[2]; bool sbus[2], dbus[2], smask[2], dmask[2]; };

static inline uint64_t B(uint64_t w, int hi, int lo) { return (w >> lo) & ((1ull << (hi - lo + 1)) - 1); }

// tgpx4_core's xdec, the transfer part
static inline Xd xdec(uint64_t w)
{
  Xd d{};
  int t = int(B(w, 63, 61)), c = int(B(w, 26, 22));
  uint32_t e2 = uint32_t(B(w, 15, 0));
  bool t1_ext = (t == 1) ? B(w, 26, 26) : B(w, 38, 38);
  bool t1_dir = (t == 1) ? B(w, 25, 25) : B(w, 37, 37);
  int t1_rr = int((t == 1) ? B(w, 18, 12) : B(w, 30, 24));
  int t1_sr7 = int((t == 1) ? B(w, 25, 19) : B(w, 37, 31));
  switch (t) {
  case 0:
    d.sc[0] = d.dc[0] = int(B(w, 24, 20)); d.sc[1] = d.dc[1] = 0x20 | int(B(w, 13, 10));
    d.sbus[1] = d.dbus[1] = true;
    switch (B(w, 26, 25)) {
    case 0: d.sk[0] = d.dk[0] = d.sk[1] = d.dk[1] = K_REG; break;
    case 1: d.sk[0] = K_REG; d.dk[0] = K_MEM; d.sk[1] = K_REG; d.dk[1] = K_MEM; break;
    case 2: d.sk[0] = K_MEM; d.dk[0] = K_REG; d.sk[1] = K_MEM; d.dk[1] = K_REG; break;
    }
    break;
  case 1: case 5:
    if (t1_ext) {
      if (t1_dir) { d.sk[0] = K_EXT; d.dk[0] = (t1_rr & 0x40) ? K_MEM : K_REG; d.dc[0] = t1_rr & 0x3f; d.dbus[0] = t1_rr & 0x20; d.dmask[0] = true; }
      else { d.sk[0] = (t1_rr & 0x40) ? K_MEM : K_REG; d.sc[0] = t1_rr & 0x3f; d.sbus[0] = t1_rr & 0x20; d.smask[0] = true; d.dk[0] = K_EXT; }
    } else {
      if (t1_sr7 == 0x58) d.sk[0] = K_IMM;
      else { d.sk[0] = (t1_sr7 & 0x40) ? K_MEM : K_REG; d.sc[0] = t1_sr7 & 0x3f; d.sbus[0] = t1_sr7 & 0x20; }
      d.dk[0] = (t1_rr & 0x40) ? K_MEM : K_REG; d.dc[0] = t1_rr & 0x3f; d.dbus[0] = t1_rr & 0x20;
    }
    break;
  case 4:
    d.sbus[1] = d.dbus[1] = true;
    d.sc[0] = int(B(w, 37, 33)); d.dc[0] = int(B(w, 32, 28)); d.sc[1] = 0x20 | int(B(w, 17, 13)); d.dc[1] = 0x20 | int(B(w, 12, 8));
    switch (B(w, 39, 38)) { case 0: d.sk[0] = d.dk[0] = K_REG; break; case 1: d.sk[0] = K_REG; d.dk[0] = K_MEM; break; case 2: d.sk[0] = K_MEM; d.dk[0] = K_REG; break; }
    switch (B(w, 19, 18)) { case 0: d.sk[1] = d.dk[1] = K_REG; break; case 1: d.sk[1] = K_REG; d.dk[1] = K_MEM; break; case 2: d.sk[1] = K_MEM; d.dk[1] = K_REG; break; }
    break;
  case 7:
    d.sk[0] = K_IMM; d.dk[0] = B(w, 25, 25) ? K_MEM : K_REG; d.dc[0] = int(B(w, 24, 19)); d.dbus[0] = B(w, 24, 24);
    break;
  case 2: case 6:
    if (c == 4) { d.sk[0] = K_REG; d.sc[0] = int((e2 >> 6) & 0x3f); }
    if (c == 5) { d.sk[0] = K_MEM; d.sbus[0] = true; d.dk[0] = K_REG; d.dc[0] = int((e2 >> 6) & 0x3f); }
    if (c == 0x10 || c == 0x11 || c == 0x12 || c == 0x18 || c == 0x19 || c == 0x1a) {
      switch (B(w, 15, 13)) {
      case 2: d.sk[0] = K_REG; d.sc[0] = (B(w, 11, 11) ? 0x28 : 0x08) | int(B(w, 8, 6)); break;
      case 3: d.sk[0] = K_REG; d.sc[0] = (B(w, 11, 11) ? 0x20 : 0x00) | int(B(w, 8, 6)); break;
      case 4: case 6: d.sk[0] = K_MEM; break;
      case 5: case 7: d.sk[0] = K_MEM; d.sbus[0] = true; break;
      }
    }
    break;
  }
  return d;
}
static inline bool is_rf(int c) { int h = c >> 3; return !(c & 0x10) && h != 2 && h != 6 && h != 7; }
static inline int rf_idx(int c) { return ((c >> 5) & 1) << 4 | ((c >> 3) & 1) << 3 | (c & 7); }

