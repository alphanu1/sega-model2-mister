// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// The CPU bridge against the REAL SDRAM controller.
//
// Both blocks pass their own testbenches. On hardware the i960 reads ZERO from
// a ROM that is demonstrably loaded -- the same words read correctly through a
// different port. The composition is what ships and the composition is what had
// never been tested: the bridge's own testbench talks to a hand-written model
// of the controller, written by the same hand, on the same day, as the bridge.
//
// It replays the i960's actual boot walk -- mem[0], mem[4], mem[12] -- against
// the real controller and a device model, with the ROM put in through the
// loader's write port rather than poked into an array.

#include "Vm2_cpu_sdram_harness.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>
#include <cstring>

static Vm2_cpu_sdram_harness *dut;

// 25 MHz and 40 MHz from a 200 MHz tick.
static const int CPU_DIV = 8, MEM_DIV = 5;
static uint64_t tk = 0;

// Ports 2 and 3 hammering away, as they do on the board: the self-test loops
// on port 2 forever and the character fetch runs port 3 every line. Both read
// addresses far from the CPU's, so any data that turns up on port 0 from here
// is unmistakable.
static bool competing = true;
static uint32_t p2a = 0x100000, p3a = 0x200000;

static void drive_competitors() {
  if (!competing) { dut->p2_req = 0; dut->p3_req = 0; return; }
  if (dut->p2_ack) { dut->p2_req = 0; p2a = 0x100000 + ((p2a + 4) & 0xfff); }
  else if (!dut->p2_req) { dut->p2_addr = p2a; dut->p2_req = 1; }
  if (dut->p3_ack) { dut->p3_req = 0; p3a = 0x200000 + ((p3a + 4) & 0xfff); }
  else if (!dut->p3_req) { dut->p3_addr = p3a; dut->p3_req = 1; }
}

static void step() {
  if ((tk % MEM_DIV) == 0) drive_competitors();
  if ((tk % CPU_DIV) == 0) { dut->clk_cpu = 0; dut->eval(); }
  if ((tk % MEM_DIV) == 0) { dut->clk_mem = 0; dut->eval(); }
  ++tk;
  if ((tk % CPU_DIV) == 0) { dut->clk_cpu = 1; dut->eval(); }
  if ((tk % MEM_DIV) == 0) { dut->clk_mem = 1; dut->eval(); }
}

static bool cpu_read(uint32_t addr, uint32_t *out) {
  dut->bus_req = 1; dut->bus_we = 0; dut->bus_addr = addr; dut->bus_be = 0xf;
  for (int g = 0; g < 200000; ++g) {
    step();
    if (dut->bus_ack) {
      *out = dut->bus_rdata;
      dut->bus_req = 0;
      for (int k = 0; k < CPU_DIV * 4; ++k) step();
      return true;
    }
  }
  dut->bus_req = 0;
  return false;
}

static int write_acks = 0;
static int fails_byte = 0;
static void sd_write(uint32_t word_addr, uint16_t data) {
  dut->wr_req = 1; dut->wr_addr = word_addr; dut->wr_din = data;
  bool acked = false;
  for (int g = 0; g < 100000; ++g) { step(); if (dut->wr_ack) { acked = true; break; } }
  if (acked) ++write_acks;
  dut->wr_req = 0;
  // The loader pulses req and waits for the ack EDGE (study R30), so the ack
  // must be allowed to fall before the next one.
  for (int g = 0; g < 100000 && dut->wr_ack; ++g) step();
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vm2_cpu_sdram_harness;
  dut->rst_n = 0; dut->bus_req = 0; dut->wr_req = 0;
  dut->p2_req = 0; dut->p3_req = 0;
  for (int i = 1; i < argc; i++)
    if (!std::strcmp(argv[i], "+solo")) competing = false;
  for (int i = 0; i < 400; ++i) step();
  dut->rst_n = 1;

  std::printf("m2_cpu_bridge against the real m2_sdram\n");
  for (int g = 0; g < 400000 && !dut->mem_ready; ++g) step();
  std::printf("  controller ready after %llu ticks\n", (unsigned long long)tk);

  // Daytona's boot record, as the interleaved image holds it:
  //   word0..1 = 0000 0000   SAT  = 00000000
  //   word2..3 = 00c0 0000   PRCB = 000000c0
  //   word6..7 = 0860 0000   IP   = 00000860
  const uint16_t rom[10] = { 0x0000, 0x0000, 0x00c0, 0x0000, 0x0000,
                             0x0000, 0x0860, 0x0000, 0xf6e0, 0xffff };
  { const bool save = competing; competing = false;
    for (uint32_t w = 0; w < 10; ++w) sd_write(w, rom[w]);
    competing = save; }
  std::printf("  boot record written: %d of 10 writes acked\n", write_acks);

  // ISOLATE THE SIDE. Write and read back through the SAME port -- the CPU's --
  // into work RAM, which is writable. If this works, port 0 reads and writes
  // are both fine and the fault is in the loader's write port or its
  // interaction with them. If it fails, the read path is the problem.
  {
    dut->bus_req = 1; dut->bus_we = 1; dut->bus_addr = 0x00500010u;
    dut->bus_wdata = 0xdeadbeefu; dut->bus_be = 0xf;
    for (int g = 0; g < 200000; ++g) { step(); if (dut->bus_ack) break; }
    dut->bus_req = 0;
    for (int k = 0; k < CPU_DIV * 4; ++k) step();
    uint32_t back = 0;
    cpu_read(0x00500010u, &back);
    std::printf("  CPU write/read same port: got=%08x want=deadbeef  %s\n",
                back, back == 0xdeadbeefu ? "ok" : "MISMATCH");
  }

  // BYTE STORES MUST NOT SMEAR, which on hardware they do.
  //
  // The board's loop count at 0x501084 reads back 0x27272727 where it should be
  // 0x00000027 -- the byte 0x27 in all four lanes -- and that turns a 39-pass
  // loop into a 656-million-pass one, which is 85 minutes. The i960 replicates a
  // stored byte across the word and relies on the ENABLES to pick a lane, so
  // this replays exactly that: zero the word, store one byte with one enable,
  // read it back.
  //
  // Every lane is tested because a fault that drops enables entirely and one
  // that mishandles the high half look identical from lane 0 alone.
  {
    const uint32_t A = 0x00501084u;
    struct { uint32_t be, wdat, want; } BT[] = {
      { 0x1, 0x27272727u, 0x00000027u },
      { 0x2, 0x27272727u, 0x00002700u },
      { 0x4, 0x27272727u, 0x00270000u },
      { 0x8, 0x27272727u, 0x27000000u },
    };
    for (auto &b : BT) {
      // Zero the whole word first, exactly as the game does.
      dut->bus_req = 1; dut->bus_we = 1; dut->bus_addr = A;
      dut->bus_wdata = 0; dut->bus_be = 0xf;
      for (int g = 0; g < 200000; ++g) { step(); if (dut->bus_ack) break; }
      dut->bus_req = 0;
      for (int k = 0; k < CPU_DIV * 4; ++k) step();
      // Then the byte store.
      dut->bus_req = 1; dut->bus_we = 1; dut->bus_addr = A;
      dut->bus_wdata = b.wdat; dut->bus_be = b.be;
      for (int g = 0; g < 200000; ++g) { step(); if (dut->bus_ack) break; }
      dut->bus_req = 0;
      for (int k = 0; k < CPU_DIV * 4; ++k) step();
      uint32_t back = 0;
      cpu_read(A, &back);
      const bool ok = (back == b.want);
      std::printf("  byte store be=%x: got=%08x want=%08x  %s\n",
                  b.be, back, b.want, ok ? "ok" : "SMEARED");
      if (!ok) ++fails_byte;
    }
  }

  struct { uint32_t addr, want; const char *name; } T[] = {
    { 0,  0x00000000u, "SAT  mem[0]"  },
    { 4,  0x000000c0u, "PRCB mem[4]"  },
    { 12, 0x00000860u, "IP   mem[12]" },
    { 16, 0xfffff6e0u, "     mem[16]" },
  };
  int fails = fails_byte;
  for (auto &t : T) {
    uint32_t got = 0;
    if (!cpu_read(t.addr, &got)) {
      std::printf("  %s  NO ACK -- the bridge hung\n", t.name);
      ++fails; continue;
    }
    const bool ok = (got == t.want);
    std::printf("  %s  got=%08x want=%08x  %s\n", t.name, got, t.want, ok ? "ok" : "MISMATCH");
    if (!ok) ++fails;
  }
  std::printf("  last sd_addr=%08x last sd_dout=%08x reads=%u\n",
              dut->dbg_last_addr, dut->dbg_last_dout, dut->dbg_reads);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  return fails ? 1 : 0;
}
