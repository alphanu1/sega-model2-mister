// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R924: the few pieces of MAME's emu.h that mb86235ops.cpp (MAME 0.289,
// copied verbatim beside this file, BSD-3-Clause) uses, so it compiles
// outside MAME as the TGPx4 reference model for sim/tgpx4. See mb86235.h.
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <cstdarg>

using u8 = uint8_t; using u16 = uint16_t; using u32 = uint32_t; using u64 = uint64_t;
using s8 = int8_t;  using s16 = int16_t;  using s32 = int32_t;  using s64 = int64_t;

template <typename T> constexpr T BIT(T x, int n) { return (x >> n) & T(1); }

struct mb86235_fatal : std::runtime_error { using std::runtime_error::runtime_error; };
[[noreturn]] inline void fatalerror(const char *fmt, ...)
{
  char b[256];
  va_list ap; va_start(ap, fmt); vsnprintf(b, sizeof b, fmt, ap); va_end(ap);
  throw mb86235_fatal(b);
}
