// R995: m2_video with the gamma curve folded into the translation table,
// against m2_video / m2_palette at 9ba7115a (sim/video/m2_video_r995_miter.sv).
// Whole frames of hashed tile, glyph and palette data; the table written at
// random on its own clock (80 MHz against 100) from power-up values first; the
// gamma choice changed at random cycles; every output -- colour, cat1, syncs,
// blanks, field, x, y and the palette address -- compared EVERY clk_mem cycle,
// and the stream as the framework takes it (sampled on ce_pix) hashed too.
//   +frames=N +seed=S +phase=P (ce accumulator start, 0-99)
//   +il=0/1 +ntsc=0/1 +mid=0/1 +narrow=0/1 +gper=N (cycles between gamma changes)
#include "Vm2_video_r995_miter.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  int frames = 2, phase = 0, il = 0, ntsc = 0, mid = 0, nar = 0; long gper = 997; uint32_t seed = 1;
  for (int i = 1; i < argc; i++) {
    if (!std::strncmp(argv[i], "+frames=", 8)) frames = std::atoi(argv[i] + 8);
    if (!std::strncmp(argv[i], "+seed=", 6))   seed   = std::strtoul(argv[i] + 6, nullptr, 0);
    if (!std::strncmp(argv[i], "+phase=", 7))  phase  = std::atoi(argv[i] + 7);
    if (!std::strncmp(argv[i], "+il=", 4))     il     = std::atoi(argv[i] + 4);
    if (!std::strncmp(argv[i], "+ntsc=", 6))   ntsc   = std::atoi(argv[i] + 6);
    if (!std::strncmp(argv[i], "+mid=", 5))    mid    = std::atoi(argv[i] + 5);
    if (!std::strncmp(argv[i], "+narrow=", 8)) nar    = std::atoi(argv[i] + 8);
    if (!std::strncmp(argv[i], "+gper=", 6))   gper   = std::atol(argv[i] + 6);
  }
  auto *d = new Vm2_video_r995_miter;
  uint32_t rs = seed * 2654435761u + 1;
  auto rnd = [&]() { rs = rs * 1664525u + 1013904223u; return rs >> 8; };
  d->seed = seed; d->rst_n = 0; d->ce_pix = 0; d->gamma_sel = 0; d->xlat_we = 0;
  d->interlace = il; d->ntsc_lines = ntsc; d->mid_lines = mid; d->narrow = nar;
  d->clk = 0; d->xlat_clk = 0; d->eval();
  // clk_mem 100 MHz against clk_sys 80: 5 ns and 6.25 ns half periods, in 0.25 ns steps.
  long t = 0, cyc = 0, checks = 0, fails = 0, px_lit = 0, writes = 0, ces = 0, gch = 0;
  long lit_g[4] = {0, 0, 0, 0};
  uint64_t hn = 1469598103934665603ull, hr = hn;
  const long fcyc = 640L * 424L * 7L;
  const long cycles = long(frames) * fcyc * (il ? 2 : 1);
  int ce_acc = phase % 100;
  while (cyc < cycles) {
    t++;
    bool e_clk = (t % 20) == 0, e_x = (t % 25) == 0;
    if (e_x) { d->xlat_clk = 1; d->eval(); }
    if (e_clk) {
      bool ce_now = d->ce_pix;   // the enable this edge samples with
      d->clk = 1; d->eval();
      cyc++;
      if (cyc == 20) d->rst_n = 1;
      ++checks;
      if (d->px_new != d->px_ref) {
        if (++fails <= 10) std::printf("  FAIL cyc %ld: new %016llx ref %016llx\n", cyc,
                                       (unsigned long long)d->px_new, (unsigned long long)d->px_ref);
      }
      if (ce_now) {   // the framework's / m2_scan15's sample of the stream
        ++ces;
        hn = (hn ^ d->px_new) * 1099511628211ull;
        hr = (hr ^ d->px_ref) * 1099511628211ull;
      }
      if (d->px_new & 0xffffff) { px_lit++; lit_g[d->gamma_sel & 3]++; }
      ce_acc += 16; d->ce_pix = ce_acc >= 100; if (ce_acc >= 100) ce_acc -= 100;
      if (gper > 0 && (cyc % gper) == 0) { d->gamma_sel = rnd() & 3; gch++; }
    }
    if ((t % 20) == 10) { d->clk = 0; d->eval(); }
    if ((t % 25) == 12) {
      d->xlat_clk = 0;
      // No writes for the first quarter frame (power-up table), then bursts.
      bool w = cyc > fcyc / 4 && (rnd() % 64) == 0;
      d->xlat_we = w; d->xlat_addr = rnd() & 0x7f; d->xlat_din = rnd() & 0xff;
      writes += w;
      d->eval();
    }
  }
  std::printf("m2_video r995 (il %d ntsc %d mid %d narrow %d phase %d seed %u): %ld cycles compared, %ld fails;"
              " %ld lit (gsel 0/1/2/3: %ld/%ld/%ld/%ld), %ld table writes, %ld gamma changes;"
              " ce_pix stream %ld samples, hash new %016llx ref %016llx\n%s\n",
              il, ntsc, mid, nar, phase, seed, checks, fails, px_lit, lit_g[0], lit_g[1], lit_g[2], lit_g[3],
              writes, gch, ces, (unsigned long long)hn, (unsigned long long)hr,
              (fails || hn != hr) ? "FAIL" : "PASS");
  delete d;
  return (fails || hn != hr) ? 1 : 0;
}
