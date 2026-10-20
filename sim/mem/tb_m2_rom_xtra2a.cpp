// tb_m2_rom_xtra2a -- R862: m2_rom_loader's two remaps as the 2A core sets
// them (SDR_AW 26 since R891 -- 25 before; XTRA 0x2540000 -> word 0x1A00000, the samples; XTRA2
// 0x2D40000 -> word 0x1300000, the extension). Below XTRA a byte lands at its
// own word; from XTRA at XTRA_TO + (byte - XTRA) / 2; from XTRA2 at XTRA2_TO +
// (byte - XTRA2) / 2 -- the last byte of Sega Rally's 0x32C0000 image included.
#include "Vm2_rom_loader.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <map>

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
  ++checks; if (got != want) { ++fails; std::printf("  FAIL %s: got %x want %x\n", what, got, want); }
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
  for (int k = 0; k < N; ++k) {
    while (d->ioctl_wait) tick();
    d->ioctl_addr = byte[k]; d->ioctl_dout = val[k]; d->ioctl_wr = 1; tick(); d->ioctl_wr = 0; tick();
  }
  d->ioctl_download = 0;
  for (int i = 0; i < 2000; i++) tick();
  const uint32_t want[] = { 0x0000000u, 0x129FFFFu, 0x1A00000u, 0x1DFFFFFu, 0x1300000u, 0x1300001u, 0x13C0000u, 0x15BFFFFu };
  for (int k = 0; k < N; ++k) {
    char nm[80]; std::snprintf(nm, sizeof nm, "byte 0x%07X lands at word 0x%07X", byte[k], want[k]);
    ck(nm, mem.count(want[k]) ? mem[want[k]] : 0xdead, val[k]);
  }
  ck("words written", (uint32_t)mem.size(), N);
  std::printf("m2_rom_xtra2a: checks=%d fails=%d\n%s\n", checks, fails, fails ? "FAIL" : "PASS");
  delete d; return fails ? 1 : 0;
}
