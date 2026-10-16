// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// scsp_randcap: a synthetic SCSP capture for tb_m2_scsp (study R856) -- the
// features no game's capture plays but whose code the drivers can reach (FM
// and the ring buffer, PCM16, the noise LFO, SSCTL 2 / 3, MOBUF), driven by
// random register writes and random sound RAM, with the reference's own mix
// (scsp_ref.h, MAME 0.289's scsp.cpp) as out.bin. The format is
// mame_p16_scsp.sh's: regs.bin {u32 n, u16 off, data, mask, pad}, ramw.bin
// {u32 n, u32 byte address, u32 data | mask << 16}, out.bin {s32 l, r}.
// A record with pad = 1 is a read the bench checks against the reference;
// midi.txt carries random MIDI-in bytes, for the interrupts.
//
//   scsp_randcap <dir> <seed> <samples> [noise hex]
//
// Not generated (not built, and unreachable in all four 2A drivers, R856):
// LPCTL 2 / 3, SSCTL 1, SDIR, DMA; the DSP (its own bench, random programs).
#include "scsp_ref.h"
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

using namespace scspref;

struct Rec { uint32_t n; uint16_t off, data, mask, pad; };
struct RamW { uint32_t n, a, dm; };

static uint64_t rs;
static uint32_t rnd() { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return uint32_t(rs >> 11); }
static uint32_t rr(uint32_t n) { return rnd() % n; }

int main(int argc, char **argv) {
	if (argc < 4) { fprintf(stderr, "usage: scsp_randcap <dir> <seed> <samples> [noise hex]\n"); return 2; }
	std::string d = argv[1];
	rs = 0x9e3779b97f4a7c15ull ^ (strtoull(argv[2], nullptr, 0) * 0x2545f4914f6cdd1dull);
	for (int i = 0; i < 8; i++) rnd();
	uint32_t N = strtoul(argv[3], nullptr, 0);
	static Tables T;
	if (argc > 4) {
		FILE *h = fopen(argv[4], "r");
		if (!h) { fprintf(stderr, "no %s\n", argv[4]); return 2; }
		static int an[256], pn[256];
		for (int i = 0; i < 256; i++) { unsigned v; if (fscanf(h, "%x", &v) != 1) { fprintf(stderr, "short noise\n"); return 2; } an[i] = int(v); pn[i] = 128 - int(v); }
		fclose(h);
		T.load_noise(an, pn);
	}
	static u16 ram[0x40000];
	SCSP R(T, ram);
	FILE *fr = fopen((d + "/regs.bin").c_str(), "wb"), *fw = fopen((d + "/ramw.bin").c_str(), "wb"), *fo = fopen((d + "/out.bin").c_str(), "wb");
	FILE *fm = fopen((d + "/midi.txt").c_str(), "w");   // (MIDI in reaches only the interrupts: the bench's own reference takes it)
	if (!fr || !fw || !fo) { fprintf(stderr, "cannot write %s\n", d.c_str()); return 2; }

	// sound RAM: random, with a few smooth stretches
	for (uint32_t w = 0; w < 0x40000; w++) {
		u16 v = (w & 0x2000) ? u16(rnd()) : u16(int(4000.0 * __builtin_sin(w * 0.05)) + int(rr(64)));
		ram[w] = v;
		RamW x = { 0, w * 2, uint32_t(v) | 0xffff0000u };
		fwrite(&x, sizeof x, 1, fw);
	}
	uint64_t nw = 0, nr = 0;
	auto wr = [&](uint32_t n, uint16_t off, uint16_t data, uint16_t mask) {
		R.write(off, data, mask);
		Rec r = { n, off, data, mask, 0 }; fwrite(&r, sizeof r, 1, fr); nw++;
	};
	auto rd = [&](uint32_t n, uint16_t off) {
		Rec r = { n, off, 0, 0xffff, 1 }; fwrite(&r, sizeof r, 1, fr); nr++;
	};
	auto mask = [&]() -> uint16_t { uint32_t k = rr(8); return k == 0 ? 0xff00 : k == 1 ? 0x00ff : 0xffff; };

	// the common registers: MVOL 15, DAC18B now and then
	wr(0, 0x400, 0x000f, 0xffff);
	uint32_t next = 0;
	for (uint32_t n = 0; n < N; n++) {
		// MIDI in from the main board, now and then (bursts of up to 3 bytes)
		if (fm && rr(400) == 0) for (uint32_t k = 1 + rr(3); k; k--) fprintf(fm, "%u in %02x\n", n, rr(256));
		while (n >= next) {
			uint32_t what = rr(100);
			int s = int(rr(32));
			uint16_t base = uint16_t(s * 0x20);
			if (what < 40) {
				// a slot programmed and keyed on: SA anywhere (sometimes past 512 KB),
				// LSA / LEA, PCM8 / 16, LPCTL 0 / 1, SSCTL 0 / 2 / 3, SBCTL
				uint32_t sa = rr(10) == 0 ? rr(0x100000) : rr(0x80000);
				uint16_t lea = uint16_t(rr(4) == 0 ? rr(0x10000) : rr(0x2000));
				uint16_t lsa = uint16_t(lea ? rr(lea) : 0);
				static const uint16_t ssc[4] = { 0, 0, 2, 3 };
				uint16_t w0 = uint16_t((sa >> 16) | (rr(2) << 4) | (rr(2) << 5) | (ssc[rr(4)] << 7) | (rr(4) << 9));
				wr(n, base + 0x02, uint16_t(sa), 0xffff);
				wr(n, base + 0x04, lsa, 0xffff);
				wr(n, base + 0x06, lea, 0xffff);
				// EG: rates, EGHOLD, KRS, DL, LPSLNK
				wr(n, base + 0x08, uint16_t(rnd()), 0xffff);
				wr(n, base + 0x0a, uint16_t(rnd() & 0x7fff), 0xffff);
				// TL (no SDIR), STWINH
				wr(n, base + 0x0c, uint16_t(rnd() & 0x2ff), 0xffff);
				// FM: MDL, MDXSL, MDYSL -- half the slots modulated
				wr(n, base + 0x0e, rr(2) ? uint16_t(rnd()) : 0, 0xffff);
				// pitch
				wr(n, base + 0x10, uint16_t(rnd() & 0x7fff), 0xffff);
				// LFO: all waves, noise included
				wr(n, base + 0x12, uint16_t(rnd()), 0xffff);
				wr(n, base + 0x14, uint16_t(rnd()), 0xffff);
				wr(n, base + 0x16, uint16_t(rnd()), 0xffff);
				wr(n, base + 0x00, uint16_t(w0 | 0x1800), 0xffff);   // KEYONB, KEYONEX
			} else if (what < 50) {
				// key off (KEYONEX on another slot's word)
				uint16_t w0 = R.r16(base);
				wr(n, base, uint16_t(w0 & ~0x800), 0xffff);
				int s2 = int(rr(32));
				wr(n, uint16_t(s2 * 0x20), uint16_t(R.r16(uint16_t(s2 * 0x20)) | 0x1000), 0xff00);
			} else if (what < 70) {
				// one slot register rewritten while it plays (byte or word)
				static const uint16_t wds[] = { 0x0a, 0x0c, 0x0e, 0x10, 0x12, 0x14, 0x16 };
				uint16_t o = wds[rr(7)];
				uint16_t v = uint16_t(rnd());
				if (o == 0x0c) v &= 0x2ff;            // no SDIR
				wr(n, base + o, v, mask());
			} else if (what < 82) {
				// the ring buffer from the 68000, word and byte
				wr(n, uint16_t(0x600 + 2 * rr(128)), uint16_t(rnd()), mask());
			} else if (what < 86) {
				// reads: a slot register, the ring
				rd(n, uint16_t(2 * rr(0x200)));
				rd(n, uint16_t(0x600 + 2 * rr(128)));
			} else if (what < 89) {
				// MOBUF (MIDI out), word and byte
				wr(n, 0x406, uint16_t(rnd()), mask());
			} else if (what < 90) {
				// MVOL / DAC18B
				wr(n, 0x400, uint16_t((rnd() & 0x10f)), 0xffff);
			} else if (what < 96) {
				// the timers, interrupts and monitor: MSLC, timers A / B / C (short
				// counts), SCIEB, SCIPD, SCIRE, SCILV0-2 -- word and byte
				static const uint16_t cr[] = { 0x408, 0x418, 0x41a, 0x41c, 0x41e, 0x420, 0x422, 0x424, 0x426, 0x428 };
				uint16_t o = cr[rr(10)];
				uint16_t v = uint16_t(rnd());
				// (the bits the SCSP defines; MAME keeps all 16 of a register, the
				// RTL only those, so undefined bits written would read back apart)
				if (o >= 0x418 && o <= 0x41c) v = uint16_t((v & 0x0700) | (rr(4) ? 0xc0 + rr(64) : rr(256)));
				else if (o >= 0x41e && o <= 0x422) v &= 0x07ff;
				else if (o >= 0x424) v &= 0x00ff;
				wr(n, o, v, mask());
			} else {
				// reads of the common registers (MIBUF pops, the monitor)
				static const uint16_t cr[] = { 0x400, 0x402, 0x404, 0x406, 0x408, 0x418, 0x41a, 0x41c, 0x41e, 0x420, 0x424, 0x426, 0x428 };
				rd(n, cr[rr(13)]);
			}
			next = n + 1 + rr(200);
		}
		s32 l, r;
		R.sample(l, r);
		s32 o[2] = { l, r };
		fwrite(o, sizeof o, 1, fo);
	}
	fclose(fr); fclose(fw); fclose(fo); if (fm) fclose(fm);
	printf("scsp_randcap %s: %u samples, %llu writes, %llu reads\n", d.c_str(), N, (unsigned long long)nw, (unsigned long long)nr);
	return 0;
}
