-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- DESERT TANK'S ANALOG CHANNELS, ASKED OF THE GAME (R837).
-- Runs a set headless and plays a timed script of inputs and snapshots, so
-- the service mode's input test and the game itself can say what each I/O
-- board ADC channel is. Besides MAME's own ports (STEER / ACCEL / BRAKE on
-- channels 0-2), it can FORCE any of the eight analog bytes the I/O board's
-- Z80 deposits in the DPRAM (byte n = channel n; 4-7 the secondary bank),
-- by overriding the i960's reads of them -- the only way to drive the
-- channels MAME leaves unconnected (they read 0xFF there).
--
--   DTI_OUT=<dir> DTI_SCRIPT=<file> M2_MAME_OUT=<dir> \
--     tools/m2b-mame.sh desert -autoboot_script sim/io/mame_m2_desert_input.lua
--
-- The script file, one action per line, times in emulated seconds:
--   <t> press <port> <field-pattern> [len]   hold a button len s (0.2); _ = space
--   <t> hold  <port> <field-pattern> <0|1>   set a button and leave it
--   <t> set   <port> <value>                 an analog port's (first) field
--   <t> an    <n> <value|off>                force DPRAM analog byte n
--   <t> snap  <name>                         a snapshot <name>.png
--   <t> dump  <name>                         i960 DPRAM bytes 0-15 to log
--   <t> exit
-- Lines starting with # are comments. dpram.txt counts the i960's DPRAM
-- reads by byte; log.txt records every action. Everything written is
-- ROM-derived and stays outside the repository.

local out   = os.getenv("DTI_OUT") or "."
local sfile = assert(os.getenv("DTI_SCRIPT"), "DTI_SCRIPT not set")
local m     = manager.machine
local cpu   = m.devices[":maincpu"]
local sp    = cpu.spaces["program"]
local scr   = m.screens[":screen"]
local ports = m.ioport.ports
local log   = assert(io.open(out .. "/log.txt", "w"))

local acts = {}
for line in io.lines(sfile) do
  if not line:match("^%s*#") and line:match("%S") then
    local w = {}
    for x in line:gmatch("%S+") do w[#w + 1] = x end
    acts[#acts + 1] = { t = tonumber(w[1]), op = w[2], a = w[3], b = w[4], c = w[5] }
  end
end
table.sort(acts, function(x, y) return x.t < y.t end)

-- byte n of the DPRAM sits at 0x01c00000 + (n >> 1) * 4 + (n & 1) * 2,
-- umask32 0x00ff00ff (model2.cpp's map)
DTI_FORCE = {}
DTI_RD = {}
DTI_TAP = sp:install_read_tap(0x01c00000, 0x01c0001f, "dtian", function(o, d, mk)
  local w = (o - 0x01c00000) >> 2
  for h = 0, 1 do
    local lane = h * 16
    if (mk >> lane) & 0xff ~= 0 then
      local n = w * 2 + h
      DTI_RD[n] = (DTI_RD[n] or 0) + 1
      local v = DTI_FORCE[n]
      if v then d = (d & ~(0xff << lane)) | (v << lane) end
    end
  end
  return d
end)

local function field(p, pat)
  local P = ports[p]
  if not P then return nil end
  for n, f in pairs(P.fields) do
    if pat == nil or n:find((pat:gsub("_", " ")), 1, true) then return f, n end
  end
end

local held = {}   -- presses to release: {t, field}
local ix = 1
DTI_F = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  for i = #held, 1, -1 do
    if t >= held[i].t then held[i].f:set_value(0); table.remove(held, i) end
  end
  while ix <= #acts and t >= acts[ix].t do
    local a = acts[ix]; ix = ix + 1
    log:write(string.format("%.3f f%d %s %s %s %s\n", t, scr:frame_number(), a.op, a.a or "", a.b or "", a.c or ""))
    if a.op == "press" or a.op == "hold" then
      local f, n = field(a.a, a.b)
      if not f then log:write("  no field\n")
      elseif a.op == "press" then
        f:set_value(1); held[#held + 1] = { t = t + (tonumber(a.c) or 0.2), f = f }
      else f:set_value(tonumber(a.c)) end
    elseif a.op == "set" then
      local f = field(a.a)
      if f then f:set_value(tonumber(a.b)) else log:write("  no port\n") end
    elseif a.op == "an" then
      DTI_FORCE[tonumber(a.a)] = (a.b ~= "off") and tonumber(a.b) or nil
    elseif a.op == "snap" then
      scr:snapshot(a.a .. ".png")
    elseif a.op == "dump" then
      local s = {}
      for n = 0, 15 do
        local w = sp:read_u32(0x01c00000 + (n >> 1) * 4)
        s[#s + 1] = string.format("%02x", (w >> ((n & 1) * 16)) & 0xff)
      end
      log:write("  " .. a.a .. " dpram " .. table.concat(s, " ") .. "\n")
    elseif a.op == "exit" then
      local f = assert(io.open(out .. "/dpram.txt", "w"))
      for n = 0, 15 do f:write(string.format("byte %2d reads %d\n", n, DTI_RD[n] or 0)) end
      f:close(); log:close()
      m:exit()
    end
  end
end)
