-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- R1011: AN i960 CHECKPOINT FOR THE RTL (sim/i960ck). The core's i960 cannot
-- reach a game's race on the whole-core bench inside an hour, so its speed on
-- race code was inferred (R1005's s). This takes MAME to an instruction
-- boundary at a main-loop address, writes what the RTL needs to start there,
-- and logs every i960 access after it:
--
--   CK_OUT=<dir>     where everything goes (ROM-derived: outside the repository)
--   CK_T=<s>         the first pass through CK_IP at or after this time
--   CK_IP=<hex>      a main-loop address: no return can go above its frame,
--                    so MAME's register cache (not visible from Lua) is never
--                    needed; STCC 0x1164, the return from its flip-and-wait
--   CK_SECS=<s>      how long to log after the checkpoint (default 0.25)
--   CK_REGIONS=<lo-hi,...>  memory dumped at the checkpoint (hex, inclusive)
--   CK_GAME=<lua>    the game's timeline driver, run as usual (dofile)
--
-- Run with -debug -debugger none -debugscript <a file saying "go">: a
-- breakpoint stops the i960 exactly at CK_IP, and a periodic callback (which
-- MAME runs while the debugger is stopped) takes the checkpoint there.
--
-- Written: <dir>/state.txt (ip pc ac sat prcb pfp sp rip r3-r15 g0-g15 t),
-- <dir>/mem_<lo>.bin (bytes in address order), <dir>/acc.bin: one record an
-- access, <c1 kind I4 addr I4 data I4 mask I4 ip I4 pip d t> -- kind R or W, the
-- tap's offset and mask as MAME passes them, the i960's ip and pip at the
-- access, its local time -- and an 'F' record (addr = frame number) at each
-- video frame. An instruction fetch is a read whose address is the ip.
local m = manager.machine
local cpu = m.devices[":maincpu"]
local sp = cpu.spaces["program"]
local out = assert(os.getenv("CK_OUT"), "CK_OUT")
local T_CK = tonumber(os.getenv("CK_T") or "0")
local CK_IP = tonumber(os.getenv("CK_IP") or "1164", 16)
local SECS = tonumber(os.getenv("CK_SECS") or "0.25")
local REG = os.getenv("CK_REGIONS") or
  "0-1fffff,200000-23ffff,500000-5fffff,900000-97ffff,1000000-101ffff,1080000-10fffff,1800000-1803fff,1810000-181bfff,2000000-3ffffff"
local scr = m.screens[":screen"]
local st = {}
for _, n in ipairs({"ip", "pip", "pc", "ac", "sat", "prcb", "pfp", "sp", "rip", "r3", "r4", "r5", "r6", "r7", "r8", "r9",
                    "r10", "r11", "r12", "r13", "r14", "r15", "g0", "g1", "g2", "g3", "g4", "g5", "g6", "g7", "g8",
                    "g9", "g10", "g11", "g12", "g13", "g14", "fp"}) do st[n] = cpu.state[n] end
local IPS, PIPS = st["ip"], st["pip"]

local armed, done, t_ck, L, bpi = false, false, nil, nil, nil
local buf, nb = {}, 0
local pk = string.pack
local function flush() if L and nb > 0 then L:write(table.concat(buf)); buf = {}; nb = 0 end end
local function rec(k, o, d, mk)
  nb = nb + 1
  buf[nb] = pk("<c1I4I4I4I4I4d", k, o, d, mk, IPS.value, PIPS.value, emu.time())
  if nb >= 65536 then flush() end
end

local function checkpoint()
  local f = assert(io.open(out .. "/state.txt", "w"))
  for _, n in ipairs({"ip", "pc", "ac", "sat", "prcb", "pfp", "sp", "rip", "r3", "r4", "r5", "r6", "r7", "r8", "r9",
                      "r10", "r11", "r12", "r13", "r14", "r15", "g0", "g1", "g2", "g3", "g4", "g5", "g6", "g7", "g8",
                      "g9", "g10", "g11", "g12", "g13", "g14", "fp"}) do
    f:write(string.format("%s %08x\n", n, st[n].value))
  end
  t_ck = emu.time()
  f:write(string.format("t %.9f\nframe %d\n", t_ck, scr:frame_number()))
  f:close()
  for lo, hi in string.gmatch(REG, "(%x+)-(%x+)") do
    local a, b = tonumber(lo, 16), tonumber(hi, 16)
    local g = assert(io.open(string.format("%s/mem_%08x.bin", out, a), "wb"))
    local step = 0x100000
    for x = a, b, step do g:write(sp:read_range(x, math.min(x + step - 1, b), 8)) end
    g:close()
  end
  L = assert(io.open(out .. "/acc.bin", "wb"))
  CK_TR = sp:install_read_tap(0, 0xffffffff, "ck_r", function(o, d, mk) rec("R", o, d, mk); return d end)
  CK_TW = sp:install_write_tap(0, 0xffffffff, "ck_w", function(o, d, mk) rec("W", o, d, mk); return d end)
end

CK_P = emu.register_periodic(function()
  if armed and not done and m.debugger and m.debugger.execution_state == "stop" and IPS.value == CK_IP then
    done = true
    cpu.debug:bpclear(bpi)
    checkpoint()
    m.debugger.execution_state = "run"
  end
end)

CK_F = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  if not armed and t >= T_CK then armed = true; bpi = cpu.debug:bpset(CK_IP, "1", "") end
  if L then
    nb = nb + 1; buf[nb] = pk("<c1I4I4I4I4I4d", "F", scr:frame_number(), 0, 0, IPS.value, PIPS.value, t)
    if t >= t_ck + SECS then
      flush(); L:close(); L = nil
      m:exit()
    end
  end
end)

local g = os.getenv("CK_GAME")
if g then dofile(g) end
