-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- R933: THE 2C TEXTURE SHEETS AND LUMA RAM AS THE i960 SEES THEM, at given
-- video frames, for the whole-core bench's M2_DUMP_OUT (tex0.bin / tex1.bin /
-- luma) to be set against. Reads through the i960's program space:
-- 0x11000000 and 0x11200000 (2 MB each, MAME's model2c_crx_mem; written as
-- <prefix>_<frame>_tex0.bin / _tex1.bin, u32 little-endian) and the luma RAM
-- at 0x11400000 (a byte per halfword: <prefix>_<frame>_luma.bin, 32 KB).
--
--   TD_OUT=<prefix> TD_FRAMES=<f,f,...>   (screen frame numbers)
--
-- The dumps are ROM-derived and stay outside the repository.
local m = manager.machine
local scr = m.screens[":screen"]
local sp = m.devices[":maincpu"].spaces["program"]
local pre = assert(os.getenv("TD_OUT"), "TD_OUT")
local want = {}
for f in string.gmatch(os.getenv("TD_FRAMES") or "", "(%d+)") do want[tonumber(f)] = true end
local last = 0
for f in pairs(want) do if f > last then last = f end end

local function dump(name, base, n, step, rd)
  local fh = assert(io.open(name, "wb"))
  local buf = {}
  for a = base, base + n - step, step do
    buf[#buf + 1] = rd(a)
    if #buf == 4096 then fh:write(table.concat(buf)); buf = {} end
  end
  fh:write(table.concat(buf)); fh:close()
end

TD_FN = emu.add_machine_frame_notifier(function()
  local f = scr:frame_number()
  if want[f] then
    want[f] = nil
    local p = string.format("%s_%06d", pre, f)
    dump(p .. "_tex0.bin", 0x11000000, 0x200000, 4, function(a) return string.pack("<I4", sp:read_u32(a)) end)
    dump(p .. "_tex1.bin", 0x11200000, 0x200000, 4, function(a) return string.pack("<I4", sp:read_u32(a)) end)
    dump(p .. "_luma.bin", 0x11400000, 0x10000, 2, function(a) return string.pack("B", sp:read_u16(a) & 0xff) end)
    if f >= last then m:exit() end
  end
end)
