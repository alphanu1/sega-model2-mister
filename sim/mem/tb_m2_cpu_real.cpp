// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// The real i960 running the real Daytona program ROM through the real bridge
// and the real SDRAM controller. See m2_cpu_real_harness.sv for why.
//
// WHAT THIS CHECKS. Not values -- the ROM's arithmetic is tb_i960_rom's job --
// but that the CPU KEEPS GOING. The two changes this exists for both failed
// on hardware as the machine stopping: black, or locked before the first
// frame. So the checks are (1) the CPU retires N instructions without halting
// or trapping, (2) it never goes quiet for long, and (3) the SEQUENCE of
// instruction pointers it retires is the same as it was -- a change to the
// memory path that alters WHEN the CPU is answered must not alter WHAT it
// executes, and a hash over the retired-IP stream says so in one number.
//
// Run it twice, before and after a change, and compare the hash. M2_HASH_OUT
// writes it to a file so a Makefile or a shell can diff them.
//
// NO ROM BYTE ENTERS THE REPOSITORY. Skips, as tb_i960_rom does, when the set
// is not under M2_ROMPATH (default ~/roms/Model2). A missing ROM is not a
// broken build.

#include "Vm2_cpu_real_harness.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <string>
#include <vector>

static Vm2_cpu_real_harness *dut;
static int checks = 0, fails = 0;
#define CHECK(c, ...) do { ++checks; if (!(c)) { ++fails; std::printf("  FAIL: " __VA_ARGS__); std::printf("\n"); } } while (0)

// Same clock ratio as tb_m2_cpu_sdram, so the bridge's crossing is exercised
// the way the composition test already exercises it.
static const int CPU_DIV = 8, MEM_DIV = 5;
static unsigned long long tk = 0;

// R529: COMPETING SDRAM TRAFFIC, as tb_m2_cpu_sdram has it. On the board ports
// 2 and 3 are never idle -- the self-test loops and the character fetch runs
// every line -- and a CPU access waits its turn behind them. M2_COMPETE=1.
static bool competing = false;
static uint32_t p2a = 0x100000, p3a = 0x200000;
static void drive_traffic() {
  if (!competing) { dut->p2_req = 0; dut->p3_req = 0; return; }
  if (dut->p2_ack) { dut->p2_req = 0; p2a = 0x100000 + ((p2a + 4) & 0xfff); }
  else if (!dut->p2_req) { dut->p2_addr = p2a; dut->p2_req = 1; }
  if (dut->p3_ack) { dut->p3_req = 0; p3a = 0x200000 + ((p3a + 4) & 0xfff); }
  else if (!dut->p3_req) { dut->p3_addr = p3a; dut->p3_req = 1; }
}

static void step() {
  ++tk;
  drive_traffic();
  if ((tk % CPU_DIV) == 0) { dut->clk_cpu = 0; dut->eval(); }
  if ((tk % MEM_DIV) == 0) { dut->clk_mem = 0; dut->eval(); }
  if ((tk % CPU_DIV) == 0) { dut->clk_cpu = 1; dut->eval(); }
  if ((tk % MEM_DIV) == 0) { dut->clk_mem = 1; dut->eval(); }
}

static bool load_file(const std::string &path, std::vector<uint8_t> &out) {
  FILE *f = std::fopen(path.c_str(), "rb");
  if (!f) return false;
  std::fseek(f, 0, SEEK_END); long n = std::ftell(f); std::fseek(f, 0, SEEK_SET);
  if (n <= 0) { std::fclose(f); return false; }
  out.resize(size_t(n));
  const size_t got = std::fread(out.data(), 1, size_t(n), f);
  std::fclose(f);
  return got == size_t(n);
}

// One 16-bit word into the controller through the preload port.
static bool preload(uint32_t word_addr, uint16_t data) {
  dut->wr_req = 1; dut->wr_addr = word_addr; dut->wr_din = data;
  bool acked = false;
  for (int g = 0; g < 100000; ++g) { step(); if (dut->wr_ack) { acked = true; break; } }
  dut->wr_req = 0;
  for (int g = 0; g < 100000 && dut->wr_ack; ++g) step();
  return acked;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vm2_cpu_real_harness;

  // ---------------------------------------------------------------- the ROM
  const char *rp = std::getenv("M2_ROMPATH");
  const std::string base = rp ? rp
    : (std::string(std::getenv("HOME") ? std::getenv("HOME") : ".") + "/roms/Model2");
  const std::string dir = base + "/daytona93/";
  std::vector<uint8_t> lo, hi;
  if (!load_file(dir + "epr-16530a.12", lo) || !load_file(dir + "epr-16531a.13", hi)) {
    std::printf("m2_cpu_real: daytona93 program ROMs not found under %s\n", dir.c_str());
    std::printf("SKIP (no ROMs; set M2_ROMPATH to a directory holding daytona93/)\n");
    return 0;
  }
  if (lo.size() != 0x20000 || hi.size() != 0x20000) {
    std::printf("unexpected program ROM sizes %zu/%zu\n", lo.size(), hi.size());
    return 1;
  }

  // ------------------------------------------------------------- bring-up
  dut->clk_cpu = 0; dut->clk_mem = 0; dut->rst_n = 0; dut->cpu_rst_n = 0;
  dut->wr_req = 0; dut->wr_addr = 0; dut->wr_din = 0;
  dut->p2_req = 0; dut->p3_req = 0;
  competing = std::getenv("M2_COMPETE") && atoi(std::getenv("M2_COMPETE"));
  for (int i = 0; i < 64; ++i) step();
  dut->rst_n = 1;
  { long g = 0; while (!dut->mem_ready && g++ < 4000000) step(); }
  CHECK(dut->mem_ready, "controller never became ready");

  // ROM_LOAD32_WORD: lo supplies bytes 0,1 of each dword and hi bytes 2,3. In
  // 16-bit SDRAM words that is word 2w = lo word w, word 2w+1 = hi word w, and
  // base_prog is 0 in the harness so CPU byte address 0 is SDRAM word 0.
  const uint32_t NW = 0x10000;            // 64K dwords = 256 KB of program ROM
  uint32_t loaded = 0;
  for (uint32_t w = 0; w < NW; ++w) {
    const uint16_t l = uint16_t(lo[w*2] | (lo[w*2+1] << 8));
    const uint16_t h = uint16_t(hi[w*2] | (hi[w*2+1] << 8));
    if (preload(2*w, l)) ++loaded;
    if (preload(2*w + 1, h)) ++loaded;
  }
  CHECK(loaded == 2*NW, "preload: %u of %u words acknowledged", loaded, 2*NW);
  std::printf("m2_cpu_real: %u KB of program ROM in SDRAM after %llu ticks\n",
              loaded / 512, tk);

  // --------------------------------------------------------------- the run
  const long N = std::getenv("M2_INSNS") ? atol(std::getenv("M2_INSNS")) : 100000;
  const unsigned long long QUIET_LIMIT = 400000;   // ticks with no retirement
  dut->cpu_rst_n = 1;

  uint32_t last_acc = dut->dbg_acc_cnt;
  unsigned long long t0 = tk, last_change = tk, worst_quiet = 0;
  uint64_t hash = 1469598103934665603ULL;          // FNV-1a over retired IPs
  uint32_t first_ip = 0; bool got_first = false;
  long retired = 0;

  while (retired < N && !dut->halted && !dut->trap) {
    step();
    const uint32_t acc = dut->dbg_acc_cnt;
    if (acc != last_acc) {
      retired += int32_t(acc - last_acc);
      last_acc = acc;
      const uint32_t ip = dut->dbg_ip;
      if (!got_first) { first_ip = ip; got_first = true; }
      hash ^= ip; hash *= 1099511628211ULL;
      const unsigned long long quiet = tk - last_change;
      if (quiet > worst_quiet) worst_quiet = quiet;
      last_change = tk;
    } else if (tk - last_change > QUIET_LIMIT) {
      break;                                   // stopped: fall through to the checks
    }
  }
  const unsigned long long cycles = (tk - t0) / CPU_DIV;

  std::printf("  retired %ld instructions in %llu CPU cycles -- %.2f CPI\n",
              retired, cycles, retired ? double(cycles) / double(retired) : 0.0);
  std::printf("  first IP %08x  last IP %08x  longest quiet %llu ticks  trace hash %016llx\n",
              first_ip, dut->dbg_ip, worst_quiet, (unsigned long long)hash);
  if (const char *ho = std::getenv("M2_HASH_OUT")) {
    if (FILE *f = std::fopen(ho, "w")) { std::fprintf(f, "%016llx %ld\n", (unsigned long long)hash, retired); std::fclose(f); }
  }

  // THE CHECKS ARE THE SYMPTOMS THE BOARD SHOWED.
  CHECK(!dut->halted, "the CPU halted at IP %08x", dut->dbg_ip);
  CHECK(!dut->trap,   "the CPU trapped at IP %08x", dut->dbg_ip);
  CHECK(retired >= N, "the CPU stopped: %ld of %ld instructions, quiet for %llu ticks at IP %08x "
                      "(bus_req=%d we=%d ack=%d addr=%08x)",
        retired, N, tk - last_change, dut->dbg_ip,
        dut->bus_req, dut->bus_we, dut->bus_ack, dut->bus_addr);
  CHECK(got_first && first_ip == 0x00000860u, "boot IP was %08x, the ROM's record says 00000860", first_ip);

  std::printf("m2_cpu_real: checks=%d fails=%d\n", checks, fails);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete dut;
  return fails ? 1 : 0;
}
