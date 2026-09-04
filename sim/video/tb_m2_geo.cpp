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
  d->frame_start=0; d->rd_data=0; d->rd_ack=0; d->eng_busy=0;
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

  // ---- 7. THE DISPLAY-LIST WALK
  //
  // A SYNTHETIC list with the same shape as Daytona's, because the real one is
  // ROM-derived and must not enter this repository. Walking the real list
  // offline retires 101 opcodes -- 60 object_data, 33 matrix_write, 2 focal,
  // 2 light, 1 zsort, 1 window, 1 texture_data, 1 end -- and this reproduces
  // that mix exactly, plus a JUMP, which the real list also uses.
  //
  // What it proves: every opcode consumes the right number of operand words. A
  // walker that miscounts even once desynchronises and reads operands as
  // commands, which looks like a corrupt display list rather than a bug here.
  {
    std::vector<uint32_t> list(0x8000, 0);
    size_t w = 0;
    auto emit = [&](unsigned op, unsigned operands) {
      list[w++] = op << 23;
      for (unsigned i = 0; i < operands; i++) list[w++] = 0xdead0000u + i;
    };
    int want_ops = 0, want_objs = 0;
    emit(0x08, 1);  want_ops++;                       // zsort
    emit(0x03, 6);  want_ops++;                       // window
    emit(0x09, 2);  want_ops++;                       // focal
    emit(0x09, 2);  want_ops++;
    emit(0x0a, 3);  want_ops++;                       // light
    emit(0x0a, 3);  want_ops++;
    // texture_data: one operand, then a COUNT read from the stream, then count words
    list[w++] = 0x04u << 23; list[w++] = 0x11111111u; list[w++] = 5;
    for (int i = 0; i < 5; i++) list[w++] = 0x22220000u + i;
    want_ops++;
    // a JUMP to the rest of the list, as the real one does after its preamble
    size_t tail = 0x400;
    // A jump counts as a retired opcode: geo_parse's op_count++ sits in the
    // while condition, before the jump is tested.
    list[w++] = 0x80000000u | uint32_t(tail * 4);  want_ops++;
    w = tail;
    for (int i = 0; i < 33; i++) { emit(0x0b, 12); want_ops++; }   // matrix
    for (int i = 0; i < 60; i++) { emit(0x01, 4);  want_ops++; want_objs++; }
    // THE THREE FORMS THAT DIFFER ACROSS THE OPCODE HALVES. Keying the length
    // on the low nibble gets all three wrong, and the board found the first of
    // them: it halted on 0x06 with unknown_opcode set, which is how we learned
    // the game's real list carries commands MAME's frame-900 snapshot did not.
    list[w++] = 0x06u << 23; list[w++] = 0x33333333u; list[w++] = 4;   // 2 + 2*count
    for (int i = 0; i < 8; i++) list[w++] = 0x44440000u + i;
    want_ops++;
    list[w++] = 0x16u << 23; list[w++] = 0x55555555u;                  // lod: 1 word
    want_ops++;
    list[w++] = 0x0du << 23; list[w++] = 0x66666666u; list[w++] = 3;   // 2 + count
    for (int i = 0; i < 3; i++) list[w++] = 0x77770000u + i;
    want_ops++;
    list[w++] = 0x1du << 23; list[w++] = 2;                            // 1 + 3*count
    for (int i = 0; i < 6; i++) list[w++] = 0x88880000u + i;
    want_ops++;
    list[w++] = 0x1eu << 23; list[w++] = 0x99999999u;                  // code_jump: 1
    want_ops++;

    // 0x0e test -- 32 + 1 + 3*blocks. THIS IS THE ONE THAT STOPPED THE BOARD:
    // 141 frames walked, then dbg_walk_unknown reported 0x0e. Its count sits at
    // operand offset 32, behind the FIFO ramp, not at offset 1 like every other
    // count-driven command, so it is the one length the preop/mult table cannot
    // express. Swept 0, 1 and 40 blocks -- 40 is an order of magnitude past any
    // plausible list, per the standing rule that a test which only tries the
    // believed value confirms it instead of testing it.
    for (unsigned blocks : {0u, 1u, 40u}) {
      list[w++] = 0x0eu << 23;
      uint32_t ramp = 1;
      for (int i = 0; i < 32; i++) { list[w++] = ramp; ramp <<= 1; }   // 1,2,4,8...
      list[w++] = blocks;
      for (unsigned b = 0; b < blocks; b++) {
        list[w++] = 0x00100000u + b;   // address
        list[w++] = 0x10u;             // count
        list[w++] = 0xabcd0000u + b;   // checksum
      }
      want_ops++;
    }

    // 0x02/0x12 direct_data -- 8 words, then an attribute loop that ends when
    // the low two bits are clear. Its length is data-dependent, which is why it
    // was left halting; a loop is not the same as an unknown, and MAME's
    // geo_process_command has no default case, so every opcode is measurable.
    // Swept: no vertices at all, a lone tri, a lone quad, and a 30-vertex run
    // alternating tri and quad -- an order of magnitude past a plausible strip,
    // and it is the alternation that would expose a wrong per-vertex stride.
    auto emit_dd = [&](uint32_t op, const std::vector<bool>& quads) {
      list[w++] = op << 23;
      list[w++] = 0x0aa00000u;                       // tpa
      list[w++] = 0x0bb00000u;                       // tha
      for (int i = 0; i < 6; i++) list[w++] = 0x0c000000u + i;   // two xyz points
      for (bool q : quads) {
        list[w++] = q ? 0x00ffff03u : 0x00ffff02u;   // attr: bit0 = quad
        list[w++] = 0x0d000000u;                     // luma
        list[w++] = 0x0e000000u;                     // distance
        for (int i = 0; i < 3; i++) list[w++] = 0x0f000000u + i;      // xyz
        if (q) for (int i = 0; i < 3; i++) list[w++] = 0x11000000u + i; // 4th pt
      }
      list[w++] = 0x00ffff00u;                       // terminator: low 2 bits clear
      want_ops++;
    };
    emit_dd(0x02, {});                                        // no vertices
    emit_dd(0x02, {false});                                   // one tri
    emit_dd(0x12, {true});                                    // one quad
    {
      std::vector<bool> mixed;
      for (int i = 0; i < 30; i++) mixed.push_back(i & 1);
      emit_dd(0x12, mixed);
    }

    emit(0x0f, 0);  want_ops++;                       // end

    d->rst_n = 0; for (int i = 0; i < 4; i++) tick(); d->rst_n = 1; idle(2);
    d->frame_start = 1; tick(); d->frame_start = 0;
    // A STAND-IN GEOMETRY ENGINE. The walk now stops at every object_data
    // until eng_busy has gone high and come back down, so a bench that leaves
    // eng_busy tied low deadlocks at the first object -- which is exactly what
    // this one did, reporting 1 object where 60 were due. Eight cycles is
    // arbitrary; what matters is that busy rises after obj_valid and falls
    // later, because the walker's two-halves wait is the thing under test.
    int eng_cnt = 0;
    for (int i = 0; i < 200000; i++) {
      if (d->obj_valid) eng_cnt = 8;
      d->eng_busy = eng_cnt > 0;
      if (eng_cnt) eng_cnt--;
      d->rd_ack = 0;
      if (d->rd_req) { d->rd_data = (d->rd_addr < list.size()) ? list[d->rd_addr] : 0; d->rd_ack = 1; }
      tick();
      if (d->dbg_walk_frames) break;
    }
    ++checks;
    if (!d->dbg_walk_frames) { std::printf("  FAIL walk never reached end\n"); ++fails; }
    else std::printf("  walk completed: %u opcodes, %u object_data\n",
                     d->dbg_walk_ops, d->dbg_walk_objs);
    ck("walk opcode count", d->dbg_walk_ops,  want_ops);
    ck("walk object_data count", d->dbg_walk_objs, want_objs);
    ck("no unknown opcode", d->dbg_walk_unknown, 0);

    // ---- 7b. THE GEOMETRY STATE IS CAPTURED, NOT STEPPED OVER (R168)
    //
    // Every operand in this list is 0xdead0000 + its index, so the captured
    // words are predictable and their ORDER is checkable -- which is the point.
    // model2_v.cpp reads all three of these as a flat run in order
    // (geo_matrix_write, geo_focal_distance, geo_object_data); a walker that
    // captured them shuffled would still count opcodes correctly and put every
    // polygon in the wrong place.
    ck("matrices captured",  d->dbg_mtx_n, 33);
    ck("focal writes captured", d->dbg_foc_n, 2);
    ck("matrix[0]",  d->mtx0,  0xdead0000);
    ck("matrix[4]",  d->mtx4,  0xdead0004);
    ck("matrix[8]",  d->mtx8,  0xdead0008);
    ck("matrix[11]", d->mtx11, 0xdead000b);
    ck("focus x", d->foc_x, 0xdead0000);
    ck("focus y", d->foc_y, 0xdead0001);
    // object_data: tpa, tha, oba, obc in that order
    ck("object tpa", d->obj_tpa, 0xdead0000);
    ck("object tha", d->obj_tha, 0xdead0001);
    ck("object oba", d->obj_oba, 0xdead0002);
    ck("object obc", d->obj_obc, 0xdead0003);
  }

  // UNWRITTEN MEMORY MUST NOT WALK FOREVER. SDRAM that nobody wrote reads
  // 0xFFFFFFFF, bit 31 is set, and bit 31 means JUMP -- so every word is a jump
  // and the walk re-enters W_FETCH without ever passing through W_SKIP, where
  // the only bound used to live. MAME cannot reach this state because it fills
  // bufferram with 0x07800f0f (an `end`) at reset; we can, and did.
  {
    d->rst_n = 0; for (int i = 0; i < 4; i++) tick(); d->rst_n = 1; idle(2);
    d->frame_start = 1; tick(); d->frame_start = 0;
    bool quiet = false;
    int  idle_run = 0;
    int  eng_cnt = 0;
    for (int i = 0; i < 400000; i++) {
      if (d->obj_valid) eng_cnt = 8;
      d->eng_busy = eng_cnt > 0;
      if (eng_cnt) { eng_cnt--; idle_run = 0; }
      d->rd_ack = 0;
      if (d->rd_req) { d->rd_data = 0xFFFFFFFFu; d->rd_ack = 1; idle_run = 0; }
      else if (++idle_run > 200) { quiet = true; break; }
      tick();
    }
    ++checks;
    if (!quiet) { std::printf("  FAIL walk never stopped on unwritten memory\n"); ++fails; }
    else std::printf("  unwritten memory: walk bounded, stopped requesting\n");
  }

  std::printf("m2_geo: checks=%d fails=%d\n", checks, fails);
  std::printf("%s\n", fails?"FAIL":"PASS");
  delete d; return fails?1:0;
}
