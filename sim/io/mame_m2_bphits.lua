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
--   BP_FILE=<"pc name" lines> BP_OUT=<file> BP_TEND=<s> BP_COIN=<s,s,...>
local m = manager.machine
local ports = m.ioport.ports
local scr = m.screens[":screen"]
local T_END = tonumber(os.getenv("BP_TEND") or "300")
local COINS = {}
for v in string.gmatch(os.getenv("BP_COIN") or "", "[^,]+") do COINS[#COINS + 1] = tonumber(v) end
local out = assert(io.open(assert(os.getenv("BP_OUT")), "w"))
local names, n = {}, 0
for ln in io.lines(assert(os.getenv("BP_FILE"))) do
  local pc, nm = ln:match("^(%x+)%s+(%S+)")
  if pc then
    names[tonumber(pc, 16)] = nm
    m.debugger:command(string.format('bpset %s,1,{printf "BPHIT %%08x",curpc; g}', pc))
    n = n + 1
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
  if playing then
    if F_ACC then set(":ACCEL", F_ACC, 255) end
    if F_STR then set(":STEER", F_STR, 0x80 + math.floor(40 * math.sin(t * 0.7))) end
    if F_MG then set(":IN1", F_MG, ((t * 2) % 2 < 1) and 1 or 0) end
    if F_CAN then pulse(t, math.floor(t / 3) * 3, ":IN1", F_CAN, 0.25) end
  end
  local log = m.debugger.consolelog
  local nl = #log
  for i = last + 1, nl do
    local s = log[i]
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
    m:exit()
  end
end)
