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
--   dig    R887: a digital stick and three buttons (hpyagu98, dynamcop,
--          pltkidsa, doaab) -- buttons on their own rhythms, a random stick
--   sky    R887: Sky Target -- the analog stick swept, gun held, missiles, view
--   bike   R887: Manx TT / Motor Raid -- throttle, lean, brake, shift / punch
--   orev   R928: Over Rev (2C; indy500's ports) -- accelerator held, the wheel
--          swept, brake now and then, shift up / down (IN1 0x10 / 0x20) and
--          View 1 (IN1 0x01) on their own rhythms; start on IN0 bit 6
--   chase  R903: Manx TT on an autopilot that rides at the other riders and
--          brake-checks the ones behind it -- knocks riders down (below)
-- Each coin time drops two coins; Start is pressed every 2 s for 100 s after
-- each (it also takes the continue offers and the menus).
--
--   PL_GAME=rally|zg|vcop2  PL_COIN=<s,s,...>  PL_TEND=<s>
--   [PL_SNAP=<s>] a snapshot every <s> seconds   [PL_LOG=<file>] time, frame, IP
--   [PL_TAP=<file>] R887: every i960 access to 0x01d80000-0x01d9ffff (the
--                 315-5881 / 317-0229 window) with time and IP; and a 64 KB
--                 map of the data ROM the i960 reads (D: 0x02000000-0x03ffffff,
--                 E: 0x06000000-0x06ffffff, MAME's main_data + 16 MB window);
--                 the first 200 i8251 data reads (U) and comm-board reads (C)
--   [PL_PRESS=<s>:test,<s>:svc,...] R887: test (1 s) / service (0.3 s) presses
--   [PL_PATCH=<off>=<word>,...] R887: program words patched before the boot
--   [PL_WATCH=<addr>,...] R887: with PL_TAP, those words logged every second
--   [PL_ZERO=1]   R887: with PL_TAP, every 315-5881 decrypt read (0x01d9000c)
--                 returns 0 -- what this core's empty window answers
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
-- R887: PL_PRESS="<s>:test,<s>:svc,..." -- the test switch (1 s) or the
-- service button (0.3 s) pressed at those times (Manx TT leaves its motion-
-- slider check only through the test menu, as MAME's notes say)
local PRESS = {}
for t_, k_ in string.gmatch(os.getenv("PL_PRESS") or "", "([%d%.]+):(%a+)") do
  PRESS[#PRESS + 1] = {tonumber(t_), k_, (k_ == "test") and 1.0 or 0.3}
end

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
-- R887: the other 2A games' controls, found by bit (their names differ: Punch,
-- Hold, Machine Gun, Shift Up ...). A field is taken only if it is not unused.
local function fmask(p, mk)
  if not ports[p] then return nil end
  for _, f in pairs(ports[p].fields) do
    if f.mask == mk and not f.name:find("Unused") and not f.name:find("Unknown") then return f end
  end
  return nil
end
F.d1, F.d2, F.d3 = fmask(":IN1", 0x01), fmask(":IN1", 0x02), fmask(":IN1", 0x04)
F.s40 = fmask(":IN0", 0x40)                          -- Sky Target / bikes: start on IN0 bit 6
F.v20 = fmask(":IN0", 0x20)                          -- Sky Target: View Change
F.i10, F.i20 = fmask(":IN1", 0x10), fmask(":IN1", 0x20)   -- gun / missile, shift up / down
F.sx, F.sy = first(":STICKX"), first(":STICKY")
F.thr, F.bank = first(":THROTTLE"), first(":BANK")
if GAME == "sky" or GAME == "bike" or GAME == "chase" or GAME == "orev" then F.start = F.s40 end
if log then
  for k, v in pairs(F) do log:write(string.format("FIELD %s %s\n", k, v and "yes" or "no")) end
  log:flush()
end
local seed = 12345
local function rnd(n) seed = (seed * 1103515245 + 12345) & 0x7fffffff; return (seed >> 8) % n end
-- R887: PL_PATCH="<hex offset>=<hex word>,..." writes words into the i960
-- program region before the boot runs (an MRA's <patch> bytes, as MAME would
-- see them); PL_WATCH="<hex addr>,..." logs those words once a second ("M")
if os.getenv("PL_PATCH") then
  local reg = m.memory.regions[":maincpu"]
  for o_, w_ in string.gmatch(os.getenv("PL_PATCH"), "(%x+)=(%x+)") do
    local o, w = tonumber(o_, 16), tonumber(w_, 16)
    if log then log:write(string.format("PATCH %06x %08x -> %08x\n", o, reg:read_u32(o), w)) end
    reg:write_u32(o, w)
  end
end
local WATCH = {}
for a_ in string.gmatch(os.getenv("PL_WATCH") or "", "(%x+)") do WATCH[#WATCH + 1] = tonumber(a_, 16) end
local step_t, next_snap = -1, 0
if os.getenv("PL_TAP") then
  local tl = assert(io.open(os.getenv("PL_TAP"), "w"))
  local sp = cpu.spaces["program"]
  local seen = {}
  local function ip() return cpu.state["ip"].value end
  PL_TW = sp:install_write_tap(0x01d80000, 0x01d9ffff, "pl_pw", function(o, d, mk)
    tl:write(string.format("%.6f W %08x %08x %08x ip %08x\n", emu.time(), o, d, mk, ip())); return d
  end)
  local ZERO = os.getenv("PL_ZERO") == "1"   -- R887: the 315-5881's decrypt reads answer 0 (this core)
  PL_TR = sp:install_read_tap(0x01d80000, 0x01d9ffff, "pl_pr", function(o, d, mk)
    if ZERO and o == 0x01d9000c then d = d & ~mk end
    tl:write(string.format("%.6f R %08x %08x %08x ip %08x\n", emu.time(), o, d, mk, ip())); return d
  end)
  PL_TD = sp:install_read_tap(0x02000000, 0x03ffffff, "pl_dr", function(o, d, mk)
    local b = (o - 0x02000000) >> 16
    if not seen[b] then seen[b] = true; tl:write(string.format("%.6f D %08x ip %08x\n", emu.time(), o, ip())) end
    return d
  end)
  PL_TE = sp:install_read_tap(0x06000000, 0x06ffffff, "pl_er", function(o, d, mk)
    local b = 0x200 + ((o - 0x06000000) >> 16)          -- main_data + 16 MB (MAME's 0x06000000 window)
    if not seen[b] then seen[b] = true; tl:write(string.format("%.6f E %08x ip %08x\n", emu.time(), o, ip())) end
    return d
  end)
  local nu, nc = 0, 0
  PL_TU = sp:install_read_tap(0x01c80000, 0x01c80003, "pl_ur", function(o, d, mk)
    -- the i8251: data (offset 0) reads and the comm board's flag (R887: does a
    -- game wait on an answer the 2A core's sound side never sends?)
    if (o & 3) == 0 and (mk & 0xff) ~= 0 and nu < 200 then
      nu = nu + 1; tl:write(string.format("%.6f U %08x %08x ip %08x\n", emu.time(), o, d, ip()))
    end
    return d
  end)
  PL_TC = sp:install_read_tap(0x01a00000, 0x01a1ffff, "pl_cr", function(o, d, mk)
    if nc < 200 then nc = nc + 1; tl:write(string.format("%.6f C %08x %08x ip %08x\n", emu.time(), o, d, ip())) end
    return d
  end)
  PL_TL = tl
end
local function pulse(t, at, len) return t >= at and t < at + len end

-- R903: MANX TT RIDDEN AT THE OTHER RIDERS (PL_GAME=chase). The game's own
-- state, found in MAME 0.289's work RAM (manxtt, verified by the dumps of a
-- race, not by the program's symbols -- there are none):
--   0x5bba30 + 52 k  rider k (0 the player, 1-7 the others): x +0, y +4,
--                    z +8, heading +0x10 (radians; forward = (-sin h, cos h)
--                    in x / z), speed +0x1c
--   0x53e3c8 + 28 n  the course line near the riders (x +0, y +4, z +8,
--                    ~20 apart, ~600 valid), a window the game streams
--   0x5bbd20         riders down: the other riders' crash state (0x2edc0) adds
--                    one, its end clears it -- the path R903 was after
-- An autopilot steers along the course line, and at the nearest rider ahead
-- whenever one is within reach; throttle flat out; and brakes hard when a
-- rider is close behind in line, so it runs into us. PL_BANKSIGN (+1, the
-- default, verified / -1) is which way BANK turns the bike. PL_CHASELOG=<file>
-- logs, every frame: time, our speed and its drop, the nearest rider, the
-- target rider and its speed, the steering error and BANK, and 0x5bbd20.
-- (Seeded as `bike`'s coins and starts; menus ridden upright and unbraked.)
local CH_SIGN = tonumber(os.getenv("PL_BANKSIGN") or "1")
local CH_LOG = os.getenv("PL_CHASELOG") and assert(io.open(os.getenv("PL_CHASELOG"), "w"))
local CH_SP = cpu.spaces["program"]
local CH_V = nil
local function rf(a) return string.unpack("<f", string.pack("<I4", CH_SP:read_u32(a))) end
local function wrap(a) return (a + math.pi) % (2 * math.pi) - math.pi end
function chase(t)
  local px, pz, h, v = rf(0x5bba30), rf(0x5bba38), rf(0x5bba40), rf(0x5bba4c)
  local lc = 0
  for _, c in ipairs(COINS) do if t >= c then lc = c end end
  if t - lc < 20 or (px == 0 and pz == 0) then
    -- the menus: upright, no brake (brake on Start picks TT MODE, no riders)
    set(F.thr, 0x00); set(F.brk, 0x00); set(F.bank, 0x80); set(F.i10, 0); set(F.i20, 0)
    return
  end
  local fx, fz = -math.sin(h), math.cos(h)
  -- the course line: the nearest point, then one ~300 ahead
  local best, bn = 1e30, -1
  for n = 0, 1200 do
    local a = 0x53e3c8 + 28 * n
    local x, z = rf(a), rf(a + 8)
    if x ~= x or math.abs(x) < 1 or math.abs(x) > 30000 then break end
    local d = (x - px) ^ 2 + (z - pz) ^ 2
    if d < best then best, bn = d, n end
  end
  local tx, tz = px + fx * 300, pz + fz * 300
  if bn >= 0 then
    local k = bn + 15
    local a = 0x53e3c8 + 28 * k
    local x = rf(a)
    if x == x and math.abs(x) >= 1 and math.abs(x) <= 30000 then tx, tz = x, rf(a + 8) end
  end
  -- the nearest rider ahead, within 1,500 and inside a 60-degree cone
  local rk, rd = -1, 1e30
  for k = 1, 7 do
    local b = 0x5bba30 + 52 * k
    local dx, dz = rf(b) - px, rf(b + 8) - pz
    local fd = dx * fx + dz * fz
    local ld = math.abs(dx * fz - dz * fx)
    local d = math.sqrt(dx * dx + dz * dz)
    if fd > 0 and fd < 1500 and ld < fd * 0.6 + 40 and d < rd then rk, rd = k, d end
  end
  if rk > 0 then
    -- the rider's centre once close; further out a little to one side of it,
    -- in turn, so the hit comes from behind or from the side
    local b = 0x5bba30 + 52 * rk
    local o = (rd > 200) and 12 * math.sin(t * 0.8) or 0
    tx, tz = rf(b) + o * fz, rf(b + 8) - o * fx
  end
  local err = wrap(-math.atan(tx - px, tz - pz) - h)
  local s = math.max(-0x70, math.min(0x70, math.floor(err * 0x140 * CH_SIGN)))
  -- the brake check: a rider close behind and in line, and we brake hard, so
  -- it runs into us at the difference of the two speeds
  local bc = false
  for k = 1, 7 do
    local b = 0x5bba30 + 52 * k
    local dx, dz = rf(b) - px, rf(b + 8) - pz
    local fd = dx * fx + dz * fz
    local ld = math.abs(dx * fz - dz * fx)
    if fd < 0 and fd > -160 and ld < 25 and rf(b + 0x1c) > v - 5 then bc = true end
  end
  if bc then
    set(F.thr, 0x00); set(F.brk, 0xff); set(F.bank, 0x80)
  else
    set(F.thr, 0xff); set(F.brk, 0x00); set(F.bank, 0x80 + s)
  end
  set(F.i10, ((t % 3) < 0.2) and 1 or 0); set(F.i20, 0)
  if CH_LOG then
    local dv = CH_V and (CH_V - v) or 0
    -- the nearest rider in any direction
    local nd = 1e30
    for k = 1, 7 do
      local b = 0x5bba30 + 52 * k
      local d = math.sqrt((rf(b) - px) ^ 2 + (rf(b + 8) - pz) ^ 2)
      if d < nd then nd = d end
    end
    local tv = (rk > 0) and rf(0x5bba30 + 52 * rk + 0x1c) or 0
    CH_LOG:write(string.format("%.4f v %.2f dv %.2f near %.1f tgt %d tv %.2f err %.3f bank %d c %d\n",
      t, v, dv, nd, rk, tv, err, 0x80 + s, CH_SP:read_u32(0x5bbd20)))
  end
  CH_V = v
end
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
    elseif GAME == "orev" then
      -- R928: Over Rev -- MAME's ACCEL / BRAKE are PORT_REVERSE; the value set
      -- here is the field's (0xff = floored), the port reads it inverted
      set(F.acc, ((t % 20) < 18) and 0xff or 0x00)
      set(F.brk, ((t % 20) >= 18.5) and 0xff or 0x00)
      set(F.str, 0x80 + math.floor(0x60 * math.sin(t * 0.7)))
      set(F.i10, ((t % 7) < 0.2) and 1 or 0)
      set(F.i20, ((t % 23) < 0.2) and 1 or 0)
      set(F.d1, ((t % 13) < 0.2) and 1 or 0)
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
    elseif GAME == "dig" then
      -- R887: a digital stick and up to three buttons (Hanguk Pro Yagu,
      -- Dynamite Cop, Pilot Kids, Dead or Alive): each button pressed on its
      -- own rhythm, the stick on a pseudo-random walk
      set(F.d1, ((t * 3) % 2 < 1) and 1 or 0)
      set(F.d2, ((t * 2.3) % 3 < 1) and 1 or 0)
      set(F.d3, ((t * 1.7) % 4 < 1) and 1 or 0)
      local s = math.floor(t * 4)
      if s ~= step_t then
        step_t = s
        local d = rnd(9)
        set(F.up, (d == 1 or d == 5 or d == 6) and 1 or 0); set(F.dn, (d == 2 or d == 7 or d == 8) and 1 or 0)
        set(F.lt, (d == 3 or d == 5 or d == 7) and 1 or 0); set(F.rt, (d == 4 or d == 6 or d == 8) and 1 or 0)
      end
    elseif GAME == "sky" then
      -- Sky Target: the stick swept, machine gun held, a missile every 3 s,
      -- the view changed every 15 s
      set(F.sx, 0x80 + math.floor(0x70 * math.sin(t * 0.8)))
      set(F.sy, 0x80 + math.floor(0x60 * math.sin(t * 1.1)))
      set(F.i10, ((t % 2) < 1.6) and 1 or 0)
      set(F.i20, ((t % 3) < 0.2) and 1 or 0)
      set(F.v20, ((t % 15) < 0.2) and 1 or 0)
    elseif GAME == "bike" then
      -- Manx TT / Motor Raid: throttle held, the bike leaned side to side,
      -- brake now and then, shift up / down (Motor Raid: punch / kick)
      set(F.thr, ((t % 20) < 17) and 0xff or 0x00)
      set(F.brk, ((t % 20) >= 18) and 0xff or 0x00)
      set(F.bank, 0x80 + math.floor(0x70 * math.sin(t * 0.6)))
      set(F.i10, ((t % 5) < 0.2) and 1 or 0)
      set(F.i20, ((t % 7) < 0.2) and 1 or 0)
    elseif GAME == "chase" then
      chase(t)
    end
  end
  if #PRESS > 0 then                            -- R887: scripted test / service presses
    local te, sv = 0, 0
    for _, p in ipairs(PRESS) do
      if pulse(t, p[1], p[3]) then if p[2] == "test" then te = 1 else sv = 1 end end
    end
    set(F.test, te); set(F.svc, sv)
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
  if PL_TL and #WATCH > 0 and math.floor(t) ~= math.floor(t - 1 / 60) then
    local sp_ = cpu.spaces["program"]
    local o_ = {}
    for _, a in ipairs(WATCH) do o_[#o_ + 1] = string.format("%08x=%08x", a, sp_:read_u32(a)) end
    PL_TL:write(string.format("%.2f M %s\n", t, table.concat(o_, " ")))
  end
  if log and math.floor(t) ~= math.floor(t - 1 / 60) then
    log:write(string.format("%.2f frame %d ip %08x\n", t, scr:frame_number(), cpu.state["ip"].value)); log:flush()
  end
  if t >= T_END then
    if log then log:close() end
    if PL_TL then PL_TL:close(); PL_TL = nil end
    m:exit()
  end
end)
