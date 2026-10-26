-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- R965: WHAT A GUN GAME WRITES TO TILEMAPS 0/1's WINDOW TABLE (tile RAM words
-- 0x6000-0x67FF, CPU 0x0100C000-0x0100CFFF), FRAME BY FRAME. One line a frame
-- with writes: count, all-ones / zero / other values, the offsets, the i960
-- ips, and what word 0x6000 (the flash request, R929) was written to. For the
-- 2A / 2C gun games (vcop2, hotd) as well as Model 2's.
--   WT_OUT=<dir>       wt.txt, snapshots, dumps
--   WT_COIN / WT_START / WT_SHOTS "t,t,..."  0.2 s coin / start, 0.05 s pulls
--   WT_NOINPUT=1       leave the inputs alone (run beside another script, e.g.
--                      sim/io/mame_m2_hotd_play.lua with HA_EXTRA=<this>)
--   WT_TEND            exit time (s)
--   WT_SNAP "t0-t1,.." a snapshot every frame inside each window
--   WT_LOGF "f,f,..."  every table write of those frames
--   WT_DUMP "f,f,..."  tile / char / palette / colour table at those frames'
--                      notifiers (tb_m2_gunflash2a's +in=, little-endian)
--   WT_NOFLASH=1       every table write turned into 0 (the picture without
--                      the game's flash, as sim/io/mame_m2_gunflash.lua GF_NOFLASH)
-- Run (writable dirs outside the tree): mame vcop2 -autoboot_script <this>
--   -video none -nothrottle -snapview native -nosnapbilinear
local m = manager.machine
local cpu = m.devices[":maincpu"]
local sp = cpu.spaces["program"]
local scr = m.screens[":screen"]
local out = assert(os.getenv("WT_OUT"))
local c1, s1, trig
for pn, p in pairs(m.ioport.ports) do
  for n, f in pairs(p.fields) do
    if n == "Coin 1" then c1 = f end
    if n == "1 Player Start" then s1 = f end
    if (n == "P1 Trigger" or n == "P1 Button 1") and not trig then trig = f end
  end
end
assert(c1 and s1 and trig, "fields")
local function list(e) local r = {} for x in string.gmatch(os.getenv(e) or "", "([%d%.]+)") do r[#r+1] = tonumber(x) end return r end
local shots = list("WT_SHOTS")
local coins = list("WT_COIN")
local starts = list("WT_START")
local snaps = {}
for a, b in string.gmatch(os.getenv("WT_SNAP") or "", "([%d%.]+)-([%d%.]+)") do snaps[#snaps+1] = {tonumber(a), tonumber(b)} end
local TEND = tonumber(os.getenv("WT_TEND") or "60")
local log = assert(io.open(out .. "/wt.txt", "w"))
local dumps, logf = {}, {}
for f in string.gmatch(os.getenv("WT_DUMP") or "", "(%d+)") do dumps[tonumber(f)] = true end
for f in string.gmatch(os.getenv("WT_LOGF") or "", "(%d+)") do logf[tonumber(f)] = true end
local DREG = { { "tile", 0x01000000, 0x010000 }, { "char", 0x01080000, 0x080000 },
  { "palette", 0x01800000, 0x004000 }, { "colorxlat", 0x01810000, 0x00c000 } }
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
local n, nff, n0, nother, lo, hi, ips, w0 = 0, 0, 0, 0, 1e9, -1, {}, nil
WTT = sp:install_write_tap(0x0100c000, 0x0100cfff, "wt", function(o, d, mk)
  local off = o - 0x0100c000
  n = n + 1
  local v = d & mk
  if v == mk then nff = nff + 1 elseif v == 0 then n0 = n0 + 1 else nother = nother + 1 end
  if off < lo then lo = off end
  if off > hi then hi = off end
  ips[string.format("%x", cpu.state["ip"].value)] = true
  if off == 0 and (mk & 0xffff) ~= 0 then w0 = string.format("w6000=%04x ip=%x", d & 0xffff, cpu.state["ip"].value) end
  if logf[scr:frame_number()] then log:write(string.format("  W f%d %04x = %08x mask %08x ip %x\n", scr:frame_number(), off, d, mk, cpu.state["ip"].value)) end
  if os.getenv("WT_NOFLASH") then return 0 end
end)
local function tin(t, L, w) for _, s in ipairs(L) do if t >= s and t < s + w then return true end end return false end
WTF = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  local f = scr:frame_number()
  local tp = false
  if not os.getenv("WT_NOINPUT") then
  if tin(t, coins, 0.2) then c1:set_value(1) else c1:clear_value() end
  if tin(t, starts, 0.2) then s1:set_value(1) else s1:clear_value() end
  tp = tin(t, shots, 0.05)
  if tp then trig:set_value(1) else trig:clear_value() end
  end
  if n > 0 then
    local k = {} for ip in pairs(ips) do k[#k+1] = ip end
    log:write(string.format("%.4f f%d n=%d ff=%d z=%d other=%d off=%x-%x ips=%s %s%s\n", t, f, n, nff, n0, nother, lo, hi, table.concat(k, ","), w0 or "", tp and " TP" or ""))
  elseif tp then log:write(string.format("%.4f f%d TP\n", t, f)) end
  n, nff, n0, nother, lo, hi, ips, w0 = 0, 0, 0, 0, 1e9, -1, {}, nil
  if dumps[f] then dump(f) end
  for _, s in ipairs(snaps) do if t >= s[1] and t < s[2] then scr:snapshot(string.format("f%06d.png", f)) end end
  if t >= TEND then log:close(); m:exit() end
end)
