// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// R924: tb_tgpx4_replay -- a captured 2C session (MAME 0.289, R924_CAP) replayed
// through m2_copro built as the 2C board (TGPX4=1), with MAME's own MB86235
// interpreter (sim/tgpx4/mame, verbatim) in LOCKSTEP.
//
// THE i960. The bench walks the capture's i960-side events in order -- copro_ctl1
// writes (C), the program upload (U), FIFO and function-port pushes (I / N) and
// output-FIFO reads (X) -- each presented on m2_copro's bus and held while it
// raises `stall`, exactly as m2_cpu_bridge holds the CPU. So the TGPx4 waits only
// for what the i960 really had not yet sent, and every word it produces is read
// in the order MAME's i960 read it: each X is checked, word for word.
//
// THE LOCKSTEP. Every word the RTL accepts (tgpx4_core's dbg_retire, the clock
// after the accept) completes the word before it; the reference then executes
// that word and the whole architectural state is compared -- the 32 ALU /
// multiplier registers, AR0-7, ST, EB, EO, SP, MOD, LPC, RPC, PRP, PWP, the PR
// queue, PDR, DDR, the PC stack -- and the accepted word's address against the
// reference's next pc. RAM A / B are compared every --ram-every words. The
// reference runs CLEAN (a word waits for its input; MAME's replayed stall pass
// is not modelled -- R924 measured it changes nothing in House of the Dead).
// Its FIFO input is the capture's pop stream; its external reads the dumped ROM.
//
// THE MEMORIES. Port 9 and the write port are answered after --lat clocks (plus
// 0..--jitter, seeded): the data ROM from cdata.bin, buffer RAM from a model
// (MAME's power-on 0x07800f0f), the program copy from what the upload wrote.
//
// R933: THE FRAMES. MAME's i960 makes its FIFO pushes over time, and the
// TGPx4's CLRF (which empties both FIFOs, now wired) throws away whatever is
// queued at that moment -- so presenting every i960 event as fast as the bus
// takes it can queue a push MAME made a frame later in front of the clear
// (STCC pushes 0x1a at boot and 0x23 ten seconds later; the clear falls
// between). Each capture vblank (F) before an i960 event is therefore passed
// only once the TGPx4 has sat waiting on an empty input FIFO for --idle
// clocks (the frame's work done), or after a frame's worth of clocks
// (--frame, 80 MHz / 57.5 = 1,391,304). --no-frames presents events as before.
//
// R1005: THE i960 PACED (--tm). The bench above presents the i960's accesses as
// fast as the bus takes them, so it measures the TGPx4 alone. With --tm <dir>
// (sim/tgpx4/tm_gaps.py: MAME's own i960 time between consecutive copro
// accesses, from tools/mame_stcc_timing.lua's taps, aligned to the capture)
// each access from frame --tm-from on is presented no earlier than the last
// one's completion plus MAME's gap times --tm-scale (the core's i960 time per
// MAME i960 time), and each game frame starts at the first vblank edge after
// the last frame's flip -- the game's own pacing (it flips, then spins until
// the frame-parity bit at 0x98000c changes). One line per frame to --flog:
// the frame's work from its vblank to its flip, how many vblanks it took, and
// where the time went: the i960's own (scaled) time, the i960 held on a full
// input FIFO, the i960 held waiting for an output, TGPx4 words. Clocks in which
// the TGPx4 sits on an empty input FIFO with nothing on its memory ports, and
// the i960 has time still to spend, are skipped rather than simulated.
//
//   Vm2_copro <capdir> [--lat N] [--jitter N] [--seed N] [--max-words N]
//             [--max-cyc M] [--ram-every N] [--no-lockstep] [--quiet]
//             [--no-frames] [--idle N] [--frame N]
//             [--tm DIR --tm-scale S --tm-from F --flog FILE --vbl N --tm-to F]
//             [--pcprof FILE]
// --pcprof: each word's own clocks (accept to accept, less the clocks it sat in
// S_DEC on an empty input or full output FIFO), summed by program address --
// the RTL's cost table for a model of the TGPx4 (R1005). Without --tm, --flog
// gets one line per vblank passed: the TGPx4's busy clocks in it and its words.
#include "Vm2_copro.h"
#include "Vm2_copro___024root.h"
#include "verilated.h"
#include "mame/mb86235.h"
#include "cap.h"
#include "x4_xdec.h"
#include <cinttypes>
#include <random>

#define C(x) (top->rootp->m2_copro__DOT__g_tgpx4__DOT__u_x4__DOT__u_core__DOT__##x)
// R1006: the register file in two banks of 16, two read copies each: A = AA / AB, M = MA / MB
#define RFA(n, i) (top->rootp->m2_copro__DOT__g_tgpx4__DOT__u_x4__DOT__u_core__DOT__g_rfa__BRA__##n##__KET____DOT__u_rf__DOT__mem[i])
#define RFM(n, i) (top->rootp->m2_copro__DOT__g_tgpx4__DOT__u_x4__DOT__u_core__DOT__g_rfm__BRA__##n##__KET____DOT__u_rf__DOT__mem[i])

static Vm2_copro *top;
static uint64_t cyc = 0;

int main(int argc, char **argv)
{
  Verilated::commandArgs(argc, argv);
  if (argc < 2) { fprintf(stderr, "usage: Vm2_copro <capdir> [options]\n"); return 2; }
  std::string dir = argv[1];
  int lat = 6, jitter = 0; unsigned seed = 1;
  uint64_t max_words = UINT64_MAX, max_cyc = UINT64_MAX, ram_every = 4096;
  bool lockstep = true, quiet = false;
  bool frames_on = true; uint64_t idle_need = 64, frame_cyc = 1391304;   // R933
  std::string tm_dir, flog_path, pcprof_path; double tm_scale = 1.0;    // R1005
  bool stprof = false;                                                  // R1006
  uint32_t ck_frame = UINT32_MAX;                                       // R1006: checkpoint start
  uint32_t tm_from = UINT32_MAX, tm_to = UINT32_MAX; uint64_t vbl_cyc = 1391304;
  bool no_hi = false;   // R1010
  for (int i = 2; i < argc; i++) {
    std::string a = argv[i];
    auto nx = [&]() { return (i + 1 < argc) ? strtoull(argv[++i], nullptr, 0) : 0ull; };
    if (a == "--lat") lat = int(nx());
    else if (a == "--jitter") jitter = int(nx());
    else if (a == "--seed") seed = unsigned(nx());
    else if (a == "--max-words") max_words = nx();
    else if (a == "--max-cyc") max_cyc = nx() * 1000000ull;
    else if (a == "--ram-every") ram_every = nx();
    else if (a == "--no-lockstep") lockstep = false;
    else if (a == "--quiet") quiet = true;
    else if (a == "--no-frames") frames_on = false;      // R933
    else if (a == "--idle") idle_need = nx();
    else if (a == "--frame") frame_cyc = nx();
    else if (a == "--tm") tm_dir = argv[++i];                         // R1005
    else if (a == "--tm-scale") tm_scale = strtod(argv[++i], nullptr);
    else if (a == "--tm-from") tm_from = uint32_t(nx());
    else if (a == "--tm-to") tm_to = uint32_t(nx());
    else if (a == "--flog") flog_path = argv[++i];
    else if (a == "--vbl") vbl_cyc = nx();
    else if (a == "--pcprof") pcprof_path = argv[++i];
    else if (a == "--stprof") stprof = true;                          // R1006
    else if (a == "--ck-frame") ck_frame = uint32_t(nx());            // R1006
    else if (a == "--no-hi") no_hi = true;                            // R1010: serve the ROM as the core did before (bit 20 dropped)
  }
  Capture cap;
  if (!cap.load(dir, 0)) return 2;
  std::mt19937 rng(seed);

  // ---- the reference
  mb86235_device ref;
  memcpy(ref.prog, cap.prog, sizeof ref.prog);
  ref.reset();
  std::vector<uint32_t> pops;
  for (size_t i = cap.boot_ev; i < cap.ev.size(); i++) if (cap.ev[i].t == 'P') pops.push_back(cap.ev[i].b);
  size_t rpop = 0; bool ref_end = false;
  uint64_t ref_outs = 0;
  ref.fin.empty = [&]() { if (rpop >= pops.size()) { ref_end = true; return true; } return false; };
  ref.fin.full = []() { return false; };
  ref.fin.pop_fn = [&]() { return pops[rpop++]; };
  ref.fout.empty = []() { return true; };
  ref.fout.full = []() { return false; };
  ref.fout.push_fn = [&](uint32_t) { ref_outs++; };
  std::vector<uint32_t> bufram(0x8000, 0x07800f0f);
  ref.m_external.rd = [&](uint32_t a) -> uint32_t {
    if (a >= 0x800000 && a < 0xa00000) return cap.rom(a);
    if (a >= 0x400000 && a < 0x800000) return bufram[a & 0x7fff];
    return 0;
  };
  ref.m_external.wr = [&](uint32_t, uint32_t) {};

  // ---- the RTL
  top = new Vm2_copro;
  std::vector<uint16_t> progcopy(0x4000, 0xffff);   // unwritten memory reads 0xFFFF
  std::vector<uint16_t> bufh(0x10000);
  for (int i = 0; i < 0x8000; i++) { bufh[2 * i] = 0x0f0f; bufh[2 * i + 1] = 0x0780; }
  auto lat_now = [&]() { return lat + (jitter ? int(rng() % (jitter + 1)) : 0); };
  int dat_cnt = -1, bufw_cnt = -1;

  auto tick = [&]() {
    top->clk = 0; top->eval();
    // memory answers, presented before the rising edge
    top->dat_ack = 0; top->bufw_ack = 0; top->tbl_ack = 0;
    if (top->dat_req) {
      if (dat_cnt == -1) dat_cnt = lat_now();
      if (dat_cnt == 0) {
        uint32_t a = top->dat_addr, v;
        if (top->dat_is_prog) v = progcopy[(2 * a) & 0x3fff] | (uint32_t(progcopy[(2 * a + 1) & 0x3fff]) << 16);
        else if (top->dat_is_buf) v = bufh[(2 * a) & 0xffff] | (uint32_t(bufh[(2 * a + 1) & 0xffff]) << 16);
        else {   // R1010: dat_hi is the copro data ROM's dword bit 20 (an 8 MB region)
          const uint32_t ra = a | (no_hi ? 0u : uint32_t(top->dat_hi) << 20);
          v = (ra < cap.cdata.size()) ? cap.cdata[ra] : 0;
        }
        top->dat_rdata = v; top->dat_ack = 1; dat_cnt = -2;
      } else if (dat_cnt > 0) dat_cnt--;
    } else dat_cnt = -1;
    if (top->bufw_req) {
      if (bufw_cnt == -1) bufw_cnt = lat_now();
      if (bufw_cnt == 0) {
        uint32_t a = top->bufw_addr;
        if (top->bufw_is_prog) progcopy[a & 0x3fff] = top->bufw_data;
        else bufh[a & 0xffff] = top->bufw_data;
        top->bufw_ack = 1; bufw_cnt = -2;
      } else if (bufw_cnt > 0) bufw_cnt--;
    } else bufw_cnt = -1;
    top->eval();
    top->clk = 1; top->eval();
    cyc++;
  };

  top->rst_n = 0; top->sel_ctl = 0; top->sel_fifo = 0; top->sel_fn = 0; top->sel_fifoctl = 0; top->we = 0;
  for (int i = 0; i < 5; i++) tick();
  top->rst_n = 1;
  for (int i = 0; i < 5; i++) tick();

  // ---- the i960's events
  std::vector<const CapEv *> cpu;
  std::vector<uint32_t> fbefore;   // R933: capture vblanks before each i960 event
  std::vector<uint8_t> postboot;   //        and whether it came after the boot
  { uint32_t nf = 0; size_t i = 0;
    for (auto &e : cap.ev) {
      if (e.t == 'F') nf++;
      if (e.t == 'C' || e.t == 'U' || e.t == 'I' || e.t == 'N' || e.t == 'X') {
        cpu.push_back(&e); fbefore.push_back(nf); postboot.push_back(i > cap.boot_ev);
      }
      i++;
    } }
  // R1006: THE CHECKPOINT START (--ck-frame N). The first capture vblank at or
  // after N at which MAME's two FIFOs are empty is found; the reference runs
  // (as in the lockstep) up to the first word after it that reads the input
  // FIFO, and that word must not sit in a delay slot or a repeat, and the
  // reference must have pushed no output the i960 had not read by then. The
  // RTL boots as usual; at its first idle clock it is restarted at that word
  // (tgpx4_core's dbg_restart), the reference's state written into it, and
  // the i960's events resume after that vblank.
  size_t ck_ie = SIZE_MAX; uint32_t ck_pc = 0, ck_fnum = 0; bool ck_done = false;
  if (ck_frame != UINT32_MAX) {
    // pushes discarded by CLRF: align the pops with the pushes by value (x4_pace_model's way)
    std::vector<uint32_t> pushv, popv;
    for (size_t i = cap.boot_ev + 1; i < cap.ev.size(); i++) {
      if (cap.ev[i].t == 'I' || cap.ev[i].t == 'N') pushv.push_back(cap.ev[i].b);
      if (cap.ev[i].t == 'P') popv.push_back(cap.ev[i].b);
    }
    long poff = -1;
    for (long k = 0; k < 8 && poff < 0; k++) {
      bool ok = true; size_t n = std::min<size_t>(popv.size(), 200000);
      for (size_t j = popv.size() - n; j < popv.size() && ok; j++) if (j + k >= pushv.size() || pushv[j + k] != popv[j]) ok = false;
      if (ok) poff = k;
    }
    if (poff < 0) { printf("CK: cannot align pops with pushes\n"); return 2; }
    uint64_t npush = 0, npop = 0, nout = 0, nxr = 0; uint32_t nf = 0; size_t found = SIZE_MAX;
    for (size_t i = cap.boot_ev + 1; i < cap.ev.size() && found == SIZE_MAX; i++) {
      const CapEv &e = cap.ev[i];
      switch (e.t) { case 'I': case 'N': npush++; break; case 'P': npop++; break; case 'O': nout++; break; case 'X': nxr++; break; default: break; }
      if (e.t != 'F') continue;
      nf = e.a;
      if (nf < ck_frame || npop + uint64_t(poff) != npush || nout != nxr) continue;
      // run the reference up to the first word that reads the input FIFO after pop npop
      bool bad = false;
      while (!ref_end) {
        if (rpop > npop) { bad = true; break; }
        if (rpop == npop && !ref.m_core->delay_slot) {
          Xd x = xdec(ref.prog[ref.m_core->pc & 0xfff]);
          bool rfi = false;
          for (int m = 0; m < 2; m++) if (x.sk[m] == K_REG && x.sc[m] == 0x31) rfi = true;
          if (rfi) break;
        }
        ref.execute_one();
      }
      if (bad || ref_end) { printf("CK: lost the reference at frame %u\n", nf); return 2; }
      if (ref_outs != nout || (ref.m_core->st & 0x4000)) continue;   // an unread output, or a repeat: try the next vblank
      found = i; ck_pc = ref.m_core->pc & 0xfff; ck_fnum = nf;
    }
    if (found == SIZE_MAX) { printf("CK: no checkpoint at or after frame %u\n", ck_frame); return 2; }
    for (size_t k = 0; k < cpu.size(); k++) if (cpu[k] > &cap.ev[found]) { ck_ie = k; break; }
    printf("CK: frame %u (capture event %zu): pc %03x, pops %zu, outputs %" PRIu64 ", i960 event %zu of %zu\n",
           ck_fnum, found, ck_pc, rpop, ref_outs, ck_ie, cpu.size());
  }
  // R1005: MAME's i960 gaps, one record per entry of `cpu`
  struct TmRec { double gap; uint32_t frame, flags; };
  std::vector<TmRec> tmg; std::vector<double> tml, tmw;
  if (!tm_dir.empty()) {
    std::vector<uint8_t> b;
    if (!Capture::rd_all(tm_dir + "/tmg.bin", b) || b.size() / 16 != cpu.size()) {
      fprintf(stderr, "tmg.bin: %zu records, the capture has %zu i960 events\n", b.size() / 16, cpu.size()); return 2; }
    tmg.resize(cpu.size()); memcpy(tmg.data(), b.data(), cpu.size() * 16);
    b.clear(); Capture::rd_all(tm_dir + "/tml.bin", b);
    tml.resize(b.size() / 16); tmw.resize(b.size() / 16);
    for (size_t i = 0; i < tml.size(); i++) { memcpy(&tml[i], &b[i * 16], 8); memcpy(&tmw[i], &b[i * 16 + 8], 8); }
    printf("R1005: %zu gaps, %zu frames, scale %.3f, paced from frame %u\n", tmg.size(), tml.size(), tm_scale, tm_from);
  }
  FILE *flog = flog_path.empty() ? nullptr : fopen(flog_path.c_str(), "w");
  if (flog) fprintf(flog, "# frame vstart work_clk vblanks cpu_clk held_in_clk held_out_clk words events mame_work_s\n");
  auto paced = [&](size_t k) { return !tmg.empty() && k < tmg.size() && tmg[k].frame >= tm_from && tmg[k].frame < tm_to; };
  bool tm_has_e = false; uint64_t tm_e = 0, tm_done = 0, tm_v = 0, tm_v0 = 0;
  uint32_t tm_f = UINT32_MAX;
  uint64_t tf_cpu = 0, tf_hin = 0, tf_hout = 0, tf_w0 = 0, tf_ev = 0, tm_pres = 0, tm_skip = 0;
  uint64_t tm_frames = 0, tm_over = 0, tm_hist[5] = {};
  auto sc = [&](double sec) { return uint64_t(sec * 80e6 * tm_scale + 0.5); };
  uint32_t fdone = 0; uint64_t idle_run = 0, fstart = 0, gate_cyc = 0, fpassed_idle = 0, fpassed_cap = 0;
  size_t ie = 0;
  uint64_t xs = 0, xbad = 0, words = 0, lbad = 0, frames = 0;
  bool active = false;

  auto field = [&](const char *n, uint32_t rtl, uint32_t rf) {
    if (rtl != rf) { if (lbad < 30) printf("  %-6s rtl %08x ref %08x\n", n, rtl, rf); return 1; }
    return 0;
  };
  auto compare = [&](uint64_t w) -> int {
    const auto *c = ref.m_core;
    int bad = 0;
    char n[16];
    for (int i = 0; i < 8; i++) {
      // R1006: bank A {sel1, n} = AA / AB, bank M = MA / MB; both copies
      snprintf(n, sizeof n, "MA%d", i); bad += field(n, RFM(0, i), c->ma[i]);     bad += field(n, RFM(1, i), c->ma[i]);
      snprintf(n, sizeof n, "AA%d", i); bad += field(n, RFA(0, i), c->aa[i]);     bad += field(n, RFA(1, i), c->aa[i]);
      snprintf(n, sizeof n, "MB%d", i); bad += field(n, RFM(0, 8 + i), c->mb[i]); bad += field(n, RFM(1, 8 + i), c->mb[i]);
      snprintf(n, sizeof n, "AB%d", i); bad += field(n, RFA(0, 8 + i), c->ab[i]); bad += field(n, RFA(1, 8 + i), c->ab[i]);
      snprintf(n, sizeof n, "AR%d", i); bad += field(n, C(ar)[i], c->ar[i]);
    }
    // the accept has applied the next word's repeat step; the reference
    // applies it when it fetches that word
    uint32_t rst = c->st, rrpc = c->rpc;
    if (!c->delay_slot && (c->st & 0x4000)) { rrpc = c->rpc - 1; if (rrpc == 1) rst &= ~0x4000u; }
    bad += field("ST", C(st), rst);
    bad += field("RPC", C(rpc), rrpc & 0xffff);
    bad += field("EB", C(eb), c->eb & 0xffffff);
    bad += field("EO", C(eo), c->eo & 0xffffff);
    bad += field("SP", C(sp), c->sp & 0x3ff);
    bad += field("MOD", C(modr), c->mod & 0xffff);
    bad += field("LPC", C(lpc), c->lpc & 0xffff);
    bad += field("PRP", C(prp), c->prp);
    bad += field("PWP", C(pwp), c->pwp);
    for (int i = 0; i < 24; i++) { snprintf(n, sizeof n, "PR%d", i); bad += field(n, C(prq)[i], c->pr[i]); }
    bad += field("PDR", C(pdr), c->pdr);
    bad += field("DDR", C(ddr), c->ddr);
    bad += field("PCP", C(pcp), c->pcp & 3);
    for (int i = 0; i < 4; i++) { snprintf(n, sizeof n, "PCS%d", i); bad += field(n, C(pcs)[i], c->pcs[i] & 0xfff); }
    uint32_t npc = c->delay_slot ? c->pc : c->pc;   // the next word's address (pc; a delay slot's own pc)
    bad += field("PC", C(ir_pc), npc & 0xfff);
    if (ram_every && (w % ram_every) == 0) {
      for (int i = 0; i < 1024; i++) {
        if (C(ram_a)[i] != ref.m_dataa.m[i]) { snprintf(n, sizeof n, "A[%03x]", i); bad += field(n, C(ram_a)[i], ref.m_dataa.m[i]); }
        if (C(ram_b)[i] != ref.m_datab.m[i]) { snprintf(n, sizeof n, "B[%03x]", i); bad += field(n, C(ram_b)[i], ref.m_datab.m[i]); }
      }
    }
    return bad;
  };

  uint32_t last_pc[16] = {}; int lp = 0;
  std::vector<uint64_t> pp_n(4096), pp_c(4096); uint64_t pp_last = 0, pp_wait = 0; uint32_t pp_pc = 0; bool pp_have = false;   // R1005
  uint64_t uf_w0 = 0;
  uint64_t st_hist[16] = {}, st_fifo = 0, st_extr = 0, st_extw = 0;   // R1006
  uint64_t ls_cmp = 0, ls_skip = 0, st_hz = 0, st_hzk[5] = {};                                     // R1006: lockstep compares made / not
  int pend = 0;          // an access is on the bus
  const CapEv *cur = nullptr;
  bool done = false;
  while (!done) {
    // R1006: the checkpoint start, at the RTL's first idle clock after its boot
    if (ck_ie != SIZE_MAX && !ck_done && !pend && ie < cpu.size() && postboot[ie]) {
      if (C(s) == 2 && C(dec_stall) && C(nx_v) && C(ops_idle) && !top->dat_req && !top->bufw_req) {
        C(dbg_restart) = 1; C(dbg_restart_pc) = ck_pc;
        tick();
        C(dbg_restart) = 0;
        // the FIFO clear lands a clock after the restart: no push before it; the
        // NOP's own end (its retire) may fall in these clocks
        bool ck_ret = false;
        tick(); ck_ret |= C(dbg_retire) != 0; tick(); ck_ret |= C(dbg_retire) != 0;
        const auto *c = ref.m_core;
        for (int i = 0; i < 8; i++) {
          RFA(0, i) = RFA(1, i) = c->aa[i]; RFA(0, 8 + i) = RFA(1, 8 + i) = c->ab[i];
          RFM(0, i) = RFM(1, i) = c->ma[i]; RFM(0, 8 + i) = RFM(1, 8 + i) = c->mb[i];
          C(ar)[i] = c->ar[i] & 0x3fff;
        }
        C(st) = c->st; C(rpc) = c->rpc & 0xffff; C(lpc) = c->lpc & 0xffff; C(eb) = c->eb & 0xffffff; C(eo) = c->eo & 0xffffff;
        C(sp) = c->sp & 0x3ff; C(modr) = c->mod & 0xffff; C(pdr) = c->pdr; C(ddr) = c->ddr; C(prp) = c->prp; C(pwp) = c->pwp;
        C(pcp) = c->pcp & 3; for (int i = 0; i < 4; i++) C(pcs)[i] = c->pcs[i] & 0xfff;
        for (int i = 0; i < 24; i++) C(prq)[i] = c->pr[i];
        for (int i = 0; i < 1024; i++) { C(ram_a)[i] = ref.m_dataa.m[i]; C(ram_b)[i] = ref.m_datab.m[i]; }
        ie = ck_ie; fdone = fbefore[ie]; fstart = cyc; idle_run = 0; active = ck_ret; ck_done = true;
        printf("CK: restarted at cycle %" PRIu64 "\n", cyc);
        continue;
      }
      tick();
      continue;
    }
    // R933: pass the capture's vblanks before the next i960 access
    const bool waiting_in = C(needs_fi) && !C(fi_valid);
    idle_run = waiting_in ? idle_run + 1 : 0;
    bool gated = false;
    if (!pend && ie < cpu.size() && paced(ie)) {   // R1005
      if (!tm_has_e) {
        const TmRec &r = tmg[ie];
        if (r.frame != tm_f) {
          uint64_t v;
          if (tm_f == UINT32_MAX) { v = cyc; tm_v0 = cyc; }
          else {
            uint64_t e = tm_done + sc(tm_f < tml.size() ? tml[tm_f] : 0.0);
            uint64_t work = e - tm_v, nv = (work + vbl_cyc - 1) / vbl_cyc;
            if (flog) fprintf(flog, "%u %" PRIu64 " %" PRIu64 " %" PRIu64 " %" PRIu64 " %" PRIu64 " %" PRIu64 " %" PRIu64 " %" PRIu64 " %.6f\n",
                              tm_f, tm_v - tm_v0, work, nv, tf_cpu, tf_hin, tf_hout, words - tf_w0, tf_ev, tm_f < tmw.size() ? tmw[tm_f] : 0.0);
            tm_frames++; if (nv > 1) tm_over++; tm_hist[nv < 4 ? nv : 4]++;
            v = tm_v0 + ((e - tm_v0) / vbl_cyc + 1) * vbl_cyc;            // the first edge after the flip
            v += uint64_t(r.frame - tm_f - 1) * vbl_cyc;                   // frames with no copro access
          }
          tm_f = r.frame; tm_v = v; tf_cpu = tf_hin = tf_hout = tf_ev = 0; tf_w0 = words;
          tm_e = v + sc(r.gap);
        } else tm_e = tm_done + sc(r.gap);
        tf_cpu += sc(r.gap);
        tm_has_e = true;
      }
      if (cyc < tm_e) {
        gated = true;
        // nothing to simulate: the TGPx4 sits in S_DEC on a FIFO (needs_fi alone is
        // not enough -- it stays set for the rest of the word that popped) and its
        // memory ports are quiet
        if (C(s) == 2 && C(dec_stall) && C(ops_idle) && !top->dat_req && !top->bufw_req && !top->tbl_req) { tm_skip += tm_e - cyc; cyc = tm_e; gated = false; }
      }
      if (!gated) tm_pres = cyc;
    } else if (frames_on && !pend && ie < cpu.size() && postboot[ie] && fbefore[ie] > fdone) {
      if (idle_run >= idle_need || cyc - fstart >= frame_cyc) {
        const bool idle = idle_run >= idle_need;
        if (flog && tmg.empty()) fprintf(flog, "%u %c %" PRIu64 " %" PRIu64 "\n", fdone, idle ? 'I' : 'C', cyc - fstart - (idle ? idle_need : 0), words - uf_w0);
        uf_w0 = words;
        fdone++; if (idle) { fpassed_idle++; idle_run = 0; } else fpassed_cap++; fstart = cyc;
      }
      gated = fbefore[ie] > fdone;
      if (gated) gate_cyc++;
    } else if (!frames_on || (ie < cpu.size() && !postboot[ie])) { fdone = fbefore[ie]; fstart = cyc; }
    // present the next i960 access
    if (!pend && !gated && ie < cpu.size()) {
      cur = cpu[ie];
      top->sel_ctl = (cur->t == 'C');
      top->sel_fifo = (cur->t == 'U' || cur->t == 'I' || cur->t == 'X');
      top->sel_fn = (cur->t == 'N');
      top->fn_code = (cur->a >> 2) & 0xff;   // offset is a dword index: (offset >> 2) & 0xff
      top->we = (cur->t != 'X');
      top->wdata = (cur->t == 'N') ? ((cur->b & 0x800fffff)) : cur->b;
      pend = 1;
    }
    top->clk = 0; top->eval();
    bool stalled = top->stall;
    uint32_t rd = top->rdata;
    tick();
    if (pend && !stalled) {
      if (cur->t == 'X') {
        if (rd != cur->b) { if (xbad < 20) printf("X %" PRIu64 ": rtl %08x mame %08x (cyc %" PRIu64 ")\n", xs, rd, cur->b, cyc); xbad++; }
        xs++;
      }
      top->sel_ctl = 0; top->sel_fifo = 0; top->sel_fn = 0; top->we = 0;
      if (tm_has_e) {   // R1005
        uint64_t held = cyc - tm_pres;
        if (cur->t == 'X') tf_hout += held; else tf_hin += held;
        tf_ev++; tm_done = cyc; tm_has_e = false;
      }
      pend = 0; ie++;
    }
    if (C(s) == 2 && C(dec_stall)) pp_wait++;   // R1005: S_DEC held on a FIFO
    if (stprof && active) {                      // R1006: clocks by sequencer state, FIFO waits apart
      if (C(s) == 2 && C(dec_stall)) st_fifo++;
      else { st_hist[C(s) & 15]++; if (C(s) == 2 && C(dec_hz)) {
        st_hz++;
        if (C(hz_reg)) st_hzk[0]++; else if (C(hz_st)) st_hzk[1]++;
        else if (C(alu_op) && !C(a_issue_ok)) st_hzk[2]++; else if (C(mul_op) && !C(m_issue_ok)) st_hzk[3]++; else st_hzk[4]++; } }
      if (C(ext_req)) { if (C(ext_we)) st_extw++; else st_extr++; }
    }
    if (C(dbg_retire) && !pcprof_path.empty()) {
      if (pp_have) { uint64_t c = cyc - pp_last - pp_wait; pp_n[pp_pc & 0xfff]++; pp_c[pp_pc & 0xfff] += c; }
      pp_have = true; pp_last = cyc; pp_wait = 0; pp_pc = C(ir_pc);
    }
    // the lockstep (R1006: with a checkpoint, from the restart on)
    if (C(dbg_retire) && (ck_ie == SIZE_MAX || ck_done)) {
      if (active && lockstep) {
        try { ref.execute_one(); } catch (const std::exception &e) { printf("REF FATAL %s\n", e.what()); done = true; }
        words++;
        // R1006: results may still be in flight at a word's end; the state is
        // compared at the words where every one has been written
        int b = 0;
        if (C(ops_idle)) { b = compare(words); ls_cmp++; } else ls_skip++;
        if (b) {
          if (lbad < 30) {
            printf("LOCKSTEP word %" PRIu64 " (cyc %" PRIu64 "): %d fields differ; ref executed pc %03x, rtl now at %03x; recent rtl pcs:", words, cyc, b, ref.m_core->ppc, C(ir_pc));
            for (int k = 0; k < 16; k++) printf(" %03x", last_pc[(lp + k) & 15]);
            printf("\n");
          }
          lbad++;
          if (lbad >= 3) done = true;
        }
      } else if (!active) active = true;
      else words++;
      last_pc[lp++ & 15] = C(ir_pc);
    }
    if (ie >= cpu.size() && !pend) done = true;
    // R933: a wedge is a result, not a wait -- no word for 50 M clocks ends the run
    static uint64_t last_words = 0, last_move = 0;
    if (words != last_words || !active || tm_has_e) { last_words = words; last_move = cyc; }
    else if (cyc - last_move > 50000000ull) {
      printf("WEDGED: no word retired in 50 M clocks (word %" PRIu64 ", pc %03x, i960 event %zu/%zu '%c', input waiting %d, frames %u/%u)\n",
             words, C(ir_pc), ie, cpu.size(), ie < cpu.size() ? cpu[ie]->t : '-', int(waiting_in), fdone, ie < fbefore.size() ? fbefore[ie] : 0u);
      lbad++; done = true;
    }
    if (words >= max_words || cyc >= max_cyc) done = true;
    if (!quiet && (cyc % 50000000) == 0) printf("  cyc %" PRIu64 "M words %" PRIu64 " i960 events %zu/%zu X %" PRIu64 " bad %" PRIu64 "\n",
                                               cyc / 1000000, words, ie, cpu.size(), xs, xbad);
    if (C(dbg_bad) && !frames) { printf("RTL dbg_bad raised at word %" PRIu64 ", pc %03x\n", words, C(ir_pc)); frames = 1; }
  }
  size_t nx = 0; for (size_t k = (ck_ie != SIZE_MAX ? ck_ie : 0); k < cpu.size(); k++) if (cpu[k]->t == 'X') nx++;
  if (stprof) {   // R1006
    uint64_t tot = st_fifo; for (auto v : st_hist) tot += v;
    printf("STPROF (clocks by state, %% of %" PRIu64 "; FIFO waits apart):", tot);
    for (int i = 0; i < 16; i++) if (st_hist[i]) printf(" s%d %.2f%%", i, 100.0 * st_hist[i] / tot);
    printf(" (of s2 hazard holds %.2f%%) fifo %.2f%%; ext read pending %.2f%%, ext write pending %.2f%%; per word: %.3f clk (FIFO waits out)\n",
           100.0 * st_hz / tot, 100.0 * st_fifo / tot, 100.0 * st_extr / tot, 100.0 * st_extw / tot, words ? double(tot - st_fifo) / words : 0.0);
    if (st_hz) printf("HAZARDS (R1006, %% of all clocks): register %.2f%%, ST %.2f%%, ALU issue %.2f%%, multiplier issue %.2f%%, PR2 %.2f%%\n",
                      100.0 * st_hzk[0] / tot, 100.0 * st_hzk[1] / tot, 100.0 * st_hzk[2] / tot, 100.0 * st_hzk[3] / tot, 100.0 * st_hzk[4] / tot);
  }
  if (!pcprof_path.empty()) {
    FILE *pf = fopen(pcprof_path.c_str(), "w");
    for (int i = 0; i < 4096; i++) if (pp_n[i]) fprintf(pf, "%03x %" PRIu64 " %" PRIu64 "\n", i, pp_n[i], pp_c[i]);
    fclose(pf);
  }
  if (flog && tmg.empty()) fclose(flog);
  if (!tmg.empty()) {
    printf("R1005 PACED: %" PRIu64 " frames, %" PRIu64 " over one vblank (1: %" PRIu64 "  2: %" PRIu64 "  3: %" PRIu64 "  4+: %" PRIu64 "); %" PRIu64 " idle clocks skipped\n",
           tm_frames, tm_over, tm_hist[1], tm_hist[2], tm_hist[3], tm_hist[4], tm_skip);
    if (flog) fclose(flog);
  }
  if (frames_on) printf("FRAMES (R933): %u vblanks passed, %" PRIu64 " with the TGPx4 idle, %" PRIu64 " at the frame cap; %" PRIu64 " clocks held for them (%.2f clk/word without)\n",
                        fdone, fpassed_idle, fpassed_cap, gate_cyc, words ? double(cyc - gate_cyc) / words : 0.0);
  if (lockstep) printf("LOCKSTEP (R1006): state compared at %" PRIu64 " words, %" PRIu64 " ended with results in flight\n", ls_cmp, ls_skip);
  printf("RESULT: %" PRIu64 " cycles, %" PRIu64 " words (%.2f clk/word), i960 events %zu/%zu, outputs %" PRIu64 "/%zu checked, %" PRIu64 " differ (%.4f%% match), lockstep %s %" PRIu64 " bad\n",
         cyc, words, words ? double(cyc) / words : 0.0, ie, cpu.size(), xs, nx, xbad, xs ? 100.0 * (xs - xbad) / xs : 0.0,
         lockstep ? "on" : "off", lbad);
  delete top;
  return (xbad || lbad || xs < nx) ? 1 : 0;
}
