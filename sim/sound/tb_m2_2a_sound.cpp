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
//   LAT_A_LO / LAT_A_HI the 68000's port alone (R874)
//   LAT_TRACE=<prefix>  R877: each port's latency from tb_m2_sdram_load's trace
//     (<prefix>5/6/7.txt, "issue latency" in clk_mem cycles of 100 MHz): a
//     request at time t takes the latency the arbiter gave the first traced
//     request at or after t (mod the trace's span), x CLK/100 + LAT_CDC
//     (default 4) clk_sys for the crossing -- bursty, as the load is
//   SND_SHIFT=<s> [SND_SHIFT_AFTER=<s>, default 5]  MAME's MIDI and writes from
//     SND_SHIFT_AFTER moved SND_SHIFT seconds earlier, to reach a late event
//     in a short run (R874: VF2's music at 4.77 s with SND_SHIFT=9)
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
#ifndef CLK_MHZ
#define CLK_MHZ 80
#endif
static const double CLK = CLK_MHZ * 1e6;   // (SND2A_MHZ: the boot harness runs the board at 48)
// SDRAM, word addressed as the core's: the board's parameters below
static const uint32_t RAM_BASE = 0x12C0000, ROM_BASE = 0x1260000, SMP_BASE = 0x1A00000;
static std::vector<uint16_t> ram(0x40000), rom(0x40000), smp(0x400000);
static uint16_t ramfill = 0xffff;
static uint32_t rng_s = 1;
static int lat_lo = 6, lat_hi = 40;
static int lat() { rng_s = rng_s * 1103515245u + 12345u; return lat_lo + int((rng_s >> 8) % unsigned(lat_hi - lat_lo + 1)); }
// LAT_A_LO / LAT_A_HI: the 68000's port alone (default: LAT_LO / LAT_HI)
static int lat_a_lo = -1, lat_a_hi = -1;
static int lat_a() {
	if (lat_a_lo < 0) return lat();
	rng_s = rng_s * 1103515245u + 12345u; return lat_a_lo + int((rng_s >> 8) % unsigned(lat_a_hi - lat_a_lo + 1));
}

static uint16_t rd16(uint32_t w) {
	if (w >= RAM_BASE && w < RAM_BASE + 0x40000) return ram[w - RAM_BASE];
	if (w >= ROM_BASE && w < ROM_BASE + 0x40000) { uint16_t v = rom[w - ROM_BASE]; return uint16_t((v << 8) | (v >> 8)); }   // the loader's order
	if (w >= SMP_BASE && w < SMP_BASE + 0x400000) { uint16_t v = smp[w - SMP_BASE]; return uint16_t((v << 8) | (v >> 8)); }
	return 0xffff;
}
static uint64_t rd64(uint32_t w) { w &= ~3u; uint64_t v = 0; for (int i = 0; i < 4; i++) v |= uint64_t(rd16(w + i)) << (16 * i); return v; }
static uint64_t ram_writes = 0, bad_writes = 0, part_writes = 0;   // R871: part = a write with be != 3
static void wr16(uint32_t w, uint16_t d, int be) {
	if (w >= RAM_BASE && w < RAM_BASE + 0x40000) {
		uint16_t &x = ram[w - RAM_BASE];
		// R871: AS THE BOARD DOES IT -- the byte enables never reach the
		// SDRAM (R82), so a write lands in both lanes whatever be says.
		// SND_BE_HONOUR=1 brings the old model back.
		static const bool honour = getenv("SND_BE_HONOUR") != nullptr;
		if (honour) {
			if (be & 2) x = uint16_t((x & 0x00ff) | (d & 0xff00));
			if (be & 1) x = uint16_t((x & 0xff00) | (d & 0x00ff));
		} else x = d;
		if (be != 3) part_writes++;
		ram_writes++;
	} else bad_writes++;
}

struct Port { bool busy = false, was = false; int wait = 0; };
static Port pa, pb, pc;

// R877: the latency trace (LAT_TRACE) and the ports' demand
struct Trace { std::vector<std::pair<uint64_t, uint32_t>> v; uint64_t span = 0; };
static Trace tr[3];
static int lat_cdc = 4;
static bool load_trace(const std::string &f, Trace &x) {
	FILE *fp = fopen(f.c_str(), "r");
	if (!fp) return false;
	unsigned long long a; unsigned long b;
	while (fscanf(fp, "%llu %lu", &a, &b) == 2) x.v.push_back({a, uint32_t(b)});
	fclose(fp);
	if (!x.v.empty()) x.span = x.v.back().first + 1;
	return !x.v.empty();
}
static int lat_tr(int k) {   // k: 0 = port 5 (a), 1 = 6 (b), 2 = 7 (c)
	const Trace &x = tr[k];
	const uint64_t tm = uint64_t(double(cyc) * 100.0 / CLK_MHZ) % x.span;
	auto it = std::lower_bound(x.v.begin(), x.v.end(), std::make_pair(tm, uint32_t(0)));
	if (it == x.v.end()) it = x.v.begin();
	return int(it->second * CLK_MHZ / 100.0 + 0.999) + lat_cdc;
}
static bool use_tr = false;
struct Dem { uint64_t rd = 0, wr = 0, lat = 0, win = 0, win_max = 0, win_t = 0, lat_max = 0; };
static Dem dem[3];
static uint64_t a_wait = 0;   // clocks the 68000's port has a request outstanding
static void dem_req(int k, bool we, int l) {
	Dem &d = dem[k];
	(we ? d.wr : d.rd)++; d.lat += uint64_t(l); if (uint64_t(l) > d.lat_max) d.lat_max = uint64_t(l);
	const uint64_t w = cyc / uint64_t(CLK / 100);   // 10 ms windows
	if (w != d.win_t) { d.win_t = w; d.win = 0; }
	if (++d.win > d.win_max) d.win_max = d.win;
}

static void tick() {
	t->clk = 0; t->eval();
	t->a_ack = 0; t->b_ack = 0; t->c_ack = 0;
	if (t->a_req && !pa.was && !pa.busy) { pa.busy = true; pa.wait = use_tr ? lat_tr(0) : lat_a(); dem_req(0, t->a_we, pa.wait); }
	if (pa.busy) a_wait++;
	if (pa.busy && --pa.wait <= 0) {
		pa.busy = false; t->a_ack = 1;
		if (t->a_we) wr16(t->a_addr, t->a_din, t->a_be); else t->a_dout = rd64(t->a_addr);
	}
	pa.was = t->a_req;
	if (t->b_req && !pb.was && !pb.busy) { pb.busy = true; pb.wait = use_tr ? lat_tr(1) : lat(); dem_req(1, false, pb.wait); }
	if (pb.busy && --pb.wait <= 0) { pb.busy = false; t->b_ack = 1; t->b_dout = rd64(t->b_addr); }
	pb.was = t->b_req;
	if (t->c_req && !pc.was && !pc.busy) { pc.busy = true; pc.wait = use_tr ? lat_tr(2) : lat(); dem_req(2, t->c_we, pc.wait); }
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
	if (getenv("LAT_CDC")) lat_cdc = atoi(getenv("LAT_CDC"));
	if (const char *lt = getenv("LAT_TRACE")) {
		use_tr = true;
		for (int k = 0; k < 3; k++)
			if (!load_trace(std::string(lt) + std::to_string(5 + k) + ".txt", tr[k])) { fprintf(stderr, "no trace %s%d.txt\n", lt, 5 + k); return 2; }
	}
	if (getenv("LAT_A_LO")) { lat_a_lo = atoi(getenv("LAT_A_LO")); lat_a_hi = getenv("LAT_A_HI") ? atoi(getenv("LAT_A_HI")) : lat_a_lo; }
	// SND_SHIFT=<s>: MAME's MIDI bytes and register writes from SND_SHIFT_AFTER
	// seconds (default 5) moved SND_SHIFT seconds earlier -- to reach a late
	// event (VF2's first sound effect, 19.8 s) in a short run
	const double shift = getenv("SND_SHIFT") ? atof(getenv("SND_SHIFT")) : 0.0;
	const double shift_after = getenv("SND_SHIFT_AFTER") ? atof(getenv("SND_SHIFT_AFTER")) : 5.0;
	auto shifted = [&](double tm) { return tm >= shift_after ? tm - shift : tm; };
	if (getenv("SND_RAMFILL")) ramfill = uint16_t(strtoul(getenv("SND_RAMFILL"), nullptr, 0));
	std::fill(ram.begin(), ram.end(), ramfill);
	if (!load(std::string(img) + "/prog.bin", rom) || !load(std::string(img) + "/samp.bin", smp)) { fprintf(stderr, "no images in %s\n", img); return 2; }

	// MAME's side: the MIDI bytes in (with their times) and the register writes
	std::string d = cap;
	std::vector<std::pair<double, int>> midi;
	if (FILE *f = fopen((d + "/midi.txt").c_str(), "r")) {
		unsigned long long n; char dir[8]; unsigned b;
		while (fscanf(f, "%llu %7s %x", &n, dir, &b) == 3) if (!strcmp(dir, "in")) midi.push_back({shifted(n / 44100.0), int(b)});
		fclose(f);
	}
	std::vector<W> mw;
	if (FILE *f = fopen((d + "/regs.bin").c_str(), "rb")) {
		Rec r;
		while (fread(&r, sizeof r, 1, f) == 1) {
			const double tm = r.n / 44100.0;
			if (shifted(tm) > secs) break;
			if (!r.pad && (shift == 0.0 || tm < shift_after - shift || tm >= shift_after)) mw.push_back({shifted(tm), r.off, uint16_t(r.data & r.mask), r.mask});
		}
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

	// SND_WAV=<path>: the output as a 44.1 kHz stereo WAV (header written at the end)
	FILE *wav = getenv("SND_WAV") ? fopen(getenv("SND_WAV"), "wb") : nullptr;
	uint64_t nwav = 0;
	if (wav) { uint8_t h[44] = {0}; fwrite(h, 1, 44, wav); }
	std::vector<W> rw;
	size_t mi = 0;
	const char *ramdump = getenv("SND_RAMDUMP");
	const double ramdump_at = getenv("SND_RAMDUMP_AT") ? atof(getenv("SND_RAMDUMP_AT")) : 3.0;
	const uint64_t midi_gap = getenv("SND_MIDI_GAP") ? strtoull(getenv("SND_MIDI_GAP"), nullptr, 0) : 0;
	uint64_t midi_next = 0;
	uint64_t end = uint64_t(secs * CLK), midi_bytes = 0, tx_bytes = 0;
	std::vector<double> ours_rms, mame_rms;
	double acc_l = 0; uint64_t nacc = 0; int16_t last_l = 0; uint64_t last_samples = 0;
	uint32_t pc_last = 0; uint64_t pc_same = 0;
	// R883: the output read once per drained sample, on the board's own 44.1 kHz
	// accumulator (T44_NUM / T44_DEN, 441 / CLK_MHZ x 10000) -- not every
	// CLK / 44100 clocks rounded, which at 48 MHz read 44,117.6 samples a second
	uint64_t tacc = 0; const uint64_t T44_DEN = uint64_t(CLK_MHZ) * 10000;
	while (cyc < end) {
		double now = cyc / CLK;
		// MIDI: the next byte once its time has come and the last was taken
		// (SND_MIDI_GAP=<clocks>: at least that long from one byte to the next, as the
		// serial line spaces them -- 320 us at 31,250 baud; MAME delivers at once)
		if (!t->rx_valid && mi < midi.size() && midi[mi].first <= now && cyc >= midi_next) {
			t->rx_data = uint8_t(midi[mi].second); t->rx_valid = 1; midi_next = cyc + midi_gap;
		}
		tick();
		if (t->rx_valid && t->rx_ack) { t->rx_valid = 0; mi++; midi_bytes++; }
		t->tx_ack = t->tx_valid;
		if (t->tx_valid) tx_bytes++;
		if (t->dbg_scsp_we) {
			uint16_t m = uint16_t(((t->dbg_scsp_be & 2) ? 0xff00 : 0) | ((t->dbg_scsp_be & 1) ? 0x00ff : 0));
			rw.push_back({cyc / CLK, uint16_t(t->dbg_scsp_a << 1), uint16_t(t->dbg_scsp_d & m), m});
		}
		// SND_RAMDUMP=<file> SND_RAMDUMP_AT=<seconds>: the sound RAM, big end first
		if (ramdump && now >= ramdump_at) {
			if (FILE *rf = fopen(ramdump, "wb")) {
				for (uint32_t w = 0; w < 0x40000; w++) { uint8_t b2[2] = {uint8_t(ram[w] >> 8), uint8_t(ram[w])}; fwrite(b2, 1, 2, rf); }
				fclose(rf);
			}
			ramdump = nullptr;
		}
		// the output, one value per drained sample
		tacc += 441;
		if (tacc >= T44_DEN) {   // (the ports are unsigned in C++: the sign by hand)
			tacc -= T44_DEN;
			const int16_t l = int16_t(t->snd_l), r = int16_t(t->snd_r);
			acc_l += double(l) * l; nacc++;
			if (wav) { int16_t sm[2] = {l, r}; fwrite(sm, 2, 2, wav); nwav++; }
		}
		if (nacc == 44100) { ours_rms.push_back(sqrt(acc_l / nacc)); acc_l = 0; nacc = 0; }
		if ((cyc % uint64_t(CLK / 10)) == 0) {
			if (t->dbg_addr == pc_last) pc_same++; else pc_same = 0;
			pc_last = t->dbg_addr;
			printf("  %.1f s: 68000 cycles %u, samples %u, FIFO empty %u, MIDI in %llu, out %llu, SCSP writes %zu (MAME %zu by then)\n",
				now, t->dbg_cycles, t->dbg_samples, t->dbg_under, (unsigned long long)midi_bytes, (unsigned long long)tx_bytes, rw.size(),
				size_t(std::count_if(mw.begin(), mw.end(), [&](const W &w) { return w.t <= now; })));
			fflush(stdout);
		}
	}
	t->final();   // (the RTL's final blocks: M2_SND_TRACE's summary, R885)
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
	if (wav) {
		const uint32_t db = uint32_t(nwav * 4);
		uint8_t h[44] = {'R', 'I', 'F', 'F'};
		auto le32 = [&](int o, uint32_t v) { for (int i = 0; i < 4; i++) h[o + i] = uint8_t(v >> (8 * i)); };
		le32(4, 36 + db); memcpy(h + 8, "WAVEfmt ", 8); le32(16, 16);
		h[20] = 1; h[22] = 2; le32(24, 44100); le32(28, 44100 * 4); h[32] = 4; h[34] = 16;
		memcpy(h + 36, "data", 4); le32(40, db);
		fseek(wav, 0, SEEK_SET); fwrite(h, 1, 44, wav); fclose(wav);
	}
	if (const char *dp = getenv("SND_DUMP")) {   // both write streams, for a diff
		if (FILE *f = fopen(dp, "w")) {
			for (const W &w : rw) fprintf(f, "ours %.6f %03x %04x %04x\n", w.t, w.off, w.data, w.mask);
			for (const W &w : mw) fprintf(f, "mame %.6f %03x %04x %04x\n", w.t, w.off, w.data, w.mask);
			fclose(f);
		}
	}
	printf("tb_m2_2a_sound %s: %.1f s, 68000 bus cycles %u (last address %06x), samples %u, FIFO found empty %u times\n",
		cap, secs, t->dbg_cycles, t->dbg_addr, t->dbg_samples, t->dbg_under);
	printf("  pre-boot sound-RAM check: %u words wrong; MVOL %u; 68000 writes to 0x400 %u, to 0x418 %u\n",
		(unsigned)t->dbg_selftest, (unsigned)t->dbg_mvol, (unsigned)t->dbg_w400, (unsigned)t->dbg_w418);
	if (t->dbg_selftest) { printf("FAIL: the sound-RAM check found wrong words\n"); return 1; }
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
	{   // R877: what the board asked of each port
		const double sec = cyc / CLK;
		static const char *nm[3] = {"5 (68000)", "6 (slot fills)", "7 (DSP)"};
		printf("  SDRAM demand over %.1f s (%s):\n", sec, use_tr ? "LAT_TRACE" : "random latency");
		for (int k = 0; k < 3; k++) {
			const Dem &d = dem[k]; const uint64_t n = d.rd + d.wr;
			printf("    port %-15s reads %8.0f/s writes %8.0f/s, worst 10 ms %6llu (%.0f/s), latency mean %.1f max %llu clk\n",
				nm[k], d.rd / sec, d.wr / sec, (unsigned long long)d.win_max, d.win_max * 100.0, n ? double(d.lat) / n : 0.0, (unsigned long long)d.lat_max);
		}
		printf("    the 68000 waiting on port 5: %.1f%% of all clocks\n", 100.0 * a_wait / cyc);
	}
	// R882: the boot-time sums (CHKSUM builds; zero otherwise)
	printf("  sound ROM sums (R882): program %08x, samples %08x %08x %08x %08x\n",
		t->dbg_sums[0], t->dbg_sums[1], t->dbg_sums[2], t->dbg_sums[3], t->dbg_sums[4]);
	printf("  RAM writes with a byte mask (R871: must be 0 -- the board drops the mask): %llu\n", (unsigned long long)part_writes);
	bool ok = t->dbg_under == 0 && bad_writes == 0 && part_writes == 0 && t->dbg_cycles > 1000 && (nb == 0 || mtch >= nb * 9 / 10);
	printf("%s\n", ok ? "PASS" : "FAIL");
	return ok ? 0 : 1;
}
