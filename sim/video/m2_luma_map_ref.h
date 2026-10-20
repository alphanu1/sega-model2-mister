// SPDX-License-Identifier: GPL-3.0-or-later
// Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
//
// R900: rtl/video/m2_luma_map.sv as a reference -- a luma-RAM row's
// {captured, slot} for a game ID (Model2.sv's: a2_big for 0x13-0x16, 0x18,
// 0x1A; Zero Gunner 0x12), written from MAME's own rows, not from the RTL.
#pragma once
static inline bool m2_luma_big(int game) {
  if (((game >> 4) & 7) != 1) return false;
  const int n = game & 15;
  return n == 3 || n == 4 || n == 5 || n == 6 || n == 8 || n == 10;
}
static inline int m2_luma_map_ref(int game, int r) {
  // the large layout's games: the first row of each slot's range, s[0] < ... < s[7];
  // slot k takes rows s[k] .. s[k+1] - 1 (slot 0 everything below s[1]) and is
  // filled from row s[k]
  struct T { int id; int s[8]; };
  static const T tab[] = {
    {0x13, {47, 51, 52, 54, 76, 92, 96, 100}},       // Hanguk Pro Yagu 98
    {0x14, {6, 7, 76, 96, 100, 132, 138, 142}},      // Dynamite Cop
    {0x15, {0, 249, 250, 251, 252, 253, 254, 255}},  // Pilot Kids
    {0x16, {6, 72, 89, 92, 98, 100, 254, 255}},      // Dead or Alive
    {0x18, {6, 7, 18, 22, 76, 94, 96, 107}},         // Sky Target
    {0x1A, {100, 115, 125, 126, 131, 133, 137, 151}},  // Motor Raid
  };
  if (m2_luma_big(game))
    for (const T &e : tab) if ((e.id & 15) == (game & 15)) {
      int k = 0; for (int i = 1; i < 8; i++) if (r >= e.s[i]) k = i;
      return ((r == e.s[k]) ? 8 : 0) | k;
    }
  if (game == 0x12)   // R867: Zero Gunner, rows 0-5, 9, 100
    return (r <= 5) ? (8 | (r & 7)) : (r == 9) ? 14 : (r == 100) ? 15 : (r & 7);
  // R867: VF2, Virtua Cop 2, Sega Rally (and every other ID): rows 0-3, 16-19
  return ((((r >> 5) & 7) == 0 && ((r >> 2) & 3) == 0) ? 8 : 0) | (((r >> 4) & 1) << 2) | (r & 3);
}
