// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// Reference for i960_regs, transcribed from MAME's i960 device: do_call,
// do_ret_0 and flushreg. BSD-3-Clause, copyright Farfetch'd and R. Belmont.
//
// Models the register file, the four-frame cache AND the external memory write
// stream, because the last of those is the part a register-only comparison
// cannot see. Cache depth is architecturally invisible but memory-visible: a
// spilled frame writes to memory, so getting the depth or the spill condition
// wrong is silent in the registers and obvious here.

#pragma once
#include <cstdint>
#include <map>
#include <vector>

namespace i960ref {

struct MemOp {
  uint32_t addr;
  uint32_t data;
  bool     is_write;
  bool operator==(const MemOp &o) const {
    return addr == o.addr && data == o.data && is_write == o.is_write;
  }
};

struct Regs {
  static constexpr int RCACHE_SIZE = 4;
  static constexpr int PFP = 0, SP = 1, RIP = 2, FP = 31;   // FP is g15 = index 31

  uint32_t r[32]{};
  uint32_t rcache[RCACHE_SIZE][16]{};
  uint32_t rcache_frame_addr[RCACHE_SIZE]{};
  int32_t  rcache_pos = 0;

  std::map<uint32_t, uint32_t> mem;
  std::vector<MemOp>           stream;   // ordered, writes and reads

  // Unwritten memory reads 0xFFFFFFFF, never zero. docs/mister-integration.md:
  // zero is a legal instruction, a legal tile number and a black palette entry,
  // so a core let loose on zeroed memory looks far healthier than it is.
  uint32_t read(uint32_t a) {
    auto it = mem.find(a);
    const uint32_t v = (it == mem.end()) ? 0xffffffffu : it->second;
    stream.push_back({a, v, false});
    return v;
  }
  void write(uint32_t a, uint32_t v) {
    mem[a] = v;
    stream.push_back({a, v, true});
  }

  void do_call(uint32_t adr, int type, uint32_t stack) {
    r[RIP] = adr;   // caller supplies the return address in `adr` slot below

    (void)adr;
  }

  // Split exactly as MAME has it so the ordering is auditable line by line.
  void call(uint32_t ret_ip, uint32_t target, int type, uint32_t stack) {
    r[RIP] = ret_ip;

    if (rcache_pos >= RCACHE_SIZE) {
      const uint32_t f = r[FP] & ~0x3fu;
      for (int i = 0; i < 16; i++) write(f + i * 4, r[i]);
    } else {
      for (int i = 0; i < 16; i++) rcache[rcache_pos][i] = r[i];
      rcache_frame_addr[rcache_pos] = r[FP] & ~0x3fu;
    }
    rcache_pos++;

    // The locals are NOT cleared: the callee inherits the caller's values.
    r[PFP] = (r[FP] & ~7u) | static_cast<uint32_t>(type);
    if (type == 7) r[SP] = stack;
    r[FP] = (r[SP] + 63) & ~63u;
    r[SP] = r[FP] + 64;
    (void)target;
  }

  // do_ret. MAME dispatches on PFP[2:0] and this reference did not, which is why
  // lockstep could not see it: the module ignored the type field too, so the two
  // agreed while both were wrong. Study R14.
  //
  //   type 0  ordinary return
  //   type 7  interrupt return: PC and AC come back from the frame BEFORE the
  //           registers are reloaded, because do_ret_0 overwrites FP
  //   1-6     MAME calls fatalerror; we trap, which is the same discipline
  //
  // ret_type is set by the caller from PFP[2:0]; ret_pc/ret_ac carry the restored
  // values out for the sequencer to apply.
  uint32_t ret_pc = 0, ret_ac = 0;
  bool     ret_bad = false;

  uint32_t ret_typed(uint32_t &pc_out, uint32_t &ac_out) {
    const uint32_t type = r[PFP] & 7;
    ret_bad = false;
    if (type == 7) {
      // Read BEFORE do_ret_0: it reloads the register file and moves FP.
      pc_out = read(r[FP] - 16);
      ac_out = read(r[FP] - 12);
    } else if (type != 0 && type != 7) {
      ret_bad = true;
      return r[RIP];
    }
    return ret();
  }

  // do_ret_0. Returns the IP to take.
  uint32_t ret() {
    r[FP] = r[PFP] & ~0x3fu;
    rcache_pos--;

    if (rcache_pos >= RCACHE_SIZE || rcache_pos < 0) {
      for (int i = 0; i < 16; i++) r[i] = read(r[FP] + 4 * i);
      if (rcache_pos < 0) rcache_pos = 0;
    } else {
      for (int i = 0; i < 16; i++) r[i] = rcache[rcache_pos][i];
    }
    return r[RIP];
  }

  void flushreg() {
    if (rcache_pos > RCACHE_SIZE) rcache_pos = RCACHE_SIZE;
    for (int32_t t = 0; t < rcache_pos; t++)
      for (int i = 0; i < 16; i++)
        write(rcache_frame_addr[t] + i * 4, rcache[t][i]);
    rcache_pos = 0;
  }
};

} // namespace i960ref
