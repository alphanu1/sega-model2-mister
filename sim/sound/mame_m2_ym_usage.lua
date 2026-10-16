-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- WHAT THE SOUND 68000 DOES WITH ITS YM3438, COUNTED (R833) -- the evidence
-- for m2_ym_timers, the timer-only stand-in for jt12.
--
--   ymw.log    every YM write: "<seconds> <offset> <byte> <pc>" (offset 0/2 =
--              address/data part 0, 4/6 = part 1) -- tb_m2_ym_timers replays it
--   link.log   the bytes the 68000 reads from its UART ("<seconds> R <byte>"),
--              as mame_m2_sound_levels.lua's -- tb_m2_sndboard's M2_SND_LINKLOG
--   ymu.txt    the summary: writes per (part, register) with the values seen,
--              key-on writes, reads per (pc, offset, value), and the chip's
--              own output (MAME's ymsnd stream: samples, non-zero, peak)
--
-- Same inputs as mame_m2_sound_levels.lua: coins at SND_COIN, start pressed
-- four times (the defaults), nobody drives, the race times out into GAME OVER.
--
--   M2_OUT=/tmp/x SND_TEND=320 SND_COIN=200 mame daytona -rompath ... \
--     -video none -sound none -nothrottle -autoboot_script mame_m2_ym_usage.lua
--
-- Point every writable MAME directory outside the repository and delete the
-- nvram first (tools/m2b-mame.sh): the logs are ROM-derived, never in git.
-- Globals, or the taps and notifiers are collected and silently stop.

local out    = os.getenv("M2_OUT") or "."
local T_END  = tonumber(os.getenv("SND_TEND") or "320")
local T_COIN = tonumber(os.getenv("SND_COIN") or "200")
local m      = manager.machine
local cpu    = m.devices[":m1audio:sndcpu"]
local snd    = cpu.spaces["program"]
local wl     = assert(io.open(out .. "/ymw.log", "w"))
local lnk    = assert(io.open(out .. "/link.log", "w"))
local function PC() return cpu.state["PC"].value end

YM_TL = snd:install_read_tap(0xc20000, 0xc20001, "rx", function(o, d)
  lnk:write(string.format("%.7f R %d\n", emu.time(), d & 0xff)) end)

YM_SEL  = { [0] = 0, [1] = 0 }     -- the address latch, per part
YM_W    = {}                       -- [part*256+reg] = { n = count, v = {value = count} }
YM_KON  = {}                       -- key-on (0x28) values
YM_R    = {}                       -- ["pc off val"] = count
YM_NW, YM_NR = 0, 0

YM_TW = snd:install_write_tap(0xd00000, 0xd00007, "ymw", function(o, d, mk)
  local off = o - 0xd00000
  local b = d & 0xff
  YM_NW = YM_NW + 1
  wl:write(string.format("%.7f %d %d %06x\n", emu.time(), off, b, PC()))
  local part = (off >> 2) & 1
  if (off & 2) == 0 then
    YM_SEL[part] = b
  else
    local k = part * 256 + YM_SEL[part]
    local e = YM_W[k] or { n = 0, v = {} }
    e.n = e.n + 1; e.v[b] = (e.v[b] or 0) + 1
    YM_W[k] = e
    if part == 0 and YM_SEL[0] == 0x28 then
      YM_KON[#YM_KON + 1] = string.format("%.4f %02x", emu.time(), b)
    end
  end
end)

YM_TR = snd:install_read_tap(0xd00000, 0xd00007, "ymr", function(o, d, mk)
  YM_NR = YM_NR + 1
  local key = string.format("%06x %d %02x", PC(), o - 0xd00000, d & 0xff)
  YM_R[key] = (YM_R[key] or 0) + 1
end)

YM_OUT = { n = 0, nz = 0, pk = 0, first_nz = -1, last_nz = -1 }
m.sounds[":m1audio:ymsnd"].hook = true
emu.register_sound_update(function(t)
  local c = t[":m1audio:ymsnd"]
  if not c then return end
  local L, R = c[1], c[2]
  for i = 1, #L do
    local a, b = math.abs(L[i]), math.abs(R and R[i] or 0)
    YM_OUT.n = YM_OUT.n + 1
    if a ~= 0 or b ~= 0 then
      YM_OUT.nz = YM_OUT.nz + 1
      if YM_OUT.first_nz < 0 then YM_OUT.first_nz = emu.time() end
      YM_OUT.last_nz = emu.time()
      local p = math.max(a, b)
      if p > YM_OUT.pk then YM_OUT.pk = p end
    end
  end
end)

local function summary()
  local f = assert(io.open(out .. "/ymu.txt", "w"))
  f:write(string.format("system %s  time %.1f s  writes %d  reads %d\n",
    m.system.name, emu.time(), YM_NW, YM_NR))
  f:write(string.format("ymsnd output: %d samples, %d non-zero, peak %.6f, first %.4f s, last %.4f s\n",
    YM_OUT.n, YM_OUT.nz, YM_OUT.pk, YM_OUT.first_nz, YM_OUT.last_nz))
  local keys = {}
  for k in pairs(YM_W) do keys[#keys + 1] = k end
  table.sort(keys)
  f:write("data writes by part/register: count, distinct values (value:count, first 24)\n")
  for _, k in ipairs(keys) do
    local e, vs = YM_W[k], {}
    for v, c in pairs(e.v) do vs[#vs + 1] = { v, c } end
    table.sort(vs, function(a, b) return a[1] < b[1] end)
    local s = {}
    for i = 1, math.min(24, #vs) do s[#s + 1] = string.format("%02x:%d", vs[i][1], vs[i][2]) end
    f:write(string.format("  p%d r%02x  %8d  %3d  %s\n", k >> 8, k & 0xff, e.n, #vs, table.concat(s, " ")))
  end
  f:write(string.format("key-on (0x28) writes: %d\n", #YM_KON))
  for i = 1, math.min(64, #YM_KON) do f:write("  " .. YM_KON[i] .. "\n") end
  local rk = {}
  for k in pairs(YM_R) do rk[#rk + 1] = k end
  table.sort(rk)
  f:write("reads: pc offset value count\n")
  for _, k in ipairs(rk) do f:write(string.format("  %s %d\n", k, YM_R[k])) end
  f:close()
end

-- Daytona's coin and start; another set without them just runs its attract.
local in0   = m.ioport.ports[":IN0"]
local coin  = in0 and in0.fields["Coin 1"]
local start = in0 and in0.fields["1 Player Start"]
YM_F = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  local function pulse(at, fl)
    if not fl then return end
    if t >= at and t < at + 0.2 then fl:set_value(1)
    elseif t >= at + 0.2 and t < at + 0.4 then fl:set_value(0) end
  end
  pulse(T_COIN, coin); pulse(T_COIN + 1, coin); pulse(T_COIN + 2, coin)
  pulse(T_COIN + 4, start); pulse(T_COIN + 10, start)
  pulse(T_COIN + 14, start); pulse(T_COIN + 18, start)
  if t >= T_END then
    summary(); wl:close(); lnk:close()
    m:exit()
  end
end)
