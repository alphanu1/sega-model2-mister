// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
// R924: MAME's u2f / f2u (corefloat.h) for the verbatim mb86235ops.cpp.
#pragma once
#include <cstring>
#include <cstdint>
inline float u2f(uint32_t v) { float f; std::memcpy(&f, &v, 4); return f; }
inline uint32_t f2u(float f) { uint32_t v; std::memcpy(&v, &f, 4); return v; }
