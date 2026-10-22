-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- R926: SEGA RALLY DRIVEN BY AN AUTOPILOT THAT CATCHES THE OPPONENTS, over
-- sim/io/mame_m2_2a_play.lua (coins and start; run it with PL_GAME=none so it
-- leaves the controls to this script). The game's own object table, found in
-- MAME 0.289's work RAM (srallyc, verified by dumps of a race, no symbols):
--   0x500000 + 0x100 k   object k; +4 handler (0x5cacf0 an AI car, 0x5d3f40
--                        the player), +0x10 flags (bits 31:16 the wheels'
--                        state: 0000 on the course line, 2222 / 3333 / 4343
--                        the full physics), +0x14 x y z, +0x2c velocity a
--                        frame, +0x88 course segment, +0x8c its render record
--                        (byte 0x51 bits 7:6: the detail the frame allowed),
--                        +0x9c heading
-- The autopilot steers along the trail the AI cars leave (the nearest point
-- of any car's trail, then AP_LOOK + AP_LOOKK * km/h along it), lifts when the
-- trail AP_FAR + AP_FARK * km/h on bends by more than AP_LIFTA rad above
-- AP_LIFTV km/h, brakes when far off line, and changes gear by speed.
-- Tuned (R926): AP_LOOK=15 AP_LOOKK=0.1 AP_GAIN=300 AP_FAR=40 AP_FARK=0.3
-- AP_LIFTA=0.4 AP_LIFTV=170 with PL_COIN=8: the first opponent is caught at
-- ~37 s (frame ~2115), within 3 units at ~42 s.
--   APLOG=<file>   every frame: "T <t> <frame> P <x> <y> <z> <handler>", then
--                  per AI car "A <slot> <segment> <pos> <vel> <heading>
--                  <+0x10>" (hex words) -- sim/io/rally_ai_check.py reads it,
--                  and tb_m2_boot's M2_CARLOG writes the same format
--   INREC=<file>   the cabinet's port values each frame ("<frame> IN0 IN1 IN2
--                  STEER ACCEL BRAKE", hex): tb_m2_boot's M2_INSCHED
--   PLAY_LUA=<sim/io/mame_m2_2a_play.lua>, AP_FROM=<s> (default 36)
-- Everything written is ROM-derived and stays outside the repository.
local m = manager.machine
local cpu = m.devices[":maincpu"]
local sp = cpu.spaces["program"]
local ports = m.ioport.ports
local function first(p) return ports[p] and select(2, next(ports[p].fields)) end
local function fld(p, pat)
  if not ports[p] then return nil end
  for k, f in pairs(ports[p].fields) do if k:find(pat) then return f end end
end
local A = {acc = first(":ACCEL"), brk = first(":BRAKE"), str = first(":STEER"),
  g1 = fld(":GEARS", "GEAR 1"), g2 = fld(":GEARS", "GEAR 2"), g3 = fld(":GEARS", "GEAR 3"), g4 = fld(":GEARS", "GEAR 4")}
local function set(f, v) if f then f:set_value(v) end end
local function rf(a) return string.unpack("<f", string.pack("<I4", sp:read_u32(a))) end
local L = os.getenv("APLOG") and assert(io.open(os.getenv("APLOG"), "w"))
local SIGN = tonumber(os.getenv("AP_SIGN") or "1")
local GAIN = tonumber(os.getenv("AP_GAIN") or "200")
local LOOK = tonumber(os.getenv("AP_LOOK") or "25")
local LOOKK = tonumber(os.getenv("AP_LOOKK") or "0")
local FAR = tonumber(os.getenv("AP_FAR") or "60")
local FARK = tonumber(os.getenv("AP_FARK") or "0")
local BRKA = tonumber(os.getenv("AP_BRKA") or "9")
local BRKV = tonumber(os.getenv("AP_BRKV") or "999")
local LIFTA = tonumber(os.getenv("AP_LIFTA") or "9")
local LIFTV = tonumber(os.getenv("AP_LIFTV") or "999")
local AP_FROM = tonumber(os.getenv("AP_FROM") or "36")
dofile(os.getenv("PLAY_LUA"))
local trail = {}      -- per slot: list of {x, z}
local last = {}
local head = 0
local ppx, ppz
local function wrap(a) return (a + math.pi) % (2 * math.pi) - math.pi end
AP_F = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  local fr = m.screens[":screen"]:frame_number()
  local px, py, pz = rf(0x500014), rf(0x500018), rf(0x50001c)
  local isp = sp:read_u32(0x500004) == 0x5d3f40
  local out = L and {}
  -- AI objects: trails and the log
  for k = 1, 15 do
    local b = 0x500000 + 0x100 * k
    if sp:read_u32(b + 4) == 0x5cacf0 then
      local x, y, z = rf(b + 0x14), rf(b + 0x18), rf(b + 0x1c)
      local tr = trail[k]
      local lp = last[k]
      if (not tr) or (lp and ((x - lp[1]) ^ 2 + (z - lp[2]) ^ 2 > 400)) then tr = {}; trail[k] = tr end
      if x == x and z == z then
        local n = #tr
        if n == 0 or (x - tr[n][1]) ^ 2 + (z - tr[n][2]) ^ 2 > 4 then tr[n + 1] = {x, z} end
        last[k] = {x, z}
      end
      if out then
        out[#out + 1] = string.format("A %d %d %s", k, sp:read_u32(b + 0x88) & 0xffff, table.concat({
          string.format("%08x %08x %08x", sp:read_u32(b + 0x14), sp:read_u32(b + 0x18), sp:read_u32(b + 0x1c)),
          string.format("%08x %08x %08x", sp:read_u32(b + 0x2c), sp:read_u32(b + 0x30), sp:read_u32(b + 0x34)),
          string.format("%08x %08x %08x", sp:read_u32(b + 0x9c), sp:read_u32(b + 0xa0), sp:read_u32(b + 0xa4)),
          string.format("%08x", sp:read_u32(b + 0x10))}, " "))
      end
    end
  end
  if L then
    L:write(string.format("T %.4f %d P %.3f %.3f %.3f %08x\n", t, fr, px, py, pz, sp:read_u32(0x500004)))
    if #out > 0 then L:write(table.concat(out, "\n") .. "\n") end
  end
  if t < AP_FROM or not isp then return end
  -- heading from the player's velocity
  local vx, vz = rf(0x50002c), rf(0x500034)
  local spd = math.sqrt(vx * vx + vz * vz)
  if spd > 0.03 then head = math.atan(vx, vz) end
  -- the trail whose nearest point is closest to us, then LOOK units on along it
  local best, bt, bi = 1e30, nil, 0
  for k, tr in pairs(trail) do
    for i = 1, #tr do
      local d = (tr[i][1] - px) ^ 2 + (tr[i][2] - pz) ^ 2
      if d < best and i < #tr then best, bt, bi = d, tr, i end
    end
  end
  local kmh = spd * 60 * 3.6
  local look = LOOK + LOOKK * kmh
  local function ahead(dist)
    if not bt then return px + 30 * math.sin(head), pz + 30 * math.cos(head) end
    local acc, i = 0, bi
    while i < #bt and acc < dist do
      acc = acc + math.sqrt((bt[i + 1][1] - bt[i][1]) ^ 2 + (bt[i + 1][2] - bt[i][2]) ^ 2); i = i + 1
    end
    return bt[i][1], bt[i][2]
  end
  local tx, tz = ahead(look)
  local fx, fz = ahead(FAR + FARK * kmh)
  local err = wrap(math.atan(tx - px, tz - pz) - head)
  local ferr = math.abs(wrap(math.atan(fx - px, fz - pz) - head))
  local s = math.max(-0x7f, math.min(0x7f, math.floor(err * GAIN * SIGN)))
  set(A.str, 0x80 + s)
  local brake = (ferr > BRKA and kmh > BRKV) or (math.abs(err) > 0.5 and kmh > 90)
  local lift = ferr > LIFTA and kmh > LIFTV
  set(A.acc, (brake or lift) and 0 or 0xff); set(A.brk, brake and 0xff or 0)
  local g = kmh < 55 and 1 or kmh < 95 and 2 or kmh < 140 and 3 or 4
  set(A.g1, g == 1 and 1 or 0); set(A.g2, g == 2 and 1 or 0); set(A.g3, g == 3 and 1 or 0); set(A.g4, g == 4 and 1 or 0)
  if L then L:write(string.format("D %.1f err %.3f s %d kmh %.0f near %.1f\n", head, err, s, kmh, math.sqrt(best))) end
end)
-- the cabinet's port values each frame, for the harness's M2_INSCHED
local IR = os.getenv("INREC") and assert(io.open(os.getenv("INREC"), "w"))
if IR then
  AP_IR = emu.add_machine_frame_notifier(function()
    local function rd(p) return ports[p] and ports[p]:read() or 0xff end
    IR:write(string.format("%d %02x %02x %02x %02x %02x %02x\n", m.screens[":screen"]:frame_number(),
      rd(":IN0") & 0xff, rd(":IN1") & 0xff, rd(":IN2") & 0xff, rd(":STEER") & 0xff, rd(":ACCEL") & 0xff, rd(":BRAKE") & 0xff))
  end)
end
