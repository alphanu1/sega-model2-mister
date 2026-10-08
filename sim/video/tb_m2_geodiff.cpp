// THE GEOMETRY DIFFERENTIAL (R643). One walk of MAME's (patch p14:
// M2GEO_WALK/M2GEO_OUT) replayed through this core's walker + projection +
// geometry (sim/video/geodiff_top.sv), every quad written to ours.txt for
// build/m2scripts/geodiff.py to set against MAME's geopolys.txt.
//
// The memories are laid out as Model2.sv lays them out in SDRAM (16-bit words
// at the GAME_* bases) and served through the same address arithmetic as its
// engine port (eng_base / eng_mem_idx), so a mapping fault shows up here too.
//
//   M2GD_DIR=<dump dir>   required
//   M2GD_STATE=1          preload the walk's inherited state from state.txt
#include "Vgeodiff_top.h"
#include "Vgeodiff_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <map>
#include <set>
#include <deque>
#include <algorithm>

static Vgeodiff_top *d;
static std::vector<uint16_t> mem(1u << 25, 0xFFFF);   // unwritten reads 0xFFFF (docs/mister-integration.md)
static std::vector<uint32_t> buf;                      // bufferram, dwords

static const uint32_t GAME_BUFFER = 0x16f0000, GAME_PRAM0 = 0x1710000, GAME_PRAM1 = 0x1720000,
                      GAME_PAL3D = 0x1730000, GAME_XLAT3D = 0x1731000, GAME_TEXRAM = 0x1740000,
                      GAME_TEX = 0x0720000, GAME_POLY = 0x0b20000;

static bool load(const std::string &p, std::vector<uint8_t> &v) {
  FILE *f = std::fopen(p.c_str(), "rb"); if (!f) { std::printf("  missing %s\n", p.c_str()); return false; }
  std::fseek(f, 0, SEEK_END); long n = std::ftell(f); std::fseek(f, 0, SEEK_SET);
  v.resize(n); bool ok = std::fread(v.data(), 1, n, f) == size_t(n); std::fclose(f); return ok;
}
static void put_dwords(uint32_t base, const std::vector<uint8_t> &v, size_t maxdw) {
  for (size_t i = 0; i * 4 + 3 < v.size() && i < maxdw; i++) {
    uint32_t w; std::memcpy(&w, &v[i * 4], 4);
    mem[base + 2 * i] = w & 0xffff; mem[base + 2 * i + 1] = w >> 16;
  }
}
static void put_words(uint32_t base, const std::vector<uint8_t> &v, size_t first, size_t n) {
  for (size_t i = 0; i < n && (first + i) * 2 + 1 < v.size(); i++) {
    uint16_t w; std::memcpy(&w, &v[(first + i) * 2], 2); mem[base + i] = w;
  }
}

// R696: the 16-bit SDRAM word address eng_read reads from.
static uint32_t eng_wordaddr(uint32_t space, uint32_t a, uint32_t oba);
// Model2.sv's engine port: which memory, and which dword in it.
static uint32_t eng_read(uint32_t space, uint32_t a, uint32_t oba) {
  uint32_t base, idx;
  if (space == 1)      { base = (a & 0x800000) ? GAME_TEXRAM : GAME_TEX; idx = (a & 0x800000) ? (a & 0x7fff) : (a & 0x1fffff); }
  else if (space == 2) { base = GAME_PAL3D;  idx = a & 0x1ff; }
  else if (space == 3) { base = GAME_XLAT3D; idx = a & 0x3fff; }
  else {
    base = (oba & 0x1000000) ? GAME_PRAM1 : (oba & 0x800000) ? GAME_POLY : GAME_PRAM0;
    idx  = ((oba & 0x1000000) || !(oba & 0x800000)) ? (a & 0x7fff) : (a & 0x3fffff);
  }
  const uint32_t wa = (base + 2 * idx) & ((1u << 25) - 1);
  return uint32_t(mem[wa]) | (uint32_t(mem[(wa + 1) & ((1u << 25) - 1)]) << 16);
}

static long g_memreqs = 0, g_repeat = 0, g_porttrips = 0;   // R696
static std::map<int, long> g_rd_by;
static std::set<uint64_t> g_seen;
static uint32_t eng_wordaddr(uint32_t space, uint32_t a, uint32_t oba) {
  uint32_t base, idx;
  if (space == 1)      { base = (a & 0x800000) ? GAME_TEXRAM : GAME_TEX; idx = (a & 0x800000) ? (a & 0x7fff) : (a & 0x1fffff); }
  else if (space == 2) { base = GAME_PAL3D;  idx = a & 0x1ff; }
  else if (space == 3) { base = GAME_XLAT3D; idx = a & 0x3fff; }
  else {
    base = (oba & 0x1000000) ? GAME_PRAM1 : (oba & 0x800000) ? GAME_POLY : GAME_PRAM0;
    idx  = ((oba & 0x1000000) || !(oba & 0x800000)) ? (a & 0x7fff) : (a & 0x3fffff);
  }
  return (base + 2 * idx) & ((1u << 25) - 1);
}
// R707: M2GD_PC=3/4 -- READ-AHEAD. A stream per memory space (3), or one
// shared (4), fetches the pairs after the engine's last miss before they are
// asked for: M2GD_RA pairs ahead (default 4). One port: a fetch occupies it
// M2GD_OCC cycles (default LAT, one in flight; less is a pipelined port) and
// answers LAT after it issues. A read of a pair the stream holds or has in
// flight waits only for its arrival; anything else is a miss and restarts the
// stream there. The whole last pair is kept, as PC=2. Writes are ignored: a
// best case, so the copies are never made stale.
// R709: the safe design's limits. M2GD_RAMASK: the memory spaces that get a
// stream (bit per space, default all); the others make a port trip for every
// read. M2GD_RAFLUSH=1: every stream is dropped when the engine starts an
// object, so no copy outlives one. M2GD_RAALIGN=1: a stream starts at the even
// dword at or below the miss, as the RTL's pairs {2k, 2k+1} do. M2GD_RANOTR=1:
// no stream for texture headers in texture RAM, which the CPU writes.
static long g_cyc = 0, g_pf = 0, g_rahit = 0, g_wrflush = 0;
struct RaStream { bool act = false; uint32_t next = 0, last = ~0u; std::deque<std::pair<uint32_t, long>> q; };
static RaStream g_ra[4]; static long g_port_free = 0; static int g_ra_rr = 0;
static int g_ra_align = 0;
static int ra_trip(uint32_t dw, int lat, int occ) {
  const long issue = std::max(g_cyc, g_port_free);
  g_port_free = issue + occ; ++g_porttrips;
  return int(issue + lat - g_cyc);
}
static int ra_read(RaStream &S, uint32_t dw, int lat, int occ) {
  while (!S.q.empty() && dw > S.q.front().first + 1 && dw - S.q.front().first < 4096) S.q.pop_front();
  for (auto &e : S.q)
    if (dw >= e.first && dw <= e.first + 1) { S.last = e.first; ++g_rahit; return int(std::max(0L, e.second - g_cyc)); }
  if (S.last != ~0u && dw >= S.last && dw <= S.last + 1) return 0;
  const long issue = std::max(g_cyc, g_port_free);
  g_port_free = issue + occ; ++g_porttrips;
  const uint32_t b = g_ra_align ? (dw & ~1u) : dw;
  S.q.clear(); S.q.push_back({b, issue + lat}); S.next = b + 2; S.last = b; S.act = true;
  return int(issue + lat - g_cyc);
}
static void ra_tick(int ra, int lat, int occ) {
  if (g_cyc < g_port_free) return;
  for (int k = 0; k < 4; k++) {
    RaStream &S = g_ra[(g_ra_rr + k) & 3];
    if (S.act && int(S.q.size()) < ra) {
      S.q.push_back({S.next, g_cyc + lat}); S.next += 2;
      g_port_free = g_cyc + occ; ++g_porttrips; ++g_pf; g_ra_rr = (g_ra_rr + k + 1) & 3;
      return;
    }
  }
}

static bool wr_pend = false; static uint32_t wr_a; static uint16_t wr_d;
static long nq = 0; static FILE *fo = nullptr;

static void tick() {
#ifdef GD_RA
  // R709: the RTL read-ahead's port, answered as m2_sdram_x2 does: a request
  // taken on its rising edge, the pair {idx, idx+1} (wrapping inside its
  // 512-dword row) M2GD_LAT cycles later, the acknowledge held while the
  // request stands. M2GD_RABYPASS=1 keeps no copy: every read a port trip.
  {
    static const int PLAT = std::getenv("M2GD_LAT") ? std::atoi(std::getenv("M2GD_LAT")) : 10;
    static int preq_d = 0, pcnt = -1, pdone = 0; static uint32_t pidx = 0;
    d->ra_bypass = std::getenv("M2GD_RABYPASS") ? 1 : 0;
    if (d->p_req && !preq_d && pcnt < 0 && !pdone) { pcnt = PLAT; pidx = d->p_idx; ++g_porttrips; }
    preq_d = d->p_req;
    if (pcnt > 0 && --pcnt == 0) {
      const uint32_t row = pidx & ~511u, hi = row | ((pidx + 1) & 511u);
      const uint32_t w0 = (2 * pidx) & ((1u << 25) - 1), w1 = (2 * hi) & ((1u << 25) - 1);
      d->p_dout = (uint64_t(mem[w1 + 1]) << 48) | (uint64_t(mem[w1]) << 32) | (uint64_t(mem[w0 + 1]) << 16) | mem[w0];
      pdone = 1; pcnt = -1;
    }
    if (!d->p_req) pdone = 0;
    d->p_ack = pdone;
    static int mreq_d = 0;
    if (d->mem_req && !mreq_d) ++g_memreqs;   // engine reads, on the request's rising edge
    mreq_d = d->mem_req;
  }
#endif
  d->rd_ack = 0;
  if (d->rd_req) { d->rd_data = (d->rd_addr < buf.size()) ? buf[d->rd_addr] : 0xFFFFFFFFu; d->rd_ack = 1; }
  // R696: M2GD_LAT -- the engine's memory answers N cycles after the request
  // (0, the default, is the same-cycle answer this bench always gave). The
  // board's engine port goes through the pair cache to a one-word SDRAM port.
  static const int LAT = std::getenv("M2GD_LAT") ? std::atoi(std::getenv("M2GD_LAT")) : 0;
  static int lat_left = -1;
  // R696: M2GD_PC models the cache in front of the engine port (Model2.sv's
  // m2_pair_cache) so only real port trips pay LAT: 0 none, 1 today's (the
  // next dword, used once), 2 the whole last answer {N, N+1} kept until replaced.
  static const int PC = std::getenv("M2GD_PC") ? std::atoi(std::getenv("M2GD_PC")) : 0;
  static bool pc_v = false; static uint32_t pc_n = 0;
  static const int RA  = std::getenv("M2GD_RA")  ? std::atoi(std::getenv("M2GD_RA"))  : 4;
  static const int OCC = std::getenv("M2GD_OCC") ? std::atoi(std::getenv("M2GD_OCC")) : std::max(LAT, 1);
  static const int RAMASK  = std::getenv("M2GD_RAMASK")  ? std::atoi(std::getenv("M2GD_RAMASK")) : 15;
  static const int RAFLUSH = std::getenv("M2GD_RAFLUSH") ? std::atoi(std::getenv("M2GD_RAFLUSH")) : 0;
  g_ra_align = std::getenv("M2GD_RAALIGN") ? std::atoi(std::getenv("M2GD_RAALIGN")) : 0;
  static bool busy_d = false;
  const bool busy = d->rootp->geodiff_top__DOT__eng_busy;
  if (RAFLUSH && busy && !busy_d) for (auto &S : g_ra) { S.act = false; S.q.clear(); S.last = ~0u; }
  busy_d = busy;
  ++g_cyc;
  if (PC >= 3) ra_tick(RA, LAT, OCC);
  d->mem_ack = 0;
#ifdef GD_RA
  if (false) {
#else
  if (d->mem_req) {
#endif
    if (lat_left < 0) {
      // the SDRAM dword this read lands on, as the port sees it
      const uint32_t dw = eng_wordaddr(d->mem_space, d->mem_addr, d->obj_oba_r) >> 1;
      bool hit = false;
      if (PC == 1) { hit = pc_v && dw == pc_n; pc_v = !hit && ((dw & 511) != 511); pc_n = dw + 1; }
      else if (PC == 2) { hit = pc_v && (dw == pc_n || dw == pc_n + 1); if (!hit) { pc_v = ((dw & 511) != 511) || true; pc_n = dw; } }
      // M2GD_RANOTR=1: texture headers in texture RAM (addr[23]) -- the half the CPU writes -- get no stream
      static const int RANOTR = std::getenv("M2GD_RANOTR") ? std::atoi(std::getenv("M2GD_RANOTR")) : 0;
      if (PC >= 3 && (!((RAMASK >> (d->mem_space & 3)) & 1) || (RANOTR && d->mem_space == 1 && (d->mem_addr & 0x800000))))
        lat_left = ra_trip(dw, LAT, OCC);
      else if (PC >= 3) lat_left = ra_read(g_ra[PC == 3 ? (d->mem_space & 3) : 0], dw, LAT, OCC);
      else { if (!hit) ++g_porttrips; lat_left = hit ? 0 : LAT; }
      ++g_memreqs;
      // R696: which memory, which engine state, and whether this exact word was read before in this list
      const int est = d->rootp->geodiff_top__DOT__u_geometry__DOT__u_engine__DOT__st;
      g_rd_by[(d->mem_space << 8) | est]++;
      const uint64_t key = (uint64_t(d->mem_space) << 40) | (uint64_t(d->obj_oba_r & 0x1800000) << 8) | d->mem_addr;
      if (!g_seen.insert(key).second) ++g_repeat;
    }
    if (lat_left == 0) {
      d->mem_ack = 1; d->mem_data = eng_read(d->mem_space, d->mem_addr, d->obj_oba_r); lat_left = -1;
    } else --lat_left;
  } else lat_left = -1;
  d->sd_wr_ack = 0;
  if (wr_pend) {
    mem[wr_a] = wr_d; d->sd_wr_ack = 1; wr_pend = false;
    // R709: the geometrizer's write landing drops every stream (the RTL's inval)
    if (std::getenv("M2GD_RAFLUSH")) { ++g_wrflush; for (auto &S : g_ra) { S.act = false; S.q.clear(); S.last = ~0u; } }
  }
  else if (d->sd_wr_req) { wr_a = d->sd_wr_addr & ((1u << 25) - 1); wr_d = d->sd_wr_din; wr_pend = true; }
  d->clk = 0; d->eval(); d->clk = 1; d->eval();
  if (d->q_valid && d->q_ready) {
    std::fprintf(fo, "Q %ld %d,%d %d,%d %d,%d %d,%d frac=%04x uv=%u,%u %u,%u %u,%u %u,%u tex=%06x col=%06x z=%08x lum=%u oz=%04x,%04x,%04x,%04x\n",
      nq++, (int16_t)d->q_x0, (int16_t)d->q_y0, (int16_t)d->q_x1, (int16_t)d->q_y1,
      (int16_t)d->q_x2, (int16_t)d->q_y2, (int16_t)d->q_x3, (int16_t)d->q_y3, (unsigned)d->q_frac,
      (unsigned)d->q_u0, (unsigned)d->q_v0, (unsigned)d->q_u1, (unsigned)d->q_v1,
      (unsigned)d->q_u2, (unsigned)d->q_v2, (unsigned)d->q_u3, (unsigned)d->q_v3,
      (unsigned)d->q_tex, (unsigned)d->q_col, (unsigned)d->q_z, (unsigned)d->q_lum,
      (unsigned)d->q_oz0, (unsigned)d->q_oz1, (unsigned)d->q_oz2, (unsigned)d->q_oz3);
  }
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const char *dp = std::getenv("M2GD_DIR");
  if (!dp) { std::printf("set M2GD_DIR\n"); return 1; }
  const std::string dir(dp);
  std::vector<uint8_t> v;
  if (!load(dir + "/bufferram.bin", v)) return 1;
  buf.resize(v.size() / 4); std::memcpy(buf.data(), v.data(), buf.size() * 4);
  if (load(dir + "/pram0.bin", v)) put_dwords(GAME_PRAM0, v, 0x8000);
  if (load(dir + "/pram1.bin", v)) put_dwords(GAME_PRAM1, v, 0x8000);
  if (load(dir + "/polyrom.bin", v)) put_dwords(GAME_POLY, v, 0x400000);
  // R671: packed as the MRA packs it -- MAME's 16 MB region holds its two ROM
  // pairs at words 0 and 0x400000; the board's 8 MB holds them back to back
  if (load(dir + "/texrom.bin", v)) {
    put_words(GAME_TEX, v, 0, 0x200000);                     // pair one: words 0..0x1FFFFF
    put_words(GAME_TEX + 0x200000, v, 0x400000, 0x200000);   // pair two: MAME's word 0x400000 -> packed 0x200000
  }
  if (load(dir + "/texram.bin", v)) put_words(GAME_TEXRAM, v, 0, 0x10000);
  if (load(dir + "/palram.bin", v)) put_words(GAME_PAL3D, v, 0x1000, 0x400);
  if (load(dir + "/colorxlat.bin", v)) put_words(GAME_XLAT3D, v, 0, 0x6000);
  unsigned start = 0;
  { FILE *f = std::fopen((dir + "/state.txt").c_str(), "r"); char line[512];
    while (f && std::fgets(line, sizeof line, f)) std::sscanf(line, "walk %*d start %x", &start);
    if (f) std::fclose(f); }
  fo = std::fopen((dir + "/ours.txt").c_str(), "w");

  d = new Vgeodiff_top;
  d->rst_n = 0; d->wr_setrp = 0; d->wdata = 0; d->frame_start = 0; d->q_ready = 1;
  d->rd_ack = 0; d->mem_ack = 0; d->sd_wr_ack = 0;
  for (int i = 0; i < 8; i++) tick();
  d->rst_n = 1; for (int i = 0; i < 8; i++) tick();

  // The game's flip: the read pointer is a BYTE address.
  d->wdata = start * 4; d->wr_setrp = 1; tick(); d->wr_setrp = 0;   // one pulse: a held write re-arms the flip
  long quiet = 0, t = 0;
  // R671: M2GD_HDR=1 -- every texture header the engine reads: the address it
  // read from (th_w, RAM or ROM), words 0 and 2, and the attr whose tho steps it
  FILE *fh = std::getenv("M2GD_HDR") ? std::fopen((dir + "/hdr.txt").c_str(), "w") : nullptr;
  uint32_t thw_prev = 0xffffffffu;
  for (t = 0; t < 400000000L; t++) {
    const long before = nq;
    tick();
    if (fh) {
      auto *r = d->rootp;
      const uint32_t thw = r->geodiff_top__DOT__u_geometry__DOT__u_engine__DOT__th_w;
      if (thw != thw_prev) {
        std::fprintf(fh, "H thw=%06x ram=%d h0=%04x h1=%04x h2=%04x attr=%08x\n", thw_prev,
                     (int)r->geodiff_top__DOT__u_geometry__DOT__u_engine__DOT__th_ram,
                     (unsigned)r->geodiff_top__DOT__u_geometry__DOT__u_engine__DOT__hdr0,
                     (unsigned)r->geodiff_top__DOT__u_geometry__DOT__u_engine__DOT__hdr1,
                     (unsigned)r->geodiff_top__DOT__u_geometry__DOT__u_engine__DOT__hdr2,
                     (unsigned)r->geodiff_top__DOT__u_geometry__DOT__u_engine__DOT__attr);
        thw_prev = thw;
      }
      static uint32_t tpw_prev = 0xffffffffu;   // R671: the u/v pointer too
      const uint32_t tpw = r->geodiff_top__DOT__u_geometry__DOT__u_engine__DOT__tp_w;
      if (tpw != tpw_prev) {
        std::fprintf(fh, "T tpw=%06x ram=%d\n", tpw, (int)r->geodiff_top__DOT__u_geometry__DOT__u_engine__DOT__tp_ram);
        tpw_prev = tpw;
      }
    }
    if (d->walk_frames >= 1) { quiet = (nq == before) ? quiet + 1 : 0; if (quiet > 200000) break; }
  }
  std::fclose(fo); if (fh) std::fclose(fh);
  std::printf("geodiff %s: start %05x, %ld cycles, %ld engine memory reads\n", dp, start, t, g_memreqs);
  if (std::getenv("M2GD_RDS")) {
    static const char *SP[4] = {"polygon", "texture", "palette", "xlat"};
    std::printf("  port trips %ld (M2GD_PC=%s)\n", g_porttrips, std::getenv("M2GD_PC") ? std::getenv("M2GD_PC") : "0");
    if (g_pf) std::printf("  read-ahead: %ld fetched ahead, %ld reads served from them, %ld write flushes\n", g_pf, g_rahit, g_wrflush);
    std::printf("  engine reads %ld, of which repeats of a word already read this list %ld (%.1f%%)\n", g_memreqs, g_repeat, 100.0 * g_repeat / std::max(g_memreqs, 1L));
    std::vector<std::pair<long,int>> v; for (auto &k : g_rd_by) v.push_back({k.second, k.first});
    std::sort(v.rbegin(), v.rend());
    for (size_t i = 0; i < v.size() && i < 16; i++)
      std::printf("    %-8s engine state %2d: %7ld (%.1f%%)\n", SP[(v[i].second >> 8) & 3], v[i].second & 0xff, v[i].first, 100.0 * v[i].first / g_memreqs);
  }
  std::printf("  walk: ops %u objects %u frames %u unknown %u | captured mtx %u foc %u lit %u tp %u\n",
    d->walk_ops, d->walk_objs, d->walk_frames, d->walk_unknown, d->mtx_n, d->foc_n, d->lit_n, d->tp_n);
  std::printf("  geometry: polys %u objects %u culled %u clip in %u out %u dropped %u nonfinite %u behind %u | quads %ld\n",
    d->polys, d->objects, d->culled, d->clip_in, d->clip_out, d->clip_dropped, d->n_nonfinite, d->behind, nq);
  delete d;
  return 0;
}
