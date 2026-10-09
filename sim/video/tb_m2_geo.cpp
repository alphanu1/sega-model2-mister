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
static std::map<uint32_t,uint16_t> mem;
static bool trace_wr = false;      // SDRAM word address -> data
static const uint32_t BASE = 0x16f0000;

// R610: until the walker tests take over the read side, a read is answered
// with an `end` (MAME's own bufferram fill, 0x07800f0f), so a walk the pointer
// writes trigger finishes as it would on hardware. The push queue now holds
// while a walk runs, so a walk left waiting on a read that never comes would
// keep every push out of memory -- a bench artefact, since the board always
// answers.
static bool auto_end = true;
// R638: a walker served from `mem` itself, one read every rd_slow cycles, so a
// pushed word that drains ahead of the walk is one the walk really reads.
static int rd_slow = 0, rd_cnt = 0;
static int wr_slow = 0, wr_cnt = 0;   // R752
static uint16_t rdm(uint32_t a){ auto it = mem.find(a); return it == mem.end() ? 0xFFFF : it->second; }
static void tick() {
  if (rd_slow) { d->rd_ack = 0;
    if (d->rd_req && ++rd_cnt >= rd_slow) { rd_cnt = 0;
      uint32_t a = BASE + (uint32_t(d->rd_addr) << 1);
      d->rd_data = uint32_t(rdm(a)) | (uint32_t(rdm(a + 1)) << 16); d->rd_ack = 1; } }
  if (auto_end) { d->rd_ack = 0; if (d->rd_req) { d->rd_data = 0x07800f0fu; d->rd_ack = 1; } }
  // the shared write port: ack a request the cycle after it is seen, or
  // wr_slow cycles after (R752: a port busy with other owners)
  static bool pend = false; static uint32_t pa; static uint16_t pd;
  d->sd_wr_ack = 0;
  if (pend && ++wr_cnt >= wr_slow) { wr_cnt = 0; mem[pa] = pd; d->sd_wr_ack = 1; pend = false;
              if (trace_wr) std::printf("    WR %08x <= %04x\n", pa, pd); }
  else if (d->sd_wr_req) { pa = d->sd_wr_addr; pd = d->sd_wr_din; pend = true; }
  d->clk = 0; d->eval(); d->clk = 1; d->eval();
}
static void idle(int n=1){ d->wr_ctl=d->wr_setwp=d->wr_setrp=d->wr_push=0; for(int i=0;i<n;i++) tick(); }
static void w(int which, uint32_t v){
  d->wr_ctl=d->wr_setwp=d->wr_setrp=d->wr_push=0;
  if(which==0) d->wr_ctl=1; else if(which==1) d->wr_setwp=1;
  else if(which==2) d->wr_setrp=1; else d->wr_push=1;
  d->wdata=v;
  // R260: THE PUSH IS HELD WHILE `push_stall` IS HIGH, exactly as the bridge
  // holds an I/O access while `io_stall` is high -- select asserted, same data,
  // until it is taken. A pusher that ignores the stall loses the word silently,
  // which is worse than the drop this replaces.
  d->eval();
  for(int guard=0; which==3 && d->push_stall && guard<4096; ++guard) tick();
  tick(); idle();
}
static void ck(const char*w_,uint32_t got,uint32_t want){
  ++checks; if(got!=want){ std::printf("  FAIL %-38s got=%08x want=%08x\n",w_,got,want); ++fails; }
}

int main(int argc,char**argv){
  Verilated::commandArgs(argc,argv);
  d = new Vm2_geo;
  d->rst_n=0; d->base_buffer=BASE; d->sd_wr_ack=0;
  d->frame_start=0; d->rd_data=0; d->rd_ack=0; d->eng_busy=0;
  d->base_pram0 = 0x1710000; d->base_pram1 = 0x1720000; d->base_texram = 0x1740000;
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

  // ---- 6. R260: THE I960 IS HELD, AND NOTHING IS LOST.
  //
  // This used to assert the opposite -- that an overrun DROPS and counts, and
  // never stalls. The board says what that costs: the queue drops continuously,
  // and a drop is a hole in the display list because the write pointer
  // deliberately does not advance, so the next dword takes the missing one's
  // slot. The reference has no queue and cannot drop; it writes bufferram and
  // returns. Measured against it, the light table the game writes in one
  // 64-word command has no zero entry anywhere, and the board's copy had
  // nineteen. So the contract is now backpressure: hold the pusher, drop
  // nothing.
  mem.clear();
  w(1, 0x00001000); idle();
  uint32_t drop0 = d->dbg_dropped;
  for(int i=0;i<4000;i++) w(3, 0xC0000000u+i);
  for(int i=0;i<400;i++) tick();
  ++checks;
  if(d->dbg_dropped != drop0){
    std::printf("  FAIL 4000 held pushes still dropped %u\n", d->dbg_dropped-drop0);
    ++fails;
  } else {
    std::printf("  overrun: 4000 pushes, none dropped -- the pusher was held\n");
  }
  // and the write pointer advanced once per dword, so the list has no hole
  ck("write pointer after 4000 held pushes", d->dbg_wp, 0x00001000u + 4000u*4u);

  auto_end = false;   // R610: the walker tests serve their own reads from here
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

  // ---- geo_translate_write updates the matrix's TRANSLATION ROW
  //
  // 0x0c writes matrix[9..11] and nothing else. It rides the same mat_we /
  // mat_idx stream as 0x0b, offset by nine, so m2_geo_xform needs no knowledge
  // of which opcode a row came from. While this was a blind skip a game that
  // set rotation once and then moved objects with 0x0c would draw every one of
  // them at a stale position -- right shape, wrong place.
  {
    std::vector<uint32_t> list(0x800, 0);
    size_t w = 0;
    list[w++] = 0x0cu << 23;
    list[w++] = 0x40400000u;      // 3.0
    list[w++] = 0x40800000u;      // 4.0
    list[w++] = 0x40a00000u;      // 5.0
    list[w++] = 0x0fu << 23;

    d->rst_n = 0; for (int i = 0; i < 4; i++) tick(); d->rst_n = 1; idle(2);
    d->frame_start = 1; tick(); d->frame_start = 0;
    unsigned seen_idx[3] = {99,99,99}, seen_dat[3] = {0,0,0};
    int n = 0;
    for (int i = 0; i < 100000; i++) {
      d->rd_ack = 0;
      if (d->rd_req) { d->rd_data = (d->rd_addr < list.size()) ? list[d->rd_addr] : 0; d->rd_ack = 1; }
      // mat_we is COMBINATIONAL on wst and rd_ack, so it has to be sampled
      // during the cycle its inputs describe. Reading it after tick() reads the
      // value belonging to the NEXT state and misses the first write entirely --
      // which showed up as rows 10 and 11 arriving and row 9 never doing.
      d->eval();
      if (d->mat_we && n < 3) { seen_idx[n] = d->mat_idx; seen_dat[n] = d->mat_data; n++; }
      tick();
      if (d->dbg_walk_frames) break;
    }
    std::printf("test: geo_translate_write writes matrix rows 9,10,11\n");
    ck("three matrix writes", (uint32_t)n, 3);
    ck("row index 9",  seen_idx[0], 9);
    ck("row index 10", seen_idx[1], 10);
    ck("row index 11", seen_idx[2], 11);
    ck("translate x",  seen_dat[0], 0x40400000u);
    ck("translate y",  seen_dat[1], 0x40800000u);
    ck("translate z",  seen_dat[2], 0x40a00000u);
    ck("mtx11 mirrors it", d->mtx11, 0x40a00000u);
  }

  // ---- geo_texture_parameters supplies diffuse and ambient
  //
  // luminance * texparam->diffuse + texparam->ambient, with the entry chosen
  // per polygon by (attr >> 18) & 0x1f. Two words per entry -- the packed
  // parameters then a coefficient only the specular parser reads -- and the
  // index wraps at 32, which is why the test writes across the wrap.
  {
    std::vector<uint32_t> list(0x800, 0);
    size_t w = 0;
    list[w++] = 0x06u << 23;
    list[w++] = 0x1e << 2;        // base index 30, so entry 3 wraps to 0
    list[w++] = 4;                // four entries: 30, 31, 0, 1
    list[w++] = 0x0000A011u; list[w++] = 0xdeadbeefu;   // diff 0x11 amb 0xA0
    list[w++] = 0x0000B022u; list[w++] = 0xdeadbeefu;   // diff 0x22 amb 0xB0
    list[w++] = 0x0000C033u; list[w++] = 0xdeadbeefu;   // diff 0x33 amb 0xC0
    list[w++] = 0x0000D044u; list[w++] = 0xdeadbeefu;   // diff 0x44 amb 0xD0
    list[w++] = 0x0fu << 23;

    d->rst_n = 0; for (int i = 0; i < 4; i++) tick(); d->rst_n = 1; idle(2);
    d->frame_start = 1; tick(); d->frame_start = 0;
    struct TP { unsigned idx, diff, amb; };
    std::vector<TP> tps;
    for (int i = 0; i < 100000; i++) {
      d->rd_ack = 0;
      if (d->rd_req) { d->rd_data = (d->rd_addr < list.size()) ? list[d->rd_addr] : 0; d->rd_ack = 1; }
      d->eval();
      if (d->tp_we) tps.push_back({d->tp_idx, d->tp_diffuse, d->tp_ambient});
      tick();
      if (d->dbg_walk_frames) break;
    }
    std::printf("test: geo_texture_parameters fills the diffuse/ambient table\n");
    ck("commands seen", d->dbg_tp_n, 1);
    ck("four entries written", (uint32_t)tps.size(), 4);
    if (tps.size() >= 4) {
      ck("entry 0 index 30", tps[0].idx, 30);  ck("entry 0 diffuse", tps[0].diff, 0x11);
      ck("entry 0 ambient",  tps[0].amb, 0xA0);
      ck("entry 1 index 31", tps[1].idx, 31);  ck("entry 1 diffuse", tps[1].diff, 0x22);
      ck("index WRAPS to 0",  tps[2].idx, 0);  ck("entry 2 diffuse", tps[2].diff, 0x33);
      ck("entry 3 index 1",   tps[3].idx, 1);  ck("entry 3 ambient", tps[3].amb, 0xD0);
    }
    ck("the walk still finished", d->dbg_walk_frames ? 1u : 0u, 1u);
  }

  // ---- geo_light_source is captured, not stepped over
  //
  // Model 2's lighting is dot(normal, light) against dot(normal, point), so the
  // light vector is half of every luminance the renderer will ever compute.
  // While 0x0a was a blind skip there was no light at all.
  {
    std::vector<uint32_t> list(0x800, 0);
    size_t w = 0;
    list[w++] = 0x0au << 23;
    list[w++] = 0x3f800000u;      // 1.0
    list[w++] = 0xbf800000u;      // -1.0
    list[w++] = 0x40000000u;      // 2.0
    list[w++] = 0x0fu << 23;

    d->rst_n = 0; for (int i = 0; i < 4; i++) tick(); d->rst_n = 1; idle(2);
    d->frame_start = 1; tick(); d->frame_start = 0;
    for (int i = 0; i < 100000; i++) {
      d->rd_ack = 0;
      if (d->rd_req) { d->rd_data = (d->rd_addr < list.size()) ? list[d->rd_addr] : 0; d->rd_ack = 1; }
      tick();
      if (d->dbg_walk_frames) break;
    }
    std::printf("test: geo_light_source is captured\n");
    ck("light captured once", d->dbg_lit_n, 1);
    ck("light x", d->lit_x, 0x3f800000u);
    ck("light y", d->lit_y, 0xbf800000u);
    ck("light z", d->lit_z, 0x40000000u);
    ck("the walk still finished", d->dbg_walk_frames ? 1u : 0u, 1u);
  }

  // ---- R222: geo_texture_data with bit 23 set lands in TEXTURE RAM, low
  //      16 bits of each payload dword at base_texram + ((addr + i) & 0xffff);
  //      with bit 23 clear (log RAM) it is stepped over by its count, as before.
  {
    const uint32_t TEXRAM = 0x1740000;
    mem.clear();
    std::vector<uint32_t> list(0x8000, 0);
    size_t w = 0;
    list[w++] = 0x04u << 23;                      // texture RAM at word 0xfffe: wraps
    list[w++] = 0x0080fffeu;
    list[w++] = 4;
    list[w++] = 0xAAAA1111u; list[w++] = 0xBBBB2222u; list[w++] = 0xCCCC3333u; list[w++] = 0xDDDD4444u;
    list[w++] = 0x04u << 23;                      // log RAM: skipped
    list[w++] = 0x00001000u;
    list[w++] = 3;
    list[w++] = 0x55555555u; list[w++] = 0x66666666u; list[w++] = 0x77777777u;
    list[w++] = 0x05u << 23;                      // and polygon RAM still works after it
    list[w++] = 0x00000040u;
    list[w++] = 1;
    list[w++] = 0x12345678u;
    list[w++] = 0x0fu << 23;                      // end

    d->rst_n = 0; for (int i = 0; i < 4; i++) tick(); d->rst_n = 1; idle(2);
    d->frame_start = 1; tick(); d->frame_start = 0;
    for (int i = 0; i < 200000; i++) {
      d->eng_busy = 0;
      d->rd_ack = 0;
      if (d->rd_req) { d->rd_data = (d->rd_addr < list.size()) ? list[d->rd_addr] : 0; d->rd_ack = 1; }
      tick();
      if (d->dbg_walk_frames) break;
    }
    auto rd = [&](uint32_t a) -> uint32_t { auto it = mem.find(a); return it == mem.end() ? 0xffffu : it->second; };
    std::printf("test: geo_texture_data writes texture RAM (R222)\n");
    ck("texture words written",        d->dbg_td_words, 4);
    ck("polygon dwords still counted", d->dbg_pd_words, 1);
    ck("texram[0xfffe]", rd(TEXRAM + 0xfffe), 0x1111);
    ck("texram[0xffff]", rd(TEXRAM + 0xffff), 0x2222);
    ck("texram[0x0000] (wrapped)", rd(TEXRAM + 0x0000), 0x3333);
    ck("texram[0x0001] (wrapped)", rd(TEXRAM + 0x0001), 0x4444);
    ck("no high half written", rd(TEXRAM + 0x0002), 0xffff);
    ck("log RAM data went nowhere", rd(TEXRAM + 0x1000), 0xffff);
    ck("polygon RAM dword after it", rd(0x1710000 + 0x80) | (rd(0x1710000 + 0x81) << 16), 0x12345678u);
  }

  // ---- geo_polygon_data ACTUALLY COPIES, and to the right polygon RAM
  //
  // This is the command the whole 3D path was waiting on. The board reported
  // Daytona's object_data pointing at SLOW POLYGON RAM and never at the polygon
  // ROM -- objects rom=0, pram0=1 -- and 0x05 is what fills that RAM. While it
  // was a blind skip, every object read unwritten memory, which is NaN.
  //
  // Both destinations are exercised because the bit that chooses between them
  // (0x01000000) is one bit, and a wrong polarity puts every polygon in the
  // wrong memory while every count and every length still looks right.
  {
    const uint32_t PRAM0 = 0x1710000, PRAM1 = 0x1720000;
    mem.clear();                                  // unwritten: see rdw() below
    std::vector<uint32_t> list(0x8000, 0);
    size_t w = 0;
    // slow polygon RAM at dword 0x40, three words
    list[w++] = 0x05u << 23;
    list[w++] = 0x00000040u;
    list[w++] = 3;
    list[w++] = 0x11111111u; list[w++] = 0x22222222u; list[w++] = 0x33333333u;
    // fast polygon RAM at dword 0x10, two words
    list[w++] = 0x05u << 23;
    list[w++] = 0x01000010u;
    list[w++] = 2;
    list[w++] = 0xAAAAAAAAu; list[w++] = 0xBBBBBBBBu;
    list[w++] = 0x0fu << 23;                      // end

    d->rst_n = 0; for (int i = 0; i < 4; i++) tick(); d->rst_n = 1; idle(2);
    d->frame_start = 1; tick(); d->frame_start = 0;
    int eng_cnt = 0;
    trace_wr = true;
    for (int i = 0; i < 200000; i++) {
      if (d->obj_valid) eng_cnt = 8;
      d->eng_busy = eng_cnt > 0;
      if (eng_cnt) eng_cnt--;
      d->rd_ack = 0;
      if (d->rd_req) { d->rd_data = (d->rd_addr < list.size()) ? list[d->rd_addr] : 0; d->rd_ack = 1; }
      tick();
      if (d->dbg_walk_frames) break;
    }
    trace_wr = false;
    std::printf("test: geo_polygon_data copies into polygon RAM\n");
    std::printf("  %u commands, %u dwords written\n", d->dbg_pd_cmds, d->dbg_pd_words);
    ck("polygon_data commands", d->dbg_pd_cmds,  2);
    ck("polygon_data dwords",   d->dbg_pd_words, 5);
    // A dword lands as two 16-bit halves at base + (index << 1) and +1.
    // UNWRITTEN MEMORY READS 0xFFFF, NEVER ZERO -- the standing requirement in
    // docs/mister-integration.md, and the one whose absence let a NaN wedge the
    // whole geometry pipeline. mem is sparse, so absence is the unwritten case.
    auto rdw = [&](uint32_t a) -> uint16_t {
      auto it = mem.find(a);
      return (it == mem.end()) ? uint16_t(0xFFFF) : it->second;
    };
    auto rd32 = [&](uint32_t base, uint32_t dwidx) -> uint32_t {
      uint32_t a = base + (dwidx << 1);
      return (uint32_t(rdw(a + 1)) << 16) | uint32_t(rdw(a));
    };
    ck("slow pram dword 0x40", rd32(PRAM0, 0x40), 0x11111111u);
    ck("slow pram dword 0x41", rd32(PRAM0, 0x41), 0x22222222u);
    ck("slow pram dword 0x42", rd32(PRAM0, 0x42), 0x33333333u);
    ck("fast pram dword 0x10", rd32(PRAM1, 0x10), 0xAAAAAAAAu);
    ck("fast pram dword 0x11", rd32(PRAM1, 0x11), 0xBBBBBBBBu);
    // and it must not have written the OTHER memory at the same index
    ck("slow pram untouched at 0x10", rd32(PRAM0, 0x10), 0xFFFFFFFFu);
    ck("the walk still finished", d->dbg_walk_frames ? 1u : 0u, 1u);
  }

  // ---- R642: geo_window_data is READ, not stepped over. Six words; the
  // first three -- viewport start, end, centre 0 -- reach the outputs, the
  // walk stays in step (the matrix write after it still lands), and win_cnt
  // steps once.
  {
    std::vector<uint32_t> list(0x8000, 0);
    size_t n = 0;
    list[n++] = 0x03u << 23;
    const uint32_t ww[6] = {0xffff0080u, 0x01f00200u, 0x00f8010eu, 0x00f8013cu, 0x01600098u, 0x00f8013cu};
    for (int i = 0; i < 6; i++) list[n++] = ww[i];
    list[n++] = 0x0bu << 23;                       // matrix write, 12 words
    for (int i = 0; i < 12; i++) list[n++] = 0x3f800000u + i;
    list[n++] = 0x0fu << 23;                       // end
    d->rst_n = 0; for (int i = 0; i < 4; i++) tick(); d->rst_n = 1; idle(2);
    ck("power-up window: viewport start", d->win_vp_s, 0x00000080u);
    ck("power-up window: centre 0",       d->win_c0,   0x00f80140u);
    const unsigned c0 = d->win_cnt;
    d->frame_start = 1; tick(); d->frame_start = 0;
    for (int i = 0; i < 200000; i++) {
      d->rd_ack = 0;
      if (d->rd_req) { d->rd_data = (d->rd_addr < list.size()) ? list[d->rd_addr] : 0; d->rd_ack = 1; }
      tick();
      if (d->dbg_walk_frames) break;
    }
    std::printf("test: R642 window_data captured -- %u ops, win_cnt +%u\n", d->dbg_walk_ops, (unsigned)(uint8_t)(d->win_cnt - c0));
    ck("window: viewport start", d->win_vp_s, ww[0]);
    ck("window: viewport end",   d->win_vp_e, ww[1]);
    // R760: the centre is applied per OBJECT (its select, opcode bits 30:29);
    // a list with no object leaves win_c0 where it was.
    ck("window: centre held until an object", d->win_c0, 0x00f80140u);
    ck("window: counted once",   (uint8_t)(d->win_cnt - c0), 1);
    ck("walk in step: three opcodes", d->dbg_walk_ops, 3);
    ck("walk in step: matrix landed", d->dbg_mtx_n, 1);
    ck("no unknown opcode", d->dbg_walk_unknown, 0);
  }

  // ---- 8. R638: ONLY THE WALK'S OWN LIST IS HELD.
  //
  // Daytona double-buffers (dword 0x0000 / 0x4000, alternating every frame in
  // MAME) and pushes the next list into the other buffer while this one is
  // walked. R610 held all of it, so the CPU stalled until the walk ended. Here
  // a slow walk of list A runs while the pusher (a) writes list B, 300 dwords,
  // into the other buffer -- it must land during the walk, the pusher not held
  // to the walk's end; (b) rewrites words of A the walk has read -- they land
  // too; (c) writes `end` into A ahead of the walk -- held until the walk ends,
  // or the walk stops short. Then B, flipped during A, is walked in full.
  {
    d->rst_n = 0; for (int i = 0; i < 4; i++) tick(); d->rst_n = 1; idle(2);
    mem.clear();
    auto put = [&](uint32_t dw, uint32_t v){ uint32_t a = BASE + (dw << 1);
                                             mem[a] = v & 0xFFFF; mem[a + 1] = v >> 16; };
    auto get = [&](uint32_t dw) -> uint32_t { uint32_t a = BASE + (dw << 1);
                                              return uint32_t(rdm(a)) | (uint32_t(rdm(a + 1)) << 16); };
    const uint32_t A = 0x100, N = 64, B = 0x4100, NB = 299, END = 0x0fu << 23;
    for (uint32_t i = 0; i < N; i++) put(A + i, 0);          // nops
    put(A + N, END);
    rd_slow = 200;
    w(2, A * 4);                                            // flip: walk A
    for (int i = 0; i < 24 * 200; i++) tick();              // ~24 ops in
    // (a) list B into the other buffer, more than the queue holds
    w(1, B * 4);
    for (uint32_t i = 0; i < NB; i++) w(3, 0);
    w(3, END);
    for (int i = 0; i < 1500; i++) tick();                  // the queue drains
    bool b_ok = true;
    for (uint32_t i = 0; i < NB; i++) if (get(B + i) != 0) b_ok = false;
    if (get(B + NB) != END) b_ok = false;
    ck("other buffer landed during the walk", b_ok ? 1u : 0u, 1u);
    ck("walk A still running after list B", d->dbg_walk_frames, 0);
    w(2, B * 4);                                            // flip B, pending
    // (b) rewrite what the walk has read
    w(1, A * 4);
    for (int i = 0; i < 8; i++) w(3, END);
    for (int i = 0; i < 64; i++) tick();
    ck("words behind the walk landed", get(A + 7), END);
    // (c) `end` ahead of the walk, inside its list
    w(1, (A + N - 8) * 4);
    for (int i = 0; i < 4; i++) w(3, END);
    for (int i = 0; i < 64; i++) tick();
    ck("words ahead of the walk held", get(A + N - 8), 0);
    ck("walk A still running", d->dbg_walk_frames, 0);
    uint32_t ops_a = 0;
    for (int i = 0; i < 400000 && d->dbg_walk_frames < 1; i++) tick();
    ops_a = d->dbg_walk_ops;
    ck("words ahead landed once the walk ended", (tick(), tick(), get(A + N - 8)), END);
    for (int i = 0; i < 400000 && d->dbg_walk_frames < 2; i++) tick();
    std::printf("test: R638 walk A %u ops, walk B %u ops, overtakes %u\n",
                ops_a, d->dbg_walk_ops, d->dbg_overtake);
    ck("walk A read its whole list", ops_a, N + 1);
    ck("walk B read its whole list", d->dbg_walk_ops, NB + 1);
    ck("no word drained into a walk's window", d->dbg_overtake, 0);
    rd_slow = 0;
  }
  // ---- R699: FRAME SKIP. Six lists flipped, one a frame; skip 0 walks all
  // six, 1 walks every second, 2 every third -- in the flip trigger (mode 0)
  // and After flip (mode 2, what the board runs). A list of just `end`.
  for (int mode : {0, 2}) for (int sk = 0; sk <= 2; ++sk) {
    d->rst_n = 0; for (int i = 0; i < 4; i++) tick(); d->rst_n = 1; idle(2);
    d->trig_mode = mode; d->skip = sk; d->eng_busy = 0;
    unsigned walks = 0, last = d->dbg_walk_frames;
    for (int f = 0; f < 6; ++f) {
      w(2, 0x00000000);                                // the flip: the list is at 0
      d->frame_start = 1; tick(); d->frame_start = 0;
      for (int i = 0; i < 3000; i++) {
        d->rd_ack = 0;
        if (d->rd_req) { d->rd_data = 0x07800000u; d->rd_ack = 1; }   // op 0x0f, end
        tick();
      }
      if (d->dbg_walk_frames != last) { walks += (d->dbg_walk_frames - last) & 0xffff; last = d->dbg_walk_frames; }
    }
    char nm[64]; std::snprintf(nm, sizeof nm, "R699 mode %d skip %d: lists walked of 6", mode, sk);
    ck(nm, walks, sk == 0 ? 6 : sk == 1 ? 3 : 2);
  }
  // ---- R711: A SKIPPED LIST STILL RUNS ITS STATE. Each list sets the light
  // to a value of its own, then one object, then ends. Every list's light
  // must land -- skipped or not -- while objects reach the engine, and frame
  // ends reach the renderer, only from the lists that draw.
  for (int mode : {0, 2}) for (int sk = 0; sk <= 2; ++sk) {
    d->rst_n = 0; for (int i = 0; i < 4; i++) tick(); d->rst_n = 1; idle(2);
    d->trig_mode = mode; d->skip = sk; d->eng_busy = 0;
    unsigned lit_ok = 0, objs = 0, frames = 0, last = d->dbg_walk_frames;
    int busy_left = 0;
    for (int f = 0; f < 6; ++f) {
      const uint32_t lx = 0x3f800000u + uint32_t(f) * 0x100u;
      const uint32_t list[10] = { 0x05000000u, lx, 0x40000000u, 0x40400000u,      // light (op 0x0a)
                                  0x00800000u, 0, 0, 0x00800000u, 0,              // object_data (op 0x01)
                                  0x07800000u };                                   // end
      w(2, 0x00000000);
      d->frame_start = 1; tick(); d->frame_start = 0;
      for (int i = 0; i < 4000; i++) {
        d->rd_ack = 0;
        if (d->rd_req) { d->rd_data = list[d->rd_addr < 10 ? d->rd_addr : 9]; d->rd_ack = 1; }
        if (d->obj_valid) { ++objs; busy_left = 30; }
        d->eng_busy = busy_left > 0; if (busy_left > 0) --busy_left;
        tick();
      }
      if (d->lit_x == lx) ++lit_ok;
      if (d->dbg_walk_frames != last) { frames += (d->dbg_walk_frames - last) & 0xffff; last = d->dbg_walk_frames; }
    }
    const unsigned draws = sk == 0 ? 6 : sk == 1 ? 3 : 2;
    char nm[96];
    std::snprintf(nm, sizeof nm, "R711 mode %d skip %d: lights applied of 6", mode, sk);  ck(nm, lit_ok, 6);
    std::snprintf(nm, sizeof nm, "R711 mode %d skip %d: objects to the engine", mode, sk); ck(nm, objs, draws);
    std::snprintf(nm, sizeof nm, "R711 mode %d skip %d: frame ends", mode, sk);            ck(nm, frames, draws);
  }
  d->skip = 0; d->trig_mode = 0;


  // ---- R747: push_busy covers EVERY cycle a pushed word is not yet in memory.
  // It is what holds the CPU's count patch (R697); a cycle with a word still
  // queued and push_busy low is a cycle the patch can overtake the placeholder.
  // q_valid alone left two such cycles after each push and one between words.
  {
    idle(200);
    w(1, 0x00000300); idle(4);
    const uint32_t v[3] = {0x11112222u, 0x33334444u, 0x55556666u};
    for (int k = 0; k < 3; ++k) { mem.erase(BASE + 0x180 + 2*k); mem.erase(BASE + 0x181 + 2*k); }
    auto landed = [&]() {
      for (int k = 0; k < 3; ++k) {
        auto lo = mem.find(BASE + 0x180 + 2*k), hi = mem.find(BASE + 0x181 + 2*k);
        if (lo == mem.end() || hi == mem.end() || lo->second != (v[k] & 0xffff) || hi->second != (v[k] >> 16)) return false;
      }
      return true;
    };
    int holes = 0, seen_busy = 0;
    for (int k = 0; k < 3; ++k) {
      d->wr_ctl = d->wr_setwp = d->wr_setrp = 0; d->wr_push = 1; d->wdata = v[k]; d->eval();
      for (int g = 0; d->push_stall && g < 4096; ++g) tick();
      tick();                                   // taken on this edge
      d->wr_push = 0; d->eval();
      if (!landed() && !d->push_busy) ++holes;
      if (d->push_busy) ++seen_busy;
    }
    for (int c = 0; c < 400 && !landed(); ++c) {
      tick();
      if (!landed() && !d->push_busy) ++holes;
      if (d->push_busy) ++seen_busy;
    }
    ck("R747 the three pushed words landed", landed() ? 1u : 0u, 1u);
    ck("R747 push_busy never low with a word queued", uint32_t(holes), 0u);
    ++checks; if (!seen_busy) { std::printf("  FAIL R747 push_busy never rose\n"); ++fails; }
  }

  // ---- R752: A FLIP'S WALK WAITS FOR EVERY WORD PUSHED BEFORE THE FLIP.
  // The board: after a flip the game pushes its next list into the other
  // buffer at once, so the queue is never idle and the walk started on
  // drain_wait's 1,023-cycle timeout with its own list's tail still queued --
  // held in its window, the walk read the previous frame's words there. Here
  // list A (40 nops and an end) is pushed over an old list of ends through a
  // slow write port (~2,500 cycles to land), flipped, and list B is pushed
  // into the other buffer without pause. The walk must read all 41 opcodes,
  // and must start before B has finished landing (B does not hold it).
  {
    d->rst_n = 0; for (int i = 0; i < 4; i++) tick(); d->rst_n = 1; idle(2);
    d->trig_mode = 0; d->skip = 0; d->eng_busy = 0;
    mem.clear();
    auto put = [&](uint32_t dw, uint32_t v){ uint32_t a = BASE + (dw << 1);
                                             mem[a] = v & 0xFFFF; mem[a + 1] = v >> 16; };
    const uint32_t A = 0x200, N = 40, B = 0x4200, END = 0x0fu << 23;
    for (uint32_t i = 0; i <= N; i++) put(A + i, END);      // the old list: ends
    rd_slow = 1; wr_slow = 30;
    w(1, A * 4);
    for (uint32_t i = 0; i < N; i++) w(3, 0);               // nops
    w(3, END);
    w(2, A * 4);                                            // flip A, its tail queued
    w(1, B * 4);
    unsigned b_pushed = 0, b_at_walk = 0;
    const unsigned f0 = d->dbg_walk_frames;
    bool walked = false;
    for (int k = 0; k < 600 && !walked; ++k) {
      w(3, 0); ++b_pushed;                                  // the next list, no pause
      if (d->dbg_walk_frames != f0) { walked = true; b_at_walk = b_pushed; }
    }
    for (int i = 0; i < 200000 && d->dbg_walk_frames == f0; i++) tick();
    std::printf("test: R752 walk of A: %u ops; %u words of B pushed when it ended\n",
                d->dbg_walk_ops, b_at_walk);
    ck("R752 walk A ran", d->dbg_walk_frames != f0 ? 1u : 0u, 1u);
    ck("R752 walk A read its whole list", d->dbg_walk_ops, N + 1);
    ck("R752 B's words did not hold the walk", walked ? 1u : 0u, 1u);
    rd_slow = 0; wr_slow = 0;
  }

  // ---- R760: EACH OBJECT PROJECTS ABOUT THE CENTRE IT SELECTS. A window
  // with four different centres, then four objects selecting 0, 1, 2, 3 (opcode
  // bits 30:29) and then 1 again: win_c0 must carry the selected centre when
  // each object is announced. MAME: center_sel = (opcode >> 29) & 3.
  {
    std::vector<uint32_t> list(0x8000, 0);
    size_t n = 0;
    list[n++] = 0x03u << 23;
    const uint32_t ww[6] = {0xffff0080u, 0x01f00200u, 0x00f8010eu, 0x00f8013cu, 0x01600098u, 0x0123045cu};
    for (int i = 0; i < 6; i++) list[n++] = ww[i];
    const int sel[5] = {0, 1, 2, 3, 1};
    for (int k = 0; k < 5; k++) {
      list[n++] = (0x01u << 23) | (uint32_t(sel[k]) << 29);   // object_data
      for (int i = 0; i < 4; i++) list[n++] = 0;
    }
    list[n++] = 0x0fu << 23;                                   // end
    d->rst_n = 0; for (int i = 0; i < 4; i++) tick(); d->rst_n = 1; idle(2);
    d->trig_mode = 0; d->skip = 0; d->eng_busy = 0;
    w(2, 0x00000000);
    int seen = 0, busy_left = 0;
    for (int i = 0; i < 200000 && !d->dbg_walk_frames; i++) {
      d->rd_ack = 0;
      if (d->rd_req) { d->rd_data = (d->rd_addr < list.size()) ? list[d->rd_addr] : 0; d->rd_ack = 1; }
      if (d->obj_valid && seen < 5) {
        const uint32_t c = ww[2 + sel[seen]] & 0x0fff0fffu;
        char nm[64]; std::snprintf(nm, sizeof nm, "R760 object %d (centre %d)", seen, sel[seen]);
        ck(nm, d->win_c0, c);
        ++seen; busy_left = 30;
      }
      d->eng_busy = busy_left > 0; if (busy_left > 0) --busy_left;
      tick();
    }
    std::printf("test: R760 centre select -- %d objects announced\n", seen);
    ck("R760 five objects announced", uint32_t(seen), 5u);
    d->eng_busy = 0;
  }

  std::printf("m2_geo: checks=%d fails=%d\n", checks, fails);
  std::printf("%s\n", fails?"FAIL":"PASS");
  delete d; return fails?1:0;
}
