// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// The geometrizer's front door against model2.cpp's own semantics.
//
//   geo_prg_w:      geoctl[31] ? geocnt++ (data DISCARDED) : push_geo_data
//   push_geo_data:  bufferram[wp/4] = d;  wp += 4
//   geo_r:          0x2008 -> wp, 0x3008 -> rp
//
// What is checked, and why each one is here:
//   * the pointers read back what was written -- returning 0 for these is the
//     suspected cause of the R129 livelock
//   * a push advances the write pointer by four, and the game reads it back to
//     find where it is
//   * upload mode COUNTS AND DISCARDS: nothing reaches memory and geocnt moves
//   * every dword lands at the right word address, low half first
//   * A POINTER CHANGE MID-STREAM lands the queued words at the NEW pointer.
//     The first version carried a drain-side counter and would have written
//     them where the pointer used to be -- a plausible display list in the
//     wrong place, which is the worst kind of wrong.
//   * the i960 is never held: pushing far past the queue depth drops and counts
//     rather than backpressuring

#include "Vm2_geo.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <map>
#include <vector>

static Vm2_geo *d;
static int fails = 0, checks = 0;
static std::map<uint32_t,uint16_t> mem;      // SDRAM word address -> data
static const uint32_t BASE = 0x16f0000;

static void tick() {
  // the shared write port: ack a request the cycle after it is seen
  static bool pend = false; static uint32_t pa; static uint16_t pd;
  d->sd_wr_ack = 0;
  if (pend) { mem[pa] = pd; d->sd_wr_ack = 1; pend = false; }
  else if (d->sd_wr_req) { pa = d->sd_wr_addr; pd = d->sd_wr_din; pend = true; }
  d->clk = 0; d->eval(); d->clk = 1; d->eval();
}
static void idle(int n=1){ d->wr_ctl=d->wr_setwp=d->wr_setrp=d->wr_push=0; for(int i=0;i<n;i++) tick(); }
static void w(int which, uint32_t v){
  d->wr_ctl=d->wr_setwp=d->wr_setrp=d->wr_push=0;
  if(which==0) d->wr_ctl=1; else if(which==1) d->wr_setwp=1;
  else if(which==2) d->wr_setrp=1; else d->wr_push=1;
  d->wdata=v; tick(); idle();
}
static void ck(const char*w_,uint32_t got,uint32_t want){
  ++checks; if(got!=want){ std::printf("  FAIL %-38s got=%08x want=%08x\n",w_,got,want); ++fails; }
}

int main(int argc,char**argv){
  Verilated::commandArgs(argc,argv);
  d = new Vm2_geo;
  d->rst_n=0; d->base_buffer=BASE; d->sd_wr_ack=0;
  d->wr_ctl=d->wr_setwp=d->wr_setrp=d->wr_push=0; d->wdata=0;
  for(int i=0;i<8;i++) tick();
  d->rst_n=1; idle(4);

  // ---- 1. the pointers read back
  w(1, 0x00001234); w(2, 0x0000abcd); idle(2);
  ck("write pointer reads back", d->rd_wp, 0x1234);
  ck("read pointer reads back",  d->rd_rp, 0xabcd);

  // ---- 2. a push advances the write pointer by four
  w(1, 0x00000100); idle(2);
  w(3, 0xdeadbeef); idle(2);
  ck("wp advances by 4", d->rd_wp, 0x104);
  for(int i=0;i<40;i++) tick();
  ck("low half at wp/2",      mem[BASE + (0x100>>1)],     0xbeef);
  ck("high half at wp/2 + 1", mem[BASE + (0x100>>1) + 1], 0xdead);

  // ---- 3. upload mode counts and DISCARDS
  mem.clear();
  w(1, 0x00000200); idle();
  w(0, 0x80000000); idle(2);                 // geoctl bit31 -> upload
  uint32_t before = d->dbg_pushes;
  for(int i=0;i<5;i++) w(3, 0x11110000u+i);
  for(int i=0;i<40;i++) tick();
  ck("upload: nothing reached memory", (uint32_t)mem.size(), 0);
  ck("upload: wp did not move",        d->rd_wp, 0x200);
  ck("upload: pushes did not count",   d->dbg_pushes, before);
  ck("upload: geocnt counted 5",       d->dbg_geocnt, 5);
  w(0, 0x00000000); idle(2);                 // boot

  // ---- 4. a run of dwords lands in order
  mem.clear();
  w(1, 0x00000400); idle();
  for(int i=0;i<16;i++) w(3, 0xA0000000u + i);
  for(int i=0;i<400;i++) tick();
  bool ok=true;
  for(int i=0;i<16 && ok;i++){
    uint32_t byte = 0x400 + 4*i, wa = BASE + (byte>>1);
    uint32_t got = mem[wa] | (uint32_t(mem[wa+1])<<16);
    if(got != 0xA0000000u+i){
      std::printf("  FAIL run: dword %d at %05x got %08x want %08x\n", i, byte, got, 0xA0000000u+i);
      ++fails; ok=false;
    }
  }
  ++checks; if(ok) std::printf("  16 dwords in order, halves correct\n");
  ck("wp after 16 pushes", d->rd_wp, 0x400 + 64);

  // ---- 5. THE POINTER MOVES MID-STREAM, and the queued words must follow it.
  // Pushed back-to-back so several are still queued when the pointer changes.
  mem.clear();
  w(1, 0x00000800); idle();
  d->wdata=0xB0000000; d->wr_push=1; tick();
  d->wdata=0xB0000001;               tick();
  d->wr_push=0; tick();
  w(1, 0x00000C00); idle();                   // move it while they are in flight
  d->wdata=0xB0000002; d->wr_push=1; tick();
  d->wr_push=0;
  for(int i=0;i<400;i++) tick();
  {
    uint32_t a=BASE+(0x800>>1), b=BASE+(0x804>>1), c=BASE+(0xC00>>1);
    ck("pre-change dword 0 at 0x800",  mem[a]|(uint32_t(mem[a+1])<<16), 0xB0000000);
    ck("pre-change dword 1 at 0x804",  mem[b]|(uint32_t(mem[b+1])<<16), 0xB0000001);
    ck("post-change dword at 0x C00",  mem[c]|(uint32_t(mem[c+1])<<16), 0xB0000002);
  }

  // ---- 6. the i960 is never held: overrun drops and counts
  mem.clear();
  w(1, 0x00001000); idle();
  uint32_t drop0 = d->dbg_dropped;
  d->wr_push=1;
  for(int i=0;i<4000;i++){ d->wdata=0xC0000000u+i; tick(); }   // no drain time
  d->wr_push=0;
  for(int i=0;i<200;i++) tick();
  ++checks;
  if(d->dbg_dropped == drop0){
    std::printf("  FAIL 4000 pushes into a %d-deep queue dropped nothing\n", 128);
    ++fails;
  } else {
    std::printf("  overrun: %u dropped, counted, never stalled\n", d->dbg_dropped-drop0);
  }

  std::printf("m2_geo: checks=%d fails=%d\n", checks, fails);
  std::printf("%s\n", fails?"FAIL":"PASS");
  delete d; return fails?1:0;
}
