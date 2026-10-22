-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- R933: SEGA TOURING CAR CHAMPIONSHIP (stcc, MAME 0.289) THROUGH QUALIFYING
-- AND INTO ROUND 1. mame_m2_orev_race.lua's timeline driver (OR_SEQ / OR_SNAP /
-- OR_TEND / OR_TAPLOG, the same controls: STCC has indy500's ports, as Over
-- Rev does) with STCC's own default timeline, and two more taps:
--
--   ST_TAPLOG=<file>  every i960 access to the comm board (0x01a00000-
--                     0x01a1ffff: share RAM, CN, FG) and every write to the
--                     315-5649 (0x01c00000-0x01c0001f), one line each; the
--                     315-5649's reads counted by register, printed at exit
--   ST_GEO="<trig>,t0,t1,dt"  create the file <trig> every dt s from t0 to t1:
--                     a MAME built with the M2GEO patch (M2GEO_TRIG=<trig>,
--                     M2GEO_OUT=<dir>) dumps the next geometry walk to
--                     <dir>/t<walk> and deletes the file (R932's method)
--
-- STCC's pedals have NO PORT_REVERSE (indy500's ports): a raw set_value of
-- 0xff is the pedal floored, 0x00 released -- the other way round from Over
-- Rev's. The default timeline: coin twice at 30 s, start at 34 s, start again
-- through Select Car / Enter Your Name, then the accelerator floored from
-- 58 s with the wheel straight, a shift up / down and both view buttons on
-- their own rhythm through the race.
-- Everything written is ROM-derived and stays outside the repository.
OR_SEQ_DEFAULT = "30:coin=1;30.2:coin=0;30.6:coin=1;30.8:coin=0;34:start=1;34.2:start=0;"
  .. "40:start=1;40.2:start=0;46:start=1;46.2:start=0;52:start=1;52.2:start=0;58:acc=255;"
  .. "75:v1=1;75.2:v1=0;80:v1=1;80.2:v1=0;90:str=100;90.4:str=128;95:str=156;95.4:str=128;"
  .. "110:up=1;110.2:up=0;112:dn=1;112.2:dn=0;130:brk=255;130.5:brk=0;160:v1=1;160.2:v1=0"

local cpu = manager.machine.devices[":maincpu"]
if os.getenv("ST_TAPLOG") then
  local sp = cpu.spaces["program"]
  local L = assert(io.open(os.getenv("ST_TAPLOG"), "w"))
  local function ip() return cpu.state["ip"].value end
  local ior = {}
  ST_T1 = sp:install_read_tap(0x01a00000, 0x01a1ffff, "st_cr", function(o, d, mk)
    L:write(string.format("%.6f CR %08x %08x %08x ip %08x\n", emu.time(), o, d, mk, ip())); return d end)
  ST_T2 = sp:install_write_tap(0x01a00000, 0x01a1ffff, "st_cw", function(o, d, mk)
    L:write(string.format("%.6f CW %08x %08x %08x ip %08x\n", emu.time(), o, d, mk, ip())); return d end)
  ST_T3 = sp:install_write_tap(0x01c00000, 0x01c0001f, "st_iw", function(o, d, mk)
    L:write(string.format("%.6f IW %08x %08x %08x ip %08x\n", emu.time(), o, d, mk, ip())); return d end)
  ST_T4 = sp:install_read_tap(0x01c00000, 0x01c0001f, "st_ir", function(o, d, mk)
    local k = string.format("%08x/%08x", o, mk); ior[k] = (ior[k] or 0) + 1; return d end)
  ST_N = emu.add_machine_stop_notifier(function()
    for k, v in pairs(ior) do L:write(string.format("IR %s %d\n", k, v)) end
    L:close()
  end)
end

do
  local gt, g0, g1, gd = string.match(os.getenv("ST_GEO") or "", "([^,]+),([%d%.]+),([%d%.]+),([%d%.]+)")
  if gt then
    g0, g1, gd = tonumber(g0), tonumber(g1), tonumber(gd)
    local nx = g0
    ST_GF = emu.add_machine_frame_notifier(function()
      local t = emu.time()
      if t >= nx and t <= g1 then local f = io.open(gt, "w"); if f then f:close() end; nx = nx + gd end
    end)
  end
end

local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
dofile(here .. "mame_m2_orev_race.lua")
