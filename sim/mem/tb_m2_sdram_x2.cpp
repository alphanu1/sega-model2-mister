// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// The controller at 96 MHz behind m2_sdram_x2, driven from 48.
//
// tb_m2_sdram.cpp tests the controller with no slow domain to be misaligned
// with, so it passes whether or not the adapter is right. The adapter's two
// hazards are both pulse widths measured in the OTHER domain's cycles:
//
//   * the read-data bypass. `dout_r` loads on the fast edge AFTER the
//     acknowledge, the acknowledge is two fast cycles wide, and the slow edge
//     lands on one or the other. Get it wrong and roughly HALF of all reads
//     return the previous transaction's data — the two alignments are equally
//     likely and one is wrong.
//   * the request mask. A slow requester drops `req` one slow cycle after it
//     sees the acknowledge, so `req` is still high for up to two more fast
//     cycles and a LEVEL-latching controller would read the same address again.
//
//     THIS TEST CANNOT FAIL ON THAT, and it is stated here rather than left for
//     someone to discover. m2_sdram latches on the edge -- `p_req[i] &&
//     !req_d[i]` -- so a held request cannot re-request, and the mask can be
//     deleted with all 2,560 checks passing and the transaction count exact.
//     Both were tried. The mask is defensive against a controller change, not
//     against this controller.
//
// So this drives the slow side ONLY on slow edges. A testbench that acted on
// fast edges would be a requester this core does not have, and would pass.

#include "Vm2_sdram_x2_harness.h"
#include "verilated.h"
#include <cstdio>
#include <map>
#include <cstdint>

static Vm2_sdram_x2_harness *d;
static long checks = 0, fails = 0, raced = 0;
// TRANSACTIONS ISSUED, counted so a DUPLICATE can be seen.
//
// Hazard 2 -- a request left high for two more fast cycles after the
// acknowledge -- makes the controller run the same transaction twice. That
// returns the SAME data, so no value check can see it, and the first version of
// this test passed with the request mask deleted. What it changes is the COUNT.
// Compared against the device model's own served-read counter, which is on the
// far side of everything and cannot be fooled by the adapter.
static long bursts_issued = 0;
static std::map<uint32_t, uint16_t> shadow;
struct WriteRec { uint16_t prev; long cyc; };
static std::map<uint32_t, WriteRec> last_write;
static long cyc = 0;
static bool slow_prev = false;

// One fast tick. Returns true if a slow rising edge happened on it.
static bool tick() {
  d->clk = 0; d->eval();
  d->clk = 1; d->eval();
  ++cyc;
  const bool e = d->clk_slow && !slow_prev;
  slow_prev = d->clk_slow;
  return e;
}

static void slow_ticks(int n) { int seen = 0; while (seen < n) if (tick()) ++seen; }

struct Port { bool busy = false, ack_prev = false; uint32_t addr = 0; long issued = 0; };
static Port port[5];

static void set_req(int p, bool v) {
  switch (p) { case 0: d->p0_req = v; break; case 1: d->p1_req = v; break;
               case 2: d->p2_req = v; break; case 3: d->p3_req = v; break;
               default: d->p4_req = v; }
}
static void set_addr(int p, uint32_t a) {
  switch (p) { case 0: d->p0_addr = a; break; case 1: d->p1_addr = a; break;
               case 2: d->p2_addr = a; break; case 3: d->p3_addr = a; break;
               default: d->p4_addr = a; }
}
static bool get_ack(int p) {
  switch (p) { case 0: return d->p0_ack; case 1: return d->p1_ack;
               case 2: return d->p2_ack; case 3: return d->p3_ack;
               default: return d->p4_ack; }
}
static uint64_t get_dout(int p) {
  switch (p) { case 0: return d->p0_dout; case 1: return d->p1_dout;
               case 2: return d->p2_dout; case 3: return d->p3_dout;
               default: return d->p4_dout; }
}

// A slow-side read: hold req, wait for the acknowledge ON SLOW EDGES, check the
// four words, then drop req the slow cycle after — exactly what a real
// requester does, and what makes hazard 2 reachable.
static void read4(int p, uint32_t addr) {
  addr &= ~3u;
  set_addr(p, addr); set_req(p, 1);
  port[p].issued = cyc;
  for (int guard = 0; guard < 4000; ++guard) {
    if (!tick()) continue;
    if (!get_ack(p)) continue;
    const uint64_t got = get_dout(p);
    for (int w = 0; w < 4; ++w) {
      const uint32_t a = addr + w;
      const uint16_t want = shadow.count(a) ? shadow[a] : 0;
      const uint16_t g = uint16_t((got >> (16 * w)) & 0xffff);
      ++checks;
      if (g != want) {
        auto it = last_write.find(a);
        const bool ok = it != last_write.end() && it->second.cyc >= port[p].issued
                     && g == it->second.prev;
        if (ok) ++raced;
        else if (fails < 12) {
          std::printf("  FAIL p%d addr=%06x word=%d got=%04x want=%04x\n",
                      p, a, w, g, want); ++fails;
        } else ++fails;
      }
    }
    // DROP `req` THE SLOW CYCLE AFTER THE ACKNOWLEDGE, NOT ON IT.
    //
    // A real requester registers the acknowledge and lowers its request on the
    // next edge, so `req` is still high for up to two more fast cycles -- which
    // is precisely hazard 2, the reason `done` exists. The first version of
    // this test dropped it in the same slow cycle, which no requester in this
    // core does, and the request mask could be deleted with all 2,560 checks
    // still passing and the transaction count exact.
    //
    // A testbench more polite than the thing it models is the failure this
    // project has recorded six times, and it was about to make it a seventh.
    slow_ticks(1);
    set_req(p, 0);
    ++bursts_issued;
    slow_ticks(1);
    return;
  }
  std::printf("  FAIL p%d addr=%06x never acknowledged\n", p, addr); ++fails;
  set_req(p, 0);
}

static void write1(uint32_t addr, uint16_t v) {
  d->wr_addr = addr; d->wr_din = v; d->wr_be = 3; d->wr_req = 1;
  last_write[addr] = { uint16_t(shadow.count(addr) ? shadow[addr] : 0), cyc };
  shadow[addr] = v;
  for (int guard = 0; guard < 4000; ++guard) {
    if (!tick()) continue;
    if (!d->wr_ack) continue;
    slow_ticks(1);              // same reason as read4
    d->wr_req = 0; slow_ticks(1); return;
  }
  std::printf("  FAIL write %06x never acknowledged\n", addr); ++fails;
  d->wr_req = 0;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_sdram_x2_harness;
  d->clk = 0; d->rst_n = 0;
  d->wr_req = 0; d->p0_we = 0; d->p0_din = 0; d->p0_be = 3;
  for (int p = 0; p < 5; ++p) { set_req(p, 0); set_addr(p, 0); }
  for (int i = 0; i < 64; ++i) tick();
  d->rst_n = 1;
  for (int i = 0; i < 4000 && !d->ready; ++i) tick();
  if (!d->ready) { std::printf("  FAIL controller never became ready\n"); return 1; }

  // Fill a spread of rows and banks, then read every one of them back on every
  // port. A wrong bypass fails about half of these; a wrong request mask
  // re-reads an address and fails whichever of them moved on.
  uint32_t seed = 0x1234567u;
  auto rnd = [&]() { seed = seed * 1103515245u + 12345u; return seed >> 8; };

  for (int i = 0; i < 256; ++i) {
    const uint32_t base = ((rnd() % 6) << 13) | ((rnd() % 4) << 20) | ((rnd() % 64) << 2);
    for (int w = 0; w < 4; ++w) write1(base + w, uint16_t(rnd()));
  }
  std::printf("  wrote %zu words\n", shadow.size());

  int n = 0;
  for (auto &kv : shadow) {
    if ((kv.first & 3u) != 0) continue;
    read4(n % 5, kv.first);
    ++n;
  }
  std::printf("  read back %d bursts on all five ports\n", n);

  // Now with writes running against the reads, which is where the raced case
  // lives and where a request that is taken twice shows up.
  for (int i = 0; i < 400; ++i) {
    const uint32_t base = ((rnd() % 6) << 13) | ((rnd() % 4) << 20) | ((rnd() % 64) << 2);
    write1(base + (rnd() % 4), uint16_t(rnd()));
    read4(int(rnd() % 5), base);
  }

  // Each burst is four 16-bit words; the model counts words served. Refresh and
  // the controller's own bring-up add nothing to a READ counter, so the only
  // way to exceed this is a transaction that ran twice.
  const long want_reads = bursts_issued * 4;
  std::printf("  bursts issued %ld, device served %u read words (want %ld)\n",
              bursts_issued, d->reads_served, want_reads);
  if (long(d->reads_served) != want_reads) {
    std::printf("  FAIL the device served %ld read words for %ld bursts -- a\n"
                "       request was taken more than once.\n",
                long(d->reads_served), bursts_issued);
    ++fails;
  }
  std::printf("  reads accepted as raced (returned the legal pre-write value): %ld\n", raced);
  std::printf("  m2_sdram_x2: checks=%ld fails=%ld violations=%u\n",
              checks, fails, d->violations);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
