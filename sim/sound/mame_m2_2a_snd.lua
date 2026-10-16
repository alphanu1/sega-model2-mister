-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- THE MODEL 2A SOUND BOARD MEASURED (study R856), any 2A game, headless.
-- Rides on MAME with build/mame_patches/p16 (M2SCSP_OUT=<dir>), which logs
-- the SCSP's register traffic, key-ons, DSP program, mix and usage counts.
-- This script plays the game: coins at SND_COIN times (two pulses each),
-- every "Start" field pulsed every 2 s for 60 s after each coin, and every
-- other digital player field (buttons, sticks, pedals as switches) driven by
-- a fixed pseudo-random sequence from the first coin on, so a run repeats.
-- Service, test, tilt and DIP fields are never touched. Analog fields are
-- left at their defaults unless SND_ANALOG=1 (then they walk randomly).
-- Once a second it records the sound 68000's PC (pc.txt: is code run from
-- ROM or RAM) and exits at SND_TEND seconds.
--
--   SND_COIN=<s,...> (default 40,100)   SND_TEND=<s> (default 160)
--   SND_SNAP=<s>  a screenshot every <s> seconds (default 0: none)
--
-- Everything written is ROM-derived and stays outside the repository.
local m = manager.machine
local COINS = {}
for v in string.gmatch(os.getenv("SND_COIN") or "40,100", "[^,]+") do COINS[#COINS + 1] = tonumber(v) end
local T_END = tonumber(os.getenv("SND_TEND") or "160")
local SNAP = tonumber(os.getenv("SND_SNAP") or "0")
local ANALOG = os.getenv("SND_ANALOG") == "1"
local OUT = os.getenv("M2SCSP_OUT") or "."
local pcf = io.open(OUT .. "/pc.txt", "w")
local scr = m.screens[":screen"]
local snd = m.devices[":audiocpu"]

local coin, start, play, ana = {}, {}, {}, {}
for tag, port in pairs(m.ioport.ports) do
  for name, f in pairs(port.fields) do
    local n = name:lower()
    if n:find("service") or n:find("test") or n:find("tilt") or f.type_class == "dipswitch" or f.type_class == "config" then
      -- never
    elseif n:find("coin") then coin[#coin + 1] = f
    elseif n:find("start") then start[#start + 1] = f
    elseif f.is_analog then ana[#ana + 1] = f
    elseif f.type_class ~= "dipswitch" and f.type_class ~= "config" and f.type_class ~= "internal" then play[#play + 1] = f
    end
    print("SNDPLAY all " .. tag .. " / " .. name .. " class " .. tostring(f.type_class) .. " analog " .. tostring(f.is_analog))
  end
end
table.sort(play, function(a, b) return a.name < b.name end)
print(string.format("SNDPLAY coin %d start %d player %d analog %d", #coin, #start, #play, #ana))
for _, f in ipairs(play) do print("SNDPLAY field " .. f.name) end

local seed = 12345
local function rnd(n) seed = (seed * 1103515245 + 12345) & 0x7fffffff; return (seed >> 8) % n end
local step_t, next_pc, next_snap = -1, 0, 0
SND_F = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  local c, s, playing = 0, 0, false
  for _, ct in ipairs(COINS) do
    if (t >= ct and t < ct + 0.2) or (t >= ct + 0.6 and t < ct + 0.8) then c = 1 end
    if t >= ct + 3 and t < ct + 60 and ((t - ct - 3) % 2) < 0.2 then s = 1 end
    if t >= ct + 3 then playing = true end
  end
  for _, f in ipairs(coin) do f:set_value(c) end
  for _, f in ipairs(start) do f:set_value(s) end
  if playing then
    local q = math.floor(t * 5)
    if q ~= step_t then
      step_t = q
      for _, f in ipairs(play) do f:set_value(rnd(3) == 0 and 1 or 0) end
      if ANALOG then for _, f in ipairs(ana) do f:set_value(rnd(256)) end end
    end
  end
  if t >= next_pc then
    pcf:write(string.format("%.1f %06x\n", t, snd.state["PC"].value)); pcf:flush()
    next_pc = next_pc + 1
  end
  if SNAP > 0 and t >= next_snap then
    scr:snapshot(string.format("snd_%05.1f.png", t))
    next_snap = next_snap + SNAP
  end
  if t >= T_END then pcf:close(); m:exit() end
end)
