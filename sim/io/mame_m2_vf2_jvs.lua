-- SPDX-License-Identifier: GPL-3.0-or-later
-- Sega Model 2 core for MiSTer FPGA -- Copyright (C) 2026 alphanu1
-- R972: VF2 Jacky (P1) vs Sarah (P2) in VS mode, the stage of GitHub #27's seam.
-- SEL_SEQ="t|port|field,..." pulses inputs (sim/i960/audit: the Jacky / Sarah sequence is
-- 20|:IN0|Coin 1, 20.5|:IN0|Coin 1, 23|:IN0|1 Player Start, P1 Right x7 from 25 every 0.4 s,
-- 28.5|:IN1|P1 Punch, 30 / 30.5 Coin 2, 31.5 2 Players Start, P2 Left x3 from 34, 35.5 P2 Punch);
-- SNAP0 / SNAP1 / SNAPDT snapshots; MASH_T=<s> both players move by a fixed pseudo-random sequence.
local m = manager.machine
local ports = m.ioport.ports
local scr = m.screens[":screen"]
local function set(p, f, v) local x = ports[p] and ports[p].fields[f]; if x then x:set_value(v) end end
local function pulse(t, at, p, f, len)
  len = len or 0.15
  if t >= at and t < at + len then set(p, f, 1) elseif t >= at + len and t < at + len + 0.1 then set(p, f, 0) end
end
local n = 0
MASH_T = tonumber(os.getenv("MASH_T") or "")
mseed, mash_k = 4242, -1
local SEQ = {}
-- SEL_SEQ="t:port:field,t:port:field,..."
for t, p, f in string.gmatch(os.getenv("SEL_SEQ") or "", "([%d%.]+)|([^|]+)|([^,]+)") do SEQ[#SEQ+1] = {tonumber(t), p, f} end
local SNAP0, SNAP1, SNAPDT = tonumber(os.getenv("SNAP0") or "20"), tonumber(os.getenv("SNAP1") or "40"), tonumber(os.getenv("SNAPDT") or "0.5")
local nexts = SNAP0
SEL_F = emu.add_machine_frame_notifier(function()
  local t = emu.time()
  for _, s in ipairs(SEQ) do pulse(t, s[1], s[2], s[3]) end
  -- MASH_T=<s>: from then on, both players' sticks and buttons follow a fixed
  -- pseudo-random sequence (a new state every 0.2 s), so the fighters move
  if MASH_T and t >= MASH_T then
    local k = math.floor(t * 5)
    if k ~= mash_k then
      mash_k = k
      for _, pl in ipairs({{":IN1","P1 "},{":IN2","P2 "}}) do
        for _, b in ipairs({"Up","Down","Left","Right","Punch","Kick","Guard"}) do
          mseed = (mseed * 1103515245 + 12345) & 0x7fffffff
          set(pl[1], pl[2] .. b, (((mseed >> 8) % 5) == 0) and 1 or 0)
        end
      end
    end
  end
  if t >= nexts and t <= SNAP1 then scr:snapshot(string.format("s%07.2f.png", t)); nexts = nexts + SNAPDT end
  if SNAP1 < 1e8 and t > SNAP1 + 1 then m:exit() end
end)
