// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sega Model 2 core for MiSTer FPGA
// Copyright (C) 2026 alphanu1
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE for the full text.
//
// ---------------------------------------------------------------------------
//
// R927: A DATA CACHE ON THE CPU'S SIDE OF THE BRIDGE, for board RAM and work
// RAM only.
//
// WHY. Every data read the i960 makes crosses into the memory clock and back
// through m2_cpu_bridge, even when the bridge's own data cache holds the line:
// the request toggles across, the cache answers in S_DCK, the completion
// toggles back -- five CPU cycles for a hit, against the one the load would
// need. Sega Rally's race code (R926) runs from work RAM and lives in it: its
// loads are most of the 30% of the frame start spent waiting on data.
//
// WHAT. Direct-mapped, LINES lines of 16 bytes, A WORD ALLOCATED PER MISS:
// each line has a tag and four word valid bits, a read the bridge answers
// installs its word (a new tag drops the line's other words), and nothing is
// ever fetched that was not asked for -- the bus sees exactly the traffic it
// saw before, less the reads this answers. Write-through: every write still
// goes to the bridge as before, and one that lands in a line held here
// updates its bytes too (and makes a full-word write's word valid). A hit is
// answered the cycle after the request, from the data array's registered read.
//
// WHY THIS IS COHERENT. Board RAM and work RAM are written by the CPU alone
// once it runs (m2_cpu_bridge's own data cache rests on the same fact: "work
// RAM, char RAM and backup are CPU-only"), and every CPU write to them passes
// this module -- loads, stores, frame spills, the interrupt path's saves, the
// synmov writes -- whichever master the arbiter granted. The boot's RAM sweeps
// (R900) run while the CPU is in reset; reset sweeps every valid bit here, as
// the bridge's cache does. Buffer RAM (written by the TGP) and everything else
// is never cached. On the original board's map (BOARD_2A = 0) 0x220000-
// 0x23ffff is a ROM mirror that ignores writes, so only 0x200000-0x21ffff is
// cached there.
//
// It is architecturally invisible, like i960_icache: MAME has no data cache,
// and nothing the CPU computes can differ, only when.
//
// STORAGE. The data in four byte-lane M10K arrays (the project rule: lanes,
// tagged, never cleared in reset); the tags with their valid bits in LUT RAM,
// read asynchronously so a hit is known in the request's own cycle -- which it
// must be, to keep the request off the bridge -- and swept one line a cycle at
// reset, as i960_icache's are (R768).

module i960_dcache #(
  parameter int unsigned LINES    = 256,   // x 16 B: 4 KB
  // 1: the data in four byte lanes, a partial write merged into a held word.
  // 0: one 32-bit array (one M10K up to 1 KB), a partial write DROPS the word
  // it lands in (its valid bit cleared) and the next read refetches it.
  parameter bit          LANES    = 1'b1,
  parameter bit          BOARD_2A = 1'b1,
  // The lockstep bench (sim/i960/tb_i960_top.cpp) runs its programs and data
  // below 0x10000: 1 caches everything below 0x800000 so it can see this.
  parameter bit          TEST_ALL = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,

  // The arbiter's transaction this cycle.
  input  logic        req,        // a request is presented
  input  logic        rd_ok,      // ...by a master this may answer (load / store unit, frame fill)
  input  logic        we,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] addr,       // [1:0] unused: a word holds every byte a read can ask for
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [3:0]  be,
  input  logic [31:0] wdata,
  input  logic        ack_x,      // the bridge's acknowledge
  input  logic [31:0] rdata_x,    // ...and its read data

  output logic        take,       // answered here: keep it off the bridge (combinational)
  output logic        ack,        // the answer, the cycle after
  output logic [31:0] rdata,

  output logic [31:0] dbg_hits,
  output logic [31:0] dbg_miss
);

  localparam int unsigned IW = $clog2(LINES);   // index bits
  localparam int unsigned TW = 23 - IW - 4;     // tag: addr[22:IW+4] (cached space < 0x800000)

  // ------------------------------------------------------------ what is cached
  wire cacheable = (addr[31:23] == 9'd0) && (TEST_ALL ||
                   (addr[22:20] == 3'h5) ||                                      // work RAM
                    (BOARD_2A ? (addr[22:18] == 5'h08) : (addr[22:17] == 6'h10)));   // board RAM

  wire [IW-1:0] idx  = addr[IW+3:4];
  wire [TW-1:0] tagv = addr[22:IW+4];
  wire [1:0]    wsel = addr[3:2];

  // --------------------------------------------------------------- the tags
  // {valid[3:0], tag}. LUT RAM, asynchronous read, one write port, never
  // cleared by reset (swept instead).
  (* ramstyle = "MLAB, no_rw_check" *) logic [TW+3:0] ctag [0:LINES-1];
  wire  [TW+3:0] trd    = ctag[idx];
  wire           tmatch = (trd[TW-1:0] == tagv);
  wire  [3:0]    tval   = trd[TW+3:TW];

  logic          sweeping;
  logic [IW-1:0] sweep_idx;

  // ------------------------------------------------------------- the lookup
  logic pend;   // a hit taken last cycle, answered this one
  assign take = req && rd_ok && !we && cacheable && !sweeping && !pend
             && tmatch && tval[wsel];
  assign ack  = pend;

  // A read the bridge answered, or a write it accepted, on a cached address.
  wire fill = req && rd_ok && !we && cacheable && ack_x && !sweeping;
  wire wupd = req && we && cacheable && ack_x && !sweeping && tmatch;

  // --------------------------------------------------------------- the data
  wire  [IW+1:0] waddr = {idx, wsel};
  wire  [31:0]   wd    = fill ? rdata_x : wdata;
  generate if (LANES) begin : g_lanes
    logic [7:0] q0, q1, q2, q3;
    assign rdata = {q3, q2, q1, q0};
    wire  [3:0] lane = fill ? 4'hf : (wupd ? be : 4'h0);
    i960_dc_lane #(.AW(IW+2)) u_l0 (.clk(clk), .we(lane[0]), .wa(waddr), .wd(wd[7:0]),   .ra(waddr), .q(q0));
    i960_dc_lane #(.AW(IW+2)) u_l1 (.clk(clk), .we(lane[1]), .wa(waddr), .wd(wd[15:8]),  .ra(waddr), .q(q1));
    i960_dc_lane #(.AW(IW+2)) u_l2 (.clk(clk), .we(lane[2]), .wa(waddr), .wd(wd[23:16]), .ra(waddr), .q(q2));
    i960_dc_lane #(.AW(IW+2)) u_l3 (.clk(clk), .we(lane[3]), .wa(waddr), .wd(wd[31:24]), .ra(waddr), .q(q3));
  end else begin : g_word
    i960_dc_word #(.AW(IW+2)) u_w (.clk(clk), .we(fill || (wupd && (be == 4'hf))), .wa(waddr), .wd(wd),
                                   .ra(waddr), .q(rdata));
  end endgenerate

  // ---------------------------------------------------------- the tag write
  // One port: the sweep, a fill (the word valid, the rest kept if the tag is
  // this line's, else dropped), or a full-word write hit (its word valid).
  wire [3:0] wbit = 4'b0001 << wsel;
  always_ff @(posedge clk) begin
    if (sweeping)
      ctag[sweep_idx] <= '0;
    else if (fill)
      ctag[idx] <= {(tmatch ? tval : 4'd0) | wbit, tagv};
    else if (wupd && (be == 4'hf))
      ctag[idx] <= {tval | wbit, tagv};
    else if (wupd && !LANES)
      ctag[idx] <= {tval & ~wbit, tagv};   // a partial write the one array cannot merge
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pend      <= 1'b0;
      sweeping  <= 1'b1;
      sweep_idx <= '0;
      dbg_hits  <= 32'd0;
      dbg_miss  <= 32'd0;
    end else begin
      pend <= take;
      if (take) dbg_hits <= dbg_hits + 32'd1;
      if (fill) dbg_miss <= dbg_miss + 32'd1;
      if (sweeping) begin
        sweep_idx <= sweep_idx + 1'b1;
        if (sweep_idx == IW'(LINES - 1)) sweeping <= 1'b0;
      end
    end
  end

endmodule

// One byte lane of the data: simple dual port, registered read, never cleared.
module i960_dc_lane #(
  parameter int unsigned AW = 10
) (
  input  logic          clk,
  input  logic          we,
  input  logic [AW-1:0] wa,
  input  logic [7:0]    wd,
  input  logic [AW-1:0] ra,
  output logic [7:0]    q
);
  (* ramstyle = "M10K, no_rw_check" *) logic [7:0] mem [0:(1 << AW) - 1];
  always_ff @(posedge clk) begin
    if (we) mem[wa] <= wd;
    q <= mem[ra];
  end
endmodule

// The data as one 32-bit array (LANES = 0).
module i960_dc_word #(
  parameter int unsigned AW = 8
) (
  input  logic          clk,
  input  logic          we,
  input  logic [AW-1:0] wa,
  input  logic [31:0]   wd,
  input  logic [AW-1:0] ra,
  output logic [31:0]   q
);
  (* ramstyle = "M10K, no_rw_check" *) logic [31:0] mem [0:(1 << AW) - 1];
  always_ff @(posedge clk) begin
    if (we) mem[wa] <= wd;
    q <= mem[ra];
  end
endmodule
