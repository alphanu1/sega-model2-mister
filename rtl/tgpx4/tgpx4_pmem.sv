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
// The TGPx4's program memory: 4 K x 64 (MAME copro_tgpx4_map, 0x000-0xfff),
// uploaded by the i960 as word pairs while copro_ctl1 bit 31 is set.
//
// LINES = 4096: all of it on chip, 4096 x 64 in M10K (32 blocks at 4 K x 2).
// LINES = 1024 / 2048: a direct-mapped cache of that many 64-bit lines over a
// copy of the program in SDRAM. Tag and valid ride in the spare bits of the
// line (64 + tag + 1 <= 70 at 1 K x 10, <= 70 at 2 K x 5), so the cache is
// 7 M10K at 1 K lines and 14 at 2 K. The upload writes the line as well as
// the SDRAM copy (the wrapper's job), so the cache never holds a stale word
// and needs no flush: a line is replaced only by its own address's upload.
// A valid bit starts at 0 from configuration and is never cleared in reset.
//
// Read: rd_req with rd_addr; rd_valid / rd_data one clock later on a hit (or
// a full store), after the refill on a miss.

`timescale 1ns/1ps

module tgpx4_pmem #(
  parameter int unsigned LINES = 1024
) (
  input  logic        clk,
  input  logic        rst_n,

  input  logic        rd_req,
  input  logic [11:0] rd_addr,
  output logic        rd_valid,
  output logic [63:0] rd_data,

  input  logic        prog_we,
  input  logic [11:0] prog_addr,
  input  logic [63:0] prog_data,

  // refill from the SDRAM copy (unused when LINES = 4096)
  output logic        pf_req,
  output logic [11:0] pf_addr,
  input  logic [63:0] pf_data,
  input  logic        pf_ack
);

  localparam int IW = $clog2(LINES);
  localparam int TW = (LINES >= 4096) ? 1 : (12 - IW);   // 1 dummy bit when full
  localparam int LW = 64 + TW + 1;

  generate
  if (LINES >= 4096) begin : g_full

    (* ramstyle = "M10K" *) logic [63:0] prog [0:4095];
    logic [63:0] q;
    always_ff @(posedge clk) begin
      if (prog_we) prog[prog_addr] <= prog_data;
      q <= prog[rd_addr];
    end
    always_ff @(posedge clk or negedge rst_n)
      if (!rst_n) rd_valid <= 1'b0; else rd_valid <= rd_req;
    assign rd_data = q;
    assign pf_req  = 1'b0;
    assign pf_addr = 12'd0;
    logic unused_pf;
    assign unused_pf = pf_ack ^ (^pf_data);

  end else begin : g_cache

    (* ramstyle = "M10K, no_rw_check" *) logic [LW-1:0] line [0:LINES-1];

    logic [IW-1:0] w_idx;
    logic [LW-1:0] w_dat;
    logic          w_en;
    logic [IW-1:0] r_idx;
    logic [LW-1:0] q;

    always_ff @(posedge clk) begin
      if (w_en) line[w_idx] <= w_dat;
      q <= line[r_idx];
    end

    typedef enum logic [1:0] { C_IDLE, C_LOOK, C_MISS, C_FILL } cst_e;
    cst_e          cs;
    logic [11:0]   a_q;

    // the read index is the request's, or the held address while it resolves
    assign r_idx = (cs == C_IDLE) ? rd_addr[IW-1:0] : a_q[IW-1:0];

    logic hit;
    assign hit = q[LW-1] && (q[64 +: TW] == a_q[11 -: TW]);

    always_comb begin
      w_en  = 1'b0;
      w_idx = prog_addr[IW-1:0];
      w_dat = {1'b1, prog_addr[11 -: TW], prog_data};
      if (prog_we) begin
        w_en = 1'b1;
      end else if (cs == C_MISS && pf_ack) begin
        w_en  = 1'b1;
        w_idx = a_q[IW-1:0];
        w_dat = {1'b1, a_q[11 -: TW], pf_data};
      end
    end

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        cs       <= C_IDLE;
        a_q      <= 12'd0;
        pf_req   <= 1'b0;
        pf_addr  <= 12'd0;
      end else begin
        case (cs)
          C_IDLE: if (rd_req) begin a_q <= rd_addr; cs <= C_LOOK; end
          C_LOOK: begin
            if (hit) begin
              cs       <= C_IDLE;
            end else begin
              pf_req  <= 1'b1;
              pf_addr <= a_q;
              cs      <= C_MISS;
            end
          end
          C_MISS: if (pf_ack) begin pf_req <= 1'b0; cs <= C_FILL; end
          C_FILL: cs <= C_LOOK;      // re-read the filled line
          default: cs <= C_IDLE;
        endcase
      end
    end

    // a hit answers in the clock after the request, as the full store does
    assign rd_valid = (cs == C_LOOK) && hit;
    assign rd_data  = q[63:0];

  end
  endgenerate

endmodule
