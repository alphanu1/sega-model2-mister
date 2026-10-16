// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// tb_m2_scsp: the SCSP RTL (m2_scsp) replaying MAME's own 2A sound captures
// (study R856), sample for sample, against scsp_ref.h (MAME 0.289's
// scsp.cpp, ported; bit-exact to MAME) and against MAME's mix itself.
//
// The capture (sim/sound/mame_p16_scsp.sh) logs every 68000 register write
// and sound-RAM write with the sample it lands before. Here, for each sample
// n: the register writes go in over the RTL's 68000 port, the RAM writes
// into the bench's sound RAM (and are snooped), the engine is let run one
// sample (step_mode), and its mix -- and each active slot's sample -- is
// compared. Sound RAM answers the two ports after a latency drawn from
// [LAT_LO, LAT_HI] clocks.
//
//   SCSP_CAP=<dir>  the capture        SCSP_N=<samples> (default 441000)
//   SCSP_FROM=<n>   compare from sample n (default 0)
//   LAT_LO / LAT_HI the memory latency (default 6 / 40)
//   SCSP_SEED       the latency draw's seed
#include "Vm2_scsp.h"
#include "verilated.h"
#include "scsp_ref.h"
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include <deque>

using namespace scspref;

struct Rec { uint32_t n; uint16_t off, data, mask, pad; };
struct RamW { uint32_t n, a, dm; };

static Vm2_scsp *t;
static uint64_t cyc = 0;
static uint16_t ram[0x40000];
static uint32_t rng_s = 1;
static int lat_lo = 6, lat_hi = 40;
static int lat() { rng_s = rng_s * 1103515245u + 12345u; return lat_lo + int((rng_s >> 8) % unsigned(lat_hi - lat_lo + 1)); }

// one port: a request, served after a latency
struct Port { bool busy = false; int wait = 0; bool was = false; };
static Port sm, dm;
static uint64_t sm_reqs = 0, dm_rd = 0, dm_wr = 0;

static uint64_t line_of(uint32_t widx) {
	widx &= ~3u; uint64_t v = 0;
	for (int i = 0; i < 4; i++) v |= uint64_t(ram[(widx + i) & 0x3ffff]) << (16 * i);
	return v;
}

static void tick() {
	t->clk = 0; t->eval();
	// ports, sampled on the falling half so the rising edge sees the answer
	t->sm_ack = 0; t->dm_ack = 0;
	if (t->sm_req && !sm.was && !sm.busy) { sm.busy = true; sm.wait = lat(); sm_reqs++; }
	if (sm.busy && --sm.wait <= 0) { t->sm_ack = 1; t->sm_data = line_of(uint32_t(t->sm_line) << 2); sm.busy = false; }
	sm.was = t->sm_req;
	if (t->dm_req && !dm.was && !dm.busy) { dm.busy = true; dm.wait = lat(); }
	if (dm.busy && --dm.wait <= 0) {
		t->dm_ack = 1; dm.busy = false;
		uint32_t w = t->dm_addr & 0x3ffff;
		if (t->dm_we) { ram[w] = t->dm_wdata; dm_wr++; }
		else { t->dm_data = line_of(w); dm_rd++; }
	}
	dm.was = t->dm_req;
	t->eval();
	t->clk = 1; t->eval();
	cyc++;
}

template <class T> struct Stream {
	FILE *f; T cur; bool ok;
	Stream(const std::string &p) { f = fopen(p.c_str(), "rb"); ok = f && fread(&cur, sizeof(T), 1, f) == 1; }
	void next() { ok = fread(&cur, sizeof(T), 1, f) == 1; }
};

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	const char *cap = getenv("SCSP_CAP");
	if (!cap) { fprintf(stderr, "SCSP_CAP=<capture dir>\n"); return 2; }
	std::string d = cap;
	uint64_t N = getenv("SCSP_N") ? strtoull(getenv("SCSP_N"), nullptr, 0) : 441000;
	uint64_t FROM = getenv("SCSP_FROM") ? strtoull(getenv("SCSP_FROM"), nullptr, 0) : 0;
	if (getenv("LAT_LO")) lat_lo = atoi(getenv("LAT_LO"));
	if (getenv("LAT_HI")) lat_hi = atoi(getenv("LAT_HI"));
	if (getenv("SCSP_SEED")) rng_s = strtoul(getenv("SCSP_SEED"), nullptr, 0);

	static Tables T;
	static uint16_t rram[0x40000];
	memset(ram, 0, sizeof ram); memset(rram, 0, sizeof rram);
	SCSP R(T, rram);
	Stream<Rec> regs(d + "/regs.bin");
	Stream<RamW> rw(d + "/ramw.bin");
	FILE *fo = fopen((d + "/out.bin").c_str(), "rb");
	if (!regs.f || !rw.f || !fo) { fprintf(stderr, "capture incomplete in %s\n", cap); return 2; }

	t = new Vm2_scsp;
	t->rst_n = 0; t->step_mode = 1; t->step_go = 0; t->out_ready = 0; t->tick44 = 0;
	t->cpu_req = 0; t->midi_valid = 0; t->snp = 0;
	for (int i = 0; i < 4; i++) tick();
	t->rst_n = 1;
	for (int i = 0; i < 4; i++) tick();

	uint64_t bad = 0, bad_mame = 0, slot_bad = 0, slot_checks = 0, nz = 0;
	uint64_t eng_cyc = 0, eng_max = 0;
	std::vector<uint64_t> hist(64, 0);
	int64_t first_bad = -1;
	for (uint64_t n = 0; n < N; n++) {
		s32 mo[2];
		if (fread(mo, sizeof mo, 1, fo) != 1) { N = n; break; }
		// the register writes before sample n: the reference, then the RTL's 68000 port
		while (regs.ok && regs.cur.n <= n) {
			R.write(regs.cur.off, regs.cur.data, regs.cur.mask);
			t->cpu_addr = (regs.cur.off >> 1) & 0x7ff;
			t->cpu_din = regs.cur.data; t->cpu_we = 1;
			t->cpu_be = ((regs.cur.mask & 0xff00) ? 2 : 0) | ((regs.cur.mask & 0x00ff) ? 1 : 0);
			t->cpu_req = 1; tick(); t->cpu_req = 0;
			int g = 0; while (!t->cpu_ack) { tick(); if (++g > 100000) { printf("FAIL: write not acked\n"); return 1; } }
			// let the queue drain before the next (the 68000 is never faster than this)
			g = 0; while (!t->quiet) { tick(); if (++g > 2000000) { printf("FAIL: not quiet after a write (n %llu)\n", (unsigned long long)n); return 1; } }
			regs.next();
		}
		while (rw.ok && rw.cur.n <= n) {
			uint32_t a = (rw.cur.a & 0x7fffe) >> 1; uint16_t dv = rw.cur.dm & 0xffff, m = rw.cur.dm >> 16;
			ram[a] = (ram[a] & ~m) | (dv & m);
			rram[a] = (rram[a] & ~m) | (dv & m);
			t->snp = 1; t->snp_addr = a; tick(); t->snp = 0; tick(); tick();
			rw.next();
		}
		int g = 0; while (!t->quiet) { tick(); if (++g > 2000000) { printf("FAIL: not quiet (n %llu)\n", (unsigned long long)n); return 1; } }
		// the reference's sample (and its slots)
		s32 rl, rr; R.sample(rl, rr);
		// the RTL's
		t->step_go = 1; tick(); t->step_go = 0;
		uint64_t c0 = cyc;
		g = 0;
		while (!t->out_valid) {
			if (t->dbg_slot_valid) {
				int sl = t->dbg_slot; slot_checks++;
				if (n >= FROM && (int32_t)t->dbg_slot_smp != R.slot_out[sl]) {
					if (slot_bad < 10) printf("  sample %llu slot %d: rtl %d ref %d\n", (unsigned long long)n, sl, (int32_t)t->dbg_slot_smp, R.slot_out[sl]);
					slot_bad++;
				}
			}
			tick();
			if (++g > 5000000) { printf("FAIL: no sample (n %llu)\n", (unsigned long long)n); return 1; }
		}
		uint64_t ec = cyc - c0;
		eng_cyc += ec; if (ec > eng_max) eng_max = ec;
		hist[std::min<uint64_t>(63, ec / 64)]++;
		int32_t ol = (int32_t)t->out_l_raw, orr = (int32_t)t->out_r_raw;
		t->tick44 = 1; tick(); t->tick44 = 0;
		if (rl || rr) nz++;
		if (n >= FROM && (ol != rl || orr != rr)) {
			if (bad < 10) printf("  sample %llu: rtl %d %d  ref %d %d  MAME %d %d\n", (unsigned long long)n, ol, orr, rl, rr, mo[0], mo[1]);
			if (first_bad < 0) first_bad = (int64_t)n;
			bad++;
		}
		if (n >= FROM && (ol != mo[0] || orr != mo[1])) bad_mame++;
		if ((n % 441000) == 0 && n) { printf("  .. %llu samples, %llu wrong\n", (unsigned long long)n, (unsigned long long)bad); fflush(stdout); }
	}
	printf("tb_m2_scsp %s: %llu samples (%.1f s), %llu non-zero; %llu differ from the reference, %llu from MAME's mix (first %lld)\n",
		cap, (unsigned long long)N, N / 44100.0, (unsigned long long)nz, (unsigned long long)bad, (unsigned long long)bad_mame, (long long)first_bad);
	printf("  slot samples checked %llu, wrong %llu; engine clocks a sample: mean %.0f, max %llu (budget at 80 MHz: 1,814)\n",
		(unsigned long long)slot_checks, (unsigned long long)slot_bad, double(eng_cyc) / std::max<uint64_t>(1, N), (unsigned long long)eng_max);
	printf("  sound RAM: slot line fills %llu (%.2f a sample), DSP reads %llu, writes %llu; latency %d..%d\n",
		(unsigned long long)sm_reqs, sm_reqs / double(std::max<uint64_t>(1, N)), (unsigned long long)dm_rd, (unsigned long long)dm_wr, lat_lo, lat_hi);
	printf("%s\n", (bad || slot_bad) ? "FAIL" : "PASS");
	return (bad || slot_bad) ? 1 : 0;
}
