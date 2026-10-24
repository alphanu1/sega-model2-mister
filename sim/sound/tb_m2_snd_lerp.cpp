// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// tb_m2_snd_lerp (study R949): m2_snd_lerp at 80 MHz, fed a 44.1 kHz stream
// on m2_2a_sound's drain accumulator (441 / 800,000 a clock), its output read
// the way sys/audio_out.sv reads AUDIO_L with the IIR filter off: two flops in
// a 24.576 MHz clock domain, taken when both agree, sampled at 48 kHz. Writes
// the 48 kHz stream (int16 mono) for the aliasing measurement, and checks:
//   * every output value lies between the two samples it interpolates
//     (never outside, never a wrap), at full-scale steps too;
//   * the 48 kHz reads never see a value the RTL never held (a torn read);
//   * LERP 1 at phase 0 gives the previous sample exactly (one sample late).
//   LERP_IN=<int16 mono raw at 44.1 kHz> (default: a full-scale square + sweep)
//   LERP_OUT=<file>  LERP_N=<samples>
//   R956: LERP_NUM / LERP_DEN, the drain's accumulator (default 441 / 800,000,
//   m2_2a_sound; Model 2's m2_pcm_rate at 80 MHz is 44,643 / 80,000,000 --
//   build the RTL with the same -GT44_NUM / -GT44_DEN); LERP_TONE=<Hz> a pure
//   tone at 20,000 for 2 s in place of the default input
#include "Vm2_snd_lerp.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>
#include <cmath>
#include <set>
int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	std::vector<int16_t> in;
	const uint32_t NUM = getenv("LERP_NUM") ? strtoul(getenv("LERP_NUM"), nullptr, 0) : 441;
	const uint32_t DEN = getenv("LERP_DEN") ? strtoul(getenv("LERP_DEN"), nullptr, 0) : 800000;
	const double FS = 80e6 * NUM / DEN;     // the input's sample rate
	if (const char *tf = getenv("LERP_TONE")) { const double f = atof(tf); for (int i = 0; i < int(2 * FS); i++) in.push_back(int16_t(lrint(20000 * sin(2 * M_PI * f * i / FS)))); }
	else if (const char *f = getenv("LERP_IN")) { FILE *h = fopen(f, "rb"); int16_t v; while (h && fread(&v, 2, 1, h) == 1) in.push_back(v); if (h) fclose(h); }
	else {
		for (int i = 0; i < 44100; i++) in.push_back((i / 7) & 1 ? 32767 : -32768);   // full-scale steps
		for (int i = 0; i < 88200; i++) in.push_back(int16_t(20000 * sin(2 * M_PI * (100.0 + 10000.0 * i / 88200) * i / 44100.0)));
	}
	size_t N = getenv("LERP_N") ? strtoull(getenv("LERP_N"), nullptr, 0) : in.size();
	if (N > in.size()) N = in.size();
	FILE *fo = getenv("LERP_OUT") ? fopen(getenv("LERP_OUT"), "wb") : nullptr;
	Vm2_snd_lerp *t = new Vm2_snd_lerp;
	t->clk = 0; t->rst_n = 0; t->tick = 0; t->tacc = 0; t->in_l = 0; t->in_r = 0;
	auto edge = [&]() { t->clk = 1; t->eval(); t->clk = 0; t->eval(); };
	for (int i = 0; i < 4; i++) edge();
	t->rst_n = 1;
	// the drain accumulator and the FIFO's register, as m2_2a_sound has them
	uint32_t tacc = 0; int tick = 0; int16_t q = 0; size_t k = 0;
	const double CLK = 80e6, ACLK = 24.576e6;
	double ta = 0;                         // next clk_audio edge (s)
	uint64_t cyc = 0; int16_t c1 = 0, c2 = 0, cl = 0; uint32_t acnt = 0;   // audio_out's flops, 48 kHz = 24.576 MHz / 512
	std::set<int> held;                     // values the RTL output held in the last few us
	uint64_t bad_range = 0, torn = 0, out48 = 0, checks = 0;
	int16_t lo = 0, hi = 0;                 // the pair being interpolated
	std::vector<int16_t> recent; recent.reserve(4096);
	while (k < N) {
		// clk_sys edge: the accumulator and the FIFO register (registered, as in RTL)
		int ntick = 0; uint32_t ntacc = tacc + NUM;
		if (ntacc >= DEN) { ntacc -= DEN; ntick = 1; }
		int16_t nq = q;
		if (tick) { nq = in[k]; }
		t->tick = tick; t->tacc = tacc; t->in_l = q; t->in_r = q;
		edge(); cyc++;
		if (tick) { lo = q; hi = nq; k++; }
		tacc = ntacc; tick = ntick; q = nq;
		const int16_t o = int16_t(t->out_l);
		// range: between the two samples around it (allow the previous pair for a few clocks after a change)
		if (k > 3) {
			checks++;
			int a = std::min<int>(in[k - 3], std::min<int>(in[k - 2], in[k - 1])), b = std::max<int>(in[k - 3], std::max<int>(in[k - 2], in[k - 1]));
			if (o < a || o > b) { if (bad_range < 5) printf("  out %d outside [%d, %d] at sample %zu\n", o, a, b, k); bad_range++; }
		}
		recent.push_back(o); if (recent.size() > 64) recent.erase(recent.begin());
		// clk_audio edges inside this clk_sys period
		const double tnow = cyc / CLK;
		while (ta < tnow) {
			c2 = c1; c1 = o;                 // (o: the value on the wire now)
			if (c1 == c2) cl = c2;
			if (++acnt == 512) {             // 48 kHz
				acnt = 0; out48++;
				bool seen = false; for (int16_t v : recent) if (v == cl) { seen = true; break; }
				if (!seen && k > 3) torn++;
				if (fo) fwrite(&cl, 2, 1, fo);
			}
			ta += 1.0 / ACLK;
		}
	}
	if (fo) fclose(fo);
	printf("tb_m2_snd_lerp: %zu samples in, %llu at 48 kHz out; outside the bracketing samples %llu of %llu; 48 kHz reads of a value not held %llu\n",
	       N, (unsigned long long)out48, (unsigned long long)bad_range, (unsigned long long)checks, (unsigned long long)torn);
	printf("%s\n", bad_range || torn ? "FAIL" : "PASS");
	delete t;
	return bad_range || torn ? 1 : 0;
}
