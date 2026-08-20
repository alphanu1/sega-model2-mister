// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// Turn the clock; the bus lives in sim/sound/fx68k_harness.sv. See that file
// for what the program is and why the check is a computed value at a chosen
// address rather than "it did not crash".
//
// $readmemb in fx68k resolves relative to the WORKING DIRECTORY, so this is run
// from third_party/fx68k. A microcode ROM that silently fails to load leaves
// the sequencer full of zeros, which looks exactly like a core that does not
// work -- so the run asserts it read the vector before it asserts anything else.

#include "Vfx68k_harness.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>

static Vfx68k_harness *dut;
static uint64_t ticks = 0;

static void tick() {
  dut->clk = 0; dut->eval();
  dut->clk = 1; dut->eval();
  ++ticks;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  uint64_t max_ticks = 400000;
  for (int i = 1; i < argc; i++)
    if (!std::strncmp(argv[i], "+ticks=", 7))
      max_ticks = std::strtoull(argv[i] + 7, nullptr, 10);

  dut = new Vfx68k_harness;
  dut->clk = 0; dut->rst = 1;
  for (int i = 0; i < 64; i++) tick();
  dut->rst = 0;

  uint64_t first_write = 0;
  while (ticks < max_ticks) {
    tick();
    if (!first_write && dut->writes) first_write = ticks;
    if (dut->probe == 0x1234) break;
  }

  std::printf("  ticks %llu, bus cycles %u, writes %u, last address %06x\n",
              (unsigned long long)ticks, dut->bus_cycles, dut->writes,
              unsigned(dut->eab_o) << 1);
  std::printf("  mem[0x100] = %04x (want 1234)\n", dut->probe);

  int fail = 0;
  if (dut->bus_cycles == 0) {
    std::printf("  FAIL: no bus cycles at all -- the core never fetched.\n");
    std::printf("        Check microrom.mem/nanorom.mem are in the working\n");
    std::printf("        directory; $readmemb is silent when they are not.\n");
    fail = 1;
  } else if (dut->writes == 0) {
    std::printf("  FAIL: it fetched (%u cycles) but never wrote. It is\n"
                "        executing something, but not this program.\n",
                dut->bus_cycles);
    fail = 1;
  } else if (dut->probe != 0x1234) {
    std::printf("  FAIL: wrote %u times but 0x1234 never reached 0x100.\n",
                dut->writes);
    fail = 1;
  } else {
    std::printf("  fx68k EXECUTES: reset vector read, immediate decoded,\n"
                "  absolute-long write completed (first write at tick %llu).\n",
                (unsigned long long)first_write);
  }
  std::printf("%s\n", fail ? "FAIL" : "PASS");
  delete dut;
  return fail;
}
