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

static bool wr_pend = false; static uint32_t wr_a; static uint16_t wr_d;
static long nq = 0; static FILE *fo = nullptr;

static void tick() {
  d->rd_ack = 0;
  if (d->rd_req) { d->rd_data = (d->rd_addr < buf.size()) ? buf[d->rd_addr] : 0xFFFFFFFFu; d->rd_ack = 1; }
  d->mem_ack = d->mem_req;
  if (d->mem_req) d->mem_data = eng_read(d->mem_space, d->mem_addr, d->obj_oba_r);
  d->sd_wr_ack = 0;
  if (wr_pend) { mem[wr_a] = wr_d; d->sd_wr_ack = 1; wr_pend = false; }
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
  std::printf("geodiff %s: start %05x, %ld cycles\n", dp, start, t);
  std::printf("  walk: ops %u objects %u frames %u unknown %u | captured mtx %u foc %u lit %u tp %u\n",
    d->walk_ops, d->walk_objs, d->walk_frames, d->walk_unknown, d->mtx_n, d->foc_n, d->lit_n, d->tp_n);
  std::printf("  geometry: polys %u objects %u culled %u clip in %u out %u dropped %u nonfinite %u behind %u | quads %ld\n",
    d->polys, d->objects, d->culled, d->clip_in, d->clip_out, d->clip_dropped, d->n_nonfinite, d->behind, nq);
  delete d;
  return 0;
}
