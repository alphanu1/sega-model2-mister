-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- R931: VIRTUA FIGHTER 2, THE WIN POSE SKIPPED (GitHub #17's reproducer: "after
-- landing the final blow ... press Start right after ... it will often
-- crash"). A credit, then player 1 fights with a fixed pseudo-random
-- sequence (as mame_m2_vf2_play.lua) while Start is tapped every SK_EVERY
-- frames for the rest of the session, so every K.O. is followed by a press
-- within a few frames. Logs what the i960 does at the copro and video
-- control ports frame by frame, and the inputs for tb_m2_boot's M2_INSCHED.
--
--   SK_COIN=<s,..>  coin times (two coins each: one credit; default 15)
--   SK_EVERY=<n>    a Start press every <n> frames from SK_COIN + 3 s (default 8;
--                   0: only the credit's own presses)
--   SK_HOLD=<n>     frames each press is held (default 2)
--   SK_IDLE=1       player 1 does nothing (the CPU wins every round)
--   SK_TEND=<s>     exit at <s> (default 200)
--   SK_LOG=<file>   per frame: "F <frame> <t> ip <ip> in <in0> <in1> fn <n> fifo <n>
--                   pop <n> geo <n> rm <n>"; events: "C" copro_ctl1 writes,
--                   "Q" fifo_control reads, "G" geo_ctl1 writes, "E" irq enable
--                   writes, "R" copro_ctl1 reads
--   SK_SNAP=<s>     a snapshot every <s> seconds (default 0: none)
--   INREC=<file>    the cabinet's port values each frame (M2_INSCHED format)
--   SK_CHAIN=<file> a second autoboot script run in the same session
--
-- Everything written is ROM-derived and stays outside the repository.
local m = manager.machine
local ports = m.ioport.ports
local scr = m.screens[":screen"]
local cpu = m.devices[":maincpu"]
local msp = cpu.spaces["program"]
local COINS = {}
for v in string.gmatch(os.getenv("SK_COIN") or "15", "[^,]+") do COINS[#COINS + 1] = tonumber(v) end
local COIN = COINS[1]
local EVERY = tonumber(os.getenv("SK_EVERY") or "8")
local HOLD = tonumber(os.getenv("SK_HOLD") or "2")
local IDLE = os.getenv("SK_IDLE") == "1"
local T_END = tonumber(os.getenv("SK_TEND") or "200")
local SNAP = tonumber(os.getenv("SK_SNAP") or "0")
local L = os.getenv("SK_LOG") and assert(io.open(os.getenv("SK_LOG"), "w"))
local IR = os.getenv("INREC") and assert(io.open(os.getenv("INREC"), "w"))

local function field(p, name)
  local f = ports[p] and ports[p].fields[name]
  if not f then print("VF2SKIP no field " .. p .. " / " .. name) end
  return f
end
local F = {
  coin = field(":IN0", "Coin 1"), start = field(":IN0", "1 Player Start"),
  p = field(":IN1", "P1 Punch"), k = field(":IN1", "P1 Kick"), g = field(":IN1", "P1 Guard"),
  dn = field(":IN1", "P1 Down"), up = field(":IN1", "P1 Up"),
  rt = field(":IN1", "P1 Right"), lt = field(":IN1", "P1 Left"),
}
local function set(f, v) if f then f:set_value(v) end end

local function fr() return scr:frame_number() end
local function ev(s) if L then L:write(string.format("%s %d %.4f ip %08x\n", s, fr(), emu.time(), cpu.state["ip"].value)) end end

-- counts per frame
local nfn, nfifo, npop, ngeo, nrm = 0, 0, 0, 0, 0
TAP_FN = msp:install_write_tap(0x880000, 0x887fff, "sk_fn", function(off, data, mask)
  if off < 0x884000 then nfn = nfn + 1 else nfifo = nfifo + 1 end
end)
TAP_POP = msp:install_read_tap(0x884000, 0x887fff, "sk_pop", function(off, data, mask) npop = npop + 1 end)
TAP_GEO = msp:install_write_tap(0x800000, 0x807fff, "sk_geo", function(off, data, mask) ngeo = ngeo + 1 end)
TAP_RM = msp:install_write_tap(0x10000000, 0x101fffff, "sk_rm", function(off, data, mask)
  nrm = nrm + 1; ev(string.format("M %08x %08x %08x", off, data, mask))
end)
TAP_CW = msp:install_write_tap(0x980000, 0x98000f, "sk_cw", function(off, data, mask)
  local k = ({[0] = "C", [4] = "W4", [8] = "G", [12] = "V"})[off & 0xc]
  ev(string.format("%s %08x %08x %08x", k, off, data, mask))
end)
TAP_CR = msp:install_read_tap(0x980000, 0x98000f, "sk_cr", function(off, data, mask)
  local k = ({[0] = "R", [4] = "Q", [8] = "R8", [12] = "RV"})[off & 0xc]
  ev(string.format("%s %08x %08x", k, off, data))
end)
TAP_IE = msp:install_write_tap(0xe80000, 0xe80007, "sk_ie", function(off, data, mask)
  if off >= 0xe80004 then ev(string.format("E %08x %08x", data, mask)) end
end)

local seed = 12345
local function rnd(n) seed = (seed * 1103515245 + 12345) & 0x7fffffff; return (seed >> 8) % n end
local STICK = { {}, {"lt"}, {"rt"}, {"up"}, {"dn"}, {"up", "lt"}, {"up", "rt"},
                {"dn", "lt"}, {"dn", "rt"}, {"rt"}, {"rt"} }
local step_t, next_snap = -1, 0
local start_f0 = nil
SK_F = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  local f = fr()
  local coin, start = 0, 0
  for _, c in ipairs(COINS) do
    if (t >= c and t < c + 0.2) or (t >= c + 0.6 and t < c + 0.8) then coin = 1 end
  end
  if t >= COIN + 3 and t < COIN + 3.2 then start = 1 end
  if t >= COIN + 3 and not start_f0 then start_f0 = f end
  if start_f0 and EVERY > 0 and ((f - start_f0) % EVERY) < HOLD then start = 1 end
  set(F.coin, coin); set(F.start, start)
  if start_f0 and not IDLE then
    local s = math.floor(t * 5)
    if s ~= step_t then
      step_t = s
      for _, k in ipairs({"dn", "up", "rt", "lt"}) do set(F[k], 0) end
      for _, k in ipairs(STICK[rnd(#STICK) + 1]) do set(F[k], 1) end
      local b = rnd(8)
      set(F.p, b & 1); set(F.k, (b >> 1) & 1); set(F.g, ((b >> 2) & 1) & rnd(2))
    end
  end
  if L then
    local function rd(p) return ports[p] and ports[p]:read() or 0xff end
    L:write(string.format("F %d %.4f ip %08x in %02x %02x fn %d fifo %d pop %d geo %d rm %d\n", f, t,
      cpu.state["ip"].value, rd(":IN0") & 0xff, rd(":IN1") & 0xff, nfn, nfifo, npop, ngeo, nrm))
  end
  nfn, nfifo, npop, ngeo, nrm = 0, 0, 0, 0, 0
  if IR then
    local function rd(p) return ports[p] and ports[p]:read() or 0xff end
    IR:write(string.format("%d %02x %02x %02x ff ff ff\n", f, rd(":IN0") & 0xff, rd(":IN1") & 0xff, rd(":IN2") & 0xff))
  end
  if SNAP > 0 and t >= next_snap then
    scr:snapshot(string.format("vf2_%06.1f.png", t))
    next_snap = next_snap + SNAP
  end
  if T_END >= 0 and t >= T_END then
    if L then L:close() end
    if IR then IR:close() end
    m:exit()
  end
end)

if os.getenv("SK_CHAIN") then dofile(os.getenv("SK_CHAIN")) end
