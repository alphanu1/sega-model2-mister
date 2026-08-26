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
  d->clk_cpu = 0; d->clk_mem = 0; d->rst_n = 0; d->irq = 0;
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

  // clk_mem is twice clk_cpu, as on the board: 48 and 24 MHz.
  uint64_t mem_edges = 0;
  auto tick = [&]() {
    d->clk_mem = 0; d->eval();
    if ((mem_edges & 1) == 0) d->clk_cpu = 0;
    d->eval();
    d->clk_mem = 1;
    if ((mem_edges & 1) == 0) d->clk_cpu = 1;
    d->eval();
    mem_tick();
    d->eval();
    ++mem_edges;
  };

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
  const char *cf = std::getenv("M2_BOOT_CYC");
  const uint32_t cyc_from = cf ? uint32_t(std::strtoul(cf, nullptr, 10)) : 0;
  int n_cyc = 0;

  while (d->dbg_acc < max_instr) {
    tick();
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

    // THE COPY LOOP'S OWN BUS TRAFFIC. ldq/stq are 16-byte accesses, which the
    // i960 issues as four back-to-back 32-bit ones with bus_req HELD and the
    // address moving on the acknowledge -- study R34. That is the pattern the
    // bridge finds hardest and the one nothing else exercises.
    if (bus_from && d->dbg_acc >= bus_from && d->obs_bus_ack && !ack_prev
        && n_bus < 80) {
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
  std::printf("%s\n", fail ? "FAIL" : "PASS");
  delete d;
  return fail;
}
