// R907: m2_video with the translation table as three MLAB arrays, against the
// single 96-entry array it replaced (sim/video/m2_video_xlat_miter.sv). Whole
// frames of hashed tile, glyph and palette data; the table written at random
// (every address 0-127, channel 3 included) on its own clock, from power-up
// values first. Every cycle's pixel, syncs and palette address must agree.
#include "Vm2_video_xlat_miter.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  int frames = 4; uint32_t seed = 1;
  for (int i = 1; i < argc; i++) {
    if (!std::strncmp(argv[i], "+frames=", 8)) frames = std::atoi(argv[i] + 8);
    if (!std::strncmp(argv[i], "+seed=", 6))   seed   = std::strtoul(argv[i] + 6, nullptr, 0);
  }
  auto *d = new Vm2_video_xlat_miter;
  uint32_t rs = seed * 2654435761u + 1;
  auto rnd = [&]() { rs = rs * 1664525u + 1013904223u; return rs >> 8; };
  d->seed = seed; d->rst_n = 0; d->ce_pix = 0; d->gamma_sel = 0; d->xlat_we = 0;
  d->clk = 0; d->xlat_clk = 0; d->eval();
  // clk_mem 100 MHz against clk_sys 80: 5 ns and 6.25 ns half periods, in 0.25 ns steps.
  long t = 0, cyc = 0, checks = 0, fails = 0, px_lit = 0, writes = 0;
  const long cycles = long(frames) * 640L * 424L * 7L;   // ~ a frame at ce 1 in 6-7
  int ce_acc = 0;
  while (cyc < cycles) {
    t++;
    bool e_clk = (t % 20) == 0, e_x = (t % 25) == 0;
    if (e_x) {   // the writers' clock: inputs change on its falling side
      d->xlat_clk = 1; d->eval();
    }
    if (e_clk) {
      d->clk = 1; d->eval();
      cyc++;
      if (cyc == 20) d->rst_n = 1;
      ++checks;
      if (d->px_new != d->px_ref || d->pal_new != d->pal_ref) {
        if (++fails <= 10) std::printf("  FAIL cyc %ld: new %08x ref %08x pal %03x/%03x\n", cyc,
                                       d->px_new, d->px_ref, d->pal_new, d->pal_ref);
      }
      if (d->px_new & 0xffffff) px_lit++;
      ce_acc += 16; d->ce_pix = ce_acc >= 100; if (ce_acc >= 100) ce_acc -= 100;
      if ((cyc % 100000) == 0) d->gamma_sel = rnd() & 3;
    }
    if ((t % 20) == 10) { d->clk = 0; d->eval(); }
    if ((t % 25) == 12) {
      d->xlat_clk = 0;
      // No writes for the first frame (power-up table), then bursts.
      bool w = cyc > 640L * 424L * 7L && (rnd() % 64) == 0;
      d->xlat_we = w; d->xlat_addr = rnd() & 0x7f; d->xlat_din = rnd() & 0xff;
      writes += w;
      d->eval();
    }
  }
  std::printf("m2_video xlat: %ld cycles compared, %ld with a lit pixel, %ld table writes, %ld fails\n%s\n",
              checks, px_lit, writes, fails, fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
