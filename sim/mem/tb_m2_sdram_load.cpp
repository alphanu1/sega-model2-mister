// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// tb_m2_sdram_load (R877): WHAT LATENCY THE 2A SOUND BOARD'S PORTS (5: the
// 68000, 6: the SCSP's slot fills, 7: its DSP) SEE FROM m2_sdram UNDER A VIDEO
// LOAD. Not a correctness bench (tb_m2_sdram is that): the same harness, the
// 2A build's thirteen ports and priority class, a synthetic frame -- a render
// phase in which the class ports (1 i960, 2/10/11/12 texel misses, 3 glyphs,
// 4 walker, 8/9 TGP) re-request after a short random think time, then a quiet
// phase -- and the three sound ports at the demand measured in MAME's VF2 /
// Zero Gunner captures (R877). Every sound request's latency is counted from
// its request to its acknowledge in clk_mem cycles.
//
//   LOAD_THINK=<clk_mem mean think time of a video port in the render phase>
//   LOAD_RENDER=<render share of a frame, percent>   LOAD_FRAMES=<frames>
//   LOAD_TRACE=<prefix>   writes <prefix>5/6/7.txt: "issue_cycle latency" per
//                          request (clk_mem), for tb_m2_2a_sound's LAT_TRACE
//   Built with -GPRI=... as Model2.sv's 2A build (make test_m2_sdram_load) or
//   with 5/6/7 added (the R877 fix).
#define main tb_m2_sdram_main_unused
#include "tb_m2_sdram.cpp"
#undef main

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Harness h;
  std::mt19937 rng(877u);
  h.reset();
  const double think   = getenv("LOAD_THINK")  ? atof(getenv("LOAD_THINK"))  : 20.0;
  const double render  = getenv("LOAD_RENDER") ? atof(getenv("LOAD_RENDER")) / 100.0 : 0.75;
  const int    frames  = getenv("LOAD_FRAMES") ? atoi(getenv("LOAD_FRAMES")) : 6;
  const char*  trace   = getenv("LOAD_TRACE");
  const long   FRAME   = 1739000;                       // 100 MHz / 57.5 Hz
  // the sound ports' think time after an acknowledge (clk_mem), from the MAME
  // capture's averages (R877): 68000 ~600 K transactions/s, slot fills ~100 K,
  // the DSP ~300 K -- as a mean gap of 100 MHz / rate less a typical latency
  const double snd_think[3] = {
    getenv("LOAD_T5") ? atof(getenv("LOAD_T5")) : 140.0,
    getenv("LOAD_T6") ? atof(getenv("LOAD_T6")) : 950.0,
    getenv("LOAD_T7") ? atof(getenv("LOAD_T7")) : 300.0 };
  const int vid[] = {1, 2, 3, 4, 8, 9, 10, 11, 12};
  // relative appetite of each video port in the render phase (think x this)
  auto vthink = [&](int p) { return p == 1 ? 3.0 : p == 3 ? 4.0 : p == 4 ? 2.0 : (p == 8 || p == 9) ? 6.0 : 1.0; };
  std::exponential_distribution<double> ex(1.0);
  std::vector<long> next(NP, 0);
  std::vector<std::vector<long>> lat(NP);
  FILE* tf[3] = {nullptr, nullptr, nullptr};
  if (trace) for (int i = 0; i < 3; i++) tf[i] = fopen((std::string(trace) + std::to_string(5 + i) + ".txt").c_str(), "w");
  std::vector<bool> was_busy(NP, false);
  std::vector<long> issued(NP, 0);
  long busy_cyc = 0, total = 0, rbusy = 0, rtotal = 0, wr_next = 0;
  const long t0 = h.cyc;
  auto addr = [&](int p) -> uint32_t {   // each port in its own region, sequential-ish
    static uint32_t seq[16] = {0};
    seq[p] += (rng() % 8 == 0) ? (rng() & 0xfff) : 4;
    const uint32_t bank = (p * 3) & 3;
    return (bank << 23) | ((uint32_t(p) << 18) & 0x7c0000) | (seq[p] & 0x3ffff);
  };
  while (h.cyc - t0 < FRAME * frames) {
    const long t = h.cyc - t0;
    const bool rend = (t % FRAME) < long(render * FRAME);
    for (int p : vid) {
      if (h.port[p].busy || t < next[p] || h.getAck(p)) continue;   // (the CDC: the acknowledge low first)
      if (!rend && (rng() % 64)) { next[p] = t + 64; continue; }   // quiet: a trickle
      h.issue(p, addr(p), false, 0);
      issued[p] = h.cyc;
    }
    for (int i = 0; i < 3; i++) {
      const int p = 5 + i;
      if (h.port[p].busy || t < next[p] || h.getAck(p)) continue;   // (the CDC: the acknowledge low first)
      const bool w = (p == 5 && rng() % 2) || (p == 7 && rng() % 3 == 0);
      h.issue(p, addr(p), w, uint16_t(rng()));
      issued[p] = h.cyc;
    }
    if (!h.wr_busy && rend && t >= wr_next) { h.issueWrite(addr(0) | 0x400000, uint16_t(rng())); wr_next = t + long(think * 4 * ex(rng)); }
    h.step();
    if (h.d->ready) {}
    for (int p = 0; p < NP; p++) {
      if (was_busy[p] && !h.port[p].busy) {
        const long l = h.cyc - issued[p];
        lat[p].push_back(l);
        if (p >= 5 && p <= 7) {
          if (tf[p - 5]) fprintf(tf[p - 5], "%ld %ld\n", issued[p] - t0, l);
          next[p] = (h.cyc - t0) + long(snd_think[p - 5] * ex(rng));
        } else next[p] = (h.cyc - t0) + long(think * vthink(p) * ex(rng));
      }
      was_busy[p] = h.port[p].busy;
    }
    // bus busy: the device model's served counters are cumulative; use the
    // harness's own busy view -- any port in flight
    bool any = h.wr_busy;
    for (int p = 0; p < NP; p++) any |= h.port[p].busy;
    busy_cyc += any; total++;
    if (rend) { rbusy += any; rtotal++; }
  }
  for (int i = 0; i < 3; i++) if (tf[i]) fclose(tf[i]);
  printf("load: think %.0f, render %.0f%%, %d frames; a port in flight %.1f%% of all cycles, %.1f%% of the render phase\n",
         think, render * 100, frames, 100.0 * busy_cyc / total, 100.0 * rbusy / rtotal);
  printf("  port  transactions/s   latency clk_mem: p50   p90   p99  p99.9   max   (x0.8 = clk_sys, + ~4 clk_sys CDC)\n");
  for (int p = 0; p < NP; p++) {
    auto& v = lat[p];
    if (v.empty()) continue;
    std::sort(v.begin(), v.end());
    auto q = [&](double f) { return v[std::min(v.size() - 1, size_t(f * v.size()))]; };
    printf("  %2d %s  %10.0f        %5ld %5ld %5ld %5ld %6ld\n", p, (p >= 5 && p <= 7) ? "snd" : "   ",
           v.size() / (double(frames) * FRAME / 1e8), q(.5), q(.9), q(.99), q(.999), v.back());
  }
  // R881: the ~1.5% "word pair shifted" port 7 reads R877 recorded here were
  // this bench's addresses: bank << 23 set bit 24 of a 24-bit input, which
  // Verilator does not mask, and the harness packs the ports' addresses into one
  // vector -- port 6's bit 24 became port 7's bit 0. Harness::issue masks now,
  // and the shadow check reads 0. tb_m2_sdram_cdc_load is the correctness bench
  // for these ports through the real crossing.
  printf("  device violations %u, data check %ld fails of %ld\n", h.d->violations, h.fails, h.checks);
  return (h.d->violations || h.fails) ? 1 : 0;
}
