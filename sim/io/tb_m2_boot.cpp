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

static Vm2_boot_harness *d;

// 25-bit word address space, 64 MB. Unwritten reads 0xFFFF, per the standing
// rule in docs/mister-integration.md — never zero.
static std::vector<uint16_t> mem;

static bool load_file(const std::string &p, std::vector<uint8_t> &out) {
  FILE *f = std::fopen(p.c_str(), "rb");
  if (!f) return false;
  std::fseek(f, 0, SEEK_END); long n = std::ftell(f); std::fseek(f, 0, SEEK_SET);
  out.resize(size_t(n));
  const size_t got = std::fread(out.data(), 1, size_t(n), f);
  std::fclose(f);
  return got == size_t(n);
}

static int g_e1n = 0, g_e0n = 0, g_win = 0, g_bk_n = 0, g_c3_n = 0, g_src_n = 0, g_sw_n = 0;
static const int FW = 496, FH = 384;
static std::vector<uint8_t> g_frame(size_t(FW)*FH*3, 0);
static int g_px = 0, g_py = 0, g_hb_p = 0, g_vb_p = 0;
static uint64_t g_nonblack = 0, g_frames_done = 0;
static std::map<uint32_t,uint64_t> g_rd_unbacked;
static uint64_t g_tw_in_vbl = 0, g_tw_out_vbl = 0, g_ss_in = 0, g_ss_out = 0;
static uint16_t g_tram[32768];
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

  // THREE CLOCKS, ON A 192 MHz BASE, because 48 and 32 do not divide each
  // other. Half-periods are 2, 3 and 4 base steps: clk_mem 48 MHz, clk_vid 32
  // MHz, clk_cpu 24 MHz -- the board's ratios exactly. Driving clk_vid as a
  // simple divide of clk_mem would invent a phase relationship the hardware
  // does not have, which is the whole thing this harness exists to model.
  uint64_t mem_edges = 0, base_t = 0;
  int mem_prev = 0, vid_prev = 0;

  // ce_pix halves clk_vid to the 16 MHz dot clock, as Model2.sv does.
  int ce_tog = 0;

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
      if (d->vid_vb && !g_vb_p) { ++g_frames_done; }
      if (!d->vid_vb && g_vb_p) { g_py = 0; g_px = 0; }
      g_hb_p = d->vid_hb; g_vb_p = d->vid_vb;
    }
    if (v && !vid_prev) { ce_tog ^= 1; d->ce_pix = ce_tog; }
    d->clk_mem = m; d->clk_vid = v; d->clk_cpu = c;
    d->eval();
    if (m && !mem_prev) { mem_tick(); sd2_tick(); d->eval(); ++mem_edges; }
    mem_prev = m; vid_prev = v;
    ++base_t;
  };

  // One clk_mem cycle, so the loop below is unchanged.
  auto tick = [&]() { for (int i = 0; i < 4; ++i) base_step(); };

  for (int i = 0; i < 64; ++i) tick();
  d->rst_n = 1;

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

  while (d->dbg_acc < max_instr) {
    tick();
    if (pctr && d->dbg_acc != pc_acc_prev) {
      if (d->dbg_acc >= pcfrom) std::fprintf(pctr, "%08x\n", (unsigned)d->dbg_ip);
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
        g_sw_n < 30) {
      std::printf("      SET WR %08x be=%x %08x  (insn %u ip %08x)\n",
                  d->obs_bus_addr, d->obs_bus_be, d->obs_bus_wdata,
                  (unsigned)d->dbg_acc, (unsigned)d->dbg_ip);
      ++g_sw_n;
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
    std::printf("\n  REPRODUCED: the i960 never read the block window, which is\n"
                "  what the board shows. The fault is in this composition and can\n"
                "  now be stepped.\n");
    fail = 1;
  } else {
    std::printf("\n  the copy ran (first window read at instruction %llu).\n"
                "  This harness does NOT reproduce the hardware fault.\n",
                (unsigned long long)first_win_rd);
  }
  if (out) { std::fclose(out); std::printf("  PC stream written to %s\n", outfile); }
  if (charstream) { std::fclose(charstream); std::printf("  char write stream written\n"); }
  std::printf("%s\n", fail ? "FAIL" : "PASS");
  delete d;
  return fail;
}
