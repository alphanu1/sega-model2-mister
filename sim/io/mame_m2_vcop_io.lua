-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- VIRTUA COP'S I/O BOARD (model1io2, TMPZ84C015, EPR-17181) IN MAME: WHAT THE
-- FIRMWARE TOUCHES (R839). Runs vcop / vcopa headless through boot, attract,
-- a coin, a start and a game with both guns swept and fired (a reload shot
-- off-screen every few seconds), and records:
--
--   summary.txt  every I/O Z80 data access by address outside its work RAM
--                (reads and writes, counts, first values), every on-die I/O
--                port access (CTC 0x10-13, SIO 0x18-1B, PIO 0x1C-1F, WDT
--                0xF0/F1, daisy 0xF4, anything else), the work-RAM extent,
--                data reads of the ROM by 1 KB page, the interrupt vector
--                fetches (IM 2 table reads) by vector with their spacing,
--                the FPGA (0x8100-0x810F) reads by offset and the bitstream
--                write count
--   io.log       the 315-5338A stream in order: "<t> W|R <off> <byte>" for
--                0x8000-0x800F, so a bench can rebuild the DPRAM writes
--   dpw.log      the DPRAM writes the board makes, rebuilt from that stream
--                ("<t> <dpram addr> <byte>"), first VC_DPN of them
--   sNNNN.png    a snapshot every VC_SNAP s
--
--   M2_MAME_OUT=<dir> VC_OUT=<dir> VC_TEND=240 VC_COIN=60 \
--     tools/m2b-mame.sh vcopa -autoboot_script sim/io/mame_m2_vcop_io.lua
--
-- Everything written is ROM-derived and stays outside the repository.

local out    = os.getenv("VC_OUT") or "."
local T_END  = tonumber(os.getenv("VC_TEND") or "240")
local T_COIN = tonumber(os.getenv("VC_COIN") or "60")
local SNAP   = tonumber(os.getenv("VC_SNAP") or "10")
local DPN    = tonumber(os.getenv("VC_DPN") or "200000")
local IOLOGT = tonumber(os.getenv("VC_IOLOGT") or "20")   -- io.log, gw.log only to this time
GUNFIX = (os.getenv("VC_GUNFIX") or "0") ~= "0"
local m      = manager.machine
local scr    = m.screens[":screen"]
local ports  = m.ioport.ports
local z80    = m.devices[":ioboard:iocpu"]
local zp     = z80.spaces["program"]
local zio    = z80.spaces["io"]

local f = assert(io.open(out .. "/fields.txt", "w"))
for k, p in pairs(ports) do
  for n, fl in pairs(p.fields) do
    f:write(string.format("%s\t%s\tmask %x\tdef %x\n", k, n, fl.mask, fl.defvalue))
  end
end
f:close()

VC_ACC = {}     -- ["R"/"W" .. addr] = {n, vals = {}}
VC_IOP = {}     -- on-die ports
VC_ROMPG = {}   -- data reads of ROM by 1 KB page
VC_VEC = {}     -- vector -> {n, last, dmin, dmax}
VC_RAM = { lo = 0x10000, hi = -1, wlo = 0x10000, whi = -1 }
VC_FPGA_W = 0
VC_FPGA_R = {}
local iol = assert(io.open(out .. "/io.log", "w"))
local dpl = assert(io.open(out .. "/dpw.log", "w"))
VC_DPN = 0
VC_SER, VC_ADR = 0, 0

local function note(tab, key, d)
  local e = tab[key]
  if not e then e = { n = 0, vals = {}, nv = 0 }; tab[key] = e end
  e.n = e.n + 1
  if not e.vals[d] and e.nv < 16 then e.vals[d] = true; e.nv = e.nv + 1 end
end

-- ROM data reads, including the IM 2 vector fetches (0x00E0-0x00FF)
VC_TR = zp:install_read_tap(0x0000, 0x7fff, "vcrom", function(o, d, mk)
  if o == 0x0a3a and VC_ISR0 then
    -- the handler's RETI (0x0a39 ED, 0x0a3a 4D): time in the handler
    local dt = emu.time() - VC_ISR0
    VC_ISRN = (VC_ISRN or 0) + 1; VC_ISRT = (VC_ISRT or 0) + dt
    if dt > (VC_ISRMAX or 0) then VC_ISRMAX = dt end
    VC_ISR0 = nil
  end
  if o >= 0xe0 and o <= 0xff then
    if (o & 1) == 0 then
      local t = emu.time()
      if o == 0xea then VC_ISR0 = t end
      local e = VC_VEC[o]
      if not e then e = { n = 0, last = t, dmin = 1e9, dmax = 0 }; VC_VEC[o] = e
      else
        local dt = t - e.last
        if dt < e.dmin then e.dmin = dt end
        if dt > e.dmax then e.dmax = dt end
        e.last = t
      end
      e.n = e.n + 1
    end
  else
    local pg = o >> 10
    VC_ROMPG[pg] = (VC_ROMPG[pg] or 0) + 1
  end
end)

-- the I/O window
VC_TIR = zp:install_read_tap(0x8000, 0xdfff, "vcior", function(o, d, mk)
  note(VC_ACC, string.format("R %04x", o), d)
  if o >= 0x8100 and o <= 0x810f then VC_FPGA_R[o - 0x8100] = (VC_FPGA_R[o - 0x8100] or 0) + 1 end
  if o <= 0x800f and emu.time() < IOLOGT then
    iol:write(string.format("%.6f R %x %02x\n", emu.time(), o & 0xf, d))
  end
end)
VC_TIW = zp:install_write_tap(0x8000, 0xdfff, "vciow", function(o, d, mk)
  note(VC_ACC, string.format("W %04x", o), d)
  if o >= 0x8100 and o <= 0x810f then VC_FPGA_W = VC_FPGA_W + 1 end
  if o <= 0x800f then
    if emu.time() < IOLOGT then
      iol:write(string.format("%.6f W %x %02x\n", emu.time(), o & 0xf, d))
    end
    local r = o & 0xf
    if r == 0xa then VC_SER = d
    elseif r == 0x9 then
      local w = nil
      if d == 0x00 then VC_ADR = (VC_ADR & 0xff00) | VC_SER
      elseif d == 0x01 then VC_ADR = (VC_ADR & 0x00ff) | (VC_SER << 8)
      elseif d == 0x07 then w = VC_ADR
      elseif d >= 0x70 and d <= 0x77 then w = d & 7 end
      if w and VC_DPN < DPN then
        VC_DPN = VC_DPN + 1
        dpl:write(string.format("%.6f %03x %02x\n", emu.time(), w & 0x7ff, VC_SER))
      end
    end
  end
end)

-- the game's side of the DPRAM (i960 0x01c00000, bytes 0 and 2 of each
-- dword), in time order, for a bench to replay: "<t> G <dpram addr> <byte>"
local mcpu = m.devices[":maincpu"]
local gpl = assert(io.open(out .. "/gw.log", "w"))
VC_TG = mcpu.spaces["program"]:install_write_tap(0x01c00000, 0x01c00fff, "vcgw", function(o, d, mk)
  if emu.time() >= IOLOGT then return end
  local a = ((o - 0x01c00000) >> 2) * 2
  if (mk & 0xff) ~= 0 then gpl:write(string.format("%.6f G %03x %02x\n", emu.time(), a, d & 0xff)) end
  if (mk & 0xff0000) ~= 0 then gpl:write(string.format("%.6f G %03x %02x\n", emu.time(), a + 1, (d >> 16) & 0xff)) end
end)

-- work RAM extent
VC_TRR = zp:install_read_tap(0xe000, 0xffff, "vcramr", function(o, d, mk)
  if o < VC_RAM.lo then VC_RAM.lo = o end
  if o > VC_RAM.hi then VC_RAM.hi = o end
end)
VC_TRW = zp:install_write_tap(0xe000, 0xffff, "vcramw", function(o, d, mk)
  if o < VC_RAM.wlo then VC_RAM.wlo = o end
  if o > VC_RAM.whi then VC_RAM.whi = o end
end)

-- on-die peripherals (the Z80 I/O space)
VC_TOR = zio:install_read_tap(0x0000, 0xffff, "vcpr", function(o, d, mk)
  note(VC_IOP, string.format("IN  %02x", o & 0xff), d)
end)
VC_TOW = zio:install_write_tap(0x0000, 0xffff, "vcpw", function(o, d, mk)
  note(VC_IOP, string.format("OUT %02x", o & 0xff), d)
end)

-- ------------------------------------------------------------------ inputs
local function set(p, n, v)
  local x = ports[p] and ports[p].fields[n]
  if x then x:set_value(v) end
end
local function first(p)
  return ports[p] and next(ports[p].fields)
end
local function find(p, pat)
  if not ports[p] then return nil end
  for n in pairs(ports[p].fields) do if n:find(pat) then return n end end
end
local F_P1X, F_P1Y = first(":P1_X"), first(":P1_Y")
local F_P2X, F_P2Y = first(":P2_X"), first(":P2_Y")
local F_T1 = find(":IN1", "P1 Trigger")
local F_T2 = find(":IN1", "P2 Trigger")
local function pulse(t, at, p, n, len)
  len = len or 0.2
  if t >= at and t < at + len then set(p, n, 1)
  elseif t >= at + len and t < at + 2 * len then set(p, n, 0) end
end

local next_snap = 0
VC_F = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  pulse(t, T_COIN, ":IN0", "Coin 1"); pulse(t, T_COIN + 1, ":IN0", "Coin 1")
  for k = 0, 6 do pulse(t, T_COIN + 3 + 2 * k, ":IN0", "1 Player Start") end
  if GUNFIX then
    -- VC_GUNFIX=1: both guns held still and nothing pressed, for the
    -- firmware bench (tb_m2_ioz80 type 2) to reproduce
    set(":P1_X", F_P1X, 0x100); set(":P1_Y", F_P1Y, 0x0a0)
    set(":P2_X", F_P2X, 0x200); set(":P2_Y", F_P2Y, 0x150)
  elseif t >= T_COIN + 3 then
    -- a slow sweep over the playfield; every 4 s a reload: off-screen + fire
    local reload = (t % 4) >= 3.6
    local x = 0x17c + math.floor(0xd0 * math.sin(t * 0.9))
    local y = 0x0e6 + math.floor(0x90 * math.sin(t * 1.3))
    if reload then x, y = 0x083, 0x024 end
    if F_P1X then set(":P1_X", F_P1X, x) end
    if F_P1Y then set(":P1_Y", F_P1Y, y) end
    if F_P2X then set(":P2_X", F_P2X, 0x179 + math.floor(0x60 * math.cos(t * 0.7))) end
    if F_P2Y then set(":P2_Y", F_P2Y, 0x0e8) end
    if F_T1 then set(":IN1", F_T1, ((t * 4) % 2 < 1) and 1 or 0) end
  end
  if SNAP > 0 and t >= next_snap then
    scr:snapshot(string.format("s%04d.png", math.floor(t)))
    next_snap = next_snap + SNAP
  end
  if t >= T_END then
    local s = assert(io.open(out .. "/summary.txt", "w"))
    s:write(string.format("system %s  time %.2f s  frame %d  coin at %d s\n",
      m.system.name, t, scr:frame_number(), T_COIN))
    s:write(string.format("fields: P1X %s P1Y %s T1 %s T2 %s\n",
      tostring(F_P1X), tostring(F_P1Y), tostring(F_T1), tostring(F_T2)))
    local function dump(title, tab)
      s:write(title .. "\n")
      local ks = {}
      for k in pairs(tab) do ks[#ks + 1] = k end
      table.sort(ks)
      for _, k in ipairs(ks) do
        local e = tab[k]
        local vs = {}
        for v in pairs(e.vals) do vs[#vs + 1] = string.format("%02x", v) end
        table.sort(vs)
        s:write(string.format("  %s  n %d  vals %s%s\n", k, e.n, table.concat(vs, " "),
          e.nv >= 16 and " ..." or ""))
      end
    end
    dump("I/O window (0x8000-0xDFFF):", VC_ACC)
    dump("on-die I/O ports:", VC_IOP)
    s:write(string.format("work RAM: reads %04x-%04x  writes %04x-%04x\n",
      VC_RAM.lo, VC_RAM.hi, VC_RAM.wlo, VC_RAM.whi))
    s:write("ROM data reads by 1 KB page:\n")
    for pg = 0, 31 do
      if VC_ROMPG[pg] then s:write(string.format("  %04x  %d\n", pg << 10, VC_ROMPG[pg])) end
    end
    s:write("IM 2 vector fetches:\n")
    for v = 0xe0, 0xfe, 2 do
      local e = VC_VEC[v]
      if e then
        s:write(string.format("  %02x  n %d  per s %.1f  spacing %.6f..%.6f s\n",
          v, e.n, e.n / t, e.dmin, e.dmax))
      end
    end
    if VC_ISRN then
      s:write(string.format("CTC handler (vector 0xea to its RETI): n %d mean %.1f us max %.1f us\n",
        VC_ISRN, 1e6 * VC_ISRT / VC_ISRN, 1e6 * VC_ISRMAX))
    end
    s:write(string.format("FPGA writes (bitstream) %d\n", VC_FPGA_W))
    for k = 0, 15 do
      if VC_FPGA_R[k] then s:write(string.format("  FPGA read +%x  %d\n", k, VC_FPGA_R[k])) end
    end
    s:write(string.format("DPRAM writes logged %d\n", VC_DPN))
    s:close(); iol:close(); dpl:close(); gpl:close()
    m:exit()
  end
end)
