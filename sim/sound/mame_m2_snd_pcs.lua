-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- WHERE THE SOUND 68000 WRITES THE SCSP'S SLOT REGISTERS FROM (study R856):
-- a write tap on 0x100000-0x1003ff records, per (PC, register word), how many
-- writes and the values seen; written to SND_PCS (default pcs.txt) at
-- SND_PCS_T seconds. Rides alongside mame_m2_2a_snd.lua (SND_CHAIN) or alone.
local m = manager.machine
local cpu = m.devices[":audiocpu"]
local sp = cpu.spaces["program"]
local T = tonumber(os.getenv("SND_PCS_T") or "100")
local out = os.getenv("SND_PCS") or "pcs.txt"
local hist = {}
SND_PCS_TAP = sp:install_write_tap(0x100000, 0x1003ff, "pcs", function(offset, data, mask)
  local pc = cpu.state["PC"].value
  local w = (offset & 0x1f) >> 1
  local k = string.format("%06x %x", pc, w)
  local h = hist[k]
  if not h then h = { n = 0, v = {} }; hist[k] = h end
  h.n = h.n + 1
  if not h.v[data] then h.v[data] = 0 end
  h.v[data] = h.v[data] + 1
end)
local done = false
SND_PCS_F = emu.add_machine_frame_notifier(function()
  if done or emu.time() < T then return end
  done = true
  local f = io.open(out, "w")
  local keys = {}
  for k in pairs(hist) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local h = hist[k]
    local vs = {}
    for v, c in pairs(h.v) do vs[#vs + 1] = string.format("%04x", v) end
    table.sort(vs)
    local s = table.concat(vs, " ", 1, math.min(#vs, 24))
    f:write(string.format("%s n %d values %d: %s\n", k, h.n, #vs, s))
  end
  f:close()
end)
if os.getenv("SND_CHAIN") then dofile(os.getenv("SND_CHAIN")) end
