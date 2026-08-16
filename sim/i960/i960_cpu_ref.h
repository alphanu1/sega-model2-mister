// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Whole-CPU reference for i960_top, transcribed from MAME's execute_op.
// BSD-3-Clause, Farfetch'd and R. Belmont.
//
// Assembled from the per-block references that are already verified against
// their own DUTs — the method Model 1 used for mb86233_ref. Nothing here
// re-derives semantics a block reference already owns; this file is fetch,
// dispatch and the control-flow instructions, which have no block of their own.
//
// Covers the subset i960_top executes. Anything outside it sets `trapped`,
// which the harness treats as end-of-program rather than as a mismatch.

#pragma once
#include <cstdint>
#include "i960_dec_ref.h"
#include "i960_alu_ref.h"
#include "i960_agu_ref.h"
#include "i960_ldst_ref.h"
#include "i960_regs_ref.h"
#include "i960_muldiv_ref.h"

namespace i960ref {

struct Cpu {
  Regs     rf;                 // r[32], rcache, memory and its op stream
  uint32_t AC = 0;
  uint32_t IP = 0;
  bool     trapped = false;
  uint8_t  trap_op = 0;
  uint64_t retired = 0;

  uint32_t rd(uint32_t a) {
    auto it = rf.mem.find(a & ~3u);
    return (it == rf.mem.end()) ? 0xffffffffu : it->second;   // never zero
  }
  void wr(uint32_t a, uint32_t v) { rf.mem[a & ~3u] = v; }

  // get_1_ci: bit 13 selects literal, field is (op>>19)&0x1f.
  uint32_t g1ci(uint32_t o) const {
    return (o & 0x2000u) ? ((o >> 19) & 0x1f) : rf.r[(o >> 19) & 0x1f];
  }
  // get_2_ci: always a register.
  uint32_t g2ci(uint32_t o) const { return rf.r[(o >> 14) & 0x1f]; }

  static uint32_t disp24(uint32_t o) { return uint32_t((int32_t(o << 8) >> 8) - 4); }
  static uint32_t disp13(uint32_t o) { return uint32_t((int32_t(o << 19) >> 19) - 4); }

  void cmpu(uint32_t a, uint32_t b) { i960ref::cmp_u(AC, a, b); }
  void cmps(int32_t a, int32_t b)   { i960ref::cmp_s(AC, a, b); }

  // bxx / bxx_s mask the IP after a taken branch. Plain `b`, `bbc` and `bbs`
  // do not. That asymmetry is in the source and is reproduced, not tidied.
  void bxx(uint32_t o, uint32_t mask)   { if (AC & mask) { IP += disp24(o); IP &= ~3u; } }
  void bxx_s(uint32_t o, uint32_t mask) { if (AC & mask) { IP += disp13(o); IP &= ~3u; } }

  void step() {
    if (trapped) return;
    const uint32_t insn = rd(IP);
    const Decoded d = i960ref::decode(insn);
    const uint32_t ip_next = IP + (d.insn_len2 ? 8 : 4);
    const uint32_t dispw   = d.insn_len2 ? rd(IP + 4) : 0;

    if (!d.valid) { trapped = true; trap_op = d.op; return; }

    switch (d.fmt) {
      case FMT_CTRL:
        switch (d.op) {
          // m_IP is already past the instruction when execute_op runs, so
          // every CTRL displacement is relative to ip_next, not ip.
          case 0x08: IP = ip_next + disp24(insn); break;               // b
          case 0x09: {                                                // call
            const uint32_t tgt = ip_next + disp24(insn);
            rf.call(ip_next, tgt, 0, 0);
            IP = tgt;
            break;
          }
          case 0x0a: IP = rf.ret(); break;                            // ret
          case 0x0b: rf.r[0x1e] = ip_next; IP = ip_next + disp24(insn); break; // bal
          default:
            if (d.op >= 0x10 && d.op <= 0x17) { IP = ip_next; bxx(insn, d.op & 7); }
            else if (d.op == 0x18) {
              // faultno is a conditional branch in the reference, and does not
              // mask the IP the way bxx does.
              IP = ip_next;
              if (!(AC & 7)) IP += disp24(insn);
            } else if (d.op >= 0x19 && d.op <= 0x1f) {
              // fxx: fatalerror when taken, nothing when not.
              if (AC & (d.op & 7)) { trapped = true; trap_op = d.op; }
              else IP = ip_next;
            } else { trapped = true; trap_op = d.op; }
            break;
        }
        break;

      case FMT_COBR: {
        IP = ip_next;
        if (d.op >= 0x20 && d.op <= 0x27) {                           // test<cc>
          const uint32_t m = d.op & 7;
          const bool set = m ? ((AC & m) != 0) : ((AC & 7) == 0);
          rf.r[(insn >> 19) & 0x1f] = set ? 1u : 0u;
        } else if (d.op == 0x30 || d.op == 0x37) {                    // bbc / bbs
          const uint32_t bit = g1ci(insn) & 0x1f;
          const uint32_t val = g2ci(insn);
          const bool s = (val >> bit) & 1u;
          if ((d.op == 0x37) ? s : !s) { AC = (AC & ~7u) | 2u; IP += disp13(insn); }
          else                          { AC &= ~7u; }
        } else if (d.op >= 0x31 && d.op <= 0x36) {                    // cmpob<cc>
          cmpu(g1ci(insn), g2ci(insn));  bxx_s(insn, d.op & 7);
        } else if (d.op >= 0x39 && d.op <= 0x3e) {                    // cmpib<cc>
          cmps(int32_t(g1ci(insn)), int32_t(g2ci(insn))); bxx_s(insn, d.op & 7);
        } else { trapped = true; trap_op = d.op; }
        break;
      }

      case FMT_REG: {
        const uint32_t s1 = d.src1_lit ? d.src1 : rf.r[d.src1];
        const uint32_t s2 = d.src2_lit ? d.src2 : rf.r[d.src2];
        // movl / movt / movq: 2, 3 or 4 consecutive registers. The
        // destination mask differs per opcode; the SOURCE is never masked.
        //
        // OVERLAPPING SOURCE AND DESTINATION ARE UNDEFINED. The reference uses
        // memcpy, and memcpy with overlapping regions is undefined in C —
        // memmove is the defined one. The forward loop below propagates
        // (r[28]=r[27], then r[29]=r[28] which is already r[27]); a vectorised
        // or backward memcpy would not. The harness never generates an overlap,
        // the same way it never generates a zero divisor.
        if (d.op2 == 0xc && (d.op == 0x5d || d.op == 0x5e || d.op == 0x5f)) {
          const uint8_t n    = (d.op == 0x5d) ? 2 : (d.op == 0x5e) ? 3 : 4;
          const uint8_t base = d.srcdst & ((d.op == 0x5d) ? 0x1e : 0x1c);
          if (d.src1_lit) for (uint8_t k = 0; k < n; k++) rf.r[(base + k) & 0x1f] = d.src1;
          else            for (uint8_t k = 0; k < n; k++)
                            rf.r[(base + k) & 0x1f] = rf.r[(d.src1 + k) & 0x1f];
          IP = ip_next;
          break;
        }

        // 0x70, 0x74 and 0x67 are multi-cycle and bypass the ALU.
        const MdOut m = i960ref::muldiv(d.op, d.op2, s1, s2, 0);
        if (m.valid) {
          rf.r[d.srcdst] = m.lo;
          // emul and ediv write a pair, and the destination is NOT masked.
          if (m.pair) rf.r[(d.srcdst + 1) & 0x1f] = m.hi;
          IP = ip_next;
          break;
        }
        const AluOut a = i960ref::alu(d.op, d.op2, s1, s2, AC);
        if (!a.valid) { trapped = true; trap_op = d.op; break; }
        AC = a.ac;
        if (a.result_we) rf.r[d.srcdst] = a.result;
        IP = ip_next;
        break;
      }

      default: {                                                       // MEM
        const AguOut g = i960ref::agu(insn, rf.r[d.abase], rf.r[d.index],
                                      dispw, IP + 8);
        const LdSt   l = i960ref::ldst(d.op, g.ea & 3, 0, 0);
        if (!g.valid || !l.valid) { trapped = true; trap_op = d.op; break; }

        if (l.no_mem) {                                                // lda
          rf.r[d.srcdst] = g.ea;
        } else {
          const uint8_t base = d.srcdst & l.reg_mask;
          uint32_t t1 = g.ea;
          // Burst decode mirrors i960_memmap. Only the regions the test uses
          // matter here; the module owns the full table.
          const bool burst = (t1 < 0x00200000u) ||
                             (t1 >= 0x00500000u && t1 < 0x00600000u);
          for (uint8_t w = 0; w < l.n_words; ++w) {
            if (l.is_store) {
              const uint32_t v = rf.r[(base + w) & 0x1f];
              uint32_t dcur = rd(t1);
              if (l.size == 0)      dcur = (dcur & ~(0xffu << ((t1 & 3) * 8)))
                                          | ((v & 0xffu) << ((t1 & 3) * 8));
              else if (l.size == 1) dcur = (t1 & 2) ? ((dcur & 0x0000ffffu) | (v << 16))
                                                    : ((dcur & 0xffff0000u) | (v & 0xffffu));
              else                  dcur = v;
              wr(t1, dcur);
            } else {
              const uint32_t dv = rd(t1);
              const LdSt e = i960ref::ldst(d.op, t1 & 3, dv, 0);
              rf.r[(base + w) & 0x1f] = e.ld_result;
            }
            if (burst) t1 += 4;
          }
        }
        IP = ip_next;
        break;
      }
    }
    ++retired;
  }
};

} // namespace i960ref
