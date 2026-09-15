// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// m2_raster3d WITH THE DDR3 FRAMEBUFFER ON (FB_DDR3 = 1).
//
// tb_m2_raster3d drives the same module with FB_DDR3 = 0, so it proves nothing
// about the path the board will actually run -- R356 is the worked example of
// what that costs: a double driver on tx_span_ready that lint could not see,
// because the generate that would have created it built nothing. Everything in
// the FB_DDR3 branch wants a bench of its own, and this is it.
//
// THE TWO FACTS THE FRAMEBUFFER CHANGES.
//
//  1. THE DISPLAY HOLDS A COMPLETE FRAME. Nothing is shown until a whole list
//     has been drawn, and a frame that runs long holds the last complete one
//     rather than showing half of itself. The band path could not do either: it
//     handed the beam whatever was ready.
//
//  2. A HELD LIST IS DRAWN ONCE. Daytona delivers a list every second video
//     frame, and the band path redrew it every frame because the beam needed
//     the bands again -- 1.98 renders per list, measured on the board. With
//     somewhere to keep the result that work disappears, and dbg_pixels is flat
//     across a frame with no new list. THAT IS THE SAVING, and a bench that did
//     not check it would let a regression put it back silently.
#include "Vm2_raster3d.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <map>

static int checks = 0, fails = 0;
#define CHECK(c, ...) do { ++checks; if (!(c)) { ++fails; std::printf("  FAIL: " __VA_ARGS__); std::printf("\n"); } } while (0)

static const int SCR_W = 496, SCR_H = 384, V_TOTAL = 424;
// CORE CLOCKS PER SCANLINE, AND IT HAS TO BE NEAR THE BOARD'S. The board runs
// the fill at 100 MHz against a 60 Hz frame: 1.67 M cycles a frame, ~3,900 a
// line. The clear pass alone is 384 x 248 = 95,232 write beats, so at the 400
// tb_m2_raster3d uses it would eat more than half the frame and the test would
// be measuring the bench. 1,600 keeps the clear at 14% against the board's 6%.
static int TPL = 1600;

// ---------------------------------------------------------------- DDR3 model
// One outstanding command, burst of m_blen beats, ~200 ns to the first (R347).
// Reads return what was written; UNWRITTEN MEMORY IS NOT ZERO -- it comes back
// as 0xFFFF... as the integration doc requires, and here that matters twice
// over, because bit 24 of garbage is the painted flag and the mixer would show
// it. The first-frame gate is exactly what stops that.
static std::map<uint32_t, uint64_t> mem;   // ONE memory, two ports onto it
static const int LAT = 20;
struct Port { int cd = 0, left = 0, is_wr = 0; uint32_t addr = 0, addr0 = 0; unsigned blen0 = 0; };
static Port p1, p2;
static long wbeats = 0, rbeats = 0, cyc = 0;
static long proto_err = 0;
static int dbg_cmds = 0;

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (const char *e = std::getenv("M2_R3D_TPL")) TPL = std::atoi(e);
  dbg_cmds = std::getenv("M2_FB_CMDS") != nullptr;
  std::printf("  %d core clocks per scanline, DDR3 latency %d cycles\n", TPL, LAT);
  auto d = new Vm2_raster3d;
  d->clk = 0; d->clk_mem = 0; d->scan_clk = 0; d->rst_n = 0;
  d->frame_start = 0; d->q_valid = 0; d->q_end = 0;
  d->scan_x = 0; d->scan_y = 0;
  d->tex_m_ack = 0; d->tex_m_data = 0; d->tex_inval = 0;
  d->tex_base0 = 0x1760000; d->tex_base1 = 0x17E0000;
  d->fb_wnext = 0; d->fb_rvalid = 0; d->fb_ack = 0; d->fb_dout = 0;
  d->fb2_wnext = 0; d->fb2_rvalid = 0; d->fb2_ack = 0; d->fb2_dout = 0;

  int tex_wait = -1;
  auto tick = [&]() {
    cyc++;
    if (d->tex_m_req && tex_wait < 0) tex_wait = 8;
    if (tex_wait == 0) {
      d->tex_m_ack = 1;
      d->tex_m_data = 0x0123456789abcdefULL ^ (uint64_t)d->tex_m_addr;
    }
    // ---- DDR3: TWO INDEPENDENT PORTS (R376).
    //
    // The writer owns port 1 and the reader owns port 2; sysmem gives the board
    // three and ram2 was idle. There is no arbiter and nothing shared, so the
    // model is two copies of the same small state machine rather than one with
    // ownership -- which is the point: the whole class of "who does this
    // acknowledge belong to" cannot arise.
    //
    // Both keep the timing m2_ddr3 actually has: NOT served in the command
    // cycle, because D_IDLE spends a cycle latching before D_ISSUE. A model a
    // cycle quicker invented a deadlock once (R362) and one that could not be
    // slow enough hid a watchdog fault (R372).
    for (int port = 0; port < 2; port++) {
      Port &P = port ? p2 : p1;
      // request side
      unsigned  req   = port ? d->fb2_req   : d->fb_req;
      unsigned  we    = port ? d->fb2_we    : d->fb_we;
      uint32_t  addr  = port ? d->fb2_addr  : d->fb_addr;
      unsigned  blen  = port ? d->fb2_blen  : d->fb_blen;
      uint64_t  din   = port ? d->fb2_din   : d->fb_din;
      unsigned  be    = port ? d->fb2_be    : d->fb_be;
      // response side, cleared every cycle
      unsigned wnext = 0, rvalid = 0, ack = 0; uint64_t dout = 0;

      if (P.left == 0 && req) {
        if (dbg_cmds) std::printf("      p%d cmd %s addr %u blen %u be %02x @%ld\n",
                                  port + 1, we ? "WR" : "RD", (unsigned)addr,
                                  blen, be, cyc);
        P.addr = addr; P.left = blen ? blen : 256; P.is_wr = we;
        P.addr0 = addr; P.blen0 = blen;
        P.cd = we ? 1 : LAT;
      } else if (P.left > 0) {
        // Avalon holds the master to a constant address and burstcount for every
        // beat (R362). Checked on every beat, on both ports.
        if (addr != P.addr0 || blen != P.blen0) {
          if (!proto_err) std::printf("  FAIL: port %d ADDR/BURSTCNT MOVED mid-burst "
                                      "(addr %u -> %u, blen %u -> %u)\n",
                                      port + 1, P.addr0, (unsigned)addr, P.blen0, blen);
          proto_err++;
        }
        if (P.is_wr) {
          if (P.cd > 0) P.cd--;
          else {
            uint64_t old = mem.count(P.addr) ? mem[P.addr] : ~0ull;
            uint64_t m = 0;
            for (int b = 0; b < 8; b++) if (be & (1 << b)) m |= 0xffull << (b * 8);
            mem[P.addr] = (din & m) | (old & ~m);
            wnext = 1; P.addr++; P.left--; wbeats++;
            if (P.left == 0) ack = 1;
          }
        } else if (P.cd > 0) P.cd--;
        else {
          dout = mem.count(P.addr) ? mem[P.addr] : ~0ull;
          rvalid = 1; P.addr++; P.left--; rbeats++;
          if (P.left == 0) ack = 1;
        }
      }

      if (port) { d->fb2_wnext = wnext; d->fb2_rvalid = rvalid; d->fb2_ack = ack;
                  if (rvalid) d->fb2_dout = dout; }
      else      { d->fb_wnext  = wnext; d->fb_rvalid  = rvalid; d->fb_ack  = ack;
                  if (rvalid) d->fb_dout  = dout; }
    }
    d->eval();
    d->clk_mem = 1; d->eval(); d->clk_mem = 0; d->eval();
    d->clk = 1; d->scan_clk = 1; d->eval(); d->clk = 0; d->scan_clk = 0; d->eval();
    d->clk_mem = 1; d->eval(); d->clk_mem = 0; d->eval();
    if (d->tex_m_ack) { d->tex_m_ack = 0; tex_wait = -1; }
    else if (tex_wait > 0) --tex_wait;
  };
  for (int i = 0; i < 4; i++) tick();
  d->rst_n = 1; tick();

  // A column of quads down the screen at x0..x0+40. THE TWO LISTS GO IN
  // DIFFERENT PLACES, because that is the only way a bench can see whether the
  // two buffers are actually two: if they are one, drawing list B lands in the
  // picture the beam is showing and B's column appears while A's disappears.
  auto push_list = [&](int x0) {
    d->frame_start = 0;
    for (int b = 0; b < SCR_H / 16; b++) {
      { int g = 0; d->q_valid = 0; d->eval(); while (!d->q_ready && g++ < 100000) tick(); }
      d->q_valid = 1;
      d->q_x0 = x0;      d->q_y0 = b * 16 + 2;
      d->q_x1 = x0 + 40; d->q_y1 = b * 16 + 2;
      d->q_x2 = x0 + 40; d->q_y2 = b * 16 + 12;
      d->q_x3 = x0;      d->q_y3 = b * 16 + 12;
      d->q_col = 0xFFFFFF; d->q_z = 0x3F800000; d->q_moire = 0; d->q_tex = 0;
      d->q_end = (b == SCR_H / 16 - 1);
      tick();
    }
    d->q_valid = 0; d->q_end = 0;
  };

  // A video frame. Returns what the beam SAW (scan_hit) and what the fill DREW
  // (dbg_pixels) -- with a framebuffer those are different numbers, which is
  // the whole point.
  long inA = 0, inB = 0;
  auto video_frame = [&](long *seen, long *drawn) {
    inA = 0; inB = 0;
    unsigned px0 = d->dbg_pixels;
    d->frame_start = 1; tick(); d->frame_start = 0;
    long hits = 0;
    static long perline[SCR_H];
    for (int i = 0; i < SCR_H; i++) perline[i] = 0;
    for (int y = SCR_H; y < V_TOTAL; y++)
      for (int t = 0; t < TPL; t++) { d->scan_y = y; d->scan_x = 0; tick(); }
    for (int y = 0; y < SCR_H; y++)
      for (int t = 0; t < TPL; t++) {
        d->scan_y = y; d->scan_x = (t < SCR_W) ? t : SCR_W - 1;
        tick();
        if (t < SCR_W && d->scan_hit) {
          ++hits; ++perline[y];
          if (t >= 100 && t <= 141) ++inA;
          if (t >= 300 && t <= 341) ++inB;
        }
      }
    if (seen)  *seen  = hits;
    if (drawn) *drawn = (long)(unsigned)(d->dbg_pixels - px0);
    if (std::getenv("M2_FB_LINES")) {
      std::printf("      per line:");
      for (int y = 0; y < SCR_H; y += 1) if (perline[y]) std::printf(" %d:%ld", y, perline[y]);
      std::printf("\n");
    }
    std::printf("    frame: seen %ld (A %ld B %ld)  drawn %ld  pub %d drop %d  bands %d quads %d  lines %u late %u\n",
                hits, inA, inB, (long)(unsigned)(d->dbg_pixels - px0),
                (int)d->dbg_fb_pub, (int)d->dbg_fb_drop, (int)d->dbg_bands, (int)d->dbg_quads,
                (unsigned)d->dbg_fb_lines, (unsigned)d->dbg_fb_late);
  };

  // ---- 1. NOTHING IS SHOWN BEFORE A FRAME HAS BEEN DRAWN.
  //         DDR3 holds 0xFFFF..., whose bit 24 is the painted flag, so without
  //         the gate this frame scatters white over the whole tilemap.
  std::printf("test: an empty frame before any list shows nothing\n");
  { long seen = 0, drawn = 0; video_frame(&seen, &drawn);
    CHECK(seen == 0, "%ld pixels shown before any frame was drawn -- uninitialised DDR3 is on screen", seen); }

  // ---- 2. FOUR VIDEO FRAMES OF ONE LIST COST EXACTLY ONE RENDER.
  //
  //         Stated as a sum rather than per frame on purpose: which frame the
  //         draw lands on depends on when the sort finishes, and a test that
  //         pins that is testing the bench. What must not move is the TOTAL --
  //         one list, one render, however the frames fall.
  std::printf("test: four frames of one list cost one render\n");
  push_list(100);
  long seen[8] = {0}, drawn[8] = {0}, drewA = 0, drewB = 0;
  for (int f = 0; f < 4; f++) { video_frame(&seen[f], &drawn[f]); drewA += drawn[f]; }
  const long ONE = drawn[0] + drawn[1] + drawn[2] + drawn[3];
  int renders = 0; for (int f = 0; f < 4; f++) if (drawn[f]) renders++;
  CHECK(renders == 1, "list A was rendered %d times in four frames, not once", renders);
  CHECK(drewA > 0, "list A was never drawn");
  CHECK(seen[3] > 0, "nothing on screen four frames after the list arrived");
  CHECK(seen[3] == ONE, "the beam saw %ld pixels, the fill painted %ld -- "
        "the scanout is not showing what was drawn", seen[3], ONE);

  // ---- 3. AND THE NEXT LIST REPLACES IT, ONCE.
  std::printf("test: the next list replaces it, also once\n");
  const int pub0 = d->dbg_fb_pub;
  push_list(300);
  long drawFrameA = 0, drawFrameB = 0, lastA = 0, lastB = 0;
  for (int f = 4; f < 8; f++) {
    video_frame(&seen[f], &drawn[f]); drewB += drawn[f];
    // THE FRAME IN WHICH B IS BEING DRAWN. The beam must still be showing A,
    // and B must be nowhere -- it is going into the other buffer. If the two
    // buffers are one, B's column appears here while A's is cleared away, and
    // that is the whole failure this checks for: the fb_sel offset multiplied
    // past the top of a 25-bit address and both buffers were the same memory.
    if (drawn[f]) { drawFrameA = inA; drawFrameB = inB; }
    lastA = inA; lastB = inB;
  }
  CHECK(drawFrameA > 0 && drawFrameB == 0,
        "while list B was drawing the beam saw A %ld B %ld -- the draw landed in "
        "the buffer being displayed, so the double buffer is not double",
        drawFrameA, drawFrameB);
  CHECK(lastB > 0 && lastA == 0,
        "after list B was published the beam saw A %ld B %ld", lastA, lastB);
  int rendersB = 0; for (int f = 4; f < 8; f++) if (drawn[f]) rendersB++;
  CHECK(rendersB == 1, "list B was rendered %d times in four frames, not once", rendersB);
  CHECK(seen[7] > 0, "list B was never shown");
  CHECK(d->dbg_fb_pub > pub0, "no frame was published: pub stuck at %d", pub0);
  CHECK(d->dbg_fb_drop == 0, "%d lists were dropped -- the fill is not keeping up",
        (int)d->dbg_fb_drop);
  CHECK(d->dbg_fb_late == 0, "%u lines were asked for before the last had landed",
        (unsigned)d->dbg_fb_late);
  CHECK(d->dbg_dropped == 0, "quads dropped: %d", (int)d->dbg_dropped);
  CHECK(proto_err == 0, "the address moved under the bridge %ld times mid-burst", proto_err);

  std::printf("  seen per frame:  %ld %ld %ld %ld | %ld %ld %ld %ld\n",
              seen[0], seen[1], seen[2], seen[3], seen[4], seen[5], seen[6], seen[7]);
  std::printf("  drawn per frame: %ld %ld %ld %ld | %ld %ld %ld %ld\n",
              drawn[0], drawn[1], drawn[2], drawn[3], drawn[4], drawn[5], drawn[6], drawn[7]);
  std::printf("  one list rendered once: %ld pixels for A, %ld for B, over four frames each\n", drewA, drewB);
  std::printf("  DDR3: %ld write beats, %ld read beats\n", wbeats, rbeats);
  std::printf("m2_raster3d (FB_DDR3): checks=%d fails=%d\n", checks, fails);
  std::printf(fails ? "FAIL\n" : "PASS\n");
  delete d;
  return fails ? 1 : 0;
}
