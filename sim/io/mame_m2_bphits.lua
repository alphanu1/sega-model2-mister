-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- WHICH OF A LIST OF i960 ADDRESSES A GAME EVER EXECUTES (R836): a debugger
-- breakpoint on each, whose action prints the address and resumes; the
-- console is read once a frame and every first hit written with its frame.
-- Cheaper than a trace by orders of magnitude, so it can cover a whole
-- session: attract, coins, start, mission select and play (accelerator held,
-- the wheel swept, machine gun and cannon fired). Run with -debug and a
-- debugscript that says "go".
--
--   BP_FILE=<"pc name [reg ...]" lines> BP_OUT=<file> BP_TEND=<s> BP_COIN=<s,s,...>
--   [BP_VALS=<file>]  R839: a line naming registers also prints them at every
--   hit ("V <pc> <reg> ..." in hex) into BP_VALS
--   [BP_ONCE=1] each breakpoint disables itself at its first hit (R866)
--   [BP_MASH=1] in play, player 1's buttons and stick toggle (R866)
--   [BP_TEST=<s>] the test switch at s, then a walk of the menus (R866)
-- R866: Sega Rally and Zero Gunner run their program from a copy in work RAM
-- (sim/io/mame_m2_ramdump.lua); a ROM address there never hits -- give the
-- copy's addresses too.
local m = manager.machine
local ports = m.ioport.ports
local scr = m.screens[":screen"]
local T_END = tonumber(os.getenv("BP_TEND") or "300")
local COINS = {}
for v in string.gmatch(os.getenv("BP_COIN") or "", "[^,]+") do COINS[#COINS + 1] = tonumber(v) end
local out = assert(io.open(assert(os.getenv("BP_OUT")), "w"))
local names, n = {}, 0
-- R866: BP_ONCE=1 -- each breakpoint disables itself at its first hit, so
-- thousands of candidates (hot loops among them) cost one stop each
local ONCE = (os.getenv("BP_ONCE") or "0") ~= "0"
local MASH = (os.getenv("BP_MASH") or "0") ~= "0"
local T_TEST = tonumber(os.getenv("BP_TEST") or "")
VALS = os.getenv("BP_VALS") and assert(io.open(os.getenv("BP_VALS"), "w"))
for ln in io.lines(assert(os.getenv("BP_FILE"))) do
  local pc, nm, regs = ln:match("^(%x+)%s+(%S+)%s*(.*)$")
  if pc then
    names[tonumber(pc, 16)] = nm
    local extra = ""
    if regs ~= "" then
      local fm, ar = {}, {}
      for r in regs:gmatch("%S+") do fm[#fm + 1] = "%08x"; ar[#ar + 1] = r end
      extra = string.format('; printf "V %%08x %s",curpc,%s', table.concat(fm, " "), table.concat(ar, ","))
    end
    n = n + 1
    local off = ONCE and string.format("; bpdisable %d", n) or ""
    m.debugger:command(string.format('bpset %s,1,{printf "BPHIT %%08x",curpc%s%s; g}', pc, extra, off))
  end
end
out:write(string.format("# %d breakpoints\n", n)); out:flush()
local function set(p, f, v) local x = ports[p] and ports[p].fields[f]; if x then x:set_value(v) end end
local function find(p, pat)
  if not ports[p] then return nil end
  for k in pairs(ports[p].fields) do if k:find(pat) then return k end end
end
local F_MG, F_CAN = find(":IN1", "Machine"), find(":IN1", "Cannon")
local F_ACC = ports[":ACCEL"] and next(ports[":ACCEL"].fields)
local F_STR = ports[":STEER"] and next(ports[":STEER"].fields)
local F_P1X = ports[":P1_X"] and next(ports[":P1_X"].fields)
local F_P1Y = ports[":P1_Y"] and next(ports[":P1_Y"].fields)
local F_T1 = find(":IN1", "P1 Trigger")
local function pulse(t, at, p, f, len)
  len = len or 0.2
  if t >= at and t < at + len then set(p, f, 1)
  elseif t >= at + len and t < at + 2 * len then set(p, f, 0) end
end
local seen, last = {}, 0
BP_F = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  local playing = false
  for _, c in ipairs(COINS) do
    pulse(t, c, ":IN0", "Coin 1")
    for k = 0, 12 do pulse(t, c + 3 + 2 * k, ":IN0", "1 Player Start") end
    if t >= c + 3 then playing = true end
  end
  if playing and F_P1X then
    -- Virtua Cop (R839): sweep the gun, fire, reload off-screen every 4 s
    local x = 0x17c + math.floor(0xd0 * math.sin(t * 0.9))
    local y = 0x0e6 + math.floor(0x90 * math.sin(t * 1.3))
    if (t % 4) >= 3.6 then x, y = 0x083, 0x024 end
    set(":P1_X", F_P1X, x); set(":P1_Y", F_P1Y, y)
    if F_T1 then set(":IN1", F_T1, ((t * 4) % 2 < 1) and 1 or 0) end
  elseif playing then
    if F_ACC then set(":ACCEL", F_ACC, 255) end
    if F_STR then set(":STEER", F_STR, 0x80 + math.floor(40 * math.sin(t * 0.7))) end
    if F_MG then set(":IN1", F_MG, ((t * 2) % 2 < 1) and 1 or 0) end
    if F_CAN then pulse(t, math.floor(t / 3) * 3, ":IN1", F_CAN, 0.25) end
  end
  -- R866: BP_MASH=1 -- in play, every player-1 button and direction on IN1
  -- toggles at its own rate (a fighter / shooter plays itself, badly)
  if playing and MASH and not F_P1X then
    local i = 0
    for k, f in pairs(ports[":IN1"].fields) do
      i = i + 1
      if not k:find("Gear") then f:set_value(((t * (1.3 + 0.7 * i)) % 2 < 0.8) and 1 or 0) end
    end
  end
  -- R866: BP_TEST=<s> -- the test switch at s, then Service 1 every 2 s (the
  -- cursor) and the test switch every 9 s (select / exit): a walk of the menus
  if T_TEST and t >= T_TEST then
    local u = t - T_TEST
    pulse(u, 0, ":IN0", "Service Mode", 0.3)
    pulse(u, math.floor(u / 2) * 2 + 1, ":IN0", "Service 1", 0.2)
    if u > 9 then pulse(u, math.floor(u / 9) * 9, ":IN0", "Service Mode", 0.3) end
  end
  local log = m.debugger.consolelog
  local nl = #log
  for i = last + 1, nl do
    local s = log[i]
    if VALS and s and s:sub(1, 2) == "V " then VALS:write(s, "\n") end
    local pc = s and s:match("BPHIT (%x+)")
    if pc then
      local a = tonumber(pc, 16)
      if not seen[a] then
        seen[a] = 1
        out:write(string.format("HIT %05x %s frame %d t %.3f\n", a, names[a] or "?", scr:frame_number(), t)); out:flush()
      else seen[a] = seen[a] + 1 end
    end
  end
  last = nl
  if t >= T_END then
    for a, c in pairs(seen) do out:write(string.format("COUNT %05x %s %d\n", a, names[a] or "?", c)) end
    out:write(string.format("END frame %d t %.3f\n", scr:frame_number(), t)); out:close()
    if VALS then VALS:close() end
    m:exit()
  end
end)
