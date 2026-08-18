-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- Trace N consecutive i960 frames at a chosen point, uncollapsed.
--
--   M2_FRAME=2300 M2_FRAMES=12 M2_TR=/tmp/f.tr mame daytona93 ... \
--     -debug -debugscript <(echo go) -autoboot_script tools/mame_i960_frame_trace.lua
--
-- WHY A FRAME NOTIFIER RATHER THAN `gtime`
--
-- A long `gtime` in a debugscript silently produces no trace file here (20000,
-- and 4x5000 chained, both yielded nothing while `gtime 1` worked). Unresolved.
-- This drives the debugger from a frame notifier instead, which also gives an
-- exact frame boundary rather than a millisecond window.
--
-- `noloop` IS THE POINT. Without it MAME collapses loops and hides 70-85% of
-- what executed -- see study R15, which retracted three figures for want of it.
--
-- The subscription is kept in a GLOBAL. Assigned to a local it is collected and
-- the callback silently stops (Model 1 docs/differential-testing.md).
--
-- `tracelog M2FRAME` writes a marker into the trace at each frame boundary, so
-- one run yields per-frame counts instead of one undifferentiated blob.
local cnt = tonumber(os.getenv("M2_FRAMES") or "12")
local out = os.getenv("M2_TR") or "/tmp/frames.tr"
local n = 0
M2_SUB = emu.add_machine_frame_notifier(function()
  n = n + 1
  if n == at then
    manager.machine.debugger:command("trace " .. out .. ",:maincpu,noloop")
  elseif n > at and n < at + cnt then
    manager.machine.debugger:command("tracelog M2FRAME")
  elseif n == at + cnt then
    manager.machine.debugger:command("trace off")
    print("M2TRACE: done")
    manager.machine:exit()
  end
end)
