// m2_tex_ddr3 (R645): the texture sheets' DDR3 mirror.
//
// Two clocks at the board's 100:70, a DDR3 model with a random latency, CPU
// writes of 16-bit words with byte enables into both sheets, and the two miss
// ports reading four-word lines while the writes go on. Every read must equal
// the four words an SDRAM burst at that address would return ({w3,w2,w1,w0}),
// against a reference image of the sheets kept here. And a port that gives up
// and asks for another line must never be handed the old one.
#include "Vm2_tex_ddr3.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <map>
#include <vector>

static Vm2_tex_ddr3 *d;
static long checks = 0, fails = 0;
static void ck(const char *w, long got, long want) {
  ++checks; if (got != want) { ++fails; if (fails < 20) std::printf("  FAIL %-40s got %ld want %ld\n", w, got, want); }
}

static const uint32_t SBASE = 0x1760000, TBASE = 0x080000;
static std::vector<uint16_t> ref(0x100000, 0xFFFF);     // the sheets as SDRAM holds them
static std::map<uint32_t, uint64_t> ddr;                // DDR3, 64-bit words
static int lat = 0, left = 0; static bool rd = false; static uint32_t ca;
static long d_beats = 0;

static uint64_t ddr_get(uint32_t a) { auto it = ddr.find(a); return it == ddr.end() ? ~0ull : it->second; }

// the DDR3 client port, served once per clk (clk_sys) edge
static void serve_ddr() {
  d->d_wnext = 0; d->d_rvalid = 0; d->d_ack = 0;
  if (left == 0 && d->d_req) { ca = d->d_addr; left = d->d_blen; rd = !d->d_we; lat = rd ? 8 + std::rand() % 40 : 1 + std::rand() % 4; }
  else if (left > 0) {
    if (lat > 0) { lat--; return; }
    if (rd) { d->d_dout = ddr_get(ca); d->d_rvalid = 1; }
    else {
      uint64_t m = 0; for (int b = 0; b < 8; b++) if (d->d_be & (1 << b)) m |= 0xffull << (8 * b);
      ddr[ca] = (ddr_get(ca) & ~m) | (d->d_din & m); d->d_wnext = 1;
    }
    ca++; left--; d_beats++;
    if (left == 0) d->d_ack = 1;
  }
}

// time in 1/700 ns units: clk_mem every 7, clk every 10
static long t = 0;
static void step() {
  const bool mem_edge = (t % 7) == 0, sys_edge = (t % 10) == 0;
  if (sys_edge) serve_ddr();
  d->clk_mem = 0; d->clk = 0; d->eval();
  if (mem_edge) d->clk_mem = 1;
  if (sys_edge) d->clk = 1;
  d->eval();
  t++;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  std::srand(1);
  d = new Vm2_tex_ddr3;
  d->rst_n = 0; d->r_req[0] = d->r_req[1] = 0; d->w_valid = 0;
  for (int i = 0; i < 200; i++) step();
  d->rst_n = 1;

  // ---- 1. writes into both sheets, every lane and both byte enables
  std::printf("test: 4,000 CPU writes, both sheets, all lanes, partial byte enables\n");
  for (int n = 0; n < 4000; n++) {
    const uint32_t off = (n < 2000) ? (std::rand() % 0x400) : (0x80000 + std::rand() % 0x400);
    const uint16_t v = std::rand() & 0xffff; const int be = (n % 5 == 0) ? 1 + std::rand() % 2 : 3;
    uint16_t &r = ref[off];
    if (r == 0xFFFF && be != 3) r = 0xFFFF;
    if (be & 1) r = (r & 0xff00) | (v & 0x00ff);
    if (be & 2) r = (r & 0x00ff) | (v & 0xff00);
    // on a clk (clk_sys) edge: one cycle of w_valid
    while ((t % 10) != 9) step();
    d->w_valid = 1; d->w_addr = SBASE + off; d->w_data = v; d->w_be = be;
    step(); while ((t % 10) != 9) step(); d->w_valid = 0;
    static const int GAP = std::getenv("GAP") ? std::atoi(std::getenv("GAP")) : 200;
    for (int k = 0; k < GAP; k++) step();         // a CPU write every ~20 clk_sys cycles, at most
  }
  for (int k = 0; k < 20000; k++) step();
  ck("no write lost", d->dbg_wr_lost, 0);
  ck("every write reached DDR3", d->dbg_writes, 4000);
  // and a write outside the sheets is not mirrored
  while ((t % 10) != 9) step();
  d->w_valid = 1; d->w_addr = SBASE - 4; d->w_data = 0x1234; d->w_be = 3; step(); while ((t % 10) != 9) step(); d->w_valid = 0;
  for (int k = 0; k < 2000; k++) step();
  ck("a write below sheet 0 is not mirrored", d->dbg_writes, 4000);

  // ---- 2. reads: both ports, random aligned lines, answers against an SDRAM burst
  std::printf("test: 3,000 line reads on two ports, random latency\n");
  long good = 0, bad = 0;
  for (int n = 0; n < 1500; n++) {
    uint32_t off[2]; bool got[2] = {false, false}; uint64_t data[2] = {0, 0};
    for (int p = 0; p < 2; p++) {
      off[p] = ((n & 1) ? 0x80000 : 0) + ((std::rand() % 0x400) & ~3u);
      d->r_req[p] = 1; d->r_addr[p] = SBASE + off[p];
    }
    for (int k = 0; k < 40000 && !(got[0] && got[1]); k++) {
      step();
      if ((t % 7) == 1) for (int p = 0; p < 2; p++)
        if (d->r_ack[p] && !got[p]) { got[p] = true; data[p] = d->r_data[p]; d->r_req[p] = 0; }
    }
    for (int p = 0; p < 2; p++) {
      uint64_t want = 0; for (int w = 0; w < 4; w++) want |= uint64_t(ref[off[p] + w]) << (16 * w);
      if (got[p] && data[p] == want) good++; else bad++;
    }
    for (int k = 0; k < 30; k++) step();
  }
  ck("reads answered with the SDRAM burst's words", bad, 0);
  std::printf("  %ld reads right, %ld wrong or missing\n", good, bad);

  // ---- 3. a port that moves on is never answered with the old line
  std::printf("test: a slot that gives up and asks for another line\n");
  {
    const uint32_t A = 0x100, B = 0x200;
    d->r_req[0] = 1; d->r_addr[0] = SBASE + A;
    for (int k = 0; k < 30; k++) step();          // the request has crossed; DDR3 is slow
    d->r_req[0] = 0; for (int k = 0; k < 14; k++) step();
    d->r_addr[0] = SBASE + B; d->r_req[0] = 1;    // a different line now
    uint64_t data = 0; bool got = false;
    for (int k = 0; k < 40000 && !got; k++) { step(); if ((t % 7) == 1 && d->r_ack[0]) { got = true; data = d->r_data[0]; } }
    d->r_req[0] = 0;
    uint64_t want = 0; for (int w = 0; w < 4; w++) want |= uint64_t(ref[B + w]) << (16 * w);
    ck("answered", got, 1);
    ck("with the NEW line, not the old", data == want, 1);
  }
  std::printf("m2_tex_ddr3: checks=%ld fails=%ld (%ld DDR3 beats)\n%s\n", checks, fails, d_beats, fails ? "FAIL" : "PASS");
  delete d; return fails ? 1 : 0;
}
