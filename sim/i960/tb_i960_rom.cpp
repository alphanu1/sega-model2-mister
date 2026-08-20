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
static bool dpram0 = false;
static uint32_t dpram_fill = 0;

static void drive_irq() {
  dut->irq = uint8_t(((intreq & 0x001u) ? 1u : 0u) |
                     ((intreq & 0x002u) ? 2u : 0u) |
                     ((intreq & 0x3fcu) ? 4u : 0u) |
                     ((intreq & 0xc00u) ? 8u : 0u));
}

static uint32_t mem_read(uint32_t a) {
  a &= ~3u;
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
  if (dpram0 && a >= 0x01c00000u && a < 0x01c01000u)
    return (a == 0x01c00040u) ? ((dpram_fill & 0xffu) << 16) : 0u;
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
  const char *r = region_of(a);
  if (!r) ++unmapped_rd[a];
  return 0;
}

static void mem_write(uint32_t a, uint32_t v, uint8_t be) {
  a &= ~3u;
  if (a < 0x00200000u) return;                 // ROM. MAME's map is .rom().nopw()
  if (a >= 0x00220000u && a < 0x00240000u) return;   // the model2o ROM mirror
  // irq_ack_w CLEARS the bits that are set in the written value -- `m_intreq &=
  // data`. Treating it as a plain store leaves the request asserted and the
  // handler re-enters forever.
  if (a == 0x00e80000u) { intreq &= v; drive_irq(); return; }
  if (a == 0x00e80004u) { intena  = v; return; }
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
static uint64_t vblanks = 0;

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
  for (int i = 1; i < argc; i++) {
    if (!std::strncmp(argv[i], "+insn=", 6)) max_insn = std::strtoull(argv[i]+6, nullptr, 10);
    if (!std::strcmp (argv[i], "+trace"))    trace = true;
    if (!std::strncmp(argv[i], "+out=", 5))  tracefile = argv[i]+5;
    if (!std::strncmp(argv[i], "+dump=", 6)) dumpdir   = argv[i]+6;
    if (!std::strcmp (argv[i], "+dpram0"))   dpram0    = true;
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
  // ROM_COPY( "main_data", 0x900000, ... ) -- the same 1 MB appears at four
  // more addresses. MAME does this in the ROM definition, so the CPU sees it.
  for (uint32_t d : {0xa00000u, 0xb00000u, 0xc00000u})
    std::memcpy(&main_data[d], &main_data[0x900000], 0x100000);
  std::printf("  main_data: %d of 6 files loaded\n", md_loaded);

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
    if (trace && insns < 64) std::printf("  %6llu  ip=%08x insn=%08x\n",
                                         (unsigned long long)insns, ip, dut->dbg_insn);
    ++insns;
  }
  if (tf) std::fclose(tf);

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
      std::printf("    %08x  %llu\n", kv.first, (unsigned long long)kv.second);
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
