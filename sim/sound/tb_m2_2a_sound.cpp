// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// tb_m2_2a_sound: the Model 2A sound board (m2_2a_sound: fx68k, the SCSP,
// sound RAM in SDRAM) running a game's real sound program, free-running at
// 80 MHz against three SDRAM ports of random latency, with the MIDI bytes
// MAME's i960 sent at MAME's times (study R859). It is not bit-exact -- the
// 68000's accesses land when its own timing puts them, R821's case -- so it
// checks what the board must get right:
//   * the 68000 runs (no fault, no hang) and keeps up: the FIFO never empty;
//   * the SCSP register writes it makes are MAME's, in MAME's order (the
//     longest common subsequence against the capture's regs.bin, and how far
//     apart in time the matched writes land);
//   * the mix's level, second by second, against MAME's out.bin.
//
//   SND_IMG=<dir with prog.bin, samp.bin (snd_img.py)>  SCSP_CAP=<p16 capture>
//   SND_S=<seconds, default 10>  LAT_LO / LAT_HI (default 6 / 40)
//   SND_RAMFILL=<word>  what unwritten sound RAM reads (default 0xffff)
#include "Vm2_2a_sound.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>
#include <deque>
#include <algorithm>

static Vm2_2a_sound *t;
static uint64_t cyc = 0;
static const double CLK = 80e6;
// SDRAM, word addressed as the core's: the board's parameters below
static const uint32_t RAM_BASE = 0x12C0000, ROM_BASE = 0x1260000, SMP_BASE = 0x1A00000;
static std::vector<uint16_t> ram(0x40000), rom(0x40000), smp(0x400000);
static uint16_t ramfill = 0xffff;
static uint32_t rng_s = 1;
static int lat_lo = 6, lat_hi = 40;
static int lat() { rng_s = rng_s * 1103515245u + 12345u; return lat_lo + int((rng_s >> 8) % unsigned(lat_hi - lat_lo + 1)); }

static uint16_t rd16(uint32_t w) {
	if (w >= RAM_BASE && w < RAM_BASE + 0x40000) return ram[w - RAM_BASE];
	if (w >= ROM_BASE && w < ROM_BASE + 0x40000) { uint16_t v = rom[w - ROM_BASE]; return uint16_t((v << 8) | (v >> 8)); }   // the loader's order
	if (w >= SMP_BASE && w < SMP_BASE + 0x400000) { uint16_t v = smp[w - SMP_BASE]; return uint16_t((v << 8) | (v >> 8)); }
	return 0xffff;
}
static uint64_t rd64(uint32_t w) { w &= ~3u; uint64_t v = 0; for (int i = 0; i < 4; i++) v |= uint64_t(rd16(w + i)) << (16 * i); return v; }
static uint64_t ram_writes = 0, bad_writes = 0;
static void wr16(uint32_t w, uint16_t d, int be) {
	if (w >= RAM_BASE && w < RAM_BASE + 0x40000) {
		uint16_t &x = ram[w - RAM_BASE];
		if (be & 2) x = uint16_t((x & 0x00ff) | (d & 0xff00));
		if (be & 1) x = uint16_t((x & 0xff00) | (d & 0x00ff));
		ram_writes++;
	} else bad_writes++;
}

struct Port { bool busy = false, was = false; int wait = 0; };
static Port pa, pb, pc;

static void tick() {
	t->clk = 0; t->eval();
	t->a_ack = 0; t->b_ack = 0; t->c_ack = 0;
	if (t->a_req && !pa.was && !pa.busy) { pa.busy = true; pa.wait = lat(); }
	if (pa.busy && --pa.wait <= 0) {
		pa.busy = false; t->a_ack = 1;
		if (t->a_we) wr16(t->a_addr, t->a_din, t->a_be); else t->a_dout = rd64(t->a_addr);
	}
	pa.was = t->a_req;
	if (t->b_req && !pb.was && !pb.busy) { pb.busy = true; pb.wait = lat(); }
	if (pb.busy && --pb.wait <= 0) { pb.busy = false; t->b_ack = 1; t->b_dout = rd64(t->b_addr); }
	pb.was = t->b_req;
	if (t->c_req && !pc.was && !pc.busy) { pc.busy = true; pc.wait = lat(); }
	if (pc.busy && --pc.wait <= 0) {
		pc.busy = false; t->c_ack = 1;
		if (t->c_we) wr16(t->c_addr, t->c_din, 3); else t->c_dout = rd64(t->c_addr);
	}
	pc.was = t->c_req;
	t->eval();
	t->clk = 1; t->eval();
	cyc++;
}

struct Rec { uint32_t n; uint16_t off, data, mask, pad; };
struct W { double t; uint16_t off, data, mask; };

static bool load(const std::string &p, std::vector<uint16_t> &v) {
	FILE *f = fopen(p.c_str(), "rb");
	if (!f) return false;
	std::vector<uint8_t> b(v.size() * 2);
	size_t n = fread(b.data(), 1, b.size(), f); fclose(f);
	for (size_t i = 0; i + 1 < n; i += 2) v[i / 2] = uint16_t((b[i] << 8) | b[i + 1]);   // big end first
	return n > 0;
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	const char *img = getenv("SND_IMG"), *cap = getenv("SCSP_CAP");
	if (!img || !cap) { fprintf(stderr, "SND_IMG=<dir> SCSP_CAP=<capture>\n"); return 2; }
	double secs = getenv("SND_S") ? atof(getenv("SND_S")) : 10.0;
	if (getenv("LAT_LO")) lat_lo = atoi(getenv("LAT_LO"));
	if (getenv("LAT_HI")) lat_hi = atoi(getenv("LAT_HI"));
	if (getenv("SND_RAMFILL")) ramfill = uint16_t(strtoul(getenv("SND_RAMFILL"), nullptr, 0));
	std::fill(ram.begin(), ram.end(), ramfill);
	if (!load(std::string(img) + "/prog.bin", rom) || !load(std::string(img) + "/samp.bin", smp)) { fprintf(stderr, "no images in %s\n", img); return 2; }

	// MAME's side: the MIDI bytes in (with their times) and the register writes
	std::string d = cap;
	std::vector<std::pair<double, int>> midi;
	if (FILE *f = fopen((d + "/midi.txt").c_str(), "r")) {
		unsigned long long n; char dir[8]; unsigned b;
		while (fscanf(f, "%llu %7s %x", &n, dir, &b) == 3) if (!strcmp(dir, "in")) midi.push_back({n / 44100.0, int(b)});
		fclose(f);
	}
	std::vector<W> mw;
	if (FILE *f = fopen((d + "/regs.bin").c_str(), "rb")) {
		Rec r;
		while (fread(&r, sizeof r, 1, f) == 1) { if (r.n / 44100.0 > secs) break; if (!r.pad) mw.push_back({r.n / 44100.0, r.off, uint16_t(r.data & r.mask), r.mask}); }
		fclose(f);
	}
	std::vector<int32_t> mout;   // MAME's mix, pre-clamp L / R
	if (FILE *f = fopen((d + "/out.bin").c_str(), "rb")) {
		int32_t s[2];
		while (fread(s, sizeof s, 1, f) == 1 && mout.size() < size_t(secs * 44100) * 2) { mout.push_back(s[0]); mout.push_back(s[1]); }
		fclose(f);
	}

	t = new Vm2_2a_sound;
	t->rst_n = 0; t->rx_valid = 0; t->tx_ack = 0;
	for (int i = 0; i < 8; i++) tick();
	t->rst_n = 1;

	std::vector<W> rw;
	size_t mi = 0;
	uint64_t end = uint64_t(secs * CLK), midi_bytes = 0, tx_bytes = 0;
	std::vector<double> ours_rms, mame_rms;
	double acc_l = 0; uint64_t nacc = 0; int16_t last_l = 0; uint64_t last_samples = 0;
	uint32_t pc_last = 0; uint64_t pc_same = 0;
	while (cyc < end) {
		double now = cyc / CLK;
		// MIDI: the next byte once its time has come and the last was taken
		if (!t->rx_valid && mi < midi.size() && midi[mi].first <= now) { t->rx_data = uint8_t(midi[mi].second); t->rx_valid = 1; }
		tick();
		if (t->rx_valid && t->rx_ack) { t->rx_valid = 0; mi++; midi_bytes++; }
		t->tx_ack = t->tx_valid;
		if (t->tx_valid) tx_bytes++;
		if (t->dbg_scsp_we) {
			uint16_t m = uint16_t(((t->dbg_scsp_be & 2) ? 0xff00 : 0) | ((t->dbg_scsp_be & 1) ? 0x00ff : 0));
			rw.push_back({cyc / CLK, uint16_t(t->dbg_scsp_a << 1), uint16_t(t->dbg_scsp_d & m), m});
		}
		// the output, one value per drained sample
		if (cyc % 1814 == 0) { acc_l += double(t->snd_l) * t->snd_l; nacc++; }
		if (nacc == 44100) { ours_rms.push_back(sqrt(acc_l / nacc)); acc_l = 0; nacc = 0; }
		if ((cyc % 8000000) == 0) {
			if (t->dbg_addr == pc_last) pc_same++; else pc_same = 0;
			pc_last = t->dbg_addr;
			printf("  %.1f s: 68000 cycles %u, samples %u, FIFO empty %u, MIDI in %llu, out %llu, SCSP writes %zu (MAME %zu by then)\n",
				now, t->dbg_cycles, t->dbg_samples, t->dbg_under, (unsigned long long)midi_bytes, (unsigned long long)tx_bytes, rw.size(),
				size_t(std::count_if(mw.begin(), mw.end(), [&](const W &w) { return w.t <= now; })));
			fflush(stdout);
		}
	}
	// MAME's level, second by second (its mix >> 2, the DAC's 16 bits, MVOL 15)
	for (size_t s = 0; s + 1 <= mout.size() / 2 / 44100; s++) {
		double a = 0;
		for (size_t i = 0; i < 44100; i++) { double v = std::max(-32768.0, std::min(32767.0, double(mout[2 * (s * 44100 + i)] >> 2))); a += v * v; }
		mame_rms.push_back(sqrt(a / 44100));
	}
	// the writes: longest common subsequence of (offset, data, mask), windowed
	// the window: MAME's writes from SND_FROM seconds, ours from SND_FROM + SND_OFS
	double from = getenv("SND_FROM") ? atof(getenv("SND_FROM")) : 0.0;
	double ofs = getenv("SND_OFS") ? atof(getenv("SND_OFS")) : 0.0;
	size_t a0 = 0, b0 = 0;
	while (a0 < rw.size() && rw[a0].t < from + ofs) a0++;
	while (b0 < mw.size() && mw[b0].t < from) b0++;
	size_t na = std::min(rw.size() - a0, size_t(8000)), nb = std::min(mw.size() - b0, size_t(8000)), mtch = 0;
	std::vector<std::vector<uint16_t>> L(na + 1, std::vector<uint16_t>(nb + 1, 0));
	// (16-bit LCS cells: a window of up to 8,000 writes each)
	for (size_t i = 1; i <= na; i++) for (size_t j = 1; j <= nb; j++) {
		const W &a = rw[a0 + i - 1], &b = mw[b0 + j - 1];
		if (a.off == b.off && a.data == b.data && a.mask == b.mask) L[i][j] = uint16_t(L[i - 1][j - 1] + 1);
		else L[i][j] = std::max(L[i - 1][j], L[i][j - 1]);
	}
	mtch = L[na][nb];
	// time offsets of the matched pairs (walk back)
	std::vector<double> dt;
	for (size_t i = na, j = nb; i && j;) {
		const W &a = rw[a0 + i - 1], &b = mw[b0 + j - 1];
		if (a.off == b.off && a.data == b.data && a.mask == b.mask) { dt.push_back(a.t - b.t); i--; j--; }
		else if (L[i - 1][j] >= L[i][j - 1]) i--; else j--;
	}
	std::sort(dt.begin(), dt.end());
	if (const char *dp = getenv("SND_DUMP")) {   // both write streams, for a diff
		if (FILE *f = fopen(dp, "w")) {
			for (const W &w : rw) fprintf(f, "ours %.6f %03x %04x %04x\n", w.t, w.off, w.data, w.mask);
			for (const W &w : mw) fprintf(f, "mame %.6f %03x %04x %04x\n", w.t, w.off, w.data, w.mask);
			fclose(f);
		}
	}
	printf("tb_m2_2a_sound %s: %.1f s, 68000 bus cycles %u (last address %06x), samples %u, FIFO found empty %u times\n",
		cap, secs, t->dbg_cycles, t->dbg_addr, t->dbg_samples, t->dbg_under);
	printf("  MIDI in %llu of MAME's %zu (in the time); MIDI out %llu bytes; sound-RAM writes %llu, stray writes %llu\n",
		(unsigned long long)midi_bytes, size_t(std::count_if(midi.begin(), midi.end(), [&](const std::pair<double, int> &m) { return m.first <= secs; })), (unsigned long long)tx_bytes, (unsigned long long)ram_writes, (unsigned long long)bad_writes);
	printf("  SCSP writes: ours %zu, MAME's %zu; in MAME's order (LCS of %zu / %zu from %.2f s) %zu = %.1f%% of MAME's\n",
		rw.size(), mw.size(), na, nb, from, mtch, nb ? 100.0 * mtch / nb : 0.0);
	if (!dt.empty())
		printf("  matched writes land later than MAME's by: median %.2f ms, 10%% %.2f ms, 90%% %.2f ms\n",
			1e3 * dt[dt.size() / 2], 1e3 * dt[dt.size() / 10], 1e3 * dt[dt.size() * 9 / 10]);
	printf("  level (RMS, left), second by second -- ours / MAME's:\n   ");
	for (size_t s = 0; s < std::max(ours_rms.size(), mame_rms.size()); s++)
		printf(" %.0f/%.0f", s < ours_rms.size() ? ours_rms[s] : -1.0, s < mame_rms.size() ? mame_rms[s] : -1.0);
	printf("\n");
	bool ok = t->dbg_under == 0 && bad_writes == 0 && t->dbg_cycles > 1000 && (nb == 0 || mtch >= nb * 9 / 10);
	printf("%s\n", ok ? "PASS" : "FAIL");
	return ok ? 0 : 1;
}
