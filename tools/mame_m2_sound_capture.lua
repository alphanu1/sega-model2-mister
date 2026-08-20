-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- Capture the sound board's register window ONCE PER FRAME, whole, as binary.
--
-- tools/mame_m2_dpram_watch.lua reports what CHANGED, which answered "when and
-- how often" (study R37) and is the wrong shape for replay: a change log has to
-- be reconstructed into state before anything can read it. This writes the
-- state directly -- frame N is at offset N * LEN -- so the harness can index it
-- with its own V-blank count and answer any address in the window.
--
-- WHY PER FRAME IS THE RIGHT AXIS, given the two machines run at different
-- speeds. Our i960 retires ~110,000 instructions per frame and MAME's ~307,000,
-- so an instruction count is not comparable between them. A frame is: both
-- reach 178 V-blanks over the same 3.1 seconds of emulated time, because both
-- are driven by the same 57.5 Hz refresh. The handshake R37 traced moves on
-- frames -- 1, 7, 8, 10, 21, 175 -- not on instruction counts, so replaying it
-- against a V-blank counter reproduces the protocol's actual time base.
--
-- It does NOT make the two instruction streams line up inside a poll; nothing
-- can, since the loops spin at different rates. tools/i960-resync-diff.py is
-- what handles that, and this capture is only useful together with it.
--
-- Read taps do not fire on this region -- it is a device handler, not RAM --
-- so it is walked in byte steps, which is also the only way to see both halves
-- of an 8-bit-wide DPRAM sitting at bytes 0 and 2 of each dword.
--
-- The notifier is kept in a GLOBAL or it is collected and silently stops.

local out    = os.getenv("M2_OUT")    or "/tmp/m2-sound"
local frames = tonumber(os.getenv("M2_FRAMES") or "400")
local base   = tonumber(os.getenv("M2_SND_BASE") or "0x01c00000")
local len    = tonumber(os.getenv("M2_SND_LEN")  or "0x1000")

os.execute("mkdir -p " .. out)
local f  = assert(io.open(out .. "/sound_frames.bin", "wb"))
local sp = manager.machine.devices[":maincpu"].spaces["program"]
local n  = 0

M2_SOUND_CAP = emu.add_machine_frame_notifier(function()
  n = n + 1
  if n > frames then return end
  local t = {}
  for i = 0, len - 1 do t[i + 1] = string.char(sp:read_u8(base + i)) end
  f:write(table.concat(t))
  if n == frames then
    f:flush(); f:close()
    print(string.format("[sound-cap] wrote %d frames x %d bytes", frames, len))
  end
end)

print(string.format("[sound-cap] %d frames over %08X +%X -> %s/sound_frames.bin",
                    frames, base, len, out))
