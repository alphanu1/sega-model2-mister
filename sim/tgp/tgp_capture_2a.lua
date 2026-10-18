-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- R876: THE TGP CAPTURE OVER A SCRIPTED 2A PLAY SESSION. tgp_capture.lua with
-- its Daytona inputs off (TGPCAP_INPUTS=none), driven by sim/io/
-- mame_m2_2a_play.lua (PL_GAME=zg|rally|vcop2, PL_COIN, PL_TEND), so the
-- window can be a game in play rather than the attract. Both scripts' own
-- environment applies; `make tgp_capture_2a` sets it.
local dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
dofile(dir .. "/../io/mame_m2_2a_play.lua")
dofile(dir .. "/tgp_capture.lua")
