// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// tb_tgp_replay -- replay a captured Daytona race workload through m2_copro
// and check every word the TGP produces, bit for bit, against MAME.
//
// THE CAPTURE (tools: sim/tgp/tgp_capture.lua, run inside MAME 0.289):
//   state.txt   TGP architectural state at the snapshot (MAME state names)
//   dram.bin    TGP data RAM 0x000-0x3ff        prog.bin  program RAM 0x000-0xfff
//   tables.bin  :copro_tgp_tables (64K words)    cdata.bin :copro_data (2M words)
//   events.bin[.gz]  9-byte records <u8 type, u32 a, u32 b>, in emulation order:
//     F frame boundary (a = frame, b = 1 at end of window)
//     N function-port push (a = i960 byte address, b = data)
//     I FIFO-port push (b = data)        H FIFO-port push, 16-bit store
//     X i960 popped an output (a = index, b = value)
//     O TGP pushed an output  (a = index, b = value)
//     P TGP popped an input   (a = index, b = value)   S TGP stalled pop
//     R TGP io read   (a = io_addr | bank[23:16]<<16 | view_on<<24, b = data)
//     W TGP io write  (same tag, b = data)             B rf 3 (bank) write
//
// THE i960 MODEL. The bench is the i960, infinitely fast but causally exact:
// it walks N/I/H/X in capture order, pushing as fast as m2_copro's input FIFO
// accepts, and on an X it READS the output FIFO and is held by `stall` until
// a word is there -- the same synchronous push-push-pop protocol the game
// uses. So the TGP's waits for input are only the causal ones (a command that
// depends on a previous answer), and the i960's waits on X are the analogue of
// the board's copro_stall with zero i960 compute time.
//
// THE SNAPSHOT. MAME's TGP was parked at a stalled input-FIFO pop with the
// FIFO empty. The bench uploads the program through the real upload path,
// pokes the data RAM, boots the coprocessor, and on the first cycle the core
// leaves reset pokes every architectural register (incl. PC, PC stack, loop
// counters, ST, M, the bank register and the math-unit bases).
//
// CHECKS: every TGP output word (O) and every i960 pop (X) against MAME; every
// input pop (P); every io read (address/bank tag and returned data: math units
// and data ROM come from the RTL + dumped ROMs, so this checks them) and every
// io write (math-unit bases and buffer-RAM writes). Buffer-RAM READS, if a
// capture has any, are served from the R record (the i960 owns that RAM).
//
// MISMATCH CLASSES: see mclass() -- NaN-vs-NaN differences (x86 host NaN
// encoding in MAME) are reported but do not fail the run without --strict-nan.
//
// Usage: Vm2_copro <capture-dir> [--lat N] [--wlat N] [--frames N]
//          [--max-mism N] [--only KIND] [--profile N] [--quiet] [--strict-nan]
//          [--dump-rtl FILE] [--vs-rtl FILE]
//   --lat/--wlat   table+data-ROM read latency / buffer-RAM write ack (cycles, default 6)
//   --frames N     replay only the first N frames
//   --halfword-replicate  feed 16-bit FIFO stores as this core's i960 drives them
//   --dump-rtl     write the RTL's own outputs + io writes; --vs-rtl compares
//                  against such a file, for exact regression of a faster RTL
//                  against this one where MAME and the RTL legitimately differ

#include "Vm2_copro.h"
#include "Vm2_copro___024root.h"
#include "verilated.h"
#include <zlib.h>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <map>
#include <algorithm>
#include <fstream>
#include <sstream>

#define R(x) (top->rootp->m2_copro__DOT__##x)
#define TGP(x) R(u_tgp__DOT__##x)
#define CORE(x) TGP(core__DOT__##x)
#define SEQ(x) CORE(u_seq__DOT__##x)
#define REGS(x) CORE(u_regs__DOT__##x)

struct Ev { uint8_t t; uint32_t a, b; };

// Plain or gzip (gzopen reads either; "<p>.gz" is tried first).
static std::vector<uint32_t> load_words(const std::string &p, size_t want = 0) {
  std::vector<uint32_t> v;
  gzFile g = gzopen((p + ".gz").c_str(), "rb");
  if (!g) g = gzopen(p.c_str(), "rb");
  if (!g) { std::fprintf(stderr, "cannot open %s[.gz]\n", p.c_str()); std::exit(2); }
  uint32_t w;
  while (gzread(g, &w, 4) == 4) v.push_back(w);
  gzclose(g);
  if (want && v.size() != want) {
    std::fprintf(stderr, "%s: %zu words, expected %zu\n", p.c_str(), v.size(), want);
    std::exit(2);
  }
  return v;
}

static std::vector<Ev> load_events(const std::string &dir) {
  std::string p = dir + "/events.bin.gz";
  gzFile g = gzopen(p.c_str(), "rb");
  if (!g) { p = dir + "/events.bin"; g = gzopen(p.c_str(), "rb"); }
  if (!g) { std::fprintf(stderr, "no events.bin[.gz] in %s\n", dir.c_str()); std::exit(2); }
  std::vector<Ev> v;
  unsigned char rec[9];
  while (gzread(g, rec, 9) == 9) {
    Ev e; e.t = rec[0];
    std::memcpy(&e.a, rec + 1, 4); std::memcpy(&e.b, rec + 5, 4);
    v.push_back(e);
  }
  gzclose(g);
  return v;
}

static std::map<std::string, uint32_t> load_state(const std::string &p) {
  std::map<std::string, uint32_t> m;
  std::ifstream f(p);
  if (!f) { std::fprintf(stderr, "cannot open %s\n", p.c_str()); std::exit(2); }
  std::string k, v;
  while (f >> k >> v) m[k] = (k == "frame") ? std::stoul(v, nullptr, 10) : std::stoul(v, nullptr, 16);
  return m;
}

// ---------------------------------------------------------------- naming
static const char *STATE_NAMES[16] = {
  "S_FETCH", "S_FETCH_W", "S_DECODE", "S_SRC", "S_SRC_W", "S_LABB", "S_LABB_W",
  "S_DST", "S_DST_W", "S_ALU", "S_RETIRE", "S_BRUL_RD", "S_BRUL_W",
  "S_LAB_WA", "S_LAB_WB", "?15" };
enum { S_FETCH, S_FETCH_W, S_DECODE, S_SRC, S_SRC_W, S_LABB, S_LABB_W, S_DST,
       S_DST_W, S_ALU, S_RETIRE, S_BRUL_RD, S_BRUL_W, S_LAB_WA, S_LAB_WB };

static const char *alu_name(unsigned op) {
  static const char *n[32] = {
    "nop", "andd", "orad", "eord", "notd", "fcpd", "fadd", "fsbd",
    "fml", "fmsd", "fmrd", "fabd", "fsmd", "fspd", "cxfd", "cfxd",
    "fdvd", "fned", "alu12", "bapa", "bspa", "alu15", "lsrd", "lsld",
    "asrd", "asld", "addd", "subd", "alu1c", "alu1d", "alu1e", "alu1f" };
  return n[op & 31];
}
static const char *sp_name(unsigned s) {   // mb86233_pkg EP_*: none, data, io, prog
  static const char *n[4] = { "none", "data", "io", "prog" };
  return n[s & 3];
}

struct Stat { uint64_t n = 0, cyc = 0; };

// MISMATCH CLASSES. MAME's TGP is host float arithmetic, so a NaN it produces
// carries x86 SSE's encoding: the default NaN is 0xffc00000 (sign set) and an
// input NaN's payload propagates. Neither is a fact about the MB86234. A
// difference where BOTH sides are NaN is counted as "nan-encoding" and does
// not fail the run unless --strict-nan; every other difference does, including
// +0 / -0, which is a real arithmetic difference.
static bool is_nan(uint32_t v) { return (v & 0x7f800000u) == 0x7f800000u && (v & 0x007fffffu); }
enum { MK_NAN, MK_ZERO, MK_OTHER };
static int mclass(uint32_t want, uint32_t got) {
  if (is_nan(want) && is_nan(got)) return MK_NAN;
  if (((want | got) & 0x7fffffffu) == 0) return MK_ZERO;
  return MK_OTHER;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s <capture-dir> [--lat N] [--wlat N] [--frames N] "
                         "[--max-mism N] [--quiet] [--profile N]\n", argv[0]);
    return 2;
  }
  std::string dir = argv[1];
  int lat = 6, wlat = 6, max_frames = 1 << 30, max_mism = 20, profile_n = 25;
  bool quiet = false, strict_nan = false;
  // --halfword-replicate: feed a 16-bit FIFO store ('H') the way this core's
  // i960 presents it -- i960_lsu drives {2{st_word[15:0]}} and m2_copro takes
  // wdata whole -- instead of MAME's zero-extended word. An experiment switch.
  bool hw_rep = false;
  std::string only;   // print only mismatches whose kind contains this
  std::string dump_rtl, vs_rtl;   // RTL result stream: write it / compare against it
  for (int i = 2; i < argc; ++i) {
    std::string a = argv[i];
    auto nxt = [&]() { return (i + 1 < argc) ? std::atoi(argv[++i]) : 0; };
    if (a == "--lat") lat = nxt();
    else if (a == "--wlat") wlat = nxt();
    else if (a == "--frames") max_frames = nxt();
    else if (a == "--max-mism") max_mism = nxt();
    else if (a == "--profile") profile_n = nxt();
    else if (a == "--quiet") quiet = true;
    else if (a == "--strict-nan") strict_nan = true;
    else if (a == "--halfword-replicate") hw_rep = true;
    else if (a == "--only" && i + 1 < argc) only = argv[++i];
    else if (a == "--dump-rtl" && i + 1 < argc) dump_rtl = argv[++i];
    else if (a == "--vs-rtl" && i + 1 < argc) vs_rtl = argv[++i];
  }
  if (lat < 1) lat = 1;
  if (wlat < 1) wlat = 1;

  // ------------------------------------------------------------ capture
  auto st = load_state(dir + "/state.txt");
  auto dram   = load_words(dir + "/dram.bin", 0x400);
  auto prog   = load_words(dir + "/prog.bin", 0x1000);
  auto tables = load_words(dir + "/tables.bin", 0x10000);
  auto cdata  = load_words(dir + "/cdata.bin", 0x200000);
  auto ev     = load_events(dir);

  // Split: what the i960 does (feed) and what the TGP must do (expect).
  std::vector<Ev> feed;                       // N I H X F
  std::vector<uint32_t> exp_out, exp_pop, exp_xpop;
  std::vector<Ev> exp_rd, exp_wr;
  std::vector<uint64_t> frame_in_start;       // input index at each frame start
  std::vector<uint32_t> frame_no;
  uint64_t nin = 0;
  int nframes_seen = 0;
  for (auto &e : ev) {
    switch (e.t) {
      case 'F':
        if (e.b == 1) break;                  // end-of-window marker
        if (nframes_seen >= max_frames) goto split_done;
        ++nframes_seen;
        frame_in_start.push_back(nin); frame_no.push_back(e.a);
        feed.push_back(e);
        break;
      case 'N': case 'I': case 'H': feed.push_back(e); ++nin; break;
      case 'X': feed.push_back(e); exp_xpop.push_back(e.b); break;
      case 'O': exp_out.push_back(e.b); break;
      case 'P': exp_pop.push_back(e.b); break;
      case 'R': exp_rd.push_back(e); break;
      case 'W': exp_wr.push_back(e); break;
      default: break;
    }
  }
split_done:
  // With --frames the window is cut at a frame marker, which is not
  // necessarily quiescent; the expectation streams are only checked as far as
  // the RTL gets, and the run ends when the TGP parks with the feed exhausted.
  const uint64_t n_inputs = nin;
  const unsigned NF = frame_in_start.size();
  std::printf("capture %s: snapshot frame %u pc %03x, %u frames, %llu inputs, %zu outputs, "
              "%zu io reads, %zu io writes\n",
              dir.c_str(), st["frame"], st["GENPC"], NF, (unsigned long long)n_inputs,
              exp_out.size(), exp_rd.size(), exp_wr.size());
  std::printf("memory model: table/data-ROM read latency %d cycles, buffer-RAM write ack %d cycles\n",
              lat, wlat);

  // --------------------------------------------------------------- DUT
  Vm2_copro *top = new Vm2_copro;
  uint64_t cyc = 0;
  auto clear_bus = [&]() {
    top->sel_ctl = 0; top->sel_fifo = 0; top->sel_fn = 0; top->sel_fifoctl = 0;
    top->we = 0; top->wdata = 0; top->fn_code = 0;
  };
  // One clock: inputs are already set; settle, then rising edge.
  auto tick = [&]() {
    top->clk = 0; top->eval();
    top->clk = 1; top->eval();
    ++cyc;
  };

  clear_bus();
  top->tbl_ack = 0; top->dat_ack = 0; top->bufw_ack = 0;
  top->tbl_rdata = 0; top->dat_rdata = 0;
  top->rst_n = 0; top->clk = 0; top->eval();
  for (int i = 0; i < 4; ++i) tick();
  top->rst_n = 1;
  tick();

  // ---- program upload through the real path: ctl bit 31 up, words, bit 31 down
  const unsigned nup = st.count("UPLOAD_WORDS") ? st["UPLOAD_WORDS"] : 2048;
  clear_bus(); top->sel_ctl = 1; top->we = 1; top->wdata = 0x80000000u; tick();
  for (unsigned i = 0; i < nup && i < 2048; ++i) {
    clear_bus(); top->sel_fifo = 1; top->we = 1; top->wdata = prog[i]; tick();
  }
  clear_bus(); tick();
  for (unsigned i = nup; i < 0x1000; ++i)
    if (prog[i]) { std::printf("NOTE: program RAM word %03x = %08x beyond the upload (not loaded)\n", i, prog[i]); break; }

  // ---- data RAM: MAME's AS_DATA 0x000-0x0ff and 0x200-0x3ff
  for (int i = 0; i < 256; ++i) CORE(u_mem__DOT__ram0)[i] = dram[i];
  for (int i = 0; i < 512; ++i) CORE(u_mem__DOT__ram1)[i] = dram[0x200 + i];

  // ---- boot: bit 31 down releases `halted`
  clear_bus(); top->sel_ctl = 1; top->we = 1; top->wdata = 0; tick();
  clear_bus();
  uint64_t boot_cyc = 0;
  while (!(TGP(sw_done) && TGP(rel_done))) {
    tick();
    if (++boot_cyc > 100000) { std::printf("FAIL: core never left reset\n"); return 1; }
  }
  // The core's reset is released now and its first edge is the next one:
  // state is S_FETCH and the fetch at the next edge reads prog[pc].
  {
    SEQ(pc) = st["GENPC"];
    SEQ(c0) = st["C0"]; SEQ(c1) = st["C1"]; SEQ(rep) = st["R"];
    const uint32_t f = st["CURFLAGS"];
    SEQ(zc0) = (f >> 30) & 1; SEQ(zc1) = (f >> 31) & 1;
    CORE(st_hold) = f & 0x3fffffffu;
    for (int i = 0; i < 4; ++i) SEQ(pcs)[i] = st["PCS" + std::to_string(i)];
    REGS(reg_a) = st["A"]; REGS(reg_b) = st["B"]; REGS(reg_d) = st["D"]; REGS(reg_p) = st["P"];
    REGS(b0) = st["B0"]; REGS(b1) = st["B1"]; REGS(x0) = st["X0"]; REGS(x1) = st["X1"];
    REGS(i0) = st["I0"]; REGS(i1) = st["I1"]; REGS(sp) = st["SP"]; REGS(mask) = st["MASK"];
    REGS(sft) = st["SFT"]; REGS(rpc) = st["RPC"];
    REGS(vsm) = st["VSM"] & 7; REGS(vsmr) = (8u << (st["VSM"] & 7)) - 1;
    REGS(rf)[3] = st["BANK"];
    CORE(reg_m) = st["M"];
    TGP(sincos_base) = st["SINCOS"]; TGP(inv_base) = st["INV"]; TGP(isqrt_base) = st["ISQRT"];
    for (int i = 0; i < 4; ++i) TGP(atan_base)[i] = st["ATAN" + std::to_string(i)];
    if (CORE(state) != S_FETCH) { std::printf("FAIL: core not in S_FETCH at release\n"); return 1; }
  }
  if (!quiet) std::printf("boot: %llu cycles to core release (program sweep + release delay), state poked\n",
                          (unsigned long long)boot_cyc);

  // ------------------------------------------------------------ run
  size_t fp = 0;                          // feed pointer
  size_t oi = 0, pi = 0, ri = 0, wi = 0, xi = 0;
  uint64_t mism_out = 0, mism_x = 0, mism_pop = 0, mism_rd = 0, mism_wr = 0, mism_rdaddr = 0, mism_wraddr = 0;
  uint64_t extra_out = 0, extra_rd = 0, extra_wr = 0;
  int printed = 0;
  struct RingE { unsigned pc; uint32_t ir, a, b, d, p; uint64_t cyc; };
  RingE ring[32] = {};
  uint64_t ring_i = 0;
  int ring_dumps = 3;
  uint64_t mclass_n[3] = {0, 0, 0};
  auto report = [&](const char *what, size_t idx, uint32_t want, uint32_t got, const char *extra) {
    if (std::strstr(what, "addr") == nullptr) mclass_n[mclass(want, got)]++;
    else mclass_n[MK_OTHER]++;
    if (!only.empty() && std::strstr(what, only.c_str()) == nullptr) return;
    if (printed < max_mism) {
      ++printed;
      std::printf("MISMATCH %s #%zu: mame %08x rtl %08x  pc %04x ir %08x  cyc %llu  %s\n",
                  what, idx, want, got, (unsigned)SEQ(pc), (unsigned)CORE(ir),
                  (unsigned long long)cyc, extra ? extra : "");
      if (printed <= ring_dumps) {
        std::printf("  last retired (pc, op, then A B D P as the op retired -- its own D/P land later):\n");
        for (uint64_t j = (ring_i > 12 ? ring_i - 12 : 0); j < ring_i; ++j) {
          const RingE &r = ring[j & 31];
          std::printf("    %03x %08x  a %08x b %08x d %08x p %08x\n", r.pc, r.ir, r.a, r.b, r.d, r.p);
        }
      }
    }
  };

  // The RTL's own results, for regression against an earlier RTL (--dump-rtl /
  // --vs-rtl): every output word (type 'O') and io write (type 'W', tag+data).
  std::vector<uint32_t> rtl_stream, rtl_ref;
  if (!vs_rtl.empty()) {
    rtl_ref = load_words(vs_rtl);
    std::printf("regression reference: %s, %zu words\n", vs_rtl.c_str(), rtl_ref.size());
  }
  uint64_t ldif_taken = 0;
  // memory model state
  int tbl_left = -1, dat_left = -1, bw_left = -1;
  uint32_t dat_val = 0;
  uint64_t buf_reads = 0, unimpl_cyc = 0;

  // statistics
  const uint64_t run_start = cyc;
  uint64_t state_cyc[16] = {0};
  uint64_t fifo_empty_cyc = 0, fout_full_cyc = 0;
  uint64_t io_wait_cyc[4] = {0};          // math, rom, buf-read, buf-write
  uint64_t datamem_wait_cyc = 0;
  uint64_t feed_x_block = 0, feed_full_block = 0;
  uint64_t retired = 0;
  // per frame (TGP side, by input index popped)
  std::vector<uint64_t> f_cyc(NF + 1, 0), f_ret(NF + 1, 0), f_empty(NF + 1, 0), f_xblk(NF + 1, 0);
  std::vector<uint64_t> f_out(NF + 1, 0);
  unsigned cur_frame = 0;                 // TGP-side frame (by pops)
  unsigned feed_frame = 0;
  uint64_t popped = 0;
  // per instruction
  uint64_t ins_start = cyc;
  std::vector<Stat> cls(1 << 14);
  std::map<std::string, Stat> alu_ops;
  uint64_t alu_wait_by_op[32] = {0}, alu_n_by_op[32] = {0};
  std::vector<uint64_t> pc_cyc(4096, 0), pc_n(4096, 0);
  uint64_t rep_iter = 0;
  uint64_t last_retire_cyc = cyc;
  bool end_ok = false;

  while (true) {
    // ---------------- i960 side: drive this cycle's access
    clear_bus();
    bool feed_xread = false, feed_write = false;
    while (fp < feed.size() && feed[fp].t == 'F') { ++fp; ++feed_frame; }
    if (fp < feed.size()) {
      const Ev &e = feed[fp];
      if (e.t == 'X') {
        top->sel_fifo = 1; top->we = 0; feed_xread = true;
      } else if (!R(fin_full)) {
        feed_write = true;
        top->we = 1; top->wdata = (hw_rep && e.t == 'H') ? ((e.b & 0xffffu) * 0x10001u) : e.b;
        if (e.t == 'N') { top->sel_fn = 1; top->fn_code = (e.a >> 4) & 0xff; }
        else            { top->sel_fifo = 1; }
      } else {
        ++feed_full_block;
      }
    }

    // ---------------- memory side: acknowledges due this cycle
    top->tbl_ack = 0; top->dat_ack = 0; top->bufw_ack = 0;
    if (tbl_left == 0) { top->tbl_ack = 1; tbl_left = -1; }
    else if (tbl_left > 0) --tbl_left;
    if (dat_left == 0) { top->dat_ack = 1; top->dat_rdata = dat_val; dat_left = -1; }
    else if (dat_left > 0) --dat_left;
    if (bw_left == 0) { top->bufw_ack = 1; bw_left = -1; }
    else if (bw_left > 0) --bw_left;

    top->clk = 0; top->eval();

    // ---------------- observe the settled cycle
    const unsigned s = CORE(state);
    state_cyc[s]++;
    const bool io_rd = TGP(io_rd), io_wr = TGP(io_wr), io_ack = TGP(io_ack);
    if (s == S_SRC && CORE(src_fifo_q) && !CORE(fifo_ack)) { ++fifo_empty_cyc; ++f_empty[cur_frame]; }
    if ((io_rd || io_wr) && !io_ack) {
      if (TGP(sel_math)) io_wait_cyc[0]++;
      else if (TGP(sel_rom)) io_wait_cyc[1]++;
      else if (TGP(sel_buf)) io_wait_cyc[io_wr ? 3 : 2]++;
    }
    if ((s == S_SRC_W || s == S_LABB_W || s == S_DST_W) && CORE(mem_stall)) datamem_wait_cyc++;
    if (TGP(fifo_out_push) == 0 && TGP(fifo_wr) && R(fout_full)) fout_full_cyc++;
    f_cyc[cur_frame]++;
    if (TGP(dbg_unimplemented)) ++unimpl_cyc;

    // i960 pop of an output
    if (feed_xread) {
      if (!top->stall) {
        const uint32_t got = top->rdata;
        if (xi < exp_xpop.size() && got != exp_xpop[xi]) { ++mism_x; report("i960-pop", xi, exp_xpop[xi], got, ""); }
        ++xi; ++fp;
      } else { ++feed_x_block; ++f_xblk[cur_frame]; }
    } else if (feed_write) {
      ++fp;
    }

    // TGP input pop
    if (TGP(fifo_in_pop)) {
      const uint32_t got = TGP(fifo_in_data);
      if (pi < exp_pop.size() && got != exp_pop[pi]) { ++mism_pop; report("tgp-pop", pi, exp_pop[pi], got, ""); }
      ++pi; ++popped;
      while (cur_frame + 1 < NF && popped > frame_in_start[cur_frame + 1]) ++cur_frame;
    }
    // TGP output push
    if (TGP(fifo_out_push)) {
      const uint32_t got = TGP(fifo_out_data);
      if (oi < exp_out.size()) {
        if (got != exp_out[oi]) { ++mism_out; report("tgp-out", oi, exp_out[oi], got, ""); }
      } else ++extra_out;
      ++oi; f_out[cur_frame]++;
      rtl_stream.push_back('O'); rtl_stream.push_back(got);
    }
    // io accesses complete on (io_rd|io_wr) && io_ack
    if ((io_rd || io_wr) && io_ack) {
      const uint32_t bank = TGP(bank_reg);
      const uint32_t on = (bank & 0xc00000u) ? 1u : 0u;
      const uint32_t tag = (TGP(io_addr) & 0xffffu) | (((bank >> 16) & 0xffu) << 16) | (on << 24);
      char ctx[96];
      if (io_rd) {
        const uint32_t got = TGP(io_rdata);
        if (ri < exp_rd.size()) {
          std::snprintf(ctx, sizeof ctx, "io-read tag mame %08x rtl %08x", exp_rd[ri].a, tag);
          if (exp_rd[ri].a != tag) { ++mism_rdaddr; report("io-read-addr", ri, exp_rd[ri].a, tag, ctx); }
          else if (exp_rd[ri].b != got) { ++mism_rd; report("io-read-data", ri, exp_rd[ri].b, got, ctx); }
        } else ++extra_rd;
        ++ri;
      } else {
        const uint32_t got = TGP(io_wdata);
        if (wi < exp_wr.size()) {
          std::snprintf(ctx, sizeof ctx, "io-write tag mame %08x rtl %08x", exp_wr[wi].a, tag);
          if (exp_wr[wi].a != tag) { ++mism_wraddr; report("io-write-addr", wi, exp_wr[wi].a, tag, ctx); }
          else if (exp_wr[wi].b != got) { ++mism_wr; report("io-write-data", wi, exp_wr[wi].b, got, ctx); }
        } else ++extra_wr;
        ++wi;
        rtl_stream.push_back('W'); rtl_stream.push_back(tag); rtl_stream.push_back(got);
      }
    }

    // instruction accounting at retire (decode registers still hold it)
    if (CORE(ret_now)) {   // R773: retire is no longer one state
      ++retired; f_ret[cur_frame]++;
      const uint64_t c = cyc - ins_start + 1;
      const unsigned ipc = SEQ(pc) & 0xfff;
      pc_cyc[ipc] += c; pc_n[ipc]++;
      // class key: group[13:11] alu[10:6] x[5:3] y[2:0]
      const unsigned alu = CORE(d_alu) & 31;
      unsigned key;
      if (CORE(d_branch)) {
        key = (0u << 11) | (CORE(d_bsub) & 7);
        if ((CORE(d_bsub) & 7) == 6 && CORE(seq_cond_passed)) ++ldif_taken;
      } else if (CORE(d_ldi))    key = (1u << 11);
      else if (CORE(d_lipl))   key = (2u << 11);
      else if (CORE(d_stm))    key = (3u << 11);
      else if (CORE(d_lab))    key = (4u << 11) | (alu << 6) | (CORE(x_lab_b_sp) & 3);
      else if (CORE(d_ldmov)) {
        const unsigned src = CORE(x_src_reg) ? (CORE(src_fifo_q) ? 5u : 4u) : (CORE(x_src_sp) & 3);
        const unsigned dst = CORE(x_dst_reg) ? 4u : (CORE(x_dst_sp) & 3);
        key = (5u << 11) | (alu << 6) | (src << 3) | dst;
      } else if (CORE(d_repgrp)) {
        key = (6u << 11) | (alu << 6) | (CORE(d_fsub) & 7);
        if ((CORE(d_fsub) & 7) == 2) ++rep_iter;
      } else key = (7u << 11);
      cls[key].n++; cls[key].cyc += c;
      ring[ring_i & 31] = {ipc, (uint32_t)CORE(ir), (uint32_t)REGS(reg_a), (uint32_t)REGS(reg_b),
                           (uint32_t)REGS(reg_d), (uint32_t)REGS(reg_p), cyc};
      ++ring_i;
      if (CORE(d_lab) || CORE(d_ldmov) || CORE(d_repgrp)) { alu_n_by_op[alu]++; }
      ins_start = cyc + 1;
      last_retire_cyc = cyc;
    }
    if (s == S_ALU && CORE(alu_active)) alu_wait_by_op[CORE(d_alu) & 31]++;

    // ---------------- rising edge
    top->clk = 1; top->eval();
    ++cyc;

    // ---------------- memory requests visible after the edge
    // A request is answered `lat` cycles after it first shows (min 1), with
    // the data looked up when it is accepted; the address is held until the
    // acknowledge because the core waits in its _W state.
    if (tbl_left < 0 && top->tbl_req && !top->tbl_ack) {
      tbl_left = lat - 1;
      top->tbl_rdata = tables[top->tbl_addr & 0xffff];
    }
    if (dat_left < 0 && top->dat_req && !top->dat_ack) {
      dat_left = lat - 1;
      if (top->dat_is_buf) {
        // The i960 owns buffer RAM: the value is MAME's, from the R record.
        ++buf_reads;
        dat_val = (ri < exp_rd.size()) ? exp_rd[ri].b : 0xffffffffu;
      } else {
        dat_val = cdata[top->dat_addr & 0x1fffff];
      }
    }
    if (bw_left < 0 && top->bufw_req && !top->bufw_ack) bw_left = wlat - 1;

    // ---------------- termination
    const bool feed_done = (fp >= feed.size());
    if (feed_done && pi >= exp_pop.size() && oi >= exp_out.size() && xi >= exp_xpop.size()
        && CORE(state) == S_SRC && CORE(src_fifo_q) && !CORE(fifo_ack)) {
      end_ok = true;
      break;
    }
    if (feed_done && max_frames < (1 << 30) && CORE(state) == S_SRC && CORE(src_fifo_q)
        && !CORE(fifo_ack) && !R(fin_valid)) {
      end_ok = true;  // truncated window: parked with nothing left to feed
      break;
    }
    if (cyc - last_retire_cyc > 2000000) {
      std::printf("FAIL: no retire for 2M cycles at pc %04x state %s io_rd %d io_wr %d fifo in %d out %d\n",
                  (unsigned)SEQ(pc), STATE_NAMES[CORE(state)], (int)TGP(io_rd), (int)TGP(io_wr),
                  (int)R(fin_valid), (int)R(fout_valid));
      break;
    }
  }
  const uint64_t run_cyc = cyc - run_start;

  // ------------------------------------------------------------ report
  std::printf("\n== RESULT\n");
  const bool counts_ok = (oi == exp_out.size() || max_frames < (1 << 30)) && extra_out == 0 && extra_rd == 0 && extra_wr == 0;
  const uint64_t total_mism = mism_out + mism_x + mism_pop + mism_rd + mism_wr + mism_rdaddr + mism_wraddr;
  std::printf("outputs   : %zu of %zu checked, %llu mismatched, %llu extra\n", std::min(oi, exp_out.size()),
              exp_out.size(), (unsigned long long)mism_out, (unsigned long long)extra_out);
  std::printf("i960 pops : %zu of %zu checked, %llu mismatched\n", xi, exp_xpop.size(), (unsigned long long)mism_x);
  std::printf("input pops: %zu of %zu, %llu mismatched; dropped by m2_copro: %u\n", pi, exp_pop.size(),
              (unsigned long long)mism_pop, (unsigned)top->dbg_in_dropped);
  std::printf("io reads  : %zu of %zu, %llu address/bank mismatches, %llu data mismatches, %llu extra\n",
              ri, exp_rd.size(), (unsigned long long)mism_rdaddr, (unsigned long long)mism_rd, (unsigned long long)extra_rd);
  std::printf("io writes : %zu of %zu, %llu address/bank mismatches, %llu data mismatches, %llu extra\n",
              wi, exp_wr.size(), (unsigned long long)mism_wraddr, (unsigned long long)mism_wr, (unsigned long long)extra_wr);
  std::printf("unimplemented-opcode flag: %llu cycles; buffer-RAM reads served from capture: %llu\n",
              (unsigned long long)unimpl_cyc, (unsigned long long)buf_reads);
  std::printf("mismatch classes: nan-encoding %llu, sign-of-zero %llu, other %llu\n",
              (unsigned long long)mclass_n[MK_NAN], (unsigned long long)mclass_n[MK_ZERO],
              (unsigned long long)mclass_n[MK_OTHER]);
  std::printf("ldif with condition true (the load MAME performs, mb86233.cpp case 6): %llu\n",
              (unsigned long long)ldif_taken);
  const uint64_t hard = strict_nan ? total_mism : total_mism - mclass_n[MK_NAN];
  const bool pass = end_ok && counts_ok && hard == 0 && unimpl_cyc == 0;
  std::printf("VERDICT vs MAME: %s\n", !pass ? "FAIL"
              : total_mism == 0 ? "PASS (bit-exact against MAME)"
              : "PASS (bit-exact against MAME except NaN encoding)");
  bool reg_pass = true;
  if (!vs_rtl.empty()) {
    size_t n = std::min(rtl_stream.size(), rtl_ref.size()), diff = 0, first = n;
    for (size_t i = 0; i < n; ++i) if (rtl_stream[i] != rtl_ref[i]) { if (first == n) first = i; ++diff; }
    reg_pass = (diff == 0 && rtl_stream.size() == rtl_ref.size());
    std::printf("VERDICT vs reference RTL: %s (%zu words here, %zu in reference, %zu differ, first at word %zd)\n",
                reg_pass ? "IDENTICAL" : "DIFFERENT", rtl_stream.size(), rtl_ref.size(), diff,
                first == n ? (ssize_t)-1 : (ssize_t)first);
  }
  if (!dump_rtl.empty()) {
    FILE *f = std::fopen(dump_rtl.c_str(), "wb");
    if (f) { std::fwrite(rtl_stream.data(), 4, rtl_stream.size(), f); std::fclose(f); }
    std::printf("RTL result stream written to %s (%zu words)\n", dump_rtl.c_str(), rtl_stream.size());
  }

  std::printf("\n== THROUGHPUT (clk_sys cycles; at 80 MHz 1 ms = 80,000 cycles)\n");
  std::printf("total %llu cycles, %llu instructions retired, CPI %.3f, %.3f ms @80MHz over %u frames\n",
              (unsigned long long)run_cyc, (unsigned long long)retired, double(run_cyc) / std::max<uint64_t>(retired, 1),
              run_cyc / 80000.0, NF);
  std::printf("TGP waiting on empty input FIFO: %llu cycles (%.1f%%)   computing/other: %llu (%.1f%%)\n",
              (unsigned long long)fifo_empty_cyc, 100.0 * fifo_empty_cyc / run_cyc,
              (unsigned long long)(run_cyc - fifo_empty_cyc), 100.0 * (run_cyc - fifo_empty_cyc) / run_cyc);
  std::printf("i960 model blocked on an empty output FIFO (copro_stall analogue): %llu cycles; on a full input FIFO: %llu\n",
              (unsigned long long)feed_x_block, (unsigned long long)feed_full_block);
  std::printf("output FIFO full stalls: %llu\n", (unsigned long long)fout_full_cyc);

  std::printf("\nper frame (frames delimited by the input word that opens them):\n");
  std::printf("  frame   inputs  outputs   cycles   retired    CPI   empty-wait  busy-ms@80  i960-wait-ms@80\n");
  for (unsigned f = 0; f < NF; ++f) {
    const uint64_t nin_f = ((f + 1 < NF) ? frame_in_start[f + 1] : n_inputs) - frame_in_start[f];
    std::printf("  %5u  %7llu  %7llu  %8llu  %8llu  %6.2f  %9llu   %7.3f     %7.3f\n", frame_no[f],
                (unsigned long long)nin_f, (unsigned long long)f_out[f], (unsigned long long)f_cyc[f],
                (unsigned long long)f_ret[f], double(f_cyc[f]) / std::max<uint64_t>(f_ret[f], 1),
                (unsigned long long)f_empty[f], (f_cyc[f] - f_empty[f]) / 80000.0, f_xblk[f] / 80000.0);
  }

  std::printf("\n== CORE FSM STATE HISTOGRAM (cycles)\n");
  for (int i = 0; i < 15; ++i)
    std::printf("  %-10s %11llu  %5.1f%%%s\n", STATE_NAMES[i], (unsigned long long)state_cyc[i],
                100.0 * state_cyc[i] / run_cyc,
                i == S_SRC ? "   (includes the empty-FIFO hold above)" : "");
  std::printf("  of which: input-FIFO empty hold %llu; io wait math %llu, data-ROM %llu, bufram-rd %llu, bufram-wr %llu; data-RAM/FIFO mem_stall %llu\n",
              (unsigned long long)fifo_empty_cyc, (unsigned long long)io_wait_cyc[0], (unsigned long long)io_wait_cyc[1],
              (unsigned long long)io_wait_cyc[2], (unsigned long long)io_wait_cyc[3], (unsigned long long)datamem_wait_cyc);

  std::printf("\n== INSTRUCTION MIX (cycles from S_FETCH to S_RETIRE inclusive)\n");
  auto key_name = [&](unsigned key) {
    static const char *bn[8] = {"brif", "brul", "bsif", "bsul", "br4", "rtif", "ldif", "br7"};
    static const char *ep[6] = {"none", "data", "io", "prog", "reg", "fifo"};
    const unsigned g = key >> 11, alu = (key >> 6) & 31, x = (key >> 3) & 7, y = key & 7;
    char buf[64];
    switch (g) {
      case 0: std::snprintf(buf, sizeof buf, "branch %s", bn[y]); break;
      case 1: std::snprintf(buf, sizeof buf, "ldi"); break;
      case 2: std::snprintf(buf, sizeof buf, "lipl"); break;
      case 3: std::snprintf(buf, sizeof buf, "stm"); break;
      case 4: std::snprintf(buf, sizeof buf, "lab  %-4s b:%s", alu_name(alu), ep[y & 3]); break;
      case 5: std::snprintf(buf, sizeof buf, "mov  %-4s %s->%s", alu_name(alu), ep[x], ep[y]); break;
      case 6: std::snprintf(buf, sizeof buf, "0x0f %-4s %s", alu_name(alu),
                            y == 0 ? "clr" : y == 2 ? "rep" : y == 1 ? "fsub1" : "fsubx"); break;
      default: std::snprintf(buf, sizeof buf, "other"); break;
    }
    return std::string(buf);
  };
  std::vector<std::pair<std::string, Stat>> cv;
  std::map<std::string, Stat> grp;
  for (unsigned k = 0; k < cls.size(); ++k) if (cls[k].n) {
    cv.push_back({key_name(k), cls[k]});
    static const char *gn[8] = {"branch", "ldi", "lipl", "stm", "lab", "mov", "0x0f", "other"};
    grp[gn[k >> 11]].n += cls[k].n; grp[gn[k >> 11]].cyc += cls[k].cyc;
  }
  std::sort(cv.begin(), cv.end(), [](auto &a, auto &b) { return a.second.cyc > b.second.cyc; });
  std::printf("  %-28s %10s %6s %12s %6s %7s\n", "class", "count", "%ins", "cycles", "%cyc", "cyc/ins");
  for (auto &p : cv)
    std::printf("  %-28s %10llu %5.1f%% %12llu %5.1f%% %7.2f\n", p.first.c_str(), (unsigned long long)p.second.n,
                100.0 * p.second.n / std::max<uint64_t>(retired, 1), (unsigned long long)p.second.cyc,
                100.0 * p.second.cyc / run_cyc, double(p.second.cyc) / std::max<uint64_t>(p.second.n, 1));
  std::printf("  -- groups:\n");
  for (auto &p : grp)
    std::printf("     %-7s %10llu ins %5.1f%%  %12llu cyc %5.1f%%  %6.2f cyc/ins\n", p.first.c_str(),
                (unsigned long long)p.second.n, 100.0 * p.second.n / std::max<uint64_t>(retired, 1),
                (unsigned long long)p.second.cyc, 100.0 * p.second.cyc / run_cyc,
                double(p.second.cyc) / std::max<uint64_t>(p.second.n, 1));
  std::printf("\n  rep-group 'rep' instructions retired: %llu\n", (unsigned long long)rep_iter);

  std::printf("\n== ALU OPS (lab / ld-mov / 0x0f group): count and S_ALU cycles\n");
  for (int i = 0; i < 32; ++i)
    if (alu_n_by_op[i])
      std::printf("  %-6s %10llu ops  %11llu S_ALU cycles  %6.2f/op\n", alu_name(i), (unsigned long long)alu_n_by_op[i],
                  (unsigned long long)alu_wait_by_op[i], double(alu_wait_by_op[i]) / alu_n_by_op[i]);

  if (profile_n > 0) {
    std::printf("\n== HOTTEST PCs (cycles in instructions retired at that pc)\n");
    std::vector<unsigned> idx(4096);
    for (unsigned i = 0; i < 4096; ++i) idx[i] = i;
    std::sort(idx.begin(), idx.end(), [&](unsigned a, unsigned b) { return pc_cyc[a] > pc_cyc[b]; });
    for (int i = 0; i < profile_n && pc_cyc[idx[i]]; ++i)
      std::printf("  pc %03x  %10llu cyc  %9llu ins  %6.2f cyc/ins  op %08x\n", idx[i], (unsigned long long)pc_cyc[idx[i]],
                  (unsigned long long)pc_n[idx[i]], double(pc_cyc[idx[i]]) / pc_n[idx[i]], prog[idx[i]]);
  }

  delete top;
  // Against a reference RTL stream the regression verdict is the exit status:
  // MAME and the RTL legitimately differ (NaN encoding, ldif), which --vs-rtl
  // exists to look past.
  return (vs_rtl.empty() ? pass : reg_pass) ? 0 : 1;
}
