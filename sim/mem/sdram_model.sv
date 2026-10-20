// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 1 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE for the full text.
//
// Behavioural SDRAM device model that CHECKS THE PROTOCOL.
//
// WHY THIS EXISTS
//
// s32 ships an SDRAM testbench and it is not enough to build a controller
// against. Its device model returns `0xa000 ^ column` for every read — a
// column echo, not storage — so:
//
//   - the write path cannot be verified at all, because a read never returns
//     what was written to it;
//   - every command timing rule is unchecked. A controller that drives READ
//     one cycle after ACTIVATE, precharges a row it activated last cycle, or
//     never refreshes at all, passes.
//
// Those faults do not show up in simulation. They show up as a core that
// works on the author's board and hangs or corrupts on someone else's, at a
// different temperature, with a different SDRAM stick — which is the single
// worst failure mode to ship, because the person seeing it has no way to
// debug it and the author cannot reproduce it.
//
// So this model stores what is written, returns it, and asserts on every
// JEDEC timing rule the controller can violate. A controller is not
// considered working here until it runs a full traffic mix through this with
// `violations == 0`.
//
// CLOCKING CONTRACT
//
// Commands are sampled on posedge. Read data is presented CL cycles later,
// also on posedge, and the controller samples it on the following edge. The
// real board's +90-degree forwarded clock to the chip is a pin-timing matter
// handled by the PLL and the .sdc, and deliberately not modelled here: mixing
// physical phase into a protocol checker makes both harder to reason about.
//
// DQ is split into separate in/out/oe rather than a tri-state `inout`. That
// keeps the model and the controller Verilator-friendly, and the tri-state
// assign lives in one place at the top level where the physical pin is.

`timescale 1ns/1ps

module sdram_model #(
  parameter int unsigned ROW_BITS = 13,
  parameter int unsigned COL_BITS = 10,
  parameter int unsigned BA_BITS  = 2,
  parameter int unsigned DQ_BITS  = 16,

  // Timing, in clock cycles. Defaults are -7E parts at roughly 100 MHz, which
  // is the usual MiSTer operating point. They are parameters because the
  // right values depend on the clock the controller ends up running at, and a
  // model with the numbers baked in is a model that silently stops checking
  // when the clock changes.
  parameter int unsigned T_RCD = 2,    // ACTIVATE -> READ/WRITE
  parameter int unsigned T_RP  = 2,    // PRECHARGE -> ACTIVATE
  parameter int unsigned T_RC  = 7,    // ACTIVATE -> ACTIVATE, same bank
  parameter int unsigned T_RAS = 5,    // ACTIVATE -> PRECHARGE, same bank
  parameter int unsigned T_RRD = 2,    // ACTIVATE -> ACTIVATE, different bank
  parameter int unsigned T_WR  = 2,    // last write data -> PRECHARGE
  parameter int unsigned T_MRD = 2,    // MRS -> any other command
  parameter int unsigned CL    = 2,    // CAS latency

  // Refresh. 8192 rows in 64 ms at 100 MHz is one every 781 cycles on
  // average. Bursting is legal, so the check is against a generous multiple
  // rather than the average itself — a controller that refreshes in bursts of
  // eight is correct and must not be failed for it.
  parameter int unsigned T_REFI     = 781,
  parameter int unsigned REFI_SLACK = 9,

  parameter bit CHECK_REFRESH = 1'b1,
  parameter int unsigned MAX_REPORT = 20,

  // What a location nobody has written reads back as.
  //
  // Zero is the convenient answer and the misleading one: zero is a legal
  // instruction, a legal tile number and a black palette entry, so a core let
  // loose on empty memory looks far healthier here than it does on a board.
  // Storage is sparse and cannot be pre-filled cheaply, so the default comes
  // from a parameter instead. Left at zero so every existing harness keeps the
  // numbers it was baselined with.
  parameter logic [DQ_BITS-1:0] DEFAULT_DATA = '0,
  // R881: OR A HASH OF THE WORD ADDRESS (the top 16 bits of adr x 0x9E3779B1),
  // so a word delivered from the wrong address, port or burst slot reads as a
  // different value instead of as the same zero. 0: DEFAULT_DATA, as before.
  parameter bit DEFAULT_HASH = 1'b0,

  // R891: THE MiSTer 128 MB MODULE'S WIRING AND THE CHECKS A SECOND CHIP NEEDS.
  // All default off, so every harness built before them checks what it did.
  //   DQM_FROM_A  the chip's DQML/DQMH are wired to A11/A12 (the 128 MB
  //               module), not to the dqm pins -- the write mask is whatever
  //               A[12:11] carries during the WRITE, and a READ is masked by
  //               A[12:11] at its own edge (DQM read latency 2, CL 2)
  //   RD_DQM      DQM masks read data two edges later, as the part does: a
  //               masked byte comes back as its complement and is a
  //               violation (V_RD_TRUNC -- read data lost)
  //   CHECK_RET   a row not restored (ACTIVATE, PRECHARGE, or the REFRESH
  //               that reaches it through the chip's own row counter) within
  //               T_RET cycles LOSES ITS DATA -- every word of it reads as
  //               unwritten afterwards -- and V_DECAY is flagged. 64 ms at
  //               100 MHz is 6,400,000.
  //   CHECK_INIT  no ACTIVATE / READ / WRITE unless the last MRS had a
  //               PRECHARGE-all and two REFRESHes before it and a word of
  //               BL1, sequential, CL (V_INIT, once). The LAST one: a register
  //               file powers up as zeros, and cmd 0000 is an MRS -- the
  //               controller's cmd presents one before its synchronous reset
  //               lands (in simulation; on the board too, unless the register
  //               powers up at its reset value -- not established). Harmless
  //               either way: the bring-up's MRS follows it and is the one
  //               that counts.
  //   NAME        a prefix for this chip's messages
  parameter bit DQM_FROM_A = 1'b0,
  parameter bit RD_DQM     = 1'b0,
  parameter bit CHECK_RET  = 1'b0,
  parameter int unsigned T_RET = 6_400_000,
  parameter bit CHECK_INIT = 1'b0,
  parameter string NAME    = ""
) (
  input  logic                clk,
  input  logic                cke,
  input  logic                cs_n,
  input  logic                ras_n,
  input  logic                cas_n,
  input  logic                we_n,
  input  logic [BA_BITS-1:0]  ba,
  input  logic [ROW_BITS-1:0] a,
  input  logic [1:0]          dqm,

  // Controller -> device
  input  logic [DQ_BITS-1:0]  dq_i,
  input  logic                dq_oe_i,

  // Device -> controller
  output logic [DQ_BITS-1:0]  dq_o,
  output logic                dq_oe_o,

  // Observability. Every check that fires sets its bit in `v_flags` and bumps
  // `violations`. The bitmask matters: a harness proving this model has teeth
  // has to show that a specific injected fault trips its specific check, not
  // merely that something somewhere complained.
  output int unsigned         violations,
  output logic [15:0]         v_flags,
  output int unsigned         reads_served,
  output int unsigned         writes_served
);

  localparam int unsigned BANKS = 1 << BA_BITS;

  // Violation codes. Kept as localparams and mirrored in the harness so a
  // failure names the rule that broke rather than a bare index.
  localparam int V_ACT_OPEN   = 0;   // ACTIVATE on a bank with a row already open
  localparam int V_TRCD       = 1;
  localparam int V_TRAS       = 2;
  localparam int V_TRP        = 3;
  localparam int V_TRC        = 4;
  localparam int V_TRRD       = 5;
  localparam int V_NO_ROW     = 6;   // READ/WRITE with no open row
  localparam int V_TWR        = 7;
  localparam int V_REF_OPEN   = 8;   // REFRESH with a bank open
  localparam int V_REFRESH    = 9;   // refresh interval exceeded
  localparam int V_MRS_OPEN   = 10;  // MRS with a bank open
  localparam int V_TMRD       = 11;
  localparam int V_DQ_FIGHT   = 12;  // both ends driving DQ
  localparam int V_RD_TRUNC   = 13;  // PRECHARGE while read data still in flight
                                     // (R891: or read data masked by DQM)
  localparam int V_DECAY      = 14;  // R891: a row lost its data (not restored in T_RET)
  localparam int V_INIT       = 15;  // R891: access before the bring-up, or a bad MRS word

  // Command encoding, {cs_n, ras_n, cas_n, we_n}.
  localparam logic [3:0] C_NOP   = 4'b0111;
  localparam logic [3:0] C_ACT   = 4'b0011;
  localparam logic [3:0] C_READ  = 4'b0101;
  localparam logic [3:0] C_WRITE = 4'b0100;
  localparam logic [3:0] C_PRE   = 4'b0010;
  localparam logic [3:0] C_REF   = 4'b0001;
  localparam logic [3:0] C_MRS   = 4'b0000;

  wire logic [3:0] cmd = {cs_n, ras_n, cas_n, we_n};
  // A deselected device ignores everything; so does a device with CKE low.
  wire logic       active = cke && !cs_n;

  // Sparse storage. A 13/10/2 device is 33.5 M words, and a dense array would
  // cost 67 MB of simulator memory to hold a few thousand written locations.
  logic [DQ_BITS-1:0] mem [longint];

  logic                row_open [BANKS];
  logic [ROW_BITS-1:0] open_row [BANKS];
  longint              t_act    [BANKS];   // cycle of last ACTIVATE
  longint              t_pre    [BANKS];   // cycle of last PRECHARGE
  longint              t_wr     [BANKS];   // cycle of last WRITE data
  // Cycle by which this bank's outstanding read data has been delivered. A
  // PRECHARGE before then truncates the burst on real silicon and returns
  // nothing, which is a controller bug the model previously could not see.
  longint              rd_due   [BANKS];

  longint cyc;
  longint t_act_any;
  longint t_ref;
  longint t_mrs;
  logic   initialised;                     // MRS seen

  int unsigned reported;

  // Read return pipeline. Burst length is 1 in this controller's mode word, so
  // one entry per READ is enough; depth is CL+2 so the CL parameter can move
  // without reshaping anything.
  logic                rd_v   [CL+2];
  logic [DQ_BITS-1:0]  rd_d   [CL+2];

  // R881: what an unwritten word reads as
  function automatic logic [DQ_BITS-1:0] dflt(input longint ad);
    logic [31:0] h;
    h = 32'(ad) * 32'h9E3779B1;
    dflt = DEFAULT_HASH ? DQ_BITS'(h[31:16]) : DEFAULT_DATA;
  endfunction

  function automatic longint addr_of(input logic [BA_BITS-1:0] b,
                                     input logic [ROW_BITS-1:0] r,
                                     input logic [COL_BITS-1:0] c);
    addr_of = (longint'(b) << (ROW_BITS + COL_BITS))
            | (longint'(r) << COL_BITS)
            | longint'(c);
  endfunction

  // Blocking assignment inside a clocked process is flagged by -Wall, and in
  // synthesised RTL that warning is right. This is a behavioural device model,
  // never synthesised: the storage array, the address temporaries and the
  // violation counter all have to take effect immediately within the cycle
  // that computes them, which is exactly what blocking assignment means. The
  // waiver is scoped to this block rather than set globally so that a real
  // BLKSEQ fault elsewhere still fails the lint.
  /* verilator lint_off BLKSEQ */

  task automatic flag(input int code, input string msg);
    violations = violations + 1;
    v_flags[code] = 1'b1;
    if (reported < MAX_REPORT) begin
      reported = reported + 1;
      $display("SDRAM VIOLATION%s @%0d [%0d] %s", NAME, cyc, code, msg);
    end
  endtask

  // R891: RETENTION. A row's charge is restored by ACTIVATE (and held while
  // open, written back at PRECHARGE) and by the REFRESH that reaches it: the
  // chip's own counter steps one row (in every bank) per REFRESH. A row with
  // data whose last restore is more than T_RET ago has decayed: its words are
  // deleted, so they read as unwritten, as on a part that was not refreshed.
  localparam int unsigned NROWS = 1 << ROW_BITS;
  longint ref_t [NROWS];                 // cycle the counter last refreshed row r
  int unsigned ref_row;                  // the chip's refresh counter
  longint rst_t [longint];               // {bank,row} -> last ACTIVATE / PRECHARGE
  bit     has_dat [longint];             // {bank,row} -> holds written data
  int unsigned decayed_rows;
  function automatic longint rkey(input int unsigned b, input int unsigned r);
    rkey = (longint'(b) << ROW_BITS) | longint'(r);
  endfunction
  task automatic decay_check(input int unsigned b, input int unsigned r);
    longint key, last, ad;
    key = rkey(b, r);
    if (CHECK_RET && has_dat.exists(key)) begin
      last = ref_t[r];
      if (rst_t.exists(key) && rst_t[key] > last) last = rst_t[key];
      if (cyc - last > longint'(T_RET)) begin
        flag(V_DECAY, $sformatf("bank %0d row %0d not restored for %0d cycles -- its data is lost",
                                b, r, cyc - last));
        for (int unsigned c = 0; c < (1 << COL_BITS); c++) begin
          ad = addr_of(BA_BITS'(b), ROW_BITS'(r), COL_BITS'(c));
          if (mem.exists(ad)) mem.delete(ad);
        end
        has_dat.delete(key);
        decayed_rows = decayed_rows + 1;
      end
    end
  endtask
  // R891: BRING-UP ORDER (CHECK_INIT)
  logic   ini_pre_seen;
  int unsigned ini_refs;
  logic   ini_ok;
  logic   ini_flagged;
  string  ini_why;
  // R891: the mask the chip sees, and its two-edge read-mask pipeline
  wire  [1:0]          dqm_e = DQM_FROM_A ? a[12:11] : dqm;
  logic [1:0]          dqm_p1, dqm_p0;

  int unsigned bi;
  initial begin
    cyc = 0; t_act_any = -1000; t_ref = 0; t_mrs = -1000;
    violations = 0; v_flags = '0; reported = 0; initialised = 1'b0;
    reads_served = 0; writes_served = 0;
    dq_o = '0; dq_oe_o = 1'b0;
    for (bi = 0; bi < BANKS; bi = bi + 1) begin
      row_open[bi] = 1'b0; open_row[bi] = '0;
      t_act[bi] = -1000; t_pre[bi] = -1000; t_wr[bi] = -1000;
      rd_due[bi] = -1000;
    end
    for (bi = 0; bi < CL+2; bi = bi + 1) begin rd_v[bi] = 1'b0; rd_d[bi] = '0; end
    for (bi = 0; bi < NROWS; bi = bi + 1) ref_t[bi] = 0;   // R891
    ref_row = 0; decayed_rows = 0;
    ini_pre_seen = 1'b0; ini_refs = 0; ini_ok = 1'b0; ini_flagged = 1'b0; ini_why = "no MRS";
    dqm_p1 = '0; dqm_p0 = '0;
  end

  int unsigned k;
  logic [COL_BITS-1:0] col;
  logic [11:0]         colfull;
  assign colfull = {a[12], a[11], a[9:0]};
  longint              adr;
  logic [DQ_BITS-1:0]  cur;
  longint              eff_pre;

  always @(posedge clk) begin
    cyc <= cyc + 1;

    // Advance the read return pipeline first, so a READ issued this cycle
    // lands in slot 0 below and emerges exactly CL cycles later.
    for (k = 0; k < CL+1; k = k + 1) begin
      rd_v[k] <= rd_v[k+1];
      rd_d[k] <= rd_d[k+1];
    end
    rd_v[CL+1] <= 1'b0;

    dq_oe_o <= rd_v[0];
    dq_o    <= rd_d[0];
    // R891: DQM AT A READ'S OWN EDGE MASKS ITS DATA (read latency 2 at CL 2):
    // a masked byte is not driven, so it reads as anything -- here its
    // complement, and it is a violation, because nothing in this controller
    // means to mask a read.
    dqm_p1 <= dqm_e;
    dqm_p0 <= dqm_p1;
    if (RD_DQM && rd_v[0] && (dqm_p0 != 2'b00)) begin
      dq_o <= rd_d[0] ^ {{8{dqm_p0[1]}}, {8{dqm_p0[0]}}};
      flag(V_RD_TRUNC, $sformatf("read data masked by DQM (%b)", dqm_p0));
    end

    // Both ends driving the bus is a controller bug that a tri-state model
    // would hide behind an X. Name it.
    //
    // Compare the state in which the device is ACTUALLY driving, dq_oe_o, not
    // rd_v[0] which is one edge earlier. The first version compared rd_v[0]
    // and so checked the cycle before the device took the bus — a controller
    // whose write data landed exactly one cycle later, which is the natural
    // spacing its own state machine produces, collided for real and passed.
    // The check existed, named the right hazard, and could not fire.
    if (dq_oe_o && dq_oe_i) flag(V_DQ_FIGHT, "controller drives DQ during read data");

    if (CHECK_REFRESH && initialised && (cyc - t_ref) > longint'(T_REFI) * longint'(REFI_SLACK)) begin
      flag(V_REFRESH, $sformatf("no REFRESH for %0d cycles", cyc - t_ref));
      t_ref <= cyc;   // report once per overrun, not every cycle after
    end

    if (active) begin
      // Anything other than MRS itself must respect tMRD after one.
      if (cmd != C_NOP && (cyc - t_mrs) < longint'(T_MRD) && t_mrs > 0)
        flag(V_TMRD, "command inside tMRD after MRS");

      case (cmd)
        C_MRS: begin
          for (k = 0; k < BANKS; k = k + 1)
            if (row_open[k]) flag(V_MRS_OPEN, "MRS with a bank open");
          t_mrs <= cyc;
          initialised <= 1'b1;
          t_ref <= cyc;
          // R891: the mode word this controller relies on -- burst length 1,
          // sequential, CAS latency CL, burst writes -- and the bring-up before it
          ini_ok  = (a[2:0] == 3'b000) && !a[3] && (a[6:4] == 3'(CL)) && !a[9] && (ba == '0)
                    && ini_pre_seen && (ini_refs >= 2);
          ini_why = $sformatf("the last MRS (@%0d) had word %04x (BL1, sequential, CL%0d wanted), %0s, %0d REFRESHes",
                              cyc, a, CL, ini_pre_seen ? "a PRECHARGE-all" : "NO PRECHARGE-all", ini_refs);
        end

        C_ACT: begin
          if (CHECK_INIT && !ini_ok && !ini_flagged) begin
            flag(V_INIT, {"ACTIVATE before the bring-up: ", ini_why}); ini_flagged = 1'b1;
          end
          decay_check(int'(ba), int'(a));        // R891: was it still there?
          rst_t[rkey(int'(ba), int'(a))] = cyc;
          if (row_open[ba])
            flag(V_ACT_OPEN, $sformatf("ACTIVATE bank %0d with row %0d still open",
                                       ba, open_row[ba]));
          if ((cyc - t_pre[ba]) < longint'(T_RP) && t_pre[ba] > 0)
            flag(V_TRP, $sformatf("tRP: ACTIVATE %0d cycles after PRECHARGE",
                                  cyc - t_pre[ba]));
          if ((cyc - t_act[ba]) < longint'(T_RC) && t_act[ba] > 0)
            flag(V_TRC, $sformatf("tRC: ACTIVATE %0d cycles after ACTIVATE, same bank",
                                  cyc - t_act[ba]));
          if ((cyc - t_act_any) < longint'(T_RRD) && t_act_any > 0)
            flag(V_TRRD, $sformatf("tRRD: ACTIVATE %0d cycles after another ACTIVATE",
                                   cyc - t_act_any));
          row_open[ba] <= 1'b1;
          open_row[ba] <= a;
          t_act[ba]    <= cyc;
          t_act_any    <= cyc;
        end

        C_READ, C_WRITE: begin
          if (CHECK_INIT && !ini_ok && !ini_flagged) begin
            flag(V_INIT, {"READ / WRITE before the bring-up: ", ini_why}); ini_flagged = 1'b1;
          end
          if (!row_open[ba]) begin
            flag(V_NO_ROW, $sformatf("%s bank %0d with no open row",
                                     (cmd == C_READ) ? "READ" : "WRITE", ba));
          end else begin
            if ((cyc - t_act[ba]) < longint'(T_RCD))
              flag(V_TRCD, $sformatf("tRCD: access %0d cycles after ACTIVATE",
                                     cyc - t_act[ba]));
            // COLUMN BITS MAP TO A0..A9 THEN A11, A12 -- never A10, which is
            // the auto-precharge flag this same model tests at line ~340. A
            // straight slice a[COL_BITS-1:0] is correct up to TEN column bits
            // and wrong at eleven, where it takes the precharge flag as a
            // column bit. That made a correct 128 MB controller look broken:
            // 3,965 data mismatches with ZERO protocol violations.
            col = colfull[COL_BITS-1:0];
            adr = addr_of(ba, open_row[ba], col);
            if (cmd == C_READ) begin
              rd_due[ba] <= cyc + longint'(CL);
              // Slot CL-1, not CL. A READ at edge T must present data after
              // edge T+CL. The entry lands in slot S at edge T and reaches
              // slot 0 after edge T+S, and dq_o is registered from rd_d[0] one
              // edge after that — so S = CL-1. Slot CL would deliver at T+CL+1.
              // Traced rather than discovered by a failing run, because this
              // exact off-by-one has cost this project five debugging sessions
              // already and it always looks like broken hardware.
              rd_v[CL-1] <= 1'b1;
              rd_d[CL-1] <= mem.exists(adr) ? mem[adr] : dflt(adr);
              reads_served <= reads_served + 1;
            end else begin
              cur = mem.exists(adr) ? mem[adr] : dflt(adr);
              // DQM is active-high mask: a set bit suppresses that byte.
              // R891: dqm_e -- A[12:11] on a module wired that way
              if (!dqm_e[0]) cur[7:0]  = dq_i[7:0];
              if (!dqm_e[1]) cur[15:8] = dq_i[15:8];
              mem[adr] = cur;
              has_dat[rkey(int'(ba), int'(open_row[ba]))] = 1'b1;   // R891
              t_wr[ba] <= cyc;
              writes_served <= writes_served + 1;
            end
          end
          // A10 high on READ/WRITE requests auto-precharge, which the
          // controller uses on the final CAS of every read burst.
          //
          // The subtlety that makes this worth modelling rather than ignoring:
          // the device does NOT precharge immediately. It delays internally
          // until tRAS(min) is satisfied, so an auto-precharge that lands
          // early is legal and must not be flagged as a tRAS violation. What
          // it does affect is tRP for the next ACTIVATE to that bank, which is
          // measured from the effective precharge point, not from the CAS. A
          // model that closed the row at the CAS edge would let a controller
          // re-activate too early and call it correct.
          //
          // The tRAS clamp below is datasheet fidelity, NOT a checked
          // behaviour, and mutation testing is what established the
          // difference: deleting it changes no test result. The reason is
          // structural. The next ACTIVATE to this bank is bounded by
          // eff_pre + tRP, which with the clamp is tRAS + tRP — and tRC is
          // *defined* as tRAS + tRP, so the tRC check always binds first. It
          // is kept because a model should describe the device rather than
          // only the parts one controller can observe, but it is deliberately
          // not claimed as covered.
          if (a[10] && row_open[ba]) begin
            eff_pre = (cmd == C_READ) ? (cyc + 1) : (cyc + longint'(T_WR));
            if (eff_pre < t_act[ba] + longint'(T_RAS))
              eff_pre = t_act[ba] + longint'(T_RAS);
            row_open[ba] <= 1'b0;
            t_pre[ba]    <= eff_pre;
            rst_t[rkey(int'(ba), int'(open_row[ba]))] = cyc;   // R891: written back
          end
        end

        C_PRE: begin
          if (a[10]) begin ini_pre_seen = 1'b1; ini_refs = 0; end   // R891
          for (k = 0; k < BANKS; k = k + 1) begin
            // A10 selects precharge-all over the addressed bank.
            if (a[10] || (BA_BITS'(k) == ba)) begin
              if (row_open[k]) begin
                if (cyc < rd_due[k])
                  flag(V_RD_TRUNC, $sformatf("PRECHARGE bank %0d truncates read data", k));
                if ((cyc - t_act[k]) < longint'(T_RAS))
                  flag(V_TRAS, $sformatf("tRAS: PRECHARGE %0d cycles after ACTIVATE",
                                         cyc - t_act[k]));
                if ((cyc - t_wr[k]) < longint'(T_WR) && t_wr[k] > 0)
                  flag(V_TWR, $sformatf("tWR: PRECHARGE %0d cycles after WRITE",
                                        cyc - t_wr[k]));
                t_pre[k] <= cyc;
                rst_t[rkey(k, int'(open_row[k]))] = cyc;   // R891: written back
              end
              row_open[k] <= 1'b0;
            end
          end
        end

        C_REF: begin
          for (k = 0; k < BANKS; k = k + 1)
            if (row_open[k]) flag(V_REF_OPEN, $sformatf("REFRESH with bank %0d open", k));
          t_ref <= cyc;
          // R891: the counter's row, in every bank -- lost already if it waited too long
          for (k = 0; k < BANKS; k = k + 1) decay_check(k, ref_row);
          ref_t[ref_row] = cyc;
          ref_row = (ref_row + 1) % NROWS;
          if (ini_pre_seen) ini_refs = ini_refs + 1;
        end

        default: ; // NOP / deselect
      endcase
    end
  end

  /* verilator lint_on BLKSEQ */

endmodule

// R891: THE MiSTer 128 MB SDRAM MODULE -- two 64 MB chips (13 rows, 10
// columns, 4 banks each) on one chip-select line: chip 0 takes cs_n, chip 1
// its inverse; DQ shared; each chip's DQML/DQMH wired to A11/A12
// (DQM_FROM_A). CHIPS = 1 is the 64 MB module: one chip on cs_n, and a
// command with cs_n high -- the controller's chip-1 commands -- is a
// deselect it ignores. Each chip is a full sdram_model, so every rule is
// checked per chip; two chips driving DQ at once is a fight.
module sdram_module #(
  parameter int unsigned CHIPS    = 2,
  parameter int unsigned ROW_BITS = 13,
  parameter int unsigned COL_BITS = 10,
  parameter int unsigned T_RCD = 2, T_RP = 2, T_RC = 7, T_RAS = 5, T_RRD = 2,
  parameter int unsigned T_WR = 2, T_MRD = 2, CL = 2,
  parameter int unsigned T_REFI = 781, REFI_SLACK = 9,
  parameter logic [15:0] DEFAULT_DATA = '0,
  parameter bit DEFAULT_HASH = 1'b0,
  parameter bit DQM_FROM_A = 1'b1,
  parameter bit RD_DQM     = 1'b1,
  parameter bit CHECK_RET  = 1'b1,
  parameter int unsigned T_RET = 6_400_000,
  parameter bit CHECK_INIT = 1'b1
) (
  input  logic                clk, cke, cs_n, ras_n, cas_n, we_n,
  input  logic [1:0]          ba,
  input  logic [ROW_BITS-1:0] a,
  input  logic [1:0]          dqm,
  input  logic [15:0]         dq_i,
  input  logic                dq_oe_i,
  output logic [15:0]         dq_o,
  output logic                dq_oe_o,
  output int unsigned         violations,
  output logic [15:0]         v_flags,
  output int unsigned         reads_served,
  output int unsigned         writes_served,
  output int unsigned         decayed_rows      // R891: rows that lost their data
);
  logic [15:0] o0, o1;
  logic        e0, e1;
  int unsigned v0, v1, r0, r1, w0, w1;
  logic [15:0] f0, f1;
  int unsigned fights;
  initial fights = 0;

  sdram_model #(.ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .T_RCD(T_RCD), .T_RP(T_RP),
    .T_RC(T_RC), .T_RAS(T_RAS), .T_RRD(T_RRD), .T_WR(T_WR), .T_MRD(T_MRD), .CL(CL),
    .T_REFI(T_REFI), .REFI_SLACK(REFI_SLACK), .DEFAULT_DATA(DEFAULT_DATA),
    .DEFAULT_HASH(DEFAULT_HASH), .DQM_FROM_A(DQM_FROM_A), .RD_DQM(RD_DQM),
    .CHECK_RET(CHECK_RET), .T_RET(T_RET), .CHECK_INIT(CHECK_INIT), .NAME(" chip0")
  ) chip0 (
    .clk(clk), .cke(cke), .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
    .ba(ba), .a(a), .dqm(dqm), .dq_i(dq_i), .dq_oe_i(dq_oe_i), .dq_o(o0), .dq_oe_o(e0),
    .violations(v0), .v_flags(f0), .reads_served(r0), .writes_served(w0)
  );

  generate if (CHIPS > 1) begin : g_chip1
    sdram_model #(.ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .T_RCD(T_RCD), .T_RP(T_RP),
      .T_RC(T_RC), .T_RAS(T_RAS), .T_RRD(T_RRD), .T_WR(T_WR), .T_MRD(T_MRD), .CL(CL),
      .T_REFI(T_REFI), .REFI_SLACK(REFI_SLACK), .DEFAULT_DATA(DEFAULT_DATA),
      .DEFAULT_HASH(DEFAULT_HASH), .DQM_FROM_A(DQM_FROM_A), .RD_DQM(RD_DQM),
      .CHECK_RET(CHECK_RET), .T_RET(T_RET), .CHECK_INIT(CHECK_INIT), .NAME(" chip1")
    ) chip1 (
      .clk(clk), .cke(cke), .cs_n(~cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
      .ba(ba), .a(a), .dqm(dqm), .dq_i(dq_i), .dq_oe_i(dq_oe_i), .dq_o(o1), .dq_oe_o(e1),
      .violations(v1), .v_flags(f1), .reads_served(r1), .writes_served(w1)
    );
    assign decayed_rows = chip0.decayed_rows + chip1.decayed_rows;
  end else begin : g_one
    assign o1 = '0; assign e1 = 1'b0; assign f1 = '0;
    assign v1 = 0; assign r1 = 0; assign w1 = 0;
    assign decayed_rows = chip0.decayed_rows;
  end endgenerate

  always @(posedge clk)
    if (e0 && e1) begin
      fights <= fights + 1;
      if (fights < 20) $display("SDRAM VIOLATION both chips drive DQ");
    end

  assign dq_o          = e1 ? o1 : o0;
  assign dq_oe_o       = e0 | e1;
  assign violations    = v0 + v1 + fights;
  assign v_flags       = f0 | f1 | ((fights != 0) ? 16'h1000 : 16'h0000);   // V_DQ_FIGHT
  assign reads_served  = r0 + r1;
  assign writes_served = w0 + w1;
endmodule
