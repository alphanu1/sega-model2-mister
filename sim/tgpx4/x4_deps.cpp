// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R1006: WHAT A FASTER TGPx4 COULD OVERLAP -- the dynamic word stream of a
// capture (MAME's MB86235 interpreter, sim/tgpx4/mame, fed the capture's pops
// and external reads as ref_replay does), each word decoded as tgpx4_core
// decodes it (xdec, the ALU / multiplier fields), and for every register a
// word reads the distance in words back to the last ALU / multiplier result
// written to it; the same for the flags (ST) a word reads.
//
//   x4_deps <capdir> [--from W] [--words N] [--pcs FILE] [--pcdump FILE]
//
// --from / --words: the window of words counted (all words execute).
// --pcs FILE: only words at program addresses listed in FILE (one hex address
// per line, e.g. the race's top addresses) are counted.
// Prints the word mix by class and the distance histograms.
#include "mame/mb86235.h"
#include "cap.h"
#include <cinttypes>
#include <algorithm>
#include <map>

#include "x4_xdec.h"

int main(int argc, char **argv)
{
  if (argc < 2) { fprintf(stderr, "usage: x4_deps <capdir> [--from W] [--words N] [--pcs FILE]\n"); return 2; }
  uint64_t from = 0, nwin = UINT64_MAX; std::vector<bool> pcsel; bool usepcs = false;
  std::string pcdump; uint64_t from_pop = 0;   // --from-pop P: the external-access statistics from the P-th pop on                    // --pcdump FILE: pc, words counted there, the word's class
  std::vector<uint64_t> pc_n(4096, 0); std::vector<std::string> pc_k(4096);
  for (int i = 2; i < argc; i++) {
    std::string a = argv[i];
    if (a == "--from") from = strtoull(argv[++i], nullptr, 0);
    else if (a == "--words") nwin = strtoull(argv[++i], nullptr, 0);
    else if (a == "--pcdump") pcdump = argv[++i];
    else if (a == "--from-pop") from_pop = strtoull(argv[++i], nullptr, 0);
    else if (a == "--pcs") { usepcs = true; pcsel.assign(4096, false); FILE *f = fopen(argv[++i], "r"); unsigned p; while (f && fscanf(f, "%x%*[^\n]", &p) == 1) pcsel[p & 0xfff] = true; if (f) fclose(f); }
  }
  Capture c;
  if (!c.load(argv[1], 0)) return 2;
  mb86235_device d;
  memcpy(d.prog, c.prog, sizeof d.prog);
  d.reset();
  std::vector<uint32_t> pops; std::vector<const CapEv *> exts;
  for (size_t i = c.boot_ev; i < c.ev.size(); i++) {
    const CapEv &e = c.ev[i];
    if (e.t == 'P') pops.push_back(e.b); else if (e.t == 'R' || e.t == 'W') exts.push_back(&e);
  }
  size_t ip = 0, ix = 0; bool end = false;
  d.fin.empty = [&]() { if (ip >= pops.size()) { end = true; return true; } return false; };
  d.fin.full = []() { return false; };
  d.fin.pop_fn = [&]() { return pops[ip++]; };
  d.fout.empty = []() { return true; };
  d.fout.full = []() { return false; };
  d.fout.push_fn = [&](uint32_t) {};
  // external accesses: the words between them, and whether a read is at the
  // address the last one left behind (eb + eo after its eo step: read-ahead)
  uint64_t cur_w = 0, last_rw = UINT64_MAX, last_ww = UINT64_MAX, nrd = 0, nwr = 0, rd_pred = 0, rd_rom = 0;
  uint32_t pred_a = 0xffffffff; bool rd_this = false;
  uint64_t h_rg[7] = {}, h_wg[7] = {};
  auto gb = [](uint64_t g) { return g <= 1 ? 0 : g == 2 ? 1 : g == 3 ? 2 : g < 8 ? 3 : g < 16 ? 4 : g < 64 ? 5 : 6; };
  // direct-mapped caches of the ROM reads: 2^k lines of 2^l words (R1006)
  const int CK[4] = {10, 11, 12, 13}, CL[3] = {0, 2, 3};
  std::vector<uint32_t> ctag[4][3]; uint64_t chit[4][3] = {};
  for (int i = 0; i < 4; i++) for (int j = 0; j < 3; j++) ctag[i][j].assign(1u << CK[i], 0xffffffff);
  // write bursts: consecutive writes no more than 2 words apart
  uint64_t burst = 0, h_bl[7] = {};
  d.m_external.rd = [&](uint32_t a) -> uint32_t {
    const bool cnt_on = ip >= from_pop;
    for (int i = 0; i < 4; i++) for (int j = 0; j < 3; j++) {
      uint32_t ln = a >> CL[j], ix2 = ln & ((1u << CK[i]) - 1);
      if (ctag[i][j][ix2] == ln) { if (cnt_on) chit[i][j]++; } else ctag[i][j][ix2] = ln; }
    if (!cnt_on) { while (ix < exts.size() && exts[ix]->t != 'R') ix++; return ix < exts.size() ? exts[ix++]->b : c.rom(a); }
    nrd++; if (a >= 0x800000) rd_rom++; if (a == pred_a) rd_pred++; rd_this = true;
    if (last_rw != UINT64_MAX) h_rg[gb(cur_w - last_rw)]++; last_rw = cur_w;
    while (ix < exts.size() && exts[ix]->t != 'R') ix++; return ix < exts.size() ? exts[ix++]->b : c.rom(a); };
  d.m_external.wr = [&](uint32_t, uint32_t) {
    if (ip < from_pop) { if (ix < exts.size() && exts[ix]->t == 'W') ix++; return; }
    nwr++; if (last_ww != UINT64_MAX) h_wg[gb(cur_w - last_ww)]++;
    if (last_ww != UINT64_MAX && cur_w - last_ww <= 2) burst++; else { if (burst) h_bl[gb(burst)]++; burst = 1; }
    last_ww = cur_w;
    if (ix < exts.size() && exts[ix]->t == 'W') ix++; };

  const int ND = 8;                     // distance buckets 1..7, 8+
  uint64_t last_w[32]; for (auto &x : last_w) x = UINT64_MAX;   // word index of the last ALU / MUL write to each register
  uint64_t last_fw = UINT64_MAX;        // the last ALU / MUL op (it writes flags)
  uint64_t h_op[ND + 1] = {}, h_tx[ND + 1] = {}, h_wawt[ND + 1] = {}, h_fl[ND + 1] = {}, h_any[ND + 1] = {};
  std::map<std::string, uint64_t> mix;
  uint64_t nw = 0, cnt = 0;
  auto bucket = [&](uint64_t w, uint64_t last) { if (last == UINT64_MAX) return ND; uint64_t dd = w - last; return int(dd >= ND ? ND : dd); };
  while (!end) {
    cur_w = nw; rd_this = false;
    uint32_t pc = d.execute_one();
    if (end) break;
    if (d.stalled()) continue;
    if (rd_this) pred_a = (d.m_core->eb + d.m_core->eo) & 0xffffff;
    const uint64_t w = d.prog[pc & 0xfff];
    const uint64_t wi = nw++;
    const int top = int(w >> 61);
    const bool is_ctl = top == 2 || top == 6, is_imm = top == 7, alu_one = (w >> 63) & 1;
    const bool alu_en = !is_imm && (!alu_one || ((w >> 41) & 1)), mul_en = !is_imm && (!alu_one || !((w >> 41) & 1));
    const int aop = int(B(w, 60, 56)), ai1 = int(B(w, 55, 52)), ai2 = int(B(w, 51, 47)), ao = int(B(w, 46, 42));
    const int mi1 = int(B(w, 40, 37)), mi2 = int(B(w, 36, 32)), mo = int(B(w, 31, 27));
    const int m1s = alu_one ? ai1 : mi1, m2s = alu_one ? ai2 : mi2, md = alu_one ? ao : mo;
    const bool isfmul = alu_one ? aop != 0 : ((w >> 41) & 1);
    const bool src2 = !(((aop & 0x1c) == 0x1c) || ((aop & 0x1e) == 0x16) || ((aop & 0x0f) == 0x05) || ((aop & 0x18) == 0x08));
    const bool a_nop = aop == 7;
    const Xd x = xdec(w);
    const int cop = int(B(w, 26, 22)), ef1 = int(B(w, 21, 16));
    // registers read by the ALU / multiplier, and by transfers
    int rop[4], nrop = 0, rtx[3], nrtx = 0;
    if (alu_en && !a_nop) { rop[nrop++] = ((ai1 >> 3) & 1) << 4 | 1 << 3 | (ai1 & 7); if (src2 && (ai2 >> 3) < 2) rop[nrop++] = ((ai2 >> 3) & 1) << 4 | 1 << 3 | (ai2 & 7); }
    if (mul_en) { rop[nrop++] = ((m1s >> 3) & 1) << 4 | (m1s & 7); if ((m2s >> 3) < 2) rop[nrop++] = ((m2s >> 3) & 1) << 4 | (m2s & 7); }
    for (int m = 0; m < 2; m++) if (x.sk[m] == K_REG && is_rf(x.sc[m])) rtx[nrtx++] = rf_idx(x.sc[m]);
    bool rd_st = false;
    for (int m = 0; m < 2; m++) if ((x.sk[m] == K_REG && x.sc[m] == 0x15) || (x.dk[m] == K_REG && x.dc[m] == 0x15)) rd_st = true;
    if (is_ctl && (cop == 0x10 || cop == 0x11 || cop == 0x18 || cop == 0x19) && (ef1 & 0x1f) < 20) rd_st = true;
    const bool counted = wi >= from && wi - from < nwin && (!usepcs || pcsel[pc & 0xfff]);
    if (counted) {
      cnt++;
      int bo = ND, bt = ND, bw = ND, bf = ND;
      for (int i = 0; i < nrop; i++) bo = std::min(bo, bucket(wi, last_w[rop[i]]));
      for (int i = 0; i < nrtx; i++) bt = std::min(bt, bucket(wi, last_w[rtx[i]]));
      for (int m = 0; m < 2; m++) if (x.dk[m] == K_REG && is_rf(x.dc[m])) bw = std::min(bw, bucket(wi, last_w[rf_idx(x.dc[m])]));
      if (rd_st) bf = bucket(wi, last_fw);
      h_op[bo]++; h_tx[bt]++; h_wawt[bw]++; h_fl[bf]++; h_any[std::min(std::min(bo, bt), std::min(bw, bf))]++;
      // class
      std::string k;
      if (alu_en && !a_nop) {
        if ((aop & 0x18) == 0 && (aop & 7) != 5 && (aop & 7) != 7) k += "fadd"; else if (aop == 0xa) k += "frcp"; else if (aop == 0xb) k += "frsq";
        else if (aop == 0xd || aop == 0xe || aop == 0xf || (aop >> 2) == 7) k += "cvt"; else k += "int";
      } else k += "-";
      k += mul_en ? (isfmul ? "+fmul" : "+imul") : "+-";
      int ns = 0, nd = 0; bool ext = false, mem = false;
      for (int m = 0; m < 2; m++) { if (x.sk[m] != K_NONE) ns++; if (x.dk[m] != K_NONE) nd++; if (x.sk[m] == K_EXT || x.dk[m] == K_EXT) ext = true; if (x.sk[m] == K_MEM || x.dk[m] == K_MEM) mem = true; }
      k += " t" + std::to_string(ns) + std::to_string(nd) + (ext ? "x" : "") + (mem ? "m" : "") + (is_ctl ? " ctl" : "");
      mix[k]++;
      pc_n[pc & 0xfff]++; if (pc_k[pc & 0xfff].empty()) pc_k[pc & 0xfff] = k;
    }
    // this word's ALU / MUL results (a transfer to the same register in the word wins, but the op still ran)
    if (alu_en && !a_nop) { last_fw = wi; if (!(aop == 0x04 || aop == 0x06 || aop == 0x14)) last_w[((ao >> 3) & 1) << 4 | ((ao >> 4) & 1) << 3 | (ao & 7)] = wi; }
    if (mul_en) { last_fw = wi; last_w[((md >> 3) & 1) << 4 | ((md >> 4) & 1) << 3 | (md & 7)] = wi; }
  }
  printf("words %" PRIu64 ", counted %" PRIu64 "\n", nw, cnt);
  auto ph = [&](const char *n, uint64_t *h) {
    printf("%-34s", n);
    for (int i = 1; i <= ND; i++) printf(" %c%d %5.1f%%", i == ND ? '>' : '=', i == ND ? ND - 1 : i, 100.0 * h[i] / std::max<uint64_t>(cnt, 1));
    printf("\n");
  };
  printf("distance to the last ALU / MUL result (words; >7 includes none):\n");
  ph("ALU / MUL operand (RAW)", h_op);
  ph("transfer source (RAW)", h_tx);
  ph("transfer dest register (WAW)", h_wawt);
  ph("ST read / written / cond", h_fl);
  ph("any of them", h_any);
  if (!pcdump.empty()) {
    FILE *f = fopen(pcdump.c_str(), "w");
    for (int i = 0; i < 4096; i++) if (pc_n[i]) fprintf(f, "%03x %" PRIu64 " %s\n", i, pc_n[i], pc_k[i].c_str());
    fclose(f);
  }
  const char *gn[7] = {"1", "2", "3", "4-7", "8-15", "16-63", "64+"};
  printf("external reads %" PRIu64 " (ROM %" PRIu64 "), at the address the last read left (eb + eo) %.1f%%; writes %" PRIu64 "\n",
         nrd, rd_rom, 100.0 * rd_pred / std::max<uint64_t>(nrd, 1), nwr);
  printf("words from one external read to the next: "); for (int i = 0; i < 7; i++) printf(" %s %.1f%%", gn[i], 100.0 * h_rg[i] / std::max<uint64_t>(nrd, 1)); printf("\n");
  printf("words from one external write to the next:"); for (int i = 0; i < 7; i++) printf(" %s %.1f%%", gn[i], 100.0 * h_wg[i] / std::max<uint64_t>(nwr, 1)); printf("\n");
  printf("write bursts (writes <= 2 words apart), by length:"); { uint64_t t = 0; for (auto x : h_bl) t += x; for (int i = 0; i < 7; i++) printf(" %s %.1f%%", gn[i], 100.0 * h_bl[i] / std::max<uint64_t>(t, 1)); } printf("\n");
  printf("ROM read hit rate, direct-mapped, lines x words:");
  for (int i = 0; i < 4; i++) for (int j = 0; j < 3; j++) printf(" %ux%u %.1f%%", 1u << CK[i], 1u << CL[j], 100.0 * chit[i][j] / std::max<uint64_t>(nrd, 1));
  printf("\n");
  std::vector<std::pair<uint64_t, std::string>> v;
  for (auto &kv : mix) v.push_back({kv.second, kv.first});
  std::sort(v.rbegin(), v.rend());
  printf("word mix (alu+mul, transfers t<src><dst>, x external, m RAM):\n");
  for (size_t i = 0; i < v.size() && i < 40; i++) printf("  %6.2f%%  %s\n", 100.0 * v[i].first / std::max<uint64_t>(cnt, 1), v[i].second.c_str());
  return 0;
}
