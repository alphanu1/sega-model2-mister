-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- THE SOUND BOARD, AS MAME HEARS IT, CHIP BY CHIP (R819) -- the capture
-- tb_m2_mpcm_level's part C replays.
--
--   regs.log   every write the sound 68000 makes to the two MultiPCMs (chip 1
--              and 2, offset 0/2/4 = data/slot/register), their bank latches
--              (3 and 4) and the YM3438 (0): "<seconds> <chip> <offset> <byte>"
--   link.log   the bytes the 68000 reads from its UART ("R") -- the main
--              board's commands -- and the main CPU's writes to its own ("W")
--   pcm1.raw, pcm2.raw, ym.raw
--              each chip's OWN output before the board's route gains, from
--              MAME's sound hook: signed 16-bit little-endian, L/R interleaved,
--              at the chip's rate (10 MHz / 224 for the MultiPCMs, 8 MHz / 144
--              for the YM3438)
--
-- Inserts three coins (Daytona's default is three a credit) and presses start
-- at SND_COIN seconds and four more times after, which picks the defaults on
-- the course and transmission screens; nobody drives, so the race times out
-- and the GAME OVER speech plays about 100 s after the coins. SND_C00, if set,
-- forces the byte the 68000 reads at 0xC00001 -- the velocity-curve select
-- MAME leaves unmapped (0x00) and the board answers 0xFF (R819).
--
--   M2_OUT=/tmp/snd SND_TEND=200 SND_COIN=20 mame daytona93 -rompath ... \
--     -video none -sound none -nothrottle -autoboot_script mame_m2_sound_levels.lua
--
-- Run it with every writable MAME directory pointed outside the repository and
-- nvram deleted first (tools/m2b-mame.sh's arrangement): the captures and the
-- nvram are ROM-derived and never enter git. 200 s is ~170 MB of raw audio.
--
-- Globals, or the taps and notifiers are collected and silently stop.

local out    = os.getenv("M2_OUT") or "."
local T_END  = tonumber(os.getenv("SND_TEND") or "200")
local T_COIN = tonumber(os.getenv("SND_COIN") or "20")
local m      = manager.machine
local snd    = m.devices[":m1audio:sndcpu"].spaces["program"]
local main   = m.devices[":maincpu"].spaces["program"]
local reg    = assert(io.open(out .. "/regs.log", "w"))
local lnk    = assert(io.open(out .. "/link.log", "w"))
local function T() return string.format("%.7f", emu.time()) end

SND_T1 = snd:install_write_tap(0xc40000, 0xc40007, "p1", function(o, d) reg:write(T(), " 1 ", o - 0xc40000, " ", d & 0xff, "\n") end)
SND_T2 = snd:install_write_tap(0xc60000, 0xc60007, "p2", function(o, d) reg:write(T(), " 2 ", o - 0xc60000, " ", d & 0xff, "\n") end)
SND_T3 = snd:install_write_tap(0xd00000, 0xd00007, "ym", function(o, d) reg:write(T(), " 0 ", o - 0xd00000, " ", d & 0xff, "\n") end)
SND_T4 = snd:install_write_tap(0xc50000, 0xc50001, "b1", function(o, d) reg:write(T(), " 3 0 ", d & 0xff, "\n") end)
SND_T5 = snd:install_write_tap(0xc70000, 0xc70001, "b2", function(o, d) reg:write(T(), " 4 0 ", d & 0xff, "\n") end)
SND_T6 = snd:install_read_tap(0xc20000, 0xc20001, "rx", function(o, d) lnk:write(T(), " R ", d & 0xff, "\n") end)
SND_T7 = main:install_write_tap(0x01c80000, 0x01c80003, "tx", function(o, d, mk)
  lnk:write(T(), string.format(" W %08x %08x %08x\n", o, d, mk)) end)
if os.getenv("SND_C00") then
  local v = tonumber(os.getenv("SND_C00"))
  SND_T8 = snd:install_read_tap(0xc00000, 0xc00001, "c00", function(o, d) return (d & 0xff00) | v end)
end

local devs = { [":m1audio:pcm1"] = "pcm1", [":m1audio:pcm2"] = "pcm2", [":m1audio:ymsnd"] = "ym" }
local files = {}
for tag, name in pairs(devs) do
  m.sounds[tag].hook = true
  files[tag] = assert(io.open(out .. "/" .. name .. ".raw", "wb"))
end
local function s16(x)
  x = math.floor(x * 32768 + 0.5)
  if x > 32767 then return 32767 elseif x < -32768 then return -32768 end
  return x
end
emu.register_sound_update(function(t)
  for tag, chans in pairs(t) do
    local f = files[tag]
    if f then
      local L, R, buf = chans[1], chans[2], {}
      for i = 1, #L do buf[i] = string.pack("<i2i2", s16(L[i]), s16(R and R[i] or 0)) end
      f:write(table.concat(buf))
    end
  end
end)

local coin  = m.ioport.ports[":IN0"].fields["Coin 1"]
local start = m.ioport.ports[":IN0"].fields["1 Player Start"]
SND_F = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  local function pulse(at, f)
    if t >= at and t < at + 0.2 then f:set_value(1)
    elseif t >= at + 0.2 and t < at + 0.4 then f:set_value(0) end
  end
  pulse(T_COIN, coin); pulse(T_COIN + 1, coin); pulse(T_COIN + 2, coin)
  pulse(T_COIN + 4, start); pulse(T_COIN + 10, start)
  pulse(T_COIN + 14, start); pulse(T_COIN + 18, start)
  if t >= T_END then
    for _, f in pairs(files) do f:close() end
    reg:close(); lnk:close()
    m:exit()
  end
end)
