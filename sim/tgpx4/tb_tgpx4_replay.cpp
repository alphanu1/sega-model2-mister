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
//   Vm2_copro <capdir> [--lat N] [--jitter N] [--seed N] [--max-words N]
//             [--max-cyc M] [--ram-every N] [--no-lockstep] [--quiet]
#include "Vm2_copro.h"
#include "Vm2_copro___024root.h"
#include "verilated.h"
#include "mame/mb86235.h"
#include "cap.h"
#include <cinttypes>
#include <random>

#define C(x) (top->rootp->m2_copro__DOT__g_tgpx4__DOT__u_x4__DOT__u_core__DOT__##x)
#define RF0(i) (top->rootp->m2_copro__DOT__g_tgpx4__DOT__u_x4__DOT__u_core__DOT__g_rf__BRA__0__KET____DOT__u_rf__DOT__mem[i])

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
        else v = (a < cap.cdata.size()) ? cap.cdata[a] : 0;
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
  for (auto &e : cap.ev) if (e.t == 'C' || e.t == 'U' || e.t == 'I' || e.t == 'N' || e.t == 'X') cpu.push_back(&e);
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
      // RF index {sel1, sel0, n}: 00 MA, 01 AA, 10 MB, 11 AB
      snprintf(n, sizeof n, "MA%d", i); bad += field(n, RF0(0  + i), c->ma[i]);
      snprintf(n, sizeof n, "AA%d", i); bad += field(n, RF0(8  + i), c->aa[i]);
      snprintf(n, sizeof n, "MB%d", i); bad += field(n, RF0(16 + i), c->mb[i]);
      snprintf(n, sizeof n, "AB%d", i); bad += field(n, RF0(24 + i), c->ab[i]);
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
  int pend = 0;          // an access is on the bus
  const CapEv *cur = nullptr;
  bool done = false;
  while (!done) {
    // present the next i960 access
    if (!pend && ie < cpu.size()) {
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
      pend = 0; ie++;
    }
    // the lockstep
    if (C(dbg_retire)) {
      if (active && lockstep) {
        try { ref.execute_one(); } catch (const std::exception &e) { printf("REF FATAL %s\n", e.what()); done = true; }
        words++;
        int b = compare(words);
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
    if (words >= max_words || cyc >= max_cyc) done = true;
    if (!quiet && (cyc % 50000000) == 0) printf("  cyc %" PRIu64 "M words %" PRIu64 " i960 events %zu/%zu X %" PRIu64 " bad %" PRIu64 "\n",
                                               cyc / 1000000, words, ie, cpu.size(), xs, xbad);
    if (C(dbg_bad) && !frames) { printf("RTL dbg_bad raised at word %" PRIu64 ", pc %03x\n", words, C(ir_pc)); frames = 1; }
  }
  size_t nx = 0; for (auto *e : cpu) if (e->t == 'X') nx++;
  printf("RESULT: %" PRIu64 " cycles, %" PRIu64 " words (%.2f clk/word), i960 events %zu/%zu, outputs %" PRIu64 "/%zu checked, %" PRIu64 " differ (%.4f%% match), lockstep %s %" PRIu64 " bad\n",
         cyc, words, words ? double(cyc) / words : 0.0, ie, cpu.size(), xs, nx, xbad, xs ? 100.0 * (xs - xbad) / xs : 0.0,
         lockstep ? "on" : "off", lbad);
  delete top;
  return (xbad || lbad || xs < nx) ? 1 : 0;
}
