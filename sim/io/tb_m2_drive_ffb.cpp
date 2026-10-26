// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// m2_drive_ffb (R966): Daytona's drive board byte to MiSTer Main's force
// feedback word, against a C++ reference -- rt::DriveBoard copied unchanged
// from daytona-arcade-recomp (below), the board's two-equal-samples rule, and
// the mapping m2_drive_ffb's header states. Every output word is compared a
// few clocks after every input event (a frame, a port E write, a steering or
// OSD change).
//
//  1. THE GAME'S OWN STREAM (M2_DRVLOG = a MAME 0.289 drive_tap log, not
//     committed: ROM-derived): every PE write at its frame, MAME's own STEER
//     inputs, then the same stream under a steering sweep and random steering,
//     with each OSD setting (On / Off, Normal / Invert) and en low.
//  2. TRANSIENTS: bytes held under one frame are never taken, bytes held two
//     frames always are; random hold times 0.1-3 frames against the reference.
//  3. RESET: the latch's value is not a command until the firmware writes it;
//     a reset mid-stream drops ACTIVE until a byte is taken again.
//  4. en LOW (not Daytona): never ACTIVE, the word is 0, whatever arrives.
//  5. DIRECTION: 0x5- left / 0x6- right, uncentring away from the centre, and
//     Invert flipping both; every command byte against the reference.
//
// The frame here is FR clocks: m2_drive_ffb has no timing of its own (the
// frame is an input), so a short frame tests the same logic.
#include "Vm2_drive_ffb.h"
#include "verilated.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <vector>

// ---------------------------------------------------------------------------
// rt::DriveBoard, from daytona-arcade-recomp src/runtime/drive_board.h at
// f32c48ff9b (github.com/alphanu1/daytona-arcade-recomp).
// Copyright (c) 2026, Ben Templeman and contributors. BSD-3-Clause:
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
// 1. Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
// 3. Neither the name of the copyright holder nor the names of its
//    contributors may be used to endorse or promote products derived from
//    this software without specific prior written permission.
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.
namespace rt {

struct DriveBoard {
    enum class Effect : uint8_t { None, Resistance, Centre, CentreDeadZone, Uncentre, Force };
    bool motor_on = false; // off at power-on, until the game turns it on
    Effect effect = Effect::None;
    int strength = 0; // n, 0..7
    int direction = 1; // Force: +1 0x5- (right), -1 0x6- (left)

    void command(uint8_t cmd) {
        const int n = cmd & 7;
        switch (cmd >> 4) {
        case 0x0: motor_on = cmd == 0x0a || n >= 5; return;
        case 0x1: set(Effect::None, 0); return;
        case 0x2: set(cmd & 8 ? Effect::None : Effect::Resistance, n); return;
        case 0x3: set(cmd & 8 ? Effect::CentreDeadZone : Effect::Centre, n); return;
        case 0x4: set(cmd & 8 ? Effect::None : Effect::Uncentre, n); return;
        case 0x5:
        case 0x6:
            set(cmd & 8 ? Effect::None : Effect::Force, n);
            direction = (cmd >> 4) == 0x5 ? 1 : -1;
            return;
        default: return; // 0x7-: the spring's slope (not modelled); 0x8- and up: queries, nothing
        }
    }

    // The effect's strength, 0 when the motor is off or another effect runs.
    // The board's motor power is 0..63: about 7 + 2n for the springs and
    // resistance, 17 + 2n for uncentring and the constant force (its minimum
    // and the spring parameter the game sets included); 31 is the strongest.
    float level(Effect e) const {
        if (!motor_on || effect != e || e == Effect::None) return 0.0f;
        const bool push = e == Effect::Uncentre || e == Effect::Force;
        return float((push ? 17 : 7) + 2 * strength) / 31.0f;
    }
    // The constant force, -1 (left) .. +1 (right).
    float force() const { return level(Effect::Force) * float(direction); }

    // The force the board's own closed loop drives for a wheel at x (-1 full
    // left .. +1 full right; +1 pushes right), for a host device whose driver
    // has no spring effect (the launcher's centring override). The springs
    // push towards the centre, rising over 8% of the travel beyond their dead
    // zone (2%, or 6% for 0x38-0x3F) to their level: the board's ramp, about
    // 2 power steps per position step, reaches it within a few percent.
    // Uncentring pushes away; the constant force is as it is; resistance has
    // no direction and gives nothing here.
    float motor(float x) const {
        switch (effect) {
        case Effect::Centre:
        case Effect::CentreDeadZone: {
            const float dead = effect == Effect::CentreDeadZone ? 0.06f : 0.02f;
            const float ramp = std::clamp((std::fabs(x) - dead) / 0.08f, 0.0f, 1.0f);
            return -std::copysign(level(effect) * ramp, x);
        }
        case Effect::Uncentre: return std::copysign(level(effect), x); // at the centre: right, as the board's direction 1
        case Effect::Force: return force();
        default: return 0.0f;
        }
    }

private:
    void set(Effect e, int n) { effect = e, strength = n; }
};

} // namespace rt
// ---------------------------------------------------------------------------

using E = rt::DriveBoard::Effect;
static const int DEAD = 2, IDLE_SPRING = 51;

// The board's acceptance and m2_drive_ffb's mapping, on top of rt::DriveBoard.
struct Ref {
  rt::DriveBoard b;
  bool seen = false, have = false, started = false;
  uint8_t smp = 0;
  int last_taken = -1;               // for the stream's report: each change of the byte taken
  std::vector<uint8_t>* taken_log = nullptr;
  void frame(uint8_t pe) {           // the sample uses `seen` from before this clock's write
    if (!seen) return;
    if (have && pe == smp) {
      started = true; b.command(pe);
      if (taken_log && pe != last_taken) taken_log->push_back(pe);
      last_taken = pe;
    }
    smp = pe; have = true;
  }
  void stb() { seen = true; }
  uint64_t word(bool en, bool on, bool inv, uint8_t steer) const {
    if (!(en && on && started)) return 0;
    const bool idle = !b.motor_on || b.effect == E::None;
    int spring = idle ? IDLE_SPRING
               : int(std::lround(255.0f * std::max(b.level(E::Centre), b.level(E::CentreDeadZone))));
    int fric = int(std::lround(255.0f * b.level(E::Resistance)));
    // rt's sign: +1 = 0x5- and uncentring away from centre (copysign of x).
    // Here 0x5- is LEFT (negative); uncentring pushes the way the wheel is
    // turned (0x80 centre, higher = right), nothing within DEAD of it.
    float f = 0.0f;
    if (b.effect == E::Force) f = -b.force();
    else if (b.effect == E::Uncentre) {
      int x = int(steer) - 0x80;
      f = (std::abs(x) <= DEAD) ? 0.0f : b.motor(float(x) / 96.0f);
    }
    if (inv) f = -f;
    int c = int(std::lround(f * 32767.0f));
    return (uint64_t(0x03) << 48) | (uint64_t(uint16_t(c)) << 32) | (uint64_t(spring) << 24) |
           (uint64_t(0) << 16) | (uint64_t(fric) << 8) | 0;
  }
};

static Vm2_drive_ffb* d;
static long checks = 0, fails = 0;
static uint64_t cyc = 0;
static Ref ref;
static bool en = true, on = true, inv = false;
static uint8_t steer = 0x80, pe = 0;
static long n_active = 0, n_force = 0, n_unc = 0, n_spring = 0, n_fric = 0, n_idle = 0;

static void apply() { d->en = en; d->on = on; d->invert = inv; d->steer = steer; d->pe_cmd = pe; }
static void tick() { d->clk = 0; d->eval(); d->clk = 1; d->eval(); cyc++; }
// one clock with optional frame / write pulses; the model sees them in the RTL's order
static void clock(bool frame, bool write, uint8_t val) {
  if (write) pe = val;
  apply(); d->frame = frame; d->pe_stb = write;
  tick();
  d->frame = 0; d->pe_stb = 0;
  if (frame) ref.frame(pe);
  if (write) ref.stb();
}
static void check(const char* what) {
  for (int i = 0; i < 3; i++) { apply(); tick(); }
  uint64_t want = ref.word(en, on, inv, steer), got = d->ffb;
  checks++;
  if (got != want) {
    if (fails++ < 25)
      printf("FAIL %s cyc %llu: got %014llx want %014llx (pe %02x steer %02x en%d on%d inv%d motor%d eff%d n%d)\n",
             what, (unsigned long long)cyc, (unsigned long long)got, (unsigned long long)want, pe, steer,
             en, on, inv, ref.b.motor_on, int(ref.b.effect), ref.b.strength);
  }
  if (want) {
    n_active++;
    int16_t c = int16_t(want >> 32);
    if (ref.b.effect == E::Force && c) n_force++;
    if (ref.b.effect == E::Uncentre && c) n_unc++;
    if (((want >> 24) & 0xff) == unsigned(IDLE_SPRING)) n_idle++;
    else if ((want >> 24) & 0xff) n_spring++;
    if ((want >> 8) & 0xff) n_fric++;
  }
}
static void reset() {
  d->rst_n = 0; apply(); tick(); tick(); d->rst_n = 1; tick();
  ref = Ref(); pe = 0;
}

static const int FR = 256;   // clocks per frame

// A frame: the vblank pulse at clock 0, then `ev` events (PE writes or steering
// changes) at their offsets inside it, each checked.
struct Ev { int at; int kind; uint8_t v; };   // kind 0 = PE write, 1 = steer, 2 = OSD
static void run_frame(std::vector<Ev> ev) {
  std::sort(ev.begin(), ev.end(), [](const Ev& a, const Ev& b) { return a.at < b.at; });
  int t = 0;
  clock(true, false, 0); t++;
  check("frame"); t += 3;
  for (auto& e : ev) {
    int at = std::max(e.at, t);
    while (t < at) { clock(false, false, 0); t++; }
    if (e.kind == 0) clock(false, true, e.v);
    else { if (e.kind == 1) steer = e.v; else { on = e.v & 1; inv = (e.v >> 1) & 1; } clock(false, false, 0); }
    t++;
    check(e.kind == 0 ? "write" : "input"); t += 3;
  }
  while (t < FR) { clock(false, false, 0); t++; }
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vm2_drive_ffb;
  std::mt19937 rng(12345);
  for (int i = 1; i < argc; i++) if (!strncmp(argv[i], "+seed=", 6)) rng.seed(atoi(argv[i] + 6));
  d->clk = 0; d->frame = 0; d->pe_stb = 0;
  reset();

  // ------------------------------------------------ 1. the game's own stream
  struct PeW { int f; uint8_t v; };
  struct In { int f; uint8_t v; };
  std::vector<PeW> pw; std::vector<In> st;
  const char* lp = getenv("M2_DRVLOG");
  if (lp) {
    FILE* g = fopen(lp, "r");
    if (!g) { printf("cannot read %s\nFAIL\n", lp); return 1; }
    char line[512];
    while (fgets(line, sizeof line, g)) {
      int f; unsigned v;
      if (sscanf(line, "PE f= %d v=%x", &f, &v) == 2) pw.push_back({f, uint8_t(v)});
      else if (strstr(line, ":STEER") && sscanf(line, "IN f= %d", &f) == 1) {
        const char* q = strrchr(line, '=');
        st.push_back({f, uint8_t(atoi(q + 1))});
      }
    }
    fclose(g);
    int last = pw.empty() ? 0 : pw.back().f;
    printf("== stream: %zu PE writes over %d frames, %zu steering inputs (%s)\n", pw.size(), last, st.size(), lp);
    // passes: steering = MAME's / a sweep / random; OSD: each of the four, then en low
    struct Pass { const char* name; int steer_mode; bool en, on, inv; };
    const Pass passes[] = {
      {"MAME steering, On Normal",  0, true, true, false},
      {"MAME steering, On Invert",  0, true, true, true},
      {"MAME steering, Off",        0, true, false, false},
      {"sweep steering, On Normal", 1, true, true, false},
      {"sweep steering, On Invert", 1, true, true, true},
      {"random steering + OSD",     2, true, true, false},
      {"en low (not Daytona)",      2, false, true, false},
    };
    for (auto& P : passes) {
      long c0 = checks, f0 = fails, a0 = n_active, fo0 = n_force, u0 = n_unc;
      reset(); en = P.en; on = P.on; inv = P.inv; steer = 0x80;
      std::vector<uint8_t> tl; if (&P == &passes[0]) ref.taken_log = &tl;
      size_t pi = 0, si = 0; int sweep = 0;
      for (int f = 0; f <= last + 4; f++) {
        std::vector<Ev> ev;
        while (pi < pw.size() && pw[pi].f == f) { ev.push_back({16 + int(rng() % 160) + int(ev.size()) * 8, 0, pw[pi].v}); pi++; }
        if (P.steer_mode == 0) { while (si < st.size() && st[si].f == f) { ev.push_back({200, 1, st[si].v}); si++; } }
        else if (P.steer_mode == 1) { ev.push_back({200, 1, uint8_t(sweep)}); sweep = (sweep + 1) & 0xff; }
        else {
          ev.push_back({180 + int(rng() % 20), 1, uint8_t(rng())});
          if (P.en && rng() % 97 == 0) ev.push_back({230, 2, uint8_t(rng() & 3)});
        }
        run_frame(ev);
      }
      printf("  %-28s %8ld checks, %ld fail, active %ld, force %ld, uncentre %ld\n", P.name, checks - c0,
             fails - f0, n_active - a0, n_force - fo0, n_unc - u0);
      if (&P == &passes[0]) {
        // what the board took, in order, against what port E carried
        std::vector<uint8_t> pec;
        for (auto& w : pw) if (pec.empty() || pec.back() != w.v) pec.push_back(w.v);
        printf("    port E changed %zu times; the board took %zu changes:", pec.size(), tl.size());
        for (size_t i = 0; i < tl.size() && i < 24; i++) printf(" %02X", tl[i]);
        printf("%s\n", tl.size() > 24 ? " ..." : "");
        ref.taken_log = nullptr;
      }
    }
    en = true; on = true; inv = false;
  } else {
    printf("== stream: M2_DRVLOG not set, the game's stream is SKIPPED (synthetic tests only)\n");
  }

  // ------------------------------------------------ 2. transients
  {
    long c0 = checks, f0 = fails;
    reset(); en = on = true; inv = false; steer = 0xC0;
    // settle on 0x07 (motor on) then 0x3B
    for (uint8_t v : {uint8_t(0x07), uint8_t(0x3B)}) { run_frame({{20, 0, v}}); run_frame({}); run_frame({}); }
    uint64_t base = d->ffb; long held = 0;
    // a write every ~0.4 frame: no byte covers two vblanks unless it is the same byte
    for (int f = 0; f < 4000; f++) {
      uint8_t a = uint8_t(rng()), b = uint8_t(rng());
      if (a == b) b ^= 1;
      // a written mid-frame, b before the next vblank, then 0x3B back right after it:
      // a and b each see at most one vblank
      run_frame({{40, 0, a}, {150, 0, b}});
      run_frame({{8, 0, 0x3B}});   // 0x3B again: held since the frame, a sample of b in between
      held++;
      checks++;
      if (d->ffb != base) { if (fails++ < 25) printf("FAIL transient %02x %02x taken: %014llx\n", a, b, (unsigned long long)d->ffb); }
      run_frame({});
    }
    // bytes held exactly two frames are always taken
    long two = 0;
    for (int k = 0; k < 2000; k++) {
      uint8_t v = uint8_t(rng());
      rt::DriveBoard want = ref.b;   // the board's state with v applied: v must be taken
      want.command(v);
      // v over exactly two vblanks, then something else (over one vblank)
      run_frame({{30 + int(rng() % 100), 0, v}}); run_frame({}); run_frame({{30, 0, uint8_t(rng())}});
      checks++; two++;
      if (!(ref.started && want.motor_on == ref.b.motor_on && want.effect == ref.b.effect &&
            want.strength == ref.b.strength && want.direction == ref.b.direction))
        { if (fails++ < 25) printf("FAIL two-frame byte %02x not taken\n", v); }
    }
    // random hold times 0.1 - 3 frames against the reference
    for (int k = 0; k < 20000; k++) {
      std::vector<Ev> ev;
      int nw = rng() % 4;
      for (int i = 0; i < nw; i++) ev.push_back({10 + int(rng() % 200), 0, uint8_t(rng() % 3 == 0 ? (0x30 | (rng() & 0x3f)) : rng())});
      if (rng() % 3 == 0) ev.push_back({220, 1, uint8_t(rng())});
      run_frame(ev);
    }
    printf("== transients: %ld checks, %ld fail (%ld sub-frame pairs ignored, %ld two-frame bytes taken)\n",
           checks - c0, fails - f0, held, two);
  }

  // ------------------------------------------------ 3. reset
  {
    long c0 = checks, f0 = fails;
    for (int k = 0; k < 512; k++) {
      reset(); en = on = true; inv = k & 1;
      uint8_t latch = uint8_t(k >> 1);   // whatever the latch holds out of reset
      pe = latch;
      for (int f = 0; f < 8; f++) run_frame({});   // no write: never taken
      checks++;
      if (d->ffb != 0) { if (fails++ < 25) printf("FAIL reset value %02x taken: %014llx\n", latch, (unsigned long long)d->ffb); }
      run_frame({{50, 0, latch}}); run_frame({}); run_frame({});   // written: taken
      checks++;
      if ((d->ffb >> 48) != 3) { if (fails++ < 25) printf("FAIL first write %02x not ACTIVE: %014llx\n", latch, (unsigned long long)d->ffb); }
      // a reset mid-stream drops ACTIVE
      d->rst_n = 0; tick(); d->rst_n = 1; tick(); ref = Ref();
      run_frame({}); run_frame({});
      checks++;
      if (d->ffb != 0) { if (fails++ < 25) printf("FAIL ACTIVE after reset: %014llx\n", (unsigned long long)d->ffb); }
    }
    printf("== reset: %ld checks, %ld fail\n", checks - c0, fails - f0);
  }

  // ------------------------------------------------ 4. en low
  {
    long c0 = checks, f0 = fails, nz = 0;
    reset(); en = false; on = true; inv = false;
    for (int f = 0; f < 20000; f++) {
      std::vector<Ev> ev;
      ev.push_back({20 + int(rng() % 100), 0, uint8_t(rng() % 2 ? 0x07 : rng())});
      ev.push_back({200, 1, uint8_t(rng())});
      if (f % 50 == 0) ev.push_back({230, 2, uint8_t(rng() & 3)});
      run_frame(ev);
      if (d->ffb) nz++;
    }
    checks++;
    if (nz) { fails++; printf("FAIL en low: %ld frames with a word\n", nz); }
    printf("== en low: %ld checks, %ld fail (never ACTIVE)\n", checks - c0, fails - f0);
    en = true;
  }

  // ------------------------------------------------ 5. direction, every byte
  {
    long c0 = checks, f0 = fails;
    struct D { uint8_t cmd, steer; bool inv; int want; };
    // the stated directions, independent of the reference: positive = right
    const D dirs[] = {
      {0x57, 0x80, false, -32767}, {0x57, 0x80, true, 32767},
      {0x67, 0x80, false, 32767},  {0x67, 0x80, true, -32767},
      {0x50, 0x80, false, -17969}, {0x60, 0x20, true, -17969},
      {0x47, 0xE0, false, 32767},  {0x47, 0xE0, true, -32767},
      {0x47, 0x20, false, -32767}, {0x47, 0x20, true, 32767},
      {0x47, 0x80, false, 0}, {0x47, 0x82, false, 0}, {0x47, 0x7E, false, 0},
      {0x47, 0x83, false, 32767}, {0x47, 0x7D, false, -32767},
      {0x40, 0x83, true, -17969},
    };
    for (auto& t : dirs) {
      reset(); en = on = true; inv = t.inv; steer = t.steer;
      for (uint8_t v : {uint8_t(0x07), t.cmd}) { run_frame({{20, 0, v}}); run_frame({}); run_frame({}); }
      checks++;
      int16_t c = int16_t(d->ffb >> 32);
      if (c != t.want) { if (fails++ < 25) printf("FAIL direction %02x steer %02x inv %d: %d want %d\n", t.cmd, t.steer, t.inv, c, t.want); }
    }
    // every byte, motor on and off, every steering value class, both directions
    for (int motor = 0; motor < 2; motor++)
      for (int cmd = 0; cmd < 256; cmd++)
        for (uint8_t s : {uint8_t(0x20), uint8_t(0x7D), uint8_t(0x7E), uint8_t(0x80), uint8_t(0x82), uint8_t(0x83), uint8_t(0xE0)})
          for (int iv = 0; iv < 2; iv++) {
            reset(); en = on = true; inv = iv; steer = s;
            run_frame({{20, 0, uint8_t(motor ? 0x07 : 0x01)}}); run_frame({}); run_frame({});
            run_frame({{20, 0, uint8_t(cmd)}}); run_frame({}); run_frame({});
          }
    printf("== direction and every byte: %ld checks, %ld fail\n", checks - c0, fails - f0);
  }

  printf("TOTAL %ld checks, %ld fail; active words %ld (force %ld, uncentre %ld, spring %ld, idle spring %ld, friction %ld)\n",
         checks, fails, n_active, n_force, n_unc, n_spring, n_idle, n_fric);
  printf(fails ? "FAIL\n" : "PASS\n");
  delete d;
  return fails ? 1 : 0;
}
