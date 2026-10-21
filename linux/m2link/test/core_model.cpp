// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// THE CORE'S SIDE OF THE PAGE, IN C++, for the m2link tests that need more
// cabinets than a Verilator bench can run in real time. It does what
// rtl/io/m2_comm.sv does to the page m2link maps (tb_m2_comm checks the RTL
// against the recomp's CommBoard; this is the same contract):
//
//   0x0000-0x3fff shared RAM; the init command clears it and writes the
//                 header (byte 1 = 2, 0x12-0x15 = 00 0e c0 01, 2-3 = ff ff)
//   0x4000        status: [7:0] vblanks, [15:8] FG reads, [23:16] CN writes,
//                 [24] cn, [25] fg, [26] zfg as FG reads return it,
//                 [39:32] heartbeat, [63:40] 0x4B4C01
//   0x4008        mailbox from m2link: [0] zfg
//
// with the fake game on top, paced at 57.5 Hz, standing in for Daytona.
//
//   core_model --mem FILE (--master|--slave) [--car N] [--seconds S]
//              [--spin-us N] [--start-frame N] [--stop-at S] [--access-ns N]

#include "fake_game.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/mman.h>
#include <thread>
#include <unistd.h>

namespace {
constexpr size_t kSize = 0x5000;

struct Core : GameIO {
    volatile uint8_t *m;
    uint8_t cn = 0, fg = 0, tick = 0, fgrd = 0, cnwr = 0, hb = 0;
    long access_ns = 0; // each access takes this long, as a DDR3 round trip does on the core
    explicit Core(volatile uint8_t *mm) : m(mm) {}
    void wait() const {
        if (!access_ns) return;
        const auto t = std::chrono::steady_clock::now() + std::chrono::nanoseconds(access_ns);
        while (std::chrono::steady_clock::now() < t) {}
    }

    void status() {
        const uint32_t lo = uint32_t(tick) | uint32_t(fgrd) << 8 | uint32_t(cnwr) << 16 | uint32_t(cn) << 24 | uint32_t(fg) << 25 |
                            uint32_t(zfg()) << 26;
        const uint32_t hi = uint32_t(hb) | 0x4B4C01u << 8;
        volatile uint32_t *w = reinterpret_cast<volatile uint32_t *>(m + 0x4000);
        w[0] = lo;
        w[1] = hi;
    }
    uint8_t zfg() const { return cn & (*reinterpret_cast<const volatile uint32_t *>(m + 0x4008) & 1); }

    uint8_t rd8(int off) override { wait(); return m[off & 0x3fff]; }
    uint32_t rd32(int off) override { wait(); return *reinterpret_cast<const volatile uint32_t *>(m + (off & 0x3ffc)); }
    void wr32(int off, uint32_t v) override { wait(); *reinterpret_cast<volatile uint32_t *>(m + (off & 0x3ffc)) = v; }
    uint8_t fg_read() override {
        const uint8_t v = uint8_t(fg | (zfg() ? 0 : 0x80) | 0x7e);
        ++fgrd;
        status();
        return v;
    }
    void cn_write(uint8_t v) override {
        cn = v & 1;
        if (!cn) fg = 0;
        else {
            for (int i = 0; i < 0x4000; i++) m[i] = 0;
            m[1] = 0x02;
            m[2] = m[3] = 0xff;
            m[0x13] = 0x0e;
            m[0x14] = 0xc0;
            m[0x15] = 0x01;
        }
        ++cnwr;
        status();
    }
    void fg_write(uint8_t v) override {
        fg = v & 1;
        status();
    }
};
} // namespace

int main(int argc, char **argv) {
    const char *path = nullptr;
    bool master = false;
    int car = 1, spin_us = 50000, start_frame = 30;
    double seconds = 10, stop_at = 0;
    long access_ns = 0;
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
    FakeGame game(core, master, car, spin_us);
    const auto period = std::chrono::nanoseconds(int64_t(1e9 / 57.524));
    auto t = std::chrono::steady_clock::now();
    const auto t0 = t, t_end = t + std::chrono::milliseconds(int64_t(seconds * 1000));
    char who[64];
    std::snprintf(who, sizeof who, "core:%s", path);
    for (int f = 0; std::chrono::steady_clock::now() < t_end; f++) {
        if (stop_at > 0 && std::chrono::steady_clock::now() - t0 > std::chrono::milliseconds(int64_t(stop_at * 1000))) {
            std::this_thread::sleep_until(t_end); // a core that stops (another core loaded)
            break;
        }
        ++core.hb;
        ++core.tick;
        core.status();
        if (f == start_frame) game.start();
        game.frame();
        t += period;
        std::this_thread::sleep_until(t);
    }
    game.report(who);
    return 0;
}
