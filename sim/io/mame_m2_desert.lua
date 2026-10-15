-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- DESERT TANK IN MAME, AND WHAT IT TOUCHES THAT DAYTONA DOES NOT (R835).
-- Runs a set headless, coins it, starts it and plays it (accelerator held,
-- the wheel swept a little, machine gun and cannon fired), and records:
--
--   ymw.log     every YM3438 write "<s> <off> <byte> <pc>" (R833's format)
--   ym.txt      the YM summary split by phase (attract / play): data writes
--               per register with values, key-ons with an operator bit set,
--               TL writes below 127, F-number writes, ymsnd's own output
--   video.txt   render_mode (0x10000000) and videocontrol (0x98000c) writes
--               with time and IP; list flips (0x803008) per second
--   pages.txt   i960 reads and writes by address bucket outside RAM and
--               program ROM -- diff two sets' files to see what one touches
--               and the other does not
--   tgp.txt     the TGP's uploaded program (word count, CRC) and the
--               function-port commands by code; copro bank writes
--   tgp_prog.bin the uploaded program itself (ROM-derived: never in git)
--   lamps.txt   output changes (lamps, coin counters)
--   fields.txt  every input port field, so the names below can be checked
--   sNNN.png    a snapshot every SNAP s (in the MAME snapshot directory)
--
--   M2_MAME_OUT=<dir> DT_OUT=<dir> DT_TEND=400 DT_COIN=60 \
--     tools/m2b-mame.sh desert -autoboot_script sim/io/mame_m2_desert.lua
--
-- Delete <M2_MAME_OUT>/nvram first. Everything written is ROM-derived and
-- stays outside the repository. Taps are globals or they are collected.

local out    = os.getenv("DT_OUT") or "."
local T_END  = tonumber(os.getenv("DT_TEND") or "400")
local T_COIN = tonumber(os.getenv("DT_COIN") or "60")
local T_COIN2 = tonumber(os.getenv("DT_COIN2") or "260")
local SNAP   = tonumber(os.getenv("DT_SNAP") or "10")
-- the accelerator while playing, the wheel's swing (0 holds it at centre)
-- and whether the guns fire -- for the analog-range experiments
local ACCV   = tonumber(os.getenv("DT_ACCV") or "255")
local SWING  = tonumber(os.getenv("DT_SWING") or "40")
local FIRE   = (os.getenv("DT_FIRE") or "1") ~= "0"
local STEERV = tonumber(os.getenv("DT_STEERV") or "-1")   -- >= 0: the wheel held there
local m      = manager.machine
local cpu    = m.devices[":maincpu"]
local sp     = cpu.spaces["program"]
local scr    = m.screens[":screen"]
local ports  = m.ioport.ports
local function IP() return cpu.state["ip"] and cpu.state["ip"].value or 0 end
local function phase() return (emu.time() < T_COIN) and "attract" or "play" end
-- DT_TIMER0=1: every i960 read of the timers (0x00f00000-0x00f0000f) returns
-- 0, as this core answers them (it has no timers) -- to see whether the game
-- notices (R835)
if (os.getenv("DT_TIMER0") or "0") ~= "0" then
  DT_T0 = sp:install_read_tap(0x00f00000, 0x00f0000f, "dtt0", function(o, d, mk) return 0 end)
end

-- ------------------------------------------------------------------ fields
do
  local f = assert(io.open(out .. "/fields.txt", "w"))
  local pn = {}
  for k in pairs(ports) do pn[#pn + 1] = k end
  table.sort(pn)
  for _, k in ipairs(pn) do
    for n, fl in pairs(ports[k].fields) do
      f:write(string.format("%s\t%s\tmask %x\tdef %x\n", k, n, fl.mask, fl.defvalue))
    end
  end
  f:write("devices with spaces:\n")
  for tag, d in pairs(m.devices) do
    local s = {}
    for n in pairs(d.spaces) do s[#s + 1] = n end
    if #s > 0 then f:write("  " .. tag .. " " .. table.concat(s, ",") .. "\n") end
  end
  f:close()
end

-- --------------------------------------------------------------------- YM
local snd  = m.devices[":m1audio:sndcpu"]
local ssp  = snd.spaces["program"]
local ywl  = assert(io.open(out .. "/ymw.log", "w"))
DT_YSEL = { [0] = 0, [1] = 0 }
DT_YW   = { attract = {}, play = {} }   -- [phase][part*256+reg] = {n, v = {}}
DT_YKON = {}                            -- key-ons with an operator bit
DT_YTL  = {}                            -- TL writes below 0x7f
DT_YN   = { attract = 0, play = 0 }
DT_YT = ssp:install_write_tap(0xd00000, 0xd00007, "dtym", function(o, d, mk)
  local off = o - 0xd00000
  local b = d & 0xff
  local ph = phase()
  DT_YN[ph] = DT_YN[ph] + 1
  ywl:write(string.format("%.7f %d %d %06x\n", emu.time(), off, b, snd.state["PC"].value))
  local part = (off >> 2) & 1
  if (off & 2) == 0 then
    DT_YSEL[part] = b
  else
    local r = DT_YSEL[part]
    local k = part * 256 + r
    local e = DT_YW[ph][k] or { n = 0, v = {} }
    e.n = e.n + 1; e.v[b] = (e.v[b] or 0) + 1
    DT_YW[ph][k] = e
    if part == 0 and r == 0x28 and (b & 0xf0) ~= 0 then
      DT_YKON[#DT_YKON + 1] = string.format("%.4f %02x", emu.time(), b)
    end
    if r >= 0x40 and r <= 0x4f and b ~= 0x7f then
      DT_YTL[#DT_YTL + 1] = string.format("%.4f p%d r%02x %02x", emu.time(), part, r, b)
    end
  end
end)

DT_YO = { attract = { n = 0, nz = 0, pk = 0 }, play = { n = 0, nz = 0, pk = 0, first = -1, last = -1 } }
m.sounds[":m1audio:ymsnd"].hook = true
emu.register_sound_update(function(t)
  local c = t[":m1audio:ymsnd"]
  if not c then return end
  local o = DT_YO[phase()]
  local L, R = c[1], c[2]
  for i = 1, #L do
    local a, b = math.abs(L[i]), math.abs(R and R[i] or 0)
    o.n = o.n + 1
    if a ~= 0 or b ~= 0 then
      o.nz = o.nz + 1
      if o.first and o.first < 0 then o.first = emu.time() end
      if o.last then o.last = emu.time() end
      local p = math.max(a, b)
      if p > o.pk then o.pk = p end
    end
  end
end)

-- ------------------------------------------------------------------ video
local vf = assert(io.open(out .. "/video.txt", "w"))
DT_FLIPS, DT_FLIPS_SEC = 0, {}
DT_RM = sp:install_write_tap(0x10000000, 0x101fffff, "dtrm", function(o, d, mk)
  vf:write(string.format("%.4f f%d render_mode %08x @%08x ip %08x\n", emu.time(), scr:frame_number(), d, o, IP()))
end)
DT_VC = sp:install_write_tap(0x0098000c, 0x0098000f, "dtvc", function(o, d, mk)
  vf:write(string.format("%.4f f%d videoctl %08x ip %08x\n", emu.time(), scr:frame_number(), d, IP()))
end)
DT_FL = sp:install_write_tap(0x00803008, 0x0080300b, "dtfl", function(o, d, mk)
  DT_FLIPS = DT_FLIPS + 1
end)

-- ------------------------------------------------------------ page counts
DT_PG = {}
local function bump(k) DT_PG[k] = (DT_PG[k] or 0) + 1 end
local function key(rw, a)
  -- exact dword for the control registers, coarser elsewhere
  if (a >= 0x00980000 and a < 0x00990000) or (a >= 0x00e00000 and a < 0x01000000)
     or (a >= 0x01c80000 and a < 0x01c80010) or (a >= 0x0181c000 and a < 0x0181c010)
     or (a >= 0x01040000 and a < 0x01080000) then
    return string.format("%s %08x", rw, a & ~3)
  elseif a >= 0x01c00000 and a < 0x01c01000 then
    return string.format("%s %08x dpram", rw, a & ~3)
  elseif a >= 0x00800000 and a < 0x00900000 then
    return string.format("%s %08x/4K", rw, a & ~0xfff)
  elseif a >= 0x02000000 and a < 0x10000000 then
    return string.format("%s %08x/1M", rw, a & ~0xfffff)
  elseif a >= 0x10000000 then
    return string.format("%s %08x/64K", rw, a & ~0xffff)
  else
    return string.format("%s %08x/4K", rw, a & ~0xfff)
  end
end
local W = { {0x00800000, 0x008fffff}, {0x00980000, 0x0098ffff}, {0x00a00000, 0x00ffffff},
            {0x01020000, 0x0107ffff}, {0x01120000, 0x0117ffff},
            {0x01800000, 0x01ffffff}, {0x02000000, 0x0fffffff}, {0x10000000, 0x1fffffff},
            {0x00240000, 0x004fffff}, {0x00600000, 0x007fffff} }
local R = { {0x00800000, 0x008fffff}, {0x00980000, 0x00ffffff},
            {0x01800000, 0x01ffffff}, {0x02000000, 0x0fffffff}, {0x10000000, 0x1fffffff},
            {0x00240000, 0x004fffff}, {0x00600000, 0x007fffff} }
DT_TAPS = {}
for i, r in ipairs(W) do
  DT_TAPS[#DT_TAPS + 1] = sp:install_write_tap(r[1], r[2], "dtw" .. i, function(o, d, mk) bump(key("W", o)) end)
end
for i, r in ipairs(R) do
  DT_TAPS[#DT_TAPS + 1] = sp:install_read_tap(r[1], r[2], "dtr" .. i, function(o, d, mk) bump(key("R", o)) end)
end
-- the tilemap and char RAM, coarsely (writes only)
DT_TAPS[#DT_TAPS + 1] = sp:install_write_tap(0x01000000, 0x0101ffff, "dtwt", function(o, d, mk) bump("W tile/64K " .. string.format("%08x", o & ~0xffff)) end)
DT_TAPS[#DT_TAPS + 1] = sp:install_write_tap(0x01080000, 0x010fffff, "dtwc", function(o, d, mk) bump("W char") end)
-- the copro function port by command code
DT_FN = {}
DT_TAPS[#DT_TAPS + 1] = sp:install_write_tap(0x00880000, 0x00883fff, "dtfn", function(o, d, mk)
  local k = ((o - 0x00880000) >> 4) & 0xff   -- MAME: (dword offset >> 2) & 0xff
  DT_FN[k] = (DT_FN[k] or 0) + 1
end)

-- ------------------------------------------------------------------- TGP
local tgp = m.devices[":copro_tgp"]
DT_BANK = {}
if tgp and tgp.spaces["rf"] then
  DT_TB = tgp.spaces["rf"]:install_write_tap(0x3, 0x3, "dtbank", function(o, d, mk)
    DT_BANK[d] = (DT_BANK[d] or 0) + 1
  end)
end
local function crc32(s)
  local c = 0xffffffff
  for i = 1, #s do
    c = c ~ s:byte(i)
    for _ = 1, 8 do
      if (c & 1) ~= 0 then c = (c >> 1) ~ 0xedb88320 else c = c >> 1 end
    end
  end
  return (~c) & 0xffffffff
end
local function dump_tgp(tf)
  if not tgp then tf:write("no :copro_tgp\n"); return end
  local ps = tgp.spaces["program"]
  local t, last = {}, -1
  for i = 0, 0xfff do
    local w = ps:read_u32(i)
    t[#t + 1] = string.pack("<I4", w)
    if w ~= 0 then last = i end
  end
  local s = table.concat(t)
  local bf = assert(io.open(out .. "/tgp_prog.bin", "wb")); bf:write(s); bf:close()
  local used = string.sub(s, 1, (last + 1) * 4)
  tf:write(string.format("tgp program: last non-zero word 0x%03x (%d words), crc32(used) %08x, crc32(4096 words) %08x\n",
    last, last + 1, crc32(used), crc32(s)))
end

-- ------------------------------------------------------------------ lamps
local lf = assert(io.open(out .. "/lamps.txt", "w"))
DT_LV = {}
local LNAMES = { "lamp0", "lamp1", "lamp2", "lamp3", "lamp4", "lamp5" }

-- ----------------------------------------------------------------- summary
local function summary()
  local f = assert(io.open(out .. "/ym.txt", "w"))
  f:write(string.format("system %s  time %.1f s  coin at %d s\n", m.system.name, emu.time(), T_COIN))
  for _, ph in ipairs({ "attract", "play" }) do
    local o = DT_YO[ph]
    f:write(string.format("[%s] YM writes %d; ymsnd %d samples, %d non-zero, peak %.6f%s\n", ph, DT_YN[ph],
      o.n, o.nz, o.pk, o.first and string.format(", first %.3f last %.3f", o.first, o.last) or ""))
    local keys = {}
    for k in pairs(DT_YW[ph]) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local e, vs = DT_YW[ph][k], {}
      for v, c in pairs(e.v) do vs[#vs + 1] = { v, c } end
      table.sort(vs, function(a, b) return a[1] < b[1] end)
      local s = {}
      for i = 1, math.min(24, #vs) do s[#s + 1] = string.format("%02x:%d", vs[i][1], vs[i][2]) end
      f:write(string.format("  p%d r%02x %8d %3d  %s\n", k >> 8, k & 0xff, e.n, #vs, table.concat(s, " ")))
    end
  end
  f:write(string.format("key-on with an operator bit: %d\n", #DT_YKON))
  for i = 1, math.min(64, #DT_YKON) do f:write("  " .. DT_YKON[i] .. "\n") end
  f:write(string.format("TL writes below 0x7f: %d\n", #DT_YTL))
  for i = 1, math.min(64, #DT_YTL) do f:write("  " .. DT_YTL[i] .. "\n") end
  f:close()

  local p = assert(io.open(out .. "/pages.txt", "w"))
  local ks = {}
  for k in pairs(DT_PG) do ks[#ks + 1] = k end
  table.sort(ks)
  for _, k in ipairs(ks) do p:write(string.format("%s %d\n", k, DT_PG[k])) end
  p:close()

  local tf = assert(io.open(out .. "/tgp.txt", "w"))
  dump_tgp(tf)
  local fk = {}
  for k in pairs(DT_FN) do fk[#fk + 1] = k end
  table.sort(fk)
  tf:write("function port writes by function ((addr-0x880000)>>4 & 0xff):\n")
  for _, k in ipairs(fk) do tf:write(string.format("  %02x %d\n", k, DT_FN[k])) end
  local bk = {}
  for k in pairs(DT_BANK) do bk[#bk + 1] = k end
  table.sort(bk)
  tf:write("copro bank (rf 3) writes:\n")
  for _, k in ipairs(bk) do tf:write(string.format("  %08x %d\n", k, DT_BANK[k])) end
  tf:close()
end

-- ------------------------------------------------------------------ drive
local function fld(p, n) return ports[p] and ports[p].fields[n] end
local function set(p, n, v) local x = fld(p, n); if x then x:set_value(v) end end
local function find(p, pat)
  if not ports[p] then return nil end
  for n, x in pairs(ports[p].fields) do if n:find(pat) then return n end end
end
local F_COIN  = "Coin 1"
local F_START = "1 Player Start"
local F_MG    = find(":IN1", "Machine") or "Machine Gun"
local F_CAN   = find(":IN1", "Cannon") or "Cannon"
local F_ACC   = ports[":ACCEL"] and next(ports[":ACCEL"].fields)
local F_STR   = ports[":STEER"] and next(ports[":STEER"].fields)
local function pulse(t, at, p, n, len)
  len = len or 0.2
  if t >= at and t < at + len then set(p, n, 1)
  elseif t >= at + len and t < at + 2 * len then set(p, n, 0) end
end

local next_snap, last_sec = 0, -1
DT_F = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  for _, c in ipairs({ T_COIN, T_COIN2 }) do
    pulse(t, c, ":IN0", F_COIN); pulse(t, c + 1, ":IN0", F_COIN)
    for k = 0, 12 do pulse(t, c + 4 + 2 * k, ":IN0", F_START) end
  end
  local playing = (t >= T_COIN + 4 and t < T_COIN2 - 20) or (t >= T_COIN2 + 4)
  if playing then
    if F_ACC then set(":ACCEL", F_ACC, ACCV) end
    if F_STR then
      set(":STEER", F_STR, STEERV >= 0 and STEERV or (0x80 + math.floor(SWING * math.sin(t * 0.7))))
    end
    if FIRE then
      set(":IN1", F_MG, ((t * 2) % 2 < 1) and 1 or 0)
      pulse(t, math.floor(t / 3) * 3, ":IN1", F_CAN, 0.25)
    end
  else
    if F_ACC then set(":ACCEL", F_ACC, 0) end
    if F_STR then set(":STEER", F_STR, 0x80) end
    set(":IN1", F_MG, 0); set(":IN1", F_CAN, 0)
  end
  local sec = math.floor(t)
  if sec ~= last_sec then
    if last_sec >= 0 then
      vf:write(string.format("sec %d flips %d frame %d\n", last_sec, DT_FLIPS, scr:frame_number()))
    end
    DT_FLIPS = 0
    last_sec = sec
    for _, n in ipairs(LNAMES) do
      local o = m.output:find(n)
      local v = o and o.value or -1
      if v ~= DT_LV[n] then lf:write(string.format("%.2f %s %d\n", t, n, v)); DT_LV[n] = v end
    end
    if sec % 10 == 0 then vf:flush(); lf:flush(); ywl:flush() end
  end
  if SNAP > 0 and t >= next_snap then
    scr:snapshot(string.format("s%04d.png", math.floor(t)))
    next_snap = next_snap + SNAP
  end
  if t >= T_END then
    summary(); ywl:close(); vf:close(); lf:close()
    m:exit()
  end
end)
