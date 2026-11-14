// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R1011: THE i960 FROM A MAME CHECKPOINT (m2_i960_ck_harness).
//
//   Vm2_i960_ck_harness <ckdir> [--lat N] [--icr HEX] [--stub HEX] [--max-ins N]
//                       [--spin LO,HI] [--frame-ip HEX] [--only-frame N] [--ws] [--quiet] [--trace N]
//
// <ckdir> is tools/mame_i960_ck.lua's output after sim/i960ck/ck_prep.py. The
// bench builds the memory image MAME had at the checkpoint, boots the RTL into
// a stub (program ROM words 0 / 4 / 12 patched: SAT, PRCB, the stub's address)
// that sets ICR (synmov), AC (modac), PC (modpc) and g0-g14, points r0 at
// MAME's frame -- written into memory with MAME's r0-r15, rip = the checkpoint
// ip -- and returns into it. From there:
//   * every accepted instruction's ip is compared with MAME's stream;
//   * every load / store the LSU completes is compared with MAME's, in order
//     (aligned address, lanes, data under MAME's mask, direction);
//   * the bridge's I/O port is answered from MAME's I/O reads, in order, at
//     once (no device here waits: the time is the i960's own);
//   * an interrupt MAME took before instruction k is raised on its line
//     (ICR's vector) once the RTL has accepted k instructions.
// The first difference stops the run. The profile: clk_i960 cycles by
// sequencer state, the load / store wait by region, the fetch wait split,
// per game frame (frame-ip to frame-ip), with the spin loop (--spin) apart;
// and MAME's own time for the same instructions (its local time between
// instruction starts, a gap over 4 us -- a halt on a FIFO -- counted at that
// instruction's shortest elsewhere), so s = core time / MAME time is measured.
#include "Vm2_i960_ck_harness.h"
#include "Vm2_i960_ck_harness___024root.h"
#include "Vm2_i960_ck_harness_m2_i960_ck_harness.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <map>
#include <algorithm>
#include <unordered_map>

#define R(x) top->rootp->m2_i960_ck_harness->x

static std::vector<uint16_t> mem;
static const uint32_t MW = 1u << 26;   // 16-bit words (AW 26)

struct Ins { uint32_t ip, fl; double t; };
struct Op  { uint32_t idx, addr, data, mask; uint8_t we, io; uint16_t pad; };

static std::vector<uint8_t> rdfile(const std::string &p) {
  std::vector<uint8_t> v;
  FILE *f = std::fopen(p.c_str(), "rb");
  if (!f) return v;
  std::fseek(f, 0, SEEK_END); long n = std::ftell(f); std::fseek(f, 0, SEEK_SET);
  v.resize(size_t(n));
  if (n && std::fread(v.data(), 1, size_t(n), f) != size_t(n)) v.clear();
  std::fclose(f);
  return v;
}

// a CPU byte range -> SDRAM words at base (the harness's bases)
static void put(const std::vector<uint8_t> &b, size_t off, size_t len, uint32_t base) {
  for (size_t i = 0; i + 1 < len && off + i + 1 < b.size() + 1; i += 2)
    mem[(base + uint32_t(i / 2)) & (MW - 1)] = uint16_t(b[off + i] | (b[off + i + 1] << 8));
}
static uint32_t cpu2word(uint32_t a, bool &ok) {
  ok = true;
  if (a < 0x200000) return 0x0000000 + a / 2;
  if (a >= 0x200000 && a < 0x240000) return 0x0100000 + (a - 0x200000) / 2;
  if (a >= 0x500000 && a < 0x600000) return 0x0200000 + (a - 0x500000) / 2;
  ok = false; return 0;
}
static void wr32(uint32_t a, uint32_t v) {
  bool ok; uint32_t w = cpu2word(a, ok);
  if (!ok) { std::fprintf(stderr, "stub write outside ROM / board / work RAM: %08x\n", a); std::exit(2); }
  mem[w] = uint16_t(v); mem[w + 1] = uint16_t(v >> 16);
}
static uint32_t rd32(uint32_t a) {
  bool ok; uint32_t w = cpu2word(a, ok);
  return ok ? (uint32_t(mem[w]) | (uint32_t(mem[w + 1]) << 16)) : 0;
}

static const char *TSN[32] = {"FETCH", "FETCH_W", "FETCH2", "FETCH2_W", "DECODE", "EXEC", "MEM", "MEM_W",
  "MULDIV", "MULTI", "PAIR", "FP", "WB", "FRAME", "TRAP", "BOOT", "SYNMOV_RD", "SYNMOV_WR", "INTR", "RET7",
  "MODPC", "SYNQ", "RLLO", "TRIP"};

static int region(uint32_t a) {   // for the profile
  if (a < 0x200000) return 0;                        // program ROM
  if (a < 0x240000) return 1;                        // board RAM
  if (a >= 0x500000 && a < 0x600000) return 2;       // work RAM
  if (a >= 0x900000 && a < 0x980000) return 3;       // buffer RAM
  if (a >= 0x884000 && a < 0x888000) return 4;       // copro FIFO
  if (a >= 0x800000 && a < 0x1000000) return 5;      // other I/O 0x8xxxxx-0xfxxxxx
  if (a >= 0x2000000 && a < 0x7000000) return 6;     // data ROM
  if (a >= 0x1000000 && a < 0x1020000) return 7;     // tile RAM
  if (a >= 0x1080000 && a < 0x1100000) return 8;     // char RAM
  if (a >= 0x1800000 && a < 0x1820000) return 9;     // palette, colorxlat
  if (a >= 0x1a00000 && a < 0x2000000) return 10;    // comm, I/O board, backup
  if (a >= 0x10000000) return 11;                    // renderer, texture
  return 12;
}
static const char *RGN[13] = {"progROM", "boardRAM", "workRAM", "bufRAM", "FIFO", "IO", "dataROM", "tileRAM",
                              "charRAM", "palette", "commIO", "render", "other"};

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 2) { std::fprintf(stderr, "usage: %s <ckdir> [options]\n", argv[0]); return 2; }
  std::string dir = argv[1];
  int lat = 6; uint32_t icr = 0x0f0e0d0c, stub = 0x1fff00, frame_ip = 0x1164;
  uint32_t spin_lo = 0x763d4, spin_hi = 0x763e8;
  uint64_t max_ins = ~0ull; bool quiet = false; long trace = 0;
  int only_frame = -1;   // the totals over this game frame alone
  bool ws = false;
  for (int i = 2; i < argc; ++i) {
    std::string a = argv[i];
    auto nx = [&]() { return (i + 1 < argc) ? argv[++i] : ""; };
    if (a == "--lat") lat = std::atoi(nx());
    else if (a == "--icr") icr = uint32_t(std::strtoul(nx(), nullptr, 16));
    else if (a == "--stub") stub = uint32_t(std::strtoul(nx(), nullptr, 16));
    else if (a == "--frame-ip") frame_ip = uint32_t(std::strtoul(nx(), nullptr, 16));
    else if (a == "--max-ins") max_ins = std::strtoull(nx(), nullptr, 10);
    else if (a == "--spin") { std::sscanf(nx(), "%x,%x", &spin_lo, &spin_hi); }
    else if (a == "--quiet") quiet = true;
    else if (a == "--trace") trace = std::atol(nx());
    else if (a == "--only-frame") only_frame = std::atoi(nx());
    else if (a == "--ws") ws = true;   // m2_waitst live (Sega Rally; a WAITST=1 build)
  }

  // ---- MAME's state
  std::map<std::string, uint32_t> st;
  double t_ck = 0;
  {
    FILE *f = std::fopen((dir + "/state.txt").c_str(), "r");
    if (!f) { std::perror("state.txt"); return 2; }
    char k[32], v[64];
    while (std::fscanf(f, "%31s %63s", k, v) == 2) {
      if (!std::strcmp(k, "t")) t_ck = std::atof(v);
      else if (!std::strcmp(k, "frame")) st[k] = uint32_t(std::atol(v));
      else st[k] = uint32_t(std::strtoul(v, nullptr, 16));
    }
    std::fclose(f);
  }
  std::vector<uint8_t> ib = rdfile(dir + "/insn.bin"), ob = rdfile(dir + "/ops.bin");
  const size_t NI = ib.size() / 16, NO = ob.size() / 20;
  std::vector<Ins> ins(NI); std::vector<Op> ops(NO);
  for (size_t i = 0; i < NI; ++i) std::memcpy(&ins[i], &ib[i * 16], 16);
  for (size_t i = 0; i < NO; ++i) std::memcpy(&ops[i], &ob[i * 20], 20);
  if (!NI) { std::fprintf(stderr, "no instructions (run ck_prep.py)\n"); return 2; }
  std::printf("checkpoint ip %08x t %.6f, %zu instructions, %zu loads / stores\n", st["ip"], t_ck, NI, NO);

  // ---- the image
  mem.assign(MW, 0xffff);
  auto ld = [&](uint32_t lo, uint32_t len, uint32_t cpu_off, uint32_t base) {
    char fn[64]; std::snprintf(fn, sizeof fn, "/mem_%08x.bin", lo);
    std::vector<uint8_t> b = rdfile(dir + fn);
    if (b.size() < cpu_off + len) { std::printf("  (no %s)\n", fn); return; }
    put(b, cpu_off, len, base);
  };
  ld(0x000000, 0x200000, 0, 0x0000000);
  ld(0x200000, 0x040000, 0, 0x0100000);
  ld(0x500000, 0x100000, 0, 0x0200000);
  ld(0x1080000, 0x080000, 0, 0x0300000);
  ld(0x900000, 0x020000, 0, 0x0380000);
  ld(0x1800000, 0x000800, 0x2000, 0x03a0000);
  ld(0x1810000, 0x00c000, 0, 0x03b0000);
  ld(0x2000000, 0x2000000, 0, 0x1000000);
  // the on-chip tile RAM and palette
  Vm2_i960_ck_harness *top = new Vm2_i960_ck_harness;
  {
    std::vector<uint8_t> t = rdfile(dir + "/mem_01000000.bin"), p = rdfile(dir + "/mem_01800000.bin");
    for (size_t i = 0; i < 32768 && 2 * i + 1 < t.size(); ++i) R(tram)[i] = uint16_t(t[2 * i] | (t[2 * i + 1] << 8));
    for (size_t i = 0; i < 8192 && 2 * i + 1 < p.size(); ++i) R(pal)[i] = uint16_t(p[2 * i] | (p[2 * i + 1] << 8));
  }

  // ---- the stub
  const uint32_t D = stub + 0x80;
  wr32(0x0, st["sat"]); wr32(0x4, st["prcb"]); wr32(0xc, stub);
  {
    uint32_t c = stub;
    auto w = [&](uint32_t v) { wr32(c, v); c += 4; };
    auto mld = [&](uint8_t op, int reg, uint32_t a) { w((uint32_t(op) << 24) | (uint32_t(reg) << 19) | 0x3000); w(a); };
    mld(0x8c, 18, 0xff000004);          // lda 0xff000004,g2
    mld(0x8c, 19, D + 0x0c);            // lda D+12,g3
    w(0x6004E012);                      // synmov g2,g3     (ICR)
    mld(0x90, 16, D + 0x00);            // ld mask,g0
    mld(0x90, 17, D + 0x04);            // ld AC,g1
    w(0x64944290);                      // modac g0,g1,g2
    mld(0x90, 17, D + 0x08);            // ld PC,g1
    w(0x658C0290);                      // modpc g0,g0,g1
    mld(0xb0, 16, D + 0x10);            // ldq g0-g3
    mld(0xb0, 20, D + 0x20);            // ldq g4-g7
    mld(0xb0, 24, D + 0x30);            // ldq g8-g11
    mld(0xa0, 28, D + 0x40);            // ldt g12-g14
    mld(0x90, 0,  D + 0x4c);            // ld pfp
    w(0x0A000000);                      // ret
    if (c > D) { std::fprintf(stderr, "stub too long\n"); return 2; }
    wr32(D + 0x00, 0xffffffff); wr32(D + 0x04, st["ac"]); wr32(D + 0x08, st["pc"]); wr32(D + 0x0c, icr);
    const char *gn[15] = {"g0", "g1", "g2", "g3", "g4", "g5", "g6", "g7", "g8", "g9", "g10", "g11", "g12", "g13", "g14"};
    for (int i = 0; i < 15; ++i) wr32(D + 0x10 + 4 * i, st[gn[i]]);
    wr32(D + 0x4c, st["fp"] & ~0x3fu);
    // MAME's current frame, as if it had been saved: rip = where it resumes
    const char *rn[16] = {"pfp", "sp", "rip", "r3", "r4", "r5", "r6", "r7", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"};
    for (int i = 0; i < 16; ++i) wr32((st["fp"] & ~0x3fu) + 4 * i, i == 2 ? st["ip"] : st[rn[i]]);
  }

  // ---- run
  top->clk_cpu = 0; top->clk_mem = 0; top->rst_n = 0; top->ws_en = ws ? 1 : 0; top->irq = 0;
  top->sd_ack = 0; top->sd_dout = 0; top->io_rdata = 0;
  top->eval();
  int s_lat = 0, ack_left = 0; bool busy = false; uint32_t pend = 0;
  size_t io_r = 0, io_w = 0, op_i = 0;   // cursors into ops: the I/O reads, the I/O writes, every op
  std::vector<size_t> io_rd, io_wr;
  for (size_t i = 0; i < NO; ++i) if (ops[i].io == 1) (ops[i].we ? io_wr : io_rd).push_back(i);

  bool started = false; uint64_t base_acc = 0, k = 0;   // k: MAME instructions matched
  uint64_t cyc = 0, h = 0;
  int irq_hold = 0; uint32_t irq_line = 0;
  bool fail = false; std::string why;
  uint64_t geo_step = 0;   // stores into the geo push window at a stepped address (R1011)
  uint64_t n_vdiff = 0, n_iodiff = 0;
  // the RTL's own stream (ips, LSU words, I/O accesses, in order): two builds
  // that differ only in timing must print the same digest
  // One digest a stream, not one over them interleaved: a posted store (R1011)
  // completes after later instructions are accepted, so the interleaving is
  // timing; each stream's own order is not.
  uint64_t dgs[3] = {1469598103934665603ull, 1469598103934665603ull, 1469598103934665603ull};
  int dsel = 0;
  auto dg = [&](uint32_t x) { uint64_t &d_ = dgs[dsel]; for (int b = 0; b < 4; ++b) { d_ ^= (x >> (8 * b)) & 0xff; d_ *= 1099511628211ull; } };
  // profile
  uint64_t c_ts[32] = {0}, c_spin = 0, c_all = 0, n_busy = 0, n_spin = 0;
  uint64_t memw_rgn[13] = {0}, memn_rgn[13] = {0}, fw_fill = 0, fw_hit = 0;
  // per LSU word: the cycles its request was up, by region / direction / data-cache hit
  uint64_t aw_n[13][2][2] = {{{0}}}, aw_c[13][2][2] = {{{0}}}; uint64_t a_cyc = 0;
  uint64_t n_len2 = 0, f2w_cyc = 0, n_ld = 0, n_st = 0;
  uint64_t ic_fills = 0, ic_fill_cyc = 0, ic_words = 0; int ic_prev = 0;   // the i-cache's line fills
  uint64_t f_ts[32] = {0}; uint64_t f_cyc = 0, f_spin = 0, f_n = 0, f_nspin = 0; double f_mame = 0;
  double mame_busy = 0; size_t f_first = 0; int frames = 0;
  uint32_t cur_ip = 0; uint32_t last_lsu_addr = 0;
  // MAME's own time per instruction: its local time to the next start; a gap
  // over 4 us is a halt, charged at that ip's shortest elsewhere
  std::unordered_map<uint32_t, double> ipmin;
  for (size_t i = 0; i + 1 < NI; ++i) {
    double dt = ins[i + 1].t - ins[i].t;
    if (ins[i + 1].fl & 1) continue;
    auto it = ipmin.find(ins[i].ip);
    if (it == ipmin.end() || dt < it->second) ipmin[ins[i].ip] = dt;
  }
  // MAME charges each opcode a fixed count (m_icount -= n), so an instruction's
  // own time is the shortest gap seen after it; a longer gap is a halt, a stall
  // spin on an empty FIFO (merged into the load) or an interrupt between.
  auto mame_dt = [&](size_t i) -> double {
    auto it = ipmin.find(ins[i].ip);
    return (it != ipmin.end() && it->second <= 4e-6) ? it->second : 4e-8;
  };
  auto in_spin = [&](uint32_t ip) { return ip >= spin_lo && ip <= spin_hi; };
  std::printf("%-6s %8s %9s %7s %8s %8s %6s %7s  %s\n", "frame", "busy_i", "busy_cyc", "CPI", "core_ms", "mame_ms", "s",
              "spin_i", "by state (busy, % of cycles)");

  const uint64_t HMAX = 4000000000ull;
  uint64_t end_at = 0;   // the stream is done: a few cycles more, for what is still on the bus
  for (h = 0; h < HMAX && !fail; ++h) {
    if (end_at && cyc >= end_at) break;
    const bool mem_rise = (h & 1);
    const bool cpu_rise = mem_rise && !((h >> 1) & 1);   // every second clk_mem rise
    if (h == 40) top->rst_n = 1;
    // ---- sample the cycle about to end (before the edges)
    if (cpu_rise) {
      const int ts = top->dbg_ts & 31;
      if (started) {
        ++c_all;
        const bool sp = in_spin(cur_ip);
        if (sp) ++c_spin; else { ++c_ts[ts]; ++f_ts[ts]; ++f_cyc; }
        if (sp) ++f_spin;
        if (!sp) {
          if (ts == 7) { ++memw_rgn[region(R(u_cpu__DOT__lsu_breq) ? R(u_cpu__DOT__lsu_baddr) : last_lsu_addr)]; }
          if (ts == 3) ++f2w_cyc;
          if (ts == 1 || ts == 3) { if (R(u_cpu__DOT__ic_breq)) ++fw_fill; else ++fw_hit; }
        }
      }
      {
        const int ist = R(u_cpu__DOT__u_icache__DOT__state);
        static long ftr = std::getenv("CK_FILLTRACE") ? std::atol(std::getenv("CK_FILLTRACE")) : 0;
        if (started && ftr > 0) {
          if (ist == 1 && ic_prev != 1) std::printf("  fill start cyc %llu addr %08x ts %s\n", (unsigned long long)cyc, R(u_cpu__DOT__ic_baddr), TSN[ts]);
          if (R(u_cpu__DOT__ic_breq) && R(u_cpu__DOT__ic_back)) std::printf("    word %08x at cyc %llu (ts %s)\n", R(u_cpu__DOT__ic_baddr), (unsigned long long)cyc, TSN[ts]);
          if (ist != 1 && ic_prev == 1) { std::printf("  fill end cyc %llu\n", (unsigned long long)cyc); --ftr; }
        }
        if (started) {
          if (ist == 1 && ic_prev != 1) ++ic_fills;
          if (ist == 1) ++ic_fill_cyc;
          if (R(u_cpu__DOT__ic_breq) && R(u_cpu__DOT__ic_back)) ++ic_words;
        }
        ic_prev = ist;
      }
      // the LSU's completed access
      if (R(u_cpu__DOT__lsu_breq)) ++a_cyc;
      if (R(u_cpu__DOT__lsu_breq) && R(u_cpu__DOT__lsu_back)) {
        const uint32_t a = R(u_cpu__DOT__lsu_baddr);
        last_lsu_addr = a;
        if (started) {
          ++memn_rgn[region(a)];
          if (!in_spin(cur_ip)) {
            const int rg = region(a), w_ = R(u_cpu__DOT__lsu_bwe) ? 1 : 0, hit = R(u_cpu__DOT__g_dc__DOT__dc_ack) ? 1 : 0;
            ++aw_n[rg][w_][hit]; aw_c[rg][w_][hit] += a_cyc;
          }
          const bool we = R(u_cpu__DOT__lsu_bwe);
          const uint32_t be = R(u_cpu__DOT__lsu_bbe);
          const uint32_t wd = R(u_cpu__DOT__lsu_bwdata), rd = R(u_cpu__DOT__c_rdata);
          const bool inlog = op_i < NO;
          if (op_i >= NO) { if (!end_at) { fail = true; why = "LSU access past MAME's log"; } }
          else {
            const Op &o = ops[op_i];
            uint32_t bm = 0; for (int b = 0; b < 4; ++b) if (be & (1u << b)) bm |= 0xffu << (8 * b);
            const uint32_t v = we ? wd : rd;
            char buf[256];
            const bool geo = (a >= 0x804000 && a < 0x808000) && (o.addr >= 0x804000 && o.addr < 0x808000);
            if ((((a & ~3u) != o.addr) && !geo) || bool(we) != bool(o.we) || ((v ^ o.data) & o.mask) || (we && bm != o.mask)) {
              std::snprintf(buf, sizeof buf, "LSU %zu (insn %u ip %08x): RTL %s %08x be %x data %08x, MAME %s %08x mask %08x data %08x",
                            op_i, o.idx, ins[o.idx].ip, we ? "W" : "R", a, be, v, o.we ? "W" : "R", o.addr, o.mask, o.data);
              if (bool(we) == bool(o.we) && ((a & ~3u) == o.addr || geo) && (!we || bm == o.mask)) {
                // R1011: the same access with another value. The RTL's FP units
                // flush subnormals (study 8.1) where MAME's host floats keep
                // them, and STCC's race has them (0x202638): the run goes on
                // with the RTL's own values, every one counted. Only a
                // different access -- address, direction, lanes -- or a
                // different instruction stops it.
                if (n_vdiff++ < 12) std::printf("  value differs: %s\n", buf);
              } else { fail = true; why = buf; }
            }
            ++op_i;
          }
          { uint32_t m = 0; for (int b = 0; b < 4; ++b) if (be & (1u << b)) m |= 0xffu << (8 * b);
            if (inlog) { dsel = 1; dg((we ? 0x80000000u : 0x40000000u) | (be << 24) | (a & 0x00ffffffu)); dg(we ? (wd & m) : (rd & m)); } }
        }
        a_cyc = 0;
        // (accesses before the start: the stub's own, not compared)
      }
    }
    // ---- the edges
    // clk_cpu rises with every other clk_mem rise and falls with the ones between
    top->clk_mem = mem_rise ? 1 : 0;
    if (mem_rise) top->clk_cpu = cpu_rise ? 1 : 0;
    top->eval();
    if (!mem_rise) continue;
    // ---- after a clk_mem rise: the memory model and the I/O port
    if (!busy && top->sd_req && !ack_left) {
      busy = true; s_lat = lat; pend = top->sd_addr;
      if (top->sd_we) {
        const uint16_t old = mem[pend & (MW - 1)];
        uint16_t v = top->sd_din;
        if (!(top->sd_be & 1)) v = uint16_t((v & 0xff00) | (old & 0x00ff));
        if (!(top->sd_be & 2)) v = uint16_t((v & 0x00ff) | (old & 0xff00));
        mem[pend & (MW - 1)] = v;
      }
    } else if (busy && --s_lat <= 0) {
      uint64_t v = 0;
      for (int w = 0; w < 4; ++w) v |= uint64_t(mem[(pend + w) & (MW - 1)]) << (16 * w);
      top->sd_dout = v; ack_left = 2; busy = false;
    }
    top->sd_ack = ack_left > 0;
    if (ack_left > 0) --ack_left;
    if (top->io_sel) {
      const uint32_t a = top->io_addr;
      if (top->io_we) {
        if (started) {
          const bool inl = io_w < io_wr.size();
          if (io_w >= io_wr.size()) { if (!end_at) { fail = true; why = "I/O write past MAME's log"; } }
          else {
            const Op &o = ops[io_wr[io_w++]];
            uint32_t bm = 0; for (int b = 0; b < 4; ++b) if (top->io_be & (1u << b)) bm |= 0xffu << (8 * b);
            // R1011: on 2C MAME maps 0x804000-0x807fff (geo_prg) WITHOUT i960
            // BURST, so a multi-word store repeats its address there; the RTL's
            // memmap steps it (the 2A map). The core decodes the whole window
            // as one push port, so only the data is compared there, and counted.
            const bool geo = (a >= 0x804000 && a < 0x808000) && (o.addr >= 0x804000 && o.addr < 0x808000);
            if (geo && (a & ~3u) != o.addr) ++geo_step;
            if (((a & ~3u) != o.addr && !geo) || ((top->io_wdata ^ o.data) & o.mask)) {
              char buf[200];
              std::snprintf(buf, sizeof buf, "I/O write %zu (insn %u): RTL %08x %08x, MAME %08x %08x mask %08x",
                            io_w - 1, o.idx, a, top->io_wdata, o.addr, o.data, o.mask);
              if ((a & ~3u) == o.addr || geo) { if (n_iodiff++ < 12) std::printf("  I/O value differs: %s\n", buf); }
              else { fail = true; why = buf; }
            }
            if (inl) { dsel = 2; dg(0x10000000u | (a & 0x00ffffffu)); dg(top->io_wdata & bm); }
          }
        }
      } else {
        uint32_t v = 0xffffffff;
        if (started) {
          const bool inl = io_r < io_rd.size();
          if (io_r >= io_rd.size()) { if (!end_at) { fail = true; why = "I/O read past MAME's log"; } }
          else {
            const Op &o = ops[io_rd[io_r++]];
            if ((a & ~3u) != o.addr) {
              char buf[200];
              std::snprintf(buf, sizeof buf, "I/O read %zu (insn %u): RTL %08x, MAME %08x", io_r - 1, o.idx, a, o.addr);
              fail = true; why = buf;
            }
            v = o.data;
          }
          if (inl) { dsel = 2; dg(0x20000000u | (a & 0x00ffffffu)); }
        }
        top->io_rdata = v;
      }
    }
    if (!cpu_rise) continue;
    ++cyc;
    // ---- after a clk_cpu rise: accepts, interrupts
    if (top->trap || top->halted) {
      char buf[120]; std::snprintf(buf, sizeof buf, "trap %d op %02x halted %d at ip %08x", top->trap, top->trap_op, top->halted, top->dbg_ip);
      fail = true; why = buf; break;
    }
    if (irq_hold > 0 && --irq_hold == 0) top->irq = 0;
    static uint32_t last_acc = 0;
    const uint32_t acc = top->dbg_acc_cnt;
    if (acc != last_acc) {
      last_acc = acc;
      const uint32_t ip = top->dbg_ip;
      if (!started) {
        if (ip == st["ip"] && acc > 3) {
          started = true; base_acc = acc - 1; k = 0;
          std::printf("started at cycle %llu (stub done)\n", (unsigned long long)cyc);
        }
      }
      if (started) {
        const uint64_t j = acc - 1 - base_acc;   // this instruction's index
        if (j >= NI || end_at) { if (!end_at) end_at = cyc + 64; continue; }
        if (ip != ins[j].ip) {
          char buf[160]; std::snprintf(buf, sizeof buf, "PC: instruction %llu RTL %08x MAME %08x (prev %08x)",
                                       (unsigned long long)j, ip, ins[j].ip, j ? ins[j - 1].ip : 0);
          fail = true; why = buf; break;
        }
        if (trace && long(j) < trace) std::printf("  i %llu %08x cyc %llu\n", (unsigned long long)j, ip, (unsigned long long)cyc);
        cur_ip = ip; k = j + 1; dsel = 0; dg(ip);
        if (in_spin(ip)) { ++n_spin; ++f_nspin; } else { ++n_busy; ++f_n; const double dt = mame_dt(j); mame_busy += dt; f_mame += dt;
          if (R(u_cpu__DOT__d_len2)) ++n_len2; }
        // the next instruction is entered by an interrupt: raise its line now
        if (j + 1 < NI && (ins[j + 1].fl & 1)) {
          const uint32_t vec = (ins[j + 1].fl >> 8) & 0xff;
          int line = -1; for (int l = 0; l < 4; ++l) if (((icr >> (8 * l)) & 0xff) == vec) line = l;
          if (line < 0) { fail = true; why = "interrupt vector not in ICR"; break; }
          irq_line = 1u << line; top->irq = irq_line; irq_hold = 8;
        }
        // a game frame ends where the next begins
        if (ip == frame_ip && j > 0) {
          if (!quiet || frames < 1000) {
            std::printf("%-6d %8llu %9llu %7.3f %8.3f %8.3f %6.3f %7llu ", frames, (unsigned long long)f_n,
                        (unsigned long long)f_cyc, f_n ? double(f_cyc) / f_n : 0, f_cyc / 40e3, f_mame * 1e3,
                        f_mame > 0 ? (f_cyc / 40e6) / f_mame : 0, (unsigned long long)f_nspin);
            for (int s = 0; s < 24; ++s) if (f_ts[s] * 200 >= f_cyc && f_cyc) std::printf(" %s %.1f", TSN[s], 100.0 * f_ts[s] / f_cyc);
            std::printf("\n");
          }
          ++frames;
          if (only_frame >= 0 && frames == only_frame) {
            // the totals from here: zero them (the frame table goes on)
            std::memset(c_ts, 0, sizeof c_ts); c_spin = c_all = n_busy = n_spin = 0; mame_busy = 0;
            std::memset(memw_rgn, 0, sizeof memw_rgn); std::memset(memn_rgn, 0, sizeof memn_rgn);
            std::memset(aw_n, 0, sizeof aw_n); std::memset(aw_c, 0, sizeof aw_c);
            fw_fill = fw_hit = n_len2 = f2w_cyc = 0; ic_fills = ic_fill_cyc = ic_words = 0;
          }
          if (only_frame >= 0 && frames == only_frame + 1) { k = j; break; }
          std::memset(f_ts, 0, sizeof f_ts); f_cyc = f_spin = f_n = f_nspin = 0; f_mame = 0; f_first = j;
        }
        if (k >= max_ins) break;
      }
    }
  }
  (void)f_first;
  std::printf("\n%s after %llu MAME instructions (%llu clk_i960 cycles); LSU %zu / %zu, I/O reads %zu / %zu, writes %zu / %zu\n",
              fail ? "FAIL" : "PASS", (unsigned long long)k, (unsigned long long)cyc, op_i, NO, io_r, io_rd.size(), io_w, io_wr.size());
  if (fail) std::printf("  %s\n", why.c_str());
  std::printf("  digests: instructions %016llx, LSU %016llx, I/O %016llx; values that differ from MAME's: LSU %llu, I/O writes %llu\n",
              (unsigned long long)dgs[0], (unsigned long long)dgs[1], (unsigned long long)dgs[2],
              (unsigned long long)n_vdiff, (unsigned long long)n_iodiff);
  if (geo_step) std::printf("  %llu geo-window writes at a stepped address (MAME: the same address; data equal)\n", (unsigned long long)geo_step);
  const uint64_t cb = c_all - c_spin;
  std::printf("busy: %llu instructions, %llu cycles, CPI %.3f; core %.3f ms, MAME %.3f ms, s = %.3f; spin %llu instructions %llu cycles\n",
              (unsigned long long)n_busy, (unsigned long long)cb, n_busy ? double(cb) / n_busy : 0, cb / 40e3,
              mame_busy * 1e3, mame_busy > 0 ? (cb / 40e6) / mame_busy : 0, (unsigned long long)n_spin, (unsigned long long)c_spin);
  std::printf("busy cycles by state (CPI contribution):\n");
  for (int s = 0; s < 24; ++s) if (c_ts[s]) std::printf("  %-10s %10llu  %5.1f%%  %.3f\n", TSN[s], (unsigned long long)c_ts[s],
                                                      100.0 * c_ts[s] / cb, double(c_ts[s]) / n_busy);
  std::printf("  fetch wait: %llu cycles with the i-cache filling, %llu without\n", (unsigned long long)fw_fill, (unsigned long long)fw_hit);
  std::printf("  i-cache: %llu fills (%.1f a 1000 busy instructions), %.1f cycles filling each, %llu bus words\n",
              (unsigned long long)ic_fills, 1000.0 * ic_fills / (n_busy ? n_busy : 1), ic_fills ? double(ic_fill_cyc) / ic_fills : 0,
              (unsigned long long)ic_words);
  std::printf("  two-word instructions %llu (%.1f%%), FETCH2_W %.2f cycles each\n", (unsigned long long)n_len2,
              100.0 * n_len2 / (n_busy ? n_busy : 1), n_len2 ? double(f2w_cyc) / n_len2 : 0);
  std::printf("LSU words (busy): region dir dcache  n  request-cycles-each\n");
  for (int r = 0; r < 13; ++r) for (int w_ = 0; w_ < 2; ++w_) for (int hh = 0; hh < 2; ++hh) if (aw_n[r][w_][hh])
    std::printf("  %-9s %s %s %9llu  %.2f  (%.3f CPI)\n", RGN[r], w_ ? "W" : "R", hh ? "hit " : "    ",
                (unsigned long long)aw_n[r][w_][hh], double(aw_c[r][w_][hh]) / aw_n[r][w_][hh], double(aw_c[r][w_][hh]) / n_busy);
  std::printf("MEM_W by region (cycles / accesses / cycles each; all LSU accesses counted, busy MEM_W cycles):\n");
  for (int r = 0; r < 13; ++r) if (memn_rgn[r] || memw_rgn[r])
    std::printf("  %-9s %9llu %8llu  %.2f\n", RGN[r], (unsigned long long)memw_rgn[r], (unsigned long long)memn_rgn[r],
                memn_rgn[r] ? double(memw_rgn[r]) / memn_rgn[r] : 0);
  delete top;
  return fail ? 1 : 0;
}
