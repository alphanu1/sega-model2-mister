-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- VIRTUA FIGHTER 2 (vf2, 2A-CRX) IN MAME: ITS BOOT, ITS SOUND HANDSHAKE AND
-- ITS I/O CONTROLLER. Headless, from power-on through attract, optionally a
-- coin, a start and some play, recording:
--
--   timeline.txt  per second: frame, IP sampled at the frame, flips (writes
--                 to geo read-start 0x00803008), geo writes, TGP FIFO writes,
--                 UART accesses, 315-5649 accesses, screen changes; plus the
--                 first of each event (first non-black screen, first geo
--                 write, first FIFO push after the TGP upload, first flip)
--   uart.log      every i960 access to the i8251 (0x01c80000-03): time,
--                 frame, IP, R/W, offset (0 data, 1 ctrl/status), value
--   irq.log       interrupt-enable writes (0x00e80004), ack writes and
--                 request reads (0x00e80000), first VF_IMAX of them
--   io.log        every 315-5649 write and every read whose value changed
--                 for that offset: time, IP, R/W, device offset, value
--   eeprom.txt    the 93C46 commands decoded off port A / port B
--   ctl.log       copro_ctl1, geo_ctl1, videoctl, render mode, timer writes
--   summary.txt   counts by offset and value for all of the above
--   tNNN.NN.png   snapshots, every VF_SNAP1 s to VF_TSPLIT, then every VF_SNAP2
--
-- VF_SUSPEND=1 suspends the sound 68000 from power-on (needs -debug and a
-- debugscript that says "go"): the sound board never answers.
-- VF_NOIRQ10=1 strips bit 10 from every interrupt-enable write: the UART's
-- TxRDY never interrupts the i960, as if the UART never became ready.
-- VF_MAP=1 also writes map.txt: every i960 data access from 0x00200000 up,
-- by 4 KB page, before and after the coin (slow: every access is counted),
-- and every exact address in pages only partly mapped (register pages).
-- VF_IOALL=<s> logs every 315-5649 read (not only changes) before that time.
--
--   M2_MAME_OUT=<dir> VF_OUT=<dir> VF_TEND=90 [VF_COIN=60] [VF_SUSPEND=1] \
--     tools/m2b-mame.sh vf2 -skip_gameinfo -autoboot_script sim/io/mame_m2_vf2_boot.lua
--
-- MAME 0.289's vf2 also needs the billboard's epr-18022.ic2 (segabill). Its
-- Z80 only reads a latch port E writes, nothing flows back to the i960, so a
-- 64 KB zero-filled stand-in under <dir>/segabill/ (added with -rompath
-- "$HOME/roms/Model2;<dir>") runs the set with a checksum warning.
--
-- Everything written is ROM-derived and stays outside the repository.

local out    = os.getenv("VF_OUT") or "."
local T_END  = tonumber(os.getenv("VF_TEND") or "90")
local T_COIN = tonumber(os.getenv("VF_COIN") or "0")
local SNAP1  = tonumber(os.getenv("VF_SNAP1") or "0.5")
local SNAP2  = tonumber(os.getenv("VF_SNAP2") or "5")
local TSPLIT = tonumber(os.getenv("VF_TSPLIT") or "40")
local UMAX   = tonumber(os.getenv("VF_UMAX") or "60000")
local IMAX   = tonumber(os.getenv("VF_IMAX") or "4000")
local IOALL  = tonumber(os.getenv("VF_IOALL") or "0")       -- io.log: every read before this time
local NOIRQ10 = (os.getenv("VF_NOIRQ10") or "0") ~= "0"
local m      = manager.machine
local scr    = m.screens[":screen"]
local ports  = m.ioport.ports
local cpu    = m.devices[":maincpu"]
local sp     = cpu.spaces["program"]
local function IP() return cpu.state["ip"].value end
local function FR() return scr:frame_number() end

if (os.getenv("VF_SUSPEND") or "0") ~= "0" then
  m.debugger:command("suspend :audiocpu")
end

local tl  = assert(io.open(out .. "/timeline.txt", "w"))
local ul  = assert(io.open(out .. "/uart.log", "w"))
local il  = assert(io.open(out .. "/irq.log", "w"))
local iol = assert(io.open(out .. "/io.log", "w"))
local cl  = assert(io.open(out .. "/ctl.log", "w"))
local el  = assert(io.open(out .. "/eeprom.txt", "w"))

-- per-second counters
VF_SEC = {}
local function bump(k, n)
  local s = math.floor(emu.time())
  local e = VF_SEC[s]
  if not e then e = {}; VF_SEC[s] = e end
  e[k] = (e[k] or 0) + (n or 1)
end
VF_FIRST = {}
local function first(k, extra)
  if not VF_FIRST[k] then
    VF_FIRST[k] = string.format("t %.4f frame %d ip %08x %s", emu.time(), FR(), IP(), extra or "")
    tl:write("FIRST " .. k .. " " .. VF_FIRST[k] .. "\n"); tl:flush()
  end
end
-- (key -> {n, vals})
VF_CNT = {}
local function note(key, d)
  local e = VF_CNT[key]
  if not e then e = { n = 0, vals = {}, nv = 0 }; VF_CNT[key] = e end
  e.n = e.n + 1
  if d and not e.vals[d] then
    if e.nv < 24 then e.vals[d] = 1; e.nv = e.nv + 1 end
  elseif d then e.vals[d] = e.vals[d] + 1 end
end

-- ------------------------------------------------------------ the i8251
VF_UN = 0
local function uart(rw, o, d, mk)
  local lanes = {}
  if (mk & 0x000000ff) ~= 0 then lanes[#lanes + 1] = { 0, d & 0xff } end
  if (mk & 0x00ff0000) ~= 0 then lanes[#lanes + 1] = { 1, (d >> 16) & 0xff } end
  for _, l in ipairs(lanes) do
    VF_UN = VF_UN + 1
    bump("uart")
    note(string.format("uart %s %d ip %08x", rw, l[1], IP()), l[2])
    first("uart_" .. rw .. l[1], string.format("val %02x", l[2]))
    if VF_UN <= UMAX then
      ul:write(string.format("%.6f %6d ip %08x %s %d %02x  mask %08x\n", emu.time(), FR(), IP(), rw, l[1], l[2], mk))
    end
  end
  if #lanes == 0 then
    ul:write(string.format("%.6f %6d ip %08x %s ? mask %08x data %08x\n", emu.time(), FR(), IP(), rw, mk, d))
  end
end
VF_TUR = sp:install_read_tap(0x01c80000, 0x01c80003, "vfur", function(o, d, mk) uart("R", o, d, mk) end)
VF_TUW = sp:install_write_tap(0x01c80000, 0x01c80003, "vfuw", function(o, d, mk) uart("W", o, d, mk) end)

-- ------------------------------------------------------------ interrupts
VF_IN = 0
local function ilog(s)
  VF_IN = VF_IN + 1
  if VF_IN <= IMAX then il:write(s) end
end
VF_TIR = sp:install_read_tap(0x00e80000, 0x00e80007, "vfir", function(o, d, mk)
  local k = (o == 0x00e80000) and "intreq_r" or "intena_r"
  note(k, d); bump(k)
  ilog(string.format("%.6f %6d ip %08x R %s %08x\n", emu.time(), FR(), IP(), k, d))
end)
VF_TIW = sp:install_write_tap(0x00e80000, 0x00e80007, "vfiw", function(o, d, mk)
  local k = (o == 0x00e80000) and "intack_w" or "intena_w"
  if NOIRQ10 and k == "intena_w" and (d & 0x400) ~= 0 then
    -- VF_NOIRQ10=1: the enable for line 10 never lands, so the UART's TxRDY
    -- never interrupts -- a sound UART that never becomes ready
    note("intena_w bit 10 stripped", d)
    return d & ~0x400
  end
  note(k, d); bump(k)
  if k == "intena_w" then first("intena_w", string.format("%08x", d)) end
  ilog(string.format("%.6f %6d ip %08x W %s %08x mask %08x\n", emu.time(), FR(), IP(), k, d, mk))
end)

-- ------------------------------------------------------------ 315-5649
local PN = { [0] = "PA", "PB", "PC", "PD", "PE", "PF", "PG", "P7", "DIR", "S1O", "S2O", "S1I", "S2I", "SST",
  "MODE", "AN" }
local io_last = {}
-- EEPROM decode: PA bit0 ctrlmode, bit5 DI, bit6 CS, bit7 CLK; DO on PB bit5
local ee = { cs = 0, clk = 0, st = "idle", bits = 0, nb = 0, op = nil, data = 0, dob = {}, last_do = nil }
VF_EE = {}
local function ee_cmd(s)
  VF_EE[#VF_EE + 1] = s
  el:write(string.format("%.6f %6d ip %08x %s\n", emu.time(), FR(), IP(), s)); el:flush()
end
local function ee_pa(v)
  local cs, clk, di = (v >> 6) & 1, (v >> 7) & 1, (v >> 5) & 1
  if cs == 0 and ee.cs == 1 then
    if ee.st == "read" then
      ee_cmd(string.format("READ %02x end: DO after edges %s", ee.addr, table.concat(ee.dob)))
    elseif ee.st ~= "idle" and ee.st ~= "done" then
      ee_cmd(string.format("CS fell in state %s after %d bits (%x)", ee.st, ee.nb, ee.bits))
    end
    ee.st = "idle"; ee.nb = 0; ee.bits = 0
  end
  if cs == 1 and clk == 1 and ee.clk == 0 then
    -- rising edge
    if ee.st == "idle" then
      if di == 1 then ee.st = "hdr"; ee.nb = 0; ee.bits = 0 end
    elseif ee.st == "hdr" then
      ee.bits = (ee.bits << 1) | di; ee.nb = ee.nb + 1
      if ee.nb == 8 then
        local op, a = ee.bits >> 6, ee.bits & 0x3f
        ee.addr = a
        if op == 2 then ee.st = "read"; ee.dob = {}
        elseif op == 1 then ee.st = "wdata"; ee.nb = 0; ee.data = 0
        elseif op == 3 then ee_cmd(string.format("ERASE %02x", a)); ee.st = "done"
        else
          local sub = a >> 4
          if sub == 0 then ee_cmd("EWDS") ; ee.st = "done"
          elseif sub == 1 then ee.st = "wall"; ee.nb = 0; ee.data = 0
          elseif sub == 2 then ee_cmd("ERAL"); ee.st = "done"
          else ee_cmd("EWEN"); ee.st = "done" end
        end
      end
    elseif ee.st == "read" then
      ee.dob[#ee.dob + 1] = ee.last_do and tostring(ee.last_do) or "?"
      ee.last_do = nil
    elseif ee.st == "wdata" or ee.st == "wall" then
      ee.data = (ee.data << 1) | di; ee.nb = ee.nb + 1
      if ee.nb == 16 then
        if ee.st == "wdata" then ee_cmd(string.format("WRITE %02x = %04x", ee.addr, ee.data))
        else ee_cmd(string.format("WRAL %04x", ee.data)) end
        ee.st = "done"
      end
    end
  end
  ee.cs, ee.clk = cs, clk
end

local function io_acc(rw, n, v)
  local k = string.format("io %s %02x %s", rw, n, PN[n] or "?")
  note(k, v); bump("io")
  bump("io" .. rw .. string.format("%02x", n))
  if rw == "W" then
    iol:write(string.format("%.6f %6d ip %08x W %02x %-4s %02x\n", emu.time(), FR(), IP(), n, PN[n] or "?", v))
    if n == 0 then ee_pa(v) end
  else
    if n == 1 and ee.st == "read" and ee.last_do == nil then ee.last_do = (v >> 5) & 1 end
    if io_last[n] ~= v or emu.time() < IOALL then
      iol:write(string.format("%.6f %6d ip %08x R %02x %-4s %02x\n", emu.time(), FR(), IP(), n, PN[n] or "?", v))
      io_last[n] = v
    end
  end
end
local function io_tap(rw, o, d, mk)
  local base = ((o - 0x01c00000) >> 2) * 2
  if o >= 0x01c00020 then
    note(string.format("io %s %08x (outside 315-5649)", rw, o), d)
    iol:write(string.format("%.6f %6d ip %08x %s %08x = %08x mask %08x\n", emu.time(), FR(), IP(), rw, o, d, mk))
    return
  end
  local any = false
  if (mk & 0x000000ff) ~= 0 then io_acc(rw, base, d & 0xff); any = true end
  if (mk & 0x00ff0000) ~= 0 then io_acc(rw, base + 1, (d >> 16) & 0xff); any = true end
  if not any then note(string.format("io %s %08x odd lane mask %08x", rw, o, mk), d) end
end
VF_TIOR = sp:install_read_tap(0x01c00000, 0x01c0007f, "vfior", function(o, d, mk) io_tap("R", o, d, mk) end)
VF_TIOW = sp:install_write_tap(0x01c00000, 0x01c0007f, "vfiow", function(o, d, mk) io_tap("W", o, d, mk) end)

-- ------------------------------------------------------------ geometry / TGP / control
VF_UP = { on = false, n = 0, uploads = {} }
VF_TGW = sp:install_write_tap(0x00800000, 0x00887fff, "vfgw", function(o, d, mk)
  if o == 0x00803008 then
    bump("flip"); first("flip_3008", string.format("%08x", d)); note("geo 3008 (read start)", d)
    cl:write(string.format("%.6f %6d ip %08x geo_rd_start %08x\n", emu.time(), FR(), IP(), d))
  elseif o == 0x00801008 then
    bump("geo_wstart"); note("geo 1008 (write start)", d)
  elseif o < 0x00804000 then
    bump("geo"); first("geo_write", string.format("off %x %08x", o - 0x00800000, d))
  elseif o < 0x00808000 then
    bump("geo_prg"); first("geo_prg_write", string.format("%08x", d))
  elseif o < 0x00884000 then
    bump("copro_fn"); first("copro_function_port", string.format("off %x %08x", o - 0x00880000, d))
  else
    if VF_UP.on then VF_UP.n = VF_UP.n + 1; bump("tgp_upload")
    else bump("fifo"); VF_FF = (VF_FF or 0) + 1; first("fifo_push_after_upload", string.format("%08x", d)) end
  end
end)
VF_TGR = sp:install_read_tap(0x00800000, 0x00887fff, "vfgr", function(o, d, mk)
  bump("geo_r"); note(string.format("geo/copro R %08x", o), nil)
end)
local function ctl(name, o, d, mk)
  cl:write(string.format("%.6f %6d ip %08x %s %08x mask %08x\n", emu.time(), FR(), IP(), name, d, mk))
  note(name, d)
end
VF_TCW = sp:install_write_tap(0x00980000, 0x0098003f, "vfcw", function(o, d, mk)
  if o == 0x00980000 then
    if (d & 0x80000000) ~= 0 and not VF_UP.on then VF_UP.on = true; VF_UP.n = 0
    elseif (d & 0x80000000) == 0 and VF_UP.on then
      VF_UP.on = false
      VF_UP.uploads[#VF_UP.uploads + 1] = string.format("t %.4f frame %d words %d", emu.time(), FR(), VF_UP.n)
    end
    ctl("copro_ctl1", o, d, mk)
  elseif o == 0x00980008 then ctl("geo_ctl1", o, d, mk)
  elseif o == 0x0098000c then ctl("videoctl", o, d, mk)
  else ctl(string.format("ctl %08x", o), o, d, mk) end
end)
VF_TCR = sp:install_read_tap(0x00980000, 0x0098003f, "vfcr", function(o, d, mk)
  note(string.format("ctl R %08x", o), d); bump("ctl_r")
end)
VF_TRM = sp:install_write_tap(0x10000000, 0x101fffff, "vfrm", function(o, d, mk)
  ctl(string.format("render_mode @%08x", o), o, d, mk)
end)
VF_TPC = sp:install_read_tap(0x10400000, 0x105fffff, "vfpc", function(o, d, mk)
  bump("polycount_r"); first("polycount_r", string.format("%08x", d))
end)
VF_TTW = sp:install_write_tap(0x00f00000, 0x00f0000f, "vftw", function(o, d, mk)
  ctl(string.format("timer W +%x", o - 0x00f00000), o, d, mk); bump("timer_w")
end)
VF_TTR = sp:install_read_tap(0x00f00000, 0x00f0000f, "vftr", function(o, d, mk)
  note(string.format("timer R +%x ip %08x", o - 0x00f00000, IP()), nil); bump("timer_r")
end)

-- ------------------------------------------------------------ the map
-- VF_MAP=1: every i960 data access from 0x00200000 up, counted by 4 KB page
-- and phase (before / after VF_COIN), with each page's lowest and highest
-- address. The boot ROM (0x0-0x1fffff) is left untapped: a tap there would
-- also see every instruction fetch.
local MAPPED = {
  { 0x00000000, 0x001fffff, "boot ROM" }, { 0x00200000, 0x0023ffff, "RAM 0x200000" },
  { 0x00500000, 0x005fffff, "workram" }, { 0x00800000, 0x00803fff, "geo" },
  { 0x00804000, 0x00807fff, "geo_prg" }, { 0x00880000, 0x00883fff, "copro function port" },
  { 0x00884000, 0x00887fff, "copro fifo" }, { 0x00900000, 0x0097ffff, "bufferram (+mirrors)" },
  { 0x00980000, 0x00980003, "copro_ctl1" }, { 0x00980004, 0x00980007, "fifo_control" },
  { 0x00980008, 0x0098000b, "geo_ctl1" }, { 0x0098000c, 0x0098000f, "videoctl" },
  { 0x00980030, 0x0098003f, "tgpid" }, { 0x00e00000, 0x00e00037, "cpu ctl (wait states)" },
  { 0x00e80000, 0x00e80007, "irq" }, { 0x00f00000, 0x00f0000f, "timers" },
  { 0x01000000, 0x0100ffff, "tile" }, { 0x01100000, 0x0110ffff, "tile mirror" },
  { 0x01010000, 0x0101ffff, "tile mirror" }, { 0x01110000, 0x0111ffff, "tile mirror" },
  { 0x01020000, 0x01020003, "ABSEL" }, { 0x01120000, 0x01120003, "ABSEL mirror" },
  { 0x01040000, 0x01040001, "xhout" }, { 0x01140000, 0x01140001, "xhout mirror" },
  { 0x01060000, 0x01060001, "xvout" }, { 0x01160000, 0x01160001, "xvout mirror" },
  { 0x01070000, 0x01070003, "vsync switch" }, { 0x01170000, 0x01170003, "vsync switch mirror" },
  { 0x01080000, 0x010fffff, "tile char" }, { 0x01180000, 0x011fffff, "tile char mirror" },
  { 0x01800000, 0x01803fff, "palette" }, { 0x01810000, 0x0181bfff, "colorxlat" },
  { 0x0181c000, 0x0181c003, "zclip" }, { 0x01a00000, 0x01a04003, "comms" }, { 0x01a10000, 0x01a14003, "comms mirror" },
  { 0x01c00000, 0x01c0001f, "315-5649" }, { 0x01c00040, 0x01c00043, "0x01c00040 nopw" },
  { 0x01c80000, 0x01c80003, "i8251" }, { 0x01d00000, 0x01d03fff, "backup RAM" },
  { 0x02000000, 0x03ffffff, "main_data" }, { 0x06000000, 0x06ffffff, "main_data extra" },
  { 0x10000000, 0x101fffff, "render mode" }, { 0x10400000, 0x105fffff, "polygon count" },
  { 0x10800000, 0x10800003, "polycount nopr" },
  { 0x11600000, 0x1167ffff, "fb A" }, { 0x11680000, 0x116fffff, "fb B" },
  { 0x12000000, 0x123fffff, "texture 0 (+mirror)" }, { 0x12400000, 0x127fffff, "texture 1 (+mirror)" },
  { 0x12800000, 0x1281ffff, "luma" },
}
local function label(a)
  for _, r in ipairs(MAPPED) do if a >= r[1] and a <= r[2] then return r[3] end end
  return "UNMAPPED"
end
VF_MAPT = { [0] = {}, [1] = {} }
VF_UNM = {}
-- pages not wholly inside one mapped range (register pages, gaps): every
-- dword address in them is counted exactly, so an unmapped register next to
-- a mapped one is not hidden by the page count
VF_PART = {}
VF_EXACT = {}
local function partial(pg)
  local v = VF_PART[pg]
  if v == nil then
    local a, b = pg << 12, (pg << 12) | 0xfff
    v = true
    for _, r in ipairs(MAPPED) do if r[1] <= a and r[2] >= b then v = false; break end end
    VF_PART[pg] = v
  end
  return v
end
local function maptap(rw, o, mk)
  local ph = (T_COIN > 0 and emu.time() >= T_COIN) and 1 or 0
  if partial(o >> 12) then
    local k = string.format("%d %s %08x mask %08x", ph, rw == 1 and "W" or "R", o, mk)
    local e = VF_EXACT[k]
    if not e then e = { 0, emu.time(), IP() }; VF_EXACT[k] = e end
    e[1] = e[1] + 1
  end
  local k = (o >> 12) * 2 + rw
  local tb = VF_MAPT[ph]
  local e = tb[k]
  if not e then
    e = { 0, o, o }; tb[k] = e
    if label(o) == "UNMAPPED" or (rw == 1 and o >= 0x02000000 and o <= 0x06ffffff) then
      local key = string.format("%s %08x", rw == 1 and "W" or "R", o)
      if not VF_UNM[key] then
        VF_UNM[key] = string.format("t %.4f ip %08x mask %08x", emu.time(), IP(), mk)
      end
    end
  end
  e[1] = e[1] + 1
  if o < e[2] then e[2] = o end
  if o > e[3] then e[3] = o end
end
if (os.getenv("VF_MAP") or "0") ~= "0" then
  VF_TMR = sp:install_read_tap(0x00200000, 0xffffffff, "vfmr", function(o, d, mk) maptap(0, o, mk) end)
  VF_TMW = sp:install_write_tap(0x00200000, 0xffffffff, "vfmw", function(o, d, mk) maptap(1, o, mk) end)
end
local function map_dump()
  local f2 = assert(io.open(out .. "/map.txt", "w"))
  for ph = 0, 1 do
    f2:write(string.format("PHASE %d (%s)\n", ph, ph == 0 and "before coin" or "after coin"))
    -- by region
    local reg = {}
    local ks = {}
    for k, e in pairs(VF_MAPT[ph]) do
      ks[#ks + 1] = k
      local nm = label((k >> 1) << 12)
      local key = nm .. ((k & 1) == 1 and " W" or " R")
      local r = reg[key]
      if not r then r = { 0, e[2], e[3], 0 }; reg[key] = r end
      r[1] = r[1] + e[1]; r[4] = r[4] + 1
      if e[2] < r[2] then r[2] = e[2] end
      if e[3] > r[3] then r[3] = e[3] end
    end
    local rk = {}
    for k in pairs(reg) do rk[#rk + 1] = k end
    table.sort(rk, function(a, b) return reg[a][2] < reg[b][2] end)
    f2:write("  region  count  lowest-highest dword  4KB-pages\n")
    for _, k in ipairs(rk) do
      local r = reg[k]
      f2:write(string.format("  %-28s %12d  %08x-%08x  %d\n", k, r[1], r[2], r[3], r[4]))
    end
    table.sort(ks)
    f2:write("  4KB pages: page R/W count lowest highest\n")
    for _, k in ipairs(ks) do
      local e = VF_MAPT[ph][k]
      f2:write(string.format("    %08x %s %10d %08x %08x %s\n", (k >> 1) << 12, (k & 1) == 1 and "W" or "R",
        e[1], e[2], e[3], label((k >> 1) << 12)))
    end
  end
  f2:write("EXACT addresses in partly-mapped pages: phase R/W addr mask  count first-t first-ip  label\n")
  local xs = {}
  for k in pairs(VF_EXACT) do xs[#xs + 1] = k end
  table.sort(xs)
  for _, k in ipairs(xs) do
    local e = VF_EXACT[k]
    local a = tonumber(k:match(" (%x+) mask"), 16)
    f2:write(string.format("  %s  %10d  %.4f  %08x  %s\n", k, e[1], e[2], e[3], label(a)))
  end
  f2:write("UNMAPPED / ROM-write first accesses per page:\n")
  local ks = {}
  for k in pairs(VF_UNM) do ks[#ks + 1] = k end
  table.sort(ks)
  for _, k in ipairs(ks) do f2:write("  " .. k .. " " .. VF_UNM[k] .. "\n") end
  f2:close()
end

-- ------------------------------------------------------------ inputs
local function set(p, n, v)
  local x = ports[p] and ports[p].fields[n]
  if x then x:set_value(v) end
end
local function pulse(t, at, p, n, len)
  len = len or 0.2
  if t >= at and t < at + len then set(p, n, 1)
  elseif t >= at + len and t < at + 2 * len then set(p, n, 0) end
end
local f = assert(io.open(out .. "/fields.txt", "w"))
for k, p in pairs(ports) do
  for n, fl in pairs(p.fields) do f:write(string.format("%s\t%s\tmask %x\tdef %x\n", k, n, fl.mask, fl.defvalue)) end
end
f:close()

-- ------------------------------------------------------------ the frame loop
local next_snap = 0
local prev_pix = nil
local black_seen = true
VF_IPH = {}
VF_SEC_IPS = {}
VF_F = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  local ip = IP()
  VF_IPH[ip & 0xfffffff0] = (VF_IPH[ip & 0xfffffff0] or 0) + 1
  local s = math.floor(t)
  local e = VF_SEC_IPS[s]
  if not e then e = {}; VF_SEC_IPS[s] = e end
  e[ip & 0xfffffff0] = (e[ip & 0xfffffff0] or 0) + 1
  -- screen content
  local px = scr:pixels()
  if px:find("[^%z\255]") then
    if black_seen then
      tl:write(string.format("SCREEN non-black from t %.4f frame %d\n", t, FR())); tl:flush()
      first("screen_nonblack")
      black_seen = false
    end
  elseif not black_seen then
    tl:write(string.format("SCREEN black again at t %.4f frame %d\n", t, FR())); tl:flush()
    black_seen = true
  end
  if prev_pix and px ~= prev_pix then bump("scr_change") end
  -- the first frame with a real TGP load (over VF_3DMIN FIFO words in a frame)
  if (VF_FF or 0) > tonumber(os.getenv("VF_3DMIN") or "1000") then first("fifo_frame_over_3dmin", string.format("words %d", VF_FF)) end
  VF_FF = 0
  prev_pix = px
  -- inputs
  if T_COIN > 0 then
    pulse(t, T_COIN, ":IN0", "Coin 1"); pulse(t, T_COIN + 1, ":IN0", "Coin 1")
    for k = 0, 3 do pulse(t, T_COIN + 3 + 2 * k, ":IN0", "1 Player Start") end
    if t >= T_COIN + 12 then
      -- play: a punch / kick / guard cycle and the stick swung left and right
      local ph = (t - T_COIN) % 3
      set(":IN1", "P1 Punch", (ph < 0.15 or (ph >= 1.0 and ph < 1.15)) and 1 or 0)
      set(":IN1", "P1 Kick", (ph >= 0.5 and ph < 0.65) and 1 or 0)
      set(":IN1", "P1 Guard", (ph >= 2.0 and ph < 2.6) and 1 or 0)
      local sw = (t - T_COIN) % 8
      set(":IN1", "P1 Right", (sw < 2) and 1 or 0)
      set(":IN1", "P1 Left", (sw >= 4 and sw < 5.5) and 1 or 0)
      set(":IN1", "P1 Up", (sw >= 6 and sw < 6.3) and 1 or 0)
      set(":IN1", "P1 Down", (sw >= 7 and sw < 7.5) and 1 or 0)
    elseif t >= T_COIN + 8 then
      pulse(t, T_COIN + 8, ":IN1", "P1 Punch"); pulse(t, T_COIN + 10, ":IN1", "P1 Punch")
    end
  end
  if t >= next_snap then
    scr:snapshot(string.format("t%06.2f.png", t))
    tl:write(string.format("SNAP t %.2f frame %d ip %08x\n", t, FR(), ip))
    next_snap = next_snap + ((t < TSPLIT) and SNAP1 or SNAP2)
  end
  if t >= T_END then
    -- per-second table
    tl:write("\nPER SECOND\n")
    local keys = { "flip", "geo", "geo_wstart", "geo_prg", "copro_fn", "fifo", "tgp_upload", "polycount_r", "uart",
      "intreq_r", "intack_w", "intena_w", "io", "ioR01", "ioR02", "ioR03", "ioR06", "ioW00", "ioW04", "ioW05", "timer_w", "timer_r",
      "scr_change" }
    tl:write("sec  " .. table.concat(keys, " ") .. "  top-ip\n")
    for s2 = 0, math.floor(t) do
      local e2 = VF_SEC[s2] or {}
      local row = {}
      for _, k in ipairs(keys) do row[#row + 1] = tostring(e2[k] or 0) end
      local best, bn = 0, 0
      for a, n in pairs(VF_SEC_IPS[s2] or {}) do if n > bn then best, bn = a, n end end
      tl:write(string.format("%3d  %s  %08x(%d)\n", s2, table.concat(row, " "), best, bn))
    end
    tl:close()
    local sm = assert(io.open(out .. "/summary.txt", "w"))
    sm:write(string.format("system %s time %.2f s frame %d coin %s suspend %s\n", m.system.name, t, FR(),
      tostring(T_COIN), os.getenv("VF_SUSPEND") or "0"))
    sm:write(string.format("uart accesses %d, irq accesses %d\n", VF_UN, VF_IN))
    local acpu = m.devices[":audiocpu"]
    if acpu then
      sm:write(string.format("audiocpu PC at end %06x\n", acpu.state["PC"].value))
    end
    sm:write("TGP uploads:\n")
    for _, u in ipairs(VF_UP.uploads) do sm:write("  " .. u .. "\n") end
    if VF_UP.on then sm:write(string.format("  still uploading, %d words\n", VF_UP.n)) end
    sm:write("first events:\n")
    local ks = {}
    for k in pairs(VF_FIRST) do ks[#ks + 1] = k end
    table.sort(ks)
    for _, k in ipairs(ks) do sm:write(string.format("  %-24s %s\n", k, VF_FIRST[k])) end
    sm:write("counts (key, n, values:count):\n")
    ks = {}
    for k in pairs(VF_CNT) do ks[#ks + 1] = k end
    table.sort(ks)
    for _, k in ipairs(ks) do
      local e2 = VF_CNT[k]
      local vs = {}
      for v, c in pairs(e2.vals) do vs[#vs + 1] = string.format("%x:%d", v, c) end
      table.sort(vs)
      sm:write(string.format("  %-44s n %8d  %s%s\n", k, e2.n, table.concat(vs, " "), e2.nv >= 24 and " ..." or ""))
    end
    sm:write("IP at frame end, top 40 (16-byte buckets):\n")
    local ips = {}
    for a, n in pairs(VF_IPH) do ips[#ips + 1] = { a, n } end
    table.sort(ips, function(x, y) return x[2] > y[2] end)
    for i = 1, math.min(40, #ips) do sm:write(string.format("  %08x %d\n", ips[i][1], ips[i][2])) end
    sm:write("eeprom commands:\n")
    for _, c in ipairs(VF_EE) do sm:write("  " .. c .. "\n") end
    sm:close(); ul:close(); il:close(); iol:close(); cl:close(); el:close()
    if VF_TMR then map_dump() end
    m:exit()
  end
end)
