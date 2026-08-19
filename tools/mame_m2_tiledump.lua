-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
--
-- Dump the 2D layer's state out of MAME at a chosen frame, so P1.5's tilemap has
-- an ORACLE rather than a hope. Without it there is no CPU to write the tilemap
-- and the screen is black whatever the fetcher does.
--
-- Regions, from model2.cpp's memory map:
--   0x01000000 +0x010000   tile RAM   -- the tilemap layout
--   0x01080000 +0x080000   char RAM   -- the character/glyph data
--   0x01800000 +0x004000   palette
--
-- The subscription is kept in a GLOBAL: assigned to a local it is collected and
-- the callback silently stops (Model 1 docs/differential-testing.md).

local at  = tonumber(os.getenv("M2_FRAME") or "2300")
local out = os.getenv("M2_OUT") or "/tmp/m2tiles"
local n   = 0

local REGIONS = {
  { name = "tile",    base = 0x01000000, size = 0x010000 },
  { name = "char",    base = 0x01080000, size = 0x080000 },
  { name = "palette", base = 0x01800000, size = 0x004000 },
  -- The colour translation RAM. Model 2's palette is NOT a plain 5-to-8 bit
  -- expansion: model2.cpp palette_w indexes this table with each 5-bit channel
  -- and then applies a gamma curve. Only 96 of its entries are ever read --
  -- 32 per channel at a stride of 256 words -- but the whole region is dumped
  -- because the stride is worth confirming from real data rather than trusting.
  { name = "colorxlat", base = 0x01810000, size = 0x00c000 },
}

M2_TILEDUMP_SUB = emu.add_machine_frame_notifier(function()
  n = n + 1
  if n ~= at then return end

  local sp = manager.machine.devices[":maincpu"].spaces["program"]
  for _, r in ipairs(REGIONS) do
    local f = io.open(out .. "/" .. r.name .. ".bin", "wb")
    local chunk = {}
    for a = r.base, r.base + r.size - 4, 4 do
      local v = sp:read_u32(a)
      -- Little-endian, matching how the i960 sees it and how the ROM loader
      -- will stream it. Getting this backwards produces a plausible-looking
      -- picture made of the wrong bytes, which is worse than an obvious failure.
      chunk[#chunk+1] = string.pack("<I4", v)
      if #chunk >= 4096 then f:write(table.concat(chunk)); chunk = {} end
    end
    if #chunk > 0 then f:write(table.concat(chunk)) end
    f:close()
    print(string.format("M2DUMP: %s %d bytes from %08x", r.name, r.size, r.base))
  end
  print("M2DUMP: frame " .. n .. " done")
  manager.machine:exit()
end)
