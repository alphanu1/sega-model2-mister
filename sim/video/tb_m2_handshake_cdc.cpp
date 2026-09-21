// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// m2_handshake_cdc: every item crosses exactly once, in order, unchanged.
//
// WHAT THIS CAN AND CANNOT PROVE, said up front because the module's own header
// quotes Model 1 on exactly this trap: a bench drives both clocks from one
// simulation timebase, so there is no setup window to violate and no
// metastability to observe. This proves the PROTOCOL -- nothing lost, nothing
// duplicated, order preserved, ready/valid respected. It cannot prove the
// crossing is safe; that comes from the structure (one toggle bit, data held
// stable beside it), not from a green run here.
//
// The clocks are stepped at a real 3:5 ratio -- 60 MHz against 100 -- rather
// than at exact multiples, so the handshake is at least exercised with edges
// landing in every relative position over the 50 ns realignment period. Model 1
// records that driving them "from exact multiples" is what hid a fault, so
// doing that here would repeat a known mistake.

#include "Vm2_handshake_cdc.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <deque>
#include <vector>

static long checks = 0, fails = 0;

static void fail(const char *what, uint32_t got, uint32_t want) {
  if (fails < 12) printf("  FAIL %s: got %08x want %08x\n", what, got, want);
  fails++;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *d = new Vm2_handshake_cdc;

  // Picoseconds per half period. 60 MHz -> 8333 ps, 100 MHz -> 5000 ps.
  // Deliberately not an integer ratio: 3:5 realigns only every 50 ns.
  const long HALF_SRC = 8333, HALF_DST = 5000;
  long t_src = HALF_SRC, t_dst = HALF_DST, now = 0;

  d->rst_n_src = 0; d->rst_n_dst = 0;
  d->s_valid = 0; d->s_data = 0; d->d_ready = 0;
  d->clk_src = 0; d->clk_dst = 0;
  d->eval();

  std::deque<uint32_t> inflight;   // what the source has handed over
  std::vector<uint32_t> received;  // what the destination took
  uint32_t next_item = 0x1000;
  long sent = 0;
  const long TOTAL = 4000;

  // Pseudo-random but reproducible backpressure on both sides.
  uint32_t rng = 12345;
  auto roll = [&]() { rng = rng * 1664525u + 1013904223u; return (rng >> 16) & 0xff; };

  for (long step = 0; step < 4000000 && (long)received.size() < TOTAL; step++) {
    // Advance to whichever clock edge comes next.
    long next = (t_src < t_dst) ? t_src : t_dst;
    now = next;

    // STIMULUS CHANGES ONLY ON ITS OWN CLOCK EDGE. Driving it on every eval()
    // -- which happens on both clocks' half-edges -- advanced the item counter
    // several times between source edges and read as the DUT dropping items.
    // The DUT was fine; the bench was feeding it values it never accepted.
    if (t_src == now) {
      if (!d->clk_src) {
        // About to rise. Sample the handshake as the DUT will see it: BEFORE
        // the edge. Reading s_ready after eval() reads the value the edge just
        // produced, not the one that decided this transfer.
        bool xfer = d->rst_n_src && d->s_valid && d->s_ready;
        d->clk_src = 1; d->eval();
        if (xfer) { inflight.push_back(d->s_data); sent++; }
        if (d->rst_n_src && (xfer || !d->s_valid)) {
          if (sent < TOTAL && roll() > 40) { d->s_valid = 1; d->s_data = next_item++; }
          else                             { d->s_valid = 0; }
        }
      } else {
        d->clk_src = 0; d->eval();
      }
      t_src += HALF_SRC;
    }
    if (t_dst == now) {
      if (!d->clk_dst) {
        bool xfer = d->rst_n_dst && d->d_valid && d->d_ready;
        uint32_t val = d->d_data;
        d->clk_dst = 1; d->eval();
        if (xfer) received.push_back(val);
        if (d->rst_n_dst) d->d_ready = (roll() > 60) ? 1 : 0;
      } else {
        d->clk_dst = 0; d->eval();
      }
      t_dst += HALF_DST;
    }

    // Release reset after a few edges on both clocks.
    if (now > 40000) { d->rst_n_src = 1; d->rst_n_dst = 1; }
    d->eval();
  }

  // ---- nothing lost, nothing duplicated, order preserved
  if ((long)received.size() != TOTAL)
    printf("  FAIL count: received %zu of %ld\n", received.size(), TOTAL), fails++;
  checks++;

  uint32_t expect = 0x1000;
  for (size_t i = 0; i < received.size(); i++) {
    checks++;
    if (received[i] != expect) fail("order/value", received[i], expect);
    expect++;
  }

  // ---- the source must never have been able to overwrite a live item
  // s_ready is only high when nothing is in flight, so `sent` can never exceed
  // what the destination has taken by more than one.
  checks++;
  if (sent - (long)received.size() > 1) {
    printf("  FAIL overlap: %ld sent, %zu received\n", sent, received.size());
    fails++;
  }

  printf("m2_handshake_cdc: checks=%ld fails=%ld crossed=%zu\n",
         checks, fails, received.size());
  printf("%s\n", fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
