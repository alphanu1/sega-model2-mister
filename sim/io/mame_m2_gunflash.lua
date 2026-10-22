-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- WHAT A GUN GAME ASKS FOR ON A SHOT (R929, GitHub #13). A scripted game with
-- single trigger pulls, and per frame around each shot: i960 write counts to
-- every video memory, every write to the video / sync / render-mode registers,
-- the palette and colour table, the i960 <-> I/O board path (DPRAM on Model 2,
-- the 315-5649 on 2A / 2C), the I/O board Z80's writes to its 315-5338A ports
-- and FPGA block (Model 2), and a snapshot per frame.
--   GF_OUT=<dir>   frames.txt (per frame), writes.txt (every logged write)
--   GF_SET=vcop|vcop2|hotd     which map / inputs (default vcop)
--   GF_COIN GF_START  times (s); GF_SHOTS="t,t,..." single 0.05 s pulls
--   GF_T0 GF_TEND     log window; GF_WIN  half-width (s) of the per-frame
--                     snapshot / detail window around each shot (0.4)
-- Run as tools/m2b-mame.sh does (writable dirs outside the tree):
--   m2lod vcopa -autoboot_script <this> -snapview native -snapsize 496x384
local m = manager.machine
local cpu = m.devices[":maincpu"]
local sp = cpu.spaces["program"]
local scr = m.screens[":screen"]
local out = assert(os.getenv("GF_OUT"), "GF_OUT")
local set = os.getenv("GF_SET") or "vcop"
local function fld(port, name)
  local p = m.ioport.ports[port]
  if not p then return nil end
  for n, f in pairs(p.fields) do if n == name then return f end end
  return nil
end
local function need(port, name) return assert(fld(port, name), "no field " .. port .. " " .. name) end
local c1, s1, trig
if set == "vcop" then
  c1, s1, trig = need(":IN0", "Coin 1"), need(":IN0", "1 Player Start"), need(":IN1", "P1 Trigger")
else
  -- 2A / 2C sets: find the fields by name in any port
  for pn, p in pairs(m.ioport.ports) do
    for n, f in pairs(p.fields) do
      if n == "Coin 1" then c1 = f end
      if n == "1 Player Start" then s1 = f end
      if n == "P1 Trigger" or n == "P1 Button 1" and not trig then trig = trig or f end
    end
  end
  assert(c1 and s1 and trig, "fields")
end
local shots = {}
for t in string.gmatch(os.getenv("GF_SHOTS") or "", "([%d%.]+)") do shots[#shots + 1] = tonumber(t) end
local T_COIN = tonumber(os.getenv("GF_COIN") or "40")
local T_START = tonumber(os.getenv("GF_START") or "41.5")
local T0 = tonumber(os.getenv("GF_T0") or "50")
local T_END = tonumber(os.getenv("GF_TEND") or "70")
local WIN = tonumber(os.getenv("GF_WIN") or "0.4")
local function near(t) for _, s in ipairs(shots) do if t >= s - WIN and t < s + WIN then return true end end return false end

-- Model 2 (vcop): the gun coordinates at the I/O board's FPGA, centred, as R899's script
if set == "vcop" then
  local g = { 0x0e6, 0x17c, 0x0e8, 0x179, 0 }
  local iocpu = m.devices[":ioboard:iocpu"]
  local isp = iocpu.spaces["program"]
  GFG = isp:install_read_tap(0x8100, 0x810f, "gun", function(off, data, mask)
    local o = off & 0xf
    if data == 0x80 and o ~= 8 then return data end
    if o == 8 then return 0xfc | g[5] end
    if o > 8 then return data end
    local v = g[(o >> 1) + 1]
    if (o & 1) == 0 then return v & 0xff else return (v >> 8) & 0xff end
  end)
end

local detail = assert(io.open(out .. "/writes.txt", "w"))
local fr = assert(io.open(out .. "/frames.txt", "w"))
local regions = {
  { "tex", 0x12000000, 0x127fffff, false },
  { "luma", 0x12800000, 0x1281ffff, true },
  { "tile", 0x01000000, 0x0100ffff, true },
  { "char", 0x01080000, 0x010fffff, false },
  { "pal", 0x01800000, 0x01803fff, true },
  { "xlat", 0x01810000, 0x0181bfff, true },
  { "zclip", 0x0181c000, 0x0181c003, true },
  { "buf", 0x00900000, 0x0097ffff, false },
  { "geo", 0x00800000, 0x00803fff, false },
  { "fifo", 0x00880000, 0x00887fff, false },
  { "vctl", 0x00980000, 0x0098003f, true },
  { "sync", 0x01020000, 0x0107ffff, true },
  { "rmode", 0x10000000, 0x101fffff, true },
  { "cpuctl", 0x00e00000, 0x00e00037, true },
  { "io", 0x01c00000, 0x01c00fff, true },
}
local cnt = {}
GFT = {}
-- GF_NOFLASH=1: every write to the tilemap 0/1 window mask (tile RAM 0x6000-0x67ff
-- words, CPU 0x0100c000-0x0100cfff) is turned into 0 -- the picture under the flash
if os.getenv("GF_NOFLASH") then
  GFN = sp:install_write_tap(0x0100c000, 0x0100cfff, "noflash", function(o, d, mk) return 0 end)
end
for _, r in ipairs(regions) do
  local name, logit = r[1], r[4]
  cnt[name] = 0
  GFT[#GFT + 1] = sp:install_write_tap(r[2], r[3], name, function(o, d, mk)
    cnt[name] = cnt[name] + 1
    local t = emu.time()
    -- registers always; tables and DPRAM inside the windows
    local always = (name == "vctl" or name == "sync" or name == "rmode" or name == "zclip" or name == "cpuctl")
    if logit and t >= T0 and (always or near(t)) then
      detail:write(string.format("%.4f f%d %s %08x = %08x mask %08x ip %08x\n", t, scr:frame_number(), name, o, d, mk, cpu.state["ip"].value))
    end
  end)
end
-- the I/O board Z80 (Model 2): 315-5338A writes (ports, lamps / recoil on PD) and the FPGA block
local zlast = {}
if set == "vcop" then
  local iocpu = m.devices[":ioboard:iocpu"]
  local isp = iocpu.spaces["program"]
  GFZ = isp:install_write_tap(0x8000, 0x83ff, "z80io", function(o, d, mk)
    local t = emu.time()
    if t < T0 then return end
    local v = d & 0xff
    if zlast[o] ~= v or (o >= 0x8100 and o < 0x8200) then
      detail:write(string.format("%.4f f%d z80 %04x = %02x\n", t, scr:frame_number(), o, v))
      zlast[o] = v
    end
  end)
end
-- GF_DUMP="frame,frame,...": tile / char / palette / colour table at those frames'
-- notifiers, little-endian, as tools/mame_m2_tiledump.lua (tb_m2_video_frame's +in=)
local dumps = {}
for f in string.gmatch(os.getenv("GF_DUMP") or "", "(%d+)") do dumps[tonumber(f)] = true end
local DREG = {
  { "tile", 0x01000000, 0x010000 }, { "char", 0x01080000, 0x080000 },
  { "palette", 0x01800000, 0x004000 }, { "colorxlat", 0x01810000, 0x00c000 },
}
local function dump(fn)
  local d = out .. "/d" .. fn
  os.execute("mkdir -p " .. d)
  for _, r in ipairs(DREG) do
    local f = assert(io.open(d .. "/" .. r[1] .. ".bin", "wb"))
    local chunk = {}
    for a = r[2], r[2] + r[3] - 4, 4 do
      chunk[#chunk + 1] = string.pack("<I4", sp:read_u32(a))
      if #chunk >= 4096 then f:write(table.concat(chunk)); chunk = {} end
    end
    if #chunk > 0 then f:write(table.concat(chunk)) end
    f:close()
  end
end
local ns = 0
GFF = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  if dumps[scr:frame_number()] then dump(scr:frame_number()) end
  if t >= T_COIN and t < T_COIN + 0.2 then c1:set_value(1) else c1:clear_value() end
  if t >= T_START and t < T_START + 0.2 then s1:set_value(1) else s1:clear_value() end
  local tp = false
  for _, s in ipairs(shots) do if t >= s and t < s + 0.05 then tp = true end end
  if tp then trig:set_value(1) else trig:clear_value() end
  if t >= T0 then
    local s = string.format("%.4f f%d", t, scr:frame_number())
    for _, r in ipairs(regions) do s = s .. string.format(" %s=%d", r[1], cnt[r[1]]) end
    s = s .. string.format(" tp=%d", tp and 1 or 0)
    fr:write(s .. "\n")
    if near(t) then scr:snapshot(string.format("f%06d.png", scr:frame_number())) end
  end
  for _, r in ipairs(regions) do cnt[r[1]] = 0 end
  if t >= T_END then detail:close(); fr:close(); m:exit() end
end)
