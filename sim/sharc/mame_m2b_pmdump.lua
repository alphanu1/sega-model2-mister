-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- R1038: dump the 2B SHARC program memory (words
-- 0x20000-0x21fff) at PMD_T seconds (default 40) to PMD_OUT, for sim/sharc/m2b_sclass.py.
-- ROM-derived output: keep it outside the repository.
local out = os.getenv("PMD_OUT"); local t = tonumber(os.getenv("PMD_T") or "40")
local dev = manager.machine.devices[os.getenv("PMD_DEV") or ":copro_adsp"]
local done = false
PMD_F = emu.add_machine_frame_notifier(function()
  if done or emu.time() < t then return end
  done = true
  local L = io.open(out, "w")
  for k, v in pairs(dev.spaces) do L:write("# space " .. k .. "\n") end
  local sp = dev.spaces["program"]
  for a = 0x20000, 0x21fff do
    L:write(string.format("%05x %012x\n", a, sp:read_u64(a) & 0xffffffffffff))
  end
  L:close()
end)
