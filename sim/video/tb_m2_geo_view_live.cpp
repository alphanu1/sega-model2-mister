// R908: m2_geo_view (R907, one shared int-to-float) against the 2A branch's
// pre-R907 module, both LIVE (the game's CRTC offsets, R852). Each step holds
// a new set of inputs -- the window words and the CRTC offsets, random or at
// the 12/16-bit extremes -- for 8 to 60 cycles. R907's promise is that every
// output is right at most 8 cycles after its inputs change, so from the 8th
// cycle of each hold to its end both modules must agree on all six outputs,
// every cycle. Fewer than 8 cycles' hold is outside the promise and is not
// generated (the window and the offsets change at most once an object).
#include "Vm2_geo_view_live_miter.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
static Vm2_geo_view_live_miter *d;
static uint64_t rs = 0x9E3779B97F4A7C15ull;
static uint32_t rnd() { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return uint32_t(rs >> 16); }
static void tick() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }
static bool same() { for (int i = 0; i < 6; i++) if (d->o_new[i] != d->o_ref[i]) return false; return true; }
static uint32_t f12(int k) {   // a 12-bit field: random, or one of the extremes
  static const uint32_t ex[] = {0x000, 0x7ff, 0x800, 0xfff, 0x001, 0x080, 0x1f0, 0x200, 0x140, 0x0f8};
  return (k & 3) == 0 ? ex[rnd() % 10] : (rnd() & 0xfff);
}
int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_geo_view_live_miter;
  const long steps = argc > 1 ? std::atol(argv[1]) : 200000;
  d->rst_n = 0; d->crtc_x = 0; d->crtc_y = 128;
  d->win_vp_s = 0x00000080; d->win_vp_e = 0x01f00200; d->win_c0 = 0x00f80140;
  tick(); tick();
  long checks = 0, fails = 0;
  if (!same()) { std::printf("  FAIL reset values differ\n"); fails++; }
  d->rst_n = 1;
  static const int16_t cex[] = {0, 128, 127, 90, -8, -1, 32767, -32768, 84, 130};
  for (long s = 0; s < steps; s++) {
    const int k = rnd();
    // junk in the bits outside the 12-bit fields, as the words carry it
    d->win_vp_s = (rnd() & 0xf000f000u) | (f12(k) << 16) | f12(k >> 2);
    d->win_vp_e = (rnd() & 0xf000f000u) | (f12(k >> 4) << 16) | f12(k >> 6);
    d->win_c0   = (rnd() & 0xf000f000u) | (f12(k >> 8) << 16) | f12(k >> 10);
    if ((k >> 12) & 1) d->crtc_x = (k >> 13) & 1 ? cex[rnd() % 10] : int16_t(rnd());
    if ((k >> 14) & 1) d->crtc_y = (k >> 15) & 1 ? cex[rnd() % 10] : int16_t(rnd());
    const int hold = 8 + rnd() % 53;
    for (int c = 1; c <= hold; c++) {
      tick();
      if (c >= 8) {
        ++checks;
        if (!same()) {
          if (++fails <= 10)
            std::printf("  FAIL step %ld cycle %d: vs %08x ve %08x c0 %08x crtc %d,%d new xc %08x yc %08x l %08x r %08x b %08x t %08x ref %08x %08x %08x %08x %08x %08x\n",
                        s, c, d->win_vp_s, d->win_vp_e, d->win_c0, int(int16_t(d->crtc_x)), int(int16_t(d->crtc_y)),
                        d->o_new[0], d->o_new[1], d->o_new[2], d->o_new[3], d->o_new[4], d->o_new[5],
                        d->o_ref[0], d->o_ref[1], d->o_ref[2], d->o_ref[3], d->o_ref[4], d->o_ref[5]);
        }
      }
    }
  }
  std::printf("test: m2_geo_view LIVE (R907) against the pre-R907 module: %ld steps, %ld checks, %ld fails\n", steps, checks, fails);
  std::printf(fails ? "FAIL\n" : "PASS\n");
  delete d;
  return fails ? 1 : 0;
}
