// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
// i960 audit against Intel's manuals (docs/i960-intel-audit.md).
// Directed timing harness for i960_top: flat memory, fixed read/write latency.
// Prints one line per accepted instruction: tick ip
#include "Vi960_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unordered_map>
#include <cstdint>
static std::unordered_map<uint32_t,uint32_t> mem;
int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  int rlat = 0, wlat = 0, ilat = -1; long maxt = 20000; long from = 0; long irqat = -1;
  const char* prog = nullptr;
  for (int i = 1; i < argc; i++) {
    if (!strncmp(argv[i], "+rlat=", 6)) rlat = atoi(argv[i]+6);
    else if (!strncmp(argv[i], "+wlat=", 6)) wlat = atoi(argv[i]+6);
    else if (!strncmp(argv[i], "+ilat=", 6)) ilat = atoi(argv[i]+6);
    else if (!strncmp(argv[i], "+max=", 5)) maxt = atol(argv[i]+5);
    else if (!strncmp(argv[i], "+from=", 6)) from = atol(argv[i]+6);
    else if (!strncmp(argv[i], "+prog=", 6)) prog = argv[i]+6;
    else if (!strncmp(argv[i], "+irqat=", 7)) irqat = atol(argv[i]+7);
  }
  if (ilat < 0) ilat = rlat;
  FILE* f = fopen(prog, "r"); if (!f) { perror("prog"); return 1; }
  unsigned a, w; while (fscanf(f, "%x %x", &a, &w) == 2) mem[a & ~3u] = w; fclose(f);
  Vi960_top* d = new Vi960_top;
  d->vc_en = 1; d->irq = 0; d->rst_n = 0; d->bus_ack = 0; d->clk = 0; d->eval();
  for (int i = 0; i < 4; i++) { d->clk = 1; d->eval(); d->clk = 0; d->eval(); }
  d->rst_n = 1;
  uint32_t last_acc = d->dbg_acc_cnt; int wait = -1; uint64_t nbus = 0, nbusw = 0;
  for (long t = 0; t < maxt; t++) {
    // bus model: ack after N cycles of a held request
    bool ack = false;
    if (d->bus_req) {
      if (wait < 0) wait = d->bus_we ? wlat : (d->bus_ifetch ? ilat : rlat);
      if (wait == 0) { ack = true; wait = -1; } else wait--;
    } else wait = -1;
    if (ack) {
      uint32_t ad = d->bus_addr & ~3u;
      auto it = mem.find(ad); uint32_t cur = it == mem.end() ? 0xffffffffu : it->second;
      if (d->bus_we) { uint32_t x = cur; for (int l = 0; l < 4; l++) if (d->bus_be & (1<<l)) x = (x & ~(0xffu<<(8*l))) | (d->bus_wdata & (0xffu<<(8*l))); mem[ad] = x; nbusw++; }
      else d->bus_rdata = cur;
      nbus++;
    }
    d->bus_ack = ack;
    if (irqat >= 0 && t == irqat) d->irq = 8;
    if (irqat >= 0 && t == irqat) printf("IRQ %ld\n", t);
    if (d->bus_req && ack && irqat >= 0 && t >= irqat && t < irqat + 400) printf("B %ld %s %08x\n", t, d->bus_we ? "W" : "R", d->bus_addr);
    d->clk = 1; d->eval();
    if (d->dbg_acc_cnt != last_acc) { last_acc = d->dbg_acc_cnt; if (t >= from) printf("A %ld %08x\n", t, d->dbg_ip); }
    if (d->trap) { printf("TRAP op=%02x ip=%08x t=%ld\n", d->trap_op, d->dbg_ip, t); break; }
    d->clk = 0; d->eval();
  }
  printf("BUS %llu %llu\n", (unsigned long long)nbus, (unsigned long long)nbusw);
  delete d; return 0;
}
