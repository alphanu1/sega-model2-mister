// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// R817: i960_icache AGAINST A REQUESTER THAT DOES NOT WAIT, AND A SLOW BUS.
//
// tb_i960_icache drives the cache from a requester that waits for every answer
// and a memory that acknowledges in the cycle it is asked. Neither is the
// board: i960_top issues a prefetch at every accept and a new demand request
// whenever its prediction misses, without waiting for the previous one, and the
// bridge answers many cycles later (its first word a crossing and an SDRAM
// read away, the rest from its line buffer). R812's lock lived in exactly that
// gap; so did the stale-redirect hang tb_m2_ifetch_replay found in R817's hit
// under fill. This bench is that gap, at random:
//
//   * the bus acknowledges each word after a random delay (0..BUS_MAX cycles),
//     registered, and while bus_req stays up -- the bridge's contract;
//   * the requester keeps ONE current address (as i960_top keeps fetch_addr)
//     and accepts only a `valid` whose `vaddr` names it (R812's ic_ok). It
//     moves on -- sequentially, within the line, to a recent line, or to a new
//     one -- either after its answer or, at random, BEFORE it (a prefetch the
//     sequencer stops wanting, a redirect);
//   * EVERY valid is checked against memory at the address it names, wanted
//     or not, and a requester left unanswered for HANG_LIMIT cycles fails.
//
// And the efficiency claims, which transparency cannot see:
//   * HUF: a loop whose last word prefetches an absent next line installs that
//     line once, not once an iteration;
//   * ER: a miss is answered at its own word, before the line completes.
//
// Parameters come from the build: -GLINES -GHUF -GNLP -GER. RANDOM= / SEED= as
// everywhere.

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>
#include "Vi960_icache.h"
#include "verilated.h"

static Vi960_icache *dut;
static int HUF_EXPECTED = 0, ER_EXPECTED = 0;
static std::mt19937 rng(1);
static uint64_t ticks = 0, fails = 0, valids_checked = 0, answers = 0, fills = 0;
static int BUS_MAX = 12;
static const int HANG_LIMIT = 4000;
static uint32_t mem_of(uint32_t a) { a &= ~3u; return (a * 2654435761u) ^ 0x5a5a1234u ^ (a >> 7); }

// the bus: one word at a time, a random delay, ack held for one cycle
static int bus_wait = -1; static uint32_t bus_a = 0; static bool prev_breq = false; static uint32_t prev_baddr = 0;
static void bus_drive() {
  // Called before the edge: decides this cycle's ack from the cache's request.
  // The address is LATCHED when a word is first asked for, as the bridge
  // latches r_addr; moving it while that word is outstanding is R45's fault
  // and is reported, not followed.
  dut->bus_ack = 0;
  if (dut->bus_req) {
    if (bus_wait < 0) { bus_wait = int(rng() % (BUS_MAX + 1)); bus_a = dut->bus_addr; }
    else if (dut->bus_addr != bus_a) {
      if (fails < 12) std::printf("  BUS ADDRESS MOVED under an outstanding word: %08x -> %08x (tick %llu)\n", bus_a, dut->bus_addr, (unsigned long long)ticks);
      ++fails; bus_a = dut->bus_addr;
    }
    if (bus_wait == 0) { dut->bus_ack = 1; dut->bus_rdata = mem_of(bus_a); bus_wait = -1; }
    else --bus_wait;
  } else bus_wait = -1;
  prev_breq = dut->bus_req; prev_baddr = dut->bus_addr;
}

static void check_valid() {
  if (dut->valid) {
    ++valids_checked;
    const uint32_t va = uint32_t(dut->vaddr) << 2;
    if (dut->data != mem_of(va)) {
      if (fails < 12) std::printf("  BAD ANSWER: vaddr=%08x data=%08x want=%08x at tick %llu\n", va, dut->data, mem_of(va), (unsigned long long)ticks);
      ++fails;
    }
  }
}

static void tick() {
  bus_drive();
  if (dut->bus_ack && dut->bus_req) ++fills;
  dut->clk = 0; dut->eval();
  dut->clk = 1; dut->eval();
  ++ticks;
  check_valid();
}

// A random walk shaped like code: mostly sequential, loops back, calls away.
static uint32_t next_addr(uint32_t a, const std::vector<uint32_t> &recent, uint32_t span) {
  const unsigned r = rng() % 100;
  if (r < 60) return a + 4;                                         // sequential
  if (r < 70) return (a & ~15u) | ((rng() % 4) << 2);               // same line
  if (r < 88 && !recent.empty()) return recent[rng() % recent.size()];   // loop / return
  return (0x1000u + (rng() % span)) & ~3u;                           // call far
}

static void random_run(long n, uint32_t span, const char *what, int give_up_pct = 3) {
  uint32_t cur = 0x1000; std::vector<uint32_t> recent;
  uint32_t hist[4] = {0x1000, 0x1000, 0x1000, 0x1000};   // the last requests, newest first
  dut->addr = cur >> 2; dut->req = 1; dut->req_demand = 1; tick(); dut->req = 0;
  long waited = 0, done = 0;
  const uint64_t f0 = fails;
  // A request is a PREFETCH (the sequencer may stop wanting it) or a DEMAND
  // (it waits in T_FETCH_W until answered, however long). Only prefetches are
  // abandoned; a demand left unanswered is a hang, as on the board.
  bool spec = false;
  while (done < n) {
    const bool ok = dut->valid && ((uint32_t(dut->vaddr) << 2) == cur);
    const bool give_up = !ok && spec && int(rng() % 100) < give_up_pct;   // move on before the answer
    if (ok || give_up) {
      if (ok) { ++answers; ++done; }
      if (recent.size() < 64) recent.push_back(cur); else recent[rng() % 64] = cur;
      // Abandoning a request and coming BACK to one of the last few -- whose
      // line may still be filling, or whose redirect may still be pending --
      // is what a prefetch, a taken branch and a return do in a few cycles.
      if (give_up && (rng() % 2)) cur = (hist[1 + rng() % 3] & ~15u) | ((rng() % 4) << 2);
      else cur = next_addr(cur, recent, span);
      hist[3] = hist[2]; hist[2] = hist[1]; hist[1] = hist[0]; hist[0] = cur;
      spec = (rng() % 2) != 0;
      // the next request goes out now, or after a gap (execute, a data access)
      const int gap = (rng() % 3 == 0) ? int(rng() % 6) : 0;
      for (int g = 0; g < gap; ++g) tick();
      dut->addr = cur >> 2; dut->req = 1; dut->req_demand = 1; tick(); dut->req = 0;
      waited = 0;
      continue;
    }
    tick();
    if (++waited > HANG_LIMIT) {
      std::printf("  HANG [%s]: waiting for %08x since %ld cycles (tick %llu)\n", what, cur, waited, (unsigned long long)ticks);
      ++fails; return;
    }
  }
  std::printf("  %-34s %8ld answers, %llu fails\n", what, n, (unsigned long long)(fails - f0));
}

// HUF: a loop of four words whose last prefetches the next, absent line.
static void loop_case() {
  const uint32_t top = 0x8000;
  // warm the loop line
  auto ask = [&](uint32_t a) -> bool {
    dut->addr = a >> 2; dut->req = 1; dut->req_demand = 1; tick(); dut->req = 0;
    for (int i = 0; i < HANG_LIMIT; ++i) { if (dut->valid && (uint32_t(dut->vaddr) << 2) == a) return true; tick(); }
    std::printf("  HANG in loop_case at %08x\n", a); ++fails; return false;
  };
  for (uint32_t a = top; a < top + 16; a += 4) if (!ask(a)) return;
  const uint64_t f0 = fills;
  for (int it = 0; it < 200; ++it) {
    for (uint32_t a = top; a < top + 16; a += 4) if (!ask(a)) return;
    // the sequencer prefetches the word after the branch (the next line) as
    // it accepts the branch, then asks for the branch target
    dut->addr = (top + 16) >> 2; dut->req = 1; tick(); dut->req = 0;
    tick();
  }
  const uint64_t words = fills - f0;
  std::printf("  loop with a fall-through prefetch : %llu words fetched over 200 iterations\n", (unsigned long long)words);
  if (HUF_EXPECTED && words > 8) { std::printf("  FAIL: the fall-through line is refetched (HUF should install it once)\n"); ++fails; }
}

// ER: a miss on word 3 answered before the line completes.
static void er_case() {
  const uint32_t a = 0x7000c;
  dut->addr = a >> 2; dut->req = 1; dut->req_demand = 1; tick(); dut->req = 0;
  int t = 0; bool done = false;
  for (; t < HANG_LIMIT; ++t) {
    if (dut->valid && (uint32_t(dut->vaddr) << 2) == a) { done = true; break; }
    tick();
  }
  const bool busy_at_answer = dut->busy;
  std::printf("  miss on word 3: answered after %d cycles, line %s\n", t, busy_at_answer ? "still filling" : "complete");
  if (!done) { ++fails; return; }
  if (ER_EXPECTED && !busy_at_answer && BUS_MAX > 0) { std::printf("  FAIL: ER should answer before the line completes\n"); ++fails; }
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  long N = 300000;
  for (int i = 1; i < argc; ++i) {
    if (!std::strncmp(argv[i], "+random=", 8)) N = atol(argv[i] + 8);
    if (!std::strncmp(argv[i], "+seed=", 6)) rng.seed(unsigned(atol(argv[i] + 6)));
    if (!std::strncmp(argv[i], "+bus=", 5)) BUS_MAX = atoi(argv[i] + 5);
    if (!std::strncmp(argv[i], "+huf", 4)) HUF_EXPECTED = 1;
    if (!std::strncmp(argv[i], "+er", 3)) ER_EXPECTED = 1;
  }
  dut = new Vi960_icache;
  dut->clk = 0; dut->rst_n = 0; dut->inval = 0; dut->req = 0; dut->req_demand = 1; dut->addr = 0;
  dut->bus_ack = 0; dut->bus_rdata = 0;
  dut->eval(); dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval();
  dut->rst_n = 1;
  for (int i = 0; i < 4200; ++i) tick();     // the reset sweep (2048 lines at most)

  std::printf("i960_icache R817 -- slow bus (0..%d), a requester that does not wait\n", BUS_MAX);
  er_case();
  loop_case();
  random_run(N, 0x1000, "random, 4 KB of code");
  random_run(N, 0x10000, "random, 64 KB of code");
  random_run(N / 3, 0x400, "random, 1 KB of code");
  random_run(N, 0x4000, "16 KB, requests abandoned often", 25);
  std::printf("  %llu valids checked against memory, %llu answers taken, %llu fails\n",
              (unsigned long long)valids_checked, (unsigned long long)answers, (unsigned long long)fails);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  delete dut;
  return fails ? 1 : 0;
}
