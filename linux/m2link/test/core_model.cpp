// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// THE CORE'S SIDE OF THE PAGE, IN C++, for the m2link tests that need more
// cabinets than a Verilator bench can run in real time. It keeps the contract
// rtl/io/m2_comm.sv keeps (tb_m2_comm checks the RTL; R916's second addendum
// has the rules), with the fake game on top, paced at 57.5 Hz:
//
//   * the shared RAM, its rx area (0x21c0-0x2fbf) in two banks
//   * a vblank: the game's block (0x2000-0x21bf) copied to the tick
//     snapshot, any offer taken, zfg flipped every vblank while the mailbox
//     says so (not linked, both sockets up), zfg_delay 2 and linktimer =
//     link_framesync when linked; held instead while linktimer is still set
//   * an FG read: past zfg_delay, an offer is taken (block to the take
//     snapshot, bank swap, zfg flip) and the read returns the new zfg; with
//     linktimer set it waits (the i960 held) until a vsync token is taken
//
//   core_model --mem FILE (--master|--slave) [--car N] [--seconds S]
//              [--spin-us N] [--start-frame N] [--stop-at S] [--access-ns N]
//              [--hz F]

#include "fake_game.h"

#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/mman.h>
#include <thread>
#include <unistd.h>

namespace {
volatile std::sig_atomic_t g_stop = 0;
void on_signal(int) { g_stop = 1; }
constexpr size_t kSize = 0xb000, kStatus = 0x4000, kMailbox = 0x4008, kSnapT = 0x4800, kSnapD = 0x4c00, kBank1 = 0x8000;
using Clock = std::chrono::steady_clock;

struct Core : GameIO {
    volatile uint8_t *m;
    long access_ns = 0, hold_ms = 800; // the RTL gives up after 48 video frames
    double hz = 57.524;
    Clock::time_point next_vbl{};       // video runs on while the game is held
    uint8_t cn = 0, fg = 0, zfg = 0, rxbank = 0, fs_wait = 0, tick_pend = 0, take_tick = 0, zfg_delay = 0;
    uint8_t taken = 0, taken_tick = 0, tick_evt = 0, cnwr = 0, hb = 0;
    uint64_t held_ns = 0, holds = 0, timeouts = 0, ticks = 0;
    explicit Core(volatile uint8_t *mm) : m(mm) {}

    void wait() const {
        if (!access_ns) return;
        const auto t = Clock::now() + std::chrono::nanoseconds(access_ns);
        while (Clock::now() < t) {}
    }
    uint32_t mbox() const { return *reinterpret_cast<const volatile uint32_t *>(m + kMailbox); }
    bool linked() const { return mbox() >> 11 & 1; }
    bool fs_hold() const { return fs_wait && (mbox() >> 12 & 1) && linked(); }
    bool offer() const { return cn && uint8_t(mbox()) != taken; }

    void status() {
        const uint32_t lo = uint32_t(tick_evt) | uint32_t(taken) << 8 | uint32_t(taken_tick) << 16 | uint32_t(cnwr) << 24;
        const uint32_t hi = uint32_t(cn) | uint32_t(fg) << 1 | uint32_t(zfg) << 2 | uint32_t(rxbank) << 3 |
                            uint32_t(fs_wait) << 4 | uint32_t(tick_pend) << 5 | uint32_t(take_tick) << 6 |
                            uint32_t(hb) << 8 | 0x4C02u << 16;
        volatile uint32_t *w = reinterpret_cast<volatile uint32_t *>(m + kStatus);
        w[0] = lo;
        w[1] = hi;
    }
    void snapshot(size_t to) {
        for (int i = 0; i < 0x1c0; i += 4) {
            wait();
            *reinterpret_cast<volatile uint32_t *>(m + to + i) = *reinterpret_cast<const volatile uint32_t *>(m + 0x2000 + i);
        }
    }
    // An event: the snapshot, then everything at once.
    void event(bool is_tick) {
        snapshot(is_tick ? kSnapT : kSnapD);
        const uint32_t mb = mbox();
        const bool take = cn && uint8_t(mb) != taken;
        if (take) {
            taken = uint8_t(mb);
            rxbank = mb >> 8 & 1;
            take_tick = is_tick;
            zfg ^= mb >> 9 & 1;
        }
        if (is_tick) {
            if (mb >> 13 & 1) zfg ^= 1;
            if (mb >> 11 & 1) zfg_delay = 2;
            fs_wait = (mb >> 11 & 1) && (mb >> 12 & 1);
            taken_tick = uint8_t(mb);
            ++tick_evt;
            ++ticks;
        } else if (take && (mb >> 10 & 1)) fs_wait = 0;
        status();
    }
    void vblank() {
        ++hb;
        if (cn) {
            if (fs_hold()) tick_pend = 1;
            else event(true);
        }
        status();
    }
    size_t at(int off) const {
        const int o = off & 0x3fff;
        return (rxbank && o >= 0x21c0 && o < 0x2fc0) ? kBank1 + size_t(o) : size_t(o);
    }

    uint8_t rd8(int off) override { wait(); return m[at(off)]; }
    uint32_t rd32(int off) override { wait(); return *reinterpret_cast<const volatile uint32_t *>(m + (at(off) & ~size_t(3))); }
    void wr32(int off, uint32_t v) override { wait(); *reinterpret_cast<volatile uint32_t *>(m + (at(off) & ~size_t(3))) = v; }
    uint8_t fg_read() override {
        wait();
        const auto t0 = Clock::now();
        bool held = false;
        for (;;) {
            if (cn && tick_pend) {
                if (!fs_hold()) { tick_pend = 0; event(true); continue; }
                if (offer()) { event(false); continue; }
            } else if (cn && zfg_delay) {
                --zfg_delay;
                break;
            } else if (offer()) { event(false); continue; }
            else if (!(cn && fs_hold())) break;
            // held: link_framesync's wait, until a token is taken
            if (!held) { held = true; ++holds; }
            // the video frames go on: the heartbeat, and a vblank that
            // finds the wait still on is held (one for all of them)
            if (Clock::now() >= next_vbl) {
                next_vbl = Clock::now() + std::chrono::nanoseconds(int64_t(1e9 / hz));
                ++hb;
                if (cn && fs_hold()) tick_pend = 1;
                status();
            }
            if (Clock::now() - t0 > std::chrono::milliseconds(hold_ms)) { fs_wait = 0; ++timeouts; continue; }
            std::this_thread::sleep_for(std::chrono::microseconds(20));
        }
        if (held) held_ns += uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - t0).count());
        return uint8_t(fg | (zfg ? 0 : 0x80) | 0x7e);
    }
    void cn_write(uint8_t v) override {
        wait();
        cn = v & 1;
        fs_wait = tick_pend = zfg_delay = 0;
        if (!cn) { fg = 0; zfg = 0; }
        else {
            for (int i = 0; i < 0x4000; i++) m[i] = 0;
            m[1] = 0x02;
            m[2] = m[3] = 0xff;
            m[0x13] = 0x0e;
            m[0x14] = 0xc0;
            m[0x15] = 0x01;
            rxbank = 0;
            taken = uint8_t(mbox());
        }
        ++cnwr;
        status();
    }
    void fg_write(uint8_t v) override {
        wait();
        fg = v & 1;
        status();
    }
};
} // namespace

int main(int argc, char **argv) {
    const char *path = nullptr;
    bool master = false;
    int car = 1, spin_us = 50000, start_frame = 30;
    double seconds = 10, stop_at = 0, hz = 57.524;
    long access_ns = 0, hold_ms = 800;
    for (int i = 1; i < argc; i++) {
        const std::string a = argv[i];
        if (a == "--mem") path = argv[++i];
        else if (a == "--master") master = true;
        else if (a == "--slave") master = false;
        else if (a == "--car") car = std::atoi(argv[++i]);
        else if (a == "--seconds") seconds = std::atof(argv[++i]);
        else if (a == "--spin-us") spin_us = std::atoi(argv[++i]);
        else if (a == "--start-frame") start_frame = std::atoi(argv[++i]);
        else if (a == "--stop-at") stop_at = std::atof(argv[++i]);
        else if (a == "--access-ns") access_ns = std::atol(argv[++i]);
        else if (a == "--hz") hz = std::atof(argv[++i]);
        else if (a == "--hold-ms") hold_ms = std::atol(argv[++i]);
        else {
            std::fprintf(stderr, "core_model: unknown %s\n", a.c_str());
            return 2;
        }
    }
    if (!path) return 2;
    const int fd = ::open(path, O_RDWR | O_CREAT, 0644);
    if (fd < 0 || ::ftruncate(fd, kSize) != 0) return 1;
    void *p = ::mmap(nullptr, kSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) return 1;
    volatile uint8_t *m = static_cast<volatile uint8_t *>(p);
    for (size_t i = 0; i < kSize; i++) m[i] = 0; // the power-on clear

    Core core(m);
    core.access_ns = access_ns;
    core.hold_ms = hold_ms;
    core.hz = hz;
    FakeGame game(core, master, car, spin_us);
    const auto period = std::chrono::nanoseconds(int64_t(1e9 / hz));
    auto t = Clock::now();
    const auto t0 = t, t_end = t + std::chrono::milliseconds(int64_t(seconds * 1000));
    char who[64];
    std::snprintf(who, sizeof who, "core:%s", path);
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);
    for (int f = 0; Clock::now() < t_end && !g_stop; f++) {
        if (stop_at > 0 && Clock::now() - t0 > std::chrono::milliseconds(int64_t(stop_at * 1000))) {
            std::this_thread::sleep_until(t_end); // a core that stops (another core loaded)
            break;
        }
        core.next_vbl = t + period;
        core.vblank();
        if (f == start_frame) game.start();
        game.frame();
        t += period;
        // Video runs on while the game is held: vblanks it missed are not
        // owed (one interrupt stands for them all, as on the board).
        if (Clock::now() > t + period) t = Clock::now();
        std::this_thread::sleep_until(t);
    }
    game.report(who);
    std::printf("%s: held %llu times, %.1f ms in all, %llu gave up; vblanks processed %llu\n", who,
                (unsigned long long)core.holds, double(core.held_ns) / 1e6, (unsigned long long)core.timeouts, (unsigned long long)core.ticks);
    return 0;
}
