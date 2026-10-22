-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- THE HOUSE OF THE DEAD, PLAYED BY A SCRIPT (R935): coins every 6 s and start
-- every 1.5 s from HA_PLAY (so a lost life is continued), and P1's gun forced
-- through the 315-5649's mux read (as sim/io/mame_m2_vcop2_play.lua does, on
-- HOTD's ranges) to a seeded random point six shots in seven, the seventh off
-- screen (reload). With HA_SEED=1 and the nvram R935 used it reaches the
-- courtyard (41-50 s), the stone wall (67-74 s: the first logrl at 68.67 s)
-- and the fountain; the game is deterministic under it, so a second run with
-- dumps lands on the same frames.
--   HA_PLAY (22) HA_TEND (400) HA_SEED (1) HA_OUT <file> (snapshot / trigger log)
--   HA_SNAP / HA_SNAP0: snapshots every HA_SNAP s from HA_SNAP0, named
--     t<time>_f<MAME's 3D list number> (M2LOD_OUT's last line)
--   HA_TRIG "t1,t2,...": create M2GEO_TRIG at those times (a walk dump each)
--   HA_EXTRA <lua>: another script run beside this one (dofile)
-- Run: m2lod hotd -video none -sound none -nothrottle -autoboot_script <this>
local m = manager.machine
local cpu = m.devices[":maincpu"]
local sp = cpu.spaces["program"]
local scr = m.screens[":screen"]
local function fld(port, name)
  for n, f in pairs(m.ioport.ports[port].fields) do if n == name then return f end end
  error("no field " .. port .. " " .. name)
end
local coin = fld(":IN0", "Coin 1")
local start = fld(":IN0", "1 Player Start")
local trig = fld(":IN1", "P1 Trigger")
local T_PLAY = tonumber(os.getenv("HA_PLAY") or "22")
local T_END = tonumber(os.getenv("HA_TEND") or "400")
local SNAPE = tonumber(os.getenv("HA_SNAP") or "1")
local SNAP0 = tonumber(os.getenv("HA_SNAP0") or "0")
local LOD = os.getenv("M2LOD_OUT")
local SEED = tonumber(os.getenv("HA_SEED") or "1")
local TRIG = os.getenv("HA_TRIG")
local trigs = {}
if TRIG then for t in string.gmatch(TRIG, "[^,]+") do trigs[#trigs+1] = tonumber(t) end end
local out = assert(io.open(os.getenv("HA_OUT"), "w"))
local function lastframe()
  if not LOD then return -1 end
  local f = io.open(LOD, "r"); if not f then return -1 end
  local sz = f:seek("end"); f:seek("set", math.max(0, sz - 4000)); local s = f:read("a"); f:close()
  local last = -1
  for n in string.gmatch(s, "F (%d+) ") do last = tonumber(n) end
  return last
end
-- deterministic LCG
local rs = SEED
local function rnd() rs = (rs * 1103515245 + 12345) % 2147483648; return rs / 2147483648 end
local gx, gy = 384, 233
local function off(x, y) return (x <= 173 + 21 or x >= 596 - 21 or y <= 87 + 14 or y >= 380 - 14) and 1 or 0 end
local mux = 0
GW = sp:install_write_tap(0x01c00014, 0x01c00017, "gunmux", function(o, d, mask) if (mask & 0xff) ~= 0 then mux = d & 0xff end end)
GR = sp:install_read_tap(0x01c00018, 0x01c0001b, "gundata", function(o, d, mask)
  if (mask & 0xff) == 0 then return d end
  local b
  if mux < 8 then
    local v = ({ gy, gx, 233, 384 })[(mux >> 1) + 1]
    b = ((mux & 1) == 1) and ((v >> 8) & 0xff) or (v & 0xff)
  else b = 0xfc | off(gx, gy) end
  return (d & 0xffffff00) | b
end)
local ns, ti, shot, phase_t = SNAP0, 1, 0, 0
local PER = 0.13
HF = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  -- coins every 6 s from T_PLAY-4, start pressed every 1.5 s after T_PLAY
  local c = (t >= T_PLAY - 4) and ((t - (T_PLAY - 4)) % 6.0) < 0.15
  if c then coin:set_value(1) else coin:clear_value() end
  local s = (t >= T_PLAY) and ((t - T_PLAY) % 1.5) < 0.2
  if s then start:set_value(1) else start:clear_value() end
  if t >= T_PLAY then
    local k = math.floor((t - T_PLAY) / PER)
    local ph = (t - T_PLAY) - k * PER
    if k ~= shot then
      shot = k
      if k % 7 == 6 then gx, gy = 180, 90       -- off screen: reload
      else gx = math.floor(230 + rnd() * 310); gy = math.floor(130 + rnd() * 200) end
    end
    if ph > 0.03 and ph < 0.08 then trig:set_value(1) else trig:clear_value() end
  end
  if ti <= #trigs and t >= trigs[ti] then
    local f = io.open(os.getenv("M2GEO_TRIG"), "w"); f:write("x"); f:close()
    out:write(string.format("TRIG %.3f lod %d\n", t, lastframe())); out:flush(); ti = ti + 1
  end
  if t >= ns then
    local lf = lastframe()
    scr:snapshot(string.format("t%06.2f_f%d.png", t, lf))
    out:write(string.format("%.3f lod %d\n", t, lf)); out:flush()
    ns = ns + SNAPE
  end
  if t >= T_END then out:close(); m:exit() end
end)
local xf = os.getenv("HA_EXTRA"); if xf then dofile(xf) end
