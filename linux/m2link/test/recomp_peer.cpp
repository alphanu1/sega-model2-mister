// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// A RECOMP CABINET WITHOUT THE GAME: the Daytona USA recompilation's own
// CommBoard and TcpLink (recomp/, verbatim at b33baeb), wired as its M2Board
// wires them (comm_board_->vblank() at vblank start; FG reads through fg_r(),
// which takes frames in), driven by the fake game at 57.5 Hz. The far end of
// every m2link test.
//
//   recomp_peer --listen PORT --next HOST:PORT (--master|--slave) [--car N]
//               [--seconds S] [--framesync] [--spin-us N] [--start-frame N] [--hz F]
//               [--display-hz F]   (the app's Clock pacing: passes at the display's
//               rate, frames owed at --hz, 57.5244 by default)

#include "runtime/comm_board.h"
#include "app/link_socket.h"
#include "app/pacing.h"
#include "fake_game.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

namespace {
struct RecompIO : GameIO {
    std::vector<uint8_t> &ram;
    rt::CommBoard &b;
    RecompIO(std::vector<uint8_t> &r, rt::CommBoard &bb) : ram(r), b(bb) {}
    uint8_t rd8(int off) override { return ram[size_t(off & 0x3fff)]; }
    uint32_t rd32(int off) override {
        uint32_t v;
        std::memcpy(&v, &ram[size_t(off & 0x3ffc)], 4);
        return v;
    }
    void wr32(int off, uint32_t v) override { std::memcpy(&ram[size_t(off & 0x3ffc)], &v, 4); }
    uint8_t fg_read() override { return b.fg_r(); }
    void cn_write(uint8_t v) override { b.cn_w(v); }
    void fg_write(uint8_t v) override { b.fg_w(v); }
};

const char *state(const rt::CommBoard &b) {
    switch (b.link()) {
    case rt::CommBoard::Link::Off: return "off";
    case rt::CommBoard::Link::Waiting: return "waiting";
    case rt::CommBoard::Link::Up: return "linked";
    case rt::CommBoard::Link::Lost: return "lost";
    }
    return "?";
}
} // namespace

int main(int argc, char **argv) {
    int listen = 0, car = 1, spin_us = 50000, start_frame = 30;
    std::string next;
    bool master = false, framesync = false;
    double seconds = 10, hz = app::kArcadeFrameHz, display_hz = 60;
    for (int i = 1; i < argc; i++) {
        const std::string a = argv[i];
        if (a == "--listen") listen = std::atoi(argv[++i]);
        else if (a == "--next") next = argv[++i];
        else if (a == "--master") master = true;
        else if (a == "--slave") master = false;
        else if (a == "--car") car = std::atoi(argv[++i]);
        else if (a == "--seconds") seconds = std::atof(argv[++i]);
        else if (a == "--framesync") framesync = true;
        else if (a == "--spin-us") spin_us = std::atoi(argv[++i]);
        else if (a == "--start-frame") start_frame = std::atoi(argv[++i]);
        else if (a == "--hz") hz = std::atof(argv[++i]);
        else if (a == "--display-hz") display_hz = std::atof(argv[++i]);
        else {
            std::fprintf(stderr, "recomp_peer: unknown %s\n", a.c_str());
            return 2;
        }
    }
    app::TcpLink link(uint16_t(listen), next);
    if (!link.error().empty()) {
        std::fprintf(stderr, "recomp_peer: %s\n", link.error().c_str());
        return 1;
    }
    std::vector<uint8_t> ram(0x4000, 0);
    rt::CommBoard board(ram.data());
    board.set_transport(&link);
    board.set_framesync(framesync);
    RecompIO io(ram, board);
    FakeGame game(io, master, car, spin_us);

    // THE RECOMP'S OWN PACING (src/app/pacing.cpp, verbatim in recomp/app):
    // Clock mode, the default -- each pass of the main loop, paced by the
    // display's vsync (display_hz), runs the game frames the wall clock owes
    // at game_hz, at most four frames' worth; a frame held in comm_tick or
    // fg_r (link_framesync) is owed back, as in the app.
    using SC = std::chrono::steady_clock;
    auto ns = [] { return uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(SC::now().time_since_epoch()).count()); };
    app::Pacing pacing;
    pacing.game_hz = hz;
    app::Pacer pacer;
    pacer.set(pacing, ns());
    const auto pass = std::chrono::nanoseconds(int64_t(1e9 / display_hz));
    auto t = SC::now();
    const auto t_end = t + std::chrono::milliseconds(int64_t(seconds * 1000));
    const char *last = "";
    char who[32];
    std::snprintf(who, sizeof who, "recomp:%d", listen);
    int f = 0;
    while (SC::now() < t_end) {
        for (int n = pacer.frames(ns()); n > 0; --n, ++f) {
            if (f == start_frame) game.start();
            board.vblank(); // M2Board::vblank_start
            game.frame();
            const char *s = state(board);
            if (std::strcmp(s, last)) {
                std::printf("%s: %s", who, s);
                if (board.link() == rt::CommBoard::Link::Up) std::printf(" cabinet %d of %d", board.id(), board.count());
                std::printf(" (frame %d)\n", f);
                std::fflush(stdout);
                last = s;
            }
        }
        t += pass;
        if (SC::now() > t + pass) t = SC::now();
        std::this_thread::sleep_until(t);
    }
    game.report(who);
    std::printf("%s: final %s %d of %d\n", who, state(board), board.id(), board.count());
    return 0;
}
