-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- THE HOUSE OF THE DEAD: THE GAME'S OWN AIM MARK (R960). Drives the test menu
-- (TEST MENU -> GUN SETTING -> GUN MARK CHECK) and forces the gun coordinates
-- through the 315-5649's serial channel 2 mux, so snapshots show where the
-- game itself puts each player's mark for a coordinate; sim/io/hotd_marks.py
-- measures them. Fresh NVRAM: the game's default calibration (173-596 /
-- 163-596 / 87-380, as MAME's ports). R960's sequence:
--   TS_SEQ="20::IN0/Service Mode,23::IN0/Service 1 (x9, every 0.5 s),
--           28.5::IN0/Service Mode,30::IN0/Service 1,31::IN0/Service Mode"
--   TS_GUNAT="t=p1x,p1y,p2x,p2y,off;..." (hex), TS_FROM / TS_EVERY / TS_TEND
-- Run: mame hotd -autoboot_script <this> -video none -snapview native -nosnapbilinear
local m = manager.machine
local sp = m.devices[":maincpu"].spaces["program"]
local scr = m.screens[":screen"]
local function fld(port, name)
  for n, f in pairs(m.ioport.ports[port].fields) do if n == name then return f end end
  error("no field " .. port .. " " .. name)
end
local seq = {}
for t, pn in string.gmatch(os.getenv("TS_SEQ") or "", "([%d%.]+):([^,]+)") do
  local port, name = pn:match("([^/]+)/(.+)")
  seq[#seq + 1] = { t = tonumber(t), f = fld(port, name) }
end
local g = {0x180,0x0e9,0x17b,0x0e9,0}
local sched = {}
for t, vals in string.gmatch(os.getenv("TS_GUNAT") or "", "([%d%.]+)=([%x,]+)") do
  local v = {}
  for x in string.gmatch(vals, "([%x]+)") do v[#v + 1] = tonumber(x, 16) end
  sched[#sched + 1] = { t = tonumber(t), v = v }
end
local mux = 0
GW = sp:install_write_tap(0x01c00014, 0x01c00017, "gunmux", function(o, d, mask) if (mask & 0xff) ~= 0 then mux = d & 0xff end end)
GR = sp:install_read_tap(0x01c00018, 0x01c0001b, "gundata", function(o, d, mask)
  if (mask & 0xff) == 0 then return d end
  local b
  if mux < 8 then
    local v = ({ g[2], g[1], g[4], g[3] })[(mux >> 1) + 1]
    b = ((mux & 1) == 1) and ((v >> 8) & 0xff) or (v & 0xff)
  else b = 0xfc | (g[5] & 3) end
  return (d & 0xffffff00) | b
end)
local EVERY = tonumber(os.getenv("TS_EVERY") or "1")
local nexts = tonumber(os.getenv("TS_FROM") or "0")
local T_END = tonumber(os.getenv("TS_TEND") or "40")
TSF = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  for _, s in ipairs(sched) do if t >= s.t then g = s.v end end
  for _, s in ipairs(seq) do
    if t >= s.t and t < s.t + 0.2 then s.f:set_value(1) elseif t >= s.t + 0.2 and not s.done then s.f:clear_value(); s.done = true end
  end
  if t >= nexts then scr:snapshot(string.format("s%06.2f.png", t)); nexts = nexts + EVERY end
  if t >= T_END then m:exit() end
end)
