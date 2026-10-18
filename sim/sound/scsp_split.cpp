// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// scsp_split <trace> -- the free-running SCSP, replayed through scsp_ref.h
// (study R885).
//
// The trace is the engine's own view of a free-running run (tb_m2_2a_sound
// built with -DM2_SND_TRACE, +sndtrace=<file>): each 68000 register access
// and each sound-RAM write with the sample the engine applied it in and where
// in that sample (before slot 0..31, or after the slots), and every sample the
// engine made. Here the reference -- MAME's scsp.cpp, ported -- is given the
// same accesses at the same places and its mix compared with the engine's,
// sample for sample. Equal: the engine computes what MAME's would from what
// it was given, and any difference from MAME's capture is in what the 68000
// gave it. Not equal: the free-running engine departs from MAME's semantics.
//
//   SPLIT_MODE=split   each access where the engine applied it (default)
//              whole   every access of sample n before its slot 0 (MAME's way)
//   SPLIT_MID=after    a RAM write landing inside slot s counts after s (default)
//             before   ... before s
//   SPLIT_RAMFILL=<w>  unwritten sound RAM (default 0xffff, as the bench)
//   SPLIT_OUT=<file>   the reference's mix, int32 L / R a sample
//   SPLIT_SHOW=<n>     how many differences to print (default 12)
//   lfonoise: scsp_lfonoise.hex in the working directory (MAME's noise)
//
// Also counted: 0x408 reads whose latch was made for another slot than MSLC
// selects (the engine's own latch, before R885) and, for Q records (R885's
// 0x408 reads, answered in the 68000's time), latches for another slot than
// the 68000 last selected; and slot reads of a sound-RAM word the 68000 wrote
// twice since the slot last read it -- a streamed ring overwritten ahead of
// its reader. sim/sound/scsp_cap2tr.py turns MAME's own capture into a trace
// (every access before slot 0, MAME's mix as the samples) for the same counts.
#include "scsp_ref.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <cmath>

using namespace scspref;

struct Ev { char k; int pos; uint32_t a; uint32_t d; int be; uint16_t m; };

static SCSP *R;
static uint16_t ram[0x40000];
struct EvN { uint64_t n; Ev e; };
static std::vector<Ev> evs;            // this sample's accesses
static std::vector<EvN> pend;          // read, not yet made (the sample record is logged a clock after the next
                                       // sample's first access can be)
static bool whole = false, mid_after = true;
static uint64_t rd_checks = 0, rd_bad = 0, wr_n = 0, ram_n = 0, mid_n = 0;
static int show = 12;
// the 0x408 monitor: a read whose latch was made with another MSLC than the one last written
// (the driver selects a slot, waits ~one sample, reads its CA / SGC / EG)
static int lat_used = -1;
static uint64_t mon_stale_ca = 0;
static uint64_t mon_reads = 0, mon_stale = 0, q_reads = 0, q_other = 0;
static uint64_t cur_n = 0;

static uint8_t wsince[0x40000];        // 68000 writes to each word since a slot last read it
static int place(const Ev &e) {
	if (whole) return 0;
	if (e.pos >= 64) return (e.pos - 64) + (mid_after ? 1 : 0);
	return e.pos;
}

static void apply(const Ev &e) {
	switch (e.k) {
	case 'W': {
		const uint16_t m = uint16_t(((e.be & 2) ? 0xff00 : 0) | ((e.be & 1) ? 0x00ff : 0));
		R->write(e.a << 1, uint16_t(e.d), m); wr_n++;
		break;
	}
	case 'R': {
		const uint32_t off = e.a << 1;
		if (off == 0x404 || off == 0x405) break;           // MIDI in: not fed here
		if (off == 0x408) {
			mon_reads++;
			if (lat_used != int(R->latched_MSLC)) {
				mon_stale++;
				// the CA bit the driver tests (bit 7), against the selected slot's own now
				const u32 ca = (R->S[R->latched_MSLC].cur_addr >> (SHIFT + 12)) & 1;
				if (((R->latched_MSLC_data >> 7) & 1) != ca) mon_stale_ca++;
			}
		}
		const uint16_t v = R->r16(off);
		if (off < 0x400 || off == 0x408) {
			rd_checks++;
			if (v != uint16_t(e.d)) {
				if (rd_bad < uint64_t(show)) printf("  sample %llu pos %d: read %03x engine %04x reference %04x\n", (unsigned long long)cur_n, e.pos, off, e.d, v);
				rd_bad++;
			}
		}
		break;
	}
	case 'M': {
		uint16_t &w = ram[e.a & 0x3ffff];
		w = uint16_t((w & ~e.m) | (e.d & e.m)); ram_n++; if (e.pos >= 64) mid_n++;
		if (wsince[e.a & 0x3ffff] < 255) wsince[e.a & 0x3ffff]++;
		break;
	}
	default: break;
	}
}

// a slot reads a sound-RAM word written twice by the 68000 since the slot last read it:
// the data of a later lap of a streamed ring, played early (an overwrite ahead of the reader)
static uint64_t sl_reads = 0, sl_twice = 0, sl_fresh = 0;
static std::vector<uint64_t> wtwice;
static void memhook(void *, int k, u32 a) {
	if (k > 1) return;
	const u32 w = (a & 0x7ffff) >> 1;
	sl_reads++;
	if (wsince[w] >= 2) { sl_twice++; const uint64_t i = cur_n / 22050; if (wtwice.size() <= i) wtwice.resize(i + 1, 0); wtwice[i]++; }
	if (wsince[w]) sl_fresh++;
	wsince[w] = 0;
}

static void hook(void *, int pos) {
	for (const Ev &e : evs) if (place(e) == pos) apply(e);
}

int main(int argc, char **argv) {
	if (argc < 2) { fprintf(stderr, "usage: scsp_split <trace>\n"); return 2; }
	const char *mode = getenv("SPLIT_MODE");
	whole = mode && !strcmp(mode, "whole");
	const char *mid = getenv("SPLIT_MID");
	mid_after = !(mid && !strcmp(mid, "before"));
	if (getenv("SPLIT_SHOW")) show = atoi(getenv("SPLIT_SHOW"));
	const uint16_t fill = getenv("SPLIT_RAMFILL") ? uint16_t(strtoul(getenv("SPLIT_RAMFILL"), nullptr, 0)) : 0xffff;
	for (auto &w : ram) w = fill;

	static Tables T;
	if (FILE *h = fopen("scsp_lfonoise.hex", "r")) {
		static int an[256], pn[256];
		for (int i = 0; i < 256; i++) { unsigned v = 0; if (fscanf(h, "%x", &v) != 1) break; an[i] = int(v); pn[i] = 128 - int(v); }
		fclose(h);
		T.load_noise(an, pn);
	} else fprintf(stderr, "warning: no scsp_lfonoise.hex here\n");
	static SCSP ref(T, ram);
	R = &ref;
	R->slot_hook = hook;
	R->mem_hook = memhook;

	FILE *f = fopen(argv[1], "r");
	if (!f) { fprintf(stderr, "no trace %s\n", argv[1]); return 2; }
	FILE *fo = getenv("SPLIT_OUT") ? fopen(getenv("SPLIT_OUT"), "wb") : nullptr;
	char line[256];
	uint64_t samples = 0, bad = 0, nz = 0, tag_bad = 0;
	int64_t first_bad = -1;
	const uint64_t WIN = 22050;
	std::vector<uint64_t> wbad; std::vector<double> wdiff, wsig;
	while (fgets(line, sizeof line, f)) {
		char k = line[0];
		if (k == 'O') {
			unsigned long long n; long long l, r;
			if (sscanf(line + 2, "%llu %lld %lld", &n, &l, &r) != 3) continue;
			cur_n = n;
			if (n != samples) { if (tag_bad < 5) printf("  sample index %llu, expected %llu\n", n, (unsigned long long)samples); tag_bad++; }
			evs.clear();
			{
				std::vector<EvN> keep;
				for (const EvN &x : pend) {
					if (x.n == n) evs.push_back(x.e);
					else if (x.n > n) keep.push_back(x);
					else { if (tag_bad < 5) printf("  %c tagged sample %llu, after it was made\n", x.e.k, (unsigned long long)x.n); tag_bad++; }
				}
				pend.swap(keep);
			}
			s32 rl, rr;
			R->sample(rl, rr);
			lat_used = R->latched_MSLC;
			R->tick();
			for (const Ev &e : evs) if (place(e) > 32) apply(e);   // (none: a write inside slot 31 counts at 32)
			evs.clear();
			if (fo) { s32 o[2] = {rl, rr}; fwrite(o, sizeof o, 1, fo); }
			const uint64_t w = n / WIN;
			if (wbad.size() <= w) { wbad.resize(w + 1, 0); wdiff.resize(w + 1, 0); wsig.resize(w + 1, 0); }
			if (rl || rr) nz++;
			const double dl = double(rl) - double(l);
			wdiff[w] += dl * dl; wsig[w] += double(rl) * double(rl);
			if (rl != l || rr != r) {
				if (bad < uint64_t(show)) printf("  sample %llu: engine %lld %lld  reference %d %d\n", n, l, r, rl, rr);
				if (first_bad < 0) first_bad = int64_t(n);
				bad++; wbad[w]++;
			}
			samples++;
			continue;
		}
		Ev e{};
		e.k = k;
		unsigned long long n; int pos; unsigned a, d; int be = 3;
		unsigned msk = 0xffff;
		if (k == 'W') { if (sscanf(line + 2, "%llu %d %x %x %d", &n, &pos, &a, &d, &be) < 5) continue; }
		else if (k == 'M') { if (sscanf(line + 2, "%llu %d %x %x %x", &n, &pos, &a, &d, &msk) < 4) continue; }   // (mask: MAME's byte writes)
		else if (k == 'R' || k == 'D') { if (sscanf(line + 2, "%llu %d %x %x", &n, &pos, &a, &d) != 4) continue; }
		else if (k == 'Q') {                                    // a 0x408 read in the 68000's time (R885)
			unsigned v, ms, mc;
			if (sscanf(line + 2, "%llu %d %x %u %u", &n, &pos, &v, &ms, &mc) == 5) { q_reads++; if (ms != mc) q_other++; }
			continue;
		}
		else continue;
		if (k == 'D') continue;                                 // the DSP's writes: the reference makes its own
		if (n != samples && n != samples + 1) { if (tag_bad < 5) printf("  %c tagged sample %llu while making %llu\n", k, n, (unsigned long long)samples); tag_bad++; }
		e.pos = pos; e.a = a; e.d = d; e.be = be; e.m = uint16_t(msk);
		pend.push_back({n, e});
	}
	if (fo) fclose(fo);
	printf("scsp_split %s (%s%s): %llu samples (%.2f s), %llu non-zero; %llu differ from the reference (first %lld)\n",
		argv[1], whole ? "whole: every access before slot 0" : "split: where the engine applied it",
		whole ? "" : (mid_after ? ", mid-slot RAM writes after the slot" : ", mid-slot RAM writes before the slot"),
		(unsigned long long)samples, samples / 44100.0, (unsigned long long)nz, (unsigned long long)bad, (long long)first_bad);
	printf("  register writes %llu, RAM writes %llu (%llu inside a slot); reads checked %llu (slot registers, 0x408), wrong %llu; tags out of order %llu\n",
		(unsigned long long)wr_n, (unsigned long long)ram_n, (unsigned long long)mid_n, (unsigned long long)rd_checks, (unsigned long long)rd_bad, (unsigned long long)tag_bad);
	printf("  0x408 reads %llu, of them latched with another slot than MSLC selects %llu (%.2f%%)\n",
		(unsigned long long)mon_reads, (unsigned long long)mon_stale, mon_reads ? 100.0 * mon_stale / mon_reads : 0.0);
	printf("    of those, the CA bit the driver tests (bit 7) not the selected slot's: %llu\n", (unsigned long long)mon_stale_ca);
	if (q_reads) printf("  0x408 reads in the 68000's time (R885) %llu, latched for another slot than the 68000 last selected %llu (%.2f%%)\n",
		(unsigned long long)q_reads, (unsigned long long)q_other, 100.0 * q_other / q_reads);
	printf("  slot reads of sound RAM %llu; of a word the 68000 wrote since the last read %llu, wrote TWICE (a later lap played early) %llu\n   per 0.5 s:",
		(unsigned long long)sl_reads, (unsigned long long)sl_fresh, (unsigned long long)sl_twice);
	for (size_t i = 0; i < wtwice.size(); i++) printf(" %llu", (unsigned long long)wtwice[i]);
	printf("\n");
	printf("  per 0.5 s: samples differing / residual-to-signal RMS (left)\n   ");
	for (size_t w = 0; w < wbad.size(); w++) printf(" %.1f:%llu/%.3f", w * 0.5, (unsigned long long)wbad[w], wsig[w] > 0 ? sqrt(wdiff[w] / wsig[w]) : 0.0);
	printf("\n%s\n", (bad || rd_bad || tag_bad) ? "DIFFER" : "EQUAL");
	return (bad || rd_bad || tag_bad) ? 1 : 0;
}
