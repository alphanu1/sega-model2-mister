// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- R1028: random vectors through m2b_sharc_xu and the
// package functions it replaces (tb_m2b_xu.sv), both roundings. Operands biased past the edges:
// shift counts and field positions / lengths 0-63 and beyond in both forms, every fixed op on
// 0 / 1 / -1 / 0x80000000 / 0x7fffffff and their neighbours, the carry in and out, saturation;
// floats as sim/sharc/fp's pick (zeros, denormals, infinities, NaNs, halfway cases), integers for
// FLOAT, scale factors around the exponent's limits and around 2^31 (MAME's int wraps).
//   tb_m2b_xu [+n=10000000] [+seed=1]
#include "Vtb_m2b_xu.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <random>
#include <algorithm>

double sc_time_stamp() { return 0; }

static const uint32_t SIGN = 0x80000000u, INF = 0x7f800000u;
static const int FIXED[] = {0x01, 0x05, 0x25, 0x29, 0x02, 0x06, 0x26, 0x2a, 0x0a, 0x21, 0x22, 0x30,
                            0x40, 0x41, 0x42, 0x43, 0x61, 0x62, 0x63};
static const int SHIFT[] = {0x00, 0x08, 0x01, 0x02, 0x10, 0x11, 0x12, 0x13, 0x19, 0x30, 0x31, 0x32, 0x33};
static const int MISC[] = {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21};
static const char *MN[] = {"", "", "", "", "FABS", "FMIN", "FMAX", "FNEG", "FPASS", "FCOMP", "SCALB", "LOGB",
    "FIX", "FIX BY", "FIX BY (multi)", "FLOAT", "FLOAT BY", "FLOAT BY (multi)", "RECIPS", "RSQRTS", "COPYSIGN", "FCLIP"};

static uint32_t fpick(std::mt19937 &g, uint32_t other) {
    uint32_t r = g();
    switch (g() % 20) {
    case 0: return r & SIGN;
    case 1: return (r & SIGN) | (r & 0x7fffff);
    case 2: return (r & SIGN) | INF;
    case 3: return (r & SIGN) | INF | ((r >> 1) & 0x7fffff) | 1;
    case 4: return other ^ (r & 0xf) ^ (r & SIGN);
    case 5: return (r & 0x807fffff) | (((127 + int(r % 60) - 30) & 0xff) << 23);
    case 6: return (r & 0x807fffff) | 0x00800000;
    case 7: return (r & 0x807fffff) | 0x7f000000;
    case 8: return int32_t(r) >> (r & 31);
    case 9: return uint32_t(int32_t(r % 64) - 32);
    case 10: return (r & 0x807fffff) | ((uint32_t(110 + g() % 56) & 0xff) << 23);     // FIX: 2^-17 .. 2^38
    case 11: return (r & 0xff800000) | ((g() & 0xfff) << 11);                          // ties
    case 12: return (other & 0xff800000) ^ (r & SIGN) | (r & 0x7fffff);                // same exponent
    case 13: return (r & 0x80000000) | (r & 0x7fffff) | (uint32_t(g() % 3 == 0 ? 252 + g() % 4 : 1 + g() % 3) << 23);
    default: return r;
    }
}
static uint32_t ipick(std::mt19937 &g) {
    uint32_t r = g();
    switch (g() % 12) {
    case 0: return 0;
    case 1: return 1;
    case 2: return 0xffffffffu;
    case 3: return 0x80000000u;
    case 4: return 0x7fffffffu;
    case 5: return 0x80000000u + (g() % 5) - 2;
    case 6: return 0x7fffffffu + (g() % 5) - 2;
    case 7: return uint32_t(int32_t(g() % 512) - 256);
    case 8: return int32_t(r) >> (g() & 31);
    case 9: return 1u << (g() & 31);
    default: return r;
    }
}
// a scale factor (SCALB, FIX BY, FLOAT BY): around the exponent's limits and MAME's int wrap
static uint32_t spick(std::mt19937 &g) {
    switch (g() % 6) {
    case 0: return uint32_t(int32_t(g() % 600) - 300);
    case 1: return uint32_t(int32_t(g() % 64) - 32);
    case 2: return 0x80000000u + (g() % 300);
    case 3: return 0x7fffffffu - (g() % 300);
    case 4: return ipick(g);
    default: return g();
    }
}
// a shift operand (the register form: 32 bits; the immediate: the instruction's 12)
static uint32_t shpick(std::mt19937 &g, bool imm) {
    uint32_t v;
    switch (g() % 6) {
    case 0: v = uint32_t(int32_t(g() % 160) - 80); break;            // counts -80..79
    case 1: v = (g() % 64) | ((g() % 64) << 6); break;               // bitn, len 0-63
    case 2: v = (g() % 40) | ((g() % 40) << 6); break;
    case 3: v = g() % 70; break;                                     // a bit number, past 32
    case 4: v = ipick(g); break;
    default: v = g(); break;
    }
    return imm ? (v & 0xfff) : v;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *s;
    long n = (s = Verilated::commandArgsPlusMatch("n=")) && *s ? atol(s + 3) : 10000000;
    unsigned seed = (s = Verilated::commandArgsPlusMatch("seed=")) && *s ? atoi(s + 6) : 1;
    std::mt19937 g(seed);
    Vtb_m2b_xu *t = new Vtb_m2b_xu;
    long runs[3][256] = {{0}}, bad1[3][256] = {{0}}, bad0[3][256] = {{0}}, shown = 0;
    for (long i = 0; i < n; i++) {
        int cls = i % 3;
        t->cls = cls;
        t->fix_op = FIXED[g() % 19];
        t->sh_op = SHIFT[g() % 13];
        t->sh_imm = g() & 1;
        t->sh_val = shpick(g, t->sh_imm);
        t->misc_op = MISC[g() % 18];
        t->x = ipick(g); t->y = (g() % 4 == 0) ? t->x + (g() % 3) - 1 : ipick(g); t->n = ipick(g);
        t->fx = fpick(g, 0); t->fy = fpick(g, t->fx);
        if (cls == 2 && (t->misc_op >= 15 && t->misc_op <= 17) && (g() & 1)) t->fx = ipick(g);
        if (cls == 2 && (t->misc_op == 10 || t->misc_op == 13 || t->misc_op == 14 || t->misc_op == 16 || t->misc_op == 17))
            t->fy = spick(g);
        t->astat = g(); t->alusat = g() & 1; t->trunc = (g() & 3) != 0;
        t->eval();
        // R1029: the result after the clocks the core gives it, the inputs held (the stage
        // registers hold the last vector's values until then)
        { int nk = cls == 2 ? t->misc_x : cls == 1 ? t->sh_x : 0;
          for (int k = 0; k < nk; k++) { t->clk = 1; t->eval(); t->clk = 0; t->eval(); } }
        int op = cls == 0 ? t->fix_op : cls == 1 ? t->sh_op : t->misc_op;
        runs[cls][op]++;
        // a result the core does not write is not compared
        bool b1 = t->u1_we != t->e1_we || t->u1_a != t->e1_a || t->u1_s != t->e1_s || (t->e1_we && t->u1_r != t->e1_r);
        bool b0 = t->u0_we != t->e0_we || t->u0_a != t->e0_a || t->u0_s != t->e0_s || (t->e0_we && t->u0_r != t->e0_r);
        if (b1) bad1[cls][op]++;
        if (b0) bad0[cls][op]++;
        if ((b1 || b0) && shown++ < 20)
            printf("%s cls %d op %02x imm %d sval %08x x %08x y %08x n %08x fx %08x fy %08x astat %08x sat %d trunc %d:\n"
                   "   MAME   unit r %08x we %d a %08x s %08x  ref r %08x we %d a %08x s %08x\n"
                   "   manual unit r %08x we %d a %08x s %08x  ref r %08x we %d a %08x s %08x\n",
                   b1 ? (b0 ? "BOTH" : "MAME") : "MANUAL", cls, op, t->sh_imm, t->sh_val, t->x, t->y, t->n, t->fx, t->fy,
                   t->astat, t->alusat, t->trunc,
                   t->u1_r, t->u1_we, t->u1_a, t->u1_s, t->e1_r, t->e1_we, t->e1_a, t->e1_s,
                   t->u0_r, t->u0_we, t->u0_a, t->u0_s, t->e0_r, t->e0_we, t->e0_a, t->e0_s);
    }
    long total = 0, nv = 0;
    const char *CN[3] = {"fixed", "shift", "misc"};
    for (int c = 0; c < 3; c++)
        for (int op = 0; op < 256; op++)
            if (runs[c][op]) {
                nv += runs[c][op];
                printf("%-5s %02x %-17s %9ld vectors, MAME %ld bad, manual %ld bad\n", CN[c], op, c == 2 ? MN[op] : "",
                       runs[c][op], bad1[c][op], bad0[c][op]);
                total += bad1[c][op] + bad0[c][op];
            }
    printf("%ld vectors, %ld mismatches\n%s\n", nv, total, total ? "FAIL" : "PASS");
    delete t;
    return total ? 1 : 0;
}
