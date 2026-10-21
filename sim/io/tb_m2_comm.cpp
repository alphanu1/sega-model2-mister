// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// m2_comm (study R916): the communication board's registers and shared RAM,
// in DDR3, against THE RECOMP'S CommBoard as the oracle (linux/m2link/recomp,
// verbatim) -- the Daytona USA recompilation is the reference for link play.
//
// The block goes through the real m2_ddr3_arb and m2_ddr3 to a DDRAM model
// that says BUSY at random and answers after a random latency, while the
// arbiter's other port carries framebuffer-like bursts. The CPU side is
// driven as m2_cpu_bridge drives it: io_sel held while stall is high, rdata
// sampled on the first cycle it is low.
//
// Unwritten DDR3 reads all ones (docs/mister-integration.md), so a clear that
// misses a word shows. The sweep runs BUSY 0-90% and latency up to 120
// cycles, past anything measured on the board (R351: 13 typical, 50 worst).
//
//   +seed=N  +busy=PCT  +lat=MAX  (one configuration; default: the sweep)
//   +mem=FILE  +run=SECONDS  +vblank=CYCLES   THE INTEGRATION MODE: the comm
//      page is FILE (shared with a running m2link --mem FILE), and the fake
//      game (linux/m2link/test/fake_game.h) runs on the RTL for SECONDS of
//      wall time, a vblank every CYCLES cycles.

#include "Vm2_comm_harness.h"
#include "verilated.h"

#include "runtime/comm_board.h" // the oracle: the recomp's, verbatim
#include "../../linux/m2link/test/fake_game.h"

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fcntl.h>
#include <random>
#include <string>
#include <sys/mman.h>
#include <unistd.h>
#include <unordered_map>
#include <vector>

namespace {

Vm2_comm_harness *d;
std::mt19937 rng;
long checks = 0, fails = 0;
const char *last_ck = "";
void ck(const char *what, uint64_t got, uint64_t want) {
    ++checks;
    last_ck = what;
    if (got != want) {
        if (++fails < 40) std::printf("  FAIL %-52s got %llx want %llx\n", what, (unsigned long long)got, (unsigned long long)want);
    }
}

// ------------------------------------------------------------- the DDRAM
constexpr uint32_t kComm = 0x06100000; // DDRAM word of byte 0x30800000
constexpr uint32_t kFbLo = 0x06000000, kFbHi = 0x06040000;
std::unordered_map<uint32_t, uint64_t> mem;
volatile uint8_t *file_page = nullptr; // integration mode: the comm page is a file
int busy_pct = 30, lat_max = 40;
long comm_writes_outside = 0, fb_writes_outside = 0, comm_txn = 0;
long fill_beats_after_status = 0;
bool status_seen_since_cn = false;

uint64_t rd64(uint32_t w) {
    if (file_page && w >= kComm && w < kComm + 0x1600) {
        uint64_t v;
        std::memcpy(&v, const_cast<uint8_t *>(file_page) + size_t(w - kComm) * 8, 8);
        return v;
    }
    auto it = mem.find(w);
    return it == mem.end() ? ~0ull : it->second;
}
void wr64(uint32_t w, uint64_t v, uint8_t be) {
    uint64_t old = rd64(w);
    for (int i = 0; i < 8; i++)
        if (be >> i & 1) old = (old & ~(0xffull << (8 * i))) | (v & (0xffull << (8 * i)));
    if (file_page && w >= kComm && w < kComm + 0x1600) std::memcpy(const_cast<uint8_t *>(file_page) + size_t(w - kComm) * 8, &old, 8);
    else mem[w] = old;
}

struct Rd {
    uint32_t addr;
    int left, wait;
};
std::deque<Rd> rq;
uint32_t wr_addr = 0;
int wr_left = 0;
long t_cycle = 0;

// One clock. Inputs for the cycle are set; the DUT settles; the DDRAM model
// takes what the master presents (accepted when not BUSY); the edge.
uint8_t cur_busy = 0;
void ddram_pre() {
    d->DDRAM_BUSY = cur_busy;
    d->DDRAM_DOUT_READY = 0;
    if (!rq.empty() && rq.front().wait <= 0 && (rng() % 100) >= 10) {
        Rd &r = rq.front();
        d->DDRAM_DOUT = rd64(r.addr);
        d->DDRAM_DOUT_READY = 1;
        r.addr++;
        if (--r.left == 0) rq.pop_front();
    }
    for (auto &r : rq) r.wait--;
}
void ddram_take() {
    if (cur_busy) return;
    if (d->DDRAM_WE) {
        if (wr_left == 0) {
            wr_addr = d->DDRAM_ADDR;
            wr_left = d->DDRAM_BURSTCNT ? d->DDRAM_BURSTCNT : 1;
        }
        const bool comm = wr_addr >= kComm && wr_addr < kComm + 0x9b8;   // RAM, status, mailbox, snapshots
        const bool fb = wr_addr >= kFbLo && wr_addr < kFbHi;
        if (!comm && !fb) ++comm_writes_outside;
        wr64(wr_addr, d->DDRAM_DIN, d->DDRAM_BE);
        if (comm && wr_addr == kComm + 0x800) status_seen_since_cn = true;
        else if (comm && wr_addr < kComm + 0x800 && status_seen_since_cn) ++fill_beats_after_status;
        wr_addr++;
        wr_left--;
    } else if (d->DDRAM_RD) {
        const int n = d->DDRAM_BURSTCNT ? d->DDRAM_BURSTCNT : 1;
        rq.push_back({uint32_t(d->DDRAM_ADDR), n, 1 + int(rng() % unsigned(lat_max))});
    }
}

// ------------------------------------------------------------- port a: framebuffer-like
int a_beat = 0;
struct A {
    bool on = true;
    int state = 0, beats = 0, idle = 0;
    uint32_t addr = 0;
    bool we = false;
    std::vector<uint64_t> wdata;
    long bursts = 0, bad = 0;
} pa;
std::unordered_map<uint32_t, uint64_t> fb_shadow;
void a_pre() {
    if (!pa.on) {
        d->a_req = 0;
        return;
    }
    if (pa.state == 0) {
        if (pa.idle > 0) {
            pa.idle--;
            d->a_req = 0;
            return;
        }
        pa.we = rng() & 1;
        pa.beats = 1 + int(rng() % 248);
        pa.addr = (kFbLo - 0x06000000) + (rng() % (0x40000 - 256));
        pa.wdata.clear();
        for (int i = 0; i < pa.beats; i++) pa.wdata.push_back((uint64_t(rng()) << 32) | rng());
        pa.state = 1;
        pa.idle = int(rng() % 200);
        a_beat = 0;
    }
    d->a_req = 1;
    d->a_we = pa.we;
    d->a_addr = pa.addr;
    d->a_blen = uint8_t(pa.beats);
    d->a_din = pa.we ? pa.wdata[size_t(std::min<int>(a_beat, pa.beats - 1))] : 0;
}
// The DUT's outputs in the cycle before the edge: what a flip-flop samples.
struct Pre {
    uint8_t a_wacc, a_rvalid, a_ack, stall;
    uint64_t dout;
    uint32_t rdata;
};
void a_post(const Pre &p) {
    if (!pa.on || pa.state == 0) return;
    if (pa.we && p.a_wacc) {
        fb_shadow[0x06000000 + pa.addr + uint32_t(a_beat)] = pa.wdata[size_t(a_beat)];
        a_beat++;
    }
    if (!pa.we && p.a_rvalid) {
        const uint32_t w = 0x06000000 + pa.addr + uint32_t(a_beat);
        auto it = fb_shadow.find(w);
        const uint64_t want = it == fb_shadow.end() ? ~0ull : it->second;
        if (p.dout != want) pa.bad++;
        a_beat++;
    }
    if (p.a_ack) {
        // a requester drops req on the edge that shows it ack
        pa.state = 0;
        pa.bursts++;
    }
}

Pre step() {
    cur_busy = (rng() % 100) < unsigned(busy_pct);
    ddram_pre();
    a_pre();
    d->clk = 0;
    d->eval();
    const Pre p{d->a_wacc, d->a_rvalid, d->a_ack, d->stall, d->dout, d->rdata};
    ddram_take();
    d->clk = 1;
    d->eval();
    a_post(p);
    d->tick = 0;
    d->frame = 0;
    ++t_cycle;
    return p;
}
void cycle() { (void)step(); }

// ------------------------------------------------------------- the CPU, as the bridge
long stall_cycles_last = 0;
uint32_t access(bool we, uint32_t byte_addr, uint8_t be, uint32_t wdata) {
    d->sel = 1;
    d->we = we;
    d->addr = uint16_t(byte_addr & 0xffff);
    d->be = be;
    d->wdata = wdata;
    long n = 0;
    for (;;) {
        const Pre p = step();
        const bool stall = p.stall;
        const uint32_t r = p.rdata;
        if (!stall) {
            d->sel = 0;
            stall_cycles_last = n;
            return r;
        }
        if (++n > 2000000) {
            std::printf("  FAIL: access to %x stalled for ever (after \"%s\")\n", byte_addr, last_ck);
            ++fails;
            d->sel = 0;
            return 0xdeadbeef;
        }
    }
}
void idle(int n) {
    for (int i = 0; i < n; i++) cycle();
}

// The oracle's transport: both cables unplugged (the recomp's board with a
// transport attached, nobody at the other end).
struct Unplugged : rt::LinkTransport {
    void poll() override {}
    bool rx_open() const override { return false; }
    bool tx_open() const override { return false; }
    int read(uint8_t *, int) override { return 0; }
    bool write(const uint8_t *, int) override { return false; }
};

uint32_t ram32(const std::vector<uint8_t> &r, uint32_t a) {
    uint32_t v;
    std::memcpy(&v, &r[a & 0x3ffc], 4);
    return v;
}
uint32_t lanes(uint8_t be) {
    uint32_t m = 0;
    for (int i = 0; i < 4; i++)
        if (be >> i & 1) m |= 0xffu << (8 * i);
    return m;
}
uint64_t status_word() { return rd64(kComm + 0x800); }

void reset_all(bool fitted) {
    mem.clear();
    fb_shadow.clear();
    rq.clear();
    wr_left = 0;
    d->rst_n = 0;
    d->game_rst_n = 0;
    d->fitted = fitted;
    d->sel = 0;
    d->tick = 0;
    d->frame = 0;
    d->a_req = 0;
    pa = A{};
    for (int i = 0; i < 4; i++) {
        d->clk = 0;
        d->eval();
        d->clk = 1;
        d->eval();
    }
    d->rst_n = 1;
    d->game_rst_n = 1;
}

// Wait until the block has nothing to do (status written, clear finished).
void settle() { idle(250000); }

// ------------------------------------------------------------- the checks
void run_config(int seed) {
    rng.seed(unsigned(seed));
    std::printf("-- seed %d, BUSY %d%%, latency 1-%d\n", seed, busy_pct, lat_max);
    reset_all(true);
    settle();

    // POWER-ON: everything clear, as m_shared{} and the zero-initialised
    // registers; the status word says who is here.
    bool all0 = true;
    for (uint32_t w = 0; w < 0x802; w++) all0 &= (w == 0x800) || rd64(kComm + w) == 0;
    ck("power-on: 16 KB + mailbox clear", all0, 1);
    ck("power-on: status magic and version", status_word() >> 48, 0x4C02);

    Unplugged up;
    std::vector<uint8_t> oram(0x4000, 0);
    rt::CommBoard oracle(oram.data());
    oracle.set_transport(&up);

    // Registers at reset: cn_r = 0xfe, fg_r = 0xfe.
    ck("CN read (byte 0)", access(false, 0x4000, 0x1, 0) & 0xff, oracle.cn_r());
    ck("FG read (byte 2)", (access(false, 0x4002, 0x4, 0) >> 16) & 0xff, oracle.fg_r());
    ck("CN|FG dword", access(false, 0x14000, 0x5, 0), uint32_t(oracle.cn_r()) | uint32_t(oracle.fg_r()) << 16);
    ck("register reads never stall", stall_cycles_last, 0);
    ck("unmapped 0x4004 reads 0", access(false, 0x4004, 0xf, 0), 0);
    ck("unmapped 0xfffc reads 0", access(false, 0xfffc, 0xf, 0), 0);

    // RANDOM RAM TRAFFIC, both mirrors, every lane combination the i960
    // makes: bytes, halves, words.
    for (int i = 0; i < 3000; i++) {
        const uint32_t a = (rng() % 0x4000) & ~3u;
        const uint32_t mirror = (rng() & 1) ? 0x10000 : 0;
        static const uint8_t bes[] = {1, 2, 4, 8, 3, 0xc, 0xf};
        const uint8_t be = bes[rng() % 7];
        if (rng() % 3) {
            const uint32_t v = rng();
            access(true, mirror | a, be, v);
            const uint32_t m = lanes(be);
            const uint32_t o = (ram32(oram, a) & ~m) | (v & m);
            std::memcpy(&oram[a], &o, 4);
        } else {
            const uint32_t got = access(false, mirror | a, be, 0);
            char what[64];
            std::snprintf(what, sizeof what, "RAM read %04x be %x", a, be);
            ck(what, got & lanes(be), ram32(oram, a) & lanes(be));
        }
        if ((rng() % 8) == 0) idle(int(rng() % 50));
    }

    // THE INIT COMMAND, with a write in flight just before it: the clear
    // lands after the write, and the next RAM access waits for the clear.
    access(true, 0x2000, 0xf, 0x12345678);
    status_seen_since_cn = false;
    fill_beats_after_status = 0;
    access(true, 0x4000, 0x1, 1);
    oracle.cn_w(1);
    const uint32_t first = access(false, 0x2000, 0xf, 0);
    ck("RAM read right after CN=1 waits for the clear", first, 0);
    ck("  ... and it did wait (cycles > 2048 beats)", stall_cycles_last > 2048, 1);
    std::vector<uint8_t> got(0x4000);
    for (uint32_t a = 0; a < 0x4000; a += 4) {
        const uint32_t v = access(false, (rng() & 1 ? 0x10000 : 0) | a, 0xf, 0);
        std::memcpy(&got[a], &v, 4);
    }
    int diff = 0;
    for (int i = 0; i < 0x4000; i++) diff += got[i] != oram[i];
    ck("init: all 16 KB as the recomp's cn_w(1) + comm_tick leaves them", diff, 0);
    ck("init: header 0x00-0x03", ram32(got, 0), 0xffff0200);
    ck("init: header 0x10-0x13", ram32(got, 0x10), 0x0e000000);
    ck("init: header 0x14-0x17", ram32(got, 0x14), 0x000001c0);
    settle();
    ck("status: CN's count published only after the clear", fill_beats_after_status, 0);

    // FG = 1 (the master): fg_r 0xff with zfg 0.
    access(true, 0x4000, 0x4, 0x00010000);
    oracle.fg_w(1);
    ck("FG=1: fg_r", (access(false, 0x4000, 0x4, 0) >> 16) & 0xff, oracle.fg_r());
    ck("FG=1: cn_r", access(false, 0x4000, 0x1, 0) & 0xff, oracle.cn_r());

    // ================= THE HAND-OVER (R916 addendum 2) =================
    // m2link's side, done here directly on the DDRAM model: a block into a
    // bank, an offer in the mailbox.
    int zfg = 0;                                  // what FG bit 7 should say: ~zfg
    auto fgval = [&]() { return (access(false, 0x4000, 0x4, 0) >> 16) & 0xff; };
    auto want_fg = [&](int fgb) { return uint32_t(fgb | (zfg ? 0 : 0x80) | 0x7e); };
    auto mbox = [&](uint8_t seq, int bank, int flip, int tok, int linked, int fsync, int ttog) {
        wr64(kComm + 0x801, uint64_t(seq) | uint64_t(bank) << 8 | uint64_t(flip) << 9 | uint64_t(tok) << 10 |
             uint64_t(linked) << 11 | uint64_t(fsync) << 12 | uint64_t(ttog) << 13, 0xff);
    };
    auto put_block = [&](int bank, uint32_t tag) {
        for (uint32_t w = 0x438; w < 0x5f8; w++)
            wr64(kComm + (bank ? 0x1000u : 0u) + w, (uint64_t(tag | (w * 2 + 1)) << 32) | (tag | w * 2), 0xff);
    };
    auto rx_is = [&](uint32_t tag) {   // the game's view of 0x21c0-0x2fbf, through the CPU port
        bool ok = true;
        for (uint32_t a = 0x21c0; a < 0x2fc0; a += 4 * 37) ok &= access(false, a, 0xf, 0) == (tag | (a >> 2));
        return ok;
    };
    auto put_tx = [&](uint32_t tag) {
        for (uint32_t a = 0x2000; a < 0x21c0; a += 4) access(true, a, 0xf, tag | a);
    };
    auto snap_is = [&](uint32_t word, uint32_t tag) {
        bool ok = true;
        for (uint32_t i = 0; i < 56; i++) {
            const uint64_t v = rd64(kComm + word + i);
            const uint32_t a = 0x2000 + i * 8;
            ok &= uint32_t(v) == (tag | a) && uint32_t(v >> 32) == (tag | (a + 4));
        }
        return ok;
    };
    auto st = [&](int lo, int bits) { return (status_word() >> lo) & ((1ull << bits) - 1); };
    auto pulse_tick = [&]() { d->tick = 1; d->frame = 1; cycle(); };
    uint8_t seq = uint8_t(st(8, 8));
    const int fgb = 1;                      // FG = 1 from above (the master)

    // 1. An offer, not linked (no zfg_delay): an FG read takes it -- the
    // flip is in the very read that takes it; the slots now come from bank 1;
    // the game's block was copied to the take snapshot first.
    put_tx(0x10000000);
    put_block(1, 0x11000000);
    mbox(++seq, 1, 1, 0, 0, 0, 0);
    zfg ^= 1;
    long n = 0;
    uint32_t fgv = 0;
    const long c0 = t_cycle;
    do fgv = fgval(); while (fgv != want_fg(fgb) && ++n < 200000);
    ck("offer: an FG read takes it and returns the flip", fgv, want_fg(fgb));
    ck("  ... within the refresh pace + one copy (< 30,000 cycles here)", t_cycle - c0 < 30000, 1);
    ck("  ... once: the next reads say the same", fgval() == want_fg(fgb) && fgval() == want_fg(fgb), 1);
    settle();
    ck("status: taken = the offer", st(8, 8), seq);
    ck("status: rx bank 1, taken at an FG read (bit 38 = 0)", st(35, 1) << 1 | st(38, 1), 2);
    ck("the game reads the slots from bank 1", rx_is(0x11000000), 1);
    ck("take snapshot = the game's block at the take", snap_is(0x980, 0x10000000), 1);
    ck("the game's own block is not banked", access(false, 0x2000, 0xf, 0), 0x10002000);

    // 2. Two frames in one offer: the recomp's loop flips twice -- no flip
    // seen -- and the slots are the newest's.
    put_block(0, 0x12000000);
    mbox(++seq, 0, 0, 0, 0, 0, 0);
    for (int i = 0; i < 200 && st(8, 8) != seq; i++) { (void)fgval(); idle(20); settle(); }
    ck("even offer: taken", st(8, 8), seq);
    ck("  ... zfg unchanged", fgval(), want_fg(fgb));
    ck("  ... slots from bank 0, the newest", rx_is(0x12000000), 1);

    // 3. A vblank takes the offer that is there (after reading the mailbox
    // fresh) and copies the game's block to the tick snapshot.
    put_tx(0x13000000);
    put_block(1, 0x14000000);
    mbox(++seq, 1, 1, 0, 0, 0, 0);
    const uint64_t t0 = st(0, 8);
    pulse_tick();
    settle();
    zfg ^= 1;
    ck("vblank: one tick event", st(0, 8), (t0 + 1) & 0xff);
    ck("vblank: took the offer, at the tick (bit 38), taken-at-tick", st(8, 8) | st(38, 1) << 8 | st(16, 8) << 9,
       uint64_t(seq) | 1 << 8 | uint64_t(seq) << 9);
    ck("vblank: zfg flipped", fgval(), want_fg(fgb));
    ck("vblank: tick snapshot = the block at the vblank", snap_is(0x900, 0x13000000), 1);
    ck("vblank: slots from bank 1", rx_is(0x14000000), 1);

    // 4. Not linked, both sockets up: zfg flips every vblank (comm_tick's
    // zfg ^= 1), with nothing offered.
    mbox(seq, 1, 1, 0, 0, 0, 1);
    pulse_tick(); settle(); zfg ^= 1;
    ck("waiting for the link: vblank flips zfg", fgval(), want_fg(fgb));
    pulse_tick(); settle(); zfg ^= 1;
    ck("  ... and again", fgval(), want_fg(fgb));

    // 5. Linked: a vblank sets zfg_delay 2 -- the next two FG reads take
    // nothing, however long the offer has been there; the third does.
    mbox(seq, 1, 0, 0, 1, 0, 0);
    pulse_tick(); settle();
    put_block(0, 0x15000000);
    mbox(++seq, 0, 1, 0, 1, 0, 0);
    idle(3000);
    (void)fgval(); idle(3000);
    (void)fgval(); idle(3000); settle();
    ck("zfg_delay: two FG reads after a vblank take nothing", st(8, 8), uint8_t(seq - 1));
    zfg ^= 1;
    n = 0;
    do fgv = fgval(); while (fgv != want_fg(fgb) && ++n < 200000);
    ck("  ... the third does", fgv, want_fg(fgb));
    settle();
    ck("  ... status", st(8, 8), seq);

    // 6. LINK_FRAMESYNC. Linked with framesync: a vblank sets linktimer;
    // past zfg_delay an FG read is HELD until a vsync token is taken.
    mbox(seq, 0, 0, 0, 1, 1, 0);
    pulse_tick(); settle();
    ck("framesync: the vblank sets the wait (bit 36)", st(36, 1), 1);
    (void)fgval(); (void)fgval();             // zfg_delay
    auto begin_fg = [&]() { d->sel = 1; d->we = 0; d->addr = 0x4000; d->be = 0x4; d->wdata = 0; };
    auto run_until_done = [&](long max) {     // the access already presented; step until it completes
        for (long i = 0; i < max; i++) {
            const Pre p = step();
            if (!p.stall) { d->sel = 0; return i; }
        }
        return -1L;
    };
    begin_fg();
    ck("framesync: the third FG read is held", run_until_done(50000), uint64_t(-1L));
    mbox(++seq, 0, 0, 1, 1, 1, 0);           // a vsync token, no data
    const long held = run_until_done(400000);
    ck("  ... and let go when the token is taken", held >= 0, 1);
    settle();
    ck("  ... status: the wait off, the token's offer taken", st(36, 1) | st(8, 8) << 1, uint64_t(seq) << 1);
    ck("  ... no flip for a token", fgval(), want_fg(fgb));

    // A vblank that finds the wait still on is HELD (comm_tick's wait): no
    // tick event, and the next FG read waits for the token, which releases
    // the vblank first -- the game sees it all at once.
    pulse_tick(); settle();                   // sets the wait
    (void)fgval(); (void)fgval();
    const uint64_t te = st(0, 8);
    pulse_tick(); settle();                   // the wait is still on: held
    ck("framesync: a vblank in the wait is held (bit 37), no event", st(37, 1) | (st(0, 8) == te) << 1, 3);
    begin_fg();
    ck("  ... the FG read waits for it (even with zfg_delay)", run_until_done(50000), uint64_t(-1L));
    mbox(++seq, 0, 0, 1, 1, 1, 0);
    ck("  ... the token releases it", run_until_done(400000) >= 0, 1);
    settle();
    ck("  ... then the held vblank: one event, the wait on again", (st(0, 8) == ((te + 1) & 0xff)) | st(36, 1) << 1, 3);

    // The wait gives up after TMO_FRAMES video frames: a dead link cannot
    // freeze the core. (The read the held vblank came out on was the first
    // of its zfg_delay, as the recomp's first read after comm_tick is.)
    (void)fgval();
    begin_fg();
    ck("framesync: held", run_until_done(5000), uint64_t(-1L));
    long gave = -1;
    for (int f = 0; f < 60 && gave < 0; f++) {
        d->frame = 1;
        gave = run_until_done(2000);
    }
    ck("  ... let go after ~48 frames of no token", gave >= 0, 1);
    d->sel = 0;

    // 7. The reset command ends it all: zfg, the wait, the held vblank.
    pulse_tick(); settle();
    access(true, 0x4000, 0x1, 0);
    settle();
    zfg = 0;
    ck("CN=0: wait, held vblank off", st(36, 2), 0);
    ck("CN=0: FG", fgval(), 0xfe);
    mbox(seq, 0, 0, 0, 0, 0, 0);
    access(true, 0x4000, 0x5, 0x00010001);    // CN 1 again, FG 1
    settle();
    ck("init: rx bank 0 again", st(35, 1), 0);

    // THE GAME'S RESET (device_reset): cn = fg = zfg = 0; the RAM kept.
    mbox(seq, 0, 0, 0, 0, 0, 1);              // flip at every vblank
    pulse_tick(); settle();
    ck("before the game reset: zfg 1", fgval(), 0x7f);
    access(true, 0x100, 0xf, 0xcafef00d);
    d->game_rst_n = 0;
    idle(4);
    d->game_rst_n = 1;
    idle(4); // the block takes it through two flops
    ck("game reset: cn 0, fg 0, zfg 0", access(false, 0x4000, 0x5, 0), 0x00fe00fe);
    ck("game reset keeps the RAM", access(false, 0x100, 0xf, 0), 0xcafef00d);
    mbox(seq, 0, 0, 0, 0, 0, 0);

    // PORT A, the framebuffer's stand-in, was bursting throughout.
    settle();
    ck("framebuffer bursts all whole (reads matched writes)", pa.bad, 0);
    ck("framebuffer bursts ran", pa.bursts > 50, 1);
    ck("no write outside the two regions", comm_writes_outside, 0);

    // OFF: no board. Never stalls; no DDR3 traffic past the power-on clear.
    reset_all(false);
    pa.on = false;
    settle();
    mem.clear();
    long stalls = 0;
    for (int i = 0; i < 500; i++) {
        access(rng() & 1, rng() % 0x4010, 0xf, rng());
        stalls += stall_cycles_last;
    }
    for (int i = 0; i < 3; i++) {
        d->tick = 1;
        d->frame = 1;
        cycle();
        idle(100);
    }
    settle();
    ck("off: never stalls", stalls, 0);
    ck("off: no DDR3 writes at all", mem.size(), 0);
    ck("off: no status (m2link stays idle)", status_word(), ~0ull);
}

// ------------------------------------------------------------- integration mode
struct RtlIO : GameIO {
    uint8_t rd8(int off) override { return uint8_t(access(false, uint32_t(off) & ~3u, 0xf, 0) >> (8 * (off & 3))); }
    uint32_t rd32(int off) override { return access(false, uint32_t(off), 0xf, 0); }
    void wr32(int off, uint32_t v) override { access(true, uint32_t(off), 0xf, v); }
    uint8_t fg_read() override { return uint8_t(access(false, 0x4000, 0x4, 0) >> 16); }
    void cn_write(uint8_t v) override { access(true, 0x4000, 0x1, v); }
    void fg_write(uint8_t v) override { access(true, 0x4000, 0x4, uint32_t(v) << 16); }
};

int integration(const char *path, double seconds, long vblank, bool master, int car, int spin_us) {
    const int fd = ::open(path, O_RDWR | O_CREAT, 0644);
    if (fd < 0 || ::ftruncate(fd, 0xb000) != 0) return 1;
    void *p = ::mmap(nullptr, 0xb000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) return 1;
    file_page = static_cast<volatile uint8_t *>(p);
    for (int i = 0; i < 0xb000; i++) file_page[i] = 0xff; // DDR3 at power-on: anything
    busy_pct = 20;
    lat_max = 30;
    reset_all(true);
    pa.on = true;
    RtlIO io;
    FakeGame game(io, master, car, spin_us);
    const auto t_end = std::chrono::steady_clock::now() + std::chrono::milliseconds(long(seconds * 1000));
    long frames = 0, next_vbl = t_cycle + vblank;
    while (std::chrono::steady_clock::now() < t_end) {
        if (t_cycle >= next_vbl) {
            next_vbl += vblank;
            d->tick = 1;
            d->frame = 1;
            cycle();
            if (++frames == 30) game.start();
            game.frame();
        } else idle(64);
    }
    char who[32];
    std::snprintf(who, sizeof who, "rtl:%s", master ? "master" : "slave");
    game.report(who);
    std::printf("rtl: %ld frames, %ld cycles (%.1f MHz of simulation), framebuffer bursts %ld bad %ld\n", frames, t_cycle,
                double(t_cycle) / seconds / 1e6, pa.bursts, pa.bad);
    return 0;
}

} // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    d = new Vm2_comm_harness;
    int seed = -1;
    const char *memf = nullptr;
    double run = 20;
    long vblank = 200000;
    bool master = false;
    int car = 2, spin_us = 50000;
    for (int i = 1; i < argc; i++) {
        const std::string a = argv[i];
        auto val = [&](const char *k) { return a.rfind(k, 0) == 0 ? argv[i] + std::strlen(k) : nullptr; }; // argv outlives a
        if (auto v = val("+seed=")) seed = std::atoi(v);
        else if (auto v2 = val("+busy=")) busy_pct = std::atoi(v2);
        else if (auto v3 = val("+lat=")) lat_max = std::atoi(v3);
        else if (auto v4 = val("+mem=")) memf = v4;
        else if (auto v5 = val("+run=")) run = std::atof(v5);
        else if (auto v6 = val("+vblank=")) vblank = std::atol(v6);
        else if (a == "+master") master = true;
        else if (auto v7 = val("+car=")) car = std::atoi(v7);
        else if (auto v8 = val("+spin=")) spin_us = std::atoi(v8);
    }
    if (memf) return integration(memf, run, vblank, master, car, spin_us);
    if (seed >= 0) run_config(seed);
    else {
        const int busy[] = {0, 30, 90}, lat[] = {1, 40, 120};
        int s = 1;
        for (int b : busy)
            for (int l : lat) {
                busy_pct = b;
                lat_max = l;
                run_config(s++);
            }
    }
    std::printf("== m2_comm: %ld checks, %ld failed\n", checks, fails);
    delete d;
    return fails ? 1 : 0;
}
