-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- DAYTONA USA DRIVEN BY AN AUTOPILOT THAT RAMS THE OPPONENTS (GitHub #34).
-- MAME 0.289, set daytona, headless (tools/m2b-mame.sh). Coins up at 12 s,
-- presses start at 14 s and lets the selections time out (Beginner,
-- Automatic); the race's rolling start is at ~44 s.
--
-- The game's car table, found in MAME's work RAM (no symbols): car k
-- (0 = the player, 1-39 the field) at 0x505100 + 0x300 k; +0x9c x, +0xa0 y,
-- +0xa4 z (floats).
--
-- The autopilot follows the trail the AI cars leave (as mame_m2_rally_ap.lua
-- does); from AP_RAM s on it aims at the nearest car ahead within AP_RAMD
-- units instead, offset AP_RAMOFF units to the outside of the bend, so that
-- car is driven into the wall.
--   APLOG=<file>   every frame: "F <frame> <t>" then per car
--                  "<k> <x> <y> <z>" (floats, %.3f), one line per frame
--   INREC=<file>   the cabinet's port values each frame ("<frame> IN0 IN1
--                  GEARS STEER ACCEL BRAKE", hex)
--   AP_SNAP=<s>    a snapshot every <s> from AP_SNAPFROM (44)
--   STRUCTLOG=<file>  every STRUCTN (4) frames: the frame (u32) and the whole
--                  car table, 40 x 0x300 bytes
--   AP_ZONES="x0,x1,z0,z1;..."  ram only while the player is in one of them
--   AP_LATOFF=<u>  in AP_ZONES (and not ramming), aim LATOFF units to the
--                  outside of the bend: the player against the outer wall
--   AP_CHAIN=<lua> another autoboot script run alongside this one
--   AP_END=<s>     exit at that emulated time (default 200)
-- R969's reproduction (an AI car through the outer wall of the Beginner
-- course's left hairpin, car 33, frames 9166-9203): MAME 0.289 daytona,
-- AP_RAM=50 AP_RAMOFF=3, everything else default. The game's own handler
-- block is car + 0x80 (g13 in its code): +0x18 speed (int), +0x48 heading,
-- +0x1bc the ground polygon's surface bits (2 road, 0x20 wall), +0x211 the
-- hit countdown, +0x23a the speed-class index into the wall tables.
-- Everything written is ROM-derived and stays outside the repository.
local m = manager.machine
local cpu = m.devices[":maincpu"]
local sp = cpu.spaces["program"]
local ports = m.ioport.ports
local function fld(p, pat)
  if not ports[p] then return nil end
  for k, f in pairs(ports[p].fields) do if k:find(pat) then return f end end
end
local A = {coin = fld(":IN0", "Coin 1"), start = fld(":IN0", "Start"),
  acc = fld(":ACCEL", "Pedal"), brk = fld(":BRAKE", "Pedal"), str = fld(":STEER", "Paddle")}
local function set(f, v) if f then f:set_value(v) end end
local function rf(a) return string.unpack("<f", string.pack("<I4", sp:read_u32(a))) end
local function env(n, d) return tonumber(os.getenv(n) or d) end
-- AP_CHAIN=<lua>: another script run alongside (sim/tgp/tgp_capture.lua with
-- TGPCAP_NOINPUT=1 records the TGP across the session)
if os.getenv("AP_CHAIN") then dofile(os.getenv("AP_CHAIN")) end
local L = os.getenv("APLOG") and assert(io.open(os.getenv("APLOG"), "w"))
local SIGN = env("AP_SIGN", "1")
local GAIN = env("AP_GAIN", "200")
local LOOK = env("AP_LOOK", "25")
local LOOKK = env("AP_LOOKK", "0.1")
local AP_FROM = env("AP_FROM", "44")
local AP_RAM = env("AP_RAM", "1e9")
local RAMD = env("AP_RAMD", "60")
local RAMOFF = env("AP_RAMOFF", "0")
local AP_END = env("AP_END", "200")
-- AP_ZONES="x0,x1,z0,z1;..." ram only while the player is inside one of them
local ZONES = {}
for zs in (os.getenv("AP_ZONES") or ""):gmatch("[^;]+") do
  local zb = {}
  for v in zs:gmatch("[^,]+") do zb[#zb + 1] = tonumber(v) end
  ZONES[#ZONES + 1] = zb
end
local VMAX = env("AP_VMAX", "999")
local SNAP = os.getenv("AP_SNAP") and tonumber(os.getenv("AP_SNAP"))
local nsnap = env("AP_SNAPFROM", "44")
local NCAR = 40
local LATOFF = env("AP_LATOFF", "0")
local SL = os.getenv("STRUCTLOG") and assert(io.open(os.getenv("STRUCTLOG"), "wb"))
local SLN = env("STRUCTN", "4")
local CAR = 0x505100
local function pos(k) local b = CAR + 0x300 * k + 0x9c; return rf(b), rf(b + 4), rf(b + 8) end
local trail = {}
local last = {}
local head, ppx, ppz = 0, nil, nil
local function wrap(a) return (a + math.pi) % (2 * math.pi) - math.pi end
AP_F = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  local fr = m.screens[":screen"]:frame_number()
  set(A.coin, (t > 12 and t < 12.3) and 1 or 0)
  set(A.start, (t > 14 and t < 14.3) and 1 or 0)
  if t >= AP_END then m:exit() return end
  local px, py, pz = pos(0)
  if L then
    local o = {string.format("F %d %.4f", fr, t)}
    for k = 0, NCAR - 1 do
      local x, y, z = pos(k)
      o[#o + 1] = string.format("%.3f %.3f %.3f", x, y, z)
    end
    L:write(table.concat(o, " "), "\n")
  end
  if SL and fr % SLN == 0 then SL:write(string.pack("<I4", fr), sp:read_range(CAR, CAR + 0x300 * NCAR - 1, 8)) end
  if SNAP and t >= nsnap then m.video:snapshot(); nsnap = nsnap + SNAP end
  if t < AP_FROM then return end
  for k = 1, NCAR - 1 do
    local x, _, z = pos(k)
    local tr = trail[k]
    local lp = last[k]
    if (not tr) or (lp and ((x - lp[1]) ^ 2 + (z - lp[2]) ^ 2 > 400)) then tr = {}; trail[k] = tr end
    if x == x and z == z then
      local n = #tr
      if n == 0 or (x - tr[n][1]) ^ 2 + (z - tr[n][2]) ^ 2 > 4 then tr[n + 1] = {x, z} end
      last[k] = {x, z}
    end
  end
  local spd = 0
  if ppx then
    local vx, vz = px - ppx, pz - ppz
    spd = math.sqrt(vx * vx + vz * vz)
    if spd > 0.03 then head = math.atan(vx, vz) end
  end
  ppx, ppz = px, pz
  local kmh = spd * 60 * 3.6
  -- the nearest point of any car's trail, then LOOK on along it
  local best, bt, bi = 1e30, nil, 0
  for k, tr in pairs(trail) do
    for i = 1, #tr - 1 do
      local d = (tr[i][1] - px) ^ 2 + (tr[i][2] - pz) ^ 2
      if d < best then best, bt, bi = d, tr, i end
    end
  end
  local function ahead(dist)
    if not bt then return px + 30 * math.sin(head), pz + 30 * math.cos(head) end
    local acc, i = 0, bi
    while i < #bt and acc < dist do
      acc = acc + math.sqrt((bt[i + 1][1] - bt[i][1]) ^ 2 + (bt[i + 1][2] - bt[i][2]) ^ 2); i = i + 1
    end
    return bt[i][1], bt[i][2]
  end
  local tx, tz = ahead(LOOK + LOOKK * kmh)
  local mode = "T"
  local inzone = #ZONES == 0
  for _, zb in ipairs(ZONES) do
    if px >= zb[1] and px <= zb[2] and pz >= zb[3] and pz <= zb[4] then inzone = true end
  end
  if t >= AP_RAM and inzone then
    -- the nearest car ahead (within +-60 degrees of the heading)
    local bd, bk = RAMD * RAMD, nil
    for k = 1, NCAR - 1 do
      local x, _, z = pos(k)
      local d = (x - px) ^ 2 + (z - pz) ^ 2
      if d < bd and math.abs(wrap(math.atan(x - px, z - pz) - head)) < 1.0 then bd, bk = d, k end
    end
    if bk then
      local x, _, z = pos(bk)
      -- outward = away from the bend's inside: the trail's turn direction
      local fx, fz = ahead(60)
      local turn = wrap(math.atan(fx - px, fz - pz) - head)
      local s = turn > 0 and -1 or 1
      local nx, nz = math.cos(head), -math.sin(head)   -- right of the heading
      tx, tz = x + s * RAMOFF * nx, z + s * RAMOFF * nz
      mode = "R" .. bk
    end
  end
  if LATOFF ~= 0 and inzone and mode == "T" then
    -- drive LATOFF units to the outside of the bend (the player's own wall)
    local fx, fz = ahead(60)
    local turn = wrap(math.atan(fx - px, fz - pz) - head)
    local s = turn > 0 and -1 or 1
    tx, tz = tx + s * LATOFF * math.cos(head), tz - s * LATOFF * math.sin(head)
  end
  local err = wrap(math.atan(tx - px, tz - pz) - head)
  local s = math.max(-0x7f, math.min(0x7f, math.floor(err * GAIN * SIGN)))
  set(A.str, 0x80 + s)
  local brake = math.abs(err) > 0.5 and kmh > 90
  set(A.acc, (brake or kmh > VMAX) and 0 or 0xff); set(A.brk, brake and 0xff or 0)
  if L then L:write(string.format("D %s err %.3f s %d kmh %.0f near %.1f\n", mode, err, s, kmh, math.sqrt(best))) end
end)
local IR = os.getenv("INREC") and assert(io.open(os.getenv("INREC"), "w"))
if IR then
  AP_IR = emu.add_machine_frame_notifier(function()
    local function rd(p) return ports[p] and ports[p]:read() or 0xff end
    IR:write(string.format("%d %02x %02x %02x %02x %02x %02x\n", m.screens[":screen"]:frame_number(),
      rd(":IN0") & 0xff, rd(":IN1") & 0xff, rd(":GEARS") & 0xff, rd(":STEER") & 0xff, rd(":ACCEL") & 0xff, rd(":BRAKE") & 0xff))
  end)
end
