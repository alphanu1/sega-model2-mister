-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- Dump the I/O board's 128-byte identity block, MORE THAN ONCE, and say whether
-- it settled.
--
-- The i960 block-reads DPRAM 0x100-0x17f once, immediately after its first
-- handshake is answered, and will not go on to poll its controls until it has.
-- Nothing else writes that window -- the CPU is still spinning on the flag --
-- so the board supplies it, and a core that answers the handshake but leaves
-- the window empty gets exactly as far as one that never answered it.
--
-- SAMPLED AT SEVERAL FRAMES ON PURPOSE. The Model 1 core took this block from a
-- single snapshot just after the handshake, while the Z80 was still filling the
-- window, and got six bytes wrong -- one of which, offset 0x0b, gates the
-- coprocessor path (their `6e5aed4`). That reading then became the RTL table,
-- the testbench's expected values and the documentation, which looks like three
-- independent artefacts and is one measurement. A single snapshot of a window
-- another processor is filling is not a measurement.
--
-- ADDRESSING. The DPRAM is 2K x 8 behind umask32(0x00ff00ff), so DPRAM byte N
-- lives at i960 address 0x01c00000 + (N>>1)*4 + (N&1)*2 -- bytes 0 and 2 of each
-- dword. DPRAM 0x20 is therefore 0x01c00040, which is the byte the boot polls,
-- and DPRAM 0x21 is 0x01c00042, the status byte beside it. The block at DPRAM
-- 0x100 begins at 0x01c00200.

local out    = os.getenv("M2_OUT") or "/tmp/m2-idblock"
-- WATCH IT CHANGE, do not sample it at chosen frames.
--
-- Fixed frames answered "has it settled" -- it had, by frame 10 -- and that is
-- the wrong question. The window is BIDIRECTIONAL: the board pushes a block in
-- and the CPU writes a block out, and a sample taken after the CPU has written
-- returns the CPU's block. The first reading here was byte-identical to backup
-- SRAM 0x1d00000, which is what that looks like.
--
-- So every frame is sampled and only CHANGES are recorded, with the frame they
-- happened on. That distinguishes what the board supplies from what the CPU
-- later puts there, which a settled snapshot cannot.
local frames = tonumber(os.getenv("M2_FRAMES") or "400")

os.execute("mkdir -p " .. out)
local sp = manager.machine.devices[":maincpu"].spaces["program"]
local n, taken, first, stable = 0, {}, nil, true

local function dpram(off)                     -- DPRAM byte -> i960 address
  return 0x01c00000 + (off >> 1) * 4 + (off & 1) * 2
end

local function dump()
  local f = assert(io.open(out .. "/idblock.txt", "w"))
  f:write(string.format("%d distinct states of DPRAM 0x100-0x17f\n\n", #taken))
  for _, s in ipairs(taken) do
    f:write(string.format("frame %d   flag=%02x status=%02x\n",
                          s.frame, s.flag or 0, s.stat or 0))
    for r = 0, 7 do
      local line = string.format("  %02x:", r * 16)
      for c = 0, 15 do line = line .. string.format(" %02x", s.bytes[r * 16 + c]) end
      f:write(line .. "\n")
    end
  end
  f:close()
  print("[idblock] " .. #taken .. " samples -> " .. out .. "/idblock.txt")
end


M2_IDBLOCK = emu.add_machine_frame_notifier(function()
  n = n + 1
  if n > frames then return end
  local b = {}
  for i = 0, 127 do b[i] = sp:read_u8(dpram(0x100 + i)) end
  local changed = (first == nil)
  if not changed then
    for i = 0, 127 do if b[i] ~= taken[#taken].bytes[i] then changed = true end end
  end
  if changed then
    taken[#taken + 1] = { frame = n, bytes = b,
                          flag = sp:read_u8(dpram(0x20)),
                          stat = sp:read_u8(dpram(0x21)) }
    first = 1
  end
  if n >= frames then dump() end
end)


print("[idblock] sampling DPRAM 0x100-0x17f")
