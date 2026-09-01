// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// The CPU bridge, against a model of what it is bridging to.
//
// This exists because the bridge is the one new block between two things that
// are already verified -- an i960 that matches MAME for 803,355 instructions
// and a renderer that matches it pixel for pixel -- and a fault here presents
// as neither of them working. On hardware that is a black screen and no
// information at all.
//
// WHAT IT CHECKS
//
//   * every region decodes to the right target and the right word address
//   * a 32-bit access becomes two 16-bit transactions, low half first
//   * the domain crossing fires ONCE per access, at 25 MHz into 40 MHz
//   * writes to ROM regions are dropped rather than performed
//   * unmapped accesses are counted, not silently answered
//
// The two clocks are driven at their real ratio -- 25 and 40 MHz -- rather than
// at a convenient integer one. A handshake that only works when the clocks
// divide evenly is a handshake that works in the testbench.

#include "Vm2_cpu_bridge.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <map>
#include <vector>

static Vm2_cpu_bridge *dut;

// The far side: SDRAM as a sparse map of 16-bit words, plus tile RAM, palette
// and the translation table as arrays.
static std::map<uint32_t, uint16_t> sdram;
static std::vector<uint16_t> tram(32768, 0), pal(4096, 0);
static std::vector<uint8_t>  xlat(96, 0);
static std::map<uint32_t, uint32_t> io_regs;
static uint32_t io_rdata_q = 0;   // the registered peripheral read, see tick()

static uint64_t fails = 0, checks = 0;

// 25 MHz and 40 MHz from a common 200 MHz tick: 8 and 5 ticks per period.
static const int CPU_DIV = 8, MEM_DIV = 5;
static uint64_t tk = 0;

static void step() {
  const bool cpu_edge = (tk % CPU_DIV) == 0;
  const bool mem_edge = (tk % MEM_DIV) == 0;

  if (mem_edge) {
    // SDRAM model: single-word port. ACK IS HELD FOR ACK_HOLD CYCLES, which is
    // 2 -- m2_sdram's own parameter, "requesters on a slower synchronous clock
    // must see exactly one rising edge with ack high".
    //
    // The first version of this model acked for ONE cycle, and that is why it
    // passed a bridge that samples an ack still held from the previous
    // transaction. A model that is easier than the thing it models does not
    // test the thing it models.
    static bool pend = false;
    static int  ackhold = 0;
    static uint32_t pa = 0; static bool pw = false; static uint16_t pd = 0; static uint8_t pb = 3;
    if (ackhold > 0) { --ackhold; dut->sd_ack = 1; }
    else dut->sd_ack = 0;
    if (pend && ackhold == 0) {
      if (pw) {
        uint16_t cur = sdram.count(pa) ? sdram[pa] : 0xffff;
        if (pb & 1) cur = uint16_t((cur & 0xff00) | (pd & 0x00ff));
        if (pb & 2) cur = uint16_t((cur & 0x00ff) | (pd & 0xff00));
        sdram[pa] = cur;
      } else {
        // A FOUR-WORD BURST, because that is what port 0 now does -- blen()
        // gives ports 0 to 3 four words. Returning one and zero-filling the
        // rest is what this model used to do, and it is how a model drifts
        // from the thing it models: the bridge reads p_dout[31:0] and would
        // have seen a permanently zero high half.
        uint64_t d = 0;
        for (int w = 0; w < 4; ++w) {
          const uint32_t a = pa + uint32_t(w);
          const uint64_t v = sdram.count(a) ? sdram[a] : 0xffffu;
          d |= v << (16 * w);
        }
        dut->sd_dout = d;
      }
      dut->sd_ack = 1;
      ackhold = 1;                 // this cycle plus one more = ACK_HOLD of 2
      pend = false;
    } else if (dut->sd_req && ackhold == 0) {
      pa = dut->sd_addr; pw = dut->sd_we; pd = dut->sd_din; pb = dut->sd_be;
      pend = true;
    }
    // On-chip arrays: REGISTERED reads, as M10K is.
    dut->oc_tram_q = tram[dut->oc_addr & 0x7fff];
    dut->oc_pal_q  = pal[dut->oc_addr & 0xfff];
    if (dut->oc_tram_we) tram[dut->oc_addr & 0x7fff] = dut->oc_din;
    if (dut->oc_pal_we)  pal[dut->oc_addr & 0xfff]   = dut->oc_din;
    if (dut->oc_xlat_we) xlat[dut->oc_xlat_addr % 96] = dut->oc_xlat_din;
    if (dut->io_sel) {
      if (dut->io_we) io_regs[dut->io_addr] = dut->io_wdata;
    }
    // A REGISTERED I/O READ, because that is what the peripherals are.
    //
    // This was combinational from io_addr, which is a peripheral that answers
    // in the same instant it is addressed. m2_ioboard and m2_backup hold their
    // state in M10K and present it one clk_mem later -- they have to, because
    // an asynchronously read 1024x16 array is not an MLAB on this part, it is
    // 16,384 flip-flops and 7,899 ALM.
    //
    // The bridge captures r_rdata <= io_rdata in the SAME cycle it raises
    // io_sel, so it samples one cycle before io_sel is visible. With a
    // combinational model that is invisible. With a registered one it is the
    // whole question, and it is the only link between the i960 and the I/O
    // board that nothing exercised.
    dut->io_rdata = io_rdata_q;
    io_rdata_q = io_regs.count(dut->io_addr) ? io_regs[dut->io_addr] : 0xa5a50000u;
  }

  if (cpu_edge) { dut->clk_cpu = 0; dut->eval(); }
  if (mem_edge) { dut->clk_mem = 0; dut->eval(); }
  ++tk;
  if ((tk % CPU_DIV) == 0) { dut->clk_cpu = 1; dut->eval(); }
  if ((tk % MEM_DIV) == 0) { dut->clk_mem = 1; dut->eval(); }
}

// One CPU access, driven the way i960_top drives it: raise req, hold until ack.
static bool access(bool we, uint32_t addr, uint32_t wdata, uint8_t be, uint32_t *out) {
  dut->bus_req = 1; dut->bus_we = we; dut->bus_addr = addr;
  dut->bus_wdata = wdata; dut->bus_be = be;
  for (int g = 0; g < 4000; ++g) {
    step();
    if (dut->bus_ack) {
      if (out) *out = dut->bus_rdata;
      dut->bus_req = 0;
      for (int k = 0; k < CPU_DIV * 3; ++k) step();
      return true;
    }
  }
  dut->bus_req = 0;
  return false;
}

static void expect(const char *what, uint32_t got, uint32_t want) {
  ++checks;
  if (got != want) {
    if (fails < 20) std::printf("  MISMATCH %-34s got=%08x want=%08x\n", what, got, want);
    ++fails;
  }
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vm2_cpu_bridge;

  dut->rst_n_cpu = 0; dut->rst_n_mem = 0;
  dut->bus_req = 0; dut->sd_ack = 0; dut->io_rdata = 0;
  dut->base_prog = 0x00000; dut->base_data = 0x40000;
  dut->base_work = 0x20000; dut->base_board = 0x30000; dut->base_char = 0x38000; dut->base_buffer = 0x40000;
  for (int i = 0; i < 200; ++i) step();
  dut->rst_n_cpu = 1; dut->rst_n_mem = 1;
  // LONG ENOUGH FOR THE CACHE'S RESET SWEEP, WHICH IS NOT A FIXED NUMBER.
  //
  // The bridge clears every valid bit after reset one line per cycle, and
  // refuses transactions until it has finished -- S_IDLE gates on
  // !dc_sweeping. This wait was 200 cycles, which covered a 256-line cache and
  // silently encoded that size: growing the cache to 2048 lines made the first
  // write land during the sweep and the test reported work RAM reading zero,
  // which looks like a bridge fault and is a testbench assumption.
  //
  // 8192 covers the largest cache anyone is likely to try next, and the cost of
  // being generous here is nothing.
  for (int i = 0; i < 8192; ++i) step();

  std::printf("m2_cpu_bridge\n");

  // ---- work RAM: write then read back, and check it landed as two words ----
  {
    uint32_t v = 0;
    access(true,  0x00500010u, 0xdeadbeefu, 0xf, nullptr);
    // Offset WITHIN the region, not the absolute address >> 1 -- the bridge
    // masks to the region size, which is what makes the same SDRAM base
    // usable for a 1 MB window.
    expect("work RAM low word",  sdram[0x20000 + ((0x00500010u & 0xfffffu) >> 1)],     0xbeef);
    expect("work RAM high word", sdram[0x20000 + ((0x00500010u & 0xfffffu) >> 1) + 1], 0xdead);
    access(false, 0x00500010u, 0, 0xf, &v);
    expect("work RAM readback", v, 0xdeadbeefu);
  }

  // ---- the shared buffer RAM at 0x00900000, 128 KB, mirrored to 0x0097ffff ----
  //
  // Mapping this region made the machine WORSE on hardware: the i960's clear
  // loop at 0x0E00 walked into 0x0163Fxxx, which the reference never touches.
  // Before blaming the game, prove the mapping itself: a dword must land in two
  // SDRAM words at base + (offset >> 1), read back whole, and the mirror must
  // alias rather than address new storage.
  {
    uint32_t v = 0;
    access(true,  0x00900010u, 0xcafef00du, 0xf, nullptr);
    expect("buffer low word",  sdram[0x40000 + ((0x00900010u & 0x1ffffu) >> 1)],     0xf00d);
    expect("buffer high word", sdram[0x40000 + ((0x00900010u & 0x1ffffu) >> 1) + 1], 0xcafe);
    access(false, 0x00900010u, 0, 0xf, &v);
    expect("buffer readback", v, 0xcafef00du);

    // the mirror: 0x920000 is the same 128 KB seen again
    access(false, 0x00920010u, 0, 0xf, &v);
    expect("buffer mirror reads the same", v, 0xcafef00du);
    access(true,  0x00940010u, 0x12345678u, 0xf, nullptr);
    access(false, 0x00900010u, 0, 0xf, &v);
    expect("mirror write aliases", v, 0x12345678u);

    // the top of the region must not run past 128 KB into whatever is next
    access(true,  0x0091fffcu, 0xa5a55a5au, 0xf, nullptr);
    expect("last dword low",  sdram[0x40000 + (0x1fffcu >> 1)],     0x5a5a);
    expect("last dword high", sdram[0x40000 + (0x1fffcu >> 1) + 1], 0xa5a5);
  }

  // ---- program ROM is READ ONLY: the write must not land ----
  {
    const uint32_t wa = 0x00000000u + ((0x00001000u & 0x1fffffu) >> 1);
    sdram[wa] = 0x1234; sdram[wa + 1] = 0x5678;
    uint32_t v = 0;
    access(true,  0x00001000u, 0xffffffffu, 0xf, nullptr);
    expect("ROM write dropped (low)",  sdram[wa],     0x1234);
    expect("ROM write dropped (high)", sdram[wa + 1], 0x5678);
    access(false, 0x00001000u, 0, 0xf, &v);
    expect("ROM readback", v, 0x56781234u);
  }

  // ---- model2o ROM MIRROR at 0x00220000 reads the program ROM's second half --
  {
    const uint32_t wa = 0x00000000u + 0x10000 + ((0x00227cf0u & 0x1ffffu) >> 1);
    sdram[wa] = 0xcafe; sdram[wa + 1] = 0xf00d;
    uint32_t v = 0;
    access(false, 0x00227cf0u, 0, 0xf, &v);
    expect("model2o ROM mirror", v, 0xf00dcafeu);
  }

  // ---- board RAM is WRITABLE and does not alias the mirror ----
  {
    uint32_t v = 0;
    access(true,  0x00200004u, 0x11112222u, 0xf, nullptr);
    access(false, 0x00200004u, 0, 0xf, &v);
    expect("board RAM readback", v, 0x11112222u);
    expect("board RAM did not touch the mirror",
           sdram.count(0x00000000u + 0x10000 + 2) ? 1u : 0u, 0u);
  }

  // ---- tile RAM and palette, on chip ----
  {
    uint32_t v = 0;
    access(true,  0x01000008u, 0x00110022u, 0xf, nullptr);
    expect("tile RAM word 4", tram[4], 0x0022);
    expect("tile RAM word 5", tram[5], 0x0011);
    access(false, 0x01000008u, 0, 0xf, &v);
    expect("tile RAM readback", v, 0x00110022u);

    access(true,  0x01800008u, 0x00330044u, 0xf, nullptr);
    expect("palette word 4", pal[4], 0x0044);
    access(false, 0x01800008u, 0, 0xf, &v);
    expect("palette readback", v, 0x00330044u);
  }

  // ---- char RAM lands in SDRAM at its own base ----
  {
    access(true, 0x01080020u, 0x99887766u, 0xf, nullptr);
    expect("char RAM low word", sdram[0x38000 + ((0x01080020u & 0x7ffffu) >> 1)], 0x7766);
  }

  // ---- main_data, and its alias at 0x06000000 ----
  {
    sdram[0x40000 + ((0x02000100u & 0x1ffffffu) >> 1)] = 0x0f0f;
    uint32_t v = 0;
    access(false, 0x02000100u, 0, 0xf, &v);
    expect("main_data low half", v & 0xffffu, 0x0f0fu);
    sdram[0x40000 + 0x800000 + ((0x06000040u & 0xffffffu) >> 1)] = 0x7070;
    access(false, 0x06000040u, 0, 0xf, &v);
    expect("main_data alias low half", v & 0xffffu, 0x7070u);
  }

  // ---- unaligned halfword access, which is what char RAM is built from ----
  //
  // The boot's character copy is a halfword loop: `ldos (g7),g4` / `stos
  // g4,(g6)` with both pointers advancing by 2, so every OTHER access has
  // r_addr[1] set. On that one the enabled bytes are the dword's HIGH half,
  // and SDRAM word r_addr[..:1] holds them -- not the low half.
  //
  // Nothing in this suite read or wrote a halfword before: every case was
  // full-width, so the entire unaligned path was untested. 52,375 of 140,864
  // source loads in the boot returned the wrong halfword and every one of them
  // had be=c.
  {
    uint32_t v = 0;
    // WORK RAM, not the program ROM. The first version of this case used
    // 0x00000200, which decodes to T_SDRAM with is_rom set -- writes there are
    // discarded on purpose, so two of the four checks failed for a reason that
    // had nothing to do with alignment.
    const uint32_t WR = 0x00500200u;                 // work RAM
    const uint32_t W  = 0x20000u + ((WR & 0xfffffu) >> 1);
    sdram[W]     = 0xaaaa;      // bytes 0,1 of the dword
    sdram[W + 1] = 0x5555;      // bytes 2,3
    access(false, WR,      0, 0x3, &v);
    expect("halfword read, aligned",   v & 0xffffu,         0xaaaau);
    access(false, WR + 2u, 0, 0xc, &v);
    expect("halfword read, unaligned", (v >> 16) & 0xffffu, 0x5555u);

    access(true, WR + 4u, 0x00001234u, 0x3, nullptr);
    expect("halfword write, aligned",   sdram[W + 2], 0x1234u);
    access(true, WR + 6u, 0x99990000u, 0xc, nullptr);
    expect("halfword write, unaligned", sdram[W + 3], 0x9999u);
  }

  // ---- the translation table ----
  //
  // ADDRESSES FROM model2.cpp, NOT FROM THE BRIDGE. This case used to write
  // 0x01810004 and expect entry 2, which is what `r_addr[7:1]` did -- the test
  // was written from the implementation rather than from the reference, so it
  // agreed with the bridge and with nothing real. docs/differential-testing.md
  // names exactly this trap.
  //
  //   r = m_colorxlat[(0x0080 >> 1) + (((palcolor >> 0) & 0x1f) << 8)];
  //   g = m_colorxlat[(0x4080 >> 1) + ...];
  //   b = m_colorxlat[(0x8080 >> 1) + ...];
  //
  // so entry v of a channel is at BYTE offset base + v*512, base 0x0080 for
  // red, 0x4080 for green, 0x8080 for blue. Only those 96 of the region's
  // 24,576 words are ever read.
  {
    const uint32_t XL = 0x01810000u;
    access(true, XL + 0x0080u + 2u * 512u,  0x000000c3u, 0xf, nullptr);
    expect("xlat R entry 2",  xlat[2],  0xc3);
    access(true, XL + 0x4080u + 5u * 512u,  0x0000005au, 0xf, nullptr);
    expect("xlat G entry 5",  xlat[37], 0x5a);
    access(true, XL + 0x8080u + 31u * 512u, 0x000000ffu, 0xf, nullptr);
    expect("xlat B entry 31", xlat[95], 0xff);

    // AND THE OTHER 24,480 WRITES MUST GO NOWHERE. The game writes the whole
    // region; keeping 96 bytes only works if everything else is discarded
    // rather than folded onto an entry that happens to share low address bits.
    const uint8_t before = xlat[2];
    access(true, XL + 0x0080u + 2u * 512u + 4u, 0x00000011u, 0xf, nullptr);
    expect("xlat ignores a non-entry write", xlat[2], before);
  }

  // ---- I/O reaches the register file and comes back ----
  {
    uint32_t v = 0;
    io_regs[0x00980004u] = 1;
    access(false, 0x00980004u, 0, 0xf, &v);
    expect("fifo_control read", v, 1u);
    access(true, 0x00e80004u, 0x00000001u, 0xf, nullptr);
    expect("irq_enable write", io_regs[0x00e80004u], 1u);

    // THE ACCESS THE BOOT IS STUCK ON, exactly as it makes it.
    //
    //   0022824C: ldob 0x1c00042,g4   ; byte 2 of the I/O board's flag dword
    //   00228258: cmpibne g4,g1,...   ; loop until it reads 0x40
    //
    // A BYTE read, byte lane 2, of a dword whose other live byte is at lane 0.
    // On hardware the board returns 00400000 -- confirmed on the overlay -- and
    // the boot loops anyway, so the question is whether the word survives the
    // bridge intact and with the right lanes. Nothing here read a single byte
    // from I/O before: every I/O access in this suite was full-width.
    io_regs[0x01c00040u] = 0x00400000u;
    io_regs[0x01c00042u] = 0x00400000u;
    access(false, 0x01c00040u, 0, 0x1, &v);
    expect("I/O byte read, lane 0", v, 0x00400000u);
    access(false, 0x01c00042u, 0, 0x4, &v);
    expect("I/O byte read, lane 2", v, 0x00400000u);
  }

  // ---- an unmapped access is counted, not silently answered ----
  {
    const uint32_t before = dut->dbg_unmapped;
    uint32_t v = 0;
    access(false, 0x0f000000u, 0, 0xf, &v);
    expect("unmapped counted", dut->dbg_unmapped, before + 1);
  }

  // ---- THE CROSSING FIRES ONCE. Hammer it and check the counters agree with
  // the number of accesses actually issued -- a handshake that double-fires
  // shows up here and nowhere else until it deadlocks on hardware.
  {
    const uint32_t r0 = dut->dbg_cpu_reads, w0 = dut->dbg_cpu_writes;
    uint32_t v = 0;
    for (int i = 0; i < 64; ++i) {
      access(true,  0x00500100u + uint32_t(i * 4), 0x1000u + uint32_t(i), 0xf, nullptr);
      access(false, 0x00500100u + uint32_t(i * 4), 0, 0xf, &v);
      expect("hammer readback", v, 0x1000u + uint32_t(i));
    }
    expect("write count exact", dut->dbg_cpu_writes - w0, 64);
    expect("read  count exact", dut->dbg_cpu_reads  - r0, 64);
  }

  std::printf("  [before boot walk] reads=%u last_addr=%08x last_dout=%08x\n",
              dut->dbg_cpu_reads, dut->dbg_last_addr, dut->dbg_last_dout);

  // ---- THE i960's BOOT WALK: req HELD, address changed ON THE ACK ----
  //
  // access() above drops bus_req after every ack, and that is not what the CPU
  // does. Its boot master holds the request high for three reads and moves the
  // address when the acknowledge arrives. Holding is the harder case and it is
  // the one that shipped: the bridge sampled the address in the cycle it was
  // answering, before the CPU had updated it, and every read came out one
  // behind.
  {
    sdram[0x00000000u + 0] = 0x0000; sdram[0x00000000u + 1] = 0x0000;
    sdram[0x00000000u + 2] = 0x00c0; sdram[0x00000000u + 3] = 0x0000;
    sdram[0x00000000u + 6] = 0x0860; sdram[0x00000000u + 7] = 0x0000;
    const uint32_t seq[3]  = { 0, 4, 12 };
    const uint32_t want[3] = { 0x00000000u, 0x000000c0u, 0x00000860u };
    int idx = 0;
    // RISING EDGE. bus_ack is asserted for a whole CPU clock, which is eight of
    // these ticks, and checking it per tick counts one acknowledge as eight.
    // access() above hides this by breaking out on the first one; the boot walk
    // does not, and it reported three reads completing on three consecutive
    // ticks -- one real acknowledge, counted three times, which looked exactly
    // like the bridge answering without going to memory.
    bool ack_prev = false;
    dut->bus_req = 1; dut->bus_we = 0; dut->bus_be = 0xf;
    dut->bus_addr = seq[0];
    for (int g = 0; g < 200000 && idx < 3; ++g) {
      step();
      const bool ack_now = dut->bus_ack;
      const bool ack_rise = ack_now && !ack_prev;
      ack_prev = ack_now;
      if (ack_rise) {
        std::printf("    boot read %d: asked %2u fetched %u got %08x accesses=%u  "
                    "mstate=%02x (sd_ack=%d ack_mem=%d req_mem=%d st=%d)\n",
                    idx, seq[idx], dut->dbg_last_addr, dut->bus_rdata, dut->dbg_cpu_reads,
                    dut->dbg_mstate, (dut->dbg_mstate>>5)&1, (dut->dbg_mstate>>4)&1,
                    (dut->dbg_mstate>>3)&1, dut->dbg_mstate&7);
        std::printf("              at tick %llu\n", (unsigned long long)tk);
        expect(idx == 0 ? "boot walk mem[0]" : idx == 1 ? "boot walk mem[4]"
                                             : "boot walk mem[12]",
               dut->bus_rdata, want[idx]);
        ++idx;
        // The address moves ON the ack, exactly as i960_top's T_BOOT does, and
        // the request is NOT dropped.
        if (idx < 3) dut->bus_addr = seq[idx];
      }
    }
    if (idx < 3) { std::printf("  boot walk did not complete (%d of 3)\n", idx); ++fails; }
    dut->bus_req = 0;
    for (int k = 0; k < CPU_DIV * 4; ++k) step();
  }

  std::printf("  probe6=%08x probe2=%08x (EEEEEEEE = never read)\n",
              dut->dbg_probe6, dut->dbg_probe2);
  std::printf("  %llu checks, %llu mismatches, %llu unmapped seen\n",
              (unsigned long long)checks, (unsigned long long)fails,
              (unsigned long long)dut->dbg_unmapped);
  std::printf("%s\n", fails ? "FAIL" : "PASS");
  return fails ? 1 : 0;
}
