-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- R888: MAME's GAME FRAME RATE over a scripted 2A play session. The game
-- starts a frame with one write of the geometrizer's 0x803008 (build/dasm/
-- flips.lua, R637); this counts them per vblank over sim/io/mame_m2_2a_play.lua
-- (PL_GAME, PL_COIN, PL_TEND as there) and prints, for frames FL_START ..
-- FL_END, how many vblanks each game frame took. A hint, not a hardware fact:
-- MAME's i960 and TGP timings are its own.
--   FL_START / FL_END   the vblank window (default 1300 / 3720, R876's race)
local dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
dofile(dir .. "/../io/mame_m2_2a_play.lua")
local sp = manager.machine.devices[":maincpu"].spaces["program"]
local S = tonumber(os.getenv("FL_START") or "1300")
local E = tonumber(os.getenv("FL_END") or "3720")
local vb, last, flips = 0, nil, 0
local hist = {}
FL_TAP = sp:install_write_tap(0x803008, 0x80300b, "fl_flip", function(off, data, mask)
  if vb >= S and vb < E then
    flips = flips + 1
    if last then local d = vb - last; hist[d] = (hist[d] or 0) + 1 end
    last = vb
  end
end)
FL_F = emu.add_machine_frame_notifier(function()
  vb = vb + 1
  if vb == E then
    local n = E - S
    print(string.format("FLIPS %d in %d vblanks: %.3f a vblank, %.1f game fps at 57.5 Hz", flips, n, flips / n, 57.5 * flips / n))
    local ks = {}
    for k in pairs(hist) do ks[#ks + 1] = k end
    table.sort(ks)
    for _, k in ipairs(ks) do print(string.format("FLIPS gap %d vblank(s): %d frames", k, hist[k])) end
    manager.machine:exit()
  end
end)
