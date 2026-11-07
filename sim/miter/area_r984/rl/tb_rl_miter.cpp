// m2_rom_loader old against new (sim/miter/miter.py): random downloads at the
// 2A parameters -- ROM and TGP indices, bursts and gaps, mem_ready dropping,
// the SDRAM's ack after a random delay, resets in the middle now and then.
#include "Vm2_rom_loader.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <random>
static Vm2_rom_loader *d;
static void tick() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); }
int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const unsigned seed = getenv("SEED") ? atoi(getenv("SEED")) : 1;
  const long N = getenv("CYC") ? atol(getenv("CYC")) : 5000000;
  std::mt19937 r(seed);
  d = new Vm2_rom_loader;
  d->rst = 1; for (int i = 0; i < 4; i++) tick(); d->rst = 0;
  long writes = 0, acks = 0; int ack_wait = -1; uint32_t addr = 0;
  int mode = 0; long left = 0;
  for (long c = 0; c < N; c++) {
    if (left <= 0) {                       // a new phase
      mode = r() % 8; left = 2000 + r() % 60000;
      if (mode == 0) { d->ioctl_download = 0; }
      else { d->ioctl_download = 1; d->ioctl_index = (mode == 1) ? 1 : (mode == 2 ? 5 : 0);
             addr = (r() % 4 == 0) ? (r() % 60000000) & ~1u : 0; }
    }
    left--;
    d->mem_ready = (r() % 50) != 0;
    d->ioctl_wr = d->ioctl_download && !d->ioctl_wait && (r() % 3 == 0);
    if (d->ioctl_wr) { d->ioctl_addr = addr & 0x7ffffff; d->ioctl_dout = r(); addr += 2; writes++; }
    if (d->sdr_wr_req && ack_wait < 0) ack_wait = r() % 6;
    d->sdr_wr_ack = 0;
    if (ack_wait == 0) { d->sdr_wr_ack = 1; acks++; ack_wait = -1; } else if (ack_wait > 0) ack_wait--;
    d->rst = (r() % 400000) == 0;
    tick();
  }
  printf("tb_rl_miter: seed %u, %ld cycles, %ld writes in, %ld acks\n", seed, N, writes, acks);
  d->final(); delete d; return 0;
}
