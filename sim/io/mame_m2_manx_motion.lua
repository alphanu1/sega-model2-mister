-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- MANX TT'S MOTION-SLIDER CHECK IN MAME 0.289 (study R892). The game's boot
-- check (program 0x5f530) talks to the DX cabinet's drive board on the
-- 315-5649: command on port E (RAM copy 0x514034), status on port D (0x514035).
--   MX_MODE=answer  port D answers as the core does (M2_2A_MANX_MOTION): 0xCE
--                   while port E holds 0x3D, else 0xCD -- [MX_ANS_FROM=<s>]
--                   only from that time (MAME's 0xFF before it)
--   MX_MODE=test    port D as MAME (0xFF); Test held 1 s at MX_T1 and MX_T2
--                   (the workaround: Test, then Test again on the menu's EXIT)
--   MX_MODE=none    nothing
--   [MX_SETCNT=<v>] the control: 0x5bba00 (a frame counter the check reloads
--                   with 0x234 when it passes) written with v in the first
--                   frame of main state 1
-- Tg is the first frame of main state 0x5bba08 == MX_TGMS (1 the warning
-- screen, 3 the attract), or power-on with MX_GATE=0. Coin / start / throttle
-- / lean / brake / shift are timed from Tg (MX_COIN=<s,...>, two coins each;
-- "none" for no coins); before Tg coin and start are held released.
-- OUT=<dir>: st.txt (main / check state, port E and port D changes), hash.txt
-- (each second from Tg: FNV of work RAM 0x500000-0x5fffff with the motion
-- bytes masked, RAM 0x200000-0x23ffff, buffer RAM 0x900000-0x91ffff and the
-- EEPROM settings 0x514050-0x514087), MX_DUMP=<s,...> RAM dumps from Tg, and
-- snapshots every MX_SNAP s from Tg (MAME's -snapshot_directory).
--
-- R892's runs (fresh nvram/manxtt/eeprom: 128 bytes of 0xFF, the core's blank
-- 93C46): MX_TGMS=3 MX_TEND=240 MX_COIN=10,130 MX_DUMP=5,60,120,200,240 and
--   A   MX_MODE=answer
--   T   MX_MODE=test MX_T1=18 MX_T2=22
--   A2  MX_MODE=answer MX_ANS_FROM=22.99   (passes on T's frame, 1324)
--   TF  as T, MX_SETCNT=564
--     mame manxtt -autoboot_script sim/io/mame_m2_manx_motion.lua ...
--   python3 -I sim/io/manx_motion_cmp.py <A2 dir> <TF dir>
-- Everything written is ROM-derived and stays outside the repository.
local m = manager.machine
local cpu = m.devices[":maincpu"]
local sp = cpu.spaces["program"]
local scr = m.screens[":screen"]
local out = os.getenv("OUT")
local MODE = os.getenv("MX_MODE") or "none"
local T1 = tonumber(os.getenv("MX_T1") or "18")
local T2 = tonumber(os.getenv("MX_T2") or "22")
local TEND = tonumber(os.getenv("MX_TEND") or "60")      -- seconds after Tg
local SNAP = tonumber(os.getenv("MX_SNAP") or "2")
local GATE = (os.getenv("MX_GATE") or "1") == "1"
local TGMS = tonumber(os.getenv("MX_TGMS") or "1")
local COINS = {}
for v in string.gmatch(os.getenv("MX_COIN") or "10", "[%d%.]+") do COINS[#COINS + 1] = tonumber(v) end
local HASH = (os.getenv("MX_HASH") or "1") == "1"
local ANS_FROM = tonumber(os.getenv("MX_ANS_FROM") or "0")   -- answer mode: PD 0xFF (MAME's) before this time
local st = assert(io.open(out .. "/st.txt", "w"))
local hf = assert(io.open(out .. "/hash.txt", "w"))
local pe = 0xff
local pd_last = -1
local function ip() return cpu.state["ip"].value end
TW = sp:install_write_tap(0x01c00008, 0x01c0000b, "mx_pe", function(o, d, mk)
  if (mk & 0xff) ~= 0 then
    local v = d & 0xff
    if v ~= pe then st:write(string.format("%.6f PE %02x ip %08x\n", emu.time(), v, ip())) end
    pe = v
  end
  return d
end)
TR = sp:install_read_tap(0x01c00004, 0x01c00007, "mx_pd", function(o, d, mk)
  if (mk & 0x00ff0000) ~= 0 then
    if MODE == "answer" and emu.time() >= ANS_FROM then
      local a = (pe == 0x3d) and 0xce or 0xcd
      d = (d & ~0x00ff0000) | (a << 16)
    end
    local v = (d >> 16) & 0xff
    if v ~= pd_last then st:write(string.format("%.6f PD %02x ip %08x\n", emu.time(), v, ip())); pd_last = v end
  end
  return d
end)
local ports = m.ioport.ports
local function fld(p, pat) for k, f in pairs(ports[p].fields) do if k:find(pat) then return f end end end
local function fmask(p, mk) for _, f in pairs(ports[p].fields) do if f.mask == mk then return f end end end
local F = {
  test = fld(":IN0", "Service Mode"), svc = fld(":IN0", "Service 1"), coin = fld(":IN0", "Coin 1"),
  start = fmask(":IN0", 0x40), up = fmask(":IN1", 0x10), dn = fmask(":IN1", 0x20),
  thr = select(2, next(ports[":THROTTLE"].fields)), brk = select(2, next(ports[":BRAKE"].fields)),
  bank = select(2, next(ports[":BANK"].fields)),
}
local function set(f, v) if f then f:set_value(v) end end
local function pulse(t, at, len) return t >= at and t < at + len end
local function fnv(a0, a1)
  local h = 0x811c9dc5
  for a = a0, a1, 4 do
    local v = sp:read_u32(a)
    if a == 0x514034 then v = v & 0xffff0000 end   -- the motion command / status bytes
    h = ((h ~ v) * 0x01000193) & 0xffffffff
  end
  return h
end
local DUMPS = {}
for v in string.gmatch(os.getenv("MX_DUMP") or "", "[^,]+") do DUMPS[#DUMPS + 1] = tonumber(v) end
local ndump = 1
local function dump(tag)
  for _, r in ipairs({{0x500000, 0x5fffff, "w"}, {0x200000, 0x23ffff, "r"}, {0x900000, 0x91ffff, "b"}}) do
    local f = assert(io.open(string.format("%s/%s_%s.bin", out, r[3], tag), "wb"))
    local t = {}
    for a = r[1], r[2], 4 do t[#t + 1] = string.pack("<I4", sp:read_u32(a)) end
    f:write(table.concat(t)); f:close()
  end
end
local ms_last, cs_last = -1, -1
local SETCNT = os.getenv("MX_SETCNT") and tonumber(os.getenv("MX_SETCNT"))
local cnt_done = false
local Tg = nil
if not GATE then Tg = 0 end
local nsnap, nhash = 0, 0
FN = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  local ms = sp:read_u32(0x5bba08)
  local cs = sp:read_u32(0x5bba0c)
  if SETCNT and ms == 1 and not cnt_done then   -- control: the check's own 0x5bba00 = 0x234
    sp:write_u32(0x5bba00, SETCNT); cnt_done = true
  end
  if ms ~= ms_last or cs ~= cs_last then
    st:write(string.format("%.6f frame %d MS %d CS %d timer %d cab %d st %02x cmd %02x\n", t, scr:frame_number(), ms, cs,
      sp:read_u32(0x5bba00), sp:read_u8(0x51405a), sp:read_u8(0x514035), sp:read_u8(0x514034)))
    ms_last, cs_last = ms, cs
  end
  if not Tg and ms == TGMS then
    Tg = t; st:write(string.format("%.6f frame %d TG\n", t, scr:frame_number()))
  end
  local te = 0
  if MODE == "test" and (pulse(t, T1, 1.0) or pulse(t, T2, 1.0)) then te = 1 end
  set(F.test, te)
  if not Tg then set(F.coin, 0); set(F.start, 0) end
  if Tg then
    local u = t - Tg
    local coin, start, playing = 0, 0, false
    for _, c in ipairs(COINS) do
      if pulse(u, c, 0.2) or pulse(u, c + 0.6, 0.2) then coin = 1 end
      if u >= c + 3 and u < c + 103 and ((u - c - 3) % 2) < 0.2 then start = 1 end
      if u >= c + 3 then playing = true end
    end
    set(F.coin, coin); set(F.start, start)
    if playing then
      set(F.thr, ((u % 20) < 17) and 0xff or 0x00)
      set(F.brk, ((u % 20) >= 18) and 0xff or 0x00)
      set(F.bank, 0x80 + math.floor(0x70 * math.sin(u * 0.6)))
      set(F.up, ((u % 5) < 0.2) and 1 or 0)
      set(F.dn, ((u % 7) < 0.2) and 1 or 0)
    end
    if SNAP > 0 and u >= nsnap then scr:snapshot(string.format("g_%05.1f.png", u)); nsnap = nsnap + SNAP end
    if HASH and u >= nhash then
      hf:write(string.format("%6.1f frame %d w %08x r %08x b %08x set %08x st %02x cmd %02x ms %d\n", u, scr:frame_number(),
        fnv(0x500000, 0x5fffff), fnv(0x200000, 0x23ffff), fnv(0x900000, 0x91ffff), fnv(0x514050, 0x514087),
        sp:read_u8(0x514035), sp:read_u8(0x514034), ms))
      hf:flush()
      nhash = nhash + 1
    end
    if ndump <= #DUMPS and u >= DUMPS[ndump] then dump(string.format("%04d", DUMPS[ndump])); ndump = ndump + 1 end
    if u >= TEND then st:close(); hf:close(); m:exit() end
  elseif t > 120 then
    st:write("NO TG by 120 s\n"); st:close(); hf:close(); m:exit()
  end
end)
