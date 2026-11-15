// R1021: m2_scsp_regs old against new under random stimulus. Built against
// sim/miter/miter.py's m2_scsp_regs miter (sim/miter/scsp_regs.sh): every
// input random on every clock -- the register mostly a timer's (0x418-0x41c),
// writes with random data and byte enables, tick44, the write phase, exact,
// tarc, MIDI in and out -- and beside the miter's output compare, the two
// copies' timer and interrupt state compared on every clock too.
//   RR_N=<cycles> RR_SEED=<n>
#include "Vm2_scsp_regs.h"
#include "Vm2_scsp_regs___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
static uint64_t s = 1;
static inline uint32_t rnd() { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return (uint32_t)(s >> 11); }
int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  uint64_t N = getenv("RR_N") ? strtoull(getenv("RR_N"), 0, 0) : 10000000ull;
  s = getenv("RR_SEED") ? strtoull(getenv("RR_SEED"), 0, 0) : 1; if (!s) s = 1;
  Vm2_scsp_regs *t = new Vm2_scsp_regs;
  auto *r = t->rootp;
  uint64_t bad = 0, fires = 0, twr = 0; unsigned exact = 0, tarc = 0, last_ipl = 0;
  t->clk = 0; t->rst_n = 0; t->eval();
  for (uint64_t c = 0; c < N; c++) {
    if (c == 4) t->rst_n = 1;
    if ((c & 1023) == 0) exact = rnd() & 1;
    if ((c % 9973) == 0) tarc = rnd() & 1;
    uint32_t x = rnd(), y = rnd();
    unsigned a;
    switch (x & 7) {
      case 0: case 1: case 2: case 3: a = 0x0c + (y % 3); break;   // a timer
      case 4: a = 0x10 + (y & 1); break;                           // SCIPD / SCIRE
      case 5: a = 0x0f + 2 * (y & 3) % 7; break;                   // SCIEB, the levels
      default: a = y & 31; break;
    }
    t->a = a;
    t->we = ((x >> 3) & 3) == 0;
    t->d = rnd() & 0xffff;
    t->be = (x >> 5) & 3;
    t->mi_pop = ((x >> 7) & 63) == 0;
    t->mon = rnd() & 0xffff;
    t->tick44 = ((x >> 13) & 7) == 0;
    t->exact = exact;
    t->tph = (x >> 16) & 63;
    t->tarc = tarc;
    t->midi_data = (x >> 22) & 255;
    t->midi_valid = ((y >> 8) & 31) == 0;
    t->mout_ack = (y >> 13) & 1;
    if (t->we && a >= 0x0c && a <= 0x0e) twr++;
    t->clk = 1; t->eval();
    t->clk = 0; t->eval();
    if (t->ipl != last_ipl) { if (t->ipl) fires++; last_ipl = t->ipl; }
    // the timer and interrupt state of the two copies
#define CMP(f) if (r->m2_scsp_regs__DOT__u_new__DOT__##f != r->m2_scsp_regs__DOT__u_old__DOT__##f) { if (bad < 10) printf("state %s differs at cycle %llu\n", #f, (unsigned long long)c); bad++; }
    CMP(due) CMP(tarm) CMP(texp) CMP(fired) CMP(late) CMP(dph) CMP(scipd) CMP(mcipd) CMP(lines)
  }
  printf("RR %llu cycles, %llu timer writes, %llu ipl rises, %llu state differences\n",
         (unsigned long long)N, (unsigned long long)twr, (unsigned long long)fires, (unsigned long long)bad);
  t->final(); delete t;
  return bad ? 1 : 0;
}
