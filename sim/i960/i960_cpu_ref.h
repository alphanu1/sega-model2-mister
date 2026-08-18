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
#include <vector>
#include <utility>
#include "i960_dec_ref.h"
#include "i960_alu_ref.h"
#include "i960_agu_ref.h"
#include "i960_ldst_ref.h"
#include "i960_regs_ref.h"
#include "i960_muldiv_ref.h"
#include <cmath>
#include <cstring>

namespace i960ref {

struct Cpu {
  Regs     rf;
  double   fp[4] = {0,0,0,0};        // fp0-fp3, held as double per spike §8

  // u2f / f2u: a general register reinterpreted as IEEE single, and back.
  static double u2f(uint32_t v) { float f; std::memcpy(&f, &v, 4); return (double)f; }

  // The FP units flush subnormal singles to zero; the host does not. That is a
  // recorded deviation (p1-i960-spike.md §8.1), not a defect, and it is reached
  // here far more often than at block level: any arithmetic can leave a small
  // integer in a register, and a small integer reinterpreted as a single IS a
  // subnormal. 0x1b is 3.8e-44, and `0 / 3.8e-44` is 0 on the host but 0/0 = NaN
  // once the divisor flushes. Flagged rather than avoided, so the suite skips
  // exactly the deviation and still compares everything else on that retire.
  bool fp_denorm_operand = false;
  // Which general register this retire's FP result narrowed into, or -1. A
  // single-precision NaN's sign and payload differ between the units' canonical
  // quiet NaN and the host's propagation — recorded, and already exempted for
  // fp0-fp3. Naming the register keeps that exemption to exactly the word the
  // FP unit wrote, so an integer result that merely looks like a NaN is still
  // compared bit for bit.
  int  fp_sdest = -1;
  // Set when this retire's FP result is a NaN. The units emit one canonical
  // quiet NaN; the host propagates the operand's payload and sign. Exempting
  // the comparison is not enough, because the differing word stays in the
  // register file and breaks every retire after it — so the program ends here,
  // the same as for a flushed subnormal.
  bool fp_nan_result = false;
  // Modelled, not excluded. Abandoning every program that touched a subnormal
  // cost 111 of 200 -- most of the run, and it truncated at the deepest
  // retires first, which is where the interesting state is. The flush is a
  // two-line predicate written from the specification (§8.1) rather than read
  // off the RTL, so it does not agree with the design by construction: if a
  // unit flushes something it should not, this still diverges.
  static double flush_s(uint32_t v) {
    if (((v >> 23) & 0xff) == 0 && (v & 0x7fffff) != 0)
      return (v & 0x80000000u) ? -0.0 : 0.0;
    return u2f(v);
  }
  static double flush_d(double d) {
    return (std::fpclassify(d) == FP_SUBNORMAL) ? std::copysign(0.0, d) : d;
  }
  double u2f_t(uint32_t v) { return flush_s(v); }
  static uint32_t f2u(double d) { float f = (float)d; uint32_t v; std::memcpy(&v, &f, 4); return v; }

  // The literal forms select fp0-fp3, or 1.0 at index 0x16, else 0.0.
  double fp_lit(uint32_t idx) const {
    if (idx < 4) return fp[idx];
    if (idx == 0x16) return 1.0;
    return 0.0;
  }                 // r[32], rcache, memory and its op stream
  uint32_t AC = 0;
  uint32_t IP = 0;
  bool     trapped = false;
  uint8_t  trap_op = 0;
  uint64_t retired = 0;

  uint32_t rd(uint32_t a) {
    auto it = rf.mem.find(a & ~3u);
    return (it == rf.mem.end()) ? 0xffffffffu : it->second;   // never zero
  }
  // Every store this reference performs, in order. The exit criteria call for
  // comparing the data-memory write stream and the whole-CPU harness never did
  // -- which is why a store divergence could only ever surface indirectly, as a
  // later load reading a value the other side never wrote.
  std::vector<std::pair<uint32_t,uint32_t>> stores;
  void wr(uint32_t a, uint32_t v) {
    rf.mem[a & ~3u] = v;
    stores.emplace_back(a & ~3u, v);
  }

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
    fp_denorm_operand = false;
    fp_sdest          = -1;
    fp_nan_result     = false;
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

        // ---- single-precision FP, the subset wired into the CPU ----
        {
          const double fa = d.src1_lit ? fp_lit(d.src1) : u2f_t(rf.r[d.src1]);
          const double fb = d.src2_lit ? fp_lit(d.src2) : u2f_t(rf.r[d.src2]);
          bool handled = true, wr_int = false, wr_cc = false;
          double fres = 0.0; uint32_t ires = 0;
          const int rm = int((AC >> 30) & 3);
          auto rti = [&](double v) {
            switch (rm) { case 0: return std::round(v); case 1: return std::floor(v);
                          case 2: return std::ceil(v);  default: return std::trunc(v); }
          };
          // Opcode and sub-opcode pack as 0xOOS across THREE hex digits, so
          // the shift is 4, not 8. With 8 the labels never matched, `handled`
          // was always false, and every FP instruction trapped in the reference
          // while the DUT executed it — which ended the lockstep loop before it
          // could compare anything and made the FP-register check look inert.
          switch ((uint32_t(d.op) << 4) | d.op2) {
            case 0x78f: fres = fb + fa; break;                       // addr
            case 0x78d: fres = fb - fa; break;                       // subr
            case 0x78c: fres = fb * fa; break;                       // mulr
            case 0x78b: fres = fb / fa; break;                       // divr
            case 0x688: fres = std::sqrt(fa); break;                 // sqrtr
            case 0x68a: fres = std::logb(fa); break;                 // logbnr
            case 0x68b: fres = rti(fa); break;                       // roundr
            case 0x685: {                                            // cmpr
              wr_cc = true;
              AC &= ~7u;
              if (!(std::isnan(fa) || std::isnan(fb)))
                AC |= (fa < fb) ? 4 : (fa == fb) ? 2 : 1;
              break;
            }
            case 0x6c0: wr_int = true; ires = uint32_t(int32_t(rti(fa))); break;   // cvtri
            case 0x6c2: wr_int = true; ires = uint32_t(int32_t(fa)); break;        // cvtzri
            case 0x6c9: fres = fa; break;                                          // movr
            case 0x674: fres = double(int32_t(s1)); break;                          // cvtir
            case 0x677: fres = fb * std::pow(2.0, double(int32_t(s1))); break;      // scaler
            default: handled = false; break;
          }
          if (handled) {
            if (!wr_cc) {
              if (wr_int)            rf.r[d.srcdst] = ires;
              else if (d.dst_lit)    fp[d.srcdst & 3] = flush_d(fres);
              else {
                // The result flushes too, not only the operands: a pair of
                // normal singles can divide to a subnormal one.
                uint32_t u = f2u(fres);
                if (((u >> 23) & 0xff) == 0 && (u & 0x7fffff) != 0)
                  u &= 0x80000000u;
                rf.r[d.srcdst] = u;
                fp_sdest       = d.srcdst;
              }
              if (!wr_int && std::isnan(fres)) fp_nan_result = true;
            }
            IP = ip_next;
            break;
          }
        }
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

        if (l.no_mem && d.op == 0x86) {                               // callx
          rf.call(ip_next, g.ea, 0, 0);
          IP = g.ea;
          break;
        } else if (l.no_mem) {                                         // lda
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
              // BYTE-WISE, because a store need not be aligned. The previous
              // form replaced the whole word at `t1 & ~3` for a word store and
              // used `t1 & 2` for a half, both of which assume alignment -- so
              // `st` to 0xd66 wrote all four bytes of 0xd64 instead of its
              // upper half and the lower half of 0xd68. MAME's memory system
              // splits an unaligned access; this now does too.
              //
              // Reached only once the generator stopped emitting exclusively
              // word-aligned offsets.
              const uint8_t nb = (l.size == 0) ? 1 : (l.size == 1) ? 2 : 4;
              for (uint8_t k = 0; k < nb; ++k) {
                const uint32_t ba = t1 + k;
                uint32_t word = rd(ba);
                word = (word & ~(0xffu << ((ba & 3) * 8)))
                     | (((v >> (k * 8)) & 0xffu) << ((ba & 3) * 8));
                wr(ba, word);
              }
            } else {
              // BYTE-WISE for the same reason as the store above: an unaligned
              // load spans two words, and reading a single word at `t1 & ~3`
              // and extracting from it silently returned the wrong half. `ld`
              // from 0xb17 needs one byte of 0xb14 and three of 0xb18.
              const uint8_t nb = (l.size == 0) ? 1 : (l.size == 1) ? 2 : 4;
              uint32_t raw = 0;
              for (uint8_t k = 0; k < nb; ++k) {
                const uint32_t ba = t1 + k;
                raw |= ((rd(ba) >> ((ba & 3) * 8)) & 0xffu) << (k * 8);
              }
              uint32_t res;
              if      (l.size == 0) res = l.sign_ext ? uint32_t(int32_t(int8_t (raw)))
                                                     : (raw & 0xffu);
              else if (l.size == 1) res = l.sign_ext ? uint32_t(int32_t(int16_t(raw)))
                                                     : (raw & 0xffffu);
              else                  res = raw;
              rf.r[(base + w) & 0x1f] = res;
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
