// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R924: THE REFERENCE MODEL AGAINST MAME'S OWN RUN. MAME's MB86235
// interpreter (sim/tgpx4/mame, verbatim) replays a capture: its FIFO pops
// are served the words MAME's TGPx4 popped, in order, its stalls where MAME
// stalled (mode mame) or never (mode clean: a word waits for its input, as
// the RTL does); its external reads are answered from copro_data and
// checked against MAME's; every word it pushes is checked against MAME's;
// and the state hash after every completed word against MAME's trace.
//   ref_replay <capdir> [clean] [maxwords]
#include "mame/mb86235.h"
#include "cap.h"

int main(int argc, char **argv)
{
  if (argc < 2) { fprintf(stderr, "usage: ref_replay <capdir> [clean] [maxwords]\n"); return 2; }
  bool clean = argc > 2 && !strcmp(argv[2], "clean");
  uint64_t maxw = argc > 3 ? strtoull(argv[3], nullptr, 0) : UINT64_MAX;
  Capture c;
  if (!c.load(argv[1])) return 2;
  printf("events %zu, upload %u dwords, boot at event %zu, trace %zu words\n", c.ev.size(), c.upload, c.boot_ev, c.tr_pc.size());

  mb86235_device d;
  memcpy(d.prog, c.prog, sizeof d.prog);
  d.reset();
  // the TGPx4-side events after the boot, in order
  std::vector<const CapEv *> pops, outs, exts;
  for (size_t i = c.boot_ev; i < c.ev.size(); i++) {
    const CapEv &e = c.ev[i];
    if (e.t == 'P' || (e.t == 'S' && !clean)) pops.push_back(&e);
    else if (e.t == 'O') outs.push_back(&e);
    else if (e.t == 'R' || e.t == 'W') exts.push_back(&e);
  }
  size_t ip = 0, io = 0, ix = 0, itr = 0;
  uint64_t bad = 0, nstall = 0, nw = 0, rombad = 0;
  bool end = false;
  d.fin.empty = [&]() { if (ip >= pops.size()) { end = true; return true; } if (pops[ip]->t == 'S') { ip++; return true; } return false; };
  d.fin.full = []() { return false; };
  d.fin.pop_fn = [&]() { return pops[ip++]->b; };
  d.fout.empty = []() { return true; };
  d.fout.full = []() { return false; };
  d.fout.push_fn = [&](uint32_t v) {
    if (io >= outs.size()) { end = true; return; }
    if (outs[io]->b != v && bad++ < 20) printf("OUT %zu: ref %08x mame %08x (pc %03x)\n", io, v, outs[io]->b, d.m_core->ppc);
    io++;
  };
  d.m_external.rd = [&](uint32_t a) -> uint32_t {
    if (ix >= exts.size() || exts[ix]->t != 'R') { if (bad++ < 20) printf("EXT read %06x not in capture (pc %03x)\n", a, d.m_core->ppc); return 0; }
    const CapEv *e = exts[ix++];
    if ((e->a & 0xffffff) != a && bad++ < 20) printf("EXT read addr ref %06x mame %06x\n", a, e->a & 0xffffff);
    if (a >= 0x800000 && a < 0xa00000 && c.rom(a) != e->b && rombad++ < 5) printf("ROM %06x dump %08x mame %08x\n", a, c.rom(a), e->b);
    return e->b;
  };
  d.m_external.wr = [&](uint32_t a, uint32_t v) {
    if (ix >= exts.size() || exts[ix]->t != 'W') { if (bad++ < 20) printf("EXT write %06x not in capture\n", a); return; }
    const CapEv *e = exts[ix++];
    if (((e->a & 0xffffff) != a || e->b != v) && bad++ < 20) printf("EXT write ref %06x=%08x mame %06x=%08x\n", a, v, e->a & 0xffffff, e->b);
  };
  uint64_t trbad = 0;
  try {
    while (!end && nw < maxw) {
      uint32_t pc = d.execute_one();
      if (end) break;
      if (d.stalled()) { nstall++; continue; }
      if (itr < c.tr_pc.size()) {
        uint32_t h = d.state_hash();
        if ((c.tr_pc[itr] != pc || c.tr_h[itr] != h) && trbad++ < 10)
          printf("TRACE %zu: ref pc %03x h %08x, mame pc %03x h %08x\n", itr, pc, h, c.tr_pc[itr], c.tr_h[itr]);
        itr++;
      }
      nw++;
    }
  } catch (const std::exception &e) { printf("FATAL %s after %llu words\n", e.what(), (unsigned long long)nw); bad++; }
  printf("%s: %llu words, %llu stall passes, pops %zu/%zu, outs %zu/%zu, ext %zu/%zu, trace %zu checked %llu bad, out/ext bad %llu, rom bad %llu\n",
         clean ? "clean" : "mame", (unsigned long long)nw, (unsigned long long)nstall, ip, pops.size(), io, outs.size(), ix, exts.size(),
         itr, (unsigned long long)trbad, (unsigned long long)bad, (unsigned long long)rombad);
  return (bad || trbad || rombad) ? 1 : 0;
}
