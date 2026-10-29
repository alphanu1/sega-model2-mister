-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
-- R972: cvtri tie census, and ties-to-even emulated in MAME (TIE_FIX=1).
-- Run with -debug -debugger none; TIE_SITES from sim/i960/audit/rscan.py (pc reg).
--   TIE_SITES=<"pc reg" lines>  TIE_OUT=<file>  TIE_TEND=<s>
--   TIE_FIX=1: at the stis after each of the four pose loops' cvtri r13,r13
--   (0x27cc8 via g3; 0x28820 / 0x288f0 / 0x28ad4 via g5), where the source
--   single is still in memory, an exact tie whose away-from-zero result is
--   odd is moved one toward zero: the result Intel's mode 00 gives.
--   TIE_SNAP=<frame list a,b,...> snapshots;  TIE_CHAIN=<lua> chained script
local m = manager.machine
local scr = m.screens[":screen"]
local dbg = m.debugger
local T_END = tonumber(os.getenv("TIE_TEND") or "120")
local out = assert(io.open(assert(os.getenv("TIE_OUT")), "w"))
local function tie(x)
  local e = "((" .. x .. ">>0x17)&0xff)"
  return string.format("(%s>=0x7e && %s<=0x95 && ((((%s)&0x7fffff)|0x800000) & ((0x1<<(0x96-%s))-0x1)) == (0x1<<(0x95-%s)))",
                       e, e, x, e, e)
end
local n = 0
for ln in io.lines(assert(os.getenv("TIE_SITES"))) do
  local pc, reg = ln:match("^(%x+)%s+(%S+)")
  if pc then
    n = n + 1
    dbg:command(string.format('bpset %s,%s,{printf "T %%08x %%08x %%08x",curpc,%s,ac; g}', pc, tie(reg), reg))
  end
end
if os.getenv("TIE_FIX") == "1" then
  for _, s in ipairs({ {0x27ccc, "g3"}, {0x28824, "g5"}, {0x288f4, "g5"}, {0x28ad8, "g5"} }) do
    local src = "d@" .. s[2]
    dbg:command(string.format('bpset %x,%s && (r13&0x1),{printf "F %%08x %%08x %%08x",curpc,%s,r13; r13 = r13 - 0x1 + 0x2*((r13>>0x1f)&0x1); g}',
                              s[1], tie(src), src))
  end
end
out:write(string.format("# %d tie breakpoints fix=%s\n", n, os.getenv("TIE_FIX") or "0")); out:flush()
local SNAP = {}
for v in string.gmatch(os.getenv("TIE_SNAP") or "", "[^,]+") do SNAP[tonumber(v)] = true end
local last = 0
TIE_F = emu.add_machine_frame_notifier(function()
  local log = dbg.consolelog
  local nl = #log
  local f = scr:frame_number()
  for i = last + 1, nl do
    local s = log[i]
    if s and (s:sub(1, 2) == "T " or s:sub(1, 2) == "F ") then out:write(s, " ", f, "\n")
    elseif s and f < 3 then out:write("# ", s, "\n") end
  end
  last = nl
  if SNAP[f] then scr:snapshot(string.format("t%06d.png", f)) end
  if emu.time() >= T_END then out:write(string.format("END frame %d\n", f)); out:close(); m:exit() end
end)
if os.getenv("TIE_CHAIN") then dofile(os.getenv("TIE_CHAIN")) end
