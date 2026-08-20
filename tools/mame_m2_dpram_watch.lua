-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- Watch the sound board's dual-port RAM change over time.
--
-- The core answers that region with a CONSTANT, arrived at by sweeping values
-- until one worked. That establishes that a value works and nothing about the
-- PROTOCOL: how often the handshake happens, what the i960 writes, what the
-- board writes back, or whether the answer has to change.
--
-- Read taps do not fire on this region -- it is a device handler, not RAM --
-- and debugger printf does not reach stdout, so neither of those instruments
-- worked. This samples the region every frame and reports only what CHANGED,
-- which answers "when and how often" directly and costs one read per byte.
--
-- The DPRAM is EIGHT BITS WIDE at bytes 0 and 2 of each dword, so the whole
-- region is walked in byte steps and both halves are visible.
--
-- The notifier is kept in a GLOBAL or it is collected and silently stops.

local out    = os.getenv("M2_OUT") or "/tmp/m2-dpram"
local frames = tonumber(os.getenv("M2_FRAMES") or "600")
local base, len = 0x01c00000, 0x100          -- first 256 bytes: the handshake area

os.execute("mkdir -p " .. out)
local f = assert(io.open(out .. "/dpram_changes.log", "w"))
local sp = manager.machine.devices[":maincpu"].spaces["program"]
local prev, n = {}, 0

M2_DPRAM_WATCH = emu.add_machine_frame_notifier(function()
  n = n + 1
  if n > frames then return end
  for i = 0, len - 1 do
    local v = sp:read_u8(base + i)
    if prev[i] ~= v then
      if prev[i] ~= nil then
        f:write(string.format("frame %5d  %08X  %02X -> %02X\n", n, base + i, prev[i], v))
      else
        f:write(string.format("frame %5d  %08X  initial %02X\n", n, base + i, v))
      end
      prev[i] = v
    end
  end
  f:flush()
  if n == frames then
    f:write("-- end --\n"); f:flush()
    print("[dpram-watch] done")
  end
end)

print(string.format("[dpram-watch] %d frames over %08X +%X", frames, base, len))
