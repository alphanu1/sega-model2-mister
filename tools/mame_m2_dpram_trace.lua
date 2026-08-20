-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- Trace every i960 access to the sound board's dual-port RAM.
--
-- The core currently answers that region with a CONSTANT -- two bytes that get
-- the boot past its first poll. That was arrived at by sweeping values until
-- one worked, which establishes that a value works and NOTHING about the
-- protocol: how often the handshake happens, what the i960 writes, what the
-- sound board writes back, or whether the answer has to change over time.
--
-- This logs the traffic instead of guessing at it:
--
--   R addr  value  pc      the i960 reading the board's side
--   W addr  value  pc      the i960 writing a command
--
-- The DPRAM is EIGHT BITS WIDE at bytes 0 and 2 of each dword --
-- model2.cpp maps it .umask32(0x00ff00ff) -- so the byte address matters and
-- two different byte addresses live in one 32-bit word. Getting that wrong is
-- what made the core's stub match only half the poll.
--
-- Taps are kept in GLOBALS. Assigned to a local they are collected and the
-- callback silently stops (Model 1 docs/differential-testing.md).

local out   = os.getenv("M2_OUT") or "/tmp/m2-dpram"
local limit = tonumber(os.getenv("M2_LIMIT") or "4000")
local n     = 0

os.execute("mkdir -p " .. out)
local f = assert(io.open(out .. "/dpram.log", "w"))

local cpu = manager.machine.devices[":maincpu"]
local sp  = cpu.spaces["program"]

M2_DPRAM_R = sp:install_read_tap(0x01c00000, 0x01c00fff, "dpram_r",
  function(offset, data, mask)
    if n < limit then
      n = n + 1
      f:write(string.format("R %08X %08X mask=%08X pc=%08X\n",
                            offset, data, mask, cpu.state["PC"].value))
    end
    return data
  end)

M2_DPRAM_W = sp:install_write_tap(0x01c00000, 0x01c00fff, "dpram_w",
  function(offset, data, mask)
    if n < limit then
      n = n + 1
      f:write(string.format("W %08X %08X mask=%08X pc=%08X\n",
                            offset, data, mask, cpu.state["PC"].value))
    end
    return data
  end)

M2_DPRAM_SUB = emu.add_machine_frame_notifier(function()
  f:flush()
end)

print(string.format("[dpram] tracing 0x01c00000-0x01c00fff, limit %d", limit))
