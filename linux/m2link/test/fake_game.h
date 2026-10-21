// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// A STAND-IN FOR DAYTONA'S USE OF THE COMMUNICATION BOARD, for the link
// tests. What it does is what MAME 0.289 showed the real game doing (study
// R916, a Lua tap on 0x01a00000-0x01a1ffff, two linked cabinets):
//
//   start:  CN 0, FG 0, read CN, CN 1, FG = 1 on the master / 0 on a slave
//   each vblank: read FG; once the status byte says linked, spin on FG
//           until zfg (bit 7) flips -- a slave spins ~3,000 reads a frame --
//           then read the status bytes, the received slots (0x21c0..) when
//           it flipped, and write this cabinet's own block at 0x2000
//           (Daytona: 0x1c0 bytes)
//
// The block it writes is a pattern that says who wrote it and in which of
// its frames, so the far end can tell a whole block from a torn one (part
// of one frame, part of another), and a fresh one from a repeat.
#pragma once

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <set>

struct GameIO {
    virtual ~GameIO() = default;
    virtual uint8_t rd8(int off) = 0;
    virtual uint32_t rd32(int off) = 0; // off a multiple of 4, little-endian
    virtual void wr32(int off, uint32_t v) = 0;
    virtual uint8_t fg_read() = 0;      // FG: fg | ~zfg << 7 | 0x7e
    virtual void cn_write(uint8_t v) = 0;
    virtual void fg_write(uint8_t v) = 0;
};

class FakeGame {
public:
    static constexpr int kSlot = 0x1c0, kWords = kSlot / 4, kTx = 0x2000, kRx = 0x21c0;
    FakeGame(GameIO &io, bool master, int car, int spin_us) : io_(io), master_(master), car_(car), spin_us_(spin_us) {}

    void start() {
        io_.cn_write(0);
        io_.fg_write(0);
        (void)io_.fg_read();
        io_.cn_write(1);
        io_.fg_write(master_ ? 1 : 0);
        last_bit_ = io_.fg_read() >> 7;
        started_ = true;
    }

    void frame() {
        ++frame_;
        if (!started_) return;
        uint8_t f = io_.fg_read();
        if (io_.rd8(0) == 1) {
            ++linked_frames_;
            // the spin, bounded (the real one gives up too, eventually)
            const auto t0 = std::chrono::steady_clock::now();
            while ((f >> 7) == last_bit_ &&
                   std::chrono::steady_clock::now() - t0 < std::chrono::microseconds(spin_us_))
                f = io_.fg_read();
            const bool flipped = (f >> 7) != last_bit_;
            last_bit_ = f >> 7;
            id_ = io_.rd8(2);
            count_ = io_.rd8(3);
            // The slots are read when the board says a frame came (the flip);
            // a spin that gives up reads nothing new.
            if (flipped) {
                ++flips_;
                check_rx();
            } else ++no_flip_;
        } else last_bit_ = f >> 7;
        write_tx();
    }

    void write_tx() {
        for (int k = 0; k < kWords; k++) io_.wr32(kTx + 4 * k, word(car_, frame_, k));
    }

    // The slot from the cabinet before this one. Whole: every word is the
    // same car and frame. Torn: words from two frames. A repeat: the same
    // frame as last time (no new data this frame).
    void check_rx() {
        const uint32_t w0 = io_.rd32(kRx);
        if ((w0 >> 24) != 0xA5) {
            ++rx_none_;
            return;
        }
        const int car = int((w0 >> 20) & 0xf);
        const uint32_t fr = (w0 >> 8) & 0xfff;
        bool whole = true;
        for (int k = 1; k < kWords && whole; k++) whole = io_.rd32(kRx + 4 * k) == word(car, fr, k);
        if (!whole) {
            // The first frames after the link comes up are the one place the
            // hand-over cannot cover: the game wrote its block before it knew
            // it was linked (it writes it every frame, linked or not).
            if (linked_frames_ <= 3) {
                ++rx_torn_linkup_;
                return;
            }
            if (++rx_torn_ <= 3) std::printf("torn: frame %u (linked frame %llu): car %d frame %u in word 0\n", unsigned(frame_),
                                             (unsigned long long)linked_frames_, car, unsigned(fr));
            return;
        }
        cars_seen_.insert(car);
        if (have_rx_ && fr == last_rx_frame_) ++rx_repeat_;
        else ++rx_ok_;
        // SKEW: this cabinet's frame less the one whose block it just took.
        // Cabinets held together keep it within a frame or two; free-running
        // ones at different rates walk it away.
        if (linked_frames_ > 60) {
            const int d = int((frame_ - fr) & 0xfff);
            if (d < skew_min_) skew_min_ = d;
            if (d > skew_max_) skew_max_ = d;
        }
        have_rx_ = true;
        last_rx_frame_ = fr;
        // and the slots further round the ring (0x2380.., ...)
        for (int s = 2; s < 8; s++) {
            const uint32_t v = io_.rd32(kRx + (s - 1) * kSlot);
            if ((v >> 24) == 0xA5) cars_seen_.insert(int((v >> 20) & 0xf));
        }
    }

    static uint32_t word(int car, uint32_t frame, int k) {
        return 0xA5000000u | uint32_t(car & 0xf) << 20 | (frame & 0xfff) << 8 | uint32_t((k * 37 + frame) & 0xff);
    }

    void report(const char *who) const {
        std::printf("%s: frames %llu linked %llu id %d of %d flips %llu (spins given up %llu) rx ok %llu repeat %llu torn %llu none %llu link-up-torn %llu cars",
                    who, (unsigned long long)frame_, (unsigned long long)linked_frames_, id_, count_,
                    (unsigned long long)flips_, (unsigned long long)no_flip_, (unsigned long long)rx_ok_, (unsigned long long)rx_repeat_,
                    (unsigned long long)rx_torn_, (unsigned long long)rx_none_, (unsigned long long)rx_torn_linkup_);
        for (int c : cars_seen_) std::printf(" %d", c);
        if (skew_max_ >= 0) std::printf(" skew %d..%d", skew_min_, skew_max_);
        std::printf("\n");
        std::fflush(stdout);
    }

    uint64_t rx_ok() const { return rx_ok_; }
    uint64_t rx_torn() const { return rx_torn_; }
    int id() const { return id_; }
    int count() const { return count_; }

private:
    GameIO &io_;
    bool master_;
    int car_, spin_us_;
    bool started_ = false, have_rx_ = false;
    uint8_t last_bit_ = 1;
    uint32_t frame_ = 0, last_rx_frame_ = 0;
    uint64_t linked_frames_ = 0, flips_ = 0, no_flip_ = 0, rx_torn_linkup_ = 0, rx_ok_ = 0, rx_repeat_ = 0, rx_torn_ = 0, rx_none_ = 0;
    int id_ = 0, count_ = 0, skew_min_ = 1 << 20, skew_max_ = -1;
    std::set<int> cars_seen_;
};
