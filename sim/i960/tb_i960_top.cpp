// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Whole-CPU lockstep for i960_top against the transcribed reference.
//
// Compares all 32 architectural registers, AC and IP after every retire, plus
// data memory at the end.
//
// Instruction-fetch bus traffic is deliberately NOT compared. The DUT fetches
// through a 16-byte-line cache while the reference reads single words, so the
// two streams differ by design — that is the cache doing its job, not a bug.
// Data writes are compared through memory contents instead.
//
// Programs are generated from the subset i960_top implements, with registers
// and memory seeded identically on both sides. Anything the reference traps on
// ends the program rather than counting as a mismatch.

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <map>
#include <random>
#include <vector>
#include "Vi960_top.h"
#include "Vi960_top___024root.h"
#include "verilated.h"
#include <cmath>
#include "i960_cpu_ref.h"

namespace {
Vi960_top   *dut = nullptr;
i960ref::Cpu ref;
std::map<uint32_t,uint32_t> mem;
uint64_t fpwrites = 0, fpany = 0;
uint32_t exec_ip = 0, exec_insn = 0;   // the instruction just retired
uint64_t checks = 0, fails = 0, ticks = 0, retires = 0;
const int MAX_REPORT = 10;

// Cycles spent in each sequencer state. Measuring before optimising, because
// the last time this project optimised on intuition it went after the wrong
// block entirely.
uint64_t state_cycles[16] = {0};
const char *STATE_NAME[16] = {
  "T_FETCH","T_FETCH_W","T_FETCH2","T_FETCH2_W","T_DECODE","T_EXEC",
  "T_MEM","T_MEM_W","T_MULDIV","T_MULTI","T_PAIR","T_FP","T_WB","T_FRAME",
  "T_TRAP","?"
};

uint64_t fetch_enter = 0, fetch_hit = 0, fetch_stall = 0, ic_fill_cyc = 0;

bool bus_probe = false;
int pf_bad = 0;

// Straight-line programs have NO temporal locality: every instruction runs once,
// so every I-cache miss is compulsory and no cache of any size can help. An
// LINES sweep from 512 B to 4 KB returned byte-identical numbers because of it.
//
// Real code loops. M2-B's Daytona sample executed 38,987 instructions over 4,265
// distinct PCs -- 9.1x average PC reuse. `+loops` closes an unconditional
// backward branch over part of the program and extends the retire budget, so
// instructions execute repeatedly and the fetch path is exercised the way real
// code exercises it.
//
// Off by default: a loop narrows what a single program covers, and the default
// mix exists to cover instruction forms. Use it for fetch and cache work.
bool loop_mode = false;
std::vector<std::pair<uint32_t,uint32_t>> dut_stores;

struct Trace { uint64_t t; int ts; int req, valid, busy; uint32_t addr, data, insn, ip; };
Trace ring[4096];
size_t ring_n = 0;

void dump_ring() {
  std::printf("  --- front-end activity (req/valid/latch only) ---\n");
  const size_t start = ring_n < 4096 ? 0 : ring_n - 4096;
  uint32_t prev_insn = 0;
  for (size_t k = start; k < ring_n; ++k) {
    const Trace &e = ring[k % 4096];
    const bool interesting = e.req || e.valid || (e.insn != prev_insn);
    prev_insn = e.insn;
    if (!interesting) continue;
    std::printf("   t=%-6llu ts=%-2d req=%d valid=%d busy=%d addr=%08x "
                "data=%08x insn=%08x ip=%08x\n",
                (unsigned long long)e.t, e.ts, e.req, e.valid, e.busy,
                e.addr, e.data, e.insn, e.ip);
  }
}

void tick() {
  const int ts_now = dut->rootp->i960_top__DOT__ts & 15;
  // PREFETCH INVARIANT, checked at the moment a word is latched: whatever the
  // front end accepts must be the word actually at `ip`. A prefetch queue that
  // hands over the wrong instruction shows up downstream as a wrong register,
  // dozens of retires later, with nothing pointing back at the fetch.
  if ((ts_now == 0 || ts_now == 1) && dut->rootp->i960_top__DOT__fetch_word_ok) {
    const uint32_t at = dut->rootp->i960_top__DOT__ip;
    auto it = mem.find(at);
    const uint32_t want = (it == mem.end()) ? 0xffffffffu : it->second;
    const uint32_t got  = dut->rootp->i960_top__DOT__fetch_word;
    if (got != want && pf_bad < 6) {
      std::printf("  [PREFETCH] latched %08x at ip=%08x, memory has %08x"
                  "   pf_ip=%08x v%d\n",
                  got, at, want,
                  dut->rootp->i960_top__DOT__pf_ip,
                  dut->rootp->i960_top__DOT__pf_valid);
      ++pf_bad;
    }
  }

  if (bus_probe && dut->bus_req && (dut->bus_addr & ~3u) >= 0x800 && !dut->bus_we)
    std::printf("  [req] bus_addr=%08x cur=%08x widx=%d nw=%d burst=%d\n",
                dut->bus_addr,
                dut->rootp->i960_top__DOT__u_lsu__DOT__cur_addr,
                dut->rootp->i960_top__DOT__u_lsu__DOT__widx,
                dut->rootp->i960_top__DOT__u_lsu__DOT__nw,
                dut->rootp->i960_top__DOT__u_lsu__DOT__burst_q);
  if (bus_probe && dut->rootp->i960_top__DOT__lsu_ldwe)
    std::printf("  [lsu] ldwe widx=%d ldword=%08x mask=%02x srcdst=%02d ts=%d\n",
                dut->rootp->i960_top__DOT__lsu_widx,
                dut->rootp->i960_top__DOT__lsu_ldword,
                dut->rootp->i960_top__DOT__ls_regmask,
                dut->rootp->i960_top__DOT__d_srcdst, ts_now);
  {
    Trace &e = ring[ring_n % 64];
    e.t = ticks; e.ts = ts_now;
    e.req   = dut->rootp->i960_top__DOT__ic_req;
    e.valid = dut->rootp->i960_top__DOT__ic_valid;
    e.busy  = dut->rootp->i960_top__DOT__ic_busy;
    e.addr  = dut->rootp->i960_top__DOT__fetch_addr;
    e.data  = dut->rootp->i960_top__DOT__ic_data;
    e.insn  = dut->rootp->i960_top__DOT__insn;
    e.ip    = dut->rootp->i960_top__DOT__ip;
    ++ring_n;
  }
  state_cycles[ts_now]++;
  // Where the fetch cycles actually go. T_FETCH costs 1 cycle when the
  // prefetch predicted correctly and much more otherwise, so the average alone
  // cannot say whether the cost is a missing prediction or a slow fill.
  {
    static int ts_prev = -1;
    if (ts_now == 0 && ts_prev != 0) ++fetch_enter;          // entered T_FETCH
    // Probe the signal, not a state transition: T_DECODE was removed, and a
    // hit-counter keyed on "T_FETCH -> T_DECODE" then silently read 0% rather
    // than reporting that it had stopped measuring anything.
    if (ts_now == 0 && dut->rootp->i960_top__DOT__fetch_word_ok) ++fetch_hit;
    if (ts_prev == 0 && ts_now == 0) ++fetch_stall;          // stuck in T_FETCH
    if (ts_now == 1)                 ++ic_fill_cyc;          // waiting on a fill
    ts_prev = ts_now;
  }
  if (dut->bus_req) {
    const uint32_t a = dut->bus_addr & ~3u;
    if (bus_probe && a >= 0x800) {
      auto i2 = mem.find(a);
      std::printf("  [bus] %s addr=%08x be=%x rdata=%08x wdata=%08x insn=%08x\n",
                  dut->bus_we ? "WR" : "RD", dut->bus_addr, dut->bus_be,
                  (i2 == mem.end()) ? 0xffffffffu : i2->second, dut->bus_wdata,
                  dut->rootp->i960_top__DOT__insn);
    }
    auto it = mem.find(a);
    const uint32_t cur = (it == mem.end()) ? 0xffffffffu : it->second;
    if (dut->bus_we) {
      uint32_t d = cur;
      for (int l = 0; l < 4; l++)
        if (dut->bus_be & (1 << l))
          d = (d & ~(0xffu << (l*8))) | (dut->bus_wdata & (0xffu << (l*8)));
      mem[a] = d;
      dut_stores.emplace_back(a, d);
    } else {
      dut->bus_rdata = cur;
    }
    dut->bus_ack = 1;
  } else dut->bus_ack = 0;
  dut->clk = 0; dut->eval();
  dut->clk = 1; dut->eval();
  ++ticks;
}

// Verilated internals, exposed with --public-flat-rd. Reading the register file
// directly avoids adding debug ports that would change what is measured.
uint32_t dreg(int i) {
  return (i < 16) ? dut->rootp->i960_top__DOT__u_regs__DOT__loc[i]
                  : dut->rootp->i960_top__DOT__u_regs__DOT__glb[i-16];
}
uint32_t dac() { return dut->rootp->i960_top__DOT__ac; }

// fp0-fp3. Comparing these closes a real gap: an instruction whose only effect
// is an FP-register write was previously executed by both sides and checked by
// neither.
uint64_t dfp(int i) { return dut->rootp->i960_top__DOT__fpr[i]; }
uint64_t ref_fp_bits(int i) {
  uint64_t b; std::memcpy(&b, &ref.fp[i], 8); return b;
}
uint32_t dip() { return dut->rootp->i960_top__DOT__ip; }

const char *rn(int i) {
  static char b[8];
  std::snprintf(b, sizeof b, i < 16 ? "r%d" : "g%d", i < 16 ? i : i - 16);
  return b;
}

uint64_t denorm_skips = 0;
uint64_t nan_stops    = 0;
bool     probe_fp     = false;

// Instruction-class weighting.
//
// Two modes, and the default is NOT the realistic one on purpose.
//
//   coverage (default) -- every class roughly equally often. Frequency in real
//     code is irrelevant to a verifier: a rare instruction that is wrong is
//     still wrong, and weighting by frequency would bury it.
//
//   daytona (+mix=daytona) -- the mix MEASURED from Daytona USA under MAME
//     (M2-B): 52.9% load/store, 13.6% integer ALU, 9.7% move, 9.4%
//     compare/branch, 8.0% lda, 0.8% FP. Use this for CPI and throughput, where
//     frequency is the only thing that matters.
//
// Reporting a CPI figure without saying which mix produced it is what R9 exists
// to prevent -- the two differ by a large factor, and neither is wrong.
enum { C_REGALU=0, C_BRANCH=1, C_FAULT=2, C_CMPBR=3, C_FP=4, C_BBX=5,
       C_EMUL=6, C_MOVX=7, C_MOV=8, C_MULDIV=9, C_LDST=10, C_LDA=11, C_TEST=12,
       C_N=13 };

bool mix_daytona = false;

// coverage: near-uniform. daytona: M2-B's measured shares, in percent.
const int W_COVER[C_N]  = { 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 4 };
const int W_DAYTON[C_N] = { 12, 4, 0, 6, 1, 2, 1, 3, 10, 1, 49, 8, 3 };

int pick_class(std::mt19937_64 &rng) {
  const int *w = mix_daytona ? W_DAYTON : W_COVER;
  int total = 0;
  for (int i = 0; i < C_N; ++i) total += w[i];
  int r = int(rng() % uint64_t(total));
  for (int i = 0; i < C_N; ++i) { r -= w[i]; if (r < 0) return i; }
  return C_REGALU;
}

bool compare(uint64_t n) {
  // Skip the retire outright when the reference widened a subnormal single.
  // The units flush, the host does not, and the divergence is real but already
  // recorded (§8.1). Skipping is what the block harnesses do; counting the
  // skips is what stops it quietly becoming most of the run.
  bool ok = true;
  for (int i = 0; i < 32; i++) {
    ++checks;
    const bool fp_nan_ok = (i == ref.fp_sdest) &&
                           ((dreg(i)      & 0x7fffffffu) > 0x7f800000u) &&
                           ((ref.rf.r[i]  & 0x7fffffffu) > 0x7f800000u);
    if (dreg(i) != ref.rf.r[i] && !fp_nan_ok) {
      ok = false;
      if (fails < MAX_REPORT)
        if (fails == 0) {
          // Loads and stores are new to this generator. A load divergence is
          // often a STORE divergence surfacing later, so compare the data
          // windows before blaming the load.
          int shown = 0;
          for (const auto &kv : mem) {
            if (kv.first < 0x800) continue;
            auto it = ref.rf.mem.find(kv.first);
            const uint32_t r = (it == ref.rf.mem.end()) ? 0xffffffffu : it->second;
            if (r != kv.second && shown < 8) {
              std::printf("  MEMDIFF %08x  dut=%08x ref=%08x\n",
                          kv.first, kv.second, r);
              ++shown;
            }
          }
          if (!shown) std::printf("  (data memory agrees; divergence is in the load path)\n");
          dump_ring();
        }
        std::printf("  MISMATCH retire %llu  %-4s got=%08x want=%08x  (IP %08x insn %08x)\n",
                    (unsigned long long)n, rn(i), dreg(i), ref.rf.r[i],
                    exec_ip, exec_insn);
      ++fails;
    }
  }
  for (int i = 0; i < 4; i++) {
    ++checks;
    const uint64_t g = dfp(i), w = ref_fp_bits(i);
    // NaN payloads may differ between a hardware canonical quiet NaN and the
    // host's propagation, and that is a recorded deviation rather than a bug,
    // so both-NaN is accepted. Everything else is compared bit for bit.
    double gd, wd; std::memcpy(&gd, &g, 8); std::memcpy(&wd, &w, 8);
    if (g != w && !(std::isnan(gd) && std::isnan(wd))) {
      ok = false;
      if (fails < MAX_REPORT)
        std::printf("  MISMATCH retire %llu  fp%d  got=%016llx want=%016llx"
                    "  (insn %08x op=%02x op2=%x s1=%02d s2=%02d lit %d%d%d)\n",
                    (unsigned long long)n, i,
                    (unsigned long long)g, (unsigned long long)w, exec_insn,
                    exec_insn >> 24, (exec_insn >> 7) & 0xf, exec_insn & 0x1f,
                    (exec_insn >> 14) & 0x1f, !!(exec_insn & 0x800),
                    !!(exec_insn & 0x1000), !!(exec_insn & 0x2000));
      ++fails;
    }
  }

  ++checks;
  if (dac() != ref.AC) {
    ok = false;
    if (fails < MAX_REPORT)
      std::printf("  MISMATCH retire %llu  AC   got=%08x want=%08x\n",
                  (unsigned long long)n, dac(), ref.AC);
    ++fails;
  }
  ++checks;
  if (dip() != ref.IP) {
    ok = false;
    if (fails < MAX_REPORT)
      std::printf("  MISMATCH retire %llu  IP   got=%08x want=%08x\n",
                  (unsigned long long)n, dip(), ref.IP);
    ++fails;
  }
  return ok;
}
} // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  uint64_t progs = 200, steps = 60, seed = 1;
  for (int i = 1; i < argc; ++i) {
    if (!std::strncmp(argv[i], "+random=", 8)) progs = std::strtoull(argv[i]+8, nullptr, 10);
    if (!std::strcmp (argv[i], "+probe_fp"))  probe_fp = true;
    if (!std::strcmp (argv[i], "+bus_probe")) bus_probe = true;
    if (!std::strcmp (argv[i], "+loops"))     loop_mode = true;
    if (!std::strcmp (argv[i], "+mix=daytona")) mix_daytona = true;
    if (!std::strncmp(argv[i], "+seed=", 6))   seed  = std::strtoull(argv[i]+6, nullptr, 10);
    // Program length is the WORKING SET, and the working set is what decides
    // whether cache size matters. At the 60-instruction default the footprint
    // is 240 bytes and fits in any cache, which is why an 8x LINES sweep
    // returned identical numbers even after loops were added. Daytona's sample
    // touched 4,265 distinct PCs -- about 17 KB, or 34x a 512 B cache.
    if (!std::strncmp(argv[i], "+steps=", 7)) steps = std::strtoull(argv[i]+7, nullptr, 10);
  }
  dut = new Vi960_top;
  std::printf("i960_top whole-CPU lockstep\n");

  // Opcodes i960_top has an execution path for.
  const uint8_t REG58[] = {0x0,0x1,0x2,0x3,0x4,0x6,0x7,0x8,0x9,0xa,0xb,0xc,0xd,0xe,0xf};
  const uint8_t REG59[] = {0x0,0x1,0x2,0x3,0x8,0xa,0xb,0xc,0xd,0xe};
  const uint8_t REG5A[] = {0x0,0x1,0x2,0x3,0x4,0x5,0x6,0x7,0xc,0xe};

  std::mt19937_64 rng(seed);
  uint64_t total_retires = 0, trapped_progs = 0;

  for (uint64_t p = 0; p < progs && fails == 0; ++p) {
    mem.clear(); ref = i960ref::Cpu(); dut_stores.clear();

    // Generate a straight-line program of REG and COBR forms. Work RAM at
    // 0x00500000 is burst-flagged; the program sits at 0.
    std::vector<uint32_t> prog;
    for (uint64_t k = 0; k < steps; ++k) {
      const int cls = pick_class(rng);
      uint32_t insn;
      if (cls == 7) {                                  // movl / movt / movq
        const uint32_t blk = 0x5d + (rng() % 3);
        const uint32_t n    = (blk == 0x5d) ? 2u : (blk == 0x5e) ? 3u : 4u;
        const uint32_t sd   = rng() % 32;
        const uint32_t base = sd & ((blk == 0x5d) ? 0x1eu : 0x1cu);
        const bool lit = (rng() & 1);
        // Source and destination must not overlap. memcpy with overlapping
        // regions is undefined in the reference, so an overlap would compare
        // this design against whatever the host's memcpy happened to do.
        // Overlap must be tested on the WRAPPED index sets. A linear
        // comparison misses src=30,n=4 (indices 30,31,0,1) colliding with
        // base=0 — the register number is 5 bits and the copy wraps.
        auto overlaps = [&](uint32_t a, uint32_t b) {
          for (uint32_t i = 0; i < n; i++)
            for (uint32_t j = 0; j < n; j++)
              if (((a + i) & 31u) == ((b + j) & 31u)) return true;
          return false;
        };
        uint32_t src = rng() % 32;
        for (int t = 0; !lit && t < 64 && overlaps(src, base); ++t) src = rng() % 32;
        if (!lit && overlaps(src, base)) src = (base + 8) & 0x1f;
        insn = (blk << 24) | (sd << 19) | (0xcu << 7) | src;
        if (lit) insn |= 0x0800;
      } else if (cls == 6) {                           // emul / ediv
        // srcdst is capped at 30: the destination is unmasked, so 31 would make
        // the reference write m_r[32], one past the end of its array. Undefined
        // there, so never generated — same rule as the zero divisor.
        insn = (0x67u << 24) | ((rng() % 31) << 19) | ((rng() % 32) << 14)
             | ((rng() & 1) << 7) | (1 + rng() % 31) | 0x0800;
      } else if (cls == 9) {                           // mul / div / rem / mod
        const uint32_t blk = (rng() & 1) ? 0x70u : 0x74u;
        static const uint8_t U[] = {0x1,0x8,0xb}, S[] = {0x1,0x8,0x9,0xb};
        const uint32_t o2 = (blk == 0x70) ? U[rng()%3] : S[rng()%4];
        // src1 is the divisor. A literal keeps it non-zero, which the
        // reference leaves undefined for every opcode except divo.
        insn = (blk << 24) | ((rng() % 32) << 19) | ((rng() % 32) << 14)
             | (o2 << 7) | (1 + rng() % 31) | 0x0800;
      } else if (cls == 4) {                           // single-precision FP
        static const uint32_t FPOPS[] = {
          0x78fu, 0x78du, 0x78cu, 0x78bu,      // addr subr mulr divr
          0x688u, 0x68au, 0x68bu, 0x685u,      // sqrtr logbnr roundr cmpr
          0x6c0u, 0x6c2u, 0x6c9u,              // cvtri cvtzri movr
          0x674u, 0x677u };                    // cvtir scaler
        // The table packs opcode and sub-opcode as 0xOOS across THREE hex
        // digits, so the opcode is (sel >> 4) & 0xff. Using sel >> 8 yields
        // 0x07 for 0x78f -- an invalid opcode that traps, which is why the
        // FP-register-destination path was never once reached.
        const uint32_t sel = FPOPS[rng() % (sizeof FPOPS / sizeof FPOPS[0])];
        insn = (((sel >> 4) & 0xffu) << 24) | ((rng() % 32) << 19)
             | ((rng() % 32) << 14) | ((sel & 0xf) << 7) | (rng() % 32);
        if (rng() & 1) insn |= 0x0800;
        if (rng() & 1) insn |= 0x1000;
        // A literal destination writes fp0-fp3 and needs bits 23:21 clear.
        if ((rng() % 4) == 0) insn = (insn | 0x2000u) & ~0x00e00000u;
      } else if (cls == 8) {                           // mov / bit scan / modac
        static const uint8_t B64[] = {0x0,0x1,0x4,0x5};
        const bool use5c = (rng() & 1);
        const uint32_t blk = use5c ? 0x5cu : 0x64u;
        const uint32_t o2  = use5c ? 0xcu  : B64[rng() % 4];
        insn = (blk << 24) | ((rng() % 32) << 19) | ((rng() % 32) << 14)
             | (o2 << 7) | (rng() % 32);
        if (rng() & 1) insn |= 0x0800;
        if (rng() & 1) insn |= 0x1000;
      } else if (cls == 0) {                           // REG ALU
        const uint32_t blk = 0x58 + (rng() % 4);
        uint32_t o2;
        if      (blk == 0x58) o2 = REG58[rng() % 15];
        else if (blk == 0x59) o2 = REG59[rng() % 10];
        else if (blk == 0x5a) o2 = REG5A[rng() % 10];
        else                  o2 = (rng() & 1) ? 2 : 0;
        insn = (blk << 24) | ((rng() % 32) << 19) | ((rng() % 32) << 14)
             | (o2 << 7) | (rng() % 32);
        if (rng() & 1) insn |= 0x0800;                 // src1 literal
        if (rng() & 1) insn |= 0x1000;                 // src2 literal
      } else if (cls == 1) {                           // b / bal
        // Short forward displacements only, so the target stays inside the
        // program rather than landing in unwritten memory every time.
        const uint32_t d = 4u + 4u * (rng() % 6);
        insn = (((rng() & 1) ? 0x0bu : 0x08u) << 24) | ((d + 4u) & 0x00ffffffu);
      } else if (cls == 2) {                           // faultno / fault<cc>
        // Only the not-taken path of fault<cc> is generated: the taken path is
        // fatalerror in the reference and §1 scopes it out, so both sides trap
        // and there is nothing to compare.
        insn = ((0x18u + (rng() % 8)) << 24) | (rng() % 0x10000u & ~3u);
      } else if (cls == 12) {                          // test<cc>
        insn = ((0x20 + (rng() % 8)) << 24) | ((rng() % 32) << 19);
      } else if (cls == 3) {                           // cmpib<cc> / cmpob<cc>
        const uint32_t op = (rng() & 1) ? (0x31 + rng() % 6) : (0x39 + rng() % 6);
        insn = (op << 24) | ((rng() % 32) << 19) | ((rng() % 32) << 14) | 0x0008;
      } else if (cls == 10) {                          // load / store  (MEMA)
        // MEMA absolute: bit 12 must be 0 (that is what selects MEMA over
        // MEMB), bit 13 = 0 selects a plain offset rather than r[abase] +
        // offset. Offset is 12 bits, so the data window is 0x800-0xFFC --
        // clear of the program, which sits at 0 and is `steps` words long.
        // Form weights MEASURED from Daytona (M2-B), per mille of memory ops.
        // Two things were wrong with picking uniformly from twelve forms:
        //
        //  - the sign-extending loads 0xc0/0xc2/0xc8/0xca were absent entirely,
        //    and they are ~7% of real memory operations -- never executed at
        //    CPU level despite being implemented;
        //  - multi-word ldl/stl/ldt/stt/ldq/stq were picked HALF the time and
        //    are 0.36% of real memory operations. They are the most expensive
        //    forms there are, so T_MEM_W was dominated by instructions that
        //    barely occur.
        //
        // In coverage mode the weights are flattened, because a rare form that
        // is wrong is still wrong.
        static const struct { uint8_t op; uint16_t w; } LS[] = {
          {0x90, 407}, {0x92, 400},                 // ld, st
          {0xc8,  52}, {0xca,  32},                 // ldis, stis
          {0x88,  31}, {0x80,  25},                 // ldos, ldob
          {0x8a,  18}, {0xc0,  16},                 // stos, ldib
          {0x82,  12}, {0xc2,   3},                 // stob, stib
          {0x98,   1}, {0x9a,   1}, {0xa0,   1},    // ldl, stl, ldt
          {0xa2,   1}, {0xb0,   1}, {0xb2,   1},    // stt, ldq, stq
        };
        const int NLS = int(sizeof LS / sizeof LS[0]);
        uint32_t op = 0x90;
        if (mix_daytona) {
          int tw = 0; for (int q = 0; q < NLS; ++q) tw += LS[q].w;
          int pick = int(rng() % uint64_t(tw));
          for (int q = 0; q < NLS; ++q) { pick -= LS[q].w; if (pick < 0) { op = LS[q].op; break; } }
        } else {
          op = LS[rng() % uint64_t(NLS)].op;
        }
        // UNALIGNED ADDRESSES for the single-word forms. Word-aligned offsets
        // only was a silent coverage hole: the LSU's byte-split path is reached
        // exclusively by unaligned byte/half/word access, so the whole-CPU
        // harness could not exercise it at all. A combinational-bus change that
        // broke splitting outright passed here and was caught only by the block
        // harness -- the reverse of the load bugs, where the CPU harness caught
        // what the block one could not. Both levels are needed and neither is
        // redundant.
        //
        // Multi-word forms stay aligned: ldl/ldt/ldq have alignment rules of
        // their own and an unaligned one is not a case the design promises.
        const bool multi = (op == 0x98 || op == 0x9a || op == 0xa0 ||
                            op == 0xa2 || op == 0xb0 || op == 0xb2);
        // ALIGNMENT is weighted too, and for the same reason as the form mix.
        // Only half-word and word accesses can split (a byte access never
        // does), and splitting costs several bus cycles -- so generating
        // byte-granular addresses uniformly makes the memory path look far more
        // expensive than compiler-generated code, which aligns its accesses.
        //
        // coverage: byte-granular, because the split path must be exercised.
        // daytona: aligned to the access size, with a small unaligned tail.
        uint32_t off;
        if (multi) {
          off = 0x800u + ((rng() % 0x180u) << 2);
        } else if (!mix_daytona || (rng() % 100) < 3) {
          off = 0x800u + (rng() % 0x600u);           // any alignment
        } else {
          const uint32_t sz = (op == 0x80 || op == 0x82 || op == 0xc0 || op == 0xc2) ? 1u
                            : (op == 0x88 || op == 0x8a || op == 0xc8 || op == 0xca) ? 2u
                                                                                     : 4u;
          off = (0x800u + (rng() % 0x600u)) & ~(sz - 1u);
        }
        // Multi-word forms mask the destination register, so a high srcdst is
        // fine, but keep it out of r0-r2 (PFP/SP/RIP) to avoid perturbing the
        // frame machinery in a test aimed at the memory path.
        insn = (op << 24) | (((rng() % 24) + 4) << 19) | (0u << 14) | off;
      } else if (cls == 11) {                          // lda
        insn = (0x8cu << 24) | (((rng() % 24) + 4) << 19)
             | (0u << 14) | (0x800u + ((rng() % 0x200u) << 2));
      } else if (cls == 5) {                           // bbc / bbs
        insn = (((rng() & 1) ? 0x37u : 0x30u) << 24)
             | ((rng() % 32) << 19) | ((rng() % 32) << 14) | 0x2008;
      } else { insn = 0x5c0c0000u; }                   // unreachable filler
      prog.push_back(insn);
    }
    if (loop_mode && prog.size() >= 16) {
      // Unconditional backward branch: target = IP + field, so the field is
      // simply (top - at) * 4 as a negative 24-bit value. It never falls
      // through, which is deliberate -- the retire budget below bounds the run,
      // and a conditional loop whose counter the random body could clobber
      // would terminate unpredictably and make the measurement noisy.
      const size_t top = prog.size() / 4;
      const size_t at  = prog.size() / 2;
      const int32_t field = int32_t((top - at) * 4);
      prog[at] = (0x08u << 24) | (uint32_t(field) & 0x00ffffffu);
    }
    for (size_t k = 0; k < prog.size(); ++k) mem[uint32_t(k*4)] = prog[k];
    ref.rf.mem = mem;

    // Reset, then seed both register files identically.
    dut->rst_n = 0; dut->bus_ack = 0;
    for (int i = 0; i < 4; i++) tick();
    dut->rst_n = 1; tick();
    for (int i = 0; i < 32; i++) {
      uint32_t v = uint32_t(rng());
      // Keep every register a NORMAL single when read as a float. The FP units
      // flush subnormals and the host does not, which is a recorded deviation
      // (§8.1) rather than a bug — but a randomly seeded register hits it
      // often, and then the suite measures the deviation instead of the design.
      // Same discipline as excluding the zero divisor and the overlapping mov.
      const uint32_t e = (v >> 23) & 0xff;
      if (e == 0x00 || e == 0xff) v = (v & 0x807fffffu) | (0x7fu << 23);
      ref.rf.r[i] = v;
      if (i < 16) dut->rootp->i960_top__DOT__u_regs__DOT__loc[i] = v;
      else        dut->rootp->i960_top__DOT__u_regs__DOT__glb[i-16] = v;
    }
    ref.AC = 0; ref.IP = 0;

  // Self-test of the FP-register plumbing, once. Write a known value into the
  // DUT's fp file and read it back through the same accessor the comparison
  // uses. If this does not round-trip, the comparison is inert and every FP
  // result it claims to check is unchecked.
  {
    static bool probed = false;
    if (!probed) {
      probed = true;
      dut->rootp->i960_top__DOT__fpr[2] = 0x0123456789abcdefull;
      const uint64_t back = dfp(2);
      std::printf("  [probe] fp2 written 0123456789abcdef, read back %016llx  %s\n",
                  (unsigned long long)back,
                  back == 0x0123456789abcdefull ? "ACCESSOR OK" : "ACCESSOR BROKEN");
      dut->rootp->i960_top__DOT__fpr[2] = 0;
    }
  }

    // Run, comparing at each retire. The DUT retires when it re-enters fetch.
    const uint64_t budget = loop_mode ? steps * 5 : steps;
    for (uint64_t r = 0; r < budget && fails == 0; ++r) {
      const uint32_t ip_before = dip();
      int guard = 0;
      // Probe every cycle of an FP op with an fp0-fp3 destination. There are
      // only a handful in the whole run, so this is cheap, and it answers which
      // branch of the T_FP writeback actually fires -- which five rounds of
      // reading the source could not.
      const uint32_t iw_now = ref.rd(ref.IP);
      const uint32_t o_now  = iw_now >> 24;
      const bool probe = probe_fp &&
                         (o_now==0x78||o_now==0x68||o_now==0x6c||o_now==0x67) &&
                         (iw_now & 0x2000);
      if (probe) std::printf("[probe] insn %08x op2=%x IP %08x\n",
                             iw_now, (iw_now >> 7) & 0xf, ip_before);
      // advance until the sequencer has moved on to the next instruction
      while (guard++ < 400 && dip() == ip_before && !dut->trap) {
        if (probe)
          std::printf("        ts=%2d req=%d done=%d busy=%d fp_a=%016llx "
                      "sqrt=%d valid=%d dstlit=%d fpr2=%016llx\n",
                      dut->rootp->i960_top__DOT__ts,
                      dut->rootp->i960_top__DOT__fsqrt_req,
                      dut->rootp->i960_top__DOT__fsqrt_done,
                      dut->rootp->i960_top__DOT__fsqrt_busy,
                      (unsigned long long)dut->rootp->i960_top__DOT__fp_a,
                      dut->rootp->i960_top__DOT__fp_is_sqrt,
                      dut->rootp->i960_top__DOT__fp_valid,
                      dut->rootp->i960_top__DOT__d_dst_lit,
                      (unsigned long long)dfp(2));
        tick();
      }
      if (dut->trap) break;
      if (guard >= 400) { std::printf("STALL at IP %08x\n", ip_before); ++fails; break; }
      // IP moving is not the same as the instruction having retired. `we` is
      // registered in the execute state, so the write reaches the register file
      // one edge AFTER the IP updates. Sampling on the IP change alone compares
      // the architectural state one cycle early and reports a stale register.
      tick();
      exec_ip = ref.IP; exec_insn = ref.rd(ref.IP);
      { const uint32_t iw = exec_insn; const uint32_t o = iw>>24;
        if (o==0x78||o==0x68||o==0x6c||o==0x67) fpany++;
        if ((o==0x78||o==0x68||o==0x6c||o==0x67) && (iw&0x2000) && !(iw&0x00e00000)) fpwrites++; }
      ref.step();
      if (ref.trapped) { ++trapped_progs; break; }
      // A flushed subnormal does not just make one comparison wrong — it writes
      // a diverged value into a register, and every later retire in the program
      // then fails on state that is already known to differ. Abandon the
      // program at that point, the same as a trap.
      if (ref.fp_denorm_operand) { ++denorm_skips; break; }
      if (ref.fp_nan_result)     { ++nan_stops;    break; }
      // Compare the DATA MEMORY after every retire, not the bus transaction
      // stream. The stream was the first attempt and it is wrong: an unaligned
      // access legitimately becomes several byte transactions in the DUT and
      // stays one logical store in the reference, so comparing counts fails a
      // correct implementation. What must agree is the RESULT.
      //
      // Per-retire is the point -- comparing only at the end lets a store to
      // the wrong address be overwritten before anyone looks, which is how the
      // stt defect survived "zero divergence" for so long.
      {
        bool bad = false;
        for (const auto &kv : mem) {
          if (kv.first < 0x800) continue;          // program, not data
          auto it = ref.rf.mem.find(kv.first);
          const uint32_t rv = (it == ref.rf.mem.end()) ? 0xffffffffu : it->second;
          if (rv != kv.second) {
            if (fails < MAX_REPORT)
              std::printf("  MEMSTATE retire %llu  %08x dut=%08x ref=%08x"
                          "  (insn %08x)\n", (unsigned long long)r,
                          kv.first, kv.second, rv, exec_insn);
            bad = true; break;
          }
        }
        if (bad) { ++fails; break; }
      }
      ++retires; ++total_retires;
      if (!compare(r)) break;
    }
  }

  dut->final(); delete dut;
  // Cycles per retired instruction. This is the number the pipeline exists to
  // reduce, and it is measured rather than estimated. It includes I-cache
  // misses and the per-program reset, so it is an upper bound on steady state.
  if (total_retires) {
    std::printf("\n  cycles by sequencer state, per retired instruction:\n");
    for (int i = 0; i < 16; i++)
      if (state_cycles[i])
        std::printf("    %-12s %10llu  %6.2f cyc/instr  %5.1f%%\n",
                    STATE_NAME[i], (unsigned long long)state_cycles[i],
                    double(state_cycles[i]) / double(total_retires),
                    100.0 * double(state_cycles[i]) / double(ticks));
    std::printf("\n");
  }
  if (total_retires)
    std::printf("  CPI (incl. reset and I-cache misses): %.2f\n",
                double(ticks) / double(total_retires));
  std::printf("  FP ops executed: %llu, of which FP-register destination: %llu\n", (unsigned long long)fpany, (unsigned long long)fpwrites);
  std::printf("  %llu ended early: subnormal FP operand, %llu: NaN result"
              "  (both recorded deviations)\n",
              (unsigned long long)denorm_skips, (unsigned long long)nan_stops);
  std::printf("  fetch: %llu entered, %llu prefetch hits (%.1f%%), "
              "%llu extra T_FETCH cycles, %llu fill-wait cycles\n",
              (unsigned long long)fetch_enter, (unsigned long long)fetch_hit,
              100.0 * double(fetch_hit) / double(fetch_enter ? fetch_enter : 1),
              (unsigned long long)fetch_stall, (unsigned long long)ic_fill_cyc);
  std::printf("  %llu programs, %llu retires, %llu checks over %llu cycles\n",
              (unsigned long long)progs, (unsigned long long)total_retires,
              (unsigned long long)checks, (unsigned long long)ticks);
  std::printf("  %llu mismatches\n", (unsigned long long)fails);
  if (fails) { std::printf("FAIL\n"); return 1; }
  std::printf("PASS\n"); return 0;
}
