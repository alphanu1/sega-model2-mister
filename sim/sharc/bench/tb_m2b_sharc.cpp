// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA -- R1027: the 2B SHARC (m2b_sharc) replayed on a MAME
// capture (sim/sharc/mame_m2b_capture.patch: R924_CAP's events.bin, M2B_TRACE's strace.bin).
//
//   * the boot as the i960 did it: the host's IOP-window writes ('H') and the 16-bit upload
//     words ('U', phase = the upload count mod 3) through the core's own host ports, then the
//     HALT released at 'B';
//   * the in FIFO (16 deep) kept as full as the stream allows from the i960's pushes ('I', 'N'
//     in order); the out FIFO (16) drained at once: FLAG0 / FLAG1 never wait, so every word the
//     core runs is work, and the clocks per word are the core's own;
//   * every out-FIFO word checked against MAME's ('O', in order);
//   * with +trace=<strace.bin> [+tfrom=<k>]: the PC and a hash of the state after every word
//     that is not a one-word wait, against MAME's (the R1023 spin rule on both sides);
//   * with +lock: Hornet's v1 (sim/sharc/ref, MAME's interpreter transcribed; MAN = the
//     manual's rounding when the core is built MAME_RND 0) beside it, its PM loaded with the
//     upload (MAME's external_dma_write), on its own FIFOs; PC, R0-R15, I0-I15, M0-M15, ASTAT,
//     STKY, MODE1, the stacks' pointers and tops, CURLCNTR, LCNTR compared at every word.
//
//   * R1031: the board's side of the external bus (m2b_xbus) is in the bench: the DM page's port
//     and the buffer RAM / ROM ports served by a model here, each transaction answered after a
//     random latency in [lo, hi] clocks (+lat=lo:hi, +seed=<n>), the page and the buffer RAM
//     starting all ones (unwritten memory reads 0xFFFF...), the ROM 0 (DOA's region is
//     ERASE00). Built with a small DM_AW, Dead or Alive's data words above 2^DM_AW go through
//     the cache.
//
//   tb_m2b_sharc +ev=<events.bin> [+trace=<strace.bin>] [+tfrom=<k>] [+words=<n>] [+lock]
//                [+prof=<file>] [+tdiff=<n>] [+quiet] [+lat=<lo>:<hi>] [+seed=<n>]
#include "Vtb_m2b_sharc.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <algorithm>
#include <deque>
#include <map>
#include <string>
#include <vector>

double sc_time_stamp() { return 0; }

struct Ev { uint8_t t; uint32_t a, b; };

// a forward reader of events.bin for one kind of record
struct Reader {
    FILE *f = nullptr;
    std::vector<uint8_t> buf;
    size_t pos = 0, len = 0;
    bool open(const char *p) { f = fopen(p, "rb"); buf.resize(9 << 16); return f != nullptr; }
    bool next(Ev &e) {
        if (pos + 9 > len) {
            size_t keep = len - pos;
            memmove(buf.data(), buf.data() + pos, keep);
            len = keep + fread(buf.data() + keep, 1, buf.size() - keep, f);
            pos = 0;
            if (len < 9) return false;
        }
        const uint8_t *r = buf.data() + pos;
        e.t = r[0];
        e.a = r[1] | r[2] << 8 | r[3] << 16 | uint32_t(r[4]) << 24;
        e.b = r[5] | r[6] << 8 | r[7] << 16 | uint32_t(r[8]) << 24;
        pos += 9;
        return true;
    }
};

static inline uint32_t fnv(uint32_t h, uint32_t v) {
    for (int k = 0; k < 4; k++) { h ^= (v >> (8 * k)) & 0xff; h *= 16777619u; }
    return h;
}

struct St {                       // the state after a word
    uint32_t pc, r[16], i[16], m[16], astat, stky, mode1, curlcntr, lcntr, pcstk, pcstkp, lstkp;
};
static uint32_t hash_st(const St &s) {
    uint32_t h = 2166136261u;
    for (int k = 0; k < 16; k++) h = fnv(h, s.r[k]);
    h = fnv(h, s.astat & ~0x00180000u);
    h = fnv(h, s.stky);
    h = fnv(h, s.mode1);
    for (int k = 0; k < 8; k++) h = fnv(h, s.i[k]);
    for (int k = 8; k < 16; k++) h = fnv(h, s.i[k] & 0xffffff);
    for (int k = 0; k < 8; k++) h = fnv(h, s.m[k]);
    for (int k = 8; k < 16; k++) h = fnv(h, s.m[k] & 0xffffff);
    h = fnv(h, s.pcstkp);
    h = fnv(h, s.lstkp);
    h = fnv(h, s.curlcntr);
    return h;
}
static void print_st(const char *who, const St &s) {
    printf("  %s pc %05x  ASTAT %08x STKY %08x MODE1 %08x PCSTKP %u LSTKP %u CURLCNTR %08x LCNTR %08x PCSTK %06x\n",
           who, s.pc, s.astat, s.stky, s.mode1, s.pcstkp, s.lstkp, s.curlcntr, s.lcntr, s.pcstk);
    printf("    R "); for (int k = 0; k < 16; k++) printf("%08x%c", s.r[k], k == 7 ? '\n' : ' ');
    printf("\n    I "); for (int k = 0; k < 16; k++) printf("%08x%c", s.i[k], k == 7 ? '\n' : ' ');
    printf("\n    M "); for (int k = 0; k < 16; k++) printf("%08x%c", s.m[k], k == 7 ? '\n' : ' ');
    printf("\n");
}

static bool is_wait(uint32_t pc, uint64_t op, uint32_t next) {
    uint64_t o = op & 0xffffffffffffULL;
    unsigned top = unsigned(o >> 32) & 0xff80;
    return next == pc && (o == 0 || top == 0x0600 || top == 0x0700);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    // commandArgsPlusMatch returns a buffer the next call reuses: keep copies
    static std::map<std::string, std::string> args;
    auto arg = [](const char *k) -> const char * {
        auto it = args.find(k);
        if (it == args.end()) {
            const char *s = Verilated::commandArgsPlusMatch(k);
            it = args.emplace(k, (s && *s) ? std::string(s + strlen(k) + 1) : std::string("\x01")).first;
        }
        return it->second == "\x01" ? nullptr : it->second.c_str();
    };
    const char *evp = arg("ev=");
    if (!evp) { fprintf(stderr, "+ev=<events.bin> required\n"); return 1; }
    const char *trp = arg("trace=");
    uint64_t tfrom = arg("tfrom=") ? strtoull(arg("tfrom="), nullptr, 0) : 0;
    uint64_t maxw = arg("words=") ? strtoull(arg("words="), nullptr, 0) : ~0ULL;
    long tdiff_max = arg("tdiff=") ? atol(arg("tdiff=")) : 5;
    const char *profp = arg("prof=");
    uint64_t show_n = arg("show=") ? strtoull(arg("show="), nullptr, 0) : 0;
    bool noidle = Verilated::commandArgsPlusMatch("noidle") && *Verilated::commandArgsPlusMatch("noidle");
    bool outok = Verilated::commandArgsPlusMatch("outok") && *Verilated::commandArgsPlusMatch("outok");   // manual rounding: the out words may differ from MAME's
    long out_show = arg("outshow=") ? atol(arg("outshow=")) : 10;
    bool pconly = Verilated::commandArgsPlusMatch("pconly") && *Verilated::commandArgsPlusMatch("pconly");
    uint64_t ulp_h[8] = {0}, ulp_up = 0, ulp_dn = 0, thash = 0;
    std::map<uint32_t, uint64_t> big_pc, all_pc;
    bool lock = Verilated::commandArgsPlusMatch("lock") && *Verilated::commandArgsPlusMatch("lock");
    bool quiet = Verilated::commandArgsPlusMatch("quiet") && *Verilated::commandArgsPlusMatch("quiet");

    Reader rin, rout;
    if (!rin.open(evp) || !rout.open(evp)) { fprintf(stderr, "cannot open %s\n", evp); return 1; }
    FILE *tf = trp ? fopen(trp, "rb") : nullptr;
    if (trp && !tf) { fprintf(stderr, "cannot open %s\n", trp); return 1; }

    Vtb_m2b_sharc *t = new Vtb_m2b_sharc;
    t->clk = 0; t->reset = 1; t->run = 0; t->host_iop_we = 0; t->xdma_we = 0;
    t->fin_empty = 1; t->fout_full = 0; t->v_ce = 0; t->v_ext_ack = 0;
    t->sdm_ack = 0; t->dat_ack = 0; t->bufw_ack = 0;
    t->v_pm_we = 0; t->v_we = 0; t->v_flag = 0;

    // R1031: the SDRAM side -- the DM page (64 K halfwords), the buffer RAM (32 K words), the ROM
    unsigned lat_lo = 1, lat_hi = 1;
    if (const char *l = arg("lat=")) { if (sscanf(l, "%u:%u", &lat_lo, &lat_hi) != 2) lat_hi = lat_lo = atoi(l); }
    if (lat_hi < lat_lo) lat_hi = lat_lo;
    uint64_t rng = arg("seed=") ? strtoull(arg("seed="), nullptr, 0) * 0x9e3779b97f4a7c15ULL + 1 : 0x1234567ULL;
    auto rnd = [&]() { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return rng; };
    auto lat = [&]() -> uint64_t { return lat_lo + (lat_hi > lat_lo ? rnd() % (lat_hi - lat_lo + 1) : 0); };
    std::vector<uint16_t> page(65536, 0xffff);
    std::vector<uint16_t> bufram(65536, 0xffff);
    uint64_t sclk = 0, sdm_rd = 0, sdm_wr = 0, x_rd = 0, x_wr = 0;
    struct Port { bool busy = false, done = false; uint64_t due = 0; };
    Port psdm, pdat, pbw;
    // R1042: the buffer RAM / data ROM reads answered with the capture's own values ('R', in
    // MAME's order: the i960 writes the buffer RAM too, which the capture does not hold), each
    // read's address checked against MAME's; without 'R' records the model above (DOA reads none)
    Reader rbr, rvbr; rbr.open(evp); rvbr.open(evp);
    uint64_t r_n = 0, r_bad = 0, vr_n = 0, vr_bad = 0;
    auto next_r = [&](Reader &rd, Ev &x) -> bool { while (rd.next(x)) if (x.t == 'R') return true; return false; };
    auto serve = [&]() {      // the low half of a clock: answer the ports (inputs for this edge)
        // the DM page
        if (!t->sdm_req) { psdm.done = false; t->sdm_ack = 0; }
        else if (!psdm.busy && !psdm.done) { psdm.busy = true; psdm.due = sclk + lat(); }
        if (psdm.busy && sclk >= psdm.due) {
            unsigned a = t->sdm_addr;
            if (t->sdm_we) { page[a] = t->sdm_din; sdm_wr++; }
            else { t->sdm_dout = page[a] | uint32_t(page[(a + 1) & 0xffff]) << 16; sdm_rd++; }
            psdm.busy = false; psdm.done = true;
        }
        if (t->sdm_req && psdm.done) t->sdm_ack = 1;      // sticky while the request stands (R162)
        // buffer RAM / ROM reads
        if (!t->dat_req) { pdat.done = false; t->dat_ack = 0; }
        else if (!pdat.busy && !pdat.done) { pdat.busy = true; pdat.due = sclk + lat(); }
        if (pdat.busy && sclk >= pdat.due) {
            uint32_t a = t->dat_addr;
            t->dat_rdata = t->dat_is_buf ? (bufram[(2 * a) & 0xffff] | uint32_t(bufram[(2 * a + 1) & 0xffff]) << 16) : 0;
            Ev x;
            if (next_r(rbr, x)) {
                uint32_t ca = t->dat_is_buf ? (0x1400000u + (a & 0x7fff)) : (0x1c00000u + (uint32_t(t->dat_hi) << 20 | a));
                uint32_t ma = (x.a >= 0x1400000u && x.a < 0x1c00000u) ? (0x1400000u + ((x.a - 0x1400000u) & 0x7fff)) : x.a;
                r_n++;
                if (ca != ma && r_bad++ < 5) printf("buffer / ROM read #%llu at %07x, MAME's at %07x\n", (unsigned long long)r_n, ca, x.a);
                t->dat_rdata = x.b;
            }
            x_rd++;
            pdat.busy = false; pdat.done = true;
        }
        if (t->dat_req && pdat.done) t->dat_ack = 1;
        // buffer RAM writes
        if (!t->bufw_req) { pbw.done = false; t->bufw_ack = 0; }
        else if (!pbw.busy && !pbw.done) { pbw.busy = true; pbw.due = sclk + lat(); }
        if (pbw.busy && sclk >= pbw.due) { bufram[t->bufw_addr & 0xffff] = t->bufw_data; x_wr++; pbw.busy = false; pbw.done = true; }
        if (t->bufw_req && pbw.done) t->bufw_ack = 1;
        sclk++;
    };
    auto tick = [&]() { t->clk = 0; t->eval(); serve(); t->eval(); t->clk = 1; t->eval(); };
    for (int k = 0; k < 4; k++) tick();
    t->reset = 0;
    // the core clears its RAM after reset (MAME's device_reset), and m2b_dmc the DM page's part; the
    // i960's upload comes long after
    for (int k = 0; k < 8200; k++) tick();
    uint64_t clr_clk = 0;
    while (t->o_busy) { tick(); clr_clk++; }
    printf("DM page cleared %llu clocks after the core's RAM (latency %u-%u)\n", (unsigned long long)clr_clk, lat_lo, lat_hi);

    // ---------------------------------------------------------------- the boot
    // MAME's external_dma_write, for v1's PM (16/48 packing as DOA sets it: DMAC6 0xa1)
    std::vector<uint64_t> pm(8192, 0);
    uint32_t ii6 = 0x20000, im6 = 1, dmac6 = 0xa1, syscon = 0x10, iop_lo = 0; bool iop_hi = false;
    std::deque<uint32_t> inq;         // i960 pushes not yet in the FIFO
    Ev e;
    bool booted = false;
    long nh = 0, nu = 0;
    while (!booted && rin.next(e)) {
        switch (e.t) {
        case 'H': {
            t->host_iop_we = 1; t->host_iop_reg = e.a & 0xff; t->host_iop_data = e.b;
            tick(); t->host_iop_we = 0; nh++;
            uint32_t d = e.b; bool go = true;
            if ((syscon & 0x10) && (e.a & 0xff) != 4) {
                if (!iop_hi) { iop_lo = e.b & 0xffff; iop_hi = true; go = false; }
                else { d = (e.b & 0xffff) << 16 | iop_lo; iop_hi = false; }
            }
            if (go) switch (e.a & 0xff) {
                case 0x1c: dmac6 = d; break; case 0x00: syscon = d; break;
                case 0x40: ii6 = d; break; case 0x41: im6 = d; break; default: break; }
            break;
        }
        case 'U': {
            unsigned w = e.a % 3;
            t->xdma_we = 1; t->xdma_phase = w; t->xdma_data = e.b & 0xffff;
            tick(); t->xdma_we = 0; nu++;
            unsigned idx = ((ii6 & 0x1ffff) | 0x20000) - 0x20000;
            unsigned sh = ((dmac6 & 0x100) ? (2 - w) : w) * 16;
            if (((dmac6 >> 6) & 3) == 2 && idx < pm.size()) {
                pm[idx] &= ~(0xffffULL << sh);
                pm[idx] |= uint64_t(e.b & 0xffff) << sh;
            }
            if (w == 2) ii6 += im6;
            break;
        }
        case 'B': booted = true; break;
        case 'I': case 'N': inq.push_back(e.b); break;
        default: break;
        }
    }
    if (!booted) { fprintf(stderr, "no boot in the capture\n"); return 1; }
    printf("boot: %ld IOP-window writes, %ld upload words; %zu FIFO words before the boot\n", nh, nu, inq.size());

    // v1: the upload in its PM, MAME's reset state, then run
    if (lock) {
        for (unsigned k = 0; k < pm.size(); k++) {
            t->v_pm_we = 1; t->v_pm_addr = k; t->v_pm_wdata = pm[k]; tick();
        }
        t->v_pm_we = 0;
        auto w = [&](int sel, int idx, uint64_t d) { t->v_we = 1; t->v_wsel = sel; t->v_widx = idx; t->v_wdata = d; tick(); t->v_we = 0; };
        w(21, 0, 0x20004); w(22, 0, 0x20005); w(23, 0, 0x20006); w(24, 0, 0x20007);
        w(27, 0, 0x00ffffff); w(32, 0, 0xffffffff); w(35, 0, 0xffffffff);
        w(45, 0, 0x05400000); w(47, 0, 3); w(52, 0, 0x10);
        w(25, 0, 0xffffffff); w(26, 0, 0xffffffff);
        w(255, 0, 0);
        t->v_ce = 1;
    }
    t->run = 1;

    // ---------------------------------------------------------------- the run
    std::deque<uint32_t> fin, vfin;   // the in FIFOs (core, v1)
    bool in_done = false;
    auto refill = [&]() {
        while (!in_done && inq.size() < 64) {
            Ev x;
            if (!rin.next(x)) { in_done = true; break; }
            if (x.t == 'I' || x.t == 'N') inq.push_back(x.b);
        }
    };
    // v1 reads the same stream with its own reader, its FIFO kept as full
    Reader rvin; rvin.open(evp);
    bool vin_done = false;
    auto vrefill = [&]() {
        while (!vin_done && vfin.size() < 16) {
            Ev x;
            if (!rvin.next(x)) { vin_done = true; break; }
            if (x.t == 'I' || x.t == 'N') vfin.push_back(x.b);
        }
    };
    uint64_t clocks = 0, words = 0, nwait = 0, dwait = 0, outs = 0, out_bad = 0, vouts = 0, vout_bad = 0;
    uint64_t tw = 0, tbad = 0, tcmp = 0, lock_n = 0, lock_bad = 0;
    uint64_t st_cnt[8] = {0}, rf2w = 0, dm_fill = 0, dm_wait = 0, dm_acc = 0, dm_wr = 0;
    std::map<uint32_t, std::pair<uint64_t, uint64_t>> prof;   // pc -> (words, clocks)
    uint64_t last_ret_clk = 0;
    bool have_prev = false;
    St prev{};
    uint64_t prev_op = 0;
    std::deque<St> mine, theirs;      // lockstep queues
    bool v_have = false; St v_prev{};
    bool stop = false;
    bool unsup_seen = false;
    uint64_t idle_clocks = 0;
    std::deque<uint32_t> outq_exp;    // expected out words (MAME's order)
    bool out_eof = false;
    auto want_out = [&](uint32_t &v) -> bool {
        while (outq_exp.empty() && !out_eof) {
            Ev x;
            if (!rout.next(x)) { out_eof = true; break; }
            if (x.t == 'O') outq_exp.push_back(x.b);
        }
        if (outq_exp.empty()) return false;
        v = outq_exp.front(); outq_exp.pop_front(); return true;
    };
    std::deque<uint32_t> vout_exp;    // v1 checked against the same order (its own reader)
    Reader rvout; rvout.open(evp); bool vout_eof = false;
    auto vwant_out = [&](uint32_t &v) -> bool {
        while (vout_exp.empty() && !vout_eof) {
            Ev x;
            if (!rvout.next(x)) { vout_eof = true; break; }
            if (x.t == 'O') vout_exp.push_back(x.b);
        }
        if (vout_exp.empty()) return false;
        v = vout_exp.front(); vout_exp.pop_front(); return true;
    };
    uint32_t ext_pending = 0; (void)ext_pending;

    while (!stop) {
        refill();
        while (fin.size() < 16 && !inq.empty()) { fin.push_back(inq.front()); inq.pop_front(); }
        // v1's stream: every word the core's FIFO took (the same order), kept 16 deep
        t->fin_empty = fin.empty();
        t->fin_data = fin.empty() ? 0xffffffffu : fin.front();
        if (lock) {
            vrefill();
            t->v_flag = (vfin.empty() ? 1 : 0);
            // v1 runs about twice as fast: hold it while it is far ahead of the core
            t->v_ce = theirs.size() < 4096;
        }
        t->clk = 0; t->eval();
        serve();
        t->eval();
        // the combinational outputs of this clock
        bool pop = t->fin_pop, push = t->fout_push;
        uint32_t pushd = t->fout_data;
        uint32_t pushpc = t->o_xpc;
        bool vreq = lock && t->v_ext_req && t->v_ce;
        uint32_t vaddr = t->v_ext_addr, vwd = t->v_ext_wdata; bool vwe = t->v_ext_we;
        bool vexec = lock && t->v_exec;
        St vs{};
        if (vexec) {
            vs.pc = t->v_pc;
            for (int k = 0; k < 16; k++) { vs.r[k] = t->v_r[k]; vs.i[k] = t->v_i[k]; vs.m[k] = t->v_m[k]; }
            vs.astat = t->v_astat; vs.stky = t->v_stky; vs.mode1 = t->v_mode1; vs.curlcntr = t->v_curlcntr;
            vs.lcntr = t->v_lcntr; vs.pcstk = t->v_pcstk; vs.pcstkp = t->v_pcstkp; vs.lstkp = t->v_lstkp;
        }
        // v1's external bus: one access answered the clock it is seen
        t->v_ext_ack = 0;
        if (vreq) {
            if (vaddr >= 0x400000 && vaddr < 0xc00000 && !vwe) {
                if (!vfin.empty()) { t->v_ext_ack = 1; t->v_ext_rdata = vfin.front(); vfin.pop_front(); }
            } else if (vaddr >= 0xc00000 && vaddr < 0x1400000 && vwe) {
                t->v_ext_ack = 1;
                uint32_t w;
                vouts++;
                if (!vwant_out(w) || w != vwd) { if (vout_bad++ < 5) printf("v1 out #%llu: %08x, MAME %08x\n", (unsigned long long)vouts, vwd, w); }
            } else if (vaddr >= 0x1400000 && vaddr < 0x1e00000 && !vwe) {     // R1042: as the core's, from 'R'
                Ev x;
                t->v_ext_ack = 1; t->v_ext_rdata = 0xffffffffu;
                if (next_r(rvbr, x)) {
                    uint32_t ca = vaddr < 0x1c00000 ? 0x1400000u + ((vaddr - 0x1400000u) & 0x7fff) : vaddr;
                    uint32_t ma = (x.a >= 0x1400000u && x.a < 0x1c00000u) ? (0x1400000u + ((x.a - 0x1400000u) & 0x7fff)) : x.a;
                    vr_n++;
                    if (ca != ma && vr_bad++ < 5) printf("v1 buffer / ROM read #%llu at %07x, MAME's at %07x\n", (unsigned long long)vr_n, ca, x.a);
                    t->v_ext_rdata = x.b;
                }
            } else { t->v_ext_ack = 1; t->v_ext_rdata = 0xffffffffu; }
            t->eval();
        }
        t->clk = 1; t->eval();
        clocks++;
        st_cnt[t->dbg_st & 7]++;
        rf2w += t->o_rf2w;
        dm_fill += t->o_fill; dm_wait += t->o_wait; dm_acc += t->o_dm_acc; dm_wr += t->o_dm_wr;
        if (pop && !fin.empty()) fin.pop_front();
        if (push) {
            uint32_t w;
            outs++;
            all_pc[pushpc]++;
            if (!want_out(w)) { if (out_bad++ < 5) printf("out #%llu: %08x, MAME has no more\n", (unsigned long long)outs, pushd); }
            else if (w != pushd) {
                if (out_bad++ < (uint64_t)out_show) printf("out #%llu: %08x, MAME %08x (word %llu)\n", (unsigned long long)outs, pushd, w, (unsigned long long)words);
                // the distance in units in the last place, as floats of the same sign
                int b;
                if ((w ^ pushd) & 0x80000000u) b = 7;
                else {
                    uint32_t d = w > pushd ? w - pushd : pushd - w;
                    b = d == 1 ? 0 : d <= 3 ? 1 : d <= 15 ? 2 : d <= 255 ? 3 : d <= 65535 ? 4 : d < (1u << 23) ? 5 : 6;
                }
                ulp_h[b]++;
                if (b >= 3) big_pc[pushpc]++;
                if (pushd > w) ulp_up++; else ulp_dn++;
            }
        }
        if (t->unsup && !unsup_seen) {
            unsup_seen = true;
            printf("UNSUPPORTED word at %05x: %012llx (reason %u), after %llu words\n", t->unsup_pc,
                   (unsigned long long)t->unsup_op, t->unsup_why, (unsigned long long)words);
        }
        // v1's record: the state at its exec is that after its previous word
        if (vexec) {
            if (v_have) { St s = v_prev; St post = vs; post.pc = s.pc; theirs.push_back(post); }
            v_prev = vs; v_have = true;
        }
        if (t->dbg_ret) {
            St s{};
            s.pc = t->dbg_pc;
            for (int k = 0; k < 16; k++) { s.r[k] = t->o_r[k]; s.i[k] = t->o_i[k]; s.m[k] = t->o_m[k]; }
            s.astat = t->o_astat; s.stky = t->o_stky; s.mode1 = t->o_mode1; s.curlcntr = t->o_curlcntr;
            s.lcntr = t->o_lcntr; s.pcstk = t->o_pcstk; s.pcstkp = t->o_pcstkp; s.lstkp = t->o_lstkp;
            uint64_t op = t->dbg_op;
            uint32_t next = t->o_daddr;
            if (words < show_n)
                printf("ret %llu clk %llu pc %05x op %012llx next %05x  R0 %08x R1 %08x I0 %08x M0 %08x ASTAT %08x\n",
                       (unsigned long long)words, (unsigned long long)clocks, s.pc, (unsigned long long)op, next,
                       s.r[0], s.r[1], s.i[0], s.m[0], s.astat);
            bool wt = is_wait(s.pc, op, next);
            words++;
            if (wt) nwait++;
            auto &pp = prof[s.pc]; pp.first++; pp.second += clocks - last_ret_clk;
            last_ret_clk = clocks;
            if (tf && !wt) {
                if (tw >= tfrom) {
                    uint32_t rec[2];
                    if (fread(rec, 4, 2, tf) == 2) {
                        tcmp++;
                        uint32_t h = hash_st(s);
                        if (rec[1] != h) thash++;
                        if (rec[0] != s.pc || (!pconly && rec[1] != h)) {
                            if (tbad++ < tdiff_max) {
                                printf("trace word %llu: core pc %05x hash %08x, MAME pc %05x hash %08x\n",
                                       (unsigned long long)tw, s.pc, h, rec[0], rec[1]);
                                print_st("core", s);
                                if (have_prev) print_st("core (the word before)", prev);
                            }
                        }
                    } else { fclose(tf); tf = nullptr; }
                }
                tw++;
            }
            if (lock) mine.push_back(s);
            prev = s; prev_op = op; have_prev = true;
            if (words >= maxw) stop = true;
        }
        // the lockstep comparison, in order
        while (lock && !mine.empty() && !theirs.empty()) {
            St &a = mine.front(), &b = theirs.front();
            lock_n++;
            bool bad = a.pc != b.pc || a.astat != b.astat || a.stky != b.stky || a.mode1 != b.mode1 ||
                       a.curlcntr != b.curlcntr || a.lcntr != b.lcntr || (a.pcstk & 0xffffff) != (b.pcstk & 0xffffff) ||
                       a.pcstkp != b.pcstkp || a.lstkp != b.lstkp;
            for (int k = 0; k < 16; k++) bad |= a.r[k] != b.r[k] || a.i[k] != b.i[k] || a.m[k] != b.m[k];
            // ASTAT's FLG0 / FLG1 bits hold the input pins as last written: not compared
            if (bad && ((a.astat ^ b.astat) & ~0x00180000u) == 0) {
                bool other = a.pc != b.pc || a.stky != b.stky || a.mode1 != b.mode1 || a.curlcntr != b.curlcntr ||
                             a.lcntr != b.lcntr || (a.pcstk & 0xffffff) != (b.pcstk & 0xffffff) || a.pcstkp != b.pcstkp || a.lstkp != b.lstkp;
                for (int k = 0; k < 16; k++) other |= a.r[k] != b.r[k] || a.i[k] != b.i[k] || a.m[k] != b.m[k];
                bad = other;
            }
            if (bad && lock_bad++ < tdiff_max) {
                printf("LOCKSTEP word %llu differs\n", (unsigned long long)lock_n - 1);
                print_st("core", a); print_st("v1  ", b);
            }
            mine.pop_front(); theirs.pop_front();
            if (lock_bad > (uint64_t)tdiff_max) stop = true;
        }
        if (!noidle && in_done && inq.empty() && fin.empty()) {
            if (++idle_clocks > 20000) stop = true;
        }
        if (!quiet && (clocks & ((1ULL << 26) - 1)) == 0)
            fprintf(stderr, "clk %llu words %llu outs %llu bad %llu trace %llu/%llu\n", (unsigned long long)clocks,
                    (unsigned long long)words, (unsigned long long)outs, (unsigned long long)out_bad,
                    (unsigned long long)tcmp, (unsigned long long)tbad);
    }
    uint64_t work = words - nwait;
    printf("clocks %llu, words %llu (%llu one-word waits), work words %llu\n", (unsigned long long)clocks,
           (unsigned long long)words, (unsigned long long)nwait, (unsigned long long)work);
    printf("clk_sys per word %.4f, per work word %.4f; D clocks %llu (waiting on the scoreboard %llu), X clocks %llu\n",
           double(clocks) / words, double(clocks) / (work ? work : 1),
           (unsigned long long)(st_cnt[2] + st_cnt[6]), (unsigned long long)st_cnt[6], (unsigned long long)st_cnt[3]);
    printf("deferred R-file writes (a word writing two) %llu\n", (unsigned long long)rf2w);
    printf("DM page (R1031): %llu accesses through the cache (%llu writes), %llu fills, %llu clocks a read waited for its word;"
           " port: %llu reads, %llu writes; buffer / ROM: %llu reads, %llu writes\n",
           (unsigned long long)dm_acc, (unsigned long long)dm_wr, (unsigned long long)dm_fill, (unsigned long long)dm_wait,
           (unsigned long long)sdm_rd, (unsigned long long)sdm_wr, (unsigned long long)x_rd, (unsigned long long)x_wr);
    printf("out FIFO words %llu, %llu differ from MAME's\n", (unsigned long long)outs, (unsigned long long)out_bad);
    printf("buffer / ROM reads from the capture (R1042): core %llu (%llu at another address), v1 %llu (%llu)\n",
           (unsigned long long)r_n, (unsigned long long)r_bad, (unsigned long long)vr_n, (unsigned long long)vr_bad);
    if (out_bad)
        printf("  the differences in ulps (same sign): 1: %llu, 2-3: %llu, 4-15: %llu, 16-255: %llu, 256-65535: %llu, "
               "more: %llu, exponent-wide: %llu; sign differs: %llu; core above MAME %llu, below %llu\n",
               (unsigned long long)ulp_h[0], (unsigned long long)ulp_h[1], (unsigned long long)ulp_h[2], (unsigned long long)ulp_h[3],
               (unsigned long long)ulp_h[4], (unsigned long long)ulp_h[5], (unsigned long long)ulp_h[6], (unsigned long long)ulp_h[7],
               (unsigned long long)ulp_up, (unsigned long long)ulp_dn);
    if (!big_pc.empty()) {
        printf("  the pushes with 16 ulps or more, by the pushing word (pc: those / all its pushes):");
        std::vector<std::pair<uint64_t, uint32_t>> v;
        for (auto &kv : big_pc) v.push_back({kv.second, kv.first});
        std::sort(v.rbegin(), v.rend());
        for (size_t k = 0; k < v.size() && k < 12; k++) printf(" %05x: %llu/%llu", v[k].second, (unsigned long long)v[k].first, (unsigned long long)all_pc[v[k].second]);
        printf("\n");
    }
    if (trp) printf("trace: %llu words compared against MAME's, %llu differ%s; state hash differs at %llu\n", (unsigned long long)tcmp,
                    (unsigned long long)tbad, pconly ? " (PC only)" : "", (unsigned long long)thash);
    if (lock) {
        printf("lockstep: %llu words compared against v1, %llu differ; v1 out words %llu, %llu differ from MAME's\n",
               (unsigned long long)lock_n, (unsigned long long)lock_bad, (unsigned long long)vouts, (unsigned long long)vout_bad);
    }
    printf("unsupported: %s\n", unsup_seen ? "YES" : "none");
    if (profp) {
        FILE *pf = fopen(profp, "w");
        for (auto &kv : prof) fprintf(pf, "%05x %llu %llu\n", kv.first, (unsigned long long)kv.second.first, (unsigned long long)kv.second.second);
        fclose(pf);
    }
    bool fail = (out_bad && !outok) || (vout_bad && !outok) || tbad || lock_bad || unsup_seen || (r_bad && !outok) || (vr_bad && !outok);
    printf(fail ? "FAIL\n" : "PASS\n");
    delete t;
    return fail;
}
