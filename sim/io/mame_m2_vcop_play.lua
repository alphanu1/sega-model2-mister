-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- VIRTUA COP, PLAYED BY SCRIPT, FOR WHO IS IN PLAY (R849). Coins, starts,
-- triggers and the Test button by schedule, the guns swept at the I/O board
-- (a read tap on 0x8100), and three records: every i960 write to the mode
-- word 0x5016d4 and the player words 0x50ee30 / 0x50ee34 plus the Test
-- presses (PL_WLOG), those three bytes every 0.5 s (PL_STATE), and optional
-- work-RAM dumps (PL_DUMP) for finding such bytes. PL_WLOG / PL_STATE are
-- tb_m2_vcop_state's inputs (make test_m2_vcop_state, VCOPSTATE=<dir> holding
-- <name>_wlog.txt / <name>_state.txt). R849 lists the five scenarios.
-- Run: mame vcopa -autoboot_script <this> -snapview native -snapsize 496x384
--
-- Virtua Cop scripted play with work-RAM dumps (R849 state hunt).
-- PL_EV   = "t|port/field|dur;..."  presses (dur s)
-- PL_FIRE = "p:t0:t1:period;..."    player p's trigger pulsed (0.05 s) every period in [t0,t1)
-- PL_AIM  = "p:t0:t1;..."           player p's gun swept across the screen in [t0,t1) (else centre)
-- PL_DUMP = file; work RAM 0x500000..+PL_LEN dumped every PL_EVERY s (binary, prefixed by a
--           12-byte header: "VCDP", time*1000 u32, frame u32)
-- PL_SNAP every PL_SNAPEVERY s; PL_TEND end.
local m = manager.machine
local cpu = m.devices[":maincpu"]
local sp = cpu.spaces["program"]
local scr = m.screens[":screen"]
local function fld(port, name)
  for n, f in pairs(m.ioport.ports[port].fields) do if n == name then return f end end
  error("no field " .. port .. " " .. name)
end
local ev = {}
for t, pn, dur in string.gmatch(os.getenv("PL_EV") or "", "([%d%.]+)|([^|;]+)|([%d%.]+)") do
  local port, name = pn:match("([^/]+)/(.+)")
  ev[#ev + 1] = { t = tonumber(t), d = tonumber(dur), f = fld(port, name), on = false }
end
if os.getenv("PL_AUTORELOAD") then fld(":ioboard:dsw1", "Reloading").user_value = 0 end
local trig = { fld(":IN1", "P1 Trigger"), fld(":IN1", "P2 Trigger") }
local fire = {}
for p, t0, t1, per in string.gmatch(os.getenv("PL_FIRE") or "", "(%d):([%d%.]+):([%d%.]+):([%d%.]+)") do
  fire[#fire + 1] = { p = tonumber(p), t0 = tonumber(t0), t1 = tonumber(t1), per = tonumber(per) }
end
local aim = {}
for p, t0, t1 in string.gmatch(os.getenv("PL_AIM") or "", "(%d):([%d%.]+):([%d%.]+)") do
  aim[#aim + 1] = { p = tonumber(p), t0 = tonumber(t0), t1 = tonumber(t1) }
end
-- gun coordinates at the I/O board (P1Y, P1X, P2Y, P2X, off)
local g = { 0x0e6, 0x17c, 0x0e8, 0x179, 0 }
local iocpu = m.devices[":ioboard:iocpu"]
PLG = iocpu.spaces["program"]:install_read_tap(0x8100, 0x810f, "gun", function(off, data, mask)
  local o = off & 0xf
  if data == 0x80 and o ~= 8 then return data end      -- before the FPGA upload: as the board
  if o == 8 then return 0xfc | g[5] end
  if o > 8 then return data end
  local v = g[(o >> 1) + 1]
  if (o & 1) == 0 then return v & 0xff else return (v >> 8) & 0xff end
end)
-- PL_WLOG: every write to the mode byte and the two player-state words
local wlog = os.getenv("PL_WLOG") and assert(io.open(os.getenv("PL_WLOG"), "w"))
if wlog then
  local function wt(name)
    return function(off, data, mask)
      wlog:write(string.format("%.3f %s %08x data %08x mask %08x pc %08x\n", emu.time(), name, off, data, mask, cpu.state["ip"].value))
      return data
    end
  end
  PLW1 = sp:install_write_tap(0x5016d4, 0x5016d7, "mode", wt("mode"))
  PLW2 = sp:install_write_tap(0x50ee30, 0x50ee37, "pst", wt("pst"))
end
if os.getenv("PL_NOENEMY") then fld(":IN2", "No Enemies").user_value = 0 end
local dumpf = os.getenv("PL_DUMP") and assert(io.open(os.getenv("PL_DUMP"), "wb"))
local LEN = tonumber(os.getenv("PL_LEN") or "131072")
local EVERY = tonumber(os.getenv("PL_EVERY") or "1")
local SNAPE = tonumber(os.getenv("PL_SNAPEVERY") or "2")
local T_END = tonumber(os.getenv("PL_TEND") or "300")
local nd, ns, nst = 0, 0, 0
-- PL_STATE: the three bytes every 0.5 s (time mode p1 p2), tb_m2_vcop_state's reference
local statef = os.getenv("PL_STATE") and assert(io.open(os.getenv("PL_STATE"), "w"))
-- PL_REACT: the first time player 1 reaches the continue (state 2), a coin and
-- a start 2 / 3 s later -- a continue taken.
local react = os.getenv("PL_REACT") and { done = false, p = 0 }
local c1, s1 = fld(":IN0", "Coin 1"), fld(":IN0", "1 Player Start")
PLF = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  for _, e in ipairs(ev) do
    if not e.done then
      if t >= e.t and not e.on then e.f:set_value(1); e.on = true
        if wlog and e.f.name == "Service Mode" then wlog:write(string.format("%.3f test 00000000 data 00000001 mask 00000000 pc 00000000\n", t)) end
      elseif t >= e.t + e.d and e.on then e.f:clear_value(); e.done = true
        if wlog and e.f.name == "Service Mode" then wlog:write(string.format("%.3f test 00000000 data 00000000 mask 00000000 pc 00000000\n", t)) end
      end
    end
  end
  if react and not react.done then
    if react.p == 0 and sp:read_u8(0x50ee30) == 2 then react.p = t end
    if react.p > 0 then
      local dt = t - react.p
      if dt >= 2 and dt < 2.2 then c1:set_value(1) else c1:clear_value() end
      if dt >= 3 and dt < 3.2 then s1:set_value(1) else s1:clear_value() end
      if dt > 4 then react.done = true; c1:clear_value(); s1:clear_value() end
    end
  end
  local tp = { false, false }
  for _, f in ipairs(fire) do
    if t >= f.t0 and t < f.t1 and ((t - f.t0) % f.per) < 0.05 then tp[f.p] = true end
  end
  for p = 1, 2 do if tp[p] then trig[p]:set_value(1) else trig[p]:clear_value() end end
  -- sweep: a Lissajous over the inner screen
  local sx, sy = { 0x17c, 0x179 }, { 0x0e6, 0x0e8 }
  for _, a in ipairs(aim) do
    if t >= a.t0 and t < a.t1 then
      local ph = t * (a.p == 1 and 1.3 or 1.7)
      sx[a.p] = math.floor(0x17c + 0xc0 * math.sin(ph))
      sy[a.p] = math.floor(0x0e6 + 0x80 * math.sin(ph * 1.37 + a.p))
    end
  end
  g[1], g[2], g[3], g[4] = sy[1], sx[1], sy[2], sx[2]
  if statef and t >= nst then
    statef:write(string.format("%.3f %02x %02x %02x\n", t, sp:read_u8(0x5016d4), sp:read_u8(0x50ee30), sp:read_u8(0x50ee34)))
    nst = nst + 0.5
  end
  if dumpf and t >= nd then
    dumpf:write("VCDP", string.pack("<I4I4", math.floor(t * 1000), scr:frame_number()))
    dumpf:write(sp:read_range(0x500000, 0x500000 + LEN - 1, 8))
    nd = nd + EVERY
  end
  if t >= ns then scr:snapshot(string.format("p%06.1f.png", t)); ns = ns + SNAPE end
  if t >= T_END then if dumpf then dumpf:close() end; if wlog then wlog:close() end; if statef then statef:close() end; m:exit() end
end)
