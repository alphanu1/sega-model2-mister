// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// m2_geo_xform against the reference arithmetic.
//
// The oracle is model2_v.cpp's own code, transcribed:
//
//   tx = (x*m[0]) + (y*m[3]) + (z*m[6]) + m[9]      transform_point
//   ty = (x*m[1]) + (y*m[4]) + (z*m[7]) + m[10]
//   tz = (x*m[2]) + (y*m[5]) + (z*m[8]) + m[11]
//   x *= focus.x;  y *= focus.y                     apply_focus
//
// and transform_vector is the same three lines without the translate.
//
// BIT-EXACT, NOT WITHIN-A-TOLERANCE. Float add is not associative, so the
// order of accumulation is part of the specification, and the rasterizer takes
// these values shifted right by 8 -- a one-bit difference is a vertex in the
// wrong place. This block has no framebuffer oracle of its own (study 2.1), so
// the arithmetic is the only thing that CAN be checked exactly, and it is.
//
// The C is compiled with the same float semantics the hardware implements:
// single precision throughout, no double-rounding. `volatile float` at each
// step stops the compiler contracting a multiply and an add into an FMA, which
// would be more accurate than the hardware and would fail every vector.

#include "Vm2_geo_xform.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <random>

static Vm2_geo_xform* dut;

static void tick() { dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval(); }

static uint32_t f2u(float f) { uint32_t u; std::memcpy(&u, &f, 4); return u; }
static float    u2f(uint32_t u) { float f; std::memcpy(&f, &u, 4); return f; }

// The reference, step for step. volatile forces each rounding.
static void ref_xform(float x, float y, float z, const float m[12],
                      float fx, float fy, bool vec_only,
                      float &ox, float &oy, float &oz)
{
  volatile float tx = x * m[0]; tx = tx + y * m[3]; tx = tx + z * m[6];
  volatile float ty = x * m[1]; ty = ty + y * m[4]; ty = ty + z * m[7];
  volatile float tz = x * m[2]; tz = tz + y * m[5]; tz = tz + z * m[8];
  if (!vec_only) { tx = tx + m[9]; ty = ty + m[10]; tz = tz + m[11]; }
  ox = tx; oy = ty; oz = tz;
  if (!vec_only) { volatile float a = ox * fx, b = oy * fy; ox = a; oy = b; }
}

static long checks = 0, fails = 0;

static bool run_one(float x, float y, float z, const float m[12],
                    float fx, float fy, bool vec_only)
{
  dut->px = f2u(x); dut->py = f2u(y); dut->pz = f2u(z);
  for (int i = 0; i < 12; i++) dut->m[i] = f2u(m[i]);
  dut->fx = f2u(fx); dut->fy = f2u(fy);
  dut->vec_only = vec_only;
  dut->start = 1; tick(); dut->start = 0;

  for (int budget = 0; budget < 4000; budget++) {
    tick();
    if (dut->done) {
      float ex, ey, ez;
      ref_xform(x, y, z, m, fx, fy, vec_only, ex, ey, ez);
      checks++;
      const bool ok = dut->ox == f2u(ex) && dut->oy == f2u(ey) && dut->oz == f2u(ez);
      if (!ok && fails < 12) {
        std::printf("  FAIL %s p=(%g,%g,%g)\n", vec_only ? "vector" : "point", x, y, z);
        std::printf("       got %08x %08x %08x\n", dut->ox, dut->oy, dut->oz);
        std::printf("       exp %08x %08x %08x\n", f2u(ex), f2u(ey), f2u(ez));
      }
      if (!ok) fails++;
      return ok;
    }
  }
  std::printf("  FAIL timeout\n"); fails++; return false;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vm2_geo_xform;
  dut->rst_n = 0; dut->start = 0; dut->vec_only = 0;
  for (int i = 0; i < 8; i++) tick();
  dut->rst_n = 1; tick();

  // ---- directed: identity leaves a point alone (focus 1.0)
  {
    float m[12] = {1,0,0, 0,1,0, 0,0,1, 0,0,0};
    printf("test: identity matrix, unit focus\n");
    run_one(1.0f, 2.0f, 3.0f, m, 1.0f, 1.0f, false);
    run_one(-7.5f, 0.25f, 1e6f, m, 1.0f, 1.0f, false);
  }
  // ---- directed: the translate is applied, and NOT applied to a vector
  {
    float m[12] = {1,0,0, 0,1,0, 0,0,1, 10,20,30};
    printf("test: translate applies to a point and not to a vector\n");
    run_one(1,1,1, m, 1.0f, 1.0f, false);
    run_one(1,1,1, m, 1.0f, 1.0f, true);
  }
  // ---- directed: focus scales x and y only
  {
    float m[12] = {1,0,0, 0,1,0, 0,0,1, 0,0,0};
    printf("test: focus scales x and y, never z\n");
    run_one(3,5,7, m, 2.0f, 4.0f, false);
  }

  // ---- random, both forms
  printf("test: random points and matrices against the reference\n");
  std::mt19937 rnd(20260904);
  auto rf = [&](){
    // A spread that covers ordinary geometry and the awkward exponents, without
    // manufacturing NaN/inf -- those are a separate question and the reference
    // does not generate them here either.
    static const float scale[] = {1e-6f, 1e-3f, 1.0f, 1e3f, 1e6f};
    float s = scale[rnd() % 5];
    return (float(int32_t(rnd())) / 2147483648.0f) * s;
  };
  const int N = argc > 1 ? atoi(argv[1]) : 20000;
  for (int i = 0; i < N; i++) {
    float m[12]; for (int k = 0; k < 12; k++) m[k] = rf();
    run_one(rf(), rf(), rf(), m, rf(), rf(), (rnd() & 3) == 0);
  }

  printf("m2_geo_xform: checks=%ld fails=%ld\n", checks, fails);
  delete dut;
  return fails ? 1 : 0;
}
