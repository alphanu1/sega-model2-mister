-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- VIRTUA COP: THE GAME'S OWN AIM MARKS (R846). Drives the test menu (TEST
-- MODE -> GUN SETTING -> GUN MARK CHECK) and forces the gun coordinates the
-- I/O board reads at 0x8100, so the snapshots show where the game itself puts
-- each player's mark for a coordinate; sim/io/vcop_marks.py measures them.
-- Run: mame vcopa -autoboot_script <this> -snapview native -snapsize 496x384
--      -nosnapbilinear, with TS_SEQ / TS_GUNAT as documented in vcop_marks.py.
--
-- drive Virtua Cop's test menu: TS_SEQ="t:field[,t:field...]" presses (0.2 s each);
-- gun coordinates forced through a read tap on the I/O board's 0x8100 block:
-- TS_GUN="p1x,p1y,p2x,p2y,off" (hex). Snapshots every TS_EVERY s from TS_FROM.
local m = manager.machine
local function fld(port, name)
  local p = m.ioport.ports[port]
  for n, f in pairs(p.fields) do if n == name then return f end end
  error("no field " .. port .. " " .. name)
end
local seq = {}
for t, pn in string.gmatch(os.getenv("TS_SEQ") or "", "([%d%.]+):([^,]+)") do
  local port, name = pn:match("([^/]+)/(.+)")
  seq[#seq + 1] = { t = tonumber(t), f = fld(port, name) }
end
local g = {}
for v in string.gmatch(os.getenv("TS_GUN") or "17c,0e6,179,0e8,0", "([%x]+)") do g[#g + 1] = tonumber(v, 16) end
-- TS_GUNAT="t=p1x,p1y,p2x,p2y,off;t=..." switches the forced values over time
local sched = {}
for t, vals in string.gmatch(os.getenv("TS_GUNAT") or "", "([%d%.]+)=([%x,]+)") do
  local v = {}
  for x in string.gmatch(vals, "([%x]+)") do v[#v + 1] = tonumber(x, 16) end
  sched[#sched + 1] = { t = tonumber(t), v = v }
end
local iocpu = m.devices[":ioboard:iocpu"]
local zsp = iocpu.spaces["program"]
TSG = zsp:install_read_tap(0x8100, 0x810f, "gun", function(off, data, mask)
  local o = off & 0xf
  if o >= 8 then
    if o == 8 then return g[5] end
    return data
  end
  local val = ({ g[2], g[1], g[4], g[3] })[(o >> 1) + 1]   -- P1Y, P1X, P2Y, P2X
  if (o & 1) == 0 then return val & 0xff else return (val >> 8) & 0xff end
end)
local scr = m.screens[":screen"]
local EVERY = tonumber(os.getenv("TS_EVERY") or "1")
local FROM = tonumber(os.getenv("TS_FROM") or "0")
local T_END = tonumber(os.getenv("TS_TEND") or "40")
local nexts = FROM
TSF = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  for _, s in ipairs(sched) do if t >= s.t then g = s.v end end
  for _, s in ipairs(seq) do
    if t >= s.t and t < s.t + 0.2 then s.f:set_value(1) elseif t >= s.t + 0.2 and not s.done then s.f:clear_value(); s.done = true end
  end
  if t >= nexts then scr:snapshot(string.format("s%06.2f.png", t)); nexts = nexts + EVERY end
  if t >= T_END then m:exit() end
end)
