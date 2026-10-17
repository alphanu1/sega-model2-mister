-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- VIRTUA COP 2: HOW THE GAME READS ITS GUNS, AND WHO IS IN PLAY (R870).
-- MAME 0.289 vcop2 binds the 315-5649's RS-422 channel 2 to the guns
-- (model2a_state::vcop2: serial_ch2_wr = lightgun_mux_w, offset 0x0a; serial_ch2_rd =
-- lightgun_mux_r, offset 0x0c). With umask32(0x00ff00ff) those are byte lane 0
-- of CPU 0x01c00014 (write) and 0x01c00018 (read). This script taps both:
--   V2_IOLOG  file: every mux write and data read (time, pc, mux, byte) for
--             the first V2_IOMAX accesses, then a per-second histogram of the
--             mux values read (the order the game reads them in).
--   V2_GUNAT  "t=p1x,p1y,p2x,p2y;t=..." (decimal) forces the coordinates the
--             game reads from time t on, by returning lightgun_mux_r's byte
--             for those values (mux 0-7 = P1_Y lo/hi, P1_X, P2_Y, P2_X; mux
--             >= 8 the off-screen byte 0xfc | P2 << 1 | P1 by MAME's 5% rule
--             on vcop2's ranges). Unset: MAME's own ports, untouched.
--   V2_EV     "t|port/field|dur;..."  presses (dur s)
--   V2_FIRE   "p:t0:t1:period;..."    player p's trigger pulsed every period in [t0,t1)
--   V2_REACT  "addr:value:delay:port/field;..." (addr, value hex): the first time
--             the byte at addr reads value, press the field (0.3 s) delay s later
--   V2_IOFROM the access log starts at this time (default 0)
--   V2_DUMP   file; work RAM 0x500000..+V2_LEN every V2_EVERY s (12-byte header
--             "VCDP", time*1000 u32, frame u32, then the bytes)
--   V2_WATCH  "addr,addr,..." (hex): those bytes every 0.5 s to V2_STATE, and every
--             write to their words to V2_WLOG (time addr data mask pc)
--   V2_SNAPEVERY snapshots every n s (default 2); V2_TEND end (default 240).
-- Run: mame vcop2 -rompath ~/roms/Model2 -video none -sound none -nothrottle
--      -autoboot_script <this> -snapview native -snapsize 496x384
--      (a fresh -nvram_directory: the game's gun calibration lives in its EEPROM)
-- R870's run 3, test_m2_vcop2_state's capture (build/vcop2state/r3_wlog.txt,
-- r3_state.txt):
--   V2_TEND=200 V2_WATCH=500034,500038,502088,50208c V2_STATE=r3_state.txt
--   V2_WLOG=r3_wlog.txt
--   V2_EV="40|:IN0/Coin 1|0.2;40.6|...;43.6|:IN0/Coin 1|0.2" (seven coins, 0.6 s apart)
--         ";44|:IN0/1 Player Start|0.3;56|:IN0/2 Players Start|0.3;160|:IN0/2 Players Start|0.3"
--         ";175|:IN0/Service Mode|0.3;190|:IN0/Service Mode|0.3"
--   V2_REACT="502088:02:2::IN0/1 Player Start;50208c:02:3::IN0/2 Players Start"
--   V2_FIRE="1:50:150:0.7;2:58:150:0.9;2:165:175:0.8"
-- GUN MARK CHECK (R870 3): V2_EV="16|:IN0/Service Mode|0.2", Service 1 nine
-- times from 18 s, 0.6 s apart, then "25|:IN0/Service Mode|0.2;26.5|:IN0/Service
-- 1|0.15;28|:IN0/Service Mode|0.2"; V2_GUNAT sets the coordinates shown.
local m = manager.machine
local cpu = m.devices[":maincpu"]
local sp = cpu.spaces["program"]
local scr = m.screens[":screen"]
local function fld(port, name)
  for n, f in pairs(m.ioport.ports[port].fields) do if n == name then return f end end
  error("no field " .. port .. " " .. name)
end
local ev = {}
for t, pn, dur in string.gmatch(os.getenv("V2_EV") or "", "([%d%.]+)|([^|;]+)|([%d%.]+)") do
  local port, name = pn:match("([^/]+)/(.+)")
  ev[#ev + 1] = { t = tonumber(t), d = tonumber(dur), f = fld(port, name), on = false }
end
local trig = { fld(":IN1", "P1 Trigger"), fld(":IN1", "P2 Trigger") }
local fire = {}
for p, t0, t1, per in string.gmatch(os.getenv("V2_FIRE") or "", "(%d):([%d%.]+):([%d%.]+):([%d%.]+)") do
  fire[#fire + 1] = { p = tonumber(p), t0 = tonumber(t0), t1 = tonumber(t1), per = tonumber(per) }
end
local react = {}
for a, v, dl, pn in string.gmatch(os.getenv("V2_REACT") or "", "(%x+):(%x+):([%d%.]+):([^;]+)") do
  local port, name = pn:match("([^/]+)/(.+)")
  react[#react + 1] = { a = tonumber(a, 16), v = tonumber(v, 16), d = tonumber(dl), f = fld(port, name), t = nil }
end
local gunat = {}
for t, vals in string.gmatch(os.getenv("V2_GUNAT") or "", "([%d%.]+)=([%d,]+)") do
  local v = {}
  for x in string.gmatch(vals, "(%d+)") do v[#v + 1] = tonumber(x) end
  gunat[#gunat + 1] = { t = tonumber(t), v = v }
end
local gun = nil   -- {p1x, p1y, p2x, p2y} when forced
-- vcop2's ranges (INPUT_PORTS_START(vcop2)) and MAME's int(span * 0.05f) border
local function offbits(g)
  local o = 0
  if g[1] <= 137 + 24 or g[1] >= 630 - 24 or g[2] <= 36 + 19 or g[2] >= 425 - 19 then o = o | 1 end
  if g[3] <= 134 + 24 or g[3] >= 627 - 24 or g[4] <= 36 + 19 or g[4] >= 425 - 19 then o = o | 2 end
  return o
end
local pnames = { ":P1_Y", ":P1_X", ":P2_Y", ":P2_X" }
local mux = 0
local iolog = os.getenv("V2_IOLOG") and assert(io.open(os.getenv("V2_IOLOG"), "w"))
local IOMAX = tonumber(os.getenv("V2_IOMAX") or "400")
local IOFROM = tonumber(os.getenv("V2_IOFROM") or "0")
local nio = 0
local hist, hsec = {}, 0
local nmism = 0
V2W = sp:install_write_tap(0x01c00014, 0x01c00017, "gunmux", function(off, data, mask)
  if (mask & 0xff) ~= 0 then
    mux = data & 0xff
    if iolog and nio < IOMAX and emu.time() >= IOFROM then
      iolog:write(string.format("%.6f W pc %08x mux %02x (data %08x mask %08x)\n", emu.time(), cpu.state["ip"].value, mux, data, mask))
      nio = nio + 1
    end
  end
end)
V2R = sp:install_read_tap(0x01c00018, 0x01c0001b, "gundata", function(off, data, mask)
  if (mask & 0xff) == 0 then return data end
  local mame = data & 0xff
  -- what MAME's own ports say, as a check on the reading of lightgun_mux_r
  local exp
  if mux < 8 then
    local v = m.ioport.ports[pnames[(mux >> 1) + 1]]:read() & 0x3ff
    exp = ((mux & 1) == 1) and (v >> 8) or (v & 0xff)
  else
    local g = { m.ioport.ports[":P1_X"]:read() & 0x3ff, m.ioport.ports[":P1_Y"]:read() & 0x3ff,
                m.ioport.ports[":P2_X"]:read() & 0x3ff, m.ioport.ports[":P2_Y"]:read() & 0x3ff }
    exp = 0xfc | offbits(g)
  end
  if exp ~= mame then nmism = nmism + 1 end
  local b = mame
  if gun then
    if mux < 8 then
      local v = ({ gun[2], gun[1], gun[4], gun[3] })[(mux >> 1) + 1]
      b = ((mux & 1) == 1) and ((v >> 8) & 0xff) or (v & 0xff)
    else
      b = 0xfc | offbits(gun)
    end
  end
  local s = math.floor(emu.time())
  if s ~= hsec then
    if iolog and next(hist) then
      local ks = {}
      for k, n in pairs(hist) do ks[#ks + 1] = string.format("%02x:%d", k, n) end
      table.sort(ks)
      iolog:write(string.format("sec %d reads %s\n", hsec, table.concat(ks, " ")))
    end
    hist, hsec = {}, s
  end
  hist[mux] = (hist[mux] or 0) + 1
  if iolog and nio < IOMAX and emu.time() >= IOFROM then
    iolog:write(string.format("%.6f R pc %08x mux %02x mame %02x ports %02x -> %02x\n", emu.time(), cpu.state["ip"].value, mux, mame, exp, b))
    nio = nio + 1
  end
  return (data & 0xffffff00) | b
end)
local watch = {}
for a in string.gmatch(os.getenv("V2_WATCH") or "", "(%x+)") do watch[#watch + 1] = tonumber(a, 16) end
local wlog = os.getenv("V2_WLOG") and assert(io.open(os.getenv("V2_WLOG"), "w"))
V2WT = {}   -- global: a local table would be collected and the taps with it
if wlog then
  for i, a in ipairs(watch) do
    local w = a & ~3
    V2WT[i] = sp:install_write_tap(w, w + 3, "w" .. i, function(off, data, mask)
      wlog:write(string.format("%.6f %08x data %08x mask %08x pc %08x\n", emu.time(), off, data, mask, cpu.state["ip"].value))
    end)
  end
end
local statef = os.getenv("V2_STATE") and assert(io.open(os.getenv("V2_STATE"), "w"))
local dumpf = os.getenv("V2_DUMP") and assert(io.open(os.getenv("V2_DUMP"), "wb"))
local LEN = tonumber(os.getenv("V2_LEN") or "262144")
local EVERY = tonumber(os.getenv("V2_EVERY") or "1")
local SNAPE = tonumber(os.getenv("V2_SNAPEVERY") or "2")
local T_END = tonumber(os.getenv("V2_TEND") or "240")
local nd, ns, nst = 0, 0, 0
V2F = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  for _, e in ipairs(ev) do
    if not e.done then
      if t >= e.t and not e.on then e.f:set_value(1); e.on = true
        if wlog then wlog:write(string.format("%.3f press %s\n", t, e.f.name)) end
      elseif t >= e.t + e.d and e.on then e.f:clear_value(); e.done = true end
    end
  end
  for _, r in ipairs(react) do
    if not r.t and sp:read_u8(r.a) == r.v then r.t = t
      if wlog then wlog:write(string.format("%.3f react %08x = %02x\n", t, r.a, r.v)) end
    end
    if r.t and not r.done then
      if t >= r.t + r.d and t < r.t + r.d + 0.3 then r.f:set_value(1); r.on = true
        if wlog and not r.logged then wlog:write(string.format("%.3f press %s\n", t, r.f.name)); r.logged = true end
      elseif t >= r.t + r.d + 0.3 then r.f:clear_value(); r.done = true end
    end
  end
  local tp = { false, false }
  for _, f in ipairs(fire) do
    if t >= f.t0 and t < f.t1 and ((t - f.t0) % f.per) < 0.05 then tp[f.p] = true end
  end
  for p = 1, 2 do if tp[p] then trig[p]:set_value(1) else trig[p]:clear_value() end end
  for _, s in ipairs(gunat) do if t >= s.t then gun = s.v end end
  if statef and t >= nst then
    local vs = {}
    for _, a in ipairs(watch) do vs[#vs + 1] = string.format("%02x", sp:read_u8(a)) end
    statef:write(string.format("%.6f %s\n", t, table.concat(vs, " ")))
    nst = nst + 0.5
  end
  if dumpf and t >= nd then
    dumpf:write("VCDP", string.pack("<I4I4", math.floor(t * 1000), scr:frame_number()))
    dumpf:write(sp:read_range(0x500000, 0x500000 + LEN - 1, 8))
    nd = nd + EVERY
  end
  if t >= ns then scr:snapshot(string.format("v%06.1f.png", t)); ns = ns + SNAPE end
  if t >= T_END then
    if iolog then iolog:write(string.format("mismatches against the ports: %d\n", nmism)); iolog:close() end
    if dumpf then dumpf:close() end; if wlog then wlog:close() end; if statef then statef:close() end
    m:exit()
  end
end)
