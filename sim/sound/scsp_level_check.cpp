// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// THE SCSP's LEVEL WORD WITHOUT MAME's 64 K-ENTRY TABLE (study R856).
// MAME's LPANTABLE / RPANTABLE[TL | PAN << 8 | SDL << 13] is
// FIX(4.0f * LPAN * TL * fSDL): three single-precision factors multiplied in
// float, scaled by 4096 and truncated. This evaluates the same word the way
// the RTL will: each factor as a 24-bit mantissa and an exponent (from 256 +
// 16 + 8 entry tables), two integer mantissa products each rounded to 24 bits
// nearest-even exactly as an IEEE single multiply rounds, then the shift and
// the truncation. Checked against the table MAME builds, every entry.
// Also writes the three factor tables as the RTL ROM (scsp_lvl.hex).
//
//   scsp_level_check [rtl dir]   (writes the factor ROM scsp_lvl.hex there)
#include "scsp_ref.h"
#include <cstdio>
#include <cstring>

using namespace scspref;

struct F { uint32_t m; int e; bool zero; };   // value = m * 2^(e-23), m in [2^23, 2^24)

static F split(float f) {
	F r; uint32_t b; memcpy(&b, &f, 4);
	if (f == 0.0f) { r.m = 0; r.e = 0; r.zero = true; return r; }
	r.zero = false; r.m = (b & 0x7fffff) | 0x800000; r.e = int((b >> 23) & 0xff) - 127;
	return r;
}
// IEEE single multiply, round to nearest even (normal operands, no overflow)
static F fmul(F a, F b) {
	F r; if (a.zero || b.zero) { r.zero = true; r.m = 0; r.e = 0; return r; }
	r.zero = false;
	uint64_t p = uint64_t(a.m) * b.m;            // [2^46, 2^48)
	int e = a.e + b.e;
	int sh;
	if (p >> 47) { sh = 24; e += 1; } else sh = 23;
	uint64_t q = p >> sh, rem = p & ((1ull << sh) - 1), half = 1ull << (sh - 1);
	if (rem > half || (rem == half && (q & 1))) q++;
	if (q >> 24) { q >>= 1; e++; }
	r.m = uint32_t(q); r.e = e;
	return r;
}
// (u32)(4096.0f * (4.0f * x)): x * 2^14, truncated
static uint32_t fix14(F x) {
	if (x.zero) return 0;
	int s = x.e + 14 - 23;                      // value = m * 2^s
	if (s >= 0) return x.m << s;
	if (s <= -32) return 0;
	return x.m >> -s;
}

int main(int argc, char **argv) {
	static Tables T;
	float TLf[256], PANf[16], SDLf[8];
	for (int iTL = 0; iTL < 256; iTL++) {
		float SegaDB = 0.0f;
		if (iTL & 0x01) SegaDB -= 0.4f;
		if (iTL & 0x02) SegaDB -= 0.8f;
		if (iTL & 0x04) SegaDB -= 1.5f;
		if (iTL & 0x08) SegaDB -= 3.0f;
		if (iTL & 0x10) SegaDB -= 6.0f;
		if (iTL & 0x20) SegaDB -= 12.0f;
		if (iTL & 0x40) SegaDB -= 24.0f;
		if (iTL & 0x80) SegaDB -= 48.0f;
		TLf[iTL] = powf(10.0f, SegaDB / 20.0f);
	}
	for (int p = 0; p < 16; p++) {
		float SegaDB = 0;
		if (p & 0x1) SegaDB -= 3.0f;
		if (p & 0x2) SegaDB -= 6.0f;
		if (p & 0x4) SegaDB -= 12.0f;
		if (p & 0x8) SegaDB -= 24.0f;
		PANf[p] = (p == 0xf) ? 0.0f : powf(10.0f, SegaDB / 20.0f);
	}
	for (int s = 0; s < 8; s++) SDLf[s] = s ? powf(10.0f, SDLT[s] / 20.0f) : 0.0f;
	int bad = 0;
	for (int i = 0; i < 0x10000; i++) {
		int iTL = i & 0xff, iPAN = (i >> 8) & 0x1f, iSDL = (i >> 13) & 7;
		F one = split(1.0f), pan = split(PANf[iPAN & 15]);
		F L = iPAN < 0x10 ? pan : one, R = iPAN < 0x10 ? one : pan;
		F tl = split(TLf[iTL]), sdl = split(SDLf[iSDL]);
		uint32_t vl = fix14(fmul(fmul(L, tl), sdl)), vr = fix14(fmul(fmul(R, tl), sdl));
		if (int(vl) != T.LPANTABLE[i] || int(vr) != T.RPANTABLE[i]) {
			if (bad < 10) printf("  enc %04x: L %u (MAME %d)  R %u (MAME %d)\n", i, vl, T.LPANTABLE[i], vr, T.RPANTABLE[i]);
			bad++;
		}
	}
	printf("level word, all 65,536 encodings x 2 sides: %d differ from MAME's table\n", bad);
	if (argc > 1) {
		// The RTL's factors: {-exponent (5 bits), mantissa without the hidden bit (23)}. PAN 15
		// and SDL 0 are the zeros, decoded by the RTL. TL is a ROM image (256 x 28); PAN and SDL
		// are functions.
		// One ROM image, 512 x 28: TL 0-255, PAN 256-271, SDL 272-279, the rest 0.
		std::string dir = argv[1];
		FILE *o = fopen((dir + "/scsp_lvl.hex").c_str(), "w");
		for (int k = 0; k < 512; k++) {
			float v = k < 256 ? TLf[k] : k < 272 ? PANf[k - 256] : k < 280 ? SDLf[k - 272] : 0.0f;
			F f = split(v);
			if (!f.zero && (f.e > 0 || f.e < -31)) { fprintf(stderr, "factor out of range\n"); return 3; }
			fprintf(o, "%07x\n", f.zero ? 0u : (unsigned(-f.e) << 23) | (f.m & 0x7fffff));
		}
		fclose(o);
	}
	return bad != 0;
}
