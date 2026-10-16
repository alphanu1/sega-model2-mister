-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- VIRTUA FIGHTER 2 PLAYED BY SCRIPT, for a long MAME session that another
-- measurement script rides on: attract, coins, start, character select and
-- fights. Player 1's stick and Punch / Kick / Guard follow a fixed
-- pseudo-random sequence (a new state every 0.2 s) from the first coin on,
-- so every run is the same session. Each coin time drops two coins (one
-- credit at MAME's default 2 coins / credit); Start is pressed every 2 s for
-- 120 s after each, which also takes the continue offer.
--
--   VF2_COIN=<s,s,...>  coin times (default 60,180,300,420)
--   VF2_SNAP=<s>        a snapshot every <s> seconds (default 0: none)
--   VF2_LOG=<file>      a line per snapshot: time, frame, i960 IP
--   VF2_TEND=<s>        exit at <s> (default: never; the chained script ends)
--   VF2_CHAIN=<file>    a second autoboot script run in the same session
--                       (e.g. sim/io/mame_m2_bphits.lua with BP_COIN unset,
--                       or sim/tgp/tgp_capture.lua)
--
-- Everything written is ROM-derived and stays outside the repository.
local m = manager.machine
local ports = m.ioport.ports
local scr = m.screens[":screen"]
local cpu = m.devices[":maincpu"]
local COINS = {}
for v in string.gmatch(os.getenv("VF2_COIN") or "60,180,300,420", "[^,]+") do COINS[#COINS + 1] = tonumber(v) end
local SNAP = tonumber(os.getenv("VF2_SNAP") or "0")
local T_END = tonumber(os.getenv("VF2_TEND") or "-1")
local log = os.getenv("VF2_LOG") and assert(io.open(os.getenv("VF2_LOG"), "w"))

local function field(p, name)
  local f = ports[p] and ports[p].fields[name]
  if not f then print("VF2PLAY no field " .. p .. " / " .. name) end
  return f
end
local F = {
  coin = field(":IN0", "Coin 1"), start = field(":IN0", "1 Player Start"),
  p = field(":IN1", "P1 Punch"), k = field(":IN1", "P1 Kick"), g = field(":IN1", "P1 Guard"),
  dn = field(":IN1", "P1 Down"), up = field(":IN1", "P1 Up"),
  rt = field(":IN1", "P1 Right"), lt = field(":IN1", "P1 Left"),
}
local function set(f, v) if f then f:set_value(v) end end

-- A fixed LCG, so the session repeats exactly.
local seed = 12345
local function rnd(n) seed = (seed * 1103515245 + 12345) & 0x7fffffff; return (seed >> 8) % n end
-- stick: none, l, r, u, d, ul, ur, dl, dr (towards the opponent more often)
local STICK = { {}, {"lt"}, {"rt"}, {"up"}, {"dn"}, {"up", "lt"}, {"up", "rt"},
                {"dn", "lt"}, {"dn", "rt"}, {"rt"}, {"lt"} }
local step_t, next_snap = -1, 0
VF2_F = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  local playing, coin, start = false, 0, 0
  for _, c in ipairs(COINS) do
    -- two coins a credit (the attract reads CREDIT 1/2 after one)
    if (t >= c and t < c + 0.2) or (t >= c + 0.6 and t < c + 0.8) then coin = 1 end
    if t >= c + 3 and t < c + 120 and ((t - c - 3) % 2) < 0.2 then start = 1 end
    if t >= c + 3 then playing = true end
  end
  set(F.coin, coin); set(F.start, start)
  if playing then
    local s = math.floor(t * 5)
    if s ~= step_t then
      step_t = s
      for _, k in ipairs({"dn", "up", "rt", "lt"}) do set(F[k], 0) end
      for _, k in ipairs(STICK[rnd(#STICK) + 1]) do set(F[k], 1) end
      local b = rnd(8)
      set(F.p, b & 1); set(F.k, (b >> 1) & 1); set(F.g, ((b >> 2) & 1) & rnd(2))
    end
  end
  if SNAP > 0 and t >= next_snap then
    scr:snapshot(string.format("vf2_%05.1f.png", t))
    if log then
      log:write(string.format("%.2f frame %d ip %08x\n", t, scr:frame_number(), cpu.state["ip"].value)); log:flush()
    end
    next_snap = next_snap + SNAP
  end
  if T_END >= 0 and t >= T_END then
    if log then log:close() end
    m:exit()
  end
end)

if os.getenv("VF2_CHAIN") then dofile(os.getenv("VF2_CHAIN")) end
