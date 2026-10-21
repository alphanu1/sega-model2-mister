// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA — Copyright (C) 2026 alphanu1
//
// R869: WHICH OF THE FORMS A GAME EXECUTES DOES THIS CORE TRAP ON. Reads the
// MAME form log (R869_OUT from the patched i960.cpp, sim/io/mame_i960_formlog.patch:
// a FIRST line per distinct form -- REG op.op2, MEM op + mode bits, ret by its
// frame type, CTRL / COBR op -- with the first instruction word, PC and time,
// and a COUNT line each at exit) and steps the whole-CPU reference
// (sim/i960/i960_cpu_ref.h, the model the lockstep holds i960_top to, traps
// included) once on each first word, in three builds:
//   2A-old  FR=1, VC=0, F2A=0  (R865's 2A core)
//   2A-new  FR=1, VC=0, F2A=1  (R869)
//   main    VC=1               (Daytona / Desert Tank / Virtua Cop)
// A form is listed TRAP when the reference traps on it there. The reference
// is the transcription of MAME's execute_op for exactly the subset the module
// executes (trap equality is part of every lockstep run, R836), so this is
// the module's answer without a simulation.
//
// R921: and every operand VARIANT (the log's VAR lines: the form with its
// m1 m2 m3 s1 s2 bits, the FP operand fields where an m bit is set -- fp0-fp3
// or which literal -- and the multi-word ops' register alignment, MEM's mode
// and scale), each stepped on its own first word in the same three builds and
// in VF2's (vc_en low on the 2A core: FR / F2A off, as R865 left it). A form
// implemented for one operand kind and trapped on another shows here and not
// in the FIRST table.
//
//   g++ -O1 -std=c++17 -I sim/i960 sim/io/i960_formcheck.cpp -o formcheck
//   formcheck <forms.txt>     prints every form; TRAP lines are what halts
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <map>
#include <string>
#include "i960_cpu_ref.h"

static bool traps(uint32_t key, uint32_t insn, bool fr, bool vc, bool f2a) {
  i960ref::Cpu c;
  c.ref_fr = fr; c.ref_vc = vc; c.ref_f2a = f2a;
  for (int i = 0; i < 32; i++) c.rf.r[i] = 0x3000u + 0x40u * uint32_t(i);
  c.rf.r[i960ref::Regs::FP] = 0x8000u;
  c.rf.r[i960ref::Regs::PFP] = 0x7000u | ((key >> 0) & 7u);   // ret keys carry the frame type
  if ((key & 0xff0u) != 0x0a0u || key >= 0x1000u) c.rf.r[i960ref::Regs::PFP] = 0x7000u;
  c.IP = 0x1000u;
  c.rf.mem[0x1000u] = insn;
  c.rf.mem[0x1004u] = 0x2000u;                 // a displacement word, for the two-word forms
  c.step();
  return c.trapped;
}

int main(int argc, char **argv) {
  if (argc < 2) { std::fprintf(stderr, "formcheck <forms.txt>\n"); return 2; }
  FILE *f = std::fopen(argv[1], "r");
  if (!f) return 2;
  struct E { uint32_t pc = 0, insn = 0; double t = 0; unsigned long long n = 0; };
  std::map<uint32_t, E> keys, vars;
  std::map<uint32_t, uint32_t> var_key;
  char ln[512];
  while (std::fgets(ln, sizeof ln, f)) {
    unsigned k, pc, insn; double t; unsigned long long n;
    if (std::sscanf(ln, "FIRST %x pc %x insn %x t %lf", &k, &pc, &insn, &t) == 4) {
      E &e = keys[k]; e.pc = pc; e.insn = insn; e.t = t;
    } else if (std::sscanf(ln, "COUNT %x pc %x t %lf n %llu", &k, &pc, &t, &n) == 4) {
      keys[k].n = n;
    } else if (unsigned v, vk; std::sscanf(ln, "VAR %x key %x pc %x insn %x t %lf", &v, &vk, &pc, &insn, &t) == 5) {
      E &e = vars[v]; e.pc = pc; e.insn = insn; e.t = t; var_key[v] = vk;
    } else if (std::sscanf(ln, "VCOUNT %x pc %x t %lf n %llu", &k, &pc, &t, &n) == 4) {
      vars[k].n = n;
    }
  }
  std::fclose(f);
  int old_traps = 0, new_traps = 0, main_traps = 0;
  for (auto &kv : keys) {
    const uint32_t k = kv.first; const E &e = kv.second;
    const bool o = traps(k, e.insn, true, false, false);
    const bool nw = traps(k, e.insn, true, false, true);
    const bool m = traps(k, e.insn, false, true, false);
    old_traps += o; new_traps += nw; main_traps += m;
    std::printf("%s %04x insn %08x first pc %08x t %9.4f n %12llu  2A-old %s  2A-new %s  main %s\n",
                (o || nw) ? "TRAP" : "    ", k, e.insn, e.pc, e.t, e.n,
                o ? "TRAP" : "ok  ", nw ? "TRAP" : "ok  ", m ? "TRAP" : "ok  ");
  }
  std::printf("%zu forms: 2A-old traps on %d, 2A-new on %d, main on %d\n", keys.size(), old_traps, new_traps, main_traps);
  // R921: the variants. 2A = FR + F2A with vc_en high (every 2A game past
  // VF2); vf2 = the same core with vc_en low (nothing of FR / VC / F2A live).
  int v2a = 0, vvf2 = 0, vmain = 0;
  for (auto &kv : vars) {
    const uint32_t v = kv.first; const E &e = kv.second; const uint32_t k = var_key[v];
    const bool a = traps(k, e.insn, true, false, true);
    const bool f = traps(k, e.insn, false, false, false);
    const bool m = traps(k, e.insn, false, true, false);
    v2a += a; vvf2 += f; vmain += m;
    std::printf("%s VAR %08x key %04x insn %08x first pc %08x t %9.4f n %12llu  2A %s  vf2 %s  main %s\n",
                a ? "VTRAP" : (f ? "vtrap" : "     "), v, k, e.insn, e.pc, e.t, e.n,
                a ? "TRAP" : "ok  ", f ? "TRAP" : "ok  ", m ? "TRAP" : "ok  ");
  }
  if (!vars.empty())
    std::printf("%zu variants: 2A traps on %d, vf2 (vc_en low) on %d, main on %d\n", vars.size(), v2a, vvf2, vmain);
  return 0;
}
