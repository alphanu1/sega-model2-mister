-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- R1046: for make test_m2_lut_snoop -- MAME 0.289 (taps only) logs every CPU write to the
-- luma RAM, the 3D palette and the colour table (writes.txt: region, offset, data, mask)
-- and their contents at the end (final.txt). ROM-derived output: keep it out of the repo.
--   CW_OUT=<dir> MS_PLAY=sim/io/mame_m2_2a_play.lua PL_GAME=dig PL_TEND=60 mame doa ... -autoboot_script <this>
local m = manager.machine
local sp = m.devices[":maincpu"].spaces["program"]
local L = assert(io.open(os.getenv("CW_OUT") .. "/writes.txt", "w"))
local R = {{0,0x11400000,0x1140ffff},{1,0x01802000,0x018027ff},{2,0x01810000,0x0181bfff}}
T = {}
for i, r in ipairs(R) do
  T[i] = sp:install_write_tap(r[2], r[3], "cw"..i, function(o, d, mk)
    L:write(string.format("%d %08x %08x %08x\n", r[1], o - r[2], d, mk)); return d end)
end
S = emu.add_machine_stop_notifier(function()
  L:close()
  local F = assert(io.open(os.getenv("CW_OUT") .. "/final.txt", "w"))
  for i, r in ipairs(R) do
    for a = r[2], r[3], 4 do F:write(string.format("%d %08x %08x\n", r[1], a - r[2], sp:read_u32(a))) end
  end
  F:close()
end)
dofile(os.getenv("MS_PLAY"))
