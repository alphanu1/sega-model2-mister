-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- ZERO GUNNER AND ITS 315-5881 (study R862): every i960 write to the RAM at
-- 0x01d80000 ("M"), every read of it (the chip's own reads, "m"), every write
-- and read of the chip at 0x01d90000 ("W" / "R"), a snapshot each 10 s; coins
-- and starts at 40-44 s and 120-123 s, Button 1 pulsed from 45 s.
-- ZG_ZERO=1 makes every decrypt read return 0 (what the core does without the
-- chip). sim/prot/zg_5881_replay.cpp replays the log through m2_5881_ref.h.
--
--   ZG_OUT=<dir> ZG_TEND=<s> M2_MAME_OUT=<dir> \
--     tools/m2b-mame.sh zeroguna -autoboot_script sim/prot/mame_m2_zg_5881.lua
--
-- Everything written is ROM-derived and stays outside the repository.
local out = os.getenv("ZG_OUT") or "."
local TEND = tonumber(os.getenv("ZG_TEND") or "200")
local ZERO = os.getenv("ZG_ZERO") == "1"
local m = manager.machine
local cpu = m.devices[":maincpu"]
local sp = cpu.spaces["program"]
local ports = m.ioport.ports
local log = assert(io.open(out .. "/zg.txt", "w"))
local nw, nr = 0, 0
ZG_W1 = sp:install_write_tap(0x01d80000, 0x01d8ffff, "zgram_w", function(o, d, mk)
  nw = nw + 1
  log:write(string.format("%.6f M %05x %08x %08x\n", emu.time(), o - 0x01d80000, d, mk))
  return d
end)
ZG_R1 = sp:install_read_tap(0x01d80000, 0x01d8ffff, "zgram_r", function(o, d, mk)
  nr = nr + 1
  log:write(string.format("%.6f m %05x %08x %08x\n", emu.time(), o - 0x01d80000, d, mk))
  return d
end)
ZG_R2 = sp:install_read_tap(0x01d90000, 0x01d9ffff, "zgdev_r", function(o, d, mk)
  if ZERO and (o & 0xffff) == 0x0c then d = d & ~mk end
  log:write(string.format("%.6f R %05x %08x %08x\n", emu.time(), o - 0x01d90000, d, mk))
  return d
end)
ZG_W2 = sp:install_write_tap(0x01d90000, 0x01d9ffff, "zgdev_w", function(o, d, mk)
  log:write(string.format("%.6f W %05x %08x %08x\n", emu.time(), o - 0x01d90000, d, mk))
  return d
end)
local function field(p, pat)
  local P = ports[p]
  if not P then return nil end
  for n, f in pairs(P.fields) do if n:find(pat, 1, true) then return f end end
end
local coin, start = field(":IN0", "Coin 1"), field(":IN0", "1 Player Start")
local b1 = field(":IN1", "P1 Button 1") or field(":IN1", "Button 1")
local held, done = {}, false
local acts = { {40, coin}, {41, coin}, {43, start}, {44, start}, {120, coin}, {121, coin}, {123, start} }
local ai, nsnap = 1, 10
ZG_F = emu.add_machine_frame_notifier(function()
  if done then return end
  local t = emu.time()
  for i = #held, 1, -1 do if t >= held[i].t then held[i].f:set_value(0); table.remove(held, i) end end
  while ai <= #acts and t >= acts[ai][1] do
    local f = acts[ai][2]
    if f then f:set_value(1); held[#held + 1] = { t = t + 0.2, f = f } end
    ai = ai + 1
  end
  if b1 then b1:set_value((t >= 45 and (math.floor(t * 4) % 2 == 0)) and 1 or 0) end
  if t >= nsnap then
    m.video:snapshot(); nsnap = nsnap + 10
  end
  if t >= TEND then
    done = true
    log:write(string.format("RAM writes %d reads %d\n", nw, nr))
    log:close()
    m:exit()
  end
end)
