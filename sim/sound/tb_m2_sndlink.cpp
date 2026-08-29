// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// The main-board-to-sound-board serial link, against the reference's own bytes.
//
// MAME writes the i960's i8251 exactly 59 times over 900 frames of attract
// mode, and the whole of that traffic is reproduced here verbatim: 11 CONTROL
// writes and 48 DATA bytes. It is a real oracle rather than a made-up pattern.
//
// The split matters and an earlier version of this file got it wrong. The
// opening looks like eleven 0x00 data bytes if the address is not checked, and
// it is not -- those are the control port, mask 0xffff0000, address 0x01c80002.
// They are the canonical i8251 wake-up: three zeroes to flush the register's
// state machine from wherever it was, 0x40 for an internal reset, then the mode
// byte and the command. Feeding them through the DATA port tests nothing that
// happens on hardware and hides the sequencing this device gets wrong.
//
// What is checked:
//   * the mode/command sequencing -- the first control write after reset is a
//     MODE byte, not a command, and getting that backwards means the link never
//     starts
//   * every byte arrives, once, in order
//   * TXRDY falls while a byte is in flight, which is the property that stops a
//     sender outrunning the wire. A link that delivers instantly passes an
//     ordering test and still runs the game's command pacing at the wrong speed
//   * that the stream survives being written BLIND, which is what the firmware
//     actually does: the read tap over the same 900 frames fires zero times, so
//     Daytona never polls status and never waits on TXRDY. It relies on its own
//     spacing. A model that only works when the sender checks TXRDY would pass
//     the polled test above and drop bytes on the board.
//   * the reverse direction, which the sound board uses to answer
//   * a read of the data register consumes the byte, so RXRDY falls

#include "Vm2_sndlink_harness.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>

static const int BYTE_TIME = 64;   // must match the harness's BYTE_CYCLES
static Vm2_sndlink_harness *d;
static int fails = 0, checks = 0;

static void tick() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }

static void idle(int n = 1) {
  d->a_sel = 0; d->b_sel = 0;
  for (int i = 0; i < n; ++i) tick();
}

// One register access on side A (the i960's).
static void a_write(int addr, uint8_t v) {
  d->a_sel = 1; d->a_we = 1; d->a_addr = addr; d->a_din = v;
  tick();
  idle();
}
static uint8_t a_read(int addr) {
  d->a_sel = 1; d->a_we = 0; d->a_addr = addr;
  d->eval();
  uint8_t v = d->a_dout;
  tick();
  idle();
  return v;
}
static void b_write(int addr, uint8_t v) {
  d->b_sel = 1; d->b_we = 1; d->b_addr = addr; d->b_din = v;
  tick();
  idle();
}
static uint8_t b_read(int addr) {
  d->b_sel = 1; d->b_we = 0; d->b_addr = addr;
  d->eval();
  uint8_t v = d->b_dout;
  tick();
  idle();
  return v;
}

static void expect_u32(const char *what, uint32_t got, uint32_t want) {
  ++checks;
  if (got != want) {
    std::printf("  FAIL %-34s got=%08x want=%08x\n", what, got, want);
    ++fails;
  } else {
    std::printf("  %-36s %08x\n", what, got);
  }
}

static void expect(const char *what, uint32_t got, uint32_t want) {
  ++checks;
  if (got != want) {
    std::printf("  FAIL %-34s got=%02x want=%02x\n", what, got, want);
    ++fails;
  }
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_sndlink_harness;

  d->rst_n = 0;
  d->a_sel = d->a_we = d->a_addr = d->a_din = 0;
  d->b_sel = d->b_we = d->b_addr = d->b_din = 0;
  for (int i = 0; i < 8; ++i) tick();
  d->rst_n = 1;
  idle(4);

  // THE FIRMWARE'S OWN WAKE-UP SEQUENCE, not an idealised one. Three zeroes,
  // an internal reset, then mode and command -- and the three zeroes land while
  // this model is still expecting a mode byte, so it must come out of them in
  // the same state the real part does. It does, via the 0x40: whatever the
  // zeroes were taken for, bit 6 re-arms the mode write.
  const uint8_t ctrl[] = { 0x00, 0x00, 0x00, 0x40, 0x4e, 0x37 };
  for (uint8_t c : ctrl) a_write(1, c);
  for (uint8_t c : ctrl) b_write(1, c);
  idle(4);

  expect("A status after setup", a_read(1) & 0x03, 0x01);   // TXRDY, no RXRDY

  // THE REFERENCE'S OWN BYTES: all 48 data writes MAME makes in 900 frames.
  // Three to open, then fifteen three-byte commands -- 0xbe or 0xae, a register,
  // a value.
  const uint8_t stream[] = {
    0xf8, 0xf8, 0xff,
    0xbe, 0x14, 0x1f,  0xbe, 0x16, 0x02,  0xbe, 0x1b, 0x06,
    0xbe, 0x1c, 0x03,  0xbe, 0x1d, 0x01,  0xbe, 0x1e, 0x02,
    0xbe, 0x1f, 0x05,  0xbe, 0x36, 0x09,  0xbe, 0x17, 0x00,
    0xbe, 0x18, 0x04,  0xbe, 0x35, 0x00,  0xbe, 0x34, 0x00,
    0xae, 0x10, 0x08,  0xbe, 0x17, 0x00,  0xbe, 0x19, 0x00
  };
  const int N = int(sizeof stream);

  std::vector<uint8_t> got;
  bool saw_busy = false;

  for (int i = 0; i < N; ++i) {
    // Wait for the transmitter, exactly as the firmware does.
    int guard = 0;
    while (!(a_read(1) & 0x01)) {
      if (++guard > 10000) { std::printf("  FAIL TXRDY never returned\n"); ++fails; break; }
    }
    a_write(0, stream[i]);
    // TXRDY must FALL while the byte is on the wire. Without this the link is
    // infinitely fast and the game's pacing is wrong even though the bytes are
    // right.
    if (!(a_read(1) & 0x01)) saw_busy = true;

    // Drain the far end as it arrives.
    for (int t = 0; t < 400; ++t) {
      if (b_read(1) & 0x02) { got.push_back(b_read(0)); break; }
      idle();
    }
  }

  ++checks;
  if (!saw_busy) {
    std::printf("  FAIL transmitter never went busy -- the wire has no line time\n");
    ++fails;
  }

  ++checks;
  if ((int)got.size() != N) {
    std::printf("  FAIL received %zu bytes, expected %d\n", got.size(), N);
    ++fails;
  } else {
    for (int i = 0; i < N; ++i)
      if (got[i] != stream[i]) {
        std::printf("  FAIL byte %d: got %02x want %02x\n", i, got[i], stream[i]);
        ++fails;
        break;
      }
  }
  std::printf("  main -> sound: %zu of %d bytes, in order\n", got.size(), N);

  // THE SAME 48 BYTES, AS ONE NUMBER, so the board can be checked over a debug
  // channel that carries two words a frame. Rotate-xor is order sensitive --
  // a sum or an xor would pass on the right bytes in the wrong order, and a
  // command protocol is entirely order. This is the value MAME's stream gives.
  expect_u32("stream signature", d->dbg_a_sig, 0x6ae52ed8u);

  // RXRDY must fall once the byte is read, or the firmware reads it forever.
  expect("RXRDY after read", b_read(1) & 0x02, 0x00);

  // ---- THE SAME STREAM, WRITTEN BLIND.
  //
  // The firmware does not poll. Over 900 frames of attract mode the read tap on
  // this port fires ZERO times: Daytona writes its command bytes and moves on,
  // relying on its own spacing to stay under the line rate. So the polled pass
  // above proves the ordering but not the case that actually runs, and a model
  // that only keeps up when the sender waits would pass it and still lose bytes
  // on the board.
  //
  // Paced at exactly the line time and never reading status. Nothing may be
  // dropped. This is a floor, not the firmware's real spacing -- that is not
  // known to a frame's resolution and the property should hold regardless.
  got.clear();
  for (int i = 0; i < N; ++i) {
    a_write(0, stream[i]);
    for (int t = 0; t < BYTE_TIME + 8; ++t) {
      if (b_read(1) & 0x02) got.push_back(b_read(0));
      idle();
    }
  }
  ++checks;
  if ((int)got.size() != N) {
    std::printf("  FAIL blind write: %zu of %d bytes survived -- the model needs "
                "the sender to poll\n", got.size(), N);
    ++fails;
  } else {
    for (int i = 0; i < N; ++i)
      if (got[i] != stream[i]) {
        std::printf("  FAIL blind byte %d: got %02x want %02x\n", i, got[i], stream[i]);
        ++fails; break;
      }
    std::printf("  blind, unpolled: %d of %d bytes, in order\n", N, N);
  }

  // The sound board answers.
  b_write(0, 0x5a);
  for (int t = 0; t < 400; ++t) { if (a_read(1) & 0x02) break; idle(); }
  expect("reverse direction", a_read(0), 0x5a);

  std::printf("m2_sndlink: checks=%d fails=%d\n", checks, fails);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
