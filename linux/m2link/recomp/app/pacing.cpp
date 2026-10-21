#include "app/pacing.h"

#include <algorithm>
#include <cmath>
#include <cstdio>

namespace app {

namespace {

constexpr double kArcadeHz = kArcadeFrameHz;
constexpr int kMaxEvery = 8;                               // up to a 460 Hz display

} // namespace

Pacing choose_pacing(double refresh_hz, const PacingSettings &s) {
    if (s.vrr) return {Pacing::Mode::Vrr, 1, kArcadeHz};
    if (refresh_hz > 0) {
        if (s.smooth) // a multiple of the arcade's rate: its own speed, within 1%
            for (int n = 1; n <= kMaxEvery; ++n)
                if (std::fabs(refresh_hz / n - kArcadeHz) <= 0.01 * kArcadeHz) return {Pacing::Mode::Display, n, refresh_hz / n};
        if (s.sync_display) // the first whole division of the refresh at or below 61 Hz, if it is 56 or more
            for (int n = 1; n <= kMaxEvery; ++n)
                if (refresh_hz / n <= 61.0) {
                    if (refresh_hz / n >= 56.0) return {Pacing::Mode::Display, n, refresh_hz / n};
                    break;
                }
    }
    return {Pacing::Mode::Clock, 1, kArcadeHz};
}

std::string Pacing::describe(double refresh_hz) const {
    char display[48] = "";
    if (refresh_hz > 0) std::snprintf(display, sizeof display, " on a %.2f Hz display", refresh_hz);
    char s[160];
    switch (mode) {
    case Mode::Clock: std::snprintf(s, sizeof s, "the arcade's speed, 57.52 frames/s%s", display); break;
    case Mode::Display: {
        char each[32] = "every refresh";
        if (every > 1) std::snprintf(each, sizeof each, "every %d refreshes", every);
        const double speed = (game_hz / kArcadeHz - 1.0) * 100.0;
        char change[32] = "";
        if (std::fabs(speed) >= 0.05) std::snprintf(change, sizeof change, ", %+.1f%% speed", speed);
        std::snprintf(s, sizeof s, "synced, %.2f frames/s, a frame %s%s%s", game_hz, each, display, change);
        break;
    }
    case Mode::Vrr: std::snprintf(s, sizeof s, "VRR, 57.52 frames/s, each held to 17.38 ms%s", display); break;
    }
    return s;
}

void Pacer::set(const Pacing &p, uint64_t now_ns) {
    pacing_ = p;
    pause(now_ns);
}

void Pacer::pause(uint64_t now_ns) {
    pending_ = 0;
    last_ = start_ = deadline_ = now_ns;
    run_ = passes_ = 0;
}

int Pacer::frames(uint64_t now_ns) {
    const double frame_ns = 1e9 / pacing_.game_hz;
    switch (pacing_.mode) {
    case Pacing::Mode::Clock: { // as the game always ran: the wall time owed, at most four frames of it
        pending_ = std::min(pending_ + double(now_ns - last_), frame_ns * 4);
        last_ = now_ns;
        int n = 0;
        while (pending_ >= frame_ns) ++n, pending_ -= frame_ns;
        return n;
    }
    case Pacing::Mode::Display: {
        // One frame every `every` passes: the display's vsync paces them. The
        // wall clock only keeps the game from running ahead (vsync forced off
        // in the driver) and starts the count again after a stall.
        ++passes_;
        double ahead = double(run_) - double(now_ns - start_) / frame_ns;
        if (ahead < -4) {
            start_ = now_ns, run_ = 0, passes_ = uint64_t(pacing_.every);
            ahead = 0;
        }
        if (passes_ % uint64_t(pacing_.every) || ahead >= 2) return 0;
        ++run_;
        return 1;
    }
    case Pacing::Mode::Vrr: { // one frame, due a frame after the last one (or now, after a stall)
        const uint64_t step = uint64_t(std::llround(frame_ns));
        if (now_ns > deadline_ + step) deadline_ = now_ns;
        deadline_ += step;
        return 1;
    }
    }
    return 0;
}

uint64_t Pacer::wait_ns(uint64_t now_ns) const {
    return pacing_.mode == Pacing::Mode::Vrr && now_ns < deadline_ ? deadline_ - now_ns : 0;
}

} // namespace app
