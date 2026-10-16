-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- R826 addendum: WHAT THE BACKDROP'S SCROLL IS COMPUTED FROM, PER FRAME, AND
-- EVERY TIMING INPUT THE GAME READS WHILE IT DOES (Daytona Revision A only --
-- the addresses are that program's).
--
-- The chain (MAME 0.289 debugger, Revision A):
--   car heading      car+0x58 += step        0x10178-0x101cc  (fixed step)
--   car display yaw  car+0x2a                0x102b4-0x102d8
--   camera yaw Y     0x5014a8 = car+0x2a + car+0xf2 + 0x501834 (shake)
--                                            0x6d88-0x6da0 (chase views)
--                    0x50174c = Y            0x6e4c
--   start of the next game step (line ~386):
--                    0x5fe118 = old 0x5fe11a, 0x5fe11a = 0x50174c + 0x501748<<5
--                                            0x4500-0x4528
--   vblank IRQ (line 384):
--                    0x501308 = (0x5fe11a >> 5) & 0x1ff   0x1df9c-0x1dfb8
--                    tile RAM 0x5002 (hscr2) = 0x501308   0x1ba58
--   car = [0x501220]. car+0x2a, 0x5014a8, hscr2 logged per frame below.
--
-- Timing reads counted per frame (outside the vblank wait loop at 0x138c):
-- the timers 0xf00000-f, the vblank count 0x500000-7, 0x98000c, 0x5010b0-7.
--
--   M2_MAME_OUT=<dir> BG_OUT=<dir> BG_TAG=r100 BG_FIRST=2400 BG_LAST=3400 \
--   BG_STEER="0:128,2560:100" [BG_ACCEL="0:224"] \
--     tools/m2b-mame.sh daytona -autoboot_script sim/video/mame_m2_bgtime.lua
--
-- Coin at 900, start 1000-1400; the race is under the player's control from
-- ~2560 (before that: the rolling start, AUTO DRIVE, a keyframed camera).
-- Output is ROM-derived and never enters the repository.
local out   = os.getenv("BG_OUT") or "/tmp/bg"
local tag   = os.getenv("BG_TAG") or "race"
local first = tonumber(os.getenv("BG_FIRST") or "2400")
local last  = tonumber(os.getenv("BG_LAST") or "3400")
local cpu = manager.machine.devices[":maincpu"]
local sp = cpu.spaces["program"]
local ports = manager.machine.ioport.ports
local function press(p, f, v) local x = ports[p] and ports[p].fields[f]; if x then x:set_value(v) end end
local function pc() return cpu.state["ip"].value end
local function s16(v) v = v & 0xffff; if v >= 0x8000 then v = v - 0x10000 end; return v end
os.execute("mkdir -p " .. out)
local log = io.open(out .. "/" .. tag .. ".txt", "w")
local n, flips, it = 0, 0, 0
local tim = {}
local function on() return n >= first end
local function bump(k) tim[k] = (tim[k] or 0) + 1 end
-- one game step = one write of the old angle to 0x5fe118 (0x4520)
BG_T1 = sp:install_write_tap(0x005fe118, 0x005fe11b, "bgit",
  function(o, d, m) if m == 0xffff0000 then it = it + 1 end; return d end)
BG_T2 = sp:install_write_tap(0x00803008, 0x0080300b, "bgfl",
  function(o, d, m) flips = flips + 1; return d end)
BG_T3 = sp:install_read_tap(0x00f00000, 0x00f0000f, "bgtm",
  function(o, d, m) if on() then bump(string.format("tmr@%x", pc())) end; return d end)
-- the wait loop's own reads (reported PC = the next instruction) are not counted
BG_T4 = sp:install_read_tap(0x00500000, 0x00500007, "bgvc",
  function(o, d, m)
    local p = pc()
    if on() and p ~= 0x1398 and p ~= 0x139c and p ~= 0x13a0 and p ~= 0x13a8 and p ~= 0x1394 and p ~= 0xe44 then
      bump(string.format("vcnt@%x", p)) end
    return d end)
BG_T5 = sp:install_read_tap(0x0098000c, 0x0098000f, "bgvb",
  function(o, d, m) if on() then bump(string.format("vctl@%x", pc())) end; return d end)
BG_T6 = sp:install_read_tap(0x005010b0, 0x005010b7, "bgov",
  function(o, d, m) if on() then bump(string.format("5010b%x@%x", o & 7, pc())) end; return d end)
local function sched(s, d)
  local t = {}
  for f, v in string.gmatch(s or "", "(%d+):(%d+)") do t[#t+1] = {tonumber(f), tonumber(v)} end
  if #t == 0 then t = {{0, d}} end
  return t
end
local ST = sched(os.getenv("BG_STEER"), 128)
local AC = sched(os.getenv("BG_ACCEL"), 224)
local function at(t, k) local v = t[1][2]; for _, e in ipairs(t) do if k >= e[1] then v = e[2] end end; return v end
BG_SUB = emu.add_machine_frame_notifier(function()
  n = n + 1
  if n == 900 then press(":IN0", "Coin 1", 1) end
  if n == 906 then press(":IN0", "Coin 1", 0) end
  if n >= 1000 and n < 1400 then press(":IN0", "1 Player Start", ((n % 60) < 4) and 1 or 0) end
  local st, ac = at(ST, n), at(AC, n)
  if n >= 1000 then press(":ACCEL", "P1 Pedal 1", ac); press(":STEER", "Paddle", st) end
  if on() then
    local car = sp:read_u32(0x501220)
    local ks = {}
    for k, v in pairs(tim) do ks[#ks+1] = k .. "x" .. v end
    table.sort(ks)
    log:write(string.format("%d it=%d fl=%d st=%d ac=%d Y=%d cy=%d cf2=%d sh=%d hscr2=%d tim=%s\n",
      n, it, flips, st, ac, s16(sp:read_u16(0x005014a8)), s16(sp:read_u16(car + 0x2a)),
      s16(sp:read_u16(car + 0xf2)), s16(sp:read_u16(0x00501834)),
      sp:read_u16(0x0100A004) & 0x1ff, table.concat(ks, ",")))
  end
  flips, it, tim = 0, 0, {}
  if n % 60 == 0 then log:flush() end
  if n >= last then log:close(); manager.machine:exit() end
end)
