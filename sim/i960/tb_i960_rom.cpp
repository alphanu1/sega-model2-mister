// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// Run the REAL Daytona program ROM through i960_top.
//
// P1's third exit criterion. Everything before this verified the CPU against a
// reference that this project wrote: the lockstep harness proves the module
// agrees with a transcription of MAME, on instruction mixes this project chose.
// It cannot prove the mix resembles Daytona's, that the boot record is where the
// part expects it, or that the memory map is right -- and a core that passes
// every unit test and executes four instructions of real code before wandering
// into unmapped space is a real outcome, not a hypothetical.
//
// NO ROM BYTES ENTER THE REPOSITORY. The set is read from $M2_ROMPATH (default
// ~/roms/Model2) at run time, the same arrangement tools/m2b-mame.sh uses, and
// the harness skips with a message rather than failing when it is absent -- a
// missing ROM is not a broken build.
//
// THE ROM INTERLEAVE IS NOT A DETAIL. MAME:
//
//   ROM_LOAD32_WORD("epr-16530a.12", 0x000000, 0x020000, ...)
//   ROM_LOAD32_WORD("epr-16531a.13", 0x000002, 0x020000, ...)
//
// ROM_LOAD32_WORD places 16-bit words at 32-bit stride, so .12 supplies the low
// half of every dword and .13 the high half. Concatenating the two files, or
// interleaving them by byte, both produce a plausible-looking image that
// disassembles to nonsense -- and the first instruction fetched is the boot
// record, which will look wrong in a way that says nothing about why.

#include "Vi960_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <map>
#include <algorithm>
#include <utility>

static Vi960_top *dut;
static uint64_t ticks = 0;

// ---------------------------------------------------------------- memory
//
// Program ROM, and everything the map calls RAM. RAM is ZERO-filled here, not
// 0xFFFFFFFF: the "unwritten memory reads 0xFFFF" rule in
// docs/mister-integration.md is about the generator's sparse model catching
// reads of never-written addresses, and MAME allocates real RAM zeroed. Using
// the sentinel here would diverge from the oracle on the first uninitialised
// read the boot code makes.
static std::vector<uint8_t> prog_rom;
// "main_data", mapped at 0x02000000 and again at 0x06000000 (offset 0x1000000).
// Loading it is not optional: the boot code COPIES CODE OUT OF IT INTO RAM and
// jumps there, so without it the core runs half a million instructions, lands
// on a zero word in 2A-CRX RAM and traps on opcode 0x00 -- which looks like a
// decoder fault and is a missing ROM.
static std::vector<uint8_t> main_data;
static std::map<uint32_t, uint32_t> ram;

// Regions the CPU may write. Anything else is logged once and dropped, which is
// how an unimplemented device announces itself instead of silently accepting.
struct Region { uint32_t lo, hi; const char *name; };
static const Region WRITABLE[] = {
  // model2o, NOT 2A-CRX. daytona93 runs on the ORIGINAL Model 2 board
  // (GAME(...) names model2o_state), and its map differs from the 2A-CRX one
  // the study targets in a way that matters here:
  //
  //   map(0x00200000, 0x0021ffff).ram()                        128 KB, not 256
  //   map(0x00220000, 0x0023ffff).rom().region("maincpu", 0x20000)
  //
  // The upper half is a ROM MIRROR of the program ROM's second 128 KB. Treating
  // the whole 256 KB as RAM read zero there, and the boot code calls 0x00227cf0
  // -- so the core executed 521,748 instructions in exact agreement with MAME
  // and then trapped on opcode 0x00, which looks like a decoder fault and is a
  // memory map that was copied from the wrong variant.
  { 0x00200000, 0x0021ffff, "board RAM"      },
  { 0x00500000, 0x005fffff, "work RAM"       },
  { 0x00800000, 0x00803fff, "geo"            },
  { 0x00880000, 0x00887fff, "copro"          },
  { 0x00900000, 0x0097ffff, "buffer RAM"     },
  { 0x00980000, 0x0098003f, "video control"  },
  { 0x00e00000, 0x00e00037, "CPU control"    },
  { 0x00e80000, 0x00e80007, "IRQ"            },
  { 0x00f00000, 0x00f0000f, "timers"         },
  { 0x01000000, 0x0101ffff, "tilemap"        },
  { 0x01020000, 0x01070003, "tile regs"      },
  { 0x01080000, 0x011fffff, "char RAM"       },
  { 0x01800000, 0x01803fff, "palette"        },
  { 0x01810000, 0x0181c003, "colour xlat"    },
  { 0x01a00000, 0x01a1ffff, "m2comm"         },
  { 0x01c00000, 0x01c80003, "I/O"            },
  { 0x01d00000, 0x01d03fff, "backup SRAM"    },
  { 0x10000000, 0x10ffffff, "renderer regs"  },
  { 0x11600000, 0x116fffff, "framebuffer"    },
  { 0x12000000, 0x1282ffff, "texture/luma"   },
};

static const char *region_of(uint32_t a) {
  for (const auto &r : WRITABLE) if (a >= r.lo && a <= r.hi) return r.name;
  return nullptr;
}

static std::map<uint32_t, uint64_t> unmapped_rd, unmapped_wr;
// WHICH INSTRUCTION DID IT. A count of unmapped reads says the CPU went
// somewhere it should not; it does not say who sent it, and that is the only
// part that leads anywhere. The IP is taken from the DUT at the moment of the
// access -- first occurrence kept, because the first one is the cause and the
// rest are usually the same loop repeating.
static std::map<uint32_t, uint32_t> unmapped_rd_ip;

// ------------------------------------------------- interrupt controller
//
// model2.cpp: a 12-bit request register and a 12-bit enable, folded onto the
// i960's four lines by irq_update():
//
//   IRQ0 = bit 0 (V-BLANK)   IRQ1 = bit 1   IRQ2 = bits 2-9   IRQ3 = bits 10-11
//
// This is modelled because without it the core boots, writes the tilemap, and
// then sits in a poll loop forever -- which reads as "the CPU stopped" and is
// actually "the machine never told it a frame had ended".
static uint32_t intreq = 0, intena = 0;
static uint32_t videoctl = 0;
static uint64_t vblanks = 0;
static bool dpram0 = false;
static std::vector<uint8_t> dpram;
static uint32_t dpram_fill = 0;

static void drive_irq() {
  dut->irq = uint8_t(((intreq & 0x001u) ? 1u : 0u) |
                     ((intreq & 0x002u) ? 2u : 0u) |
                     ((intreq & 0x3fcu) ? 4u : 0u) |
                     ((intreq & 0xc00u) ? 8u : 0u));
}

// The addresses read in the recent past. A core sitting in a poll loop is
// waiting on ONE address, and naming it is the difference between a diagnosis
// and a guess -- decoding the loop by hand to work out which address a MEMA
// form refers to is how that turns into an afternoon.
static std::map<uint32_t, uint64_t> recent_rd;
static bool rd_log = false;
static uint32_t watch_lo = 1, watch_hi = 0;   // empty range by default
// +rdwatch=LO,HI logs every READ in an address range with the IP that issued
// it and the value returned. +watch is keyed on the IP and answers "were we
// looking at the same instruction"; this is keyed on the ADDRESS and answers
// "did that instruction get the same data", which is the half a PC comparison
// structurally cannot see.
static uint32_t rdw_lo = 1, rdw_hi = 0;
static int      rdw_n  = 0;
// A PER-FRAME RECORDING OF THE SOUND WINDOW, indexed by our own V-blank count.
// tools/mame_m2_sound_capture.lua writes it: frame N at offset N*SNDCAP_LEN.
//
// This is not a model of the sound board and cannot become one. It is an
// ORACLE, in the same sense the PC differential is: it answers "if the sound
// window held what MAME's held at this point in time, does the rest of the
// machine agree with MAME?" A yes means every remaining defect is in the sound
// board. A no means there is a second one, and finding that out costs an
// afternoon rather than the days a real 68000 will take.
//
// Frames are the right axis and instruction counts are not. Our i960 retires
// ~110,000 instructions per frame against MAME's ~307,000, so the two are not
// comparable by instruction; both reach 178 V-blanks over the same 3.1 seconds
// because both are driven by the same 57.5 Hz refresh, and R37's handshake
// moves on frames -- 1, 7, 8, 10, 21, 175.
// THE I/O BOARD, modelled the way rtl/io/m2_ioboard.sv models it, so the two
// can disagree visibly rather than quietly. This is the device the boot has
// been waiting on since R40 -- 0x01c00000 is an MB8421 dual-port RAM whose far
// side is SEGA_MODEL1IO, not the sound board.
//
// Two replies on two triggers, measured in docs/io-board.md:
//   status 0x21 -> 0x40  one frame after the i960 writes its block
//   flag   0x20 -> 0x00  at frame 174, on the board's own self-test, whatever
//                        the i960 has done in the meantime
//
// Driven off the V-BLANK COUNT rather than a cycle count, because that is the
// axis the measurement is on and the two machines do not agree on cycles.
static uint8_t  io_dp[2048];
static bool     io_win_written = false;
static uint64_t io_win_frame   = 0;
static bool     io_status_done = false;
static bool     io_flag_cleared = false;
static bool     io_board = true;          // +noioboard turns it off
static uint64_t io_selftest_frame = 174;
// Frame 7, measured. The window fill rides on the same event because that is
// when it was observed, and its attribution is still inferred either way.
static uint64_t io_status_frame  = 7;

// THE STATUS BYTE IS NOT A REPLY TO THE WINDOW WRITE. That was the first model
// and the boot disproved it in one run: it parks at
//
//   0022824C: ldob    0x1c00042,g4      ; status
//   00228254: setbit  6,0,g1            ; 0x40
//   00228258: cmpibne g4,g1,0x22824c    ; spin until status == 0x40
//   0022825C: mov     3,g2
//   00228260: stob    g2,0x1c00040      ; only THEN write the flag again
//
// waiting for 0x40 BEFORE it writes anything into the window. So the board
// raises the status on its own schedule -- frame 7 -- and the window write at
// frame 6 was concurrent, not causal. Two events in consecutive frames are not
// a cause and an effect, and reading them as one produced a model that
// deadlocks against the very code it was built from.
static void io_board_step() {
  if (!io_board) return;
  if (!io_status_done && vblanks >= io_status_frame) {
    io_dp[0x21] = 0x40;
    for (uint32_t n = 0x143; n <= 0x17b; n++) io_dp[n] = 0xff;
    io_dp[0x17c] = 0x01;
    io_status_done = true;
  }
  // ONCE AWAKE, THE BOARD ANSWERS; IT IS NOT A ONE-SHOT.
  //
  // The first version cleared the flag exactly once, at frame 174, on the
  // reasoning that MAME clears it exactly once. That is true of MAME and it
  // deadlocks here, because our i960 is roughly three times slower per frame:
  // it had not yet written its command when the single clear fired, so the
  // clear landed on nothing and the command that arrived afterwards was never
  // answered. The boot parked at
  //
  //   00228268: ldob    0x1c00040,g4
  //   00228270: cmpibne 0,g4,0x228268
  //
  // A one-shot is a description of the reference's TIMELINE, not of the
  // board's behaviour. The behaviour, which Model 1 established by reading the
  // Z80 ROM, is that the board is not listening until its self-test finishes
  // and answers requests after that. Modelled that way it does not depend on
  // the two machines running at the same speed.
  //
  // KNOWN DIVERGENCE, stated rather than papered over: on the reference the
  // flag STAYS set after boot -- the CPU re-raises it once a frame as a
  // doorbell and it is never cleared again. This clears it every time. That is
  // wrong for the post-boot phase and right for the phase the boot is in, and
  // the differential will say when it starts to matter.
  if (vblanks >= io_selftest_frame && io_dp[0x20] != 0x00) {
    io_dp[0x20] = 0x00;
    io_flag_cleared = true;
  }
}

static std::vector<uint8_t> sndcap;
static const uint32_t SNDCAP_BASE = 0x01c00000u;
static uint32_t sndcap_len = 0x1000;

static uint32_t mem_read_inner(uint32_t a) {
  a &= ~3u;
  if (rd_log) ++recent_rd[a];
  // fifo_control_r: MAME returns 1 when the coprocessor's output FIFO is EMPTY.
  // Returning 0 -- which "unmapped reads as zero" does -- tells the game the
  // copro still has work queued, and it waits for a drain that never comes.
  // 2.5 million reads of this address is what that looks like.
  //
  // There is no TGP here, so "permanently drained" is the honest stub: it says
  // the copro has finished, which for a copro that never starts is true.
  if (a == 0x00980004u) return 1;
  // videoctl_r: the frame-number bits the game uses for double buffering, plus
  // the two control bits it wrote. Without a changing frame number a game that
  // waits for the buffer to flip waits forever.
  if (a == 0x0098000cu) {
    const uint32_t fn = uint32_t(vblanks);
    return (videoctl & 1u) ? (((fn & 1u) << 2) | (videoctl & 3u))
                           : (((fn & 2u) << 1) | (videoctl & 3u));
  }
  if (a == 0x00e80000u) return intreq;          // irq_request_r
  if (a == 0x00e80004u) return intena;          // irq_enable_r
  // EXPERIMENT, not a model. The boot polls the sound board's dual-port RAM at
  // 0x01c00040 and will not proceed until it reads 0. There is no sound board
  // here, so it never does -- and MAME sits in the same loop for its whole
  // trace window. +dpram0 answers "what is actually gating the first drawn
  // frame" by forcing the poll to succeed. It is a switch precisely because it
  // is a lie: nothing downstream of it is evidence about the real machine.
  // The DPRAM is 8 BITS WIDE, at bytes 0 and 2 of each dword -- MAME's map says
  // .umask32(0x00ff00ff). So 0x01c00040 and 0x01c00042 are two bytes of ONE
  // word, and an override keyed on the byte address is keyed on nothing: the
  // read has already been masked to the word. The first version of this
  // experiment did exactly that and reported identical cycle counts for every
  // value it was given, which is what a switch that changes nothing looks like.
  // A CANNED SOUND BOARD. daytona93 is model2o, whose sound board is a separate
  // 68000 behind a dual-port RAM at 0x01c00000, and the i960's boot will not
  // proceed until that board answers. Rather than emulate it to find out
  // whether the rest works, this replays the DPRAM contents captured out of
  // MAME at the moment its own boot cleared the handshake.
  //
  // It is a RECORDING, not a model: it cannot answer a command the capture did
  // not contain, and anything reached through it is evidence about our CPU and
  // renderer, not about the sound board.
  if (!sndcap.empty() && a >= SNDCAP_BASE && a < SNDCAP_BASE + sndcap_len) {
    const uint64_t nf = sndcap.size() / sndcap_len;
    // Past the end of the recording, hold the last frame. The capture is
    // finite and the run is not; holding is wrong, but it is wrong in a way
    // that shows up as a divergence rather than as zeros, which do not.
    const uint64_t fr = (vblanks < nf) ? vblanks : (nf - 1);
    const uint8_t *p = &sndcap[size_t(fr) * sndcap_len + (a - SNDCAP_BASE)];
    return uint32_t(p[0]) | (uint32_t(p[1]) << 8) |
           (uint32_t(p[2]) << 16) | (uint32_t(p[3]) << 24);
  }
  if (!dpram.empty() && a >= 0x01c00000u && a < 0x01c01000u) {
    const uint32_t o = a - 0x01c00000u;
    if (o + 3 < dpram.size())
      return uint32_t(dpram[o]) | (uint32_t(dpram[o+1]) << 8) |
             (uint32_t(dpram[o+2]) << 16) | (uint32_t(dpram[o+3]) << 24);
    return 0;
  }
  // THE SHIPPING STUB, and the default now. Two bytes answer the boot's poll:
  // byte 0 of 0x01c00040 is 0 and byte 2 is 0x40, both in one 32-bit word
  // because the DPRAM is eight bits wide at bytes 0 and 2. This is what
  // Model2.sv implements, and it gets further than the 4 KB MAME capture --
  // same boot, and SENSIBLE settings values where the recording gave garbage.
  if (io_board && a >= 0x01c00000u && a < 0x01c01000u) {
    io_board_step();
    const uint32_t k = (a - 0x01c00000u) >> 2;      // dword -> DPRAM byte pair
    return uint32_t(io_dp[2*k]) | (uint32_t(io_dp[2*k + 1]) << 16);
  }
  if (a >= 0x01c00000u && a < 0x01c01000u) {
    if (dpram0) return (a == 0x01c00040u) ? ((dpram_fill & 0xffu) << 16) : 0u;
    return (a == 0x01c00040u) ? 0x00400000u : 0u;
  }
  // The 0x00220000 ROM mirror, model2o only. Checked before the RAM map so it
  // cannot be shadowed by a stray write.
  if (a >= 0x00220000u && a < 0x00240000u) {
    const uint32_t o = (a - 0x00220000u) + 0x20000u;
    if (o + 3 < prog_rom.size())
      return uint32_t(prog_rom[o]) | (uint32_t(prog_rom[o+1]) << 8) |
             (uint32_t(prog_rom[o+2]) << 16) | (uint32_t(prog_rom[o+3]) << 24);
    return 0;
  }
  if (a < 0x00200000u) {                       // program ROM, and its dead space
    if (a + 3 < prog_rom.size())
      return uint32_t(prog_rom[a]) | (uint32_t(prog_rom[a+1]) << 8) |
             (uint32_t(prog_rom[a+2]) << 16) | (uint32_t(prog_rom[a+3]) << 24);
    return 0;                                  // MAME's region is 0x200000, zero-filled
  }
  if (a >= 0x02000000u && a < 0x04000000u) {           // main_data
    const uint32_t o = a - 0x02000000u;
    if (o + 3 < main_data.size())
      return uint32_t(main_data[o]) | (uint32_t(main_data[o+1]) << 8) |
             (uint32_t(main_data[o+2]) << 16) | (uint32_t(main_data[o+3]) << 24);
    return 0;
  }
  if (a >= 0x06000000u && a < 0x07000000u) {           // "extra" data: +0x1000000
    const uint32_t o = (a - 0x06000000u) + 0x1000000u;
    if (o + 3 < main_data.size())
      return uint32_t(main_data[o]) | (uint32_t(main_data[o+1]) << 8) |
             (uint32_t(main_data[o+2]) << 16) | (uint32_t(main_data[o+3]) << 24);
    return 0;
  }
  auto it = ram.find(a);
  if (it != ram.end()) return it->second;
  // BACKUP SRAM POWERS UP ALL ONES, NOT ZERO.
  //
  //   NVRAM(config, "backup1", nvram_device::DEFAULT_ALL_1);
  //
  // Everything else MAME maps with .ram() is zero-filled, so this is the one
  // region where "unwritten" is 0xFF. It is also the region whose contents the
  // boot tests against a signature before deciding whether to initialise it,
  // which makes the difference between 0x00 and 0xFF a branch rather than a
  // detail.
  //
  // docs/mister-integration.md has said "unwritten memory reads 0xFFFF, never
  // zero" since before this harness existed. The rule was written down, and
  // this file broke it for the one region where MAME agrees with it.
  if (a >= 0x01d00000u && a <= 0x01d03fffu) return 0xffffffffu;
  const char *r = region_of(a);
  if (!r) {
    if (!unmapped_rd[a]++) unmapped_rd_ip[a] = dut ? dut->dbg_ip : 0;
  }
  return 0;
}

static uint32_t mem_read(uint32_t a) {
  const uint32_t v = mem_read_inner(a);
  if (a >= rdw_lo && a <= rdw_hi && rdw_n < 60) {
    std::printf("  rd %08x -> %08x   from IP %08x\n", a & ~3u, v,
                dut ? dut->dbg_ip : 0);
    ++rdw_n;
  }
  return v;
}

static void mem_write(uint32_t a, uint32_t v, uint8_t be) {
  a &= ~3u;
  if (a < 0x00200000u) return;                 // ROM. MAME's map is .rom().nopw()
  if (a >= 0x00220000u && a < 0x00240000u) return;   // the model2o ROM mirror
  // irq_ack_w CLEARS the bits that are set in the written value -- `m_intreq &=
  // data`. Treating it as a plain store leaves the request asserted and the
  // handler re-enters forever.
  if (io_board && a >= 0x01c00000u && a < 0x01c01000u) {
    const uint32_t k = (a - 0x01c00000u) >> 2;
    if (be & 0x1) io_dp[2*k]     = uint8_t(v);
    if (be & 0x4) io_dp[2*k + 1] = uint8_t(v >> 16);
    // A write INTO THE WINDOW arms the reply. Watching the write and not the
    // contents, because the request is the write: a poll of the same address
    // looks identical in the RAM and means the opposite thing.
    const uint32_t n = 2*k;
    if (n >= 0x100 && n <= 0x17f) { io_win_written = true; io_win_frame = vblanks; }
    io_board_step();
    return;
  }
  if (a == 0x00e80000u) { intreq &= v; drive_irq(); return; }
  if (a == 0x00e80004u) { intena  = v; return; }
  if (a == 0x0098000cu) { videoctl = v; return; }        // videoctl_w
  const char *r = region_of(a);
  if (!r) { ++unmapped_wr[a]; return; }
  uint32_t cur = ram.count(a) ? ram[a] : 0;
  for (int l = 0; l < 4; l++)
    if (be & (1 << l)) cur = (cur & ~(0xffu << (l*8))) | (v & (0xffu << (l*8)));
  ram[a] = cur;
}

// 25 MHz core, 57.52 Hz frame -> 434,600 cycles. Real ratio, not a convenient
// small number: a V-blank rate faster than the handler can service produces a
// core that never leaves the interrupt handler, and that would look like a bug
// in take_interrupt.
static const uint64_t VBLANK_CYCLES = 434600;

static void tick() {
  if ((ticks % VBLANK_CYCLES) == (VBLANK_CYCLES - 1)) {
    ++vblanks;
    if (intena & 1u) { intreq |= 1u; drive_irq(); }
  }
  if (dut->bus_req) {
    const uint32_t a = dut->bus_addr & ~3u;
    if (dut->bus_we) mem_write(a, dut->bus_wdata, dut->bus_be);
    else             dut->bus_rdata = mem_read(a);
    dut->bus_ack = 1;
  } else dut->bus_ack = 0;
  dut->clk = 0; dut->eval();
  dut->clk = 1; dut->eval();
  ++ticks;
}

// ---------------------------------------------------------------- ROM load
static bool load_file(const std::string &path, std::vector<uint8_t> &out) {
  FILE *f = std::fopen(path.c_str(), "rb");
  if (!f) return false;
  std::fseek(f, 0, SEEK_END); long n = std::ftell(f); std::fseek(f, 0, SEEK_SET);
  out.resize(size_t(n));
  const size_t got = std::fread(out.data(), 1, size_t(n), f);
  std::fclose(f);
  return got == size_t(n);
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  uint64_t max_insn = 200000;
  bool     trace    = false;
  const char *tracefile = nullptr;
  const char *dumpdir = nullptr;
  const char *dpramfile = nullptr;
  const char *sndcapfile = nullptr;
  for (int i = 1; i < argc; i++) {
    if (!std::strncmp(argv[i], "+insn=", 6)) max_insn = std::strtoull(argv[i]+6, nullptr, 10);
    if (!std::strcmp (argv[i], "+trace"))    trace = true;
    if (!std::strncmp(argv[i], "+out=", 5))  tracefile = argv[i]+5;
    if (!std::strncmp(argv[i], "+dump=", 6)) dumpdir   = argv[i]+6;
    if (!std::strcmp (argv[i], "+dpram0"))   dpram0    = true;
    if (!std::strncmp(argv[i], "+dpram=", 7)) dpramfile = argv[i]+7;
    if (!std::strncmp(argv[i], "+sndcap=", 8)) sndcapfile = argv[i]+8;
    if (!std::strncmp(argv[i], "+rdwatch=", 9)) {
      rdw_lo = uint32_t(std::strtoul(argv[i]+9, nullptr, 16));
      const char *c = std::strchr(argv[i]+9, ',');
      rdw_hi = c ? uint32_t(std::strtoul(c+1, nullptr, 16)) : rdw_lo;
    }
    if (!std::strcmp (argv[i], "+rdlog"))     rd_log    = true;
    if (!std::strcmp (argv[i], "+noioboard")) io_board  = false;
    // +watch=LO,HI prints IP and the fetched instruction word for every
    // instruction retired in that range. The differential compares PROGRAM
    // COUNTERS; when it says we branched where MAME fell through, the next
    // question is whether we were even looking at the same instruction, and
    // no PC stream can answer that.
    if (!std::strncmp(argv[i], "+watch=", 7)) {
      watch_lo = uint32_t(std::strtoul(argv[i]+7, nullptr, 16));
      const char *c = std::strchr(argv[i], ',');
      watch_hi = c ? uint32_t(std::strtoul(c+1, nullptr, 16)) : watch_lo;
    }
    if (!std::strncmp(argv[i], "+dpfill=", 8)) dpram_fill = uint32_t(std::strtoul(argv[i]+8, nullptr, 16));
  }

  const char *rp = std::getenv("M2_ROMPATH");
  const std::string base = std::string(rp ? rp : (std::string(std::getenv("HOME") ? std::getenv("HOME") : ".") + "/roms/Model2").c_str());

  std::vector<uint8_t> lo, hi;
  const std::string dir = base + "/daytona93/";
  if (!load_file(dir + "epr-16530a.12", lo) || !load_file(dir + "epr-16531a.13", hi)) {
    std::printf("i960 ROM run: daytona93 program ROMs not found under %s\n", dir.c_str());
    std::printf("SKIP (no ROMs; set M2_ROMPATH to a directory holding daytona93/)\n");
    return 0;
  }
  if (lo.size() != 0x20000 || hi.size() != 0x20000) {
    std::printf("unexpected program ROM sizes %zu/%zu\n", lo.size(), hi.size());
    return 1;
  }

  // ROM_LOAD32_WORD, generically: `len` bytes of `file` become 16-bit words at
  // 32-bit stride starting at `off`. off 0 fills the low half of each dword,
  // off 2 the high half.
  auto load32_word = [&](std::vector<uint8_t> &dst, const char *name,
                         uint32_t off, uint32_t len) -> bool {
    std::vector<uint8_t> f;
    if (!load_file(dir + name, f)) return false;
    if (f.size() < len) return false;
    const uint32_t base = off & ~3u, half = off & 2u;
    for (uint32_t w = 0; w * 2 < len; ++w) {
      const uint32_t d = base + w * 4 + half;
      if (d + 1 >= dst.size()) break;
      dst[d]     = f[w * 2];
      dst[d + 1] = f[w * 2 + 1];
    }
    return true;
  };

  // ROM_LOAD32_WORD: .12 is the low 16 bits of each dword, .13 the high 16.
  prog_rom.assign(0x40000, 0);
  for (size_t w = 0; w < 0x10000; ++w) {
    prog_rom[w*4 + 0] = lo[w*2 + 0];
    prog_rom[w*4 + 1] = lo[w*2 + 1];
    prog_rom[w*4 + 2] = hi[w*2 + 0];
    prog_rom[w*4 + 3] = hi[w*2 + 1];
  }

  // daytona93's "main_data", transcribed from ROM_START( daytona93 ). Absent
  // files are tolerated -- the region reads 0 there, exactly as MAME's
  // zero-filled region does -- so a partial set still runs.
  main_data.assign(0x2000000, 0);
  int md_loaded = 0;
  md_loaded += load32_word(main_data, "mpr-16528.10", 0x000000, 0x200000);
  md_loaded += load32_word(main_data, "mpr-16529.11", 0x000002, 0x200000);
  md_loaded += load32_word(main_data, "mpr-16526.8",  0x400000, 0x200000);
  md_loaded += load32_word(main_data, "mpr-16527.9",  0x400002, 0x200000);
  md_loaded += load32_word(main_data, "epr-16534a.6", 0x800000, 0x100000);
  md_loaded += load32_word(main_data, "epr-16535a.7", 0x800002, 0x100000);
  // ROM_COPY( "main_data", 0x900000, ... ) -- the same 1 MB appears at SIX
  // more addresses. MAME does this in the ROM definition, so the CPU sees it.
  //
  // SIX, not three, and not the four this comment used to claim. ROM_START(
  // daytona93 ) lists 0xa00000 through 0xf00000; the code copied three and the
  // comment said four, so 0xd00000-0xffffff read as zero here and as real data
  // in MAME. A zero read from a mirror is a null pointer a few instructions
  // later, which is exactly how it presented.
  for (uint32_t d : {0xa00000u, 0xb00000u, 0xc00000u,
                     0xd00000u, 0xe00000u, 0xf00000u})
    std::memcpy(&main_data[d], &main_data[0x900000], 0x100000);
  std::printf("  main_data: %d of 6 files loaded\n", md_loaded);

  if (sndcapfile) {
    if (load_file(sndcapfile, sndcap) && sndcap.size() >= sndcap_len)
      std::printf("  sound window recording: %zu frames of %u bytes from %s\n",
                  sndcap.size() / sndcap_len, sndcap_len, sndcapfile);
    else { std::printf("  cannot use %s as a sound recording\n", sndcapfile);
           sndcap.clear(); }
  }
  if (dpramfile && load_file(dpramfile, dpram))
    std::printf("  canned sound-board DPRAM: %zu bytes from %s\n", dpram.size(), dpramfile);

  dut = new Vi960_top;
  dut->rst_n = 0; dut->bus_ack = 0; dut->irq = 0;
  for (int i = 0; i < 8; i++) tick();
  dut->rst_n = 1;

  std::printf("i960 ROM run: daytona93 program ROM, %zu bytes\n", prog_rom.size());
  std::printf("  boot record in ROM: SAT=%08x PRCB=%08x IP=%08x\n",
              mem_read(0), mem_read(4), mem_read(12));

  FILE *tf = tracefile ? std::fopen(tracefile, "w") : nullptr;

  uint32_t acc_prev = 0;
  uint64_t insns = 0, stall = 0;
  uint32_t last_ip = 0xffffffffu;
  std::map<uint32_t, uint64_t> ip_hits;
  int watch_n = 0;

  while (insns < max_insn) {
    const uint32_t acc0 = dut->dbg_acc_cnt;
    uint32_t guard = 0;
    while (dut->dbg_acc_cnt == acc0 && guard++ < 100000 && !dut->trap) tick();
    if (dut->trap) break;
    if (guard >= 100000) { ++stall; break; }
    acc_prev = dut->dbg_acc_cnt;
    (void)acc_prev;
    const uint32_t ip = dut->dbg_ip;
    if (ip != last_ip) { ++ip_hits[ip]; last_ip = ip; }
    if (tf) std::fprintf(tf, "%08x\n", ip);
    if (ip >= watch_lo && ip <= watch_hi && watch_n < 200) {
      std::printf("  watch %08x  insn=%08x\n", ip, dut->dbg_insn);
      ++watch_n;
    }
    if (trace && insns < 64) std::printf("  %6llu  ip=%08x insn=%08x\n",
                                         (unsigned long long)insns, ip, dut->dbg_insn);
    ++insns;
  }
  if (tf) std::fclose(tf);

  if (rd_log) {
    std::printf("\n  most-read addresses:\n");
    std::vector<std::pair<uint64_t,uint32_t>> v;
    for (auto &kv : recent_rd) v.push_back({kv.second, kv.first});
    std::sort(v.rbegin(), v.rend());
    for (size_t i = 0; i < v.size() && i < 8; ++i)
      std::printf("    %08x  %llu reads\n", v[i].second, (unsigned long long)v[i].first);
  }
  std::printf("\n  executed %llu instructions over %llu cycles, %zu distinct IPs\n",
              (unsigned long long)insns, (unsigned long long)ticks, ip_hits.size());
  std::printf("  final IP %08x  PC=%08x  ICR=%08x  interrupts taken %u\n",
              dut->dbg_ip, dut->dbg_pc, dut->dbg_icr, dut->dbg_intr_cnt);
  if (dut->trap)
    std::printf("  TRAPPED on op %02x at IP %08x\n", dut->trap_op, dut->dbg_ip);
  if (stall) std::printf("  STALLED (no instruction accepted in 100000 cycles)\n");
  std::printf("  %llu vblanks asserted, intena=%03x intreq=%03x\n",
              (unsigned long long)vblanks, intena, intreq);
  if (!unmapped_rd.empty()) {
    std::printf("  unmapped reads (top addresses):\n");
    int n = 0;
    for (auto &kv : unmapped_rd) {
      if (n++ >= 8) break;
      std::printf("    %08x  x%-8llu first read from IP %08x\n", kv.first,
                  (unsigned long long)kv.second, unmapped_rd_ip[kv.first]);
    }
  }
  for (auto &kv : unmapped_wr)
    std::printf("  unmapped write %08x x%llu\n", kv.first, (unsigned long long)kv.second);

  // What did it actually touch? This is the question the run exists to answer:
  // a core that boots writes tile RAM, palette and work RAM, and one that does
  // not is stuck somewhere specific.
  std::map<std::string, uint64_t> touched;
  for (auto &kv : ram) { const char *r = region_of(kv.first); if (r) ++touched[r]; }
  std::printf("\n  regions written:\n");
  for (auto &kv : touched)
    std::printf("    %-16s %llu words\n", kv.first.c_str(), (unsigned long long)kv.second);

  // Dump what the CPU built, in the same layout tools/mame_m2_tiledump.lua
  // writes, so the two are directly comparable. This is the DATA half of the
  // differential test: the PC comparison proves the core executed the same
  // instructions, and proves nothing at all about the values it stored.
  if (dumpdir) {
    struct { const char *name; uint32_t base, size; } R[] = {
      { "tile",    0x01000000u, 0x010000u },
      { "char",    0x01080000u, 0x080000u },
      { "palette", 0x01800000u, 0x004000u },
      // The game programs this itself once it is past the sound handshake, so
      // the render uses ITS table rather than a capture from MAME.
      { "colorxlat", 0x01810000u, 0x00c000u },
    };
    for (auto &r : R) {
      const std::string fn = std::string(dumpdir) + "/" + r.name + ".bin";
      FILE *f = std::fopen(fn.c_str(), "wb");
      if (!f) { std::printf("  cannot write %s\n", fn.c_str()); continue; }
      for (uint32_t a = r.base; a < r.base + r.size; a += 4) {
        const uint32_t v = mem_read(a);
        const uint8_t b[4] = { uint8_t(v), uint8_t(v>>8), uint8_t(v>>16), uint8_t(v>>24) };
        std::fwrite(b, 1, 4, f);
      }
      std::fclose(f);
    }
    std::printf("  dumped tile/char/palette to %s\n", dumpdir);
  }

  const bool ok = (insns >= 1000) && !dut->trap && !stall;
  std::printf("\n%s\n", ok ? "PASS" : "FAIL");
  return ok ? 0 : 1;
}
