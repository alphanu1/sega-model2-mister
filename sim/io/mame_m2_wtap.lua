-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- EVERY i960 WRITE TO AN ADDRESS RANGE, with the IP and time (R844): which
-- code sets a word the core and MAME disagree about.
--
--   WT_LO=<hex> WT_HI=<hex> WT_OUT=<file> WT_TEND=<s> [WT_MAX=<n>]
local m = manager.machine
local cpu = m.devices[":maincpu"]
local sp = cpu.spaces["program"]
local lo = tonumber(os.getenv("WT_LO"), 16)
local hi = tonumber(os.getenv("WT_HI"), 16)
local T_END = tonumber(os.getenv("WT_TEND") or "10")
local MAX = tonumber(os.getenv("WT_MAX") or "2000")
local f = assert(io.open(assert(os.getenv("WT_OUT")), "w"))
WT_N = 0
WT_T = sp:install_write_tap(lo, hi, "wtap", function(o, d, mk)
  WT_N = WT_N + 1
  if WT_N <= MAX then
    f:write(string.format("%.6f ip %08x W %08x = %08x mask %08x\n", emu.time(), cpu.state["ip"].value, o, d, mk))
  end
end)
WT_R = sp:install_read_tap(lo, hi, "rtap", function(o, d, mk)
  WT_N = WT_N + 1
  if WT_N <= MAX then
    f:write(string.format("%.6f ip %08x R %08x = %08x mask %08x\n", emu.time(), cpu.state["ip"].value, o, d, mk))
  end
end)
WT_F = emu.add_machine_frame_notifier(function()
  if emu.time() >= T_END then f:close(); m:exit() end
end)
