-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- VIRTUA COP 2's EXPERT STAGE BY SCRIPT (R954, GitHub #29): the train scene
-- with enemies, the same session every run, and a log of each vblank's work.
-- Two coins at 25 s, Start at 28, the gun on FILE 3 (EXPERT, gun 560,130 --
-- the gun's Y runs bottom to top) and the trigger at 33 s; from 37 s a shot
-- every 6 frames at a pseudo-random point (seeded), every 7th off-screen (the
-- reload); a coin every 12 s and Start every 1.5 s from 45 s take the
-- continues. The guns are forced through the 315-5649's mux read tap, as
-- sim/io/mame_m2_vcop2_play.lua does. In MAME 0.289 the subway platform is
-- ~40-95 s and the train ~100-160 s (vblanks ~5,750-9,200; a rendered list's
-- index is the vblank less ~792 there).
--   VD_TEND  end time (s, default 200)     VD_SNAP snapshot period (s, 0 none)
--   VD_SEL   "x,y" the stage box's gun position (default 560,130: EXPERT)
--   VD_LOG   file: per vblank -- frame, time, flips (0x803008), function-port
--            and FIFO-port pushes, output-FIFO reads, geometrizer writes,
--            buffer-RAM writes, and the game's own meter word 0x500014
--            (timer 0's count where the frame's work ended, 0x36d8)
--   VD_DUMP  file: work RAM 0x500000..+0x40000 every VD_EVERY s
-- The frame loop (MAME trace): the work ends with `call 0x36d8`, which stores
-- the meter and spins at 0x36fc / 0x3704 until the vblank counter (byte
-- 0x500000) changes -- so a frame over one vblank costs two.
-- Everything written is ROM-derived and stays outside the repository.
local m = manager.machine
local cpu = m.devices[":maincpu"]
local sp = cpu.spaces["program"]
local scr = m.screens[":screen"]
local ports = m.ioport.ports
local function fld(port, name)
  for n, f in pairs(ports[port].fields) do if n == name then return f end end
  error("no field " .. port .. " " .. name)
end
local coinf, startf = fld(":IN0", "Coin 1"), fld(":IN0", "1 Player Start")
local trigf = fld(":IN1", "P1 Trigger")
local TEND = tonumber(os.getenv("VD_TEND") or "200")
local SNAP = tonumber(os.getenv("VD_SNAP") or "1")
local selx, sely = (os.getenv("VD_SEL") or "560,130"):match("(%d+),(%d+)")
selx, sely = tonumber(selx), tonumber(sely)
local gun = { 400, 230, 400, 230 }
local function offbits(g)
  local o = 0
  if g[1] <= 137 + 24 or g[1] >= 630 - 24 or g[2] <= 36 + 19 or g[2] >= 425 - 19 then o = o | 1 end
  if g[3] <= 134 + 24 or g[3] >= 627 - 24 or g[4] <= 36 + 19 or g[4] >= 425 - 19 then o = o | 2 end
  return o
end
local mux = 0
VD_W = sp:install_write_tap(0x01c00014, 0x01c00017, "gunmux", function(off, data, mask)
  if (mask & 0xff) ~= 0 then mux = data & 0xff end
end)
VD_R = sp:install_read_tap(0x01c00018, 0x01c0001b, "gundata", function(off, data, mask)
  if (mask & 0xff) == 0 then return data end
  local b
  if mux < 8 then
    local v = ({ gun[2], gun[1], gun[4], gun[3] })[(mux >> 1) + 1]
    b = ((mux & 1) == 1) and ((v >> 8) & 0xff) or (v & 0xff)
  else
    b = 0xfc | offbits(gun)
  end
  return (data & 0xffffff00) | b
end)
-- per-vblank counters
local c = { flip = 0, fp = 0, fw = 0, fr = 0, geo = 0, bw = 0 }
VD_T1 = sp:install_write_tap(0x803008, 0x80300b, "flip", function() c.flip = c.flip + 1 end)
VD_T2 = sp:install_write_tap(0x880000, 0x883fff, "fp", function() c.fp = c.fp + 1 end)
VD_T3 = sp:install_write_tap(0x884000, 0x887fff, "fw", function() c.fw = c.fw + 1 end)
VD_T4 = sp:install_read_tap(0x884000, 0x887fff, "fr", function(o, d) c.fr = c.fr + 1; return d end)
VD_T5 = sp:install_write_tap(0x804000, 0x807fff, "geo", function() c.geo = c.geo + 1 end)
VD_T6 = sp:install_write_tap(0x900000, 0x97ffff, "bw", function() c.bw = c.bw + 1 end)
local log = os.getenv("VD_LOG") and assert(io.open(os.getenv("VD_LOG"), "w"))
if log then log:write("frame time flip fp fifo_w fifo_r geo buf_w meter\n") end
local dumpf = os.getenv("VD_DUMP") and assert(io.open(os.getenv("VD_DUMP"), "wb"))
local EVERY = tonumber(os.getenv("VD_EVERY") or "1")
local ns, nd = 0, 0
local shots, ph, pht = 0, 0, 0
local seed = 4321
local function rnd(n) seed = (seed * 1103515245 + 12345) & 0x7fffffff; return (seed >> 8) % n end
VD_F = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  local fr = scr:frame_number()
  if log then
    log:write(string.format("%d %.3f %d %d %d %d %d %d %d\n", fr, t, c.flip, c.fp, c.fw, c.fr, c.geo, c.bw, sp:read_u32(0x500014)))
  end
  for k in pairs(c) do c[k] = 0 end
  -- coins: two at 25 s, then one every 12 s from 60 s; start every 1.5 s from 28
  local coin = 0
  if (t >= 25 and t < 25.2) or (t >= 25.6 and t < 25.8) then coin = 1 end
  if t >= 60 and (t % 12) < 0.2 then coin = 1 end
  coinf:set_value(coin)
  local st = 0
  if t >= 28 and t < 29 and t < 28.3 then st = 1 end
  if t >= 45 and (t % 1.5) < 0.2 then st = 1 end
  startf:set_value(st)
  local tr = 0
  if t >= 30 and t < 37 then
    gun = { selx, sely, 400, 230 }
    if t >= 33 and t < 33.1 then tr = 1 end
  elseif t >= 37 then
    -- a frame-stepped pattern: 6 frames a shot (press 2), every 7th shot off-screen
    if fr ~= pht then
      pht = fr
      ph = ph + 1
      if ph >= 6 then ph = 0; shots = shots + 1
        if shots % 7 == 0 then gun = { 100, 20, 400, 230 }
        else gun = { 170 + rnd(420), 70 + rnd(320), 400, 230 } end
      end
    end
    if ph < 2 then tr = 1 end
  end
  if tr == 1 then trigf:set_value(1) else trigf:clear_value() end
  if dumpf and t >= nd then
    dumpf:write("VCDP", string.pack("<I4I4", math.floor(t * 1000), fr))
    dumpf:write(sp:read_range(0x500000, 0x500000 + 0x40000 - 1, 8))
    nd = nd + EVERY
  end
  if SNAP > 0 and t >= ns then scr:snapshot(string.format("v%06.1f.png", t)); ns = ns + SNAP end
  if t >= TEND then if log then log:close() end; if dumpf then dumpf:close() end; m:exit() end
end)
