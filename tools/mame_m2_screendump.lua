-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- Dump MAME's rendered SCREEN at a chosen frame, as raw pixels, so our
-- renderer can be compared against it pixel by pixel rather than by eye.
--
-- tools/mame_m2_tiledump.lua dumps the tilemap INPUTS at the same frame. The
-- two together are the whole 2D test: same inputs in, same pixels out. Dumping
-- only the inputs proves the data is right and says nothing about the renderer;
-- dumping only the screen cannot tell a renderer bug from a data difference.
--
-- screen:pixels() returns the frame as packed 32-bit values in the screen's own
-- format. Written raw and decoded on the comparison side, because a PNG round
-- trip through MAME's snapshot path rescales and would silently make a
-- pixel-exact comparison approximate.
--
-- The subscription is kept in a GLOBAL: assigned to a local it is collected and
-- the callback silently stops (Model 1 docs/differential-testing.md).

local at  = tonumber(os.getenv("M2_FRAME") or "2300")
local out = os.getenv("M2_OUT") or "/tmp/m2tiles"
local n   = 0

M2_SCREENDUMP_SUB = emu.add_machine_frame_notifier(function()
  n = n + 1
  if n ~= at then return end

  local scr = manager.machine.screens[":screen"]
  local px  = scr:pixels()
  local f = io.open(out .. "/screen.raw", "wb")
  f:write(px)
  f:close()

  local g = io.open(out .. "/screen.txt", "w")
  g:write(string.format("%d %d %d\n", scr.width, scr.height, #px))
  g:close()

  print(string.format("[screendump] frame %d: %dx%d, %d bytes", n, scr.width, scr.height, #px))
  manager.machine:exit()
end)
