// R1030: the 2C tilemap path, old against new (m2_vid2c_miter.sv). Two clocks
// as the core has them -- clk_mem 100 MHz, clk_sys 80 MHz -- the CPU writing
// tile RAM, palette and the translation table on clk_sys, port 3 answering
// each side's glyph cache after a latency drawn per transaction (the same for
// both), the invalidate pulsed (half of them on the line just fetched, so the
// kill paths run), the R826 scroll inputs moving, and every output of the two
// sides compared on every clk_mem edge, the palette's CPU read on every
// clk_sys edge.
//
//   VM_N=<clk_mem cycles> VM_SEED=<n> VM_IN=<dir with tile.bin char.bin
//   palette.bin, or unset for random memories> VM_CE=0|1|2 (0 the core's
//   6,6,6,7 pixel enable; 1 random 6-7; 2 random 1-70) VM_LAT=<max port-3
//   latency> VM_HOLD=1|2 (the acknowledge's length) VM_IL=0|1 (interlace)
//   VM_WR=<CPU write every n clk_sys, 0 none> VM_INV=<invalidate every n, 0 none>
#include "Vm2_vid2c_miter.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

static uint64_t s = 1;
static inline uint32_t rnd() { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return (uint32_t)(s >> 11); }
static uint64_t envu(const char *n, uint64_t d) { const char *v = getenv(n); return v ? strtoull(v, 0, 0) : d; }

static bool load_u16(const std::string &p, std::vector<uint16_t> &v) {
  FILE *f = fopen(p.c_str(), "rb");
  if (!f) return false;
  size_t n = fread(v.data(), 2, v.size(), f);
  fclose(f);
  return n > 0;
}

// Unwritten memory reads 0xFFFF.
static std::vector<uint16_t> tram(32768, 0xFFFF), pal(8192, 0xFFFF), chr(262144, 0xFFFF);

// One side's port 3: a request is taken when m_req is high and nothing is in
// flight; after its latency the data is delivered with an acknowledge HOLD
// cycles long, and the data stays until the next delivery (m2_sdram's p_dout).
struct Port {
  int busy = 0, wait = 0, ackc = 0; uint32_t addr = 0; uint64_t txn = 0; uint64_t data = 0;
};
static uint32_t lat_of(uint64_t txn, uint64_t seed, int maxlat) {
  uint64_t h = (txn + 1) * 0x9E3779B97F4A7C15ull ^ seed * 0xBF58476D1CE4E5B9ull;
  h ^= h >> 31; h *= 0x94D049BB133111EBull; h ^= h >> 29;
  return 1 + (uint32_t)(h % (uint64_t)maxlat);
}
static void port_edge(Port &p, int req, uint32_t addr, int hold, uint64_t seed, int maxlat,
                      unsigned char &ack, uint64_t &data) {
  // State after the edge, from what the cache showed before it.
  if (p.ackc > 0) { p.ackc--; }
  else if (p.busy) {
    if (--p.wait == 0) {
      uint32_t a = p.addr & 0x3FFFC;
      p.data = (uint64_t)chr[a] | ((uint64_t)chr[a + 1] << 16) |
               ((uint64_t)chr[a + 2] << 32) | ((uint64_t)chr[a + 3] << 48);
      p.ackc = hold; p.busy = 0;
    }
  } else if (req) {
    p.busy = 1; p.addr = addr; p.wait = lat_of(p.txn++, seed, maxlat);
  }
  ack = p.ackc > 0;
  if (p.ackc > 0 && p.ackc == hold) { /* first cycle of the acknowledge */ }
  data = p.data;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const uint64_t N = envu("VM_N", 2000000);
  const uint64_t seed = envu("VM_SEED", 1); s = seed ? seed : 1;
  const int cem = (int)envu("VM_CE", 0), maxlat = (int)envu("VM_LAT", 40), hold = (int)envu("VM_HOLD", 2);
  const int il = (int)envu("VM_IL", 0), wr_every = (int)envu("VM_WR", 0), inv_every = (int)envu("VM_INV", 3000);
  const char *in = getenv("VM_IN");
  bool dump = false;
  if (in) {
    dump = load_u16(std::string(in) + "/tile.bin", tram) & load_u16(std::string(in) + "/char.bin", chr) &
           load_u16(std::string(in) + "/palette.bin", pal);
    if (!dump) { printf("VM_IN=%s: tile.bin, char.bin and palette.bin wanted\n", in); return 2; }
  } else {
    for (auto &w : tram) w = rnd(); for (auto &w : pal) w = rnd(); for (auto &w : chr) w = rnd();
  }

  Vm2_vid2c_miter *t = new Vm2_vid2c_miter;
  t->clk_mem = 0; t->clk_sys = 0; t->rst_n = 0; t->cc_rst_n = 0; t->ce_pix = 0;
  t->interlace = il; t->gamma_sel = 0;
  t->eval();

  Port po, pn;
  uint64_t mem_cyc = 0, sys_cyc = 0, bad = 0, badc = 0, bad_cpu = 0, bad_port = 0;
  uint64_t creq = 0, inv_n = 0, inv_hit = 0, nz_px = 0, frames = 0, pal_wr = 0, tram_wr = 0;
  int ce_cnt = 0, ce_gap = 6, ce_ph = 0, inv_left = 0;
  uint32_t load = 0;                 // CPU load position: tram then palette
  const uint32_t LOAD_END = 32768 + 8192;
  uint32_t last_line = 0; int prev_creq = 0, prev_mreq = 0; uint64_t mreq = 0;
  // Time in units of 1.25 ns: clk_mem toggles every 4, clk_sys every 5.
  for (uint64_t u = 0; mem_cyc < N; u++) {
    bool mem_e = (u % 4) == 0, sys_e = (u % 5) == 0;
    if (!mem_e && !sys_e) continue;
    bool mem_rise = mem_e && !t->clk_mem, sys_rise = sys_e && !t->clk_sys;
    if (mem_e) t->clk_mem = !t->clk_mem;
    if (sys_e) t->clk_sys = !t->clk_sys;
    // what the caches show before this edge
    int oreq = t->o_m_req, nreq = t->n_m_req; uint32_t oad = t->o_m_addr, nad = t->n_m_addr;
    t->eval();
    if (mem_rise) {
      mem_cyc++;
      // ---- compare
      bool d = false;
      for (int w = 0; w < 5; w++) if (t->o_obs[w] != t->n_obs[w]) d = true;
      if (d) { if (bad < 10) printf("outputs differ at clk_mem %llu\n", (unsigned long long)mem_cyc); bad++; }
      if (!t->n_copies_ok) { if (badc < 10) printf("palette address copies differ at %llu\n", (unsigned long long)mem_cyc); badc++; }
      if (t->o_m_req != t->n_m_req || t->o_m_addr != t->n_m_addr) {
        if (bad_port < 10) printf("port 3 requests differ at %llu\n", (unsigned long long)mem_cyc); bad_port++;
      }
      // ---- statistics (from the old side). obs: {r,g,b} 129:106, vblank_irq
      // 100, char_req 55 (words of 32 bits, least significant first).
      if ((t->o_obs[4] & 3) || (t->o_obs[3] >> 10)) nz_px++;
      if ((t->o_obs[3] >> 4) & 1) frames++;
      int cr = (t->o_obs[1] >> 23) & 1;
      if (cr && !prev_creq) creq++;
      prev_creq = cr;
      if (oreq && !prev_mreq) mreq++;
      prev_mreq = oreq;
      // ---- inputs for the next cycle (register-like, after the edge)
      if (mem_cyc == 20) { t->rst_n = 1; t->cc_rst_n = 1; }
      // pixel enable
      int ce = 0;
      if (++ce_cnt >= ce_gap) {
        ce = 1; ce_cnt = 0;
        if (cem == 0) { ce_gap = (ce_ph++ & 3) == 3 ? 7 : 6; }
        else if (cem == 1) ce_gap = 6 + (rnd() & 1);
        else ce_gap = 1 + rnd() % 70;
      }
      t->ce_pix = ce;
      // the R826 inputs, slowly
      if ((rnd() % 50000) == 0) t->scr_flip = !t->scr_flip;
      if ((rnd() % 70000) == 0) t->scr_tag = rnd() & 15;
      if ((rnd() % 60000) == 0) t->scr_vtgl = !t->scr_vtgl;
      if ((rnd() % 80000) == 0) t->scr_ttag = rnd() & 15;
      if ((rnd() % 400000) == 0) t->gamma_sel = rnd() & 3;
      // invalidates
      if (inv_left > 0) { if (--inv_left == 0) t->inval = 0; }
      else if (inv_every && (rnd() % inv_every) == 0) {
        inv_n++;
        uint32_t idx;
        if (rnd() & 1) { idx = (last_line >> 2) & 0x1FFF; inv_hit++; } else idx = rnd() & 0x1FFF;
        t->inval_idx = idx; t->inval = 1; inv_left = 1 + rnd() % 16;
        // the write that caused it: some word of that line, in every tag
        uint32_t a = ((rnd() & 0xF) << 15) | (idx << 2) | (rnd() & 3);
        chr[a & 0x3FFFF] = rnd();
      }
      // port 3
      unsigned char ack; uint64_t dat;
      port_edge(po, oreq, oad, hold, seed, maxlat, ack, dat); t->o_m_ack = ack; t->o_m_data = dat;
      port_edge(pn, nreq, nad, hold, seed, maxlat, ack, dat); t->n_m_ack = ack; t->n_m_data = dat;
      if (oreq) last_line = oad;
    }
    if (sys_rise) {
      sys_cyc++;
      if (t->o_pal_cpu != t->n_pal_cpu) { if (bad_cpu < 10) printf("palette CPU reads differ at clk_sys %llu\n", (unsigned long long)sys_cyc); bad_cpu++; }
      t->oc_tram_we = 0; t->oc_pal_we = 0; t->xlat_we = 0;
      if (load < LOAD_END) {
        if (load < 32768) { t->oc_addr = load; t->oc_din = tram[load]; t->oc_tram_we = 1; }
        else { t->oc_addr = load - 32768; t->oc_din = pal[load - 32768]; t->oc_pal_we = 1; }
        load++;
      } else {
        uint32_t x = rnd();
        if (wr_every && (x % wr_every) == 0) {
          uint32_t y = rnd();
          switch (y & 3) {
            case 0: t->oc_addr = y >> 17; t->oc_din = rnd(); t->oc_tram_we = 1; tram_wr++; break;
            case 1: t->oc_addr = (y >> 19) & 0x1FFF; t->oc_din = rnd(); t->oc_pal_we = 1; pal_wr++; break;
            case 2: t->xlat_addr = (y >> 8) & 127; t->xlat_din = y >> 24; t->xlat_we = 1; break;
            default: t->oc_addr = y >> 17; break;          // a CPU read
          }
        } else if ((x & 7) == 0) t->oc_addr = rnd() & 0x7FFF;   // reads, for a_q
      }
    }
    t->eval();
  }
  t->final();
  printf("VM seed %llu ce %d lat %d hold %d il %d wr %d inv %d %s: %llu clk_mem, %llu clk_sys; "
         "%llu frames, %llu non-black pixel-cycles, %llu glyph requests, %llu port-3 misses, %llu invalidates (%llu on the last line), %llu tile / %llu palette CPU writes\n",
         (unsigned long long)seed, cem, maxlat, hold, il, wr_every, inv_every, dump ? in : "random",
         (unsigned long long)mem_cyc, (unsigned long long)sys_cyc, (unsigned long long)frames,
         (unsigned long long)nz_px, (unsigned long long)creq, (unsigned long long)mreq,
         (unsigned long long)inv_n, (unsigned long long)inv_hit, (unsigned long long)tram_wr, (unsigned long long)pal_wr);
  printf("VM differences: outputs %llu, port 3 %llu, palette copies %llu, palette CPU reads %llu -> %s\n",
         (unsigned long long)bad, (unsigned long long)bad_port, (unsigned long long)badc,
         (unsigned long long)bad_cpu, (bad || bad_port || badc || bad_cpu) ? "FAIL" : "PASS");
  delete t;
  return (bad || bad_port || badc || bad_cpu) ? 1 : 0;
}
