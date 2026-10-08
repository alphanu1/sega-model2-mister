// tb_m2_eng_ra -- the geometry engine's read-ahead (R709) against a port that
// answers like m2_sdram_x2 (a request taken on its rising edge, the dword at
// the index and the next one returned LAT cycles later, the pair wrapping
// inside its 512-dword row, the acknowledge held while the request stands),
// read by a requester using R208's handshake.
//
// Objects of engine-like reads: forward walks through polygon data with
// re-reads and short steps back, runs of texture-header reads, jumps, and
// reads straight through (the palette, the table, texture RAM). Between
// reads the engine "works" for a random time, which is when the read-ahead
// fetches. While an object runs, the geometrizer's DMA rewrites polygon data
// and the write lands with `inval`; the CPU rewrites the straight-through
// region with no invalidate at all.
//
// Every answer must be the memory's value at that index -- or the value
// before a write that landed AFTER the read was asked (either is a correct
// order). Also: the port's request never rises while its acknowledge is up,
// `busy` covers every fetch, and it falls within a fetch of the engine going
// idle (the walker waits on it). And the read-ahead must be faster than no
// copies at all (`bypass`).
#include "Vm2_eng_ra.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>

static int checks = 0, fails = 0;
#define CHECK(c, ...) do { ++checks; if (!(c)) { ++fails; if (fails <= 12) { std::printf("  FAIL: " __VA_ARGS__); std::printf("\n"); } } } while (0)

static const uint32_t N = 1u << 16;          // dwords
static const uint32_t POLY0 = 0, POLY1 = 0x8000, TEX0 = 0x8000, TEX1 = 0xC000, PASS0 = 0xC000;

struct Sim {
  Vm2_eng_ra *d;
  int LAT;
  std::vector<uint32_t> mem, prev;
  std::vector<long> wcyc;
  long cyc = 0, trips = 0;
  // port model
  int p_req_d = 0, cnt = -1, done = 0; uint32_t p_idx_l = 0;
  // the DMA / CPU writer
  int wr_rate = 0;            // a write every ~wr_rate cycles while active (0: none)
  uint32_t rng = 1;
  uint32_t rnd() { rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng; }

  Sim(int lat, uint32_t seed) : LAT(lat), mem(N), prev(N), wcyc(N, -1), rng(seed) {
    d = new Vm2_eng_ra;
    for (uint32_t i = 0; i < N; i++) mem[i] = prev[i] = 0xA5000000u ^ (i * 0x9E3779B1u);
    d->clk = 0; d->rst_n = 0; d->req = 0; d->idx = 0; d->stream_en = 0; d->sid = 0;
    d->p_ack = 0; d->p_dout = 0; d->bypass = 0; d->inval = 0; d->active = 0;
    tick(); tick(); d->rst_n = 1; tick();
  }
  ~Sim() { delete d; }

  void write(uint32_t a, bool land_inval) {
    prev[a] = mem[a]; mem[a] = rnd(); wcyc[a] = cyc;
    if (land_inval) d->inval = 1;
  }

  // One clock. Inputs for this cycle are already on the pins.
  void tick() {
    d->eval();
    // the protocol, on this cycle's outputs
    if (d->p_req && !p_req_d) {
      CHECK(!d->p_ack, "cycle %ld: the port's request rose while its acknowledge was up", cyc);
      if (cnt < 0 && !done) { cnt = LAT; p_idx_l = d->p_idx; ++trips; }
    }
    if (d->p_req || d->p_ack) CHECK(d->busy, "cycle %ld: a fetch in flight without busy", cyc);
    p_req_d = d->p_req;
    d->clk = 1; d->eval(); d->clk = 0; d->eval();
    ++cyc;
    d->inval = 0;
    // the port answers: the pair read at completion, wrapping inside its row
    if (cnt > 0 && --cnt == 0) {
      const uint32_t lo = p_idx_l & (N - 1), hi = ((p_idx_l & ~511u) | ((p_idx_l + 1) & 511u)) & (N - 1);
      d->p_dout = (uint64_t(mem[hi]) << 32) | mem[lo];
      done = 1; cnt = -1;
    }
    if (!d->p_req) done = 0;
    d->p_ack = done;
    // writes behind the reader, while an object runs
    if (wr_rate && d->active && (rnd() % wr_rate) == 0) {
      if (rnd() & 1) write(POLY0 + (rnd() % (POLY1 - POLY0)), true);   // the geometrizer's DMA: lands with inval
      else           write(PASS0 + (rnd() % (N - PASS0)), false);      // the CPU, straight-through memory
    }
  }

  int ack_d = 0;
  // One engine read (R208): request until the acknowledge rises, then a cycle
  // with it down.
  void read(uint32_t ix, bool sen, int sid, const char *what) {
    d->idx = ix; d->stream_en = sen; d->sid = sid;
    const long t0 = cyc;
    bool got = false;
    // a read can wait behind one fetch in flight and then make its own two
    // (R709's answer-from-own-fetch); allow that at any latency, not 400
    for (int guard = 0; !got && guard < 400 + 6 * LAT; guard++) {
      d->req = 1;
      d->eval();
      const int go = d->ack && !ack_d; ack_d = d->ack;
      if (go) {
        const uint32_t v = d->data;
        const bool ok = v == mem[ix] || (wcyc[ix] >= t0 && v == prev[ix]);
        CHECK(ok, "%s: idx %05x read %08x, memory %08x (written cycle %ld, asked %ld)", what, ix, v, mem[ix], wcyc[ix], t0);
        got = true;
        break;
      }
      tick();
    }
    CHECK(got, "%s: idx %05x never acknowledged", what, ix);
    d->req = 0; tick();
    { d->eval(); ack_d = d->ack; }
  }
  void work(int n) { d->req = 0; for (int i = 0; i < n; i++) { tick(); d->eval(); ack_d = d->ack; } }
};

// An object: engine-like reads. Returns nothing; checks run inside.
static void object(Sim &s, bool heavy) {
  s.d->active = 1; s.work(1);
  uint32_t p = POLY0 + (s.rnd() % (POLY1 - POLY0 - 4096));
  uint32_t t = TEX0 + (s.rnd() % (TEX1 - TEX0 - 64));
  const int polys = heavy ? 40 : 8;
  for (int q = 0; q < polys; q++) {
    // a polygon record: forward with re-reads and a step back now and then
    const int words = 6 + s.rnd() % 10;
    for (int w = 0; w < words; w++) {
      s.read(p, true, 0, "polygon");
      if ((s.rnd() % 5) == 0) s.read(p, true, 0, "polygon re-read");
      if ((s.rnd() % 9) == 0 && p > POLY0) s.read(p - 1, true, 0, "polygon step back");
      s.work(s.rnd() % 12);
      ++p;
    }
    // its texture header: a short run
    if (s.rnd() & 1) { for (int h = 0; h < 4; h++) { s.read(t + h, true, 1, "texture header"); s.work(s.rnd() % 6); } t += 4; }
    // a colour: straight through
    if ((s.rnd() % 3) == 0) s.read(PASS0 + (s.rnd() % (N - PASS0)), false, 0, "straight through");
    // now and then a jump elsewhere in the polygon data
    if ((s.rnd() % 11) == 0) p = POLY0 + (s.rnd() % (POLY1 - POLY0 - 4096));
  }
  // the engine goes idle: busy must clear within one fetch and a few cycles
  s.d->active = 0; s.d->req = 0;
  int n = 0; do { s.tick(); s.d->eval(); } while (s.d->busy && ++n < s.LAT + 12);
  CHECK(!s.d->busy, "busy still up %d cycles after the engine went idle", n);
  s.work(3);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const int LAT = std::getenv("LAT") ? std::atoi(std::getenv("LAT")) : 12;

  // 1. Correctness under rewrites, several seeds and write rates -- at the
  // board's latency and five times it (a write landing during every fetch is
  // what starves a read that is not answered from its own fetch).
  for (int lat : {LAT, LAT * 5})
  for (uint32_t seed = 1; seed <= 6; seed++)
    for (int rate : {0, 40, 7}) {
      Sim s(lat, seed * 7919 + rate);
      s.wr_rate = rate;
      for (int o = 0; o < 30; o++) object(s, (o % 3) == 0);
    }

  // 2. Bypassed: still correct, and no copy at all.
  {
    Sim s(LAT, 99); s.wr_rate = 7; s.d->bypass = 1;
    for (int o = 0; o < 10; o++) object(s, true);
  }

  // 3. Speed: the same objects, read-ahead against bypass.
  long cyc_ra, cyc_by, tr_ra, tr_by;
  { Sim s(LAT, 4242); for (int o = 0; o < 40; o++) object(s, true); cyc_ra = s.cyc; tr_ra = s.trips; }
  { Sim s(LAT, 4242); s.d->bypass = 1; for (int o = 0; o < 40; o++) object(s, true); cyc_by = s.cyc; tr_by = s.trips; }
  std::printf("  LAT %d: read-ahead %ld cycles, %ld port trips; bypassed %ld cycles, %ld trips (%.0f%% of the time)\n",
              LAT, cyc_ra, tr_ra, cyc_by, tr_by, 100.0 * cyc_ra / cyc_by);
  // (at a latency of a few cycles there is little to hide)
  if (LAT >= 6) CHECK(cyc_ra < cyc_by * 0.8, "read-ahead %ld cycles is not clearly faster than bypassed %ld", cyc_ra, cyc_by);

  std::printf("m2_eng_ra: checks=%d fails=%d\n", checks, fails);
  std::printf(fails ? "FAIL\n" : "PASS\n");
  return fails ? 1 : 0;
}
