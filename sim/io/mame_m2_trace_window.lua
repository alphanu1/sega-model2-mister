-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- AN i960 TRACE OVER A WINDOW OF EMULATED TIME (R836), loops NOT collapsed
-- (study R15), for an instruction-coverage check: which instructions a game
-- executes that another never does. Run with -debug and a debugscript that
-- says "go"; the trace goes to TW_FILE (a file or a fifo).
--
--   TW_FILE=<path> TW_ON=<s> TW_OFF=<s> [TW_COIN=<s>]
--
-- Everything written is ROM-derived and stays outside the repository.
local FILE = assert(os.getenv("TW_FILE"))
local T_ON = tonumber(os.getenv("TW_ON") or "17")
local T_OFF = tonumber(os.getenv("TW_OFF") or "22")
local T_COIN = tonumber(os.getenv("TW_COIN") or "-1")
local m = manager.machine
local ports = m.ioport.ports
local MARK = (os.getenv("TW_MARK") or "0") ~= "0"   -- a "F <frame> <time>" line per frame in the trace
local scr = m.screens[":screen"]
local on, off = false, false
local function set(p, n, v) local x = ports[p] and ports[p].fields[n]; if x then x:set_value(v) end end
local F_P1X = ports[":P1_X"] and next(ports[":P1_X"].fields)
local F_P1Y = ports[":P1_Y"] and next(ports[":P1_Y"].fields)
local function pulse(t, at, p, n, len)
  len = len or 0.2
  if t >= at and t < at + len then set(p, n, 1)
  elseif t >= at + len and t < at + 2 * len then set(p, n, 0) end
end
TW_F = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  if T_COIN >= 0 then
    pulse(t, T_COIN, ":IN0", "Coin 1")
    for k = 0, 2 do pulse(t, T_COIN + 3 + 2 * k, ":IN0", "1 Player Start") end
    -- Virtua Cop (R839): after the start, sweep gun 1, fire, reload off-screen
    if F_P1X and t >= T_COIN + 3 then
      local x = 0x17c + math.floor(0xd0 * math.sin(t * 0.9))
      local y = 0x0e6 + math.floor(0x90 * math.sin(t * 1.3))
      if (t % 4) >= 3.6 then x, y = 0x083, 0x024 end
      set(":P1_X", F_P1X, x); set(":P1_Y", F_P1Y, y)
      set(":IN1", "P1 Trigger", ((t * 4) % 2 < 1) and 1 or 0)
    end
  end
  if not on and t >= T_ON then
    m.debugger:command("trace " .. FILE .. ",:maincpu,noloop")
    on = true
  end
  if on and not off and MARK then
    m.debugger:command(string.format('tracelog "F %d %.4f\\n"', scr:frame_number(), t))
  end
  if on and not off and t >= T_OFF then
    m.debugger:command("trace off")
    off = true
    m:exit()
  end
end)
