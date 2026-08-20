// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// The CPU bridge, against a model of what it is bridging to.
//
// This exists because the bridge is the one new block between two things that
// are already verified -- an i960 that matches MAME for 803,355 instructions
// and a renderer that matches it pixel for pixel -- and a fault here presents
// as neither of them working. On hardware that is a black screen and no
// information at all.
//
// WHAT IT CHECKS
//
//   * every region decodes to the right target and the right word address
//   * a 32-bit access becomes two 16-bit transactions, low half first
//   * the domain crossing fires ONCE per access, at 25 MHz into 40 MHz
//   * writes to ROM regions are dropped rather than performed
//   * unmapped accesses are counted, not silently answered
//
// The two clocks are driven at their real ratio -- 25 and 40 MHz -- rather than
// at a convenient integer one. A handshake that only works when the clocks
// divide evenly is a handshake that works in the testbench.

#include "Vm2_cpu_bridge.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <map>
#include <vector>

static Vm2_cpu_bridge *dut;

// The far side: SDRAM as a sparse map of 16-bit words, plus tile RAM, palette
// and the translation table as arrays.
static std::map<uint32_t, uint16_t> sdram;
static std::vector<uint16_t> tram(32768, 0), pal(4096, 0);
static std::vector<uint8_t>  xlat(96, 0);
static std::map<uint32_t, uint32_t> io_regs;

static uint64_t fails = 0, checks = 0;

// 25 MHz and 40 MHz from a common 200 MHz tick: 8 and 5 ticks per period.
static const int CPU_DIV = 8, MEM_DIV = 5;
static uint64_t tk = 0;

static void step() {
  const bool cpu_edge = (tk % CPU_DIV) == 0;
  const bool mem_edge = (tk % MEM_DIV) == 0;

  if (mem_edge) {
    // SDRAM model: single-word port. ACK IS HELD FOR ACK_HOLD CYCLES, which is
    // 2 -- m2_sdram's own parameter, "requesters on a slower synchronous clock
    // must see exactly one rising edge with ack high".
    //
    // The first version of this model acked for ONE cycle, and that is why it
    // passed a bridge that samples an ack still held from the previous
    // transaction. A model that is easier than the thing it models does not
    // test the thing it models.
    static bool pend = false;
    static int  ackhold = 0;
    static uint32_t pa = 0; static bool pw = false; static uint16_t pd = 0; static uint8_t pb = 3;
    if (ackhold > 0) { --ackhold; dut->sd_ack = 1; }
    else dut->sd_ack = 0;
    if (pend && ackhold == 0) {
      if (pw) {
        uint16_t cur = sdram.count(pa) ? sdram[pa] : 0xffff;
        if (pb & 1) cur = uint16_t((cur & 0xff00) | (pd & 0x00ff));
        if (pb & 2) cur = uint16_t((cur & 0x00ff) | (pd & 0xff00));
        sdram[pa] = cur;
      } else {
        // A FOUR-WORD BURST, because that is what port 0 now does -- blen()
        // gives ports 0 to 3 four words. Returning one and zero-filling the
        // rest is what this model used to do, and it is how a model drifts
        // from the thing it models: the bridge reads p_dout[31:0] and would
        // have seen a permanently zero high half.
        uint64_t d = 0;
        for (int w = 0; w < 4; ++w) {
          const uint32_t a = pa + uint32_t(w);
          const uint64_t v = sdram.count(a) ? sdram[a] : 0xffffu;
          d |= v << (16 * w);
        }
        dut->sd_dout = d;
      }
      dut->sd_ack = 1;
      ackhold = 1;                 // this cycle plus one more = ACK_HOLD of 2
      pend = false;
    } else if (dut->sd_req && ackhold == 0) {
      pa = dut->sd_addr; pw = dut->sd_we; pd = dut->sd_din; pb = dut->sd_be;
      pend = true;
    }
    // On-chip arrays: REGISTERED reads, as M10K is.
    dut->oc_tram_q = tram[dut->oc_addr & 0x7fff];
    dut->oc_pal_q  = pal[dut->oc_addr & 0xfff];
    if (dut->oc_tram_we) tram[dut->oc_addr & 0x7fff] = dut->oc_din;
    if (dut->oc_pal_we)  pal[dut->oc_addr & 0xfff]   = dut->oc_din;
    if (dut->oc_xlat_we) xlat[dut->oc_xlat_addr % 96] = dut->oc_xlat_din;
    if (dut->io_sel) {
      if (dut->io_we) io_regs[dut->io_addr] = dut->io_wdata;
    }
    dut->io_rdata = io_regs.count(dut->io_addr) ? io_regs[dut->io_addr] : 0xa5a50000u;
  }

  if (cpu_edge) { dut->clk_cpu = 0; dut->eval(); }
  if (mem_edge) { dut->clk_mem = 0; dut->eval(); }
  ++tk;
  if ((tk % CPU_DIV) == 0) { dut->clk_cpu = 1; dut->eval(); }
  if ((tk % MEM_DIV) == 0) { dut->clk_mem = 1; dut->eval(); }
}

// One CPU access, driven the way i960_top drives it: raise req, hold until ack.
static bool access(bool we, uint32_t addr, uint32_t wdata, uint8_t be, uint32_t *out) {
  dut->bus_req = 1; dut->bus_we = we; dut->bus_addr = addr;
  dut->bus_wdata = wdata; dut->bus_be = be;
  for (int g = 0; g < 4000; ++g) {
    step();
    if (dut->bus_ack) {
      if (out) *out = dut->bus_rdata;
      dut->bus_req = 0;
      for (int k = 0; k < CPU_DIV * 3; ++k) step();
      return true;
    }
  }
  dut->bus_req = 0;
  return false;
}

static void expect(const char *what, uint32_t got, uint32_t want) {
  ++checks;
  if (got != want) {
    if (fails < 20) std::printf("  MISMATCH %-34s got=%08x want=%08x\n", what, got, want);
    ++fails;
  }
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vm2_cpu_bridge;

  dut->rst_n_cpu = 0; dut->rst_n_mem = 0;
  dut->bus_req = 0; dut->sd_ack = 0; dut->io_rdata = 0;
  dut->base_prog = 0x00000; dut->base_data = 0x40000;
  dut->base_work = 0x20000; dut->base_board = 0x30000; dut->base_char = 0x38000;
  for (int i = 0; i < 200; ++i) step();
  dut->rst_n_cpu = 1; dut->rst_n_mem = 1;
  for (int i = 0; i < 200; ++i) step();

  std::printf("m2_cpu_bridge\n");

  // ---- work RAM: write then read back, and check it landed as two words ----
  {
    uint32_t v = 0;
    access(true,  0x00500010u, 0xdeadbeefu, 0xf, nullptr);
    // Offset WITHIN the region, not the absolute address >> 1 -- the bridge
    // masks to the region size, which is what makes the same SDRAM base
    // usable for a 1 MB window.
    expect("work RAM low word",  sdram[0x20000 + ((0x00500010u & 0xfffffu) >> 1)],     0xbeef);
    expect("work RAM high word", sdram[0x20000 + ((0x00500010u & 0xfffffu) >> 1) + 1], 0xdead);
    access(false, 0x00500010u, 0, 0xf, &v);
    expect("work RAM readback", v, 0xdeadbeefu);
  }

  // ---- program ROM is READ ONLY: the write must not land ----
  {
    const uint32_t wa = 0x00000000u + ((0x00001000u & 0x1fffffu) >> 1);
    sdram[wa] = 0x1234; sdram[wa + 1] = 0x5678;
    uint32_t v = 0;
    access(true,  0x00001000u, 0xffffffffu, 0xf, nullptr);
    expect("ROM write dropped (low)",  sdram[wa],     0x1234);
    expect("ROM write dropped (high)", sdram[wa + 1], 0x5678);
    access(false, 0x00001000u, 0, 0xf, &v);
    expect("ROM readback", v, 0x56781234u);
  }

  // ---- model2o ROM MIRROR at 0x00220000 reads the program ROM's second half --
  {
    const uint32_t wa = 0x00000000u + 0x10000 + ((0x00227cf0u & 0x1ffffu) >> 1);
    sdram[wa] = 0xcafe; sdram[wa + 1] = 0xf00d;
    uint32_t v = 0;
    access(false, 0x00227cf0u, 0, 0xf, &v);
    expect("model2o ROM mirror", v, 0xf00dcafeu);
  }

  // ---- board RAM is WRITABLE and does not alias the mirror ----
  {
    uint32_t v = 0;
    access(true,  0x00200004u, 0x11112222u, 0xf, nullptr);
    access(false, 0x00200004u, 0, 0xf, &v);
    expect("board RAM readback", v, 0x11112222u);
    expect("board RAM did not touch the mirror",
           sdram.count(0x00000000u + 0x10000 + 2) ? 1u : 0u, 0u);
  }

  // ---- tile RAM and palette, on chip ----
  {
    uint32_t v = 0;
    access(true,  0x01000008u, 0x00110022u, 0xf, nullptr);
    expect("tile RAM word 4", tram[4], 0x0022);
    expect("tile RAM word 5", tram[5], 0x0011);
    access(false, 0x01000008u, 0, 0xf, &v);
    expect("tile RAM readback", v, 0x00110022u);

    access(true,  0x01800008u, 0x00330044u, 0xf, nullptr);
    expect("palette word 4", pal[4], 0x0044);
    access(false, 0x01800008u, 0, 0xf, &v);
    expect("palette readback", v, 0x00330044u);
  }

  // ---- char RAM lands in SDRAM at its own base ----
  {
    access(true, 0x01080020u, 0x99887766u, 0xf, nullptr);
    expect("char RAM low word", sdram[0x38000 + ((0x01080020u & 0x7ffffu) >> 1)], 0x7766);
  }

  // ---- main_data, and its alias at 0x06000000 ----
  {
    sdram[0x40000 + ((0x02000100u & 0x1ffffffu) >> 1)] = 0x0f0f;
    uint32_t v = 0;
    access(false, 0x02000100u, 0, 0xf, &v);
    expect("main_data low half", v & 0xffffu, 0x0f0fu);
    sdram[0x40000 + 0x800000 + ((0x06000040u & 0xffffffu) >> 1)] = 0x7070;
    access(false, 0x06000040u, 0, 0xf, &v);
    expect("main_data alias low half", v & 0xffffu, 0x7070u);
  }

  // ---- the translation table ----
  {
    access(true, 0x01810004u, 0x000000c3u, 0xf, nullptr);
    expect("xlat entry 2", xlat[2], 0xc3);
  }

  // ---- I/O reaches the register file and comes back ----
  {
    uint32_t v = 0;
    io_regs[0x00980004u] = 1;
    access(false, 0x00980004u, 0, 0xf, &v);
    expect("fifo_control read", v, 1u);
    access(true, 0x00e80004u, 0x00000001u, 0xf, nullptr);
    expect("irq_enable write", io_regs[0x00e80004u], 1u);
  }

  // ---- an unmapped access is counted, not silently answered ----
  {
    const uint32_t before = dut->dbg_unmapped;
    uint32_t v = 0;
    access(false, 0x0f000000u, 0, 0xf, &v);
    expect("unmapped counted", dut->dbg_unmapped, before + 1);
  }

  // ---- THE CROSSING FIRES ONCE. Hammer it and check the counters agree with
  // the number of accesses actually issued -- a handshake that double-fires
  // shows up here and nowhere else until it deadlocks on hardware.
  {
    const uint32_t r0 = dut->dbg_cpu_reads, w0 = dut->dbg_cpu_writes;
    uint32_t v = 0;
    for (int i = 0; i < 64; ++i) {
      access(true,  0x00500100u + uint32_t(i * 4), 0x1000u + uint32_t(i), 0xf, nullptr);
      access(false, 0x00500100u + uint32_t(i * 4), 0, 0xf, &v);
      expect("hammer readback", v, 0x1000u + uint32_t(i));
    }
    expect("write count exact", dut->dbg_cpu_writes - w0, 64);
    expect("read  count exact", dut->dbg_cpu_reads  - r0, 64);
  }

  std::printf("  probe6=%08x probe2=%08x (EEEEEEEE = never read)\n",
              dut->dbg_probe6, dut->dbg_probe2);
  std::printf("  %llu checks, %llu mismatches, %llu unmapped seen\n",
              (unsigned long long)checks, (unsigned long long)fails,
              (unsigned long long)dut->dbg_unmapped);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  return fails ? 1 : 0;
}
