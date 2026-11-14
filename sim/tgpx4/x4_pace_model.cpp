// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R1005: A TIMING MODEL OF THE 2C FRAME -- the i960 and the TGPx4 coupled
// through the two 8-deep FIFOs -- for whole sessions, where the RTL replay
// (tb_tgpx4_replay, ~1 M clocks a second) cannot reach a race inside a bench's
// time limit.
//
//   THE TGPx4 is MAME's own interpreter (sim/tgpx4/mame, verbatim) fed the
//   capture's pop stream, so it executes exactly the words MAME's did; each
//   word costs what the RTL measured for its program address (--pcprof, from
//   tb_tgpx4_replay --pcprof: the RTL's clocks accept to accept, FIFO waits
//   removed; unseen addresses cost --cost, the session mean), times --x4 (a
//   what-if on the TGPx4's speed).
//   THE i960 presents the capture's accesses in order (C U I N X), each no
//   earlier than the last one's completion plus MAME's own i960 time between
//   them (tm_gaps.py) times --scale (the core's i960 time per MAME i960 time).
//   A push waits for room (the push 8 before it popped), a read for its word.
//   Game frames start at the first vblank edge after the last frame's flip
//   (the game's own pacing). Before --from the i960 is instantaneous and a
//   frame is passed when the TGPx4 has waited --idle clocks on an empty input
//   FIFO (tb_tgpx4_replay's R933 gate), so the model can be checked against
//   the RTL bench frame for frame (--flog lines "U frame busy words").
//
//   x4_pace_model <capdir> --tm DIR --pcprof FILE [--scale S] [--x4 K]
//                 [--from F] [--to F] [--flog FILE] [--cost C] [--vbl N]
//   X4_PCHIST=<file>: the words run from frame --from on, by program address.
//
// CHECKED (R1005): unpaced, against the RTL replay of the same capture over
// its first 3,129 vblanks with work: the TGPx4's busy clocks per vblank agree
// to p1 0.991 / p50 1.001 / p99 1.057 (sum 0.9998), words equal in 3,128.
// The costs are the RTL's own at --lat 6, so the board's SDRAM is not in them.
#include "mame/mb86235.h"
#include "cap.h"
#include <cinttypes>
#include <deque>

int main(int argc, char **argv)
{
  if (argc < 2) { fprintf(stderr, "usage: x4_pace_model <capdir> [options]\n"); return 2; }
  std::string dir = argv[1], tm_dir, pcprof, flog_path;
  double scale = 1.0, x4 = 1.0, cost_def = 6.72;
  uint32_t from = UINT32_MAX, to = UINT32_MAX;
  uint64_t vbl = 1391304, idle_need = 64, frame_cap = 1391304;
  const double wr_cost = 4, rd_cost = 6;            // the bridge's access, clk_sys (tb_tgpx4_replay's bus)
  for (int i = 2; i < argc; i++) {
    std::string a = argv[i];
    auto nx = [&]() { return std::string(i + 1 < argc ? argv[++i] : ""); };
    if (a == "--tm") tm_dir = nx();
    else if (a == "--pcprof") pcprof = nx();
    else if (a == "--scale") scale = atof(nx().c_str());
    else if (a == "--x4") x4 = atof(nx().c_str());
    else if (a == "--from") from = uint32_t(strtoul(nx().c_str(), nullptr, 0));
    else if (a == "--to") to = uint32_t(strtoul(nx().c_str(), nullptr, 0));
    else if (a == "--flog") flog_path = nx();
    else if (a == "--cost") cost_def = atof(nx().c_str());
    else if (a == "--vbl") vbl = strtoull(nx().c_str(), nullptr, 0);
  }
  Capture cap;
  if (!cap.load(dir, 0)) return 2;
  // ---- per-address cost
  std::vector<double> cost(4096, cost_def);
  std::vector<bool> prof(4096, false); uint64_t unprof = 0;
  std::vector<uint64_t> pc_paced(4096, 0);        // words executed in paced frames, by address
  if (!pcprof.empty()) {
    FILE *f = fopen(pcprof.c_str(), "r"); unsigned pc; unsigned long long n, c; int seen = 0;
    double sn = 0, sc = 0;
    while (f && fscanf(f, "%x %llu %llu", &pc, &n, &c) == 3) { if (n) { cost[pc & 0xfff] = double(c) / n; prof[pc & 0xfff] = true; seen++; sn += n; sc += c; } }
    if (f) fclose(f);
    printf("pcprof: %d addresses, mean %.3f clk/word over %.0f words\n", seen, sn ? sc / sn : 0, sn);
  }
  for (auto &c : cost) c *= x4;
  // ---- the i960's accesses and the TGPx4's FIFO traffic, in capture order
  struct Cpu { char t; uint32_t b; uint32_t fcap; };
  std::vector<Cpu> cpu;
  std::vector<uint32_t> pops, outs;               // after the boot: the TGPx4's pops (P) and outputs (O)
  std::vector<const CapEv *> exts;
  { uint32_t nf = 0;
    for (size_t i = 0; i < cap.ev.size(); i++) {
      const CapEv &e = cap.ev[i];
      if (e.t == 'F') nf++;
      if (e.t == 'C' || e.t == 'U' || e.t == 'I' || e.t == 'N' || e.t == 'X') cpu.push_back({char(e.t), e.b, nf});
      if (i > cap.boot_ev) {
        if (e.t == 'P') pops.push_back(e.b);
        else if (e.t == 'O') outs.push_back(e.b);
        else if (e.t == 'R' || e.t == 'W') exts.push_back(&e);
      }
    } }
  // the i960's pushes (I and N after the boot) and reads (X), indexed
  size_t boot_cpu = 0;
  { size_t k = 0; for (size_t i = 0; i < cap.ev.size() && i <= cap.boot_ev; i++) {
      const CapEv &e = cap.ev[i]; if (e.t == 'C' || e.t == 'U' || e.t == 'I' || e.t == 'N' || e.t == 'X') k++; }
    boot_cpu = k; }
  // the TGPx4's CLRF drops pushes it never pops: align pops to pushes by value
  std::vector<uint32_t> pushv;
  for (size_t k = boot_cpu; k < cpu.size(); k++) if (cpu[k].t == 'I' || cpu[k].t == 'N') pushv.push_back(cpu[k].b);
  size_t nxr = 0; for (size_t k = boot_cpu; k < cpu.size(); k++) if (cpu[k].t == 'X') nxr++;
  printf("events %zu; after the boot: i960 accesses %zu (pushes %zu, reads %zu), TGPx4 pops %zu, outputs %zu, external %zu\n",
         cap.ev.size(), cpu.size() - boot_cpu, pushv.size(), nxr, pops.size(), outs.size(), exts.size());
  // offset: the pushes discarded before pop j is the k with pushv[j + k] == pops[j] for the tail
  long poff = -1;
  for (long k = 0; k < 8 && poff < 0; k++) {
    bool ok = true; size_t n = std::min<size_t>(pops.size(), 200000);
    for (size_t j = pops.size() - n; j < pops.size() && ok; j++) if (j + k >= pushv.size() || pushv[j + k] != pops[j]) ok = false;
    if (ok) poff = k;
  }
  long ooff = long(outs.size()) - long(nxr);      // outputs never read (cleared or left at the end)
  printf("pop offset %ld (pushes discarded by CLRF), outputs not read %ld\n", poff, ooff);
  if (poff < 0) { printf("cannot align pops to pushes\n"); return 1; }
  // ---- the i960 gaps
  struct TmRec { double gap; uint32_t frame, flags; };
  std::vector<TmRec> tmg; std::vector<double> tml, tmw;
  if (!tm_dir.empty()) {
    std::vector<uint8_t> b;
    if (!Capture::rd_all(tm_dir + "/tmg.bin", b) || b.size() / 16 != cpu.size()) { fprintf(stderr, "tmg.bin does not match\n"); return 2; }
    tmg.resize(cpu.size()); memcpy(tmg.data(), b.data(), cpu.size() * 16);
    b.clear(); Capture::rd_all(tm_dir + "/tml.bin", b);
    tml.resize(b.size() / 16); tmw.resize(b.size() / 16);
    for (size_t i = 0; i < tml.size(); i++) { memcpy(&tml[i], &b[i * 16], 8); memcpy(&tmw[i], &b[i * 16 + 8], 8); }
  }
  auto paced = [&](size_t k) { return !tmg.empty() && tmg[k].frame >= from && tmg[k].frame < to; };
  const double clk_s = 80e6 * scale;
  FILE *flog = flog_path.empty() ? nullptr : fopen(flog_path.c_str(), "w");
  if (flog) fprintf(flog, "# P frame vstart work vblanks cpu held_in held_out words events mame_work_s | U capframe busy words\n");

  // ---- state
  std::vector<double> t_push(pushv.size() + 1, -1), t_pop(pops.size() + 1, -1), t_out(outs.size() + 1, -1), t_read(nxr + 1, -1);
  size_t npush = 0, nread = 0, npop = 0, nout = 0, iext = 0;
  double Ti = 0, Tx = 0;                          // the two agents' clocks (clk_sys)
  size_t ie = 0;                                  // next i960 access
  bool x4_end = false; uint64_t words = 0, stall_pass = 0, outbad = 0, extbad = 0;
  int x4_block = 0;                               // 1: needs push npop+poff; 2: needs read nout-8
  int i_block = 0;                                // 1: push needs a pop; 2: read needs an output
  // unpaced gate (R933)
  uint32_t fdone = 0; double fstart = 0, x4_idle_since = -1; uint64_t uf_w0 = 0;
  // paced bookkeeping
  uint32_t pf = UINT32_MAX; double pv = 0, pv0 = 0, pdone = 0; bool have_e = false; double e_at = 0;
  double f_cpu = 0, f_hin = 0, f_hout = 0; uint64_t f_w0 = 0, f_ev = 0, pframes = 0, pover = 0, phist[5] = {};

  mb86235_device ref;
  memcpy(ref.prog, cap.prog, sizeof ref.prog);
  ref.reset();
  ref.fin.empty = [&]() {
    if (npop >= pops.size()) { x4_end = true; return true; }
    size_t k = npop + size_t(poff);
    if (k >= pushv.size()) { x4_end = true; return true; }
    if (t_push[k] < 0) { x4_block = 1; return true; }
    return false;
  };
  ref.fin.full = []() { return false; };
  ref.fin.pop_fn = [&]() { size_t k = npop + size_t(poff); Tx = std::max(Tx, t_push[k]); t_pop[npop] = Tx; return pops[npop++]; };
  ref.fout.empty = []() { return true; };
  ref.fout.full = []() { return false; };
  ref.fout.push_fn = [&](uint32_t v) {
    if (nout < outs.size() && outs[nout] != v && outbad++ < 10) printf("OUT %zu: model %08x mame %08x\n", nout, v, outs[nout]);
    t_out[nout] = -2; nout++;                     // its time is the word's end, set below
  };
  ref.m_external.rd = [&](uint32_t a) -> uint32_t {
    if (iext < exts.size() && exts[iext]->t == 'R') return exts[iext++]->b;
    if (extbad++ < 10) printf("EXT read %06x out of step\n", a);
    return cap.rom(a);
  };
  ref.m_external.wr = [&](uint32_t, uint32_t) { if (iext < exts.size() && exts[iext]->t == 'W') iext++; else extbad++; };

  auto step_x4 = [&]() {
    // a full output FIFO holds the next word
    if (nout >= 8 && t_read[nout - 8] < 0 && nout - 8 < nxr) { x4_block = 2; return; }
    if (nout >= 8 && nout - 8 < nxr) Tx = std::max(Tx, t_read[nout - 8]);
    size_t out0 = nout;
    x4_block = 0;
    uint32_t pc = ref.execute_one();
    if (x4_end) return;
    if (ref.stalled()) {
      stall_pass++;
      if (x4_block == 1 && x4_idle_since < 0) x4_idle_since = Tx;
      return;
    }
    x4_idle_since = -1;
    Tx += cost[pc & 0xfff];
    if (!pcprof.empty() && !prof[pc & 0xfff]) unprof++;
    if (pf != UINT32_MAX) pc_paced[pc & 0xfff]++;
    for (size_t m = out0; m < nout; m++) t_out[m] = Tx;
    words++;
  };
  auto finish_frame = [&](uint32_t next_frame) {
    // close paced frame pf: its flip is MAME's flip gap after its last access
    double e = pdone + (pf < tml.size() ? tml[pf] * clk_s : 0);
    double work = e - pv; uint64_t nv = uint64_t((work + vbl - 1) / vbl);
    if (flog) fprintf(flog, "P %u %.0f %.0f %" PRIu64 " %.0f %.0f %.0f %" PRIu64 " %" PRIu64 " %.6f\n", pf, pv - pv0, work, nv, f_cpu, f_hin, f_hout,
                      words - f_w0, f_ev, pf < tmw.size() ? tmw[pf] : 0.0);
    pframes++; if (nv > 1) pover++; phist[nv < 4 ? nv : 4]++;
    double v = pv0 + (std::floor((e - pv0) / vbl) + 1) * vbl;
    v += double(next_frame - pf - 1) * vbl;
    return v;
  };
  // the i960's next access: returns false if it must wait for the TGPx4
  auto step_i = [&]() -> bool {
    const Cpu &c = cpu[ie];
    double ready;
    if (paced(ie)) {
      if (!have_e) {
        const TmRec &r = tmg[ie];
        if (r.frame != pf) {
          double v;
          if (pf == UINT32_MAX) { v = std::max(Ti, Tx); pv0 = v; }
          else v = finish_frame(r.frame);
          pf = r.frame; pv = v; f_cpu = f_hin = f_hout = 0; f_w0 = words; f_ev = 0;
          e_at = v + r.gap * clk_s;
        } else e_at = pdone + r.gap * clk_s;
        f_cpu += r.gap * clk_s; have_e = true;
      }
      ready = e_at;
    } else {
      // R933's gate: a capture vblank before this access passes once the TGPx4
      // has sat idle on an empty input FIFO, or a frame's worth of clocks
      if (ie > boot_cpu && c.fcap > fdone) {
        double pass;
        if (x4_idle_since >= 0 && npop + size_t(poff) >= npush) pass = std::max(x4_idle_since + idle_need, Ti);
        else if (Tx >= fstart + frame_cap) pass = std::max(fstart + frame_cap, Ti);
        else return false;                        // let the TGPx4 run
        bool idle = x4_idle_since >= 0;
        if (flog) fprintf(flog, "U %u %c %.0f %" PRIu64 "\n", fdone, idle ? 'I' : 'C', pass - fstart - (idle ? idle_need : 0), words - uf_w0);
        uf_w0 = words; fdone++; fstart = pass; Ti = std::max(Ti, pass);
        return true;
      }
      ready = Ti;
    }
    double done;
    if (c.t == 'I' || c.t == 'N') {
      // room: push n-8 has been popped (pushes before poff were dropped by CLRF)
      size_t n = npush;
      if (n >= 8 && n - 8 >= size_t(poff)) {
        size_t j = n - 8 - size_t(poff);
        if (j < pops.size()) {
          if (t_pop[j] < 0) { i_block = 1; return false; }
          done = std::max(ready, t_pop[j]) + wr_cost;
        } else done = ready + wr_cost;
      } else done = ready + wr_cost;
      if (paced(ie)) f_hin += done - ready - wr_cost;
      t_push[n] = done; npush++;
    } else if (c.t == 'X') {
      size_t m = nread;
      if (m >= outs.size()) { x4_end = true; return false; }
      if (t_out[m] < 0) { i_block = 2; return false; }
      done = std::max(ready, t_out[m]) + rd_cost;
      if (paced(ie)) f_hout += done - ready - rd_cost;
      t_read[nread] = done; nread++;
    } else done = ready + wr_cost;
    i_block = 0;
    Ti = done;
    if (paced(ie)) { pdone = done; have_e = false; f_ev++; }
    ie++;
    return true;
  };

  // pre-boot accesses (control, upload) take no modelled time
  while (ie < boot_cpu) ie++;
  uint64_t guard = 0;
  while (ie < cpu.size() && !x4_end) {
    // run whichever is behind, unless it waits on the other
    if (Tx <= Ti || i_block) {
      if (x4_block == 1 && npop + size_t(poff) < pushv.size() && t_push[npop + poff] < 0) { if (!step_i()) { guard++; if (guard > 1000000) { printf("DEADLOCK at i960 %zu\n", ie); break; } } else guard = 0; continue; }
      if (x4_block == 2 && t_read[nout - 8] < 0) { if (!step_i()) { printf("DEADLOCK (output full) at i960 %zu\n", ie); break; } continue; }
      step_x4(); continue;
    }
    if (!step_i()) step_x4();
  }
  if (pf != UINT32_MAX && have_e == false) finish_frame(pf + 1);
  printf("RESULT: %" PRIu64 " words, %" PRIu64 " stall passes, Tx %.0f Ti %.0f, i960 accesses %zu/%zu, out mismatches %" PRIu64 ", ext out of step %" PRIu64 "\n",
         words, stall_pass, Tx, Ti, ie, cpu.size(), outbad, extbad);
  if (!pcprof.empty()) printf("words at addresses the profile never saw (cost %.2f): %" PRIu64 " (%.3f%%)\n", cost_def * x4, unprof, 100.0 * unprof / std::max<uint64_t>(words, 1));
  if (pframes) printf("PACED (scale %.3f, TGPx4 x%.3f): %" PRIu64 " frames, %" PRIu64 " over one vblank (1: %" PRIu64 "  2: %" PRIu64 "  3: %" PRIu64 "  4+: %" PRIu64 ")\n",
                      scale, x4, pframes, pover, phist[1], phist[2], phist[3], phist[4]);
  if (flog) fclose(flog);
  if (const char *hp = getenv("X4_PCHIST")) {   // the paced frames' words by address: pc words clk/word
    FILE *h = fopen(hp, "w");
    for (int i = 0; i < 4096; i++) if (pc_paced[i]) fprintf(h, "%03x %" PRIu64 " %.3f\n", i, pc_paced[i], cost[i]);
    fclose(h);
  }
  return 0;
}
