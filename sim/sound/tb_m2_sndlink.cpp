// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// The main-board-to-sound-board serial link, against the reference's own bytes.
//
// MAME emits exactly 59 bytes to the i960's i8251 over 900 frames of attract
// mode, and the opening of that stream is reproduced here verbatim. It is a
// real oracle rather than a made-up pattern: if this link carries these bytes,
// in this order, with the transmitter busy between them, then the path the
// sound board will sit behind is correct before a single sound chip exists.
//
// What is checked:
//   * the mode/command sequencing -- the first control write after reset is a
//     MODE byte, not a command, and getting that backwards means the link never
//     starts
//   * every byte arrives, once, in order
//   * TXRDY falls while a byte is in flight, which is the property that stops a
//     sender outrunning the wire. A link that delivers instantly passes an
//     ordering test and still runs the game's command pacing at the wrong speed
//   * the reverse direction, which the sound board uses to answer
//   * a read of the data register consumes the byte, so RXRDY falls

#include "Vm2_sndlink_harness.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>

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

  // Both ends program themselves: mode byte, then command. 8N1, x16.
  a_write(1, 0x4e);          // mode: 1 stop, no parity, 8 data, x16
  a_write(1, 0x37);          // command: TxEN|DTR|RxEN|ER|RTS
  b_write(1, 0x4e);
  b_write(1, 0x37);
  idle(4);

  expect("A status after setup", a_read(1) & 0x03, 0x01);   // TXRDY, no RXRDY

  // THE REFERENCE'S OWN BYTES. The opening of what MAME sends in attract mode.
  const uint8_t stream[] = {
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0xf8, 0xf8, 0xff,
    0xbe, 0x14, 0x1f,
    0xbe, 0x16, 0x02,
    0xbe, 0x1b, 0x17
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

  // RXRDY must fall once the byte is read, or the firmware reads it forever.
  expect("RXRDY after read", b_read(1) & 0x02, 0x00);

  // The sound board answers.
  b_write(0, 0x5a);
  for (int t = 0; t < 400; ++t) { if (a_read(1) & 0x02) break; idle(); }
  expect("reverse direction", a_read(0), 0x5a);

  std::printf("m2_sndlink: checks=%d fails=%d\n", checks, fails);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
