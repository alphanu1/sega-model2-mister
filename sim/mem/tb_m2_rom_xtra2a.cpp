// tb_m2_rom_xtra2a -- R862: m2_rom_loader's two remaps as the 2A core sets
// them (SDR_AW 26 since R891 -- 25 before; XTRA 0x2540000 -> word 0x1A00000, the samples; XTRA2
// 0x2D40000 -> word 0x1300000, the extension). Below XTRA a byte lands at its
// own word; from XTRA at XTRA_TO + (byte - XTRA) / 2; from XTRA2 at XTRA2_TO +
// (byte - XTRA2) / 2 -- the last byte of Sega Rally's 0x32C0000 image included.
//
// R897: and the third, XTRA3 0x32C0000 -> word 0x2000000 (byte 0x4000000, the
// upper 64 MB): the large 2A layout's texture-coordinate ROM and polygons.
// Built with -DTB_X3 and Model2.sv's XTRA3 values; without TB_X3 the bench
// expects no third remap (the loader as it was, byte for byte).
//
// Beside the eight fixed bytes, a sweep: one byte in every 4 KB of the whole
// stream the remaps can take (to 0x72C0000, the largest image whose words do
// not wrap) and the words either side of every boundary, each checked against
// the reference map below -- 29,000+ addresses, where the layouts use a
// handful of slot starts, so a remap right only at its own slots fails here.
#include "Vm2_rom_loader.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <map>
#include <set>

static Vm2_rom_loader *d;
static std::map<uint32_t, uint16_t> mem;     // word address -> data, as written
static int checks = 0, fails = 0;
static void tick() {
  d->clk = 0; d->eval();
  d->sdr_wr_ack = 0;
  if (d->sdr_wr_req) { mem[d->sdr_wr_addr] = d->sdr_wr_din; d->sdr_wr_ack = 1; }
  d->clk = 1; d->eval();
}
static void ck(const char *what, uint32_t got, uint32_t want) {
  ++checks; if (got != want) { ++fails; if (fails < 20) std::printf("  FAIL %s: got %x want %x\n", what, got, want); }
}
// the reference: Model2.sv's 2A constants
static uint32_t ref(uint32_t b) {
#ifdef TB_X3
  if (b >= 0x32C0000u) return (0x2000000u + ((b - 0x32C0000u) >> 1)) & 0x3FFFFFFu;
#endif
  if (b >= 0x2D40000u) return (0x1300000u + ((b - 0x2D40000u) >> 1)) & 0x3FFFFFFu;
  if (b >= 0x2540000u) return (0x1A00000u + ((b - 0x2540000u) >> 1)) & 0x3FFFFFFu;
  return b >> 1;
}
static void send(uint32_t b, uint16_t v) {
  while (d->ioctl_wait) tick();
  d->ioctl_addr = b; d->ioctl_dout = v; d->ioctl_wr = 1; tick(); d->ioctl_wr = 0; tick();
}
int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_rom_loader;
  d->rst = 1; d->mem_ready = 0; d->ioctl_download = 0; d->ioctl_index = 0; d->ioctl_wr = 0;
  for (int i = 0; i < 8; i++) tick();
  d->rst = 0; d->mem_ready = 1; for (int i = 0; i < 8; i++) tick();
  d->ioctl_download = 1; tick();
  const int N = 8;
  const uint32_t byte[] = { 0x00000000u, 0x0253FFFEu, 0x02540000u, 0x02D3FFFEu, 0x02D40000u, 0x02D40002u, 0x02EC0000u, 0x032BFFFEu };
  const uint16_t val[]  = { 0x2001,      0x2002,      0x2003,      0x2004,      0x2005,      0x2006,      0x2007,      0x2008 };
  for (int k = 0; k < N; ++k) send(byte[k], val[k]);
  for (int i = 0; i < 2000; i++) tick();
  const uint32_t want[] = { 0x0000000u, 0x129FFFFu, 0x1A00000u, 0x1DFFFFFu, 0x1300000u, 0x1300001u, 0x13C0000u, 0x15BFFFFu };
  for (int k = 0; k < N; ++k) {
    char nm[80]; std::snprintf(nm, sizeof nm, "byte 0x%07X lands at word 0x%07X", byte[k], want[k]);
    ck(nm, mem.count(want[k]) ? mem[want[k]] : 0xdead, val[k]);
  }
  ck("words written", (uint32_t)mem.size(), N);

  // the sweep
  const uint32_t IMG_MAX = 0x72C0000u;
  std::set<uint32_t> pts;
  for (uint32_t b = 0; b < IMG_MAX; b += 0x1000u) pts.insert(b + 0x246u);
  for (uint32_t e : {0x2540000u, 0x2D40000u, 0x32C0000u, 0x42C0000u, 0x4000000u, 0x52C0000u, 0x62C0000u, IMG_MAX})
    for (int o = -4; o <= 2; o += 2) if (e + o < IMG_MAX) pts.insert(e + o);
  mem.clear();
  std::map<uint32_t, uint16_t> sent;
  uint16_t v = 0x3000;
  for (uint32_t b : pts) {
#ifndef TB_X3
    if (b >= 0x32C0000u) continue;   // the images without the third remap end there
#endif
    sent[b] = ++v; send(b, v);
  }
  d->ioctl_download = 0;
  for (int i = 0; i < 4000; i++) tick();
  std::set<uint32_t> words;
  int upper = 0;
  for (auto &kv : sent) {
    const uint32_t w = ref(kv.first);
    words.insert(w);
    if (w & 0x2000000u) ++upper;
    char nm[80]; std::snprintf(nm, sizeof nm, "sweep byte 0x%07X lands at word 0x%07X", kv.first, w);
    ck(nm, mem.count(w) ? mem[w] : 0xdead, kv.second);
  }
  ck("sweep: distinct words written", (uint32_t)mem.size(), (uint32_t)words.size());
  std::printf("m2_rom_xtra2a: %zu sweep bytes, %d of them in the upper 64 MB\n", sent.size(), upper);
  std::printf("m2_rom_xtra2a: checks=%d fails=%d\n%s\n", checks, fails, fails ? "FAIL" : "PASS");
  delete d; return fails ? 1 : 0;
}
