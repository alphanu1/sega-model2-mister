// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// tb_m2_sdram_cdc_load (R881): EVERY WORD THE 2A BUILD'S SDRAM PATH RETURNS,
// CHECKED, WITH THE SOUND BOARD'S REAL REQUESTERS ON THE REAL CROSSING.
//
// m2_sdram_cdc_load_harness.sv: the real m2_2a_sound (ports 5, 6, 7) through
// the real m2_sdram_cdc and m2_sdram (the 2A class, COL_BITS 10) to the device
// model, whose unwritten words read a hash of their address; clk_sys (80 MHz)
// and clk_mem (100 MHz) driven independently here, with a phase offset, a
// drift and a jitter, so the crossing sees every alignment. A synthetic video
// load on 1-4 and 8-12 and the write port (tb_m2_sdram_load's frame: a render
// phase in which they re-request after a random think, then a trickle).
//
// THE CHECKS
//   port level  every read word on every port, at the clock its requester took
//               the acknowledge, against the shadow of every write: legal
//               values are the newest write certainly landed before the read
//               was raised, and any write in flight at some time during it.
//               Writes are timed from their request (raised) to their
//               acknowledge (taken), so the set is exact, not a tolerance.
//   68000       each bus cycle's data: the program and samples exactly (the
//               ROM's hash, byte-swapped as ROM_SWAP); RAM it alone writes
//               exactly -- its posted writes and R871's merges must be seen by
//               its own later reads; the DSP's area through the port check.
//   slots (6)   each cache hit against the shadow as it stood up to STALE clk_sys
//               before the hit: a snoop that lost a write leaves a line stale
//               for ever, and this is where it would show.
//   DSP (7)     each read: its own area exactly, the rest as the slots.
//   contract    a request's address / data / direction unchanged while it
//               waits; never dropped before its acknowledge; a slow port's
//               acknowledge never without its request; an eight-word read gets
//               exactly one first half; no request waits longer than WATCHDOG.
//   totals      after a drain, the device served exactly the READ and WRITE
//               commands the requesters asked for -- nothing lost, nothing twice.
//   boot        m2_2a_sound's own sound-RAM check (dbg_selftest) reads 0.
//   device      0 protocol violations.
//
// Knobs (environment): SEED, RUN_MS (simulated ms after the boot, default 20),
// LOAD_THINK (video think in clk_mem, default 20), LOAD_RENDER (percent, 75),
// CDC_PHASE (ps, clk_sys's first edge), CDC_DRIFT (ps added to each clk_sys
// period, default 1), CDC_JIT (ps, uniform +- on each half period),
// C68_GAP (clk_sys idle after a bus cycle, mean, default 10), BOOT_FULL=1 (the
// whole 256 K-word clear; default jumps it to its last 256 words), VERBOSE.
#include "Vm2_sdram_cdc_load_harness.h"
#include "Vm2_sdram_cdc_load_harness___024root.h"
#include "Vm2_sdram_cdc_load_harness__Dpi.h"
#include "svdpi.h"
#include "verilated.h"
#include <algorithm>
#include <climits>
#include <cmath>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <string>
#include <unordered_map>
#include <vector>

static const int      NP = 13, NPW = 14;                 // + the write port
static const uint32_t AMASK = (1u << 25) - 1;            // COL_BITS 10: [25:1]
static const uint32_t RAM_BASE = 0x12C0000, ROM_BASE = 0x1260000, SMP_BASE = 0x1A00000;
static const uint32_t FAST = 0x1C0C, LONG = 0x1C04;
static const int64_t  INF = INT64_MAX;
// regions (word addresses)
static const uint32_t I960 = 0x0100000, GLYPH = 0x0200000, BUFR = 0x0280000, GEO = 0x0300000, TGPT = 0x0400000;
// sound RAM areas (word index into the 256 K words)
static const uint32_t VARS_LO = 0x01000, VARS_HI = 0x08000, RING0 = 0x08000, NRING = 16, RINGW = 0x800;
static const uint32_t DSP_LO = 0x30000;

static double envd(const char* n, double d) { const char* s = getenv(n); return s ? atof(s) : d; }

static int64_t  g_now = 0, g_tsys = 12500, g_tmem = 10000;
static bool     g_ready = false, g_go = false, g_drain = false;
static int64_t  g_t_go = 0, g_t_ready = 0;
static std::mt19937_64 rng;
static double   urand() { return double(rng() >> 11) * (1.0 / 9007199254740992.0); }
static double   expo(double m) { return -m * std::log(1.0 - urand()); }
static uint32_t rnd(uint32_t n) { return uint32_t(rng() % n); }
static uint16_t hash16(uint32_t a) { return uint16_t((a * 0x9E3779B1u) >> 16); }
static uint16_t swp(uint16_t w) { return uint16_t((w << 8) | (w >> 8)); }
static int      burst(int p) { return ((LONG >> p) & 1) ? 8 : (p == 8 || p == 9) ? 2 : 4; }
static bool     fast(int p) { return p < NP && ((FAST >> p) & 1); }

static double   think_mean, render;
static int64_t  STALE, WATCHDOG;
static const long FRAME = 1739000;                       // clk_mem cycles, 57.5 Hz
static bool     verbose = false;

static long     fails = 0;
static long     n_checks = 0, n_lvl68 = 0, n_slot = 0, n_dsp = 0, n_raced = 0;
static void fail_msg(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
static void fail_msg(const char* fmt, ...) {
  if (fails++ < 40) {
    va_list ap; va_start(ap, fmt);
    printf("  FAIL @%.3f us: ", g_now / 1e6); vprintf(fmt, ap); printf("\n");
    va_end(ap);
  }
}

// ------------------------------------------------------------------- shadow
struct WRec { uint16_t v; int64_t ti, td; int port; };
static std::unordered_map<uint32_t, std::vector<WRec>> hist;
static const int64_t HORIZON = 400000000;                // 400 us: longer than any request may wait

static void prune(std::vector<WRec>& h) {
  const int64_t T = g_now - HORIZON;
  h.erase(std::remove_if(h.begin(), h.end(), [&](const WRec& w) {
            if (w.td == INF) return false;
            for (auto& w2 : h) if (w2.ti > w.td && w2.td < T) return true;
            return false; }), h.end());
}
static void push_write(uint32_t a, uint16_t v, int port) {
  auto& h = hist[a];
  if (h.size() > 6) prune(h);
  h.push_back({v, g_now, INF, port});
}
static void done_write(uint32_t a, int port, int64_t ti) {
  auto it = hist.find(a);
  if (it != hist.end())
    for (auto& w : it->second) if (w.port == port && w.ti == ti && w.td == INF) { w.td = g_now; return; }
  fail_msg("p%d write to %07x acknowledged but never recorded", port, a);
}
// legal values of word a for a read raised at tri and taken at tra
static void cands(uint32_t a, int64_t tri, int64_t tra, std::vector<uint16_t>& out) {
  out.clear();
  auto it = hist.find(a);
  if (it == hist.end()) { out.push_back(hash16(a)); return; }
  auto& h = it->second;
  bool sup0 = false;
  for (auto& w : h) if (w.td < tri) { sup0 = true; break; }
  if (!sup0) out.push_back(hash16(a));
  for (auto& w : h) {
    if (w.td < tri) {
      bool sup = false;
      for (auto& w2 : h) if (w2.ti > w.td && w2.td < tri) { sup = true; break; }
      if (!sup) out.push_back(w.v);
    } else if (w.ti < tra) out.push_back(w.v);
  }
}
// the one value certainly current at t (all writes before it landed), for the exact shadows
static uint16_t value_at(uint32_t a, int64_t t) {
  auto it = hist.find(a);
  uint16_t v = hash16(a); int64_t best = -1;
  if (it != hist.end()) for (auto& w : it->second) if (w.td < t && w.td > best) { best = w.td; v = w.v; }
  return v;
}
static bool check_word(const char* who, int port, uint32_t a, uint16_t got, int64_t tri, int64_t tra) {
  static std::vector<uint16_t> c;
  cands(a, tri, tra, c);
  n_checks++;
  if (std::find(c.begin(), c.end(), got) != c.end()) { if (c.size() > 1) n_raced++; return true; }
  std::string s;
  for (auto v : c) { char b[8]; snprintf(b, sizeof b, " %04x", v); s += b; }
  fail_msg("%s p%d word %07x got %04x, legal {%s } (raised %.3f us)", who, port, a, got, s.c_str(), tri / 1e6);
  return false;
}

// ------------------------------------------------------------ the monitors
struct Mon {
  bool out = false, acked = false, we = false;
  uint32_t a = 0; uint16_t din = 0; int64_t ti = 0;
  uint64_t lo = 0; int lo_n = 0;
  long n_rd = 0, n_wr = 0; std::vector<int64_t> lat;
} mon[NPW];
static long dev_reads = 0, dev_writes = 0;

extern "C" void tb_mon(int port, svBit req, svBit ack, svBit we, int addr, int din, long long dout) {
  Mon& m = mon[port];
  const uint32_t a = uint32_t(addr) & AMASK;
  if (req && !m.out) {
    m.out = true; m.acked = false; m.we = we; m.a = a; m.din = uint16_t(din); m.ti = g_now; m.lo_n = 0;
    if (we) push_write(a, m.din, port);
  } else if (m.out && req && !m.acked && (a != m.a || bool(we) != m.we || (we && uint16_t(din) != m.din)))
    fail_msg("p%d request changed while it waited: %07x/%d/%04x -> %07x/%d/%04x", port, m.a, m.we, m.din, a, int(we), din & 0xffff);
  if (m.out) {
    if (req && ack && !m.acked) {
      m.acked = true;
      m.lat.push_back(g_now - m.ti);
      if (m.we) { done_write(m.a, port, m.ti); m.n_wr++; dev_writes++; }
      else {
        const int n = burst(port);
        m.n_rd++; dev_reads += n;
        if (n == 8 && m.lo_n != 1) fail_msg("p%d: %d first halves for one eight-word read", port, m.lo_n);
        for (int w = 0; w < n; w++) {
          const uint64_t src = (n == 8 && w < 4) ? m.lo : uint64_t(dout);
          check_word("read", port, (m.a + w) & AMASK, uint16_t(src >> (16 * (w & 3))), m.ti, g_now);
        }
      }
    }
    if (!req) {
      if (!m.acked) fail_msg("p%d request dropped before its acknowledge", port);
      m.out = false;
    }
    if (m.out && !m.acked && g_now - m.ti > WATCHDOG) {
      fail_msg("p%d request at %07x waiting %.1f us", port, m.a, (g_now - m.ti) / 1e6); m.ti = g_now;
    }
  }
  if (!req && ack && !fast(port)) fail_msg("p%d acknowledge without a request", port);
}
extern "C" void tb_mon_lo(int port, long long dout) { mon[port].lo = uint64_t(dout); mon[port].lo_n++; }

// ------------------------------------------------- the video and write ports
struct Rq { int st = 0; int64_t next = 0; bool we = false; uint32_t a = 0; uint16_t d = 0; uint32_t seq = 0; } rq[NPW];
static bool in_render() { return ((g_now / g_tmem) % FRAME) < long(render * FRAME); }
static double vthink(int p) { return p == 1 ? 3.0 : p == 3 ? 4.0 : p == 4 ? 2.0 : (p == 8 || p == 9) ? 6.0 : p == 13 ? 4.0 : 1.0; }
static int64_t think(int p) {
  if (in_render()) return int64_t(expo(think_mean * vthink(p))) * g_tmem;
  return (rnd(64) == 0) ? 0 : 64 * g_tmem;               // quiet: a trickle
}
static void choose(int p, Rq& r) {
  auto walk = [&](uint32_t base, uint32_t span, uint32_t step) {
    r.seq = (rnd(8) == 0) ? rnd(span) : (r.seq + step) % span;
    return (base + r.seq) & AMASK;
  };
  r.we = false; r.d = uint16_t(rng());
  switch (p) {
    case 1:  r.we = urand() < 0.3; r.a = walk(I960, 0x10000, 4); if (!r.we) r.a &= ~3u; break;   // the i960
    case 3:  r.a = walk(GLYPH, 0x8000, 4) & ~3u; break;
    case 4:  r.a = walk(GEO, 0x10000, 4) & ~3u; break;
    case 8:  r.a = walk(TGPT, 0x20000, 2) & ~1u; break;
    case 9:  r.a = walk(BUFR, 0x10000, 2) & ~1u; break;
    case 13: r.we = true; r.a = (rnd(2) ? GEO + rnd(0x10000) : BUFR + rnd(0x10000)) & AMASK; break;
    default: r.a = walk(0, AMASK + 1, 8) & ~7u; break;  // texel misses: anywhere, sound RAM included
  }
}
extern "C" void tb_req_step(int port, svBit ack, svBit* req, int* addr, svBit* we, int* din) {
  Rq& r = rq[port];
  if (r.st == 1) { if (ack) { r.st = 2; r.next = g_now + think(port); } }
  else if (g_ready && !g_drain && port != 0 && g_now >= r.next) { choose(port, r); r.st = 1; }
  else r.st = 0;
  *req = r.st == 1; *addr = int(r.a); *we = r.we; *din = r.d;
}

// ---------------------------------------------------------------- the 68000
static std::unordered_map<uint32_t, uint16_t> s68, s7;   // exact shadows, by sound-RAM word
static uint16_t sget(std::unordered_map<uint32_t, uint16_t>& s, uint32_t w) {
  auto it = s.find(w);
  if (it != s.end()) return it->second;
  const uint16_t v = value_at(RAM_BASE + w, g_t_go);
  s[w] = v; return v;
}
static uint32_t wp[NRING];                               // the 68000's ring write pointers
struct C68 {
  int st = 0; long cyc = 0, next = 0, hold = 0; int kind = 0; bool rw = true, uds = false, lds = false;
  uint32_t a = 0; uint16_t d = 0; int64_t t0 = 0; uint32_t pc = 0, sp = 0; long n[8] = {0};
} c68;
static double c68_gap;
enum { K_FETCH, K_SMP, K_RD, K_WR, K_WB, K_SCSP };
static void c68_choose() {
  C68& c = c68;
  const double u = urand();
  c.rw = true; c.uds = c.lds = true; c.d = uint16_t(rng());
  // (MAME's VF2, R877: program 1.23 M, samples 226 K, RAM reads 218 K, writes 270 K a second)
  if (u < 0.55) {                                       // code: loops in a 1 KB hot spot, a far jump now and then
    c.kind = K_FETCH;
    if (rnd(300) == 0) c.pc = rnd(0x40000) * 2;
    else c.pc = (rnd(16) == 0) ? (c.pc & ~0x3feu) | (rnd(0x200) * 2) : (c.pc & ~0x3feu) | ((c.pc + 2) & 0x3fe);
    c.a = 0x600000 + c.pc;
  }
  else if (u < 0.67) { c.kind = K_SMP; c.sp = (rnd(50) == 0) ? rnd(0x400000) * 2 : (c.sp + 2) & 0x7ffffe; c.a = 0x800000 + c.sp; }
  else if (u < 0.79) {
    c.kind = K_RD;
    const double v = urand();
    const uint32_t w = v < 0.6 ? VARS_LO + rnd(VARS_HI - VARS_LO) : v < 0.85 ? RING0 + rnd(NRING * RINGW) : DSP_LO + rnd(0x10000);
    c.a = w * 2;
  } else if (u < 0.94) {
    c.kind = K_WR; c.rw = false;
    uint32_t w;
    if (urand() < 0.7) { const uint32_t r = rnd(NRING); w = RING0 + r * RINGW + wp[r]; wp[r] = (wp[r] + 1) % RINGW; }
    else w = VARS_LO + rnd(VARS_HI - VARS_LO);
    c.a = w * 2;
  } else if (u < 0.97) {
    c.kind = K_WB; c.rw = false;
    c.a = (VARS_LO + rnd(VARS_HI - VARS_LO)) * 2;
    if (rnd(2)) c.uds = false; else c.lds = false;      // one strobe
    c.d = uint16_t((c.d & 0xff) * 0x101);               // the byte on both halves, as a 68000 drives it
  } else { c.kind = K_SCSP; c.rw = rnd(2); c.a = 0x100000 + rnd(0x800) * 2; }
}
static void c68_done(uint16_t iedb) {
  C68& c = c68;
  c.n[c.kind]++;
  const uint32_t w = (c.a >> 1) & 0x3ffff;
  switch (c.kind) {
    case K_FETCH: case K_SMP: {
      const uint32_t rw = (c.kind == K_FETCH ? ROM_BASE + ((c.a >> 1) & 0x3ffff) : SMP_BASE + ((c.a >> 1) & 0x3fffff)) & AMASK;
      n_lvl68++;
      if (iedb != swp(hash16(rw))) fail_msg("68000 %s read %06x got %04x want %04x", c.kind == K_FETCH ? "program" : "sample", c.a, iedb, swp(hash16(rw)));
      break;
    }
    case K_RD:
      if (w >= DSP_LO) break;                           // the DSP writes there: the port check has it
      n_lvl68++;
      if (iedb != sget(s68, w)) fail_msg("68000 RAM read %06x got %04x want %04x (its own writes)", c.a, iedb, sget(s68, w));
      break;
    case K_WR: s68[w] = c.d; break;
    case K_WB: { const uint16_t o = sget(s68, w); s68[w] = c.uds ? uint16_t((c.d & 0xff00) | (o & 0x00ff)) : uint16_t((o & 0xff00) | (c.d & 0x00ff)); break; }
    default: break;
  }
}
extern "C" void c68_step(svBit rst, svBit dtackn, int iedb, svBit* asn, svBit* rwn, svBit* udsn, svBit* ldsn, int* a, int* d) {
  C68& c = c68;
  if (rst) { c.st = 0; *asn = 1; *rwn = 1; *udsn = 1; *ldsn = 1; *a = 0; *d = 0; return; }
  if (!g_go) { g_go = true; g_t_go = g_now; }
  c.cyc++;
  switch (c.st) {
    case 0: if (!g_drain && dtackn && c.cyc >= c.next) { c68_choose(); c.st = 1; c.t0 = g_now; } break;
    case 1: if (!dtackn) { c68_done(uint16_t(iedb)); c.st = 2; c.hold = 1 + rnd(6); } break;
    default: if (--c.hold <= 0) { c.st = 0; c.next = c.cyc + 1 + long(expo(c68_gap)); } break;
  }
  const bool as = c.st != 0;
  *asn = !as; *rwn = as ? c.rw : 1; *udsn = as ? !c.uds : 1; *ldsn = as ? !c.lds : 1;
  *a = int(c.a); *d = c.d;
}

// ---------------------------------------------------------- the SCSP's slots
// 32 slots, each playing a ring (slot % 16) a fixed distance behind the
// 68000's write pointer -- some of them on the very line being written, as
// VF2's slots start 16 samples after the copy (R874) -- a word per lookup, so
// most lookups hit and the misses are the lines the 68000 has just filled.
static long slot_go = 0;
static uint32_t slot_i = 0, slot_back[32];
extern "C" void c6_step(svBit rst, svBit* go, int* line) {
  *go = 0; *line = 0;
  if (rst || !g_go || g_drain || rnd(3)) return;
  if (slot_go == 0) for (int s = 0; s < 32; s++) slot_back[s] = (s < 12) ? rnd(8) : rnd(512);
  uint32_t w;
  const double u = urand();
  if (u < 0.92) {
    const uint32_t s = slot_i++ & 31, r = s % NRING;
    w = RING0 + r * RINGW + (wp[r] + RINGW - slot_back[s]) % RINGW;
  } else if (u < 0.96) w = VARS_LO + rnd(VARS_HI - VARS_LO);
  else w = DSP_LO + rnd(0x10000);
  *go = 1; *line = int(w >> 2); slot_go++;
}
extern "C" void c6_hit(int line, long long data) {
  for (int i = 0; i < 4; i++) {
    n_slot++;
    check_word("slot hit", 6, RAM_BASE + uint32_t(line) * 4 + i, uint16_t(uint64_t(data) >> (16 * i)), g_now - STALE, g_now);
  }
}

// ----------------------------------------------------------- the SCSP's DSP
static uint32_t dsp_base = 0; static long dsp_tick = 0;
static bool p7_wr = false; static uint32_t p7_wa = 0; static uint16_t p7_wd = 0;
extern "C" void c7_step(svBit rst, svBit idle, svBit* go, svBit* rd, svBit* wr, int* addr, int* wdata) {
  *go = 0; *rd = 0; *wr = 0; *addr = 0; *wdata = 0;
  if (rst || !idle || !g_go || g_drain) return;
  if (++dsp_tick % 1814 == 0) dsp_base++;               // the ring moves a word per 44.1 kHz sample
  if (rnd(40)) return;
  const double u = urand();
  const bool r = u < 0.8, w = u >= 0.7;                 // 70% read, 20% write, 10% both (one address)
  uint32_t a = DSP_LO + ((dsp_base + rnd(0x2000)) & 0xffff);
  if (r && !w && rnd(7) == 0) a = rnd(DSP_LO);           // a read of the 68000's areas
  const uint16_t d = uint16_t(rng());
  *go = 1; *rd = r; *wr = w; *addr = int(a); *wdata = d;
  if (w && !r) s7[a] = d;
  else if (w) { p7_wr = true; p7_wa = a; p7_wd = d; }  // lands after the read
}
extern "C" void c7_read(int addr, int word) {
  const uint32_t w = uint32_t(addr) & 0x3ffff;
  n_dsp++;
  if (w >= DSP_LO) {
    n_checks++;
    if (uint16_t(word) != sget(s7, w)) fail_msg("DSP read %05x got %04x want %04x (its own writes)", w, word & 0xffff, sget(s7, w));
  } else check_word("DSP read", 7, RAM_BASE + w, uint16_t(word), g_now - STALE, g_now);
  if (p7_wr) { if (p7_wa != w) fail_msg("DSP step read %05x but writes %05x", w, p7_wa); s7[p7_wa] = p7_wd; p7_wr = false; }
}

// ------------------------------------------------------------------- main
static void stats(int p, const char* name) {
  auto& v = mon[p].lat;
  if (v.empty()) return;
  std::sort(v.begin(), v.end());
  auto q = [&](double f) { return v[std::min(v.size() - 1, size_t(f * v.size()))] / 1000.0; };
  printf("  %2d %-9s %9ld rd %9ld wr   latency ns p50 %6.0f p99 %6.0f max %6.0f\n", p, name, mon[p].n_rd, mon[p].n_wr, q(.5), q(.99), v.back() / 1000.0);
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  rng.seed(uint64_t(envd("SEED", 881)));
  think_mean = envd("LOAD_THINK", 20.0);
  render = envd("LOAD_RENDER", 75.0) / 100.0;
  c68_gap = envd("C68_GAP", 10.0);
  verbose = getenv("VERBOSE") != nullptr;
  const double run_ms = envd("RUN_MS", 20.0);
  const int64_t drift = int64_t(envd("CDC_DRIFT", 1.0)), jit = int64_t(envd("CDC_JIT", 0.0));
  const int64_t phase = int64_t(envd("CDC_PHASE", 3333.0));
  const bool boot_full = getenv("BOOT_FULL") != nullptr;
  g_tsys = 12500 + drift;
  STALE = 32 * 12500; WATCHDOG = 200000000;            // 200 us
  printf("tb_m2_sdram_cdc_load: seed %.0f, %.1f ms after boot, think %.0f, render %.0f%%, clk_sys %lld ps (+-%lld), phase %lld ps\n",
         envd("SEED", 881), run_ms, think_mean, render * 100, (long long)g_tsys, (long long)jit, (long long)phase);

  auto* d = new Vm2_sdram_cdc_load_harness;
  auto* r = d->rootp;
  d->clk_sys = 0; d->clk_mem = 0; d->rst_n = 0; d->snd_rst_n = 0; d->eval();
  int64_t tm = 0, ts = phase;
  bool cm = false, cs = false;
  long mem_cyc = 0, sys_cyc = 0;
  int64_t t_end = INF, t_drain_quiet = INF;
  for (;;) {
    const int64_t t = std::min(tm, ts);
    g_now = t;
    bool sys_pos = false;
    if (tm == t) { cm = !cm; d->clk_mem = cm; tm += g_tmem / 2; mem_cyc += cm; }
    if (ts == t) {
      cs = !cs; d->clk_sys = cs; sys_pos = cs; sys_cyc += cs;
      int64_t h = g_tsys / 2 + (cs ? (g_tsys & 1) : 0);
      if (jit) h += int64_t(rng() % (2 * jit + 1)) - jit;
      ts += h;
    }
    d->eval();
    if (!sys_pos) continue;
    // ---- control, once per clk_sys
    if (sys_cyc == 20) d->rst_n = 1;
    if (!g_ready && d->ready) { g_ready = true; g_t_ready = g_now; }
    if (g_ready && !d->snd_rst_n && g_now - g_t_ready > 100 * g_tsys) d->snd_rst_n = 1;
    if (!boot_full && r->m2_sdram_cdc_load_harness__DOT__u_snd__DOT__bs == 4 /* V_ZR */
        && r->m2_sdram_cdc_load_harness__DOT__u_snd__DOT__ti < 0x3ff00)
      r->m2_sdram_cdc_load_harness__DOT__u_snd__DOT__ti = 0x3ff00;
    if (g_go && t_end == INF) {
      t_end = g_now + int64_t(run_ms * 1e9);
      printf("  boot: %.2f ms to the 68000 running; the sound-RAM check reads %u wrong\n", g_now / 1e9, d->selftest);
      if (d->selftest) fail_msg("m2_2a_sound's sound-RAM check read %u words wrong", d->selftest);
    }
    if (!g_drain && g_now >= t_end) g_drain = true;
    if (g_now > 2000000000000LL && !g_go) { fail_msg("the 68000 never started"); break; }
    if (g_drain) {
      bool busy = c68.st != 0 || r->m2_sdram_cdc_load_harness__DOT__u_snd__DOT__wpost;
      for (int p = 0; p < NPW; p++) busy |= mon[p].out;
      if (busy) t_drain_quiet = INF;
      else if (t_drain_quiet == INF) t_drain_quiet = g_now;
      else if (g_now - t_drain_quiet > 4000 * g_tsys) break;
      if (g_now - t_end > 2000000000LL) { fail_msg("the drain never went quiet"); break; }
    }
  }
  d->final();
  printf("  ran %.2f ms: %ld clk_mem, %ld clk_sys cycles\n", g_now / 1e9, mem_cyc, sys_cyc);
  printf("  port               reads    writes\n");
  const char* nm[NPW] = {"-", "i960", "texel2", "glyph", "walker", "68000", "slots", "DSP", "tgp tbl", "tgp dat", "texel10", "texel11", "texel12", "write"};
  long txn = 0;
  for (int p = 0; p < NPW; p++) { stats(p, nm[p]); txn += mon[p].n_rd + mon[p].n_wr; }
  printf("  68000 cycles: program %ld, samples %ld, RAM reads %ld, word writes %ld, byte writes %ld, SCSP %ld\n",
         c68.n[K_FETCH], c68.n[K_SMP], c68.n[K_RD], c68.n[K_WR], c68.n[K_WB], c68.n[K_SCSP]);
  printf("  slot lookups %ld (%ld words checked on hits), DSP reads %ld\n", slot_go, n_slot, n_dsp);
  printf("  device: %u READs (requesters asked %ld), %u WRITEs (asked %ld), %u violations\n",
         d->reads_served, dev_reads, d->writes_served, dev_writes, d->violations);
  if (long(d->reads_served) != dev_reads) fail_msg("the device served %u READs for %ld asked", d->reads_served, dev_reads);
  if (long(d->writes_served) != dev_writes) fail_msg("the device served %u WRITEs for %ld asked", d->writes_served, dev_writes);
  if (d->violations) fail_msg("%u device protocol violations", d->violations);
  printf("  %ld transactions, %ld words checked (%ld with more than one legal value), %ld 68000 data checks: %ld FAILS\n",
         txn, n_checks, n_raced, n_lvl68, fails);
  printf("%s\n", fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
