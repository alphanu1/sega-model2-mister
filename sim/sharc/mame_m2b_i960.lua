-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- R1023: what a Model 2B game's i960 does on the 2B-only parts of its map
-- (MAME 0.289 model2b_crx_mem), over sim/io/mame_m2_2a_play.lua's session:
--   0x008c0000-0x008c0fff  the SHARC's IOP registers written by the host
--   0x00980020             the bank control register
--   0x009c0000-0x009c0007  the i8251 (2C has it at 0x01c80000)
--   0x01c80000-0x01c80003  2A / 2C's i8251 address (unmapped on 2B)
--   0x11000000-0x113fffff  texture RAM, the mirrored upper MB of each window apart
--   0x00880000 / 0x00884000 the function port and the FIFO (upload and commands)
-- M2B_I960_LOG=<file>: a summary at exit, and the first 200 IOP / bank writes.
local out = os.getenv("M2B_I960_LOG")
if out then
  local sp = manager.machine.devices[":maincpu"].spaces["program"]
  local L = assert(io.open(out, "w"))
  local n = {}
  local first = 0
  local function cnt(k) n[k] = (n[k] or 0) + 1 end
  local function logw(k, o, d)
    cnt(k)
    if first < 200 then first = first + 1; L:write(string.format("%.6f %s %08x %08x\n", emu.time(), k, o, d)) end
  end
  T1 = sp:install_write_tap(0x008c0000, 0x008c0fff, "m2b_iop", function(o, d, m) logw("IOP", o, d); return d end)
  T2 = sp:install_write_tap(0x00980020, 0x00980023, "m2b_bank", function(o, d, m) logw("BANK", o, d); return d end)
  T3 = sp:install_read_tap(0x00980020, 0x00980023, "m2b_bankr", function(o, d, m) cnt("BANK_R"); return d end)
  T4 = sp:install_write_tap(0x009c0000, 0x009c0007, "m2b_uartw", function(o, d, m) cnt("UART9C_W"); return d end)
  T5 = sp:install_read_tap(0x009c0000, 0x009c0007, "m2b_uartr", function(o, d, m) cnt("UART9C_R"); return d end)
  T6 = sp:install_write_tap(0x01c80000, 0x01c80003, "m2b_uart2", function(o, d, m) cnt("UART1C8_W"); return d end)
  T7 = sp:install_write_tap(0x11000000, 0x113fffff, "m2b_tex", function(o, d, m)
    if (o & 0x00100000) ~= 0 then cnt("TEX_UPPER_MB") else cnt("TEX_LOWER_MB") end; return d end)
  T8 = sp:install_read_tap(0x11000000, 0x113fffff, "m2b_texr", function(o, d, m) cnt("TEX_READ"); return d end)
  T9 = sp:install_write_tap(0x00884000, 0x00887fff, "m2b_fifo", function(o, d, m) cnt("FIFO_W"); return d end)
  T10 = sp:install_write_tap(0x00880000, 0x00883fff, "m2b_fn", function(o, d, m) cnt("FN_W"); return d end)
  T11 = sp:install_read_tap(0x00884000, 0x00887fff, "m2b_fifor", function(o, d, m) cnt("FIFO_R"); return d end)
  T12 = sp:install_read_tap(0x00980014, 0x00980017, "m2b_stat", function(o, d, m) cnt("STATUS_R"); return d end)
  T13 = sp:install_write_tap(0x00980000, 0x00980003, "m2b_ctl", function(o, d, m) logw("CTL1", o, d); return d end)
  T14 = sp:install_write_tap(0x00804000, 0x00807fff, "m2b_geo", function(o, d, m) cnt("GEO_PRG_W"); return d end)
  T15 = sp:install_write_tap(0x01d80000, 0x01d9ffff, "m2b_prot", function(o, d, m) cnt("PROT_W"); return d end)
  T16 = sp:install_read_tap(0x01d80000, 0x01d9ffff, "m2b_protr", function(o, d, m) cnt("PROT_R"); return d end)
  T17 = sp:install_write_tap(0x00900000, 0x0097ffff, "m2b_bufw", function(o, d, m) cnt("BUFRAM_W"); return d end)
  T18 = sp:install_read_tap(0x00900000, 0x0097ffff, "m2b_bufr", function(o, d, m) cnt("BUFRAM_R"); return d end)
  TS = emu.add_machine_stop_notifier(function()
    local ks = {}
    for k in pairs(n) do ks[#ks + 1] = k end
    table.sort(ks)
    for _, k in ipairs(ks) do L:write(string.format("COUNT %s %d\n", k, n[k])) end
    L:close()
  end)
end
local here = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
dofile(here .. "../io/mame_m2_2a_play.lua")
