// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// tb_m2_scsp_level: m2_scsp_level against MAME's LPANTABLE / RPANTABLE
// (scsp_ref.h's, equal to MAME's dump), every encoding (study R856).
// For each Enc = TL | PAN << 8 | SDL << 13: words 0 / 1 (direct) with TL,
// DIPAN, DISDL; word 2 (DSP send) with TL and IMXL = SDL (pan 0); words 3 / 4
// (effect) with EFPAN = PAN, EFSDL = SDL against Enc with TL 0; and SDIR set
// on every 7th request (TL must read as 0). The slot cycles 0..31 so every
// RAM row is written and read back.
#include "Vm2_scsp_level.h"
#include "verilated.h"
#include "scsp_ref.h"
#include <cstdio>

using namespace scspref;

static Vm2_scsp_level *t;
static void tick() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); }

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);
	static Tables T;
	t = new Vm2_scsp_level;
	t->rst_n = 0; t->req = 0; tick(); tick(); t->rst_n = 1; tick();
	long bad = 0, checks = 0;
	for (int enc = 0; enc < 0x10000; enc++) {
		int tl = enc & 0xff, pan = (enc >> 8) & 31, sdl = (enc >> 13) & 7;
		int slot = enc & 31;
		bool sdir = (enc % 7) == 3;
		t->req_slot = slot;
		t->req_w6  = (sdir ? 0x100 : 0) | tl | 0x200;          // STWINH set, ignored
		t->req_w10 = (enc & 0x78) | sdl;                        // ISEL junk, IMXL
		t->req_w11 = (sdl << 13) | (pan << 8) | (sdl << 5) | pan;
		t->req = 1; tick(); t->req = 0;
		int n = 0;
		while (t->busy) { tick(); if (++n > 100) { printf("FAIL: hung\n"); return 1; } }
		int got[5];
		for (int k = 0; k < 5; k++) { t->rd_addr = (slot << 3) | k; tick(); got[k] = t->rd_q; }
		int etl = sdir ? 0 : tl;
		int e0 = etl | (pan << 8) | (sdl << 13);
		int e2 = etl | (sdl << 13);
		int e3 = (pan << 8) | (sdl << 13);
		int want[5] = { T.LPANTABLE[e0], T.RPANTABLE[e0], T.LPANTABLE[e2], T.LPANTABLE[e3], T.RPANTABLE[e3] };
		for (int k = 0; k < 5; k++) {
			checks++;
			if (got[k] != want[k]) { if (bad < 10) printf("  enc %04x sdir %d word %d: %d want %d\n", enc, sdir, k, got[k], want[k]); bad++; }
		}
	}
	printf("m2_scsp_level: %ld words checked, %ld wrong\n", checks, bad);
	printf("%s\n", bad ? "FAIL" : "PASS");
	return bad ? 1 : 0;
}
