-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- VIRTUA COP: SHOTS AT THE SCREEN'S EDGE (R961). Forces the I/O board's gun
-- FPGA reads (Z80 0x8100-0x8108: P1_Y, P1_X, P2_Y, P2_X, the off-screen
-- byte) to scheduled values and presses buttons on time, with snapshots, so
-- the revolver shows whether a coordinate with the off-screen bit clear is a
-- shot (a round spent) or not. R961's run (fresh NVRAM):
--   TS_SEQ="40::IN0/Coin 1,42::IN0/1 Player Start,72::IN1/P1 Trigger,..."
--   TS_GUNAT="t=p1x,p1y,p2x,p2y,off;..." (hex), TS_FROM / TS_EVERY / TS_TEND
-- Run: mame vcopa -autoboot_script <this> -video none -nothrottle -snapview native
local sp = m.devices[":ioboard:iocpu"].spaces["program"]
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
-- g = p1x, p1y, p2x, p2y, off (hex); port order P1_Y, P1_X, P2_Y, P2_X
local g = nil
local sched = {}
for t, vals in string.gmatch(os.getenv("TS_GUNAT") or "", "([%d%.]+)=([%x,]+)") do
  local v = {}
  for x in string.gmatch(vals, "([%x]+)") do v[#v + 1] = tonumber(x, 16) end
  sched[#sched + 1] = { t = tonumber(t), v = v }
end
GR = sp:install_read_tap(0x8100, 0x8108, "gun", function(o, d, mask)
  if g == nil then return d end
  local off = o - 0x8100
  if off < 8 then
    local v = ({ g[2], g[1], g[4], g[3] })[(off >> 1) + 1]
    return ((off & 1) == 1) and ((v >> 8) & 0xff) or (v & 0xff)
  end
  return 0xfc | (g[5] & 3)
end)
local EVERY = tonumber(os.getenv("TS_EVERY") or "1")
local nexts = tonumber(os.getenv("TS_FROM") or "0")
local T_END = tonumber(os.getenv("TS_TEND") or "40")
TSF = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  for _, s in ipairs(sched) do if t >= s.t then g = s.v end end
  for _, s in ipairs(seq) do
    if t >= s.t and t < s.t + 0.15 then s.f:set_value(1) elseif t >= s.t + 0.15 and not s.done then s.f:clear_value(); s.done = true end
  end
  if t >= nexts then scr:snapshot(string.format("s%06.2f.png", t)); nexts = nexts + EVERY end
  if t >= T_END then m:exit() end
end)
