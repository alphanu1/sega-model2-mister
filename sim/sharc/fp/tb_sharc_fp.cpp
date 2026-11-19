// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- R1027: the 2B SHARC's float units and functions
// against two references.
//
//   MAME:   sharc_fp_mame_ref.h -- MAME's compute.hxx on the host's floats (Hornet's bench).
//   MANUAL: written here from the ADSP-2106x User's Manual's definitions (study R1024), with
//           none of the RTL's structure: the exact result is formed in long double (a float
//           sum with exponents within 40 of each other, every float product and every int32
//           are exact there), rounded to 24 bits by frexpl / truncl / nearbyintl with the
//           exponent unbounded, then judged tiny (below 2^-126: flushed, underflow flags) or
//           overflowed (2^128 or more). Denormal operands are flushed first, in every unit.
//
// Checked: sharc_fadd / sharc_fmul at MAME_RND 1 against MAME and at MAME_RND 0 against the
// manual (TRUNC on and off); the package's f_* against MAME and man_* against the manual.
//
//   tb_sharc_fp [+n=10000000] [+seed=1] [+only=<what>]
#include "Vtb_sharc_fp.h"
#include "verilated.h"
#include "sharc_fp_mame_ref.h"
#include <cfenv>
#include <cstdio>
#include <cstdlib>
#include <random>

double sc_time_stamp() { return 0; }

using namespace mame_fp;

static const uint32_t MAXF = 0x7f7fffff;

// ---------------------------------------------------------------- the manual's rounding

struct MR { uint32_t r; bool tiny, ovf; };

// v exact and nonzero; to 24 bits, toward zero or to nearest even, exponent unbounded
static MR mround(long double v, bool rz) {
    MR o{};
    uint32_t sg = std::signbit(v) ? SIGN : 0;
    int e;
    long double m = frexpl(fabsl(v), &e);              // [0.5, 1) x 2^e
    long double M = ldexpl(m, 24);                      // [2^23, 2^24)
    long double Mi = rz ? truncl(M) : nearbyintl(M);    // FE_TONEAREST: ties to even
    if (Mi >= 16777216.0L) { Mi = 8388608.0L; e++; }
    int be = e - 1 + 127;                               // the value is in [2^(e-1), 2^e)
    o.tiny = be < 1;
    o.ovf = be >= 255;
    if (o.ovf) o.r = sg | INF;
    else if (o.tiny) o.r = sg;
    else o.r = sg | (uint32_t(be) << 23) | (uint32_t(Mi) - 0x800000u);
    return o;
}

static long double LD(uint32_t r) { return (long double)F(r); }
static int uexp(uint32_t r) { return int((r >> 23) & 0xff) - 127; }

// the exact sum of two flushed finite operands (or a stand-in that rounds the same)
static long double xsum(uint32_t a, uint32_t b) {
    if (is_zero(a) || is_zero(b)) return LD(a) + LD(b);
    uint32_t x = a, y = b;
    if ((y & 0x7fffffff) > (x & 0x7fffffff)) std::swap(x, y);
    int d = uexp(x) - uexp(y);
    if (d <= 40) return LD(x) + LD(y);
    // |y| is below 2^-17 of an ulp of x: any smaller amount of the same sign rounds the same
    long double eps = ldexpl(1.0L, uexp(x) - 50);
    return LD(x) + ((y & SIGN) ? -eps : eps);
}

static Res man_fin(MR m, bool trunc) {               // the ALU's finish (MAME's flags)
    Res o; o.r = m.r;
    if (is_inf(o.r)) { o.astat |= AV; o.stky |= AVS; if (trunc) o.r = (o.r & SIGN) | MAXF; }
    else if (is_zero(o.r)) { o.astat |= AZ; if (m.tiny) o.stky |= AUS; }
    if (o.r & SIGN) o.astat |= AN;
    o.astat |= AF;
    return o;
}

static MR man_addr(uint32_t xf, uint32_t yf, bool rz, bool half) {
    MR o{};
    if (is_inf(xf)) { o.r = xf; return o; }
    if (is_inf(yf)) { o.r = yf; return o; }
    if (is_zero(xf) && is_zero(yf)) { o.r = (xf & yf & SIGN); return o; }
    long double v = xsum(xf, yf);
    if (v == 0) { o.r = 0; return o; }                  // exact cancellation: +0
    if (half) v = v / 2;
    return mround(v, rz);
}

static Res man_ref(int op, uint32_t x, uint32_t y, bool trunc, uint32_t astat_in) {
    Res o;
    uint32_t xf = flush(x), yf = flush(y);
    switch (op) {
    case 0: if (nan_add(x, y)) { o = invalid(); o.astat |= AF; return o; } return man_fin(man_addr(xf, yf, trunc, false), trunc);
    case 1: if (nan_sub(x, y)) { o = invalid(); o.astat |= AF; return o; } return man_fin(man_addr(xf, yf ^ SIGN, trunc, false), trunc);
    case 2: if (nan_add(x, y)) { o = invalid(); o.astat |= AF; return o; } return man_fin(man_addr(xf, yf, trunc, true), trunc);
    case 3: {
        Res a = man_ref(0, x, y, trunc, 0), s = man_ref(1, x, y, trunc, 0);
        o.r = a.r; o.r2 = s.r;
        o.astat = (a.astat | s.astat) & ~AN; o.stky = a.stky | s.stky;
        if ((a.r | s.r) & SIGN) o.astat |= AN;
        return o;
    }
    // the exact operations: MAME's, on flushed operands
    case 4: case 7: case 8: case 20: case 21: return ref(op, x, y, trunc, astat_in);
    case 5: case 6: case 9: case 10: case 11: case 18: case 19:
        return ref(op, xf, op == 10 ? y : yf, trunc, astat_in);   // SCALB's y is an integer
    case 12: case 13: case 14: {
        uint32_t a = 0, v = op == 12 ? xf : scalb(xf, y, a);
        if (is_den(v)) v &= SIGN;
        uint32_t r;
        bool bad = (v & INF) == INF || fabsl(LD(v)) >= 2147483648.0L;
        if (!bad) {
            long double t = trunc ? floorl(LD(v)) : nearbyintl(LD(v));
            if (t >= 2147483648.0L || t < -2147483648.0L) r = 0x80000000u; else r = uint32_t(int32_t((long long)t));
        } else r = 0x80000000u;
        if (!bad && LD(v) == -2147483648.0L) r = 0x80000000u;
        o.r = r; o.astat |= (r & SIGN) ? AN : 0; o.astat |= r == 0 ? AZ : 0;
        o.astat |= is_nan(x) ? AI : 0; o.astat |= AF;
        return o;
    }
    case 15: case 16: case 17: {
        uint32_t a = 0;
        int32_t iv = int32_t(x);
        o.r = iv == 0 ? 0 : mround((long double)iv, trunc).r;
        if (op != 15) o.r = scalb(o.r, y, a);
        if (op == 17) o.astat |= (F(o.r) < 0.0f) ? AN : 0; else o.astat |= (o.r & SIGN) ? AN : 0;
        o.astat |= is_dz(o.r) ? AZ : 0; o.stky |= is_den(o.r) ? AUS : 0; o.astat |= AF;
        return o;
    }
    case 22: {
        if (nan_mul(xf, yf)) return invalid(MI, MIS);
        uint32_t sg = (xf ^ yf) & SIGN;
        if (is_inf(xf) || is_inf(yf)) { o.r = sg | INF; o.astat = MV | (sg ? MN : 0); o.stky = MVS; return o; }
        if (is_zero(xf) || is_zero(yf)) { o.r = sg; o.astat = sg ? MN : 0; return o; }
        MR m = mround(LD(xf) * LD(yf), trunc);
        o.r = m.r;
        if (m.ovf) { o.astat |= MV; o.stky |= MVS; if (trunc) o.r = sg | MAXF; }
        if (m.tiny) { o.astat |= MU; o.stky |= MUS; }
        if (o.r & SIGN) o.astat |= MN;
        return o;
    }
    }
    return o;
}

static const char *NAMES[] = {"FADD", "FSUB", "FAVG", "FADD/FSUB", "FABS", "FMIN", "FMAX", "FNEG",
    "FPASS", "FCOMP", "SCALB", "LOGB", "FIX", "FIX BY", "FIX BY (multi)", "FLOAT", "FLOAT BY",
    "FLOAT BY (multi)", "RECIPS", "RSQRTS", "COPYSIGN", "FCLIP", "FMUL"};
static const int NOPS = 23;

// operands biased toward the edges, an order of magnitude past where the rounding matters:
// zeros, denormals, infinities, NaNs, cancellation, products near 2^-126 and 2^128, halfway
// cases for the rounding, exponent differences 0-60 for the adder, integers for FLOAT
static uint32_t pick(std::mt19937 &g, uint32_t other) {
    uint32_t r = g();
    switch (g() % 22) {
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
    // the product's exponent near the bottom (tiny / not tiny) and the top (overflow)
    case 10: { int eo = (other >> 23) & 0xff; int e = 127 - eo + 1 + int(g() % 9) - 4; e = std::clamp(e, 1, 254);
               return (r & 0x807fffff) | (uint32_t(e) << 23); }
    case 11: { int eo = (other >> 23) & 0xff; int e = 254 + 127 - eo + int(g() % 5) - 2; e = std::clamp(e, 1, 254);
               return (r & 0x807fffff) | (uint32_t(e) << 23); }
    // few mantissa bits: products and sums land on halfway cases
    case 12: return (r & 0xff800000) | ((g() & 0xfff) << 11);
    case 13: return (r & 0xff800000) | ((g() & 0x3) << 21) | 0x1000;
    // the adder: exponent difference 0-60 from the other operand, either sign
    case 14: { int eo = (other >> 23) & 0xff; int e = eo - int(g() % 61); if (e < 1) e = 1;
               return (r & 0x807fffff) | (uint32_t(e) << 23); }
    case 15: return (other & 0xff800000) ^ (r & SIGN) | (r & 0x7fffff);
    // R1028: exactly 2^-126 / 2^-125 (FAVG's tiny edge, a mantissa with no bits)
    case 16: return (r & SIGN) | (uint32_t(1 + ((r >> 1) & 1)) << 23);
    // R1052: a product just under a power of two (mantissas' product just under 2^47), so its top
    // 24 bits are all ones and rounding to nearest carries out of them; the exponent near the
    // other's complement so the result lands anywhere from tiny to overflow
    case 17: { uint64_t mo = (other & 0x7fffff) | 0x800000;
               uint64_t m = ((1ull << 47) - 1) / mo - (g() % 3);
               if (m >= (1u << 24)) m = (1u << 24) - 1;
               if (m < (1u << 23)) m = 1u << 23;
               int eo = (other >> 23) & 0xff; int e = 254 - eo + int(g() % 260) - 130; e = std::clamp(e, 1, 254);
               return (r & SIGN) | (uint32_t(e) << 23) | uint32_t(m & 0x7fffff); }
    // R1052: a mantissa of all ones (or nearly), the exponent up to 30 below the other's: sums
    // whose rounding carries out of the 24 bits
    case 18: { int eo = (other >> 23) & 0xff; int e = other ? eo - int(g() % 30) : 1 + int(g() % 254);
               e = std::clamp(e, 1, 254);
               return (r & SIGN) | (uint32_t(e) << 23) | (0x7fffffu ^ (g() & 3)); }
    default: return r;
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    fesetround(FE_TONEAREST);
    const char *s;
    long n = (s = Verilated::commandArgsPlusMatch("n=")) && *s ? atol(s + 3) : 10000000;
    unsigned seed = (s = Verilated::commandArgsPlusMatch("seed=")) && *s ? atoi(s + 6) : 1;
    std::mt19937 g(seed);
    Vtb_sharc_fp *t = new Vtb_sharc_fp;
    long pm_bad[NOPS] = {0}, pn_bad[NOPS] = {0}, runs[NOPS] = {0};
    long u_bad[4] = {0}, u_runs = 0, stalls = 0, tiny_seen = 0, ovf_seen = 0, rz_diff = 0, carry_seen = 0, acarry_seen = 0;
    const char *UN[4] = {"fadd MAME", "fadd manual", "fmul MAME", "fmul manual"};
    t->clk = 0; t->en = 1; t->eval();
    for (long i = 0; i < n; i++) {
        int op = i % NOPS;
        uint32_t x = pick(g, 0), y = pick(g, x), a = g();
        bool trunc = (g() & 3) != 0;          // TRUNC is what every Sega program sets
        bool sub = g() & 1;
        bool avg = (g() & 3) == 0;            // R1028: FAVG on the adder unit
        t->op = op; t->x = x; t->y = y; t->trunc = trunc; t->astat_in = a; t->sub = sub; t->avg = avg;
        // the units: register stage 1 (held while MAME's multiplier is on its slow path); twice,
        // the operands held (R1029: the adder's stage 2a is a second advance; the multiplier's
        // stage 1 loads the same product again)
        for (int adv = 0; adv < 2; adv++)
            for (;;) {
                t->clk = 0; t->eval();
                t->en = !t->busy;
                if (t->busy) stalls++;
                t->clk = 1; t->eval();
                if (t->en) break;
            }
        t->clk = 0; t->eval();
        // package (combinational on the same inputs)
        Res em = ref(op, x, y, trunc, a), en = man_ref(op, x, y, trunc, a);
        bool two = op == 3;
        runs[op]++;
        bool bm = t->pm_r != em.r || t->pm_a != em.astat || t->pm_s != em.stky || (two && t->pm_r2 != em.r2);
        bool bn = t->pn_r != en.r || t->pn_a != en.astat || t->pn_s != en.stky || (two && t->pn_r2 != en.r2);
        if (bm && pm_bad[op]++ < 5)
            printf("pkg MAME   %-16s x=%08X y=%08X trunc=%d: RTL %08X %08X a=%08X s=%08X ref %08X %08X a=%08X s=%08X\n",
                   NAMES[op], x, y, trunc, t->pm_r, t->pm_r2, t->pm_a, t->pm_s, em.r, em.r2, em.astat, em.stky);
        if (bn && pn_bad[op]++ < 5)
            printf("pkg manual %-16s x=%08X y=%08X trunc=%d: RTL %08X %08X a=%08X s=%08X ref %08X %08X a=%08X s=%08X\n",
                   NAMES[op], x, y, trunc, t->pn_r, t->pn_r2, t->pn_a, t->pn_s, en.r, en.r2, en.astat, en.stky);
        // units: FADD / FSUB and FMUL on every vector
        int aop = avg ? 2 : sub ? 1 : 0;
        Res wa_m = ref(aop, x, y, trunc, 0), wa_n = man_ref(aop, x, y, trunc, 0);
        Res wm_m = ref(22, x, y, trunc, 0), wm_n = man_ref(22, x, y, trunc, 0);
        u_runs++;
        if ((wm_n.stky & MUS) && !(wm_n.r & 0x7fffffff)) tiny_seen++;
        if (wm_n.stky & MVS) ovf_seen++;
        if (!trunc && !(wm_n.stky & (MVS | MUS)) && !is_nan(wm_n.r) && (wm_n.r & 0x7fffff) == 0 && (wm_n.r & INF) &&
            fabsl(LD(flush(x)) * LD(flush(y))) < fabsl(LD(wm_n.r))) carry_seen++;
        if (wa_n.r != wa_m.r) rz_diff++;
        if (aop == 0 && !trunc && !(wa_n.stky & (AVS | AUS)) && !is_nan(wa_n.r) && (wa_n.r & 0x7fffff) == 0 && (wa_n.r & INF) &&
            fabsl(LD(flush(x)) + LD(flush(y))) < fabsl(LD(wa_n.r))) acarry_seen++;
        struct { uint32_t r, a, s; Res w; } u[4] = {
            {t->am_r, t->am_a, t->am_s, wa_m}, {t->an_r, t->an_a, t->an_s, wa_n},
            {t->mm_r, t->mm_a, t->mm_s, wm_m}, {t->mn_r, t->mn_a, t->mn_s, wm_n}};
        for (int k = 0; k < 4; k++)
            if ((u[k].r != u[k].w.r || u[k].a != u[k].w.astat || u[k].s != u[k].w.stky) && u_bad[k]++ < 5)
                printf("%-11s x=%08X y=%08X sub=%d avg=%d trunc=%d: RTL %08X a=%08X s=%08X ref %08X a=%08X s=%08X\n",
                       UN[k], x, y, sub, avg, trunc, u[k].r, u[k].a, u[k].s, u[k].w.r, u[k].w.astat, u[k].w.stky);
    }
    long total = 0;
    printf("%-16s %9s %12s %12s\n", "package op", "vectors", "MAME bad", "manual bad");
    for (int op = 0; op < NOPS; op++) {
        printf("%-16s %9ld %12ld %12ld\n", NAMES[op], runs[op], pm_bad[op], pn_bad[op]);
        total += pm_bad[op] + pn_bad[op];
    }
    for (int k = 0; k < 4; k++) { printf("unit %-11s %9ld vectors, %ld mismatches\n", UN[k], u_runs, u_bad[k]); total += u_bad[k]; }
    printf("MAME fmul slow-path clocks %ld; manual products flushed tiny %ld, overflowed %ld; "
           "add/sub results where the manual differs from MAME %ld; manual products rounded up to a power of two %ld, sums %ld\n",
           stalls, tiny_seen, ovf_seen, rz_diff, carry_seen, acarry_seen);
    printf(total ? "FAIL: %ld mismatches\n" : "PASS\n", total);
    delete t;
    return total ? 1 : 0;
}
