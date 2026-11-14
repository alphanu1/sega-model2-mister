-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- R1005: SEGA TOURING CAR CHAMPIONSHIP (stcc, MAME 0.289) through qualifying
-- and into round 1 (sim/io/mame_m2_stcc_race.lua's own timeline, unchanged:
-- in R1005's runs the car came out AT and drove from 58 s, qualifying ran to
-- ~100 s and the race started at ~120 s with seven opponents; one earlier run
-- of the same timeline, with snapshots from 20 s, came out MT and never moved
-- -- not understood), with the i960's copro accesses stamped in
-- the i960's OWN local time (emu.time() inside a tap is the executing CPU's
-- clock). TM_OUT=<file>: one 9-byte record per event <c1 type, double t>:
--   W copro FIFO write (0x884000)   N function port (0x880000)
--   R copro FIFO read               C copro_ctl1 write (0x980000)
--   L flip (0x803008 write: the top of STCC's wait routine, 0x76380)
--   F the frame notifier (fires ~0.75 ms after the vblank -- R1005)
-- W/N/R/C are, one for one and in order, the I/U, N, X/Y and C events of an
-- R924 capture taken in the same run (R924_CAP); sim/tgpx4/tm_gaps.py aligns
-- them. Without TM_OUT no tap is installed. The run is deterministic: the same
-- script gives the same lists frame for frame (checked over 8,870 lists).
-- Everything written is ROM-derived and stays outside the repository.
--   R924_CAP=<dir> TM_OUT=<dir>/tm.bin OR_TEND=200 m2lod stcc ... \
--     -autoboot_script tools/mame_stcc_timing.lua
local out = os.getenv("TM_OUT")
if out then
  local cpu = manager.machine.devices[":maincpu"]
  local sp = cpu.spaces["program"]
  local L = assert(io.open(out, "wb"))
  local buf, nb = {}, 0
  local pk = string.pack
  local function ev(c) nb = nb + 1; buf[nb] = pk("<c1d", c, emu.time()); if nb >= 65536 then L:write(table.concat(buf)); buf = {}; nb = 0 end end
  TM1 = sp:install_write_tap(0x00884000, 0x00887fff, "tm_fw", function(o, d, mk) ev("W"); return d end)
  TM2 = sp:install_write_tap(0x00880000, 0x00883fff, "tm_fn", function(o, d, mk) ev("N"); return d end)
  TM3 = sp:install_read_tap(0x00884000, 0x00887fff, "tm_fr", function(o, d, mk) ev("R"); return d end)
  TM4 = sp:install_write_tap(0x00980000, 0x00980003, "tm_ct", function(o, d, mk) ev("C"); return d end)
  TM5 = sp:install_write_tap(0x00803008, 0x0080300b, "tm_fl", function(o, d, mk) ev("L"); return d end)
  TM6 = emu.add_machine_frame_notifier(function() ev("F") end)
  TM7 = emu.add_machine_stop_notifier(function() L:write(table.concat(buf)); L:close() end)
end
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
dofile(here .. "../sim/io/mame_m2_stcc_race.lua")
