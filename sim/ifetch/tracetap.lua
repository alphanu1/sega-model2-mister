-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
-- R817: see sim/mem/tb_m2_ifetch_replay.cpp. Usage:
--   M2_TRACEAT=1200,2800 M2_W=6 M2_PFX=a M2_TRDIR=<dir outside the tree>/ [M2_RACE=1] \
--   tools/m2b-mame.sh daytona -debug -debugscript <(echo go) -autoboot_script sim/ifetch/tracetap.lua
-- Writes <pfx><frame>.tr (uncollapsed trace) and .da (every access, tagged pip/ip).
-- Both are ROM-derived: keep them outside the repository.
-- trace W frames at each window AND log every data access the i960 makes
-- (read/write taps), tagged with the instruction's address (pip), in the same
-- run so the two line up. Optional race driving (M2_RACE=1).
local cpu = manager.machine.devices[":maincpu"]
local space = cpu.spaces["program"]
local P = manager.machine.ioport.ports
local race = os.getenv("M2_RACE") == "1"
local coin = P[":IN0"].fields["Coin 1"]; local start = P[":IN0"].fields["1 Player Start"]
local accel = P[":ACCEL"].fields["P1 Pedal 1"]
local wins = {}; for s in string.gmatch(os.getenv("M2_TRACEAT") or "", "%d+") do wins[#wins+1] = tonumber(s) end
local W = tonumber(os.getenv("M2_W") or "6")
local dir = os.getenv("M2_TRDIR") or "/tmp/"
local pfx = os.getenv("M2_PFX") or "t"
local n = 0
local df = nil
local function rec(rw, off, mask)
  if df then
    local st = cpu.state
    df:write(string.format("%x %x %s %x %x\n", st["pip"].value, st["ip"].value, rw, off, mask))
  end
end
M2_TAPS = {}
M2_SUB = emu.add_machine_frame_notifier(function()
  n = n + 1
  if race then
    coin:set_value((n >= 600 and n < 610) and 1 or 0)
    local st = (n >= 680 and n < 690) or (n >= 900 and n % 120 < 6 and n < 1800)
    start:set_value(st and 1 or 0)
    if n >= 1000 then accel:set_value(224) end
  end
  local d = manager.machine.debugger
  for _, s in ipairs(wins) do
    if n == s then
      d:command("trace " .. dir .. pfx .. s .. ".tr,:maincpu,noloop")
      df = io.open(dir .. pfx .. s .. ".da", "w")
      M2_TAPS[1] = space:install_read_tap(0x00000000, 0x1fffffff, "m2r", function(off, data, mask) rec("r", off, mask) end)
      M2_TAPS[2] = space:install_write_tap(0x00000000, 0x1fffffff, "m2w", function(off, data, mask) rec("w", off, mask) end)
    elseif n > s and n < s + W then
      d:command("tracelog M2FRAME\n"); if df then df:write("M2FRAME\n") end
    elseif n == s + W then
      d:command("trace off")
      for _, t in ipairs(M2_TAPS) do t:remove() end
      M2_TAPS = {}
      if df then df:close(); df = nil end
      io.stderr:write("TRACED " .. s .. "\n")
    end
  end
  if n == wins[#wins] + W + 1 then manager.machine:exit() end
end)
