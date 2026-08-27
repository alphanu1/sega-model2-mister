// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The character fetch crossing, at the frequencies it actually runs at.
//
// TWO THINGS ARE PROVED HERE, and the second is the one that matters:
//
//   1. Every fetch through m2_char_cdc is acknowledged exactly once and returns
//      the right data, at 48 MHz <-> 32 MHz and at a range of memory latencies.
//
//   2. THE ARRANGEMENT IT REPLACES LOSES ACKNOWLEDGES. m2_sdram holds p_ack for
//      one clk_sys cycle (20.8 ns) and clk_vid samples every 31.25 ns, so a
//      pulse can fall entirely between two sampling edges. This counts them.
//      Without that count the fix is an assertion; with it, it is a measurement.
//
// The time base is 192 MHz so both clocks are exact: clk_sys toggles every 2
// ticks (48 MHz), clk_vid every 3 (32 MHz). Their edges realign every 62.5 ns,
// which is precisely why no pulse-width argument works between them.

#include "Vm2_char_cdc.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>

static Vm2_char_cdc *d;

// One 192 MHz tick. Returns which clocks had a rising edge.
struct Edges { bool sys, vid; };

static uint64_t tick_count = 0;
static int sys_phase = 0, vid_phase = 0;

static Edges tick() {
  Edges e{false, false};
  ++tick_count;
  if (++sys_phase == 2) { sys_phase = 0; d->clk_sys = !d->clk_sys; if (d->clk_sys) e.sys = true; }
  if (++vid_phase == 3) { vid_phase = 0; d->clk_vid = !d->clk_vid; if (d->clk_vid) e.vid = true; }
  d->eval();
  return e;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_char_cdc;

  int fails = 0, checks = 0;
  std::printf("m2_char_cdc: the character fetch across 48 MHz <-> 32 MHz\n");

  // ---- 2. First, MEASURE the failure this module exists to fix. -----------
  //
  // A one-clk_sys-cycle pulse, sampled on clk_vid rising edges, at every
  // starting phase. This is the old direct connection, modelled exactly.
  {
    int missed = 0, seen = 0;
    for (int start = 0; start < 12; ++start) {
      // Build one clk_sys-cycle-wide pulse beginning at tick `start`, and ask
      // whether any clk_vid rising edge lands inside it.
      bool caught = false;
      int sp = 0, vp = 0, sclk = 0, vclk = 0;
      int pulse_from = -1;
      for (int t = 0; t < 96; ++t) {
        bool sr = false, vr = false;
        if (++sp == 2) { sp = 0; sclk = !sclk; if (sclk) sr = true; }
        if (++vp == 3) { vp = 0; vclk = !vclk; if (vclk) vr = true; }
        if (sr && t >= start && pulse_from < 0) pulse_from = t;      // pulse starts
        const bool in_pulse = (pulse_from >= 0) && (t > pulse_from) && (t <= pulse_from + 4);
        if (vr && in_pulse) caught = true;
        if (pulse_from >= 0 && t > pulse_from + 4) break;
      }
      if (caught) ++seen; else ++missed;
    }
    std::printf("  the OLD direct connection, one clk_sys pulse per ack:\n"
                "    %d of %d starting phases are seen by clk_vid, %d are MISSED\n",
                seen, seen + missed, missed);
    if (missed == 0) {
      std::printf("    FAIL: no phase loses the pulse, so this does not model the fault\n");
      ++fails;
    }
    ++checks;
  }

  // ---- 1. Now the module itself. ----------------------------------------
  for (int lat : {1, 2, 5, 13, 40}) {
    // reset
    d->clk_sys = 0; d->clk_vid = 0; d->vid_rst_n = 0; d->sys_rst_n = 0;
    d->v_req = 0; d->v_addr = 0; d->s_ack = 0; d->s_data = 0;
    sys_phase = vid_phase = 0;
    for (int i = 0; i < 40; ++i) tick();
    d->vid_rst_n = 1; d->sys_rst_n = 1;
    for (int i = 0; i < 20; ++i) tick();

    const int N = 64;
    int issued = 0, acked = 0, bad_data = 0, acks_while_idle = 0;
    uint32_t expect = 0;
    bool waiting = false;

    // Memory side model: s_req -> after `lat` clk_sys cycles, one-cycle s_ack.
    int mem_count = -1;
    uint64_t vid_edges_used = 0;

    for (uint64_t t = 0; t < 4000000 && acked < N; ++t) {
      Edges e = tick();

      if (e.sys) {
        // drop a one-cycle ack
        if (d->s_ack) { d->s_ack = 0; }
        if (mem_count < 0 && d->s_req) {
          mem_count = lat;
        } else if (mem_count > 0) {
          --mem_count;
        } else if (mem_count == 0) {
          d->s_data = 0xC0DE0000u + d->s_addr;
          d->s_ack  = 1;
          mem_count = -1;
        }
      }

      if (e.vid) {
        if (issued > 0 && acked < N) ++vid_edges_used;
        if (d->v_ack && !waiting) ++acks_while_idle;
        if (waiting && d->v_ack) {
          if (d->v_data != expect) { ++bad_data; }
          ++acked;
          d->v_req = 0;
          waiting  = false;
        } else if (!waiting && !d->v_ack && issued < N) {
          d->v_addr = issued;
          expect    = 0xC0DE0000u + issued;
          d->v_req  = 1;
          waiting   = true;
          ++issued;
        }
      }
    }

    // THROUGHPUT IS THE NUMBER THAT MATTERS, not request-to-ack. The fetch
    // engine is serial: what limits it is how soon the NEXT fetch can start,
    // and a four-phase handshake makes it wait for the whole return-to-zero.
    const double per_fetch = double(vid_edges_used) / double(acked ? acked : 1);
    const bool ok = (acked == N) && (bad_data == 0) && (acks_while_idle == 0);
    std::printf("  mem latency %2d clk_sys: %2d/%d acknowledged, %d wrong, "
                "%d stray, %5.1f clk_vid cycles per fetch  %s\n",
                lat, acked, N, bad_data, acks_while_idle, per_fetch,
                ok ? "ok" : "FAIL");
    if (!ok) ++fails;
    checks += 3;
  }

  std::printf("m2_char_cdc: checks=%d fails=%d\n", checks, fails);
  std::printf(fails ? "FAIL\n" : "PASS\n");
  delete d;
  return fails ? 1 : 0;
}
