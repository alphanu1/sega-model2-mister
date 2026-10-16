-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- SNAPSHOTS OF THE FIRST SECONDS OF A SET, WITH THE I/O BOARD OPTIONALLY
-- SILENCED (R839): what the game puts on the screen in its own boot, and
-- what it puts there when the I/O board never answers. Run with -debug and a
-- debugscript; SN_SUSPEND=1 suspends the I/O board's Z80 from the start
-- (the debugger's "suspend"), which is a board that never talks.
--
--   SN_EVERY=<s> SN_TEND=<s> [SN_SUSPEND=1] [SN_OUT=<file>]
local m = manager.machine
local scr = m.screens[":screen"]
local EVERY = tonumber(os.getenv("SN_EVERY") or "1")
local T_END = tonumber(os.getenv("SN_TEND") or "20")
local out = os.getenv("SN_OUT") and assert(io.open(os.getenv("SN_OUT"), "w"))
local dbg = m.debugger
if (os.getenv("SN_SUSPEND") or "0") ~= "0" then
  dbg:command("suspend :ioboard:iocpu")
end
local next_t = 0
local cpu = m.devices[":maincpu"]
SN_F = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  if t >= next_t then
    scr:snapshot(string.format("t%05.1f.png", t))
    if out then
      out:write(string.format("%.2f frame %d ip %08x\n", t, scr:frame_number(), cpu.state["ip"].value))
      out:flush()
    end
    next_t = next_t + EVERY
  end
  if t >= T_END then
    if out then out:close() end
    m:exit()
  end
end)
