// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R909: m2_scsp_lfo (the waves in logic, the scales in a 4,096 x 9 ROM)
// against the 16,384 x 9 ROM it replaced -- scsp_lfo.hex as f7437e2 built it
// (`ref.hex` here, from git) -- and against MAME's own tables (scsp_ref.h with
// MAME's noise, scsp_lfonoise.hex), which is how that ROM was generated.
//
// Every tadr in order, then +n=<cycles> random ones (default 4,000,000), each
// standing at one edge: tbl_q must then be the old ROM's word for it, and hold
// it until the next edge. The module has no other inputs and no state but its
// address and output registers, so the 16,384 words are the whole function;
// the random run checks the latency.
#include "Vm2_scsp_lfo.h"
#include "verilated.h"
#include "scsp_ref.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>

using namespace scspref;

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	long n = 4000000;
	for (int i = 1; i < argc; i++)
		if (!std::strncmp(argv[i], "+n=", 3)) n = std::atol(argv[i] + 3);

	static int old[16384];
	FILE *h = fopen("ref.hex", "r");
	if (!h) { std::printf("no ref.hex (the old ROM)\nFAIL\n"); return 1; }
	for (int i = 0; i < 16384; i++) { unsigned v; if (fscanf(h, "%x", &v) != 1) { std::printf("ref.hex short\nFAIL\n"); return 1; } old[i] = int(v); }
	fclose(h);

	// MAME's tables, the way scsp_tables_gen built the old ROM
	static Tables T;
	static int an[256];
	h = fopen("scsp_lfonoise.hex", "r");
	if (!h) { std::printf("no scsp_lfonoise.hex\nFAIL\n"); return 1; }
	for (int i = 0; i < 256; i++) { unsigned v; if (fscanf(h, "%x", &v) != 1) { std::printf("noise short\nFAIL\n"); return 1; } an[i] = int(v); }
	fclose(h);
	long mame_bad = 0;
	const int *flat = &T.PSCALES[0][0];
	for (int k = 0; k < 16384; k++) {
		int sel = k >> 13, s = (k >> 10) & 7, w = (k >> 8) & 3, i = k & 255, v;
		if (sel == 0) {
			int p = w == 0 ? T.PLFO_SAW[i] : w == 1 ? T.PLFO_SQR[i] : w == 2 ? T.PLFO_TRI[i] : 128 - an[i];
			v = flat[s * 256 + p + 128];
		} else {
			int a = w == 0 ? T.ALFO_SAW[i] : w == 1 ? T.ALFO_SQR[i] : w == 2 ? T.ALFO_TRI[i] : an[i];
			v = T.ASCALES[s][a];
		}
		if (v != old[k]) mame_bad++;
	}

	auto *d = new Vm2_scsp_lfo;
	uint32_t rs = 12345;
	auto rnd = [&]() { rs = rs * 1664525u + 1013904223u; return rs >> 8; };
	long checks = 0, fails = 0, seen[2] = {0, 0};
	d->clk = 0; d->tadr = 0; d->eval();
	const long total = 16384 + n;
	// tadr is the engine's register: the value standing at an edge is the
	// address that edge reads, and tbl_q holds its word until the next.
	for (long c = 0; c < total; c++) {
		int t = c < 16384 ? int(c) : int(rnd() & 0x3fff);
		d->tadr = t; d->eval();
		d->clk = 1; d->eval();
		d->clk = 0; d->eval();
		checks++;
		if (int(d->tbl_q) != old[t]) {
			if (++fails <= 10) std::printf("  FAIL clk %ld: tadr %04x -> %03x, old ROM %03x\n", c, t, d->tbl_q, old[t]);
		} else seen[t >> 13]++;
		// and nothing moves without an edge
		d->tadr = (t + 1) & 0x3fff; d->eval();
		if (int(d->tbl_q) != old[t]) { if (++fails <= 10) std::printf("  FAIL clk %ld: tbl_q moved between edges\n", c); }
	}
	std::printf("m2_scsp_lfo: old ROM against MAME's tables: %ld of 16384 differ\n", mame_bad);
	std::printf("m2_scsp_lfo: %ld clocks compared (16,384 in order, %ld random), %ld fails (pitch %ld / amplitude %ld agree)\n%s\n",
	            checks, n, fails, seen[0], seen[1], (fails || mame_bad) ? "FAIL" : "PASS");
	delete d;
	return (fails || mame_bad) ? 1 : 0;
}
