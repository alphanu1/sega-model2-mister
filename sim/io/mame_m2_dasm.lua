-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- DISASSEMBLE A RANGE OF THE i960 PROGRAM WITH MAME'S OWN DISASSEMBLER (R844)
-- and, optionally, log the main CPU's IP each frame for a while. Run with
-- -debug and a debugscript that says "go".
--
--   DA_OUT=<file> DA_FROM=<hex> DA_LEN=<hex> [DA_IPLOG=<file> DA_TEND=<s>]
local m = manager.machine
local out = assert(os.getenv("DA_OUT"))
local from = os.getenv("DA_FROM") or "0"
local len = os.getenv("DA_LEN") or "100"
local iplog = os.getenv("DA_IPLOG") and assert(io.open(os.getenv("DA_IPLOG"), "w"))
local T_END = tonumber(os.getenv("DA_TEND") or "0")
local cpu = m.devices[":maincpu"]
local scr = m.screens[":screen"]
local done = false
DA_F = emu.add_machine_frame_notifier(function()
  if not done then
    m.debugger:command(string.format("dasm %s,%s,%s,1,:maincpu", out, from, len))
    done = true
  end
  local t = emu.time()
  if iplog then iplog:write(string.format("%.3f %d %08x\n", t, scr:frame_number(), cpu.state["ip"].value)) end
  if t >= T_END then
    if iplog then iplog:close() end
    m:exit()
  end
end)
