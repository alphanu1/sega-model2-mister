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
void ck(const char *what, uint64_t got, uint64_t want) {
    ++checks;
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
    if (file_page && w >= kComm && w < kComm + 0xa00) {
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
    if (file_page && w >= kComm && w < kComm + 0xa00) std::memcpy(const_cast<uint8_t *>(file_page) + size_t(w - kComm) * 8, &old, 8);
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
        const bool comm = wr_addr >= kComm && wr_addr < kComm + 0x802;
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
            std::printf("  FAIL: access to %x stalled for ever\n", byte_addr);
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
    ck("power-on: status magic", status_word() >> 40, 0x4B4C01);

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

    // zfg from m2link's mailbox: bit 7 of FG falls, within the refresh gap.
    wr64(kComm + 0x801, 1, 0xff);
    long n = 0;
    uint32_t fgv = 0;
    do {
        fgv = (access(false, 0x4000, 0x4, 0) >> 16) & 0xff;
        idle(int(rng() % 20));
    } while (fgv != 0x7f && ++n < 20000);
    ck("mailbox zfg=1: FG reads 0x7f (fg 1, ~zfg 0)", fgv, 0x7f);
    ck("  ... within ~1,024 cycles of reads", n < 400, 1);
    settle();
    ck("status: the zfg the core now returns (bit 26) is 1", (status_word() >> 26) & 1, 1);
    wr64(kComm + 0x801, 0, 0xff);
    n = 0;
    do {
        fgv = (access(false, 0x4000, 0x4, 0) >> 16) & 0xff;
    } while (fgv != 0xff && ++n < 20000);
    ck("mailbox zfg=0: FG back to 0xff", fgv, 0xff);
    settle();
    ck("status: and back to 0", (status_word() >> 26) & 1, 0);

    // STATUS WORD: vblanks, heartbeats, FG reads, CN writes.
    settle();
    const uint64_t s0 = status_word();
    for (int i = 0; i < 5; i++) {
        d->tick = 1;
        d->frame = 1;
        cycle();
        idle(500);
    }
    for (int i = 0; i < 7; i++) access(false, 0x4002, 0x4, 0);
    settle();
    const uint64_t s1 = status_word();
    ck("status: 5 vblanks", uint8_t(s1 - s0), 5);
    ck("status: 5 heartbeats", uint8_t((s1 >> 32) - (s0 >> 32)), 5);
    ck("status: 7 FG reads", uint8_t((s1 >> 8) - (s0 >> 8)), 7);
    ck("status: cn 1, fg 1", (s1 >> 24) & 3, 3);

    // THE RESET COMMAND: cn = fg = 0, and zfg 0 whatever the mailbox says --
    // from a zfg of 1 that the core has already taken in.
    wr64(kComm + 0x801, 1, 0xff);
    n = 0;
    do fgv = (access(false, 0x4000, 0x4, 0) >> 16) & 0xff;
    while (fgv != 0x7f && ++n < 20000);
    ck("zfg 1 taken in before the reset command", fgv, 0x7f);
    idle(5000); // any refresh still owed has landed: only the command can clear it
    access(true, 0x4000, 0x1, 0);
    oracle.cn_w(0);
    ck("CN=0: cn_r", access(false, 0x4000, 0x1, 0) & 0xff, oracle.cn_r());
    idle(3000);
    ck("CN=0: fg_r (fg 0, zfg 0 despite the mailbox)", (access(false, 0x4000, 0x4, 0) >> 16) & 0xff, oracle.fg_r());
    settle();
    const uint64_t s2 = status_word();
    ck("status: one more CN write", uint8_t((s2 >> 16) - (s1 >> 16)), 1);
    ck("status: cn 0, fg 0", (s2 >> 24) & 3, 0);
    ck("CN=0 leaves the RAM alone", access(false, 0x14, 0xf, 0), 0x000001c0);
    wr64(kComm + 0x801, 0, 0xff);

    // ONE DWORD WITH BOTH: cn_w then fg_w (recomp dev_write order).
    access(true, 0x4000, 0x5, 0x00010001);
    oracle.cn_w(1);
    oracle.fg_w(1);
    ck("CN+FG in one dword: regs", access(false, 0x4000, 0x5, 0), uint32_t(oracle.cn_r()) | uint32_t(oracle.fg_r()) << 16);
    access(true, 0x4000, 0x5, 0x00010000); // cn_w(0) then fg_w(1)
    oracle.cn_w(0);
    oracle.fg_w(1);
    ck("CN=0,FG=1 in one dword: regs", access(false, 0x4000, 0x5, 0), uint32_t(oracle.cn_r()) | uint32_t(oracle.fg_r()) << 16);

    // A REFRESH IN FLIGHT WHEN THE RESET COMMAND LANDS: what it brings back
    // must not undo the command.
    access(true, 0x4000, 0x5, 0x00010001);
    wr64(kComm + 0x801, 1, 0xff);
    idle(5000);
    (void)access(false, 0x4000, 0x4, 0); // starts a refresh (the gap has run out)
    access(true, 0x4000, 0x1, 0);        // and the command lands while it is out
    idle(3000);
    ck("reset command during a refresh: zfg 0", (access(false, 0x4000, 0x4, 0) >> 16) & 0xff, 0xfe);

    // THE GAME'S RESET (device_reset): cn = fg = zfg = 0; the RAM kept.
    access(true, 0x4000, 0x5, 0x00010001);
    n = 0;
    do fgv = (access(false, 0x4000, 0x4, 0) >> 16) & 0xff;
    while (fgv != 0x7f && ++n < 20000);
    idle(5000);
    access(true, 0x100, 0xf, 0xcafef00d);
    d->game_rst_n = 0;
    idle(4);
    d->game_rst_n = 1;
    idle(4); // the block takes it through two flops
    ck("game reset: cn 0, fg 0", access(false, 0x4000, 0x5, 0), 0x00fe00fe);
    ck("game reset keeps the RAM", access(false, 0x100, 0xf, 0), 0xcafef00d);
    wr64(kComm + 0x801, 0, 0xff);

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
    long st = 0;
    for (int i = 0; i < 500; i++) {
        access(rng() & 1, rng() % 0x4010, 0xf, rng());
        st += stall_cycles_last;
    }
    for (int i = 0; i < 3; i++) {
        d->tick = 1;
        d->frame = 1;
        cycle();
        idle(100);
    }
    settle();
    ck("off: never stalls", st, 0);
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
    if (fd < 0 || ::ftruncate(fd, 0x5000) != 0) return 1;
    void *p = ::mmap(nullptr, 0x5000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) return 1;
    file_page = static_cast<volatile uint8_t *>(p);
    for (int i = 0; i < 0x5000; i++) file_page[i] = 0xff; // DDR3 at power-on: anything
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
