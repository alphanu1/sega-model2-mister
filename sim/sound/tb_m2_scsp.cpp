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
//
// A record with pad = 1 is a read (scsp_randcap's): the RTL's answer is
// checked against the reference's r16. Bytes the RTL sends on MIDI out are
// checked against the low bytes of the reference's 0x406 after each write.
// The noise LFO is MAME's (scsp_lfonoise.hex, beside the binary).
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
static std::deque<int> mout_got;
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
	t->mout_ack = t->mout_valid;
	if (t->mout_valid) mout_got.push_back(t->mout_data);
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
	if (FILE *h = fopen("scsp_lfonoise.hex", "r")) {
		static int an[256], pn[256];
		for (int i = 0; i < 256; i++) { unsigned v = 0; if (fscanf(h, "%x", &v) != 1) break; an[i] = int(v); pn[i] = 128 - int(v); }
		fclose(h);
		T.load_noise(an, pn);
	}
	static uint16_t rram[0x40000];
	memset(ram, 0, sizeof ram); memset(rram, 0, sizeof rram);
	SCSP R(T, rram);
	Stream<Rec> regs(d + "/regs.bin");
	Stream<RamW> rw(d + "/ramw.bin");
	// MAME's interrupt lines (irq.txt: n, line, state), for the RTL's IPL
	FILE *fi = fopen((d + "/irq.txt").c_str(), "r");
	unsigned long long irq_n = 0; unsigned irq_l = 0, irq_v = 0; bool irq_ok = fi && fscanf(fi, "%llu %u %u", &irq_n, &irq_l, &irq_v) == 3;
	unsigned mame_lines = 0;
	uint64_t ipl_checks = 0, ipl_bad = 0, ipl_mame = 0, rd_mame = 0;
	// the 68000's reads (reads.bin) and MIDI in (midi.txt: "n in xx")
	Stream<Rec> rds(d + "/reads.bin");
	FILE *fm = fopen((d + "/midi.txt").c_str(), "r");
	unsigned long long mi_n = 0; unsigned mi_b = 0;
	auto next_midi = [&]() -> bool {
		char dir[8];
		while (fm && fscanf(fm, "%llu %7s %x", &mi_n, dir, &mi_b) == 3) if (!strcmp(dir, "in")) return true;
		return false;
	};
	bool mi_ok = next_midi();
	FILE *fo = fopen((d + "/out.bin").c_str(), "rb");
	if (!regs.f || !rw.f || !fo) { fprintf(stderr, "capture incomplete in %s\n", cap); return 2; }

	t = new Vm2_scsp;
	t->rst_n = 0; t->step_mode = 1; t->step_go = 0; t->out_ready = 0; t->tick44 = 0; t->cpu_tick = 0;
	t->cpu_req = 0; t->midi_valid = 0; t->snp = 0;
	for (int i = 0; i < 4; i++) tick();
	t->rst_n = 1;
	for (int i = 0; i < 4; i++) tick();

	uint64_t bad = 0, bad_mame = 0, slot_bad = 0, slot_checks = 0, nz = 0, rd_checks = 0, rd_bad = 0, mo_bad = 0;
	std::deque<int> mout_want;
	// a read: the RTL's answer against the reference's r16 (exactly), and
	// against MAME's logged one (loosely: the order within a sample is lost)
	auto do_read = [&](uint64_t n, uint16_t off, bool has_mame, uint16_t mame_v) -> bool {
		t->cpu_addr = (off >> 1) & 0x7ff; t->cpu_we = 0; t->cpu_be = 3;
		t->cpu_req = 1; tick(); t->cpu_req = 0;
		int g = 0; while (!t->cpu_ack) { tick(); if (++g > 2000000) { printf("FAIL: read not acked\n"); return false; } }
		uint16_t want = R.r16(off);
		rd_checks++;
		if (t->cpu_dout != want) {
			if (rd_bad < 10) printf("  sample %llu: read %03x rtl %04x ref %04x\n", (unsigned long long)n, off, t->cpu_dout, want);
			rd_bad++;
		}
		if (has_mame && want != mame_v) rd_mame++;
		return true;
	};
	uint64_t eng_cyc = 0, eng_max = 0;
	std::vector<uint64_t> hist(64, 0);
	int64_t first_bad = -1;
	for (uint64_t n = 0; n < N; n++) {
		s32 mo[2];
		if (fread(mo, sizeof mo, 1, fo) != 1) { N = n; break; }
		// MIDI bytes from the main board before sample n: the reference's, the RTL's
		while (mi_ok && mi_n <= n) {
			R.midi_in(u8(mi_b));
			t->midi_data = mi_b; t->midi_valid = 1;
			int g = 0; do { tick(); if (++g > 1000) { printf("FAIL: MIDI byte not taken\n"); return 1; } } while (!t->midi_ack);
			t->midi_valid = 0; tick();
			mi_ok = next_midi();
		}
		// the 68000's reads (MAME's answers logged), then its writes, before sample n
		while (rds.ok && rds.cur.n <= n) { if (!do_read(n, rds.cur.off, true, rds.cur.data)) return 1; rds.next(); }
		while (regs.ok && regs.cur.n <= n) {
			if (regs.cur.pad == 1) { if (!do_read(n, regs.cur.off, false, 0)) return 1; regs.next(); continue; }
			R.write(regs.cur.off, regs.cur.data, regs.cur.mask);
			if ((regs.cur.off & 0xffe) == 0x406) mout_want.push_back(R.udata[3] & 0xff);
			t->cpu_addr = (regs.cur.off >> 1) & 0x7ff;
			t->cpu_din = regs.cur.data; t->cpu_we = 1;
			t->cpu_be = ((regs.cur.mask & 0xff00) ? 2 : 0) | ((regs.cur.mask & 0x00ff) ? 1 : 0);
			t->cpu_req = 1; tick(); t->cpu_req = 0;
			int g = 0; while (!t->cpu_ack) { tick(); if (++g > 100000) { printf("FAIL: write not acked\n"); return 1; } }
			// let the queue drain before the next (the 68000 is never faster than this)
			g = 0; while (!t->quiet) { tick(); if (++g > 2000000) { printf("FAIL: not quiet after a write (n %llu)\n", (unsigned long long)n); return 1; } }
			regs.next();
		}
		// the IPL: against the reference's lines exactly; against MAME's loosely
		// (MAME's timers are its scheduler's, not sample-locked, and the logs do
		// not keep the order of reads, writes and MIDI within a sample)
		{
			int want = 0; for (int l = 1; l < 8; l++) if (R.lines & (1u << l)) want = l;
			ipl_checks++;
			if (int(t->ipl) != want) { if (ipl_bad < 10) printf("  sample %llu: ipl rtl %d ref %d (lines %02x)\n", (unsigned long long)n, int(t->ipl), want, R.lines); ipl_bad++; }
			while (irq_ok && irq_n <= n) {
				if (irq_l) { if (irq_v) mame_lines |= 1u << irq_l; else mame_lines &= ~(1u << irq_l); }
				irq_ok = fscanf(fi, "%llu %u %u", &irq_n, &irq_l, &irq_v) == 3;
			}
			int mw_ = 0; for (int l = 1; l < 8; l++) if (mame_lines & (1u << l)) mw_ = l;
			if (fi && mw_ != want) { if (getenv("IPLDBG") && ipl_mame < 4000) printf("  sample %llu: ipl ref %d (lines %02x) MAME %d (lines %02x)\n", (unsigned long long)n, want, R.lines, mw_, mame_lines); ipl_mame++; }
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
		if (getenv("DREF")) {   // the FM read the reference's slot is about to make
			int ds = atoi(getenv("DREF"));
			const Slot &q = R.S[ds];
			int x = int(((32 * n + ds) + ((q.data[7] >> 6) & 63)) & 63), y = int(((32 * n + ds) + (q.data[7] & 63)) & 63);
			if (getenv("DREF_FM")) printf("ref fm n %llu x %d %04x y %d %04x\n", (unsigned long long)n, x, uint16_t(R.RINGBUF[x]), y, uint16_t(R.RINGBUF[y]));
		}
		s32 rl, rr; R.sample(rl, rr);
		R.tick();
		if (getenv("DREF")) {   // DREF=<slot> DREF_FROM / DREF_TO: the reference's slot, after the sample
			static int ds = atoi(getenv("DREF"));
			static uint64_t d0 = getenv("DREF_FROM") ? strtoull(getenv("DREF_FROM"), nullptr, 0) : 0, d1 = getenv("DREF_TO") ? strtoull(getenv("DREF_TO"), nullptr, 0) : ~0ull;
			const Slot &q = R.S[ds];
			if (n >= d0 && n < d1)
				printf("ref n %llu slot %d act %d eg %d vol %x cur %08x r0 %04x out %d ar %x d1r %x d2r %x rr %x dl %x w4 %04x w5 %04x w8 %04x w9 %04x ring %04x pph %04x/%x aph %04x/%x\n", (unsigned long long)n, ds, q.active, int(q.EG.state), q.EG.volume, q.cur_addr, q.data[0], R.slot_out[ds], q.EG.AR, q.EG.D1R, q.EG.D2R, q.EG.RR, q.EG.DL, q.data[4], q.data[5], q.data[8], q.data[9], uint16_t(R.RINGBUF[(32 * n + ds) & 63]), q.PLFO.phase, q.PLFO.phase_step, q.ALFO.phase, q.ALFO.phase_step);
		}
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
	for (int i = 0; i < 200; i++) tick();
	{
		size_t k = 0;
		for (; k < mout_want.size() && k < mout_got.size(); k++) if (mout_want[k] != mout_got[k]) mo_bad++;
		mo_bad += (mout_want.size() > mout_got.size() ? mout_want.size() - mout_got.size() : mout_got.size() - mout_want.size());
		printf("  reads checked %llu, wrong %llu; MIDI out bytes %zu, wrong %llu\n", (unsigned long long)rd_checks, (unsigned long long)rd_bad,
		       mout_want.size(), (unsigned long long)mo_bad);
		printf("  IPL checked %llu samples, wrong %llu (the reference's against MAME's lines: %llu differ); reads against MAME's: %llu differ\n",
		       (unsigned long long)ipl_checks, (unsigned long long)ipl_bad, (unsigned long long)ipl_mame, (unsigned long long)rd_mame);
		bad += rd_bad + mo_bad + ipl_bad;
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
