// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// tb_m2_scsp_dsp: the SCSP's DSP (m2_scsp_dsp) alone, on a game's own
// program and data (study R856). The whole reference SCSP (scsp_ref.h,
// MAME's scsp.cpp ported, bit-exact to MAME) replays a p16 capture; each
// sample its DSP sends go into the RTL's MIXS, the 68000's writes to COEF /
// MADRS / MPRO and RBL / RBP go to the RTL as they did to MAME, sound RAM is
// shared, and after the RTL's run its 16 EFREGs and every sound-RAM word it
// wrote are compared with the reference's.
//
//   SCSP_CAP=<dir>  SCSP_N=<samples>  LAT_LO / LAT_HI  SCSP_SEED
//   DSP_RANDOM=<n>  instead: n random programs, 2,000 samples each, on
//                   random sends and a random ring (the fields no game uses)
#include "Vm2_scsp_dsp.h"
#include "verilated.h"
#include "scsp_ref.h"
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

using namespace scspref;

struct Rec { uint32_t n; uint16_t off, data, mask, pad; };
struct RamW { uint32_t n, a, dm; };

static Vm2_scsp_dsp *t;
static uint16_t ram[0x40000];
static uint32_t rng_s = 1;
static int lat_lo = 6, lat_hi = 40;
static uint32_t rnd() { rng_s = rng_s * 1103515245u + 12345u; return rng_s >> 8; }
static int lat() { return lat_lo + int(rnd() % unsigned(lat_hi - lat_lo + 1)); }
static bool busy_p = false, was = false; static int wait_p = 0;
static std::vector<uint32_t> written;

static void tick() {
	t->clk = 0; t->eval();
	t->m_ack = 0;
	if (t->m_req && !was && !busy_p) { busy_p = true; wait_p = lat(); }
	if (busy_p && --wait_p <= 0) {
		t->m_ack = 1; busy_p = false;
		uint32_t w = t->m_addr & 0x3ffff;
		if (t->m_we) { ram[w] = t->m_wdata; written.push_back(w); }
		else { uint64_t v = 0; uint32_t b = w & ~3u; for (int i = 0; i < 4; i++) v |= uint64_t(ram[b + i]) << (16 * i); t->m_data = v; }
	}
	was = t->m_req;
	t->eval();
	t->clk = 1; t->eval();
}

template <class T> struct Stream {
	FILE *f; T cur; bool ok;
	Stream(const std::string &p) { f = fopen(p.c_str(), "rb"); ok = f && fread(&cur, sizeof(T), 1, f) == 1; }
	void next() { ok = fread(&cur, sizeof(T), 1, f) == 1; }
};

static uint16_t c402 = 0;
static void cpu_write(uint16_t off, uint16_t data, uint16_t mask) {
	if (off == 0x402) { c402 = (c402 & ~mask) | (data & mask); t->rbl = (c402 >> 7) & 3; t->rbp = c402 & 0x3f; }
	if (off >= 0x700 && off < 0xc00) {
		int g = 0; while (t->busy) { tick(); if (++g > 100000) { printf("FAIL: busy\n"); exit(1); } }
		t->w_en = 1; t->w_addr = (off >> 1) & 0x7ff; t->w_data = data;
		t->w_be = ((mask & 0xff00) ? 2 : 0) | ((mask & 0xff) ? 1 : 0);
		tick(); t->w_en = 0; tick();
		g = 0; while (t->busy) { tick(); if (++g > 100000) { printf("FAIL: busy after a write\n"); exit(1); } }
	}
}

// one sample: the sends, the run, the compare
static uint64_t bad_ef = 0, bad_ram = 0, runs = 0;
static bool run_one(SCSP &R, uint64_t n, uint16_t *rram) {
	for (int i = 0; i < 16; i++) {
		if (!R.mix_add[i]) continue;
		t->mix_sel = i; tick();
		t->mix_we = 1; t->mix_val = uint32_t(R.mix_add[i]) & 0xfffff; tick(); t->mix_we = 0;
	}
	written.clear();
	t->go = 1; tick(); t->go = 0;
	int g = 0; while (!t->done) { tick(); if (++g > 200000) { printf("FAIL: no done (n %llu)\n", (unsigned long long)n); exit(1); } }
	runs++;
	// writes still in flight land before the compare
	for (int i = 0; i < 3 * lat_hi + 40; i++) tick();   // a read and the write behind it may still be in flight
	// (R946 WPOST: up to eight queued writes go on after done -- until the port is quiet)
	for (int idle = 0, i = 0; idle < 3; i++) { tick(); idle = (!t->m_req && !busy_p) ? idle + 1 : 0; if (i > 20 * lat_hi + 400) { printf("FAIL: port never quiet (n %llu)\n", (unsigned long long)n); exit(1); } }
	bool ok = true;
	for (int i = 0; i < 16; i++) {
		t->ef_idx = i; tick(); tick();
		if ((int16_t)t->ef_q != R.D.EFREG[i]) {
			if (bad_ef < 10) printf("  sample %llu EFREG[%d]: rtl %d ref %d\n", (unsigned long long)n, i, (int16_t)t->ef_q, R.D.EFREG[i]);
			bad_ef++; ok = false;
		}
	}
	for (uint32_t w : written) if (ram[w] != rram[w]) {
		if (bad_ram < 10) printf("  sample %llu RAM[%05x]: rtl %04x ref %04x\n", (unsigned long long)n, w * 2, ram[w], rram[w]);
		bad_ram++; ok = false;
	}
	return ok;
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	if (getenv("LAT_LO")) lat_lo = atoi(getenv("LAT_LO"));
	if (getenv("LAT_HI")) lat_hi = atoi(getenv("LAT_HI"));
	if (getenv("SCSP_SEED")) rng_s = strtoul(getenv("SCSP_SEED"), nullptr, 0);
	static Tables T;
	static uint16_t rram[0x40000];
	t = new Vm2_scsp_dsp;
	t->rst_n = 0; t->go = 0; t->mix_we = 0; t->w_en = 0; t->snp = 0; t->rbl = 0; t->rbp = 0;
	t->mix_idle = 1;   // R946 (OVERLAP builds): no slots here, a merge may run at once
	tick(); tick(); t->rst_n = 1; tick();

	if (getenv("DSP_RANDOM")) {
		// random programs: every field at random, memory on any step (MAME keeps odd only)
		int progs = atoi(getenv("DSP_RANDOM"));
		// one random ring for all programs (the RTL caches it); one reference, as
		// the RTL keeps TEMP / MEMS / DEC across programs
		for (int i = 0; i < 0x40000; i++) ram[i] = rram[i] = rnd() & 0xffff;
		static SCSP R(T, rram);
		for (int p = 0; p < progs; p++) {
			// RBL / RBP
			uint16_t v402 = ((rnd() & 3) << 7) | (rnd() & 0x3f);
			R.write(0x402, v402, 0xffff); cpu_write(0x402, v402, 0xffff);
			int steps = 1 + rnd() % 128;
			for (int k = 0; k < 64; k++) { uint16_t v = rnd(); R.write(0x700 + 2 * k, v, 0xffff); cpu_write(0x700 + 2 * k, v, 0xffff); }
			for (int k = 0; k < 32; k++) { uint16_t v = rnd(); R.write(0x780 + 2 * k, v, 0xffff); cpu_write(0x780 + 2 * k, v, 0xffff); }
			for (int k = 0; k < 128 * 4; k++) {
				uint16_t v = 0;
				if (k / 4 < steps) {
					v = rnd();
					if ((k & 3) == 1) { int ira = rnd() % 50; v = (v & ~(0x3f << 6)) | (ira << 6); }   // IRA stays <= 0x31 mostly
					if ((k & 3) == 1 && (rnd() % 64) == 0) v |= (0x3f << 6);                         // and sometimes aborts
				}
				if (getenv("DSP_KEEP")) {   // only the fields named stay random (word:mask pairs, hex)
					uint16_t keep = 0; const char *q = getenv("DSP_KEEP");
					while (*q) { int w = int(strtol(q, (char **)&q, 16)); if (*q == ':') q++; uint16_t m = uint16_t(strtol(q, (char **)&q, 16)); if (*q == ',') q++; if (w == (k & 3)) keep |= m; }
					v &= keep;
				}
				if (0x800 + 2 * k == 0xBF0) continue;
				R.write(0x800 + 2 * k, v, 0xffff); cpu_write(0x800 + 2 * k, v, 0xffff);
			}
			uint16_t vbf0 = R.D.MPRO[0x1F8];
			R.write(0xBF0, vbf0, 0xffff); cpu_write(0xBF0, vbf0, 0xffff);
			for (int s = 0; s < 2000; s++) {
				bool dbg = getenv("DSP_DBG") && atoi(getenv("DSP_DBG")) == p * 10000 + s;
				R.dbg_dsp = dbg; t->dbg_on = dbg;
				for (int i = 0; i < 16; i++) R.mix_add[i] = 0;
				for (int i = 0; i < 16; i++) if (rnd() & 1) { s32 v = s32(rnd() << 8) >> 12; R.mix_add[i] = v; R.D.MIXS[i] += v; }
				R.DSP_Step();
				run_one(R, uint64_t(p) * 10000 + s, rram);
			}
			if (p % 50 == 49) { printf("  .. %d programs, %llu EFREG wrong, %llu RAM words wrong\n", p + 1, (unsigned long long)bad_ef, (unsigned long long)bad_ram); fflush(stdout); }
		}
	} else {
		const char *cap = getenv("SCSP_CAP");
		if (!cap) { fprintf(stderr, "SCSP_CAP=<capture dir> or DSP_RANDOM=<n>\n"); return 2; }
		std::string d = cap;
		uint64_t N = getenv("SCSP_N") ? strtoull(getenv("SCSP_N"), nullptr, 0) : 441000;
		memset(ram, 0, sizeof ram); memset(rram, 0, sizeof rram);
		SCSP R(T, rram);
		Stream<Rec> regs(d + "/regs.bin");
		Stream<RamW> rw(d + "/ramw.bin");
		for (uint64_t n = 0; n < N; n++) {
			while (regs.ok && regs.cur.n <= n) { R.write(regs.cur.off, regs.cur.data, regs.cur.mask); cpu_write(regs.cur.off, regs.cur.data, regs.cur.mask); regs.next(); }
			while (rw.ok && rw.cur.n <= n) {
				uint32_t a = (rw.cur.a & 0x7fffe) >> 1; uint16_t dv = rw.cur.dm & 0xffff, m = rw.cur.dm >> 16;
				ram[a] = (ram[a] & ~m) | (dv & m); rram[a] = (rram[a] & ~m) | (dv & m);
				t->snp = 1; t->snp_addr = a; tick(); t->snp = 0; tick(); tick();
				rw.next();
			}
			s32 l, r; R.sample(l, r);
			if (!R.D.Stopped || true) run_one(R, n, rram);
			if (n % 441000 == 0 && n) { printf("  .. %llu samples\n", (unsigned long long)n); fflush(stdout); }
			if (bad_ef > 100) break;
		}
	}
	printf("m2_scsp_dsp: %llu runs, %llu EFREG values wrong, %llu RAM words wrong; reference DSP reads/writes %s\n",
		(unsigned long long)runs, (unsigned long long)bad_ef, (unsigned long long)bad_ram, "");
	printf("%s\n", (bad_ef || bad_ram) ? "FAIL" : "PASS");
	return (bad_ef || bad_ram) ? 1 : 0;
}
