// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The boot, through the REAL bridge and the REAL peripherals.
//
// tb_i960_rom drives i960_top directly with a C++ memory. Every instruction
// verified against MAME went through that path, and none went through
// m2_cpu_bridge. So the boot runs clean there and stops on the board, and this
// covers the link between them.
//
// THE FAILURE IT IS BUILT TO REPRODUCE. On hardware the i960 reads the I/O
// board's flag and status correctly — row 17 returns 4000, row 18 the address
// 01C00042, row 19 the word 00400000 — passes all three polls at
// 0x22824x-0x228270, and never reaches the copy loop at 0x22827C. Rows 15 and
// 16 read zero: no window reads, no backup-SRAM writes.
//
// So the check is not "did it finish" but "did it get to the copy":
//
//   window reads > 0   the copy ran. The board is not the blocker and this
//                      harness does not reproduce the hardware fault.
//   window reads == 0  reproduced, in a place where it can be stepped.
//
// The SDRAM behind the bridge is modelled in C++. m2_sdram has 123,927 checks
// of its own and is not the question. It bursts FOUR words into the 64-bit
// p_dout — study R33, which is also why every port bursts four — so a 32-bit
// access is one transaction, not two. A model that returned one word made the
// boot trap after a single instruction with every upper half reading zero.

#include "Vm2_boot_harness.h"
#include "verilated.h"
#include <cstdio>
#include <cmath>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <string>
#include <map>
#include <algorithm>

static Vm2_boot_harness *d;

// 25-bit word address space, 64 MB. Unwritten reads 0xFFFF, per the standing
// rule in docs/mister-integration.md — never zero.
static std::vector<uint16_t> mem;
// R222 PROBE: where the texture headers live and what they say. On every new
// object the walker starts, read its header from the texture ROM image (word
// 0x0720000 = byte 0x0e40000 in the MRA stream; tha is a 16-bit-word index
// masked to 4M words) and count: RAM-resident headers (bit 23, which this
// bench cannot read), the renderer bits (texheader[0] >> 13), and the
// distinct colorbase values (texheader[3] >> 6 & 0x3ff).
#include <map>
#include <set>
static uint32_t g_th_objs = 0, g_th_ram = 0, g_th_rend[4] = {0,0,0,0}, g_th_checker = 0;
static std::set<uint32_t> g_th_colorbase;
static std::map<uint32_t,uint32_t> g_th_colorbase_n;
static uint32_t g_th_last_objs = 0;
static uint32_t g_tdwords = 0;
static unsigned g_pj_lost = 0;
// R231: where the luminance lands, and the table it comes from.
static unsigned g_luma_hist[16] = {0};
static unsigned g_luma_n = 0, g_luma_zero = 0;
static unsigned g_tp_dif[32], g_tp_amb[32]; static bool g_tp_seen[32];
// R245: which light-parameter entry each polygon asked for, how many read an
// all-zero entry (which renders black), and how often the walker wrote each.
static long g_lp_used[32] = {0}, g_lp_zero = 0, g_tp_w[32] = {0};
static long g_fr_poly = 0, g_fr_lsum = 0, g_fr_zero = 0; static uint32_t g_fr_lp = 0;   // R248, per frame
static FILE *g_fr_log = nullptr;
// R232: coprocessor data-ROM reads by dword address range. The loaded ROM is
// 4 MB = 0x100000 dwords; the reference's region is 8 MB and reads above the
// loaded part return zero; this core's address is 20 bits and would alias.
static unsigned long g_rom_rd = 0, g_rom_rd_hi = 0, g_rom_rd_max = 0; static bool g_rom_rd_d = false;
// R234: every distinct light vector the walker held, with its length.
#include <cmath>
static std::map<uint64_t, unsigned> g_lights; static uint32_t g_lit_last[3] = {0,0,0};
// the rotated normal's length per emitted polygon, binned
static unsigned g_nlen_hist[8] = {0}; static unsigned g_nlen_n = 0; static double g_nlen_sum = 0;
static uint32_t g_op_hist[32] = {0};   // display-list opcodes decoded from M2_POLY_FROM
static void th_probe(uint32_t tha) {
  ++g_th_objs;
  if (g_th_objs <= 6 || (g_th_objs % 400) == 0) std::printf("    TEXHDR sample: object %u tha %08x\n", g_th_objs, tha);
  if (tha & 0x800000u) { ++g_th_ram; return; }
  const uint32_t a = 0x0720000u + (tha & 0x3fffffu);
  if (a + 3 >= mem.size()) return;
  const uint16_t h0 = mem[a], h3 = mem[a + 3];
  if (g_th_objs <= 6 || (g_th_objs % 400) == 0) std::printf("      header %04x %04x %04x %04x\n", mem[a], mem[a+1], mem[a+2], mem[a+3]);
  ++g_th_rend[(h0 >> 13) & 3];
  if (h0 & 0x8000) ++g_th_checker;
  const uint32_t cb = (h3 >> 6) & 0x3ff;
  g_th_colorbase.insert(cb); ++g_th_colorbase_n[cb];
}
static void th_report() {
  {
    std::printf("    LUMINANCE over %u polygons, zero on %u (%.1f%%); histogram by 16s:",
                g_luma_n, g_luma_zero, g_luma_n ? 100.0 * g_luma_zero / g_luma_n : 0.0);
    for (int i = 0; i < 16; i++) std::printf(" %u", g_luma_hist[i]);
    std::printf("\n    ROTATED NORMAL LENGTH over %u polygons: mean %.3f; bins <0.5 %u, 0.5-0.9 %u, 0.9-1.1 %u, 1.1-2 %u, 2-10 %u, 10-100 %u, 100-1000 %u, >1000 %u",
                g_nlen_n, g_nlen_n ? g_nlen_sum / g_nlen_n : 0.0, g_nlen_hist[0], g_nlen_hist[1], g_nlen_hist[2], g_nlen_hist[3], g_nlen_hist[4], g_nlen_hist[5], g_nlen_hist[6], g_nlen_hist[7]);
    std::printf("\n    TEXTURE PARAMETERS the walker captured (index: diffuse/ambient):");
    for (int i = 0; i < 32; i++) if (g_tp_seen[i]) std::printf(" %d:%u/%u", i, g_tp_dif[i], g_tp_amb[i]);
    std::printf("\n");
  }
  {
    // R231: THE COLOUR TABLES AS THE GAME WROTE THEM, read back out of the
    // bridge's SDRAM mirrors. The 3D palette (entries 0x1000+) at word
    // 0x1730000, colorxlat at 0x1731000 as three 0x2000-word channels, each
    // 32 blocks of 256 by component value, of which the flat path reads
    // words 0..63 (luma >> 2). Unwritten SDRAM is 0xFFFF.
    auto gam = [](unsigned v){ double r = ((double)v - 64.0) * 255.0 / 191.0; return r < 0 ? 0u : (unsigned)r; };
    unsigned written[3] = {0,0,0}, total = 32 * 64;
    for (int c = 0; c < 3; c++) for (int c5 = 0; c5 < 32; c5++) for (int l = 0; l < 64; l++)
      if (mem[0x1731000u + c * 0x2000u + c5 * 0x100u + l] != 0xffff) ++written[c];
    std::printf("    COLORXLAT mirror: of the 2,048 words per channel the flat path can read, written R %u G %u B %u\n", written[0], written[1], written[2]);
    std::printf("      red channel, component 16, luma index 0..63:");
    for (int l = 0; l < 64; l++) std::printf(" %02x", mem[0x1731000u + 16 * 0x100u + l] & 0xff);
    std::printf("\n      red channel, component 31, luma index 0..63:");
    for (int l = 0; l < 64; l++) std::printf(" %02x", mem[0x1731000u + 31 * 0x100u + l] & 0xff);
    std::printf("\n      and the tile row (word 64) for components 0..31:");
    for (int c5 = 0; c5 < 32; c5++) std::printf(" %02x", mem[0x1731000u + c5 * 0x100u + 64] & 0xff);
    unsigned pw = 0; for (int i = 0; i < 1024; i++) if (mem[0x1730000u + i] != 0xffff) ++pw;
    std::printf("\n    3D PALETTE mirror: %u of 1024 entries written\n", pw);
    for (unsigned cb : {0x155u, 0x02cu, 0x130u, 0x127u, 0x000u, 0x001u, 0x3ffu}) {
      unsigned e = mem[0x1730000u + cb] & 0x7fff;
      unsigned r5 = e & 31, g5 = (e >> 5) & 31, b5 = (e >> 10) & 31;
      unsigned xr = mem[0x1731000u + 0x0000u + r5 * 0x100u + 63] & 0xff;
      unsigned xg = mem[0x1731000u + 0x2000u + g5 * 0x100u + 63] & 0xff;
      unsigned xb = mem[0x1731000u + 0x4000u + b5 * 0x100u + 63] & 0xff;
      std::printf("      colorbase %03x: entry %04x (r%2u g%2u b%2u) -> xlat@63 %02x %02x %02x -> gamma %02x%02x%02x\n",
                  cb, e, r5, g5, b5, xr, xg, xb, gam(xr), gam(xg), gam(xb));
    }
  }
  {
    auto u2f = [](uint32_t u){ float f; std::memcpy(&f, &u, 4); return f; };
    {
      long tot = 0; for (int i = 0; i < 32; i++) tot += g_lp_used[i];
      std::printf("    LIGHT PARAMETERS (R245): polygons %ld, of which %ld read an entry of {diffuse 0, ambient 0} -- black\n", tot, g_lp_zero);
      std::printf("      walker wrote / polygons asked, per entry:");
      for (int i = 0; i < 32; i++) if (g_tp_w[i] || g_lp_used[i]) std::printf(" %d:%ld/%ld", i, g_tp_w[i], g_lp_used[i]);
      std::printf("\n");
    }
    std::printf("    LIGHT VECTORS the walker captured: %zu distinct; last (%g, %g, %g) length %g\n", g_lights.size(),
                u2f(g_lit_last[0]), u2f(g_lit_last[1]), u2f(g_lit_last[2]),
                std::sqrt((double)u2f(g_lit_last[0])*u2f(g_lit_last[0]) + (double)u2f(g_lit_last[1])*u2f(g_lit_last[1]) + (double)u2f(g_lit_last[2])*u2f(g_lit_last[2])));
  }
  std::printf("    COPRO DATA-ROM READS: %lu, of which %lu at or above dword 0x100000 (past the 4 MB loaded; the reference reads ZERO there, this core ALIASES); highest dword 0x%06lx\n", g_rom_rd, g_rom_rd_hi, g_rom_rd_max);
  std::printf("    PROJECTIONS ABANDONED ON TIMEOUT: %u  (R226: an abandoned vertex keeps the screen position it already had)\n", g_pj_lost);
  std::printf("    TEXHDR texture RAM words written by the walker (op 0x04, bit 23): %u\n", (unsigned)g_tdwords);
  std::printf("    WALKER OPCODES from M2_POLY_FROM:");
  for (int i = 0; i < 32; i++) if (g_op_hist[i]) std::printf(" %02x:%u", i, g_op_hist[i]);
  std::printf("\n");
  std::printf("    TEXHDR objects %u: RAM-resident %u, renderer flat %u translucent %u textured %u tex+trans %u, checker %u, distinct colorbase %zu\n",
              g_th_objs, g_th_ram, g_th_rend[0], g_th_rend[1], g_th_rend[2], g_th_rend[3], g_th_checker, g_th_colorbase.size());
  int n = 0;
  for (auto &kv : g_th_colorbase_n) { if (n++ < 24) std::printf("      colorbase %03x x%u\n", kv.first, kv.second); }
}
static std::set<uint32_t> g_geo_writes;      // word addresses geo_polygon_data wrote
static std::vector<std::array<int,10>> g_quads;  // screen quads, colour (R222), sort z (R226)
// base_buffer, as passed to m2_cpu_bridge -- the SAME array the CPU reaches
// buffer RAM through, so the coprocessor and the CPU finally share one memory.
// File scope because mem_tick() is defined above the base constants it needs.
static const uint32_t BUF_BASE = 0x16d0000;
static uint64_t cpu_buf_writes = 0;
static uint32_t cpu_buf_lo = 0xffffffffu, cpu_buf_hi = 0;
static uint64_t mem_words = 0;

static bool load_file(const std::string &p, std::vector<uint8_t> &out) {
  FILE *f = std::fopen(p.c_str(), "rb");
  if (!f) return false;
  std::fseek(f, 0, SEEK_END); long n = std::ftell(f); std::fseek(f, 0, SEEK_SET);
  out.resize(size_t(n));
  const size_t got = std::fread(out.data(), 1, size_t(n), f);
  std::fclose(f);
  return got == size_t(n);
}

static FILE *g_dplog = nullptr;
static bool g_set_contam = false;
// Last bus transactions, dumped once when the CPU first traps or halts --
// the black-box flight recorder for a crash whose cause is a memory answer.
struct BusEv { uint32_t addr, data; uint32_t insn; uint8_t we, be; };
static BusEv g_ring[64]; static unsigned g_ring_n = 0; static bool g_ring_dumped = false;
static int g_r5_n = 0;
static int g_vs_n = 0;
static int g_e1n = 0, g_e0n = 0, g_win = 0, g_bk_n = 0, g_c3_n = 0, g_src_n = 0, g_sw_n = 0;
static const int FW = 496, FH = 384;
static std::vector<uint8_t> g_frame(size_t(FW)*FH*3, 0);
static int g_px = 0, g_py = 0, g_hb_p = 0, g_vb_p = 0;
static uint64_t g_nonblack = 0, g_frames_done = 0;
static FILE *g_copro_trace = nullptr;
static FILE *g_state_trace = nullptr;
enum { IPRING = 40 };
static uint32_t g_ipring[IPRING], g_ipring_last = 0xffffffffu;
static uint64_t g_shadow_ok = 0, g_shadow_bad = 0, g_shadow_rom_ok = 0, g_shadow_rom_bad = 0;
static unsigned g_ipring_w = 0; static uint32_t g_trap_addr = 0; static bool g_trapped = false;
// M2_FINDVAL: log every bus transaction carrying this value, which is how a
// pointer written into a table in RAM gets located.
static uint32_t g_findval = 0;
static long g_eng_st_hist[32] = {0}; static long g_pj_busy_ticks = 0;
static long g_pj_k_ticks = 0, g_pj_w_ticks = 0, g_w_grants = 0, g_k_grants = 0, g_pj_hits = 0; static long g_walk_hist[16] = {0};
static long g_eng_busy_ticks = 0, g_eng_objs = 0, g_eng_quads = 0; static std::vector<int> *g_eng_gaps = nullptr;
static bool g_rd_pend = false;   // a coprocessor FIFO read that stalled at its start
static int g_at_st = 0; static uint32_t g_at_in[2] = {0, 0}; static long g_at_n = 0, g_at_bad = 0;
// M2_STATE_ADDR picks the word to watch; the game dispatches through function
// pointers in work RAM, so which one matters changes as the chain is followed.
static uint32_t g_state_addr = 0x0053e5f4u;
static unsigned g_engrd_n = 0;   // first few engine object reads, dumped
static unsigned g_pdrd_n = 0;    // first few polygon_data reads, dumped
static FILE *g_pdlog = nullptr;  // M2_PDLOG: the walker's reads, state by state
// The instruction-pointer histogram is sampled inside geo_tick, which is
// defined above main's locals, so these live at file scope.
static std::map<uint32_t,uint64_t> ip_hist;
static uint64_t ip_samp = 0;
static const char *g_seq_dir = nullptr;
// CHARACTER WORKING SET. Glyph pixels are the one part of the 2D path still
// fetched from SDRAM; everything else (tilemap, palette, colour table) is
// on-chip. If the set of words the renderer actually touches is small enough,
// it could live in M10K too -- which would take SDRAM out of the 2D renderer
// entirely. This counts the distinct addresses, which is the number that
// decides it.
#include <set>
static std::set<uint32_t> g_char_words;
static uint64_t g_char_fetches = 0;
static uint64_t g_seq_every = 1;   // M2_FRAME_EVERY: keep every Nth frame
static std::map<uint32_t,uint64_t> g_rd_unbacked;
static uint64_t g_tw_in_vbl = 0, g_tw_out_vbl = 0, g_ss_in = 0, g_ss_out = 0;
static uint16_t g_tram[32768];
static std::map<uint32_t, std::map<uint16_t,int>> g_tram_ip;
static std::map<uint32_t,int> g_prof;
static int g_flagw = 0;
static int g_loopr = 0;
static int g_ptrw = 0;
static bool g_draw_seen = false;
static uint64_t g_draw_insn = 0;
static std::map<uint32_t, std::map<uint32_t,uint32_t>> *g_st1578 = nullptr;
static bool     g_tram_seen[32768];
static uint16_t g_pal[8192];
static bool     g_pal_seen[8192];
static uint8_t g_xlat[96];
static bool    g_xlat_seen[96];

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  uint64_t max_instr = 3'000'000;
  for (int i = 1; i < argc; i++)
    if (!std::strncmp(argv[i], "+insn=", 6))
      max_instr = std::strtoull(argv[i] + 6, nullptr, 10);

  // A PC STREAM FROM THE COMPOSITION, so the differential can be run against
  // MAME through the REAL bridge. tb_i960_rom's stream comes from a path that
  // has never included it, which is exactly how a bridge defect survived
  // 803,355 verified instructions.
  const char *outfile = nullptr;
  for (int i = 1; i < argc; i++)
    if (!std::strncmp(argv[i], "+out=", 5)) outfile = argv[i] + 5;

  const char *rp = std::getenv("M2_ROMPATH");
  const std::string dir = std::string(rp ? rp :
      (std::string(std::getenv("HOME") ? std::getenv("HOME") : ".") + "/roms/Model2"))
      + "/daytona93/";

  std::vector<uint8_t> lo, hi;
  if (!load_file(dir + "epr-16530a.12", lo) || !load_file(dir + "epr-16531a.13", hi)) {
    std::printf("SKIP (no ROMs; set M2_ROMPATH to a directory holding daytona93/)\n");
    return 0;
  }

  mem.assign(size_t(1) << 25, 0xffff);
  // R247: THE DISPLAY-LIST RAM COMES UP WITH THE REFERENCE'S PATTERN, as
  // model2.cpp's reset sets it -- 0x07800F0F in every dword of the 128 KB.
  // Model2.sv now sweeps it at boot; the bench has no boot sweep, so it starts
  // there. Unwritten, it read 0xFFFF, and a texture-parameter command that runs
  // past what the game wrote then read diffuse 255 and ambient 255, which
  // saturates every polygon that uses the entry.
  for (uint32_t i = 0; i < 0x10000u; i++) mem[0x16f0000u + i] = (i & 1) ? 0x0780 : 0x0f0f;
  // R223: TEXTURE RAM IS ZERO AT BOOT, because Model2.sv sweeps it once after
  // the capture calibration -- the reference's raster_state is value-
  // initialised and nothing in a whole run of this title ever writes it, so
  // 0xFFFF here would say "translucent" for the 3% of objects that read their
  // texture header from it and cull every one.
  for (size_t i = 0; i < 0x10000; i++) mem[0x1740000 + i] = 0;

  // BUFFER RAM IS INITIALISED ON HARDWARE AND WAS NOT HERE. Model2.sv's bi_*
  // writer fills 65,536 words with 0x07800f0f before the i960 leaves reset
  // (cpu_rst_n is gated on bi_done), because MAME does the same at reset and
  // calls it "a sane default": 0x07800f0f decodes as opcode 0x0f, geo_end, so
  // a walk starting anywhere in untouched buffer RAM stops on its first word.
  //
  // Without this the harness models neither the board nor MAME but a third
  // thing -- mapped but reading 0xFFFFFFFF -- and any conclusion drawn from
  // BUFFERRAM_EN=1 was about that third thing. The harness maps base_buffer at
  // word 0x16d0000; Model2.sv uses 0x16f0000, and the two need not agree
  // because each is self-consistent.
  for (uint32_t i = 0; i < 65536; ++i)
    mem[0x16d0000 + i] = (i & 1) ? 0x0780 : 0x0f0f;

  // Program ROM: two 16-bit halves at 32-bit stride, at GAME_PROG = word 0.
  for (size_t w = 0; w * 2 < lo.size(); ++w) {
    mem[w * 2 + 0] = uint16_t(lo[w * 2] | (lo[w * 2 + 1] << 8));
    mem[w * 2 + 1] = uint16_t(hi[w * 2] | (hi[w * 2 + 1] << 8));
  }

  // main_data at GAME_DATA = word 0x20000, same interleave.
  // THE WHOLE MRA IMAGE, IF IT IS OFFERED. Everything below loads program ROM
  // and SIX main_data files and leaves the other 34 MB at 0xffff, so the CPU
  // reading the upper image -- where the graphics live -- has never been
  // simulated at all. The board loads the full 43.62 MB through the MRA, and
  // "it renders correctly in simulation" has therefore always been a statement
  // about a PARTIAL image.
  //
  // Build the file with tools/rom_csum.py's build_image() and pass it in
  // M2_BOOT_IMAGE. It is loaded at word 0, exactly as the loader places it, so
  // every bridge address translation is exercised against real data.
  if (const char *ip = std::getenv("M2_BOOT_IMAGE")) {
    std::vector<uint8_t> full;
    if (load_file(ip, full)) {
      const size_t nw = full.size() / 2;
      for (size_t w = 0; w < nw && w < mem.size(); ++w)
        mem[w] = uint16_t(full[w*2] | (full[w*2+1] << 8));
      std::printf("  FULL IMAGE: %zu bytes (%.2f MB), %zu words from %s\n",
                  full.size(), double(full.size())/1048576.0, nw, ip);
      mem_words = nw;
    } else {
      std::printf("  M2_BOOT_IMAGE set but %s could not be read\n", ip);
    }
  }

  const uint32_t DATA_BASE = 0x20000;
  struct { const char *n; uint32_t off, len; } md[] = {
    {"mpr-16528.10", 0x000000, 0x200000}, {"mpr-16529.11", 0x000002, 0x200000},
    {"mpr-16526.8",  0x400000, 0x200000}, {"mpr-16527.9",  0x400002, 0x200000},
    {"epr-16534a.6", 0x800000, 0x100000}, {"epr-16535a.7", 0x800002, 0x100000},
  };
  int md_ok = 0;
  for (auto &e : md) {
    std::vector<uint8_t> f;
    if (!load_file(dir + e.n, f)) continue;
    ++md_ok;
    for (uint32_t w = 0; w * 2 < e.len && w * 2 < f.size(); ++w) {
      const uint32_t byte = (e.off & ~3u) + w * 4 + (e.off & 2u);
      const size_t   word = DATA_BASE + (byte >> 1);
      if (word < mem.size()) mem[word] = uint16_t(f[w * 2] | (f[w * 2 + 1] << 8));
    }
  }
  // THE COPROCESSOR'S DATA ROM, AND IT WAS NEVER LOADED.
  //
  // Nothing wrote GAME_COPRO in this harness, so every copro data-ROM read
  // returned the uninitialised 0xFFFFFFFF. That is not cosmetic: the TGP's
  // init at 0x7CE reads dword 0x10 of this ROM and adds 0x800000 to make
  // $0x69, the base every display-list access is computed from
  // (0x474 `mov $0x69, d`, 0x475 `addd`, 0x478 `mov d, rf3`). MAME has
  // $0x69 = 0xFF800030; with an all-ones read ours came out 0x30 short, so the
  // count at 0x47C was fetched from dword 0x1057 instead of 0x1087 and read
  // as 0xFFFFFFFF -- 4.3 billion loop iterations, and the mailbox never
  // cleared.
  //
  // ROM_REGION32_LE("copro_data") in model2.cpp: two ROM_LOAD32_WORDs, the
  // same low/high interleave as main_data above.
  {
    struct { const char *n; uint32_t off, len; } cd[] = {
      {"mpr-16537.ic28", 0x000000, 0x200000},
      {"mpr-16536.ic29", 0x000002, 0x200000},
    };
    int cd_ok = 0;
    for (auto &e : cd) {
      std::vector<uint8_t> f;
      if (!load_file(dir + e.n, f)) continue;
      ++cd_ok;
      for (uint32_t w = 0; w * 2 < e.len && w * 2 < f.size(); ++w) {
        const uint32_t byte = (e.off & ~3u) + w * 4 + (e.off & 2u);
        const size_t   word = 0x520000 + (byte >> 1);
        if (word < mem.size()) mem[word] = uint16_t(f[w * 2] | (f[w * 2 + 1] << 8));
      }
    }
    std::printf("  copro data ROM: %d/2 files at word 0x520000", cd_ok);
    if (cd_ok == 2)
      // VERIFIED AGAINST MAME ITSELF, not against memory: reading :copro_data
      // out of MAME 0.289 on the same ROMs gives dword 0x10 = 00000030, which
      // is what this loads. The expectation here previously read "ff000030",
      // which is wrong, and it sat in the output implying a ROM fault for a
      // long time. MAME's first words are 3f800000 00000000 00000000 00000000
      // 00000000 3f800000 -- an identity matrix -- and ours match.
      std::printf("   dword 0x10 = %04x%04x (MAME: 00000030, verified)",
                  mem[0x520000 + 0x21], mem[0x520000 + 0x20]);
    std::printf("\n");
  }

  // THE POLYGON ROM, AND WHETHER GAME_POLY IS WHERE THE ARITHMETIC SAYS (R169).
  //
  // 12 MB of models, loaded by the MRA and never read until the geometry engine
  // needs them. The base is derived from the MRA's stream order rather than
  // declared anywhere, so it is checked rather than trusted: R154 is the
  // precedent -- the copro data ROM was never loaded here at all, every read of
  // it returned 0xFFFFFFFF, and the arithmetic for ITS base was perfectly
  // correct the whole time.
  {
    struct { const char *n; uint32_t off, len; } pg[] = {
      {"mpr-16523.ic16", 0x000000, 0x200000}, {"mpr-16518.ic20", 0x000002, 0x200000},
      {"mpr-16524.ic17", 0x400000, 0x200000}, {"mpr-16519.ic21", 0x400002, 0x200000},
      {"mpr-16525.ic18", 0x800000, 0x200000}, {"mpr-16520.ic22", 0x800002, 0x200000},
    };
    int pg_ok = 0;
    for (auto &e : pg) {
      std::vector<uint8_t> f;
      if (!load_file(dir + e.n, f)) continue;
      ++pg_ok;
      for (uint32_t w = 0; w * 2 < e.len && w * 2 < f.size(); ++w) {
        const uint32_t byte = (e.off & ~3u) + w * 4 + (e.off & 2u);
        const size_t   word = 0xb20000 + (byte >> 1);
        if (word < mem.size()) mem[word] = uint16_t(f[w * 2] | (f[w * 2 + 1] << 8));
      }
    }
    std::printf("  polygon ROM: %d/6 files at GAME_POLY word 0xb20000", pg_ok);
    // THE TEXTURE ROM (R222): 8 MB at MRA byte 0x0e40000, word 0x0720000, the
    // same 32-bit interleave of two 16-bit ROMs (ROM_LOAD32_WORD). Read for the
    // texture headers -- four 16-bit words per polygon -- and for nothing else
    // yet. Loaded here because the header probe read 0xFFFF everywhere and
    // reported every object as translucent, textured and colorbase 0x3ff.
    {
      struct { const char *n; uint32_t off, len; } tx[] = {
        {"mpr-16522.25", 0x000000, 0x200000}, {"mpr-16521.24", 0x000002, 0x200000},
        {"mpr-16517.27", 0x400000, 0x200000}, {"mpr-16516.26", 0x400002, 0x200000},
      };
      int tx_ok = 0;
      for (auto &e : tx) {
        std::vector<uint8_t> f;
        if (!load_file(dir + e.n, f)) continue;
        ++tx_ok;
        for (uint32_t w = 0; w * 2 < e.len && w * 2 < f.size(); ++w) {
          const uint32_t byte = (e.off & ~3u) + w * 4 + (e.off & 2u);
          const size_t   word = 0x720000 + (byte >> 1);
          if (word < mem.size()) mem[word] = uint16_t(f[w * 2] | (f[w * 2 + 1] << 8));
        }
      }
      std::printf("\n  texture ROM: %d/4 files at word 0x720000, dword 0 = %04x%04x", tx_ok, mem[0x720001], mem[0x720000]);
    }
    if (pg_ok == 6) {
      // The first dword, interleaved as the region is: low word from ic16,
      // high word from ic20. Non-zero is the whole point -- an unloaded region
      // reads as the power-up pattern and would say the base was wrong.
      std::printf("   dword 0 = %04x%04x", mem[0xb20000 + 1], mem[0xb20000]);
      if (mem[0xb20000] == 0xffff && mem[0xb20000 + 1] == 0xffff)
        std::printf("   <<< READS ALL-ONES: NOT LOADED, or the base is wrong");
    }
    std::printf("\n");
  }

  // THE TGP's MATH TABLES, at GAME_TGPTBL. 64K 32-bit words: sincos, atan,
  // inverse and inverse-square-root quadrants.
  //
  // The interleave is NOT guessed. MAME's own :copro_tgp_tables region starts
  // 00000000 38c90fdb 39490fdb -- sin of 0, of 2*pi/65536, of twice that --
  // and only one arrangement of the two ROMs reproduces it: opr-14742a
  // supplies bits 15:0 and opr-14743a bits 31:16, each little-endian within
  // itself. That is what the .mra's interleave already produced, and checking
  // it against the reference cost one script and settles a byte order that
  // cost four builds the last time it was assumed (R94).
  const uint32_t TBL_BASE = 0x15d0000;      // GAME_TGPTBL, word address (R203: 0x2BA0000 bytes, not 0x2BB0000)
  {
    std::vector<uint8_t> ta, tb;
    if (load_file(dir + "opr-14742a.45", ta) && load_file(dir + "opr-14743a.46", tb)) {
      const size_t n = std::min(ta.size(), tb.size()) / 2;   // 32-bit words
      for (size_t i = 0; i < n; ++i) {
        const size_t w = TBL_BASE + i * 2;
        if (w + 1 >= mem.size()) break;
        mem[w    ] = uint16_t(ta[i*2] | (ta[i*2+1] << 8));
        mem[w + 1] = uint16_t(tb[i*2] | (tb[i*2+1] << 8));
      }
      std::printf("  TGP math tables: %zu 32-bit words at word 0x%x\n", n, TBL_BASE);
    } else {
      std::printf("  WARNING: no TGP math tables -- every lookup reads 0xFFFF\n");
    }
  }

  std::printf("  program ROM %zu+%zu bytes, main_data files %d of 6\n",
              lo.size(), hi.size(), md_ok);

  d = new Vm2_boot_harness;
  d->clk_cpu = 0; d->clk_mem = 0; d->clk_vid = 0; d->ce_pix = 0;
  d->sd2_ack = 0; d->sd2_dout = 0; d->rst_n = 0; d->irq = 0;
  d->sd_ack = 0; d->sd_dout = 0;

  // The SDRAM: one word per transaction into sd_dout[15:0], acknowledged for two
  // mem cycles, which is m2_sdram's ACK_HOLD. The bridge waits for the ack to
  // FALL before its next access (S_LO_W / S_HI_W), so holding it is not
  // optional — a one-cycle ack would let it run ahead of the real controller.
  // SWEEPING THE MEMORY LATENCY IS A DIAGNOSTIC, not a tuning knob. If the
  // outcome changes with it, the fault is a handshake race rather than an
  // address calculation -- and study rule 8 says to sweep an order of magnitude
  // past the value you believe, or the test confirms the setting instead of
  // testing it.
  const char *lf = std::getenv("M2_BOOT_LAT");
  const int sdr_lat = lf ? std::atoi(lf) : 6;
  // Declared before mem_tick, which uses them.
  uint64_t char_even = 0, char_odd = 0;
  int  lat = 0, ack_left = 0;
  bool busy = false;
  uint32_t pend_addr = 0;

  const char *sf = std::getenv("M2_BOOT_SDR");
  const uint32_t sdr_from = sf ? uint32_t(std::strtoul(sf, nullptr, 10)) : 0;
  int n_sdr = 0;

  auto mem_tick = [&]() {
    if (sdr_from && d->dbg_acc >= sdr_from && n_sdr < 60 && d->sd_req && !busy && !ack_left) {
      std::printf("      sdr i%-4u %s word %07x\n", d->dbg_acc,
                  d->sd_we ? "wr" : "rd", d->sd_addr);
      ++n_sdr;
    }
    if (!busy && d->sd_req && !ack_left) {
      busy = true; lat = sdr_lat; pend_addr = d->sd_addr;
      // WHAT THE BRIDGE ACTUALLY ISSUES INTO CHAR RAM, split by whether the
      // word is even or odd. A 32-bit store becomes two 16-bit transactions,
      // S_LO then S_HI, so the two counts should be equal. They are not on
      // hardware: every odd word of char RAM is missing.
      if (d->sd_we) {
        const uint32_t CB = 0x1690000;
        if (d->sd_addr >= CB && d->sd_addr < CB + 0x40000) {
          if (d->sd_addr & 1) ++char_odd; else ++char_even;
        }
      }
      // DID ANYONE WRITE THE DISPLAY LIST? The TGP reads its loop count from
      // buffer RAM at 0x47C and gets 0xFFFFFFFF, which is this project's
      // signature for memory nobody has written. This says whether the CPU
      // wrote the window at all, and where.
      if (d->sd_we && pend_addr >= BUF_BASE && pend_addr < BUF_BASE + 0x10000) {
        ++cpu_buf_writes;
        const uint32_t off = pend_addr - BUF_BASE;
        if (off < cpu_buf_lo) cpu_buf_lo = off;
        if (off > cpu_buf_hi) cpu_buf_hi = off;
      }
      if (d->sd_we) {
        const uint16_t old = mem[pend_addr & 0x1ffffff];
        uint16_t v = d->sd_din;
        if (!(d->sd_be & 1)) v = uint16_t((v & 0xff00) | (old & 0x00ff));
        if (!(d->sd_be & 2)) v = uint16_t((v & 0x00ff) | (old & 0xff00));
        mem[pend_addr & 0x1ffffff] = v;
      }
    } else if (busy && --lat <= 0) {
      // FOUR WORDS, not one. m2_sdram bursts four and packs them into the
      // 64-bit p_dout, and the bridge takes a 32-bit access's two halves out
      // of one transaction rather than issuing two. Returning only the low
      // word made every fetch's upper half read zero, and the boot executed
      // one instruction and trapped.
      {
        const uint32_t a = pend_addr & 0x1ffffff;
        uint64_t v = 0;
        for (int w = 0; w < 4; ++w)
          v |= uint64_t(mem[(a + w) & 0x1ffffff]) << (16 * w);
        d->sd_dout = v;
      }
      ack_left = 2; busy = false;
    }
    d->sd_ack = ack_left > 0;
    if (ack_left > 0) --ack_left;
  };

  // THE RENDERER'S SDRAM PORT. Separate from the CPU's, as m2_sdram gives it,
  // so this does not invent contention the hardware does not have. Latency is
  // settable because the board's is not constant.
  int sd2_left = -1;
  uint32_t sd2_data = 0;
  const int sd2_lat = std::getenv("M2_CHAR_LAT")
                    ? std::atoi(std::getenv("M2_CHAR_LAT")) : 6;
  auto sd2_tick = [&]() {
    d->sd2_ack = 0;
    if (sd2_left < 0 && d->sd2_req) {
      const uint32_t a = d->sd2_addr & 0x1ffffff;
      sd2_data = uint32_t(mem[a]) | (uint32_t(mem[(a + 1) & 0x1ffffff]) << 16);
      sd2_left = sd2_lat;
    } else if (sd2_left > 0) {
      --sd2_left;
    } else if (sd2_left == 0) {
      d->sd2_dout = sd2_data;
      d->sd2_ack  = 1;
      sd2_left    = -1;
    }
  };

  // THE DISPLAY-LIST WALK, served out of the same modelled memory.
  //
  // The walker reads DWORDS from buffer RAM by dword index; base_buffer is
  // word 0x16f0000, so the word address is base + (index << 1). Writes are
  // 16-bit halves at whatever word address geo_polygon_data computed, which is
  // exactly what needs checking -- if the destination decode is wrong they will
  // land somewhere recognisable, like word 0.
  // R240: THE PORT BEHIND THE PAIR CACHES, when the harness was built with
  // PAIR_EN. A request is taken on its rising edge, answered M2_PAIR_LAT ticks
  // later (default 6, about the board's port round trip) with the dword at the
  // index in the low half and the NEXT dword in the high half -- taken as
  // m2_sdram takes it, by incrementing the column inside the 1,024-word row,
  // so the pair at a row's last dword is the row's FIRST dword. The
  // acknowledge is held while the request stands (m2_sdram_x2).
  struct PairPort { int req_d = 0, cnt = -1, done = 0; uint32_t idx = 0; uint64_t dout = 0; };
  static PairPort pp_geo, pp_eng;
  static const int pair_lat = std::getenv("M2_PAIR_LAT") ? std::atoi(std::getenv("M2_PAIR_LAT")) : 6;
  auto pair_serve = [&](PairPort& p, int req, uint32_t pidx) {
    if (req && !p.req_d && p.cnt < 0 && !p.done) { p.cnt = pair_lat; p.idx = pidx; }
    p.req_d = req;
    if (p.cnt > 0 && --p.cnt == 0) {
      const uint32_t w  = (p.idx * 2u) & 0x1ffffffu;
      const uint32_t w2 = (w & ~1023u) | ((w + 2u) & 1023u);
      const uint64_t lo = uint32_t(mem[w]) | (uint32_t(mem[(w + 1u) & 0x1ffffffu]) << 16);
      const uint64_t hi = uint32_t(mem[w2]) | (uint32_t(mem[(w2 + 1u) & 0x1ffffffu]) << 16);
      p.dout = lo | (hi << 32); p.done = 1; p.cnt = -1;
    }
    if (!req) p.done = 0;
  };
  auto geo_tick = [&]() {
    if (d->pair_en) {
      pair_serve(pp_geo, d->geo_p_req, uint32_t(d->geo_p_idx));
      pair_serve(pp_eng, d->eng_p_req, uint32_t(d->eng_p_idx));
      d->geo_p_ack = pp_geo.done; d->geo_p_dout = pp_geo.dout;
      d->eng_p_ack = pp_eng.done; d->eng_p_dout = pp_eng.dout;
    }
    d->geo_rd_ack = 0;
    // With the board's handshake modelled the service runs EVERY tick: `done`
    // clears on the tick the request is low, and that tick must be seen.
    static const int geo_lat_on = std::getenv("M2_GEO_LAT") ? std::atoi(std::getenv("M2_GEO_LAT")) : 0;
    if (d->geo_rd_req || geo_lat_on > 0) {
      // WHAT THE WALKER READS FOR A polygon_data COMMAND. MAME's format is
      // address, then a full-dword count, then that many payload words. Ours
      // reports 32 commands and 0 dwords, so every count word is reading zero
      // and the payload is skipped -- which leaves polygon RAM unwritten, and
      // an unwritten read is 0xFFFFFFFF, exponent 0xFF, refused by the
      // non-finite gate. States: 4=W_CNT, 10=W_PDA, 11=W_PDR.
      const unsigned st = d->geo_state & 15;
      static unsigned last_st = 99; static uint32_t last_a = 0xffffffff;
      const bool newrd = (st != last_st) || (uint32_t(d->geo_rd_addr) != last_a);
      if (newrd) { last_st = st; last_a = uint32_t(d->geo_rd_addr); }
      if (newrd && d->geo_rd_req && g_pdlog && g_pdrd_n < 400000 && st <= 12) {
        static const char *WN[13] = {"W_IDLE","W_FETCH","W_DECODE","W_SKIP","W_CNT",
                                     "W_TFIFO","W_DDSKIP","W_DDATTR","W_OPRD","W_OBJW",
                                     "W_PDA","W_PDR","W_PDW"};
        const char *nm = WN[st];
        const uint32_t aa = (0x16f0000u + (uint32_t(d->geo_rd_addr) << 1)) & 0x1ffffff;
        std::fprintf(g_pdlog, "%-8s ip=%05x word %07x = %08x\n",
                    nm, (unsigned)d->geo_rd_addr, aa,
                    (unsigned)(uint32_t(mem[aa]) | (uint32_t(mem[(aa+1)&0x1ffffff]) << 16)));
        ++g_pdrd_n;
      }
      // THE BOARD'S HANDSHAKE, WHEN ASKED (M2_GEO_LAT=N): the controller
      // latches the address on the request's RISING edge, answers N ticks
      // later, holds the acknowledge two ticks, and ignores the request level
      // in between. Unset, the walker is answered in the same tick from the
      // address it presents -- which cannot show a stream that arrives one
      // word ahead (study R207).
      static const int geo_lat = std::getenv("M2_GEO_LAT") ? std::atoi(std::getenv("M2_GEO_LAT")) : 0;
      // Modelled as m2_sdram_x2 does it (R162): the request is registered
      // (Model2.sv's geo_rd_req_r), a fast read is issued when it stands with
      // no `done`, `done` latches on the fast acknowledge and clears ONLY
      // when the registered request is low, the acknowledge is f_ack | done
      // and reaches the walker a tick late (geo_rd_ack_r), data held.
      static int gl_req_r = 0, gl_done = 0, gl_cnt = -1, gl_ack_r = 0;
      static uint32_t gl_addr = 0, gl_addr_r = 0, gl_data = 0;
      if (geo_lat > 0) {
        d->geo_rd_ack = gl_ack_r; d->geo_rd_data = gl_data;
        int f_ack = 0;
        if (gl_cnt > 0 && --gl_cnt == 0) {
          const uint32_t a = (0x16f0000u + (gl_addr << 1)) & 0x1ffffff;
          gl_data = uint32_t(mem[a]) | (uint32_t(mem[(a + 1) & 0x1ffffff]) << 16);
          f_ack = 1; gl_cnt = -1;
        }
        if (!gl_req_r) gl_done = 0; else if (f_ack) gl_done = 1;
        if (gl_req_r && !gl_done && !f_ack && gl_cnt < 0) { gl_cnt = geo_lat; gl_addr = gl_addr_r; }
        gl_ack_r = f_ack | gl_done;
        gl_req_r = d->geo_rd_req; gl_addr_r = uint32_t(d->geo_rd_addr);
        static FILE *gt = std::getenv("M2_GEOTRACE") ? std::fopen(std::getenv("M2_GEOTRACE"), "w") : nullptr;
        static int gt_n = 0;
        // R253: GATED BY VIDEO FRAME, and long enough to hold a whole walk. The
        // first version started at the first walk and stopped after 6,000
        // lines, which is entirely inside the boot -- before the game has
        // written a display list at all, so every read returned the buffer's
        // fill pattern and the trace said the walk ends immediately.
        static const uint64_t gt_from = std::getenv("M2_GEOTRACE_FROM") ? std::strtoull(std::getenv("M2_GEOTRACE_FROM"), nullptr, 10) : 0;
        if (gt && g_frames_done >= gt_from && (st != 0 || gt_n) && gt_n < 4000000) {
          std::fprintf(gt, "%llu st=%u req=%d addr=%05x ack=%d data=%08x cnt=%d done=%d ebusy=%d\n",
                       (unsigned long long)d->dbg_acc, st, (int)d->geo_rd_req, (unsigned)d->geo_rd_addr,
                       (int)d->geo_rd_ack, (unsigned)d->geo_rd_data, gl_cnt, gl_done, (int)d->obs_eng_busy);
          ++gt_n;
        }
      } else {
        const uint32_t a = (0x16f0000u + (uint32_t(d->geo_rd_addr) << 1)) & 0x1ffffff;
        d->geo_rd_data = uint32_t(mem[a]) | (uint32_t(mem[(a + 1) & 0x1ffffff]) << 16);
        d->geo_rd_ack  = 1;
      }
    } else {
      static int *dummy = nullptr; (void)dummy;
    }
    // The geometry engine reads objects: polygon ROM if oba bit 23, otherwise
    // one of the two polygon RAMs. Same decode as Model2.sv's.
    d->eng_mem_ack = 0;
    if ((++ip_samp & 0xffff) == 0) ++ip_hist[uint32_t(d->dbg_ip)];
    // THE SCROLL THE RENDERER LATCHED, LOGGED ON CHANGE (M2_SCRLOG=<file>):
    // the background jumps vertically on the board; a value that alternates
    // frame to frame here is the game (or the write path) doing it.
    {
      static FILE *sf = std::getenv("M2_SCRLOG") ? std::fopen(std::getenv("M2_SCRLOG"), "w") : nullptr;
      static uint16_t pv[4] = {0xffff,0xffff,0xffff,0xffff}, ph[4] = {0xffff,0xffff,0xffff,0xffff};
      static long sn = 0;
      if (sf && sn < 200000) for (int i = 0; i < 4; i++) {
        if (d->obs_vscr[i] != pv[i] || d->obs_hscr[i] != ph[i]) {
          std::fprintf(sf, "%llu L%d hscr=%04x vscr=%04x\n", (unsigned long long)d->dbg_acc, i, (unsigned)d->obs_hscr[i], (unsigned)d->obs_vscr[i]);
          pv[i] = d->obs_vscr[i]; ph[i] = d->obs_hscr[i]; ++sn;
        }
      }
    }
    static const uint64_t quads_from = std::getenv("M2_POLY_FROM") ? std::strtoull(std::getenv("M2_POLY_FROM"), nullptr, 10) : 0;
    // R215: WHERE THE COLLECT'S TIME GOES. Ticks of engine-busy per object
    // and per emitted quad, and ticks between consecutive quads, from
    // M2_POLY_FROM on. Reported at the end.
    {
      static long busy_ticks = 0, objs = 0, quads = 0; static int busy_p = 0;
      static std::vector<int> gaps; static long last_q = -1; static long tick_n = 0;
      ++tick_n;
      if (d->dbg_acc >= quads_from) {
        if (d->obs_eng_busy) ++busy_ticks;
        if (d->obs_eng_busy && !busy_p) ++objs;
        if (d->eng_q_valid) { ++quads; if (last_q >= 0 && gaps.size() < 200000) gaps.push_back((int)(tick_n - last_q)); last_q = tick_n; }
      }
      busy_p = d->obs_eng_busy;
      g_eng_busy_ticks = busy_ticks; g_eng_objs = objs; g_eng_quads = quads; g_eng_gaps = &gaps;
      if (d->dbg_acc >= quads_from) {
        ++g_eng_st_hist[d->obs_eng_state & 31]; if (d->obs_pj_busy) ++g_pj_busy_ticks;
        if (d->obs_pj_busy) { if (d->obs_pj_owner) ++g_pj_k_ticks; else ++g_pj_w_ticks; }
        if (d->obs_w_granted) ++g_w_grants; if (d->obs_k_granted) ++g_k_grants; if (d->obs_pj_hit) ++g_pj_hits;
        ++g_walk_hist[d->geo_state & 15];
        { static unsigned last_st = 0; if ((d->geo_state & 15) == 2 && last_st != 2) ++g_op_hist[d->geo_w_op & 31]; last_st = d->geo_state & 15; }
        // R253: THE COMMAND STREAM, with the address each command was decoded
        // at. The walker's opcode histogram says it decodes 417 nops a frame
        // that the reference's list does not contain, and a histogram cannot
        // say where the walk left the rails. M2_WALKLOG=<file> writes one line
        // per decode from M2_WALKLOG_FROM (a video frame).
        {
          static FILE *wl = std::getenv("M2_WALKLOG") ? std::fopen(std::getenv("M2_WALKLOG"), "w") : nullptr;
          static const uint64_t wl_from = std::getenv("M2_WALKLOG_FROM") ? std::strtoull(std::getenv("M2_WALKLOG_FROM"), nullptr, 10) : 0;
          static unsigned wl_st = 0; static long wl_n = 0;
          if (wl && g_frames_done >= wl_from && (d->geo_state & 15) == 2 && wl_st != 2 && wl_n < 200000) {
            std::fprintf(wl, "f%llu ip=%05x op=%02x\n", (unsigned long long)g_frames_done,
                         (unsigned)d->geo_w_ip, (unsigned)d->geo_w_op);
            ++wl_n;
          }
          wl_st = d->geo_state & 15;
          // R254: EVERY CPU WRITE INTO THE HEAD OF THE DISPLAY LIST, with its
          // byte enables and the instruction that made it. The list our walker
          // reads has a texture_data count of ZERO where the reference's list
          // has 0x118, and everything else in it matches -- so one word is
          // being lost between the i960 and SDRAM, and this says whether the
          // CPU ever writes it.
          // R254: THE WRITE-POINTER READ. The game pushes a zero placeholder
          // for a count, reads 0x802008 to remember where it landed, pushes the
          // payload, reads it again and patches the count in. Our CPU stored
          // 0xFFFFFFFF at offset 0, which means both reads returned the same
          // value and that value was zero.
          if (wl && g_frames_done >= wl_from && d->obs_io_sel && !d->obs_io_we
              && (uint32_t(d->obs_io_addr) & 0xffffffu) == 0x802008u) {
            static long rn = 0;
            if (rn < 60) { ++rn;
              std::fprintf(wl, "WPRD 802008 -> %08x (geo_wp=%05x) ip=%08x f%llu\n",
                           (unsigned)d->obs_io_rdata, (unsigned)d->geo_wp_o,
                           (unsigned)d->obs_ip, (unsigned long long)g_frames_done);
            }
          }
          // R254: THE CPU'S OWN WRITES INTO THE GEOMETRY WINDOWS, with the
          // instruction that made each one. The push port lands zero in the
          // texture_data count slot where the reference's list holds 0x118,
          // and the word is pushed verbatim from that window, so the question
          // is what the i960 wrote and where it got it.
          if (wl && g_frames_done >= wl_from && d->obs_io_sel && d->obs_io_we
              && (uint32_t(d->obs_io_addr) & 0xff8000u) == 0x800000u) {
            static long gn = 0; static uint32_t lga = 0, lgd = 0;
            if (uint32_t(d->obs_io_addr) == lga && uint32_t(d->obs_io_wdata) == lgd) gn = gn;
            else { lga = uint32_t(d->obs_io_addr); lgd = uint32_t(d->obs_io_wdata);
            if (gn < 400) { ++gn;
              std::fprintf(wl, "GEOWR %06x = %08x ip=%08x f%llu\n",
                           (unsigned)d->obs_io_addr, (unsigned)d->obs_io_wdata,
                           (unsigned)d->obs_ip, (unsigned long long)g_frames_done);
            } }
          }
          // R254: and what the PUSH PORT's drain lands in the list head. The
          // list arrives through the geometry push port, not through CPU
          // stores, and its queue drops when full without advancing the write
          // pointer -- so a dropped dword is a hole in the list.
          if (wl && g_frames_done >= wl_from && d->geo_sd_req
              && uint32_t(d->geo_sd_addr) >= 0x16f0000u && uint32_t(d->geo_sd_addr) < 0x16f0040u) {
            static uint32_t la = 0; static uint16_t ld = 0;
            if (uint32_t(d->geo_sd_addr) != la || uint16_t(d->geo_sd_din) != ld) {
              std::fprintf(wl, "PUSHWR word %07x = %04x (dword %x half %d) f%llu\n",
                           (unsigned)d->geo_sd_addr, (unsigned)d->geo_sd_din,
                           (unsigned)((uint32_t(d->geo_sd_addr) - 0x16f0000u) >> 1),
                           (int)(uint32_t(d->geo_sd_addr) & 1),
                           (unsigned long long)g_frames_done);
              la = uint32_t(d->geo_sd_addr); ld = uint16_t(d->geo_sd_din);
            }
          }
          if (wl && g_frames_done >= wl_from && d->obs_bus_req && d->obs_bus_ack && d->obs_bus_we
              && (uint32_t(d->obs_bus_addr) & 0xfffff000u) == 0x00900000u
              && (uint32_t(d->obs_bus_addr) & 0xfffu) < 0x80u) {
            std::fprintf(wl, "CPUWR %08x be=%x data=%08x ip=%08x f%llu\n",
                         (unsigned)d->obs_bus_addr, (unsigned)d->obs_bus_be,
                         (unsigned)d->obs_bus_wdata, (unsigned)d->obs_ip,
                         (unsigned long long)g_frames_done);
          }
          // R253: and the LIST ITSELF, once, at the frame the log starts. The
          // walk log says where the walker went; only the words it walked over
          // say whether it misread them or the list is malformed.
          static bool bd_done = false;
          if (wl && !bd_done && g_frames_done >= wl_from) {
            bd_done = true;
            if (const char *bd = std::getenv("M2_BUFDUMP")) {
              if (FILE *bf = std::fopen(bd, "wb")) {
                for (uint32_t i = 0; i < 0x10000u; i++) {
                  uint16_t v = mem[0x16f0000u + i];
                  std::fwrite(&v, 2, 1, bf);
                }
                std::fclose(bf);
              }
            }
          }
        }
      }
    }
    // R231: EVERY TICK, not inside the memory-serve block. The first version of
    // this sat under `if (d->eng_mem_req)` and so sampled only on cycles the
    // engine happened to be fetching: it reported ZERO polygons and ZERO
    // texture parameters, which would have read as "the game sets none" when
    // the walker's own opcode histogram counts 38 of them.
    // R245: the light parameter each polygon asked for, beside the entry the
    // engine read for it.
    if (d->eng_poly_go) { g_lp_used[d->eng_lp]++; if (!d->eng_lp_dif && !d->eng_lp_amb) ++g_lp_zero;
      // R248: the frame's own lighting, so a scene that renders black can be
      // SEEN happening instead of inferred from a total. Per frame: polygons,
      // mean luminance, how many came out zero, and which light entry they
      // asked for.
      ++g_fr_poly; g_fr_lsum += d->eng_luma; if (!d->eng_luma) ++g_fr_zero;
      g_fr_lp |= (1u << d->eng_lp); }
    if (d->eng_poly_go) { unsigned l = d->eng_luma; ++g_luma_n; ++g_luma_hist[l >> 4]; if (l == 0) ++g_luma_zero;
      auto u2f = [](uint32_t u){ float f; std::memcpy(&f, &u, 4); return f; };
      double nx = u2f(d->nrm_x_o), ny = u2f(d->nrm_y_o), nz = u2f(d->nrm_z_o), ln = std::sqrt(nx*nx + ny*ny + nz*nz);
      if (std::isfinite(ln)) { ++g_nlen_n; g_nlen_sum += ln; int b = ln < 0.5 ? 0 : ln < 0.9 ? 1 : ln < 1.1 ? 2 : ln < 2 ? 3 : ln < 10 ? 4 : ln < 100 ? 5 : ln < 1000 ? 6 : 7; ++g_nlen_hist[b]; } }
    if (d->tpw_we) { g_tp_dif[d->tpw_idx] = d->tpw_diffuse; g_tp_amb[d->tpw_idx] = d->tpw_ambient; g_tp_seen[d->tpw_idx] = true; ++g_tp_w[d->tpw_idx]; }
    if (d->lit_x_o != g_lit_last[0] || d->lit_y_o != g_lit_last[1] || d->lit_z_o != g_lit_last[2]) {
      g_lit_last[0] = d->lit_x_o; g_lit_last[1] = d->lit_y_o; g_lit_last[2] = d->lit_z_o;
      ++g_lights[(uint64_t(d->lit_x_o) << 32) ^ (uint64_t(d->lit_y_o) << 11) ^ d->lit_z_o];
    }
    { bool r = d->tgp_rom_rd; if (r && !g_rom_rd_d) { unsigned a = d->tgp_rom_adr & 0x7fffffu; ++g_rom_rd; if (a >= 0x100000u) ++g_rom_rd_hi; if (a > g_rom_rd_max) g_rom_rd_max = a; } g_rom_rd_d = r; }
    if (d->eng_q_valid && g_quads.size() < 65536 && d->dbg_acc >= quads_from)
      g_quads.push_back({(int)(int16_t)d->eng_q_x0, (int)(int16_t)d->eng_q_y0,
                         (int)(int16_t)d->eng_q_x1, (int)(int16_t)d->eng_q_y1,
                         (int)(int16_t)d->eng_q_x2, (int)(int16_t)d->eng_q_y2,
                         (int)(int16_t)d->eng_q_x3, (int)(int16_t)d->eng_q_y3, (int)d->eng_q_col,
                         (int)d->eng_q_z});
    // The engine, same board handshake when M2_GEO_LAT is set (R207).
    {
      static const int eng_lat = std::getenv("M2_GEO_LAT") ? std::atoi(std::getenv("M2_GEO_LAT")) : 0;
      static int el_req_r = 0, el_done = 0, el_cnt = -1, el_ack_r = 0;
      static uint32_t el_addr = 0, el_addr_r = 0, el_oba = 0, el_oba_r = 0, el_data = 0;
      static unsigned el_space = 0, el_space_r = 0;
      if (eng_lat > 0) {
        d->eng_mem_ack = el_ack_r; d->eng_mem_data = el_data;
        int f_ack = 0;
        if (el_cnt > 0 && --el_cnt == 0) {
          uint32_t base, off;
          // R222: the same four spaces the instant-ack path decodes. Without
          // this the latency model answered every texture-header, palette and
          // colour-table read out of polygon memory, so the one model that
          // represents the BOARD was the one giving the wrong colours.
          if      (el_space == 1)       { if (el_addr & 0x800000u) { base = 0x1740000u; off = el_addr & 0x7fffu; }
                                          else                    { base = 0x0720000u; off = el_addr & 0x1fffffu; } }
          else if (el_space == 2)       { base = 0x1730000u; off = el_addr & 0x1ffu;    }
          else if (el_space == 3)       { base = 0x1731000u; off = el_addr & 0x3fffu;   }
          else if (el_oba & (1u << 24)) { base = 0x1720000u; off = el_addr & 0x7fffu;   }
          else if (el_oba & (1u << 23)) { base = 0x0b20000u; off = el_addr & 0x3fffffu; }
          else                          { base = 0x1710000u; off = el_addr & 0x7fffu;   }
          const uint32_t a = (base + off * 2u) & 0x1ffffff;
          el_data = uint32_t(mem[a]) | (uint32_t(mem[(a + 1) & 0x1ffffff]) << 16);
          f_ack = 1; el_cnt = -1;
        }
        if (!el_req_r) el_done = 0; else if (f_ack) el_done = 1;
        // R237: M2_GEO_LAT_RAND=1 draws each latency uniformly from 1..eng_lat
        // instead of holding it fixed, to search the interleavings of the pool's
        // clients that the board's varying memory timing produces.
        static const bool lat_rand = std::getenv("M2_GEO_LAT_RAND") != nullptr;
        static uint32_t lat_rng = 0x9E3779B9u;
        if (el_req_r && !el_done && !f_ack && el_cnt < 0) {
          el_cnt = eng_lat;
          if (lat_rand) { lat_rng ^= lat_rng << 13; lat_rng ^= lat_rng >> 17; lat_rng ^= lat_rng << 5; el_cnt = 1 + int(lat_rng % unsigned(eng_lat)); }
          el_addr = el_addr_r; el_oba = el_oba_r; el_space = el_space_r; }
        el_ack_r = f_ack | el_done;
        el_req_r = d->eng_mem_req; el_addr_r = uint32_t(d->eng_mem_addr); el_oba_r = uint32_t(d->geo_oba_last);
        el_space_r = d->eng_mem_space;
      }
      if (eng_lat > 0) goto eng_served;
    }
    if (d->eng_mem_req) {
      // THE SAME DECODE AS Model2.sv's, WHICH THIS PREVIOUSLY CLAIMED AND WAS
      // NOT. It always used the polygon-ROM base and never masked the selector
      // bit, so for oba=0x95e0c6 it indexed 0x800000 dwords past where the core
      // reads and then wrapped on the 25-bit mask. Every vertex came back
      // 0xFFFFFFFF -- exponent 0xFF -- and m2_geometry's nonfinite gate refused
      // the lot: 20,112 rejections against 3,728 polygons, and zero quads.
      // That was a fault in this model, not in the core.
      //
      //   Model2.sv: base = oba[24] ? GAME_PRAM1 : oba[23] ? GAME_POLY : GAME_PRAM0
      //              idx  = ROM ? addr[21:0] : addr[14:0]
      g_tdwords = uint32_t(d->geo_tdwords);
      g_pj_lost = unsigned(d->eng_pj_lost);
      if (uint32_t(d->geo_objs) != g_th_last_objs) { g_th_last_objs = uint32_t(d->geo_objs); th_probe(uint32_t(d->geo_tha_last)); }
      const uint32_t oba = uint32_t(d->geo_oba_last);
      const uint32_t idx = uint32_t(d->eng_mem_addr);
      const unsigned space = d->eng_mem_space;          // R222
      uint32_t base, off;
      if      (space == 1)       { if (idx & 0x800000u) { base = 0x1740000u; off = idx & 0x7fffu; }
                                   else                 { base = 0x0720000u; off = idx & 0x1fffffu; } }
      else if (space == 2)       { base = 0x1730000u; off = idx & 0x1ffu;    }
      else if (space == 3)       { base = 0x1731000u; off = idx & 0x3fffu;   }
      else if (oba & (1u << 24)) { base = 0x1720000u; off = idx & 0x7fffu;   }
      else if (oba & (1u << 23)) { base = 0x0b20000u; off = idx & 0x3fffffu; }
      else                       { base = 0x1710000u; off = idx & 0x7fffu;   }
      const uint32_t a = (base + (off << 1)) & 0x1ffffff;
      d->eng_mem_data = uint32_t(mem[a]) | (uint32_t(mem[(a + 1) & 0x1ffffff]) << 16);
      d->eng_mem_ack  = 1;
      // Only the reads that return something other than unwritten memory: the
      // first dozen reads happen before polygon RAM is filled and say nothing.
      if (g_engrd_n < 12 && d->eng_mem_data != 0xffffffffu) {
        std::printf("      engrd %2u: oba=%08x addr=%06x -> word %07x = %08x\n",
                    g_engrd_n, oba, idx, a, (unsigned)d->eng_mem_data);
        ++g_engrd_n;
      }
    }
    d->geo_sd_ack = 0;
    eng_served:
    // PER-OBJECT READ ACCOUNTING, the bench's side of the board's build/eo
    // probe: first read (index, data) and read count for the first objects
    // after M2_POLY_FROM.
    {
      static const uint64_t eo_from = std::getenv("M2_POLY_FROM") ? std::strtoull(std::getenv("M2_POLY_FROM"), nullptr, 10) : ~0ull;
      static int req_p = 0, nobj = 0, reads = 0; static uint32_t fidx = 0, fdat = 0; static bool armed = false, inobj = false;
      // an object starts with its first request after an idle gap; count acks
      if (d->eng_mem_req && !req_p) {
        if (!inobj) { inobj = true; armed = true; reads = 0; }
      }
      if (d->eng_mem_ack) {
        if (armed) { fidx = uint32_t(d->eng_mem_addr); fdat = uint32_t(d->eng_mem_data); armed = false; }
        ++reads;
      }
      if (inobj && !d->eng_mem_req && !req_p && !d->obs_eng_busy) {
        inobj = false;
        if (d->dbg_acc >= eo_from && nobj < 20) { ++nobj; std::printf("    EOBJ %2d oba=%08x first idx %06x data %08x reads %d\n", nobj, (unsigned)d->geo_oba_last, fidx, fdat, reads); }
      }
      req_p = d->eng_mem_req;
    }
    if (d->geo_sd_req) {
      const uint32_t a = uint32_t(d->geo_sd_addr) & 0x1ffffff;
      mem[a] = d->geo_sd_din;
      g_geo_writes.insert(a);
      d->geo_sd_ack = 1;
      // The front door's writes, in the same log as the walker's reads, so a
      // read of 0xFFFFFFFF can be checked against whether anything ever wrote
      // that word. 74,272 distinct words land in a 131,072-word region, so the
      // coverage is sparse and the walker is reading holes.
      // ONLY THE WIPES, and only into the display list. A word written 0x002e
      // early reads back 0xFFFF later, so something clears buffer RAM under the
      // walker; logging every write exhausted the cap before reaching it.
      static uint32_t wn = 0;
      if (g_pdlog && wn < 200000 && d->geo_sd_din == 0xffff &&
          a >= 0x16f0000u && a < 0x1700000u) {
        std::fprintf(g_pdlog, "WIPE     word %07x = ffff\n", a); ++wn;
      }
    }
  };

  // THE COPROCESSOR'S TWO READ-ONLY WINDOWS, out of the same modelled memory.
  //
  // On the board these are SDRAM ports 8 and 9, which burst four and hand back
  // the low pair; here the pair is all that is modelled, because the upper two
  // words are discarded either way. Latency is deliberately non-zero: a window
  // that answers in the same cycle hides whether the TGP actually waits on the
  // acknowledge, and that is the handshake this harness exists to exercise.
  const uint32_t COPRO_BASE = 0x520000;     // GAME_COPRO, word address
  // base_buffer, as passed to m2_cpu_bridge below -- the SAME array the CPU
  // reaches buffer RAM through, so the two sides finally share one memory.

  int tbl_left = -1, dat_left = -1;
  uint32_t tbl_data = 0, dat_data = 0;
  const int tgp_lat = std::getenv("M2_TGP_LAT")
                    ? std::atoi(std::getenv("M2_TGP_LAT")) : 6;
  uint64_t tbl_reads = 0, dat_reads = 0;
  auto rd32 = [&](uint32_t w) -> uint32_t {
    return uint32_t(mem[w & 0x1ffffff])
         | (uint32_t(mem[(w + 1) & 0x1ffffff]) << 16);
  };
  // WHAT THE TGP IS DOING, sampled every clk_mem edge after it settles.
  //
  // "It retires instructions" and "it does useful work" are different claims,
  // and the first was all the previous run could support. A processor looping
  // on a status read it never sees change retires as fast as one doing work.
  // WHERE THE i960 SPENDS ITS TIME, sampled the same way the board's UART
  // profiler samples it -- one in 65,536 -- so the two histograms are directly
  // comparable. The board shows 0x12B0 (the idle poll), 0x18E98/0x18EA4,
  // 0x11C74 and 0x1166C; if the bench's top regions differ, that names where
  // execution diverges, and the game stops emitting geometry at frame 140.
  std::map<uint32_t,uint64_t> tgp_pc_hist, tgp_io_hist;
  uint64_t tgp_ram_req_cyc = 0, tgp_fifo_rd_n = 0, tgp_fifo_wr_n = 0;
  uint64_t tgp_io_rd_n = 0, tgp_io_wr_n = 0, tgp_io_ack_n = 0;
  // THE FIRST PCs AFTER BOOT, in order. A histogram says where it ends up; a
  // sequence says how it got there, and a wrong backward branch is only
  // visible in the second.
  std::vector<uint32_t> tgp_pc_seq;
  std::map<uint32_t,uint32_t> tgp_prog;
  uint32_t tgp_pc_prev = 0xffffffffu;
  // THE UPLOAD/BOOT CYCLE, as it actually happened.
  //
  // copro_ctl1 bit 31 is a SELECTOR: while set, a write to the FIFO port goes
  // to program RAM at a hardware counter; clear, it pushes the input FIFO. So
  // every write to that port is routed by whatever this register holds, and a
  // missed edge sends a program into the FIFO or a command into program memory.
  // Logging the register alongside the running program-word count shows which.
  std::vector<std::pair<uint32_t,uint32_t>> ctl_log;
  uint32_t ctl_prev = 0xdeadbeefu;
  // The upload stream, written out so it can be diffed against MAME's tap on
  // the same port. Ours is (addr, data) at the point it lands in program RAM.
  FILE *ucf = std::getenv("M2_UCLOG") ? std::fopen(std::getenv("M2_UCLOG"), "w") : nullptr;
  uint64_t uc_n = 0;
  std::vector<uint32_t> popvals, popA, popB, popD, popPC, popOP;
  std::vector<uint32_t> pushvals;
  std::vector<uint32_t> pushpcs;
  struct Disp { uint32_t pc, b, pop; };
  std::vector<Disp> dbg_disp;
  uint32_t pushn_prev = 0;
  uint32_t popn_prev = 0;
  std::map<uint32_t,uint64_t> pop_pc_hist;
  // Sampled EVERY cycle, not at the pop: the destination write-back lands a
  // cycle or more after the FIFO read, so a sample taken at the pop sees the
  // old value and proves nothing.
  uint64_t a_nz = 0, b_nz = 0, d_nz = 0;
  uint32_t a_last = 0, b_last = 0, d_last = 0;
  std::vector<std::pair<uint32_t,uint32_t>> dwrites;
  uint32_t dwn_prev = 0;
  // The drain loop, instruction by instruction, in the same shape as the
  // reference capture so the two can be read side by side.
  std::vector<std::string> loopst;
  uint32_t lpc_prev = 0xffffffffu;
  // UNIMPLEMENTED IS A COMBINATIONAL WIRE, high only in the cycle it decodes.
  // Sampling it once at the end of a run -- which is what this did -- reads
  // zero almost regardless of how often it fires. Count every cycle and keep
  // the first few program counters.
  uint64_t unimpl_n = 0;
  std::vector<uint32_t> unimpl_pc;
  std::vector<uint32_t> outvals;
  uint32_t outn_prev = 0;
  // HOW HARD THE COPROCESSOR IS HOLDING THE CPU. If this is a large fraction of
  // the run the i960 is not doing anything else -- including updating the
  // tilemap, which is what a black screen looks like from the outside.
  uint64_t cpu_held = 0, mem_cyc = 0;
  // THE COPROCESSOR'S BUFFER-RAM WRITES, APPLIED TO THE MEMORY THE CPU READS.
  //
  // The harness used to count these and throw the data away -- `bufw_data` was
  // wired to nothing and `bufw_ack` tied high -- while the CPU reached buffer
  // RAM through the bridge, which maps it into SDRAM at base_buffer. So the two
  // sides were not talking to the same memory at all, the mailbox at dword
  // 0x7FFC could never clear however the coprocessor behaved, and a boot parked
  // at 0x1166c proved nothing. Model2.sv routes these to
  // `GAME_BUFFER + tgp_bufw_addr`; base_buffer here is 0x16d0000, so this is
  // the same arithmetic against the same array.
  struct MboxW { uint64_t cyc; uint32_t addr; uint16_t data; uint32_t pc; };
  std::vector<MboxW> mboxlog;
  uint64_t bufw_applied = 0;
  // THE DISPLAY-LIST COUNT the TGP loops on. 0x47C reads it from BUFFER RAM
  // into $0x4a, 0x47D moves it to d, and 0x481-0x4B5 counts it down; only when
  // it reaches zero does 0x4B4 fall through to the result store at 0x4BC and
  // the mailbox clear at 0x4C4. MAME reads 6, 7, 8, 9, 0x14 here (measured).
  // A wrong count here is a coprocessor that never finishes a command.
  struct DatR { uint32_t addr; uint32_t isbuf; uint32_t data; uint32_t pc; };
  std::vector<DatR> datlog, buflog;
  uint64_t buf_reads_n = 0;
  std::vector<uint32_t> lcounts;
  // THE DISPLAY-LIST POINTER, which is what the count is read relative to.
  // 0x473 `mov rf1, a` pops it from the command FIFO; 0x475 `addd` makes
  // d = $0x69 + a, so the count comes from ROM[a + 0x30]. MAME's sequence is
  // 1057, 1180, 1049, ... -- two interleaved streams walking back by 0xE.
  std::vector<uint32_t> lptrs;
  std::vector<uint32_t> cmdstream;
  struct InitS { uint32_t pc, d, a; };
  std::vector<InitS> initlog;
  uint32_t lc_prev_pc = 0xffff;
  auto tgp_sample = [&]() {
    ++mem_cyc;
    {
      const uint32_t pc = uint32_t(d->obs_tgp_pc);
      if (pc == 0x47e && lc_prev_pc != 0x47e && lcounts.size() < 24)
        lcounts.push_back(uint32_t(d->obs_tgp_d));
      if (pc == 0x475 && lc_prev_pc != 0x475 && lptrs.size() < 30)
        lptrs.push_back(uint32_t(d->obs_tgp_a));
      // THE INIT THAT BUILDS $0x69. 07CF reads the data ROM into d, 07D0 adds
      // a (=0x800000), 07D1 stores it. MAME has d = 0xFF800030 at 07D2. Ours
      // behaves as though $0x69 = 0x800000 -- the ROM's 0x30 lost between the
      // read and the add, which is a read-to-ALU hazard if it is real.
      if (pc >= 0x7cc && pc <= 0x7d6 && pc != lc_prev_pc && initlog.size() < 24)
        initlog.push_back({pc, uint32_t(d->obs_tgp_d), uint32_t(d->obs_tgp_a)});
      lc_prev_pc = pc;
    }
    if (d->obs_bufw_wr) {
      const uint32_t w = 0x16d0000u + uint32_t(d->obs_bufw_waddr);
      if (w < mem.size()) { mem[w] = uint16_t(d->obs_bufw_wdata); ++bufw_applied; }
      // THE WHOLE MAILBOX BLOCK, not just 0x7FFC. 0x4BC writes the result count
      // to dword 0x7FFD and the CPU reads two result dwords at 0x91FFF4 and
      // 0x91FFF8 -- dwords 0x7FFD and 0x7FFE. When the first reads zero the CPU
      // branches at 0x11688 to 0x116B4 and substitutes the constant 0xBDCCCCCD,
      // which is exactly what our command stream pushes where MAME pushes a
      // real value.
      // WIDENED to the whole last 64 dwords of buffer RAM and 200 entries: the
      // CPU reads the query answers at dwords 0x7FFD/0x7FFE as ZERO while the
      // reference gets a flag and a segment index; where our TGP puts them
      // is the question (the handler writes through a running pointer).
      if ((uint32_t(d->obs_bufw_waddr) >> 1) >= 0x07FC0u
          && (uint32_t(d->obs_bufw_waddr) >> 1) <= 0x07FFFu && mboxlog.size() < 200)
        mboxlog.push_back({mem_cyc, uint32_t(d->obs_bufw_waddr),
                           uint16_t(d->obs_bufw_wdata), uint32_t(d->obs_tgp_pc)});
    }
    if (d->obs_copro_stall) ++cpu_held;
    if (uint32_t(d->obs_out_pushed) != outn_prev) {
      outn_prev = uint32_t(d->obs_out_pushed);
      if (outvals.size() < 40) outvals.push_back(uint32_t(d->obs_out_data));
    }
    if (uint32_t(d->obs_copro_in) != pushn_prev) {
      pushn_prev = uint32_t(d->obs_copro_in);
      // THE COMMAND STREAM, in order, to diff against MAME's. dbg_push_data and
      // dbg_in_pushed are written in the same always_ff, so sampling the value
      // when the count moves pairs them correctly.
      if (cmdstream.size() < 200) cmdstream.push_back(uint32_t(d->obs_push_data));
      // R148: WHERE the i960 is when it pushes. MAME pushes from 0x11C08 (the
      // routine at 0x11BD4 loading a struct at g13+0x1c..), 0x178DC/E4 and
      // 0x13C48..0x13DC4. Same PC with different data = wrong memory read;
      // a different PC = the CPU took a different path.
      if (pushpcs.size() < 300) pushpcs.push_back(uint32_t(d->obs_ip));
      // R150: the dispatch at 004c pops into B; B != 0 branches to the command
      // path at 00a1. Ours never reaches 00a1 despite 109 commands arriving.
      // Record the TGP pc at every pop, and B just after, to see where the
      // command actually goes.
      if (dbg_disp.size() < 40) dbg_disp.push_back({uint32_t(d->obs_tgp_pc), uint32_t(d->obs_tgp_b), uint32_t(d->obs_pop_data)});
    }
    // R148: the table-upload loop at 0x1578 stores r14 to (g10)[g12] and MAME
    // counts every one as a FIFO push; ours counts none. Record the bus address
    // the i960 actually emits at that instruction, and at the two neighbours.
    { static std::map<uint32_t, std::map<uint32_t,uint32_t>> st1578;
      uint32_t ip = uint32_t(d->obs_ip);
      if ((ip == 0x1578 || ip == 0x1508 || ip == 0x150c) && d->obs_bus_we) {
        auto &m = st1578[ip]; if (m.size() < 8) m[uint32_t(d->obs_bus_addr)]++;
      }
      g_st1578 = &st1578;
      if (pushvals.size() < 300) pushvals.push_back(uint32_t(d->obs_push_data));
    }
    if (d->obs_tgp_unimpl) {
      ++unimpl_n;
      uint32_t p = uint32_t(d->obs_tgp_pc);
      if (unimpl_pc.empty() || unimpl_pc.back() != p)
        if (unimpl_pc.size() < 12) unimpl_pc.push_back(p);
    }
    {
      uint32_t pc = uint32_t(d->obs_tgp_pc);
      if (pc != lpc_prev) {
        lpc_prev = pc;
        // Skip the first visits: before the i960 sends anything the FIFO is
        // legitimately empty and the loop is meant to spin. What matters is
        // what it does once commands are flowing.
        if (pc >= 0x44 && pc <= 0x4b && d->obs_in_popped > 2000 && loopst.size() < 24) {
          char b[160];
          std::snprintf(b, sizeof b, "%04x  A=%08x B=%08x D=%08x ST=%08x",
                        pc, (unsigned)d->obs_tgp_a, (unsigned)d->obs_tgp_b,
                        (unsigned)d->obs_tgp_d, (unsigned)d->obs_tgp_st);
          loopst.push_back(b);
        }
      }
    }
    if (uint32_t(d->obs_tgp_wr_n) != dwn_prev) {
      dwn_prev = uint32_t(d->obs_tgp_wr_n);
      if (dwrites.size() < 24)
        dwrites.push_back({uint32_t(d->obs_tgp_wr_addr), uint32_t(d->obs_tgp_wr_data)});
    }
    if (d->obs_tgp_a) { ++a_nz; a_last = uint32_t(d->obs_tgp_a); }
    if (d->obs_tgp_b) { ++b_nz; b_last = uint32_t(d->obs_tgp_b); }
    if (d->obs_tgp_d) { ++d_nz; d_last = uint32_t(d->obs_tgp_d); }
    if (uint32_t(d->obs_in_popped) != popn_prev) {
      popn_prev = uint32_t(d->obs_in_popped);
      ++pop_pc_hist[uint32_t(d->obs_tgp_pc)];
      if (popvals.size() < 300) {
        popvals.push_back(uint32_t(d->obs_pop_data));
        popA.push_back(uint32_t(d->obs_tgp_a));
        popB.push_back(uint32_t(d->obs_tgp_b));
        popD.push_back(uint32_t(d->obs_tgp_d));
        popPC.push_back(uint32_t(d->obs_tgp_pc));
        popOP.push_back(uint32_t(d->obs_tgp_op));
      }
    }
    if (ucf && d->obs_uc_we) {
      ++uc_n;
      if (uc_n <= 2100)
        std::fprintf(ucf, "%05llu %04x %08x\n", (unsigned long long)uc_n,
                     (unsigned)d->obs_uc_addr, (unsigned)d->obs_uc_data);
    }
    if (uint32_t(d->obs_copro_ctl) != ctl_prev) {
      ctl_prev = uint32_t(d->obs_copro_ctl);
      if (ctl_log.size() < 40)
        ctl_log.push_back({ctl_prev, uint32_t(d->obs_copro_prog)});
    }
    if (uint32_t(d->obs_tgp_pc) != tgp_pc_prev) {
      tgp_pc_prev = uint32_t(d->obs_tgp_pc);
      if (tgp_pc_seq.size() < 400) tgp_pc_seq.push_back(tgp_pc_prev);
      // LAST sighting, not first. The game uploads the program more than once
      // -- dbg_prog_words is cumulative and counted 2024 where MAME's resident
      // program is 506 non-zero words -- so recording the first opcode at each
      // address compares our EARLY upload against MAME's FINAL one and reports
      // a mismatch that means nothing.
      tgp_prog[tgp_pc_prev] = uint32_t(d->obs_tgp_op);
    }
    ++tgp_pc_hist[uint32_t(d->obs_tgp_pc)];
    if (d->obs_tgp_io_rd) { ++tgp_io_rd_n; ++tgp_io_hist[uint32_t(d->obs_tgp_io_addr)]; }
    // THE RECORD-BASE ARITHMETIC, instruction by instruction: sub_7cb (0x7cb-
    // 0x7d5) computes $0x69/$0x6a, the lookup at 0x487-0x48c adds $0x6a.
    {
      static const uint64_t tr_from = std::getenv("M2_TGPRD_FROM") ? std::strtoull(std::getenv("M2_TGPRD_FROM"), nullptr, 10) : ~0ull;
      static int ntr = 0; static int rt_p = 0;
      const unsigned rpc = d->obs_tgp_rpc;
      if (d->obs_tgp_retire && !rt_p && d->dbg_acc >= tr_from && ntr < 80 &&
          ((rpc >= 0x7cb && rpc <= 0x7d8) || (rpc >= 0x484 && rpc <= 0x48f))) {
        ++ntr;
        std::printf("    TGPX pc=%03x a=%08x d=%08x $69=%08x $6a=%08x\n", rpc,
                    (unsigned)d->obs_tgpx_a, (unsigned)d->obs_tgpx_d, (unsigned)d->obs_tgp_ram69, (unsigned)d->obs_tgp_ram6a);
      }
      rt_p = d->obs_tgp_retire;
    }
    // THE TGP's EXTERNAL DATA READS (port 9: data ROM and buffer RAM), address
    // and data, from M2_TGPRD_FROM on, first 5000: diffable against a Lua tap
    // on the reference's :copro_tgp io space.
    {
      static const uint64_t rd_from = std::getenv("M2_TGPRD_FROM") ? std::strtoull(std::getenv("M2_TGPRD_FROM"), nullptr, 10) : ~0ull;
      static int nrd = 0; static int ack_p = 0;
      if (d->tgp_dat_ack && !ack_p && d->dbg_acc >= rd_from && nrd < 5000) {
        ++nrd;
        std::printf("    TGPRD %s %05x %08x\n", d->tgp_dat_is_buf ? "B" : "D", (unsigned)d->tgp_dat_addr, (unsigned)d->tgp_dat_rdata);
      }
      ack_p = d->tgp_dat_ack;
    }
    if (d->obs_tgp_io_wr)   ++tgp_io_wr_n;
    if (d->obs_tgp_io_ack)  ++tgp_io_ack_n;
    if (d->obs_tgp_ram_req) ++tgp_ram_req_cyc;
    if (d->obs_tgp_fifo_rd) ++tgp_fifo_rd_n;
    if (d->obs_tgp_fifo_wr) ++tgp_fifo_wr_n;
  };
  auto tgp_tick = [&]() {
    d->tgp_tbl_ack = 0;
    if (tbl_left < 0 && d->tgp_tbl_req) {
      tbl_data = rd32(TBL_BASE + (uint32_t(d->tgp_tbl_addr) << 1));
      tbl_left = tgp_lat; ++tbl_reads;
    } else if (tbl_left > 0) --tbl_left;
    else if (tbl_left == 0) {
      d->tgp_tbl_rdata = tbl_data; d->tgp_tbl_ack = 1; tbl_left = -1;
    }
    d->tgp_dat_ack = 0;
    if (dat_left < 0 && d->tgp_dat_req) {
      // THE BASE DEPENDS ON WHICH MEMORY IT IS, as Model2.sv does it:
      // p_addr[9] = (dat_is_buf ? GAME_BUFFER : GAME_COPRO) + {dat_addr, half}.
      // Serving buffer-RAM reads out of the data ROM gave the TGP a garbage
      // display-list count at 0x47C, so it never terminated the loop at
      // 0x481-0x4B5 and never reached the mailbox clear at 0x4C4.
      dat_data = rd32((d->tgp_dat_is_buf ? BUF_BASE : COPRO_BASE)
                      + (uint32_t(d->tgp_dat_addr) << 1));
      // WHERE THE COUNT COMES FROM. 0x47C is `mov (x0+1)(e), $0x4a`; MAME's x0
      // there is ~0x1088/0x11B1, small dword offsets into buffer RAM.
      // EVERY read, with the pc, rather than filtering on 0x47C: the pc probe
      // and the request are not necessarily in the same cycle, and filtering
      // on a guess reported "none captured" while 115,757 reads were happening.
      if (datlog.size() < 20)
        datlog.push_back({uint32_t(d->tgp_dat_addr),
                          uint32_t(d->tgp_dat_is_buf), dat_data,
                          uint32_t(d->obs_tgp_pc)});
      if (d->tgp_dat_is_buf && buflog.size() < 20)
        buflog.push_back({uint32_t(d->tgp_dat_addr), 1, dat_data,
                          uint32_t(d->obs_tgp_pc)});
      if (d->tgp_dat_is_buf) ++buf_reads_n;
      dat_left = tgp_lat; ++dat_reads;
    } else if (dat_left > 0) --dat_left;
    else if (dat_left == 0) {
      d->tgp_dat_rdata = dat_data; d->tgp_dat_ack = 1; dat_left = -1;
    }
  };

  // THREE CLOCKS, ON A 192 MHz BASE, because 48 and 32 do not divide each
  // other. Half-periods are 2, 3 and 4 base steps: clk_mem 48 MHz, clk_vid 32
  // MHz, clk_cpu 24 MHz -- the board's ratios exactly. Driving clk_vid as a
  // simple divide of clk_mem would invent a phase relationship the hardware
  // does not have, which is the whole thing this harness exists to model.
  uint64_t mem_edges = 0, base_t = 0;
  int mem_prev = 0, vid_prev = 0;

  // ce_pix halves clk_vid to the 16 MHz dot clock, as Model2.sv does.
  int ce_tog = 0;

  g_seq_dir = std::getenv("M2_FRAME_SEQ");
  if (const char *fe = std::getenv("M2_FRAME_EVERY")) {
    g_seq_every = std::strtoull(fe, nullptr, 10);
    if (!g_seq_every) g_seq_every = 1;
  }
  const bool real_mem = std::getenv("M2_REALMEM") != nullptr;
  if (const char *fv = std::getenv("M2_FINDVAL"))
    g_findval = uint32_t(std::strtoul(fv, nullptr, 0));
  if (const char *pl = std::getenv("M2_PDLOG")) {
    g_pdlog = std::fopen(pl, "w");
    if (g_pdlog) std::setvbuf(g_pdlog, nullptr, _IOLBF, 0);
  }
  if (const char *tp = std::getenv("M2_TRAP"))
    g_trap_addr = uint32_t(std::strtoul(tp, nullptr, 0));
  if (const char *sa = std::getenv("M2_STATE_ADDR"))
    g_state_addr = uint32_t(std::strtoul(sa, nullptr, 0)) & ~3u;
  if (const char *st2 = std::getenv("M2_STATE_TRACE")) {
    g_state_trace = std::fopen(st2, "w");
    if (g_state_trace) { std::setvbuf(g_state_trace, nullptr, _IOLBF, 0);
                         std::printf("  STATE TRACE -> %s\n", st2); }
  }
  if (const char *fl = std::getenv("M2_FRAME_LIGHT")) {
    g_fr_log = std::fopen(fl, "w");
    if (g_fr_log) std::setvbuf(g_fr_log, nullptr, _IOLBF, 0);
  }
  if (const char *ct = std::getenv("M2_COPRO_TRACE")) {
    g_copro_trace = std::fopen(ct, "w");
    if (!g_copro_trace) std::printf("  COPRO TRACE: cannot open %s\n", ct);
    else { std::setvbuf(g_copro_trace, nullptr, _IOLBF, 0);
           std::printf("  COPRO TRACE -> %s\n", ct); }
  }
  {
    unsigned c = 0xff;
    if (const char *cv = std::getenv("M2_IN0")) c = std::strtoul(cv, nullptr, 16);
    d->cab_in0 = c;
    if (c != 0xff) std::printf("  CABINET in0 = %02x (bit2 clear = TEST held)\n", c);
  }
  int slow_prev = 0;
  int cpu_prev = 0;
  auto base_step = [&]() {
    const int m = int((base_t / 2) & 1);
    const int v = int((base_t / 3) & 1);
    const int c = int((base_t / 4) & 1);
    // FRAME CAPTURE, on the falling edge of ce_pix so the pixel is settled.
    // This is the picture the renderer produces WHILE the CPU is running, which
    // is the configuration that has never been simulated.
    if (v && !vid_prev && ce_tog) {
      if (!d->vid_vb && !d->vid_hb) {
        if (g_px < 10 && g_py < 10) { /* nothing: bounds set below */ }
        if (g_py < FH && g_px < FW) {
          const size_t o = (size_t(g_py) * FW + g_px) * 3;
          g_frame[o+0] = d->vid_r; g_frame[o+1] = d->vid_g; g_frame[o+2] = d->vid_b;
          if (d->vid_r || d->vid_g || d->vid_b) ++g_nonblack;
        }
        ++g_px;
      }
      if (d->vid_hb && !g_hb_p) { g_px = 0; if (!d->vid_vb) ++g_py; }
      if (d->vid_vb && !g_vb_p) {
        ++g_frames_done;
        // R248: one line per frame that drew anything, with its lighting.
        if (g_fr_log && g_fr_poly) {
          std::fprintf(g_fr_log, "f%llu polys=%ld luma_mean=%.1f zero=%ld (%.0f%%) lp=%04x light=(%08x,%08x,%08x)\n",
                       (unsigned long long)g_frames_done, g_fr_poly,
                       (double)g_fr_lsum / g_fr_poly, g_fr_zero,
                       100.0 * g_fr_zero / g_fr_poly, g_fr_lp,
                       (unsigned)d->lit_x_o, (unsigned)d->lit_y_o, (unsigned)d->lit_z_o);
        }
        g_fr_poly = 0; g_fr_lsum = 0; g_fr_zero = 0; g_fr_lp = 0;
        // TILEMAP CONTENT CENSUS, to put beside the board's UART capture. The
      // board fetches only tiles 0, 1, 24576 and 24577 -- blank tiles with two
      // attributes -- so the question is what the SAME code writes here.
      // M2_FRAME_SEQ=dir writes EVERY completed frame, so the render can be
        // watched as a sequence instead of judged from one still. Two of this
        // session's wrong conclusions came from reading a single frame that
        // happened to be captured mid-draw.
        static const uint64_t seq_from = std::getenv("M2_FRAME_FROM") ? std::strtoull(std::getenv("M2_FRAME_FROM"), nullptr, 10) : 0;
        if (g_seq_dir && (g_frames_done % g_seq_every) == 0 && d->dbg_acc >= seq_from) {
          char path[512];
          std::snprintf(path, sizeof path, "%s/f%05llu.ppm", g_seq_dir,
                        (unsigned long long)g_frames_done);
          if (FILE *sf = std::fopen(path, "wb")) {
            std::fprintf(sf, "P6\n%d %d\n255\n", FW, FH);
            std::fwrite(g_frame.data(), 1, g_frame.size(), sf);
            std::fclose(sf);
          }
        }
      }
      if (!d->vid_vb && g_vb_p) { g_py = 0; g_px = 0; }
      g_hb_p = d->vid_hb; g_vb_p = d->vid_vb;
    }
    if (v && !vid_prev) { ce_tog ^= 1; d->ce_pix = ce_tog; }
    // EXPERIMENT (M2_SAMECLK=1): drive the CPU from the memory clock, which
    // collapses the four-phase handshake to a same-domain one. This measures the
    // CEILING for moving the i960 into clk_sys before committing to the refactor:
    // it also doubles the CPU clock, so the clock-enable version -- which keeps
    // 24 MHz -- is worth roughly half of whatever this shows.
    static const bool same_clk = std::getenv("M2_SAMECLK") != nullptr;
    d->clk_mem = m; d->clk_vid = v; d->clk_cpu = same_clk ? m : c;
    d->eval();
    d->clk96 = int(base_t & 1);
    if (real_mem) {
      d->eval();
      if (d->clk_slow_o && !slow_prev) ++mem_edges;   // the stack's own 48 MHz
      slow_prev = d->clk_slow_o;
    } else if (m && !mem_prev) { mem_tick(); sd2_tick(); tgp_tick(); geo_tick(); d->eval(); tgp_sample(); ++mem_edges; }
    if (d->sd2_req) { g_char_words.insert((uint32_t)d->sd2_addr); ++g_char_fetches; }
    // M2_COPRO_TRACE: log the i960's coprocessor bus cycles in the same shape a
    // Lua memory tap produces from the reference, so the two are diffable. The
    // select is a one-cycle pulse in the CPU domain, so one log per rising CPU
    // edge is one transaction -- counting cycles instead would double-count a
    // write the bridge holds.
    // M2_COPRO_FROM=<video frame>: trace only from that frame, so a run long
    // enough to reach the racing attract does not carry hours of boot (R232).
    static const unsigned long long copro_from = std::getenv("M2_COPRO_FROM") ? std::strtoull(std::getenv("M2_COPRO_FROM"), nullptr, 10) : 0;
    if (g_copro_trace && g_frames_done >= copro_from && c && !cpu_prev && d->obs_io_sel) {
      const uint32_t a = d->obs_io_addr;
      char kind = 0;
      uint32_t val = d->obs_io_wdata;
      if (a >= 0x880000 && a <= 0x883fff && d->obs_io_we)      kind = 'F';
      else if (a >= 0x884000 && a <= 0x887fff && d->obs_io_we) kind = 'W';
      // A FIFO read holds io_sel for every cycle it is stalled; log it once,
      // when it completes, or the trace is one line per stall cycle (2.3M
      // 'R 00000000' lines in a 19M-instruction run).
      // A READ THAT STALLS FROM ITS FIRST CYCLE WAS DROPPED HERE: it was
      // logged only on the cycle it started, and skipped when the FIFO was
      // empty then. The horizon routine's 0x0a result (R211/R212) went
      // missing that way. A stalled read is remembered and logged when it
      // completes.
      else if (a >= 0x884000 && a <= 0x887fff)               { if (d->obs_copro_stall) { kind = 0; g_rd_pend = true; } else { kind = 'R'; val = d->obs_io_rdata; } }
      else if (a == 0x980000 && d->obs_io_we)                  kind = 'C';
      if (kind)
        std::fprintf(g_copro_trace, "%c %llu %08x %08x %08x\n", kind,
                     (unsigned long long)g_frames_done, a, val, (unsigned)d->obs_ip);   // the fifth field: the i960's IP (R232)
    }
    // THE ATAN JOB, SCORED (R212). Function 0x0a takes two floats and returns
    // atan2(b, a) in 1/65536 turns. Every completed 0x0a exchange is checked
    // against a C model; the count is reported at the end.
    if (c && !cpu_prev && d->obs_io_sel) {
      const uint32_t a = d->obs_io_addr;
      if (a == 0x8800a0 && d->obs_io_we) { g_at_st = 1; }
      else if (g_at_st >= 1 && g_at_st <= 2 && a == 0x884000 && d->obs_io_we) { g_at_in[g_at_st - 1] = d->obs_io_wdata; ++g_at_st; }
      else if (g_at_st == 3 && a == 0x884000 && !d->obs_io_we) { g_at_st = 4; }
      else if (a >= 0x880000 && a <= 0x883fff && d->obs_io_we) g_at_st = 0;
    }
    if (c && g_at_st == 4 && d->obs_io_sel && !d->obs_copro_stall && !d->obs_io_we && d->obs_io_addr == 0x884000) {
      float fa, fb; std::memcpy(&fa, &g_at_in[0], 4); std::memcpy(&fb, &g_at_in[1], 4);
      const double turns = std::atan2((double)fb, (double)fa) / (2.0 * 3.14159265358979323846);
      const int exp16 = (int)std::lrint(turns * 65536.0);
      const int got = (int16_t)(d->obs_io_rdata & 0xffff);
      int diff = got - exp16; if (diff > 32768) diff -= 65536; if (diff < -32768) diff += 65536;
      ++g_at_n; if (diff < -2 || diff > 2) { ++g_at_bad; if (g_at_bad <= 12) std::printf("    ATAN MISMATCH a=%g b=%g expect %d got %d (insn %llu)\n", fa, fb, exp16, got, (unsigned long long)d->dbg_acc); }
      g_at_st = 0;
    }
    if (g_copro_trace && g_frames_done >= copro_from && g_rd_pend && c) {
      if (!d->obs_io_sel) g_rd_pend = false;
      else if (!d->obs_copro_stall) {
        std::fprintf(g_copro_trace, "R %llu %08x %08x %08x\n", (unsigned long long)g_frames_done,
                     (unsigned)d->obs_io_addr, (unsigned)d->obs_io_rdata, (unsigned)d->obs_ip);
        g_rd_pend = false;
      }
    }
    // 'P' RECORDS: one per POP of the coprocessor's output FIFO, counted from
    // m2_copro's dbg_out_popped, so the result stream is logged where the data
    // leaves the queue and not where the CPU-domain sampling sees it. R232:
    // the 'R' records were one short on 0x0a/0x0f/0x1a and carried duplicates
    // against the reference, which is either the trace or the hardware.
    if (g_copro_trace && g_frames_done >= copro_from) {
      static uint16_t pop_prev = 0;
      const uint16_t pn = (uint16_t)d->obs_copro_out;
      if (pn != pop_prev) {
        std::fprintf(g_copro_trace, "P %llu %08x %08x %08x %u\n", (unsigned long long)g_frames_done,
                     (unsigned)d->obs_io_addr, (unsigned)d->obs_io_rdata, (unsigned)d->obs_ip, (unsigned)(uint16_t)(pn - pop_prev));
        pop_prev = pn;
      }
    }
    // THE STATE BYTE THE BOARD'S TOP-LEVEL LOOP TESTS. The loop at 0x1240 reads
    // 0x0053e5f4 every frame and leaves for 0x228f00 when it changes; the board
    // has never left it. The bench reaches the 3D, so it can say what writes
    // that byte, with what, and when -- which the board cannot be asked without
    // a build.
    if (g_state_trace && d->obs_bus_ack && d->obs_bus_we &&
        (d->obs_bus_addr & ~3u) == g_state_addr) {
      std::fprintf(g_state_trace, "W frame=%llu insn=%llu ip=%08x data=%08x be=%x\n",
                   (unsigned long long)g_frames_done,
                   (unsigned long long)d->dbg_acc, (unsigned)d->dbg_ip,
                   (unsigned)d->obs_bus_wdata, (unsigned)d->obs_bus_be);
    }
    // THE PATH INTO THE GEOMETRY CODE. M2_TRAP=<addr> keeps a ring of the IPs
    // the CPU passed through and dumps it the first time it reaches that
    // address. 0x44a8 has no direct callers in the ROM -- the game gets there
    // through an indirect jump -- so the call site cannot be found by reading
    // the ROM and has to be caught in flight.
    if (g_trap_addr && c && !cpu_prev) {
      const uint32_t ip = d->dbg_ip;
      if (ip != g_ipring_last) {
        g_ipring_last = ip;
        g_ipring[g_ipring_w++ & (IPRING - 1)] = ip;
        if (ip == g_trap_addr && !g_trapped) {
          g_trapped = true;
          std::printf("  TRAP %08x reached at frame %llu, insn %llu. The %d IPs before it:\n",
                      g_trap_addr, (unsigned long long)g_frames_done,
                      (unsigned long long)d->dbg_acc, IPRING - 1);
          for (int k = IPRING - 1; k >= 1; --k)
            std::printf("     -%2d  %08x\n", k, g_ipring[(g_ipring_w - 1 - k) & (IPRING - 1)]);
        }
      }
    }
    // WHERE THE DISPATCH POINTER COMES FROM. 0x44a8 -- the function that calls
    // the matrix builder eight times -- has no direct callers in the ROM, so
    // the game reaches it through a pointer and no call-graph walk can find the
    // gate. A read that RETURNS 0x44a8 names the table entry it was loaded
    // from, which is a thing the board can then be asked about.
    if (g_state_trace && d->obs_bus_ack && g_findval &&
        ((!d->obs_bus_we && d->obs_bus_rdata == g_findval) ||
         ( d->obs_bus_we && d->obs_bus_wdata == g_findval))) {
      static uint32_t last_seen = 0xffffffffu;
      if (d->obs_bus_addr != last_seen) {
        last_seen = d->obs_bus_addr;
        std::fprintf(g_state_trace, "PTR frame=%llu insn=%llu ip=%08x %s [%08x] = %08x\n",
                     (unsigned long long)g_frames_done,
                     (unsigned long long)d->dbg_acc, (unsigned)d->dbg_ip,
                     d->obs_bus_we ? "WR" : "RD", (unsigned)d->obs_bus_addr,
                     (unsigned)(d->obs_bus_we ? d->obs_bus_wdata : d->obs_bus_rdata));
      }
    }
    cpu_prev = c;
    mem_prev = m; vid_prev = v;
    ++base_t;
  };

  // One clk_mem cycle, so the loop below is unchanged.
  auto tick = [&]() { for (int i = 0; i < 4; ++i) base_step(); };

  // REAL MEMORY. The binary decides (built with -GREAL_MEM=1); the tb follows
  // its lead: clk96 toggles every base tick, the memory-edge accounting keys
  // off the stack's exported clk_slow, the C++ SDRAM answers are ignored by
  // the harness, and the ROM image streams through the rl_* port into the
  // DEVICE MODEL after its init -- the loader's role, played at the bench.


  for (int i = 0; i < 64; ++i) tick();
  // THE REAL I/O FIRMWARE, when offered: M2_IOFW names EPR-14869C, and the
  // harness swaps R37-R41's imitation for m2_ioz80 running it. This is the
  // full-duplex composition: real i960 and real Z80, interlocking through the
  // real flag/status protocol -- the instrument the half-duplex replay could
  // not be (its fixed-time replay broke the interlock and the input scan
  // swept the game's settings deposit).
  d->fw_we = 0; d->fw_addr = 0; d->fw_data = 0; d->fw_ready = 0;
  // M2_FWLATE=N defers the firmware load to instruction N, replicating the
  // board's ordering: the MRA's later parts arrive after rom_loaded has
  // released the i960, so the Z80 wakes mid-boot there, not before reset.
  uint64_t fw_late = 0;
  if (const char *fl = std::getenv("M2_FWLATE"))
    fw_late = std::strtoull(fl, nullptr, 10);
  std::vector<uint8_t> fw_pending;
  std::vector<uint8_t> fw_rm;   // real-memory mode: held until clk_slow runs
  // THE I/O FIRMWARE IS NOT OPTIONAL, AND THAT IS WHY IT IS DEFAULTED.
  //
  // Without it the Z80 board never answers the DPRAM handshake and the i960
  // parks at 0x228240 polling 0x01c00040 -- forever. That boot still retires
  // instructions as fast as any other, still prints a full profile, and has
  // executed none of the game: 97.8% of every instruction lands in one 4 KB
  // page of work RAM. It is the most expensive kind of passing-looking run,
  // and it was read once as evidence that the tilemap scroll registers were
  // never written when what it actually measured was a CPU spinning on a
  // handshake nobody had connected.
  //
  // A knob that must be remembered is a knob that will be forgotten, so the
  // firmware defaults to the ROM sitting beside the program ROMs and M2_IOFW
  // only overrides the path. If it is genuinely absent, say so loudly rather
  // than booting into the spin.
  const std::string iofw_def = dir + "epr-14869c.25";
  const char *fp_env = std::getenv("M2_IOFW");
  {
    const char *fp = fp_env ? fp_env : iofw_def.c_str();
    FILE *ff = std::fopen(fp, "rb");
    if (!ff)
      std::printf("  WARNING: no I/O firmware at %s -- the Z80 board is dead and "
                  "the i960 will spin on the 0x01c00040 handshake\n", fp);
    if (ff) {
      std::vector<uint8_t> fwb(16384, 0xff);
      size_t fn = std::fread(fwb.data(), 1, fwb.size(), ff);
      std::fclose(ff);
      // REAL_MEM: the fw ROM's clock is the stack's clk_slow, and that
      // divider is held while rst_n=0 -- a load issued here would strobe a
      // dead clock and write NOTHING (the first composition run proved it:
      // the Z80 woke on an empty ROM and the exchange never began). Hold
      // the bytes; the real-memory block below loads them after reset,
      // with the Z80 still held by fw_ready=0.
      if (fw_late == 0 && real_mem) {
        fw_rm = fwb;
        std::printf("  I/O FIRMWARE held for post-reset load (real memory)\n");
      } else if (fw_late == 0) {
        for (int a = 0; a < 8192; ++a) {
          d->fw_we = 1; d->fw_addr = a;
          d->fw_data = fwb[a*2] | (fwb[a*2+1] << 8); tick();
        }
        d->fw_we = 0; d->fw_ready = 1;
        std::printf("  I/O FIRMWARE loaded: %zu bytes -- the Z80 board is live\n", fn);
      } else {
        fw_pending = fwb;
        std::printf("  I/O FIRMWARE held for late load at insn %llu\n",
                    (unsigned long long)fw_late);
      }
    }
  }
  d->cpu_hold = 0; d->rl_req = 0; d->rl_addr = 0; d->rl_din = 0;
  d->rst_n = 1;
  if (real_mem) {
    // Device init first, then the image, CPU held throughout.
    d->cpu_hold = 1;
    while (!d->mem_ready_o) tick();
    if (!fw_rm.empty()) {
      for (int a = 0; a < 8192; ++a) {
        d->fw_we = 1; d->fw_addr = a;
        d->fw_data = fw_rm[a*2] | (fw_rm[a*2+1] << 8); tick();
      }
      d->fw_we = 0; d->fw_ready = 1;
      std::printf("  I/O FIRMWARE loaded post-reset -- the Z80 board is live\n");
    }
    std::printf("  REAL MEMORY ready; streaming the image...\n");
    uint64_t words = mem_words;   // set below where the image was read
    for (uint64_t w = 1; w <= words; ++w) {
      d->rl_req = 1; d->rl_addr = w; d->rl_din = mem[w];
      do { tick(); } while (!d->rl_ack);
      d->rl_req = 0; tick();
      if ((w % 2000000) == 0)
        std::printf("    ... %llu / %llu words\n",
                    (unsigned long long)w, (unsigned long long)words);
    }
    std::printf("  image streamed; releasing the CPU\n");
    d->cpu_hold = 0;
  }
  if (const char *dl = std::getenv("M2_DPLOG")) g_dplog = std::fopen(dl, "w");

  if (std::getenv("M2_BOOT_TRACE")) {
    for (int i = 0; i < 400; ++i) {
      tick();
      std::printf("    t%-4d req=%d we=%d addr=%07x ack=%d dout=%04x ip=%08x acc=%u trap=%d halt=%d\n",
                  i, d->sd_req, d->sd_we, d->sd_addr, d->sd_ack,
                  unsigned(d->sd_dout & 0xffff), d->dbg_ip, d->dbg_acc,
                  d->cpu_trap, d->cpu_halt);
      if (d->cpu_trap || d->cpu_halt) break;
    }
    return 0;
  }

  // PC STREAM, for tools/i960-resync-diff.py.
  //
  // THE EXISTING DIFF TOOLS CANNOT REACH THIS FAULT. Both drive obj_i960_rom,
  // which has no I/O board, so it stalls forever in the poll loop at 0x228240
  // while MAME walks past it and draws the menu. i960-datadiff.sh accordingly
  // compares two pre-menu states and reports tile, char and palette IDENTICAL
  // -- a true result about the wrong moment. This harness is the one that gets
  // past the poll, because it has the board and the backup SRAM, so the trace
  // has to come from here.
  //
  // One PC per retired instruction, from M2_BOOT_PCFROM onward, which keeps the
  // file to the window around the divergence rather than 1.7 million lines.
  FILE *pctr = nullptr;
  uint64_t pcfrom = 0;
  if (const char *pf = std::getenv("M2_BOOT_PCTRACE")) {
    pctr = std::fopen(pf, "w");
    if (const char *pfr = std::getenv("M2_BOOT_PCFROM"))
      pcfrom = std::strtoull(pfr, nullptr, 10);
  }
  // M2_BOOT_PCFRAME=<video frame>: trace the PCs of that frame and the two
  // after it, so a divergence found in the coprocessor trace at a frame can be
  // read back as instructions without knowing the instruction count (R232).
  const uint64_t pcframe = std::getenv("M2_BOOT_PCFRAME") ? std::strtoull(std::getenv("M2_BOOT_PCFRAME"), nullptr, 10) : ~0ull;
  uint32_t pc_acc_prev = 0;

  // WHERE THE CPU ACTUALLY IS, over the whole run.
  //
  // A boot that renders tiles has clearly reached the main loop, but that says
  // nothing about which per-frame routines it runs. MAME writes the tilemap
  // scroll from 0x1a164 every frame; if this core never executes that address
  // the scroll cannot be anything but zero, and no amount of staring at the
  // video path will show it. M2_BOOT_PCHIT=0x1a164 counts one address; the
  // 4 KB histogram says where the time went, which is the same question asked
  // without having to guess the address first.
  const char *ph = std::getenv("M2_BOOT_PCHIT");
  const uint32_t pchit_addr = ph ? uint32_t(std::strtoul(ph, nullptr, 0)) : 0;
  uint64_t pchit_n = 0, retired = 0;
  std::map<uint32_t,uint64_t> pc_hist;

  // V-blank at 57.52 Hz against a 48 MHz mem clock.
  const uint64_t VBL = uint64_t(48e6 / 57.52);
  uint64_t next_vbl = VBL, vblanks = 0;
  uint64_t first_win_rd = 0;
  FILE *out = outfile ? std::fopen(outfile, "wb") : nullptr;
  uint32_t acc_prev = 0;
  const bool watch_io = std::getenv("M2_BOOT_IO") != nullptr;
  bool ack_prev = false;
  int  n_watch = 0;
  const char *bf = std::getenv("M2_BOOT_BUS");
  const uint32_t bus_from = bf ? uint32_t(std::strtoul(bf, nullptr, 10)) : 0;
  int n_bus = 0;
  const bool watch_char = std::getenv("M2_BOOT_CHAR") != nullptr;
  const char *csf = std::getenv("M2_BOOT_CHARSTREAM");
  FILE *charstream = csf ? std::fopen(csf, "w") : nullptr;
  int n_char = 0;
  uint64_t ldos_n = 0, ldos_bad = 0;
  uint64_t rf_req_cycles = 0, rf_ack_count = 0; uint32_t rf_last_addr = 0;
  uint32_t rf_bad_first = 0, rf_bad_at = 0, rf_bad_ip = 0, rf_bad_pfp = 0;
  std::map<uint32_t,uint32_t> frame_shadow;
  std::map<uint32_t,uint64_t> io_unclaimed;
  uint64_t fill_ok = 0, fill_wrong = 0, fill_unwritten = 0;
  const bool stacktrace = std::getenv("M2_BOOT_STACK") != nullptr;
  int n_stack = 0;
  const char *cf = std::getenv("M2_BOOT_CYC");
  const uint32_t cyc_from = cf ? uint32_t(std::strtoul(cf, nullptr, 10)) : 0;
  int n_cyc = 0;
  const bool frametrace = std::getenv("M2_BOOT_FRAME") != nullptr;
  uint32_t acc_prev2 = 0;

  // WARM BOOT. +warmboot=N runs to N instructions, pulses reset, and runs a
  // second boot to the +insn limit. The backup SRAM arrays have no reset, so
  // boot 2 finds boot 1's settings -- the state every real board boot has and
  // no simulation has ever had. The board's first settings read returns the
  // correct 030300 and the draw still prints spaces; if boot 2 here writes
  // C020 to cell 1129 where boot 1 wrote C033, the warm path is reproduced.
  uint64_t warm_at = 0;
  if (const char *wb = std::getenv("M2_WARMBOOT"))
    warm_at = std::strtoull(wb, nullptr, 10);
  bool warm_done = false;

  // WHERE DO THE CYCLES ACTUALLY GO?
  //
  // The board runs 21.6x slower than the reference and the instruction cache
  // was assumed to be the reason. It is not: modelled against a 4 M instruction
  // trace, 512 B already hits 99.97%, and 8 KB buys 0.03 points for thousands
  // of tag flip-flops. So the stall is not misses, and the next guess should be
  // measured rather than made.
  //
  // This splits CPI in two without touching the RTL: cycles in which the CPU
  // has a bus request outstanding and has not been answered are MEMORY stalls;
  // everything else is the core's own sequencing. Those two numbers point at
  // completely different pieces of work, which is why guessing between them has
  // been expensive.
  uint64_t prof_cycles = 0, prof_waiting = 0, prof_req = 0;
  uint32_t prof_acc0 = d->dbg_acc;
  // LATENCY OR COUNT? Waiting 14.87 cycles per instruction is either a few
  // very slow accesses or many quick ones, and those are opposite fixes: the
  // first is the SDRAM path, the second is a data cache. Counting completed
  // transactions separates them.
  FILE *dtr = nullptr;
  if (const char *dt = std::getenv("M2_DTRACE")) dtr = std::fopen(dt, "w");
  uint64_t prof_txn = 0, prof_txn_wr = 0, prof_wait_wr = 0;
  int prof_ack_prev = 0;
  // WHICH STATE EATS THE 18.5 CYCLES? The sequencer is
  // IDLE,LO,LO_W,HI,HI_W,RDB,IOW,DONE and obs_mstate carries st in bits 2:0.
  // Histogramming it says whether the cost is the ack-fall waits (LO_W/HI_W),
  // the requests themselves (LO/HI, i.e. real SDRAM latency), or the tail.
  // Changing the bridge before knowing this would be a guess.
  uint64_t prof_st[8] = {0,0,0,0,0,0,0,0};
  // WHERE THE CORE'S OWN CYCLES GO. Core sequencing is 10.30 of 17.12 CPI, the
  // largest term in the design, and it has never been broken down.
  uint64_t prof_ts[32] = {0};
  // DOES THE PREFETCH ACTUALLY HIT? A successful one goes T_EXEC -> T_FETCH ->
  // T_EXEC, skipping T_FETCH_W entirely; a miss goes T_FETCH -> T_FETCH_W. The
  // transition out of T_FETCH is therefore the hit rate, and it needs no RTL
  // change to see -- the state is already observable.
  uint64_t pf_hit = 0, pf_miss = 0, pf_len2 = 0;
  uint64_t pf_m_wrong = 0, pf_m_late = 0;
  int ts_prev = -1;
  uint64_t prof_cpu_cycles = 0;
  int pf_match_in_fetch = 0;
  int pf_dump = 0;

  while (d->dbg_acc < max_instr || (warm_at && !warm_done)) {
    if (!fw_pending.empty() && d->dbg_acc >= fw_late) {
      for (int a = 0; a < 8192; ++a) {
        d->fw_we = 1; d->fw_addr = a;
        d->fw_data = fw_pending[a*2] | (fw_pending[a*2+1] << 8); tick();
      }
      d->fw_we = 0; d->fw_ready = 1; fw_pending.clear();
      std::printf("  I/O FIRMWARE late-loaded at insn %u\n", (unsigned)d->dbg_acc);
    }
    if (warm_at && !warm_done && d->dbg_acc >= warm_at) {
      std::printf("  === WARM RESET at insn %u ===\n", (unsigned)d->dbg_acc);
      d->rst_n = 0;
      for (int i = 0; i < 64; ++i) tick();
      d->rst_n = 1;
      warm_done = true;
      g_c3_n = 0; g_sw_n = 0; g_bk_n = 60;   // re-arm the cell log for boot 2
    }
    tick();
    ++prof_cycles;
    if (d->obs_bus_req) {
      ++prof_req;
      if (!d->obs_bus_ack) ++prof_waiting;
    }
    if (d->obs_bus_ack && !prof_ack_prev) {
      ++prof_txn;
      if (d->obs_bus_we) ++prof_txn_wr;
      // DATA ADDRESS TRACE, for modelling a data cache offline before building
      // one. The same method sized the instruction cache and killed that plan
      // for the cost of a text file instead of a Quartus run.
      if (dtr && !d->obs_bus_we) std::fprintf(dtr, "%08x\n", (unsigned)d->obs_bus_addr);
    }
    // A WRITE NEED NOT BLOCK. Reads must: the instruction wants the value.
    // Writes only need to be ordered, so every cycle spent waiting on one is a
    // cycle a posted-write buffer would give back. Counted separately because
    // that is the size of the prize.
    if (d->obs_bus_req && !d->obs_bus_ack && d->obs_bus_we) ++prof_wait_wr;
    prof_ack_prev = d->obs_bus_ack;
    ++prof_st[d->obs_mstate & 7];
    {
      // SAMPLED ON THE CPU'S OWN EDGE, not on clk_mem. The sequencer changes
      // state at clk_cpu, which is half clk_mem, so sampling every tick counted
      // each state twice -- which is why every figure came out an exact
      // multiple of two -- and read pf_ip against an `ip` that had not been
      // updated yet, turning ordinary sequential fetches into "mispredictions".
      // Two different wrong answers from one sampling mistake.
      static int cpu_prev = 0;
      int cpu_now = d->clk_cpu;
      if (cpu_now && !cpu_prev) {
        int t = d->obs_ts & 31;
        // THE THREE WAYS OUT OF T_FETCH, which is the whole story:
        //   -> T_EXEC      the prefetch had the word: no fetch cost at all
        //   -> T_FETCH2_W  a two-word instruction, which by design cannot
        //                  prefetch -- it needs the cache port for its own
        //                  displacement word
        //   -> T_FETCH_W   a real miss, waiting for the cache
        // The first version lumped T_FETCH2_W in with the hits and watched the
        // wrong transition for two-word instructions, reporting 0% of them
        // while T_FETCH2_W was burning 0.83 cycles an instruction.
        if (ts_prev == 0 && t != 0) {
          if      (t == 1) {                   // T_FETCH_W: a real miss
            // pf_match is captured WHILE IN T_FETCH, below. Reading it on the
            // edge that LEAVES the state reads an ip that has already moved to
            // the next instruction, which made every ordinary sequential fetch
            // look like a mispredicted branch -- 87% of them.
            ++pf_miss;
            if (!pf_match_in_fetch) ++pf_m_wrong; else ++pf_m_late;
          }
          else if (t == 3) ++pf_len2;          // T_FETCH2_W: two-word
          else             ++pf_hit;           // straight on: the prefetch paid
        }
        if (t == 0) {
          pf_match_in_fetch = d->obs_pf_match;
          // LOOK AT THE VALUES. Three rounds of reasoning about why pf_ip does
          // not match ip have each been wrong; printing them settles it.
          if (d->dbg_acc > 100000 && pf_dump < 16) {
            std::printf("    T_FETCH: ip=%08x pf_ip=%08x  valid=%d armed=%d icv=%d\n",
                        (unsigned)d->obs_ip, (unsigned)d->obs_pf_ip,
                        d->obs_pf_valid, d->obs_pf_armed, d->obs_ic_valid);
            ++pf_dump;
          }
        }
        ts_prev = t;
        ++prof_ts[t];
        ++prof_cpu_cycles;
      }
      cpu_prev = cpu_now;
    }
    if (d->dbg_acc != pc_acc_prev) {
      const uint32_t ip = uint32_t(d->dbg_ip);
      if (pctr && d->dbg_acc >= pcfrom && (pcframe == ~0ull || (g_frames_done >= pcframe && g_frames_done < pcframe + 3)))
        std::fprintf(pctr, "%08x\n", (unsigned)ip);
      if (pchit_addr && ip == pchit_addr) ++pchit_n;
      ++pc_hist[ip >> 12];
      ++retired;
      pc_acc_prev = d->dbg_acc;
    }
    if (mem_edges >= next_vbl) {
      next_vbl += VBL; ++vblanks;
      d->irq = 0x1;                       // level, cleared below
    } else if (d->irq) {
      static int hold = 0;
      if (++hold > 200) { d->irq = 0; hold = 0; }
    }
    // One line per RETIRED instruction, in the same 8-hex format tools/
    // i960-resync-diff.py reads.
    if (out && d->dbg_acc != acc_prev) {
      std::fprintf(out, "%08x\n", d->dbg_ip);
      acc_prev = d->dbg_acc;
    }

    if (!first_win_rd && d->iob_win_rd) first_win_rd = d->dbg_acc;

    // WHAT THE i960 WAS HANDED, for the accesses the boot is stuck on. The
    // overlay can show what the I/O board returned; only this can show what
    // arrived at the CPU, and the two are separated by the bridge.
    // THE FRAME, AT EVERY CALL AND RETURN IN THE FAILING ROUTINE. A `ret` that
    // lands on 0x00000000 has either restored a frame whose RIP is zero or
    // never saved one; only the frame state distinguishes those.
    if (frametrace && d->dbg_acc != acc_prev2) {
      const uint32_t ip = d->dbg_ip;
      if (ip == 0x0001c66cu || ip == 0x0001c6a0u || ip == 0x0001c690u ||
          ip == 0x0001c928u || ip == 0x0001c670u) {
        std::printf("    i%-9u ip=%08x  rip=%08x pfp=%08x pos=%d spill=%d\n",
                    d->dbg_acc, ip, d->dbg_rip, d->dbg_pfp,
                    int(d->dbg_rcache_pos), d->dbg_to_memory);
      }
      acc_prev2 = d->dbg_acc;
    }

    // CYCLE BY CYCLE ACROSS ONE FETCH. Three explanations for this have now
    // been wrong, all of them reasoned from summaries. This prints the state
    // itself over a bounded window: the transaction is at a known instruction.
    if (cyc_from && d->dbg_acc >= cyc_from && n_cyc < 260) {
      static const char *ST[8] = {"IDLE","LO","LO_W","HI","HI_W","RDB","IOW","DONE"};
      std::printf("      c i%-4u req=%d addr=%08x ack=%d rdata=%08x | "
                  "st=%-4s reqm=%d ackm=%d sdack=%d sdreq=%d sdaddr=%07x\n",
                  d->dbg_acc, d->obs_bus_req, d->obs_bus_addr, d->obs_bus_ack,
                  d->obs_bus_rdata, ST[d->obs_mstate & 7],
                  (d->obs_mstate >> 3) & 1, (d->obs_mstate >> 4) & 1,
                  (d->obs_mstate >> 5) & 1, d->sd_req, d->sd_addr);
      ++n_cyc;
    }

    // WHAT EACH SPILL WROTE, AND WHAT THE MATCHING FILL READ BACK. Addresses
    // and counts already agree; the words themselves are the only thing left
    // that can differ. A shadow of every frame word written, checked on every
    // frame word read, so a mismatch names the address and the two values
    // rather than being inferred from a corrupted PFP three returns later.
    if (d->dbg_rf_ack) {
      const uint32_t a = d->dbg_rf_addr;
      if (d->dbg_rf_we) {
        frame_shadow[a] = d->dbg_rf_wdata;
      } else {
        auto it = frame_shadow.find(a);
        const uint32_t got = d->obs_bus_rdata;
        if (it == frame_shadow.end()) {
          if (fill_unwritten < 4)
            std::printf("    frame fill %08x -> %08x, NOTHING EVER SPILLED THERE"
                        "  (i%u ip %08x)\n", a, got, d->dbg_acc, d->dbg_ip);
          ++fill_unwritten;
        } else if (it->second != got) {
          if (fill_wrong < 4)
            std::printf("    frame fill %08x -> %08x, spill wrote %08x"
                        "  (i%u ip %08x)\n", a, got, it->second,
                        d->dbg_acc, d->dbg_ip);
          ++fill_wrong;
        } else ++fill_ok;
      }
    }

    // DOES THE REGISTER FILE ASK, AND IS IT ANSWERED? Counted rather than
    // printed: a spill is sixteen accesses and what matters is whether the
    // count is zero.
    if (d->dbg_rf_req) {
      ++rf_req_cycles; rf_last_addr = d->dbg_rf_addr;
      // The FIRST spill or fill whose address leaves work RAM. Everything after
      // it is downstream of the same corruption, so only the first is evidence.
      if (!rf_bad_first && (d->dbg_rf_addr < 0x00500000u || d->dbg_rf_addr >= 0x00600000u)) {
        rf_bad_first = d->dbg_rf_addr;
        rf_bad_at    = d->dbg_acc;
        rf_bad_ip    = d->dbg_ip;
        rf_bad_pfp   = d->dbg_pfp;
      }
    }
    if (d->dbg_rf_ack) ++rf_ack_count;

    // THE REGISTER-FRAME SPILL AND FILL. A `ret` whose PFP comes back as
    // 0xffffffff read memory nothing had written, so the question is whether
    // the matching spill wrote at all and to where.
    if (stacktrace && d->obs_bus_ack && !ack_prev
        && (d->obs_bus_addr & 0xffff0000u) == 0x00530000u && n_stack < 100000) {
      if (d->dbg_acc > 15000000u && n_stack < 30)
        std::printf("    stk %08x be=%x %s %08x  (i%u)\n", d->obs_bus_addr,
                  d->obs_bus_be, d->obs_bus_we ? "wr" : "rd",
                  d->obs_bus_we ? d->obs_bus_wdata : d->obs_bus_rdata, d->dbg_acc);
      ++n_stack;
    }

    // THE SOURCE LOAD, which is where g4 comes from. The store address is
    // right and the DATA is one halfword ahead, so the question is what
    // `ldos (g7),g4` at 0001C478 returned and from where.
    // EVERY source load checked against what memory holds, rather than a
    // handful printed and reasoned about. The store address is right and the
    // data is one halfword out, so either the load returns the wrong value or
    // it reads the wrong place -- and this distinguishes them.
    if (d->obs_bus_ack && !ack_prev && !d->obs_bus_we
        && d->dbg_ip == 0x0001c478u) {
      const uint32_t A = d->obs_bus_addr;
      if (A >= 0x02000000u && A < 0x04000000u) {
        const uint32_t word = 0x20000u + ((A - 0x02000000u) >> 1);
        const uint16_t want = mem[word & 0x1ffffff];
        const uint16_t got  = (A & 2) ? uint16_t(d->obs_bus_rdata >> 16)
                                      : uint16_t(d->obs_bus_rdata);
        ++ldos_n;
        if (got != want) {
          if (ldos_bad < 6)
            std::printf("    ldos %08x be=%x got %04x want %04x\n",
                        A, d->obs_bus_be, got, want);
          ++ldos_bad;
        }
      }
    }

    // THE WRITE STREAM, in MAME's own tap format, so the two can be diffed
    // line for line. Comparing finished memory scores ~60% either way on data
    // that is mostly repeated 0x1111, which is how a one-word-shift theory came
    // to be believed on two samples. A stream has no such ambiguity.
    if (charstream && d->obs_bus_ack && !ack_prev && d->obs_bus_we
        && (d->obs_bus_addr & 0xfff80000u) == 0x01080000u) {
      // MAME's mask is per-BYTE-lane expanded to 32 bits; ours is a 4-bit
      // enable, so it is expanded here rather than the comparison being taught
      // about two formats.
      uint32_t mask = 0;
      for (int b = 0; b < 4; ++b) if (d->obs_bus_be & (1u << b)) mask |= 0xffu << (8*b);
      std::fprintf(charstream, "%08x %08x %08x\n",
                   d->obs_bus_addr, d->obs_bus_wdata, mask);
    }

    // I/O WRITES NOTHING CLAIMS. The bridge routes a wide range to T_IO and the
    // mux answers a handful of addresses; everything else reads zero and its
    // writes go nowhere. That is correct for the regions MAME marks nopw and
    // wrong for anything the renderer needs, and the two are indistinguishable
    // until they are counted.
    // WHERE IN THE FRAME DO TILEMAP WRITES LAND?
    //
    // Real hardware updates the tilemap during V-blank, when the renderer is
    // not scanning it. V-blank is 40 lines of 424, so 9.4% of the frame --
    // 78,725 of the 834,492 mem cycles between interrupts. A real i960KB
    // retires roughly four times the instructions we do in that window (our
    // CPI is ~3.95), so work that fits there on the real machine can overrun
    // into active display on ours. If the game clears a tile and then writes
    // the character, and the clear lands in V-blank while the write slips past
    // scanout, the renderer reads the CLEARED tile: blank, not garbage, and
    // only for the characters that are rewritten every frame.
    //
    // That is the last standing explanation for the missing 3 and 1, and this
    // is the measurement that confirms or kills it.
    // WHAT THE DRAW READS BEFORE WRITING THE '3'. The board draws green
    // spaces where the sim draws the digit, so the game printed a blank
    // value there: the INPUT to the print differs. This window catches the
    // loads feeding the value just before the tram write at insn 1769120.
    if (((d->dbg_acc >= 1765330 && d->dbg_acc <= 1765450) ||
         (d->dbg_acc >= 1768950 && d->dbg_acc <= 1769125)) &&
        d->obs_bus_ack && !ack_prev && !d->obs_bus_we && g_src_n < 60) {
      std::printf("      SRC rd %08x -> %08x  (insn %u ip %08x)\n",
                  d->obs_bus_addr, d->obs_bus_rdata,
                  (unsigned)d->dbg_acc, (unsigned)d->dbg_ip);
      ++g_src_n;
    }
    // THE FORMATTED VALUE STRING at 0x53e540: the digit travels settings ->
    // formatter (0x10c4) -> this string -> the draw. The board's blank means
    // the STRING holds spaces; these are its writes.
    if (d->obs_bus_ack && !ack_prev && d->obs_bus_we &&
        d->obs_bus_addr >= 0x0053e540u && d->obs_bus_addr < 0x0053e548u &&
        g_vs_n < 24) {
      std::printf("      VSTR [%08x] <= %08x be=%x (insn %u ip %08x)\n",
                  d->obs_bus_addr, d->obs_bus_wdata, d->obs_bus_be,
                  (unsigned)d->dbg_acc, (unsigned)d->dbg_ip);
      ++g_vs_n;
    }
    // THE '3' CELL, WORD 1129, AND ITS NEIGHBOUR THE 'C' CELL, 1130. Every
    // write, with value and instruction: the digit renders in this harness and
    // not on the board, and the write SEQUENCE is the last place the two can
    // differ.
    if (d->obs_tram_we && (d->obs_oc_addr == 1129 || d->obs_oc_addr == 1130) &&
        g_c3_n < 40) {
      std::printf("      T3 tram[%u] <= %04x  (insn %u ip %08x)\n",
                  (unsigned)d->obs_oc_addr, d->obs_oc_din,
                  (unsigned)d->dbg_acc, (unsigned)d->dbg_ip);
      ++g_c3_n;
    }
    if (d->obs_tram_we) {
      const uint64_t since = mem_edges - (next_vbl - VBL);
      if (since < 78725) ++g_tw_in_vbl; else ++g_tw_out_vbl;
      // STEADY STATE ONLY. The figures above include boot-time bulk drawing,
      // when nothing is displayed and writing outside V-blank is entirely
      // normal. What matters is the per-frame updates once a screen is up.
      if (d->dbg_acc > 2000000) {
        if (since < 78725) ++g_ss_in; else ++g_ss_out;
      }
    }
    // WHICH CODE WRITES THE TILEMAP. The board shows a clear loop at 0001A15C
    // and ONE fill at 0000D0B6 writing tile 0x3000, and nothing else. If the
    // same run here has writers the board never executes, those IPs name the
    // routines that do not run on hardware.
    if (d->obs_tram_we) g_tram_ip[(uint32_t)d->dbg_ip][d->obs_oc_din & 0xffff]++;
    // WHAT THE SAME LOOP READS HERE. The board reads the SAME two addresses
    // every iteration -- 0x511000 -> 80000000 and 0x511008 -> 0 -- which is why
    // a counted loop never ends: it is not advancing. Simulation runs this loop
    // 39 times and leaves, so its read sequence is the answer.
    if (d->obs_bus_ack && !ack_prev && !d->obs_bus_we &&
        d->dbg_ip >= 0x00001718u && d->dbg_ip <= 0x00001754u && g_loopr < 40) {
      std::printf("      LOOPRD ip %08x  addr %08x -> %08x\n",
                  (unsigned)d->dbg_ip, (unsigned)d->obs_bus_addr,
                  (unsigned)d->obs_bus_rdata);
      ++g_loopr;
    }
    // WHO WRITES THE POINTER. Simulation loads 0x00505100 from work RAM
    // 0x501224 and the loop then reads a bound of 0x300 at base+8. The board
    // has 0x00511000 there and reads a bound of ZERO -- which is why its loop
    // misbehaves. The pointer is the fault; this names what puts it there.
    if (d->obs_bus_ack && !ack_prev && d->obs_bus_we &&
        (d->obs_bus_addr & 0xFFFFFFFCu) == 0x00501224u && g_ptrw < 12) {
      std::printf("      PTR 0x501224 <= %08x  be=%x  (insn %u ip %08x)\n",
                  (unsigned)d->obs_bus_wdata, (unsigned)d->obs_bus_be,
                  (unsigned)d->dbg_acc, (unsigned)d->dbg_ip);
      ++g_ptrw;
    }
    // WHO WRITES THE FLAG THE BOARD IS WAITING ON.
    //
    // The board sits in the counted loop at 0x1BA8 polling i960 0x511008 --
    // SDRAM word 0x1608804 -- for a non-zero value that never arrives. The loop
    // is a legitimate wait; the bug is whatever should set that flag. This runs
    // where it DOES work, so it names the writer instead of guessing at one.
    if (d->obs_bus_ack && !ack_prev && d->obs_bus_we &&
        (d->obs_bus_addr & 0xFFFFFFFCu) == 0x00511008u && g_flagw < 12) {
      std::printf("      FLAG 0x511008 <= %08x  be=%x  (insn %u ip %08x)\n",
                  (unsigned)d->obs_bus_wdata, (unsigned)d->obs_bus_be,
                  (unsigned)d->dbg_acc, (unsigned)d->dbg_ip);
      ++g_flagw;
    }
    // THE SAME PROFILE THE BOARD NOW TAKES, so the two histograms compare.
    // Sampling the IP on a free-running divider rather than per instruction
    // matches what hardware can afford and keeps the populations comparable.
    if ((mem_edges & 0xFFFF) == 0) g_prof[(uint32_t)d->dbg_ip & 0xFFFFFF00]++;
    // THE CALL PATH INTO THE BACKGROUND DRAWER. 00018EA4 writes 23,769 tiles
    // here and NEVER executes on the board, which runs only the per-frame
    // scroll update. Whatever gates it is the fault, so record the instruction
    // stream leading to its first write.
    if (d->obs_tram_we && (uint32_t)d->dbg_ip == 0x00018EA4 && !g_draw_seen) {
      g_draw_seen = true;
      g_draw_insn = (uint64_t)d->dbg_acc;
      std::printf("      BACKGROUND DRAWER first write at insn %llu\n",
                  (unsigned long long)g_draw_insn);
    }
    if (d->obs_tram_we && d->obs_oc_addr < 32768) {
      g_tram[d->obs_oc_addr]      = d->obs_oc_din;
      g_tram_seen[d->obs_oc_addr] = true;
    }
    // THE BUS AROUND THE STORE THAT DESTROYS THE WHITE. IP 00002784 writes
    // whatever its source holds; if the source reads zero, the loop copies zero
    // faithfully and the fault is upstream of the palette entirely.
    if (d->dbg_acc >= 1713540 && d->dbg_acc <= 1713600 &&
        d->obs_bus_ack && !ack_prev && g_win < 60) {
      std::printf("      [%u] ip %08x  %s %08x %08x\n",
                  (unsigned)d->dbg_acc, (unsigned)d->dbg_ip,
                  d->obs_bus_we ? "WR" : "rd",
                  d->obs_bus_addr,
                  d->obs_bus_we ? d->obs_bus_wdata : d->obs_bus_rdata);
      ++g_win;
    }
    // EVERY WRITE TO ENTRY 1, which is white in the reference and black here.
    if (d->obs_pal_we && d->obs_oc_addr == 1 && g_e1n < 24) {
      std::printf("    pal[1] <= %04x   (bus %08x be=%x, instruction %u, ip %08x)\n",
                  d->obs_oc_din, d->obs_bus_addr, d->obs_bus_be,
                  (unsigned)d->dbg_acc, (unsigned)d->dbg_ip);
      ++g_e1n;
    }
    if (d->obs_pal_we && d->obs_oc_addr == 0 && g_e0n < 8) {
      std::printf("    pal[0] <= %04x   (bus %08x be=%x)\n",
                  d->obs_oc_din, d->obs_bus_addr, d->obs_bus_be);
      ++g_e0n;
    }
    if (d->obs_pal_we && d->obs_oc_addr < 8192) {
      g_pal[d->obs_oc_addr]      = d->obs_oc_din;
      g_pal_seen[d->obs_oc_addr] = true;
    }
    if (d->obs_xlat_we && d->obs_xlat_addr < 96) {
      g_xlat[d->obs_xlat_addr]      = d->obs_xlat_din;
      g_xlat_seen[d->obs_xlat_addr] = true;
    }
    // READS THAT COME BACK AS ZERO BECAUSE NOTHING BACKS THEM. Writes to an
    // unimplemented region are merely lost; reads are worse, because the game
    // acts on the value. MAME declares several regions here as plain .ram()
    // that this core routes to a stub -- bufferram at 0x00900000 (128 KB),
    // CPU control at 0x00e00000, the comm share at 0x01a00000 -- and the
    // colorxlat region is 48 KB where only 96 entries are stored.
    // WHO WRITES THE SETTINGS DWORD, AND WHEN. The digits are printed from
    // backup byte 0x14 (read at ip 229c64, insn 1769032). Log every write to
    // bytes 0x10-0x17 with value and instruction, so the board's reading of
    // that dword can be matched against the exact write that should have
    // produced it.
    if (d->obs_bus_ack && !ack_prev && d->obs_bus_we &&
        d->obs_bus_addr >= 0x01d00010u && d->obs_bus_addr < 0x01d00018u &&
        g_sw_n < 120) {
      std::printf("      SET WR %08x be=%x %08x  (insn %u ip %08x)\n",
                  d->obs_bus_addr, d->obs_bus_be, d->obs_bus_wdata,
                  (unsigned)d->dbg_acc, (unsigned)d->dbg_ip);
      ++g_sw_n;
      // THE RACE'S FINGERPRINT (R63): a settings copy-back carrying the
      // firmware's input-scan bytes instead of digits. 7f and ff are the
      // scan pattern; real settings bytes here are small BCD-ish values.
      {
        const uint8_t b = uint8_t(d->obs_bus_wdata & 0xff);
        if (b == 0x7f || b == 0xff) g_set_contam = true;
      }
    }
    // EVERY read of the settings dword, numbered -- the board capture's
    // reference sequence.
    if (d->obs_bus_ack && !ack_prev && !d->obs_bus_we &&
        d->obs_bus_addr >= 0x01d00014u && d->obs_bus_addr < 0x01d00018u &&
        g_r5_n < 60) {
      std::printf("      RD5 #%d addr %08x -> %08x  (insn %u ip %08x)\n",
                  g_r5_n, d->obs_bus_addr, d->obs_bus_rdata,
                  (unsigned)d->dbg_acc, (unsigned)d->dbg_ip);
      ++g_r5_n;
    }
    // BACKUP SRAM SETTINGS WINDOW. The menu's missing digits are the credit
    // and coin settings, which live here; the byte-walking loop at ip 0x5250
    // reads them out. Log every access to the window so our contents can be
    // diffed against MAME's backup1 at the same point in the program.
    if (d->obs_bus_ack && !ack_prev &&
        d->obs_bus_addr >= 0x01d001f0u && d->obs_bus_addr < 0x01d00260u &&
        g_bk_n < 80) {
      std::printf("      BK %s %08x be=%x %08x  (insn %u ip %08x)\n",
                  d->obs_bus_we ? "WR" : "rd", d->obs_bus_addr, d->obs_bus_be,
                  d->obs_bus_we ? d->obs_bus_wdata : d->obs_bus_rdata,
                  (unsigned)d->dbg_acc, (unsigned)d->dbg_ip);
      ++g_bk_n;
    }
    if (d->obs_bus_ack && !ack_prev && !d->obs_bus_we) {
      const uint32_t a = d->obs_bus_addr;
      const bool backed =
           (a <  0x00200000u)                            // program ROM
        || (a >= 0x00500000u && a <  0x00600000u)        // work RAM
        || (a >= 0x01000000u && a <  0x01020000u)        // tile RAM
        || (a >= 0x01080000u && a <  0x01100000u)        // char RAM
        || (a >= 0x01800000u && a <  0x01804000u)        // palette
        || (a >= 0x01c00000u && a <  0x01c01000u)        // I/O board
        || (a >= 0x01d00000u && a <  0x01d04000u)        // backup SRAM
        || (a >= 0x02000000u && a <  0x04000000u)        // main_data
        || (a >= 0x06000000u && a <  0x07000000u)        // main_data alias
        || (a >= 0x00220000u && a <  0x00240000u);       // ROM mirror
      if (!backed) g_rd_unbacked[a & 0xffff0000u]++;
    }
    // A SHADOW OF WORK RAM, CHECKED ON EVERY CPU READ. The real-memory
    // composition trapped at insn 17.5M with a register frame filled from ROM
    // address 0x140: the frame pointer had been corrupted, which means a frame
    // read back from work RAM through the real controller was wrong. This names
    // the FIRST wrong read rather than the crash it eventually causes. Bytes
    // never written by the CPU are not compared (ROM-initialised state, the
    // TGP's and the loader's writes are not on this bus).
    // THE FIRST POLYGONS THE ENGINE EMITS, in view space, with the focus and
    // the matrix corners in force. Printed as floats.
    {
      static int npoly = 0; static int pv_prev = 0;
      auto F = [](uint32_t u) { float f; std::memcpy(&f, &u, 4); return double(f); };
      // Gated past the boot: the first 16 the engine emits are read out of
      // unwritten polygon RAM at instruction ~48,900 -- attr 0xFFFFFFFF, every
      // vertex NaN -- and they are what saturates dbg_nonfinite and dbg_capped.
      static const uint64_t poly_from = std::getenv("M2_POLY_FROM") ? std::strtoull(std::getenv("M2_POLY_FROM"), nullptr, 10) : 0;
      if (d->obs_poly_valid && !pv_prev && npoly < 24 && d->dbg_acc >= poly_from) {
        ++npoly;
        std::printf("    POLY %2d i%-9llu attr %08x foc (%g,%g) mtx0 %g mtx4 %g mtx8 %g mtx11 %g\n"
                    "         v0 (%g,%g,%g) v1 (%g,%g,%g) v2 (%g,%g,%g) v3 (%g,%g,%g)\n",
                    npoly, (unsigned long long)d->dbg_acc, (unsigned)d->obs_poly_attr,
                    F(d->obs_foc_x), F(d->obs_foc_y), F(d->obs_mtx0), F(d->obs_mtx4), F(d->obs_mtx8), F(d->obs_mtx11),
                    F(d->obs_v0x), F(d->obs_v0y), F(d->obs_v0z), F(d->obs_v1x), F(d->obs_v1y), F(d->obs_v1z),
                    F(d->obs_v2x), F(d->obs_v2y), F(d->obs_v2z), F(d->obs_v3x), F(d->obs_v3y), F(d->obs_v3z));
      }
      pv_prev = d->obs_poly_valid;
      // The points entering the transform, with the matrix in force, for the
      // first polygons: enough to redo v' = M v + T in Python.
      static int nxf = 0; static int xv_prev = 0;
      if (d->obs_xf_valid && !xv_prev && nxf < 8 && d->dbg_acc >= poly_from) {
        ++nxf;
        std::printf("    XFIN %d i%llu p (%g,%g,%g) M [", nxf, (unsigned long long)d->dbg_acc, F(d->obs_xf_x), F(d->obs_xf_y), F(d->obs_xf_z));
        for (int k = 0; k < 12; k++) std::printf("%g%s", F(d->obs_mtx[k]), k < 11 ? " " : "]\n");
      }
      xv_prev = d->obs_xf_valid;
    }
    // THE MAILBOX QUERY, as the CPU sees it: the arm (write to 0x91fff0) and
    // the answers (reads of 0x91fff4/0x91fff8), to compare with the reference.
    if (d->obs_bus_ack && !ack_prev) {
      const uint32_t ma = d->obs_bus_addr;
      static int nmb = 0;
      if (ma >= 0x0091fff0u && ma < 0x0091fffcu && nmb < 400) {
        if (d->obs_bus_we && ma == 0x0091fff0u) { ++nmb; std::printf("    MBOX A f%llu %08x i%llu pc=%08x\n", (unsigned long long)g_frames_done, (unsigned)d->obs_bus_wdata, (unsigned long long)d->dbg_acc, (unsigned)d->dbg_ip); }
        else if (!d->obs_bus_we && ma != 0x0091fff0u) { ++nmb; std::printf("    MBOX R %08x %08x f%llu pc=%08x\n", ma, (unsigned)d->obs_bus_rdata, (unsigned long long)g_frames_done, (unsigned)d->dbg_ip); }
      }
    }
    if (d->obs_bus_ack && !ack_prev) {
      static std::vector<uint32_t> shadow(1u << 18, 0);
      static std::vector<uint8_t>  shadow_ok(1u << 18, 0);
      const uint32_t a = d->obs_bus_addr;
      // ROM READS AGAINST THE IMAGE. 0x000000-0x1fffff is program ROM at
      // word 0; 0x220000-0x23ffff is model2o's mirror of its second 128 KB
      // (the bridge maps it so); 0x200000-0x21ffff is board RAM, skipped.
      // Full-word reads only: the plain bench shows halfword (be=c) reads
      // presented in the other lane, so partial reads are the checker's blind
      // spot, not the memory's.
      if (!d->obs_bus_we && (d->obs_bus_be & 15) == 15 && (a < 0x00200000u || (a >= 0x00220000u && a < 0x00240000u))) {
        const uint32_t byte = (a < 0x00200000u) ? a : (0x20000u + (a - 0x00220000u));
        const uint32_t w = byte >> 1;
        const uint32_t exp = uint32_t(mem[w]) | (uint32_t(mem[w + 1]) << 16);
        const unsigned be = d->obs_bus_be & 15;
        uint32_t mask = 0;
        for (int b = 0; b < 4; ++b) if (be & (1u << b)) mask |= 0xffu << (8*b);
        if ((d->obs_bus_rdata & mask) != (exp & mask)) {
          ++g_shadow_rom_bad;
          if (g_shadow_rom_bad <= 16)
            std::printf("    ROM MISMATCH %08x be=%x read %08x, image %08x  (insn %llu ip %08x)\n",
                        a, be, (unsigned)d->obs_bus_rdata, exp,
                        (unsigned long long)d->dbg_acc, (unsigned)d->dbg_ip);
        } else ++g_shadow_rom_ok;
      }
      if (a >= 0x00500000u && a < 0x00600000u) {
        const uint32_t i = (a - 0x00500000u) >> 2;
        const unsigned be = d->obs_bus_be & 15;
        if (d->obs_bus_we) {
          uint32_t v = shadow[i], w = d->obs_bus_wdata;
          for (int b = 0; b < 4; ++b) if (be & (1u << b)) {
            v = (v & ~(0xffu << (8*b))) | (w & (0xffu << (8*b)));
          }
          shadow[i] = v; shadow_ok[i] |= be;
        } else if ((shadow_ok[i] & be) == be) {
          uint32_t mask = 0;
          for (int b = 0; b < 4; ++b) if (be & (1u << b)) mask |= 0xffu << (8*b);
          if ((d->obs_bus_rdata & mask) != (shadow[i] & mask)) {
            ++g_shadow_bad;
            if (g_shadow_bad <= 16)
              std::printf("    SHADOW MISMATCH %08x be=%x read %08x, last written %08x  (insn %llu ip %08x)\n",
                          a, be, (unsigned)d->obs_bus_rdata, shadow[i],
                          (unsigned long long)d->dbg_acc, (unsigned)d->dbg_ip);
          } else ++g_shadow_ok;
        }
      }
      BusEv &e = g_ring[g_ring_n++ & 63];
      e.addr = d->obs_bus_addr;
      e.we   = d->obs_bus_we; e.be = d->obs_bus_be;
      e.data = d->obs_bus_we ? d->obs_bus_wdata : d->obs_bus_rdata;
      e.insn = (uint32_t)d->dbg_acc;
    }
    if ((d->cpu_trap || d->cpu_halt) && !g_ring_dumped) {
      g_ring_dumped = true;
      std::printf("  FLIGHT RECORDER at first trap/halt (insn %u, ip %08x):\n",
                  (unsigned)d->dbg_acc, (unsigned)d->dbg_ip);
      const unsigned n = g_ring_n < 64 ? g_ring_n : 64;
      for (unsigned i = 0; i < n; ++i) {
        const BusEv &e = g_ring[(g_ring_n - n + i) & 63];
        std::printf("    %s %08x be=%x %08x  insn %u\n",
                    e.we ? "W" : "R", e.addr, e.be, e.data, e.insn);
      }
    }
    // WHO WRITES THE INTERRUPT TABLE POINTER, AND WHEN. The crash read
    // PRCB+20 (0x53f414) as zero mid-run; this names every write that lands
    // in PRCB[0x10..0x1f] so the fill can be placed against the interrupt.
    if (d->obs_bus_ack && !ack_prev && d->obs_bus_we &&
        d->obs_bus_addr >= 0x0053f410u && d->obs_bus_addr < 0x0053f420u) {
      static int pn = 0;
      if (pn < 20) {
        std::printf("      PRCB WR %08x be=%x %08x  (insn %u ip %08x)\n",
                    d->obs_bus_addr, d->obs_bus_be, d->obs_bus_wdata,
                    (unsigned)d->dbg_acc, (unsigned)d->dbg_ip);
        ++pn;
      }
    }
    if (g_dplog && d->obs_bus_ack && !ack_prev &&
        d->obs_bus_addr >= 0x01c00000u && d->obs_bus_addr < 0x01c01000u) {
      std::fprintf(g_dplog, "%c %03x %02x %u\n",
                   d->obs_bus_we ? 'W' : 'R',
                   (d->obs_bus_addr - 0x01c00000u) >> 1,
                   d->obs_bus_we ? (d->obs_bus_wdata & 0xff)
                                 : ((d->obs_bus_rdata
                                     >> (8 * (d->obs_bus_addr & 3))) & 0xff),
                   (unsigned)d->dbg_acc);
    }
    if (d->obs_bus_ack && !ack_prev && d->obs_bus_we) {
      const uint32_t a = d->obs_bus_addr;
      const bool claimed =
           (a >= 0x01000000u && a <  0x01020000u)   // tile RAM
        || (a >= 0x01080000u && a <  0x01100000u)   // char RAM
        || (a >= 0x01800000u && a <  0x01804000u)   // palette
        || (a >= 0x01810000u && a <  0x0181c000u)   // colorxlat
        || (a >= 0x01c00000u && a <  0x01c01000u)   // I/O board
        || (a >= 0x01d00000u && a <  0x01d04000u)   // backup SRAM
        || (a <  0x00600000u)                       // ROM, board and work RAM
        || (a >= 0x02000000u && a <  0x04000000u);  // main_data
      if (!claimed) ++io_unclaimed[a & 0xffffff00u];
    }

    // WHAT THE CPU PUTS ON THE BUS FOR CHAR RAM. The bridge issues equal
    // numbers of even and odd 16-bit writes, so the halves are both being
    // sent; the odd ones are arriving as zero. This shows the 32-bit word and
    // byte enables the i960 presented, which is the only place that can come
    // from.
    if (watch_char && d->obs_bus_ack && !ack_prev && d->obs_bus_we
        && (d->obs_bus_addr & 0xfff80000u) == 0x01080000u && d->obs_bus_wdata && n_char < 16) {
      std::printf("    char wr %08x be=%x data=%08x  from IP %08x\n",
                  d->obs_bus_addr, d->obs_bus_be, d->obs_bus_wdata, d->dbg_ip);
      ++n_char;
    }

    // THE COPY LOOP'S OWN BUS TRAFFIC. ldq/stq are 16-byte accesses, which the
    // i960 issues as four back-to-back 32-bit ones with bus_req HELD and the
    // address moving on the acknowledge -- study R34. That is the pattern the
    // bridge finds hardest and the one nothing else exercises.
    if (bus_from && d->dbg_acc >= bus_from && d->obs_bus_ack && !ack_prev
        && (d->obs_bus_addr & 0xfff00000u) != 0x01000000u && n_bus < 40) {
      std::printf("    i%-4u %08x be=%x %s %08x\n", d->dbg_acc,
                  d->obs_bus_addr, d->obs_bus_be,
                  d->obs_bus_we ? "wr" : "rd",
                  d->obs_bus_we ? d->obs_bus_wdata : d->obs_bus_rdata);
      ++n_bus;
    }

    if (watch_io && d->obs_bus_ack && !ack_prev &&
        (d->obs_bus_addr & 0xfffffff0u) == 0x01c00040u && n_watch < 12) {
      std::printf("    bus %08x be=%x %s -> %08x\n", d->obs_bus_addr,
                  d->obs_bus_be, d->obs_bus_we ? "wr" : "rd", d->obs_bus_rdata);
      ++n_watch;
    }
    ack_prev = d->obs_bus_ack;
    if (d->cpu_trap || d->cpu_halt) break;
  }

  std::printf("  ran %u instructions, %llu V-blanks, IP %08x%s%s\n",
              d->dbg_acc, (unsigned long long)vblanks, d->dbg_ip,
              d->cpu_trap ? "  TRAPPED" : "", d->cpu_halt ? "  HALTED" : "");
  std::printf("  I/O board: %08x   flag reads %u, seen %04x\n",
              d->iob_dbg, d->iob_flag_rd, d->iob_seen);
  std::printf("  window reads %u, backup writes %u, backup dword0 %08x\n",
              d->iob_win_rd, d->bak_writes, d->bak_w0);
  if (!g_char_words.empty()) {
    const uint32_t lo = *g_char_words.begin(), hi = *g_char_words.rbegin();
    std::printf("  CHARACTER WORKING SET: %zu distinct words of %llu fetches\n"
                "    address span %08x..%08x = %u words (%.1f KB contiguous)\n"
                "    touched %.1f KB; redundancy %.0fx\n",
                g_char_words.size(), (unsigned long long)g_char_fetches,
                lo, hi, hi - lo + 1, (hi - lo + 1) * 4.0 / 1024.0,
                g_char_words.size() * 4.0 / 1024.0,
                double(g_char_fetches) / double(g_char_words.size()));
  }
  std::printf("  LINE OVERRUNS: %u   worst-line fetches: %u\n",
              (unsigned)d->dbg_overruns_o, (unsigned)d->dbg_fetches_o);
  std::printf("  DPRAM WINDOW: game %u accesses, Z80 %u writes, COLLISIONS %u\n",
              (unsigned)d->dbg_win_game_o, (unsigned)d->dbg_win_z80_o,
              (unsigned)d->dbg_collide_o);
  std::printf("  tile RAM writes %u\n", d->dbg_tram_wr);
  {
    // TILE RAM AS THE CPU BUILDS IT, against the captured frame. The board
    // renders that capture pixel-perfectly and puts its content on LAYER 0,
    // while the live game reports layers 2 and 3. Same screen must not land on
    // different layers, so either the CPU writes elsewhere or the bridge does.
    const char *dir = std::getenv("M2_PAL_REF");
    int seen = 0; for (int i = 0; i < 32768; ++i) if (g_tram_seen[i]) ++seen;
    {
    const uint64_t t = g_tw_in_vbl + g_tw_out_vbl;
    std::printf("  tilemap writes: %llu in V-blank, %llu during active display"
                " (%.1f%% unsafe)\n",
                (unsigned long long)g_tw_in_vbl, (unsigned long long)g_tw_out_vbl,
                t ? 100.0 * double(g_tw_out_vbl) / double(t) : 0.0);
    const uint64_t u = g_ss_in + g_ss_out;
    std::printf("    steady state (after 2M instructions): %llu in V-blank, "
                "%llu active (%.1f%% unsafe)\n",
                (unsigned long long)g_ss_in, (unsigned long long)g_ss_out,
                u ? 100.0 * double(g_ss_out) / double(u) : 0.0);
  }
  // WHAT TILE INDICES THE MAP ACTUALLY NAMES. The board fetches only tiles 0,
  // 1, 24576 and 24577 -- blank tiles wearing two attributes -- which is two
  // flat colours. This says what the same code produces here, so the two can
  // be compared as populations rather than as single cells.
  {
    std::map<uint16_t,int> idx_hist, attr_hist;
    int nonblank = 0;
    for (int i = 0; i < 32768; ++i) {
      const uint16_t w = g_tram[i];
      if (!w) continue;
      ++nonblank;
      idx_hist[w & 0x3FFF]++;
      attr_hist[uint16_t(w >> 14)]++;
    }
  {
    std::printf("  IP PROFILE (256-byte buckets, top 12):\n");
    std::vector<std::pair<int,uint32_t>> v;
    for (auto &kv : g_prof) v.push_back({kv.second, kv.first});
    std::sort(v.rbegin(), v.rend());
    int tot = 0; for (auto &p2 : v) tot += p2.first;
    for (size_t i = 0; i < v.size() && i < 12; ++i)
      std::printf("    %08x  %6d  %5.1f%%\n", v[i].second, v[i].first,
                  100.0 * v[i].first / (tot ? tot : 1));
  }
  {
    std::printf("  TILEMAP WRITERS (ip -> writes, distinct values):\n");
    std::vector<std::pair<int,uint32_t>> v;
    for (auto &kv : g_tram_ip) {
      int n = 0; for (auto &d : kv.second) n += d.second;
      v.push_back({n, kv.first});
    }
    std::sort(v.rbegin(), v.rend());
    for (size_t i = 0; i < v.size() && i < 12; ++i) {
      auto &m = g_tram_ip[v[i].second];
      std::printf("    ip %08x  %7d writes, %3zu distinct values, top:",
                  v[i].second, v[i].first, m.size());
      std::vector<std::pair<int,uint16_t>> d;
      for (auto &kv : m) d.push_back({kv.second, kv.first});
      std::sort(d.rbegin(), d.rend());
      for (size_t j = 0; j < d.size() && j < 3; ++j)
        std::printf(" %04x(x%d)", d[j].second, d[j].first);
      std::printf("\n");
    }
  }
    std::printf("  TILEMAP CENSUS: %d non-zero cells, %zu distinct indices, "
                "%zu distinct attributes\n",
                nonblank, idx_hist.size(), attr_hist.size());
    std::printf("    most common indices:");
    std::vector<std::pair<int,uint16_t>> v;
    for (auto &kv : idx_hist) v.push_back({kv.second, kv.first});
    std::sort(v.rbegin(), v.rend());
    for (size_t i = 0; i < v.size() && i < 6; ++i)
      std::printf(" %u(x%d)", v[i].second, v[i].first);
    std::printf("\n");
  }
  std::printf("  tile RAM as the CPU builds it: %d/32768 words written\n", seen);
    // Which quarter of tile RAM did it touch? The four layers occupy distinct
    // regions, so this says which layers the CPU believes it is drawing on.
    for (int q = 0; q < 4; ++q) {
      int n = 0, nz = 0;
      for (int i = q*8192; i < (q+1)*8192; ++i) {
        if (g_tram_seen[i]) ++n;
        if (g_tram_seen[i] && g_tram[i] != 0) ++nz;
      }
      std::printf("    words %5d-%5d: %5d written, %5d non-zero\n",
                  q*8192, (q+1)*8192-1, n, nz);
    }
    if (dir) {
      std::string path = std::string(dir) + "/tile.bin";
      FILE *f = std::fopen(path.c_str(), "rb");
      if (f) {
        std::vector<uint16_t> ref(32768, 0);
        size_t got = std::fread(ref.data(), 2, 32768, f);
        std::fclose(f);
        for (int q = 0; q < 4; ++q) {
          int nz = 0;
          for (size_t i = q*8192; i < (q+1)*8192 && i < got; ++i) if (ref[i]) ++nz;
          std::printf("    reference words %5d-%5d: %5d non-zero\n",
                      q*8192, (q+1)*8192-1, nz);
        }
      }
    }
    // DUMP WHAT THIS CPU BUILT, so it can be rendered by test_m2_video_frame.
    // The existing fixture is MAME's state; this is OURS. If the renderer draws
    // MAME's correctly and ours with labels missing, the fault is in the data
    // the CPU produces and the diff says exactly where.
    if (const char *od = std::getenv("M2_DUMP_OUT")) {
      auto put = [&](const char *nm, const void *p, size_t n) {
        std::string q = std::string(od) + "/" + nm;
        FILE *g = std::fopen(q.c_str(), "wb");
        if (g) { std::fwrite(p, 1, n, g); std::fclose(g);
                 std::printf("    wrote %s (%zu bytes)\n", q.c_str(), n); }
      };
      put("tile.bin", g_tram, sizeof(g_tram));
      put("palette.bin", g_pal, sizeof(g_pal));
      uint16_t xl[24576];
      std::memset(xl, 0, sizeof(xl));
      for (int c = 0; c < 3; ++c)
        for (int i = 0; i < 32; ++i)
          xl[(c == 0 ? 0x40 : c == 1 ? 0x2040 : 0x4040) + (i << 8)] = g_xlat[c*32 + i];
      put("colorxlat.bin", xl, sizeof(xl));
    }
    int lo = 0, hi = 0;
    for (int i = 0; i < 4096; ++i) if (g_pal_seen[i]) ++lo;
    for (int i = 4096; i < 8192; ++i) if (g_pal_seen[i]) ++hi;
    std::printf("  palette as the CPU builds it: %d/4096 low entries, %d/4096 high\n", lo, hi);
    // Compare against the captured frame if it is to hand. That image renders
    // white labels correctly through this same renderer, so any entry that
    // differs is a candidate for the missing white.
    const char *dir2 = std::getenv("M2_PAL_REF");
    if (dir2) {
      std::string path = std::string(dir2) + "/palette.bin";
      FILE *f = std::fopen(path.c_str(), "rb");
      if (f) {
        std::vector<uint16_t> ref(8192, 0);
        size_t got = std::fread(ref.data(), 2, 8192, f);
        std::fclose(f);
        int diff = 0, first = -1, whites_ref = 0, whites_cpu = 0;
        for (size_t i = 0; i < got && i < 4096; ++i) {
          if (ref[i] == 0x7fff || ref[i] == 0xffff) ++whites_ref;
          if (g_pal[i] == 0x7fff || g_pal[i] == 0xffff) ++whites_cpu;
          if (g_pal_seen[i] && g_pal[i] != ref[i]) { if (first < 0) first = int(i); ++diff; }
        }
        std::printf("    vs %s (%zu words): %d written entries differ, first at %d\n",
                    path.c_str(), got, diff, first);
        std::printf("    entries holding white (7fff/ffff): reference %d, CPU %d\n",
                    whites_ref, whites_cpu);
      }
    }
    int n = 0; for (int i = 0; i < 96; ++i) if (g_xlat_seen[i]) ++n;
    std::printf("  colour translation table, as the CPU programmed it (%d/96 written):\n", n);
    static const char *ch = "RGB";
    for (int c = 0; c < 3; ++c) {
      std::printf("    %c: first=%3d last=%3d  [", ch[c],
                  g_xlat[c*32 + 0], g_xlat[c*32 + 31]);
      for (int i = 0; i < 8; ++i) std::printf("%d ", g_xlat[c*32 + i]);
      std::printf("... %d %d]  %s\n", g_xlat[c*32+30], g_xlat[c*32+31],
                  (g_xlat[c*32+0] == 0 && g_xlat[c*32+31] == 255) ? "ramp ok"
                                                                  : "NOT A 0..255 RAMP");
    }
  }
  if (pctr) { std::fclose(pctr); std::printf("  PC trace written\n"); }
  std::printf("  PRCB as the CPU holds it at the end: %08x (boot value is 000000c0;\n"
              "    it legitimately CHANGES on a reinitialize IAC, so a different\n"
              "    value here is not by itself a fault)\n", d->obs_prcb);
  if (rf_bad_first)
    std::printf("  FIRST frame access outside work RAM: addr %08x at instruction %u,"
                " ip %08x, pfp %08x\n", rf_bad_first, rf_bad_at, rf_bad_ip, rf_bad_pfp);
  {
    std::printf("  COMPOSITION: %llu frames scanned, %llu non-black pixels "
                "in the last one captured\n",
                (unsigned long long)g_frames_done, (unsigned long long)g_nonblack);
    if (const char *fo = std::getenv("M2_FRAME_OUT")) {
      FILE *f = std::fopen(fo, "wb");
      if (f) {
        std::fprintf(f, "P6\n%d %d\n255\n", FW, FH);
        std::fwrite(g_frame.data(), 1, g_frame.size(), f);
        std::fclose(f);
        std::printf("    wrote %s\n", fo);
      }
    }
  }
  if (!g_rd_unbacked.empty()) {
    std::printf("  READS from regions nothing backs (returned 0), by 64 KB:\n");
    std::vector<std::pair<uint64_t,uint32_t>> v;
    for (auto &kv : g_rd_unbacked) v.push_back({kv.second, kv.first});
    std::sort(v.rbegin(), v.rend());
    for (size_t i = 0; i < v.size() && i < 14; ++i)
      std::printf("    %08x  %llu reads\n", v[i].second,
                  (unsigned long long)v[i].first);
  }
  if (!io_unclaimed.empty()) {
    std::printf("  writes to addresses nothing claims, by 256-byte page:\n");
    std::vector<std::pair<uint64_t,uint32_t>> v;
    for (auto &kv : io_unclaimed) v.push_back({kv.second, kv.first});
    std::sort(v.rbegin(), v.rend());
    for (size_t i = 0; i < v.size() && i < 12; ++i)
      std::printf("    %08x  %llu writes\n", v[i].second,
                  (unsigned long long)v[i].first);
  }
  std::printf("  ROM reads vs image: %llu checked, %llu WRONG\n",
              (unsigned long long)g_shadow_rom_ok, (unsigned long long)g_shadow_rom_bad);
  std::printf("  work-RAM shadow: %llu reads checked, %llu WRONG\n",
              (unsigned long long)g_shadow_ok, (unsigned long long)g_shadow_bad);
  std::printf("  frame fills: %llu correct, %llu wrong, %llu from never-spilled addresses\n",
              (unsigned long long)fill_ok, (unsigned long long)fill_wrong,
              (unsigned long long)fill_unwritten);
  std::printf("  register-frame memory: req asserted %llu cycles, %llu acks, last addr %08x\n",
              (unsigned long long)rf_req_cycles, (unsigned long long)rf_ack_count,
              rf_last_addr);
  if (ldos_n)
    std::printf("  source loads: %llu checked, %llu returned the wrong halfword\n",
                (unsigned long long)ldos_n, (unsigned long long)ldos_bad);
  std::printf("  bus address moved mid-transaction: %u times\n", d->obs_addr_moved);

  // R142: the game polls buffer-RAM dword 0x7FFC for zero and spins forever
  // because nothing clears it. On real hardware the coprocessor does. This says
  // whether OUR TGP ever tries -- and if it writes buffer RAM at all.
  std::printf("  COPRO buffer-RAM writes: %u   last word addr %08x   dword 0x7FFC hits: %u\n",
              d->obs_bufw_count, d->obs_bufw_last, d->obs_bufw_7ffc);
  // THE VALUE, NOT JUST THE COUNT. The game writes 0xFFFFFFFF to 0x91FFF0 and
  // polls until it reads 0 (R142/R144), so a write that is not zero leaves it
  // spinning exactly as no write at all would.
  std::printf("  COPRO writes APPLIED to buffer RAM: %llu\n",
              (unsigned long long)bufw_applied);
  if (d->obs_mbox == 0xEEEEEEEEu) {
    std::printf("  MAILBOX dword 0x7FFC: NEVER WRITTEN by the coprocessor\n");
  } else {
    std::printf("  MAILBOX dword 0x7FFC: %08x   %s\n", d->obs_mbox,
                d->obs_mbox == 0 ? "ZERO -- this is what the game waits for"
                                 : "NON-ZERO -- the poll at 0x1166c cannot exit on this");
  }
  // What the CPU would actually read back, straight out of the array it polls.
  std::printf("  MAILBOX BLOCK as the CPU reads it:\n");
  std::printf("    0x91FFF0 (dword 7FFC, the flag)   = %04x%04x\n",
              mem[BUF_BASE + 0xFFF9], mem[BUF_BASE + 0xFFF8]);
  std::printf("    0x91FFF4 (dword 7FFD, result 1)   = %04x%04x   (MAME writes 2 here)\n",
              mem[BUF_BASE + 0xFFFB], mem[BUF_BASE + 0xFFFA]);
  std::printf("    0x91FFF8 (dword 7FFE, result 2)   = %04x%04x\n",
              mem[BUF_BASE + 0xFFFD], mem[BUF_BASE + 0xFFFC]);
  std::printf("  CPU writes into the buffer-RAM window: %llu",
              (unsigned long long)cpu_buf_writes);
  if (cpu_buf_writes) std::printf("   word offsets %04x..%04x", cpu_buf_lo, cpu_buf_hi);
  std::printf("\n");
  std::printf("  COPRO reads with is_buf=1 (buffer RAM): %llu of %llu data reads\n",
              (unsigned long long)buf_reads_n, (unsigned long long)dat_reads);
  auto dump = [&](const char *what, std::vector<DatR> &v) {
    std::printf("  %s:\n", what);
    if (v.empty()) { std::printf("    (none)\n"); return; }
    for (auto &r : v)
      std::printf("    dat_addr=%05x is_buf=%u -> %08x  tgp pc=%04x\n",
                  r.addr, r.isbuf, r.data, r.pc);
  };
  dump("FIRST COPRO DATA READS (MAME's count comes from dword ~0x1088, is_buf=1)",
       datlog);
  dump("FIRST BUFFER-RAM READS", buflog);
  // What is actually sitting where MAME reads its count.
  std::printf("  buffer RAM at MAME's dword 0x1088: %04x %04x   at 0x11B1: %04x %04x\n",
              mem[BUF_BASE + 0x1088*2], mem[BUF_BASE + 0x1088*2 + 1],
              mem[BUF_BASE + 0x11B1*2], mem[BUF_BASE + 0x11B1*2 + 1]);
  if (!cmdstream.empty()) {
    if (const char *cf = std::getenv("M2_CMD_OUT")) {
      if (FILE *f = std::fopen(cf, "w")) {
        for (auto v : cmdstream) std::fprintf(f, "%08X\n", v);
        std::fclose(f);
        std::printf("  command stream (%zu words) written to %s\n",
                    cmdstream.size(), cf);
      }
    }
    std::printf("  COMMAND STREAM, first 24:");
    for (size_t i = 0; i < cmdstream.size() && i < 24; ++i)
      std::printf(" %08x", cmdstream[i]);
    std::printf("\n");
  }
  if (!initlog.empty()) {
    std::printf("  TGP INIT 0x7CC-0x7D6 (MAME: d=FF800030 at 07D2):\n");
    for (auto &e : initlog)
      std::printf("    pc=%04x  d=%08x  a=%08x\n", e.pc, e.d, e.a);
  }
  if (!lptrs.empty()) {
    std::printf("  DISPLAY-LIST POINTERS at 0x475 (MAME: 1057 1180 1049 ...):");
    for (auto v : lptrs) std::printf(" %x", v);
    std::printf("\n");
  }
  if (!lcounts.empty()) {
    std::printf("  DISPLAY-LIST COUNT at 0x47E (MAME reads 6,7,8,9,0x14):");
    for (auto c : lcounts) std::printf(" %08x", c);
    std::printf("\n");
  } else {
    std::printf("  DISPLAY-LIST COUNT at 0x47E: pc 0x47e never reached\n");
  }
  if (!mboxlog.empty()) {
    std::printf("  MAILBOX WRITES (word addr : data @ tgp pc), first %u:\n",
                (unsigned)mboxlog.size());
    for (auto &m : mboxlog)
      std::printf("    cyc %-12llu %05x : %04x   tgp pc=%04x\n",
                  (unsigned long long)m.cyc, m.addr, m.data, m.pc);
  }

  // WHAT THE CPU BUILT, so it can be compared against MAME's own dump rather
  // than guessed at from a photograph of a screen. The board shows white with a
  // brief flicker of colour; the question that answers is whether the palette
  // it wrote is white, and only a comparison can say.
  if (const char *dd = std::getenv("M2_BOOT_DUMP")) {
    auto grab = [&](const char *name, bool pal, uint32_t n) {
      std::string path = std::string(dd) + "/" + name;
      FILE *f = std::fopen(path.c_str(), "wb");
      if (!f) return;
      for (uint32_t a = 0; a < n; ++a) {
        d->dump_addr = a; d->eval();
        const uint16_t v = pal ? d->dump_pal : d->dump_tram;
        std::fputc(v & 0xff, f); std::fputc(v >> 8, f);
      }
      std::fclose(f);
      std::printf("  wrote %s (%u words)\n", path.c_str(), n);
    };
    grab("tram.bin", false, 32768);
    // CHAR RAM, straight out of the modelled SDRAM at GAME_CHAR. The tilemap
    // says WHICH character to draw; this is the character. A correct tilemap
    // over blank characters is a black screen, which is what the board shows.
    {
      std::string path = std::string(dd) + "/char.bin";
      FILE *f = std::fopen(path.c_str(), "wb");
      if (f) {
        const uint32_t CHAR_BASE = 0x1690000;   // GAME_CHAR, word address
        uint32_t nz = 0;
        for (uint32_t w = 0; w < 0x40000; ++w) {
          const uint16_t v = mem[CHAR_BASE + w];
          if (v && v != 0xffff) ++nz;
          std::fputc(v & 0xff, f); std::fputc(v >> 8, f);
        }
        std::fclose(f);
        std::printf("  char RAM: %u of 262144 words written (non-zero, non-ffff)\n", nz);
        std::printf("  char RAM writes issued: %llu even, %llu odd\n",
                    (unsigned long long)char_even, (unsigned long long)char_odd);
      }
    }
    grab("pal.bin",  true,  4096);
    // How much of the palette is white, which is the specific question.
    uint32_t white = 0, nonzero = 0;
    for (uint32_t a = 0; a < 4096; ++a) {
      d->dump_addr = a; d->eval();
      const uint16_t v = d->dump_pal;
      if (v) ++nonzero;
      if ((v & 0x7fff) == 0x7fff) ++white;
    }
    std::printf("  palette: %u of 4096 non-zero, %u are full white (7FFF)\n",
                nonzero, white);
  }

  // DID THE BOOT'S FIRST BLOCK COPY LAND? Instruction 113 is
  //
  //   00000890: shlo 17,1,g0        ; 128 KB
  //   0000089C: lda  0x200000,g2    ; board RAM
  //   000008A4: bal  0x910          ; ldq/stq, 16 bytes an iteration
  //
  // copying the program ROM into board RAM. MAME runs that loop 8,192 times.
  // Checking the destination is worth more than counting the loop: it says
  // whether the machine ended up in the right state, not whether it took the
  // expected route there.
  {
    const uint32_t BOARD = 0x1680000;   // GAME_BOARD, word address
    size_t same = 0, diff = 0;
    for (uint32_t w = 0; w < 0x10000; ++w) {
      if (mem[BOARD + w] == mem[w]) ++same; else ++diff;
    }
    std::printf("  boot copy 0x0 -> 0x200000: %zu of %zu words match\n",
                same, same + diff);
    // The PATTERN names the fault. Duplicated words mean an address latched
    // twice; a shift means one was missed; zeros or 0xffff mean the write never
    // reached memory at all.
    std::printf("    src:");
    for (int w = 0; w < 12; ++w) std::printf(" %04x", mem[w]);
    std::printf("\n    dst:");
    for (int w = 0; w < 12; ++w) std::printf(" %04x", mem[BOARD + w]);
    std::printf("\n");
  }

  int fail = 0;
  if (d->iob_win_rd == 0) {
    std::printf("\n  BLOCKED: the i960 never read the block window -- the\n"
                "  exchange itself is broken in this composition. Step that\n"
                "  before asking about the race.\n");
    fail = 1;
  } else if (g_set_contam) {
    std::printf("\n  RACE REPRODUCED: the settings copy-back (first window read\n"
                "  at instruction %llu) carried the firmware's input-scan bytes\n"
                "  (7F/FF) -- the exact contamination the board measures (R63).\n",
                (unsigned long long)first_win_rd);
  } else {
    std::printf("\n  clean exchange (first window read at instruction %llu):\n"
                "  the copy-back carried real settings and the race was won.\n"
                "  The board loses it; this run did not reproduce that.\n",
                (unsigned long long)first_win_rd);
  }
  {
    const uint64_t insns = uint64_t(d->dbg_acc) - prof_acc0;
    std::printf("\n  CYCLE PROFILE over %llu instructions:\n",
                (unsigned long long)insns);
    if (insns) {
      std::printf("    cycles              %12llu   CPI %.2f\n",
                  (unsigned long long)prof_cycles, double(prof_cycles)/double(insns));
      std::printf("    bus request up      %12llu   %5.1f%% of cycles\n",
                  (unsigned long long)prof_req, 100.0*double(prof_req)/double(prof_cycles));
      std::printf("    WAITING on memory   %12llu   %5.1f%% of cycles"
                  "   -> %.2f of the CPI\n",
                  (unsigned long long)prof_waiting,
                  100.0*double(prof_waiting)/double(prof_cycles),
                  double(prof_waiting)/double(insns));
      {
      static const char *TS[32] = {
        "T_FETCH","T_FETCH_W","T_FETCH2","T_FETCH2_W","T_DECODE",
        "T_EXEC","T_MEM","T_MEM_W","T_MULDIV","T_MULTI","T_PAIR","T_FP",
        "T_WB","T_FRAME","14","15","16","17","18","19","20","21","22","23",
        "24","25","26","27","28","29","30","31" };
      const double pf_tot = double(pf_hit + pf_miss + pf_len2);
      std::printf("\n    PREFETCH: %llu hits, %llu misses -> %.1f%% hit rate\n",
                  (unsigned long long)pf_hit, (unsigned long long)pf_miss,
                  pf_tot > 0 ? 100.0*double(pf_hit)/pf_tot : 0.0);
      std::printf("      of the misses: %llu mispredicted (a branch), %llu right but LATE\n",
                  (unsigned long long)pf_m_wrong, (unsigned long long)pf_m_late);
      std::printf("    two-word instructions (cannot prefetch by design): %llu, %.1f%%\n",
                  (unsigned long long)pf_len2,
                  100.0*double(pf_len2)/double(d->dbg_acc));
      std::printf("\n    WHERE THE CORE'S CYCLES GO -- CPU cycles per instruction"
                  " (total %.2f):\n", double(prof_cpu_cycles)/double(d->dbg_acc));
      for (int i = 0; i < 32; ++i)
        if (prof_ts[i])
          std::printf("      %-12s %12llu  %5.1f%%  -> %5.2f of the CPI\n",
                      TS[i], (unsigned long long)prof_ts[i],
                      100.0*double(prof_ts[i])/double(prof_cycles),
                      double(prof_ts[i])/double(d->dbg_acc));
      std::printf("\n");
    }
    std::printf("    core sequencing     %12llu   %5.1f%% of cycles"
                  "   -> %.2f of the CPI\n",
                  (unsigned long long)(prof_cycles - prof_waiting),
                  100.0*double(prof_cycles-prof_waiting)/double(prof_cycles),
                  double(prof_cycles-prof_waiting)/double(insns));
      std::printf("    bus transactions    %12llu   %.3f per instruction,"
                  " %.1f cycles of wait each\n",
                  (unsigned long long)prof_txn, double(prof_txn)/double(insns),
                  prof_txn ? double(prof_waiting)/double(prof_txn) : 0.0);
      std::printf("    of which WRITES     %12llu   %5.1f%%   waiting on them:"
                  " %llu cycles -> %.2f of the CPI\n",
                  (unsigned long long)prof_txn_wr,
                  100.0*double(prof_txn_wr)/double(prof_txn ? prof_txn : 1),
                  (unsigned long long)prof_wait_wr,
                  double(prof_wait_wr)/double(insns));
      {
        const double h = d->obs_dc_hits, m = d->obs_dc_miss;
        std::printf("    DATA CACHE          hits %.0f  misses %.0f  hit rate %.2f%%"
                    "   (modelled 97.86%% on reads alone)\n", h, m,
                    (h+m) ? 100.0*h/(h+m) : 0.0);
      }
      static const char *ST[8]={"IDLE","LO","LO_W","HI","HI_W","RDB","IOW","DONE"};
      std::printf("    bridge sequencer, cycles in each state:\n");
      for (int i = 0; i < 8; ++i)
        std::printf("      %-5s %12llu  %5.1f%%  %6.2f cycles per transaction\n",
                    ST[i], (unsigned long long)prof_st[i],
                    100.0*double(prof_st[i])/double(prof_cycles),
                    prof_txn ? double(prof_st[i])/double(prof_txn) : 0.0);
    }
  }
  {
    std::printf("  COPROCESSOR:\n");
    std::printf("    copro_ctl1        %08x\n", (unsigned)d->obs_copro_ctl);
    std::printf("    program uploaded  %u words\n", (unsigned)d->obs_copro_prog);
    std::printf("    FIFO in pushed    %u\n", (unsigned)d->obs_copro_in);
    { std::printf("    AT EACH PUSH: tgp pc / B / last pop  (MAME dispatches from 004c to 00a1)\n");
      for (auto &e : dbg_disp) std::printf("      pc=%04x B=%08x pop=%08x\n", e.pc, e.b, e.pop); }
    if (g_st1578) for (auto &e : *g_st1578) { std::printf("    STORE @%05x -> bus addr:", e.first);
      for (auto &a : e.second) std::printf(" %08x(x%u)", a.first, a.second); std::printf("\n"); }
    std::printf("    FIFO out popped   %u\n", (unsigned)d->obs_copro_out);
    std::printf("    WORDS DROPPED     in=%u  out=%u%s\n", (unsigned)d->obs_in_dropped, (unsigned)d->obs_out_dropped,
                (d->obs_in_dropped || d->obs_out_dropped) ? "   <<< DATA LOSS" : "");
    std::printf("    TGP retires       %u   pc=%04x%s\n",
                (unsigned)d->obs_tgp_retires, (unsigned)d->obs_tgp_pc,
                d->obs_tgp_unimpl ? "   *** UNIMPLEMENTED OPCODE ***" : "");
    std::printf("    table reads       %llu    data reads %llu\n",
                (unsigned long long)tbl_reads, (unsigned long long)dat_reads);
    // A coprocessor that was uploaded and booted but retires nothing is the
    // interesting failure, and it is invisible in anything else this harness
    // prints.
    if (d->obs_copro_prog && !d->obs_tgp_retires)
      std::printf("    *** program uploaded but the TGP retired NOTHING ***\n");
    std::printf("    i960 fifo_control polls  %u\n", (unsigned)d->obs_fctl_reads);
    std::printf("    TGP popped        %u   (MAME: 484,947 against 257,709 pushes)\n", (unsigned)d->obs_in_popped);
    std::printf("    WORDS DROPPED     in=%u  out=%u%s\n",
                (unsigned)d->obs_in_dropped, (unsigned)d->obs_out_dropped,
                (d->obs_in_dropped || d->obs_out_dropped) ? "   <<< DATA LOSS" : "");
    { std::printf("    POP / B / D  (MAME: the pop lands in B, D = get_exp(B) + 0x58)\n");
      if (const char *qf = std::getenv("M2_PUSHLOG")) {
        FILE *g = std::fopen(qf, "w");
        if (g) { for (size_t k = 0; k < pushvals.size(); ++k) std::fprintf(g, "%08x @%08x\n", pushvals[k], k < pushpcs.size() ? pushpcs[k] : 0u); std::fclose(g);
                 std::printf("      push stream written (%zu)\n", pushvals.size()); }
      }
      if (const char *pf = std::getenv("M2_POPLOG")) {
        FILE *g = std::fopen(pf, "w");
        if (g) { for (auto v : popvals) std::fprintf(g, "%08x\n", v); std::fclose(g);
                 std::printf("      pop stream written (%zu values)\n", popvals.size()); }
      }
      for (size_t i = 0; i < popvals.size() && i < 14; ++i)
        std::printf("      pop=%08x  A=%08x  B=%08x  D=%08x\n",
                    popvals[i], popA[i], popB[i], popD[i]);
      std::printf("      A non-zero for %llu cycles (last %08x)\n", (unsigned long long)a_nz, a_last);
      std::printf("      B non-zero for %llu cycles (last %08x)\n", (unsigned long long)b_nz, b_last);
      std::printf("      D non-zero for %llu cycles (last %08x)\n", (unsigned long long)d_nz, d_last);
      std::printf("      FIFO read held the pipe for %u cycles\n", (unsigned)d->obs_tgp_hold);
      { std::printf("      UNIMPLEMENTED fired on %llu cycles", (unsigned long long)unimpl_n);
        if (!unimpl_pc.empty()) { std::printf("   at pc:"); for (auto p : unimpl_pc) std::printf(" %04x", p); }
        std::printf("\n"); }
      std::printf("      i960 HELD by the copro for %llu of %llu cycles (%.1f%%)\n",
                  (unsigned long long)cpu_held, (unsigned long long)mem_cyc,
                  mem_cyc ? 100.0*double(cpu_held)/double(mem_cyc) : 0.0);
      { std::printf("      TGP OUTPUT, ours (%u pushed):\n       ", (unsigned)d->obs_out_pushed);
        for (auto v : outvals) std::printf(" %08x", v);
        std::printf("\n        MAME idles pushing 00000000 from pc 030a, then at the\n"
                    "        first command batch: 3f9e5556 3f5a7171 4260e0e2 42e00000\n"
                    "        4289898a 430a7e7e 00000000 00000000 c08fd608 41840a7e\n"); }
      { std::printf("      WHERE OUR POPS HAPPEN (MAME pops at 0044 and 004c):\n");
        std::vector<std::pair<uint64_t,uint32_t>> h;
        for (auto &kv : pop_pc_hist) h.push_back({kv.second, kv.first});
        std::sort(h.rbegin(), h.rend());
        for (size_t i = 0; i < h.size() && i < 6; ++i)
          std::printf("        pc %04x : %llu\n", h[i].second, (unsigned long long)h[i].first); }
      { std::printf("      DRAIN LOOP 0x44-0x4b, ours:\n");
        for (auto &l : loopst) std::printf("        %s\n", l.c_str());
        std::printf("      MAME: 0044 A=ff800000 B=00000000 D=ff819c90 ST=f8000009\n"
                    "            0045 A=ff800000 B=04000001 D=ff819c90 ST=f8000009\n"
                    "            0046 A=ff800000 B=04000001 D=00000008 ST=f8000009\n"
                    "            0047 A=0000003f B=04000001 D=00000008 ST=f8000009\n"
                    "            0048 A=00000008 B=04000001 D=00000008 ST=f8000001\n"
                    "            0049 A=00000008 B=04000001 D=00000000 ST=f8000003\n"
                    "            004a A=00000008 B=04000001 D=00000000 ST=f8000003\n"); }
      { std::printf("      FIRST DATA-RAM WRITES:\n       ");
        for (auto &w : dwrites) std::printf(" [%03x]=%08x", w.first, w.second);
        std::printf("\n        MAME: [000]=0 [001]=1 [002]=ffffffff [003]=0 [004]=3f800000\n"
                    "              [005]=bf800000 [006]=f [007]=130 [008]=130 [009]=0\n"
                    "              [00a]=7 [00b]=8 [00c]=100 [00d]=200\n"); }
      std::printf("      TGP data-RAM writes: %u  (last addr %05x)\n",
                  (unsigned)d->obs_tgp_wr_n, (unsigned)d->obs_tgp_wr_addr); }
    std::printf("    io rd/wr/ack      %llu / %llu / %llu\n",
                (unsigned long long)tgp_io_rd_n, (unsigned long long)tgp_io_wr_n,
                (unsigned long long)tgp_io_ack_n);
    std::printf("    fifo rd/wr        %llu / %llu\n",
                (unsigned long long)tgp_fifo_rd_n, (unsigned long long)tgp_fifo_wr_n);
    std::printf("    ram_req cycles    %llu   (the window is TIED OFF)\n",
                (unsigned long long)tgp_ram_req_cyc);
    {
      std::vector<std::pair<uint64_t,uint32_t>> h;
      for (auto &kv : tgp_pc_hist) h.push_back({kv.second, kv.first});
      std::sort(h.rbegin(), h.rend());
      std::printf("    WHERE THE TGP SITS -- top program addresses:\n");
      for (size_t i = 0; i < h.size() && i < 8; ++i)
        std::printf("      pc %04x  %10llu\n", h[i].second,
                    (unsigned long long)h[i].first);
      std::printf("    (%zu distinct program addresses seen)\n", tgp_pc_hist.size());
    }
    {
      std::printf("    FIRST PCs AFTER BOOT, in order:\n     ");
      for (size_t i = 0; i < tgp_pc_seq.size(); ++i)
        std::printf(" %04x%s", tgp_pc_seq[i],
                    ((i % 16) == 15 && i + 1 < tgp_pc_seq.size()) ? "\n     " : "");
      std::printf("\n");
    }
    {
      // Against MAME's own :copro_tgp_program, dumped at the same addresses.
      std::printf("    copro_ctl1 WRITES (value : program words so far):\n     ");
      for (size_t i = 0; i < ctl_log.size(); ++i)
        std::printf(" %08x:%u%s", ctl_log[i].first, ctl_log[i].second,
                    ((i % 5) == 4 && i + 1 < ctl_log.size()) ? "\n     " : "");
      std::printf("\n");
      // RE-DUMPED FROM MAME, CORRECTLY ADDRESSED. The previous table was
      // captured under the R110 error -- reading AS_PROGRAM at read_u32(word*4)
      // when the space is (32,16,-2) -- and R116 retracted the finding without
      // fixing these constants. Every entry was wrong, so this bench printed
      // "the uploaded PROGRAM is wrong" on every run against a CORRECT core.
      // Verified: MAME holds 2,024 nonzero words and we upload 2,024, and all
      // ten original addresses match exactly. 0x480-0x482 are here because the
      // TGP halts at 0x481 on hardware.
      static const struct { uint32_t a, w; } want[] = {
        {0x44,0x1c1f2621}, {0x45,0x1c1f3214}, {0x46,0x3900003f}, {0x47,0x1c3da00b}, {0x48,0x1f7f1e10}, {0x49,0xfe000044}, {0x4a,0x3b000008}, {0x4b,0xbf600055}, {0x4c,0x1c1f2621}, {0x57,0xbf624019}, {0x480,0xbe0004b7}, {0x481,0x1c1dc638}, {0x482,0x1c089da1},
      };
      std::printf("    PROGRAM AS FETCHED vs MAME:\n");
      int bad = 0;
      for (auto &e : want) {
        auto it = tgp_prog.find(e.a);
        if (it == tgp_prog.end()) { std::printf("      %04x  (never fetched)   want %08x\n", e.a, e.w); continue; }
        const bool ok = (it->second == e.w);
        if (!ok) ++bad;
        std::printf("      %04x  %08x  want %08x  %s\n", e.a, it->second, e.w, ok ? "ok" : "<<< MISMATCH");
      }
      if (bad) std::printf("    *** the uploaded PROGRAM is wrong, not the decode ***\n");
    }
    if (!tgp_io_hist.empty()) {
      std::vector<std::pair<uint64_t,uint32_t>> h;
      for (auto &kv : tgp_io_hist) h.push_back({kv.second, kv.first});
      std::sort(h.rbegin(), h.rend());
      std::printf("    WHAT IT KEEPS READING -- top io addresses:\n");
      for (size_t i = 0; i < h.size() && i < 8; ++i)
        std::printf("      io %04x  %10llu\n", h[i].second,
                    (unsigned long long)h[i].first);
    }
  }
  {
    std::printf("  WHERE THE CPU RAN -- top 4 KB pages of %llu retired:\n",
                (unsigned long long)retired);
    std::vector<std::pair<uint64_t,uint32_t>> h;
    for (auto &kv : pc_hist) h.push_back({kv.second, kv.first});
    std::sort(h.rbegin(), h.rend());
    for (size_t i = 0; i < h.size() && i < 12; ++i)
      std::printf("    %08x-%08x  %10llu  %5.1f%%\n",
                  h[i].second << 12, (h[i].second << 12) | 0xfff,
                  (unsigned long long)h[i].first,
                  retired ? 100.0 * double(h[i].first) / double(retired) : 0.0);
    if (pchit_addr)
      std::printf("    PC %08x executed %llu times\n",
                  pchit_addr, (unsigned long long)pchit_n);
  }
  {
    // THE DISPLAY-LIST WALK. On hardware this completes exactly one frame and
    // then never runs again -- frames=1, objs=0, unknown=0 -- and the state it
    // is sitting in is the whole question. W_IDLE means it is waiting for a
    // vblank that is not arriving or a list it will not start; anything else
    // means it is stuck mid-walk.
    static const char* WST[16] = {
      "W_IDLE","W_FETCH","W_DECODE","W_SKIP","W_CNT","W_TFIFO","W_DDSKIP",
      "W_DDATTR","W_OPRD","W_OBJW","W_PDA","W_PDR","W_PDW","?13","?14","?15"
    };
    std::printf("  DISPLAY LIST PUSH PORT (R254): accepted %u dwords, queue DROPPED %u\n",
                (unsigned)d->geo_pushes_o, (unsigned)d->geo_dropped_o);
    std::printf("  DISPLAY LIST WALK:\n");
    std::printf("    frames=%u  ops=%u  objs=%u  unknown=%02x  state=%s\n",
                d->geo_frames, d->geo_ops, d->geo_objs, d->geo_unknown,
                WST[d->geo_state & 15]);
    std::printf("    geo rp=%08x wp=%08x\n", d->geo_rp_o, d->geo_wp_o);
    std::printf("    matrix writes=%u  focal writes=%u\n", d->geo_mtx_n, d->geo_foc_n);
    {
      std::vector<std::pair<uint64_t,uint32_t>> v;
      uint64_t tot = 0;
      for (auto &e : ip_hist) { v.push_back({e.second, e.first}); tot += e.second; }
      std::sort(v.rbegin(), v.rend());
      std::printf("    i960 PC histogram, same 1-in-65536 sampling as the board's UART:\n");
      for (size_t i = 0; i < v.size() && i < 8; i++)
        std::printf("      %08x  %5.1f%%\n", v[i].second,
                    100.0 * double(v[i].first) / double(tot ? tot : 1));
      std::printf("      (%zu distinct, %llu samples)\n", v.size(),
                  (unsigned long long)tot);
    }
    std::printf("    PUSHED: %u matrix, %u object   last matrix pushed from PC %08x\n",
                d->geo_mtx_pushes, d->geo_obj_pushes, d->geo_mtx_pc);
    std::printf("    last object: oba=%08x obc=%08x  -> %s\n",
                d->geo_oba_last, d->geo_obc_last,
                (d->geo_oba_last & 0x01000000u) ? "fast polygon RAM"
                : (d->geo_oba_last & 0x00800000u) ? "polygon ROM" : "slow polygon RAM");
    std::printf("  GEOMETRY ENGINE:\n");
    std::printf("    ATAN jobs checked %ld, off by more than 2/65536 turn: %ld\n", g_at_n, g_at_bad);
    std::printf("    objects=%u polys=%u capped=%u nonfinite=%u\n",
                d->eng_objects, d->eng_polys, d->eng_capped, d->eng_nonfinite);
    std::printf("    clipper in=%u out=%u dropped=%u   QUADS OUT=%zu\n",
                d->eng_clip_in, d->eng_clip_out, d->eng_clip_drop, g_quads.size());
    // EVERY QUAD, to a file, when asked: the harness has no rasteriser, so the
    // screen coordinates here are the only picture of the 3D the bench has.
    if (g_eng_gaps && !g_eng_gaps->empty()) {
      std::vector<int> g = *g_eng_gaps; std::sort(g.begin(), g.end());
    th_report();
      std::printf("    ENGINE COST from M2_POLY_FROM: busy ticks %ld over %ld objects (%.0f/object), %ld quads (%.1f busy ticks/quad); quad-to-quad gap median %d, p90 %d ticks\n",
                  g_eng_busy_ticks, g_eng_objs, g_eng_objs ? (double)g_eng_busy_ticks / g_eng_objs : 0.0, g_eng_quads,
                  g_eng_quads ? (double)g_eng_busy_ticks / g_eng_quads : 0.0, g[g.size()/2], g[g.size()*9/10]);
    }
    {
      static const char *EN[32] = {"E_IDLE","E_RD","E_XF","E_XFW","E_FOC","E_FOCW","E_STORE","E_ATTR","E_NORM","E_NXF","E_NXFW","E_SKIP","E_EMIT","E_LINK","E_DONE","E_DOT","E_DOTA","?","?","?","?","?","?","?","?","?","?","?","?","?","?","?"};
      long tot = 0; for (int i = 0; i < 32; i++) tot += g_eng_st_hist[i];
      if (tot) {
        std::printf("    ENGINE STATES from M2_POLY_FROM (ticks, %% of all):");
        for (int i = 0; i < 32; i++) if (g_eng_st_hist[i]) std::printf(" %s %ld (%.1f%%)", EN[i], g_eng_st_hist[i], 100.0 * g_eng_st_hist[i] / tot);
        std::printf("\n    projection busy %ld ticks (%.1f%%): quad projector %ld (%.1f%%), clipper %ld (%.1f%%); projections granted: quad %ld, clipper %ld; R217 cache hits %ld\n",
                    g_pj_busy_ticks, 100.0 * g_pj_busy_ticks / tot, g_pj_w_ticks, 100.0 * g_pj_w_ticks / tot, g_pj_k_ticks, 100.0 * g_pj_k_ticks / tot, g_w_grants, g_k_grants, g_pj_hits);
        static const char *WN[16] = {"W_IDLE","W_FETCH","W_DECODE","W_SKIP","W_CNT","W_TFIFO","W_DDSKIP","W_DDATTR","W_OPRD","W_OBJW","W_PDA","W_PDR","W_PDW","W_TPI","W_TPP","W_TPC"};
        std::printf("    WALKER STATES from M2_POLY_FROM:");
        for (int i = 0; i < 16; i++) if (g_walk_hist[i]) std::printf(" %s %.1f%%", WN[i], 100.0 * g_walk_hist[i] / tot);
        std::printf("\n");
      }
    }
    if (const char *qo = std::getenv("M2_QUADS_OUT")) {
      if (FILE *qf = std::fopen(qo, "w")) {
        for (auto &q : g_quads) std::fprintf(qf, "%d %d %d %d %d %d %d %d %06x %08x\n", q[0], q[1], q[2], q[3], q[4], q[5], q[6], q[7], q[8], q[9]);
        std::fclose(qf);
      }
    }
    for (size_t i = 0; i < g_quads.size() && i < 24; i++)
      std::printf("      quad %zu: (%d,%d) (%d,%d) (%d,%d) (%d,%d) col %06x\n", i,
                  g_quads[i][0], g_quads[i][1], g_quads[i][2], g_quads[i][3],
                  g_quads[i][4], g_quads[i][5], g_quads[i][6], g_quads[i][7], g_quads[i][8]);
    {
      // R222: the colours the title's quads carry -- how many distinct, and the
      // commonest. A single colour here would mean the lookup is not landing.
      std::map<int,int> cols; for (auto &q : g_quads) cols[q[8]]++;
      std::vector<std::pair<int,int>> top(cols.begin(), cols.end());
      std::sort(top.begin(), top.end(), [](auto &a, auto &b){ return a.second > b.second; });
      std::printf("    QUAD COLOURS: %zu distinct over %zu quads;", cols.size(), g_quads.size());
      for (size_t i = 0; i < top.size() && i < 10; i++) std::printf(" %06x x%d", top[i].first, top[i].second);
      std::printf("\n");
    }
    std::printf("    polygon_data: %u commands, %u dwords, %zu distinct words written\n",
                d->geo_pdcmds, d->geo_pdwords, g_geo_writes.size());
    if (!g_geo_writes.empty()) {
      uint32_t lo = *g_geo_writes.begin(), hi = *g_geo_writes.rbegin();
      std::printf("    front-door DMA wrote words %08x..%08x (buffer RAM is 016f0000+)\n",
                  lo, hi);
    }

    // THE SAME HISTOGRAM MAME'S LUA SCRIPT PRODUCES, so the two are directly
    // comparable. MAME at frame 300 holds 01:138 object_data and 0b:29
    // matrix_write in this memory; if ours holds none, the front door is still
    // not delivering what the i960 wrote.
    {
      int hist[32] = {0}; int total = 0;
      for (uint32_t dw = 0; dw < 2048; dw++) {
        const uint32_t a2 = 0x16f0000u + (dw << 1);
        const uint32_t w  = uint32_t(mem[a2]) | (uint32_t(mem[a2 + 1]) << 16);
        if (w != 0 && w != 0xffffffffu) { hist[(w >> 23) & 0x1f]++; total++; }
      }
      std::printf("    OUROPS nonzero=%d  ", total);
      for (int op = 0; op < 32; op++) if (hist[op]) std::printf("%02x:%d ", op, hist[op]);
      std::printf("\n");
    }

    // WHERE IS THE LIST, ACTUALLY? Scan buffer RAM for the opcode pattern a
    // display list must have -- a geo_end (0x0f/0x1f) with a plausible command
    // near it -- rather than trusting the pointer the walk was given.
    {
      int shown = 0;
      std::printf("    scanning buffer RAM for geo_end opcodes:\n");
      for (uint32_t dw = 0; dw < 0x4400 && shown < 8; dw++) {
        const uint32_t a2 = 0x16f0000u + (dw << 1);
        const uint32_t w  = uint32_t(mem[a2]) | (uint32_t(mem[a2 + 1]) << 16);
        const uint32_t op = (w >> 23) & 0x1f;
        if ((op == 0x0f || op == 0x1f) && w != 0xffffffffu) {
          std::printf("      dword %5u : %08x  geo_end\n", dw, w);
          shown++;
        }
      }
      if (!shown) std::printf("      NONE FOUND -- no geo_end anywhere in buffer RAM\n");
    }

    // THE LIST ITSELF, FROM WHERE THE WALK STARTS. ops saturating with frames=0
    // means the walk is desynchronised: one wrong opcode length and it reads an
    // operand as a command and wanders. The only way to tell a wrong length
    // from a list that genuinely has no end is to read the list.
    {
      const uint32_t rp_dw = (d->geo_rp_o & 0x1ffff) >> 2;
      std::printf("    LIST from rp (dword %u):\n", rp_dw);
      for (uint32_t i = 0; i < 24; i++) {
        const uint32_t a = (0x16f0000u + ((rp_dw + i) << 1)) & 0x1ffffff;
        const uint32_t w = uint32_t(mem[a]) | (uint32_t(mem[a + 1]) << 16);
        const uint32_t op = (w >> 23) & 0x1f;
        std::printf("      [%4u] %08x   op=%02x%s\n", rp_dw + i, w, op,
                    (op == 0x0f || op == 0x1f) ? "  <-- geo_end" : "");
      }
    }

    std::printf("  TILEMAP SCROLL the renderer used, per layer:\n");
    for (int i = 0; i < 4; ++i)
      std::printf("    layer %d : hscr=%04x  vscr=%04x%s\n", i,
                  d->obs_hscr[i], d->obs_vscr[i],
                  (d->obs_hscr[i] || (d->obs_vscr[i] & 0x1ff)) ? "" : "   (no scroll)");
  }
  if (ucf) { std::fprintf(ucf, "-- total %llu\n", (unsigned long long)uc_n); std::fclose(ucf); std::printf("  upload stream written\n"); }
  if (dtr) { std::fclose(dtr); std::printf("  data address trace written\n"); }
  if (out) { std::fclose(out); std::printf("  PC stream written to %s\n", outfile); }
  if (charstream) { std::fclose(charstream); std::printf("  char write stream written\n"); }
  std::printf("%s\n", fail ? "FAIL" : "PASS");
  delete d;
  return fail;
}
