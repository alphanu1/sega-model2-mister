-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- DESERT TANK'S GEOMETRIZER TRAFFIC, FRAME BY FRAME (R836).
-- Logs, per emulated frame, everything the i960 does to the geometrizer and
-- the video control registers, and asks the instrumented MAME (patch p14,
-- M2GEO_OUT/M2GEO_TRIG) to dump whole walks at chosen times so they can be
-- replayed through this core's walker, engine, projector and clipper
-- (make geodiff).
--
--   geo.log   one line a frame: "F <frame> <t> fl <n> <last rp> wp <n> <last>
--             push <fifo dwords> bw <direct bufferram stores> <lo>-<hi>
--             ctl <n> <last>"; and every videoctl / render_mode write
--   sNNNN.png a snapshot every DG_SNAP s
--
--   DG_OUT=<dir>       where geo.log goes (default .)
--   DG_TEND=<s>        stop (default 150)
--   DG_COIN=<s>        coin at (default -1: never), start pressed after it
--   DG_SNAP=<s>        snapshot period (default 2; 0 none)
--   DG_DUMPS=a,b,...   times (s) at which the next walk is dumped
--   DG_DEVERY=<s>      also dump every this many seconds (default 0: off)
--   DG_SNAPFROM=<s>    a snapshot every frame from this time, fNNNNN.png
--   M2GEO_OUT, M2GEO_TRIG   MAME's own (p14): where dumps go, the trigger file
--
-- Everything written is ROM-derived and stays outside the repository.

local out    = os.getenv("DG_OUT") or "."
local T_END  = tonumber(os.getenv("DG_TEND") or "150")
local T_COIN = tonumber(os.getenv("DG_COIN") or "-1")
local SNAP   = tonumber(os.getenv("DG_SNAP") or "2")
local EVERY  = tonumber(os.getenv("DG_DEVERY") or "0")
local SFROM  = tonumber(os.getenv("DG_SNAPFROM") or "-1")   -- a snapshot every frame from here, named by frame
local TRIG   = os.getenv("M2GEO_TRIG")
local DUMPS  = {}
for v in string.gmatch(os.getenv("DG_DUMPS") or "", "[^,]+") do DUMPS[#DUMPS + 1] = tonumber(v) end
table.sort(DUMPS)

local m   = manager.machine
local cpu = m.devices[":maincpu"]
local sp  = cpu.spaces["program"]
local scr = m.screens[":screen"]
local ports = m.ioport.ports
local function IP() return cpu.state["ip"] and cpu.state["ip"].value or 0 end

local gf = assert(io.open(out .. "/geo.log", "w"))
DG = { fl = 0, rp = -1, wp = 0, wpv = -1, push = 0, bw = 0, blo = 0xffffffff, bhi = 0, ctl = 0, ctlv = -1 }
DG_T = {}
DG_T[#DG_T + 1] = sp:install_write_tap(0x00803008, 0x0080300b, "dgfl", function(o, d, mk)
  DG.fl = DG.fl + 1; DG.rp = d
end)
DG_T[#DG_T + 1] = sp:install_write_tap(0x00801008, 0x0080100b, "dgwp", function(o, d, mk)
  DG.wp = DG.wp + 1; DG.wpv = d
end)
DG_T[#DG_T + 1] = sp:install_write_tap(0x00800000, 0x00800fff, "dgp0", function(o, d, mk) DG.push = DG.push + 1 end)
DG_T[#DG_T + 1] = sp:install_write_tap(0x00804000, 0x00807fff, "dgp1", function(o, d, mk) DG.push = DG.push + 1 end)
DG_T[#DG_T + 1] = sp:install_write_tap(0x00900000, 0x0097ffff, "dgbw", function(o, d, mk)
  DG.bw = DG.bw + 1
  local a = o & 0x1ffff
  if a < DG.blo then DG.blo = a end
  if a > DG.bhi then DG.bhi = a end
end)
DG_T[#DG_T + 1] = sp:install_write_tap(0x00980008, 0x0098000b, "dgctl", function(o, d, mk)
  DG.ctl = DG.ctl + 1; DG.ctlv = d
end)
DG_T[#DG_T + 1] = sp:install_write_tap(0x0098000c, 0x0098000f, "dgvc", function(o, d, mk)
  gf:write(string.format("V %d %.4f videoctl %08x ip %08x\n", scr:frame_number(), emu.time(), d, IP()))
end)
DG_T[#DG_T + 1] = sp:install_write_tap(0x10000000, 0x101fffff, "dgrm", function(o, d, mk)
  gf:write(string.format("V %d %.4f render_mode %08x @%08x ip %08x\n", scr:frame_number(), emu.time(), d, o, IP()))
end)

local function fld(p, n) return ports[p] and ports[p].fields[n] end
local function set(p, n, v) local x = fld(p, n); if x then x:set_value(v) end end
local function pulse(t, at, p, n, len)
  len = len or 0.2
  if t >= at and t < at + len then set(p, n, 1)
  elseif t >= at + len and t < at + 2 * len then set(p, n, 0) end
end

local di, next_snap, next_every = 1, 0, EVERY
local function trig(t)
  if not TRIG then return end
  local f = io.open(TRIG, "w"); if f then f:write("x"); f:close() end
  gf:write(string.format("D %d %.4f dump requested\n", scr:frame_number(), t))
end

DG_F = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  if T_COIN >= 0 then
    pulse(t, T_COIN, ":IN0", "Coin 1")
    for k = 0, 2 do pulse(t, T_COIN + 3 + 2 * k, ":IN0", "1 Player Start") end
  end
  gf:write(string.format("F %d %.4f fl %d %x wp %d %x push %d bw %d %x-%x ctl %d %x\n",
    scr:frame_number(), t, DG.fl, DG.rp, DG.wp, DG.wpv, DG.push, DG.bw,
    DG.bw > 0 and DG.blo or 0, DG.bhi, DG.ctl, DG.ctlv))
  DG.fl, DG.wp, DG.push, DG.bw, DG.blo, DG.bhi, DG.ctl = 0, 0, 0, 0, 0xffffffff, 0, 0
  while di <= #DUMPS and t >= DUMPS[di] do trig(t); di = di + 1 end
  if EVERY > 0 and t >= next_every then trig(t); next_every = next_every + EVERY end
  if SFROM >= 0 and t >= SFROM then scr:snapshot(string.format("f%05d.png", scr:frame_number())) end
  if SNAP > 0 and t >= next_snap then
    scr:snapshot(string.format("s%04d.png", math.floor(t)))
    next_snap = next_snap + SNAP
  end
  if t >= T_END then gf:close(); m:exit() end
end)
