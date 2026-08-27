-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- Watch the palette entries that carry the test menu's WHITE, frame by frame.
--
-- WHY THIS IS A POLL AND NOT A WRITE TAP. tools/mame_m2_charwrites.lua taps
-- char RAM with install_write_tap because char RAM is mapped .ram(). The
-- palette is not: model2.cpp:1059 maps 0x01800000-0x01803fff as
-- .rw(palette_r, palette_w), a device handler, and study R37 records that taps
-- do not fire on those. Reading THROUGH the handler works, so this samples
-- instead of tapping.
--
-- WHAT IT IS FOR. Our CPU builds a palette whose entries at 1 + 16k are 0000
-- where MAME's hold colours -- entry 1 is white, and its absence is why
-- Daytona's test menu renders its green values with no white labels (study
-- R54). A snapshot cannot say whether MAME never writes the zero or writes it
-- and then writes the colour back; a per-frame timeline can, and that
-- distinguishes "we execute a store MAME does not" from "we miss a store MAME
-- makes".
--
-- Sampling per frame rather than per write cannot see a value that is written
-- and overwritten within one frame. That is a real limit and it is why this
-- reports the whole first row of tracked entries rather than entry 1 alone: if
-- the neighbours move in step, the loop ran; if only entry 1 differs, it did
-- not.

local out    = os.getenv("M2_OUT")    or "/tmp/m2-palwatch"
local frames = tonumber(os.getenv("M2_FRAMES") or "600")

os.execute("mkdir -p " .. out)
local f = assert(io.open(out .. "/palwatch.log", "w"))
local sp = manager.machine.devices[":maincpu"].spaces["program"]
local frame = 0

-- The entries our CPU leaves at zero: 1 + 16k. Track the first few, plus 0 and
-- 41, which both machines agree on -- a control that must NOT move.
local WATCH = { 0, 1, 17, 33, 41, 49, 65 }

f:write("# frame")
for _, e in ipairs(WATCH) do f:write(string.format("  e%d", e)) end
f:write("\n")

-- Kept in a global, or it is collected and silently stops -- which looks
-- exactly like a game that writes nothing (the lesson charwrites records).
M2_PALFRAME = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame <= frames then
    f:write(string.format("%6d", frame))
    for _, e in ipairs(WATCH) do
      f:write(string.format("  %04x", sp:read_u16(0x01800000 + e * 2)))
    end
    f:write("\n")
    if frame == frames then
      f:flush(); f:close()
      print(string.format("[palwatch] %d frames -> %s/palwatch.log", frames, out))
      manager.machine:exit()
    end
  end
end)
