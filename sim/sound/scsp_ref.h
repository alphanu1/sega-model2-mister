// license:BSD-3-Clause
// copyright-holders:ElSemi, R. Belmont
// thanks-to: kingshriek
//
// A standalone port of MAME 0.289's src/devices/sound/scsp.cpp and
// scspdsp.cpp (the Sega/Yamaha YMF292-F SCSP), for the Model 2A sound board's
// benches (study R856). It keeps MAME's arithmetic, tables and order of
// operations exactly; what is left out is DMA (unused by every 2A game
// measured), MIDI out and the sound-stream plumbing. Driven by p16's logs
// (register writes and the 68000's sound-RAM writes, each applied before the
// sample it was logged against), it must reproduce MAME's own mix sample for
// sample. The timers, interrupts, MIDI in and the 0x408 monitor are MAME's
// too, except that a timer counts samples (tick() after each) where MAME's
// is a scheduler timer of the same period: the RTL's design (R856).
//
// Modifications from MAME (2026, alphanu1, for sega-model2-mister): the
// device and stream framework removed; RAM is a local array; the noise LFO
// tables are loaded from MAME's dump (machine().rand() is MAME's own); the
// per-slot sample and the DSP send are exposed for the benches; the timers
// count samples; the 68000's interrupt lines are a bit mask (lines).
//
// BSD-3-Clause: see THIRD_PARTY.md (MAME) for the notice and conditions.

#pragma once
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <cmath>
#include <algorithm>
#include <iterator>

namespace scspref {

typedef uint8_t u8; typedef uint16_t u16; typedef uint32_t u32; typedef int32_t s32; typedef int64_t s64; typedef int16_t s16;

static const double ARTimes[64] = {100000,100000,8100.0,6900.0,6000.0,4800.0,4000.0,3400.0,3000.0,2400.0,2000.0,1700.0,1500.0,
					1200.0,1000.0,860.0,760.0,600.0,500.0,430.0,380.0,300.0,250.0,220.0,190.0,150.0,130.0,110.0,95.0,
					76.0,63.0,55.0,47.0,38.0,31.0,27.0,24.0,19.0,15.0,13.0,12.0,9.4,7.9,6.8,6.0,4.7,3.8,3.4,3.0,2.4,
					2.0,1.8,1.6,1.3,1.1,0.93,0.85,0.65,0.53,0.44,0.40,0.35,0.0,0.0};
static const double DRTimes[64] = {100000,100000,118200.0,101300.0,88600.0,70900.0,59100.0,50700.0,44300.0,35500.0,29600.0,25300.0,22200.0,17700.0,
					14800.0,12700.0,11100.0,8900.0,7400.0,6300.0,5500.0,4400.0,3700.0,3200.0,2800.0,2200.0,1800.0,1600.0,1400.0,1100.0,
					920.0,790.0,690.0,550.0,460.0,390.0,340.0,270.0,230.0,200.0,170.0,140.0,110.0,98.0,85.0,68.0,57.0,49.0,43.0,34.0,
					28.0,25.0,22.0,18.0,14.0,12.0,11.0,8.5,7.1,6.1,5.4,4.3,3.6,3.1};
static const float SDLT[8] = {-1000000.0f,-36.0f,-30.0f,-24.0f,-18.0f,-12.0f,-6.0f,0.0f};
static const float LFOFreq[32] = {
	0.17f,0.19f,0.23f,0.27f,0.34f,0.39f,0.45f,0.55f,0.68f,0.78f,0.92f,1.10f,1.39f,1.60f,1.87f,2.27f,
	2.87f,3.31f,3.92f,4.79f,6.15f,7.18f,8.60f,10.8f,14.4f,17.2f,21.5f,28.7f,43.1f,57.4f,86.1f,172.3f };
static const float ASCALE[8] = {0.0f,0.4f,0.8f,1.5f,3.0f,6.0f,12.0f,24.0f};
static const float PSCALE[8] = {0.0f,7.0f,13.5f,27.0f,55.0f,112.0f,230.0f,494.0f};

enum { SHIFT = 12, LFO_SHIFT = 8, EG_SHIFT = 16 };
#define FIX(v)  ((u32) ((float) (1 << SHIFT) * (v)))
#define LFIX(v) ((u32) ((float) (1 << LFO_SHIFT) * (v)))
#define DB(v)   LFIX(powf(10.0f, v / 20.0f))
#define CENTS(v) LFIX(powf(2.0f, v / 1200.0f))

static inline s32 sext(s32 v, int n) { return s32(u32(v) << (32 - n)) >> (32 - n); }

enum STATE { ATTACK, DECAY1, DECAY2, RELEASE };

struct Tables {
	s32 EG_TABLE[0x400];
	int LPANTABLE[0x10000], RPANTABLE[0x10000];
	int ARTABLE[64], DRTABLE[64];
	int PLFO_TRI[256], PLFO_SQR[256], PLFO_SAW[256], PLFO_NOI[256];
	int ALFO_TRI[256], ALFO_SQR[256], ALFO_SAW[256], ALFO_NOI[256];
	int PSCALES[8][256], ASCALES[8][256];
	Tables() {
		for (int i = 0; i < 0x400; ++i) {
			float envDB = ((float)(3 * (i - 0x3ff))) / 32.0f;
			float scale = (float)(1 << SHIFT);
			EG_TABLE[i] = (s32)(powf(10.0f, envDB / 20.0f) * scale);
		}
		for (int i = 0; i < 0x10000; ++i) {
			int iTL = i & 0xff, iPAN = (i >> 8) & 0x1f, iSDL = (i >> 13) & 7;
			float TL, SegaDB = 0.0f, fSDL, PAN, LPAN, RPAN;
			if (iTL & 0x01) SegaDB -= 0.4f;
			if (iTL & 0x02) SegaDB -= 0.8f;
			if (iTL & 0x04) SegaDB -= 1.5f;
			if (iTL & 0x08) SegaDB -= 3.0f;
			if (iTL & 0x10) SegaDB -= 6.0f;
			if (iTL & 0x20) SegaDB -= 12.0f;
			if (iTL & 0x40) SegaDB -= 24.0f;
			if (iTL & 0x80) SegaDB -= 48.0f;
			TL = powf(10.0f, SegaDB / 20.0f);
			SegaDB = 0;
			if (iPAN & 0x1) SegaDB -= 3.0f;
			if (iPAN & 0x2) SegaDB -= 6.0f;
			if (iPAN & 0x4) SegaDB -= 12.0f;
			if (iPAN & 0x8) SegaDB -= 24.0f;
			if ((iPAN & 0xf) == 0xf) PAN = 0.0; else PAN = powf(10.0f, SegaDB / 20.0f);
			if (iPAN < 0x10) { LPAN = PAN; RPAN = 1.0; } else { RPAN = PAN; LPAN = 1.0; }
			if (iSDL) fSDL = powf(10.0f, (SDLT[iSDL]) / 20.0f); else fSDL = 0.0;
			LPANTABLE[i] = FIX((4.0f * LPAN * TL * fSDL));
			RPANTABLE[i] = FIX((4.0f * RPAN * TL * fSDL));
		}
		ARTABLE[0] = DRTABLE[0] = 0; ARTABLE[1] = DRTABLE[1] = 0;
		for (int i = 2; i < 64; ++i) {
			double step, scale, t = ARTimes[i];
			if (t != 0.0) { step = (1023 * 1000.0) / (44100.0 * t); scale = (double)(1 << EG_SHIFT); ARTABLE[i] = (int)(step * scale); }
			else ARTABLE[i] = 1024 << EG_SHIFT;
			t = DRTimes[i]; step = (1023 * 1000.0) / (44100.0 * t); scale = (double)(1 << EG_SHIFT); DRTABLE[i] = (int)(step * scale);
		}
		for (int i = 0; i < 256; ++i) {
			int a, p;
			a = 255 - i; p = i < 128 ? i : i - 256; ALFO_SAW[i] = a; PLFO_SAW[i] = p;
			if (i < 128) { a = 255; p = 127; } else { a = 0; p = -128; }
			ALFO_SQR[i] = a; PLFO_SQR[i] = p;
			if (i < 128) a = 255 - (i * 2); else a = (i * 2) - 256;
			if (i < 64) p = i * 2; else if (i < 128) p = 255 - i * 2; else if (i < 192) p = 256 - i * 2; else p = i * 2 - 511;
			ALFO_TRI[i] = a; PLFO_TRI[i] = p;
			ALFO_NOI[i] = 0; PLFO_NOI[i] = 128;   // MAME: machine().rand(); load_noise() takes MAME's
		}
		for (int s = 0; s < 8; ++s) {
			float limit = PSCALE[s];
			for (int i = -128; i < 128; ++i) PSCALES[s][i + 128] = CENTS(((limit * (float)i) / 128.0f));
			limit = -ASCALE[s];
			for (int i = 0; i < 256; ++i) ASCALES[s][i] = DB(((limit * (float)i) / 256.0f));
		}
	}
	void load_noise(const int *alfo, const int *plfo) { memcpy(ALFO_NOI, alfo, sizeof(ALFO_NOI)); memcpy(PLFO_NOI, plfo, sizeof(PLFO_NOI)); }
};

struct LFO { u16 phase = 0; u32 phase_step = 0; const int *table = nullptr; const int *scale = nullptr; };

struct Slot {
	u16 data[0x10];
	u8 Backwards = 0, active = 0;
	u32 cur_addr = 0, nxt_addr = 0, step = 0;
	struct { int volume = 0; STATE state = RELEASE; int AR = 0, D1R = 0, D2R = 0, RR = 0, DL = 0; u8 EGHOLD = 0; } EG;
	LFO PLFO, ALFO;
};

struct DSP {
	u32 RBP = 0, RBL = 8 * 1024;
	s16 COEF[64]; u16 MADRS[32]; u16 MPRO[128 * 4];
	s32 TEMP[128]; s32 MEMS[32]; u32 DEC = 0;
	s32 MIXS[16]; s16 EXTS[2]; s16 EFREG[16];
	bool Stopped = true; int LastStep = 0;
	DSP() { memset(COEF, 0, sizeof(COEF)); memset(MADRS, 0, sizeof(MADRS)); memset(MPRO, 0, sizeof(MPRO)); memset(TEMP, 0, sizeof(TEMP));
		memset(MEMS, 0, sizeof(MEMS)); memset(MIXS, 0, sizeof(MIXS)); memset(EXTS, 0, sizeof(EXTS)); memset(EFREG, 0, sizeof(EFREG)); }
};

class SCSP {
public:
	const Tables &T;
	u16 udata[0x30 / 2];
	Slot S[32];
	s16 RINGBUF[128];
	u8 BUFPTR = 0;
	DSP D;
	u16 *ram;                  // 0x40000 words, big-endian bytes, owned by the caller
	u8 latched_MSLC = 0;
	u16 latched_MSLC_data = 0;
	// interrupts, timers, MIDI in
	u8 lines = 0;                          // the 68000's lines asserted, bit per level (bit 0: MAME's line 0)
	u32 TimCnt[3] = { 0xffff, 0xffff, 0xffff };
	int tim_left[3] = { 0, 0, 0 };         // samples to a timer's callback; 0: not running
	u8 MidiStack[32] = {}; u8 MidiW = 0, MidiR = 0;
	u8 IrqTimA = 0, IrqTimBC = 0, IrqMidi = 0;
	u16 mcieb = 0, mcipd = 0;
	// per-sample observation for the benches
	s32 slot_out[32]; u8 slot_was_active[32]; s32 last_l = 0, last_r = 0;
	s32 slot_dl[32], slot_dr[32], efx_l = 0, efx_r = 0;   // this sample's direct sends per slot, the effect return (benches, R886)
	s32 mix_add[16];   // this sample's DSP sends, per MIXS entry (benches)
	u32 mixs_mask = 0xffffffffu;   // benches (R949): the slots that feed MIXS (all, as MAME; scsp_mixcat masks)

	SCSP(const Tables &t, u16 *r) : T(t), ram(r) {
		memset(udata, 0, sizeof(udata)); memset(RINGBUF, 0, sizeof(RINGBUF));
		for (int i = 0; i < 32; i++) { memset(S[i].data, 0, sizeof(S[i].data)); S[i].active = 0; S[i].EG.state = RELEASE; }
	}

	// ---------------------------------------------------------------- memory
	// bench hook: every sound-RAM access the chip makes (0 slot byte, 1 slot word, 2 DSP read, 3 DSP write)
	void (*mem_hook)(void *, int, u32) = nullptr; void *hook_ctx = nullptr;
	u8 read_byte(u32 a) { if (mem_hook) mem_hook(hook_ctx, 0, a); a &= 0xfffff; if (a >= 0x80000) return 0; u16 w = ram[a >> 1]; return (a & 1) ? (w & 0xff) : (w >> 8); }
	u16 read_word(u32 a) { if (mem_hook) mem_hook(hook_ctx, 1, a); a &= 0xfffff; if (a >= 0x80000) return 0; return ram[a >> 1]; }
	void write_word(u32 a, u16 v) { if (mem_hook) mem_hook(hook_ctx, 3, a); a &= 0xfffff; if (a >= 0x80000) return; ram[a >> 1] = v; }

	// ---------------------------------------------------------------- fields
	static u32 KEYONEX(const Slot *s) { return s->data[0] & 0x1000; }
	static u32 KEYONB(const Slot *s) { return s->data[0] & 0x0800; }
	static u32 SBCTL(const Slot *s) { return (s->data[0] >> 9) & 3; }
	static u32 SSCTL(const Slot *s) { return (s->data[0] >> 7) & 3; }
	static u32 LPCTL(const Slot *s) { return (s->data[0] >> 5) & 3; }
	static u32 PCM8B(const Slot *s) { return s->data[0] & 0x10; }
	static u32 SA(const Slot *s) { return ((s->data[0] & 0xf) << 16) | s->data[1]; }
	static u32 LSA(const Slot *s) { return s->data[2]; }
	static u32 LEA(const Slot *s) { return s->data[3]; }
	static u32 D2R(const Slot *s) { return (s->data[4] >> 11) & 31; }
	static u32 D1R(const Slot *s) { return (s->data[4] >> 6) & 31; }
	static u32 EGHOLD(const Slot *s) { return s->data[4] & 0x20; }
	static u32 AR(const Slot *s) { return s->data[4] & 31; }
	static u32 LPSLNK(const Slot *s) { return s->data[5] & 0x4000; }
	static u32 KRS(const Slot *s) { return (s->data[5] >> 10) & 15; }
	static u32 DL(const Slot *s) { return (s->data[5] >> 5) & 31; }
	static u32 RR(const Slot *s) { return s->data[5] & 31; }
	static u32 STWINH(const Slot *s) { return s->data[6] & 0x200; }
	static u32 SDIR(const Slot *s) { return s->data[6] & 0x100; }
	static u32 TL(const Slot *s) { return s->data[6] & 0xff; }
	static u32 MDL(const Slot *s) { return (s->data[7] >> 12) & 15; }
	static u32 MDXSL(const Slot *s) { return (s->data[7] >> 6) & 63; }
	static u32 MDYSL(const Slot *s) { return s->data[7] & 63; }
	static u32 OCT(const Slot *s) { return (s->data[8] >> 11) & 15; }
	static u32 FNS(const Slot *s) { return s->data[8] & 0x3ff; }
	static u32 LFOF(const Slot *s) { return (s->data[9] >> 10) & 31; }
	static u32 PLFOWS(const Slot *s) { return (s->data[9] >> 8) & 3; }
	static u32 PLFOS(const Slot *s) { return (s->data[9] >> 5) & 7; }
	static u32 ALFOWS(const Slot *s) { return (s->data[9] >> 3) & 3; }
	static u32 ALFOS(const Slot *s) { return s->data[9] & 7; }
	static u32 ISEL(const Slot *s) { return (s->data[10] >> 3) & 15; }
	static u32 IMXL(const Slot *s) { return s->data[10] & 7; }
	static u32 DISDL(const Slot *s) { return (s->data[11] >> 13) & 7; }
	static u32 DIPAN(const Slot *s) { return (s->data[11] >> 8) & 31; }
	static u32 EFSDL(const Slot *s) { return (s->data[11] >> 5) & 7; }
	static u32 EFPAN(const Slot *s) { return s->data[11] & 31; }
	u32 DAC18B() const { return udata[0] & 0x0100; }
	u32 MVOL() const { return udata[0] & 0xf; }
	u32 RBL() const { return (udata[1] >> 7) & 3; }
	u32 RBP() const { return udata[1] & 0x3f; }

	// ---------------------------------------------------------------- EG
	int Get_AR(int base, int R) { int Rate = base + (R << 1); return T.ARTABLE[std::clamp(Rate, 0, 63)]; }
	int Get_DR(int base, int R) { int Rate = base + (R << 1); return T.DRTABLE[std::clamp(Rate, 0, 63)]; }
	void Compute_EG(Slot *slot) {
		int octave = (OCT(slot) ^ 8) - 8;
		int rate;
		if (KRS(slot) != 0xf) rate = octave + 2 * KRS(slot) + ((FNS(slot) >> 9) & 1); else rate = 0;
		slot->EG.volume = 0x17F << EG_SHIFT;
		slot->EG.AR = Get_AR(rate, AR(slot));
		slot->EG.D1R = Get_DR(rate, D1R(slot));
		slot->EG.D2R = Get_DR(rate, D2R(slot));
		slot->EG.RR = Get_DR(rate, RR(slot));
		slot->EG.DL = 0x1f - DL(slot);
		slot->EG.EGHOLD = EGHOLD(slot) ? 1 : 0;
	}
	int EG_Update(Slot *slot) {
		switch (slot->EG.state) {
		case ATTACK:
			slot->EG.volume += slot->EG.AR;
			if (slot->EG.volume >= (0x3ff << EG_SHIFT)) {
				if (!LPSLNK(slot)) {
					slot->EG.state = DECAY1;
					if (slot->EG.D1R >= (1024 << EG_SHIFT)) slot->EG.state = DECAY2;
				}
				slot->EG.volume = 0x3ff << EG_SHIFT;
			}
			if (slot->EG.EGHOLD) return 0x3ff << (SHIFT - 10);
			break;
		case DECAY1:
			slot->EG.volume -= slot->EG.D1R;
			if (slot->EG.volume <= 0) slot->EG.volume = 0;
			if (slot->EG.volume >> (EG_SHIFT + 5) <= slot->EG.DL) slot->EG.state = DECAY2;
			break;
		case DECAY2:
			if (D2R(slot) == 0) return (slot->EG.volume >> EG_SHIFT) << (SHIFT - 10);
			slot->EG.volume -= slot->EG.D2R;
			if (slot->EG.volume <= 0) slot->EG.volume = 0;
			break;
		case RELEASE:
			slot->EG.volume -= slot->EG.RR;
			if (slot->EG.volume <= 0) { slot->EG.volume = 0; StopSlot(slot, 0); }
			break;
		}
		return (slot->EG.volume >> EG_SHIFT) << (SHIFT - 10);
	}
	u32 Step(Slot *slot) {
		int octave = (OCT(slot) ^ 8) - 8 + SHIFT - 10;
		u32 Fn = FNS(slot) + (1 << 10);
		if (octave >= 0) Fn <<= octave; else Fn >>= -octave;
		return Fn;
	}
	void LFO_ComputeStep(LFO *L, u32 LFOFv, u32 LFOWS, u32 LFOS, int ALFO) {
		float step = (float)LFOFreq[LFOFv] * 256.0f / 44100.0f;
		L->phase_step = (u32)((float)(1 << LFO_SHIFT) * step);
		if (ALFO) {
			switch (LFOWS) { case 0: L->table = T.ALFO_SAW; break; case 1: L->table = T.ALFO_SQR; break; case 2: L->table = T.ALFO_TRI; break; case 3: L->table = T.ALFO_NOI; break; }
			L->scale = T.ASCALES[LFOS];
		} else {
			switch (LFOWS) { case 0: L->table = T.PLFO_SAW; break; case 1: L->table = T.PLFO_SQR; break; case 2: L->table = T.PLFO_TRI; break; case 3: L->table = T.PLFO_NOI; break; }
			L->scale = T.PSCALES[LFOS];
		}
	}
	void Compute_LFO(Slot *slot) {
		if (PLFOS(slot) != 0) LFO_ComputeStep(&slot->PLFO, LFOF(slot), PLFOWS(slot), PLFOS(slot), 0);
		if (ALFOS(slot) != 0) LFO_ComputeStep(&slot->ALFO, LFOF(slot), ALFOWS(slot), ALFOS(slot), 1);
	}
	s32 PLFO_Step(LFO *L) { L->phase += L->phase_step; int p = L->table[L->phase >> LFO_SHIFT]; p = L->scale[p + 128]; return p << (SHIFT - LFO_SHIFT); }
	s32 ALFO_Step(LFO *L) { L->phase += L->phase_step; int p = L->table[L->phase >> LFO_SHIFT]; p = L->scale[p]; return p << (SHIFT - LFO_SHIFT); }

	void StartSlot(Slot *slot) {
		slot->active = 1; slot->cur_addr = 0; slot->nxt_addr = 1 << SHIFT; slot->step = Step(slot);
		Compute_EG(slot); slot->EG.state = ATTACK; slot->EG.volume = 0x17F << EG_SHIFT; slot->Backwards = 0;
		Compute_LFO(slot);
	}
	void StopSlot(Slot *slot, int keyoff) {
		if (keyoff) slot->EG.state = RELEASE; else slot->active = 0;
		slot->data[0] &= ~0x800;
	}

	// ---------------------------------------------------------------- registers
	void UpdateSlotReg(int s, int r) {
		Slot *slot = S + s;
		switch (r & 0x3f) {
		case 0: case 1:
			if (KEYONEX(slot)) {
				for (int sl = 0; sl < 32; ++sl) {
					Slot *s2 = S + sl;
					if (KEYONB(s2) && s2->EG.state == RELEASE) StartSlot(s2);
					if (!KEYONB(s2)) StopSlot(s2, 1);
				}
				slot->data[0] &= ~0x1000;
			}
			break;
		case 0x10: case 0x11: slot->step = Step(slot); break;
		case 0xA: case 0xB: slot->EG.RR = Get_DR(0, RR(slot)); slot->EG.DL = 0x1f - DL(slot); break;
		case 0x12: case 0x13: Compute_LFO(slot); break;
		}
	}
	void DSP_Start() {
		D.Stopped = false;
		int i;
		for (i = 127; i >= 0; --i) { const u16 *IPtr = D.MPRO + i * 4; if (IPtr[0] || IPtr[1] || IPtr[2] || IPtr[3]) break; }
		D.LastStep = i + 1;
	}
	void irq(u8 level, bool on) { if (on) lines |= u8(1 << level); else lines &= u8(~(1 << level)); }
	u8 DecodeSCI(int b) { return u8(((udata[0x24 / 2] >> b) & 1) | (((udata[0x26 / 2] >> b) & 1) << 1) | (((udata[0x28 / 2] >> b) & 1) << 2)); }
	void CheckPendingIRQ() {
		u32 pend = udata[0x20 / 2], en = udata[0x1e / 2];
		if (MidiW != MidiR) { udata[0x20 / 2] |= 8; pend |= 8; }
		if (!pend) return;
		if ((pend & 0x40) && (en & 0x40)) { irq(IrqTimA, 1); return; }
		if ((pend & 0x80) && (en & 0x80)) { irq(IrqTimBC, 1); return; }
		if ((pend & 0x100) && (en & 0x100)) { irq(IrqTimBC, 1); return; }
		if ((pend & 8) && (en & 8)) { irq(IrqMidi, 1); return; }
		irq(0, 0);
	}
	void ResetInterrupts() {
		u32 reset = udata[0x22 / 2];
		if (reset & 0x40) irq(IrqTimA, 0);
		if (reset & 0x180) irq(IrqTimBC, 0);
		if (reset & 0x8) irq(IrqMidi, 0);
		CheckPendingIRQ();
	}
	void timer_cb(int t) {
		TimCnt[t] = 0xffff;
		udata[0x20 / 2] |= u16(0x40 << t);
		udata[(0x18 + 2 * t) / 2] = u16((udata[(0x18 + 2 * t) / 2] & 0xff00) | 0xff);
		CheckPendingIRQ();
		if (t == 0) mcipd |= 0x40;          // MainCheckPendingIRQ(0x40)
	}
	// one sample's time: the timers (after the sample, as the RTL's)
	void tick() { for (int t = 0; t < 3; t++) if (tim_left[t] && --tim_left[t] == 0) timer_cb(t); }
	// a MIDI byte from the main board (rcv_complete)
	void midi_in(u8 b) { MidiStack[MidiW++] = b; MidiW &= 31; CheckPendingIRQ(); }
	void UpdateReg(int reg) {
		switch (reg & 0x3f) {
		case 0x2: case 0x3: D.RBL = (8 * 1024) << RBL(); D.RBP = RBP(); break;
		case 8: case 9: latched_MSLC = (udata[0x8 / 2] & 0xf800) >> 11; break;
		case 0x18: case 0x19: case 0x1a: case 0x1b: case 0x1c: case 0x1d: {
			int t = ((reg & 0x3f) - 0x18) >> 1;
			u16 v = udata[(0x18 + 2 * t) / 2];
			TimCnt[t] = (v & 0xff) << 8;
			if ((v & 0xff) != 255) tim_left[t] = (255 - (v & 0xff)) << ((v >> 8) & 7);
			break;
		}
		case 0x1e: case 0x1f: CheckPendingIRQ(); break;
		case 0x22: case 0x23:
			udata[0x20 / 2] &= u16(~udata[0x22 / 2]);
			ResetInterrupts();
			if (TimCnt[0] == 0xffff) udata[0x20 / 2] |= 0x40;
			if (TimCnt[1] == 0xffff) udata[0x20 / 2] |= 0x80;
			if (TimCnt[2] == 0xffff) udata[0x20 / 2] |= 0x100;
			break;
		case 0x24: case 0x25: case 0x26: case 0x27: case 0x28: case 0x29:
			IrqTimA = DecodeSCI(6); IrqTimBC = DecodeSCI(7); IrqMidi = DecodeSCI(3); break;
		case 0x2a: case 0x2b: mcieb = udata[0x2a / 2]; break;
		case 0x2c: case 0x2d: if (udata[0x2c / 2] & 0x20) mcipd |= 0x20; break;
		case 0x2e: case 0x2f: mcipd &= u16(~udata[0x2e / 2]); break;
		default: break;   // MIDI out, DMA: not modelled (no DMA in any 2A game)
		}
	}
	void UpdateRegR(int reg) {
		switch (reg & 0x3f) {
		case 4: case 5: {
			u16 v = u16((udata[0x4 / 2] & 0xff00) | MidiStack[MidiR]);
			if (MidiR != MidiW) { ++MidiR; MidiR &= 31; }
			if (MidiR == MidiW) { irq(IrqMidi, 0); udata[0x20 / 2] &= u16(~8); }
			udata[0x4 / 2] = v;
			break;
		}
		case 8: case 9: udata[0x8 / 2] = latched_MSLC_data; break;
		case 0x2a: case 0x2b: udata[0x2a / 2] = mcieb; break;
		case 0x2c: case 0x2d: udata[0x2c / 2] = mcipd; break;
		default: break;
		}
	}
	// R914: 0x7c0-0x7ff. MAME 0.289 mirrors it onto MADRS; the SCSP does not
	// (Mednafen: writes dropped, reads 0), and the RTL follows the SCSP.
	// SCSP_MIRROR=1 gives MAME's mirror (the replay then equals MAME's mix).
	bool madrs_mirror = getenv("SCSP_MIRROR") != nullptr;
	void w16(u32 addr, u16 val) {
		addr &= 0xffff;
		if (addr < 0x400) { int slot = addr / 0x20; addr &= 0x1f; S[slot].data[addr >> 1] = val; UpdateSlotReg(slot, addr & 0x1f); }
		else if (addr < 0x600) { if (addr < 0x430) { udata[(addr & 0x3f) >> 1] = val; UpdateReg(addr & 0x3f); } }
		else if (addr < 0x700) RINGBUF[(addr - 0x600) / 2] = val;
		else {
			if (addr < 0x780) D.COEF[(addr - 0x700) / 2] = val;
			else if (addr < 0x7c0) D.MADRS[(addr - 0x780) / 2] = val;
			else if (addr < 0x800) { if (madrs_mirror) D.MADRS[(addr - 0x7c0) / 2] = val; }   // R914
			else if (addr < 0xC00) { D.MPRO[(addr - 0x800) / 2] = val; if (addr == 0xBF0) DSP_Start(); }
		}
	}
	u16 r16(u32 addr) {
		addr &= 0xffff;
		if (addr < 0x400) return S[addr / 0x20].data[(addr & 0x1f) >> 1];
		if (addr < 0x600) { if (addr >= 0x430) return 0; UpdateRegR(int(addr & 0x3f)); return udata[(addr & 0x3f) >> 1]; }
		if (addr < 0x700) return RINGBUF[(addr - 0x600) / 2];
		if (addr < 0x780) return D.COEF[(addr - 0x700) / 2];
		if (addr < 0x7c0) return D.MADRS[(addr - 0x780) / 2];
		if (addr < 0x800) return madrs_mirror ? D.MADRS[(addr - 0x7c0) / 2] : 0;   // R914
		if (addr < 0xC00) return D.MPRO[(addr - 0x800) / 2];
		return 0;
	}
	// MAME scsp_device::write: read, combine with mem_mask, write back.
	void write(u32 byteoff, u16 data, u16 mask) { u16 tmp = r16(byteoff); tmp = (tmp & ~mask) | (data & mask); w16(byteoff, tmp); }

	// ---------------------------------------------------------------- slot
	s32 UpdateSlot(Slot *slot) {
		if (SSCTL(slot) == 3) return 0;
		s32 sample = 0;
		int step = slot->step;
		u32 addr1, addr2, addr_select;
		u32 *addr[2] = {&addr1, &addr2};
		u32 *slot_addr[2] = {&slot->cur_addr, &slot->nxt_addr};
		if (PLFOS(slot) != 0) { step = step * PLFO_Step(&slot->PLFO); step >>= SHIFT; }
		if (PCM8B(slot)) { addr1 = slot->cur_addr >> SHIFT; addr2 = slot->nxt_addr >> SHIFT; }
		else { addr1 = (slot->cur_addr >> (SHIFT - 1)) & ~1; addr2 = (slot->nxt_addr >> (SHIFT - 1)) & ~1; }
		if (MDL(slot) != 0 || MDXSL(slot) != 0 || MDYSL(slot) != 0) {
			s32 smp = (RINGBUF[(BUFPTR + MDXSL(slot)) & 63] + RINGBUF[(BUFPTR + MDYSL(slot)) & 63]) / 2;
			smp <<= 0xA; smp >>= 0x1A - MDL(slot);
			if (!PCM8B(slot)) smp <<= 1;
			addr1 += smp; addr2 += smp;
		}
		if (SSCTL(slot) == 0) {
			if (PCM8B(slot)) {
				int8_t p1 = read_byte(SA(slot) + addr1), p2 = read_byte(SA(slot) + addr2);
				s32 fpart = slot->cur_addr & ((1 << SHIFT) - 1);
				s32 s = (int)(p1 << 8) * ((1 << SHIFT) - fpart) + (int)(p2 << 8) * fpart;
				sample = (s >> SHIFT);
			} else {
				s16 p1 = read_word(SA(slot) + addr1), p2 = read_word(SA(slot) + addr2);
				s32 fpart = slot->cur_addr & ((1 << SHIFT) - 1);
				s32 s = (int)(p1) * ((1 << SHIFT) - fpart) + (int)(p2) * fpart;
				sample = (s >> SHIFT);
			}
		} else if (SSCTL(slot) == 1) sample = 0;   // MAME: machine().rand() noise; not used by any 2A game
		else sample = 0;
		if (SBCTL(slot) & 1) sample ^= 0x7FFF;
		if (SBCTL(slot) & 2) sample = (s16)(sample ^ 0x8000);
		if (slot->Backwards) slot->cur_addr -= step; else slot->cur_addr += step;
		slot->nxt_addr = slot->cur_addr + (1 << SHIFT);
		addr1 = slot->cur_addr >> SHIFT; addr2 = slot->nxt_addr >> SHIFT;
		if (addr1 >= LSA(slot) && !(slot->Backwards)) { if (LPSLNK(slot) && slot->EG.state == ATTACK) slot->EG.state = DECAY1; }
		for (addr_select = 0; addr_select < 2; addr_select++) {
			s32 rem_addr;
			switch (LPCTL(slot)) {
			case 0: if (*addr[addr_select] >= LSA(slot) && *addr[addr_select] >= LEA(slot)) StopSlot(slot, 0); break;
			case 1: if (*addr[addr_select] >= LEA(slot)) { rem_addr = *slot_addr[addr_select] - (LEA(slot) << SHIFT); *slot_addr[addr_select] = (LSA(slot) << SHIFT) + rem_addr; } break;
			case 2:
				if ((*addr[addr_select] >= LSA(slot)) && !(slot->Backwards)) { rem_addr = *slot_addr[addr_select] - (LSA(slot) << SHIFT); *slot_addr[addr_select] = (LEA(slot) << SHIFT) - rem_addr; slot->Backwards = 1; }
				else if ((*addr[addr_select] < LSA(slot) || (*slot_addr[addr_select] & 0x80000000)) && slot->Backwards) { rem_addr = (LSA(slot) << SHIFT) - *slot_addr[addr_select]; *slot_addr[addr_select] = (LEA(slot) << SHIFT) - rem_addr; }
				break;
			case 3:
				if (*addr[addr_select] >= LEA(slot)) { rem_addr = *slot_addr[addr_select] - (LEA(slot) << SHIFT); *slot_addr[addr_select] = (LEA(slot) << SHIFT) - rem_addr; slot->Backwards = 1; }
				else if ((*addr[addr_select] < LSA(slot) || (*slot_addr[addr_select] & 0x80000000)) && slot->Backwards) { rem_addr = (LSA(slot) << SHIFT) - *slot_addr[addr_select]; *slot_addr[addr_select] = (LSA(slot) << SHIFT) + rem_addr; slot->Backwards = 0; }
				break;
			}
		}
		if (!SDIR(slot)) {
			if (ALFOS(slot) != 0) { sample = sample * ALFO_Step(&slot->ALFO); sample >>= SHIFT; }
			if (slot->EG.state == ATTACK) sample = (sample * EG_Update(slot)) >> SHIFT;
			else sample = (sample * T.EG_TABLE[EG_Update(slot) >> (SHIFT - 10)]) >> SHIFT;
		}
		if (!STWINH(slot)) {
			u16 Enc = SDIR(slot) ? (0x7 << 0xd) : ((TL(slot)) | (0x7 << 0xd));
			*RBUFDST = (sample * T.LPANTABLE[Enc]) >> (SHIFT + 1);
		}
		return sample;
	}
	s16 *RBUFDST = nullptr;

	// ---------------------------------------------------------------- DSP
	static u16 PACK(s32 val) {
		int sign = (val >> 23) & 1; u32 temp = (val ^ (val << 1)) & 0xFFFFFF; int exponent = 0;
		for (int k = 0; k < 12; k++) { if (temp & 0x800000) break; temp <<= 1; exponent += 1; }
		if (exponent < 12) val = (val << exponent) & 0x3FFFFF; else val <<= 11;
		val >>= 11; val &= 0x7FF; val |= sign << 15; val |= exponent << 11;
		return u16(val);
	}
	static s32 UNPACK(u16 val) {
		int sign = (val >> 15) & 1; int exponent = (val >> 11) & 0xF; int mantissa = val & 0x7FF; s32 uval = mantissa << 11;
		if (exponent > 11) { exponent = 11; uval |= sign << 22; } else uval |= (sign ^ 1) << 22;
		uval |= sign << 23; uval <<= 8; uval >>= 8; uval >>= exponent;
		return uval;
	}
	void DSP_Step() {
		if (D.Stopped) return;
		std::fill(std::begin(D.EFREG), std::end(D.EFREG), 0);
		s32 ACC = 0, MEMVAL = 0, FRC_REG = 0, Y_REG = 0; u32 ADRS_REG = 0;
		for (int step = 0; step < D.LastStep; ++step) {
			u16 *IPtr = D.MPRO + step * 4;
			u32 TRA = (IPtr[0] >> 8) & 0x7f, TWT = (IPtr[0] >> 7) & 1, TWA = IPtr[0] & 0x7f;
			u32 XSEL = (IPtr[1] >> 15) & 1, YSEL = (IPtr[1] >> 13) & 3, IRA = (IPtr[1] >> 6) & 0x3f, IWT = (IPtr[1] >> 5) & 1, IWA = IPtr[1] & 0x1f;
			u32 TABLE = (IPtr[2] >> 15) & 1, MWT = (IPtr[2] >> 14) & 1, MRD = (IPtr[2] >> 13) & 1, EWT = (IPtr[2] >> 12) & 1, EWA = (IPtr[2] >> 8) & 0xf;
			u32 ADRL = (IPtr[2] >> 7) & 1, FRCL = (IPtr[2] >> 6) & 1, SHIFTv = (IPtr[2] >> 4) & 3, YRL = (IPtr[2] >> 3) & 1, NEGB = (IPtr[2] >> 2) & 1, ZERO = (IPtr[2] >> 1) & 1, BSEL = IPtr[2] & 1;
			u32 NOFL = (IPtr[3] >> 15) & 1, COEFi = (IPtr[3] >> 9) & 0x3f, MASA = (IPtr[3] >> 2) & 0x1f, ADREB = (IPtr[3] >> 1) & 1, NXADR = IPtr[3] & 1;
			s32 INPUTS;
			if (IRA <= 0x1f) INPUTS = D.MEMS[IRA];
			else if (IRA <= 0x2F) INPUTS = D.MIXS[IRA - 0x20] << 4;
			else if (IRA <= 0x31) INPUTS = D.EXTS[IRA - 0x30] << 8;
			else return;
			INPUTS = sext(INPUTS, 24);
			if (IWT) { D.MEMS[IWA] = MEMVAL; if (IRA == IWA) INPUTS = MEMVAL; }
			s32 B;
			if (!ZERO) { if (BSEL) B = ACC; else B = sext(D.TEMP[(TRA + D.DEC) & 0x7f], 24); if (NEGB) B = 0 - B; }
			else B = 0;
			s32 X;
			if (XSEL) X = INPUTS; else X = sext(D.TEMP[(TRA + D.DEC) & 0x7f], 24);
			s32 Y = 0;
			if (YSEL == 0) Y = FRC_REG; else if (YSEL == 1) Y = D.COEF[COEFi] >> 3; else if (YSEL == 2) Y = (Y_REG >> 11) & 0x1fff; else Y = (Y_REG >> 4) & 0x0fff;
			if (YRL) Y_REG = INPUTS;
			s32 SHIFTED = 0;
			if (SHIFTv == 0) SHIFTED = std::clamp<s32>(ACC, -0x00800000, 0x007fffff);
			else if (SHIFTv == 1) SHIFTED = std::clamp<s32>(ACC * 2, -0x00800000, 0x007fffff);
			else if (SHIFTv == 2) SHIFTED = sext(ACC * 2, 24);
			else SHIFTED = sext(ACC, 24);
			Y = sext(Y, 13);
			s64 v = (s64(X) * s64(Y)) >> 12;
			if (dbg_dsp) printf("M k %d acc %d sh %d in %d x %d y %d b %d mv %d dec %u ira %x iwt %d iwa %d mixs %x\n", step, ACC, SHIFTED, INPUTS, X, Y, B, MEMVAL, D.DEC & 0xffff, IRA, IWT, IWA, IRA >= 0x20 && IRA < 0x30 ? D.MIXS[IRA - 0x20] : 0);
			ACC = int(v + B);
			if (TWT) D.TEMP[(TWA + D.DEC) & 0x7f] = SHIFTED;
			if (FRCL) { if (SHIFTv == 3) FRC_REG = SHIFTED & 0x0fff; else FRC_REG = (SHIFTED >> 11) & 0x1fff; }
			if (MRD || MWT) {
				u32 ADDR = D.MADRS[MASA];
				if (!TABLE) ADDR += D.DEC;
				if (ADREB) ADDR += ADRS_REG & 0x0FFF;
				if (NXADR) ADDR++;
				if (!TABLE) ADDR &= D.RBL - 1; else ADDR &= 0xffff;
				ADDR += D.RBP << 12;
				ADDR <<= 1;
				if (dbg_dsp) printf("M   addr %05x (words %05x) rbl %u rbp %x\n", ADDR, ADDR >> 1, D.RBL, D.RBP);
				if (MRD && (step & 1)) { if (mem_hook) mem_hook(hook_ctx, 2, ADDR); auto h = mem_hook; mem_hook = nullptr;
					if (NOFL) MEMVAL = read_word(ADDR) << 8; else MEMVAL = UNPACK(read_word(ADDR)); dsp_reads++; mem_hook = h; }
				if (MWT && (step & 1)) { if (NOFL) write_word(ADDR, SHIFTED >> 8); else write_word(ADDR, PACK(SHIFTED)); dsp_writes++; }
			}
			if (ADRL) { if (SHIFTv == 3) ADRS_REG = (SHIFTED >> 12) & 0xfff; else ADRS_REG = INPUTS >> 16; }
			if (EWT) D.EFREG[EWA] += SHIFTED >> 8;
		}
		--D.DEC;
		std::fill(std::begin(D.MIXS), std::end(D.MIXS), 0);
	}
	uint64_t dsp_reads = 0, dsp_writes = 0;
	bool dbg_dsp = false;

	// ---------------------------------------------------------------- one sample (MAME DoMasterSamples, one iteration)
	// bench hook (R885): called before each slot (0..31) and before the DSP (32),
	// to apply accesses where a free-running engine applied them
	void (*slot_hook)(void *, int) = nullptr; void *slot_ctx = nullptr;
	void sample(s32 &outl, s32 &outr) {
		s32 smpl = 0, smpr = 0;
		for (int i = 0; i < 16; i++) mix_add[i] = 0;
		for (int sl = 0; sl < 32; ++sl) {
			if (slot_hook) slot_hook(slot_ctx, sl);
			RBUFDST = RINGBUF + BUFPTR;
			slot_was_active[sl] = S[sl].active; slot_out[sl] = 0; slot_dl[sl] = slot_dr[sl] = 0;
			if (S[sl].active) {
				Slot *slot = S + sl;
				s32 smp = UpdateSlot(slot);
				slot_out[sl] = smp;
				u16 eff_tl = SDIR(slot) ? 0 : TL(slot);
				u16 Enc = eff_tl | (IMXL(slot) << 0xd);
				if ((mixs_mask >> sl) & 1) D.MIXS[ISEL(slot)] += (smp * T.LPANTABLE[Enc]) >> (SHIFT - 2);
				mix_add[ISEL(slot)] += (smp * T.LPANTABLE[Enc]) >> (SHIFT - 2);
				Enc = eff_tl | (DIPAN(slot) << 0x8) | (DISDL(slot) << 0xd);
				slot_dl[sl] = (smp * T.LPANTABLE[Enc]) >> SHIFT; slot_dr[sl] = (smp * T.RPANTABLE[Enc]) >> SHIFT;
				smpl += slot_dl[sl];
				smpr += slot_dr[sl];
			}
			++BUFPTR; BUFPTR &= 63;
		}
		if (slot_hook) slot_hook(slot_ctx, 32);
		DSP_Step();
		const s32 dir_l = smpl, dir_r = smpr;
		for (int i = 0; i < 16; ++i) {
			Slot *slot = S + i;
			if (EFSDL(slot)) {
				u16 Enc = (EFPAN(slot) << 0x8) | (EFSDL(slot) << 0xd);
				smpl += (D.EFREG[i] * T.LPANTABLE[Enc]) >> SHIFT;
				smpr += (D.EFREG[i] * T.RPANTABLE[Enc]) >> SHIFT;
			}
		}
		for (int i = 0; i < 2; ++i) {
			Slot *slot = S + i + 16;
			if (EFSDL(slot)) {
				D.EXTS[i] = 0;   // Model 2: no external input on the SCSP's stream
				u16 Enc = (EFPAN(slot) << 0x8) | (EFSDL(slot) << 0xd);
				smpl += (D.EXTS[i] * T.LPANTABLE[Enc]) >> SHIFT;
				smpr += (D.EXTS[i] * T.RPANTABLE[Enc]) >> SHIFT;
			}
		}
		efx_l = smpl - dir_l; efx_r = smpr - dir_r;
		outl = last_l = smpl; outr = last_r = smpr;
		// the 0x408 monitor, latched after each update (MAME sound_stream_update)
		const Slot *m = S + latched_MSLC;
		latched_MSLC_data = u16((((m->cur_addr >> (SHIFT + 12)) & 0xf) << 7) | ((u32(m->EG.state) & 3) << 5) | ((0x1f - (m->EG.volume >> (EG_SHIFT + 5))) & 0x1f));
	}
};

} // namespace scspref
