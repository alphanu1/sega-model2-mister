-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
-- From the Sega Model 1 core (sega-model1-mister 2657c46, tools/mame_dsb_cap.lua), for STCC (study R979).
-- DSBCAP_SECS=300 DSBCAP_COIN=150 DSBCAP_OUT=cap300.txt mame stcc -rompath <dir> -video none -sound none \
--   -nothrottle -skip_gameinfo -autoboot_delay 0 -autoboot_script tools/dsb/stcc_dsb_cap.lua
-- STCC Digital Sound Board traffic, headless (based on Model 1 tools/mame_dsb_cap.lua)
--   TX xx      bytes the i960 writes to its i8251 data port (0x01c80000) -- the DSB's only input
--   TXC xx     the i960's i8251 control writes
--   RX xx      bytes the DSB's own i8251 hands its Z80 (port f0 reads)
--   ZW pp xx   the Z80's port writes (0xe0-0xf1)
--   ZR pp xx   its port reads, except the status port 0xf1
--   PC xxxx    every distinct Z80 PC executed (at the end)
local OUT = os.getenv("DSBCAP_OUT") or "dsbcap.txt"
local SECS = tonumber(os.getenv("DSBCAP_SECS") or "240")
local f = io.open(OUT, "w")
local m = manager.machine
local function t() return m.time:as_double() end
local cpu = m.devices[":maincpu"].spaces["program"]
local zio = m.devices[":dsbz80:mpegcpu"].spaces["io"]
local zpg = m.devices[":dsbz80:mpegcpu"].spaces["program"]
local wrote, rd_unw, unw = {}, 0, {}
local wmin, wmax, ramw = 0xffff, 0, 0
local readpages = {}
taps = {}
taps[#taps+1] = cpu:install_write_tap(0x01c80000, 0x01c80003, "uart", function(o, d, mk)
  if (mk & 0x000000ff) ~= 0 then f:write(string.format("%.9f TX %02x\n", t(), d & 0xff)) end
  if (mk & 0x00ff0000) ~= 0 then f:write(string.format("%.9f TXC %02x\n", t(), (d >> 16) & 0xff)) end
  return d end)
taps[#taps+1] = zio:install_write_tap(0x00, 0xff, "zw", function(o, d, mk)
  f:write(string.format("%.9f ZW %02x %02x\n", t(), o & 0xff, d & 0xff)); return d end)
taps[#taps+1] = zio:install_read_tap(0x00, 0xff, "zr", function(o, d, mk)
  if (o & 0xff) ~= 0xf1 then f:write(string.format("%.9f ZR %02x %02x\n", t(), o & 0xff, d & 0xff)) end
  return d end)
taps[#taps+1] = zpg:install_write_tap(0x8000, 0xffff, "zram_w", function(o, d, mk)
  wrote[o] = true; ramw = ramw + 1
  if o < wmin then wmin = o end
  if o > wmax then wmax = o end
  return d end)
taps[#taps+1] = zpg:install_read_tap(0x0000, 0xffff, "zrd", function(o, d, mk)
  readpages[o >> 8] = (readpages[o >> 8] or 0) + 1
  if o >= 0x8000 and not wrote[o] then rd_unw = rd_unw + 1; unw[o] = true end
  return d end)
local ports = m.ioport.ports
local function press(fname, on)
  for tag, port in pairs(ports) do
    for fn, fld in pairs(port.fields) do
      if fn:lower():find(fname) then fld:set_value(on and 1 or 0) end
    end
  end
end
notif = emu.add_machine_frame_notifier(function()
  local s = t()
  local cs = tonumber(os.getenv("DSBCAP_COIN") or "120")
  if s > cs and s < cs + 0.2 then press("coin 1", true) else press("coin 1", false) end
  if s > cs + 2 and s < cs + 2.2 then press("1 player start", true) else press("1 player start", false) end
  if s > SECS then
    local n = 0; local blocks = {}
    for a, _ in pairs(wrote) do n = n + 1; blocks[a >> 8] = true end
    local bl = {}
    for b, _ in pairs(blocks) do bl[#bl+1] = string.format("%02x", b) end
    table.sort(bl)
    local un = {}; for a,_ in pairs(unw) do un[#un+1] = a end; table.sort(un)
    local us = {}; for i=1,math.min(#un,64) do us[#us+1]=string.format("%04x",un[i]) end
    local rp = {}; for p,c in pairs(readpages) do rp[#rp+1] = string.format("%02x:%d", p, c) end; table.sort(rp)
    f:write(string.format("# RAM writes=%d distinct=%d min=%04x max=%04x pages=%s\n", ramw, n, wmin, wmax, table.concat(bl, ",")))
    f:write(string.format("# RAM reads of unwritten=%d distinct=%d first=%s\n", rd_unw, #un, table.concat(us, ",")))
    f:write("# read pages " .. table.concat(rp, " ") .. "\n")
    f:close()
    m:exit()
  end
end)
