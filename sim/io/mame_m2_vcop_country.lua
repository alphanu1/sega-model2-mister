-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- VIRTUA COP'S LANGUAGE IS ITS COUNTRY (R846): backup RAM byte 0x1b (CPU
-- 0x01d0001b; 0 USA, 1 JPN, 2 EXP -- the strings at program 0x29d20). The
-- program fills a fresh backup RAM from the data ROM (0x2831ba0.., which puts
-- 1, Japan, in byte 0x1b). Logs every write to it (CO_OUT); CO_FORCE=<n> holds
-- it at n after 3 s and snapshots every 5 s to show the attract in that
-- country's language.
--
-- log writes to backup RAM byte 0x1b (country); optionally force it after init
local m = manager.machine
local cpu = m.devices[":maincpu"]
local sp = cpu.spaces["program"]
local out = assert(io.open(os.getenv("CO_OUT"), "w"))
local force = tonumber(os.getenv("CO_FORCE") or "-1")
CT = sp:install_write_tap(0x1d00018, 0x1d0001b, "cw", function(off, data, mask)
  out:write(string.format("%.3f write %08x data %08x mask %08x pc %08x\n", emu.time(), off, data, mask, cpu.state["ip"].value)); out:flush()
  return data
end)
local scr = m.screens[":screen"]
local T_END = tonumber(os.getenv("CO_TEND") or "70")
local nexts = 5
CF = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  if force >= 0 and t > 3.0 then
    local v = sp:read_u8(0x1d0001b)
    if v ~= force then sp:write_u8(0x1d0001b, force) end
  end
  if t >= nexts then scr:snapshot(string.format("c%03d.png", math.floor(t))); nexts = nexts + 5 end
  if t >= T_END then out:write(string.format("end byte %02x\n", sp:read_u8(0x1d0001b))); out:close(); m:exit() end
end)
