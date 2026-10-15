-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- R835: WHAT A GAME DOES WITH THE MODEL 2 TIMERS (0x00f00000-0x00f0000f,
-- four 25 MHz down-counters, IRQ bits 2-5) AND THE INTERRUPT ENABLE.
-- Daytona never touches them; Desert Tank polls one. Writes: time, IP,
-- offset, value. Reads: counted per (IP, offset), with the first and last
-- value seen. intena / intreq-ack writes: values with first time and count.
-- IRQ entries per line are counted off intreq reads' values.
--
--   M2_MAME_OUT=<dir> TM_OUT=<dir> TM_TEND=150 TM_COIN=60 \
--     tools/m2b-mame.sh desert -autoboot_script sim/io/mame_m2_timers.lua
-- Output is ROM-derived (game addresses and values); keep it out of git.

local out   = os.getenv("TM_OUT") or "."
local T_END = tonumber(os.getenv("TM_TEND") or "150")
local T_COIN = tonumber(os.getenv("TM_COIN") or "60")
local m     = manager.machine
local cpu   = m.devices[":maincpu"]
local sp    = cpu.spaces["program"]
local ports = m.ioport.ports
local function IP() return cpu.state["ip"] and cpu.state["ip"].value or 0 end
local wf = assert(io.open(out .. "/timer_writes.txt", "w"))
TM_NW = 0
TM_R = {}
TM_EN = {}
TM_TW = sp:install_write_tap(0x00f00000, 0x00f0000f, "tmw", function(o, d, mk)
  TM_NW = TM_NW + 1
  if TM_NW <= 400 or TM_NW % 1000 == 0 then
    wf:write(string.format("%.6f ip %08x off %x data %08x mask %08x\n", emu.time(), IP(), o - 0x00f00000, d, mk))
  end
end)
TM_TR = sp:install_read_tap(0x00f00000, 0x00f0000f, "tmr", function(o, d, mk)
  local k = string.format("ip %08x off %x", IP(), o - 0x00f00000)
  local e = TM_R[k]
  if not e then e = { n = 0, first = d, last = d, min = d, max = d }; TM_R[k] = e end
  e.n = e.n + 1; e.last = d
  if d < e.min then e.min = d end
  if d > e.max then e.max = d end
end)
TM_IE = sp:install_write_tap(0x00e80000, 0x00e80007, "tmie", function(o, d, mk)
  local k = string.format("%s %08x", (o >= 0x00e80004) and "intena" or "intack", d)
  local e = TM_EN[k]
  if not e then e = { n = 0, t = emu.time() }; TM_EN[k] = e end
  e.n = e.n + 1
end)

local function set(p, n, v) local x = ports[p] and ports[p].fields[n]; if x then x:set_value(v) end end
TM_F = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  if t >= T_COIN and t < T_COIN + 0.2 then set(":IN0", "Coin 1", 1) else set(":IN0", "Coin 1", 0) end
  local s = (t >= T_COIN + 2) and ((t - T_COIN) % 2 < 0.2)
  set(":IN0", "1 Player Start", s and t < T_COIN + 30 and 1 or 0)
  if t >= T_COIN + 4 then set(":ACCEL", "P1 Pedal 1", 255) end
  if t >= T_END then
    local f = assert(io.open(out .. "/timers.txt", "w"))
    f:write(string.format("system %s time %.1f s, timer writes %d\n", m.system.name, t, TM_NW))
    f:write("reads by ip/offset: count first last min max\n")
    local ks = {}
    for k in pairs(TM_R) do ks[#ks + 1] = k end
    table.sort(ks)
    for _, k in ipairs(ks) do
      local e = TM_R[k]
      f:write(string.format("  %s  %d  %08x %08x %08x %08x\n", k, e.n, e.first, e.last, e.min, e.max))
    end
    f:write("intena / intack writes: value count first-time\n")
    ks = {}
    for k in pairs(TM_EN) do ks[#ks + 1] = k end
    table.sort(ks)
    for _, k in ipairs(ks) do f:write(string.format("  %s %d %.4f\n", k, TM_EN[k].n, TM_EN[k].t)) end
    f:close(); wf:close()
    m:exit()
  end
end)
