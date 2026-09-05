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
static std::set<uint32_t> g_geo_writes;      // word addresses geo_polygon_data wrote
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
      std::printf("   dword 0x10 = %04x%04x (MAME: ff000030)",
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
  const uint32_t TBL_BASE = 0x15d8000;      // GAME_TGPTBL, word address
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
  auto geo_tick = [&]() {
    d->geo_rd_ack = 0;
    if (d->geo_rd_req) {
      const uint32_t a = (0x16f0000u + (uint32_t(d->geo_rd_addr) << 1)) & 0x1ffffff;
      d->geo_rd_data = uint32_t(mem[a]) | (uint32_t(mem[(a + 1) & 0x1ffffff]) << 16);
      d->geo_rd_ack  = 1;
    }
    d->geo_sd_ack = 0;
    if (d->geo_sd_req) {
      const uint32_t a = uint32_t(d->geo_sd_addr) & 0x1ffffff;
      mem[a] = d->geo_sd_din;
      g_geo_writes.insert(a);
      d->geo_sd_ack = 1;
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
      if ((uint32_t(d->obs_bufw_waddr) >> 1) >= 0x07FFCu
          && (uint32_t(d->obs_bufw_waddr) >> 1) <= 0x07FFEu && mboxlog.size() < 40)
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
  {
    unsigned c = 0xff;
    if (const char *cv = std::getenv("M2_IN0")) c = std::strtoul(cv, nullptr, 16);
    d->cab_in0 = c;
    if (c != 0xff) std::printf("  CABINET in0 = %02x (bit2 clear = TEST held)\n", c);
  }
  int slow_prev = 0;
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
        // TILEMAP CONTENT CENSUS, to put beside the board's UART capture. The
      // board fetches only tiles 0, 1, 24576 and 24577 -- blank tiles with two
      // attributes -- so the question is what the SAME code writes here.
      // M2_FRAME_SEQ=dir writes EVERY completed frame, so the render can be
        // watched as a sequence instead of judged from one still. Two of this
        // session's wrong conclusions came from reading a single frame that
        // happened to be captured mid-draw.
        if (g_seq_dir && (g_frames_done % g_seq_every) == 0) {
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
      if (pctr && d->dbg_acc >= pcfrom) std::fprintf(pctr, "%08x\n", (unsigned)ip);
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
    if (d->obs_bus_ack && !ack_prev) {
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
    std::printf("  DISPLAY LIST WALK:\n");
    std::printf("    frames=%u  ops=%u  objs=%u  unknown=%02x  state=%s\n",
                d->geo_frames, d->geo_ops, d->geo_objs, d->geo_unknown,
                WST[d->geo_state & 15]);
    std::printf("    geo rp=%08x wp=%08x\n", d->geo_rp_o, d->geo_wp_o);
    std::printf("    polygon_data: %u commands, %u dwords, %zu distinct words written\n",
                d->geo_pdcmds, d->geo_pdwords, g_geo_writes.size());
    if (!g_geo_writes.empty()) {
      uint32_t lo = *g_geo_writes.begin(), hi = *g_geo_writes.rbegin();
      std::printf("    front-door DMA wrote words %08x..%08x (buffer RAM is 016f0000+)\n",
                  lo, hi);
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
