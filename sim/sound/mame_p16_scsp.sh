# p16: M2SCSP_OUT=<dir> -- the Model 2A sound board measured (study R856).
# scsp.cpp: every 68000 register write and read with the sample it lands
# before, MAME's mix per sample (before the clamp), per-slot samples in a
# window (M2SCSP_SLOT_FROM / M2SCSP_SLOT_TO, samples), every key-on with the
# slot's registers, the DSP program at each start, MIDI in bytes, DMA, the
# derived tables, and feature counts (stats.txt at exit).
# model2.cpp: the 68000's sound-RAM writes (for replay) and its bus traffic
# by region; the SCSP's interrupt line changes.
# Off (no env var) MAME is unchanged.
#   sh sim/sound/mame_p16_scsp.sh <mame 0.289 tree>   (then: make SUBTARGET=m2lod SOURCES=src/mame/sega/model2.cpp)
S=${1:?mame tree}/src
P=$S/devices/sound/scsp.cpp Q=$S/devices/sound/scspdsp.cpp R=$S/mame/sega/model2.cpp python3 - <<'PY'
import os
p=os.environ['P']; s=open(p).read()
if 'M2SCSP' not in s:
    a='''DEFINE_DEVICE_TYPE(SCSP, scsp_device, "scsp", "Yamaha YMF292-F SCSP")'''
    b=a+'''

// ---- p16: M2SCSP instrumentation ----
#include <cstdio>
#include <cstdlib>
#include <string>
u64 g_m2s_n = 0;
FILE *g_m2s_ramw = nullptr;
struct m2s_stats_t {
	bool init = false; bool on = false;
	FILE *regs = nullptr, *rd = nullptr, *out = nullptr, *slots = nullptr, *key = nullptr, *midi = nullptr, *misc = nullptr;
	u64 slot_from = 0, slot_to = 0;
	u64 act_hist[33] = {0};
	u64 feat[64] = {0};
	u64 slot_samples = 0;
	u64 page_slot[128] = {0};
	u64 rd_count[0x800] = {0}, wr_count[0x800] = {0};
	u64 keyons = 0;
	u64 clamp_l = 0, clamp_r = 0;
	s32 peak = 0;
	std::string dir;
	void open() {
		init = true;
		const char *d = getenv("M2SCSP_OUT"); if (!d) return;
		on = true; dir = d;
		auto f = [&](const char *n) { return fopen((dir + "/" + n).c_str(), "wb"); };
		regs = f("regs.bin"); rd = f("reads.bin"); out = f("out.bin"); key = f("keyon.txt"); midi = f("midi.txt"); misc = f("misc.txt");
		g_m2s_ramw = f("ramw.bin");
		if (getenv("M2SCSP_SLOT_TO")) { slot_from = strtoull(getenv("M2SCSP_SLOT_FROM") ? getenv("M2SCSP_SLOT_FROM") : "0", nullptr, 0); slot_to = strtoull(getenv("M2SCSP_SLOT_TO"), nullptr, 0); slots = f("slots.bin"); }
	}
	~m2s_stats_t() {
		if (!on) return;
		FILE *st = fopen((dir + "/stats.txt").c_str(), "w"); if (!st) return;
		fprintf(st, "samples %llu keyons %llu slot_samples %llu peak %d clamp_l %llu clamp_r %llu\\n", (unsigned long long)g_m2s_n, (unsigned long long)keyons, (unsigned long long)slot_samples, peak, (unsigned long long)clamp_l, (unsigned long long)clamp_r);
		fprintf(st, "active-slot histogram (samples with n slots active):\\n");
		for (int i = 0; i <= 32; i++) if (act_hist[i]) fprintf(st, "  act %2d %llu\\n", i, (unsigned long long)act_hist[i]);
		static const char *fn[64] = {"pcm8","pcm16","lp0","lp1","lp2","lp3","fm","plfo","plfo_ws0","plfo_ws1","plfo_ws2","plfo_ws3","alfo","alfo_ws0","alfo_ws1","alfo_ws2","alfo_ws3",
			"sdir","ssctl1","ssctl2","ssctl3","sbctl1","sbctl2","sbctl3","stwinh","eghold","krs_on","lpslnk","imxl","disdl","efsdl","backwards","eg_attack","eg_decay1","eg_decay2","eg_release","mdl_only","mdxsl_ne_mdysl","oct_pos","oct_neg"};
		fprintf(st, "slot-sample feature counts:\\n");
		for (int i = 0; i < 64; i++) if (fn[i]) fprintf(st, "  %-14s %llu\\n", fn[i], (unsigned long long)feat[i]);
		fprintf(st, "slot read pages (4 KB of sound RAM, slot-samples):\\n");
		for (int i = 0; i < 128; i++) if (page_slot[i]) fprintf(st, "  page %05x %llu\\n", i << 12, (unsigned long long)page_slot[i]);
		fprintf(st, "68000 register reads / writes by byte offset:\\n");
		for (int i = 0; i < 0x800; i++) if (rd_count[i] || wr_count[i]) fprintf(st, "  reg %03x r %llu w %llu\\n", i * 2, (unsigned long long)rd_count[i], (unsigned long long)wr_count[i]);
		fclose(st);
	}
};
static m2s_stats_t &m2s() { static m2s_stats_t s; if (!s.init) s.open(); return s; }
struct m2s_rec { u32 n; u16 off, data, mask, pad; };
'''
    assert s.count(a)==1; s=s.replace(a,b)
    a='''	LFO_Init();
	// no "pend"'''
    b='''	LFO_Init();
	if (m2s().on) {   // p16: the derived tables
		FILE *t = fopen((m2s().dir + "/tables.bin").c_str(), "wb");
		if (t) {
			fwrite(m_EG_TABLE, sizeof(m_EG_TABLE), 1, t); fwrite(m_LPANTABLE, sizeof(m_LPANTABLE), 1, t); fwrite(m_RPANTABLE, sizeof(m_RPANTABLE), 1, t);
			fwrite(m_ARTABLE, sizeof(m_ARTABLE), 1, t); fwrite(m_DRTABLE, sizeof(m_DRTABLE), 1, t);
			fwrite(m_PSCALES, sizeof(m_PSCALES), 1, t); fwrite(m_ASCALES, sizeof(m_ASCALES), 1, t);
			fwrite(m_ALFO_NOI, sizeof(m_ALFO_NOI), 1, t); fwrite(m_PLFO_NOI, sizeof(m_PLFO_NOI), 1, t);
			fclose(t);
		}
	}
	// no "pend"'''
    assert s.count(a)==1; s=s.replace(a,b)
    a='''	Compute_LFO(slot);

//  printf("StartSlot'''
    b='''	Compute_LFO(slot);
	if (m2s().on) {   // p16
		m2s().keyons++;
		fprintf(m2s().key, "%llu %2d", (unsigned long long)g_m2s_n, slot->slot);
		for (int i = 0; i < 0x10; i++) fprintf(m2s().key, " %04x", slot->udata.data[i]);
		fprintf(m2s().key, "\\n");
	}

//  printf("StartSlot'''
    assert s.count(a)==1; s=s.replace(a,b)
    a='''void scsp_device::exec_dma()
{
	static u16 tmp_dma[3];
	int i;
'''
    b=a+'''	if (m2s().on) fprintf(m2s().misc, "%llu DMA dmea %x drga %x dtlg %x ddir %d dgate %d\\n", (unsigned long long)g_m2s_n, m_dma.dmea, m_dma.drga, m_dma.dtlg, m_dma.ddir, m_dma.dgate);   // p16
'''
    assert s.count(a)==1; s=s.replace(a,b)
    a='''u16 scsp_device::read(offs_t offset)
{
	m_stream->update();
	return r16(offset * 2);
}'''
    b='''u16 scsp_device::read(offs_t offset)
{
	m_stream->update();
	u16 v = r16(offset * 2);
	if (m2s().on) {   // p16
		m2s().rd_count[offset & 0x7ff]++;
		m2s_rec r = { u32(g_m2s_n), u16(offset * 2), v, 0xffff, 0 }; fwrite(&r, sizeof(r), 1, m2s().rd);
	}
	return v;
}'''
    assert s.count(a)==1; s=s.replace(a,b)
    a='''	m_stream->update();

	u16 tmp = r16(offset * 2);'''
    b='''	m_stream->update();
	if (m2s().on) {   // p16
		m2s().wr_count[offset & 0x7ff]++;
		m2s_rec r = { u32(g_m2s_n), u16(offset * 2), data, mem_mask, 0 }; fwrite(&r, sizeof(r), 1, m2s().regs);
	}

	u16 tmp = r16(offset * 2);'''
    assert s.count(a)==1; s=s.replace(a,b)
    a='''	m_MidiStack[m_MidiW++] = get_received_char();'''
    b='''	if (m2s().on) fprintf(m2s().midi, "%llu in %02x\\n", (unsigned long long)g_m2s_n, get_received_char());   // p16
	m_MidiStack[m_MidiW++] = get_received_char();'''
    assert s.count(a)==1; s=s.replace(a,b)
    a='''				s32 sample = UpdateSlot(slot);
'''
    b='''				s32 sample = UpdateSlot(slot);
				if (m2s().on) {   // p16
					auto &M = m2s(); m2s_act++; m2s_smp[sl] = sample; m2s_on[sl] = 1; M.slot_samples++;
					u64 *F = M.feat;
					F[PCM8B(slot) ? 0 : 1]++; F[2 + LPCTL(slot)]++;
					if (MDL(slot) || MDXSL(slot) || MDYSL(slot)) { F[6]++; if (MDL(slot) && !MDXSL(slot) && !MDYSL(slot)) F[36]++; if (MDXSL(slot) != MDYSL(slot)) F[37]++; }
					if (PLFOS(slot)) { F[7]++; F[8 + PLFOWS(slot)]++; }
					if (ALFOS(slot)) { F[12]++; F[13 + ALFOWS(slot)]++; }
					if (SDIR(slot)) F[17]++;
					if (SSCTL(slot)) F[17 + SSCTL(slot)]++;
					if (SBCTL(slot)) F[20 + SBCTL(slot)]++;
					if (STWINH(slot)) F[24]++;
					if (EGHOLD(slot)) F[25]++;
					if (KRS(slot) != 0xf) F[26]++;
					if (LPSLNK(slot)) F[27]++;
					if (IMXL(slot)) F[28]++;
					if (DISDL(slot)) F[29]++;
					if (EFSDL(slot)) F[30]++;
					if (slot->Backwards) F[31]++;
					F[32 + (slot->EG.state & 3)]++;
					if (OCT(slot) & 8) F[39]++; else F[38]++;
					if (SSCTL(slot) == 0) {
						u32 a = (SA(slot) + ((slot->cur_addr >> SHIFT) << (PCM8B(slot) ? 0 : 1))) & 0x7ffff;
						M.page_slot[a >> 12]++;
					}
				}
'''
    assert s.count(a)==1; s=s.replace(a,b)
    a='''	for (int s = 0; s < stream.samples(); ++s)
	{
		s32 smpl = 0, smpr = 0;
'''
    b='''	for (int s = 0; s < stream.samples(); ++s)
	{
		s32 smpl = 0, smpr = 0;
		int m2s_act = 0; s32 m2s_smp[32]; u8 m2s_on[32];   // p16
		for (int i = 0; i < 32; i++) { m2s_smp[i] = 0; m2s_on[i] = 0; }
'''
    assert s.count(a)==1; s=s.replace(a,b)
    a='''		if (DAC18B())
		{
			stream.put_int_clamp(0, s, smpl, 131072);'''
    b='''		if (m2s().on) {   // p16
			auto &M = m2s();
			M.act_hist[m2s_act]++;
			s32 o[2] = { smpl, smpr }; fwrite(o, sizeof(o), 1, M.out);
			if ((smpl >> 2) > 32767 || (smpl >> 2) < -32768) M.clamp_l++;
			if ((smpr >> 2) > 32767 || (smpr >> 2) < -32768) M.clamp_r++;
			if (std::abs(smpl) > M.peak) M.peak = std::abs(smpl);
			if (std::abs(smpr) > M.peak) M.peak = std::abs(smpr);
			if (M.slots && g_m2s_n >= M.slot_from && g_m2s_n < M.slot_to) {
				for (int i = 0; i < 32; i++) {
					SCSP_SLOT *sl2 = m_Slots + i;
					s32 rec[4] = { m2s_on[i] ? m2s_smp[i] : 0, sl2->EG.volume, s32(sl2->cur_addr), s32((sl2->EG.state & 3) | (m2s_on[i] << 4) | (sl2->active << 5)) };
					fwrite(rec, sizeof(rec), 1, M.slots);
				}
				s32 ef[16]; for (int i = 0; i < 16; i++) ef[i] = m_DSP.EFREG[i];
				fwrite(ef, sizeof(ef), 1, M.slots);
			}
			g_m2s_n++;
		}
		if (DAC18B())
		{
			stream.put_int_clamp(0, s, smpl, 131072);'''
    assert s.count(a)==1; s=s.replace(a,b)
    open(p,'w').write(s)

q=os.environ['Q']; s=open(q).read()
if 'M2SCSP' not in s:
    s=s.replace('#include <cstring>', '#include <cstring>\n#include <cstdio>\n#include <cstdlib>\n#include <string>',1)
    a='''void SCSPDSP::Init()'''
    b='''// p16 M2SCSP: DSP usage counts
struct m2s_dsp_t { u64 runs = 0, steps = 0, mrd = 0, mwt = 0; u32 amin = 0xffffffff, amax = 0; u64 page[128] = {0}; bool on = getenv("M2SCSP_OUT") != nullptr;
	~m2s_dsp_t() { if (!on) return; std::string p = std::string(getenv("M2SCSP_OUT")) + "/dspstats.txt"; FILE *f = fopen(p.c_str(), "w"); if (!f) return;
		fprintf(f, "runs %llu steps %llu mrd %llu mwt %llu addr(bytes) min %x max %x\\n", (unsigned long long)runs, (unsigned long long)steps, (unsigned long long)mrd, (unsigned long long)mwt, amin, amax);
		for (int i = 0; i < 128; i++) if (page[i]) fprintf(f, "page %05x %llu\\n", i << 12, (unsigned long long)page[i]);
		fclose(f); } };
static m2s_dsp_t &m2sd() { static m2s_dsp_t d; return d; }
extern u64 g_m2s_n;

void SCSPDSP::Init()'''
    assert s.count(a)==1; s=s.replace(a,b)
    a='''	s32 ACC = 0;    //26 bit'''
    b='''	if (m2sd().on) { m2sd().runs++; m2sd().steps += LastStep; }   // p16
	s32 ACC = 0;    //26 bit'''
    assert s.count(a)==1; s=s.replace(a,b)
    a='''			if (MRD && (step & 1)) //memory only allowed on odd? DoA inserts NOPs on even'''
    b='''			if (m2sd().on && (step & 1) && (MRD || MWT)) {   // p16
				if (MRD) m2sd().mrd++;
				if (MWT) m2sd().mwt++;
				u32 a = ADDR & 0x7ffff; if (a < m2sd().amin) m2sd().amin = a; if (a > m2sd().amax) m2sd().amax = a; m2sd().page[a >> 12]++;
			}
			if (MRD && (step & 1)) //memory only allowed on odd? DoA inserts NOPs on even'''
    assert s.count(a)==1; s=s.replace(a,b)
    a='''	LastStep = i + 1;
}'''
    b='''	LastStep = i + 1;
	if (m2sd().on) {   // p16: the program at each start
		std::string p = std::string(getenv("M2SCSP_OUT")) + "/dsp.txt"; FILE *f = fopen(p.c_str(), "a");
		if (f) {
			fprintf(f, "START n %llu laststep %d RBP %x RBL %x\\n", (unsigned long long)g_m2s_n, LastStep, RBP, RBL);
			for (int k = 0; k < 128; k++) fprintf(f, "MPRO %3d %04x %04x %04x %04x\\n", k, MPRO[k*4], MPRO[k*4+1], MPRO[k*4+2], MPRO[k*4+3]);
			for (int k = 0; k < 64; k++) fprintf(f, "COEF %2d %04x\\n", k, u16(COEF[k]));
			for (int k = 0; k < 32; k++) fprintf(f, "MADRS %2d %04x\\n", k, MADRS[k]);
			fclose(f);
		}
	}
}'''
    assert s.count(a)==1; s=s.replace(a,b)
    open(q,'w').write(s)

r=os.environ['R']; s=open(r).read()
if 'M2SCSP' not in s:
    a='''void model2_state::reset_model2_scsp()
{'''
    b='''extern u64 g_m2s_n;   // p16 M2SCSP
extern FILE *g_m2s_ramw;
struct m2s_bus_t { u64 rd[8] = {0}, wr[8] = {0}; bool on = getenv("M2SCSP_OUT") != nullptr;
	~m2s_bus_t() { if (!on) return; std::string p = std::string(getenv("M2SCSP_OUT")) + "/bus.txt"; FILE *f = fopen(p.c_str(), "w"); if (!f) return;
		static const char *n[8] = {"ram","scsp","ctl","prog","samp","bank4","bank5","other"};
		fprintf(f, "68000 data accesses by region, samples %llu\\n", (unsigned long long)g_m2s_n);
		for (int i = 0; i < 8; i++) fprintf(f, "%-6s r %llu w %llu\\n", n[i], (unsigned long long)rd[i], (unsigned long long)wr[i]);
		fclose(f); } };
static m2s_bus_t &m2sb() { static m2s_bus_t b; return b; }
static int m2s_reg(offs_t a) { a &= 0xffffff; if (a < 0x80000) return 0; if (a >= 0x100000 && a < 0x101000) return 1; if (a >= 0x400000 && a < 0x400002) return 2;
	if (a >= 0x600000 && a < 0x680000) return 3; if (a >= 0x800000 && a < 0xa00000) return 4; if (a >= 0xa00000 && a < 0xe00000) return 5; if (a >= 0xe00000) return 6; return 7; }

void model2_state::reset_model2_scsp()
{
	static bool m2s_tapped = false;   // p16
	if (m2sb().on && !m2s_tapped && m_audiocpu) {
		m2s_tapped = true;
		address_space &sp = m_audiocpu->space(AS_PROGRAM);
		sp.install_write_tap(0x000000, 0xffffff, "m2s_w", [](offs_t off, u16 &data, u16 mask) {
			int r = m2s_reg(off); m2sb().wr[r]++;
			if (r == 0 && g_m2s_ramw) { u32 rec[3] = { u32(g_m2s_n), u32(off & 0x7ffff), u32(data) | (u32(mask) << 16) }; fwrite(rec, sizeof(rec), 1, g_m2s_ramw); }
			if (r == 2) { std::string p = std::string(getenv("M2SCSP_OUT")) + "/ctl.txt"; FILE *f = fopen(p.c_str(), "a"); if (f) { fprintf(f, "%llu CTL 400000 <- %04x mask %04x\\n", (unsigned long long)g_m2s_n, data, mask); fclose(f); } }
		});
		sp.install_read_tap(0x000000, 0xffffff, "m2s_r", [](offs_t off, u16 &data, u16 mask) { m2sb().rd[m2s_reg(off)]++; });
	}'''
    assert s.count(a)==1; s=s.replace(a,b)
    a='''void model2_state::scsp_irq(offs_t offset, u8 data)
{'''
    b='''void model2_state::scsp_irq(offs_t offset, u8 data)
{
	if (m2sb().on) {   // p16
		static FILE *f = nullptr; if (!f) f = fopen((std::string(getenv("M2SCSP_OUT")) + "/irq.txt").c_str(), "w");
		if (f) fprintf(f, "%llu %u %u\\n", (unsigned long long)g_m2s_n, unsigned(offset), unsigned(data));
	}'''
    assert s.count(a)==1; s=s.replace(a,b)
    open(r,'w').write(s)
print("p16 applied")
PY
