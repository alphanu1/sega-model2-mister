// m2_quad_store old against new (sim/miter/miter.py), random frames at the 2A
// parameters (NX 512, R962's spill): quads in with gaps, the sort, then bands
// replayed with random out_ready; now and then a replay_start in the middle of
// a band, the banks equal, or the bank inputs moved while a band is out.
// ofree (the other list done with) is low, high, or rises during the
// collection; in_stall is honoured most of the time and ignored now and then,
// and one list in six is 1,800-2,800 quads (past 2,048 is the spill).
#include "Vm2_quad_store.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <random>
static Vm2_quad_store *d;
static unsigned long cyc = 0;
static void tick() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); cyc++; }
int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const unsigned seed = getenv("SEED") ? atoi(getenv("SEED")) : 1;
  const long FRAMES = getenv("FRAMES") ? atol(getenv("FRAMES")) : 200;
  std::mt19937 r(seed);
  d = new Vm2_quad_store;
  d->rst_n = 0; d->clk = 0;
  for (int i = 0; i < 5; i++) tick();
  d->rst_n = 1;
  long quads = 0, bands = 0, outs = 0, spill = 0;
  for (long f = 0; f < FRAMES; f++) {
    const int wb = f & 1;
    d->wbank = wb; d->rbank = (r() % 16 == 0) ? wb : !wb;
    const int ofm = r() % 3;   // 0: ofree low, 1: high, 2: rises during the list
    d->ofree = (ofm == 1);
    d->clear = 1; tick(); d->clear = 0;
    const int nq = (r() % 6 == 0) ? 1800 + (int)(r() % 1000) : (r() % 8 == 0) ? (int)(r() % 1800) : (int)(r() % 300);
    for (int q = 0; q < nq; q++) {
      if (ofm == 2 && r() % 600 == 0) d->ofree = 1;
      for (int w = 0; d->in_stall && w < 3000 && r() % 400 != 0; w++) {
        if (ofm == 2 && r() % 500 == 0) d->ofree = 1;
        tick();
      }
      const int cx = (int)(r() % 1200) - 300, cy = (int)(r() % 900) - 200;
      const int sz = (r() % 4 == 0) ? (int)(r() % 6) : (int)(r() % 200);
      int16_t xs[4], ys[4];
      for (int k = 0; k < 4; k++) { xs[k] = cx + (int)(r() % (sz + 1)) - sz / 2; ys[k] = cy + (int)(r() % (sz + 1)) - sz / 2; }
      d->in_x0 = xs[0]; d->in_y0 = ys[0]; d->in_x1 = xs[1]; d->in_y1 = ys[1];
      d->in_x2 = xs[2]; d->in_y2 = ys[2]; d->in_x3 = xs[3]; d->in_y3 = ys[3];
      d->in_col = r() & 0xffffff; d->in_z = r(); d->in_moire = r() & 1;
      d->in_u0 = r(); d->in_v0 = r(); d->in_u1 = r(); d->in_v1 = r();
      d->in_u2 = r(); d->in_v2 = r(); d->in_u3 = r(); d->in_v3 = r();
      d->in_oz0 = r(); d->in_oz1 = r(); d->in_oz2 = r(); d->in_oz3 = r();
      d->in_frac = r(); d->in_tex = r() & 0xfffffff; d->in_vx = r() & 1; d->in_mipz = r() & 1;
      d->in_valid = 1; tick(); d->in_valid = 0; quads++;
      while (r() % 3 == 0) tick();
    }
    for (int i = 0; i < 4; i++) tick();
    if (d->dbg_count > 2048) spill++;
    d->sort_start = 1; tick(); d->sort_start = 0;
    for (long c = 0; d->sort_busy && c < 2000000; c++) tick();
    const int nb = 1 + r() % 12;
    for (int b = 0; b < nb; b++) {
      d->replay_band = r() % 48;
      d->replay_start = 1; tick(); d->replay_start = 0; bands++;
      const int rdy = r() % 4;   // 0: always ready, else ready 1 in rdy+1
      for (long c = 0; c < 400000; c++) {
        d->out_ready = (rdy == 0) || (r() % (rdy + 1) == 0);
        if (d->out_valid && d->out_ready) outs++;
        if (r() % 20000 == 0) { d->replay_band = r() % 48; d->replay_start = 1; }   // restarted mid-band
        if (r() % 30000 == 0) d->rbank = !d->rbank;                               // banks moved under it
        tick(); d->replay_start = 0;
        if (!d->replay_busy && c > 4) break;
      }
      d->out_ready = 0;
      for (int i = 0; i < (int)(r() % 4); i++) tick();
    }
  }
  printf("tb_qs_miter: seed %u, %ld frames, %ld quads, %ld bands, %ld quads out, %ld lists past 2048, %lu cycles\n",
         seed, FRAMES, quads, bands, outs, spill, cyc);
  d->final(); delete d;
  return 0;
}
