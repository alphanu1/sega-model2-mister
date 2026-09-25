// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// The real i960 running the real Daytona program ROM through the real bridge
// and the real SDRAM controller. See m2_cpu_real_harness.sv for why.
//
// WHAT THIS CHECKS. Not values -- the ROM's arithmetic is tb_i960_rom's job --
// but that the CPU KEEPS GOING. The two changes this exists for both failed
// on hardware as the machine stopping: black, or locked before the first
// frame. So the checks are (1) the CPU retires N instructions without halting
// or trapping, (2) it never goes quiet for long, and (3) the SEQUENCE of
// instruction pointers it retires is the same as it was -- a change to the
// memory path that alters WHEN the CPU is answered must not alter WHAT it
// executes, and a hash over the retired-IP stream says so in one number.
//
// Run it twice, before and after a change, and compare the hash. M2_HASH_OUT
// writes it to a file so a Makefile or a shell can diff them.
//
// NO ROM BYTE ENTERS THE REPOSITORY. Skips, as tb_i960_rom does, when the set
// is not under M2_ROMPATH (default ~/roms/Model2). A missing ROM is not a
// broken build.

#include "Vm2_cpu_real_harness.h"
#include "verilated.h"
#include "Vm2_cpu_real_harness___024root.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <string>
#include <vector>
#include <algorithm>

static Vm2_cpu_real_harness *dut;
static int checks = 0, fails = 0;
#define CHECK(c, ...) do { ++checks; if (!(c)) { ++fails; std::printf("  FAIL: " __VA_ARGS__); std::printf("\n"); } } while (0)

// Same clock ratio as tb_m2_cpu_sdram, so the bridge's crossing is exercised
// the way the composition test already exercises it.
// R561: M2_CPU_DIV / M2_MEM_DIV / M2_SD_DIV override them, in 5 ns ticks, and
// M2_SD_DIV gives the controller its own clock (the harness's XMODE 1 or 2).
// 8/4/2 is the board today: 25 / 50 / 100 MHz.
static int CPU_DIV = 8, MEM_DIV = 5, SD_DIV = 0;
static unsigned long long tk = 0;

// R529: COMPETING SDRAM TRAFFIC, as tb_m2_cpu_sdram has it. On the board ports
// 2 and 3 are never idle -- the self-test loops and the character fetch runs
// every line -- and a CPU access waits its turn behind them. M2_COMPETE=1.
static bool competing = false;
static uint32_t p2a = 0x100000, p3a = 0x200000;
static int p2_off = 0, p3_off = 0;   // R561: ticks the request must stay low
static void drive_traffic() {
  if (!competing) { dut->p2_req = 0; dut->p3_req = 0; return; }
  // R561: low for a whole requester cycle between requests -- see preload().
  if (dut->p2_req && dut->p2_ack) { dut->p2_req = 0; p2_off = MEM_DIV; p2a = 0x100000 + ((p2a + 4) & 0xfff); }
  else if (!dut->p2_req && p2_off > 0) --p2_off;
  else if (!dut->p2_req) { dut->p2_addr = p2a; dut->p2_req = 1; }
  if (dut->p3_req && dut->p3_ack) { dut->p3_req = 0; p3_off = MEM_DIV; p3a = 0x200000 + ((p3a + 4) & 0xfff); }
  else if (!dut->p3_req && p3_off > 0) --p3_off;
  else if (!dut->p3_req) { dut->p3_addr = p3a; dut->p3_req = 1; }
}

// R530: THE DEVICES THE BOOT CODE TALKS TO, ported from tb_i960_rom's model:
// the irq controller, videoctl's frame counter, a copro that reports drained,
// the copro ID string, the I/O board's dual-port RAM, and backup SRAM as
// unwritten. Everything else in the I/O window reads as zero. A vblank every
// VBLANK_CYCLES CPU cycles raises irq 0 when the game has enabled it.
static uint32_t intreq = 0, intena = 0, videoctl = 0;
static uint64_t vblanks = 0;
static uint8_t  io_dp[0x800];
static unsigned long long VBLANK_TICKS = 434600ULL * 8;   // set again once CPU_DIV is known
static void drive_irq() {
  dut->irq = uint8_t(((intreq & 0x001u) ? 1u : 0u) | ((intreq & 0x002u) ? 2u : 0u) |
                     ((intreq & 0x3fcu) ? 4u : 0u) | ((intreq & 0xc00u) ? 8u : 0u));
}
static uint32_t io_read(uint32_t a) {
  a &= ~3u;
  if (a == 0x00980004u) return 1;                                   // copro drained
  if (a >= 0x00980030u && a < 0x00980040u) {
    static const uint8_t ID[16] = {0,'T','A','H',0,'A','K','O',0,'Z','A','K',0,'M','T','K'};
    const uint32_t o = a & 0xfu;
    return uint32_t(ID[o]) | (uint32_t(ID[o|1]) << 8) | (uint32_t(ID[o|2]) << 16) | (uint32_t(ID[o|3]) << 24);
  }
  if (a == 0x0098000cu) {                                           // videoctl_r
    const uint32_t fn = uint32_t(vblanks);
    return (videoctl & 1u) ? (((fn & 1u) << 2) | (videoctl & 3u)) : (((fn & 2u) << 1) | (videoctl & 3u));
  }
  if (a == 0x00e80000u) return intreq;
  if (a == 0x00e80004u) return intena;
  if (a >= 0x01c00000u && a < 0x01c01000u) { const uint32_t k = (a - 0x01c00000u) >> 2; return uint32_t(io_dp[2*k]) | (uint32_t(io_dp[2*k+1]) << 16); }
  if (a >= 0x01d00000u && a <= 0x01d03fffu) return 0xffffffffu;   // backup SRAM, unwritten
  return 0;
}
static void io_write(uint32_t a, uint32_t v, uint8_t be) {
  a &= ~3u;
  if (a == 0x00e80000u) { intreq &= v; drive_irq(); return; }
  if (a == 0x00e80004u) { intena  = v; return; }
  if (a == 0x0098000cu) { videoctl = v; return; }
  if (a >= 0x01c00000u && a < 0x01c01000u) {
    const uint32_t k = (a - 0x01c00000u) >> 2;
    if (be & 0x1) io_dp[2*k]   = uint8_t(v);
    if (be & 0x4) io_dp[2*k+1] = uint8_t(v >> 16);
  }
}
static bool io_we_seen = false;
static bool io_sel_seen = false;
static long io_accesses = 0;
static std::vector<std::pair<uint32_t,long>> io_hist;     // (addr, count), small
static void io_note(uint32_t a) {
  for (auto &e : io_hist) if (e.first == a) { ++e.second; return; }
  if (io_hist.size() < 32) io_hist.push_back({a, 1});
}
static void drive_io() {
  dut->io_stall = 0;
  if (dut->io_sel && !io_sel_seen) { ++io_accesses; io_note(dut->io_addr & ~3u); }
  io_sel_seen = dut->io_sel;
  if (dut->io_sel) {
    dut->io_rdata = io_read(dut->io_addr);
    if (dut->io_we && !io_we_seen) io_write(dut->io_addr, dut->io_wdata, uint8_t(dut->io_be));
    io_we_seen = dut->io_we;
  } else io_we_seen = false;
  if ((tk % VBLANK_TICKS) == VBLANK_TICKS - 1) { ++vblanks; if (intena & 1u) { intreq |= 1u; drive_irq(); } }
}

// R530: WHAT THE CPU IS POLLING. A core in a spin loop is waiting on ONE
// address; tb_i960_rom names it for the same reason. Counted on the rising
// edge of bus_ack for reads.
static std::vector<std::pair<uint32_t,long>> rd_hist;
static bool ack_seen = false;
static long bus_n = 0;
// THE ADDRESS MUST BE TAKEN WHILE THE REQUEST IS PENDING, NOT AT THE ACK. The
// real CPU moves bus_addr ON the acknowledge (the bridge header says so), so
// by the time the ack edge is seen the address already names the NEXT access.
// The first version sampled at the edge and every transaction read as 0.
static uint32_t pend_addr = 0, pend_ip = 0; static bool pend_we = false;
static uint32_t pend_wdata = 0;
// R532: the same fold Model2.sv computes -- first 32,768 dword writes into
// board RAM, 16-bit sum of both halves -- so the board's value has a reference.
static uint16_t bw_fold = 0; static uint32_t bw_cnt = 0;
static long trace_from = -1, trace_n = 0;      // M2_TRACE_BUS=from,count
static void note_reads() {
  // Nothing before the CPU is released: while it is held in reset during the
  // preload it still presents a request at address 0, and the first version
  // counted 102,815 of them as the loop's most-read address.
  if (!dut->cpu_rst_n) { ack_seen = dut->bus_ack; return; }
  if (dut->bus_req && !dut->bus_ack) { pend_addr = dut->bus_addr; pend_we = dut->bus_we; pend_ip = dut->dbg_ip; pend_wdata = dut->bus_wdata; }
  if (dut->bus_ack && !ack_seen && pend_we && bw_cnt < 32768
      && pend_addr >= 0x00200000u && pend_addr < 0x00220000u) {
    bw_fold = uint16_t(bw_fold + (pend_wdata >> 16) + (pend_wdata & 0xffff));
    ++bw_cnt;
  }
  if (dut->bus_ack && !ack_seen) {
    if (trace_from >= 0 && bus_n >= trace_from && bus_n < trace_from + trace_n)
      std::printf("      bus#%-6ld ip=%08x %s %08x %s%08x\n", bus_n, pend_ip,
                  pend_we ? "WR" : "rd", pend_addr,
                  pend_we ? "" : "-> ", pend_we ? 0u : dut->bus_rdata);
    ++bus_n;
  }
  if (dut->bus_ack && !ack_seen && !pend_we) {
    const uint32_t a = pend_addr & ~3u;
    bool hit = false;
    for (auto &e : rd_hist) if (e.first == a) { ++e.second; hit = true; break; }
    if (!hit && rd_hist.size() < 64) rd_hist.push_back({a, 1});
  }
  ack_seen = dut->bus_ack;
}

// R548: WHERE THE CPU'S CYCLES GO. On each CPU edge: waiting on the bus (a
// request up, not yet acknowledged), by class of what it waits for; or not on
// the bus at all (the core computing, or stalled on something internal).
static long acc_cyc = 0, acc_nobus = 0, acc_wait[6], acc_n[6];
static const char *acc_name[6] = {"write", "read ROM", "read board RAM", "read work RAM", "read I/O+other", "(unused)"};
static bool acc_ack_d = false;
static long mst_wait[8], rom_by_mst[8];
#include <unordered_map>
static std::unordered_map<uint32_t, long> ic_lines;   // R548: icache fill words by 16-byte line
static long ic_words = 0;
static bool ic_ack_d = false;   // by bus master: 1 boot, 2 reg-frame, 3 LSU, 4 icache
static int acc_class(uint32_t a, bool we) {
  if (we) return 0;
  if (a < 0x00200000u) return 1;
  if (a < 0x00240000u) return 2;
  if (a >= 0x00500000u && a < 0x00600000u) return 3;
  return 4;
}
static void cpu_account() {
  if (!dut->cpu_rst_n) return;
  ++acc_cyc;
  if (!dut->bus_req) ++acc_nobus;
  else if (!dut->bus_ack) {
    ++acc_wait[acc_class(dut->bus_addr, dut->bus_we)];
    ++mst_wait[dut->rootp->m2_cpu_real_harness__DOT__u_cpu__DOT__gsel & 7];
    if (!dut->bus_we && dut->bus_addr < 0x00200000u) ++rom_by_mst[dut->rootp->m2_cpu_real_harness__DOT__u_cpu__DOT__gsel & 7];
  }
  if (dut->bus_ack && !acc_ack_d) ++acc_n[acc_class(pend_addr, pend_we)];
  {
    const bool ic = (dut->rootp->m2_cpu_real_harness__DOT__u_cpu__DOT__gsel & 7) == 4;
    if (ic && dut->bus_ack && !ic_ack_d) { ++ic_words; ++ic_lines[dut->bus_addr >> 4]; }
    ic_ack_d = dut->bus_ack;
  }
  acc_ack_d = dut->bus_ack;
}

static void step() {
  ++tk;
  drive_traffic();
  drive_io();
  if (SD_DIV) {
    // Three clocks: every edge due on this tick moves at once, then ONE
    // evaluation. Aligned clocks evaluated one after the other would let a
    // register clocked first be seen by one clocked second in the same instant,
    // which is a race the hardware does not have.
    const bool c = (tk % CPU_DIV) == 0, m = (tk % MEM_DIV) == 0, sd = (tk % SD_DIV) == 0;
    if (c || m || sd) {
      if (c) dut->clk_cpu = 0; if (m) dut->clk_mem = 0; if (sd) dut->clk_sd = 0;
      dut->eval();
      if (c) dut->clk_cpu = 1; if (m) dut->clk_mem = 1; if (sd) dut->clk_sd = 1;
      dut->eval();
    }
    note_reads();
    if (c) cpu_account();
    return;
  }
  if ((tk % CPU_DIV) == 0) { dut->clk_cpu = 0; dut->eval(); }
  if ((tk % MEM_DIV) == 0) { dut->clk_mem = 0; dut->eval(); }
  if ((tk % CPU_DIV) == 0) { dut->clk_cpu = 1; dut->eval(); }
  if ((tk % MEM_DIV) == 0) { dut->clk_mem = 1; dut->eval(); }
  note_reads();          // R530: after the edges, so bus_* are this tick's values
  if ((tk % CPU_DIV) == 0) cpu_account();   // R548
}

static bool load_file(const std::string &path, std::vector<uint8_t> &out) {
  FILE *f = std::fopen(path.c_str(), "rb");
  if (!f) return false;
  std::fseek(f, 0, SEEK_END); long n = std::ftell(f); std::fseek(f, 0, SEEK_SET);
  if (n <= 0) { std::fclose(f); return false; }
  out.resize(size_t(n));
  const size_t got = std::fread(out.data(), 1, size_t(n), f);
  std::fclose(f);
  return got == size_t(n);
}

// One 16-bit word into the controller through the preload port.
static bool preload(uint32_t word_addr, uint16_t data) {
  dut->wr_req = 1; dut->wr_addr = word_addr; dut->wr_din = data;
  bool acked = false;
  for (int g = 0; g < 100000; ++g) { step(); if (dut->wr_ack) { acked = true; break; } }
  dut->wr_req = 0;
  for (int g = 0; g < 100000 && dut->wr_ack; ++g) step();
  // R561: AND LOW FOR A WHOLE REQUESTER CYCLE. This loop acts on 5 ns ticks,
  // faster than the clock the requester lives on, and used to raise the next
  // write the tick after the acknowledge fell. m2_sdram_x2 happened to hide
  // that -- its acknowledge stayed up until a fast edge had seen the request
  // fall -- but no RTL requester can do it: every one is a register on its own
  // clock, and m2_wr_arb releases the port with a dead cycle.
  for (int g = 0; g < MEM_DIV; ++g) step();
  return acked;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vm2_cpu_real_harness;

  // ---------------------------------------------------------------- the ROM
  const char *rp = std::getenv("M2_ROMPATH");
  const std::string base = rp ? rp
    : (std::string(std::getenv("HOME") ? std::getenv("HOME") : ".") + "/roms/Model2");
  const std::string dir = base + "/daytona93/";
  std::vector<uint8_t> lo, hi;
  if (!load_file(dir + "epr-16530a.12", lo) || !load_file(dir + "epr-16531a.13", hi)) {
    std::printf("m2_cpu_real: daytona93 program ROMs not found under %s\n", dir.c_str());
    std::printf("SKIP (no ROMs; set M2_ROMPATH to a directory holding daytona93/)\n");
    return 0;
  }
  if (lo.size() != 0x20000 || hi.size() != 0x20000) {
    std::printf("unexpected program ROM sizes %zu/%zu\n", lo.size(), hi.size());
    return 1;
  }

  // ------------------------------------------------------------- bring-up
  dut->clk_cpu = 0; dut->clk_mem = 0; dut->rst_n = 0; dut->cpu_rst_n = 0;
  dut->wr_req = 0; dut->wr_addr = 0; dut->wr_din = 0;
  dut->p2_req = 0; dut->p3_req = 0; dut->irq = 0; dut->io_rdata = 0; dut->io_stall = 0;
  competing = std::getenv("M2_COMPETE") && atoi(std::getenv("M2_COMPETE"));
  if (const char *e = std::getenv("M2_CPU_DIV")) CPU_DIV = atoi(e);
  if (const char *e = std::getenv("M2_MEM_DIV")) MEM_DIV = atoi(e);
  if (const char *e = std::getenv("M2_SD_DIV"))  SD_DIV  = atoi(e);
  VBLANK_TICKS = 434600ULL * CPU_DIV;
  std::printf("m2_cpu_real: clocks in 5 ns ticks -- cpu /%d  bridge /%d  controller /%d\n",
              CPU_DIV, MEM_DIV, SD_DIV ? SD_DIV : MEM_DIV);
  if (const char *tb = std::getenv("M2_TRACE_BUS")) { long f=0,n=0; if (sscanf(tb, "%ld,%ld", &f, &n) == 2) { trace_from = f; trace_n = n; } }
  for (int i = 0; i < 64; ++i) step();
  dut->rst_n = 1;
  { long g = 0; while (!dut->mem_ready && g++ < 4000000) step(); }
  CHECK(dut->mem_ready, "controller never became ready");

  // ROM_LOAD32_WORD: lo supplies bytes 0,1 of each dword and hi bytes 2,3. In
  // 16-bit SDRAM words that is word 2w = lo word w, word 2w+1 = hi word w, and
  // base_prog is 0 in the harness so CPU byte address 0 is SDRAM word 0.
  const uint32_t NW = 0x10000;            // 64K dwords = 256 KB of program ROM
  uint32_t loaded = 0;
  for (uint32_t w = 0; w < NW; ++w) {
    const uint16_t l = uint16_t(lo[w*2] | (lo[w*2+1] << 8));
    const uint16_t h = uint16_t(hi[w*2] | (hi[w*2+1] << 8));
    if (preload(2*w, l)) ++loaded;
    if (preload(2*w + 1, h)) ++loaded;
  }
  CHECK(loaded == 2*NW, "preload: %u of %u words acknowledged", loaded, 2*NW);
  std::printf("m2_cpu_real: %u KB of program ROM in SDRAM after %llu ticks\n",
              loaded / 512, tk);

  // --------------------------------------------------------------- the run
  const long N = std::getenv("M2_INSNS") ? atol(std::getenv("M2_INSNS")) : 100000;
  const unsigned long long QUIET_LIMIT = 400000;   // ticks with no retirement
  dut->cpu_rst_n = 1;

  uint32_t last_acc = dut->dbg_acc_cnt;
  unsigned long long t0 = tk, last_change = tk, worst_quiet = 0;
  uint64_t hash = 1469598103934665603ULL;          // FNV-1a over retired IPs
  uint32_t first_ip = 0; bool got_first = false;
  long retired = 0;
  std::vector<uint8_t> seen(1u << 18, 0); long distinct = 0;   // IPs below 256 KB

  while (retired < N && !dut->halted && !dut->trap) {
    step();
    const uint32_t acc = dut->dbg_acc_cnt;
    if (acc != last_acc) {
      retired += int32_t(acc - last_acc);
      last_acc = acc;
      const uint32_t ip = dut->dbg_ip;
      if (!got_first) { first_ip = ip; got_first = true; }
      hash ^= ip; hash *= 1099511628211ULL;
      if (ip < (1u << 18) && !seen[ip]) { seen[ip] = 1; ++distinct; }
      const unsigned long long quiet = tk - last_change;
      if (quiet > worst_quiet) worst_quiet = quiet;
      last_change = tk;
    } else if (tk - last_change > QUIET_LIMIT) {
      break;                                   // stopped: fall through to the checks
    }
  }
  const unsigned long long cycles = (tk - t0) / CPU_DIV;

  std::printf("  retired %ld instructions in %llu CPU cycles -- %.2f CPI\n",
              retired, cycles, retired ? double(cycles) / double(retired) : 0.0);
  std::printf("  first IP %08x  last IP %08x  %ld distinct IPs  %llu vblanks  longest quiet %llu ticks  trace hash %016llx\n",
              first_ip, dut->dbg_ip, distinct, (unsigned long long)vblanks, worst_quiet, (unsigned long long)hash);
  if (const char *ho = std::getenv("M2_HASH_OUT")) {
    if (FILE *f = std::fopen(ho, "w")) { std::fprintf(f, "%016llx %ld\n", (unsigned long long)hash, retired); std::fclose(f); }
  }

  // THE CHECKS ARE THE SYMPTOMS THE BOARD SHOWED.
  CHECK(!dut->halted, "the CPU halted at IP %08x", dut->dbg_ip);
  CHECK(!dut->trap,   "the CPU trapped at IP %08x", dut->dbg_ip);
  CHECK(retired >= N, "the CPU stopped: %ld of %ld instructions, quiet for %llu ticks at IP %08x "
                      "(bus_req=%d we=%d ack=%d addr=%08x)",
        retired, N, tk - last_change, dut->dbg_ip,
        dut->bus_req, dut->bus_we, dut->bus_ack, dut->bus_addr);
  CHECK(got_first && first_ip == 0x00000860u, "boot IP was %08x, the ROM's record says 00000860", first_ip);

  {
    std::sort(rd_hist.begin(), rd_hist.end(), [](auto &x, auto &y){ return x.second > y.second; });
    std::printf("  top read addresses:\n");
    for (size_t i = 0; i < rd_hist.size() && i < 6; ++i) std::printf("    rd %08x  x%ld\n", rd_hist[i].first, rd_hist[i].second);
  }
  std::printf("  bus transactions seen: %ld (trace window %ld,%ld)\n", bus_n, trace_from, trace_n);
  std::printf("  board-RAM copy fold: %04x over %u writes (the board reports this in z[15:0])\n", bw_fold, bw_cnt);
  std::printf("  R548 CPU cycles: %ld  off the bus %.1f%%\n", acc_cyc, 100.0 * acc_nobus / (acc_cyc ? acc_cyc : 1));
  { long maxl = 0; for (auto &kv : ic_lines) maxl = std::max(maxl, kv.second);
    { std::vector<std::pair<long,uint32_t>> v; for (auto &kv : ic_lines) v.push_back({kv.second, kv.first});
      std::sort(v.rbegin(), v.rend());
      std::printf("    hottest icache lines:"); for (size_t i = 0; i < v.size() && i < 6; ++i) std::printf(" %08x:%ld", v[i].second << 4, v[i].first); std::printf("\n"); }
    std::printf("    icache fill words %ld over %zu distinct lines (%.1f words a line; worst line fetched %ld words)\n",
                ic_words, ic_lines.size(), double(ic_words) / (ic_lines.size() ? ic_lines.size() : 1), maxl); }
  std::printf("    by master (cycles waiting): boot %ld  reg-frame %ld  LSU %ld  icache %ld   | ROM reads: LSU %ld  icache %ld\n",
              mst_wait[1], mst_wait[2], mst_wait[3], mst_wait[4], rom_by_mst[3], rom_by_mst[4]);
  for (int k = 0; k < 5; ++k)
    std::printf("    %-16s %8ld accesses  %9ld cycles waiting  (%5.1f%% of all, %.1f a access)\n", acc_name[k], acc_n[k], acc_wait[k],
                100.0 * acc_wait[k] / (acc_cyc ? acc_cyc : 1), double(acc_wait[k]) / (acc_n[k] ? acc_n[k] : 1));
  std::printf("  the RTL fold Model2.sv uses:  %04x over %u writes\n", dut->rtl_bw_fold, dut->rtl_bw_cnt);
  // R533: the references the board's 'z' records are compared against.
  std::printf("  copy read fold (R533):         %04x\n", dut->rtl_br_fold);
  std::printf("  copy chunk folds (R533):      ");
  for (int i = 0; i < 16; ++i) {
    const int b = i * 12;
    const uint32_t v = (dut->rtl_bw_ck[b / 32] >> (b % 32)
                        | (b % 32 > 20 ? dut->rtl_bw_ck[b / 32 + 1] << (32 - b % 32) : 0)) & 0xfff;
    std::printf(" %x:%03x", i, v);
  }
  std::printf("\n");
  std::printf("  I/O accesses: %ld\n", io_accesses);
  for (auto &e : io_hist) std::printf("    io %08x  x%ld\n", e.first, e.second);
  std::printf("m2_cpu_real: checks=%d fails=%d\n", checks, fails);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete dut;
  return fails ? 1 : 0;
}
