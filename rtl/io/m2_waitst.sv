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
// R904: THE i960'S WAIT STATES, between i960_top and m2_cpu_bridge on the
// CPU's own clock (clk_i960). Model2.sv builds it only with M2_2A_WAITST and
// turns it on (`en`) for Sega Rally alone (game ID 0x10); with `en` low every
// output is its input and the CPU sees the bus it saw before.
//
// THE BLOCK. 0x00E00000-0x00E00037, 14 words (MAME model2.cpp: ".ram(); //
// CPU control (wait-states)"). Every game copies a 14-word table there in its
// first instructions (Sega Rally: program 0x3e0, `10 02 42 02 10 10 10 10 08
// 10 10 10 10 10`) and none was seen to read it back (study R904). Writes are
// stored here (byte lanes, an MLAB) and reads return them, as MAME's RAM does;
// the bridge never sees an access to the block while `en` is high.
//
// THE FORMAT IS NOT DOCUMENTED, and both halves of this module that depend on
// it are parameters (R904 has the measurements and the expert's questions):
//   ONEHOT  1: a word's count is the position of its lowest set bit in 5:0
//              (0x01 = 0, 0x02 = 1, 0x04 = 2, 0x08 = 3, 0x10 = 4, 0x20 = 5) --
//              every value any game writes has exactly one bit set there, and
//              0x42 (bits 6 and 1) is the work-RAM word on every board;
//           0: bits 5:0 are the count in binary (the expert's description:
//              "set 10, the read takes 1 + 10 + 1 cycles"); bit 6 dropped.
//   region_of() below: which word governs which address -- inferred from the
//              values, not measured.
//
// THE SEMANTICS (EXTRA). The expert's bus cycle is address + N waits + data,
// 2 + N cycles. On the board those waits ARE the memory's access time; here
// the SDRAM behind the bridge is that access time, and already takes longer
// than two cycles on a miss.
//   EXTRA 0 (default): a MINIMUM. An access is never answered before cycle
//           2 + N from its first; an answer the bridge has sooner is held
//           (data latched, the bridge kept off the bus) until then, and one
//           that comes later passes as it is. Our accesses are never made
//           faster than the board's and never slower than they already are.
//   EXTRA 1: N cycles ON TOP: the request is shown to the bridge only from
//           cycle N, so every access takes N more than it does now.
//   BURST 1 (default): an access that follows its predecessor with no gap,
//           in the same direction and the same 16-byte line (the i-cache's
//           line fill, ldl / ldq) is a burst's next word -- 1 + N, the
//           address cycle once per burst, as on the i960KB's bus.
// Instruction fetches the i-cache answers never reach this bus, as on the
// chip. Designed against the bridge's registered acknowledge (FAST_ACK 0,
// what Model2.sv builds): its answer never comes in an access's first cycle.

`timescale 1ns/1ps

module m2_waitst #(
  parameter bit ONEHOT = 1'b1,
  parameter bit EXTRA  = 1'b0,
  parameter bit BURST  = 1'b1
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        en,          // quasi-static: the switch and the game ID

  // the i960 (i960_top's bus)
  input  logic        c_req,
  input  logic        c_we,
  input  logic [31:0] c_addr,
  input  logic  [3:0] c_be,
  input  logic [31:0] c_wdata,
  output logic [31:0] c_rdata,
  output logic        c_ack,

  // the bridge (m2_cpu_bridge's bus; the payload is the CPU's, unchanged)
  output logic        b_req,
  input  logic [31:0] b_rdata,
  input  logic        b_ack,

  // the access's region and its count, for a bench
  output logic  [3:0] dbg_region,
  output logic  [5:0] dbg_n
);

  // -------------------------------------------------------------- the block
  wire blk = c_req && (c_addr[31:6] == 26'h0038000) && (c_addr[5:2] <= 4'd13);

  (* ramstyle = "MLAB, no_rw_check" *) logic [7:0] mem0 [16];
  (* ramstyle = "MLAB, no_rw_check" *) logic [7:0] mem1 [16];
  (* ramstyle = "MLAB, no_rw_check" *) logic [7:0] mem2 [16];
  (* ramstyle = "MLAB, no_rw_check" *) logic [7:0] mem3 [16];
  logic [31:0] blk_q;
  logic        blk_we;
  always_ff @(posedge clk) begin
    if (blk_we && c_be[0]) mem0[c_addr[5:2]] <= c_wdata[7:0];
    if (blk_we && c_be[1]) mem1[c_addr[5:2]] <= c_wdata[15:8];
    if (blk_we && c_be[2]) mem2[c_addr[5:2]] <= c_wdata[23:16];
    if (blk_we && c_be[3]) mem3[c_addr[5:2]] <= c_wdata[31:24];
    blk_q <= {mem3[c_addr[5:2]], mem2[c_addr[5:2]], mem1[c_addr[5:2]], mem0[c_addr[5:2]]};
  end

  // Each word's count, decoded as it is written (byte 0 holds every value
  // seen). Cleared by the CPU's reset; the boot writes them again at once.
  /* verilator lint_off UNUSEDSIGNAL */   // bits 7:6 (0x42's flag) carry no count
  function automatic logic [5:0] count_of(input logic [7:0] v);
    if (!ONEHOT)    count_of = v[5:0];
    else if (v[0])  count_of = 6'd0;
    else if (v[1])  count_of = 6'd1;
    else if (v[2])  count_of = 6'd2;
    else if (v[3])  count_of = 6'd3;
    else if (v[4])  count_of = 6'd4;
    else if (v[5])  count_of = 6'd5;
    else            count_of = 6'd0;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */
  logic [5:0] cnt_w [16];   // 14 used; 16 so a 4-bit index cannot leave the array

  // WHICH WORD GOVERNS AN ADDRESS -- INFERRED (R904), MAME's 2A-CRX map in
  // address order. Words 0-3 are the ones every game sets alike apart from
  // word 0 (program ROM: 0x04 on 256-512 KB programs, 0x10 on Sega Rally's,
  // Zero Gunner's and Pilot Kids' 1 MB), words 1-3 the three RAMs. 15: none.
  /* verilator lint_off UNUSEDSIGNAL */   // the decode reads the high bits only
  function automatic logic [3:0] region_of(input logic [31:0] a);
    if      (a[31:21] == 11'h000)                    region_of = 4'd0;   // program ROM   0x00000000
    else if (a[31:22] == 10'h000)                    region_of = 4'd1;   // board RAM     0x00200000
    else if (a[31:23] == 9'h000)                     region_of = 4'd2;   // work RAM      0x00500000
    else if (a[31:19] == 13'h0012)                   region_of = 4'd3;   // buffer RAM    0x00900000
    else if (a[31:19] == 13'h0010)                   region_of = 4'd4;   // geometrizer   0x00800000
    else if (a[31:23] == 9'h001 && !a[22])           region_of = 4'd5;   // copro         0x00880000, 0x00980000
    else if (a[31:23] == 9'h001)                     region_of = 4'd6;   // system        0x00e00000
    else if (a[31:23] == 9'h002)                     region_of = 4'd7;   // tile, char    0x01000000
    else if (a[31:25] == 7'h01)                      region_of = 4'd8;   // data ROM      0x02000000
    else if (a[31:21] == 11'h00c)                    region_of = 4'd9;   // palette       0x01800000
    else if (a[31:21] == 11'h00d)                    region_of = 4'd10;  // comm          0x01a00000
    else if (a[31:22] == 10'h007)                    region_of = 4'd11;  // I/O, backup   0x01c00000
    else if (a[31:28] == 4'h1 && !a[25])             region_of = 4'd12;  // renderer      0x10000000
    else if (a[31:28] == 4'h1)                       region_of = 4'd13;  // texture, luma 0x12000000
    else if (a[31:26] == 6'h01)                      region_of = 4'd8;   // data ROM      0x06000000
    else                                             region_of = 4'd15;
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */
  wire [3:0] rg     = region_of(c_addr);
  wire [5:0] n_comb = cnt_w[rg];   // 14 and 15 are never written: 0

  // -------------------------------------------------------------- the timing
  logic [6:0]  cyc;        // cycles this access has been shown (0 in its first)
  logic [6:0]  need_r;     // the cycle index its answer may come in (MIN)
  logic        held;       // the answer is in, latched, and waiting
  logic [31:0] hold_q;
  logic        ack_d;      // the previous cycle was an acknowledge
  logic        prev_we;
  logic [27:0] prev_line;

  wire cont    = BURST && ack_d && (c_we == prev_we) && (c_addr[31:4] == prev_line);
  wire blk_due = EXTRA ? (cyc > {1'b0, n_comb}) : (cyc != 7'd0);
  wire dev_ack = !held && (blk ? blk_due : b_ack);
  wire [31:0] dev_q = blk ? blk_q : b_rdata;
  wire ok      = (cyc != 7'd0) && (cyc >= need_r);

  always_comb begin
    if (!en) begin
      b_req = c_req; c_ack = b_ack; c_rdata = b_rdata;
    end else if (EXTRA) begin
      b_req   = c_req && !blk && (cyc >= {1'b0, n_comb});
      c_ack   = dev_ack;
      c_rdata = dev_q;
    end else begin
      b_req   = c_req && !blk && !held;
      c_ack   = ok && (held || dev_ack);
      c_rdata = held ? hold_q : dev_q;
    end
  end
  assign blk_we     = en && blk && c_we && dev_ack;
  assign dbg_region = rg;
  assign dbg_n      = n_comb;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cyc <= 7'd0; need_r <= 7'd1; held <= 1'b0; hold_q <= 32'd0;
      ack_d <= 1'b0; prev_we <= 1'b0; prev_line <= 28'd0;
      for (int i = 0; i < 16; i++) cnt_w[i] <= 6'd0;
    end else begin
      ack_d <= c_ack;
      if (c_ack) begin prev_we <= c_we; prev_line <= c_addr[31:4]; end
      if (c_ack || !c_req) cyc <= 7'd0;
      else if (cyc != 7'h7f) cyc <= cyc + 7'd1;
      // the access's first cycle: its minimum (2 + N, a burst's next word 1 + N)
      if (cyc == 7'd0) need_r <= cont ? {1'b0, n_comb} : {1'b0, n_comb} + 7'd1;
      if (en && !EXTRA) begin
        if (c_ack)               held <= 1'b0;
        else if (dev_ack && !ok) begin held <= 1'b1; hold_q <= dev_q; end
      end else held <= 1'b0;
      if (blk_we && c_be[0]) cnt_w[c_addr[5:2]] <= count_of(c_wdata[7:0]);
    end
  end

endmodule
