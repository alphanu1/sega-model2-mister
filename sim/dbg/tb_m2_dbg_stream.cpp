// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// The serial debug channel, decoded back out of the wire.
//
// This testbench does what a terminal on the other end of the cable would do:
// samples tx at the middle of each bit, reassembles 8N1 bytes, and checks the
// lines against the events that were fed in. If the framing is wrong by one
// bit the text is garbage, and garbage on a debug channel is worse than no
// channel -- it was trusting a misread instrument that cost this project a
// session.
//
// It also checks the two properties the design chose deliberately:
//   * events are DROPPED, never stalled, so the instrument cannot change the
//     timing of what it measures
//   * every dropped event is COUNTED, so the log can never imply it saw
//     everything

#include "Vm2_dbg_stream.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

static Vm2_dbg_stream *d;
static const int DIV = 417;

static std::string line, captured;
static std::vector<std::string> lines;

// A receiver, sampling the middle of each bit exactly as a real UART does.
static void rx_sample() {
  static int state = 0, cnt = 0, biti = 0;
  static uint8_t sh = 0;
  if (state == 0) {                       // idle, wait for the start bit
    if (!d->tx) { state = 1; cnt = DIV / 2; }
  } else if (--cnt <= 0) {
    if (state == 1) {                     // middle of the start bit
      state = 2; biti = 0; sh = 0; cnt = DIV;
    } else if (state == 2) {
      sh = uint8_t((sh >> 1) | (d->tx ? 0x80 : 0x00));
      if (++biti == 8) { state = 3; cnt = DIV; }
      else cnt = DIV;
    } else {                              // stop bit
      if (sh == '\n') { lines.push_back(line); line.clear(); }
      else            line.push_back(char(sh));
      state = 0;
    }
  }
}

static void tick() {
  d->clk = 0; d->eval();
  d->clk = 1; d->eval();
  rx_sample();
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_dbg_stream;

  d->rst_n = 0; d->enable = 1;
  d->a_valid = 0; d->b_valid = 0;
  d->a_tag = 'W'; d->b_tag = 'R';
  d->a_addr = 0; d->a_data = 0; d->b_addr = 0; d->b_data = 0;
  for (int i = 0; i < 8; ++i) tick();
  d->rst_n = 1;
  for (int i = 0; i < 8; ++i) tick();

  struct Ev { char tag; uint32_t a, v; };
  const Ev want[] = {
    {'W', 0x01690000u, 0x12345678u},
    {'R', 0x01690004u, 0x00000000u},
    {'W', 0xDEADBEEFu, 0xCAFEF00Du},
    {'R', 0x016CD8DEu, 0xFFFFFFFFu},
  };

  // Each event is offered, then the stream is given time to send the line.
  // 20 characters at 417 cycles a bit, 10 bits a character, is 83,400 cycles.
  for (const Ev &e : want) {
    if (e.tag == 'W') { d->a_valid = 1; d->a_addr = e.a; d->a_data = e.v; }
    else              { d->b_valid = 1; d->b_addr = e.a; d->b_data = e.v; }
    tick();
    d->a_valid = 0; d->b_valid = 0;
    for (int i = 0; i < 120000; ++i) tick();
  }

  int fails = 0;
  std::printf("  received %zu lines:\n", lines.size());
  for (const std::string &l : lines) std::printf("    |%s|\n", l.c_str());

  if (lines.size() != 4) {
    std::printf("  FAIL: expected 4 lines, got %zu\n", lines.size());
    ++fails;
  }
  for (size_t i = 0; i < lines.size() && i < 4; ++i) {
    char exp[64];
    std::snprintf(exp, sizeof exp, "%c %08X %08X",
                  want[i].tag, want[i].a, want[i].v);
    if (lines[i] != exp) {
      std::printf("  FAIL line %zu: got |%s| want |%s|\n",
                  i, lines[i].c_str(), exp);
      ++fails;
    }
  }

  // Drops must be counted, not stalled: fire a burst far faster than the wire
  // can carry and confirm the counter moves and the stream keeps its framing.
  const uint32_t before = d->dbg_dropped;
  for (int i = 0; i < 500; ++i) {
    d->a_valid = 1; d->a_addr = 0x1000 + i; d->a_data = i;
    tick();
    d->a_valid = 0;
    tick();
  }
  for (int i = 0; i < 200000; ++i) tick();
  const uint32_t dropped = d->dbg_dropped - before;
  std::printf("  burst of 500: %u dropped, %zu lines total\n",
              dropped, lines.size());
  if (dropped == 0) {
    std::printf("  FAIL: a 500-event burst cannot fit on the wire; drops must be counted\n");
    ++fails;
  }
  // Whatever did get through must still be well-formed.
  for (const std::string &l : lines) {
    if (l.size() != 19) {
      std::printf("  FAIL: malformed line |%s| (%zu chars)\n", l.c_str(), l.size());
      ++fails;
      break;
    }
  }

  std::printf("m2_dbg_stream: fails=%d\n", fails);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
