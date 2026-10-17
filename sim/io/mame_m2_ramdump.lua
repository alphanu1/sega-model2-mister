-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- THE i960's WORK RAM (0x500000-0x5fffff) DUMPED AT GIVEN TIMES (R866): Sega
-- Rally and Zero Gunner copy their program into work RAM at boot and run it
-- there (PC 0x5cxxxx in attract), so a breakpoint on a ROM address never
-- fires for that code. A dump is scanned like a ROM (sim/io/i960_fpext_scan.py
-- --raw) and its addresses breakpointed (sim/io/mame_m2_bphits.lua); dumps
-- from different times say whether the code region stays put.
--
--   RD_OUT=<prefix> RD_TIMES=<s,s,...> [RD_COIN=<s>]   writes <prefix>_<t>.bin
--
-- The dumps are ROM-derived and stay outside the repository.
local m = manager.machine
local ports = m.ioport.ports
local sp = m.devices[":maincpu"].spaces["program"]
local OUT = assert(os.getenv("RD_OUT"))
local T_COIN = tonumber(os.getenv("RD_COIN") or "-1")
local TIMES, k = {}, 1
for v in string.gmatch(os.getenv("RD_TIMES") or "10", "[^,]+") do TIMES[#TIMES + 1] = tonumber(v) end
local function set(p, n, v) local x = ports[p] and ports[p].fields[n]; if x then x:set_value(v) end end
local function pulse(t, at, p, n, len)
  len = len or 0.2
  if t >= at and t < at + len then set(p, n, 1)
  elseif t >= at + len and t < at + 2 * len then set(p, n, 0) end
end
RD_F = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  if T_COIN >= 0 then
    pulse(t, T_COIN, ":IN0", "Coin 1")
    for j = 0, 4 do pulse(t, T_COIN + 3 + 2 * j, ":IN0", "1 Player Start") end
  end
  if k <= #TIMES and t >= TIMES[k] then
    local f = assert(io.open(string.format("%s_%d.bin", OUT, TIMES[k]), "wb"))
    local parts = {}
    for a = 0x500000, 0x5ffffc, 4 do
      parts[#parts + 1] = string.pack("<I4", sp:read_u32(a))
      if #parts == 4096 then f:write(table.concat(parts)); parts = {} end
    end
    f:write(table.concat(parts)); f:close()
    k = k + 1
    if k > #TIMES then m:exit() end
  end
end)
