// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// m2_315_5649 (and the m2_93c46 on its port A) against a C++ transcription of
// MAME 0.289's sega_315_5649_device and eeprom_serial_93cxx_device (16-bit
// 93C46, output on the falling clock, streaming reads, locked at reset), wired
// as model2a(): PA -> eeprom_w (bit 0 ctrlmode, 5 DI, 6 CS, 7 CLK), PB <-
// in0_r, PC <- IN1, PD <- IN2, PG <- SW.
//
// The bus is the i960's through m2_cpu_bridge: one select cycle per access,
// device offset n at dword n >> 1, lane 0 (n even) or 2 (n odd). Every read
// of every offset is compared. The EEPROM is driven mostly with well-formed
// commands (READ with streaming, WRITE, ERASE, LOCK/UNLOCK, WRITEALL,
// ERASEALL) and sometimes with noise, so out-of-protocol edges are compared
// too. Usage: Vm2_315_5649 [+n=<accesses>] [+seed=<s>]

#include "Vm2_315_5649.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <random>

// ---------------------------------------------------------------- the reference
struct Ee93 {
  enum St { IN_RESET, WAIT_START, WAIT_CMD, READING, WAIT_DATA, WAIT_DONE } st = IN_RESET;
  uint16_t mem[64];
  int cs = 0, clk = 0, di = 0;
  uint32_t cmdacc = 0, sh = 0; int bits = 0; int addr = 0; int cmd = 0;
  bool locked = true;
  Ee93() { for (auto &m : mem) m = 0xffff; }
  void reset() { st = IN_RESET; bits = 0; locked = true; cs = clk = di = 0; }
  int do_read() const {
    if (st == READING) return (sh >> 31) & 1;
    return 1;   // tristate pull-up; in WAIT_START "ready" (no write time)
  }
  void exec_cmd() {
    addr = cmdacc & 0x3f;
    int op = cmdacc >> 6;
    bits = 0;
    switch (op) {
      case 2: sh = 0; st = READING; cmd = 2; break;
      case 1: sh = 0; st = WAIT_DATA; cmd = 1; break;
      case 3: if (locked) { st = IN_RESET; break; } mem[addr] = 0xffff; st = WAIT_DONE; break;
      default:
        switch (addr >> 4) {
          case 0: locked = true; st = IN_RESET; break;
          case 1: sh = 0; st = WAIT_DATA; cmd = 4; break;   // WRITEALL
          case 2: if (locked) { st = IN_RESET; break; } for (auto &m : mem) m = 0xffff; st = WAIT_DONE; break;
          case 3: locked = false; st = IN_RESET; break;
        }
        addr = 0;
    }
  }
  void event(bool cs_rise, bool cs_fall, bool clk_rise, bool clk_fall) {
    switch (st) {
      case IN_RESET: if (cs_rise) st = WAIT_START; break;
      case WAIT_START:
        if (clk_rise && di) { cmdacc = 0; bits = 0; st = WAIT_CMD; }
        else if (cs_fall) st = IN_RESET;
        break;
      case WAIT_CMD:
        if (clk_rise) { cmdacc = (cmdacc << 1) | di; if (++bits == 8) exec_cmd(); }
        else if (cs_fall) st = IN_RESET;
        break;
      case READING:
        if (clk_fall) {
          int bi = bits++;
          if (bi % 16 == 0) sh = uint32_t(mem[(addr + bits / 16) & 63]) << 16;
          else sh = (sh << 1) | 1;
        } else if (cs_fall) st = IN_RESET;
        break;
      case WAIT_DATA:
        if (clk_rise) {
          sh = (sh << 1) | di;
          if (++bits == 16) {
            if (locked) { st = IN_RESET; break; }
            if (cmd == 1) mem[addr] = sh & 0xffff;
            else for (auto &m : mem) m &= sh & 0xffff;
            st = WAIT_DONE;
          }
        } else if (cs_fall) st = IN_RESET;
        break;
      case WAIT_DONE: if (cs_fall) st = IN_RESET; break;
    }
  }
  // eeprom_w order: di_write, clk_write, cs_write
  void write_pa(uint8_t d) {
    di = (d >> 5) & 1;
    int nclk = (d >> 7) & 1, ncs = (d >> 6) & 1;
    if (nclk != clk) { clk = nclk; event(false, false, clk, !clk); }
    if (ncs != cs)   { cs = ncs;   event(cs, !cs, false, false); }
  }
};

struct Io5649 {
  uint8_t pv[7]; uint8_t dir = 0xff, mode = 0; int an = 0;
  uint8_t in0 = 0xff, in1 = 0xff, in2 = 0xff, sw = 0xff;
  uint8_t anv[3] = {0xff, 0xff, 0xff};   // R862: an_port_cb 0-2 (srallyc); 3-7 unbound
  Ee93 ee; bool ctrlmode = false;
  void power_on() { for (auto &v : pv) v = 0xff; ee.reset(); ee.cs = ee.clk = ee.di = 1; an = 0; reset(); }
  // machine_reset: the device's direction and mode, and model2's m_ctrlmode.
  // R862: not m_analog_channel -- 0 at construction, untouched by device_reset.
  void reset() { dir = 0xff; mode = 0; ctrlmode = false; }
  uint8_t in_port(int p) {
    switch (p) {
      case 1: return ctrlmode ? uint8_t(0xc0 | (ee.do_read() << 5) | 0x10 | (in0 & 0x0f)) : in0;
      case 2: return in1; case 3: return in2; case 6: return sw;
      default: return 0xff;
    }
  }
  uint8_t read(int off) {
    switch (off) {
      case 0: case 1: case 2: case 3: case 4: case 5: case 6:
        return (dir >> off) & 1 ? in_port(off) : pv[off];
      case 0xb: case 0xc: return 0x00;
      case 0xd: return 0x0c;
      case 0xf: { uint8_t v = an < 3 ? anv[an] : 0xff; an = (an + 1) & 7; return v; }
      default: return 0xff;
    }
  }
  void write(int off, uint8_t d) {
    if (off <= 6) {
      pv[off] = d;
      if (off == 0) { ctrlmode = d & 1; ee.write_pa(d); }   // eeprom_w
    } else if (off == 8) dir = d;
    else if (off == 0xe) mode = d;
    else if (off == 0xf) an = d & 7;
  }
};

// ---------------------------------------------------------------- the bench
static Vm2_315_5649 *d;
static uint64_t cyc;
static void tick() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); ++cyc; }

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  uint64_t n = 2'000'000; unsigned seed = 1;
  for (int i = 1; i < argc; i++) {
    if (!std::strncmp(argv[i], "+n=", 3)) n = std::strtoull(argv[i] + 3, nullptr, 10);
    if (!std::strncmp(argv[i], "+seed=", 6)) seed = unsigned(std::strtoul(argv[i] + 6, nullptr, 10));
  }
  std::mt19937 rng(seed);
  d = new Vm2_315_5649;
  Io5649 ref; ref.power_on();
  d->clk = 0; d->por_n = 0; d->rst_n = 0; d->sel = 0; d->we = 0; d->word = 0; d->be = 0; d->wdata = 0;
  d->in0 = 0xff; d->in1 = 0xff; d->in2 = 0xff; d->sw = 0xff;
  d->an0 = 0xff; d->an1 = 0xff; d->an2 = 0xff;
  for (int i = 0; i < 4; i++) tick();
  d->por_n = 1; d->rst_n = 1; tick();

  uint64_t pors = 0, resets = 0, reads = 0, bad = 0, ee_reads = 0, ee_ones = 0, ee_zeros = 0, cmds = 0, pe_checks = 0;
  auto access = [&](bool we, int off, uint8_t data) -> void {
    // optional idle gap, as the i960 bit-bangs slowly
    int gap = 4 + int(rng() % 6);   // the i960 is never closer than this (25 MHz bus, bridge)
    for (int i = 0; i < gap; i++) tick();
    d->sel = 1; d->we = we; d->word = off >> 1;
    // a byte access names one lane; a dword read sometimes names both
    bool both = !we && (rng() % 4 == 0);
    d->be = both ? 0x5 : ((off & 1) ? 0x4 : 0x1);
    d->wdata = (off & 1) ? (uint32_t(data) << 16) : data;
    d->wdata |= (rng() & 0xff00ff00u);   // junk in the lanes the device ignores
    d->eval();
    if (!we) {
      int offs[2] = { off & ~1, off | 1 };
      for (int k = 0; k < 2; k++) {
        if (!both && offs[k] != off) continue;
        uint8_t exp = ref.read(offs[k]);
        uint8_t got = (d->rdata >> (16 * k)) & 0xff;
        ++reads;
        if (offs[k] == 1 && ref.ctrlmode && (ref.dir & 2)) {
          ++ee_reads; if (exp & 0x20) ++ee_ones; else ++ee_zeros;
        }
        if (exp != got) {
          if (++bad <= 20)
            std::printf("  MISMATCH cyc %llu off %x: expected %02x got %02x (ee st %d bits %d)\n",
                        (unsigned long long)cyc, offs[k], exp, got, int(ref.ee.st), ref.ee.bits);
        }
      }
    } else ref.write(off, data);
    tick();
    d->sel = 0; d->we = 0;
    d->eval();
    ++pe_checks;   // R892: the PE latch out (Manx TT's motion-base command)
    if (d->pe != ref.pv[4] && ++bad <= 20)
      std::printf("  MISMATCH cyc %llu pe: expected %02x got %02x\n", (unsigned long long)cyc, ref.pv[4], d->pe);
  };
  auto pa = [&](int cs, int clk, int di) {
    uint8_t v = uint8_t(0x01 | (clk << 7) | (cs << 6) | (di << 5) | (rng() & 0x1e));
    access(true, 0, v);
    if (rng() % 3 == 0) access(false, 1, 0);   // read DO via PB
  };
  auto clock_bit = [&](int di) { pa(1, 0, di); pa(1, 1, di); pa(1, 0, di); };

  access(true, 8, 0xfe);   // port A output, the rest input (dir 1 = input)
  uint64_t ops = 0;
  while (ops < n) {
    unsigned r = rng() % 1000;
    if (r < 1) {   // power off and on: the EEPROM keeps its words and locks again
      for (int i = 0; i < 300; i++) tick();   // let a WRITEALL / ERASEALL sweep finish (192 cycles)
      d->por_n = 0; d->rst_n = 0; tick(); tick(); d->por_n = 1; d->rst_n = 1; tick();
      ref.power_on(); ++pors;
      access(true, 8, 0xfe);
      ++ops; continue;
    }
    if (r < 3) {   // a machine reset: direction, mode, ctrlmode; the latches and the EEPROM keep theirs
      d->rst_n = 0; tick(); tick(); d->rst_n = 1; tick();
      ref.reset(); ++resets;
      if (rng() & 1) access(true, 8, 0xfe);
      ++ops; continue;
    }
    r = r / 10;
    if (r < 55) {   // a well-formed EEPROM command
      ++cmds;
      pa(0, 0, 0); pa(1, 0, 0);
      clock_bit(1);   // start bit
      int op = int(rng() % 4), a = int(rng() % 64);
      if (op == 0) a = int((rng() % 4) << 4) | (a & 15);
      if (rng() % 3 == 0) { op = 0; a = 0x30; }   // UNLOCK often, or nothing writes
      int cmd = (op << 6) | a;
      for (int b = 7; b >= 0; b--) clock_bit((cmd >> b) & 1);
      if (op == 1 || (op == 0 && (a >> 4) == 1)) {
        uint16_t w = uint16_t(rng());
        for (int b = 15; b >= 0; b--) clock_bit((w >> b) & 1);
      } else if (op == 2) {
        int nb = 16 * (1 + int(rng() % 3)) + int(rng() % 3);   // streaming, over-clocked
        for (int b = 0; b < nb; b++) clock_bit(int(rng() & 1));
      }
      pa(0, 0, 0);
    } else if (r < 70) {   // noise on port A
      pa(int(rng() & 1), int(rng() & 1), int(rng() & 1));
    } else if (r < 80) {   // the other ports
      access(rng() & 1, int(rng() % 7), uint8_t(rng()));
      if (rng() % 8 == 0) access(true, 8, uint8_t(rng() | 1) & 0xfe);   // keep A an output
    } else if (r < 85) {
      access(false, int(rng() % 16), 0);
    } else if (r < 90) {
      access(true, 0xe + int(rng() & 1), uint8_t(rng()));
    } else {   // inputs move
      ref.in0 = d->in0 = uint8_t(rng()); ref.in1 = d->in1 = uint8_t(rng());
      ref.in2 = d->in2 = uint8_t(rng()); ref.sw = d->sw = uint8_t(rng());
      ref.anv[0] = d->an0 = uint8_t(rng()); ref.anv[1] = d->an1 = uint8_t(rng());
      ref.anv[2] = d->an2 = uint8_t(rng());
      d->eval();
      access(false, (rng() & 1) ? 0xf : int(1 + rng() % 3), 0);
    }
    ++ops;
  }
  std::printf("  %llu operations, %llu EEPROM commands, %llu reads compared (%llu of EEPROM DO: %llu ones, %llu zeros), %llu resets, %llu power-ons, %llu cycles\n",
              (unsigned long long)ops, (unsigned long long)cmds, (unsigned long long)reads,
              (unsigned long long)ee_reads, (unsigned long long)ee_ones, (unsigned long long)ee_zeros, (unsigned long long)resets, (unsigned long long)pors,
              (unsigned long long)cyc);
  std::printf("  %llu PE latch checks (R892)\n", (unsigned long long)pe_checks);
  if (bad) { std::printf("FAIL: %llu mismatches\n", (unsigned long long)bad); return 1; }
  std::printf("PASS\n");
  delete d;
  return 0;
}
