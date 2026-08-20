// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The I/O board answers two things on two triggers, and this checks both
// separately — because conflating them is the failure mode. The status reply
// follows the i960 writing its block; the flag clear follows the board's own
// power-on self-test and lands regardless of what the i960 has done. A test
// that only checked "the flag eventually clears" would pass with the window
// reply removed entirely.
//
// SELFTEST_CYCLES and REPLY_CYCLES are overridden at build time. The real ones
// are 75,652,174 and 25,000 — three seconds of simulation to observe one edge.
// The behaviour under test is the sequence, not the constants; the constants
// are measured in docs/io-board.md and asserted by the differential, not here.

#include "Vm2_ioboard.h"
#include "verilated.h"
#include <cstdio>

static Vm2_ioboard *d;
static int checks = 0, fails = 0;

static void tick() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }

static void ck(const char *what, uint32_t got, uint32_t want) {
  ++checks;
  if (got != want) { ++fails;
    std::printf("  FAIL %-44s got %08x want %08x\n", what, got, want); }
}

// DPRAM byte N lives in bytes 0 and 2 of dword N>>1.
static void wr_byte(uint32_t n, uint8_t v) {
  d->sel = 1; d->we = 1; d->word = n >> 1;
  d->be = (n & 1) ? 0x4 : 0x1;
  d->wdata = (n & 1) ? (uint32_t(v) << 16) : v;
  tick();
  d->sel = 0; d->we = 0; d->be = 0;
}
// The read is REGISTERED now -- the store is M10K, not LUTRAM, because as
// LUTRAM it silently became 16,384 flip-flops. So present the address, clock
// once, then sample. On the real path the bridge holds the address for a
// dispatch cycle before it asserts io_sel, which is the same thing.
static uint8_t rd_byte(uint32_t n) {
  d->sel = 1; d->we = 0; d->word = n >> 1;
  tick();
  d->sel = 0;
  return (n & 1) ? uint8_t(d->rdata >> 16) : uint8_t(d->rdata);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_ioboard;
  d->clk = 0; d->rst_n = 0; d->sel = 0; d->we = 0; d->be = 0; d->wdata = 0;
  for (int i = 0; i < 8; i++) tick();
  d->rst_n = 1;

  // The i960's block: what MAME shows it writing, first 0x43 bytes.
  static const uint8_t head[] = {
    0x53,0x45,0x47,0x41, 0x40,0x82,0x01,0x00, 0xbc,0xeb,0x00,0x00,
    0x00,0xff,0xff,0xff, 0x00,0x01,0x01,0x01, 0x00,0x03,0x03,0x00 };
  for (unsigned i = 0; i < sizeof(head); i++) wr_byte(0x100 + i, head[i]);

  // It reads back what it wrote: the window is RAM, not a register file.
  ck("window readback 0x100", rd_byte(0x100), 0x53);
  ck("window readback 0x105", rd_byte(0x105), 0x82);
  ck("window readback 0x117", rd_byte(0x117), 0x00);

  // The status is on the BOARD'S schedule, not a reply to that write. The boot
  // waits for 0x40 before it writes the window at all, so a status that only
  // arrives afterwards is a deadlock -- see the note in the RTL.
  ck("status before its time", rd_byte(0x21), 0x00);

  for (int i = 0; i < 4000; i++) tick();

  ck("status on schedule",   rd_byte(0x21), 0x40);
  ck("window fill 0x143",    rd_byte(0x143), 0xff);
  ck("window fill 0x160",    rd_byte(0x160), 0xff);
  ck("window fill 0x17b",    rd_byte(0x17b), 0xff);
  ck("window mark 0x17c",    rd_byte(0x17c), 0x01);
  ck("fill did not overrun", rd_byte(0x17d), 0x00);
  ck("fill did not underrun",rd_byte(0x142), 0x00);
  ck("head survived fill",   rd_byte(0x100), 0x53);

  // The i960 raises the flag and polls it. The board is still in self-test.
  wr_byte(0x20, 0x01);
  ck("flag holds while asleep", rd_byte(0x20), 0x01);
  for (int i = 0; i < 200; i++) tick();
  ck("flag still held",         rd_byte(0x20), 0x01);

  // The i960 writes other codes into it meanwhile, as it does on the real
  // machine — 01, 03, 02, 01 across twenty frames — and none of them are
  // answered until the self-test finishes.
  wr_byte(0x20, 0x03); for (int i = 0; i < 50; i++) tick();
  ck("03 not answered early",   rd_byte(0x20), 0x03);
  wr_byte(0x20, 0x02); for (int i = 0; i < 50; i++) tick();
  ck("02 not answered early",   rd_byte(0x20), 0x02);
  wr_byte(0x20, 0x01);

  for (int i = 0; i < 6000; i++) tick();
  ck("flag cleared after self-test", rd_byte(0x20), 0x00);
  ck("status kept across clear",     rd_byte(0x21), 0x40);

  // AND IT ANSWERS AGAIN. A board that clears once is a description of the
  // reference's timeline rather than of the board, and it deadlocks a CPU
  // slower than the reference: the single clear lands before the command
  // arrives, and the command is never answered. This is the check that fails
  // if the one-shot ever comes back.
  wr_byte(0x20, 0x03);
  ck("second request seen",   rd_byte(0x20), 0x03);
  for (int i = 0; i < 100; i++) tick();
  ck("second request answered", rd_byte(0x20), 0x00);

  std::printf("m2_ioboard checks=%d fails=%d\n", checks, fails);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete d; return fails ? 1 : 0;
}
