-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- THE THREE OTHER 2A GAMES PLAYED BY SCRIPT (R869), for a long MAME session
-- another instrument rides on (the i960 form log, sim/io/mame_i960_formlog.py):
-- attract, coins, start and play, the same session every run.
--   rally  Sega Rally: accelerator held, the wheel swept, brake / hand brake /
--          VR now and then, the gear lever stepped 1-2-3-4 (if the game is in MT)
--   zg     Zero Gunner: button 1 held (fire), button 2 every 5 s, the stick on
--          a fixed pseudo-random walk
--   vcop2  Virtua Cop 2: the gun swept and fired, a reload off-screen every 4 s
-- Each coin time drops two coins; Start is pressed every 2 s for 100 s after
-- each (it also takes the continue offers and the menus).
--
--   PL_GAME=rally|zg|vcop2  PL_COIN=<s,s,...>  PL_TEND=<s>
--   [PL_SNAP=<s>] a snapshot every <s> seconds   [PL_LOG=<file>] time, frame, IP
--   [PL_TEST=<s>] the test switch (held 1 s) at s, then the service button
--                 every 2 s and the test switch every 9 s (a walk of the menus)
--
-- Everything written is ROM-derived and stays outside the repository.
local m = manager.machine
local ports = m.ioport.ports
local scr = m.screens[":screen"]
local cpu = m.devices[":maincpu"]
local GAME = os.getenv("PL_GAME") or "rally"
local COINS = {}
for v in string.gmatch(os.getenv("PL_COIN") or "30,200,330", "[^,]+") do COINS[#COINS + 1] = tonumber(v) end
local T_END = tonumber(os.getenv("PL_TEND") or "420")
local SNAP = tonumber(os.getenv("PL_SNAP") or "0")
local T_TEST = tonumber(os.getenv("PL_TEST") or "")
local log = os.getenv("PL_LOG") and assert(io.open(os.getenv("PL_LOG"), "w"))

if log then
  for pn, p in pairs(ports) do
    for fn, _ in pairs(p.fields) do log:write(string.format("PORT %s / %s\n", pn, fn)) end
  end
  log:flush()
end
local function fld(p, pat)
  if not ports[p] then return nil end
  for k, f in pairs(ports[p].fields) do if k:find(pat) then return f end end
  return nil
end
local function set(f, v) if f then f:set_value(v) end end
local function first(p) return ports[p] and select(2, next(ports[p].fields)) end
local F = {
  coin = fld(":IN0", "Coin 1"), start = fld(":IN0", "1 Player Start"),
  test = fld(":IN0", "Service Mode"), svc = fld(":IN0", "Service 1"),
  acc = first(":ACCEL"), brk = first(":BRAKE"), str = first(":STEER"),
  vr = fld(":IN0", "VR"), hb = first(":IN2"),
  g1 = fld(":GEARS", "GEAR 1"), g2 = fld(":GEARS", "GEAR 2"), g3 = fld(":GEARS", "GEAR 3"), g4 = fld(":GEARS", "GEAR 4"),
  b1 = fld(":IN1", "P1 Button 1"), b2 = fld(":IN1", "P1 Button 2"),
  up = fld(":IN1", "P1 Up"), dn = fld(":IN1", "P1 Down"), lt = fld(":IN1", "P1 Left"), rt = fld(":IN1", "P1 Right"),
  x = first(":P1_X"), y = first(":P1_Y"), trig = fld(":IN1", "P1 Trigger") or fld(":IN1", "P1 Button 1"),
}
if log then
  for k, v in pairs(F) do log:write(string.format("FIELD %s %s\n", k, v and "yes" or "no")) end
  log:flush()
end
local seed = 12345
local function rnd(n) seed = (seed * 1103515245 + 12345) & 0x7fffffff; return (seed >> 8) % n end
local step_t, next_snap = -1, 0
local function pulse(t, at, len) return t >= at and t < at + len end
PL_F = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  local playing, coin, start = false, 0, 0
  for _, c in ipairs(COINS) do
    if pulse(t, c, 0.2) or pulse(t, c + 0.6, 0.2) then coin = 1 end
    if t >= c + 3 and t < c + 103 and ((t - c - 3) % 2) < 0.2 then start = 1 end
    if t >= c + 3 then playing = true end
  end
  set(F.coin, coin); set(F.start, start)
  if playing then
    if GAME == "rally" then
      set(F.acc, ((t % 20) < 18) and 0xff or 0x00)
      set(F.brk, ((t % 20) >= 18.5) and 0xff or 0x00)
      set(F.str, 0x80 + math.floor(0x60 * math.sin(t * 0.7)))
      set(F.vr, ((t % 13) < 0.2) and 1 or 0)
      set(F.hb, ((t % 17) < 0.5) and 1 or 0)
      local g = math.floor(t / 7) % 4             -- a gear every 7 s: 1 2 3 4
      set(F.g1, g == 0 and 1 or 0); set(F.g2, g == 1 and 1 or 0)
      set(F.g3, g == 2 and 1 or 0); set(F.g4, g == 3 and 1 or 0)
    elseif GAME == "zg" then
      set(F.b1, 1)
      set(F.b2, ((t % 5) < 0.3) and 1 or 0)
      local s = math.floor(t * 4)
      if s ~= step_t then
        step_t = s
        local d = rnd(9)
        set(F.up, (d == 1 or d == 5 or d == 6) and 1 or 0); set(F.dn, (d == 2 or d == 7 or d == 8) and 1 or 0)
        set(F.lt, (d == 3 or d == 5 or d == 7) and 1 or 0); set(F.rt, (d == 4 or d == 6 or d == 8) and 1 or 0)
      end
    elseif GAME == "vcop2" then
      local x = 0x17c + math.floor(0xd0 * math.sin(t * 0.9))
      local y = 0x0e6 + math.floor(0x90 * math.sin(t * 1.3))
      if (t % 4) >= 3.6 then x, y = 0x083, 0x024 end
      set(F.x, x); set(F.y, y)
      set(F.trig, ((t * 4) % 2 < 1) and 1 or 0)
    end
  end
  if T_TEST and t >= T_TEST then
    local u = t - T_TEST
    set(F.test, (pulse(u, 0, 1.0) or (u > 9 and (u % 9) < 1.0)) and 1 or 0)
    set(F.svc, (u % 2 >= 1 and u % 2 < 1.2) and 1 or 0)
  end
  if SNAP > 0 and t >= next_snap then
    scr:snapshot(string.format("%s_%05.1f.png", GAME, t))
    next_snap = next_snap + SNAP
  end
  if log and math.floor(t) ~= math.floor(t - 1 / 60) then
    log:write(string.format("%.2f frame %d ip %08x\n", t, scr:frame_number(), cpu.state["ip"].value)); log:flush()
  end
  if t >= T_END then
    if log then log:close() end
    m:exit()
  end
end)
