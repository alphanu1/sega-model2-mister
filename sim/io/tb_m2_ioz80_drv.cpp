// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R966: m2_ioz80's drive board outputs (drv_cmd, drv_stb) with tv80 running
// the very instruction EPR-14869C uses -- `ld (iy+$04),e` (FD 73 04) with
// iy = 0x8000, at 0x01B2 -- in a loop beside writes that must NOT strobe:
// the direction register (`ld (iy+$08),$4E`, the next instruction in the
// firmware), PF, PA, work RAM 0x4004, and 0x8014 / 0x9004 / 0xC004 (0x8004's
// low bits elsewhere). Each pass writes PE with a new e, so every strobe must
// carry exactly the next value and come once per pass.
//
// Not the firmware itself: tb_m2_ioz80's harness does not reach the
// firmware's main loop without the game's side of the DPRAM dialogue (it
// spins in its DPRAM routine at 0x0815 at 40M clocks, at 47ad2e2 as before
// this change), and the loop's PE write only runs when the game raises DPRAM
// 0x20. The program below is ROM-free, so this runs in `make test`.
#include "Vm2_ioz80_harness.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <vector>

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  auto* d = new Vm2_ioz80_harness;
  const std::vector<uint8_t> prog = {
    0xF3,                         // 0000 di
    0x31, 0x00, 0x60,             // 0001 ld sp,$6000
    0xFD, 0x21, 0x00, 0x80,       // 0004 ld iy,$8000
    0x1E, 0x00,                   // 0008 ld e,$00
    0xFD, 0x73, 0x04,             // 000A loop: ld (iy+$04),e   PE: strobe, carries e
    0xFD, 0x36, 0x08, 0x4E,       // 000D ld (iy+$08),$4E       DIR
    0xFD, 0x73, 0x05,             // 0011 ld (iy+$05),e         PF
    0xFD, 0x73, 0x00,             // 0014 ld (iy+$00),e         PA
    0x7B,                         // 0017 ld a,e
    0x32, 0x04, 0x40,             // 0018 ld ($4004),a          work RAM
    0x32, 0x14, 0x80,             // 001B ld ($8014),a
    0x32, 0x04, 0x90,             // 001E ld ($9004),a
    0x32, 0x04, 0xC0,             // 0021 ld ($C004),a
    0x1C,                         // 0024 inc e
    0x18, 0xE3,                   // 0025 jr loop (0x0027 - 0x1D = 0x000A)
  };
  std::vector<uint8_t> fw(16384, 0x00);
  for (size_t i = 0; i < prog.size(); i++) fw[i] = prog[i];

  d->type2 = 0; d->in0 = 0xff; d->in1 = 0x8f; d->in2 = 0xff;
  d->adc0 = 0x80; d->adc1 = 0x20; d->adc2 = 0x20; d->adc3 = 0xff;
  d->dsw1 = d->dsw2 = d->dsw3 = 0xff;
  d->g_we = 0; d->g_addr = 0; d->g_wdata = 0;
  uint64_t cyc = 0;
  auto tick = [&]() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); cyc++; };

  d->rst_n = 0; d->fw_we = 0;
  for (int i = 0; i < 4; ++i) tick();
  for (int a = 0; a < 8192; ++a) { d->fw_we = 1; d->fw_addr = a; d->fw_data = fw[a * 2] | (fw[a * 2 + 1] << 8); tick(); }
  d->fw_we = 0;
  for (int i = 0; i < 8; ++i) tick();
  long checks = 0, fails = 0;
  checks++;
  if (d->spy_drv_stb) { fails++; std::printf("FAIL strobe in reset\n"); }
  d->rst_n = 1;

  uint64_t strobes = 0, writes = 0;
  int want = 0;
  while (strobes < 2000 && cyc < 50'000'000) {
    tick();
    if (d->spy_wr) writes++;
    if (d->spy_drv_stb) {
      checks++;
      if (d->spy_drv_cmd != uint8_t(want) && fails++ < 20)
        std::printf("FAIL strobe %llu carries %02x, want %02x\n", (unsigned long long)strobes, d->spy_drv_cmd, uint8_t(want));
      strobes++; want++;
    }
  }
  // 8 writes a pass: PE, DIR, PF, PA and the four stores; one strobe each pass
  checks++;
  const uint64_t per = 8;
  if (strobes < 2000 || writes < strobes * per - per || writes > strobes * per + per) {
    fails++;
    std::printf("FAIL %llu strobes for %llu writes (want one per %llu)\n", (unsigned long long)strobes,
                (unsigned long long)writes, (unsigned long long)per);
  }
  std::printf("m2_ioz80 drive byte: %llu PE strobes, %llu Z80 writes, every strobe the pass's value\n",
              (unsigned long long)strobes, (unsigned long long)writes);
  std::printf("TOTAL %ld checks, %ld fail\n%s\n", checks, fails, fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
