// Frame pacing (issue #7): how many game frames each pass of the main loop
// runs, and when. Every setting is off by default, and then the game runs at
// the arcade's own rate on the wall clock, whatever the display's refresh:
// a faster display shows frames more often, never a faster game.
//
//   Clock    (default) game frames as the wall clock passes 1/57.52 s; the
//            display's vsync paces the passes.
//   Display  a game frame every `every` refreshes, so each is shown for the
//            same time. "Smooth pacing": a display at a multiple of the
//            arcade's rate (within 1%: 57.52, 115.05 Hz). "Sync to display":
//            a rate that divides evenly into the refresh between 56 and
//            61 Hz (60 frames/s on 60, 120, 180, 240 Hz: 4% fast).
//   Vrr      one game frame per pass, each pass held to 1/57.52 s, so a
//            G-Sync or FreeSync display refreshes at the game's rate.
#pragma once

#include <cstdint>
#include <string>

namespace app {

inline constexpr double kArcadeFrameHz = 16000000.0 / (656.0 * 424.0); // the board's (rt::GameLoop::kFrameHz)

struct Pacing {
    enum class Mode { Clock, Display, Vrr };
    Mode mode = Mode::Clock;
    int every = 1;          // Display: refreshes per game frame
    double game_hz = kArcadeFrameHz; // the rate the game runs at
    std::string describe(double refresh_hz) const; // for the launcher and the log
    bool operator==(const Pacing &o) const { return mode == o.mode && every == o.every && game_hz == o.game_hz; }
};

struct PacingSettings {
    bool smooth = false;       // a display at a multiple of the arcade's rate: one frame per refresh(es)
    bool sync_display = false; // a rate dividing evenly into the refresh, 56-61 Hz
    bool vrr = false;          // held to 57.52 Hz for a variable-refresh display
};

// refresh_hz: the display's, 0 when not known.
Pacing choose_pacing(double refresh_hz, const PacingSettings &settings);

// The per-pass bookkeeping. frames(now) is how many game frames to run this
// pass; wait_ns(now), in Vrr mode, how long to sleep before the pass.
class Pacer {
public:
    void set(const Pacing &p, uint64_t now_ns);
    const Pacing &pacing() const { return pacing_; }
    void pause(uint64_t now_ns); // the launcher is open: no frames owed
    int frames(uint64_t now_ns);
    uint64_t wait_ns(uint64_t now_ns) const;

private:
    Pacing pacing_;
    double pending_ = 0;    // Clock: wall time owed, ns
    uint64_t last_ = 0;     // Clock: the previous pass
    uint64_t start_ = 0;    // Display: the wall-clock reference
    uint64_t run_ = 0;      // Display: frames run since start_
    uint64_t passes_ = 0;   // Display: passes since start_
    uint64_t deadline_ = 0; // Vrr: when the next frame is due
};

} // namespace app
