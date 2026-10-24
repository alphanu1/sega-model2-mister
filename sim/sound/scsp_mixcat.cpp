// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// scsp_mixcat <capture> <seconds> <scsp_lfonoise.hex> [t0 t1] -- THE MIX BY
// CATEGORY, MAME's MADRS mirror against R914's decode (the core), study R949.
// A p16 capture (regs.bin, ramw.bin) is replayed through scsp_ref.h in 18
// instances: the whole mix with MAME's mirror and with R914; and for each
// IMXL value 0..7 the same two again with only the slots at that IMXL feeding
// MIXS (mixs_mask). A category's level is its slots' direct sends plus the
// DSP return it alone produces, so what R914 does to each kind of voice is
// read off directly. Left channel, the DAC's 16-bit units, through a ~3.5 Hz
// DC blocker (MiSTer's is ~7 Hz; MAME 0.289's default chain a 20 Hz high-pass)
// so MAME's DC on VC2 / DOA does not count. Also the 95th percentile of 50 ms
// windows (how loud a category's events are). Over [t0, t1) seconds.
// Everything it writes is ROM-derived; keep it outside the repository.
#include "scsp_ref.h"
#include <cstdio>
#include <string>
#include <vector>
#include <algorithm>
using namespace scspref;
struct Inst { u16 ram[0x40000]; SCSP *s; };
int main(int argc, char **argv) {
	const std::string d = argv[1];
	const double secs = atof(argv[2]);
	const double t0 = argc > 5 ? atof(argv[4]) : 0, t1 = argc > 5 ? atof(argv[5]) : 1e9;
	static Tables T;
	if (FILE *h = fopen(argv[3], "r")) {
		static int an[256], pn[256];
		for (int i = 0; i < 256; i++) { unsigned v = 0; if (fscanf(h, "%x", &v) != 1) break; an[i] = int(v); pn[i] = 128 - int(v); }
		fclose(h); T.load_noise(an, pn);
	} else return 2;
	const int NC = 8;   // categories: IMXL 0..7
	const int NI = 2 + 2 * NC;
	std::vector<Inst *> I(NI);
	for (int k = 0; k < NI; k++) { I[k] = new Inst; for (auto &w : I[k]->ram) w = 0xffff; I[k]->s = new SCSP(T, I[k]->ram); I[k]->s->madrs_mirror = (k == 0) || (k >= 2 && ((k - 2) & 1) == 0); }
	FILE *fr = fopen((d + "/regs.bin").c_str(), "rb"), *fm = fopen((d + "/ramw.bin").c_str(), "rb");
	struct RR { uint32_t n; uint16_t off, data, mask, pad; } rr; struct MW { uint32_t n, a, dm; } mw;
	bool hr = fread(&rr, sizeof rr, 1, fr) == 1, hm = fread(&mw, sizeof mw, 1, fm) == 1;
	const uint64_t N = uint64_t(secs * 44100);
	// energies over [t0, t1): per category dir, M ret, C ret, M tot, C tot (left, 16-bit units); whole mix M, C
	double E[NC][5] = {{0}}, EM = 0, EC = 0; uint64_t cnt = 0;
	// transient loudness: 50 ms windows, per category M tot / C tot
	const int W50 = 2205; double w50[NC][2] = {{0}}; std::vector<double> win[NC][2];
	double slotsamp[NC] = {0};
	struct HP { double x = 0, y = 0; double f(double v) { y = v - x + 0.9995 * y; x = v; return y; } } hpM, hpC, hp[NC][5];   // ~3.5 Hz DC blocker (MiSTer's is ~7 Hz)
	for (uint64_t n = 0; n < N; n++) {
		for (; hr && rr.n <= n; hr = fread(&rr, sizeof rr, 1, fr) == 1) { if (rr.pad) continue; for (auto *x : I) x->s->write(rr.off, rr.data, rr.mask); }
		for (; hm && mw.n <= n; hm = fread(&mw, sizeof mw, 1, fm) == 1) {
			const u32 a = (mw.a & 0x7fffe) >> 1; const u16 v = mw.dm & 0xffff, m = u16(mw.dm >> 16);
			for (auto *x : I) { u16 &w = x->ram[a]; w = u16((w & ~m) | (v & m)); }
		}
		u32 mask[NC] = {0};
		for (int sl = 0; sl < 32; sl++) mask[SCSP::IMXL(&I[0]->s->S[sl])] |= 1u << sl;
		for (int c = 0; c < NC; c++) { I[2 + 2 * c]->s->mixs_mask = mask[c]; I[3 + 2 * c]->s->mixs_mask = mask[c]; }
		s32 l[64], r[64];
		for (int k = 0; k < NI; k++) { I[k]->s->sample(l[k], r[k]); I[k]->s->tick(); }
		const double tn = n / 44100.0;
		SCSP &C = *I[1]->s;
		const double om = hpM.f(l[0] / 4.0), oc = hpC.f(l[1] / 4.0);
		double cd[NC], crm[NC], crc[NC];
		for (int c = 0; c < NC; c++) { double dir = 0; for (int sl = 0; sl < 32; sl++) if ((mask[c] >> sl) & 1) dir += C.slot_dl[sl]; dir /= 4;
			cd[c] = hp[c][0].f(dir); crm[c] = hp[c][1].f(I[2 + 2 * c]->s->efx_l / 4.0); crc[c] = hp[c][2].f(I[3 + 2 * c]->s->efx_l / 4.0); }
		if (tn < t0 || tn >= t1) continue;
		cnt++;
		EM += om * om; EC += oc * oc;
		for (int c = 0; c < NC; c++) {
			for (int sl = 0; sl < 32; sl++) if (((mask[c] >> sl) & 1) && C.slot_was_active[sl]) slotsamp[c]++;
			const double dir = cd[c], rm = crm[c], rc = crc[c];
			const double tm = dir + rm, tc = dir + rc;
			E[c][0] += dir * dir; E[c][1] += rm * rm; E[c][2] += rc * rc; E[c][3] += tm * tm; E[c][4] += tc * tc;
			w50[c][0] += tm * tm; w50[c][1] += tc * tc;
		}
		if (cnt % W50 == 0) for (int c = 0; c < NC; c++) { for (int j = 0; j < 2; j++) { win[c][j].push_back(std::sqrt(w50[c][j] / W50)); w50[c][j] = 0; } }
	}
	auto db = [](double a, double b) { return (a > 0 && b > 0) ? 10 * std::log10(a / b) : 0.0; };
	printf("whole mix: MAME %.0f  core %.0f  %+.1f dB  (%.1f s)\n", std::sqrt(EM / cnt), std::sqrt(EC / cnt), db(EC, EM), cnt / 44100.0);
	printf("IMXL  slot-s   direct  ret MAME  ret core   tot MAME  tot core   dB    | 50 ms p95 MAME / core  dB\n");
	for (int c = 0; c < NC; c++) {
		if (slotsamp[c] == 0) continue;
		auto p95 = [&](std::vector<double> v) { if (v.empty()) return 0.0; std::sort(v.begin(), v.end()); return v[size_t(v.size() * 0.95)]; };
		const double a = p95(win[c][0]), b = p95(win[c][1]);
		printf("%4d %8.1f %8.0f %9.0f %9.0f %10.0f %9.0f %+6.1f | %8.0f %8.0f %+6.1f\n", c, slotsamp[c] / 44100.0, std::sqrt(E[c][0] / cnt), std::sqrt(E[c][1] / cnt), std::sqrt(E[c][2] / cnt),
		       std::sqrt(E[c][3] / cnt), std::sqrt(E[c][4] / cnt), db(E[c][4], E[c][3]), a, b, (a > 0 && b > 0) ? 20 * std::log10(b / a) : 0.0);
	}
	return 0;
}
