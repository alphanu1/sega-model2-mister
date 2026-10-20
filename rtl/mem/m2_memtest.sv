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
// R891: THE BOARD'S SDRAM, TESTED AT POWER-UP, ACROSS THE WHOLE MODULE.
//
// Only the board can say how a module is wired -- R18/R19 spent twelve builds
// learning that, and that a test reading ONE address passes at every setting,
// the aliasing one included. So this writes every sample before it reads any,
// and every sample's data names the sample, so a word that aliased onto
// another comes back holding the OTHER sample's number.
//
// THE SAMPLES. The word address is split as {region, offset}: the region is
// its top four bits -- sixteen regions, 8 MB each at AW 26 (128 MB: chip,
// bank, the row's top bit), 4 MB at AW 25 -- and the offset the rest (OB
// bits: the row's other twelve and the column's ten at AW 26). In every
// region, 256 samples, k = 0..255:
//   k = 0            offset 0
//   k = 1            offset all ones
//   k = 2..OB+1      one offset bit set (walking one)
//   k = OB+2..2OB+1  one offset bit clear (walking zero)
//   k = 2OB+2..255   a 32-bit Galois LFSR's low OB bits (0x80200003, seeded
//                    0x2468ACE1 at the start of every pass), stepped once per
//                    such sample in the order visited
// Sample s = {region, k}, 12 bits, holds d = {~s[3:0], s[11:0]}: unique, so
// an alias says where it came from. k[1:0] = 1 then has its LOW byte written
// again as ~d with be 01, k[1:0] = 2 its HIGH byte with be 10, so the word
// must read {d[15:8], ~d[7:0]} or {~d[15:8], d[7:0]}. A word reading ~d whole
// lost its mask (R82, R871): counted apart, as a MASK error.
//
// THE PASSES. Pass 1: write every sample (region 0..15, k 0..255), then read
// every one back. Then, while nothing is downloaded, read-only passes after an
// idle wait -- 2^W1, 2^W2, then 2^W3 ticks (a tick is 65,536 clocks; at 80
// MHz about 0.84 s, 3.4 s and 13.4 s): nothing touches the memory then but the
// controller's refresh, so a chip it does not refresh loses rows that a read
// would otherwise have restored. A download (stop) parks it at the next
// sample -- except in the first pass, which always completes: the loader
// waits for it (done0), a few milliseconds. A pass cut short leaves the
// regions it reached marked with its number and the summary on the last
// complete pass.
//
// THE PORT is port 1's contract (m2_sdram_cdc): a level held with its address
// and data until the acknowledge, then low for a cycle; reads are four-word
// bursts of the aligned address, the word picked by the offset's low bits.
//
// RESULTS, per region, read by `sel` (0-15; 16 the summary), registered:
//   region   r_a = {its pass (1 = the first), region, 3'd0, data errors(9), first bad k}
//            r_d = {7'd0, mask errors(9), the first bad word as read}
//   summary  r_a = {passes, parked, 2'd0, AW(5), sdram_sz(16)}
//            r_d = 0 (a pass's totals are the sum of its sixteen regions;
//                  the decoder adds them -- 64 registers not spent here)
// tools/decode_why.py prints them ('B' and 'b' records of the M2_PROBE stream).

`timescale 1ns/1ps

module m2_memtest #(
  parameter int unsigned AW = 26,           // word address [AW:1]
  parameter int unsigned W1 = 10,           // idle before read pass 2, log2 ticks
  parameter int unsigned W2 = 12,           //                      pass 3
  parameter int unsigned W3 = 14            //                      pass 4 on
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic          go,                 // the memory is ready
  input  logic          stop,               // a download has begun
  input  logic          tick,               // one pulse per 65,536 clocks

  output logic          own,                // port 1 is the test's
  output logic          req,
  output logic          we,
  output logic [AW:1]   addr,
  output logic [15:0]   din,
  output logic [1:0]    be,
  input  logic          ack,
  input  logic [63:0]   dout,

  output logic          done0,              // the first pass is complete
  input  logic [4:0]    sel,
  input  logic [15:0]   sdram_sz,
  output logic [31:0]   r_a,
  output logic [31:0]   r_d,
  output logic [7:0]    passes
);

  localparam int unsigned OB = AW - 4;      // offset bits
  localparam logic [31:0] SEED = 32'h2468ACE1;

  typedef enum logic [2:0] { T_IDLE, T_ISSUE, T_WAIT, T_NEXT, T_IDLEWAIT, T_PARK } st_t;
  st_t st;

  logic        wr_ph;                       // the pass's write phase
  logic        byte_ph;                     // the sample's byte write
  logic [3:0]  r;
  logic [7:0]  k;
  logic [31:0] lfsr;
  logic [OB-1:0] walk;                      // the walking bit: rotated, not shifted by k
  logic        stop_l;
  logic [14:0] wcnt;
  logic [8:0]  derr, merr;
  logic [7:0]  fk;
  logic [15:0] fgot;
  logic        parked;

  // the sample's offset
  logic [OB-1:0] off;
  always_comb begin
    if (k == 8'd0)                       off = '0;
    else if (k == 8'd1)                  off = '1;
    else if (k < 8'(OB + 2))             off = walk;    // bit k-2
    else if (k < 8'(2 * OB + 2))         off = ~walk;   // bit k-OB-2: walk wrapped round to bit 0
    else                                 off = lfsr[OB-1:0];
  end
  wire        rnd    = (k >= 8'(2 * OB + 2));
  wire [11:0] s      = {r, k};
  wire [15:0] d      = {~s[3:0], s};
  wire        b_lo   = (k[1:0] == 2'd1);
  wire        b_hi   = (k[1:0] == 2'd2);
  wire [15:0] expect_w = b_lo ? {d[15:8], ~d[7:0]} : b_hi ? {~d[15:8], d[7:0]} : d;
  wire [15:0] got    = dout[{off[1:0], 4'd0} +: 16];
  wire        last_k = (k == 8'd255);

  // A region's entry: {pass (8), data errors (9), mask errors (9), first bad
  // k (8), the first bad word (16)} -- the pass it belongs to, since a read
  // pass rewrites the regions one at a time while the summary still counts
  // the last complete one. Written as the region's last sample is checked
  // (the FSM's region-done arm, below, under the same condition); read
  // through one register -- the outputs are combinational from it, since
  // the probe holds `sel` for milliseconds.
  (* ramstyle = "MLAB" *) logic [49:0] res [16];
  logic [49:0] res_q;
  wire         res_we = (st == T_NEXT) && !(stop_l && passes != 8'd0) && !wr_ph && last_k;
  always_ff @(posedge clk) if (res_we) res[r] <= {passes + 8'd1, derr, merr, fk, fgot};
  always_ff @(posedge clk) res_q <= res[sel[3:0]];
  assign r_a = sel[4] ? {passes, parked, 2'd0, 5'(AW), sdram_sz}
                      : {res_q[49:42], sel[3:0], 3'd0, res_q[41:33], res_q[23:16]};
  assign r_d = sel[4] ? 32'd0 : {7'd0, res_q[32:24], res_q[15:0]};

  assign done0 = (passes != 8'd0) || parked;
  assign own   = !parked;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= T_IDLE; req <= 1'b0; we <= 1'b0; addr <= '0; din <= '0; be <= 2'b11;
      wr_ph <= 1'b1; byte_ph <= 1'b0; r <= '0; k <= '0; lfsr <= SEED; walk <= OB'(1);
      stop_l <= 1'b0; wcnt <= '0; derr <= '0; merr <= '0; fk <= '0; fgot <= '0;
      passes <= '0; parked <= 1'b0;
    end else begin
      if (stop) stop_l <= 1'b1;
      case (st)
        T_IDLE: if (go) begin
          wr_ph <= 1'b1; byte_ph <= 1'b0; r <= '0; k <= '0; lfsr <= SEED; walk <= OB'(1);
          st <= T_ISSUE;
        end

        T_ISSUE: begin
          we   <= wr_ph;
          addr <= wr_ph ? {r, off} : {r, off[OB-1:2], 2'b00};
          din  <= byte_ph ? ~d : d;
          be   <= byte_ph ? (b_lo ? 2'b01 : 2'b10) : 2'b11;
          req  <= 1'b1;
          st   <= T_WAIT;
        end

        T_WAIT: if (ack) begin
          req <= 1'b0;
          if (!wr_ph && got != expect_w) begin
            if ((b_lo || b_hi) && got == ~d) merr <= merr + 9'd1;
            else                             derr <= derr + 9'd1;
            if (derr == 9'd0 && merr == 9'd0) begin fk <= k; fgot <= got; end
          end
          st <= T_NEXT;
        end

        // the request is low this cycle (the port's contract); move on
        T_NEXT: begin
          st <= T_ISSUE;
          // a download has begun: a later pass stops here (the loader is
          // writing; its words are not the test's), the first one finishes
          if (stop_l && passes != 8'd0) st <= T_PARK;
          else if (wr_ph && (b_lo || b_hi) && !byte_ph) byte_ph <= 1'b1;
          else begin
            byte_ph <= 1'b0;
            if (rnd) lfsr <= lfsr[0] ? ((lfsr >> 1) ^ 32'h80200003) : (lfsr >> 1);
            // the next sample's walking bit: rotate from k = 2 on (bit OB-1
            // wraps to bit 0 for the walking zeros); 1 again for a new region
            if (k >= 8'd2) walk <= {walk[OB-2:0], walk[OB-1]};
            if (last_k)    walk <= OB'(1);
            if (!wr_ph && last_k) begin
              // the region is done: res_we keeps its numbers this cycle
              derr <= '0; merr <= '0; fk <= '0; fgot <= '0;
            end
            k <= k + 8'd1;
            if (last_k) begin
              r <= r + 4'd1;
              if (r == 4'd15) begin
                lfsr <= SEED;
                if (wr_ph) wr_ph <= 1'b0;             // all written: read them back
                else begin                            // a pass is complete
                  passes <= passes + 8'd1;
                  wcnt   <= '0;
                  st     <= T_IDLEWAIT;
                end
              end
            end
          end
        end

        // nothing but the refresh touches the memory here
        T_IDLEWAIT: begin
          if (stop_l) st <= T_PARK;
          else begin
            if (tick) wcnt <= wcnt + 15'd1;
            if (wcnt == 15'((passes == 8'd1) ? (1 << W1) : (passes == 8'd2) ? (1 << W2) : (1 << W3))) begin
              r <= '0; k <= '0; lfsr <= SEED; walk <= OB'(1); st <= T_ISSUE;
            end
          end
        end

        T_PARK: begin parked <= 1'b1; req <= 1'b0; end

        default: st <= T_IDLE;
      endcase
    end
  end

endmodule
