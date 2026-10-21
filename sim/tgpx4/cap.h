// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R924: a TGPx4 capture from MAME (sim/tgpx4/mame_mb86235_cap.patch, R924_CAP),
// loaded for the replay benches. events.bin: 9-byte records <u8 type, u32 a,
// u32 b> in emulation order (the types are in the patch's header comment);
// cdata.bin the copro_data region; trace.bin <u16 pc, u32 state hash> per
// completed word. All ROM-derived: never in the repository.
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <zlib.h>

struct CapEv { uint8_t t; uint32_t a, b; };

struct Capture {
  std::vector<CapEv> ev;
  std::vector<uint32_t> cdata;
  std::vector<uint16_t> tr_pc;
  std::vector<uint32_t> tr_h;
  uint64_t prog[4096] = {};
  size_t boot_ev = 0;          // index of the 'B' event
  unsigned upload = 0;

  static bool rd_all(const std::string &p, std::vector<uint8_t> &out) {
    gzFile g = gzopen((p + ".gz").c_str(), "rb");
    if (!g) g = gzopen(p.c_str(), "rb");
    if (!g) return false;
    uint8_t buf[1 << 16]; int n;
    while ((n = gzread(g, buf, sizeof buf)) > 0) out.insert(out.end(), buf, buf + n);
    gzclose(g);
    return true;
  }
  bool load(const std::string &dir, size_t max_trace = SIZE_MAX) {
    std::vector<uint8_t> b;
    if (!rd_all(dir + "/events.bin", b)) { fprintf(stderr, "no events.bin in %s\n", dir.c_str()); return false; }
    ev.resize(b.size() / 9);
    for (size_t i = 0; i < ev.size(); i++) {
      ev[i].t = b[i * 9];
      memcpy(&ev[i].a, &b[i * 9 + 1], 4); memcpy(&ev[i].b, &b[i * 9 + 5], 4);
    }
    b.clear(); b.shrink_to_fit();
    if (!rd_all(dir + "/cdata.bin", b)) { fprintf(stderr, "no cdata.bin in %s\n", dir.c_str()); return false; }
    cdata.resize(b.size() / 4); memcpy(cdata.data(), b.data(), cdata.size() * 4);
    b.clear(); b.shrink_to_fit();
    if (rd_all(dir + "/trace.bin", b)) {
      size_t n = std::min(b.size() / 6, max_trace);
      tr_pc.resize(n); tr_h.resize(n);
      for (size_t i = 0; i < n; i++) { memcpy(&tr_pc[i], &b[i * 6], 2); memcpy(&tr_h[i], &b[i * 6 + 2], 4); }
    }
    // the program, as model2c_state::copro_fifo_w packs it: dword n is the
    // low half of word n/2 when even, the high half when odd
    for (size_t i = 0; i < ev.size(); i++) {
      if (ev[i].t == 'U') {
        unsigned n = ev[i].a;
        uint64_t &w = prog[(n / 2) & 0xfff];
        if (n & 1) w = (w & 0xffffffffull) | (uint64_t(ev[i].b) << 32);
        else       w = (w & 0xffffffff00000000ull) | ev[i].b;
        upload++;
      }
      if (ev[i].t == 'B') { boot_ev = i; break; }
    }
    return true;
  }
  uint32_t rom(uint32_t addr) const {   // external bus 0x800000-0x9fffff
    uint32_t i = (addr - 0x800000) & 0x1fffff;
    return i < cdata.size() ? cdata[i] : 0;
  }
};
