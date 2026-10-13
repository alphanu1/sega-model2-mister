// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// R817: AN INSTRUCTION STREAM THROUGH THE REAL FETCH PATH.
//
// m2_ifetch_replay_harness.sv says why. This file is the sequencer: it walks a
// recorded stream of instruction addresses and drives i960_icache the way
// i960_top's front end does --
//
//   T_FETCH    accept a prefetched word (pf_valid, or pf_armed with the answer
//              landing now), else issue a demand fetch at ip -> T_FETCH_W
//   T_FETCH_W  wait for the cache's answer at fetch_addr (R812's ic_ok)
//   accept     a two-word instruction fetches ip+4 -> T_FETCH2_W; any other
//              predicts sequential: prefetch ip+4 (pf_issued, armed a cycle
//              later, captured when its answer lands) -> T_EXEC
//   T_EXEC     one cycle, plus the load/store's bus transactions (held until
//              acknowledged, as i960_lsu holds them), then the next address
//
// -- and the load/store traffic onto the shared bus through i960_top's grant.
// Every other cycle the real CPU spends (frames, multiply, the register cache)
// is a fixed allowance per opcode class: those cycles change what overlaps a
// fill, not what a fetch costs. The model is checked against the real i960_top
// on the boot (the same stream through both): see the R817 study entry.
//
// The stream: u32 instruction addresses, 0xFFFFFFFF between frames (made from
// MAME's uncollapsed trace, or from tb_m2_cpu_real's M2_IP_OUT). Instruction
// lengths come from the program ROM itself (MEMB modes 5, 12-15 are two
// words). NO ROM BYTE ENTERS THE REPOSITORY: ROMs are read from $M2_ROMPATH.
//
// Environment:
//   M2_STREAM   the stream file (required)
//   M2_SET      daytona (Revision A, default) or daytona93
//   M2_SPIN     comma list of IPs booked as the frame-sync spin (default the
//               Revision A loop, 1394,139c), reported apart from the work
//   M2_LIMIT    instructions to replay (default all)
//   M2_COMPETE  0..100: % of controller cycles ports 2 and 3 ask for the bus
//   M2_MEMEXTRA extra CPU cycles a load/store spends beyond its bus time
//   M2_IPD      in place of M2_STREAM: per instruction its own loads and stores
//               (sim/ifetch/tapconv.py, from MAME's taps)
//   M2_DATA     with M2_STREAM: tb_m2_cpu_real's M2_DA_OUT
//   M2_RTRACE   a cycle trace from instruction n (120 lines)
//   M2_FE       front-end variants (bit mask): 1 = a taken branch's target is
//               prefetched (static prediction: unconditional and backward
//               branches; a model only), 2 = a two-word instruction prefetches
//               the word after its displacement (i960_top's PF2W, R817: the
//               default, as the core is now; M2_FE=0 models R815's)

#include "Vm2_ifetch_replay_harness.h"
#include "Vm2_ifetch_replay_harness___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <unordered_set>
#include <unordered_map>
#include <algorithm>

static Vm2_ifetch_replay_harness *dut;
static const int CPU_DIV = 20, MEM_DIV = 10, SD_DIV = 8;   // 1.25 ns ticks: 40 / 80 / 100 MHz
static unsigned long long tk = 0;
static int compete = 0;
static uint32_t p2a = 0x100000, p3a = 0x200000;
static unsigned rng = 12345;
static unsigned rnd() { rng = rng * 1103515245u + 12345u; return rng >> 8; }

static void drive_traffic_fast() {
  // on controller-clock ticks only: request with probability `compete`
  if (dut->p2_req && dut->p2_ack) { dut->p2_req = 0; p2a = 0x100000 + ((p2a + 4) & 0xffff); }
  else if (!dut->p2_req && compete && int(rnd() % 100) < compete) { dut->p2_addr = p2a; dut->p2_req = 1; }
  if (dut->p3_req && dut->p3_ack) { dut->p3_req = 0; p3a = 0x200000 + ((p3a + 4) & 0xffff); }
  else if (!dut->p3_req && compete && int(rnd() % 100) < compete) { dut->p3_addr = p3a; dut->p3_req = 1; }
}

// One tick. Returns true if a CPU rising edge happened on it.
static bool edge_cpu_now() { return ((tk + 1) % CPU_DIV) == 0; }
static void tick() {
  ++tk;
  const bool c = (tk % CPU_DIV) == 0, m = (tk % MEM_DIV) == 0, sd = (tk % SD_DIV) == 0;
  if (m) drive_traffic_fast();
  if (c || m || sd) {
    if (c) dut->clk_cpu = 0; if (m) dut->clk_mem = 0; if (sd) dut->clk_sd = 0;
    dut->eval();
    if (c) dut->clk_cpu = 1; if (m) dut->clk_mem = 1; if (sd) dut->clk_sd = 1;
    dut->eval();
  }
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

static std::vector<uint32_t> rom;   // program ROM dwords
static uint32_t romw(uint32_t a) {
  if (a >= 0x220000u && a < 0x240000u) a -= 0x200000u;
  const uint32_t i = a >> 2;
  return i < rom.size() ? rom[i] : 0u;
}
static int ilen(uint32_t w) {
  const uint32_t op = w >> 24;
  if (op >= 0x80 && ((w >> 12) & 1)) {
    const uint32_t mode = (w >> 10) & 0xF;
    if (mode == 5 || mode >= 12) return 8;
  }
  return 4;
}
// Bus transactions a MEM-format instruction makes, and whether they are writes.
// lda (0x8C) makes none. ld/st family by opcode: 0x80 ldob, 0x82 stob, 0x84 bx,
// 0x85 balx, 0x86 callx, 0x88 ldos, 0x8A stos, 0x8C lda, 0x90 ld, 0x92 st,
// 0x98 ldl, 0x9A stl, 0xA0 ldt, 0xA2 stt, 0xB0 ldq, 0xB2 stq, 0xC0 ldib,
// 0xC2 stib, 0xC8 ldis, 0xCA stis.
static void mem_ops(uint32_t w, int &n, bool &we) {
  const uint32_t op = w >> 24; n = 0; we = false;
  if (op < 0x80) return;
  switch (op) {
    case 0x80: case 0x88: case 0x90: case 0xC0: case 0xC8: n = 1; break;
    case 0x82: case 0x8A: case 0x92: case 0xC2: case 0xCA: n = 1; we = true; break;
    case 0x98: n = 2; break;  case 0x9A: n = 2; we = true; break;
    case 0xA0: n = 3; break;  case 0xA2: n = 3; we = true; break;
    case 0xB0: n = 4; break;  case 0xB2: n = 4; we = true; break;
    default: n = 0;
  }
}
// Extra cycles beyond T_FETCH + T_EXEC for the opcode classes the real core
// spends longer on: call/ret (the register cache), multiply/divide, FP.
static int extra_cycles(uint32_t w) {
  const uint32_t op = w >> 24;
  if (op == 0x09 || op == 0x0A || op == 0x86) return 4;           // call, ret, callx
  if (op >= 0x70 && op <= 0x75) return 8;                          // mul/div/rem
  if ((op >= 0x67 && op <= 0x6F) || (op >= 0x78 && op <= 0x7F)) return 10;   // FP
  return 0;
}
// Static branch target for front-end variant 1, from the word itself.
static bool static_target(uint32_t ip, uint32_t w, uint32_t &tgt) {
  const uint32_t op = w >> 24;
  if (op >= 0x08 && op <= 0x0B && op != 0x0A) {       // b, call, bal: CTRL, 24-bit disp, word aligned
    int32_t d = int32_t(w << 8) >> 8; d &= ~3;
    tgt = ip + uint32_t(d); return true;
  }
  if (op >= 0x10 && op <= 0x17) {                     // conditional CTRL branches: predict backward taken
    int32_t d = int32_t(w << 8) >> 8; d &= ~3;
    if (d < 0) { tgt = ip + uint32_t(d); return true; }
    return false;
  }
  if (op >= 0x20 && op <= 0x3F) {                     // COBR: 13-bit disp, predict backward taken
    int32_t d = int32_t((w & 0x1FFC) << 19) >> 19;
    if (d < 0) { tgt = ip + uint32_t(d); return true; }
    return false;
  }
  return false;
}


// Where a fetch-wait cycle goes (the same booking as tb_m2_cpu_real's
// IFETCH_PROF), and every fill timed. Needs --public-flat-rw.
#define RP_IC(x) (dut->rootp->m2_ifetch_replay_harness__DOT__u_icache__DOT__##x)
#define RP_BR(x) (dut->rootp->m2_ifetch_replay_harness__DOT__u_mem__DOT__u_bridge__DOT__##x)
enum { K_HIT, K_OTHER, K_GRANT, K_BR_IDLE, K_XIN, K_DC, K_SD, K_XOUT, K_ACK, K_DONE, K_SWEEP, K_N };
static const char *k_name[K_N] = {"cache answering (hit pipeline)", "cache filling ANOTHER line", "bus held by load/store",
  "bridge C_IDLE (lb word / gap)", "request crossing in", "memory side: d-cache", "memory side: SDRAM",
  "answer crossing back", "bridge registering ack", "fill done (S_DONE)", "sweep"};
static unsigned long long k_cyc[K_N], k_other[K_N];
static unsigned long long fl_n = 0, fl_done = 0, fl_ab = 0, fl_first = 0, fl_cpl = 0, fl_first_n = 0, fl_want = 0, fl_want_n = 0;
static unsigned long long fl_sd = 0;   // fills whose first word went to the SDRAM
static bool fl_on = false, fl_seen1 = false, fl_wseen = false, fl_sdq = false; static unsigned long long fl_t0 = 0, now_cyc = 0; static uint32_t fl_base = 0; static int prev_ics = 0;
static int classify(uint32_t fa, int gsel) {
  const int ics = RP_IC(state) & 3; const uint32_t fb = RP_IC(fill_base);
  if (ics == 3) return K_SWEEP;
  if (ics == 0) return K_HIT;
  if (ics == 2) return K_DONE;
  int k;
  const int cph = RP_BR(cph) & 7, stt = RP_BR(st) & 15;
  const bool pend = RP_BR(req_mem) != RP_BR(req_seen), back = RP_BR(ack_cpu) != RP_BR(ack_seen);
  if (gsel == 3) k = K_GRANT;
  else if (cph == 0) k = K_BR_IDLE;
  else if (back) k = K_ACK;
  else if (pend) k = K_XIN;
  else if (stt == 8 || stt == 11) k = K_DC;
  else if (stt == 5 || stt == 4) k = K_SD;
  else if (stt == 0) k = K_XOUT;
  else k = K_SD;
  if ((fa >> 4) != (fb >> 4)) { ++k_other[k]; return K_OTHER; }
  return k;
}
static void fill_track(uint32_t fa, bool fw) {
  ++now_cyc;
  const int ics = RP_IC(state) & 3; const uint32_t fb = RP_IC(fill_base);
  const int gsel = dut->dbg_gsel;
  if (ics == 1 && (prev_ics != 1 || (fl_on && fb != fl_base))) {
    if (fl_on) ++fl_ab;
    fl_on = true; fl_t0 = now_cyc; fl_base = fb; fl_seen1 = false; fl_wseen = false; fl_sdq = false; ++fl_n;
  }
  if (fl_on && ics == 1 && !fl_seen1 && ((RP_BR(st) & 15) == 5)) fl_sdq = true;
  if (fl_on && ics == 1 && dut->dbg_bus_ack && gsel == 4) {
    if (!fl_seen1) { fl_seen1 = true; fl_first += now_cyc - fl_t0; ++fl_first_n; if (fl_sdq) ++fl_sd; }
    if (fw && !fl_wseen && ((fa >> 2) == ((fb >> 2) + (RP_IC(fill_word) & 3)))) { fl_wseen = true; fl_want += now_cyc - fl_t0; ++fl_want_n; }
  }
  if (fl_on && RP_IC(tag_we)) { ++fl_done; fl_cpl += now_cyc - fl_t0; fl_on = false; }
  else if (fl_on && ics != 1) { ++fl_ab; fl_on = false; }
  prev_ics = ics;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vm2_ifetch_replay_harness;

  const char *rp = std::getenv("M2_ROMPATH");
  const std::string base = rp ? rp : (std::string(std::getenv("HOME") ? std::getenv("HOME") : ".") + "/roms/Model2");
  const std::string set = std::getenv("M2_SET") ? std::getenv("M2_SET") : "daytona";
  std::vector<uint8_t> lo, hi;
  const bool d93 = (set == "daytona93");
  if (!load_file(base + "/" + set + (d93 ? "/epr-16530a.12" : "/epr-16722a.12"), lo) ||
      !load_file(base + "/" + set + (d93 ? "/epr-16531a.13" : "/epr-16723a.13"), hi)) {
    std::printf("SKIP (no ROMs under %s/%s)\n", base.c_str(), set.c_str()); return 0;
  }
  const uint32_t NW = uint32_t(std::min(lo.size(), hi.size()) / 2);
  rom.resize(NW);
  for (uint32_t w = 0; w < NW; ++w)
    rom[w] = uint32_t(lo[w*2] | (lo[w*2+1] << 8)) | (uint32_t(hi[w*2] | (hi[w*2+1] << 8)) << 16);

  // M2_STREAM: bare addresses. M2_IPD: per instruction {ip, n, n x {addr|we,
  // byte enables}} -- the game's own loads and stores from MAME's taps.
  const char *sp = std::getenv("M2_STREAM");
  const char *ipd = std::getenv("M2_IPD");
  std::vector<uint8_t> sb;
  if (ipd) sp = ipd;
  if (!sp || !load_file(sp, sb)) { std::printf("M2_STREAM / M2_IPD not readable\n"); return 1; }
  std::vector<uint32_t> st;
  std::vector<uint32_t> st_off;          // M2_IPD: offset of each instruction's records in raw
  std::vector<uint32_t> raw(sb.size() / 4);
  std::memcpy(raw.data(), sb.data(), raw.size() * 4);
  if (ipd) {
    for (size_t i = 0; i + 1 < raw.size(); ) { st.push_back(raw[i]); st_off.push_back(uint32_t(i)); i += 2 + 2 * size_t(raw[i + 1]); }
  } else st = raw;
  std::unordered_set<uint32_t> spin;
  { std::string s = std::getenv("M2_SPIN") ? std::getenv("M2_SPIN") : "1394,139c";
    size_t p = 0; while (p < s.size()) { size_t q = s.find(',', p); if (q == std::string::npos) q = s.size();
      spin.insert(uint32_t(std::strtoul(s.substr(p, q - p).c_str(), nullptr, 16))); p = q + 1; } }
  const long LIMIT = std::getenv("M2_LIMIT") ? atol(std::getenv("M2_LIMIT")) : -1;
  compete = std::getenv("M2_COMPETE") ? atoi(std::getenv("M2_COMPETE")) : 0;
  const int memextra = std::getenv("M2_MEMEXTRA") ? atoi(std::getenv("M2_MEMEXTRA")) : 0;
  // Default 2: i960_top's PF2W (R817), the sequencer as it is now. 0 is R815's.
  const int fe = std::getenv("M2_FE") ? atoi(std::getenv("M2_FE")) : 2;
  // M2_DATA: the real CPU's load/store transactions ({instruction count,
  // address | we} from tb_m2_cpu_real's M2_DA_OUT), used in place of the
  // synthetic ones -- for checking the model against the real core.
  std::vector<uint32_t> da; size_t dk = 0;
  if (const char *df = std::getenv("M2_DATA")) { std::vector<uint8_t> b; if (load_file(df, b)) { da.resize(b.size() / 4); std::memcpy(da.data(), b.data(), da.size() * 4); } }
  std::vector<uint32_t> cur_da, cur_be;
  uint32_t lsu_be = 0xF;

  // ------------------------------------------------------------- bring-up
  dut->clk_cpu = 0; dut->clk_mem = 0; dut->clk_sd = 0; dut->rst_n = 0; dut->cpu_rst_n = 0;
  dut->ic_req = 0; dut->ic_addr = 0; dut->lsu_req = 0; dut->lsu_we = 0; dut->lsu_addr = 0;
  dut->wr_req = 0; dut->p2_req = 0; dut->p3_req = 0;
  for (int i = 0; i < 640; ++i) tick();
  dut->rst_n = 1;
  { long g = 0; while (!dut->mem_ready && g++ < 40000000) tick(); }
  if (!dut->mem_ready) { std::printf("FAIL: controller never ready\n"); return 1; }
  const int saved_compete = compete; compete = 0;
  auto preload = [&](uint32_t wa, uint16_t d) {
    dut->wr_req = 1; dut->wr_addr = wa; dut->wr_din = d;
    for (int g = 0; g < 1000000 && !dut->wr_ack; ++g) tick();
    dut->wr_req = 0;
    for (int g = 0; g < 1000000 && dut->wr_ack; ++g) tick();
    for (int g = 0; g < MEM_DIV; ++g) tick();
  };
  for (uint32_t w = 0; w < NW; ++w) { preload(2*w, uint16_t(rom[w])); preload(2*w + 1, uint16_t(rom[w] >> 16)); }
  compete = saved_compete;
  // the bridge and cache come out of reset; wait out the sweeps
  dut->cpu_rst_n = 1;
  for (int i = 0; i < 4096 * CPU_DIV; ++i) tick();

  // ---------------------------------------------------------- the replay
  enum { T_FETCH, T_FETCH_W, T_FETCH2_W, T_EXEC, T_MEM, T_MEM_W, T_XTRA };
  int ts = T_FETCH;
  size_t k = 0;
  while (k < st.size() && st[k] == 0xffffffffu) ++k;
  uint32_t fetch_addr = 0, pf_ip = 0;
  bool ic_req = false, pf_valid = false, pf_armed = false, pf_issued = false;
  int xtra = 0, mem_left = 0; bool mem_we = false; bool lsu_req = false; uint32_t lsu_addr = 0;
  // accounting
  unsigned long long cyc = 0, n_insn = 0, n_busy = 0, cyc_busy = 0, cyc_spin = 0;
  unsigned long long fw_b = 0, f2w_b = 0, memw_b = 0, fw_s = 0, f2w_s = 0, memw_s = 0;
  unsigned long long frames = 0, pf_hits = 0, n_two = 0, n_taken = 0;
  unsigned long long fills = 0, fill_cyc = 0;
  bool cur_spin = false; unsigned long long insn_t0 = 0;
  bool prev_busy = false;
  std::vector<unsigned long long> frame_busy;
  unsigned long long fb_acc = 0;

  auto next_ip = [&](size_t from) -> size_t {
    size_t j = from + 1;
    while (j < st.size() && st[j] == 0xffffffffu) { ++frames; frame_busy.push_back(fb_acc); fb_acc = 0; ++j; }
    return j;
  };

  unsigned long long last_acc_cyc = 0, last_n = 0; bool hung = false;
  while (k < st.size() && (LIMIT < 0 || long(n_insn) < LIMIT)) {
    { static const long long trf = std::getenv("M2_RTRACE") ? atoll(std::getenv("M2_RTRACE")) : -1; static int trn = 0;
      if (trf >= 0 && (long long)n_insn >= trf && trn < 120) { ++trn;
        std::printf("  c%llu n=%llu ip=%08x ts=%d fa=%08x icreq=%d pf_ip=%08x v%d a%d i%d | st=%d fb=%08x fw=%d want=%d rq=%d hit=%d valid=%d vaddr=%08x breq=%d gsel=%d ack=%d\n",
          cyc, n_insn, st[k], ts, fetch_addr, int(ic_req), pf_ip, pf_valid, pf_armed, pf_issued, int(RP_IC(state)), unsigned(RP_IC(fill_base)), int(RP_IC(fill_word)),
          int(RP_IC(fill_wanted)), int(RP_IC(redir_q)), int(RP_IC(hit)), int(dut->ic_valid), unsigned(dut->ic_vaddr) << 2, int(RP_IC(bus_req)), int(dut->dbg_gsel), int(dut->dbg_bus_ack)); } }
    if (n_insn != last_n) { last_n = n_insn; last_acc_cyc = cyc; }
    else if (cyc - last_acc_cyc > 20000) {
      // THE REPLAY STOPPED: no instruction accepted for 20,000 cycles. On the
      // real CPU that is a hang; report what the cache and the front end hold.
      std::printf("HUNG at instruction %llu ip=%08x ts=%d fetch_addr=%08x pf_ip=%08x pf_valid=%d pf_armed=%d | cache state=%d fill_base=%08x fill_word=%d fill_wanted=%d redir_q=%d valid=%d vaddr=%08x busy=%d\n",
                  n_insn, st[k], ts, fetch_addr, pf_ip, pf_valid, pf_armed, int(RP_IC(state)), unsigned(RP_IC(fill_base)), int(RP_IC(fill_word)),
                  int(RP_IC(fill_wanted)), int(RP_IC(redir_q)), int(dut->ic_valid), unsigned(dut->ic_vaddr) << 2, int(dut->ic_busy));
      hung = true; break;
    }
    // ---- one CPU cycle: compute the next state from this cycle's outputs
    const uint32_t ip = st[k];
    const uint32_t w = romw(ip);
    const int L = ilen(w);
    const bool ic_ok = dut->ic_valid && (uint32_t(dut->ic_vaddr) == (fetch_addr >> 2));
    const bool lack = dut->lsu_ack;
    if (dut->ic_busy && prev_busy) ++fill_cyc;
    prev_busy = dut->ic_busy;

    int ts_n = ts; uint32_t fa_n = fetch_addr, pfip_n = pf_ip;
    bool icr_n = false, pfv_n = pf_valid, pfa_n = pf_issued, pfi_n = false;
    bool lreq_n = lsu_req; uint32_t la_n = lsu_addr;
    if (pf_armed && ic_ok) { pfv_n = true; pfa_n = false; }

    ++cyc;
    if (cur_spin) ++cyc_spin; else { ++cyc_busy; ++fb_acc; }
    fill_track(fetch_addr, ts == T_FETCH_W || ts == T_FETCH2_W);
    if (!cur_spin && (ts == T_FETCH_W || ts == T_FETCH2_W)) ++k_cyc[classify(fetch_addr, dut->dbg_gsel)];
    if (ts == T_FETCH_W) { if (cur_spin) ++fw_s; else ++fw_b; }
    if (ts == T_FETCH2_W) { if (cur_spin) ++f2w_s; else ++f2w_b; }
    if (ts == T_MEM_W || ts == T_MEM) { if (cur_spin) ++memw_s; else ++memw_b; }

    auto finish = [&]() {
      // the instruction is done: on to the next address
      const size_t kn = next_ip(k);
      if (kn < st.size() && st[kn] != ip + uint32_t(L)) ++n_taken;
      k = kn; ts_n = T_FETCH;
    };
    auto accept = [&](bool via_pf) {
      ++n_insn; if (via_pf) ++pf_hits;
      cur_spin = spin.count(ip) != 0; if (!cur_spin) ++n_busy;
      (void)insn_t0;
      pfv_n = false; pfa_n = false;
      if (L == 8) {
        ++n_two;
        fa_n = ip + 4; icr_n = true; ts_n = T_FETCH2_W;
      } else {
        uint32_t tgt = ip + 4;
        if (fe & 1) { uint32_t t2; if (static_target(ip, w, t2)) tgt = t2; }
        fa_n = tgt; icr_n = true; pfip_n = tgt; pfi_n = true;
        ts_n = T_EXEC;
      }
    };

    switch (ts) {
      case T_FETCH: case T_FETCH_W: {
        bool ok, via_pf = false;
        if (ts == T_FETCH) {
          ok = (pf_valid && pf_ip == ip) || (pf_armed && ic_ok && pf_ip == ip);
          via_pf = ok;
        } else ok = ic_ok;
        if (ok) accept(via_pf);
        else if (ts == T_FETCH) { pfv_n = false; pfa_n = false; fa_n = ip; icr_n = true; ts_n = T_FETCH_W; }
        break;
      }
      case T_FETCH2_W:
        if (ic_ok) {
          ts_n = T_EXEC;
          if (fe & 2) { fa_n = ip + 8; icr_n = true; pfip_n = ip + 8; pfi_n = true; }
        }
        break;
      case T_EXEC: {
        int n; bool we; mem_ops(w, n, we);
        xtra = extra_cycles(w);
        cur_da.clear(); cur_be.clear();
        if (ipd) {
          const size_t o = st_off[k]; const uint32_t nn = raw[o + 1];
          for (uint32_t j = 0; j < nn; ++j) { cur_da.push_back(raw[o + 2 + 2*j]); cur_be.push_back(raw[o + 3 + 2*j]); }
          n = int(cur_da.size()); if (n) we = cur_da[0] & 1u;
        } else if (!da.empty()) {
          while (dk + 1 < da.size() && da[dk] < n_insn) dk += 2;
          while (dk + 1 < da.size() && da[dk] == n_insn) { cur_da.push_back(da[dk + 1]); dk += 2; }
          n = int(cur_da.size()); if (n) we = cur_da[0] & 1u;
        }
        if (n) {
          mem_left = n; mem_we = we;
          // synthetic data addresses: work RAM, reads and writes in separate
          // 8 KB regions so the reads stay in the bridge's data cache
          lsu_be = cur_be.empty() ? 0xFu : cur_be[0];
          la_n = !cur_da.empty() ? (cur_da[0] & ~1u)
               : (we ? 0x00504000u : 0x00500000u) + ((ip * 2654435761u) >> 19 & 0x1ff8u);
          lreq_n = true; ts_n = T_MEM_W;
        } else if (xtra) ts_n = T_XTRA;
        else finish();
        break;
      }
      case T_MEM_W:
        if (lack) {
          if (--mem_left == 0) { lreq_n = false; xtra += memextra; if (xtra) ts_n = T_XTRA; else finish(); }
          else if (!cur_da.empty()) { const size_t j = cur_da.size() - size_t(mem_left); la_n = cur_da[j] & ~1u; mem_we = cur_da[j] & 1u; lsu_be = cur_be.empty() ? 0xFu : cur_be[j]; }
          else la_n = lsu_addr + 4;
        }
        break;
      case T_XTRA:
        if (--xtra <= 0) finish();
        break;
    }
    (void)mem_we;

    // ---- the edge: registered outputs change after it
    for (int i = 0; i < CPU_DIV; ++i) {
      const bool c = edge_cpu_now();
      tick();
      if (c) {
        ts = ts_n; fetch_addr = fa_n; pf_ip = pfip_n; ic_req = icr_n;
        pf_valid = pfv_n; pf_armed = pfa_n; pf_issued = pfi_n;
        lsu_req = lreq_n; lsu_addr = la_n;
        dut->ic_req = ic_req; dut->ic_addr = fetch_addr >> 2;
        dut->lsu_req = lsu_req; dut->lsu_we = mem_we; dut->lsu_addr = lsu_addr; dut->lsu_be = lsu_be;
        dut->eval();
      }
    }
    ++fills; (void)fills;
  }
  frame_busy.push_back(fb_acc);

  const double nb = double(n_busy ? n_busy : 1), ns = double((n_insn - n_busy) ? (n_insn - n_busy) : 1);
  std::printf("replay: %s, %llu instructions (%llu busy, %llu spin), %llu frames, compete %d%%, FE %d\n",
              sp, n_insn, n_busy, n_insn - n_busy, frames, compete, fe);
  std::printf("  BUSY: %llu cycles, %.2f a instruction: fetch wait %.2f (T_FETCH_W %.2f, T_FETCH2_W %.2f), load/store %.2f\n",
              cyc_busy, cyc_busy / nb, (fw_b + f2w_b) / nb, fw_b / nb, f2w_b / nb, memw_b / nb);
  std::printf("  SPIN: %llu cycles, %.2f a instruction: fetch wait %.2f, load/store %.2f\n",
              cyc_spin, cyc_spin / ns, (fw_s + f2w_s) / ns, memw_s / ns);
  std::printf("  two-word %.1f%%, taken %.1f%%, prefetch hits %.1f%% of instructions\n",
              100.0 * n_two / double(n_insn), 100.0 * n_taken / double(n_insn), 100.0 * pf_hits / double(n_insn));
  if (frame_busy.size() > 2) {
    std::printf("  busy cycles a frame:");
    for (size_t i = 0; i < frame_busy.size(); ++i) std::printf(" %llu", frame_busy[i]);
    std::printf("\n");
  }
  std::printf("  busy fetch wait by phase (cycles a busy instruction):");
  for (int i = 0; i < K_N; ++i) if (k_cyc[i]) std::printf("\n    %-34s %.3f", k_name[i], k_cyc[i] / nb);
  std::printf("\n    ... the other line's fill was:");
  for (int i = 0; i < K_N; ++i) if (k_other[i]) std::printf(" %s %.3f;", k_name[i], k_other[i] / nb);
  std::printf("\n  fills %llu (%.3f a busy insn): %llu completed, %llu abandoned; first word %.1f cycles (%.0f%% via SDRAM), wanted word %.1f, line %.1f\n",
              fl_n, fl_n / nb, fl_done, fl_ab, fl_first / double(fl_first_n ? fl_first_n : 1), 100.0 * fl_sd / double(fl_first_n ? fl_first_n : 1),
              fl_want / double(fl_want_n ? fl_want_n : 1), fl_cpl / double(fl_done ? fl_done : 1));
  if (hung) std::printf("FAIL: the replay hung\n");
  std::printf("RESULT busy_cpi=%.3f busy_fw=%.3f busy_mem=%.3f spin_cpi=%.3f\n",
              cyc_busy / nb, (fw_b + f2w_b) / nb, memw_b / nb, cyc_spin / ns);
  delete dut;
  return 0;
}
