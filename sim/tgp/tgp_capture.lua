-- tgp_capture.lua -- record an exact, replayable MB86234 (Model 2A TGP) workload
-- out of MAME, for sim/tgp bench tb_tgp_replay.
--
-- Run as an -autoboot_script on daytona93. Environment:
--   TGPCAP_DIR     output directory (must exist)
--   TGPCAP_START   first frame at which the snapshot may be taken (default 5200)
--   TGPCAP_FRAMES  frames to record after the snapshot (default 30)
--
-- METHOD. Everything that crosses the TGP's boundary is tapped from power-on,
-- but only counted until the window opens:
--   * i960 writes to 0x880000-0x883fff (function port) and 0x884000-0x887fff
--     (FIFO port), and copro_ctl1 at 0x980000 to tell program upload from
--     FIFO pushes (model2.cpp copro_fifo_w);
--   * the TGP's AS_RF space: read of index 1 = input FIFO pop, write of index
--     2 = output FIFO push, write of index 3 = the memory bank register;
--   * the TGP's AS_IO space (math units, data ROM / buffer RAM window);
--   * i960 reads of 0x884000 (output FIFO pop).
-- Input-FIFO occupancy is tracked as pushes minus real pops. A TGP read of rf 1
-- at occupancy 0 is a STALLED pop (gen_fifo returns 0 and mb86233 replays the
-- instruction), not a pop. Likewise an i960 read of the output FIFO at
-- occupancy 0 is a stalled read (i960_stall replays it).
--
-- The snapshot is taken at the first frame boundary >= START at which the TGP
-- is PARKED: its last rf-1 read stalled and the input FIFO is empty. The TGP
-- is then between instructions, at the pc of that pop, and nothing is in
-- flight towards it. Recording runs FRAMES frames and then on to the next
-- parked point, so the window also ends quiescent: every input consumed, every
-- output produced.
--
-- Files written:
--   state.txt   TGP registers (MAME state names), bank, math-unit bases,
--               pc, output-FIFO occupancy at the snapshot
--   dram.bin    TGP data RAM words 0x000-0x3ff (u32 LE; 0x100-0x1ff unmapped=0)
--   prog.bin    TGP program RAM 0x000-0xfff (u32 LE)
--   tables.bin  :copro_tgp_tables region (u32 LE, 64K words)
--   cdata.bin   :copro_data region (u32 LE, 2M words)
--   events.bin  9-byte records "<c1 I4 I4": type, a, b (see EV_* below)
--   NONE of these may enter the repository: they are ROM-derived.

local outdir = os.getenv("TGPCAP_DIR") or "."
local START  = tonumber(os.getenv("TGPCAP_START") or "5200")
local NFR    = tonumber(os.getenv("TGPCAP_FRAMES") or "30")

local m    = manager.machine
local cpu  = m.devices[":maincpu"]
local tgp  = m.devices[":copro_tgp"]
local msp  = cpu.spaces["program"]
local rf, io_, ds, ps = tgp.spaces["rf"], tgp.spaces["io"], tgp.spaces["data"], tgp.spaces["program"]

local in0 = m.ioport.ports[":IN0"]
local coin, start = in0.fields["Coin 1"], in0.fields["1 Player Start"]

-- ---------------------------------------------------------------- state
local frame     = 0
local coproctl  = 0
local occ_in    = 0         -- input FIFO occupancy (values + overflow queue)
local occ_out   = 0         -- output FIFO occupancy
local parked    = false     -- last rf-1 read stalled, none since
local bank      = 0
local sincos, inv, isqrt = 0, 0, 0
local atan      = {0, 0, 0, 0}
local capturing = false
local done      = false
local cap_frames = 0
local n_upload  = 0
local nin, nout, npop, nxpop = 0, 0, 0, 0
local queue     = {}        -- pushed words not yet popped (for the pop cross-check)
local qh, qt    = 0, 0       -- ring of 64K: occupancy never comes close
local pop_mismatch = 0
local nhalf = 0

-- ------------------------------------------------------------- recording
local EV_FRAME, EV_FIFO, EV_FN, EV_XPOP = 0x46, 0x49, 0x4e, 0x58   -- F I N X
local EV_FIFOH = 0x48                                              -- H
local EV_OUT, EV_POP, EV_STALL         = 0x4f, 0x50, 0x53          -- O P S
local EV_IORD, EV_IOWR, EV_BANK        = 0x52, 0x57, 0x42          -- R W B
local buf, nbuf = {}, 0
local evf
local function ev(t, a, b)
  nbuf = nbuf + 1
  buf[nbuf] = string.pack("<BI4I4", t, a & 0xffffffff, b & 0xffffffff)
  if nbuf >= 4096 then evf:write(table.concat(buf, "", 1, nbuf)); nbuf = 0 end
end
local function flush() if evf and nbuf > 0 then evf:write(table.concat(buf, "", 1, nbuf)); nbuf = 0 end end

local function dump_space(path, sp, lo, hi)
  local f = assert(io.open(path, "wb"))
  local t = {}
  for a = lo, hi do t[#t + 1] = string.pack("<I4", sp:read_u32(a)) end
  f:write(table.concat(t)); f:close()
end
local function dump_region(path, tag)
  local r = m.memory.regions[tag]
  local f = assert(io.open(path, "wb"))
  local t, n = {}, 0
  for off = 0, r.size - 4, 4 do
    n = n + 1; t[n] = string.pack("<I4", r:read_u32(off))
    if n == 65536 then f:write(table.concat(t)); t, n = {}, 0 end
  end
  if n > 0 then f:write(table.concat(t, "", 1, n)) end
  f:close()
end

-- io-space tag: the bank register decides what the address means, so it goes
-- in the record. a = io_addr | (bank[23:16] << 16) | (view_on << 24)
local function io_tag(off)
  local on = ((bank & 0xc00000) ~= 0) and 1 or 0
  return (off & 0xffff) | (((bank >> 16) & 0xff) << 16) | (on << 24)
end

-- ----------------------------------------------------------------- taps
TAP_CTL = msp:install_write_tap(0x980000, 0x980003, "tgpcap_ctl", function(off, data, mask)
  coproctl = (coproctl & ~mask) | (data & mask)
end)

TAP_W = msp:install_write_tap(0x880000, 0x887fff, "tgpcap_w", function(off, data, mask)
  if off >= 0x884000 and (coproctl & 0x80000000) ~= 0 then
    n_upload = n_upload + 1
    return
  end
  local word
  if off < 0x884000 then
    word = (data & 0x800fffff) | (((off >> 4) & 0xff) << 23)
    if capturing then ev(EV_FN, off, data) end
  else
    word = data
    -- A 16-bit store to the FIFO port (the i960 does these: st.s) pushes the
    -- handler's whole u32 argument, which carries the halfword in its lane
    -- and zeros elsewhere. Recorded as its own type so it stays visible.
    if capturing then ev(mask == 0xffffffff and EV_FIFO or EV_FIFOH, off, data) end
  end
  if mask ~= 0xffffffff then nhalf = nhalf + 1; if nhalf <= 4 then
    print(string.format("TGPCAP partial copro write %x data %08x mask %08x", off, data, mask)) end end
  occ_in = occ_in + 1
  queue[qt & 0xffff] = word; qt = qt + 1
  if capturing then nin = nin + 1 end
end)

TAP_R = msp:install_read_tap(0x884000, 0x887fff, "tgpcap_r", function(off, data, mask)
  if occ_out > 0 then
    occ_out = occ_out - 1
    if capturing then ev(EV_XPOP, nxpop, data); nxpop = nxpop + 1 end
  end
end)

TAP_RFR = rf:install_read_tap(1, 1, "tgpcap_rfr", function(off, data, mask)
  if occ_in > 0 then
    occ_in = occ_in - 1
    local want = queue[qh & 0xffff]; qh = qh + 1
    if want ~= data then pop_mismatch = pop_mismatch + 1 end
    parked = false
    if capturing then ev(EV_POP, npop, data); npop = npop + 1 end
  else
    parked = true
    if capturing then ev(EV_STALL, 0, 0) end
  end
end)

TAP_RFW = rf:install_write_tap(2, 3, "tgpcap_rfw", function(off, data, mask)
  if off == 2 then
    occ_out = occ_out + 1
    if capturing then ev(EV_OUT, nout, data); nout = nout + 1 end
  else
    bank = (bank & ~mask) | (data & mask)
    if capturing then ev(EV_BANK, 0, bank) end
  end
end)

TAP_IOW = io_:install_write_tap(0, 0xffff, "tgpcap_iow", function(off, data, mask)
  if (bank & 0xc00000) == 0 and off >= 0x20 and off <= 0x2b then
    if off <= 0x23 then sincos = data
    elseif off <= 0x27 then atan[(off & 3) + 1] = data
    elseif off <= 0x29 then inv = data
    else isqrt = data end
  end
  if capturing then ev(EV_IOWR, io_tag(off), data) end
end)

TAP_IOR = io_:install_read_tap(0, 0xffff, "tgpcap_ior", function(off, data, mask)
  if capturing then ev(EV_IORD, io_tag(off), data) end
end)

-- ------------------------------------------------------------- snapshot
local function snapshot()
  local f = assert(io.open(outdir .. "/state.txt", "w"))
  f:write(string.format("frame %d\n", frame))
  for _, k in ipairs({"GENPC", "CURFLAGS", "SP", "A", "B", "D", "P", "R", "RPC",
                      "C0", "C1", "B0", "B1", "X0", "X1", "I0", "I1", "SFT", "VSM",
                      "PCS0", "PCS1", "PCS2", "PCS3", "MASK", "M"}) do
    f:write(string.format("%s %x\n", k, tgp.state[k].value))
  end
  f:write(string.format("BANK %x\nSINCOS %x\nINV %x\nISQRT %x\n", bank, sincos, inv, isqrt))
  for i = 1, 4 do f:write(string.format("ATAN%d %x\n", i - 1, atan[i])) end
  f:write(string.format("OCC_OUT %x\nOCC_IN %x\nUPLOAD_WORDS %x\n", occ_out, occ_in, n_upload))
  f:close()
  dump_space(outdir .. "/dram.bin", ds, 0x000, 0x3ff)
  dump_space(outdir .. "/prog.bin", ps, 0x000, 0xfff)
  dump_region(outdir .. "/tables.bin", ":copro_tgp_tables")
  dump_region(outdir .. "/cdata.bin", ":copro_data")
  evf = assert(io.open(outdir .. "/events.bin", "wb"))
  print(string.format("TGPCAP snapshot at frame %d pc=%x occ_out=%d", frame, tgp.state["GENPC"].value, occ_out))
end

SUB = emu.add_machine_frame_notifier(function()
  frame = frame + 1
  -- inputs: race.lua's sequence (3 coins, then start presses)
  for _, f in ipairs({3000, 3020, 3040}) do
    if frame == f then coin:set_value(1) elseif frame == f + 8 then coin:set_value(0) end
  end
  for _, f in ipairs({3100, 3500, 3700, 3900, 4300, 4500}) do
    if frame == f then start:set_value(1) elseif frame == f + 10 then start:set_value(0) end
  end
  if done then return end
  if not capturing then
    if frame >= START and parked and occ_in == 0 then
      snapshot()
      capturing = true
      ev(EV_FRAME, frame, 0)
    end
  else
    cap_frames = cap_frames + 1
    if cap_frames >= NFR and parked and occ_in == 0 then
      ev(EV_FRAME, frame, 1)          -- b = 1: end of window
      flush(); evf:close()
      done = true
      print(string.format("TGPCAP end at frame %d: in=%d pops=%d out=%d i960pops=%d popmismatch=%d halfword_pushes_since_boot=%d",
                          frame, nin, npop, nout, nxpop, pop_mismatch, nhalf))
      manager.machine.video:snapshot()
      m:exit()
    else
      ev(EV_FRAME, frame, 0)
    end
  end
  if frame % 500 == 0 then
    print(string.format("TGPCAP frame %d occ_in=%d occ_out=%d parked=%s popmismatch=%d",
                        frame, occ_in, occ_out, tostring(parked), pop_mismatch))
  end
end)
