-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- R826: THE BACKDROP AGAINST THE 3D, FRAME BY FRAME. Logs, per frame, the
-- eight scroll words (tile RAM 0x5000-0x5007) as MAME composites them, and
-- every write to them with the beam line it landed on; the game's list flip
-- (0x803008) with its line; write counts to the maps, the per-line H tables
-- and the row masks. Drives a race: coin at 900, start every second
-- 1000-2400, pedal floored, the wheel at full lock alternately every 150
-- frames (wall scrapes and spins, where the game shakes the picture).
-- Optional snapshots for measuring on-screen motion (sim/video/r826_shift.py).
-- Output is ROM-derived and never enters the repository.
--
--   M2_MAME_OUT=<dir> SL_OUT=<dir> SL_LAST=3600 [SL_SNAP0=f SL_SNAP1=f SL_SNAP2=f SL_SNAPN=n] \
--     tools/m2b-mame.sh daytona -autoboot_script sim/video/mame_m2_scrlog.lua
--
-- Delete <M2_MAME_OUT>/nvram first: a run is deterministic only from the
-- same NVRAM (the first run writes it).
-- Frame n's line = the frame notifier, which MAME runs right after the
-- screen update at the END of vblank (model2: VIDEO_UPDATE_AFTER_VBLANK), so
-- the words logged are the ones that picture used. Write lines are derived
-- from time_until_pos(0) (the Lua screen has no vpos); +-1 line.
local out    = os.getenv("SL_OUT") or "/tmp/sl"
local last   = tonumber(os.getenv("SL_LAST") or "4000")
local snap0  = tonumber(os.getenv("SL_SNAP0") or "0")
local snapn  = tonumber(os.getenv("SL_SNAPN") or "0")
local snap1  = tonumber(os.getenv("SL_SNAP1") or "0")
local snap2  = tonumber(os.getenv("SL_SNAP2") or "0")
local cpu = manager.machine.devices[":maincpu"]
local function pc() return cpu.state["ip"] and cpu.state["ip"].value or 0 end
os.execute("mkdir -p " .. out)
local sp = manager.machine.devices[":maincpu"].spaces["program"]
local scr = manager.machine.screens[":screen"]
local ports = manager.machine.ioport.ports
local fper = scr.frame_period
local lper = scr.scan_period
local function vl()
  local t = scr:time_until_pos(0)
  local e = fper - t
  if e < 0 then e = 0 end
  return math.floor(e / lper + 0.5) % 424
end
local function press(p, f, v)
  local x = ports[p] and ports[p].fields[f]; if x then x:set_value(v) end
end
local log = io.open(out .. "/frames.txt", "w")
local wl  = io.open(out .. "/writes.txt", "w")
local n = 0
local cnt = {}
local function bump(k) cnt[k] = (cnt[k] or 0) + 1 end
-- scroll registers 0x5000..0x5007 (words) = bytes 0xA000..0xA00F
SL_T1 = sp:install_write_tap(0x0100A000, 0x0100A00F, "slreg",
  function(offset, data, mask)
    wl:write(string.format("%d %d %x reg %x %08x %08x\n", n, vl(), pc(), offset, data, mask))
    bump("reg"); return data end)
-- per-line H tables 0x4000..0x47ff words = bytes 0x8000..0x8FFF
SL_T2 = sp:install_write_tap(0x01008000, 0x01008FFF, "sltab",
  function(offset, data, mask)
    bump("tab" .. ((offset - 0x01008000) // 0x400)); return data end)
-- tile maps 0x0000..0x3fff words = bytes 0x0000..0x7fff, 0x1000 words per map
SL_T3 = sp:install_write_tap(0x01000000, 0x01007FFF, "slmap",
  function(offset, data, mask)
    bump("map" .. ((offset - 0x01000000) // 0x2000)); return data end)
-- row-mask tables 0x6000/0x6800 words = 0xC000..0xDFFF
SL_T4 = sp:install_write_tap(0x0100C000, 0x0100DFFF, "slmask",
  function(offset, data, mask) bump("mask"); return data end)
SL_T5 = sp:install_write_tap(0x0098000c, 0x0098000f, "slvc",
  function(offset, data, mask)
    wl:write(string.format("%d %d %d vctl %08x\n", n, vl(), 0, data))
    bump("vctl"); return data end)
SL_T6 = sp:install_write_tap(0x00980008, 0x0098000b, "slgeo",
  function(offset, data, mask)
    wl:write(string.format("%d %d %d geo %08x\n", n, vl(), 0, data))
    bump("geo"); return data end)
SL_T8 = sp:install_write_tap(0x00803008, 0x0080300b, "slflip",
  function(offset, data, mask)
    wl:write(string.format("%d %d %x flip %08x\n", n, vl(), pc(), data))
    bump("flip"); return data end)
SL_T7 = sp:install_write_tap(0x01040000, 0x01060003, "slsync",
  function(offset, data, mask)
    wl:write(string.format("%d %d %d sync %x %08x\n", n, vl(), 0, offset, data))
    bump("sync"); return data end)

SL_SUB = emu.add_machine_frame_notifier(function()
  n = n + 1
  -- coin, start, pedal; steering: hard lock alternating every ~3 s once racing
  if n == 900 then press(":IN0", "Coin 1", 1) end
  if n == 906 then press(":IN0", "Coin 1", 0) end
  if n >= 1000 and (n % 60) < 4 and n < 2400 then press(":IN0", "1 Player Start", 1)
  elseif n >= 1000 and n < 2400 then press(":IN0", "1 Player Start", 0) end
  if n >= 1000 then press(":ACCEL", "P1 Pedal 1", 224) end
  if n >= 1000 then
    local ph = (n // 150) % 4
    local st = ({128, 36, 128, 220})[ph + 1]
    press(":STEER", "Paddle", st)
  end
  local r = {}
  for i = 0, 7 do r[#r+1] = string.format("%04x", sp:read_u16(0x0100A000 + 2*i) & 0xffff) end
  local c = {}
  for k, v in pairs(cnt) do c[#c+1] = k .. "=" .. v end
  table.sort(c)
  log:write(string.format("%d fn=%d vp=%d regs=%s %s\n", n, scr:frame_number(), vl(),
    table.concat(r, ","), table.concat(c, " ")))
  cnt = {}
  if n % 60 == 0 then log:flush(); wl:flush() end
  if snapn > 0 and ((n >= snap0 and n < snap0 + snapn) or (n >= snap1 and n < snap1 + snapn) or (n >= snap2 and n < snap2 + snapn)) then
    scr:snapshot(string.format("f%05d.png", n))
  end
  if n >= last then log:close(); wl:close(); manager.machine:exit() end
end)
