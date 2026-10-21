// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// m2link: LINK PLAY FOR THE MODEL 2 CORE, the half that runs on MiSTer's
// Linux. Study R916 (the shape is R863's addendum).
//
// The core puts the communication board's 16 KB shared RAM in DDR3 and
// writes a status word beside it (rtl/io/m2_comm.sv); this program maps that
// page through /dev/mem and runs the board's protocol -- the Daytona USA
// recompilation's, the same frames at the same moments -- over the recomp's
// own TCP transport (app::TcpLink, verbatim). So a MiSTer is one more cabinet
// in the recomp's ring: the same frames, the same ports, the same master /
// slave from the game's test menu. Where a frame lands, when the game sees
// it, and link_framesync's wait are the core's (core_board.h says which half
// does what).
//
//   m2link [-c INI] [-v]                      on the MiSTer
//   m2link --mem FILE [...]                   a test: FILE stands for DDR3
//
// The INI (default /media/fat/linux/m2link.ini) holds only the network, in
// the recomp's names and with its defaults:
//
//   link_port = 15112             this cabinet listens here (the one before connects)
//   link_next = 192.168.1.20:15112   the next cabinet in the ring (host:port)
//   link_framesync = 0            1 on every cabinet: held in step (the core waits)
//
// Master or slave, car number: the game's own test menu (GAME SYSTEM >
// LINK ID, CAR NUMBER), exactly as on the recomp and the arcade.

#include "core_board.h"
#include "app/link_socket.h"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <memory>
#include <string>
#include <sys/mman.h>
#include <unistd.h>

namespace {

// Where the core keeps it (rtl/io/m2_comm.sv): 8 MB above the 3D framebuffer.
constexpr uint64_t kPhysBase = 0x30800000;
constexpr size_t kMapSize = m2link::CorePage::kSize;
int g_alive_ms = 500;                 // no video frame for this long: the core is gone
int g_sync_ms = 3000;                 // link_framesync: no vsync token for this long loses the link (the recomp's)

volatile sig_atomic_t g_stop = 0;
void on_signal(int) { g_stop = 1; }

bool g_verbose = false;
void say(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    std::fputs("m2link: ", stdout);
    std::vfprintf(stdout, fmt, ap);
    std::fputc('\n', stdout);
    std::fflush(stdout);
    va_end(ap);
}

uint64_t now_ms() {
    return uint64_t(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
}

// ------------------------------------------------------------------ the INI
struct Config {
    int link_port = 15112;                     // the recomp's defaults (src/app/config.h)
    std::string link_next = "127.0.0.1:15113";
    bool link_framesync = false;
};

std::string trim(const std::string &s) {
    const auto a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) return "";
    const auto b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
}

// MiSTer.ini's style: key = value, [sections] and ; or # comments ignored.
// Every problem is said and the default kept, so a typo never stops the link
// without a word.
void load_ini(const char *path, Config &cfg) {
    FILE *f = std::fopen(path, "r");
    if (!f) {
        say("%s: %s -- using the defaults", path, std::strerror(errno));
        return;
    }
    char line[512];
    int n = 0;
    while (std::fgets(line, sizeof line, f)) {
        ++n;
        std::string s = line;
        const auto c = s.find_first_of(";#");
        if (c != std::string::npos) s = s.substr(0, c);
        s = trim(s);
        if (s.empty() || s[0] == '[') continue;
        const auto eq = s.find('=');
        if (eq == std::string::npos) {
            say("%s:%d: \"%s\" is not key = value; ignored", path, n, s.c_str());
            continue;
        }
        const std::string k = trim(s.substr(0, eq)), v = trim(s.substr(eq + 1));
        if (k == "link_port") {
            char *end = nullptr;
            const long p = std::strtol(v.c_str(), &end, 10);
            if (v.empty() || *end || p < 1 || p > 65535) say("%s:%d: link_port \"%s\" is not a port (1-65535); keeping %d", path, n, v.c_str(), cfg.link_port);
            else cfg.link_port = int(p);
        } else if (k == "link_next") {
            std::string host;
            uint16_t port = 0;
            if (!app::TcpLink::parse_address(v, host, port)) say("%s:%d: link_next \"%s\" is not host:port; keeping %s", path, n, v.c_str(), cfg.link_next.c_str());
            else cfg.link_next = v;
        } else if (k == "link_framesync") {
            if (v == "0" || v == "1") cfg.link_framesync = v == "1";
            else say("%s:%d: link_framesync \"%s\" is not 0 or 1; keeping %d", path, n, v.c_str(), int(cfg.link_framesync));
        } else if (k == "link") {
            // the recomp's on/off; here, running this program is "on"
        } else say("%s:%d: unknown key \"%s\"; ignored", path, n, k.c_str());
    }
    std::fclose(f);
}

// ------------------------------------------------------------------ the core's page
std::string link_status(const m2link::CoreBoard &b, const app::TcpLink &l, const Config &cfg) {
    switch (b.link()) {
    case m2link::CoreBoard::Link::Off: return "on (the game has not started the link: set LINK ID in test mode)";
    case m2link::CoreBoard::Link::Waiting: {
        std::string s = "waiting: ";
        s += l.tx_open() ? "next cabinet " + cfg.link_next + " reached; "
                         : "next cabinet " + cfg.link_next + " not reached yet (is it listening on that port?); ";
        s += l.rx_open() ? "a cabinet is connected to port " + std::to_string(cfg.link_port)
                         : "no cabinet has connected to port " + std::to_string(cfg.link_port) + " yet";
        return s;
    }
    case m2link::CoreBoard::Link::Up:
        return "linked: cabinet " + std::to_string(b.id()) + " of " + std::to_string(b.count());
    case m2link::CoreBoard::Link::Lost: return "lost (reset the game to try again)";
    }
    return "?";
}

void usage() {
    std::fprintf(stderr,
                 "usage: m2link [-c INI] [-v] [--mem FILE] [--phys ADDR] [--seconds N]\n"
                 "  -c INI      settings (default /media/fat/linux/m2link.ini)\n"
                 "  -v          say more (every change of the core's registers)\n"
                 "  --mem FILE  map FILE instead of /dev/mem (tests; the page at offset 0)\n"
                 "  --phys ADDR the core's page (default 0x30800000)\n"
                 "  --seconds N stop after N seconds (tests)\n"
                 "  --alive-ms N the core is gone after N ms without a video frame (default 500;\n"
                 "              tests against a simulated core, whose frames are slow)\n"
                 "  --sync-timeout-ms N  link_framesync: lose the link after N ms without a token\n"
                 "              (default 3000, the recomp's; tests against a simulated core)\n"
                 "  --hold, --no-hold  accepted and ignored (the hand-over is the core's now)\n");
}

} // namespace

int main(int argc, char **argv) {
    const char *ini = "/media/fat/linux/m2link.ini";
    const char *mem_path = nullptr;
    uint64_t phys = kPhysBase;
    double seconds = 0;
    for (int i = 1; i < argc; i++) {
        const std::string a = argv[i];
        if (a == "-c" && i + 1 < argc) ini = argv[++i];
        else if (a == "-v") g_verbose = true;
        else if (a == "--mem" && i + 1 < argc) mem_path = argv[++i];
        else if (a == "--phys" && i + 1 < argc) phys = std::strtoull(argv[++i], nullptr, 0);
        else if (a == "--seconds" && i + 1 < argc) seconds = std::atof(argv[++i]);
        else if (a == "--no-hold" || a == "--hold") {
            // R916: the hand-over moved into the core (second addendum)
        }
        else if (a == "--alive-ms" && i + 1 < argc) g_alive_ms = std::atoi(argv[++i]); // tests: a simulated core's slow frames
        else if (a == "--sync-timeout-ms" && i + 1 < argc) g_sync_ms = std::atoi(argv[++i]); // tests: the same, for framesync
        else {
            usage();
            return 2;
        }
    }

    Config cfg;
    load_ini(ini, cfg);
    say("settings: link_port=%d link_next=%s link_framesync=%d", cfg.link_port, cfg.link_next.c_str(), int(cfg.link_framesync));
    if (cfg.link_next.find("XXX") != std::string::npos)
        say("link_next is still the example's placeholder (%s): set it to the next cabinet's IP address in the INI",
            cfg.link_next.c_str());
    if (cfg.link_next.rfind("127.", 0) == 0 || cfg.link_next.rfind("localhost:", 0) == 0)
        say("link_next is this machine (%s): set it to the next cabinet's address and port", cfg.link_next.c_str());

    // The core's page: /dev/mem at the physical address, uncached (O_SYNC),
    // as Main_MiSTer maps the FPGA's DDR3; or a file, for the tests.
    const int fd = mem_path ? ::open(mem_path, O_RDWR) : ::open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        say("cannot open %s: %s", mem_path ? mem_path : "/dev/mem", std::strerror(errno));
        return 1;
    }
    void *map = ::mmap(nullptr, kMapSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, mem_path ? 0 : off_t(phys));
    if (map == MAP_FAILED) {
        say("cannot map %s at 0x%llx: %s", mem_path ? mem_path : "/dev/mem", (unsigned long long)phys, std::strerror(errno));
        return 1;
    }
    volatile uint8_t *mem = static_cast<volatile uint8_t *>(map);

    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);
    std::signal(SIGPIPE, SIG_IGN);

    std::unique_ptr<app::TcpLink> link;
    std::unique_ptr<m2link::CoreBoard> board;
    const m2link::CorePage page{mem};
    uint8_t board_cn = 0xff, board_fg = 0xff;
    uint8_t last_hb = 0;
    uint64_t hb_ms = 0, t_end = seconds > 0 ? now_ms() + uint64_t(seconds * 1000) : 0;
    std::string said;
    bool waiting_said = false;

    while (!g_stop && (!t_end || now_ms() < t_end)) {
        const m2link::CoreStatus s = m2link::read_status(page);
        const uint64_t t = now_ms();

        // ---- is the core there? Its magic, and its heartbeat moving. Off in
        // the OSD, another core, or a stopped core: nothing is written into
        // that memory, and the sockets close (the other cabinets see the
        // link go, as they would a cabinet switched off).
        if (s.valid && s.hb != last_hb) {
            hb_ms = t;
            last_hb = s.hb;
        }
        const bool present = s.valid && hb_ms && t - hb_ms < uint64_t(g_alive_ms);
        if (!present) {
            if (board) {
                say("the core has stopped answering (another core, or Link board Off in the OSD): link closed");
                board.reset();
                link.reset();
                said.clear();
            }
            if (!waiting_said) {
                say("waiting for the Model 2 core with Link board On in its OSD");
                waiting_said = true;
            }
            ::usleep(20000);
            continue;
        }
        waiting_said = false;

        if (!board) {
            link = std::make_unique<app::TcpLink>(uint16_t(cfg.link_port), cfg.link_next);
            if (!link->error().empty()) {
                say("link: %s", link->error().c_str());
                return 1;
            }
            board = std::make_unique<m2link::CoreBoard>(page);
            board->set_transport(link.get());
            board->set_framesync(cfg.link_framesync);
            board->set_sync_timeout_ms(uint64_t(g_sync_ms));
            say("the core is here: listening on port %d, next cabinet %s", cfg.link_port, cfg.link_next.c_str());
            board->attach(s);
        }
        if (g_verbose && (s.cn != board_cn || s.fg != board_fg)) {
            say("CN %d FG %d", s.cn, s.fg);
            board_cn = s.cn;
            board_fg = s.fg;
        }
        const bool busy = board->poll(s);

        const std::string st = link_status(*board, *link, cfg);
        if (st != said) {
            say("%s", st.c_str());
            said = st;
        }
        if (!busy) ::usleep(100);
    }
    say("stopped");
    return 0;
}
