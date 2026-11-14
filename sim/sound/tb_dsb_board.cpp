// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// The whole Digital Sound Board against MAME. From the Sega Model 1 core
// (sega-model1-mister 2657c46, sim/sound/tb_dsb_board.cpp); on Model 2 it runs
// Sega Touring Car Championship's board (and, with the Star Wars parameters,
// Model 1's), at clk_sys = 80 MHz (SYS_MHZ), behind m2_sdram_cdc's port contract.
//
// Fed exactly the bytes MAME's main CPU transmitted in a 300 s run
// (STCC: tools/dsb/stcc_dsb_cap.lua, the i960's i8251 at 0x01c80000; attract,
// coin at 150 s, start at 152 s), each arriving one character time (320 us)
// after it was written, with the Z80's ROM and RAM and the MPEG data behind a
// memory that answers in [1, LAT] cycles and reads 0xFFFF where nothing was
// written:
//
//   1. the Z80's port accesses against MAME's, in three streams, each in
//      order and value:  the UART (f0 reads and f0/f1 writes); the music
//      controls (writes to e0, e2-e7, e9, ea, eb); and the volume (e8 writes,
//      consecutive repeats collapsed -- STCC writes e8 on every pass of its
//      main loop, 800,000 times in 300 s, so how many land between two
//      controls is a matter of loop timing, not of what the board does).
//      Play-position reads (e2-e4) are counted, not compared: MAME's
//      position moves only when its sound stream is updated, ours as the
//      decoder reads. The time of each control write against MAME's is
//      reported, not asserted -- MAME schedules its Z80 in slices;
//   2. every decoded sample must equal tools/dsb/dsb_fixmodel.h driven by the
//      same port writes (bit-exact; that model is within 1 LSB of MAME's
//      decoder, tools/dsb/dsb_cmp.cpp);
//   3. every 32 kHz output sample must equal the decoded one with the volume
//      and pan in force.
//
//   DSB_SECS (default 70), DSB_LAT (default 40), DSB_VOLMAME (MAME's e8
//   reading; STCC on Model 2 uses it), DSB_Z80ROM / DSB_MPEG / DSB_CAP the
//   inputs, DSB_MB the MPEG image in MB (default 8), DSB_ROMB / DSB_MPB /
//   DSB_RAMB the SDRAM word bases (hex; default the 2C layout).
//   DSB_DUMP=<file> writes every 32 kHz output (tick number, source, L, R)
//   and every decoded sample with its clock, so two builds of the board can be
//   compared tick for tick (R1007: tools/dsb/dsb_dumpcmp.py).
#include "Vdsb_board_harness.h"
#include "verilated.h"
#include "dsb_fixmodel.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <random>
#include <string>
#include <vector>

static std::vector<uint8_t> mp, zr;
static double winf[512];

struct Ref {   // dsbz80.cpp's register and play logic around the fixed-point decoder
  FixDec *fx;
  uint32_t st = 0, en = 0, mp_start = 0, mp_end = 0, lp_start = 0, lp_end = 0, state = 0;
  int pos = 0;
  std::deque<uint32_t> q;
  Ref() { fx = new FixDec(mp.data(), FixCfg()); }
  void wr(int a, int v) {
    switch (a) {
      case 0: state = v; if (v == 0) q.clear(); else if (v == 1 || v == 2) pos = mp_start * 8; break;
      case 2: st = (st & 0x00ffff) | (v << 16); break;
      case 3: st = (st & 0xff00ff) | (v << 8); break;
      case 4: st = (st & 0xffff00) | v; if (state == 0) mp_start = st; else lp_start = st; break;
      case 5: en = (en & 0x00ffff) | (v << 16); break;
      case 6: en = (en & 0xff00ff) | (v << 8); break;
      case 7: en = (en & 0xffff00) | v; if (state == 0) mp_end = en; else lp_end = en; break;
    }
  }
  void next() {
    int16_t out[1152 * 2];
    while (state != 0) {
      int p = pos;
      if (fx->frame(p, mp_end * 8, out, winf)) {
        pos = p;
        for (int i = 0; i < 1152; i++)
          q.push_back(((uint32_t)(uint16_t)out[2 * i] << 16) | (uint16_t)out[2 * i + 1]);
        return;
      }
      if (state == 2) { if (pos == (int)lp_start * 8) state = 0; pos = lp_start * 8; if (lp_end) mp_end = lp_end; }
      else state = 0;
    }
  }
};

static std::vector<uint8_t> load(const char *p, size_t n, size_t pad) {
  std::vector<uint8_t> v(n + pad, 0xff);
  FILE *f = fopen(p, "rb"); if (!f) return {};
  size_t r = fread(v.data(), 1, n, f); fclose(f);
  if (r != n) return {};
  return v;
}

struct Ev { double t; int port, v; };
struct Stream {
  const char *name; std::deque<Ev> mame; long checks = 0, fails = 0, ours = 0;
  double dt_sum = 0, dt_max = 0; long dt_n = 0;
  void check(int port, int v, double t, long &tot) {
    ours++;
    if (mame.empty()) { if (tot < 20) printf("FAIL: %s: ours %02x=%02x at %.6f s, MAME has nothing more\n", name, port, v, t); fails++; tot++; return; }
    Ev e = mame.front(); mame.pop_front(); checks++;
    if (e.port != port || e.v != v) {
      if (tot < 20) printf("FAIL: %s %ld: ours %02x=%02x at %.6f s, MAME %02x=%02x at %.6f s\n", name, checks, port, v, t, e.port, e.v, e.t);
      fails++; tot++;
    }
    double dt = t - e.t; dt_sum += dt; dt_n++; if (fabs(dt) > fabs(dt_max)) dt_max = dt;
    if (getenv("DSB_SHOWT") && (fabs(dt) > atof(getenv("DSB_SHOWT")) * 1e-6))
      printf("  %s %ld: %02x=%02x ours %.6f MAME %.6f (%+.1f us)\n", name, checks, port, v, t, e.t, 1e6 * dt);
  }
};

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const char *zp  = getenv("DSB_Z80ROM") ? getenv("DSB_Z80ROM") : "build/rom/dsb/epr-19275.2s";
  const char *mpp = getenv("DSB_MPEG")   ? getenv("DSB_MPEG")   : "build/rom/dsb/mpeg.bin";
  const size_t MB = getenv("DSB_MB") ? (size_t)atoi(getenv("DSB_MB")) : 8;
  zr = load(zp, 128 << 10, 0); mp = load(mpp, MB << 20, 16 << 20);
  if (zr.empty() || mp.empty()) { printf("dsb_board: SKIPPED (ROMs not readable)\n"); return 0; }
  { FILE *t = fopen("rtl/sound/dsb_tables.svh", "r"); char line[256]; int i, v;
    while (fgets(line, sizeof line, t)) if (sscanf(line, "  win[%d] = %d;", &i, &v) == 2) winf[i] = (double)((v & 0x20000) ? v - 0x40000 : v) / 65536.0;
    fclose(t);
    // R1007: the RTL's table carries the synthesis's signs (negated where
    // i mod 64 >= 16, tools/dsb/gen_tables.py); the model takes ISO's window
    for (int k = 0; k < 512; k++) if ((k & 63) >= 16) winf[k] = -winf[k]; }
  double secs = getenv("DSB_SECS") ? atof(getenv("DSB_SECS")) : 70.0;
  int LAT = getenv("DSB_LAT") ? atoi(getenv("DSB_LAT")) : 40;
  int volmame = getenv("DSB_VOLMAME") ? atoi(getenv("DSB_VOLMAME")) : 0;
  const char *cap = getenv("DSB_CAP") ? getenv("DSB_CAP") : "build/rom/dsb/cap300.txt";
  const double CLK = getenv("DSB_CLK") ? atof(getenv("DSB_CLK")) : 80e6;   // clk_sys (SYS_MHZ)
  const uint32_t ROMB = getenv("DSB_ROMB") ? strtoul(getenv("DSB_ROMB"), 0, 16) : 0x3400000;
  const uint32_t MPB  = getenv("DSB_MPB")  ? strtoul(getenv("DSB_MPB"), 0, 16)  : 0x3000000;
  const uint32_t RAMB = getenv("DSB_RAMB") ? strtoul(getenv("DSB_RAMB"), 0, 16) : 0x3410000;

  // MAME's side: the bytes in, the port accesses out, in three streams
  std::deque<std::pair<uint64_t, int>> rx;
  Stream su{"uart"}, sc{"control"}, sv{"volume"};
  long mame_pos = 0;
  if (FILE *f = fopen(cap, "r")) {
    char line[256]; int lastv = -1;
    while (fgets(line, sizeof line, f)) {
      double t; char k[8]; unsigned a, b;
      int n = sscanf(line, "%lf %7s %x %x", &t, k, &a, &b);
      if (n == 3 && std::string(k) == "TX") rx.push_back({(uint64_t)((t + 320e-6) * CLK), (int)a});
      if (n != 4 || t >= secs) continue;
      if (std::string(k) == "ZW") {
        if (a == 0xf0 || a == 0xf1) su.mame.push_back({t, (int)a, (int)b});
        else if (a == 0xe8) { if ((int)b != lastv) sv.mame.push_back({t, (int)a, (int)b}); lastv = b; }
        else sc.mame.push_back({t, (int)a, (int)b});
      }
      if (std::string(k) == "ZR" && a == 0xf0) su.mame.push_back({t, 0x100 | (int)a, (int)b});
      if (std::string(k) == "ZR" && a >= 0xe2 && a <= 0xe4) mame_pos++;
    }
    fclose(f);
  } else { printf("dsb_board: SKIPPED (no capture %s)\n", cap); return 0; }

  // SDRAM image, word addressed: ROM, MPEG, RAM (RAM and the rest unwritten)
  std::vector<uint16_t> ram(0x4000, 0xffff);
  const uint32_t MPW = (uint32_t)(MB << 19);
  auto rd = [&](uint32_t a) -> uint16_t {
    if (a >= ROMB && a < ROMB + 0x10000) { uint32_t b = (a - ROMB) * 2; return zr[b] | (zr[b + 1] << 8); }
    if (a >= MPB && a < MPB + MPW)       { uint32_t b = (a - MPB) * 2;  return mp[b] | (mp[b + 1] << 8); }
    if (a >= RAMB && a < RAMB + 0x4000)  return ram[a - RAMB];
    return 0xffff;
  };

  auto *h = new Vdsb_board_harness;
  Ref ref;
  std::mt19937 rng(777);
  h->vol_mame = volmame; h->rst_n = 0; h->rx_tog = 0; h->s_ack = 0;
  for (int i = 0; i < 20; i++) { h->clk = 0; h->eval(); h->clk = 1; h->eval(); }
  h->rst_n = 1;

  long fails = 0, schk = 0, ochk = 0, rxn = 0, bad_mem = 0, nreq = 0, zreq_chip = 0, zreq_off = 0, our_pos = 0;
  std::deque<uint32_t> popq;
  FILE *dump = getenv("DSB_DUMP") ? fopen(getenv("DSB_DUMP"), "w") : nullptr;
  long ntick = 0;
  int vol = 0x7f, pan = 0, lastv = -1;
  // m2_sdram_cdc's slow side: s_req a level, held with its address and data
  // until s_ack; s_ack sticky while the request stands; then the request
  // drops for at least one cycle
  bool busy = false, acked = false, req_d = false, zr_d = false; int pend = 0;
  uint32_t pa = 0; bool pw = false; uint16_t pd = 0; uint8_t pbe = 0;
  uint64_t T = 0, cyc = 0, end = (uint64_t)(secs * CLK);
  while (cyc < end) {
    if (!rx.empty() && rx.front().first <= cyc) { h->rx_byte = rx.front().second; h->rx_tog ^= 1; rx.pop_front(); rxn++; }
    if (busy) {
      if (pend == 0) {
        if (pw) { if (pa >= RAMB && pa < RAMB + 0x4000) { uint16_t &w = ram[pa - RAMB];
                    if (pbe & 1) w = (w & 0xff00) | (pd & 0xff); if (pbe & 2) w = (w & 0x00ff) | (pd & 0xff00); }
                  else bad_mem++; }
        else h->s_dout = rd(pa);
        busy = false; acked = true;
      } else pend--;
    }
    h->s_ack = acked && h->s_req;
    h->clk = 0; h->eval(); h->clk = 1; h->eval();
    if (!h->s_req) acked = false;
    if (h->s_req && !busy && !acked) {
      if (req_d) { if (fails < 20) printf("FAIL: a request without the one-cycle gap\n"); fails++; }
      nreq++; busy = true;
      pa = h->s_addr; pw = h->s_we; pd = h->s_din; pbe = h->s_be; pend = (int)(rng() % LAT);
    }
    if (busy && (h->s_addr != pa || h->s_we != pw || (pw && h->s_din != pd))) {
      if (fails < 20) printf("FAIL: the request moved while it stood\n"); fails++;
    }
    req_d = h->s_req && acked;   // still up the cycle after its acknowledge
    if (h->z_req && !zr_d) { if (h->z_chip) zreq_chip++; else zreq_off++; }
    zr_d = h->z_req;
    if (h->tick) T++;
    // 1. port accesses against MAME
    if (h->io_wr || h->io_rd) {
      double t = T / 4e6; int a = h->io_addr, v = h->io_data;
      if (h->io_wr && (a == 0xf0 || a == 0xf1)) su.check(a, v, t, fails);
      else if (h->io_rd && a == 0xf0) su.check(0x100 | a, v, t, fails);
      else if (h->io_wr && a == 0xe8) { if (v != lastv) sv.check(a, v, t, fails); lastv = v; }
      else if (h->io_wr) sc.check(a, v, t, fails);
      else if (a >= 0xe2 && a <= 0xe4) our_pos++;
      if (h->io_wr && (a & 0xf0) == 0xe0) {
        int r = a & 0xf;
        ref.wr(r, v);
        if (r == 0 && v == 0) popq.clear();
        if (r == 8 && (volmame || !(v & 0x80))) vol = (~v) & 0x7f;
        if (r == 9) pan = v & 3;
      }
    }
    // 2. decoded samples against the model
    if (h->smp_stb) {
      if (dump) fprintf(dump, "S %llu %08x\n", (unsigned long long)cyc, h->smp_lr);
      popq.push_back(h->smp_lr);
      if (ref.q.empty()) ref.next();
      if (ref.q.empty()) { if (fails < 20) printf("FAIL: a sample the reference does not have\n"); fails++; }
      else { uint32_t e = ref.q.front(); ref.q.pop_front(); schk++;
             if (e != h->smp_lr) { if (fails < 20) printf("FAIL: sample %ld %08x vs %08x\n", schk, h->smp_lr, e); fails++; } }
      // EAGERLY, as MAME does (see Model 1's note): a frame that fails at the
      // end address still advances the synthesis history
      if (ref.q.empty()) ref.next();
    }
    // 3. the 32 kHz output
    if (h->out_stb) {
      if (dump) fprintf(dump, "O %ld %d %04x %04x\n", ntick, (int)h->out_src, (uint16_t)h->out_l, (uint16_t)h->out_r);
      ntick++;
      if (h->out_src && !popq.empty()) {
        uint32_t s = popq.front(); popq.pop_front();
        int16_t L = s >> 16, R = s & 0xffff, sl = pan == 2 ? R : L, sr = pan == 1 ? L : R;
        int16_t el = pan == 3 ? 0 : (int16_t)((sl * vol) >> 7), er = pan == 3 ? 0 : (int16_t)((sr * vol) >> 7);
        ochk++;
        if (el != (int16_t)h->out_l || er != (int16_t)h->out_r) { if (fails < 20) printf("FAIL: out %d %d vs %d %d\n", (int16_t)h->out_l, (int16_t)h->out_r, el, er); fails++; }
      }
    }
    cyc++;
  }
  if (h->trap) { printf("FAIL: the Z80 executed an opcode outside its census\n"); fails++; }
  if (bad_mem) { printf("FAIL: %ld writes outside the Z80's RAM\n", bad_mem); fails++; }
  for (Stream *s : {&su, &sc, &sv}) {
    if (s->mame.size() > 2) { printf("FAIL: %s: MAME made %zu more accesses than we did\n", s->name, s->mame.size()); fails++; }
    printf("  %-7s: ours %ld, compared %ld, fails %ld, MAME left %zu, dt mean %+.1f us, max %+.1f us\n", s->name, s->ours, s->checks,
           s->fails, s->mame.size(), s->dt_n ? 1e6 * s->dt_sum / s->dt_n : 0.0, 1e6 * s->dt_max);
  }
  printf("  position reads: ours %ld, MAME %ld (not compared)\n", our_pos, mame_pos);
  printf("  Z80 memory: %ld on chip, %ld through the cache / SDRAM (%.0f/s)\n", zreq_chip, zreq_off, zreq_off / secs);
  printf("dsb_board[lat=%d%s,%.0fs]: fails=%ld samples=%ld out=%ld rx=%ld sdram=%.0f/s\n",
         LAT, volmame ? ",volmame" : "", secs, fails, schk, ochk, rxn, nreq / secs);
  if (dump) fclose(dump);
  delete h;
  return fails ? 1 : 0;
}
