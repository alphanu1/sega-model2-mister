// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The hardware path on a desk: ioctl -> m2_rom_loader -> m2_sdram -> readback.
//
// It feeds the FIRST WORDS OF THE REAL DAYTONA STREAM, as the MRA interleaves
// them, and asserts the two signatures the overlay prints. The board reported
// 000000FF and 00000000 where these say FFFFF6E0 and 00000860.

#include "Vm2_romload_harness.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>
#include <cstdlib>

static Vm2_romload_harness *dut;
static uint64_t fails = 0, checks = 0;

static int nwr = 0;
static long req_cyc = 0, ack_cyc = 0, both_cyc = 0;
static int nrd = 0, ack_prev = 0;
static void tick() {
  dut->clk = 0; dut->eval();
  dut->clk = 1; dut->eval();
  // Sample AFTER the edge. Sampling before it reads the pre-edge values and
  // showed nothing at all while the device model was serving 16 writes.
  // One access is req & ack, never the request level.
  if (dut->dbg_rb_ack && !ack_prev && nrd < 8) {
    std::printf("    READ ack: addr %u  dout %016llx  state %d\n",
                (unsigned)dut->dbg_rb_addr,
                (unsigned long long)dut->dbg_rb_dout, dut->rb_state);
    ++nrd;
  }
  ack_prev = dut->dbg_rb_ack;
  if (dut->dbg_wr_req) ++req_cyc;
  if (dut->dbg_wr_ack) ++ack_cyc;
  if (dut->dbg_wr_req && dut->dbg_wr_ack) ++both_cyc;
  // Log on the REQUEST. The loader pulses it for one cycle and the controller
  // acks two cycles later, so req & ack never coincide on this interface --
  // which is why the first attempt at this log printed nothing at all.
  if (dut->dbg_wr_req && nwr < 20) {
    std::printf("    write %2d: sdram word addr %6u  data %04x\n",
                nwr++, (unsigned)dut->dbg_wr_addr, (unsigned)dut->dbg_wr_din);
  }
}

static void ck(const char *what, uint32_t got, uint32_t want) {
  ++checks;
  if (got != want) {
    std::printf("  MISMATCH %-22s got=%08x want=%08x\n", what, got, want);
    ++fails;
  }
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vm2_romload_harness;

  // epr-16530a.12 / epr-16531a.13 interleaved by the MRA, 16-bit words.
  const std::vector<uint16_t> rom = {
    0x0000, 0x0000, 0x00c0, 0x0000, 0x0000, 0x0000, 0x0860, 0x0000,
    0xf6e0, 0xffff, 0x0000, 0x0000, 0x0000, 0x0000, 0xffff, 0xffff
  };

  // Default 0 = CL+3, which is what the device MODEL wants. The BOARD wants
  // CL+2 (sel 1), because the real device is clocked on the inverse of the
  // controller clock and answers half a period away. Both are exercised below;
  // sel 1 here produces exactly the one-16-bit-word shift the Model 1 core
  // documented seeing on hardware, which is how that claim got corroborated.
  const int sel = (argc > 1) ? atoi(argv[1]) : 0;
  dut->rd_lat_sel = sel;
  dut->rst_n = 0; dut->ioctl_download = 0; dut->ioctl_wr = 0;
  dut->ioctl_index = 0; dut->ioctl_addr = 0; dut->ioctl_dout = 0;
  for (int i = 0; i < 8; i++) tick();
  dut->rst_n = 1;

  for (int g = 0; g < 20000 && !dut->mem_ready; ++g) tick();
  ck("mem_ready", dut->mem_ready, 1);

  // WIDE=1: 16 bits per write, ioctl_addr advancing by TWO. Getting this wrong
  // is the defect this test exists for.
  dut->ioctl_download = 1;
  tick();
  for (size_t i = 0; i < rom.size(); ++i) {
    while (dut->ioctl_wait) tick();          // the loader asks the host to stop
    dut->ioctl_addr = uint32_t(i * 2);
    dut->ioctl_dout = rom[i];
    dut->ioctl_wr   = 1;  tick();
    dut->ioctl_wr   = 0;  tick();
  }
  dut->ioctl_download = 0;
  tick();

  for (int g = 0; g < 200000 && !dut->rom_loaded; ++g) tick();
  ck("rom_loaded", dut->rom_loaded, 1);
  ck("overflow",   dut->overflow, 0);

  // Let the readback FSM run to its final state.
  for (int g = 0; g < 200000 && dut->rb_state != 3; ++g) tick();
  for (int g = 0; g < 200000; ++g) tick();

  std::printf("  rd_lat_sel=%d\n", sel);
  std::printf("  rb_state=%d  rb_w0=%08x  rb_w1=%08x\n",
              dut->rb_state, dut->rb_w0, dut->rb_w1);

  ck("rb_w0 (word 8/9)",  dut->rb_w0, 0xfffff6e0u);
  ck("rb_w1 (word 6/7)",  dut->rb_w1, 0x00000860u);
  ck("device violations", dut->violations, 0);

  std::printf("  wr_req cycles=%ld  wr_ack cycles=%ld  both=%ld\n",
              req_cyc, ack_cyc, both_cyc);
  std::printf("  writes served=%u reads served=%u\n",
              dut->writes_served, dut->reads_served);
  std::printf("  %llu checks, %llu mismatches\n",
              (unsigned long long)checks, (unsigned long long)fails);
  std::printf(fails ? "FAIL\n" : "PASS\n");
  delete dut;
  return fails ? 1 : 0;
}
