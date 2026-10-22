-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- R930: OVER REV (overrev, MAME 0.289) INTO ROUND 1 OF THE CHALLENGE CUP AND
-- PAST ITS SPEED CONTEST. Coin at 40 s, start, the accelerator tapped through
-- Mode Select (Challenge Cup), Car Select and Gear Select (AT), then held with
-- the wheel straight: the car scrapes the walls but gets round, past the
-- container cranes and the SPEED CONTEST at ~34 s of race time (~103 s of
-- session) -- the point where the 2C core's i960 stopped on cvtilr (R930).
--
-- MAME's PEDALS: a Lua set_value on an analog field is the PORT value, raw --
-- PORT_REVERSE is not applied to it -- so 0x00 is the pedal floored and 0xff
-- released (the invert mode the game expects). (mame_m2_2a_play.lua's 'orev'
-- mode has them the other way round: its accelerator is pressed 2 s in 20.)
--
--   OR_SEQ="t:ctl=val;..."  replaces the timeline (ctl: coin start acc brk str
--                           up dn v1; acc / brk / str are port values); a
--                           wrapper may set the global OR_SEQ_DEFAULT (R933)
--   OR_SNAP="t0,t1,dt"      snapshots   OR_TEND=<s> (default 150)
--   OR_TAPLOG=<file>        render mode reads / writes (0x10000000), the
--                           flips (0x803008), videoctl reads, copro status
--                           (0x980014) and polygon count (0x10400000) reads:
--                           an F line per video frame, a line per mode access
-- Everything written is ROM-derived and stays outside the repository.
local m = manager.machine
local ports = m.ioport.ports
local scr = m.screens[":screen"]
local cpu = m.devices[":maincpu"]
local function first(p) return ports[p] and select(2, next(ports[p].fields)) end
local function fmask(p, mk)
  for _, f in pairs(ports[p].fields) do if f.mask == mk and not f.name:find("Unused") then return f end end
end
local F = { coin = fmask(":IN0", 0x01), start = fmask(":IN0", 0x40), acc = first(":ACCEL"), brk = first(":BRAKE"),
  str = first(":STEER"), up = fmask(":IN1", 0x10), dn = fmask(":IN1", 0x20), v1 = fmask(":IN1", 0x01) }
local SEQ = os.getenv("OR_SEQ") or OR_SEQ_DEFAULT or ("1:brk=255;40:coin=1;40.2:coin=0;40.6:coin=1;40.8:coin=0;43.5:start=1;43.7:start=0;"
  .. "47:acc=255;47.3:acc=0;51:acc=255;51.3:acc=0;55:str=60;55.5:str=128;56:acc=255;56.3:acc=0")
local EV = {}
for t_, c_, v_ in string.gmatch(SEQ, "([%d%.]+):(%a+%d?)=(%d+)") do EV[#EV + 1] = {tonumber(t_), c_, tonumber(v_)} end
table.sort(EV, function(a, b) return a[1] < b[1] end)
local s0, s1, sd = string.match(os.getenv("OR_SNAP") or "", "([%d%.]+),([%d%.]+),([%d%.]+)")
s0, s1, sd = tonumber(s0), tonumber(s1), tonumber(sd)
local T_END = tonumber(os.getenv("OR_TEND") or "150")
local ei, nsnap = 1, s0
local cur = { str = 0x80, acc = 0, brk = 0 }

if os.getenv("OR_TAPLOG") then
  local sp = cpu.spaces["program"]
  local L = assert(io.open(os.getenv("OR_TAPLOG"), "w"))
  local function ip() return cpu.state["ip"].value end
  local fl, vr, pc, cs, lastfl = 0, 0, 0, 0, 0
  OR_T1 = sp:install_write_tap(0x10000000, 0x101fffff, "or_rmw", function(o, d, mk)
    L:write(string.format("%.6f RMW %08x %08x %08x ip %08x\n", emu.time(), o, d, mk, ip())); return d end)
  OR_T2 = sp:install_read_tap(0x10000000, 0x101fffff, "or_rmr", function(o, d, mk)
    L:write(string.format("%.6f RMR %08x %08x %08x ip %08x\n", emu.time(), o, d, mk, ip())); return d end)
  OR_T3 = sp:install_write_tap(0x00803008, 0x0080300b, "or_flip", function(o, d, mk) fl = fl + 1; lastfl = d; return d end)
  OR_T4 = sp:install_read_tap(0x0098000c, 0x0098000f, "or_vc", function(o, d, mk) vr = vr + 1; return d end)
  OR_T5 = sp:install_read_tap(0x10400000, 0x105fffff, "or_pc", function(o, d, mk) pc = pc + 1; return d end)
  OR_T6 = sp:install_read_tap(0x00980014, 0x00980017, "or_cs", function(o, d, mk) cs = cs + 1; return d end)
  OR_T7 = sp:install_write_tap(0x0098000c, 0x0098000f, "or_vcw", function(o, d, mk)
    L:write(string.format("%.6f VCW %08x %08x ip %08x\n", emu.time(), d, mk, ip())); return d end)
  OR_FT = emu.add_machine_frame_notifier(function()
    L:write(string.format("F %d %.4f fl %d vr %d pc %d cs %d d %05x ip %08x\n", scr:frame_number(), emu.time(),
      fl, vr, pc, cs, lastfl & 0xfffff, ip()))
    fl, vr, pc, cs = 0, 0, 0, 0
  end)
  OR_TL = L
end

OR_FN = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  while ei <= #EV and EV[ei][1] <= t do local e = EV[ei]; cur[e[2]] = e[3]; ei = ei + 1 end
  for k, f in pairs(F) do if f then f:set_value(cur[k] or 0) end end
  if nsnap and t >= nsnap and t <= s1 then scr:snapshot(string.format("o_%06.2f.png", t)); nsnap = nsnap + sd end
  if t >= T_END then if OR_TL then OR_TL:close(); OR_TL = nil end; m:exit() end
end)
