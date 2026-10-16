// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// scsp_replay <dir> [samples] -- MAME's SCSP, re-run outside MAME (study R856).
//
// <dir> is one p16 capture (build/mame_patches/p16.sh, M2SCSP_OUT): every
// register write and every 68000 sound-RAM write, each applied before the
// sample MAME logged it against, drive scsp_ref.h (MAME's scsp.cpp, ported),
// and every sample of the mix is compared with MAME's own (out.bin).
// Also: MAME's derived tables (tables.bin) against the port's, and what the
// sound RAM is asked for -- slot sample lines and DSP words -- under candidate
// caches, for the design's bandwidth figures.
#include "scsp_ref.h"
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <string>
#include <map>

using namespace scspref;

struct Rec { uint32_t n; uint16_t off, data, mask, pad; };
struct RamW { uint32_t n, a, dm; };

template <class T> struct Stream {
	FILE *f; T cur; bool ok;
	Stream(const std::string &p) { f = fopen(p.c_str(), "rb"); ok = f && fread(&cur, sizeof(T), 1, f) == 1; }
	void next() { ok = fread(&cur, sizeof(T), 1, f) == 1; }
};

int main(int argc, char **argv) {
	if (argc < 2) { fprintf(stderr, "usage: scsp_replay <dir> [samples]\n"); return 2; }
	std::string d = argv[1];
	uint64_t limit = argc > 2 ? strtoull(argv[2], nullptr, 0) : ~0ull;
	static Tables T;
	// ---- the tables, against MAME's own
	{
		FILE *t = fopen((d + "/tables.bin").c_str(), "rb");
		if (!t) { fprintf(stderr, "no tables.bin\n"); return 2; }
		static s32 eg[0x400]; static int lp[0x10000], rp[0x10000], ar[64], dr[64], ps[8][256], as[8][256], an[256], pn[256];
		bool ok = fread(eg, sizeof eg, 1, t) && fread(lp, sizeof lp, 1, t) && fread(rp, sizeof rp, 1, t) && fread(ar, sizeof ar, 1, t) && fread(dr, sizeof dr, 1, t)
			&& fread(ps, sizeof ps, 1, t) && fread(as, sizeof as, 1, t) && fread(an, sizeof an, 1, t) && fread(pn, sizeof pn, 1, t);
		fclose(t);
		if (!ok) { fprintf(stderr, "short tables.bin\n"); return 2; }
		int bad = 0;
		bad += memcmp(eg, T.EG_TABLE, sizeof eg) != 0; bad += 2 * (memcmp(lp, T.LPANTABLE, sizeof lp) != 0); bad += 4 * (memcmp(rp, T.RPANTABLE, sizeof rp) != 0);
		bad += 8 * (memcmp(ar, T.ARTABLE, sizeof ar) != 0); bad += 16 * (memcmp(dr, T.DRTABLE, sizeof dr) != 0);
		bad += 32 * (memcmp(ps, T.PSCALES, sizeof ps) != 0); bad += 64 * (memcmp(as, T.ASCALES, sizeof as) != 0);
		printf("tables: %s (mask %d)\n", bad ? "DIFFER from MAME" : "identical to MAME's", bad);
		T.load_noise(an, pn);
	}
	static u16 ram[0x40000];
	memset(ram, 0, sizeof ram);
	SCSP C(T, ram);
	Stream<Rec> regs(d + "/regs.bin");
	Stream<RamW> rw(d + "/ramw.bin");
	FILE *fo = fopen((d + "/out.bin").c_str(), "rb");
	if (!fo) { fprintf(stderr, "no out.bin\n"); return 2; }

	// ---- cache models: what the sound RAM is asked for
	// slots: direct-mapped, 8-byte lines, by byte address; next line prefetched on use
	struct DM { std::vector<int64_t> tag; int lines, lb; uint64_t acc = 0, miss = 0;
		DM(int l, int lbits) : tag(l, -1), lines(l), lb(lbits) {}
		bool look(uint32_t a) { acc++; int64_t ln = a >> lb; int i = ln & (lines - 1); if (tag[i] == ln) return true; miss++; tag[i] = ln; return false; }
		void inval(uint32_t a) { int64_t ln = a >> lb; int i = ln & (lines - 1); if (tag[i] == ln) tag[i] = -1; } };
	DM slotc(256, 3), dspc(64, 3);
	// DSP: direct-mapped by word address, 4-word lines (one SDRAM burst); writes patch a present line
	static std::vector<DM> dsp_models = { DM(32, 3), DM(64, 3), DM(128, 3), DM(256, 3) };
	struct Ctx { DM *slot; std::vector<DM> *dsp; uint64_t sb = 0, sw = 0, dr = 0, dw = 0; } ctx{&slotc, &dsp_models};
	C.hook_ctx = &ctx;
	C.mem_hook = [](void *c, int k, u32 a) {
		Ctx *x = (Ctx *)c;
		if (k == 0 || k == 1) { x->slot->look(a & 0xfffff); }
		else if (k == 2) { for (auto &m : *x->dsp) m.look(a); x->dr++; }
		else { x->dw++; if (getenv("DSP_WINV")) for (auto &m : *x->dsp) m.inval(a); }
	};
	uint64_t wrong = 0, first_wrong = ~0ull, n = 0, nz = 0, maxd = 0;
	s32 o[2];
	uint64_t slot_bytes = 0;
	while (n < limit && fread(o, sizeof o, 1, fo) == 1) {
		while (regs.ok && regs.cur.n <= n) { C.write(regs.cur.off, regs.cur.data, regs.cur.mask); regs.next(); }
		while (rw.ok && rw.cur.n <= n) {
			uint32_t a = rw.cur.a & 0x7fffe; uint16_t dv = rw.cur.dm & 0xffff, m = rw.cur.dm >> 16;
			ram[a >> 1] = (ram[a >> 1] & ~m) | (dv & m);
			slotc.inval(a); for (auto &m : dsp_models) m.inval(a);
			rw.next();
		}
		uint64_t r0 = C.dsp_reads;
		s32 l, r; C.sample(l, r);
		(void)r0;
		if (l || r) nz++;
		if (l != o[0] || r != o[1]) {
			if (!wrong) first_wrong = n;
			wrong++;
			uint64_t dd = std::max<int64_t>(llabs((int64_t)l - o[0]), llabs((int64_t)r - o[1]));
			if (dd > maxd) maxd = dd;
			if (wrong <= 5) printf("  sample %llu: ref %d %d  MAME %d %d\n", (unsigned long long)n, l, r, o[0], o[1]);
		}
		n++;
	}
	printf("%s: %llu samples (%.1f s), %llu non-zero, %llu differ from MAME (first %lld, max |d| %llu)\n", d.c_str(), (unsigned long long)n, n / 44100.0,
		(unsigned long long)nz, (unsigned long long)wrong, wrong ? (long long)first_wrong : -1LL, (unsigned long long)maxd);
	printf("  slot sample reads %llu (%.1f a sample); 256 x 8-byte direct-mapped lines: miss %.2f%% = %.2f line fetches a sample\n",
		(unsigned long long)slotc.acc, slotc.acc / double(n), 100.0 * slotc.miss / std::max<uint64_t>(1, slotc.acc), slotc.miss / double(n));
	for (auto &m : dsp_models) printf("  DSP read cache %3d x 4 words: miss %.2f%% = %.2f fetches a sample\n", m.lines, 100.0 * m.miss / std::max<uint64_t>(1, m.acc), m.miss / double(n));
	printf("  DSP reads %llu (%.2f a sample), writes %llu (%.2f a sample)\n", (unsigned long long)C.dsp_reads, C.dsp_reads / double(n),
		(unsigned long long)C.dsp_writes, C.dsp_writes / double(n));
	return wrong ? 1 : 0;
}
