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

  // The window is RAM as well as a block source: the i960 writes elsewhere in
  // it, so a write must stick.
  wr_byte(0x1f0, 0x5a);
  ck("window is writable",   rd_byte(0x1f0), 0x5a);

  // The status is on the BOARD'S schedule, not a reply to that write. The boot
  // waits for 0x40 before it writes the window at all, so a status that only
  // arrives afterwards is a deadlock -- see the note in the RTL.
  ck("status before its time", rd_byte(0x21), 0x00);

  for (int i = 0; i < 4000; i++) tick();

  ck("status on schedule",   rd_byte(0x21), 0x40);
  // THE BOARD SUPPLIES THE WHOLE BLOCK. The i960 copies DPRAM 0x100-0x17f into
  // backup SRAM and will not go on until it has -- 0022827C reads (g6) with
  // g6 = 0x1c00200 and stores to (g5) with g5 = 0x1d00000 -- so a window that
  // is only partly filled is copied in as zeros and rejected.
  //
  // These expectations are typed from MAME's dump independently of the RTL
  // table. That is a weaker safeguard than it looks -- the Model 1 core did the
  // same and still propagated one bad reading into both -- which is why the
  // dump was sampled at five frames and checked identical rather than taken
  // once.
  ck("block 'S'",            rd_byte(0x100), 0x53);
  ck("block 'E'",            rd_byte(0x101), 0x45);
  ck("block 'G'",            rd_byte(0x102), 0x47);
  ck("block 'A'",            rd_byte(0x103), 0x41);
  ck("block 0x105",          rd_byte(0x105), 0x82);
  ck("block 0x109",          rd_byte(0x109), 0xeb);
  ck("block 0x11b",          rd_byte(0x11b), 0x01);
  ck("block 0x120",          rd_byte(0x120), 0x01);
  ck("block 0x12f gap",      rd_byte(0x12f), 0x00);
  ck("block 0x132",          rd_byte(0x132), 0x14);
  ck("block 0x139",          rd_byte(0x139), 0x01);
  ck("block 0x13a tail",     rd_byte(0x13a), 0xff);
  ck("block 0x160 tail",     rd_byte(0x160), 0xff);
  ck("block 0x17b tail",     rd_byte(0x17b), 0xff);
  ck("block 0x17c mark",     rd_byte(0x17c), 0x01);
  ck("block 0x17f end",      rd_byte(0x17f), 0x00);
  ck("did not overrun",      rd_byte(0x180), 0x00);
  ck("did not underrun",     rd_byte(0x0ff), 0x00);

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
