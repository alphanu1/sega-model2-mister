// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R924: THE TGPx4 REFERENCE MODEL -- MAME 0.289's own MB86235 interpreter.
//
// mb86235ops.cpp beside this file is MAME's src/devices/cpu/mb86235/
// mb86235ops.cpp at 0.289 (f34f0250), copied VERBATIM (BSD-3-Clause,
// copyright-holders Angelo Salese, ElSemi, Matthew Daniels; see
// THIRD_PARTY.md). This header stands in for MAME's mb86235.h: the same
// class name, the same internal state struct (field for field) and the same
// interpreter method declarations, with MAME's device machinery replaced by
// host callbacks -- the FIFOs, the external bus -- so that the opcode file
// compiles unchanged. execute_one() is MAME's execute_run() loop body
// (mb86235.cpp), one word.
#pragma once
#include "emu.h"
#include <functional>

class mb86235_device
{
public:
  // ---- the host's side
  struct fifo_t {
    mb86235_device *dev = nullptr;
    std::function<bool()> empty, full;
    std::function<uint32_t()> pop_fn;          // called only when not empty
    std::function<void(uint32_t)> push_fn;
    std::function<void()> clear_fn;
    // generic_fifo: pop() of an empty FIFO fires the stall callback and
    // returns T() -- the instruction completes with 0 and is replayed
    uint32_t pop() { if (empty()) { dev->stall(); return 0; } return pop_fn(); }
    void push(uint32_t v) { push_fn(v); }
    bool is_empty() { return empty(); }
    bool is_full() { return full(); }
    void clear() { if (clear_fn) clear_fn(); }
  };
  struct ext_t {
    std::function<uint32_t(uint32_t)> rd;
    std::function<void(uint32_t, uint32_t)> wr;
    uint32_t read_dword(uint32_t a) { return rd(a & 0xffffff); }
    void write_dword(uint32_t a, uint32_t d) { wr(a & 0xffffff, d); }
  };
  struct ram_t {
    uint32_t m[1024] = {};
    uint32_t read_dword(uint32_t a) { return m[a & 0x3ff]; }
    void write_dword(uint32_t a, uint32_t d) { m[a & 0x3ff] = d; }
  };

  mb86235_device() { m_core = &core_; fin.dev = this; fout.dev = this; }
  void stall() { m_core->cur_fifo_state.has_stalled = true; }
  void reset() { m_core->pc = 0; m_core->delay_pc = 0; m_core->ppc = 0; m_core->delay_slot = false; }

  // MAME's execute_run, one word (ENABLE_DRC 0). Returns the pc executed.
  uint32_t execute_one()
  {
    uint32_t curpc = check_previous_op_stall() ? m_core->cur_fifo_state.pc : m_core->pc;
    uint64_t opcode = prog[curpc & 0xfff];
    m_core->ppc = curpc;
    if (m_core->delay_slot == true) { m_core->pc = m_core->delay_pc; m_core->delay_slot = false; }
    else handle_single_step_execution();
    m_core->cur_fifo_state.has_stalled = false;
    execute_op(opcode);
    m_core->icount--;
    return curpc;
  }
  bool stalled() const { return m_core->cur_fifo_state.has_stalled; }

  // the R924 state hash (MAME patch, sim/tgpx4/mame_mb86235_cap.patch)
  uint32_t state_hash() const
  {
    uint32_t h = 2166136261u;
    auto mix = [&h](uint32_t v) { for (int k = 0; k < 4; k++) { h ^= (v >> (8 * k)) & 0xff; h *= 16777619u; } };
    const auto *c = m_core;
    for (int i = 0; i < 8; i++) { mix(c->aa[i]); mix(c->ab[i]); mix(c->ma[i]); mix(c->mb[i]); mix(c->ar[i]); }
    mix(c->sp); mix(c->eb); mix(c->eo); mix(c->rpc); mix(c->lpc);
    mix(c->prp); mix(c->pwp); for (int i = 0; i < 24; i++) mix(c->pr[i]);
    mix(c->mod); mix(c->st); mix(c->pcp); for (int i = 0; i < 4; i++) mix(c->pcs[i]);
    mix(c->pdr); mix(c->ddr);
    return h;
  }

  struct mb86235_flags { uint32_t az, an, av, au, ad, zc, il, nr, zd, mn, mz, mv, mu, md; };
  struct fifo_state { uint32_t pc; bool has_stalled; };
  struct mb86235_internal_state
  {
    uint32_t pc, delay_pc, ppc;
    uint32_t aa[8], ab[8], ma[8], mb[8], ar[8];
    uint32_t sp, eb, eo, rpc, lpc;
    uint32_t prp, pwp, pr[24];
    uint32_t mod;
    mb86235_flags flags;
    uint32_t st;
    int icount;
    uint32_t arg0, arg1, arg2, arg3; uint64_t arg64;
    uint32_t pcp, pcs[4];
    uint32_t jmpdest, alutemp, multemp, condtemp;
    uint32_t pdr, ddr;
    float fp0;
    bool delay_slot;
    fifo_state cur_fifo_state;
  };
  mb86235_internal_state core_ = {};
  mb86235_internal_state *m_core;

  uint64_t prog[4096] = {};
  fifo_t fin, fout;
  fifo_t *const m_fifoin = &fin;
  fifo_t *const m_fifoout = &fout;
  ext_t m_external;
  ram_t m_dataa, m_datab;

  // ---- MAME's interpreter (mb86235.h), unchanged
  void execute_op(uint64_t op);
  void do_alu1(uint64_t op);
  void do_alu2(uint64_t op);
  void do_alu2_trans2_1(uint64_t op);
  void do_alu2_trans1_1(uint64_t op);
  void do_alu1_trans2_2(uint64_t op);
  void do_alu1_trans1_2(uint64_t op);
  void do_trans1_3(uint64_t op);
  void do_alu_control(uint64_t op);
  inline uint32_t get_prx(uint8_t which);
  inline uint32_t get_constfloat(uint8_t which);
  inline uint32_t get_constint(uint8_t which);
  inline uint32_t get_alureg(uint8_t which, bool isfloatop);
  inline uint32_t get_mulreg(uint8_t which, bool isfloatop);
  inline void set_alureg(uint8_t which, uint32_t value);
  inline void decode_aluop(uint8_t opcode, uint32_t src1, uint32_t src2, uint8_t imm, uint8_t dst_which);
  inline void decode_mulop(bool isfmul, uint32_t src1, uint32_t src2, uint8_t dst_which);
  inline bool decode_branch_jump(uint8_t which);
  inline uint32_t do_control_dst(uint64_t op);
  inline void push_pc(uint32_t pcval);
  inline uint32_t pop_pc();
  inline void set_mod(uint16_t mod1, uint16_t mod2);
  inline uint32_t get_transfer_reg(uint8_t which);
  inline void set_transfer_reg(uint8_t which, uint32_t value);
  inline uint32_t decode_ea(uint8_t mode, uint8_t rx, uint8_t ry, uint16_t disp, bool isbbus);
  inline uint32_t read_abus(uint32_t addr);
  inline uint32_t read_bbus(uint32_t addr);
  inline void write_abus(uint32_t addr, uint32_t data);
  inline void write_bbus(uint32_t addr, uint32_t data);
  inline void increment_pwp();
  inline void increment_prp();
  inline void decrement_prp();
  inline void zero_prp();
  inline void set_alu_flagsd(uint32_t val);
  inline void set_alu_flagsf(float val);
  inline void set_alu_flagsi(int val);
  inline bool get_alu_second_src(uint8_t which);
  void handle_single_step_execution();
  bool check_previous_op_stall();
};
