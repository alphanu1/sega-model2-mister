-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- ZERO GUNNER WITHOUT ITS 315-5881: THE MRA'S CHECK PATCHES, PROVED IN MAME 0.289
-- (study R873). One run per configuration, the same inputs every time; the runs
-- are compared afterwards by sim/prot/zg_patch_cmp.py.
--
--   ZG_ZERO=1    every decrypt read (0x01d9000c) returns 0 -- the core today
--   ZG_IMG=<f>   the i960 program taken from the image the MRA builds
--                (tools/rom_csum.py <mra> <romdir> --out <f>): image 0..0x7ffff
--                and 0x2d40000.. (program 0x80000..0xfffff) written over MAME's
--                maincpu region before the boot copies it to work RAM; every
--                changed word is logged
--   ZG_RNGLOG=1 / ZG_RNGFIX=1  see the random number generator, below
--   ZG_TEND      end, emulated s (840)    ZG_SNAP   s between snapshots (2)
--   ZG_DUMP      s between RAM dumps (60) ZG_CYCLES credit times ("40,240,440,640")
--   ZG_OUT       output directory
--
-- Each cycle T: Coin 1 at T and T+1 (2 credits), 1P start T+3, 2P start T+4,
-- then both players weave and fire until game over; attract between cycles.
-- Outputs: run.txt (every check -- call site, subkey, address, the chip's four
-- words -- every write of the counter at 0x513000 and its readers), hash.txt
-- (each second: the counter, FNV hashes of work RAM 0x500000-0x53ffff "w0", the
-- code copy 0x540000-0x5fffff "w1" every 30 s, RAM 0x200000-0x23ffff "w2", the
-- buffer RAM 0x900000-0x91ffff "f"), wr_/lr_NNNN.bin dumps and snapshots.
--
--   ZG_OUT=<dir> M2_MAME_OUT=<dir> ZG_ZERO=1 ZG_IMG=<image> \
--     tools/m2b-mame.sh zeroguna -snapshot_directory <dir>/snap \
--       -autoboot_script sim/prot/mame_m2_zg_patch.lua
--
-- Everything written is ROM-derived and stays outside the repository. Start
-- each run with an empty nvram directory, or the EEPROM differs between runs.
local out = os.getenv("ZG_OUT") or "."
local TEND = tonumber(os.getenv("ZG_TEND") or "840")
local SNAP = tonumber(os.getenv("ZG_SNAP") or "2")
local DUMP = tonumber(os.getenv("ZG_DUMP") or "60")
local ZERO = os.getenv("ZG_ZERO") == "1"
local IMG = os.getenv("ZG_IMG")
local cyc = {}
for v in (os.getenv("ZG_CYCLES") or "40,240,440,640"):gmatch("[^,]+") do cyc[#cyc + 1] = tonumber(v) end
local m = manager.machine
local cpu = m.devices[":maincpu"]
local sp = cpu.spaces["program"]
local ports = m.ioport.ports
local reg = m.memory.regions[":maincpu"]
local log = assert(io.open(out .. "/run.txt", "w"))
local hl = assert(io.open(out .. "/hash.txt", "w"))

-- the check sites (program offsets; run from the copy at +0x500000)
local SITES = {0x443c8, 0x446e0, 0x449bc, 0x44bac, 0x44e14, 0x474dc, 0x475e8, 0x477f4, 0x4cc34, 0x55cd4, 0x56204}

if IMG then
  local f = assert(io.open(IMG, "rb"))
  local nd = 0
  local function load(io_, ro, len)
    f:seek("set", io_)
    local s = f:read(len)
    for i = 0, len - 4, 4 do
      local w = string.unpack("<I4", s, i + 1)
      local o = reg:read_u32(ro + i)
      if w ~= o then
        nd = nd + 1
        log:write(string.format("img %05x %08x -> %08x\n", ro + i, o, w))
        reg:write_u32(ro + i, w)
      end
    end
  end
  load(0, 0, 0x80000)
  load(0x2d40000, 0x80000, 0x80000)
  f:close()
  log:write(string.format("img words changed %d\n", nd))
end

local function field(name)
  for _, P in pairs(ports) do
    for n, f in pairs(P.fields) do if n == name then return f end end
  end
  log:write("missing field " .. name .. "\n")
end
local F = {}
for _, n in ipairs({"Coin 1", "1 Player Start", "2 Players Start", "P1 Button 1", "P2 Button 1",
    "P1 Up", "P1 Down", "P1 Left", "P1 Right", "P2 Up", "P2 Down", "P2 Left", "P2 Right"}) do
  F[n] = field(n)
end
local function set(n, v) if F[n] then F[n]:set_value(v) end end

local function ip() return cpu.state["ip"].value end
-- the decrypt routine (0x56b8d0): 0x56b8fc reads the status after the subkey
-- write, 0x56b934 is the loop's read of each word
local sess = nil
ZG_R = sp:install_read_tap(0x01d90000, 0x01d9ffff, "zgdev_r", function(o, d, mk)
  if (o & 0xfffc) == 0x0c then
    local p = ip()
    if p == 0x0056b8fc then
      sess = { t = emu.time(), g1 = cpu.state["g1"].value, g3 = cpu.state["g3"].value,
               rip = cpu.state["rip"].value, v = {} }
    end
    if p == 0x0056b934 and sess then
      sess.v[#sess.v + 1] = string.format("%04x", (d >> 16) & 0xffff)
      if #sess.v == 4 then
        log:write(string.format("%.4f CHECK rip=%08x key=%04x addr=%04x dec=%s%s\n", sess.t, sess.rip,
          sess.g1, sess.g3, table.concat(sess.v, " "), ZERO and " (zeroed)" or ""))
        sess = nil
      end
    end
    if ZERO then d = d & ~mk end
  end
  return d
end)
ZG_C = sp:install_write_tap(0x00513000, 0x00513003, "zgcnt_w", function(o, d, mk)
  log:write(string.format("%.4f CNT <- %08x ip=%08x\n", emu.time(), d, ip()))
  return d
end)
-- THE RANDOM NUMBER GENERATOR READS THE PROGRAM (0x54b430: seed += ROM[seed &
-- 0xffffc] + ...), so any patched ROM word changes the game's random sequence
-- whenever the seed lands on it. ZG_RNGLOG=1 logs every data read of the
-- eleven site words after the boot's copy (t >= 5 s); ZG_RNGFIX=1 also gives
-- those reads MAME's original word -- the program as if only the work-RAM copy
-- were patched -- which isolates everything else the patch might change.
local RNGLOG = os.getenv("ZG_RNGLOG") == "1" or os.getenv("ZG_RNGFIX") == "1"
local RNGFIX = os.getenv("ZG_RNGFIX") == "1"
if RNGLOG then
  ZG_RT = {}
  for _, a in ipairs(SITES) do
    local orig = (reg:read_u32(a) & 0x00ffffff) | 0x12000000
    ZG_RT[#ZG_RT + 1] = sp:install_read_tap(a, a + 3, string.format("zgrng%05x", a), function(o, d, mk)
      local t = emu.time()
      if t < 5 then return d end
      local nd = RNGFIX and orig or d
      log:write(string.format("%.6f ROMREAD %05x ip=%08x val=%08x ret=%08x\n", t, a, ip(), d, nd))
      return nd
    end)
  end
end
local rd, inlua = {}, false
ZG_CR = sp:install_read_tap(0x00513000, 0x00513003, "zgcnt_r", function(o, d, mk)
  if inlua then return d end
  local p = ip()
  if not rd[p] then rd[p] = true; log:write(string.format("%.4f CNT read ip=%08x val=%08x\n", emu.time(), p, d)) end
  return d
end)

local function hashrange(a0, a1)
  local h = 0xcbf29ce484222325
  for a = a0, a1 - 4, 4 do h = (h ~ sp:read_u32(a)) * 0x100000001b3 end
  return h
end
local function dump(name, a0, a1)
  local f = assert(io.open(out .. "/" .. name, "wb"))
  local t = {}
  for a = a0, a1 - 4, 4 do
    t[#t + 1] = string.pack("<I4", sp:read_u32(a))
    if #t == 4096 then f:write(table.concat(t)); t = {} end
  end
  f:write(table.concat(t)); f:close()
end

local done, nsnap, nhash, ndump, copied = false, SNAP, 1, DUMP, false
local PLAY = {"P1 Button 1", "P2 Button 1", "P1 Left", "P1 Right", "P1 Up", "P1 Down",
  "P2 Left", "P2 Right", "P2 Up", "P2 Down"}
ZG_F = emu.add_machine_frame_notifier(function()
  if done then return end
  local t = emu.time()
  local cin, s1, s2, play = 0, 0, 0, false
  for _, T in ipairs(cyc) do
    local dt = t - T
    if (dt >= 0 and dt < 0.2) or (dt >= 1 and dt < 1.2) then cin = 1 end
    if dt >= 3 and dt < 3.2 then s1 = 1 end
    if dt >= 4 and dt < 4.2 then s2 = 1 end
    if dt >= 5 then play = true end
  end
  set("Coin 1", cin); set("1 Player Start", s1); set("2 Players Start", s2)
  if play then
    local ph = math.floor(t * 4)
    set("P1 Button 1", ph % 2); set("P2 Button 1", (ph + 1) % 2)
    local sx, sy = math.sin(t * 0.7), math.sin(t * 1.1)
    set("P1 Left", sx < -0.3 and 1 or 0); set("P1 Right", sx > 0.3 and 1 or 0)
    set("P1 Up", sy < -0.3 and 1 or 0); set("P1 Down", sy > 0.3 and 1 or 0)
    set("P2 Left", sy < -0.3 and 1 or 0); set("P2 Right", sy > 0.3 and 1 or 0)
    set("P2 Up", sx < -0.3 and 1 or 0); set("P2 Down", sx > 0.3 and 1 or 0)
  else
    for _, n in ipairs(PLAY) do set(n, 0) end
  end
  if not copied and t >= 5 then
    copied = true
    for _, a in ipairs(SITES) do
      log:write(string.format("ramcopy %06x %08x rom %08x\n", 0x500000 + a, sp:read_u32(0x500000 + a), reg:read_u32(a)))
    end
  end
  inlua = true
  if t >= nhash then
    hl:write(string.format("%d cnt=%d w0=%016x w1=%016x w2=%016x f=%016x\n", nhash, sp:read_u32(0x513000),
      hashrange(0x500000, 0x540000), (nhash % 30 == 0) and hashrange(0x540000, 0x600000) or 0,
      hashrange(0x200000, 0x240000), hashrange(0x900000, 0x920000)))
    nhash = nhash + 1
  end
  if SNAP > 0 and t >= nsnap then m.video:snapshot(); nsnap = nsnap + SNAP end
  if DUMP > 0 and t >= ndump then
    dump(string.format("wr_%04d.bin", ndump), 0x500000, 0x600000)
    dump(string.format("lr_%04d.bin", ndump), 0x200000, 0x240000)
    ndump = ndump + DUMP
  end
  inlua = false
  if t >= TEND then
    done = true
    log:close(); hl:close()
    m:exit()
  end
end)
