// tb_m2_rom_xtra -- R725: m2_rom_loader's XTRA remap, alone. Built with
// Model2.sv's parameters (SDR_AW 25, XTRA_FROM 0x2BE0000, XTRA_TO 0x1880000):
// download bytes below the '93 image's end must land at their own word
// (byte / 2), bytes from it on at XTRA_TO + (byte - XTRA_FROM) / 2.
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
  const uint32_t byte[] = { 0x00000000u, 0x01640000u, 0x02BDFFFEu, 0x02BE0000u, 0x02BE0002u, 0x02EDFFFEu };
  const uint16_t val[]  = { 0x1001,      0x1002,       0x1003,      0x1004,      0x1005,      0x1006 };
  for (int k = 0; k < 6; ++k) {
    while (d->ioctl_wait) tick();
    d->ioctl_addr = byte[k]; d->ioctl_dout = val[k]; d->ioctl_wr = 1; tick(); d->ioctl_wr = 0; tick();
  }
  d->ioctl_download = 0;
  for (int i = 0; i < 2000; i++) tick();
  const uint32_t want[] = { 0x0000000u, 0x0B20000u, 0x15EFFFFu, 0x1880000u, 0x1880001u, 0x19FFFFFu };
  for (int k = 0; k < 6; ++k) {
    char nm[80]; std::snprintf(nm, sizeof nm, "byte 0x%07X lands at word 0x%07X", byte[k], want[k]);
    ck(nm, mem.count(want[k]) ? mem[want[k]] : 0xdead, val[k]);
  }
  ck("words written", (uint32_t)mem.size(), 6);
  std::printf("m2_rom_xtra: checks=%d fails=%d\n%s\n", checks, fails, fails ? "FAIL" : "PASS");
  delete d; return fails ? 1 : 0;
}
