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


#ifdef IFETCH_PROF
// R817: WHERE AN INSTRUCTION-FETCH WAIT GOES. Bench-only (the profiling build,
// --public-flat-rw): every CPU cycle in T_FETCH_W / T_FETCH2_W is booked by
// what the cache, the i960's bus grant, the bridge and the memory side are
// doing, and every i-cache line fill is timed from its start to its first
// word, to the word the CPU waits for, and to its completion.
//   M2_IP_OUT=f  the retired instruction addresses (u32 each), and
//   M2_DA_OUT=f  every load/store {instruction count, address | we} -- the
//                inputs tb_m2_ifetch_replay needs to replay this run (that is
//                how the replay's sequencer model was checked against this CPU)
//   M2_PTRACE=n  a cycle-by-cycle trace of the front end, cache and bridge from
//                CPU cycle n (4,000 lines)
#define PR_C(x)  (dut->rootp->m2_cpu_real_harness__DOT__u_cpu__DOT__##x)
#define PR_IC(x) (dut->rootp->m2_cpu_real_harness__DOT__u_cpu__DOT__u_icache__DOT__##x)
#define PR_BR(x) (dut->rootp->m2_cpu_real_harness__DOT__u_mem__DOT__u_bridge__DOT__##x)
enum { K_HIT, K_STALE_OTHER, K_GRANT, K_BR_IDLE, K_XIN, K_DC, K_SD, K_XOUT, K_ACK, K_DONE, K_SWEEP, K_N };
static const char *k_name[K_N] = {"cache answering (hit pipeline)", "cache filling ANOTHER line", "bus held by LSU/RF",
  "bridge C_IDLE (lb word / gap)", "request crossing in", "memory side: d-cache", "memory side: SDRAM",
  "answer crossing back", "bridge registering ack", "fill done (S_DONE)", "sweep"};
static unsigned long long k_cyc[2][K_N];         // [0] T_FETCH_W, [1] T_FETCH2_W
static unsigned long long k_stale[K_N];          // sub-phase while the line being filled is NOT the wanted one
static unsigned long long ep_n[2][4], ep_cyc[2][4];   // episodes by outcome: hit, miss, stale-then-hit, stale-then-miss
static unsigned long long fw_total = 0, f2w_total = 0, cpu_cyc_prof = 0, retired_prof = 0, memw_total = 0;
static unsigned long long ts_hist[32];
static int ep_kind = -1; static bool ep_saw_fill = false, ep_saw_stale = false; static unsigned ep_len = 0; static uint32_t ep_addr = 0;
// fills
static unsigned long long fl_start_n = 0, fl_done_n = 0, fl_abandon_n = 0, fl_demand_n = 0;
static unsigned long long fl_first_sum = 0, fl_done_sum = 0, fl_want_sum = 0, fl_want_n = 0;
static std::vector<unsigned> fl_first_hist(256, 0), fl_done_hist(256, 0);
static bool fl_on = false; static unsigned long long fl_t0 = 0; static int fl_words = 0; static uint32_t fl_base = 0;
static bool fl_first_seen = false; static bool fl_want_seen = false; static bool fl_demand = false;
static int prev_ics = 0;
static FILE *ip_out = nullptr; static uint32_t prof_last_acc = 0;
static FILE *da_out = nullptr;   // M2_DA_OUT: {instruction index, address | we} per LSU transaction
static uint32_t da_pend = 0; static bool da_pwe = false;
static void prof_cycle() {
  if (!dut->cpu_rst_n) return;
  ++cpu_cyc_prof;
  const int ts = PR_C(ts) & 31; ++ts_hist[ts];
  const uint32_t fa = PR_C(fetch_addr);
  const int ics = PR_IC(state) & 3;
  const uint32_t fb = PR_IC(fill_base);
  const int gsel = PR_C(gsel) & 7;
  const bool fw = (ts == 1 || ts == 3);
  if (ts == 7) ++memw_total;
  const uint32_t acc = dut->dbg_acc_cnt;
  if (acc != prof_last_acc) { retired_prof += acc - prof_last_acc; prof_last_acc = acc;
    if (ip_out) std::fwrite(&dut->dbg_ip, 4, 1, ip_out); }
  if (da_out && gsel == 3) {
    if (!dut->bus_ack) { da_pend = dut->bus_addr; da_pwe = dut->bus_we; }
    else { const uint32_t rec[2] = { uint32_t(retired_prof), (da_pend & ~1u) | (da_pwe ? 1u : 0u) }; std::fwrite(rec, 4, 2, da_out); }
  }
  // ---- fill timing (the cache's own view)
  if (ics == 1 && (prev_ics != 1 || (fl_on && (fb != fl_base)))) {
    if (fl_on && fb != fl_base) ++fl_abandon_n;          // redirected onto another line
    fl_on = true; fl_t0 = cpu_cyc_prof; fl_base = fb; fl_words = 0; fl_first_seen = false; fl_want_seen = false;
    fl_demand = fw && ((fa >> 4) == (fb >> 4)); ++fl_start_n; if (fl_demand) ++fl_demand_n;
  }
  if (fl_on && ics == 1 && dut->bus_ack && gsel == 4) {
    const unsigned dt = unsigned(cpu_cyc_prof - fl_t0);
    if (!fl_first_seen) { fl_first_seen = true; fl_first_sum += dt; ++fl_first_hist[std::min(dt, 255u)]; }
    if (fw && ((fa >> 2) == ((fb >> 2) + unsigned(PR_IC(fill_word) & 3))) && !fl_want_seen) { fl_want_seen = true; fl_want_sum += dt; ++fl_want_n; }
    ++fl_words;
  }
  if (fl_on && PR_IC(tag_we)) { ++fl_done_n; fl_done_sum += cpu_cyc_prof - fl_t0; ++fl_done_hist[std::min<unsigned long long>(cpu_cyc_prof - fl_t0, 255)]; fl_on = false; }
  if (fl_on && ics != 1) { ++fl_abandon_n; fl_on = false; }   // left S_FILL without writing its tag: abandoned
  prev_ics = ics;
  { static long tr_from = std::getenv("M2_PTRACE") ? atol(std::getenv("M2_PTRACE")) : -1; static long tr_n = 0;
    if (tr_from >= 0 && (long)cpu_cyc_prof >= tr_from && tr_n < 4000) { ++tr_n;
      std::printf("    c%-8llu ts=%2d ip=%08x fa=%08x icreq=%d ics=%d fb=%08x fw=%d hit=%d v=%d va=%08x | gsel=%d breq=%d ack=%d ba=%08x cph=%d st=%d\n",
        cpu_cyc_prof, ts, dut->dbg_ip, fa, (int)PR_C(ic_req), ics, fb, (int)PR_IC(fill_word), (int)PR_IC(hit), (int)PR_IC(valid), (unsigned)PR_IC(req_addr_q) << 2,
        gsel, (int)dut->bus_req, (int)dut->bus_ack, dut->bus_addr, (int)PR_BR(cph), (int)PR_BR(st)); } }
  // ---- the fetch-wait cycle
  if (fw) {
    if (ts == 1) ++fw_total; else ++f2w_total;
    int k;
    const bool want_fill = (ics == 1) && ((fa >> 4) == (fb >> 4));
    if (ics == 3) k = K_SWEEP;
    else if (ics == 0) k = K_HIT;
    else if (ics == 2) k = K_DONE;
    else {
      const int cph = PR_BR(cph) & 7;
      const int st  = PR_BR(st) & 15;
      const bool pend = PR_BR(req_mem) != PR_BR(req_seen);
      const bool back = PR_BR(ack_cpu) != PR_BR(ack_seen);
      if (gsel != 4 && gsel != 0) k = K_GRANT;
      else if (cph == 0) k = K_BR_IDLE;
      else if (back) k = K_ACK;
      else if (pend) k = K_XIN;
      else if (st == 8 || st == 11) k = K_DC;          // S_DCK, S_DCN
      else if (st == 5 || st == 4) k = K_SD;           // S_RDB, S_HI_W
      else if (st == 0) k = K_XOUT;                    // done on the memory side, ack crossing
      else k = K_SD;
    }
    if (ics == 1 && !want_fill) { ++k_stale[k]; ep_saw_stale = true; k = K_STALE_OTHER; }
    if (want_fill) ep_saw_fill = true;
    ++k_cyc[ts == 3][k];
    if (ep_len == 0) { ep_addr = fa; ep_kind = (ts == 3); }
    ++ep_len;
  }
  if (ep_len && (!fw || PR_C(fetch_addr) != ep_addr)) {
    const int o = ep_saw_fill ? (ep_saw_stale ? 3 : 1) : (ep_saw_stale ? 2 : 0);
    ++ep_n[ep_kind][o]; ep_cyc[ep_kind][o] += ep_len;
    ep_len = 0; ep_saw_fill = ep_saw_stale = false;
  }
}
static void prof_report() {
  const double c = double(cpu_cyc_prof), n = double(retired_prof ? retired_prof : 1);
  std::printf("  IFETCH PROFILE: %llu CPU cycles, %llu instructions, CPI %.2f\n", cpu_cyc_prof, retired_prof, c / n);
  std::printf("    T_FETCH_W %llu (%.1f%%, %.2f/insn)  T_FETCH2_W %llu (%.1f%%, %.2f/insn)  T_MEM_W %.1f%% (%.2f/insn)\n",
              fw_total, 100.0 * fw_total / c, fw_total / n, f2w_total, 100.0 * f2w_total / c, f2w_total / n,
              100.0 * memw_total / c, memw_total / n);
  const char *on[4] = {"hit", "miss (filled the wanted line)", "another line's fill, then hit", "another line's fill, then miss"};
  for (int w = 0; w < 2; ++w) for (int o = 0; o < 4; ++o)
    if (ep_n[w][o]) std::printf("    %s episodes %-32s %9llu  %10llu cycles  %.2f each  (%.3f/insn)\n", w ? "T_FETCH2_W" : "T_FETCH_W ",
                                on[o], ep_n[w][o], ep_cyc[w][o], double(ep_cyc[w][o]) / ep_n[w][o], ep_cyc[w][o] / n);
  std::printf("    fetch-wait cycles by phase (T_FETCH_W + T_FETCH2_W):\n");
  for (int k = 0; k < K_N; ++k) { const unsigned long long v = k_cyc[0][k] + k_cyc[1][k];
    if (v) std::printf("      %-34s %10llu  %5.1f%% of fetch wait  %.3f/insn\n", k_name[k], v, 100.0 * v / double(fw_total + f2w_total), v / n); }
  std::printf("    ... of 'cache filling ANOTHER line', what that fill was doing:\n");
  for (int k = 0; k < K_N; ++k) if (k_stale[k]) std::printf("      %-34s %10llu\n", k_name[k], k_stale[k]);
  std::printf("    fills: %llu started (%llu with the CPU waiting on them), %llu completed, %llu abandoned\n",
              fl_start_n, fl_demand_n, fl_done_n, fl_abandon_n);
  std::printf("    fill latency: first word %.1f cycles avg, wanted word %.1f (n=%llu), line complete %.1f (CPU cycles)\n",
              fl_first_sum / double(fl_start_n ? fl_start_n : 1), fl_want_sum / double(fl_want_n ? fl_want_n : 1), fl_want_n,
              fl_done_sum / double(fl_done_n ? fl_done_n : 1));
  std::printf("    first-word latency histogram:");
  for (int i = 0; i < 64; ++i) if (fl_first_hist[i]) std::printf(" %d:%u", i, fl_first_hist[i]);
  std::printf("\n    line-complete histogram:");
  for (int i = 0; i < 80; ++i) if (fl_done_hist[i]) std::printf(" %d:%u", i, fl_done_hist[i]);
  std::printf("\n    sequencer states:");
  static const char *tsn[] = {"FETCH","FETCH_W","FETCH2","FETCH2_W","DECODE","EXEC","MEM","MEM_W","MULDIV","MULTI","PAIR","FP","WB","FRAME","TRAP","BOOT","SYNRD","SYNWR","INTR","RET7","MODPC","SYNQ"};
  for (int i = 0; i < 22; ++i) if (ts_hist[i]) std::printf(" %s %.2f", tsn[i], ts_hist[i] / n);
  std::printf("  (cycles/insn)\n");
}
#endif

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
#ifdef IFETCH_PROF
    if (c) prof_cycle();
#endif
    return;
  }
  if ((tk % CPU_DIV) == 0) { dut->clk_cpu = 0; dut->eval(); }
  if ((tk % MEM_DIV) == 0) { dut->clk_mem = 0; dut->eval(); }
  if ((tk % CPU_DIV) == 0) { dut->clk_cpu = 1; dut->eval(); }
  if ((tk % MEM_DIV) == 0) { dut->clk_mem = 1; dut->eval(); }
  note_reads();          // R530: after the edges, so bus_* are this tick's values
  if ((tk % CPU_DIV) == 0) cpu_account();   // R548
#ifdef IFETCH_PROF
  if ((tk % CPU_DIV) == 0) prof_cycle();
#endif
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
#ifdef IFETCH_PROF
  if (const char *f = std::getenv("M2_IP_OUT")) ip_out = std::fopen(f, "wb");
  if (const char *f = std::getenv("M2_DA_OUT")) da_out = std::fopen(f, "wb");
#endif

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
#ifdef IFETCH_PROF
  prof_report();
  if (ip_out) std::fclose(ip_out);
  if (da_out) std::fclose(da_out);
#endif
  std::printf("  I/O accesses: %ld\n", io_accesses);
  for (auto &e : io_hist) std::printf("    io %08x  x%ld\n", e.first, e.second);
  std::printf("m2_cpu_real: checks=%d fails=%d\n", checks, fails);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete dut;
  return fails ? 1 : 0;
}
