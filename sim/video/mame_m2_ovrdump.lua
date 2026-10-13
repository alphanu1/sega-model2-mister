-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- R823: dump BURSTS of consecutive frames of the 2D state for
-- tb_m2_video_ovr (make test_m2_video_ovr TEST_ARGS=+burst=<dir>).
-- The output is ROM-derived and never enters the repository.
--
--   OV_OUT=<dir> OV_BURSTS=start:count,... [OV_RACE=1] [OV_LAST=n]
--   [OV_SNAPEVERY=n] mame daytona -autoboot_script sim/video/mame_m2_ovrdump.lua
--
-- Each dumped frame gets <dir>/fNNNNN/{tile,palette}.bin, char.bin on the
-- first frame of a burst, the char words written during that frame
-- (charwr.txt; the tap saw none in any frame dumped for R823, which was not
-- cross-checked), and a snapshot.
-- Move each burst into its own directory before handing it to the bench.
-- OV_RACE=1 inserts a coin at frame 900, presses start every second from
-- 1000 to 2400 and floors the pedal: a beginner race starts by ~1950.
-- The subscriptions are GLOBALS: a local is collected and silently stops.
local out    = os.getenv("OV_OUT") or "/tmp/ov"
local snapev = tonumber(os.getenv("OV_SNAPEVERY") or "0")
local last   = tonumber(os.getenv("OV_LAST") or "3000")
local race   = os.getenv("OV_RACE") == "1"
-- bursts: "start:count,start:count"
local bursts = {}
for s, c in string.gmatch(os.getenv("OV_BURSTS") or "", "(%d+):(%d+)") do
  bursts[#bursts+1] = { s = tonumber(s), c = tonumber(c) }
end
local function in_burst(n)
  for _, b in ipairs(bursts) do
    if n >= b.s and n < b.s + b.c then return b, n == b.s end
  end
  return nil, false
end
os.execute("mkdir -p " .. out)
local sp = manager.machine.devices[":maincpu"].spaces["program"]
local ports = manager.machine.ioport.ports
local function fld(p, f) return ports[p] and ports[p].fields[f] end
local n = 0
local wr = {}          -- char words written this frame (32-bit offsets)
local wrn = 0
OV_TAP = sp:install_write_tap(0x01080000, 0x010fffff, "ovchar",
  function(offset, data, mask) wr[offset] = true; wrn = wrn + 1; return data end)

local function dump(name, base, size, path)
  local f = io.open(path, "wb")
  local chunk = {}
  for a = base, base + size - 4, 4 do
    chunk[#chunk+1] = string.pack("<I4", sp:read_u32(a))
    if #chunk >= 4096 then f:write(table.concat(chunk)); chunk = {} end
  end
  if #chunk > 0 then f:write(table.concat(chunk)) end
  f:close()
end

local held = {}
local function press(p, f, v)
  local x = fld(p, f); if x then x:set_value(v) end
end

OV_SUB = emu.add_machine_frame_notifier(function()
  n = n + 1
  if race then
    -- coin, start, then keep pressing start/VR1 through the menus; floor the pedal
    if n == 900 then press(":IN0", "Coin 1", 1) end
    if n == 906 then press(":IN0", "Coin 1", 0) end
    if n >= 1000 and (n % 60) < 4 and n < 2400 then press(":IN0", "1 Player Start", 1)
    elseif n >= 1000 and n < 2400 then press(":IN0", "1 Player Start", 0) end
    if n >= 1000 then press(":ACCEL", "P1 Pedal 1", 224) end
    if n >= 1000 then press(":STEER", "Paddle", 128 + math.floor(40 * math.sin(n / 90))) end
  end
  local b, first = in_burst(n)
  if b then
    local d = string.format("%s/f%05d", out, n)
    os.execute("mkdir -p " .. d)
    dump("tile", 0x01000000, 0x010000, d .. "/tile.bin")
    dump("palette", 0x01800000, 0x004000, d .. "/palette.bin")
    if first then dump("char", 0x01080000, 0x080000, d .. "/char.bin") end
    -- the char words written during the frame that just ended
    local g = io.open(d .. "/charwr.txt", "w")
    for off, _ in pairs(wr) do g:write(string.format("%x\n", off)) end
    g:close()
    manager.machine.screens[":screen"]:snapshot(string.format("ov_f%05d.png", n))
  end
  if snapev > 0 and n % snapev == 0 then
    manager.machine.screens[":screen"]:snapshot(string.format("s_f%05d.png", n))
    print(string.format("OV frame %d charwrites %d", n, wrn))
  end
  wr = {}; wrn = 0
  if n >= last then manager.machine:exit() end
end)
