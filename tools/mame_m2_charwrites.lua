-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- Log every write the i960 makes into char RAM, as a STREAM.
--
-- Comparing the finished contents of char RAM against ours answers "is the
-- result the same" and nothing about how it got there. It also scores
-- misleadingly well by accident: character data is mostly repeated 0x1111
-- patterns, so a copy displaced by one word still matches ~60% of words, which
-- is close enough to the aligned score to prove nothing. That is how a
-- one-word-shift theory came to be believed on two samples.
--
-- A write stream has no such ambiguity. Same addresses in the same order, or
-- not.
--
-- char RAM is 0x01080000 +0x80000, mapped .ram() in model2.cpp, so a write tap
-- works here -- unlike the DPRAM at 0x01c00000, which is a device handler and
-- where taps do not fire (study R37).

local out    = os.getenv("M2_OUT")    or "/tmp/m2-charwr"
local frames = tonumber(os.getenv("M2_FRAMES") or "56")
local limit  = tonumber(os.getenv("M2_LIMIT")  or "200000")

os.execute("mkdir -p " .. out)
local f = assert(io.open(out .. "/charwr.log", "w"))
local sp = manager.machine.devices[":maincpu"].spaces["program"]
local n, frame = 0, 0

-- The tap is kept in a GLOBAL or it is collected and silently stops logging,
-- which looks exactly like a game that writes nothing.
M2_CHARTAP = sp:install_write_tap(0x01080000, 0x010fffff, "charwr",
  function(offset, data, mask)
    if n < limit then
      f:write(string.format("%08x %08x %08x\n", offset, data, mask))
      n = n + 1
    end
    return data
  end)

M2_CHARFRAME = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  if frame == frames then
    f:flush(); f:close()
    print(string.format("[charwr] %d writes over %d frames -> %s/charwr.log",
                        n, frames, out))
  end
end)

print("[charwr] tapping 0x01080000 +0x80000")
