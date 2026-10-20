-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- VIRTUA COP'S AMMO DISPLAY (R899): a scripted game (coin 40 s, start 41.5 s;
-- a shot at 52 s picks the stage), single shots, and per frame the number of
-- i960 writes to each video memory (texture RAM, luma, tile / char RAM,
-- palette, colour table, buffer RAM, geometrizer, TGP FIFO) -- frames.txt --
-- with every texture / tile / char / luma / palette write logged from AM_T0
-- (writes.txt); snapshots; and geometry-walk dumps on time (patch p14's
-- M2GEO_TRIG: the script creates the trigger file, the next walk dumps).
--   AM_OUT=<dir>  AM_SHOTS="t,t,..."  AM_FIREEVERY="t0:t1:period"
--   AM_TRIG="t,t,..."  AM_TRIGEVERY="t0:t1:period"  AM_TRIGFILE=<M2GEO_TRIG's path>
--   AM_AUTORELOAD=1 (DSW1 Reloading = Auto)  AM_T0 AM_TEND AM_SNAPEVERY
-- Run (writable dirs outside the tree, as tools/m2b-mame.sh; set M2LOD_OUT):
--   M2GEO_OUT=<dir> M2GEO_TRIG=<file> mame vcopa -autoboot_script <this> -snapview native -snapsize 496x384
local m = manager.machine
local cpu = m.devices[":maincpu"]
local sp = cpu.spaces["program"]
local scr = m.screens[":screen"]
local out = os.getenv("AM_OUT")
local function fld(port, name)
  for n, f in pairs(m.ioport.ports[port].fields) do if n == name then return f end end
  error("no field " .. port .. " " .. name)
end
local c1, s1 = fld(":IN0", "Coin 1"), fld(":IN0", "1 Player Start")
local trig = fld(":IN1", "P1 Trigger")
local g = { 0x0e6, 0x17c, 0x0e8, 0x179, 0 }
local iocpu = m.devices[":ioboard:iocpu"]
AMG = iocpu.spaces["program"]:install_read_tap(0x8100, 0x810f, "gun", function(off, data, mask)
  local o = off & 0xf
  if data == 0x80 and o ~= 8 then return data end
  if o == 8 then return 0xfc | g[5] end
  if o > 8 then return data end
  local v = g[(o >> 1) + 1]
  if (o & 1) == 0 then return v & 0xff else return (v >> 8) & 0xff end
end)
if os.getenv("AM_AUTORELOAD") then fld(":ioboard:dsw1", "Reloading").user_value = 0 end
local shots = {}
do
  local a, b, p = (os.getenv("AM_FIREEVERY") or ""):match("([%d%.]+):([%d%.]+):([%d%.]+)")
  if a then local t = tonumber(a); while t < tonumber(b) do shots[#shots + 1] = t; t = t + tonumber(p) end end
end
local trigs = {}
do
  local a, b, p = (os.getenv("AM_TRIGEVERY") or ""):match("([%d%.]+):([%d%.]+):([%d%.]+)")
  if a then local t = tonumber(a); while t < tonumber(b) do trigs[#trigs + 1] = { t = t, done = false }; t = t + tonumber(p) end end
end
for t in string.gmatch(os.getenv("AM_SHOTS") or "", "([%d%.]+)") do shots[#shots + 1] = tonumber(t) end
for t in string.gmatch(os.getenv("AM_TRIG") or "", "([%d%.]+)") do trigs[#trigs + 1] = { t = tonumber(t), done = false } end
local trigfile = os.getenv("AM_TRIGFILE")
local T0 = tonumber(os.getenv("AM_T0") or "46")
local T_END = tonumber(os.getenv("AM_TEND") or "64")
local SNAPE = tonumber(os.getenv("AM_SNAPEVERY") or "0.25")
local regions = {
  { "tex0", 0x12000000, 0x123fffff },
  { "tex1", 0x12400000, 0x127fffff },
  { "luma", 0x12800000, 0x1281ffff },
  { "tile", 0x01000000, 0x0100ffff },
  { "char", 0x01080000, 0x010fffff },
  { "pal",  0x01800000, 0x01803fff },
  { "xlat", 0x01810000, 0x0181bfff },
  { "buf",  0x00900000, 0x0097ffff },
  { "geo",  0x00800000, 0x00803fff },
  { "fifo", 0x00880000, 0x00887fff },
}
local cnt = {}
local detail = assert(io.open(out .. "/writes.txt", "w"))
local fr = assert(io.open(out .. "/frames.txt", "w"))
local logdetail = { tex0 = true, tex1 = true, tile = true, char = true, luma = true, pal = true }
AMT = {}
for _, r in ipairs(regions) do
  local name = r[1]
  cnt[name] = 0
  AMT[#AMT + 1] = sp:install_write_tap(r[2], r[3], name, function(o, d, mk)
    cnt[name] = cnt[name] + 1
    local t = emu.time()
    if logdetail[name] and t >= T0 then
      detail:write(string.format("%.4f %s %08x = %08x mask %08x ip %08x\n", t, name, o, d, mk, cpu.state["ip"].value))
    end
  end)
end
local ns = T0
AMF = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  -- coin 40, start 41.5
  if t >= 40 and t < 40.2 then c1:set_value(1) else c1:clear_value() end
  if t >= 41.5 and t < 41.7 then s1:set_value(1) else s1:clear_value() end
  local tp = false
  for _, s in ipairs(shots) do if t >= s and t < s + 0.05 then tp = true end end
  if tp then trig:set_value(1) else trig:clear_value() end
  for _, tr in ipairs(trigs) do
    if not tr.done and t >= tr.t then
      local f = io.open(trigfile, "w"); f:write("x"); f:close(); tr.done = true
      detail:write(string.format("%.4f TRIG\n", t))
    end
  end
  if t >= T0 then
    local s = string.format("%.4f f%d", t, scr:frame_number())
    for _, r in ipairs(regions) do s = s .. string.format(" %s=%d", r[1], cnt[r[1]]) end
    s = s .. string.format(" mode=%02x p1=%02x tp=%d", sp:read_u8(0x5016d4), sp:read_u8(0x50ee30), tp and 1 or 0)
    fr:write(s .. "\n")
  end
  for _, r in ipairs(regions) do cnt[r[1]] = 0 end
  if t >= ns and t < T_END then scr:snapshot(string.format("p%06.2f.png", t)); ns = ns + SNAPE end
  if t >= T_END then detail:close(); fr:close(); m:exit() end
end)
